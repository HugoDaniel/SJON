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
