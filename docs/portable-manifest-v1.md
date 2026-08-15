# Portable plugin manifests — v1 spec

> **Plugin Model v1 sub-spec.** This document defines the detailed
> portable manifest syntax under [`plugin-model-v1.md`](plugin-model-v1.md).
> It is not the whole plugin contract: static Zig plugins, WASM sidecars,
> and host-owned lowering are summarized there.
>
> The wire-form for SJON plugin descriptors. A manifest is itself a
> valid SJON document. Hosts in any language load manifests, then
> validate, lint, or autocomplete user documents without compiling Zig.
>
> Companion to `docs/LANGUAGE.md`, which covers SJON-the-data-language.
> This document covers SJON-the-vocabulary-format. The data shapes
> (`FormSpec`, `KeySpec`, `ValueKind`, `ExprFunc`) are the same — this
> spec just defines their on-disk syntax.

## Status

`v1` is the current portable manifest revision. The substrate it
serialises (`src/Plugin.zig`), the on-disk format, the bootstrap
meta-plugin (`manifests/meta.sjon`), the Zig loader, and cross-host
conformance fixtures are in place. This document is the syntax sub-spec;
the overall layer contract is [`plugin-model-v1.md`](plugin-model-v1.md).

## 1. Layering

Two cuts shape the format:

- **Substrate vs vocabulary.** SJON-the-data-language (parser, AST,
  binary IR, edit ops) ships as Zig today and is closed. Vocabularies —
  the forms, value kinds, and expression functions a particular domain
  uses — are first-class but external, and a manifest is what carries
  them.
- **Validation vs evaluation.** A manifest carries signatures and
  symbolic implementation references, never implementation bodies.
  Hosts that only need linting / completion / error messages (LSPs,
  web playgrounds, doc tooling) consume a manifest and stop there. Hosts
  that also evaluate expressions either use static Zig `ExprFunc.impl`
  hooks or bind `wasm:` references through the executable sidecar ABI —
  see §10 and `docs/executable-plugin-abi.md`.

This split keeps the format small. The wire-form has no execution
semantics to specify; it is *purely* a description of valid documents.

## 2. Scope

### 2.1 Includes

- Plugin metadata: `:name`, `:version`, `:description`.
- `value-kind` declarations with the current refinement axes:
  `vector-shape`, `unit-shape`, `numeric-bounds`, `string-bounds`,
  `member-set`, `head-set`, `cross-ref`, `union-of`, `repr-shape`,
  and the `scalar-or-ref-shape` shorthand.
- `form` declarations: keys, `:positional`, `:open`, discriminated
  variants, exclusive groups, and lowering metadata.
- `key` sub-forms: name, type, optional, default, and documentation.
- `expr-func` declarations in two encodings — *mono-signature*
  (`:arity` / `:params` / `:rest` / `:result` on the form) and
  *multi-signature* (one or more `(signature …)` positional children).
- Arity variants: `(fixed N)`, `(at-least N)`, `(range :min M :max N)`.
- Form-level lowering metadata via `(lowering …)`. The hook code is
  host-owned and never lives in the manifest.
- Free-text documentation (`:description`) on every declaration.

### 2.2 Deferred

- Package resolution, version matching, manifest imports.
- Custom validation predicates beyond the closed refinement set.
- Manifest-loaded host-native implementations (`host:` / `native:`).
  Static Zig plugins can use `ExprFunc.impl`; portable manifests cannot
  dynamically bind native host code in v1.
- Parametric typing (generics, subtyping). Concrete typed signatures
  only.
- Schema inheritance / composition beyond simple host-side aggregation.

### 2.3 Anti-patterns explicitly avoided

No document-side `(import …)`. No scene-bundling forms that pull
vocabularies into a document. Vocabulary discovery is a host concern,
not a document concern. The model is:

```
host loads:    core + shapes + masagin
host validates: my-document.sjon
```

Aggregation, ambiguity resolution, and load-order semantics live host-
side. Documents stay vocabulary-agnostic.

## 3. The `(plugin …)` form

A manifest is a single top-level `(plugin …)` form whose positional
children are declaration sub-forms (`(value-kind …)`, `(form …)`,
`(expr-func …)`, `(cross-ref-provider …)`).

```
(plugin :name shapes :version "1.0.0"
  :description "2-D shape primitives."

  (value-kind …)
  (form …)
  (expr-func …)
  (cross-ref-provider …)
  …)
```

Required keys: `:name` (symbol), `:version` (string).

Optional keys:

| Key            | Type                                | Notes                                                                                                       |
|----------------|-------------------------------------|-------------------------------------------------------------------------------------------------------------|
| `:description` | string                              | Free-form prose.                                                                                            |
| `:wasm-file`   | string                              | Manifest-dir-relative path to the paired wasm binary. Escapes outside the package emit `plugin_wasm_resolved_outside_package`. |
| `:wasm-sha256` | string (`sha256-<64 hex>`)          | Author's stamp of the published wasm bytes. The host verifies on load; mismatch → `plugin_wasm_self_hash_mismatch`. |
| `:authors`     | vector of symbols / strings         | Free-form attribution metadata.                                                                              |
| `:license`     | string (SPDX identifier)            | Non-canonical strings produce an advisory `license_unrecognized`.                                            |
| `:homepage`    | string                              | Informational URL.                                                                                           |
| `:repository`  | string                              | Informational URL.                                                                                           |
| `:keywords`    | vector of symbols                   | Soft cap at 16 entries; advisory `too_many_keywords` past that.                                              |
| `:sjon`        | string (`"1.0"` / `"1.1"` / …)      | Declared portable-manifest format version. Host emits `sjon_format_unsupported` when its max is lower.       |

