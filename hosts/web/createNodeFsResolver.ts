// Default Node `fs`-backed resolver for `SjonHost`. Mirrors
// `hosts/typescript-parity/src/FilesystemResolver.ts` semantics:
//
//   1. Read `sjon-project.sjon`, walk `(project :plugins […])`.
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
// The micro-parser only handles the SJON subset needed for the project
// file (`(project :plugins ["…" …])`) and the manifest `:name`
// extraction. Full SJON parsing lives in the WASM artifact for the
// actual document validation pass — this is intentionally separate so
// the resolver can index manifests *before* the WASM is loaded.

import { readFileSync } from 'node:fs';
import { resolve as resolvePath, isAbsolute } from 'node:path';
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

  if (projectForm.head !== 'project') {
    diagnostics.push(
      projectDiag(
        'invalid_manifest',
        `expected (project …) at top level of sjon-project.sjon, got \`${projectForm.head}\``,
      ),
    );
    return;
  }

  for (const child of projectForm.children) {
    if (child.tag !== 'kvpair' || child.key !== 'plugins') continue;
    if (child.value.tag !== 'vector') {
      diagnostics.push(
        projectDiag('invalid_manifest', '`:plugins` must be a vector of manifest path strings'),
      );
      continue;
    }
    for (const elem of child.value.elements) {
      indexOneManifest(projectRoot, elem, nameIndex, diagnostics);
    }
  }
}

function indexOneManifest(
  projectRoot: string,
  elem: ParsedNode,
  nameIndex: Map<string, ManifestEntry>,
  diagnostics: HostDiagnostic[],
): void {
  if (elem.tag !== 'string') {
    diagnostics.push(projectDiag('invalid_manifest', '`:plugins` entries must be path strings'));
    return;
  }
  const manifestPath = resolveAgainstRoot(projectRoot, elem.value);
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
  if (pluginForm === null || pluginForm.head !== 'plugin') {
    diagnostics.push(
      projectDiag('invalid_manifest', `manifest at \`${manifestPath}\` is not a (plugin …) form`),
    );
    return;
  }
  let name: string | null = null;
  for (const child of pluginForm.children) {
    if (child.tag !== 'kvpair' || child.key !== 'name') continue;
    if (child.value.tag === 'symbol' || child.value.tag === 'string') {
      name = child.value.value;
    }
    break;
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

function errMsg(err: unknown): string {
  if (err && typeof err === 'object' && 'message' in err) {
    return (err as { message: string }).message;
  }
  return String(err);
}

// ---------------------------------------------------------------------------
// Tiny SJON-subset parser
// ---------------------------------------------------------------------------
//
// Handles only what `sjon-project.sjon` and `(plugin :name … …)`
// manifests need: forms, kvpairs (greedy `:k v`), vectors, strings,
// symbols, line comments (`;`), and any whitespace. Ignores numbers /
// booleans / nested structures past what we actually walk. The full
// validating parser lives in `sjon.wasm` and runs against the document
// itself; this is just the bootstrap so the resolver can index
// manifests before WASM is loaded.

type FormNode = { tag: 'form'; head: string; children: ParsedNode[] };

type ParsedNode =
  | FormNode
  | { tag: 'kvpair'; key: string; value: ParsedNode }
  | { tag: 'vector'; elements: ParsedNode[] }
  | { tag: 'string'; value: string }
  | { tag: 'symbol'; value: string }
  | { tag: 'other' };

interface Cursor {
  src: string;
  i: number;
}

/**
 * Parse a single top-level form. Returns `null` for an empty source
 * (whitespace + comments only). Throws on any structural error.
 */
function parseProjectFile(source: string): FormNode | null {
  const cursor: Cursor = { src: source, i: 0 };
  skipTrivia(cursor);
  if (cursor.i >= cursor.src.length) return null;
  const node = parseNode(cursor);
  if (node.tag !== 'form') {
    throw new Error('expected a form at top level');
  }
  skipTrivia(cursor);
  if (cursor.i < cursor.src.length) {
    throw new Error('expected a single top-level form');
  }
  return node;
}

function skipTrivia(c: Cursor): void {
  while (c.i < c.src.length) {
    const ch = c.src[c.i];
    if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r') {
      c.i++;
    } else if (ch === ';') {
      while (c.i < c.src.length && c.src[c.i] !== '\n') c.i++;
    } else break;
  }
}

function parseNode(c: Cursor): ParsedNode {
  skipTrivia(c);
  if (c.i >= c.src.length) throw new Error('unexpected end of input');
  const ch = c.src[c.i];
  if (ch === '(') return parseForm(c);
  if (ch === '[') return parseVector(c);
  if (ch === '"') return parseString(c);
  if (ch === ':') {
    // Bare keyword without a paired value is uncommon outside kvpair
    // context; treat as a symbol-like token (we never use it as a value).
    c.i++;
    const key = readSymbol(c);
    return { tag: 'symbol', value: ':' + key };
  }
  return parseAtom(c);
}

function parseForm(c: Cursor): ParsedNode {
  c.i++; // consume '('
  skipTrivia(c);
  const head = readSymbol(c);
  const children: ParsedNode[] = [];
  while (true) {
    skipTrivia(c);
    if (c.i >= c.src.length) throw new Error('unterminated form');
    if (c.src[c.i] === ')') {
      c.i++;
      return { tag: 'form', head, children };
    }
    if (c.src[c.i] === ':') {
      c.i++;
      const key = readSymbol(c);
      skipTrivia(c);
      const value = parseNode(c);
      children.push({ tag: 'kvpair', key, value });
      continue;
    }
    children.push(parseNode(c));
  }
}

function parseVector(c: Cursor): ParsedNode {
  c.i++; // consume '['
  const elements: ParsedNode[] = [];
  while (true) {
    skipTrivia(c);
    if (c.i >= c.src.length) throw new Error('unterminated vector');
    if (c.src[c.i] === ']') {
      c.i++;
      return { tag: 'vector', elements };
    }
    elements.push(parseNode(c));
  }
}

function parseString(c: Cursor): ParsedNode {
  c.i++; // consume '"'
  let out = '';
  while (c.i < c.src.length) {
    const ch = c.src[c.i];
    if (ch === '"') {
      c.i++;
      return { tag: 'string', value: out };
    }
    if (ch === '\\') {
      c.i++;
      const esc = c.src[c.i];
      if (esc === 'n') out += '\n';
      else if (esc === 'r') out += '\r';
      else if (esc === 't') out += '\t';
      else out += esc;
      c.i++;
    } else {
      out += ch;
      c.i++;
    }
  }
  throw new Error('unterminated string');
}

function parseAtom(c: Cursor): ParsedNode {
  const value = readSymbol(c);
  if (value.length === 0) throw new Error(`unexpected character \`${c.src[c.i]}\``);
  return { tag: 'symbol', value };
}

function readSymbol(c: Cursor): string {
  const start = c.i;
  while (c.i < c.src.length) {
    const ch = c.src[c.i];
    if (
      ch === '(' ||
      ch === ')' ||
      ch === '[' ||
      ch === ']' ||
      ch === '"' ||
      ch === ':' ||
      ch === ' ' ||
      ch === '\t' ||
      ch === '\n' ||
      ch === '\r' ||
      ch === ';'
    )
      break;
    c.i++;
  }
  return c.src.slice(start, c.i);
}
