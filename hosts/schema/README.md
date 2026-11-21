# @sjon-lang/schema — fluent schema authoring + Zod-style inference

Host-independent TypeScript front-end for SJON plugin schemas. You write
a schema with a fluent builder, get a precise static type for free
(`s.infer<T>`), and serialize it to the portable `(plugin …)` manifest
that every SJON host understands. Pure TypeScript, **zero runtime deps**.

```ts
import { s } from '@sjon-lang/schema';

const Profile = s.form('profile', {
  handle: s.slug(),
  email: s.email().optional(),
  score: s.number().min(0).max(100).optional(),
}, 'bounds');

type Profile = s.infer<typeof Profile>;
// { $form: "profile"; $ns: "bounds"; handle: string; email?: string; score?: number }

s.use(backend);                       // register a WASM or native ValidateBackend
const data = Profile.parse(sjonText); // typed, or throws SjonValidationError
```

The builder never validates on its own — that's the backend's job (see
the seam below). What the builder owns is *authoring*, *inference*, and
*serialization*.

## Namespaces

All five are module namespaces, so the value factory and the type
helpers resolve off one import.

| Namespace      | Source            | What it gives you |
| -------------- | ----------------- | ----------------- |
| `s`            | `builder.ts`      | Schema factories — `s.form` / `s.plugin`, leaves (`s.string`, `s.number`, `s.symbol`, `s.expr`, …), string presets (`s.slug`, `s.email`, `s.url`, `s.uuid`, `s.semver`, `s.path`), `s.vector`, `s.crossRef`, `s.kind`, plus the `s.infer<T>` / `s.input<T>` type helpers and `s.use` (backend registration). Also re-exported flat (`import { form, string } from '@sjon-lang/schema'`). |
| `v`            | `value-ctor.ts`   | Atom value constructors (`v.sym(…)`, …) for building concrete SJON values. |
| `e`            | `expr.ts`         | Expression constructors (`e.add(…)`, …) for `(expr …)` trees. The typed surface is generated from the Zig core op table (`expr.gen.ts`, via `zig build gen-expr-ops`). |
| `sjon`         | `template.ts`     | The `` sjon`…` `` tagged template for inline SJON literals. |
| `edit`         | `edit.ts`         | Write-back action builders + a pure differ (`diffToActions`, `sjonValueEqual`). The typed edit *methods* live on the nodes (`Form.setKey` / `removeKey` / `replace`). |

## Enums whose members start with a digit

`s.symbolMembers` accepts the WebGPU-style spelling — `1d`, `2d`,
`2d-array`, `50%` — that no bare SJON symbol can express, because such a
spelling lexes as a **unit-bearing number**. That has one consequence you
can see in the types, and it is not a quirk of this package: it is what
the document actually carries.

```ts
import { s, v } from '@sjon-lang/schema';

const Texture = s.form('texture', {
  dimension: s.symbolMembers(['1d', '2d', '3d'] as const),
  view: s.symbolMembers(['2d', '2d-array', 'cube'] as const).optional(),
}, 'gpu');

// dimension is SjonUnit<"d">, not Symbol_<"2d"> —
// so v.unit(2, "d") fits the slot and v.sym("2d") throws.
const t = Texture.create({ dimension: v.unit(2, 'd') });
```

Two details worth knowing:

- **The brand keys on the unit, not the magnitude.** `SjonUnit<"d">`
  accepts any `v.unit(n, "d")`; the *validator* is what reports `4d` as
  `not_member`. A magnitude-keyed brand is not something this package
  has.
- **Spellings are canonicalised, and bad ones throw at authoring time.**
  `02d` declares the member `2d` (exactly as the engine's loader
  canonicalises it, so the manifest agrees with every diagnostic about
  it). A spelling with no unit (`1`), a fractional magnitude (`2.5d`), or
  a unit that would not lex as one token (`2dx9`) throws where you wrote
  it, rather than becoming an `invalid_manifest` diagnostic on a manifest
  nobody has read yet.

Ordinary symbol members are unaffected — `Symbol_<"admin"> |
Symbol_<"user">` as before.

