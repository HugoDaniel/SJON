// SjonStore: a Redux-shaped wrapper around an SJON document.
//
// State is held as canonical SJON source text. Every dispatch:
//   1. asks `host.encoder.applyEdit(source, action)` for the candidate
//      next text (immutable reducer);
//   2. validates the candidate against the `todo-app` plugin manifest
//      via `host.validateDocument`. If any error diagnostic comes
//      back, the previous state survives and the error rides into the
//      cached projection under `__error`;
//   3. on success, projects the new text through `to_json` (compact
//      mode) and runs `host.hostEvalExpr` against the projected items
//      to compute done/active counts; both are real `(count-done …)`
//      / `(count-active …)` plugin expr-funcs dispatched through the
//      sidecar `todo-plugin.wasm`.
//
// The resolver fetches `todo-app.sjon` once at boot and serves it for
// every `(use-plugin "todo-app" …)` reference the validator sees.

// `dist/SjonHost.js` is the browser-ESM build of the TypeScript host,
// emitted by `zig build web-todo` (which runs `tsc -p
// hosts/web/tsconfig.browser.json`).
import { SjonHost } from "../../hosts/web/dist/SjonHost.js";

const USE_PLUGIN_PRELUDE = "(use-plugin \"todo-app\")\n\n";
const STORAGE_KEY = "web-todo:state";

/**
 * @typedef {Object} SjonStore
 * @property {() => object}                  getState
 * @property {() => string}                  getSource
 * @property {(action: object) => void}      dispatch
 * @property {(fn: () => void) => () => void} subscribe
 */

/**
 * Boot the store.
 *
 * @param {{wasmUrl: URL | string, manifestUrl: URL | string, pluginWasmUrl: URL | string, seed: string}} options
 * @returns {Promise<SjonStore>}
 */
export async function createStore({ wasmUrl, manifestUrl, pluginWasmUrl, seed }) {
    const [wasmBytes, manifestText, pluginWasmBytes] = await Promise.all([
        fetch(wasmUrl).then(must("wasm", wasmUrl)).then((r) => r.arrayBuffer()),
        fetch(manifestUrl).then(must("manifest", manifestUrl)).then((r) => r.text()),
        fetch(pluginWasmUrl).then(must("plugin-wasm", pluginWasmUrl)).then((r) => r.arrayBuffer()),
    ]);
    const pluginWasm = new Uint8Array(pluginWasmBytes);

    // The resolver runs synchronously inside `validateDocument`. We
    // close over the already-fetched manifest text + plugin wasm so
    // the resolver doesn't need to do async work. Including `wasm`
    // triggers D7 pre-flight on first reference (ABI version + export
    // checks + import-emptiness).
    const resolver = (ref) => {
        if (ref.name === "todo-app") {
            return { kind: "manifest", source: manifestText, wasm: pluginWasm };
        }
        return {
            kind: "failure",
            code: "unresolved_plugin",
            detail: `unknown plugin: ${ref.name}`,
        };
    };

    const host = await SjonHost.loadFromBytes(wasmBytes, { resolver });

    // `host` layers resolver-aware validation (`validateDocument`) and
    // plugin-dispatching eval (`hostEvalExpr`) over the pure encoder.
    // The reducer / projection / persistence below go through
    // `host.encoder` is the `SjonEncoder` (`applyEdit` / `toJson` /
    // `toBinary` / `fromBinary`), which does no plugin resolution.

    // Hydrate from localStorage if available. Binary IR is the
    // transport: same bytes the Rust / TS hosts would consume, and ~25-
    // 40% smaller than canonical text for repeating shapes. Falls back
    // to `seed` on any decode failure so a poisoned localStorage entry
    // can't brick the demo.
    let source = hydrate(host) ?? seed;
    /** @type {{code: string, message: string} | null} */
    let lastError = null;
    let projection = project(host, source);
    const listeners = new Set();

    function notify() {
        for (const fn of listeners) fn();
    }

    /** @returns {any[]} validation-phase err diagnostics */
    function validateState(text) {
        const r = host.validateDocument(USE_PLUGIN_PRELUDE + text, {
            projectRoot: null,
            projectFile: null,
        });
        return r.diagnostics.filter((d) => d.severity === "err");
    }

    /**
     * Recompute done/active counts by splicing the current
     * `:items` vector into a `(count-done …)` / `(count-active …)`
     * expression and asking `hostEvalExpr` to dispatch the call
     * through the sidecar `todo-plugin.wasm`. Returns `null` for
     * each side that failed so the UI can fall back gracefully.
     *
     * @param {string} text
     */
    function recomputeCounts(text) {
        const items = extractItemsSource(text);
        if (items === null) return { done: null, active: null };
        const done = runCount("count-done", items);
        const active = runCount("count-active", items);
        return { done, active };
    }

    /**
     * @param {"count-done" | "count-active"} fn
     * @param {string} itemsSource canonical SJON for the items vector
     * @returns {number | null}
     */
    function runCount(fn, itemsSource) {
        const src = `${USE_PLUGIN_PRELUDE}(${fn} ${itemsSource})`;
        try {
            const r = host.hostEvalExpr(src, {
                projectRoot: null,
                projectFile: null,
            });
            if (r.diagnostics.some((d) => d.severity === "err")) return null;
            if (typeof r.value !== "number") return null;
            return r.value;
        } catch (err) {
            console.warn(`[counts] (${fn} …) failed:`, err);
            return null;
        }
    }

    // Seed-state sanity check.
    const seedErrors = validateState(source);
    if (seedErrors.length > 0) {
        lastError = errorOf(seedErrors[0]);
        projection = { ...projection, __error: lastError };
    }
    const seedCounts = recomputeCounts(source);
    projection = { ...projection, __counts: seedCounts };

    return {
        getState() {
            return projection;
        },
        getSource() {
            return source;
        },
        dispatch(action) {
            console.log("[dispatch]", action);
            let candidate;
            try {
                candidate = host.encoder.applyEdit(source, action);
            } catch (err) {
                lastError = { code: "apply_edit_failed", message: errMsg(err) };
                projection = { ...projection, __error: lastError };
                notify();
                return;
            }
            const errors = validateState(candidate);
            if (errors.length > 0) {
                // Reject: keep the old source, surface the first error
                // pill. The reducer stays pure because `source` never
                // moved.
                lastError = errorOf(errors[0]);
                projection = { ...projection, __error: lastError };
                console.warn("[dispatch] rejected by validator:", errors);
                notify();
                return;
            }
            source = candidate;
            lastError = null;
            const counts = recomputeCounts(source);
            projection = {
                ...project(host, source),
                __counts: counts,
            };
            persist(host, source);
            notify();
        },
        subscribe(fn) {
            listeners.add(fn);
            return () => listeners.delete(fn);
        },
        // Internal handles for upcoming steps and ad-hoc exploration.
        _host: host,
    };
}

