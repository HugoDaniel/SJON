//! D7-exec — executable-plugin ABI dispatch (Phase D).
//!
//! Mirrors `hosts/web/test/host.test.ts` D7-exec section. The fixtures
//! come from `examples/plugins/double/plugin.wasm` (built by
//! `zig build plugin-fixtures`): exports `double`, `trap`, `fail`, each
//! demonstrating one execution outcome.
//!
//! Also covers the post-D7 host-result merging surface
//! (`project_diagnostics`, `materialized_defaults`) that exercises the
//! same WASM<->Rust bridge.

// float_cmp is allowed because eval returns integer-valued f64s
// (`32.0`, `6.0`) where exact equality is the contract under test.
#![allow(clippy::expect_used, clippy::float_cmp, clippy::unwrap_used)]

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use sjon_host::{
    DefaultOrigin, FailurePolicy, FnResolver, HostOptions, Phase, Reference, Resolution, Resolver,
    Severity, SjonHost,
};

mod common;
use common::wasm_builder::{build_import_forbidden_wasm, build_stub_plugin_wasm};
use common::{err_codes, wasm_path};

const DOUBLE_MANIFEST: &str = r#"(plugin :name double :version "1.0.0" (expr-func :name double :arity (fixed 1) :params [number] :result number :impl "wasm:double"))"#;

fn double_wasm_path() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../examples/plugins/double/plugin.wasm");
    p
}

fn read_double_wasm() -> Vec<u8> {
    std::fs::read(double_wasm_path()).expect("read examples/plugins/double/plugin.wasm")
}

#[test]
fn d7_exec_happy_path_double_validates_with_zero_diagnostics() {
    let wasm = read_double_wasm();
    let resolver: Arc<dyn Resolver> =
        Arc::new(FnResolver(move |_r: &Reference| Resolution::Manifest {
            source: DOUBLE_MANIFEST.to_string(),
            wasm: Some(wasm.clone()),
        }));
    let mut host = SjonHost::load(&wasm_path(), Some(resolver)).unwrap();
    let r = host
        .validate_document(
            "(use-plugin \"double\")\n(double 21)\n",
            &HostOptions::default(),
        )
        .unwrap();
    assert!(
        err_codes(&r.diagnostics).is_empty(),
        "expected clean validation, got: {:?}",
        r.diagnostics
            .iter()
            .map(|d| (&d.code, &d.message))
            .collect::<Vec<_>>()
    );
    assert_eq!(r.loaded_plugins.len(), 1);
    assert_eq!(r.loaded_plugins[0].name, "double");
}

#[test]
fn d7_exec_plugin_name_after_leading_expr_func_pools_under_plugin_name() {
    // Regression (A.2): the retired byte-walker anchored on the FIRST
    // :name in source order and pooled this plugin under the nested
    // expr-func's `twice`, not the plugin's own `realpkg`. Zig's invoke
    // request keys on the real name, so dispatch missed the pool and the
    // `(twice 21)` call failed. The structural `sjon_manifest_meta` reads
    // `realpkg`.
    let wasm = read_double_wasm();
    let manifest = r#"(plugin (expr-func :name twice :arity (fixed 1) :params [number] :result number :impl "wasm:double") :name realpkg :version "1.0.0")"#;
    let resolver: Arc<dyn Resolver> =
        Arc::new(FnResolver(move |_r: &Reference| Resolution::Manifest {
            source: manifest.to_string(),
            wasm: Some(wasm.clone()),
        }));
    let mut host = SjonHost::load(&wasm_path(), Some(resolver)).unwrap();
    let r = host
        .validate_document(
            "(use-plugin \"realpkg\")\n(twice 21)\n",
            &HostOptions::default(),
        )
        .unwrap();
    assert!(
        err_codes(&r.diagnostics).is_empty(),
        "expected clean validation, got: {:?}",
        r.diagnostics
            .iter()
            .map(|d| (&d.code, &d.message))
            .collect::<Vec<_>>()
    );
    assert_eq!(r.loaded_plugins.len(), 1);
    assert_eq!(r.loaded_plugins[0].name, "realpkg");
}

