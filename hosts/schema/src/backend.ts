// Validate backend — the injected seam between the host-independent
// builder and a concrete SJON engine (WASM via `hosts/web`, or the
// native validator in `hosts/typescript-parity`).
//
// The builder serializes a schema to canonical `(plugin …)` manifest
// text (`serialize.ts`); a backend turns that text + data into
// diagnostics, and — where it can — projects validated SJON to JSON
// (`toJson`) or a JS value to SJON (`fromValue`). Keeping the surface
// this small means a host adapter is a dozen lines: map the host's
// richer `HostResult` onto `ValidateOutcome` and forward the codec
// calls it already has.

// Type-only — `edit.ts` is the leaf and never imports back, so this is fully
// erasable and introduces no runtime cycle.
import { FORM_KEY, NS_KEY } from './discriminators.ts';
import type { EditAction } from './edit.ts';
import { isFormObject, isRecord } from './internal.ts';

/**
 * One diagnostic, reduced to the cross-host-stable fields. Mirrors the
 * intersection of `hosts/web` `HostDiagnostic` and
 * `hosts/typescript-parity` `HostDiagnostic` — the `code` strings are
 * pinned by `Ast.Diagnostic.Code` in the Zig core.
 */
export interface BackendDiagnostic {
  readonly code: string;
  readonly severity: 'err' | 'warning';
  readonly message: string;
  readonly path?: readonly string[];
  readonly span?: { readonly start: number; readonly end: number };
  readonly phase?: string;
}

/** Result of a `validate` call: the flat diagnostic stream. */
export interface ValidateOutcome {
  readonly diagnostics: readonly BackendDiagnostic[];
}

/**
 * The engine the builder drives. `validate` is mandatory; `toJson` /
 * `fromValue` / `exportSchema` are capability flags — a backend that
 * lacks one disables the matching ergonomic (`.parse` needs `toJson`,
 * `.parseValue` needs `fromValue`, `.toDts` needs `exportSchema`).
 */
export interface ValidateBackend {
  /** Validate a full document (manifest text + data) and return diagnostics. */
  validate(source: string): ValidateOutcome;
  /** Project SJON text to its canonical JSON shape (`{$form,$ns,…}`). WASM-only. */
  toJson?(source: string): unknown;
  /** Render a JS value as SJON text (inverse of `toJson`). WASM-only (`sjon_from_json`). */
  fromValue?(value: unknown): string;
  /** Export the schema declared in `source` to a TypeScript `.d.ts`. */
  exportSchema?(source: string): { readonly tsTypes: string | null };
  /**
   * Apply one structural {@link EditAction} to `source` and return the
   * re-printed `.full` (trivia-preserving) SJON text. WASM-only — the engine is
   * a Zig printer, so a validation-only backend (native TS) cannot edit. Throws
   * on a bad path / invalid action; `applyOne` remaps that to `SjonEditError`.
   */
  applyEdit?(source: string, action: EditAction): string;
  /**
   * Batched counterpart to {@link applyEdit}: apply `actions` left-to-right
   * in a single engine pass. WASM-only and optional — when absent,
   * {@link applyAll} falls back to a per-action {@link applyEdit} fold, so
   * a backend may implement just `applyEdit`. Observably identical to that
   * fold; only the engine round-trips collapse. Throws on a bad path /
   * invalid action.
   *
   * `options.layout` chooses what comes back, defaulting to `'reprint'`
   * (the whole document re-printed in `.full` mode, which is what
   * {@link applyEdit} always does). `'preserve'` replaces one span per
   * action and leaves every other byte as the author wrote it.
   */
  applyEdits?(source: string, actions: readonly EditAction[], options?: EditOptions): string;
}

/** How an applied edit reaches the output. Mirrors `Edit.Layout`. */
export type EditLayout = 'reprint' | 'preserve';

/** Tunables for {@link ValidateBackend.applyEdits}. */
export interface EditOptions {
  readonly layout?: EditLayout;
}

/** Thrown by `.parse` / `.parseValue` when any `err`-severity diagnostic fires. */
export class SjonValidationError extends Error {
  readonly diagnostics: readonly BackendDiagnostic[];

  constructor(diagnostics: readonly BackendDiagnostic[]) {
    const errs = diagnostics.filter((d) => d.severity === 'err');
    const head = errs[0];
    const summary = head ? `${head.code}: ${head.message}` : 'validation failed';
    const more = errs.length > 1 ? ` (+${errs.length - 1} more)` : '';
    super(`SJON validation failed — ${summary}${more}`);
    this.name = 'SjonValidationError';
    this.diagnostics = diagnostics;
  }

