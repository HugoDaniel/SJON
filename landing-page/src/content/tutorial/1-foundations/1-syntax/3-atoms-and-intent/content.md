---
type: lesson
title: 'Atoms and Intent'
---

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

[Open in playground →](/playground#s=KGNhbWVyYQogIDpvcnRobwogIDpwcm9qZWN0aW9uIG9ydGhvCiAgOnpvb20gMgogIDpsYWJlbCAibWFpbiBjYW1lcmEiCiAgOmVuYWJsZWQgdHJ1ZQogIDpkZWJ1ZyBuaWwp)

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

[Open in playground →](/playground#s=KGNhbWVyYSA6cHJvamVjdGlvbiA6b3J0aG8p)

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

[Open in playground →](/playground#s=KHNjZW5lIDpuYW1lIGludHJvKQ)

If `:name` is free-form text, repair with a string:

```sjon
(scene :name "intro")
```

[Open in playground →](/playground#s=KHNjZW5lIDpuYW1lICJpbnRybyIp)

```sjon
(camera :projection "ortho")
```

[Open in playground →](/playground#s=KGNhbWVyYSA6cHJvamVjdGlvbiAib3J0aG8iKQ)

If `:projection` is a symbol member set, repair with a symbol:

```sjon
(camera :projection ortho)
```

[Open in playground →](/playground#s=KGNhbWVyYSA6cHJvamVjdGlvbiBvcnRobyk)

```sjon
(placeholder :enabled "false" :data "nil")
```

[Open in playground →](/playground#s=KHBsYWNlaG9sZGVyIDplbmFibGVkICJmYWxzZSIgOmRhdGEgIm5pbCIp)

If the slots expect a boolean and nil, repair the atoms:

```sjon
(placeholder :enabled false :data nil)
```

[Open in playground →](/playground#s=KHBsYWNlaG9sZGVyIDplbmFibGVkIGZhbHNlIDpkYXRhIG5pbCk)

<section class="mastery-quiz" data-lesson="atoms-and-intent">
  <h2>Mastery Check</h2>
  <ol class="mc-list">
    <li class="mc-item" data-correct="2">
      <p class="mc-q">Which value kind should you use for a filename?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-atoms-and-intent-0" value="0" /> <span>A symbol like <code>intro.sjon</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-atoms-and-intent-0" value="1" /> <span>A keyword like <code>:intro.sjon</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-atoms-and-intent-0" value="2" /> <span>A string like <code>&quot;intro.sjon&quot;</code>.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="2">
      <p class="mc-q">Which value kind should you use for a closed enum-like option?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-atoms-and-intent-1" value="0" /> <span>A keyword like <code>:overlay</code>.</span></label>
        <p class="mc-explanation" hidden>Keywords are slot labels or flags, never kvpair values. <code>:projection :overlay</code> parses as two adjacent positional flags, not <code>projection = :overlay</code>.</p>
      </li>
      <li>
        <label><input type="radio" name="q-atoms-and-intent-1" value="1" /> <span>A string like <code>&quot;overlay&quot;</code>.</span></label>
        <p class="mc-explanation" hidden>A string would work, but it tells the schema &quot;free-form text,&quot; not &quot;one of a closed set.&quot; Use strings for opaque labels, not enum members.</p>
      </li>
      <li>
        <label><input type="radio" name="q-atoms-and-intent-1" value="2" /> <span>A symbol like <code>overlay</code>.</span></label>
        <p class="mc-explanation" hidden>Symbols carry author intent for <em>named choices in a closed vocabulary</em> — exactly what an enum is. The schema can validate the symbol against a member set.</p>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">Why is <code>:projection :ortho</code> not a reliable way to write an option?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-atoms-and-intent-2" value="0" /> <span>Two consecutive keywords don't pair into a kvpair — <code>:ortho</code> becomes a separate flag, not the value of <code>:projection</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-atoms-and-intent-2" value="1" /> <span>SJON forbids two keywords in a row.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-atoms-and-intent-2" value="2" /> <span>It is reliable; both spellings are equivalent.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="2">
      <p class="mc-q">Are <code>:bpm</code> and <code>:BPM</code> the same keyword?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-atoms-and-intent-3" value="0" /> <span>Yes — keyword comparison is case-insensitive.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-atoms-and-intent-3" value="1" /> <span>Only if the schema says so.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-atoms-and-intent-3" value="2" /> <span>No — keywords compare byte-for-byte, so casing matters.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">Is <code>C#4</code> a valid symbol? Is <code>#C4</code>?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-atoms-and-intent-4" value="0" /> <span>Both are valid symbols.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-atoms-and-intent-4" value="1" /> <span><code>C#4</code> is a valid symbol; <code>#C4</code> is not, because symbols cannot start with <code>#</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-atoms-and-intent-4" value="2" /> <span>Neither is a valid symbol.</span></label>
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
