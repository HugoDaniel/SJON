import { createElement } from "https://esm.sh/react@18.3.1";
import htm from "https://esm.sh/htm@3.1.1";

import { NewTodo } from "./NewTodo.mjs";
import { Filter } from "./Filter.mjs";
import { TodoList } from "./TodoList.mjs";
import { Counter } from "./Counter.mjs";

const html = htm.bind(createElement);

/**
 * Root component. Reads the projected state once per render via
 * `store.getState()`; child components reach back into the store for
 * dispatch.
 */
export function TodoApp({ store }) {
    const state = store.getState();
    const items = state.items ?? [];
    const filter = state.filter ?? "all";
    const error = state.__error ?? null;
    const counts = state.__counts ?? null;

    return html`
        <h1>SJON TODO <span class="sub">— state lives in an SJON document</span></h1>
        <${NewTodo} store=${store} nextId=${state["next-id"] ?? 1} />
        <${Filter} store=${store} active=${filter} />
        <${TodoList} store=${store} items=${items} filter=${filter} />
        <${Counter} counts=${counts} />
        ${error
            ? html`<div class="error-pill">Rejected by validator — ${error.message}</div>`
            : null}
    `;
}
