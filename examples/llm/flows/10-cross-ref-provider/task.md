---
expects: not_cross_ref
---
# Task: fill two regions from a palette's swatches

Schema: `manifests/paint.sjon`, named by `sjon-project.sjon`. This flow
is the only one whose schema is not inline in the document, and it has
to be: the schema declares a **provider**, which names compiled code
(`paint.wasm`), and there is nowhere in an inline manifest to put that.

`:swatch` is typed `swatch-name`, a symbol value-kind whose cross-ref
takes the provider route:

```sjon
(cross-ref :target palette :provider swatches :source-key colors)
```

Read that as: the legal values are **not** the `:name` of any form. They
are whatever the `swatches` provider extracts from each
`(palette … :colors "…")` string, here one swatch per non-empty line.
So `attempt-1.sjon`'s palette declares `ember`, `dusk`, `clay`, and
those three names appear nowhere in the document's own syntax.

`attempt-1.sjon` fills with `dust`, which is in no line. The diagnostic
is `code = not_cross_ref`, `path = [fill, swatch]`, the same code and
the same slot path an identity-route miss produces, because from the
reference side nothing is different.

**The message tells you which key to read**: *no `(paint/palette
:colors …)` source provides this name*. `:colors`, not `:name`. That is
the whole difference in the repair:

- Identity route (`:name-key`) → add or fix a `(form :name X …)`
  declaration.
- Provider route (`:source-key`) → the names are inside the string, so
  either reference one that is already there, or add a line to the
  string. **Adding `(palette :name dust …)` registers nothing**; it
  declares a palette, not a swatch.

`attempt-2.sjon` takes the first option and fills with `clay`.

Two codes you may hit on this route and cannot repair at the reference:
`cross_ref_extraction_failed` (the provider read the source string and
rejected it) and `cross_ref_provider_unavailable` (this host cannot
execute the provider). Both are reported at the source string, and both
leave every reference into it **unchecked**: not reported as valid, not
reported as invalid. Silence there is the design: a member set nobody
could compute has no answer to give, and reporting `not_cross_ref`
against it would blame you for the provider's problem.
