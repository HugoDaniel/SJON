// SJON validating host — D5 production JS wrapper around `sjon.wasm`.
//
// `SjonHost.load(path, { resolver })` instantiates `sjon.wasm` with two
// `env.*` callback imports:
//
//   * `sjon_host_resolve` — bridges the user's sync `(ref) => Resolution`
//     callback. When the resolver returns `Resolution.manifest` with
//     `wasm` bytes attached, this same bridge runs **D7 pre-flight**
//     inline: it instantiates the plugin with empty imports, asserts
//     `sjon_plugin_abi_version() === 2`, checks all `:impl "wasm:..."`
//     exports are present, and checks the module declares no imports.
//     Pre-flight failures collapse the whole `(use-plugin …)` to a
//     `Resolution.failure` carrying the appropriate diagnostic code
//     (`plugin_abi_mismatch`, `plugin_export_missing`, or
//     `plugin_import_forbidden`) so it surfaces at `phase: 'manifest'`
//     under the reference's span.
//
//   * `sjon_host_invoke_plugin` — bridges `:impl "wasm:..."` calls
//     dispatched by the Zig core (`src/wasm_plugin_invoker.zig`). For
//     each call the host: reads the request payload (plugin name +
//     export name + encoded args) out of sjon memory, allocates a
//     matching buffer in the plugin's linear memory via the plugin's
//     `sjon_plugin_alloc`, copies the args in, calls the export wrapped
//     in `try/catch` (a thrown `WebAssembly.RuntimeError` becomes an
//     `_internal_trap` frame), reads the result frame back, frees both
//     plugin buffers, and re-frames the result into sjon memory via
//     `sjon_alloc`. The wire format is pinned by
//     `src/PluginValueCodec.zig` and `src/wasm_plugin_invoker.zig` — Web
//     and Rust hosts speak the same bytes.
//
// `host.validateDocument(source, options)` calls the
// `sjon_host_validate_document` export and returns a JSON-decoded
// `HostResult` matching `hosts/typescript-parity/src/Host.ts`. The shape
// is the cross-host contract — every wrapper around `sjon.wasm` (Rust,
// Python, …) returns it byte-identically over the conformance corpus.
//
// `HostOptions.projectDiagnostics` (from `createNodeFsResolver`'s
// `{resolver, projectDiagnostics}` return) are merged JS-side — the
// WASM payload is filesystem-agnostic. They land at the front of
// `result.diagnostics` under `phase: 'manifest'`, mirroring how
// `Host.zig` drains its `FilesystemResolver`'s project diagnostics.
//
// Plugin instance lifetime is per-host-load: instances live as long as
// the `SjonHost` and are released when it's garbage-collected. Hot
// reload is a v2 concern — re-instantiate the host to pick up new
// plugin bytes.

// `node:fs` is loaded on-demand inside `load` so this module can be
// imported directly in a browser (see the sibling note in
// `sjon-reader.ts`).

import { errMsg } from './errMsg.ts';
import { SjonEncoder, SjonWasm } from './sjon-reader.ts';
import { parseJsonWithBigInt } from './parseJsonWithBigInt.ts';
import type {
  ExportSchemaDraft,
  ExportSchemaLayout,
  ExportSchemaResult,
  ExportSchemaTarget,
  HostEvalResult,
  HostOptions,
  HostResult,
  Reference,
  Resolution,
  ResolverFn,
} from './types.ts';

const HEADER_BYTES = 8;
const PLUGIN_ABI_VERSION = 2;
// Hard upper bound on the payload size a plugin export may report. The
// header arrives as `[u32 ok][u32 len][payload]`, so without a cap a
// hostile plugin could advertise ~4 GiB and force the host to allocate
// a matching mirror buffer. 16 MiB comfortably exceeds any realistic
// codec-encoded value while keeping the per-call memory ceiling small.
const MAX_PLUGIN_RESULT_FRAME = 16 * 1024 * 1024;
const decoder = new TextDecoder();
const encoder = new TextEncoder();

interface PluginInstance {
  readonly instance: WebAssembly.Instance;
  readonly exports: Record<string, WebAssembly.ExportValue>;
  readonly memory: WebAssembly.Memory;
}

interface HostRef {
  instance: WebAssembly.Instance | null;
  readonly resolver: ResolverFn | null;
  readonly plugins: Map<string, PluginInstance>;
}

type PreflightResult = { ok: true } | { ok: false; code: string; detail: string };

export interface SjonHostLoadOptions {
  resolver?: ResolverFn | null;
}

