// Default Node `fs`-backed Resolver — second-host TypeScript.
//
// Mirrors `src/FilesystemResolver.zig`. Built around a project root
// directory containing a `sjon-project.sjon` file of the form:
//
//     (project :plugins ["./vendor/foo.sjon"
//                        "./vendor/bar.sjon"])
//
// At `load` time the resolver reads each `:plugins` entry through
// `loadManifest`, reads its `:name`, and indexes it. At resolve time a
// `(use-plugin "name")` reference looks the name up; an explicit
// `:path` short-circuits the index and reads the file directly.
//
// Resolution order:
//
//   1. `ref.explicitPath` (resolved relative to `projectRoot`).
//   2. Project-file index (`ref.name`).
//   3. Failure → `Resolution.failure { unresolved_plugin, … }`.
//
// Project-load failures (parse errors, malformed shape, per-entry
// manifest read/parse failure, duplicate `:name`) are exposed via the
// `projectDiagnostics` slice so the host can drain them under
// `phase = 'manifest'` alongside inline manifest diagnostics.

import { readFileSync } from 'node:fs';
import { resolve as resolvePath, isAbsolute } from 'node:path';

import type { FormNode } from './ast.ts';
import type { Diagnostic } from './diagnostics.ts';
import type { Reference, Resolution } from './Resolver.ts';

import { parse } from './parser.ts';
import { loadManifest } from './loader.ts';

const ZERO_SPAN = { start: 0, end: 0 } as const;

interface IndexEntry {
  readonly manifestPath: string;
  readonly manifestSource: string;
}

export class FilesystemResolver {
  private readonly projectRoot: string;
  private readonly projectFilePath: string | null;
  private readonly nameIndex: ReadonlyMap<string, IndexEntry>;

  private constructor(
    projectRoot: string,
    projectFilePath: string | null,
    nameIndex: ReadonlyMap<string, IndexEntry>,
  ) {
    this.projectRoot = projectRoot;
    this.projectFilePath = projectFilePath;
    this.nameIndex = nameIndex;
  }

  static load(
    projectRoot: string,
    projectFilePath: string | null,
  ): { resolver: FilesystemResolver; projectDiagnostics: readonly Diagnostic[] } {
    const diagnostics: Diagnostic[] = [];
    const nameIndex = new Map<string, IndexEntry>();

    if (projectFilePath !== null) {
      loadProjectFile(projectRoot, projectFilePath, nameIndex, diagnostics);
    }

    const resolver = new FilesystemResolver(projectRoot, projectFilePath, nameIndex);
    return { resolver, projectDiagnostics: diagnostics };
  }

  resolve(ref: Reference): Resolution {
    if (ref.explicitPath !== null) {
      const absPath = resolveAgainstRoot(this.projectRoot, ref.explicitPath);
      let bytes: string;
      try {
        bytes = readFileSync(absPath, 'utf8');
      } catch (err) {
        return {
          kind: 'failure',
          code: 'unresolved_plugin',
          detail: `explicit :path \`${absPath}\` unreadable: ${(err as Error).message}`,
        };
      }
      return { kind: 'manifest_source', bytes };
    }

    const entry = this.nameIndex.get(ref.name);
    if (entry) {
      return { kind: 'manifest_source', bytes: entry.manifestSource };
    }

    if (this.projectFilePath === null) {
      return {
        kind: 'failure',
        code: 'unresolved_plugin',
        detail: `no plugin named \`${ref.name}\` (no project file in \`${this.projectRoot}\`)`,
      };
    }
    return {
      kind: 'failure',
      code: 'unresolved_plugin',
      detail: `no plugin named \`${ref.name}\` in \`${this.projectFilePath}\``,
    };
  }
}

