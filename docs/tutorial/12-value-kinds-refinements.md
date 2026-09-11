# 12 - Value Kinds: Strings, Members, Heads, Unions, Slot-Local Forms

## Goal

Read the five remaining value-kind refinements and write values that
satisfy them, and when a value is rejected, work back from the
diagnostic code to the exact line of the contract you missed.

## Five More Ways to Narrow a Slot

[Value kinds: shapes](11-value-kinds-shapes.md) gave you the named-kind pattern
and the refinements that work on shape: underlying kind, vector length,
unit rule, numeric bound, representation tag. Those all constrain what a
value *is*. The five in this lesson constrain what it is *allowed to
say*:

```
string bounds     how long the text may be, and what shape it must have
member sets       a closed list of legal names
head sets         a closed list of legal form heads (and how many of each)
unions            several alternatives behind one slot
slot-local forms  forms a slot declares inline, for its own use
opaque slots      a slot the schema types and then leaves alone
```

The last line is not a narrowing at all. I put it in this lesson
because it is the mirror image of slot-local forms: one says "this
slot has a vocabulary of its own", the other says "this slot's
contents are not mine to read", and you will meet both in the same
plugin.

The reading habit does not change. Underlying shape first, then
refinement, then surface value. What does change is that each axis has
its own diagnostic code, so the cheat sheet at the end of this lesson
is the fastest route from an error message back to the right line in the
plugin docs. If you only remember one thing from here, remember that the
code names the layer.

## String Bounds

[Atoms and intent](03-atoms-and-intent.md) said a string carries opaque text
and nobody validates it. That was true of the language and it is not
true of a schema. An id that must not be empty, an address that has to
look like an address, a version that has to be a version: these are
string slots where "any text" is the wrong contract, and a **string
bound** is how a plugin says so.

A string bound applies to a string-underlying kind and constrains the
value's length, pattern, or format. Each field is
optional; the validator applies them cheapest-first (length, then
format, then pattern).

Example contracts:

