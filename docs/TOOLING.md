# SJON editor & tooling guide

This is the hub for wiring SJON into an editor and driving it from the
command line. **Embedding the engine in your own program** is a different
job — start at [INTEGRATION.md](INTEGRATION.md).

Two things live here:

- **The language server** (`sjon-lsp`) — diagnostics, hover, completion,
  goto-definition, formatting, and the rest, over LSP 3.17. One
  transport-neutral handler (`src/lsp/Handler.zig`) ships in two shapes: a
  native stdio binary for desktop editors, and a WASM byte-pump for browsers.
- **The CLI** (`sjon`) — `check`, `validate`, `fmt`, `explain`, schema export,
  and the plugin/project subtools.

Syntax highlighting is separate from the server: the reusable CodeMirror and
TextMate grammars live in [`hosts/highlight`](../hosts/highlight/README.md).
The server adds the schema-aware layer a grammar can't see (resolved form
heads, keys, cross-ref names) via semantic tokens.

## Building the servers

The servers aren't prebuilt — build them from source with a Zig 0.16
toolchain. Both land in `zig-out/bin/`.

| Command | Builds | Output |
|---|---|---|
| `zig build lsp` | native stdio server | `zig-out/bin/sjon-lsp` |
| `zig build wasm-lsp` | browser byte-pump | `zig-out/bin/sjon-lsp.wasm` |
| `zig build lsp-all` | both of the above | both |

The native build depends on `lsp-kit`, a **lazy** dependency — the first
`zig build lsp` fetches it (network required once), later builds are offline.
The WASM build has no such dependency.

Put `zig-out/bin` on your `PATH`, or reference the absolute path to
`sjon-lsp` in your editor config below. The server takes no arguments; it
speaks LSP over stdio.

`sjon-lsp` loads its schema from a workspace's `sjon-project.sjon` (a
manifest of plugin manifests). The handler in `src/lsp/Handler.zig` is
transport-neutral SJON logic; `main.zig` provides stdio + `lsp-kit`
JSON-RPC and `wasm.zig` exposes a hand-rolled JSON-RPC dispatcher for
browser hosts.

Capabilities: diagnostics (with code actions for `ambiguous_form` /
`missing_required_key` / `expr_kvpair_not_allowed`), hover, completion
(form-head snippet completion + key completion), signature help (per
`ExprFunc.signatures` overload), folding ranges, inlay hints, document
symbols, formatting, goto-definition, document highlight, selection
ranges, workspace symbols, find-references, prepare-rename, rename,
semantic tokens (`full` only — schema-resolved heads, keys, members,
and cross-ref names, which is the one axis the TextMate grammar in
`hosts/highlight` cannot see), and workspace diagnostics (native only
— the server walks `**/*.sjon` under the workspace root so errors in
files you never opened still reach the Problems panel; the WASM build
has no filesystem and reports open documents only). Diagnostic codes
are the bare snake_case tags from `Ast.Diagnostic.Code` (stable across
SJON versions per [LANGUAGE.md §7.6](LANGUAGE.md)). Schema reloads on
`workspace/didChangeWatchedFiles` for project files and revalidates
all open documents.

## Per-editor setup

Every block below assumes `sjon-lsp` is on your `PATH`. The server:

- attaches to `*.sjon` files,
- treats `;` as the line-comment token,
- discovers its schema from the nearest `sjon-project.sjon` at or above the
  edited file (a manifest of plugin manifests), and reloads it when that file
  changes.

No `sjon-project.sjon` means no plugin vocabulary: every form head reports
`unknown_form`. That is correct — a bare document declares nothing. Add a
project file (or an inline `(plugin …)` / `(use-plugin …)`) to give the
validator a vocabulary.

### Neovim (0.11+)

```lua
-- init.lua
vim.filetype.add({ extension = { sjon = "sjon" } })

vim.lsp.config("sjon", {
  cmd = { "sjon-lsp" },
  filetypes = { "sjon" },
  root_markers = { "sjon-project.sjon", ".git" },
})

vim.lsp.enable("sjon")
```

### Helix

`~/.config/helix/languages.toml`:

