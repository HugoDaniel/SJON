// Unit tests for `SjonHost.validateDocument`. Mirrors
// `hosts/typescript-parity/test/host.test.ts` so the WASM-backed host's
// shape stays in sync with the parallel-TS reference. Each Resolution
// variant is exercised through a mock resolver to drive the WASM↔JS
// callback bridge end to end.
//
// D7-exec coverage is in the second half of the file: it points the
// resolver at the checked-in `examples/plugins/double/plugin.wasm`
// fixture and exercises every diagnostic code the executable-plugin
// path can surface (pre-flight + runtime).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { promises as fs } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { SjonHost } from '../SjonHost.ts';
import type { HostDiagnostic, Resolution, ResolverFn } from '../sjon-reader.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const wasmPath = path.join(root, 'zig-out/bin/sjon.wasm');
const doublePluginPath = path.join(root, 'examples/plugins/double/plugin.wasm');

const errs = (diags: readonly HostDiagnostic[]): readonly HostDiagnostic[] =>
  diags.filter((d) => d.severity === 'err');

const codes = (diags: readonly HostDiagnostic[]): string[] => diags.map((d) => d.code);

test('validateDocument: empty source produces no diagnostics', async () => {
  const host = await SjonHost.load(wasmPath);
  const r = host.validateDocument('', { projectRoot: null, projectFile: null });
  assert.equal(r.diagnostics.length, 0);
  assert.equal(r.loadedPlugins.length, 0);
});

test('validateDocument: bare data with no schema → unknown_form', async () => {
  const host = await SjonHost.load(wasmPath);
  const r = host.validateDocument('(widget :name w0)\n', {
    projectRoot: null,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(r.diagnostics)), ['unknown_form']);
  assert.equal(errs(r.diagnostics)[0]!.phase, 'validation');
});

test('validateDocument: inline manifest then data validates cleanly', async () => {
  const host = await SjonHost.load(wasmPath);
  const src = `
(plugin :name probe :version "1.0.0"
  (form :name widget
    (key :name name :type symbol :optional false)))

(widget :name w0)
`;
  const r = host.validateDocument(src, { projectRoot: null, projectFile: null });
  assert.deepEqual(codes(errs(r.diagnostics)), []);
  assert.equal(r.loadedPlugins.length, 1);
  assert.equal(r.loadedPlugins[0]!.name, 'probe');
});

test('validateDocument: inline manifest data error → missing_required_key', async () => {
  const host = await SjonHost.load(wasmPath);
  const src = `
(plugin :name probe :version "1.0.0"
  (form :name widget
    (key :name name :type symbol :optional false)))

(widget)
`;
  const r = host.validateDocument(src, { projectRoot: null, projectFile: null });
  const e = errs(r.diagnostics);
  assert.deepEqual(codes(e), ['missing_required_key']);
  assert.equal(e[0]!.phase, 'validation');
});

test('validateDocument: use-plugin with no resolver → unresolved_plugin', async () => {
  const host = await SjonHost.load(wasmPath);
  const r = host.validateDocument('(use-plugin "missing")\n', {
    projectRoot: null,
    projectFile: null,
  });
  const e = errs(r.diagnostics);
  assert.deepEqual(codes(e), ['unresolved_plugin']);
  assert.equal(e[0]!.phase, 'manifest');
  assert.notEqual(e[0]!.declarationSpan, null);
});

test('validateDocument: mock resolver returning manifest envelope loads + validates', async () => {
  const resolver: ResolverFn = (ref) => {
    assert.equal(ref.name, 'shapes');
    return {
      kind: 'manifest',
      source:
        '(plugin :name shapes :version "1.0.0" (form :name circle (key :name r :type number :optional false)))',
      wasm: null,
    };
  };
  const host = await SjonHost.load(wasmPath, { resolver });
  const r = host.validateDocument('(use-plugin "shapes")\n(circle :r 4)\n', {
    projectRoot: null,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(r.diagnostics)), []);
  assert.equal(r.loadedPlugins.length, 1);
});

test('validateDocument: declarative manifest with empty wasm header loads cleanly', async () => {
  // The wasm bytes here are a minimal valid module header (no
  // sections, no exports), and the paired manifest declares no
  // `:impl "wasm:..."` exports — so pre-flight has nothing to verify
  // beyond ABI/imports. The minimal module is missing the required
  // `sjon_plugin_abi_version` export, so pre-flight collapses the
  // whole load with `plugin_export_missing`. Keeps the D5 deferral-
  // shaped surface honest now that the deferral itself is gone.
  const resolver: ResolverFn = (): Resolution => ({
    kind: 'manifest',
    source:
      '(plugin :name shapes :version "1.0.0" (form :name circle (key :name r :type number :optional false)))',
    wasm: new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]),
  });
  const host = await SjonHost.load(wasmPath, { resolver });
  const r = host.validateDocument('(use-plugin "shapes")\n', {
    projectRoot: null,
    projectFile: null,
  });
  assert.equal(r.loadedPlugins.length, 0);
  const e = errs(r.diagnostics);
  assert.deepEqual(codes(e), ['plugin_export_missing']);
  assert.equal(e[0]!.phase, 'manifest');
});

test('validateDocument: mock resolver returning failure surfaces code+detail', async () => {
  const resolver: ResolverFn = (ref): Resolution => ({
    kind: 'failure',
    code: 'unresolved_plugin',
    detail: `no plugin named ${ref.name} in mock`,
  });
  const host = await SjonHost.load(wasmPath, { resolver });
  const r = host.validateDocument('(use-plugin "shapes")\n', {
    projectRoot: null,
    projectFile: null,
  });
  const e = errs(r.diagnostics);
  assert.deepEqual(codes(e), ['unresolved_plugin']);
  assert.match(e[0]!.message, /no plugin named shapes in mock/);
});