```text title="plugin summary"
slug:           string, length 1-64, format path
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

- `string_too_long`: codepoint count above `:max-len`.
- `string_format_mismatch`: the value fails the declared `:format`, one of email / uri / path / uuid / semver.
- `string_pattern_unsupported`: `:pattern` is declared but this build has no regex engine. It is a warning, and validation still succeeds.
- `string_pattern_mismatch`: reserved for the engine milestone. v1 builds never emit it.
- `string_bounds_invalid`: emitted by the loader for an empty range, a negative bound, an empty pattern, a wrong underlying kind, or a member literal that itself fails the declared length or format.

Length is measured in UTF-8 codepoints, so `"héllo"` (5 cp / 6 bytes)
passes `:max-len 5`. The parser guarantees well-formed UTF-8, so
the count is total. No normalisation is applied, so precomposed `"é"`
(1 cp) and decomposed `"é"` (2 cp) count differently.

`:pattern` is accept-but-warn in v1: declaring it does not yet
enforce a regex (the engine lands later), but the loader stores the
source and the validator fires `string_pattern_unsupported` at every
matched value site so authors know the constraint is informational.
The wire shape is stable, so once the engine lands the same manifest
starts enforcing the regex without a spec change.

## Member Sets

A member set is the payoff for [Atoms and intent](03-atoms-and-intent.md)'s
advice to write named choices as symbols. It is a closed list of
accepted values for a symbol-underlying or string-underlying kind, and
it is what turns "write `ortho` here" from a convention into a check.

For the shapes plugin:

```text title="plugin summary"
fill-rule: symbol, members evenodd | nonzero
```

Accepted:

```sjon
(circle :center [0 0] :radius 1 :fill evenodd)
(circle :center [0 0] :radius 1 :fill nonzero)
```

Rejected:

```sjon del={1}
(circle :center [0 0] :radius 1 :fill diagonal)
```

Likely diagnostic: `not_member`. Repair with one of the documented
symbols:

```sjon ins={1}
(circle :center [0 0] :radius 1 :fill evenodd)
```

Do not repair symbol member sets with keywords:

```sjon
(circle :center [0 0] :radius 1 :fill :evenodd)
```

That runs into the keyword-pairing rule from
[Forms and keyword pairing](05-forms-and-keyword-pairing.md). `:fill` no longer receives
a value; both `:fill` and `:evenodd` are read as positional flags.
Closed enum-like values are usually symbols:

```sjon
:fill evenodd
```

If a plugin documents a string-underlying member set, then use quoted
strings instead:

```text title="plugin summary"
blend-mode: string, members "normal" | "multiply"
```

```sjon
(layer :blend "multiply")
```

The contract decides whether the closed values are symbols or strings.

A member set is closed *and* written in the plugin.
[Cross-references](13-cross-references.md) covers the other way a symbol slot
gets a fixed list of legal values: read out of the document being
validated, or extracted from a string inside it.

### Enums whose names start with a digit

Some enums name their members with a digit first. WebGPU's texture
dimensions are `"1d"`, `"2d"`, `"3d"`; its view dimensions add `2d-array`,
`cube`, and `cube-array`. A plugin may declare those directly:

```text title="plugin summary"
texture-dimension: symbol, members 1d | 2d | 3d
view-dimension:    symbol, members 1d | 2d | 2d-array | cube | cube-array | 3d
```

Accepted:

```sjon
(texture :name albedo :dimension 2d :view 2d-array)
```

`2d-array` works for the reason [Numbers, units, vectors](04-numbers-units-vectors.md)
gives: inside a unit, a hyphen joins two letter runs when a letter
follows it, so the unit here is `d-array` and the whole thing is one
value. Without that rule this was `2d` plus a stray symbol `-array`: one
intended value, two diagnostics.

Your editor treats these members like any other: completion offers
them in the slot, hover on `2d` names the kind it belongs to, and a
near miss such as `2dd` gets a quick fix to `2d`.

You write the spelling the spec uses. There is no quoting and no numeric
lookup table to memorise, which is what schemas used to force, with
`:view-dimension 3 ; cube` and a comment carrying the meaning.

Why this needs its own heading: `2d` is not a symbol.
[Numbers, units, vectors](04-numbers-units-vectors.md) showed that a digit-leading
token lexes as a **number with a unit**: value `2`, unit `d`. So the
schema matches on that pair rather than on the text, and three
consequences follow:

```sjon
(texture :dimension 2.0d)   ; ✓ same magnitude, same unit
(texture :dimension 02d)    ; ✓ the leading zero is not part of the name
(texture :dimension 2.5d)   ; ✗ fractional, so it matches no member
(texture :dimension 2b)     ; ✗ the unit is part of the name
(texture :dimension 2)      ; ✗ no unit, so not a spelling at all
```

The last two fail differently, and the difference is informative.
`2b` is `not_member`, because a unit-bearing number *is* the right shape
here and it is simply not one of the three. `2` is `wrong_underlying`,
because a bare number is not a name in the first place.

Repair drill:

```sjon del={1}
(texture :name albedo :dimension 4d)
```

`not_member`, and the diagnostic names the set:

```
got `4d` (allowed: `1d`, `2d`, `3d`)
```

so pick one of the three:

```sjon ins={1}
(texture :name albedo :dimension 3d)
```

## Head Sets

A member set closes the list of legal *names*. A **head set** closes the
list of legal *forms*: the slot value must be a nested form, and that
form's head must be one of the listed ones.
[Forms and keyword pairing](05-forms-and-keyword-pairing.md)'s repair for
`(badge :label "ok" :shape :circle)` was to write a form in the slot,
and this is the schema half of that story, the part that says which
forms.

For the shapes plugin:

```text title="plugin summary"
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

```sjon del={1}
(badge :label "bad" :shape (group :name "not-a-shape"))
```

