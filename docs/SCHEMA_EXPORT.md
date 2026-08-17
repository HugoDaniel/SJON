# SJON schema export

A one-way exporter that converts a fully-resolved `Schema.Schema` into JSON Schema 2020-12 and TypeScript `.d.ts` types describing the **canonical JSON shape** of `sjon to-json` output. Use it to give downstream tools (editors, codegen pipelines, language servers, validators in other ecosystems) a machine-readable view of a plugin's forms without re-implementing the SJON parser, meta-schema, or aggregate-phase resolution rules.

Output format version: **`x-sjon-export-version: 1`**. The exporter covers primitives, closed/open forms, typed/untyped vectors, compact members, and literal defaults; discriminated variants, exclusive groups, head-sets, unions, slot-local forms (inline anonymous union), and rich member-sets (including digit-leading spellings, pinned to their `$num` wire shape); numeric bounds (including `:multiple-of` → `multipleOf`), key dependencies (`:requires` → `dependentRequired`), per-head positional counts (`contains` / `minContains` / `maxContains`), unit-bearing numbers (`$num` tuple via `prefixItems`), unitless numbers (`:reject`), GPU representation tags (`x-sjon-gpu-repr` + branded `F32`…`F16`), variable-arity vectors (`minItems`/`maxItems`), the `scalar-or-ref` shorthand (exported as its desugared union), string bounds (`minLength`/`maxLength`/`pattern`/`format`), cross-ref annotations (`x-sjon-cross-ref` carrying the target, one form or a group of them, plus `name-key`, `acyclic`, and `scope-form` / `provider` + `source-key` when set), the per-plugin layout (with cross-file `$ref` resolution), multi-key exclusive-group bundles, and positional flag-sets (`x-sjon-positional-flags`). Known limitations are listed under *What's not in this exporter* below.

## Intended consumers

- **Editor tooling** — surface form/key autocomplete by importing the emitted `.d.ts` into a TypeScript LSP.
- **Codegen pipelines** — feed the JSON Schema into `quicktype` / `json-schema-to-anything` to produce Python, OCaml, Rust, etc. bindings.
- **Cross-ecosystem validators** — point Ajv 2020 / `python-jsonschema` / Newtonsoft.JSON at the schema and validate documents that were already pushed through `sjon to-json --canonical`.
- **Documentation generators** — read the `description`/`title`/`@member` annotations to build per-plugin reference pages.

## CLI

```
sjon export-schema FILE [options]
```

Options (mirrors `sjon --help`):

| Option | Default | Notes |
|---|---|---|
| `--target=<json-schema\|typescript\|both\|intermediate\|markdown>` | `both` | Output dialect. `intermediate` emits the IR (see below); `markdown` renders reference pages (see below). |
| `--output=PATH` | `-` (stdout) | With `--target=both` and stdout, emits a `{"jsonSchema": …, "tsTypes": …}` envelope. With a PATH, writes per-target files (`schema.json`, `types.d.ts`, `export.json`, `schema.md`). |
| `--layout=<aggregated\|per-plugin>` | `aggregated` | `aggregated` emits one `schema.json` + `types.d.ts`. `per-plugin` emits one `<plugin>.schema.json` + `<plugin>.d.ts` per plugin plus an `index.d.ts` barrel; cross-plugin `$ref`s resolve as `./<other>.schema.json#/$defs/form.<other>.<head>` and TS `import type { OtherForm } from "./other"`. |
| `--draft=2020-12` | `2020-12` | Only 2020-12 is accepted; the flag exists for forward compatibility. |
| `--project-root=DIR` / `--no-project` | auto-discover | Same semantics as `sjon validate`. |

Exit codes: `0` clean, `1` if any warning has `.err` severity (output still written), `2` usage error.

## Output modes

### JSON Schema 2020-12

A single top-level document whose `oneOf` enumerates every form. Per-form definitions live under `$defs/form.<plugin>.<name>`.

Headline 2020-12 features used:
- `prefixItems` — encodes `number_with_unit` as `{"$num": [<magnitude>, <unit>]}`. The magnitude slot carries `minimum`/`maximum` when the source also declared `:numeric`; the unit slot carries an `enum` of the allowed unit strings.
- `unevaluatedProperties: false` — closes discriminated and exclusive-group forms whose overlays live inside `allOf` branches.
- `$ref` into `#/$defs/form.<plugin>.<name>` — head-set alternatives, top-level `oneOf`. In `--layout=per-plugin`, cross-plugin refs become `./<other>.schema.json#/$defs/form.<other>.<head>` relative file paths.
- `minimum`/`maximum`/`exclusiveMinimum`/`exclusiveMaximum`/`multipleOf`/`minLength`/`maxLength`/`pattern`/`format` — numeric and string bounds emitted natively.
- `dependentRequired` — key dependencies (`:requires`) emitted natively.

### TypeScript `.d.ts`

One declaration file per export, with:
- A small **prelude** declaring `Keyword<S>`, `Symbol_<S>`, `SjonDate`, `SjonTime`, `SjonExpr<T>`, and `CrossRef<TargetForm, S>` — branded primitives that round-trip through canonical JSON.
- One `interface <Plugin>_<Form> { … }` per simple form, or one `type <Plugin>_<Form> = | { … } | { … }` per discriminated form.
- A per-plugin barrel: `export type Sjon<Plugin> = Form1 | Form2 | …;`.

