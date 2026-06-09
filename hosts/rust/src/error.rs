//! Public error surface for `SjonHost`. Every variant carries a typed
//! source (`std::io::Error`, `wasmtime::Error`, `serde_json::Error`) so
//! callers can `match` on the shape without pulling an `anyhow`
//! dependency (`ERROR_HANDLING.md:426` — library APIs must not leak
//! `anyhow::Error`). Internal `wasm.rs` keeps `wasmtime::Error` chains
//! attached via `.context(…)` so callers walking `source()` still see
//! the original wasmtime detail.

use std::path::PathBuf;

/// Errors returned by the public `SjonHost` surface. Variants wrap the
/// typed source error directly (no anyhow indirection); callers can
/// destructure each `source` field for programmatic handling.
#[derive(Debug, thiserror::Error)]
#[non_exhaustive]
pub enum SjonHostError {
    /// `std::fs::read` on the path passed to `SjonHost::load` failed —
    /// usually `NotFound` or a permission error.
    #[error("reading wasm file {path}: {source:#}")]
    WasmRead {
        /// Path passed to `SjonHost::load`.
        path: PathBuf,
        /// Underlying `std::io::Error`.
        #[source]
        source: std::io::Error,
    },
    /// `Module::from_binary` rejected the bytes. Either the file isn't
    /// WASM, or wasmtime / the host disagree on the spec the module
    /// targets.
    #[error("parsing sjon.wasm: {0:#}")]
    WasmParse(#[source] wasmtime::Error),
    /// `Linker::instantiate` failed — typically a missing/extra import
    /// or a memory limit hit at startup. The inner error carries the
    /// wasmtime-side detail.
    #[error("instantiating sjon.wasm: {0:#}")]
    WasmInstantiate(#[source] wasmtime::Error),
    /// A typed-func call into a sjon.wasm export trapped or returned
    /// an error result frame. `export` names which one
    /// (`sjon_host_validate_document`, `sjon_host_eval_expr`,
    /// `sjon_export_schema`, etc.). Display flattens the wasmtime
    /// error chain via `{:#}` so the framed WASM error name surfaces
    /// in the top-level message (callers — and tests — can
    /// string-match on the Zig-side diagnostic ident without walking
    /// `source()`).
    #[error("calling WASM export {export}: {source:#}")]
    WasmCall {
        /// Export name that trapped (e.g. `"sjon_host_validate_document"`).
        export: &'static str,
        /// Underlying wasmtime error chain.
        #[source]
        source: wasmtime::Error,
    },
    /// `serde_json::from_slice` rejected the framed payload returned by
    /// WASM. `kind` distinguishes the three envelopes
    /// (`HostResult`, `HostEvalResult`, `ExportSchemaResult`).
    #[error("decoding {kind} JSON: {source}")]
    JsonDecode {
        /// Envelope kind being decoded
        /// (`"HostResult"` / `"HostEvalResult"` / `"ExportSchemaResult"`).
        kind: &'static str,
        /// Underlying `serde_json` error.
        #[source]
        source: serde_json::Error,
    },
    /// `serde_json::to_vec` failed to encode an options struct on its
    /// way into WASM. Shouldn't happen in practice (the option types
    /// are all `Serialize`-clean) but the variant exists so the
    /// public surface is exhaustive over the call path.
    #[error("encoding {kind} JSON: {source}")]
    JsonEncode {
        /// Options struct being encoded
        /// (`"HostOptions"` / `"ExportSchemaOptions"`).
        kind: &'static str,
        /// Underlying `serde_json` error.
        #[source]
        source: serde_json::Error,
    },
}