`group` is a known form, but it is not a member of the allowed head set.
Likely diagnostic: `not_head_member`. Repair with one of the allowed
heads:

```sjon ins={1}
(badge :label "ok" :shape (rect :origin [0 0] :size [10 10]))
```

A head set is different from a symbol member set:

- `:fill evenodd` stores a symbol value and checks it against
  `evenodd | nonzero`.
- `:shape (circle ...)` stores a form value and checks the form head
  against `circle | rect`.

## How Many?

On a form's `:positional` slot, where the head set governs a *list* of
children rather than one value, it can bound the count as well as the
vocabulary. Spell the heads out as `(head …)` children and each one may
carry `:min` / `:max`:

```sjon
(value-kind :name pipeline-section :underlying form
  :heads (head-set
    (head :name vertex   :min 1 :max 1)   ; exactly one
    (head :name fragment :max 1)          ; at most one, none is fine
    (head :name constant)))               ; any number

(form :name render-pipeline :positional pipeline-section
  (key :name name :type symbol))
```

Read the three spellings carefully, because the floor defaults to 0:

- `:min 1 :max 1`: exactly one.
- `:max 1` alone: at most one. Zero is fine.
- no bound: any number, including zero.

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

`positional_too_many`, reported **on the second `(fragment …)`**, which
is the line to delete. Not on the parent, and not once per extra child: a form
four `(fragment …)` children over its ceiling still gets one diagnostic,
naming the real count.

Too few:

```sjon
(render-pipeline :name main
  (fragment :entry fs_main))
```

`positional_missing`, reported **on `(render-pipeline …)` itself**. You
cannot know a head is absent until the children run out, so there is no
child to point at, which is the same reason a missing required key lands on the
form's head rather than anywhere in particular.

Three things that will save you a debugging session:

- `:names [a b c]` cannot carry a count. The two spellings are exclusive,
  so adding a bound to one head means writing them all as `(head …)`.
- **`:open true` does not turn the counts off.** Openness widens which
  *keywords* a form accepts. A positional count is a different surface,
  and declaring `:positional <bounded-kind>` opts into it.
- **The counts only bite on `:positional`.** Reuse the same kind on a
  `(key :type pipeline-section)` slot and the bounds ride along inertly:
  a keyed slot holds one value, so `:max 1` is trivially true and `:min 1`
  has no set to be missing from. That is deliberate, and it keeps a
  bounded kind shareable between a slot that has a population and one
  that does not.

## How Many Altogether?

Every bound above counts *one* head. Some rules count the set.

A WebGPU bind-group-layout entry binds exactly one resource: a buffer, a
sampler, or a texture. Try to say that with per-head bounds and watch it
fail. Give each head `:max 1` and an entry with a buffer *and* a sampler
is accepted, because each head is within its ceiling. Give one head `:min 1` and
you have demanded a buffer specifically, which is a different rule.

The claim is about the set, so it is spelled on the set:

```sjon
(value-kind :name bgl-resource :underlying form
  :heads (head-set :min-children 1 :max-children 1   ; exactly one, whichever
    (head :name buffer  :max 1)                      ; …and not two of the same
    (head :name sampler :max 1)
    (head :name texture :max 1)))

(form :name entry :positional bgl-resource
  (key :name binding :type number))
```

`:min-children` and `:max-children` count children of *any* head in the
set. Read the four cases:

```sjon
(entry :binding 0 (buffer :type uniform))
```

Accepted: one resource.

```sjon
(entry :binding 1
  (buffer  :type uniform)
  (sampler :type filtering))
```

`positional_too_many`, on the `(sampler …)`. Both per-head ceilings are
satisfied; only `:max-children 1` refuses this.

```sjon
(entry :binding 2)
```

`positional_missing`, on `(entry …)`. Every per-head bound here is a
ceiling, so an empty child list satisfies all of them.

