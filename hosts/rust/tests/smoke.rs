//! Smoke test — proves the whole wasmtime + framed-protocol + JSON-
//! decode loop wires up by validating an empty document. The richer
//! mock-resolver / filesystem / conformance suites land in later commits.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::path::PathBuf;

use sjon_host::{HostOptions, SjonHost};

fn wasm_path() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../zig-out/bin/sjon.wasm");
    p
}

#[test]
fn empty_document_produces_no_diagnostics() {
    let mut host = SjonHost::load(&wasm_path(), None).expect("load sjon.wasm");
    let result = host
        .validate_document("", &HostOptions::default())
        .expect("validate empty doc");
    assert!(
        result.diagnostics.is_empty(),
        "empty document produced diagnostics: {:?}",
        result.diagnostics,
    );
    assert!(result.loaded_plugins.is_empty());
}
