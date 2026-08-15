---
type: lesson
title: 'Comments and Strings'
---

## Mental Model

SJON has line comments and block comments:

```sjon
; line comment
;; section heading by convention
#| block comment |#
```

[Open in playground →](/playground#s=OyBsaW5lIGNvbW1lbnQKOzsgc2VjdGlvbiBoZWFkaW5nIGJ5IGNvbnZlbnRpb24KI3wgYmxvY2sgY29tbWVudCB8Iw)

Comments attach to nearby structure and can be preserved by lossless
printing. They are for authors and tools; canonical output may omit
them.

SJON has two string surfaces:

```sjon
"escaped\nstring"
"""raw string"""
```

[Open in playground →](/playground#s=ImVzY2FwZWRcbnN0cmluZyIKIiIicmF3IHN0cmluZyIiIg)

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

[Open in playground →](/playground#s=KHNoYWRlci1tb2R1bGUgOm5hbWUgImhlbGxvLXRyaWFuZ2xlIgogIDpzb3VyY2UgIiIiQHZlcnRleApmbiB2cyhAYnVpbHRpbih2ZXJ0ZXhfaW5kZXgpIGk6IHUzMikgLT4gQGJ1aWx0aW4ocG9zaXRpb24pIHZlYzRmIHsKICB2YXIgcG9zID0gYXJyYXk8dmVjMmYsIDM-KAogICAgdmVjMigwLjAsIDAuNSksCiAgICB2ZWMyKC0wLjUsIC0wLjUpLAogICAgdmVjMigwLjUsIC0wLjUpLAogICk7CiAgcmV0dXJuIHZlYzRmKHBvc1tpXSwgMC4wLCAxLjApOwp9CiIiIik)

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

[Open in playground →](/playground#s=OnNvdXJjZSAiIiIKQHZlcnRleApmbiB2cygpIC0-IEBidWlsdGluKHBvc2l0aW9uKSB2ZWM0ZiB7CiAgcmV0dXJuIHZlYzRmKDAuMCk7Cn0KIiIi)

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

[Open in playground →](/playground#s=OnNvdXJjZSAiIiIKZm4gbWFpbigpIHt9CiIiIg)

The string starts with a newline before `fn`.

Repair if the leading newline is unwanted:

```sjon
:source """fn main() {}
"""
```

[Open in playground →](/playground#s=OnNvdXJjZSAiIiJmbiBtYWluKCkge30KIiIi)

Repair this raw string:

```sjon
(snippet :source """the delimiter is """ here""")
```

[Open in playground →](/playground#s=KHNuaXBwZXQgOnNvdXJjZSAiIiJ0aGUgZGVsaW1pdGVyIGlzICIiIiBoZXJlIiIiKQ)

Use an escaped string instead:

```sjon
(snippet :source "the delimiter is \"\"\" here")
```

[Open in playground →](/playground#s=KHNuaXBwZXQgOnNvdXJjZSAidGhlIGRlbGltaXRlciBpcyBcIlwiXCIgaGVyZSIp)

<section class="mastery-quiz" data-lesson="comments-and-strings">
  <h2>Mastery Check</h2>
  <ol class="mc-list">
    <li class="mc-item" data-correct="1">
      <p class="mc-q">When should you prefer raw strings (<code>&quot;&quot;&quot;...&quot;&quot;&quot;</code>)?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-comments-and-strings-0" value="0" /> <span>Always — they are faster to parse.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-comments-and-strings-0" value="1" /> <span>When escaping would obscure the payload (shaders, regex, paths with backslashes, markup).</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-comments-and-strings-0" value="2" /> <span>When the string is short.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">Does raw string content process <code>\n</code> escapes?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-comments-and-strings-1" value="0" /> <span>No — raw strings keep their bytes verbatim; <code>\n</code> stays as a backslash and an <code>n</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-comments-and-strings-1" value="1" /> <span>Yes — escapes work in both surfaces.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-comments-and-strings-1" value="2" /> <span>Only inside a <code>(raw ...)</code> block.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">Can block comments nest?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-comments-and-strings-2" value="0" /> <span>No — the first <code>|#</code> always closes the outermost <code>#|</code>.</span></label>
        <p class="mc-explanation" hidden>Correct. <code>LANGUAGE.md</code> §2.2 is explicit: &quot;Block comments do not nest.&quot; The lexer treats <code>|#</code> as the closer for the <em>outermost</em> open <code>#|</code>.</p>
      </li>
      <li>
        <label><input type="radio" name="q-comments-and-strings-2" value="1" /> <span>Only if the parser is told to.</span></label>
        <p class="mc-explanation" hidden>No — the parser has no nesting mode. Block-comment lexing is fixed.</p>
      </li>
      <li>
        <label><input type="radio" name="q-comments-and-strings-2" value="2" /> <span>Yes — <code>#| ... #| inner |# ... |#</code> is allowed; comments nest properly.</span></label>
        <p class="mc-explanation" hidden>This would require a counter in the lexer; SJON keeps the lexer single-pass and labeled-switch. If you need a long comment, use multiple <code>#| ... |#</code> blocks back-to-back.</p>
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