`:wasm-sha256` is the **author's** stamp and is complementary to the
consumer-side `(use-plugin … :hash …)` pin. The lockfile (Pillar C of
the local-packaging plan) records the **observed** bytes at lock time.
Disagreement among the three produces distinct codes pointing at the
distinct sources: `plugin_wasm_self_hash_mismatch` (manifest),
`plugin_hash_mismatch` (use-plugin), `lockfile_drift` (lockfile).

Declaration order does not matter. Forward references between
declarations are resolved at load time.

## 4. `(value-kind …)` declarations

A value kind is a named refinement of one underlying primitive.

```
(value-kind :name <symbol>
  :underlying <number|string|symbol|vector|form|union|scalar-or-ref>
  :description <string>?
  :vector        (vector-shape …)?       ; only when :underlying is vector
  :unit          (unit-shape …)?         ; only when :underlying is number
  :numeric       (numeric-bounds …)?     ; only when :underlying is number
  :repr          (repr-shape …)?         ; only when :underlying is number
  :members       (member-set …)?         ; only when :underlying is symbol or string
  :heads         (head-set …)?           ; only when :underlying is form
  :cross-ref     (cross-ref …)?          ; only when :underlying is symbol
  :scalar-or-ref (scalar-or-ref-shape …)?) ; only when :underlying is scalar-or-ref
```

Each refinement axis is gated by exactly one underlying. Loaders reject
mismatched pairings (e.g. `:heads` on a `:underlying number`). The
load-closed axes (`:vector` / `:unit` / `:numeric` / `:repr` /
`:members` / `:heads`) fix their set at load time. `:cross-ref` is
the lone axis whose set is determined by the validated document —
every form whose head matches `:target` contributes its `:name-key`
value to the registry (see §4.6). `:scalar-or-ref` is not a base axis
but a **shorthand**: it desugars to a `:underlying union` at load (see §4.8).

### 4.1 `(vector-shape …)`

```
(vector-shape
  :len     <number>?              ; fixed element count; omit for any-length
  :min-len <number>?              ; inclusive floor on element count (variable arity)
  :max-len <number>?              ; inclusive ceiling on element count (variable arity)
  :element <type-ref>)            ; element kind; resolved through the catalog
```

Length is either **fixed** or **variable**, never both. A fixed `:len`
demands exactly that many elements (a miss is `vector_length_mismatch`).
Variable arity uses `:min-len` / `:max-len` instead — both inclusive,
either omittable for an open end; under-/over-long values surface as
`vector_too_short` / `vector_too_long`. Combining `:len` with
`:min-len`/`:max-len`, or declaring `:min-len > :max-len`, emits
`vector_bounds_invalid` at load.

### 4.2 `(unit-shape …)`

```
(unit-shape
  :required <bool>?               ; reject bare numbers when true (a unit is demanded)
  :reject   <bool>?               ; reject any unit suffix when true (bare numbers only)
  :allowed  <symbol-list>?)       ; closed set of allowed unit suffixes
```

`:reject true` is the opposite pole of `:required true`: it forbids
*any* unit suffix, so a unit-bearing value surfaces as `unit_forbidden`
and only bare numbers pass — closing the silent `1.0f → 0` GPU-backfill
defect. It is mutually exclusive with `:required` and with a non-empty
`:allowed`; either combination emits `invalid_manifest` at load.

### 4.3 `(numeric-bounds …)`

```
(numeric-bounds
  :min           <number>?         ; inclusive unless :exclusive-min true
  :max           <number>?         ; inclusive unless :exclusive-max true
  :exclusive-min <bool>?           ; require value strictly greater than :min
  :exclusive-max <bool>?           ; require value strictly less than :max
  :integer       <bool>?)          ; require integer-valued (rejects fractional & non-finite)
```

`:min` and `:max` accept any numeric literal, including unit-bearing
ones (`:min 0ms`). Bound vs value unit semantics are byte-equal with
no canonicalisation:

| Bound        | Value        | Behaviour                                   |
|--------------|--------------|---------------------------------------------|
| bare         | bare         | compare magnitudes                          |
| bare         | unit-bearing | compare magnitudes (unit's correctness is `:unit`'s job) |
| unit-bearing | unit-bearing | byte-equal units required, then magnitudes  |
| unit-bearing | bare         | `numeric_bound_unit_mismatch`               |

Bound vs value comparison preserves exact precision when both came
from integer literals (`Tag.number_i64` / `Tag.number_u64`); the
validator uses integer-space comparison so the 2^53 + 1 vs 2^53
off-by-one isn't lost to f64 round-trip. Bounds whose magnitude
exceeds 2^53 still round to the nearest f64 in storage — keep
bounds whole numbers below 2^53 when exact precision matters.

`:integer true` rejects NaN, ±inf, and any fractional f64 value.
Negative-zero passes: `floor(-0.0) == -0.0` in IEEE-754.

Load-time consistency checks emit `numeric_bounds_invalid`:

