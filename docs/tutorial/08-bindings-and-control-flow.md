# 08 - Bindings and Control Flow

## Goal

Use `let`, `if`, and `cond` to keep an expression readable, and know
where a name like `t` comes from when the document never declares it.

## Two Kinds of Name

[Safe expressions](07-safe-expressions.md) gave you a closed vocabulary of
functions and said nothing about where a *value* could come from other
than a literal. Here is the missing half. An expression can see names,
and those names arrive from exactly two places.

Some come from the **host**, which supplies an environment when it asks
for a value to be evaluated. A normalized animation time called `t` is
the canonical case, and it is why this validates and evaluates even
though nothing in the document defines `t`:

```sjon
(group :name "fade"
  (shape :sdf
    :radius 0.5
    :alpha (lerp 1 0 (clamp t 0 1))))
```

The rest you create yourself with `let`, and this is the one place a
SJON document introduces a name at all.

## `let` Binds in Order

```sjon
(let [a 1
      b (+ a 2)
      c (* a b)]
  (+ a b c))
```

The bindings are a flat vector of name/expression pairs, read left to
right, and each one can see everything bound before it:

```
(let [ a 1                  a is now 1
       b (+ a 2)            can see a       -> b is 3
       c (* a b) ]          can see a and b -> c is 3
  (+ a b c))                the body sees a, b, and c -> 7
```

Read that diagram backwards and you have the rule that catches people:
`a` cannot see `b`. There is no mutual recursion, no forward reference,
and no way to define something in terms of a name that comes later. That
falls out of "no recursion" from [Safe expressions](07-safe-expressions.md),
and it is a feature: a `let` you can read top to bottom is a `let` you
can evaluate in your head.

## `if` and `cond`

`if` picks one branch and evaluates only that one:

```sjon
(if (> t 0.5) 1 0)
```

`cond` takes test/value pairs, walks them left to right, and stops at
the first test that is truthy, returning the value paired with it.
Everything after that pair goes unevaluated:

```sjon
(cond
  (< x 0) -1
  (> x 0)  1
  true     0)
```

```
x = -3      (< x 0) truthy   -> -1     ; (> x 0) never runs
x =  4      (< x 0) falsy
            (> x 0) truthy   ->  1     ; the true branch never runs
x =  0      (< x 0) falsy
            (> x 0) falsy
            true    truthy   ->  0
```

That last row is why the literal `true` is the idiom for a default
branch. Take it away and the third case falls off the end, and `cond`
returns `nil` when no test is truthy. `nil` is a real value that will
travel happily into whatever slot you put it in, so leaving the default
off is a decision, not an oversight to be caught later.

## Worked Example

Our fade again, with the clamp appearing once instead of being inlined:

```sjon
(group :name "fade"
  (shape :sdf
    :radius 0.5
    :alpha (let [phase (clamp t 0 1)]
             (lerp 1 0 phase))))
```

Both versions compute the same number. The second one names the
intermediate, which is worth doing the moment the expression stops
fitting on one line.

There is a limit, and I want to name it rather than let you discover it
at 200 lines of `let`. SJON expressions are for a little arithmetic that
belongs in the document: a fade, a margin derived from a width, a colour
derived from an index. When the logic stops feeling like "a little safe
math", the right move is to lift it into your host language and pass the
result in as data. A document that has grown a program inside it has
lost the property that made it worth reading.

## Exercises

Write an alpha fade that goes from transparent to opaque:

```sjon
(shape :sdf
  :alpha (lerp 0 1 (clamp t 0 1)))
```

Now invert it, changing exactly one thing:

```sjon
(shape :sdf
  :alpha (lerp 1 0 (clamp t 0 1)))
```

Use `let` so the clamp is written once and the pulse is named:

```sjon
(shape :sdf
  :radius (let [phase (clamp t 0 1)
                pulse (lerp 0.8 1.2 phase)]
            (* 20 pulse)))
```

Repair the binding vector:

```sjon
(let [a 1 b] (+ a b))
```

The vector holds name/expression pairs, and this one has three elements,
so `b` has no value. Give it one:

```sjon
(let [a 1
      b (+ a 2)]
  (+ a b))
```

Repair the missing default:

```sjon del={3}
(cond
  (< x 0) -1
  (> x 0)  1)
```

This is valid and returns `nil` when `x` is zero. If a zero case was
intended, say so:

```sjon ins={3-4}
(cond
  (< x 0) -1
  (> x 0)  1
  true     0)
```

## Mastery Check

- Can a later `let` binding refer to an earlier one?
- Can an earlier `let` binding refer to a later one?
- What supplies `t` in an expression like `(clamp t 0 1)`?
- When should expression logic move out of SJON?

Next: [Reading Plugin Schemas](09-reading-plugin-schemas.md).
