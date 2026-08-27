//! Zig build script for SJON.
//!
//! Produces:
//!   - `sjon` library module (consumed via path dependency, e.g. PNGine).
//!   - `sjon.wasm` — kitchen-sink WASM artifact (parse / print / validate /
//!     evalExpr / JSON / binary IR / edit).
//!   - `sjon-binary.wasm` — read-only WASM artifact, binary IR validate +
//!     evalExpr only (no Parser / Printer / Json / Edit).
//!   - `test` step running every in-source unit test (no separate tests/
//!     directory — every src/*.zig discovers its own tests via root.zig).
//!
//! Requires Zig 0.16.x or newer.

const std = @import("std");
const builtin = @import("builtin");

// Pin the minimum Zig version at compile time. SJON uses 0.16-only APIs
// (`std.testing.Smith`, `std.Io.Dir`, the new `std.heap.wasm_allocator`
// surface) so an older toolchain would surface as confusing import errors;
// fail with a single explicit message here instead.
comptime {
    if (builtin.zig_version.major != 0 or builtin.zig_version.minor < 16) {
        @compileError("sjon requires Zig 0.16.x or newer");
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---------------------------------------------------------------------
    // Build options
    //
    // `-Dplugin-exec` toggles the native executable-plugin runtime adapter
    // (`src/runtimes/wasmtime.zig` + `src/PluginRuntime.zig`). When true,
    // the native CLI links libwasmtime and instantiates `:impl
    // "wasm:<name>"` sidecars; when false, the native path stays at the
    // historical "declarative-only" behavior — `wasm_plugin_invoker.invoke`
    // returns `error.PluginFuncNotImplemented` and the conformance test
    // skips every `plugin-exec-*` case.
    //
    // The option is wasm32-incoherent (the WASM build dispatches through
    // the `sjon_host_invoke_plugin` host import, not a linked runtime), so
    // force-disable it on wasm32 targets regardless of the CLI flag.
    //
    // Default is ON, matching the Web + Rust hosts' execution-path
    // behavior. Pass `-Dplugin-exec=false` on systems without libwasmtime
    // (the native test step degrades to skip the 13 `plugin-exec-*`
    // conformance cases). Plumbed into every module via `b.addOptions()`;
    // consumers branch on `@import("build_options").plugin_exec`.
    // ---------------------------------------------------------------------
    const target_is_wasm32 = target.result.cpu.arch == .wasm32;
    const plugin_exec_opt = b.option(
        bool,
        "plugin-exec",
        "Enable executable WASM plugin support on native (links libwasmtime). Forced off on wasm32 targets. Default: true.",
    );
    const plugin_exec = if (target_is_wasm32) false else (plugin_exec_opt orelse true);

    const sjon_build_options = b.addOptions();
    sjon_build_options.addOption(bool, "plugin_exec", plugin_exec);
    // `sjon.wasm`'s embedders (hosts/web, the Rust wasmtime host) supply
    // `env.sjon_host_invoke_plugin`, so it may declare the import.
    sjon_build_options.addOption(bool, "wasm_plugin_host", true);
    const build_options_mod = sjon_build_options.createModule();

    // Same options with the plugin-invoke import switched off, for
    // `sjon-lsp.wasm`. The playground and `gen-lsp-meta.mjs` instantiate
    // that artifact with **no imports** (`instantiate(mod, {})`), so any
    // declared import makes it fail to load outright — a browser LSP has
    // no plugin pool to invoke into regardless. Kept as a second options
    // module rather than a target check inside the invoker because
    // `sjon.wasm` is also wasm32 and does want the import.
    const lsp_build_options = b.addOptions();
    lsp_build_options.addOption(bool, "plugin_exec", plugin_exec);
    lsp_build_options.addOption(bool, "wasm_plugin_host", false);
    const lsp_build_options_mod = lsp_build_options.createModule();

    // ---------------------------------------------------------------------
    // Core library module
    //
    // `plugin_exec=true` pulls `PluginRuntime` + `runtimes/wasmtime.zig`
    // into the module graph transitively via `wasm_plugin_invoker.zig`.
    // Both reference `extern "c"` wasmtime symbols, so the link
    // dependency needs to land on `sjon_mod` itself; every consumer
    // (CLI, native LSP, tests rooted on src/) inherits it.
    // ---------------------------------------------------------------------
    const sjon_mod = b.addModule("sjon", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (plugin_exec) true else null,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
        },
    });
    if (plugin_exec) linkSystemWasmtime(b, sjon_mod);

    // ---------------------------------------------------------------------
    // WASM build (editor consumption).
    //
    // Built with `ReleaseSmall`; the dominant cost is the std lib
    // (`std.json` generic Value, ArrayHashMap in `Printer.zig`'s length
    // pre-pass, `std.fmt` float helpers). The narrower `sjon-binary.wasm`
    // artifact below skips those imports for read-only consumers.
    // ---------------------------------------------------------------------
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm = addWasmExe(b, wasm_target, "sjon", "src/wasm.zig", &.{
        .{ .name = "build_options", .module = build_options_mod },
    });

    const install_wasm = b.addInstallArtifact(wasm, .{});
    const wasm_step = b.step("wasm", "Build WASM binary");
    wasm_step.dependOn(&install_wasm.step);

    // ---------------------------------------------------------------------
    // Read-only binary-IR-only WASM artifact.
    //
    // Imports a subset of SJON: Ast / Schema / Plugin / Validator / Expr /
    // BinaryCursor / Pattern / PatternQuery / plugins.core / plugins.pattern
    // / wasm_common / version. Does NOT pull Parser, Printer, Json, Edit, or
    // write-side Binary — `audit-wasm-imports` gates the closure (BFS from
    // `src/wasm_binary.zig`).
    // ---------------------------------------------------------------------
    const wasm_binary = addWasmExe(b, wasm_target, "sjon-binary", "src/wasm_binary.zig", &.{
        .{ .name = "build_options", .module = build_options_mod },
    });

    const install_wasm_binary = b.addInstallArtifact(wasm_binary, .{});
    const wasm_binary_step = b.step("wasm-binary", "Build read-only sjon-binary.wasm");
    wasm_binary_step.dependOn(&install_wasm_binary.step);

    const wasm_all_step = b.step("wasm-all", "Build both WASM artifacts");
    wasm_all_step.dependOn(&install_wasm.step);
    wasm_all_step.dependOn(&install_wasm_binary.step);

    // ---------------------------------------------------------------------
    // WASM LSP artifact (sjon-lsp.wasm).
    //
    // The WASM target doesn't need lsp-kit (Handler.zig only imports `sjon`;
    // wasm.zig rolls its own JSON-RPC dispatcher) so it lives outside the
    // lsp_kit lazy-dependency block. Sibling native build is wired further
    // down, gated by `if (b.lazyDependency("lsp_kit", ...))`.
    // ---------------------------------------------------------------------
    const sjon_wasm_lsp_mod = b.addModule("sjon-wasm-lsp", .{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .link_libc = false,
        .imports = &.{
            .{ .name = "build_options", .module = lsp_build_options_mod },
        },
    });
    // The URI helper carries the hash context both of Handler's URI-keyed
    // maps use, so every Handler module below imports it. Std-only, so it
    // costs the artifact nothing beyond the comparison itself.
    const uri_wasm_mod = b.addModule("sjon-lsp-uri-wasm", .{
        .root_source_file = b.path("src/lsp/uri.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .link_libc = false,
    });
    const handler_wasm_mod = b.addModule("sjon-lsp-handler-wasm", .{
        .root_source_file = b.path("src/lsp/Handler.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .link_libc = false,
        .imports = &.{
            .{ .name = "sjon", .module = sjon_wasm_lsp_mod },
            .{ .name = "build_options", .module = lsp_build_options_mod },
            .{ .name = "uri", .module = uri_wasm_mod },
        },
    });
    const lsp_wasm = addWasmExe(b, wasm_target, "sjon-lsp", "src/lsp/wasm.zig", &.{
        .{ .name = "Handler", .module = handler_wasm_mod },
        // `wasm.zig` reads `sjon.version`; the module is already
        // linked transitively via `Handler`, named here so the
        // entry file can reference it without a cross-dir import.
        .{ .name = "sjon", .module = sjon_wasm_lsp_mod },
        .{ .name = "build_options", .module = lsp_build_options_mod },
    });

    const install_lsp_wasm = b.addInstallArtifact(lsp_wasm, .{});
    const lsp_wasm_step = b.step("wasm-lsp", "Build the SJON LSP (WASM)");
    lsp_wasm_step.dependOn(&install_lsp_wasm.step);

    // Stage the WASM into the landing-page so the playground route can fetch
    // `/sjon-lsp.wasm` directly. Mirrors the cp pattern used by the web-todo
    // example a few sections down.
    const stage_landing_page_lsp_wasm = stageArtifact(b, lsp_wasm, "landing-page/public/sjon-lsp.wasm");

    // Record the staged wasm's sha256 + serverInfo into a sidecar the
    // playground reads to cache-bust the URL and warn on a stale artifact.
    // Runs after the cp (reads the staged copy). Needs `node`; the sidecar is
    // gitignored, so a fresh checkout that skips this step just runs without
    // the guard (fetchWasmMeta → null → degrades quietly).
    const gen_lsp_meta = b.addSystemCommand(&.{
        "node",
        "landing-page/scripts/gen-lsp-meta.mjs",
    });
    gen_lsp_meta.step.dependOn(&stage_landing_page_lsp_wasm.step);

    const landing_page_assets_step = b.step(
        "landing-page-assets",
        "Stage WASM artifacts into landing-page/public/",
    );
    landing_page_assets_step.dependOn(&stage_landing_page_lsp_wasm.step);
    landing_page_assets_step.dependOn(&gen_lsp_meta.step);

    // ---------------------------------------------------------------------
    // Plugin fixtures — build executable-plugin sidecar binaries that the
    // Web + Rust host tests (and `conformance/cases/*-plugin-*/`) load.
    //
    // The .wasm artifacts are checked in so host tests can run without a
    // Zig toolchain; this step rebuilds them in place. Deliberately NOT
    // wired into `zig build test` — keeps cold-cache builds fast and lets
    // a checksum-style PR review catch unexpected regenerations.
    // ---------------------------------------------------------------------
    const double_plugin = addWasmExe(b, wasm_target, "double", "examples/plugins/double/double.zig", &.{});

    const stage_double = stageArtifact(b, double_plugin, "examples/plugins/double/plugin.wasm");

    // Conformance fixture — ABI 99 stub. The corpus case `plugin-exec-
    // abi-mismatch` pairs `manifests/shapes.sjon` with `manifests/
    // shapes.wasm`; this build step produces the latter so the host's
    // pre-flight surfaces `plugin_abi_mismatch` end-to-end.
    const abi99_plugin = addWasmExe(b, wasm_target, "abi-99", "conformance/fixtures/abi-99.zig", &.{});

    const stage_abi99 = stageArtifact(b, abi99_plugin, "conformance/cases/plugin-exec-abi-mismatch/manifests/shapes.wasm");

    // Conformance fixture — forbidden-import stub. The corpus case
    // `plugin-exec-import-forbidden` pairs `manifests/forbidden.sjon` with
    // `manifests/forbidden.wasm`; this build step produces the latter so
    // the host's pre-flight surfaces `plugin_import_forbidden` end-to-end.
    const import_forbidden_plugin = addWasmExe(b, wasm_target, "import-forbidden", "conformance/fixtures/import_forbidden.zig", &.{});

    const stage_import_forbidden = stageArtifact(b, import_forbidden_plugin, "conformance/cases/plugin-exec-import-forbidden/manifests/forbidden.wasm");

    // Conformance fixtures that reuse the single `double.wasm` binary. Each
    // corpus case pairs a manifest naming `double.wasm` with a document that
    // drives a distinct D7 plugin-exec code (or a §18 round-trip stretch),
    // so one artifact stages to many destinations. The trailing comment on
    // each entry names what that case exercises; the wasm still has to be
    // loadable everywhere because pre-flight runs ahead of validation.
    const double_dests = [_][]const u8{
        "conformance/cases/plugin-exec-export-missing/manifests/double.wasm", // manifest names an absent export
        "conformance/cases/plugin-exec-trap/manifests/double.wasm", // dispatches to wasm:trap
        "conformance/cases/plugin-exec-double-eval/manifests/double.wasm", // happy-path double eval
        "conformance/cases/plugin-exec-func-failed/manifests/double.wasm", // wasm:fail → plugin_func_failed
        "conformance/cases/plugin-exec-alloc-failed/manifests/double.wasm", // wasm:huge → plugin_func_alloc_failed
        "conformance/cases/plugin-exec-result-type/manifests/double.wasm", // wrong :result → plugin_func_result_type
        "conformance/cases/plugin-exec-keyword-roundtrip/manifests/double.wasm", // §18 wasm:tag keyword identity
        "conformance/cases/plugin-exec-vector-roundtrip/manifests/double.wasm", // §18 wasm:vec3_length
        "conformance/cases/plugin-exec-large-vector/manifests/double.wasm", // §18 wasm:vector_sum, 10k elems
        "conformance/cases/plugin-exec-arity-violation/manifests/double.wasm", // pre-dispatch arity check
        "conformance/cases/plugin-exec-form-roundtrip/manifests/double.wasm", // §18 Tag.form crosses the boundary
        "conformance/cases/use-plugin-hash-mismatch/manifests/double.wasm", // :hash all-zeros vs real hash
    };

    // Conformance fixture — the `lines` cross-ref provider. One binary
    // carries both extractors (`extract_lines`, `extract_lines_overflow`)
    // and fans out to every executable-tier `cross-ref-provider-*` case,
    // the same one-artifact-many-destinations shape as `double.wasm`.
    // `cross-ref-provider-unavailable` is deliberately absent from the
    // list: its manifest declares the provider with no `:impl`, and a
    // sibling `.wasm` would give the resolver something to pair.
    const lines_provider = addWasmExe(b, wasm_target, "lines", "conformance/fixtures/lines_provider.zig", &.{});

    const lines_dests = [_][]const u8{
        "conformance/cases/cross-ref-provider-resolved/manifests/lines.wasm", // extracted names resolve
        "conformance/cases/cross-ref-provider-missing/manifests/lines.wasm", // a reference outside the set
        "conformance/cases/cross-ref-provider-extraction-failed/manifests/lines.wasm", // refusal poisons the bucket
        "conformance/cases/cross-ref-provider-scope/manifests/lines.wasm", // `:scope` composes with the route
        "conformance/cases/cross-ref-provider-duplicate/manifests/lines.wasm", // one name from two sources
        "conformance/cases/cross-ref-provider-overflow/manifests/lines.wasm", // MAX_EXTRACTED_NAMES trip
        // The LLM pack's provider repair flow. Renamed to pair with its
        // own manifest (flat-vendor layout is `<stem>.sjon` next to
        // `<stem>.wasm`), same bytes: staging it here rather than
        // committing a hand-copied twin is what keeps the pack's
        // extractor and the corpus's from ever answering differently.
        "examples/llm/flows/10-cross-ref-provider/manifests/paint.wasm",
    };

    // Example provider — the `uniforms` WGSL extractor
    // (`examples/plugins/uniforms/`), the "real provider" counterpart to
    // the corpus's `lines` fixture: it parses the source instead of
    // splitting it on newlines. Stages as `plugin.wasm` to pair with the
    // example's `plugin.sjon`, the same layout as `double`.
    const uniforms_provider = addWasmExe(b, wasm_target, "uniforms", "examples/plugins/uniforms/uniforms_provider.zig", &.{});

    const stage_uniforms = stageArtifact(b, uniforms_provider, "examples/plugins/uniforms/plugin.wasm");

    const plugin_fixtures_step = b.step(
        "plugin-fixtures",
        "Build executable-plugin .wasm fixtures into examples/plugins/<name>/ and conformance/cases/{plugin-exec,cross-ref-provider}-*/manifests/",
    );
    plugin_fixtures_step.dependOn(&stage_uniforms.step);
    plugin_fixtures_step.dependOn(&stage_double.step);
    plugin_fixtures_step.dependOn(&stage_abi99.step);
    plugin_fixtures_step.dependOn(&stage_import_forbidden.step);
    for (double_dests) |dest| {
        const stage = stageArtifact(b, double_plugin, dest);
        plugin_fixtures_step.dependOn(&stage.step);
    }
    for (lines_dests) |dest| {
        const stage = stageArtifact(b, lines_provider, dest);
        plugin_fixtures_step.dependOn(&stage.step);
    }

    // ---------------------------------------------------------------------
    // Redux-on-SJON web demo (examples/web-todo/).
    //
    // `web-todo-plugin` builds the sidecar wasm (`sum` expr-func) and
    // stages it next to the manifest. `web-todo` additionally stages
    // `sjon.wasm` into the example directory so a static server can serve
    // the whole thing without reaching outside `examples/web-todo/`.
    // ---------------------------------------------------------------------
    const todo_plugin = addWasmExe(b, wasm_target, "todo-plugin", "examples/web-todo/todo-plugin/plugin.zig", &.{});

    const stage_todo_plugin = stageArtifact(b, todo_plugin, "examples/web-todo/todo-plugin.wasm");

    const web_todo_plugin_step = b.step(
        "web-todo-plugin",
        "Build examples/web-todo/todo-plugin.wasm",
    );
    web_todo_plugin_step.dependOn(&stage_todo_plugin.step);

    const stage_web_todo_sjon = stageArtifact(b, wasm, "examples/web-todo/sjon.wasm");

    // Browser-ESM build of the web host (hosts/web/dist/*.js). The browser
    // demos import the `SjonEncoder` / `SjonHost` wrappers, which ship as
    // TypeScript; browsers can't execute `.ts`, so `tsc` strips types and
    // rewrites `./foo.ts` specifiers to `./foo.js` (no bundler). The host's
    // `node:fs` use is a lazy `await import` on the `load`/`_instantiate`
    // path the `loadFromBytes` demos never reach, so the emit is
    // browser-safe. Requires `pnpm install` to have populated node_modules.
    const web_host_browser = b.addSystemCommand(&.{
        "hosts/web/node_modules/.bin/tsc",
        "-p",
        "hosts/web/tsconfig.browser.json",
    });
    const web_host_browser_step = b.step(
        "web-host-browser",
        "Compile the web host to browser ESM in hosts/web/dist/ (needs `tsc` from pnpm install)",
    );
    web_host_browser_step.dependOn(&web_host_browser.step);

    const web_todo_step = b.step(
        "web-todo",
        "Build + stage all artifacts the examples/web-todo/ demo needs",
    );
    web_todo_step.dependOn(&stage_todo_plugin.step);
    web_todo_step.dependOn(&stage_web_todo_sjon.step);
    web_todo_step.dependOn(&install_wasm_binary.step);
    web_todo_step.dependOn(&web_host_browser.step);

    // Canvas demo (examples/web-canvas/) reads `sjon.wasm` straight from
    // `zig-out/bin/` and imports the browser host build; no per-dir
    // staging needed.
    const web_canvas_step = b.step(
        "web-canvas",
        "Build the artifacts the examples/web-canvas/ demo needs",
    );
    web_canvas_step.dependOn(&install_wasm.step);
    web_canvas_step.dependOn(&web_host_browser.step);

    // ---------------------------------------------------------------------
    // Binary IR end-to-end demo (examples/binary-ir-demo.zig).
    //
    // Demonstrates the Binary IR pipeline: parse → toBinary → fromBinary →
    // BinaryCursor walk → canonical print. Wired into `zig build test` so
    // wire-format drift trips here (there is no CI — see the `verify` step).
    // ---------------------------------------------------------------------
    const demo_tool = addSjonTool(b, sjon_mod, target, optimize, "binary-ir-demo", "examples/binary-ir-demo.zig", "demo-binary", "Run the binary-IR end-to-end demo", false);

    // ---------------------------------------------------------------------
    // Reference plugin: `shapes` — minimal but complete plugin example.
    //
    // Builds an executable demoing parse → validate → print → toBinary →
    // cursor walk against a schema composed of `core + shapes`. The same
    // module is also a test target so plugin-side tests run under
    // `zig build test`.
    // ---------------------------------------------------------------------
    const shapes_demo_tool = addSjonTool(b, sjon_mod, target, optimize, "shapes-demo", "examples/plugins/shapes-demo.zig", "shapes-demo", "Run the shapes plugin end-to-end demo", false);

    const union_demo_tool = addSjonTool(b, sjon_mod, target, optimize, "union-demo", "examples/union-demo.zig", "union-demo", "Run the union value-kind demo", false);

    // ---------------------------------------------------------------------
    // Schema-export goldens — exports JSON Schema + TS + IR for `shapes`
    // (static plugin) and `double` (manifest-loaded) into the checked-in
    // `.golden` files. Default run mode compares the freshly-emitted
    // bytes against the goldens and exits non-zero on any diff;
    // `--regen` overwrites the goldens for human review.
    //
    // Wired into `zig build test` so SchemaExport drift trips here
    // (there is no CI). The standalone `zig build export-schema-demo`
    // step is the entry point a human runs after intentional changes.
    // ---------------------------------------------------------------------
    const export_schema_tool = addSjonTool(b, sjon_mod, target, optimize, "export-schema-demo", "examples/export-schema-demo.zig", "export-schema-demo", "Verify schema-export goldens (pass --regen to overwrite)", true);

    // ---------------------------------------------------------------------
    // Meta-schema generator — emits src/MetaSchema.generated.zig from
    // manifests/meta.sjon (the single source of truth). Default run mode
    // byte-compares the committed file against a fresh generation and
    // exits non-zero on drift; `--regen` overwrites it for review.
    //
    // Wired into `zig build test` (below) so editing meta.sjon without
    // regenerating trips here (there is no CI). `zig build gen-meta-schema
    // -- --regen` is the entry point a human runs after an intentional edit.
    // ---------------------------------------------------------------------
    const gen_meta_tool = addSjonTool(b, sjon_mod, target, optimize, "gen-meta-schema", "tools/gen_meta_schema.zig", "gen-meta-schema", "Verify src/MetaSchema.generated.zig matches manifests/meta.sjon (pass --regen to overwrite)", true);

    // ---------------------------------------------------------------------
    // Expr-ops generator — emits hosts/schema/src/expr.gen.ts from the
    // `expr_funcs` table in src/plugins/core.zig (the single source of truth
    // for the typed `e.*` surface). Same drift-check contract as
    // gen-meta-schema: default run byte-compares the committed file,
    // `--regen` overwrites. Wired into `zig build test` (below) so editing
    // the core op table without regenerating trips here (there is no CI).
    // ---------------------------------------------------------------------
    const gen_expr_tool = addSjonTool(b, sjon_mod, target, optimize, "gen-expr-ops", "tools/gen_expr_ops.zig", "gen-expr-ops", "Verify hosts/schema/src/expr.gen.ts matches src/plugins/core.zig expr_funcs (pass --regen to overwrite)", true);

    // ---------------------------------------------------------------------
    // Expected-values sibling generator — emits
    // conformance/cases/<case>/expected.values.json for every value-carrying
    // fixture from its `(values …)` block, encoded through the same
    // `wasm_common.appendValue` the WASM envelope uses. Same drift-check
    // contract as gen-meta-schema: default run byte-compares (and flags a
    // missing sibling for a fixture that gained a values block, or an orphan
    // left after one was removed); `--regen` writes/deletes. Wired into
    // `zig build test` (below) so editing a fixture's values without
    // regenerating trips here (there is no CI).
    // ---------------------------------------------------------------------
    const gen_expected_tool = addSjonTool(b, sjon_mod, target, optimize, "gen-expected-values", "tools/gen_expected_values.zig", "gen-expected-values", "Verify conformance/cases/*/expected.values.json matches each fixture's (values …) block (pass --regen to overwrite)", true);

    // ---------------------------------------------------------------------
    // Diagnostic-explanation catalogue — emits
    // landing-page/src/data/errors.json from src/Explanations.zig, one entry
    // per Ast.Diagnostic.Code in enum-declaration order. The landing page
    // renders a page per code from it, and the LSP's `codeDescription` href
    // points at those pages — so a code whose page is missing is a dead link
    // in every editor. Same drift-check contract as gen-meta-schema: default
    // run byte-compares, `--regen` overwrites. Wired into `zig build test`
    // (below) so editing an explanation without regenerating trips here.
    // ---------------------------------------------------------------------
    const gen_explanations_tool = addSjonTool(b, sjon_mod, target, optimize, "gen-explanations", "tools/gen_explanations.zig", "gen-explanations", "Verify landing-page/src/data/errors.json matches src/Explanations.zig (pass --regen to overwrite)", true);

    // ---------------------------------------------------------------------
    // WASM consumer (Node) — runs node:test against the built artifacts.
    //
    // Separate step (NOT added to `zig build test`) because it depends on
    // a `node` binary. Use `zig build wasm-consumer-test` to run it
    // explicitly. Builds both wasm artifacts first.
    //
    // The host is TypeScript (`node --experimental-strip-types`, ≥ 22.6).
    // Globs (expanded by node's test runner, not the shell) mirror the
    // package.json `test` script so this list never goes stale when a
    // `.test.ts` is added or renamed — the failure mode of the old
    // hard-coded `.mjs` list.
    // ---------------------------------------------------------------------
    const wasm_consumer_test = nodeTest(b, &.{
        "hosts/web/test/*.test.ts",
        "hosts/web/*.test.ts",
    });
    wasm_consumer_test.step.dependOn(&install_wasm.step);
    wasm_consumer_test.step.dependOn(&install_wasm_binary.step);
    // `test/lsp-folding.test.ts` drives the LSP artifact over JSON-RPC.
    wasm_consumer_test.step.dependOn(&install_lsp_wasm.step);
    const wasm_consumer_step = b.step(
        "wasm-consumer-test",
        "Run the Node WASM consumer tests (requires `node` ≥ 22.6 with --experimental-strip-types)",
    );
    wasm_consumer_step.dependOn(&wasm_consumer_test.step);

    // ---------------------------------------------------------------------
    // Landing-page TS unit tests — headless CodeMirror (`EditorState`, no
    // DOM) plus the lesson transforms. Pure TS: no wasm/CLI dependency. node
    // expands the glob itself (same as the package.json `test` script), so
    // this list never goes stale as `.test.ts` files are added anywhere under
    // `landing-page/src/`.
    // ---------------------------------------------------------------------
    const playground_test = nodeTest(b, &.{"landing-page/src/**/*.test.ts"});
    const playground_test_step = b.step(
        "playground-test",
        "Run the landing-page playground TS unit tests (requires `node` ≥ 22.6 with --experimental-strip-types)",
    );
    playground_test_step.dependOn(&playground_test.step);

    // ---------------------------------------------------------------------
    // Landing-page typecheck (`astro check`).
    //
    // `ts_typecheck` scopes to ./hosts/* + ./editors/*, and the playground
    // tests run under `--experimental-strip-types`, which strips types
    // without checking them — so nothing type-checked landing-page at all.
    // Both production outages this repo has had (wasm served as
    // octet-stream; a duplicated CodeMirror) lived exactly here — see
    // landing-page/src/playground/wasm-compile.ts and astro.config.mjs.
    // Runs in seconds and covers the .astro files too.
    // ---------------------------------------------------------------------
    const landing_page_typecheck = b.addSystemCommand(&.{
        "pnpm", "--filter", "landing-page", "run", "typecheck",
    });
    const landing_page_typecheck_step = b.step(
        "landing-page-typecheck",
        "Typecheck the landing page with `astro check`",
    );
    landing_page_typecheck_step.dependOn(&landing_page_typecheck.step);

    // ---------------------------------------------------------------------
    // Curated playground examples — run each entry of the examples registry
    // through the staged `sjon-lsp.wasm` and check it still validates the way
    // it claims to (clean, or provoking exactly the codes it declares).
    //
    // Unlike `playground-test` above this *does* need the wasm, so it depends
    // on the staging step rather than sharing the pure-TS one. Without a gate
    // the examples rot silently: the registry is plain data, so typecheck and
    // the unit tests stay green while the front door fills with `unknown_form`.
    // ---------------------------------------------------------------------
    const check_examples = b.addSystemCommand(&.{
        "node",
        "--experimental-strip-types",
        "landing-page/scripts/check-examples.mjs",
    });
    check_examples.step.dependOn(&stage_landing_page_lsp_wasm.step);
    // …and on the sidecar generator, not just the staging. `gen-lsp-meta`
    // writes `sjon-lsp.meta.json`, whose sha256 pins the staged bytes; it
    // otherwise runs only under `landing-page-assets`, so a verify run
    // restaged the wasm and left the sidecar describing the previous one.
    // Both are gitignored build outputs, so regenerating here is free.
    check_examples.step.dependOn(&gen_lsp_meta.step);
    const check_examples_step = b.step(
        "check-examples",
        "Validate the curated playground examples against the staged LSP wasm",
    );
    check_examples_step.dependOn(&check_examples.step);

    // ---------------------------------------------------------------------
    // Rust second-host (D6) — runs the `hosts/rust/` crate's `cargo test`
    // suite, which wraps `sjon.wasm` through wasmtime and walks the same
    // `conformance/cases/*` corpus the Zig + ts-parity + D5 hosts do.
    //
    // Separate step (NOT added to `zig build test`) because it depends on
    // a `cargo` binary. Use `zig build rust-host-test` to run it.
    // Builds `sjon.wasm` first; `cargo test` reads it from `zig-out/bin/`.
    // ---------------------------------------------------------------------
    const rust_host_test = b.addSystemCommand(&.{
        "cargo",
        "test",
        "--manifest-path",
        "hosts/rust/Cargo.toml",
    });
    rust_host_test.step.dependOn(&install_wasm.step);
    const rust_host_step = b.step(
        "rust-host-test",
        "Run the Rust host crate tests (requires `cargo`)",
    );
    rust_host_step.dependOn(&rust_host_test.step);

    // ---------------------------------------------------------------------
    // SJON CLI binary (`sjon validate FILE`, etc.).
    //
    // Native entry point at `src/cli/main.zig`. Mirrors the LSP shape:
    // thin main + heavy lifting behind library calls. The binary is a
    // scaffold so the layout is real and downstream wiring (install
    // path, step name) is locked in.
    //
    // Declared before `ts-conformance-test` so the latter can depend on
    // `install_cli` — `schema-export-compile.test.ts` invokes the CLI to
    // emit a `.d.ts` it then runs through `tsc --noEmit`.
    // ---------------------------------------------------------------------
    const cli_exe = b.addExecutable(.{
        .name = "sjon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sjon", .module = sjon_mod }},
        }),
    });
    const install_cli = b.addInstallArtifact(cli_exe, .{});
    const cli_step = b.step("cli", "Build the SJON CLI (native)");
    cli_step.dependOn(&install_cli.step);

    // ---------------------------------------------------------------------
    // LLM pack verification — drives the freshly-built CLI over
    // `examples/llm/` and byte-diffs every write→validate→repair golden,
    // the same goldens+gate contract as `export-schema-demo`. Pass
    // `-- --regen` to overwrite goldens, `-- --replay` for transcripts.
    // Folded into `zig build verify` further down.
    // ---------------------------------------------------------------------
    const llm_pack_verify = b.addSystemCommand(&.{ "node", "tools/llm_pack_verify.mjs" });
    llm_pack_verify.step.dependOn(&install_cli.step);
    if (b.args) |fwd| llm_pack_verify.addArgs(fwd);
    const llm_pack_step = b.step(
        "llm-pack-verify",
        "Verify examples/llm goldens, primer budget, and token table (pass -- --regen to overwrite)",
    );
    llm_pack_step.dependOn(&llm_pack_verify.step);

    // ---------------------------------------------------------------------
    // TypeScript second-host conformance — runs the `hosts/typescript-parity`
    // implementation against the same `conformance/cases/*` corpus the
    // Zig validator runs from `src/conformance_tests.zig`.
    //
    // Separate step (NOT added to `zig build test`) because it depends
    // on a `node` binary. Use `zig build ts-conformance-test` to run.
    // ---------------------------------------------------------------------
    const ts_conformance_test = nodeTest(b, &.{
        "hosts/typescript-parity/test/conformance.test.ts",
        "hosts/typescript-parity/test/schemaExport.test.ts",
        "hosts/typescript-parity/test/schema-export-compile.test.ts",
    });
    // The `schema-export-compile` test invokes the Zig CLI to emit a
    // `.d.ts`; depend on `install_cli` so the binary is fresh.
    ts_conformance_test.step.dependOn(&install_cli.step);
    const ts_conformance_step = b.step(
        "ts-conformance-test",
        "Run the TypeScript second-host against the conformance corpus (requires `node` ≥ 22.6 with --experimental-strip-types)",
    );
    ts_conformance_step.dependOn(&ts_conformance_test.step);

    // ---------------------------------------------------------------------
    // LSP server (native + WASM).
    //
    // Native uses lsp-kit's `basic_server` for stdio + JSON-RPC framing;
    // the WASM target rolls its own JSON-RPC dispatcher to avoid pulling
    // in basic_server's stdio code path. Both share `src/lsp/Handler.zig`,
    // which is pure SJON logic (no lsp-kit imports), so the language-aware
    // bits are written once.
    //
    // `lsp_kit` is `.lazy = true` in build.zig.zon — we only resolve it
    // when an LSP step is in the build graph. If the dep isn't fetched
    // yet, skip the wiring (Zig re-invokes build() after the fetch).
    // ---------------------------------------------------------------------
    // Captured out of the lazy block below so `zig build verify` can depend
    // on the native LSP install without forcing the lazy dep when it isn't
    // fetched (stays null → verify simply skips it, same as `lsp-all`).
    var native_lsp_install: ?*std.Build.Step = null;
    if (b.lazyDependency("lsp_kit", .{ .target = target, .optimize = optimize })) |lsp_kit_dep| {
        const lsp_mod = lsp_kit_dep.module("lsp");

        // Handler is lsp-kit-free so the WASM target doesn't drag stdio
        // basic_server bits along. Native and WASM both depend on it.
        // `main.zig` uses the URI helper to convert `rootUri` → workspace
        // path; Handler uses its hash context to key the document map.
        const uri_mod = b.addModule("sjon-lsp-uri", .{
            .root_source_file = b.path("src/lsp/uri.zig"),
            .target = target,
            .optimize = optimize,
        });
        const handler_mod = b.addModule("sjon-lsp-handler", .{
            .root_source_file = b.path("src/lsp/Handler.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sjon", .module = sjon_mod },
                .{ .name = "build_options", .module = build_options_mod },
                .{ .name = "uri", .module = uri_mod },
            },
        });

        // Workspace enumeration — the filesystem half of the seam
        // `Handler.ingestWorkspaceFiles` sits behind. Its own module so
        // the walk's skip/ceiling rules are testable without a server.
        const workspace_scan_mod = b.addModule("sjon-lsp-workspace-scan", .{
            .root_source_file = b.path("src/lsp/workspace_scan.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sjon", .module = sjon_mod },
                .{ .name = "Handler", .module = handler_mod },
                .{ .name = "uri", .module = uri_mod },
            },
        });

        // Incremental-sync splice. Shared with the WASM transport (which
        // imports it by path); std-only, so it takes no imports and each
        // transport supplies its own position→byte converter.
        const text_sync_mod = b.addModule("sjon-lsp-text-sync", .{
            .root_source_file = b.path("src/lsp/text_sync.zig"),
            .target = target,
            .optimize = optimize,
        });

        // Native LSP — stdio + lsp-kit-typed dispatch.
        const lsp_exe = b.addExecutable(.{
            .name = "sjon-lsp",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/lsp/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "sjon", .module = sjon_mod },
                    .{ .name = "lsp", .module = lsp_mod },
                    .{ .name = "Handler", .module = handler_mod },
                    .{ .name = "uri", .module = uri_mod },
                    .{ .name = "workspace_scan", .module = workspace_scan_mod },
                    .{ .name = "text_sync", .module = text_sync_mod },
                },
            }),
        });
        const install_lsp = b.addInstallArtifact(lsp_exe, .{});
        native_lsp_install = &install_lsp.step;
        const lsp_step = b.step("lsp", "Build the SJON LSP (native)");
        lsp_step.dependOn(&install_lsp.step);

        // The WASM LSP target is wired unconditionally above (see
        // `wasm-lsp` step) since it doesn't need lsp-kit. The aggregate
        // `lsp-all` step lives here so it can depend on both.
        const lsp_all_step = b.step("lsp-all", "Build both LSP artifacts");
        lsp_all_step.dependOn(&install_lsp.step);
        lsp_all_step.dependOn(&install_lsp_wasm.step);
    }

    // ---------------------------------------------------------------------
    // Test wiring
    // ---------------------------------------------------------------------
    const test_step = b.step("test", "Run all tests");

    // Coverage wiring — every test binary (and the two demo executables)
    // runs once more under kcov, writing a per-binary report into
    // `zig-out/coverage/<name>/`. The final merge collapses them into
    // `zig-out/coverage/merged/`, and `tools/coverage_summary.sh` prints
    // per-file line% to stdout. `rm -rf zig-out/coverage` runs first so a
    // deleted test can't leave a stale dir that --merge would still pick up.
    const coverage_step = b.step("coverage", "Run all tests under kcov and emit a merged report");
    // kcov creates its leaf output dir but won't make intermediate parents,
    // so wipe and recreate `zig-out/coverage/` in one step before any kcov run.
    const cov_clean = b.addSystemCommand(&.{
        "sh", "-c", "rm -rf zig-out/coverage && mkdir -p zig-out/coverage",
    });
    const cov_merge = b.addSystemCommand(&.{ "kcov", "--merge", "zig-out/coverage/merged" });
    const cov_summary = b.addSystemCommand(&.{ "tools/coverage_summary.sh", "zig-out/coverage/merged/kcov-merged/coverage.json" });
    cov_summary.step.dependOn(&cov_merge.step);
    coverage_step.dependOn(&cov_summary.step);

    // Wasmtime runtime adapter tests (`src/runtimes/wasmtime.zig`). The
    // module links libwasmtime, so we only add it to the test graph when
    // the user opts into executable plugin support — keeps `zig build test`
    // green on systems without a system wasmtime install. PluginRuntime
    // tests (commit 3) and the conformance plugin-exec-* corpus (commit 5)
    // depend on the same library.
    if (plugin_exec) {
        const wasmtime_mod = b.createModule(.{
            .root_source_file = b.path("src/runtimes/wasmtime.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "build_options", .module = build_options_mod },
            },
        });
        linkSystemWasmtime(b, wasmtime_mod);
        const wasmtime_test = b.addTest(.{ .root_module = wasmtime_mod });
        const run_wasmtime_test = b.addRunArtifact(wasmtime_test);
        test_step.dependOn(&run_wasmtime_test.step);
        wrapKcov(b, cov_clean, cov_merge, "wasmtime", wasmtime_test);

        // PluginRuntime exercises the wasmtime wrapper against the
        // checked-in plugin fixtures (`examples/plugins/double/plugin.wasm`
        // + the abi-99 / forbidden-import conformance fixtures). The
        // tests `@embedFile` those bytes at compile time so the binary
        // is self-contained.
        const plugin_runtime_mod = b.createModule(.{
            .root_source_file = b.path("src/PluginRuntime.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "build_options", .module = build_options_mod },
            },
        });
        linkSystemWasmtime(b, plugin_runtime_mod);
        const plugin_runtime_test = b.addTest(.{ .root_module = plugin_runtime_mod });
        const run_plugin_runtime_test = b.addRunArtifact(plugin_runtime_test);
        test_step.dependOn(&run_plugin_runtime_test.step);
        wrapKcov(b, cov_clean, cov_merge, "plugin-runtime", plugin_runtime_test);
    }

    // In-source unit tests (src/root.zig forces discovery of every submodule
    // referenced from root via `comptime { _ = X; }` blocks). The root
    // test compiles the full source tree as its own root module — when
    // plugin_exec is on, it transitively touches the wasmtime wrapper
    // and needs libwasmtime linked + libc enabled.
    const root_test_step = addTestStep(b, test_step, cov_clean, cov_merge, "root", "src/root.zig", target, optimize, &.{
        .{ .name = "build_options", .module = build_options_mod },
    });
    if (plugin_exec) linkSystemWasmtime(b, root_test_step.root_module);

    // Reference-plugin tests + demo regression test.
    _ = addTestStep(
        b,
        test_step,
        cov_clean,
        cov_merge,
        "shapes-plugin",
        "examples/plugins/shapes.zig",
        target,
        optimize,
        &.{.{ .name = "sjon", .module = sjon_mod }},
    );
    _ = addTestStep(
        b,
        test_step,
        cov_clean,
        cov_merge,
        "shapes-demo-tests",
        "examples/plugins/shapes-demo.zig",
        target,
        optimize,
        &.{.{ .name = "sjon", .module = sjon_mod }},
    );

    // The `lines` cross-ref-provider fixture, native halves. `lines-extract`
    // is the extractor itself — dependency-free, because the freestanding
    // wasm fixture (`conformance/fixtures/lines_provider.zig`) compiles it
    // too; `lines-plugin` links it as a native `CrossRefProvider.impl` and
    // drives the same four semantics the executable-tier corpus cases pin
    // through the wasm, so the two routes are compared rather than merely
    // both present.
    _ = addTestStep(
        b,
        test_step,
        cov_clean,
        cov_merge,
        "lines-extract",
        "conformance/fixtures/lines_extract.zig",
        target,
        optimize,
        &.{},
    );
    _ = addTestStep(
        b,
        test_step,
        cov_clean,
        cov_merge,
        "lines-plugin",
        "conformance/fixtures/lines_plugin.zig",
        target,
        optimize,
        &.{.{ .name = "sjon", .module = sjon_mod }},
    );

    // The `uniforms` example provider's scanner tests — dependency-free
    // for the same reason as `lines-extract`: the freestanding wasm root
    // (`uniforms_provider.zig`, built by `plugin-fixtures`) compiles the
    // same scanner file.
    _ = addTestStep(
        b,
        test_step,
        cov_clean,
        cov_merge,
        "uniforms-extract",
        "examples/plugins/uniforms/uniforms_extract.zig",
        target,
        optimize,
        &.{},
    );

    // LSP-side unit tests. Handler is the SJON-aware core (needs `sjon`);
    // offsets is the wasm-only Position helper (freestanding-clean, no
    // imports); uri is the standalone URI decoder (no SJON dep).
    //
    // `uri` is registered here, ahead of every consumer, and outside the
    // `lsp_kit` lazy block: it imports no lsp-kit, so its own tests and its
    // consumers run whether or not that dependency was fetched.
    const lsp_uri_mod = b.addModule("sjon-lsp-uri-native", .{
        .root_source_file = b.path("src/lsp/uri.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = addTestStep(
        b,
        test_step,
        cov_clean,
        cov_merge,
        "lsp-handler",
        "src/lsp/Handler.zig",
        target,
        optimize,
        &.{
            .{ .name = "sjon", .module = sjon_mod },
            .{ .name = "uri", .module = lsp_uri_mod },
            // Not for `Handler.zig` — it reads no build option, on
            // purpose: every capability it branches on is data it can
            // observe at runtime. The tests need it to know whether
            // *this* build can register a wasm provider at all, so the
            // one case that requires a live runtime skips instead of
            // failing on a `-Dplugin-exec=false` build.
            .{ .name = "build_options", .module = build_options_mod },
        },
    );
    _ = addTestStep(
        b,
        test_step,
        cov_clean,
        cov_merge,
        "lsp-offsets",
        "src/lsp/offsets.zig",
        target,
        optimize,
        &.{},
    );
    _ = addTestStep(
        b,
        test_step,
        cov_clean,
        cov_merge,
        "lsp-uri",
        "src/lsp/uri.zig",
        target,
        optimize,
        &.{},
    );
    _ = addTestStep(
        b,
        test_step,
        cov_clean,
        cov_merge,
        "lsp-text-sync",
        "src/lsp/text_sync.zig",
        target,
        optimize,
        &.{},
    );

    // LSP WASM dispatcher — the JSON-RPC wire layer. Ships wasm-only
    // (`std.heap.wasm_allocator`), but `wasm.zig` gates the allocator on
    // the target arch so the dispatch handlers are driveable natively:
    // these tests feed a request in and parse the framed response back
    // out. Handler is compiled as a native module for the import.
    const lsp_handler_native_mod = b.addModule("sjon-lsp-handler-native", .{
        .root_source_file = b.path("src/lsp/Handler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sjon", .module = sjon_mod },
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "uri", .module = lsp_uri_mod },
        },
    });
    _ = addTestStep(
        b,
        test_step,
        cov_clean,
        cov_merge,
        "lsp-wasm-dispatch",
        "src/lsp/wasm.zig",
        target,
        optimize,
        &.{
            .{ .name = "Handler", .module = lsp_handler_native_mod },
            .{ .name = "sjon", .module = sjon_mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    );

    // Workspace enumeration — the native server's filesystem walk.
    _ = addTestStep(
        b,
        test_step,
        cov_clean,
        cov_merge,
        "lsp-workspace-scan",
        "src/lsp/workspace_scan.zig",
        target,
        optimize,
        &.{
            .{ .name = "Handler", .module = lsp_handler_native_mod },
            .{ .name = "sjon", .module = sjon_mod },
            .{ .name = "uri", .module = lsp_uri_mod },
        },
    );

    // CLI in-source tests — drive `Cli.run` directly and assert on the
    // captured stdout/stderr buffers. Reads the conformance fixtures
    // off-disk via `std.testing.io`, so the test runner must be invoked
    // from the repo root (which `zig build test` does).
    const cli_tests = addTestStep(
        b,
        test_step,
        cov_clean,
        cov_merge,
        "cli",
        "src/cli/Cli_tests.zig",
        target,
        optimize,
        &.{
            .{ .name = "sjon", .module = sjon_mod },
            // Same reason as `lsp-handler`: the `uniforms` example tests
            // execute the committed provider wasm, and need to know
            // whether *this* build can run it at all, so they skip
            // instead of failing on a `-Dplugin-exec=false` build.
            .{ .name = "build_options", .module = build_options_mod },
        },
    );
    // The `sjon fmt -` cases spawn the installed binary — the only way
    // to reach the CLI's stdin path, which `Cli.run`'s seam can't
    // substitute. Hanging the dependency on the *compile* step orders
    // the install ahead of the test run (which already depends on the
    // compile); depending from `test_step` instead would let the two
    // race, and the tests would skip against a missing binary.
    cli_tests.step.dependOn(&install_cli.step);

    // Run the binary-IR demo and the shapes demo as part of `zig build test`,
    // and also wrap them in kcov so their end-to-end paths feed the merged
    // coverage report.
    test_step.dependOn(&demo_tool.run.step);
    test_step.dependOn(&shapes_demo_tool.run.step);
    test_step.dependOn(&export_schema_tool.run.step);
    test_step.dependOn(&gen_meta_tool.run.step);
    test_step.dependOn(&gen_expr_tool.run.step);
    test_step.dependOn(&gen_expected_tool.run.step);
    test_step.dependOn(&gen_explanations_tool.run.step);
    wrapKcov(b, cov_clean, cov_merge, "demo-binary-ir", demo_tool.exe);
    wrapKcov(b, cov_clean, cov_merge, "demo-shapes", shapes_demo_tool.exe);
    wrapKcov(b, cov_clean, cov_merge, "demo-export-schema", export_schema_tool.exe);

    // ---------------------------------------------------------------------
    // Fuzz wiring — separate step so `zig build test` stays fast.
    //
    // `zig build fuzz` runs every harness in `src/fuzz.zig` against its
    // baked-in corpus PLUS Smith-generated inputs (with Zig's instrumented
    // fuzzer when available). Each harness asserts only never-panic
    // invariants — they MUST succeed for any byte sequence.
    //
    // The LSP dispatcher harness reaches `src/lsp/wasm.zig`, whose imports
    // are module-named (`Handler`, `sjon`) rather than relative — so they
    // have to be in this module's table too. `sjon` is the same module the
    // LSP handler links, which is why `fuzz.zig` takes the core through
    // `@import("sjon")` and not a second relative copy of `root.zig`.
    // ---------------------------------------------------------------------
    const fuzz_step = b.step("fuzz", "Run never-panic fuzz harnesses");
    const fuzz_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (plugin_exec) true else null,
            .imports = &.{
                .{ .name = "build_options", .module = build_options_mod },
                .{ .name = "sjon", .module = sjon_mod },
                .{ .name = "Handler", .module = lsp_handler_native_mod },
            },
        }),
    });
    if (plugin_exec) linkSystemWasmtime(b, fuzz_test.root_module);
    const run_fuzz = b.addRunArtifact(fuzz_test);
    fuzz_step.dependOn(&run_fuzz.step);

    // ---------------------------------------------------------------------
    // Diagnostic-code coverage audit.
    //
    // Walks every `Ast.Diagnostic.Code` variant and asserts that at
    // least one `test {}` body or `conformance/cases/*/expected.sjon`
    // fixture references it. Prevents new codes from landing without
    // a test, and prevents existing tests from drifting to message-only
    // assertions when a code is removed/renamed.
    // ---------------------------------------------------------------------
    const audit_diagnostics_step = b.step("audit-diagnostics", "Audit Ast.Diagnostic.Code test coverage");
    // The enum-variant list comes from a tiny reflection tool (@typeInfo over
    // Ast.Diagnostic.Code) rather than a text-scrape of Ast.zig — the scrape
    // silently under-counts if the enum block's formatting shifts. Its stdout
    // is captured to a file and passed to the coverage script as $1.
    const emit_diagnostic_codes = b.addExecutable(.{
        .name = "emit-diagnostic-codes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/emit_diagnostic_codes.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sjon", .module = sjon_mod }},
        }),
    });
    const run_emit_codes = b.addRunArtifact(emit_diagnostic_codes);
    const diagnostic_codes_file = run_emit_codes.captureStdOut(.{});
    const audit_diagnostics = b.addSystemCommand(&.{"tools/audit_diagnostic_coverage.sh"});
    audit_diagnostics.addFileArg(diagnostic_codes_file);
    audit_diagnostics_step.dependOn(&audit_diagnostics.step);

    // ---------------------------------------------------------------------
    // Docs-truth audit.
    //
    // Compares the numbers human-facing docs promise (README wire-table
    // version row, DESIGN.md wire-version prose, README/CLAUDE corpus
    // counts) against their live sources of truth (Binary.wire_version,
    // the conformance case count). Dumb by design — numbers, not prose —
    // so the record can't drift behind the code the way it did through
    // the mid-May wire bumps. Wired into `verify` below.
    // ---------------------------------------------------------------------
    const audit_docs_step = b.step("audit-docs", "Audit README/DESIGN/CLAUDE consistency with code truths");
    const audit_docs = b.addSystemCommand(&.{"tools/audit_docs.sh"});
    audit_docs_step.dependOn(&audit_docs.step);

    // ---------------------------------------------------------------------
    // Canonical Zig formatting.
    //
    // `verify` gated everything about this repo except the formatter, so six
    // files had drifted out of canonical form on main without anything
    // noticing — including two of the dedicated test suites. Cheap, total,
    // and it removes "did you run zig fmt" from review entirely.
    //
    // The paths are the whole hand-written Zig surface. `zig fmt` walks
    // directories recursively, so `src` and `tools` need no enumeration;
    // `--check` prints offenders and exits non-zero rather than rewriting.
    // ---------------------------------------------------------------------
    const audit_fmt_step = b.step("audit-fmt", "Check every tracked .zig file is `zig fmt` clean");
    const audit_fmt = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt", "--check", "src", "tools", "build.zig", "build.zig.zon" });
    audit_fmt.setCwd(b.path("."));
    audit_fmt_step.dependOn(&audit_fmt.step);

    // ---------------------------------------------------------------------
    // Format-version reconciler.
    //
    // Machine-compares the version / ABI literals each host spells by hand
    // (plugin ABI, binary wire version + magic bytes, manifest format string,
    // schema-export version) against their in-repo source of truth. A wire or
    // ABI bump always needs behavioral host work, so the constants stay
    // independently spelled and this gate fails loudly on any that drift —
    // rather than a single generated constant silently auto-propagating the
    // number while the host logic lags. Imports the `sjon` module for the
    // compiled truths (Binary/Plugin/SchemaExport); reads PLUGIN_ABI_VERSION as
    // text (PluginRuntime comptime-asserts -Dplugin-exec, so it can't be
    // imported here). Wired into `verify` below; its pure token-extraction
    // helpers carry inline tests, wired into `test` just after.
    // ---------------------------------------------------------------------
    const audit_format_tool = addSjonTool(b, sjon_mod, target, optimize, "audit-format-versions", "tools/audit_format_versions.zig", "audit-format-versions", "Audit host version/ABI literals against their in-repo source of truth", false);
    // The tool's helper unit tests ride `zig build test`.
    _ = addTestStep(
        b,
        test_step,
        cov_clean,
        cov_merge,
        "audit-format-versions",
        "tools/audit_format_versions.zig",
        target,
        optimize,
        &.{.{ .name = "sjon", .module = sjon_mod }},
    );

    // ---------------------------------------------------------------------
    // Read-only-artifact import-closure gate.
    //
    // BFS the column-0 `@import("*.zig")` closure from `src/wasm_binary.zig`
    // and fail if it reaches a write-side / host module (Parser, Printer,
    // Json, Edit, write-side Binary, Host, ManifestLoader, Lowering, root,
    // Lexer, SchemaExport/*). Today only DCE keeps `sjon-binary.wasm` free
    // of that code; this makes the boundary a legible build-time gate that
    // names the offending chain. Pure text scanner — no `sjon` import.
    // Wired into `verify` (the closure gate, via
    // `verify_step.dependOn(audit_wasm_imports_step)` below) and into
    // `test` (its helper unit tests).
    // ---------------------------------------------------------------------
    const audit_wasm_imports = b.addExecutable(.{
        .name = "audit-wasm-imports",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/audit_wasm_imports.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_audit_wasm_imports = b.addRunArtifact(audit_wasm_imports);
    const audit_wasm_imports_step = b.step("audit-wasm-imports", "Audit the sjon-binary.wasm import closure for write-side / host modules");
    audit_wasm_imports_step.dependOn(&run_audit_wasm_imports.step);
    _ = addTestStep(
        b,
        test_step,
        cov_clean,
        cov_merge,
        "audit-wasm-imports",
        "tools/audit_wasm_imports.zig",
        target,
        optimize,
        &.{},
    );

    // ---------------------------------------------------------------------
    // sjon-lsp.wasm zero-imports gate.
    //
    // The artifact's one hard invariant: the playground and gen-lsp-meta
    // instantiate it with `{}`, so any declared import makes it fail to load
    // outright. That was checked only at runtime (by `check-examples`, and by
    // `gen-lsp-meta` which is not in verify), meaning one `wasm_plugin_host`
    // flag mixup shipped with no build-time signal. This reads the linked
    // binary's import section — complementary to `audit-wasm-imports`, which
    // scans source and so cannot see `extern` declarations becoming imports.
    // ---------------------------------------------------------------------
    const audit_lsp_wasm_imports = b.addExecutable(.{
        .name = "audit-lsp-wasm-imports",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/audit_lsp_wasm_imports.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_audit_lsp_wasm_imports = b.addRunArtifact(audit_lsp_wasm_imports);
    run_audit_lsp_wasm_imports.addArg("zig-out/bin/sjon-lsp.wasm");
    run_audit_lsp_wasm_imports.step.dependOn(&install_lsp_wasm.step);
    const audit_lsp_wasm_imports_step = b.step(
        "audit-lsp-wasm-imports",
        "Assert sjon-lsp.wasm declares zero imports (it is instantiated with {})",
    );
    audit_lsp_wasm_imports_step.dependOn(&run_audit_lsp_wasm_imports.step);
    _ = addTestStep(
        b,
        test_step,
        cov_clean,
        cov_merge,
        "audit-lsp-wasm-imports",
        "tools/audit_lsp_wasm_imports.zig",
        target,
        optimize,
        &.{},
    );

    // ---------------------------------------------------------------------
    // Effective-validation axis-diff harness.
    //
    // Walks the conformance corpus and runs each case six times
    // (baseline + per-axis A/B/C/D + all-on), reducing the validator
    // output to sorted `(code, path)` tuples and writing a markdown
    // diff report to `tools/effective-axes-snapshot.md`. Used to track
    // axis-by-axis diagnostic deltas against the production reference.
    // ---------------------------------------------------------------------
    _ = addSjonTool(b, sjon_mod, target, optimize, "effective-axes-harness", "tools/effective_axes_harness.zig", "effective-axes-harness", "Generate tools/effective-axes-snapshot.md from the conformance corpus", false);

    // ---------------------------------------------------------------------
    // Aggregate local gate — `zig build verify`.
    //
    // Runs every gate that matters before a change lands, so targets that
    // aren't on the `test` path (the class that let the native LSP and
    // union-demo bit-rot) can't drift silently again. Local-only; there is
    // no CI. Prerequisites: Zig 0.16, `node` ≥ 22.6, `pnpm install` already
    // run, a `cargo` toolchain with `clippy` + `rustfmt`, libwasmtime (the
    // default `-Dplugin-exec=true` links it — same prereq `test` has), and
    // `bash` (the audit script).
    //
    // Deliberately excludes `coverage` (kcov is slow and orthogonal) and the
    // artifact-regen steps (`plugin-fixtures`, `landing-page-assets`, the
    // `web-todo` staging) — those rewrite checked-in bytes and are run
    // intentionally, not as a pre-commit gate. The granular steps
    // (`wasm-consumer-test`, `ts-conformance-test`, `rust-host-test`, …)
    // stay for targeted runs.
    // ---------------------------------------------------------------------
    const verify_step = b.step(
        "verify",
        "Run every local gate: Zig tests + fuzz + diagnostic audit, all artifact/demo builds, every TS host typecheck/test, biome, and Rust test/clippy/fmt",
    );

    // Zig: unit tests (the gen-meta / gen-expr / schema-export goldens ride
    // inside `test`), fuzz harnesses, and the diagnostic-code audit.
    verify_step.dependOn(test_step);
    verify_step.dependOn(fuzz_step);
    verify_step.dependOn(audit_diagnostics_step);
    verify_step.dependOn(audit_docs_step);
    verify_step.dependOn(audit_fmt_step);
    verify_step.dependOn(audit_format_tool.step);
    verify_step.dependOn(audit_wasm_imports_step);
    verify_step.dependOn(audit_lsp_wasm_imports_step);

    // Artifacts + demos that are NOT on the `test` path — exactly where the
    // LSP and union-demo rot lived. Both WASM artifacts, the WASM LSP, the
    // CLI, the browser-ESM web host emit, and the union demo. The native LSP
    // install is behind the lazy `lsp_kit` dep, reached via the optional
    // captured above (null when the dep isn't fetched).
    verify_step.dependOn(wasm_all_step);
    verify_step.dependOn(lsp_wasm_step);
    verify_step.dependOn(cli_step);
    verify_step.dependOn(llm_pack_step);
    verify_step.dependOn(web_host_browser_step);
    verify_step.dependOn(&union_demo_tool.run.step);
    if (native_lsp_install) |s| verify_step.dependOn(s);

    // TypeScript hosts (schema / web / typescript-parity) plus the editor
    // extensions. `--filter ./hosts/* --filter ./editors/*` scopes to the
    // workspace packages that carry a package.json, skipping landing-page
    // (whose `astro check` is a separate, heavier toolchain) and the Rust
    // crate. typecheck is artifact-free; the host test scripts read the
    // freshly-built WASM + CLI, so those installs are dependencies (the
    // editor extension's tests are data-only, but ride the same step).
    // `pnpm run check` is biome over the whole repo (needs the tsconfig-JSONC
    // override that landed earlier).
    const ts_typecheck = b.addSystemCommand(&.{ "pnpm", "--filter", "./hosts/*", "--filter", "./editors/*", "run", "typecheck" });
    const ts_test = b.addSystemCommand(&.{ "pnpm", "--filter", "./hosts/*", "--filter", "./editors/*", "run", "test" });
    ts_test.step.dependOn(&install_wasm.step);
    ts_test.step.dependOn(&install_wasm_binary.step);
    ts_test.step.dependOn(&install_cli.step);
    // `hosts/web/test/lsp-harness.ts` reads zig-out/bin/sjon-lsp.wasm, so
    // verify needs the same edge the granular `wasm-consumer-test` step has.
    // Without it, LSP changes could test against a stale artifact (a silent
    // false-green) or a missing one on a clean checkout.
    ts_test.step.dependOn(&install_lsp_wasm.step);
    const biome_check = b.addSystemCommand(&.{ "pnpm", "run", "check" });
    verify_step.dependOn(&ts_typecheck.step);
    verify_step.dependOn(&ts_test.step);
    verify_step.dependOn(&biome_check.step);

    // The landing-page playground's headless TS tests (not a `./hosts/*`
    // workspace member, so not covered by `ts_test` above), plus the
    // curated examples' validity check against the staged LSP wasm.
    verify_step.dependOn(playground_test_step);
    verify_step.dependOn(landing_page_typecheck_step);
    verify_step.dependOn(check_examples_step);

    // Rust host: reuse the existing `cargo test` step (it already builds
    // `sjon.wasm` first and reads it at runtime), and add clippy-as-gate +
    // a formatting check. The crate declares its lints `warn`; `-D warnings`
    // promotes them to a hard failure. clippy/fmt are compile-or-parse only
    // (no runtime wasm read), so they need no artifact dep; cargo's
    // target-dir lock serializes them against `cargo test`.
    const rust_clippy = b.addSystemCommand(&.{
        "cargo",           "clippy",
        "--manifest-path", "hosts/rust/Cargo.toml",
        "--all-targets",   "--",
        "-D",              "warnings",
    });
    const rust_fmt = b.addSystemCommand(&.{
        "cargo",           "fmt",
        "--manifest-path", "hosts/rust/Cargo.toml",
        "--check",
    });
    verify_step.dependOn(rust_host_step);
    verify_step.dependOn(&rust_clippy.step);
    verify_step.dependOn(&rust_fmt.step);
}

fn addTestStep(
    b: *std.Build,
    test_step: *std.Build.Step,
    cov_clean: *std.Build.Step.Run,
    cov_merge: *std.Build.Step.Run,
    name: []const u8,
    source: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const std.Build.Module.Import,
) *std.Build.Step.Compile {
    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    const run = b.addRunArtifact(t);
    test_step.dependOn(&run.step);
    wrapKcov(b, cov_clean, cov_merge, name, t);
    return t;
}

/// Build a freestanding wasm32 executable in the shape every SJON WASM
/// artifact shares: `ReleaseSmall`, no libc, `entry = .disabled`,
/// `rdynamic = true` (exported functions survive DCE with no `_start`).
/// Returns the `*Compile` so callers wire installs / staging through it.
fn addWasmExe(
    b: *std.Build,
    wasm_target: std.Build.ResolvedTarget,
    name: []const u8,
    source: []const u8,
    imports: []const std.Build.Module.Import,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .link_libc = false,
            .imports = imports,
        }),
    });
    exe.entry = .disabled;
    exe.rdynamic = true;
    return exe;
}