export interface ExportSchemaOptions extends HostOptions {
  readonly target?: ExportSchemaTarget;
  readonly layout?: ExportSchemaLayout;
  readonly draft?: ExportSchemaDraft;
}

/**
 * Validating host wrapping `sjon.wasm`. Composes a `SjonEncoder` for
 * the underlying WASM marshalling — the encoder is exposed on
 * `host.encoder` so Redux-style consumers can reach the kitchen-sink
 * read/edit surface (`toBinary`, `validate`, `toJson`, `applyEdit`, …)
 * on the same WASM instance without instantiating the module twice.
 */
export class SjonHost {
  readonly encoder: SjonEncoder;
  readonly _resolver: ResolverFn | null;
  readonly _plugins: Map<string, PluginInstance>;

  private constructor(
    encoder: SjonEncoder,
    resolver: ResolverFn | null,
    plugins: Map<string, PluginInstance>,
  ) {
    this.encoder = encoder;
    this._resolver = resolver;
    this._plugins = plugins;
  }

  /**
   * Drop references to plugin instances and the underlying encoder so
   * the GC can collect the WebAssembly instances. WebAssembly has no
   * explicit instance-free API — this is honest-lifecycle hygiene
   * (`await using host = await SjonHost.load(...)`), not a real
   * resource release. The actual memory reclamation still depends on
   * GC seeing no remaining references.
   */
  async [Symbol.asyncDispose](): Promise<void> {
    this._plugins.clear();
  }

  /**
   * Load `sjon.wasm` and bind the resolver. The resolver runs sync
   * during validation; throwing inside it produces an `unresolved_plugin`
   * diagnostic carrying the error message. Resolved-and-pre-flighted
   * plugin instances live in `host._plugins` until the host is dropped.
   */
  static async load(path: string | URL, options: SjonHostLoadOptions = {}): Promise<SjonHost> {
    const { promises: fs } = await import('node:fs');
    const bytes = await fs.readFile(path);
    return SjonHost.loadFromBytes(bytes, options);
  }

  /**
   * Browser-side load. Hand in the WASM bytes you've already fetched
   * (e.g. via `fetch(url).then(r => r.arrayBuffer())`); no `node:fs`
   * needed. Otherwise identical to `load` — the resolver bridge + D7
   * pre-flight plumbing run the same way.
   */
  static async loadFromBytes(
    bytes: BufferSource,
    { resolver = null }: SjonHostLoadOptions = {},
  ): Promise<SjonHost> {
    // The instance the bridges read memory through doesn't exist
    // yet — WebAssembly.instantiate has to return it. Plumb a
    // mutable ref cell into the import closures so we can fill it
    // in after instantiation. Nobody calls the imports between
    // instantiate-resolve and our assignment, so the null-window is
    // unobservable.
    const ref: HostRef = {
      instance: null,
      resolver,
      plugins: new Map(),
    };
    const imports: WebAssembly.Imports = {
      env: {
        sjon_host_resolve: (refPtr: number, refLen: number) => handleResolve(ref, refPtr, refLen),
        sjon_host_invoke_plugin: (reqPtr: number, reqLen: number) =>
          handleInvoke(ref, reqPtr, reqLen),
      },
    };
    const { instance } = await WebAssembly.instantiate(bytes, imports);
    ref.instance = instance;
    const encoder = new SjonEncoder(instance);
    return new SjonHost(encoder, resolver, ref.plugins);
  }

  /** Validate `source` through `Host.validateDocument` over WASM. */
  validateDocument(source: string, options: HostOptions): HostResult {
    const projectDiagnostics = options.projectDiagnostics ?? [];
    const text = this._invokeHostExport(
      'sjon_host_validate_document',
      source,
      this._buildHostOptions(options),
    );
    const wasmResult = parseJsonWithBigInt(text) as HostResult;
    if (projectDiagnostics.length === 0) return wasmResult;
    // Spread the WASM result first so any new HostResult fields
    // (materializedDefaults, future additions) flow through;
    // then override diagnostics with the project-prefixed list.
    return {
      ...wasmResult,
      diagnostics: [...projectDiagnostics, ...wasmResult.diagnostics],
    };
  }