- `:exclusive-min true` with `:min` absent.
- `:exclusive-max true` with `:max` absent.
- `:min > :max` when both bounds share a unit (or both are
  unitless). Mixed-unit bounds defer to validate time, where they
  surface as `numeric_bound_unit_mismatch`.
- `:numeric` attached to a kind whose `:underlying` is not `number`.

Examples:

```sjon
(value-kind :name opacity :underlying number
  :numeric (numeric-bounds :min 0 :max 1))

(value-kind :name iteration-count :underlying number
  :numeric (numeric-bounds :min 1 :integer true))

(value-kind :name duration-ms :underlying number
  :unit    (unit-shape :required true :allowed [ms])
  :numeric (numeric-bounds :min 0ms :max 10000ms))
```

### 4.4 `(member-set …)`

```
; Compact — set-only declaration.
(member-set
  :values <symbol-list>)          ; closed set of allowed values

; Rich — per-member editor metadata.
(member-set
  (member :name <symbol>
          :label "<string>"               ; optional display label
          :description "<string>"         ; optional help text
          :deprecated <boolean>           ; optional, default false
          :deprecation-message "<string>") ; optional replacement hint
  …)
```

For `:underlying symbol`, the names are bare symbol identifiers (no
leading `:`). For `:underlying string`, the names are still bare
symbols whose textual content is matched against the string literal.

A `(member-set …)` may use the compact `:values [...]` shape OR the
rich `(member …)` shape, but not both — the loader emits
`invalid_manifest` on a mixed declaration. An empty `(member-set)`
(neither shape present) is also `invalid_manifest`, and two
`(member :name X)` siblings sharing `:name` are `invalid_manifest`
("duplicate member").

When a `Member` carries `:deprecated true`, the validator still
accepts the value (membership succeeds) but emits a
`deprecated_member` warning anchored on the value's span. The
`:deprecation-message` text, if present, appends to the warning's
prose ("member `X` is deprecated: <message>"); LSP clients also
render the completion item with `CompletionItemTag.Deprecated` and
expose `:label` / `:description` as completion `detail` / `documentation`.

### 4.5 `(head-set …)`

```
(head-set
  :names <symbol-list>)           ; closed set of allowed form heads
```

`(head-set …)` pins the form-as-slot discriminator (the form's head
symbol) to a closed set. Combined with the per-head `(form …)`
declaration, the validator selects the right `FormSpec` before walking
the children.

### 4.6 `(cross-ref …)`

```
(cross-ref
  :target   <symbol>              ; bare or qualified form name
  :name-key <symbol>?              ; key on target form to index by; default `name`
  :acyclic  <boolean>?             ; opt into cycle detection over self-edges
  :scope    <symbol>?)             ; per-form lexical scope; default tree-scoped
```

Pins a `:underlying symbol` value to the set of names declared by some
other form. The validator runs a descendant-DFS pre-pass over every
input tree: for every form whose canonical name matches `:target`, it
reads the kvpair named by `:name-key` and indexes that name. A symbol
value typed by the cross-ref kind is then checked against the registry;
misses surface as `not_cross_ref`.

`:target` resolves at schema-aggregation time via the same lookup as
qualified type references (`<ns>/<form>` is supported for namespace
disambiguation). The registry indexes by the canonical
`<plugin>/<form>` name — two plugins each declaring a form named
`phrase` register under distinct keys. Aggregation-time failures
surface as `unknown_cross_ref_target` or `ambiguous_cross_ref_target`;
a `:name-key` that doesn't exist on the resolved form (or whose value
type isn't `.symbol`) surfaces as `cross_ref_name_key_unknown`.

Two forms within the same scope declaring the same `(target, name)`
pair emit `duplicate_cross_ref_target` on the second by stable order
(`(tree_index, document-pre-order)` ascending). Forms whose
`:name-key` is missing or non-symbol-typed are silently skipped by
the indexer — their own slot-typed errors are the visible diagnostic;
cross-ref doesn't cascade.

**Scoping.** v1 enforces per-tree isolation by default — every input
tree is its own scope, so two pieces with phrases `p0` in each don't
collide and references resolve only against names declared in the same
tree. `:scope <form>` opts into a tighter lexical scope: each
instance of `<form>` (qualified or bare; resolved the same way as
`:target`) opens a fresh registry, references resolve only against
names defined inside the nearest enclosing instance, and a reference
that appears outside any matching enclosing form fires
`cross_ref_outside_scope`. `:scope` failures at aggregate time surface
as `unknown_cross_ref_scope` / `ambiguous_cross_ref_scope`. Cross-tree
opt-in (`:scope forest`) is reserved for v2.

`:cross-ref` walks descendants, not just roots — libraries nest under
`(piece …)`, etc. Vectors of cross-ref names compose the obvious way:

```sjon
(value-kind :name phrase-name
  :underlying symbol
  :cross-ref (cross-ref :target phrase :name-key name))

(value-kind :name phrase-sequence
  :underlying vector
  :vector (vector-shape :element phrase-name))
```

`:acyclic`, when set to `true`, asks the validator to detect cycles
among forms in the registry. Cycle edges are read from any key on the
target form whose declared `:type` resolves back to this cross-ref's
kind — directly (e.g. `:parent phrase-name`) or through one
vector hop (e.g. `:children phrase-name-list` where the list's
`:element` is `phrase-name`). On a cycle, every member emits
`cyclic_cross_ref` on its `:name`-value span (path empty, mirroring
`duplicate_cross_ref_target`). At schema-aggregate time, declaring
`:acyclic true` on a kind whose target form has no self-edge key
emits `acyclic_without_self_edge` — the flag would otherwise be
silently inert.

