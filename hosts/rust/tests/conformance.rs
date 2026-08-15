//! Conformance corpus runner — D6 host.
//!
//! Walks `conformance/cases/*` and runs every fixture through
//! `SjonHost::validate_document`. One `#[test]` per fixture is
//! emitted by `build.rs` into `conformance_generated.rs` and
//! `include!`d below — that mirrors the discovery-time `for` loops in
//! `hosts/web/test/conformance.test.ts` and the inline / `conformance
//! host:` branches of `hosts/typescript-parity/test/conformance.test.ts`,
//! and gives the Rust host per-fixture libtest output, `cargo test`
//! filtering, parallel scheduling, and panic isolation.
//!
//! Inline fixtures (`document.sjon`, no `schema.sjon`) go through
//! `run_inline_case`; legacy fixtures (`schema.sjon` + `input.sjon`)
//! are synthesised into a single document containing each plugin
//! manifest as an inline `(plugin …)` declaration and routed through
//! `run_legacy_case_as_host`.
//!
//! Cross-host parity contract: `(code, path)` stream must match the Zig
//! CLI, ts-parity, and the D5 web host for every fixture.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use sjon_host::{FilesystemResolver, HostDiagnostic, HostOptions, Resolver, SjonHost};

mod common;

use common::{ExpectedDiagnostic, format_diags, read_expected, read_values_json, wasm_path};

fn corpus_dir() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../conformance/cases");
    p
}

/// Read `sjon.wasm` once per test-binary run. With ~200 per-fixture
/// tests running in parallel, reading the bytes 200 times is wasted
/// I/O — `SjonHost::load_bytes` accepts the cached slice and each test
/// still gets its own wasmtime `Store` / `Linker`.
fn wasm_bytes() -> &'static [u8] {
    static BYTES: OnceLock<Vec<u8>> = OnceLock::new();
    BYTES.get_or_init(|| {
        let path = wasm_path();
        std::fs::read(&path).unwrap_or_else(|err| panic!("read {}: {}", path.display(), err))
    })
}

fn assert_diagnostics_match(
    name: &str,
    actual: &[&HostDiagnostic],
    expected: &[ExpectedDiagnostic],
) {
    assert_eq!(
        actual.len(),
        expected.len(),
        "{}: diagnostic count mismatch. Got: {}",
        name,
        format_diags(actual),
    );
    for (i, (a, e)) in actual.iter().zip(expected.iter()).enumerate() {
        assert_eq!(
            a.code, e.code,
            "{} #{}: code mismatch (got {}, want {}); message={}",
            name, i, a.code, e.code, a.message,
        );
        assert_eq!(
            a.severity, e.severity,
            "{} #{}: severity mismatch (got {:?}, want {:?})",
            name, i, a.severity, e.severity,
        );
        assert_eq!(
            a.path,
            e.path,
            "{} #{}: path mismatch (got [{}], want [{}])",
            name,
            i,
            a.path.join(" "),
            e.path.join(" "),
        );
    }
}

