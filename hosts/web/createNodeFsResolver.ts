// Default Node `fs`-backed resolver for `SjonHost`. Mirrors
// `hosts/typescript-parity/src/FilesystemResolver.ts` semantics:
//
//   1. Read `sjon-project.sjon`, walk `(project :plugins […])`. An
//      entry is a path string or a `(plugin-entry :path "…" …)` form.
//   2. For each entry, read the manifest, parse its top-level
//      `(plugin :name <symbol> …)` to extract the name, index by name.
//   3. Duplicate `:name` → `duplicate_plugin_name` diagnostic.
//   4. `(use-plugin "name")` → index lookup; explicit `:path` →
//      direct file read.
//
// Returns `{resolver, projectDiagnostics}`. Caller forwards
// `projectDiagnostics` to `host.validateDocument` via `HostOptions`;
// `SjonHost` prepends them to the result's diagnostics so they land
// under `phase: 'manifest'` exactly like Zig's `Host.validateDocument`
// drains its own FilesystemResolver project diagnostics.
//
// Both bootstrap reads go through `@sjon-lang/read`'s throwing `read`
// entry: the resolver is a strict consumer, so a partial tree carrying
// diagnostics must never be indexed. Raw strings and `#| … |#` block
// comments are therefore real SJON here — a commented-out `:plugins`
// entry is trivia, not configuration — while parse errors, a non-form
// root, and multiple roots still surface as `invalid_manifest`. This is
// intentionally separate from the WASM document-validation pass so the
// resolver can index manifests *before* the WASM is loaded.

import { readFileSync } from 'node:fs';
import { resolve as resolvePath, isAbsolute } from 'node:path';
import { fields, read } from '@sjon-lang/read';
import type { FormNode, Node } from '@sjon-lang/read';
import { errMsg } from './errMsg.ts';
import type { HostDiagnostic, ResolverFn } from './types.ts';

/**
 * Look for an executable-plugin sidecar wasm next to `manifestPath`.
 * Pairing is by file stem — `manifests/double.sjon` pairs with
 * `manifests/double.wasm`. Returns `null` for missing/unreadable files;
 * the absence of a sidecar wasm is the declarative-only path, not a
 * load failure.
 */
function tryReadSiblingWasm(manifestPath: string): Uint8Array | null {
  const wasmPath = manifestPath.replace(/\.sjon$/i, '') + '.wasm';
  // No-op if the manifest didn't actually end with `.sjon` — the host
  // accepts arbitrary extensions but pairs only `.sjon` ↔ `.wasm`.
  if (wasmPath === manifestPath) return null;
  try {
    return readFileSync(wasmPath);
  } catch {
    return null;
  }
}

const ZERO_SPAN = Object.freeze({ start: 0, end: 0 });

interface ManifestEntry {
  manifestPath: string;
  manifestSource: string;
}

export interface CreateNodeFsResolverOptions {
  projectRoot: string;
  projectFile?: string | null;
}

export interface CreateNodeFsResolverResult {
  resolver: ResolverFn;
  projectDiagnostics: readonly HostDiagnostic[];
}

