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
JSON, which is what the other five `value`-taking ops do, and the JSON
bridge carries no comments. Spelling the same shape as a `replace`
whose value nests the old subtree loses them. `path` may be empty
(wrap the whole root); `hole` may not, and the builder throws before
the round-trip, since a wrap with no hole is a `replace` that discards
its target. Layout is not preserved by any op: the result is re-printed
from the tree.

`atRoot` points an action at root `index`. A SJON file that declares or
references a plugin has several roots, and every builder produces a
root-less action, which the engine accepts only on a single-root
document; on a multi-root one an omitted root is `MultipleRoots`, a
refusal rather than an implicit `0`. It is a combinator rather than a
parameter on all six builders because `root` answers "which fragment"
and `path` answers "where inside it", and only the second is worth
repeating six times.

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
