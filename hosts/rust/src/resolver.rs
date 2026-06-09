//! `(use-plugin …)` resolver surface.
//!
//! Mirrors `hosts/web/SjonHost.ts` Reference / Resolution shapes
//! verbatim — they're the cross-host contract over the same `sjon.wasm`
//! ABI. The trait keeps state ergonomic (the filesystem resolver carries
//! a `HashMap` of indexed manifests); `FnResolver` is a thin closure
//! adapter for short-lived test resolvers.

use serde::{Deserialize, Serialize};

use crate::diagnostic::Span;

/// One `(use-plugin …)` reference WASM hands back to the host. Field
/// shape mirrors `src/wasm_host_resolver.zig`'s JSON encoder — every
/// optional is present (as `null`) rather than omitted.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Reference {
    /// Plugin `:name` from the `(use-plugin …)` form.
    pub name: String,
    /// Explicit `:path` override, if the form supplied one.
    pub explicit_path: Option<String>,
    /// `:version` constraint, if present.
    pub version: Option<String>,
    /// `:hash` integrity pin, if present.
    pub hash: Option<String>,
    /// Source span of the `(use-plugin …)` form.
    pub span: Span,
}

/// A resolver's reply for a Reference. The serialized shape matches
/// `wasm_host_resolver.zig`'s expected payload — `manifest` carries the
/// manifest source bytes plus an optional WASM artifact (D7); `failure`
/// carries a code/detail pair the host folds into an `unresolved_plugin`
/// (or matching) diagnostic.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[non_exhaustive]
#[must_use = "a Resolution must be returned to the bridge; dropping it collapses to unresolved_plugin"]
pub enum Resolution {
    /// Sidecar plugin envelope: a parsed-on-the-Zig-side manifest, plus
    /// optional WASM bytes. When `wasm` is `Some`, the host instantiates
    /// the plugin and runs D7-exec pre-flight (ABI version, required +
    /// declared exports, import emptiness) before passing the manifest
    /// through to Zig. Pre-flight failures collapse to a
    /// `Resolution::Failure` carrying `plugin_abi_mismatch` /
    /// `plugin_export_missing` / `plugin_import_forbidden`.
    Manifest {
        /// Manifest source bytes (UTF-8 SJON text).
        source: String,
        /// Optional WASM artifact for D7 plugin-exec.
        wasm: Option<Vec<u8>>,
    },
    /// Resolution failure carrying a typed `code` (`snake_case`) and a
    /// human-readable `detail`. The bridge folds this into the
    /// matching diagnostic at the `(use-plugin …)` span.
    Failure {
        /// Snake-case diagnostic code (e.g., `"unresolved_plugin"`).
        code: String,
        /// Human-readable failure detail.
        detail: String,
    },
}

impl Serialize for Resolution {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        use serde::ser::SerializeMap;

        match self {
            Resolution::Manifest { source, wasm } => {
                let mut map = serializer.serialize_map(Some(3))?;
                map.serialize_entry("kind", "manifest")?;
                map.serialize_entry("source", source)?;
                // serde_json default: Option<Vec<u8>> -> null | [u8…].
                map.serialize_entry("wasm", wasm)?;
                map.end()
            }
            Resolution::Failure { code, detail } => {
                let mut map = serializer.serialize_map(Some(3))?;
                map.serialize_entry("kind", "failure")?;
                map.serialize_entry("code", code)?;
                map.serialize_entry("detail", detail)?;
                map.end()
            }
        }
    }
}

/// Sync-only resolver. Wasmtime imports return synchronously; an async
/// resolver story (pre-fetch + sync replay) is a v2 deferral.
///
/// # Panics
///
/// `resolve` is invoked from inside a wasmtime callback (`wasm.rs`
/// `host_resolve`). Panics inside the resolver are caught with
/// `std::panic::catch_unwind` and folded into
/// `Resolution::Failure { code: "unresolved_plugin", detail: "<panic
/// message>" }` so document validation always finishes cleanly — the
/// guarantee is "no panic in here ever traps WASM", not "no panic in
/// here ever produces a diagnostic."
///
/// # Examples
///
/// ```
/// use sjon_host::{FnResolver, Reference, Resolution, Resolver, Span};
/// let r = FnResolver(|reference: &Reference| Resolution::Failure {
///     code: "unresolved_plugin".to_string(),
///     detail: format!("no plugin named `{}`", reference.name),
/// });
/// let res = r.resolve(&Reference {
///     name: "shapes".to_string(),
///     explicit_path: None,
///     version: None,
///     hash: None,
///     span: Span::ZERO,
/// });
/// assert!(matches!(res, Resolution::Failure { .. }));
/// ```
pub trait Resolver: Send + Sync {
    /// Resolve a `(use-plugin …)` reference to a manifest or a
    /// failure. See the trait-level docs for panic-safety semantics.
    fn resolve(&self, reference: &Reference) -> Resolution;
}

/// Closure adapter so callers can pass `FnResolver(|r| Resolution::…)`
/// without writing a trait impl. Trait dispatch is the recommended path
/// when state is involved (the filesystem resolver carries an index).
#[derive(Debug)]
pub struct FnResolver<F>(pub F);

impl<F> Resolver for FnResolver<F>
where
    F: Fn(&Reference) -> Resolution + Send + Sync,
{
    fn resolve(&self, reference: &Reference) -> Resolution {
        (self.0)(reference)
    }
}
