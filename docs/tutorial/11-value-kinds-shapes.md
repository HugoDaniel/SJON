# 11 - Value Kinds: Shapes, Vectors, Units, Bounds, Representation

## Goal

Read a plugin-declared value kind and know exactly what to type, and
repair the five failures that follow from getting it wrong: the
underlying shape, the vector length, the unit suffix, the numeric
bound, and the representation range.

## A Type That Is Not Syntax

[Reading plugin schemas](09-reading-plugin-schemas.md) told you a key has a value
type, and then quietly used names like `length`, `point`, `fill-rule`,
and `shape-form` without saying where those come from. They come from
the plugin, and they are the subject of this lesson and the next.

The reason plugins need them is our camera's `:zoom`. Saying "number" is
true and nearly useless: it does not say that a zoom is positive, that a
delay carries a time unit, or that a centre is a pair. A plugin declares
a **value kind** to say the useful part once and then point every slot
that needs it at the same name.

The critical thing, and the thing people get wrong on first contact, is
that a named kind is **not new syntax**. If a slot is typed `point`, you
do not write `point(160 120)`, and you do not write `:point [160 120]`.
You write the value whose shape satisfies the kind:

```sjon
(circle :center [160 120])
```

The name exists in the schema. In the document there are only the same
value kinds you have been writing since
[Atoms and intent](03-atoms-and-intent.md) and
[Numbers, units, vectors](04-numbers-units-vectors.md).

## Reading a Named Kind

Three steps, in this order, and the order matters because a mismatch at
step one makes steps two and three irrelevant:

1. **Underlying shape.** Should the value be a number, string, symbol,
   vector, form, or one of several alternatives?
2. **Refinement.** Does the kind add a vector length, a unit rule, a
   representation tag, a closed member list, an allowed head list, or a
   list of alternatives?
3. **Surface value.** What do you actually type?

You never define a value kind while authoring a document. You read one
and satisfy it.

Cross-references are also built as value-kind refinements, but they need
an authoring model of their own, so they get a whole lesson,
[Cross-references](13-cross-references.md).

## Worked Example

The reference shapes plugin, summarised with its kinds spelled out
underneath:

```text title="plugin summary"
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

Now write the source straight off the contract:

```sjon
(circle :center [160 120] :radius 32 :fill evenodd)

(badge :label "dot"
  :shape (circle :center [0 0] :radius 1))
```

Read the first form one slot at a time, following the two hops from the
slot line to the kind line and back:

```
:center point       -> point is "vector, length 2, element number"  -> [160 120]
:radius length      -> length is "number"                           -> 32
:fill   fill-rule   -> fill-rule is "symbol, members evenodd|nonzero" -> evenodd
:label  string      -> a base kind, no hop needed                   -> "dot"
:shape  shape-form  -> "form, heads circle|rect"                    -> (circle …)
```

That two-hop habit is the whole skill. The slot line tells you which
kind applies; the kind line tells you which value shape is accepted.
Notice that `:fill evenodd` is a symbol and not a keyword, which is
[Atoms and intent](03-atoms-and-intent.md)'s rule arriving with a schema behind
it: a closed member set is exactly the case symbols exist for.

## Underlying Shape First

Get the broad shape right before worrying about any refinement.

```sjon del={1}
(circle :center "160,120" :radius 32)
```

This fails before the validator gets anywhere near counting elements.
`point` is vector-underlying, and a string is the wrong underlying
shape:

```sjon ins={1}
(circle :center [160 120] :radius 32)
```

Same story one slot over:

```sjon del={1}
(circle :center [160 120] :radius "32")
```

`length` is number-underlying, so a string gets `wrong_underlying`:

```sjon ins={1}
(circle :center [160 120] :radius 32)
```

## Vector Shapes

A vector refinement answers two questions: how many elements, and what
kind is each one.

```text title="plugin summary"
point: vector, length 2, element number
```

```sjon
[0 0]
[160 120]
[1.5 -2]
```

Wrong count:

```sjon del={1}
(circle :center [160] :radius 32)
```

`vector_length_mismatch`. Write exactly two:

```sjon ins={1}
(circle :center [160 120] :radius 32)
```

Wrong element kind:

```sjon del={1}
(circle :center [160 "top"] :radius 32)
```

The second element is a string where `point` wants numbers:

```sjon ins={1}
(circle :center [160 120] :radius 32)
```

Nesting works the same way. If a plugin documents
`points: vector, element point`, the outer value is a vector and each
element must itself satisfy `point`:

```sjon
(shape :points [[0 0] [1 0] [1 1]])
```

which is the flatten trap from
[Numbers, units, vectors](04-numbers-units-vectors.md) wearing a
schema:

```sjon
(shape :points [0 0 1 0 1 1])
```

One flat vector of six numbers is not three points, and now something
finally says so.

### Variable-Length Vectors

A vector kind does not have to fix an exact length. Instead of a single
`length` it can set a minimum, a maximum, or both, and then any vector
whose element count lands in the window is accepted. The case that
motivates it is a GPU vertex attribute, which is two to four float
components depending on what it holds:

```text title="plugin summary"
attribute: vector, length 2-4, element number
```

```sjon
(vertex :position [0.0 1.0])
(vertex :position [0.0 1.0 0.5])
(vertex :position [0.0 1.0 0.5 1.0])
```

All three are fine. The edges are not:

```sjon
(vertex :position [0.0])                     ; vector_too_short
(vertex :position [0.0 1.0 0.5 1.0 2.0])     ; vector_too_long
```

```sjon
(vertex :position [0.0 1.0 0.5])
```

The two contracts produce different diagnostics, which is the fastest
way to tell from an error message which one you are dealing with:

```
fixed length      exactly N        wrong count -> vector_length_mismatch
variable length   min..max         under       -> vector_too_short
                                   over        -> vector_too_long
