# 14 - Diagnostics-Driven Repair

## Goal

Turn a diagnostic into a repair mechanically: read the code, know which
layer of the contract it belongs to, and fix that layer rather than
guessing at the one next to it.

## Read the Code, Not the Sentence

Every diagnostic SJON emits carries a **code**, a snake_case identifier
like `unknown_key` or `vector_too_short`, alongside its prose message, a
source span, and a semantic path. The code is the part to build a habit
around, for two reasons. It is wire-stable, so it means the same thing
in this release and the next one, which the wording of a message does
not promise. And it names a *layer*, which is what tells you where to
look.

That last point is the whole method. Write this against the shapes
plugin and you get two diagnostics, both of them
`positional_not_allowed`, both saying that `circle` does not accept
positional children:

```sjon del={1}
(circle :center [0 0] :radius 1 :fill :evenodd)
```

Read that literally and you go looking for a stray child form. There is
no child form. What happened is the pairing rule from
[Forms and keyword pairing](05-forms-and-keyword-pairing.md): `:fill`
could not pair with `:evenodd`, so both became positional flags, and
`circle` accepts no positionals. The count is the tell, incidentally,
since two complaints from one mistake means two children appeared where
you wrote one thing. The diagnostic is telling the truth about the tree,
and the tree is not what you thought you wrote. Fixing the layer it
names would mean deleting children that do not exist; fixing the layer
*underneath* it takes one character:

```sjon ins={1}
(circle :center [0 0] :radius 1 :fill evenodd)
```

So the first move on any diagnostic is to place the code in the stack:

```
vocabulary        unknown head or key, or a head outside a slot's local form set
form contract     duplicate key, missing key, positional placement
value shape       wrong underlying kind, wrong vector length
kind refinement   member, head, unit, bound, or representation error
union             no alternative accepted the value
expression        arity, typed argument, or kvpair in a call
cross-reference   name undeclared, duplicated, cyclic, or out of scope
exclusive group   too many or too few alternatives present
```

Then work the code first and the prose second.

Stable codes you are likely to see while authoring:

| Code | Usual repair direction |
| --- | --- |
| `unknown_form` / `ambiguous_form` / `ambiguous_expr` | Check the head spelling, loaded plugin set, or qualify with `plugin/head`. |
| `unknown_key` / `duplicate_key` / `missing_required_key` | Check the form's key table. |
| `positional_not_allowed` | Move the child under a containing form or into a form-valued key. |
| `wrong_underlying` / `vector_length_mismatch` | Match the declared value shape. |
| `vector_too_short` / `vector_too_long` | Add or drop elements to land in the kind's `:min-len`/`:max-len` window (distinct from a fixed `:len`). |
| `repr_out_of_range` | Bring the number into the `:repr` type's range, and make it whole for an integer type (`u16`/`u32`/`i32`). |
| `unit_required` / `unit_not_allowed` | Add an allowed unit suffix. |
| `unit_forbidden` | Drop the unit suffix; the kind rejects every unit, which is distinct from a suffix outside an allowed list. |
| `not_member` / `not_head_member` | Use one of the plugin's closed-set values or heads. |
| `unknown_local_form` | Use a head the slot accepts: a local form the message lists, or a known global head. |
| `union_no_branch_matched` | Read the listed alternatives (the message names every shape the slot accepts) and rewrite the value to fit one of them. You see this code when the value's shape reaches none of the alternatives, or two or more; when it reaches exactly one, the slot reports that alternative's own code instead. |
| `expr_kvpair_not_allowed` / `arity_mismatch` / `expr_type_mismatch` | Rewrite the expression call shape. |
| `not_cross_ref` | Spell the referenced name correctly, or add the missing declaration. |
| `duplicate_cross_ref_target` | Rename one of the two declarations or remove the duplicate. |
| `cyclic_cross_ref` | Break the cycle in the chain (typically a `:parent`-style key). |
| `cross_ref_outside_scope` | Move the reference inside the enclosing scope form, or declare the name in the right scope. |
| `cross_ref_extraction_failed` | Fix the source string the diagnostic points at; a provider read it and rejected it, so the names inside are unknown. |
| `cross_ref_provider_unavailable` | Nothing in the document to repair: this host cannot run the provider, so those names go unchecked here. |
| `missing_discriminant_key` | Add the discriminant key (e.g. `:kind`) to the form. |
| `unknown_key` (with discriminant-first hint) | Reorder so the discriminant key precedes any variant-only key. |
| `mutually_exclusive_keys_present` | Remove all but one alternative from the group the message names. |
| `required_one_of_missing` | Add exactly one of the alternatives the message names. |

## Worked Example

The pairing case from the opening is the first half of this drill, so
here is the second. Broken:

```sjon del={1}
(badge :label "x" :shape (group :name "oops"))
```

Likely diagnostic: `not_head_member`. The `:shape` slot accepts only
specific form heads. Repair with an allowed form:

```sjon ins={1}
(badge :label "x" :shape (circle :center [0 0] :radius 1))
```

## Exercises

