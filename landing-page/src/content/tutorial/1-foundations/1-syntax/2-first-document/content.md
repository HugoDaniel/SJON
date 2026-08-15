---
type: lesson
title: 'First Document'
---

## Mental Model

SJON source is a sequence of values. A value can be an atom, vector, or
form. A common authoring shape is:

```sjon
(head :key value
  (child :key value))
```

[Open in playground →](/playground#s=KGhlYWQgOmtleSB2YWx1ZQogIChjaGlsZCA6a2V5IHZhbHVlKSk)

Whitespace is only separation. Newlines and indentation are for humans,
not for meaning.

Source order is preserved. If you write keys before children, tools and
readers see that order. SJON allows kvpairs and positional children to
be intermixed, but the house style for readable documents is:

1. Required keys.
2. Optional keys.
3. Positional child forms.

## Worked Example

Start with an atomic root:

```sjon
42
```

[Open in playground →](/playground#s=NDI)

Now use a single form root:

```sjon
(scene :name "intro")
```

[Open in playground →](/playground#s=KHNjZW5lIDpuYW1lICJpbnRybyIp)

Add a nested child:

```sjon
(scene :name "intro"
  (canvas :name "main" :size [1920 1080]))
```

[Open in playground →](/playground#s=KHNjZW5lIDpuYW1lICJpbnRybyIKICAoY2FudmFzIDpuYW1lICJtYWluIiA6c2l6ZSBbMTkyMCAxMDgwXSkp)

Add a second level:

```sjon
(scene :name "intro"
  (canvas :name "main" :size [1920 1080]
    (camera :ortho :zoom 2)))
```

[Open in playground →](/playground#s=KHNjZW5lIDpuYW1lICJpbnRybyIKICAoY2FudmFzIDpuYW1lICJtYWluIiA6c2l6ZSBbMTkyMCAxMDgwXQogICAgKGNhbWVyYSA6b3J0aG8gOnpvb20gMikpKQ)

All four snippets are syntactically valid SJON. Whether the heads and
keys are accepted depends on the host-loaded schema.

Multiple roots are also valid:

```sjon
(layer :name "background" :z 0)
(layer :name "midground" :z 1)
(layer :name "foreground" :z 2)
```

[Open in playground →](/playground#s=KGxheWVyIDpuYW1lICJiYWNrZ3JvdW5kIiA6eiAwKQoobGF5ZXIgOm5hbWUgIm1pZGdyb3VuZCIgOnogMSkKKGxheWVyIDpuYW1lICJmb3JlZ3JvdW5kIiA6eiAyKQ)

Use multi-root documents for batches, fixtures, palettes, and other
cases where the host expects a list of peer values.

## Exercises

Write:

1. A single atomic root containing the number `130`.
2. A single form root named `scene` with `:name "intro"`.
3. A `scene` with a nested `canvas`.
4. A `canvas` with a nested `camera` and `stack`.
5. A multi-root document containing three `(layer ...)` forms.

Predict:

```sjon
(scene
  (canvas :name "main")
  :name "intro")
```

[Open in playground →](/playground#s=KHNjZW5lCiAgKGNhbnZhcyA6bmFtZSAibWFpbiIpCiAgOm5hbWUgImludHJvIik)

This is syntactically valid. The `scene` form has a positional child
before its `:name` kvpair. The authoring convention would usually move
`:name "intro"` before the child:

```sjon
(scene :name "intro"
  (canvas :name "main"))
```

[Open in playground →](/playground#s=KHNjZW5lIDpuYW1lICJpbnRybyIKICAoY2FudmFzIDpuYW1lICJtYWluIikp)

Repair:

```sjon
:name "intro"
(canvas :name "main")
```

[Open in playground →](/playground#s=Om5hbWUgImludHJvIgooY2FudmFzIDpuYW1lICJtYWluIik)

The first line tries to put a kvpair at the document root. Repair it by
choosing a containing form:

```sjon
(scene :name "intro"
  (canvas :name "main"))
```

[Open in playground →](/playground#s=KHNjZW5lIDpuYW1lICJpbnRybyIKICAoY2FudmFzIDpuYW1lICJtYWluIikp)

<section class="mastery-quiz" data-lesson="first-document">
  <h2>Mastery Check</h2>
  <ol class="mc-list">
    <li class="mc-item" data-correct="2">
      <p class="mc-q">What are the roots in a document with three top-level <code>(layer ...)</code> forms?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-first-document-0" value="0" /> <span>Zero roots — only one root is permitted in a document.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-first-document-0" value="1" /> <span>One root holding three children.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-first-document-0" value="2" /> <span>Three roots — each <code>(layer ...)</code> is its own top-level value.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">Does indentation change the tree?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-first-document-1" value="0" /> <span>No — only parens and brackets shape the tree; whitespace is for readers.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-first-document-1" value="1" /> <span>Yes — children must be indented under their parent.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-first-document-1" value="2" /> <span>Only inside vectors.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">Why do keys-first documents make later edits easier to review?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-first-document-2" value="0" /> <span>They run faster through the parser.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-first-document-2" value="1" /> <span>Each <code>:key value</code> line stands on its own, so diffs and reorderings stay local.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-first-document-2" value="2" /> <span>They take less disk space.</span></label>
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
