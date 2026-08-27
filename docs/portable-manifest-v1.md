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

Required key: `:name` (symbol). `(plugin :name x)` is a complete manifest.

Optional keys:

| Key            | Type                                | Notes                                                                                                       |
|----------------|-------------------------------------|-------------------------------------------------------------------------------------------------------------|
| `:version`     | string (`"1.0.0"`)                  | The plugin's own version — the `(use-plugin … :version …)` pin target and the lockfile row (§9). Absent = unversioned. |
| `:description` | string                              | Free-form prose.                                                                                            |
| `:wasm-file`   | string                              | Manifest-dir-relative path to the paired wasm binary. Escapes outside the package emit `plugin_wasm_resolved_outside_package`. |
| `:wasm-sha256` | string (`sha256-<64 hex>`)          | Author's stamp of the published wasm bytes. The host verifies on load; mismatch → `plugin_wasm_self_hash_mismatch`. |
| `:authors`     | vector of symbols / strings         | Free-form attribution metadata.                                                                              |
| `:license`     | string (SPDX identifier)            | Non-canonical strings produce an advisory `license_unrecognized`.                                            |
| `:homepage`    | string                              | Informational URL.                                                                                           |
| `:repository`  | string                              | Informational URL.                                                                                           |
| `:keywords`    | vector of symbols                   | Soft cap at 16 entries; advisory `too_many_keywords` past that.                                              |

There is no format-version key. The manifest vocabulary has one version —
the SJON release — and `CHANGELOG.md` says which release each keyword or
declaration arrived in. (An earlier revision had `:sjon "1.x"`; it enabled
nothing on the host reading it and was retired. A leftover `:sjon` is an
unknown key on `(plugin …)`, reported like any other.)

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
  :union         (union-shape …)?        ; only when :underlying is union
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
  :integer       <bool>?           ; require integer-valued (rejects fractional & non-finite)
  :multiple-of   <number>?)        ; require an exact multiple of this divisor
```

`:min` and `:max` accept any numeric literal, including unit-bearing
ones (`:min 0ms`) and hex integers (`:min 0x10`, `:max 0xFFFF_FFFF` —
`docs/LANGUAGE.md` §2.6). A hex bound is just an integer bound: it
takes the exact-integer comparison path below, and a manifest reader
sees the value, never the spelling. Bound vs value unit semantics are
byte-equal with no canonicalisation:

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

**`:multiple-of`.** The value must divide evenly by this
divisor — the alignment constraint a range and `:integer` cannot express
between them. It carries a unit like `:min` / `:max`, under the table
above, so `:multiple-of 256b` beside `:min 0b` is expressible. The
*value's* sign is irrelevant — `-512` is a multiple of `256`. The
*divisor* must be positive: `:multiple-of -4` has exactly the multiples
`:multiple-of 4` has, so nothing is lost by rejecting it, and JSON Schema
2020-12 requires `multipleOf` to be strictly greater than zero — a host
that accepted the negative spelling would export a schema no validator
will compile.

Divisibility is decided in **exact integer space** whenever the value and
the divisor are both whole — the same concern as the exact-precision
paragraph above, and the same answer. `9007199254740993` (2^53 + 1) is odd
and fails `:multiple-of 2`, where an f64 remainder would round it to an
even number and accept it. A fractional value under a whole divisor is
never a multiple (`3.5` is not a multiple of `4`); it is not rounded on
the way in.

A *fractional divisor* is the one approximate case. `:multiple-of 0.25`
has no exact answer in binary floating point, so the remainder is compared
against a relative epsilon and the loader warns (below). It works; it is
simply not exact, and every alignment rule uses a whole divisor anyway.

Ordering matters and is fixed: `:integer` is checked first, then the range
bounds, then divisibility. Only the first failure is reported, so `250.5`
under `:integer true :multiple-of 4` is `number_not_integer` and `-256`
under `:min 0 :multiple-of 256` is `number_below_min`. An author chasing an
alignment error should not be told to align a number that is not whole yet.

Load-time consistency checks emit `numeric_bounds_invalid`:

- `:exclusive-min true` with `:min` absent.
- `:exclusive-max true` with `:max` absent.
- `:min > :max` when both bounds share a unit (or both are
  unitless). Mixed-unit bounds defer to validate time, where they
  surface as `numeric_bound_unit_mismatch`.
- `:numeric` attached to a kind whose `:underlying` is not `number`.
- A non-positive `:multiple-of`, or a non-finite one — the check divides by
  this value, "every number is a multiple of 0" is not a useful reading
  either, and a negative divisor is both redundant and unexportable (see
  above). Both signs share one message.
- **Warning, not error:** a fractional `:multiple-of`. The constraint is
  kept and still checked; the author is told it is approximate.

Examples:

```sjon
(value-kind :name opacity :underlying number
  :numeric (numeric-bounds :min 0 :max 1))

(value-kind :name iteration-count :underlying number
  :numeric (numeric-bounds :min 1 :integer true))

(value-kind :name duration-ms :underlying number
  :unit    (unit-shape :required true :allowed [ms])
  :numeric (numeric-bounds :min 0ms :max 10000ms))

(value-kind :name aligned-offset :underlying number
  :numeric (numeric-bounds :min 0 :integer true :multiple-of 256))

(value-kind :name aligned-bytes :underlying number
  :unit    (unit-shape :required true :allowed [b])
  :numeric (numeric-bounds :min 0b :multiple-of 256b))
```

### 4.4 `(member-set …)`

```
; Compact — set-only declaration.
(member-set
  :values <member-name-list>)     ; closed set of allowed values

