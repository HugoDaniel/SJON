# SJON Author Tutorial

This is the slow path through SJON authoring. It takes the material in
[`AUTHORING.md`](../AUTHORING.md) and spreads it over fifteen lessons
with worked examples, prediction prompts, repair drills, and a check at
the end of each one.

What I want you to be able to do at the end is write a `.sjon` file by
hand and know what it will do before anything reads it: predict the
parse, choose value kinds on purpose, use expressions without turning
the document into a program, read a plugin's schema the way its author
intended, and repair a diagnostic without guessing.

I use one running example the whole way. It starts in
[Orientation](01-orientation.md) as this:

```sjon
(camera :ortho :zoom 2)
```

and by the end it is carrying units, comments, an expression, a schema,
a variant, and a cross-reference. Every new piece of machinery gets
pointed at the same camera, so you accumulate one mental model instead
of fifteen unrelated ones.

## How to Use It

Each lesson follows the same frame:

- **Goal**: what you should be able to do afterwards.
- **The rule**, motivated before it is stated.
- **Worked example**: a small piece of SJON, read closely.
- **Exercises**: write, predict, break, repair.
- **Mastery Check**: questions that should feel mechanical once the
  lesson has landed. If one makes you think hard, reread the lesson
  rather than moving on.

Do them in order. SJON has a small surface, but the rules interact:
keyword pairing changes what the validator sees, value kinds change what
a schema can check for you, and an expression is still just a form until
a schema says otherwise. [Orientation](01-orientation.md) through
[Bindings and control flow](08-bindings-and-control-flow.md) are the
language. [Reading plugin schemas](09-reading-plugin-schemas.md)
through [Style, portability, capstone](15-style-portability-and-capstone.md)
are what a schema does with it.

## Course Map

1. [Orientation](01-orientation.md) - symbolic data plus safe expressions.
2. [First Document](02-first-document.md) - roots, forms, nesting, and order.
3. [Atoms and Intent](03-atoms-and-intent.md) - value kinds, identifiers, and choosing the right surface form.
4. [Numbers, Units, and Vectors](04-numbers-units-vectors.md) - numeric payloads and structured values.
5. [Forms and Keyword Pairing](05-forms-and-keyword-pairing.md) - kvpairs, flags, and the main gotcha.
6. [Comments and Strings](06-comments-and-strings.md) - comments, escaped strings, and raw strings.
7. [Safe Expressions](07-safe-expressions.md) - expression position, typed diagnostics, and core vocabulary.
8. [Bindings and Control Flow](08-bindings-and-control-flow.md) - `let`, `if`, `cond`, and host bindings.
9. [Reading Plugin Schemas](09-reading-plugin-schemas.md) - author-facing schema literacy: keys, required/optional, defaults, positional policy, open forms, lowering metadata, and exporting schemas.
10. [Discriminated and Exclusive Forms](10-discriminated-and-exclusive-forms.md) - one head with variant shapes and their defaults; exclusive groups (`exactly-one` / `at-most-one`); multi-key bundles.
11. [Value Kinds: Shapes, Vectors, Units, Bounds, Representation](11-value-kinds-shapes.md) - underlying shapes, vector shapes, unit shapes, numeric bounds, representation.
12. [Value Kinds: Strings, Members, Heads, Unions, Slot-Local Forms](12-value-kinds-refinements.md) - string bounds, member sets, head sets, unions, slot-local forms, opaque slots, and the diagnostic cheat sheet.
13. [Cross-References](13-cross-references.md) - document-discovered name resolution between forms.
14. [Diagnostics-Driven Repair](14-diagnostics-driven-repair.md) - using stable diagnostic codes as a repair workflow.
15. [Style, Portability, and Capstone](15-style-portability-and-capstone.md) - durable authoring habits.

## Files to Keep Open

- [`../AUTHORING.md`](../AUTHORING.md) - the compact author handbook this course expands.
- [`../LANGUAGE.md`](../LANGUAGE.md) - the formal reference, for when you want the exact rule.
- [`../../examples/basic.sjon`](../../examples/basic.sjon) - a pure data scene.
- [`../../examples/with-expressions.sjon`](../../examples/with-expressions.sjon) - the core expression vocabulary.
- [`../../examples/wgsl-shader.sjon`](../../examples/wgsl-shader.sjon) - raw string payloads.
- [`../../examples/plugins/shapes-scene.sjon`](../../examples/plugins/shapes-scene.sjon) - the reference plugin scene.
- [`../../examples/plugins/README.md`](../../examples/plugins/README.md) - author-readable notes on the shape schema.

## What This Course Leaves Out

This is for people writing `.sjon` source, so it stays out of parser
internals, plugin implementation, host APIs, JSON encoding, binary IR,
structural editing, and the conformance harness. Those are real topics
and they are separate tracks. If you came here to embed SJON in a tool
rather than to write documents with it, read `AUTHORING.md` and
`docs/DESIGN.md` instead.
