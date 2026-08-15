# 12 - Value Kinds: Strings, Members, Heads, Unions, Slot-Local Forms

## Goal

This is part 2 of value kinds, covering string bounds, member sets,
head sets, unions, and slot-local forms, plus the diagnostic cheat
sheet for every value-kind diagnostic. Read these refinements and write values that
satisfy them; when a value is rejected, work back from the diagnostic
code to the layer of the contract you missed.

## Mental Model

Part 1 introduced the named-kind pattern and worked through underlying
shapes, vector shapes, unit shapes, numeric bounds, and representation
tags. The five refinements in this chapter are the remaining axes a
plugin can use to narrow what a slot accepts: codepoint-length and
format constraints on strings, closed lists of symbol or string values,
closed lists of allowed form heads, unions that combine several
alternatives behind one slot, and slot-local forms that a slot defines
inline. The reading habit stays the same — underlying shape first, then
refinement, then surface value — but each axis has its own diagnostic
code, so the cheat sheet at the end of the chapter is the fastest path
back to the right line in the plugin docs.

## String Bounds

A string bound refinement applies to a string-underlying kind and
constrains the value's length, pattern, or format. Each field is
optional; the validator applies them cheapest-first (length, then
format, then pattern).

Example contracts:

```text
slug:           string, length 1–64, format path
email-address:  string, format email
semver-string:  string, format semver
```

Accepted values for `slug`:

```sjon
(post :id "intro")
(post :id "release-notes-2026-05")
```

Rejected because below `:min-len`:

```sjon
(post :id "")
```

Likely diagnostic: `string_too_short`. Other diagnostics in this
family:

- `string_too_long`            — codepoint count above `:max-len`.
- `string_format_mismatch`     — value fails the declared `:format` (one of email / uri / path / uuid / semver).
- `string_pattern_unsupported` — `:pattern` is declared but this build has no regex engine; warning, validation still succeeds.
- `string_pattern_mismatch`    — reserved for the engine milestone; v1 builds never emit it.
- `string_bounds_invalid`      — loader-emitted: empty range, negative bound, empty pattern, wrong underlying, or a member literal that itself fails the declared length / format.

Length is measured in UTF-8 codepoints, so `"héllo"` (5 cp / 6 bytes)
passes `:max-len 5`. The parser guarantees well-formed UTF-8, so
the count is total. No normalisation is applied — precomposed `"é"`
(1 cp) and decomposed `"é"` (2 cp) count differently.

`:pattern` is accept-but-warn in v1: declaring it does not yet
enforce a regex (the engine lands later), but the loader stores the
source and the validator fires `string_pattern_unsupported` at every
matched value site so authors know the constraint is informational.
The wire shape is stable — once the engine lands, the same manifest
starts enforcing the regex without a spec change.

## Member Sets

A member set is a closed list of accepted values for a symbol-underlying
or string-underlying kind.

For the shapes plugin:

```text
fill-rule: symbol, members evenodd | nonzero
```

Accepted:

```sjon
(circle :center [0 0] :radius 1 :fill evenodd)
(circle :center [0 0] :radius 1 :fill nonzero)
```

Rejected:

```sjon
(circle :center [0 0] :radius 1 :fill diagonal)
```

Likely diagnostic: `not_member`. Repair with one of the documented
symbols:

```sjon
(circle :center [0 0] :radius 1 :fill evenodd)
```

Do not repair symbol member sets with keywords:

```sjon
(circle :center [0 0] :radius 1 :fill :evenodd)
```

That runs into the keyword-pairing rule from chapter 5. `:fill` no
longer receives a value; both `:fill` and `:evenodd` are read as
positional flags. Closed enum-like values are usually symbols:

```sjon
:fill evenodd
```

If a plugin documents a string-underlying member set, then use quoted
strings instead:

```text
blend-mode: string, members "normal" | "multiply"
```

```sjon
(layer :blend "multiply")
```

The contract decides whether the closed values are symbols or strings.

A member set is closed *and* written in the plugin. Chapter 13 covers
the other way a symbol slot gets a fixed list of legal values: read out
of the document being validated, or extracted from a string inside it.

## Head Sets

A head set applies to a form-underlying kind. It says "the slot value
must be a nested form, and the nested form's head must be one of these."

For the shapes plugin:

```text
shape-form: form, heads circle | rect
```

Accepted:

```sjon
(badge :label "dot"
  :shape (circle :center [0 0] :radius 1))

(badge :label "box"
  :shape (rect :origin [0 0] :size [10 10]))
```

Rejected:

```sjon
(badge :label "bad" :shape (group :name "not-a-shape"))
```

`group` is a known form, but it is not a member of the allowed head set.
Likely diagnostic: `not_head_member`. Repair with one of the allowed
heads:

```sjon
(badge :label "ok" :shape (rect :origin [0 0] :size [10 10]))
```

A head set is different from a symbol member set:

- `:fill evenodd` stores a symbol value and checks it against
  `evenodd | nonzero`.
