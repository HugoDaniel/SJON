# @sjon/schema — fluent schema authoring + Zod-style inference

Host-independent TypeScript front-end for SJON plugin schemas. You write
a schema with a fluent builder, get a precise static type for free
(`s.infer<T>`), and serialize it to the portable `(plugin …)` manifest
that every SJON host understands. Pure TypeScript, **zero runtime deps**.

```ts
import { s } from '@sjon/schema';

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
| `s`            | `builder.ts`      | Schema factories — `s.form` / `s.plugin`, leaves (`s.string`, `s.number`, `s.symbol`, `s.expr`, …), string presets (`s.slug`, `s.email`, `s.url`, `s.uuid`, `s.semver`, `s.path`), `s.vector`, `s.crossRef`, `s.kind`, plus the `s.infer<T>` / `s.input<T>` type helpers and `s.use` (backend registration). Also re-exported flat (`import { form, string } from '@sjon/schema'`). |
| `v`            | `value-ctor.ts`   | Atom value constructors (`v.sym(…)`, …) for building concrete SJON values. |
| `e`            | `expr.ts`         | Expression constructors (`e.add(…)`, …) for `(expr …)` trees. The typed surface is generated from the Zig core op table (`expr.gen.ts`, via `zig build gen-expr-ops`). |
| `sjon`         | `template.ts`     | The `` sjon`…` `` tagged template for inline SJON literals. |
| `edit`         | `edit.ts`         | Write-back action builders + a pure differ (`diffToActions`, `sjonValueEqual`). The typed edit *methods* live on the nodes (`Form.setKey` / `removeKey` / `replace`). |

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