  /**
   * Evaluate one SJON expression against the resolved plugin schema.
   * Reuses the same resolver bridge + options shape as
   * `validateDocument`; the document must contain exactly one
   * data-forest form (plugin declarations + `(use-plugin …)`
   * references are allowed alongside it). Plugin expr-funcs declared
   * by loaded plugins dispatch through `lookupExprFunc`, so
   * `(double 21)`, `(count-done items)`, etc. are callable directly.
   *
   * Returns `{ value, diagnostics, loadedPlugins }`. `value` is the
   * JSON-encoded `Expr.Value` (numbers → numbers, strings → strings,
   * keywords → `{"$kw":"…"}`, vectors → arrays) when evaluation
   * succeeded; `null` when it didn't (the matching error landed in
   * `diagnostics`).
   */
  hostEvalExpr(source: string, options: HostOptions = defaultHostOptions()): HostEvalResult {
    const projectDiagnostics = options.projectDiagnostics ?? [];
    const text = this._invokeHostExport(
      'sjon_host_eval_expr',
      source,
      this._buildHostOptions(options),
    );
    const wasmResult = parseJsonWithBigInt(text) as HostEvalResult;
    if (projectDiagnostics.length === 0) return wasmResult;
    return {
      ...wasmResult,
      diagnostics: [...projectDiagnostics, ...wasmResult.diagnostics],
    };
  }

  /**
   * Query a pattern document (`PatternQuery` over WASM) on the half-open
   * tick window `[begin, end)` with RNG `seed`. Returns the framed SJON
   * text: `(haps …)` on success, `(diagnostics …)` when the query
   * collected any. No resolver / plugin schema needed — the pattern
   * vocabulary is built into the artifact.
   */
  queryPattern(source: string, begin: number, end: number, seed: number): string {
    return this.encoder.queryPattern(source, begin, end, seed);
  }

  /**
   * Export a JSON Schema 2020-12 + TypeScript `.d.ts` (+ optional
   * intermediate IR) for the plugin schema declared in `source`.
   * Mirrors `Host.exportSchemaFromSource` over WASM: parses,
   * aggregates, validates, and lowers in one call. Returns the
   * envelope produced by `common.writeExportSchemaResult`.
   *
   * The `target` option selects which artifacts are populated:
   * `"json-schema"`, `"typescript"`, `"both"` (default — both
   * `jsonSchema` and `tsTypes`), `"intermediate"` (only `intermediate`).
   * `layout` defaults to `"aggregated"`; pass `"per-plugin"` for the
   * sibling-file layout.
   */
  exportSchema(
    source: string,
    options: ExportSchemaOptions = defaultHostOptions(),
  ): ExportSchemaResult {
    const wasmOptions = {
      ...this._buildHostOptions(options),
      target: options.target ?? 'both',
      layout: options.layout ?? 'aggregated',
      draft: options.draft ?? '2020-12',
    };
    const text = this._invokeHostExport('sjon_export_schema', source, wasmOptions);
    return parseJsonWithBigInt(text) as ExportSchemaResult;
  }

  /**
   * Render the document's aggregate `:lowering :produces` DAG as SJON.
   * Mirrors `Host.exportLoweringGraphFromSource` over WASM. Unlike
   * `exportSchema`, the framed payload is the `(lowering-graph …)` SJON
   * text itself (not a JSON envelope), so this returns the raw string. A
   * cyclic aggregate still renders so the cycle stays visible; query
   * diagnostics via `validateDocument` if you need them.
   */
  exportLoweringGraph(source: string, options: HostOptions = defaultHostOptions()): string {
    return this._invokeHostExport(
      'sjon_export_lowering_graph',
      source,
      this._buildHostOptions(options),
    );
  }

  _buildHostOptions(options: HostOptions): {
    projectRoot: string | null;
    projectFile: string | null;
    failurePolicy: 'strict' | 'lenient';
    heldSymbol: string | null;
    hasResolver: boolean;
  } {
    return {
      projectRoot: options.projectRoot ?? null,
      projectFile: options.projectFile ?? null,
      failurePolicy: options.failurePolicy ?? 'lenient',
      // Only `sjon_host_validate_document` reads this; the export entries
      // parse the same options shape and ignore it, exactly as they do with
      // `projectRoot` when nothing resolves.
      heldSymbol: options.heldSymbol ?? null,
      hasResolver: this._resolver !== null,
    };
  }

  /**
   * Two-buffer export call shared by `validateDocument` and
   * `hostEvalExpr`. Marshals `source` + `wasmOptions` and delegates to
   * the encoder's one two-buffer marshaller (`_callBytesTwo`, which owns
   * the empty-source reservation + framed read/free). Throws
   * `SjonWasmError` on an `ok=0` frame.
   */
  _invokeHostExport(fnName: string, source: string, wasmOptions: object): string {
    const payload = this.encoder._callBytesTwo(
      fnName,
      encoder.encode(source),
      encoder.encode(JSON.stringify(wasmOptions)),
    );
    return decoder.decode(payload);
  }
}

function defaultHostOptions(): HostOptions {
  return { projectRoot: null, projectFile: null };
}