- `:shape (circle ...)` stores a form value and checks the form head
  against `circle | rect`.

## Unions

A union says "this value may satisfy any one of these alternatives."
Each alternative is another named kind or a primitive shortcut like
`number`, `symbol`, or `form`.

The validator tries alternatives in the order the plugin declared them.
As an author, the main thing to notice is the failure case: if no
alternative accepts the value, the diagnostic lists the alternatives as
a menu of legal shapes.

Example music contract:

```text
pitch: symbol, members E4 | G4 | A4 | B4 | _
event: form, heads n | rest
note-or-event: union pitch | event

(phrase ...)
  :notes vector<note-or-event> optional
```

Now every element of `:notes` is checked against the union:

```sjon
(phrase :notes [E4 (n G4 0.5b) _ (rest 0.25b)])
```

Read the elements:

- `E4` satisfies `pitch`.
- `(n G4 0.5b)` satisfies `event`.
- `_` satisfies `pitch`.
- `(rest 0.25b)` satisfies `event`.

This fails:

```sjon
(phrase :notes [E4 X4 (n G4 0.5b)])
```

`X4` is not in the pitch member set, and it is not a form, so no
alternative accepts it. Likely diagnostic: `union_no_branch_matched`.
Repair with a value that fits one branch:

```sjon
(phrase :notes [E4 G4 (n G4 0.5b)])
```

The diagnostic lists the alternatives the plugin declared. Use that
list as a menu of legal shapes.

### Form Alternative Pitfall

A union alternative named `form` is not a wildcard for unknown
parenthesized syntax.

Assume this contract:

```text
vec4: vector, length 4, element number
value: union number | vec4 | form
```

Assume `(set ...)` itself is a known form. This still fails if `foo`
is not declared by any loaded plugin:

```sjon
(set :value (foo 1 2))
```

Likely diagnostic: `unknown_form`, not `union_no_branch_matched`. The
slot accepts form-shaped values, but form heads still resolve against
the schema. Repair by using a form whose head the schema knows:

```sjon
(set :value (+ 1 2))
```

If a plugin truly wants to accept absolutely any value, the slot is
typed `any`. A union containing `form` means "any declared form," not
"any parentheses."

### The scalar-or-ref Shorthand

One union shows up often enough to earn its own shorthand: "a literal
value, or a symbol that names a constant defined elsewhere." A plugin
writes it as a `scalar-or-ref` kind over a base kind, and the loader
expands it to `union base | symbol`.

```text
dim-value: number
dim: scalar-or-ref, base dim-value
```

So `dim` accepts either a number or a bare symbol:

```sjon
(dispatch :x 64 :y WORKGROUP_SIZE :z 1)
```

`64` and `1` take the scalar branch; `WORKGROUP_SIZE` is a bare symbol,
so it takes the reference branch, naming a constant the host resolves
later (the same `#define`-style pattern as a cross-reference, the
subject of the next chapter).

A quoted string is neither a number nor a symbol:

```sjon
(dispatch :x "64" :y WORKGROUP_SIZE)
```

Likely diagnostic: `union_no_branch_matched`. The shorthand is a union
underneath, so a value that fits no branch fails exactly as a
hand-written union would. Repair by dropping the quotes for a reference,
or writing a number for a literal:

```sjon
(dispatch :x 64 :y WORKGROUP_SIZE)
```

## Slot-Local Forms

A head set restricts a form slot to a closed list of *global* form
heads. A slot-local form set goes one step further: the slot defines its
own forms inline, right where it is declared. Those local forms are part
of the slot's contract, not the global vocabulary.

```text
(canvas ...)
  :shape form, local circle | rect | group
    circle: (r number required)
    rect:   (w number required) (h number required)
    group:  (child form required, local dot)
```

`canvas`'s `:shape` slot defines a local `circle`, `rect`, and `group`.
Resolution follows three rules.

**Local first.** A head that names a local form resolves to that local
form:

```sjon
(canvas :shape (circle :r 12))
```

This local `circle` takes `:r`. If a global `circle` also exists, the
local one shadows it inside this slot - so a global `circle` that took
`:radius` is not what is checked here.

**Additive fallback.** A head that is not local still resolves against
the global vocabulary:

```sjon
(canvas :shape (line :from [0 0] :to [10 10]))
```

`line` is not one of the slot's local forms, so it falls back to the
global `line`. Local forms add to the global set; they do not hide it,
except where a name collides as `circle` does above.

**Local forms nest.** A local form can declare its own local slots:

```sjon
(canvas :shape (group :child (dot)))
```

The local `group` has a `:child` slot with its own local `dot`.

A head that matches neither a local form nor a global one is the error
case:

```sjon
(canvas :shape (triangle))
```

Likely diagnostic: `unknown_local_form`. This is more specific than the
plain `unknown_form` you would get at the top level, because the slot
narrowed the choices. Repair with a head the slot accepts - a local
form, or a known global one:

```sjon
(canvas :shape (circle :r 12))
```

