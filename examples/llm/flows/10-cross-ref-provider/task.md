---
expects: not_cross_ref
---
# Task: fill two regions with the stock swatches

Schema: `manifests/paint.sjon`, named by `sjon-project.sjon`. This flow
is the only one whose schema is not inline in the document, and it has
to be: the schema declares a **provider**, which names compiled code
(`paint.wasm`), and there is nowhere in an inline manifest to put that.

`fill` has two swatch slots, and they do not mean the same thing.
`:swatch` is typed `swatch-name`, a symbol value-kind whose cross-ref
takes the provider route:

```sjon
(cross-ref :target palette :provider swatches :source-key colors)
```

Read that as: the legal values are **not** the `:name` of any form. They
are whatever the `swatches` provider extracts from each
`(palette … :colors "…")` string, here one swatch per non-empty line.
`:stock` is the other route, the identity one: its cross-ref is
`(cross-ref :target stock)`, so its legal values are exactly the `:name`
of each `(stock …)` declaration in the document.

`attempt-1.sjon` declares `ember` and `clay` as stock swatches, then
fills the sky through the wrong route — `:swatch ember`. `ember` is
spelled correctly, is declared in this very document, and still fails:
the provider route cannot read `(stock …)` declarations, and no
`(palette …)` source exists in the document, so the member set
`:swatch` draws on is empty. The diagnostic is
`code = not_cross_ref`, `path = [fill, swatch]`, the same code and the
same slot path an identity-route miss produces, because from the
reference side nothing is different.

**The message tells you which route you are on**: *no
`(paint/palette :colors …)` source provides this name*. `:colors`, not
`:name`. That is the whole difference in the repair:

- Identity route (`:stock`) → a `(stock :name X …)` declaration
  registers X, on every host. `attempt-2.sjon` moves `ember` to the
  `:stock` slot and validates clean.
- Provider route (`:swatch`) → the names are inside the string, so
  either reference one that is already there, or add a line to a
  palette's `:colors`. **Adding `(stock :name ember …)` registers
  nothing for `:swatch`**; and neither does `(palette :name ember …)`
  — a palette's `:name` names the palette, not a swatch. Do not keep
  editing the reference site: the name is not misspelled, it is on the
  wrong route.

Two codes you may hit on this route and cannot repair at the reference:
`cross_ref_extraction_failed` (the provider read the source string and
rejected it) and `cross_ref_provider_unavailable` (this host cannot
execute the provider). Both are reported at the source string, and both
leave every reference into it **unchecked**: not reported as valid, not
reported as invalid. Silence there is the design: a member set nobody
could compute has no answer to give, and reporting `not_cross_ref`
against it would blame you for the provider's problem. It is also why
this flow's attempts never instantiate a palette: a document that did
would verify differently depending on whether the host can run
`paint.wasm`, and a repair loop has to mean the same thing everywhere
it runs.
