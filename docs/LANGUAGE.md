# SJON — A Substrate for Symbolic Data and Safe Expressions

A reference outlook for an S-expression substrate that pairs deterministic
symbolic data with a closed, evaluator-bounded expression vocabulary, all
extended through comptime-aggregated plugins and equipped with two
equivalent encodings (JSON and a hand-rolled binary IR).

This document is a description of what the language *looks like* and
*means* to an author. Implementation choices — the SoA AST layout, the
labeled-switch lexer, the iterative parser, the WASM artifacts, the
binary cursor's monotonic walk — are deliberately out of scope. Those
live in [`DESIGN.md`](DESIGN.md).
The contracts in this document hold regardless.

For a hands-on, example-first tutorial — syntax, common patterns,
the v1 expression vocabulary, and reading plugin schemas — see
[`AUTHORING.md`](AUTHORING.md). This file remains the normative spec.

---

## 1. Purpose and shape

SJON is a substrate. It does not describe a domain; it gives domains a
uniform surface to describe themselves on. A program is:

- A flat list of **roots** — top-level values, usually one **form**, but
  any number of forms or other values is permitted.
- Each form is a constructor `(<head> <child> ...)` whose meaning is
  determined by a **schema** assembled at compile time from one or more
  **plugins**.
- Inside a value position, a parenthesised form whose head is in the
  closed **expression vocabulary** is a **safe expression** rather than
  data.

```sjon
(scene :bpm 130
  (canvas :name "main"
    (camera :ortho :zoom (* 2 (b 1)))
    (stack :mode :mask
      (shape :sdf :radius 0.5
        :delay (delay :p+s (b 4))
        :lifespan (b 16))
      (shape :path :points [[0 0] [1 0] [1 1]]))))
```

SJON is for: scene descriptions, configuration, structural editing,
domain-specific languages that need a Lispy carrier with first-class
keyword arguments and bounded inline arithmetic — anywhere "tagged tree
of named slots, with a little safe math" is the right abstraction.

SJON is *not*: a general-purpose language. There are no first-class
functions, no closures, no I/O, no mutable state, no recursion at the
language level, no runtime side effects. Every safe expression is pure;
every form is a constructor whose semantics belong to whichever plugin
declared it.

SJON closes several sets — value kinds, expression vocabulary, JSON
discriminators, binary tags, edit operations. The closures are what
make a SJON document parseable and validatable from a static read of
the source: a runtime knows the entire vocabulary before any document
loads. The argument for each closure, the route by which the language
extends across spec versions rather than at user code, and the things
SJON still chooses not to extend at all, live in §14.

The substrate's encodings preserve substrate semantics — but with
different fidelity per channel. Canonical text and **lossless**
binary IR (every trivia flag on) are *structurally bijective*: round
trip through the binary preserves not just values but spans,
comments, and the exact source order of kvpairs and positionals.
Canonical JSON is *semantically* equivalent only — same kinds,
payloads, key→value mapping per form, and positional sequence, but
the interleaving of kvpairs with positional children is normalised
on the wire (see §9.2). The full per-encoding guarantees are stated
alongside each in §9–§10.

### 1.1 At a glance

Six lines that fit the whole substrate before the reference begins:

1. **A document is a tree of eleven value kinds** — `nil`, `boolean`,
   `number`, `number_with_unit`, `date`, `time`, `string`, `keyword`,
   `symbol`, `vector`, `form` (§3). Everything else in this
   document either names one of these or describes how they
   compose.
2. **A form is `(<head> child ...)`** — the head names a
   constructor; children are positional values, kvpairs `:k v`, or
   nested forms. Vectors `[a b c]` are positional-only (§5).
3. **Plugins define the heads** — *data form* heads (`canvas`,
   `circle`, `scene`) come from `FormSpec`s; *expression* heads
   (`+`, `lerp`, `let`) come from `ExprFunc`s. The schema is the
   comptime union of every loaded plugin's heads (§6).
4. **Keywords pair greedily with the next non-keyword token** — so
   `(stack :mode :mask)` parses as **two positional flags**, not
   `mode = :mask`. To express keyword-like data as a value, use a
   symbol or wrap in a vector (§5.4).
5. **Expressions are pure, bounded, and closed** — no I/O, no
   mutation, no recursion; the v1 vocabulary is a small fixed set
   (arithmetic, comparison, logical, vectors, math, smoothing, list
   ops, seeded random, control flow); the evaluator caps depth,
   frames, and steps (§8).
6. **Two encodings ride alongside the text** — JSON for
   interchange (canonical mode round-trips with semantic
   equivalence, not byte equality — see §9.2; lossy mode collapses
   for human reading), binary IR for runtime/lossless consumption
   with per-channel trivia flags (§9, §10).

If you only read those six lines, you can navigate the rest of this
spec; every later section is the long version of one of them.

---

## 2. Lexical foundation

### 2.1 Forms, vectors, and tokens

Two paired delimiters:

- `( ... )` — a **form**: head identifier + tail. The head names the
  constructor that the form represents. The schema (§6) decides what
  constructor that is.
- `[ ... ]` — a **vector**: ordered list of values. Used for points,
  polylines, palettes, anywhere "an ordered tuple of values" is the
  right shape. Vectors are values; forms are constructors.

Whitespace is insignificant. Tabs, spaces, carriage returns, and
newlines are equivalent and skipped silently.

### 2.2 Comments

```
; line comment to end of line
;; conventionally for section headings
#| block comment, may span lines |#
```

Comments are first-class lexical tokens. The parser attaches each
comment to the nearest following structural node as **leading trivia**,
or — when no following node exists in the surrounding container — as
**trailing trivia** on the container itself. Block comments do not
nest. Comments survive every lossless round-trip (lossless print mode,
binary IR with the comment flags set, and structural edits outside the
affected subtree). They do not survive canonical print, canonical
JSON, or stripped binary.

### 2.3 Identifiers

A bare identifier — used as a symbol, a form head, or after a leading
`:` as a keyword — is one or more characters drawn from the following
classes. Most classes may appear in any position; a few are restricted
to non-leading positions, as noted:

```
letters       a-z A-Z
digits        0-9                      ; allowed after the first char
underscore    _
operators     + * / < > = ! ? . % & | ^ ~ $ @
hyphen        -                        ; only if not the first char of a number
hash          #                        ; only after the first char (see below)
slash         /                        ; namespacing — see §5.3
```

A leading `-` followed by a digit starts a number. A leading `-`
followed by anything else is a symbol character.

A leading `#` is reserved: at the start of a token `#|` opens a block
comment (§2.6) and any other `#…` is invalid. Inside an identifier
already in progress, `#` is part of the symbol — so `C#4`, `F#m`, and
`Bb3` all lex as single identifiers, which is what enables natural
sharp-note spellings in closed-`:members` kinds.

There is no escape mechanism inside an identifier.

Three identifiers are reserved to literals: `true`, `false`, and
`nil`. The lexer emits them as their own token kinds; they are not
symbols.

### 2.4 Keywords

A `:` followed by an identifier is a **keyword**. Keywords carry
meaning by name; they do not carry numeric or string content. Their
two roles — as the *key* in a `:key value` pair and as a *flag* value
in their own right — are decided by the parser per §5.4.

```
:bpm        :ortho       :p+s
:zoom       :mode        :name
```

A keyword's name follows the identifier rules in §2.3.

### 2.5 Strings

Two surface forms, one value kind:

- **Escape-quoted** `"…"` — the common case. Recognised escapes:
  `\\`, `\"`, `\n`, `\t`, `\r`, `\u{NNNN}` (1–6 hex digits). Unknown
  backslash sequences are a parse diagnostic; the parser still emits
  a string node so editors can render under-construction code.
- **Triple-quoted raw** `"""…"""` — body taken verbatim. No escape
  processing, no dedent. Reach for it when escape-quoting would
  clutter the payload: literal `\` or `"` bytes (paths, regex,
  HTML/XML, embedded code). Both forms accept literal newlines, so
  multi-line content alone is *not* a reason to use `"""…"""`.

```
"plain"
"foo \"bar\""
"unicode: \u{2728}"

"""@vertex
fn vs() -> @builtin(position) vec4f { return vec4f(0.0); }
"""

"""C:\path\to\file"""        ; backslash is literal
"""she said "hi" today"""    ; single quotes are content
```

The decoded value of a `"""…"""` body is the bytes between the
delimiters, exactly. Putting the opening `"""` alone on a line means
the first byte of content is `\n`; put the body on the same line to
avoid that.

**Greedy closer.** Three consecutive `"` end the token, so a body
cannot end with a literal `"` immediately before the close and cannot
contain three consecutive `"` at all. For those payloads, fall back to
`"…"` with `\"` escapes. (No hash-padded raw form like Rust's
`r#"…"#` today.)

Both forms produce the same `string` AST kind with byte-identical
decoded content; equality is form-blind, so `"""hello"""` equals
`"hello"`. Round-trip behavior — including the one bit of string
trivia SJON does not yet preserve — is covered in §4.2.

### 2.6 Numbers and units

A number is an optional leading `-`, an integer or fractional decimal
representation, optional decimal exponent, optional unit suffix. The
unit suffix is one or more ASCII letters, or a single `%`, immediately
following the numeric portion with no intervening whitespace.

```
0           1           -3
0.5         -1.25       2.
1e9         1.5e-10     1.5e+2
4b          90deg       50%        250ms       1.5e2hz
```

Underscores may appear inside the numeric portion as digit grouping;
they are stripped before parsing (`1_000_000` parses as `1000000.0`).
The numeric portion is parsed to IEEE-754 `f64`. The unit, when
present, is opaque metadata: SJON does not interpret it, does not
convert between units, does not enforce a unit grammar beyond "ASCII
letters or a single `%`". Plugins (§6) and downstream consumers
choose which units they accept.

**Exponent vs. unit ambiguity.** `e` and `E` start an exponent only
when the very next character is a digit or sign. Otherwise, `e`
starts a unit suffix. So `1em` lexes as one number-with-unit token
(value `1`, unit `em`), while `1e9` lexes as the number `1e9` and
`1.5e+2hz` lexes as the value `150` with unit `hz`. The disambiguation
rule is fixed: it does not depend on schema, plugin, or context.

**Adjacent unit numbers.** `90deg5px` lexes as two tokens
(`90deg`, `5px`), the same way `12foo` lexes as `.number .symbol`.
Use whitespace to separate adjacent numeric values when the
ambiguity would otherwise matter.

### 2.7 Reserved tokens

The lexer recognises a small fixed set of tokens. There are no
reserved identifiers beyond `true` / `false` / `nil`; everything else
gets its meaning from the parser (`(`, `)`, `[`, `]`, `:` prefix) or
the schema (form heads, expression heads, value kinds).

The lexer is *total*: every byte sequence yields some token stream,
possibly including `.invalid` tokens. It never panics and never
allocates. The parser owns every diagnostic the lexer surfaces.

---

## 3. Values

A *value* is anything that may appear where the parser expects a
piece of data — at the document root, inside a vector, as a `:key`'s
paired value, or as a positional child of a form. SJON's value
vocabulary is a **closed set of eleven kinds**:

| Kind | Examples | Section |
| --- | --- | --- |
| `nil` | `nil` | §3.1 |
| `boolean` | `true`, `false` | §3.1 |
| `number` | `0`, `-1.25`, `1e9` | §3.2 |
| `number_with_unit` | `4b`, `90deg`, `50%`, `250ms` | §3.2 |
| `date` | `2026-05-19`, `0001-01-01`, `9999-12-31` | §3.2.1 |
| `time` | `12:34:56`, `23:59:59.999` | §3.2.2 |
| `string` | `"hello"` | §3.3 |
| `keyword` | `:ortho`, `:p+s` | §3.4 |
| `symbol` | `bounce`, `parent.transform`, `+` | §3.5 |
| `vector` | `[1 0 0 1]`, `[[0 0] [1 0]]` | §3.6 |
| `form` | `(scene :bpm 130 …)` | §3.7 |

Forms in value position split into two roles by their head — *data
form* or *safe expression* — covered in §3.7 and developed in §5
(forms) and §8 (expressions).

The vocabulary is closed. Adding a new value kind is a substrate-
level change (§14), not an extension. Plugins refine kinds by
declaring **value kinds** (§6.4) — typed names like `length` or
`point` that constrain an underlying kind — but they do not introduce
new kinds.

### 3.1 nil and booleans

```
nil
true
false
```

`nil` is the sole inhabitant of its kind; it is the explicit
"absence" value. `true` and `false` are the booleans. None of the
three may carry payload, units, or attributes — they are atoms by
identity.

In safe expressions, `nil` is falsy and so is `false`; every other
value is truthy (§8).

### 3.2 Numbers

A number value carries an `f64` magnitude. A `number_with_unit` value
additionally carries a non-empty unit suffix as opaque bytes (the
exact slice the lexer captured). The two are distinct kinds:

```
0           ; number
0.5         ; number
4b          ; number_with_unit, unit "b"
50%         ; number_with_unit, unit "%"
250ms       ; number_with_unit, unit "ms"
```

A unit-bearing number and a unitless number are *not interchangeable
as values*. They print differently, encode differently in canonical
JSON (§9), occupy distinct binary tags (§10), and a value-kind
declaration may require or forbid units (§6.4). When a plugin's
expression function wants to interpret a unit (e.g. `(b 4)` →
seconds), it does so through its own logic — the substrate carries
the unit slice forward without inspecting it.

#### 3.2.1 Dates

A *date* is a calendar position — proleptic Gregorian `(year, month,
day)`, no time of day, no time zone. The lexical form is strict ISO
8601 calendar form: exactly ten ASCII characters `YYYY-MM-DD`, with
leading zeros required.

```
2026-05-19    ; Tuesday, 19 May 2026
0001-01-01    ; min (year 0 is excluded)
9999-12-31    ; max
2024-02-29    ; leap day
```

The 4+2+2 shape gates date recognition at lex time: a stream like
`1900-1899` lexes as `1900`, `-`, `1899` (two numbers and a sign),
never as a date — the lookahead requires the `[0-9][0-9]-[0-9][0-9]`
trailer. Leading sign, 5+ digit years, single-digit months / days,
and underscores anywhere in the lexeme all fall back to the
unrelated number / symbol paths.

Component validity is parser-enforced. Year is clamped to
`[1, 9999]` (year 0 disallowed by ISO 8601); month to `[1, 12]`;
day to `[1, daysInMonth(year, month)]`, with February 29 valid iff
the year is a Gregorian leap year (`y % 4 == 0 and (y % 100 != 0 or
y % 400 == 0)`). Out-of-range components emit `date_invalid_year`,
`date_invalid_month`, or `date_invalid_day` (§7.6) and a defaulted
`0001-01-01` node, mirroring the parser's collection-over-abort
contract.

Equality is by `(year, month, day)`. Dates do **not** participate in
the cross-variant numeric collapse used by the integer / float
tags — `Value.date` only compares equal to another `Value.date`.

#### 3.2.2 Times

A *time* is a clock position — `(hour, minute, second, millisecond)`,
no date, no time zone, no leap seconds. The lexical form is strict
ISO 8601 clock-time form: either eight characters `HH:MM:SS` or
twelve characters `HH:MM:SS.fff`, with leading zeros required and
the fractional `.fff` carrying exactly three digits when present.

```
12:34:56          ; mid-afternoon
00:00:00          ; min
23:59:59.999      ; max
12:34:56.789      ; with millisecond precision
12:34:56.000      ; canonicalises to 12:34:56
```

The 2+2+2 shape gates time recognition at lex time: a stream like
`12:34` (missing seconds) lexes as `12`, `:34` (a number followed by
a kwarg-shaped keyword), never as a time — the lookahead requires
the `[0-9][0-9]:[0-9][0-9]` trailer. The fractional tail is
*all-or-nothing*: `12:34:56.1` lexes as the 8-char prefix `12:34:56`
followed by `.1` as a number, because the fractional must be exactly
three digits.

Component validity is parser-enforced. Hour is clamped to `[0, 23]`
(`24:00:00` is rejected — older ISO 8601 profiles allowed it as an
"end of day" marker, but the substrate keeps the invariant simple);
minute and second to `[0, 59]` (no leap-second slot — the substrate
has no UTC concept). Millisecond range is enforced at the lexer
level: exactly three digits trivially compose to `[0, 999]`.
Out-of-range hour/minute/second components emit `time_invalid_hour`,
`time_invalid_minute`, or `time_invalid_second` (§7.6) and a
defaulted `00:00:00.000` node, mirroring the parser's
collection-over-abort contract.

The canonical print form is *shortest*: an 8-char render when the
millisecond is zero, a 12-char render otherwise. Both the SJON
printer and the JSON emitter apply this rule, so a parsed
`12:34:56.000` round-trips byte-for-byte to `12:34:56`.

Equality is by `(hour, minute, second, millisecond)` — exact
component match. Times do **not** participate in the cross-variant
numeric collapse used by the integer / float tags — `Value.time`
only compares equal to another `Value.time`, even though `45296` is
the second-of-day for `12:34:56`.

### 3.3 Strings

A string value carries the *decoded* UTF-8 bytes between its
delimiters (§2.5). Both the escape-quoted `"…"` form and the
triple-quoted raw form `"""…"""` produce the same kind — the surface
form is a lexical convenience that does not survive into the value.

For escape-quoted strings, the value is the escape-resolved bytes.
For raw strings, the value is the verbatim bytes between the
delimiters — no escapes, no newline stripping, no dedent. Two strings
with byte-equal decoded content compare equal regardless of which
form authored them.

Strings are opaque to the substrate. Plugins decide what a string
means in any given slot (filename, label, colour name, shader
source, etc.).

### 3.4 Keywords

A keyword value carries its name, without the leading `:`. Keywords
are compared by name; two keywords with the same name are equal
regardless of where they were lexed.

In the parser's pairing rule (§5.4), a keyword token may serve
either as a *key* (left side of a `:key value` pair) or as a *value*
in its own right (a "flag"). The pairing decision is structural,
not lexical: the same `:ortho` token is a flag in `(camera :ortho)`
and a key in `(camera :ortho 2)`.

Keywords are intentionally distinct from symbols and strings:

- A keyword names a slot or a discrete option (`:mode`, `:loop`).
- A symbol names something else in the schema (a form head when in
  head position, a variable reference when in expression position).
- A string is opaque payload.

The trichotomy is preserved across canonical encodings (§9).
Lossy modes collapse keywords and symbols to bare strings; the
distinction is one-way lost.

### 3.5 Symbols

A symbol value carries an identifier (§2.3) that did not match a
reserved literal and was not preceded by `:`. Symbols mean nothing
to the substrate by themselves — they are looked up by whichever
context consumes them:

