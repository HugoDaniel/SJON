---
type: lesson
title: 'Discriminated and Exclusive Forms'
---

## Mental Model

Chapter 9 covered the basics of a form schema: keys, required vs
optional, defaults, positional policy, and open forms. This chapter adds
two structural patterns that plugins use to keep one head's vocabulary
manageable: a single form name with several variant shapes selected by a
discriminant key, and forms that declare a bundle of keys as mutually
exclusive. Both patterns produce their own family of diagnostic codes,
and both interact with the keyword-pairing rule from chapter 5 in ways
worth knowing before you read the error messages.

## Discriminated Forms

Some forms reuse one head for several closely related shapes, gated by
the value of one key. The schema doc will tell you two things about
such a form:

- **Discriminant** - the gating key, e.g. `discriminant: kind`.
- **Variants** - one extra key set per allowed discriminant value.

An author-facing summary for a discriminated form looks like:

```text
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

Read it like this: `:name`, `:kind`, and `:from` are the **common keys**
- always allowed. The variant blocks list **extra keys** that are only
allowed when `:kind` matches the variant's `when` value. So
`(track :kind kick :step 4)` is valid; `(track :kind kick :mesh logo)`
is not - `:mesh` only exists under the `animation` variant.

Two author rules follow from the streaming validator:

1. **Set the discriminant first.** Write `:kind` before any
   variant-only key. A variant key encountered before the
   discriminant is set is reported as `unknown_key` with a hint
   ("`:kind` must be set before variant-only keys"), even if the key
   is valid for some variant.
2. **The discriminant value must be in the closed member set.** The
   schema documents which values are allowed (here:
   `kick | groove | animation`). Any other symbol gets `not_member`
   on the discriminant slot itself.

Worked example:

```sjon
(track :kind kick :name k1 :step 4 :volume 0.7)
(track :kind animation :name a1 :mesh logo :parent root)
```

Both validate cleanly. The mental model: one form name, several
shapes, picked by the discriminant.

Common breakage and repair:

```sjon
(track :name k1 :step 4 :kind kick)
```

`:step` is encountered before `:kind`. Diagnostic: `unknown_key` on
`:step` with the discriminant-first hint. Repair by ordering the
discriminant first:

```sjon
(track :kind kick :name k1 :step 4)
```

Cross-variant misuse:

```sjon
(track :kind kick :name k1 :mesh logo)
```

`:mesh` is an `animation` variant key. Diagnostic: `unknown_key` -
`:mesh` is not allowed when `:kind = kick`. Repair either by changing
the discriminant or by removing the wrong-variant key:

```sjon
(track :kind animation :name k1 :mesh logo)
```

Discriminant absent:

```sjon
(track :name k1 :from 0)
```

Diagnostic: `missing_discriminant_key`. The validator skips the
variant required-key sweep in this case - it does not pile on
`missing_required_key :step` etc. Repair by adding `:kind`:

```sjon
(track :kind kick :name k1 :step 4 :from 0)
```

## Exclusive Groups (Exactly-One-Of)

Some forms accept several keys but only allow one of them at a time.
A plugin can declare this directly with an **exclusive group** —
the schema doc names the group, lists its alternatives, and tags it
with one of two cardinalities:

- **`exactly-one`** — exactly one alternative must be present.
  Omitting all and supplying more than one are both errors.
- **`at-most-one`** — zero or one. Omission is fine; supplying two
  or more is an error.

An author-facing summary looks like:

```text
(phrase ...)
  :name symbol required
  :notes vector optional
  :events vector optional
  exclusive-group cardinality exactly-one
    alt :notes
    alt :events
```

Read it like this: `:notes` and `:events` are individually optional
(either column may be absent on its own), but the group rule says
that, taken together, exactly one must be present. The plugin is
saying "a phrase is *either* a note list *or* an event list — never
both, never neither."

Worked example:

```sjon
(phrase :name p0 :notes [E4 G4 A4 G4])
(phrase :name p1 :events [(n E4 0.5b) (rest 0.25b)])
```

Both validate cleanly: each phrase carries one alternative.

Common breakage and repair:

```sjon
(phrase :name p2 :notes [E4 G4] :events [(n A4 0.5b)])
```

Diagnostic: `mutually_exclusive_keys_present`. The message lists
the alternatives (`:notes | :events`). Repair by removing one:

```sjon
(phrase :name p2 :notes [E4 G4])
```

Required-one-of missing:

```sjon
(phrase :name p3)
```

Diagnostic: `required_one_of_missing`. The group's cardinality is
`exactly-one`, so omitting both alternatives is rejected. Repair by
adding one:

```sjon
(phrase :name p3 :notes [E4])
```

Two author rules follow:

1. **The group is the source of truth for presence, not the keys'
   `optional` flag.** Even if the schema marks both keys
   `optional false`, a key participating in an `exactly-one` group
   will not produce its own `missing_required_key` — the group's
   `required_one_of_missing` covers it. You see one diagnostic per
   root cause, not two.
2. **Open forms bypass the group sweep.** If the plugin marks the
   form `open: true`, exclusive groups do not fire — not for "both
   present" and not for "neither present." Open forms are bags, and
   group cardinality is a closed-shape rule. If a plugin needs both
   extension metadata and an exclusive group, make the governed form
   closed and put free-form metadata in a separate open child form.

A form may declare more than one exclusive group, and a variant
inside a discriminated form may declare its own groups. The same
key cannot appear in two groups on the same scope (the plugin
author would get a manifest-load error). As an author you only
need to read the group blocks the schema documents — the rules
above apply identically per group.

**Multi-key bundles.** An alternative may name *more than one* key;
a multi-key bundle is "present" iff every key in the bundle is
present on the form. The wire shape looks like:

```text
(route ...)
  :name symbol required
  :from symbol optional
  :to   symbol optional
  :at   symbol optional
  exclusive-group cardinality exactly-one
    alt :keys [from to]    ; bundle: both must be present together
    alt :keys [at]         ; bundle: just `at`
