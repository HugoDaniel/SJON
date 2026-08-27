#!/usr/bin/env bash
# Mirror SJON to its public release repos as a clean cut of the committed tree.
#
# The cut is `git archive HEAD`: every tracked file — sources with their
# comments, every test, the conformance corpus, the examples, the docs —
# minus the dev-only set marked `export-ignore` in .gitattributes (agent
# instruction files, git hooks, docs/plans, docs/notes, docs/ROADMAP.md).
# What ships must hold on its own: a link check walks every shipped
# Markdown file's relative links and fails the cut on any that point
# outside it.
#
# The mirror is built in a git worktree on an orphan `release` branch located
# OUTSIDE this repo (default ../sjon-release), committed as one snapshot per
# release titled "SJON <version>" (version read from src/version.zig, the
# semver truth every manifest follows), and tagged v<version>.
#
# Usage:
#   scripts/mirror.sh           prepare + commit + tag the cut locally (no push)
#   scripts/mirror.sh --push    also push branch + tag to both public remotes:
#                                 release -> git.hugodaniel.com/releases/sjon (main)
#                                 github  -> github.com/HugoDaniel/SJON (main)
#   scripts/mirror.sh --help    show this help
#
# Env overrides:
#   SJON_RELEASE_WORKTREE   worktree path  (default ../sjon-release)
#   SJON_RELEASE_REMOTE     releases URL   (default https://git.hugodaniel.com/releases/sjon.git)
#   SJON_GITHUB_REMOTE      GitHub URL     (default git@github.com:HugoDaniel/SJON.git)

set -euo pipefail

usage() {
    # Print the leading comment block (lines after the shebang), minus the '# '.
    awk 'NR>=2 && /^#/ {sub(/^# ?/, ""); print; next} NR>=2 {exit}' "$0"
}

# --- Args ---
PUSH=false
for arg in "$@"; do
    case "$arg" in
        --push) PUSH=true ;;
        -h | --help) usage; exit 0 ;;
        *) echo "error: unknown argument '$arg' (try --help)" >&2; exit 1 ;;
    esac
done

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PARENT_DIR="$(cd "$PROJECT_DIR/.." && pwd)"
WORKTREE="${SJON_RELEASE_WORKTREE:-$PARENT_DIR/sjon-release}"
RELEASES_URL="${SJON_RELEASE_REMOTE:-https://git.hugodaniel.com/releases/sjon.git}"
GITHUB_URL="${SJON_GITHUB_REMOTE:-git@github.com:HugoDaniel/SJON.git}"
LOCAL_BRANCH="release"
REMOTE_BRANCH="main"

# --- The cut is the committed tree; refuse to mirror over uncommitted work ---
if [ -n "$(git -C "$PROJECT_DIR" status --porcelain)" ]; then
    echo "error: working tree is dirty — the cut is \`git archive HEAD\`," >&2
    echo "       so commit (or stash) first to make the release reproducible." >&2
    exit 1
fi

# --- Version: read the one semver truth ---
VERSION="$(sed -n 's/^pub const string = "\(.*\)";$/\1/p' "$PROJECT_DIR/src/version.zig")"
if [ -z "$VERSION" ]; then
    echo "error: no \`pub const string\` in src/version.zig" >&2
    exit 1
fi

# --- Ensure both public remotes ---
ensure_remote() {
    local name="$1" url="$2"
    if ! git -C "$PROJECT_DIR" remote get-url "$name" >/dev/null 2>&1; then
        echo "==> Adding remote '$name' -> $url"
        git -C "$PROJECT_DIR" remote add "$name" "$url"
    fi
}
ensure_remote release "$RELEASES_URL"
ensure_remote github "$GITHUB_URL"

# --- Ensure the worktree on an orphan `release` branch ---
if [ ! -e "$WORKTREE/.git" ]; then
    if git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$LOCAL_BRANCH"; then
        echo "==> Attaching worktree at $WORKTREE to existing branch '$LOCAL_BRANCH'"
        git -C "$PROJECT_DIR" worktree add "$WORKTREE" "$LOCAL_BRANCH"
    else
        echo "==> Creating worktree at $WORKTREE on new orphan branch '$LOCAL_BRANCH'"
        git -C "$PROJECT_DIR" worktree add --orphan -b "$LOCAL_BRANCH" "$WORKTREE"
    fi
