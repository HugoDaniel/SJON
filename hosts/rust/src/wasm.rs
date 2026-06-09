//! Wasmtime instantiation, framed-protocol marshalling, and the two
//! `env.*` callback handlers that bridge sjon.wasm to host-supplied code:
//! `sjon_host_resolve` (the `(use-plugin …)` resolver bridge) and
//! `sjon_host_invoke_plugin` (the D7-exec `:impl "wasm:…"` dispatcher).
//!
//! Output framing (every output-returning WASM export):
//! `[u32 ok][u32 len][u8... payload]`. `ok=1` → JSON payload; `ok=0`
//! → UTF-8 error name. Caller frees `8 + len` via `sjon_free`.
//!
//! Resolver bridge: WASM hands us `[ref_ptr, ref_ptr+ref_len)` pointing
//! at a JSON `Reference`; we call the user resolver, JSON-encode the
//! `Resolution`, allocate a framed buffer via `sjon_alloc`, and return
//! its pointer. Returning 0 makes the Zig side emit `unresolved_plugin`.
//!
//! When the resolver returns `Resolution::Manifest` with wasm bytes
//! attached, the same bridge runs D7 pre-flight inline: instantiate the
//! plugin with empty imports, assert `sjon_plugin_abi_version() == 2`,
//! check all required + declared exports are present, and check the
//! module declares no imports. Pre-flight failures collapse to a
//! `Resolution::Failure` carrying the matching diagnostic code (
//! `plugin_abi_mismatch` / `plugin_export_missing` /
//! `plugin_import_forbidden`).
//!
//! Plugin-invoke bridge: per-call alloc/copy/call/free across the two
//! WASM instances. Wire format pinned by `src/wasm_plugin_invoker.zig`
//! and `src/PluginValueCodec.zig` — Web and Rust hosts speak the same
//! bytes. Traps map to `_internal_trap`, host-side alloc failures to
//! `_alloc`; the Zig invoker translates those onto `PluginFuncTrapped`
//! and `PluginFuncAllocFailed` respectively at the call span.

use std::collections::HashMap;
use std::sync::Arc;

use wasmtime::error::Context as _;
use wasmtime::{Caller, Engine, Extern, Linker, Memory, Module, Store, TypedFunc};

use crate::resolver::{Reference, Resolution, Resolver};

/// Outcome of `SjonWasm::load_bytes`. Discriminates parse-time failures
/// (`Module::from_binary`) from instantiation-time failures (linker
/// wiring, instantiate, missing exports) so the public `SjonHostError`
/// can mirror that split without string-matching on context messages.
pub(crate) enum LoadError {
    /// `Module::from_binary` rejected the bytes — not WASM, or the
    /// module targets a spec wasmtime doesn't speak.
    Parse(wasmtime::Error),
    /// Anything else along the load path: import wiring,
    /// `Linker::instantiate`, missing memory, or a missing/wrong-shaped
    /// host export.
    Instantiate(wasmtime::Error),
}

/// Plugin `sjon_plugin_alloc(len) -> ptr` export.
type PluginAllocFn = TypedFunc<u32, u32>;
/// Plugin `sjon_plugin_free(ptr, len)` export.
type PluginFreeFn = TypedFunc<(u32, u32), ()>;
/// One plugin-side `:impl "wasm:<name>"` export
/// (`(args_ptr, args_len) -> result_ptr`).
type PluginImplFn = TypedFunc<(u32, u32), u32>;
/// `(code, message)` pair returned by every plugin pre-flight helper.
/// `preflight_and_register`'s caller folds these into a diagnostic at
/// the `(use-plugin …)` span.
type PluginLoadErr = (String, String);

pub(crate) const HEADER_BYTES: usize = 8;
const PLUGIN_ABI_VERSION: u32 = 2;
const TRAP_CODE: &str = "_internal_trap";
const ALLOC_CODE: &str = "_alloc";
/// Hard upper bound on the payload size a plugin export may report. The
/// header arrives as `[u32 ok][u32 len][payload]`, so without a cap a
/// hostile plugin could advertise ~4 GiB and force the host to allocate
/// a matching mirror buffer. 16 MiB comfortably exceeds any realistic
/// codec-encoded value while keeping the per-call memory ceiling small.
///
/// Coupled to `tests/host.rs::d7_exec_plugin_reports_oversized_frame_*`,
/// which asserts the host refuses to honor a length past this cap and
/// emits `plugin_func_alloc_failed`.
const MAX_PLUGIN_RESULT_FRAME: usize = 16 * 1024 * 1024;

/// Decode a little-endian `u32` from the first 4 bytes of `buf`. Panics
/// if `buf.len() < 4` — callers must have already bounds-checked. Pure
/// helper to dedup the 6 framed-header / invoke-request decode sites.
#[allow(clippy::expect_used)]
fn read_u32_le(buf: &[u8]) -> u32 {
    u32::from_le_bytes(
        buf[0..4]
            .try_into()
            .expect("invariant: 4-byte slice into [u8; 4] is infallible"),
    )
}

