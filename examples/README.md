# Examples

Each `.sjon` fixture documents itself with a header comment; this is just an
index. Run any host demo with the `zig build` verb noted below.

| File | Demonstrates |
| --- | --- |
| [`basic.sjon`](basic.sjon) | Pure data: forms, keyword properties, vector literals, primitive types. No expressions. |
| [`with-expressions.sjon`](with-expressions.sjon) | Every safe-expression operation, exercised once. |
| [`wgsl-shader.sjon`](wgsl-shader.sjon) | Multi-line WGSL embedded via triple-quoted raw strings (`"""…"""`). |
| [`webgpu-render-pipeline.sjon`](webgpu-render-pipeline.sjon) | A compact, non-exhaustive WebGPU render-pipeline sketch: schema validation, cross-ref diagnostics, safe-expression computed values, defaults, host-owned lowering. |
| [`unknown-key-typo.sjon`](unknown-key-typo.sjon), [`warning-deprecated.sjon`](warning-deprecated.sjon), [`hint-plugin-typo/`](hint-plugin-typo) | Diagnostic fixtures — malformed / deprecated input paired with the diagnostics they raise. |
| [`binary-ir-demo.zig`](binary-ir-demo.zig) | Binary IR end-to-end: parse → toBinary → fromBinary → cursor walk. `zig build demo-binary`. |
| [`export-schema-demo.zig`](export-schema-demo.zig) | Schema export walkthrough. |
| [`union-demo.zig`](union-demo.zig) | `union_of` value-kind refinement. |
| [`plugins/`](plugins/README.md) | Reference plugin (`shapes`): forms, value kinds, expression functions, a runnable demo, and a copy-paste template for downstream packages. `zig build shapes-demo`. |
| [`plugins/xref/`](plugins/xref) | Every `(cross-ref …)` axis in one manifest — bare, `:acyclic`, `:scope`-bound, the provider route (`:provider` + `:source-key`, whose member set is extracted from a string in the document), and a target group (`:target [a b]`, several forms sharing one namespace). Read it beside the four export goldens: the routes differ in what an exporter can say about them, not in the JSON they produce. The bottom of `example.sjon` is the clearest place in the repo to see the group next to the `:union`-of-two-cross-refs it replaces — the same two targets, and the answers differ exactly where a name is defined twice (`duplicate_cross_ref_target` at the declarations vs. `union_ambiguous` at every reference). |
| [`plugins/dimensions/`](plugins/dimensions) | Digit-leading enum members — `GPUTextureDimension` spelled `1d` / `2d` / `3d`, the way the WebGPU spec spells it, which no bare SJON symbol can express. Read it beside the goldens: this is the one member shape whose wire encoding is `{"$num": [2, "d"]}` rather than `{"$sym": "2d"}`, and the mixed `view-dimension` set shows both side by side. `2d-array` is there too — one token only because a hyphen may join two letter runs inside a unit. Doubles as a migration reference for a host retiring a numeric lookup table. |
| [`plugins/head-counts/`](plugins/head-counts) | Per-head positional counts: a `(head :name … :min … :max …)` head-set bounding how many of each section a pipeline may carry. `example.sjon` is the clean pair plus the keyed slot where the counts go inert; `example-too-many.sjon`, `example-missing.sjon`, and `example-open.sjon` are the three breaches (the last showing that `:open true` silences neither). |
| [`plugins/uniforms/`](plugins/uniforms) | The provider route *running*: a real WGSL `var<uniform>` extractor (`uniforms_extract.zig` → `plugin.wasm`, rebuilt by `zig build plugin-fixtures`) and three documents driving it — `scene.sjon` resolves binds against names that exist only inside the shader string, `scene-typo.sjon` fires `not_cross_ref`, `scene-malformed.sjon` poisons the bucket (`cross_ref_extraction_failed`, references silent). Validate each with `sjon validate --project-root=examples/plugins/uniforms <file>`. |
| [`llm/`](llm/README.md) | SJON packaged for LLM authors: a paste-into-context `PRIMER.md`, ten worked write→validate→repair flows, a token-efficiency receipt vs. JSON + JSON Schema. Byte-diffed by `zig build llm-pack-verify`. |
| [`web-todo/`](web-todo/README.md) | Browser demo: `sjon.wasm` driving a todo-list UI. `zig build web-todo`. |
| [`web-canvas/`](web-canvas) | Browser demo: schema-driven canvas rendering. |
| [`quickstart-web.mjs`](quickstart-web.mjs) | Minimal Node/WASM consumer, mirrors [`docs/INTEGRATION.md`](../docs/INTEGRATION.md). |
| [`quickstart-rust.rs`](quickstart-rust.rs) | Minimal Rust consumer, mirrors [`docs/INTEGRATION.md`](../docs/INTEGRATION.md). |

`hosts/web/` (Node/browser consumer of `sjon.wasm` + `sjon-binary.wasm`,
JSDoc-typed wrapper + `.d.ts`, exercised by `node:test`, Node ≥ 20) is
documented in [`hosts/web/README.md`](../hosts/web/README.md).
