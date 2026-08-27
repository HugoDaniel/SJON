# Writing SJON — author's handbook

A practical guide for people writing SJON by hand. Open this if you
have a `.sjon` file in front of you and you want to know what to type.

This document covers syntax, common patterns, the built-in
expression vocabulary, and how to read a plugin's schema. It is
deliberately silent on what happens after you save the file —
parsing, the binary wire format, the JSON bridge, structural editing,
plugin authoring. For any of those, see [`LANGUAGE.md`](LANGUAGE.md)
(the spec) or [`examples/plugins/README.md`](../examples/plugins/README.md)
(plugin-side material).

The fastest first five minutes is the REPL — a calculator that knows
your vocabulary once a project loads:

```console
$ sjon repl
sjon repl — core vocabulary only, no project loaded (try :help, :quit exits)
sjon> (+ 1 (* 2 3))
7.0
sjon> (clamp 12 0 10)
10.0
sjon> :quit
```

---

## 1. What SJON looks like

A single-form document:

```sjon
(camera :ortho :zoom 2)
```

A nested scene:

```sjon
(scene :bpm 130 :name "intro"
  (canvas :name "main" :size [1920 1080]
    (camera :ortho :zoom 2)
    (stack :mode overlay
      (shape :sdf :radius 0.5 :color [0.9 0.4 0.2 1.0])
      (shape :path :closed true
        :points [[0 0] [1 0] [1 1] [0 1]]))))
```

A configuration with a little inline math:

```sjon
(group :name "fade"
  (shape :sdf
    :radius 0.5
    :alpha (lerp 1 0 (clamp t 0 1))))
```

Three things are worth naming on a first read:

- `(head ...)` — **a form**. The first token is the constructor
  name; the rest are children.
- `:keyword value` — **a kvpair**. Forms hold properties this way.
  `:ortho` on its own (no value after it) is a positional flag.
- `[...]` — **a vector**. An ordered list of values, no keys.

The rest of this handbook elaborates those pieces one at a time.

---

## 2. The shape of a document

A SJON document is a flat list of **roots**. Most documents have
exactly one root — a single top-level form — but multiple roots
are valid:

```sjon
; Single-root: the common case.
(scene :bpm 130 (canvas :name "main"))
```

```sjon
; Multi-root: fixtures, batches, palettes.
(layer :name "background" :z 0)
(layer :name "midground"  :z 1)
(layer :name "foreground" :z 2)
```

```sjon
; Atomic root: also valid.
42
```

One narrowing rule: **a `:key value` pair cannot be a root.** Top
level holds values (forms, vectors, atoms); kvpairs only live
inside forms. Whitespace doesn't matter — newlines, tabs, and
spaces are all just separators.

> If you're shipping SJON across the wire, encoding to JSON, or
> mutating documents programmatically, those concerns are covered
> in `LANGUAGE.md` §9–§11. From here on, this document assumes
> you're typing source.

### No imports in `.sjon` files

A SJON document does not declare which plugins it uses. There is no
document-level `(import …)`, no `use`, no package stanza, and no
scene-bundling form that pulls vocabularies into the file.

Vocabulary loading is a **host concern**:

```text
host loads:      core + shapes + masagin
host validates:  my-document.sjon
```

The document itself stays vocabulary-agnostic. It contains forms like
`(scene …)`, `(circle …)`, `(shape …)`, and `(b 4)`; the host decides
which plugin set those names are checked against.

This has two practical consequences:

- The same document can validate under different host setups, as long
  as the loaded plugins provide the heads it uses.
- A bare head such as `(circle …)` works only when exactly one loaded
  plugin owns `circle`. If more than one plugin declares it, qualify
  the head: `(shapes/circle …)`.

Plugin manifests may themselves be written in SJON, but those manifests
are loaded by the host. They are not imported from ordinary `.sjon`
documents.

---

## 3. Atoms

The substrate has eleven value kinds. Most are atomic values; vectors
and forms are the two structural containers. Unit-bearing numbers are
covered separately because authors need to understand suffix rules.

| Kind | Examples | Notes |
| --- | --- | --- |
| `nil` | `nil` | The explicit "absence" value. Falsy. |
| `boolean` | `true`, `false` | The two booleans. `false` is falsy; `true` is truthy. |
| `number` | `0`, `-1.25`, `1e9`, `1.5e-10` | IEEE-754 `f64`. Underscores allowed: `1_000_000`. |
| `date` | `2026-05-19`, `0001-01-01` | Calendar `YYYY-MM-DD` (year 1..9999, no time, no zone). |
| `time` | `12:34:56`, `23:59:59.999` | Clock `HH:MM:SS[.fff]` (no date, no zone, no leap seconds). |
| `string` | `"hello"`, `"""raw bytes"""` | UTF-8 bytes. Two surface forms, one value (§9). |
| `keyword` | `:bpm`, `:ortho`, `:p+s` | A name with a leading `:`. |
| `symbol` | `bounce`, `parent.transform`, `+` | A name without a leading `:`. |

`nil` and the booleans cannot carry payload — they're atoms by
identity. `true`, `false`, and `nil` are the only reserved words;
every other identifier is fair game.

**All identifiers are case-sensitive.** `:bpm`, `:Bpm`, and
`:BPM` are three distinct keywords; `circle` and `Circle` are
two distinct heads. Plugin docs are the source of truth for the
exact spelling — match it byte-for-byte.

### Symbol vs string vs keyword — when to reach for which

Three distinct kinds, intentionally distinct:

- **A keyword** names a slot or a discrete option. Use it for
  `:mode`, `:loop`, `:enabled`, `:pos` — keys on a form, or
  flags. A keyword is **self-evaluating**: it stands for itself,
  never resolved against a binding. Keywords are first-class but
  they are not stand-ins for short labels.
- **A symbol** names something the schema knows about: a form
  head (`scene`, `circle`), a binding inside an expression (`t`,
  `radius`), or a closed-set enum value (`ortho`, `loop`,
  `mask`). A symbol is an **identifier**: it gets looked up in a
  binding scope, or matched against a member-set the plugin
  declares. Plugins frequently declare member-sets where the
  expected value is a symbol.
- **A string** is opaque payload. Reach for it when the value is
  free-form text — a label, a filename, a color name, embedded
  shader source.

The trichotomy matters because the parser keeps it. Once you've
chosen, the value remembers which kind it was, and the validator
checks against the slot's declared type accordingly.

---

## 4. Numbers and units

A number can carry a **unit suffix**: one or more ASCII letters
(hyphens may join two letter runs), or a single `%`, glued to the end
with no whitespace.

```sjon
0           1           -3                 ; numbers, no unit
0.5         -1.25       1.5e-10            ; numbers, no unit
4b          90deg       50%                ; numbers with unit
250ms       1.5e2hz                        ; numbers with unit
2d-array    5ms-per-frame                  ; hyphen-joined units
```

A hyphen only continues a unit when a **letter** follows it, so `1em-2`
is two values (`1em` and `-2`), not one number with the unit `em-2`.

Units are **opaque** to the substrate. SJON does not interpret
`b` as beats, `deg` as degrees, or `ms` as milliseconds — it
just carries the suffix forward as text. The plugin (or your
host code) decides what each suffix means. A common pattern: a
domain plugin declares an expression function `(b 4)` that
converts beats to seconds at evaluation time.

A unit-bearing number is a **distinct value** from a unitless
one — `4b` and `4` are not interchangeable. A plugin can refine a
numeric slot to require a unit, or to allow only specific suffixes.
A plain `number` slot accepts both `4` and `4b`.

### Exponent vs. unit ambiguity

`e` and `E` start an **exponent** only when the very next
character is a digit or sign. Otherwise, they start a unit:

```sjon
1e9          ; the number 1,000,000,000 (exponent)
1e+9         ; same — sign counts as starting an exponent
1em          ; the number 1, with unit "em" (no digit after `e`)
1.5e2hz      ; the number 150, with unit "hz" (exponent + unit)
1e-9ms       ; the number 1e-9, with unit "ms" (signed exponent + unit)
```