## Divisibility bounds and target groups

Two more knobs the manifest grammar gained in SJON 1.2.0.

```ts
s.number().multipleOf(256)                  // (numeric-bounds :multiple-of 256)
s.crossRef(['render-pipeline', 'compute-pipeline'], { nameKey: 'name' })
```

`multipleOf` is the alignment constraint a `min`/`max` pair cannot express
(`:offset` must be a multiple of 256, whatever its range). The divisor has
to be positive: zero has no multiples to check, and a negative one accepts
exactly what its magnitude accepts while exporting a `multipleOf` that JSON
Schema forbids. The builder throws at the call site, where the loader would
report `invalid_manifest`.

`s.crossRef` takes one target form or a list of them. A list is **one
namespace over several forms**: a name declared by any of them satisfies a
reference, and a name declared by two of them is
`duplicate_cross_ref_target`. A union over two cross-ref kinds is the other
shape, two namespaces where declaration order picks the entity. The value
type distributes either way (`CrossRef<"render-pipeline"> |
CrossRef<"compute-pipeline">`), since TypeScript has no way to say "one
namespace". `acyclic` and `provider` are rejected on a group, matching the
loader rather than emitting a manifest it would refuse.

## Extension vocabularies and starter templates

The builder is for *new* vocabulary: a small plugin authored in TypeScript
beside a host's hand-authored manifest, plus a starter document for one of its
forms. It is not a way to move a host's core schema into TypeScript, and it is
not zod interop (see *What this is not* below).

### Form options: `open` and `positional`

`s.form`'s third argument still takes the legacy namespace string, unchanged.
It also takes an options object; the string spelling normalizes to `{ns}`.

```ts
// Legacy spelling: same namespace, same manifest bytes as before.
const Profile = s.form('profile', { handle: s.slug() }, 'bounds');

// Options object: namespace plus an open form.
const Note = s.form(
  'note',
  { text: s.string() },
  { ns: 'studio', open: true },
);

// Untyped positional children.
const AnyLines = s.form(
  'lines',
  { title: s.string() },
  { ns: 'studio', positional: 'any' },
);

// One typed positional slot: every child is a string.
const Lines = s.form(
  'lines',
  { title: s.string() },
  { ns: 'studio', positional: s.string() },
);
```

`open: true` emits `:open true`. The inferred value gains
`[key: string]: unknown`, and `.create` / `.toSjon` keep undeclared own fields
(declared keys are still materialized and overwrite, and `$form` / `$ns` are
still stamped). A closed form keeps dropping undeclared fields.

`positional: 'any'` emits `:positional any` and types
`$children?: unknown[]`. A node emits `:positional <kind>` — a builtin token
such as `:positional string`, or a hoisted value-kind name when the element is
refined — and types `$children?: Array<Out>`; `.create` materializes each child
through the element's shape. Omitting `positional` leaves no `$children` member
in the type or the manifest, and a smuggled `$children` value is ignored.

The slot is exactly `'any'` or one existing node. A union of shapes, a
positional flag-set, or a slot-local form is not a `FormOptions` spelling.

### Number representation and unit rejection

```ts
const Bytes = s.number().repr('u32').rejectUnits().min(0).int();
```

`.repr(tag)` accepts exactly five GPU tags — `'f32' | 'u32' | 'i32' | 'u16' |
'f16'` (`s.GpuRepr`) — and emits `:repr (repr-shape :type <tag>)`. The value
type is branded: `s.F32` … `s.F16`, or `s.ReprNumber<tag>` structurally. The
brand is a phantom key on an ordinary `number`, not a runtime wrapper. Any
other tag (`'u8'`) throws at the call site, and every existing number
refinement preserves the selected tag.

`.rejectUnits()` emits `:unit (unit-shape :reject true)` and leaves the static
type `number`, because rejection is a validation rule rather than a type
distinction.

