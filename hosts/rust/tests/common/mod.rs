//! Shared helpers for integration tests. Cargo gives every file under
//! `tests/` its own crate, so common code lives here and gets included
//! via `mod common;` from each runner.

// Each test binary only imports the helpers it actually needs; the
// others trip `dead_code` / `unreachable_pub` because their crate
// doesn't reach them. Suppress at the module boundary so the warning
// reflects real drift rather than test-binary granularity.
#![allow(dead_code, unreachable_pub)]

pub mod wasm_builder;

use std::path::{Path, PathBuf};

use sjon_host::__fuzz_only::{Node, find_form_by_head, parse_top_level_forms};
use sjon_host::{HostDiagnostic, Severity};

/// Path to the `sjon.wasm` artifact under `zig-out/bin/`. All
/// integration tests build against the same artifact.
pub fn wasm_path() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../zig-out/bin/sjon.wasm");
    p
}

/// Extract just the `snake_case` codes of every `Severity::Err` diagnostic.
/// The standard summary the assertion shape every test reaches for.
pub fn err_codes(diagnostics: &[HostDiagnostic]) -> Vec<String> {
    diagnostics
        .iter()
        .filter(|d| d.severity == Severity::Err)
        .map(|d| d.code.clone())
        .collect()
}

#[derive(Debug, Clone)]
pub struct ExpectedDiagnostic {
    pub code: String,
    pub path: Vec<String>,
    /// Defaults to `Severity::Err` so existing fixtures need no change.
    /// Set to `Severity::Warning` via `:severity warning` to assert
    /// against a warning-severity diagnostic such as `deprecated_member`.
    pub severity: Severity,
}

/// Parse `expected.sjon` into `[(code, path, severity)]`. Mirrors the
/// readers in `hosts/typescript-parity/test/conformance.test.ts` and
/// `src/conformance_tests.zig`. Path entries can be symbols, decimal-
/// stringified numbers, or strings — symbols and numbers reach us as
/// `Node::Symbol` (the subset parser doesn't tag numbers separately;
/// the textual form already matches the validator's `indexStep` output).
///
/// Tolerates an optional `(values …)` sibling alongside the required
/// `(diagnostics …)` form — `(values …)` is consumed by a separate
/// reader once the host's wasm framing surfaces evaluated values.
///
/// Everything *inside* `(diagnostics …)` is rejected loudly instead:
/// unknown keys, an unknown `:severity`, a wrongly-shaped `:code`, a
/// path element that is neither symbol nor string, a missing `:code`.
/// This reader used to map an unknown `:severity` to `Err` and an
/// unrecognized path element to `""`, which meant a typo in a fixture
/// weakened the assertion rather than failing it — `:severity warnign`
/// silently asserted `err`. Fixture vocabulary is small and fixed;
/// anything outside it is a mistake in the fixture, and test code is
/// exactly where that should be loud.
pub fn read_expected(source: &str) -> Result<Vec<ExpectedDiagnostic>, String> {
    let forms = parse_top_level_forms(source)?;
    let root = find_form_by_head(&forms, "diagnostics")
        .ok_or_else(|| "expected.sjon must contain a (diagnostics …) form".to_string())?;
    let Node::Form { children, .. } = root else {
        unreachable!("find_form_by_head returns Node::Form");
    };
    let mut out: Vec<ExpectedDiagnostic> = Vec::new();
    for child in children {
        let Node::Form {
            head: ch_head,
            children: ch_children,
        } = child
        else {
            return Err(format!("(diagnostics …) child is not a form: {child:?}"));
        };
        if ch_head != "diagnostic" {
            return Err(format!(
                "unknown form `({ch_head} …)` inside (diagnostics …)"
            ));
        }
        let mut code: Option<String> = None;
        let mut path: Vec<String> = Vec::new();
        let mut severity = Severity::Err;
        for kv in ch_children {
            let Node::Kvpair { key, value } = kv else {
                return Err(format!("(diagnostic …) child is not a kvpair: {kv:?}"));
            };
            match (key.as_str(), value.as_ref()) {
                ("code", Node::Symbol(s)) => code = Some(s.clone()),
                ("severity", Node::Symbol(s)) => {
                    severity = match s.as_str() {
                        "err" => Severity::Err,
                        "warning" => Severity::Warning,
                        other => return Err(format!("unknown :severity `{other}`")),
                    };
                }
                ("path", Node::Vector { elements }) => {
                    path = elements
                        .iter()
                        .map(|e| match e {
                            Node::Symbol(s) | Node::String(s) => Ok(s.clone()),
                            other => Err(format!(
                                "(:path …) element is not a symbol or string: {other:?}"
                            )),
                        })
                        .collect::<Result<Vec<String>, String>>()?;
                }
                ("code" | "severity" | "path", other) => {
                    return Err(format!("`:{key}` has the wrong shape: {other:?}"));
                }
                _ => return Err(format!("unknown key `:{key}` in (diagnostic …)")),
            }
        }
        out.push(ExpectedDiagnostic {
            code: code.ok_or_else(|| "(diagnostic …) is missing :code".to_string())?,
            path,
            severity,
        });
    }
    Ok(out)
}

pub fn format_diags(diags: &[&HostDiagnostic]) -> String {
    let parts: Vec<String> = diags
        .iter()
        .map(|d| format!("{}@[{}]: {}", d.code, d.path.join(" "), d.message))
        .collect();
    format!("[{}]", parts.join("; "))
}

/// Load a case's generated `expected.values.json` sibling as an
/// index→value map, or an empty map when the case has none (most cases).
/// The sibling is derived at build time from the fixture's `(values …)`
/// block through the same `wasm_common.appendValue` the WASM envelope uses
/// and drift-gated by `zig build gen-expected-values`, so this host reads
/// it verbatim through `serde_json` and compares each entry with `==`
/// against `evaluated_results[i].value` (also `serde_json`). Byte-identical
/// encoder output on both sides makes the plain `PartialEq` exact — no
/// custom numeric/date/time normalizer is needed.
pub fn read_values_json(case_dir: &Path) -> serde_json::Map<String, serde_json::Value> {
    let sibling = case_dir.join("expected.values.json");
    if !sibling.exists() {
        return serde_json::Map::new();
    }
    let text = std::fs::read_to_string(&sibling)
        .unwrap_or_else(|err| panic!("read {}: {err}", sibling.display()));
    match serde_json::from_str(&text) {
        Ok(serde_json::Value::Object(map)) => map,
        Ok(_) => panic!("{}: expected a top-level JSON object", sibling.display()),
        Err(err) => panic!("{}: invalid JSON: {err}", sibling.display()),
    }
}
