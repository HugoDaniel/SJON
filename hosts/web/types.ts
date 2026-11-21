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
  /**
   * The symbol a *held* position is spelled with: a value the author has
   * deliberately not filled in yet. When set, a symbol whose text matches is
   * accepted wherever a value may appear, without narrowing on the slot's
   * declared kind or any of its refinements, and registers no cross-ref
   * name. `undefined` (the default) validates exactly as before.
   *
   * The assertion is about the *run* — "this document is being typed" — and
   * is made by whoever calls the host, never by the document: a manifest is
   * loaded because the document said `(use-plugin …)`, so a document-level
   * opt-in would let a document turn off its own type checking.
   *
   * `_` is the conventional spelling. SJON does not police the name: a
   * symbol that collides with one of your own members loses checking on that
   * member, and a string that does not lex as a symbol never matches.
   */
  readonly heldSymbol?: string;
  /**
   * One schema retained by `SjonHost.preload`, borrowed for this call.
   *
   * The handle must have been minted by the same `SjonHost` instance and
   * must not have been disposed; a foreign or disposed handle is refused
   * in JavaScript before it reaches WASM. It composes additively with any
   * `(plugin …)` / `(use-plugin …)` declarations in the document — there
   * is no ambient schema and no handle stacking, so one call borrows at
   * most this one handle.
   *
   * The borrow lasts only for the synchronous call. Disposing the handle
   * (or the host) while one of the host's calls is in flight throws
   * `SchemaInUse`.
   */
  readonly preloaded?: PreloadedSchemaHandle;
}

/**
 * Options accepted by `SjonHost.validateAgainst`.
 *
 * The project fields are deliberately absent: the call composes the
 * manifest string it is given and performs no project discovery, so
 * `projectRoot` / `projectFile` are forced to `null` and
 * `projectDiagnostics` has no channel into a two-source result.
 * `failurePolicy` and `heldSymbol` keep their `HostOptions` meaning and
 * defaults.
 */
export type ValidateAgainstOptions = Pick<HostOptions, 'failurePolicy' | 'heldSymbol'>;

export interface PluginSummary {
  readonly name: string;
  readonly version: string | null;
  readonly formCount: number;
}

/**
 * One compiled schema retained by `SjonHost.preload`.
 *
 * The report members mirror the native `Host.PreloadedSchema` view:
 * `diagnostics` is the flattened `sourceDiagnostics` (input-index aligned,
 * one entry per manifest source) followed by `aggregateDiagnostics`.
 * Manifest content problems are reported here — `hasErrors` does not make
 * the handle unusable, and borrowing a partial handle is an explicit
 * caller decision, matching the native Host.
 *
 * `dispose()` releases the WASM-side schema. It is idempotent, and every
 * handle stays live until it is called or the host is closed with
 * `await using` (`Symbol.asyncDispose` frees every live handle). Using a
 * handle after disposal — or with a different host — is refused in
 * JavaScript; the numeric ID is deliberately not public, because raw IDs
 * carry no owner token across WASM instances.
 *
 * Disposal while one of the host's calls is in flight (for example from
 * inside a resolver callback) throws `SchemaInUse` rather than freeing a
 * schema the borrow is still reading.
 */
export interface PreloadedSchemaHandle {
  readonly hasErrors: boolean;
  readonly diagnostics: readonly HostDiagnostic[];
  readonly sourceDiagnostics: readonly (readonly HostDiagnostic[])[];
  readonly aggregateDiagnostics: readonly HostDiagnostic[];
  readonly loadedPlugins: readonly PluginSummary[];
  dispose(): void;
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

/**
 * One stable lexical parent prefix of an identity: the parent's canonical
 * cross-ref registry and its author-written symbol. Never a `ScopeId`, an
 * AST index, or a byte offset — the same pair names the same scope across
 * revisions.
 */
export interface IdentityScope {
  readonly registry: string;
  readonly symbol: string;
}

/**
 * Where a resolved identity sits in this revision, in the same two fields
 * an edit action takes: `root` indexes the document's roots left to right,
 * and `path` is the §11.2 path from that root (`string` names a keyword
 * value, `number` a positional child or vector element). An address is a
 * position, not an identity: revalidate after an edit rather than carrying
 * one across revisions.
 */
export interface IdentityAddress {
  readonly root: number;
  readonly path: readonly (string | number)[];
}

/**
 * The structural key of an identity row: canonical cross-ref registry,
 * outermost-first stable scope prefixes, and author-written symbol.
 */
interface IdentityKey {
  readonly registry: string;
  readonly scope: readonly IdentityScope[];
  readonly symbol: string;
}

/**
 * One row projected from the validation pass that already ran.
 *
 * The discriminated union on `status` is the safety surface: a consumer
 * that refuses `'ambiguous'` needs no null-check on the resolved arm, and
 * an ambiguous row can never carry a stale first-wins address. An absent
 * `(registry, scope, symbol)` is simply not found — there is no row for
 * it.
 */
export type IdentityRow =
  | (IdentityKey & {
      readonly status: 'resolved';
      readonly address: IdentityAddress;
    })
  | (IdentityKey & {
      readonly status: 'ambiguous';
      readonly address: null;
    });

export interface HostResult {
  readonly diagnostics: readonly HostDiagnostic[];
  readonly loadedPlugins: readonly PluginSummary[];
  readonly materializedDefaults: readonly MaterializedDefault[];
  readonly evaluatedResults: readonly EvalResultEntry[];
  /**
   * Every declared, author-written identity the validation pass saw —
   * deterministic lexical order, empty when none qualify, always present.
   */
  readonly identities: readonly IdentityRow[];
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