**The provider route.** `:provider <name>` replaces `:name-key` as the
source of member names: instead of reading one symbol off each target
instance, the validator hands the string under `:source-key` (default
`src`) to the named `(cross-ref-provider …)` and registers every name
the provider returns. The two routes are exclusive — a kind declares
one or the other. Because the member set is computed rather than read,
it can be *uncomputable*, and two validate-time codes say so at the
source instance's span: `cross_ref_extraction_failed` when the provider
ran and rejected the source, `cross_ref_provider_unavailable` when the
host could not run it (no executable runtime, missing export, plugin
execution compiled out). Either one **poisons** that bucket: references
into it are then left unchecked rather than reported as misses, so one
uncomputable source yields one diagnostic instead of a `not_cross_ref`
at every reference site. A host that cannot execute plugins therefore
validates everything else and stays silent about names it cannot know.

**One target, one member set.** A target form's members are collected
once, not once per referring kind, and the first `(cross-ref …)` in
plugin × value-kind order supplies the spec. So two kinds naming one
target and *disagreeing* — one route against the other, or different
`:name-key` / `:source-key` / `:provider` / `:scope` — means the
loser's declaration is inert and its references are checked against the
winner's names. That earns a schema-aggregate-time
`cross_ref_target_collapse` warning on the losing kind; two kinds
declaring the *same* spec on one target are ordinary aliasing and stay
silent.

#### The `(cross-ref-provider …)` declaration

The thing `:provider` names is a direct child of `(plugin …)`, sibling to
`(value-kind …)` and `(expr-func …)` rather than nested under the
cross-ref that uses it — one provider commonly backs several kinds, and
kinds in other plugins may name it as `<plugin>/<name>`.

```
(cross-ref-provider :name <symbol>
  :description <string>?          ; free-form prose, surfaced in tooltips
  :impl        <binding-ref>?)    ; "wasm:<export>" — see §10
```

`:name` is required. `:impl` follows §10's rules unchanged: `wasm:<name>`
binds the export described in the executable-plugin ABI §5.5 (one
`.string` in, a `.vector` of `.string` out), and static Zig plugins may
set the native `impl` directly instead. Both are absent on a
declaration-only provider, which is legal and is how a manifest describes
a vocabulary whose implementation ships elsewhere — the same latitude
`(expr-func …)` has. What differs from `expr-func` is the consequence:
an unimplemented expression function is simply not evaluated, while an
unrunnable provider must still say so at every source instance that
needed it (`cross_ref_provider_unavailable`), because staying quiet would
mean claiming a member set nobody computed.

Providers require `:sjon "1.2"`; a manifest declaring an older format
version is read by a host whose vocabulary predates the route.

**Determinism is the provider's obligation.** The same source bytes must
yield the same names in the same order on every host and every run. Order
is provider-chosen — it is not sorted for you — and it is observable:
registration order is what the index pass and the conformance corpus
pin. A provider that consults anything outside its argument (a clock, a
filesystem, a hash seed with per-process randomness) breaks the property
that makes a document's validity a property of the document.

### 4.7 `(repr-shape …)`

```
(repr-shape
  :type <f32|u32|i32|u16|f16>)   ; GPU machine type the number must fit
```

Only on `:underlying number`. Names the GPU type a downstream emitter
encodes the value as; the validator rejects a literal outside the type's
range — or non-integral under an integer type (`u32` / `u16` / `i32`) —
with `repr_out_of_range`, before the emitter would silently wrap the
bits. Orthogonal to `:unit` and `:numeric`; all three may co-exist. The
five tag names are wire-stable (append-only). Ranges: `u16` `[0, 65535]`,
`u32` `[0, 4294967295]`, `i32` `[−2147483648, 2147483647]`, and
`f32` / `f16` the signed magnitude of the IEEE type (no integrality
constraint). The check is range-only — *precision* narrowing (e.g.
`16777217` losing its low bit under `f32`) is the emitter's accepted
lossy step, not a validation failure.

```sjon
(value-kind :name u16-channel :underlying number
  :repr (repr-shape :type u16))
```

### 4.8 `(scalar-or-ref-shape …)`

```
(scalar-or-ref-shape
  :base <type-ref>)              ; the scalar alternative
```

A **shorthand**, not a base underlying. `:underlying scalar-or-ref` with
a `:scalar-or-ref (scalar-or-ref-shape :base <kind>)` slot desugars at
load to a `:underlying union` over `[<base>, symbol]` — so the stored
kind is an ordinary union and every consumer inherits its behaviour. It
captures "a literal `<base>` value, *or* a bare-symbol reference to one
defined elsewhere": a `<base>` value takes the scalar alternative, a
bare symbol the `symbol` alternative, and anything else fails with
`union_no_branch_matched`. Declaring `:underlying scalar-or-ref` without
the `:scalar-or-ref` slot — or a `:scalar-or-ref` slot on any other
underlying — emits `invalid_manifest` at load.

```sjon
(value-kind :name count-value :underlying number)
(value-kind :name count
  :underlying scalar-or-ref
  :scalar-or-ref (scalar-or-ref-shape :base count-value))
```

## 5. `(form …)` declarations