/// A native `sjon`-importing tool: its executable, the run step that
/// invokes it, and the named build step exposing it. Callers additionally
/// wire `.run` into `test` or `wrapKcov` the `.exe` where a tool also rides
/// `zig build test`.
const SjonTool = struct {
    exe: *std.Build.Step.Compile,
    run: *std.Build.Step.Run,
    step: *std.Build.Step,
};

/// Build a native executable importing the `sjon` module, wrap it in a run
/// step, and expose it under `step_name`. `forward_args` mirrors the
/// `if (b.args) |fwd| run.addArgs(fwd)` the goldens / generators use so
/// `zig build <verb> -- --regen` reaches the tool; leave it false for tools
/// that take no arguments. The shape the demos, `gen-*` generators, and
/// `audit-format-versions` / `effective-axes-harness` all repeat.
fn addSjonTool(
    b: *std.Build,
    sjon_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    source: []const u8,
    step_name: []const u8,
    step_desc: []const u8,
    forward_args: bool,
) SjonTool {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sjon", .module = sjon_mod }},
        }),
    });
    const run = b.addRunArtifact(exe);
    if (forward_args) {
        if (b.args) |fwd| run.addArgs(fwd);
    }
    const step = b.step(step_name, step_desc);
    step.dependOn(&run.step);
    return .{ .exe = exe, .run = run, .step = step };
}