/// Cast a `usize` length to `u32` at the FFI boundary. The framing
/// protocol pins payloads to `u32`, so `> 4 GiB` is out-of-contract —
/// `expect` documents that boundary explicitly instead of silently
/// truncating via `as u32`.
#[allow(clippy::expect_used)]
fn u32_len(len: usize) -> u32 {
    u32::try_from(len).expect("invariant: FFI payload length exceeds u32::MAX (>4 GiB)")
}

/// Free the given plugin allocation, dropping any error from
/// `sjon_plugin_free`. Used in `invoke_plugin_export`'s cleanup paths
/// where an `InvokeFailure` is already on its way back to the caller —
/// propagating the free-time error would mask the original failure
/// and there's nothing meaningful the host can do about a trap inside
/// the plugin's own deallocator at this point.
fn best_effort_free(plugin: &mut PluginInstance, ptr: u32, len: u32) {
    let _ = plugin.free.call(&mut plugin.store, (ptr, len));
}

/// Per-store data carried into every wasmtime callback. The resolver is
/// `Arc<dyn Resolver>` so the import handler can clone-hand it across
/// the wasmtime Caller boundary without borrowing through `&mut Store`.
/// `engine` is a cheap-cloning handle (Arc internally) so the resolver
/// bridge can compile + instantiate plugin modules without threading the
/// engine through every call. `plugins` holds the pre-flighted plugin
/// pool keyed by manifest `:name`, populated when a resolver returns
/// `Resolution::Manifest { wasm: Some(_), .. }` and pre-flight passes.
pub(crate) struct StoreData {
    pub resolver: Option<Arc<dyn Resolver>>,
    pub engine: Engine,
    pub plugins: HashMap<String, PluginInstance>,
}

/// A successfully pre-flighted plugin. Each plugin gets its own
/// `Store<()>` because wasmtime requires every `TypedFunc::call` to
/// borrow the store that owns the instance — sharing sjon.wasm's store
/// would couple unrelated linear memories. `exports` holds every
/// `:impl "wasm:<name>"` referenced by the manifest, type-erased to the
/// `(args_ptr, args_len) -> result_ptr` ABI shape.
pub(crate) struct PluginInstance {
    pub store: Store<()>,
    pub memory: Memory,
    pub alloc: PluginAllocFn,
    pub free: PluginFreeFn,
    pub exports: HashMap<String, PluginImplFn>,
}

/// All the WASM-side handles + helpers a `SjonHost` needs.
pub(crate) struct SjonWasm {
    store: Store<StoreData>,
    memory: Memory,
    alloc: PluginAllocFn,
    free: PluginFreeFn,
    host_validate: TypedFunc<(u32, u32, u32, u32), u32>,
    host_eval_expr: TypedFunc<(u32, u32, u32, u32), u32>,
    export_schema: TypedFunc<(u32, u32, u32, u32), u32>,
}

impl SjonWasm {
    pub(crate) fn load_bytes(
        bytes: &[u8],
        resolver: Option<Arc<dyn Resolver>>,
    ) -> std::result::Result<Self, LoadError> {
        let engine = Engine::default();
        let module = Module::from_binary(&engine, bytes).map_err(LoadError::Parse)?;
        let mut store = Store::new(
            &engine,
            StoreData {
                resolver,
                engine: engine.clone(),
                plugins: HashMap::new(),
            },
        );
        let mut linker = Linker::<StoreData>::new(&engine);

        linker
            .func_wrap("env", "sjon_host_resolve", host_resolve)
            .context("wiring env.sjon_host_resolve import")
            .map_err(LoadError::Instantiate)?;

        linker
            .func_wrap("env", "sjon_host_invoke_plugin", host_invoke_plugin)
            .context("wiring env.sjon_host_invoke_plugin import")
            .map_err(LoadError::Instantiate)?;

        let instance = linker
            .instantiate(&mut store, &module)
            .map_err(LoadError::Instantiate)?;

        let memory = instance.get_memory(&mut store, "memory").ok_or_else(|| {
            LoadError::Instantiate(wasmtime::Error::msg("sjon.wasm has no exported `memory`"))
        })?;
        let alloc = instance
            .get_typed_func::<u32, u32>(&mut store, "sjon_alloc")
            .context("getting sjon_alloc export")
            .map_err(LoadError::Instantiate)?;
        let free = instance
            .get_typed_func::<(u32, u32), ()>(&mut store, "sjon_free")
            .context("getting sjon_free export")
            .map_err(LoadError::Instantiate)?;
        let host_validate = instance
            .get_typed_func::<(u32, u32, u32, u32), u32>(&mut store, "sjon_host_validate_document")
            .context("getting sjon_host_validate_document export")
            .map_err(LoadError::Instantiate)?;
        let host_eval_expr = instance
            .get_typed_func::<(u32, u32, u32, u32), u32>(&mut store, "sjon_host_eval_expr")
            .context("getting sjon_host_eval_expr export")
            .map_err(LoadError::Instantiate)?;
        let export_schema = instance
            .get_typed_func::<(u32, u32, u32, u32), u32>(&mut store, "sjon_export_schema")
            .context("getting sjon_export_schema export")
            .map_err(LoadError::Instantiate)?;

        Ok(Self {
            store,
            memory,
            alloc,
            free,
            host_validate,
            host_eval_expr,
            export_schema,
        })
    }

