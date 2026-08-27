---
expects: arity_mismatch
---
# Task: compute a radius with a `lerp` expression

Schema: `(shape :radius <number>)`. The slot accepts an expression
that evaluates to a number, so `(lerp a b t)` is legal here, but
`lerp` takes exactly three arguments.

`attempt-1.sjon` writes `(lerp 0 10)`, two arguments. The diagnostic
is `code = arity_mismatch`, and the message states the exact count:
*expression `lerp` expects exactly 3 argument(s), got 2*. Supply the
missing interpolant. `attempt-2.sjon` writes `(lerp 0 10 0.5)`.