The rule is purely lexical — it doesn't depend on the schema or
the surrounding context.

### Underscores

Digit grouping is allowed:

```sjon
1_000_000              ; same as 1000000
0.000_001              ; same as 0.000001
60_000ms               ; same as 60000ms
```

Underscores are stripped before parsing.

### Write masks in hex

A `0x` prefix opens a hexadecimal integer, so a bit mask can be
written the way the spec you are transcribing writes it:

```sjon
(target :write-mask 0xFFFFFFFF :sample-mask 0xF)
```

instead of:

```sjon
(target :write-mask 4294967295 :sample-mask 15)
```

Both documents mean exactly the same thing. Case is free on the `x`
and on the digits, and `_` groups hex digits the way it groups decimal
ones:

```sjon
0xFF        0Xff        0xdeadBEEF         ; all fine
0xFFFF_FFFF                                ; = 4294967295
-0x10                                      ; = -16
```

Three things to know:

**Hex is an integer.** No fraction, no exponent, no unit. The token
ends at the first non-hex byte, so `0xFFms` is `0xFF` followed by the
symbol `ms` — not a masked value with a unit.

**`0x` alone is an error.** `0x`, `0x_F`, and `0xGG` are parse
diagnostics. Before hex literals existed `0xFF` lexed as the number
`0` carrying the unit `xFF`, so a mask typo was *silently zero* unless
the slot happened to reject units. That is the failure hex removes, and
leaving `0x` readable as zero would have kept it for the likeliest
typo.

**`sjon fmt` rewrites hex to decimal.** The formatter works from the
value and never sees your source, so `0xFFFFFFFF` comes back as
`4294967295` — the same normalization that turns `1_000` into `1000`.
If you want the hex spelling to survive in a file, keep `sjon fmt`
off it.

---

## 5. Vectors

`[a b c]` is a vector — an ordered list of any values, of any kind.

```sjon
[]                              ; empty
[1 2 3]                         ; numbers
[[0 0] [1 0] [1 1] [0 1]]       ; a polyline (vector of 2-vectors)
[:loop :ping-pong]              ; vector of keywords
["red" "green" "blue"]          ; vector of strings
[(rgb 1 0 0) (rgb 0 1 0)]       ; vector of forms
```

Vectors do **not** carry kvpairs. A `:keyword` inside `[...]`
is a value of kind `keyword`, not a key looking for a partner.
If you find yourself wanting `:k v` pairs in a list, you want a
sequence of forms (each carrying its own keys), not a vector.

Common shapes plugins ask of you:

- **2-vector of numbers** for points: `[160 120]`.
- **3-vector** for vec3 / RGB: `[0.9 0.4 0.2]`.
- **4-vector** for vec4 / RGBA / matrices-by-row:
  `[0.9 0.4 0.2 1.0]`.
- **Vector of points** for polylines / outlines:
  `[[0 0] [1 0] [1 1]]`.

