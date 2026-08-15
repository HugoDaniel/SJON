---
expects: unknown_key
---
# Task: point a camera in orthographic mode at 2× zoom

Schema (inline in the doc): `(camera :mode <symbol> :zoom <number>)`,
both keys optional.

`attempt-1.sjon` is a first draft with a typo: `:zom` instead of
`:zoom`. Validate it —

```
sjon validate examples/llm/flows/01-unknown-key/attempt-1.sjon --format=json --no-project
```

— and the diagnostic hands you the repair: `code = unknown_key`,
`path = [camera, zom]`. The key isn't declared on `camera`; the
nearest declared one is `:zoom`. `attempt-2.sjon` is the fix and
validates clean (empty `diagnostics`, exit 0).
