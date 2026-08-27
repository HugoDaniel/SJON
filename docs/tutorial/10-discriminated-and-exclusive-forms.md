# 10 - Discriminated and Exclusive Forms

## Goal

Read a schema for a form that wears several shapes under one head, or
that allows only one of a set of keys, and predict which key is legal
where before the validator tells you.

## One Head, Several Shapes

Our camera has been an orthographic camera since
[Orientation](01-orientation.md), because `:ortho` was sitting in it as a
flag. A real camera plugin has to handle the perspective case too, and
there are three ways it could:

```
three heads              (ortho-camera :zoom 2)
                         (perspective-camera :fov 60deg)

one open head            (camera :zoom 2 :fov 60deg)     nothing checked

one discriminated head   (camera :projection ortho :zoom 2)
                         (camera :projection perspective :fov 60deg)
```

The first makes you remember three names for one concept, and makes
every consumer switch on the head. The second gives up: `:fov` on an
orthographic camera is meaningless and nothing says so. The third is
what this lesson is about. One head, one key whose *value* decides
which other keys exist, and a validator that will tell you when you have
written `:fov` on a camera that has no field of view.

There are three patterns like this, and they are easy to mix up, so here
is the distinction first. It is the thing that tells you which part of a
plugin's docs to reread:

| Pattern | Constrains | Reads as |
| --- | --- | --- |
| Discriminated form | which keys *exist*, given another key's **value** | "`:step` only when `:kind` is `kick`" |
| Exclusive group | **how many** of a set may appear | "at most one of `:color`, `:gradient`" |
| Key dependency | one key's presence demanding another's | "if `:offset`, then also `:buffer`" |

Value, count, and implication. Every constraint you meet is one of the
three, and I will come back to the question of how to tell them apart
from prose once all three are on the table.

## Discriminated Forms

The gating key is called the **discriminant**, and each set of keys it
gates is a **variant**. A plugin's summary tells you both:

```text title="plugin summary"
(track ...)
  discriminant: kind
  :name symbol required
  :kind track-kind required        ; member set [kick groove animation]
  :from number optional
  variant when kick
    :step number required
    :volume number optional
  variant when groove
    :pattern symbol required
    :swing number optional
  variant when animation
    :mesh symbol optional
    :parent symbol optional
```

The keys before the first `variant` line are **common keys**, always
allowed. Each variant block lists keys that exist *only* while the
discriminant holds that value:

```
                     :kind kick        :kind groove      :kind animation
common   :name          allowed           allowed           allowed
         :kind          allowed           allowed           allowed
         :from          allowed           allowed           allowed
variant  :step          allowed        unknown_key       unknown_key
         :volume        allowed        unknown_key       unknown_key
         :pattern    unknown_key          allowed        unknown_key
         :swing      unknown_key          allowed        unknown_key
         :mesh       unknown_key       unknown_key          allowed
         :parent     unknown_key       unknown_key          allowed
```

So `(track :kind kick :step 4)` is fine and
`(track :kind kick :mesh logo)` is not, because there is no `:mesh`
column under `kick`.

Two author rules fall out of the validator being a streaming one, which
is to say it reads your form left to right and decides as it goes.

**Write the discriminant first.** The validator cannot know which column
of that table it is in until it has seen `:kind`, so a variant-only key
encountered before the discriminant is reported as `unknown_key`, with a
hint saying `:kind` must be set before variant-only keys. The key may be
perfectly valid for the variant you intended. The validator simply had
not been told yet.

**The discriminant value must be in the closed member set.** Here that
is `kick | groove | animation`, and any other symbol gets `not_member`
on the discriminant slot itself rather than a pile of confusing key
errors.

Both of these validate cleanly:

```sjon
(track :kind kick :name k1 :step 4 :volume 0.7)
(track :kind animation :name a1 :mesh logo :parent root)
```

And here are the three ways it goes wrong. Ordering:

```sjon del={1}
(track :name k1 :step 4 :kind kick)
```

`:step` arrives before `:kind`, so it is `unknown_key` with the
discriminant-first hint. Put the discriminant first:

```sjon ins={1}
(track :kind kick :name k1 :step 4)
```

Cross-variant misuse:

```sjon del={1}
(track :kind kick :name k1 :mesh logo)
```

`:mesh` is an `animation` key, so `unknown_key` again. Repair by
changing whichever half you got wrong, the discriminant or the key:

```sjon ins={1}
(track :kind animation :name k1 :mesh logo)
```

Discriminant missing entirely:

```sjon del={1}
(track :name k1 :from 0)
```

This is `missing_discriminant_key`, and notice what does *not* happen:
the validator skips the variant required-key sweep rather than piling
`missing_required_key :step` on top. One root cause, one diagnostic.

```sjon ins={1}
(track :kind kick :name k1 :step 4 :from 0)
```

### One Variant, Several Values

A variant's `when` can list several discriminant values, and the variant
is selected when the value is any of them. The summary shows the set in
brackets:

```text title="plugin summary"
(primitive ...)
  discriminant: topology
  :topology topology optional (default triangle-list)
      ; member set [point-list line-list line-strip triangle-list triangle-strip]
  variant when [triangle-strip line-strip]
    :strip-index-format index-format optional
```

Read it as: `:strip-index-format` exists under either strip topology and
under no list topology, which is WebGPU's own rule, declared once
instead of twice. So both of these are fine:

```sjon
(primitive :topology triangle-strip :strip-index-format uint16)
(primitive :topology line-strip :strip-index-format uint16)
```

and this is `unknown_key` on `:strip-index-format`, because
`triangle-list` selects no variant at all:

```sjon
(primitive :topology triangle-list :strip-index-format uint16)
```

Two things follow. A value selects **at most one** variant, so a plugin
can never list the same value under two variants; if you see
`variant when [a b]` and `variant when [b c]` in a summary, that plugin
would have failed to load. And when a diagnostic names the active
variant it quotes the plugin's own spelling, so you will read both
``(variant `:when line-list`)`` and
``(variant `:when [triangle-strip line-strip]`)``. The bracketed one is
a multi-value variant, not a different construct.

## Exclusive Groups

The second pattern counts. A form accepts several keys but allows only
one of them at a time, and the plugin says so directly with an
**exclusive group**: a named set of alternatives tagged with one of two
cardinalities.

- **`exactly-one`**: one alternative must be present. Both zero and two
  are errors.
- **`at-most-one`**: zero or one. Omission is fine, two is not.

```text title="plugin summary"
(phrase ...)
  :name symbol required
  :notes vector optional
  :events vector optional
  exclusive-group cardinality exactly-one
    alt :notes
    alt :events
```

`:notes` and `:events` are each individually optional, and the group
says that taken together exactly one must be there. The plugin is
saying "a phrase is either a note list or an event list, never both and
never neither", which is a sentence that no per-key required flag can
express.

```sjon
(phrase :name p0 :notes [E4 G4 A4 G4])
(phrase :name p1 :events [(n E4 0.5b) (rest 0.25b)])
```

Both clean. Now the two failures, which have separate codes because
they are separate mistakes:

```sjon del={1}
(phrase :name p2 :notes [E4 G4] :events [(n A4 0.5b)])
```

`mutually_exclusive_keys_present`, and the message lists the
alternatives as `:notes | :events`. Drop one:

```sjon ins={1}
(phrase :name p2 :notes [E4 G4])
```

```sjon del={1}
(phrase :name p3)
```

`required_one_of_missing`, because the cardinality is `exactly-one`. Add
one:

```sjon ins={1}
(phrase :name p3 :notes [E4])
```

Two author rules again.

**The group owns presence, not the keys' `optional` flags.** A key
inside an `exactly-one` group never produces its own
`missing_required_key`, because `required_one_of_missing` already covers
that root cause. You get one diagnostic per problem, not two per key.