A form declaration says what `(name …)` looks like in user documents.

```
(form :name <symbol>
  :open       <bool>?             ; default false
  :positional <type-ref>|(flag-set …)?  ; positional child policy; omit for none
  :description <string>?

  (key …)*                        ; zero or more (key …) sub-forms
  (form …)*                       ; zero or more positional slot-local forms (§5.2)
  )
```

The sub-forms of a `(form …)` declaration include its `(key …)` slots
(§5.1) and inline `(form …)` **positional slot-local** definitions
(§5.2). An unrecognized sub-form head is rejected.

`:positional` interpretation:

| Manifest                  | In-memory `PositionalSpec` |
|---------------------------|---------------------------|
| `:positional` omitted     | `.none`                   |
| `:positional any`         | `.any`                    |
| `:positional <kind-name>` | `.kind = "<kind-name>"`   |
| `:positional (flag-set …)` | `.flag_set = {names}`     |

A `(flag-set …)` declares a closed set of allowed **positional keyword
flags** — the trailing valueless `:keyword` tokens the parser promotes
to positional children (LANGUAGE.md §5.4):

```
(form :name task
  :positional (flag-set
    (flag :name done)
    (flag :name archived)))
```

In a document, `(task :done)` carries `:done` as a positional flag. Flag
names are bare symbols, matched against the flag keyword's text with the
leading `:` stripped (`:done` ↔ `done`). A flag outside the set →
`not_flag_member`; a non-keyword positional in the slot (`(task 42)`) →
`wrong_underlying`. `:positional` is one policy per form — a flag-set
replaces `any` / `<kind>` / `none` rather than combining with them. If a
surface form carries an invalid flag, validation fails and its
`:lowering` hook is suppressed, so the host hook only ever sees
validated flags.

`:open true` marks the form as an extensible bag. Unknown keys are
accepted silently and closed-shape sweeps are skipped
(missing-required, missing-discriminant, exclusive-group, and
`:positional none` rejection). It does **not** relax declared-key type
checks, typed positional-child checks, or duplicate-key detection (see
LANGUAGE.md §7.3).

### 5.1 `(key …)` sub-forms

```
(key :name        <symbol>
     :type        <type-ref>
     :optional    <bool>?         ; default false for keys without :default,
                                  ; true when :default is present
     :default     <any>?          ; default for omitted optional keys —
                                  ; literal value OR expression form
     :walk-opaque <bool>?         ; default false; suppress recursive
                                  ; validation of a form-shaped value
     :description <string>?)
```

`:default` accepts two shapes:

- **Literal values** (numbers, strings, symbols, booleans, nil, vectors).
  The loader post-checks the literal's tag against `:type` and emits
  `wrong_underlying` under `[plugin, form, key, default]` on mismatch.
  Vectors with nested expression elements are rejected — use a
  top-level expression default instead.
- **Expression forms** (e.g. `:default (pi)`, `:default (* 2 16)`,
  `:default (vec3 0 0 0)`). The loader snapshots the head, namespace,
  and arg count *and* encodes the whole expression subtree as a
  one-root Binary IR program retained on the `KeySpec` (the evaluable
  payload the runtime materialization pass feeds to `Expr.evalBinary`;
  see LANGUAGE.md §7.8). Schema-build's aggregate phase resolves the
  head and compares the declared `:result` (§6.1) against `:type`.
  Mismatched results emit `wrong_underlying` under `[plugin, form,
  key, default]`. Expression heads with no declared `:result` (`let`,
  `if`, unresolved overloads) defer at validate-time — mirrors the
  runtime-deferral policy for nested expressions in data forms (§7.4).
  Expression defaults can additionally fail at *materialization* time
  (unknown/unimplemented head at runtime, unbound symbol, plugin
  runtime failure, malformed retained program); the host emits
  `default_eval_failed` at the document path
  `[<form-head> <key-name> default]` and produces no overlay entry
  for that key.

`:walk-opaque true` tells the validator not to descend into a
form-shaped value paired with this key — the value's head and inner
contents are treated as opaque to the surrounding schema. The
slot-level type check (`:type`) still runs; only the recursive walk of
the nested form is skipped, so expression-shaped contents like
`:default (pi)` don't draw a spurious `unknown_form`. It is opt-in per
key and only ever *suppresses* a diagnostic, so its blast radius is
small. The meta-schema itself uses it on exactly one slot — the
`(key …)` form's own `:default` — which is why `manifests/meta.sjon`
can describe expression-bearing defaults without special-casing.

### 5.2 Positional slot-local forms

A `(form …)` may declare inline `(form …)` children directly beneath it —
the positional mirror of the slot-local forms a `(key …)` scopes to a
`.form`-typed slot (§5.1's inline `(form …)`; semantics in LANGUAGE.md
§6.3.1). They populate the form-wide `FormSpec.local_forms`, scoping
one-off, slot-anonymous form bodies to the form's **positional** children:

```
(form :name bind-group
  (form :name entry  (key :name binding :type number :optional false))
  (form :name buffer (key :name slot    :type number :optional false)))
```

A form-shaped positional child resolves **local-first, then additively**:
a bare head matching a local validates against that local (shadowing a
same-named global), a bare head matching no local falls back to the
global catalog, and a bare head matching neither is `unknown_local_form`
at the **parent form's** path. A *qualified* head (`ns/entry`) bypasses
the locals and resolves global-only. (Full resolution order: LANGUAGE.md
§6.3.1.)

