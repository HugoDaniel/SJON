#!/usr/bin/env bash
# Audit `Ast.Diagnostic.Code` test coverage.
#
# Two tiers.
#
# Tier 1 — every variant of the `Code` enum is referenced by at least one
# test or conformance fixture. References we accept:
#
#   * `.<name>`    — Zig enum literal (test code).
#   * `:code <name>`         — conformance `expected.sjon` body.
#
# We DO NOT accept the enum definition itself or doc comments — only
# call sites that actually exercise the code on a live diagnostic.
#
# Tier 2 — every variant NOT listed in `corpus_exempt_diagnostic_codes.txt`
# has a *corpus* reference specifically. Tier 1 accepts a Zig test as
# sufficient, which lets a code be fully covered on the reference
# implementation and never replayed against the Node, Rust or TypeScript
# hosts; the corpus is the only cross-host axis there is. Tier 2 makes
# "reachable from a document" imply "checked on every host", and the
# exempt list is the written-down set of what cannot be.
#
# Both allowlists fail on a STALE entry — one that has since gained the
# coverage it was excused from — so neither can grow by accident.
#
# Output: human-readable per-code status, plus a final OK/FAIL summary.
# Exit 0 on full coverage, 1 if any variant has no reference.
#
# Usage: tools/audit_diagnostic_coverage.sh <codes-file>
#   <codes-file> holds one `Ast.Diagnostic.Code` name per line, emitted by
#   tools/emit_diagnostic_codes.zig via @typeInfo (the compiler's ground
#   truth). `zig build audit-diagnostics` runs that tool and passes the
#   captured file — the canonical entry point. Reading a compiled list instead
#   of text-scraping the enum out of Ast.zig closes the class of silent
#   false-pass where a reformatted enum block under-counts variants.

set -e
cd "$(dirname "$0")/.."

AST="src/Ast.zig"
if [ ! -f "$AST" ]; then
    echo "audit_diagnostic_coverage.sh: $AST not found" >&2
    exit 1
fi

# The variant list is supplied as $1 (see Usage). Guard the empty case so a
# broken emitter can't false-pass at 0/0.
codes_file="$1"
if [ -z "$codes_file" ] || [ ! -f "$codes_file" ]; then
    echo "audit_diagnostic_coverage.sh: expected a codes-list file as \$1 (run via 'zig build audit-diagnostics')" >&2
    exit 2
fi
# `|| true`: an empty match must reach the guard below, not trip `set -e`.
codes=$(grep -E '^[a-z0-9_]+$' "$codes_file" || true)
if [ -z "$codes" ]; then
    echo "audit_diagnostic_coverage.sh: codes list is empty — emitter is broken" >&2
    exit 2
fi

# Files to search (test code + conformance fixtures). Exclude Ast.zig
# itself so the enum definition doesn't count.
find_test_files() {
    # Any .zig under src/ except Ast.zig (the enum definition lives there;
    # listing it would self-satisfy every code). Inline `test {}` blocks
    # in production files count just as much as `*_tests.zig` companions.
    find src -name '*.zig' -type f ! -path 'src/Ast.zig'
}
find_fixture_files() {
    find conformance/cases -name 'expected.sjon' -type f 2>/dev/null || true
}

# Materialize once into a temp dir so we don't re-walk per code.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
find_test_files > "$tmp/tests.list"
find_fixture_files > "$tmp/fixtures.list"

# Extract only the bodies of `test "..." { ... }` blocks from each .zig
# file. Switch arms in production code (`.unknown_form => ...`) reference
# the enum but aren't test coverage — only what runs inside a test block
# counts. We exploit Zig style: tests are top-level, so the closing `}`
# sits at column 0.
extract_tests_to() {
    local out="$1"
    : > "$out"
    while read -r f; do
        # Comments are stripped from the extracted bodies: a commented-out
        # or merely-mentioned `.some_code` inside a test is prose, not
        # coverage. (No code relies on this today — it is closed before it
        # can be leaned on, which is exactly how the constructibility
        # tests started.)
        awk '
            /^test ".*" \{/ { in_test = 1 }
            in_test { line = $0; sub(/\/\/.*$/, "", line); print line }
            in_test && /^\}$/ { in_test = 0 }
        ' "$f" >> "$out"
    done < "$tmp/tests.list"
}
extract_tests_to "$tmp/test_bodies.txt"

# Reserved-code allowlist: codes deliberately exempt, each with a reason.
# See the file's own header for why this exists rather than the previous
# arrangement (construct-only tests that satisfied the grep without ever
# firing the code).
RESERVED_FILE="tools/reserved_diagnostic_codes.txt"
if [ -f "$RESERVED_FILE" ]; then
    sed 's/#.*//' "$RESERVED_FILE" | grep -E '^[a-z0-9_]+$' > "$tmp/reserved.txt" || true