// ---------------------------------------------------------------------------
// Resolver bridge.
// ---------------------------------------------------------------------------

/**
 * Resolver-bridge entry point. WASM hands us a JSON Reference at
 * `[refPtr, refPtr+refLen)`; we call the user resolver, JSON-encode the
 * Resolution, allocate a framed `[u32 ok][u32 len][u8 payload]` buffer
 * via `sjon_alloc`, and return its pointer. Returning 0 makes the Zig
 * adapter emit `unresolved_plugin`.
 *
 * When the resolver returns `manifest` with wasm bytes attached we run
 * D7 pre-flight inline here — instantiate the plugin, check ABI version,
 * required exports, and import emptiness — and stash the instance in
 * the host's plugin pool. Pre-flight failures collapse the resolution
 * to a `failure` Resolution carrying the matching diagnostic code.
 */
function handleResolve(ref: HostRef, refPtr: number, refLen: number): number {
  const { instance, resolver } = ref;
  if (!instance || !resolver) return 0;
  const memory = instance.exports['memory'] as WebAssembly.Memory;

  let parsed: Reference;
  try {
    const refJson = decoder.decode(new Uint8Array(memory.buffer, refPtr, refLen));
    parsed = JSON.parse(refJson) as Reference;
  } catch (err) {
    return frameResolverError(instance, `failed to decode Reference: ${errMsg(err)}`);
  }

  let resolution: Resolution;
  try {
    resolution = resolver(parsed);
  } catch (err) {
    return frameResolverError(instance, errMsg(err));
  }

  if (resolution && resolution.kind === 'manifest' && resolution.wasm) {
    const preflight = instantiateAndPreflight(
      ref,
      instance,
      resolution.source,
      resolution.wasm as BufferSource,
    );
    if (!preflight.ok) {
      return frameOk(
        instance,
        JSON.stringify({
          kind: 'failure',
          code: preflight.code,
          detail: preflight.detail,
        }),
      );
    }
  }

  return frameOk(instance, encodeResolution(resolution));
}

/**
 * Instantiate `wasmBytes` with empty imports and pre-flight per spec
 * `docs/executable-plugin-abi.md` §§5-7. On success, register the
 * instance in `ref.plugins` keyed by the manifest's `:name`.
 *
 * Pre-flight order:
 *   1. `WebAssembly.Module(bytes)` — compile-time validity.
 *   2. `Module.imports(module)` non-empty → `plugin_import_forbidden`.
 *      Checked before instantiating because instantiation with an
 *      unresolved import throws `LinkError`, which would mask the
 *      forbidden-import case as a generic instantiate failure.
 *   3. `Instance(module, {})` — links against the empty import set.
 *   4. `sjon_plugin_abi_version() === 2` → else `plugin_abi_mismatch`.
 *   5. Required standard exports + every `:impl "wasm:<name>"` named
 *      in the manifest source, expr-funcs and cross-ref providers alike
 *      → else `plugin_export_missing`.
 *
 * `mainInstance` is the host's own `sjon.wasm` instance — its
 * `sjon_manifest_meta` export supplies the manifest's `:name` + wasm
 * impls (see `readManifestMeta`), replacing the earlier source scrape.
 */