fi

# --- Clean the worktree to a slate (keep only the .git linkfile) ---
# Start fresh each run so the mirror is a deterministic reflection of the
# archive: a file that left the tree (or became export-ignored) must not
# linger from a prior run.
if [ ! -e "$WORKTREE/.git" ]; then
    echo "error: $WORKTREE is not a git worktree; refusing to clean it" >&2
    exit 1
fi
find "$WORKTREE" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +

# --- Populate: the committed tree minus the export-ignore set ---
echo "==> Extracting \`git archive HEAD\` (SJON ${VERSION}) into $WORKTREE"
git -C "$PROJECT_DIR" archive HEAD | tar -x -C "$WORKTREE"

# --- Link check: every shipped Markdown link must resolve inside the cut ---
# One deliberate exclusion: root-absolute targets (`/playground#…`) address the
# deployed site, not the file tree.
#
# There used to be a second, for landing-page/src/content/, when that tree was
# fifteen generated `content.md` files whose sources in docs/tutorial/ were
# checked here anyway. The Starlight rebuild retired the generator; what lives
# there now is three hand-written `.mdx` pages, which this check should see
# rather than skip the day one of them becomes a `.md`.
echo "==> Checking Markdown links in the cut"
broken=0
while IFS= read -r -d '' md; do
    dir="$(dirname "$md")"
    while IFS= read -r target; do
        case "$target" in
            http://* | https://* | mailto:* | '#'* | /*) continue ;;
        esac
        path="${target%%#*}" # drop in-page anchors
        path="${path%% *}"   # drop optional link titles
        [ -n "$path" ] || continue
        if [ ! -e "$dir/$path" ]; then
            echo "    broken: ${md#"$WORKTREE"/} -> $target" >&2
            broken=$((broken + 1))
        fi
    done < <(grep -oE '\]\([^)]+\)' "$md" 2>/dev/null | sed 's/^](//; s/)$//')
done < <(find "$WORKTREE" -name '*.md' -type f -print0)
if [ "$broken" -ne 0 ]; then
    echo "error: $broken broken Markdown link(s) — the cut must hold on its own" >&2
    exit 1
fi

cd "$WORKTREE"

# --- Commit ---
git add -A
if git diff --cached --quiet; then
    echo "==> No changes to mirror; nothing to commit."
else
    # Release-style message: a versioned title plus one description paragraph
    # of what SJON is. Signing off: snapshots are automated and may run
    # headless.
    git -c commit.gpgsign=false commit -q \
        -m "SJON ${VERSION}" \
        -m "SJON is a schema-constrained data language for domain tools and the agents that operate them: deterministic S-expression data plus a pure, bounded expression layer, one front-end, a stable binary wire format, append-only diagnostic codes, and parity hosts in Zig, Node, Rust, and TypeScript."
    echo "==> Committed release snapshot (SJON ${VERSION})"
fi

# --- Tag the snapshot (immutable; a new release bumps src/version.zig) ---
if git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null; then
    echo "==> Tag v${VERSION} already exists; leaving it as is."
else
    git -c tag.gpgSign=false tag -a "v${VERSION}" -m "SJON ${VERSION}"
    echo "==> Tagged v${VERSION}"
fi

# --- Push (opt-in) ---
if $PUSH; then
    for remote in release github; do
        echo "==> Pushing '$LOCAL_BRANCH' + v${VERSION} -> $remote/$REMOTE_BRANCH"
        git push -u "$remote" "${LOCAL_BRANCH}:${REMOTE_BRANCH}"
        git push "$remote" "v${VERSION}"
    done
    echo "==> Pushed. https://git.hugodaniel.com/releases/sjon and https://github.com/HugoDaniel/SJON"
else
    echo "==> Local mirror ready at $WORKTREE (branch '$LOCAL_BRANCH', tag v${VERSION})."
    echo "    Inspect it, then re-run with --push to publish to both remotes."
fi
