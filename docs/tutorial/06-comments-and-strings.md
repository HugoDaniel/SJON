# 06 - Comments and Strings

## Goal

Use comments for authoring intent and choose between escaped strings and
raw triple-quoted strings for text payloads.

## Mental Model

SJON has line comments and block comments:

```sjon
; line comment
;; section heading by convention
#| block comment |#
```

Comments attach to nearby structure and can be preserved by lossless
printing. They are for authors and tools; canonical output may omit
them.

SJON has two string surfaces:

```sjon
"escaped\nstring"
"""raw string"""
```

Both produce string values. Use escaped strings for normal text. Use raw
strings when escaping would obscure the payload, such as shader source,
regular expressions, paths with backslashes, or snippets of markup.

## Worked Example

From [`../../examples/wgsl-shader.sjon`](../../examples/wgsl-shader.sjon):

```sjon
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

The opening `"""` is immediately followed by `@vertex`, so the first
byte of the string body is `@`.

This version starts with a newline:

```sjon
:source """
@vertex
fn vs() -> @builtin(position) vec4f {
  return vec4f(0.0);
}
"""
```

That may be fine, but it should be intentional.

Raw strings cannot contain three consecutive double quotes, because
that sequence closes the string. If the payload contains `"""`, use an
escaped string.

## Exercises

Write:

1. A line comment above a non-obvious numeric value.
2. A `;;` section heading inside a long form.
3. A raw string containing two lines of WGSL.
4. An escaped string containing a quote and a newline.

Predict:

```sjon
:source """
fn main() {}
"""
```

The string starts with a newline before `fn`.

Repair if the leading newline is unwanted:

```sjon
:source """fn main() {}
"""
```

Repair this raw string:

```sjon
(snippet :source """the delimiter is """ here""")
```

Use an escaped string instead:

```sjon
(snippet :source "the delimiter is \"\"\" here")
```

## Mastery Check

- When should you prefer raw strings?
- Does raw string content process `\n` escapes?
- What happens if the raw string opener is alone on a line?
- Can block comments nest?

Next: [Safe Expressions](07-safe-expressions.md).

