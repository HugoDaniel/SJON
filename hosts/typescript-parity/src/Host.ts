// SJON host — second-host TypeScript implementation.
//
// Mirrors `src/Host.zig`'s `validateDocument`: parse a single source,
// partition top-level forms into `(plugin …)` declarations,
// `(use-plugin …)` references, and data, then run three passes —
// manifest (load each declaration, resolve each reference), aggregate
// (cross-ref schema validation), and validation (data forest).
//
// The cross-host parity guarantee: this host's diagnostic stream
// (filtered to err severity, compared on `(code, path)`) matches the
// Zig host's stream for every conformance fixture.

import type { Node, FormNode, Span } from './ast.ts';
import type { Diagnostic } from './diagnostics.ts';
import type { Plugin, Schema } from './plugin.ts';

import { parse } from './parser.ts';
import { loadManifest } from './loader.ts';
import { validate } from './validator.ts';
import { validateCrossRefs } from './plugin.ts';
import { FilesystemResolver } from './FilesystemResolver.ts';
import { parseReference, type Reference, type Resolution, type ResolverFn } from './Resolver.ts';
import {
  exportSchema as exportSchemaNative,
  type ExportOptions as SchemaExportOptions,
  type ExportResult as SchemaExportResult,
} from './schemaExport/index.ts';

export type Phase = 'manifest' | 'aggregate' | 'validation';

export interface HostDiagnostic extends Diagnostic {
  readonly phase: Phase;
  // Set only when phase === 'manifest' and the diagnostic was emitted
  // against a `(plugin …)` declaration or `(use-plugin …)` reference.
  // Points at the form's head span so a renderer can anchor the failure
  // to its owner.
  readonly declarationSpan: Span | null;
}

export interface HostOptions {
  // Used to resolve `:path` overrides and (with `projectFile`) to drive
  // the default FilesystemResolver auto-construction.
  readonly projectRoot: string | null;
  // Explicit resolver. Takes precedence over `projectRoot`/`projectFile`.
  readonly resolver: ResolverFn | null;
  // Path to the project file. The conformance runner discovers this by
  // probing for a sibling `sjon-project.sjon`.
  readonly projectFile: string | null;
}

export interface HostResult {
  readonly diagnostics: readonly HostDiagnostic[];
  readonly loadedPlugins: readonly Plugin[];
  readonly declarations: readonly FormNode[];
  readonly references: readonly FormNode[];
  readonly dataForest: readonly Node[];
}

// `evalExpr`'s declarative-only result. The TS-parity host has no Expr
// evaluator and no WASM runtime — `value` is always `null`; cross-host
// parity tests use this entry point to compare the parse / manifest /
// aggregate diagnostic stream the WASM-backed hosts produce against the
// same prep phases the TS host runs.
export interface HostEvalResult {
  readonly value: unknown;
  readonly diagnostics: readonly HostDiagnostic[];
  readonly loadedPlugins: readonly Plugin[];
}

export class EvalExprError extends Error {
  readonly code: 'NoExpression' | 'MultipleExpressions';

  constructor(code: 'NoExpression' | 'MultipleExpressions', message: string) {
    super(message);
    this.name = 'EvalExprError';
    this.code = code;
  }
}

interface Partitioned {
  readonly declarations: readonly FormNode[];
  readonly references: readonly FormNode[];
  readonly dataForest: readonly Node[];
}

function partition(roots: readonly Node[]): Partitioned {
  const declarations: FormNode[] = [];
  const references: FormNode[] = [];
  const dataForest: Node[] = [];
  for (const node of roots) {
    if (node.tag === 'form' && node.namespace === null) {
      if (node.head === 'plugin') {
        declarations.push(node);
        continue;
      }
      if (node.head === 'use-plugin') {
        references.push(node);
        continue;
      }
    }
    dataForest.push(node);
  }
  return { declarations, references, dataForest };
}

function wrapDiagnostic(d: Diagnostic, phase: Phase, declarationSpan: Span | null): HostDiagnostic {
  return {
    code: d.code,
    message: d.message,
    path: d.path,
    span: d.span,
    severity: d.severity,
    phase,
    declarationSpan,
  };
}

