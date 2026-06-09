//! `SjonHost` — public entry point. `load(wasm_path, resolver)` then
//! `validate_document(source, &options)`. Mirrors `hosts/web/SjonHost.ts`
//! shape so the Rust host's diagnostic stream is byte-identical to the
//! JS host over the conformance corpus.

use std::path::Path;
use std::sync::Arc;

use crate::diagnostic::{
    ExportSchemaOptions, ExportSchemaResult, HostEvalResult, HostOptions, HostResult,
    WasmExportSchemaOptions, WasmHostOptions,
};
use crate::error::SjonHostError;
use crate::resolver::Resolver;
use crate::wasm::{LoadError, SjonWasm};

/// Rust host wrapping a loaded `sjon.wasm` instance. Owns the
/// wasmtime `Store` / `Linker` and the per-host plugin pool;
/// `validate_document` / `eval_expr` / `export_schema` are the three
/// public entry points.
pub struct SjonHost {
    wasm: SjonWasm,
}

impl SjonHost {
    /// Load `sjon.wasm` and bind the resolver. The resolver runs sync
    /// during validation; panics inside it produce an `unresolved_plugin`
    /// diagnostic carrying the panic message (caught via
    /// `panic::catch_unwind`).
    #[must_use = "the loaded SjonHost owns the wasmtime store; drop it on the floor and the resolver / plugin instances leak"]
    pub fn load(
        wasm_path: &Path,
        resolver: Option<Arc<dyn Resolver>>,
    ) -> Result<Self, SjonHostError> {
        let bytes = std::fs::read(wasm_path).map_err(|err| SjonHostError::WasmRead {
            path: wasm_path.to_path_buf(),
            source: err,
        })?;
        Self::load_bytes(&bytes, resolver)
    }

    /// Variant for callers who already have the WASM bytes in memory
    /// (e.g. embedded via `include_bytes!`).
    #[must_use = "the loaded SjonHost owns the wasmtime store; drop it on the floor and the resolver / plugin instances leak"]
    pub fn load_bytes(
        bytes: &[u8],
        resolver: Option<Arc<dyn Resolver>>,
    ) -> Result<Self, SjonHostError> {
        let wasm = SjonWasm::load_bytes(bytes, resolver).map_err(|e| match e {
            LoadError::Parse(err) => SjonHostError::WasmParse(err),
            LoadError::Instantiate(err) => SjonHostError::WasmInstantiate(err),
        })?;
        Ok(Self { wasm })
    }

    /// Validate `source` through the WASM-backed `Host.validateDocument`
    /// pipeline. Returns the parsed `HostResult` with any
    /// `options.project_diagnostics` prepended (matches D5's JS-side
    /// merge: keeps `sjon.wasm` filesystem-agnostic).
    pub fn validate_document(
        &mut self,
        source: &str,
        options: &HostOptions,
    ) -> Result<HostResult, SjonHostError> {
        let opts_bytes = self.encode_wasm_options(options)?;
        let payload = self
            .wasm
            .call_host_validate(source.as_bytes(), &opts_bytes)
            .map_err(|err| SjonHostError::WasmCall {
                export: "sjon_host_validate_document",
                source: err,
            })?;
        let mut result: HostResult =
            serde_json::from_slice(&payload).map_err(|err| SjonHostError::JsonDecode {
                kind: "HostResult",
                source: err,
            })?;
        prepend_project_diagnostics(&mut result.diagnostics, options);
        Ok(result)
    }

    /// Evaluate one expression against the resolved plugin schema.
    /// Source must contain exactly one data-forest form (plugin
    /// declarations + `(use-plugin …)` references are allowed
    /// alongside it). Plugin expr-funcs declared by loaded plugins
    /// dispatch through `lookupExprFunc`, so `(double 21)`,
    /// `(count-done items)`, etc. are callable directly.
    pub fn eval_expr(
        &mut self,
        source: &str,
        options: &HostOptions,
    ) -> Result<HostEvalResult, SjonHostError> {
        let opts_bytes = self.encode_wasm_options(options)?;
        let payload = self
            .wasm
            .call_host_eval_expr(source.as_bytes(), &opts_bytes)
            .map_err(|err| SjonHostError::WasmCall {
                export: "sjon_host_eval_expr",
                source: err,
            })?;
        let mut result: HostEvalResult =
            serde_json::from_slice(&payload).map_err(|err| SjonHostError::JsonDecode {
                kind: "HostEvalResult",
                source: err,
            })?;
        prepend_project_diagnostics(&mut result.diagnostics, options);
        Ok(result)
    }

    fn encode_wasm_options(&self, options: &HostOptions) -> Result<Vec<u8>, SjonHostError> {
        let wasm_opts = WasmHostOptions {
            project_root: options.project_root.as_deref(),
            project_file: options.project_file.as_deref(),
            failure_policy: options.failure_policy,
            has_resolver: self.wasm.has_resolver(),
        };
        serde_json::to_vec(&wasm_opts).map_err(|err| SjonHostError::JsonEncode {
            kind: "HostOptions",
            source: err,
        })
    }

    /// Export a JSON Schema 2020-12 + TypeScript `.d.ts` (+ optional
    /// intermediate IR) for the plugin schema declared in `source`.
    /// Mirrors `Host.exportSchemaFromSource` over WASM: parses,
    /// aggregates, validates, and lowers in one call. Returns the
    /// decoded envelope `{layout, hostDiagnostics, loadedPlugins,
    /// warnings, aggregated, perPlugin}`.
    pub fn export_schema(
        &mut self,
        source: &str,
        options: &ExportSchemaOptions,
    ) -> Result<ExportSchemaResult, SjonHostError> {
        let wasm_opts = WasmExportSchemaOptions {
            project_root: options.project_root.as_deref(),
            project_file: options.project_file.as_deref(),
            failure_policy: options.failure_policy,
            has_resolver: self.wasm.has_resolver(),
            target: options.target,
            layout: options.layout,
            draft: "2020-12",
        };
        let opts_bytes =
            serde_json::to_vec(&wasm_opts).map_err(|err| SjonHostError::JsonEncode {
                kind: "ExportSchemaOptions",
                source: err,
            })?;
        let payload = self
            .wasm
            .call_export_schema(source.as_bytes(), &opts_bytes)
            .map_err(|err| SjonHostError::WasmCall {
                export: "sjon_export_schema",
                source: err,
            })?;
        let result: ExportSchemaResult =
            serde_json::from_slice(&payload).map_err(|err| SjonHostError::JsonDecode {
                kind: "ExportSchemaResult",
                source: err,
            })?;
        Ok(result)
    }
}

fn prepend_project_diagnostics(
    diagnostics: &mut Vec<crate::diagnostic::HostDiagnostic>,
    options: &HostOptions,
) {
    if options.project_diagnostics.is_empty() {
        return;
    }
    let mut merged = Vec::with_capacity(options.project_diagnostics.len() + diagnostics.len());
    merged.extend(options.project_diagnostics.iter().cloned());
    merged.append(diagnostics);
    *diagnostics = merged;
}

// Auto-trait pin: a future field that's `!Send` or `!Sync` (e.g. a
// stray `Cell` or `Rc`) should break the build here rather than
// silently regress the public contract. The wasmtime `Store` chain
// underlying `SjonWasm` is `Send + Sync` today; revisit when adding
// any field whose auto-traits aren't obvious.
const _: fn() = || {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<SjonHost>();
};
