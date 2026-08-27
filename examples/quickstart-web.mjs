// SJON quickstart: a Node consumer of the WASM artifacts.
//
// Build the WASM artifacts once:
//
//     zig build wasm-all
//
// Then run this file directly (Node ≥ 22.6 strips the host's TypeScript
// types at load time):
//
//     node --experimental-strip-types examples/quickstart-web.mjs
//
// What it shows: load both WASM artifacts, round-trip a document through
// its binary IR, validate it against the built-in `core` schema (and
// watch an unknown form get caught), then evaluate a safe expression.
// See hosts/web/demo.ts for the longer walkthrough and
// hosts/web/README.md for the full wrapper surface; for the in-browser
// story see examples/web-canvas/ and examples/web-todo/.

import path from "node:path";
import { fileURLToPath } from "node:url";
import { SjonEncoder, SjonReader } from "../hosts/web/sjon-reader.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const wasmDir = path.resolve(here, "../zig-out/bin");

const encoder = await SjonEncoder.load(path.join(wasmDir, "sjon.wasm"));
const reader = await SjonReader.load(path.join(wasmDir, "sjon-binary.wasm"));

// 1. Text → Binary IR. The IR is the portable wire format every host
//    (Node, Rust, the browser) consumes, usually smaller than the
//    canonical text for repeating shapes.
const doc = '{:name "main" :bpm 130 :tracks [1 2 3]}';
const binary = encoder.toBinary(doc);
console.log(`document      : ${doc}`);
console.log(`binary IR     : ${binary.length} bytes`);

// 2. Validate the Binary IR against the built-in `core` schema. Plain
//    data and core expressions validate clean; application *forms* are
//    "unknown" until a plugin schema defines them (see examples/plugins/
//    and docs/AUTHORING.md).
const clean = reader.validateBinary(binary);
console.log(`diagnostics   : ${clean.diagnostics.length}`); // 0

const checked = reader.validateBinary(encoder.toBinary("(scene :bpm 130)"));
for (const d of checked.diagnostics) {
    console.log(`  caught      : ${d.code}: ${d.message}`);
}

// 3. Evaluate a safe expression through the same read-only path.
const expr = "(+ 1 2 (* 3 4))";
const value = reader.evalExprBinary(encoder.toBinary(expr));
console.log(`${expr} = ${JSON.stringify(value)}`); // 15
