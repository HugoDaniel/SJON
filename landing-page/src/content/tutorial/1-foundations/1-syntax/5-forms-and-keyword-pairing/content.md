---
type: lesson
title: 'Forms and Keyword Pairing'
---

## Mental Model

A form has a head and an ordered list of children:

```sjon
(camera
  :ortho
  :zoom 2
  :pos [0 1])
```

[Open in playground →](/playground#s=KGNhbWVyYQogIDpvcnRobwogIDp6b29tIDIKICA6cG9zIFswIDFdKQ)

The children are:

- `:ortho` - a positional flag.
- `:zoom 2` - a kvpair.
- `:pos [0 1]` - a kvpair.

The key rule:

```sjon
:key value
```

[Open in playground →](/playground#s=OmtleSB2YWx1ZQ)

pairs only when `value` is a non-keyword value. A keyword can never be
the value of a kvpair.

This means:

```sjon
(stack :mode :mask)
```

[Open in playground →](/playground#s=KHN0YWNrIDptb2RlIDptYXNrKQ)

does not mean `mode = :mask`. It means two positional flags:
`:mode` and `:mask`.

Two flags side by side isn't always a mistake. When both keywords are
meant as independent toggles, that same parse is exactly the intent:

```sjon
(text "Hello" :bold :italic)
```

[Open in playground →](/playground#s=KHRleHQgIkhlbGxvIiA6Ym9sZCA6aXRhbGljKQ)

Children: `:bold` flag, `:italic` flag. Both styles apply. The gotcha
bites only when one of those keywords was meant to be a *value*.

That separation is deliberate. Adjacent flags should remain unambiguous:
if one keyword could become another keyword's kvpair value, the two
flags in `(text "Hello" :bold :italic)` would turn into
`bold = :italic`. When a slot needs a value instead, use a symbol,
string, or container shape that the schema documents.

## Worked Example

Broken:

```sjon
(camera :projection :ortho)
```

[Open in playground →](/playground#s=KGNhbWVyYSA6cHJvamVjdGlvbiA6b3J0aG8p)

What the parser sees:

- `:projection` cannot pair with `:ortho`.
- `:projection` is committed as a positional flag.
- `:ortho` is also a positional flag when the form closes.

Repair when the schema expects a symbol:

```sjon
(camera :projection ortho)
```

[Open in playground →](/playground#s=KGNhbWVyYSA6cHJvamVjdGlvbiBvcnRobyk)

Repair when the schema expects free-form text:

```sjon
(camera :projection "ortho")
```

[Open in playground →](/playground#s=KGNhbWVyYSA6cHJvamVjdGlvbiAib3J0aG8iKQ)

Repair when you truly need keywords as values by wrapping them in a
vector:

```sjon
(stack :modes [:mask])
```

[Open in playground →](/playground#s=KHN0YWNrIDptb2RlcyBbOm1hc2tdKQ)

Inside the vector, `:mask` is a keyword value because vectors do not
have kvpairs.

## Exercises

Predict the children before reading the repairs:

```sjon
(stack :mode :overlay)
```

[Open in playground →](/playground#s=KHN0YWNrIDptb2RlIDpvdmVybGF5KQ)

Children: `:mode` flag, `:overlay` flag. Repair as a symbol enum:

```sjon
(stack :mode overlay)
```

[Open in playground →](/playground#s=KHN0YWNrIDptb2RlIG92ZXJsYXkp)

```sjon
(camera :zoom 2 :ortho)
```

[Open in playground →](/playground#s=KGNhbWVyYSA6em9vbSAyIDpvcnRobyk)

Children: kvpair `:zoom 2`, then trailing flag `:ortho`. No repair is
needed if `:ortho` is meant to be a flag.

```sjon
(circle :center [0 0] :radius 1 :fill :evenodd)
```

[Open in playground →](/playground#s=KGNpcmNsZSA6Y2VudGVyIFswIDBdIDpyYWRpdXMgMSA6ZmlsbCA6ZXZlbm9kZCk)

If `:fill` expects a symbol member set, repair with a symbol:

```sjon
(circle :center [0 0] :radius 1 :fill evenodd)
```

[Open in playground →](/playground#s=KGNpcmNsZSA6Y2VudGVyIFswIDBdIDpyYWRpdXMgMSA6ZmlsbCBldmVub2RkKQ)

Repair drill:

```sjon
(badge :label "ok" :shape :circle)
```

[Open in playground →](/playground#s=KGJhZGdlIDpsYWJlbCAib2siIDpzaGFwZSA6Y2lyY2xlKQ)

If `:shape` expects a form slot pinned to `(circle ...)` or `(rect ...)`,
repair it with a form value:

```sjon
(badge :label "ok" :shape (circle :center [0 0] :radius 1))
```

[Open in playground →](/playground#s=KGJhZGdlIDpsYWJlbCAib2siIDpzaGFwZSAoY2lyY2xlIDpjZW50ZXIgWzAgMF0gOnJhZGl1cyAxKSk)

## Kvpairs in expression heads

Data forms pair keys to values; expression heads (`(lerp …)`, `(vec3 …)`)
take positional arguments by default. Some expression functions opt into
a labeled call form so kvpairs work there too — see
[Safe Expressions](07-safe-expressions.md) for the contract.

<section class="mastery-quiz" data-lesson="forms-and-keyword-pairing">
  <h2>Mastery Check</h2>
  <ol class="mc-list">
    <li class="mc-item" data-correct="0">
      <p class="mc-q">What does <code>(stack :mode :mask)</code> parse as?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-forms-and-keyword-pairing-0" value="0" /> <span>A <code>stack</code> form with two positional flags <code>:mode</code> and <code>:mask</code> — a keyword can never be the value of a kvpair.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-forms-and-keyword-pairing-0" value="1" /> <span>A <code>stack</code> form with a kvpair <code>:mode :mask</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-forms-and-keyword-pairing-0" value="2" /> <span>A syntax error.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="2">
      <p class="mc-q">How do you write an enum-like value in a kvpair?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-forms-and-keyword-pairing-1" value="0" /> <span>Use two keywords back-to-back: <code>:projection :ortho</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-forms-and-keyword-pairing-1" value="1" /> <span>Wrap the option in parens: <code>:projection (ortho)</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-forms-and-keyword-pairing-1" value="2" /> <span>Use a symbol or string for the value: <code>:projection ortho</code> or <code>:projection &quot;ortho&quot;</code>.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">Where can a keyword safely be used as a value?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-forms-and-keyword-pairing-2" value="0" /> <span>In a kvpair after another <code>:key</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-forms-and-keyword-pairing-2" value="1" /> <span>As a positional flag — i.e., as a child of a form, not the value of a kvpair.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-forms-and-keyword-pairing-2" value="2" /> <span>Anywhere; SJON makes no distinction.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">Why do forms with no positional children expose keyword-pairing mistakes quickly?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-forms-and-keyword-pairing-3" value="0" /> <span>A stray bare keyword has nowhere legitimate to live, so the schema flags it as a positional child.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-forms-and-keyword-pairing-3" value="1" /> <span>They have stricter parsers.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-forms-and-keyword-pairing-3" value="2" /> <span>They run a second validation pass.</span></label>
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
