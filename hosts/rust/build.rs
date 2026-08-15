//! Generates one `#[test] fn` per conformance fixture under
//! `conformance/cases/`. Mirrors the discovery-time `for` loops in
//! `hosts/web/test/conformance.test.ts` and
//! `hosts/typescript-parity/test/conformance.test.ts`, so the Rust
//! host gets the same per-fixture visibility (named test, `cargo
//! test` filtering, parallel scheduling, isolation against panics).
//!
//! The runtime helpers live in `tests/conformance.rs`; this script
//! only emits dispatch stubs that call them by case name.

use std::collections::HashSet;
use std::error::Error;
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};

use serde::Deserialize;

/// The single-source case classifier, `conformance/classifier.json` — the
/// same file the two TS hosts read (`hosts/conformance-shared`). It carries
/// the marker filenames, the dispatch precedence, and the wasm-host skip
/// families as data, so this build script, the TS hosts, and the Zig
/// reference runner can never disagree on classification. (The Zig runner
/// classifies natively and is the reference; it mirrors this file.)
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Classifier {
    markers: Markers,
    precedence: Vec<String>,
    /// Families the Rust host does not emit a test for. Same set as the Web
    /// host (both drive the kitchen-sink `sjon.wasm`); the TS-parity port's
    /// larger skip set stays host-local and is not in this file.
    wasm_host_skip_families: Vec<SkipFamily>,
}

#[derive(Deserialize)]
struct Markers {
    legacy: String,
    query: String,
    inline: String,
}

#[derive(Deserialize)]
struct SkipFamily {
    label: String,
    #[serde(rename = "match")]
    matcher: Matcher,
    reason: String,
}

#[derive(Deserialize)]
struct Matcher {
    #[serde(rename = "type")]
    kind: String,
    value: String,
}

impl Matcher {
    fn matches(&self, name: &str) -> bool {
        match self.kind.as_str() {
            "prefix" => name.starts_with(&self.value),
            "exact" => name == self.value,
            other => panic!("classifier.json: unknown match type {other:?}"),
        }
    }
}

impl Classifier {
    /// The reason `name` is skipped, or `None` when the Rust host runs it.
    fn skip_reason(&self, name: &str) -> Option<&str> {
        self.wasm_host_skip_families
            .iter()
            .find(|f| f.matcher.matches(name))
            .map(|f| f.reason.as_str())
    }

    /// Does `case_dir` carry the marker file for `runner`?
    fn marker_present(&self, case_dir: &Path, runner: &str) -> bool {
        let file = match runner {
            "legacy" => &self.markers.legacy,
            "query" => &self.markers.query,
            "inline" => &self.markers.inline,
            _ => return false,
        };
        case_dir.join(file).exists()
    }
}

/// The generated-test prefix + runtime helper for a runner label. Mirrors
/// the Zig runner's `CaseKind` → runner-branch dispatch.
fn helper_for(runner: &str) -> Option<(&'static str, &'static str)> {
    match runner {
        "legacy" => Some(("legacy", "run_legacy_case_as_host")),
        "query" => Some(("query", "run_query_case")),
        "inline" => Some(("inline", "run_inline_case")),
        _ => None,
    }
}

fn corpus_dir() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../conformance/cases");
    p
}

fn classifier_path() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../conformance/classifier.json");
    p
}

/// Lowercase + `-` → `_`. Any other non-`[a-z0-9_]` byte becomes `_`
/// too, so quirky names still produce a valid Rust identifier.
fn sanitize(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    for ch in name.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
        } else {
            out.push('_');
        }
    }
    out
}