    pub(crate) fn has_resolver(&self) -> bool {
        self.store.data().resolver.is_some()
    }

    /// Run `sjon_host_validate_document(source, options)`. Returns the
    /// raw framed JSON payload.
    pub(crate) fn call_host_validate(
        &mut self,
        source: &[u8],
        options: &[u8],
    ) -> wasmtime::Result<Vec<u8>> {
        let fn_handle = self.host_validate.clone();
        self.call_two_buffer_export(fn_handle, "sjon_host_validate_document", source, options)
    }

    /// Run `sjon_host_eval_expr(source, options)`. Returns the raw
    /// framed JSON payload — `{ value, diagnostics, loadedPlugins }`.
    pub(crate) fn call_host_eval_expr(
        &mut self,
        source: &[u8],
        options: &[u8],
    ) -> wasmtime::Result<Vec<u8>> {
        let fn_handle = self.host_eval_expr.clone();
        self.call_two_buffer_export(fn_handle, "sjon_host_eval_expr", source, options)
    }

    /// Run `sjon_export_schema(source, options)`. Returns the raw
    /// framed JSON envelope `{layout, hostDiagnostics, loadedPlugins,
    /// warnings, aggregated, perPlugin}` produced by
    /// `wasm_common.writeExportSchemaResult`.
    pub(crate) fn call_export_schema(
        &mut self,
        source: &[u8],
        options: &[u8],
    ) -> wasmtime::Result<Vec<u8>> {
        let fn_handle = self.export_schema.clone();
        self.call_two_buffer_export(fn_handle, "sjon_export_schema", source, options)
    }

    /// Shared marshalling skeleton for both two-buffer host exports.
    /// Allocates `source` + `options` in wasm memory, invokes the
    /// passed-in typed export, copies the framed payload out, and
    /// releases both input allocations even when the call fails.
    fn call_two_buffer_export(
        &mut self,
        fn_handle: TypedFunc<(u32, u32, u32, u32), u32>,
        export_name: &'static str,
        source: &[u8],
        options: &[u8],
    ) -> wasmtime::Result<Vec<u8>> {
        let src_alloc_len = u32_len(source.len().max(1));
        let src_ptr = self
            .alloc
            .call(&mut self.store, src_alloc_len)
            .map_err(|e| e.context("sjon_alloc(source)"))?;
        if src_ptr == 0 {
            return Err(wasmtime::Error::msg(
                "sjon_alloc returned null for source buffer (OOM in WASM)",
            ));
        }
        let mut opts_ptr: u32 = 0;
        let opts_len = u32_len(options.len());
        let result = (|| -> wasmtime::Result<Vec<u8>> {
            if !source.is_empty() {
                self.memory
                    .write(&mut self.store, src_ptr as usize, source)
                    .map_err(|e| {
                        wasmtime::Error::from(e).context("writing source bytes into wasm memory")
                    })?;
            }
            opts_ptr = self
                .alloc
                .call(&mut self.store, opts_len)
                .map_err(|e| e.context("sjon_alloc(options)"))?;
            if opts_ptr == 0 {
                return Err(wasmtime::Error::msg(
                    "sjon_alloc returned null for options buffer (OOM in WASM)",
                ));
            }
            self.memory
                .write(&mut self.store, opts_ptr as usize, options)
                .map_err(|e| {
                    wasmtime::Error::from(e).context("writing options bytes into wasm memory")
                })?;
            let result_ptr = fn_handle
                .call(
                    &mut self.store,
                    (src_ptr, u32_len(source.len()), opts_ptr, opts_len),
                )
                .map_err(|e| e.context(export_name))?;
            self.read_framed(result_ptr)
        })();

        // Always free the input buffers, then propagate any error.
        let free_src = self.free.call(&mut self.store, (src_ptr, src_alloc_len));
        let free_opts = if opts_ptr != 0 {
            self.free.call(&mut self.store, (opts_ptr, opts_len))
        } else {
            Ok(())
        };
        let payload = result?;
        free_src.map_err(|e| e.context("sjon_free(source)"))?;
        free_opts.map_err(|e| e.context("sjon_free(options)"))?;
        Ok(payload)
    }

    fn read_framed(&mut self, ptr: u32) -> wasmtime::Result<Vec<u8>> {
        if ptr == 0 {
            return Err(wasmtime::Error::msg("WASM returned null framed pointer"));
        }
        let mut header = [0u8; HEADER_BYTES];
        self.memory
            .read(&mut self.store, ptr as usize, &mut header)
            .map_err(|e| wasmtime::Error::from(e).context("reading framed header"))?;
        let ok = read_u32_le(&header[0..4]);
        let len = read_u32_le(&header[4..8]) as usize;
        let mut payload = vec![0u8; len];
        if len > 0 {
            self.memory
                .read(&mut self.store, ptr as usize + HEADER_BYTES, &mut payload)
                .map_err(|e| wasmtime::Error::from(e).context("reading framed payload"))?;
        }
        let total = u32_len(HEADER_BYTES + len);
        self.free
            .call(&mut self.store, (ptr, total))
            .map_err(|e| e.context("sjon_free(framed result)"))?;
        if ok != 1 {
            let name = String::from_utf8_lossy(&payload).into_owned();
            return Err(wasmtime::Error::msg(format!(
                "WASM call returned ok=0 ({name})"
            )));
        }
        Ok(payload)
    }
}