export function validateDocument(source: string, options: HostOptions): HostResult {
  const diagnostics: HostDiagnostic[] = [];

  const parseDiagnostics: Diagnostic[] = [];
  const roots = parse(source, parseDiagnostics);
  for (const d of parseDiagnostics) {
    diagnostics.push(wrapDiagnostic(d, 'validation', null));
  }
  const part = partition(roots);

  const loadedPlugins: Plugin[] = [];

  // Manifest pass — each inline `(plugin …)` declaration becomes a
  // ManifestLoader call. Successful loads contribute to the schema.
  for (const decl of part.declarations) {
    const declHeadSpan = decl.headSpan;
    const loaded = loadManifest([decl]);
    if (loaded.errors.length > 0) {
      // ManifestLoader-shape failures (no single root etc) shouldn't
      // happen here — we partitioned for `(plugin …)` heads — but
      // surface as `invalid_manifest` defensively.
      for (const msg of loaded.errors) {
        diagnostics.push({
          code: 'invalid_manifest',
          message: msg,
          path: [],
          span: declHeadSpan,
          severity: 'err',
          phase: 'manifest',
          declarationSpan: declHeadSpan,
        });
      }
      continue;
    }
    let hadErr = false;
    for (const d of loaded.diagnostics) {
      diagnostics.push(wrapDiagnostic(d, 'manifest', declHeadSpan));
      if (d.severity === 'err') hadErr = true;
    }
    if (hadErr) continue;
    loadedPlugins.push(loaded.plugin);
  }

  // Resolver pass — each `(use-plugin …)` reference is parsed and
  // (when a resolver is installed) handed off. The default
  // FilesystemResolver is constructed from `projectRoot` + `projectFile`
  // when no explicit resolver was injected; project-load diagnostics
  // are drained into the host stream under `phase = 'manifest'`.
  let effectiveResolver: ResolverFn | null = options.resolver;
  if (!effectiveResolver && options.projectRoot) {
    const built = FilesystemResolver.load(options.projectRoot, options.projectFile);
    for (const d of built.projectDiagnostics) {
      diagnostics.push(wrapDiagnostic(d, 'manifest', null));
    }
    effectiveResolver = (ref) => built.resolver.resolve(ref);
  }

  for (const ref of part.references) {
    const refHeadSpan = ref.headSpan;
    const parsed = parseReference(ref);
    let hadParseErr = false;
    for (const d of parsed.diagnostics) {
      diagnostics.push(wrapDiagnostic(d, 'manifest', refHeadSpan));
      if (d.severity === 'err') hadParseErr = true;
    }
    if (hadParseErr) continue;

    if (!effectiveResolver) {
      diagnostics.push({
        code: 'unresolved_plugin',
        message: `no resolver configured for \`(use-plugin "${parsed.reference.name}" …)\``,
        path: [],
        span: parsed.reference.span,
        severity: 'err',
        phase: 'manifest',
        declarationSpan: refHeadSpan,
      });
      continue;
    }

    const resolution = effectiveResolver(parsed.reference);
    handleResolution(resolution, parsed.reference, refHeadSpan, loadedPlugins, diagnostics);
  }

  // Aggregate pass — cross-ref schema validation runs over the loaded
  // plugins (not the partial declarations). Diagnostics carry
  // `phase = 'aggregate'`.
  const schema: Schema = { plugins: loadedPlugins };
  for (const d of validateCrossRefs(schema)) {
    diagnostics.push(wrapDiagnostic(d, 'aggregate', null));
  }

  // Validation pass — the data forest only.
  for (const d of validate(schema, part.dataForest)) {
    diagnostics.push(wrapDiagnostic(d, 'validation', null));
  }

  return {
    diagnostics,
    loadedPlugins,
    declarations: part.declarations,
    references: part.references,
    dataForest: part.dataForest,
  };
}

/// Manifest_source / wasm_bytes / failure dispatch. Mirrors the
/// `loadResolvedManifest` pattern in `src/Host.zig`: the resolver-returned
/// bytes get re-parsed + loaded, and an `:name` mismatch against the
/// reference becomes `plugin_name_mismatch`.
function handleResolution(
  resolution: Resolution,
  reference: Reference,
  refHeadSpan: Span,
  loadedPlugins: Plugin[],
  diagnostics: HostDiagnostic[],
): void {
  switch (resolution.kind) {
    case 'manifest_source':
      loadResolvedManifest(resolution.bytes, reference, refHeadSpan, loadedPlugins, diagnostics);
      return;
    case 'wasm_bytes':
      diagnostics.push({
        code: 'unresolved_plugin',
        message: `WASM plugins not supported yet (D7); \`(use-plugin "${reference.name}" …)\` returned wasm bytes`,
        path: [],
        span: reference.span,
        severity: 'err',
        phase: 'manifest',
        declarationSpan: refHeadSpan,
      });
      return;
    case 'failure':
      diagnostics.push({
        code: resolution.code,
        message: resolution.detail,
        path: [],
        span: reference.span,
        severity: 'err',
        phase: 'manifest',
        declarationSpan: refHeadSpan,
      });
      return;
  }
}