#[test]
fn d7_exec_abi_mismatch_synthetic_abi_63_surfaces_plugin_abi_mismatch() {
    let wasm = build_stub_plugin_wasm(63);
    let resolver: Arc<dyn Resolver> = Arc::new(FnResolver(move |_r: &Reference| {
        Resolution::Manifest {
            source: r#"(plugin :name shapes :version "1.0.0" (form :name circle (key :name r :type number :optional false)))"#
                .to_string(),
            wasm: Some(wasm.clone()),
        }
    }));
    let mut host = SjonHost::load(&wasm_path(), Some(resolver)).unwrap();
    let r = host
        .validate_document("(use-plugin \"shapes\")\n", &HostOptions::default())
        .unwrap();
    let codes = err_codes(&r.diagnostics);
    assert_eq!(codes, vec!["plugin_abi_mismatch".to_string()]);
    let err = r
        .diagnostics
        .iter()
        .find(|d| d.severity == Severity::Err)
        .unwrap();
    assert_eq!(err.phase, Phase::Manifest);
    assert!(
        err.message.contains("ABI version 63"),
        "expected message to cite ABI version, got: {}",
        err.message
    );
    assert_eq!(r.loaded_plugins.len(), 0);
}

#[test]
fn d7_exec_manifest_declares_missing_export_surfaces_plugin_export_missing() {
    let wasm = read_double_wasm();
    let manifest = r#"(plugin :name double :version "1.0.0" (expr-func :name halve :arity (fixed 1) :params [number] :result number :impl "wasm:halve"))"#;
    let resolver: Arc<dyn Resolver> =
        Arc::new(FnResolver(move |_r: &Reference| Resolution::Manifest {
            source: manifest.to_string(),
            wasm: Some(wasm.clone()),
        }));
    let mut host = SjonHost::load(&wasm_path(), Some(resolver)).unwrap();
    let r = host
        .validate_document("(use-plugin \"double\")\n", &HostOptions::default())
        .unwrap();
    let codes = err_codes(&r.diagnostics);
    assert_eq!(codes, vec!["plugin_export_missing".to_string()]);
    let err = r
        .diagnostics
        .iter()
        .find(|d| d.severity == Severity::Err)
        .unwrap();
    assert_eq!(err.phase, Phase::Manifest);
    assert!(
        err.message.contains("halve"),
        "expected message to cite missing export, got: {}",
        err.message
    );
    assert_eq!(r.loaded_plugins.len(), 0);
}

#[test]
fn d7_exec_forbidden_env_import_surfaces_plugin_import_forbidden() {
    let wasm = build_import_forbidden_wasm();
    let resolver: Arc<dyn Resolver> = Arc::new(FnResolver(move |_r: &Reference| {
        Resolution::Manifest {
            source: r#"(plugin :name shapes :version "1.0.0" (form :name circle (key :name r :type number :optional false)))"#
                .to_string(),
            wasm: Some(wasm.clone()),
        }
    }));
    let mut host = SjonHost::load(&wasm_path(), Some(resolver)).unwrap();
    let r = host
        .validate_document("(use-plugin \"shapes\")\n", &HostOptions::default())
        .unwrap();
    let codes = err_codes(&r.diagnostics);
    assert_eq!(codes, vec!["plugin_import_forbidden".to_string()]);
    let err = r
        .diagnostics
        .iter()
        .find(|d| d.severity == Severity::Err)
        .unwrap();
    assert_eq!(err.phase, Phase::Manifest);
    assert!(
        err.message.contains("env.host_helper"),
        "expected message to cite forbidden import, got: {}",
        err.message
    );
}