fn main() -> Result<(), Box<dyn Error>> {
    let corpus = corpus_dir();
    let classifier_file = classifier_path();
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed={}", corpus.display());
    // Re-run when the single-source classifier changes (skip families,
    // markers, precedence) — same data the two TS hosts read.
    println!("cargo:rerun-if-changed={}", classifier_file.display());

    let classifier: Classifier = serde_json::from_str(&fs::read_to_string(&classifier_file)?)?;

    let mut entries: Vec<String> = fs::read_dir(&corpus)?
        .filter_map(Result::ok)
        .filter(|d| d.file_type().ok().is_some_and(|t| t.is_dir()))
        .map(|d| d.file_name().to_string_lossy().into_owned())
        // Drop hidden dirs (the gitignored `.zig-cache` build cache) —
        // dir-only + dot-filter, matching the TS-host discovery. Without
        // this, `.zig-cache` has no runner marker and would trip the
        // unmatched-dir build error below.
        .filter(|name| !name.starts_with('.'))
        .collect();
    entries.sort();

    let mut emitted: HashSet<String> = HashSet::new();
    let mut body = String::new();
    body.push_str("// @generated by build.rs from conformance/cases — do not edit.\n\n");

    let mut inline_count = 0usize;
    let mut legacy_count = 0usize;
    let mut query_count = 0usize;
    let mut skipped_count = 0usize;
    for name in &entries {
        // Skip-first: a reasoned skip short-circuits runner dispatch (a
        // `lowering-*` dir carries a `document.sjon` marker but must not be
        // emitted as an inline test). The reason lands in the generated
        // file so `cargo expand` / a reader sees why a case is absent.
        if let Some(reason) = classifier.skip_reason(name) {
            writeln!(body, "// skipped: {name} — {reason}")?;
            skipped_count += 1;
            continue;
        }
        let case_dir = corpus.join(name);
        // A legacy (schema) case and a document/query case cannot share a
        // dir — the dispatch below picks query while the TS hosts picked
        // legacy by precedence, so the same dir would route to a different
        // runner per host. Fail the build rather than silently routing.
        // document+query alone is a valid query case, so only
        // schema-alongside-document/query is ambiguous. Mirrors the
        // `no case dir has ambiguous markers` audit in the shared TS runner.
        if classifier.marker_present(&case_dir, "legacy")
            && (classifier.marker_present(&case_dir, "inline")
                || classifier.marker_present(&case_dir, "query"))
        {
            return Err(format!(
                "conformance build.rs: case dir `{name}` carries a schema.sjon alongside a document/query marker — a legacy case and a document/query case can't share a dir; remove the conflicting marker"
            )
            .into());
        }
        // Dispatch by the JSON precedence: the first runner whose marker is
        // present. With the ambiguity guard above, schema (legacy) is
        // exclusive, so the order that resolves is query-before-inline (a
        // doc+query dir is a query case). Mirrors classifyCase + the Zig runner.
        let runner = classifier
            .precedence
            .iter()
            .find(|r| classifier.marker_present(&case_dir, r))
            .map(String::as_str);
        let (prefix, helper) = match runner {
            Some(r) => helper_for(r).ok_or_else(|| {
                format!(
                    "conformance build.rs: classifier.json precedence lists unknown runner `{r}`"
                )
            })?,
            // No runner marker and no skip family — a misfiled case or a
            // new fixture nobody wired up. Fail the build loudly rather
            // than silently dropping it from coverage (the failure mode the
            // old `else { continue }` hid).
            None => {
                return Err(format!(
                    "conformance build.rs: case dir `{name}` has no runner marker (schema/document/query.sjon) and matches no skip family — add a marker or a classifier.json family"
                )
                .into());
            }
        };
        match prefix {
            "inline" => inline_count += 1,
            "legacy" => legacy_count += 1,
            "query" => query_count += 1,
            _ => {}
        }

        let fn_name = format!("{prefix}_{}", sanitize(name));
        if !emitted.insert(fn_name.clone()) {
            return Err(format!(
                "conformance build.rs: sanitized test name `{fn_name}` collides — fixture `{name}` would shadow an earlier case"
            )
            .into());
        }
        writeln!(body, "#[test]\nfn {fn_name}() {{ {helper}(\"{name}\"); }}")?;
    }

    // Dead-rule detector: a skip family matching nothing is stale (its
    // cases were renamed or deleted) and silently narrows coverage.
    for fam in &classifier.wasm_host_skip_families {
        if !entries.iter().any(|n| fam.matcher.matches(n)) {
            return Err(format!(
                "conformance build.rs: skip family `{}` (in classifier.json) matches no case dir — stale, remove it or fix the matcher",
                fam.label
            )
            .into());
        }
    }

    // Each leg must be non-empty. `query_count` is here because it was
    // missing: losing every `query.sjon` marker would have silently dropped
    // the whole PatternQuery leg from this host with a green build.
    if inline_count == 0 || legacy_count == 0 || query_count == 0 {
        return Err(format!(
            "conformance build.rs: every corpus leg must be non-empty (inline={inline_count}, legacy={legacy_count}, query={query_count}) under {}",
            corpus.display()
        )
        .into());
    }

    writeln!(
        body,
        "\n// coverage: {inline_count} inline + {legacy_count} legacy + {query_count} query tests emitted, {skipped_count} dirs skipped"
    )?;

    let out_dir = std::env::var_os("OUT_DIR").ok_or("OUT_DIR not set")?;
    let out_path = PathBuf::from(out_dir).join("conformance_generated.rs");
    fs::write(&out_path, body)?;
    Ok(())
}