```sjon
(entry :binding 3
  (buffer :type uniform)
  (buffer :type storage))
```

`positional_too_many` again, but read the message. It says **`at most 1
buffer positional child`**, not `at most 1 positional child from [buffer
| sampler | texture]`. This document breaks both rules at once, and you
get one diagnostic: the per-head one, because it points at the line to
delete. The set's complaint follows from it.

That is the habit to build: **the message tells you which level fired.**
A bracketed set means the children are individually fine and there are
simply too many of them together, so the repair is to pick one, not to
de-duplicate.

Two more things:

- **The compact spelling works here.** `(head-set :names [cube sphere]
  :max-children 1)`, meaning "at most one generator", is legal, because the
  aggregate needs no per-head metadata. Only *per-head* counts force the
  `(head …)` spelling.
- **The loader refuses an impossible set.** Two heads at `:min 1` under
  `:max-children 1` is `invalid_manifest`: satisfying both needs two
  children and the set allows one. Note that neither head *alone* looks
  wrong on its own; the check has to add them up.

## Unions

Every refinement so far narrows a slot to one shape. Sometimes a slot
genuinely takes two: a note is a pitch *or* an event, a dimension is a
literal *or* the name of a constant. A **union** says "this value may
satisfy any one of these alternatives", where each alternative is
another named kind or a primitive shortcut such as `number`, `symbol`,
or `form`.

The validator tries alternatives in the order the plugin declared them.
As an author, the main thing to notice is the failure case, and it has
two answers. If the value's *shape* (number, string, symbol, vector,
form) could only ever have matched one alternative, the diagnostic is
that alternative's own, exactly as if the slot had been declared with
it alone. If the shape reaches several alternatives, or none, the
diagnostic lists the alternatives as a menu of legal shapes.

An editor runs the same shape test the other way round. A union-typed
slot completes to every alternative's values, and once what you have
typed has a shape only one alternative accepts (a bare symbol against
`pitch | event`, say) the list narrows to that arm.

Example music contract:

```text title="plugin summary"
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

`X4` is a symbol, and only one of the two alternatives takes symbols, so
`X4` could only ever have meant `pitch`. Likely diagnostic:
`not_member`, listing the pitches. Repair with a value that fits one
branch:

```sjon
(phrase :notes [E4 G4 (n G4 0.5b)])
```

Try `(chord G4)` in the same slot, where `chord` is a form the plugin
declares and the head set leaves out, and the mirror happens: a form
could only have meant `event`, so you get `not_head_member` listing `n`
and `rest`. An *undeclared* head is a different story, and the next
section tells it. Neither message mentions the union, because the union
added nothing to the question. Write a number there instead, `[E4 42]`,
and you get `union_no_branch_matched` with both alternatives named,
because a number is neither a pitch nor an event and there is nothing
more specific to say.

### Order Is Part Of The Contract

Alternatives are tried in declaration order and the first one that
accepts wins. No alternative is "more specific" than another, and none
is preferred by shape. Order is the whole rule.

Most of the time this is invisible, because alternatives do not overlap:
a symbol cannot satisfy `vec4`, a vector cannot satisfy `pitch`. But
when two alternatives *can* both accept the same value, order decides
which one, and that is usually deliberate:

```text title="plugin summary"
byte-count: number
size: union byte-count | symbol
```

`1024` matches `byte-count`. A bare name matches the `symbol` half. Had
the plugin listed `symbol` first, it would still only claim symbols, so
nothing changes here. A union of two *symbol* kinds is a different
story, and [Cross-references](13-cross-references.md#two-targets-one-name)
shows the case where order quietly decides which entity a name refers
to.

The practical rule for reading a schema: when two alternatives overlap,
the earlier one is what you get. When you cannot tell which one accepted
your value, ask the tooling: go-to-definition on the value lands in
whichever declaration actually claimed it.

### Form Alternative Pitfall

A union alternative named `form` is not a wildcard for unknown
parenthesized syntax.

Assume this contract:

```text title="plugin summary"
vec4: vector, length 4, element number
value: union number | vec4 | form
```

Assume `(set ...)` itself is a known form. This still fails if `foo`
is not declared by any loaded plugin:

```sjon del={1}
(set :value (foo 1 2))
```

Likely diagnostic: `unknown_form`, not `union_no_branch_matched`. The
slot accepts form-shaped values, but form heads still resolve against
the schema. Repair by using a form whose head the schema knows:

```sjon ins={1}
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