test('validateDocument: parse-fail reference (missing name) skips resolver call', async () => {
  let resolverCalls = 0;
  const resolver: ResolverFn = (): Resolution => {
    resolverCalls++;
    return { kind: 'failure', code: 'unresolved_plugin', detail: 'unreachable' };
  };
  const host = await SjonHost.load(wasmPath, { resolver });
  const r = host.validateDocument('(use-plugin)\n', {
    projectRoot: null,
    projectFile: null,
  });
  assert.equal(resolverCalls, 0, 'parse-fail reference must not invoke the resolver');
  assert.deepEqual(codes(errs(r.diagnostics)), ['invalid_manifest']);
});

test('validateDocument: name mismatch on resolved manifest emits plugin_name_mismatch', async () => {
  const resolver: ResolverFn = (): Resolution => ({
    kind: 'manifest',
    source: '(plugin :name circles :version "1.0.0")',
    wasm: null,
  });
  const host = await SjonHost.load(wasmPath, { resolver });
  const r = host.validateDocument('(use-plugin "shapes" :path "./circles.sjon")\n', {
    projectRoot: null,
    projectFile: null,
  });
  const e = errs(r.diagnostics);
  assert.deepEqual(codes(e), ['plugin_name_mismatch']);
  assert.equal(r.loadedPlugins.length, 0);
});

test('validateDocument: mixed inline + reference (partial-load shape)', async () => {
  const host = await SjonHost.load(wasmPath);
  const src = `
(plugin :name shapes :version "1.0.0"
  (form :name circle
    (key :name r :type number :optional false)))

(use-plugin "missing")

(circle :r 4)
`;
  const r = host.validateDocument(src, { projectRoot: null, projectFile: null });
  const e = errs(r.diagnostics);
  assert.deepEqual(codes(e), ['unresolved_plugin']);
  assert.equal(r.loadedPlugins.length, 1);
});

test('validateDocument: throwing resolver folds into unresolved_plugin failure', async () => {
  const resolver: ResolverFn = (): Resolution => {
    throw new Error('kaboom');
  };
  const host = await SjonHost.load(wasmPath, { resolver });
  const r = host.validateDocument('(use-plugin "x")\n', {
    projectRoot: null,
    projectFile: null,
  });
  const e = errs(r.diagnostics);
  assert.deepEqual(codes(e), ['unresolved_plugin']);
  assert.match(e[0]!.message, /kaboom/);
});

// ---------------------------------------------------------------------------
// D7-exec — executable-plugin ABI dispatch (Phase C).
//
// The fixtures used below come from `examples/plugins/double/plugin.wasm`
// (built by `zig build plugin-fixtures`). It exports `double`, `trap`,
// and `fail` — each demonstrates one execution outcome.
// ---------------------------------------------------------------------------

const DOUBLE_MANIFEST =
  '(plugin :name double :version "1.0.0" (expr-func :name double :arity (fixed 1) :params [number] :result number :impl "wasm:double"))';

/**
 * Resolver helper: serve a fixed manifest source + the on-disk plugin
 * wasm bytes. Captures call count for assertions.
 */
function fixtureResolver(
  manifestSource: string,
  wasmBytes: Uint8Array,
): { resolver: ResolverFn; readonly served: number } {
  let served = 0;
  const resolver: ResolverFn = (): Resolution => {
    served++;
    return { kind: 'manifest', source: manifestSource, wasm: wasmBytes };
  };
  return {
    resolver,
    get served() {
      return served;
    },
  };
}

// --- tiny wasm builder ---------------------------------------------------
//
// Hand-assembled modules for pre-flight tests. The two builders below
// produce minimal v1-shaped wasm — three required exports plus memory —
// either to drive a specific ABI value or to inject a forbidden import.
// We auto-size sections via `section()` so off-by-one byte counts can't
// rot the fixtures.

const utf8 = new TextEncoder();

type Bytes = Uint8Array | readonly number[];

/** Concatenate `Uint8Array | number[]` chunks into one buffer. */
const cat = (...chunks: Bytes[]): Uint8Array => {
  const out: number[] = [];
  for (const c of chunks) for (const b of c) out.push(b);
  return new Uint8Array(out);
};

/** Single-byte LEB128 — fine for everything our test fixtures use. */
const u = (n: number): number[] => {
  if (n < 0 || n > 127) throw new Error(`u: ${n} out of single-byte LEB128 range`);
  return [n];
};

/** Length-prefixed UTF-8 string (single-byte length). */
const lstr = (s: string): Uint8Array => {
  const bytes = utf8.encode(s);
  return cat(u(bytes.length), bytes);
};

/** `[id, size, ...body]` with the size auto-computed from `body`'s length. */
const section = (id: number, body: Bytes): Uint8Array => cat([id], u(body.length), body);

/** Vector of items: `[count, ...items]` with the count auto-computed. */
const vec = (items: Bytes[]): Uint8Array => cat(u(items.length), ...items);

const TYPE_FUNC = 0x60;
const KIND_FUNC = 0x00;
const KIND_MEMORY = 0x02;

/** `(func (param ...) (result ...))` type entry. */
const funcType = (params: Bytes, results: Bytes): Uint8Array =>
  cat([TYPE_FUNC], u(params.length), params, u(results.length), results);