/// Build a `node --test --experimental-strip-types <globs…>` run command —
/// the invocation the three TS host test steps share (node expands the
/// globs itself, matching each package.json `test` script, so the list
/// never goes stale as `.test.ts` files are added). Returns the Run so
/// callers wire artifact deps and the named step.
fn nodeTest(b: *std.Build, globs: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "node", "--test", "--experimental-strip-types" });
    run.addArgs(globs);
    return run;
}

/// Stage a built artifact to a fixed on-disk path via `cp` — the shape
/// the plugin-fixture and landing-page/web-demo staging steps all repeat
/// (`cp <artifact> <dest>`). Returns the run step so callers can wire
/// dependencies through `&stageArtifact(...).step`.
fn stageArtifact(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    dest: []const u8,
) *std.Build.Step.Run {
    const cmd = b.addSystemCommand(&.{"cp"});
    cmd.addArtifactArg(artifact);
    cmd.addArg(dest);
    return cmd;
}

/// Attach libwasmtime to a module — dynamic link, no pkg-config (we
/// shouldn't require an extra build-time tool just to consume a system
/// library). Standard installation prefixes are probed at build time and
/// added only when they exist on disk so contributors on either macOS
/// flavor or Linux don't trip Zig's "unable to open library directory"
/// warning-as-error. If wasmtime isn't installed under any probed
/// prefix, the link step's "library not found" error tells the user to
/// install the package; the message references
/// `docs/zig-discipline.md`'s libwasmtime section.
fn linkSystemWasmtime(b: *std.Build, mod: *std.Build.Module) void {
    mod.linkSystemLibrary("wasmtime", .{
        .use_pkg_config = .no,
        .preferred_link_mode = .dynamic,
    });
    const prefixes = [_][]const u8{
        "/opt/homebrew", // Homebrew on Apple Silicon
        "/usr/local", // Homebrew on Intel macOS + common Linux prefix
    };
    for (prefixes) |prefix| {
        const lib_dir = b.fmt("{s}/lib", .{prefix});
        const inc_dir = b.fmt("{s}/include", .{prefix});
        if (dirExists(lib_dir)) {
            mod.addLibraryPath(.{ .cwd_relative = lib_dir });
        }
        if (dirExists(inc_dir)) {
            mod.addIncludePath(.{ .cwd_relative = inc_dir });
        }
    }
}