Predict the diagnostic category and repair each example.

Unknown form:

```sjon del={1}
(circl :center [0 0] :radius 1)
```

Repair:

```sjon ins={1}
(circle :center [0 0] :radius 1)
```

Unknown key:

```sjon del={1}
(canvas :width 320 :height 240)
```

Repair:

```sjon ins={1}
(canvas :w 320 :h 240)
```

Duplicate key:

```sjon del={1}
(scene :title "a" :title "b")
```

Repair by choosing one value:

```sjon ins={1}
(scene :title "b")
```

Missing required key. This one is a schema-reading drill: assume the
plugin docs say `(circle ...)` requires both `:center` and `:radius`.

```sjon del={1}
(circle :center [0 0])
```

Repair:

```sjon ins={1}
(circle :center [0 0] :radius 1)
```

Wrong underlying kind:

```sjon del={1}
(circle :center "middle" :radius 1)
```

Repair:

```sjon ins={1}
(circle :center [0 0] :radius 1)
```

Arity mismatch:

```sjon del={1}
(shape :sdf :radius (lerp 0 10))
```

Repair:

```sjon ins={1}
(shape :sdf :radius (lerp 0 10 0.5))
```

Typed expression mismatch:

```sjon del={1}
(vec3 1 "two" 3)
```

`vec3` takes three numbers:

```sjon ins={1}
(vec3 1 2 3)
```

If you meant a scalar radius, use a scalar expression instead:

```sjon
(shape :sdf :radius (* 2 16))
```

Member set mismatch:

```sjon del={1}
(circle :center [0 0] :radius 1 :fill diagonal)
```

Repair:

```sjon ins={1}
(circle :center [0 0] :radius 1 :fill nonzero)
```

Unit mismatch. Assume `duration` allows `s | ms | b`:

```sjon del={1}
(delay :wait 4px)
```

Repair with an allowed suffix:

```sjon ins={1}
(delay :wait 4b)
```

Head set mismatch:

```sjon del={1}
(badge :label "x" :shape (group :name "oops"))
```

Repair:

```sjon ins={1}
(badge :label "x" :shape (rect :origin [0 0] :size [10 10]))
```

Variable-length vector. Assume `:position` is documented as
`vector, length 2-4`, a range rather than a fixed `:len`:

```sjon del={1}
(vertex :position [0.0])
```

Likely diagnostic: `vector_too_short` (the floor is 2; a fixed-length
kind fires `vector_length_mismatch` instead). Repair into range:

```sjon ins={1}
(vertex :position [0.0 1.0])
```

Representation out of range. Assume `:tint` is documented as
`number, repr u16`:

```sjon del={1}
(vertex :tint 70000)
```

Likely diagnostic: `repr_out_of_range`. `u16` tops out at `65535`, and
an integer type also rejects a fractional value. Repair into range:

```sjon ins={1}
(vertex :tint 65535)
```

Unit rejected. Assume `:lod-bias` is documented as
`number, unit rejected`:

```sjon del={1}
(draw :lod-bias 0.5f)
```

Likely diagnostic: `unit_forbidden`. The slot takes bare numbers; the
trailing `f` lexes as a unit suffix. Repair by dropping it:

```sjon ins={1}
(draw :lod-bias 0.5)
```

Slot-local form. Assume `canvas`'s `:shape` slot defines local forms
`circle | rect | group`:

```sjon del={1}
(canvas :shape (triangle))
```

Likely diagnostic: `unknown_local_form`, listing the slot's local
heads, which is more specific than a top-level `unknown_form`. Repair with a
head the slot accepts:

```sjon ins={1}
(canvas :shape (circle :r 12))
```

Union no-branch matched. Assume `:notes` is documented as
`vector<note-or-event>` where `note-or-event = note-or-rest | event`
and `event` is a form with head `n` or `rest`:

```sjon del={1}
(phrase :notes [E4 42])
```

Likely diagnostic: `union_no_branch_matched` listing the alternatives
(`note-or-rest`, `event`). The number `42` is neither a pitch symbol
nor an event form, and since no alternative takes numbers there is no
single one to blame. Write a *symbol* the set does not contain and the
message changes: only `note-or-rest` takes symbols, so you get its
`not_member` instead. Repair with a value matching either alternative:

```sjon ins={1}
(phrase :notes [E4 (n G4 0.5b)])
```

Union with a `form` alternative, which is the wildcard pitfall. Assume the
plugin documents `:value` as `number | vec4 | form`:

```sjon del={1}
(set :value (foo 1 2))
```

Likely diagnostic: `unknown_form` (not `union_no_branch_matched`).
The `form` alternative still resolves the form's head against the
schema; "any form" is not the same as "any parens." Repair by using
a form whose head the schema knows:

```sjon ins={1}
(set :value (+ 1 2))
```

Ambiguous form. Assume two loaded plugins both declare `circle`:

```sjon del={1}
(circle :center [0 0] :radius 1)
```

Repair by qualifying the domain head:

```sjon ins={1}
(shapes/circle :center [0 0] :radius 1)
```

