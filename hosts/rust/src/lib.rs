//! `sjon-host` — Rust host wrapping `sjon.wasm` through wasmtime.
//!
//! Single-language port of `hosts/web/SjonHost.ts` over the same WASM
//! ABI. The diagnostic stream is byte-identical (`(code, path)`) to the
//! Zig CLI, the typescript-parity reference, and the D5 web host across
//! the conformance corpus.
//!
//! Entry point: [`SjonHost::load`] then [`SjonHost::validate_document`].

mod diagnostic;
mod error;
mod filesystem_resolver;
mod host;
mod resolver;
pub(crate) mod sjon_subset;
mod wasm;

pub use diagnostic::{
    Address, AggregatedArtifacts, DefaultOrigin, EvalResultEntry, ExportLayout, ExportLayoutOption,
    ExportSchemaOptions, ExportSchemaResult, ExportTarget, ExportWarning, FailurePolicy,
    HostDiagnostic, HostEvalResult, HostOptions, HostResult, MaterializedDefault, NodeRow,
    NodeTable, ParseDiagnostic, PathStep, PerPluginArtifact, Phase, PluginSummary, Severity, Span,
};
pub use error::SjonHostError;
pub use filesystem_resolver::FilesystemResolver;
pub use host::SjonHost;
pub use resolver::{FnResolver, Reference, Resolution, Resolver};

/// Internal entry points exposed for fuzz targets and integration
/// tests only. NOT part of the stable public API — symbols here may
/// move or disappear without notice. The `__` prefix +
/// `#[doc(hidden)]` keep them out of rustdoc; `cargo-fuzz` and the
/// `tests/common` helpers re-export from here so the underlying
/// parsers can stay `pub(crate)`.
#[doc(hidden)]
pub mod __fuzz_only {
    pub use crate::sjon_subset::{
        Node, find_form_by_head, parse_single_form, parse_top_level_forms,
    };
    pub use crate::wasm::parse_invoke_request;
}