**Implied `.any`.** A form has a single `:positional` policy, but its
locals are declared independently of it. Inline locals with **no**
explicit `:positional` imply `.any` — otherwise they would be
unreachable behind `positional_not_allowed`. Pairing locals with
`:positional (flag-set …)` is a contradiction the loader rejects as
`invalid_manifest`: a flag slot admits only keyword flags, never forms.

**Closed positional set (the head-set recipe).** To restrict the slot to
a fixed set of heads *and* give each its own body, gate it with a
`head-set` value-kind (§4.5) and declare a matching local per head:

```
(value-kind :name bg-set :underlying form
  :heads (head-set :names [entry buffer]))
(form :name bind-group :positional bg-set
  (form :name entry  (key :name binding :type number :optional false))
  (form :name buffer (key :name slot    :type number :optional false)))
```

The head-set narrows the slot to `{entry, buffer}` by byte-equality (an
out-of-set head → `not_head_member`); the in-set heads then resolve their
local bodies. This is the closed-set shape a host reaches for when a
positional child name (`entry`) would otherwise collide with a global
form of the same name.

**Depth.** Positional locals count against the same
`Plugin.MAX_LOCAL_FORM_DEPTH` as key-locals and compose with them — a
positional local may carry `(key …)` slot-locals and vice-versa —
nesting no deeper than the shared ceiling.

## 6. `(expr-func …)` declarations

Expression functions have two encodings. Mixing both on a single
`expr-func` is a load-time error: the loader emits a structural
diagnostic and prefers the multi-signature form (the richer of the two)
when materialising the in-memory `ExprFunc`.

### 6.1 Mono-signature (the common case)

```
(expr-func :name <symbol>
  :arity      (fixed N) | (at-least N) | (range :min M :max N)
  :params     <type-list>?         ; types per fixed positional
  :rest       <type-ref>?           ; type for the variadic tail
  :result     <type-ref>?           ; declared result type — used by the
                                    ; validator to check that a form
                                    ; value in a typed slot (or as an
                                    ; expression positional arg) matches
                                    ; the slot's expected type at
                                    ; validate-time. Omit to keep the
                                    ; result opaque (defer to runtime).
  :description <string>?
  :impl       <binding-ref>?)
```

`:params` and `:rest` interact with `:arity` as follows:

- `(fixed N)` with `:params [t1 … tN]`: every position is typed.
- `(at-least K)` or `(range :min K :max M)` with `:params [t1 … tK]`
  and `:rest tR`: positions `0..K-1` take the per-position types,
  positions `K..` take `tR`.
- `:rest` without `:params`: every position takes `:rest`.
- Both omitted: the function is *opaque to typing* — arity is enforced,
  arguments are untyped.

### 6.2 Multi-signature (overloads)

For overloaded functions (`lerp`, `clamp`, `min`, `max`, …), declare one
or more `(signature …)` positional children and leave the top-level
`:arity` / `:params` / `:rest` / `:result` unset:

```
(expr-func :name lerp
  :description "Linear interpolation."
  (signature :arity (fixed 3) :params [number number number] :result number)
  (signature :arity (fixed 3) :params [vec2   vec2   number] :result vec2)
  (signature :arity (fixed 3) :params [vec3   vec3   number] :result vec3)
  (signature :arity (fixed 3) :params [vec4   vec4   number] :result vec4))
```

Each `(signature …)` carries the same fields as a mono-signature
encoding. At validate-time the candidate set starts as every signature
whose arity accepts the call's argc, then narrows tag-wise per
positional argument. When narrowing empties the set the validator emits
`expr_type_mismatch`; the message lists each remaining candidate's
declared type at that position (deduped, joined with " or "). Symbol
args defer to runtime and don't narrow the candidate set. Form args
narrow using their declared expression result type when one is
statically resolvable; opaque forms (no declared `:result`, or
ambiguous active candidates) defer like symbols. (Refinement-aware
narrowing of overload args — length-pinning a vector kind, member-set
/ unit-shape on a primitive — is not yet wired through; `.named` types
accept any tag at the overload layer.)

### 6.3 Opaque (special forms)

`let`, `if`, `cond`, `and`, `or`, `quote`-like forms don't fit a
positional signature — their typing depends on bindings, branches, or
quoting rules. Declare arity only:

```
(expr-func :name let
  :arity (fixed 2)
  :description "(let [name expr …] body) — sequential bindings.")
```

The validator enforces arity; semantic typing is deferred to the impl.

## 7. Arity variants

```
(fixed N)            ; exactly N arguments
(at-least N)         ; N or more
(range :min M :max N) ; inclusive [M, N]
```

`N`, `M`, `N` are non-negative integer numbers. The loader rejects
non-integer or negative values.

## 8. Type references

`<type-ref>` resolves through the host's aggregated kind catalog. The
following bare symbols are reserved primitives:

| Symbol    | Meaning                              |
|-----------|--------------------------------------|
| `number`  | Any number literal                   |
| `string`  | Any string literal                   |
| `symbol`  | Any bare symbol                      |
| `boolean` | `true` or `false`                    |
| `nil`     | The `nil` literal                    |
| `vector`  | Any `[…]` vector                     |
| `form`    | Any `(…)` form                       |
| `expr`    | Any safe-expression form             |
| `any`     | Any value (escape hatch)             |

