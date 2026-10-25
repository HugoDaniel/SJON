# Releasing SJON

Use Zig 0.16.x throughout, including commands started by package scripts.
On machines whose `BASH_ENV` changes PATH, set `BASH_ENV=/dev/null` and prepend
the installed 0.16 toolchain directory for the invocation. Do not change the
global Zig selection to run a release.

The semantic version in `src/version.zig` is shared by every package.
`zig build audit-format-versions` identifies synchronized manifests. A semantic
release does not by itself change binary wire v5 or diagnostic-code ordering.

## Check the committed candidate

```sh
zig build verify --summary all
zig build landing-page-assets
pnpm --filter landing-page run build
mkdir -p /tmp/sjon-packages
pnpm --dir hosts/schema pack --pack-destination /tmp/sjon-packages
pnpm --dir hosts/web pack --pack-destination /tmp/sjon-packages
pnpm --dir hosts/highlight pack --pack-destination /tmp/sjon-packages
scripts/check-packed-packages.sh /tmp/sjon-packages "$PWD/zig-out/bin"
```

Use an empty tarball directory for each version. `pnpm pack` is required:
`npm pack` leaves the web package's `workspace:*` dependency unresolved.
The checker installs tarballs into a disposable project outside the workspace,
imports all public subpaths in plain Node, exercises schema construction,
WASM validation/evaluation/editing, CodeMirror and Shiki, and checks a strict
NodeNext TypeScript consumer with `skipLibCheck: false`. The consumer includes
`esnext.disposable` because the host exposes `Symbol.asyncDispose`.
It checks Node 20.0 for web/schema and 20.10 for highlight, whose JSON import
attributes are unavailable in 20.0. It prints tarball versions and SHA-256s.
The web npm package does not bundle WASM: distribute matching `zig-out/bin`
artifacts with the source release or build them from that source.

Before publishing, serve `landing-page/dist` at `/pages/sjon` with `.wasm`
served as `application/octet-stream`. Check actual playground values, format,
share-link round-trips including schemas, light/dark/auto themes, search from
inside the editor, all lesson/error routes, the editing route, `llms.txt`,
404 handling, and the visible failure banner with LSP WASM unavailable.
Static route success and a local Astro preview do not replace these checks.

## Rust crate

The Rust host is published as `sjon-host` on crates.io. Its manifest restricts
publication to that registry and includes library sources, README, and the
build script. Repository integration tests, corpus data, and WASM artifacts
are excluded. The packaged build skips corpus-driven test generation; the
source checkout still enforces corpus/classifier checks.

```sh
cargo package --manifest-path hosts/rust/Cargo.toml --list
cargo publish --manifest-path hosts/rust/Cargo.toml --dry-run
cargo login
cargo publish --manifest-path hosts/rust/Cargo.toml
```

Create a crates.io account, verify its email address, and enter a publishing
API token at the `cargo login` prompt. Verify the uploaded version with
`cargo info sjon-host@1.5.0`, then build a fresh registry consumer. The crate
requires Rust 1.92 and a matching external `sjon.wasm`; it does not require
Zig when using a prebuilt artifact. Instructions are in the
[Rust README](../hosts/rust/README.md).

## Prepare and publish

From a clean committed candidate:

```sh
scripts/publish-npm.sh          # pack/publish dry run, no registry writes
scripts/mirror.sh               # local public snapshot and immutable v<version>
```

Inspect the public snapshot and build it in an isolated checkout. The mirror
checks both Markdown and MDX file links; development-only plans are omitted,
so consumer instructions must live in shipped docs. Prepare a GitHub Release
body from the version's changelog entry and attach matching WASM/binary
artifacts with SHA-256 checksums. Do not retarget an existing release tag.

After candidate acceptance, source and npm publication use:

```sh
scripts/mirror.sh --push
scripts/publish-npm.sh --publish
```

Source push, npm publication, GitHub Release creation, and website deployment
are separate operations. The mirror does not create a GitHub Release or deploy
the site. Obtain the website's actual deployment procedure before recording
that channel as released. Verify each published npm version independently,
install from the registry in a fresh project, and repeat consumer checks.
Check both source remotes and the live site, retaining candidate identities,
artifact checksums, URLs, and command results. A local tarball pass is not
proof of a registry installation.
