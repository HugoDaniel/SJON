const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.zig_version.major != 0 or builtin.zig_version.minor < 16) {
        @compileError("sjon requires Zig 0.16.x or newer");
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const target_is_wasm32 = target.result.cpu.arch == .wasm32;
    const plugin_exec_opt = b.option(
        bool,
        "plugin-exec",
        "Enable executable WASM plugin support on native (links libwasmtime). Forced off on wasm32 targets. Default: true.",
    );
    const plugin_exec = if (target_is_wasm32) false else (plugin_exec_opt orelse true);

    const sjon_build_options = b.addOptions();
    sjon_build_options.addOption(bool, "plugin_exec", plugin_exec);
    const build_options_mod = sjon_build_options.createModule();

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

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm = b.addExecutable(.{
        .name = "sjon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .link_libc = false,
            .imports = &.{
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;

    const install_wasm = b.addInstallArtifact(wasm, .{});
    const wasm_step = b.step("wasm", "Build WASM binary");
    wasm_step.dependOn(&install_wasm.step);

    const wasm_binary = b.addExecutable(.{
        .name = "sjon-binary",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_binary.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .link_libc = false,
            .imports = &.{
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    wasm_binary.entry = .disabled;
    wasm_binary.rdynamic = true;

    const install_wasm_binary = b.addInstallArtifact(wasm_binary, .{});
    const wasm_binary_step = b.step("wasm-binary", "Build read-only sjon-binary.wasm");
    wasm_binary_step.dependOn(&install_wasm_binary.step);

    const wasm_all_step = b.step("wasm-all", "Build both WASM artifacts");
    wasm_all_step.dependOn(&install_wasm.step);
    wasm_all_step.dependOn(&install_wasm_binary.step);

    const sjon_wasm_lsp_mod = b.addModule("sjon-wasm-lsp", .{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .link_libc = false,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
        },
    });
    const handler_wasm_mod = b.addModule("sjon-lsp-handler-wasm", .{
        .root_source_file = b.path("src/lsp/Handler.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .link_libc = false,
        .imports = &.{
            .{ .name = "sjon", .module = sjon_wasm_lsp_mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });
    const lsp_wasm = b.addExecutable(.{
        .name = "sjon-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lsp/wasm.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .link_libc = false,
            .imports = &.{
                .{ .name = "Handler", .module = handler_wasm_mod },
                .{ .name = "sjon", .module = sjon_wasm_lsp_mod },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    lsp_wasm.entry = .disabled;
    lsp_wasm.rdynamic = true;

    const install_lsp_wasm = b.addInstallArtifact(lsp_wasm, .{});
    const lsp_wasm_step = b.step("lsp-wasm", "Build the SJON LSP (WASM)");
    lsp_wasm_step.dependOn(&install_lsp_wasm.step);

    const stage_landing_page_lsp_wasm = b.addSystemCommand(&.{"cp"});
    stage_landing_page_lsp_wasm.addArtifactArg(lsp_wasm);
    stage_landing_page_lsp_wasm.addArg("landing-page/public/sjon-lsp.wasm");

    const landing_page_assets_step = b.step(
        "landing-page-assets",
        "Stage WASM artifacts into landing-page/public/",
    );
    landing_page_assets_step.dependOn(&stage_landing_page_lsp_wasm.step);

    const double_plugin = b.addExecutable(.{
        .name = "double",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/plugins/double/double.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .link_libc = false,
        }),
    });
    double_plugin.entry = .disabled;
    double_plugin.rdynamic = true;

    const stage_double = b.addSystemCommand(&.{"cp"});
    stage_double.addArtifactArg(double_plugin);
    stage_double.addArg("examples/plugins/double/plugin.wasm");

    const abi99_plugin = b.addExecutable(.{
        .name = "abi-99",
        .root_module = b.createModule(.{
            .root_source_file = b.path("conformance/fixtures/abi-99.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .link_libc = false,
        }),
    });
    abi99_plugin.entry = .disabled;
    abi99_plugin.rdynamic = true;

    const stage_abi99 = b.addSystemCommand(&.{"cp"});
    stage_abi99.addArtifactArg(abi99_plugin);
    stage_abi99.addArg("conformance/cases/plugin-exec-abi-mismatch/manifests/shapes.wasm");

    const import_forbidden_plugin = b.addExecutable(.{
        .name = "import-forbidden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("conformance/fixtures/import_forbidden.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .link_libc = false,
        }),
    });
    import_forbidden_plugin.entry = .disabled;
    import_forbidden_plugin.rdynamic = true;

    const stage_import_forbidden = b.addSystemCommand(&.{"cp"});
    stage_import_forbidden.addArtifactArg(import_forbidden_plugin);
    stage_import_forbidden.addArg(
        "conformance/cases/plugin-exec-import-forbidden/manifests/forbidden.wasm",
    );

    const stage_double_export_missing = b.addSystemCommand(&.{"cp"});
    stage_double_export_missing.addArtifactArg(double_plugin);
    stage_double_export_missing
        .addArg("conformance/cases/plugin-exec-export-missing/manifests/double.wasm");

    const stage_double_trap = b.addSystemCommand(&.{"cp"});
    stage_double_trap.addArtifactArg(double_plugin);
    stage_double_trap.addArg("conformance/cases/plugin-exec-trap/manifests/double.wasm");

    const stage_double_eval = b.addSystemCommand(&.{"cp"});
    stage_double_eval.addArtifactArg(double_plugin);
    stage_double_eval.addArg("conformance/cases/plugin-exec-double-eval/manifests/double.wasm");

    const stage_double_func_failed = b.addSystemCommand(&.{"cp"});
    stage_double_func_failed.addArtifactArg(double_plugin);
    stage_double_func_failed
        .addArg("conformance/cases/plugin-exec-func-failed/manifests/double.wasm");

    const stage_double_alloc_failed = b.addSystemCommand(&.{"cp"});
    stage_double_alloc_failed.addArtifactArg(double_plugin);
    stage_double_alloc_failed
        .addArg("conformance/cases/plugin-exec-alloc-failed/manifests/double.wasm");

    const stage_double_result_type = b.addSystemCommand(&.{"cp"});
    stage_double_result_type.addArtifactArg(double_plugin);
    stage_double_result_type
        .addArg("conformance/cases/plugin-exec-result-type/manifests/double.wasm");

    const stage_double_keyword_roundtrip = b.addSystemCommand(&.{"cp"});
    stage_double_keyword_roundtrip.addArtifactArg(double_plugin);
    stage_double_keyword_roundtrip
        .addArg("conformance/cases/plugin-exec-keyword-roundtrip/manifests/double.wasm");

    const stage_double_vector_roundtrip = b.addSystemCommand(&.{"cp"});
    stage_double_vector_roundtrip.addArtifactArg(double_plugin);
    stage_double_vector_roundtrip
        .addArg("conformance/cases/plugin-exec-vector-roundtrip/manifests/double.wasm");

    const stage_double_large_vector = b.addSystemCommand(&.{"cp"});
    stage_double_large_vector.addArtifactArg(double_plugin);
    stage_double_large_vector
        .addArg("conformance/cases/plugin-exec-large-vector/manifests/double.wasm");

    const stage_double_arity_violation = b.addSystemCommand(&.{"cp"});
    stage_double_arity_violation.addArtifactArg(double_plugin);
    stage_double_arity_violation
        .addArg("conformance/cases/plugin-exec-arity-violation/manifests/double.wasm");

    const stage_double_form_roundtrip = b.addSystemCommand(&.{"cp"});
    stage_double_form_roundtrip.addArtifactArg(double_plugin);
    stage_double_form_roundtrip
        .addArg("conformance/cases/plugin-exec-form-roundtrip/manifests/double.wasm");

    const stage_double_hash_mismatch = b.addSystemCommand(&.{"cp"});
    stage_double_hash_mismatch.addArtifactArg(double_plugin);
    stage_double_hash_mismatch
        .addArg("conformance/cases/use-plugin-hash-mismatch/manifests/double.wasm");

    const plugin_fixtures_step = b.step(
        "plugin-fixtures",
        "Build executable-plugin .wasm fixtures into examples/plugins/<name>/ and conformance/cases/plugin-exec-*/manifests/",
    );
    plugin_fixtures_step.dependOn(&stage_double.step);
    plugin_fixtures_step.dependOn(&stage_abi99.step);
    plugin_fixtures_step.dependOn(&stage_import_forbidden.step);
    plugin_fixtures_step.dependOn(&stage_double_export_missing.step);
    plugin_fixtures_step.dependOn(&stage_double_trap.step);
    plugin_fixtures_step.dependOn(&stage_double_eval.step);
    plugin_fixtures_step.dependOn(&stage_double_func_failed.step);
    plugin_fixtures_step.dependOn(&stage_double_alloc_failed.step);
    plugin_fixtures_step.dependOn(&stage_double_result_type.step);
    plugin_fixtures_step.dependOn(&stage_double_keyword_roundtrip.step);
    plugin_fixtures_step.dependOn(&stage_double_vector_roundtrip.step);
    plugin_fixtures_step.dependOn(&stage_double_large_vector.step);
    plugin_fixtures_step.dependOn(&stage_double_arity_violation.step);
    plugin_fixtures_step.dependOn(&stage_double_form_roundtrip.step);
    plugin_fixtures_step.dependOn(&stage_double_hash_mismatch.step);

    const todo_plugin = b.addExecutable(.{
        .name = "todo-plugin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/web-todo/todo-plugin/plugin.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .link_libc = false,
        }),
    });
    todo_plugin.entry = .disabled;
    todo_plugin.rdynamic = true;

    const stage_todo_plugin = b.addSystemCommand(&.{"cp"});
    stage_todo_plugin.addArtifactArg(todo_plugin);
    stage_todo_plugin.addArg("examples/web-todo/todo-plugin.wasm");

    const web_todo_plugin_step = b.step(
        "web-todo-plugin",
        "Build examples/web-todo/todo-plugin.wasm",
    );
    web_todo_plugin_step.dependOn(&stage_todo_plugin.step);

    const stage_web_todo_sjon = b.addSystemCommand(&.{"cp"});
    stage_web_todo_sjon.addArtifactArg(wasm);
    stage_web_todo_sjon.addArg("examples/web-todo/sjon.wasm");

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

    const web_canvas_step = b.step(
        "web-canvas",
        "Build the artifacts the examples/web-canvas/ demo needs",
    );
    web_canvas_step.dependOn(&install_wasm.step);
    web_canvas_step.dependOn(&web_host_browser.step);

    const demo = b.addExecutable(.{
        .name = "binary-ir-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/binary-ir-demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sjon", .module = sjon_mod }},
        }),
    });
    const run_demo = b.addRunArtifact(demo);
    const demo_step = b.step("demo-binary", "Run the binary-IR end-to-end demo");
    demo_step.dependOn(&run_demo.step);

    const shapes_demo = b.addExecutable(.{
        .name = "shapes-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/plugins/shapes-demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sjon", .module = sjon_mod }},
        }),
    });
    const run_shapes_demo = b.addRunArtifact(shapes_demo);
    const shapes_demo_step = b.step("shapes-demo", "Run the shapes plugin end-to-end demo");
    shapes_demo_step.dependOn(&run_shapes_demo.step);

    const union_demo = b.addExecutable(.{
        .name = "union-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/union-demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sjon", .module = sjon_mod }},
        }),
    });
    const run_union_demo = b.addRunArtifact(union_demo);
    const union_demo_step = b.step("union-demo", "Run the union value-kind demo");
    union_demo_step.dependOn(&run_union_demo.step);

    const export_schema_demo = b.addExecutable(.{
        .name = "export-schema-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/export-schema-demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sjon", .module = sjon_mod }},
        }),
    });
    const run_export_schema_demo = b.addRunArtifact(export_schema_demo);
    if (b.args) |fwd| run_export_schema_demo.addArgs(fwd);
    const export_schema_demo_step = b.step("export-schema-demo", "Verify schema-export goldens (pass --regen to overwrite)");
    export_schema_demo_step.dependOn(&run_export_schema_demo.step);

    const gen_meta_schema = b.addExecutable(.{
        .name = "gen-meta-schema",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_meta_schema.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sjon", .module = sjon_mod }},
        }),
    });
    const run_gen_meta_schema = b.addRunArtifact(gen_meta_schema);
    if (b.args) |fwd| run_gen_meta_schema.addArgs(fwd);
    const gen_meta_schema_step = b.step("gen-meta-schema", "Verify src/MetaSchema.generated.zig matches manifests/meta.sjon (pass --regen to overwrite)");
    gen_meta_schema_step.dependOn(&run_gen_meta_schema.step);

    const gen_expr_ops = b.addExecutable(.{
        .name = "gen-expr-ops",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_expr_ops.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sjon", .module = sjon_mod }},
        }),
    });
    const run_gen_expr_ops = b.addRunArtifact(gen_expr_ops);
    if (b.args) |fwd| run_gen_expr_ops.addArgs(fwd);
    const gen_expr_ops_step = b.step("gen-expr-ops", "Verify hosts/schema/src/expr.gen.ts matches src/plugins/core.zig expr_funcs (pass --regen to overwrite)");
    gen_expr_ops_step.dependOn(&run_gen_expr_ops.step);

    const wasm_consumer_test = b.addSystemCommand(&.{
        "node",
        "--test",
        "--experimental-strip-types",
        "hosts/web/test/*.test.ts",
        "hosts/web/*.test.ts",
    });
    wasm_consumer_test.step.dependOn(&install_wasm.step);
    wasm_consumer_test.step.dependOn(&install_wasm_binary.step);
    const wasm_consumer_step = b.step(
        "wasm-consumer-test",
        "Run the Node WASM consumer tests (requires `node` ≥ 22.6 with --experimental-strip-types)",
    );
    wasm_consumer_step.dependOn(&wasm_consumer_test.step);

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

    const ts_conformance_test = b.addSystemCommand(&.{
        "node",
        "--test",
        "--experimental-strip-types",
        "hosts/typescript-parity/test/conformance.test.ts",
        "hosts/typescript-parity/test/schemaExport.test.ts",
        "hosts/typescript-parity/test/schema-export-compile.test.ts",
    });
    ts_conformance_test.step.dependOn(&install_cli.step);
    const ts_conformance_step = b.step(
        "ts-conformance-test",
        "Run the TypeScript second-host against the conformance corpus (requires `node` ≥ 22.6 with --experimental-strip-types)",
    );
    ts_conformance_step.dependOn(&ts_conformance_test.step);

    var native_lsp_install: ?*std.Build.Step = null;
    if (b.lazyDependency("lsp_kit", .{ .target = target, .optimize = optimize })) |lsp_kit_dep| {
        const lsp_mod = lsp_kit_dep.module("lsp");

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
            },
        });

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
                },
            }),
        });
        const install_lsp = b.addInstallArtifact(lsp_exe, .{});
        native_lsp_install = &install_lsp.step;
        const lsp_step = b.step("lsp", "Build the SJON LSP (native)");
        lsp_step.dependOn(&install_lsp.step);

        const lsp_all_step = b.step("lsp-all", "Build both LSP artifacts");
        lsp_all_step.dependOn(&install_lsp.step);
        lsp_all_step.dependOn(&install_lsp_wasm.step);
    }

    const test_step = b.step("test", "Run all tests");

    const coverage_step = b.step("coverage", "Run all tests under kcov and emit a merged report");
    const cov_clean = b.addSystemCommand(&.{
        "sh", "-c", "rm -rf zig-out/coverage && mkdir -p zig-out/coverage",
    });
    const cov_merge = b.addSystemCommand(&.{ "kcov", "--merge", "zig-out/coverage/merged" });
    const cov_summary = b.addSystemCommand(&.{ "tools/coverage_summary.sh", "zig-out/coverage/merged/kcov-merged/coverage.json" });
    cov_summary.step.dependOn(&cov_merge.step);
    coverage_step.dependOn(&cov_summary.step);

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

    const root_test_step = addTestStep(b, test_step, cov_clean, cov_merge, "root", "src/root.zig", target, optimize, &.{
        .{ .name = "build_options", .module = build_options_mod },
    });
    if (plugin_exec) linkSystemWasmtime(b, root_test_step.root_module);

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
        "cli",
        "src/cli/Cli_tests.zig",
        target,
        optimize,
        &.{.{ .name = "sjon", .module = sjon_mod }},
    );

    test_step.dependOn(&run_demo.step);
    test_step.dependOn(&run_shapes_demo.step);
    test_step.dependOn(&run_export_schema_demo.step);
    test_step.dependOn(&run_gen_meta_schema.step);
    test_step.dependOn(&run_gen_expr_ops.step);
    wrapKcov(b, cov_clean, cov_merge, "demo-binary-ir", demo);
    wrapKcov(b, cov_clean, cov_merge, "demo-shapes", shapes_demo);
    wrapKcov(b, cov_clean, cov_merge, "demo-export-schema", export_schema_demo);

    const fuzz_step = b.step("fuzz", "Run never-panic fuzz harnesses");
    const fuzz_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (plugin_exec) true else null,
            .imports = &.{
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    if (plugin_exec) linkSystemWasmtime(b, fuzz_test.root_module);
    const run_fuzz = b.addRunArtifact(fuzz_test);
    fuzz_step.dependOn(&run_fuzz.step);

    const audit_diagnostics_step = b.step("audit-diagnostics", "Audit Ast.Diagnostic.Code test coverage");
    const audit_diagnostics = b.addSystemCommand(&.{"tools/audit_diagnostic_coverage.sh"});
    audit_diagnostics_step.dependOn(&audit_diagnostics.step);

    const axes_harness = b.addExecutable(.{
        .name = "effective-axes-harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/effective_axes_harness.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sjon", .module = sjon_mod }},
        }),
    });
    const run_axes_harness = b.addRunArtifact(axes_harness);
    const axes_harness_step = b.step(
        "effective-axes-harness",
        "Generate tools/effective-axes-snapshot.md from the conformance corpus",
    );
    axes_harness_step.dependOn(&run_axes_harness.step);

    const verify_step = b.step(
        "verify",
        "Run every local gate: Zig tests + fuzz + diagnostic audit, all artifact/demo builds, every TS host typecheck/test, biome, and Rust test/clippy/fmt",
    );

    verify_step.dependOn(test_step);
    verify_step.dependOn(fuzz_step);
    verify_step.dependOn(audit_diagnostics_step);

    verify_step.dependOn(wasm_all_step);
    verify_step.dependOn(lsp_wasm_step);
    verify_step.dependOn(cli_step);
    verify_step.dependOn(web_host_browser_step);
    verify_step.dependOn(&run_union_demo.step);
    if (native_lsp_install) |s| verify_step.dependOn(s);

    const ts_typecheck = b.addSystemCommand(&.{ "pnpm", "--filter", "./hosts/*", "run", "typecheck" });
    const ts_test = b.addSystemCommand(&.{ "pnpm", "--filter", "./hosts/*", "run", "test" });
    ts_test.step.dependOn(&install_wasm.step);
    ts_test.step.dependOn(&install_wasm_binary.step);
    ts_test.step.dependOn(&install_cli.step);
    const biome_check = b.addSystemCommand(&.{ "pnpm", "run", "check" });
    verify_step.dependOn(&ts_typecheck.step);
    verify_step.dependOn(&ts_test.step);
    verify_step.dependOn(&biome_check.step);

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

fn linkSystemWasmtime(b: *std.Build, mod: *std.Build.Module) void {
    mod.linkSystemLibrary("wasmtime", .{
        .use_pkg_config = .no,
        .preferred_link_mode = .dynamic,
    });
    const prefixes = [_][]const u8{
        "/opt/homebrew",
        "/usr/local",
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

fn dirExists(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const zpath: [*:0]const u8 = @ptrCast(&buf);
    return std.c.access(zpath, 0) == 0;
}

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
