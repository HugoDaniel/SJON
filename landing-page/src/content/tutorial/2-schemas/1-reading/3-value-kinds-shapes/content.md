---
type: lesson
title: 'Value Kinds: Shapes, Vectors, Units, Bounds, Representation'
---

## Mental Model

The phrase "value kind" appears in two related places:

- The parser sees base value kinds: `number`, `string`, `symbol`,
  `vector`, `form`, and so on.
- A plugin can give a name to a narrower contract: `length`, `point`,
  `fill-rule`, `shape-form`, `duration`, `note-or-event`.

The named kind is not new syntax. If a slot is typed `point`, you do not
write `point(160 120)` or `:point [160 120]`. You write the value whose
shape satisfies the kind:

```sjon
(circle :center [160 120])
```

Read a named kind in this order:

1. **Underlying shape** - should the value be a number, string, symbol,
   vector, form, or union?
2. **Refinement** - does the kind add a vector length, unit rule,
   representation tag, closed member list, allowed head list, or list
   of alternatives?
3. **Surface value** - what do you actually type in the document?

You do not define value kinds while authoring a document. You read the
plugin docs and write values that satisfy them.

Cross-references are also implemented as value-kind refinements, but
they deserve their own authoring model. Chapter 13 covers them.

## Worked Example

The reference shapes plugin can be summarized like this:

```text
(circle ...)
  :center point optional
  :radius length optional
  :fill fill-rule optional

(badge ...)
  :label string optional
  :shape shape-form optional

length: number
point: vector, length 2, element number
fill-rule: symbol, members evenodd | nonzero
shape-form: form, heads circle | rect
```

Now write the source from the contract:

```sjon
(circle :center [160 120] :radius 32 :fill evenodd)

(badge :label "dot"
  :shape (circle :center [0 0] :radius 1))
```

Read the first form slowly:

- `:center point` means "write a vector with two numeric elements."
- `:radius length` means "write a number."
- `:fill fill-rule` means "write one of the listed symbols."

Read the second form:

- `:label string` means "write quoted text."
- `:shape shape-form` means "write a nested form, but only with an
  allowed head."

The important habit: start from the slot line, then jump to the named
kind line. The slot tells you which kind applies; the kind tells you
which value shape is accepted.

## Underlying Shape First

Before worrying about refinements, make the broad shape match.

```sjon
(circle :center "160,120" :radius 32)
```

This fails before the validator even cares about length 2. `point` is
vector-underlying, so a string is the wrong underlying shape. Repair by
using brackets:

```sjon
(circle :center [160 120] :radius 32)
```

Likewise:

```sjon
(circle :center [160 120] :radius "32")
```

`:radius` is `length`, and `length` is number-underlying. A string
produces `wrong_underlying`. Repair with a number:

```sjon
(circle :center [160 120] :radius 32)
```

## Vector Shapes

A vector refinement usually answers two questions:

- How many elements?
- What kind should each element have?

For `point`:

```text
point: vector, length 2, element number
```

That accepts:

```sjon
[0 0]
[160 120]
[1.5 -2]
```

It rejects a vector with too few or too many elements:

```sjon
(circle :center [160] :radius 32)
```

Likely diagnostic: `vector_length_mismatch`. Repair by writing exactly
two elements:

```sjon
(circle :center [160 120] :radius 32)
```

It also rejects a vector whose element has the wrong kind:

```sjon
(circle :center [160 "top"] :radius 32)
```

The second element is a string, but `point` needs numbers. Repair the
element:

```sjon
(circle :center [160 120] :radius 32)
```

Nested vectors use the same idea. If a plugin documents
`points: vector, element point`, then the outer value is a vector and
each element must satisfy `point`:

```sjon
(shape :points [[0 0] [1 0] [1 1]])
```

This is not the same shape:

```sjon
(shape :points [0 0 1 0 1 1])
```

That is one flat vector of numbers, not a vector of points.

### Variable-Length Vectors

A vector kind does not have to fix an exact length. Instead of a single
`length`, a plugin can set a minimum, a maximum, or both; the value is
then any vector whose element count lands in that window. The examples
here come from a GPU-oriented plugin, where a vertex attribute is two to
four float components.

```text
attribute: vector, length 2-4, element number
```

`attribute` accepts a vec2, vec3, or vec4:

```sjon
(vertex :position [0.0 1.0])
(vertex :position [0.0 1.0 0.5])
(vertex :position [0.0 1.0 0.5 1.0])
```

Too few elements:

```sjon
(vertex :position [0.0])
```

Likely diagnostic: `vector_too_short`. Too many:

```sjon
(vertex :position [0.0 1.0 0.5 1.0 2.0])
```

Likely diagnostic: `vector_too_long`. Repair by writing a vector whose
length lands in the documented range:

```sjon
(vertex :position [0.0 1.0 0.5])
```