function instantiateAndPreflight(
  ref: HostRef,
  mainInstance: WebAssembly.Instance,
  source: string,
  wasmBytes: BufferSource,
): PreflightResult {
  const meta = readManifestMeta(mainInstance, source);
  const pluginName = meta.name;
  if (pluginName === null) {
    // Without a `:name` keyword the manifest itself is malformed.
    // Let the loader's parser emit the canonical invalid_manifest
    // diagnostic by passing the bytes through; nothing useful comes
    // of pre-flighting against an unknowable pool key.
    return { ok: true };
  }

  let module: WebAssembly.Module;
  try {
    module = new WebAssembly.Module(wasmBytes);
  } catch (err) {
    return {
      ok: false,
      code: 'plugin_abi_mismatch',
      detail: `plugin "${pluginName}" failed to compile: ${errMsg(err)}`,
    };
  }

  // Check imports BEFORE instantiating. `new WebAssembly.Instance(mod,
  // {})` throws `LinkError` on any unresolved import, which would
  // otherwise mask a forbidden-import as a generic instantiate failure.
  const declaredImports = WebAssembly.Module.imports(module);
  if (declaredImports.length > 0) {
    const first = declaredImports[0]!;
    return {
      ok: false,
      code: 'plugin_import_forbidden',
      detail: `plugin "${pluginName}" declares forbidden import \`${first.module}.${first.name}\` (v1 plugins MUST have an empty import set)`,
    };
  }

  let instance: WebAssembly.Instance;
  try {
    instance = new WebAssembly.Instance(module, {});
  } catch (err) {
    return {
      ok: false,
      code: 'plugin_abi_mismatch',
      detail: `plugin "${pluginName}" failed to instantiate: ${errMsg(err)}`,
    };
  }

  const exports = instance.exports as Record<string, WebAssembly.ExportValue>;

  // (i) Required standard exports — presence + arity. JS exposes a
  // WebAssembly export's parameter count via `Function.prototype.length`,
  // which is the only declarative signal we have without the
  // not-yet-shipped Type Reflection proposal. Wrong arity surfaces as
  // `plugin_abi_mismatch`, distinguishing "missing" (export_missing)
  // from "present but wrong signature" — mirrors the Rust host's
  // `get_func + .typed()` split.
  for (const req of REQUIRED_STANDARD_EXPORTS) {
    const value = exports[req.name];
    if (req.kind === 'memory') {
      if (!(value instanceof WebAssembly.Memory)) {
        return {
          ok: false,
          code: 'plugin_export_missing',
          detail: `plugin "${pluginName}" is missing the required \`${req.name}\` export`,
        };
      }
      continue;
    }
    if (typeof value !== 'function') {
      return {
        ok: false,
        code: 'plugin_export_missing',
        detail: `plugin "${pluginName}" is missing the required \`${req.name}\` export`,
      };
    }
    if (value.length !== req.arity) {
      return {
        ok: false,
        code: 'plugin_abi_mismatch',
        detail: `plugin "${pluginName}" export \`${req.name}\` has the wrong signature; expected arity ${req.arity}, got ${value.length}`,
      };
    }
  }

  // (ii) ABI version dispatch. Presence + arity already verified
  // above; the call itself only surfaces traps or wrong-value failures.
  let abi: number;
  try {
    const abiFn = exports['sjon_plugin_abi_version'] as () => number;
    abi = abiFn();
  } catch (err) {
    return {
      ok: false,
      code: 'plugin_abi_mismatch',
      detail: `plugin "${pluginName}" sjon_plugin_abi_version() trapped: ${errMsg(err)}`,
    };
  }
  if (abi !== PLUGIN_ABI_VERSION) {
    return {
      ok: false,
      code: 'plugin_abi_mismatch',
      detail: `plugin "${pluginName}" reports ABI version ${abi}; host implements ${PLUGIN_ABI_VERSION}`,
    };
  }

  // (iii) Declared `:impl "wasm:<name>"` exports. Every one is
  // contractually `(i32, i32) -> i32`, so the JS-side `.length` must
  // be 2. Same missing-vs-wrong-sig split as the standard exports.
  //
  // Both catalogs that can declare one arrive here in a single
  // undiscriminated list — expr-funcs and cross-ref providers — because
  // pre-flight asks them the same question. A provider call is an
  // ordinary plugin call, right down to the signature.
  for (const exportName of meta.wasmImpls) {
    const fn = exports[exportName];
    if (typeof fn !== 'function') {
      return {
        ok: false,
        code: 'plugin_export_missing',
        detail: `plugin "${pluginName}" manifest declares \`:impl "wasm:${exportName}"\` but the binary has no such export`,
      };
    }
    if (fn.length !== 2) {
      return {
        ok: false,
        code: 'plugin_abi_mismatch',
        detail: `plugin "${pluginName}" export \`${exportName}\` has the wrong signature; expected \`(i32, i32) -> i32\` (arity 2), got arity ${fn.length}`,
      };
    }
  }

  // First-wins: if a plugin with this `:name` is already registered,
  // keep the existing instance. Zig's manifest-load dedupe later emits
  // `duplicate_plugin_name` for the second `(use-plugin …)` and drops
  // it from the schema; without this guard the pool would overwrite
  // the live instance with the about-to-be-rejected one, and eval
  // would dispatch into the wrong module.
  if (ref.plugins.has(pluginName)) return { ok: true };

  const entry: PluginInstance = {
    instance,
    exports,
    memory: exports['memory'] as WebAssembly.Memory,
  };
  ref.plugins.set(pluginName, entry);
  return { ok: true };
}

interface ManifestMeta {
  /** The plugin's own `:name`, or null when `source` is not a
   *  well-formed `(plugin …)` manifest (nothing to key the pool on). */
  readonly name: string | null;
  /** Every declared `:impl "wasm:<export>"` name, in declaration order. */
  readonly wasmImpls: readonly string[];
}