```

## Unit Shapes

A unit refinement applies to a number-underlying kind, and the plugin
picks one of three postures: unitless numbers allowed, a unit required,
or only specific suffixes allowed.

```text title="plugin summary"
duration: number, unit required, allowed s | ms | b
```

```sjon
0.5s
250ms
4b
```

Missing the unit:

```sjon del={1}
(delay :wait 4)
```

`unit_required`. Supply one the contract lists:

```sjon ins={1}
(delay :wait 4b)
```

Wrong suffix:

```sjon del={1}
(delay :wait 90deg)
```

`unit_not_allowed`:

```sjon ins={1}
(delay :wait 250ms)
```

[Numbers, units, vectors](04-numbers-units-vectors.md) said SJON preserves unit
suffixes without interpreting them, and that still holds. What changed
is that a plugin can now insist on one, which is where the check you
actually wanted lives.

### Rejecting Every Unit

The opposite posture is to accept a bare number and nothing else:

```text title="plugin summary"
raw-uniform: number, unit rejected
```

```sjon
(draw :lod-bias 0.5)     ; accepted
(draw :lod-bias 0.5f)    ; unit_forbidden
```

This rule earns its place, and the reason is a real bug it prevents.
Recall from [Numbers, units, vectors](04-numbers-units-vectors.md) that the lexer
reads a trailing letter run as a unit, so `0.5f` is not a float with a
type hint, it is the number `0.5` carrying the unit `f`. Without a
reject rule that value validates fine and lands downstream in a consumer
that ignores units, which might well read it as `0`. A reject kind
converts a silent wrong number into a diagnostic at the site where it
was written:

```sjon
(draw :lod-bias 0.5)
```

## Numeric Bounds

A numeric bound constrains a number's magnitude, integrality, or
divisibility, independently of any unit rule:

```text title="plugin summary"
opacity:          number, range [0, 1]
iteration-count:  number, min 1, integer
duration-ms:      number, unit required ms, range [0ms, 10000ms]
buffer-offset:    number, min 0, integer, multiple of 256
```

```sjon
(layer :opacity 0)
(layer :opacity 0.5)
(layer :opacity 1)
(layer :opacity -0.1)   ; number_below_min
```

The whole family:

- `number_above_max`: greater than `:max`.
- `number_at_or_below_exclusive_min`: `:exclusive-min true` and the
  value is at or under `:min`.
- `number_at_or_above_exclusive_max`: `:exclusive-max true` and the
  value is at or over `:max`.
- `number_not_integer`: `:integer true` and the value is fractional or
  non-finite.
- `number_not_multiple`: `:multiple-of N` and the value does not divide
  evenly by `N`.
- `numeric_bound_unit_mismatch`: the bound carries a unit and the value
  either has none or carries a different one.

Comparison keeps exact precision when both the bound and the value came
from integer literals, so `9007199254740993` against a `:max` of
`9007199254740992` correctly fires `number_above_max` even though both
round to the same f64. For everyday plugins that just works; the corner
only matters when a bound approaches 2^53.

### Divisibility, and the Order the Checks Run In

`:multiple-of` is the one bound that a range and `:integer` together
cannot express. "A byte offset aligned to 256" is not "between 0 and X"
and it is not merely "a whole number", and before this existed a plugin
had to check it in host code after validation had already passed.

```text title="plugin summary"
buffer-offset: number, min 0, integer, multiple of 256
```

```sjon
(binding :offset 0)      ; fine, zero divides by anything
(binding :offset 512)    ; fine
(binding :offset 250)    ; number_not_multiple
```

Divisibility is exact rather than approximate: a value above 2^53 is
compared in whole numbers instead of being rounded to a float first, so
an odd number stays odd. (A *fractional* divisor such as
`multiple of 0.25` is the one approximate case, because binary floating
point has no exact answer for it, and the plugin author is warned when
the schema loads. You will not meet this; alignment rules use whole
numbers.) A divisor of zero or below is refused outright rather than
warned about, since dividing by zero has no answer at all and a negative
divisor accepts exactly what its magnitude accepts.

Now the part worth learning, because it decides which diagnostic you
get. The three checks run in a fixed order and only the first failure is
reported:

```
      integrality  ->  range  ->  divisibility
                only the first failure is reported