const i32 = 0x7f;
const MAGIC = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
const END = 0x0b;
const I32_CONST = 0x41;

/** A function body — locals decl + ops + end. */
const code = (...ops: number[]): Uint8Array => {
  const body = cat([0x00], ops, [END]); // 0 locals
  return cat(u(body.length), body);
};

/**
 * Build a minimal v1-shaped wasm module:
 *   (module
 *     (memory (export "memory") 1)
 *     (func (export "sjon_plugin_abi_version") (result i32) i32.const <abi>)
 *     (func (export "sjon_plugin_alloc") (param i32) (result i32) i32.const 0)
 *     (func (export "sjon_plugin_free") (param i32 i32)))
 *
 * `abi` is signed-LEB128 — must be a single-byte value (|abi| < 64).
 */
function buildStubPluginWasm(abi: number): Uint8Array {
  if (abi < 0 || abi > 63) throw new Error(`abi ${abi} out of single-byte LEB128 range`);
  const typeSec = section(
    0x01,
    vec([
      funcType([], [i32]), // () -> i32
      funcType([i32], [i32]), // (i32) -> i32
      funcType([i32, i32], []), // (i32, i32) -> ()
    ]),
  );
  const funcSec = section(0x03, vec([u(0), u(1), u(2)]));
  const memSec = section(0x05, vec([cat([0x00], u(1))])); // 1 mem, min=1
  const exportSec = section(
    0x07,
    vec([
      cat(lstr('memory'), [KIND_MEMORY, 0x00]),
      cat(lstr('sjon_plugin_abi_version'), [KIND_FUNC, 0x00]),
      cat(lstr('sjon_plugin_alloc'), [KIND_FUNC, 0x01]),
      cat(lstr('sjon_plugin_free'), [KIND_FUNC, 0x02]),
    ]),
  );
  const codeSec = section(0x0a, vec([code(I32_CONST, abi), code(I32_CONST, 0x00), code()]));
  return cat(MAGIC, typeSec, funcSec, memSec, exportSec, codeSec);
}

/**
 * Build a wasm module with a forbidden `env.host_helper` import. Drives
 * `plugin_import_forbidden`.
 *
 *   (module
 *     (import "env" "host_helper" (func (param i32)))
 *     (memory (export "memory") 1)
 *     (func (export "sjon_plugin_abi_version") (result i32) i32.const 1)
 *     (func (export "sjon_plugin_alloc") (param i32) (result i32) i32.const 0)
 *     (func (export "sjon_plugin_free") (param i32 i32)))
 *
 * The import sits at func index 0, so the local funcs are 1, 2, 3 in
 * the export section.
 */
function buildImportForbiddenWasm(): Uint8Array {
  const typeSec = section(
    0x01,
    vec([
      funcType([i32], []), // (i32) -> ()   — for the import
      funcType([], [i32]), // () -> i32
      funcType([i32], [i32]), // (i32) -> i32
      funcType([i32, i32], []), // (i32, i32) -> ()
    ]),
  );
  const importSec = section(0x02, vec([cat(lstr('env'), lstr('host_helper'), [KIND_FUNC, 0x00])]));
  const funcSec = section(0x03, vec([u(1), u(2), u(3)]));
  const memSec = section(0x05, vec([cat([0x00], u(1))]));
  const exportSec = section(
    0x07,
    vec([
      cat(lstr('memory'), [KIND_MEMORY, 0x00]),
      cat(lstr('sjon_plugin_abi_version'), [KIND_FUNC, 0x01]),
      cat(lstr('sjon_plugin_alloc'), [KIND_FUNC, 0x02]),
      cat(lstr('sjon_plugin_free'), [KIND_FUNC, 0x03]),
    ]),
  );
  const codeSec = section(0x0a, vec([code(I32_CONST, 0x01), code(I32_CONST, 0x00), code()]));
  return cat(MAGIC, typeSec, importSec, funcSec, memSec, exportSec, codeSec);
}

/**
 * Build a wasm with `sjon_plugin_alloc` declared as `() -> i32` instead
 * of the contractual `(i32) -> i32`. Drives the standard-export arity
 * pre-flight check.
 */
function buildWrongAllocArityWasm(): Uint8Array {
  const typeSec = section(
    0x01,
    vec([
      funcType([], [i32]), // () -> i32   (abi_version AND wrong-arity alloc)
      funcType([i32, i32], []), // (i32, i32) -> () (free)
    ]),
  );
  const funcSec = section(0x03, vec([u(0), u(0), u(1)]));
  const memSec = section(0x05, vec([cat([0x00], u(1))]));
  const exportSec = section(
    0x07,
    vec([
      cat(lstr('memory'), [KIND_MEMORY, 0x00]),
      cat(lstr('sjon_plugin_abi_version'), [KIND_FUNC, 0x00]),
      cat(lstr('sjon_plugin_alloc'), [KIND_FUNC, 0x01]),
      cat(lstr('sjon_plugin_free'), [KIND_FUNC, 0x02]),
    ]),
  );
  const codeSec = section(0x0a, vec([code(I32_CONST, 0x01), code(I32_CONST, 0x00), code()]));
  return cat(MAGIC, typeSec, funcSec, memSec, exportSec, codeSec);
}

/**
 * Build a wasm whose declared `:impl "wasm:bad"` export has signature
 * `(i32) -> i32` instead of `(i32, i32) -> i32`. Drives the impl-export
 * arity pre-flight check.
 */
