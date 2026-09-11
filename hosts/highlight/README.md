# @sjon-lang/highlight

Reusable `.sjon` syntax-highlighting grammars: a **CodeMirror 6**
`StreamLanguage` and a **TextMate** grammar for Shiki (and any other TextMate
consumer). Two engines, one source of truth — both derive from the same token
rules, so every consumer highlights `.sjon` identically.

This package covers *lexical* highlighting only (comments, strings, numbers,
`:keys`, form heads, brackets). The schema-aware layer a grammar can't see —
resolved heads, keys, cross-ref names — comes from the language server's
semantic tokens; see [docs/TOOLING.md](../../docs/TOOLING.md).

## Install

Consumed as a workspace or path dependency. It is **source-only**: there is
no build step — bundlers (Astro/Vite/esbuild) transpile the `.ts` and
resolve the `.json` directly.

- `@codemirror/language` is a **peer** dependency (the CodeMirror path).
- `shiki` is needed only for the Shiki path.

## CodeMirror 6

```ts
import { sjonLanguage } from '@sjon-lang/highlight';
import { EditorState } from '@codemirror/state';

EditorState.create({ extensions: [sjonLanguage, /* … */] });
```

Lower-level exports for embedding in an existing `StreamParser`:
`sjonToken`, `sjonStreamParser`, and the `SjonStreamState` type.

## Shiki / TextMate

```ts
import { sjonTextMateGrammar } from '@sjon-lang/highlight';
import { createHighlighter } from 'shiki';

const hl = await createHighlighter({
  langs: [sjonTextMateGrammar],
  themes: ['github-dark'],
});
hl.codeToHtml('(scene :w 800)', { lang: 'sjon', theme: 'github-dark' });
```

## The raw TextMate grammar

`sjonTextMateGrammar` is the typed re-export of
[`src/sjon.tmLanguage.json`](src/sjon.tmLanguage.json) (scope `source.sjon`).
Consume that file directly in any TextMate host — VS Code's
`contributes.grammars`, a Sublime `.sublime-syntax` conversion, etc. The
named scopes are stable theme targets:

| Construct | Scope |
|---|---|
| `; line comment` | `comment.line.semicolon.sjon` |
| block comment | `comment.block.sjon` |
| `"string"` / `"""raw"""` | `string.quoted.double.sjon` / `string.quoted.triple.sjon` |
| escape | `constant.character.escape.sjon` |
| number | `constant.numeric.sjon` |
| `:keyword` | `entity.name.tag.sjon` |
| form head | `entity.name.function.sjon` |
| `true` / `false` / atoms | `constant.language.sjon` |
| `(` `)` `[` `]` | `punctuation.section.parens.*` / `punctuation.section.brackets.sjon` |

Renaming a scope silently breaks downstream themes — they're pinned by the
scope-surface test below, so a rename is a conscious edit.

## Tests

`pnpm test` (or `node --test --experimental-strip-types 'test/*.test.ts'`)
runs both engines against a shared corpus: the `sjonToken` regression net, the
TextMate scope surface, and a per-character CodeMirror↔TextMate parity check
that catches drift between the playground (CM) and static-docs (Shiki)
renderers. Fidelity is hand-verified against `src/Lexer.zig` and
[docs/LANGUAGE.md §2](../../docs/LANGUAGE.md).