/**
 * Read a manifest's `:name` + declared `:impl "wasm:<export>"` names via
 * the host's `sjon_manifest_meta` export — a structural walk (parse →
 * load → plugin fields). Unlike the retired regex it can't be fooled by
 * source order: a leading nested `(expr-func :name …)` no longer shadows
 * the plugin's own `:name`, so the pool is keyed correctly.
 *
 * Runs re-entrantly on the main instance during resolver-bridge
 * pre-flight (`handleResolve` is itself a callback out of a running
 * `sjon_host_validate_document`). This is safe: `sjon_manifest_meta`
 * neither resolves plugins nor calls back into JS, and its
 * `sjon_alloc`/`sjon_free` pair is balanced before it returns — the same
 * re-entrant marshalling the resolver bridge already performs.
 */
function readManifestMeta(instance: WebAssembly.Instance, source: string): ManifestMeta {
  const raw = new SjonWasm(instance)._callJson('sjon_manifest_meta', encoder.encode(source)) as {
    name: string | null;
    wasm_impls: string[];
  };
  return { name: raw.name, wasmImpls: raw.wasm_impls };
}

type RequiredExport =
  | { readonly name: string; readonly kind: 'function'; readonly arity: number }
  | { readonly name: string; readonly kind: 'memory' };

/**
 * Required standard exports per spec §6. The `arity` is the contractual
 * JS-visible parameter count (`Function.prototype.length` on a
 * WebAssembly export). Memory entries have no `arity` — they're checked
 * via `instanceof WebAssembly.Memory`.
 */
const REQUIRED_STANDARD_EXPORTS = [
  { name: 'sjon_plugin_abi_version', kind: 'function', arity: 0 },
  { name: 'sjon_plugin_alloc', kind: 'function', arity: 1 },
  { name: 'sjon_plugin_free', kind: 'function', arity: 2 },
  { name: 'memory', kind: 'memory' },
] as const satisfies readonly RequiredExport[];

// ---------------------------------------------------------------------------
// Plugin invoke bridge.
// ---------------------------------------------------------------------------

interface InvokeRequest {
  readonly pluginName: string;
  readonly exportName: string;
  readonly argsBytes: Uint8Array;
}

/**
 * `env.sjon_host_invoke_plugin` handler. Reads the per-call request
 * payload (plugin name + export name + encoded args) from sjon memory,
 * dispatches into the plugin, copies the result frame back into sjon
 * memory, and returns its pointer. Wire format documented in
 * `src/wasm_plugin_invoker.zig` and `src/PluginValueCodec.zig`.
 *
 * Trap and alloc failures are surfaced as plugin-style `ok=0` frames
 * with the synthetic `_internal_trap` / `_alloc` codes the Zig invoker
 * recognises (it maps them onto `PluginFuncTrapped` /
 * `PluginFuncAllocFailed` respectively, which then drive the
 * `plugin_func_trapped` / `plugin_func_alloc_failed` diagnostic codes
 * at validation phase).
 */