function buildWrongImplArityWasm(): Uint8Array {
  const typeSec = section(
    0x01,
    vec([
      funcType([], [i32]), // () -> i32
      funcType([i32], [i32]), // (i32) -> i32 (alloc AND wrong-arity `bad`)
      funcType([i32, i32], []), // (i32, i32) -> ()
    ]),
  );
  const funcSec = section(0x03, vec([u(0), u(1), u(2), u(1)]));
  const memSec = section(0x05, vec([cat([0x00], u(1))]));
  const exportSec = section(
    0x07,
    vec([
      cat(lstr('memory'), [KIND_MEMORY, 0x00]),
      cat(lstr('sjon_plugin_abi_version'), [KIND_FUNC, 0x00]),
      cat(lstr('sjon_plugin_alloc'), [KIND_FUNC, 0x01]),
      cat(lstr('sjon_plugin_free'), [KIND_FUNC, 0x02]),
      cat(lstr('bad'), [KIND_FUNC, 0x03]),
    ]),
  );
  const codeSec = section(
    0x0a,
    vec([code(I32_CONST, 0x02), code(I32_CONST, 0x00), code(), code(I32_CONST, 0x00)]),
  );
  return cat(MAGIC, typeSec, funcSec, memSec, exportSec, codeSec);
}

test('D7-exec: happy path — (double 21) loads + validates with zero diagnostics', async () => {
  const wasm = await fs.readFile(doublePluginPath);
  const { resolver } = fixtureResolver(DOUBLE_MANIFEST, wasm);
  const host = await SjonHost.load(wasmPath, { resolver });
  const r = host.validateDocument('(use-plugin "double")\n(double 21)\n', {
    projectRoot: null,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(r.diagnostics)), []);
  assert.equal(r.loadedPlugins.length, 1);
  assert.equal(r.loadedPlugins[0]!.name, 'double');
});

test('D7-exec: ABI mismatch (synthetic abi=99) → plugin_abi_mismatch', async () => {
  const wasm = buildStubPluginWasm(63); // 63 is the max single-byte LEB128 value; suffices to ≠ 1
  const resolver: ResolverFn = (): Resolution => ({
    kind: 'manifest',
    source:
      '(plugin :name shapes :version "1.0.0" (form :name circle (key :name r :type number :optional false)))',
    wasm,
  });
  const host = await SjonHost.load(wasmPath, { resolver });
  const r = host.validateDocument('(use-plugin "shapes")\n', {
    projectRoot: null,
    projectFile: null,
  });
  const e = errs(r.diagnostics);
  assert.deepEqual(codes(e), ['plugin_abi_mismatch']);
  assert.equal(e[0]!.phase, 'manifest');
  assert.match(e[0]!.message, /ABI version 63/);
  assert.equal(r.loadedPlugins.length, 0);
});

test('D7-exec: manifest references missing export → plugin_export_missing', async () => {
  const wasm = await fs.readFile(doublePluginPath);
  const manifest =
    '(plugin :name double :version "1.0.0" (expr-func :name halve :arity (fixed 1) :params [number] :result number :impl "wasm:halve"))';
  const resolver: ResolverFn = (): Resolution => ({ kind: 'manifest', source: manifest, wasm });
  const host = await SjonHost.load(wasmPath, { resolver });
  const r = host.validateDocument('(use-plugin "double")\n', {
    projectRoot: null,
    projectFile: null,
  });
  const e = errs(r.diagnostics);
  assert.deepEqual(codes(e), ['plugin_export_missing']);
  assert.equal(e[0]!.phase, 'manifest');
  assert.match(e[0]!.message, /halve/);
  assert.equal(r.loadedPlugins.length, 0);
});

test('D7-exec: plugin declares forbidden env import → plugin_import_forbidden', async () => {
  const wasm = buildImportForbiddenWasm();
  const resolver: ResolverFn = (): Resolution => ({
    kind: 'manifest',
    source:
      '(plugin :name shapes :version "1.0.0" (form :name circle (key :name r :type number :optional false)))',
    wasm,
  });
  const host = await SjonHost.load(wasmPath, { resolver });
  const r = host.validateDocument('(use-plugin "shapes")\n', {
    projectRoot: null,
    projectFile: null,
  });
  const e = errs(r.diagnostics);
  assert.deepEqual(codes(e), ['plugin_import_forbidden']);
  assert.equal(e[0]!.phase, 'manifest');
  assert.match(e[0]!.message, /env\.host_helper/);
});

test('D7-exec: standard export with wrong arity → plugin_abi_mismatch', async () => {
  // `sjon_plugin_alloc` is declared `() -> i32` (arity 0) instead of
  // the contractual `(i32) -> i32` (arity 1). JS exposes the arity via
  // `Function.prototype.length`, the only declarative signature signal
  // available without the not-yet-shipped Type Reflection proposal —
  // wrong arity collapses to `plugin_abi_mismatch`, mirroring Rust's
  // `get_func + .typed()` split.
  const wasm = buildWrongAllocArityWasm();
  const resolver: ResolverFn = (): Resolution => ({
    kind: 'manifest',
    source: '(plugin :name shapes :version "1.0.0")',
    wasm,
  });
  const host = await SjonHost.load(wasmPath, { resolver });
  const r = host.validateDocument('(use-plugin "shapes")\n', {
    projectRoot: null,
    projectFile: null,
  });
  const e = errs(r.diagnostics);
  assert.deepEqual(codes(e), ['plugin_abi_mismatch']);
  assert.equal(e[0]!.phase, 'manifest');
  assert.match(e[0]!.message, /sjon_plugin_alloc/);
  assert.match(e[0]!.message, /arity 1/);
});

