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

Repair the values:

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
  </ol>
  <div class="mc-controls">
    <button type="button" class="mc-submit">Submit answers</button>
    <button type="button" class="mc-reset" hidden>Reset</button>
    <p class="mc-score" hidden></p>
  </div>
</section>
