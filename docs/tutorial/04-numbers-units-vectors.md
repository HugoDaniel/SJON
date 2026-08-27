# 04 - Numbers, Units, and Vectors

## Goal

Write numbers, unit-bearing numbers, and vectors in the shapes schema
authors ask for, and predict how the lexer splits every one of them.

## The Number That Remembers Its Unit

Our camera has been carrying a bare `2` since
[Orientation](01-orientation.md). Let me give it a second number, and this
one is more interesting:

```sjon
(camera :ortho :zoom 2 :delay 4b)
```

`4b` is a single number token. Not `4` followed by the symbol `b`, and
not a string that a later pass has to pick apart: one value, whose
magnitude is `4` and whose **unit** is `b`. It survives printing, JSON,
and the binary encoding as a four-beat delay, and any tool that reads
this document sees the beats.

That matters because the alternative is the thing every config format
does instead, which is to bury the unit in the key name (`:delay-beats
4`) or in a comment, or nowhere. A unit in the key can't be changed
without renaming the key. A unit in a comment isn't data. SJON hangs the
suffix off the number and carries it.

What SJON does **not** do is understand it. `b`, `deg`, `ms`, `%` and
the rest are opaque tags. The substrate preserves the bytes; a host or
plugin decides that `b` means beats and that `250ms` is a quarter of a
second. Do not expect any unit conversion, ever, from the language
itself.

The spellings all look the way you would guess:

```sjon
4b
90deg
50%
250ms
1.5e2hz
```

## Where the Token Stops

Everything hard about numbers is the question of where the lexer decides
one value has ended. There are three rules, and each exists to stop a
different ambiguity.

**Rule one: `e` starts an exponent only before a digit or a sign.**

```sjon
1e9       ; exponent: the number 1000000000
1e+9      ; exponent, explicit sign
1em       ; the number 1 with unit `em`
1e-9ms    ; exponent, then unit `ms`
```

Without that rule, CSS-flavoured units beginning with `e` would be
unwritable.

**Rule two: inside a unit, a hyphen continues the suffix only when an
ASCII letter follows it.**

```sjon
2d-array        ; one value: number 2, unit `d-array`
5ms-per-frame   ; one value: number 5, unit `ms-per-frame`
1em-2           ; TWO values: `1em`, then `-2`
```

The third line is the one to memorise. A digit after the hyphen means
the unit is over and a new value has begun, so `1em-2` is a number with
unit `em` followed by negative two. That is the same rule from both
sides: it lets compound units exist without swallowing subtraction.

**Rule three: `0x` is a hex prefix only right after a lone `0`.**

```sjon
1_000_000     ; the number 1000000; underscores are stripped
0xFF          ; the number 255
0Xff          ; the same number; case is free
0xFFFF_FFFF   ; 4294967295, grouped
-0x10         ; -16
10x           ; the number 10 with unit `x`
```

Hex is an *integer* spelling and nothing more: no fraction, no exponent,
no unit. The token stops at the first byte that isn't a hex digit, so
`0xFFms` is the number `0xFF` followed by the separate symbol `ms`. And
because the prefix is gated on that lone leading `0`, every document
written before hex existed reads exactly as it did.

Here is a thing I have implied and should say outright: **the value
survives, the spelling does not.** Run `0xFF` through `sjon fmt` and it
comes back as `255`. Run `1_000` through and it comes back as `1000`.
The formatter prints from the parsed tree and never looks at your source
text, so no numeric spelling survives it. The unit does survive, because
the unit is part of the value rather than part of the spelling. If that
distinction feels arbitrary, the test is whether a reader who only has
the value can reconstruct the thing: `255` tells you everything `0xFF`
did, but `4` does not tell you `4b`.

## Vectors

A vector is an ordered list, written with square brackets, holding any
values at all:

```sjon
[1920 1080]
[0.9 0.4 0.2 1.0]
[[0 0] [1 0] [1 1]]
```

Nesting is not flattening, and confusing the two is the most common
vector mistake:

```
[0 0 1 0]           one vector, four numbers
  |
  +-- 0, 0, 1, 0

[[0 0] [1 0]]       one vector, two vectors, each of two numbers
  |
  |-- [0 0]  -> 0, 0
  `-- [1 0]  -> 1, 0
