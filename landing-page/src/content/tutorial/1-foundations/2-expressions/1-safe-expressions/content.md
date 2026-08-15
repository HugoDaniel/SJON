---
type: lesson
title: 'Safe Expressions'
---

## Mental Model

An expression is a form whose head is declared as an expression function
by the active schema:

```sjon
(camera :zoom (* 2 4))
```

[Open in playground →](/playground#s=KGNhbWVyYSA6em9vbSAoKiAyIDQpKQ)

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

[Open in playground →](/playground#s=KGxlcnAgMCAxMCAwLjUpICAgICAgICAgICAgICA7IHBvc2l0aW9uYWwKKGxlcnAgOmZyb20gMCA6dG8gMTAgOnQgMC41KSA7IGxhYmVsZWQg4oCUIHNhbWUgY2FsbAoobGVycCA6dCAwLjUgOmZyb20gMCA6dG8gMTApIDsgbGFiZWxlZCwgcmVvcmRlcmVkIOKAlCBzYW1lIGNhbGw)

A labeled call is all-or-nothing. Mixing positional and labeled
arguments in the same call is a hard error:

```sjon
(lerp 0 :to 10 0.5) ; rejected — expr_mixed_args
```

[Open in playground →](/playground#s=KGxlcnAgMCA6dG8gMTAgMC41KSA7IHJlamVjdGVkIOKAlCBleHByX21peGVkX2FyZ3M)

If a function does not declare labels (e.g. `+`, `*`, `<`), kvpairs in
the argument list keep being rejected — that vocabulary doesn't have
named slots:

```sjon
(+ :a 1 :b 2) ; rejected — expr_kvpair_not_allowed
```

[Open in playground →](/playground#s=KCsgOmEgMSA6YiAyKSA7IHJlamVjdGVkIOKAlCBleHByX2t2cGFpcl9ub3RfYWxsb3dlZA)

For labeled functions, the validator catches the usual mistakes:
unknown labels, duplicate labels, and missing labels each have their
own diagnostic code.

Some expression functions also declare typed signatures. The validator
can catch obvious literal mistakes before evaluation:

```sjon
(vec3 1 "x" 3)  ; the string should be a number
(< true "x")    ; ordering comparisons take numbers
```

[Open in playground →](/playground#s=KHZlYzMgMSAieCIgMykgIDsgdGhlIHN0cmluZyBzaG91bGQgYmUgYSBudW1iZXIKKDwgdHJ1ZSAieCIpICAgIDsgb3JkZXJpbmcgY29tcGFyaXNvbnMgdGFrZSBudW1iZXJz)

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

[Open in playground →](/playground#s=KGxldCBbciAwLjVdCiAgKHZlYzMgciByIHIpKSAgICAgICAgIDsgYHJgIGlzIG9wYXF1ZTsgdmFsaWRhdGVzIGNsZWFuLgoKKCsgKHZlYzMgMSAyIDMpIDEpICAgICAgOyB2ZWMzIGRlY2xhcmVzIGA6cmVzdWx0IHZlY3RvcmA7IGArYCB3YW50cwogICAgICAgICAgICAgICAgICAgICAgICA7IGEgbnVtYmVyIOKGkiBleHByX3R5cGVfbWlzbWF0Y2ggYXQgYXJnIDAuCgooKyAxIChsZXQgW3IgMV0gcikpICAgICA7IGBsZXRgIGhhcyBubyBkZWNsYXJlZCByZXN1bHQg4oaSIGRlZmVycy4)

## Worked Example

From [`../../examples/with-expressions.sjon`](../../examples/with-expressions.sjon):

```sjon
(+ 1 2 3)              ; 6
(* 2 3 4)              ; 24
(lerp 0 10 0.25)       ; 2.5
(clamp 1.5 0 1)        ; 1
(dot (vec3 1 2 3) (vec3 4 5 6)) ; 32
```

[Open in playground →](/playground#s=KCsgMSAyIDMpICAgICAgICAgICAgICA7IDYKKCogMiAzIDQpICAgICAgICAgICAgICA7IDI0CihsZXJwIDAgMTAgMC4yNSkgICAgICAgOyAyLjUKKGNsYW1wIDEuNSAwIDEpICAgICAgICA7IDEKKGRvdCAodmVjMyAxIDIgMykgKHZlYzMgNCA1IDYpKSA7IDMy)

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

[Open in playground →](/playground#s=KHJhbmQwMSAxIDApICAgICAgICAgICAgICA7IGZsb2F0IGluIFswLCAxKQoocmFuZC1yYW5nZSAxIDAgLTIgNSkgICAgIDsgZmxvYXQgaW4gWy0yLCA1KQoocmFuZC1pbnQgICAxIDAgMCA5KSAgICAgIDsgaW50ZWdlciBpbiBbMCwgOV0gaW5jbHVzaXZlCihyYW5kLWJvb2wgIDEgMCAwLjUpICAgICAgOyB0cnVlIHdpdGggcHJvYmFiaWxpdHkgMC41CihyYW5kLWNob2ljZSAxIDAgWzEwIDIwIDMwXSkgIDsgcGljayBhbiBlbGVtZW50)

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

[Open in playground →](/playground#s=KCsgMSAyIDMpCigtIDEwIDMgMikKKCogMiAzIDQpCigvIDEwMCA1IDIpCihtb2QgMTcgNSk)

Predict truthiness:

```sjon
(and true 1 "ok")
(and true nil "never")
(or false nil 0)
(or false nil)
(not false)
```

[Open in playground →](/playground#s=KGFuZCB0cnVlIDEgIm9rIikKKGFuZCB0cnVlIG5pbCAibmV2ZXIiKQoob3IgZmFsc2UgbmlsIDApCihvciBmYWxzZSBuaWwpCihub3QgZmFsc2Up)

Remember:

- `and` returns the first falsy value, or the last value if all are
  truthy.
- `or` returns the first truthy value, or `false` if none are truthy.

Repair expression arity:

```sjon
(lerp 0 10)
```

[Open in playground →](/playground#s=KGxlcnAgMCAxMCk)

`lerp` needs three arguments:

```sjon
(lerp 0 10 0.5)
```

[Open in playground →](/playground#s=KGxlcnAgMCAxMCAwLjUp)

Compare positional vs labeled — `clamp` declares `:x :lo :hi`, so both
calls below are valid and produce the same value:

```sjon
(clamp 1.5 0 1)
(clamp :x 1.5 :lo 0 :hi 1)
(clamp :hi 1 :x 1.5 :lo 0)
```

[Open in playground →](/playground#s=KGNsYW1wIDEuNSAwIDEpCihjbGFtcCA6eCAxLjUgOmxvIDAgOmhpIDEpCihjbGFtcCA6aGkgMSA6eCAxLjUgOmxvIDAp)

A function without declared labels (`+`, here variadic) continues to
reject the kvpair form:

```sjon
(+ :a 1 :b 2) ; rejected
```

[Open in playground →](/playground#s=KCsgOmEgMSA6YiAyKSA7IHJlamVjdGVk)

Repair typed expression arguments:

```sjon
(vec3 1 "two" 3)
```

[Open in playground →](/playground#s=KHZlYzMgMSAidHdvIiAzKQ)

`vec3` takes three numbers:

```sjon
(vec3 1 2 3)
```

[Open in playground →](/playground#s=KHZlYzMgMSAyIDMp)

<section class="mastery-quiz" data-lesson="safe-expressions">
  <h2>Mastery Check</h2>
  <ol class="mc-list">
    <li class="mc-item" data-correct="2">
      <p class="mc-q">Can a safe expression appear as a vector element?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-safe-expressions-0" value="0" /> <span>No — only literals are allowed inside vectors.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-safe-expressions-0" value="1" /> <span>Only if the vector is wrapped in <code>(expr ...)</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-safe-expressions-0" value="2" /> <span>Yes — a vector holds any value, so a form (expression) can sit alongside literals.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">Why is <code>(lerp 0 :to 10 0.5)</code> invalid?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-safe-expressions-1" value="0" /> <span>A labeled call is all-or-nothing — mixing positional and labeled arguments produces <code>expr_mixed_args</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-safe-expressions-1" value="1" /> <span>The numbers are out of range.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-safe-expressions-1" value="2" /> <span><code>lerp</code> does not exist.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">Why can <code>(vec3 1 &quot;x&quot; 3)</code> fail validation before evaluation?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-safe-expressions-2" value="0" /> <span><code>vec3</code> only accepts symbols.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-safe-expressions-2" value="1" /> <span>The signature is typed — the validator catches the literal <code>&quot;x&quot;</code> where a number is required.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-safe-expressions-2" value="2" /> <span>Strings are illegal in expressions.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="2">
      <p class="mc-q">What does <code>(or false nil)</code> return?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-safe-expressions-3" value="0" /> <span><code>true</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-safe-expressions-3" value="1" /> <span>It raises an error.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-safe-expressions-3" value="2" /> <span><code>nil</code> — both branches are falsy, so <code>or</code> falls through and returns the last value.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">What values are falsy in safe expressions?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-safe-expressions-4" value="0" /> <span>Only <code>nil</code> and <code>false</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-safe-expressions-4" value="1" /> <span><code>0</code>, <code>&quot;&quot;</code>, <code>nil</code>, and <code>false</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-safe-expressions-4" value="2" /> <span>Any value not equal to <code>true</code>.</span></label>
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