/// Bridge `env.sjon_host_resolve(ref_ptr, ref_len) -> u32`. Reads the
/// JSON Reference from linear memory, dispatches to the resolver,
/// JSON-encodes the Resolution, allocates a framed buffer via
/// `sjon_alloc`, and returns its pointer. Returns 0 on no-resolver /
/// OOM (Zig adapter folds that into `unresolved_plugin`).
///
/// When the resolver returns `Resolution::Manifest { wasm: Some(_), .. }`
/// we instantiate + pre-flight the plugin here. Pre-flight failures
/// collapse the resolution to `Resolution::Failure` so the diagnostic
/// surfaces at the `(use-plugin …)` span via `phase: 'manifest'`.
fn host_resolve(mut caller: Caller<'_, StoreData>, ref_ptr: u32, ref_len: u32) -> u32 {
    let Some(resolver) = caller.data().resolver.as_ref().map(Arc::clone) else {
        return 0;
    };

    let Some(memory) = caller.get_export("memory").and_then(Extern::into_memory) else {
        return 0;
    };

    let mut ref_bytes = vec![0u8; ref_len as usize];
    if memory
        .read(&caller, ref_ptr as usize, &mut ref_bytes)
        .is_err()
    {
        return frame_error(
            &mut caller,
            "failed to read Reference bytes from WASM memory",
        );
    }

    let parsed: Reference = match serde_json::from_slice(&ref_bytes) {
        Ok(r) => r,
        Err(err) => return frame_error(&mut caller, &format!("failed to decode Reference: {err}")),
    };

    let resolution =
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| resolver.resolve(&parsed)))
            .unwrap_or_else(|payload| Resolution::Failure {
                code: "unresolved_plugin".to_string(),
                detail: panic_message(&*payload),
            });

    let resolution = match resolution {
        Resolution::Manifest {
            source,
            wasm: Some(bytes),
        } => match preflight_and_register(&mut caller, &source, &bytes) {
            Ok(()) => Resolution::Manifest {
                source,
                wasm: Some(bytes),
            },
            Err((code, detail)) => Resolution::Failure { code, detail },
        },
        other => other,
    };

    let json = match serde_json::to_vec(&resolution) {
        Ok(v) => v,
        Err(err) => {
            return frame_error(
                &mut caller,
                &format!("failed to serialize Resolution: {err}"),
            );
        }
    };
    frame_payload(&mut caller, true, &json)
}

/// Instantiate `bytes` with empty imports and pre-flight per spec
/// `docs/executable-plugin-abi.md` §§5-7. On success, register the
/// instance in `caller.data_mut().plugins` keyed by the manifest's
/// `:name`. Returns `(code, detail)` on failure so the caller can emit
/// the corresponding diagnostic.
///
/// Pre-flight order mirrors `hosts/web/SjonHost.ts` exactly:
///   1. `Module::from_binary` — compile-time validity.
///   2. `module.imports()` non-empty → `plugin_import_forbidden`.
///      Checked *before* instantiating: linking against `Linker::new(_)`
///      would otherwise produce a generic `UnknownImport` that masks the
///      forbidden-import case as `plugin_abi_mismatch`.
///   3. `Linker::new(_).instantiate(_, module)` — empty import set.
///   4. `sjon_plugin_abi_version() == 2` → else `plugin_abi_mismatch`.
///   5. Required standard exports (`sjon_plugin_alloc`,
///      `sjon_plugin_free`, `memory`) + every `:impl "wasm:<name>"`
///      declared by the manifest → else `plugin_export_missing`.
fn preflight_and_register(
    caller: &mut Caller<'_, StoreData>,
    source: &str,
    bytes: &[u8],
) -> std::result::Result<(), PluginLoadErr> {
    let Some(plugin_name) = extract_plugin_name(source) else {
        return Ok(());
    };
    let engine = caller.data().engine.clone();

    let module = Module::from_binary(&engine, bytes).map_err(|e| {
        (
            "plugin_abi_mismatch".to_string(),
            format!("plugin \"{plugin_name}\" failed to compile: {e}"),
        )
    })?;
    verify_imports_empty(&module, &plugin_name)?;

    let mut plugin_store = Store::new(&engine, ());
    let linker = Linker::<()>::new(&engine);
    let instance = linker
        .instantiate(&mut plugin_store, &module)
        .map_err(|e| {
            (
                "plugin_abi_mismatch".to_string(),
                format!("plugin \"{plugin_name}\" failed to instantiate: {e}"),
            )
        })?;

    verify_abi_version(&instance, &mut plugin_store, &plugin_name)?;
    let (alloc, free, memory) =
        require_standard_exports(&instance, &mut plugin_store, &plugin_name)?;
    let exports = collect_impl_exports(&instance, &mut plugin_store, source, &plugin_name)?;

    // First-wins: if a plugin with this `:name` is already registered,
    // keep the existing instance. Zig's manifest-load dedupe later emits
    // `duplicate_plugin_name` for the second `(use-plugin …)` and drops
    // it from the schema; without this guard the pool would overwrite
    // the live instance with the about-to-be-rejected one, and eval
    // would dispatch into the wrong module.
    let data = caller.data_mut();
    data.plugins.entry(plugin_name).or_insert(PluginInstance {
        store: plugin_store,
        memory,
        alloc,
        free,
        exports,
    });
    Ok(())
}

