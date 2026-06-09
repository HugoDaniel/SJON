# 02 - First Document

## Goal

Build a tiny SJON document from an atomic root to a nested scene, while
keeping roots, forms, whitespace, and source order clear.

## Mental Model

SJON source is a sequence of values. A value can be an atom, vector, or
form. A common authoring shape is:

```sjon
(head :key value
  (child :key value))
```

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

Now use a single form root:

```sjon
(scene :name "intro")
```

Add a nested child:

```sjon
(scene :name "intro"
  (canvas :name "main" :size [1920 1080]))
```

Add a second level:

```sjon
(scene :name "intro"
  (canvas :name "main" :size [1920 1080]
    (camera :ortho :zoom 2)))
```

All four snippets are syntactically valid SJON. Whether the heads and
keys are accepted depends on the host-loaded schema.

Multiple roots are also valid:

```sjon
(layer :name "background" :z 0)
(layer :name "midground" :z 1)
(layer :name "foreground" :z 2)
```

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

This is syntactically valid. The `scene` form has a positional child
before its `:name` kvpair. The authoring convention would usually move
`:name "intro"` before the child:

```sjon
(scene :name "intro"
  (canvas :name "main"))
```

Repair:

```sjon
:name "intro"
(canvas :name "main")
```

The first line tries to put a kvpair at the document root. Repair it by
choosing a containing form:

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