### Intermediate IR (`--target=intermediate`)

A self-describing JSON document mirroring `SchemaExport.Model` 1:1. Stable enough to be the basis for downstream codegen targeting languages SJON doesn't ship; useful when neither JSON Schema nor TS is the right pivot.

### Markdown reference pages (`--target=markdown`)

Human-facing reference documentation rendered from the same descriptors
that drive editor hover — forms with key tables, positional specs (plus a
Head/Count table when the slot's head-set carries counts, written in prose:
"exactly 1", "at most 1", "any"), variants and local forms, value kinds
with member tables (deprecations carry their message), and expression
functions with signatures. Asked for by name, never part of `both`.
`--layout=per-plugin` with `--output=DIR` writes one `<plugin>.md` per
plugin. Excerpt from the
`shapes` reference (`examples/plugins/shapes.md.golden` is the full
pinned page):

```markdown
### `(circle …)`

Filled circle at :center with given :radius.

| Key | Type | Required | Default | Constraints |
| --- | --- | --- | --- | --- |
| `:center` | `vector<any>` | no | — | — |
| `:radius` | `number` | no | — | — |
| `:fill` | `symbol enum` | no | — | one of: `evenodd`, `nonzero` |
```

The IR also carries the full warning list. Use it as the canonical surface for SJON-aware tooling.

## Mapping reference

Every construct lands in one of three buckets:

- **[ENFORCED]** — JSON Schema validates the constraint at parse time. A consumer running Ajv 2020 against the schema will reject violations.
- **[ANNOTATED]** — JSON Schema carries an `x-sjon-…` annotation so SJON-aware tooling can see the constraint, but JSON Schema validators ignore it.
- **[DOCS-ONLY]** — Only documentation (JSDoc, descriptions). No machine-checkable constraint at all.

### Primitives

| SJON | JSON Schema | TS | Bucket |
|---|---|---|---|
| `nil` | `{type: "null"}` | `null` | ENFORCED |
| `boolean` | `{type: "boolean"}` | `boolean` | ENFORCED |
| `number` | `{type: "number"}` | `number` | ENFORCED |
| `number_i64` | `{type: "integer", x-sjon-int-width: "i64"}` | `bigint` | ENFORCED + ANNOTATED |
| `number_u64` | `oneOf:[{type:"integer"},{type:"string",pattern:"^[0-9]+$"}]` | `bigint` | ENFORCED (values > 2^53 ride the string arm) |
| `string` | `{type: "string"}` | `string` | ENFORCED |
| `keyword` | `{type:"object", required:["$kw"], properties:{$kw:{type:"string"}}, additionalProperties:false}` | `Keyword<S>` | ENFORCED (envelope shape only) |
| `symbol` | `{type:"object", required:["$sym"], properties:{$sym:{type:"string"}}, additionalProperties:false}` | `Symbol_<S>` | ENFORCED (envelope shape only) |
| `date` | `{type:"object", required:["$date"], properties:{$date:{pattern, format:"date"}}, additionalProperties:false}` | `SjonDate` | ENFORCED |
| `time` | `{type:"object", required:["$time"], properties:{$time:{pattern, format:"time"}}, additionalProperties:false}` | `SjonTime` | ENFORCED |

### Vectors

