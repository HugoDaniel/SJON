// SJON structural editing: `wrap`, and which root an edit starts at.
//
// Build the WASM artifacts once:
//
//     zig build wasm-all
//
// Then run this file directly (Node ≥ 22.6 strips the host's TypeScript
// types at load time):
//
//     node --experimental-strip-types examples/edit-wrap.mjs
//
// What it shows. An edit action is a JSON object with an `op`, a `path`
// into the document, and op-specific fields (docs/LANGUAGE.md §11).
// Five of the six ops build their new node from a JSON `value`, and the
// JSON bridge carries no comments, so a subtree you re-encode loses the
// comments inside it even when you only meant to put it under a new
// parent. `wrap` is the op for that case: it clones the node at `path`
// into a `hole` inside the new parent, so the wrapped subtree keeps
// its comments. (Layout is another matter: the result is re-printed
// from the tree, so line breaks are the printer's on every run, and a
// form carrying a comment always goes multi-line.)
//
// The document has two roots (a `(use-plugin …)` and the camera), which
// is what every real SJON file that names a plugin looks like. An edit
// on such a file names its root with `"root": N`; omitting it is a
// refusal, not an implicit 0.

import path from "node:path";
import { fileURLToPath } from "node:url";
import { SjonEncoder } from "../hosts/web/sjon-reader.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const encoder = await SjonEncoder.load(path.resolve(here, "../zig-out/bin/sjon.wasm"));

const source = `(use-plugin "scene")

(camera :name wide
  :alpha (* 2
            ;; the base curve
            (sin t)))
`;

console.log("source:");
console.log(indent(source));

// 1. wrap: (* 2 (sin t)) becomes (+ (* 2 (sin t)) 0.1). `value` is the
//    new parent with a placeholder where the wrapped node lands, and
//    `hole` is the path to that placeholder inside `value`: [0] is the
//    parent's first positional child. The comment inside `(* …)` rides
//    along, because the node is cloned rather than rebuilt; the layout
//    around it is re-derived.
const wrapped = encoder.applyEdit(source, {
    op: "wrap",
    root: 1,
    path: ["alpha"],
    value: { $expr: ["+", null, 0.1] },
    hole: [0],
});
console.log("wrap ['alpha'] into (+ _ 0.1):");
console.log(indent(wrapped));

// 2. The same shape spelled as a replace whose value nests the old
//    subtree. Identical tree, and the comment is gone: everything in a
//    `value` crosses the JSON bridge, and the bridge has no comments.
const replaced = encoder.applyEdit(source, {
    op: "replace",
    root: 1,
    path: ["alpha"],
    value: { $expr: ["+", { $expr: ["*", 2, { $expr: ["sin", { $sym: "t" }] }] }, 0.1] },
});
console.log("replace ['alpha'] with the nested value (comment lost):");
console.log(indent(replaced));

// 3. Omit `root` on a two-root document. The engine refuses rather than
//    guessing which form you meant; the error names the reason.
try {
    encoder.applyEdit(source, { op: "set_keyword", path: [], key: "zoom", value: 2 });
    console.log("unexpected: the edit applied without a root");
} catch (err) {
    console.log(`omitted root on two roots: ${err.message}`);
}

function indent(text) {
    return text.replace(/\n$/, "").split("\n").map((l) => `    ${l}`).join("\n") + "\n";
}