function loadProjectFile(
  projectRoot: string,
  projectFilePath: string,
  nameIndex: Map<string, IndexEntry>,
  diagnostics: Diagnostic[],
): void {
  let projectSource: string;
  try {
    projectSource = readFileSync(projectFilePath, 'utf8');
  } catch (err) {
    diagnostics.push({
      code: 'invalid_manifest',
      message: `could not read project file \`${projectFilePath}\`: ${(err as Error).message}`,
      path: ['project'],
      span: ZERO_SPAN,
      severity: 'err',
    });
    return;
  }

  let roots;
  try {
    roots = parse(projectSource);
  } catch (err) {
    diagnostics.push({
      code: 'invalid_manifest',
      message: `project file \`${projectFilePath}\` failed to parse: ${(err as Error).message}`,
      path: ['project'],
      span: ZERO_SPAN,
      severity: 'err',
    });
    return;
  }

  if (roots.length === 0) return;
  if (roots.length > 1) {
    diagnostics.push({
      code: 'invalid_manifest',
      message: 'expected a single (project …) form in sjon-project.sjon',
      path: ['project'],
      span: ZERO_SPAN,
      severity: 'err',
    });
    return;
  }

  const root = roots[0]!;
  if (root.tag !== 'form') {
    diagnostics.push({
      code: 'invalid_manifest',
      message: 'expected a (project …) form at top level of sjon-project.sjon',
      path: ['project'],
      span: root.span,
      severity: 'err',
    });
    return;
  }
  if (root.namespace !== null || root.head !== 'project') {
    diagnostics.push({
      code: 'invalid_manifest',
      message: `expected (project …) at top level of sjon-project.sjon, got \`${root.head}\``,
      path: ['project'],
      span: root.headSpan,
      severity: 'err',
    });
    return;
  }

  walkProjectForm(projectRoot, root, nameIndex, diagnostics);
}

function walkProjectForm(
  projectRoot: string,
  form: FormNode,
  nameIndex: Map<string, IndexEntry>,
  diagnostics: Diagnostic[],
): void {
  for (const child of form.children) {
    if (child.tag !== 'kvpair') continue;
    if (child.key !== 'plugins') continue;
    if (child.value.tag !== 'vector') {
      diagnostics.push({
        code: 'invalid_manifest',
        message: '`:plugins` must be a vector of manifest path strings',
        path: ['project'],
        span: child.value.span,
        severity: 'err',
      });
      continue;
    }
    for (const elem of child.value.elements) {
      indexOneManifest(projectRoot, elem, nameIndex, diagnostics);
    }
  }
}

function indexOneManifest(
  projectRoot: string,
  elem: import('./ast.ts').Node,
  nameIndex: Map<string, IndexEntry>,
  diagnostics: Diagnostic[],
): void {
  if (elem.tag !== 'string') {
    diagnostics.push({
      code: 'invalid_manifest',
      message: '`:plugins` entries must be path strings',
      path: ['project'],
      span: elem.span,
      severity: 'err',
    });
    return;
  }

  const relPath = elem.value;
  const pathSpan = elem.span;
  const manifestPath = resolveAgainstRoot(projectRoot, relPath);

  let manifestSource: string;
  try {
    manifestSource = readFileSync(manifestPath, 'utf8');
  } catch (err) {
    diagnostics.push({
      code: 'invalid_manifest',
      message: `manifest at \`${manifestPath}\` unreadable: ${(err as Error).message}`,
      path: ['project'],
      span: pathSpan,
      severity: 'err',
    });
    return;
  }

  let manifestRoots;
  try {
    manifestRoots = parse(manifestSource);
  } catch (err) {
    diagnostics.push({
      code: 'invalid_manifest',
      message: `manifest at \`${manifestPath}\` failed to parse: ${(err as Error).message}`,
      path: ['project'],
      span: pathSpan,
      severity: 'err',
    });
    return;
  }

  const loaded = loadManifest(manifestRoots);
  if (loaded.errors.length > 0) {
    for (const msg of loaded.errors) {
      diagnostics.push({
        code: 'invalid_manifest',
        message: `manifest at \`${manifestPath}\` rejected: ${msg}`,
        path: ['project'],
        span: pathSpan,
        severity: 'err',
      });
    }
    return;
  }
  let hadErr = false;
  for (const d of loaded.diagnostics) {
    diagnostics.push({
      code: d.code,
      message: `in ${manifestPath}: ${d.message}`,
      path: ['project'],
      span: pathSpan,
      severity: d.severity,
    });
    if (d.severity === 'err') hadErr = true;
  }
  if (hadErr) return;

  const name = loaded.plugin.name;
  if (nameIndex.has(name)) {
    const existing = nameIndex.get(name)!;
    diagnostics.push({
      code: 'duplicate_plugin_name',
      message: `plugin \`:name ${name}\` already declared by \`${existing.manifestPath}\`; refusing last-wins`,
      path: ['project'],
      span: pathSpan,
      severity: 'err',
    });
    return;
  }

  nameIndex.set(name, { manifestPath, manifestSource });
}

function resolveAgainstRoot(root: string, rel: string): string {
  if (isAbsolute(rel)) return rel;
  return resolvePath(root, rel);
}
