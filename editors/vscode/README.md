# SJON for VS Code

Syntax highlighting for `.sjon` plus the `sjon-lsp` language server —
diagnostics with quick fixes, hover, completion, signature help, inlay
hints, goto-definition, rename, and semantic tokens, all served by the
same engine the other editors and the playground use. This is a **local-install**
extension (build from source, run in a dev host or package a `.vsix`); it is
not on the Marketplace.

## Prerequisites

Build the language server once from the repo root:

```sh
zig build lsp        # → zig-out/bin/sjon-lsp (fetches the lsp_kit dep on first build)
```

Then either put `zig-out/bin/` on your `PATH`, or point the extension straight
at the binary with the **`sjon.lsp.path`** setting (absolute path). The
extension prefers the setting; with it empty it looks for `sjon-lsp` on `PATH`.
If neither resolves it shows an error instead of starting a broken client.

## Run it

Install workspace dependencies (from the repo root, once):

```sh
pnpm install
```

Then bundle the extension and launch it:

```sh
pnpm --filter sjon-vscode run bundle   # → dist/extension.cjs (esbuild)
```

- **Dev host:** open `editors/vscode/` in VS Code and press **F5** ("Run
  Extension"). A second window opens with the extension loaded; open any
  `.sjon` file — or a workspace containing a `sjon-lsp.sjon` or
  `sjon-project.sjon` — to see diagnostics, hover, completion, and
  goto-definition. `zig build lsp` with no `-Doptimize` is a Debug
  build, and Debug is the one to point
  the extension at: `initialize` validates the advertised capability set
  against the handlers behind it, so a mismatch stops the server there
  instead of surfacing as a dead feature.
- **Package a `.vsix`:** `pnpm dlx @vscode/vsce package` in `editors/vscode/`,
  then *Extensions: Install from VSIX…* in VS Code.

## Schema discovery

The language server, not the extension, decides which schema a file uses.
For each open or saved document it walks from the document's directory
toward the workspace folder, stops at the nearest `sjon-lsp.sjon` or
`sjon-project.sjon`, and uses a matching bundle when one exists. A
`sjon-project.sjon` in that same directory is the legacy fallback when no
bundle matches; nothing is inherited from a parent directory. The full
grammar, pattern, discovery, conflict, declaration, and saved-byte rules
are in
[docs/TOOLING.md](../../docs/TOOLING.md#editor-schema-bundles).

The extension does not parse either configuration file. Its own file-event
registration is `**/sjon-project.sjon`; when VS Code advertises dynamic
registration for watched files, the server additionally asks the client
for a broad `**/*.sjon` watcher. Dynamically changing the workspace folder
set is not supported by the server, so reload the window after adding or
removing a folder to initialize it with the new roots. The extension
restarts the server when `sjon.lsp.path` changes.

## Grammar (the drift gate)

`syntaxes/sjon.tmLanguage.json` is a **byte-identical copy** of the source of
truth in [`hosts/highlight`](../../hosts/highlight/) (scope `source.sjon`) —
VS Code needs the grammar file inside the extension. `test/manifest.test.ts`
fails if the copy drifts. When it does, re-copy and re-run the tests:

```sh
cp ../../hosts/highlight/src/sjon.tmLanguage.json syntaxes/sjon.tmLanguage.json
pnpm --filter sjon-vscode run test
```

## Gates

```sh
pnpm --filter sjon-vscode run typecheck   # tsc --noEmit (beyond-strict, per CLAUDE.md)
pnpm --filter sjon-vscode run test        # node:test — grammar drift, language config, server-path resolution
```

Both ride `zig build verify` (the workspace's `./editors/*` filter). Editor
setup for every other editor, the CLI, and the WASM embedding contract live in
[`docs/TOOLING.md`](../../docs/TOOLING.md).