/// D6 (4/4) — graduate the legacy schema+input fixtures through the
/// host pipeline by synthesising a single document containing each
/// plugin manifest as an inline `(plugin …)` declaration followed by
/// the input source. Mirrors `runLegacyCaseAsHost` in
/// `src/conformance_tests.zig`, the `conformance host: …` loop in
/// `hosts/typescript-parity/test/conformance.test.ts`, and the
/// matching loop in `hosts/web/test/conformance.test.ts`.
/// Concatenate `schema.sjon`, each `extra-*.sjon` in lexical order, and
/// `input.sjon` with `\n` separators. This recipe MUST stay byte-identical
/// to `synthesizeLegacyDocument` in `hosts/conformance-shared/index.ts`,
/// which the two TypeScript hosts share. Extracted from
/// `run_legacy_case_as_host` so `legacy_synthesis_matches_golden` can
/// diff it against the checked-in golden both sides now compare against —
/// the "MUST stay byte-identical" note used to be enforced by nothing.
fn synthesize_legacy_document(case_dir: &std::path::Path) -> String {
    let schema_src = std::fs::read_to_string(case_dir.join("schema.sjon"))
        .unwrap_or_else(|err| panic!("read {}/schema.sjon: {err}", case_dir.display()));
    let input_src = std::fs::read_to_string(case_dir.join("input.sjon"))
        .unwrap_or_else(|err| panic!("read {}/input.sjon: {err}", case_dir.display()));

    let mut extra_paths: Vec<PathBuf> = std::fs::read_dir(case_dir)
        .unwrap_or_else(|err| panic!("read {}: {}", case_dir.display(), err))
        .filter_map(|res| res.ok().map(|d| d.path()))
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("extra-"))
                && p.extension().is_some_and(|ext| ext == "sjon")
        })
        .collect();
    extra_paths.sort();
    let mut synthetic = String::new();
    synthetic.push_str(&schema_src);
    for path in &extra_paths {
        synthetic.push('\n');
        synthetic.push_str(
            &std::fs::read_to_string(path)
                .unwrap_or_else(|err| panic!("read {}: {}", path.display(), err)),
        );
    }
    synthetic.push('\n');
    synthetic.push_str(&input_src);
    synthetic
}

fn run_legacy_case_as_host(name: &str) {
    let case_dir = corpus_dir().join(name);
    let expected_src = std::fs::read_to_string(case_dir.join("expected.sjon"))
        .unwrap_or_else(|err| panic!("read {name}/expected.sjon: {err}"));
    let synthetic = synthesize_legacy_document(&case_dir);

    let mut host = SjonHost::load_bytes(wasm_bytes(), None)
        .unwrap_or_else(|err| panic!("load sjon.wasm: {err}"));
    let opts = HostOptions {
        project_root: Some(case_dir.display().to_string()),
        ..HostOptions::default()
    };
    let result = host
        .validate_document(&synthetic, &opts)
        .unwrap_or_else(|err| panic!("validate {name}: {err}"));
    let errs: Vec<&HostDiagnostic> = result.diagnostics.iter().collect();
    let expected = read_expected(&expected_src)
        .unwrap_or_else(|err| panic!("parse {name}/expected.sjon: {err}"));
    assert_diagnostics_match(name, &errs, &expected);
}

fn run_inline_case(name: &str) {
    let case_dir = corpus_dir().join(name);
    let document_src = std::fs::read_to_string(case_dir.join("document.sjon"))
        .unwrap_or_else(|err| panic!("read {name}/document.sjon: {err}"));
    let expected_src = std::fs::read_to_string(case_dir.join("expected.sjon"))
        .unwrap_or_else(|err| panic!("read {name}/expected.sjon: {err}"));
    let project_file = case_dir.join("sjon-project.sjon");
    let project_file_opt = if project_file.exists() {
        Some(project_file.as_path())
    } else {
        None
    };

    // Always supply a resolver — even without a project file, the
    // explicit-`:path` branch is needed (e.g. `use-plugin-name-mismatch`).
    // `FilesystemResolver` handles `project_file=None` by leaving the
    // index empty; `:path` still resolves.
    let (resolver, project_diagnostics) = FilesystemResolver::build(&case_dir, project_file_opt);
    let resolver: Arc<dyn Resolver> = Arc::new(resolver);

    let mut host = SjonHost::load_bytes(wasm_bytes(), Some(resolver))
        .unwrap_or_else(|err| panic!("load sjon.wasm: {err}"));
    let opts = HostOptions {
        project_root: Some(case_dir.display().to_string()),
        project_file: project_file_opt.map(|p| p.display().to_string()),
        project_diagnostics,
        ..HostOptions::default()
    };
    let result = host
        .validate_document(&document_src, &opts)
        .unwrap_or_else(|err| panic!("validate {name}: {err}"));
    let errs: Vec<&HostDiagnostic> = result.diagnostics.iter().collect();
    let expected = read_expected(&expected_src)
        .unwrap_or_else(|err| panic!("parse {name}/expected.sjon: {err}"));
    assert_diagnostics_match(name, &errs, &expected);

    // Optional `expected.values.json` sibling — generated at build time
    // from the fixture's `(values …)` block through the same
    // `wasm_common.appendValue` the envelope uses and drift-gated by
    // `zig build gen-expected-values`. Both the sibling and
    // `evaluated_results[i].value` are parsed by serde_json, so a plain
    // `==` on `serde_json::Value` is exact — no custom numeric/date/time
    // normalizer needed.
    let expected_values = read_values_json(&case_dir);
    for (index_str, expected_value) in &expected_values {
        let index: usize = index_str
            .parse()
            .unwrap_or_else(|_| panic!("{name}: non-integer value index `{index_str}`"));
        let actual = result
            .evaluated_results
            .iter()
            .find(|r| r.index == index)
            .unwrap_or_else(|| {
                let got: Vec<String> = result
                    .evaluated_results
                    .iter()
                    .map(|r| r.index.to_string())
                    .collect();
                panic!(
                    "{}: expected value at index {} but no matching evaluatedResults entry; got [{}]",
                    name, index, got.join(", ")
                );
            });
        assert_eq!(
            &actual.value, expected_value,
            "{name}: value mismatch at index {index}"
        );
    }
}