```

A slot that wants a list of points wants the second shape. A slot that
wants an RGBA colour wants the first shape with four elements. Nothing
in the brackets tells you which; the plugin's schema does, and
[Value kinds: shapes](11-value-kinds-shapes.md) is where we learn to read that
part of a schema. A schema that says only "vector" checks that the value
is a vector and stops. A schema that says "2-vector of numbers" also
checks the length and the element kind.

Vector elements are values, so they can be forms, which is how
expressions end up inside them. Hold that thought until
[Safe expressions](07-safe-expressions.md).

## Worked Example

```sjon
(shape :path :closed true
  :points [[0 0] [1 0] [1 1] [0 1]])
```

- `true` is a boolean.
- `[[0 0] [1 0] [1 1] [0 1]]` is a vector of four vectors.
- Each inner vector is two numbers, which reads as a point.

And from the shapes tutorial scene:

```sjon
(circle :center [160 120] :radius (* 2 16))
```

`:center` is written in the conventional point shape `[x y]`. `:radius`
holds a form in a numeric slot, which is the expression case from
[Orientation](01-orientation.md) finally showing up in real code.

## Exercises

Classify the unit behaviour. For each, say whether there is an exponent,
a unit, both, or neither:

1. `1e9`
2. `1em`
3. `1e-9ms`
4. `60_000ms`
5. `50%`

Predict the lexing. How many values is each of these?

1. `2d-array`
2. `1em-2`
3. `90deg5px`
4. `5-3`

The second is the one to remember: **two**. A hyphen continues a unit
only before a letter, so `1em-2` is `1em` then `-2`. The first is one
value (a letter follows the hyphen), the third is two (a digit ends a
unit), and the fourth is two, with no unit involved at all, because that
is how subtraction is spelled.

Predict the value. Every one of these is a number, so say which:

1. `0xFF`
2. `0x10`
3. `10x`
4. `0xFFms`

The third is worth the pause. `x` only begins a hex prefix immediately
after a lone `0`; everywhere else it is an ordinary unit letter, so
`10x` is ten with unit `x`.

Repair each of these:

```sjon del={1}
(mask :bits 0x)
```

A `0x` with no hex digit after it is a parse error, not zero. Finish the
literal:

```sjon ins={1}
(mask :bits 0xFF)
```

```sjon del={1}
(mask :bits 0xGG)
```

`G` is not a hex digit; they are `0`-`9` and `a`-`f` in either case:

```sjon ins={1}
(mask :bits 0xFF)
```

```sjon del={1}
(circle :center [160] :radius 32)
```

If the plugin documents `:center` as a 2-number point, give it two
numbers:

```sjon ins={1}
(circle :center [160 120] :radius 32)
```

```sjon del={1}
(shape :sdf :color [0.9 0.4 0.2])
```

If `:color` is RGBA, the alpha is missing:

```sjon ins={1}
(shape :sdf :color [0.9 0.4 0.2 1.0])
```

```sjon del={1}
(delay :wait 0.5)
```

If `:wait` expects a unit-bearing duration, a bare number is ambiguous
in exactly the way units exist to prevent. Supply the unit the plugin
allows:

```sjon ins={1}
(delay :wait 0.5s)
```

```sjon del={1}
(shape :path :points [0 0 1 0 1 1])
```

Six numbers in one vector are not three points. Group them:

```sjon ins={1}
(shape :path :points [[0 0] [1 0] [1 1]])
```

## A Note on Bounds

A schema can constrain a number's **value**, not only its kind. A
value-kind with a `:numeric` refinement pins ranges with `:min`, `:max`,
`:exclusive-min`, and `:exclusive-max`, and pins integrality with
`:integer true`. As an author you never write the bound; you meet it, in
the form of a `number_below_min` or `number_above_max` diagnostic when
your value falls outside the declared range. The reference is
[`../LANGUAGE.md`](../LANGUAGE.md) §6.5 (NumericBounds) and §4.3 of
[`../portable-manifest-v1.md`](../portable-manifest-v1.md), and
[Value kinds: shapes](11-value-kinds-shapes.md) reads one in anger.

## Mastery Check

- Does SJON itself know that `ms` means milliseconds?
- What is the difference between `1e9` and `1em`?
- Is `[0 0 1 1]` the same shape as `[[0 0] [1 1]]`?
- Can vector elements be forms?
- Why is `10x` not a hex literal?
- What does `sjon fmt` print for `0xFF`, and why?
- `2d-array` is one value and `1em-2` is two. What single rule decides
  both?

Next: [Forms and Keyword Pairing](05-forms-and-keyword-pairing.md).
