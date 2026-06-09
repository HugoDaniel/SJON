# 07 - Safe Expressions

## Goal

Use SJON's built-in safe expression vocabulary in value positions,
recognize typed expression diagnostics, and predict basic evaluation
behavior without treating SJON as a general programming language.

## Mental Model

An expression is a form whose head is declared as an expression function
by the active schema:

```sjon
(camera :zoom (* 2 4))
```

The expression appears where a value would appear. It is pure and
bounded: no I/O, no mutation, no recursion, and no side effects.

Expression arguments are positional by default. Functions that declare
parameter names also accept a Swift-style **labeled call form** — labels
match the declared names and may appear in any order:

```sjon
(lerp 0 10 0.5)              ; positional
(lerp :from 0 :to 10 :t 0.5) ; labeled — same call
(lerp :t 0.5 :from 0 :to 10) ; labeled, reordered — same call
```

A labeled call is all-or-nothing. Mixing positional and labeled
arguments in the same call is a hard error:

```sjon
(lerp 0 :to 10 0.5) ; rejected — expr_mixed_args
```

If a function does not declare labels (e.g. `+`, `*`, `<`), kvpairs in
the argument list keep being rejected — that vocabulary doesn't have
named slots:

```sjon
(+ :a 1 :b 2) ; rejected — expr_kvpair_not_allowed
```

For labeled functions, the validator catches the usual mistakes:
unknown labels, duplicate labels, and missing labels each have their
own diagnostic code.

Some expression functions also declare typed signatures. The validator
can catch obvious literal mistakes before evaluation:

```sjon
(vec3 1 "x" 3)  ; the string should be a number
(< true "x")    ; ordering comparisons take numbers
```

Symbols defer to runtime because they may come from `let` bindings or
host bindings. Nested forms are classified at validate-time: a nested
expression with a declared `:result` gets that result compared to the
slot's expected type, so `(+ (vec3 1 2 3) 1)` flags the vector-result
argument up front. Forms whose head is an opaque expression (`let`,
`if`, …) — or whose declared result is too coarse to satisfy a refined
named kind — still defer:

```sjon
(let [r 0.5]
  (vec3 r r r))         ; `r` is opaque; validates clean.

(+ (vec3 1 2 3) 1)      ; vec3 declares `:result vector`; `+` wants
                        ; a number → expr_type_mismatch at arg 0.

(+ 1 (let [r 1] r))     ; `let` has no declared result → defers.
```

## Worked Example

From [`../../examples/with-expressions.sjon`](../../examples/with-expressions.sjon):

```sjon
(+ 1 2 3)              ; 6
(* 2 3 4)              ; 24
(lerp 0 10 0.25)       ; 2.5
(clamp 1.5 0 1)        ; 1
(dot (vec3 1 2 3) (vec3 4 5 6)) ; 32
```

The core vocabulary includes:

- Arithmetic: `+`, `-`, `*`, `/`, `mod`.
- Comparison: `<`, `<=`, `>`, `>=`, `=`, `!=`.
- Logical: `and`, `or`, `not`.
- Vectors: `vec2`, `vec3`, `vec4`.
- Math: `lerp`, `clamp`, `min`, `max`, `dot`, `cross`, `length`,
  `abs`, `sign`, `floor`, `ceil`, `round`, `fract`, `sqrt`, `pow`,
  `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `radians`,
  `degrees`.
- Constants (0-arity): `pi`, `tau`. Call as `(pi)` and `(tau)`.
- Smoothing (WGSL): `saturate`, `step`, `smoothstep`.
- Vector ops: `normalize`, `distance`, `reflect`.
- List ops: `nth`, `count`.
- Seeded random: `hash`, `rand01`, `rand-range`, `rand-int`,
  `rand-bool`, `rand-choice`.
- Control: `let`, `if`, `cond`.

Truthiness is simple: `false` and `nil` are falsy. Everything else,
including `0`, `""`, and `[]`, is truthy.

### Domain errors propagate as NaN

Operations like `(sqrt -1)`, `(asin 2)`, or `(pow -1 0.5)` return
IEEE 754 `NaN` rather than raising an error. This keeps
cross-platform behaviour bit-faithful — every host produces the same
NaN — and lets manifests carry NaN through nested expressions
without special-casing. If you want strict input checks, guard with
`(if (>= x 0) (sqrt x) ...)`.

### Reproducible randomness

The seeded random functions are pure, deterministic functions of
their `seed` and `key` arguments. They use a fixed SplitMix64-based
mixer, so the same `(seed, key)` pair produces the same value across
runs, platforms, and Zig versions:

```sjon
(rand01 1 0)              ; float in [0, 1)
(rand-range 1 0 -2 5)     ; float in [-2, 5)
(rand-int   1 0 0 9)      ; integer in [0, 9] inclusive
(rand-bool  1 0 0.5)      ; true with probability 0.5
(rand-choice 1 0 [10 20 30])  ; pick an element
```

Use `seed` for a stable per-document base (e.g. a scene id) and
`key` to walk through a sequence of independent draws. Integer
seeds are recommended; `(rand01 1 0)` and `(rand01 1.0 0.0)` are
guaranteed to produce identical streams.

Typed signatures do not turn SJON into a static programming language.
They are a validator aid for expression heads that advertise their
argument shapes. Opaque or polymorphic heads still check arity first and
leave value-specific failures to evaluation.

## Exercises

Evaluate by hand:

```sjon
(+ 1 2 3)
(- 10 3 2)
(* 2 3 4)
(/ 100 5 2)
(mod 17 5)
```

Predict truthiness:

```sjon
(and true 1 "ok")
(and true nil "never")
(or false nil 0)
(or false nil)
(not false)
```

Remember:

- `and` returns the first falsy value, or the last value if all are
  truthy.
- `or` returns the first truthy value, or `false` if none are truthy.

Repair expression arity:

```sjon
(lerp 0 10)
```

`lerp` needs three arguments:

```sjon
(lerp 0 10 0.5)
```

Compare positional vs labeled — `clamp` declares `:x :lo :hi`, so both
calls below are valid and produce the same value:

```sjon
(clamp 1.5 0 1)
(clamp :x 1.5 :lo 0 :hi 1)
(clamp :hi 1 :x 1.5 :lo 0)
```

A function without declared labels (`+`, here variadic) continues to
reject the kvpair form:

```sjon
(+ :a 1 :b 2) ; rejected
```

Repair typed expression arguments:

```sjon
(vec3 1 "two" 3)
```

`vec3` takes three numbers:

```sjon
(vec3 1 2 3)
```

## Mastery Check

- Can a safe expression appear as a vector element?
- Why is `(lerp :t 0.5)` invalid? (hint: missing labels, not the
  presence of labels — `lerp` declares `:from :to :t`).
- Why is `(lerp 0 :to 10 0.5)` invalid?
- Why can `(vec3 1 "x" 3)` fail during validation?
- Why does `(vec3 r r r)` usually defer type certainty until runtime?
- What values are falsy?
- What does `(or false nil)` return?

Next: [Bindings and Control Flow](08-bindings-and-control-flow.md).