; Rich — per-member editor metadata.
(member-set
  (member :name <member-name>
          :label "<string>"               ; optional display label
          :description "<string>"         ; optional help text
          :deprecated <boolean>           ; optional, default false
          :deprecation-message "<string>") ; optional replacement hint
  …)
```

For `:underlying symbol`, the names are bare symbol identifiers (no
leading `:`). For `:underlying string`, the names are still bare
symbols whose textual content is matched against the string literal.

#### Digit-leading spellings

`member-name` (§8) is a symbol **or** a number, because some enums name
their members with a digit first — WebGPU's `GPUTextureDimension` is
`"1d"`, `"2d"`, `"3d"`, and none of those lexes as a symbol: SJON reads a
digit-leading token as a number with a unit (`docs/LANGUAGE.md` §2.6).

```sjon
(value-kind :name texture-dimension :underlying symbol
  :members (member-set :values [1d 2d 3d]))

(value-kind :name view-dimension :underlying symbol
  :members (member-set
    (member :name 1d)
    (member :name 2d :description "The default.")
    (member :name cube)
    (member :name cube-array)
    (member :name 3d)))
```

A digit-leading member is matched on its parsed `(magnitude, unit)` pair,
so `2d`, `2.0d`, and `02d` are the same member and `2.5d` is none of them.
The member's `name` is the **canonical** spelling — the magnitude
re-rendered from its integer value — so `02d` declares `2d` and a
manifest's incidental spelling never reaches a diagnostic or an export.

The value is **accepted, not rewritten**: a document carries
`{"$num": [2, "d"]}` through the JSON bridge, which is why the exported
JSON Schema pins `$num` for these members and `$sym` for the ordinary
ones (§10 / `docs/SCHEMA_EXPORT.md`). A host that wants the spelling maps
the pair against the member list it already holds.

The type can only say "symbol or number", so **which** numbers are
spellings is decided by the loader — the same split `(fixed N)` uses.
Four `invalid_manifest` conditions:

| Condition | Why |
|---|---|
| A number with **no unit** (`:values [1 2 3]`) | A bare magnitude is not a name. |
| A magnitude that is negative, fractional, or above 2^53 | 2^53 is the range where the canonical spelling has one text form in every host — and `name` reaches the exported `enum` and `.d.ts` union, which are byte-compared. |
| A digit-leading member on a non-`symbol` `:underlying` | On `:string` the members are string literals; no numeric value can reach them, so the declaration is dead. |
| Two members with the same `(magnitude, unit)` | `2d` and `02d` are one member. The duplicate check is on the identity, since that is what the validator matches on. |

A `(member-set …)` may use the compact `:values [...]` shape OR the
rich `(member …)` shape, but not both — the loader emits
`invalid_manifest` on a mixed declaration. An empty `(member-set)`
(neither shape present) is also `invalid_manifest`.

Two members with the same identity are `invalid_manifest` ("duplicate
member") **in either shape**: two `(member :name X)` siblings sharing
`:name`, and two elements of one `:values` list. The scan is the same one
in both, on the identity rather than the text, so `[2d 2.0d]` is reported
exactly as `(member :name 2d)` beside `(member :name 02d)` is.

When a `Member` carries `:deprecated true`, the validator still
accepts the value (membership succeeds) but emits a
`deprecated_member` warning anchored on the value's span. The
`:deprecation-message` text, if present, appends to the warning's
prose ("member `X` is deprecated: <message>"); LSP clients also
render the completion item with `CompletionItemTag.Deprecated` and
expose `:label` / `:description` as completion `detail` / `documentation`.

### 4.5 `(head-set …)`

```
; Compact — set-only declaration. Every *head* unbounded.
(head-set
  :names <symbol-list>            ; closed set of allowed form heads
  :min-children <number>?         ; see "A count over the whole set"
  :max-children <number>?)

; Rich — per-head positional counts + editor metadata.
(head-set
  :min-children <number>?         ; legal on either spelling
  :max-children <number>?
  (head :name <symbol>            ; required
        :min <number>             ; optional, inclusive floor, default 0
        :max <number>             ; optional, inclusive ceiling, default unbounded
        :description "<string>")   ; optional help text
  …)
```

`(head-set …)` pins the form-as-slot discriminator (the form's head
symbol) to a closed set.

Narrowing is by **head text alone** — byte-equality against each
`:name`, with no catalog lookup at manifest-load time or at validate
time. Whether a matched head has a `(form …)` to be validated against is
a separate, later step, and that step resolves **local-first**: a
slot-local `(form …)` in scope at the slot satisfies it with no global
declaration anywhere. A global "dummy" form is not required to make a
head-set name usable.

**Schema export resolves the same way.** `sjon export-schema` emits one
branch per accepted head, resolved at the slot: a `$ref` into
`#/$defs/form.<plugin>.<head>` for a global, the local's body *inline*
for a slot-local (locals have no global `$def` to point at), and a
head-pinned open object — `{"$form": {"const": "<head>"}}` — for a head
that resolves to neither. So a head-set whose members are all
slot-locals exports cleanly with no global dummy, which is the whole
point of the paragraph above. A head that resolves to nothing *at a slot*
is an export error (`head_set_member_unresolved`); the same head-set
lowered on its own for the value-kind table is not judged at all, because
which forms are in scope is a property of the slot and a head-set kind is
reusable across slots (see the scope note below).

A head-set name with no form in either scope is admitted by the
head-set and then reported as `unknown_local_form` at the slot — one
diagnostic, from the descent. A head *outside* the set trips both
mechanisms and reports twice (`not_head_member` from the narrowing,
`unknown_local_form` from the descent).