```text title="plugin summary"
dim-value: number
dim: scalar-or-ref, base dim-value
```

So `dim` accepts either a number or a bare symbol:

```sjon
(dispatch :x 64 :y WORKGROUP_SIZE :z 1)
```

`64` and `1` take the scalar branch; `WORKGROUP_SIZE` is a bare symbol,
so it takes the reference branch, naming a constant the host resolves
later (the same `#define`-style pattern as a cross-reference, which is
the subject of [the next lesson](13-cross-references.md)).

A quoted string is neither a number nor a symbol:

```sjon
(dispatch :x "64" :y WORKGROUP_SIZE)
```

Likely diagnostic: `union_no_branch_matched`. The shorthand is a union
underneath, and a string is a shape *neither* half could take, so there
is no half to blame and the message names both. Repair by dropping the
quotes for a reference, or writing a number for a literal:

```sjon
(dispatch :x 64 :y WORKGROUP_SIZE)
```

#### Is the reference half checked?

Read the plugin line carefully, because two `scalar-or-ref` kinds that
look alike behave very differently on a typo. The reference half is
whatever the plugin named as its `ref`, and if it named nothing, the
answer is the plain `symbol` type, which accepts *any* spelling.

```text title="plugin summary"
dim:     scalar-or-ref, base dim-value                   ; ref defaults to symbol
bones:   scalar-or-ref, base bone-count, ref define-ref  ; ref is a cross-ref kind
```

Now misspell a constant in each:

```sjon
(dispatch :y WORKGROUP_SIZ)     ; A: validates clean
(mesh :bones MAX_BONE)          ; B: not_cross_ref
```

Line A passes. `WORKGROUP_SIZ` is a perfectly good symbol, and the
reference half only asked for a symbol, and nothing checked that a constant
by that name exists. The mistake surfaces later, at whatever point the
host tries to resolve it.

Line B fails at validate time, because `define-ref` is a cross-reference
kind and the document contains no matching `(define …)`.

Note the diagnostic on line B: `not_cross_ref`, not
`union_no_branch_matched`. This is the union rule from earlier in the
lesson, and the shorthand is just a union that always meets its
condition: the two halves are disjoint by shape, so a symbol can only
have meant the reference half and a number only the literal half. A
symbol gets `not_cross_ref` naming the form it had to be declared by; a
number outside the base's bounds gets `number_above_max` (or
`number_below_min`, `unit_forbidden`, `repr_out_of_range` …) naming the
bound. Only a shape neither half takes (the quoted string above, or a
vector) gets the union's own `union_no_branch_matched` with its list of
alternatives.

Nothing here is special to the shorthand. Write the same two kinds out
as a `(union-shape …)` by hand and you get the same two messages.

## Slot-Local Forms

A head set picks from forms that already exist somewhere. Sometimes the
form you want exists nowhere else and should not: a `(dot)` that only
means anything inside one slot does not belong in the global vocabulary,
where it would pollute completion lists and collide with other plugins.

So a slot may declare its own forms inline, right where it is declared. Those local forms are
part of the slot's contract, not the global vocabulary.