```

Read it as: `(route :from a :to b)` validates clean (the `[from to]`
bundle is fully present); `(route :at c)` also validates clean. Both
of these are errors:

```sjon
(route :name r0 :from a)              ; partial bundle — :to is missing
(route :name r1 :from a :to b :at c)  ; both bundles present
```

The first fires `exclusive_bundle_partial` because `:from` is set but
`:to` is missing; the second fires
`mutually_exclusive_keys_present`. Either way, the diagnostic message
lists each bundle with `+`-joined keys (`:from+:to | :at`) so the
source of the rule is obvious.

Multi-key bundles round-trip through `sjon export-schema` as
`{required: [<bundle-keys>]}` entries inside `oneOf`. JSON Schema's
`required` keyword is all-or-nothing per the standard, so partial
bundles fail validation as `oneOf` mismatch — they don't produce a
"partial bundle" message at the JSON Schema layer. Use the SJON
validator (or the IR's warning list) for the more specific
diagnostic.

## Exercises

Discriminated-form drill. Use the `(track ...)` summary above:

```sjon
(track :kind groove :name g1 :step 4)
```

`:step` is a `kick`-variant key, not a `groove` key. Repair to a
groove-variant shape:

```sjon
(track :kind groove :name g1 :pattern straight :swing 0.1)
```

Discriminant ordering drill:

```sjon
(track :name a1 :mesh logo :kind animation)
```

Repair by writing the discriminant first:

```sjon
(track :kind animation :name a1 :mesh logo)
```

Exclusive-group drill. Use the `(phrase ...)` summary above:

```sjon
(phrase :name p4 :notes [E4 G4] :events [(n A4 0.5b)])
```

Both alternatives are present. Repair by keeping one:

```sjon
(phrase :name p4 :notes [E4 G4])
```

Empty-of-required drill:

```sjon
(phrase :name p5)
```

Neither alternative is present and the group is `exactly-one`.
Repair by supplying one:

```sjon
(phrase :name p5 :events [(n A4 0.5b)])
```

<section class="mastery-quiz" data-lesson="discriminated-and-exclusive-forms">
  <h2>Mastery Check</h2>
  <ol class="mc-list">
    <li class="mc-item" data-correct="0">
      <p class="mc-q">On a discriminated form, why must the discriminant key appear before variant-only keys?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-discriminated-and-exclusive-forms-0" value="0" /> <span>Until the discriminant is known, the validator can't tell which variant's keys are legal — variant-only keys before it produce <code>unknown_key</code> with a discriminant-first hint.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-discriminated-and-exclusive-forms-0" value="1" /> <span>For readability only.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-discriminated-and-exclusive-forms-0" value="2" /> <span>It is a parser limitation.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">For an <code>exactly-one</code> exclusive group, what distinguishes the &quot;both present&quot; diagnostic from the &quot;neither present&quot; one?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-discriminated-and-exclusive-forms-1" value="0" /> <span>They share one code; only the message differs.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-discriminated-and-exclusive-forms-1" value="1" /> <span>They are distinct codes — <code>mutually_exclusive_keys_present</code> for too many, <code>required_one_of_missing</code> for too few.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-discriminated-and-exclusive-forms-1" value="2" /> <span>Only &quot;both present&quot; produces a diagnostic.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="0">
      <p class="mc-q">What does a partial multi-key exclusive bundle produce?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-discriminated-and-exclusive-forms-2" value="0" /> <span><code>exclusive_bundle_partial</code> — some keys in the bundle are present and the rest are missing.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-discriminated-and-exclusive-forms-2" value="1" /> <span><code>required_one_of_missing</code> — partial bundles are treated as completely absent.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-discriminated-and-exclusive-forms-2" value="2" /> <span><code>duplicate_key</code> — the bundle counts as writing the same key twice.</span></label>
      </li>
      </ul>
      <p class="mc-feedback" hidden></p>
    </li>
    <li class="mc-item" data-correct="1">
      <p class="mc-q">What happens if an <code>open: true</code> form declares an exclusive group?</p>
      <ul class="mc-options">
      <li>
        <label><input type="radio" name="q-discriminated-and-exclusive-forms-3" value="0" /> <span>The group still fires; openness only affects unknown keys.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-discriminated-and-exclusive-forms-3" value="1" /> <span>The group does not fire — open forms skip closed-shape cardinality sweeps.</span></label>
      </li>
      <li>
        <label><input type="radio" name="q-discriminated-and-exclusive-forms-3" value="2" /> <span>Only <code>at-most-one</code> groups fire.</span></label>
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