As with `(member-set …)`, the two spellings are exclusive. The loader
emits `invalid_manifest` on a mixed declaration, on an empty
`(head-set)`, on two `(head :name X)` siblings sharing `:name`
("duplicate head"), and on a `:min` above its `:max` ("empty range"). A
`:min` or `:max` that is negative, fractional, or above 65535 reports
`wrong_underlying` instead — the same out-of-range check `(fixed N)` and
`(range :min …)` go through.

#### How many, not just which

The compact spelling says which heads a slot accepts. The rich spelling
can also say how many of each:

```sjon
(value-kind :name pipeline-section
  :underlying form
  :description "One section of a render pipeline."
  :heads (head-set
    (head :name vertex   :min 1 :max 1 :description "The vertex stage. Exactly one.")
    (head :name fragment :max 1        :description "The fragment stage. At most one.")
    (head :name constant               :description "Any number.")))

(form :name render-pipeline
  :positional pipeline-section
  (key :name name :type symbol))
```

`:min 1 :max 1` is "exactly one"; `:max 1` alone is "at most one, and
none is fine" (the floor defaults to 0); no bound at all is any number.

Two diagnostics fall out, and they land in different places:

- **`positional_too_many`** at the child that crosses the ceiling, with
  that child's positional path step — the squiggle goes on the line to
  delete. One report per crossing, not one per child past it, so a form
  four children over its bound doesn't bury its other diagnostics.
- **`positional_missing`** at the parent form's head span with the
  parent's path. A floor breach is an end-of-children fact — you cannot
  know a head is absent until the children run out — so it lands where
  `missing_required_key` lands, and for the same reason: there is no
  child to point at. One report per unsatisfied head.

**Scope: counts are enforced at a form's `:positional` slot and are inert
everywhere else.** A head-set kind is a value-kind and therefore
reusable — the same `pipeline-section` may sit on a `:positional` slot, a
`(key :type pipeline-section)` slot, and inside
`(vector-shape :element pipeline-section)`. Only the first has a repeated
population to count: a keyed slot holds one value, so `:max` is trivially
satisfied and `:min` has no set to be missing from, and a vector element
is a value rather than a child list. Reuse is inert rather than an error,
because rejecting it would make a bounded head-set kind un-shareable for
no gain. (Counting vector elements is a coherent extension and is
deliberately not part of this version.)

**Counts survive a slot that also declares locals.** The positional slot
is the positional slot whether or not it carries inline `(form …)`
children (§5.2), so a bounded head on a locals slot is enforced and
exported like any other — `contains` + `minContains` / `maxContains`,
one entry per bounded head. A local head's `contains` is the head-pin
rather than a `$ref`, since there is no `$def` to point at; it counts the
same children, because the slot's `oneOf` already forces every child to
satisfy its own head's branch.

**`:open true` suppresses neither code.** Openness widens which
*keywords* a form accepts; a positional count is a different surface, and
declaring `:positional <bounded-kind>` opts into it. This makes
`positional_missing` the one end-of-form sweep `:open` leaves alone —
every other one (required keys, the discriminant gate, exclusive groups,
key dependencies) is about keywords. The neighbouring positional rules
agree: `not_head_member` and `duplicate_positional_flag` already fire on
open forms.

**A child counts towards a head only if its own head matches
byte-for-byte.** A head outside the set fails `not_head_member` and a
non-form positional fails `wrong_underlying`; neither consumes a tally.
So an out-of-set child cannot accidentally satisfy some other head's
floor, and a repair sees both problems at once rather than one hiding the
other. The same rule governs the set-level count below — a child that
counts towards no head counts towards the set either.

#### A count over the whole set

Per-head bounds cannot bound the *set*. "Exactly one of buffer /
sampler / texture" is satisfied, under every per-head spelling, by a form
carrying one of each and by a form carrying none: each head's `:max 1`
holds, and no head's `:min` can be raised without demanding that
particular head. `:min-children` / `:max-children` sit on the
`(head-set …)` itself and count children of *any* head in it:

```sjon
(value-kind :name bgl-resource
  :underlying form
  :heads (head-set :min-children 1 :max-children 1
    (head :name buffer  :max 1)
    (head :name sampler :max 1)
    (head :name texture :max 1)))
```

— "exactly one resource, and not two of the same". The two levels are
independent claims, and both are needed: drop the set's and one of each
is accepted; drop the heads' and `:max-children 2` over three heads
would allow two buffers where "one of each, up to two" was meant.

**Both spellings carry them, including compact `:names`.** The aggregate
needs no per-head metadata, so
`(head-set :names [cube sphere] :max-children 1)` is legal and is the
common case. A compact head-set is therefore no longer always unbounded.

**Why `-children` and not bare `:min` / `:max`.** This vocabulary
reserves the bare pair for a *value* bound (`(numeric-bounds :min …)`)
and qualifies every other axis — `:min-len` / `:max-len` on both
`(vector-shape …)` and `(string-bounds …)`. Here the collision would be
worse than `vector-shape`'s, because `(head …)` *inside the same form*
already spells `:min` / `:max` with a different meaning: bare keys would
put two different bounds one line apart under identical names.

**Three more `invalid_manifest` refusals**, on top of §4.5's four. The
set's own empty range (`:min-children` above `:max-children`), and two
cross-level checks that are **sums** rather than per-head comparisons:

- `Σ head.min > :max-children` — heads `a :min 1` and `b :min 1` under a
  set `:max-children 1` is unsatisfiable, yet neither head's `:min`
  exceeds the set's `:max`. Only the sum sees it.
- `:min-children > Σ head.max` — the mirror, and only meaningful when
  *every* head is bounded. One unbounded head makes the set always
  fillable, so the check is vacuous and does not fire.

A `:min-children` / `:max-children` that is negative, fractional, or
above 65535 reports `wrong_underlying`, as the per-head pair does.

**Both codes are reused, and the set yields to the head.** A set-level
breach reports `positional_too_many` / `positional_missing` with the set
named in the message (`at most 1 positional child from
[buffer | sampler | texture], found 2`) instead of a head. The two levels
overlap by construction — `:min-children 1 :max-children 1` over heads
each `:max 1` is exactly the redundant case — so a second `(buffer …)`
under it would cross both ceilings on one child, at one span, with one
path and one code. **Only the per-head report fires.** It names the line
to delete and the set's claim follows from it; the reverse does not hold.
The same rule applies to the floor: a head whose `:min` went unmet
suppresses the set's floor report for that form.

That is what makes reusing the codes safe rather than merely cheap — no
host can observe a same-code-same-span pair, so nothing has to read prose
to tell the levels apart. A host that *wants* to knows by the bracketed
set in the message.

**Export.** The set's bound is one more `contains` in the same `allOf`,
whose subschema is the `anyOf` of the members' — "a child whose head is
in the set", which is what the validator tallies. `minItems`/`maxItems`
would say the same thing here and only here (a head-set slot is closed,
so the positional population *is* the set); `contains` is right in both
readings and keeps the two claims the same shape. A floor at **either**
level also puts `$children` in `required`: the JSON bridge omits the key
entirely for a childless form, so a `minContains` inside the `$children`
subschema would have nothing to judge on precisely the document that
breaches the floor hardest.

### 4.6 `(cross-ref …)`

```
(cross-ref
  :target   <symbol | [<symbol>…]> ; bare or qualified form name(s)
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

**Target groups.** `:target` may be a vector, which declares that the
listed forms share **one namespace**: a name declared by any of them
satisfies a reference, and a name declared by two of them is
`duplicate_cross_ref_target`. Both spellings normalise to a list, so
`:target [phrase]` is a single-target cross-ref rather than a group of
one, and a host cannot distinguish the two.

The list is a **set**. A host keys the namespace on its targets' canonical
names *sorted and de-duplicated*, so `[a b]` and `[b a]` name one
namespace and `[a p/a]` names the same one as `:target a`. This is
observable, not an implementation detail: it decides whether two kinds
spelling one group differently collapse into one registry (§7's
`cross_ref_target_collapse`), whether a name declared by two of the
targets is reported once or once per spelling, and whether a `:union` over
two spellings of one group reports `union_ambiguous`. A host that keyed on
the written order would differ on all three.

A group is not the same shape as a `:union` over two single-target
cross-ref kinds, and the difference is exactly the collision. A union
keeps one namespace per alternative, so a name declared by both targets
is legal in each and every reference to it has two readings — reported
as `union_ambiguous` (a warning) with first-match-wins resolution. A
group has one namespace, so the same pair is an error at the
*declarations* and no reference is ambiguous. Choose the group when the
names are meant to be unique across the forms.

Two keys are rejected on a group, as `invalid_manifest`, and both are
dropped rather than half-honoured:

- `:acyclic` — cycle edges are defined over a target form's
  *self*-referential keys, and "self" is not well defined across several
  forms, so `acyclic_without_self_edge` could not be computed honestly
  either. (Same reasoning already rejects `:acyclic` beside `:provider`.)
- `:provider` — an extracted member set is collected per target form, so
  a group would make one form owe extractions to several namespaces at
  once. Declare one cross-ref per target instead.

An empty `:target []` and a repeated entry are also `invalid_manifest`:
the first accepts nothing and rejects everything, the second adds nothing
to a namespace while hiding a likely typo in the entry it duplicates.

`:target` resolves at schema-aggregation time via the same lookup as
qualified type references (`<ns>/<form>` is supported for namespace
disambiguation), and every entry of a group resolves independently. The
registry indexes by the canonical `<plugin>/<form>` name — two plugins
each declaring a form named `phrase` register under distinct keys — and a
group indexes under a synthetic name derived from every canonical target,
which is what makes its one namespace one registry. Aggregation-time
failures surface as `unknown_cross_ref_target` or
`ambiguous_cross_ref_target`, once per offending entry; a group with any
unresolvable entry contributes no registry at all, so its references
report `not_cross_ref` rather than resolving against a namespace missing
names the author listed.
a `:name-key` that doesn't exist on the resolved form (or whose value
type isn't `.symbol`) surfaces as `cross_ref_name_key_unknown`.

Two forms within the same scope declaring the same `(namespace, name)`
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
  :base <type-ref>               ; the scalar alternative
  :ref  <type-ref>?)             ; the reference alternative; default `symbol`
```

A **shorthand**, not a base underlying. `:underlying scalar-or-ref` with
a `:scalar-or-ref (scalar-or-ref-shape :base <kind>)` slot desugars at
load to a `:underlying union` over `[<base>, <ref>]` — so the stored
kind is an ordinary union and every consumer inherits its *matching*
behaviour. It captures "a literal `<base>` value, *or* a bare-symbol
reference to one defined elsewhere": a `<base>` value takes the scalar
alternative, a symbol the reference alternative, and anything else fails
with `union_no_branch_matched`. Declaring `:underlying scalar-or-ref`
without the `:scalar-or-ref` slot — or a `:scalar-or-ref` slot on any
other underlying — emits `invalid_manifest` at load.