```

Predict all three of these against the contract above before reading on:

```sjon
(binding :offset 250.5)
(binding :offset -256)
(binding :offset 250)
```

The first is `number_not_integer`. It fails alignment too, but being
fractional is the more basic problem, and telling you to align a number
that is not whole yet would be useless advice.

The second is `number_below_min`. `-256` genuinely is a multiple of 256,
so the only thing wrong with it is the sign.

The third is `number_not_multiple`, because the value is whole and in
range and divisibility is all that is left.

The practical consequence is one you will feel: fix what the diagnostic
says and re-run, because a second complaint may be queued behind the
first.

## Representation

A representation tag pins the machine type a downstream tool will encode
a number as: `u16`, `u32`, `i32`, `f32`, or `f16`. What you write is
still an ordinary SJON number. The tag tells the validator to check that
the number actually fits.

```text title="plugin summary"
channel:       number, repr u16
scalar:        number, repr f32
vertex-index:  number, repr u32
```

Two checks, both at validate time:

- **Range**, the number must fall inside the type's span. `u16` is
  `[0, 65535]`, `u32` is `[0, 2^32)`, and `i32` is the signed 32-bit
  range.
- **Integrality**, where an integer type (`u16`, `u32`, `i32`) rejects a
  fractional value. A float type (`f32`, `f16`) has no integrality rule,
  so any finite number in range is accepted.

```sjon
(vertex :tint 65535)        ; fits u16
(draw :line-width 1.5)      ; a fine f32
(draw :base-vertex 32768)   ; fits u32
```

Both failures share one code:

```sjon
(vertex :tint 70000)        ; repr_out_of_range, above the u16 ceiling
(draw :base-vertex 1.5)     ; repr_out_of_range, not whole under u32
```

The message names which of the two it was.

```sjon
(vertex :tint 65535)
```

One thing a repr tag does **not** do: it never asks you to round for
precision. An `f32` value needing more than 32 bits of mantissa is
accepted, because narrowing precision is the downstream encoder's step
rather than a validation error. The tag guards range and integrality,
and nothing else.

## Exercises

Read the contract first, then repair the source.

### Vector Shape

```text title="plugin summary"
point: vector, length 2, element number
(circle ...)
  :center point optional
```

```sjon del={1}
(circle :center [160] :radius 32)
```

```sjon ins={1}
(circle :center [160 120] :radius 32)
```

### Vector Element Kind

```sjon del={1}
(circle :center [160 "top"] :radius 32)
```

```sjon ins={1}
(circle :center [160 120] :radius 32)
```

### Unit Shape

```text title="plugin summary"
duration: number, unit required, allowed s | ms | b
(delay ...)
  :wait duration required
```

```sjon del={1}
(delay :wait 4)
```

```sjon ins={1}
(delay :wait 4b)
```

### Variable-Length Vector

```text title="plugin summary"
attribute: vector, length 2-4, element number
(vertex ...)
  :position attribute required
```

```sjon del={1}
(vertex :position [0.0])
```

```sjon ins={1}
(vertex :position [0.0 1.0])
```

### Unit Rejection

```text title="plugin summary"
raw-uniform: number, unit rejected
(draw ...)
  :lod-bias raw-uniform optional
```

```sjon del={1}
(draw :lod-bias 0.5f)
```

```sjon ins={1}
(draw :lod-bias 0.5)
```

### Representation

```text title="plugin summary"
channel: number, repr u16
(vertex ...)
  :tint channel optional
```

```sjon del={1}
(vertex :tint 70000)
```

```sjon ins={1}
(vertex :tint 65535)
```

## Mastery Check

- Is a plugin-declared value kind a new SJON syntax feature?
- When reading a named kind, why should you check the underlying shape
  before the refinement?
- What diagnostic should you expect when a required unit suffix is
  missing?
- What is the difference between a fixed-length vector kind and a
  variable-length one, and which diagnostics does each produce?
- When would a plugin reject every unit suffix on a number, and what
  diagnostic flags a stray suffix?
- A `repr u16` value is rejected. What two things should you check about
  the number you wrote?

Next: [Value Kinds: Strings, Members, Heads, Unions, Slot-Local Forms](12-value-kinds-refinements.md).