test('D7-exec: `:impl wasm:...` export with wrong arity → plugin_abi_mismatch', async () => {
  const wasm = buildWrongImplArityWasm();
  const resolver: ResolverFn = (): Resolution => ({
    kind: 'manifest',
    source:
      '(plugin :name shapes :version "1.0.0" (expr-func :name bad :arity (fixed 1) :params [number] :result number :impl "wasm:bad"))',
    wasm,
  });
  const host = await SjonHost.load(wasmPath, { resolver });
  const r = host.validateDocument('(use-plugin "shapes")\n', {
    projectRoot: null,
    projectFile: null,
  });
  const e = errs(r.diagnostics);
  assert.deepEqual(codes(e), ['plugin_abi_mismatch']);
  assert.equal(e[0]!.phase, 'manifest');
  assert.match(e[0]!.message, /\bbad\b/);
  assert.match(e[0]!.message, /arity 2/);
});

test('D7-exec: plugin export traps → plugin_func_trapped at call span', async () => {
  const wasm = await fs.readFile(doublePluginPath);
  const manifest =
    '(plugin :name double :version "1.0.0" (expr-func :name boom :arity (fixed 1) :params [number] :result number :impl "wasm:trap"))';
  const resolver: ResolverFn = (): Resolution => ({ kind: 'manifest', source: manifest, wasm });
  const host = await SjonHost.load(wasmPath, { resolver });
  const r = host.validateDocument('(use-plugin "double")\n(boom 1)\n', {
    projectRoot: null,
    projectFile: null,
  });
  const e = errs(r.diagnostics);
  assert.deepEqual(codes(e), ['plugin_func_trapped']);
  assert.equal(e[0]!.phase, 'validation');
});

test('D7-exec: plugin returns ok=0 structured error → plugin_func_failed with detail', async () => {
  const wasm = await fs.readFile(doublePluginPath);
  const manifest =
    '(plugin :name double :version "1.0.0" (expr-func :name kaboom :arity (fixed 1) :params [number] :result number :impl "wasm:fail"))';
  const resolver: ResolverFn = (): Resolution => ({ kind: 'manifest', source: manifest, wasm });
  const host = await SjonHost.load(wasmPath, { resolver });
  const r = host.validateDocument('(use-plugin "double")\n(kaboom 1)\n', {
    projectRoot: null,
    projectFile: null,
  });
  const e = errs(r.diagnostics);
  assert.deepEqual(codes(e), ['plugin_func_failed']);
  assert.equal(e[0]!.phase, 'validation');
  // The `fail` export emits code `domain` + detail "plugin reported a
  // structured failure"; both should be visible in the diagnostic
  // message so a user can trace the failure back to plugin source.
  assert.match(e[0]!.message, /domain/);
  assert.match(e[0]!.message, /plugin reported a structured failure/);
});

test('D7-exec: duplicate :name → first-wins pool, dispatch stays on first plugin', async () => {
  // Two `(use-plugin)` references resolve to manifests with the same
  // `:name double`. The first carries the real `double.wasm` (defines
  // `double`); the second carries a no-`double` stub. Zig dedupes the
  // second manifest with `duplicate_plugin_name` and drops it from
  // the schema — so eval looks up `double` against the FIRST plugin's
  // expr-func definition, then dispatches via `sjon_host_invoke_plugin`
  // with `plugin_name="double", export_name="double"`. With first-wins,
  // pool["double"] is still the real wasm and dispatch returns 42.
  // Without it, pool["double"] would be the stub (no `double` export)
  // and eval would surface `plugin_func_alloc_failed`.
  const realWasm = await fs.readFile(doublePluginPath);
  const stubWasm = buildStubPluginWasm(2);
  let call = 0;
  const resolver: ResolverFn = (): Resolution => {
    call++;
    if (call === 1) {
      return { kind: 'manifest', source: DOUBLE_MANIFEST, wasm: realWasm };
    }
    return {
      kind: 'manifest',
      source: '(plugin :name double :version "2.0.0")',
      wasm: stubWasm,
    };
  };
  const host = await SjonHost.load(wasmPath, { resolver });
  const r = host.validateDocument(
    '(use-plugin "double")\n(use-plugin "double" :path "./other.sjon")\n(double 21)\n',
    { projectRoot: null, projectFile: null },
  );
  assert.deepEqual(codes(errs(r.diagnostics)), ['duplicate_plugin_name']);
  assert.equal(r.loadedPlugins.length, 1);
  assert.equal(host._plugins.size, 1);
});

test('D7-exec: plugin :name after a leading (expr-func :name …) pools under the plugin name (A.2)', async () => {
  // Regression: the retired JS scraper anchored on the FIRST :name in
  // source order and pooled this plugin under the nested expr-func's
  // `twice`, not the plugin's own `realpkg`. Zig's invoke request keys
  // on the real name (`realpkg`), so dispatch then missed the pool. The
  // structural `sjon_manifest_meta` reads `realpkg`.
  const realWasm = await fs.readFile(doublePluginPath);
  const manifest =
    '(plugin (expr-func :name twice :arity (fixed 1) :params [number] :result number :impl "wasm:double") :name realpkg :version "1.0.0")';
  const { resolver } = fixtureResolver(manifest, realWasm);
  const host = await SjonHost.load(wasmPath, { resolver });
  const r = host.validateDocument('(use-plugin "realpkg")\n(twice 21)\n', {
    projectRoot: null,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(r.diagnostics)), []);
  assert.ok(host._plugins.has('realpkg'), 'plugin pooled under its own :name');
  assert.ok(!host._plugins.has('twice'), 'not under the nested expr-func name');
});

