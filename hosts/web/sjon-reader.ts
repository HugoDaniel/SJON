// Node.js / browser consumer of the SJON WASM artifacts.
//
// Two classes:
//
//   * `SjonEncoder` — wraps the kitchen-sink `sjon.wasm`. Use it to turn
//     SJON text into Binary IR bytes (and to validate / evaluate text
//     directly when you have it).
//   * `SjonReader`  — wraps the read-only `sjon-binary.wasm`. Use it
//     when you only need to *consume* pre-baked Binary IR.
//
// Both classes share a common WASM-marshalling base; the framed-output
// protocol is documented in `src/wasm.zig`. Every `[u32 ok][u32 len]
// [u8 payload…]` buffer is read into a fresh JS `Uint8Array` and the
// underlying WASM allocation is freed before this module returns.

// `node:fs` is loaded on-demand inside `_instantiate` so this module
// can be imported directly in a browser (where the top-level
// `node:fs` specifier would otherwise blow up CORS / module
// resolution). The browser entry points — `loadFromBytes` everywhere
// — never reach the import.

import { parseJsonWithBigInt } from './parseJsonWithBigInt.ts';
import type { SjonValue, ValidatorReport, WasmDescribe } from './types.ts';

const HEADER_BYTES = 8;
const decoder = new TextDecoder();
const encoder = new TextEncoder();

// Default WASM imports for `sjon.wasm`. Two stubs:
//
//   * `sjon_host_resolve` — bound only when `sjon_host_validate_document`
//     runs with `hasResolver=true`; encoder/reader paths never reach it.
//     Returning 0 (null pointer) makes the Zig adapter emit
//     `unresolved_plugin` without crashing.
//   * `sjon_host_invoke_plugin` — bound only when an `:impl "wasm:..."`
//     plugin function is actually called. Encoder/reader paths never
//     reach it; the stub returns 0 so `wasm_plugin_invoker.zig` surfaces
//     `PluginFuncAllocFailed` if anything ever does call through here
//     instead of crashing the WASM module.
//
// `sjon-binary.wasm` doesn't import anything from `env`, so the field
// is harmless when ignored.
const DEFAULT_IMPORTS: WebAssembly.Imports = Object.freeze({
  env: Object.freeze({
    sjon_host_resolve: () => 0,
    sjon_host_invoke_plugin: () => 0,
  }),
}) as WebAssembly.Imports;

/**
 * Shared WASM marshalling base. Subclassed by SjonEncoder / SjonReader
 * (in this module) and by `SjonHost` (in `./SjonHost.ts`). Exported so
 * downstream subclasses can reach the protected `_alloc` / `_free` /
 * `_readFramed` helpers without re-implementing the framing protocol.
 *
 * Lifetime: the underlying `WebAssembly.Instance`'s linear memory grows
 * on demand. We never hold pointers across calls, and every buffer we
 * receive from WASM is copied into JS-owned memory before being
 * returned to the caller, so caller code never has to worry about
 * memory invalidation.
 */
export class SjonWasm {
  readonly exports: Record<string, WebAssembly.ExportValue>;
  readonly memory: WebAssembly.Memory;

  /**
   * Instantiate the artifact at `path`. The `sjon.wasm` artifact (D5)
   * imports `env.sjon_host_resolve` for `(use-plugin …)` resolution
   * via the `SjonHost` wrapper; encoder / reader callers don't bind a
   * real resolver so we default to a no-op stub that returns null
   * (which the Zig adapter treats as "resolver missing"). Callers that
   * need the real resolver bridge — `SjonHost.load` — pass their own
   * imports object.
   */
  static async _instantiate(
    path: string | URL,
    imports: WebAssembly.Imports = DEFAULT_IMPORTS,
  ): Promise<WebAssembly.Instance> {
    const { promises: fs } = await import('node:fs');
    const bytes = await fs.readFile(path);
    return SjonWasm._instantiateBytes(bytes, imports);
  }

  /**
   * Browser-side counterpart to `_instantiate`. Takes already-fetched
   * wasm bytes (e.g. from `fetch(url).then(r => r.arrayBuffer())`) so
   * the loader chain doesn't have to touch `node:fs`.
   */
  static async _instantiateBytes(
    bytes: BufferSource,
    imports: WebAssembly.Imports = DEFAULT_IMPORTS,
  ): Promise<WebAssembly.Instance> {
    const { instance } = await WebAssembly.instantiate(bytes, imports);
    return instance;
  }

