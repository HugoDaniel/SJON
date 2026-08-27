# 07 - Safe Expressions

## Goal

Use SJON's built-in expression vocabulary in value positions, read the
typed expression diagnostics, and predict evaluation without ever
mistaking SJON for a programming language.

## Paying the Debt from Orientation

In [Orientation](01-orientation.md) I put this in front of you and refused
to explain it:

```sjon
(camera :zoom (* 2 4))
```

I said `(* 2 4)` is a form and nothing more, and that it becomes an
expression only when the active schema says so. Here is the full
version.

An **expression** is a form whose head has been declared an expression
function by the schema that is active when the document is validated.
Nothing about the source text makes a form an expression. `(* 2 4)`
sitting in a document validated against a schema with no `*` in it is a
form whose head is the symbol `*`, and it will be reported as an unknown
head, not evaluated.

That indirection is doing real work. It means the set of things a
document can compute is a closed list chosen by the host, in advance, in
code. There is no way for a document to add to it: no import, no
definition form, no eval. Add to that the properties the evaluator
guarantees and you get the whole safety story:

```
no I/O          a document cannot read a file, open a socket, or read the clock
no mutation     evaluating a value cannot change another value
no recursion    a call cannot re-enter itself, so it cannot fail to terminate
no side effects the same inputs give the same output, every time
```

Which is why I could promise in [Orientation](01-orientation.md) that
reading a SJON file costs what reading data costs. It is not that the
arithmetic is cheap. It is that the arithmetic cannot reach anything.

## Where an Expression May Sit

Anywhere a value may sit, which by now you know is three places:

```sjon
(camera :zoom (* 2 4))                 ; the value half of a kvpair
(canvas :size [(* 2 960) 1080])        ; an element of a vector
(group (lerp 0 1 t))                   ; a positional child
```

The vector case is the one people forget.
[Numbers, units, vectors](04-numbers-units-vectors.md) said vector elements are values
and that forms are values, and this is what that adds up to: an
expression inside a vector sits next to literals and is not special.

## Calling Conventions

Arguments are positional by default:

```sjon
(lerp 0 10 0.5)
```

Functions that declare parameter names also accept a Swift-style
**labelled call form**, where the labels match the declared names and
may appear in any order:

```sjon
(lerp 0 10 0.5)              ; positional
(lerp :from 0 :to 10 :t 0.5) ; labelled, same call
(lerp :t 0.5 :from 0 :to 10) ; labelled and reordered, same call
```

A labelled call is all or nothing. Half-and-half is a hard error:

```sjon
(lerp 0 :to 10 0.5) ; rejected: expr_mixed_args
```

I chose that rather than trying to fill the gaps, because the moment you
allow mixing you have to define what `(lerp 0 :t 0.5)` means, and every
answer to that is a rule somebody has to remember.

Functions that declare no labels keep rejecting kvpairs outright, since
there are no named slots for the labels to refer to:

```sjon
(+ :a 1 :b 2) ; rejected: expr_kvpair_not_allowed
```

For labelled functions the validator separates the three ways a call can
go wrong, and each has its own diagnostic code: an unknown label, a
duplicate label, and a missing label.

## What the Validator Can Check Before Evaluating

Some expression functions declare typed signatures, so obvious literal
mistakes are caught before anything runs:

```sjon
(vec3 1 "x" 3)  ; the string should be a number
(< true "x")    ; ordering comparisons take numbers
```

But the validator only sees the document, so it has to know when to keep
quiet. A symbol could come from a `let` binding or from the host, so a
symbol argument always defers to runtime. A nested form is classified
right there at validate time: if the inner expression declares a
`:result`, that result is compared against what the outer slot expects.

```sjon
(let [r 0.5]
  (vec3 r r r))         ; `r` is opaque, so this validates clean.

(+ (vec3 1 2 3) 1)      ; `vec3` declares `:result vector`; `+` wants a
                        ; number, so this is expr_type_mismatch at arg 0.

(+ 1 (let [r 1] r))     ; `let` declares no result, so this defers.
```

Read the middle line again, because it is the interesting one: the
validator caught a type error in an expression it never evaluated,
purely from the declared result of `vec3`. And read the third: `let` is
opaque, and the validator says nothing rather than guessing.

Typed signatures do not make SJON statically typed. They are an aid for
heads that advertise their shapes. Opaque and polymorphic heads still
check arity first and leave the rest to evaluation.

## One Thing Forms and Keyword Pairing Bought You

Keywords inside an expression are worth a paragraph, because the rule
from [Forms and keyword pairing](05-forms-and-keyword-pairing.md) turns out to do
something useful here:

```sjon
(= mode :ortho)
```

`:ortho` cannot pair with anything, because the frame closes
immediately after it. The greedy rule promotes it to a positional, and
inside an expression a bare keyword evaluates to a keyword value, so `=`
compares two keywords and the comparison reads exactly as written. There
is no way to write a `:k v` argument inside an expression form, which is
why `expr_kvpair_not_allowed` exists at all.

