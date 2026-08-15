---
type: lesson
title: 'Diagnostics-Driven Repair'
---

## Mental Model

Diagnostics are not just error messages. They tell you which layer of
authoring went wrong:

- Unknown head or key, or a form head outside a slot's local form
  set: vocabulary mismatch.
- Duplicate or missing key: form contract mismatch.
- Wrong underlying kind, or a vector with the wrong number of
  elements: value shape mismatch.
- Member, head, unit, bound, or representation error: value kind
  refinement mismatch.
- Union of alternatives, no match: the value didn't fit any alternative
  the plugin declared for this slot.
- Expression arity, typed-argument, or kvpair error: expression contract
  mismatch.
- Positional error: child placement or keyword-pairing mismatch.
- Cross-reference resolution failure: name not declared, duplicated,
  cyclic, or outside its lexical scope.
- Exclusive-group cardinality error: the form declares an
  exactly-one-of (or at-most-one-of) rule and the source presents
  too many or too few alternatives.

Work from the diagnostic code first, then from the prose message.

Stable codes you are likely to see while authoring:

<div class="codes-sticky">

| Code | Usual repair direction |
| --- | --- |
| `unknown_form` / `ambiguous_form` / `ambiguous_expr` | Check the head spelling, loaded plugin set, or qualify with `plugin/head`. |
| `unknown_key` / `duplicate_key` / `missing_required_key` | Check the form's key table. |
| `positional_not_allowed` | Move the child under a containing form or into a form-valued key. |
| `wrong_underlying` / `vector_length_mismatch` | Match the declared value shape. |
| `vector_too_short` / `vector_too_long` | Add or drop elements to land in the kind's `:min-len`/`:max-len` window (distinct from a fixed `:len`). |
| `repr_out_of_range` | Bring the number into the `:repr` type's range, and make it whole for an integer type (`u16`/`u32`/`i32`). |
| `unit_required` / `unit_not_allowed` | Add an allowed unit suffix. |
| `unit_forbidden` | Drop the unit suffix - the kind rejects every unit (distinct from a suffix outside an allowed list). |
| `not_member` / `not_head_member` | Use one of the plugin's closed-set values or heads. |
| `unknown_local_form` | Use a head the slot accepts - a local form the message lists, or a known global head. |
| `union_no_branch_matched` | Read the listed alternatives - the message names every shape the slot accepts - and rewrite the value to fit one of them. |
| `expr_kvpair_not_allowed` / `arity_mismatch` / `expr_type_mismatch` | Rewrite the expression call shape. |
| `not_cross_ref` | Spell the referenced name correctly, or add the missing declaration. |
| `duplicate_cross_ref_target` | Rename one of the two declarations or remove the duplicate. |
| `cyclic_cross_ref` | Break the cycle in the chain (typically a `:parent`-style key). |
| `cross_ref_outside_scope` | Move the reference inside the enclosing scope form, or declare the name in the right scope. |
| `cross_ref_extraction_failed` | Fix the source string the diagnostic points at - a provider read it and rejected it, so the names inside are unknown. |
| `cross_ref_provider_unavailable` | Nothing in the document to repair: this host cannot run the provider, so those names go unchecked here. |
| `missing_discriminant_key` | Add the discriminant key (e.g. `:kind`) to the form. |
| `unknown_key` (with discriminant-first hint) | Reorder so the discriminant key precedes any variant-only key. |
| `mutually_exclusive_keys_present` | Remove all but one alternative from the group the message names. |
| `required_one_of_missing` | Add exactly one of the alternatives the message names. |

</div>

## Worked Example

Broken:

```sjon
(circle :center [0 0] :radius 1 :fill :evenodd)
```

Likely symptoms:

- `:fill` does not pair with `:evenodd`.
- Both become positional flags.
- `circle` does not accept positional children.

The real mistake is not "fill rule unknown"; it is keyword pairing.
Repair:

```sjon
(circle :center [0 0] :radius 1 :fill evenodd)
```

Broken:

```sjon
(badge :label "x" :shape (group :name "oops"))
```

Likely diagnostic: `not_head_member`. The `:shape` slot accepts only
specific form heads. Repair with an allowed form:

```sjon
(badge :label "x" :shape (circle :center [0 0] :radius 1))
```

## Exercises

Predict the diagnostic category and repair each example.

Unknown form:

```sjon
(circl :center [0 0] :radius 1)
```

Repair:

```sjon
(circle :center [0 0] :radius 1)
```

Unknown key:

```sjon
(canvas :width 320 :height 240)
```

Repair:

```sjon
(canvas :w 320 :h 240)
```

Duplicate key:

```sjon
(scene :title "a" :title "b")
```

Repair by choosing one value:

```sjon
(scene :title "b")
```

Missing required key. This one is a schema-reading drill: assume the
plugin docs say `(circle ...)` requires both `:center` and `:radius`.

```sjon
(circle :center [0 0])
```

Repair:

```sjon
(circle :center [0 0] :radius 1)
```

Wrong underlying kind:

```sjon
(circle :center "middle" :radius 1)
```

Repair:

```sjon
(circle :center [0 0] :radius 1)
```

Arity mismatch:

```sjon
(shape :sdf :radius (lerp 0 10))
```

Repair:

```sjon
(shape :sdf :radius (lerp 0 10 0.5))
```

Typed expression mismatch:

```sjon
(vec3 1 "two" 3)
```

`vec3` takes three numbers:

```sjon
(vec3 1 2 3)
```

If you meant a scalar radius, use a scalar expression instead:

```sjon
(shape :sdf :radius (* 2 16))
```

Member set mismatch:

```sjon
(circle :center [0 0] :radius 1 :fill diagonal)
```

Repair:

```sjon
(circle :center [0 0] :radius 1 :fill nonzero)
```

Unit mismatch. Assume `duration` allows `s | ms | b`:

```sjon
(delay :wait 4px)
```

Repair with an allowed suffix:

```sjon
(delay :wait 4b)
```

Head set mismatch:

```sjon
(badge :label "x" :shape (group :name "oops"))
```

Repair:

```sjon
(badge :label "x" :shape (rect :origin [0 0] :size [10 10]))
```

Variable-length vector. Assume `:position` is documented as
`vector, length 2-4` - a range, not a fixed `:len`:

```sjon
(vertex :position [0.0])
```

Likely diagnostic: `vector_too_short` (the floor is 2; a fixed-length
kind fires `vector_length_mismatch` instead). Repair into range:

```sjon
(vertex :position [0.0 1.0])
```

Representation out of range. Assume `:tint` is documented as
`number, repr u16`:

```sjon
(vertex :tint 70000)
```

Likely diagnostic: `repr_out_of_range`. `u16` tops out at `65535`, and
an integer type also rejects a fractional value. Repair into range:

```sjon
(vertex :tint 65535)
```

Unit rejected. Assume `:lod-bias` is documented as
`number, unit rejected`:

```sjon
(draw :lod-bias 0.5f)
```

Likely diagnostic: `unit_forbidden`. The slot takes bare numbers; the
trailing `f` lexes as a unit suffix. Repair by dropping it:

```sjon
(draw :lod-bias 0.5)
```

Slot-local form. Assume `canvas`'s `:shape` slot defines local forms
`circle | rect | group`:

```sjon
(canvas :shape (triangle))
```

Likely diagnostic: `unknown_local_form`, listing the slot's local
heads - more specific than a top-level `unknown_form`. Repair with a
head the slot accepts:

```sjon
(canvas :shape (circle :r 12))
```

Union no-branch matched. Assume `:notes` is documented as
`vector<note-or-event>` where `note-or-event = note-or-rest | event`
and `event` is a form with head `n` or `rest`:

```sjon
(phrase :notes [E4 42])
```

Likely diagnostic: `union_no_branch_matched` listing the alternatives
(`note-or-rest`, `event`). The number `42` is neither a pitch symbol
nor an event form. Repair with a value matching either alternative:

```sjon
(phrase :notes [E4 (n G4 0.5b)])
```

Union with `form` alternative - the wildcard pitfall. Assume the
plugin documents `:value` as `number | vec4 | form`:

```sjon
(set :value (foo 1 2))
```

Likely diagnostic: `unknown_form` (not `union_no_branch_matched`).
The `form` alternative still resolves the form's head against the
schema; "any form" is not the same as "any parens." Repair by using
a form whose head the schema knows:

```sjon
(set :value (+ 1 2))
```

Ambiguous form. Assume two loaded plugins both declare `circle`:

```sjon
(circle :center [0 0] :radius 1)
```

Repair by qualifying the domain head:

```sjon
(shapes/circle :center [0 0] :radius 1)
```

Discriminant absent. Assume `(track ...)` is documented with
`discriminant: kind` and variants `kick | groove | animation`:

```sjon
(track :name k1 :from 0)
```

Likely diagnostic: `missing_discriminant_key`. Repair:

```sjon
(track :kind kick :name k1 :step 4 :from 0)
```

Discriminant out of order. The variant key `:step` is written before
`:kind`:

```sjon
(track :name k1 :step 4 :kind kick)
```

Likely diagnostic: `unknown_key` on `:step` with a hint that the
discriminant must be set first. Repair by placing `:kind` before any
variant-only key:

```sjon
(track :kind kick :name k1 :step 4)
```

Cross-variant key. `:mesh` is an `animation`-variant key, but
`:kind = kick`:

```sjon
(track :kind kick :name k1 :mesh logo)
```