/// V1 plugins MUST have an empty import set — verified from the module
/// alone (before instantiation), so the host doesn't waste work on a
/// plugin that wouldn't link anyway.
fn verify_imports_empty(
    module: &Module,
    plugin_name: &str,
) -> std::result::Result<(), PluginLoadErr> {
    if let Some(first) = module.imports().next() {
        return Err((
            "plugin_import_forbidden".to_string(),
            format!(
                "plugin \"{plugin_name}\" declares forbidden import `{}.{}` (v1 plugins MUST have an empty import set)",
                first.module(),
                first.name(),
            ),
        ));
    }
    Ok(())
}

/// Call `sjon_plugin_abi_version()` and check it matches the host's
/// pinned version. `get_func` + `.typed()` rather than `get_typed_func`
/// so a present-but-wrong-signature export surfaces as
/// `plugin_abi_mismatch` instead of `plugin_export_missing` (the host's
/// signature contract is what changed, not the export's presence).
fn verify_abi_version(
    instance: &wasmtime::Instance,
    plugin_store: &mut Store<()>,
    plugin_name: &str,
) -> std::result::Result<(), PluginLoadErr> {
    let abi_fn = require_typed::<(), u32>(
        instance,
        plugin_store,
        "sjon_plugin_abi_version",
        plugin_name,
    )?;
    let abi = abi_fn.call(&mut *plugin_store, ()).map_err(|e| {
        (
            "plugin_abi_mismatch".to_string(),
            format!("plugin \"{plugin_name}\" sjon_plugin_abi_version() trapped: {e}"),
        )
    })?;
    if abi != PLUGIN_ABI_VERSION {
        return Err((
            "plugin_abi_mismatch".to_string(),
            format!(
                "plugin \"{plugin_name}\" reports ABI version {abi}; host implements {PLUGIN_ABI_VERSION}"
            ),
        ));
    }
    Ok(())
}

/// Pull the three required standard exports — `sjon_plugin_alloc`,
/// `sjon_plugin_free`, `memory`. Missing-vs-wrong-signature stays
/// distinguished through `require_typed`.
fn require_standard_exports(
    instance: &wasmtime::Instance,
    plugin_store: &mut Store<()>,
    plugin_name: &str,
) -> std::result::Result<(PluginAllocFn, PluginFreeFn, Memory), PluginLoadErr> {
    let alloc =
        require_typed::<u32, u32>(instance, plugin_store, "sjon_plugin_alloc", plugin_name)?;
    let free =
        require_typed::<(u32, u32), ()>(instance, plugin_store, "sjon_plugin_free", plugin_name)?;
    let memory = instance
        .get_memory(&mut *plugin_store, "memory")
        .ok_or_else(|| {
            (
                "plugin_export_missing".to_string(),
                format!("plugin \"{plugin_name}\" is missing the required `memory` export"),
            )
        })?;
    Ok((alloc, free, memory))
}

/// Build the per-manifest `:impl "wasm:<name>"` typed-func table. Same
/// missing-vs-wrong-sig split as the standard exports: every impl is
/// contractually `(i32, i32) -> i32`.
fn collect_impl_exports(
    instance: &wasmtime::Instance,
    plugin_store: &mut Store<()>,
    source: &str,
    plugin_name: &str,
) -> std::result::Result<HashMap<String, PluginImplFn>, PluginLoadErr> {
    let mut exports: HashMap<String, PluginImplFn> = HashMap::new();
    for name in extract_wasm_impl_names(source) {
        let Some(f) = instance.get_func(&mut *plugin_store, &name) else {
            return Err((
                "plugin_export_missing".to_string(),
                format!(
                    "plugin \"{plugin_name}\" manifest declares `:impl \"wasm:{name}\"` but the binary has no such export"
                ),
            ));
        };
        let typed = f.typed::<(u32, u32), u32>(&*plugin_store).map_err(|_| {
            (
                "plugin_abi_mismatch".to_string(),
                format!(
                    "plugin \"{plugin_name}\" export `{name}` has the wrong signature; expected `(i32, i32) -> i32`"
                ),
            )
        })?;
        exports.insert(name, typed);
    }
    Ok(exports)
}

/// Look up `name` on the plugin instance and assert it has signature
/// `(P) -> R`. Distinguishes the "missing export" case
/// (`plugin_export_missing`) from the "present but wrong signature" case
/// (`plugin_abi_mismatch`) — `get_typed_func` collapses both into one
/// `Err` and would silently mislabel signature mismatches.
fn require_typed<P, R>(
    instance: &wasmtime::Instance,
    store: &mut Store<()>,
    name: &str,
    plugin_name: &str,
) -> std::result::Result<TypedFunc<P, R>, PluginLoadErr>
where
    P: wasmtime::WasmParams,
    R: wasmtime::WasmResults,
{
    let func = instance.get_func(&mut *store, name).ok_or_else(|| {
        (
            "plugin_export_missing".to_string(),
            format!("plugin \"{plugin_name}\" is missing the required `{name}` export"),
        )
    })?;
    func.typed::<P, R>(&*store).map_err(|_| {
        (
            "plugin_abi_mismatch".to_string(),
            format!("plugin \"{plugin_name}\" export `{name}` has the wrong signature"),
        )
    })
}

