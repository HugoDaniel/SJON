# 01 - Orientation

## Goal

Look at a small SJON file and name every part of it: the roots, the
forms, the kvpairs, the vectors, the atoms, and the values that only
look like arithmetic.

## Why I Wrote a Data Language

Config files start simple and then they stop being simple. You begin
with JSON, and within a month you want a comment saying why the timeout
is 250 and not 200. JSON has no comments. You want `250ms` to stay a
duration instead of collapsing into a bare `250` that some later reader
has to guess the unit for. JSON has no units. You want the file to say
`ortho` and have something tell the author when they type `orhto`. JSON
has strings, and a string is anything.

So the tool grows a little language of its own, and that little language
then needs a lexer, a parser, a formatter, error messages with line and
column numbers, and a way to hand the result to the rest of the program.
That is a lot of machinery, and every domain tool ends up writing its
own copy of it.

SJON is that machinery written once. You get a file a person can read
and annotate, a schema in which your application states exactly what it
accepts, and diagnostics precise enough to underline the typo.

What you do not get is a programming language. There are no imports, no
I/O, no mutation, no recursion, and no way for a document to reach out
and touch the world. Reading a SJON file costs what reading data costs.
That claim gets tested in [Safe expressions](07-safe-expressions.md), where we
put arithmetic inside a document, and I have to show you why the
arithmetic doesn't break it.

## The Example We'll Keep Coming Back To

Here is the smallest thing worth reading:

```sjon
(camera :ortho :zoom 2)
```

I'm going to use this camera for the entire course. Every time a new
piece of machinery shows up, we'll point it at the same camera and see
what it says. By the time we reach
[Reading plugin schemas](09-reading-plugin-schemas.md), that one form
will be carrying units, comments, an expression, and a schema, and
you'll have watched every piece arrive.

Read it as a tree:

```
(camera :ortho :zoom 2)
 |       |      |
 |       |      +-- kvpair: key `:zoom`, value `2`
 |       +--------- positional flag: the keyword `:ortho`, standing alone
 +----------------- head: the symbol `camera`
```

The whole form is one **root**. A SJON document is a flat list of roots,
and most authored files use exactly one. The parts are:

- `(camera ...)` is a **form**: a pair of parens with a head and an
  ordered list of children.
- `camera` is the form **head**.
- `:zoom 2` is a **kvpair**: a keyword key bound to a following value.
- `:ortho` is a keyword that pairs with nothing, so it stands as a
  **positional flag**.
- `2` is an **atom**.

Notice what is missing from that list: any claim about what a camera
*is*. SJON does not know. It sees a form whose head is the symbol
`camera` and it stops there.

## Who Decides What `camera` Means

The **host application** does. That is the program embedding SJON: a
game engine, a compiler, a build tool, a synthesiser. The host loads one
or more **plugins**, each of which contributes a vocabulary of form
heads and the slots those heads accept, and then asks the validator to
check your document against that vocabulary.

The important consequence is that the document does not choose. An
ordinary `.sjon` file never imports a plugin, never names a version,
never pulls anything in. It just uses words, and the host decides in
advance which words are legal. If you have met a config format where a
file could load code, this is deliberately not that.

## The Arithmetic Trap

Expressions use the same surface as data forms, which is worth pausing
on because it looks like a trap:

```sjon
(camera :zoom (* 2 4))
```

`(* 2 4)` is a form. Its head is the symbol `*` and its children are `2`
and `4`, and that is *all* it is in source text. It becomes an
expression that evaluates to 8 only when the active schema declares `*`
to be an expression function and the host asks for that value to be
evaluated. Nothing in the file makes it happen.

I've glossed over how the schema declares that, and I'm going to keep
glossing over it until [Safe expressions](07-safe-expressions.md). Right now
the only thing to hold onto is that parens are not a call.

## Worked Example

Now the same reading on something bigger. This is
[`../../examples/basic.sjon`](../../examples/basic.sjon), which is our
camera in its natural habitat:

```sjon title="examples/basic.sjon"
(scene :bpm 130 :name "intro"
  (canvas :name "main" :size [1920 1080]
    (camera :ortho :zoom 2)
    (stack :mode overlay
      (shape :sdf :radius 0.5 :color [0.9 0.4 0.2 1.0])
      (shape :path :closed true
        :points [[0 0] [1 0] [1 1] [0 1]]))
    (placeholder :note "TODO" :enabled false :data nil)))
```

Read it as a tree and it comes apart cleanly:

```
document
  `-- (scene ...)                        <- the one root
        :bpm 130                         kvpair
        :name "intro"                    kvpair
        `-- (canvas ...)                 positional child form
              :name "main"               kvpair
              :size [1920 1080]          kvpair holding a vector
              |-- (camera :ortho :zoom 2)
              |     :ortho               <- flag
              |     :zoom 2              <- kvpair
              |-- (stack :mode overlay)
              |     |-- (shape :sdf ...)
              |     `-- (shape :path ...)
              `-- (placeholder ...)
```

Everything in that tree is one of six things:

- The document has one root, the `(scene ...)` form.
- `scene` carries two kvpairs before its child: `:bpm 130` and
  `:name "intro"`.
- `canvas`, `camera`, `stack`, `shape`, and `placeholder` are nested
  forms.
- `[1920 1080]`, `[0.9 0.4 0.2 1.0]`, and `[[0 0] [1 0] [1 1] [0 1]]`
  are vectors.
- `"intro"` and `"TODO"` are strings.
- `true`, `false`, and `nil` are reserved literal atoms.

That leaves `:ortho`, `:sdf`, and `:path`, which are positional flags,
and here is where I have to stop and admit that I have shown you
something without explaining it. Look at the camera:

```sjon
(camera :ortho :zoom 2)
```

Both children start with a colon, both are keywords, and yet I have
drawn one of them as a flag and the other as a key with a value. The
rule that decides which is which is one line long, it is the only rule
in SJON that people get wrong, and
[Forms and keyword pairing](05-forms-and-keyword-pairing.md) is where I explain it
properly. Until then, notice every place two keywords sit next to each
other, and remember that I owe you an explanation.

## Exercises

1. Open [`../../examples/basic.sjon`](../../examples/basic.sjon).
2. Count the root values, then count the forms. The two numbers are very
   different, and knowing why is most of this lesson.
3. Mark each vector and write down its likely role: a size, a colour, a
   point, or a list of points.
4. Find every string and decide whether it is a label, a note, or a
   payload.
5. Find every positional flag. Don't judge whether a schema would like
   it; just find the parse shape.

Repair drill. This is not a document:

```sjon del={1}
:bpm 130
```

A kvpair only exists inside a form, so at the top level there is nothing
for `:bpm` to be a key *of*. Give it a container:

```sjon ins={1}
(scene :bpm 130)
```

## Mastery Check

- Can a document have more than one root?
- Does a `.sjon` file import plugins?
- Is `(* 2 4)` always evaluated just because it looks like arithmetic?
- Where can a kvpair appear?

Next: [First Document](02-first-document.md).