test('D7-exec: plugin reports oversized frame length → plugin_func_alloc_failed', async () => {
  // The fixture's `huge` export returns a frame header claiming a
  // ~4 GiB payload that doesn't exist. Without a host cap on the
  // reported length the dispatch bridge would try to allocate a
  // matching mirror buffer; the cap rejects it as
  // `plugin_func_alloc_failed` with the size + cap in the detail.
  const wasm = await fs.readFile(doublePluginPath);
  const manifest =
    '(plugin :name double :version "1.0.0" (expr-func :name big :arity (fixed 1) :params [number] :result number :impl "wasm:huge"))';
  const resolver: ResolverFn = (): Resolution => ({ kind: 'manifest', source: manifest, wasm });
  const host = await SjonHost.load(wasmPath, { resolver });
  const r = host.validateDocument('(use-plugin "double")\n(big 1)\n', {
    projectRoot: null,
    projectFile: null,
  });
  const e = errs(r.diagnostics);
  assert.deepEqual(codes(e), ['plugin_func_alloc_failed']);
  assert.equal(e[0]!.phase, 'validation');
  assert.match(e[0]!.message, /4294967295 bytes/);
  assert.match(e[0]!.message, /host caps plugin frames at/);
});

test('validateDocument: projectDiagnostics from HostOptions are prepended', async () => {
  const host = await SjonHost.load(wasmPath);
  const synthetic: HostDiagnostic = {
    phase: 'manifest',
    code: 'duplicate_plugin_name',
    severity: 'err',
    message: 'synthetic duplicate (testing)',
    span: { start: 0, end: 0 },
    path: ['project'],
    declarationSpan: null,
  };
  const r = host.validateDocument('(widget)\n', {
    projectRoot: null,
    projectFile: null,
    projectDiagnostics: [synthetic],
  });
  const e = errs(r.diagnostics);
  // Synthetic project-diagnostic first, then unknown_form for the bare data.
  assert.deepEqual(codes(e), ['duplicate_plugin_name', 'unknown_form']);
  assert.equal(e[0]!.message, 'synthetic duplicate (testing)');
});

// Slice 7: `HostResult.materializedDefaults` mirrors the
// `MaterializedDefaults` side-table for omitted defaulted keys on known
// data forms. Shape per `wasm_common.writeHostResult`:
//   { path, key, origin, value }
// where `path = [form-head, key-name]` and `origin` is
// `literal_default` | `expression_default`.

test('validateDocument: literal default surfaces on materializedDefaults', async () => {
  const host = await SjonHost.load(wasmPath);
  const src = `
(plugin :name probe :version "1.0.0"
  (form :name circle
    (key :name radius :type number :default 32)))

(circle)
`;
  const r = host.validateDocument(src, { projectRoot: null, projectFile: null });
  assert.equal(errs(r.diagnostics).length, 0);
  assert.equal(r.materializedDefaults.length, 1);
  const entry = r.materializedDefaults[0]!;
  assert.deepEqual(entry.path, ['circle', 'radius']);
  assert.equal(entry.key, 'radius');
  assert.equal(entry.origin, 'literal_default');
  assert.equal(entry.value, 32);
});

test('validateDocument: expression default reports expression_default origin', async () => {
  const host = await SjonHost.load(wasmPath);
  const src = `
(plugin :name probe :version "1.0.0"
  (form :name circle
    (key :name radius :type number :default (if true 32 0))))

(circle)
`;
  const r = host.validateDocument(src, { projectRoot: null, projectFile: null });
  assert.equal(errs(r.diagnostics).length, 0);
  assert.equal(r.materializedDefaults.length, 1);
  const entry = r.materializedDefaults[0]!;
  assert.equal(entry.origin, 'expression_default');
  assert.equal(entry.value, 32);
});

test('validateDocument: explicit author kvpair suppresses overlay entry', async () => {
  const host = await SjonHost.load(wasmPath);
  const src = `
(plugin :name probe :version "1.0.0"
  (form :name circle
    (key :name radius :type number :default 32)))

(circle :radius 7)
`;
  const r = host.validateDocument(src, { projectRoot: null, projectFile: null });
  assert.equal(errs(r.diagnostics).length, 0);
  assert.equal(r.materializedDefaults.length, 0);
});

test('validateDocument: failed expression default yields no overlay entry', async () => {
  const host = await SjonHost.load(wasmPath);
  // `(nope)` declares :result number so aggregate validation accepts
  // it, but has no :impl — runtime materialization fails with
  // default_eval_failed and contributes no overlay entry.
  const src = `
(plugin :name probe :version "1.0.0"
  (expr-func :name nope :arity (fixed 0) :result number)
  (form :name circle
    (key :name radius :type number :default (nope))))

(circle)
`;
  const r = host.validateDocument(src, { projectRoot: null, projectFile: null });
  const codeSet = new Set(codes(errs(r.diagnostics)));
  assert.ok(codeSet.has('default_eval_failed'), 'expected default_eval_failed');
  assert.equal(r.materializedDefaults.length, 0);
});

