# Editor schema bundles

This is a worked [`sjon-lsp.sjon`](../../docs/TOOLING.md#editor-schema-bundles)
workspace: one directory that gives two folders two different schemas. The
native language server reads the configuration; the CLI and the WASM
playground do not.

| Path | What it is |
| --- | --- |
| [`sjon-lsp.sjon`](sjon-lsp.sjon) | Version-1 bundle configuration: two named bundles with file patterns and ordered manifests. |
| [`gpu/texture.sjon`](gpu/texture.sjon) | Valid under the `gpu-textures` bundle. |
| [`gpu/texture-typo.sjon`](gpu/texture-typo.sjon) | Deliberately invalid: `4d` is not a member of `texture-dimension`. |
| [`geometry/shape.sjon`](geometry/shape.sjon) | Valid under the `geometry` bundle. |
| [`geometry/shape-typo.sjon`](geometry/shape-typo.sjon) | Deliberately invalid: `px` is outside `distance`'s allowed units. |

The two bundles reuse the reference plugins in
[`examples/plugins/`](../plugins/): `dimensions` (digit-leading enum members)
and `units` (unit-bearing numbers). Their manifests are referenced by relative
path, so the example stays one file rather than a copy of both schemas.

## How the server picks one

1. The document's path is matched against each bundle's `:files` patterns,
   relative to this directory. `*` is one path segment; a whole `**` segment
   is zero or more.
2. Exactly one match selects that bundle. Two matches are a conflict, not a
   first-match choice.
3. The selected bundle's `:manifests` are read in order and compiled into that
   document's complete schema. Core is prepended once.
4. Discovery stops at the nearest `sjon-lsp.sjon` or `sjon-project.sjon`
   marker. Nothing is inherited from a parent directory.
5. A document with its own top-level `(plugin …)` or `(use-plugin …)` directive
   gets a one-document context composed on top of the bundle. These example
   documents declare nothing: the bundle is their whole schema.

A malformed configuration, unreadable manifest, or aggregate failure makes the
document unavailable; it does not fall back to core or to the other bundle.
The full grammar, pattern rules, precedence against `sjon-project.sjon`, and
the `sjon-lsp/*` diagnostic identifiers are in
[the editor guide](../../docs/TOOLING.md#editor-schema-bundles).

## Try it

Build the server and point an editor at this directory:

```sh
zig build lsp            # → zig-out/bin/sjon-lsp
```

Open `examples/editor-bundles` as the workspace (or as a root in Neovim or
Helix), then open the documents:

- `gpu/texture.sjon` and `geometry/shape.sjon` are clean.
- `gpu/texture-typo.sjon` reports `not_member` at `4d`; the quick fix offers
  the declared spellings.
- `geometry/shape-typo.sjon` reports `unit_not_allowed` at `12px`; the quick
  fix offers `mm`, `cm`, `m`, and `km`.
- Completion in `gpu/texture.sjon` offers `texture` and its keys, but not
  `shape`; completion in `geometry/shape.sjon` does the reverse. That is the
  per-document schema, not a global plugin list.

The WASM language server does not discover this file: the playground keeps its
one supplied schema. `sjon check` also ignores it, because it is an
editor-local format.

Once the server has a document open, editing `sjon-lsp.sjon` or either manifest
and saving reloads the affected documents. Adding a brand-new marker directory
needs a server restart.