- As a form's head, the symbol is the constructor name (§5).
- Inside a safe expression, the symbol is a variable reference
  (resolved against the evaluator's environment, §8).
- As a value in a slot, the symbol is opaque text the consuming
  plugin can interpret as it wishes.

A symbol may contain a single `/`; when both sides are non-empty,
the parser splits the symbol into a **namespace** and a **name**
(§5.3). The split applies only to *form heads* — symbols in value
position are not split.

### 3.6 Vectors

`[ ... ]` is a vector. Vectors carry an ordered list of values of
any kind, including nested vectors and forms:

```
[]                        ; empty vector
[1 2 3]                   ; numbers
[[0 0] [1 0] [1 1]]       ; vector of 2-vectors — a polyline
[:loop :ping-pong]        ; vector of keywords
["red" "green" "blue"]    ; vector of strings
[(rgb 1 0 0) (rgb 0 1 0)] ; vector of forms
```

Vectors do not carry keyword children. A `:keyword` token inside `[
... ]` is itself a value of kind `keyword`; it does not pair with
the next element.

A plugin may shape a slot's expected vector via `ValueKind`'s
`VectorShape` (§6.4) — pinning element kind and optionally length,
so that `(camera :pos [0.5 1.0])` can be type-checked as a 2-vector
of numbers. The substrate enforces no shape by default.

### 3.7 Forms

`(<head> <child> ...)` is a form. Forms split into two roles by their
head:

- **Data forms** — heads that match a `FormSpec` in the active
  schema (§6). The form's children are parsed under the constructor's
  rules and the validator (§7) type-checks each child against the
  spec.
- **Safe expressions** — heads that match an `ExprFunc` in the active
  schema (§6.5, §8). The form is evaluable in any value position
  through `evalExpr`.

The same shape — `(name child ...)` — covers both roles. The role
is decided at consumption time by looking the head up in the schema:
constructors win when both registries name the same head (a name
collision between a `FormSpec` and an `ExprFunc` is a schema-
construction error, surfaced at compile time when plugins are
aggregated).

A form's children preserve **source order**. The parser pairs
keywords with their values per §5.4; the resulting child list
contains *positional* values and *kvpair* nodes intermixed in the
order the author wrote them. Consumers walk the child list to
recover the author's intent. The text printer and the binary IR
preserve this ordering verbatim; canonical JSON normalises
kvpair-vs-positional interleaving on round-trip (see §9.2).

### 3.8 Equality

Two values are equal when they have the same kind and equal payload.
`number` equality is IEEE-754 (`NaN ≠ NaN`); `number_with_unit`
equality additionally requires byte-equal unit slices. Vector
equality is per-element, recursive. Form equality is structural —
same head, same namespace, same children in the same order, including
keyword pairs by key and value. Comments, spans, and trivia do not
participate in equality.

`Tag.toValueKind` (in `Ast.zig`) is the canonical projection from a
layer-specific tag enum to the abstract `ValueKind` vocabulary above.
Every layer (AST, Binary, BinaryCursor) shares this vocabulary; the
layer-specific tag enums are *refinements* — for example, `Ast.Tag`
splits `boolean` into `boolean_true` / `boolean_false` for storage,
and adds `kvpair` for the parser's structural pairing. The shared
vocabulary is what lets a SJON document round-trip across encodings
without losing kind.

---

## 4. Documents

A SJON document is a sequence of zero or more **roots**. Each root is
a value of any kind — typically a single form, but vectors, atoms,
and even bare numbers are valid documents. There is no required
preamble, no `module` wrapper, no header form. The substrate is
unopinionated about whether your document carries one root or many.

```sjon
; Single-root document — the common case.
(scene :bpm 130
  (canvas :name "main"
    (shape :sdf :radius 0.5)))
```

```sjon
; Multi-root document — fixtures, palettes, batched configurations.
(layer :name "background" :z 0)
(layer :name "midground"  :z 1)
(layer :name "foreground" :z 2)
```

```sjon
; Atomic document — also valid.
42
```

The number of roots is preserved across the JSON bridge through
`toJsonRoots` / `fromJsonRoots` (§9.4); single-root documents have a
shorter `toJson` / `fromJson` path.

### 4.1 Top-level rules

The top level is a container, like a vector or a form, with one
narrowing: **keyword pairs are not permitted as roots**. A `:key
value` pair at the top level emits a diagnostic — `"keyword pair at
top level (expected inside a form)"` — and the parser still produces
a tree (with the `:key` node followed by its `value` node, both as
positional roots) so editors can render the under-construction
document. Standalone keywords (without a paired value) are valid
roots — they're values of kind `keyword`.

The other top-level constraints are mechanical:

- An unmatched closing delimiter (`)` or `]`) at the top level emits
  `"unexpected close delimiter at top level"` and is dropped.
- An unclosed delimiter at end-of-input emits `"unclosed delimiter
  at end of input"` once per still-open frame, and the parser closes
  each frame implicitly so the tree finalises cleanly.
- Comments at the top level become **tree-trailing trivia** when
  no following root absorbs them as leading trivia. They survive the
  lossless round-trip.

### 4.2 Trivia and round-tripping

Two kinds of trivia ride alongside the structural tree: **comments**
and **spans**. Both survive a lossless round-trip but are dropped by
canonical print and canonical JSON.

| Trivia | Where it lives | Survives canonical text | Survives canonical JSON | Survives lossless binary |
| --- | --- | --- | --- | --- |
| Leading comments | per-node | no | no | yes (with `with_node_comments`) |
| Trailing comments | per-form | no | no | yes (with `with_node_comments`) |
| Tree-trailing comments | per-tree | no | no | yes (with `with_tree_trailing_comments`) |
| Kvpair comments | per-kvpair | no | no | yes (with `with_kvpair_comments`) |
| Spans | per-node, per-head, per-key | no | no | yes (with `with_spans` / `with_head_spans` / `with_kvpair_key_spans`) |
| String form (`"…"` vs `"""…"""`) | per-string-node | no | no | no (deferred) |

The binary IR exposes one flag per trivia channel and groups them
into three presets (§10.2): `compact` clears every flag, `canonical`
(the default) keeps the three span flags on but clears the comment
flags, and `lossless` (alias `full`) sets every flag. Spans are
default-on because validator diagnostics, editor cursor mapping, and
language-server features all depend on them; comments are default-off
because nothing downstream of an emitter consumes them. See §10.2
for the rationale and per-bit table.

**String-form preservation is deferred.** Every print mode emits
escape-quoted `"…"`, so a triple-quoted source round-tripped through
lossless binary comes back as escape-quoted text. The decoded bytes
are identical (`"""hello"""` and `"hello"` are the same value), so
nothing observable is lost — only the author's choice of delimiter.
The mechanics for preserving it are sketched (one bit per string
node, one binary IR flag in the reserved space, one printer branch);
the work is gated on a real use case rather than shipped ahead of
demand. Until then, `"…"` is the only form any SJON tool will hand
back.

### 4.3 Diagnostics and partial trees

The parser is **total** — it always returns a tree. Every malformed
construct becomes a `Diagnostic` attached to the tree, and the parser
recovers structurally and continues. The tree may be empty or partial,
but it is well-formed: every form has a head string (possibly empty),
every kvpair has a key and a value, every vector has its element
list. `tree.hasErrors()` is the predicate for "did the parser surface
any diagnostics."

This is a deliberate substrate choice. Editor integrations consume
`Tree`s in real time, character by character; aborting on the first
malformed token would make the tree unusable until the author finishes
typing. SJON's contract is that every byte sequence parses to *some*
tree, and diagnostics travel alongside that tree for downstream UI.

The substrate caps depth and frame growth to bound the parser's work:

- `MAX_PARSE_DEPTH = 1024` — maximum nesting of forms and vectors.
  Reaching this emits `"nesting too deep"` and stops the parse cleanly.
- `Binary.MAX_TREE_DEPTH = 1024` — equal to the parser cap by a
  comptime assertion, so a binary tree never decodes deeper than
  the parser would accept.

Authors will not encounter these limits in practice; they exist as
guards against pathological input.

### 4.4 Lifetime and ownership

Every parsed `Tree` is **arena-owned**: a single `ArenaAllocator`
backs the node arrays, the string pool, the comment text, and the
diagnostics list. `tree.deinit()` releases everything in one
operation. The same convention applies to every public output
(`Json.Result`, `Validator.Result`, `Expr.Result`, `Bytes`): each
bundles its allocator with its data and exposes `.deinit()`.

A tree's `source` field borrows the original source slice. When the
caller intends to free the source before the tree, they must clone
into the tree's arena first. Comment text is always dup'd into the
tree's arena, so a tree survives the source buffer for trivia
lookups; spans, however, refer back to the original source by
byte offset, and are meaningless once the source is freed.

---

## 5. Forms

Forms are the workhorse of SJON. Every constructor — domain or
expression — is `(<head> <child> ...)`. This section covers the
structural rules; what each constructor *means* lives with the
plugin that defines it (§6).

### 5.1 Head

The head is the first significant token after the opening `(`. It
must be one of:

- A **symbol** (§3.5).
- A **reserved literal** — `true`, `false`, or `nil`. The literals
  are accepted here for parser regularity; whether `(true ...)` is a
  meaningful constructor depends on whether the schema declares it.
- A **closing `)`** — yields the empty form, with diagnostic
  `"empty form: expected head symbol after `(`"`. The form's head
  string is empty; downstream consumers see it as a structural
  placeholder.

Anything else (a number, a string, a keyword, a vector, a nested
form) emits `"expected head symbol after `(`"` and the parser opens
a form anyway, with an empty head, attaching the offending token as
the form's first child. The tree remains well-formed.

### 5.2 Children

After the head, a form holds zero or more children. Each child is
either a **value** (any of the eleven kinds — §3) or a **kvpair**
(`:key value`, materialised structurally per §5.4). Children appear
in source order; the parser does not reorder them. (Canonical JSON
normalises kvpair-vs-positional interleaving on round-trip — see
§9.2. The text printer and binary IR preserve order verbatim.)

```sjon
(camera                      ; head: camera
  :ortho                     ; positional flag (keyword as value)
  :zoom 2                    ; kvpair: zoom=2
  :pos [0 1]                 ; kvpair: pos=[0 1]
  (group :name "main"))      ; positional child: a nested form
```

A form may carry both kvpairs and positional children freely
intermixed. Schemas (§6) decide what each form accepts.

### 5.3 Namespaces

A form's head may be **qualified** with a `<namespace>/<name>`
prefix:

```sjon
(masagin/verb …)         ; qualified — masagin's verb constructor
(shapes/canvas …)        ; qualified — shapes plugin's canvas
```

The `/` separator splits the head into namespace and name when
*both sides are non-empty*. Specifically:

- A leading `/` (`/foo`) is part of an operator-like symbol; no
  split occurs. The head is `/foo`.
- A trailing `/` (`foo/`) is treated as part of the head; the
  validator may flag it. No split occurs.
- Multiple `/` characters: the *first* `/` is the separator, the
  rest belong to the name. So `a/b/c` splits as namespace `a`,
  name `b/c`.

When the head splits, the namespace serves as a **disambiguator**
for the schema lookup (§6.2). When it does not split, the schema
resolves the head as a **bare** name — accepted iff exactly one
plugin claims it.

The same head may appear bare and qualified for the same
constructor:

```sjon
(verb …)                 ; bare — only valid when one plugin owns "verb"
(masagin/verb …)         ; qualified — always valid when masagin defines "verb"
```

Authors generally write bare forms for compactness and qualified
forms when collision is possible across plugins. The validator
flags an ambiguous bare head (two plugins both define it) and
suggests qualifying.

### 5.4 Keyword pairing — the greedy rule

The parser's pairing rule for `:key` tokens is *greedy with
single-token lookahead*:

1. When the parser sees a `:key` token, it stashes it on the
   current frame's `pending` slot.
2. The next non-keyword token consumed by the frame becomes the
   value of the pending key, and a `kvpair { key, value }` joins
   the child list.
3. If a *second* `:key` token arrives while a `pending` is set,
   the earlier `:key` is committed as a **positional flag** — a
   plain keyword value in the child list — and the new `:key`
   becomes the new `pending`.
4. If the frame closes while a `pending` is set, the pending key
   is committed as a positional flag.

This is the masagin convention: `(camera :ortho :zoom 2)` parses
as one positional flag `:ortho` followed by one kvpair
`zoom=2`. Authors write keywords compactly; the parser figures
out which is a flag and which is a key.

```sjon
(stack :mode :mask)
; → pending=:mode; sees :mask; second :key, commits :mode as flag,
;   :mask becomes new pending; frame closes, :mask becomes flag.
; Children: positional :mode, positional :mask.
```

> [!IMPORTANT]
> **A keyword can never be the value of a kvpair.** The greedy rule
> always promotes a `:keyword` in value position to a positional
> flag, even when the author "obviously meant" pairing.
>
> `(stack :mode :mask)` parses as **two positional flags**, *not*
> `mode = :mask`. If you want keyword-like data as a value, use a
> symbol (`(stack :mode mask)` → `mode = mask`) or wrap it in a
> vector (`(stack :modes [:mask])` → `modes = [:mask]`). Strings
> work too (`:mode "mask"`) but lose the closed-vocabulary feel.

```sjon
(stack :mode "mask")
; → pending=:mode; sees "mask"; pairs as kvpair mode="mask".
; Children: kvpair mode="mask".
```

```sjon
(camera :ortho :zoom 2 :pos [0 1])
; → :ortho pending; :zoom arrives, :ortho becomes positional flag,
;   :zoom pending; sees 2, kvpair zoom=2; :pos pending; sees [0 1],
;   kvpair pos=[0 1].
; Children: positional :ortho, kvpair zoom=2, kvpair pos=[0 1].
```

A manifest can constrain *which* positional flags a form accepts via
`:positional (flag-set …)`; a flag outside the declared set validates as
`not_flag_member` (see portable-manifest-v1.md §5). Without a flag-set,
positional flags are unconstrained.

### 5.5 Reading a form's children

A consumer walks a form's child list to recover author intent.
Two access patterns:

- **By key** — find the kvpair whose key matches a given name. The
  schema's `KeySpec.optional` field decides whether absence is an
  error. **Duplicate keys** (the same `:k` appearing twice on the
  same form) emit a `duplicate keyword \`:k\` in form \`name\``
  diagnostic — schema-independent, so it fires on open forms too
  (`spec.open` relaxes closed-shape sweeps; kvpair lists carry map
  semantics regardless). A validated tree
  therefore never carries duplicates. For unvalidated trees, the
  canonical recovery rule is "first match wins" because the parser
  preserves source order.
- **By position** — iterate positional children (skipping kvpairs)
  in order. The schema's `FormSpec.positional` field decides
  whether positional children are accepted at all (`.none`),
  accepted untyped (`.any`), or accepted as a typed sequence
  (`.kind = "<value-kind-name>"`).

Both `Validator` and `Expr` walk forms with this two-pattern
discipline. Plugins that want both styles in the same form declare
keys for the keyword-addressable slots and `.positional = .any` (or
`.kind = …`) for the rest.

### 5.6 Forms as values vs. forms as expressions

Because forms can play two roles — data constructor (§3.7,
resolved through `FormSpec`) or safe expression (§8, resolved
through `ExprFunc`) — the consumer's job is to look the head up in
the schema and dispatch accordingly. The substrate offers two
facilities for this:

- `Validator.validate(tree, schema)` walks the tree once, classifying
  every form by its head and emitting diagnostics for unknowns,
  ambiguous bare heads, type mismatches, missing required keys, and
  unknown keys on closed forms.
- `Expr.evalExpr(tree, node, env, schema)` evaluates a single value
  position — typically the value side of a kvpair — by treating
  forms as expressions when their head appears in `expr_funcs`, and
  as opaque data otherwise.

Form heads are looked up case-sensitively against `name` in
`FormSpec` and `ExprFunc`. The schema-aggregation step rejects a
plugin set in which a single bare name appears in both registries
across two plugins — that would be ambiguous.

---

## 6. Schema and plugins

The current plugin-layer contract lives in
[`docs/plugin-model-v1.md`](plugin-model-v1.md). This section describes
the descriptor shape that both static Zig plugins and portable manifests
materialize into.

The substrate parses and prints SJON without knowing what any form
*means*. Meaning comes from a **schema** assembled at compile time
from one or more **plugins**. The validator (§7) and the expression
evaluator (§8) consult the schema to resolve every form head, every
keyword name on a form, and every typed slot.

```zig
const sjon = @import("sjon");
const core = sjon.plugins.core;            // built-in expression vocabulary
const shapes = @import("shapes.zig");      // a domain plugin

const schema = sjon.Schema.init(&.{ core.plugin, shapes.plugin });
```

In the static Zig path, a schema is a comptime descriptor — a slice of
`Plugin.Plugin` values walked by the validator and evaluator. There is
no runtime registration, no hot-loaded Zig code, and no late-binding
host-native hook on that path. The host pipeline can also materialize
portable manifests into the same `Plugin.Plugin` shape before validation.

### 6.1 Plugin

Every plugin declares three vocabularies, each independently
optional:

```zig
pub const Plugin = struct {
    name: []const u8,                        // namespace token (`shapes`, `masagin`, …)
    forms: []const FormSpec = &.{},          // data-form constructors
    expr_funcs: []const ExprFunc = &.{},     // safe-expression functions
    value_kinds: []const ValueKind = &.{},   // typed value refinements
};
```

Convention:

- The `core` plugin (built in) ships only `expr_funcs` — it owns the
  closed v1 expression vocabulary (§8).
- Domain plugins (`shapes`, `masagin`, `pngine`, …) live in their
  own repos. They declare `forms` and may declare `value_kinds` and
  domain-specific `expr_funcs`.
- A plugin's `name` is its namespace prefix in qualified form heads
  (`(masagin/verb …)`). Every plugin must have a non-empty name.

Plugin descriptors are *static*. Every `[]const u8` field is intended
to be a string literal or otherwise long-lived; the schema borrows
references and copies nothing.

### 6.2 FormSpec — declaring a constructor

Each `FormSpec` is one entry in a plugin's `forms` slice:

```zig
.{
    .name = "canvas",
    .description = "Drawing surface. Positional children are shapes.",
    .keys = &.{
        .{ .name = "w",  .value_type = .{ .named = "length" } },
        .{ .name = "h",  .value_type = .{ .named = "length" } },
        .{ .name = "bg", .value_type = .string },
    },
    .positional = .any,
    .open = false,
}
```

The fields:

| Field | Meaning |
| --- | --- |
| `name` | Bare head as it appears in source (`(canvas …)`). |
| `keys` | Allowed `:keyword value` slots. Validator emits a diagnostic for any unknown key on a closed form. |
| `positional` | Whether positional children are accepted. See §6.3. |
| `open` | When `true`, the form is treated as an extensible bag: unknown keys are accepted silently and closed-shape completeness/cardinality sweeps are skipped. Useful for forms acting as raw bags during prototyping. |
| `description` | Free-text help string surfaced by editor tooltips. |

A form's keys are looked up by name. The order of keys in the spec
is preserved in tooling output but does not constrain the order in
which authors write them.

#### 6.2.1 Exclusive groups — keys that constrain each other

A form may declare `(exclusive-group …)` sub-forms to require that one
group of keys is mutually exclusive. Each group has a `:cardinality`
(`exactly-one` or `at-most-one`) and two or more `(alt …)`
alternatives. Each alt names one or more keys; the alt is "present"
when **every** key it names is set on the form.

```sjon
(form :name route
  (key :name from :type symbol :optional true)
  (key :name to   :type symbol :optional true)
  (key :name at   :type symbol :optional true)
  (exclusive-group :cardinality exactly-one
    (alt :keys [from to])           ; multi-key bundle: both required together
    (alt :keys [at])))              ; single-key alt
```

Single-key alts (`(alt :keys [at])`) behave like the simple "exactly
one of these keys" pattern. Multi-key alts (`(alt :keys [from to])`)
are **all-or-nothing bundles**: the bundle counts as present iff every
key in it is set. The verbose `:keys` shape is the only authoring
syntax — there is no compact `[from to]` sub-vector form.

**Diagnostics.**

| Code | When |
| --- | --- |
| `mutually_exclusive_keys_present` | Two or more alts are fully present on the same form / variant. |
| `required_one_of_missing` | `cardinality = exactly-one` and no alt is present. |
| `exclusive_bundle_partial` | A multi-key alt has some-but-not-all keys present and no sibling alt is fully present. Single-key alts never trigger this code. |
| `multiple_defaulted_alternatives_in_group` | Schema admits more than one default-only resolution path. |
| `exclusive_group_invalid` | Manifest-time: group has fewer than two alts, names an undeclared key, names the discriminant, or shares a key across two different groups. |
| `exclusive_bundle_collision` | Manifest-time: one key name appears in two alts of the **same** group. The cross-group case still emits `exclusive_group_invalid`. |

The runtime is group-aware on defaulted keys — a defaulted alt only
participates in the presence count when no sibling is fully
author-present (see §7.8 for the materialization boundary).

### 6.3 KeySpec and PositionalSpec

A `KeySpec` declares one keyword-addressable slot:

```zig
pub const KeySpec = struct {
    name: []const u8,                        // bare keyword name, no leading `:`
    value_type: ValueType = .any,            // expected type; default = unconstrained
    optional: bool = true,                   // false = required; absence is a diagnostic
    default: ?Default = null,                // fallback for omitted optional keys; see §7.8
    description: []const u8 = "",
    local_forms: []const FormSpec = &.{},    // slot-local forms (only on .form slots); see below
};
```

A non-null `default` makes the key *effectively optional* regardless of
the `optional` flag — the validator skips `missing_required_key` for
that slot. `Default` is a small union covering literal values
(`number` / `string` / `symbol` / `boolean` / `nil` / `vector` of those)
and one `expression` arm that retains a one-root Binary IR program
for the runtime materialization pass. Effective-value semantics live
in §7.8.

`PositionalSpec` declares the form's stance on positional children:

```zig
pub const PositionalSpec = union(enum) {
    none,                                    // no positional children allowed
    any,                                     // any number, untyped
    kind: []const u8,                        // any number, each must match named ValueKind
    flag_set: []const []const u8,            // positional keyword flags; each must be in the set
};
```

A form with `.positional = .none` declared keys but no positional
children — the typical "named-argument record" pattern. A form with
`.positional = .any` is a container — `(group :name "main" child1
child2 …)`. A form with `.positional = .kind = "shape"` constrains
the positional children to a typed sequence. A form with
`.positional = .flag_set` accepts only positional keyword flags drawn
from the listed names (`(task :done)`); an out-of-set flag is
`not_flag_member` and a non-keyword positional is `wrong_underlying`
(see portable-manifest-v1.md §5).

#### 6.3.1 Slot-local forms

A `.value_type = .form` slot may carry its own inline `FormSpec`s in
`local_forms`, scoping a set of one-off form shapes to that slot:

```sjon
(form :name canvas
  (key :name shape :type form
    (form :name circle (key :name r :type number :optional false))
    (form :name rect   (key :name w :type number :optional false))))
```

A form value in such a slot resolves **local-first, then additively**:

1. A *bare* head matching a local form's name validates against that
   local spec in place — a local **shadows** a same-named global form.
2. A bare head matching no local falls back to the global
   `Schema.lookupForm` catalog (the slot stays open to any global form).
3. A bare head matching *neither* is `unknown_local_form`, emitted at the
   **slot** path (e.g. `[canvas shape]`) and listing the local names; the
   generic `unknown_form` is suppressed for that node.

A **qualified** head (`ns/circle`) deliberately bypasses locals (which are
bare-named) and resolves global-only, so its terminal miss is the ordinary
`unknown_form`. Locals are honoured only on `.form` slots, validate their
contents with the full machinery (`missing_required_key`, `unknown_key`,
discriminant/variant, exclusive groups — a local may itself be
discriminated and nest further `local_forms`), and nest no deeper than
`Plugin.MAX_LOCAL_FORM_DEPTH`. A local head is **invisible** to global
lookup — it exists only inside its slot. Contrast with `HeadSet` (§6.5),
which *narrows* a slot to a closed set of **global** form heads by
byte-equality; slot-local forms instead *add* slot-scoped, anonymous form
bodies on top of the global catalog.

### 6.4 ValueType — what a slot accepts

`ValueType` is the validator's per-slot type vocabulary. It is closed:

```zig
pub const ValueType = union(enum) {
    any,                                     // escape hatch; no checks
    number,
    string,
    symbol,
    boolean,
    nil,
    vector,                                  // any vector, untyped elements
    form,                                    // any nested form
    expr,                                    // safe-expression form
    named: []const u8,                       // reference to a plugin-defined ValueKind
};
```

Two notable absences:

- **`keyword`** is intentionally absent. The greedy pairing rule
  (§5.4) means a kvpair value can never be a keyword — a `:k1 :k2`
  sequence promotes `:k1` to a positional flag instead. There is no
  way to express "a kvpair value of kind keyword" in source, so the
  validator declines to model one. Plugins wanting an "atom value"
  use `.symbol` (`(scene :mode loop)` → `mode=loop`) or wrap a
  keyword in a vector (`[:loop]`).
- **`number_with_unit`** is not a separate `ValueType`. `.number`
  accepts **both** unitless `Tag.number` and unit-bearing
  `Tag.number_with_unit` — a slot typed `.number` accepts `4` *and*
  `4b`, with no unit check either way. To constrain unit presence,
  refine via a `ValueKind` with a `UnitShape` (§6.5):
  `UnitShape.required = true` rejects bare numbers,
  `UnitShape.required = false` accepts both, and a non-empty
  `UnitShape.allowed = &.{ … }` restricts which unit suffixes are
  legal. The validator's "tag mismatch" check (§7.4) treats
  `.number_with_unit` as compatible with the `.number` slot type —
  it is not a mismatch.

### 6.5 ValueKind — typed refinements

`ValueKind` is how a plugin declares a *named type* — `length`,
`point`, `duration`, `colour` — that other slot declarations
reference by name (`.value_type = .{ .named = "length" }`).

```zig
pub const ValueKind = struct {
    name: []const u8,
    underlying: Underlying,                  // number | string | vector | form | symbol | union_of
    description: []const u8 = "",
    vector: ?VectorShape = null,             // refines .vector underlying
    unit: ?UnitShape = null,                 // refines .number underlying
    numeric: ?NumericBounds = null,          // refines .number underlying
    members: ?MemberSet = null,              // refines .symbol or .string underlying
    heads: ?HeadSet = null,                  // refines .form underlying
    cross_ref: ?CrossRef = null,             // refines .symbol from validated forest names
    union_of: ?UnionShape = null,            // refines .union_of alternatives
    string_bounds: ?StringBounds = null,     // refines .string underlying
    repr: ?Repr = null,                      // refines .number underlying (GPU representation tag)
};

pub const Underlying = enum { number, string, vector, form, symbol, union_of };

// GPU machine type a downstream emitter encodes the number as.
pub const Repr = enum { f32, u32, i32, u16, f16 };

pub const VectorShape = struct {
    len: ?u16 = null,                        // fixed element count; null = any. Excludes min_len/max_len.
    min_len: ?u16 = null,                    // inclusive floor on element count (variable arity); null = no floor
    max_len: ?u16 = null,                    // inclusive ceiling on element count (variable arity); null = no ceiling
    element: []const u8,                     // element kind name (or "number"/"string"/...)
};

pub const UnitShape = struct {
    required: bool = false,                  // true = bare number rejected (a unit is demanded)
    reject: bool = false,                    // true = any unit suffix rejected (bare numbers only); excludes required/allowed
    allowed: []const []const u8 = &.{},      // empty = any non-empty unit accepted
};

pub const NumericBounds = struct {
    min: ?Bound = null,                      // inclusive unless exclusive_min
    max: ?Bound = null,                      // inclusive unless exclusive_max
    exclusive_min: bool = false,
    exclusive_max: bool = false,
    integer: bool = false,                   // reject fractional / non-finite values

    pub const Bound = struct {
        value: f64,
        unit: ?[]const u8 = null,            // bound carries a unit suffix
        exact_int: bool = false,             // literal was Tag.number_i64 / number_u64
    };
};

pub const StringBounds = struct {
    min_len: ?u32 = null,                    // inclusive UTF-8 codepoint count
    max_len: ?u32 = null,                    // inclusive UTF-8 codepoint count
    pattern: ?[]const u8 = null,             // raw pattern source (v1: informational)
    format: ?Format = null,                  // named, closed format

    pub const Format = enum { email, uri, path, uuid, semver };
};

pub const MemberSet = struct {
    members: []const Member,                 // closed set; byte-equality on Member.name

    pub const Member = struct {
        name: []const u8,                    // bare identifier (no leading `:`)
        label: []const u8 = "",              // editor-facing display label
        description: []const u8 = "",        // editor-facing help string
        deprecated: bool = false,            // true ⇒ warning on use (deprecated_member)
        deprecation_message: []const u8 = "",// optional replacement hint
    };
};

pub const HeadSet = struct {
    names: []const []const u8,               // closed set of allowed form heads; byte-equality
};

pub const CrossRef = struct {
    target_form: []const u8,                 // forms contributing names
    name_key: []const u8 = "name",           // symbol-valued name key on each target
    acyclic: bool = false,                   // true = reject cycles over self-edge keys
    scope_form: ?[]const u8 = null,          // null = whole forest; non-null = lexical scope form
};

pub const UnionShape = struct {
    alternatives: []const []const u8,        // named kinds or primitive shortcuts
};
```

The `Underlying` set is closed at five concrete value shapes plus
`union_of`, which delegates to named alternatives. Those are the
places where plugin-declared refinement is meaningful. `boolean`,
`keyword`, and `nil` are intentionally absent: their cardinality is fixed
(`true`/`false`; "the keyword *is* its name"; one inhabitant), so
there is no refinement axis. `symbol` is included because closed-set
enumeration via `MemberSet` is the meaningful axis for symbols
(declaring `:projection :ortho|:perspective` and rejecting
`:oblique`).

Worked declarations:

```zig
// Length: any non-negative number.
.{ .name = "length", .underlying = .number,
   .description = "Non-negative scalar in canvas units." }

// Point: a 2-vector of numbers.
.{ .name = "point", .underlying = .vector,
   .vector = .{ .len = 2, .element = "number" },
   .description = "[x y] vector in canvas coordinates." }

// Duration: a number that *must* carry a time unit.
.{ .name = "duration", .underlying = .number,
   .unit = .{ .required = true, .allowed = &.{ "s", "ms", "b" } } }

// Opacity: a unitless number in [0, 1].
.{ .name = "opacity", .underlying = .number,
   .numeric = .{ .min = .{ .value = 0 }, .max = .{ .value = 1 } } }

// Iteration count: a positive integer.
.{ .name = "iteration-count", .underlying = .number,
   .numeric = .{ .min = .{ .value = 1, .exact_int = true }, .integer = true } }

// Colour: a 4-vector of numbers (linear RGBA).
.{ .name = "rgba", .underlying = .vector,
   .vector = .{ .len = 4, .element = "number" } }

// Projection mode: closed enum of two symbols.
.{ .name = "projection", .underlying = .symbol,
   .members = .{ .members = &.{ .{ .name = "ortho" }, .{ .name = "perspective" } } },
   .description = "Camera projection." }

// Colour space: closed enum of three string variants.
.{ .name = "colour-space", .underlying = .string,
   .members = .{ .members = &.{ .{ .name = "rgb" }, .{ .name = "yuv" }, .{ .name = "hsl" } } } }

// Slug: a non-empty lowercase identifier capped at 64 codepoints.
.{ .name = "slug", .underlying = .string,
   .string_bounds = .{ .min_len = 1, .max_len = 64,
                       .pattern = "^[a-z0-9-]+$" } }

// Email address: any string that looks like an email.
.{ .name = "email-address", .underlying = .string,
   .string_bounds = .{ .format = .email } }

// Semver string: any valid semver 2.0.0 textual representation.
.{ .name = "semver-string", .underlying = .string,
   .string_bounds = .{ .format = .semver } }

// Status: rich members with editor metadata.
.{ .name = "status", .underlying = .symbol,
   .members = .{ .members = &.{
       .{ .name = "draft",     .label = "Draft" },
       .{ .name = "published", .label = "Published" },
       .{ .name = "archived",  .deprecated = true, .deprecation_message = "Use hidden." },
   } } }

// Shape-form: closed set of allowed form heads (form-as-slot pinning).
.{ .name = "shape-form", .underlying = .form,
   .heads = .{ .names = &.{ "circle", "rect" } },
   .description = "(circle …) | (rect …) — narrows the slot's identity." }

// Phrase name: document-discovered symbol names from `(phrase :name ...)`.
.{ .name = "phrase-name", .underlying = .symbol,
   .cross_ref = .{ .target_form = "phrase", .name_key = "name" } }

// Pitch or event: one value may satisfy either named branch.
.{ .name = "note-or-event", .underlying = .union_of,
   .union_of = .{ .alternatives = &.{ "pitch", "event" } } }

// Channel: a number that must encode as a GPU u16 ([0, 65535], integral).
.{ .name = "u16-channel", .underlying = .number,
   .repr = .u16 }

// Viewport box: 4-to-6 numbers — variable arity, no fixed :len.
.{ .name = "viewport", .underlying = .vector,
   .vector = .{ .min_len = 4, .max_len = 6, .element = "number" } }

// Bare count: a unitless number — any unit suffix is rejected.
.{ .name = "bare-count", .underlying = .number,
   .unit = .{ .reject = true } }
```

`MemberSet` applies only to `.symbol` and `.string` underlyings.
`null` members means "no narrowing" (any value of the underlying).
An empty `members` slice is treated identically — plugin authors
should set `members = null` rather than supply `&.{}`. Member
comparison is byte-equality on `Member.name`; for `.symbol`
underlying the names are bare identifiers (no leading `:`).

Each `Member` carries optional editor metadata:

- `label` — a display string the LSP surfaces in completion `detail`.
- `description` — free-text help shown in completion `documentation`
  and hover.
- `deprecated` — when `true`, validation still succeeds but the
  validator emits a `deprecated_member` warning at the value's span
  and the LSP tags the completion item as deprecated (LSP
  `CompletionItemTag.Deprecated` — typically struck through).
- `deprecation_message` — appended to the warning's prose ("member
  `archived` is deprecated: Use hidden."). Empty = generic
  "is deprecated" prose.

Wire syntax for the rich form (`(member …)` positional children) lives
in `docs/portable-manifest-v1.md` §4.4; the compact `:values [...]`
shape is preserved unchanged for set-only declarations.

`HeadSet` applies only to `.form` underlying — the form-as-slot
pinning case (OpenAPI-style discriminator). The validator narrows
the slot to a closed set of allowed form heads (e.g. a `:shape`
slot that accepts only `(circle …)` or `(rect …)`). Comparison is
byte-equality on the head identifier as written; namespace
resolution is a host concern (the validator does not canonicalise
qualified vs. bare heads against the head-set). `null` heads means
"no narrowing" (any form head accepted), and an empty `names` list
is treated identically — set `heads = null` rather than supply
`&.{}`. Form values in slots whose kind has no `heads` continue
to defer to runtime evaluation (§7.4); HeadSet is the one
structural narrowing applied to forms.

`VectorShape.element` is itself a kind name. Resolution shortcuts the
primitive `ValueType` tags by reserved names (`"number"`, `"string"`,
`"symbol"`, `"form"`, `"any"`); any other name is resolved via
`Schema.lookupValueKind`. Recursion is bounded by `Schema.MAX_KIND_DEPTH = 8`,
which prevents cyclic kind references from looping forever.

`VectorShape` length is either **fixed** or **variable**, never both. A
fixed `:len N` demands exactly `N` elements (a short or long vector trips
`vector_length_mismatch`). Variable arity uses `:min-len` / `:max-len`
instead — both inclusive bounds on the element count, either omittable for
an open end. Too few elements fires `vector_too_short`; too many fires
`vector_too_long`. `:len` is mutually exclusive with `:min-len` / `:max-len`
(a fixed length already pins the count, so a range alongside it is
contradictory); the loader rejects the clash — and an inverted
`:min-len > :max-len` — with `vector_bounds_invalid` at manifest-load time.

`CrossRef` applies only to `.symbol` underlying. It changes a
symbol kind's legal set from manifest-declared members to names found
in the validated forest: every form resolving to `target_form`
contributes the symbol under `name_key`. With `scope_form = null`, the
registry is forest-wide. A scope form narrows it to the nearest
enclosing instance, so sibling scopes get independent registries.
`acyclic = true` asks the validator to reject cycles over keys on the
target form whose effective type resolves back to the same cross-ref
kind. Target, name-key, and scope resolution failures are schema
diagnostics; missing names, duplicates, out-of-scope uses, and cycles
are validation diagnostics (§7.6).

`UnionShape` applies only to `.union_of` underlying. Each alternative
is a value-kind name or the primitive shortcut `number`, `string`,
`symbol`, `vector`, `form`, or `any`. Alternatives are tried in
declaration order; the first full match accepts the value. If none
matches, validation emits `union_no_branch_matched` rather than
leaking every branch's inner diagnostics. A union alternative cannot
resolve to another union; aggregate validation emits `nested_union`
so dispatch stays a flat loop.

`scalar-or-ref` is a manifest-only **shorthand** over `UnionShape`, not a
sixth `Underlying`. Writing `:underlying scalar-or-ref` with a
`:scalar-or-ref (scalar-or-ref-shape :base <kind>)` slot desugars at load
time to `union_of` with alternatives `[<base>, symbol]` — so the stored
kind is an ordinary union and the validator, exporter, and every
downstream consumer inherit its behaviour for free. It captures the common
"a literal value *or* a bare-symbol reference to one defined elsewhere"
pattern: a value matching `<base>` takes the scalar alternative, a bare
symbol takes the `symbol` (reference) alternative, and anything else
falls through to `union_no_branch_matched`. `:underlying scalar-or-ref`
without the `:scalar-or-ref` slot — or a `:scalar-or-ref` slot on a
non-`scalar-or-ref` underlying — is rejected at manifest-load time with
`invalid_manifest`.

`UnitShape` applies only to `.number` underlying. Three keys:
`:required`, `:allowed`, `:reject`. `:required true` rejects a bare
`Tag.number` (`unit_required`); a non-empty `:allowed [s ms]` rejects a
`number_with_unit` whose suffix is outside the set (`unit_not_allowed`).
`:reject true` is the opposite pole — it forbids *any* unit suffix, so a
`number_with_unit` of any kind trips `unit_forbidden` and only bare numbers
pass. It closes the silent `1.0f → 0` GPU-backfill defect, where the lexer
reads the trailing `f` as a unit and a downstream emitter quietly drops it.
`:reject` is mutually exclusive with `:required` (which demands a unit) and
with a non-empty `:allowed` (which permits some) — the loader rejects either
combination with `invalid_manifest`.

`NumericBounds` applies only to `.number` underlying — orthogonal to
`UnitShape`. Five keys: `:min`, `:max`, `:exclusive-min`,
`:exclusive-max`, `:integer`. Inclusive by default; the
`:exclusive-min` / `:exclusive-max` booleans flip each end. The
loader emits `numeric_bounds_invalid` at manifest-load time when
the form is internally inconsistent — `:exclusive-min true` without
`:min`, `:min > :max` (when both share a unit), or `:numeric`
attached to a kind whose `:underlying` is not `number`.

Bound and value unit semantics (units are opaque per §2.6, no
canonicalisation):

- Bare-number bound + bare-number value → compare magnitudes.
- Bare-number bound + unit-bearing value → magnitude-only; the
  unit's correctness is `:unit`'s job, not `:numeric`'s.
- Unit-bearing bound + unit-bearing value → byte-equal units, then
  compare magnitudes. Mismatch fires
  `numeric_bound_unit_mismatch`.
- Unit-bearing bound + bare-number value →
  `numeric_bound_unit_mismatch`.

Comparison preserves exact precision when both bound and value
came from integer literals (`Tag.number_i64` / `Tag.number_u64`)
— the validator picks an integer-space comparison so the
2^53 + 1 vs 2^53 off-by-one isn't lost to f64 round-trip. Bounds
whose magnitude exceeds 2^53 still round to the nearest f64 in
storage; keep bounds whole numbers below 2^53 if exact precision
matters.

`:integer true` requires the value to be representable as an
integer. `Tag.number_i64` / `Tag.number_u64` are trivially
integer; `Tag.number` / `Tag.number_with_unit` must be finite
(`!NaN`, `!±inf`) and equal their floor. Negative-zero passes:
`@floor(-0.0) == -0.0` in IEEE-754.

`Repr` applies only to `.number` underlying — orthogonal to both
`UnitShape` and `NumericBounds`; all three may co-exist and each is
checked independently. Declared as `:repr (repr-shape :type <tag>)`, it
names the GPU machine type a downstream emitter encodes the number as,
drawn from the closed set `f32`, `u32`, `i32`, `u16`, `f16`. Each tag
carries an `(min, max, integer)` spec, and a value that doesn't fit trips
`repr_out_of_range` — *before* the emitter would silently wrap the bits:

| `:repr` | range | integral? |
| --- | --- | --- |
| `u16` | `[0, 65535]` | yes |
| `u32` | `[0, 4294967295]` | yes |
| `i32` | `[−2147483648, 2147483647]` | yes |
| `f32` | `[−f32max, f32max]` | no |
| `f16` | `[−f16max, f16max]` | no |

The integer tags reject a fractional literal (checked before range, so
`1.5` under `:repr u32` reports "not an integer" rather than a bound
miss); the float tags carry no integrality constraint. The check is
range-only — *precision* narrowing (e.g. `16777217` losing its low bit
under `f32`) is the emitter's accepted lossy step, not a validation
failure. The tag names are a wire-stable surface (they appear in the
schema export's `x-sjon-gpu-repr` annotation and the conformance corpus):
append-only, never reordered or renamed.

`StringBounds` applies only to `.string` underlying — orthogonal to
`MemberSet`. Four keys: `:min-len`, `:max-len`, `:pattern`, `:format`.
Length bounds are inclusive; `:min-len 0` and an absent `:min-len`
behave identically. The loader emits `string_bounds_invalid` at
manifest-load time when the form is internally inconsistent — empty
range (`:min-len > :max-len`), negative bound, empty `:pattern ""`,
or `:string-bounds` attached to a kind whose `:underlying` is not
`string`.

Length semantics:

- Measured in UTF-8 codepoints, not bytes. `"héllo"` is five
  codepoints (six bytes) and passes `:max-len 5`. The parser
  guarantees well-formed UTF-8, so `std.unicode.utf8CountCodepoints`
  is total here.
- No normalisation. Precomposed `"é"` (1 cp) and decomposed `"é"`
  (2 cp) count differently. A future opt-in `:normalize :nfc` on the
  bounds form is left open.

Format semantics — the `:format` symbol is drawn from a closed set:

- `email` — common-subset email shape (exactly one `@`, non-empty
  local part, dotted host). Not RFC 5321 strict.
- `uri` — RFC 3986 §3.1 scheme prefix (`<scheme>:<tail>` where the
  scheme starts with a letter and the tail is non-empty).
- `path` — non-empty, no NUL, no newline, no leading whitespace.
  Separator conventions vary per host, so the check stays liberal.
- `uuid` — RFC 4122 textual `8-4-4-4-12` hex with dashes at fixed
  positions (lower or upper case accepted).
- `semver` — SemVer 2.0.0 grammar (`MAJOR.MINOR.PATCH[-pre][+build]`,
  no leading zeros on numeric identifiers).

Unknown format names are rejected at manifest-load time (the meta-
schema's `string-format-tag` member-set gates entry). The set is
deliberately small for v1 — `date-time`, `ipv4`, `ipv6`, `hostname`,
and `json-pointer` are deferred until corpus demand justifies the
checker code; `date` and `time` already exist as first-class SJON
literal tags and do not need string-format duplication.

`:pattern` is accept-but-warn in v1. The loader stores the raw
pattern source and the validator emits `string_pattern_unsupported`
(a `.warning`) on every successful match against a kind whose
`:pattern` is set — the constraint is informational only because v1
builds carry no regex engine. The engine and the
`string_pattern_mismatch` emission land together in a follow-up
milestone; `:pattern` is already wire-stable so authors can declare
the constraint today and have it tighten silently once the engine
ships.

`MemberSet` and `StringBounds` may co-exist on the same `.string`
kind. The loader cross-checks at manifest load that every member
literal satisfies the declared bounds (length + format), so the
validator can apply members-or-bounds in either order without
divergence.

### 6.6 ExprFunc — declaring a safe-expression function

Each `ExprFunc` declares one function in the safe-expression
vocabulary:

```zig
pub const ExprFunc = struct {
    name: []const u8,                        // callable name (`+`, `lerp`, `vec3`, `b`)
    arity: Arity,
    description: []const u8 = "",
    impl: ?Impl = null,                      // null = declaration-only (validator-known, not callable)
    params: ?[]const ValueType = null,       // optional typed positional parameters
    param_names: ?[]const []const u8 = null, // full fixed-arity coverage enables labeled calls
    rest: ?ValueType = null,                 // optional variadic-tail type
    result: ?ValueType = null,               // declared result type — checked at validate-time when present
    signatures: ?[]const Signature = null,   // optional overload set; replaces mono fields above

    pub const Signature = struct {
        arity: Arity,
        params: ?[]const ValueType = null,
        param_names: ?[]const []const u8 = null,
        rest: ?ValueType = null,
        result: ?ValueType = null,
    };
};

pub const Arity = union(enum) {
    fixed: u8,                               // exactly N args
    at_least: u8,                            // N or more
    range: struct { min: u8, max: u8 },      // [min, max] inclusive
};
```

Three important properties:

- **Declaration without implementation** is a supported state. A
  plugin can register `(x.foo.catmull tension)` with `impl = null`
  so the validator recognises the form and reports arity errors,
  while the evaluator returns `error.PluginFuncNotImplemented` if
  someone actually evaluates it. This is how a plugin stages an
  expression function before committing to runtime semantics.
- **Labeled arguments are explicit opt-in.** A fixed-arity signature
  whose `param_names` covers every slot accepts either positional
  syntax `(lerp 0 10 0.5)` or labeled syntax
  `(lerp :from 0 :to 10 :t 0.5)`. Labeled calls may reorder slots,
  but a call is all-positional or all-labeled; mixing the styles emits
  `expr_mixed_args`. Unknown, duplicate, and omitted labels emit
  `expr_unknown_label`, `expr_duplicate_label`, and
  `expr_missing_label`. A `kvpair` AST child still emits
  `expr_kvpair_not_allowed` when the selected expression function has
  not opted into labels. A *bare* `:keyword` is a different thing:
  the greedy pairing rule (§5.4) promotes any keyword that cannot
  find a value into a positional flag, and that positional is a
  value of kind `keyword`. Bare keywords inside expressions evaluate
  to `Value.keyword`, which is what makes `(= mode :ortho)` and
  `(cond … :two-d)` work. See §8.1 for the full substrate-wide
  statement.
- **Typed signatures** (optional). When `params` / `rest` are set,
  the validator type-checks each positional argument against its
  declared type and emits a slot-style diagnostic on mismatch
  (`expression `vec3` argument 0 expects number, got string`).
  `params[i]` types the i-th fixed positional; `rest` types every
  trailing position past `params.len`. The opt-in shape preserves
  existing "expression args are untyped" behaviour for funcs that
  leave the fields null.

  The validator defers `.symbol` args to runtime (potential
  `let`-binding references). `.form` args are resolved as expressions:
  if the head's declared `:result` type matches the slot, the arg
  passes; if it conflicts, the validator emits a slot-style diagnostic
  before evaluation; if the head is opaque (no `:result`, or an
  ambiguous active overload candidate set), the arg defers like a
  symbol. Literal-tagged args (`.number`, `.string`, `.boolean`,
  `.vector`, `.nil`) are checked directly.
- **Overload sets** (optional). When `signatures` is non-null, each
  `Signature` owns its arity, parameter names, parameter types, rest
  type, and declared result; the mono fields above are ignored. The
  validator starts from the signatures that accept the call arity and
  narrows by labeled-slot resolution and argument type where those are
  statically known.

The control-flow functions (`let`, `if`, `cond`, `and`, `or`)
declare `impl = null` because the evaluator handles them with
dedicated frames rather than through `applyFunction`. They are not
"unimplemented" — they have stricter, lazier semantics that the
generic `Impl` signature cannot express. They also leave `params`
null (opaque signature) because their argument typing depends on
bindings or branch evaluation, neither of which the validator can
statically resolve.

### 6.7 Schema aggregation

`Schema.init` takes a slice of plugins and returns an aggregate view.
Lookup is uniform across the three vocabularies and uses a tri-state
result type:

```zig
pub fn LookupResult(comptime Hit: type) type {
    return union(enum) {
        found: Hit,
        not_found,
        ambiguous: Ambiguous,                // up to MAX_AMBIGUOUS = 16 claimants
    };
}
```

Lookup rules:

- **Bare** lookup — walk every plugin. Two or more matches across
  plugins yield `.ambiguous` with the list of claimants. Within-
  plugin duplicates resolve first-match (a plugin author's bug to
  fix; qualifying with a namespace doesn't help since they share
  one).
- **Qualified** lookup (`<ns>/<name>`) — select the plugin whose
  `name == ns`, then look up the name inside that plugin. If the
  namespace doesn't exist, or the name isn't in it, return
  `.not_found` immediately. Qualified lookups are *never* ambiguous.

The same shape and rules apply to all three lookups
(`lookupForm`, `lookupExprFunc`, `lookupValueKind`). Value-kind
references in manifests use the same `<plugin>/<kind>` syntax — a
form's `:type plugin/color`, a `(vector-shape :element plugin/color)`,
a `(positional plugin/color)`, and a `(union-shape :alternatives
[plugin/a plugin/b])` all split on the first interior `/`. Ambiguous
bare references surface a diagnostic with a `qualify with
`<plugin>/<name>`` recovery hint.

A bare head present in *both* a plugin's `forms` and its
`expr_funcs` is a plugin-author bug; the validator's lookup
precedence (§7.2) treats forms-first, expression-second, but the
validator itself flags this as a configuration error when it can.

---

## 7. Validation

Validation is the third pass after parse and schema construction.
Given a tree and a schema, the validator emits a list of
diagnostics: zero diagnostics means the tree's structure matches
the schema's declarations.

```zig
var tree = try sjon.parse(gpa, source);
defer tree.deinit();

var result = try sjon.validate(gpa, tree, schema);
defer result.deinit();

if (result.hasErrors()) {
    for (result.diagnostics) |d| { /* render d.message at d.span */ }
}
```

The validator is **iterative** (no recursion), **total** (always
returns a `Result`, never aborts on bad input), and **read-only on
the tree**. Diagnostics live in their own arena, separate from the
tree's arena, so they can be rendered after the tree is freed by
copying first.

### 7.1 What gets walked

The validator's stack walks every `form`, `vector`, and `kvpair` in
the tree depth-first. Atoms (numbers, strings, keywords, symbols,
booleans, nil) are skipped — there is nothing to look up. Forms
trigger head resolution (§7.2); kvpair values are visited so nested
forms inside them get their heads resolved too.

The roots of a multi-root document are walked in order, each
treated as an independent value at the top level.

### 7.2 Form-head resolution

For each form, the validator follows a fixed precedence:

```
head: <ns>/<name>?
    │
    ├── yes (qualified):
    │       schema.lookupForm(name, ns)
    │           ├── found      → validate keys + positional + types
    │           ├── ambiguous  → diagnostic
    │           └── not_found  → schema.lookupExprFunc(name, ns)
    │                              ├── found     → validate arity + expression args
    │                              ├── ambiguous → diagnostic
    │                              └── not_found → diagnostic ("unknown form ns/name")
    │
    └── no (bare):
            schema.lookupForm(name, null)
                ├── found      → validate keys + positional + types
                ├── ambiguous  → diagnostic ("form X is ambiguous; defined by [a, b, …]; qualify with `<ns>/X`")
                └── not_found  → schema.lookupExprFunc(name, null)
                                   ├── found     → validate arity + expression args
                                   ├── ambiguous → diagnostic
                                   └── not_found → diagnostic ("unknown form X")
```

Forms-first, expressions-second is deliberate. Domain forms tend to
outnumber expression heads in any real schema; checking forms first
keeps the diagnostic precise when an author writes a domain form
whose head accidentally collides with an expression function in the
plugin list.

A form whose head string is empty (the parser-recovery synthetic
form for `()`) is silently skipped — the parser already emitted the
diagnostic at parse time.

### 7.3 Validating keys and positional children

For a `FormSpec` hit, the validator walks the form's children:

- For each kvpair:
  - Look up the key in `spec.keys`. Unknown key on a closed form
    (`spec.open = false`) emits `"unknown keyword `:K` in form
    `F`"`.
  - On a known key, type-check the kvpair's value against
    `key.value_type` (§7.4). A mismatch emits a typed diagnostic
    naming the form, the slot, the expected type, and the actual
    value's category.
- For each positional child:
  - `.positional = .none` emits `"form `F` does not accept
    positional children"`.
  - `.positional = .any` accepts silently.
  - `.positional = .kind = "K"` type-checks the child against the
    named `ValueKind`.

After the walk, the validator checks that every `optional = false`
key appears at least once, emitting `"form `F` is missing required
keyword `:K`"` for each absent required key. Required-key tracking
caps at 64 keys per form (`Plugin.MAX_FORM_KEYS`). The cap is enforced
at *manifest load* time: a `(form …)` declaring more than 64 keys
emits `too_many_keys` against the form's `:name` and the loader
truncates the trailing keys so the post-load invariant
`spec.keys.len <= MAX_FORM_KEYS` holds. Validators (Tree and Binary
paths) `comptime`-assert this coupling on the required-key bitset, so
the bitset never silently aliases past index 63.

`spec.open = true` treats the form as an extensible bag. The validator
still performs schema-independent duplicate-key detection, declared-key
type checks, and typed positional-child checks (`:positional <kind>`),
but it skips closed-shape sweeps: unknown-key diagnostics,
missing-required-key diagnostics, missing-discriminant diagnostics,
exclusive-group diagnostics, and `:positional none` rejection. Open
forms intentionally have no notion of "complete." For example,
`(form :name bag :open true (key :name radius :type number))` still
rejects `(bag :radius "x")`, and `(bag :x 1 :x 2)` still emits
`duplicate keyword \`:x\` in form \`bag\`` because kvpair lists carry
map semantics regardless of openness. The relaxation covers
undeclared shape, not declared slots.

### 7.4 Type matching

`matchValueAgainstType(value_node, expected_type)` is the
type-checking primitive. Outcomes:

- **Tag mismatch** — the value's kind isn't compatible with the
  expected `ValueType` (e.g. expected `number`, got `string`). Emits
  a category-level diagnostic.
- **Vector shape mismatch** — expected a `VectorShape` of length
  `N` and element kind `K`; got a vector of length `M ≠ N` or an
  element of incompatible kind. The diagnostic carries the failing
  element's span.
- **Unit shape mismatch** — expected a `UnitShape`; got a unitless
  number when one was required, or a unit not in the `allowed` list.
- **Member set mismatch** — expected a `MemberSet` (closed enum on a
  `.symbol` or `.string` `ValueKind`); got a value of the right
  underlying that wasn't in the declared `values` list.
- **Form-head set mismatch** — expected a `HeadSet` (closed set of
  allowed form heads on a `.form` `ValueKind`); got a form whose
  head isn't in the declared `names` list. The diagnostic uses
  alternation prose (``form head `typo` not in set [point | rect]``)
  to distinguish the discriminator role from member narrowing.

A few deliberate concessions:

- `Tag.form` in a typed slot is classified before deferral. The
  validator looks the form's head up: data forms in a non-form slot
  surface `wrong_underlying` (or, for an `.expr` slot, the same code
  with prose distinguishing the role); expression heads with a
  declared `:result` get that result compared to the slot's expected
  type (mismatch ⇒ `wrong_underlying`, match ⇒ accept). Expressions
  without a declared result, or whose result is too coarse to prove
  the slot's refined named kind (a generic `.vector` result cannot
  satisfy a `vec3` length, a generic `.symbol` cannot satisfy a
  member-set, etc.), still defer to the evaluator. When the slot's
  `value_type` is `.form` directly, any form passes; when it resolves
  to a `.form`-underlying `ValueKind` with a `HeadSet`, the head text
  is checked against the allowed set.

Expression argument typing follows the same rules. When an
`ExprFunc` declares a typed signature (§6.6), each positional argument
is matched against its declared type. `.symbol` args still defer
(they may be `let`-binding references); `.form` args route through
the declared-result check above. Literal-tagged args (`.number`,
`.string`, `.boolean`, `.vector`, `.nil`) are checked statically. So
`(+ (vec3 1 2 3) 1)` now flags arg 0 at validate time with
`expr_type_mismatch`, while `(+ 1 (let [r 1] r))` validates clean
(the `let` is opaque, the eventual numeric value will be checked at
evaluation).
- `.any` accepts every value with no further check — the explicit
  escape hatch for plugins that want loose typing.

### 7.5 Diagnostics

Every diagnostic is `Ast.Diagnostic`:

```zig
pub const Diagnostic = struct {
    span: Span,                              // byte offsets into the source
    message: []const u8,                     // human-readable, allocated in result arena
    severity: Severity = .err,               // err | warning
    code: Code = .unspecified,               // stable, machine-matched (§7.6)
};
```

Most validator diagnostics are `.err`; warning codes exist for
non-fatal authoring signals such as `deprecated_member` and
`string_pattern_unsupported`. The shape is chosen to match LSP-style
editor integrations: every diagnostic has a span the editor can
underline and a message the editor can render in a tooltip.

Diagnostic strings name the offending construct precisely. Examples:

```
unknown form `wibble`
unknown form `masagin/verb`                  ; namespace miss
form `verb` is ambiguous — defined by [a, b]; qualify with `<ns>/verb`
unknown keyword `:width` in form `canvas`
duplicate keyword `:bpm` in form `scene`
form `circle` does not accept positional children
form `circle` is missing required keyword `:radius`
form `badge` keyword `:shape` expects `shape-form`, got form head `typo` not in set [circle | rect]
expression `lerp` expects exactly 3 argument(s), got 2
expression `+` does not accept keyword argument `:a`
```

### 7.6 Stable diagnostic code surface

`message` is host-flavoured: locale, capitalisation, and exact
phrasing are implementation choices, and downstream conformance
tooling **must not** assert on prose. The conformance anchor is the
`code` field — a stable, machine-matched enum value drawn from the v1
surface below. Every validator-emitted diagnostic carries a code.
Most structural parser recovery sites still default to `.unspecified`;
the exact-integer overflow, date-component, and time-component parser
diagnostics below are parser-side exceptions.

Codes are bare snake_case identifiers, grouped by failure family.
Adding a code is additive; renaming or removing one is a breaking
change for downstream conformance fixtures.

**Resolution** — head/key/value-kind name lookup outcomes.

| Code                          | Raised when                                                                                |
| ----------------------------- | ------------------------------------------------------------------------------------------ |
| `unknown_form`                | head not registered by any plugin                                                          |
| `unknown_local_form`          | a bare head in a `local_forms` slot (§6.3.1) matches no local form *and* no global form; reported at the slot path, suppresses `unknown_form` |
| `unknown_key`                 | kvpair key not declared on a closed form (`:open` silences this)                           |
| `ambiguous_form`              | form head resolves to ≥ 2 plugins; qualify with `<ns>/head`                                |
| `ambiguous_expr`              | expression head resolves to ≥ 2 plugins                                                    |
| `ambiguous_element_kind`      | `.named` value-kind reference resolves to ≥ 2 plugins                                      |
| `unknown_element_kind`        | `.named` reference targets an undeclared kind (a plugin-setup bug)                         |
| `recursion_depth`             | `.named` chain exceeds `Schema.MAX_KIND_DEPTH`                                             |
| `not_cross_ref`               | a symbol value isn't a registered name in the kind's `:cross-ref` registry (validate-time) |
| `duplicate_cross_ref_target`  | two forms in the same scope declare the same `(target, name)` pair (validate-time)         |
| `unknown_cross_ref_target`    | `(cross-ref :target X …)` declares `X` but no aggregated form is named `X` (load-time)     |
| `ambiguous_cross_ref_target`  | `:target` resolves to ≥ 2 forms (load-time)                                                |
| `cross_ref_name_key_unknown`  | `:name-key` doesn't appear on the target form, or its value type isn't `.symbol`           |
| `unknown_cross_ref_scope`     | `(cross-ref :scope X …)` names a form not in the schema                                    |
| `ambiguous_cross_ref_scope`   | `:scope` resolves to ≥ 2 forms                                                             |
| `cross_ref_outside_scope`     | a cross-ref symbol is used outside any enclosing `:scope` form (validate-time)             |
| `cyclic_cross_ref`            | a cycle of `:acyclic true` cross-ref edges among forest forms (validate-time)              |
| `acyclic_without_self_edge`   | `:acyclic true` declared on a kind whose target form has no key whose type resolves back   |

**Form-shape rules** — kvpair / positional integrity.

| Code                       | Raised when                                                                 |
| -------------------------- | --------------------------------------------------------------------------- |
| `duplicate_key`            | the same `:k` appears twice (kvpair lists are maps; emitted on `:open` too) |
| `too_many_keys`            | a `(form …)` declares more than `Plugin.MAX_FORM_KEYS` (= 64) keys at manifest-load time; trailing keys are truncated |
| `missing_required_key`     | a `:optional false` key is absent on a closed form                          |
| `positional_not_allowed`   | a positional child appears on a form whose `:positional` is `none`          |
| `expr_kvpair_not_allowed`  | an expression head that has not opted into labels receives a `:kw v` argument |
| `missing_discriminant_key` | a discriminated form omits its discriminant key                             |
| `unknown_discriminant_value` | a variant declaration names a value outside the discriminant member set    |
| `discriminant_not_closed_enum` | a discriminant does not resolve to a closed symbol member set            |
| `variant_key_collision`    | a key name appears in incompatible base or variant declarations             |
| `mutually_exclusive_keys_present` | two alternatives in one exclusive group are present                  |
| `multiple_defaulted_alternatives_in_group` | defaults alone select more than one exclusive alternative      |
| `required_one_of_missing`  | an `exactly_one` exclusive group has no present alternative                 |
| `exclusive_group_invalid`  | an exclusive-group declaration is malformed                                 |
| `exclusive_bundle_partial` | a multi-key exclusive alternative is only partly present                    |
| `exclusive_bundle_collision` | a key appears in two alternatives of one exclusive group                  |

**Type-level** — value-shape constraints (kvpair value, positional
kind, or typed-vector element).

| Code                      | Raised when                                                                  |
| ------------------------- | ---------------------------------------------------------------------------- |
| `wrong_underlying`        | value tag doesn't match the declared `ValueType` or the kind's `Underlying`  |
| `vector_length_mismatch`  | a typed-vector slot's fixed `:len` is not met                                |
| `vector_too_short`        | a variable-arity vector has fewer elements than its `:min-len`               |
| `vector_too_long`         | a variable-arity vector has more elements than its `:max-len`                |
| `unit_required`           | a bare `Tag.number` lands in a slot where `UnitShape.required` is true       |
| `unit_not_allowed`        | a `number_with_unit` carries a suffix not in `UnitShape.allowed`             |
| `unit_forbidden`          | a `number_with_unit` lands in a slot whose `UnitShape.reject` is true (bare numbers only) |
| `not_member`              | a symbol/string value is not in the kind's `MemberSet.members`               |
| `deprecated_member`       | a symbol/string value matched a `Member` whose `deprecated` is `true` (severity `warning`) |
| `not_head_member`         | a form value's head is not in the kind's `HeadSet.names`                     |
| `union_no_branch_matched` | a `union_of` value kind accepts none of its alternative kinds                |
| `nested_union`            | a `union_of` alternative resolves to another union                           |
| `number_below_min` / `number_above_max` | a numeric value crosses an inclusive bound                  |
| `number_at_or_below_exclusive_min` / `number_at_or_above_exclusive_max` | a numeric value crosses an exclusive bound |
| `number_not_integer`      | a numeric kind marked `:integer true` gets a fractional or non-finite value  |
| `repr_out_of_range`       | a number doesn't fit its `:repr` GPU type — out of range, or non-integral under an integer type |
| `numeric_bound_unit_mismatch` | a unit-bearing numeric bound cannot compare with the value's unit        |
| `numeric_bounds_invalid`  | a manifest numeric-bounds declaration is internally inconsistent             |
| `vector_bounds_invalid`   | a manifest vector-shape declaration is internally inconsistent (`:min-len > :max-len`, or `:len` mixed with `:min-len`/`:max-len`) |
| `string_too_short` / `string_too_long` | a string codepoint count crosses its declared length bound      |
| `string_format_mismatch`  | a string fails its declared `email`, `uri`, `path`, `uuid`, or `semver` format |
| `string_pattern_mismatch` | reserved for a future regex-backed pattern mismatch                          |
| `string_pattern_unsupported` | a declared string pattern is informational in a build without regex support (severity `warning`) |
| `string_bounds_invalid`   | a manifest string-bounds declaration is internally inconsistent              |

(`:cross-ref` registry / scoping / acyclic codes are listed under
**Resolution** above — they fire against names, not value shapes.)

A typed-vector element that fails its element-kind check carries the
**leaf** code, not a wrapping container code: `(paint :color [1 "x"
3])` against an `rgb` (vector of number, len 3) emits
`wrong_underlying` for the `"x"` element. The Tree path's internal
`MatchFail.element_at` recurses into the leaf code so Tree + Binary
agree on the wire-level identifier even though Tree currently spans
the whole vector while Binary spans the offending element.

**Defaults** — materialization-phase failures (§7.8).

| Code                  | Raised when                                                                                                          |
| --------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `default_eval_failed` | an expression default's retained program failed at materialization time (unknown/unimplemented head, unbound symbol, plugin runtime failure, malformed program). Path shape: `[<form-head> <key-name> default]`. One diagnostic per schema key per validation result, regardless of how many form instances omit it. |

**Expression** — expression-vocabulary rules.

| Code                  | Raised when                                                          |
| --------------------- | -------------------------------------------------------------------- |
| `arity_mismatch`      | wrong number of arguments to an expression head                      |
| `expr_type_mismatch`  | typed expression argument fails its `params`/`rest` constraint       |
| `expr_unknown_label`  | a labeled expression call uses a label outside the selected signature |
| `expr_duplicate_label` | a labeled expression call repeats a label                          |
| `expr_missing_label`  | a labeled expression call omits a declared required label            |
| `expr_mixed_args`     | a call mixes positional and labeled expression arguments             |

`expr_type_mismatch` is distinct from the kvpair-side codes above on
purpose: a downstream consumer that wants to ignore typed-expression
diagnostics (e.g. while a plugin is mid-migration to typed signatures)
can filter on the code without false positives on data-form slot
failures. Typed-signature opt-in is per-`ExprFunc`; opaque heads
(`let`, `if`, `cond`, polymorphic vector funcs, …) emit only
`arity_mismatch`.

**Manifest, plugin, and project loading** — host-side setup outcomes.

| Code | Raised when |
| --- | --- |
| `invalid_manifest` | the meta-schema rejects a manifest declaration |
| `unresolved_plugin` | a `(use-plugin ...)` reference resolves to no manifest or WASM bytes |
| `plugin_version_mismatch` / `plugin_hash_mismatch` | resolved plugin bytes fail a version constraint or hash pin |
| `duplicate_plugin_name` | two project plugin entries resolve to the same manifest name |
| `plugin_name_mismatch` | a named `(use-plugin ...)` resolves to a manifest with a different `:name` |
| `project_file_not_found` | an explicit project root has no `sjon-project.sjon` |

**Executable plugin runtime** — WASM binding and dispatch outcomes.

| Code | Raised when |
| --- | --- |
| `plugin_abi_mismatch` | a plugin exports an ABI version the host does not implement |
| `plugin_export_missing` | a manifest names a `wasm:*` implementation export absent from its binary |
| `plugin_import_forbidden` | a plugin binary declares an import outside the v1 allowlist |
| `plugin_wasm_required` | a manifest needs a WASM implementation but the resolver supplied no WASM bytes |
| `plugin_describe_invalid` | reserved for the self-describing plugin path |
| `plugin_func_trapped` | WASM expression dispatch traps |
| `plugin_func_result_type` | a plugin result conflicts with its declared expression result type |
| `plugin_func_failed` | a plugin reports a structured expression failure |
| `plugin_func_alloc_failed` | a plugin allocator export cannot reserve its argument frame |

**Lowering** — host-owned form lowering failures.

| Code | Raised when |
| --- | --- |
| `lowering_hook_missing` | a lowering contract names no registered host hook |
| `lowering_hook_failed` | a registered lowering hook returns failure |
| `lowering_produced_invalid_head` | a hook emits a head outside its declared `produces` set |
| `lowering_produced_lowerable_head` | a single-pass lowering hook emits another lowerable form |
| `lowering_output_too_large` | emitted lowering output crosses form, depth, or byte limits |

**Parser literal codes** — stable parser exceptions to the general
`.unspecified` structural recovery surface.

| Code | Raised when |
| --- | --- |
| `number_overflow_exact_integer` | a pure integer literal cannot fit the exact `u64` path |
| `date_invalid_year` / `date_invalid_month` / `date_invalid_day` | date literal components are out of range |
| `time_invalid_hour` / `time_invalid_minute` / `time_invalid_second` | time literal components are out of range |

The Tree and Binary paths produce the **same code** for the same
input. Spans may differ between paths in subtle cases (Tree wraps a
vector-element failure at the vector's span, Binary points at the
offending element); the path-level conformance anchor is the code,
not the span. Anchor cross-host fixtures on `(code, code-specific
fields)` and treat span as advisory.

**Semantic path.** Each diagnostic also carries a `path: []const
[]const u8` — a list of bare-identifier steps from the document
root to the failing node. Steps come from three sources:

  * a form contributes its head name (`scene`);
  * a kvpair contributes its key (`bpm`);
  * a vector element contributes its decimal index (`0`, `1`, …).

The kvpair value itself does **not** add a step when it's an atom —
it inherits the kvpair's path. When the value is a form, descending
into it adds the form's head as a final step, so structural descent
and path stay in lock-step. Examples:

  * `(scene :bpm "x")` — wrong `:bpm` value, path `[scene, bpm]`.
  * `(canvas :shape (triangle …))` against a HeadSet that excludes
    `triangle` — `not_head_member` at path `[canvas, shape]`,
    followed by `unknown_form` at path `[canvas, shape, triangle]`
    once the walker descends into the form.
  * `(scene :tags ["a" "b"])` — the second element fails at path
    `[scene, tags, 1]`.

The path is the cross-host anchor for fixtures: `(code, path)`
identifies *what* failed *where* without committing to host-specific
span semantics. The parser and both validator paths (Tree and Binary)
emit semantic paths and agree on `(code, path)` for every parity
case; the only remaining divergence is the typed-vector element-fusion
case (Tree fires once at the slot wrapping "element [N]: …", Binary
fires per element at the leaf), which is a structural difference in
how the per-element check propagates rather than a path-tracking
gap.

Parser diagnostics follow the same path conventions: a bad number or
escape inside `(parent :k …)` lands at `[parent, k]`; an empty form
inside `(parent (…))` lands at `[parent, "0"]`; an unclosed delimiter
emits one diagnostic per still-open frame, each path pointing at the
frame that didn't close. Codes for these stay `.unspecified` per the
note above — only paths are wired.

### 7.7 Validating over the binary IR

`validateBinary(gpa, bytes, schema)` is the streaming counterpart to
`validate`. It walks `bytes` directly through `BinaryCursor` (§10.4)
without ever building a `Tree`. The diagnostic shape is identical;
the spans refer to the binary buffer's nodes via the same source
spans the binary preserves under the `with_spans` flag.

`validateBinary` carries one extra error class beyond `validate`:
the wire-format errors from the cursor (`InvalidMagic`,
`InvalidVersion`, `UnknownTag`, …) are returned as `Error!Result`
rather than as diagnostics. Schema violations stay diagnostics inside
the returned `Result` exactly as they would on the tree path. The
contract `validate(parse(s)) ≡ validateBinary(toBinary(parse(s)))`
holds for every example fixture and is enforced by a property
test.

The streaming validator carries the same depth bounds as the
expression evaluator: `MAX_VALIDATE_FRAMES = 1024`,
`MAX_VALIDATE_STEPS = 2^20`. Exceeding either yields
`error.DepthExceeded`. Real documents are far below either
ceiling.

### 7.8 Defaults: author value vs effective value

A `KeySpec.default` (§6.3) declares a fallback for an omitted optional
key. The substrate distinguishes three values per key on a data-form
instance:

- **Author value** — a kvpair explicitly written in the document.
- **Default value** — the value declared by the schema on
  `KeySpec.default`.
- **Effective value** — the author value if present, otherwise the
  materialized default if one exists.

`Host.validateDocument` runs a *materialization* pass after the
aggregate validators and **before** the data-forest walk. The pass walks
every reachable known data form, finds each omitted declared key whose
`KeySpec.default` is non-null, and records the effective value in a
side-table overlay (`MaterializedDefaults`) keyed by
`(form NodeIndex, key name)`. The author `Ast.Tree` is **never
rewritten** — source stays source, materialization is semantic output.

The overlay is built before the validator runs so the validator can
consult it through the active `effective_axes` policy. Diagnostic-stream
order
is preserved separately from phase order: validator diagnostics are
appended to the result first, then materializer diagnostics, both
under `phase = .validation`.

The rules:

1. Defaults apply only to omitted declared keys on known data forms.
   Unknown heads are already diagnosed; materialization skips them.
2. An explicit author kvpair always wins, even if it is invalid. The
   overlay carries no entry for an explicitly written key.
3. Duplicate explicit keys remain a validation error; materialization
   does not try to repair them.
4. **Literal defaults** materialize by copying the schema-owned default
   into the host result arena.
5. **Expression defaults** evaluate the retained one-root Binary IR
   program (§6.3) with an empty `Expr.Env` against the active schema.
   No document-local bindings, no sibling key values, no IO.
6. Each schema key's expression default is evaluated **at most once**
   per `Host.validateDocument` result. N omitted instances of the same
   `KeySpec` share the cached `Expr.Value` from the overlay arena.
7. If materialization fails for an expression default, the host emits
   one `default_eval_failed` diagnostic at path `[<form-head>
   <key-name> default]` and produces no overlay entry for that key. The
   negative result is also cached, so N omitted instances of a failing
   default produce one diagnostic, not N.

**Validation-semantics boundary.** Materialization is a read-side
overlay; the author tree is not rewritten. The production validator
consults defaulted effective values for cross-reference name indexing,
cross-reference target lookup, variant/discriminant selection, and
exclusive-group presence. Axis C runs under a group-aware rule: a
defaulted alternative participates in the group only when no sibling
alternative is fully author-present — so `(track :at 12)` with a
defaulted `:from` stays silent. Schemas with multiple default-only
alternatives in the same exclusive group surface
`multiple_defaulted_alternatives_in_group`. Lowering hooks read the
effective view through `EffectiveView` — see the runtime in
`src/Lowering.zig` and the model contract in
[`docs/plugin-model-v1.md`](plugin-model-v1.md).

**Eval-capable reads + host-supplied env.** A hook's typed read helpers
(`symbol` / `string` / `number` / `boolean`) accept only *literal* values;
a non-literal is `HookFailed`. A number slot also has an *eval-capable*
reader, `numberEval`, which **evaluates** an author expression in value
position (`:count (* workgroup-size 1)`) instead of rejecting it, and
resolves any free variable against a **host-supplied environment**. The
environment is injected at the Zig API boundary — `HostOptions.lowering_env`
(an `Expr.Env` the embedder populates with named constants like
`workgroup-size`) — and defaults empty, so a free variable with no host
binding fails the hook (`UnknownBinding` → `lowering_hook_failed`). This is
**Zig-API-only**: no wire format, diagnostic code, or WASM ABI surface, and
with the default empty env every existing document is byte-identical. A host
constant must be referenced *inside an expression*; a bare symbol in a
`:type number` slot is still a static `wrong_underlying`, because only an
expression form defers to runtime evaluation. To make that deferral honest,
the lowering pass validates each sugar form against the same core-prepended
schema the final forest validation uses, so an expression's core operators
(`*`, `+`, …) resolve rather than tripping `unknown_form`.

**Cross-tree refs (host lowering).** When a hook lowers a sugar form,
the emitted forms land in a separate lowered tree whose nodes carry
spans inherited from the source form. The host's final-document
validator runs over a 2-tree forest (`source_view`, `lowered_tree`)
with one fused scope, so a source `:ref` may resolve to a lowered
target — and a lowered `:ref` may resolve to a source target — just
as if the document were authored as one piece. Each tree gets its
own materialized-defaults overlay (`Validator.Options.overlays`)
because their `NodeIndex` spaces are disjoint. Surface validation
inside the lowering pass sees only the one-form sub-tree and would
miss any external cross-ref; the gate filters those misses and
defers cross-ref reporting to the final-forest pass.

Consumers walk `Ast.Tree` for author input and ask the overlay for
effective values. A consumer that wants the effective value of
`(circle, radius)` calls `materialized_defaults.defaultFor(form_idx,
"radius")` and falls back to the explicit kvpair on the tree when the
overlay returns `null`.

---

## 8. Safe expressions

A **safe expression** is a form whose head appears in the active
schema's `expr_funcs`. In any value position — a kvpair value, a
vector element, a positional child — the consumer chooses whether to
read the form opaquely (as data) or to evaluate it (as an
expression) by calling `evalExpr`.

```sjon
(camera :ortho :zoom (* 2 (b 1)))
                     ^^^^^^^^^^^^
                     ; safe expression: `(* 2 (b 1))`
                     ;   `*` from core (multiply)
                     ;   `b` from a domain plugin (beats → seconds)
```

Expressions are *pure*. Every operation is deterministic, has no
side effects, allocates only on the result arena, and depends only
on the bound environment and the active schema. There are no
captures, no closures, no I/O, no mutation, no recursion at the
language level.

The substrate guarantees:

- Eager evaluation (left to right) for non-control-flow forms.
- Short-circuit evaluation for `if` / `cond` / `and` / `or`.
- Bounded depth and step count (`MAX_EVAL_DEPTH = 256`,
  `MAX_FRAMES = 1024`, `MAX_STEPS = 2^20`).
- No memoisation: identical sub-expressions re-evaluate on each visit.
- Result strings, keywords, and vectors are deep-copied into the
  result arena, so callers may free the source tree (or binary
  buffer) immediately after `evalExpr` returns.

### 8.1 Where expressions may appear

An expression form may appear *anywhere a value may appear*. The
substrate does not gate expression position by syntax — instead, the
*consumer* decides whether to evaluate or to read opaquely.

In the canonical pipeline:

- The validator (§7) treats every form-headed value either as a
  data form (when the head matches a `FormSpec`) or as an
  expression form (when the head matches an `ExprFunc`). Either
  way, the validator does not evaluate; it only checks structure.
- `evalExpr(tree, node, env, schema)` evaluates a single value
  position — usually the value of a kvpair, but any node index is
  valid input. The result is a runtime `Value` (see §8.2).
- A consumer integrating SJON typically walks its schema's forms,
  calls `evalExpr` on each typed slot whose declared `value_type`
  matches the expression's result type, and surfaces evaluation
  errors as diagnostics.

Expression arguments are positional by default. A fixed-arity
`ExprFunc` signature whose `param_names` names every parameter also
accepts a **labeled** form such as
`(lerp :from 0 :to 10 :t 0.5)`. The labels are `kvpair` children,
match the declared parameter names, may appear in any order, and are
reordered to the expression's positional argument vector before
type-checking or evaluation.

A labeled call is strict. Every argument in the call must use labels,
each declared label must appear exactly once, and labels outside the
selected signature are errors. The validator emits
`expr_mixed_args`, `expr_missing_label`, `expr_duplicate_label`, or
`expr_unknown_label` for those cases. A function with no fully named
fixed-arity signature does not accept the labeled form; its `:k v`
child emits `expr_kvpair_not_allowed`, and the evaluator reports
`error.KeywordInExpressionArgs` if it reaches that shape at runtime.

A **bare** `:keyword` child is a different thing. The greedy pairing
rule (§5.4) promotes any keyword that cannot find a value to a
positional flag, and that positional is a value of kind `keyword`.
Inside an expression form, bare keywords evaluate to `Value.keyword`
(§8.2), which is what makes `(= mode :ortho)` work as written:
`:ortho` closes the frame before it can pair, the parser commits it
as a positional, and `=` compares same-kind keyword payloads.

Equivalent re-statement, parser-side: a keyword survives in
expression position **only when it is syntactically impossible to
pair**. There is no way to express a `:k v` "kwarg-shaped" argument
inside an expression form — the validator and evaluator both reject
that AST shape.

### 8.2 Runtime values

The evaluator's value type is a closed union of variants mirroring
the AST's eleven value kinds (integer tags fold into three variants;
date and time each ride on their own):

```zig
pub const Value = union(enum) {
    number: f64,
    integer_i64: i64,
    integer_u64: u64,
    boolean: bool,
    nil,
    string: []const u8,
    keyword: []const u8,
    date: Date,
    time: Time,
    vector: []const Value,
    form: FormValue,
};
```

Notable mappings from the AST's eleven value kinds:

- `number_with_unit` evaluates to its numeric magnitude as a
  `Value.number`. The unit is dropped — units are opaque metadata
  at the AST layer; the closed expression vocabulary operates on
  numeric values. Plugins that want unit conversion provide their
  own expression functions (see `(b 4)` for beats → seconds).
- `symbol` evaluates as a *binding lookup*: the evaluator looks the
  symbol's name up in the environment chain (§8.3). An unbound
  symbol returns `error.UnknownBinding`.
- `form` evaluates as an expression form (§8.4) when the head
  matches an `ExprFunc`. A form whose head matches *only* a
  `FormSpec` is not evaluable in expression position; calling
  `evalExpr` on it returns `error.UnknownFunction`.
- `kvpair` is not a runtime value at this layer. It can carry one
  slot of an accepted labeled expression call; an unaccepted,
  malformed, or mixed expression-side kvpair is
  `error.KeywordInExpressionArgs` at evaluation time.

Truthiness:

```
(.boolean false) → falsy
(.nil)           → falsy
everything else  → truthy
```

A number `0`, an empty string `""`, an empty vector `[]` are all
**truthy**. Authors who want zero-as-false write `(= n 0)`
explicitly.

Equality (`=`, `!=`):

- Same-kind values are compared by payload (numbers by IEEE-754;
  vectors element-wise, recursively).
- Different-kind comparisons return `false`.
- `NaN ≠ NaN` (IEEE-754 standard).

### 8.3 Environments

An `Env` is a lexically-scoped, immutable binding chain:

```zig
pub const Env = struct {
    parent: ?*const Env = null,
    bindings: []const Binding = &.{},
};

pub const Binding = struct {
    name: []const u8,
    value: Value,
};
```

The caller provides the outermost `Env` to `evalExpr`. `let` (§8.5)
extends the chain with a new frame; bindings are searched
last-to-first within a frame so a later `let` binding shadows an
earlier one in the same frame, and inner frames shadow outer.

Symbols in expression position resolve through `env.lookup(name)`.
Unbound symbols return `error.UnknownBinding`; the evaluator does
not fall through to schema-level constants or anything similar. If
a domain wants well-known constants (`pi`, `tau`, `e`), they are
declared as zero-arg `ExprFunc` entries in a plugin (§6.6).

### 8.4 The closed v1 vocabulary

The `core` plugin ships the closed v1 vocabulary. Authors using SJON
without other plugins have exactly these expression heads available.
Each entry's typed signature (where declared) is shown alongside its
arity — the validator catches mistyped literal arguments at validate
time.

#### Arithmetic

| Form | Arity | Args | Result | Meaning |
| --- | --- | --- | --- | --- |
| `(+ x ...)` | 0+ | `…number` | `number` | Sum. `(+)` → `0`. |
| `(- x ...)` | 1+ | `number, …number` | `number` | Negation when called with one arg; subtraction (left-fold) for two or more. |
| `(* x ...)` | 0+ | `…number` | `number` | Product. `(*)` → `1`. |
| `(/ x y ...)` | 2+ | `number, …number` | `number` | Division (left-fold). Division by zero returns `error.DivisionByZero`. |
| `(mod x y)` | 2 | `number, number` | `number` | Floating-point remainder. |

#### Comparison (binary)

```
(<  x y)   (>  x y)             ; both: number, number → boolean
(<= x y)   (>= x y)             ; both: number, number → boolean
(=  x y)   (!= x y)             ; opaque (polymorphic equality), → boolean
```

All six are binary, return a boolean. The four ordering operators
declare typed signatures (`number, number → boolean`) — the validator
flags `(< true "x")` statically. `=` and `!=` are polymorphic and
left opaque pending overload support.

#### Logical

```
(not x)              ; arity 1, params [boolean], → boolean
(and x ...)          ; arity 0+, opaque args, → boolean (short-circuit)
(or x ...)           ; arity 0+, opaque args, → boolean (short-circuit)
```

`(and)` with zero arguments returns `true`; `(or)` with zero
arguments returns `false`. Both forms are short-circuiting:

- `(and a b c)` evaluates left to right and returns the first falsy
  value, or the last value if all are truthy.
- `(or a b c)` evaluates left to right and returns the first
  truthy value, or `false` if none are.

This matches Lisp's "value-returning" semantics: `(and 1 2 3)` is
`3`, not `true`.

#### Vectors

```
(vec2 x y)           ; params [number, number],         → vector
(vec3 x y z)         ; params [number, number, number], → vector
(vec4 x y z w)       ; params [number, number,
                                number, number],          → vector
```

Construct fixed-arity vectors of numbers. The validator catches
non-numeric literal arguments via the typed signature; the runtime
catches non-numeric values that flow in via bindings. The result
is a `Value.vector` of length 2 / 3 / 4. To build a variable-length
vector, use the literal form `[a b c …]` directly — vector literals
evaluate element-by-element into a `Value.vector` of the same
length.

#### Math and aggregation (scalar)

`lerp`, `clamp`, `min`, and `max` operate on **scalar `f64`**. They
are left opaque at validate time pending overload support — their
argument types are not statically checked, only their arity. Vector
broadcast (component-wise application onto `vec2`/`vec3`/`vec4`) is
**not** in v1; a future `(vmap fn v)` op may layer it on without
breaking the existing scalar contract.

| Form | Arity | Meaning |
| --- | --- | --- |
| `(lerp a b t)` | 3 | Linear interpolation: `a + (b - a) * t`. Scalar. |
| `(clamp x lo hi)` | 3 | Clamp `x` into `[lo, hi]`. Scalar. |
| `(min x ...)` | 1+ | Numeric minimum across all args. |
| `(max x ...)` | 1+ | Numeric maximum across all args. |
| `(dot a b)` | 2 | Dot product of two same-length vectors. |
| `(cross a b)` | 2 | Cross product of two `vec3` values. |
| `(length v)` | 1 | Euclidean length of a vector. |

#### Math (extended) — scalar `f64 → f64`

| Form | Arity | Meaning |
| --- | --- | --- |
| `(abs x)` | 1 | Absolute value. |
| `(sign x)` | 1 | `-1`, `0`, or `1`. `NaN` is preserved. |
| `(floor x)` | 1 | Round toward `−∞`. |
| `(ceil x)` | 1 | Round toward `+∞`. |
| `(round x)` | 1 | Round half **away from zero**. |
| `(fract x)` | 1 | `x − floor(x)`. **WGSL** — result may be exactly `1.0` for some near-integer negatives; do not clamp. |
| `(sqrt x)` | 1 | Principal square root; `(sqrt x<0)` → `NaN`. |
| `(pow base exp)` | 2 | Exponentiation; out-of-domain combinations → `NaN`. |
| `(sin x)` `(cos x)` `(tan x)` | 1 | Trig with `x` in radians. |
| `(asin x)` `(acos x)` | 1 | Inverse trig; `\|x\| > 1` → `NaN`. |
| `(atan x)` | 1 | Arctangent (1-arg). |
| `(atan2 y x)` | 2 | Argument of `(x, y)` in `[−π, π]`. |
| `(radians deg)` | 1 | Degrees → radians. |
| `(degrees rad)` | 1 | Radians → degrees. |

#### Constants (0-arity)

| Form | Arity | Meaning |
| --- | --- | --- |
| `(pi)` | 0 | `π = 3.141592653589793`. |
| `(tau)` | 0 | `2π = 6.283185307179586`. |

Constants are spelled as 0-arity calls — `(pi)` rather than `pi` —
so the closed-vocabulary contract holds: `expr_funcs` enumerates
the entire callable surface, and the evaluator's environment
stays free of implicit bindings.

#### Smoothing (WGSL conventions)

| Form | Arity | Meaning |
| --- | --- | --- |
| `(saturate x)` | 1 | `clamp(x, 0, 1)`. |
| `(step edge x)` | 2 | `0` if `x < edge`, else `1`. |
| `(smoothstep e0 e1 x)` | 3 | Cubic Hermite, clamped. **WGSL** — `e0 == e1` is explicitly invalid / indeterminate. |

#### Vector ops (extended)

| Form | Arity | Meaning |
| --- | --- | --- |
| `(normalize v)` | 1 | Unit-length vector. Empty or zero-magnitude `v` → `error.TypeMismatch`. |
| `(distance a b)` | 2 | Euclidean distance. Lengths must match; empty → error. |
| `(reflect I N)` | 2 | `I − 2·dot(N, I)·N`. **WGSL** — `N` must be unit-length; the substrate does not auto-normalize. |

#### List ops

| Form | Arity | Meaning |
| --- | --- | --- |
| `(nth v i)` | 2 | 0-indexed vector access. Non-integer or out-of-bounds `i` → `error.TypeMismatch`. |
| `(count v)` | 1 | Number of elements in vector `v`. |

These are vector-only in v1; equivalent ops on strings (e.g.
codepoint counting) may follow in a separate proposal.

#### Seeded random (deterministic SplitMix64)

All random functions are pure functions of their `(seed, key, …)`
arguments. They use a fixed SplitMix64-based mixer; the same input
produces the same output across runs, platforms, and Zig versions.
Integer-valued `seed`/`key` map identically — `(rand01 1 0)` and
`(rand01 1.0 0.0)` produce the same stream.

| Form | Arity | Meaning |
| --- | --- | --- |
| `(hash seed key)` | 2 | 53-bit integer-as-`f64` in `[0, 2^53)`. |
| `(rand01 seed key)` | 2 | Uniform float in `[0, 1)`. |
| `(rand-range seed key lo hi)` | 4 | Uniform float in `[lo, hi)`; `lo > hi` → error. |
| `(rand-int seed key lo hi)` | 4 | Uniform integer in `[lo, hi]` inclusive; `lo`/`hi` must be integer-valued. |
| `(rand-bool seed key p)` | 3 | `true` with probability `clamp(p, 0, 1)`. |
| `(rand-choice seed key v)` | 3 | Pick an element of `v`; empty `v` → error. |

#### Control flow

```
(let [name1 expr1 name2 expr2 …] body)
(if test then-expr [else-expr])
(cond test1 expr1 test2 expr2 … [else-expr])
```

`(let …)` takes a vector of paired `name expr` entries (vector
length must be even) and a body expression. Bindings evaluate
**sequentially**: each `expr` sees the bindings established by every
*earlier* pair in the same `let`. The body evaluates in the new
environment.

```sjon
(let [a 1 b (+ a 2) c (* a b)]      ; a=1, b=3, c=3
  (+ a b c))                         ; → 7
```

`(if test then [else])` evaluates `test`. If truthy, evaluates and
returns `then`; otherwise evaluates and returns `else` (or `nil` if
`else` is absent). Only one of `then` / `else` is evaluated.

`(cond t1 v1 t2 v2 … tN vN)` is a generalised `if`/`else-if`
chain. Tests are evaluated left to right; the value paired with the
first truthy test is evaluated and returned. If no test is truthy,
the form returns `nil`. A `cond` with an odd number of children
returns `error.InvalidCondClause`.

To express a "default" branch, end with a `true` test:

```sjon
(cond
  (< x 0)  -1
  (> x 0)   1
  true      0)                       ; default fallthrough
```

#### Higher-order binder forms

`map`, `filter`, `any`, `all`, and `fold` walk a finite vector and
bind a name to each element while evaluating a body expression. They
are **special forms**, not plugin functions — the evaluator
dispatches them through dedicated frames so the body re-evaluates
once per element with a fresh binding. There is no first-class
function value involved; the body is a syntactic sub-expression of
the form.

| Form | Arity | Result | Notes |
| --- | --- | --- | --- |
| `(map [x] xs body)` | 3 | `vector` of length `xs.len` | Evaluates `body` once per element; collects results. |
| `(filter [x] xs pred)` | 3 | `vector` of original elements | Keeps `xs[i]` whenever `pred` is truthy. |
| `(any [x] xs pred)` | 3 | `boolean` | Short-circuits on first truthy `pred`. |
| `(all [x] xs pred)` | 3 | `boolean` | Short-circuits on first falsy `pred`. |
| `(fold [acc x] init xs body)` | 4 | value of `body`'s last iteration | Threads body result as next iteration's `acc`; returns `init` on empty `xs`. |

The first child is a **binder vector**: a literal `[name]` (or
`[acc x]` for fold) with exactly one symbol — or two for fold. It is
not evaluated; the symbol(s) become the loop variable's name (and,
for fold, the accumulator's name). For `map`/`filter`/`any`/`all`,
the second child is `xs` — an expression that must evaluate to a
vector — and the third is the body. For `fold`, the second child is
`init` (the accumulator's initial value), the third is `xs`, and the
fourth is the body. Each iteration evaluates the body in an
environment that layers `name = xs[i]` (and `acc = current_acc`, for
fold) over the outer env; the outer env is unchanged after the form
completes.

```sjon
(map [x] [1 2 3 4] (* x x))             ; → [1 4 9 16]
(filter [x] [-1 0 1 2] (> x 0))         ; → [1 2]
(any [x] [1 2 3] (> x 2))               ; → true
(all [x] [1 2 3] (> x 0))               ; → true
(fold [acc x] 0 [1 2 3 4] (+ acc x))    ; → 10
(fold [acc x] 1 [2 3 4] (* acc x))      ; → 24
```

`xs` is evaluated **exactly once**; the body/predicate is evaluated
**once per element**. `any`/`all` stop as soon as the result is
decidable. Truthiness follows §8.2 — `(.boolean false)` and `(.nil)`
are falsy, everything else (including `0`, `""`, `[]`) is truthy.

`fold` evaluates `init` **once** before the first iteration; its
value becomes the iteration-0 `acc`. Each iteration's body result
becomes the next iteration's `acc`; after the final element, the
form's result is that iteration's body value. If `xs` is empty, no
body iteration runs — the form's result is the evaluated `init`.

Binder vectors are **strict**:

- Non-symbol element (`(map [1] xs body)`, `(fold [acc 1] init xs body)`)
  → `error.InvalidBinderShape`.
- Wrong length (`(map [] xs body)`, `(map [x y] xs body)`,
  `(fold [acc] init xs body)`, `(fold [a b c] init xs body)`) →
  `error.InvalidBinderShape`.
- Binder is not a literal vector (`(map foo xs body)`) →
  `error.InvalidBinderShape`.
- Duplicate binder names in fold (`(fold [acc acc] init xs body)`) →
  `error.InvalidBinderShape`.
- `xs` evaluates to non-vector → `error.TypeMismatch`.

Each iteration costs at least one step against the per-call
`MAX_STEPS = 2^20` budget, so a `(map [x] xs …)` over a 100k-element
vector with a non-trivial body can exhaust the budget and surface as
`error.DepthExceeded`. The ceiling is deliberate — these forms exist
for "a little safe iteration," not for general data processing.

Nested binders compose lexically:

```sjon
(map [x] [1 2]
  (map [y] [10 20]
    (* x y)))                          ; → [[10 20] [20 40]]
```

The inner `[y]` shadows nothing because the outer `x` and inner `y`
are different names. Reusing a name shadows it for the inner scope,
matching `let` semantics.

These forms are declared in the `core` plugin with `.impl = null`
and an opaque type signature — the validator checks arity but does
not infer the body's result type, mirroring how `let` and `if`
are handled (§8.4 control-flow forms).

### 8.5 Evaluation semantics

The evaluator is iterative — a single driver loop that pops a frame,
processes it, and pushes more frames or values until the value stack
holds the single result. There is no host-stack recursion.

Frame kinds and their semantics:

- `eval(idx, env)` — visit the AST node at `idx`, push its value
  (atoms) or schedule sub-frames (forms, vectors).
- `vec_collect(N)` — pop `N` values, build a `Value.vector`.
- `apply_form(head, argc)` — pop `argc` argument values, dispatch
  to `applyFunction(head, args, schema)`.
- `let_commit(name, env_buf, idx)` — pop a value, install it as the
  next binding in the let's environment frame.
- `if_select` / `cond_select` — pop a test value, schedule the
  appropriate branch's eval.
- `and_check` / `or_check` — pop a value, decide whether to
  short-circuit or schedule the next operand.
- `map_iter` / `filter_iter` / `any_iter` / `all_iter` / `fold_iter`
  — drive a binder loop: pop the previous iteration's body value,
  layer a fresh binding over the outer env, schedule the body again
  at the next element until the input vector is exhausted or a
  short-circuit fires. `fold_iter` also installs the body's result
  as the next iteration's `acc` binding.

`apply_form` for a known head dispatches through
`Schema.lookupExprFunc(name, namespace)`. The frame carries the head's
namespace (empty for bare heads), so `(myns/foo …)` resolves through
`myns`'s `foo` and never aliases another plugin's bare `foo`. Four
outcomes:

- **Found with `impl`** — call `impl(arena, args)`, push the
  returned value.
- **Found, `impl == null`** — return
  `error.PluginFuncNotImplemented`. The function is
  validator-known but not executable.
- **Ambiguous** (bare only) — return `error.AmbiguousFunction`.
  Qualified lookups are never ambiguous.
- **Not found** — return `error.UnknownFunction`. The validator
  catches most of these statically (§7); the runtime error covers
  `evalExpr` on a sub-tree the validator hasn't seen.

Special-form recognition (`let` / `if` / `cond` / `and` / `or` /
`map` / `filter` / `any` / `all` / `fold`) gates on `namespace == null`. A
qualified head like `(core/let …)` falls through to `applyFunction`
and yields `PluginFuncNotImplemented` — `core` declares these for
shape-checking only, no runtime impl. The validator stays happy on
either form.

The evaluator never allocates from the caller's general allocator
(`gpa`) — every `Value` is built from the result arena. The result
holds a deep copy of every string and vector, severed from the
source tree's memory.

### 8.6 Error categories

`evalExpr` returns one of:

| Error | When |
| --- | --- |
| `OutOfMemory` | Allocator failure (the only allocator failure path). |
| `TypeMismatch` | An operation received an argument of the wrong kind (e.g. `(+ "a" 1)`). |
| `DivisionByZero` | `(/ x 0)` with non-zero left operand and zero right. |
| `UnknownFunction` | A form's head matches no `ExprFunc` in the schema. |
| `AmbiguousFunction` | A bare expression head resolves to ≥ 2 plugins; qualify with `<ns>/head`. (Qualified heads are never ambiguous.) |
| `UnknownBinding` | A symbol resolves to no binding in the env chain. |
| `ArityMismatch` | Too few or too many arguments for the function's declared arity. |
| `InvalidLetBinding` | `let`'s first child is not an even-length vector of `(name expr)` pairs. |
| `InvalidCondClause` | `cond` has an odd number of children. |
| `InvalidBinderShape` | `map`/`filter`/`any`/`all`/`fold`'s first child is not a literal vector of the required number of symbols (1 for `map`/`filter`/`any`/`all`, 2 distinct for `fold`). |
| `KeywordInExpressionArgs` | An expression-side kvpair did not resolve as a valid labeled call slot. |
| `DepthExceeded` | Frame count exceeded `MAX_FRAMES`, or step count exceeded `MAX_STEPS`. |
| `MemoryBudgetExceeded` | Result-arena bytes exceeded `MAX_EVAL_BYTES` (the per-call memory ceiling). Distinct from `DepthExceeded` (steps/frames) and `OutOfMemory` (host allocator failure). |
| `PluginFuncNotImplemented` | Function was declared but its `impl` is `null`. |

Every error is *deterministic* — the same source under the same
schema and environment produces the same outcome on every run.
Spans for diagnostic rendering live on the source nodes the
caller passes in (or on the binary buffer in the streaming case);
the evaluator does not synthesize source positions.

#### Domain errors propagate as `NaN`, not as errors

Math functions whose IEEE 754 domain excludes a value — `(sqrt -1)`,
`(asin 2)`, `(acos -1.5)`, `(pow -1 0.5)` — return floating-point
`NaN` rather than raising an error. This keeps the evaluator
**total** over `f64`: every numeric expression produces a numeric
value, and downstream computation either propagates the `NaN` or
guards with `(if (>= x 0) (sqrt x) ...)`.

Cross-platform reproducibility holds for the `NaN` cases too: every
host produces the same `NaN` on the same input. SJON does not
introduce a `MathDomain` error code; the validator does not flag
literal `(sqrt -1)` ahead of time. Authors who need strict checks
should guard explicitly.

#### Transcendentals are bit-reproducible across hosts

A document's evaluated numeric results are bit-identical across the
Zig (native and both WASM artifacts) and Rust hosts, with no
"reference platform" caveat. This holds at two levels:

- The basic operations — `+ - * /` and `sqrt` — are correctly
  rounded by IEEE 754, and SJON pins `FloatMode.strict` (no FMA
  contraction or reassociation), so they produce identical bits
  everywhere for free.
- `sin` / `cos` / `tan` are **not** mandated correctly-rounded by
  IEEE 754. A naive `@sin`/`@cos`/`@tan` lowers to the platform libm
  (glibc, musl, macOS, a WASM runtime's libm), which disagree in the
  last ULP. SJON therefore evaluates them with a vendored software
  implementation (`src/trig.zig`, musl/compiler_rt lineage — the same
  algorithm the freestanding WASM artifacts already link), so they
  are reproducible by construction rather than by accident of which
  libm happens to link. `asin` / `acos` / `atan` / `atan2` and `pow`
  use `std.math`'s portable pure-software paths and are reproducible
  as-is.

The `expr-trig-*` conformance cases pin exact `sin`/`cos`/`tan`
outputs so any drift is caught across hosts. (The TypeScript-parity
host has no expression evaluator and does not participate in
evaluated-result parity.)

### 8.7 Evaluating over the binary IR

`evalExprBinary(gpa, bytes, env, schema)` is the streaming
counterpart to `evalExpr`. It walks `bytes` directly via
`BinaryCursor` (§10.4) without ever building a `Tree`, mirroring
`Expr.eval`'s frame-stack architecture with the cursor's monotonic
walk.

Its surface contract differs from `evalExpr` in one place:
`evalExprBinary` errors with `error.MultipleRoots` if the buffer's
root list has more than one entry. The streaming primitive
evaluates a single-rooted expression buffer, not an arbitrary
sub-node inside a multi-rooted document binary. To evaluate a
sub-node of a multi-rooted document, decode through `fromBinary` and
call `evalExpr` on the desired node. The kitchen-sink
`sjon.wasm` exposes both paths; the read-only `sjon-binary.wasm`
exposes only `evalExprBinary` (which, with `validate_binary`, is the
entire surface of the read-only WASM artifact).

### 8.8 Worked examples

```sjon
; arithmetic on numbers
(* 2 (+ 3 4))                               ; → 14

; comparison
(<= (length [3 4]) 5)                       ; → true (length is 5)

; let with sequential bindings
(let [r 5
      area (* 3.14159 r r)]
  (vec2 r area))                            ; → [5.0 78.53975]

; cond with default
(cond
  (= mode :ortho)        :two-d
  (= mode :perspective)  :three-d
  true                   :unknown)
; Each `:keyword` here closes its frame before it can pair, so the
; parser commits it as a positional value of kind `keyword` (§5.4),
; and the evaluator pushes it as `Value.keyword` for `=` to compare
; (§8.1, §8.2). A *paired* `:k v` inside an expression would still
; be rejected as a kwarg.

; short-circuiting
(and (> n 0) (= (mod n 2) 0))               ; "n is positive and even"

; plugin-provided function (b: beats → seconds, declared by a domain plugin)
(* 2 (b 1))                                 ; → seconds equivalent of two beats
```

The expression vocabulary is designed for "a little safe math" —
unit conversions, slot derivation, conditional defaults — not for
general computation. Authors who need general computation lift the
work out of SJON, evaluate it in their host language, and pass the
result through the substrate as data.

---

## 9. JSON bridge

SJON values map to JSON through a deterministic tagged-object
encoding. Two modes are supported:

- **Canonical** — every kind has a distinct on-the-wire shape.
  Round-trips with semantic equivalence (`≅`), not byte equality —
  see §9.2 for the precise contract and its caveats around
  kvpair/positional interleaving and duplicate keys.
- **Lossy** (alias `compact`) — keywords, symbols, and strings
  collapse to bare JSON strings. Number units drop. Useful for
  human-readable dumps; one-way only.

```
┌─────────────────────────────┬───────────────────────────────────────┐
│ SJON value                  │ JSON                                  │
├─────────────────────────────┼───────────────────────────────────────┤
│ nil                         │ null                                  │
│ true / false                │ true / false                          │
│ 4 (number, integer-valued)  │ 4                                     │
│ -1.25 (number)              │ -1.25                                 │
│ 4b (number_with_unit)       │ canonical: {"$num": [4, "b"]}         │
│                             │ lossy:     4                          │
│ 2026-05-19 (date)           │ canonical: {"$date": "2026-05-19"}    │
│                             │ lossy:     "2026-05-19"               │
│ 12:34:56.789 (time)         │ canonical: {"$time": "12:34:56.789"} │
│                             │ lossy:     "12:34:56.789"             │
│ "hello" (string)            │ "hello"                               │
│ :ortho (keyword)            │ canonical: {"$kw": "ortho"}           │
│                             │ lossy:     "ortho"                    │
│ bounce (symbol)             │ canonical: {"$sym": "bounce"}         │
│                             │ lossy:     "bounce"                   │
│ [1 2 3] (vector)            │ [1, 2, 3]                             │
│ (form :k v c1 c2)           │ canonical: {"$form":"form","$ns":...,  │
│                             │              "k":v,"$children":[c1,c2]}│
│ (+ a b) safe expression     │ canonical: {"$expr": ["+", a, b]}     │
│ (myns/foo a) qualified expr │ canonical: {"$expr":["foo",a],"$ns":"myns"} │
└─────────────────────────────┴───────────────────────────────────────┘
```

The form encoding writes the head as `$form` and the namespace (when
present) as `$ns`. Safe-expression encoding mirrors this: a qualified
expression head emits a sibling `$ns` next to `$expr`, so the runtime
dispatcher resolves the call against the same `(name, namespace)` pair
on the way back in. Keywords inside a `$form` become object keys
directly; positional children gather into an `$children` array.
Because object keys and `$children` are *separate destinations*, this
encoding cannot preserve the original interleaving of kvpairs and
positionals — `(foo a :x 1 b)` and `(foo :x 1 a b)` produce the same
JSON object, and the decoder reconstructs as "kvpairs first,
positionals after" by convention. If you need source-order fidelity
across the wire, use the binary IR (§10), which preserves the child
list verbatim.

**Duplicate kvpair keys collapse on the wire.** A form like
`(foo :x 1 :x 2)` produces a JSON object `{"$form":"foo","x":2}` —
the encoder's `obj.put` overwrites silently, so only the last value
survives, and the decoder cannot recover the lost one. The validator
emits `duplicate keyword \`:k\` in form \`name\`` (§7.5) for any
duplicate on **any** form spec (open or closed), so a validated tree
never carries duplicates and round-trips faithfully. Unvalidated
trees containing duplicates are lossy on the JSON wire; recovering
the dropped value requires the binary IR (§10), which preserves
duplicate kvpairs verbatim regardless.

Safe expressions — recognised iff the caller supplied a `Schema`
when calling `toJson` — write as
`{"$expr": [head, arg1, arg2, …]}`.
That JSON form is positional: the current bridge rejects a labeled
expression call carrying expression-side kvpairs with
`error.InvalidExprForm`. Use positional call spelling, source text,
or binary IR when crossing that bridge.

### 9.1 Sigil-escaping

Object keys whose names start with `$` are reserved for
discriminators (`$num`, `$date`, `$time`, `$kw`, `$sym`, `$form`,
`$ns`, `$children`, `$expr`, `$roots`). User keys whose source name starts with `$` are
**escaped** on the wire: each leading `$` is doubled.

```
SJON kvpair  :$foo "x"          →  JSON {"$$foo": "x"}
SJON form    ($foo …)           →  JSON {"$form": "$$foo", …}
```

Decoding reverses the doubling: `"$$foo"` becomes the user key
`$foo`. A `$`-prefixed JSON key that is *neither* a recognised
discriminator *nor* a `$$…` escape raises
`error.UnknownDiscriminator` — the substrate refuses to silently
drop unknown sigils.

### 9.2 Round-trip contract (canonical mode)

Canonical JSON round-trip is **semantic**, not structural:

```
fromJson(toJson(t, .{ .mode = .canonical }))  ≅  t
```

where `≅` means: same value kinds and payloads at every node, same
namespace per form, the same key→value mapping per form (kvpair
lists carry map semantics — see §5.5, §7.3), and the same
positional-child sequence — but the **interleaving of kvpairs with
positional children is normalised** to "kvpairs first, positionals
after" (see the form-encoding paragraph above). A document whose
form children genuinely alternate, like `(foo a :x 1 b :y 2 c)`,
does not byte-equal its canonical-print after a JSON round-trip.

The mapping claim above is well-defined only when each form has at
most one occurrence of each key. Duplicate `:k` on any data-form
spec — open or closed — is a validator error (§7.5), so a validated
tree always satisfies that precondition and round-trips faithfully.
Unvalidated trees containing duplicates collapse on the wire (last-
wins per the form-encoding paragraph) and recovering the dropped
value requires the binary IR (§10).

The strict equation
`canonical-print(t) ≡ canonical-print(fromJson(toJson(t)))` holds
*only* when `t`'s every form is already in normalised form
(kvpairs-then-positionals) and has no duplicate keys. The per-form
regression in `fixtures/json_roundtrip.sjon` pins this set; each
fixture entry is written in normalised, duplicate-free form so the
strict equality applies. For an arbitrary `t`, the safe contract is
the semantic equivalence above.

Comments, spans, and source bytes do **not** participate in any JSON
contract; canonical print drops them and JSON has no preservation
channel. For source-order *and* trivia preservation, use the binary
IR (§10).

### 9.3 Lossy mode

Lossy mode trades fidelity for human readability. The collapses are
deliberate:

| SJON | Canonical JSON | Lossy JSON |
| --- | --- | --- |
| `:ortho` | `{"$kw": "ortho"}` | `"ortho"` |
| `bounce` | `{"$sym": "bounce"}` | `"bounce"` |
| `"hello"` | `"hello"` | `"hello"` |
| `4b` | `{"$num": [4, "b"]}` | `4` |

A lossy JSON document cannot be decoded back into a SJON tree
without ambiguity: every JSON string could be a string, a keyword,
or a symbol, and the unit on every number is gone. `fromJson` in
lossy mode treats every string as a string and every number as
unitless. There is no round-trip claim in lossy mode.

### 9.4 Multi-root documents

`toJson` and `fromJson` operate on **single-root** trees. A
multi-root tree raises `error.MultipleRoots` from `toJson`. For
multi-root documents use the dedicated API:

```zig
toJsonRoots(tree, opts)   → JSON: {"$roots": [v1, v2, v3, …]}
fromJsonRoots(value, opts) → Tree with len(root) == N
```

`$roots` is a top-level discriminator on equal footing with `$form`,
`$kw`, etc. A document of `[v1, v2]` versus a document with one root
that is the vector `[v1, v2]` are distinct shapes, and the dedicated
API preserves the distinction.

### 9.5 Per-node bridging

`toJsonNode(node)` and `fromJsonNode(json)` operate on individual
nodes inside a tree. They are the building blocks for tooling that
needs to splice JSON-encoded fragments into a SJON tree (or vice
versa). The Edit reducer (§11) uses them to materialise
JSON-encoded action payloads into AST sub-trees.

---

## 10. Binary IR

The Binary IR is a hand-rolled wire format for runtime targets that
need to *consume* SJON without paying for `std.json`,
`std.fmt`-float, or a parser. It is a faithful encoding of the AST,
not a lower-level representation: numbers store as 8 raw IEEE-754
bytes, identifiers and string literals share a per-tree
deduplicated pool sorted by `(length, bytes)`, comments and spans
are independently flag-gated.

### 10.1 Byte layout

Little-endian throughout. The buffer's high-level shape:

```
[ header 16 ] [ string pool ] [ comment-text pool* ] [ roots block ] [ tree-trailing comments* ]
```

Asterisks denote sections present only when the corresponding flags
are set.

Header (16 bytes, fixed):

| Field | Size | Value |
| --- | --- | --- |
| `magic` | 4 B | `"SJ1\n"` (`0x53 0x4A 0x31 0x0A`) |
| `version` | 1 B | `0x04` |
| `flags` | 1 B | see §10.2 |
| `reserved` | 2 B | must be zero |
| `pool_offset` | 4 B | byte offset to string pool (always `16`) |
| `roots_offset` | 4 B | byte offset to roots block |

The header layout is comptime-asserted in `Binary.zig`; a typo in a
constant or a stray padding byte fails at build time, not on a
hex-diff against a stored fixture.

### 10.2 Flag inventory

The `flags` byte is the substrate's mechanism for trading bytes
against fidelity. Each bit gates an independent trivia channel:

| Bit | Flag | Default | Effect |
| --- | --- | --- | --- |
|  0  | `with_spans` | on | Per-`Node` `Span` (8 B inline) |
|  1  | `with_head_spans` | on | Per-`Form` `head_span` inline |
|  2  | `with_kvpair_key_spans` | on | Per-`KeywordPair` `key_span` inline |
|  3  | `with_node_comments` | off | `Node.leading_comments` + `Form.trailing_comments` |
|  4  | `with_kvpair_comments` | off | `KeywordPair.leading_comments` |
|  5  | `with_tree_trailing_comments` | off | `Tree.trailing_comments` block |
| 6–7 | reserved | | Decoder rejects buffers with these set. |

Three presets. "Canonical" here means **runtime-canonical** —
deterministic byte output with diagnostic-grade fidelity — *not*
"minimal byte representation" in the JCS / canonical-XML sense. Spans
default on because they are load-bearing for everything downstream of
the parser: validator diagnostics cite source ranges, editors map
cursor positions to nodes, language-server features walk them.
Comments default off because they are pure prose — no non-emitter
consumer needs them, and they would bloat every runtime payload for
no functional gain.

- **`compact`** — every flag off. Smallest output (~0.7× canonical
  on a typical scene). Use for size-critical paths where diagnostics
  will never be projected back to source.
- **`canonical`** (default) — all three span flags on, comments off.
  Deterministic and runtime-grade: the same tree always serialises
  to byte-identical output, every consumer gets span-quality
  diagnostics, and no comment bytes ride along.
- **`lossless`** / `full` — every flag on. Round-trips every trivia
  channel a re-emitter or refactoring tool needs.

If the naming friction matters in a future cleanup, the
implementation rename is small (`Ast.Mode` + `forMode` + a fixture
sweep): `compact` → `compact`, `canonical` → `diagnostic`, `full` →
`lossless`. Until then, the spec keeps the names that match the
code.

```zig
const opts = sjon.Binary.ToBinaryOptions.forMode(.full);
const bytes = try sjon.toBinary(gpa, tree, opts);
defer bytes.deinit();
```

### 10.3 Tag set

The wire's per-node `Tag` byte enumerates the node's kind:

| Tag | Byte | Kind |
| --- | --- | --- |
| `nil` | `0x00` | nil |
| `bool_false` | `0x01` | boolean false |
| `bool_true` | `0x02` | boolean true |
| `number` | `0x03` | number (no unit) |
| `string` | `0x04` | string |
| `keyword` | `0x05` | keyword |
| `symbol` | `0x06` | symbol |
| `vector` | `0x07` | vector |
| `form_bare` | `0x08` | form, no namespace |
| `form_qualified` | `0x09` | form with `$ns` |
| `number_with_unit` | `0x0A` | number with unit suffix |
| `number_i64` | `0x0B` | exact signed integer number |
| `number_u64` | `0x0C` | exact unsigned integer number |
| `date` | `0x0D` | calendar date |
| `time` | `0x0E` | clock time |

Inside a form's children, each child is prefixed with a `ChildTag`:

| Tag | Byte | Meaning |
| --- | --- | --- |
| `positional` | `0x10` | positional value follows |
| `keyword` | `0x11` | kvpair: key index + value follow |

The tag enumeration is closed and projects 1:1 onto the abstract
`ValueKind` vocabulary (§3) via `Binary.Tag.toValueKind`. Adding a
new tag is a substrate-level wire bump; the decoder rejects unknown
tags with `error.InvalidTag`. The current wire version is `0x04`:
v2 added exact integer tags, v3 added `date`, and v4 added `time`.
Older decoders fail loud on buffers whose version or tags they do
not know.

### 10.4 Cursor contract

`BinaryCursor` is a zero-allocation read cursor over a binary
buffer:

```zig
var cursor = try sjon.BinaryCursor.Cursor.init(bytes);
var roots  = try cursor.rootIter();
while (try roots.next()) |view| {
    switch (view.kind) {
        .number    => { const x = try sjon.BinaryCursor.readNumber(&cursor, view); ... },
        .string    => { const s = try sjon.BinaryCursor.readString(&cursor, view); ... },
        .form      => {
            var fv = try sjon.BinaryCursor.readForm(&cursor, view);
            // fv.head, fv.namespace, fv.head_span
            while (try fv.children.next()) |child| { ... }
        },
        else       => try sjon.BinaryCursor.skipBody(&cursor, view),
    }
}
```

Properties:

- **Monotonic walk.** The cursor advances forward only; there is
  no random access. Each frame fully consumes its node's bytes.
- **Borrowed slices.** Strings, keywords, symbols, and unit
  suffixes are slices into the input buffer. The buffer must
  outlive the cursor. (`Binary.fromBinary` always deep-copies
  string and comment text into the destination arena, so the
  resulting `Tree` is self-contained and does not borrow from
  `bytes`.)
- **No allocation.** `init`, `rootIter`, `ChildIter`, `VectorIter`,
  and `skipBody` allocate nothing.

`Validator.validateBinary` and `Expr.evalExprBinary` both consume
the cursor directly. Neither builds an intermediate `Tree`.

### 10.5 Round-trip contract (lossless mode)

For any tree `t`:

```
parse(s) ≡ fromBinary(toBinary(parse(s), .{ .mode = .full })).structurally-equal(parse(s))
```

That is, parse → encode-with-all-flags-on → decode produces a
tree with the same nodes, same children, same trivia, same source
spans. The contract is enforced by per-form regression tests over
the shared round-trip fixture corpus, currently stored at
`fixtures/json_roundtrip.sjon`. Lossless print on the round-trip
output is byte-identical to lossless print on the input.

### 10.6 Substrate limits

Hard caps applied on encode and decode (rejection rather than
silent truncation):

| Limit | Value | Meaning |
| --- | --- | --- |
| `MAX_TREE_DEPTH` | 1024 | Comptime-asserted ≥ `Parser.MAX_PARSE_DEPTH`. |
| `MAX_NODES` | 2²⁰ | Maximum `Node` count per tree. |
| `MAX_STRING_POOL_ENTRIES` | 2¹⁶ | Maximum unique pooled strings. |
| `MAX_STRING_LENGTH` | 2²⁰ | Maximum bytes per pooled string. |
| `MAX_COMMENTS_PER_NODE` | 256 | Maximum comments attached to one node site. |
| `MAX_COMMENT_TEXT_LENGTH` | 2¹⁶ | Maximum bytes per individual comment. |
| `MAX_FILE_SIZE` | 2²⁸ | Maximum buffer size accepted. |

Real documents are far below every cap.

---

## 11. Structural editing

`applyEdit(source, action_json, opts)` is the substrate's
canonical structural-mutation operation: parse the source, apply a
JSON-encoded edit action, print the result. It is a *functional
rebuild* — the source tree is unchanged; the result is a freshly
constructed tree with the action applied at the given path. Trivia
outside the affected sub-tree is preserved.

```zig
const action = try std.json.parseFromSlice(std.json.Value, gpa,
    \\{ "op": "set_keyword",
    \\  "path": [],
    \\  "key": "bpm", "value": 140 }
, .{});
defer action.deinit();

const edited = try sjon.applyEdit(gpa, source, action.value, .{});
defer edited.deinit();
```

### 11.1 Action grammar

An action is a JSON object with three fields:

```json
{
  "op":   "<operation>",
  "path": [<segment>, <segment>, ...],
  ...                     // op-specific fields
}
```

The five operations:

| `op` | Op-specific fields | Meaning |
| --- | --- | --- |
| `set_keyword` | `key: string`, `value: <SJON-as-JSON>` | Set or replace a kvpair on the form at `path`. |
| `remove_keyword` | `key: string` | Remove a kvpair from the form at `path`. |
| `replace` | `value: <SJON-as-JSON>` | Replace the node at `path` with a freshly built sub-tree. |
| `insert_positional` | `value: <SJON-as-JSON>`, `index: integer?` | Insert a positional child into the form at `path`; appends when `index` is omitted. |
| `remove_positional` | `index: integer` | Remove the `index`th positional child from the form at `path`. |

`<SJON-as-JSON>` is a value in the canonical JSON encoding (§9).

### 11.2 Path

A path is a JSON array of **segments**. Each segment selects either
a positional child (by integer index) or a kvpair value (by string
key). Path elements are walked in order, depth-first, against the
source tree.

```json
[]                          // root form
[0]                         // first positional child of the root
["canvas"]                  // value of the :canvas kvpair on the root
[0, "name"]                 // value of :name on the first positional child
[0, 2]                      // third positional child of the first positional child
```

Mismatched paths (string segment against a non-form, integer out of
range, walking into an atom) return `error.InvalidPath`.

### 11.3 Single-root scope

`applyEdit` operates on **single-root** sources. Zero-root sources
(empty input) return `error.EmptyTree`; multi-root sources return
`error.MultipleRoots`. For editing inside a multi-root document,
parse the source, edit the desired root through `Tree`-level
helpers, and print the result.

### 11.4 Trivia preservation

The functional-rebuild walker uses `TreeBuilder.cloneNode` to
re-emit every sub-tree the action does not touch. Comments,
spans, and kvpair trivia ride along unchanged on the cloned
nodes. Only the action's target sub-tree (and any newly built
node from the action's `value`) gets trivia that doesn't survive
JSON encoding — those are by definition trivia-free.

---

## 12. Worked examples

### 12.1 A scene description

```sjon
(scene :bpm 130
  (canvas :name "main" :w 800 :h 600 :bg "#202028"
    (camera :ortho :zoom 1.5 :pos [0 0])

    (group :name "shapes"
      (circle :center [0 0]   :radius 0.5)
      (circle :center [1 0]   :radius 0.3)
      (rect   :origin [-1 -1] :size [0.5 0.5])

      (shape :sdf :radius (* 0.5 (b 1))
        :delay (b 4)
        :lifespan (b 16)))))
```

What the validator sees, given a schema with `core` plus a `shapes`
plugin (`scene`/`canvas`/`camera`/`group`/`circle`/`rect`) and a
`masagin`-style plugin (`shape`/`b`):

- `(scene …)` — known form. `:bpm 130` → `bpm` is a `:bpm` key on
  the `scene` spec; if `scene.open = true`, no diagnostic.
- `(camera :ortho :zoom 1.5 :pos [0 0])` — `:ortho` is a positional
  flag; `:zoom`/`:pos` are kvpairs.
- `(circle :center [0 0] :radius 0.5)` — both keys check against
  the `point` and `length` value kinds declared by the `shapes`
  plugin (`VectorShape{len=2, element="number"}` for `point`,
  unitless `number` for `length`).
- `(* 0.5 (b 1))` in the `:radius` slot — a safe expression. The
  validator confirms the head `*` is in `core`'s `expr_funcs`,
  arity matches; the inner `(b 1)` resolves against the `masagin`
  plugin's `b` function. At eval time, `b` returns seconds for `1`
  beat; `*` multiplies; the resulting number lands in the `:radius`
  slot.

### 12.2 A multi-plugin schema

```zig
const sjon = @import("sjon");
const core = sjon.plugins.core;
const shapes = @import("shapes.zig");
const masagin = @import("masagin.zig");

const schema = sjon.Schema.init(&.{
    core.plugin,
    shapes.plugin,
    masagin.plugin,
});
```

Bare lookups walk every plugin in declaration order. Two plugins
declaring the same form name yield an `.ambiguous` diagnostic at
parse-time validation; authors disambiguate by qualifying:

```sjon
(masagin/canvas …)        ; canvas from masagin, not shapes
(shapes/canvas  …)        ; canvas from shapes, not masagin
```

### 12.3 A safe-expression-driven parameter

```sjon
(group :name "fade"
  (shape :sdf
    :radius 0.5
    :alpha (lerp 1 0 (clamp t 0 1))))     ; t bound by the consumer's env
```

When the consumer evaluates `:alpha` for a given frame, it builds an
`Env` with `{ name: "t", value: frame_t }` and calls
`evalExpr(tree, alpha_node, env, schema)`. The evaluator walks
`(lerp 1 0 (clamp t 0 1))`:

1. Evaluate `(clamp t 0 1)`: lookup `t` in env, clamp to `[0, 1]`.
2. Evaluate `(lerp 1 0 clamped)`: `1 + (0 - 1) * clamped`.
3. Push the resulting number as the alpha for this frame.

The same expression evaluates again next frame with a new `t`
binding. The substrate makes no caching commitments; the consumer
is free to memoise per-frame if it has a stable identity for the
expression node.

### 12.4 Editing an existing document

Original:

```sjon
(scene :bpm 130
  (canvas :w 800 :h 600))
```

Action:

```json
{
  "op": "set_keyword",
  "path": [0],
  "key": "w",
  "value": 1024
}
```

Result:

```sjon
(scene :bpm 130
  (canvas :w 1024 :h 600))
```

Comments on `(scene …)`, on `:bpm 130`, and on `:h 600` ride along
unchanged through the rebuild — only the `:w 800` kvpair is
replaced.

### 12.5 Round-tripping through binary

```zig
var tree = try sjon.parse(gpa, source);
defer tree.deinit();

const bytes = try sjon.toBinary(gpa, tree, .{ .mode = .full });
defer bytes.deinit();

var decoded = try sjon.fromBinary(gpa, bytes.data, .{ .strings = .copy });
defer decoded.deinit();

const reprinted = try sjon.print(gpa, decoded, .{ .mode = .lossless });
defer reprinted.deinit();

// reprinted.data is byte-identical to the lossless print of the original tree.
```

---

## 13. Reference summary

### 13.1 Token kinds

```
(  )  [  ]
:keyword
symbol            ; identifier OR operator-like
number            ; with optional unit suffix (e.g. 4b, 90deg, 50%, 250ms)
date              ; YYYY-MM-DD
time              ; HH:MM:SS or HH:MM:SS.fff
"string"          ; with \\ \" \n \t \r \u{NNNN} escapes
true  false  nil
; line comment
#| block comment |#
```

### 13.2 Value kinds (the closed eleven)

```
nil   boolean   number   number_with_unit   date   time
string   keyword   symbol   vector   form
```

### 13.3 Forms

```
(<head> <child> ...)
(ns/<head> <child> ...)               ; qualified head
```

Children are positional values, kvpairs `:k v`, or positional
keyword flags (when the greedy pairing rule §5.4 promotes). Head
must be a symbol or one of `true`/`false`/`nil`.

Duplicate kvpair keys are validator errors on every form, open or
closed — kvpair lists carry map semantics regardless of openness
(§5.5, §7.3, §9.2).

### 13.4 Expression vocabulary (built-in `core`)

```
arithmetic   + - * / mod
comparison   < <= > >= = !=
logical      and or not                   ; and/or short-circuit
vectors      vec2 vec3 vec4
math         lerp clamp min max dot cross length
math-ext     abs sign floor ceil round fract sqrt pow
             sin cos tan asin acos atan atan2 radians degrees
constants    pi tau
smoothing    saturate step smoothstep
vector-ops   normalize distance reflect
list-ops     nth count
random       hash rand01 rand-range rand-int rand-bool rand-choice
control      let if cond
binders      map filter any all fold
```

### 13.5 Plugin descriptor shape

```zig
.{
    .name = "<namespace>",
    .forms = &.{ FormSpec, FormSpec, ... },
    .expr_funcs = &.{ ExprFunc, ExprFunc, ... },
    .value_kinds = &.{ ValueKind, ValueKind, ... },
}

FormSpec     { name, keys, positional ∈ none|any|kind, open,
               lowering?, description }
KeySpec      { name, value_type ∈ ValueType, optional, default?,
               walk_opaque?, description }
ExprFunc     { name, arity ∈ fixed|at_least|range, params?,
               param_names?, rest?, result?, signatures?, impl?,
               wasm_export_name?, description }
Signature    { arity ∈ fixed|at_least|range, params?, param_names?,
               rest?, result? }
ValueKind    { name, underlying ∈ number|string|vector|form|symbol|union_of,
               vector?, unit?, numeric?, members?, string_bounds?,
               heads?, cross_ref?, union_of?, description }

  vector?   on .vector  — { len?, element }
  unit?     on .number  — { required, allowed[] }
  numeric?  on .number  — { min?, max?, exclusive_min?, exclusive_max?, integer }
  members?  on .symbol|.string — { values[] }      (closed-set narrowing)
  string_bounds? on .string — { min_len?, max_len?, pattern?, format? }
  heads?    on .form    — { names[] }              (form-as-slot pinning)
  cross_ref? on .symbol — { target_form, name_key, scope_form?, acyclic }
  union_of? on .union_of — { alternatives[] }

ValueType    any | number | string | symbol | boolean | nil
           | vector | form | expr | named "<value-kind>"
```

### 13.6 JSON discriminators

```
$num      number with unit       [<value>, "<unit>"]
$date     date                   "YYYY-MM-DD"
$time     time                   "HH:MM:SS[.fff]"
$kw       keyword                "name"
$sym      symbol                 "name"
$form     form head              "head"
$ns       form namespace         "ns"   (only on qualified forms)
$children positional children only [c1, c2, ...]
$expr     safe expression        ["head", arg1, arg2, ...]
$roots    multi-root document    [r1, r2, ...]
```

User keys starting with `$` are escaped by doubling: `$foo` → `$$foo`.

### 13.7 Binary IR tags

```
0x00 nil       0x01 bool_false   0x02 bool_true
0x03 number    0x04 string       0x05 keyword       0x06 symbol
0x07 vector    0x08 form_bare    0x09 form_qualified
0x0A number_with_unit
0x0B number_i64 0x0C number_u64 0x0D date          0x0E time

0x10 child positional             0x11 child keyword
```

### 13.8 Edit operations

```
set_keyword         path key value
remove_keyword      path key
replace             path value
insert_positional   path value [index]
remove_positional   path index
```

### 13.9 Public API

```
parse            source [:0]const u8 → Ast.Tree
print            Tree → []u8                          (canonical | lossless)
validate         Tree × Schema → Validator.Result
evalExpr         (*Tree, NodeIndex) × Env × Schema → Expr.Result
toJson           Tree → std.json.Value                (canonical | lossy)
fromJson         std.json.Value → Tree
toJsonRoots      Tree → {"$roots": [...]}
fromJsonRoots    {"$roots": [...]} → Tree
applyEdit        source × action_json → []u8
toBinary         Tree → []u8                          (compact | canonical | full)
fromBinary       []u8 → Tree
validateBinary   []u8 × Schema → Validator.Result
evalExprBinary   []u8 × Env × Schema → Expr.Result
```

Every public output owns its allocator; `result.deinit()` releases
the entire intermediate graph in one call.

---

## 14. Extensibility

SJON is closed where the substrate cares (value kinds, expression
vocabulary at the `core` level, JSON discriminators, binary tags,
edit operations) and open where the substrate does not (plugin
forms, plugin expression functions, plugin value kinds). This
section formalises the extension story so future spec versions and
third-party plugins grow the language without breaking what is
written today.

The guiding principle: **the closed sets grow via spec versions; the
open extension surface lives in plugin descriptors.** Both are
forward-compatible by design.

### 14.1 Plugin growth

Domain plugins extend SJON without spec coordination. A new plugin
brings:

- New form constructors (`forms`).
- New safe-expression functions (`expr_funcs`).
- New value-kind refinements (`value_kinds`).

A plugin's namespace (`Plugin.name`) shields its identifiers from
collisions across plugins. Bare lookups across multiple plugins
report `.ambiguous` rather than silently picking; authors qualify
with `<ns>/<name>` when that happens.

A plugin author MAY incubate experimental forms or expression
functions inside their plugin, ship them to consumers, gather
feedback, and rename or remove them at will. The static Zig path uses
a comptime *aggregator* (`Schema.init`), so authors discover
static-plugin breakage when their build fails. Portable manifests use
the same descriptor shape, but failures surface as host load or
aggregate diagnostics.

### 14.2 Versioning the closed sets

The substrate's closed sets — value kinds, the `core` expression
vocabulary, JSON discriminators, binary tags, edit operations —
grow only via spec versions. The growth path:

1. **Propose** a new entry on a SJON spec branch. Real-world plugin
   experience surfaces design issues before merging.
2. **Add** the entry in a minor version. Consumers built against
   the older spec continue to load older documents; documents using
   the new entry require the new substrate version.
3. **Pin** binary-tag and JSON-discriminator allocations at the
   minor-version bump. They never change meaning across versions.
4. **Reject** unknown wire entries: an unknown binary tag yields
   `error.InvalidTag`, an unknown JSON discriminator yields
   `error.UnknownDiscriminator`. Forward-incompatible reads are loud
   failures, never silent ones.

A consequence: a wire v4 reader knows `time` is tag `0x0E`, while
an older reader rejects the v4 buffer before it can reinterpret the
new entry as an older shape.

### 14.3 What is deliberately not extensible

The following are out of scope as plugin extensions:

- **User-defined value kinds in the abstract sense.** Plugins
  declare `ValueKind` refinements of five concrete `Underlying`
  shapes (number, string, vector, form, symbol) or a flat
  `union_of` over existing kinds. Refinement axes include vector
  shape, number units and numeric bounds, string bounds, symbol or
  string members, form heads, and symbol cross-references. Adding a
  new concrete `Underlying` (`mat4`, `bytes`) or a new abstract
  value kind is a substrate-level change. The abstract
  eleven-value-kind vocabulary in §3 grows only via spec versions.
- **User-defined expression control flow.** `let`, `if`, `cond`,
  `and`, `or` are handled by dedicated frames in the evaluator,
  not by `applyFunction`. A plugin cannot register a new lazy form
  through `expr_funcs` — every plugin function is eager.
- **User-defined cascade modes / combine functions.** SJON has no
  cascade machinery at the substrate level. Domain plugins that
  need cascading semantics implement them in their own consumer
  layer; the substrate carries the data.
- **Mutable bindings inside `let`.** Bindings are bind-once. There
  is no `set!` operation at the language level. To compute and
  thread state, return a new value.
- **Macros.** A form is what it is; there is no syntactic
  rewrite step between parse and validate. A "macro" is what a
  domain plugin builds in its own consumer code.
- **Conditionals inside paths (Edit).** Edit paths are sequences
  of positional indices and key names. There is no path
  predicate language; selecting "every form named `circle`" is
  the consumer's job, performed by walking the tree.

These limits are what keep SJON parseable, validatable, and
predictable. Extensions needing any of them are not SJON
extensions — they are a different language, possibly one that
compiles down to SJON.

### 14.4 Per-channel forward compatibility

Each cross-version channel has its own forward-compat story:

- **Text → Tree.** The lexer is total; any byte stream parses to
  some tree, with diagnostics for ill-formed input. Future
  syntactic additions (new escape codes, new literal forms) ride
  in as new lexer states behind a backwards-compatible
  distinguished prefix.
- **Tree → JSON canonical.** New value kinds get new
  discriminators. Decoders reject unknown discriminators loudly
  (`error.UnknownDiscriminator`).
- **Tree → Binary IR.** New value kinds get new tag bytes.
  Decoders reject unknown tags loudly (`error.InvalidTag`). The
  wire `version` byte tracks incompatible tag growth: v2 adds
  exact integer tags, v3 adds `date`, and v4 adds `time`.
  Older decoders correctly reject newer buffers before reading
  nodes they do not understand.
- **Tree → Tree (Edit).** New `op` values are loudly rejected
  with `error.UnknownOp`. New op-specific fields are silently
  ignored only when they begin with an underscore — an editorial
  convention, not a wire commitment.

Substrate-level forward compatibility is one-way: a new substrate
loads everything an older substrate could load; an older
substrate refuses cleanly when it encounters something new.

### 14.5 Portable plugin manifests

The in-process plugin model (`Plugin`, `FormSpec`, `KeySpec`,
`ValueKind`, `ExprFunc`) has a serialised companion: a v1 manifest
format that lets a plugin descriptor travel as a SJON document
instead of a Zig comptime artifact. Hosts in any language can load a
manifest and run validation / linting / completion against the same
diagnostic surface §7.6 documents.

The current layer contract lives in
[`docs/plugin-model-v1.md`](plugin-model-v1.md). The manifest syntax
sub-spec lives in `docs/portable-manifest-v1.md`, the executable WASM
sidecar ABI lives in `docs/executable-plugin-abi.md`, and the bootstrap
meta-plugin (which describes the manifest format in its own syntax)
lives in `manifests/meta.sjon`. Static Zig plugins remain a first-class
option; manifests are the portable representation, not a replacement for
in-process descriptors.

---

## 15. Glossary

**arena** — `std.heap.ArenaAllocator` backing a tree, result, or
bytes structure. `result.deinit()` releases the entire arena.

**ChildTag** — wire byte distinguishing a positional child
(`0x10`) from a kvpair child (`0x11`) inside a binary form.

**closed set** — a set whose membership grows only via substrate
spec versions: value kinds, `core` expression vocabulary, JSON
discriminators, binary tags, edit operations, lexer state machine.

**comment** — line (`; …\n`) or block (`#| … |#`) trivia. Survives
lossless print and binary IR with comment flags; dropped by
canonical print and JSON.

**cursor** — `BinaryCursor.Cursor`, the zero-allocation read
walker over a binary IR buffer.

**diagnostic** — `Ast.Diagnostic { span, message, severity }`. The
parser, validator, and lexer all surface diagnostics through the
same shape so editors render parse and validate findings in one
UI.

**Edit (op)** — a JSON-encoded structural mutation:
`set_keyword`, `remove_keyword`, `replace`, `insert_positional`,
`remove_positional`. Applied to a path inside a single-root tree.

**Env** — `Expr.Env`, the lexically-scoped binding chain consulted
by the safe-expression evaluator.

**ExprFunc** — `Plugin.ExprFunc`, a declared safe-expression
function. May be implemented (`impl != null`) or
declaration-only.

**FormSpec** — `Plugin.FormSpec`, a declared data-form
constructor. Defines accepted keys, positional stance, and
open/closed treatment of unknown keys.

**form** — `(<head> <child> ...)`. Either a data form (head in
`FormSpec`) or a safe expression (head in `ExprFunc`).

**identifier** — a token in the symbol/keyword character set
(letters, digits, `_`, operators, `.`, `/`, `-` non-leading). See
§2.3.

**kvpair** — a `:key value` pair inside a form, materialised as a
`Tag.kvpair` AST node.

**lossless mode** — print or binary mode that preserves spans and
comments. Round-trips byte-for-byte through Binary IR with all
flags on.

**lossy mode** — JSON encoding that collapses keywords, symbols,
and strings into bare JSON strings. One-way; no round-trip claim.

**namespace** — the `<ns>` part of a qualified form head
`<ns>/<name>`. Always equal to a `Plugin.name` for a successful
lookup.

**Plugin** — `Plugin.Plugin`, a comptime descriptor of a
vocabulary extending SJON: forms, expression functions, value
kinds.

**positional flag** — a `:keyword` value committed by the parser's
greedy rule (§5.4) when no value followed it. Promoted from
"pending key" to a positional `keyword` value in the form's child
list.

**roots** — the top-level value list of a SJON document. May be
empty, single, or multiple. Multi-root documents bridge through
`{"$roots": [...]}` (§9.4).

**Schema** — `Schema.Schema`, a comptime aggregate over one or
more `Plugin` descriptors. Source of truth for form-head and
expression-function lookup.

**span** — `Ast.Span { start, end }`, byte offsets into the
original source. Survives lossless print and binary IR with span
flags; meaningless once the source buffer is freed.

**string pool** — per-tree deduplicated identifier and string
storage in the binary IR, sorted by `(length, bytes)` for
deterministic output.

**substrate** — SJON itself. Distinguished from a *domain*, which
is a vocabulary built out of plugins on top of SJON.

**Tree** — `Ast.Tree`, the canonical SoA AST. Self-contained
behind a single arena; arena release frees every owned slice.

**unit** — opaque ASCII suffix on a `number_with_unit` value.
The substrate carries the slice forward without interpretation.

**value** — anything that may appear where a value is expected.
Eleven kinds (§3); closed.

**ValueKind** — `Plugin.ValueKind`, a plugin-declared typed
refinement of an `Underlying` kind (number / string / vector /
form / symbol / union_of). Referenced from
`KeySpec.value_type = .{ .named = "..." }`.

**ValueType** — `Plugin.ValueType`, the validator's per-slot type
vocabulary. Closed; references plugin value kinds via `.named`.

**v1** — the substrate spec series this document describes. Wire
version is currently `0x04`; closed-set additions are minor-version
bumps and may advance the binary wire version.
