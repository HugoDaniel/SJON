# 06 - Comments and Strings

## Goal

Annotate a document so the next reader knows why a number is what it is,
and pick the right string surface for a text payload.

## The Comment Is Half the Reason You Are Here

Our camera has been carrying `:zoom 2` since
[Orientation](01-orientation.md), and nowhere in this document does it say
why 2. That is the gap JSON cannot close, and closing it costs one
character:

```sjon
(camera :ortho
  ; 2 keeps the whole 1920-wide plate on screen at 960 logical units.
  :zoom 2)
```

SJON has three comment spellings:

```sjon
; line comment, runs to the end of the line
;; conventionally a section heading
#| block comment, may span lines |#
```

Block comments **do not nest**. The first `|#` closes the outermost
`#|`, and there is no counter in the lexer to make it do otherwise. If
you want to comment out a region that already contains a block comment,
put several `#| … |#` blocks back to back, or use line comments.

## Where a Comment Goes and How Long It Survives

A comment is a real lexical token, not skipped whitespace. The parser
attaches each one to the nearest following structural node as **leading
trivia**, and when there is no following node in the surrounding
container it attaches instead as **trailing trivia** on the container
itself.

```
; 2 keeps the whole plate on screen.       <- leading trivia of `:zoom 2`
:zoom 2

(camera :ortho :zoom 2
  ; nothing follows me                     <- trailing trivia of (camera …)
)
```

Whether that comment reaches the other end depends on which mode the
tool is in, and this is worth learning once rather than being surprised
by later:

```
                        comments survive?
lossless print                  yes
binary IR, comment flags set    yes
structural edit outside the
  affected subtree              yes
canonical print                 no
canonical JSON                  no
stripped binary                 no
```

The rule behind the table is that canonical modes exist to make two
documents with the same meaning produce the same bytes, and a comment is
not meaning. When you need the comment to survive, you ask for the
lossless mode by name.

## Two Ways to Write Text

```sjon
"escaped\nstring"
"""raw string"""
```

Both produce a string value, and the difference is only in what the
lexer does to the bytes between the quotes. An escaped string processes
`\n`, `\t`, `\"` and the rest. A raw string does not process anything:
what is between the delimiters is the value, byte for byte, so a `\n` in
a raw string stays a backslash followed by an `n`.

Use escaped strings for ordinary text. Use raw strings when escaping
would bury the payload, which in practice means shader source, regular
expressions, Windows paths, and snippets of markup.

## Worked Example

From
[`../../examples/wgsl-shader.sjon`](../../examples/wgsl-shader.sjon):

```sjon title="examples/wgsl-shader.sjon"
(shader-module :name "hello-triangle"
  :source """@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(
    vec2(0.0, 0.5),
    vec2(-0.5, -0.5),
    vec2(0.5, -0.5),
  );
  return vec4f(pos[i], 0.0, 1.0);
}
""")
```

Count the bytes at the start. The opening `"""` is immediately followed
by `@vertex`, so the first byte of the string body is `@`. Compare with
this, where the opener sits alone on its line:

```sjon
:source """
@vertex
fn vs() -> @builtin(position) vec4f {
  return vec4f(0.0);
}
"""
```

Here the first byte of the body is a newline. Neither version is wrong,
and a shader compiler will not care, but something else might, and the
difference is invisible unless you go looking. Decide which one you want
and be consistent.

Raw strings cannot contain three consecutive double quotes, because that
sequence is what closes them. There is no escape hatch inside a raw
string, by design: adding one would mean the contents were not raw after
all. When the payload contains `"""`, use an escaped string.

## Exercises

Write:

1. A line comment above a non-obvious numeric value, saying why that
   number and not a different one.
2. A `;;` section heading inside a long form.
3. A raw string holding two lines of WGSL.
4. An escaped string holding a quote and a newline.

Predict what the first byte of this string body is:

```sjon
:source """
fn main() {}
"""
```

A newline. If you did not want it, close up the opener:

```sjon
:source """fn main() {}
"""
```

Repair this raw string:

```sjon del={1}
(snippet :source """the delimiter is """ here""")
```

The string ends at the second `"""`, and everything after it is a parse
error. The payload contains the delimiter, so this is exactly the case
raw strings cannot serve:

```sjon ins={1}
(snippet :source "the delimiter is \"\"\" here")
```

## Mastery Check

- When should you prefer raw strings?
- Does raw string content process `\n` escapes?
- What happens if the raw string opener is alone on a line?
- Can block comments nest?

Next: [Safe Expressions](07-safe-expressions.md).
