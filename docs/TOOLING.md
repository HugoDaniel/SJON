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

The native binary is the one an editor points at: every block under
[Per-editor setup](#per-editor-setup) launches `sjon-lsp` over stdio. The
WASM byte-pump is for hosts with no process to spawn — it is what the
playground on the site runs — and no editor talks to it.

`zig build lsp` with no `-Doptimize` builds in **Debug**, which is the mode
to point an editor at. `initialize` runs lsp-kit's own capability validator
over the set the server advertises, so a capability with no handler behind
it stops the server there instead of promising a client a method that
answers method-not-found. `-Doptimize=ReleaseSafe` builds a faster server
without that check. `zig build test` runs the same validator as a test
(`lsp-main`) whenever `lsp-kit` is fetched, so a mismatch is a red build
before it is anyone's dead editor.

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

Capabilities: diagnostics with code actions (closest-spelling fixes
for `unknown_form`, `unknown_key`, `unknown_local_form`, `not_member`,
`not_cross_ref` and `cross_ref_outside_scope`; `ambiguous_form`
qualification; `missing_required_key` stubs; `duplicate_key` removal;
`expr_kvpair_not_allowed`), hover, completion (form-head snippets, keys,
and values), signature help (per `ExprFunc.signatures` overload),
folding ranges, inlay hints, document symbols, formatting,
goto-definition, document highlight, selection ranges, workspace
symbols, find-references, prepare-rename, rename, semantic tokens
(`full` only — schema-resolved heads, keys, members, and cross-ref
names, which is the one axis the TextMate grammar in `hosts/highlight`
cannot see), and workspace diagnostics (native only
— the server walks `**/*.sjon` under the workspace root so errors in
files you never opened still reach the Problems panel; the WASM build
has no filesystem and reports open documents only; the walk skips
`sjon-project.sjon`, which is the resolver's config rather than a
document in any plugin's vocabulary, and real project errors reach
you on that file's own URI). Diagnostic codes are the bare snake_case
tags from `Ast.Diagnostic.Code` (stable across SJON versions per
[LANGUAGE.md §7.6](LANGUAGE.md)). Schema reloads on
`workspace/didChangeWatchedFiles` for project files and revalidates
all open documents.

Every schema-aware surface resolves a form the way the validator does,
against the **slot** it sits in and not the global catalog. Inside a
`:type form` key or a `:positional` slot that declares local forms,
head completion offers the slot's own forms first and shadows a
same-named global (the snippet inserts the local's keys), hover and
signature help describe the local's keys, key and value completion
offer them, semantic tokens colour them, inlay hints show the local's
defaults and label the head with the plugin that resolved it, and the
quick fixes draw their candidates from the slot, so the fix for `:rr`
inside a local `circle` is `:r` and not the global's `:radius`. A
closed head-set narrows head completion to its members whether or not
a global declaration stands behind each one. A `(variant …)` key is
live on every surface once the discriminant that selects it precedes
the cursor, and silent otherwise, which is the validator's
`unknown_key` rule; key completion likewise offers a variant's keys
only after that discriminant. A union-typed slot completes to every
alternative's values and narrows to one arm as soon as the typed text
has a shape only that arm accepts; a shape two arms reach keeps the
whole list. Digit-leading members (`2d`, `2d-array`) hover, colour and
quick-fix like any other member, the fix measured against the raw text
so `2dd` and `2.5d` both offer `2d`. The playground on the site drives
the same server and gains all of this except semantic tokens, which it
does not request (its highlighting is the CodeMirror grammar). Both
servers advertise inlay hints without a resolve step: the native one
spells it `resolveProvider: false`, the WASM dispatcher `true`, and
the two say the same thing to a client, since neither has a resolve
method.

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

## Spans and addresses without the server

An editor that decorates a document needs two things the server answers
awkwardly: the span of every node, and the §11.2 path of the node under a
byte. `textDocument/selectionRange` gives you the first as a chain of
ranges, but a range is not an address, and asking it per pointer move is a
JSON-RPC round trip per mouse event.

`sjon.wasm` answers both directly, in UTF-8 byte offsets, off the same
parse that validates the text. Neither export refuses a document that does
not parse: the revision in the middle of a keystroke is the one whose
addresses you want, and the diagnostics come back beside the answer.

**`sjon_node_table(src)`** — the bulk answer, one call per revision:

```json
{"nodes":[{"i":0,"parent":-1,"root":1,"seg":null,"kind":"form",
           "span":[105,157],"head_span":[106,111]},
          {"i":1,"parent":0,"root":1,"seg":"value","kind":"form",
           "span":[150,176],"head_span":[151,152],"key_span":[143,149]},
          {"i":2,"parent":1,"root":1,"seg":0,"kind":"number",
           "span":[153,156]}],
 "diagnostics":[]}
```

`seg` is the row's own §11.2 path step: a string for a keyword value, an
integer for a positional child or a vector element, `null` for a root. A
row's full path is the chain of `seg` up the `parent` links, so it is
§11.2 by construction rather than by your reading of an encoding. `parent`
is `-1` on a root, and `head_span` / `key_span` appear only on the rows
that have one.

A `:key value` pair gets no row. §11.2 addresses a pair's *value*, so the
pair has no address of its own, and its key span rides on the value's row.

Rows are pre-order — a parent always precedes its children, siblings are
in source order — so the innermost node containing a byte is the **last**
row whose span contains it. That makes hit-testing a scan on your side,
with no call back in per pointer move. `@sjon/web` ships that scan as
`rowContaining(table, start, end?)` and the path walk as
`pathOfRow(table, row)`.

**`sjon_address_of_span(src, start, end)`** — the point answer, for a host
holding a span and not a table:

```json
{"root":1,"path":["value",0],"span":[153,156],"kind":"number"}
```

or the literal `null` when the range is inside no root. Pass `start ===
end` for a caret. `root` and `path` are an edit action's two fields
verbatim, so the answer goes straight back to `sjon edit` or
`sjon_apply_edits`.

A range covering a whole `:key value` pair answers the **enclosing form**,
because §11.2 addresses a pair's value and an edit over the pair itself is
a `set_keyword` on the form.

Both are wrapped on `@sjon/web`'s `SjonEncoder` (`nodeTable`,
`addressOfSpan`) and on the Rust host (`SjonHost::node_table`,
`SjonHost::address_of_span`). Offsets are UTF-8 bytes in every case: a
document past ASCII counts differently in UTF-16, so convert at your
editor's boundary, not before.

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
| `edit` | `sjon edit doc.sjon '{"op":"replace","path":["w"],"value":801}'` — apply structural edit actions (LANGUAGE.md §11), inside a root or over the root list; only the edited spans change |
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

### Changing a document from a script

`sjon edit` applies the structural edit actions of LANGUAGE.md §11 — the same
vocabulary an editor and the web hosts write in — and prints the result. It
changes only the bytes of the spans the actions name, so a one-literal edit is
a one-literal diff:

```console
$ cat scene.sjon
(scene
  :w   800   ; width
  :h   600)

$ sjon edit scene.sjon '{"op":"replace","path":["w"],"value":801}'
(scene
  :w   801   ; width
  :h   600)
```

Two of the eight actions add and remove a whole root, so a script can grow a
document as well as change one. They take `index` and no `path`, and an
omitted `index` appends:

```console
$ sjon edit scene.sjon '{"op":"insert_root","value":{"$form":"camera","fov":60}}'
(scene
  :w   800   ; width
  :h   600)
(camera :fov 60)
```

The separator is the document's own. A file that already puts a blank line
between its roots keeps it, because the run between the last two roots is what
gets copied:

```console
$ cat two.sjon
(scene :w 800)

(camera :fov 60)

$ sjon edit two.sjon '{"op":"insert_root","value":{"$form":"light","dir":[0,1,0]}}'
(scene :w 800)

(camera :fov 60)

(light :dir [0 1 0])
```

Only a one-root file has no such run, and there the separator is one newline.

Each `ACTION` argument is one JSON action or a JSON array of them, and they
all form one batch applied left to right. `--actions=PATH` reads the batch
from a file (`-` for stdin, when the document is not), and `--in-place`
writes the result back instead of printing it.

Layout is preserved and there is no flag to re-print: `sjon edit … | sjon fmt -`
is the refold, one verb per job. Like `fmt`, `edit` is purely syntactic — it
resolves no project and validates nothing, so `sjon edit … && sjon check …`
is the pair — and it refuses a document it cannot parse rather than writing
back the parser's recovery. A failing action names itself:

```console
$ sjon edit scene.sjon '{"op":"replace","path":["nope"],"value":1}'
sjon edit: PathNotFound (action 0)
```

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