/** Build a Node fs resolver pre-indexed against a project file. */
export function createNodeFsResolver({
  projectRoot,
  projectFile = null,
}: CreateNodeFsResolverOptions): CreateNodeFsResolverResult {
  const projectDiagnostics: HostDiagnostic[] = [];
  const nameIndex = new Map<string, ManifestEntry>();

  if (projectFile !== null) {
    loadProjectFile(projectRoot, projectFile, nameIndex, projectDiagnostics);
  }

  const resolver: ResolverFn = (ref) => {
    if (ref.explicitPath !== null && ref.explicitPath !== undefined) {
      const absPath = resolveAgainstRoot(projectRoot, ref.explicitPath);
      try {
        const source = readFileSync(absPath, 'utf8');
        return { kind: 'manifest', source, wasm: tryReadSiblingWasm(absPath) };
      } catch (err) {
        return {
          kind: 'failure',
          code: 'unresolved_plugin',
          detail: `explicit :path \`${absPath}\` unreadable: ${errMsg(err)}`,
        };
      }
    }
    const entry = nameIndex.get(ref.name);
    if (entry)
      return {
        kind: 'manifest',
        source: entry.manifestSource,
        wasm: tryReadSiblingWasm(entry.manifestPath),
      };
    if (projectFile === null) {
      return {
        kind: 'failure',
        code: 'unresolved_plugin',
        detail: `no plugin named \`${ref.name}\` (no project file in \`${projectRoot}\`)`,
      };
    }
    return {
      kind: 'failure',
      code: 'unresolved_plugin',
      detail: `no plugin named \`${ref.name}\` in \`${projectFile}\``,
    };
  };

  return { resolver, projectDiagnostics };
}

function loadProjectFile(
  projectRoot: string,
  projectFile: string,
  nameIndex: Map<string, ManifestEntry>,
  diagnostics: HostDiagnostic[],
): void {
  let source: string;
  try {
    source = readFileSync(projectFile, 'utf8');
  } catch (err) {
    diagnostics.push(
      projectDiag(
        'invalid_manifest',
        `could not read project file \`${projectFile}\`: ${errMsg(err)}`,
      ),
    );
    return;
  }

  let projectForm: FormNode | null;
  try {
    projectForm = parseProjectFile(source);
  } catch (err) {
    diagnostics.push(
      projectDiag(
        'invalid_manifest',
        `project file \`${projectFile}\` failed to parse: ${errMsg(err)}`,
      ),
    );
    return;
  }
  if (projectForm === null) return; // empty file is fine

  if (projectForm.namespace !== null || projectForm.head !== 'project') {
    diagnostics.push(
      projectDiag(
        'invalid_manifest',
        `expected (project …) at top level of sjon-project.sjon, got \`${qualifiedHead(projectForm)}\``,
      ),
    );
    return;
  }

  for (const pair of fields(projectForm).pairs) {
    if (pair.key !== 'plugins') continue;
    if (pair.value.tag !== 'vector') {
      diagnostics.push(
        projectDiag('invalid_manifest', '`:plugins` must be a vector of manifest path strings'),
      );
      continue;
    }
    for (const elem of pair.value.elements) {
      indexOneManifest(projectRoot, elem, nameIndex, diagnostics);
    }
  }
}

/**
 * Reduce one `:plugins` entry to the manifest path it names, or null
 * after pushing a diagnostic. Mirrors `indexOneManifest`'s entry switch
 * in `src/FilesystemResolver.zig` — a bare path string, or a
 * `(plugin-entry :path "…" …)` form.
 *
 * `:version` and `:hash` are *project-level* pins, parsed by the
 * reference resolver only to cross-check them against the document's
 * `(use-plugin …)` pins and emit `pin_disagreement`. That check is
 * FilesystemResolver-local by design (a deliberate parity boundary:
 * the project file is one resolver's config format, not a language
 * surface), so they are accepted and inert here — as are the
 * forward-compat `:optional` and the reserved `:as`. Accepting the
 * *syntax* is not optional: rejecting the form outright, as this did
 * until now, made a project file the reference accepts fail on three of
 * the four hosts. Enforcement of the document's own pins is unaffected —
 * it happens above the resolver, in `SjonHost`.
 */
