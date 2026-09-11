# 09 - Reading Plugin Schemas

## Goal

Read a plugin's author-facing documentation and know, before you write a
line, which heads exist, which keys they take, which are required, what
happens when you leave one out, and where a positional child is allowed.

## The Schema Is the Other Half of the Language

[Orientation](01-orientation.md) through
[Bindings and control flow](08-bindings-and-control-flow.md) covered
everything SJON knows on its own, and you may have noticed how little
that is. It knows
`(camera :ortho :zoom 2)` is a form with a flag and a kvpair. It does
not know that a camera has a zoom, that the zoom is a number, that two
is a sensible one, or that there is any such thing as a camera.

All of that lives in a **plugin**, and the plugin is where the second
half of the language is written. When the validator tells you `:zom` is
not a key on `camera`, it is quoting the plugin. So learning to read one
is not optional extra credit: it is how you find out what you are
allowed to write, and it is how you understand the diagnostic when you
write something else.

You do not load a plugin. [Orientation](01-orientation.md) said that and
it still holds: the host loads the set, and you write source that
matches it.

## What You Need Off a Schema

Eight things, and a plugin's docs should give you all eight:

- **Form name**: the head you write, as in `(circle …)`.
- **Keys**: the `:key value` slots the form accepts.
- **Required or optional**: whether leaving it out is an error.
- **Default**: the value the host materialises when you omit the key.
  It can be a literal, or an expression form such as `(pi)` or
  `(* 2 16)`.
- **Value type**: what kind of value each key expects, which is where
  [Atoms and intent](03-atoms-and-intent.md)'s choice between symbol and string
  finally gets decided for you.
- **Positional policy**: whether nested positional children are allowed.
- **Open form**: whether unknown keys are accepted.
- **Lowering metadata**: whether a host-owned hook rewrites the form
  before final validation.

## Worked Example

[`../../examples/plugins/README.md`](../../examples/plugins/README.md)
documents the reference `shapes` plugin, and its scene lives in
[`../../examples/plugins/shapes-scene.sjon`](../../examples/plugins/shapes-scene.sjon).
Here is the whole vocabulary in the summary shape I will use for the
rest of this course:

```text title="plugin summary"
(canvas ...)
  :w length optional
  :h length optional
  :bg string optional
  positional: any

(circle ...)
  :center point optional
  :radius length optional
  :fill fill-rule optional
  positional: none

(rect ...)
  :origin point optional
  :size vector optional
  positional: none

(group ...)
  :name string optional
  positional: any

(scene ...)
  :title string optional
  positional: any
  open: true

(badge ...)
  :label string optional
  :shape shape-form optional
  positional: none
```

Every key in the reference plugin is optional, which is a teaching
choice rather than a normal one: it lets a small example be written a
piece at a time. Real plugins mark keys required, and then leaving one
out is a validation error unless the key declares a default.

That table is already enough to author against:

```sjon
(scene :title "demo" :author "ada"
  (canvas :w 320 :h 240 :bg "black"
    (circle :center [160 120] :radius 32)
    (group :name "border"
      (rect :origin [0 0] :size [320 4]))))
```

Two lines of that document are only legal because of what the table
says. `:author "ada"` survives because `scene` is **open**. And nothing
may be nested under `circle`, because `circle` says `positional: none`.

## What "Open" Actually Relaxes

An open form is not an anything-goes form, and the difference matters
because openness is the one switch that turns checks off. It treats the
form as an extensible bag:

```
open: true turns OFF          open: true leaves ON
  unknown-key errors            declared key types
  missing-required-key checks   duplicate keys
  positional: none sweeps       typed positional children
  discriminant selection
  exclusive-group checks
```

So `(scene :title 42)` is still wrong on an open `scene`, because
`:title` is declared as a string and declared types always apply. The
right way to read `open: true` is "this form accepts keys I have not
heard of", not "this form accepts anything".

## Author, Default, Effective

Three words you need before the next drill, because plugin docs use them
without defining them:

- **Author value**: the kvpair the document actually writes.
- **Default value**: the fallback the schema declares on the key.
- **Effective value**: the author value if there is one, otherwise the
  materialised default.

The mechanism is worth a picture, because the obvious guess about it is
wrong. Defaults are *not* spliced into your document:

```
your document (unchanged)          the overlay (computed alongside)

(render-target :w 320 :h 240)      w  -> 320   authored
                                   h  -> 240   authored
                                   bg -> "black"  from :default
```

The host never rewrites the tree. It computes an effective view in a
side table next to the validation result, so when you read a form back
you walk the tree for what the author wrote and ask the overlay for
anything omitted. Two consequences fall straight out of that split:

- **Explicit values always win.** Writing `:bg "navy"` beats the
  schema's `:default "black"` even when `"navy"` goes on to fail a type
  check. A default never quietly overrides a choice you made.
- **A default can pass schema-build and still fail later.** The
  validator checks an expression default's declared `:result` against
  the key's `:type` when the schema is built, but a head such as
  `(nope)` declaring `:result number` with no implementation clears that
  static check and then emits `default_eval_failed` when the host tries
  to evaluate it. Read the diagnostics rather than assuming an omitted
  key has a usable value.

Effective values are not second-class once computed. A defaulted name
can be indexed as a cross-reference target, a defaulted reference slot
is checked like an authored one, a defaulted discriminant can select a
variant, and a defaulted alternative can satisfy an exclusive group when
no sibling was written.
[Discriminated and exclusive forms](10-discriminated-and-exclusive-forms.md)
and [Cross-references](13-cross-references.md) are where those three
words turn up again.
The author rule stays the one above: explicit wins, so writing one
alternative of an exclusive group is never quietly contradicted by a
sibling's default.

