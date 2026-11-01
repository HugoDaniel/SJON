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

The native build depends on `lsp-kit`, which `build.zig.zon` pins by url and
hash. The first `zig build` on a machine downloads it, whatever step was
asked for (network required once), and unpacks it into `zig-pkg/`. Later
builds are offline. The WASM server does not link it.

Put `zig-out/bin` on your `PATH`, or reference the absolute path to
`sjon-lsp` in your editor config below. The server takes no arguments; it
speaks LSP over stdio.

Diagnostic delivery is selected once per connection at `initialize`: a
client that advertises `textDocument.diagnostic` is served by pull, and
every other client falls back to push. Replacing
`zig-out/bin/sjon-lsp` does not change a running editor — restart it to
pick up the new binary. Restarting is also the guaranteed fallback
whenever a schema reload does not reach the server.

`sjon-lsp` discovers each document's schema from the nearest
`sjon-lsp.sjon` editor bundle configuration or, when no editor bundle
applies, the nearest `sjon-project.sjon` project (a manifest of plugin
manifests). The rules are in [Editor schema bundles](#editor-schema-bundles)
below. The handler in `src/lsp/Handler.zig` is transport-neutral SJON
logic; `main.zig` provides stdio + `lsp-kit` JSON-RPC and `wasm.zig`
exposes a hand-rolled JSON-RPC dispatcher for browser hosts.

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
has no filesystem and reports open documents only; the walk skips both
marker files, `sjon-lsp.sjon` and `sjon-project.sjon`, and treats
configuration, project, and bundle sources as source reports rather
than ordinary documents, so their errors reach you on their own URI).
Diagnostic codes are the bare snake_case
tags from `Ast.Diagnostic.Code` (stable across SJON versions per
[LANGUAGE.md §7.6](LANGUAGE.md)).

Diagnostics are delivered by pull or push according to the connection's
`initialize` capabilities. Advertising `textDocument.diagnostic`
selects pull, even when that object is empty or sets
`dynamicRegistration: false`; every other client falls back to push.
The mode is fixed for the life of the connection, and the pull methods
stay answerable in either mode.

A push client receives `textDocument/publishDiagnostics` after every
successful open, change, close, and schema reload. Each notification
is the complete current set for one URI, never a delta, so an empty
`diagnostics` array clears an earlier report; closing sends that empty
clear under the last validated version. `version` appears only when
the client advertises
`textDocument.publishDiagnostics.versionSupport`, and it is the
version that was actually validated. `relatedInformation`, deprecated
`tags`, and `codeDescription` are emitted only when the capability
object for the active mode announces them. Ranges use the position
encoding negotiated at `initialize`; omitting
`general.positionEncodings` means UTF-16, the LSP default. UTF-8 and
UTF-16 clients get the same diagnostics reported in their own units,
including CRLF documents.

Pull clients ask for `textDocument/diagnostic` (or
`workspace/diagnostic`) themselves and receive no unsolicited push.
After a successful schema reload, a pull client that advertises
`workspace.diagnostics.refreshSupport` gets one
`workspace/diagnostic/refresh`; a pull client without it gets the new
state on its next pull, because the result ID includes the schema
generation and changes with it. A push client never receives a
refresh request, regardless of that workspace capability.

