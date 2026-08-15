---
type: lesson
title: 'Reading Plugin Schemas'
---

## Mental Model

A plugin tells the host what forms and expression functions exist. As an
author, you only need the author-facing shape:

- **Form name** - the head you write: `(circle ...)`.
- **Keys** - the `:key value` slots the form accepts.
- **Required or optional** - whether omission is allowed.
- **Default** - a literal value, or an expression form like `(pi)` /
  `(* 2 16)`, that the host materializes when the key is omitted.
  Expression defaults are type-checked at schema-build against the
  key's type and can still fail at materialization time.
- **Value type** - what kind of value each key expects.
- **Positional policy** - whether nested positional children are allowed.
- **Open form** - whether unknown keys are accepted.
- **Lowering metadata** - whether a host-owned hook must lower the form
  before final validation.

Ordinary `.sjon` files do not import plugins. The host loads the plugin
set; you write source that matches it.

## Worked Example

The [`../../examples/plugins/README.md`](../../examples/plugins/README.md)
file describes the reference `shapes` plugin. Its scene example lives in
[`../../examples/plugins/shapes-scene.sjon`](../../examples/plugins/shapes-scene.sjon).

Author-facing summary:

```text
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

The reference plugin keeps these keys optional so small examples can be
written incrementally. Other plugin docs may mark keys required; when
they do, omission is a validation error unless the key declares a
default. A default makes the key effectively optional for validation,
but you should still read what the default means before relying on it.
The table is still enough to author meaningful source:

```sjon
(scene :title "demo" :author "ada"
  (canvas :w 320 :h 240 :bg "black"
    (circle :center [160 120] :radius 32)
    (group :name "border"
      (rect :origin [0 0] :size [320 4]))))
```

Because `scene` is open, `:author "ada"` can be accepted as ad-hoc
metadata. Because `circle` has positional `none`, a stray child under
`circle` should be rejected.

Open forms are not "anything goes" forms. Openness treats a form as an
extensible bag: unknown keys are accepted, missing-required-key checks
are skipped, and closed-shape sweeps such as `positional: none`,
discriminants, and exclusive groups do not run. Declared key types,
duplicate keys, and typed positional children still matter.

## Exercises

Write one valid form for each shape:

```sjon
(canvas :w 320 :h 240 :bg "black")
(circle :center [160 120] :radius 32)
(rect :origin [0 0] :size [320 4])
(group :name "ui")
(scene :title "demo")
(badge :label "dot" :shape (circle :center [0 0] :radius 1))
```

Now nest the forms according to positional policy:

```sjon
(scene :title "demo"
  (canvas :w 320 :h 240 :bg "black"
    (group :name "marks"
      (circle :center [160 120] :radius 32)
      (rect :origin [0 0] :size [320 4]))))
```

Repair positional misuse:

```sjon
(circle :center [160 120] :radius 32
  (rect :origin [0 0] :size [10 10]))
```

If `circle` accepts no positional children, move the peer forms under a
container:

```sjon
(group :name "marks"
  (circle :center [160 120] :radius 32)
  (rect :origin [0 0] :size [10 10]))
```

Repair unknown key:

```sjon
(canvas :width 320 :height 240)
```

Use the schema's declared key names:

```sjon
(canvas :w 320 :h 240)
```

Required-key reading drill:

```text
(render-target ...)
  :w length required
  :h length required
  :bg string optional
```

This source is missing a required key:

```sjon
(render-target :w 320 :bg "black")
```

Repair by adding `:h`:

```sjon
(render-target :w 320 :h 240 :bg "black")
```

Default reading drill:

```text
(render-target ...)
  :w length required
  :h length required
  :bg string default "black"