```text title="plugin summary"
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
local one shadows it inside this slot, so a global `circle` that took
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
narrowed the choices. Repair with a head the slot accepts, either a
local form or a known global one:

```sjon
(canvas :shape (circle :r 12))
```

Two boundaries are worth remembering. A local form is invisible outside
its slot: writing `(rect :w 1)` at the top level is an ordinary
`unknown_form`, because `rect` exists only inside `canvas`'s `:shape`. And
a namespace-qualified head skips local resolution entirely; it goes
straight to the global vocabulary.

Your editor follows the same three rules, and it matters because a
confident wrong answer is worse than none. Inside `canvas`'s `:shape`
slot, head completion offers `circle`, `rect` and `group` ahead of the
global vocabulary and inserts the local `circle`'s `:r`; hover on that
`circle` describes `:r` and not the global's `:radius`; and the quick
fix for a misspelled `:rr` says `:r`. When a slot is closed by a head
set, completion offers the set's members and nothing else, whether or
not a global declaration stands behind each one.

## Head Sets and Slot-Local Forms

These two features look like they compete. They do not: they run in
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
(entry :binding 0 (sampler :type filtering))     ; A: head not in the set
(entry :binding 0 (ghost :x 1))                  ; B: head in the set, no form
```

Line A produces **two** diagnostics: `not_head_member` from step one,
and `unknown_local_form` from step two. Both steps failed, so both
report.

Line B produces **one**: just `unknown_local_form`. This is the case
worth remembering, because the head set *admitted* `ghost`: `ghost` is
on its list, and the complaint came entirely from step two having
nothing to descend into. A head set will never tell you a name is
undeclared; that is not its job.

## Opaque Slots

Everything so far in this lesson narrows a slot. This last piece does
the opposite, and it is easy to mistake for a slot-local form's twin
when it behaves like its inverse.

Take the camera one more time. A camera plugin that lets you save a
preset wants something like this:

```sjon
(preset :name wide-shot
  :body (camera :zoom 2 :alpha (smoothstep 0 1 t)))
```

The body is a camera, but an unfinished one. `:name` is missing, and
that is deliberate: a preset is applied to a camera later, and the
application supplies the name. Now the plugin author has a problem.
`camera` is a form this schema knows, so the validator will walk into
the body and report `missing_required_key` on a document that has
nothing wrong with it. The schema is being asked a question it cannot
answer yet.

The plugin author's tool for this is one flag on the key, and a
plugin's docs will show it like so:

```text title="plugin summary"
(preset ...)
  :name symbol required
  :body form required, opaque
```

An **opaque slot** is a slot the schema types and does not read. The
boundary is checked: `:body` has to be a form, so `:body 3` is
`wrong_underlying` at `[preset body]`. Below the boundary every walk
stops. Not only the validator's: the defaults overlay from
[Reading plugin schemas](09-reading-plugin-schemas.md), the
cross-reference index you will meet in the next lesson, and any
host-side lowering all stop on the same line. Four consequences fall
out, and I want you to predict the fourth before you read it:

1. **No diagnostics inside.** The unfinished camera above is clean, and
   so is a body that uses a head this plugin never declared.
2. **No defaults inside.** `sjon effective` splices `camera`'s defaults
   into a top-level camera and leaves the one inside `:body` exactly as
   you wrote it. Same head, same omitted key, one splice.
3. **No lowering inside.** A form that a host would lower at the top
   level does nothing in a body.
4. **No names inside.** A form that would declare a cross-reference
   target at the top level declares nothing in a body.

The fourth is the one that can surprise you, because it is the one way
an opaque slot *adds* a diagnostic rather than removing one, and the
text it complains about is in plain sight. It needs the next lesson's
machinery to show properly, so I will pay that debt in
[Cross-references](13-cross-references.md). What to hold onto now is
the reading: opaque means *the validator will not tell you what is in
there*, and also *the validator will not quietly use what is in there*.
A subtree the schema declined to interpret is not a place it harvests
names out of.