/// Run a `PatternQuery` fixture: parse the window from `query.sjon`, query the
/// pattern over WASM, and compare the returned `(haps …)` / `(diagnostics …)`
/// text against `expected.sjon`. Both are parsed by the shared SJON subset
/// parser, so a structural `Node` equality is the cross-host check.
fn run_query_case(name: &str) {
    use sjon_host::__fuzz_only::{Node, parse_single_form};

    let case_dir = corpus_dir().join(name);
    let document_src = std::fs::read_to_string(case_dir.join("document.sjon"))
        .unwrap_or_else(|err| panic!("read {name}/document.sjon: {err}"));
    let query_src = std::fs::read_to_string(case_dir.join("query.sjon"))
        .unwrap_or_else(|err| panic!("read {name}/query.sjon: {err}"));
    let expected_src = std::fs::read_to_string(case_dir.join("expected.sjon"))
        .unwrap_or_else(|err| panic!("read {name}/expected.sjon: {err}"));

    let (begin, end, seed) =
        parse_query_spec(&query_src).unwrap_or_else(|err| panic!("parse {name}/query.sjon: {err}"));

    let mut host = SjonHost::load_bytes(wasm_bytes(), None)
        .unwrap_or_else(|err| panic!("load sjon.wasm: {err}"));
    let actual_text = host
        .query_pattern(&document_src, begin, end, seed)
        .unwrap_or_else(|err| panic!("query {name}: {err}"));

    let actual: Node = parse_single_form(&actual_text)
        .unwrap_or_else(|err| panic!("parse {name} query output `{actual_text}`: {err}"))
        .unwrap_or_else(|| panic!("{name}: empty query output"));
    let expected: Node = parse_single_form(&expected_src)
        .unwrap_or_else(|err| panic!("parse {name}/expected.sjon: {err}"))
        .unwrap_or_else(|| panic!("{name}: empty expected.sjon"));

    assert_eq!(
        actual,
        expected,
        "{name}: query result mismatch\n  got:  {}\n  want: {}",
        actual_text.trim(),
        expected_src.trim()
    );
}

/// Parse `(query :window [begin end] :seed N)` into numeric ticks + seed.
fn parse_query_spec(source: &str) -> Result<(i64, i64, i64), String> {
    use sjon_host::__fuzz_only::{Node, parse_single_form};
    let form = parse_single_form(source)?.ok_or("empty query.sjon")?;
    let Node::Form { head, children } = &form else {
        return Err("query.sjon root must be a form".to_string());
    };
    if head != "query" {
        return Err(format!("query.sjon root must be (query …), got ({head} …)"));
    }
    let (mut begin, mut end, mut seed) = (0i64, 0i64, 0i64);
    for child in children {
        let Node::Kvpair { key, value } = child else {
            continue;
        };
        match (key.as_str(), value.as_ref()) {
            ("window", Node::Vector { elements }) if elements.len() == 2 => {
                begin = atom_i64(&elements[0])?;
                end = atom_i64(&elements[1])?;
            }
            ("seed", v) => seed = atom_i64(v)?,
            _ => {}
        }
    }
    Ok((begin, end, seed))
}