## Worked Example

From
[`../../examples/with-expressions.sjon`](../../examples/with-expressions.sjon):

```sjon title="examples/with-expressions.sjon"
(+ 1 2 3)              ; 6
(* 2 3 4)              ; 24
(lerp 0 10 0.25)       ; 2.5
(clamp 1.5 0 1)        ; 1
(dot (vec3 1 2 3) (vec3 4 5 6)) ; 32
```

The core vocabulary, which is the whole list:

- Arithmetic: `+`, `-`, `*`, `/`, `mod`.
- Comparison: `<`, `<=`, `>`, `>=`, `=`, `!=`.
- Logical: `and`, `or`, `not`.
- Vectors: `vec2`, `vec3`, `vec4`.
- Math: `lerp`, `clamp`, `min`, `max`, `dot`, `cross`, `length`, `abs`,
  `sign`, `floor`, `ceil`, `round`, `fract`, `sqrt`, `pow`, `sin`,
  `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `radians`, `degrees`.
- Constants (0-arity): `pi`, `tau`. Call them as `(pi)` and `(tau)`.
- Smoothing (WGSL semantics): `saturate`, `step`, `smoothstep`.
- Vector ops: `normalize`, `distance`, `reflect`.
- List ops: `nth`, `count`.
- Seeded random: `hash`, `rand01`, `rand-range`, `rand-int`,
  `rand-bool`, `rand-choice`.
- Control: `let`, `if`, `cond`.

Truthiness is short enough to memorise: `false` and `nil` are falsy, and
everything else is truthy. That includes `0`, `""`, and `[]`, which is
where people coming from JavaScript get caught.

### Domain Errors Come Back as NaN

`(sqrt -1)`, `(asin 2)`, and `(pow -1 0.5)` return IEEE 754 `NaN`
instead of raising. I picked that deliberately: every host then produces
the same bits for the same bad input, and a NaN travels through nested
expressions without every function needing a special case for failure.
The cost is that a domain error is quiet, so when you want the check,
write it:

```sjon
(if (>= x 0) (sqrt x) 0)
```

### Randomness You Can Reproduce

The seeded random functions are pure, deterministic functions of their
`seed` and `key` arguments. They use a fixed SplitMix64-based mixer, so
the same `(seed, key)` pair gives the same value across runs, platforms,
and Zig versions:

```sjon
(rand01 1 0)                  ; float in [0, 1)
(rand-range 1 0 -2 5)         ; float in [-2, 5)
(rand-int   1 0 0 9)          ; integer in [0, 9], inclusive
(rand-bool  1 0 0.5)          ; true with probability 0.5
(rand-choice 1 0 [10 20 30])  ; pick an element
```

Use `seed` for a stable per-document base such as a scene id, and `key`
to walk a sequence of independent draws. Integer seeds are what I would
use, though `(rand01 1 0)` and `(rand01 1.0 0.0)` are guaranteed to
produce identical streams.

## Exercises

Evaluate these by hand before you run them. `+` and `*` take any number
of arguments, `-` negates one argument and subtracts more than one, `/`
takes at least two and folds left, and `mod` takes exactly two:

```sjon
(+ 1 2 3)
(- 10 3 2)
(* 2 3 4)
(/ 100 5 2)
(mod 17 5)
```

Predict the truthiness results. Remember that `and` returns the first
falsy value, or the last value if all of them are truthy, and `or`
returns the first truthy value, or `false` if none are:

```sjon
(and true 1 "ok")
(and true nil "never")
(or false nil 0)
(or false nil)
(not false)
```

Repair the arity:

```sjon del={1}
(lerp 0 10)
```

`lerp` takes three arguments:

```sjon ins={1}
(lerp 0 10 0.5)
```

Compare the calling conventions. `clamp` declares `:x :lo :hi`, so all
three of these are the same call:

```sjon
(clamp 1.5 0 1)
(clamp :x 1.5 :lo 0 :hi 1)
(clamp :hi 1 :x 1.5 :lo 0)
```

And `+`, which declares no labels, keeps refusing:

```sjon
(+ :a 1 :b 2) ; rejected
```

Repair the typed argument:

```sjon del={1}
(vec3 1 "two" 3)
```

`vec3` takes three numbers:

```sjon ins={1}
(vec3 1 2 3)
```

## Mastery Check

- Can a safe expression appear as a vector element?
- Why is `(lerp :t 0.5)` invalid? (The problem is the missing labels,
  not the presence of labels: `lerp` declares `:from :to :t`.)
- Why is `(lerp 0 :to 10 0.5)` invalid?
- Why can `(vec3 1 "x" 3)` fail during validation?
- Why does `(vec3 r r r)` usually defer type certainty until runtime?
- What values are falsy?
- What does `(or false nil)` return?

Next: [Bindings and Control Flow](08-bindings-and-control-flow.md).