`:numeric`, `:unit` and `:repr` are orthogonal siblings and serialize in that
order. The validator reports `repr_out_of_range` for a value the chosen tag
rejects and `unit_forbidden` for a unit-suffixed value. The exporter carries
`x-sjon-gpu-repr` and does not lower the GPU range (see
[`docs/SCHEMA_EXPORT.md`](../../docs/SCHEMA_EXPORT.md)). Only `:reject true` is
exposed: `:unit (unit-shape :required …)` and `:allowed […]` stay hand-authored.

### Starter skeletons

`skeleton(heldSymbol?)` emits ordinary SJON source for one document, with every
declared key in declaration order:

```ts
const Starter = s.form(
  'starter',
  {
    name: s.string(),
    count: s.number().default(2),
    enabled: s.boolean().optional(),
  },
  'studio',
);

Starter.skeleton();
// (studio/starter :name _ :count 2 :enabled _)
```

A declared default is deep-cloned and serialized; every other key — required or
optional, including a nested form or vector without a default — is the held
symbol. A compound slot is held as one whole value rather than recursively
expanded. No `$children` array is invented. The method is backend-free: it
returns source text, not a typed `FormOut`.

The default spelling is `_`; `skeleton('hole')` uses `hole` instead, and an
invalid spelling throws through `v.sym`'s own guard at the call site.

### The two-manifest recipe

Author a small extension plugin, compose it beside a hand-written host manifest
with one `\n` between the sources, and validate document-first:

```ts
import { SjonHost } from '@sjon-lang/web';
import { s } from '@sjon-lang/schema';

const Note = s.form(
  'note',
  { text: s.string(), bytes: s.number().repr('u32').rejectUnits() },
  { ns: 'studio', open: true },
);
const Lines = s.form(
  'lines',
  { title: s.string() },
  { ns: 'studio', positional: s.string() },
);
const Extension = s.plugin('studio', { version: '1.0.0', forms: [Note, Lines] });

// The host's own manifest stays hand-authored.
const hostManifest = `(plugin :name host :version "1.0.0"
  (form :name scene
    (key :name title :type string :optional false)))`;

const document = `(host/scene :title "opening")
(studio/note :text "hello" :author "ada" :bytes 7)
(studio/lines :title "row" "a" "b")`;

const host = await SjonHost.load('./zig-out/bin/sjon.wasm');
const result = host.validateDocument(
  `${hostManifest}\n${Extension.manifest()}\n${document}`,
  { projectRoot: null, projectFile: null },
);
// result.diagnostics carries no `err` entries.
```

The same composition is the control surface. Remove `Extension.manifest()` and
both extension roots report `unknown_form`, so a clean composed run cannot pass
merely because the extension was never loaded. A non-string child under
`lines` reports `wrong_underlying`; an undeclared key on closed `lines` reports
`unknown_key`, while the same key on open `note` is accepted; `:bytes 1.5`
reports `repr_out_of_range` and `:bytes 7px` reports `unit_forbidden`.
`hosts/web/test/schema-extension.test.ts` pins every one of those outcomes.

Diagnostics come back in the **composed** source: `validateDocument` indexes
spans over the whole string it was given, with no rebasing, so a document-origin
diagnostic sits after the manifest prefix. Subtract the prefix's UTF-8 byte
length to recover a document-relative offset.

To reuse the schema across many documents, preload the same standalone
manifests as a set instead of prepending them to every document: native
`Host.preloadSchema` takes them as a set, and the Web wrapper is
`host.preload([hostManifest, Extension.manifest()])`. A preloaded handle is an
optimization, not a prerequisite; the composed `validateDocument` call above is
the supported no-handle path.

### What this is not

- **No zod-library interop.** There is no `z.fromJSONSchema`, no
  `json-schema-to-zod`, and no zod-shaped runtime value. `s.infer` is
  TypeScript inference over this builder; "Zod-style" names the fluent
  ergonomics only.
- **Core host schemas stay hand-authored.** The builder is for new extension
  vocabularies and starter templates, not a TypeScript rewrite of a host's
  manifest.
- **Held validation is caller-selected.** Heldness is a run option
  (`heldSymbol`), never a schema or document setting.
