//! Out-of-memory regression tests for every public entrypoint in `root.zig`.
//!
//! Each test runs the operation under `std.testing.FailingAllocator` in a
//! loop, walking `fail_index` upward until the operation completes without
//! a forced failure. The contract enforced by every iteration:
//!
//!   * If the FailingAllocator induced a failure, the operation MUST return
//!     `error.OutOfMemory` (no panic, no partial success, no leak — the
//!     `std.testing.allocator` underneath catches leaks automatically).
//!   * If no failure was induced, the operation MUST succeed.
//!
//! Convergence is bounded: each loop caps at `MAX_FAIL_INDEX` iterations,
//! returning `error.OomLoopDidNotConverge` if a fn never reaches success.
//! This guards against an OOM path that silently allocates forever.
//!
//! Wired into `zig build test` from `root.zig`'s test block.

const std = @import("std");
const sjon = @import("root.zig");

const Ast = sjon.Ast;
const Parser = sjon.Parser;
const Printer = sjon.Printer;
const Validator = sjon.Validator;
const Expr = sjon.Expr;
const Json = sjon.Json;
const Edit = sjon.Edit;
const Binary = sjon.Binary;
const Schema = sjon.Schema;

const FailingAllocator = std.testing.FailingAllocator;
const testing = std.testing;

/// Hard cap on `fail_index` so a buggy fn that allocates indefinitely
/// surfaces as a clear test failure rather than hanging the suite.
const MAX_FAIL_INDEX: usize = 4096;

/// Source exercising forms, vectors, keyword pairs, comments, strings
/// (escape-quoted and triple-quoted raw), and numbers — broad enough that
/// every public entrypoint touches a non-trivial allocation footprint.
const sample_source: [:0]const u8 =
    \\; leading comment
    \\(scene
    \\  :title "OOM probe"
    \\  :bpm 120
    \\  :date 2026-05-19
    \\  :time 12:34:56.789
    \\  :note """
    \\multi-line
    \\raw payload
    \\"""
    \\  ; child comment
    \\  (canvas :w 320 :h 240 :bg "black"
    \\    [1 2 3]
    \\    (rect :origin [0 0] :size [320 4])))
;

const expr_source: [:0]const u8 = "(+ 1 (* 2 (clamp 5 0 10)))";

const core_schema = Schema.Schema.init(&.{sjon.plugins.core.plugin});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn makeFailing(fail_index: usize) FailingAllocator {
    return FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
}

/// Pre-build a tree with a normal allocator so OOM tests for
/// tree-consuming entrypoints (print, validate, toJson, toBinary, …) do
/// not need to re-parse on every iteration. The tree owns its arena via
/// `testing.allocator`; the caller `defer tree.deinit()`.
fn parseSample() !Ast.Tree {
    return Parser.parse(testing.allocator, sample_source);
}

fn parseExpr() !Ast.Tree {
    return Parser.parse(testing.allocator, expr_source);
}

// ---------------------------------------------------------------------------
// 1. parse
// ---------------------------------------------------------------------------