/// Bridge `env.sjon_host_invoke_plugin(req_ptr, req_len) -> u32`. Reads
/// the per-call request payload (plugin name + export name + encoded
/// args) from sjon memory, dispatches into the plugin, copies the result
/// frame back into sjon memory, and returns its pointer. Wire format is
/// pinned by `src/wasm_plugin_invoker.zig` and `src/PluginValueCodec.zig`.
fn host_invoke_plugin(mut caller: Caller<'_, StoreData>, req_ptr: u32, req_len: u32) -> u32 {
    let Some(sjon_memory) = caller.get_export("memory").and_then(Extern::into_memory) else {
        return 0;
    };

    let mut req_bytes = vec![0u8; req_len as usize];
    if sjon_memory
        .read(&caller, req_ptr as usize, &mut req_bytes)
        .is_err()
    {
        return frame_invoke_error(&mut caller, ALLOC_CODE, "failed to read invoke request");
    }

    let Some((plugin_name, export_name, args_bytes)) = parse_invoke_request(&req_bytes) else {
        return frame_invoke_error(&mut caller, ALLOC_CODE, "malformed invoke request");
    };

    let outcome = invoke_with_caller(&mut caller, &plugin_name, &export_name, &args_bytes);

    match outcome {
        Ok((ok, payload)) => frame_invoke_payload(&mut caller, ok, &payload),
        Err(InvokeFailure::Trap(msg)) => frame_invoke_error(&mut caller, TRAP_CODE, &msg),
        Err(InvokeFailure::Alloc(msg)) => frame_invoke_error(&mut caller, ALLOC_CODE, &msg),
    }
}

enum InvokeFailure {
    Trap(String),
    Alloc(String),
}

/// Take a mutable borrow of the plugin pool, look up the requested
/// instance and export, then hand off to `invoke_plugin_export`. Split
/// out from `host_invoke_plugin` so the `&mut caller.data_mut()` borrow
/// is dropped before we re-touch `caller` to write the result frame.
fn invoke_with_caller(
    caller: &mut Caller<'_, StoreData>,
    plugin_name: &str,
    export_name: &str,
    args: &[u8],
) -> std::result::Result<(u32, Vec<u8>), InvokeFailure> {
    let plugin = caller
        .data_mut()
        .plugins
        .get_mut(plugin_name)
        .ok_or_else(|| {
            InvokeFailure::Alloc(format!(
                "no instance for plugin \"{plugin_name}\" (was pre-flight skipped?)"
            ))
        })?;
    let export_fn = plugin.exports.get(export_name).cloned().ok_or_else(|| {
        InvokeFailure::Alloc(format!(
            "plugin \"{plugin_name}\" has no export \"{export_name}\""
        ))
    })?;
    invoke_plugin_export(plugin, export_fn, args)
}