#[test]
fn d7_exec_plugin_traps_surfaces_plugin_func_trapped_at_call_span() {
    let wasm = read_double_wasm();
    let manifest = r#"(plugin :name double :version "1.0.0" (expr-func :name boom :arity (fixed 1) :params [number] :result number :impl "wasm:trap"))"#;
    let resolver: Arc<dyn Resolver> =
        Arc::new(FnResolver(move |_r: &Reference| Resolution::Manifest {
            source: manifest.to_string(),
            wasm: Some(wasm.clone()),
        }));
    let mut host = SjonHost::load(&wasm_path(), Some(resolver)).unwrap();
    let r = host
        .validate_document(
            "(use-plugin \"double\")\n(boom 1)\n",
            &HostOptions::default(),
        )
        .unwrap();
    let codes = err_codes(&r.diagnostics);
    assert_eq!(codes, vec!["plugin_func_trapped".to_string()]);
    let err = r
        .diagnostics
        .iter()
        .find(|d| d.severity == Severity::Err)
        .unwrap();
    assert_eq!(err.phase, Phase::Validation);
}

#[test]
fn d7_exec_plugin_returns_ok_zero_surfaces_plugin_func_failed_with_detail() {
    let wasm = read_double_wasm();
    let manifest = r#"(plugin :name double :version "1.0.0" (expr-func :name kaboom :arity (fixed 1) :params [number] :result number :impl "wasm:fail"))"#;
    let resolver: Arc<dyn Resolver> =
        Arc::new(FnResolver(move |_r: &Reference| Resolution::Manifest {
            source: manifest.to_string(),
            wasm: Some(wasm.clone()),
        }));
    let mut host = SjonHost::load(&wasm_path(), Some(resolver)).unwrap();
    let r = host
        .validate_document(
            "(use-plugin \"double\")\n(kaboom 1)\n",
            &HostOptions::default(),
        )
        .unwrap();
    let codes = err_codes(&r.diagnostics);
    assert_eq!(codes, vec!["plugin_func_failed".to_string()]);
    let err = r
        .diagnostics
        .iter()
        .find(|d| d.severity == Severity::Err)
        .unwrap();
    assert_eq!(err.phase, Phase::Validation);
    assert!(
        err.message.contains("domain"),
        "expected message to cite plugin-reported code, got: {}",
        err.message
    );
    assert!(
        err.message.contains("plugin reported a structured failure"),
        "expected message to cite plugin-reported detail, got: {}",
        err.message
    );
}

#[test]
fn d7_exec_plugin_reports_oversized_frame_surfaces_alloc_failed() {
    // The fixture's `huge` export returns a frame header claiming a
    // ~4 GiB payload that doesn't exist. Without a host cap on the
    // reported length the dispatch bridge would try to allocate a
    // matching mirror buffer; the cap rejects it as
    // `plugin_func_alloc_failed` with the size + cap in the detail.
    let wasm = read_double_wasm();
    let manifest = r#"(plugin :name double :version "1.0.0" (expr-func :name big :arity (fixed 1) :params [number] :result number :impl "wasm:huge"))"#;
    let resolver: Arc<dyn Resolver> =
        Arc::new(FnResolver(move |_r: &Reference| Resolution::Manifest {
            source: manifest.to_string(),
            wasm: Some(wasm.clone()),
        }));
    let mut host = SjonHost::load(&wasm_path(), Some(resolver)).unwrap();
    let r = host
        .validate_document(
            "(use-plugin \"double\")\n(big 1)\n",
            &HostOptions::default(),
        )
        .unwrap();
    let codes = err_codes(&r.diagnostics);
    assert_eq!(codes, vec!["plugin_func_alloc_failed".to_string()]);
    let err = r
        .diagnostics
        .iter()
        .find(|d| d.severity == Severity::Err)
        .unwrap();
    assert_eq!(err.phase, Phase::Validation);
    assert!(
        err.message.contains("4294967295 bytes"),
        "expected message to cite reported size, got: {}",
        err.message
    );
    assert!(
        err.message.contains("host caps plugin frames at"),
        "expected message to cite host cap, got: {}",
        err.message
    );
}

