//! `SjonHost::eval_expr` coverage — core arithmetic, plugin-func
//! dispatch through the resolver, unknown-form passthrough, and the
//! single/multiple-expression contract errors.

// float_cmp is allowed because eval returns integer-valued f64s
// (`6.0`, `42.0`) where exact equality is the contract under test.
#![allow(clippy::expect_used, clippy::float_cmp, clippy::unwrap_used)]

use std::path::PathBuf;
use std::sync::Arc;

use sjon_host::{FnResolver, HostOptions, Reference, Resolution, Resolver, SjonHost};

mod common;
use common::{err_codes, wasm_path};

const DOUBLE_MANIFEST: &str = r#"(plugin :name double :version "1.0.0" (expr-func :name double :arity (fixed 1) :params [number] :result number :impl "wasm:double"))"#;

fn read_double_wasm() -> Vec<u8> {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../examples/plugins/double/plugin.wasm");
    std::fs::read(p).expect("read examples/plugins/double/plugin.wasm")
}

#[test]
fn eval_expr_core_arithmetic_returns_number() {
    let mut host = SjonHost::load(&wasm_path(), None).unwrap();
    let r = host
        .eval_expr("(+ 1 2 3)", &HostOptions::default())
        .unwrap();
    assert!(err_codes(&r.diagnostics).is_empty());
    assert_eq!(r.value.as_f64().unwrap(), 6.0);
}

#[test]
fn eval_expr_plugin_func_dispatches_through_resolver() {
    let wasm = read_double_wasm();
    let resolver: Arc<dyn Resolver> =
        Arc::new(FnResolver(move |_r: &Reference| Resolution::Manifest {
            source: DOUBLE_MANIFEST.to_string(),
            wasm: Some(wasm.clone()),
        }));
    let mut host = SjonHost::load(&wasm_path(), Some(resolver)).unwrap();
    let r = host
        .eval_expr(
            "(use-plugin \"double\")\n(double 21)",
            &HostOptions::default(),
        )
        .unwrap();
    assert!(
        err_codes(&r.diagnostics).is_empty(),
        "expected clean eval, got: {:?}",
        r.diagnostics
            .iter()
            .map(|d| (&d.code, &d.message))
            .collect::<Vec<_>>()
    );
    assert_eq!(r.value.as_f64().unwrap(), 42.0);
    assert_eq!(r.loaded_plugins.len(), 1);
    assert_eq!(r.loaded_plugins[0].name, "double");
}

#[test]
fn eval_expr_unknown_form_passes_through_as_value_form() {
    // v2 semantic flip: unknown heads no longer error — they pass
    // through as Value.form (`{$form, children, kvpairs}`). The host
    // surfaces the JSON object on `value` and emits no validation
    // diagnostic.
    let mut host = SjonHost::load(&wasm_path(), None).unwrap();
    let r = host
        .eval_expr("(no-such 1 2)", &HostOptions::default())
        .unwrap();
    assert!(err_codes(&r.diagnostics).is_empty());
    let obj = r
        .value
        .as_object()
        .expect("expected Value.form JSON object");
    assert_eq!(obj.get("$form").and_then(|v| v.as_str()), Some("no-such"));
    let children = obj.get("children").and_then(|v| v.as_array()).unwrap();
    assert_eq!(children.len(), 2);
    assert_eq!(children[0].as_f64(), Some(1.0));
    assert_eq!(children[1].as_f64(), Some(2.0));
}

#[test]
fn eval_expr_no_data_form_returns_err() {
    let mut host = SjonHost::load(&wasm_path(), None).unwrap();
    let err = host
        .eval_expr(
            r#"(plugin :name solo :version "1.0.0" (form :name w :open true))"#,
            &HostOptions::default(),
        )
        .expect_err("expected NoExpression");
    assert!(format!("{err:#}").contains("NoExpression"));
}

#[test]
fn eval_expr_multiple_data_forms_returns_err() {
    let mut host = SjonHost::load(&wasm_path(), None).unwrap();
    let err = host
        .eval_expr("(+ 1 2) (+ 3 4)", &HostOptions::default())
        .expect_err("expected MultipleExpressions");
    assert!(format!("{err:#}").contains("MultipleExpressions"));
}
