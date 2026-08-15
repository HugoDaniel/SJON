# SJON Author Tutorial

This tutorial is the slow path through SJON authoring. It expands
[`AUTHORING.md`](../AUTHORING.md) into a course with worked examples,
prediction prompts, repair drills, and mastery checks.

The goal is author mastery: writing clear `.sjon` files by hand,
predicting how the source will be read, using safe expressions
responsibly, reading plugin documentation as an author, and repairing
validation feedback without guessing.

## How to Use This Tutorial

Each section follows the same frame:

- **Goal** - what you should be able to do after the section.
- **Mental Model** - the rule that makes the examples predictable.
- **Worked Example** - a small piece of SJON, read carefully.
- **Exercises** - write, predict, break, and repair.
- **Mastery Check** - quick questions that should feel mechanical when
  the concept has landed.

Do the exercises in order. SJON has a small surface, but several rules
interact: keyword pairing affects schema validation, value kinds affect
authoring choices, and expression forms are still forms until a schema
decides they are evaluable.

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
10. [Discriminated and Exclusive Forms](10-discriminated-and-exclusive-forms.md) - one head with variant shapes; exclusive groups (`exactly-one` / `at-most-one`); multi-key bundles.
11. [Value Kinds: Shapes, Vectors, Units, Bounds](11-value-kinds-shapes.md) - underlying shapes, vector shapes, unit shapes, numeric bounds.
12. [Value Kinds: Strings, Members, Heads, Unions](12-value-kinds-refinements.md) - string bounds, member sets, head sets, unions, and the diagnostic cheat sheet.
13. [Cross-References](13-cross-references.md) - document-discovered name resolution between forms.
14. [Diagnostics-Driven Repair](14-diagnostics-driven-repair.md) - using stable diagnostic codes as a repair workflow.
15. [Style, Portability, and Capstone](15-style-portability-and-capstone.md) - durable authoring habits.

## Repository Anchors

Use these files alongside the course:

- [`../AUTHORING.md`](../AUTHORING.md) - compact author handbook.
- [`../LANGUAGE.md`](../LANGUAGE.md) - formal language reference.
- [`../../examples/basic.sjon`](../../examples/basic.sjon) - pure data scene.
- [`../../examples/with-expressions.sjon`](../../examples/with-expressions.sjon) - core expression vocabulary.
- [`../../examples/wgsl-shader.sjon`](../../examples/wgsl-shader.sjon) - raw string payloads.
- [`../../examples/plugins/shapes-scene.sjon`](../../examples/plugins/shapes-scene.sjon) - reference plugin scene.
- [`../../examples/plugins/README.md`](../../examples/plugins/README.md) - author-readable shape schema notes.

## Out of Scope

This course is for people writing `.sjon` source. It deliberately avoids
parser internals, plugin implementation, host APIs, JSON encoding,
Binary IR, structural editing, and conformance harnesses. Those topics
matter, but they are separate learning tracks.