#[test]
fn d7_exec_duplicate_plugin_name_first_wins_pool() {
    // Two `(use-plugin)` references resolve to manifests with the same
    // `:name double`. The first carries the real `double.wasm` (defines
    // `double`); the second carries a no-`double` stub. Zig dedupes the
    // second manifest with `duplicate_plugin_name` and drops it from the
    // schema — so eval looks up `double` against the FIRST plugin's
    // expr-func definition, then dispatches via `sjon_host_invoke_plugin`
    // with `plugin_name="double", export_name="double"`. With first-wins,
    // pool["double"] is still the real wasm and dispatch returns 42.
    // Without it, pool["double"] would be the stub (no `double` export)
    // and eval would surface `plugin_func_alloc_failed`.
    let real_wasm = read_double_wasm();
    let stub_wasm = build_stub_plugin_wasm(2);
    let call = Arc::new(AtomicUsize::new(0));
    let call_resolver = Arc::clone(&call);
    let resolver: Arc<dyn Resolver> = Arc::new(FnResolver(move |_r: &Reference| {
        let n = call_resolver.fetch_add(1, Ordering::SeqCst);
        if n == 0 {
            Resolution::Manifest {
                source: DOUBLE_MANIFEST.to_string(),
                wasm: Some(real_wasm.clone()),
            }
        } else {
            Resolution::Manifest {
                source: r#"(plugin :name double :version "2.0.0")"#.to_string(),
                wasm: Some(stub_wasm.clone()),
            }
        }
    }));
    let mut host = SjonHost::load(&wasm_path(), Some(resolver)).unwrap();
    let r = host
        .validate_document(
            "(use-plugin \"double\")\n(use-plugin \"double\" :path \"./other.sjon\")\n(double 21)\n",
            &HostOptions::default(),
        )
        .unwrap();
    let codes = err_codes(&r.diagnostics);
    assert_eq!(codes, vec!["duplicate_plugin_name".to_string()]);
    assert_eq!(r.loaded_plugins.len(), 1);
}

#[test]
fn project_diagnostics_are_prepended() {
    let mut host = SjonHost::load(&wasm_path(), None).unwrap();
    let synthetic = sjon_host::HostDiagnostic {
        phase: Phase::Manifest,
        code: "duplicate_plugin_name".to_string(),
        severity: Severity::Err,
        message: "synthetic duplicate (testing)".to_string(),
        span: sjon_host::Span::ZERO,
        path: vec!["project".to_string()],
        declaration_span: None,
    };
    let opts = HostOptions {
        project_diagnostics: vec![synthetic],
        ..HostOptions::default()
    };
    let r = host.validate_document("(widget)\n", &opts).unwrap();
    let codes = err_codes(&r.diagnostics);
    assert_eq!(
        codes,
        vec![
            "duplicate_plugin_name".to_string(),
            "unknown_form".to_string()
        ]
    );
    assert_eq!(r.diagnostics[0].message, "synthetic duplicate (testing)");
}

// The failure preference is forwarded to WASM but never gates emission (see
// `src/Host.zig` §"does NOT change what's emitted"); the CLI reads it for an
// exit code. Strict and lenient must therefore produce identical streams — the
// same contract pinned in the web + typescript-parity hosts.
#[test]
fn failure_policy_has_no_diagnostic_effect() {
    let mut host = SjonHost::load(&wasm_path(), None).unwrap();
    let strict = host
        .validate_document(
            "(widget :name w0)\n",
            &HostOptions {
                failure_policy: FailurePolicy::Strict,
                ..HostOptions::default()
            },
        )
        .unwrap();
    let lenient = host
        .validate_document(
            "(widget :name w0)\n",
            &HostOptions {
                failure_policy: FailurePolicy::Lenient,
                ..HostOptions::default()
            },
        )
        .unwrap();
    assert_eq!(
        err_codes(&strict.diagnostics),
        err_codes(&lenient.diagnostics)
    );
    assert_eq!(
        err_codes(&strict.diagnostics),
        vec!["unknown_form".to_string()]
    );
}

// Slice 7: `HostResult.materialized_defaults` mirrors the
// `MaterializedDefaults` side-table for omitted defaulted keys on
// known data forms. Shape per `wasm_common.writeHostResult`:
//   { path, key, origin, value } where path = [form-head, key-name].

