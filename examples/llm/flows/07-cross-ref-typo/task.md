---
expects: not_cross_ref
---
# Task: anchor a track to the `intro` phrase

Schema: `:anchor` is typed `phrase-name`, a symbol value-kind carrying
a `(cross-ref :target phrase)` refinement — its value must name a
declared `(phrase :name …)`.

`attempt-1.sjon` declares `(phrase :name intro)` but anchors to
`outro`, which no phrase declares. The diagnostic is
`code = not_cross_ref`, `path = [track, anchor]`, and the message
spells it out: *no `(refs/phrase :name …)` form declares this name*.
The fix is a name, not a shape: `attempt-2.sjon` anchors to `intro`.