  constructor(instance: WebAssembly.Instance) {
    this.exports = instance.exports as Record<string, WebAssembly.ExportValue>;
    this.memory = instance.exports['memory'] as WebAssembly.Memory;
  }

  /**
   * Allocate `bytes.length` in WASM memory and copy `bytes` into it.
   * Returns the pointer. Caller MUST `_free(ptr, bytes.length)`.
   */
  _alloc(bytes: Uint8Array): number {
    if (bytes.length === 0) return 0;
    const alloc = this.exports['sjon_alloc'] as (n: number) => number;
    const ptr = alloc(bytes.length);
    if (ptr === 0) throw new Error('sjon_alloc returned null (OOM in WASM)');
    new Uint8Array(this.memory.buffer, ptr, bytes.length).set(bytes);
    return ptr;
  }

  _free(ptr: number, len: number): void {
    if (len === 0) return;
    const free = this.exports['sjon_free'] as (p: number, n: number) => void;
    free(ptr, len);
  }

  /**
   * Decode a framed output buffer at `ptr`, copy its payload into a
   * fresh JS Uint8Array, and free the WASM-side buffer.
   */
  _readFramed(ptr: number): { ok: boolean; payload: Uint8Array } {
    if (ptr === 0) throw new Error('WASM returned a null pointer (OOM)');
    // The memory buffer can be reallocated underneath us if a future
    // call grows linear memory; we read the header and copy the
    // payload immediately to insulate the caller.
    const headerView = new DataView(this.memory.buffer, ptr, HEADER_BYTES);
    const ok = headerView.getUint32(0, true);
    const len = headerView.getUint32(4, true);
    const src = new Uint8Array(this.memory.buffer, ptr + HEADER_BYTES, len);
    const copy = new Uint8Array(len);
    copy.set(src);
    this._free(ptr, HEADER_BYTES + len);
    return { ok: ok === 1, payload: copy };
  }

  /** Call a no-input WASM function and JSON-parse the framed output. */
  _callJsonNullary(fnName: string): unknown {
    const fn = this.exports[fnName] as () => number;
    const ptr = fn();
    const { ok, payload } = this._readFramed(ptr);
    const text = decoder.decode(payload);
    if (!ok) throw new SjonWasmError(fnName, text);
    return parseJsonWithBigInt(text);
  }

  /** Call a one-buffer-in WASM function and return raw bytes. */
  _callBytes(fnName: string, input: Uint8Array): Uint8Array {
    const inPtr = this._alloc(input);
    try {
      const fn = this.exports[fnName] as (p: number, n: number) => number;
      const ptr = fn(inPtr, input.length);
      const { ok, payload } = this._readFramed(ptr);
      if (!ok) throw new SjonWasmError(fnName, decoder.decode(payload));
      return payload;
    } finally {
      this._free(inPtr, input.length);
    }
  }

  /** Call a one-buffer-in WASM function and JSON-parse the framed output. */
  _callJson(fnName: string, input: Uint8Array): unknown {
    const bytes = this._callBytes(fnName, input);
    return parseJsonWithBigInt(decoder.decode(bytes));
  }

  /**
   * Two-buffer counterpart to `_callBytes`. The WASM signature is
   * `(srcPtr, srcLen, optsPtr, optsLen) -> ?[*]u8`; both buffers are
   * copied in, the framed result is copied out, and all three WASM
   * allocations are released before this returns.
   */
  _callBytesTwo(fnName: string, a: Uint8Array, b: Uint8Array): Uint8Array {
    const aPtr = this._alloc(a);
    let bPtr = 0;
    try {
      bPtr = this._alloc(b);
      const fn = this.exports[fnName] as (p1: number, n1: number, p2: number, n2: number) => number;
      const ptr = fn(aPtr, a.length, bPtr, b.length);
      const { ok, payload } = this._readFramed(ptr);
      if (!ok) throw new SjonWasmError(fnName, decoder.decode(payload));
      return payload;
    } finally {
      this._free(aPtr, a.length);
      if (bPtr !== 0) this._free(bPtr, b.length);
    }
  }

