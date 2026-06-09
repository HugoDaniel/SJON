# 03 - Atoms and Intent

## Goal

Choose the right atomic value kind for the job: keyword, symbol, string,
boolean, number, or nil.

## Mental Model

SJON keeps value kinds distinct. A value does not forget whether you
wrote it as a string, symbol, keyword, number, boolean, or nil.

Use this authoring rule:

- **Keyword** - names a slot or acts as a flag: `:name`, `:ortho`.
- **Symbol** - names something the schema resolves: `ortho`, `mask`,
  `parent.transform`, `C#4`, `+`.
- **String** - carries opaque text: `"intro"`, `"black"`,
  `"hello.wgsl"`.
- **Boolean** - carries truth: `true`, `false`.
- **Nil** - carries explicit absence: `nil`.
- **Number** - carries numeric magnitude, optionally with a unit suffix.

Identifiers are case-sensitive. `circle`, `Circle`, and `CIRCLE` are
different heads or symbols.

Identifiers can include letters, digits after the first character,
operator characters, `_`, `-`, `.`, `/`, and a few other punctuation
characters. `#` is allowed **inside** an identifier, but not as the
first character. That makes natural sharp spellings such as `C#4` and
`F#m` valid symbols for plugins that model musical note names. A token
starting with `#` is reserved for block comments, so `#note` is not a
symbol.

## Worked Example

```sjon
(camera
  :ortho
  :projection ortho
  :zoom 2
  :label "main camera"
  :enabled true
  :debug nil)
```

Read the intent:

- `:ortho` is a positional flag.
- `:projection ortho` uses a symbol value. A schema can constrain it to
  a member set such as `ortho | perspective`.
- `:zoom 2` uses a number.
- `:label "main camera"` uses a string because this is free text.
- `:enabled true` uses a boolean.
- `:debug nil` explicitly says the slot has no value.

Do not write this when the slot expects a symbol:

```sjon
(camera :projection :ortho)
```

That does not create `projection = :ortho`. The keyword pairing rule
will treat both keywords as flags. Section 5 covers this in detail.

## Exercises

Choose the intended value kind for each slot:

1. A user-visible title: `"intro"` or `intro`?
2. A closed projection mode: `"ortho"`, `ortho`, or `:ortho`?
3. A boolean toggle: `"false"` or `false`?
4. An absent optional value: `"nil"` or `nil`?
5. A form flag with no payload: `:ortho` or `ortho`?

Repair each broken example:

```sjon
(scene :name intro)
```

If `:name` is free-form text, repair with a string:

```sjon
(scene :name "intro")
```

```sjon
(camera :projection "ortho")
```

If `:projection` is a symbol member set, repair with a symbol:

```sjon
(camera :projection ortho)
```

```sjon
(placeholder :enabled "false" :data "nil")
```

If the slots expect a boolean and nil, repair the atoms:

```sjon
(placeholder :enabled false :data nil)
```

## Mastery Check

- Which value kind should you use for a filename?
- Which value kind should you use for a closed enum-like option?
- Why is `:projection :ortho` not a reliable way to write an option?
- Are `:bpm` and `:BPM` the same keyword?
- Is `C#4` a valid symbol? Is `#C4`?

Next: [Numbers, Units, and Vectors](04-numbers-units-vectors.md).
