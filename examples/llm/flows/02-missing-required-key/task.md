---
expects: missing_required_key
---
# Task: place a circle at the origin

Schema: `(circle :x <number> :y <number> :radius <number>)`, where
`:radius` is required (`:optional false`) and `:x` / `:y` are not.

`attempt-1.sjon` sets `:x` and `:y` but forgets `:radius`. The
diagnostic is `code = missing_required_key`, `path = [circle, radius]`.
The repair is additive — supply the key, don't restructure.
`attempt-2.sjon` adds `:radius 1` and validates clean.