This is a different contract from a fixed `length`. A fixed-length kind
like `point` accepts exactly two elements and fires
`vector_length_mismatch` for anything else; a variable-length kind
accepts a range and fires `vector_too_short` or `vector_too_long` at the
edges. Read the contract to know which rule applies.

## Unit Shapes

A unit refinement applies to a number-underlying kind. The plugin may
allow unitless numbers, require a unit, or allow only specific suffixes.

Example contract:

```text
duration: number, unit required, allowed s | ms | b
```

Accepted values:

```sjon
0.5s
250ms
4b
```

Rejected because the unit is missing:

```sjon
(delay :wait 4)
```

Likely diagnostic: `unit_required`. Repair with an allowed suffix:

```sjon
(delay :wait 4b)
```

Rejected because the suffix is not allowed:

```sjon
(delay :wait 90deg)
```

Likely diagnostic: `unit_not_allowed`. Repair by using one of the
suffixes in the kind contract:

```sjon
(delay :wait 250ms)
```

Remember: SJON preserves unit suffixes but does not interpret them.
The plugin decides whether `b`, `ms`, or `s` means anything useful.

### Rejecting Units

The opposite of requiring a unit is rejecting every unit. A kind that
sets `unit rejected` accepts a bare number and nothing else.

```text
raw-uniform: number, unit rejected
```

Accepted:

```sjon
(draw :lod-bias 0.5)
```

Rejected, because the value carries a suffix:

```sjon
(draw :lod-bias 0.5f)
```

Likely diagnostic: `unit_forbidden`. Repair by dropping the suffix:

```sjon
(draw :lod-bias 0.5)
```

This rule earns its place. The lexer reads the trailing `f` in `0.5f`
as a unit suffix, so without a reject rule a value you meant as a plain
float lands as a number-with-unit, and a consumer that ignores units
could read it as `0`. A reject kind turns that into a diagnostic at the
value site instead of a wrong number downstream.

## Numeric Bounds

A numeric bound refinement applies to a number-underlying kind and
constrains the value's magnitude or integrality, orthogonal to any
unit shape. The plugin may pin a minimum, maximum, either-exclusive,
or require integer values.

Example contracts:

```text
opacity:          number, range [0, 1]
iteration-count:  number, min 1, integer
duration-ms:      number, unit required ms, range [0ms, 10000ms]
```

Accepted values for `opacity`:

```sjon
0
0.5
1
```

Rejected because below `:min`:

```sjon
(layer :opacity -0.1)
```

Likely diagnostic: `number_below_min`. Other diagnostics in this
family:

- `number_above_max`            — value greater than `:max`.
- `number_at_or_below_exclusive_min` — `:exclusive-min true` and value ≤ `:min`.
- `number_at_or_above_exclusive_max` — `:exclusive-max true` and value ≥ `:max`.
- `number_not_integer`          — `:integer true` and value is fractional or non-finite.
- `numeric_bound_unit_mismatch` — bound carries a unit but the value either has none or carries a different unit.

Comparison preserves exact precision when both the bound and the
value came from integer literals (`9007199254740993` vs a `:max`
of `9007199254740992` correctly fires `number_above_max`, even
though both round to the same f64). For everyday plugins this
just works; the corner only matters when the bound itself
approaches 2^53.

## Representation

A representation tag pins the machine type a downstream tool will encode
a number as - `u16`, `u32`, `i32`, `f32`, or `f16`. The value you write
is still an ordinary SJON number; the tag tells the validator to check
that the number actually fits that type.

```text
channel:       number, repr u16
scalar:        number, repr f32
vertex-index:  number, repr u32
```

Two things are checked, both at validate time:

- **Range** - the number must fall inside the type's span. `u16` is
  `[0, 65535]`, `u32` is `[0, 2^32)`, and `i32` is the signed 32-bit
  range.
- **Integrality** - an integer type (`u16`, `u32`, `i32`) rejects a
  fractional value. A float type (`f32`, `f16`) carries no integrality
  rule; any finite number in range is accepted.

Accepted:

```sjon
(vertex :tint 65535)
(draw :line-width 1.5)
(draw :base-vertex 32768)
```

`65535` fits `u16`, `1.5` is a fine `f32`, and `32768` fits `u32`.

Out of range:

```sjon
(vertex :tint 70000)
```

Likely diagnostic: `repr_out_of_range` - `70000` is above the `u16`
ceiling of `65535`. The same code covers a non-integral value under an
integer type:

```sjon
(draw :base-vertex 1.5)
```

Here the message names the integrality failure rather than the range.
Repair by writing a number that fits - in range and, for an integer
type, whole:

```sjon
(vertex :tint 65535)
```

One thing a repr tag does not do: it does not ask you to round for
precision. An `f32` value that needs more than 32 bits of mantissa is
still accepted - the precision narrowing is the downstream encoder's
step, not a validation error. The tag guards range and integrality,
nothing more.

## Exercises