For a legacy project, schema reloads run on
`workspace/didChangeWatchedFiles` and revalidate all open documents.
Push then covers every open document plus the project source, in
complete per-URI sets, and does not scan for unopened files. The
project source is reported directly at its own URI, including an empty
recovery report; a failed load also appends an `unspecified` error at
0:0 to open documents saying workspace schema loading failed, so the
failure is visible without opening `sjon-project.sjon`. Pull routes
treat the same project report as a direct document:
`textDocument/diagnostic` on the project URI returns it, and
`workspace/diagnostic` includes it once with `version` and result ID
null. A configured `sjon-lsp.sjon` connection treats a saved marker or
known source as a transactional reload and publishes the union of old
and new affected URIs; unaffected contexts keep their generation and
result ID. See
[Saved bytes, open buffers, and watchers](#saved-bytes-open-buffers-and-watchers).
The server asks the client to register a watcher for `.sjon` files only
when `workspace.didChangeWatchedFiles.dynamicRegistration` is true; a
rejected registration is ignored and is not retried. No report is
published after `shutdown`.

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

## Editor schema bundles

A native editor can give each document its own schema through a
versioned `sjon-lsp.sjon` file. The file names one or more bundles; each
bundle associates file patterns with an ordered list of plugin
manifests. A matched bundle becomes that document's complete schema, and
a document with its own plugin declarations gets an isolated effective
schema on top of it. The native server reads this file. The WASM server
keeps its one supplied schema and never discovers a `sjon-lsp.sjon`.

[`examples/editor-bundles/`](../examples/editor-bundles/README.md) is a
worked two-bundle workspace with valid and deliberately invalid documents.

### Configuration grammar

```sjon
(sjon-lsp :version 1
  :bundles [
    (bundle :name local-label
      :files ["**/document.sjon"]
      :manifests ["schemas/first.sjon"
                  "schemas/second.sjon"])])
```

- The file contains exactly one unqualified `(sjon-lsp …)` root and no
  positional root children.
- `:version` is required, must be an exact integer node, and must be `1`.
- `:bundles` is required and must be a vector. It may be empty; only
  `:files` and `:manifests` must be nonempty.
- Each bundle is an unqualified `(bundle …)` form with no positional
  children. `:name` is a symbol, unique within the file. It is an editor
  label, not a resolver plugin name.
- `:files` and `:manifests` are nonempty vectors of strings.
- Duplicate keys, unknown fields, missing required fields, wrong types,
  duplicate bundle names, malformed paths or patterns, and repeated
  normalized source paths reject the configuration.
- Parser errors are retained and stop the typed walk; a recovered tree is
  never treated as a valid configuration. Reader diagnostics are
  deterministic in source order. Duplicate-key and duplicate-source
  diagnostics point at the later occurrence and relate it to the first.

Only version 1 exists. There is no inheritance, remote registry, glob
expansion, or manifest dependency solving.

### File patterns and manifest paths

A `:files` pattern is matched case-sensitively against the document's
`/`-normalized path relative to the configuration directory. A literal
segment matches itself, `*` matches within one segment, and a whole `**`
segment matches zero or more segments. `**/program.sjon` therefore
matches both `program.sjon` and `nested/program.sjon`. Patterns may not
be empty or absolute, contain an empty segment, `..`, a backslash, `?`,
braces, character classes, an embedded `**`, or exceed
`Glob.MAX_PATTERN_LEN`. Multiple matching patterns in one bundle still
count that bundle once; matching two different bundles is a conflict.

A `:manifests` path is resolved relative to the configuration directory.
Absolute paths and `..` are allowed, and normalization is lexical; reads
follow symlinks, but normalization does not merge path aliases or
redirect discovery to a physical parent. Empty paths, NUL bytes,
URL-shaped strings, backslashes, and glob metacharacters are rejected.
Environment-looking bytes such as `$HOME` are literal and are not
expanded. A repeated normalized path is rejected within one bundle; the
same path in different bundles is allowed. Manifest URLs are never
fetched, manifest globs are never expanded, sidecars are not discovered,
and distinct files are never deduplicated by contents or plugin name.

Sources load in declaration order. Two manifests that declare the same
plugin name are both kept, and both contribute their own forms; order is
the order written in `:manifests`, not hash-map order. Core is prepended
exactly once. A bundle is `ready` only when every required source was read
and every parse, manifest, and aggregate diagnostic is non-erroring. A
partial preload is never installed as a ready schema.

### Discovery

Discovery is per document and lexical. It never combines a document with
a parent configuration.

1. A non-file URI performs no filesystem discovery and uses the existing
   in-memory context.
2. A file URI is percent-decoded and normalized lexically. Symbolic links
   are not resolved, so `/var` and `/private/var` remain distinct paths.
3. The containing initialization workspace folder is chosen by
   segment-aware path length; an exact tie keeps initialization order.
   Without workspace folders, the deprecated `rootUri` is used, then
   `rootPath`.
4. With no containing root, only the document's own directory is
   inspected.
5. Otherwise the walk starts at the document's directory and goes toward,
   but never above, the containing root. The nearest directory holding
   either marker stops the search; markers above it are never consulted.
6. No marker before the boundary leaves the document `unconfigured`.
7. Only `sjon-project.sjon` at the stopping directory selects that legacy
   project.
8. Only `sjon-lsp.sjon` at the stopping directory selects an editor
   bundle when exactly one bundle's patterns match. Multiple matches are
   an unavailable conflict; a valid file with no match leaves the
   document `unconfigured` with core behavior; an invalid file makes
   documents in that boundary unavailable.
9. When both markers exist, one matching bundle wins without eagerly
   loading the project. Multiple matches are a conflict. With no bundle
   match, the same-directory project is the legacy fallback and the named
   resolver for declaration references. An invalid editor configuration
   is unavailable and is never silently replaced by the project.
10. The walk never continues past the stopping marker directory to find a
    parent configuration or project.

Configuration files and every known bundle or declaration source are
source routes, not ordinary project data. Both marker filenames are
excluded from workspace scans regardless of the legacy project's own
plugin list. Dynamic workspace-folder notifications are not implemented
or advertised: restart the server after changing the workspace folder
set.

### Ready, unavailable, and conflicts

A **ready** association has one selected bundle and all required inputs
compiled without error-severity diagnostics. The document uses the
complete effective schema.

An **unavailable** association covers a malformed configuration, a bundle
conflict, a deleted marker, an unreadable required source, or an
error-severity compile diagnostic. It preserves the current buffer's
parse diagnostics and adds one actionable editor-local failure. It
suppresses schema-dependent results and never falls back to core, a
parent, or a stale schema. An unrelated ready context keeps serving
normally.

Unavailable and source documents still support parse-only features:
formatting, folding, document symbols, and selection ranges. Completion,
hover, signature help, goto-definition, references, prepare-rename,
rename, document highlight, semantic tokens, inlay hints, and code
actions are schema-dependent and are refused for that association.

A document matching two bundles is a conflict, not a first-match choice.
The document reports `sjon-lsp/bundle-conflict` at byte 0 and relates each
matching bundle name and pattern at its real configuration span. A
selected marker that is deleted produces `sjon-lsp/marker-deleted` and no
parent rediscovery; recreating that same known marker recovers the
boundary. A wholly new marker takes effect after a restart.

### Per-document declarations

Declarations are composed only for an ordinary document whose association
is ready. A document with no top-level `(plugin …)` or `(use-plugin …)`
shares the baseline handler. Any such directive, even a malformed one,
creates a one-document context; the temporary preparation is recomputed
on every open and content change, not only when the directive set
changes.

The effective schema is `core ++ baseline-preloaded ++ document-loaded`.
The resolver root is the discovered marker directory, and the only named
reference index is `<marker-dir>/sjon-project.sjon`; there is no
parent-index fallback. Inline-only preparation neither initializes the
filesystem resolver nor reads an unrelated project. Explicit references
load the applicable project index and retain its diagnostics; that
project file is a saved-input dependency.

Schema-only filesystem resolution follows the existing explicit-path,
name, version, and hash rules but does not read paired or `:wasm-file`
sidecars. No lowering registry or provider runtime is installed in a
configured context, so a resolved executable manifest without wasm keeps
the host's honest `plugin_wasm_required` error rather than being hidden.
Every resolved manifest path is recorded even when its load fails, so
repairing and saving that file rebuilds the document context. Aggregate
diagnostics that cannot be attributed to one source are re-anchored at
the document's byte 0, never presented as a preloaded-source offset.

### Saved bytes, open buffers, and watchers

Ordinary document buffers use the client's unsaved text immediately.
Configuration, bundle manifests, project indexes, and resolved
declaration manifests instead use saved disk bytes as their dependents'
authority. `didSave` advertises `includeText = false`; the server rereads
the saved path and ignores any optional text for schema reload. An
unsaved source buffer never creates a live generation for dependents,
and an atomic replacement needs no special watcher: the next save or
watched notification reads the replacement's current bytes.

A dirty open configuration or manifest publishes its live parse-only
report and suppresses saved-byte compile diagnostics on that same URI, so
spans from different byte streams are never mixed. Dependents stay on the
last saved generation. After a save, when the current buffer bytes equal
the saved bytes, live parse and saved source reports are combined and
exact duplicates removed. Closing a dirty source discards the overlay and
restores the saved-byte report. None of this changes the selected
context's schema until the saved input is reloaded.

The server keeps one broad `**/*.sjon` watcher registration and only
registers it when the client advertises
`workspace.didChangeWatchedFiles.dynamicRegistration`. A configured
connection filters events to selected markers and known bundle or
declaration sources; a pure legacy connection keeps its broad project
reload. A rejected registration marks watching unavailable, logs once,
and is never retried or polled; diagnostics do not depend on it. External
absolute paths and newly created previously unknown markers are not
guaranteed to be covered. Saving the file or restarting the server is the
fallback, and a save plus restart is always a valid recovery path,
including paths the client cannot watch. Pull clients that advertise
`workspace.diagnostics.refreshSupport` receive one
`workspace/diagnostic/refresh` after a successful reload; others see the
new state on their next pull because result IDs include the context
generation.

### Editor-local diagnostics

Editor-local diagnostics use `source = "sjon-lsp"` and string
identifiers, not new `Ast.Diagnostic.Code` variants. They omit
`codeDescription`: there is no `sjon explain` page for them. Ordinary
SJON parser and manifest diagnostics on the configuration or source files
keep their normal codes and documentation links.

| Identifier | Meaning and primary location |
|---|---|
| `sjon-lsp/config-read` | The selected configuration cannot be read; configuration URI, byte 0. |
| `sjon-lsp/config-shape` | Wrong root or bundle shape, a missing required field, or a positional child; offending node or containing form. |
| `sjon-lsp/config-version` | An integer version other than 1; version value span. |
| `sjon-lsp/config-duplicate-key` | A duplicate root or bundle key; second key span, first key related. |
| `sjon-lsp/config-unknown-field` | An unknown root or bundle key; unknown key span. |
| `sjon-lsp/config-type` | A value or vector element has the wrong type; value or element span. |
| `sjon-lsp/config-empty-list` | Empty `:files` or `:manifests`; vector span. |
| `sjon-lsp/config-duplicate-bundle` | A repeated bundle label; second name span, first name related. |
| `sjon-lsp/config-pattern` | An invalid file pattern; pattern string span. |
| `sjon-lsp/config-path` | An empty, NUL-containing, URL-shaped, nonportable, or glob-bearing manifest path; source string span. |
| `sjon-lsp/config-duplicate-source` | A repeated normalized manifest path in one bundle; second source span, first source related. |
| `sjon-lsp/bundle-source-read` | A required source cannot be read; manifest entry span, with the source URI related at byte 0 when useful. |
| `sjon-lsp/bundle-aggregate` | An aggregate diagnostic has no unique source attribution; a real bundle or manifest-entry span naming every candidate source. |
| `sjon-lsp/bundle-conflict` | The document matches multiple bundles; document byte 0 with each conflicting bundle name and pattern related. |
| `sjon-lsp/bundle-unavailable` | The selected configuration or bundle is unavailable; document byte 0 with the real configuration or source location related. |
| `sjon-lsp/marker-deleted` | A previously selected marker was deleted; document byte 0 with the marker URI related. |

`relatedInformation` is emitted only when the active delivery mode's
capability object announces it, like every other diagnostic relation.

### Legacy projects

`sjon-project.sjon` remains supported and unchanged when no editor bundle
applies. A project-only connection keeps its broad watched-file reload and
its partial-load behavior: a failed source reports diagnostics while the
valid sources still contribute. A selected editor bundle is stricter —
every required input must succeed before any schema is installed.

Legacy project-only and non-file contexts also keep their existing
directive behavior: top-level `(plugin …)` and `(use-plugin …)` forms are
stripped from the document data but are not composed into the schema. The
per-document declaration path above exists only for configured documents.
To give a bare or project-only document new plugin vocabulary, add a
matching `sjon-lsp.sjon` bundle.

Configuration files, project indexes, and known bundle sources are
reported at their own URIs as source routes rather than validated as
ordinary documents. The CLI and `sjon-project.sjon` resolver semantics are
otherwise unchanged; `sjon-lsp.sjon` is an editor-local file that the
native language server reads.

## Per-editor setup

Every block below assumes `sjon-lsp` is on your `PATH`. The server:

- attaches to `*.sjon` files,
- treats `;` as the line-comment token,
- discovers each document's schema from the nearest `sjon-lsp.sjon` editor
  bundle configuration or, when no bundle applies, the nearest
  `sjon-project.sjon` project, and reloads saved inputs when they change.
  A nearer marker stops the search; nothing is inherited from a parent
  directory.

No marker means core behavior: plugin form heads report `unknown_form`.
That is correct — a bare document declares nothing. Add a
`sjon-lsp.sjon` bundle for per-document declarations, or a
`sjon-project.sjon` project for a workspace-wide vocabulary. In a
project-only or bare document, top-level `(plugin …)` / `(use-plugin …)`
forms are stripped as data but do not extend the schema.

The server asks the client to watch `.sjon` files only when the client
advertises `workspace.didChangeWatchedFiles.dynamicRegistration`; a client
with static watch configuration can still send
`workspace/didChangeWatchedFiles` without registering. A configured
connection filters those events to selected markers and known bundle or
declaration sources, so a newly created unknown marker is not guaranteed
to be noticed. If an editor misses a manifest change, restart it:
`initialize` re-runs discovery from the workspace root, which is the
guaranteed way to load the current schema.

### Neovim (0.11+)

```lua
-- init.lua
vim.filetype.add({ extension = { sjon = "sjon" } })

vim.lsp.config("sjon", {
  cmd = { "sjon-lsp" },
  filetypes = { "sjon" },
  root_markers = { "sjon-lsp.sjon", "sjon-project.sjon", ".git" },
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
roots = ["sjon-lsp.sjon", "sjon-project.sjon"]
```

Helix prints a `no highlight configuration` warning without a tree-sitter
grammar (SJON ships none yet); the language server still attaches and
diagnostics, hover, and completion work.

Use an absolute `command`, or put `zig-out/bin` on `PATH`, and restart
Helix after replacing the binary — a running process keeps the copy it
initialized. `hx --health sjon` proves that Helix discovered the `sjon`
language and its server entry; it does not prove that `sjon-lsp`
initialized or that diagnostics reach the UI.

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
extension to register the language client. A minimal local-install
extension lives in [`editors/vscode/`](../editors/vscode/) — build the
server, set `sjon.lsp.path`, then `F5` or `vsce package`. The extension
only starts the server; the server discovers `sjon-lsp.sjon` and
`sjon-project.sjon` per document, so a workspace needs no extra VS Code
setting to use editor schema bundles.

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
with no call back in per pointer move. `@sjon-lang/web` ships that scan as
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

Both are wrapped on `@sjon-lang/web`'s `SjonEncoder` (`nodeTable`,
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