```toml
[language-server.sjon-lsp]
command = "sjon-lsp"

[[language]]
name = "sjon"
scope = "source.sjon"
file-types = ["sjon"]
comment-tokens = [";"]
language-servers = ["sjon-lsp"]
roots = ["sjon-project.sjon"]
```

Helix prints a `no highlight configuration` warning without a tree-sitter
grammar (SJON ships none yet); the language server still attaches and
diagnostics, hover, and completion work.

### Emacs (eglot)

eglot ships with Emacs 29+. A one-line derived mode gives it something to
attach to:

```elisp
(define-derived-mode sjon-mode prog-mode "SJON"
  "Major mode for editing SJON documents."
  (setq-local comment-start "; "))

(add-to-list 'auto-mode-alist '("\\.sjon\\'" . sjon-mode))

(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs '(sjon-mode . ("sjon-lsp"))))

(add-hook 'sjon-mode-hook #'eglot-ensure)
```

### Sublime Text (LSP package)

Sublime routes a server by *scope*, so it needs both an LSP client entry and
a minimal syntax that maps `.sjon` to `source.sjon`.

`Packages/User/SJON.sublime-syntax`:

```yaml
%YAML 1.2
---
name: SJON
file_extensions: [sjon]
scope: source.sjon
contexts:
  main:
    - match: ';.*$'
      scope: comment.line.semicolon.sjon
```

LSP settings (Preferences → Package Settings → LSP → Settings):

```jsonc
{
  "clients": {
    "sjon": {
      "enabled": true,
      "command": ["sjon-lsp"],
      "selector": "source.sjon"
    }
  }
}
```

For full TextMate highlighting instead of the two-line stub, convert the
grammar in [`hosts/highlight`](../hosts/highlight/README.md) to a
`.sublime-syntax` — the scope names already match.

### VS Code

VS Code has no settings-only path to a new stdio server; it needs an
extension to register the language client. A minimal local-install extension
lives in [`editors/vscode/`](../editors/vscode/) (added in the next
checkpoint of this plan) — build the server, set `sjon.lsp.path`, then `F5`
or `vsce package`.

### Zed

