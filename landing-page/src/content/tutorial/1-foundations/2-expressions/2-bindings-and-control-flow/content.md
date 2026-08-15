---
type: lesson
title: 'Bindings and Control Flow'
---

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

[Open in playground →](/playground#s=KGxldCBbYSAxCiAgICAgIGIgKCsgYSAyKQogICAgICBjICgqIGEgYildCiAgKCsgYSBiIGMpKQ)

Each binding can see earlier bindings in the same vector. The body can
see them all.

`if` evaluates one branch:

```sjon
(if (> t 0.5) 1 0)
```

[Open in playground →](/playground#s=KGlmICg-IHQgMC41KSAxIDAp)

`cond` checks test/value pairs from left to right and stops at the
first test that is truthy, returning its paired value. Tests and
values after the chosen pair are not evaluated:

```sjon
(cond
  (< x 0) -1
  (> x 0)  1
  true     0)
```

[Open in playground →](/playground#s=KGNvbmQKICAoPCB4IDApIC0xCiAgKD4geCAwKSAgMQogIHRydWUgICAgIDAp)

Use a literal `true` as the default branch. If no test is truthy and
there is no default, `cond` returns `nil`.

## Worked Example

```sjon
(group :name "fade"
  (shape :sdf
    :radius 0.5
    :alpha (lerp 1 0 (clamp t 0 1))))
```

[Open in playground →](/playground#s=KGdyb3VwIDpuYW1lICJmYWRlIgogIChzaGFwZSA6c2RmCiAgICA6cmFkaXVzIDAuNQogICAgOmFscGhhIChsZXJwIDEgMCAoY2xhbXAgdCAwIDEpKSkp)

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

[Open in playground →](/playground#s=KGdyb3VwIDpuYW1lICJmYWRlIgogIChzaGFwZSA6c2RmCiAgICA6cmFkaXVzIDAuNQogICAgOmFscGhhIChsZXQgW3BoYXNlIChjbGFtcCB0IDAgMSldCiAgICAgICAgICAgICAobGVycCAxIDAgcGhhc2UpKSkp)

The expression is still small and local. If the logic stops feeling
like "a little safe math", lift it into the host domain and pass the
result as data.

## Exercises

Write an alpha fade:

```sjon
(shape :sdf
  :alpha (lerp 0 1 (clamp t 0 1)))
```

[Open in playground →](/playground#s=KHNoYXBlIDpzZGYKICA6YWxwaGEgKGxlcnAgMCAxIChjbGFtcCB0IDAgMSkpKQ)

Now invert it:

```sjon
(shape :sdf
  :alpha (lerp 1 0 (clamp t 0 1)))
```

[Open in playground →](/playground#s=KHNoYXBlIDpzZGYKICA6YWxwaGEgKGxlcnAgMSAwIChjbGFtcCB0IDAgMSkpKQ)

Use `let` to avoid repeating work:

```sjon
(shape :sdf
  :radius (let [phase (clamp t 0 1)
                pulse (lerp 0.8 1.2 phase)]
            (* 20 pulse)))
```

[Open in playground →](/playground#s=KHNoYXBlIDpzZGYKICA6cmFkaXVzIChsZXQgW3BoYXNlIChjbGFtcCB0IDAgMSkKICAgICAgICAgICAgICAgIHB1bHNlIChsZXJwIDAuOCAxLjIgcGhhc2UpXQogICAgICAgICAgICAoKiAyMCBwdWxzZSkpKQ)

Repair the `let` shape:

```sjon
(let [a 1 b] (+ a b))
```

[Open in playground →](/playground#s=KGxldCBbYSAxIGJdICgrIGEgYikp)

The binding vector must contain name/expression pairs. Give `b` a
value:

```sjon
(let [a 1
      b (+ a 2)]
  (+ a b))
```

[Open in playground →](/playground#s=KGxldCBbYSAxCiAgICAgIGIgKCsgYSAyKV0KICAoKyBhIGIpKQ)

Repair the missing default:

```sjon
(cond
  (< x 0) -1
  (> x 0)  1)
```

[Open in playground →](/playground#s=KGNvbmQKICAoPCB4IDApIC0xCiAgKD4geCAwKSAgMSk)

This is valid, but returns `nil` when neither test matches. If a zero
case is intended, add a default:

```sjon
(cond
  (< x 0) -1
  (> x 0)  1
  true     0)
```

[Open in playground →](/playground#s=KGNvbmQKICAoPCB4IDApIC0xCiAgKD4geCAwKSAgMQogIHRydWUgICAgIDAp)

<section class="mastery-quiz" data-lesson="bindings-and-control-flow">
  <h2>Mastery Check</h2>
  <ol class="mc-list">
    <li class="mc-item" data-correct="0">
      <p class="mc-q">Can a later <code>let</code> binding refer to an earlier one?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-bindings-and-control-flow-0" value="0" /> <span>Yes — bindings are sequential; later names see earlier ones.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-bindings-and-control-flow-0" value="1" /> <span>No — <code>let</code> bindings are unordered.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-bindings-and-control-flow-0" value="2" /> <span>Only if wrapped in another <code>let</code>.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">Can an earlier <code>let</code> binding refer to a later one?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-bindings-and-control-flow-1" value="0" /> <span>Yes — <code>let</code> is mutually recursive.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-bindings-and-control-flow-1" value="1" /> <span>No — earlier bindings cannot see names introduced later in the same <code>let</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-bindings-and-control-flow-1" value="2" /> <span>Only inside <code>cond</code>.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="2">
      <p class="mc-q">What supplies <code>t</code> in an expression like <code>(clamp t 0 1)</code>?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-bindings-and-control-flow-2" value="0" /> <span>It defaults to <code>0</code> when undefined.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-bindings-and-control-flow-2" value="1" /> <span>It refers to the literal symbol <code>t</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-bindings-and-control-flow-2" value="2" /> <span>A surrounding <code>let</code> or a host-supplied binding provides <code>t</code>.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">When should expression logic move out of SJON?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-bindings-and-control-flow-3" value="0" /> <span>Whenever it uses <code>if</code> or <code>cond</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-bindings-and-control-flow-3" value="1" /> <span>When the logic needs side effects, recursion, I/O, or general computation — those belong in the host.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-bindings-and-control-flow-3" value="2" /> <span>Never — SJON is Turing-complete.</span></label>
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