function handleInvoke(ref: HostRef, reqPtr: number, reqLen: number): number {
  const { instance, plugins } = ref;
  if (!instance) return 0;
  const sjonMemory = instance.exports['memory'] as WebAssembly.Memory;

  // Copy the request out of sjon memory immediately — any subsequent
  // `sjon_alloc` (e.g. for the result frame) may grow the buffer and
  // invalidate the view.
  const request = new Uint8Array(reqLen);
  request.set(new Uint8Array(sjonMemory.buffer, reqPtr, reqLen));

  let parsed: InvokeRequest | null;
  try {
    parsed = parseInvokeRequest(request);
  } catch (err) {
    return frameInvokeError(instance, '_alloc', `malformed invoke request: ${errMsg(err)}`);
  }
  if (parsed === null) {
    return frameInvokeError(instance, '_alloc', 'malformed invoke request: truncated');
  }

  const plugin = plugins.get(parsed.pluginName);
  if (!plugin) {
    return frameInvokeError(
      instance,
      '_alloc',
      `no instance for plugin "${parsed.pluginName}" (was pre-flight skipped?)`,
    );
  }
  const exportFn = plugin.exports[parsed.exportName];
  if (typeof exportFn !== 'function') {
    return frameInvokeError(
      instance,
      '_alloc',
      `plugin "${parsed.pluginName}" has no export "${parsed.exportName}"`,
    );
  }

  const argsLen = parsed.argsBytes.length;
  const pluginAlloc = plugin.exports['sjon_plugin_alloc'] as (n: number) => number;
  const pluginFree = plugin.exports['sjon_plugin_free'] as (p: number, n: number) => void;
  const argsPtr = argsLen === 0 ? 0 : pluginAlloc(argsLen);
  if (argsLen > 0 && argsPtr === 0) {
    return frameInvokeError(
      instance,
      '_alloc',
      `plugin "${parsed.pluginName}" sjon_plugin_alloc(${argsLen}) returned null`,
    );
  }

  // The args buffer is plugin-owned and must be released exactly once,
  // on every exit path — and three paths reach the release: the
  // oversized-frame refusal, the success path, and the catch below.
  //
  // The success path used to free and *then* call `reframeIntoSjon`,
  // which allocates in sjon memory and can trap. That lands in the
  // catch, which freed the same pointer again. A double
  // `sjon_plugin_free` corrupts the plugin's allocator and says nothing
  // — no diagnostic, no trap, just a plugin that misbehaves later.
  //
  // `argsLive` closes the window. It is cleared *before* the call, so a
  // `sjon_plugin_free` that traps on its own also counts as consumed:
  // retrying it from the catch would be the same double free.
  let argsLive = argsLen > 0;
  const releaseArgs = (): void => {
    if (!argsLive) return;
    argsLive = false;
    pluginFree(argsPtr, argsLen);
  };
  const releaseArgsBestEffort = (): void => {
    try {
      releaseArgs();
    } catch {
      /* best-effort: we are already on a failure path */
    }
  };

  try {
    if (argsLen > 0) {
      new Uint8Array(plugin.memory.buffer, argsPtr, argsLen).set(parsed.argsBytes);
    }

    let resultPtr: number;
    try {
      resultPtr = (exportFn as (p: number, n: number) => number)(argsPtr, argsLen);
    } catch (err) {
      return frameInvokeError(instance, '_internal_trap', errMsg(err));
    }
    if (resultPtr === 0) {
      return frameInvokeError(
        instance,
        '_alloc',
        `plugin "${parsed.pluginName}" export "${parsed.exportName}" returned null pointer`,
      );
    }

    // Read the framed result out of plugin memory and copy into a JS
    // buffer; the plugin frees the original below.
    const plugMem = plugin.memory.buffer;
    const headerView = new DataView(plugMem, resultPtr, HEADER_BYTES);
    const resultOk = headerView.getUint32(0, true);
    const resultLen = headerView.getUint32(4, true);
    if (resultLen > MAX_PLUGIN_RESULT_FRAME) {
      // Refuse to honor the reported length — allocating a JS
      // mirror buffer of this size would be a host-side memory
      // attack. Don't call `sjon_plugin_free` on the bogus frame
      // (we don't trust the size); the args buffer is ours to
      // release and this is its only chance.
      releaseArgsBestEffort();
      return frameInvokeError(
        instance,
        '_alloc',
        `plugin "${parsed.pluginName}" export "${parsed.exportName}" returned a framed result of ${resultLen} bytes; host caps plugin frames at ${MAX_PLUGIN_RESULT_FRAME} bytes`,
      );
    }
    const total = HEADER_BYTES + resultLen;
    const frameCopy = new Uint8Array(total);
    frameCopy.set(new Uint8Array(plugMem, resultPtr, total));

    // Plugins own their returned frame buffer and free it via the
    // same `sjon_plugin_free` we'd use; spec §11.
    pluginFree(resultPtr, total);
    // Args buffer is plugin-owned too — release while we have the
    // handle. `releaseArgs` (not the best-effort form): a failure here
    // is still worth reporting as `_internal_trap`, and it is now safe
    // to fall into the catch, which will not re-free.
    releaseArgs();

    // Re-frame into sjon memory. The header we copied out already has
    // the right ok/len fields — splice straight through.
    void resultOk;
    return reframeIntoSjon(instance, frameCopy);
  } catch (err) {
    releaseArgsBestEffort();
    return frameInvokeError(instance, '_internal_trap', errMsg(err));
  }
}

/**
 * Parse a binary invoke request:
 *
 *   [u32 plugin_name_len][plugin_name utf-8]
 *   [u32 export_name_len][export_name utf-8]
 *   [args_bytes ...]              (PluginValueCodec.encodeArgs format)
 *
 * Returns `null` if the buffer is truncated.
 */
function parseInvokeRequest(buf: Uint8Array): InvokeRequest | null {
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  let off = 0;
  if (off + 4 > buf.length) return null;
  const pNameLen = view.getUint32(off, true);
  off += 4;
  if (off + pNameLen > buf.length) return null;
  const pluginName = decoder.decode(buf.subarray(off, off + pNameLen));
  off += pNameLen;
  if (off + 4 > buf.length) return null;
  const eNameLen = view.getUint32(off, true);
  off += 4;
  if (off + eNameLen > buf.length) return null;
  const exportName = decoder.decode(buf.subarray(off, off + eNameLen));
  off += eNameLen;
  const argsBytes = buf.subarray(off);
  return { pluginName, exportName, argsBytes };
}