```

This source can validate because `:bg` has a default:

```sjon
(render-target :w 320 :h 240)
```

Defaults can be literals (`60`, `"red"`, `[0 0]`) or expression forms
(`(pi)`, `(* 2 16)`, `(vec3 0 0 0)`). The validator checks that an
expression default's declared `:result` is compatible with the key's
`:type` at schema-build; opaque heads like `(let …)` defer to runtime.

Three vocabulary words you need before reading a schema:

- **Author value** — the kvpair the document explicitly writes.
- **Default value** — the fallback the schema declares on the key.
- **Effective value** — the author value if present, otherwise the
  materialized default.

The host never rewrites the document to insert defaults. The author
tree stays as you wrote it; the host computes effective values in a
side-table overlay alongside the validation result. When you read a
form, you walk the tree for author input and ask the overlay for the
effective value of any omitted defaulted key. Two consequences worth
internalising:

- Writing `:bg "navy"` always wins over the schema's `:default
  "black"`, even if `"navy"` later fails a type check. The schema's
  default never silently overrides an explicit author choice.
- An expression default can succeed at schema-build (its declared
  `:result` matches the key's `:type`) and still fail at
  materialization time — for example, `(nope)` declared with
  `:result number` but no `:impl` clears the static check and then
  emits `default_eval_failed` when the host tries to evaluate it.
  Read the diagnostics, not just the schema, before assuming an
  omitted key has a usable effective value.

Effective values also participate in production validation. A defaulted
name can be indexed as a cross-reference target; a defaulted reference
slot is checked like an authored reference; a defaulted discriminant can
select a variant; and a defaulted exclusive-group alternative can
satisfy the group when no sibling alternative was explicitly written.
The important author rule stays simple: explicit values win. If you
write one exclusive-group alternative, a sibling's default does not
silently fight it.

Some schemas also declare lowering metadata for surface forms. Lowering
is host-owned: the manifest names a hook contract, but does not contain
rewrite code. When a host runs a lowering hook, that hook reads the same
effective view you do — author values first, then materialized
defaults — and the final lowered forms are validated like normal data.

## Section 7 — Exporting schemas for external tools

Reading a schema is one thing; handing it to a tool that doesn't speak
SJON is another. `sjon export-schema` converts a fully-resolved schema
into JSON Schema 2020-12 + TypeScript `.d.ts` describing the canonical
JSON shape of `sjon to-json` output. A one-liner:

```
sjon export-schema mydoc.sjon --target=both --output=./gen
```

Produces:

- `./gen/schema.json` — feed into Ajv 2020 / `python-jsonschema` to
  validate `sjon to-json --canonical` output without involving the
  SJON validator.
- `./gen/types.d.ts` — import into a TypeScript project that reads
  SJON-as-JSON to get autocomplete and basic structural checking.

The exporter is **lossy** on constraints JSON Schema can't enforce
(cross-references, expression evaluation, source-order rules,
multi-key exclusive bundles). Every loss is recorded as an
`x-sjon-export-warnings` entry at the top of the schema and as a
matching `// WARNING:` header in the `.d.ts`. Discriminated forms
become `allOf` of `if/then` chains; head-sets become `oneOf` of
`$ref`s; exclusive groups become `oneOf`/`not:{allOf}`. See
[`docs/SCHEMA_EXPORT.md`](../SCHEMA_EXPORT.md) for the full mapping
table, lossiness budget, and worked examples for the `kit`, `audio`,
`enum-rich`, and `kit-xor` fixtures.

You can call the exporter from a host too — useful when your tooling
pipeline already lives in Node, Rust, or a TypeScript codebase:

- **Node** (`hosts/web/SjonHost.exportSchema`) — wraps the WASM
  export; returns a parsed envelope with `aggregated.jsonSchema` /
  `tsTypes` / `intermediate` as strings.
- **Rust** (`sjon_host::SjonHost::export_schema`) — wasmtime-backed
  binding; same envelope, serde-deserialized into
  `ExportSchemaResult` with typed `ExportTarget` /
  `ExportLayoutOption` knobs.
- **TypeScript-parity** (`hosts/typescript-parity/src/Host.exportSchema`)
  — native TS port, no WASM. Same input shape, structurally
  equivalent output.

See [`docs/SCHEMA_EXPORT.md` § Calling the
exporter](../SCHEMA_EXPORT.md#calling-the-exporter) for working code
samples per host.

<section class="mastery-quiz" data-lesson="reading-plugin-schemas">
  <h2>Mastery Check</h2>
  <ol class="mc-list">
    <li class="mc-item" data-correct="1">
      <p class="mc-q">What does <code>positional: none</code> mean for authors?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-reading-plugin-schemas-0" value="0" /> <span>The form takes no kvpair children.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-reading-plugin-schemas-0" value="1" /> <span>The form does not accept positional (non-key) children — only <code>:key value</code> pairs.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-reading-plugin-schemas-0" value="2" /> <span>The form must be empty.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">Does <code>open: true</code> silence duplicate-key or type errors?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-reading-plugin-schemas-1" value="0" /> <span>No — <code>open: true</code> only allows unknown keys; declared keys still enforce types and duplicate rules.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-reading-plugin-schemas-1" value="1" /> <span>Yes — open forms accept anything.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-reading-plugin-schemas-1" value="2" /> <span>Only on discriminated forms.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="2">
      <p class="mc-q">Does a <code>.sjon</code> file itself choose the plugin set?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-reading-plugin-schemas-2" value="0" /> <span>Yes — the file imports plugins explicitly.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-reading-plugin-schemas-2" value="1" /> <span>Only when a <code>(plugins ...)</code> form is present.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-reading-plugin-schemas-2" value="2" /> <span>No — the host loads plugins; the file just uses their vocabulary.</span></label>
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
