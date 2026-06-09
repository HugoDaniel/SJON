# 04 - Numbers, Units, and Vectors

## Goal

Write numeric values, unit-bearing numbers, and vectors in shapes that
schema authors commonly require.

## Mental Model

A number can carry an opaque unit suffix:

```sjon
4b
90deg
50%
250ms
1.5e2hz
```

SJON preserves the suffix but does not interpret it. The host or plugin
decides what `b`, `deg`, `ms`, or `%` means.

The `e` or `E` starts an exponent only when the next character is a
digit or sign:

```sjon
1e9       ; exponent
1e+9      ; exponent
1em       ; number 1 with unit em
1e-9ms    ; exponent plus unit ms
```

Vectors are ordered lists:

```sjon
[160 120]
[0.9 0.4 0.2 1.0]
[[0 0] [1 0] [1 1]]
```

A plugin may refine a vector slot to require a length and element kind,
such as "2-vector of numbers". When a plugin only says "vector", the
validator checks that the value is a vector; when it says "2-vector of
numbers", it also checks the shape.

## Worked Example

```sjon
(shape :path :closed true
  :points [[0 0] [1 0] [1 1] [0 1]])
```

Read the values:

- `true` is a boolean.
- `[[0 0] [1 0] [1 1] [0 1]]` is a vector of vectors.
- Each inner vector looks like a point.

From the shapes tutorial scene:

```sjon
(circle :center [160 120] :radius (* 2 16))
```

`:center` is written in the conventional point shape, `[x y]`.
`:radius` is an expression in a numeric slot.

## Exercises

Classify the unit behavior:

1. `1e9`
2. `1em`
3. `1e-9ms`
4. `60_000ms`
5. `50%`

Repair the values:

```sjon
(circle :center [160] :radius 32)
```

If the plugin docs say `:center` is a 2-number point, write two
numbers:

```sjon
(circle :center [160 120] :radius 32)
```

```sjon
(shape :sdf :color [0.9 0.4 0.2])
```

If `:color` expects RGBA, write four numbers:

```sjon
(shape :sdf :color [0.9 0.4 0.2 1.0])
```

```sjon
(delay :wait 0.5)
```

If `:wait` expects a unit-bearing duration, supply the unit the plugin
allows:

```sjon
(delay :wait 0.5s)
```

```sjon
(shape :path :points [0 0 1 0 1 1])
```

If `:points` expects a vector of points, group each point:

```sjon
(shape :path :points [[0 0] [1 0] [1 1]])
```

A schema can also constrain a number's **value**, not just its
tag. A value-kind with a `:numeric` refinement pins ranges
(`:min`, `:max`, `:exclusive-min`, `:exclusive-max`) and
integrality (`:integer true`). The reference is in
`docs/LANGUAGE.md` §6.5 (NumericBounds) and §4.3 of
`docs/portable-manifest-v1.md`. As an author you don't write
the bound; you just see `number_below_min` / `number_above_max`
diagnostics if your value falls outside the declared range.

## Mastery Check

- Does SJON itself know that `ms` means milliseconds?
- What is the difference between `1e9` and `1em`?
- Is `[0 0 1 1]` the same shape as `[[0 0] [1 1]]`?
- Can vector elements be forms?

Next: [Forms and Keyword Pairing](05-forms-and-keyword-pairing.md).