  /**
   * Same shape as `_callBytes`, but exposes the framed `ok` flag so
   * callers that *expect* errors (e.g. testing diagnostics on a
   * deliberately-broken input) don't have to throw / catch.
   */
  _callRaw(fnName: string, input: Uint8Array): { ok: boolean; payload: Uint8Array } {
    const inPtr = this._alloc(input);
    try {
      const fn = this.exports[fnName] as (p: number, n: number) => number;
      const ptr = fn(inPtr, input.length);
      return this._readFramed(ptr);
    } finally {
      this._free(inPtr, input.length);
    }
  }
}

/**
 * Error thrown when a WASM call returns `ok=0`. The framed payload is
 * the Zig error name (e.g. `"InvalidEncoding"`, `"MultipleRoots"`).
 */
export class SjonWasmError extends Error {
  readonly fnName: string;
  readonly errorName: string;

  constructor(fnName: string, errorName: string) {
    super(`${fnName}: ${errorName}`);
    this.name = 'SjonWasmError';
    this.fnName = fnName;
    this.errorName = errorName;
  }
}

export type ToJsonMode = 'canonical' | 'compact' | 'full';
export interface ToJsonOptions {
  mode?: ToJsonMode;
}

/**
 * Kitchen-sink consumer of `sjon.wasm`. Has parse / print / validate /
 * eval / json / edit / binary exports — see `src/wasm.zig` for the full
 * list. Most apps that only *consume* binaries should prefer
 * `SjonReader` for the smaller artifact; reach for `SjonEncoder` when
 * you also need to take SJON text in.
 */
export class SjonEncoder extends SjonWasm {
  static async load(path: string | URL): Promise<SjonEncoder> {
    return new SjonEncoder(await SjonWasm._instantiate(path));
  }

  /**
   * Browser-side load. Hand in the WASM bytes you've already fetched
   * (e.g. via `fetch(url).then(r => r.arrayBuffer())`); no `node:fs`
   * needed.
   */
  static async loadFromBytes(bytes: BufferSource): Promise<SjonEncoder> {
    return new SjonEncoder(await SjonWasm._instantiateBytes(bytes));
  }

  /** Metadata about the loaded artifact. */
  describe(): WasmDescribe {
    return this._callJsonNullary('sjon_describe') as WasmDescribe;
  }

  /** Encode SJON source text to Binary IR bytes. */
  toBinary(source: string): Uint8Array {
    return this._callBytes('sjon_to_binary', encoder.encode(source));
  }

  /** Decode Binary IR bytes back to canonical SJON source text. */
  fromBinary(binary: Uint8Array): string {
    return decoder.decode(this._callBytes('sjon_from_binary', binary));
  }

  /** Validate SJON source text against the built-in `core` schema. */
  validate(source: string): ValidatorReport {
    return this._callJson('sjon_validate', encoder.encode(source)) as ValidatorReport;
  }

  /**
   * Evaluate a single-root safe-expression source.
   * Throws `SjonWasmError("MultipleRoots")` if `source` parses to
   * more than one root form.
   */
  evalExpr(source: string): SjonValue {
    return this._callJson('sjon_eval_expr', encoder.encode(source)) as SjonValue;
  }

  /**
   * Project an SJON document into JSON. `mode: "compact"` collapses
   * `:kw` / `sym` / `5ms` to plain strings/numbers — convenient for
   * UI rendering. `mode: "canonical"` (default) keeps the round-trip
   * tagging (`{$kw}`, `{$sym}`, `{$num}`, `{$form}`).
   */
  toJson(source: string, opts: ToJsonOptions = {}): unknown {
    const optsBytes = encoder.encode(JSON.stringify(opts));
    const bytes = this._callBytesTwo('sjon_to_json', encoder.encode(source), optsBytes);
    return parseJsonWithBigInt(decoder.decode(bytes));
  }

  /**
   * Inverse of `toJson`: render a JS value (in the canonical JSON shape —
   * `{$form}`, `{$ns}`, `{$kw}`, `{$sym}`, `{$num}`) as canonical SJON
   * source text. Wraps `sjon_from_json` (`Json.fromJson` → `Printer.print`).
   * Throws `SjonWasmError("InvalidJson")` if the value isn't JSON-encodable
   * into a SJON tree.
   */
  fromJson(value: unknown): string {
    return decoder.decode(this._callBytes('sjon_from_json', encoder.encode(JSON.stringify(value))));
  }

