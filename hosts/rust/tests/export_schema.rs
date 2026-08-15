//! Smoke tests for `SjonHost::export_schema`. Proves the wasmtime
//! round-trip lands the envelope JSON intact, and that aggregated +
//! per-plugin layouts emit the matching artifact shapes.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::path::PathBuf;

use sjon_host::{ExportLayout, ExportLayoutOption, ExportSchemaOptions, ExportTarget, SjonHost};

fn wasm_path() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../zig-out/bin/sjon.wasm");
    p
}

#[test]
fn aggregated_layout_returns_json_schema_bytes() {
    let source = r#"(plugin :name smoke :version "1.0.0"
  (form :name row
    (key :name n :type number)))"#;
    let mut host = SjonHost::load(&wasm_path(), None).expect("load sjon.wasm");
    let result = host
        .export_schema(
            source,
            &ExportSchemaOptions {
                target: ExportTarget::Both,
                layout: ExportLayoutOption::Aggregated,
                ..Default::default()
            },
        )
        .expect("export_schema");

    assert_eq!(result.layout, ExportLayout::Aggregated);
    assert!(result.per_plugin.is_none());

    let aggregated = result.aggregated.expect("aggregated artifacts present");
    let schema_text = aggregated.json_schema.expect("jsonSchema bytes present");
    let ts_text = aggregated.ts_types.expect("tsTypes bytes present");

    // JSON Schema parses + carries the 2020-12 $schema reference.
    let schema: serde_json::Value =
        serde_json::from_str(&schema_text).expect("jsonSchema is valid JSON");
    let dollar_schema = schema
        .get("$schema")
        .and_then(|v| v.as_str())
        .expect("$schema field present");
    assert!(
        dollar_schema.contains("2020-12"),
        "expected 2020-12 $schema, got {dollar_schema}",
    );

    // The smoke plugin's `row` form lands in `$defs`.
    let defs = schema.get("$defs").expect("$defs present");
    assert!(
        defs.get("form.smoke.row").is_some(),
        "expected $defs/form.smoke.row entry; got keys {:?}",
        defs.as_object().map(|o| o.keys().collect::<Vec<_>>()),
    );

    // TS surface mentions the form name.
    assert!(
        ts_text.contains("Row"),
        "TS bytes should mention `Row` interface; got:\n{ts_text}",
    );
}

#[test]
fn per_plugin_layout_returns_one_artifact_per_plugin() {
    let source = r#"(plugin :name a :version "1.0.0"
  (form :name r (key :name n :type number)))
(plugin :name b :version "1.0.0"
  (form :name s (key :name m :type number)))"#;
    let mut host = SjonHost::load(&wasm_path(), None).expect("load sjon.wasm");
    let result = host
        .export_schema(
            source,
            &ExportSchemaOptions {
                target: ExportTarget::JsonSchema,
                layout: ExportLayoutOption::PerPlugin,
                ..Default::default()
            },
        )
        .expect("export_schema");

    assert_eq!(result.layout, ExportLayout::PerPlugin);
    assert!(result.aggregated.is_none());

    let per_plugin = result.per_plugin.expect("perPlugin artifacts present");
    assert_eq!(per_plugin.len(), 2);

    let plugin_names: Vec<&str> = per_plugin.iter().map(|a| a.plugin.as_str()).collect();
    assert!(plugin_names.contains(&"a"));
    assert!(plugin_names.contains(&"b"));

    for art in &per_plugin {
        let schema_text = art
            .json_schema
            .as_ref()
            .unwrap_or_else(|| panic!("plugin {} missing jsonSchema bytes", art.plugin));
        let schema: serde_json::Value =
            serde_json::from_str(schema_text).expect("jsonSchema parses as JSON");
        assert!(
            schema.get("$defs").is_some(),
            "missing $defs in {}",
            art.plugin
        );
    }
}

#[test]
fn intermediate_target_returns_ir_only() {
    let source = r#"(plugin :name smoke :version "1.0.0"
  (form :name row
    (key :name n :type number)))"#;
    let mut host = SjonHost::load(&wasm_path(), None).expect("load sjon.wasm");
    let result = host
        .export_schema(
            source,
            &ExportSchemaOptions {
                target: ExportTarget::Intermediate,
                layout: ExportLayoutOption::Aggregated,
                ..Default::default()
            },
        )
        .expect("export_schema");

    let aggregated = result.aggregated.expect("aggregated artifacts present");
    assert!(aggregated.json_schema.is_none());
    assert!(aggregated.ts_types.is_none());
    let ir_text = aggregated
        .intermediate
        .expect("intermediate IR bytes present");
    let ir: serde_json::Value =
        serde_json::from_str(&ir_text).expect("intermediate IR is valid JSON");
    assert_eq!(
        ir.get("version").and_then(serde_json::Value::as_u64),
        Some(1),
        "IR should carry version: 1",
    );
}
