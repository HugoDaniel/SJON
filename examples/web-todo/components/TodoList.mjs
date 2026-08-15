import { createElement } from "https://esm.sh/react@18.3.1";
import htm from "https://esm.sh/htm@3.1.1";

import { TodoRow } from "./TodoRow.mjs";

const html = htm.bind(createElement);

function visible(items, filter) {
    if (filter === "active") return items.filter((t) => !t.done);
    if (filter === "done") return items.filter((t) => t.done);
    return items;
}

export function TodoList({ store, items, filter }) {
    const filtered = visible(items, filter);
    if (filtered.length === 0) {
        return html`<p class="counter">No todos to show.</p>`;
    }
    // The :items vector is a positional list, so the dispatch index
    // must be the row's position in the *unfiltered* state. We zip
    // each visible row with its original index here so TodoRow can
    // emit the right Edit op.
    return html`
        <ul class="todos">
            ${filtered.map(
                (todo) => html`
                    <${TodoRow}
                        key=${todo.id}
                        store=${store}
                        todo=${todo}
                        index=${items.indexOf(todo)}
                    />
                `,
            )}
        </ul>
    `;
}
