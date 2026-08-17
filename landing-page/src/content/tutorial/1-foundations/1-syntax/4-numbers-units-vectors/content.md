---
type: lesson
title: 'Numbers, Units, and Vectors'
---

## Mental Model

A number can carry an opaque unit suffix:

```sjon
4b
90deg
50%
250ms
1.5e2hz
```

[Open in playground →](/playground#s=NGIKOTBkZWcKNTAlCjI1MG1zCjEuNWUyaHo)

A hyphen may join two letter runs inside one unit:

```sjon
2d-array
5ms-per-frame
```

[Open in playground →](/playground#s=MmQtYXJyYXkKNW1zLXBlci1mcmFtZQ)

but only when a **letter** follows the hyphen. `1em-2` is two values —
`1em` and `-2` — not one number with the unit `em-2`.

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

[Open in playground →](/playground#s=MWU5ICAgICAgIDsgZXhwb25lbnQKMWUrOSAgICAgIDsgZXhwb25lbnQKMWVtICAgICAgIDsgbnVtYmVyIDEgd2l0aCB1bml0IGVtCjFlLTltcyAgICA7IGV4cG9uZW50IHBsdXMgdW5pdCBtcw)

Underscores group digits and are stripped before parsing, and a `0x`
prefix writes an integer in hexadecimal:

```sjon
1_000_000     ; the number 1000000
0xFF          ; the number 255
0Xff          ; the same number — case is free
0xFFFF_FFFF   ; 4294967295, grouped
-0x10         ; -16
```

[Open in playground →](/playground#s=MV8wMDBfMDAwICAgICA7IHRoZSBudW1iZXIgMTAwMDAwMAoweEZGICAgICAgICAgIDsgdGhlIG51bWJlciAyNTUKMFhmZiAgICAgICAgICA7IHRoZSBzYW1lIG51bWJlciDigJQgY2FzZSBpcyBmcmVlCjB4RkZGRl9GRkZGICAgOyA0Mjk0OTY3Mjk1LCBncm91cGVkCi0weDEwICAgICAgICAgOyAtMTY)

Hex is an *integer* spelling: no fraction, no exponent, no unit. The
token stops at the first byte that isn't a hex digit, so `0xFFms` is
the number `0xFF` followed by the symbol `ms`.

Vectors are ordered lists:

```sjon
[160 120]
[0.9 0.4 0.2 1.0]
[[0 0] [1 0] [1 1]]
```

[Open in playground →](/playground#s=WzE2MCAxMjBdClswLjkgMC40IDAuMiAxLjBdCltbMCAwXSBbMSAwXSBbMSAxXV0)

A plugin may refine a vector slot to require a length and element kind,
such as "2-vector of numbers". When a plugin only says "vector", the
validator checks that the value is a vector; when it says "2-vector of
numbers", it also checks the shape.

## Worked Example

```sjon
(shape :path :closed true
  :points [[0 0] [1 0] [1 1] [0 1]])
```

[Open in playground →](/playground#s=KHNoYXBlIDpwYXRoIDpjbG9zZWQgdHJ1ZQogIDpwb2ludHMgW1swIDBdIFsxIDBdIFsxIDFdIFswIDFdXSk)

Read the values:

- `true` is a boolean.
- `[[0 0] [1 0] [1 1] [0 1]]` is a vector of vectors.
- Each inner vector looks like a point.

From the shapes tutorial scene:

```sjon
(circle :center [160 120] :radius (* 2 16))
```

[Open in playground →](/playground#s=KGNpcmNsZSA6Y2VudGVyIFsxNjAgMTIwXSA6cmFkaXVzICgqIDIgMTYpKQ)

`:center` is written in the conventional point shape, `[x y]`.
`:radius` is an expression in a numeric slot.

## Exercises

Classify the unit behavior:

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
value (letter after the hyphen), the third is two (a digit ends a unit),
and the fourth is two (no unit involved at all — that is subtraction's
spelling).

Predict the value. Each of these is a number — say which one:

1. `0xFF`
2. `0x10`
3. `10x`
4. `0xFFms`

The third is the one worth pausing on. `x` only starts a hex prefix
right after a lone `0`; everywhere else it is an ordinary unit letter,
so `10x` is the number `10` with unit `x`. That gate is what keeps every
pre-hex document reading exactly as it did.

Repair the values:

```sjon
(mask :bits 0x)
```

[Open in playground →](/playground#s=KG1hc2sgOmJpdHMgMHgp)

A `0x` prefix with no hex digit after it is a parse error, not the
number zero. Finish the literal:

```sjon
(mask :bits 0xFF)
```

[Open in playground →](/playground#s=KG1hc2sgOmJpdHMgMHhGRik)

```sjon
(mask :bits 0xGG)
```

[Open in playground →](/playground#s=KG1hc2sgOmJpdHMgMHhHRyk)

`G` is not a hex digit. Hex digits are `0`–`9` and `a`–`f` (either
case):

```sjon
(mask :bits 0xFF)
```

[Open in playground →](/playground#s=KG1hc2sgOmJpdHMgMHhGRik)

```sjon
(circle :center [160] :radius 32)
```

[Open in playground →](/playground#s=KGNpcmNsZSA6Y2VudGVyIFsxNjBdIDpyYWRpdXMgMzIp)

If the plugin docs say `:center` is a 2-number point, write two
numbers:

```sjon
(circle :center [160 120] :radius 32)
```

[Open in playground →](/playground#s=KGNpcmNsZSA6Y2VudGVyIFsxNjAgMTIwXSA6cmFkaXVzIDMyKQ)

```sjon
(shape :sdf :color [0.9 0.4 0.2])
```

[Open in playground →](/playground#s=KHNoYXBlIDpzZGYgOmNvbG9yIFswLjkgMC40IDAuMl0p)

If `:color` expects RGBA, write four numbers:

```sjon
(shape :sdf :color [0.9 0.4 0.2 1.0])
```

[Open in playground →](/playground#s=KHNoYXBlIDpzZGYgOmNvbG9yIFswLjkgMC40IDAuMiAxLjBdKQ)

```sjon
(delay :wait 0.5)
```

[Open in playground →](/playground#s=KGRlbGF5IDp3YWl0IDAuNSk)

If `:wait` expects a unit-bearing duration, supply the unit the plugin
allows:

```sjon
(delay :wait 0.5s)
```

[Open in playground →](/playground#s=KGRlbGF5IDp3YWl0IDAuNXMp)

```sjon
(shape :path :points [0 0 1 0 1 1])
```

[Open in playground →](/playground#s=KHNoYXBlIDpwYXRoIDpwb2ludHMgWzAgMCAxIDAgMSAxXSk)

If `:points` expects a vector of points, group each point:

```sjon
(shape :path :points [[0 0] [1 0] [1 1]])
```

[Open in playground →](/playground#s=KHNoYXBlIDpwYXRoIDpwb2ludHMgW1swIDBdIFsxIDBdIFsxIDFdXSk)

A schema can also constrain a number's **value**, not just its
tag. A value-kind with a `:numeric` refinement pins ranges
(`:min`, `:max`, `:exclusive-min`, `:exclusive-max`) and
integrality (`:integer true`). The reference is in
`docs/LANGUAGE.md` §6.5 (NumericBounds) and §4.3 of
`docs/portable-manifest-v1.md`. As an author you don't write
the bound; you just see `number_below_min` / `number_above_max`
diagnostics if your value falls outside the declared range.

<section class="mastery-quiz" data-lesson="numbers-units-vectors">
  <h2>Mastery Check</h2>
  <ol class="mc-list">
    <li class="mc-item" data-correct="0">
      <p class="mc-q">Does SJON itself know that <code>ms</code> means milliseconds?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-0" value="0" /> <span>No — units are opaque tags; the host plugin decides what each suffix means.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-0" value="1" /> <span>Yes — <code>ms</code> is a built-in unit.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-0" value="2" /> <span>Only if the document declares <code>:units (ms ...)</code>.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="2">
      <p class="mc-q">What is the difference between <code>1e9</code> and <code>1em</code>?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-1" value="0" /> <span>They are equivalent — both are numbers in scientific notation.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-1" value="1" /> <span><code>1em</code> is CSS-only; SJON rejects it.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-1" value="2" /> <span><code>1e9</code> is a number in scientific notation; <code>1em</code> is a number with a unit suffix.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">Is <code>[0 0 1 1]</code> the same shape as <code>[[0 0] [1 1]]</code>?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-2" value="0" /> <span>No — the first is a flat 4-vector; the second is a vector of two 2-vectors.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-2" value="1" /> <span>Yes — vectors flatten automatically.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-2" value="2" /> <span>Only when nested under <code>:points</code>.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">Can vector elements be forms?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-3" value="0" /> <span>No — vectors hold only atoms and other vectors.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-3" value="1" /> <span>Yes — vectors hold any value, including forms (e.g., expressions).</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-3" value="2" /> <span>Only inside <code>(let ...)</code>.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">Why is <code>10x</code> not a hex literal?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-4" value="0" /> <span>It is — <code>10x</code> is 16 in hexadecimal.</span></label>
        <p class="mc-explanation" hidden>No — there is no <code>0x</code> prefix here at all. The lexeme is the digits <code>10</code> followed by the unit letter <code>x</code>.</p>
      </li>
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-4" value="1" /> <span>The <code>0x</code> prefix is only recognised after a lone <code>0</code>, so elsewhere <code>x</code> is an ordinary unit letter: <code>10x</code> is the number 10 with unit <code>x</code>.</span></label>
        <p class="mc-explanation" hidden>Correct, and the narrowness is the point: gating the prefix on a bare <code>0</code> (optionally signed) is what lets hex be added without changing how a single pre-existing document reads.</p>
      </li>
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-4" value="2" /> <span>Hex needs at least two digits after the prefix.</span></label>
        <p class="mc-explanation" hidden>Hex needs exactly one digit minimum — <code>0xF</code> is fine. The digit count is not what disqualifies <code>10x</code>.</p>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q"><code>2d-array</code> is one value and <code>1em-2</code> is two. What single rule decides both?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-5" value="0" /> <span>Hyphens are allowed inside a unit, and <code>2</code> is not a valid unit character.</span></label>
        <p class="mc-explanation" hidden>Close, but stated backwards: the rule is about what follows the hyphen, not about which bytes may appear in a unit. A trailing <code>2d-</code> also ends at <code>2d</code>, and nothing about <code>2</code> being invalid explains that.</p>
      </li>
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-5" value="1" /> <span>Inside a unit, a hyphen continues the suffix only when the next byte is an ASCII letter — otherwise it ends the token.</span></label>
        <p class="mc-explanation" hidden>Correct, and the narrowness is the point: it is the smallest rule that gets <code>2d-array</code> while leaving every previously-valid input reading exactly as it did.</p>
      </li>
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-5" value="2" /> <span>The lexer looks the unit up against a table of known units.</span></label>
        <p class="mc-explanation" hidden>Units are opaque to the substrate — SJON never interprets one, so there is no table to consult. A plugin decides which units it accepts, long after lexing.</p>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">What does <code>sjon fmt</code> print for <code>0xFF</code>, and why?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-6" value="0" /> <span><code>0xFF</code> — the formatter preserves the source spelling of every literal.</span></label>
        <p class="mc-explanation" hidden>The formatter has no access to the source text; it prints from the parsed tree. No numeric spelling survives it — not underscores, not exponents, not hex.</p>
      </li>
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-6" value="1" /> <span><code>255</code> — the formatter works from the value and never sees your source, the same reason <code>1_000</code> prints as <code>1000</code>.</span></label>
        <p class="mc-explanation" hidden>Correct. Values round-trip; spellings do not (<code>LANGUAGE.md</code> §4.2). Keeping the hex spelling would need a carrier for something the value already determines.</p>
      </li>
      <li>
        <label><input type="radio" name="q-numbers-units-vectors-6" value="2" /> <span>It refuses to format a file containing hex.</span></label>
        <p class="mc-explanation" hidden>It formats normally — hex is an ordinary integer literal by the time the printer sees it.</p>
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
