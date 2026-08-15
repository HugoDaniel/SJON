//! Mock-resolver coverage. Exercises every `Resolution` variant
//! through the WASM↔Rust callback bridge end-to-end. Mirror of
//! `hosts/web/test/host.test.ts` and
//! `hosts/typescript-parity/test/host.test.ts`.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use sjon_host::{
    FnResolver, HostOptions, Phase, Reference, Resolution, Resolver, Severity, SjonHost,
};

mod common;
use common::{err_codes, wasm_path};

#[test]
fn empty_source_produces_no_diagnostics() {
    let mut host = SjonHost::load(&wasm_path(), None).unwrap();
    let r = host.validate_document("", &HostOptions::default()).unwrap();
    assert!(r.diagnostics.is_empty());
    assert!(r.loaded_plugins.is_empty());
}

#[test]
fn bare_data_with_no_schema_emits_unknown_form() {
    let mut host = SjonHost::load(&wasm_path(), None).unwrap();
    let r = host
        .validate_document("(widget :name w0)\n", &HostOptions::default())
        .unwrap();
    let codes = err_codes(&r.diagnostics);
    assert_eq!(codes, vec!["unknown_form".to_string()]);
    let err = r
        .diagnostics
        .iter()
        .find(|d| d.severity == Severity::Err)
        .unwrap();
    assert_eq!(err.phase, Phase::Validation);
}

#[test]
fn inline_manifest_then_data_validates_cleanly() {
    let mut host = SjonHost::load(&wasm_path(), None).unwrap();
    let src = r#"
(plugin :name probe :version "1.0.0"
  (form :name widget
    (key :name name :type symbol :optional false)))

(widget :name w0)
"#;
    let r = host
        .validate_document(src, &HostOptions::default())
        .unwrap();
    assert!(err_codes(&r.diagnostics).is_empty());
    assert_eq!(r.loaded_plugins.len(), 1);
    assert_eq!(r.loaded_plugins[0].name, "probe");
}

#[test]
fn use_plugin_with_no_resolver_emits_unresolved_plugin() {
    let mut host = SjonHost::load(&wasm_path(), None).unwrap();
    let r = host
        .validate_document("(use-plugin \"missing\")\n", &HostOptions::default())
        .unwrap();
    let codes = err_codes(&r.diagnostics);
    assert_eq!(codes, vec!["unresolved_plugin".to_string()]);
    let err = r
        .diagnostics
        .iter()
        .find(|d| d.severity == Severity::Err)
        .unwrap();
    assert_eq!(err.phase, Phase::Manifest);
    assert!(err.declaration_span.is_some());
}

#[test]
fn manifest_envelope_resolution_loads_and_validates() {
    let resolver: Arc<dyn Resolver> = Arc::new(FnResolver(|r: &Reference| {
        assert_eq!(r.name, "shapes");
        Resolution::Manifest {
            source: r#"(plugin :name shapes :version "1.0.0" (form :name circle (key :name r :type number :optional false)))"#
                .to_string(),
            wasm: None,
        }
    }));
    let mut host = SjonHost::load(&wasm_path(), Some(resolver)).unwrap();
    let r = host
        .validate_document(
            "(use-plugin \"shapes\")\n(circle :r 4)\n",
            &HostOptions::default(),
        )
        .unwrap();
    assert!(err_codes(&r.diagnostics).is_empty());
    assert_eq!(r.loaded_plugins.len(), 1);
}

#[test]
fn declarative_manifest_with_empty_wasm_header_collapses_to_export_missing() {
    // The wasm bytes here are a minimal valid module header (no sections,
    // no exports). Pre-flight (D7-exec) instantiates the plugin, then
    // looks for `sjon_plugin_abi_version` — which isn't there — and
    // collapses the whole load to `plugin_export_missing`. Mirror of the
    // Web host's "declarative manifest with empty wasm header loads
    // cleanly" pre-flight test.
    let resolver: Arc<dyn Resolver> = Arc::new(FnResolver(|_r: &Reference| {
        Resolution::Manifest {
            source: r#"(plugin :name shapes :version "1.0.0" (form :name circle (key :name r :type number :optional false)))"#
                .to_string(),
            wasm: Some(vec![0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]),
        }
    }));
    let mut host = SjonHost::load(&wasm_path(), Some(resolver)).unwrap();
    let r = host
        .validate_document("(use-plugin \"shapes\")\n", &HostOptions::default())
        .unwrap();
    assert_eq!(r.loaded_plugins.len(), 0);
    let codes = err_codes(&r.diagnostics);
    assert_eq!(codes, vec!["plugin_export_missing".to_string()]);
    let err = r
        .diagnostics
        .iter()
        .find(|d| d.severity == Severity::Err)
        .unwrap();
    assert_eq!(err.phase, Phase::Manifest);
}

