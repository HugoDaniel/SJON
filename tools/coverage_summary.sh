#!/usr/bin/env bash
# Summarize a kcov coverage.json — per-file line% (alphabetical), then total.
# Output is stable so the same input produces the same bytes — suitable for
# checking in as `coverage-baseline.txt` and diffing in PR review.
#
# Usage: tools/coverage_summary.sh [coverage.json]
# Default path: zig-out/coverage/merged/kcov-merged/coverage.json
# (kcov --merge writes the merged JSON into a `kcov-merged/` subdir of the
#  output directory it was given, alongside the merged HTML report.)

set -e

# Force the C locale so awk parses and formats numbers with '.' decimals
# regardless of the caller's LC_NUMERIC. Without this, a comma-decimal locale
# (e.g. pt_PT) makes awk read the JSON's period-decimal percentages as
# truncated integers ("98.22" -> 98) and re-emit them as "98,00" — which both
# loses precision and breaks the stable-bytes promise above, diverging from the
# checked-in coverage-baseline.txt on every machine with a non-C locale.
export LC_ALL=C

cd "$(dirname "$0")/.."

JSON="${1:-zig-out/coverage/merged/kcov-merged/coverage.json}"

if ! command -v jq >/dev/null; then
    echo "tools/coverage_summary.sh: jq required but not found" >&2
    exit 1
fi

if [ ! -f "$JSON" ]; then
    echo "tools/coverage_summary.sh: $JSON not found — run \`zig build coverage\` first" >&2
    exit 1
fi

# The header travels with the output, not with the checked-in file: the
# documented refresh command redirects over `coverage-baseline.txt`, so a
# header living only in that file would be deleted by the very command it
# documents — which is how it read until r1-12.
cat <<'HEADER'
# kcov line coverage, per file (alphabetical) then total.
# Generated — do not hand-edit. Refresh at the end of each plan program (or
# after any change that moves coverage materially):
#
#     zig build coverage && tools/coverage_summary.sh > coverage-baseline.txt
#
# A review aid, not a gate — nothing fails when it drifts, which is exactly
# why it needs a stated cadence. It had gone five weeks stale before r1-06,
# still reporting `src/lsp/wasm.zig 9.85%` for a file that had since grown 38
# dispatch tests.
HEADER

# Per-file, sorted alphabetically by repo-relative path.
jq -r '
    .files[]
    | select(.file | test("/src/"))
    | [.file, (.percent_covered | tonumber), (.covered_lines | tonumber), (.total_lines | tonumber)]
    | @tsv
' "$JSON" \
    | awk -F'\t' '{
        n = index($1, "/src/");
        rel = (n > 0) ? substr($1, n+1) : $1;
        printf "%s\t%.2f\t%d\t%d\n", rel, $2, $3, $4;
    }' \
    | sort \
    | awk -F'\t' '{
        printf "%6.2f%%  %5d/%-5d  %s\n", $2, $3, $4, $1;
    }'

# Aggregate.
read -r totalCov totalAll < <(jq -r '
    [.files[] | select(.file | test("/src/"))]
    | (map(.covered_lines | tonumber) | add // 0) as $cov
    | (map(.total_lines | tonumber) | add // 0) as $all
    | "\($cov) \($all)"
' "$JSON")

if [ "${totalAll:-0}" = "0" ]; then
    echo "tools/coverage_summary.sh: no /src/ files in $JSON" >&2
    exit 1
fi

awk -v c="$totalCov" -v t="$totalAll" 'BEGIN {
    printf "\n%6.2f%%  %5d/%-5d  TOTAL\n", c*100/t, c, t
}'