test('loadFromBytes: browser-style loader produces a working host', async () => {
  // Mirrors the fs-based load() under Node by reading the wasm into
  // memory first; in the browser the bytes come from
  // `fetch(url).then(r => r.arrayBuffer())`. The resolver bridge has
  // to work exactly the same — exercise an inline-manifest validation
  // to prove the env imports were wired.
  const bytes = await fs.readFile(wasmPath);
  const host = await SjonHost.loadFromBytes(bytes);
  const src = `
(plugin :name probe :version "1.0.0"
  (form :name widget
    (key :name name :type symbol :optional false)))

(widget :name w0)
`;
  const r = host.validateDocument(src, { projectRoot: null, projectFile: null });
  assert.deepEqual(codes(errs(r.diagnostics)), []);
  assert.equal(r.loadedPlugins[0]!.name, 'probe');
});

test('validateDocument: projectDiagnostics merge preserves materializedDefaults', async () => {
  const host = await SjonHost.load(wasmPath);
  const synthetic: HostDiagnostic = {
    phase: 'manifest',
    code: 'duplicate_plugin_name',
    severity: 'err',
    message: 'synthetic (testing)',
    span: { start: 0, end: 0 },
    path: ['project'],
    declarationSpan: null,
  };
  const src = `
(plugin :name probe :version "1.0.0"
  (form :name circle
    (key :name radius :type number :default 32)))

(circle)
`;
  const r = host.validateDocument(src, {
    projectRoot: null,
    projectFile: null,
    projectDiagnostics: [synthetic],
  });
  // Project diagnostic prefixed; new HostResult fields ride through
  // the spread in the merge path.
  assert.equal(r.diagnostics[0]!.code, 'duplicate_plugin_name');
  assert.equal(r.materializedDefaults.length, 1);
  assert.equal(r.materializedDefaults[0]!.value, 32);
});

// ---------------------------------------------------------------------------
// hostEvalExpr coverage
// ---------------------------------------------------------------------------

test('hostEvalExpr: core arithmetic evaluates without plugins', async () => {
  const host = await SjonHost.load(wasmPath);
  const r = host.hostEvalExpr('(+ 1 2 3)');
  assert.deepEqual(codes(errs(r.diagnostics)), []);
  assert.equal(r.value, 6);
  assert.equal(r.loadedPlugins.length, 0);
});

test('hostEvalExpr: plugin expr-func dispatches through the resolver', async () => {
  const wasm = await fs.readFile(doublePluginPath);
  const { resolver } = fixtureResolver(DOUBLE_MANIFEST, wasm);
  const host = await SjonHost.load(wasmPath, { resolver });
  const r = host.hostEvalExpr('(use-plugin "double")\n(double 21)');
  assert.deepEqual(codes(errs(r.diagnostics)), []);
  assert.equal(r.value, 42);
  assert.equal(r.loadedPlugins.length, 1);
  assert.equal(r.loadedPlugins[0]!.name, 'double');
});

test('hostEvalExpr: unknown form head evaluates as Value.form (v2 form-as-data)', async () => {
  // v2 semantic flip: unknown heads no longer error — they pass
  // through as Value.form so plugin expr-funcs can pattern-match on
  // them. The JSON shape carries `$form` (head), optional `$ns`
  // (namespace), `children`, and `kvpairs`.
  const host = await SjonHost.load(wasmPath);
  const r = host.hostEvalExpr('(no-such 1 2)');
  assert.deepEqual(errs(r.diagnostics), []);
  assert.deepEqual(r.value, {
    $form: 'no-such',
    children: [1, 2],
    kvpairs: {},
  });
});

test('hostEvalExpr: throws SjonWasmError on multiple data forms', async () => {
  const host = await SjonHost.load(wasmPath);
  await assert.rejects(async () => host.hostEvalExpr('(+ 1 2) (+ 3 4)'), /MultipleExpressions/);
});

test('hostEvalExpr: throws SjonWasmError on no data form', async () => {
  const host = await SjonHost.load(wasmPath);
  await assert.rejects(
    async () => host.hostEvalExpr('(plugin :name solo :version "1.0.0" (form :name w :open true))'),
    /NoExpression/,
  );
});

test('hostEvalExpr: vector value round-trips through the JSON shape', async () => {
  const host = await SjonHost.load(wasmPath);
  const r = host.hostEvalExpr('(vec3 1 2 3)');
  assert.deepEqual(codes(errs(r.diagnostics)), []);
  assert.deepEqual(r.value, [1, 2, 3]);
});

// ---------------------------------------------------------------------------
// Plugin-invoke bridge: args-buffer ownership
//
// `handleInvoke` is normally reachable only through a real WASM
// instantiation with a real plugin, which puts its failure paths out of
// a test's reach — and those are the paths where the plugin-owned args
// buffer's ownership is decided. `__testing.handleInvoke` takes a
// structurally-shaped ref so the two interesting orderings can be driven
// directly: a clean call, and an `sjon_alloc` that traps *after* the
// plugin has already been dispatched and its buffers released.
// ---------------------------------------------------------------------------

const HEADER = 8;

interface FakeBridge {
  readonly ref: {
    instance: WebAssembly.Instance | null;
    resolver: null;
    plugins: Map<string, unknown>;
  };
  readonly reqPtr: number;
  readonly reqLen: number;
  readonly freedArgs: () => number;
  readonly sjonMemory: WebAssembly.Memory;
}

/**
 * Build a minimal sjon-side + plugin-side pair around one invoke
 * request. `sjonAllocTrapsOnCall` (1-based) makes that nth `sjon_alloc`
 * throw, modelling a host allocation failure mid-`handleInvoke`.
 */