Likely diagnostic: `unknown_key` (no hint - discriminant is set, the
key just isn't valid under this variant). Repair by changing the
discriminant or removing the wrong-variant key:

```sjon
(track :kind animation :name k1 :mesh logo)
```

Exclusive-group violation. Assume `(phrase ...)` is documented with
an `exactly-one` group over `:notes | :events`:

```sjon
(phrase :name p0 :notes [E4 G4] :events [(n A4 0.5b)])
```

Likely diagnostic: `mutually_exclusive_keys_present` listing
`:notes | :events`. Repair by keeping one alternative:

```sjon
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

```sjon
(phrase :name p0 :notes [E4 G4 A4 G4])
(phrase :name p1 :notes [B4 A4 G4 E4])

(track :sequence [p0 p1])
```

Chapter 13 covers cross-reference shapes in detail.

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

<section class="mastery-quiz" data-lesson="diagnostics-driven-repair">
  <h2>Mastery Check</h2>
  <ol class="mc-list">
    <li class="mc-item" data-correct="1">
      <p class="mc-q">Which diagnostic category usually means you misspelled a key?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-0" value="0" /> <span><code>wrong_underlying</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-0" value="1" /> <span><code>unknown_key</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-0" value="2" /> <span><code>union_no_branch_matched</code>.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">Which category points to a closed enum-like value?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-1" value="0" /> <span><code>not_member</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-1" value="1" /> <span><code>expr_kvpair_not_allowed</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-1" value="2" /> <span><code>positional_not_allowed</code>.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="2">
      <p class="mc-q">Why should tooling match diagnostic codes rather than message prose?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-2" value="0" /> <span>Codes are shorter to type.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-2" value="1" /> <span>Prose is localized; codes are not.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-2" value="2" /> <span>Codes are the stable contract - message prose may change between releases.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">Why can <code>positional_not_allowed</code> be caused by keyword pairing?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-3" value="0" /> <span>When two keywords sit next to each other neither pairs into a kvpair, so they become positional flags - and a form that disallows positional children flags them.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-3" value="1" /> <span>It can't - pairing always succeeds.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-3" value="2" /> <span>Only when expressions are involved.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">For an <code>exactly-one</code> exclusive group, which two codes cover &quot;too many&quot; vs. &quot;too few&quot;?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-4" value="0" /> <span><code>unknown_key</code> and <code>missing_required_key</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-4" value="1" /> <span><code>mutually_exclusive_keys_present</code> (too many) and <code>required_one_of_missing</code> (too few).</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-4" value="2" /> <span><code>duplicate_key</code> and <code>not_member</code>.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">A vector value is rejected. Which diagnostic tells you the slot has a fixed length rather than a variable-length range?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-5" value="0" /> <span><code>vector_length_mismatch</code> (fixed <code>:len</code>); a range fires <code>vector_too_short</code> / <code>vector_too_long</code>.</span></label>
        <p class="mc-explanation" hidden>Correct. A fixed <code>:len</code> fires <code>vector_length_mismatch</code>; a <code>:min-len</code>/<code>:max-len</code> range fires <code>vector_too_short</code> or <code>vector_too_long</code> at the edges.</p>
      </li>
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-5" value="1" /> <span><code>vector_too_short</code> for both fixed and variable slots.</span></label>
        <p class="mc-explanation" hidden><code>vector_too_short</code> is the variable-length floor only - a fixed-length slot reports <code>vector_length_mismatch</code>.</p>
      </li>
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-5" value="2" /> <span><code>wrong_underlying</code> in every case.</span></label>
        <p class="mc-explanation" hidden><code>wrong_underlying</code> means the value was not a vector at all; here the value is a vector of the wrong length.</p>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">What separates <code>unit_not_allowed</code> from <code>unit_forbidden</code>?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-6" value="0" /> <span>They are the same code under two names.</span></label>
        <p class="mc-explanation" hidden>They are distinct, wire-stable codes for distinct rules.</p>
      </li>
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-6" value="1" /> <span><code>unit_not_allowed</code> means the suffix is outside an allowed list; <code>unit_forbidden</code> means the kind rejects every unit.</span></label>
        <p class="mc-explanation" hidden>Correct. An allowed list rejects an off-list suffix with <code>unit_not_allowed</code>; a reject kind takes bare numbers only and fires <code>unit_forbidden</code> for any suffix.</p>
      </li>
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-6" value="2" /> <span><code>unit_forbidden</code> is only for dates.</span></label>
        <p class="mc-explanation" hidden>No - <code>unit_forbidden</code> fires on a number-underlying kind that rejects all unit suffixes, closing the <code>1.0f -&gt; 0</code> trap.</p>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">Why does a bad form head inside a slot with local forms produce <code>unknown_local_form</code> rather than <code>unknown_form</code>?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-7" value="0" /> <span>The slot narrowed the choices, so the message can list the local heads it accepts.</span></label>
        <p class="mc-explanation" hidden>Correct. The slot carries its own local form set, so the resolver reports <code>unknown_local_form</code> and names the local heads (the global fallback still applies).</p>
      </li>
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-7" value="1" /> <span>It is a typo for <code>unknown_form</code>.</span></label>
        <p class="mc-explanation" hidden>They are separate codes: <code>unknown_local_form</code> is the slot-scoped version, more specific than the top-level <code>unknown_form</code>.</p>
      </li>
      <li>
        <label><input type="radio" name="q-diagnostics-driven-repair-7" value="2" /> <span>Local forms disable the global vocabulary entirely.</span></label>
        <p class="mc-explanation" hidden>Local forms are additive - a non-local head still falls back to the global vocabulary; only a head matching neither fails.</p>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
  </ol>
  <div class="mc-controls">
    <button type="button" class="mc-submit">Submit answers</button>
    <button type="button" class="mc-reset" hidden>Reset</button>
    <p class="mc-score" hidden></p>
  </div>
</section>
