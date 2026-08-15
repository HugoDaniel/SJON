---
expects: missing_discriminant_key, unknown_key
---
# Task: define a `kick` track with a step count

Schema: `track` is a **discriminated** form. Its `:kind` key
(`:optional false`) selects a variant — `kick` or `bass` — and each
variant unlocks its own keys: `kick` has `:step`, `bass` has
`:sequence`. `:name` is common to both.

Three attempts, two repairs:

1. `attempt-1.sjon` — `(track :name k1)` omits `:kind`. Diagnostic:
   `missing_discriminant_key`, `path = [track]`. The form can't pick a
   variant without it.
2. `attempt-2.sjon` — `(track :kind kick … :sequence …)` sets the
   discriminant but reaches for `:sequence`, which belongs to the
   `bass` variant. Diagnostic: `unknown_key`, and the message says so
   explicitly: *unknown keyword `:sequence` in form `track` (variant
   `:when kick`)*. Use the current variant's keys, or change `:kind`.
3. `attempt-3.sjon` — `(track :kind kick :name k1 :step 4)` uses a
   `kick`-variant key. Clean.
