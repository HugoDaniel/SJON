# Zig discipline — adding a new module

This is the short checklist for any new `src/<Module>.zig`. The conventions are distilled from TigerBeetle, Mach, and the 0.16 stdlib, pruned to the subset SJON actively enforces. `src/root.zig`'s `//!` header captures the "what is already true" reference; this file is the "what to do when writing new code" handbook.

## Module skeleton

Every new module starts with a `//!` header declaring **role**, **invariants**, and (if non-trivial) a **sketch of the algorithm**. The reader should be able to ship a bug fix without leaving the file. See `src/Lexer.zig`, `src/Validator.zig`, `src/Expr.zig` for exemplars; `src/root.zig`'s `//!` header is the canonical memory-model exemplar.

```zig
//! <One-sentence role.>
//!
//! Invariants:
//! * <invariant 1, e.g. "every next() pairs with one read* or skipBody">
//! * <invariant 2>
//!
//! Algorithm:
//! <sketch — bullet list, ASCII diagram, or short paragraph>
```

## Explicit error set

Every module that returns errors declares `pub const Error = error{ … }`. Internal helpers use `Error!T`, not inferred `!T`. If the module composes with others, list its set in `src/root.zig`'s aggregate `Error`.

```zig
pub const Error = error{
    InvalidTag,
    Truncated,
    DepthExceeded,
    OutOfMemory,
};

fn step(state: *State) Error!void { … }
```

`OutOfMemory` is implicit but list it for documentation. Don't catch errors with `unreachable` unless you can prove the variant is impossible at this call site — and if you can, leave a one-line `// SAFETY: …` saying why.

## Comptime layout pins

Any struct that crosses a wire boundary (binary IR, AST, token stream) gets a `comptime { std.debug.assert(@sizeOf(T) == N); }` block. Layout drift should break the build. Exemplars: `src/Lexer.zig` (`Token == 12`), `src/Ast.zig` (`Data == 8`, `Span == 8`), `src/Binary.zig` (the wire-layout size pins).

## Allocators

Every public function takes `gpa: std.mem.Allocator` first. Producers (returning a tree, result, or buffer) wrap `gpa` in a `std.heap.ArenaAllocator`, return a struct that owns the arena, and provide a self-contained `pub fn deinit(self: *Self) void`. Don't retain `gpa`. See `src/Parser.zig`, `src/Validator.zig`, `src/Json.zig` for exemplars.

```zig
var arena = std.heap.ArenaAllocator.init(gpa);
errdefer arena.deinit();
// build into arena.allocator()
return .{ .arena = arena, .data = … };
```

## Containers (Zig 0.16)

```zig
var list: std.ArrayList(T) = .empty;
defer list.deinit(gpa);
try list.append(gpa, item);

var map: std.StringHashMapUnmanaged(V) = .empty;
defer map.deinit(gpa);
try map.put(gpa, key, value);
```

Allocator threaded per-call. Never store the allocator in the container.

## No host-stack recursion

The default: if the data structure is recursive (forms within forms, expressions within expressions), walk it with a heap frame stack under an explicit depth bound and a per-call step ceiling — never the host call stack. See `src/Parser.zig` (`MAX_PARSE_DEPTH = 1024`), `src/Expr.zig` (`MAX_EVAL_DEPTH = 256`, `MAX_STEPS = 1 << 20`), `src/Validator.zig` (`MAX_VALIDATE_FRAMES = 1024`, `MAX_VALIDATE_STEPS = 1 << 20`). Both ceilings exist deliberately. Add a depth-bound test to `oom_tests.zig` or the module's own test file.

**Bounded-recursion carve-out.** Plain host-stack recursion is allowed only when *both* hold: (1) the descent depth is bounded by a ceiling already enforced upstream, and (2) that bound is named at the function. A recursive helper with no depth parameter and no cited ceiling is a bug, not a shortcut. Canonical shape: `Json.buildAstDepth`, `Edit.applyAtPath`, and `PluginValueCodec.encodeValueDepth` each thread a `depth` argument and return `error.DepthExceeded` at their named cap (`MAX_JSON_DEPTH` / `MAX_EDIT_PATH_DEPTH` / `MAX_VALUE_DEPTH`) before descending. Descents over an already-bounded tree — `Ast.cloneNode`, the LSP `Handler`'s enclosing-node scans — cite the tree's construction ceiling (`Parser.MAX_PARSE_DEPTH`) instead. When no bound can be cited, convert to an explicit frame-stack walk, as `Lowering.validateEmittedForm` and `MaterializedDefaults`' data walk did. `Lowering`'s *emit* walk (`emitFormIntoTree` / `emitValueIntoTree`) stays recursive under the carve-out instead: `validateEmittedForm` runs first and drops the whole invocation on any violation, so both descent axes — `Plugin.MAX_LOWERED_DEPTH` for forms, `Plugin.MAX_LOWERED_VECTOR_DEPTH` for vectors — are enforced upstream and cited at both functions.

