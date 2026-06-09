# 01 - Orientation

## Goal

See SJON as a readable tree of symbolic data, with optional safe
expressions in value positions.

By the end, you should be able to point at a small file and name its
roots, forms, kvpairs, vectors, atoms, and expression-shaped values.

## Mental Model

A SJON document is a flat list of **roots**. Most authored files use one
root form:

```sjon
(scene :bpm 130)
```

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

This cannot be a valid top-level kvpair because kvpairs only live inside
forms. Repair it by wrapping it in a form:

```sjon
(scene :bpm 130)
```

## Mastery Check

- Can a document have more than one root?
- Does a `.sjon` file import plugins?
- Is `(* 2 4)` always evaluated just because it looks like arithmetic?
- Where can a kvpair appear?

Next: [First Document](02-first-document.md).