function loadResolvedManifest(
  bytes: string,
  reference: Reference,
  refHeadSpan: Span,
  loadedPlugins: Plugin[],
  diagnostics: HostDiagnostic[],
): void {
  let manifestRoots: readonly Node[];
  try {
    manifestRoots = parse(bytes);
  } catch (err) {
    diagnostics.push({
      code: 'invalid_manifest',
      message: `manifest for \`(use-plugin "${reference.name}" …)\` failed to parse: ${(err as Error).message}`,
      path: [],
      span: reference.span,
      severity: 'err',
      phase: 'manifest',
      declarationSpan: refHeadSpan,
    });
    return;
  }

  const loaded = loadManifest(manifestRoots);
  if (loaded.errors.length > 0) {
    for (const msg of loaded.errors) {
      diagnostics.push({
        code: 'invalid_manifest',
        message: `manifest for \`(use-plugin "${reference.name}" …)\` rejected: ${msg}`,
        path: [],
        span: reference.span,
        severity: 'err',
        phase: 'manifest',
        declarationSpan: refHeadSpan,
      });
    }
    return;
  }

  let hadErr = false;
  for (const d of loaded.diagnostics) {
    diagnostics.push({
      code: d.code,
      message: `in resolved manifest for \`(use-plugin "${reference.name}" …)\`: ${d.message}`,
      path: d.path,
      span: reference.span,
      severity: d.severity,
      phase: 'manifest',
      declarationSpan: refHeadSpan,
    });
    if (d.severity === 'err') hadErr = true;
  }
  if (hadErr) return;

  if (loaded.plugin.name !== reference.name) {
    diagnostics.push({
      code: 'plugin_name_mismatch',
      message: `(use-plugin "${reference.name}" …) resolved to a manifest whose :name is \`${loaded.plugin.name}\``,
      path: [],
      span: reference.span,
      severity: 'err',
      phase: 'manifest',
      declarationSpan: refHeadSpan,
    });
    return;
  }

  // Enforce `(use-plugin … :version "x")` pin against the manifest's
  // declared `:version`. Exact-string match — no semver ranges in v1.
  // Mirrors `src/Host.zig` `loadResolvedManifest`.
  if (reference.version !== null && loaded.plugin.version !== reference.version) {
    diagnostics.push({
      code: 'plugin_version_mismatch',
      message: `(use-plugin "${reference.name}" :version "${reference.version}") pin differs from manifest :version \`${loaded.plugin.version}\``,
      path: [],
      span: reference.span,
      severity: 'err',
      phase: 'manifest',
      declarationSpan: refHeadSpan,
    });
    return;
  }

  // Enforce `(use-plugin … :hash "sha256-…")` pin. The TS-parity
  // resolver returns `manifest_source` only — it doesn't pair sibling
  // wasm — so any hash pin in this host hits the "no wasm to hash"
  // branch and emits `plugin_hash_mismatch`. The diagnostic code
  // matches the Zig and Web hosts (which hash actual bytes); only the
  // detail message differs.
  if (reference.hash !== null) {
    diagnostics.push({
      code: 'plugin_hash_mismatch',
      message: `(use-plugin "${reference.name}" :hash "${reference.hash}") pin set but TS-parity has no wasm bytes to hash`,
      path: [],
      span: reference.span,
      severity: 'err',
      phase: 'manifest',
      declarationSpan: refHeadSpan,
    });
    return;
  }

  loadedPlugins.push(loaded.plugin);
}

/**
 * Declarative-only `evalExpr` — runs the same parse / partition /
 * manifest / aggregate prep as `validateDocument`, then refuses to
 * evaluate (the TS-parity host has no Expr evaluator). `value` is
 * always `null`; cross-host parity tests use this entry point to
 * compare the WASM-backed hosts' prep-phase diagnostic stream against
 * the TS host's. NoExpression / MultipleExpressions throw an
 * `EvalExprError` matching the wire shape the Zig host returns.
 */
export function evalExpr(source: string, options: HostOptions): HostEvalResult {
  const r = validateDocument(source, options);
  // Filter out validation-phase diagnostics that came from the
  // (skipped) data forest walk — they're noise here because the data
  // form IS the expression, and the validator would flag it as
  // `unknown_form` on every call. The WASM-backed hosts don't walk the
  // form's children through the validator on this entry point.
  const diagnostics = r.diagnostics.filter((d) => d.phase !== 'validation');

  if (r.dataForest.length === 0) {
    throw new EvalExprError('NoExpression', 'document had no data-forest form to evaluate');
  }
  if (r.dataForest.length > 1) {
    throw new EvalExprError(
      'MultipleExpressions',
      `document had ${r.dataForest.length} data-forest forms; evalExpr accepts exactly one`,
    );
  }

  return {
    value: null,
    diagnostics,
    loadedPlugins: r.loadedPlugins,
  };
}

/**
 * Export a JSON Schema 2020-12 + TypeScript `.d.ts` (+ optional
 * intermediate IR) for the schema declared in `source`. Mirrors
 * `Host.exportSchemaFromSource` over the native TypeScript-parity
 * exporter: parses, partitions, runs manifest + aggregate prep, then
 * lowers + emits. Returns the export result alongside the host
 * result so callers can render aggregate diagnostics next to export
 * warnings.
 */
export function exportSchema(
  source: string,
  options: HostOptions,
  exportOptions: SchemaExportOptions = {},
): { hostResult: HostResult; exportResult: SchemaExportResult } {
  const hostResult = validateDocument(source, options);
  const schema: Schema = { plugins: hostResult.loadedPlugins };
  const exportResult = exportSchemaNative(schema, exportOptions);
  return { hostResult, exportResult };
}

// Re-export commonly-used resolver types so consumers don't double-import.
export type { Reference, Resolution, ResolverFn, ParsedReference } from './Resolver.ts';
