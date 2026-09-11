#!/usr/bin/env bash
# Publish the three publishable npm packages (@sjon-lang/schema, @sjon-lang/web,
# @sjon-lang/highlight) to the public npm registry.
#
# Uses `pnpm publish`, not `npm publish`, on purpose: @sjon-lang/web depends on
# @sjon-lang/schema via `"workspace:*"` in its package.json. `npm publish` ships
# that literal string — an invalid version range for anyone installing
# outside this workspace. `pnpm publish` rewrites it to the dependency's
# current version (`1.2.0`) before packing, which is the only one of the
# two that produces an installable tarball. Verified by hand before this
# script existed: `npm pack` on hosts/web put `"@sjon-lang/schema": "workspace:*"`
# into the tarball's package.json; `pnpm pack` put `"1.2.0"`.
#
# Order matters for the same reason: @sjon-lang/schema publishes first so that
# by the time @sjon-lang/web goes out, the version its rewritten dependency
# names is actually resolvable on the registry.
#
# Each package's own package.json is the version truth here (kept in sync
# with src/version.zig by `zig build audit-format-versions`); this script
# only cross-checks the three agree with each other before publishing.
#
# Usage:
#   scripts/publish-npm.sh            dry-run every package (no registry writes)
#   scripts/publish-npm.sh --publish  publish for real (needs `npm login` first)
#   scripts/publish-npm.sh --help     show this help
#
# A package already present at its current version on the registry is
# skipped rather than re-attempted, so a re-run after a partial failure
# (e.g. @sjon-lang/web rejected after @sjon-lang/schema succeeded) only publishes
# what is still missing.

set -euo pipefail

usage() {
    awk 'NR>=2 && /^#/ {sub(/^# ?/, ""); print; next} NR>=2 {exit}' "$0"
}

PUBLISH=false
for arg in "$@"; do
    case "$arg" in
        --publish) PUBLISH=true ;;
        -h | --help) usage; exit 0 ;;
        *) echo "error: unknown argument '$arg' (try --help)" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Dependency order: @sjon-lang/schema before @sjon-lang/web (which depends on it).
# @sjon-lang/highlight has no workspace dependency; kept last, not for
# correctness, just to group it with the others already published.
PACKAGES=("hosts/schema" "hosts/web" "hosts/highlight")

# --- The cut is the working tree; refuse to publish over uncommitted work ---
if [ -n "$(git -C "$PROJECT_DIR" status --porcelain)" ]; then
    echo "error: working tree is dirty — a package's \`files\` list packs" >&2
    echo "       whatever is on disk, not what is committed. Commit or stash first." >&2
    exit 1
fi

# --- Every package must agree with src/version.zig, the semver truth ---
TRUTH="$(sed -n 's/^pub const string = "\(.*\)";$/\1/p' "$PROJECT_DIR/src/version.zig")"
if [ -z "$TRUTH" ]; then
    echo "error: no \`pub const string\` in src/version.zig" >&2
    exit 1
fi
for pkg in "${PACKAGES[@]}"; do
    v="$(node -p "require('$PROJECT_DIR/$pkg/package.json').version")"
    if [ "$v" != "$TRUTH" ]; then
        echo "error: $pkg/package.json is at $v, src/version.zig says $TRUTH" >&2
        echo "       run \`zig build audit-format-versions\` to see every stale copy" >&2
        exit 1
    fi
done
echo "==> Every package agrees on version $TRUTH"

# --- Auth: only checked before a real publish; a dry-run needs none ---
if $PUBLISH; then
    if ! npm whoami >/dev/null 2>&1; then
        echo "error: not logged in to the npm registry — run \`npm login\` first" >&2
        exit 1
    fi
    echo "==> Publishing as $(npm whoami)"
fi

for pkg in "${PACKAGES[@]}"; do
    name="$(node -p "require('$PROJECT_DIR/$pkg/package.json').name")"
    version="$(node -p "require('$PROJECT_DIR/$pkg/package.json').version")"

    if $PUBLISH && npm view "${name}@${version}" version >/dev/null 2>&1; then
        echo "==> ${name}@${version} is already on the registry; skipping"
        continue
    fi

    echo "==> $([ "$PUBLISH" = true ] && echo Publishing || echo "Dry-run for") ${name}@${version}"
    if $PUBLISH; then
        (cd "$PROJECT_DIR/$pkg" && pnpm publish --no-git-checks)
    else
        (cd "$PROJECT_DIR/$pkg" && pnpm publish --dry-run --no-git-checks)
    fi
done

if $PUBLISH; then
    echo "==> Done. https://www.npmjs.com/org/sjon-lang"
else
    echo "==> Dry-run complete. Re-run with --publish to publish for real."
fi