test "OOM: parse converges and surfaces error.OutOfMemory at every fail point" {
    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.parse(a, sample_source);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var tree = try result;
            tree.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 2. print
// ---------------------------------------------------------------------------

test "OOM: print converges over a pre-built tree" {
    var tree = try parseSample();
    defer tree.deinit();

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.print(a, tree, .{});
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            const out = try result;
            out.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 3. validate
// ---------------------------------------------------------------------------

test "OOM: validate converges over a pre-built tree" {
    var tree = try parseSample();
    defer tree.deinit();

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.validate(a, tree, core_schema);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            r.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 4. evalExpr
// ---------------------------------------------------------------------------

test "OOM: evalExpr converges over a single expression node" {
    var tree = try parseExpr();
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    const env: Expr.Env = .{};

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.evalExpr(a, tree, tree.root[0], &env, core_schema);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            r.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 5. toJson
// ---------------------------------------------------------------------------

test "OOM: toJson converges over a single-root tree" {
    var tree = try Parser.parse(testing.allocator, "(scene :title \"x\")");
    defer tree.deinit();

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.toJson(a, tree, .{ .schema = core_schema });
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            r.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 6. fromJson
// ---------------------------------------------------------------------------

test "OOM: fromJson converges over a pre-parsed JSON value" {
    // Build a JSON value once outside the loop so the fail counter only
    // measures allocations inside `fromJson`.
    const json_text = "{\"$form\":\"scene\",\"$children\":[1,2,3]}";
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_text, .{});
    defer parsed.deinit();

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.fromJson(a, parsed.value, .{});
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var t = try result;
            t.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 7. toJsonRoots
// ---------------------------------------------------------------------------

test "OOM: toJsonRoots converges over a multi-root tree" {
    var tree = try Parser.parse(testing.allocator, "(a) (b) (c :k 1)");
    defer tree.deinit();

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.toJsonRoots(a, tree, .{ .schema = core_schema });
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            r.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 8. fromJsonRoots
// ---------------------------------------------------------------------------

test "OOM: fromJsonRoots converges over a $roots wrapper" {
    const json_text =
        \\{"$roots":[{"$form":"a"},{"$form":"b","$children":[1]}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_text, .{});
    defer parsed.deinit();

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.fromJsonRoots(a, parsed.value, .{});
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var t = try result;
            t.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 9. toBinary
// ---------------------------------------------------------------------------

test "OOM: toBinary converges over a pre-built tree" {
    var tree = try parseSample();
    defer tree.deinit();

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.toBinary(a, tree, .{});
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            const out = try result;
            out.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 10. fromBinary
// ---------------------------------------------------------------------------

test "OOM: fromBinary converges over a pre-encoded buffer" {
    var tree = try parseSample();
    defer tree.deinit();
    const bin = try Binary.toBinary(testing.allocator, tree, .{});
    defer bin.deinit();

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.fromBinary(a, bin.data, .{});
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var t = try result;
            t.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 11. validateBinary
// ---------------------------------------------------------------------------

test "OOM: validateBinary converges over a pre-encoded buffer" {
    var tree = try parseSample();
    defer tree.deinit();
    const bin = try Binary.toBinary(testing.allocator, tree, .{});
    defer bin.deinit();

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.validateBinary(a, bin.data, core_schema);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            r.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 12. validate — slot-type mismatch path (covers the matcher's
//                MatchFail allocation + emitTypeMismatch buffer growth)
// ---------------------------------------------------------------------------

const slot_typing_source: [:0]const u8 = "(box [1 \"oops\" 3])";

const slot_typing_plugin: sjon.Plugin.Plugin = .{
    .name = "demo",
    .forms = &.{
        .{ .name = "box", .positional = .{ .kind = .{ .name = "vec3" } } },
    },
    .value_kinds = &.{
        .{
            .name = "vec3",
            .underlying = .vector,
            .vector = .{ .len = 3, .element = .{ .name = "number" } },
        },
    },
};

test "OOM: validate exercising slot-type mismatch (element_at failure) converges" {
    var tree = try Parser.parse(testing.allocator, slot_typing_source);
    defer tree.deinit();
    const slot_typing_schema = Schema.Schema.init(&.{slot_typing_plugin});

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.validate(a, tree, slot_typing_schema);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            defer r.deinit();
            try testing.expect(r.hasErrors());
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 12. evalExprBinary
// ---------------------------------------------------------------------------

test "OOM: evalExprBinary converges over a single-root expression buffer" {
    var tree = try parseExpr();
    defer tree.deinit();
    const bin = try Binary.toBinary(testing.allocator, tree, .{});
    defer bin.deinit();
    const env: Expr.Env = .{};

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.evalExprBinary(a, bin.data, &env, core_schema);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            r.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 13. applyEdit
// ---------------------------------------------------------------------------

test "OOM: applyEdit converges over a structural edit action" {
    // Path `[]` targets the root form itself; `path:[0]` would descend into
    // the first positional child, which doesn't exist on a keyword-only form.
    const action_json =
        \\{"op":"set_keyword","path":[],"key":"title","value":"new"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, action_json, .{});
    defer parsed.deinit();

    const edit_source: [:0]const u8 = "(scene :title \"old\")";

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.applyEdit(a, edit_source, parsed.value, .{});
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            const out = try result;
            out.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 14. Unit-suffixed numbers — every public entrypoint that touches the
// new `Tag.number_with_unit` / `$num` paths must converge under OOM
// pressure. Source includes a unit-bearing positional, KP value, and
// vector element so the lexer / parser / printer / binary / JSON paths
// all hit the new code.
// ---------------------------------------------------------------------------

const unit_source: [:0]const u8 =
    \\(thing :angle 90deg :delay 250ms
    \\  [4b 50% 0.5em])
;

test "OOM: parse converges on unit-bearing source" {
    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();
        const result = sjon.parse(a, unit_source);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var tree = try result;
            tree.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

test "OOM: toBinary converges on unit-bearing tree" {
    var tree = try Parser.parse(testing.allocator, unit_source);
    defer tree.deinit();
    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();
        const result = sjon.toBinary(a, tree, .{});
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            const out = try result;
            out.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

test "OOM: fromBinary converges on unit-bearing buffer" {
    var tree = try Parser.parse(testing.allocator, unit_source);
    defer tree.deinit();
    const bin = try Binary.toBinary(testing.allocator, tree, .{});
    defer bin.deinit();
    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();
        const result = sjon.fromBinary(a, bin.data, .{});
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var t = try result;
            t.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

test "OOM: toJson converges on unit-bearing tree" {
    var tree = try Parser.parse(testing.allocator, unit_source);
    defer tree.deinit();
    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();
        const result = sjon.toJson(a, tree, .{});
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            r.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

test "OOM: fromJson converges on $num-bearing JSON value" {
    const json_text =
        \\{"$form":"thing","angle":{"$num":[90,"deg"]},"delay":{"$num":[250,"ms"]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_text, .{});
    defer parsed.deinit();
    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();
        const result = sjon.fromJson(a, parsed.value, .{});
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var t = try result;
            t.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

test "OOM: print converges on unit-bearing tree" {
    var tree = try Parser.parse(testing.allocator, unit_source);
    defer tree.deinit();
    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();
        const result = sjon.print(a, tree, .{});
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            const out = try result;
            out.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 15. validate — required-key check (covers the missing-keyword emit path
//                added when `KeySpec.optional = false` was activated).
// ---------------------------------------------------------------------------

const required_key_plugin: sjon.Plugin.Plugin = .{
    .name = "demo",
    .forms = &.{
        .{
            .name = "scene",
            .keys = &.{
                .{ .name = "bpm", .value_type = .number, .optional = false },
                .{ .name = "name", .value_type = .string, .optional = false },
            },
        },
    },
};

test "OOM: validate exercising required-key emit converges" {
    var tree = try Parser.parse(testing.allocator, "(scene)");
    defer tree.deinit();
    const required_schema = Schema.Schema.init(&.{required_key_plugin});

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.validate(a, tree, required_schema);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            defer r.deinit();
            try testing.expect(r.hasErrors());
            try testing.expectEqual(@as(usize, 2), r.diagnostics.len);
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 16. ManifestLoader — bound-load happy path (numeric-bounds with unit
//     literal, exercises `loadBound`'s string `a.dupe` allocation plus
//     the consistency-check `std.fmt.allocPrint` paths).
// ---------------------------------------------------------------------------

const bounds_manifest_source: [:0]const u8 =
    \\(plugin :name p :version "1.0.0"
    \\  (form :name delay
    \\    (key :name wait :type duration :optional false))
    \\  (value-kind :name duration :underlying number
    \\    :unit (unit-shape :required true :allowed [ms])
    \\    :numeric (numeric-bounds :min 0ms :max 10000ms :exclusive-max true)))
;

test "OOM: ManifestLoader.load on a (numeric-bounds …) manifest converges" {
    var tree = try Parser.parse(testing.allocator, bounds_manifest_source);
    defer tree.deinit();

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.ManifestLoader.load(a, tree);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            defer r.deinit();
            try testing.expect(!r.hasErrors());
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 17. ManifestLoader — bound-load invalid path (exercises every
//     `numeric_bounds_invalid` allocPrint message + buildPath alloc).
// ---------------------------------------------------------------------------

const bounds_invalid_manifest_source: [:0]const u8 =
    \\(plugin :name p :version "1.0.0"
    \\  (value-kind :name bad :underlying string
    \\    :numeric (numeric-bounds :min 1 :max 0 :exclusive-min true :exclusive-max true)))
;

test "OOM: ManifestLoader.load on an invalid (numeric-bounds …) manifest converges" {
    var tree = try Parser.parse(testing.allocator, bounds_invalid_manifest_source);
    defer tree.deinit();

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.ManifestLoader.load(a, tree);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            defer r.deinit();
            try testing.expect(r.hasErrors());
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 17b. ManifestLoader — slot-local forms happy path (exercises buildKey's
//      recursion into buildForm, the local_forms toOwnedSlice, and the
//      nested key duplication of name strings).
// ---------------------------------------------------------------------------

const local_form_manifest_source: [:0]const u8 =
    \\(plugin :name ui :version "1.0.0"
    \\  (form :name canvas
    \\    (key :name shape :type form
    \\      (form :name circle (key :name r :type number :optional false))
    \\      (form :name rect (key :name w :type number :optional false)))))
;

test "OOM: ManifestLoader.load on a slot-local-forms manifest converges" {
    var tree = try Parser.parse(testing.allocator, local_form_manifest_source);
    defer tree.deinit();

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.ManifestLoader.load(a, tree);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            defer r.deinit();
            try testing.expect(!r.hasErrors());
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 17c. ManifestLoader — slot-local invalid path (duplicate local-form name),
//      exercising the new `invalid_manifest` allocPrint + buildPath emit.
// ---------------------------------------------------------------------------

const local_form_invalid_manifest_source: [:0]const u8 =
    \\(plugin :name ui :version "1.0.0"
    \\  (form :name canvas
    \\    (key :name shape :type form
    \\      (form :name circle (key :name r :type number :optional false))
    \\      (form :name circle (key :name r :type number :optional false)))))
;

test "OOM: ManifestLoader.load on an invalid slot-local manifest converges" {
    var tree = try Parser.parse(testing.allocator, local_form_invalid_manifest_source);
    defer tree.deinit();

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.ManifestLoader.load(a, tree);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            defer r.deinit();
            try testing.expect(r.hasErrors());
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 18. validate — numeric-bounds violation, exercising the
//     `number_below_min` emit path with its formatted message.
// ---------------------------------------------------------------------------

const numeric_bounds_plugin: sjon.Plugin.Plugin = .{
    .name = "demo",
    .forms = &.{
        .{ .name = "set", .keys = &.{.{ .name = "v", .value_type = .{ .named = .{ .name = "opacity" } } }} },
    },
    .value_kinds = &.{
        .{
            .name = "opacity",
            .underlying = .number,
            .numeric = .{
                .min = .{ .value = 0, .exact_int = true },
                .max = .{ .value = 1, .exact_int = true },
            },
        },
    },
};

test "OOM: validate exercising number_above_max emit converges" {
    var tree = try Parser.parse(testing.allocator, "(set :v 1.5)");
    defer tree.deinit();
    const schema = Schema.Schema.init(&.{numeric_bounds_plugin});

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.validate(a, tree, schema);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            defer r.deinit();
            try testing.expect(r.hasErrors());
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 19. validateBinary — numeric-bounds violation through the binary cursor,
//     ensuring the bound message path through `matchKindBinary` also OOM-
//     converges.
// ---------------------------------------------------------------------------

test "OOM: validateBinary exercising number_above_max emit converges" {
    var tree = try Parser.parse(testing.allocator, "(set :v 1.5)");
    defer tree.deinit();
    const bin = try Binary.toBinary(testing.allocator, tree, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{numeric_bounds_plugin});

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.validateBinary(a, bin.data, schema);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            defer r.deinit();
            try testing.expect(r.hasErrors());
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 20. Lockfile.parse — exercises every allocation path the lockfile parser
//     takes (project-hash dupe, generated-at dupe, sjon-version dupe, each
//     locked entry's six string dupes). The arena hand-off pattern we
//     fixed mid-implementation makes this an especially good regression
//     target — a leak there would only surface under OOM stress.
// ---------------------------------------------------------------------------

const lockfile_sample: [:0]const u8 =
    \\(lockfile :version 1
    \\          :project-hash "sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    \\          :generated-at "2026-05-24T00:00:00Z"
    \\          :sjon-version "0.1.0"
    \\          :plugins
    \\          [(locked :name shapes
    \\                   :version "1.0.0"
    \\                   :path "./vendor/shapes.sjon"
    \\                   :manifest-hash "sha256-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    \\                   :wasm-hash "sha256-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    \\                   :resolved-from project-plugins)
    \\           (locked :name audio
    \\                   :version "0.4.2"
    \\                   :path "./vendor/audio.sjon"
    \\                   :manifest-hash "sha256-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    \\                   :resolved-from search-roots)])
;

test "OOM: Lockfile.parse converges with no leaks" {
    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.Lockfile.parse(a, lockfile_sample);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            defer r.deinit();
            try testing.expectEqual(@as(usize, 2), r.plugins.len);
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 21. Lockfile.write — exercises buffer growth + per-entry rendering on
//     a sample with two plugins. Catches a regression where the writer's
//     buffer growth stops mid-output and silently truncates.
// ---------------------------------------------------------------------------

test "OOM: Lockfile.write converges" {
    // `Lockfile.write` takes `arena: Allocator` — the caller is
    // expected to supply an arena that mops up allocations on
    // failure. To exercise the failure path without leaking, we
    // layer the FailingAllocator under an ArenaAllocator and
    // deinit the arena every iteration.
    const entries = [_]sjon.Lockfile.LockedEntry{
        .{
            .name = "alpha",
            .version = "1.0.0",
            .path = "./alpha.sjon",
            .manifest_hash = "sha256-0000000000000000000000000000000000000000000000000000000000000000",
        },
        .{
            .name = "beta",
            .version = "2.0.0",
            .path = "./beta.sjon",
            .manifest_hash = "sha256-1111111111111111111111111111111111111111111111111111111111111111",
            .wasm_hash = "sha256-2222222222222222222222222222222222222222222222222222222222222222",
        },
    };
    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        var arena = std.heap.ArenaAllocator.init(failing.allocator());
        defer arena.deinit();

        const lf: sjon.Lockfile.Lockfile = .{
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .version = 1,
            .plugins = &entries,
        };
        // lf.arena is unused inside `write` — entries are literals.
        // We don't `defer lf.arena.deinit()` because the arena
        // hasn't allocated anything.
        const result = sjon.Lockfile.write(arena.allocator(), lf);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            const bytes = try result;
            // Just spot-check structure; the round-trip test in
            // Lockfile.zig covers correctness.
            try testing.expect(std.mem.indexOf(u8, bytes, "(lockfile") != null);
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 22. Lockfile.hashBytes — small but worth confirming it doesn't trip
//     the convergence loop on a degenerate empty input.
// ---------------------------------------------------------------------------

test "OOM: Lockfile.hashBytes converges on empty input" {
    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        var arena = std.heap.ArenaAllocator.init(failing.allocator());
        defer arena.deinit();

        const result = sjon.Lockfile.hashBytes(arena.allocator(), "");
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            _ = try result;
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 23. Lowering.runLoweringPass — converges on a nested-lowerable document,
//     stressing the lint's emitDiag allocations and the errdefer cleanup.
// ---------------------------------------------------------------------------

/// Schema for the lowering OOM test: `outer` and `inner` both lowerable (the
/// nested-lowerable contradiction) plus their identity `<head>-normal`
/// terminals. A const — no allocation — so the failing allocator drives only
/// the pass, never schema setup.
const lowering_oom_plugin = sjon.Plugin.Plugin{
    .name = "tp",
    .forms = &.{
        .{ .name = "outer", .open = true, .lowering = .{ .hook = "test/identity-v1", .produces = &.{"outer-normal"} } },
        .{ .name = "inner", .open = true, .lowering = .{ .hook = "test/identity-v1", .produces = &.{"inner-normal"} } },
        .{ .name = "outer-normal", .open = true },
        .{ .name = "inner-normal", .open = true },
    },
};

test "OOM: runLoweringPass converges on a nested-lowerable document" {
    // `(outer (inner))` — both lowerable, so the pass emits a
    // lowering_nested_lowerable on `inner`. Pre-build the tree, schema, and
    // registry with the normal allocator; the failing allocator drives only the
    // pass, where the lint's emitDiag allocations (message allocPrint, path
    // alloc, per-part dupe) and the `errdefer diags.deinit(gpa)` cleanup live.
    var tree = try Parser.parse(testing.allocator, "(outer (inner))");
    defer tree.deinit();

    const schema = Schema.Schema.init(&.{lowering_oom_plugin});
    const overlay = sjon.MaterializedDefaults.MaterializedDefaults{};

    var registry: sjon.Lowering.LoweringRegistry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, sjon.Lowering_test_hooks.test_identity_v1);

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        // Arena and gpa both ride the failing allocator, so every allocation in
        // the pass — invocations (arena) and diagnostics (gpa) — is a candidate
        // trip point. The arena is reclaimed wholesale each iteration.
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();

        const result = sjon.Lowering.runLoweringPass(a, arena.allocator(), &tree, tree.root, schema, &overlay, &registry, .{});
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var pr = try result;
            pr.deinit(a);
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 24. Lowering.runLoweringPassWithEnv — converges evaluating a host-env
//     expression slot, stressing `numberEval`'s `Expr.eval` result-arena
//     allocations inside the pass on top of invocation/diagnostic allocs.
// ---------------------------------------------------------------------------

/// Schema for the env-eval lowering OOM test: a `(thing :count <number>)` sugar
/// form lowering via `test/eval-env-v1` to `(descriptor …)`. A const — no
/// allocation — so the failing allocator drives only the pass. Core is added
/// in-test (it owns `*`, which the author expression uses).
const eval_env_oom_plugin = sjon.Plugin.Plugin{
    .name = "tp",
    .forms = &.{
        .{
            .name = "thing",
            .keys = &.{.{ .name = "count", .value_type = .number, .optional = true }},
            .lowering = .{ .hook = "test/eval-env-v1", .produces = &.{"descriptor"} },
        },
        .{ .name = "descriptor", .open = true },
    },
};

test "OOM: runLoweringPassWithEnv converges evaluating a host-env expression slot" {
    // `(thing :count (* workgroup-size 1))` with a populated env binding
    // `workgroup-size = 16`. The hook reads `:count` via `numberEval`, which
    // runs `Expr.eval` against the env — so every induced failure also probes
    // the evaluator's result-arena allocations, not just the pass machinery.
    var tree = try Parser.parse(testing.allocator, "(thing :count (* workgroup-size 1))");
    defer tree.deinit();

    const schema = Schema.Schema.init(&.{ sjon.plugins.core.plugin, eval_env_oom_plugin });
    const overlay = sjon.MaterializedDefaults.MaterializedDefaults{};

    var registry: sjon.Lowering.LoweringRegistry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, sjon.Lowering_test_hooks.test_eval_env_v1);

    const bindings = [_]Expr.Env.Binding{.{ .name = "workgroup-size", .value = .{ .number = 16 } }};
    const env: Expr.Env = .{ .bindings = &bindings };

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();

        const result = sjon.Lowering.runLoweringPassWithEnv(a, arena.allocator(), &tree, tree.root, schema, &overlay, &registry, .{}, &env);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var pr = try result;
            pr.deinit(a);
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 25. Host.validateDocument — the inline-manifest constructor. Nothing is
//     pre-built (it parses + partitions + loads + validates internally), so
//     the failing allocator drives the entire three-phase pipeline. Default
//     options mean no resolver / io / plugin_exec runtime, so allocation is a
//     deterministic function of the source and the loop converges.
// ---------------------------------------------------------------------------

const host_doc_source: [:0]const u8 =
    \\(plugin :name p :version "1.0.0"
    \\  (form :name box
    \\    (key :name w :type number :optional false)
    \\    (key :name label :type string :optional true)))
    \\(box :w 5 :label "hi")
;

test "OOM: Host.validateDocument converges over an inline-plugin document" {
    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.Host.validateDocument(a, host_doc_source, .{});
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var hr = try result;
            hr.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 26. PatternQuery.queryTree / queryBinary — compile a parsed (or encoded)
//     pattern and query a fixed window. The tree / binary buffer are pre-built
//     with the normal allocator; the failing allocator drives compile + query
//     (node arena, hap emission, diagnostic alloc). A small bounded combinator
//     pattern trips none of the resource axes, so an induced failure is always
//     `OutOfMemory` — never `DepthExceeded` / `HapBudgetExceeded` / a
//     `BinaryCursor` rejection (the pre-built bytes are always valid).
// ---------------------------------------------------------------------------

const pattern_oom_schema = Schema.Schema.init(&.{ sjon.plugins.core.plugin, sjon.plugins.pattern.plugin });
const pattern_oom_window: sjon.Pattern.Span = .{ .begin = 0, .end = 4 * sjon.Pattern.PPC };
const pattern_oom_source: [:0]const u8 = "(stack (fast 2 [bd sn]) (slow 3 hh))";

test "OOM: PatternQuery.queryTree converges over a combinator pattern" {
    var tree = try Parser.parse(testing.allocator, pattern_oom_source);
    defer tree.deinit();

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.PatternQuery.queryTree(a, &tree, tree.root[0], pattern_oom_schema, pattern_oom_window, 0);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            r.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

test "OOM: PatternQuery.queryBinary converges over an encoded combinator pattern" {
    var tree = try Parser.parse(testing.allocator, pattern_oom_source);
    defer tree.deinit();
    var bin = try Binary.toBinary(testing.allocator, tree, .{});
    defer bin.deinit();

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.PatternQuery.queryBinary(a, bin.data, pattern_oom_schema, pattern_oom_window, 0);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            r.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 27. SchemaExport.exportSchema — lower a small static schema into the IR and
//     emit both backends (JSON Schema + TS `.d.ts`). The plugin is a `const`
//     (no allocation), and only it is exported (core would balloon the
//     allocation count past MAX_FAIL_INDEX), so the failing allocator drives
//     just the exporter: IR nodes, both byte buffers, and the warning stream.
// ---------------------------------------------------------------------------

const export_oom_plugin = sjon.Plugin.Plugin{
    .name = "xp",
    .version = "1.0.0",
    .forms = &.{
        .{
            .name = "box",
            .keys = &.{
                .{ .name = "w", .value_type = .number, .optional = false },
                .{ .name = "label", .value_type = .string, .optional = true },
            },
        },
    },
};

test "OOM: SchemaExport.exportSchema converges over a small schema" {
    const schema = Schema.Schema.init(&.{export_oom_plugin});

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.SchemaExport.exportSchema(a, schema, .{});
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            r.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 28. applyEditToTree — the tree-consuming edit sibling of `applyEdit`
//     (test 13). The source tree and the action JSON are pre-built with the
//     normal allocator, so the failing allocator drives only the functional
//     rebuild: `cloneNode` over the unchanged subtrees, the transform at the
//     edit path, and the edited tree's own diagnostic deep-copy.
// ---------------------------------------------------------------------------

test "OOM: applyEditToTree converges over a structural edit on a pre-built tree" {
    var src_tree = try Parser.parse(testing.allocator, "(scene :title \"old\")");
    defer src_tree.deinit();

    const action_json =
        \\{"op":"set_keyword","path":[],"key":"title","value":"new"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, action_json, .{});
    defer parsed.deinit();

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.applyEditToTree(a, &src_tree, parsed.value);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var t = try result;
            t.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 29. loadProject — default options supply no `project_root` / `io`, so the
//     FilesystemResolver branch is skipped and the loader takes the core-only
//     path (one seeded plugin, no diagnostics). The failing allocator drives
//     the arena bring-up plus the plugins-slice construction; convergence is
//     quick, but the leak check still guards the arena hand-off.
// ---------------------------------------------------------------------------

test "OOM: loadProject converges over the core-only (no project root) path" {
    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.loadProject(a, .{});
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            defer r.deinit();
            try testing.expectEqual(@as(usize, 1), r.plugins.len); // core only
            try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 30. exportSchemaFromSource — the source-driven schema exporter. Nothing is
//     pre-built: the failing allocator drives `validateDocument`'s full prep
//     pipeline plus `SchemaExport.exportSchema` (both backend byte buffers
//     and the warning stream). The `errdefer host_result.deinit()` guarding
//     the export half is exactly the two-arena hand-off an OOM sweep is here
//     to prove leak-free.
// ---------------------------------------------------------------------------

test "OOM: exportSchemaFromSource converges over an inline-plugin document" {
    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.Host.exportSchemaFromSource(a, host_doc_source, .{}, .{});
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var bundle = try result;
            bundle.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 31. Host.evalExpr — the single-expression host entrypoint. Nothing is
//     pre-built: the failing allocator drives the whole prep pipeline plus
//     `Expr.evalWithRuntime` and the value deep-copy into the result's
//     gpa-backed `value_arena`.
//
//     The source is chosen for a broad allocation footprint: the
//     `:license "…"` warning keeps `diags` non-empty while staying non-err,
//     so eval still runs and produces an *allocating* vector value in
//     `value_arena` — exercising the prep → eval → deep-copy chain plus the
//     two-arena (prep + value) hand-off, which the arithmetic `(+ 1 2)`
//     shape does not (a number value leaves `value_arena` empty).
// ---------------------------------------------------------------------------

const eval_value_arena_source: [:0]const u8 =
    \\(plugin :name p :version "1.0.0" :license "bogus-license"
    \\  (form :name w :open true))
    \\[1 2 3]
;

test "OOM: Host.evalExpr converges producing a value alongside a warning diagnostic" {
    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.Host.evalExpr(a, eval_value_arena_source, .{});
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            defer r.deinit();
            // Eval ran (the lone diagnostic is the license warning, not an
            // error) and produced the vector value it deep-copied.
            try testing.expect(!r.hasErrors());
            const v = r.value orelse return error.TestNoValue;
            try testing.expect(v == .vector);
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 32. Host.preloadSchema — the two-phase schema constructor. Nothing is
//     pre-built: the failing allocator drives the whole preload pipeline —
//     parse each manifest source, `ManifestLoader.load` each into its own
//     arena, freeze the plugin / plugin_results / diagnostics slices into the
//     shared arena, then run the five aggregate validators over the loaded
//     set. A `dangler` manifest whose cross-ref target resolves to no form
//     keeps the aggregate phase allocating (it emits
//     `unknown_cross_ref_target`) alongside the manifest phase, so an induced
//     failure is always `OutOfMemory` and the leak check guards every arena.
// ---------------------------------------------------------------------------

const preload_oom_sources = [_][:0]const u8{
    // Loads cleanly, but `:target ghost` dangles → aggregate-phase diagnostic.
    \\(plugin :name dangler :version "1.0.0"
    \\  (value-kind :name ref-kind
    \\    :underlying symbol
    \\    :cross-ref (cross-ref :target ghost)))
    ,
    "(plugin :name bystander :version \"1.0.0\")",
};

test "OOM: Host.preloadSchema converges over a multi-source manifest set" {
    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.Host.preloadSchema(a, &preload_oom_sources);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var pre = try result;
            pre.deinit();
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 32b. Schema.validateCrossRefs — the scratch-arena aggregate-validator
//      envelope under OOM, driven DIRECTLY on the failing allocator (not just
//      transitively via preloadSchema above). A dangling `:target_form ghost`
//      forces the diagnostic-allocating path, so the final
//      `dupeAggregateDiagnostics` copy-out — slice, each message, each path
//      segment — is individually OOM-gated. This pins the scratch-arena +
//      dupe envelope shared by all five aggregate validators, protecting the
//      `runInScratch` extraction (B.11).
// ---------------------------------------------------------------------------

const cross_ref_oom_plugin: sjon.Plugin.Plugin = .{
    .name = "dangler",
    .value_kinds = &.{
        .{ .name = "ref-kind", .underlying = .symbol, .cross_ref = .{ .target_form = "ghost" } },
    },
};

test "OOM: Schema.validateCrossRefs converges over a dangling cross-ref" {
    const schema = Schema.Schema.init(&.{cross_ref_oom_plugin});
    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = schema.validateCrossRefs(a);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            const diags = try result;
            // Clean run: the dangling target produced diagnostics owned by
            // `a`; free the full ownership (slice + message + path segments)
            // so the leak-checked allocator underneath stays balanced.
            try testing.expect(diags.len >= 1);
            for (diags) |d| {
                a.free(d.message);
                for (d.path) |seg| a.free(seg);
                a.free(d.path);
            }
            a.free(diags);
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 33. Host.preloadSchema → Host.validateDocument — the borrow contract under
//     OOM. The `PreloadedSchema` is built ONCE with the leak-checked normal
//     allocator and lives across the whole loop; only the per-document
//     `validateDocument` call runs on the failing allocator. This tortures the
//     borrow: an induced failure mid-validate must return `OutOfMemory`
//     without freeing (or leaving a dangling reference into) the preloaded
//     arenas, and `HostResult.deinit` must never touch them (its
//     `plugin_results` stays document-only). If the borrow reached the
//     validator, the clean `(box …)` resolves against the preloaded `box`
//     form with no errors — proving the preloaded plugins were actually
//     consulted, not silently dropped.
// ---------------------------------------------------------------------------

const preload_borrow_source: [:0]const u8 =
    \\(plugin :name p :version "1.0.0"
    \\  (form :name box
    \\    (key :name w :type number :optional false)
    \\    (key :name label :type string :optional true)))
;
const preload_borrow_doc: [:0]const u8 = "(box :w 5 :label \"hi\")";

test "OOM: preloadSchema handle survives validateDocument failing on the doc" {
    // Built with the leak-checked allocator, stable for every iteration.
    var pre = try sjon.Host.preloadSchema(testing.allocator, &.{preload_borrow_source});
    defer pre.deinit();
    try testing.expect(!pre.hasErrors());

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        const result = sjon.Host.validateDocument(a, preload_borrow_doc, .{ .preloaded = &pre });
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var hr = try result;
            defer hr.deinit();
            // The preloaded borrow reached the validator: `box` resolved.
            try testing.expect(!hr.hasErrors());
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 34. MaterializedDefaults.materializeDefaults — the gpa-owned diagnostic
//     path under partial OOM.
//
// `oom_tests` reached the materializer only through empty-overlay literals
// before this. The interesting allocations are the ones `Result.deinit`
// promises to free: a `default_eval_failed` diagnostic's message, its
// three-element path array, and each duped part. Those had no `errdefer`
// coverage — `errdefer diags.deinit(gpa)` released the list backing and
// leaked everything inside it, while `Lowering`'s identical path had been
// hardened. An induced failure between the message allocation and the
// append, or between two path dupes, leaked; `testing.allocator`'s leak
// check is what turns that into a test failure.
// ---------------------------------------------------------------------------

/// `:fps` is an expression default that always fails to evaluate (`nope` is
/// a declared expr-func with no `:impl`), so every iteration reaches
/// `emitFailure`. `:title` is a literal default, so the arena-side entry
/// path runs in the same call.
const materialize_oom_manifest: [:0]const u8 =
    \\(plugin :name p :version "1.0.0"
    \\  (expr-func :name nope :arity (fixed 0) :result number)
    \\  (form :name scene
    \\    (key :name fps :type number :default (nope))
    \\    (key :name title :type string :default "untitled")))
;

test "OOM: materializeDefaults converges through its gpa-owned diagnostic path" {
    // Manifest → Plugin with the leak-checked allocator, stable across the
    // whole loop; the failing allocator drives only the materializer.
    var mtree = try Parser.parse(testing.allocator, materialize_oom_manifest);
    defer mtree.deinit();
    var loaded = try sjon.ManifestLoader.load(testing.allocator, mtree);
    defer loaded.deinit();
    try testing.expect(!loaded.hasErrors());

    const plugins = [_]sjon.Plugin.Plugin{ sjon.plugins.core.plugin, loaded.plugin };
    const schema = Schema.Schema.init(&plugins);

    var doc = try Parser.parse(testing.allocator, "(scene)");
    defer doc.deinit();

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();

        // Both allocators ride the failing one: the arena carries the
        // entries, `a` carries the diagnostics.
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();

        const result = sjon.MaterializedDefaults.materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var r = try result;
            defer r.deinit(a);
            // Non-vacuous on both halves: the failing default emitted its
            // diagnostic, the literal default produced its entry.
            try testing.expect(r.diagnostics.len >= 1);
            try testing.expect(r.materialized.entries.len >= 1);
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

// ---------------------------------------------------------------------------
// 35. EffectiveDocument.render — the splice path under OOM.
//
// `render` is arena-only (its whole error set is `OutOfMemory`), so the
// leak surface is the arena itself; what this pins is that a failure part
// way through the insertion list unwinds as `OutOfMemory` rather than
// returning a half-spliced document. Two omitted defaults on two roots so
// the sort and the back-to-front insertion both run.
// ---------------------------------------------------------------------------

const effective_oom_manifest: [:0]const u8 =
    \\(plugin :name p :version "1.0.0"
    \\  (form :name scene
    \\    (key :name fps :type number :default 60)
    \\    (key :name title :type string :default "untitled")))
;
const effective_oom_source: [:0]const u8 = "(scene)\n(scene :fps 30)";

test "OOM: EffectiveDocument.render converges splicing defaults into source" {
    var mtree = try Parser.parse(testing.allocator, effective_oom_manifest);
    defer mtree.deinit();
    var loaded = try sjon.ManifestLoader.load(testing.allocator, mtree);
    defer loaded.deinit();
    try testing.expect(!loaded.hasErrors());

    const plugins = [_]sjon.Plugin.Plugin{ sjon.plugins.core.plugin, loaded.plugin };
    const schema = Schema.Schema.init(&plugins);

    var doc = try Parser.parse(testing.allocator, effective_oom_source);
    defer doc.deinit();

    // Overlay built once with the leak-checked allocator — the failing
    // allocator drives only `render`.
    var overlay_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer overlay_arena.deinit();
    var mat = try sjon.MaterializedDefaults.materializeDefaults(
        testing.allocator,
        overlay_arena.allocator(),
        &doc,
        doc.root,
        schema,
    );
    defer mat.deinit(testing.allocator);
    try testing.expect(mat.materialized.entries.len >= 2);

    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = makeFailing(fail_index);
        const a = failing.allocator();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();

        const result = sjon.EffectiveDocument.render(
            arena.allocator(),
            effective_oom_source,
            &doc,
            &mat.materialized,
            &schema,
        );
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            const text = try result;
            // Non-vacuous: both defaults were actually spliced in.
            try testing.expect(std.mem.indexOf(u8, text, ":title") != null);
            try testing.expect(std.mem.indexOf(u8, text, ":fps 60") != null);
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}
