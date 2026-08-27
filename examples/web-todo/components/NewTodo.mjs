import { createElement, useState } from "https://esm.sh/react@18.3.1";
import htm from "https://esm.sh/htm@3.1.1";

import { addTodo, bumpNextId } from "../actions.mjs";

const html = htm.bind(createElement);

export function NewTodo({ store, nextId }) {
    const [text, setText] = useState("");

    function submit(e) {
        e.preventDefault();
        const trimmed = text.trim();
        if (!trimmed) return;
        // Two dispatches: append the new todo, then bump next-id so
        // subsequent inserts don't collide. SJON Edit ops are atomic
        // per action, so we sequence them deliberately.
        store.dispatch(addTodo(nextId, trimmed));
        store.dispatch(bumpNextId(nextId + 1));
        setText("");
    }

    return html`
        <form class="new-todo" onSubmit=${submit}>
            <input
                type="text"
                value=${text}
                placeholder="Add a todo and press Enter"
                onChange=${(e) => setText(e.target.value)}
                autoFocus
            />
            <button type="submit">Add</button>
        </form>
    `;
}