/**
 * Pull the verbatim source of the `:items` kvpair value out of a
 * canonical-printed (todo-app …) document, so it can be spliced
 * straight into a `(count-done …)` / `(count-active …)` expression
 * without re-stringifying through JSON. We rely on the canonical
 * printer's deterministic shape (`:items` followed by `[…]`) and
 * walk brackets to find the matching close. Returns the substring
 * including the brackets, or `null` if we can't locate it.
 *
 * @param {string} text
 * @returns {string | null}
 */
function extractItemsSource(text) {
    const m = text.match(/:items\s+\[/);
    if (!m) return null;
    let i = (m.index ?? 0) + m[0].length - 1; // position on `[`
    let depth = 0;
    for (; i < text.length; i++) {
        const ch = text[i];
        if (ch === "[") depth++;
        else if (ch === "]") {
            depth--;
            if (depth === 0) return text.substring((m.index ?? 0) + m[0].length - 1, i + 1);
        }
    }
    return null;
}

function project(host, source) {
    return host.encoder.toJson(source, { mode: "compact" });
}


function persist(host, source) {
    try {
        const bin = host.encoder.toBinary(source);
        localStorage.setItem(STORAGE_KEY, bytesToBase64(bin));
    } catch (err) {
        console.warn("[persist] toBinary failed:", err);
    }
}

function hydrate(host) {
    let raw;
    try {
        raw = localStorage.getItem(STORAGE_KEY);
    } catch {
        return null;
    }
    if (!raw) return null;
    try {
        const bin = base64ToBytes(raw);
        return host.encoder.fromBinary(bin);
    } catch (err) {
        console.warn("[hydrate] dropping corrupt entry:", err);
        try {
            localStorage.removeItem(STORAGE_KEY);
        } catch {}
        return null;
    }
}

// Binary-safe base64: btoa / atob expect Latin-1 strings, so we round
// through a per-byte char/code-point dance instead of TextDecoder.
function bytesToBase64(bytes) {
    let str = "";
    for (let i = 0; i < bytes.length; i++) str += String.fromCharCode(bytes[i]);
    return btoa(str);
}
function base64ToBytes(b64) {
    const str = atob(b64);
    const out = new Uint8Array(str.length);
    for (let i = 0; i < str.length; i++) out[i] = str.charCodeAt(i);
    return out;
}

function errorOf(diag) {
    return {
        code: diag.code,
        message: `${diag.code}: ${diag.message ?? "(no message)"}`,
    };
}

function errMsg(err) {
    return err && err.message ? err.message : String(err);
}

function must(kind, url) {
    return (r) => {
        if (!r.ok) throw new Error(`failed to fetch ${kind} at ${url}: ${r.status}`);
        return r;
    };
}