| SJON | JSON Schema | TS | Bucket |
|---|---|---|---|
| Untyped vector | `{type: "array"}` | `unknown[]` | ENFORCED (just the array shape) |
| Typed (`:element E`) | `{type:"array", items:<E>}` | `Array<E>` | ENFORCED |
| Fixed-length (`:len N`) | `{type:"array", items:<E>, minItems:N, maxItems:N}` | `readonly [E, E, …]` | ENFORCED |
| Variable-arity (`:min-len M`, `:max-len N`) | `{type:"array", items:<E>, minItems:M, maxItems:N}` (either bound omittable for an open end) | `Array<E>` (TS can't express the count bound) | ENFORCED (schema) + DOCS-ONLY (TS widens to `Array<E>`) |

### Forms

| SJON | JSON Schema | TS | Bucket |
|---|---|---|---|
| Closed form | `{type:"object", properties, required, additionalProperties:false}` | `interface … { … }` | ENFORCED |
| Open form | `{… additionalProperties:true}` | `interface … { …; [key: string]: unknown }` | ENFORCED + TS soundness gap (TS lets you assign to `$form`) |
| `$$`-escape on a `$`-prefixed user key | property name doubled (`$foo` → `$$foo`) | quoted property name `"$$foo"` | ENFORCED |
| Positional `.none` | no `$children` property | no `$children` field | ENFORCED |
| Positional `.any` | `properties.$children:{type:"array"}` | `$children?: unknown[]` | ENFORCED |
| Positional `.kind(K)` | `properties.$children:{type:"array", items:<K>}` | `$children?: Array<K>` | ENFORCED |
| Positional `.kind(K)` where `K`'s head-set carries counts | the above **plus** `$children.allOf:[{contains:<$ref>, minContains, maxContains}, …]`, one entry per bounded head | `$children?: Array<K>` with a `/** Positional counts (not expressible in TS): … */` comment | ENFORCED (schema) + DOCS-ONLY (TS) |

### Member sets

| SJON | JSON Schema | TS | Bucket |
|---|---|---|---|
| Compact symbol enum | `{enum:[{"$sym":"a"},…]}` | `Symbol_<"a"> \| Symbol_<"b">` | ENFORCED |
| Compact string enum | `{enum:["a","b"]}` | `"a" \| "b"` | ENFORCED |
| Rich symbol enum | `{oneOf:[{const:{"$sym":"a"}, title, description, deprecated?, x-sjon-deprecation-message?}, …]}` | branded union + JSDoc `@member …` per arm | ENFORCED + ANNOTATED + DOCS-ONLY |
| Rich string enum | `{oneOf:[{const:"a", title, description, …}, …]}` | string-literal union + JSDoc `@member …` per arm | ENFORCED + ANNOTATED + DOCS-ONLY |
| Digit-leading members (`1d`, `2d-array`) | `{oneOf:[{const:{"$num":[1,"d"]}}, …]}`; a numeric spelling routes the whole set through the rich per-member path even when no member carries metadata | `readonly [1, "d"] \| readonly [2, "d-array"]` | ENFORCED |
| Mixed set (digit-leading + ordinary) | each member keeps its own wire shape: `{"$num":[…]}` consts beside `{"$sym":"…"}` consts | `readonly [2, "d"] \| Symbol_<"cube">` | ENFORCED |

A digit-leading member is a `number_with_unit` on the wire (LANGUAGE.md §6.5), so an `enum` of `{"$sym":"2d"}` would reject every document the validator accepts. That is why the const pins `$num`. Markdown is the one target the spelling does not move: it renders `one of: 1d, 2d, 3d`, which is what an author types.

### Discrimination and overlay

| SJON | JSON Schema | TS | Bucket |
|---|---|---|---|
| Discriminated form (`:discriminant <key>` + `(variant :when … …)`) | `allOf:[{if:{properties:{<disc>:{const:{"$sym":"<when>"}}}, required:[<disc>]}, then:{properties:{…}, required:[…]}}, …]` + `unevaluatedProperties:false` + `x-sjon-discriminant:{key, variants}` | `type X = \| {… disc: Symbol_<"a"> …} \| {…}` | ENFORCED + ANNOTATED |
| Source-order rule (variant keys must follow the discriminant) | — | — | NOT ENFORCEABLE; the warning `variants_emitted_via_if_then` records the limitation. |

### Exclusive groups

| SJON | JSON Schema | TS | Bucket |
|---|---|---|---|
| `exactly_one [a, b, c]` (single-key bundles) | `oneOf:[{required:["a"]}, {required:["b"]}, {required:["c"]}]` | `@sjon-exclusive-group exactly-one [a, b, c]` JSDoc | ENFORCED (schema) + DOCS-ONLY (TS) |
| `at_most_one [a, b]` (N=2) | `not:{allOf:[{required:["a"]}, {required:["b"]}]}` | same JSDoc | ENFORCED (schema) |
| `at_most_one [a, b, c]` (N≥3) | `not:{anyOf:[{allOf:[…]}, …]}` pairwise | same JSDoc | ENFORCED (schema) |
| Multi-key bundles (`(alt :keys [from to])` xor `(alt :keys [at])`) | each bundle becomes one `{required:[<bundle>]}` entry — bundle "present" iff every key in `required` is present | same JSDoc | ENFORCED (schema, all-or-nothing per JSON Schema's `required` semantics) |

### Numeric and string bounds

| SJON | JSON Schema | TS | Bucket |
|---|---|---|---|
| `:numeric (numeric-bounds :min N :max M)` | `minimum:N, maximum:M` | JSDoc `@minimum`/`@maximum` | ENFORCED (schema) + DOCS-ONLY (TS) |
| `:exclusive-min true` / `:exclusive-max true` | `exclusiveMinimum` / `exclusiveMaximum` instead of `minimum`/`maximum` | JSDoc `@exclusiveMinimum`/`@exclusiveMaximum` | ENFORCED (schema) + DOCS-ONLY (TS) |
| `:integer true` | lifts to `type: "integer"` | JSDoc `@sjon-integer true` | ENFORCED (schema) |
| `(key … :requires [b c])` | `dependentRequired: {"<key>": ["b", "c"]}` — an exact semantic match: 2020-12's `dependentRequired` is "if this property is present, these must be too" | JSDoc `@sjon-requires b, c` (a plain interface cannot express it — it would need a discriminated union over which keys are present) | ENFORCED (schema) + DOCS-ONLY (TS) |
| `:multiple-of N` | `multipleOf: N` — an exact semantic match, not an annotation: 2020-12's `multipleOf` is "division by this keyword's value results in an integer", the same claim SJON makes | JSDoc `@sjon-multiple-of N` (TS has no divisibility constraint) | ENFORCED (schema) + DOCS-ONLY (TS) |
| `:repr (repr-shape :type f32…f16)` | base `{type: "number"}` + `x-sjon-gpu-repr: "<tag>"` (the GPU range / integrality is **not** lowered to `minimum`/`maximum`/`type:integer` — generic validators ignore it) | branded alias `F32` … `F16` (from the prelude) | ANNOTATED + DOCS-ONLY (enforced by the SJON validator, not by the exported schema) |
| Exact-int bound `>2^53` | `minimum`/`maximum` carries the lossy f64 value; `x-sjon-exact-bound: {min|max: "<digits>"}` carries the full-precision digit string | JSDoc note `[exact-int >2^53]` | ENFORCED (lossy in non-bigint validators) + ANNOTATED |
| `:string-bounds (string-bounds :min-len M :max-len N :pattern …)` | `minLength`/`maxLength` (codepoint count via `x-sjon-length-unit: "codepoint"`); `pattern` (with `x-sjon-pattern-engine: "deferred-in-sjon-runtime"` because SJON v1 doesn't execute regex) | JSDoc `@minLength`/`@maxLength`/`@pattern` | ENFORCED (schema; regex engine differs) + DOCS-ONLY (TS) |
| `:format email|uri|uuid` | JSON Schema standard `format` | JSDoc `@format` | ENFORCED (JSON Schema validators decide assertion vs annotation per format) |
| `:format path|semver` | `x-sjon-format` (not JSON Schema standard) | JSDoc `@format path|semver` | ANNOTATED + DOCS-ONLY |

### Unit-bearing numbers

| SJON | JSON Schema | TS | Bucket |
|---|---|---|---|
| `:unit (unit-shape :allowed [deg rad])` | `{type: "object", required: ["$num"], properties: {$num: {type: "array", prefixItems: [<magnitude>, <unit-enum>], minItems: 2, maxItems: 2, items: false}}}` | `[number, "deg"] \| [number, "rad"]` | ENFORCED |
| `:unit (unit-shape :required false)` | unit slot is `{type: "string", minLength: 1}` (any non-empty unit) | `[number, string]` | ENFORCED |
| Unit + `:numeric` bounds combined | bounds propagate to the magnitude slot inside `prefixItems[0]` | JSDoc `@sjon-unit … @minimum … @maximum …` | ENFORCED + DOCS-ONLY |
| `:unit (unit-shape :reject true)` | no `$num` tuple at all — lowers to a plain number / `number_bounded` (units are forbidden, so the magnitude stands alone) | `number` (or its branded `:repr` alias) | ENFORCED |

### Cross-refs

| SJON | JSON Schema | TS | Bucket |
|---|---|---|---|
| `:cross-ref (cross-ref :target T :name-key K)` | `{type: "object", required: ["$sym"], properties: {$sym: {type: "string"}}}` (envelope only) + `x-sjon-cross-ref: {target-form: T, name-key: K, acyclic: false}` | `CrossRef<"T">` brand + JSDoc `@sjon-cross-ref target=T name-key=K acyclic=false` | ENFORCED (envelope) + ANNOTATED + DOCS-ONLY |
| `:cross-ref (cross-ref :target [A B] :name-key K)` (target group) | same envelope + `x-sjon-cross-ref: {target-forms: ["A", "B"], name-key: K, acyclic: false}`. The singular `target-form` key is **absent**, so a consumer that only knows it finds nothing rather than reading a group as one target | `CrossRef<"A"> \| CrossRef<"B">` + JSDoc `@sjon-cross-ref target=A \| B name-key=K acyclic=false` | ENFORCED (envelope) + ANNOTATED + DOCS-ONLY |
| `:acyclic true` | annotation `acyclic: true` | JSDoc `acyclic=true` | ANNOTATED + DOCS-ONLY |
| `:scope <form>` | annotation `scope-form: "<form>"` | JSDoc `scope-form=<form>` | ANNOTATED + DOCS-ONLY |
| `:provider P :source-key K` | annotations `provider: "P"`, `source-key: "K"` | JSDoc `provider=P source-key=K` | ANNOTATED + DOCS-ONLY |

None of the membership / cycle / scope rules are enforceable by JSON Schema; the `cross_ref_annotation_only` info warning lands per-slot.

A target group is one namespace over several forms, where a union over two cross-ref kinds is two namespaces (LANGUAGE.md §6.5). The export tells them apart: a group is one slot schema carrying one `x-sjon-cross-ref` with `target-forms`, while a union is an `anyOf` of two slots, each carrying its own singular annotation. The TypeScript type is the same union either way, since TS has no way to say "one namespace".

### Head-sets and unions

| SJON | JSON Schema | TS | Bucket |
|---|---|---|---|
| Head-set (`:heads [a b]`) | `{oneOf:[{$ref:"#/$defs/form.<plugin>.<head>"}, …], x-sjon-head-set:[…]}` | `{readonly $form: "a"} \| {readonly $form: "b"}` | ENFORCED + ANNOTATED |
| Union (`:union (union-shape :alternatives [a b])`) | `{anyOf:[<schema-a>, <schema-b>], x-sjon-union-alternatives:["a", "b"]}` | `<a-type> \| <b-type>` | ENFORCED (acceptance) + ANNOTATED (first-match dispatch order) |
| `scalar-or-ref` shorthand (`:underlying scalar-or-ref` + `:scalar-or-ref (… :base B)`) | desugars to `union [B symbol]` at load, then exports as any union does: `{anyOf:[<B>, <symbol envelope>], x-sjon-union-alternatives:["B", "symbol"]}` | `<B-type> \| Symbol_` | ENFORCED (acceptance) + ANNOTATED |
| …with `:ref R` naming the reference half | desugars to `union [B R]`, so the second alternative exports as whatever kind `R` is. With `R` a cross-ref kind: `{anyOf:[<B>, <$sym envelope + x-sjon-cross-ref>], x-sjon-union-alternatives:["B", "R"]}` | `<B-type> \| CrossRef<"<target>">`; the checked reference reaches the `.d.ts` with no export-side code | ENFORCED (acceptance) + ANNOTATED |
| First-match dispatch order | — | — | NOT EXPOSED — `anyOf` accepts as long as one alternative matches; the SJON validator picks the first one. |
| Union over two cross-ref kinds | `{anyOf:[<$sym envelope + x-sjon-cross-ref A>, <… B>], …}` | `CrossRef<"A"> \| CrossRef<"B">` | ENFORCED (envelope) + ANNOTATED — both targets survive into the type, and each branch keeps its own `x-sjon-cross-ref`. What does *not* survive is `union_ambiguous`: it is a document-time observation (this name is registered in both targets), and export has no document. |
| Slot-local forms (`(key … :type form (form …) …)`) | `{anyOf:[<inline form-a>, …, {type:"object", required:["$form"]}], x-sjon-local-forms:[…]}` | `<inline-a> \| … \| { readonly $form: string }` | ENFORCED (acceptance) + ANNOTATED |

### Slot-local forms

A `:type form` slot carrying inline `local_forms` (LANGUAGE.md §6.3.1) lowers to an **inline anonymous union** — not a `$ref` set, because locals have no global `$defs` entry. Each local form's full body is emitted *in place* (so a discriminated local keeps its `if/then` chain and a nested local slot expands recursively), followed by a **trailing open generic branch** (`{type:"object", required:["$form"]}` in JSON Schema, `{ readonly $form: string }` in TS) standing in for the additive global fallback. It is `anyOf`, not `oneOf`: the open branch overlaps every specific branch, so exactly-one would always fail (the same reason the union mapping uses `anyOf`). The accepted local names ride as the `x-sjon-local-forms` annotation; the local-first/global resolution order is SJON-only. An `info` warning (`local_forms_emitted_inline`) records the lowering per slot.

### Defaults

| SJON | JSON Schema | TS | Bucket |
|---|---|---|---|
| Literal default (string/number/symbol/boolean/nil/vector) | `default: <wire-encoded>` | JSDoc `@default …` (not emitted) | ENFORCED (presence) |
| Expression default (`:default (some-expr …)`) | `x-sjon-default-expression: {head, namespace?, arg-count}` | JSDoc `@default computed via <head>` | ANNOTATED + DOCS-ONLY |

## Lossiness budget

Constructs SJON validates but JSON Schema cannot enforce. The exporter still emits an annotation so SJON-aware tooling can see the intent, but a JSON Schema validator running standalone won't catch these violations:

| Construct | What's not enforced | Annotation |
|---|---|---|
| Cross-references | Closed-set membership ("symbol must be one of the names declared elsewhere"). | `x-sjon-cross-ref.target-form` (or `target-forms` for a group) + `name-key` |
| Target groups | That the listed forms share one namespace, so a name declared by two of them is an error (`duplicate_cross_ref_target`). The exported envelope is the same `{$sym}` object a single target gets. | `x-sjon-cross-ref.target-forms` |
| `acyclic: true` cross-refs | Cycle detection. | `x-sjon-cross-ref.acyclic: true` |
| `scope-form` cross-refs | Lexical scoping of the cross-ref registry. | `x-sjon-cross-ref.scope-form` |
| Expression slots / defaults | Expression evaluation and result type. | `x-sjon-expr`, `x-sjon-default-expression` |
| Discriminated variants | Source-order constraint (variant keys must follow the discriminant). | `x-sjon-discriminant` |
| Multi-key exclusive bundles | Atomic bundle presence — JSON Schema's `required` enforces presence but not "partial bundle is an error." Partial bundles fail validation as `oneOf` mismatch, not as a specific partial-bundle diagnostic. | `x-sjon-exclusive-groups` |
| Numeric bound `>2^53` precision | f64 round-trip loses bits — `minimum`/`maximum` carries the lossy value, non-bigint validators see it as approximate. | `x-sjon-exact-bound: {min|max: "<digits>"}` |
| GPU representation (`:repr`) | The GPU type's range and integrality — the exporter does **not** lower them to `minimum`/`maximum`/`type:integer`, so a standalone validator accepts an out-of-range or fractional value the SJON validator rejects (`repr_out_of_range`). | `x-sjon-gpu-repr: "<tag>"` |
| String length encoding | JSON Schema validators count UTF-16 code units; SJON counts codepoints. Diverges on surrogate pairs. | `x-sjon-length-unit: "codepoint"` |
| String pattern regex engine | SJON v1 doesn't execute regex; JSON Schema validators run their own engine (usually ECMAScript). | `x-sjon-pattern-engine: "deferred-in-sjon-runtime"` |
| Custom string formats (`path`, `semver`) | JSON Schema's `format` vocabulary doesn't list these. | `x-sjon-format: "path|semver"` |
| Lowering hooks | Hook output validation. | `x-sjon-lowering` |
| Positional flag-sets (`:positional (flag-set …)`) | Closed-set membership for positional keyword flags — `$children` widens to a plain array, so JSON Schema can't express "a keyword flag drawn from this closed set" (nor reject a repeat). | `x-sjon-positional-flags: [{name, description?, link?}, …]` |
| Per-head positional counts, in TypeScript | "exactly one element of this union in an array" — no tuple or template construction reaches a per-member count over a heterogeneous array, so the `.d.ts` accepts child lists the SJON validator rejects (`positional_too_many` / `positional_missing`). JSON Schema *does* enforce it, via `contains`; this row is the TS half only. | `/** Positional counts (not expressible in TS): vertex: 1; fragment: 0..1 */` above `$children` |
| Slot-local forms (open branch) | Local-first resolution, shadowing, and a local's required keys — the inline union's trailing open branch accepts any `{$form}` object, so an under-specified or out-of-set local still validates. | `x-sjon-local-forms: […]` |
| Plugin version pinning | — | (none — out of scope) |
| Comment / trivia preservation | — | (canonical JSON drops trivia) |

Tooling that wants strict parity should run `Host.validateDocument` from SJON itself; the exporter is for downstream surfaces that don't carry the SJON validator.

## Examples

### `shapes` — head-set, open form, compact members

Inputs come from `examples/plugins/shapes.zig`. The `(badge …)` form has a `:shape` key whose value-kind `shape-form` head-set restricts the accepted heads to `circle` and `rect`:

```jsonc
// excerpt — examples/plugins/shapes.schema.json.golden
"form.shapes.badge": {
  "type": "object",
  "properties": {
    "$form": { "const": "badge" },
    "$ns":   { "const": "shapes" },
    "label": { "type": "string" },
    "shape": {
      "oneOf": [
        { "$ref": "#/$defs/form.shapes.circle" },
        { "$ref": "#/$defs/form.shapes.rect" }
      ],
      "x-sjon-head-set": ["circle", "rect"]
    }
  },
  "required": ["$form"],
  "additionalProperties": false
}
```

```typescript
// excerpt — examples/plugins/shapes.d.ts.golden
export interface Shapes_Badge {
  $form: "badge";
  $ns: "shapes";
  label?: string;
  shape?: { readonly $form: "circle" } | { readonly $form: "rect" };
}
```

### `kit` — discriminated variants

The `(track …)` form has a `:kind` discriminant over `{kick, bass, hat}`. Each variant adds its own overlay keys:

```jsonc
// excerpt — examples/plugins/kit/kit.schema.json.golden
"form.kit.track": {
  "type": "object",
  "properties": { "$form": …, "$ns": …, "kind": …, "name": … },
  "required": ["$form", "name", "kind"],
  "allOf": [
    {
      "if": { "properties": { "kind": { "const": { "$sym": "kick" } } }, "required": ["kind"] },
      "then": {
        "properties": { "step": { "type": "number" }, "volume": { "type": "number" }, … },
        "required": ["step"]
      }
    },
    {
      "if": { "properties": { "kind": { "const": { "$sym": "bass" } } }, "required": ["kind"] },
      "then": {
        "properties": { "sequence": { "type": "array", "items": {} }, … },
        "required": ["sequence"]
      }
    }
    // … one entry per variant …
  ],
  "unevaluatedProperties": false,
  "x-sjon-discriminant": { "key": "kind", "variants": [ …declaration-order list… ] }
}
```

```typescript
// excerpt — examples/plugins/kit/kit.d.ts.golden
export type Kit_Track =
  | {
      $form: "track";
      $ns: "kit";
      kind: Symbol_<"kick">;
      name: Symbol_;
      step: number;
      volume?: number;
      "downbeat-volume"?: number;
    }
  | {
      $form: "track";
      $ns: "kit";
      kind: Symbol_<"bass">;
      name: Symbol_;
      sequence: Array<unknown>;
      gain?: number;
    }
  // …
```

A consumer narrows on the discriminant brand:

```typescript
function tick(t: Kit_Track) {
  if (t.kind.$sym === "kick") t.step;       // narrowed
  if (t.kind.$sym === "bass") t.sequence;   // narrowed
}
```

### `kit-xor`, `audio`, `enum-rich`

See `examples/plugins/kit-xor/`, `examples/plugins/audio/`, and `examples/plugins/enum-rich/` for full-document golden references covering exclusive groups, unions, and rich member-sets respectively.

### `bounds` — numeric + string bounds

`examples/plugins/bounds/` declares value-kinds for inclusive/exclusive numeric ranges, integer-only counts, an exact-int bound above 2^53 (triggers `x-sjon-exact-bound`), plus string bounds with all five formats (`email`, `uri`, `path`, `uuid`, `semver`) and a length+pattern combination.

### `units` — unit-bearing numbers

`examples/plugins/units/` exercises `:unit (unit-shape :required true :allowed […])` with the bounded-magnitude case (a `0deg..360deg` angle whose magnitude bound rides inside `prefixItems[0]`).

### `head-counts` — per-head positional counts

`examples/plugins/head-counts/` declares a head-set whose entries carry `:min` / `:max` (`vertex` exactly once, `fragment` at most once, `constant` unbounded) and puts the same kind on three slots: a positional slot, a keyed slot where the counts ride along inertly, and an open form where they still fire. The bounded slot emits one `allOf` entry per bounded head (`{contains: {$ref: …}, minContains, maxContains}`) beside the plain `items`. The unbounded head gets no entry, so a document may carry any number of `(constant …)`; `minItems`/`maxItems` would have rejected exactly that, which is why they are the wrong keyword here. `hosts/web` compiles this schema under ajv and drives it over the same documents the validator judges, so the encoding is checked rather than asserted.

### `dimensions` — digit-leading enum members

`examples/plugins/dimensions/` is the WebGPU case: `GPUTextureDimension` is spelled `1d`, `2d`, `3d`, and `GPUTextureViewDimension` mixes those with ordinary members (`cube`, `cube-array`) and one hyphenated spelling (`2d-array`). The compact `:values [1d 2d 3d]` form and the rich `(member …)` form both export as a per-member `oneOf`, each digit-leading member pinned to `{"$num": [<magnitude>, "<unit>"]}`. The `.d.ts` reads `readonly [1, "d"] | readonly [2, "d"] | readonly [3, "d"]`.

### `scalar-or-ref` — the shorthand, checked and unchecked

`examples/plugins/scalar-or-ref/` declares both halves of the contrast: `(scalar-or-ref-shape :base dim-value)`, whose reference half is the primitive `symbol`, and `(scalar-or-ref-shape :base dim-value :ref define-ref)`, whose reference half is a cross-ref kind. The difference is invisible on a correct document and visible on a misspelling, which is why the fixture ships both. It is also visible in the export with no export-side code: the first slot is `number | Symbol_`, the second `number | CrossRef<"define">`.

### `xref` — cross-refs in five flavours

`examples/plugins/xref/` declares a bare cross-ref, an acyclic cross-ref (with a self-edge through `(node :parent ...)`), a scope-form-scoped cross-ref pointed at `(piece …)` as the registry root, a provider-route cross-ref reading `(shader :code …)` through the `uniforms` provider, and a target group naming `(render-pipeline …)` and `(compute-pipeline …)` at once. All five produce identical wire shapes (a `{$sym: string}` object); the difference lands in the `x-sjon-cross-ref` annotation, which gains `provider` / `source-key` on the fourth and swaps `target-form` for `target-forms` on the fifth (both omitted elsewhere, like `scope-form`).

The group sits directly beneath a union over two cross-ref kinds pointed at the same two forms, so the fixture shows the two shapes side by side: two targets, one namespace or two. `example.sjon` carries both diagnostics that fall out. `duplicate_cross_ref_target` is an error at the declarations, because one namespace cannot hold the name twice; `union_ambiguous` is a warning at the reference, because two namespaces both hold it and declaration order picks.

The provider route is the one slot whose member set is not merely unenforceable but *unknowable* at export time — it does not exist until a host runs an extraction pre-pass over a document, which export has none of. `cross_ref_unenforceable`'s message says so. This fixture is also the only manifest-sourced one that emits a Markdown golden (`xref.md.golden`), which is how the CLI-only Markdown renderer gets covered against a real manifest rather than only the static `shapes` plugin.

### `xkey` — multi-key exclusive-group bundles

`examples/plugins/xkey/` declares `(route :from … :to … :at …)` with `exactly_one [(from to), at]` and `(tag :prefix … :suffix … :literal …)` with `at_most_one [(prefix suffix), literal]`. Each bundle becomes one `{required: [<bundle>]}` entry inside `oneOf` (or `not:{allOf}` pair for `at_most_one`).

### `pair-a` + `pair-b` — cross-plugin `$ref`

`examples/plugins/pair-a/` declares `(palette :primary … :accent …)` whose slots are a head-set unioning over `(color …)` and `(gradient …)` declared in `pair-b`. The aggregated emit folds both plugins into one schema; the per-plugin emit (run via `sjon export-schema … --layout=per-plugin`) produces:

```jsonc
// excerpt — examples/plugins/pair-a/pair-a.schema.json.golden
"primary": {
  "oneOf": [
    { "$ref": "./pair-b.schema.json#/$defs/form.pair-b.color" },
    { "$ref": "./pair-b.schema.json#/$defs/form.pair-b.gradient" }
  ],
  "x-sjon-head-set": ["color", "gradient"]
}
```

```typescript
// excerpt — examples/plugins/pair-a/pair-a.d.ts.golden
import type { PairB_Color } from "./pair-b";
import type { PairB_Gradient } from "./pair-b";

export interface PairA_Palette {
  $form: "palette";
  $ns: "pair-a";
  accent?: PairB_Color | PairB_Gradient;
  name: Symbol_;
  primary: PairB_Color | PairB_Gradient;
}
```

## Per-plugin layout

`--layout=per-plugin` emits one set of files per plugin:

```
<output-dir>/
├── index.d.ts           # barrel: `export * from "./<plugin>"` per plugin
├── pair-a.schema.json
├── pair-a.d.ts
├── pair-a.export.json
├── pair-b.schema.json
├── pair-b.d.ts
└── pair-b.export.json
```

Cross-plugin form-head references resolve via:

- **JSON Schema**: `{"$ref": "./pair-b.schema.json#/$defs/form.pair-b.color"}` — relative file paths so a downstream `ajv` invocation with `--all-errors` and `--strict=false` can load every file.
- **TypeScript**: `import type { PairB_Color } from "./pair-b";` at the top of each consuming file, plus the union form expression uses the imported type name directly: `accent?: PairB_Color | PairB_Gradient;`. Duplicate imports across slots dedupe.

Warnings on the aggregated emit list scope to one plugin or carry `plugin: null` (multi-plugin issues). The per-plugin emit filters each plugin's warning list to entries matching that plugin name, plus the global ones.

## Calling the exporter

The exporter ships on every supported host. Pick the one that matches your tooling:

### CLI

```
sjon export-schema myplugin.sjon --target=both --output=./out
```

`--target` ∈ `json-schema | typescript | both | intermediate | markdown`; `--layout` ∈ `aggregated | per-plugin`; `--draft=2020-12` is the only accepted draft. Aggregate diagnostics + export warnings print to stderr; artifacts go to stdout (with `--output=-`) or files under `--output=DIR`.

### Node (`hosts/web/`)

```js
import { SjonHost } from "./hosts/web/SjonHost.ts";
const host = await SjonHost.load("./zig-out/bin/sjon.wasm");
const result = host.exportSchema(source, {
  target: "json-schema",     // or "typescript" | "both" | "intermediate"
  layout: "aggregated",      // or "per-plugin"
  draft: "2020-12",
});
// result.aggregated.jsonSchema is a string; JSON.parse to inspect.
// result.warnings carries the export warnings.
// result.hostDiagnostics carries the aggregate-phase host diagnostics.
```

The `result` envelope: `{layout, hostDiagnostics, loadedPlugins, warnings, aggregated, perPlugin}`. `aggregated` is `{jsonSchema, tsTypes, intermediate}` when `layout === "aggregated"`; `perPlugin` is an array `[{plugin, jsonSchema, tsTypes, intermediate}]` when `layout === "per-plugin"`.

### Rust (`hosts/rust/`)

```rust
use sjon_host::{SjonHost, ExportSchemaOptions, ExportTarget, ExportLayoutOption};

let mut host = SjonHost::load("./zig-out/bin/sjon.wasm", None)?;
let result = host.export_schema(source, &ExportSchemaOptions {
    target: ExportTarget::JsonSchema,
    layout: ExportLayoutOption::Aggregated,
    ..Default::default()
})?;
```

The result types live in `sjon_host::{ExportSchemaResult, AggregatedArtifacts, PerPluginArtifact, ExportWarning}`.

### TypeScript-parity (`hosts/typescript-parity/`)

```ts
import { exportSchema } from "./hosts/typescript-parity/src/Host.ts";

const { exportResult } = exportSchema(source, {
  projectRoot: null,
  projectFile: null,
  resolver: null,
}, {
  target: { jsonSchema: true, tsTypes: true },
  layout: "aggregated",
});
```

This is the *native* TS port (no WASM). Node and Rust route through `sjon_export_schema` on the WASM artifact and decode the envelope; the CLI and TS-parity hosts run the exporter natively in their respective runtimes. All four produce structurally equivalent schemas.

## Round-trip caveats

An ajv-2020 round-trip in `hosts/web/test/schema-export-roundtrip.test.ts` guards the exporter. The assertion is **one-way**: every document that validates clean under SJON (no `err`-severity diagnostics) must also validate clean under ajv. The reverse direction is not asserted — JSON Schema is intentionally looser per the [Lossiness budget](#lossiness-budget).

The test skips these categories (their semantics cannot be enforced by JSON Schema):

| Skip pattern | Reason |
|---|---|
| `cross-ref` / `xref` | Closed-set membership / `acyclic` / `scope-form` need SJON-aware runtime |
| `expr-*-binder`, `default-expr`, `plugin-eval` | Expression evaluation out of scope (only `$expr` envelope shape is enforced) |
| `plugin-exec` | Plugin executable invocation out of scope |
| `lowering` | Lowering-hook output is host-side; the schema can't observe it |
| `use-plugin` | Resolver-bound cases need project-file plumbing the test doesn't set up |
| `pair-a` | Cross-plugin head-set; the round-trip test loads only one plugin's manifest |

`local-forms` is **not** skipped — it round-trips because the inline union's trailing open branch (`{required:["$form"]}`) accepts any `{$form}` object, so every SJON-valid document passes ajv. The cost is the other direction: that open branch also accepts a *local* form that omits its required keys (`{$form:"circle"}` with no `:r`) — such an object still satisfies the open branch. So **slot-local required-key enforcement and local-first shadowing are SJON-runtime-only**: the exported schema documents the local shapes (and pins them for IntelliSense) but does not reject an under-specified local. This is consistent with the one-way assertion above.

## What's not in this exporter

The exporter is **canonical-mode only**. Compact JSON (`sjon to-json --compact`) collapses keyword/symbol/string into bare strings and drops unit suffixes — a schema written against compact JSON would accept bare strings where keywords are required. A future `--mode=compact` could land behind a loud warning, but it isn't planned.

The TS-parity port (`hosts/typescript-parity/src/schemaExport/`) does not yet parse the manifest syntax for discriminator + variants, exclusive groups, or `union_of` — the IR fields are wired but the loader leaves them null/empty until `loader.ts` catches up. Byte-for-byte parity with the Zig goldens on those constructs depends on that follow-up; structural emission is already at full parity for every other fixture.

## Versioning

Every emitted artifact carries the format version:

- JSON Schema: `"x-sjon-export-version": 1` on the top-level object.
- TypeScript: `// sjon-export-version: 1` on line 1.
- IR: `"version": 1` on the top-level object.

Breaking format changes bump the integer. There's no deprecation window — downstream consumers should re-run the exporter and re-diff after a bump.

## Reading further

- `src/SchemaExport/` — the implementation. Start at `SchemaExport.zig`'s `exportSchema` entry point.
- `src/SchemaExport/Model.zig` — the IR types consumed by both backends.
- `examples/plugins/*/plugin.sjon` + `*.golden` — locked reference outputs for every exporter construct.
- `docs/AUTHORING.md` — how to write a plugin (the upstream input to this exporter).
- `docs/LANGUAGE.md` — the SJON grammar and semantics.
- `docs/DESIGN.md` — the broader architecture (Lexer → Parser → SoA AST → Validator → Expr → Binary IR).
