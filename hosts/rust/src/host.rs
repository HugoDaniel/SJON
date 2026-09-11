//! `SjonHost` — public entry point. `load(wasm_path, resolver)` then
//! `validate_document(source, &options)`. Mirrors `hosts/web/SjonHost.ts`
//! shape so the Rust host's diagnostic stream is byte-identical to the
//! JS host over the conformance corpus.

use std::path::Path;
use std::sync::Arc;

use crate::diagnostic::{
    Address, ExportSchemaOptions, ExportSchemaResult, HostEvalResult, HostOptions, HostResult,
    NodeTable, WasmExportSchemaOptions, WasmHostOptions,
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

    /// Query a pattern document (`PatternQuery` over WASM) on the half-open
    /// tick window `[begin, end)` with RNG `seed`. Returns the framed SJON
    /// text — `(haps …)` on success, `(diagnostics …)` when the query
    /// collected any. The pattern vocabulary is built into the artifact, so
    /// no resolver / plugin schema is needed.
    pub fn query_pattern(
        &mut self,
        source: &str,
        begin: i64,
        end: i64,
        seed: i64,
    ) -> Result<String, SjonHostError> {
        let payload = self
            .wasm
            .call_query_pattern(source.as_bytes(), begin, end, seed)
            .map_err(|err| SjonHostError::WasmCall {
                export: "sjon_query_pattern",
                source: err,
            })?;
        Ok(String::from_utf8_lossy(&payload).into_owned())
    }

    fn encode_wasm_options(&self, options: &HostOptions) -> Result<Vec<u8>, SjonHostError> {
        let wasm_opts = WasmHostOptions {
            project_root: options.project_root.as_deref(),
            project_file: options.project_file.as_deref(),
            failure_policy: options.failure_policy,
            held_symbol: options.held_symbol.as_deref(),
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

    /// Address the node at `[start, end)`: the innermost node containing
    /// that byte range, or `None` when the range is inside no root.
    ///
    /// Mirrors `SjonEncoder.addressOfSpan` over WASM. `root` and `path`
    /// on the returned [`Address`] are an edit action's two fields
    /// verbatim. Pass `start == end` for a caret.
    ///
    /// A range covering a whole `:key value` pair answers the enclosing
    /// *form*: §11.2 addresses a pair's value, so an edit over the pair
    /// itself is a `set_keyword` on the form.
    ///
    /// Offsets are UTF-8 bytes. Answers on the partial tree a recovery
    /// leaves behind, so a document mid-edit still has addresses.
    pub fn address_of_span(
        &mut self,
        source: &str,
        start: u32,
        end: u32,
    ) -> Result<Option<Address>, SjonHostError> {
        let payload = self
            .wasm
            .call_address_of_span(source.as_bytes(), start, end)
            .map_err(|err| SjonHostError::WasmCall {
                export: "sjon_address_of_span",
                source: err,
            })?;
        serde_json::from_slice(&payload).map_err(|err| SjonHostError::JsonDecode {
            kind: "Address",
            source: err,
        })
    }

    /// Every addressable node of `source`, flat and in pre-order, with
    /// the parse diagnostics beside it. Mirrors `SjonEncoder.nodeTable`
    /// over WASM, payload for payload.
    ///
    /// A row's §11.2 path is the chain of `seg` up the `parent` links;
    /// pair it with the row's `root` and the two are an edit action's
    /// `root` and `path`. Offsets are UTF-8 bytes.
    ///
    /// Rows come back for a document that does not parse too — read
    /// `diagnostics` to learn whether that is what you have.
    pub fn node_table(&mut self, source: &str) -> Result<NodeTable, SjonHostError> {
        let payload = self
            .wasm
            .call_node_table(source.as_bytes())
            .map_err(|err| SjonHostError::WasmCall {
                export: "sjon_node_table",
                source: err,
            })?;
        serde_json::from_slice(&payload).map_err(|err| SjonHostError::JsonDecode {
            kind: "NodeTable",
            source: err,
        })
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