  /** Only the `err`-severity diagnostics — the ones that caused the throw. */
  get errors(): readonly BackendDiagnostic[] {
    return this.diagnostics.filter((d) => d.severity === 'err');
  }
}

/** Discriminated result of the `safe*` parse variants. */
export type SafeParseResult<T> =
  | { readonly success: true; readonly data: T }
  | { readonly success: false; readonly error: SjonValidationError };

/**
 * Thrown by the edit surface when the engine rejects an `applyEdit` (bad path,
 * invalid action, …). `code` is the engine's error name (e.g. `"PathNotFound"`,
 * `"InvalidJson"`) duck-typed off the backend error, or `"EditFailed"` when the
 * backend threw something un-named. Mirrors `SjonValidationError`.
 */
export class SjonEditError extends Error {
  readonly code: string;
  readonly action: EditAction;

  constructor(code: string, action: EditAction, cause?: unknown) {
    super(
      `SJON edit failed — ${code} (op: ${action.op})`,
      cause !== undefined ? { cause } : undefined,
    );
    this.name = 'SjonEditError';
    this.code = code;
    this.action = action;
  }
}

/** Discriminated result of the `safe*` edit variants — the re-printed text or the error. */
export type SafeEditResult =
  | { readonly success: true; readonly source: string }
  | { readonly success: false; readonly error: SjonEditError };

/** Per-call override of the registered default backend. */
export interface ParseOptions {
  readonly backend?: ValidateBackend;
}

/** Options for `.toDts()` (reserved for future target/layout switches). */
export interface ToDtsOptions {
  readonly backend?: ValidateBackend;
}

// ---------------------------------------------------------------------------
// Default-backend registry. Zod-style ergonomics: register once, then
// `Form.parse(text)` works without threading a backend through every call.
// Module-global, but each host's test process is isolated, so this is a
// dependency-injection setter, not shared cross-host state.
// ---------------------------------------------------------------------------

let defaultBackend: ValidateBackend | null = null;

/** Register (or clear, with `null`) the backend `.parse`/`.validate` use by default. */
export function useBackend(backend: ValidateBackend | null): void {
  defaultBackend = backend;
}

/** The currently-registered default backend, or `null`. */
export function currentBackend(): ValidateBackend | null {
  return defaultBackend;
}

/** Resolve the backend for a call: explicit override → default → throw. */
export function requireBackend(explicit?: ValidateBackend): ValidateBackend {
  const backend = explicit ?? defaultBackend;
  if (!backend) {
    throw new Error(
      'SJON schema: no validate backend registered. Call useBackend(backend) ' +
        '(or `s.use(backend)`) before parse/validate, or pass `{ backend }` in options.',
    );
  }
  return backend;
}

/** A backend known to support editing — `applyEdit` is non-optional. */
export type EditBackend = ValidateBackend & {
  applyEdit: NonNullable<ValidateBackend['applyEdit']>;
};

/**
 * Resolve a backend for an *edit* call and assert it can edit. Like
 * `requireBackend`, but fails with a clear, actionable message when `applyEdit`
 * is absent — editing is WASM-gated (the engine is a Zig printer).
 */
export function requireEditBackend(explicit?: ValidateBackend): EditBackend {
  const backend = requireBackend(explicit);
  if (!backend.applyEdit) {
    throw new Error(
      'SJON schema: backend has no `applyEdit` — editing is WASM-gated. Use ' +
        '`createWasmBackend(host)`; the native TS backend has no edit engine.',
    );
  }
  return backend as EditBackend;
}

// ---------------------------------------------------------------------------
// Parse glue — shared by every FormNode. Takes already-serialized manifest
// text so it needs no knowledge of the builder IR.
// ---------------------------------------------------------------------------

function errSeverity(diagnostics: readonly BackendDiagnostic[]): boolean {
  return diagnostics.some((d) => d.severity === 'err');
}

/**
 * Stamp `$ns`/`$form` onto a `toJson` projection. The canonical JSON only
 * carries `$ns` when the source form was namespace-qualified
 * (`(ns/head …)`); a bare `(head …)` validates fine but projects without
 * it. Since the schema fixes both, we fill them in so the returned object
 * matches `infer<T>`.
 */
function stampForm(json: unknown, ns: string, head: string): Record<string, unknown> {
  let obj: unknown = json;
  if (Array.isArray(json)) {
    obj =
      json.find((r) => isFormObject(r) && r[FORM_KEY] === head) ??
      json.find((r) => isRecord(r) && !isPluginRoot(r)) ??
      json[0];
  }
  const record: Record<string, unknown> = isRecord(obj) ? { ...obj } : {};
  record[FORM_KEY] = head;
  record[NS_KEY] = ns;
  return record;
}

