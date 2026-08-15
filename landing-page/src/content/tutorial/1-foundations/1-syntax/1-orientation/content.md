---
type: lesson
title: 'Orientation'
---

## Mental Model

A SJON document is a flat list of **roots**. Most authored files use one
root form:

```sjon
(scene :bpm 130)
```

[Open in playground →](/playground#s=KHNjZW5lIDpicG0gMTMwKQ)

Inside that form:

- `(scene ...)` is a **form**.
- `scene` is the form **head**.
- `:bpm 130` is a **kvpair**.
- `130` is an atom.

SJON itself does not know what `scene` means. A host application is the
program embedding SJON, such as a game engine, compiler, or build tool.
It loads one or more plugins, then validates the document against the
vocabulary those plugins provide. Ordinary `.sjon` files do not import
plugins.

Expressions use the same surface as data forms:

```sjon
(camera :zoom (* 2 4))
```

[Open in playground →](/playground#s=KGNhbWVyYSA6em9vbSAoKiAyIDQpKQ)

`(* 2 4)` is just a form in source. It becomes a safe expression only
when the active schema says `*` is an expression function and the host
chooses to evaluate that value.

## Worked Example

From [`../../examples/basic.sjon`](../../examples/basic.sjon):

```sjon
(scene :bpm 130 :name "intro"
  (canvas :name "main" :size [1920 1080]
    (camera :ortho :zoom 2)
    (stack :mode :overlay
      (shape :sdf :radius 0.5 :color [0.9 0.4 0.2 1.0])
      (shape :path :closed true
        :points [[0 0] [1 0] [1 1] [0 1]]))
    (placeholder :note "TODO" :enabled false :data nil)))
```

[Open in playground →](/playground#s=KHNjZW5lIDpicG0gMTMwIDpuYW1lICJpbnRybyIKICAoY2FudmFzIDpuYW1lICJtYWluIiA6c2l6ZSBbMTkyMCAxMDgwXQogICAgKGNhbWVyYSA6b3J0aG8gOnpvb20gMikKICAgIChzdGFjayA6bW9kZSA6b3ZlcmxheQogICAgICAoc2hhcGUgOnNkZiA6cmFkaXVzIDAuNSA6Y29sb3IgWzAuOSAwLjQgMC4yIDEuMF0pCiAgICAgIChzaGFwZSA6cGF0aCA6Y2xvc2VkIHRydWUKICAgICAgICA6cG9pbnRzIFtbMCAwXSBbMSAwXSBbMSAxXSBbMCAxXV0pKQogICAgKHBsYWNlaG9sZGVyIDpub3RlICJUT0RPIiA6ZW5hYmxlZCBmYWxzZSA6ZGF0YSBuaWwpKSk)

Read it as a tree:

- The document has one root: the `(scene ...)` form.
- `scene` has two kvpairs before its child: `:bpm 130` and
  `:name "intro"`.
- `canvas`, `camera`, `stack`, `shape`, and `placeholder` are nested
  forms.
- `[1920 1080]`, `[0.9 0.4 0.2 1.0]`, and
  `[[0 0] [1 0] [1 1] [0 1]]` are vectors.
- `"intro"` and `"TODO"` are strings.
- `true`, `false`, and `nil` are reserved literal atoms.
- `:ortho`, `:sdf`, and `:path` are positional flags in this source.
  Two more flags are hiding in `(stack :mode :overlay ...)`; section 5
  explains why two consecutive keywords don't pair into a kvpair.

## Exercises

1. Open [`../../examples/basic.sjon`](../../examples/basic.sjon).
2. Count the root values. Then count the forms.
3. Mark each vector and write its likely role: size, color, point, or
   list of points.
4. Find every string. Decide whether each string is a label, note, or
   payload.
5. Find every positional flag. Do not decide whether the schema likes
   it yet; just identify the parse shape.

Repair drill:

```sjon
:bpm 130
```

[Open in playground →](/playground#s=OmJwbSAxMzA)

This cannot be a valid top-level kvpair because kvpairs only live inside
forms. Repair it by wrapping it in a form:

```sjon
(scene :bpm 130)
```

[Open in playground →](/playground#s=KHNjZW5lIDpicG0gMTMwKQ)

<section class="mastery-quiz" data-lesson="orientation">
  <h2>Mastery Check</h2>
  <ol class="mc-list">
    <li class="mc-item" data-correct="0">
      <p class="mc-q">Can a document have more than one root?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-orientation-0" value="0" /> <span>Yes — a document is a sequence of root values.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-orientation-0" value="1" /> <span>No — every document must have exactly one root form.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-orientation-0" value="2" /> <span>Only if separated by a blank line.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">Does a <code>.sjon</code> file import plugins?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-orientation-1" value="0" /> <span>No — the host loads plugins; the file just uses their vocabulary.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-orientation-1" value="1" /> <span>Yes, with an <code>(import ...)</code> form at the top.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-orientation-1" value="2" /> <span>Only when the document begins with <code>(plugins ...)</code>.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="2">
      <p class="mc-q">Is <code>(* 2 4)</code> always evaluated just because it looks like arithmetic?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-orientation-2" value="0" /> <span>Yes — any list whose head is <code>*</code> is multiplied automatically.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-orientation-2" value="1" /> <span>Only inside <code>(let ...)</code> blocks.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-orientation-2" value="2" /> <span>No — it is just a form in source; it becomes an expression only when the active schema and host say so.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">Where can a kvpair appear?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-orientation-3" value="0" /> <span>At the top level, between root forms.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-orientation-3" value="1" /> <span>Only inside a form, as a <code>:key value</code> pair among the form's children.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-orientation-3" value="2" /> <span>Inside a vector, between two values.</span></label>
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