For each exercise, read the contract first, then repair the source.

### Vector Shape

Contract:

```text
point: vector, length 2, element number
(circle ...)
  :center point optional
```

```sjon
(circle :center [160] :radius 32)
```

Repair:

```sjon
(circle :center [160 120] :radius 32)
```

### Vector Element Kind

```sjon
(circle :center [160 "top"] :radius 32)
```

Repair:

```sjon
(circle :center [160 120] :radius 32)
```

### Unit Shape

Contract:

```text
duration: number, unit required, allowed s | ms | b
(delay ...)
  :wait duration required
```

```sjon
(delay :wait 4)
```

Repair:

```sjon
(delay :wait 4b)
```

### Variable-Length Vector

Contract:

```text
attribute: vector, length 2-4, element number
(vertex ...)
  :position attribute required
```

```sjon
(vertex :position [0.0])
```

Repair:

```sjon
(vertex :position [0.0 1.0])
```

### Unit Rejection

Contract:

```text
raw-uniform: number, unit rejected
(draw ...)
  :lod-bias raw-uniform optional
```

```sjon
(draw :lod-bias 0.5f)
```

Repair:

```sjon
(draw :lod-bias 0.5)
```

### Representation

Contract:

```text
channel: number, repr u16
(vertex ...)
  :tint channel optional
```

```sjon
(vertex :tint 70000)
```

Repair:

```sjon
(vertex :tint 65535)
```

<section class="mastery-quiz" data-lesson="value-kinds-shapes">
  <h2>Mastery Check</h2>
  <ol class="mc-list">
    <li class="mc-item" data-correct="1">
      <p class="mc-q">Is a plugin-declared value kind a new SJON syntax feature?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-0" value="0" /> <span>Yes — each named kind adds new surface syntax.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-0" value="1" /> <span>No — value kinds are contracts on existing shapes (number, string, symbol, vector, form, union).</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-0" value="2" /> <span>Only when prefixed with the kind name.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="2">
      <p class="mc-q">When reading a named kind, what should you check first?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-1" value="0" /> <span>The error code list.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-1" value="1" /> <span>The default value.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-1" value="2" /> <span>The underlying shape — is the value a number, string, symbol, vector, form, or union?</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">Which diagnostic points to a missing required unit suffix?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-2" value="0" /> <span><code>unit_required</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-2" value="1" /> <span><code>wrong_underlying</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-2" value="2" /> <span><code>not_member</code>.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">Which diagnostic points to a vector with the wrong number of elements?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-3" value="0" /> <span><code>number_above_max</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-3" value="1" /> <span><code>vector_length_mismatch</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-3" value="2" /> <span><code>string_too_short</code>.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">A slot is typed <code>attribute: vector, length 2-4, element number</code>. Which value is rejected?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-4" value="0" /> <span><code>[0.0 1.0 0.5]</code> (three elements).</span></label>
        <p class="mc-explanation" hidden>Three elements sits inside the 2-4 window, so this is accepted.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-4" value="1" /> <span><code>[0.0]</code> (one element).</span></label>
        <p class="mc-explanation" hidden>Correct. One element is below the minimum of 2, so it fires <code>vector_too_short</code>.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-4" value="2" /> <span><code>[0.0 1.0 0.5 1.0]</code> (four elements).</span></label>
        <p class="mc-explanation" hidden>Four elements is the top of the 2-4 window, so this is accepted.</p>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">A number kind sets <code>unit rejected</code>. What does it accept?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-5" value="0" /> <span>Only a bare number with no unit suffix.</span></label>
        <p class="mc-explanation" hidden>Correct. A reject kind takes a bare number; any suffix fires <code>unit_forbidden</code>.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-5" value="1" /> <span>Any number, with or without a unit.</span></label>
        <p class="mc-explanation" hidden>No - rejecting units is the opposite of allowing them, so a suffix is an error.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-5" value="2" /> <span>Only a number with the <code>f</code> suffix.</span></label>
        <p class="mc-explanation" hidden>No - <code>f</code> is itself a unit suffix, and a reject kind forbids every suffix.</p>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">A value typed <code>repr u16</code> is rejected. What should you check about the number?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-6" value="0" /> <span>Whether it is a quoted string.</span></label>
        <p class="mc-explanation" hidden>String-vs-number is a different failure (<code>wrong_underlying</code>); a repr tag is about the number itself.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-6" value="1" /> <span>Whether it is in range <code>[0, 65535]</code> and a whole number.</span></label>
        <p class="mc-explanation" hidden>Correct. A <code>u16</code> repr checks range (<code>[0, 65535]</code>) and, being an integer type, integrality - <code>repr_out_of_range</code> covers both.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-shapes-6" value="2" /> <span>Whether it carries a unit suffix.</span></label>
        <p class="mc-explanation" hidden>Units are a separate axis (<code>unit_*</code>); a repr failure is <code>repr_out_of_range</code>.</p>
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
