#!/usr/bin/env bash
# Audit that human-facing docs stay consistent with machine truths.
#
# Structured facts only — three checks, each comparing a documented number
# against its live source of truth so the record can't silently drift the
# way it did behind the mid-May wire bumps (README/DESIGN stuck at 0x01
# while the code reached 0x04):
#
#   1. The README wire-format table `version` row must equal
#      `Binary.wire_version` (the literal lives in src/BinaryFormat.zig).
#   2. docs/DESIGN.md must mention the current wire version, and must not
#      carry a stale "Wire version stays 0xNN" claim for a *different* NN.
#   3. The "<n> fixtures" (README) and "<n> corpus cases" (CLAUDE.md)
#      counts must equal the live conformance case count — dirs under
#      conformance/cases/ carrying schema.sjon or document.sjon, the same
#      probe src/conformance_tests.zig discoverCases uses. CLAUDE.md's
#      "<n> value-carrying" count is likewise pinned to the live number of
#      generated expected.values.json siblings.
#   4. Each dedicated-suite count CLAUDE.md advertises (e.g. `Validator_tests.zig`
#      (583 cases)) must equal `grep -c '^test "'` on that suite — the same probe
#      `zig build test` compiles. Bump the doc number in the same commit as the
#      test that moved it.
#   5. Every `pub const X = @import(…)` in src/root.zig must be named at least
#      once in docs/DESIGN.md. The one structural check — the module table had
#      fallen a third behind the surface, which is the failure a numbers-only
#      audit cannot see.
#   6. Every `zig build <verb>` a doc names must resolve to a real build step
#      (the authoritative list is `zig build -l` — steps are defined through
#      helpers, so scraping `b.step("…")` from source would miss most). Catches
#      a doc naming a verb that doesn't exist, e.g. README's `zig build wasm-lsp`
#      while the step was still `lsp-wasm`.
#
# Deliberately dumb: it compares numbers, not prose. It does not lint
# wording. Each documented anchor must appear at least once (a vanished
# anchor is a failure, not a silent pass).
#
# Output: per-check status + a final OK/FAIL line. Exit 0 when every
# documented number matches its truth, 1 otherwise, 2 on a probe error.
#
# Usage: tools/audit_docs.sh

cd "$(dirname "$0")/.." || exit 2

status=0
pass() { printf '  ok    %s\n' "$1"; }
bad() {
    printf '  FAIL  %s\n' "$1"
    status=1
}

# --- truth 1: wire version from src/BinaryFormat.zig ---
# The literal lives in the wire-vocabulary leaf `BinaryFormat.zig`; Binary.zig
# only re-exports it (`pub const wire_version = fmt.wire_version;`), so grep the
# leaf. `Binary.wire_version` stays the public name the docs reference.
wire=$(grep -oE 'pub const wire_version: u8 = 0x[0-9A-Fa-f]+' src/BinaryFormat.zig |
    grep -oE '0x[0-9A-Fa-f]+' | head -1 | tr 'A-F' 'a-f')
if [ -z "$wire" ]; then
    echo "audit_docs.sh: cannot parse Binary.wire_version from src/BinaryFormat.zig" >&2
    exit 2
fi