```sjon
(value-kind :name count-value :underlying number)
(value-kind :name count
  :underlying scalar-or-ref
  :scalar-or-ref (scalar-or-ref-shape :base count-value))
```

**`:ref`.** Omitted, the reference alternative is the
primitive `symbol` — an *unchecked* name, so any spelling at all
satisfies it and a misspelled constant validates clean. That is the
shorthand's behaviour in every earlier format version and it does not
change. Naming a kind there instead makes the reference half checked:

```sjon
(value-kind :name define-ref :underlying symbol
  :cross-ref (cross-ref :target define))
(value-kind :name count
  :underlying scalar-or-ref
  :scalar-or-ref (scalar-or-ref-shape :base count-value :ref define-ref))
```

A reference that names no `(define …)` now fails — with the reference
half's own `not_cross_ref`, naming the form the symbol had to be
declared by.

**Failure reporting names the arm.** The desugar keeps nothing beyond
the union — the stored kind is indistinguishable from one spelled out
by hand — and the arm report is the general union rule of §4.9, which
this shape always satisfies: a scalar-or-ref's two arms are disjoint by
*node shape*, a number can only have meant the base and a symbol only
the ref, so a number or a symbol always has a determined arm and
validation reports **that arm's diagnostic**: the bound that refused
(`number_above_max`, `number_below_min`, `number_not_integer`,
`number_not_multiple`, `unit_forbidden`, `repr_out_of_range`, …) or the
reference that names nothing (`not_cross_ref`). A shape neither arm
reaches — a string or a vector in a `number | symbol` slot — keeps
`union_no_branch_matched`, and so does a shape both reach, which is a
`:base` that is itself a symbol kind (a member set): blaming the
reference half there would misdirect a misspelled member.

```sjon
(value-kind :name qty-value :underlying number
  :numeric (numeric-bounds :min 0 :max 16 :integer true))
(value-kind :name qty
  :underlying scalar-or-ref
  :scalar-or-ref (scalar-or-ref-shape :base qty-value :ref define-ref))
```

| Document        | Diagnostic                                    |
|-----------------|-----------------------------------------------|
| `:qty 32`       | `number_above_max` — value 32 above maximum 16 |
| `:qty -1`       | `number_below_min`                            |
| `:qty MAX_BONE` | `not_cross_ref` — no `(define :name …)` declares it |
| `:qty [1 2]`    | `union_no_branch_matched` — no arm reaches a vector |

Spelling the same two kinds by hand as a `(union-shape …)` reports
exactly the same four diagnostics. §4.9 has the rule.

One rejection at load, `invalid_manifest`: `:ref` equal to `:base`,
which spells one alternative twice (a union needs two distinct
alternatives). Equality is byte-equality on both halves, so `:base x`
with `:ref p/x` is *not* a collision even when `p` is this plugin —
namespace canonicalisation is a host concern.

Whether `:ref` names a *union* kind is not checked at the declaration.
Value-kinds load in declaration order, so a check here would accept or
reject the same manifest depending on where the union sits; the
aggregate pass resolves every alternative against the complete catalog
and reports `nested_union` order-independently. The same reasoning
covers a `:ref` that names another scalar-or-ref kind — do not add a
load-order dependency to catch it earlier.

### 4.9 `(union-shape …)`

```
(union-shape
  :alternatives [<type-ref> <type-ref> …])   ; two or more
```

The explicit form of what §4.8 desugars to. Each alternative names a
value-kind or a primitive shortcut (`number`, `string`, `symbol`,
`vector`, `form`, `any`), and may be qualified (`plugin/kind`) when a
bare name would collide.

**Alternatives are tried in declaration order and the first full match
accepts the value.** No alternative is "more specific" than another and
none is preferred by shape — order is the whole rule. An alternative
that resolves to another union is rejected by the aggregate pass with
`nested_union`, so dispatch stays a flat loop.

**A value that no alternative accepts fails with the diagnostic of the
one alternative its shape could have reached, when there is exactly
one; otherwise with `union_no_branch_matched`, naming the
alternatives.** Reachability is asked per value, before any refinement:
resolve each alternative's underlying and ask whether a node of this
shape (number, string, symbol, vector, form) can reach it at all. One
reachable alternative means nothing else could have been meant, so its
own cause — the bound that refused, the member set it is not in, the
head set it is outside, the reference that names nothing — is what the
author can act on. Two alternatives that share a node shape overlap,
and overlap is where order is the rule and no arm is to blame; zero
reachable is the same collapse for the opposite reason.

The rule is per *value*, so one union can be disjoint for one shape and
overlapping for another: in `[small-count big-count define-ref]` a
symbol determines the reference arm while a number reaches two and
keeps the collapse. And it stops at the node shape: two `:underlying
form` kinds with disjoint head-sets both *reach* a form, so
`[spring-form bounce-form]` keeps the collapse — deciding between them
would mean running the refinement, which is matching. Matching is
untouched throughout: no document changes verdict, only the code a
rejected one fails with.

Order being load-bearing is usually the design. `[byte-count symbol]`
means "a count if it parses as one, otherwise a name", and putting
`symbol` first would swallow every count. Write overlapping unions
narrowest-first and the order documents itself. Those two alternatives
are disjoint by shape, so a number out of `byte-count`'s range in that
slot reports the bound it broke, not the collapsed code.