else
    : > "$tmp/reserved.txt"
fi
is_reserved() {
    grep -qx "$1" "$tmp/reserved.txt"
}

# Corpus-exempt allowlist (tier 2): codes that cannot have a corpus case,
# each with a reason. Same stale rule as the reserved list.
CORPUS_EXEMPT_FILE="tools/corpus_exempt_diagnostic_codes.txt"
if [ -f "$CORPUS_EXEMPT_FILE" ]; then
    sed 's/#.*//' "$CORPUS_EXEMPT_FILE" | grep -E '^[a-z0-9_]+$' > "$tmp/corpus_exempt.txt" || true
else
    : > "$tmp/corpus_exempt.txt"
fi
is_corpus_exempt() {
    grep -qx "$1" "$tmp/corpus_exempt.txt"
}

missing=0
total=0
covered=0
reserved=0
stale=0
corpus_missing=0
corpus_exempt=0
corpus_stale=0

for code in $codes; do
    total=$((total + 1))
    hits=0

    # Enum-literal usage inside a `test {}` body: `.unknown_form` with a
    # trailing non-identifier character. Grepping only the extracted
    # bodies keeps production switch-arms from satisfying the check.
    if [ -s "$tmp/test_bodies.txt" ] && \
        grep -qE "\.${code}([^a-zA-Z0-9_]|$)" "$tmp/test_bodies.txt"; then
        hits=$((hits + 1))
    fi

    # Conformance expected.sjon: `:code unknown_form` (bare symbol).
    if [ -s "$tmp/fixtures.list" ] && \
        xargs grep -hEl ":code[[:space:]]+${code}([^a-zA-Z0-9_]|$)" < "$tmp/fixtures.list" >/dev/null 2>&1; then
        hits=$((hits + 2))
    fi

    # A reserved code that has since gained real coverage is a stale
    # allowlist entry: fail so the entry gets deleted. Without this the
    # list would only ever grow, which is how the previous crutch formed.
    if [ "$hits" -gt 0 ] && is_reserved "$code"; then
        printf "  STALE       %s (covered now — delete it from %s)\n" "$code" "$RESERVED_FILE"
        stale=$((stale + 1))
        continue
    fi

    case $hits in
        0)
            if is_reserved "$code"; then
                printf "  reserved    %s\n" "$code"
                reserved=$((reserved + 1))
                continue
            fi
            printf "  MISSING     %s\n" "$code"
            missing=$((missing + 1))
            ;;
        1)
            printf "  test        %s\n" "$code"
            covered=$((covered + 1))
            ;;
        2)
            printf "  conformance %s\n" "$code"
            covered=$((covered + 1))
            ;;
        3)
            printf "  both        %s\n" "$code"
            covered=$((covered + 1))
            ;;
    esac

    # --- Tier 2: corpus-reachable => corpus-referenced ------------------
    # Reserved codes are past this point only when hits == 0, and they
    # have no emitter at all, so they are exempt from tier 2 by
    # construction rather than by being listed twice.
    if is_reserved "$code"; then
        continue
    fi
    if [ $((hits & 2)) -ne 0 ]; then
        # Has a corpus case. If it is also on the exempt list, that entry
        # is stale — the same rule the reserved list follows, so neither
        # allowlist can quietly outlive its reason.
        if is_corpus_exempt "$code"; then
            printf "  CORPUS-STALE %s (has a case now — delete it from %s)\n" \
                "$code" "$CORPUS_EXEMPT_FILE"
            corpus_stale=$((corpus_stale + 1))
        fi
    elif is_corpus_exempt "$code"; then
        corpus_exempt=$((corpus_exempt + 1))
    else
        printf "  CORPUS-MISSING %s (covered by a Zig test only — add a conformance case, or list it in %s with a reason)\n" \
            "$code" "$CORPUS_EXEMPT_FILE"
        corpus_missing=$((corpus_missing + 1))
    fi
done

echo
printf "Covered: %d/%d  Reserved: %d  Missing: %d  Stale: %d\n" \
    "$covered" "$total" "$reserved" "$missing" "$stale"
printf "Corpus tier: exempt %d  Missing: %d  Stale: %d\n" \
    "$corpus_exempt" "$corpus_missing" "$corpus_stale"

if [ "$reserved" -gt 0 ]; then
    printf "  (reserved codes are exempt by %s — each entry states why)\n" "$RESERVED_FILE"
fi
if [ "$corpus_exempt" -gt 0 ]; then
    printf "  (corpus-exempt codes are excused from the cross-host tier by %s)\n" "$CORPUS_EXEMPT_FILE"
fi

if [ "$missing" -gt 0 ] || [ "$stale" -gt 0 ] || \
   [ "$corpus_missing" -gt 0 ] || [ "$corpus_stale" -gt 0 ]; then
    exit 1
fi