When should a plugin author reach for it? When a slot holds something
another interpreter will read: a template body, a parameter block
another tool expands, an expression whose head belongs to a vocabulary
this schema does not load. The meta-schema that describes plugin
manifests uses it on exactly one slot, the `(key …)` form's own
`:default`, which is what lets a default be an expression without the
expression's head being reported as an unknown form. If you find
yourself wanting it on a slot whose contents you *do* want checked, the
tool you want is a slot-local form.

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
| `positional_too_many` | A ceiling: the head's `:max`, or the set's `:max-children` if the message names a bracketed set. Reported on the child that crossed it. |
| `positional_missing` | A floor: the head's `:min`, or the set's `:min-children` if the message names a bracketed set. Reported on the parent form's head. |
| `unknown_local_form` | The slot's own local form set, plus the global vocabulary. |
| `union_no_branch_matched` | The union alternatives. This code means the value's shape reaches none of them, or reaches two or more; when it reaches exactly one you get that alternative's own code instead. |
| `string_too_short` / `string_too_long` | The `:min-len` / `:max-len` codepoint bound. |
| `string_format_mismatch` | The named format checker (email / uri / path / uuid / semver). |
| `string_pattern_unsupported` | The `:pattern` constraint is informational in this build (no regex engine). |

One thing from this lesson is missing from that table on purpose. An
opaque slot has no code of its own: it removes diagnostics from inside
the slot, and the one it can add arrives as an ordinary `not_cross_ref`
at the reference, which [Cross-references](13-cross-references.md)
walks through.

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

```text title="plugin summary"
fill-rule: symbol, members evenodd | nonzero
(circle ...)
  :fill fill-rule optional
```

```sjon del={1}
(circle :center [0 0] :radius 1 :fill diagonal)
```

Repair:

```sjon ins={1}
(circle :center [0 0] :radius 1 :fill evenodd)
```

Do not repair it with a keyword:

```sjon
(circle :center [0 0] :radius 1 :fill :evenodd)
```

That triggers the keyword-pairing problem from
[Forms and keyword pairing](05-forms-and-keyword-pairing.md).

### Digit-Leading Member Set

Contract:

```text title="plugin summary"
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

The first, second, and fourth are `not_member`, because each is a unit-bearing
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

```text title="plugin summary"
shape-form: form, heads circle | rect
(badge ...)
  :shape shape-form optional
```

```sjon del={1}
(badge :label "bad" :shape (group :name "not-a-shape"))
```

Repair with an allowed head:

```sjon ins={1}
(badge :label "ok" :shape (rect :origin [0 0] :size [10 10]))
```

### Positional Counts

Contract:

```text title="plugin summary"
pipeline-section: form, heads vertex (exactly 1) | fragment (at most 1) | constant (any)
(render-pipeline ...)
  :name symbol required
  positional pipeline-section
```

```sjon del={3-4}
(render-pipeline :name main
  (vertex :entry vs_main)
  (fragment :entry fs_main)
  (fragment :entry fs_alt))
```

Two `(fragment …)` children against `:max 1`. Likely diagnostic:
`positional_too_many`, on the *second* fragment, which is the extra one, not the
form. Repair by removing it:

```sjon ins={3}
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

`positional_missing`, because `vertex` is `:min 1` and there is none. It is
reported on `(render-pipeline …)` itself, because the fact "no vertex
anywhere in this list" belongs to the list, not to any child in it. Note
that `constant` being present helps not at all: a child counts towards a
head only if its own head matches, so nothing else can stand in for a
missing `vertex`. Repair by adding one:

```sjon ins={2}
(render-pipeline :name main
  (vertex :entry vs_main)
  (fragment :entry fs_main)
  (constant :name gamma :value 2.2))
```

### Union

Contract:

```text title="plugin summary"
pitch: symbol, members E4 | G4 | A4 | B4 | _
event: form, heads n | rest
note-or-event: union pitch | event
(phrase ...)
  :notes vector<note-or-event> optional
```

```sjon del={1}
(phrase :notes [E4 X4 (n G4 0.5b)])
```