# --- truth 2: live conformance case count ---
# A case directory carries schema.sjon (legacy) or document.sjon (inline /
# query). Dotdirs (e.g. .zig-cache) are skipped by the glob, matching the
# runner, which only counts entries carrying those files.
cases=0
for d in conformance/cases/*/; do
    [ -d "$d" ] || continue
    if [ -f "${d}schema.sjon" ] || [ -f "${d}document.sjon" ]; then
        cases=$((cases + 1))
    fi
done
if [ "$cases" -eq 0 ]; then
    echo "audit_docs.sh: found 0 conformance cases — probe is broken" >&2
    exit 2
fi

# --- check 1: README wire-table version row ---
row_hex=$(grep -E '^\| `version`' README.md | grep -oiE '0x[0-9A-Fa-f]+' | head -1 | tr 'A-F' 'a-f')
if [ -z "$row_hex" ]; then
    bad "README has no wire-table \`version\` row (expected 0xNN == $wire)"
elif [ "$row_hex" = "$wire" ]; then
    pass "README wire-table version row = $wire"
else
    bad "README wire-table version row is '$row_hex', expected '$wire' (BinaryFormat.zig wire_version)"
fi

# --- check 2: DESIGN.md mentions current version + carries no stale 'stays' ---
if grep -q "$wire" docs/DESIGN.md; then
    pass "docs/DESIGN.md mentions current wire version $wire"
else
    bad "docs/DESIGN.md never mentions the current wire version $wire"
fi
stale=$(grep -oiE 'Wire version stays `?0x[0-9A-Fa-f]+' docs/DESIGN.md |
    grep -oiE '0x[0-9A-Fa-f]+' | tr 'A-F' 'a-f' | grep -vx "$wire")
if [ -n "$stale" ]; then
    bad "docs/DESIGN.md has a stale 'Wire version stays' claim ($stale); current is $wire"
else
    pass "docs/DESIGN.md carries no stale 'Wire version stays' claim"
fi

# --- check 3: corpus counts (README fixtures, CLAUDE corpus cases) ---
# Reconcile every `<n> <phrase>` occurrence in $file against $want (defaults
# to the live conformance case count). A vanished anchor is a failure.
check_count() {
    local file="$1" phrase="$2" want="${3:-$cases}"
    local found=0 n
    while read -r n; do
        [ -z "$n" ] && continue
        found=1
        if [ "$n" = "$want" ]; then
            pass "$file '$n $phrase' matches live count"
        else
            bad "$file says '$n $phrase', live count is $want"
        fi
    done < <(grep -oE "[0-9]+ $phrase" "$file" | grep -oE '^[0-9]+')
    if [ "$found" -eq 0 ]; then
        bad "$file has no '<n> $phrase' anchor (expected $want)"
    fi
}
check_count README.md fixtures

# CLAUDE.md is a dev-repo-only file: the public release cut ships without
# it, so every CLAUDE.md check below runs only when the file is present.
# In the dev repo its absence would mean the file was deleted, which the
# guard would hide — but so would deleting README.md, and the audit's job
# is reconciling numbers in the docs that exist.
if [ -f CLAUDE.md ]; then
    check_count CLAUDE.md "corpus cases"

    # CLAUDE.md's "<n> value-carrying" count vs the live number of generated
    # expected.values.json siblings (the drift gate from `zig build
    # gen-expected-values`). CHANGELOG carries the same phrase but freezes at
    # release, so it is deliberately not gated here.
    values=$(find conformance/cases -mindepth 2 -maxdepth 2 -name expected.values.json | wc -l | tr -d ' ')
    check_count CLAUDE.md "value-carrying" "$values"
else
    pass "CLAUDE.md absent (release cut) — its doc checks are skipped"
fi

# --- check 4: dedicated-suite test counts (CLAUDE.md) ---
# CLAUDE.md's Tests section names each heavy sibling with its live `test "…"`
# count, e.g. `Validator_tests.zig` (583 cases). Reconcile the documented number
# against `grep -c '^test "'` on the file — the `.` in the pattern matches the
# closing backtick, keeping the shell out of backtick command substitution.
check_suite() {
    local suite="$1"
    # Most siblings live in src/; a few (Handler_tests) sit in a subdir, so
    # callers may pass an explicit path as $2. The CLAUDE.md anchor is keyed
    # on the bare `${suite}.zig` name regardless of directory.
    local file="${2:-src/${suite}.zig}"
    if [ ! -f "$file" ]; then
        bad "CLAUDE.md suite check: $file does not exist"
        return
    fi
    local actual claimed
    actual=$(grep -cE '^test "' "$file")
    claimed=$(grep -oE "${suite}\.zig. \([0-9]+" CLAUDE.md | grep -oE '[0-9]+' | head -1)
    if [ -z "$claimed" ]; then
        bad "CLAUDE.md has no \`${suite}.zig\` (<n>) anchor (live count $actual)"
    elif [ "$claimed" = "$actual" ]; then
        pass "CLAUDE.md \`${suite}.zig\` ($claimed) matches live test count"
    else
        bad "CLAUDE.md says \`${suite}.zig\` ($claimed), live \`test\` count is $actual"
    fi
}
if [ -f CLAUDE.md ]; then
    for suite in Validator_tests Expr_tests ManifestLoader_tests Binary_tests Json_tests Host_tests; do
        check_suite "$suite"
    done
    check_suite Handler_tests src/lsp/Handler_tests.zig
fi

# --- check 5: every root.zig export is named somewhere in DESIGN.md ---
# The one structural check here, and the reason it earns its place among the
# numeric ones: DESIGN.md's module table had fallen roughly a third behind the
# surface — no mention of EffectiveDocument, SchemaExport, Explanations,
# Lockfile, Glob, StringFormats, DidYouMean, CappedRead, PluginValueCodec,
# wasm_common, or ConformanceExpected. A module table that silently stops
# covering the modules is worse than no table: a reader trusts it to be the
# index it claims to be.
#
# Deliberately weak: presence anywhere in the file, not a table row, not a
# description. Anything stronger would be prose linting, which this script
# does not do. It catches the failure that actually happened — a new root
# export landing with no mention at all.
exports=$(grep -oE '^pub const [A-Za-z_]+ = @import' src/root.zig | awk '{print $3}')
if [ -z "$exports" ]; then
    echo "audit_docs.sh: found no 'pub const X = @import' in src/root.zig — probe is broken" >&2
    exit 2
fi
missing=""
for name in $exports; do
    grep -qF "$name" docs/DESIGN.md || missing="$missing $name"
done
if [ -n "$missing" ]; then
    bad "docs/DESIGN.md never mentions:$missing"
else
    pass "every src/root.zig export is named in DESIGN.md ($(printf '%s\n' "$exports" | wc -l | tr -d ' ') exports)"
fi

# --- check 6: documented build verbs resolve to real steps ---
# The step universe is `zig build -l` (build.zig defines many steps through
# helpers — addSjonTool / addWasmExe / nodeTestStep — so their names never
# appear as a literal `b.step("…")` to scrape). Runs a nested `zig build -l`
# (list-only: instantiates the build graph, builds no artifacts), so it is safe
# under the `zig build audit-docs` / `verify` parent.
if command -v zig >/dev/null 2>&1; then
    steps=$(zig build -l 2>/dev/null | awk 'NF {print $1}')
    if [ -z "$steps" ]; then
        echo "audit_docs.sh: 'zig build -l' produced no steps — probe is broken" >&2
        exit 2
    fi
    # Built-ins zig always provides (not created via b.step) that a doc may name.
    steps=$(printf '%s\ninstall\nuninstall\n' "$steps")
    verbs=$(grep -hoE 'zig build [a-z][a-z0-9-]*' README.md CLAUDE.md docs/*.md 2>/dev/null |
        sed 's/^zig build //' | sort -u)
    if [ -z "$verbs" ]; then
        bad "no 'zig build <verb>' references found in README/CLAUDE/docs — probe drift?"
    fi
    for verb in $verbs; do
        if printf '%s\n' "$steps" | grep -qxF "$verb"; then
            pass "doc verb \`zig build $verb\` resolves"
        else
            bad "doc verb \`zig build $verb\` matches no build step (see \`zig build -l\`)"
        fi
    done
else
    bad "zig not on PATH — cannot audit documented build verbs"
fi

echo
if [ "$status" -eq 0 ]; then
    printf 'audit-docs: OK (wire %s, %d corpus cases)\n' "$wire" "$cases"
else
    printf 'audit-docs: FAIL\n'
fi
exit "$status"
