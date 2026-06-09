# 08 - Bindings and Control Flow

## Goal

Use `let`, `if`, and `cond` to keep expressions readable, and understand
how host-supplied bindings such as `t` fit into authored SJON.

## Mental Model

Bindings are names available to an expression. Some bindings can be
created locally with `let`; others are supplied by the host when it
evaluates the expression.

`let` binds names sequentially:

```sjon
(let [a 1
      b (+ a 2)
      c (* a b)]
  (+ a b c))
```

Each binding can see earlier bindings in the same vector. The body can
see them all.

`if` evaluates one branch:

```sjon
(if (> t 0.5) 1 0)
```

`cond` checks test/value pairs from left to right and stops at the
first test that is truthy, returning its paired value. Tests and
values after the chosen pair are not evaluated:

```sjon
(cond
  (< x 0) -1
  (> x 0)  1
  true     0)
```

Use a literal `true` as the default branch. If no test is truthy and
there is no default, `cond` returns `nil`.

## Worked Example

```sjon
(group :name "fade"
  (shape :sdf
    :radius 0.5
    :alpha (lerp 1 0 (clamp t 0 1))))
```

Here `t` is not declared inside the document. It is a binding the host
supplies when evaluating `:alpha`, for example a normalized animation
time.

Make the expression easier to scan with `let`:

```sjon
(group :name "fade"
  (shape :sdf
    :radius 0.5
    :alpha (let [phase (clamp t 0 1)]
             (lerp 1 0 phase))))
```

The expression is still small and local. If the logic stops feeling
like "a little safe math", lift it into the host domain and pass the
result as data.

## Exercises

Write an alpha fade:

```sjon
(shape :sdf
  :alpha (lerp 0 1 (clamp t 0 1)))
```

Now invert it:

```sjon
(shape :sdf
  :alpha (lerp 1 0 (clamp t 0 1)))
```

Use `let` to avoid repeating work:

```sjon
(shape :sdf
  :radius (let [phase (clamp t 0 1)
                pulse (lerp 0.8 1.2 phase)]
            (* 20 pulse)))
```

Repair the `let` shape:

```sjon
(let [a 1 b] (+ a b))
```

The binding vector must contain name/expression pairs. Give `b` a
value:

```sjon
(let [a 1
      b (+ a 2)]
  (+ a b))
```

Repair the missing default:

```sjon
(cond
  (< x 0) -1
  (> x 0)  1)
```

This is valid, but returns `nil` when neither test matches. If a zero
case is intended, add a default:

```sjon
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

