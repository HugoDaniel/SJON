#!/usr/bin/env bash
# Publish the four publishable npm packages (@sjon-lang/schema,
# @sjon-lang/read, @sjon-lang/web, @sjon-lang/highlight) to the public npm
# registry.
#
# Uses `pnpm publish`, not `npm publish`, on purpose: @sjon-lang/web depends on
# @sjon-lang/schema and @sjon-lang/read via `"workspace:*"` in its
# package.json. `npm publish` ships that literal string — an invalid version
# range for anyone installing outside this workspace. `pnpm publish` rewrites
# it to the dependency's current version (`1.2.0`) before packing, which is the
# only one of the two that produces an installable tarball. Verified by hand
# before this script existed: `npm pack` on hosts/web put
# `"@sjon-lang/schema": "workspace:*"` into the tarball's package.json;
# `pnpm pack` put `"1.2.0"`.
#
# Order matters for the same reason: @sjon-lang/schema and @sjon-lang/read
# publish first so that by the time @sjon-lang/web goes out, the versions its
# rewritten dependencies name are actually resolvable on the registry.
#
# Each package compiles itself on the way out. `pnpm publish` (and the
# dry-run) runs the package's `prepack`, which builds dist/ as JavaScript plus
# declarations from its tsconfig.build.json, and `publishConfig` repoints the
# packed `main`, `types` and `exports` there. The workspace keeps importing the
# `.ts` sources. 1.4.1 shipped those sources and could not be imported at all,
# because Node refuses to strip types from a `.ts` file under node_modules.
#
# Each package's own package.json is the version truth here (kept in sync
# with src/version.zig by `zig build audit-format-versions`); this script
# only cross-checks the four agree with each other before publishing.
#
# Usage:
#   scripts/publish-npm.sh            dry-run every package (no registry writes)
#   scripts/publish-npm.sh --publish  publish for real (needs `npm login` first)
#   scripts/publish-npm.sh --help     show this help
#
# A package already present at its current version on the registry is
# skipped rather than re-attempted, so a re-run after a partial failure
# (e.g. @sjon-lang/web rejected after @sjon-lang/schema and @sjon-lang/read
# succeeded) only publishes what is still missing.

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

# Dependency order: @sjon-lang/schema and @sjon-lang/read before @sjon-lang/web
# (which depends on both). @sjon-lang/highlight has no workspace dependency;
# kept last, not for correctness, just to group it with the others already
# published.
PACKAGES=("hosts/schema" "hosts/read" "hosts/web" "hosts/highlight")

# Permanent package-contract check (P2 Task 8): @sjon-lang/read is a
# publishable package and @sjon-lang/web's packed manifest names it. Dropping
# it from the list must fail here, not ship a web tarball with an unresolvable
# dependency.
if [[ " ${PACKAGES[*]} " != *" hosts/read "* ]]; then
    echo "error: PACKAGES is missing hosts/read; @sjon-lang/web depends on it" >&2
    exit 1
fi

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

# --- The packed manifest must export what the workspace one does ---
# `exports` is what the workspace resolves (the `.ts` sources) and
# `publishConfig.exports` is what the registry serves (dist/). A subpath added
# to one and not the other passes every local test and is missing from the
# published package, so the two key sets must match before anything is packed.
for pkg in "${PACKAGES[@]}"; do
    if ! node -e '
        const p = require(process.argv[1]);
        const dev = Object.keys(p.exports ?? {}).sort().join(" ");
        const pub = Object.keys(p.publishConfig?.exports ?? {}).sort().join(" ");
        if (dev !== pub) {
            console.error(`  exports:               ${dev}\n  publishConfig.exports: ${pub}`);
            process.exit(1);
        }
    ' "$PROJECT_DIR/$pkg/package.json"; then
        echo "error: $pkg/package.json: exports and publishConfig.exports name different subpaths" >&2
        exit 1
    fi
done
echo "==> Every package publishes the subpaths it exports"

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
        # `--force` bypasses only pnpm's "this version is already on the
        # registry" guard. A dry run must still exercise every package's
        # `prepack` on a candidate whose version was published previously,
        # and `--dry-run` keeps every registry write off. A real publish keeps
        # the guard (apart from the explicit `npm view` skip above).
        (cd "$PROJECT_DIR/$pkg" && pnpm publish --dry-run --force --no-git-checks)
    fi
done

if $PUBLISH; then
    echo "==> Done. https://www.npmjs.com/org/sjon-lang"
else
    echo "==> Dry-run complete. Re-run with --publish to publish for real."
fi
