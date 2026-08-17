---
type: lesson
title: 'Value Kinds: Strings, Members, Heads, Unions, Slot-Local Forms'
---

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

### Enums whose names start with a digit

Some enums name their members with a digit first. WebGPU's texture
dimensions are `"1d"`, `"2d"`, `"3d"`; its view dimensions add `2d-array`,
`cube`, and `cube-array`. A plugin may declare those directly:

```text
texture-dimension: symbol, members 1d | 2d | 3d
view-dimension:    symbol, members 1d | 2d | 2d-array | cube | cube-array | 3d
```

Accepted:

```sjon
(texture :name albedo :dimension 2d :view 2d-array)
```

`2d-array` works for the reason chapter 4 gives: inside a unit, a hyphen
joins two letter runs when a letter follows it, so the unit here is
`d-array` and the whole thing is one value. Without that rule this was
`2d` plus a stray symbol `-array` — one intended value, two diagnostics.

You write the spelling the spec uses. There is no quoting and no numeric
lookup table to memorise — this is what schemas used to force, with
`:view-dimension 3 ; cube` and a comment carrying the meaning.

Why this needs its own section: `2d` is not a symbol. Chapter 4 showed
that a digit-leading token lexes as a **number with a unit** — value `2`,
unit `d`. So the schema matches on that pair rather than on the text, and
three consequences follow:

```sjon
(texture :dimension 2.0d)   ; ✓ same magnitude, same unit
(texture :dimension 02d)    ; ✓ the leading zero is not part of the name
(texture :dimension 2.5d)   ; ✗ fractional — matches no member
(texture :dimension 2b)     ; ✗ the unit is part of the name
(texture :dimension 2)      ; ✗ no unit, so not a spelling at all
```

The last two fail differently, and the difference is informative.
`2b` is `not_member` — a unit-bearing number *is* the right shape here, it
is simply not one of the three. `2` is `wrong_underlying` — a bare number
is not a name in the first place.

Repair drill:

```sjon
(texture :name albedo :dimension 4d)
```

`not_member`, and the diagnostic names the set:

```
got `4d` (allowed: `1d`, `2d`, `3d`)
```

so pick one of the three:

```sjon
(texture :name albedo :dimension 3d)
```

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

## How Many?

On a form's `:positional` slot — where the head set governs a *list* of
children rather than one value — it can bound the count as well as the
vocabulary. Spell the heads out as `(head …)` children and each one may
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

Read the three spellings carefully, because the floor defaults to 0:

- `:min 1 :max 1` — exactly one.
- `:max 1` alone — at most one. Zero is fine.
- no bound — any number, including zero.

Accepted:

```sjon
(render-pipeline :name main
  (vertex :entry vs_main)
  (fragment :entry fs_main)
  (constant :name gamma :value 2.2)
  (constant :name exposure :value 1.0))
```

Too many:

```sjon
(render-pipeline :name main
  (vertex :entry vs_main)
  (fragment :entry fs_main)
  (fragment :entry fs_alt))
```

`positional_too_many`, reported **on the second `(fragment …)`** — the
line to delete. Not on the parent, and not once per extra child: a form
four `(fragment …)` children over its ceiling still gets one diagnostic,
naming the real count.

Too few:

```sjon
(render-pipeline :name main
  (fragment :entry fs_main))
```

`positional_missing`, reported **on `(render-pipeline …)` itself**. You
cannot know a head is absent until the children run out, so there is no
child to point at — the same reason a missing required key lands on the
form's head rather than anywhere in particular.

Three things that will save you a debugging session:

- `:names [a b c]` cannot carry a count. The two spellings are exclusive,
  so adding a bound to one head means writing them all as `(head …)`.
- **`:open true` does not turn the counts off.** Openness widens which
  *keywords* a form accepts. A positional count is a different surface,
  and declaring `:positional <bounded-kind>` opts into it.
