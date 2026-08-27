# 02 - First Document

## Goal

Grow a document from a single atom up to a nested scene without ever
being unsure what the tree looks like, and know which parts of the
layout the parser reads and which parts are only for you.

## A Document Is a Sequence of Values

In [Orientation](01-orientation.md) I said a document is a flat list of
roots. Here is the more useful version of that sentence: a document is a
sequence of **values**, and a value is one of three things.

```
value = atom          2, "intro", true, nil, ortho, :zoom
      | vector        [1920 1080]
      | form          (camera :ortho :zoom 2)
```

That is the entire grammar of shapes. Every SJON file you will ever read
is those three things nested inside each other, and the nesting is done
by exactly two characters: `(` for a form, `[` for a vector.

Nothing else shapes the tree. Newlines don't. Indentation doesn't.
Whitespace exists to separate one value from the next, and any amount of
it separates just as well as any other. When you indent a child under
its parent you are writing for the next human, not for the parser, which
is why the parser will never punish you for getting it wrong and never
reward you for getting it right. The reviewer will do both.

What the parser *does* keep is **order**. If you write the keys before
the children, every tool downstream sees the keys before the children:
the printer, the JSON bridge, the binary encoder, the editor. Source
order survives every hop.

## Growing the Camera

Let's build our running example one value at a time, and watch the tree
each time. Start with a document that is a single atom:

```sjon
2
```

```
document
  `-- 2
```

That is a legal SJON document. It has one root, and the root is an atom.
Now make the root a form instead:

```sjon
(camera :zoom 2)
```

```
document
  `-- (camera)
        :zoom 2
```

The atom didn't disappear; it moved. `2` is now the value half of a
kvpair inside the form. Give the camera a parent:

```sjon
(canvas :name "main" :size [1920 1080]
  (camera :zoom 2))
```

```
document
  `-- (canvas)
        :name "main"
        :size [1920 1080]
        `-- (camera)
              :zoom 2
```

And one more level, which is where we rejoin `basic.sjon`:

```sjon
(scene :name "intro"
  (canvas :name "main" :size [1920 1080]
    (camera :ortho :zoom 2)))
```

```
document
  `-- (scene)
        :name "intro"
        `-- (canvas)
              :name "main"
              :size [1920 1080]
              `-- (camera)
                    :ortho          <- flag
                    :zoom 2
```

All four snippets are syntactically valid SJON, and I want to be precise
about what that means: the parser accepts every one of them. Whether
`scene` is a head your host has heard of, and whether `:zoom` is a slot
a camera actually has, is a completely separate question that a schema
answers. [Reading plugin schemas](09-reading-plugin-schemas.md) is where we
start.

## More Than One Root

The flat list of roots really is a list, and it is allowed to be longer
than one:

```sjon
(layer :name "background" :z 0)
(layer :name "midground" :z 1)
(layer :name "foreground" :z 2)
```

```
document
  |-- (layer :name "background" :z 0)
  |-- (layer :name "midground" :z 1)
  `-- (layer :name "foreground" :z 2)
```

Three roots, three peers, no wrapper. Reach for this when the host
expects a list of things that are all the same kind: batches, test
fixtures, a palette, a set of presets. Reach for a single root when the
document describes one thing that happens to have parts, which is what
`(scene ...)` is.

## House Style

SJON lets you intermix kvpairs and positional children freely, so this
parses:

```sjon
(scene
  (canvas :name "main")
  :name "intro")
```

The `scene` form has a positional child first and its `:name` kvpair
after. Nothing is wrong with it. But read the two versions next to each
other and you can feel the difference:

```sjon
(scene :name "intro"
  (canvas :name "main"))
```

Keys first, then children. I use that order everywhere, in this order:

1. Required keys.
2. Optional keys.
3. Positional child forms.

The payoff is in review, not in parsing. When every `:key value` sits on
its own line at the top of the form, adding a key touches one line,
removing one touches one line, and reordering children never drags a key
along with it. A diff that touches one line is a diff a reviewer can
check in a second.

## Exercises

Write each of these from memory, then check the shape by drawing the
tree:

1. A single atomic root holding the number `130`.
2. A single form root named `scene` with `:name "intro"`.
3. A `scene` with a nested `canvas`.
4. A `canvas` with a nested `camera` and a nested `stack`.
5. A multi-root document holding three `(layer ...)` forms.

Predict, before you read on, how many roots this has and what the first
root's children are:

```sjon
(scene
  (canvas :name "main")
  :name "intro")
```

One root. Its children are the `(canvas ...)` form, then the kvpair
`:name "intro"`, in that order. Valid, and against house style.

Repair. This is two roots, and the first one cannot exist:

```sjon
:name "intro"
(canvas :name "main")
```

A kvpair at the top level has no form to be a key of, exactly as in
[Orientation](01-orientation.md). Pick the container it belongs to:

```sjon
(scene :name "intro"
  (canvas :name "main"))
```

## Mastery Check

- What are the roots in a document with three top-level `(layer ...)`
  forms?
- Does indentation change the tree?
- Why do keys-first documents make later edits easier to review?

Next: [Atoms and Intent](03-atoms-and-intent.md).