Zed binds a language server through an *extension* backed by a tree-sitter
grammar; there is no settings-only path, and SJON ships no tree-sitter
grammar. Zed is therefore not a paste-in target — an extension would need to
carry its own grammar. The server itself is editor-neutral, so nothing in
`sjon-lsp` blocks one. See Zed's
[Language Extensions](https://zed.dev/docs/extensions/languages) docs.

## Embedding the server in a browser (WASM byte-pump)

`sjon-lsp.wasm` speaks the same LSP JSON-RPC as the native binary, but over a
hand-rolled byte pump instead of stdio — the freestanding WASM target has no
stdio. The JS host writes a request into WASM memory, calls `sjon_lsp_send`,
then drains responses with `sjon_lsp_recv`:

```js
// Send one JSON-RPC message.
const encoded = new TextEncoder().encode(json);
const ptr = w.sjon_lsp_alloc(encoded.length);
new Uint8Array(w.memory.buffer, ptr, encoded.length).set(encoded);
w.sjon_lsp_send(ptr, encoded.length);
w.sjon_lsp_dealloc(ptr, encoded.length);

// Drain every queued response.
for (;;) {
  const rptr = w.sjon_lsp_recv();
  if (!rptr) break;
  const len = new DataView(w.memory.buffer).getUint32(rptr, true);
  const msg = new TextDecoder().decode(
    new Uint8Array(w.memory.buffer, rptr + 4, len),
  );
  w.sjon_lsp_dealloc(rptr, len + 4);
  // …dispatch msg…
}
```

The authoritative contract is the header of
[`src/lsp/wasm.zig`](../src/lsp/wasm.zig); the playground's
[`lsp-worker.ts`](../landing-page/src/playground/lsp-worker.ts) is the
reference client that drives it in production.

## The CLI

`zig build` installs `sjon` to `zig-out/bin/`. Every verb reads SJON, writes
to stdout, and puts diagnostics on stderr so stdout stays a clean data
channel. `sjon --help` is the authoritative list; the common verbs:

| Verb | One-line example |
|---|---|
| `check` (default) | `sjon *.sjon` — check documents or the current project; `--watch` re-runs on change (editing a manifest re-checks every document in the project) |
| `validate` | `sjon validate doc.sjon` (or `-` for stdin) |
| `eval` | `sjon eval doc.sjon` — print each expression root's value (`--format=json` for the corpus value grammar) |
| `query` | `sjon query pat.sjon --begin=0 --end=720720 --seed=0` — pattern window to `(haps …)` |
| `effective` | `sjon effective doc.sjon` — the document with omitted defaults spliced in; `diff <(sjon effective a) <(sjon effective b)` compares what documents mean |
| `share` | `sjon share broken.sjon \| pbcopy` — a playground deep link for a repro (schemas as extra args become tabs) |
| `fmt` | `sjon fmt src/*.sjon` — reformat in place, preserving comments |
| `explain` | `sjon explain unknown_form` (or `--list`) |
| `repl` | `sjon repl` — interactive loop: expressions print values, forms validate; `:schema`, `:explain`, `:query` inside |
| `export-schema` | `sjon export-schema doc.sjon` — JSON Schema / TypeScript / Markdown reference pages (`--target=markdown`) |
| `export-lowering-graph` | `sjon export-lowering-graph doc.sjon` |
| `plugin` | `sjon plugin info plugin.sjon` (`hash`/`check`/`list`/`init`/`test` — `test` runs `tests/<case>.sjon` against `<case>.expected.sjon` in the corpus expectation format) |
| `project` | `sjon project verify` (`info`/`lock`/`sync`) |
| `completions` | `sjon completions fish` — a completion script to stdout |

`fmt` is comment-preserving and idempotent — it collapses whitespace to the
canonical shape without touching structure:

```console
$ printf '(scene  :w   800 :h 600)\n' | sjon fmt -
(scene :w 800 :h 600)
```

Number *spellings* are normalized to one decimal form, because the printer
formats from the decoded value and never sees the source: `1_000` and `1e3`
both come back as `1000`, and `0xFF` as `255` (LANGUAGE.md §4.2). Values
round-trip; spellings do not. If you keep hex masks in a formatted file, the
comment beside them is what survives.

### From a bare code to an explanation

Diagnostics carry a stable snake_case code (the same one your editor shows in
the Problems panel). `sjon explain` turns any code into prose:

```console
$ printf '(scene :w 800)\n' | sjon validate -
<stdin>:1:2: error: unknown_form: unknown form `scene`
  at scene (phase: validation)
1 error

$ sjon explain unknown_form
unknown_form
  A form's head name is not declared by any loaded plugin.

Forms must be declared by some plugin reachable from the document
(either inlined as a `(plugin …)` declaration, or imported via
`(use-plugin …)`). Qualified spellings (`<plugin>/<form>`) bypass
ambiguity when two plugins declare the same name.
...

https://hugodaniel.com/pages/sjon/errors/unknown_form
```

The same URL closes each diagnostic in `--format=rich` output as a
`help:` footer (rich is the default on a terminal).

`sjon explain --list` prints the whole catalogue (code + one-line summary).
The codes are wire-stable across SJON versions — see
[LANGUAGE.md §7.6](LANGUAGE.md).

### CI annotations (GitHub Actions)

`--format=github` (valid on `check` and `validate`) turns each diagnostic
into a workflow command, so errors and warnings land inline on the PR diff:

```yaml
- run: sjon check --format=github
```

Annotations are the only stdout product in this mode (`check` moves its
phase/summary prose to stderr); exit codes are unchanged, so the job still
fails on errors. For machine consumers that want structure instead of
annotations, `--format=json` diagnostics carry `docs` (the catalogue URL)
and, where the suggestion machinery fires, `hints` with a ready-to-apply
`replacement` string.

### Shell completions

`sjon completions <bash|zsh|fish>` prints a completion script to stdout; each
script's header documents where to install it. For fish:

```console
$ sjon completions fish > ~/.config/fish/completions/sjon.fish
```