Two edges of the overlay are worth fixing in your head now, because
both are easy to guess wrong. It reaches *into* the keys of a
discriminated form's active variant, and it reaches them even when the
discriminant itself was defaulted; the worked case is in
[Discriminated and exclusive forms](10-discriminated-and-exclusive-forms.md).
It does *not* reach into an opaque slot, a key the schema declares as
typed but unread: nothing in there is defaulted, checked, or registered,
and [Value kinds: refinements](12-value-kinds-refinements.md) says why
a schema would want that.

Some schemas also carry **lowering metadata** for surface forms.
Lowering is host-owned: the manifest names a hook contract, it does not
contain rewrite code. A hook reads the same effective view you do,
author values first and materialised defaults after, and the forms it
produces are validated like any other data.

## Exercises

Write one valid form for each head in the table:

```sjon
(canvas :w 320 :h 240 :bg "black")
(circle :center [160 120] :radius 32)
(rect :origin [0 0] :size [320 4])
(group :name "ui")
(scene :title "demo")
(badge :label "dot" :shape (circle :center [0 0] :radius 1))
```

Now nest them, obeying the positional column:

```sjon
(scene :title "demo"
  (canvas :w 320 :h 240 :bg "black"
    (group :name "marks"
      (circle :center [160 120] :radius 32)
      (rect :origin [0 0] :size [320 4]))))
```

Repair the positional misuse:

```sjon
(circle :center [160 120] :radius 32
  (rect :origin [0 0] :size [10 10]))
```

`circle` takes no positional children, so the rect is not a child of the
circle, it is a peer. Give the two of them a container that accepts
children:

```sjon
(group :name "marks"
  (circle :center [160 120] :radius 32)
  (rect :origin [0 0] :size [10 10]))
```

Repair the unknown key:

```sjon del={1}
(canvas :width 320 :height 240)
```

The table says `:w` and `:h`. Guessing longer names is exactly the
mistake the schema exists to catch:

```sjon ins={1}
(canvas :w 320 :h 240)
```

Required-key reading drill. Take our running camera, and read this as if
a plugin's docs handed it to you:

```text title="plugin summary"
(camera ...)
  :zoom number required
  :near length required
  :far  length default 1000
  positional: none
```

This source is missing a required key:

```sjon del={1}
(camera :zoom 2 :far 500)
```

`:near` is required and has no default, so add it:

```sjon ins={1}
(camera :zoom 2 :near 0.1 :far 500)
```

And this one validates even though it names only two of the three keys:

```sjon
(camera :zoom 2 :near 0.1)
```

`:far` is omitted, has a default, and so has an effective value of
`1000` that never appears in the file. Anything reading this camera
sees a far plane; anything reading the *document* sees two keys. That is
the overlay from the diagram above, and it is the single most useful
thing to hold onto from this lesson.

## Exporting a Schema for Tools That Do Not Speak SJON

Reading a schema is one job; handing it to a tool that has never heard
of SJON is another. `sjon export-schema` turns a fully-resolved schema
into JSON Schema 2020-12 plus a TypeScript `.d.ts`, both describing the
canonical JSON shape that `sjon to-json` produces:

```sh
sjon export-schema mydoc.sjon --target=both --output=./gen
```

- `./gen/schema.json` goes into Ajv 2020 or `python-jsonschema`, and
  validates `sjon to-json --canonical` output without the SJON validator
  being involved at all.
- `./gen/types.d.ts` goes into a TypeScript project that reads
  SJON-as-JSON, for autocomplete and structural checking.

The exporter is **lossy**, and deliberately so, because JSON Schema
cannot express cross-references, expression evaluation, source-order
rules, or multi-key exclusive bundles. Every loss is recorded rather
than hidden: an `x-sjon-export-warnings` entry at the top of the schema,
and a matching `// WARNING:` header in the `.d.ts`. What does survive
gets translated: discriminated forms become an `allOf` of `if/then`
chains, head-sets become a `oneOf` of `$ref`s (plus, when a head
declares a positional count, one `contains` / `minContains` /
`maxContains` entry per bounded head in the `$children` array's
`allOf`), and exclusive groups become `oneOf` and `not:{allOf}`.
[`docs/SCHEMA_EXPORT.md`](../SCHEMA_EXPORT.md) has the full mapping
table, the lossiness budget, and worked examples for the `kit`, `audio`,
`enum-rich`, and `kit-xor` fixtures.

The exporter is callable from a host too, which is what you want when
the pipeline already lives somewhere else:

- **Node**, `hosts/web/SjonHost.exportSchema`, wraps the WASM export and
  returns a parsed envelope with `aggregated.jsonSchema`, `tsTypes`, and
  `intermediate` as strings.
- **Rust**, `sjon_host::SjonHost::export_schema`, is wasmtime-backed and
  gives the same envelope serde-deserialized into `ExportSchemaResult`,
  with typed `ExportTarget` and `ExportLayoutOption` knobs.
- **TypeScript-parity**, `hosts/typescript-parity/src/Host.exportSchema`,
  is a native TS port with no WASM, same input shape and structurally
  equivalent output.

[`docs/SCHEMA_EXPORT.md` § Calling the
exporter](../SCHEMA_EXPORT.md#calling-the-exporter) has working code per
host.

## Mastery Check

- What does `positional: none` mean for authors?
- Why can `scene` accept `:author` in the shapes example?
- Does `open: true` silence duplicate-key or type errors?
- Where do you look to know whether `:bg` should be a string or symbol?
- How does a default affect a missing required key?
- Which validation decisions can see a materialized default?
- Does a `.sjon` file itself choose the plugin set?

Next: [Discriminated and Exclusive Forms](10-discriminated-and-exclusive-forms.md).
