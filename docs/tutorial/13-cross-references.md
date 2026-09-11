# 13 - Cross-References

## Goal

Write symbols that refer to named forms elsewhere in the document, tell
the declaration side from the reference side, and repair the
cross-reference diagnostics without guessing.

## A Member Set the Document Writes

[Member sets](12-value-kinds-refinements.md#member-sets) are closed
lists chosen by the plugin: `fill-rule` is `evenodd | nonzero` and will
be for as long as the plugin lives. That works for vocabularies the
plugin knows in advance, and it is useless for the ones it cannot.

A track that plays phrases has to name the phrases, and the plugin
cannot know their names, because you are about to invent them. So the
legal values have to be discovered from the document being validated,
and that is what a **cross-reference** is: a symbol whose member set is
built by reading your own file.

```
member set        legal values come from the PLUGIN
                    fill-rule -> evenodd | nonzero

cross-reference   legal values come from the DOCUMENT
                    phrase-name -> every (phrase :name …) in scope
```

Which means a cross-reference always has two sides, and you write both:

```sjon
(phrase :name p0)       ; declaration: introduces the name p0
(track :sequence [p0])  ; reference: uses the name p0
```

## Two Passes, So Order Does Not Matter

Think of the validator as doing two passes:

```
pass 1   walk the document, collect every target form's name
           registry: { p0, p1 }

pass 2   check every symbol in a cross-reference slot against it
           (track :sequence [p0 p1])   both present -> clean
```

Because the registry is complete before any reference is checked, a
reference may name a form that appears later in the file:

```sjon
(track :sequence [p0])
(phrase :name p0)
```

That validates. Forward references are not a special feature that had
to be added; they fall out of building the registry first.

The surface value is still a plain symbol. You do not write `$p0`,
`ref(p0)`, `"p0"`, or `:p0`, unless a plugin's docs explicitly say some
other value kind is expected.

## Worked Example

You will not see the plugin DSL while authoring. You will see an
author-facing summary like this:

```text title="plugin summary"
(phrase ...)
  :name   symbol required       ; declares a phrase name
  :notes  vector optional

(track ...)
  :sequence vector<phrase-name> required

phrase-name: symbol, cross-reference to (phrase :name ...)
```

Read it line by line:

- `(phrase ...) :name symbol` tells you how names are declared.
- `(track ...) :sequence vector<phrase-name>` tells you where names are
  referenced.
- `phrase-name: ... cross-reference to (phrase :name ...)` connects the
  reference kind to the declaration form.

This source validates:

```sjon
(phrase :name p0 :notes [E4 G4 A4 G4])
(phrase :name p1 :notes [B4 A4 G4 E4])

(track :sequence [p0 p1])
```

Read it as a registry:

```text
declared phrase names: p0, p1
track references:      p0, p1
```

Both references resolve.

This source does not validate:

```sjon del={3}
(phrase :name p0 :notes [E4 G4 A4 G4])

(track :sequence [p0 p99])
```

Registry:

```text
declared phrase names: p0
track references:      p0, p99
```

`p99` is missing, so the likely diagnostic is `not_cross_ref`. Repair
by making the reference match a declaration:

```sjon ins={3}
(phrase :name p0 :notes [E4 G4 A4 G4])

(track :sequence [p0])
```

Or repair by adding the missing declaration:

```sjon
(phrase :name p0 :notes [E4 G4 A4 G4])
(phrase :name p99 :notes [B4 A4 G4 E4])

(track :sequence [p0 p99])
```

## Names Are Symbols

Most cross-reference declarations use a symbol-valued name key:

```sjon
(phrase :name p0)
```

These are different values:

```sjon
(phrase :name "p0")  ; string
(phrase :name :p0)   ; keyword, and also a keyword-pairing problem
```

If the plugin says `:name symbol`, write a bare symbol. A quoted string
does not declare the same name. A keyword does not become a normal value
after `:name`; the pairing rule from
[Forms and keyword pairing](05-forms-and-keyword-pairing.md) still
applies.

The same rule applies at the reference site:

```sjon
(track :sequence [p0])    ; symbol reference
(track :sequence ["p0"])  ; string, wrong shape
(track :sequence [:p0])   ; keyword element, wrong shape
```

### A Cross-Reference As Half Of A scalar-or-ref

This is how most authors first meet a cross-reference in practice. A
slot that takes "a number, or a constant naming one" is the
[`scalar-or-ref` shorthand](12-value-kinds-refinements.md#the-scalar-or-ref-shorthand),
and its reference half can be a cross-reference kind:

```sjon
(define :name MAX_BONES :value 128)

(mesh :bones 128)         ; the literal half
(mesh :bones MAX_BONES)   ; the reference half, a cross-reference
```

The value of doing it this way is what happens on a typo. Left as the
default, the reference half is a plain `symbol` and `MAX_BONE`
validates clean, naming nothing. Backed by a cross-reference kind, it
fails, reported as `not_cross_ref`, naming the form the symbol had to
be declared by. The shorthand is a union underneath, but a symbol can
only have meant its reference half, so the diagnostic is that half's
own rather than the union's list of alternatives.

## Duplicate Declarations

A name should identify one target in its scope. If two declarations use
the same name, the validator cannot choose which one the reference
means.

Broken:

```sjon del={2}
(phrase :name p0 :notes [E4 G4 A4 G4])
(phrase :name p0 :notes [B4 A4 G4 E4])

(track :sequence [p0])
```

Registry attempt:

```text
p0 -> first phrase
p0 -> second phrase  ; duplicate
```

Likely diagnostic: `duplicate_cross_ref_target`. Repair by renaming one
declaration:

```sjon ins={2}
(phrase :name p0 :notes [E4 G4 A4 G4])
(phrase :name p1 :notes [B4 A4 G4 E4])

(track :sequence [p0])
```

Then choose which one the track should reference:

```sjon
(track :sequence [p0 p1])
```

Duplicate checking happens inside the active scope. [Scope](#scope),
further down, explains what that means for references.

## Two Targets, One Name

You just learned that two declarations sharing a name is an error. Here
is the case where it is not, and why that turns out to matter.

Duplicate checking is **per target**. Each target form gets its own
namespace, so a `(render-pipeline :name same)` and a
`(compute-pipeline :name same)` are each alone in theirs. Neither is a
duplicate. Both are fine.

Now suppose a slot accepts either one, as a union of two reference kinds:

```text title="plugin summary"
render-pipeline-ref:  symbol, cross-ref to render-pipeline
compute-pipeline-ref: symbol, cross-ref to compute-pipeline
pipeline-ref:         union render-pipeline-ref | compute-pipeline-ref

(dispatch ...)
  :pipeline pipeline-ref
```

Before reading on, predict what happens here:

```sjon
(render-pipeline  :name same)
(compute-pipeline :name same)

(dispatch :pipeline same)
```

Ask yourself two questions. Does it validate? And which pipeline is
`same`?

The answers are "yes" and "the render one", but only because
`render-pipeline-ref` is listed first. That is
[Order Is Part of the Contract](12-value-kinds-refinements.md#order-is-part-of-the-contract)
doing real work: alternatives are tried in declaration order, the first
that accepts wins, and here *both* accept. Reorder the plugin's
alternatives and the same document means something different.

So it validates, with a warning:

```text
union_ambiguous (warning)
```

Read it as: *this reference has two readings, and nothing but
declaration order is choosing between them.* Your document is not
broken. What is fragile is that a tool resolving `same` through its own
lookup (an emitter, a code generator, an editor) may pick the compute
pipeline, and neither it nor the validator would ever notice they
disagreed.

Two repairs, and the right one depends on what you meant:

```sjon
; Repair A: the collision was an accident. Rename one.
(render-pipeline  :name blit)
(compute-pipeline :name reduce)

(dispatch :pipeline blit)
```

```sjon
; Repair B: both names are deliberate; the SLOT was overloaded.
; Ask the plugin author for two keys, one reference kind each.
(dispatch :render-pipeline same)
```

```sjon
; Repair C: the names were never meant to coexist. Ask the plugin author
; for ONE reference kind over BOTH forms:
;
;   pipeline-ref: symbol, cross-ref to [render-pipeline compute-pipeline]
;
; Then this document does not warn. It fails, at the declarations:

(render-pipeline  :name same)
(compute-pipeline :name same)   ; duplicate_cross_ref_target
```

Repair A is right most of the time. Reach for B when the two names are
genuinely the same concept in two pipelines and renaming would be a lie.
Repair C is the one to ask for when they are *never* meant to be the same
name, which the next heading unpicks.

### One Namespace Or Two

Repairs B and C look similar and are opposites. Both change the schema;
what they change is how many namespaces exist.

A **union of two reference kinds** is two namespaces. `same` in each is
two different names that happen to be spelled alike, so declaring both is
fine and every *reference* is the ambiguous thing.

A **target group**, meaning one cross-reference over a list of forms, is one
namespace. `same` declared twice is one name declared twice, so the
*declaration* is the wrong thing and no reference is ever ambiguous.

That is the whole distinction, and it is a question about your data, not
about SJON: are a render pipeline and a compute pipeline allowed to share
a name? If yes, the union is right and `union_ambiguous` is a fair warning
about a genuinely overloaded slot. If no, the group is right and you want
to hear about the collision once, where you made it.

You cannot pick between them as a document author, because `:target` is the
plugin's to write. What you can do is read the diagnostic and know which
one you are inside: a warning on a reference means two namespaces, an
error on a declaration means one.

### When It Stays Quiet

This warning is deliberately narrow, so do not expect it whenever a
union overlaps:

- **A union over plain values.** "A byte count or a named constant"
  overlaps by design, and first-match is the point. Nothing there names
  two entities, so nothing warns.
- **A member set that wins first.** If the alternative that accepts is
  an enum rather than a reference, the slot denotes a member, not an
  entity, so there is no "which one" to answer.
- **Two alternatives onto the same target.** Both readings pick out the
  same declaration, so order decides nothing.
- **A target group.** One namespace has nothing to be ambiguous between;
  the collision it would warn about is an error at the declarations
  instead.

The one case it fires on is the one where order silently picks between
two *different things*. Everything else is the union working as
designed.

## Scope

When a plugin declares a cross-reference, it also defines where the
validator should look for names. The authoring question is:

```text
Which declarations are visible from this reference?
```

You will usually encounter two practical cases.

### Tree Scope

Tree scope is the default authoring model: references resolve against
names declared in the same parsed tree, usually one source document or
file.

```sjon
(phrase :name p0)
(track :sequence [p0])
```

This is the easiest case. If a reference fails, first look in the same
document for a declaration with the exact same symbol spelling.

When a host validates several roots as a forest, tooling may build one
index for all of them, but ordinary cross-reference checks are still
scoped by the rules the plugin and host document. Do not assume a name
in another file is visible just because both files are open. For
split-file authoring, check the host's plugin docs.

### Lexical Scope

A plugin can make a cross-reference local to the nearest enclosing form.
The docs might say:

```text title="plugin summary"
phrase-name: cross-reference to (phrase :name ...), scope piece
```

Read that as: a `(piece ...)` form opens a local registry. References
inside a piece can only see phrase names declared inside that same
piece.

This validates:

```sjon
(piece
  (phrase :name p0)
  (phrase :name p1)
  (track :sequence [p0 p1]))

(piece
  (phrase :name p0)
  (track :sequence [p0]))
```

The two `p0` declarations do not collide because they live in different
piece scopes.

This does not validate:

```sjon
(phrase :name p0)
(track :sequence [p0])
```

If `phrase-name` is scoped to `piece`, the reference appears outside
any enclosing `(piece ...)`. Likely diagnostic:
`cross_ref_outside_scope`. Repair by moving the declaration and
reference into the same scope:

```sjon
(piece
  (phrase :name p0)
  (track :sequence [p0]))
```

Another common scoped mistake is referencing a name from a sibling
scope:

```sjon
(piece
  (phrase :name p0))

(piece
  (track :sequence [p0]))
```

The second piece has no local `p0`. Likely diagnostic:
`not_cross_ref`. Repair by declaring `p0` in the same piece or moving
the track into the piece where `p0` is declared.

## Acyclic References

Some cross-references describe parent chains or dependency chains. In
those cases, the plugin may say the reference must be acyclic.

Example contract:

```text title="plugin summary"
(phrase ...)
  :name   symbol required
  :parent phrase-name optional

phrase-name: cross-reference to (phrase :name ...), acyclic
```

This chain is fine:

```sjon
(phrase :name p0 :parent p1)
(phrase :name p1 :parent p2)
(phrase :name p2)
```

Read the edges:

```text
p0 -> p1
p1 -> p2
p2 -> nothing
```

There is no loop.

This chain is not fine:

```sjon del={2}
(phrase :name p0 :parent p1)
(phrase :name p1 :parent p0)
```

Edges:

```text
p0 -> p1
p1 -> p0
```

The names form a cycle, so the likely diagnostic is
`cyclic_cross_ref`. Repair by breaking the loop:

```sjon ins={2}
(phrase :name p0 :parent p1)
(phrase :name p1)
```

Most cross-references are not acyclic. This rule only matters when the
plugin docs explicitly say the kind or key participates in acyclic
checking.

## Names Inside A String

Everything above assumes the name is written in your document as a
symbol: `(phrase :name p0)` puts `p0` where the validator can read it.
Plenty of names are not written that way. The uniforms of a shader are
inside the shader source. The columns of a table are inside the DDL.
The capture groups of a regex are inside the regex.

A plugin can still make those names referenceable, by declaring a
**provider**: a named extractor that reads one string and reports the
names in it. The author-facing summary says so:

```text title="plugin summary"
(shader ...)
  :name symbol required
  :code string required     ; the provider reads this

(bind ...)
  :uniform uniform-ref optional

uniforms:    provider, names out of a shader source
uniform-ref: symbol, cross-reference to (shader ...),
             provider uniforms, source key code
```

Read the last two lines together: the target form is still `(shader
...)`, but the member set no longer comes from a name key on that form.
It comes from running `uniforms` over each shader's `:code` string.

This validates:

```sjon
(shader :name blur :code """
uniform float u_time;
uniform vec2 u_resolution;
""")

(bind :uniform u_time)
(bind :uniform u_resolution)
```

Registry:

```text
shader names:    (unused; this route ignores :name)
extracted names: u_time, u_resolution
bind references: u_time, u_resolution
```

Note what is *not* in that registry. `blur` is a shader name, not a
uniform name, and `:name` plays no part on this route. The legal values
are exactly what the provider found.

This does not validate:

```sjon
(shader :name blur :code """
uniform float u_time;
""")

(bind :uniform u_tim)
```

Likely diagnostic: `not_cross_ref`, the same code as any other missed
reference, because from the reference side nothing has changed. Repair
the same way, by matching a name that exists:

```sjon
(bind :uniform u_time)
```

Your side of the deal is unchanged: write a symbol, and it either is a
member or it is not. What changed is where the member set came from.

### The Provider Only Sees Your String

This is the rule worth memorising, because it is what keeps validation
predictable:

```text
A provider is handed the string in your document,
and nothing else.
```

Not the rest of your document. Not the schema. Not your filesystem, the
network, or the clock. So a provider can tell you that `u_time` is
declared inside the source you wrote; it can never tell you that a file
exists on disk or that a column exists in a live database. Those are
facts about the world, not about your document, and validating them
would mean two hosts could disagree about the same file.

The practical consequence: if a name is not in the string, no
configuration will make the reference resolve. Add it to the source.

### Two Diagnostics You Only See On This Route

```sjon
(shader :name blur :code "not a shader {{{")
(bind :uniform u_time)
```

Likely diagnostic: `cross_ref_extraction_failed`, reported **on the
`:code` string**, not on the reference. The provider ran and rejected
its input, so nobody knows what the legal uniform names were. Repair by
fixing the source string the provider could not read.

Notice where the diagnostic did *not* appear. `(bind :uniform u_time)`
is silent, on purpose. Reporting `not_cross_ref` there would mean
claiming `u_time` is absent from a member set that was never computed.
On this route the references go unchecked when the extraction fails,
neither accepted nor rejected.

The other one is not about your document at all:

```text
cross_ref_provider_unavailable
```

It means the host you are running could not execute the provider: the
browser playground, for instance, cannot run plugin code at all. Same
place (the source string), same silence at the references, but the
repair is on the host side, not in your file. In an editor it usually
arrives as a hint rather than an error, because nothing you wrote is
wrong. If you see it in a build that is supposed to check these names,
check that the plugin's executable half is actually installed.

### Go-To-Definition Lands On The Whole String

An extracted name has no span of its own. SJON never parsed that shader
source; it received a list of names. So "go to definition" on `u_time`
takes you to the `:code` string that produced it, not to the line inside
it. That is a limit of the route, not a bug in the editor.

## Names Inside An Opaque Slot

I owe you one from
[the last lesson](12-value-kinds-refinements.md#opaque-slots), where I
said an opaque slot is the one place a schema can *add* a diagnostic
by declining to look. Here it is, on the phrase and track you have
been using all lesson. The template plugin marks `:body` opaque: a
template's body is expanded by the host later, so nothing inside it is
the schema's to read.

```sjon del={3}
(template :name ending
  :body (phrase :name outro))
(track :anchor outro)
```

This is `not_cross_ref` at `[track anchor]`, and the message says no
`(phrase :name …)` form declares this name. Read that against the
source and it looks like a lie: the declaration is two lines up,
spelled exactly right. It is not a lie. It is a precise statement about
what the schema read. Every walk stops at an opaque slot, the
cross-reference index included, so the registry built for `phrase` is
empty and `outro` has nothing to resolve against.

Registry:

```text
phrase names:     (none; the only declaration is inside an opaque body)
track references: outro          <- not_cross_ref
```

The repair is a move, not a rename. Put the declaration where the
schema reads, and let the body refer to it:

```sjon ins={1}
(phrase :name outro)
(template :name ending
  :body (fade :phrase outro))
(track :anchor outro)
```

Two things to notice about the repaired version. `(fade …)` is not a
form this plugin declares, and that is fine, because it sits in the
opaque body where nothing is checked. And `:phrase outro` inside the
body is not a reference either: the body's contents are not read, so
they are neither declarations nor references. Only the top-level
`:anchor outro` is checked, and now it resolves.

This is the second place a repair loop can spin without converging.
The first was the provider route above, where the name lives inside a
string. Here the name lives inside a slot the schema does not read.
In both cases the reference is spelled right, and in both cases the
fix is somewhere other than the reference.

## Diagnostic Cheat Sheet

| Diagnostic | What it usually means | Repair |
| --- | --- | --- |
| `not_cross_ref` | The symbol is not in the visible registry. | Fix the spelling, add the declaration, move the reference into the right scope, or move a declaration out of an opaque slot. |
| `duplicate_cross_ref_target` | Two declarations use the same name in one scope. | Rename or remove one declaration. |
| `union_ambiguous` (warning) | A name exists in two of a union slot's reference targets, so declaration order is picking which one. | Rename one declaration, or ask for the slot to be split into two single-kind keys. |
| `cross_ref_outside_scope` | A scoped reference appears outside its required enclosing form. | Put the declaration and reference inside that scope form. |
| `cyclic_cross_ref` | An acyclic reference chain loops back on itself. | Remove or change one edge in the cycle. |
| `wrong_underlying` | The declaration or reference is not the expected value shape, often string vs symbol. | Match the plugin's declared type. |
| `cross_ref_extraction_failed` | A provider ran over a source string and rejected it, so that source contributed no names. | Fix the string the diagnostic points at; the references into it stay unchecked until it parses. |
| `cross_ref_provider_unavailable` | The host could not run the provider at all. | Nothing in the document is wrong. Check the host, or accept that these names go unchecked here. |

You may also see schema setup diagnostics such as
`unknown_cross_ref_target`, `ambiguous_cross_ref_target`,
`cross_ref_name_key_unknown`, `unknown_cross_ref_scope`, or
`ambiguous_cross_ref_scope`. Those usually mean the plugin or manifest
is misconfigured, not that an ordinary document reference is misspelled.

## Repair Workflow

When a cross-reference fails, do this mechanically:

1. Find the reference slot in the diagnostic path.
2. Read the slot's value kind in the plugin docs.
3. Find the target form and name key, such as `(phrase :name ...)`.
4. List the declarations visible from the reference's scope.
5. Check exact symbol spelling and case.
6. If the name exists twice, rename one declaration.
7. If the slot is a union of reference kinds, check every target for the
   name, not just the one you had in mind.
8. If the kind is acyclic, draw the arrows and remove the loop.
9. If the kind names a provider, the list in step 4 is what the
   provider extracted from the source string, so read the source
   instead of looking for declarations.
10. If the declaration sits inside an opaque slot, it is not a
    declaration. Move it out to where the schema reads.

## Exercises

Predict the diagnostic, then repair.

### Unknown Reference

Assume only `p0` and `p1` are declared:

```sjon del={4}
(phrase :name p0 :notes [E4 G4 A4 G4])
(phrase :name p1 :notes [B4 A4 G4 E4])

(track :sequence [p0 p99])
```

Likely diagnostic: `not_cross_ref`. Repair by spelling the reference
correctly:

```sjon ins={4}
(phrase :name p0 :notes [E4 G4 A4 G4])
(phrase :name p1 :notes [B4 A4 G4 E4])

(track :sequence [p0 p1])
```

Or by adding the missing target:

```sjon
(phrase :name p0 :notes [E4 G4 A4 G4])
(phrase :name p1 :notes [B4 A4 G4 E4])
(phrase :name p99 :notes [C5 B4 A4 G4])

(track :sequence [p0 p99])
```

### Forward Reference

```sjon
(track :sequence [p0])
(phrase :name p0)
```

This should validate. The reference appears first, but the registry is
built from the whole document before references are checked.

### String Instead Of Symbol

Assume `:name` expects `symbol`:

```sjon
(phrase :name "p0")
(track :sequence [p0])
```

Likely diagnostics: the declaration has the wrong underlying shape, and
the reference may also fail because no symbol name `p0` was registered.
Repair the declaration:

```sjon
(phrase :name p0)
(track :sequence [p0])
```

### Duplicate Target

```sjon del={2}
(phrase :name p0 :notes [E4 G4 A4 G4])
(phrase :name p0 :notes [B4 A4 G4 E4])

(track :sequence [p0])
```

Likely diagnostic: `duplicate_cross_ref_target`. Repair by renaming one
declaration:

```sjon ins={2}
(phrase :name p0 :notes [E4 G4 A4 G4])
(phrase :name p1 :notes [B4 A4 G4 E4])

(track :sequence [p0])
```

### Same Name, Two Targets

Slot `:pipeline` is typed `pipeline-ref`, a union of
`render-pipeline-ref | compute-pipeline-ref` in that order.

```sjon
(render-pipeline  :name same)
(compute-pipeline :name same)

(dispatch :pipeline same)
```

Two questions before you answer: does this validate, and which pipeline
does `same` mean?

It validates. `same` is the *render* pipeline, because that alternative
is listed first. Neither declaration is a duplicate, because duplicate checking
is per target, and these are two targets. Likely diagnostic:
`union_ambiguous`, at `warning` severity. Repair by renaming so the two
targets do not collide:

```sjon
(render-pipeline  :name blit)
(compute-pipeline :name reduce)

(dispatch :pipeline blit)
```

### Overlapping Union, No Warning

Slot `:size` is typed `byte-count | symbol`.

```sjon
(buffer :size 1024)
(buffer :size default-size)
```

Both lines match a union whose alternatives overlap on shape, so is this
the ambiguity case?

No: clean, no diagnostic. `1024` matches `byte-count` and
`default-size` matches the `symbol` half, and neither value names two
different entities. `union_ambiguous` is about two *references* to two
different things colliding on one name, not about a union having
alternatives that could both accept.

### Outside Lexical Scope

Assume `phrase-name` is scoped to `piece`:

```sjon
(phrase :name p0)
(track :sequence [p0])
```

Likely diagnostic: `cross_ref_outside_scope`. Repair by adding the
scope form:

```sjon
(piece
  (phrase :name p0)
  (track :sequence [p0]))
```

### Sibling Lexical Scope

Assume `phrase-name` is scoped to `piece`:

```sjon
(piece
  (phrase :name p0))

(piece
  (track :sequence [p0]))
```

Likely diagnostic: `not_cross_ref`. The second piece has no visible
`p0`. Repair by moving the track or declaring the phrase in the same
piece:

```sjon
(piece
  (phrase :name p0)
  (track :sequence [p0]))
```

### Cycle

Assume the plugin opts the `:parent` key into acyclic detection:

```sjon del={2}
(phrase :name p0 :parent p1)
(phrase :name p1 :parent p0)
```

Likely diagnostic: `cyclic_cross_ref`. Repair by breaking the loop:

```sjon ins={2}
(phrase :name p0 :parent p1)
(phrase :name p1)
```

### Provider-Backed Reference

Assume `uniform-ref` reads its names from a `(shader ...)`'s `:code`
string through the `uniforms` provider:

```sjon
(shader :name blur :code """
uniform float u_time;
""")

(bind :uniform u_resolution)
```

Likely diagnostic: `not_cross_ref`. The source declares one uniform and
it is not that one. Repair by referencing a name the source contains:

```sjon
(bind :uniform u_time)
```

Or by adding it to the source, which is where this route's declarations
live:

```sjon
(shader :name blur :code """
uniform float u_time;
uniform vec2 u_resolution;
""")

(bind :uniform u_resolution)
```

### Unreadable Provider Source

```sjon
(shader :name blur :code "not a shader {{{")

(bind :uniform u_time)
```

Likely diagnostic: `cross_ref_extraction_failed`, on the `:code` string.
Predict the second diagnostic too. There isn't one: `(bind :uniform
u_time)` is not reported, because the member set was never computed.
Repair the source, and the reference becomes checkable again.

## Mastery Check

- What are the declaration side and reference side of a cross-reference?
- Why can a reference appear before the form it names?
- Why does a typo on a phrase reference produce `not_cross_ref` instead
  of `not_member`?
- Why is `"p0"` not the same declaration as `p0`?
- What does lexical scope allow two sibling `(piece ...)` forms to do?
- What is the first repair to try for `cross_ref_outside_scope`?
- When does `cyclic_cross_ref` matter?
- Where does a provider-backed kind get its legal names from?
- Why are the references silent when `cross_ref_extraction_failed`
  fires?
- Why is the same name under two different target forms *not* a
  `duplicate_cross_ref_target`?
- When a union slot's alternatives both accept a name, what decides
  which one the slot means?
- Why is `union_ambiguous` a warning rather than an error?
- Name one case where a union's alternatives overlap and nothing warns.

Next: [Diagnostics-Driven Repair](14-diagnostics-driven-repair.md).
