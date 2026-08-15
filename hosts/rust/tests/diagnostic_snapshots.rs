//! Pretty-printed `HostResult` snapshots for four conformance cases.
//! Catches silent JSON-shape drift between the Zig-side
//! `wasm_common.writeHostResult` and the Rust-side serde decode —
//! the conformance corpus only asserts on `(code, path, severity)`
//! tuples, so a renamed field or a re-ordered nested struct would
//! pass that suite while breaking downstream consumers.
//!
//! Run `UPDATE_EXPECT=1 cargo test --test diagnostic_snapshots` to
//! regenerate when the ABI legitimately moves.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::path::{Path, PathBuf};
use std::sync::Arc;

use expect_test::{Expect, expect};
use sjon_host::{FilesystemResolver, HostOptions, Resolver, SjonHost};

fn wasm_path() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../zig-out/bin/sjon.wasm");
    p
}

fn case_dir(name: &str) -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../conformance/cases");
    p.push(name);
    p
}

/// Validate `name`'s inline `document.sjon` and assert the pretty-
/// printed `HostResult` JSON against `expected`. The `HostOptions` mirror
/// what `tests/conformance.rs` builds — `project_root` set, optional
/// `sjon-project.sjon` wired through a `FilesystemResolver`.
fn validate_inline_case(name: &str, expected: Expect) {
    let dir = case_dir(name);
    let document_src = std::fs::read_to_string(dir.join("document.sjon"))
        .unwrap_or_else(|err| panic!("read {name}/document.sjon: {err}"));
    let project_file = dir.join("sjon-project.sjon");
    let project_file_opt: Option<&Path> = if project_file.exists() {
        Some(project_file.as_path())
    } else {
        None
    };
    let (resolver, project_diagnostics) = FilesystemResolver::build(&dir, project_file_opt);
    let resolver: Arc<dyn Resolver> = Arc::new(resolver);

    let mut host = SjonHost::load(&wasm_path(), Some(resolver))
        .unwrap_or_else(|err| panic!("load sjon.wasm: {err}"));
    let opts = HostOptions {
        project_root: Some(dir.display().to_string()),
        project_file: project_file_opt.map(|p| p.display().to_string()),
        project_diagnostics,
        ..HostOptions::default()
    };
    let result = host
        .validate_document(&document_src, &opts)
        .unwrap_or_else(|err| panic!("validate {name}: {err}"));
    let pretty = serde_json::to_string_pretty(&result)
        .expect("HostResult serializes back through serde_json");
    // Sanitize the absolute project_root path so snapshots are
    // machine-independent. The Zig-side messages embed it verbatim
    // (e.g. "no project file in `<root>`"); we collapse it to
    // `<CASE>` so the assertion is portable.
    let sanitized = pretty.replace(&dir.display().to_string(), "<CASE>");
    expected.assert_eq(&sanitized);
}

#[test]
fn happy_path_materializes_a_literal_default() {
    validate_inline_case(
        "default-materialize-literal",
        expect![[r#"
            {
              "diagnostics": [],
              "loadedPlugins": [
                {
                  "name": "probe",
                  "version": null,
                  "formCount": 1
                }
              ],
              "materializedDefaults": [
                {
                  "path": [
                    "circle",
                    "radius"
                  ],
                  "key": "radius",
                  "origin": "literal_default",
                  "value": 32
                }
              ],
              "evaluatedResults": []
            }"#]],
    );
}

#[test]
fn validation_phase_diagnostic_missing_required_key() {
    validate_inline_case(
        "inline-manifest-data-error",
        expect![[r#"
            {
              "diagnostics": [
                {
                  "phase": "validation",
                  "code": "missing_required_key",
                  "severity": "err",
                  "message": "form `widget` is missing required keyword `:name`",
                  "span": {
                    "start": 305,
                    "end": 311
                  },
                  "path": [
                    "widget"
                  ],
                  "declarationSpan": null
                }
              ],
              "loadedPlugins": [
                {
                  "name": "probe",
                  "version": null,
                  "formCount": 1
                }
              ],
              "materializedDefaults": [],
              "evaluatedResults": []
            }"#]],
    );
}

#[test]
fn manifest_phase_failure_unresolved_plugin() {
    validate_inline_case(
        "use-plugin-unresolved",
        expect![[r#"
            {
              "diagnostics": [
                {
                  "phase": "manifest",
                  "code": "unresolved_plugin",
                  "severity": "err",
                  "message": "no plugin named `missing` (no project file in `<CASE>`)",
                  "span": {
                    "start": 204,
                    "end": 213
                  },
                  "path": [],
                  "declarationSpan": {
                    "start": 193,
                    "end": 203
                  }
                }
              ],
              "loadedPlugins": [],
              "materializedDefaults": [],
              "evaluatedResults": []
            }"#]],
    );
}

#[test]
fn evaluated_results_for_any_predicate() {
    validate_inline_case(
        "expr-any-positive",
        expect![[r#"
            {
              "diagnostics": [],
              "loadedPlugins": [],
              "materializedDefaults": [],
              "evaluatedResults": [
                {
                  "index": 0,
                  "value": true
                }
              ]
            }"#]],
    );
}