**One overlap is not a design decision.** When two alternatives are
`:cross-ref` kinds pointing at *different* targets, and the document
registers the same name in both, the slot has two readings that name two
different entities — and only order decides. Neither declaration is a
duplicate, because duplicate detection is per-target, so nothing else
catches it:

```sjon
(value-kind :name render-pipeline-ref :underlying symbol
  :cross-ref (cross-ref :target render-pipeline))
(value-kind :name compute-pipeline-ref :underlying symbol
  :cross-ref (cross-ref :target compute-pipeline))
(value-kind :name pipeline-ref :underlying union
  :union (union-shape :alternatives [render-pipeline-ref compute-pipeline-ref]))
```

```sjon
(render-pipeline  :name same)
(compute-pipeline :name same)
(dispatch :pipeline same)   ; → union_ambiguous (warning)
```

`union_ambiguous` is a **warning**: the document validates, and first
match still wins — `same` is the render pipeline. What it reports is
that a second reading exists, so a consumer resolving that reference
through its own table rather than by alternative order will disagree
with the validator, silently. Rename one declaration, or split the slot
into two single-kind keys.

The check is narrow by design, because the noisy version of it would be
useless. It is silent for:

- **plain-value overlap** — `[byte-count symbol]` names no entity, and
  first-match there is the point;
- **a plain winner** — if the alternative that accepts first is a member
  set rather than a reference, the slot denotes a member, not an entity,
  and there is no "which one" to answer;
- **two alternatives onto one target** — a naming convenience; both
  readings pick out the same entity, so order decides nothing. Buckets,
  not alternatives, are what get counted, and a `:scope`d cross-ref
  splits one target into one bucket per enclosing instance.

## 5. `(form …)` declarations

A form declaration says what `(name …)` looks like in user documents.

```
(form :name <symbol>
  :open       <bool>?             ; default false
  :positional <type-ref>|(flag-set …)?  ; positional child policy; omit for none
  :discriminant <symbol>?         ; one of this form's keys; gates (variant …) (§5.3)
  :lowering   (lowering …)?       ; host-owned lowering contract; top-level forms only (§5.4)
  :description <string>?

  (key …)*                        ; zero or more (key …) sub-forms
  (variant …)*                    ; keys gated on the discriminant's value (§5.3)
  (exclusive-group …)*            ; how many of a set may be present (LANGUAGE.md §6.2.1)
  (form …)*                       ; zero or more positional slot-local forms (§5.2)
  )
```

The sub-forms of a `(form …)` declaration include its `(key …)` slots
(§5.1), `(variant …)` gates (§5.3), `(exclusive-group …)` constraints
(LANGUAGE.md §6.2.1), and inline `(form …)` **positional slot-local**
definitions (§5.2). An unrecognized sub-form head is rejected. The
`:lowering` kvpair carries a `(lowering …)` form (§5.4).

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
     :requires    <symbol-list>?  ; sibling keys this key's presence demands
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

#### `:requires` — presence implies presence

`:requires [buffer]` says: *if this key is present, `:buffer` must be
present too*. An **absent** dependent key constrains nothing, so the rule
runs one way only; mutual dependence is two `:requires` lists, and is
rejected (see below) because it is really an exclusive-group bundle.

```sjon
(form :name entry
  (key :name binding :type number     :optional false)
  (key :name buffer  :type buffer-ref :optional true)
  (key :name offset  :type byte-count :optional true :requires [buffer])
  (key :name size    :type byte-count :optional true :requires [buffer]))
```

`(entry :binding 0 :offset 256)` is `dependent_key_missing`;
`(entry :binding 0)` and `(entry :binding 0 :buffer u)` are both clean.

One diagnostic per unsatisfied **dependent key**, naming *all* of its
absent requirements — a key requiring three absent keys has one problem,
not three. Two dependent keys unsatisfied on one form produce two.

**Scope.** A base key's `:requires` may name base keys. A *variant* key's
may name that variant's keys or the form's base keys, since both are
unconditionally live once the variant is selected. The reverse — a base
key naming a variant key — is rejected: that dependency would be
conditional on the discriminant, which is what `(variant …)` is for.

**Presence** means the same thing it means for exclusive groups: written
by the author, or supplied by a materialized default when the effective
axes include overlay presence. An author who omits `:buffer` under a
schema that defaults it has, in effect, written it.

**`:open true` suppresses it**, along with every other closed-form shape
rule (`missing_required_key`, exclusive groups). An open form's declared
keys still get type-checked; the end-of-form shape sweeps do not run.

Five load-time rejections, all `invalid_manifest`:

- **self-reference** — satisfied by its own presence, so it says nothing;
- **unresolvable name** — not declared in this scope (a typo, or the
  base-names-variant case above);
- **already-required target** — the key is always present, so the
  dependency can never fire;
- **same exclusive group** — the group says "at most one of these", the
  dependency says "both";
- **cycle** — `a` requires `b`, `b` requires `a`. Satisfiable only by
  writing both or neither, which is an `exclusive-group` bundle spelled
  worse. A self-loop is reported as a self-reference, not twice.

#### Choosing between `:requires`, `exclusive-group`, and `variant`

Three mechanisms relate a form's keys, and picking the wrong one is the
common mistake. They are not interchangeable:

| Mechanism | Constrains | Reads as |
|---|---|---|
| `:requires` | one key's presence demanding another's | "if `:offset`, then also `:buffer`" |
| `(exclusive-group …)` | *how many* of a set may be present | "at most one of `:color`, `:gradient`" |
| `(variant …)` | which keys exist, given a key's **value** | "`:strip-index-format` only when `:topology` is a strip — `[triangle-strip line-strip]`" |