#[test]
fn failure_resolution_surfaces_code_and_detail() {
    let resolver: Arc<dyn Resolver> = Arc::new(FnResolver(|r: &Reference| Resolution::Failure {
        code: "unresolved_plugin".to_string(),
        detail: format!("no plugin named {} in mock", r.name),
    }));
    let mut host = SjonHost::load(&wasm_path(), Some(resolver)).unwrap();
    let r = host
        .validate_document("(use-plugin \"shapes\")\n", &HostOptions::default())
        .unwrap();
    let errs: Vec<&sjon_host::HostDiagnostic> = r
        .diagnostics
        .iter()
        .filter(|d| d.severity == Severity::Err)
        .collect();
    assert_eq!(errs.len(), 1);
    assert_eq!(errs[0].code, "unresolved_plugin");
    assert!(errs[0].message.contains("no plugin named shapes in mock"));
}

#[test]
fn parse_failed_reference_skips_resolver() {
    let calls = Arc::new(AtomicUsize::new(0));
    let calls_resolver = Arc::clone(&calls);
    let resolver: Arc<dyn Resolver> = Arc::new(FnResolver(move |_r: &Reference| {
        calls_resolver.fetch_add(1, Ordering::SeqCst);
        Resolution::Failure {
            code: "unresolved_plugin".to_string(),
            detail: "unreachable".to_string(),
        }
    }));
    let mut host = SjonHost::load(&wasm_path(), Some(resolver)).unwrap();
    let r = host
        .validate_document("(use-plugin)\n", &HostOptions::default())
        .unwrap();
    assert_eq!(
        calls.load(Ordering::SeqCst),
        0,
        "parse-fail reference must not invoke the resolver"
    );
    let codes = err_codes(&r.diagnostics);
    assert_eq!(codes, vec!["invalid_manifest".to_string()]);
}

#[test]
fn name_mismatch_on_resolved_manifest_emits_plugin_name_mismatch() {
    let resolver: Arc<dyn Resolver> = Arc::new(FnResolver(|_r: &Reference| Resolution::Manifest {
        source: r#"(plugin :name circles :version "1.0.0")"#.to_string(),
        wasm: None,
    }));
    let mut host = SjonHost::load(&wasm_path(), Some(resolver)).unwrap();
    let r = host
        .validate_document(
            "(use-plugin \"shapes\" :path \"./circles.sjon\")\n",
            &HostOptions::default(),
        )
        .unwrap();
    let codes = err_codes(&r.diagnostics);
    assert_eq!(codes, vec!["plugin_name_mismatch".to_string()]);
    assert_eq!(r.loaded_plugins.len(), 0);
}

#[test]
fn mixed_inline_plus_reference_validates_partition() {
    let mut host = SjonHost::load(&wasm_path(), None).unwrap();
    let src = r#"
(plugin :name shapes :version "1.0.0"
  (form :name circle
    (key :name r :type number :optional false)))

(use-plugin "missing")

(circle :r 4)
"#;
    let r = host
        .validate_document(src, &HostOptions::default())
        .unwrap();
    let codes = err_codes(&r.diagnostics);
    assert_eq!(codes, vec!["unresolved_plugin".to_string()]);
    assert_eq!(r.loaded_plugins.len(), 1);
}

#[test]
fn panicking_resolver_folds_into_unresolved_plugin() {
    let resolver: Arc<dyn Resolver> = Arc::new(FnResolver(|_r: &Reference| -> Resolution {
        panic!("kaboom");
    }));
    let mut host = SjonHost::load(&wasm_path(), Some(resolver)).unwrap();
    let r = host
        .validate_document("(use-plugin \"x\")\n", &HostOptions::default())
        .unwrap();
    let errs: Vec<&sjon_host::HostDiagnostic> = r
        .diagnostics
        .iter()
        .filter(|d| d.severity == Severity::Err)
        .collect();
    assert_eq!(errs.len(), 1);
    assert_eq!(errs[0].code, "unresolved_plugin");
    assert!(
        errs[0].message.contains("kaboom"),
        "expected panic message in diagnostic, got: {}",
        errs[0].message
    );
}
