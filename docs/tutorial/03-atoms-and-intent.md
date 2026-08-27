# 03 - Atoms and Intent

## Goal

Pick the right atomic value kind for a slot every time: keyword, symbol,
string, boolean, number, or nil.

## Why Six Kinds and Not One

JSON gives you one way to write a word: put quotes around it. That means
`"ortho"`, `"intro.sjon"`, and `"zoom"` all arrive at your program
looking identical, and the program has to remember from context that the
first is one of a fixed set of projections, the second is a filename,
and the third is the name of a field. All the author's intent is thrown
away at the quote marks and reconstructed later by hand.

SJON keeps the distinction the author wrote. A value never forgets
whether it was spelled as a string, a symbol, a keyword, a number, a
boolean, or nil, which means the schema can hold you to it and the
diagnostic can be specific about it.

Here is our camera saying six different things in six different ways:

```sjon
(camera
  :ortho
  :projection ortho
  :zoom 2
  :label "main camera"
  :enabled true
  :debug nil)
```

Read the intent off the spelling alone:

```
:ortho              keyword, standing alone   -> a flag. Present or absent.
:projection ortho   keyword + symbol          -> a named choice from a closed set.
:zoom 2             keyword + number          -> a magnitude.
:label "main camera"  keyword + string        -> opaque text. Nobody validates it.
:enabled true       keyword + boolean         -> truth.
:debug nil          keyword + nil             -> explicitly, deliberately absent.
```

The authoring rule in one line each:

- **Keyword** names a slot or acts as a flag: `:zoom`, `:ortho`.
- **Symbol** names something the schema resolves: `ortho`, `mask`,
  `parent.transform`, `C#4`, `+`.
- **String** carries opaque text: `"intro"`, `"black"`, `"hello.wgsl"`.
- **Boolean** carries truth: `true`, `false`.
- **Nil** carries explicit absence: `nil`.
- **Number** carries magnitude, optionally with a unit suffix.

The distinction that earns its keep is symbol versus string. A symbol
says "this is a name from a vocabulary, go and check it", so a schema
can pin `:projection` to the member set `ortho | perspective` and tell
the author when they write `orhto`. A string says "this is text, leave
it alone", so nobody checks `"main camera"` and nobody should. Choosing
between them is choosing whether you want to be told when you are wrong.

## What Counts as an Identifier

Identifiers are case-sensitive. `circle`, `Circle`, and `CIRCLE` are
three different heads, and `:bpm` and `:BPM` are two different keywords.
There is no folding anywhere.

An identifier may contain letters, digits after the first character,
operator characters, `_`, `-`, `.`, `/`, and a handful of other
punctuation. `#` is allowed **inside** an identifier but never as the
first character, which is a deliberate concession to music: `C#4` and
`F#m` are perfectly good symbols, so a plugin that models note names
doesn't have to make its authors write `"C#4"` in quotes.

The reason for the restriction on the first character is that `#` there
already means something. `#|` opens a block comment, which
[Comments and strings](06-comments-and-strings.md) covers, so a token starting with
`#` can never be a symbol. `#note` is not a name; it is the start of
something the lexer reads differently.

## Worked Example

Look again at the camera above, and then at the version that goes wrong:

```sjon
(camera :projection :ortho)
```

This does **not** mean `projection = :ortho`. The parser sees two
keywords in a row and produces two positional flags, `:projection` and
`:ortho`, neither of which is a kvpair, and the form now has no
projection set at all.

I keep flagging this and keep not explaining it, and
[Forms and keyword pairing](05-forms-and-keyword-pairing.md) is where that debt gets
paid in full. For now, treat it as a hard authoring rule: **a keyword is
never the value of a kvpair.** When a slot wants a named choice, the
value goes in as a symbol.

## Exercises

Choose the value kind for each slot, and say what the choice tells a
future reader:

1. A user-visible title: `"intro"` or `intro`?
2. A closed projection mode: `"ortho"`, `ortho`, or `:ortho`?
3. A boolean toggle: `"false"` or `false`?
4. An absent optional value: `"nil"` or `nil`?
5. A form flag with no payload: `:ortho` or `ortho`?

Repair each of these. The fix is always "write the kind the slot
means", so the work is in deciding what it means:

```sjon del={1}
(scene :name intro)
```

If `:name` is free text, a symbol is a promise the schema can't keep.
Use a string:

```sjon ins={1}
(scene :name "intro")
```

```sjon del={1}
(camera :projection "ortho")
```

If `:projection` is a member set, a string opts out of the check you
wanted. Use a symbol:

```sjon ins={1}
(camera :projection ortho)
```

```sjon del={1}
(placeholder :enabled "false" :data "nil")
```

`"false"` is a five-character string, and it is truthy. `"nil"` is a
three-character string, and it is present. Both slots wanted the
literal:

```sjon ins={1}
(placeholder :enabled false :data nil)
```

## Mastery Check

- Which value kind should you use for a filename?
- Which value kind should you use for a closed enum-like option?
- Why is `:projection :ortho` not a reliable way to write an option?
- Are `:bpm` and `:BPM` the same keyword?
- Is `C#4` a valid symbol? Is `#C4`?

Next: [Numbers, Units, and Vectors](04-numbers-units-vectors.md).