The test: if the rule names a specific **value**, you want a variant. If
it **counts**, you want a group. If it says "then also", you want
`:requires`. They compose freely — a key may sit in a group *and* carry
`:requires` — except for the one unsatisfiable pairing rejected above.

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

**What it exports.** The two mechanisms stack rather than replace each
other, and the exported `$children` says both: `oneOf` over exactly the
head set, **with no trailing open branch** (the slot is closed, so an
out-of-set head is rejected by the schema as well as by the validator),
each branch being the local's inline body or a `$ref` for a member that
resolved globally. `x-sjon-head-set` lists every accepted head and
`x-sjon-local-forms` the subset that resolved locally. Per-head counts
ride along as usual (§4.5). Contrast the open shape above — locals with
no head-set — which keeps the trailing `{"$form"}` branch for the
additive global fallback and therefore cannot reject anything.

A local whose name is **outside** the head-set is unreachable: narrowing
rejects the head before resolution ever consults the registry. That is a
declaration with no way to be used, so the exporter reports it
(`local_form_outside_head_set`, warning) rather than emitting a branch no
document can reach. `examples/plugins/headset-locals/` is the worked
fixture for all of this.

**Depth.** Positional locals count against the same
`Plugin.MAX_LOCAL_FORM_DEPTH` as key-locals and compose with them — a
positional local may carry `(key …)` slot-locals and vice-versa —
nesting no deeper than the shared ceiling.

### 5.3 `(variant …)` — keys gated on the discriminant's value

```
(form :name <symbol>
  :discriminant <key-name>            ; one of the form's own (key …) slots
  (key :name <key-name> :type <symbol-kind> …)
  (variant :when <symbol> | [<symbol> …]   ; the discriminant value(s) that select it
    (key …)*                              ; keys that exist only while selected
    (exclusive-group …)*)                 ; groups over this variant's keys
  …)
```

One head, several shapes, picked by a value. `:discriminant` names one
of the form's keys; its type must resolve to a `:underlying symbol`
kind with a non-empty `(member-set …)` (`discriminant_not_closed_enum`
otherwise). Each `(variant …)` declares keys that are allowed — and,
when not `:optional`, required — only while the discriminant's value
selects it. Common keys are always in scope.

**`:when` takes one value or a vector of values, and selection is
membership.** This is WebGPU's own rule for `stripIndexFormat`, read
when the topology is a strip — and there are two strips — and ignored
for the three list topologies:

```sjon
(form :name primitive
  :discriminant topology
  (key :name topology :type primitive-topology :optional true :default triangle-list)
  (variant :when [triangle-strip line-strip]
    (key :name strip-index-format :type index-format :optional true)))
```

Before `:when` took a vector that rule could not be declared: one
variant named one value, and two identical single-value variants
collided on the key (`variant_key_collision` — rightly, two declarations
of one slot can drift). One declaration reaching several values is what
keeps that check exactly as strict as it is: a key still lives in one
variant.

Rules, in the order they are checked:

- **A value selects at most one variant.** Three load-time rejections,
  all `invalid_manifest` at `[<form> variant when]`: an empty `:when []`
  (a variant nothing selects can never apply); a value listed twice in
  one `:when`; and a value two variants both list — `:when [b c]` after
  `:when [a b]`, or two variants with the same single `:when` — reported
  once per repeated value, naming the variant that already listed it.
  Otherwise "which variant applies" would fall to declaration order,
  which is exactly the question the key-collision rule exists to keep a
  schema from asking.
- **Every listed value is a member.** The aggregate pass checks each
  value against the discriminant's member set, once per value:
  `:when [triangle-strip nope]` reports `nope`
  (`unknown_discriminant_value`) and keeps `triangle-strip`, so a set
  with one typo names the typo rather than rejecting the declaration.
- **A key lives in exactly one place.** A variant key may not repeat a
  common key or another variant's key (`variant_key_collision`, at
  aggregate time). Unchanged by multi-value `:when`.
- **Selection.** The validator resolves the variant from the discriminant
  kvpair's symbol — author-written, or supplied by a `:default` under
  effective axis D (LANGUAGE.md §7.8). A variant-only key written before
  the discriminant, or under a value that selects no variant (a list
  topology above), is `unknown_key`; a form with no discriminant value
  at all is `missing_discriminant_key`; the selected variant's required
  keys, `(exclusive-group …)`s and `:requires` are swept like the
  form's own. Every message that names a variant spells its `:when` as
  the author did — `:when line-strip` bare, `:when [triangle-strip
  line-strip]` bracketed — so a single-value variant reads exactly as
  it always has.
- **A variant key's slot opt-ins follow its acceptance.** A `(key …)`
  under a variant may carry `:walk-opaque` and slot-local `(form …)`s
  like any key (§5.1); they are in scope exactly when the key is —
  while its variant is active, after the discriminant. Under another
  variant, or ahead of the discriminant, the key is `unknown_key` and
  puts nothing in scope: its value form resolves against the global
  catalog (`unknown_form` if nothing declares it) and is walked. Both
  walkers and every host answer alike; the conformance case is
  `local-form-variant-key`.
- **`:open true`** suppresses the discriminant and variant sweeps with
  every other closed-shape rule (§5).