function makeFakeBridge(opts: { sjonAllocTrapsOnCall?: number } = {}): FakeBridge {
  const pluginName = 'double';
  const exportName = 'twice';
  const argsBytes = new Uint8Array([1, 2, 3, 4]);

  const enc = new TextEncoder();
  const pName = enc.encode(pluginName);
  const eName = enc.encode(exportName);
  const req = new Uint8Array(4 + pName.length + 4 + eName.length + argsBytes.length);
  const reqView = new DataView(req.buffer);
  let o = 0;
  reqView.setUint32(o, pName.length, true);
  o += 4;
  req.set(pName, o);
  o += pName.length;
  reqView.setUint32(o, eName.length, true);
  o += 4;
  req.set(eName, o);
  o += eName.length;
  req.set(argsBytes, o);

  const sjonMemory = new WebAssembly.Memory({ initial: 1 });
  const reqPtr = 1024;
  new Uint8Array(sjonMemory.buffer, reqPtr, req.length).set(req);

  let sjonBump = 4096;
  let sjonAllocCalls = 0;
  const sjonAlloc = (n: number): number => {
    sjonAllocCalls += 1;
    if (opts.sjonAllocTrapsOnCall === sjonAllocCalls) {
      throw new WebAssembly.RuntimeError('sjon_alloc: out of memory');
    }
    const p = sjonBump;
    sjonBump += n;
    return p;
  };

  const pluginMemory = new WebAssembly.Memory({ initial: 1 });
  let pluginBump = 256;
  // Counted per pointer so a double free is visible as a count of 2 on
  // one address, not merely as "more frees than expected" overall.
  const frees = new Map<number, number>();
  let argsPtrIssued = 0;
  const pluginAlloc = (n: number): number => {
    const p = pluginBump;
    pluginBump += n + 8;
    if (argsPtrIssued === 0) argsPtrIssued = p;
    return p;
  };
  const pluginFree = (p: number, _n: number): void => {
    frees.set(p, (frees.get(p) ?? 0) + 1);
  };
  // Returns a well-formed `[ok=1][len=2]["hi"]` frame from a fixed
  // address, so the host's read/copy path is the real one.
  const resultPtr = 32768;
  const twice = (_p: number, _n: number): number => {
    const view = new DataView(pluginMemory.buffer, resultPtr, HEADER);
    view.setUint32(0, 1, true);
    view.setUint32(4, 2, true);
    new Uint8Array(pluginMemory.buffer, resultPtr + HEADER, 2).set([0x68, 0x69]);
    return resultPtr;
  };

  const sjonInstance = {
    exports: { memory: sjonMemory, sjon_alloc: sjonAlloc },
  } as unknown as WebAssembly.Instance;
  const pluginInstance = {
    exports: {
      memory: pluginMemory,
      sjon_plugin_alloc: pluginAlloc,
      sjon_plugin_free: pluginFree,
      twice,
    },
  } as unknown as WebAssembly.Instance;

  const plugins = new Map<string, unknown>([
    [
      pluginName,
      {
        instance: pluginInstance,
        exports: pluginInstance.exports as Record<string, WebAssembly.ExportValue>,
        memory: pluginMemory,
      },
    ],
  ]);

  return {
    ref: { instance: sjonInstance, resolver: null, plugins },
    reqPtr,
    reqLen: req.length,
    freedArgs: () => frees.get(argsPtrIssued) ?? 0,
    sjonMemory,
  };
}

/** Decode the `[u32 ok][u32 len][payload]` frame `handleInvoke` returns. */
function readFrame(memory: WebAssembly.Memory, ptr: number): { ok: boolean; payload: string } {
  const view = new DataView(memory.buffer, ptr, HEADER);
  const ok = view.getUint32(0, true) === 1;
  const len = view.getUint32(4, true);
  const payload = new TextDecoder().decode(new Uint8Array(memory.buffer, ptr + HEADER, len));
  return { ok, payload };
}

test('handleInvoke: a clean call frees the plugin args buffer exactly once', async () => {
  const { __testing } = await import('../SjonHost.ts');
  const b = makeFakeBridge();
  const ptr = __testing.handleInvoke(b.ref as never, b.reqPtr, b.reqLen);
  assert.notEqual(ptr, 0);
  assert.equal(readFrame(b.sjonMemory, ptr).ok, true);
  assert.equal(b.freedArgs(), 1);
});

test('handleInvoke: sjon_alloc trapping after dispatch does not double-free the args buffer', async () => {
  const { __testing } = await import('../SjonHost.ts');
  // The first `sjon_alloc` in this call is `reframeIntoSjon`, reached
  // after the plugin has run and both plugin buffers were released.
  // Trapping there lands in the catch — which used to free the args
  // pointer a second time. A double `sjon_plugin_free` corrupts the
  // plugin's allocator silently: no diagnostic, no trap, just a plugin
  // that misbehaves on some later call.
  const b = makeFakeBridge({ sjonAllocTrapsOnCall: 1 });
  const ptr = __testing.handleInvoke(b.ref as never, b.reqPtr, b.reqLen);
  assert.equal(b.freedArgs(), 1, 'args buffer must be freed exactly once');
  // The failure is still reported: the second `sjon_alloc` (the error
  // frame) succeeds, and carries the trap code the Zig invoker maps onto
  // `plugin_func_trapped`.
  assert.notEqual(ptr, 0);
  const frame = readFrame(b.sjonMemory, ptr);
  assert.equal(frame.ok, false);
  assert.match(frame.payload, /_internal_trap/);
});
