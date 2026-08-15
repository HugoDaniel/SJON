//! Focused tests for the `wasm.rs` ↔ resolver bridge. The conformance
//! corpus exercises these paths in passing (through `use-plugin-…`
//! cases) but this file pins the invariants explicitly so a regression
//! in `host_resolve` shows up here, against a deterministic single-
//! input scenario, rather than as a mysterious case mismatch.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::sync::Arc;

use sjon_host::{FnResolver, HostOptions, Reference, Resolution, Resolver, Severity, SjonHost};

fn wasm_path() -> std::path::PathBuf {
    let mut p = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../zig-out/bin/sjon.wasm");
    p
}

/// Build a minimal valid WASM module — just the magic + version
/// header, zero sections, zero exports. The bridge's pre-flight in
/// `wasm.rs::preflight_and_register` compiles the module, then asks
/// for `sjon_plugin_abi_version` as a typed func and finds it
/// missing — which is `plugin_export_missing`, not
/// `plugin_abi_mismatch`. We pin which one fires because the two
/// codes have different downstream UX (mismatch = "rebuild against
/// the right host"; missing = "your plugin is wrong shape").
fn minimal_wasm_header() -> Vec<u8> {
    // `\0asm` magic + version `1` (LE u32).
    vec![0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
}

/// Pre-flight on a header-only WASM module routes through
/// `plugin_export_missing` (no `sjon_plugin_abi_version` symbol). The
/// detail mentions the missing symbol by name so callers don't have
/// to grep the spec to figure out which export the host expected.
#[test]
fn header_only_plugin_collapses_to_plugin_export_missing() {
    let wasm = minimal_wasm_header();
    let resolver: Arc<dyn Resolver> = Arc::new(FnResolver(move |_r: &Reference| {
        Resolution::Manifest {
            source: r#"(plugin :name shapes :version "1.0.0" (form :name circle (key :name r :type number)))"#
                .to_string(),
            wasm: Some(wasm.clone()),
        }
    }));
    let mut host = SjonHost::load(&wasm_path(), Some(resolver)).unwrap();
    let r = host
        .validate_document(r#"(use-plugin "shapes")"#, &HostOptions::default())
        .unwrap();
    let codes: Vec<&str> = r
        .diagnostics
        .iter()
        .filter(|d| d.severity == Severity::Err)
        .map(|d| d.code.as_str())
        .collect();
    assert_eq!(codes, vec!["plugin_export_missing"]);
    let detail = &r.diagnostics[0].message;
    assert!(
        detail.contains("sjon_plugin_abi_version"),
        "expected the missing-symbol name in detail; got: {detail}"
    );
}

/// `Resolution::Failure` returned by the resolver round-trips through
/// the JSON-encode + Zig-decode bridge unchanged: the `code` ends up
/// on the diagnostic, the `detail` ends up in the message. Pins the
/// `wasm_host_resolver.zig` ↔ `Serialize for Resolution` wire format.
#[test]
fn resolution_failure_round_trips_code_and_detail() {
    let resolver: Arc<dyn Resolver> = Arc::new(FnResolver(|_r: &Reference| Resolution::Failure {
        code: "unresolved_plugin".to_string(),
        detail: "test detail with `backticks` and \"quotes\"".to_string(),
    }));
    let mut host = SjonHost::load(&wasm_path(), Some(resolver)).unwrap();
    let r = host
        .validate_document(r#"(use-plugin "x")"#, &HostOptions::default())
        .unwrap();
    let errs: Vec<&sjon_host::HostDiagnostic> = r
        .diagnostics
        .iter()
        .filter(|d| d.severity == Severity::Err)
        .collect();
    assert_eq!(errs.len(), 1);
    assert_eq!(errs[0].code, "unresolved_plugin");
    assert!(
        errs[0].message.contains("test detail with"),
        "expected resolver detail in message, got: {}",
        errs[0].message
    );
    assert!(
        errs[0].message.contains("backticks"),
        "expected backtick passthrough, got: {}",
        errs[0].message
    );
}

/// Panic inside the resolver becomes a `Resolution::Failure { code:
/// "unresolved_plugin", detail: <panic_message> }` via
/// `std::panic::catch_unwind(AssertUnwindSafe(…))`. The diagnostic
/// surfaces at the `(use-plugin …)` span on `phase: manifest` and
/// validation completes (no trap).
///
/// Complements `tests/host.rs::panicking_resolver_folds_into_unresolved_plugin`
/// — that one asserts on the panic message; this one asserts that
/// validation continues after the panic by checking that any
/// subsequent data form in the document still triggers its own
/// diagnostic (which would not happen if the panic had aborted the
/// pipeline).
#[test]
fn panic_in_resolver_does_not_abort_subsequent_validation() {
    let resolver: Arc<dyn Resolver> = Arc::new(FnResolver(|_r: &Reference| -> Resolution {
        panic!("resolver gave up");
    }));
    let mut host = SjonHost::load(&wasm_path(), Some(resolver)).unwrap();
    // Two things in the document: a `(use-plugin …)` whose resolver
    // panics, plus a bare `(widget …)` that has no schema. The bridge
    // must catch the panic and let Zig keep going so the *second*
    // form's `unknown_form` diagnostic also appears.
    let src = r#"(use-plugin "x")
(widget :name w0)
"#;
    let r = host
        .validate_document(src, &HostOptions::default())
        .unwrap();
    let codes: Vec<&str> = r
        .diagnostics
        .iter()
        .filter(|d| d.severity == Severity::Err)
        .map(|d| d.code.as_str())
        .collect();
    // Order matters: resolver-bridge failure first, then the data-
    // form failure. Both must be present.
    assert!(
        codes.contains(&"unresolved_plugin"),
        "expected unresolved_plugin from the panic; got: {codes:?}"
    );
    assert!(
        codes.contains(&"unknown_form"),
        "expected unknown_form from the subsequent widget; got: {codes:?}"
    );
}