**Open forms bypass the group sweep entirely.** If the plugin marks the
form `open: true`, exclusive groups do not fire, neither for "both
present" nor for "neither present". That follows from the table in
[Reading plugin schemas](09-reading-plugin-schemas.md#what-open-actually-relaxes):
open forms are bags, and group cardinality is a closed-shape rule. A
plugin that needs both extension metadata and an exclusive group should
keep the governed form closed and put free-form metadata in a separate
open child form.

A form may declare more than one group, and a variant inside a
discriminated form may declare its own. The same key cannot appear in
two groups on the same scope, which is a manifest-load error for the
plugin author rather than anything you will see. Per group, the rules
above apply unchanged.

### Multi-Key Bundles

An alternative may name more than one key, and such a bundle counts as
present only when *every* key in it is present:

```text title="plugin summary"
(route ...)
  :name symbol required
  :from symbol optional
  :to   symbol optional
  :at   symbol optional
  exclusive-group cardinality exactly-one
    alt :keys [from to]    ; bundle: both must be present together
    alt :keys [at]         ; bundle: just `at`
```

```
(route :from a :to b)          [from to] present, [at] absent    -> clean
(route :at c)                  [from to] absent,  [at] present   -> clean
(route :from a)                [from to] PARTIAL                 -> exclusive_bundle_partial
(route :from a :to b :at c)    both present                      -> mutually_exclusive_keys_present
```

The partial case gets its own code because it is its own mistake: you
started an alternative and did not finish it, which is different from
having chosen two. Either way the message lists each bundle with its
keys joined by `+`, as `:from+:to | :at`, so the rule you tripped over
is readable straight off the diagnostic.

One caveat if you export the schema. Multi-key bundles round-trip
through `sjon export-schema` as `{required: [<bundle-keys>]}` entries
inside `oneOf`, and JSON Schema's `required` is all-or-nothing per the
standard, so a partial bundle fails there as a plain `oneOf` mismatch.
The specific "partial bundle" message exists only in the SJON validator
and the IR's warning list.

## Key Dependencies

The third pattern is the smallest one. A key can declare that its
presence demands other keys:

```text title="plugin summary"
(entry ...)
  :binding number required
  :buffer  buffer-ref optional
  :offset  byte-count optional, requires :buffer
  :size    byte-count optional, requires :buffer
```

The reason is almost always that the dependent key is *measured from*
the one it needs. A byte offset into no buffer describes nothing.

```sjon
(entry :binding 0 :buffer uniforms :offset 256)   ; satisfied
(entry :binding 0)                                ; neither written
(entry :binding 0 :buffer uniforms)               ; the requirement alone
```

All three are clean, and the third is the one worth pausing on, because
the rule runs **one way only**. `:offset` drags `:buffer` in; `:buffer`
never drags anything. Writing only the key that others depend on is
always fine.

The failure:

```sjon
(entry :binding 0 :offset 256)
```

`dependent_key_missing`, naming `:buffer`.

Two counting rules, and they point in opposite directions, which is
deliberate. Two dependent keys with the same missing requirement give
you **two** diagnostics, one per unsatisfied key:

```sjon
(entry :binding 0 :offset 256 :size 64)   ; two diagnostics
```

One key missing several of its requirements gives you **one**
diagnostic naming them all. The principle underneath both is that a
diagnostic is per *problem*, and a key with three unmet dependencies has
one problem.

## Which of the Three Is It?

This is the whole reason the three patterns share a lesson. Given a
constraint written in prose, you can pick the mechanism off the wording
alone:

- The rule names a specific **value** ("only when the mode is
  `stream`"): a **variant** on a discriminated form.
- The rule **counts** ("exactly one of", "at most one of"): an
  **exclusive group**.
- The rule says "then also": a **key dependency**.

They compose. A key can sit inside an exclusive group and carry a
dependency at the same time. The one combination a plugin cannot
declare is a key requiring another key in its own exclusive group, since
the group forbids precisely what the dependency demands; that plugin is
rejected at load rather than producing a form nobody can write
correctly.

## Exercises

Discriminated-form drill, using the `(track ...)` summary:

```sjon del={1}
(track :kind groove :name g1 :step 4)
```

`:step` is a `kick` key. Repair into a groove shape:

```sjon ins={1}
(track :kind groove :name g1 :pattern straight :swing 0.1)
```

Discriminant ordering drill:

```sjon del={1}
(track :name a1 :mesh logo :kind animation)
```

```sjon ins={1}
(track :kind animation :name a1 :mesh logo)
```

Exclusive-group drill, using the `(phrase ...)` summary:

```sjon del={1}
(phrase :name p4 :notes [E4 G4] :events [(n A4 0.5b)])
```

```sjon ins={1}
(phrase :name p4 :notes [E4 G4])
```

Empty-of-required drill:

```sjon
(phrase :name p5)
```

```sjon
(phrase :name p5 :events [(n A4 0.5b)])
```

Key-dependency drill, using the `(entry ...)` summary:

```sjon del={1}
(entry :binding 0 :offset 256)
```

`:offset` requires `:buffer`, which is absent. There are two repairs and
which one is right depends on what you meant. Supply the requirement:

```sjon ins={1}
(entry :binding 0 :buffer uniforms :offset 256)
```

Or drop the dependent key, if the offset was a mistake:

```sjon
(entry :binding 0)
```

Pick-the-mechanism drill. Each of these is a constraint stated in prose.
Decide which of the three a plugin would use, before reading the
answers:

1. "A texture binding may declare a sampler or a comparison sampler, but
   not both."
2. "`:mip-level-count` is only meaningful on a `2d` texture."
3. "If you give `:array-layer`, you must also give `:array-layer-count`."

The first counts, so it is an **exclusive group** with `at-most-one`.
The second names a *value* of another key, so it is a **variant** on a
discriminated form. The third says "then also", so it is a **key
dependency**: `:array-layer` declares `:requires [array-layer-count]`.

## Mastery Check

- On a discriminated form, why must the discriminant key be written
  before variant-only keys?
- What's the difference between a common key and a variant key on a
  discriminated form?
- A summary shows `variant when [triangle-strip line-strip]`. Which
  topologies accept that variant's keys, and what does
  `(primitive :topology triangle-list :strip-index-format uint16)`
  report?
- For an `exactly-one` exclusive group, what's the difference between
  the diagnostic for "both present" and "neither present"?
- Why doesn't a key inside an `exactly-one` group also trigger
  `missing_required_key` when omitted?
- What does it take for an exclusive group to fire on an `open: true`
  form?
- A key declares `:requires [buffer]`. If you write neither key, is that
  an error? What if you write only `:buffer`?
- You write two keys that both require the same absent key. How many
  diagnostics, and why is that the opposite of what happens when one key
  is missing two requirements?
- Given "`:strip-index-format` applies only when `:topology` is
  `triangle-strip`", which of the three mechanisms is it, and how do you
  know from the wording alone?

Next: [Value Kinds: Shapes, Vectors, Units, Bounds, Representation](11-value-kinds-shapes.md).