fn atom_i64(node: &sjon_host::__fuzz_only::Node) -> Result<i64, String> {
    use sjon_host::__fuzz_only::Node;
    match node {
        Node::Symbol(s) => s
            .parse::<i64>()
            .map_err(|e| format!("not an i64: `{s}` ({e})")),
        other => Err(format!("expected a numeric atom, got {other:?}")),
    }
}

/// This recipe and `synthesizeLegacyDocument` in
/// `hosts/conformance-shared/index.ts` build the same string, and the
/// comment on each said they "MUST stay byte-identical" while nothing
/// checked it. Both now diff against the same checked-in golden, so a
/// change to the separator or the `extra-*` ordering fails on the side
/// that made it rather than quietly desynchronising the two hosts.
///
/// `ambiguous-cross-ref-scope` is pinned because it carries an
/// `extra-b.sjon`; a case without one exercises neither the ordering nor
/// the second separator.
#[test]
fn legacy_synthesis_matches_golden() {
    let golden_path = corpus_dir().join("../legacy-synthesis.golden");
    let golden = std::fs::read_to_string(&golden_path)
        .unwrap_or_else(|err| panic!("read {}: {err}", golden_path.display()));
    let built = synthesize_legacy_document(&corpus_dir().join("ambiguous-cross-ref-scope"));
    assert_eq!(built, golden, "legacy synthesis drifted from the golden");
}

/// The expected.sjon vocabulary is closed. Every source here is a
/// fixture typo this reader used to absorb — an unknown `:severity`
/// became `Err`, an unrecognized path element became `""`, an unknown
/// key was skipped — so the assertion got quietly weaker instead of
/// failing. Mirrors the matching tests in `src/ConformanceExpected.zig`
/// and both TypeScript hosts.
#[test]
fn read_expected_rejects_unknown_vocabulary() {
    let rejected = [
        "(diagnostics 7)",
        "(diagnostics (diagnostc :code unknown_form))",
        "(diagnostics (diagnostic unknown_form))",
        "(diagnostics (diagnostic :code unknown_form :pat [a]))",
        "(diagnostics (diagnostic :code unknown_form :severity warnign))",
        "(diagnostics (diagnostic :code unknown_form :path (a)))",
        "(diagnostics (diagnostic :path [a]))",
    ];
    for src in rejected {
        assert!(
            common::read_expected(src).is_err(),
            "expected.sjon reader accepted `{src}`",
        );
    }
    // The well-formed shapes it must still accept, both severities.
    let accepted = common::read_expected(
        "(diagnostics (diagnostic :code unknown_form :path [a 0 \"b\"]) \
         (diagnostic :code deprecated_member :severity warning))",
    )
    .expect("well-formed expected.sjon");
    assert_eq!(accepted.len(), 2);
    assert_eq!(accepted[0].path, vec!["a", "0", "b"]);
    assert_eq!(accepted[1].severity, sjon_host::Severity::Warning);
}

#[test]
fn corpus_is_non_empty() {
    let corpus = corpus_dir();
    let count = std::fs::read_dir(&corpus)
        .unwrap_or_else(|err| panic!("read corpus dir {}: {}", corpus.display(), err))
        .filter_map(std::result::Result::ok)
        .count();
    assert!(count > 0, "no cases under {}", corpus.display());
}

/// One `#[test] fn inline_<name>()` / `legacy_<name>()` per fixture,
/// generated by `build.rs`. Filter from the shell with
/// e.g. `cargo test --test conformance inline_too_many_keys`.
mod conformance_generated {
    use super::{run_inline_case, run_legacy_case_as_host, run_query_case};
    include!(concat!(env!("OUT_DIR"), "/conformance_generated.rs"));
}