/// Per-call alloc/copy/call/read/free across the plugin's linear memory.
/// Returns the plugin's framed `(ok, payload)` as-is — the caller
/// re-frames it into sjon memory. Trap → `InvokeFailure::Trap`; plugin
/// alloc returning null / memory read fail / null result pointer →
/// `InvokeFailure::Alloc`.
fn invoke_plugin_export(
    plugin: &mut PluginInstance,
    export_fn: PluginImplFn,
    args: &[u8],
) -> std::result::Result<(u32, Vec<u8>), InvokeFailure> {
    // `sjon_plugin_alloc(0)` returns null by spec. In practice the Zig
    // invoker always sends at least `[u32 count=0]` (4 bytes), so
    // `args.is_empty()` only happens on a malformed request; the
    // `max(1)` guards the alloc call against that pathological case.
    let args_alloc_len = u32_len(args.len().max(1));
    let args_ptr = plugin
        .alloc
        .call(&mut plugin.store, args_alloc_len)
        .map_err(|e| InvokeFailure::Trap(format!("plugin sjon_plugin_alloc trapped: {e}")))?;
    if args_ptr == 0 {
        return Err(InvokeFailure::Alloc(format!(
            "plugin sjon_plugin_alloc({args_alloc_len}) returned null"
        )));
    }

    if !args.is_empty()
        && plugin
            .memory
            .write(&mut plugin.store, args_ptr as usize, args)
            .is_err()
    {
        best_effort_free(plugin, args_ptr, args_alloc_len);
        return Err(InvokeFailure::Trap(
            "failed to write args into plugin memory (plugin sjon_plugin_alloc returned an out-of-bounds pointer)".into(),
        ));
    }

    let result_ptr = match export_fn.call(&mut plugin.store, (args_ptr, u32_len(args.len()))) {
        Ok(p) => p,
        Err(trap) => {
            best_effort_free(plugin, args_ptr, args_alloc_len);
            return Err(InvokeFailure::Trap(format!("{trap}")));
        }
    };

    if result_ptr == 0 {
        best_effort_free(plugin, args_ptr, args_alloc_len);
        return Err(InvokeFailure::Alloc(
            "plugin export returned null pointer".into(),
        ));
    }

    let mut header = [0u8; HEADER_BYTES];
    if plugin
        .memory
        .read(&plugin.store, result_ptr as usize, &mut header)
        .is_err()
    {
        best_effort_free(plugin, args_ptr, args_alloc_len);
        return Err(InvokeFailure::Trap(
            "plugin export returned an out-of-bounds frame pointer".into(),
        ));
    }
    let ok = read_u32_le(&header[0..4]);
    let len = read_u32_le(&header[4..8]) as usize;

    if len > MAX_PLUGIN_RESULT_FRAME {
        // Refuse to honor the reported length — allocating a mirror
        // buffer of this size would be a host-side memory attack. Don't
        // call `sjon_plugin_free` on the bogus frame (we don't trust
        // the size); release the args buffer and bail.
        best_effort_free(plugin, args_ptr, args_alloc_len);
        return Err(InvokeFailure::Alloc(format!(
            "plugin export returned a framed result of {len} bytes; host caps plugin frames at {MAX_PLUGIN_RESULT_FRAME} bytes"
        )));
    }

    let mut payload = vec![0u8; len];
    if len > 0
        && plugin
            .memory
            .read(
                &plugin.store,
                result_ptr as usize + HEADER_BYTES,
                &mut payload,
            )
            .is_err()
    {
        best_effort_free(plugin, args_ptr, args_alloc_len);
        best_effort_free(plugin, result_ptr, u32_len(HEADER_BYTES + len));
        return Err(InvokeFailure::Trap(
            "plugin export framed result payload extends past linear memory".into(),
        ));
    }

    // Plugin owns the framed buffer; release it now while we have the
    // handle (spec §11).
    best_effort_free(plugin, result_ptr, u32_len(HEADER_BYTES + len));
    best_effort_free(plugin, args_ptr, args_alloc_len);

    Ok((ok, payload))
}

/// Parse a binary invoke request:
///
///   [u32 `plugin_name_len`][`plugin_name` utf-8]
///   [u32 `export_name_len`][`export_name` utf-8]
///   [`args_bytes` ...]              (`PluginValueCodec.encodeArgs` format)
///
/// Returns `None` on truncation or non-utf8 names. The opaque args tail
/// is passed through to the plugin verbatim — the plugin re-parses it
/// using the same codec format.
pub fn parse_invoke_request(buf: &[u8]) -> Option<(String, String, Vec<u8>)> {
    let mut off = 0;
    if off + 4 > buf.len() {
        return None;
    }
    let plen = read_u32_le(&buf[off..off + 4]) as usize;
    off += 4;
    if off + plen > buf.len() {
        return None;
    }
    let pname = std::str::from_utf8(&buf[off..off + plen]).ok()?.to_string();
    off += plen;
    if off + 4 > buf.len() {
        return None;
    }
    let elen = read_u32_le(&buf[off..off + 4]) as usize;
    off += 4;
    if off + elen > buf.len() {
        return None;
    }
    let ename = std::str::from_utf8(&buf[off..off + elen]).ok()?.to_string();
    off += elen;
    Some((pname, ename, buf[off..].to_vec()))
}

/// Allocate sjon memory, write a `[u32 ok][u32 len][payload]` frame into
/// it, and return the pointer. The Zig invoker frees `8 + len` after
/// reading.
fn frame_invoke_payload(caller: &mut Caller<'_, StoreData>, ok: u32, payload: &[u8]) -> u32 {
    let total = HEADER_BYTES + payload.len();
    let Some(alloc) = caller
        .get_export("sjon_alloc")
        .and_then(Extern::into_func)
        .and_then(|f| f.typed::<u32, u32>(&caller).ok())
    else {
        return 0;
    };
    let Some(memory) = caller.get_export("memory").and_then(Extern::into_memory) else {
        return 0;
    };
    let Ok(ptr) = alloc.call(&mut *caller, u32_len(total)) else {
        return 0;
    };
    if ptr == 0 {
        return 0;
    }
    let mut header = [0u8; HEADER_BYTES];
    header[0..4].copy_from_slice(&ok.to_le_bytes());
    header[4..8].copy_from_slice(&u32_len(payload.len()).to_le_bytes());
    if memory.write(&mut *caller, ptr as usize, &header).is_err() {
        return 0;
    }
    if !payload.is_empty()
        && memory
            .write(&mut *caller, ptr as usize + HEADER_BYTES, payload)
            .is_err()
    {
        return 0;
    }
    ptr
}

