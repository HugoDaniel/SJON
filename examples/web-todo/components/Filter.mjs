import { createElement } from "https://esm.sh/react@18.3.1";
import htm from "https://esm.sh/htm@3.1.1";

import { setFilter } from "../actions.mjs";

const html = htm.bind(createElement);

const FILTERS = ["all", "active", "done"];

export function Filter({ store, active }) {
    return html`
        <nav class="filters">
            ${FILTERS.map(
                (name) => html`
                    <button
                        key=${name}
                        class=${name === active ? "active" : ""}
                        onClick=${() => store.dispatch(setFilter(name))}
                    >
                        ${name[0].toUpperCase() + name.slice(1)}
                    </button>
                `,
            )}
        </nav>
    `;
}
