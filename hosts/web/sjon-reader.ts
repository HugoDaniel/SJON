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
import type { Diagnostic, SjonValue, ValidatorReport, WasmDescribe } from './types.ts';

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
// `sjon-binary.wasm` declares `env.sjon_host_invoke_plugin` too — its
// closure reaches `wasm_plugin_invoker.zig`, which is built with
// `wasm_plugin_host = true` (`build.zig`) — so the stub is required
// there, not merely tolerated: instantiating without it throws. It never
// declares `sjon_host_resolve`, which is why passing both is the shape
// that works for either artifact.
//
// The read-only artifact still cannot reach a provider-backed cross-ref:
// `sjon_validate_binary` is hardwired to `core_schema`, so no user schema
// (and hence no `(cross-ref … :provider …)`) is ever in scope there. The
// stub answering 0 is what makes that a clean failure rather than a trap
// if anything ever does call through. See `src/ProviderExtraction.zig`'s
// header for the read-side descope.
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
   * `(srcPtr, srcLen, optsPtr, optsLen) -> ?[*]u8`. The single two-buffer
   * marshaller for both the reader exports and `SjonHost`'s host-export
   * calls; {@link _callBytesN} is the general form under it.
   */
  _callBytesTwo(fnName: string, a: Uint8Array, b: Uint8Array): Uint8Array {
    return this._callBytesN(fnName, [a, b]);
  }

  /**
   * The general form: `(p1, n1, p2, n2, …) -> ?[*]u8`. Every buffer is
   * copied in, the framed result is copied out, and every WASM allocation
   * is released before this returns — including on the throwing path,
   * which is why the pointers are collected before the call rather than
   * allocated inline in the argument list.
   *
   * `sjon_alloc(0)` returns null, so an empty buffer gets a 1-byte
   * reservation; its length arg stays 0, so no bytes are read from the
   * reserved slot and it only keeps the pointer well-formed.
   */
  _callBytesN(fnName: string, parts: readonly Uint8Array[]): Uint8Array {
    const alloc = this.exports['sjon_alloc'] as (n: number) => number;
    const ptrs: number[] = [];
    const allocLens: number[] = [];
    try {
      for (const part of parts) {
        const allocLen = part.length || 1;
        const ptr = alloc(allocLen);
        if (ptr === 0) throw new Error('sjon_alloc returned null (OOM in WASM)');
        ptrs.push(ptr);
        allocLens.push(allocLen);
        if (part.length > 0) new Uint8Array(this.memory.buffer, ptr, part.length).set(part);
      }
      const args: number[] = [];
      for (const [i, part] of parts.entries()) args.push(ptrs[i] as number, part.length);
      const fn = this.exports[fnName] as (...a: number[]) => number;
      const { ok, payload } = this._readFramed(fn(...args));
      if (!ok) throw new SjonWasmError(fnName, decoder.decode(payload));
      return payload;
    } finally {
      for (const [i, ptr] of ptrs.entries()) this._free(ptr, allocLens[i] as number);
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
 * How an applied edit reaches the output.
 *
 * `'reprint'` prints the whole edited tree, so layout is the printer's
 * decision on every run. `'preserve'` replaces one span per action and
 * leaves every other byte alone.
 */
export type SjonEditLayout = 'reprint' | 'preserve';
export interface SjonEditOptions {
  layout?: SjonEditLayout;
}

/** The empty options blob: `sjon_apply_edits` reads no options from it. */
const EMPTY_BYTES = new Uint8Array(0);

/**
 * A half-open byte range `[start, end)`, the unit every span SJON hands a
 * host is in. Not UTF-16 code units: a document past ASCII counts
 * differently in the two, so convert at the editor boundary.
 */
export type SjonByteSpan = readonly [start: number, end: number];

/**
 * One step of a §11.2 path: a string names a form's keyword value, a
 * number names a positional child of a form or an element of a vector.
 */
export type SjonPathStep = string | number;

/**
 * Where a node is, in the two fields an edit action already takes, plus
 * the two an editor wants for drawing.
 *
 * An address is where a node is, not which node it is. Insert a sibling
 * before the target and the same address names a different node, so
 * re-derive addresses from the document that comes back after a batch.
 */
/**
 * One row of {@link SjonNodeTable}: an addressable node, where it is, and
 * where its bytes are.
 *
 * A `:key value` pair gets no row. §11.2 addresses a pair's *value*, so
 * the pair has no address of its own; its key span rides on the value's
 * row as {@link keySpan}.
 */
export interface SjonNodeRow {
  /** This row's index in the table, equal to its position in `nodes`. */
  readonly i: number;
  /** The row index of the container this node sits in, `-1` for a root. */
  readonly parent: number;
  /** Which root of the document this node is under. */
  readonly root: number;
  /**
   * This row's own §11.2 path step from its parent, `null` for a root.
   * The chain of these up the `parent` links, reversed, is the path an
   * edit action takes.
   */
  readonly seg: SjonPathStep | null;
  /** The node's tag — `form`, `number`, `string`, `symbol`, and so on. */
  readonly kind: string;
  /** The node's own bytes. */
  readonly span: SjonByteSpan;
  /** A form's head bytes. Absent on every other kind. */
  readonly head_span?: SjonByteSpan;
  /** The `:key` bytes of the pair this node is the value of. */
  readonly key_span?: SjonByteSpan;
}

/**
 * Every addressable node of one document, plus the diagnostics from the
 * same parse.
 *
 * Rows are pre-order: a parent always precedes its children and siblings
 * are in source order. So the innermost node containing a byte is the
 * *last* row whose span contains it, which is what makes hit-testing a
 * scan in JS rather than a call back into WASM per pointer move.
 */
export interface SjonNodeTable {
  readonly nodes: readonly SjonNodeRow[];
  readonly diagnostics: readonly Diagnostic[];
}

export interface SjonAddress {
  /** Which root of the document, indexing the forest left to right. */
  readonly root: number;
  /** The §11.2 path from that root down to the node. */
  readonly path: readonly SjonPathStep[];
  /** The node's own bytes. */
  readonly span: SjonByteSpan;
  /** The node's tag — `form`, `number`, `string`, `symbol`, and so on. */
  readonly kind: string;
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
   * Query a pattern document over the half-open tick window
   * `[begin, end)` with RNG `seed`. Returns the framed SJON text — a
   * `(haps …)` form on success, or `(diagnostics …)` when the query
   * collected any (e.g. `pattern_tick_overflow`). Tick args cross the
   * i64 ABI boundary as BigInt.
   */
  queryPattern(source: string, begin: number, end: number, seed: number): string {
    const input = encoder.encode(source);
    const inPtr = this._alloc(input);
    try {
      const fn = this.exports['sjon_query_pattern'] as (
        p: number,
        n: number,
        b: bigint,
        e: bigint,
        s: bigint,
      ) => number;
      const ptr = fn(inPtr, input.length, BigInt(begin), BigInt(end), BigInt(seed));
      const { ok, payload } = this._readFramed(ptr);
      if (!ok) throw new SjonWasmError('sjon_query_pattern', decoder.decode(payload));
      return decoder.decode(payload);
    } finally {
      this._free(inPtr, input.length);
    }
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
   * in a single WASM pass (`sjon_apply_edits`). Equivalent to threading
   * `applyEdit`'s output through each action, but one round-trip instead
   * of N. Batches are all-or-nothing — a failing action throws
   * `SjonWasmError` (carrying the Zig error name) and nothing is returned.
   *
   * `options.layout` chooses what comes back. `'reprint'` (the default,
   * and what {@link applyEdit} always does) is the whole document
   * re-printed in `.full` mode: trivia outside the edit survives, but line
   * breaks and alignment are the printer's decision on every run.
   * `'preserve'` splices instead — one span replaced per action, every
   * other byte the author's, comments and column alignment included.
   */
  applyEdits(source: string, actions: readonly object[], options?: SjonEditOptions): string {
    const bytes = this._callBytesN('sjon_apply_edits', [
      encoder.encode(source),
      encoder.encode(JSON.stringify(actions)),
      options ? encoder.encode(JSON.stringify(options)) : EMPTY_BYTES,
    ]);
    return decoder.decode(bytes);
  }

  /**
   * Address the node at `[start, end)` — the innermost node containing
   * that byte range, as `{root, path, span, kind}`, or `null` when the
   * range is inside no root.
   *
   * `root` and `path` are an action's two fields verbatim, so what comes
   * back can be handed straight to {@link applyEdits}. Pass `start ===
   * end` for a caret.
   *
   * A range covering a whole `:key value` pair answers the *enclosing
   * form*, because §11.2 addresses a pair's value and an edit over the
   * pair itself is a `set_keyword` on the form.
   *
   * Offsets are UTF-8 bytes. Answers on the partial tree a recovery
   * leaves behind, so a document mid-keystroke still has addresses; call
   * {@link validate} to learn whether it parsed.
   *
   * Prefer {@link nodeTable} when you want more than one answer per
   * revision — a table is scanned in JS with no further call in.
   */
  addressOfSpan(source: string, start: number, end: number): SjonAddress | null {
    const input = encoder.encode(source);
    const inPtr = this._alloc(input);
    try {
      const fn = this.exports['sjon_address_of_span'] as (
        p: number,
        n: number,
        s: number,
        e: number,
      ) => number;
      const { ok, payload } = this._readFramed(fn(inPtr, input.length, start, end));
      const text = decoder.decode(payload);
      if (!ok) throw new SjonWasmError('sjon_address_of_span', text);
      return JSON.parse(text) as SjonAddress | null;
    } finally {
      this._free(inPtr, input.length);
    }
  }

  /**
   * Every addressable node of `source`, flat and in pre-order, with the
   * parse diagnostics beside it. One call per revision answers all three
   * of an editor's questions: decorate every literal, hit-test a
   * coordinate, and address the node a gesture lands on.
   *
   * Build a path with {@link pathOfRow}; find a row under a byte with
   * {@link rowContaining}. Offsets are UTF-8 bytes.
   *
   * Rows come back for a document that does not parse too — read
   * `diagnostics` to learn whether that is what you have. That is
   * deliberate: the revision in the middle of a keystroke is the one
   * whose addresses an editor wants.
   */
  nodeTable(source: string): SjonNodeTable {
    return this._callJson('sjon_node_table', encoder.encode(source)) as SjonNodeTable;
  }
}

/**
 * The §11.2 path of `row`, walked up the table's `parent` links. Pair it
 * with `row.root` and the two are an edit action's `path` and `root`.
 */
export function pathOfRow(table: SjonNodeTable, row: SjonNodeRow): SjonPathStep[] {
  const steps: SjonPathStep[] = [];
  let at: SjonNodeRow | undefined = row;
  while (at) {
    if (at.seg !== null) steps.push(at.seg);
    at = at.parent < 0 ? undefined : table.nodes[at.parent];
  }
  return steps.reverse();
}

/**
 * The innermost row whose span contains `[start, end)` — pass `start ===
 * end` for a caret — or `undefined` when the range is inside no root.
 *
 * The same rule `sjon_address_of_span` applies WASM-side: narrowest
 * containing span wins, and a tie goes to the later row, which pre-order
 * makes the deeper one. Use this to hit-test without calling in.
 */
export function rowContaining(
  table: SjonNodeTable,
  start: number,
  end: number = start,
): SjonNodeRow | undefined {
  let best: SjonNodeRow | undefined;
  let bestWidth = Number.POSITIVE_INFINITY;
  for (const row of table.nodes) {
    if (row.span[0] > start || row.span[1] < end) continue;
    const width = row.span[1] - row.span[0];
    if (width > bestWidth) continue;
    best = row;
    bestWidth = width;
  }
  return best;
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