- **A skeleton used without `heldSymbol` is intentionally invalid while holes
  remain.** The holes are ordinary symbols and report (`wrong_underlying` for
  the measured `starter` form), which is the control that keeps a held-clean
  run from meaning validation was weakened. A held run still reports
  `unknown_key` on a closed form.
- Within this extension surface, only the knobs documented above exist; the
  rest of the manifest grammar stays hand-authored vocabulary.

## Write-back: `wrap`, and which root an edit starts at

The typed edit methods on a node (`Form.setKey` / `removeKey` /
`replace`) cover a document with one root. Two things in `edit` cover
what they cannot.

```ts
import { edit } from '@sjon-lang/schema';

// (a :x (* 2 (sin t)))  →  (a :x (+ (* 2 (sin t)) 0.1)), comments kept
edit.wrap(['x'], { $form: '+', $children: [null, 0.1] }, [0]);

// the second root of a file whose first root is (use-plugin …)
edit.atRoot(edit.setKey([], 'bpm', 140), 1);
```

`wrap` composes the node at `path` into a new parent. `value` is the
parent as an ordinary `SjonValue` with a placeholder where the wrapped
node lands, and `hole` is the path to that placeholder *inside the
decoded parent* (`[0]` is its first positional child; `$children` is
not a step). It is the one op that keeps the wrapped subtree's
comments: the engine clones the node instead of rebuilding it from
JSON, which is what the four other `value`-taking ops do, and the JSON
bridge carries no comments. Spelling the same shape as a `replace`
whose value nests the old subtree loses them. `path` may be empty
(wrap the whole root); `hole` may not, and the builder throws before
the round-trip, since a wrap with no hole is a `replace` that discards
its target. Single-action `applyEdit` reprints; the backend's optional
`applyEdits(source, actions, { layout: 'preserve' })` can preserve bytes
outside edited spans. `applyAll` and form helpers use backend defaults;
the schema options expose layout, not every Zig engine option.

`atRoot` points an action at root `index`. A SJON file that declares or
references a plugin has several roots, and each of the six pathed builders produces a
root-less action, which the engine accepts only on a single-root
document; on a multi-root one an omitted root is `MultipleRoots`, a
refusal rather than an implicit `0`. It is a combinator rather than a
parameter on all six builders because `root` answers "which fragment"
and `path` answers "where inside it", and only the second is worth
repeating six times.

`edit.insertRoot(value, index?)` inserts before `index` (omitted means append);
`edit.removeRoot(index)` removes that root. These two actions take neither
`path` nor `root`: `index` addresses the document's root list.

## The `ValidateBackend` seam

The builder is host-independent: validation, projection, and `.d.ts`
emission are delegated to an injected backend. Register one once with
`s.use(backend)` (alias of `useBackend`); `requireBackend` throws a
clear error if a backend-dependent method is called before one is set.

- **`ValidateBackend`** — `validate` / `parse` over a `(manifest, source)`
  pair, plus `exportSchema` (JSON Schema + TS types).
- **`EditBackend`** — the write-back surface backing `Form.setKey` etc.

Adapters live in the sibling hosts: `hosts/web` (WASM-backed,
`SjonSchemaBackend`) and `hosts/typescript-parity` (native TS). A schema
authored here runs against any of them unchanged.

## `Form.manifest()` — the cross-language contract

Every `Form` / `Plugin` node serializes to the canonical SJON manifest:

```ts
Profile.manifest();   // → "(plugin :name bounds … (form :name profile …))"
Profile.toDts();      // → TypeScript .d.ts text (delegates to the backend)
```

`manifest()` is the universal artifact — feed it to the Zig CLI
(`sjon export-schema`), any host's `exportSchema`, or another language's
SJON reader. `s.infer<T>` is the compile-time mirror of what
`exportSchema(manifest()).tsTypes` produces at runtime, so the static
type and the emitted `.d.ts` stay in lockstep.

## Developing

`npm run typecheck` (`tsc --noEmit`) is the real gate — the inference
layer is the product, so a type regression is a behavioural regression.

```bash
cd hosts/schema
npm run typecheck     # the gate
npm test              # node --test over test/*.test.ts
```

Both also run as part of the repo-wide `zig build verify`.