- **The counts only bite on `:positional`.** Reuse the same kind on a
  `(key :type pipeline-section)` slot and the bounds ride along inertly —
  a keyed slot holds one value, so `:max 1` is trivially true and `:min 1`
  has no set to be missing from. Deliberate: it keeps a bounded kind
  shareable between a slot that has a population and one that doesn't.

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

### Order Is Part Of The Contract

Alternatives are tried in declaration order and the first one that
accepts wins. No alternative is "more specific" than another, and none
is preferred by shape — order is the whole rule.

Most of the time this is invisible, because alternatives do not overlap:
a symbol cannot satisfy `vec4`, a vector cannot satisfy `pitch`. But
when two alternatives *can* both accept the same value, order decides
which one, and that is usually deliberate:

```text
byte-count: number
size: union byte-count | symbol
```

`1024` matches `byte-count`. A bare name matches the `symbol` half. Had
the plugin listed `symbol` first, it would still only claim symbols, so
nothing changes here — but a union of two *symbol* kinds is a different
story, and lesson 13 shows the case where order quietly decides which
entity a name refers to.

The practical rule for reading a schema: when two alternatives overlap,
the earlier one is what you get. When you cannot tell which one accepted
your value, ask the tooling — go-to-definition on the value will land in
whichever declaration actually claimed it.

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

#### Is the reference half checked?

Read the plugin line carefully, because two `scalar-or-ref` kinds that
look alike behave very differently on a typo. The reference half is
whatever the plugin named as its `ref`, and if it named nothing, the
answer is the plain `symbol` type — which accepts *any* spelling.

```text
dim:     scalar-or-ref, base dim-value                   ; ref defaults to symbol
bones:   scalar-or-ref, base bone-count, ref define-ref  ; ref is a cross-ref kind
```

Now misspell a constant in each:

```sjon
(dispatch :y WORKGROUP_SIZ)     ; A — validates clean
(mesh :bones MAX_BONE)          ; B — union_no_branch_matched
```

Line A passes. `WORKGROUP_SIZ` is a perfectly good symbol, and the
reference half only asked for a symbol — nothing checked that a constant
by that name exists. The mistake surfaces later, at whatever point the
host tries to resolve it.

Line B fails at validate time, because `define-ref` is a cross-reference
kind and the document contains no matching `(define …)`.

Note the diagnostic on line B: `union_no_branch_matched`, not
`not_cross_ref`. The kind is a union underneath, and a union reports
that no alternative matched rather than forwarding one branch's private
reason. So read the message's alternative list — it tells you which two
shapes were tried, and the second one is where a name was expected.

## Slot-Local Forms

A head set restricts a form slot to a closed list of allowed form
*heads*. A slot-local form set goes one step further: the slot defines
its own forms inline, right where it is declared. Those local forms are
part of the slot's contract, not the global vocabulary.

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

## Head Sets and Slot-Local Forms

These two features look like they compete. They do not — they run in
sequence, and reading a diagnostic correctly depends on knowing which
step produced it.

**Step one: is this head allowed here?** The head set answers that from
the head's *text* alone. It compares spelling against its list and looks
nothing up.

**Step two: what is the body checked against?** Only now does the
validator go looking for a form of that name, and it looks locally
first, then globally.

The consequence is worth stating plainly, because it saves you writing
forms you do not need: a head set names *spellings*, not declarations. If
the only `storage-texture` form is a local of the slot you are in, the
head set is satisfied and the body is checked against that local. You do
not need to declare a global `storage-texture` to "make the name
resolve."

Now predict the diagnostics. The head set is `[buffer storage-texture
ghost]`, and there is a local form for `buffer` and `storage-texture` but
none anywhere for `ghost`:

```sjon
(entry :binding 0 (sampler :type filtering))     ; A — head not in the set
(entry :binding 0 (ghost :x 1))                  ; B — head in the set, no form
```