Export does not multiply the branch. JSON Schema guards the variant's one
`if/then` with `const` for a single value and `enum` for several, and
lists the values under `x-sjon-discriminant` (`"when": "a"` /
`"when": ["a", "b"]` — the manifest's own spelling); TypeScript narrows
the discriminant brand to `Symbol_<"triangle-strip" | "line-strip">` and
adds one residual branch for the members no variant selects, so a
`triangle-list` primitive has a type; Markdown heads the variant
`:topology [triangle-strip line-strip]`. See `docs/SCHEMA_EXPORT.md`.
`examples/plugins/variant-set/` is the fixture for all of this.

### 5.4 `(lowering …)` — a host-owned lowering contract

```
:lowering (lowering
  :hook     <symbol>              ; contract id, by convention <vendor>/<surface>-v<n>
  :produces [<symbol> …])         ; closed set of form heads the hook may emit; non-empty, no repeats
```

`:lowering` marks the form as *surface sugar*: a host that implements
`:hook` lowers each instance into ordinary forms before final validation.
The manifest carries the declaration only — the hook is host code, never
manifest content — and a host without the hook must fail loudly
(`lowering_hook_missing`) rather than validate the sugar as final data.
Runtime semantics (staging, limits, provenance, container lowering) are
in `docs/plugin-model-v1.md`, "Host Lowering"; this section is the
manifest side.

**`:produces` resolution.** The contract checks every emitted form's head
against `:produces`, at every depth, so the list names every head the
hook writes, nested ones included. At schema load every entry must
resolve to a declared form, and a bare entry resolves **local-first**,
the same order a form head takes at validation (§5.2, LANGUAGE.md
§6.3.1): a bare entry may name a **slot-local form reachable through the
list** — declared, at any depth and through either carrier, inside a form
the same list resolves — or a global form across the loaded plugins,
where a bare collision is `ambiguous_form`. A qualified entry
(`<plugin>/<form>`) targets that plugin's global catalog and bypasses
locals. A local listed without its declaring form is `unknown_form`, and
the message names the form the list is missing.

```sjon
(form :name init
  :lowering (lowering :hook pngine/init-v1
    :produces [bind-group entry]))          ; `entry` resolves through `bind-group`
(form :name bind-group
  (form :name entry (key :name binding :type number :optional false)))
```

**Load-time refusals.** An empty `:produces` or a head listed twice is
`wrong_underlying` at `[<form> lowering produces]`. `:lowering` on a
**slot-local** form (either carrier) is `invalid_manifest` at
`[<local> lowering]` — a local body is never a hook, so the declaration
would be silently dead; declare the sugar as a top-level `(form …)`. A
`:produces` graph that cycles is `lowering_cycle` at aggregate time; a
qualified head into a plugin that is not loaded is
`lowering_target_plugin_absent`.

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

`<member-name>` is a member spelling: a bare symbol, or a
digit-leading spelling that lexes as a unit-bearing number (`1d`, `2d`).
`<member-name-list>` is a `[…]` vector of those: `[1d 2d cube 3d]`. Both
appear only inside `(member-set …)` — see §4.4 for which numbers count as
spellings and the four conditions that reject the rest.

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
  The key is optional: a manifest that declares none is *unversioned*, not
  invalid — it loads and validates like any other, the CLI prints its
  version as `?`, and the lockfile records an empty row. A pin is a claim
  about a version the manifest declares, so pinning an unversioned plugin
  is a `plugin_version_mismatch` whose message says the manifest declares
  no `:version`.

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
- `number_not_multiple` — value is not an exact multiple of
  `:multiple-of`. Checked after `:integer` and after the range bounds,
  so a value that also fails one of those reports that instead.
- `dependent_key_missing` — a key carrying `:requires` is present while
  one or more keys it names is absent. One per unsatisfied dependent
  key, naming every absent requirement (§5.1).
- `numeric_bound_unit_mismatch` — bound carries a unit but the
  value either has none or carries a different unit.
- `positional_too_many` — a form carries more positional children of one
  head than that head's `:max` allows. Reported at the child that
  crosses the ceiling, with that child's positional path step; once per
  crossing, not once per child past it (§4.5).
- `positional_missing` — a form carries fewer positional children of one
  head than that head's `:min` requires. Reported at the parent form's
  head span with the parent's path, once per unsatisfied head (§4.5).
  Neither code is suppressed by `:open true`, which widens the *keyword*
  surface only.

Validate-time union code, severity `warning` — the document still
validates and first match still wins:

- `union_ambiguous` — a symbol in a `:underlying union` slot is a
  registered name in two or more of the union's `:cross-ref`-backed
  alternatives, so declaration order decides which entity the slot
  denotes. Silent for plain-value overlap, for a winning alternative
  that is not itself a reference, and for two alternatives pointing at
  one target (§4.9).

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
5. **`:version` is the resolver's pin target, and optional.** Exact-string
   match against `(use-plugin … :version "x")`; absent = unversioned, and
   a pin against it is a mismatch. Settled (§9).
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

The format evolves additively, and it carries no version of its own:

- New optional keys may be added to existing declarations, and new
  refinement axes to `value-kind`. A manifest that omits them means what
  it always meant.
- New `:impl` schemes may be added (`wasm:`, `native:`, …). Loaders
  treat unknown schemes as "validation works, evaluation unavailable."
- New `expr-func` encodings may be added. Mono and multi-signature are
  the current set; future encodings get a distinct positional sub-form
  shape.

A manifest read by a host *older* than the vocabulary it uses fails
loudly, not partially: every form in `manifests/meta.sjon` is
`:open false`, so an unknown keyword is `unknown_key` and an unknown
declaration head is `unknown_form` at meta-validation, and the plugin is
dropped. Which SJON release a keyword needs is what `CHANGELOG.md`
records; nothing in the manifest declares it.

Removing or renaming a declaration is a breaking change, and takes a
SJON major.