`X4` is not in the pitch member set, and a symbol could only have meant
`pitch`, so that is the alternative blamed. Likely diagnostic:
`not_member` listing the pitches. Repair with a value that fits one of
the alternatives:

```sjon ins={1}
(phrase :notes [E4 G4 (n G4 0.5b)])
```

### Union With Form Alternative

Contract:

```text title="plugin summary"
vec4: vector, length 4, element number
value: union number | vec4 | form
(set ...)
  :value value required
```

Assume `(set ...)` itself is a known form.

```sjon del={1}
(set :value (foo 1 2))
```

If `foo` isn't a head in any loaded plugin, this fails with
`unknown_form`. The `form` alternative does not turn the slot into
"any parenthesized construct accepted." Repair by using a form whose
head the schema knows about:

```sjon ins={1}
(set :value (+ 1 2))
```

If you genuinely need a domain-specific construct here, check the
plugin's loaded form vocabulary first, or look for a separate slot the
plugin documents as `any`.

### scalar-or-ref

Contract:

```text title="plugin summary"
dim-value: number
dim: scalar-or-ref, base dim-value
(dispatch ...)
  :x dim required
```

```sjon del={1}
(dispatch :x "64")
```

Repair with a literal, or a bare symbol that names a constant:

```sjon ins={1}
(dispatch :x 64)
```

### Slot-Local Form

Contract:

```text title="plugin summary"
(canvas ...)
  :shape form, local circle | rect | group
    circle: (r number required)
```

```sjon del={1}
(canvas :shape (triangle))
```

Repair with a head the slot accepts:

```sjon ins={1}
(canvas :shape (circle :r 12))
```

### Opaque Slot

Contract:

```text title="plugin summary"
(preset ...)
  :name symbol required
  :body form required, opaque
```

Predict the diagnostics for each line before reading on:

```sjon
(preset :name dolly :body (camera :zoom))
(preset :name dolly :body camera)
```

The first is clean. `(camera :zoom)` ends in a keyword with nothing
after it, so `:zoom` is a positional flag, and a camera with a stray
flag and its required keys missing would be reported at the top level.
Inside an opaque slot it draws nothing. The second is `wrong_underlying` at
`[preset body]`: the slot wants a form and got a symbol. The boundary
is checked; the contents are not.

## Mastery Check

- What does a member set usually mean for authoring?
- `2d` is a legal member of a *symbol* member set, yet `2d` is not a
  symbol. How does that work?
- Why do `:dimension 2b` and `:dimension 2` fail with different
  diagnostics against `members 1d | 2d | 3d`?
- Why is a head set different from a symbol member set?
- A head set can bound how many children carry each head. Why does
  `positional_too_many` land on a child while `positional_missing` lands
  on the parent form?
- The same bounded head-set kind sits on a `:positional` slot and on a
  `(key …)` slot. Where do its counts apply, and why is the other one
  inert rather than an error?
- Why can no arrangement of per-head `:min` / `:max` express "exactly one
  of buffer / sampler / texture"?
- Two `(buffer …)` children under a set that is `:min-children 1
  :max-children 1` over heads each `:max 1` breaks both rules. How many
  diagnostics do you get, which one, and why that one?
- A `positional_too_many` message names `[buffer | sampler | texture]`
  rather than a single head. What does that tell you about the document,
  and how does the repair differ?
- What does `union_no_branch_matched` tell you about the value's shape,
  and why does a union slot often report something else entirely?
- When two union alternatives can both accept the same value, which one
  wins, and what would change that?
- When a union slot lists `form` as one of its alternatives, does
  that mean any parenthesized construct is accepted?
- What does the `scalar-or-ref` shorthand expand to, and which
  diagnostic fires when a value fits no branch?
- How does a slot-local form set change head resolution, and what
  distinguishes `unknown_local_form` from `unknown_form`?

- A required key is missing on a form that sits inside an opaque slot.
  What is reported, and why?

Next: [Cross-References](13-cross-references.md).