Line A produces **two** diagnostics: `not_head_member` from step one,
and `unknown_local_form` from step two. Both steps failed, so both
report.

Line B produces **one**: just `unknown_local_form`. This is the case
worth remembering — the head set *admitted* `ghost`, because `ghost` is
on its list, and the complaint came entirely from step two having
nothing to descend into. A head set will never tell you a name is
undeclared; that is not its job.

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
| `not_member` | The closed symbol or string member list. On a digit-leading set, also check the magnitude *and* the unit. |
| `not_head_member` | The closed form head list. |
| `positional_too_many` | That head's `:max`. Reported on the child that crossed it. |
| `positional_missing` | That head's `:min`. Reported on the parent form's head. |
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

### Digit-Leading Member Set

Contract:

```text
texture-dimension: symbol, members 1d | 2d | 3d
(texture ...)
  :dimension texture-dimension optional
```

Predict the diagnostic for each, then repair:

```sjon
(texture :name a :dimension 4d)
(texture :name b :dimension 2b)
(texture :name c :dimension 2)
(texture :name d :dimension 2.5d)
```

The first, second, and fourth are `not_member` — each is a unit-bearing
number, which this slot accepts as a shape; they are just not in the set.
The third is `wrong_underlying`: a bare number is not a spelling at all,
so it fails one layer earlier.

Repair:

```sjon
(texture :name a :dimension 3d)
(texture :name b :dimension 2d)
(texture :name c :dimension 2d)
(texture :name d :dimension 2d)
```

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

### Positional Counts

Contract:

```text
pipeline-section: form, heads vertex (exactly 1) | fragment (at most 1) | constant (any)
(render-pipeline ...)
  :name symbol required
  positional pipeline-section
```

```sjon
(render-pipeline :name main
  (vertex :entry vs_main)
  (fragment :entry fs_main)
  (fragment :entry fs_alt))
```

Two `(fragment …)` children against `:max 1`. Likely diagnostic:
`positional_too_many`, on the *second* fragment — the extra one, not the
form. Repair by removing it:

```sjon
(render-pipeline :name main
  (vertex :entry vs_main)
  (fragment :entry fs_main))
```

Now predict this one before reading on:

```sjon
(render-pipeline :name main
  (fragment :entry fs_main)
  (constant :name gamma :value 2.2))
```

`positional_missing` — `vertex` is `:min 1` and there is none. It is
reported on `(render-pipeline …)` itself, because the fact "no vertex
anywhere in this list" belongs to the list, not to any child in it. Note
that `constant` being present helps not at all: a child counts towards a
head only if its own head matches, so nothing else can stand in for a
missing `vertex`. Repair by adding one:

