import { createElement } from "https://esm.sh/react@18.3.1";
import htm from "https://esm.sh/htm@3.1.1";

const html = htm.bind(createElement);

// Done/active counts come straight from the SJON evaluator. The store
// runs `host.hostEvalExpr` on every state change, splicing the
// current `:items` vector into `(count-done …)` / `(count-active …)`
// expressions that dispatch through the sidecar `todo-plugin.wasm`.
// `counts.done` / `counts.active` are `null` only if the call failed
// (rare — usually means the wasm sidecar is misbehaving); the UI
// falls back to a dash in that case so it never lies.
export function Counter({ counts }) {
    const done = counts?.done ?? null;
    const active = counts?.active ?? null;
    return html`
        <p class="counter">
            ${fmt(done)} done · ${fmt(active)} active
            <span class="counter-source"
                title="Computed by (count-done items) and (count-active items) — plugin expr-funcs bodied by todo-plugin.wasm"
                >— via SJON Expr</span
            >
        </p>
    `;
}

function fmt(n) {
    return n === null ? "—" : String(n);
}