  /**
   * Apply a JSON-encoded `Edit` action to `source` and return the
   * re-printed canonical SJON text. The action shape is documented
   * at the top of `src/Edit.zig`:
   *   {op: "set_keyword",      path: [...], key, value}
   *   {op: "remove_keyword",   path: [...], key}
   *   {op: "replace",          path: [...], value}      // path != []
   *   {op: "insert_positional",path: [...], value, index?}
   *   {op: "remove_positional",path: [...], index}
   *
   * `value` is decoded through `Json.fromJson` so canonical tagging
   * (`{$kw}`, `{$sym}`, `{$form}`, `{$num}`) is honored.
   */
  applyEdit(source: string, action: object): string {
    const actionBytes = encoder.encode(JSON.stringify(action));
    const bytes = this._callBytesTwo('sjon_apply_edit', encoder.encode(source), actionBytes);
    return decoder.decode(bytes);
  }

  /**
   * Batched counterpart to {@link applyEdit}: apply `actions` left-to-right
   * in a single WASM parse/print pass (`sjon_apply_edits`) and return the
   * re-printed `.full` SJON text. Equivalent to threading `applyEdit`'s
   * output through each action, but one round-trip instead of N. Batches
   * are all-or-nothing — a failing action throws `SjonWasmError` (carrying
   * the Zig error name) and nothing is returned.
   */
  applyEdits(source: string, actions: readonly object[]): string {
    const actionsBytes = encoder.encode(JSON.stringify(actions));
    const bytes = this._callBytesTwo('sjon_apply_edits', encoder.encode(source), actionsBytes);
    return decoder.decode(bytes);
  }
}

/**
 * Read-only consumer of `sjon-binary.wasm`. Cannot accept SJON text —
 * pair this with `SjonEncoder` (or any other producer of the wire
 * format) when you need to ingest source.
 */
export class SjonReader extends SjonWasm {
  static async load(path: string | URL): Promise<SjonReader> {
    return new SjonReader(await SjonWasm._instantiate(path));
  }

  /** Browser-side load. See `SjonEncoder.loadFromBytes`. */
  static async loadFromBytes(bytes: BufferSource): Promise<SjonReader> {
    return new SjonReader(await SjonWasm._instantiateBytes(bytes));
  }

  /** Metadata about the loaded artifact. */
  describe(): WasmDescribe {
    return this._callJsonNullary('sjon_describe') as WasmDescribe;
  }

  /** Validate Binary IR bytes against the built-in `core` schema. */
  validateBinary(binary: Uint8Array): ValidatorReport {
    return this._callJson('sjon_validate_binary', binary) as ValidatorReport;
  }

  /**
   * As `validateBinary`, but returns `{ok, errorName}` instead of
   * throwing on framed errors. Useful for tests that deliberately
   * feed broken inputs.
   */
  tryValidateBinary(
    binary: Uint8Array,
  ): { ok: true; value: ValidatorReport } | { ok: false; errorName: string } {
    const { ok, payload } = this._callRaw('sjon_validate_binary', binary);
    const text = decoder.decode(payload);
    return ok
      ? { ok: true, value: parseJsonWithBigInt(text) as ValidatorReport }
      : { ok: false, errorName: text };
  }

  /** Evaluate a single-root safe-expression encoded as Binary IR. */
  evalExprBinary(binary: Uint8Array): SjonValue {
    return this._callJson('sjon_eval_expr_binary', binary) as SjonValue;
  }
}

// Re-export the cross-module types from a single entry point so
// consumers can `import { type SjonValue, … } from './sjon-reader.ts'`.
export type {
  Diagnostic,
  ValidatorReport,
  WasmDescribe,
  SjonValue,
  Reference,
  Resolution,
  ResolverFn,
  Phase,
  HostDiagnostic,
  HostOptions,
  PluginSummary,
  MaterializedDefault,
  EvalResultEntry,
  HostResult,
  HostEvalResult,
  ExportSchemaResult,
} from './types.ts';