/// Build a structured-error frame (`PluginValueCodec.encodeErrFrame`
/// byte layout) and write it to sjon memory. `code` should be one of
/// `_internal_trap` / `_alloc` so the Zig invoker maps it onto
/// `PluginFuncTrapped` / `PluginFuncAllocFailed` respectively.
fn frame_invoke_error(caller: &mut Caller<'_, StoreData>, code: &str, detail: &str) -> u32 {
    let code_bytes = code.as_bytes();
    let detail_bytes = detail.as_bytes();
    let payload_len = 4 + code_bytes.len() + 4 + detail_bytes.len();
    let mut payload = vec![0u8; payload_len];
    payload[0..4].copy_from_slice(&u32_len(code_bytes.len()).to_le_bytes());
    payload[4..4 + code_bytes.len()].copy_from_slice(code_bytes);
    let detail_off = 4 + code_bytes.len();
    payload[detail_off..detail_off + 4].copy_from_slice(&u32_len(detail_bytes.len()).to_le_bytes());
    payload[detail_off + 4..detail_off + 4 + detail_bytes.len()].copy_from_slice(detail_bytes);
    frame_invoke_payload(caller, 0, &payload)
}

/// Pull the manifest's plugin `:name` out of `source`. Mirrors the JS
/// regex `/\(\s*plugin\s+[^)]*?:name\s+([A-Za-z_][\w-]*)/` — anchor on
/// the first `(plugin` form, scan its body up to (but not across) the
/// next `)`, and capture the identifier following `:name`. Returns
/// `None` if no `:name` is present in the first plugin form; the loader
/// then emits `invalid_manifest` and pre-flight is a no-op.
fn extract_plugin_name(source: &str) -> Option<String> {
    let bytes = source.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'(' {
            i += 1;
            continue;
        }
        let mut j = i + 1;
        while j < bytes.len() && (bytes[j] as char).is_ascii_whitespace() {
            j += 1;
        }
        if j + 6 > bytes.len()
            || &bytes[j..j + 6] != b"plugin"
            || !(bytes[j + 6] as char).is_ascii_whitespace()
        {
            i = j;
            continue;
        }
        // We're inside the first `(plugin …)` form's body — scan up to
        // (but not across) the matching `)`. Same behavior as the JS
        // regex's `[^)]*?`.
        let mut k = j + 7;
        while k < bytes.len() && bytes[k] != b')' {
            if bytes[k..].starts_with(b":name") {
                let mut s = k + 5;
                while s < bytes.len() && (bytes[s] as char).is_ascii_whitespace() {
                    s += 1;
                }
                let start = s;
                if s < bytes.len() && (bytes[s].is_ascii_alphabetic() || bytes[s] == b'_') {
                    s += 1;
                    while s < bytes.len()
                        && (bytes[s].is_ascii_alphanumeric()
                            || bytes[s] == b'_'
                            || bytes[s] == b'-')
                    {
                        s += 1;
                    }
                    return std::str::from_utf8(&bytes[start..s]).ok().map(String::from);
                }
            }
            k += 1;
        }
        return None;
    }
    None
}

/// Collect every `:impl "wasm:<name>"` export name declared by `source`.
/// Used by pre-flight to verify the plugin binary actually defines each
/// referenced export.
fn extract_wasm_impl_names(source: &str) -> Vec<String> {
    let bytes = source.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if !bytes[i..].starts_with(b":impl") {
            i += 1;
            continue;
        }
        let mut j = i + 5;
        while j < bytes.len() && (bytes[j] as char).is_ascii_whitespace() {
            j += 1;
        }
        if j >= bytes.len() || bytes[j] != b'"' {
            i += 5;
            continue;
        }
        let body_start = j + 1;
        let mut k = body_start;
        while k < bytes.len() && bytes[k] != b'"' {
            k += 1;
        }
        if k > body_start && bytes[body_start..k].starts_with(b"wasm:") {
            let name_start = body_start + 5;
            if let Ok(name) = std::str::from_utf8(&bytes[name_start..k]) {
                out.push(name.to_string());
            }
        }
        i = k + 1;
    }
    out
}

fn frame_error(caller: &mut Caller<'_, StoreData>, message: &str) -> u32 {
    frame_payload(caller, false, message.as_bytes())
}

fn frame_payload(caller: &mut Caller<'_, StoreData>, ok: bool, payload: &[u8]) -> u32 {
    let total = HEADER_BYTES + payload.len();
    let Some(alloc) = caller
        .get_export("sjon_alloc")
        .and_then(Extern::into_func)
        .and_then(|f| f.typed::<u32, u32>(&caller).ok())
    else {
        return 0;
    };
    let Some(memory) = caller.get_export("memory").and_then(Extern::into_memory) else {
        return 0;
    };
    let Ok(ptr) = alloc.call(&mut *caller, u32_len(total)) else {
        return 0;
    };
    if ptr == 0 {
        return 0;
    }
    let mut header = [0u8; HEADER_BYTES];
    header[0..4].copy_from_slice(&u32::from(ok).to_le_bytes());
    header[4..8].copy_from_slice(&u32_len(payload.len()).to_le_bytes());
    if memory.write(&mut *caller, ptr as usize, &header).is_err() {
        return 0;
    }
    if !payload.is_empty()
        && memory
            .write(&mut *caller, ptr as usize + HEADER_BYTES, payload)
            .is_err()
    {
        return 0;
    }
    ptr
}

fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(s) = payload.downcast_ref::<&'static str>() {
        return (*s).to_string();
    }
    if let Some(s) = payload.downcast_ref::<String>() {
        return s.clone();
    }
    "resolver panicked".to_string()
}