function entryManifestPath(elem: Node, diagnostics: HostDiagnostic[]): string | null {
  if (elem.tag === 'string') return elem.value;
  if (elem.tag !== 'form') {
    diagnostics.push(
      projectDiag(
        'invalid_manifest',
        '`:plugins` entries must be a path string or `(plugin-entry …)` form',
      ),
    );
    return null;
  }
  if (elem.namespace !== null || elem.head !== 'plugin-entry') {
    diagnostics.push(
      projectDiag(
        'invalid_manifest',
        '`:plugins` entries must be a path string or `(plugin-entry …)`; ' +
          `got \`(${qualifiedHead(elem)} …)\``,
      ),
    );
    return null;
  }
  let path = '';
  for (const pair of fields(elem).pairs) {
    if (pair.key === 'path' && pair.value.tag === 'string') path = pair.value.value;
  }
  if (path === '') {
    diagnostics.push(
      projectDiag('invalid_manifest', '`(plugin-entry …)` requires a `:path` string'),
    );
    return null;
  }
  return path;
}

function indexOneManifest(
  projectRoot: string,
  elem: Node,
  nameIndex: Map<string, ManifestEntry>,
  diagnostics: HostDiagnostic[],
): void {
  const relPath = entryManifestPath(elem, diagnostics);
  if (relPath === null) return;
  const manifestPath = resolveAgainstRoot(projectRoot, relPath);
  let manifestSource: string;
  try {
    manifestSource = readFileSync(manifestPath, 'utf8');
  } catch (err) {
    diagnostics.push(
      projectDiag('invalid_manifest', `manifest at \`${manifestPath}\` unreadable: ${errMsg(err)}`),
    );
    return;
  }
  let pluginForm: FormNode | null;
  try {
    pluginForm = parseProjectFile(manifestSource);
  } catch (err) {
    diagnostics.push(
      projectDiag(
        'invalid_manifest',
        `manifest at \`${manifestPath}\` failed to parse: ${errMsg(err)}`,
      ),
    );
    return;
  }
  if (pluginForm === null || pluginForm.namespace !== null || pluginForm.head !== 'plugin') {
    diagnostics.push(
      projectDiag('invalid_manifest', `manifest at \`${manifestPath}\` is not a (plugin …) form`),
    );
    return;
  }
  let name: string | null = null;
  const namePair = fields(pluginForm).pairs.find((pair) => pair.key === 'name');
  if (
    namePair !== undefined &&
    (namePair.value.tag === 'symbol' || namePair.value.tag === 'string')
  ) {
    name = namePair.value.value;
  }
  if (name === null) {
    diagnostics.push(
      projectDiag('invalid_manifest', `manifest at \`${manifestPath}\` is missing :name`),
    );
    return;
  }
  if (nameIndex.has(name)) {
    const existing = nameIndex.get(name)!;
    diagnostics.push(
      projectDiag(
        'duplicate_plugin_name',
        `plugin \`:name ${name}\` already declared by \`${existing.manifestPath}\`; refusing last-wins`,
      ),
    );
    return;
  }
  nameIndex.set(name, { manifestPath, manifestSource });
}

function resolveAgainstRoot(root: string, rel: string): string {
  return isAbsolute(rel) ? rel : resolvePath(root, rel);
}

function projectDiag(code: string, message: string): HostDiagnostic {
  return {
    phase: 'manifest',
    code,
    severity: 'err',
    message,
    span: ZERO_SPAN,
    path: ['project'],
    declarationSpan: null,
  };
}

/** Reconstruct the head as written: `namespace/head`, or the bare head. */
function qualifiedHead(form: FormNode): string {
  return form.namespace === null ? form.head : `${form.namespace}/${form.head}`;
}

/**
 * Read a single top-level form from a manifest / project file. Returns
 * `null` for an empty source (whitespace and comments only); throws on any
 * parse diagnostic, a non-form root, or more than one root.
 *
 * Uses throwing `read`, deliberately: a recovered partial tree with
 * diagnostics must not become resolver configuration. The caller maps the
 * throw to `invalid_manifest`.
 */
function parseProjectFile(source: string): FormNode | null {
  const [node, ...extra] = read(source);
  if (node === undefined) return null;
  if (extra.length > 0) throw new Error('expected a single top-level form');
  if (node.tag !== 'form') throw new Error('expected a form at top level');
  return node;
}
