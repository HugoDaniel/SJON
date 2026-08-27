# 15 - Style, Portability, and Capstone

## Goal

Put all fourteen lessons into one document, and leave with habits that
make a `.sjon` file predictable to a reader before any validator has
looked at it.

## Where the Camera Ended Up

We started in [Orientation](01-orientation.md) with this:

```sjon
(camera :ortho :zoom 2)
```

Every lesson since has pointed a new piece of machinery at it. Here it
is carrying all of them at once. First the contract, in the summary
shape from [Reading plugin schemas](09-reading-plugin-schemas.md):

```text title="plugin summary"
(camera ...)
  discriminant: projection
  :name       symbol required          ; declares a name others can reference
  :projection projection required      ; member set [ortho perspective]
  :delay      duration optional
  :alpha      number optional
  variant when ortho
    :zoom     number required
  variant when perspective
    :fov      number optional, unit required deg

(shot ...)
  :through camera-name required

projection:  symbol, members ortho | perspective
duration:    number, unit required, allowed s | ms | b
camera-name: symbol, cross-reference to (camera :name ...)
```

And then the document:

```sjon
;; Two cameras and a shot that names one of them.

(camera :name wide :projection ortho
  ; 2 keeps the whole 1920-wide plate on screen at 960 logical units.
  :zoom 2
  :delay 4b)

(camera :name close :projection perspective
  :fov 60deg
  :alpha (let [phase (clamp t 0 1)]
           (lerp 1 0 phase)))

(shot :through wide)
```

Read what each line is doing, with the lesson each piece arrived in on
the right, and you have the whole course:

```
:name wide          a symbol, because it is a name something resolves    (atoms, cross-refs)
:projection ortho   a symbol, not a keyword, because of the pairing rule (atoms, pairing)
:zoom 2             legal only under the ortho variant                   (variants)
:delay 4b           a number carrying a unit the plugin required         (units, kinds)
:fov 60deg          legal only under the perspective variant             (variants)
:alpha (let …)      a bounded expression over a host-supplied `t`        (expressions, bindings)
(shot :through wide) a cross-reference resolved from the document        (cross-refs)
; and ;;            comments that survive a lossless round-trip          (comments)
```

Go back to any of them: [Atoms and intent](03-atoms-and-intent.md),
[Numbers, units, vectors](04-numbers-units-vectors.md),
[Forms and keyword pairing](05-forms-and-keyword-pairing.md),
[Comments and strings](06-comments-and-strings.md),
[Safe expressions](07-safe-expressions.md),
[Bindings and control flow](08-bindings-and-control-flow.md),
[Discriminated and exclusive forms](10-discriminated-and-exclusive-forms.md),
[Value kinds: shapes](11-value-kinds-shapes.md), and
[Cross-references](13-cross-references.md).
Nothing there is new. That is the point: fourteen lessons of rules, and
the file still reads as a file.

## What Makes a Document Predictable

The habits below are the ones I would defend in review. None of them
changes what a document *means*; all of them change how long it takes
somebody else to be sure of it.

- **Keys before positional children**, unless there is a local reason
  not to. [Your first document](02-first-document.md)'s argument holds: it keeps a
  diff to one line.
- **Symbols for schema-resolved options, strings for opaque text.** The
  spelling tells the next reader whether anything is checking this
  value.
- **Keyword flags only when they really are flags.**
  [Forms and keyword pairing](05-forms-and-keyword-pairing.md) exists because this is
  the one that goes wrong quietly.
- **Raw strings for large payloads**, escaped strings for prose.
- **Expressions small and local.** When the arithmetic stops fitting on
  a line or two, lift it into the host and pass data in.
- **Lean on a default only when the default is the value you want.** An
  omitted key means "whatever the schema says", which is fine right up
  until the schema changes.
- **Comments that explain intent, not syntax.** Nobody needs
  `; the radius`. Everybody needs `; 2 keeps the whole plate on screen`.

## Portability

One more choice, and it depends on where a document is going to be read.
A bare head is resolved against whatever plugin set the host loaded, so
it is short, readable, and dependent on that set:

```sjon
(circle :center [0 0] :radius 1)
```

A qualified head names the plugin, so it survives a host where two
plugins both declare `circle`, which is the situation that produces
`ambiguous_form`:

```sjon
(shapes/circle :center [0 0] :radius 1)
```

Use bare heads for a document that lives with one known host. Qualify
domain heads when the document travels. Either way, leave core
expression heads bare: `let`, `lerp`, and `clamp` are the substrate, not
somebody's plugin, and qualifying them buys nothing.

## Worked Example

The local-authoring version:

```sjon
(scene :title "capstone" :author "ada" :draft false
  :notes """review pass:
- border group frames the canvas
- focal mark pulses from host-supplied t
"""
  (canvas :w 320 :h 240 :bg "black"
    ;; frame
    (group :name "border"
      (rect :origin [0 0] :size [320 4])
      (rect :origin [0 236] :size [320 4]))

    ;; focal mark
    (badge :label "pulse"
      :shape (circle :center [160 120]
                     :radius (let [phase (clamp t 0 1)]
                               (lerp 12 32 phase))
                     :fill evenodd))))
```

The same document, qualified for travel:

```sjon
(shapes/scene :title "capstone" :author "ada" :draft false
  :notes """review pass:
- border group frames the canvas
- focal mark pulses from host-supplied t
"""
  (shapes/canvas :w 320 :h 240 :bg "black"
    (shapes/group :name "border"
      (shapes/rect :origin [0 0] :size [320 4])
      (shapes/rect :origin [0 236] :size [320 4]))

    (shapes/badge :label "pulse"
      :shape (shapes/circle :center [160 120]
                            :radius (let [phase (clamp t 0 1)]
                                      (lerp 12 32 phase))
                            :fill evenodd))))
```

`let`, `lerp`, and `clamp` stayed bare in both.

## Exercises

Style pass. Rewrite this so a reviewer can check it at a glance, without
changing what it means:

```sjon
(scene (canvas (circle :radius 1 :center [0 0]) :bg "black" :h 240 :w 320) :title "demo")
```

One clean answer:

```sjon
(scene :title "demo"
  (canvas :w 320 :h 240 :bg "black"
    (circle :center [0 0] :radius 1)))
```

Portability pass. Qualify the domain heads and leave the expression
heads alone:

```sjon
(scene :title "demo"
  (canvas :w (+ 300 20) :h 240
    (circle :center [160 120] :radius (clamp 32 0 64))))
```

```sjon
(shapes/scene :title "demo"
  (shapes/canvas :w (+ 300 20) :h 240
    (shapes/circle :center [160 120] :radius (clamp 32 0 64))))
```

Raw payload pass. Add a raw string to a metadata slot, and decide on
purpose whether its first byte is a newline.
[Comments and strings](06-comments-and-strings.md) has the rule; the point of the
exercise is that you now choose rather than discover.

## Capstone

Write one complete document containing all of this:

- One top-level scene-like root.
- At least three levels of nesting.
- One vector of points, or repeated point-like values.
- One string label and one raw string payload.
- One boolean or nil value.
- One safe expression using `lerp` or `clamp`.
- One `let`, `if`, or `cond`.
- One form-valued slot, such as a badge shape.
- Comments that explain intent rather than syntax.

Then break it on purpose, six times:

1. Misspell one form head.
2. Misspell one key.
3. Duplicate one key.
4. Write `:keyword` where a symbol value belongs.
5. Put a disallowed head in a head-set slot.
6. Give a typed expression function an obviously wrong literal.

For each one, name the diagnostic you expect **before** you run
anything, then run it and see whether you were right. Being wrong is the
useful outcome: it means there is a layer in the stack from
[Diagnostics-driven repair](14-diagnostics-driven-repair.md#read-the-code-not-the-sentence)
you have not internalised yet, and now you know which.

## Mastery Check

- Can you explain why every keyword in your capstone is either a key or
  a deliberate flag?
- Can you identify every symbol and say what schema or binding resolves
  it?
- Can you move from local bare heads to portable qualified heads?
- Can you break and repair your own document using diagnostic codes?

Back to the [course map](README.md).
