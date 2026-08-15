# `web-todo` — Redux-style TODO app on SJON

A self-contained browser demo that uses [SJON](../../README.md) as the
state container behind a React TODO list:

- **State** is a single canonical `(todo-app …)` form, held in memory
  as SJON source text and persisted to `localStorage` as Binary IR.
- **Reducer** is `host.encoder.applyEdit(source, action)` — a pure
  `(state, action) → state` function. Actions are JSON `Edit` ops
  decoded by `src/Edit.zig`. (`host.encoder` is the plain `SjonEncoder`;
  `host` itself adds resolver-aware `validateDocument` / `hostEvalExpr`.)
- **Validation** gates every dispatch: each candidate state is run
  through `host.validateDocument` against the `todo-app` plugin
  manifest. Invalid actions roll back and surface as an error pill.
- **Selectors** (`(count-done items)`, `(count-active items)`) are
  SJON expressions evaluated through `host.hostEvalExpr`. The host
  splices the projected `:items` vector into the expression source
  on every state change and dispatches into the sidecar
  `todo-plugin.wasm`, which decodes the form-shaped argument and
  returns the count. No JS-side counting.

## Run it

```sh
# 1. Build everything the demo needs — both wasm artifacts, the sidecar
#    plugin, and the browser-ESM build of the host (hosts/web/dist/):
zig build web-todo

# 2. Serve the repo root with any static server that honours .mjs /
#    .wasm MIME types. Python 3 works out of the box:
python3 -m http.server -d . 8000

# 3. Open the demo
open http://localhost:8000/examples/web-todo/
```

> **Import idiom.** `main.mjs` imports the host from
> `hosts/web/dist/sjon-reader.js` — the pre-compiled ESM — because a
> browser can't strip TypeScript types (same for `examples/web-canvas/`).
> The Node-only `examples/quickstart-web.mjs` instead imports the
> `hosts/web/*.ts` source directly and leans on Node ≥ 22.6's
> `--experimental-strip-types`. Same host, two entry points.

Then play with it:

- Type a todo, press Enter — new row, counter updates, the action is
  logged to the console.
- Tick / untick a checkbox — `count-done` and `count-active`
  immediately re-evaluate; both numbers come from
  `todo-plugin.wasm` walking the vector-of-form.
- Filter by All / Active / Done — `:filter` is set in state, not in
  the URL.
- Refresh — the list survives (Binary IR rehydration from
  `localStorage["web-todo:state"]`).
- In DevTools, drive the store directly: `__store.dispatch({…})`,
  `__store.getState()`, `__store.getSource()`.
- Try a deliberately-bad action to see the validator reject it:
  ```js
  __store.dispatch({ op: "set_keyword", path: ["items", 0], key: "done", value: "oops" })
  ```
  The error pill shows `wrong_underlying: form 'todo' keyword ':done'
  expects boolean, got string`; the previous state survives.

## File map

| File | Role |
|---|---|
| `index.html` | Static scaffold; loads `main.mjs` as an ES module. |
| `main.mjs` | Boot: fetches wasm + manifest, creates store, mounts React. |
| `store.mjs` | The SJON-backed Redux store: `dispatch`, `getState`, `subscribe`, persist/hydrate, and counter recompute via `hostEvalExpr`. |
| `actions.mjs` | Action creators returning JSON `Edit` ops. |
| `components/*.mjs` | React components using [`htm`](https://github.com/developit/htm) tagged templates (no JSX build step). |
| `style.css` | Minimal styling. |
| `todo-app.sjon` | SJON plugin manifest: forms, value-kinds, three expr-funcs. |
| `todo-plugin/plugin.zig` | Sidecar wasm source — `(sum …)`, `(count-done …)`, `(count-active …)` per the v2 plugin ABI. |
| `todo-plugin.wasm` | Built artifact (staged by `zig build web-todo`). |
| `sjon.wasm` | Kitchen-sink SJON wasm (staged by `zig build web-todo`). |

## The pattern, in one diagram

```
React event
   │
   ▼
action ── JSON ──▶ store.dispatch(action)
                          │
                          ├── host.encoder.applyEdit(source, action)         ⟶ candidate (text)
                          ├── host.validateDocument(prelude + candidate)     ⟶ {diagnostics}
                          │       │
                          │       ├── on error: rollback + error pill
                          │       └── on ok:  source := candidate
                          │
                          ├── host.encoder.toJson(source, {mode: "compact"}) ⟶ projection (plain JS object)
                          ├── host.hostEvalExpr(prelude + "(count-done …)")   ⟶ done count (number)
                          ├── host.hostEvalExpr(prelude + "(count-active …)") ⟶ active count (number)
                          ├── host.encoder.toBinary(source)                  ⟶ localStorage["web-todo:state"]
                          └── notify subscribers                             ⟶ React re-render
```

Action shapes are pinned by `src/Edit.zig`'s `//!` header. Each is
exactly one logical mutation; multi-step user intents (like "add a
todo and bump next-id") fire multiple dispatches.

## How the selectors work

The store extracts the canonical `:items [...]` substring from the
current source on every state change and splices it into:

```sjon
(use-plugin "todo-app")
(count-done [(todo :id 1 :text "..." :done false) ...])
```

`host.hostEvalExpr` parses that, runs the resolver to load
`todo-app.sjon`, instantiates `todo-plugin.wasm` (pre-flighted once
per host), and dispatches the `count_done` export with a binary
argument list that carries each `(todo …)` as a v2 form value
(`Tag.form = 0x07`). The plugin walks the vector, decodes each
form's `:done` kvpair, and returns the count.

This means the *exact same* SJON expression you could type into the
Zig CLI's `sjon eval` runs the demo's counters. The plugin runs in a
sandboxed WASM instance with empty imports.

## Cross-host parity

`conformance/cases/web-todo-schema/` pins the forms-only schema (no
expr-funcs) so the Rust + TypeScript hosts see exactly the same
diagnostic stream the web host does. The full manifest at
`todo-app.sjon` (with the expr-funcs) is exercised at runtime by the
demo and by the Node tests in `hosts/web/test/`.