#[test]
fn literal_default_surfaces_on_materialized_defaults() {
    let mut host = SjonHost::load(&wasm_path(), None).unwrap();
    let src = r#"
(plugin :name probe :version "1.0.0"
  (form :name circle
    (key :name radius :type number :default 32)))

(circle)
"#;
    let r = host
        .validate_document(src, &HostOptions::default())
        .unwrap();
    assert!(err_codes(&r.diagnostics).is_empty());
    assert_eq!(r.materialized_defaults.len(), 1);
    let entry = &r.materialized_defaults[0];
    assert_eq!(entry.path, vec!["circle".to_string(), "radius".to_string()]);
    assert_eq!(entry.key, "radius");
    assert_eq!(entry.origin, DefaultOrigin::LiteralDefault);
    assert_eq!(entry.value.as_f64().unwrap(), 32.0);
}

#[test]
fn expression_default_reports_expression_origin() {
    let mut host = SjonHost::load(&wasm_path(), None).unwrap();
    // `(if true 32 0)` evaluates without needing `core` loaded — `if`
    // is dispatched by the evaluator before any schema lookup.
    let src = r#"
(plugin :name probe :version "1.0.0"
  (form :name circle
    (key :name radius :type number :default (if true 32 0))))

(circle)
"#;
    let r = host
        .validate_document(src, &HostOptions::default())
        .unwrap();
    assert!(err_codes(&r.diagnostics).is_empty());
    assert_eq!(r.materialized_defaults.len(), 1);
    let entry = &r.materialized_defaults[0];
    assert_eq!(entry.origin, DefaultOrigin::ExpressionDefault);
    assert_eq!(entry.value.as_f64().unwrap(), 32.0);
}

#[test]
fn explicit_author_kvpair_suppresses_overlay_entry() {
    let mut host = SjonHost::load(&wasm_path(), None).unwrap();
    let src = r#"
(plugin :name probe :version "1.0.0"
  (form :name circle
    (key :name radius :type number :default 32)))

(circle :radius 7)
"#;
    let r = host
        .validate_document(src, &HostOptions::default())
        .unwrap();
    assert!(err_codes(&r.diagnostics).is_empty());
    assert!(r.materialized_defaults.is_empty());
}

#[test]
fn failed_expression_default_yields_no_overlay_entry() {
    let mut host = SjonHost::load(&wasm_path(), None).unwrap();
    // `(nope)` declares `:result number` so aggregate validation passes,
    // but has no `:impl` — runtime evaluation fails with
    // default_eval_failed and contributes no overlay entry.
    let src = r#"
(plugin :name probe :version "1.0.0"
  (expr-func :name nope :arity (fixed 0) :result number)
  (form :name circle
    (key :name radius :type number :default (nope))))

(circle)
"#;
    let r = host
        .validate_document(src, &HostOptions::default())
        .unwrap();
    let codes = err_codes(&r.diagnostics);
    assert!(
        codes.iter().any(|c| c == "default_eval_failed"),
        "expected default_eval_failed in {codes:?}"
    );
    assert!(r.materialized_defaults.is_empty());
}

#[test]
fn project_diagnostics_merge_preserves_materialized_defaults() {
    let mut host = SjonHost::load(&wasm_path(), None).unwrap();
    let synthetic = sjon_host::HostDiagnostic {
        phase: Phase::Manifest,
        code: "duplicate_plugin_name".to_string(),
        severity: Severity::Err,
        message: "synthetic (testing)".to_string(),
        span: sjon_host::Span::ZERO,
        path: vec!["project".to_string()],
        declaration_span: None,
    };
    let src = r#"
(plugin :name probe :version "1.0.0"
  (form :name circle
    (key :name radius :type number :default 32)))

(circle)
"#;
    let opts = HostOptions {
        project_diagnostics: vec![synthetic],
        ..HostOptions::default()
    };
    let r = host.validate_document(src, &opts).unwrap();
    assert_eq!(r.diagnostics[0].code, "duplicate_plugin_name");
    assert_eq!(r.materialized_defaults.len(), 1);
    assert_eq!(r.materialized_defaults[0].value.as_f64().unwrap(), 32.0);
}