```sjon
(render-pipeline :name main
  (vertex :entry vs_main)
  (fragment :entry fs_main)
  (constant :name gamma :value 2.2))
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

<section class="mastery-quiz" data-lesson="value-kinds-refinements">
  <h2>Mastery Check</h2>
  <ol class="mc-list">
    <li class="mc-item" data-correct="0">
      <p class="mc-q">What does a member set usually mean for authoring?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-0" value="0" /> <span>You must use one of a closed list of symbol or string values declared by the plugin.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-0" value="1" /> <span>You may write any symbol; the plugin will accept it.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-0" value="2" /> <span>The slot accepts any number.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q"><code>2d</code> is a legal member of a <em>symbol</em> member set, yet <code>2d</code> is not a symbol. How does that work?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-1" value="0" /> <span>The lexer makes an exception for <code>d</code> and reads <code>2d</code> as a symbol.</span></label>
        <p class="mc-explanation" hidden>There is no such exception, and there could not be a useful one: the unit alphabet is not a list of enum names.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-1" value="1" /> <span>The schema stores the member as a <code>(magnitude, unit)</code> pair and matches the number against it — the value stays a unit-bearing number.</span></label>
        <p class="mc-explanation" hidden>Correct. A digit-leading spelling is <em>accepted</em> in a symbol slot, never rewritten — the tree, the binary IR, and the JSON bridge all keep <code>{&quot;$num&quot;: [2, &quot;d&quot;]}</code>. That is why matching is on the pair, which also makes <code>2.0d</code> and <code>02d</code> the same member.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-1" value="2" /> <span>The validator rewrites the value into the symbol <code>2d</code> before matching.</span></label>
        <p class="mc-explanation" hidden>Rewriting would make a node's identity depend on the schema, which the JSON bridge and the binary encoder both forbid: <code>parse → validate</code> and <code>parse → binary → validate</code> would disagree about the tag.</p>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">Why do <code>:dimension 2b</code> and <code>:dimension 2</code> fail differently against <code>members 1d | 2d | 3d</code>?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-2" value="0" /> <span>They do not — both are <code>not_member</code>.</span></label>
        <p class="mc-explanation" hidden>The two fail one layer apart, and the codes say so — which is the point of reporting <code>not_member</code> here rather than a blanket tag mismatch.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-2" value="1" /> <span><code>2b</code> is <code>not_member</code> (a unit-bearing number is the right shape, wrong member); <code>2</code> is <code>wrong_underlying</code> (a bare number is not a spelling at all).</span></label>
        <p class="mc-explanation" hidden>Correct. Declaring a digit-leading member is what makes the slot accept unit-bearing numbers at all; the unit is part of the identity, so <code>2b</code> gets the &quot;which ones are allowed&quot; report. A unitless number never enters that path.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-2" value="2" /> <span><code>2b</code> is <code>unit_not_allowed</code> and <code>2</code> is <code>not_member</code>.</span></label>
        <p class="mc-explanation" hidden><code>unit_not_allowed</code> belongs to <code>(unit-shape :allowed …)</code> on a number-underlying kind — a different refinement entirely.</p>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">What does <code>union_no_branch_matched</code> tell you to reread?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-3" value="0" /> <span>The plugin manifest version.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-3" value="1" /> <span>The list of alternatives the message names — the slot accepts each shape; rewrite the value to fit one of them.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-3" value="2" /> <span>The whole document from scratch.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">When two union alternatives can both accept the same value, which one wins?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-4" value="0" /> <span>The most specific alternative, decided by shape.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-4" value="1" /> <span>Whichever the plugin declared first — order is the whole rule.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-4" value="2" /> <span>Neither; an overlapping union is rejected at load.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="2">
      <p class="mc-q">When a union slot lists <code>form</code> as one alternative, does that mean any parenthesized construct is accepted?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-5" value="0" /> <span>Yes — any form satisfies the slot.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-5" value="1" /> <span>Only if the form is empty.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-5" value="2" /> <span>No — a typed form alternative usually narrows further (e.g., a head set or a discriminated form).</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">What does a head set constrain?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-6" value="0" /> <span>The spelling of a nested form head, such as <code>circle</code> or <code>rect</code>.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-6" value="1" /> <span>The keywords allowed on the parent form.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-6" value="2" /> <span>The number of vector elements.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">A head declares <code>(head :name fragment :max 1)</code> and a form carries four <code>(fragment …)</code> children. Where does the diagnostic land, and how many do you get?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-7" value="0" /> <span>One <code>positional_too_many</code>, on the second <code>(fragment …)</code> — the one that crossed the ceiling.</span></label>
        <p class="mc-explanation" hidden>Correct. The count crosses <code>:max</code> exactly once, so the report fires on that transition — and it names the real total (4), not the ceiling.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-7" value="1" /> <span>Three <code>positional_too_many</code>, one per child past the ceiling.</span></label>
        <p class="mc-explanation" hidden>That would bury every other diagnostic on the form under duplicates of one fact.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-7" value="2" /> <span>One <code>positional_too_many</code>, on the parent form.</span></label>
        <p class="mc-explanation" hidden>The parent is where a <em>floor</em> breach lands, since that one has no child to point at. A ceiling breach does.</p>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">A form declares <code>:open true</code> and a bounded <code>:positional</code> head-set. Which rules still apply?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-8" value="0" /> <span>Both counts still apply — <code>:open</code> widens the <em>keyword</em> surface only.</span></label>
        <p class="mc-explanation" hidden>Correct. Openness is about accepting unknown keywords; a form that declares <code>:positional &lt;bounded-kind&gt;</code> opted into its children's count.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-8" value="1" /> <span>Neither — <code>:open</code> turns off every end-of-form check.</span></label>
        <p class="mc-explanation" hidden>It turns off the keyword ones — required keys, the discriminant gate, exclusive groups. Positional rules like <code>not_head_member</code> already fire on open forms.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-8" value="2" /> <span>Only <code>positional_too_many</code>; the floor sweep is suppressed like other end-of-form sweeps.</span></label>
        <p class="mc-explanation" hidden>That would half-enforce one declaration: max checked, min not.</p>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">The same bounded head-set kind is used on a <code>:positional</code> slot and on a <code>(key :type …)</code> slot. Where do its <code>:min</code> / <code>:max</code> counts apply?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-9" value="0" /> <span>Only at the <code>:positional</code> slot; on the keyed slot they ride along inertly.</span></label>
        <p class="mc-explanation" hidden>Correct. A keyed slot holds one value, so <code>:max 1</code> is trivially true and <code>:min 1</code> has no set to be missing from. Inert rather than an error, so a bounded kind stays shareable.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-9" value="1" /> <span>At both — a bound is part of the kind, so it travels with it.</span></label>
        <p class="mc-explanation" hidden>A keyed slot has no repeated population to count, so there would be nothing for the bound to mean.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-9" value="2" /> <span>Nowhere; declaring a bound on a shared kind is rejected at load.</span></label>
        <p class="mc-explanation" hidden>Rejecting reuse would make a bounded head-set kind un-shareable for no gain.</p>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">A slot typed <code>dim: scalar-or-ref, base dim-value</code> (a number base). Which value takes the reference branch?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-10" value="0" /> <span>The string <code>&quot;WORKGROUP_SIZE&quot;</code>.</span></label>
        <p class="mc-explanation" hidden>A quoted string is neither a number nor a symbol, so it fires <code>union_no_branch_matched</code>.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-10" value="1" /> <span>The bare symbol <code>WORKGROUP_SIZE</code>.</span></label>
        <p class="mc-explanation" hidden>Correct. With no <code>ref</code> named, <code>scalar-or-ref</code> expands to <code>union dim-value | symbol</code>; a bare symbol takes the reference branch.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-10" value="2" /> <span>The keyword <code>:WORKGROUP_SIZE</code>.</span></label>
        <p class="mc-explanation" hidden>A keyword is not one of the branches; the reference branch is a bare symbol.</p>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">A <code>scalar-or-ref</code> slot names no <code>ref</code> kind, so the reference half is the plain <code>symbol</code> type. The document misspells a constant as <code>WORKGROUP_SIZ</code>. What happens at validate time?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-11" value="0" /> <span>It validates clean - any symbol satisfies the reference half.</span></label>
        <p class="mc-explanation" hidden>Correct. The reference half only asked for a symbol, and a misspelling is still a symbol. Nothing checked that a constant by that name exists; the mistake surfaces when the host tries to resolve it.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-11" value="1" /> <span>It fires <code>not_cross_ref</code> - the constant does not exist.</span></label>
        <p class="mc-explanation" hidden>Nothing declared the reference half as a cross-reference, so there is no target list to check against.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-11" value="2" /> <span>It fires <code>union_no_branch_matched</code> - neither branch accepts it.</span></label>
        <p class="mc-explanation" hidden>The symbol branch accepts it, so the union matched. A string would fail this way.</p>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">The plugin instead declares the slot as <code>scalar-or-ref, base bone-count, ref define-ref</code>, where <code>define-ref</code> is a cross-reference kind. The document writes <code>MAX_BONE</code> and no <code>(define :name MAX_BONE ...)</code> exists. Which diagnostic?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-12" value="0" /> <span><code>not_cross_ref</code> - the reference half is what failed.</span></label>
        <p class="mc-explanation" hidden>Reasonable, but a union does not forward one branch’s private reason. That is the general rule for unions, and the shorthand is a union underneath.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-12" value="1" /> <span><code>union_no_branch_matched</code>, naming both alternatives.</span></label>
        <p class="mc-explanation" hidden>Correct. The shorthand desugars to an ordinary union, and a union reports that no alternative matched, listing what it tried. The second alternative is where a real name was expected.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-12" value="2" /> <span><code>wrong_underlying</code> - a symbol was supplied where a number belongs.</span></label>
        <p class="mc-explanation" hidden>A symbol is a legal shape here - it is the reference branch. What failed is that it names nothing.</p>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">A <code>:shape</code> slot defines local forms <code>circle | rect</code>. The document writes <code>(canvas :shape (triangle))</code>. What happens?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-13" value="0" /> <span>It is accepted - any form works in a form slot.</span></label>
        <p class="mc-explanation" hidden>A slot-local set narrows the choices, so an arbitrary head is not accepted.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-13" value="1" /> <span>It fires <code>unknown_local_form</code> - the head is neither a local form nor a global one.</span></label>
        <p class="mc-explanation" hidden>Correct. The head matches no local form and no global form, so the slot-scoped <code>unknown_local_form</code> fires - more specific than <code>unknown_form</code>.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-13" value="2" /> <span>It fires <code>not_head_member</code> - the head is outside the list.</span></label>
        <p class="mc-explanation" hidden><code>not_head_member</code> is for a head set (a closed list of allowed head spellings); a slot that defines forms inline reports <code>unknown_local_form</code>.</p>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">A head set lists <code>ghost</code>, but no form named <code>ghost</code> is declared anywhere - not locally, not globally. The document writes <code>(ghost :x 1)</code> in that slot. How many diagnostics?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-14" value="0" /> <span>Two - <code>not_head_member</code> and <code>unknown_local_form</code>.</span></label>
        <p class="mc-explanation" hidden>Two diagnostics is what an out-of-set head produces, because both steps fail. Here the head IS in the set, so the head set is satisfied.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-14" value="1" /> <span>One - <code>unknown_local_form</code>.</span></label>
        <p class="mc-explanation" hidden>Correct. The head set admitted <code>ghost</code> (it compares spelling against its list), and the complaint came from the next step, which found no form to check the body against.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-14" value="2" /> <span>One - <code>not_head_member</code>.</span></label>
        <p class="mc-explanation" hidden>A head set never reports an undeclared name - it resolves nothing. It compared <code>ghost</code> against its list, found it, and passed.</p>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">A head set names <code>storage-texture</code>, whose only <code>(form ...)</code> declaration is a slot-local of the form you are inside. Does that work?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-15" value="0" /> <span>Yes - the head set checks spelling, and the body then resolves local-first.</span></label>
        <p class="mc-explanation" hidden>Correct. The head set names spellings, not declarations; a local form in scope at the slot is what the body is checked against.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-15" value="1" /> <span>No - head set names must be declared globally.</span></label>
        <p class="mc-explanation" hidden>A common misreading. It leads to declaring placeholder global forms that do nothing - the head set never consults a global catalog.</p>
      </li>
      <li>
        <label><input type="radio" name="q-value-kinds-refinements-15" value="2" /> <span>Only if the local form is also listed in the head set twice.</span></label>
        <p class="mc-explanation" hidden>Head set entries are a set of spellings; repeating one changes nothing.</p>
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
