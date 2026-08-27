//! Manifest-metadata smoke tests.
//!
//! The diagnostics here originate in `src/ManifestLoader.zig` and
//! travel out over the JSON envelope from `sjon.wasm`. Mirrors the
//! equivalent suites in `hosts/web/test/host-metadata.test.ts` and
//! `hosts/typescript-parity/test/loader-grammar.test.ts`.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use sjon_host::{HostOptions, Severity, SjonHost};

mod common;
use common::{err_codes, wasm_path};

fn diag_by_code<'a>(
    diags: &'a [sjon_host::HostDiagnostic],
    code: &str,
) -> Option<&'a sjon_host::HostDiagnostic> {
    diags.iter().find(|d| d.code == code)
}

#[test]
fn manifest_fully_decorated_validates_cleanly() {
    let mut host = SjonHost::load(&wasm_path(), None).unwrap();
    let src = r#"
(plugin :name probe :version "1.0.0"
  :authors ["Ada" Babbage]
  :license "CC0-1.0"
  :homepage "https://example.com"
  :repository "https://github.com/x/y"
  :keywords [graphics shapes]
  (form :name widget
    (key :name name :type symbol :optional false)))

(widget :name w0)
"#;
    let r = host
        .validate_document(src, &HostOptions::default())
        .unwrap();
    let errs = err_codes(&r.diagnostics);
    assert!(errs.is_empty(), "unexpected errs: {errs:?}");
    // No advisories either — every field is canonical.
    for code in [
        "license_unrecognized",
        "too_many_keywords",
        "plugin_wasm_self_hash_malformed",
    ] {
        assert!(
            diag_by_code(&r.diagnostics, code).is_none(),
            "unexpected diagnostic {code} on fully-canonical manifest"
        );
    }
}

#[test]
fn manifest_non_spdx_license_emits_license_unrecognized_warning() {
    let mut host = SjonHost::load(&wasm_path(), None).unwrap();
    let r = host
        .validate_document(
            r#"(plugin :name x :version "1.0.0" :license "WTFPL")
"#,
            &HostOptions::default(),
        )
        .unwrap();
    let d = diag_by_code(&r.diagnostics, "license_unrecognized")
        .expect("expected license_unrecognized");
    assert_eq!(d.severity, Severity::Warning);
}

#[test]
fn manifest_too_many_keywords_emits_warning() {
    let mut host = SjonHost::load(&wasm_path(), None).unwrap();
    let r = host
        .validate_document(
            r#"(plugin :name x :version "1.0.0" :keywords [a b c d e f g h i j k l m n o p q r])
"#,
            &HostOptions::default(),
        )
        .unwrap();
    let d = diag_by_code(&r.diagnostics, "too_many_keywords").expect("expected too_many_keywords");
    assert_eq!(d.severity, Severity::Warning);
}

#[test]
fn manifest_malformed_wasm_sha256_emits_self_hash_malformed_err() {
    let mut host = SjonHost::load(&wasm_path(), None).unwrap();
    let r = host
        .validate_document(
            r#"(plugin :name x :version "1.0.0" :wasm-sha256 "not-a-hash")
"#,
            &HostOptions::default(),
        )
        .unwrap();
    let d = diag_by_code(&r.diagnostics, "plugin_wasm_self_hash_malformed")
        .expect("expected plugin_wasm_self_hash_malformed");
    assert_eq!(d.severity, Severity::Err);
}