When a plugin pins a slot to a typed vector ("4-vector of
numbers, RGBA"), the validator checks the length and the element
kind for you. The error you'll see is covered in §13.

---

## 6. Forms

The workhorse construct. Every domain object — scenes, shapes,
camera, animations — is a form.

```sjon
(camera                   ; head: the constructor name
  :ortho                  ; positional flag (a keyword, no value)
  :zoom 2                 ; kvpair: zoom = 2
  :pos [0 1]              ; kvpair: pos = [0 1]
  (group :name "main"))   ; positional child: a nested form
```

Forms are made of:

- A **head** — the first token after `(`. A symbol naming the
  constructor (`scene`, `canvas`, `camera`).
- Zero or more **children**, in source order, each one of:
  - A **kvpair**: `:key value`.
  - A **positional value**: any value, including nested forms.
  - A **positional flag**: a bare keyword that didn't pair with a
    value (see §7).

Source order is preserved. Plugins decide what each form
accepts: required keys, optional keys, whether positional
children are allowed, and what type each slot expects (§11).

### Bare vs qualified heads

When two plugins both declare `circle`, you disambiguate by
qualifying the head with a namespace prefix:

```sjon
(circle :center [0 0] :radius 1)         ; bare — works iff one plugin owns "circle"
(shapes/circle :center [0 0] :radius 1)  ; qualified — always works for the shapes plugin
(masagin/circle …)                       ; qualified — picks masagin's circle
```

The bare form is shorter and almost always what you want. The
validator only forces you to qualify when there's a real
collision; it tells you which plugins are competing for the name.

The same rule applies to **value-kind references** inside a manifest.
A `:type plugin/kind`, a `(vector-shape :element plugin/kind)`, a
`(positional plugin/kind)`, and a `(union-shape :alternatives
[plugin/a plugin/b])` all split on the first `/`. When two plugins
both declare a `color` value-kind, qualifying as `paint/color` picks
one definition; bare `color` becomes ambiguous and the validator
emits a diagnostic with the same "qualify with `<plugin>/<name>`"
recovery hint shown for form heads.

```sjon
; Form in plugin `host` references the paint plugin's color
; explicitly, so a sibling `display` plugin declaring `color`
; cannot collide here.
(form :name swatch
  (key :name hue :type paint/color :optional false))
```

---

## 7. The keyword pairing rule (read this twice)

The single most common gotcha. The parser pairs `:key` with the
**next non-keyword value**. When two `:keyword` tokens come back
to back, the first does **not** become the second's value:

```sjon
(stack :mode :mask)
; → two positional flags: :mode and :mask
;   NOT mode = :mask
```

This is the parser's "greedy" rule: a `:key` in value position
is impossible. If a `:keyword` ever shows up where a value
should be, it's promoted to a positional flag and the pending
`:key` it would have paired with becomes a positional flag too.

The closing `)` is the same kind of break: a `:keyword` left
dangling at the end of a form has no value to pair with, so it
becomes a trailing positional flag.

```sjon
(camera :zoom 2 :ortho)
; → :zoom pairs with 2; :ortho is a trailing positional flag.
```

### Do this, not that

The fix depends on what the value is supposed to mean. Three
options:

```sjon
; ✗ Doesn't pair — :mode and :mask both end up as positional flags.
(stack :mode :mask)

; ✓ Use a symbol when the schema expects a closed-set enum.
(stack :mode mask)
;        ^^^^ pairs as a kvpair: mode = mask (a symbol).

; ✓ Use a string when the schema expects free-form text.
(stack :mode "mask")
;        ^^^^^^ pairs as a kvpair: mode = "mask".

; ✓ Wrap in a vector when you really want a keyword in value position.
(stack :modes [:mask])
;        ^^^^^^^ pairs as a kvpair: modes = [:mask].
```

Most plugins design around this. A slot for "the projection mode"
takes a symbol (`ortho` / `perspective`) or a member-set on a
symbol underlying — not a keyword. When you're reading a plugin's
schema and you see a slot typed `symbol` with a closed-set list,
write the value bare:

```sjon
(camera :projection ortho)             ; ✓ symbol value
(camera :projection :ortho)
; parses as two positional flags: :projection and :ortho
; not as projection = :ortho
```

> **Remember.** A keyword can never be the value of a kvpair.
> Reach for a symbol or a string instead.

A second consequence: forms with `.positional = .none` (§11)
reject every flag, which is how this gotcha announces itself —
you'll see one diagnostic per accidentally-promoted keyword.

---

## 8. Comments

Three syntaxes:

```sjon
; line comment to end of line
;; conventionally for section headings
#| block comment, may span lines |#
```

Comments attach to the nearest following structural node — they
ride along through structural edits and are preserved through
the lossless print mode. Canonical print drops them. Block
comments do not nest, so don't try to comment out a region that
already contains `#| … |#`.

Use them. Especially:

- A `;` above a kvpair to explain a non-obvious value.
- A `;;` heading to break a long form into sections.
- A `#| … |#` to stash a few lines of in-progress alternative
  during edits.

```sjon
(scene :bpm 130
  ;; main canvas
  (canvas :name "main" :w 1920 :h 1080
    ; the radius is driven by the beat clock
    (shape :sdf :radius (* 2 (b 1)))))
```

---

## 9. Strings revisited — when to reach for `"""…"""`

Two surface forms, one value:

- `"…"` — escape-quoted. Recognised escapes: `\\`, `\"`, `\n`,
  `\t`, `\r`, `\u{NNNN}`. The common case.
- `"""…"""` — triple-quoted raw. Body is taken verbatim. No
  escape processing, no dedent, no newline stripping.

Reach for `"""…"""` when escape-quoting would clutter the
payload — embedded shader source, regular expressions, paths
with backslashes, snippets of HTML / XML.

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

```sjon
"""C:\path\to\file"""             ; backslash is literal
"""she said "hi" today"""         ; single quotes are content
```

### The "opens with a newline" gotcha

If the opening `"""` is alone on a line, the **first byte of the
body is `\n`**:

```sjon
; Body starts with a literal newline.
:source """
@vertex …"""

; Body starts with `@vertex` — no leading newline.
:source """@vertex …"""
```

Pick the one you want; both are valid.

### What `"""…"""` cannot do

- **Three consecutive `"`** can't appear in a raw body — the
  closer is greedy. For payloads containing `"""`, fall back to
  `"…"` with `\"` escapes.
- **Trailing `"`** before the closer is impossible for the same
  reason.

There's no hash-padded raw form (no Rust-style `r#"…"#`) and no
string-concat operator in the substrate, so those edge cases
route through escape-quoting. A host may add a concat expression
via a plugin, but the escape-quoted form is the universal answer
that always works.

A raw string and an escape-quoted string with the same decoded
bytes are **equal values**: `"""hello"""` equals `"hello"`. Tools
that re-emit your document may rewrite one into the other. The
decoded content survives; the choice of delimiter does not.

---

## 10. Expressions — when a form is computation

A form whose head names a built-in or plugin-declared **safe
expression function** is computed at evaluation time, not
treated as data:

```sjon
(camera :ortho :zoom (* 2 (b 1)))
;                    ^^^^^^^^^^^^
;                    safe expression: multiply 2 by `(b 1)`,
;                    where `b` is "beats → seconds" from a plugin.
```

Expressions can appear **anywhere a value can appear** — kvpair
values, vector elements, positional children. Whether a given
form is a constructor or an expression is decided by the head's
name: if it's in the active schema's expression vocabulary, the
consumer can evaluate it; otherwise it's data.

Expression arguments are positional by default. A function that
declares labels also accepts an all-labeled call:

```sjon
(lerp 0 10 0.5)              ; positional
(lerp :from 0 :to 10 :t 0.5) ; labeled, same call
(lerp :t 0.5 :from 0 :to 10) ; labeled, reordered
```

Do not mix the two call styles in one expression. Functions without
declared labels keep rejecting `:k v` pairs with
`expr_kvpair_not_allowed`; labeled calls surface specific diagnostics
for unknown, duplicate, missing, or mixed labels (§13).

The substrate guarantees expressions are **pure**. No I/O, no
mutation, no side effects, no recursion. Evaluation always
terminates: depth and step caps are baked in. The same input
produces the same output every time.

### The built-in (`core`) vocabulary

Available with no plugins beyond `core`:

#### Arithmetic

| Form | Arity | Meaning |
| --- | --- | --- |
| `(+ x …)` | 0+ | Sum. `(+)` is `0`. |
| `(- x …)` | 1+ | Negation (one arg) or left-fold subtraction (two+). |
| `(* x …)` | 0+ | Product. `(*)` is `1`. |
| `(/ x y …)` | 2+ | Left-fold division. Division by zero is an error. |
| `(mod x y)` | 2 | Floored remainder; the result takes the divisor's sign (as GLSL `mod` / Python `%`). |

#### Comparison

```sjon
(<  x y)   (>  x y)              ; both: number, number → boolean
(<= x y)   (>= x y)              ; both: number, number → boolean
(=  x y)   (!= x y)              ; polymorphic equality → boolean
```

All binary, all return a boolean. `=` and `!=` work across kinds
(numbers, strings, keywords, symbols, vectors, booleans, nil)
and only return `true` when the kinds match and the payloads
match.

#### Logical

```sjon
(not x)              ; arity 1, boolean → boolean
(and x …)            ; arity 0+, short-circuit, returns first falsy or last value
(or x …)             ; arity 0+, short-circuit, returns first truthy or `false`
```

Short-circuit means evaluation stops as soon as the result is
decided. Both operators are value-returning, but with one
asymmetry worth pinning down:

- `(and 1 2 3)` is `3` — all truthy, the last value wins.
- `(and 1 nil 3)` is `nil` — first falsy value, returned as-is.
- `(or false 5 nil)` is `5` — first truthy value wins.
- `(or false nil)` is `false` — when nothing is truthy, the
  result is the literal boolean `false`, **not** the last value
  seen. (Unlike `and`, `or` does not preserve the trailing
  falsy value.)

`(and)` with no arguments is `true`; `(or)` with no arguments is
`false`. These are the identity elements for each operation —
`true` is the value that doesn't change an `and`, `false` is the
value that doesn't change an `or`.

Truthiness: `false` and `nil` are falsy; everything else
(including `0`, `""`, `[]`) is truthy. If you want zero-as-false,
write `(= n 0)` explicitly.

#### Vectors

```sjon
(vec2 x y)             ; → 2-vector
(vec3 x y z)           ; → 3-vector
(vec4 x y z w)         ; → 4-vector
```

For variable-length vectors, write the literal `[a b c …]`.

#### Math and aggregation

| Form | Arity | Meaning |
| --- | --- | --- |
| `(lerp a b t)` | 3 | Linear interpolation: `a + (b - a) * t`. |
| `(clamp x lo hi)` | 3 | Clamp `x` into `[lo, hi]`. |
| `(min x …)` | 1+ | Numeric minimum. |
| `(max x …)` | 1+ | Numeric maximum. |
| `(dot a b)` | 2 | Dot product of two same-length vectors. |
| `(cross a b)` | 2 | Cross product of two 3-vectors. |
| `(length v)` | 1 | Euclidean length of a vector. |
| `(abs x)` | 1 | Absolute value. |
| `(sign x)` | 1 | `-1`, `0`, or `1`; `NaN` passthrough. |
| `(floor x)` `(ceil x)` `(round x)` | 1 | Round toward `−∞`, `+∞`, away-from-zero. |
| `(fract x)` | 1 | `x − floor(x)` (WGSL — result may be exactly `1.0`). |
| `(sqrt x)` | 1 | Principal square root; `(sqrt x<0)` → `NaN`. |
| `(pow base exp)` | 2 | Exponentiation. |
| `(sin x)` `(cos x)` `(tan x)` | 1 | Trig with `x` in **radians**. |
| `(asin x)` `(acos x)` `(atan x)` | 1 | Inverse trig; out-of-domain → `NaN`. |
| `(atan2 y x)` | 2 | Argument of `(x, y)` in `[−π, π]`. |
| `(radians deg)` `(degrees rad)` | 1 | Angle conversion. |
| `(pi)` `(tau)` | 0 | Constants `π`, `2π`. |
| `(saturate x)` | 1 | `clamp(x, 0, 1)`. |
| `(step edge x)` | 2 | `0` if `x<edge`, else `1`. |
| `(smoothstep e0 e1 x)` | 3 | WGSL cubic Hermite; `e0==e1` is indeterminate. |
| `(normalize v)` | 1 | Unit-length vector; zero or empty → error. |
| `(distance a b)` | 2 | Euclidean distance; lengths must match. |
| `(reflect I N)` | 2 | Reflection: `I − 2·dot(N,I)·N`. `N` must be unit-length. |
| `(nth v i)` | 2 | 0-indexed vector access; OOB or non-integer `i` → error. |
| `(count v)` | 1 | Vector length as a number. |
| `(hash seed key)` | 2 | 53-bit deterministic integer in `[0, 2^53)`. |
| `(rand01 seed key)` | 2 | Deterministic uniform float in `[0, 1)`. |
| `(rand-range seed key lo hi)` | 4 | Float in `[lo, hi)`. |
| `(rand-int seed key lo hi)` | 4 | Integer in `[lo, hi]` inclusive. |
| `(rand-bool seed key p)` | 3 | `true` with probability `clamp(p, 0, 1)`. |
| `(rand-choice seed key v)` | 3 | Pick one element of `v`; empty → error. |

#### Control flow

```sjon
(let [name1 expr1 name2 expr2 …] body)
(if test then-expr [else-expr])
(cond test1 expr1 test2 expr2 … [else-expr])
```

`let` binds names sequentially — each `expr` sees every earlier
binding in the same `let`, and the body sees them all:

```sjon
(let [a 1
      b (+ a 2)         ; a is in scope here
      c (* a b)]        ; a and b are in scope here
  (+ a b c))            ; → 7
```

`if` evaluates exactly one of its branches:

```sjon
(if (> 5 2) "big" "small")    ; → "big"
```

`cond` is a generalised `if/else-if` chain; pairs are
test-then-value, evaluated left to right, returning the first
matching value. Use a literal `true` for the default branch:

```sjon
(cond
  (< x 0)  -1
  (> x 0)   1
  true      0)            ; default fallthrough
```

A `cond` with no matching test returns `nil`.

#### Iterating with binder forms

`map`, `filter`, `any`, `all`, and `fold` walk a finite vector while
binding a name to each element. The first child is a literal binder
vector — `[x]` for the first four (one symbol), `[acc x]` for fold
(two distinct symbols):

```sjon
(map [x] [1 2 3 4] (* x x))             ; → [1 4 9 16]
(filter [x] [-1 0 1 2] (> x 0))         ; → [1 2]
(any [x] [1 2 3] (> x 2))               ; → true
(all [x] [1 2 3] (> x 0))               ; → true
(fold [acc x] 0 [1 2 3 4 5] (+ acc x))  ; → 15
```

The body evaluates **once per element** in a fresh environment
layered over the surrounding scope. The outer scope is unchanged
after the form completes — there is no mutation, no accumulator
visible outside the loop, no early return other than the
short-circuit semantics of `any`/`all`.

`fold` threads the body's result back as `acc` for the next
iteration; the form's value is the body's last result, or the
evaluated `init` if `xs` is empty. Like the other binders, fold has
no closure value — the binding lives only inside the form.

These are not first-class lambdas. You cannot extract "the predicate"
as a value, store it, or pass it to another form. They exist to let
you write one expression that touches every element of a vector
without leaving the config language.

### A worked example using bindings

Domain plugins extend the vocabulary with their own functions
(time conversions, easing curves, color math). Compose freely:

```sjon
(group :name "fade"
  (shape :sdf
    :radius 0.5
    :alpha (lerp 1 0 (clamp t 0 1))))
;          ^^^^^^^^^^^^^^^^^^^^^^^^^^
;          `t` is a binding the host supplies (e.g. animation time).
;          The host evaluates :alpha each frame with a fresh `t`.
```

The expression vocabulary is small on purpose — for "a little
safe math" inside a config, not for general computation. If you
need a loop or a closure, lift the work into the host language
and pass the result through SJON as data.

---

## 11. Reading a plugin's schema

Plugins ship a description of the forms, expression functions,
and value kinds they declare. The structure is the same whether
the plugin is documented as a Zig struct, a portable manifest
(`manifests/meta.sjon`), or a README — for forms, the fields you
need are always the same few.

### What plugins declare

For each form a plugin owns:

| Field | What it means to you |
| --- | --- |
| `name` | The head you write. `(name …)`. |
| `keys` | The `:k` slots the form accepts. Each key has a name, a value type, an `optional` flag, and optionally a default. |
| `positional` | Whether positional children are accepted: `none`, `any`, or a typed kind. |
| `open` | When `true`, the form acts as an extensible bag: unknown keys are accepted and closed-shape sweeps are skipped, while declared key types and duplicate keys still matter. Rare; mostly a prototyping switch. |
| `description` | A free-text help string editors render on hover. |

A typical declaration table you'd see in a plugin's docs:

```
(canvas …)
  :w        length      required          width in canvas units
  :h        length      required          height in canvas units
  :bg       string      optional          background color name
  positional: any (positional children are shapes)
```

That tells you everything you need: write `:w` and `:h` (and they
must each be a `length`), `:bg` is optional and takes a string,
and you can drop shape forms in positionally.

### The type vocabulary

A slot's type is one of the following. Most reference SJON value
kinds directly; the last row is a reference to a plugin-declared
**value kind** (covered below).

| Type | Accepts |
| --- | --- |
| `any` | Any value. The escape hatch — no checks. |
| `number` | A number, with or without a unit. |
| `string` | A string. |
| `symbol` | A bare symbol. Common for closed-set enum values. |
| `boolean` | `true` or `false`. |
| `nil` | Only `nil`. |
| `vector` | Any vector, untyped elements. |
| `form` | Any nested form. |
| `expr` | A safe-expression form. |
| `<kind-name>` | Reference to a plugin-declared value kind, written as a bare symbol (e.g., `length`, `point`, `projection`). |

There is **no `keyword` slot type**. Because of the pairing
rule (§7), a kvpair value can't be a keyword, so a plugin
asking for one wouldn't get a way to receive it. Plugins
expecting "a discrete option" use `symbol` with a closed
member-set instead.

### Value kinds — refinements

When a plugin declares a value kind, it picks one concrete
underlying shape (number, string, vector, form, or symbol) and
may refine that shape. A kind can also be a flat union of existing
kinds. As an author, all you need is the plugin's docs telling you
which constraint applies. The common refinements are:

- **Vector shape** — pinned element kind and (optionally)
  length. `point` might be "2-vector of numbers"; `rgba` might
  be "4-vector of numbers."
- **Unit shape** — required unit presence and an allowed list
  of unit suffixes. `duration` might require a unit drawn from
  `s | ms | b`.
- **Numeric bounds** — range, integrality, and divisibility
  constraints on number-underlying kinds. `opacity` might be
  "number in [0, 1]"; `iteration-count` might be "integer ≥ 1";
  `buffer-offset` might be "256-byte aligned".
- **String bounds** — length and closed format checks on
  string-underlying kinds. `slug` might require 1–64 codepoints;
  `email-address` might use the `email` format.
- **Member set** — a closed list of allowed values for a
  symbol-underlying or string-underlying kind. `projection`
  might be `ortho | perspective`.
- **Head set** — a closed list of allowed form heads for a
  form-underlying kind. A `:shape` slot might accept only
  `(circle …)` or `(rect …)`.
- **Cross-reference** — a symbol-underlying kind whose allowed
  names come from matching forms in the validated document or
  scope. A `phrase-name` slot might reference a `(phrase :name …)`.
- **Union alternatives** — a slot accepts a value that satisfies
  one of several named kinds. The branches stay flat: unions do
  not nest.

Worked examples of writing to each:

```sjon
; Slot typed `length` (number underlying, no unit constraint).
(circle :radius 0.5)
(circle :radius 16)

; Slot typed `point` (vector underlying, len 2, element number).
(circle :center [160 120])

; Slot typed `duration` (number underlying, required unit ∈ {s, ms, b}).
(delay :wait 250ms)               ; ✓
(delay :wait 4b)                  ; ✓
(delay :wait 0.5)                 ; ✗ no unit, validator rejects

; Slot typed `opacity` (number underlying, in [0, 1] inclusive).
(layer :opacity 0)                ; ✓
(layer :opacity 0.5)              ; ✓
(layer :opacity 1)                ; ✓
(layer :opacity 1.5)              ; ✗ above maximum
(layer :opacity -0.1)             ; ✗ below minimum

; Slot typed `buffer-offset` (number, integer, 256-byte aligned).
; Alignment is the constraint a range and "must be whole" cannot
; express between them.
(binding :offset 0)               ; ✓ zero divides by anything
(binding :offset 512)             ; ✓
(binding :offset 250)             ; ✗ not a multiple of 256
(binding :offset 250.5)           ; ✗ not an integer — reported FIRST,
                                  ;   before the alignment complaint

; Slot typed `projection` (symbol underlying, members [ortho, perspective]).
(camera :projection ortho)        ; ✓
(camera :projection perspective)  ; ✓
(camera :projection oblique)      ; ✗ not in member set

; Slot typed `shape-form` (form underlying, head set [circle, rect]).
(badge :shape (circle :radius 4)) ; ✓
(badge :shape (rect :w 4 :h 4))   ; ✓
(badge :shape (triangle :side 4)) ; ✗ head not in set

; Slot typed `slug` (string underlying, length/format constraints).
(route :slug "intro-scene")       ; ✓
(route :slug "")                  ; ✗ below minimum length

; Slot typed `phrase-name` (symbol cross-reference to phrase names).
(phrase :name intro)
(play :phrase intro)              ; ✓
(play :phrase missing)            ; ✗ no matching phrase name

; Slot typed `pitch-or-event` (union of named kinds).
(emit :value c4)                  ; ✓ if `c4` satisfies `pitch`
(emit :value (note :at 0))        ; ✓ if `(note …)` satisfies `event`
```

The key insight: a value kind is the plugin's way of saying
"I want this slot to be more specific than just a number." You
don't define them as an author — you write values that satisfy
them.

### When a name can come from more than one form

Sometimes a slot should accept a name declared by either of two forms —
"any pipeline", where a pipeline is a `(render-pipeline …)` or a
`(compute-pipeline …)`. A plugin can write that two ways, and as an author
you can tell which one you are looking at from the diagnostics you get.

A **target group** (`:target [render-pipeline compute-pipeline]`) puts
both forms in *one* namespace. Every name resolves regardless of which
form declared it, and declaring the same name in both is an error at the
declarations:

```sjon
(render-pipeline  :name blit)
(compute-pipeline :name reduce)

(dispatch :pipeline blit)         ; ✓ resolves
(dispatch :pipeline reduce)       ; ✓ resolves — same slot, other form
(dispatch :pipeline blot)         ; ✗ not_cross_ref, spanning both forms

(render-pipeline  :name same)
(compute-pipeline :name same)     ; ✗ duplicate_cross_ref_target
```

A **union of two cross-reference kinds** keeps them in *two* namespaces.
The same names resolve, but `same` is now legal in both, and the reference
becomes ambiguous instead:

```sjon
(render-pipeline  :name same)
(compute-pipeline :name same)     ; ✓ two namespaces, no collision
(dispatch :pipeline same)         ; ⚠ union_ambiguous — resolves to the
                                  ;   first alternative the plugin listed
```

Neither is more correct in general; they answer different questions. If
you hit `duplicate_cross_ref_target` across two forms, the schema says
those names are meant to be unique together, and the fix is to rename one.
If you hit `union_ambiguous`, the schema says they are not, and the fix is
either to rename anyway or to use a slot that names one kind.

### Cross-references whose names come from inside a string

`(play :phrase intro)` above works because `intro` is written as a
symbol somewhere the validator can see it — `(phrase :name intro)`. But
plenty of names you want to reference are not written in SJON at all.
The uniforms of a shader live inside a shader; the capture groups of a
regex live inside the regex.

A plugin can bridge that with a **provider**: it declares an extractor,
and the host hands it the opaque string so it can say what names are in
there. From your side nothing new is happening — you write a symbol and
it is either a member or it isn't:

```sjon
(shader :name blur
  :src """
  uniform float u_time;
  uniform vec2  u_resolution;
  """)

(bind :uniform u_time)       ; ✓ the provider found it in :src
(bind :uniform u_resulution) ; ✗ not_cross_ref — and the fix is offered
```

Two things are worth knowing, because they look like bugs otherwise.

**Go-to-definition lands on the whole string.** `u_time` has no span of
its own — SJON never parsed that GLSL, it only received a list of names
— so the definition of every extracted name is the `:src` string that
produced it.

**Some hosts can't run providers, and say so instead of guessing.** The
browser playground, for one: it cannot execute plugin code at all. When
that happens you get a single diagnostic on the `:src` string —
"provider `lines` was not run, so `shader` names from this source are
unchecked" — and *no* diagnostics on the references. They are unchecked,
not accepted and not rejected, and a host that reported `u_resulution`
there would be claiming to know a member set it never computed. In an
editor this arrives as a hint rather than an error, because nothing in
your file is wrong.

### When a name could come from more than one form

A slot can be typed as a *union* of two reference kinds — "this names
either a render pipeline or a compute pipeline". Alternatives are tried
in the order the plugin declared them, and the first one that accepts
wins. Usually you never notice, because the name exists in only one of
them:

```sjon
(render-pipeline  :name blit)
(compute-pipeline :name reduce)

(dispatch :pipeline blit)     ; ✓ the render pipeline
(dispatch :pipeline reduce)   ; ✓ the compute pipeline
```

Now name them both the same thing:

```sjon
(render-pipeline  :name same)
(compute-pipeline :name same)

(dispatch :pipeline same)     ; ⚠ union_ambiguous
```

Neither declaration is a duplicate — duplicate names are caught *per
target*, and these are two different targets, so each is alone in its
own namespace. But the reference now has two readings, and the only
thing choosing between them is which alternative the plugin author
happened to list first. SJON picks the render pipeline; a tool that
resolves the name through its own table may well pick the other, and
neither of you would ever find out.

It is a **warning**, not an error: your document is valid and the
behaviour is defined. It is telling you that the definition is
accidental. Two repairs, and which one is right depends on what you
meant:

- **Rename one declaration.** Right when the collision was an accident
  and the two things are unrelated.
- **Split the slot.** Right when both names are deliberate and it is
  the *slot* that was overloaded — `:render-pipeline` and
  `:compute-pipeline` as separate keys, each with one reference kind.

You will not see this warning for a union that merely overlaps. `1024`
in a slot typed "a byte count or a named constant" matches the count
half and that is the design. The warning is specifically about two
*names of two different things* colliding, which is the case where order
is deciding something nobody decided.

---

## 12. Common patterns

### Required vs optional keys

The plugin tells you which keys are required. Authors write
required keys explicitly; optional keys can be omitted. The
validator emits one diagnostic per missing required key unless the key
declares a default.

```sjon
; circle requires :center and :radius; :color is optional.
(circle :center [0 0] :radius 1)                 ; ✓
(circle :center [0 0] :radius 1 :color "red")   ; ✓
(circle :radius 1)                               ; ✗ missing :center
```

### Keys that require other keys

Some keys are only meaningful next to another. A byte `:offset` into no
buffer describes nothing, so a plugin can declare that writing one
demands the other:

```sjon
; :offset and :size each require :buffer.
(entry :binding 0)                               ; ✓ neither written
(entry :binding 0 :buffer uniforms)              ; ✓ the requirement alone
(entry :binding 0 :buffer uniforms :offset 256)  ; ✓ satisfied
(entry :binding 0 :offset 256)                   ; ✗ dependent_key_missing
```

The rule runs one way. `:buffer` on its own is fine — it is `:offset`
that drags `:buffer` in, never the reverse. And you get one diagnostic
per key that went unsatisfied, listing everything it was missing, so a
key needing three absent keys tells you all three at once.

This is one of three ways a plugin relates a form's keys, and the
message tells you which you hit:

| You see | The rule was |
| --- | --- |
| `dependent_key_missing` | "if this key, then also that one" |
| `mutually_exclusive_keys_present` / `required_one_of_missing` | "how many of these may appear" |
| `unknown_key` on a key that exists elsewhere | "this key applies only for certain *values* of another key" (a variant — one value, or several: `:strip-index-format` exists under `triangle-strip` *and* `line-strip`, and under no list) |

### Defaults and effective values

A default is the plugin's fallback for an omitted key. It makes the key
effectively optional, but it does not rewrite your source:

```sjon
; render-target declares :bg default "black".
(render-target :w 320 :h 240)                    ; effective :bg = "black"
(render-target :w 320 :h 240 :bg "navy")         ; explicit value wins
```

Production validation reads effective values in the places where
presence matters: cross-reference names and references, discriminant
selection, and exclusive groups. Exclusive groups use an author-first
rule: if you explicitly write one alternative, a sibling alternative's
default does not silently conflict with it.

Multi-key alternatives (`(alt :keys [from to])`) are all-or-nothing
bundles: set every key in the bundle, or none. A partial bundle
surfaces as `exclusive_bundle_partial` — see `docs/LANGUAGE.md` §6.2.1
for the full diagnostic table.

Expression defaults can still fail when the host materializes them. If
you omit a key and see `default_eval_failed`, the schema's default was
declared but could not be evaluated by the active host.

### Typed vector slot

```sjon
; point is a 2-vector of numbers.
(circle :center [160 120])                       ; ✓
(circle :center [160 120 0])                     ; ✗ wrong length
(circle :center [160 "left"])                    ; ✗ wrong element kind
```

### Member-set enum

```sjon
; projection is a symbol from [ortho, perspective].
(camera :projection ortho)                       ; ✓
(camera :projection :ortho)                      ; ✗ keyword can't pair (§7)
(camera :projection "ortho")                     ; ✗ string, not symbol
```

### When the enum's name starts with a digit

Some enums name their members with a digit first. WebGPU's
`GPUTextureDimension` is `"1d"`, `"2d"`, `"3d"`; its view dimensions add
`cube` and `cube-array`. A plugin can declare those directly:

```sjon
(texture :name albedo :dimension 2d :view cube)
```

You write the spelling the spec uses — no quoting, no numeric lookup
table. Three things worth knowing, because they follow from *how* it
works rather than from the enum:

**Spelling is forgiving, magnitude is not.** `2d`, `2.0d`, and `02d` are
all the member `2d`: the schema matches the value's magnitude and unit,
not its text. `2.5d` is not `2d` — a fractional magnitude matches nothing.

**The unit is part of the name.** `2b` is not `2d`. If a plugin declares
`[1d 2d 3d]`, only the `d` tail counts.

**A bare number is not a member.** `:dimension 2` is a *number*, not the
spelling `2d`, so it fails as a type mismatch rather than as a bad enum
value. The letter tail is what makes a digit-leading token a name.

When you get it wrong the diagnostic names the set, the same way it does
for ordinary symbol members:

```
error: not_member: form `texture` keyword `:dimension` expects
       `texture-dimension`, got `4d` (allowed: `1d`, `2d`, `3d`)
```

### A number or a named constant

A slot typed `scalar-or-ref` takes either a literal or a bare symbol
naming one declared elsewhere:

```sjon
(define :name MAX_BONES :value 128)

(mesh :bones 128)                                ; ✓ the literal
(mesh :bones MAX_BONES)                          ; ✓ the reference
(mesh :bones "128")                              ; ✗ neither branch
```

Watch the misspelling. Whether `MAX_BONE` is caught depends on how the
plugin declared the slot:

```sjon
(mesh :bones MAX_BONE)
```

If the shorthand names a `:ref` kind, this fails — `not_cross_ref`,
naming the form the symbol had to be declared by, because a symbol can
only have meant the reference half and the diagnostic is that half's
own. (A number out of the base's range likewise reports the base's
`number_above_max`, bound and all; only a value neither half could take,
such as a string here, gets the union's `union_no_branch_matched`.) If it
does not name a `:ref`, the reference half is a plain unchecked symbol
and this **validates clean**, silently referring to nothing. If you are writing the plugin, prefer the
checked form; if you are reading someone else's, that is the difference
between a typo caught at validate time and one caught at runtime.

### Form-as-slot (head-set) pin

```sjon
; :shape accepts only (circle …) or (rect …).
(badge :shape (circle :radius 4))                ; ✓
(badge :shape (rect :w 4 :h 4))                  ; ✓
(badge :shape (triangle :side 4))                ; ✗ head not allowed in this slot
```

### Positional slot-local forms

A form can name its own one-off child forms inline — scoped to that form,
invisible everywhere else. A positional child then resolves *that* form's
local first, so a local head may reuse a name that means something else
globally:

```sjon
; `entry` here is bind-group's OWN local (needs :binding); it shadows any
; global (entry …). Unlisted heads fall through to the global catalog; a
; head that's neither local nor global is unknown_local_form on the
; (bind-group …) node itself.
(bind-group
  (entry :binding 0))                            ; ✓ the local entry
(bind-group (slot :binding 0))                   ; ✗ unknown_local_form
```

Declared with inline `(form …)` children directly under the parent form —
no `:positional` needed, since inline locals imply it:

```sjon
(form :name bind-group
  (form :name entry (key :name binding :type number :optional false)))
```

Add a `head-set` on `:positional` to close the slot to exactly those
heads. Full semantics: LANGUAGE.md §6.3.1 and portable-manifest-v1.md
§5.2.

The two work together, and a head-set does **not** force you to declare
anything globally: you don't need a global form to name a head in a
head-set, you need a form the validator can find *from that slot*. A
local one counts.

```sjon
; The head-set lists `storage-texture`; the only (form :name
; storage-texture …) is a local of `entry`. That is enough — no global
; declaration, no placeholder form.
(form :name bind-group-layout :positional bgl-entry-item
  (form :name entry :positional bgl-resource
    (form :name buffer          (key :name type   :type symbol))
    (form :name storage-texture (key :name format :type symbol))))
```

If a head-set names something with no form *anywhere*, the head is
allowed in and then has nothing to be checked against —
`unknown_local_form` at the slot. That's one diagnostic, and it comes
from looking up the body, not from the head-set.

#### …and how many of each

On a `:positional` slot, a head-set can also bound the count. Spell the
heads out with `(head …)` children instead of `:names`, and each one may
carry `:min` / `:max`:

```sjon
(value-kind :name pipeline-section :underlying form
  :heads (head-set
    (head :name vertex   :min 1 :max 1)   ; exactly one
    (head :name fragment :max 1)          ; at most one — none is fine
    (head :name constant)))               ; any number

(form :name render-pipeline :positional pipeline-section
  (key :name name :type symbol))
```

```sjon
(render-pipeline :name main
  (vertex :entry vs) (fragment :entry fs)
  (constant :name gamma :value 2.2))             ; ✓

(render-pipeline :name main
  (vertex :entry vs)
  (fragment :entry fs) (fragment :entry alt))    ; ✗ positional_too_many, on the second (fragment …)

(render-pipeline :name main
  (fragment :entry fs))                          ; ✗ positional_missing, on (render-pipeline …)
```

The two codes land in different places on purpose. A ceiling breach
points at the child that crossed it — that's the line to delete. A floor
breach has no child to point at, so it lands on the parent form's head,
the same place a missing required key does.

Three things worth knowing before you rely on it:

- `:names [a b c]` cannot carry a count. The two spellings are exclusive
  (mixing them is `invalid_manifest`), so adding a bound to one head means
  writing all of them as `(head …)` children.
- **`:open true` does not turn the counts off.** Openness is about
  keywords; a form that declares `:positional <bounded-kind>` has opted
  into its children's count regardless.
- **The counts only mean something on `:positional`.** Reuse the same kind
  on a `(key :type pipeline-section)` slot or a
  `(vector-shape :element pipeline-section)` and the bounds ride along
  inertly — a keyed slot holds one value, so there is nothing to count.
  That is deliberate: it keeps a bounded kind shareable.

#### …and how many altogether

Per-head bounds cannot say "exactly one of these". Try it: give every
head `:max 1` and a form with one of each is accepted; give one head
`:min 1` and you have demanded *that* head, not any of them. The claim
belongs to the set, so it is spelled on the set:

```sjon
(value-kind :name bgl-resource :underlying form
  :heads (head-set :min-children 1 :max-children 1   ; exactly one, whichever
    (head :name buffer  :max 1)                      ; …and not two of the same
    (head :name sampler :max 1)
    (head :name texture :max 1)))

(form :name entry :positional bgl-resource
  (key :name binding :type number))
```

```sjon
(entry :binding 0 (buffer :type uniform))                    ; ✓
(entry :binding 1 (buffer :type uniform) (sampler :type filtering))
                                                             ; ✗ positional_too_many — two resources
(entry :binding 2)                                           ; ✗ positional_missing — no resource
(entry :binding 3 (buffer :type uniform) (buffer :type storage))
                                                             ; ✗ positional_too_many — two buffers
```

Three things worth knowing here too:

- **`:min-children` / `:max-children` work on `:names` as well.** The
  aggregate needs no per-head metadata, so
  `(head-set :names [cube sphere] :max-children 1)` — "at most one
  generator" — is legal and is the common shape.
- **Both levels report through the same two codes.** Tell them apart by
  the message: a set-level one names a bracketed set (`at most 1
  positional child from [buffer | sampler | texture]`) where a per-head
  one names a head. The repair differs — pick one, versus de-duplicate.
- **When both would fire, only the head does.** The last example above is
  over `buffer`'s ceiling *and* the set's; you get one diagnostic, the
  per-head one, because it points at the line to delete. So a set-level
  message tells you the children are individually fine and there are
  simply too many of them together.

The loader refuses a set that no document could satisfy — `:min-children`
above `:max-children`, heads whose `:min`s *sum* above `:max-children`,
or a `:min-children` above what the heads' `:max`es allow between them.
The middle one is why the check is a sum: two heads at `:min 1` under
`:max-children 1` is unsatisfiable while neither head alone looks wrong.

### Embedding multi-line code

Use `"""…"""` for shader source, regex, path strings, anything
where backslashes or quotes would clutter:

```sjon
(shader-module :name "hello"
  :source """@fragment
fn fs() -> @location(0) vec4f {
  return vec4f(1.0, 0.0, 0.0, 1.0);
}
""")
```

### Driving a parameter from an expression

Any value position can hold a safe expression. The host evaluates
it when it pulls the value out:

```sjon
(group :name "pulse"
  (shape :sdf
    :radius (* 0.5 (lerp 0.8 1.2 t))
    :alpha  (clamp (- 1 t) 0 1)))
;            ^^^^^^^^^^^^^^^^^^
;            t is a host-supplied binding (e.g. normalized time).
```

When the expression's `:result` is declared in the manifest, the
validator type-checks it against the slot before evaluation. A
`(vec3 …)` in a `:radius` slot expecting a number surfaces
`wrong_underlying` at validate time — no runtime trip required.
Opaque expressions (`let`, `if`, host-bound symbols, expressions
whose declared result is too coarse to prove a refined named kind)
still defer to evaluation, so authoring with `let`-bound numbers in
a vec3 slot stays clean.

### Host-lowered forms

Some schemas declare a form as surface syntax that a host lowers into
ordinary forms before final validation. The manifest names a lowering
hook contract; the `.sjon` document does not contain rewrite code and
does not choose the implementation.

For authors, this has three practical effects:

- The document is fully usable only under a host that implements the
  declared hook.
- The hook reads effective values, so omitted defaulted keys are visible
  to lowering code.
- Diagnostics from lowered output should trace back to the source form
  through provenance, even when the final error belongs to a generated
  form.

### Mixing kvpairs and positional children

A form may carry both, freely intermixed in source order:

```sjon
(canvas :name "main" :w 1920 :h 1080
  (camera :ortho :zoom 2)             ; positional child
  (shape :sdf :radius 0.5)            ; positional child
  :bg "#202028"                       ; kvpair after children — still valid
  (placeholder :note "TODO"))         ; positional child
```

Plugins decide whether positional children are allowed at all
(`positional none / any / kind`); see §11.

**Convention:** even though intermixing is legal, most authors
write **keys first, children last**. It scans better, makes diffs
quieter when children move around, and matches the shape of every
example earlier in this handbook. Reach for the trailing-kvpair
form (like `:bg "#202028"` above) only when the value is a
trailing-flag-style afterthought.

### Qualifying heads for portability

Bare heads are the default and almost always fine (§6). But for
documents that need to validate cleanly across **multiple host
setups** — a scene shared between a renderer that loads `shapes`
and one that loads `shapes` + a third-party `art-shapes` — a
bare `(circle …)` is one collision away from `ambiguous_form`.

A defensive convention for portable documents:

- **Domain-specific plugin heads** — qualify them
  (`shapes/circle`, `audio/sample`). The cost is a few extra
  characters; the payoff is one less way for an unfamiliar host
  to reject the document.
- **Core / built-in heads** — leave bare. There's no second
  plugin that could shadow `let`, `if`, `+`, `lerp`, etc., so
  the qualification would only add noise.

For documents authored against one known host (the common case),
bare everywhere is still the right default. This pattern is for
the "ship across many hosts" scenario.

---

## 12.b Testing your schema

SJON itself is pinned by a conformance corpus: hundreds of small
documents, each with an `expected.sjon` naming exactly the diagnostics
it must produce. `sjon plugin test` hands you the same discipline for
your own schema — no new assertion syntax, the corpus format verbatim.

Beside your manifest, make a `tests/` directory of pairs:

```
myplugin/
  plugin.sjon
  tests/
    clean.sjon
    clean.expected.sjon
    missing-status.sjon
    missing-status.expected.sjon
```

Each `<case>.sjon` is a document validated against your manifest
(plus the core vocabulary). Each `<case>.expected.sjon` asserts its
diagnostic stream, in order:

```sjon
; missing-status.expected.sjon — the document omits :status, and that
; is exactly what we expect it to be told.
(diagnostics
  (diagnostic :code missing_required_key :path [post]))
```

A clean document asserts the empty stream — `(diagnostics)`. Severity
defaults to `err`; assert a warning with `:severity warning`.

Run it (red first, like any test loop):

```console
$ sjon plugin test myplugin/plugin.sjon
ok  clean
FAIL missing-status — diagnostic 0 code mismatch: expected unknown_form, got missing_required_key

1 passed, 1 failed
```

Fix either the schema or the expectation until green. `--dir=PATH`
points somewhere other than `tests/`. Because expectations pin `(code,
severity, path)` — not message prose — they survive wording changes,
exactly like the corpus itself.

---

## 13. Diagnostics gallery

When something is wrong, the validator emits diagnostics with
spans (so editors can underline) and stable codes (so tools can
match without depending on prose). Here are the eight you'll
see most while writing.

| Code | Message looks like | What's wrong | Fix |
| --- | --- | --- | --- |
| `unknown_form` | unknown form `wibble` | The head doesn't match any plugin. | Typo? Missing plugin? Check `(qualified/head)` if there's a namespace. |
| `unknown_key` | unknown keyword `:width` in form `canvas` | The key isn't declared on this form. | Typo, or use a sibling key. Try `:w` instead of `:width`. |
| `duplicate_key` | duplicate keyword `:bpm` in form `scene` | Same `:k` appears twice. | Remove or rename the duplicate. |
| `missing_required_key` | form `circle` is missing required keyword `:radius` | A required key isn't present. | Add it. |
| `dependent_key_missing` | form `entry` keyword `:offset` requires `:buffer`, which is absent | A key you wrote demands sibling keys you didn't. | Add the named keys, or drop the one that needs them. |
| `positional_not_allowed` | form `circle` does not accept positional children | Form is declared `positional = none`. | Wrap the child in the right key, or move it under a parent that allows children. |
| `wrong_underlying` | form `scene` keyword `:bpm` expects number, got string | Slot's value type doesn't match. | Look at the slot's declared type; convert the value. |
| `arity_mismatch` | expression `lerp` expects exactly 3 argument(s), got 2 | Wrong argument count to an expression. | Add or remove arguments. |
| `ambiguous_form` | form `verb` is ambiguous — defined by [a, b]; qualify with `<ns>/verb` | Two plugins both own the bare head. | Use `a/verb` or `b/verb`. |

A few more that show up around the keyword-pairing rule (§7):

- `expr_kvpair_not_allowed` — you wrote `:k v` inside an
  expression function that does not declare labeled parameters.
- `expr_unknown_label` / `expr_duplicate_label` /
  `expr_missing_label` / `expr_mixed_args` — a labeled expression
  call has the wrong labels or mixes positional and labeled
  arguments.
- `not_member` — a symbol or string isn't in the slot's
  closed-set list. Re-check the plugin's enum.
- `not_head_member` — a form's head isn't in the slot's
  allowed list (HeadSet). Use one of the pinned heads.
- `positional_too_many` — more positional children than a head-set
  ceiling allows: the head's `:max`, or the set's `:max-children`.
  Reported on the child that crossed it: delete or merge it, or raise the
  bound. Fires once per crossing, so the count in the message is the real
  total.
- `positional_missing` — fewer than a floor requires, a head's `:min` or
  the set's `:min-children`. Reported on the parent form's head, since
  there's no child to point at: add the missing child, or lower the
  bound. Neither code is silenced by `:open true`. For both, a message
  naming a bracketed set rather than one head is the set-level bound
  speaking; when both levels would fire, only the per-head one does.
- `unit_required` / `unit_not_allowed` — the slot's `UnitShape`
  either requires a suffix you omitted (bare `90` when the slot
  wants `90deg`) or rejects the suffix you supplied (`90%` when
  only `[deg, rad]` are allowed). Unit-suffix mismatches go
  here, not `wrong_underlying` — the latter is reserved for the
  case where the underlying kind is wrong (e.g., string instead
  of number).
- `default_eval_failed` — an omitted key has an expression default,
  but the active host could not evaluate it.
- `lowering_hook_missing` / `lowering_hook_failed` — the schema says a
  form must be lowered by a host hook, but the host cannot run that
  hook successfully.

The full list of diagnostic codes is in
[`LANGUAGE.md` §7.6](LANGUAGE.md). Codes are stable across host
implementations; messages are not — match on the code if you're
building tooling.

---

## 14. Quick reference

### Tokens

```
(  )                    ; form
[  ]                    ; vector
:keyword                ; keyword (a name with a leading `:`)
symbol                  ; symbol (a name without a leading `:`)
123  -1.25  1e9         ; numbers
4b  90deg  50%          ; numbers with unit
2026-05-22              ; date
12:34:56.789            ; time
"…"   """…"""           ; strings (escape / raw)
true  false  nil        ; reserved literals
;       …               ; line comment
#|      …      |#       ; block comment
```

All identifiers (keywords, symbols, heads) are **case-sensitive**:
`:bpm` ≠ `:BPM`, `circle` ≠ `Circle`.

### Value kinds (the closed eleven)

```
nil   boolean   number   number_with_unit   date   time
string   keyword   symbol   vector   form
```

### Built-in expression vocabulary (`core`)

```
arithmetic     + - * / mod
comparison     < <= > >= = !=
logical        and or not                  ; and/or short-circuit
vectors        vec2 vec3 vec4
math (basic)   lerp clamp min max dot cross length
math (ext.)    abs sign floor ceil round fract
               sqrt pow
               sin cos tan asin acos atan atan2
               radians degrees
constants      pi tau                      ; 0-arity: (pi) (tau)
smoothing      saturate step smoothstep    ; WGSL conventions
vector ops     normalize distance reflect
list ops       nth count
random         hash rand01 rand-range rand-int rand-bool rand-choice
                                           ; seeded SplitMix64; pure & deterministic
control        let if cond
binders        map filter any all fold
```

Domain errors (e.g. `(sqrt -1)`, `(asin 2)`) propagate IEEE 754
`NaN`. No `MathDomain` error code; expressions stay total over `f64`.

### Bare vs qualified head

```
(circle …)              ; bare — works iff one plugin owns "circle"
(shapes/circle …)       ; qualified — never ambiguous
```

### The keyword pairing rule

```
:k v          ; v is a value of any kind except keyword → kvpair
:k :other     ; `:k` is a positional flag, `:other` becomes the new pending
:k            ; (frame closes) → :k is a positional flag
```

A keyword can never be the value of a kvpair. Use a symbol or a
string instead.

### Symbol vs string vs keyword in a slot

```
(camera :projection ortho)    ; symbol value
(camera :projection "ortho")  ; string value
(camera :projection :ortho)   ; keyword flag, not a kvpair value
```

### Where to look next

- [`LANGUAGE.md`](LANGUAGE.md) — the formal spec. Every claim in
  this document is paraphrased from there; reach for it when you
  want exhaustive detail (encodings, lifetimes, edit operations,
  extensibility).
- [`examples/`](../examples/) — runnable scenes:
  `basic.sjon`, `with-expressions.sjon`, `wgsl-shader.sjon`,
  `webgpu-render-pipeline.sjon`, `plugins/shapes-scene.sjon`.
  Each is meant to parse and validate cleanly under its documented
  schema.
- [`examples/plugins/README.md`](../examples/plugins/README.md) —
  if you've crossed over into wanting to **define** your own
  forms, expression functions, or value kinds, start there.
- [`examples/llm/`](../examples/llm/) — SJON packaged for a model:
  a paste-into-context `PRIMER.md`, nine worked write→validate→repair
  flows, and a token-efficiency receipt versus JSON + JSON Schema. All
  goldens are gated by `zig build llm-pack-verify`.
- [`manifests/meta.sjon`](../manifests/meta.sjon) — the meta-schema
  for portable plugin manifests, written in SJON. Hosts can load
  these manifests to provide validation and tooling vocabulary;
  ordinary `.sjon` documents do not import them.

### Exporting your plugin's schema

Once you have a working plugin (whether a static `.zig` literal or a
manifest like `examples/plugins/double/plugin.sjon`), you can hand
its schema off to downstream tools — TypeScript projects, codegen
pipelines, JSON Schema validators in other ecosystems — without
making them re-implement the SJON parser. Run:

```
sjon export-schema mydoc.sjon --target=both --output=./gen
```

This writes `./gen/schema.json` (JSON Schema 2020-12) and
`./gen/types.d.ts` (TypeScript declarations) describing the canonical
JSON shape of `sjon to-json --canonical` output. The schema is
**lossy on semantics JSON Schema can't enforce** — cross-references,
expression evaluation, source-order rules — and embeds an
`x-sjon-export-warnings` block listing where it falls short. See
[`SCHEMA_EXPORT.md`](SCHEMA_EXPORT.md) for the full mapping table,
the lossiness budget, and worked examples.

### Calling the exporter from your application

If your tooling pipeline already runs in Node, Rust, or TypeScript,
you can skip the CLI and call the exporter directly:

- **Node** — `import { SjonHost } from "./hosts/web/SjonHost.ts"` →
  `host.exportSchema(source, { target, layout })` returns the same
  envelope the CLI prints, JSON-decoded.
- **Rust** — `sjon_host::SjonHost::export_schema(source, &options)`
  returns a serde-deserialized `ExportSchemaResult` with typed
  `aggregated` / `per_plugin` artifact slots.
- **TypeScript-parity** —
  `exportSchema(source, hostOpts, exportOpts)` from
  `hosts/typescript-parity/src/Host.ts` is the native port (no WASM
  needed).

See [`SCHEMA_EXPORT.md` § Calling the exporter](SCHEMA_EXPORT.md#calling-the-exporter)
for full code samples per host.
