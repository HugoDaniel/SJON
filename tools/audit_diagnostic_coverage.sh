#!/usr/bin/env bash
# Audit `Ast.Diagnostic.Code` test coverage.
#
# For every variant of the `Code` enum, confirm at least one test or
# conformance fixture references it by name. References we accept:
#
#   * `.<name>`    — Zig enum literal (test code).
#   * `:code <name>`         — conformance `expected.sjon` body.
#
# We DO NOT accept the enum definition itself or doc comments — only
# call sites that actually exercise the code on a live diagnostic.
#
# Output: human-readable per-code status, plus a final OK/FAIL summary.
# Exit 0 on full coverage, 1 if any variant has no reference.
#
# Usage: tools/audit_diagnostic_coverage.sh

set -e
cd "$(dirname "$0")/.."

AST="src/Ast.zig"
if [ ! -f "$AST" ]; then
    echo "audit_diagnostic_coverage.sh: $AST not found" >&2
    exit 1
fi

# Pull variants from the `pub const Code = enum { ... };` block.
codes=$(awk '/pub const Code = enum \{/,/^    \};/' "$AST" \
    | grep -E '^[[:space:]]+[a-z_]+,$' \
    | sed 's/^[[:space:]]*//;s/,$//')

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
        awk '
            /^test ".*" \{/ { in_test = 1 }
            in_test { print }
            in_test && /^\}$/ { in_test = 0 }
        ' "$f" >> "$out"
    done < "$tmp/tests.list"
}
extract_tests_to "$tmp/test_bodies.txt"

missing=0
total=0
covered=0

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

    case $hits in
        0)
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
done

echo
printf "Covered: %d/%d  Missing: %d\n" "$covered" "$total" "$missing"

if [ "$missing" -gt 0 ]; then
    exit 1
fi