Two boundaries are worth remembering. A local form is invisible outside
its slot: writing `(rect :w 1)` at the top level is an ordinary
`unknown_form`, because `rect` exists only inside `canvas`'s `:shape`. And
a namespace-qualified head skips local resolution entirely; it goes
straight to the global vocabulary.

## Diagnostic Cheat Sheet

When a value kind fails, the diagnostic usually tells you which layer
of the contract you violated:

| Diagnostic | What to reread |
| --- | --- |
| `wrong_underlying` | The kind's underlying shape: number, string, symbol, vector, form. |
| `vector_length_mismatch` | The fixed vector length (`:len`). |
| `vector_too_short` / `vector_too_long` | The `:min-len` / `:max-len` element-count window. |
| `repr_out_of_range` | The `:repr` machine type's range, and integrality for integer types. |
| `unit_required` | The unit requirement on a number-underlying kind. |
| `unit_not_allowed` | The allowed unit suffix list. |
| `unit_forbidden` | The kind rejects every unit; drop the suffix. |
| `not_member` | The closed symbol or string member list. |
| `not_head_member` | The closed form head list. |
| `unknown_local_form` | The slot's own local form set, plus the global vocabulary. |
| `union_no_branch_matched` | The union alternatives. |
| `string_too_short` / `string_too_long` | The `:min-len` / `:max-len` codepoint bound. |
| `string_format_mismatch` | The named format checker (email / uri / path / uuid / semver). |
| `string_pattern_unsupported` | The `:pattern` constraint is informational in this build (no regex engine). |

This is the repair loop:

1. Find the form and key in the diagnostic path.
2. Read that key's declared value type in the plugin docs.
3. If the key names a value kind, read the value-kind line.
4. Rewrite the value to match the underlying shape first, then the
   refinement.

## Exercises

For each exercise, read the contract first, then repair the source.

### Member Set

Contract:

```text
fill-rule: symbol, members evenodd | nonzero
(circle ...)
  :fill fill-rule optional
```

```sjon
(circle :center [0 0] :radius 1 :fill diagonal)
```

Repair:

```sjon
(circle :center [0 0] :radius 1 :fill evenodd)
```

Do not repair it with a keyword:

```sjon
(circle :center [0 0] :radius 1 :fill :evenodd)
```

That triggers the keyword-pairing problem from chapter 5.

### Head Set

Contract:

```text
shape-form: form, heads circle | rect
(badge ...)
  :shape shape-form optional
```

```sjon
(badge :label "bad" :shape (group :name "not-a-shape"))
```

Repair with an allowed head:

```sjon
(badge :label "ok" :shape (rect :origin [0 0] :size [10 10]))
```

### Union

Contract:

```text
pitch: symbol, members E4 | G4 | A4 | B4 | _
event: form, heads n | rest
note-or-event: union pitch | event
(phrase ...)
  :notes vector<note-or-event> optional
```

```sjon
(phrase :notes [E4 X4 (n G4 0.5b)])
```

`X4` is not in the pitch member set, and it is not a form, so neither
alternative accepts it. Likely diagnostic: `union_no_branch_matched`
naming `pitch` and `event`. Repair with a value that fits one of the
alternatives:

```sjon
(phrase :notes [E4 G4 (n G4 0.5b)])
```

### Union With Form Alternative

Contract:

```text
vec4: vector, length 4, element number
value: union number | vec4 | form
(set ...)
  :value value required
```

Assume `(set ...)` itself is a known form.

```sjon
(set :value (foo 1 2))
```

If `foo` isn't a head in any loaded plugin, this fails with
`unknown_form`. The `form` alternative does not turn the slot into
"any parenthesized construct accepted." Repair by using a form whose
head the schema knows about:

```sjon
(set :value (+ 1 2))
```

If you genuinely need to put a domain-specific construct here, check
the plugin's loaded form vocabulary first - or look for whether the
plugin has a separate slot documented as `any`.

### scalar-or-ref

Contract:

```text
dim-value: number
dim: scalar-or-ref, base dim-value
(dispatch ...)
  :x dim required
```

```sjon
(dispatch :x "64")
```

Repair with a literal, or a bare symbol that names a constant:

```sjon
(dispatch :x 64)
```

### Slot-Local Form

Contract:

```text
(canvas ...)
  :shape form, local circle | rect | group
    circle: (r number required)
```

```sjon
(canvas :shape (triangle))
```

Repair with a head the slot accepts:

```sjon
(canvas :shape (circle :r 12))
```

## Mastery Check

- What does a member set usually mean for authoring?
- Why is a head set different from a symbol member set?
- What does `union_no_branch_matched` tell you to reread?
- When a union slot lists `form` as one of its alternatives, does
  that mean any parenthesized construct is accepted?
- What does the `scalar-or-ref` shorthand expand to, and which
  diagnostic fires when a value fits no branch?
- How does a slot-local form set change head resolution, and what
  distinguishes `unknown_local_form` from `unknown_form`?

Next: [Cross-References](13-cross-references.md).