Any other symbol is resolved via the kind catalog. Failure to resolve
emits `unknown_element_kind` at load time.

`<type-list>` is a `[…]` vector of type references:
`[number string my-kind]`.

`<symbol-list>` is a `[…]` vector of bare symbols:
`[ortho perspective]`.

`<binding-ref>` is a string of the form `"<scheme>:<name>"`. Current
v1 semantics are assigned only to `wasm:` sidecar exports; `host:`,
`native:`, and unknown schemes are declaration-only in portable
manifests — see §10.

## 9. Boolean & version semantics

- Booleans use SJON-native `true` / `false`. Not `:yes` / `:no`, not
  `:t` / `:nil`.
- `:version` is the resolver's pin target: the host compares it byte-for-byte
  against any `(use-plugin … :version "x")` pin and emits
  `plugin_version_mismatch` on disagreement. v1 is exact-string match — no
  semver ranges — to keep reproducibility audits deterministic. Any
  `:version "X.Y.Z"` value is accepted as a string by the loader; semantic
  interpretation lives at the `(use-plugin)` callsite, not the manifest.

## 10. Symbolic `:impl` binding

`:impl` is a *reference*, not a loader instruction. Current v1 manifest
loading has four meaningful states:

| `:impl` field state | Validation | Evaluation |
| --- | --- | --- |
| absent | works | not possible by design |
| `"wasm:foo"` and the resolver returns a sidecar to a Web/Rust host | works | dispatches export `foo` through the executable plugin ABI |
| `"wasm:foo"` but the resolver returns no sidecar bytes | emits `plugin_wasm_required` at manifest/reference load time | not reached |
| `"wasm:foo"` on a declarative-only host such as Zig native or TS parity | works | does not instantiate plugin code; evaluation is unimplemented/deferred |
| `"host:foo"`, `"native:foo"`, or another scheme | works as a declaration-only function | no executable binding in portable manifests today |

Static Zig plugins are separate: they may set `ExprFunc.impl` directly
and the evaluator calls that function in-process. Portable manifests do
not dynamically bind `host:` or `native:` code in v1. Unknown schemes are
accepted for forward compatibility only; they do not define executable
behaviour until a future plugin-model revision assigns them semantics.

## 11. Diagnostics

Diagnostic codes are stable across hosts and are documented in
`docs/LANGUAGE.md` §7.6. Conformance fixtures match on
`(code, path)`; message prose is host-flavoured and never asserted
on.

A loader emits the same code surface as the in-process validator —
`unknown_form` for an unknown declaration head, `wrong_underlying` for
a mistyped key value, `not_head_member` for a `:positional` whose head
isn't in the declared `head-set`, `not_flag_member` for a positional
keyword flag outside a declared `(flag-set …)`, and so on. Manifest-loading itself
adds two codes:

- `unknown_scheme` — `:impl` reference uses an unrecognised scheme
  prefix.
- `wrong_underlying` (under `[plugin, form, key, default]`) — `:default`
  value's type is incompatible with the key's declared `:type`. Fires
  at load time for literal mismatches and at schema-build for expression
  defaults whose declared `:result` doesn't match.
- `unknown_cross_ref_target` — `(cross-ref :target X …)` declares
  `X` but no plugin in the aggregated schema declares such a form.
- `ambiguous_cross_ref_target` — `:target` resolves to forms in two
  or more plugins; qualify with `<ns>/<form>` to disambiguate.
- `cross_ref_name_key_unknown` — `:name-key` doesn't appear on the
  resolved target form, or that key's value type isn't `.symbol`.
- `unknown_cross_ref_scope` — `(cross-ref :scope X …)` names a form
  that no plugin declares.
- `ambiguous_cross_ref_scope` — `:scope` resolves to forms in two or
  more plugins; qualify with `<ns>/<form>` to disambiguate.
- `unknown_cross_ref_provider` — `(cross-ref :provider p …)` names a
  provider that no plugin in the aggregated schema declares.
- `ambiguous_cross_ref_provider` — bare `:provider` resolves to
  providers in two or more plugins; qualify with `<ns>/<name>`.
- `cross_ref_source_key_unknown` — `:source-key` doesn't appear on the
  resolved target form, or that key's value type isn't string-shaped.
- `numeric_bounds_invalid` — `(numeric-bounds …)` is internally
  inconsistent: `:exclusive-min/max true` without the matching
  inclusive bound, `:min > :max` (when both share a unit), or
  `:numeric` on a kind whose `:underlying` is not `number`.

(All eleven are deferred to the loader / schema-aggregation phase and
are not emitted by the substrate validator's per-document hot path.)

Validate-time numeric-bounds codes — emitted on a slot whose kind
has `:numeric` set:

- `number_below_min` — value < `:min` (inclusive).
- `number_above_max` — value > `:max` (inclusive).
- `number_at_or_below_exclusive_min` — value ≤ `:min` with
  `:exclusive-min true`.
- `number_at_or_above_exclusive_max` — value ≥ `:max` with
  `:exclusive-max true`.
- `number_not_integer` — `:integer true` and value is fractional or
  non-finite (NaN / ±inf).
- `numeric_bound_unit_mismatch` — bound carries a unit but the
  value either has none or carries a different unit.

Validate-time cross-ref-provider codes — emitted once, on the *source*
instance whose bytes could not be turned into a member set, never on the
references that read it:

- `cross_ref_extraction_failed` — the provider ran and refused the
  source, or broke the ABI's value contract (non-vector result,
  non-string element, more than 4096 names). From the document's side
  these are one thing: the provider did not answer.