/// Returns true if the given absolute path exists on the build host. We
/// use the libc `access(2)` syscall directly because std.Io.Dir's
/// existence checks require an `Io` handle that build scripts don't
/// have lying around. Zig promotes "library directory not found" to a
/// hard error, so adding a non-existent `addLibraryPath` would break
/// the build before the actual library lookup; this check lets us only
/// add prefixes that resolve.
fn dirExists(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const zpath: [*:0]const u8 = @ptrCast(&buf);
    return std.c.access(zpath, 0) == 0;
}

/// Wraps an already-built artifact in a kcov Run that writes per-binary
/// coverage to `zig-out/coverage/<name>/`, ordered after `cov_clean` so a
/// stale directory tree never bleeds into the merge.
fn wrapKcov(
    b: *std.Build,
    cov_clean: *std.Build.Step.Run,
    cov_merge: *std.Build.Step.Run,
    name: []const u8,
    artifact: *std.Build.Step.Compile,
) void {
    const cov_dir = b.fmt("zig-out/coverage/{s}", .{name});
    const cov_run = b.addSystemCommand(&.{ "kcov", "--include-path=src" });
    cov_run.addArg(cov_dir);
    cov_run.addArtifactArg(artifact);
    cov_run.step.dependOn(&cov_clean.step);
    cov_merge.addArg(cov_dir);
    cov_merge.step.dependOn(&cov_run.step);
}
