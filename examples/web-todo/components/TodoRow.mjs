import { createElement } from "https://esm.sh/react@18.3.1";
import htm from "https://esm.sh/htm@3.1.1";

import { toggleTodo, removeTodo } from "../actions.mjs";

const html = htm.bind(createElement);

export function TodoRow({ store, todo, index }) {
    const toggle = () => store.dispatch(toggleTodo(index, !todo.done));
    const remove = () => store.dispatch(removeTodo(index));
    return html`
        <li class=${todo.done ? "done" : ""}>
            <input type="checkbox" checked=${todo.done} onChange=${toggle} />
            <span class="text">${todo.text}</span>
            <button class="remove" onClick=${remove} title="Remove">×</button>
        </li>
    `;
}
