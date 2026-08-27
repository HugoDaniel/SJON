// Demo entry point: loads `sjon.wasm`, builds the store, mounts React.
//
// Run from the repo root with a static server that serves `.mjs`,
// `.wasm`, and `.js` with sensible content-types, then visit
// http://localhost:8000/examples/web-todo/.

import { createElement } from "https://esm.sh/react@18.3.1";
import { createRoot } from "https://esm.sh/react-dom@18.3.1/client";
import htm from "https://esm.sh/htm@3.1.1";

import { createStore } from "./store.mjs";
import { TodoApp } from "./components/TodoApp.mjs";

const html = htm.bind(createElement);

// Seed state. Single-root form so `Edit.applyEditToTree`'s
// `MultipleRoots` guard stays happy.
const SEED = `(todo-app
  :filter all
  :next-id 4
  :items [
    (todo :id 1 :text "Buy milk"      :done false)
    (todo :id 2 :text "Write tests"   :done true)
    (todo :id 3 :text "Ship the demo" :done false)
  ])
`;

const rootEl = document.getElementById("root");

try {
    // The wasm sits at the repo's `zig-out/bin/sjon.wasm`; with the
    // server rooted at the repo, that's two levels up from here.
    const wasmUrl = new URL("../../zig-out/bin/sjon.wasm", import.meta.url);
    const manifestUrl = new URL("./todo-app.sjon", import.meta.url);
    const pluginWasmUrl = new URL("./todo-plugin.wasm", import.meta.url);
    const store = await createStore({
        wasmUrl,
        manifestUrl,
        pluginWasmUrl,
        seed: SEED,
    });

    // Expose for console-driven exploration: `__store.dispatch({…})`,
    // `__store.getState()`, `__store.getSource()`.
    globalThis.__store = store;

    const root = createRoot(rootEl);
    const render = () => root.render(html`<${TodoApp} store=${store} />`);
    store.subscribe(render);
    render();
} catch (err) {
    rootEl.innerHTML = "";
    const pre = document.createElement("pre");
    pre.className = "error-pill";
    pre.textContent = `Boot failed: ${err && err.message ? err.message : err}`;
    rootEl.appendChild(pre);
    throw err;
}