function isPluginRoot(r: unknown): boolean {
  return isRecord(r) && (r[FORM_KEY] === 'plugin' || r[FORM_KEY] === 'use-plugin');
}

/** Validate `manifest + source`, returning the validated data on success. */
export function runParse<T>(
  manifest: string,
  source: string,
  ns: string,
  head: string,
  backend: ValidateBackend,
): SafeParseResult<T> {
  const document = `${manifest}\n\n${source}`;
  const outcome = backend.validate(document);
  if (errSeverity(outcome.diagnostics)) {
    return { success: false, error: new SjonValidationError(outcome.diagnostics) };
  }
  if (!backend.toJson) {
    throw new Error(
      'SJON schema: backend cannot materialize data from text (no `toJson`). ' +
        'Use `.parseValue(object)` or a WASM-backed backend for `.parse(text)`.',
    );
  }
  const data = stampForm(backend.toJson(source), ns, head) as T;
  return { success: true, data };
}

/** Validate a JS value by serializing it to SJON text first. */
export function runParseValue<T>(
  manifest: string,
  value: T,
  backend: ValidateBackend,
): SafeParseResult<T> {
  if (!backend.fromValue) {
    throw new Error(
      'SJON schema: backend cannot serialize a JS value (no `fromValue`). ' +
        '`.parseValue` needs a WASM-backed backend (`sjon_from_json`).',
    );
  }
  const source = backend.fromValue(value);
  const document = `${manifest}\n\n${source}`;
  const outcome = backend.validate(document);
  if (errSeverity(outcome.diagnostics)) {
    return { success: false, error: new SjonValidationError(outcome.diagnostics) };
  }
  return { success: true, data: value };
}

// ---------------------------------------------------------------------------
// Edit glue — apply one or many EditActions over a backend, remapping the
// engine's thrown error to a typed SjonEditError. Shared by every FormNode.
// ---------------------------------------------------------------------------

/** Duck-type the engine error's name (e.g. `SjonWasmError.errorName`); never imports it. */
function editErrorCode(err: unknown): string {
  if (
    err !== null &&
    typeof err === 'object' &&
    'errorName' in err &&
    typeof (err as { errorName: unknown }).errorName === 'string'
  ) {
    return (err as { errorName: string }).errorName;
  }
  return 'EditFailed';
}

/** Apply a single edit; gate the backend and remap a thrown engine error to SjonEditError. */
export function applyOne(source: string, action: EditAction, backend: ValidateBackend): string {
  const { applyEdit } = requireEditBackend(backend);
  try {
    return applyEdit(source, action);
  } catch (err) {
    if (err instanceof SjonEditError) throw err;
    throw new SjonEditError(editErrorCode(err), action, err);
  }
}

/**
 * Apply edits left-to-right, threading the re-printed text through each.
 *
 * Fast path: when the backend exposes `applyEdits` (WASM `sjon_apply_edits`),
 * the whole list folds through one parse/print round-trip instead of N. On a
 * failing batch we fall back to the per-action {@link applyOne} fold, which
 * reproduces the error attributed to the exact offending action (the batched
 * engine call returns only an error name, not which action tripped it).
 * Without `applyEdits`, it's the plain per-action fold throughout.
 */
export function applyAll(
  source: string,
  actions: readonly EditAction[],
  backend: ValidateBackend,
): string {
  if (actions.length === 0) return source;
  const { applyEdits } = backend;
  if (applyEdits) {
    try {
      return applyEdits(source, actions);
    } catch {
      // Fall through to the per-action fold for precise error attribution.
      // batched ≡ folded, so the fold reproduces the same failure with the
      // offending action in context (or simply succeeds on a transient error).
    }
  }
  let current = source;
  for (const action of actions) current = applyOne(current, action, backend);
  return current;
}

/** `applyOne`, but a failed edit becomes a `{success:false}` result instead of a throw. */
export function safeApplyOne(
  source: string,
  action: EditAction,
  backend: ValidateBackend,
): SafeEditResult {
  try {
    return { success: true, source: applyOne(source, action, backend) };
  } catch (err) {
    if (err instanceof SjonEditError) return { success: false, error: err };
    throw err; // gate misconfiguration etc. is a programmer error → propagate
  }
}

/** `applyAll`, but a failed edit becomes a `{success:false}` result instead of a throw. */
export function safeApplyAll(
  source: string,
  actions: readonly EditAction[],
  backend: ValidateBackend,
): SafeEditResult {
  try {
    return { success: true, source: applyAll(source, actions, backend) };
  } catch (err) {
    if (err instanceof SjonEditError) return { success: false, error: err };
    throw err;
  }
}
