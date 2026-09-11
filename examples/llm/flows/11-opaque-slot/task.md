---
expects: not_cross_ref
---
# Task: anchor the track to the `outro` phrase, declared next to the template

Schema: `(template :name X :body <form>)` holds a body the host expands
later, and the schema marks `:body` **opaque** (`:walk-opaque true`):
the slot's type is checked, the slot's contents are not read. `:anchor`
is typed `phrase-name`, a symbol value-kind whose cross-ref takes its
legal names from every `(phrase :name …)` the document declares.

`attempt-1.sjon` declares `(phrase :name outro)` *inside* the template
body, treating the template as a container, and anchors the track to
`outro`. The diagnostic is `code = not_cross_ref`, `path = [track,
anchor]`, and the message says *no `(refs/phrase :name …)` form declares
this name* even though the text `(phrase :name outro)` is right there.

That is the rule: **nothing inside an opaque slot registers a name**.
Every walk stops at the slot, the cross-reference index included, so a
declaration written there is text the schema does not read. It is the
one way an opaque slot adds a diagnostic instead of suppressing one.

The repair is a move, not a rename. `attempt-2.sjon` declares the phrase
at the top level, where the schema reads, and leaves the template body
alone. Fixing the *reference* (a different name, a different spelling)
would loop forever: the name is spelled right and declared nowhere the
validator looks.