## Assertions

Inside the module: `std.debug.assert(…)` for internal invariants. Aim for ≥ 1 pre-condition and ≥ 1 post-condition on non-trivial functions. Assert positive AND negative space separately:

```zig
fn advance(self: *Cursor) void {
    std.debug.assert(self.index < self.end);              // pre
    std.debug.assert(self.depth <= MAX_DEPTH);            // pre
    self.index += 1;
    std.debug.assert(self.index <= self.end);             // post
}
```

Never assert on user input — those return errors or produce diagnostics.

## Diagnostics

User-input errors become `Ast.Diagnostic` entries on the result, not panics or thrown errors. New variants append to `Ast.Diagnostic.Code` (snake_case wire identifier). Never reorder, never rename — the enum is wire-stable across hosts. `zig build audit-diagnostics` enforces every variant has a test.

Each diagnostic carries: code, severity, source span, semantic path. Trees always exist after parse, possibly partial — collection over abort.

## Tests

Inline `test "…"` blocks at the bottom of the module. When the count grows past ~30, split into a sibling `<Module>_tests.zig` (see `Validator_tests.zig`, `Expr_tests.zig`, `Binary_tests.zig`, `Json_tests.zig`, `Host_tests.zig`).

Use `std.testing.allocator` for leak detection. Use `std.testing.FailingAllocator` for OOM coverage in `oom_tests.zig`. Use `std.testing.fuzz` with `*Smith` for never-panic harnesses in `fuzz.zig` — every input-consuming module should have one.

## Generated sources

Some committed `.zig` files are generated, not authored — `src/MetaSchema.generated.zig` is compiled from `manifests/meta.sjon` by `tools/gen_meta_schema.zig`. Don't hand-edit them; edit the source artifact and regenerate:

```
zig build gen-meta-schema -- --regen   # overwrite the committed file
```

The default (no-`--regen`) run byte-compares the committed file against a fresh generation and is wired into `zig build test`, so an un-regenerated edit fails `zig build test` (there is no CI). The generator emits rough Zig and runs it through `std.zig.Ast.render`, so output is canonical and byte-stable; emitters `@panic` on any shape they don't handle rather than silently dropping it. Same verify/`--regen` idiom as the schema-export goldens (`zig build export-schema-demo`).

## Multi-host parity

Wire-format and diagnostic-code changes propagate to:

- `hosts/web/` (Node + WASM)
- `hosts/rust/` (wasmtime)
- `hosts/typescript-parity/`
- `conformance/cases/` (corpus walker exercises every host)

Land the host updates in the same PR, not "soon."

## WASM artifact discipline

If your new module participates in WASM, decide first which artifact:

- Read-only over Binary IR? → `wasm_binary.zig` import. **Don't pull in std.json, Parser, Printer, Edit, or write-side Binary.**
- Anything write-side or text-format? → `wasm.zig` import.

Both export via `wasm_common.frame*` framing: `[u32 ok][u32 len][u8…payload]`. The build sets `entry = .disabled; rdynamic = true; link_libc = false;` per module.

## Native executable-plugin runtime (libwasmtime)

The native CLI links libwasmtime when built with `-Dplugin-exec=true` (default ON). `build.zig`'s `linkSystemWasmtime` helper probes `/opt/homebrew` and `/usr/local` for the lib + headers and adds whichever resolves — Homebrew (`brew install wasmtime`) covers macOS; on Linux, install via your distro's package manager (Arch: `pacman -S wasmtime`, Debian/Ubuntu: download the static tarball from `bytecodealliance/wasmtime` releases and drop `libwasmtime.so` + headers under `/usr/local`).

`-Dplugin-exec=false` is the escape hatch for systems without libwasmtime — the native build compiles cleanly without the link dependency, the `wasm_plugin_invoker` returns `error.PluginFuncNotImplemented` for any wasm-backed dispatch, and `zig build test` skips the 13 `conformance/cases/plugin-exec-*` cases. wasm32 targets force the option off regardless of the flag.

## Style

- `//!` module header, `///` API doc with complexity / ownership / lifetime, `//` for WHY.
- **Reference symbols, not line numbers.** Comments and docs point at `Validator.processFormWalkValidate` or `MAX_EVAL_DEPTH`, never `Validator.zig:5988` — line numbers rot on the next edit; a symbol name survives it and stays greppable. (This file follows the rule; the `src/X.zig` (`Symbol`) pointers above are deliberately line-free.)
- `snake_case` for fields, `PascalCase` for types, `camelCase` for functions per Zig convention.
- 100-column soft limit. `zig fmt` after every edit.
- One logical change per commit (`feedback_commit_cadence`). Refactors, tests, and downstream wiring stay separate.