- `cross_ref_provider_unavailable` — the host could not run it at all:
  no executable-plugin support in this build, no implementation shipped
  with the plugin, or a missing export.

Both **poison** the bucket rather than emptying it, so references into it
are left unchecked instead of each reporting `not_cross_ref`. This is the
one place where a host's build configuration is visible in its
diagnostics, and it is visible on purpose: the alternative is a document
that validates differently depending on how its validator was compiled.

### 11.1 Conformance corpus

Reference fixtures live under `conformance/cases/<name>/`. Each case
is a triple:

  * `schema.sjon` — a v1 portable manifest, loaded via
    `ManifestLoader`.
  * `input.sjon` — the document to validate.
  * `expected.sjon` — a `(diagnostics …)` form listing the diagnostics
    a conforming validator must emit, in source order.

Each expected diagnostic is `(diagnostic :code <symbol> :path
[step …])`. Cross-host conformance asserts on `(code, path)` only;
neither span ranges nor message prose are part of the contract. A
second-host implementation passes conformance when it loads each
schema, validates each input, and produces the expected diagnostic
sequence. The Zig reference runner is `src/conformance_tests.zig`.

## 12. The meta-plugin

Every conforming implementation embeds the meta-plugin
(`manifests/meta.sjon`) as its bootstrap baseline. Before a user
manifest is loaded, the host validates it against the meta-plugin —
catching declaration-shape errors with the same code surface user
documents see.

`manifests/meta.sjon` is the single source of truth. The descriptor a
host embeds is *generated* from it: in the Zig reference implementation
`tools/gen_meta_schema.zig` compiles `meta.sjon` into a comptime
`Plugin` literal (`src/MetaSchema.generated.zig`), because the
bootstrap descriptor must be a constant — freestanding-wasm builds have
no filesystem to parse `meta.sjon` at startup. A second host may embed
the manifest however its toolchain prefers, so long as the embedded
descriptor is faithful to `meta.sjon`.

The meta-plugin self-validates: validating `manifests/meta.sjon`
against the generated descriptor produces zero diagnostics. Because the
descriptor is generated *from* `meta.sjon`, this is a genuine fixed
point — `meta.sjon` validates under rules derived from itself — not an
agreement between two hand-maintained copies. It is the conformance
check for the format itself; any change to the meta-plugin that breaks
self-validation is a v1 spec break. In the Zig implementation, after
editing `meta.sjon` regenerate the descriptor with `zig build
gen-meta-schema -- --regen`; `zig build test` byte-compares the
committed generated file against a fresh generation, so an
un-regenerated edit fails `zig build test` (there is no CI).

## 13. Sharp edges (v1 resolutions)

Pinned for the format spec so the meta-plugin is unambiguous.

1. **Empty `:positional` is omitted, not `none` or `[]`.** Mirrors how
   `:vector` / `:unit` / `:members` / `:heads` are absent when they
   don't apply.
2. **Form key list is positional `(key …)` children, not a kvpair.**
   `(form :name circle (key :name r :type number))`. Authoring shape;
   parses uniformly under SJON's positional rule.
3. **Type references resolve through one path.** `:type`, `:result`,
   `:rest`, `:positional`, and `(vector-shape :element …)` all consult
   the same kind catalog. Primitives (§8) shadow any user-declared
   kind of the same name.
4. **Booleans are native `true` / `false`.** Settled (§9).
5. **`:version` is the resolver's pin target.** Exact-string match against
   `(use-plugin … :version "x")`. Settled (§9).
6. **`:default` is `any`-typed at the manifest layer.** The loader
   does the literal-tag-vs-`:type` check post-parse and emits
   `wrong_underlying` on failure. Expression-shaped defaults snapshot
   `(head, namespace, arg_count)` for cheap schema-build checking and
   retain a one-root Binary IR program for runtime materialization.
   `Schema.validateDefaults` compares the head's declared `:result`
   against `:type`; opaque heads defer to runtime. At
   materialization, the host evaluates the retained program and emits
   `default_eval_failed` if evaluation fails. This keeps the
   parametric `:default :type type-of(:type)` rule out of the loader
   while still catching common shape errors and preserving an
   executable payload for effective values.
7. **Mono / multi expr-func encodings are mutually exclusive.** A
   loader rejects an `(expr-func …)` that has both top-level mono
   fields (`:arity`/`:params`/`:rest`/`:result`) and `(signature …)`
   positional children.

## 14. Forward compatibility

The format evolves additively:

- New optional keys may be added to existing declarations. Old loaders
  ignore them (or warn, depending on host policy).
- New refinement axes may be added on `value-kind`. Each is gated by
  one `:underlying` and is silently absent on old loaders.
- New `:impl` schemes may be added (`wasm:`, `native:`, …). Old
  loaders treat unknown schemes as "validation works, evaluation
  unavailable."
- New `expr-func` encodings may be added. Mono and multi-signature are
  the v1 set; future encodings get a distinct positional sub-form
  shape.

Removing or renaming a declaration is a breaking change. v1's
contract is "additive evolution only"; revisions that need to break
this contract bump the manifest format version.
