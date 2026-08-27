---
expects: not_member
---
# Task: fill a circle with a valid fill rule

Schema: `:fill` is typed `fill-rule`, a closed value-kind whose
member set is `[nonzero evenodd]`.

`attempt-1.sjon` writes `:fill diagonal`, a plausible-sounding value
that isn't in the set. The diagnostic is `code = not_member`,
`path = [circle, fill]`, and the message lists the allowed members.
Pick one of them; don't invent. `attempt-2.sjon` uses `:fill nonzero`.
(Note `nonzero` is a bare **symbol**, not a string: `:fill "nonzero"`
would fail as `wrong_underlying`.)
