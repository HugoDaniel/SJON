// Cross-module type surface for the Node WASM consumer.
//
// Shapes here mirror what `sjon.wasm` / `sjon-binary.wasm` emit (the
// framed JSON payloads decoded via parseJsonWithBigInt) and what the
// host-side WASM imports speak (Resolution, HostOptions, …). Wire-
// stable: the diagnostic `code` strings are pinned by
// `Ast.Diagnostic.Code` in the Zig core — append, never reorder.

/** A single validator or parser diagnostic with byte-offset span. */
export interface Diagnostic {
  readonly span: { readonly start: number; readonly end: number };
  readonly severity: 'err' | 'warning';
  /**
   * Stable snake_case `Ast.Diagnostic.Code` tag — e.g. `"unknown_form"`,
   * `"arity_mismatch"`. `"unspecified"` for parser diagnostics that have
   * no validator-side code.
   */
  readonly code: string;
  readonly message: string;
}

/** Validator output: parse-time diagnostics + post-parse diagnostics. */
export interface ValidatorReport {
  readonly parse_diagnostics: readonly Diagnostic[];
  readonly diagnostics: readonly Diagnostic[];
}

/** Wire description returned by `describe()`. */
export interface WasmDescribe {
  readonly name: string;
  readonly version: string;
  readonly exports: readonly string[];
  readonly plugins: readonly string[];
}

/**
 * A safe-expression evaluation result, encoded as JSON.
 *
 * `bigint` appears when the WASM payload contains an integer literal
 * whose magnitude exceeds `Number.MAX_SAFE_INTEGER` (encoded by Zig
 * as `Tag.number_i64` or `Tag.number_u64`). Smaller integers and any
 * fractional / exponent value decode to `number`.
 */
export type SjonValue =
  | null
  | boolean
  | number
  | bigint
  | string
  | { $kw: string }
  | readonly SjonValue[];

// ---------------------------------------------------------------------------
// Validating-host surface (mirrors hosts/typescript-parity types)
// ---------------------------------------------------------------------------

export interface Reference {
  readonly name: string;
  readonly explicitPath: string | null;
  readonly version: string | null;
  readonly hash: string | null;
  readonly span: { readonly start: number; readonly end: number };
}

export type Resolution =
  | { readonly kind: 'manifest'; readonly source: string; readonly wasm: Uint8Array | null }
  | { readonly kind: 'failure'; readonly code: string; readonly detail: string };

export type ResolverFn = (ref: Reference) => Resolution;

export type Phase = 'manifest' | 'aggregate' | 'validation';

export interface HostDiagnostic extends Diagnostic {
  readonly phase: Phase;
  readonly path: readonly string[];
  readonly declarationSpan: { readonly start: number; readonly end: number } | null;
}

export interface HostOptions {
  readonly projectRoot: string | null;
  readonly projectFile: string | null;
  readonly projectDiagnostics?: readonly HostDiagnostic[];
  readonly failurePolicy?: 'strict' | 'lenient';
}

export interface PluginSummary {
  readonly name: string;
  readonly version: string | null;
  readonly formCount: number;
}

/**
 * One materialized default for an omitted declared key on a known data
 * form. `path` is `[form-head, key-name]`; `value` is the JSON-encoded
 * `Expr.Value` produced by `wasm_common.appendValue` — numbers stay as
 * JSON numbers, strings as JSON strings, keywords as `{"$kw":"…"}`,
 * vectors as arrays.
 */
export interface MaterializedDefault {
  readonly path: readonly string[];
  readonly key: string;
  readonly origin: 'literal_default' | 'expression_default';
  readonly value: unknown;
}

/**
 * One per top-level `data_forest` form whose head resolved as an
 * expr-func and whose `Expr.eval` returned a value. `value` is the
 * JSON-encoded `Expr.Value` — same shape as `MaterializedDefault.value`.
 */
export interface EvalResultEntry {
  readonly index: number;
  readonly value: unknown;
}

export interface HostResult {
  readonly diagnostics: readonly HostDiagnostic[];
  readonly loadedPlugins: readonly PluginSummary[];
  readonly materializedDefaults: readonly MaterializedDefault[];
  readonly evaluatedResults: readonly EvalResultEntry[];
}

/**
 * Result of `hostEvalExpr`. `value` is the JSON-encoded `Expr.Value`
 * (see `MaterializedDefault.value` for the shape) when evaluation
 * succeeded; `null` when the document had no data form, multiple data
 * forms, pre-eval err-severity diagnostics, or a runtime failure.
 */
export interface HostEvalResult {
  readonly value: unknown;
  readonly diagnostics: readonly HostDiagnostic[];
  readonly loadedPlugins: readonly PluginSummary[];
}

// ---------------------------------------------------------------------------
// Schema-export surface (exportSchema return shape — mirrors
// common.writeExportSchemaResult / SchemaExport.zig)
// ---------------------------------------------------------------------------

export type ExportSchemaTarget = 'json-schema' | 'typescript' | 'both' | 'intermediate';
export type ExportSchemaLayout = 'aggregated' | 'per-plugin';
export type ExportSchemaDraft = '2020-12';

export interface ExportSchemaWarning {
  readonly severity: 'err' | 'warning';
  readonly code: string;
  readonly message: string;
  readonly plugin: string | null;
  readonly form: string | null;
  readonly key: string | null;
  readonly kind: string | null;
}

export interface ExportSchemaArtifacts {
  readonly jsonSchema: string | null;
  readonly tsTypes: string | null;
  readonly intermediate: string | null;
}

export interface ExportSchemaPerPluginEntry extends ExportSchemaArtifacts {
  readonly plugin: string;
}

export interface ExportSchemaResult {
  readonly layout: 'aggregated' | 'per-plugin';
  readonly hostDiagnostics: readonly HostDiagnostic[];
  readonly loadedPlugins: readonly PluginSummary[];
  readonly warnings: readonly ExportSchemaWarning[];
  readonly aggregated: ExportSchemaArtifacts | null;
  readonly perPlugin: readonly ExportSchemaPerPluginEntry[] | null;
}