Discriminant absent. Assume `(track ...)` is documented with
`discriminant: kind` and variants `kick | groove | animation`:

```sjon del={1}
(track :name k1 :from 0)
```

Likely diagnostic: `missing_discriminant_key`. Repair:

```sjon ins={1}
(track :kind kick :name k1 :step 4 :from 0)
```

Discriminant out of order. The variant key `:step` is written before
`:kind`:

```sjon del={1}
(track :name k1 :step 4 :kind kick)
```

Likely diagnostic: `unknown_key` on `:step` with a hint that the
discriminant must be set first. Repair by placing `:kind` before any
variant-only key:

```sjon ins={1}
(track :kind kick :name k1 :step 4)
```

Cross-variant key. `:mesh` is an `animation`-variant key, but
`:kind = kick`:

```sjon del={1}
(track :kind kick :name k1 :mesh logo)
```

Likely diagnostic: `unknown_key` (no hint, because the discriminant is set and the
key just isn't valid under this variant). Repair by changing the
discriminant or removing the wrong-variant key:

```sjon ins={1}
(track :kind animation :name k1 :mesh logo)
```

Exclusive-group violation. Assume `(phrase ...)` is documented with
an `exactly-one` group over `:notes | :events`:

```sjon del={1}
(phrase :name p0 :notes [E4 G4] :events [(n A4 0.5b)])
```

Likely diagnostic: `mutually_exclusive_keys_present` listing
`:notes | :events`. Repair by keeping one alternative:

```sjon ins={1}
(phrase :name p0 :notes [E4 G4])
```

Required-one-of missing. Same `(phrase ...)` summary:

```sjon
(phrase :name p1)
```

Likely diagnostic: `required_one_of_missing`. Repair by adding one
of the alternatives:

```sjon
(phrase :name p1 :events [(n A4 0.5b)])
```

Cross-reference miss. Assume the plugin's `:sequence` slot expects
`vector<phrase-name>` and only `p0` is declared:

```sjon
(phrase :name p0 :notes [E4 G4 A4 G4])

(track :sequence [p0 p1])
```

Likely diagnostic: `not_cross_ref` at `[track sequence]`. Repair by
adding the missing phrase or fixing the spelling:

```sjon ins={2}
(phrase :name p0 :notes [E4 G4 A4 G4])
(phrase :name p1 :notes [B4 A4 G4 E4])

(track :sequence [p0 p1])
```

[Cross-references](13-cross-references.md) covers these shapes in
detail.

## LSP Quickfixes

SJON's language server offers single-step quickfixes for the
diagnostics it can repair without guessing. The action title tells you
what it will do; review before applying.

| Diagnostic | Quickfix title | What it does |
| --- | --- | --- |
| `unknown_form` | `Replace with `<head>`` | Substitute the typo with the closest known head (Levenshtein-bounded). |
| `unknown_key` | `Replace with `:<key>`` | Substitute the typo with the closest declared key on this form. |
| `ambiguous_form` | `Qualify with `<plugin>/<head>`` | One action per claimant plugin. |
| `missing_required_key` | `Insert `:<key>` with stub` | Insert each missing required key with a typed placeholder value. |
| `expr_kvpair_not_allowed` | `Drop `:<key>` (keep value)` | Strip the keyword tag, leave the value as a positional argument. |
| `duplicate_key` | `Remove duplicate `:<key>`` | Delete the later occurrence and its preceding whitespace. |
| `not_cross_ref` | `Replace with `<name>`` | Replace the symbol with the closest in-scope registered name. |
| `cross_ref_outside_scope` | `Replace with `<name>`` | Surfaces only when an in-scope alternative exists; otherwise no fix (move the reference instead). |
| `not_member` | `Replace with `<name>`` | Replace the value with the closest non-deprecated member of the slot's enum. |

For typo-style fixes, only the single closest candidate within
Levenshtein distance 3 is offered; farther typos return no action so
the suggestion can't mislead.

## Mastery Check

- Which diagnostic category usually means you misspelled a key?
- Which category points to a closed enum-like value?
- Which category points to a mistyped expression literal?
- Why can `positional_not_allowed` be caused by keyword pairing?
- Why should tooling match diagnostic codes rather than message prose?
- On a discriminated form, what's the difference between an
  `unknown_key` with the discriminant-first hint and one without?
- For a slot whose value kind is `number | vec4 | form`, why does
  `(set :value (foo 1 2))` produce `unknown_form` rather than
  `union_no_branch_matched`?
- For an `exactly-one` exclusive group, which two diagnostic codes
  cover the "too many" and "too few" cases, and how does the message
  tell you which alternatives to choose between?
- Which diagnostic separates a fixed-length vector slot from a
  variable-length one, and what does each fire?
- What is the difference between `unit_not_allowed` and
  `unit_forbidden`?
- Why does a bad form head inside a slot that declares local forms
  produce `unknown_local_form` rather than `unknown_form`?

Next: [Style, Portability, and Capstone](15-style-portability-and-capstone.md).