/**
 * Allocate sjon memory and write the already-framed `[ok][len][payload]`
 * bytes into it. Returns the pointer to the framed buffer; the Zig
 * invoker frees it with `wasm_allocator.free` after reading.
 */
function reframeIntoSjon(instance: WebAssembly.Instance, framed: Uint8Array): number {
  const alloc = instance.exports['sjon_alloc'] as (n: number) => number;
  const ptr = alloc(framed.length);
  if (ptr === 0) return 0;
  const memory = instance.exports['memory'] as WebAssembly.Memory;
  new Uint8Array(memory.buffer, ptr, framed.length).set(framed);
  return ptr;
}

/**
 * Build a structured-error frame for the invoke path (matches
 * `PluginValueCodec.encodeErrFrame` byte-for-byte). `code` should be
 * one of `_internal_trap` / `_alloc` so the Zig invoker maps it onto
 * `PluginFuncTrapped` / `PluginFuncAllocFailed`.
 */
function frameInvokeError(instance: WebAssembly.Instance, code: string, detail: string): number {
  const codeBytes = encoder.encode(code);
  const detailBytes = encoder.encode(detail);
  // Build the nested `[u32 code_len][code][u32 detail_len][detail]`
  // payload, then hand it to the one framer for the `[ok][len][…]`
  // envelope — `ok=0` selects the Zig invoker's structured-error path.
  const payload = new Uint8Array(4 + codeBytes.length + 4 + detailBytes.length);
  const view = new DataView(payload.buffer);
  view.setUint32(0, codeBytes.length, true);
  payload.set(codeBytes, 4);
  const detailOff = 4 + codeBytes.length;
  view.setUint32(detailOff, detailBytes.length, true);
  payload.set(detailBytes, detailOff + 4);
  return frame(instance, false, payload);
}

// ---------------------------------------------------------------------------
// Resolver-side framing helpers (shared shape with the legacy D5 path).
// ---------------------------------------------------------------------------

function encodeResolution(resolution: Resolution): string {
  switch (resolution.kind) {
    case 'manifest':
      return JSON.stringify({
        kind: 'manifest',
        source: resolution.source,
        wasm: resolution.wasm ? Array.from(resolution.wasm) : null,
      });
    case 'failure':
      return JSON.stringify({
        kind: 'failure',
        code: resolution.code,
        detail: resolution.detail,
      });
    default:
      return JSON.stringify({
        kind: 'failure',
        code: 'unresolved_plugin',
        detail: `JS resolver returned unknown Resolution kind`,
      });
  }
}

function frameOk(instance: WebAssembly.Instance, text: string): number {
  return frame(instance, true, encoder.encode(text));
}

function frameResolverError(instance: WebAssembly.Instance, message: string): number {
  return frame(instance, false, encoder.encode(message));
}

function frame(instance: WebAssembly.Instance, ok: boolean, payload: Uint8Array): number {
  const total = HEADER_BYTES + payload.length;
  const alloc = instance.exports['sjon_alloc'] as (n: number) => number;
  const ptr = alloc(total);
  if (ptr === 0) return 0;
  // sjon_alloc may have grown linear memory — re-derive the buffer.
  const memory = instance.exports['memory'] as WebAssembly.Memory;
  const buf = new Uint8Array(memory.buffer, ptr, total);
  const view = new DataView(memory.buffer, ptr, HEADER_BYTES);
  view.setUint32(0, ok ? 1 : 0, true);
  view.setUint32(4, payload.length, true);
  if (payload.length > 0) buf.subarray(HEADER_BYTES).set(payload);
  return ptr;
}

// ---------------------------------------------------------------------------
// Test-only surface
// ---------------------------------------------------------------------------

/**
 * Handles that exist so `test/host.test.ts` can drive the plugin-invoke
 * bridge directly. Not part of the package's API.
 *
 * `handleInvoke` is otherwise reachable only through a real WASM
 * instantiation with a real plugin, which makes its failure paths — an
 * `sjon_alloc` that traps *after* the plugin has already been called, a
 * `sjon_plugin_free` that throws — unreachable from a test. Those paths
 * are exactly where the args buffer's ownership is decided, so they are
 * the ones worth pinning.
 */
export const __testing = { handleInvoke } as const;
