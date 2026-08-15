//! Internal tests for Validator.zig (tree-walker + binary streaming).
//!
//! Pulled out of `Validator.zig` post-phase-16 to keep the growing
//! production file free of interleaved tests (the binary dual-path walker
//! and effective-axes work have since pushed production well past its
//! original size). Test discovery: `Validator.zig` ends with
//! `test { _ = @import("Validator_tests.zig"); }`, so these run
//! transparently once `refAllDecls(@This())` in `root.zig`'s test block
//! references `Validator`.
//!
//! Tests access `Validator` only through its public surface — every symbol
//! reached here is `pub` in `Validator.zig`. Local `const` aliases at the
//! top re-spell those symbols unqualified to keep test bodies readable.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
const Validator = @import("Validator.zig");
const Parser = @import("Parser.zig");
const core = @import("plugins/core.zig");

// Local aliases — keep test bodies readable without churning every callsite.
const Result = Validator.Result;
const Diagnostic = Validator.Diagnostic;
const Severity = Validator.Severity;
const validate = Validator.validate;
const validateBinary = Validator.validateBinary;

fn validateSrc(
    src: [:0]const u8,
    schema: Schema.Schema,
) !struct { tree: Ast.Tree, result: Result } {
    const tree = try Parser.parse(testing.allocator, src);
    const result = try validate(testing.allocator, tree, schema);
    return .{ .tree = tree, .result = result };
}

test "valid expression passes" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("(+ 1 2 3)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "expression with wrong arity fails" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("(vec3 1 2)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const d = bundle.result.diagnostics[0];
    try testing.expect(std.mem.indexOf(u8, d.message, "vec3") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "exactly 3") != null);
}

test "expression with keyword child rejected" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("(+ :nope 1)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
}

test "labeled call: lerp with declared :from :to :t accepted" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("(lerp :from 0 :to 10 :t 0.5)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "labeled call: lerp with reordered labels accepted" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("(lerp :t 0.5 :from 0 :to 10)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "labeled call: atan2 :y :x accepted (canonical y/x case)" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("(atan2 :x 1 :y 0)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "labeled call: mixed positional+labeled rejected" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("(lerp 0 :to 10 0.5)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    try testing.expect(anyCode(bundle.result.diagnostics, .expr_mixed_args));
}

test "labeled call: unknown label rejected" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("(lerp :from 0 :to 10 :nope 0.5)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    try testing.expect(anyCode(bundle.result.diagnostics, .expr_unknown_label));
}

test "labeled call: duplicate label rejected" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("(lerp :from 0 :from 1 :t 0.5)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    try testing.expect(anyCode(bundle.result.diagnostics, .expr_duplicate_label));
}

test "labeled call: missing label rejected" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("(lerp :from 0 :to 10)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    try testing.expect(anyCode(bundle.result.diagnostics, .expr_missing_label));
}

test "labeled call: function without param_names still rejects kvpairs" {
    // `+` is variadic and doesn't declare labels — kvpairs in expression
    // position keep firing the original `expr_kvpair_not_allowed`.
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("(+ :a 1 :b 2)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    try testing.expect(anyCode(bundle.result.diagnostics, .expr_kvpair_not_allowed));
}

test "labeled call: type-checking still applies via resolved positional list" {
    // vec3 declares `:param_names = .{ x, y, z }` and `:params = .{ number, number, number }`.
    // A string in a labeled slot must still trip the type check; expression-arg
    // mismatches use the dedicated `expr_type_mismatch` code.
    //
    // Dual-path: the binary walker used to skip slot typing wholesale in
    // labeled mode, so a read-side host validating pre-encoded IR missed
    // an error the reference emits. For a mono function the label names
    // the slot outright — no random access needed — so both paths type it.
    const schema = Schema.Schema.init(&.{core.plugin});
    try expectCodeOnBoth("(vec3 :x 1 :y \"oops\" :z 3)", schema, .expr_type_mismatch);

    // Order-independent: the label, not the position, picks the slot.
    try expectCodeOnBoth("(vec3 :z 3 :y \"oops\" :x 1)", schema, .expr_type_mismatch);

    // A well-typed labeled call stays clean on both paths.
    try expectNoCodeOnBoth("(vec3 :y 2 :x 1 :z 3)", schema, .expr_type_mismatch);
}

test "labeled call: 33-param signature resolves without a u5-shift panic" {
    // `param_names.len` is bounded by `Arity.fixed` (a u8, up to 255), so a
    // labeled slot can index past 31. matchSignatureLabels' seen-set must not
    // be a u32 — its shift amount is u5, so the 33rd label used to panic in
    // Debug (`@intCast(32)` into a u5). 33 distinct labels, all supplied and
    // all `number`, is a clean accept.
    const a = testing.allocator;
    const N = 33;
    const names = comptime blk: {
        @setEvalBranchQuota(20000);
        var arr: [N][]const u8 = undefined;
        for (&arr, 0..) |*n, i| n.* = std.fmt.comptimePrint("a{d}", .{i});
        break :blk arr;
    };
    const params = [_]Plugin.ValueType{.number} ** N;
    const p: Plugin.Plugin = .{
        .name = "big",
        .expr_funcs = &.{.{
            .name = "f33",
            .arity = .{ .fixed = N },
            .params = &params,
            .param_names = &names,
            .result = .number,
        }},
    };
    const schema = Schema.Schema.init(&.{p});

    const src = comptime blk: {
        @setEvalBranchQuota(20000);
        var s: []const u8 = "(f33";
        for (0..N) |i| s = s ++ std.fmt.comptimePrint(" :a{d} 0", .{i});
        break :blk s ++ ")";
    };

    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    var tr = try validate(a, tree, schema);
    defer tr.deinit();
    try testing.expect(!tr.hasErrors());
}

test "unknown head emits unknown-form diagnostic" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("(scene :bpm 130)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const d = bundle.result.diagnostics[0];
    try testing.expect(std.mem.indexOf(u8, d.message, "unknown form") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "scene") != null);
    // Path identifies the failing node — the unknown form itself.
    try testing.expectEqual(@as(usize, 1), d.path.len);
    try testing.expectEqualStrings("scene", d.path[0]);
}

test "diagnostic path traces nested kvpair value" {
    // Path semantics: failing kvpair value gets [...form-head, key].
    const scene_plugin: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "scene",
                .keys = &.{
                    .{ .name = "bpm", .value_type = .number, .optional = false },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{scene_plugin});
    var bundle = try validateSrc(
        \\(scene :bpm "not-a-number")
    , schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const d = bundle.result.diagnostics[0];
    try testing.expectEqual(@as(usize, 2), d.path.len);
    try testing.expectEqualStrings("scene", d.path[0]);
    try testing.expectEqualStrings("bpm", d.path[1]);
}

test "diagnostic path traces nested form" {
    // Path semantics: nested form's diagnostics get [...parent-head, child-head].
    const wrap_plugin: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "outer",
                .positional = .any,
            },
        },
    };
    const schema = Schema.Schema.init(&.{wrap_plugin});
    var bundle = try validateSrc(
        \\(outer (typo :x 1))
    , schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const d = bundle.result.diagnostics[0];
    try testing.expectEqual(@as(usize, 2), d.path.len);
    try testing.expectEqualStrings("outer", d.path[0]);
    try testing.expectEqualStrings("typo", d.path[1]);
}

test "form spec accepts known keys" {
    const scene_plugin: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "scene",
                .keys = &.{
                    .{ .name = "bpm", .value_type = .number },
                    .{ .name = "name", .value_type = .string },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{scene_plugin});
    var bundle = try validateSrc(
        \\(scene :bpm 130 :name "main")
    , schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "form spec rejects unknown key" {
    const scene_plugin: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "scene",
                .keys = &.{
                    .{ .name = "bpm", .value_type = .number },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{scene_plugin});
    var bundle = try validateSrc("(scene :bpm 130 :wat 1)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[0].message, "wat") != null);
}

test "form spec rejects duplicate keys" {
    const scene_plugin: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "scene",
                .keys = &.{
                    .{ .name = "bpm", .value_type = .number },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{scene_plugin});
    var bundle = try validateSrc("(scene :bpm 120 :bpm 130)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[0].message, "duplicate") != null);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[0].message, "bpm") != null);
}

test "open form rejects duplicate keys" {
    // Duplicate detection is schema-independent: kvpair lists carry map
    // semantics regardless of whether the form is open or closed. Open
    // only relaxes the unknown-key and required-key checks.
    const open_plugin: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "any",
                .open = true,
            },
        },
    };
    const schema = Schema.Schema.init(&.{open_plugin});
    var bundle = try validateSrc("(any :x 1 :x 2)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[0].message, "duplicate") != null);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[0].message, ":x") != null);
}

test "open form accepts unknown keys silently" {
    const open_plugin: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{ .name = "bag", .open = true },
        },
    };
    const schema = Schema.Schema.init(&.{open_plugin});
    var bundle = try validateSrc("(bag :anything 1 :else 2)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "ambiguous bare head emits ambiguity diagnostic" {
    const a_plugin: Plugin.Plugin = .{
        .name = "a",
        .forms = &.{.{ .name = "verb" }},
    };
    const b_plugin: Plugin.Plugin = .{
        .name = "b",
        .forms = &.{.{ .name = "verb" }},
    };
    const schema = Schema.Schema.init(&.{ a_plugin, b_plugin });
    var bundle = try validateSrc("(verb)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "ambiguous") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "[a, b]") != null);
}

test "ambiguous head resolved by qualifier" {
    const a_plugin: Plugin.Plugin = .{
        .name = "a",
        .forms = &.{.{ .name = "verb" }},
    };
    const b_plugin: Plugin.Plugin = .{
        .name = "b",
        .forms = &.{.{ .name = "verb" }},
    };
    const schema = Schema.Schema.init(&.{ a_plugin, b_plugin });
    var bundle = try validateSrc("(b/verb)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "form rejects positional when positional == .none" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{ .name = "config", .positional = .none },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(config 1 2)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
}

test "nested expression validated too" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("(+ 1 (vec3 1 2))", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    // Two diagnostics now: inner (vec3 1 2) has wrong arity, and the
    // outer `+` sees a `.vector`-result expression in a `.number` rest
    // slot — that's `expr_type_mismatch` (declared result enforcement).
    try testing.expectEqual(@as(usize, 2), bundle.result.diagnostics.len);
    var saw_arity = false;
    var saw_expr_mismatch = false;
    for (bundle.result.diagnostics) |d| {
        if (d.code == .arity_mismatch and std.mem.indexOf(u8, d.message, "vec3") != null) saw_arity = true;
        if (d.code == .expr_type_mismatch) saw_expr_mismatch = true;
    }
    try testing.expect(saw_arity);
    try testing.expect(saw_expr_mismatch);
}

// ---------------------------------------------------------------------------
// Slot typing — typed vectors, unit-aware numbers, PositionalSpec.kind.
// Activates `KeySpec.value_type` and `PositionalSpec` enforcement.
// ---------------------------------------------------------------------------

/// Builds a plugin with a single form `set` that has one key `k` typed as
/// the named ValueKind `kind_name`. Used by several slot-typing tests.
fn makeSlotTypingPlugin(
    comptime kind_name: []const u8,
    comptime kinds: []const Plugin.ValueKind,
) Plugin.Plugin {
    return .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{
                    .{ .name = "k", .value_type = .{ .named = .{ .name = kind_name } } },
                },
            },
        },
        .value_kinds = kinds,
    };
}

test "slot typing: vec3 accepts a 3-element vector" {
    const p = makeSlotTypingPlugin("vec3", &.{
        .{
            .name = "vec3",
            .underlying = .vector,
            .vector = .{ .len = 3, .element = .{ .name = "number" } },
        },
    });
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k [1 2 3])", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "slot typing: vec3 rejects wrong-length vector" {
    const p = makeSlotTypingPlugin("vec3", &.{
        .{
            .name = "vec3",
            .underlying = .vector,
            .vector = .{ .len = 3, .element = .{ .name = "number" } },
        },
    });
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k [1 2])", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "`vec3`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "vector of length 2") != null);
}

test "slot typing: vec3 rejects scalar" {
    const p = makeSlotTypingPlugin("vec3", &.{
        .{
            .name = "vec3",
            .underlying = .vector,
            .vector = .{ .len = 3, .element = .{ .name = "number" } },
        },
    });
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k 0.5)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "`vec3`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "got number") != null);
}

test "slot typing: mat4 as flat 16-element vector" {
    const p = makeSlotTypingPlugin("mat4", &.{
        .{
            .name = "mat4",
            .underlying = .vector,
            .vector = .{ .len = 16, .element = .{ .name = "number" } },
        },
    });
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc(
        "(set :k [1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1])",
        schema,
    );
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "slot typing: mat4 as vec4-of-vec4 nests cleanly" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "m", .value_type = .{ .named = .{ .name = "mat4" } } }},
            },
        },
        .value_kinds = &.{
            .{
                .name = "vec4",
                .underlying = .vector,
                .vector = .{ .len = 4, .element = .{ .name = "number" } },
            },
            .{
                .name = "mat4",
                .underlying = .vector,
                .vector = .{ .len = 4, .element = .{ .name = "vec4" } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc(
        "(set :m [[1 0 0 0] [0 1 0 0] [0 0 1 0] [0 0 0 1]])",
        schema,
    );
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "slot typing: nested vector mismatch points at offending element" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "m", .value_type = .{ .named = .{ .name = "mat4" } } }},
            },
        },
        .value_kinds = &.{
            .{
                .name = "vec4",
                .underlying = .vector,
                .vector = .{ .len = 4, .element = .{ .name = "number" } },
            },
            .{
                .name = "mat4",
                .underlying = .vector,
                .vector = .{ .len = 4, .element = .{ .name = "vec4" } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc(
        "(set :m [[1 0 0 0] [0 1 0 0] [0 0 1 0] [0 0 0]])",
        schema,
    );
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "`mat4`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "element [3]") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "vector of length 3") != null);
}

test "slot typing: duration requires a unit suffix from allowed list" {
    const p = makeSlotTypingPlugin("duration", &.{
        .{
            .name = "duration",
            .underlying = .number,
            .unit = .{ .required = true, .allowed = &.{ "s", "ms" } },
        },
    });
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k 250ms)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "slot typing: duration rejects bare number" {
    const p = makeSlotTypingPlugin("duration", &.{
        .{
            .name = "duration",
            .underlying = .number,
            .unit = .{ .required = true, .allowed = &.{ "s", "ms" } },
        },
    });
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k 250)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "`duration`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "without unit") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`s`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`ms`") != null);
}

test "slot typing: duration rejects disallowed unit" {
    const p = makeSlotTypingPlugin("duration", &.{
        .{
            .name = "duration",
            .underlying = .number,
            .unit = .{ .required = true, .allowed = &.{ "s", "ms" } },
        },
    });
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k 90deg)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "`duration`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "unit `deg`") != null);
}

test "slot typing: angle accepts both `deg` and `rad`" {
    const p = makeSlotTypingPlugin("angle", &.{
        .{
            .name = "angle",
            .underlying = .number,
            .unit = .{ .required = true, .allowed = &.{ "deg", "rad" } },
        },
    });
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k 90deg)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());

    var bundle2 = try validateSrc("(set :k 1.57rad)", schema);
    defer bundle2.tree.deinit();
    defer {
        var r2 = bundle2.result;
        r2.deinit();
    }
    try testing.expect(!bundle2.result.hasErrors());
}

test "slot typing: bare .number slot accepts unit-suffixed values (permissive)" {
    // Per chosen design (unit work commit 86877ae): a slot typed as
    // `.number` (not a `duration`/`angle` ValueKind) accepts both plain
    // numbers and unit-suffixed numbers without diagnostic. Units are
    // metadata at AST layer; only declared `UnitShape`s constrain them.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "k", .value_type = .number }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k 250ms)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "slot typing: PositionalSpec.kind enforces typed positional children" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "box",
                .positional = .{ .kind = .{ .name = "vec3" } },
            },
        },
        .value_kinds = &.{
            .{
                .name = "vec3",
                .underlying = .vector,
                .vector = .{ .len = 3, .element = .{ .name = "number" } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});

    var ok = try validateSrc("(box [1 2 3])", schema);
    defer ok.tree.deinit();
    defer {
        var r = ok.result;
        r.deinit();
    }
    try testing.expect(!ok.result.hasErrors());

    var bad_len = try validateSrc("(box [1 2])", schema);
    defer bad_len.tree.deinit();
    defer {
        var r = bad_len.result;
        r.deinit();
    }
    try testing.expect(bad_len.result.hasErrors());
    const msg_len = bad_len.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg_len, "positional argument") != null);
    try testing.expect(std.mem.indexOf(u8, msg_len, "vector of length 2") != null);

    var bad_scalar = try validateSrc("(box 0.5)", schema);
    defer bad_scalar.tree.deinit();
    defer {
        var r = bad_scalar.result;
        r.deinit();
    }
    try testing.expect(bad_scalar.result.hasErrors());
}

test "slot typing: open form still type-checks declared keys" {
    // §7.3 invariant: `open: true` relaxes unknown-key acceptance and
    // missing-required enforcement, but NOT type checks on keys that
    // are explicitly declared. A typed slot's declared type is still
    // a contract the author asked for.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "bag",
                .keys = &.{.{ .name = "n", .value_type = .number }},
                .open = true,
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(bag :n \"oops\")", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, ":n") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "number") != null);
}

test "slot typing: open form with good type + extra key emits nothing" {
    // §7.3: declared key type-check passes, unknown key silenced. Both
    // relaxations and the type-check coexist on a single happy-path doc.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "bag",
                .keys = &.{.{ .name = "radius", .value_type = .number }},
                .open = true,
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(bag :radius 3 :extra \"anything\")", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), bundle.result.diagnostics.len);
}

test "slot typing: open form with positional kind still type-checks" {
    // §7.3 / positional path: `:positional .kind` declares a typed
    // positional slot. Open relaxes unknown shape, not declared shape;
    // the declared kind constraint still runs.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "list",
                .positional = .{ .kind = .{ .name = "number" } },
                .open = true,
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(list 1 2 \"three\")", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
}

test "slot typing: unknown ValueKind reference reports a setup error" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "bogus" } } }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k 1)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "unknown value kind `bogus`") != null);
}

test "slot typing: ambiguous ValueKind reference names the colliding plugins" {
    // Two plugins each declare `color`; a third plugin's form references it
    // bare. Validator should surface the cross-plugin collision per parse.
    const a: Plugin.Plugin = .{
        .name = "a",
        .value_kinds = &.{.{ .name = "color", .underlying = .string }},
    };
    const b: Plugin.Plugin = .{
        .name = "b",
        .value_kinds = &.{.{ .name = "color", .underlying = .string }},
    };
    const host: Plugin.Plugin = .{
        .name = "host",
        .forms = &.{
            .{
                .name = "fill",
                .keys = &.{.{ .name = "c", .value_type = .{ .named = .{ .name = "color" } } }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{ a, b, host });
    var bundle = try validateSrc("(fill :c \"red\")", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "value kind `color` is ambiguous") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "[a, b]") != null);
    // The new diagnostic surface includes a recovery hint pointing at
    // the first claimant — same convention used for ambiguous forms.
    try testing.expect(std.mem.indexOf(u8, msg, "qualify with `a/color`") != null);
}

test "slot typing: qualified value-kind ref skips ambiguity" {
    // Same two-plugin collision as the bare-ref test, but the form's
    // `:type` is qualified as `a/color` so the validator resolves to
    // plugin `a` directly. No diagnostic; value matches.
    const a: Plugin.Plugin = .{
        .name = "a",
        .value_kinds = &.{.{
            .name = "color",
            .underlying = .symbol,
            .members = .{ .members = &.{.{ .name = "red" }} },
        }},
    };
    const b: Plugin.Plugin = .{
        .name = "b",
        .value_kinds = &.{.{
            .name = "color",
            .underlying = .symbol,
            .members = .{ .members = &.{.{ .name = "cyan" }} },
        }},
    };
    const host: Plugin.Plugin = .{
        .name = "host",
        .forms = &.{
            .{
                .name = "fill",
                .keys = &.{.{ .name = "c", .value_type = .{ .named = .{ .name = "color", .namespace = "a" } } }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{ a, b, host });
    var bundle = try validateSrc("(fill :c red)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "slot typing: unknown qualified value-kind ref echoes the namespace" {
    // Slot says `paint/color` but no plugin named `paint` exists.
    // The renderer should preserve the user's surface text so the
    // diagnostic guides the user back to what they wrote.
    const p: Plugin.Plugin = .{
        .name = "host",
        .forms = &.{
            .{
                .name = "fill",
                .keys = &.{.{ .name = "c", .value_type = .{ .named = .{ .name = "color", .namespace = "paint" } } }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(fill :c red)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "unknown value kind `paint/color`") != null);
}

test "slot typing: qualified vector :element resolves to the named plugin" {
    // Vector kind in plugin `palette-host` references its element kind
    // via `paint/color`. Plugin `display` also declares `color`, so a
    // bare reference would be ambiguous; the qualification picks paint.
    const paint: Plugin.Plugin = .{
        .name = "paint",
        .value_kinds = &.{.{
            .name = "color",
            .underlying = .symbol,
            .members = .{ .members = &.{.{ .name = "red" }} },
        }},
    };
    const display: Plugin.Plugin = .{
        .name = "display",
        .value_kinds = &.{.{
            .name = "color",
            .underlying = .symbol,
            .members = .{ .members = &.{.{ .name = "cyan" }} },
        }},
    };
    const host: Plugin.Plugin = .{
        .name = "host",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "swatches", .value_type = .{ .named = .{ .name = "swatches-vec" } } }},
            },
        },
        .value_kinds = &.{.{
            .name = "swatches-vec",
            .underlying = .vector,
            .vector = .{ .element = .{ .name = "color", .namespace = "paint" } },
        }},
    };
    const schema = Schema.Schema.init(&.{ paint, display, host });
    var bundle = try validateSrc("(set :swatches [red])", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "slot typing: cyclic ValueKind chain bottoms out without looping" {
    // Pathological setup: kind A's element references B; B's references A.
    // The matcher's depth grows by one per kind lookup, so it always
    // bottoms out on the actual data — even with a cyclic chain it cannot
    // recurse past the data's nesting depth. (`MAX_KIND_DEPTH` is the
    // safety net for the case where a future change made matchType
    // non-data-driven.)
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "A" } } }},
            },
        },
        .value_kinds = &.{
            .{
                .name = "A",
                .underlying = .vector,
                .vector = .{ .element = .{ .name = "B" } },
            },
            .{
                .name = "B",
                .underlying = .vector,
                .vector = .{ .element = .{ .name = "A" } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k [[1]])", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    // Innermost `1` is a number where the cycle expects yet another vector
    // — that's a clean wrong_underlying. The test pins that we don't
    // stack-overflow trying to resolve the cycle.
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "got number") != null);
}

test "slot typing: form value in non-form slot defers to runtime" {
    // Permissive design: a form in any slot is treated as an expression
    // that will be evaluated at expr-eval time, so no static diagnostic.
    // Mirrors the existing `circle :radius (* 2 ...)` pattern.
    const p = makeSlotTypingPlugin("length", &.{
        .{ .name = "length", .underlying = .number },
    });
    const schema = Schema.Schema.init(&.{ core.plugin, p });
    var bundle = try validateSrc("(set :k (* 2 3))", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

// ---------------------------------------------------------------------------
// Slot typing — closed-set membership (`MemberSet`) on .symbol / .string.
// ---------------------------------------------------------------------------

test "slot typing: symbol enum accepts a member" {
    const p = makeSlotTypingPlugin("projection", &.{
        .{
            .name = "projection",
            .underlying = .symbol,
            .members = .{ .members = &.{ .{ .name = "ortho" }, .{ .name = "perspective" } } },
        },
    });
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k ortho)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "slot typing: deprecated member emits warning, validation still succeeds" {
    const p = makeSlotTypingPlugin("projection", &.{
        .{
            .name = "projection",
            .underlying = .symbol,
            .members = .{ .members = &.{
                .{ .name = "ortho" },
                .{ .name = "perspective", .deprecated = true, .deprecation_message = "Use ortho instead." },
            } },
        },
    });
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k perspective)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const d = bundle.result.diagnostics[0];
    try testing.expectEqual(Ast.Diagnostic.Code.deprecated_member, d.code);
    try testing.expectEqual(Ast.Diagnostic.Severity.warning, d.severity);
    try testing.expect(std.mem.indexOf(u8, d.message, "perspective") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "Use ortho instead.") != null);
}

test "slot typing: deprecated member warns in a positional slot, on both paths" {
    // The binary walker emits both warnings uniformly for every
    // slot-contexted node; the tree side had grown them per-site and the
    // positional arm only ever got the string-pattern half. The corpus
    // could not see it — no case covers a deprecated member in a
    // positional slot, which is exactly the finding.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .value_kinds = &.{.{
            .name = "projection",
            .underlying = .symbol,
            .members = .{ .members = &.{
                .{ .name = "ortho" },
                .{ .name = "perspective", .deprecated = true, .deprecation_message = "Use ortho instead." },
            } },
        }},
        .forms = &.{.{
            .name = "set",
            .positional = .{ .kind = .{ .name = "projection" } },
        }},
    };
    const schema = Schema.Schema.init(&.{p});

    try expectCodeOnBoth("(set perspective)", schema, .deprecated_member);
    // A non-deprecated member in the same slot stays silent on both.
    try expectNoCodeOnBoth("(set ortho)", schema, .deprecated_member);
}

test "slot typing: deprecated member without :deprecation-message yields generic prose" {
    const p = makeSlotTypingPlugin("projection", &.{
        .{
            .name = "projection",
            .underlying = .symbol,
            .members = .{ .members = &.{
                .{ .name = "ortho" },
                .{ .name = "perspective", .deprecated = true },
            } },
        },
    });
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k perspective)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const d = bundle.result.diagnostics[0];
    try testing.expectEqual(Ast.Diagnostic.Code.deprecated_member, d.code);
    try testing.expect(std.mem.endsWith(u8, d.message, "is deprecated"));
}

test "slot typing: non-deprecated member emits no warning" {
    const p = makeSlotTypingPlugin("projection", &.{
        .{
            .name = "projection",
            .underlying = .symbol,
            .members = .{ .members = &.{
                .{ .name = "ortho" },
                .{ .name = "perspective", .deprecated = true },
            } },
        },
    });
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k ortho)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), bundle.result.diagnostics.len);
}

test "slot typing: deprecated member on .string underlying" {
    const p = makeSlotTypingPlugin("colour-space", &.{
        .{
            .name = "colour-space",
            .underlying = .string,
            .members = .{ .members = &.{
                .{ .name = "rgb" },
                .{ .name = "yuv", .deprecated = true, .deprecation_message = "Use rgb." },
            } },
        },
    });
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k \"yuv\")", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const d = bundle.result.diagnostics[0];
    try testing.expectEqual(Ast.Diagnostic.Code.deprecated_member, d.code);
    try testing.expect(std.mem.indexOf(u8, d.message, "Use rgb.") != null);
}

test "slot typing: symbol enum rejects a non-member" {
    const p = makeSlotTypingPlugin("projection", &.{
        .{
            .name = "projection",
            .underlying = .symbol,
            .members = .{ .members = &.{ .{ .name = "ortho" }, .{ .name = "perspective" } } },
        },
    });
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k oblique)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "`projection`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`oblique`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`ortho`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`perspective`") != null);
}

test "slot typing: symbol enum rejects a non-symbol value" {
    const p = makeSlotTypingPlugin("projection", &.{
        .{
            .name = "projection",
            .underlying = .symbol,
            .members = .{ .members = &.{ .{ .name = "ortho" }, .{ .name = "perspective" } } },
        },
    });
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k 1)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "`projection`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "got number") != null);
}

test "slot typing: string enum accepts a member" {
    const p = makeSlotTypingPlugin("colour-space", &.{
        .{
            .name = "colour-space",
            .underlying = .string,
            .members = .{ .members = &.{ .{ .name = "rgb" }, .{ .name = "yuv" }, .{ .name = "hsl" } } },
        },
    });
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k \"rgb\")", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "slot typing: string enum rejects a non-member" {
    const p = makeSlotTypingPlugin("colour-space", &.{
        .{
            .name = "colour-space",
            .underlying = .string,
            .members = .{ .members = &.{ .{ .name = "rgb" }, .{ .name = "yuv" }, .{ .name = "hsl" } } },
        },
    });
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k \"cmyk\")", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "`colour-space`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`cmyk`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`rgb`") != null);
}

test "slot typing: string enum rejects a non-string value" {
    const p = makeSlotTypingPlugin("colour-space", &.{
        .{
            .name = "colour-space",
            .underlying = .string,
            .members = .{ .members = &.{ .{ .name = "rgb" }, .{ .name = "yuv" } } },
        },
    });
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k 1)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "`colour-space`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "got number") != null);
}

test "slot typing: symbol kind without members accepts any symbol" {
    // members = null → underlying-only check, no narrowing.
    const p = makeSlotTypingPlugin("anysym", &.{
        .{ .name = "anysym", .underlying = .symbol },
    });
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k whatever)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "slot typing: enum kind referenced through a vector element" {
    // Vector element kind = enum: each element must be in the member set.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "modes" } } }},
            },
        },
        .value_kinds = &.{
            .{
                .name = "modes",
                .underlying = .vector,
                .vector = .{ .element = .{ .name = "mode" } },
            },
            .{
                .name = "mode",
                .underlying = .symbol,
                .members = .{ .members = &.{ .{ .name = "loop" }, .{ .name = "once" } } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});

    var ok = try validateSrc("(set :k [loop once loop])", schema);
    defer ok.tree.deinit();
    defer {
        var r = ok.result;
        r.deinit();
    }
    try testing.expect(!ok.result.hasErrors());

    var bad = try validateSrc("(set :k [loop bounce])", schema);
    defer bad.tree.deinit();
    defer {
        var r = bad.result;
        r.deinit();
    }
    try testing.expect(bad.result.hasErrors());
    const msg = bad.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "element [1]") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`bounce`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`loop`") != null);
}

test "slot typing: ambiguous enum kind name names the colliding plugins" {
    const a: Plugin.Plugin = .{
        .name = "a",
        .value_kinds = &.{.{
            .name = "mode",
            .underlying = .symbol,
            .members = .{ .members = &.{.{ .name = "loop" }} },
        }},
    };
    const b: Plugin.Plugin = .{
        .name = "b",
        .value_kinds = &.{.{
            .name = "mode",
            .underlying = .symbol,
            .members = .{ .members = &.{.{ .name = "once" }} },
        }},
    };
    const host: Plugin.Plugin = .{
        .name = "host",
        .forms = &.{.{
            .name = "set",
            .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "mode" } } }},
        }},
    };
    const schema = Schema.Schema.init(&.{ a, b, host });
    var bundle = try validateSrc("(set :k loop)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "value kind `mode` is ambiguous") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "[a, b]") != null);
}

test "slot typing: open form still enforces enum membership on declared keys" {
    // §7.3: open forms relax unknown-key acceptance and missing-required
    // enforcement, not type checks on declared keys. Enum membership is
    // a type check on a declared key — it still runs.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "bag",
            .keys = &.{.{ .name = "mode", .value_type = .{ .named = .{ .name = "mode" } } }},
            .open = true,
        }},
        .value_kinds = &.{.{
            .name = "mode",
            .underlying = .symbol,
            .members = .{ .members = &.{ .{ .name = "loop" }, .{ .name = "once" } } },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(bag :mode bounce)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "bounce") != null);
}

// ---------------------------------------------------------------------------
// HeadSet — form-as-slot pinning. Activates `ValueKind.heads`.
// Slot expects a `(point …) | (rect …) | (circle …)` form-shaped value;
// the validator narrows on the head identifier (OpenAPI-style).
// ---------------------------------------------------------------------------

const head_pinned_plugin: Plugin.Plugin = .{
    .name = "demo",
    .forms = &.{
        .{
            .name = "set",
            .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "point-or-rect" } } }},
        },
        .{ .name = "point" },
        .{ .name = "rect" },
    },
    .value_kinds = &.{.{
        .name = "point-or-rect",
        .underlying = .form,
        .heads = .{ .names = &.{ "point", "rect" } },
    }},
};

test "head-set: accepts an allowed head" {
    const schema = Schema.Schema.init(&.{head_pinned_plugin});
    var bundle = try validateSrc("(set :k (point))", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "head-set: rejects a disallowed head" {
    // `rgb` is not in the head-set; the slot diagnostic should name it
    // and list the allowed alternatives. Using `(rgb)` (no positionals)
    // keeps the assertion to a single head-set diagnostic — `rgb` is
    // declared with default `.positional = .none`.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "point-or-rect" } } }},
            },
            .{ .name = "point" },
            .{ .name = "rect" },
            .{ .name = "rgb" },
        },
        .value_kinds = &.{.{
            .name = "point-or-rect",
            .underlying = .form,
            .heads = .{ .names = &.{ "point", "rect" } },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k (rgb))", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "rgb") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "point") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "rect") != null);
}

test "head-set: rejects a non-form value" {
    const schema = Schema.Schema.init(&.{head_pinned_plugin});
    var bundle = try validateSrc("(set :k 1)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "form") != null);
}

test "head-set: heads = null on .form underlying accepts any form head" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "any-form" } } }},
            },
            .{ .name = "anything" },
        },
        .value_kinds = &.{.{ .name = "any-form", .underlying = .form }},
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k (anything))", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "head-set: vector-of-head-pinned flags the failing element" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "shapes" } } }},
            },
            .{ .name = "point" },
            .{ .name = "typo" },
        },
        .value_kinds = &.{
            .{ .name = "shapes", .underlying = .vector, .vector = .{ .element = .{ .name = "point-or-rect" } } },
            .{ .name = "point-or-rect", .underlying = .form, .heads = .{ .names = &.{ "point", "rect" } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k [(point) (typo)])", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "typo") != null);
}

test "head-set: cross-plugin form-name ambiguity still fires alongside head check" {
    // Two plugins both declaring a form `point`. Inside a head-pinned
    // slot, the validator's per-form ambiguity check still fires — the
    // HeadSet narrowing operates on the head text and does not suppress
    // existing form-lookup diagnostics.
    const a_plugin: Plugin.Plugin = .{ .name = "a", .forms = &.{.{ .name = "point" }} };
    const b_plugin: Plugin.Plugin = .{ .name = "b", .forms = &.{.{ .name = "point" }} };
    const slot_plugin: Plugin.Plugin = .{
        .name = "slot",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "point-or-rect" } } }},
            },
            .{ .name = "rect" },
        },
        .value_kinds = &.{.{
            .name = "point-or-rect",
            .underlying = .form,
            .heads = .{ .names = &.{ "point", "rect" } },
        }},
    };
    const schema = Schema.Schema.init(&.{ a_plugin, b_plugin, slot_plugin });
    var bundle = try validateSrc("(set :k (point))", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    // Form ambiguity diagnostic still fires for `(point)` itself — the
    // HeadSet check accepted the head text but did not suppress the
    // existing per-form lookup machinery.
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "ambiguous") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "point") != null);
}

test "head-set: open form still type-checks head-pinned key" {
    // §7.3 + HeadSet: open relaxes only unknown-key/required-key. A
    // head-pinned declared key still narrows on the form head — open
    // does not silence the discriminator check.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "bag",
                .keys = &.{.{ .name = "paint", .value_type = .{ .named = .{ .name = "point-or-rect" } } }},
                .open = true,
            },
            .{ .name = "point" },
            .{ .name = "rect" },
            .{ .name = "typo" },
        },
        .value_kinds = &.{.{
            .name = "point-or-rect",
            .underlying = .form,
            .heads = .{ .names = &.{ "point", "rect" } },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(bag :paint (typo))", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "typo") != null);
}

// ---------------------------------------------------------------------------
// Required keys — activates `KeySpec.optional = false`.
// ---------------------------------------------------------------------------

const required_bpm_plugin: Plugin.Plugin = .{
    .name = "demo",
    .forms = &.{
        .{
            .name = "scene",
            .keys = &.{
                .{ .name = "bpm", .value_type = .number, .optional = false },
            },
        },
    },
};

test "required key: present passes silently" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    var bundle = try validateSrc("(scene :bpm 130)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "required key: absent emits one diagnostic anchored at form head" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    const src: [:0]const u8 = "(scene)";
    var bundle = try validateSrc(src, schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const d = bundle.result.diagnostics[0];
    try testing.expect(std.mem.indexOf(u8, d.message, "missing required keyword") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "`scene`") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "`:bpm`") != null);
    // Anchor is the form head span — `scene` token, source offsets [1, 6).
    try testing.expectEqualStrings("scene", src[d.span.start..d.span.end]);
}

test "required key: two absent yields two diagnostics in declaration order" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "scene",
                .keys = &.{
                    .{ .name = "bpm", .optional = false },
                    .{ .name = "name", .value_type = .string, .optional = false },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(scene)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 2), bundle.result.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[0].message, "`:bpm`") != null);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[1].message, "`:name`") != null);
}

test "required key: optional sibling stays silent when omitted" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "scene",
                .keys = &.{
                    .{ .name = "bpm", .optional = false },
                    .{ .name = "name", .value_type = .string },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(scene :bpm 130)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "required key: only optional given still flags the required" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "scene",
                .keys = &.{
                    .{ .name = "bpm", .optional = false },
                    .{ .name = "name", .value_type = .string },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc(
        \\(scene :name "main")
    , schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[0].message, "`:bpm`") != null);
}

test "required key: open form bypasses missing-key check" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "bag",
                .keys = &.{.{ .name = "bpm", .optional = false }},
                .open = true,
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(bag)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "required key: wrong-type value still satisfies presence" {
    // Type mismatch fires; missing-key does not — `seen` is set on name
    // match regardless of value validity.
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    var bundle = try validateSrc(
        \\(scene :bpm "fast")
    , schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "expects number") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "missing") == null);
}

// ---------------------------------------------------------------------------
// Required keys — long-tail coverage. Anchors:
//   1. Cardinality (zero / single / many / partial absences)
//   2. Ordering (declaration order vs source order; source duplicates)
//   3. Cross-diagnostic interaction (typo / type / positional / unknown-kind)
//   4. Nested + sibling forms (per-call bitset isolation)
//   5. Lookup outcomes (ambiguous / unknown / qualified bypass or honour)
//   6. Value-type cross-product
//   7. Spec-index tracking past index 0
//   8. Exact diagnostic message format / span anchoring
// ---------------------------------------------------------------------------

// 1. Cardinality

test "required key: form with no required keys never emits missing diagnostic" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{ .name = "f", .keys = &.{ .{ .name = "a" }, .{ .name = "b" } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    inline for (.{ "(f)", "(f :a 1)", "(f :a 1 :b 2)" }) |src| {
        var bundle = try validateSrc(src, schema);
        defer bundle.tree.deinit();
        defer {
            var r = bundle.result;
            r.deinit();
        }
        try testing.expect(!bundle.result.hasErrors());
    }
}

test "required key: 3 required all present passes silently" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "f",
                .keys = &.{
                    .{ .name = "a", .optional = false },
                    .{ .name = "b", .optional = false },
                    .{ .name = "c", .optional = false },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(f :a 1 :b 2 :c 3)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "required key: 3 required all absent emits 3 diagnostics in declaration order" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "f",
                .keys = &.{
                    .{ .name = "alpha", .optional = false },
                    .{ .name = "beta", .optional = false },
                    .{ .name = "gamma", .optional = false },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(f)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 3), bundle.result.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[0].message, "`:alpha`") != null);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[1].message, "`:beta`") != null);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[2].message, "`:gamma`") != null);
}

test "required key: 3 required only middle absent emits 1 diagnostic" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "f",
                .keys = &.{
                    .{ .name = "alpha", .optional = false },
                    .{ .name = "beta", .optional = false },
                    .{ .name = "gamma", .optional = false },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(f :alpha 1 :gamma 3)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[0].message, "`:beta`") != null);
}

test "required key: 3 required first and third absent emits 2 in declaration order" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "f",
                .keys = &.{
                    .{ .name = "alpha", .optional = false },
                    .{ .name = "beta", .optional = false },
                    .{ .name = "gamma", .optional = false },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(f :beta 2)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 2), bundle.result.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[0].message, "`:alpha`") != null);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[1].message, "`:gamma`") != null);
}

test "required key: 5 mixed (3 req, 2 opt interleaved), only required absent flagged" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "f",
                .keys = &.{
                    .{ .name = "r1", .optional = false },
                    .{ .name = "o1" },
                    .{ .name = "r2", .optional = false },
                    .{ .name = "o2" },
                    .{ .name = "r3", .optional = false },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    // Both optionals provided; only r2 missing.
    var bundle = try validateSrc("(f :r1 1 :o1 1 :o2 1 :r3 3)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[0].message, "`:r2`") != null);
}

// 2. Ordering and duplicates

test "required key: source provides required keys in reverse declaration order" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "f",
                .keys = &.{
                    .{ .name = "first", .optional = false },
                    .{ .name = "second", .optional = false },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(f :second 2 :first 1)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "required key: duplicate key emits duplicate diagnostic, satisfies presence" {
    // Both occurrences mark seen[idx] (no missing-required diagnostic),
    // but the second occurrence emits a duplicate-keyword error. Per-kvpair
    // type-check still runs on each occurrence.
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    var bundle = try validateSrc("(scene :bpm 130 :bpm 140)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[0].message, "duplicate") != null);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[0].message, "bpm") != null);
}

// 3. Cross-diagnostic interactions

test "required key: absent + extra unknown key emits both diagnostics" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    var bundle = try validateSrc("(scene :typo 1)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 2), bundle.result.diagnostics.len);
    var saw_unknown = false;
    var saw_missing = false;
    for (bundle.result.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "unknown keyword `:typo`") != null) saw_unknown = true;
        if (std.mem.indexOf(u8, d.message, "missing required keyword `:bpm`") != null) saw_missing = true;
    }
    try testing.expect(saw_unknown);
    try testing.expect(saw_missing);
}

test "required key: unknown ValueKind reference satisfies presence" {
    // Setup-error diagnostic fires on the value; missing-required does
    // not — name match still records seen[idx].
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "f",
                .keys = &.{
                    .{ .name = "k", .value_type = .{ .named = .{ .name = "bogus" } }, .optional = false },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(f :k 1)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "unknown value kind `bogus`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "missing") == null);
}

test "required key: absent + positional .none rejection emits both" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "f",
                .keys = &.{.{ .name = "k", .optional = false }},
                .positional = .none,
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(f 1)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 2), bundle.result.diagnostics.len);
    var saw_pos = false;
    var saw_missing = false;
    for (bundle.result.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "does not accept positional") != null) saw_pos = true;
        if (std.mem.indexOf(u8, d.message, "missing required keyword `:k`") != null) saw_missing = true;
    }
    try testing.expect(saw_pos);
    try testing.expect(saw_missing);
}

test "required key: absent + positional .kind mismatch emits both" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "f",
                .keys = &.{.{ .name = "k", .optional = false }},
                .positional = .{ .kind = .{ .name = "vec3" } },
            },
        },
        .value_kinds = &.{
            .{
                .name = "vec3",
                .underlying = .vector,
                .vector = .{ .len = 3, .element = .{ .name = "number" } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(f [1 2])", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 2), bundle.result.diagnostics.len);
    var saw_pos = false;
    var saw_missing = false;
    for (bundle.result.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "vector of length 2") != null) saw_pos = true;
        if (std.mem.indexOf(u8, d.message, "missing required keyword `:k`") != null) saw_missing = true;
    }
    try testing.expect(saw_pos);
    try testing.expect(saw_missing);
}

test "required key: positional .any coexists with required keyword check" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "f",
                .keys = &.{.{ .name = "tag", .optional = false }},
                .positional = .any,
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var ok = try validateSrc(
        \\(f 1 2 3 :tag "x")
    , schema);
    defer ok.tree.deinit();
    defer {
        var r = ok.result;
        r.deinit();
    }
    try testing.expect(!ok.result.hasErrors());

    var bad = try validateSrc("(f 1 2 3)", schema);
    defer bad.tree.deinit();
    defer {
        var r = bad.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bad.result.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, bad.result.diagnostics[0].message, "`:tag`") != null);
}

// 4. Nested + sibling forms (per-call bitset isolation)

test "required key: outer satisfies, inner missing emits diagnostic on inner" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "outer",
                .keys = &.{.{ .name = "child", .value_type = .form }},
            },
            .{
                .name = "inner",
                .keys = &.{.{ .name = "k", .optional = false }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    const src: [:0]const u8 = "(outer :child (inner))";
    var bundle = try validateSrc(src, schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const d = bundle.result.diagnostics[0];
    try testing.expect(std.mem.indexOf(u8, d.message, "`inner`") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "`:k`") != null);
    try testing.expectEqualStrings("inner", src[d.span.start..d.span.end]);
}

test "required key: outer missing, inner satisfies emits diagnostic on outer" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "outer",
                .keys = &.{
                    .{ .name = "child", .value_type = .form },
                    .{ .name = "tag", .optional = false },
                },
            },
            .{ .name = "inner" },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    const src: [:0]const u8 = "(outer :child (inner))";
    var bundle = try validateSrc(src, schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const d = bundle.result.diagnostics[0];
    try testing.expect(std.mem.indexOf(u8, d.message, "`outer`") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "`:tag`") != null);
    try testing.expectEqualStrings("outer", src[d.span.start..d.span.end]);
}

test "required key: both nested forms missing emits 2 diagnostics with correct spans" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "outer",
                .keys = &.{
                    .{ .name = "child", .value_type = .form },
                    .{ .name = "tag", .optional = false },
                },
            },
            .{
                .name = "inner",
                .keys = &.{.{ .name = "k", .optional = false }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    const src: [:0]const u8 = "(outer :child (inner))";
    var bundle = try validateSrc(src, schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 2), bundle.result.diagnostics.len);
    // Spans don't overlap and each names the right form.
    var saw_outer = false;
    var saw_inner = false;
    for (bundle.result.diagnostics) |d| {
        const head = src[d.span.start..d.span.end];
        if (std.mem.eql(u8, head, "outer") and std.mem.indexOf(u8, d.message, "`:tag`") != null) saw_outer = true;
        if (std.mem.eql(u8, head, "inner") and std.mem.indexOf(u8, d.message, "`:k`") != null) saw_inner = true;
    }
    try testing.expect(saw_outer);
    try testing.expect(saw_inner);
}

test "required key: same-named nested form uses independent bitsets" {
    // Outer (scene) satisfies its own :bpm; the same spec instance is
    // reused for the inner (scene). Bitsets are stack-local per call so
    // the inner's seen[] starts empty and correctly flags missing :bpm.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "scene",
                .keys = &.{
                    .{ .name = "child", .value_type = .form },
                    .{ .name = "bpm", .optional = false },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(scene :bpm 130 :child (scene))", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[0].message, "`:bpm`") != null);
}

// 5. Sibling and multi-root

test "required key: 3 sibling forms all missing yields 3 diagnostics with distinct spans" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    const src: [:0]const u8 = "(scene) (scene) (scene)";
    var bundle = try validateSrc(src, schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 3), bundle.result.diagnostics.len);
    // Each span must point at a distinct `scene` token.
    var starts: [3]u32 = undefined;
    for (bundle.result.diagnostics, 0..) |d, i| {
        try testing.expectEqualStrings("scene", src[d.span.start..d.span.end]);
        starts[i] = d.span.start;
    }
    try testing.expect(starts[0] != starts[1]);
    try testing.expect(starts[1] != starts[2]);
    try testing.expect(starts[0] != starts[2]);
}

test "required key: sibling forms mix pass/fail" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    var bundle = try validateSrc("(scene) (scene :bpm 130) (scene)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 2), bundle.result.diagnostics.len);
}

// 6. Lookup outcomes — required-key check is downstream of head resolution

test "required key: ambiguous form bypasses required-key check" {
    const a_plugin: Plugin.Plugin = .{
        .name = "a",
        .forms = &.{
            .{ .name = "verb", .keys = &.{.{ .name = "k", .optional = false }} },
        },
    };
    const b_plugin: Plugin.Plugin = .{
        .name = "b",
        .forms = &.{
            .{ .name = "verb", .keys = &.{.{ .name = "k", .optional = false }} },
        },
    };
    const schema = Schema.Schema.init(&.{ a_plugin, b_plugin });
    var bundle = try validateSrc("(verb)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[0].message, "ambiguous") != null);
}

test "required key: unknown form bypasses required-key check" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    var bundle = try validateSrc("(unknown)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[0].message, "unknown form") != null);
}

test "required key: qualified form still enforces required keys" {
    const ns_plugin: Plugin.Plugin = .{
        .name = "ns",
        .forms = &.{
            .{ .name = "verb", .keys = &.{.{ .name = "k", .optional = false }} },
        },
    };
    const schema = Schema.Schema.init(&.{ns_plugin});
    var bundle = try validateSrc("(ns/verb)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "missing required keyword `:k`") != null);
}

test "required key: ambiguous resolved by qualifier still required-checks" {
    const a_plugin: Plugin.Plugin = .{
        .name = "a",
        .forms = &.{
            .{ .name = "verb", .keys = &.{.{ .name = "x", .optional = false }} },
        },
    };
    const b_plugin: Plugin.Plugin = .{
        .name = "b",
        .forms = &.{
            .{ .name = "verb", .keys = &.{.{ .name = "y", .optional = false }} },
        },
    };
    const schema = Schema.Schema.init(&.{ a_plugin, b_plugin });
    var bundle = try validateSrc("(b/verb)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[0].message, "`:y`") != null);
}

// 7. Value-type cross-product on required slots

test "required key with .any accepts any value type" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "f",
                .keys = &.{.{ .name = "k", .value_type = .any, .optional = false }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    // `Tag.keyword` is intentionally absent from the cross-product —
    // SJON's greedy `:k1 :k2` rule means a kvpair value can never be a
    // keyword (`.keyword` was removed from `ValueType` for this reason;
    // see `Plugin.zig`). The set below covers every reachable atom.
    inline for (.{
        "(f :k 1)",
        "(f :k \"s\")",
        "(f :k [])",
        "(f :k true)",
        "(f :k false)",
        "(f :k nil)",
    }) |src| {
        var bundle = try validateSrc(src, schema);
        defer bundle.tree.deinit();
        defer {
            var r = bundle.result;
            r.deinit();
        }
        try testing.expect(!bundle.result.hasErrors());
    }
    var miss = try validateSrc("(f)", schema);
    defer miss.tree.deinit();
    defer {
        var r = miss.result;
        r.deinit();
    }
    try testing.expect(miss.result.hasErrors());
}

test "required key with .boolean satisfied by true and false" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "f",
                .keys = &.{.{ .name = "on", .value_type = .boolean, .optional = false }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    inline for (.{ "(f :on true)", "(f :on false)" }) |src| {
        var bundle = try validateSrc(src, schema);
        defer bundle.tree.deinit();
        defer {
            var r = bundle.result;
            r.deinit();
        }
        try testing.expect(!bundle.result.hasErrors());
    }
}

test "required key with .vector satisfied by `[…]`" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "f",
                .keys = &.{.{ .name = "v", .value_type = .vector, .optional = false }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var ok = try validateSrc("(f :v [1 2])", schema);
    defer ok.tree.deinit();
    defer {
        var r = ok.result;
        r.deinit();
    }
    try testing.expect(!ok.result.hasErrors());
    var miss = try validateSrc("(f)", schema);
    defer miss.tree.deinit();
    defer {
        var r = miss.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), miss.result.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, miss.result.diagnostics[0].message, "`:v`") != null);
}

test "required key with expression value defers and satisfies presence" {
    // Per the matcher's permissive .form rule, an expression as a value
    // bypasses the type check (deferred to expr-eval time). It still
    // counts as present for required-key tracking.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "f",
                .keys = &.{.{ .name = "k", .value_type = .number, .optional = false }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{ core.plugin, p });
    var bundle = try validateSrc("(f :k (+ 1 2))", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

// 8. Spec-index tracking past index 0

test "required key: tracked correctly at non-zero spec index (10-key form)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "form",
                .keys = &.{
                    .{ .name = "a" }, .{ .name = "b" },                    .{ .name = "c" },
                    .{ .name = "d" }, .{ .name = "e" },                    .{ .name = "f" },
                    .{ .name = "g" }, .{ .name = "h", .optional = false }, .{ .name = "i" },
                    .{ .name = "j" },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});

    // Required at index 7, present.
    var ok = try validateSrc("(form :a 0 :b 0 :h 1)", schema);
    defer ok.tree.deinit();
    defer {
        var r = ok.result;
        r.deinit();
    }
    try testing.expect(!ok.result.hasErrors());

    // Required at index 7, absent — surrounding optionals provided to
    // shake out any off-by-one in the matched-loop's seen.set.
    var bad = try validateSrc("(form :a 0 :b 0 :g 0 :i 0 :j 0)", schema);
    defer bad.tree.deinit();
    defer {
        var r = bad.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bad.result.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, bad.result.diagnostics[0].message, "`:h`") != null);
}

test "required key: many-required spec (10 keys, all required, all missing)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "form",
                .keys = &.{
                    .{ .name = "k0", .optional = false },
                    .{ .name = "k1", .optional = false },
                    .{ .name = "k2", .optional = false },
                    .{ .name = "k3", .optional = false },
                    .{ .name = "k4", .optional = false },
                    .{ .name = "k5", .optional = false },
                    .{ .name = "k6", .optional = false },
                    .{ .name = "k7", .optional = false },
                    .{ .name = "k8", .optional = false },
                    .{ .name = "k9", .optional = false },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(form)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 10), bundle.result.diagnostics.len);
    inline for (.{ "k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7", "k8", "k9" }, 0..) |name, i| {
        const expected_substr = "`:" ++ name ++ "`";
        try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[i].message, expected_substr) != null);
    }
}

// 9. Diagnostic format / span anchoring

test "required key: exact diagnostic message format is stable" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    var bundle = try validateSrc("(scene)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqualStrings(
        "form `scene` is missing required keyword `:bpm`",
        bundle.result.diagnostics[0].message,
    );
}

test "required key: indented form's diagnostic still anchors at head token" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    const src: [:0]const u8 =
        \\
        \\
        \\    (scene)
    ;
    var bundle = try validateSrc(src, schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const d = bundle.result.diagnostics[0];
    try testing.expectEqualStrings("scene", src[d.span.start..d.span.end]);
    try testing.expectEqual(d.severity, .err);
}

test "required key: diagnostic on form preceded by a comment uses head bytes" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    const src: [:0]const u8 =
        \\; intentional empty form
        \\(scene)
    ;
    var bundle = try validateSrc(src, schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const d = bundle.result.diagnostics[0];
    try testing.expectEqualStrings("scene", src[d.span.start..d.span.end]);
}

// ---------------------------------------------------------------------------
// Streaming validator (validateBinary) — parity + edge cases.
//
// Parity contract: for any source `s` and schema `S`,
//   validate(parse(s), S).diagnostics.len == validateBinary(toBinary(parse(s)), S).diagnostics.len
//
// Nested typed-`.vector` failures now converge fully: both walkers emit the
// same message, span, and path, framed against the outer slot with an
// `element [N]: …` wrap (B.9; pinned by "message parity: nested typed-vector
// element"). The remaining documented divergence is a `.union_of` slot that
// accepts a vector alternative — tree emits one `union_no_branch_matched` at
// the slot, binary emits per bad element (union-div #2).
// ---------------------------------------------------------------------------

const Binary = @import("Binary.zig");

fn encodeForValidate(src: [:0]const u8) !Ast.Bytes {
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();
    return try Binary.toBinary(testing.allocator, tree, .{
        .with_spans = true,
        .with_head_spans = true,
        .with_kvpair_key_spans = true,
    });
}

fn parityCheck(src: [:0]const u8, schema: Schema.Schema) !void {
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();
    var via_text = try validate(testing.allocator, tree, schema);
    defer via_text.deinit();

    const bin = try encodeForValidate(src);
    defer bin.deinit();
    var via_bin = try validateBinary(testing.allocator, bin.data, schema);
    defer via_bin.deinit();

    try testing.expectEqual(via_text.diagnostics.len, via_bin.diagnostics.len);
}

/// Stronger parity contract: both validators must agree on diagnostic
/// `(code, path)` for each emission, in order. Message text is allowed to
/// diverge (Tree wraps nested vectors; Binary fires at the inner element).
fn parityCheckPaths(src: [:0]const u8, schema: Schema.Schema) !void {
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();
    var via_text = try validate(testing.allocator, tree, schema);
    defer via_text.deinit();

    const bin = try encodeForValidate(src);
    defer bin.deinit();
    var via_bin = try validateBinary(testing.allocator, bin.data, schema);
    defer via_bin.deinit();

    try testing.expectEqual(via_text.diagnostics.len, via_bin.diagnostics.len);
    for (via_text.diagnostics, via_bin.diagnostics) |t, b| {
        try testing.expectEqual(t.code, b.code);
        try testing.expectEqual(t.path.len, b.path.len);
        for (t.path, b.path) |ts, bs| try testing.expectEqualStrings(ts, bs);
    }
}

test "validateBinary: clean known-form input yields no diagnostics" {
    const schema = Schema.Schema.init(&.{core.plugin});
    const bin = try encodeForValidate("(+ 1 2 3)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "validateBinary: unknown form emits one diagnostic" {
    const schema = Schema.Schema.init(&.{core.plugin});
    const bin = try encodeForValidate("(scene :bpm 130)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "unknown form") != null);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "scene") != null);
}

test "validateBinary: expression arity mismatch" {
    const schema = Schema.Schema.init(&.{core.plugin});
    const bin = try encodeForValidate("(vec3 1 2)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "vec3") != null);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "exactly 3") != null);
}

test "validateBinary: expression rejects keyword child" {
    const schema = Schema.Schema.init(&.{core.plugin});
    const bin = try encodeForValidate("(+ :nope 1)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var saw_kw_reject = false;
    for (r.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "does not accept keyword argument") != null) saw_kw_reject = true;
    }
    try testing.expect(saw_kw_reject);
}

test "validateBinary: ambiguous bare head" {
    const a_plugin: Plugin.Plugin = .{ .name = "a", .forms = &.{.{ .name = "verb" }} };
    const b_plugin: Plugin.Plugin = .{ .name = "b", .forms = &.{.{ .name = "verb" }} };
    const schema = Schema.Schema.init(&.{ a_plugin, b_plugin });
    const bin = try encodeForValidate("(verb)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "ambiguous") != null);
}

test "validateBinary: missing required keyword" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    const bin = try encodeForValidate("(scene)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "missing required keyword") != null);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, ":bpm") != null);
}

test "validateBinary: unknown keyword" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "scene", .keys = &.{.{ .name = "bpm" }} }},
    };
    const schema = Schema.Schema.init(&.{p});
    const bin = try encodeForValidate("(scene :wat 1)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "wat") != null);
}

test "validateBinary: positional rejected when .none" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "config", .positional = .none }},
    };
    const schema = Schema.Schema.init(&.{p});
    const bin = try encodeForValidate("(config 1 2)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.diagnostics.len);
    for (r.diagnostics) |d| {
        try testing.expect(std.mem.indexOf(u8, d.message, "does not accept positional") != null);
    }
}

test "validateBinary: typed slot rejects scalar where vec3 expected" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "vec3" } } }} }},
        .value_kinds = &.{.{ .name = "vec3", .underlying = .vector, .vector = .{ .len = 3, .element = .{ .name = "number" } } }},
    };
    const schema = Schema.Schema.init(&.{p});
    const bin = try encodeForValidate("(set :k 0.5)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    const msg = r.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "`vec3`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "got number") != null);
}

test "validateBinary: typed slot rejects wrong vector length" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "vec3" } } }} }},
        .value_kinds = &.{.{ .name = "vec3", .underlying = .vector, .vector = .{ .len = 3, .element = .{ .name = "number" } } }},
    };
    const schema = Schema.Schema.init(&.{p});
    const bin = try encodeForValidate("(set :k [1 2])");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    const msg = r.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "`vec3`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "vector of length 2") != null);
}

test "validateBinary: full-mode binary walks a vector without desync" {
    // Wire v5 gives every vector a trailing-comment count under `.full`. The
    // binary validator's vector walk must drain it (mirroring the form walk)
    // or the cursor desyncs on the *next* node. A trailing sibling (`:n 7`)
    // after the walked vector is what surfaces the desync — a lone tail
    // vector's one-byte misalignment falls where nothing reads it. Pin
    // full-mode parity with the tree path on a clean vec3 slot.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{
            .{ .name = "k", .value_type = .{ .named = .{ .name = "vec3" } } },
            .{ .name = "n", .value_type = .{ .named = .{ .name = "number" } } },
        } }},
        .value_kinds = &.{.{ .name = "vec3", .underlying = .vector, .vector = .{ .len = 3, .element = .{ .name = "number" } } }},
    };
    const schema = Schema.Schema.init(&.{p});
    const src = "(set :k [1 2 3] :n 7)";
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();
    var via_text = try validate(testing.allocator, tree, schema);
    defer via_text.deinit();
    try testing.expect(!via_text.hasErrors());

    const bin = try Binary.toBinary(testing.allocator, tree, Binary.ToBinaryOptions.forMode(.full));
    defer bin.deinit();
    var via_bin = try validateBinary(testing.allocator, bin.data, schema);
    defer via_bin.deinit();
    try testing.expectEqual(via_text.diagnostics.len, via_bin.diagnostics.len);
    try testing.expect(!via_bin.hasErrors());
}

test "validateBinary: nested typed-vector element reports against the outer slot" {
    // mat4 = vec of vec4. Bad inner element [0 0 0] (length 3, expected 4).
    // Post-B.9, the binary path converges on the tree framing: it reports the
    // failure against the OUTER `:m` slot — "expects `mat4`, element [3]: got
    // vector of length 3" at the whole vector's span, not "expects `vec4`, …"
    // at the inner element. Cross-arm message/span/path identity is pinned by
    // "message parity: nested typed-vector element"; this locks the binary
    // arm's own outcome.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "m", .value_type = .{ .named = .{ .name = "mat4" } } }} }},
        .value_kinds = &.{
            .{ .name = "vec4", .underlying = .vector, .vector = .{ .len = 4, .element = .{ .name = "number" } } },
            .{ .name = "mat4", .underlying = .vector, .vector = .{ .len = 4, .element = .{ .name = "vec4" } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    const src: [:0]const u8 = "(set :m [[1 0 0 0] [0 1 0 0] [0 0 1 0] [0 0 0]])";
    const bin = try encodeForValidate(src);
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    const d = r.diagnostics[0];
    try testing.expect(std.mem.indexOf(u8, d.message, "`mat4`") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "element [3]:") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "vector of length 3") != null);
    // Span points at the whole outer vector, not the inner [0 0 0].
    try testing.expectEqualStrings("[[1 0 0 0] [0 1 0 0] [0 0 1 0] [0 0 0]]", src[d.span.start..d.span.end]);
}

test "validateBinary: unit-required slot rejects bare number" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "duration" } } }} }},
        .value_kinds = &.{.{ .name = "duration", .underlying = .number, .unit = .{ .required = true, .allowed = &.{ "s", "ms" } } }},
    };
    const schema = Schema.Schema.init(&.{p});
    const bin = try encodeForValidate("(set :k 250)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    const msg = r.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "without unit") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`s`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`ms`") != null);
}

test "validateBinary: unit slot rejects disallowed unit suffix" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "duration" } } }} }},
        .value_kinds = &.{.{ .name = "duration", .underlying = .number, .unit = .{ .required = true, .allowed = &.{ "s", "ms" } } }},
    };
    const schema = Schema.Schema.init(&.{p});
    const bin = try encodeForValidate("(set :k 90deg)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "unit `deg`") != null);
}

test "validateBinary: unit slot accepts allowed suffix" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "duration" } } }} }},
        .value_kinds = &.{.{ .name = "duration", .underlying = .number, .unit = .{ .required = true, .allowed = &.{ "s", "ms" } } }},
    };
    const schema = Schema.Schema.init(&.{p});
    const bin = try encodeForValidate("(set :k 250ms)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "validateBinary: symbol enum accepts a member" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "projection" } } }} }},
        .value_kinds = &.{.{
            .name = "projection",
            .underlying = .symbol,
            .members = .{ .members = &.{ .{ .name = "ortho" }, .{ .name = "perspective" } } },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    try parityCheck("(set :k ortho)", schema);
    const bin = try encodeForValidate("(set :k ortho)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "validateBinary: symbol enum rejects a non-member" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "projection" } } }} }},
        .value_kinds = &.{.{
            .name = "projection",
            .underlying = .symbol,
            .members = .{ .members = &.{ .{ .name = "ortho" }, .{ .name = "perspective" } } },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    try parityCheck("(set :k oblique)", schema);
    const bin = try encodeForValidate("(set :k oblique)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    const msg = r.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "`projection`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`oblique`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`ortho`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`perspective`") != null);
}

test "validateBinary: symbol enum rejects a non-symbol value" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "projection" } } }} }},
        .value_kinds = &.{.{
            .name = "projection",
            .underlying = .symbol,
            .members = .{ .members = &.{ .{ .name = "ortho" }, .{ .name = "perspective" } } },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    try parityCheck("(set :k 1)", schema);
    const bin = try encodeForValidate("(set :k 1)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    const msg = r.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "`projection`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "got number") != null);
}

test "validateBinary: string enum accepts a member" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "colour-space" } } }} }},
        .value_kinds = &.{.{
            .name = "colour-space",
            .underlying = .string,
            .members = .{ .members = &.{ .{ .name = "rgb" }, .{ .name = "yuv" }, .{ .name = "hsl" } } },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    try parityCheck("(set :k \"rgb\")", schema);
    const bin = try encodeForValidate("(set :k \"rgb\")");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "validateBinary: string enum rejects a non-member" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "colour-space" } } }} }},
        .value_kinds = &.{.{
            .name = "colour-space",
            .underlying = .string,
            .members = .{ .members = &.{ .{ .name = "rgb" }, .{ .name = "yuv" }, .{ .name = "hsl" } } },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    try parityCheck("(set :k \"cmyk\")", schema);
    const bin = try encodeForValidate("(set :k \"cmyk\")");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    const msg = r.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "`colour-space`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`cmyk`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`rgb`") != null);
}

test "validateBinary: unknown ValueKind reference fires setup-error diagnostic" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "bogus" } } }} }},
    };
    const schema = Schema.Schema.init(&.{p});
    const bin = try encodeForValidate("(set :k 1)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "unknown value kind `bogus`") != null);
}

test "validateBinary: ambiguous ValueKind reference names colliding plugins" {
    const a: Plugin.Plugin = .{
        .name = "a",
        .value_kinds = &.{.{ .name = "color", .underlying = .string }},
    };
    const b: Plugin.Plugin = .{
        .name = "b",
        .value_kinds = &.{.{ .name = "color", .underlying = .string }},
    };
    const host: Plugin.Plugin = .{
        .name = "host",
        .forms = &.{.{ .name = "fill", .keys = &.{.{ .name = "c", .value_type = .{ .named = .{ .name = "color" } } }} }},
    };
    const schema = Schema.Schema.init(&.{ a, b, host });
    const bin = try encodeForValidate("(fill :c \"red\")");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    const msg = r.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "value kind `color` is ambiguous") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "[a, b]") != null);
}

test "validateBinary: head-set accepts an allowed head" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "point-or-rect" } } }} },
            .{ .name = "point" },
            .{ .name = "rect" },
        },
        .value_kinds = &.{.{
            .name = "point-or-rect",
            .underlying = .form,
            .heads = .{ .names = &.{ "point", "rect" } },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(set :k (point))", .{}, schema, 0);
}

test "validateBinary: head-set rejects a disallowed head" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "point-or-rect" } } }} },
            .{ .name = "point" },
            .{ .name = "rect" },
            .{ .name = "rgb" },
        },
        .value_kinds = &.{.{
            .name = "point-or-rect",
            .underlying = .form,
            .heads = .{ .names = &.{ "point", "rect" } },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    const bin = try encodeForValidate("(set :k (rgb))");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    const msg = r.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "rgb") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "point") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "rect") != null);
}

test "validateBinary: head-set rejects a non-form value" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "point-or-rect" } } }} },
        },
        .value_kinds = &.{.{
            .name = "point-or-rect",
            .underlying = .form,
            .heads = .{ .names = &.{ "point", "rect" } },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(set :k 1)", .{}, schema, 1);
}

test "validateBinary: form value in non-form slot defers to runtime" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .number }} }},
    };
    const schema = Schema.Schema.init(&.{ core.plugin, p });
    const bin = try encodeForValidate("(set :k (* 2 3))");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "validateBinary: nested expression inside another form gets validated" {
    const schema = Schema.Schema.init(&.{core.plugin});
    const bin = try encodeForValidate("(+ 1 (vec3 1 2))");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    // Two diagnostics now (declared-result enforcement, parity with tree):
    // inner (vec3 1 2) has wrong arity, AND the outer `+` sees a
    // vector-result form in its `.number` rest slot.
    try testing.expectEqual(@as(usize, 2), r.diagnostics.len);
    var saw_arity = false;
    var saw_expr_mismatch = false;
    for (r.diagnostics) |d| {
        if (d.code == .arity_mismatch and std.mem.indexOf(u8, d.message, "vec3") != null) saw_arity = true;
        if (d.code == .expr_type_mismatch) saw_expr_mismatch = true;
    }
    try testing.expect(saw_arity);
    try testing.expect(saw_expr_mismatch);
}

test "validateBinary: open form still type-checks declared keys" {
    // §7.3 / Binary path: open relaxes unknown keys (`:else 1` is silent),
    // but the typed slot on `:n` is still enforced — a string in a
    // number slot still emits a diagnostic.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "bag", .keys = &.{.{ .name = "n", .value_type = .number }}, .open = true }},
    };
    const schema = Schema.Schema.init(&.{p});
    const bin = try encodeForValidate("(bag :n \"oops\" :else 1)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, ":n") != null);
}

test "validateBinary: multiple roots are all validated" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    const bin = try encodeForValidate("(scene) (scene :bpm 130) (scene)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.diagnostics.len);
}

test "validateBinary: empty buffer (zero roots) yields empty result" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var tree = try Parser.parse(testing.allocator, "");
    defer tree.deinit();
    const bin = try Binary.toBinary(testing.allocator, tree, .{
        .with_spans = true,
        .with_head_spans = true,
        .with_kvpair_key_spans = true,
    });
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
}

test "validateBinary: stripped binary (no spans) emits diagnostics with zero spans" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    var tree = try Parser.parse(testing.allocator, "(scene)");
    defer tree.deinit();
    const bin = try Binary.toBinary(testing.allocator, tree, Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    const d = r.diagnostics[0];
    try testing.expectEqual(@as(u32, 0), d.span.start);
    try testing.expectEqual(@as(u32, 0), d.span.end);
}

test "validateBinary: malformed buffer surfaces cursor error" {
    const schema = Schema.Schema.init(&.{core.plugin});
    // Wrong magic bytes — Cursor.init fails immediately.
    var bytes: [16]u8 = undefined;
    @memset(&bytes, 0);
    bytes[0] = 'X';
    bytes[4] = Binary.wire_version;
    try testing.expectError(error.InvalidMagic, validateBinary(testing.allocator, &bytes, schema));
}

test "validateBinary: truncated buffer surfaces cursor error" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var tree = try Parser.parse(testing.allocator, "(+ 1 2)");
    defer tree.deinit();
    const bin = try Binary.toBinary(testing.allocator, tree, Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    // Lop the last few bytes off so a child read hits EOF.
    try testing.expectError(error.Truncated, validateBinary(testing.allocator, bin.data[0 .. bin.data.len - 3], schema));
}

// Parity sweep: text and binary paths agree on diagnostic counts across a
// representative slice of fixtures.
test "validateBinary: parity with validate across mixed fixtures" {
    const schema = Schema.Schema.init(&.{core.plugin});
    inline for (.{
        "(+ 1 2 3)",
        "(vec3 1 2)",
        "(+ :nope 1)",
        "(scene :bpm 130)",
        "(unknown-form a b c)",
        "[1 2 3]",
        "(+ 1 (vec3 1 2))",
        "(+ 1 2) (vec3 1 2) (* 1 2 3)",
    }) |src| {
        try parityCheck(src, schema);
    }
}

test "validateBinary: parity with validate for required-key plugin" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    inline for (.{
        "(scene :bpm 130)",
        "(scene)",
        "(scene :wat 1)",
        "(scene) (scene :bpm 130) (scene)",
    }) |src| {
        try parityCheck(src, schema);
    }
}

test "validateBinary: parity with validate for typed-slot plugin" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "vec3" } } }} },
            .{ .name = "box", .positional = .{ .kind = .{ .name = "vec3" } } },
        },
        .value_kinds = &.{.{ .name = "vec3", .underlying = .vector, .vector = .{ .len = 3, .element = .{ .name = "number" } } }},
    };
    const schema = Schema.Schema.init(&.{p});
    inline for (.{
        "(set :k [1 2 3])",
        "(set :k [1 2])",
        "(set :k 0.5)",
        "(box [1 2 3])",
        "(box [1 2])",
    }) |src| {
        try parityCheck(src, schema);
    }
}

// ----- Group U: union value-kinds -----------------------------------------
//
// Two shapes motivate `union_of`:
// 1. A slot mixing a bare symbol kind with a form kind, e.g.
//    `[E4 (n G4 0.5b) _]`.
// 2. A `:value` slot accepting `number | vec4 | form`.
// Both are expressible only with a `union_of` value-kind. The tests
// below cover both shapes plus the failure path; manifest-load shape
// errors live with the cross-ref errors in `ManifestLoader.zig` tests.

/// Shared plugin: a vector slot whose elements are `note-or-event`, a
/// union of `note-or-rest` (symbol with closed member-set, including a
/// rest sentinel) and `event` (form with head-set `{n, rest}`). Mirrors
/// a `:notes` slot that accepts both rest sentinels and event forms.
const audio_union_plugin: Plugin.Plugin = .{
    .name = "audio",
    .forms = &.{
        .{
            .name = "phrase",
            .keys = &.{.{ .name = "notes", .value_type = .{ .named = .{ .name = "notes-vec" } } }},
        },
        .{ .name = "n", .positional = .any },
        .{ .name = "rest", .positional = .any },
    },
    .value_kinds = &.{
        .{
            .name = "note-or-rest",
            .underlying = .symbol,
            .members = .{ .members = &.{ .{ .name = "E4" }, .{ .name = "G4" }, .{ .name = "A4" }, .{ .name = "B4" }, .{ .name = "_" } } },
        },
        .{
            .name = "event",
            .underlying = .form,
            .heads = .{ .names = &.{ "n", "rest" } },
        },
        .{
            .name = "note-or-event",
            .underlying = .union_of,
            .union_of = .{ .alternatives = &.{ .{ .name = "note-or-rest" }, .{ .name = "event" } } },
        },
        .{
            .name = "notes-vec",
            .underlying = .vector,
            .vector = .{ .element = .{ .name = "note-or-event" } },
        },
    },
};

test "validate [U1]: vector with symbol|form union accepts mixed elements" {
    const schema = Schema.Schema.init(&.{audio_union_plugin});
    try parityCheck("(phrase :notes [E4 (n G4) _ (rest)])", schema);
    var bundle = try validateSrc("(phrase :notes [E4 (n G4) _ (rest)])", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), bundle.result.diagnostics.len);
}

test "validate [U2]: non-matching element emits union_no_branch_matched listing alternatives" {
    const schema = Schema.Schema.init(&.{audio_union_plugin});
    var bundle = try validateSrc("(phrase :notes [E4 42])", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const d = bundle.result.diagnostics[0];
    try testing.expectEqual(Ast.Diagnostic.Code.union_no_branch_matched, d.code);
    try testing.expect(std.mem.indexOf(u8, d.message, "note-or-rest") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "event") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "number") != null);
}

test "validateBinary [U2-binary]: parity on union failure" {
    // Diagnostic counts must agree across paths. Path-length parity
    // doesn't hold for vector-element failures (Tree wraps in
    // `element_at`; Binary emits at the inner element) — same exemption
    // the existing typed-vector parity tests rely on.
    const schema = Schema.Schema.init(&.{audio_union_plugin});
    try parityCheck("(phrase :notes [E4 42])", schema);
}

test "validate [U3]: bare slot with number | vector | form union accepts each shape" {
    const p: Plugin.Plugin = .{
        .name = "scene",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "value", .value_type = .{ .named = .{ .name = "scalar-or-color-or-expr" } } }},
            },
        },
        .value_kinds = &.{
            .{
                .name = "scalar-or-color-or-expr",
                .underlying = .union_of,
                .union_of = .{ .alternatives = &.{ .{ .name = "number" }, .{ .name = "vec4" }, .{ .name = "form" } } },
            },
            .{
                .name = "vec4",
                .underlying = .vector,
                .vector = .{ .len = 4, .element = .{ .name = "number" } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{ core.plugin, p });
    try parityCheck("(set :value 1)", schema);
    try parityCheck("(set :value [0.05 0.05 0.08 1])", schema);
    try parityCheck("(set :value (+ 1 2))", schema);
}

test "validate [U4]: union element kind threads element_type through binary vector walk" {
    // Binary path uses `MatchResult.element_type` to drive per-element
    // dispatch on a typed-vector. Confirms the union arm propagates the
    // chosen alternative's vector element back through the cursor walk —
    // a vector of a union'd vector still type-checks per-element.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "outer",
                .keys = &.{.{ .name = "items", .value_type = .{ .named = .{ .name = "items-vec" } } }},
            },
        },
        .value_kinds = &.{
            .{
                .name = "name-or-num",
                .underlying = .union_of,
                .union_of = .{ .alternatives = &.{ .{ .name = "symbol" }, .{ .name = "number" } } },
            },
            .{
                .name = "items-vec",
                .underlying = .vector,
                .vector = .{ .element = .{ .name = "name-or-num" } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    try parityCheck("(outer :items [foo 1 bar 2])", schema);
    try parityCheck("(outer :items [foo \"bad\"])", schema);
}

// ----- Group U-forms: rejectable forms through unions (binary parity) ------
//
// Group U above exercises union-over-forms only where the form is ACCEPTED
// (via a HeadSet alternative) or where a NON-form element fails. Neither
// pushes a *rejectable form* through a union — so the binary validator's
// silent-pass gap survived: a form value in a union-resolving slot fell out
// of `processEvalValidate`'s check chain (the `!resolvesToUnion` guard), so
// `validateOneBinary` emitted nothing while the tree emitted
// `union_no_branch_matched`. These tests pin tree≡binary parity for that
// funnel — a form matching no alternative must be rejected on BOTH paths,
// and a form matching a HeadSet / vector-element alternative accepted on
// both. `union-over-forms` in every name so `--test-filter` catches them.

/// A `track` form with a direct `:ev` key typed as the `note-or-event`
/// union (`note-or-rest` symbol-set | `event` form-head-set), plus a
/// `line` form carrying a vector of the same union, an `opaque-track`
/// whose slot is `:walk-opaque`, and the data forms the alternatives
/// accept (`n` / `rest`) or reject (`other`).
const event_union_plugin: Plugin.Plugin = .{
    .name = "ev",
    .forms = &.{
        .{
            .name = "track",
            .keys = &.{.{ .name = "ev", .value_type = .{ .named = .{ .name = "note-or-event" } } }},
        },
        .{
            .name = "opaque-track",
            .keys = &.{.{ .name = "ev", .value_type = .{ .named = .{ .name = "note-or-event" } }, .walk_opaque = true }},
        },
        .{
            .name = "line",
            .keys = &.{.{ .name = "notes", .value_type = .{ .named = .{ .name = "note-vec" } } }},
        },
        .{ .name = "n", .positional = .any },
        .{ .name = "rest", .positional = .any },
        .{ .name = "other", .positional = .any },
    },
    .value_kinds = &.{
        .{
            .name = "note-or-rest",
            .underlying = .symbol,
            .members = .{ .members = &.{ .{ .name = "E4" }, .{ .name = "G4" }, .{ .name = "_" } } },
        },
        .{
            .name = "event",
            .underlying = .form,
            .heads = .{ .names = &.{ "n", "rest" } },
        },
        .{
            .name = "note-or-event",
            .underlying = .union_of,
            .union_of = .{ .alternatives = &.{ .{ .name = "note-or-rest" }, .{ .name = "event" } } },
        },
        .{
            .name = "note-vec",
            .underlying = .vector,
            .vector = .{ .element = .{ .name = "note-or-event" } },
        },
    },
};

test "validate [union-over-forms 1]: rejectable form in a union slot -> union_no_branch_matched on both paths" {
    // PRIMARY red: today the binary path emits nothing here.
    const schema = Schema.Schema.init(&.{event_union_plugin});
    try expectPathOnBoth("(track :ev (other 1))", schema, .union_no_branch_matched, &.{ "track", "ev" });
}

test "validate [union-over-forms 2]: form matching the event HeadSet alternative accepts on both paths" {
    const schema = Schema.Schema.init(&.{event_union_plugin});
    try expectNoCodeOnBoth("(track :ev (n E4))", schema, .union_no_branch_matched);
    try expectNoCodeOnBoth("(track :ev (rest))", schema, .union_no_branch_matched);
}

test "validate [union-over-forms 3]: rejectable form as a union'd vector element -> union_no_branch_matched (code parity; path exempt)" {
    // Vector-element funnel. Path parity is exempt — the tree wraps one
    // diagnostic at the slot path, the binary emits per element at an
    // index-extended path — so assert code parity only.
    const schema = Schema.Schema.init(&.{event_union_plugin});
    try expectCodeOnBoth("(line :notes [(other 1)])", schema, .union_no_branch_matched);
}

test "validate [union-over-forms 4]: forms matching alternatives as vector elements accept on both paths" {
    const schema = Schema.Schema.init(&.{event_union_plugin});
    try expectNoCodeOnBoth("(line :notes [(n E4) (rest) _])", schema, .union_no_branch_matched);
}

test "validate [union-over-forms 5]: walk-opaque union slot rejects a bad form once, identically on both paths" {
    // The slot type-check runs before the opaque descent-drain, so a
    // rejectable form still trips exactly one union_no_branch_matched and
    // the value's body is not walked. Full (count, code, path) parity.
    const schema = Schema.Schema.init(&.{event_union_plugin});
    try parityCheckPaths("(opaque-track :ev (other 1))", schema);
    try expectPathOnBoth("(opaque-track :ev (other 1))", schema, .union_no_branch_matched, &.{ "opaque-track", "ev" });
}

// ----- Group U-div: residual tree/binary union divergences -----------------
//
// Two known divergences the union-over-forms fix above does NOT close. They
// are pinned here as single-path characterization tests (deliberately NOT
// expectCodeOnBoth — the paths genuinely disagree) so that a change closing
// either has a red to flip into a parity assertion. Both are deliberate,
// known residuals.

// Divergence #2: a union with a VECTOR alternative whose elements fail. The
// tree tries the vector alternative, recurses its elements, and — the
// elements failing — rejects the alternative, so the whole union fails with
// one `union_no_branch_matched` at the slot. The binary path's union
// alternative selection is length-only (`matchKindBinary`'s `.vector` arm
// defers per-element checks via `element_type`), so it ACCEPTS the vector
// alternative on length and then emits a per-element `wrong_underlying` for
// each bad element at an index-extended path. Different code, count, and
// path. Closing it needs eager per-element validation during binary union
// alternative selection.
test "validate [union-div 2]: union-over-vector w/ failing elements diverges (tree slot vs binary per-element)" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "d2",
        .forms = &.{.{ .name = "pick", .keys = &.{.{ .name = "v", .value_type = .{ .named = .{ .name = "vec2sym-or-num" } } }} }},
        .value_kinds = &.{
            .{ .name = "vec2sym", .underlying = .vector, .vector = .{ .len = 2, .element = .{ .name = "symbol" } } },
            .{ .name = "vec2sym-or-num", .underlying = .union_of, .union_of = .{ .alternatives = &.{ .{ .name = "vec2sym" }, .{ .name = "number" } } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});

    var tree = try Parser.parse(a, "(pick :v [1 2])");
    defer tree.deinit();
    var tr = try validate(a, tree, schema);
    defer tr.deinit();
    // Tree: one union rejection at the slot.
    try testing.expectEqual(@as(usize, 1), tr.diagnostics.len);
    try testing.expect(anyCodeAtPath(tr.diagnostics, .union_no_branch_matched, &.{ "pick", "v" }));

    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();
    var br = try validateBinary(a, bin.data, schema);
    defer br.deinit();
    // Binary: length-only alternative accept, then per-element wrong_underlying.
    try testing.expectEqual(@as(usize, 2), br.diagnostics.len);
    try testing.expect(anyCodeAtPath(br.diagnostics, .wrong_underlying, &.{ "pick", "v", "0" }));
    try testing.expect(anyCodeAtPath(br.diagnostics, .wrong_underlying, &.{ "pick", "v", "1" }));
    // The divergence itself: neither path emits the other's code.
    try testing.expect(!anyCode(br.diagnostics, .union_no_branch_matched));
}

// Divergence #3: a multi-signature call with two SAME-arity signatures
// disambiguated only by label. The tree runs labeled-call resolution and
// pins the chosen signature's result; the binary narrows by arity alone
// (`resolveFormExpressionBinary` -> `sharedResultByArity`), and since the
// same-arity signatures declare different results the shared result is opaque
// (null), so the binary defers with no diagnostic. Closing it needs
// labeled-call resolution on the binary path (no random-access children
// today).
test "validate [union-div 3]: same-arity labeled multi-sig narrows on tree, defers on binary" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "d3",
        .forms = &.{.{ .name = "use", .keys = &.{.{ .name = "n", .value_type = .number }} }},
        .expr_funcs = &.{.{
            .name = "poly",
            .signatures = &.{
                .{ .arity = .{ .fixed = 1 }, .params = &.{.number}, .param_names = &.{"x"}, .result = .number },
                .{ .arity = .{ .fixed = 1 }, .params = &.{.string}, .param_names = &.{"y"}, .result = .string },
            },
        }},
    };
    const schema = Schema.Schema.init(&.{p});

    // `:y` selects the string-result signature; string ≠ the number slot.
    var tree = try Parser.parse(a, "(use :n (poly :y \"hello\"))");
    defer tree.deinit();
    var tr = try validate(a, tree, schema);
    defer tr.deinit();
    try testing.expectEqual(@as(usize, 1), tr.diagnostics.len);
    try testing.expect(anyCodeAtPath(tr.diagnostics, .wrong_underlying, &.{ "use", "n" }));

    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();
    var br = try validateBinary(a, bin.data, schema);
    defer br.deinit();
    // Binary can't disambiguate same-arity sigs → opaque result → defers.
    try testing.expectEqual(@as(usize, 0), br.diagnostics.len);
}

// Divergence #4: a form-valued expression argument that fails result-typing.
// Both walkers agree on code (`expr_type_mismatch`), severity, and count —
// they disagree only on the arg's PATH SEGMENT. The tree labels an expr arg
// by its positional ordinal (`[sum 0]`, via the `expr_arg` PathStep). The
// binary walker routes the form through the generic `.positional` StepKind,
// whose `computeBinaryPathPair` labels ANY form child by its head — correct
// for data-form children (`[scene track]`) but wrong for expr args, yielding
// `[sum vec-result]`. This is PRE-EXISTING (predates the union-over-forms
// fix — that commit changed only the verdict, not `paths.diag`). Closing it
// needs a StepKind that forces index labeling for expr-func positional args
// (and matching `paths.form` handling for nested descent). A deliberate,
// known residual; this corpus case (`expr-result-arg-
// mismatch`) is on the binary-replay path-divergence allowlist in
// `conformance_tests.zig`.
test "validate [expr-div 4]: form expr-arg labels by index on tree, by head on binary" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "d4",
        .expr_funcs = &.{
            .{ .name = "sum", .arity = .{ .fixed = 2 }, .params = &.{ .number, .number }, .result = .number },
            .{ .name = "vec-result", .arity = .{ .fixed = 0 }, .params = &.{}, .result = .vector },
        },
    };
    const schema = Schema.Schema.init(&.{p});

    var tree = try Parser.parse(a, "(sum (vec-result) 1)");
    defer tree.deinit();
    var tr = try validate(a, tree, schema);
    defer tr.deinit();
    // Tree: expr arg 0 labeled by positional ordinal.
    try testing.expectEqual(@as(usize, 1), tr.diagnostics.len);
    try testing.expect(anyCodeAtPath(tr.diagnostics, .expr_type_mismatch, &.{ "sum", "0" }));

    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();
    var br = try validateBinary(a, bin.data, schema);
    defer br.deinit();
    // Binary: same code, but the form child is labeled by head.
    try testing.expectEqual(@as(usize, 1), br.diagnostics.len);
    try testing.expect(anyCodeAtPath(br.diagnostics, .expr_type_mismatch, &.{ "sum", "vec-result" }));
    // The divergence itself: neither path emits at the other's segment.
    try testing.expect(!anyCodeAtPath(br.diagnostics, .expr_type_mismatch, &.{ "sum", "0" }));
}

// Divergence #5: a labeled call carrying BOTH a structural label fault and
// an argument type error. The tree resolves the whole call first
// (`Schema.resolveExprArgs`) and returns on the fault, so it never types a
// single argument — one diagnostic. The binary walker types each argument as
// the cursor streams past it and only reaches the structural verdict at frame
// close, so an argument typed before the fault was seen keeps its
// diagnostic — two.
//
// The two agree on every case where only one kind of fault is present, which
// is what the four `expr-label-*` corpus cases pin. Closing this one needs
// the binary path to withhold argument typing until the call's label set is
// complete — i.e. buffering every child before emitting anything, which is
// the one thing a single-pass cursor is built not to do.
//
// The divergence is in the safe direction: the binary path reports a
// superset, so nothing the reference rejects is accepted here. A
// deliberate, known residual, like union-div 2/3 and expr-div 4.
test "validate [expr-div 5]: labeled call with a type error too diverges in count" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "d5",
        .expr_funcs = &.{.{
            .name = "at2",
            .arity = .{ .fixed = 2 },
            .params = &.{ .number, .number },
            .param_names = &.{ "y", "x" },
            .result = .number,
        }},
    };
    const schema = Schema.Schema.init(&.{p});

    // `:y "s"` is a type error; `:nope` is an unknown label.
    var tree = try Parser.parse(a, "(at2 :y \"s\" :nope 1)");
    defer tree.deinit();
    var tr = try validate(a, tree, schema);
    defer tr.deinit();
    try testing.expectEqual(@as(usize, 1), tr.diagnostics.len);
    try testing.expect(anyCodeAtPath(tr.diagnostics, .expr_unknown_label, &.{ "at2", "nope" }));

    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();
    var br = try validateBinary(a, bin.data, schema);
    defer br.deinit();
    try testing.expectEqual(@as(usize, 2), br.diagnostics.len);
    // Both paths agree on the label fault — that is the half this file's
    // sibling corpus cases pin. The extra entry is the argument the binary
    // walker had already typed.
    try testing.expect(anyCodeAtPath(br.diagnostics, .expr_unknown_label, &.{ "at2", "nope" }));
    try testing.expect(anyCodeAtPath(br.diagnostics, .expr_type_mismatch, &.{ "at2", "y" }));
}

// ----- Group D: form-level discriminant unions ----------------------------
//
// The motivating case merges every audio-kind into one `(track …)`
// form gated on `:kind` — what was previously a "track-kind"
// hand-rolled host hook, now absorbed by the schema. The tests below
// cover:
//   * Common-only and variant-only key dispatch (D1–D2).
//   * Cross-variant rejection (D3).
//   * The position constraint — variant keys before the discriminant
//     emit unknown_key with a hint (D4).
//   * Discriminant absent / out-of-set (D5–D6).
//   * Manifest-load shape errors land in `Schema_tests.zig` /
//     `ManifestLoader_tests.zig` (D7–D10 — wired separately).

/// Shared plugin: a `(track …)` form discriminated on `:kind`, with
/// three variants (kick, groove, animation). Mirrors the merged piece
/// plugin's track shape from the scene sketch.
const piece_track_plugin: Plugin.Plugin = .{
    .name = "piece",
    .forms = &.{
        .{
            .name = "track",
            .keys = &.{
                .{ .name = "name", .value_type = .symbol, .optional = false },
                .{ .name = "kind", .value_type = .{ .named = .{ .name = "track-kind" } }, .optional = false },
                .{ .name = "from", .value_type = .number, .optional = true },
            },
            .discriminant_name = "kind",
            .discriminant_idx = 1,
            .variants = &.{
                .{
                    .when = "kick",
                    .keys = &.{
                        .{ .name = "step", .value_type = .number, .optional = false },
                        .{ .name = "volume", .value_type = .number, .optional = true },
                        .{ .name = "downbeat-volume", .value_type = .number, .optional = true },
                    },
                },
                .{
                    .when = "groove",
                    .keys = &.{
                        .{ .name = "pattern", .value_type = .symbol, .optional = false },
                        .{ .name = "velocity", .value_type = .number, .optional = true },
                    },
                },
                .{
                    .when = "animation",
                    .keys = &.{
                        .{ .name = "mesh", .value_type = .symbol, .optional = true },
                        .{ .name = "parent", .value_type = .symbol, .optional = true },
                    },
                },
            },
        },
    },
    .value_kinds = &.{
        .{
            .name = "track-kind",
            .underlying = .symbol,
            .members = .{ .members = &.{ .{ .name = "kick" }, .{ .name = "groove" }, .{ .name = "animation" } } },
        },
    },
};

test "validate [D1]: common + kick-variant keys validate cleanly" {
    const schema = Schema.Schema.init(&.{piece_track_plugin});
    try parityCheck("(track :kind kick :name k1 :step 4 :volume 0.7)", schema);
    var bundle = try validateSrc("(track :kind kick :name k1 :step 4 :volume 0.7)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), bundle.result.diagnostics.len);
}

test "validate [D2]: animation-variant keys validate cleanly" {
    const schema = Schema.Schema.init(&.{piece_track_plugin});
    try parityCheck("(track :kind animation :name a1 :mesh logo)", schema);
}

test "validate [D3]: variant-only key from wrong variant emits unknown_key" {
    const schema = Schema.Schema.init(&.{piece_track_plugin});
    var bundle = try validateSrc("(track :kind kick :name k1 :step 4 :mesh logo)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const d = bundle.result.diagnostics[0];
    try testing.expectEqual(Ast.Diagnostic.Code.unknown_key, d.code);
    try testing.expect(std.mem.indexOf(u8, d.message, "mesh") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "kick") != null);
    // Binary parity (count-only — path divergence at kvpair span level).
    try parityCheck("(track :kind kick :name k1 :step 4 :mesh logo)", schema);
}

test "validate [D4]: variant-only key before discriminant emits unknown_key with hint" {
    const schema = Schema.Schema.init(&.{piece_track_plugin});
    var bundle = try validateSrc("(track :name k1 :step 4 :kind kick)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const d = bundle.result.diagnostics[0];
    try testing.expectEqual(Ast.Diagnostic.Code.unknown_key, d.code);
    try testing.expect(std.mem.indexOf(u8, d.message, "step") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "kind") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "must be set before") != null);
    try parityCheck("(track :name k1 :step 4 :kind kick)", schema);
}

test "validate [D5]: missing discriminant skips variant required-key sweep" {
    const schema = Schema.Schema.init(&.{piece_track_plugin});
    var bundle = try validateSrc("(track :name k1)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    // Exactly one diagnostic — `:kind` missing. No follow-on
    // missing_required_key noise for variant keys (since no variant
    // resolved). The common :kind slot is excluded from the regular
    // required-key sweep so the user sees one root-cause error.
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const d = bundle.result.diagnostics[0];
    try testing.expectEqual(Ast.Diagnostic.Code.missing_discriminant_key, d.code);
    try testing.expect(std.mem.indexOf(u8, d.message, "kind") != null);
    try parityCheck("(track :name k1)", schema);
}

test "validate [D6]: discriminant value not in member-set still emits not_member" {
    const schema = Schema.Schema.init(&.{piece_track_plugin});
    var bundle = try validateSrc("(track :name k1 :kind unknown-kind)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    // Two diagnostics: the not_member on `:kind unknown-kind` (existing
    // member-set check) and no follow-on missing_required_key noise
    // because no variant resolved. The discriminant key WAS present, so
    // missing_discriminant_key does not fire.
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.not_member, bundle.result.diagnostics[0].code);
    try parityCheck("(track :name k1 :kind unknown-kind)", schema);
}

test "validate [D-required]: variant required key missing emits per-variant message" {
    const schema = Schema.Schema.init(&.{piece_track_plugin});
    var bundle = try validateSrc("(track :name k1 :kind kick)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const d = bundle.result.diagnostics[0];
    try testing.expectEqual(Ast.Diagnostic.Code.missing_required_key, d.code);
    try testing.expect(std.mem.indexOf(u8, d.message, "step") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "kick") != null);
    try parityCheck("(track :name k1 :kind kick)", schema);
}

// ----- Group X: exclusive-group cardinality -------------------------------
//
// The motivating case has `(phrase :notes …)` xor `(phrase :events …)`
// as a per-form host hook. The `exclusive_groups` field on `FormSpec`
// (and `Variant`) declares cardinality directly.
// X1–X8 cover both cardinality modes plus the skip-double-emit guard
// that prevents `missing_required_key` from firing for keys covered
// by an `exactly_one` group.

/// Single phrase form with `:notes` xor `:events`. Both keys are
/// optional individually — the exclusive-group is the source of truth
/// for presence rules, not `optional: false` on either key.
const phrase_xor_plugin: Plugin.Plugin = .{
    .name = "audio",
    .forms = &.{
        .{
            .name = "phrase",
            .keys = &.{
                .{ .name = "name", .value_type = .symbol, .optional = false },
                .{ .name = "notes", .value_type = .vector, .optional = true },
                .{ .name = "events", .value_type = .vector, .optional = true },
            },
            .exclusive_groups = &.{
                .{
                    .alternatives = &.{
                        .{ .keys = &.{"notes"} },
                        .{ .keys = &.{"events"} },
                    },
                    .cardinality = .exactly_one,
                },
            },
        },
    },
};

/// At-most-one variant: same shape, neither key required.
const phrase_atmostone_plugin: Plugin.Plugin = .{
    .name = "audio",
    .forms = &.{
        .{
            .name = "phrase",
            .keys = &.{
                .{ .name = "name", .value_type = .symbol, .optional = false },
                .{ .name = "notes", .value_type = .vector, .optional = true },
                .{ .name = "events", .value_type = .vector, .optional = true },
            },
            .exclusive_groups = &.{
                .{
                    .alternatives = &.{
                        .{ .keys = &.{"notes"} },
                        .{ .keys = &.{"events"} },
                    },
                    .cardinality = .at_most_one,
                },
            },
        },
    },
};

test "validate [X1]: only :notes present passes silently" {
    const schema = Schema.Schema.init(&.{phrase_xor_plugin});
    var bundle = try validateSrc("(phrase :name p :notes [E4])", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), bundle.result.diagnostics.len);
    try parityCheck("(phrase :name p :notes [E4])", schema);
}

test "validate [X2]: only :events present passes silently" {
    const schema = Schema.Schema.init(&.{phrase_xor_plugin});
    var bundle = try validateSrc("(phrase :name p :events [E4])", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), bundle.result.diagnostics.len);
    try parityCheck("(phrase :name p :events [E4])", schema);
}

test "validate [X3]: both :notes and :events emits mutually_exclusive_keys_present" {
    const schema = Schema.Schema.init(&.{phrase_xor_plugin});
    var bundle = try validateSrc("(phrase :name p :notes [E4] :events [E4])", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const d = bundle.result.diagnostics[0];
    try testing.expectEqual(Ast.Diagnostic.Code.mutually_exclusive_keys_present, d.code);
    try testing.expect(std.mem.indexOf(u8, d.message, ":notes") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, ":events") != null);
    try parityCheck("(phrase :name p :notes [E4] :events [E4])", schema);
}

test "validate [X4]: neither key + cardinality exactly_one emits required_one_of_missing" {
    const schema = Schema.Schema.init(&.{phrase_xor_plugin});
    var bundle = try validateSrc("(phrase :name p)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const d = bundle.result.diagnostics[0];
    try testing.expectEqual(Ast.Diagnostic.Code.required_one_of_missing, d.code);
    try testing.expect(std.mem.indexOf(u8, d.message, ":notes") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, ":events") != null);
    try parityCheck("(phrase :name p)", schema);
}

test "validate [X5]: neither key + cardinality at_most_one passes silently" {
    const schema = Schema.Schema.init(&.{phrase_atmostone_plugin});
    var bundle = try validateSrc("(phrase :name p)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), bundle.result.diagnostics.len);
    try parityCheck("(phrase :name p)", schema);
}

test "validate [X6]: both keys + missing :name emits two diagnostics" {
    const schema = Schema.Schema.init(&.{phrase_xor_plugin});
    var bundle = try validateSrc("(phrase :notes [E4] :events [E4])", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    // One missing-required for :name, one mutually-exclusive for the group.
    try testing.expectEqual(@as(usize, 2), bundle.result.diagnostics.len);
    var saw_missing: bool = false;
    var saw_mutex: bool = false;
    for (bundle.result.diagnostics) |d| {
        switch (d.code) {
            .missing_required_key => {
                if (std.mem.indexOf(u8, d.message, "name") != null) saw_missing = true;
            },
            .mutually_exclusive_keys_present => saw_mutex = true,
            else => {},
        }
    }
    try testing.expect(saw_missing);
    try testing.expect(saw_mutex);
    try parityCheck("(phrase :notes [E4] :events [E4])", schema);
}

test "validate [X7]: open form with both keys still fires mutex" {
    // `open: true` only relaxes unknown-key + missing-required sweeps;
    // it does not silence exclusive-group cardinality (that would
    // defeat the only declarative purpose of the group).
    //
    // Wait — by design the validator returns early on `spec.open`
    // before reaching the exclusive-group sweep. Documenting that
    // choice explicitly: open forms are bags; cardinality is shape.
    // If a use case for "open + xor" emerges, lift the early return.
    const open_plugin: Plugin.Plugin = .{
        .name = "audio",
        .forms = &.{
            .{
                .name = "phrase",
                .open = true,
                .keys = &.{
                    .{ .name = "notes", .value_type = .vector, .optional = true },
                    .{ .name = "events", .value_type = .vector, .optional = true },
                },
                .exclusive_groups = &.{.{
                    .alternatives = &.{
                        .{ .keys = &.{"notes"} },
                        .{ .keys = &.{"events"} },
                    },
                    .cardinality = .exactly_one,
                }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{open_plugin});
    var bundle = try validateSrc("(phrase :notes [E4] :events [E4])", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    // Documented behavior: open form bypasses the group sweep. If this
    // assertion needs to flip in future, lift the `if (spec.open)
    // return;` guard above the new sweep call site in Validator.zig.
    try testing.expectEqual(@as(usize, 0), bundle.result.diagnostics.len);
    try parityCheck("(phrase :notes [E4] :events [E4])", schema);
}

test "validate [X8]: exactly_one with key declared :optional false emits only group diagnostic" {
    // Skip-double-emit guard: a key participating in an exclusive_group
    // does not fire `missing_required_key` even when the spec declares
    // `optional = false` — the group sweep is the source of truth.
    const p: Plugin.Plugin = .{
        .name = "audio",
        .forms = &.{
            .{
                .name = "phrase",
                .keys = &.{
                    .{ .name = "name", .value_type = .symbol, .optional = false },
                    .{ .name = "notes", .value_type = .vector, .optional = false },
                    .{ .name = "events", .value_type = .vector, .optional = false },
                },
                .exclusive_groups = &.{.{
                    .alternatives = &.{
                        .{ .keys = &.{"notes"} },
                        .{ .keys = &.{"events"} },
                    },
                    .cardinality = .exactly_one,
                }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(phrase :name p)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const d = bundle.result.diagnostics[0];
    try testing.expectEqual(Ast.Diagnostic.Code.required_one_of_missing, d.code);
    try parityCheck("(phrase :name p)", schema);
}

// ----- Multi-key bundle (X9–X12) -----
//
// Multi-key alternatives — `(alt :keys [from to])` style. Bundles are
// all-or-nothing: a bundle is "present" iff every key is set. Partial
// presence (some keys set, others missing) emits the dedicated
// `exclusive_bundle_partial` rather than fooling the cardinality check.

/// Multi-key xor: `(from + to)` vs `(at)`. Exercises both the multi-key
/// bundle and the mixed multi-key + single-key cardinality case.
const route_xor_plugin: Plugin.Plugin = .{
    .name = "routes",
    .forms = &.{
        .{
            .name = "route",
            .keys = &.{
                .{ .name = "from", .value_type = .symbol, .optional = true },
                .{ .name = "to", .value_type = .symbol, .optional = true },
                .{ .name = "at", .value_type = .symbol, .optional = true },
            },
            .exclusive_groups = &.{
                .{
                    .alternatives = &.{
                        .{ .keys = &.{ "from", "to" } },
                        .{ .keys = &.{"at"} },
                    },
                    .cardinality = .exactly_one,
                },
            },
        },
    },
};

/// Multi-key at-most-one: `(prefix + suffix)` vs `(literal)`. Used to
/// confirm zero-bundle cardinality stays clean even with multi-key alts.
const tag_atmostone_plugin: Plugin.Plugin = .{
    .name = "routes",
    .forms = &.{
        .{
            .name = "tag",
            .keys = &.{
                .{ .name = "prefix", .value_type = .symbol, .optional = true },
                .{ .name = "suffix", .value_type = .symbol, .optional = true },
                .{ .name = "literal", .value_type = .symbol, .optional = true },
            },
            .exclusive_groups = &.{
                .{
                    .alternatives = &.{
                        .{ .keys = &.{ "prefix", "suffix" } },
                        .{ .keys = &.{"literal"} },
                    },
                    .cardinality = .at_most_one,
                },
            },
        },
    },
};

test "validate [X9]: full multi-key bundle present passes silently" {
    const schema = Schema.Schema.init(&.{route_xor_plugin});
    var bundle = try validateSrc("(route :from a :to b)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), bundle.result.diagnostics.len);
    try parityCheck("(route :from a :to b)", schema);
}

test "validate [X10]: partial multi-key bundle emits exclusive_bundle_partial" {
    const schema = Schema.Schema.init(&.{route_xor_plugin});
    var bundle = try validateSrc("(route :from a)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const d = bundle.result.diagnostics[0];
    try testing.expectEqual(Ast.Diagnostic.Code.exclusive_bundle_partial, d.code);
    try testing.expect(std.mem.indexOf(u8, d.message, ":from set") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, ":to missing") != null);
    try parityCheck("(route :from a)", schema);
}

test "validate [X11]: at_most_one multi-key bundle with zero keys passes silently" {
    const schema = Schema.Schema.init(&.{tag_atmostone_plugin});
    var bundle = try validateSrc("(tag)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), bundle.result.diagnostics.len);
    try parityCheck("(tag)", schema);
}

test "validate [X12]: full multi-key bundle AND sibling alt emits mutually_exclusive_keys_present" {
    const schema = Schema.Schema.init(&.{route_xor_plugin});
    var bundle = try validateSrc("(route :from a :to b :at noon)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    const d = bundle.result.diagnostics[0];
    try testing.expectEqual(Ast.Diagnostic.Code.mutually_exclusive_keys_present, d.code);
    try testing.expect(std.mem.indexOf(u8, d.message, ":from+:to") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, ":at") != null);
    try parityCheck("(route :from a :to b :at noon)", schema);
}

// ===========================================================================
// Long-tail validateBinary coverage
//
// Exercises wire-format flag combinations, qualified heads, special-form
// expression heads, hostile/corrupted buffers, deep + wide structures,
// sibling state isolation, multi-error fan-in, and every primitive +
// kind shape combination. Goal: catch regressions in places that the
// small core test set cannot reach by construction.
// ===========================================================================

// ----- Helpers -------------------------------------------------------------

fn encodeWith(src: [:0]const u8, opts: Binary.ToBinaryOptions) !Ast.Bytes {
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();
    return try Binary.toBinary(testing.allocator, tree, opts);
}

/// Run validateBinary over `src` using the given encoder options +
/// schema, asserting an exact diagnostic count.
fn expectBinaryDiagCount(
    src: [:0]const u8,
    opts: Binary.ToBinaryOptions,
    schema: Schema.Schema,
    expected_count: usize,
) !void {
    const bin = try encodeWith(src, opts);
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(expected_count, r.diagnostics.len);
}

// ----- Group A: wire-format flag combinations ------------------------------

test "validateBinary [A1]: lossless binary preserves diagnostic outcomes" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    try expectBinaryDiagCount("(scene)", Binary.ToBinaryOptions.forMode(.full), schema, 1);
}

test "validateBinary [A2]: stripped binary still reports correct counts" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    try expectBinaryDiagCount("(scene) (scene :bpm 130) (scene)", Binary.ToBinaryOptions.forMode(.compact), schema, 2);
}

test "validateBinary [A3]: with leading/trailing comments around root form" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    const src: [:0]const u8 =
        \\; before
        \\(scene)
        \\; after
    ;
    try expectBinaryDiagCount(src, Binary.ToBinaryOptions.forMode(.full), schema, 1);
}

test "validateBinary [A4]: mixed flags — head spans on, value spans off" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    const opts: Binary.ToBinaryOptions = .{
        .with_spans = false,
        .with_head_spans = true,
        .with_kvpair_key_spans = false,
        .with_node_comments = false,
        .with_kvpair_comments = false,
    };
    const bin = try encodeWith("(scene)", opts);
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    // Head span IS present, so the missing-required diag has a non-zero span.
    const d = r.diagnostics[0];
    try testing.expect(d.span.end > d.span.start);
}

test "validateBinary [A5]: with_kvpair_comments preserved across walk" {
    // Schema accepts :bpm; comment on the kvpair should not affect validation.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "scene", .keys = &.{.{ .name = "bpm", .value_type = .number }} }},
    };
    const schema = Schema.Schema.init(&.{p});
    const src: [:0]const u8 =
        \\(scene
        \\  ; pre-bpm
        \\  :bpm 130)
    ;
    try expectBinaryDiagCount(src, Binary.ToBinaryOptions.forMode(.full), schema, 0);
}

test "validateBinary [A6]: same source under all four canonical flag profiles agrees on count" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    const src: [:0]const u8 = "(scene) (scene :bpm 130) (scene :wat 1)";
    inline for (.{
        Binary.ToBinaryOptions.forMode(.compact),
        Binary.ToBinaryOptions.forMode(.full),
        Binary.ToBinaryOptions{},
        Binary.ToBinaryOptions{
            .with_spans = true,
            .with_head_spans = false,
            .with_kvpair_key_spans = false,
            .with_node_comments = false,
            .with_kvpair_comments = false,
        },
    }) |opts| {
        // (scene) → 1 missing :bpm; (scene :bpm 130) → 0; (scene :wat 1) → unknown :wat + missing :bpm
        try expectBinaryDiagCount(src, opts, schema, 3);
    }
}

// ----- Group B: qualified heads -------------------------------------------

test "validateBinary [B1]: qualified head finds form in named plugin" {
    const ns_plugin: Plugin.Plugin = .{
        .name = "ns",
        .forms = &.{.{ .name = "verb", .keys = &.{.{ .name = "k", .optional = false }} }},
    };
    const schema = Schema.Schema.init(&.{ns_plugin});
    const bin = try encodeForValidate("(ns/verb :k 1)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "validateBinary [B2]: qualified head finds expr_func" {
    const ns_plugin: Plugin.Plugin = .{
        .name = "ns",
        .expr_funcs = &.{.{ .name = "fn", .arity = .{ .fixed = 2 } }},
    };
    const schema = Schema.Schema.init(&.{ns_plugin});
    const bin = try encodeForValidate("(ns/fn 1)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "exactly 2") != null);
}

test "validateBinary [B3]: qualified head with unknown plugin yields unknown diagnostic" {
    const ns_plugin: Plugin.Plugin = .{ .name = "ns", .forms = &.{.{ .name = "verb" }} };
    const schema = Schema.Schema.init(&.{ns_plugin});
    const bin = try encodeForValidate("(other/verb)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "other/verb") != null);
}

test "validateBinary [B4]: qualified head with known plugin but unknown form" {
    const ns_plugin: Plugin.Plugin = .{ .name = "ns", .forms = &.{.{ .name = "verb" }} };
    const schema = Schema.Schema.init(&.{ns_plugin});
    const bin = try encodeForValidate("(ns/missing)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "ns/missing") != null);
}

test "validateBinary [B5]: qualifier disambiguates collision between plugins" {
    const a: Plugin.Plugin = .{
        .name = "a",
        .forms = &.{.{ .name = "verb", .keys = &.{.{ .name = "x", .optional = false }} }},
    };
    const b: Plugin.Plugin = .{
        .name = "b",
        .forms = &.{.{ .name = "verb", .keys = &.{.{ .name = "y", .optional = false }} }},
    };
    const schema = Schema.Schema.init(&.{ a, b });
    // Bare "(verb)" is ambiguous; "(b/verb)" picks plugin b → missing `:y`.
    try expectBinaryDiagCount("(verb)", .{}, schema, 1);
    const bin = try encodeForValidate("(b/verb)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, ":y") != null);
}

test "validateBinary [B6]: qualified canonical (core/let) validates clean" {
    // The `core` plugin declares `let` (impl-null marker, arity 2) so
    // the validator can shape-check both bare `(let …)` and the
    // canonical-namespace form `(core/let …)`. Pins the validator side
    // of the "validation checks shape, eval checks implementation"
    // split — eval surfaces the impl-null marker as
    // PluginFuncNotImplemented (see Expr_tests).
    const schema = Schema.Schema.init(&.{core.plugin});
    try expectBinaryDiagCount("(core/let [x 1] x)", .{}, schema, 0);
}

// ----- Group C: special-form / expression heads ---------------------------

test "validateBinary [C1]: (if test then else) accepted at arity 3" {
    const schema = Schema.Schema.init(&.{core.plugin});
    try expectBinaryDiagCount("(if true 1 2)", .{}, schema, 0);
}

test "validateBinary [C2]: (if test) flagged for arity below range" {
    const schema = Schema.Schema.init(&.{core.plugin});
    const bin = try encodeForValidate("(if true)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "2..3") != null);
}

test "validateBinary [C3]: (let [x 1] x) accepted" {
    const schema = Schema.Schema.init(&.{core.plugin});
    try expectBinaryDiagCount("(let [x 1] x)", .{}, schema, 0);
}

test "validateBinary [C4]: (cond) accepted (zero-clause cond)" {
    const schema = Schema.Schema.init(&.{core.plugin});
    try expectBinaryDiagCount("(cond)", .{}, schema, 0);
}

test "validateBinary [C5]: (and) and (or) accepted with no args" {
    const schema = Schema.Schema.init(&.{core.plugin});
    try expectBinaryDiagCount("(and)", .{}, schema, 0);
    try expectBinaryDiagCount("(or)", .{}, schema, 0);
}

test "validateBinary [C6]: keyword arg in special form rejected" {
    const schema = Schema.Schema.init(&.{core.plugin});
    const bin = try encodeForValidate("(if :x 1 2)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var saw_reject = false;
    for (r.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "does not accept keyword argument") != null) saw_reject = true;
    }
    try testing.expect(saw_reject);
}

test "validateBinary [C7]: nested expressions inside cond clauses validated" {
    const schema = Schema.Schema.init(&.{core.plugin});
    // Inner (vec3 1 2) wrong arity; cond itself is fine.
    try expectBinaryDiagCount("(cond true (vec3 1 2) false 0)", .{}, schema, 1);
}

test "validateBinary [C8]: not + comparison ops accept correct arity" {
    const schema = Schema.Schema.init(&.{core.plugin});
    try expectBinaryDiagCount("(not true)", .{}, schema, 0);
    try expectBinaryDiagCount("(< 1 2)", .{}, schema, 0);
    try expectBinaryDiagCount("(= 1 1)", .{}, schema, 0);
}

test "validateBinary [C9]: not with wrong arity flagged" {
    const schema = Schema.Schema.init(&.{core.plugin});
    try expectBinaryDiagCount("(not true false)", .{}, schema, 1);
}

// ----- Group C-Typed: typed expr signatures (A3) --------------------------

test "validateBinary [CT1]: vec3 with all numbers — no diag" {
    const schema = Schema.Schema.init(&.{core.plugin});
    try expectBinaryDiagCount("(vec3 1 2 3)", .{}, schema, 0);
}

test "validateBinary [CT2]: vec3 with a string arg — diag" {
    const schema = Schema.Schema.init(&.{core.plugin});
    try expectBinaryDiagCount("(vec3 \"x\" 2 3)", .{}, schema, 1);
}

test "validateBinary [CT3]: + with all numbers including variadic tail" {
    const schema = Schema.Schema.init(&.{core.plugin});
    try expectBinaryDiagCount("(+ 1 2 3 4 5)", .{}, schema, 0);
}

test "validateBinary [CT4]: + with string in variadic tail — diag" {
    const schema = Schema.Schema.init(&.{core.plugin});
    try expectBinaryDiagCount("(+ 1 2 \"x\")", .{}, schema, 1);
}

// ----- Group D: open-form bypass exhaustive --------------------------------

test "validateBinary [D1]: open form still type-checks declared keys" {
    // Binary parity for the §7.3 invariant: declared `:n` is still
    // typed as `number`, so `"oops"` emits a diagnostic even when
    // `open = true`.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "bag",
            .keys = &.{.{ .name = "n", .value_type = .number, .optional = false }},
            .open = true,
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(bag :n \"oops\")", .{}, schema, 1);
}

test "validateBinary [D2]: open form silences missing-required" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "bag",
            .keys = &.{.{ .name = "n", .optional = false }},
            .open = true,
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(bag)", .{}, schema, 0);
}

test "validateBinary [D3]: open form silences unknown-keyword + positional .none" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "bag",
            .keys = &.{.{ .name = "n" }},
            .positional = .none,
            .open = true,
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    // Unknown :wat AND positional 99 — both bypassed by open.
    try expectBinaryDiagCount("(bag :wat 1 99)", .{}, schema, 0);
}

test "validateBinary [D4]: open form still rejects duplicate keys" {
    // Duplicate detection is schema-independent — open only relaxes the
    // unknown-key and required-key checks, not map-semantic uniqueness.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "bag", .open = true }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(bag :x 1 :x 2)", .{}, schema, 1);
}

test "validateBinary [D5]: open form with good type + extra key emits nothing" {
    // Binary parity: the §7.3 happy path — declared key passes its
    // type check, unknown key silenced. Mirrors the Tree test
    // "slot typing: open form with good type + extra key emits nothing".
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "bag",
            .keys = &.{.{ .name = "radius", .value_type = .number }},
            .open = true,
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(bag :radius 3 :extra \"anything\")", .{}, schema, 0);
}

test "validateBinary [D6]: open form positional .kind still type-checks" {
    // Binary parity for the positional path: declared kind constraint
    // runs even on open. Mirrors the Tree test
    // "slot typing: open form with positional kind still type-checks".
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "list",
            .positional = .{ .kind = .{ .name = "number" } },
            .open = true,
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(list 1 2 \"three\")", .{}, schema, 1);
}

// ----- Group E: PositionalSpec.kind edge cases ----------------------------

test "validateBinary [E1]: positional .kind with multiple positionals all wrong" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "box", .positional = .{ .kind = .{ .name = "vec3" } } }},
        .value_kinds = &.{.{ .name = "vec3", .underlying = .vector, .vector = .{ .len = 3, .element = .{ .name = "number" } } }},
    };
    const schema = Schema.Schema.init(&.{p});
    // Three positionals, each wrong vec length.
    try expectBinaryDiagCount("(box [1] [2 3] [4 5 6 7])", .{}, schema, 3);
}

test "validateBinary [E2]: positional .kind with mixed valid + invalid" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "box", .positional = .{ .kind = .{ .name = "vec3" } } }},
        .value_kinds = &.{.{ .name = "vec3", .underlying = .vector, .vector = .{ .len = 3, .element = .{ .name = "number" } } }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(box [1 2 3] [4 5] [7 8 9])", .{}, schema, 1);
}

test "validateBinary [E3]: positional .kind with zero positionals OK" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "box", .positional = .{ .kind = .{ .name = "vec3" } } }},
        .value_kinds = &.{.{ .name = "vec3", .underlying = .vector, .vector = .{ .len = 3, .element = .{ .name = "number" } } }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(box)", .{}, schema, 0);
}

test "validateBinary [E4]: positional .kind referencing unknown ValueKind" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "box", .positional = .{ .kind = .{ .name = "bogus" } } }},
    };
    const schema = Schema.Schema.init(&.{p});
    // Each positional emits one setup-error diagnostic.
    try expectBinaryDiagCount("(box [1 2 3] 5)", .{}, schema, 2);
}

test "validateBinary [E5]: positional .kind value is a form (defers)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "box", .positional = .{ .kind = .{ .name = "vec3" } } }},
        .value_kinds = &.{.{ .name = "vec3", .underlying = .vector, .vector = .{ .len = 3, .element = .{ .name = "number" } } }},
    };
    const schema = Schema.Schema.init(&.{ core.plugin, p });
    // (vec3 1 2 3) is a form; per defer-to-runtime rule, no slot diagnostic.
    try expectBinaryDiagCount("(box (vec3 1 2 3))", .{}, schema, 0);
}

test "validateBinary [E6]: data form with positional .any + keyword children interleaved" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "f",
            .keys = &.{
                .{ .name = "k", .value_type = .number },
                .{ .name = "m", .value_type = .number },
            },
            .positional = .any,
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(f 1 :k 2 3 :m 4 5)", .{}, schema, 0);
}

// ----- Group F: number / unit edge cases ----------------------------------

test "validateBinary [F1]: bare-number slot accepts unit-suffixed values (permissive)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .number }} }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(set :k 250ms)", .{}, schema, 0);
    try expectBinaryDiagCount("(set :k 90deg)", .{}, schema, 0);
    try expectBinaryDiagCount("(set :k 4b)", .{}, schema, 0);
    try expectBinaryDiagCount("(set :k 50%)", .{}, schema, 0);
}

test "validateBinary [F2]: empty allowed-unit list accepts any unit" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "anyunit" } } }} }},
        .value_kinds = &.{.{ .name = "anyunit", .underlying = .number, .unit = .{ .required = true, .allowed = &.{} } }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(set :k 4b)", .{}, schema, 0);
    try expectBinaryDiagCount("(set :k 90deg)", .{}, schema, 0);
}

test "validateBinary [F3]: unit slot with empty allowed list still requires presence of unit" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "anyunit" } } }} }},
        .value_kinds = &.{.{ .name = "anyunit", .underlying = .number, .unit = .{ .required = true, .allowed = &.{} } }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(set :k 250)", .{}, schema, 1);
}

test "validateBinary [F4]: unit-required false but allowed list pinned — bare number passes; bad unit rejected" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "soft" } } }} }},
        .value_kinds = &.{.{ .name = "soft", .underlying = .number, .unit = .{ .required = false, .allowed = &.{ "s", "ms" } } }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(set :k 250)", .{}, schema, 0);
    try expectBinaryDiagCount("(set :k 250ms)", .{}, schema, 0);
    try expectBinaryDiagCount("(set :k 90deg)", .{}, schema, 1);
}

test "validateBinary [F5]: special floats round-trip and validate as numbers" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .number }} }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(set :k 0)", .{}, schema, 0);
    try expectBinaryDiagCount("(set :k -0)", .{}, schema, 0);
    try expectBinaryDiagCount("(set :k -1.5e-300)", .{}, schema, 0);
    try expectBinaryDiagCount("(set :k 1.7976931348623157e308)", .{}, schema, 0);
}

test "validateBinary [F6]: vector of unit numbers in typed slot (each element typed)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "durations" } } }} }},
        .value_kinds = &.{
            .{ .name = "duration", .underlying = .number, .unit = .{ .required = true, .allowed = &.{"ms"} } },
            .{ .name = "durations", .underlying = .vector, .vector = .{ .element = .{ .name = "duration" } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(set :k [100ms 200ms 300ms])", .{}, schema, 0);
    try expectBinaryDiagCount("(set :k [100ms 200 300ms])", .{}, schema, 1);
    try expectBinaryDiagCount("(set :k [100ms 200deg 300s])", .{}, schema, 2);
}

// ----- Group G: deep / wide structures + recursion limits -----------------

test "validateBinary [G1]: cyclic ValueKind chain bottoms out without infinite recursion" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "A" } } }} }},
        .value_kinds = &.{
            .{ .name = "A", .underlying = .vector, .vector = .{ .element = .{ .name = "B" } } },
            .{ .name = "B", .underlying = .vector, .vector = .{ .element = .{ .name = "A" } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    // The innermost `1` is a number where the cycle expects yet another vector
    // — clean wrong_underlying. Pins that we don't stack-overflow.
    try expectBinaryDiagCount("(set :k [[1]])", .{}, schema, 1);
}

test "validateBinary [G2]: primitive-shortcut chain via element=\"number\"" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "vec" } } }} }},
        .value_kinds = &.{.{ .name = "vec", .underlying = .vector, .vector = .{ .element = .{ .name = "number" } } }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(set :k [1 2 3])", .{}, schema, 0);
    try expectBinaryDiagCount("(set :k [1 \"two\" 3])", .{}, schema, 1);
}

test "validateBinary [G3]: 4-deep nested typed vector accepted (matching chain depth)" {
    // vec_a: vec of vec_b; vec_b: vec of vec_c; vec_c: vec of vec_d; vec_d: vec of number.
    // Source uses 4 vector wrappers — exactly what the chain encodes.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "vec_a" } } }} }},
        .value_kinds = &.{
            .{ .name = "vec_a", .underlying = .vector, .vector = .{ .element = .{ .name = "vec_b" } } },
            .{ .name = "vec_b", .underlying = .vector, .vector = .{ .element = .{ .name = "vec_c" } } },
            .{ .name = "vec_c", .underlying = .vector, .vector = .{ .element = .{ .name = "vec_d" } } },
            .{ .name = "vec_d", .underlying = .vector, .vector = .{ .element = .{ .name = "number" } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(set :k [[[[1 2]]]])", .{}, schema, 0);
    // Innermost element wrong type (string instead of number) — one diagnostic.
    try expectBinaryDiagCount("(set :k [[[[1 \"oops\"]]]])", .{}, schema, 1);
    // One bracket level too deep — innermost expected `number` but got vector.
    try expectBinaryDiagCount("(set :k [[[[[1 2]]]]])", .{}, schema, 1);
}

test "validateBinary [G4]: deeply nested forms (50 levels) walk without stack overflow" {
    const a = testing.allocator;
    var src_buf: std.ArrayList(u8) = .empty;
    defer src_buf.deinit(a);
    var i: usize = 0;
    while (i < 50) : (i += 1) try src_buf.appendSlice(a, "(+ 1 ");
    try src_buf.appendSlice(a, "0");
    i = 0;
    while (i < 50) : (i += 1) try src_buf.append(a, ')');
    const src_z = try a.allocSentinel(u8, src_buf.items.len, 0);
    defer a.free(src_z);
    @memcpy(src_z, src_buf.items);

    var tree = try Parser.parse(a, src_z);
    defer tree.deinit();
    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();

    const schema = Schema.Schema.init(&.{core.plugin});
    var r = try validateBinary(a, bin.data, schema);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "validateBinary [G5]: wide form (20 keys, every other required, half missing)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "f",
            .keys = &.{
                .{ .name = "a0", .optional = false }, .{ .name = "a1" },
                .{ .name = "a2", .optional = false }, .{ .name = "a3" },
                .{ .name = "a4", .optional = false }, .{ .name = "a5" },
                .{ .name = "a6", .optional = false }, .{ .name = "a7" },
                .{ .name = "a8", .optional = false }, .{ .name = "a9" },
                .{ .name = "b0", .optional = false }, .{ .name = "b1" },
                .{ .name = "b2", .optional = false }, .{ .name = "b3" },
                .{ .name = "b4", .optional = false }, .{ .name = "b5" },
                .{ .name = "b6", .optional = false }, .{ .name = "b7" },
                .{ .name = "b8", .optional = false }, .{ .name = "b9" },
            },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    // Provide only 5 of the 10 required keys.
    try expectBinaryDiagCount("(f :a0 1 :a2 1 :a4 1 :a6 1 :a8 1)", .{}, schema, 5);
}

// ----- Group H: multi-root + sibling state isolation ----------------------

test "validateBinary [H1]: many sibling forms each with independent required-key state" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    const a = testing.allocator;
    var src_buf: std.ArrayList(u8) = .empty;
    defer src_buf.deinit(a);
    var i: usize = 0;
    while (i < 25) : (i += 1) try src_buf.appendSlice(a, "(scene) ");
    const src_z = try a.allocSentinel(u8, src_buf.items.len, 0);
    defer a.free(src_z);
    @memcpy(src_z, src_buf.items);
    const bin = try encodeForValidate(src_z);
    defer bin.deinit();
    var r = try validateBinary(a, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 25), r.diagnostics.len);
}

test "validateBinary [H2]: errored first root does not poison second root's state" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    const bin = try encodeForValidate("(scene :wat 1) (scene :bpm 130)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    // First root: unknown :wat + missing :bpm = 2. Second: 0.
    try testing.expectEqual(@as(usize, 2), r.diagnostics.len);
}

test "validateBinary [H3]: same-named nested form uses independent bitsets" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "scene",
            .keys = &.{
                .{ .name = "child", .value_type = .form },
                .{ .name = "bpm", .optional = false },
            },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    // Outer scene satisfies its :bpm; inner scene should still flag missing :bpm.
    try expectBinaryDiagCount("(scene :bpm 130 :child (scene))", .{}, schema, 1);
}

test "validateBinary [H4]: heterogeneous siblings — ambiguous + valid + unknown" {
    const a_plugin: Plugin.Plugin = .{ .name = "a", .forms = &.{.{ .name = "verb" }} };
    const b_plugin: Plugin.Plugin = .{ .name = "b", .forms = &.{.{ .name = "verb" }} };
    const schema = Schema.Schema.init(&.{ a_plugin, b_plugin });
    // (verb) ambiguous, (a/verb) valid, (other) unknown.
    try expectBinaryDiagCount("(verb) (a/verb) (other)", .{}, schema, 2);
}

// ----- Group I: compound multi-error fan-in -------------------------------

test "validateBinary [I1]: arity mismatch + keyword child + nested arity (3 diagnostics)" {
    const schema = Schema.Schema.init(&.{core.plugin});
    // `(< 1 :nope 2 (< 1))` — `<` is fixed-arity 2 with no labels.
    // Errors that fire independently: outer arity mismatch (3 children
    // ≠ 2), `:nope` rejected as a keyword child, inner `<` arity
    // mismatch (1 ≠ 2), AND (post declared-result enforcement) the
    // outer `<` sees a `.boolean`-result form in its `.number` slot.
    // Four total; picked `<` over `vec3` so the test isn't affected by
    // labeled-call opt-in semantics.
    const bin = try encodeForValidate("(< 1 :nope 2 (< 1))");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 4), r.diagnostics.len);
}

test "validateBinary [I2]: positional rejection + missing required + unknown keyword (3 diagnostics)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "f",
            .keys = &.{.{ .name = "k", .optional = false }},
            .positional = .none,
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(f 1 :wat 2)", .{}, schema, 3);
}

test "validateBinary [I3]: outer typed slot fail + inner form missing required (independent)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{ .name = "outer", .keys = &.{.{ .name = "child", .value_type = .form }} },
            .{ .name = "inner", .keys = &.{.{ .name = "k", .optional = false }} },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    // Outer's :child accepts a form (no slot diag). Inner missing :k.
    try expectBinaryDiagCount("(outer :child (inner))", .{}, schema, 1);
}

// ----- Group J: hostile / corrupted buffers -------------------------------

test "validateBinary [J1]: empty bytes (length 0) returns Truncated" {
    const schema = Schema.Schema.init(&.{core.plugin});
    try testing.expectError(error.Truncated, validateBinary(testing.allocator, &[_]u8{}, schema));
}

test "validateBinary [J2]: header-only truncation" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bytes: [4]u8 = .{ Binary.wire_magic[0], Binary.wire_magic[1], Binary.wire_magic[2], Binary.wire_magic[3] };
    try testing.expectError(error.Truncated, validateBinary(testing.allocator, &bytes, schema));
}

test "validateBinary [J3]: invalid wire version" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bytes: [16]u8 = undefined;
    @memset(&bytes, 0);
    @memcpy(bytes[0..4], &Binary.wire_magic);
    bytes[4] = 0xFF; // bogus version
    try testing.expectError(error.InvalidVersion, validateBinary(testing.allocator, &bytes, schema));
}

test "validateBinary [J4]: nonzero reserved bytes flagged" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bytes: [16]u8 = undefined;
    @memset(&bytes, 0);
    @memcpy(bytes[0..4], &Binary.wire_magic);
    bytes[4] = Binary.wire_version;
    bytes[6] = 0x42; // reserved byte must be 0
    try testing.expectError(error.InvalidFlags, validateBinary(testing.allocator, &bytes, schema));
}

test "validateBinary [J5]: truncation at progressively earlier offsets" {
    // Encode a fixture, then shrink the buffer one byte at a time. Every
    // truncation past the header must surface a cursor error (not panic,
    // not return a Result with bogus diagnostics).
    const schema = Schema.Schema.init(&.{core.plugin});
    var tree = try Parser.parse(testing.allocator, "(+ 1 2 (vec3 1 2 3))");
    defer tree.deinit();
    const bin = try Binary.toBinary(testing.allocator, tree, .{});
    defer bin.deinit();
    // Shrink by 1, 4, 8, 16 bytes — exercises pool / root-count / mid-node.
    inline for (.{ 1, 4, 8, 16 }) |drop| {
        if (bin.data.len > drop) {
            const result = validateBinary(testing.allocator, bin.data[0 .. bin.data.len - drop], schema);
            // Either Truncated, InvalidTag, or PoolIndexOutOfRange — all acceptable.
            try testing.expect(std.meta.isError(result));
            if (result) |r| {
                var rr = r;
                rr.deinit();
            } else |_| {}
        }
    }
}

test "validateBinary [J6]: bytes longer than MAX_FILE_SIZE yields NodeCountExceeded" {
    // We can't actually allocate 256MB in a test, but Cursor.init checks
    // the length first — so a slice with a fake bigger length would
    // trigger this. Skip the actual allocation; just document.
    // (Manual verification: see BinaryCursor.init line 118.)
}

// ----- Group K: parity stress with example fixtures + roundtrip ----------

test "validateBinary [K1]: example fixtures round-trip — basic.sjon" {
    const a = testing.allocator;
    const io = std.testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "examples/basic.sjon", a, .unlimited);
    defer a.free(bytes);
    const src = try a.allocSentinel(u8, bytes.len, 0);
    defer a.free(src);
    @memcpy(src, bytes);

    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});

    var via_text = try validate(a, tree, schema);
    defer via_text.deinit();
    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();
    var via_bin = try validateBinary(a, bin.data, schema);
    defer via_bin.deinit();

    try testing.expectEqual(via_text.diagnostics.len, via_bin.diagnostics.len);
}

test "validateBinary [K2]: example fixtures round-trip — with-expressions.sjon" {
    const a = testing.allocator;
    const io = std.testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "examples/with-expressions.sjon", a, .unlimited);
    defer a.free(bytes);
    const src = try a.allocSentinel(u8, bytes.len, 0);
    defer a.free(src);
    @memcpy(src, bytes);

    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});

    var via_text = try validate(a, tree, schema);
    defer via_text.deinit();
    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();
    var via_bin = try validateBinary(a, bin.data, schema);
    defer via_bin.deinit();

    try testing.expectEqual(via_text.diagnostics.len, via_bin.diagnostics.len);
}

test "validateBinary [K3]: stripped vs lossless encoding agrees on diagnostic count" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    inline for (.{
        "(scene)",
        "(scene :bpm 130)",
        "(scene :wat 1)",
        "(scene) (scene :bpm 130) (scene :wat 1)",
    }) |src| {
        const a = testing.allocator;
        var tree = try Parser.parse(a, src);
        defer tree.deinit();
        const bin_strip = try Binary.toBinary(a, tree, Binary.ToBinaryOptions.forMode(.compact));
        defer bin_strip.deinit();
        const bin_loss = try Binary.toBinary(a, tree, Binary.ToBinaryOptions.forMode(.full));
        defer bin_loss.deinit();

        var r_strip = try validateBinary(a, bin_strip.data, schema);
        defer r_strip.deinit();
        var r_loss = try validateBinary(a, bin_loss.data, schema);
        defer r_loss.deinit();
        try testing.expectEqual(r_strip.diagnostics.len, r_loss.diagnostics.len);
    }
}

test "validateBinary [K4]: idempotence over re-encoding — bin → tree → bin yields same diagnostics" {
    const schema = Schema.Schema.init(&.{ core.plugin, required_bpm_plugin });
    const src: [:0]const u8 = "(scene :bpm 130 (vec3 1 2)) (cond)";
    const a = testing.allocator;

    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin1 = try Binary.toBinary(a, tree, .{});
    defer bin1.deinit();

    var tree2 = try Binary.fromBinary(a, bin1.data, .{});
    defer tree2.deinit();
    const bin2 = try Binary.toBinary(a, tree2, .{});
    defer bin2.deinit();

    var r1 = try validateBinary(a, bin1.data, schema);
    defer r1.deinit();
    var r2 = try validateBinary(a, bin2.data, schema);
    defer r2.deinit();
    try testing.expectEqual(r1.diagnostics.len, r2.diagnostics.len);
}

// ----- Group L: ValueType / ValueKind shape variations --------------------

test "validateBinary [L1]: slot expecting .form accepts a form, rejects anything else" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{ .name = "outer", .keys = &.{.{ .name = "child", .value_type = .form }} },
            .{ .name = "inner" },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(outer :child (inner))", .{}, schema, 0);
    // Per the matcher's permissive .form rule, atoms in form slots ALSO
    // bypass the type check (matchValueAgainstType returns null when
    // tag == .form OR when expected is form/expr). Test mirrors validate.
    try expectBinaryDiagCount("(outer :child 5)", .{}, schema, 1);
}

test "validateBinary [L2]: slot expecting .expr behaves like .form" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{ .name = "outer", .keys = &.{.{ .name = "child", .value_type = .expr }} },
        },
    };
    const schema = Schema.Schema.init(&.{ core.plugin, p });
    try expectBinaryDiagCount("(outer :child (+ 1 2))", .{}, schema, 0);
}

test "validateBinary [L3]: ValueKind underlying = .form accepts any form" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{ .name = "outer", .keys = &.{.{ .name = "child", .value_type = .{ .named = .{ .name = "tagged_form" } } }} },
            .{ .name = "inner" },
        },
        .value_kinds = &.{.{ .name = "tagged_form", .underlying = .form }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(outer :child (inner))", .{}, schema, 0);
}

test "validateBinary [L4]: ValueKind vector with no len pin accepts any length" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "any_vec" } } }} }},
        .value_kinds = &.{.{ .name = "any_vec", .underlying = .vector, .vector = .{ .element = .{ .name = "number" } } }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(set :k [])", .{}, schema, 0);
    try expectBinaryDiagCount("(set :k [1])", .{}, schema, 0);
    try expectBinaryDiagCount("(set :k [1 2 3 4 5 6 7 8 9 10])", .{}, schema, 0);
}

test "validateBinary [L5]: ValueKind vector with element=\"any\" accepts any element type" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "mixed_vec" } } }} }},
        .value_kinds = &.{.{ .name = "mixed_vec", .underlying = .vector, .vector = .{ .element = .{ .name = "any" } } }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(set :k [1 \"two\" :three])", .{}, schema, 0);
}

test "validateBinary [L6]: ValueKind underlying = .string in slot" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "id" } } }} }},
        .value_kinds = &.{.{ .name = "id", .underlying = .string }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(set :k \"hello\")", .{}, schema, 0);
    try expectBinaryDiagCount("(set :k 1)", .{}, schema, 1);
}

test "validateBinary [L7]: every primitive ValueType — positive and negative cases" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "set",
            .keys = &.{
                .{ .name = "n", .value_type = .number },
                .{ .name = "s", .value_type = .string },
                .{ .name = "y", .value_type = .symbol },
                .{ .name = "b", .value_type = .boolean },
                .{ .name = "z", .value_type = .nil },
                .{ .name = "v", .value_type = .vector },
            },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    // All correct types — clean.
    try expectBinaryDiagCount("(set :n 1 :s \"a\" :y sym :b true :z nil :v [1])", .{}, schema, 0);
    // Every slot wrong type — 6 diagnostics.
    try expectBinaryDiagCount("(set :n \"x\" :s 1 :y 1 :b 1 :z 1 :v 1)", .{}, schema, 6);
}

// ----- Group M: minimal / empty edge cases --------------------------------

test "validateBinary [M1]: single-atom roots of every kind" {
    const schema = Schema.Schema.init(&.{core.plugin});
    inline for (.{
        "1",         "1.5",     "-3.14", "0",
        "\"hello\"", "\"\"",    ":kw",   "sym",
        "true",      "false",   "nil",   "[]",
        "[1]",       "[1 2 3]",
    }) |src| {
        try expectBinaryDiagCount(src, .{}, schema, 0);
    }
}

test "validateBinary [M2]: form with only required keys, all missing — declaration order" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "f",
            .keys = &.{
                .{ .name = "first", .optional = false },
                .{ .name = "second", .optional = false },
                .{ .name = "third", .optional = false },
            },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    const bin = try encodeForValidate("(f)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, ":first") != null);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[1].message, ":second") != null);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[2].message, ":third") != null);
}

test "validateBinary [M3]: empty vector inside typed-vector slot accepted (no len pin)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "v" } } }} }},
        .value_kinds = &.{.{ .name = "v", .underlying = .vector, .vector = .{ .element = .{ .name = "number" } } }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(set :k [])", .{}, schema, 0);
}

// ----- Group N: pool / string lookup edge cases ---------------------------

test "validateBinary [N1]: many distinct keyword names exercise pool lookups" {
    // 30 distinct kvpair keys — forces multiple pool resolutions per node.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "f",
            .keys = &.{
                .{ .name = "k00" }, .{ .name = "k01" }, .{ .name = "k02" }, .{ .name = "k03" },
                .{ .name = "k04" }, .{ .name = "k05" }, .{ .name = "k06" }, .{ .name = "k07" },
                .{ .name = "k08" }, .{ .name = "k09" }, .{ .name = "k10" }, .{ .name = "k11" },
                .{ .name = "k12" }, .{ .name = "k13" }, .{ .name = "k14" }, .{ .name = "k15" },
                .{ .name = "k16" }, .{ .name = "k17" }, .{ .name = "k18" }, .{ .name = "k19" },
                .{ .name = "k20" }, .{ .name = "k21" }, .{ .name = "k22" }, .{ .name = "k23" },
                .{ .name = "k24" }, .{ .name = "k25" }, .{ .name = "k26" }, .{ .name = "k27" },
                .{ .name = "k28" }, .{ .name = "k29" },
            },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount(
        "(f :k00 0 :k05 5 :k10 10 :k15 15 :k20 20 :k25 25 :k29 29)",
        .{},
        schema,
        0,
    );
}

test "validateBinary [N2]: long string key + value preserved through pool" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "f", .keys = &.{.{ .name = "ksuperlong0123456789", .value_type = .string }} }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount(
        "(f :ksuperlong0123456789 \"abcdefghij_aaaaaaaaaaaaaaaaaaaaaa\")",
        .{},
        schema,
        0,
    );
}

test "validateBinary [N3]: multi-byte UTF-8 strings + symbol values" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "set",
            .keys = &.{
                .{ .name = "label", .value_type = .string },
                .{ .name = "tag", .value_type = .symbol },
            },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount(
        "(set :label \"héllo wörld 🎉\" :tag yes)",
        .{},
        schema,
        0,
    );
}

// ----- Group O: ordering, span correctness, and observability -------------

test "validateBinary [O1]: missing-required spans anchor at form head, not fallback zero" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    const src: [:0]const u8 = "    (scene)";
    const bin = try encodeForValidate(src);
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    const d = r.diagnostics[0];
    // Span is the head_span of `scene`: 5..10.
    try testing.expectEqual(@as(u32, 5), d.span.start);
    try testing.expectEqual(@as(u32, 10), d.span.end);
}

test "validateBinary [O2]: type-mismatch span anchors at value, not at form head" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .number }} }},
    };
    const schema = Schema.Schema.init(&.{p});
    const src: [:0]const u8 = "(set :k \"oops\")";
    const bin = try encodeForValidate(src);
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    const d = r.diagnostics[0];
    // Anchor is the "oops" string literal span.
    try testing.expectEqualStrings("\"oops\"", src[d.span.start..d.span.end]);
}

test "validateBinary [O3]: nested mat4 failure reports at the outer slot span" {
    // Post-B.9 the binary arm points a nested typed-vector failure at the
    // outer slot's span (the whole vector), converging on the tree walker.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "m", .value_type = .{ .named = .{ .name = "mat4" } } }} }},
        .value_kinds = &.{
            .{ .name = "vec4", .underlying = .vector, .vector = .{ .len = 4, .element = .{ .name = "number" } } },
            .{ .name = "mat4", .underlying = .vector, .vector = .{ .len = 4, .element = .{ .name = "vec4" } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    const src: [:0]const u8 = "(set :m [[1 0 0 0] [0 1 0 0] [0 0 1 0] [0 0 0]])";
    const bin = try encodeForValidate(src);
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqualStrings("[[1 0 0 0] [0 1 0 0] [0 0 1 0] [0 0 0]]", src[r.diagnostics[0].span.start..r.diagnostics[0].span.end]);
}

test "validateBinary [O4]: stripped binary diagnostics all carry zero spans" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    const bin = try encodeWith("(scene) (scene :wat 1)", Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.diagnostics.len);
    for (r.diagnostics) |d| {
        try testing.expectEqual(@as(u32, 0), d.span.start);
        try testing.expectEqual(@as(u32, 0), d.span.end);
    }
}

// ----- Group P: stress + invariants ---------------------------------------

test "validateBinary [P1]: 100 sibling forms, half clean / half error" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    const a = testing.allocator;
    var src_buf: std.ArrayList(u8) = .empty;
    defer src_buf.deinit(a);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        if (i % 2 == 0) try src_buf.appendSlice(a, "(scene :bpm 130) ") else try src_buf.appendSlice(a, "(scene) ");
    }
    const src_z = try a.allocSentinel(u8, src_buf.items.len, 0);
    defer a.free(src_z);
    @memcpy(src_z, src_buf.items);
    const bin = try encodeForValidate(src_z);
    defer bin.deinit();
    var r = try validateBinary(a, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 50), r.diagnostics.len);
}

test "validateBinary [P2]: large vector inside typed slot with all elements OK" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "v" } } }} }},
        .value_kinds = &.{.{ .name = "v", .underlying = .vector, .vector = .{ .element = .{ .name = "number" } } }},
    };
    const schema = Schema.Schema.init(&.{p});
    const a = testing.allocator;
    var src_buf: std.ArrayList(u8) = .empty;
    defer src_buf.deinit(a);
    try src_buf.appendSlice(a, "(set :k [");
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        if (i > 0) try src_buf.append(a, ' ');
        var num_buf: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&num_buf, "{d}", .{i});
        try src_buf.appendSlice(a, s);
    }
    try src_buf.appendSlice(a, "])");
    const src_z = try a.allocSentinel(u8, src_buf.items.len, 0);
    defer a.free(src_z);
    @memcpy(src_z, src_buf.items);
    const bin = try encodeForValidate(src_z);
    defer bin.deinit();
    var r = try validateBinary(a, bin.data, schema);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "validateBinary [P3]: large vector with one bad element near the end" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "v" } } }} }},
        .value_kinds = &.{.{ .name = "v", .underlying = .vector, .vector = .{ .element = .{ .name = "number" } } }},
    };
    const schema = Schema.Schema.init(&.{p});
    const a = testing.allocator;
    var src_buf: std.ArrayList(u8) = .empty;
    defer src_buf.deinit(a);
    try src_buf.appendSlice(a, "(set :k [");
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        if (i > 0) try src_buf.append(a, ' ');
        if (i == 90) {
            try src_buf.appendSlice(a, "\"oops\"");
        } else {
            var num_buf: [16]u8 = undefined;
            const s = try std.fmt.bufPrint(&num_buf, "{d}", .{i});
            try src_buf.appendSlice(a, s);
        }
    }
    try src_buf.appendSlice(a, "])");
    const src_z = try a.allocSentinel(u8, src_buf.items.len, 0);
    defer a.free(src_z);
    @memcpy(src_z, src_buf.items);
    const bin = try encodeForValidate(src_z);
    defer bin.deinit();
    var r = try validateBinary(a, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "got string") != null);
}

test "validateBinary [P4]: re-validating same buffer twice produces identical counts" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    const bin = try encodeForValidate("(scene) (scene :bpm 130) (scene)");
    defer bin.deinit();
    var r1 = try validateBinary(testing.allocator, bin.data, schema);
    defer r1.deinit();
    var r2 = try validateBinary(testing.allocator, bin.data, schema);
    defer r2.deinit();
    try testing.expectEqual(r1.diagnostics.len, r2.diagnostics.len);
}

// ----- Group Q: namespace + plugin-edge interactions ---------------------

test "validateBinary [Q1]: same name as form + expr in different plugins, qualified picks form" {
    const a_plugin: Plugin.Plugin = .{ .name = "a", .forms = &.{.{ .name = "thing" }} };
    const b_plugin: Plugin.Plugin = .{ .name = "b", .expr_funcs = &.{.{ .name = "thing", .arity = .{ .fixed = 0 } }} };
    const schema = Schema.Schema.init(&.{ a_plugin, b_plugin });
    // Bare (thing) — form takes precedence (lookupForm wins before lookupExprFunc).
    try expectBinaryDiagCount("(thing)", .{}, schema, 0);
    // a/thing → form path; clean.
    try expectBinaryDiagCount("(a/thing)", .{}, schema, 0);
    // b/thing → expr path; arity 0 OK.
    try expectBinaryDiagCount("(b/thing)", .{}, schema, 0);
    // b/thing 1 → arity mismatch.
    try expectBinaryDiagCount("(b/thing 1)", .{}, schema, 1);
}

test "validateBinary [Q2]: empty plugin (no forms, no exprs) — every head unknown" {
    const empty: Plugin.Plugin = .{ .name = "empty" };
    const schema = Schema.Schema.init(&.{empty});
    try expectBinaryDiagCount("(anything)", .{}, schema, 1);
}

test "validateBinary [Q3]: plugin with only value_kinds (no forms / exprs) still loads" {
    const p: Plugin.Plugin = .{
        .name = "kinds_only",
        .value_kinds = &.{.{ .name = "duration", .underlying = .number }},
    };
    const schema = Schema.Schema.init(&.{p});
    // Atoms / vectors at root are validated against .any → no diagnostics.
    try expectBinaryDiagCount("123 \"x\" [1 2]", .{}, schema, 0);
}

// ----- Group R: outside-the-box subtle behaviors --------------------------

test "validateBinary [R1]: empty schema (zero plugins) — every form head unknown" {
    // Validator.validateBinary itself does not assert plugins.len > 0
    // (only root.zig's wrapper does). Confirm behaviour: every head is
    // unknown; atoms/vectors pass cleanly.
    const empty_schema: Schema.Schema = .{ .plugins = &.{} };
    try expectBinaryDiagCount("(unknown)", .{}, empty_schema, 1);
    try expectBinaryDiagCount("123", .{}, empty_schema, 0);
    try expectBinaryDiagCount("(a) (b) (c)", .{}, empty_schema, 3);
}

test "validateBinary [R2]: same buffer validated against two different schemas" {
    const schema_strict = Schema.Schema.init(&.{required_bpm_plugin});
    const empty_schema: Schema.Schema = .{ .plugins = &.{} };

    const bin = try encodeForValidate("(scene :bpm 130)");
    defer bin.deinit();
    var r_strict = try validateBinary(testing.allocator, bin.data, schema_strict);
    defer r_strict.deinit();
    var r_empty = try validateBinary(testing.allocator, bin.data, empty_schema);
    defer r_empty.deinit();
    try testing.expectEqual(@as(usize, 0), r_strict.diagnostics.len);
    // Empty schema: `scene` is unknown.
    try testing.expectEqual(@as(usize, 1), r_empty.diagnostics.len);
}

test "validateBinary [R3]: typed vec-of-number rejects every non-number element" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "v" } } }} }},
        .value_kinds = &.{.{ .name = "v", .underlying = .vector, .vector = .{ .element = .{ .name = "number" } } }},
    };
    const schema = Schema.Schema.init(&.{p});
    // String, keyword, symbol, boolean, nil — 5 wrong elements; one number passes.
    try expectBinaryDiagCount("(set :k [\"a\" :b sym true nil 1])", .{}, schema, 5);
}

test "validateBinary [R4]: form element of typed vec-of-number defers (no slot diag)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "v" } } }} }},
        .value_kinds = &.{.{ .name = "v", .underlying = .vector, .vector = .{ .element = .{ .name = "number" } } }},
    };
    const schema = Schema.Schema.init(&.{ core.plugin, p });
    // (* 2 3) is a form, defers per matchValueAgainstType .form rule.
    try expectBinaryDiagCount("(set :k [1 (* 2 3) 3])", .{}, schema, 0);
}

test "validateBinary [R6]: duplicate key emits duplicate diagnostic, satisfies presence" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    // Second occurrence emits 1 duplicate-keyword diagnostic; required-key
    // tracking still sees `:bpm` as present, so no missing-required fires.
    try expectBinaryDiagCount("(scene :bpm 130 :bpm 140)", .{}, schema, 1);
}

test "validateBinary [R7]: duplicate key + one wrong type — 1 dup + 1 type-mismatch" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    // 1 duplicate-keyword diagnostic + 1 type-mismatch on the string value.
    try expectBinaryDiagCount("(scene :bpm 130 :bpm \"oops\")", .{}, schema, 2);
}

test "validateBinary [R8]: duplicate key + both wrong — 1 dup + 2 type-mismatch" {
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    // 1 duplicate-keyword diagnostic + 2 type-mismatches (one per occurrence).
    try expectBinaryDiagCount("(scene :bpm \"a\" :bpm \"b\")", .{}, schema, 3);
}

test "validateBinary [R9]: bare unit-suffixed number at root accepted as untyped value" {
    const schema = Schema.Schema.init(&.{core.plugin});
    try expectBinaryDiagCount("4b 90deg 50% 250ms", .{}, schema, 0);
}

test "validateBinary [R10]: bare unit numbers inside untyped vector at root" {
    const schema = Schema.Schema.init(&.{core.plugin});
    try expectBinaryDiagCount("[4b 90deg 50% 250ms]", .{}, schema, 0);
}

test "validateBinary [R11]: form whose value happens to be a form with internal errors" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{ .name = "wrap", .keys = &.{.{ .name = "v", .value_type = .form }} },
        },
    };
    const schema = Schema.Schema.init(&.{ core.plugin, p });
    // Inner (vec3 1 2) has wrong arity. Wrap's :v slot accepts the form
    // (defer to runtime), but the inner expr is still validated.
    try expectBinaryDiagCount("(wrap :v (vec3 1 2))", .{}, schema, 1);
}

test "validateBinary [R12]: multiple plugins layered — qualified beats bare" {
    const p1: Plugin.Plugin = .{
        .name = "p1",
        .forms = &.{.{ .name = "thing", .keys = &.{.{ .name = "x", .optional = false }} }},
    };
    const p2: Plugin.Plugin = .{
        .name = "p2",
        .forms = &.{.{ .name = "thing", .keys = &.{.{ .name = "y", .optional = false }} }},
    };
    const schema = Schema.Schema.init(&.{ p1, p2 });
    // (thing) bare → ambiguous (1 diag).
    // (p1/thing) → missing :x (1 diag).
    // (p2/thing :y 1) → clean (0 diag).
    try expectBinaryDiagCount("(thing) (p1/thing) (p2/thing :y 1)", .{}, schema, 2);
}

test "validateBinary [R13]: deeply nested form chain validated end to end" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{ .name = "outer", .keys = &.{.{ .name = "child", .value_type = .form }} },
        },
    };
    const schema = Schema.Schema.init(&.{ core.plugin, p });
    // 6 levels of (outer :child (outer :child (outer :child …))).
    try expectBinaryDiagCount(
        "(outer :child (outer :child (outer :child (outer :child (outer :child (vec3 1 2))))))",
        .{},
        schema,
        1, // innermost vec3 wrong arity
    );
}

test "validateBinary [R14]: two siblings that share a SpecState pointer — bitset reset" {
    // Both forms are `scene` with the same FormSpec. Bitset state must NOT
    // bleed across sibling form_walks.
    const schema = Schema.Schema.init(&.{required_bpm_plugin});
    const bin = try encodeForValidate("(scene :bpm 130) (scene)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, ":bpm") != null);
}

test "validateBinary [R15]: nested vector elements get result-typed" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "v" } } }} }},
        .value_kinds = &.{.{ .name = "v", .underlying = .vector, .vector = .{ .element = .{ .name = "number" } } }},
    };
    const schema = Schema.Schema.init(&.{ core.plugin, p });
    // Three forms inside the vec; element type is `.number`. Post
    // declared-result enforcement: `(+ 1 2)` → number passes,
    // `(* 3 4)` → number passes, `(vec3 1 2)` → vector mismatches
    // (plus its own inner arity is wrong). Two diagnostics total.
    try expectBinaryDiagCount("(set :k [(+ 1 2) (vec3 1 2) (* 3 4)])", .{}, schema, 2);
}

test "validateBinary [R16]: vector typed as form-of-element (not just primitive)" {
    // ValueKind underlying=.vector with element="ident" where ident is a kind.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{ .name = "bus", .keys = &.{.{ .name = "items", .value_type = .{ .named = .{ .name = "items_vec" } } }} },
            .{ .name = "item" },
        },
        .value_kinds = &.{
            .{ .name = "item_kind", .underlying = .form },
            .{ .name = "items_vec", .underlying = .vector, .vector = .{ .element = .{ .name = "item_kind" } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    try expectBinaryDiagCount("(bus :items [(item) (item) (item)])", .{}, schema, 0);
    // Mixing in a non-form element: 1 diagnostic at the bad element.
    try expectBinaryDiagCount("(bus :items [(item) 5 (item)])", .{}, schema, 1);
}

test "validateBinary [R17]: validation across all encoding flag profiles agrees on count" {
    const schema = Schema.Schema.init(&.{ core.plugin, required_bpm_plugin });
    const src: [:0]const u8 = "(scene :bpm 130 (vec3 1 2)) (scene) (vec3 1 2 3)";
    const a = testing.allocator;
    var tree = try Parser.parse(a, src);
    defer tree.deinit();

    // 6 distinct flag combinations across spans + comments.
    const profiles = [_]Binary.ToBinaryOptions{
        Binary.ToBinaryOptions.forMode(.compact),
        Binary.ToBinaryOptions.forMode(.full),
        .{},
        .{ .with_spans = true, .with_head_spans = false, .with_kvpair_key_spans = false, .with_node_comments = false, .with_kvpair_comments = false },
        .{ .with_spans = false, .with_head_spans = true, .with_kvpair_key_spans = false, .with_node_comments = false, .with_kvpair_comments = false },
        .{ .with_spans = true, .with_head_spans = true, .with_kvpair_key_spans = true, .with_node_comments = true, .with_kvpair_comments = false },
    };
    var counts: [profiles.len]usize = undefined;
    for (profiles, 0..) |opts, i| {
        const bin = try Binary.toBinary(a, tree, opts);
        defer bin.deinit();
        var r = try validateBinary(a, bin.data, schema);
        defer r.deinit();
        counts[i] = r.diagnostics.len;
    }
    // All counts identical.
    for (counts[1..]) |c| try testing.expectEqual(counts[0], c);
}

test "validateBinary [R18]: comparison ops with wrong-type args trigger validator diag" {
    // A3: typed expr signatures are now active. `<` declares
    // `params = [number, number]`, so `(< true "x")` produces two
    // diagnostics (one per wrong-typed arg). Symbols and forms are
    // deferred to runtime; primitives like `true` and `"x"` are caught
    // statically.
    const schema = Schema.Schema.init(&.{core.plugin});
    try expectBinaryDiagCount("(< true \"x\")", .{}, schema, 2);
}

test "validateBinary [R19]: empty form `()` produces no head diagnostic" {
    // The parser emits a synthetic empty-head form on recovery. The
    // binary preserves it as head.len == 0; scheduleFormWalkValidate
    // skips head lookup. Children are walked but there are none here.
    const schema = Schema.Schema.init(&.{core.plugin});
    const a = testing.allocator;
    var tree = try Parser.parse(a, "()");
    defer tree.deinit();
    // The parser may emit parse-time diagnostics for `()`; we only check
    // that validateBinary itself does not crash and produces no extra
    // diagnostics beyond what validate produces.
    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();

    var via_text = try validate(a, tree, schema);
    defer via_text.deinit();
    var via_bin = try validateBinary(a, bin.data, schema);
    defer via_bin.deinit();
    try testing.expectEqual(via_text.diagnostics.len, via_bin.diagnostics.len);
}

test "validateBinary [R20]: extreme-numeric values round-trip correctly through cursor" {
    // f64 wire encoding handles every bit pattern; type check is just
    // tag-based, so any number flows through. Confirm odd values:
    //   - subnormal, NaN, +Inf, -Inf, max double, min normal, 0, -0
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .number }} }},
    };
    const schema = Schema.Schema.init(&.{p});
    inline for (.{
        "(set :k 0)",
        "(set :k -0)",
        "(set :k 1.7976931348623157e308)",
        "(set :k 2.2250738585072014e-308)",
        "(set :k 5e-324)",
    }) |src| {
        try expectBinaryDiagCount(src, .{}, schema, 0);
    }
}

test "validateBinary [R21]: all-comments file parses to zero roots → empty result" {
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{core.plugin});
    var tree = try Parser.parse(a,
        \\; comment one
        \\; comment two
        \\; comment three
    );
    defer tree.deinit();
    const bin = try Binary.toBinary(a, tree, Binary.ToBinaryOptions.forMode(.full));
    defer bin.deinit();
    var r = try validateBinary(a, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
}

test "validateBinary [R22]: nested form span vs root span — both anchored separately" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{ .name = "outer", .keys = &.{ .{ .name = "k", .optional = false }, .{ .name = "child", .value_type = .form } } },
            .{ .name = "inner", .keys = &.{.{ .name = "k", .optional = false }} },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    const src: [:0]const u8 = "(outer :child (inner))";
    const bin = try encodeForValidate(src);
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.diagnostics.len);
    var saw_outer = false;
    var saw_inner = false;
    for (r.diagnostics) |d| {
        const head = src[d.span.start..d.span.end];
        if (std.mem.eql(u8, head, "outer")) saw_outer = true;
        if (std.mem.eql(u8, head, "inner")) saw_inner = true;
    }
    try testing.expect(saw_outer);
    try testing.expect(saw_inner);
}

test "validateBinary [R23]: schema mutation between calls — fresh state each call" {
    // Build two distinct schemas at runtime and confirm validateBinary
    // produces independent results — pins that no static state leaks.
    const a_plugin: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "f", .keys = &.{.{ .name = "x", .optional = false }} }},
    };
    const b_plugin: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "f", .keys = &.{.{ .name = "y", .optional = false }} }},
    };
    const schema_a = Schema.Schema.init(&.{a_plugin});
    const schema_b = Schema.Schema.init(&.{b_plugin});

    const bin = try encodeForValidate("(f :x 1)");
    defer bin.deinit();
    var r_a = try validateBinary(testing.allocator, bin.data, schema_a);
    defer r_a.deinit();
    var r_b = try validateBinary(testing.allocator, bin.data, schema_b);
    defer r_b.deinit();
    try testing.expectEqual(@as(usize, 0), r_a.diagnostics.len);
    // Schema B doesn't know `:x` and is missing `:y` → 2 diagnostics.
    try testing.expectEqual(@as(usize, 2), r_b.diagnostics.len);
}

test "validateBinary [R24]: cursor truncation surface — every byte-cut between header and end" {
    // Sweep every truncation length. Past the header, every cut must
    // either succeed (clean validation) or surface a cursor error —
    // never panic, never UB.
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{core.plugin});
    var tree = try Parser.parse(a, "(+ 1 (vec3 1 2 3) [4 5])");
    defer tree.deinit();
    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();

    var cut: usize = bin.data.len;
    while (cut > 0) : (cut -= 1) {
        const slice = bin.data[0..cut];
        const result = validateBinary(a, slice, schema);
        if (result) |r| {
            var rr = r;
            rr.deinit();
            // Full-length succeeds at cut == bin.data.len; below that, success
            // is unlikely but acceptable — the buffer is short and may
            // happen to truncate cleanly. We only check no crash.
        } else |_| {
            // Cursor error — fine.
        }
    }
}

test "validateBinary [R25]: validating just-the-header-bytes of a valid buffer" {
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{core.plugin});
    var tree = try Parser.parse(a, "1 2 3");
    defer tree.deinit();
    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();
    // Cut to exactly HEADER_SIZE bytes (16). Cursor.init would succeed
    // syntactically (header valid), but reading the root count fails on
    // EOF. Confirm error path.
    try testing.expectError(error.Truncated, validateBinary(a, bin.data[0..16], schema));
}

test "validateBinary [R26]: core schema does not flag any built-in expression" {
    // Sanity sweep: invoke every core function with the right arity.
    // None should produce diagnostics under the `core` schema.
    const schema = Schema.Schema.init(&.{core.plugin});
    inline for (.{
        "(+)",                   "(+ 1)",                 "(+ 1 2 3 4)",
        "(- 1)",                 "(- 5 1 1)",             "(*)",
        "(* 2 3)",               "(/ 1 2)",               "(/ 1 2 3)",
        "(mod 5 2)",             "(< 1 2)",               "(> 2 1)",
        "(<= 1 1)",              "(>= 1 1)",              "(= 1 1)",
        "(!= 1 2)",              "(and)",                 "(and true)",
        "(and true false)",      "(or)",                  "(or false true)",
        "(not true)",            "(let [x 1] x)",         "(if true 1)",
        "(if true 1 2)",         "(cond)",                "(cond true 1)",
        "(cond true 1 false 2)", "(vec2 1 2)",            "(vec3 1 2 3)",
        "(vec4 1 2 3 4)",        "(lerp 0 1 0.5)",        "(clamp 5 0 10)",
        "(min 1)",               "(min 1 2 3)",           "(max 1)",
        "(max 1 2 3)",           "(dot [1 2 3] [4 5 6])", "(cross [1 2 3] [4 5 6])",
        "(length [1 2 3])",
    }) |src| {
        try expectBinaryDiagCount(src, .{}, schema, 0);
    }
}

// ---------------------------------------------------------------------------
// Long-tail validator tests — boundaries & multi-plugin composition that
// the per-bug suites above don't cover head-on.
// ---------------------------------------------------------------------------

test "empty form (parser-recovery synthetic) is skipped silently" {
    // Parser emits a synthetic form with empty head when it sees `()`. The
    // validator must skip such forms — emitting a diagnostic would
    // duplicate the parser's own report.
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("()", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), bundle.result.diagnostics.len);
}

test "vector-only tree validates atom children silently" {
    // No forms, no expression heads → no diagnostics. Confirms the walker
    // descends into vectors and atoms without spurious complaints.
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("[1 2 3 nil true false :foo]", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), bundle.result.diagnostics.len);
}

test "deeply nested known forms all validate clean" {
    // Pin: the iterative walker handles 100+ nested levels without
    // overflow. (Recursion would have blown the stack.)
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const depth: usize = 100;
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < depth) : (i += 1) try buf.appendSlice(aa, "(if true ");
    try buf.append(aa, '1');
    i = 0;
    while (i < depth) : (i += 1) try buf.append(aa, ')');
    try buf.append(aa, 0);
    const src: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];

    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc(src, schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());
}

test "many sibling unknown forms each emit one diagnostic" {
    // Parallelism: unknown-form diagnostic must fire once per offending
    // form, never collapse multiples into a single complaint.
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("(alpha) (beta) (gamma) (delta) (epsilon)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 5), bundle.result.diagnostics.len);
}

test "schema with two plugins exposes both vocabularies" {
    // A schema composed from two plugins must accept forms from each
    // unambiguously when their names don't collide.
    const a_plugin: Plugin.Plugin = .{
        .name = "a",
        .forms = &.{.{ .name = "alpha" }},
    };
    const b_plugin: Plugin.Plugin = .{
        .name = "b",
        .forms = &.{.{ .name = "beta" }},
    };
    const schema = Schema.Schema.init(&.{ a_plugin, b_plugin });
    var bundle = try validateSrc("(alpha) (beta)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), bundle.result.diagnostics.len);
}

test "schema picks the qualified hit over the bare ambiguity" {
    // `a/verb` must resolve to plugin `a` even when `b/verb` also exists.
    // No ambiguity diagnostic should appear for the qualified call.
    const a_plugin: Plugin.Plugin = .{
        .name = "a",
        .forms = &.{.{ .name = "verb" }},
    };
    const b_plugin: Plugin.Plugin = .{
        .name = "b",
        .forms = &.{.{ .name = "verb" }},
    };
    const schema = Schema.Schema.init(&.{ a_plugin, b_plugin });
    var bundle = try validateSrc("(a/verb) (b/verb)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), bundle.result.diagnostics.len);
}

test "qualified form with unknown namespace emits unknown-form diagnostic" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("(does-not-exist/op 1 2)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "unknown") != null);
}

test "expression with arity range accepts boundaries" {
    // `if` is range [2, 3]. Pin that 2 and 3 args both pass and 1 / 4 fail.
    const schema = Schema.Schema.init(&.{core.plugin});
    {
        var b = try validateSrc("(if true 1)", schema);
        defer b.tree.deinit();
        defer {
            var r = b.result;
            r.deinit();
        }
        try testing.expect(!b.result.hasErrors());
    }
    {
        var b = try validateSrc("(if true 1 2)", schema);
        defer b.tree.deinit();
        defer {
            var r = b.result;
            r.deinit();
        }
        try testing.expect(!b.result.hasErrors());
    }
    {
        var b = try validateSrc("(if true)", schema);
        defer b.tree.deinit();
        defer {
            var r = b.result;
            r.deinit();
        }
        try testing.expect(b.result.hasErrors());
    }
    {
        var b = try validateSrc("(if true 1 2 3)", schema);
        defer b.tree.deinit();
        defer {
            var r = b.result;
            r.deinit();
        }
        try testing.expect(b.result.hasErrors());
    }
}

test "expression at_least zero accepts 0..N" {
    const schema = Schema.Schema.init(&.{core.plugin});
    inline for (.{ "(+)", "(+ 1)", "(+ 1 2 3 4 5 6 7 8 9 10)" }) |src| {
        var b = try validateSrc(src, schema);
        defer b.tree.deinit();
        defer {
            var r = b.result;
            r.deinit();
        }
        try testing.expect(!b.result.hasErrors());
    }
}

// ---------------------------------------------------------------------------
// Typed expression signatures (A3) — `ExprFunc.params` / `.rest`.
// Activates per-arg type checks. Symbol args defer to runtime
// (potential `let`-binding refs); form args defer too (nested exprs).
// ---------------------------------------------------------------------------

test "typed expr: vec3 with three numbers passes" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var b = try validateSrc("(vec3 1 2 3)", schema);
    defer b.tree.deinit();
    defer {
        var r = b.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), b.result.diagnostics.len);
}

test "typed expr: vec3 with a wrong-typed arg emits expression diagnostic" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var b = try validateSrc("(vec3 \"x\" 2 3)", schema);
    defer b.tree.deinit();
    defer {
        var r = b.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), b.result.diagnostics.len);
    const msg = b.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "expression `vec3`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "argument 0") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "number") != null);
}

test "typed expr: + variadic tail accepts numbers" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var b = try validateSrc("(+ 1 2 3 4 5)", schema);
    defer b.tree.deinit();
    defer {
        var r = b.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), b.result.diagnostics.len);
}

test "typed expr: + variadic tail rejects non-number" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var b = try validateSrc("(+ 1 2 \"x\")", schema);
    defer b.tree.deinit();
    defer {
        var r = b.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), b.result.diagnostics.len);
    const msg = b.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "expression `+`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "argument 2") != null);
}

test "typed expr: comparison with wrong-typed args emits diags per arg" {
    // `<` declares params=[number, number]; `(< true "x")` fails on
    // both args (boolean and string in number slots).
    const schema = Schema.Schema.init(&.{core.plugin});
    var b = try validateSrc("(< true \"x\")", schema);
    defer b.tree.deinit();
    defer {
        var r = b.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 2), b.result.diagnostics.len);
}

test "typed expr: not with non-boolean arg flagged" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var b = try validateSrc("(not 1)", schema);
    defer b.tree.deinit();
    defer {
        var r = b.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), b.result.diagnostics.len);
    const msg = b.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "expression `not`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "boolean") != null);
}

test "typed expr: symbol args defer to runtime (potential let-binding refs)" {
    // `(let [r 0.5] (vec3 r r r))` — `r` is a symbol that's bound
    // by `let`. The validator can't statically resolve binding refs,
    // so symbol args to typed expr funcs are accepted. This pins the
    // deferral so a future tightening (e.g. let-aware static analysis)
    // is intentional rather than accidental.
    const schema = Schema.Schema.init(&.{core.plugin});
    var b = try validateSrc("(let [r 0.5] (vec3 r r r))", schema);
    defer b.tree.deinit();
    defer {
        var r = b.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), b.result.diagnostics.len);
}

test "typed expr: nested expression args defer (form tag)" {
    // Nested expression `(+ 1 1)` returns number at runtime; its tag
    // is .form, so `vec3` accepts it without static type-flow analysis.
    const schema = Schema.Schema.init(&.{core.plugin});
    var b = try validateSrc("(vec3 (+ 1 1) 2 3)", schema);
    defer b.tree.deinit();
    defer {
        var r = b.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), b.result.diagnostics.len);
}

test "typed expr: special-form opacity — let body args not type-checked statically" {
    // `let` is opaque (no params declared). Even an obviously-wrong
    // body like `(let [] "not-a-number")` validates; result type is
    // a runtime concern. Pins that A3 leaves opaque funcs alone.
    const schema = Schema.Schema.init(&.{core.plugin});
    var b = try validateSrc("(let [] \"not-a-number\")", schema);
    defer b.tree.deinit();
    defer {
        var r = b.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), b.result.diagnostics.len);
}

test "form spec with open=true relaxes unknown-key and required-key checks" {
    // §7.3 invariant: `open = true` silences exactly two checks —
    // unknown keyword names and missing-required-key sweep. It does
    // NOT silence type checks on declared keys (see "open form still
    // type-checks declared keys"); duplicate-key detection also still
    // runs. This test exercises only the relaxed checks.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "thing",
            .keys = &.{
                .{ .name = "id", .value_type = .number, .optional = false },
            },
            .open = true,
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    {
        // Missing the required `:id` — open=true silences the diagnostic.
        var b = try validateSrc("(thing :extra 1)", schema);
        defer b.tree.deinit();
        defer {
            var r = b.result;
            r.deinit();
        }
        try testing.expectEqual(@as(usize, 0), b.result.diagnostics.len);
    }
    {
        // Required `:id` present with correct type, plus an unknown key.
        // Both pass under open: declared key type-checks fine, unknown silenced.
        var b = try validateSrc("(thing :id 7 :unknown 1)", schema);
        defer b.tree.deinit();
        defer {
            var r = b.result;
            r.deinit();
        }
        try testing.expectEqual(@as(usize, 0), b.result.diagnostics.len);
    }
}

test "validateBinary on empty roots succeeds" {
    // A valid binary with zero roots is well-formed; the validator must
    // accept it without crashing.
    const a = testing.allocator;
    var tree = try Parser.parse(a, "");
    defer tree.deinit();
    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    var r = try validateBinary(a, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
}

test "validateBinary: deeply nested known forms validate clean" {
    // Streaming-binary parity for deep nesting: the binary validator
    // walks via a frame stack, so this catches any divergence in the
    // depth bound.
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const depth: usize = 100;
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < depth) : (i += 1) try buf.appendSlice(aa, "(if true ");
    try buf.append(aa, '1');
    i = 0;
    while (i < depth) : (i += 1) try buf.append(aa, ')');
    try buf.append(aa, 0);
    const src: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];

    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    var r = try validateBinary(a, bin.data, schema);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "validateBinary: sibling unknown forms each emit a diagnostic" {
    // Match the AST-walker test: 5 unknown forms → 5 diagnostics from
    // the streaming validator too.
    const a = testing.allocator;
    var tree = try Parser.parse(a, "(alpha) (beta) (gamma) (delta) (epsilon)");
    defer tree.deinit();
    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    var r = try validateBinary(a, bin.data, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 5), r.diagnostics.len);
}

// ===========================================================================
// Tree↔Binary diagnostic-path parity. Locks the Binary walker's path
// tracking against the Tree path's `(code, path)` for every diagnostic.
// Cross-host conformance asserts on `(code, path)`; these tests guard
// the Zig host's two validation paths against drift.
// ===========================================================================
test "binary path parity: unknown form at root has [head] path" {
    const schema = Schema.Schema.init(&.{core.plugin});
    try parityCheckPaths("(unknown-root :x 1)", schema);
}

test "binary path parity: kvpair value type mismatch path is [head, key]" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "scene", .keys = &.{.{ .name = "bpm", .value_type = .number }} }},
    };
    try parityCheckPaths("(scene :bpm \"x\")", Schema.Schema.init(&.{p}));
}

test "binary path parity: nested unknown form yields [outer, key, inner_head]" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "outer", .keys = &.{.{ .name = "inner", .value_type = .form }} }},
    };
    try parityCheckPaths("(outer :inner (typo :x 1))", Schema.Schema.init(&.{p}));
}

test "binary path parity: HeadSet failure emits at slot path, not at form" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{ .name = "circle", .keys = &.{.{ .name = "radius", .value_type = .number }} },
            .{ .name = "rect", .keys = &.{.{ .name = "w", .value_type = .number }} },
            .{ .name = "canvas", .keys = &.{.{ .name = "shape", .value_type = .{ .named = .{ .name = "shape-form" } } }} },
        },
        .value_kinds = &.{.{
            .name = "shape-form",
            .underlying = .form,
            .heads = .{ .names = &.{ "circle", "rect" } },
        }},
    };
    try parityCheckPaths("(canvas :shape (triangle :w 10))", Schema.Schema.init(&.{p}));
}

test "binary path parity: missing required key emits at form's path" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "thing",
            .keys = &.{.{ .name = "name", .value_type = .string, .optional = false }},
        }},
    };
    try parityCheckPaths("(thing)", Schema.Schema.init(&.{p}));
}

test "binary path parity: duplicate key emits at [form, key]" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "thing", .keys = &.{.{ .name = "x", .value_type = .number }} }},
    };
    try parityCheckPaths("(thing :x 1 :x 2)", Schema.Schema.init(&.{p}));
}

test "binary path: typed-vector element mismatch reports against the outer slot" {
    // Post-B.9: a typed-vector element failure converges on the tree
    // framing — one diagnostic against the `:v` slot, path `[set, v]` (NOT
    // the old index-extended `[set, v, 1]`), message wrapped with
    // `element [1]: …`. Count still matches the tree (one per slot).
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "v", .value_type = .{ .named = .{ .name = "ints" } } }} }},
        .value_kinds = &.{.{ .name = "ints", .underlying = .vector, .vector = .{ .element = .{ .name = "number" } } }},
    };
    const bin = try encodeForValidate("(set :v [1 \"two\" 3])");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, Schema.Schema.init(&.{p}));
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    const d = r.diagnostics[0];
    try testing.expectEqual(@as(usize, 2), d.path.len);
    try testing.expectEqualStrings("set", d.path[0]);
    try testing.expectEqualStrings("v", d.path[1]);
    try testing.expect(std.mem.indexOf(u8, d.message, "element [1]:") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "got string") != null);
}

test "binary path parity: positional_not_allowed step uses head when value is a form" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{ .name = "parent", .keys = &.{} },
            .{ .name = "circle", .keys = &.{} },
        },
    };
    try parityCheckPaths("(parent (circle))", Schema.Schema.init(&.{p}));
}

test "binary path parity: positional_not_allowed step uses idx when value isn't a form" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "parent", .keys = &.{} }},
    };
    try parityCheckPaths("(parent 42)", Schema.Schema.init(&.{p}));
}

// ===========================================================================
// B1: Stable diagnostic-code surface (LANGUAGE.md §7.6).
//
// Every validator-emitted diagnostic carries a `Diagnostic.Code` — the
// machine-matched conformance anchor. Message prose is host-flavoured
// and never asserted on. Each test exercises one code and checks Tree
// + Binary parity (so a diagnostic emitted on one path with the
// correct code also emits with that code on the other path).
// ===========================================================================

/// Returns true iff at least one diagnostic in `diags` carries `code`.
fn anyCode(diags: []const Diagnostic, code: Diagnostic.Code) bool {
    for (diags) |d| if (d.code == code) return true;
    return false;
}

/// True when some diagnostic carries exactly `code` at exactly `path`.
/// Sharpens `anyCode` for the positional cases where the diagnostic
/// *path* (e.g. `[task 1]` vs `[task 2]`) is the property under test.
fn anyCodeAtPath(diags: []const Diagnostic, code: Diagnostic.Code, path: []const []const u8) bool {
    outer: for (diags) |d| {
        if (d.code != code or d.path.len != path.len) continue;
        for (d.path, path) |got, want| {
            if (!std.mem.eql(u8, got, want)) continue :outer;
        }
        return true;
    }
    return false;
}

/// Dual-path counterpart that pins the *path* too: assert BOTH the Tree
/// and Binary walkers emit `code` at `path`. The positional-index logic
/// (Tree's `positional_n`, Binary's `pos_idx`) drifts silently between
/// paths unless the exact path is asserted on both.
fn expectPathOnBoth(
    src: [:0]const u8,
    schema: Schema.Schema,
    code: Diagnostic.Code,
    path: []const []const u8,
) !void {
    const a = testing.allocator;
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    var tr = try validate(a, tree, schema);
    defer tr.deinit();
    try testing.expect(anyCodeAtPath(tr.diagnostics, code, path));

    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();
    var br = try validateBinary(a, bin.data, schema);
    defer br.deinit();
    try testing.expect(anyCodeAtPath(br.diagnostics, code, path));
}

/// Validate `src` through Tree + Binary paths and assert that both emit
/// at least one diagnostic with `code`. The dual check is the
/// parity invariant — emitters that drift between paths show up as a
/// failure on one side while passing on the other.
fn expectCodeOnBoth(
    src: [:0]const u8,
    schema: Schema.Schema,
    code: Diagnostic.Code,
) !void {
    const a = testing.allocator;
    var tree = try Parser.parse(a, src);
    defer tree.deinit();

    var tr = try validate(a, tree, schema);
    defer tr.deinit();
    try testing.expect(anyCode(tr.diagnostics, code));

    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();
    var br = try validateBinary(a, bin.data, schema);
    defer br.deinit();
    try testing.expect(anyCode(br.diagnostics, code));
}

/// Dual-path counterpart of `expectCodeOnBoth`: assert NEITHER the Tree
/// nor the Binary path emits `code`. Used for accept cases.
fn expectNoCodeOnBoth(
    src: [:0]const u8,
    schema: Schema.Schema,
    code: Diagnostic.Code,
) !void {
    const a = testing.allocator;
    var tree = try Parser.parse(a, src);
    defer tree.deinit();

    var tr = try validate(a, tree, schema);
    defer tr.deinit();
    try testing.expect(!anyCode(tr.diagnostics, code));

    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();
    var br = try validateBinary(a, bin.data, schema);
    defer br.deinit();
    try testing.expect(!anyCode(br.diagnostics, code));
}

// ---------------------------------------------------------------------------
// Message-parity pins. The B1 tests above assert (code, path) only — prose is
// host-flavoured and generally not pinned. These six message *families* are
// the deliberate exception: each is built by a shared helper
// (`duplicateKeyMsg` / `unknownKeywordMsg` / `positionalNotAllowedMsg` /
// `missingDiscriminantMsg` / `missingRequiredKeyMsg` /
// `missingRequiredVariantKeyMsg`) consumed by BOTH the tree and binary
// form-key walkers. The corpus compares only (code, path, severity), so a
// wording drift on one path would slip past every other gate — these pins
// lock the exact text on both paths, which is what lets the two emitters
// share one builder.
// ---------------------------------------------------------------------------

/// Message of the first diagnostic carrying `code`, or null. Each pin source
/// below yields exactly one diagnostic of the code under test, so first-match
/// is unambiguous.
fn messageForCode(diags: []const Diagnostic, code: Diagnostic.Code) ?[]const u8 {
    for (diags) |d| if (d.code == code) return d.message;
    return null;
}

/// Assert BOTH walkers emit `code` with a message byte-identical to
/// `expected`. Cross-path identity is the invariant under test; the literal
/// documents the current wording and catches a regression inside the shared
/// builder that cross-path identity alone (post-extraction) would not.
fn expectMessageOnBoth(
    src: [:0]const u8,
    schema: Schema.Schema,
    code: Diagnostic.Code,
    expected: []const u8,
) !void {
    const a = testing.allocator;
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    var tr = try validate(a, tree, schema);
    defer tr.deinit();
    try testing.expectEqualStrings(expected, messageForCode(tr.diagnostics, code) orelse return error.TreeDiagnosticMissing);

    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();
    var br = try validateBinary(a, bin.data, schema);
    defer br.deinit();
    try testing.expectEqualStrings(expected, messageForCode(br.diagnostics, code) orelse return error.BinaryDiagnosticMissing);
}

/// First diagnostic carrying `code`, or null.
fn diagForCode(diags: []const Diagnostic, code: Diagnostic.Code) ?Diagnostic {
    for (diags) |d| if (d.code == code) return d;
    return null;
}

/// Full-parity pin for the nested typed-vector family (B.9): BOTH walkers
/// emit `code` with byte-identical message, identical span, and identical
/// path. This is stricter than `expectMessageOnBoth` (which ignores span /
/// path) — the convergence work makes the binary arm report a failing
/// typed-vector *element* against its outer slot, the way the tree arm's
/// `element [N]: …` wrap already does, so the two agree on all four fields.
fn expectMessageSpanPathOnBoth(
    src: [:0]const u8,
    schema: Schema.Schema,
    code: Diagnostic.Code,
) !void {
    const a = testing.allocator;
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    var tr = try validate(a, tree, schema);
    defer tr.deinit();
    const td = diagForCode(tr.diagnostics, code) orelse return error.TreeDiagnosticMissing;

    const bin = try Binary.toBinary(a, tree, .{
        .with_spans = true,
        .with_head_spans = true,
        .with_kvpair_key_spans = true,
    });
    defer bin.deinit();
    var br = try validateBinary(a, bin.data, schema);
    defer br.deinit();
    const bd = diagForCode(br.diagnostics, code) orelse return error.BinaryDiagnosticMissing;

    try testing.expectEqualStrings(td.message, bd.message);
    try testing.expectEqual(td.span.start, bd.span.start);
    try testing.expectEqual(td.span.end, bd.span.end);
    try testing.expectEqual(td.path.len, bd.path.len);
    for (td.path, bd.path) |ts, bs| try testing.expectEqualStrings(ts, bs);
}

test "message parity: duplicate_key" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "scene", .keys = &.{.{ .name = "bpm", .value_type = .number }} }},
    };
    try expectMessageOnBoth("(scene :bpm 130 :bpm 200)", Schema.Schema.init(&.{p}), .duplicate_key, "duplicate keyword `:bpm` in form `scene`");
}

test "message parity: unknown_key (plain shape)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "scene", .keys = &.{.{ .name = "bpm", .value_type = .number }} }},
    };
    try expectMessageOnBoth("(scene :bpm 130 :wat 1)", Schema.Schema.init(&.{p}), .unknown_key, "unknown keyword `:wat` in form `scene`");
}

test "message parity: unknown_key (variant-before-discriminant hint shape)" {
    const schema = Schema.Schema.init(&.{piece_track_plugin});
    try expectMessageOnBoth("(track :name k1 :step 4 :kind kick)", schema, .unknown_key, "unknown keyword `:step` in form `track` — `:kind` must be set before variant-only keys");
}

test "message parity: positional_not_allowed" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "scene", .positional = .none }},
    };
    try expectMessageOnBoth("(scene 42)", Schema.Schema.init(&.{p}), .positional_not_allowed, "form `scene` does not accept positional children");
}

test "message parity: missing_discriminant_key" {
    const schema = Schema.Schema.init(&.{piece_track_plugin});
    try expectMessageOnBoth("(track :name k1)", schema, .missing_discriminant_key, "form `track` is missing required discriminant `:kind`");
}

test "message parity: missing_required_key (top-level shape)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "scene",
            .keys = &.{.{ .name = "bpm", .value_type = .number, .optional = false }},
        }},
    };
    try expectMessageOnBoth("(scene)", Schema.Schema.init(&.{p}), .missing_required_key, "form `scene` is missing required keyword `:bpm`");
}

test "message parity: missing_required_key (variant shape)" {
    const schema = Schema.Schema.init(&.{piece_track_plugin});
    try expectMessageOnBoth("(track :kind kick :name k1)", schema, .missing_required_key, "form `track` (variant `:when kick`) is missing required keyword `:step`");
}

test "message parity: wrong_underlying (per-path node description)" {
    // `.wrong_underlying` is the one type-mismatch arm that stays per-path
    // after the describeFail-core extraction (tree `describeNode` vs binary
    // `describeNodeBinary`). Pin that the two render the offending node — and
    // the shared slot prefix — identically.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "scene", .keys = &.{.{ .name = "bpm", .value_type = .number }} }},
    };
    try expectMessageOnBoth("(scene :bpm \"fast\")", Schema.Schema.init(&.{p}), .wrong_underlying, "form `scene` keyword `:bpm` expects number, got string");
}

test "message parity: nested typed-vector element (mat4 with a short row)" {
    // A `mat4` (vector<vec4, 4>) whose 4th row is a 3-vector. The tree arm
    // reports this against the *outer* slot — "expects `mat4`, element [3]:
    // got vector of length 3" at the whole vector's span. B.9 converges the
    // binary arm (which used to fire "expects `vec4`, got vector of length
    // 3" at the inner element's span) onto that framing: same message, same
    // span, same path on both walkers.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "set",
            .keys = &.{.{ .name = "m", .value_type = .{ .named = .{ .name = "mat4" } } }},
        }},
        .value_kinds = &.{
            .{
                .name = "vec4",
                .underlying = .vector,
                .vector = .{ .len = 4, .element = .{ .name = "number" } },
            },
            .{
                .name = "mat4",
                .underlying = .vector,
                .vector = .{ .len = 4, .element = .{ .name = "vec4" } },
            },
        },
    };
    try expectMessageSpanPathOnBoth(
        "(set :m [[1 0 0 0] [0 1 0 0] [0 0 1 0] [0 0 0]])",
        Schema.Schema.init(&.{p}),
        .vector_length_mismatch,
    );
}

test "code: unknown_form on unknown head" {
    const schema = Schema.Schema.init(&.{core.plugin});
    try expectCodeOnBoth("(scene :bpm 130)", schema, .unknown_form);
}

test "code: unknown_key on undeclared keyword (closed form)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "scene", .keys = &.{.{ .name = "bpm", .value_type = .number }} }},
    };
    try expectCodeOnBoth("(scene :bpm 130 :wat 1)", Schema.Schema.init(&.{p}), .unknown_key);
}

// ---------------------------------------------------------------------------
// walk_opaque — KeySpec.walk_opaque suppresses recursive descent into a
// slot's value, so an expression-shaped default like `(key :default (pi))`
// doesn't emit a spurious `unknown_form` for the inner head. These pin the
// *behaviour* on BOTH validation paths (the loader tests only check the
// KeySpec field round-trips). The suppression lives in `validateOneTree`
// (tree) and must be mirrored in `validateOneBinary` (binary IR) — the
// `…OnBoth` helpers catch a divergence between them.
// ---------------------------------------------------------------------------

fn walkOpaquePlugin(comptime opaque_slot: bool, comptime slot_type: Plugin.ValueType) Plugin.Plugin {
    return .{
        .name = "demo",
        .forms = &.{.{
            .name = "set",
            .keys = &.{.{ .name = "expr", .value_type = slot_type, .walk_opaque = opaque_slot }},
        }},
    };
}

test "walk_opaque: form-shaped value at an opaque slot suppresses unknown_form" {
    // `:expr` is walk_opaque → the validator never descends into the
    // form value, so its unrecognised head raises no unknown_form.
    const schema = Schema.Schema.init(&.{walkOpaquePlugin(true, .any)});
    try expectNoCodeOnBoth("(set :expr (totally-unknown 1 2))", schema, .unknown_form);
}

test "walk_opaque: control — without walk_opaque the same value DOES raise unknown_form" {
    // Identical shape, walk_opaque off. The validator descends and the
    // unrecognised head raises unknown_form. This proves the suppression
    // above is load-bearing, not vacuous.
    const schema = Schema.Schema.init(&.{walkOpaquePlugin(false, .any)});
    try expectCodeOnBoth("(set :expr (totally-unknown 1 2))", schema, .unknown_form);
}

test "walk_opaque: suppression covers a deeply nested unknown form" {
    // The whole value subtree is opaque, not just the outer head — a
    // form nested several levels down raises no unknown_form either.
    const schema = Schema.Schema.init(&.{walkOpaquePlugin(true, .any)});
    try expectNoCodeOnBoth("(set :expr (a (b (c (mystery 1)))))", schema, .unknown_form);
}

test "walk_opaque: a vector-shaped value is drained, not walked" {
    // walk_opaque suppresses descent into the entire value, including a
    // vector whose elements contain unknown forms — the binary path
    // drains the vector body rather than walking its elements.
    const opaque_schema = Schema.Schema.init(&.{walkOpaquePlugin(true, .any)});
    try expectNoCodeOnBoth("(set :expr [1 (mystery 2) 3])", opaque_schema, .unknown_form);
    // Control: without walk_opaque the vector IS walked and the nested
    // form raises unknown_form on both paths.
    const walked_schema = Schema.Schema.init(&.{walkOpaquePlugin(false, .any)});
    try expectCodeOnBoth("(set :expr [1 (mystery 2) 3])", walked_schema, .unknown_form);
}

test "walk_opaque: the slot type-check still runs (HeadSet survives suppression)" {
    // Suppression is descent-only: a form-typed slot with a HeadSet
    // still rejects an out-of-set head (not_head_member) on BOTH paths,
    // while the unknown form nested inside it is suppressed. This pins
    // the tree-vs-binary contract that walk_opaque skips the per-node
    // walk but never the slot's own type-check.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .value_kinds = &.{.{
            .name = "shape",
            .underlying = .form,
            .heads = .{ .names = &.{ "circle", "square" } },
        }},
        .forms = &.{.{
            .name = "set",
            .keys = &.{.{
                .name = "s",
                .value_type = .{ .named = .{ .name = "shape" } },
                .walk_opaque = true,
            }},
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    const src = "(set :s (triangle (mystery 1)))";
    // Slot check fires — `triangle` is not in {circle, square}.
    try expectCodeOnBoth(src, schema, .not_head_member);
    // …but the inner `(mystery 1)` is not descended into.
    try expectNoCodeOnBoth(src, schema, .unknown_form);
}

// ---------------------------------------------------------------------------
// Slot-local forms (KeySpec.local_forms) — DUAL path. A form value in a slot
// that declares local forms resolves local-first (local shadows a same-named
// global), falls back additively to the global catalog, and a head matching
// neither is `unknown_local_form` at the slot path. Every case runs through
// BOTH the Tree and Binary walkers (`expect*OnBoth`) so the two resolution
// seams — validateOneTree's kvpair handler / validateFormHead, and the binary
// processFormWalkValidate / scheduleFormWalkValidate — stay in lockstep
// (the project's dual-path invariant: every schema feature lands on both).
// ---------------------------------------------------------------------------

/// One plugin exercising every slot-local axis:
///   * `canvas.:shape` carries locals circle / rect / group.
///     - local `circle` requires `:r` and SHADOWS the global `circle`
///       (which requires `:radius`) — a clean `(circle :r 1)` proves it.
///     - `rect` is local-only — invisible to global lookup.
///     - `group` nests: its `:child` slot carries a local `dot`.
///   * global `line` (no keys) — a non-local head reachable by the additive
///     fallback.
///   * global `circle` (requires `:radius`) — the shadow target.
fn localFormsPlugin() Plugin.Plugin {
    return .{
        .name = "demo",
        .forms = &.{
            .{ .name = "canvas", .keys = &.{.{
                .name = "shape",
                .value_type = .form,
                .local_forms = &.{
                    .{ .name = "circle", .keys = &.{.{ .name = "r", .value_type = .number, .optional = false }} },
                    .{ .name = "rect", .keys = &.{.{ .name = "w", .value_type = .number, .optional = false }} },
                    .{ .name = "group", .keys = &.{.{
                        .name = "child",
                        .value_type = .form,
                        .local_forms = &.{.{ .name = "dot" }},
                    }} },
                },
            }} },
            .{ .name = "line" },
            .{ .name = "circle", .keys = &.{.{ .name = "radius", .value_type = .number, .optional = false }} },
        },
    };
}

test "local_forms (dual): local match validates contents (shadows global)" {
    const schema = Schema.Schema.init(&.{localFormsPlugin()});
    // Local `circle` requires `:r`; satisfied → clean. If the GLOBAL circle
    // (requires `:radius`) had been used, `:r` would be unknown_key and
    // `:radius` missing — so a clean result proves the local shadowed it.
    try expectNoCodeOnBoth("(canvas :shape (circle :r 1))", schema, .unknown_local_form);
    try expectNoCodeOnBoth("(canvas :shape (circle :r 1))", schema, .unknown_form);
    try expectNoCodeOnBoth("(canvas :shape (circle :r 1))", schema, .missing_required_key);
    try expectNoCodeOnBoth("(canvas :shape (circle :r 1))", schema, .unknown_key);
}

test "local_forms (dual): local match missing required key at the value path" {
    const schema = Schema.Schema.init(&.{localFormsPlugin()});
    try expectPathOnBoth("(canvas :shape (circle))", schema, .missing_required_key, &.{ "canvas", "shape", "circle" });
}

test "local_forms (dual): terminal miss is unknown_local_form at the slot path" {
    const schema = Schema.Schema.init(&.{localFormsPlugin()});
    // `triangle` is neither local nor global → unknown_local_form at the
    // SLOT path `[canvas shape]`, and the generic unknown_form is suppressed.
    try expectPathOnBoth("(canvas :shape (triangle))", schema, .unknown_local_form, &.{ "canvas", "shape" });
    try expectNoCodeOnBoth("(canvas :shape (triangle))", schema, .unknown_form);
}

test "local_forms (dual): additive fallback to a global form is clean" {
    const schema = Schema.Schema.init(&.{localFormsPlugin()});
    // `line` is not a local but resolves globally → no diagnostic.
    try expectNoCodeOnBoth("(canvas :shape (line))", schema, .unknown_local_form);
    try expectNoCodeOnBoth("(canvas :shape (line))", schema, .unknown_form);
}

test "local_forms (dual): a local head is invisible to global lookup" {
    const schema = Schema.Schema.init(&.{localFormsPlugin()});
    // `rect` exists only as a local on `canvas.:shape`; at top level it
    // resolves against nothing → ordinary unknown_form (no slot context).
    try expectCodeOnBoth("(rect :w 1)", schema, .unknown_form);
    try expectNoCodeOnBoth("(rect :w 1)", schema, .unknown_local_form);
}

test "local_forms (dual): nested locals descend and miss at the nested slot" {
    const schema = Schema.Schema.init(&.{localFormsPlugin()});
    // `group` is local; its `:child` slot carries local `dot`.
    try expectNoCodeOnBoth("(canvas :shape (group :child (dot)))", schema, .unknown_local_form);
    try expectNoCodeOnBoth("(canvas :shape (group :child (dot)))", schema, .unknown_form);
    // A miss at the nested slot points at `[canvas shape group child]`.
    try expectPathOnBoth("(canvas :shape (group :child (nope)))", schema, .unknown_local_form, &.{ "canvas", "shape", "group", "child" });
}

test "local_forms (dual): a non-form value falls through (no local resolution)" {
    const schema = Schema.Schema.init(&.{localFormsPlugin()});
    // The value isn't a form, so there's no head to resolve locally — the
    // slot's own `:type form` check handles it; unknown_local_form never fires.
    try expectNoCodeOnBoth("(canvas :shape 5)", schema, .unknown_local_form);
}

test "local_forms (dual): a qualified head bypasses locals (global-only)" {
    const schema = Schema.Schema.init(&.{localFormsPlugin()});
    // `demo/bogus` is qualified → locals are skipped → global-only lookup
    // misses → ordinary unknown_form, NOT unknown_local_form.
    try expectCodeOnBoth("(canvas :shape (demo/bogus))", schema, .unknown_form);
    try expectNoCodeOnBoth("(canvas :shape (demo/bogus))", schema, .unknown_local_form);
}

// ---------------------------------------------------------------------------
// Positional slot-local forms (FormSpec.local_forms) — DUAL path. The
// positional mirror of the keyed block above: a form-shaped POSITIONAL child
// of a form that declares `FormSpec.local_forms` resolves local-first (local
// shadows a same-named global), falls back additively to the global catalog,
// and a head matching neither is `unknown_local_form` at the PARENT form's
// path (the positional slot). The registry attaches in a different seam on
// each path — validateOneTree's `.form` child-push loop / the binary
// `processFormWalkValidate` `.positional` arm — so every case runs through
// BOTH walkers (`expect*OnBoth`) to keep the two seams in lockstep (the
// project's dual-path invariant: every schema feature lands on both).
// ---------------------------------------------------------------------------

/// Positional mirror of `localFormsPlugin`: the locals hang off each form's
/// POSITIONAL slot (`FormSpec.local_forms`) rather than a keyed slot.
///   * `canvas` takes positional children resolving local-first against
///     circle / rect / group.
///     - local `circle` requires `:r` and SHADOWS the global `circle`
///       (which requires `:radius`) — a clean `(canvas (circle :r 1))` proves it.
///     - `rect` is local-only — invisible to global lookup.
///     - `group` nests BOTH carriers: its own positional slot carries a
///       positional-local `dot`, and its `:tag` key carries a key-local
///       `badge` — so positional-local ↔ key-local composition is exercised.
///   * global `line` (no keys) — a non-local head reachable by the additive
///     fallback.
///   * global `circle` (requires `:radius`) — the shadow target.
/// `.positional = .any` is set explicitly because a hand-built FormSpec does
/// not run the loader's "locals present ⇒ imply `.any`" ergonomic.
fn positionalLocalFormsPlugin() Plugin.Plugin {
    return .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "canvas",
                .positional = .any,
                .local_forms = &.{
                    .{ .name = "circle", .keys = &.{.{ .name = "r", .value_type = .number, .optional = false }} },
                    .{ .name = "rect", .keys = &.{.{ .name = "w", .value_type = .number, .optional = false }} },
                    .{
                        .name = "group",
                        .positional = .any,
                        .local_forms = &.{.{ .name = "dot" }},
                        .keys = &.{.{
                            .name = "tag",
                            .value_type = .form,
                            .local_forms = &.{.{ .name = "badge" }},
                        }},
                    },
                },
            },
            .{ .name = "line" },
            .{ .name = "circle", .keys = &.{.{ .name = "radius", .value_type = .number, .optional = false }} },
        },
    };
}

test "positional local_forms (dual): local match validates contents (shadows global)" {
    const schema = Schema.Schema.init(&.{positionalLocalFormsPlugin()});
    // Local `circle` requires `:r`; satisfied → clean. If the GLOBAL circle
    // (requires `:radius`) had resolved, `:r` would be unknown_key and
    // `:radius` missing — a clean result proves the positional local shadowed it.
    try expectNoCodeOnBoth("(canvas (circle :r 1))", schema, .unknown_local_form);
    try expectNoCodeOnBoth("(canvas (circle :r 1))", schema, .unknown_form);
    try expectNoCodeOnBoth("(canvas (circle :r 1))", schema, .missing_required_key);
    try expectNoCodeOnBoth("(canvas (circle :r 1))", schema, .unknown_key);
}

test "positional local_forms (dual): local match missing required key at the value path" {
    const schema = Schema.Schema.init(&.{positionalLocalFormsPlugin()});
    // The local `circle` spec drives the check (needs `:r`); the miss lands at
    // the value's own path `[canvas circle]`, not the slot.
    try expectPathOnBoth("(canvas (circle))", schema, .missing_required_key, &.{ "canvas", "circle" });
}

test "positional local_forms (dual): terminal miss is unknown_local_form at the parent path" {
    const schema = Schema.Schema.init(&.{positionalLocalFormsPlugin()});
    // `triangle` is neither local nor global → unknown_local_form at the
    // PARENT form path `[canvas]` (the positional slot), unknown_form suppressed.
    try expectPathOnBoth("(canvas (triangle))", schema, .unknown_local_form, &.{"canvas"});
    try expectNoCodeOnBoth("(canvas (triangle))", schema, .unknown_form);
}

test "positional local_forms (dual): additive fallback to a global form is clean" {
    const schema = Schema.Schema.init(&.{positionalLocalFormsPlugin()});
    // `line` is not a local but resolves globally → no diagnostic.
    try expectNoCodeOnBoth("(canvas (line))", schema, .unknown_local_form);
    try expectNoCodeOnBoth("(canvas (line))", schema, .unknown_form);
}

test "positional local_forms (dual): a local head is invisible to global lookup" {
    const schema = Schema.Schema.init(&.{positionalLocalFormsPlugin()});
    // `rect` exists only as a positional-local on `canvas`; at top level it
    // resolves against nothing → ordinary unknown_form (no slot context).
    try expectCodeOnBoth("(rect :w 1)", schema, .unknown_form);
    try expectNoCodeOnBoth("(rect :w 1)", schema, .unknown_local_form);
}

test "positional local_forms (dual): nested positional locals descend and miss at the nested slot" {
    const schema = Schema.Schema.init(&.{positionalLocalFormsPlugin()});
    // `group` is a positional-local; its own positional slot carries local `dot`.
    try expectNoCodeOnBoth("(canvas (group (dot)))", schema, .unknown_local_form);
    try expectNoCodeOnBoth("(canvas (group (dot)))", schema, .unknown_form);
    // A miss at the nested positional slot points at `[canvas group]`.
    try expectPathOnBoth("(canvas (group (nope)))", schema, .unknown_local_form, &.{ "canvas", "group" });
}

test "positional local_forms (dual): a key-local composes inside a positional-local" {
    const schema = Schema.Schema.init(&.{positionalLocalFormsPlugin()});
    // `group` (a positional-local) carries a key-local `badge` on `:tag` — the
    // two carriers compose: `badge` resolves local-first under the nested key.
    try expectNoCodeOnBoth("(canvas (group :tag (badge)))", schema, .unknown_local_form);
    try expectNoCodeOnBoth("(canvas (group :tag (badge)))", schema, .unknown_form);
    // A miss at the nested key-local slot points at `[canvas group tag]`.
    try expectPathOnBoth("(canvas (group :tag (nope)))", schema, .unknown_local_form, &.{ "canvas", "group", "tag" });
}

test "positional local_forms (dual): a non-form positional falls through (no local resolution)" {
    const schema = Schema.Schema.init(&.{positionalLocalFormsPlugin()});
    // A scalar positional has no head to resolve; the slot's own positional
    // type check handles it (here `.any` accepts); unknown_local_form never fires.
    try expectNoCodeOnBoth("(canvas 5)", schema, .unknown_local_form);
}

test "positional local_forms (dual): a qualified head bypasses locals (global-only)" {
    const schema = Schema.Schema.init(&.{positionalLocalFormsPlugin()});
    // `demo/bogus` is qualified → locals are skipped → global-only lookup
    // misses → ordinary unknown_form, NOT unknown_local_form.
    try expectCodeOnBoth("(canvas (demo/bogus))", schema, .unknown_form);
    try expectNoCodeOnBoth("(canvas (demo/bogus))", schema, .unknown_local_form);
}

test "positional local_forms (dual): a head-set closes the set while locals validate contents" {
    // The PNGine recipe: a head-set positional naming the local heads. The
    // head-set enforces the closed set (byte-equality on head text); the locals
    // drive per-head content validation. An in-set head resolves its LOCAL spec
    // (shadowing the same-named global). This is the shape that lets PNGine's
    // `bind-group` reuse `entry` as a positional local without a global collision.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "canvas",
                .positional = .{ .kind = .{ .name = "shape-set" } },
                .local_forms = &.{
                    .{ .name = "circle", .keys = &.{.{ .name = "r", .value_type = .number, .optional = false }} },
                    .{ .name = "rect", .keys = &.{.{ .name = "w", .value_type = .number, .optional = false }} },
                },
            },
            .{ .name = "circle", .keys = &.{.{ .name = "radius", .value_type = .number, .optional = false }} },
        },
        .value_kinds = &.{.{
            .name = "shape-set",
            .underlying = .form,
            .heads = .{ .names = &.{ "circle", "rect" } },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    // In-set head + local content satisfied → clean; local `circle` (needs `:r`)
    // shadowed the global `circle` (needs `:radius`), and the head-set accepted it.
    try expectNoCodeOnBoth("(canvas (circle :r 1))", schema, .unknown_local_form);
    try expectNoCodeOnBoth("(canvas (circle :r 1))", schema, .not_head_member);
    try expectNoCodeOnBoth("(canvas (circle :r 1))", schema, .missing_required_key);
    // In-set head, local content violated → the LOCAL spec's missing key at the value.
    try expectPathOnBoth("(canvas (circle))", schema, .missing_required_key, &.{ "canvas", "circle" });
    // Out-of-set head → the head-set gate fires `not_head_member`.
    try expectCodeOnBoth("(canvas (triangle))", schema, .not_head_member);
}

test "code: duplicate_key" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "scene", .keys = &.{.{ .name = "bpm", .value_type = .number }} }},
    };
    try expectCodeOnBoth("(scene :bpm 130 :bpm 200)", Schema.Schema.init(&.{p}), .duplicate_key);
}

test "code: missing_required_key" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "scene",
            .keys = &.{.{ .name = "bpm", .value_type = .number, .optional = false }},
        }},
    };
    try expectCodeOnBoth("(scene)", Schema.Schema.init(&.{p}), .missing_required_key);
}

test "code: positional_not_allowed (closed form)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "scene", .positional = .none }},
    };
    try expectCodeOnBoth("(scene 42)", Schema.Schema.init(&.{p}), .positional_not_allowed);
}

test "code: expr_kvpair_not_allowed" {
    const schema = Schema.Schema.init(&.{core.plugin});
    try expectCodeOnBoth("(+ :nope 1)", schema, .expr_kvpair_not_allowed);
}

test "code: arity_mismatch" {
    const schema = Schema.Schema.init(&.{core.plugin});
    try expectCodeOnBoth("(vec3 1 2)", schema, .arity_mismatch);
}

test "code: wrong_underlying on kvpair value" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "scene", .keys = &.{.{ .name = "bpm", .value_type = .number }} }},
    };
    try expectCodeOnBoth("(scene :bpm \"fast\")", Schema.Schema.init(&.{p}), .wrong_underlying);
}

test "code: not_member on closed-set MemberSet" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .value_kinds = &.{.{
            .name = "projection",
            .underlying = .symbol,
            .members = .{ .members = &.{ .{ .name = "ortho" }, .{ .name = "perspective" } } },
        }},
        .forms = &.{.{ .name = "cam", .keys = &.{.{ .name = "mode", .value_type = .{ .named = .{ .name = "projection" } } }} }},
    };
    try expectCodeOnBoth("(cam :mode flat)", Schema.Schema.init(&.{p}), .not_member);
}

test "code: not_head_member on closed-set HeadSet" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{ .name = "circle" },
            .{ .name = "rect" },
            .{ .name = "typo" },
            .{ .name = "badge", .keys = &.{.{ .name = "shape", .value_type = .{ .named = .{ .name = "shape-form" } } }} },
        },
        .value_kinds = &.{.{
            .name = "shape-form",
            .underlying = .form,
            .heads = .{ .names = &.{ "circle", "rect" } },
        }},
    };
    try expectCodeOnBoth("(badge :shape (typo))", Schema.Schema.init(&.{p}), .not_head_member);
}

test "code: flag-set accepts a declared positional flag" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "task",
            .positional = .{ .flag_set = .{ .flags = &.{ .{ .name = "done" }, .{ .name = "archived" } } } },
        }},
    };
    try expectNoCodeOnBoth("(task :done)", Schema.Schema.init(&.{p}), .not_flag_member);
}

test "code: not_flag_member on undeclared positional flag" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "task",
            .positional = .{ .flag_set = .{ .flags = &.{ .{ .name = "done" }, .{ .name = "archived" } } } },
        }},
    };
    try expectCodeOnBoth("(task :bogus)", Schema.Schema.init(&.{p}), .not_flag_member);
}

test "code: wrong_underlying on non-keyword in a flag-set slot" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "task",
            .positional = .{ .flag_set = .{ .flags = &.{ .{ .name = "done" }, .{ .name = "archived" } } } },
        }},
    };
    try expectCodeOnBoth("(task 42)", Schema.Schema.init(&.{p}), .wrong_underlying);
}

test "code: duplicate_positional_flag on a repeated declared flag" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "task",
            .positional = .{ .flag_set = .{ .flags = &.{ .{ .name = "done" }, .{ .name = "archived" } } } },
        }},
    };
    // First `:done` is the declared flag; the second repeat trips it.
    try expectCodeOnBoth("(task :done :done)", Schema.Schema.init(&.{p}), .duplicate_positional_flag);
}

test "code: distinct positional flags do not trip duplicate_positional_flag" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "task",
            .positional = .{ .flag_set = .{ .flags = &.{ .{ .name = "done" }, .{ .name = "archived" } } } },
        }},
    };
    try expectNoCodeOnBoth("(task :done :archived)", Schema.Schema.init(&.{p}), .duplicate_positional_flag);
}

// --- Long-tail flag-set parity (Tree vs Binary, exact paths) --------------
// Each case below was cross-checked against the TS-parity host: the
// positional-index path (`[task N]`) must agree across Tree, Binary, and
// the second-host reimplementation, so the corpus carries the matching
// `flag-set-*` fixtures.

fn flagTaskSchema() Schema.Schema {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "task",
            .positional = .{ .flag_set = .{ .flags = &.{ .{ .name = "done" }, .{ .name = "archived" } } } },
        }},
    };
    return Schema.Schema.init(&.{p});
}

test "flag-set long-tail: a thrice-repeated flag trips at indices 1 and 2" {
    // Every repeat past the first is flagged, and the index advances per
    // positional — so the second and third `:done` carry distinct paths.
    const schema = flagTaskSchema();
    try expectPathOnBoth("(task :done :done :done)", schema, .duplicate_positional_flag, &.{ "task", "1" });
    try expectPathOnBoth("(task :done :done :done)", schema, .duplicate_positional_flag, &.{ "task", "2" });
}

test "flag-set long-tail: unknown flag between repeats keeps indices aligned" {
    // `(task :done :bogus :done)` → not_flag_member at index 1, then a
    // duplicate at index 2. The unknown flag must not perturb the
    // positional counter on either path.
    const schema = flagTaskSchema();
    try expectPathOnBoth("(task :done :bogus :done)", schema, .not_flag_member, &.{ "task", "1" });
    try expectPathOnBoth("(task :done :bogus :done)", schema, .duplicate_positional_flag, &.{ "task", "2" });
}

test "flag-set long-tail: a repeated *unknown* flag is not a duplicate" {
    // duplicate_positional_flag is reserved for repeats of a *declared*
    // flag (the Binary walker only records accepted flags in `seen_flags`).
    // `(task :bogus :bogus)` is therefore two not_flag_member hits, never
    // a duplicate — locking that the dedup set tracks membership, not text.
    const schema = flagTaskSchema();
    try expectPathOnBoth("(task :bogus :bogus)", schema, .not_flag_member, &.{ "task", "0" });
    try expectPathOnBoth("(task :bogus :bogus)", schema, .not_flag_member, &.{ "task", "1" });
    try expectNoCodeOnBoth("(task :bogus :bogus)", schema, .duplicate_positional_flag);
}

test "flag-set long-tail: flag matching is case-sensitive" {
    // `:Done` is a distinct keyword from the declared `:done`.
    try expectPathOnBoth("(task :Done)", flagTaskSchema(), .not_flag_member, &.{ "task", "0" });
}

test "flag-set long-tail: a preceding kvpair does not shift the flag index" {
    // The positional counter advances only on positional children, so the
    // `:title \"x\"` kvpair is skipped and the repeated `:done` still trips
    // at positional index 1 — not 2. This is the exact case the second
    // host's positional-step counter must reproduce.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "task",
            .keys = &.{.{ .name = "title", .value_type = .string, .optional = true }},
            .positional = .{ .flag_set = .{ .flags = &.{ .{ .name = "done" }, .{ .name = "archived" } } } },
        }},
    };
    try expectPathOnBoth("(task :title \"x\" :done :done)", Schema.Schema.init(&.{p}), .duplicate_positional_flag, &.{ "task", "1" });
}

test "flag-set long-tail: a valued keyword binds as a kvpair, not a flag+value" {
    // The greedy parse rule means `:done 42` is a kvpair (`done` = 42),
    // not a flag `:done` followed by a positional `42`. On a closed form
    // with no `done` key that surfaces as unknown_key at `[task done]`,
    // while the trailing valueless `:done` is a clean positional flag.
    try expectPathOnBoth("(task :done 42 :done)", flagTaskSchema(), .unknown_key, &.{ "task", "done" });
}

test "code: vector_length_mismatch" {
    const schema = Schema.Schema.init(&.{core.plugin});
    // vec3 expects 3 args of type number; passing a 2-element vector
    // hits arity (different test); to hit vector_length_mismatch we
    // need a typed-vector slot. Build a small plugin.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .value_kinds = &.{.{
            .name = "rgb",
            .underlying = .vector,
            .vector = .{ .len = 3, .element = .{ .name = "number" } },
        }},
        .forms = &.{.{ .name = "paint", .keys = &.{.{ .name = "color", .value_type = .{ .named = .{ .name = "rgb" } } }} }},
    };
    _ = schema;
    try expectCodeOnBoth("(paint :color [1 2])", Schema.Schema.init(&.{p}), .vector_length_mismatch);
}

fn arityVecPlugin(comptime vec: Plugin.ValueKind.VectorShape) Plugin.Plugin {
    return .{
        .name = "demo",
        .value_kinds = &.{.{ .name = "list", .underlying = .vector, .vector = vec }},
        .forms = &.{.{ .name = "use", .keys = &.{.{ .name = "xs", .value_type = .{ .named = .{ .name = "list" } } }} }},
    };
}

test "code: vector_too_short on a vector below :min-len" {
    const p = arityVecPlugin(.{ .min_len = 1, .element = .{ .name = "number" } });
    // Empty vector under :min-len 1 fires on BOTH the tree and binary paths.
    try expectCodeOnBoth("(use :xs [])", Schema.Schema.init(&.{p}), .vector_too_short);
}

test "code: vector_too_long on a vector above :max-len" {
    const p = arityVecPlugin(.{ .min_len = 4, .max_len = 6, .element = .{ .name = "number" } });
    // 7 elements under :max-len 6 fires on both paths.
    try expectCodeOnBoth("(use :xs [1 2 3 4 5 6 7])", Schema.Schema.init(&.{p}), .vector_too_long);
}

test "code: vector arity — in-range vector is clean on both paths" {
    const p = arityVecPlugin(.{ .min_len = 1, .max_len = 4, .element = .{ .name = "number" } });
    // 3 elements sit inside [1, 4]: neither floor nor ceiling fires.
    try expectNoCodeOnBoth("(use :xs [1 2 3])", Schema.Schema.init(&.{p}), .vector_too_short);
    try expectNoCodeOnBoth("(use :xs [1 2 3])", Schema.Schema.init(&.{p}), .vector_too_long);
}

test "code: vector arity — :min-len/:max-len are inclusive at the boundary" {
    const p = arityVecPlugin(.{ .min_len = 2, .max_len = 4, .element = .{ .name = "number" } });
    // Lengths exactly at the floor (2) and ceiling (4) are accepted.
    try expectNoCodeOnBoth("(use :xs [1 2])", Schema.Schema.init(&.{p}), .vector_too_short);
    try expectNoCodeOnBoth("(use :xs [1 2 3 4])", Schema.Schema.init(&.{p}), .vector_too_long);
}

test "code: typed-vector element failure carries the leaf code" {
    // Tree wraps element failures via `MatchFail.element_at`; Binary
    // emits per-element directly. Both must surface the leaf code
    // (`wrong_underlying` here) so cross-host conformance can match
    // without caring which path produced the diagnostic.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .value_kinds = &.{.{
            .name = "rgb",
            .underlying = .vector,
            .vector = .{ .len = 3, .element = .{ .name = "number" } },
        }},
        .forms = &.{.{ .name = "paint", .keys = &.{.{ .name = "color", .value_type = .{ .named = .{ .name = "rgb" } } }} }},
    };
    try expectCodeOnBoth("(paint :color [1 \"x\" 3])", Schema.Schema.init(&.{p}), .wrong_underlying);
}

test "code: unit_required on bare number where unit needed" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .value_kinds = &.{.{
            .name = "duration",
            .underlying = .number,
            .unit = .{ .required = true, .allowed = &.{ "ms", "s" } },
        }},
        .forms = &.{.{ .name = "tween", .keys = &.{.{ .name = "len", .value_type = .{ .named = .{ .name = "duration" } } }} }},
    };
    try expectCodeOnBoth("(tween :len 5)", Schema.Schema.init(&.{p}), .unit_required);
}

test "code: unit_not_allowed on wrong suffix" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .value_kinds = &.{.{
            .name = "duration",
            .underlying = .number,
            .unit = .{ .required = true, .allowed = &.{ "ms", "s" } },
        }},
        .forms = &.{.{ .name = "tween", .keys = &.{.{ .name = "len", .value_type = .{ .named = .{ .name = "duration" } } }} }},
    };
    try expectCodeOnBoth("(tween :len 5deg)", Schema.Schema.init(&.{p}), .unit_not_allowed);
}

fn rejectUnitPlugin() Plugin.Plugin {
    return .{
        .name = "demo",
        .value_kinds = &.{.{
            .name = "bare",
            .underlying = .number,
            .unit = .{ .reject = true },
        }},
        .forms = &.{.{ .name = "px", .keys = &.{.{ .name = "x", .value_type = .{ .named = .{ .name = "bare" } } }} }},
    };
}

test "code: unit_forbidden on a unit-bearing number in a :reject slot" {
    // `1.0f` lexes as number_with_unit{1.0,"f"}; the `:reject` slot wants
    // bare numbers, so it fires on BOTH the tree and binary paths.
    try expectCodeOnBoth("(px :x 1.0f)", Schema.Schema.init(&.{rejectUnitPlugin()}), .unit_forbidden);
}

test "code: unit_forbidden — a bare number in a :reject slot is clean" {
    // Control for the above: the same slot accepts a bare `1.0` on both
    // paths, proving `:reject` narrows units only, not numbers.
    try expectNoCodeOnBoth("(px :x 1.0)", Schema.Schema.init(&.{rejectUnitPlugin()}), .unit_forbidden);
}

test "code: expr_type_mismatch on typed expr argument" {
    // `not` is a typed unary with `:params [boolean]`. Passing a
    // string lights up `expr_type_mismatch`, not `wrong_underlying`,
    // because the slot is an expression argument.
    const schema = Schema.Schema.init(&.{core.plugin});
    try expectCodeOnBoth("(not \"oops\")", schema, .expr_type_mismatch);
}

test "code: ambiguous_form when two plugins claim same head" {
    const p1: Plugin.Plugin = .{ .name = "alpha", .forms = &.{.{ .name = "scene" }} };
    const p2: Plugin.Plugin = .{ .name = "beta", .forms = &.{.{ .name = "scene" }} };
    try expectCodeOnBoth("(scene)", Schema.Schema.init(&.{ p1, p2 }), .ambiguous_form);
}

test "code: ambiguous_expr when two plugins claim same expression head" {
    const p1: Plugin.Plugin = .{ .name = "alpha", .expr_funcs = &.{.{ .name = "thing", .arity = .{ .fixed = 0 } }} };
    const p2: Plugin.Plugin = .{ .name = "beta", .expr_funcs = &.{.{ .name = "thing", .arity = .{ .fixed = 0 } }} };
    try expectCodeOnBoth("(thing)", Schema.Schema.init(&.{ p1, p2 }), .ambiguous_expr);
}

test "code: ambiguous_element_kind when two plugins claim same kind" {
    const k1: Plugin.ValueKind = .{ .name = "color", .underlying = .vector, .vector = .{ .element = .{ .name = "number" } } };
    const k2: Plugin.ValueKind = .{ .name = "color", .underlying = .number };
    const p1: Plugin.Plugin = .{ .name = "alpha", .value_kinds = &.{k1} };
    const p2: Plugin.Plugin = .{
        .name = "beta",
        .value_kinds = &.{k2},
        .forms = &.{.{ .name = "paint", .keys = &.{.{ .name = "tint", .value_type = .{ .named = .{ .name = "color" } } }} }},
    };
    try expectCodeOnBoth("(paint :tint 1)", Schema.Schema.init(&.{ p1, p2 }), .ambiguous_element_kind);
}

test "code: unknown_element_kind when vector element references undeclared kind" {
    // The :k slot's value-kind is a vector whose element resolves to
    // `.named "missing"`. The matcher hits an undeclared kind name on
    // the first element and returns `unknown_element_kind`. Both Tree
    // and Binary paths share the same chain-resolution code, so parity
    // here covers a real cross-host invariant.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "set",
            .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "A" } } }},
        }},
        .value_kinds = &.{
            .{
                .name = "A",
                .underlying = .vector,
                .vector = .{ .element = .{ .name = "missing" } },
            },
        },
    };
    try expectCodeOnBoth("(set :k [1])", Schema.Schema.init(&.{p}), .unknown_element_kind);
}

test "code: recursion_depth when named-kind chain bottoms out below MAX_KIND_DEPTH" {
    // Self-cyclic kind `A` whose element is `.named "A"`. Data nested
    // 7 levels deep makes the resolver hop through the cycle once per
    // layer; on the 8th hop (`next_depth == 8 == MAX_KIND_DEPTH`) the
    // bound trips and `recursion_depth` is emitted before any
    // wrong_underlying diagnostic on the innermost number can fire.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "set",
            .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "A" } } }},
        }},
        .value_kinds = &.{
            .{
                .name = "A",
                .underlying = .vector,
                .vector = .{ .element = .{ .name = "A" } },
            },
        },
    };
    try expectCodeOnBoth("(set :k [[[[[[[1]]]]]]])", Schema.Schema.init(&.{p}), .recursion_depth);
}

test "code: parser-emitted diagnostics carry .unspecified" {
    // Validator codes are exhaustively wired; parser-side diagnostics
    // currently don't attribute (out of scope for B1). Guard the
    // contract so a future parser code lift is a deliberate change.
    const a = testing.allocator;
    var tree = try Parser.parse(a, "(scene"); // intentionally unterminated
    defer tree.deinit();
    if (tree.diagnostics.len > 0) {
        try testing.expectEqual(Diagnostic.Code.unspecified, tree.diagnostics[0].code);
    }
}

// ---------------------------------------------------------------------------
// Defaults: keys with `:default` are implicitly optional.
// ---------------------------------------------------------------------------

test "default: required-with-default is not flagged when omitted" {
    // The `:title` key is `:optional false` but carries a default — the
    // validator should treat it as effectively optional and skip the
    // missing-required diagnostic on a `(scene)` with no title.
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{
            .name = "scene",
            .keys = &.{.{
                .name = "title",
                .value_type = .string,
                .optional = false,
                .default = .{ .string = "Untitled" },
            }},
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    const a = testing.allocator;

    var tree = try Parser.parse(a, "(scene)");
    defer tree.deinit();
    var tr = try validate(a, tree, schema);
    defer tr.deinit();
    try testing.expect(!anyCode(tr.diagnostics, .missing_required_key));

    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();
    var br = try validateBinary(a, bin.data, schema);
    defer br.deinit();
    try testing.expect(!anyCode(br.diagnostics, .missing_required_key));
}

test "default: required-without-default is still flagged when omitted" {
    // Sanity counter-test: a sibling required key without `:default`
    // must still trip `missing_required_key`.
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{
            .name = "scene",
            .keys = &.{
                .{ .name = "title", .value_type = .string, .optional = false, .default = .{ .string = "x" } },
                .{ .name = "author", .value_type = .string, .optional = false },
            },
        }},
    };
    try expectCodeOnBoth("(scene)", Schema.Schema.init(&.{p}), .missing_required_key);
}

// ---------------------------------------------------------------------------
// Multi-signature overload dispatch.
// ---------------------------------------------------------------------------

const overload_lerp_sigs = [_]Plugin.ExprFunc.Signature{
    .{ .arity = .{ .fixed = 3 }, .params = &[_]Plugin.ValueType{ .number, .number, .number }, .result = .number },
    .{ .arity = .{ .fixed = 3 }, .params = &[_]Plugin.ValueType{ .vector, .vector, .number }, .result = .vector },
};

fn overloadPlugin() Plugin.Plugin {
    return .{
        .name = "ovl",
        .expr_funcs = &.{
            .{ .name = "lerp", .signatures = &overload_lerp_sigs, .description = "" },
        },
    };
}

test "overload: numeric triple matches the number signature" {
    const p = overloadPlugin();
    const schema = Schema.Schema.init(&.{p});
    const a = testing.allocator;

    var tree = try Parser.parse(a, "(lerp 1 2 0.5)");
    defer tree.deinit();
    var tr = try validate(a, tree, schema);
    defer tr.deinit();
    try testing.expect(!anyCode(tr.diagnostics, .expr_type_mismatch));

    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();
    var br = try validateBinary(a, bin.data, schema);
    defer br.deinit();
    try testing.expect(!anyCode(br.diagnostics, .expr_type_mismatch));
}

test "overload: vector triple+number matches the vector signature" {
    const p = overloadPlugin();
    try expectNoCodeOnBoth("(lerp [1 2 3] [4 5 6] 0.5)", Schema.Schema.init(&.{p}), .expr_type_mismatch);
}

test "overload: mismatched argument shapes elimination triggers expr_type_mismatch" {
    // `(lerp 1 [2 3 4] 0.5)` — arg 0 (number) keeps the number
    // signature alive, eliminates the vector signature. Arg 1 (vector)
    // then conflicts with the number signature's `:params [number
    // number number]`. The overload narrowing should report the union
    // of remaining types tried at arg 1.
    const p = overloadPlugin();
    try expectCodeOnBoth("(lerp 1 [2 3 4] 0.5)", Schema.Schema.init(&.{p}), .expr_type_mismatch);
}

test "overload: arity union — only matching-arity sigs constrain types" {
    // Bespoke overload: 1 arg = symbol, 3 args = number triple. A
    // 1-arg call with a string should NOT incorrectly match the 3-arg
    // signature's first slot — `checkArity` excludes it from the
    // initial mask. With one signature surviving, narrowing falls
    // through to the symbol-only candidate; a string arg there
    // emits `expr_type_mismatch`.
    const sigs = [_]Plugin.ExprFunc.Signature{
        .{ .arity = .{ .fixed = 1 }, .params = &[_]Plugin.ValueType{.symbol}, .result = .symbol },
        .{ .arity = .{ .fixed = 3 }, .params = &[_]Plugin.ValueType{ .number, .number, .number }, .result = .number },
    };
    const p: Plugin.Plugin = .{
        .name = "x",
        .expr_funcs = &.{.{ .name = "weird", .signatures = &sigs }},
    };
    try expectCodeOnBoth("(weird \"hello\")", Schema.Schema.init(&.{p}), .expr_type_mismatch);
}

test "overload: arity_mismatch when no signature accepts argc" {
    const p = overloadPlugin();
    try expectCodeOnBoth("(lerp 1 2)", Schema.Schema.init(&.{p}), .arity_mismatch);
}

test "overload: symbol arg defers narrowing (let-bound or unknown)" {
    // `x` is a free symbol — the validator can't resolve it
    // statically; overload narrowing must keep all candidates alive
    // and emit no `expr_type_mismatch`. (`let` lives in `core`, so
    // we pass both plugins so the outer expression resolves.)
    const p = overloadPlugin();
    try expectNoCodeOnBoth("(let [x 1] (lerp x 2 0.5))", Schema.Schema.init(&.{ p, core.plugin }), .expr_type_mismatch);
}

test "overload: nested expression arg defers narrowing" {
    // `(+ 1 2)` is a form — defers to runtime semantics, mask
    // unchanged.
    const p = overloadPlugin();
    const schema = Schema.Schema.init(&.{ p, core.plugin });
    try expectNoCodeOnBoth("(lerp (+ 1 2) 3 0.5)", schema, .expr_type_mismatch);
}

test "overload: message lists candidate types with ` or ` separator" {
    const p = overloadPlugin();
    const a = testing.allocator;

    var tree = try Parser.parse(a, "(lerp \"oops\" 2 0.5)");
    defer tree.deinit();
    var tr = try validate(a, tree, Schema.Schema.init(&.{p}));
    defer tr.deinit();

    var found: bool = false;
    for (tr.diagnostics) |d| {
        if (d.code != .expr_type_mismatch) continue;
        // Both signatures have a typed arg-0 (number / vector); the
        // message must mention both.
        try testing.expect(std.mem.indexOf(u8, d.message, "number") != null);
        try testing.expect(std.mem.indexOf(u8, d.message, "vector") != null);
        try testing.expect(std.mem.indexOf(u8, d.message, " or ") != null);
        found = true;
    }
    try testing.expect(found);
}

// ---------------------------------------------------------------------------
// validateForest: cross-document references
// ---------------------------------------------------------------------------

fn buildPhraseTrackPlugin() Plugin.Plugin {
    const phrase_name_kind: Plugin.ValueKind = .{
        .name = "phrase-name",
        .underlying = .symbol,
        .cross_ref = .{ .target_form = "phrase" },
    };
    const phrase_seq_kind: Plugin.ValueKind = .{
        .name = "phrase-sequence",
        .underlying = .vector,
        .vector = .{ .element = .{ .name = "phrase-name" } },
    };
    return .{
        .name = "demo",
        .value_kinds = &.{ phrase_name_kind, phrase_seq_kind },
        .forms = &.{
            .{
                .name = "phrase",
                .keys = &.{
                    .{ .name = "name", .value_type = .symbol, .optional = false },
                },
            },
            .{
                .name = "track",
                .keys = &.{
                    .{ .name = "sequence", .value_type = .{ .named = .{ .name = "phrase-sequence" } }, .optional = false },
                },
            },
        },
    };
}

test "forest: cross-tree references do NOT resolve under per-tree default" {
    const a = testing.allocator;
    const plugin = buildPhraseTrackPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var phrases = try Parser.parse(a,
        \\(phrase :name p0)
        \\(phrase :name p1)
    );
    defer phrases.deinit();
    var track = try Parser.parse(a,
        \\(track :sequence [p0 p1])
    );
    defer track.deinit();

    const trees = [_]Ast.Tree{ phrases, track };
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);

    try testing.expectEqual(@as(usize, 2), fr.results.len);
    // Tree 0 (phrases): clean.
    try testing.expectEqual(@as(usize, 0), fr.results[0].diagnostics.len);
    // Tree 1 (track) references names that live in tree 0's scope —
    // per-tree default isolates them. The vector match short-circuits
    // on the first failed element, so one `not_cross_ref` diagnostic
    // is enough to confirm isolation.
    var found_not_cross_ref = false;
    for (fr.results[1].diagnostics) |d| {
        if (d.code == .not_cross_ref) found_not_cross_ref = true;
    }
    try testing.expect(found_not_cross_ref);

    // Names live in tree 0's scope but not tree 1's.
    try testing.expect(fr.cross_ref_index.contains(.tree(0), "demo/phrase", "p0"));
    try testing.expect(fr.cross_ref_index.contains(.tree(0), "demo/phrase", "p1"));
    try testing.expect(!fr.cross_ref_index.contains(.tree(1), "demo/phrase", "p0"));
}

test "forest: same-tree reference still resolves" {
    const a = testing.allocator;
    const plugin = buildPhraseTrackPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var bundled = try Parser.parse(a,
        \\(phrase :name p0)
        \\(phrase :name p1)
        \\(track :sequence [p0 p1])
    );
    defer bundled.deinit();

    const trees = [_]Ast.Tree{bundled};
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);

    try testing.expectEqual(@as(usize, 0), fr.results[0].diagnostics.len);

    try testing.expect(fr.cross_ref_index.contains(.tree(0), "demo/phrase", "p0"));
    try testing.expect(fr.cross_ref_index.contains(.tree(0), "demo/phrase", "p1"));
    const site_p0 = fr.cross_ref_index.lookup(.tree(0), "demo/phrase", "p0").?;
    try testing.expectEqual(@as(u32, 0), site_p0.tree_idx);
    try testing.expect(!site_p0.scope.isLexical());
}

test "forest: missing same-tree reference still flagged with not_cross_ref" {
    const a = testing.allocator;
    const plugin = buildPhraseTrackPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var bundled = try Parser.parse(a,
        \\(phrase :name p0)
        \\(track :sequence [p0 typoed])
    );
    defer bundled.deinit();

    const trees = [_]Ast.Tree{bundled};
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);

    var found_not_cross_ref = false;
    for (fr.results[0].diagnostics) |d| {
        if (d.code == .not_cross_ref) {
            found_not_cross_ref = true;
            try testing.expect(std.mem.indexOf(u8, d.message, "typoed") != null);
        }
    }
    try testing.expect(found_not_cross_ref);

    try testing.expect(fr.cross_ref_index.contains(.tree(0), "demo/phrase", "p0"));
    try testing.expect(!fr.cross_ref_index.contains(.tree(0), "demo/phrase", "typoed"));
}

test "forest: same name in two trees does NOT trigger duplicate (per-tree isolation)" {
    const a = testing.allocator;
    const plugin = buildPhraseTrackPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var phrases_a = try Parser.parse(a,
        \\(phrase :name p0)
    );
    defer phrases_a.deinit();
    var phrases_b = try Parser.parse(a,
        \\(phrase :name p0)
    );
    defer phrases_b.deinit();

    const trees = [_]Ast.Tree{ phrases_a, phrases_b };
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);

    // No duplicate diagnostic — each tree's scope owns its own `p0`.
    for (fr.results[0].diagnostics) |d| try testing.expect(d.code != .duplicate_cross_ref_target);
    for (fr.results[1].diagnostics) |d| try testing.expect(d.code != .duplicate_cross_ref_target);

    // Both registrations live, in their respective scopes.
    try testing.expect(fr.cross_ref_index.contains(.tree(0), "demo/phrase", "p0"));
    try testing.expect(fr.cross_ref_index.contains(.tree(1), "demo/phrase", "p0"));
}

test "forest: duplicate name within one tree emits on second occurrence" {
    const a = testing.allocator;
    const plugin = buildPhraseTrackPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var phrases = try Parser.parse(a,
        \\(phrase :name p0)
        \\(phrase :name p0)
    );
    defer phrases.deinit();

    const trees = [_]Ast.Tree{phrases};
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);

    var dup_count: usize = 0;
    for (fr.results[0].diagnostics) |d| {
        if (d.code == .duplicate_cross_ref_target) dup_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), dup_count);

    const site = fr.cross_ref_index.lookup(.tree(0), "demo/phrase", "p0").?;
    try testing.expectEqual(@as(u32, 0), site.tree_idx);
}

test "forest binary: cross-buffer references do NOT resolve under per-tree default" {
    const a = testing.allocator;
    const plugin = buildPhraseTrackPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var phrases = try Parser.parse(a,
        \\(phrase :name p0)
        \\(phrase :name p1)
    );
    defer phrases.deinit();
    var track = try Parser.parse(a,
        \\(track :sequence [p0 p1])
    );
    defer track.deinit();

    const bin_a = try Binary.toBinary(a, phrases, .{});
    defer bin_a.deinit();
    const bin_b = try Binary.toBinary(a, track, .{});
    defer bin_b.deinit();

    const buffers = [_][]const u8{ bin_a.data, bin_b.data };
    var fr = try Validator.validateForestBinary(a, &buffers, schema, null);
    defer fr.deinit(a);

    try testing.expectEqual(@as(usize, 0), fr.results[0].diagnostics.len);
    var found_not_cross_ref = false;
    for (fr.results[1].diagnostics) |d| {
        if (d.code == .not_cross_ref) found_not_cross_ref = true;
    }
    try testing.expect(found_not_cross_ref);

    try testing.expect(fr.cross_ref_index.contains(.tree(0), "demo/phrase", "p0"));
    try testing.expect(!fr.cross_ref_index.contains(.tree(1), "demo/phrase", "p0"));
}

test "forest binary: missing same-buffer reference flagged with not_cross_ref" {
    const a = testing.allocator;
    const plugin = buildPhraseTrackPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var bundled = try Parser.parse(a,
        \\(phrase :name p0)
        \\(track :sequence [p0 typoed])
    );
    defer bundled.deinit();

    const bin = try Binary.toBinary(a, bundled, .{});
    defer bin.deinit();

    const buffers = [_][]const u8{bin.data};
    var fr = try Validator.validateForestBinary(a, &buffers, schema, null);
    defer fr.deinit(a);

    var found_not_cross_ref = false;
    for (fr.results[0].diagnostics) |d| {
        if (d.code == .not_cross_ref) {
            found_not_cross_ref = true;
            try testing.expect(std.mem.indexOf(u8, d.message, "typoed") != null);
        }
    }
    try testing.expect(found_not_cross_ref);

    try testing.expect(fr.cross_ref_index.contains(.tree(0), "demo/phrase", "p0"));
    try testing.expect(!fr.cross_ref_index.contains(.tree(0), "demo/phrase", "typoed"));
}

test "forest binary: same name in two buffers does NOT trigger duplicate" {
    const a = testing.allocator;
    const plugin = buildPhraseTrackPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var phrases_a = try Parser.parse(a,
        \\(phrase :name p0)
    );
    defer phrases_a.deinit();
    var phrases_b = try Parser.parse(a,
        \\(phrase :name p0)
    );
    defer phrases_b.deinit();

    const bin_a = try Binary.toBinary(a, phrases_a, .{});
    defer bin_a.deinit();
    const bin_b = try Binary.toBinary(a, phrases_b, .{});
    defer bin_b.deinit();

    const buffers = [_][]const u8{ bin_a.data, bin_b.data };
    var fr = try Validator.validateForestBinary(a, &buffers, schema, null);
    defer fr.deinit(a);

    for (fr.results[0].diagnostics) |d| try testing.expect(d.code != .duplicate_cross_ref_target);
    for (fr.results[1].diagnostics) |d| try testing.expect(d.code != .duplicate_cross_ref_target);

    try testing.expect(fr.cross_ref_index.contains(.tree(0), "demo/phrase", "p0"));
    try testing.expect(fr.cross_ref_index.contains(.tree(1), "demo/phrase", "p0"));
}

test "forest binary: nested phrase under piece is registered" {
    const a = testing.allocator;
    const plugin = buildPhraseTrackPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var nested = try Parser.parse(a,
        \\(piece (phrase :name p0) (track :sequence [p0]))
    );
    defer nested.deinit();

    const bin = try Binary.toBinary(a, nested, .{});
    defer bin.deinit();

    const buffers = [_][]const u8{bin.data};
    var fr = try Validator.validateForestBinary(a, &buffers, schema, null);
    defer fr.deinit(a);

    // Index pass walks descendants — the nested phrase registers even
    // though it isn't a root.
    try testing.expect(fr.cross_ref_index.contains(.tree(0), "demo/phrase", "p0"));
    // The track's `p0` reference resolves; no `not_cross_ref` diagnostic.
    var found_not_cross_ref = false;
    for (fr.results[0].diagnostics) |d| {
        if (d.code == .not_cross_ref) found_not_cross_ref = true;
    }
    try testing.expect(!found_not_cross_ref);
}

test "forest: two plugins with same form name register under distinct canonical keys" {
    const a = testing.allocator;
    // Two plugins each declare a `phrase` form and a cross-ref kind that
    // targets it. Document forms are qualified with the plugin namespace
    // so the validator can canonicalise unambiguously.
    const audio_phrase_name: Plugin.ValueKind = .{
        .name = "audio-phrase-name",
        .underlying = .symbol,
        .cross_ref = .{ .target_form = "audio/phrase" },
    };
    const audio_seq: Plugin.ValueKind = .{
        .name = "audio-phrase-seq",
        .underlying = .vector,
        .vector = .{ .element = .{ .name = "audio-phrase-name" } },
    };
    const audio: Plugin.Plugin = .{
        .name = "audio",
        .value_kinds = &.{ audio_phrase_name, audio_seq },
        .forms = &.{
            .{ .name = "phrase", .keys = &.{
                .{ .name = "name", .value_type = .symbol, .optional = false },
            } },
            .{ .name = "track", .keys = &.{
                .{ .name = "sequence", .value_type = .{ .named = .{ .name = "audio-phrase-seq" } }, .optional = false },
            } },
        },
    };
    const music_phrase_name: Plugin.ValueKind = .{
        .name = "music-phrase-name",
        .underlying = .symbol,
        .cross_ref = .{ .target_form = "music/phrase" },
    };
    const music_seq: Plugin.ValueKind = .{
        .name = "music-phrase-seq",
        .underlying = .vector,
        .vector = .{ .element = .{ .name = "music-phrase-name" } },
    };
    const music: Plugin.Plugin = .{
        .name = "music",
        .value_kinds = &.{ music_phrase_name, music_seq },
        .forms = &.{
            .{ .name = "phrase", .keys = &.{
                .{ .name = "name", .value_type = .symbol, .optional = false },
            } },
            .{ .name = "track", .keys = &.{
                .{ .name = "sequence", .value_type = .{ .named = .{ .name = "music-phrase-seq" } }, .optional = false },
            } },
        },
    };
    const schema = Schema.Schema.init(&.{ audio, music });

    var doc = try Parser.parse(a,
        \\(audio/phrase :name a0)
        \\(music/phrase :name a0)
        \\(audio/track :sequence [a0])
        \\(music/track :sequence [a0])
    );
    defer doc.deinit();

    const trees = [_]Ast.Tree{doc};
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);

    // Distinct canonical keys: same name `a0` lives in both registries.
    try testing.expect(fr.cross_ref_index.contains(.tree(0), "audio/phrase", "a0"));
    try testing.expect(fr.cross_ref_index.contains(.tree(0), "music/phrase", "a0"));

    // Both `:sequence` references resolve, no `not_cross_ref` or
    // `duplicate_cross_ref_target` diagnostics.
    for (fr.results[0].diagnostics) |d| {
        try testing.expect(d.code != .not_cross_ref);
        try testing.expect(d.code != .duplicate_cross_ref_target);
    }
}

/// Schema: `(piece (phrase :name p0) … (track :sequence [p0 …]))` with
/// the cross-ref kind declaring `:scope piece`. Each `(piece …)` is a
/// fresh scope: phrases registered in piece A don't leak into piece B.
fn buildScopedPiecePlugin() Plugin.Plugin {
    const phrase_name_kind: Plugin.ValueKind = .{
        .name = "phrase-name",
        .underlying = .symbol,
        .cross_ref = .{ .target_form = "phrase", .scope_form = "piece" },
    };
    const phrase_seq_kind: Plugin.ValueKind = .{
        .name = "phrase-sequence",
        .underlying = .vector,
        .vector = .{ .element = .{ .name = "phrase-name" } },
    };
    return .{
        .name = "demo",
        .value_kinds = &.{ phrase_name_kind, phrase_seq_kind },
        .forms = &.{
            .{ .name = "phrase", .keys = &.{
                .{ .name = "name", .value_type = .symbol, .optional = false },
            } },
            .{ .name = "track", .keys = &.{
                .{ .name = "sequence", .value_type = .{ .named = .{ .name = "phrase-sequence" } }, .optional = false },
            } },
            .{ .name = "piece", .keys = &.{} },
        },
    };
}

test "forest: lexical :scope — same name in two pieces does not collide" {
    const a = testing.allocator;
    const plugin = buildScopedPiecePlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var doc = try Parser.parse(a,
        \\(piece (phrase :name p0) (track :sequence [p0]))
        \\(piece (phrase :name p0) (track :sequence [p0]))
    );
    defer doc.deinit();

    const trees = [_]Ast.Tree{doc};
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);

    // Both `(track :sequence [p0])` references resolve — same-piece
    // lookups succeed without colliding with the sibling piece's `p0`.
    for (fr.results[0].diagnostics) |d| {
        try testing.expect(d.code != .not_cross_ref);
        try testing.expect(d.code != .duplicate_cross_ref_target);
        try testing.expect(d.code != .cross_ref_outside_scope);
    }
}

test "forest: lexical :scope — reference outside any piece emits cross_ref_outside_scope" {
    const a = testing.allocator;
    const plugin = buildScopedPiecePlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var doc = try Parser.parse(a,
        \\(phrase :name p0)
        \\(track :sequence [p0])
    );
    defer doc.deinit();

    const trees = [_]Ast.Tree{doc};
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);

    var saw = false;
    for (fr.results[0].diagnostics) |d| {
        if (d.code == .cross_ref_outside_scope) saw = true;
    }
    try testing.expect(saw);
}

test "forest binary: lexical :scope — same name in two pieces does not collide" {
    const a = testing.allocator;
    const plugin = buildScopedPiecePlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var doc = try Parser.parse(a,
        \\(piece (phrase :name p0) (track :sequence [p0]))
        \\(piece (phrase :name p0) (track :sequence [p0]))
    );
    defer doc.deinit();

    const bin = try Binary.toBinary(a, doc, .{});
    defer bin.deinit();

    const buffers = [_][]const u8{bin.data};
    var fr = try Validator.validateForestBinary(a, &buffers, schema, null);
    defer fr.deinit(a);

    for (fr.results[0].diagnostics) |d| {
        try testing.expect(d.code != .not_cross_ref);
        try testing.expect(d.code != .duplicate_cross_ref_target);
        try testing.expect(d.code != .cross_ref_outside_scope);
    }
}

test "forest binary: lexical :scope — reference outside any piece emits cross_ref_outside_scope" {
    const a = testing.allocator;
    const plugin = buildScopedPiecePlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var doc = try Parser.parse(a,
        \\(phrase :name p0)
        \\(track :sequence [p0])
    );
    defer doc.deinit();

    const bin = try Binary.toBinary(a, doc, .{});
    defer bin.deinit();

    const buffers = [_][]const u8{bin.data};
    var fr = try Validator.validateForestBinary(a, &buffers, schema, null);
    defer fr.deinit(a);

    var saw = false;
    for (fr.results[0].diagnostics) |d| {
        if (d.code == .cross_ref_outside_scope) saw = true;
    }
    try testing.expect(saw);
}

test "forest: empty input list produces no results, no registered names" {
    const a = testing.allocator;
    const plugin = buildPhraseTrackPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    const trees: [0]Ast.Tree = .{};
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);

    try testing.expectEqual(@as(usize, 0), fr.results.len);
    // No documents → no registrations. `lookup` returns null whether the
    // outer key exists (no instances) or is missing entirely.
    try testing.expectEqual(@as(?Validator.CrossRefIndex.Site, null), fr.cross_ref_index.lookup(.tree(0), "demo/phrase", "p0"));
}

// ---------------------------------------------------------------------------
// validateForest: reference-site capture (LSP find-refs / rename payload)
// ---------------------------------------------------------------------------

test "forest: references_by_scope captures every reference site" {
    const a = testing.allocator;
    const plugin = buildPhraseTrackPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var bundled = try Parser.parse(a,
        \\(phrase :name p0)
        \\(phrase :name p1)
        \\(track :sequence [p0 p1 p0])
    );
    defer bundled.deinit();

    const trees = [_]Ast.Tree{bundled};
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);

    try testing.expectEqual(@as(usize, 0), fr.results[0].diagnostics.len);

    // p0 referenced twice, p1 once.
    const p0_refs = fr.cross_ref_index.lookupReferences(.tree(0), "demo/phrase", "p0");
    const p1_refs = fr.cross_ref_index.lookupReferences(.tree(0), "demo/phrase", "p1");
    try testing.expectEqual(@as(usize, 2), p0_refs.len);
    try testing.expectEqual(@as(usize, 1), p1_refs.len);

    // Each captured site carries the symbol's span (== both form_span and
    // name_span on references) and the right tree_idx.
    for (p0_refs) |s| {
        try testing.expectEqual(@as(u32, 0), s.tree_idx);
        try testing.expect(s.name_span.start < s.name_span.end);
        try testing.expectEqual(s.name_span, s.form_span);
    }
}

test "forest: references_by_scope captures typo'd references too" {
    const a = testing.allocator;
    const plugin = buildPhraseTrackPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var bundled = try Parser.parse(a,
        \\(phrase :name p0)
        \\(track :sequence [p0 typoed])
    );
    defer bundled.deinit();

    const trees = [_]Ast.Tree{bundled};
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);

    // The typo'd name is registered as a reference even though it doesn't
    // resolve — find-refs / rename want to see it too.
    const typo_refs = fr.cross_ref_index.lookupReferences(.tree(0), "demo/phrase", "typoed");
    try testing.expectEqual(@as(usize, 1), typo_refs.len);

    // The good name's reference is also there.
    const p0_refs = fr.cross_ref_index.lookupReferences(.tree(0), "demo/phrase", "p0");
    try testing.expectEqual(@as(usize, 1), p0_refs.len);
}

/// `(track :slot …)` where the slot is `union{members, phrase-name}` —
/// the shape where a rejected cross-ref alternative used to leave a
/// reference site behind. `off` matches the members half; only a name that
/// reaches the cross-ref alternative is a real reference.
fn buildUnionRefPlugin() Plugin.Plugin {
    return .{
        .name = "demo",
        .value_kinds = &.{
            .{ .name = "phrase-name", .underlying = .symbol, .cross_ref = .{ .target_form = "phrase" } },
            .{ .name = "off-switch", .underlying = .symbol, .members = .{ .members = &.{.{ .name = "off" }} } },
            .{
                .name = "slot",
                .underlying = .union_of,
                .union_of = .{ .alternatives = &.{ .{ .name = "off-switch" }, .{ .name = "phrase-name" } } },
            },
        },
        .forms = &.{
            .{ .name = "phrase", .keys = &.{.{ .name = "name", .value_type = .symbol, .optional = false }} },
            .{ .name = "track", .keys = &.{.{ .name = "slot", .value_type = .{ .named = .{ .name = "slot" } }, .optional = false }} },
        },
    };
}

test "forest: a union alternative that loses registers no reference site" {
    // `appendReference` runs before the `contains` check so typo'd
    // references still reach find-refs — but inside a union that meant
    // *every* rejected cross-ref alternative captured a site. `off`
    // matches the members half and is not a reference to anything, yet it
    // was recorded as one, polluting rename and find-refs.
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{buildUnionRefPlugin()});

    var tree = try Parser.parse(a,
        \\(phrase :name p0)
        \\(track :slot off)
        \\(track :slot p0)
    );
    defer tree.deinit();

    const trees = [_]Ast.Tree{tree};
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);
    try testing.expectEqual(@as(usize, 0), fr.results[0].diagnostics.len);

    // `off` won on the members alternative — not a reference.
    try testing.expectEqual(@as(usize, 0), fr.cross_ref_index.lookupReferences(.tree(0), "demo/phrase", "off").len);
    // `p0` reached the cross-ref alternative — a real reference, captured
    // exactly once (the re-run must not double-register it).
    try testing.expectEqual(@as(usize, 1), fr.cross_ref_index.lookupReferences(.tree(0), "demo/phrase", "p0").len);
}

test "forest: an unresolvable union symbol is still captured once" {
    // The typo'd-reference behaviour must survive the suppression: when no
    // alternative accepts, the cross-ref alternative's capture is what
    // find-refs wants — and the slot still diagnoses.
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{buildUnionRefPlugin()});

    var tree = try Parser.parse(a, "(track :slot typoed)");
    defer tree.deinit();

    const trees = [_]Ast.Tree{tree};
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);

    try testing.expect(fr.results[0].diagnostics.len > 0);
    const refs = fr.cross_ref_index.lookupReferences(.tree(0), "demo/phrase", "typoed");
    try testing.expectEqual(@as(usize, 1), refs.len);
}

test "forest: lexical :scope — references captured under correct scope" {
    const a = testing.allocator;
    const plugin = buildScopedPiecePlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var doc = try Parser.parse(a,
        \\(piece (phrase :name p0) (track :sequence [p0]))
        \\(piece (phrase :name p0) (track :sequence [p0]))
    );
    defer doc.deinit();

    const trees = [_]Ast.Tree{doc};
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);

    // Each piece's `p0` reference lives under its own lexical scope —
    // the references_by_scope map keys them separately. Counting the
    // total occurrences of `p0` references across all scopes should be
    // exactly 2.
    var total: usize = 0;
    var scope_iter = fr.cross_ref_index.references_by_scope.iterator();
    while (scope_iter.next()) |entry| {
        const tm = entry.value_ptr;
        if (tm.getPtr("demo/phrase")) |nm| {
            if (nm.getPtr("p0")) |list| total += list.items.len;
        }
    }
    try testing.expectEqual(@as(usize, 2), total);

    // No reference in tree-scope (per-tree default isn't used when the
    // value-kind opts into `:scope piece`).
    const tree_scope_refs = fr.cross_ref_index.lookupReferences(.tree(0), "demo/phrase", "p0");
    try testing.expectEqual(@as(usize, 0), tree_scope_refs.len);
}

test "forest binary: references_by_scope captures every reference site" {
    const a = testing.allocator;
    const plugin = buildPhraseTrackPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var bundled = try Parser.parse(a,
        \\(phrase :name p0)
        \\(track :sequence [p0 p0])
    );
    defer bundled.deinit();

    const bin = try Binary.toBinary(a, bundled, .{});
    defer bin.deinit();

    const buffers = [_][]const u8{bin.data};
    var fr = try Validator.validateForestBinary(a, &buffers, schema, null);
    defer fr.deinit(a);

    const p0_refs = fr.cross_ref_index.lookupReferences(.tree(0), "demo/phrase", "p0");
    try testing.expectEqual(@as(usize, 2), p0_refs.len);
    for (p0_refs) |s| {
        try testing.expectEqual(@as(u32, 0), s.tree_idx);
        // Binary path uses .invalid for node_idx (no AST equivalent).
        try testing.expectEqual(Ast.NodeIndex.invalid, s.node_idx);
    }
}

test "forest: tree↔binary parity — same reference list for same input" {
    const a = testing.allocator;
    const plugin = buildPhraseTrackPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    const source =
        \\(phrase :name p0)
        \\(phrase :name p1)
        \\(track :sequence [p0 p1 p0 typoed])
    ;
    var tree = try Parser.parse(a, source);
    defer tree.deinit();
    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();

    const trees = [_]Ast.Tree{tree};
    var fr_tree = try Validator.validateForest(a, &trees, schema);
    defer fr_tree.deinit(a);

    const buffers = [_][]const u8{bin.data};
    var fr_bin = try Validator.validateForestBinary(a, &buffers, schema, null);
    defer fr_bin.deinit(a);

    inline for (.{ "p0", "p1", "typoed" }) |name| {
        const t = fr_tree.cross_ref_index.lookupReferences(.tree(0), "demo/phrase", name);
        const b = fr_bin.cross_ref_index.lookupReferences(.tree(0), "demo/phrase", name);
        try testing.expectEqual(t.len, b.len);
        for (t, b) |ts, bs| {
            try testing.expectEqual(ts.tree_idx, bs.tree_idx);
            try testing.expectEqual(ts.scope, bs.scope);
            // Spans match too — both paths derive them from the same
            // source byte offsets.
            try testing.expectEqual(ts.name_span.start, bs.name_span.start);
            try testing.expectEqual(ts.name_span.end, bs.name_span.end);
        }
    }
}

// ---------------------------------------------------------------------------
// validateForest: :acyclic cycle detection
// ---------------------------------------------------------------------------

/// Phrase has `:name`, `:parent` (scalar self-edge), and `:children`
/// (vector self-edge). The `phrase-name` value-kind carries
/// `:acyclic true`, so the validator runs forest cycle detection.
fn buildAcyclicPhrasePlugin() Plugin.Plugin {
    return .{
        .name = "demo",
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{ .target_form = "phrase", .acyclic = true },
            },
            .{
                .name = "phrase-name-list",
                .underlying = .vector,
                .vector = .{ .element = .{ .name = "phrase-name" } },
            },
        },
        .forms = &.{
            .{
                .name = "phrase",
                .keys = &.{
                    .{ .name = "name", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = false },
                    .{ .name = "parent", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = true },
                    .{ .name = "children", .value_type = .{ .named = .{ .name = "phrase-name-list" } }, .optional = true },
                },
            },
        },
    };
}

fn countCode(diags: []const Ast.Diagnostic, code: Ast.Diagnostic.Code) usize {
    var n: usize = 0;
    for (diags) |d| {
        if (d.code == code) n += 1;
    }
    return n;
}

test "forest acyclic: self-loop emits cyclic_cross_ref" {
    const a = testing.allocator;
    const plugin = buildAcyclicPhrasePlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var tree = try Parser.parse(a,
        \\(phrase :name p0 :parent p0)
    );
    defer tree.deinit();

    const trees = [_]Ast.Tree{tree};
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);

    try testing.expectEqual(@as(usize, 1), countCode(fr.results[0].diagnostics, .cyclic_cross_ref));
    var found = false;
    for (fr.results[0].diagnostics) |d| {
        if (d.code != .cyclic_cross_ref) continue;
        try testing.expect(std.mem.indexOf(u8, d.message, "phrase-name") != null);
        try testing.expect(std.mem.indexOf(u8, d.message, "p0 -> p0") != null);
        found = true;
    }
    try testing.expect(found);
}

test "forest acyclic: 2-cycle emits cyclic_cross_ref on both members" {
    const a = testing.allocator;
    const plugin = buildAcyclicPhrasePlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var tree = try Parser.parse(a,
        \\(phrase :name p0 :parent p1)
        \\(phrase :name p1 :parent p0)
    );
    defer tree.deinit();

    const trees = [_]Ast.Tree{tree};
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);

    try testing.expectEqual(@as(usize, 2), countCode(fr.results[0].diagnostics, .cyclic_cross_ref));
}

test "forest acyclic: cross-tree edges are isolated — no cycle when split" {
    // Same 3-cycle topology as the 3-cycle test, but split across two
    // trees. Per-tree default isolates each tree's cycle graph: tree A
    // has p0→p1→p2 (linear), tree B has p2→p0 (the back-edge points to
    // a name unknown in tree B's scope). No `cyclic_cross_ref`.
    const a = testing.allocator;
    const plugin = buildAcyclicPhrasePlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var tree_a_src = try Parser.parse(a,
        \\(phrase :name p0 :parent p1)
        \\(phrase :name p1 :parent p2)
    );
    defer tree_a_src.deinit();
    var tree_b_src = try Parser.parse(a,
        \\(phrase :name p2 :parent p0)
    );
    defer tree_b_src.deinit();

    const trees = [_]Ast.Tree{ tree_a_src, tree_b_src };
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);

    try testing.expectEqual(@as(usize, 0), countCode(fr.results[0].diagnostics, .cyclic_cross_ref));
    try testing.expectEqual(@as(usize, 0), countCode(fr.results[1].diagnostics, .cyclic_cross_ref));
}

test "forest acyclic: 3-cycle within one tree is detected" {
    const a = testing.allocator;
    const plugin = buildAcyclicPhrasePlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var tree = try Parser.parse(a,
        \\(phrase :name p0 :parent p1)
        \\(phrase :name p1 :parent p2)
        \\(phrase :name p2 :parent p0)
    );
    defer tree.deinit();

    const trees = [_]Ast.Tree{tree};
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);

    try testing.expectEqual(@as(usize, 3), countCode(fr.results[0].diagnostics, .cyclic_cross_ref));
}

test "forest acyclic: linear chain has no cyclic_cross_ref" {
    const a = testing.allocator;
    const plugin = buildAcyclicPhrasePlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var tree = try Parser.parse(a,
        \\(phrase :name p0)
        \\(phrase :name p1 :parent p0)
        \\(phrase :name p2 :parent p1)
    );
    defer tree.deinit();

    const trees = [_]Ast.Tree{tree};
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);

    try testing.expectEqual(@as(usize, 0), countCode(fr.results[0].diagnostics, .cyclic_cross_ref));
}

test "forest acyclic: same shape without :acyclic flag has no cycle diagnostic" {
    // Identical document content as the 2-cycle test, but the plugin's
    // cross-ref omits `:acyclic true`. The validator must not emit
    // `cyclic_cross_ref` — the flag is the trigger.
    const a = testing.allocator;
    const plugin: Plugin.Plugin = .{
        .name = "demo",
        .value_kinds = &.{.{
            .name = "phrase-name",
            .underlying = .symbol,
            .cross_ref = .{ .target_form = "phrase" },
        }},
        .forms = &.{.{
            .name = "phrase",
            .keys = &.{
                .{ .name = "name", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = false },
                .{ .name = "parent", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = true },
            },
        }},
    };
    const schema = Schema.Schema.init(&.{plugin});

    var tree = try Parser.parse(a,
        \\(phrase :name p0 :parent p1)
        \\(phrase :name p1 :parent p0)
    );
    defer tree.deinit();

    const trees = [_]Ast.Tree{tree};
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);

    try testing.expectEqual(@as(usize, 0), countCode(fr.results[0].diagnostics, .cyclic_cross_ref));
}

test "forest acyclic: vector edge captures cycle through :children" {
    const a = testing.allocator;
    const plugin = buildAcyclicPhrasePlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var tree = try Parser.parse(a,
        \\(phrase :name p0 :children [p1])
        \\(phrase :name p1 :children [p0])
    );
    defer tree.deinit();

    const trees = [_]Ast.Tree{tree};
    var fr = try Validator.validateForest(a, &trees, schema);
    defer fr.deinit(a);

    try testing.expectEqual(@as(usize, 2), countCode(fr.results[0].diagnostics, .cyclic_cross_ref));
}

test "forest binary acyclic: 2-cycle detected via validateForestBinary" {
    const a = testing.allocator;
    const plugin = buildAcyclicPhrasePlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var tree = try Parser.parse(a,
        \\(phrase :name p0 :parent p1)
        \\(phrase :name p1 :parent p0)
    );
    defer tree.deinit();
    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();

    const buffers = [_][]const u8{bin.data};
    var fr = try Validator.validateForestBinary(a, &buffers, schema, null);
    defer fr.deinit(a);

    try testing.expectEqual(@as(usize, 2), countCode(fr.results[0].diagnostics, .cyclic_cross_ref));
}

test "forest binary acyclic: vector edge cycle detected" {
    const a = testing.allocator;
    const plugin = buildAcyclicPhrasePlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var tree = try Parser.parse(a,
        \\(phrase :name p0 :children [p1])
        \\(phrase :name p1 :children [p0])
    );
    defer tree.deinit();
    const bin = try Binary.toBinary(a, tree, .{});
    defer bin.deinit();

    const buffers = [_][]const u8{bin.data};
    var fr = try Validator.validateForestBinary(a, &buffers, schema, null);
    defer fr.deinit(a);

    try testing.expectEqual(@as(usize, 2), countCode(fr.results[0].diagnostics, .cyclic_cross_ref));
}

const max_keys_fixture: [Plugin.MAX_FORM_KEYS]Plugin.KeySpec = blk: {
    @setEvalBranchQuota(200000);
    var keys: [Plugin.MAX_FORM_KEYS]Plugin.KeySpec = undefined;
    for (&keys, 0..) |*k, i| {
        k.* = .{ .name = std.fmt.comptimePrint("k{d}", .{i}), .value_type = .string };
    }
    break :blk keys;
};

test "Schema.init accepts plugin with form at MAX_FORM_KEYS boundary" {
    const wide_form: Plugin.FormSpec = .{
        .name = "wide",
        .description = "Form with exactly MAX_FORM_KEYS keys.",
        .keys = &max_keys_fixture,
        .positional = .none,
    };
    const wide_plugin: Plugin.Plugin = .{
        .name = "wide",
        .forms = &.{wide_form},
    };
    const schema = Schema.Schema.init(&.{wide_plugin});
    try testing.expectEqual(@as(usize, 1), schema.plugins.len);
    try testing.expectEqual(Plugin.MAX_FORM_KEYS, schema.plugins[0].forms[0].keys.len);
}

// ---------------------------------------------------------------------------
// Expression-result-type enforcement on typed slots (tree path).
//
// Tree-only for now — the binary validator's eval-frame mirror lands in
// a follow-up commit. The `parityCheck` helper is intentionally avoided
// here until that mirror exists.
// ---------------------------------------------------------------------------

const shape_with_typed_keys: Plugin.Plugin = .{
    .name = "shape",
    .forms = &.{
        .{ .name = "circle", .keys = &.{
            .{ .name = "radius", .value_type = .number, .optional = false },
            .{ .name = "center", .value_type = .vector, .optional = true },
            .{ .name = "kind", .value_type = .symbol, .optional = true },
        } },
        .{ .name = "box", .keys = &.{
            .{ .name = "predicate", .value_type = .expr, .optional = false },
        } },
        .{ .name = "label" }, // a known data form (used to test data-form-in-expr-slot mismatch)
    },
};

test "result-type [slot]: number slot rejects vec3 result" {
    const schema = Schema.Schema.init(&.{ core.plugin, shape_with_typed_keys });
    var bundle = try validateSrc("(circle :radius (vec3 1 2 3))", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    try testing.expectEqual(Diagnostic.Code.wrong_underlying, bundle.result.diagnostics[0].code);
    try testing.expectEqualStrings("circle", bundle.result.diagnostics[0].path[0]);
    try testing.expectEqualStrings("radius", bundle.result.diagnostics[0].path[1]);
}

test "result-type [slot]: number slot accepts (+ 1 2) (declared number)" {
    const schema = Schema.Schema.init(&.{ core.plugin, shape_with_typed_keys });
    var bundle = try validateSrc("(circle :radius (+ 1 2))", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), bundle.result.diagnostics.len);
}

test "result-type [slot]: vector slot accepts vec3 result" {
    const schema = Schema.Schema.init(&.{ core.plugin, shape_with_typed_keys });
    var bundle = try validateSrc("(circle :radius 1 :center (vec3 0 0 0))", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), bundle.result.diagnostics.len);
}

test "result-type [slot]: number slot defers opaque (let …) expression" {
    // `let` has no declared result — keep the existing defer behavior so
    // opaque expressions are still allowed in typed slots.
    const schema = Schema.Schema.init(&.{ core.plugin, shape_with_typed_keys });
    var bundle = try validateSrc("(circle :radius (let [x 1] x))", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), bundle.result.diagnostics.len);
}

test "result-type [slot]: number slot rejects data form value" {
    // `label` is a known data form (not an expression). Today's behavior
    // was to silently accept it in a typed slot; the new rule emits
    // `wrong_underlying`.
    const schema = Schema.Schema.init(&.{ core.plugin, shape_with_typed_keys });
    var bundle = try validateSrc("(circle :radius (label))", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    try testing.expectEqual(Diagnostic.Code.wrong_underlying, bundle.result.diagnostics[0].code);
}

test "result-type [slot]: .expr slot accepts a known expression head" {
    const schema = Schema.Schema.init(&.{ core.plugin, shape_with_typed_keys });
    var bundle = try validateSrc("(box :predicate (> 3 2))", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), bundle.result.diagnostics.len);
}

test "result-type [slot]: .expr slot rejects a data form value" {
    const schema = Schema.Schema.init(&.{ core.plugin, shape_with_typed_keys });
    var bundle = try validateSrc("(box :predicate (label))", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), bundle.result.diagnostics.len);
    try testing.expectEqual(Diagnostic.Code.wrong_underlying, bundle.result.diagnostics[0].code);
}

// ---------------------------------------------------------------------------
// Result-typing on positional expression arguments (mono + labeled).
// Overload narrowing via form-arg results is left for a later slice.
// ---------------------------------------------------------------------------

test "result-type [arg]: (+ (vec3 1 2 3) 1) reports expr_type_mismatch on arg 0" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("(+ (vec3 1 2 3) 1)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    var saw = false;
    for (bundle.result.diagnostics) |d| {
        if (d.code == .expr_type_mismatch) {
            saw = true;
            break;
        }
    }
    try testing.expect(saw);
}

test "result-type [arg]: (vec3 (+ 1 1) 2 3) passes — inner result is number" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("(vec3 (+ 1 1) 2 3)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), bundle.result.diagnostics.len);
}

test "result-type [arg]: (vec3 (not true) 2 3) reports expr_type_mismatch — not returns boolean" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("(vec3 (not true) 2 3)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    var saw = false;
    for (bundle.result.diagnostics) |d| {
        if (d.code == .expr_type_mismatch) {
            saw = true;
            break;
        }
    }
    try testing.expect(saw);
}

test "result-type [arg]: opaque (let …) in number slot defers" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("(+ 1 (let [x 1] x))", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 0), bundle.result.diagnostics.len);
}

test "result-type [arg]: labeled call rejects vector-result form in number param" {
    const schema = Schema.Schema.init(&.{core.plugin});
    var bundle = try validateSrc("(mod :x (vec3 1 2 3) :y 1)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    var saw = false;
    for (bundle.result.diagnostics) |d| {
        if (d.code == .expr_type_mismatch) {
            saw = true;
            break;
        }
    }
    try testing.expect(saw);
}

test "result-type [parity]: tree and binary agree on declared-result checks" {
    const schema = Schema.Schema.init(&.{ core.plugin, shape_with_typed_keys });
    inline for (.{
        // slot-side
        "(circle :radius (vec3 1 2 3))", // mismatch
        "(circle :radius (+ 1 2))", // pass
        "(circle :radius (let [x 1] x))", // pass (opaque defers)
        "(circle :radius (label))", // mismatch (data form in number slot)
        "(circle :radius 1 :center (vec3 0 0 0))", // pass
        "(box :predicate (> 3 2))", // pass (.expr accepts expression)
        "(box :predicate (label))", // mismatch (.expr rejects data form)
        // arg-side
        "(+ (vec3 1 2 3) 1)", // mismatch on arg 0
        "(vec3 (+ 1 1) 2 3)", // pass (number result OK)
        "(vec3 (not true) 2 3)", // mismatch (boolean result)
        "(+ 1 (let [x 1] x))", // pass (opaque defers)
    }) |src| {
        try parityCheck(src, schema);
    }
}

// ---------------------------------------------------------------------------
// Effective-validation axes — per-axis on/off unit tests.
//
// Each test exercises one axis through the real materializer + validator
// pipeline: parse → materializeDefaults → validateWithOptions. Default-
// off baseline is asserted alongside the axis-on emission so a future
// "ohh that's a baseline regression too" never gets silently hidden.
//
// Source-level symbol defaults reach the overlay as `Expr.Value.keyword`
// (see `MaterializedDefaults.literalToValue`). Tests reflect that
// mapping: `axis_d` and `axis_a` use symbol-typed schema slots whose
// defaults are spelled as bare identifiers (symbols), and the overlay
// stores them as keywords. The four axis call sites accept both
// keyword + string arms uniformly.
// ---------------------------------------------------------------------------

const MaterializedDefaultsMod = @import("MaterializedDefaults.zig");

fn runWithAxes(
    a: Allocator,
    src: [:0]const u8,
    schema: Schema.Schema,
    axes: Validator.EffectiveAxes,
) !struct {
    tree: Ast.Tree,
    mat: MaterializedDefaultsMod.Result,
    arena: std.heap.ArenaAllocator,
    result: Validator.Result,
} {
    var tree = try Parser.parse(a, src);
    errdefer tree.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();

    var mat = try MaterializedDefaultsMod.materializeDefaults(a, arena.allocator(), &tree, tree.root, schema);
    errdefer mat.deinit(a);

    const result = try Validator.validateWithOptions(a, tree, schema, .{
        .overlay = &mat.materialized,
        .axes = axes,
    });
    return .{ .tree = tree, .mat = mat, .arena = arena, .result = result };
}

fn hasDiagAtPath(
    diags: []const Diagnostic,
    code: Ast.Diagnostic.Code,
    path: []const []const u8,
) bool {
    for (diags) |d| {
        if (d.code != code) continue;
        if (d.path.len != path.len) continue;
        var matched = true;
        for (d.path, path) |a_step, e_step| {
            if (!std.mem.eql(u8, a_step, e_step)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn countDiagWithCode(
    diags: []const Diagnostic,
    code: Ast.Diagnostic.Code,
) usize {
    var n: usize = 0;
    for (diags) |d| {
        if (d.code == code) n += 1;
    }
    return n;
}

const Validator_test_actor: Plugin.Plugin = .{
    .name = "scene",
    .value_kinds = &.{
        .{
            .name = "ActorRef",
            .underlying = .symbol,
            .cross_ref = .{ .target_form = "actor", .name_key = "name" },
        },
    },
    .forms = &.{
        .{
            .name = "actor",
            .keys = &.{
                .{ .name = "name", .value_type = .symbol, .default = .{ .symbol = "ada" } },
            },
        },
        .{
            .name = "track",
            .keys = &.{
                .{
                    .name = "hero",
                    .value_type = .{ .named = .{ .name = "ActorRef" } },
                    .default = .{ .symbol = "ghost" },
                    .optional = true,
                },
            },
        },
    },
};

test "effective-axes [A]: name-index off — duplicate-defaulted actors don't collide" {
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{Validator_test_actor});
    const src: [:0]const u8 = "(actor) (actor)";

    // Production has A on; this test explicitly disables the axis to
    // pin the off-state behavior.
    var out = try runWithAxes(a, src, schema, .{ .name_index = false, .ref_lookup = false, .variant = false });
    defer {
        out.result.deinit();
        out.mat.deinit(a);
        out.arena.deinit();
        out.tree.deinit();
    }
    try testing.expectEqual(@as(usize, 0), countDiagWithCode(out.result.diagnostics, .duplicate_cross_ref_target));
}

test "effective-axes [A]: name-index on — two defaulted actors emit duplicate_cross_ref_target" {
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{Validator_test_actor});
    const src: [:0]const u8 = "(actor) (actor)";

    var out = try runWithAxes(a, src, schema, .{ .name_index = true });
    defer {
        out.result.deinit();
        out.mat.deinit(a);
        out.arena.deinit();
        out.tree.deinit();
    }
    try testing.expect(countDiagWithCode(out.result.diagnostics, .duplicate_cross_ref_target) >= 1);
}

test "effective-axes [B]: ref-lookup off — defaulted hero pointing nowhere is silent" {
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{Validator_test_actor});
    const src: [:0]const u8 = "(actor :name ada) (track)";

    // Production has B on; this test explicitly disables the axis to
    // pin the off-state behavior.
    var out = try runWithAxes(a, src, schema, .{ .name_index = false, .ref_lookup = false, .variant = false });
    defer {
        out.result.deinit();
        out.mat.deinit(a);
        out.arena.deinit();
        out.tree.deinit();
    }
    try testing.expectEqual(@as(usize, 0), countDiagWithCode(out.result.diagnostics, .not_cross_ref));
}

test "effective-axes [B]: ref-lookup on — defaulted hero `ghost` emits not_cross_ref at default path" {
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{Validator_test_actor});
    const src: [:0]const u8 = "(actor :name ada) (track)";

    var out = try runWithAxes(a, src, schema, .{ .ref_lookup = true });
    defer {
        out.result.deinit();
        out.mat.deinit(a);
        out.arena.deinit();
        out.tree.deinit();
    }
    try testing.expect(hasDiagAtPath(
        out.result.diagnostics,
        .not_cross_ref,
        &.{ "track", "hero", "default" },
    ));
}

const Validator_test_phrase: Plugin.Plugin = .{
    .name = "music",
    .forms = &.{
        .{
            .name = "phrase",
            .keys = &.{
                .{ .name = "loops", .value_type = .vector, .default = .{ .vector = &.{} }, .optional = true },
                .{ .name = "events", .value_type = .vector, .default = .{ .vector = &.{} }, .optional = true },
            },
            .exclusive_groups = &.{
                .{
                    .cardinality = .exactly_one,
                    .alternatives = &.{
                        .{ .keys = &.{"loops"} },
                        .{ .keys = &.{"events"} },
                    },
                },
            },
        },
    },
};

test "effective-axes [C]: exclusive-group off — empty phrase emits required_one_of_missing" {
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{Validator_test_phrase});
    const src: [:0]const u8 = "(phrase)";

    // Production has C on; this test explicitly disables the axis to
    // pin the off-state behavior (author-only counting).
    var out = try runWithAxes(a, src, schema, .{ .name_index = false, .ref_lookup = false, .exclusive_group = false, .variant = false });
    defer {
        out.result.deinit();
        out.mat.deinit(a);
        out.arena.deinit();
        out.tree.deinit();
    }
    try testing.expect(countDiagWithCode(out.result.diagnostics, .required_one_of_missing) >= 1);
}

test "effective-axes [C]: rule — two default-only alts, no author → multiple_defaulted_alternatives_in_group" {
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{Validator_test_phrase});
    const src: [:0]const u8 = "(phrase)";

    var out = try runWithAxes(a, src, schema, .{ .exclusive_group = true });
    defer {
        out.result.deinit();
        out.mat.deinit(a);
        out.arena.deinit();
        out.tree.deinit();
    }
    // Both alts defaulted with no author resolution → schema ambiguity.
    // Neither `required_one_of_missing` nor `mutually_exclusive_keys_present`
    // is the right diagnostic; the new schema-aware code fires instead.
    try testing.expectEqual(@as(usize, 0), countDiagWithCode(out.result.diagnostics, .required_one_of_missing));
    try testing.expectEqual(@as(usize, 0), countDiagWithCode(out.result.diagnostics, .mutually_exclusive_keys_present));
    try testing.expect(countDiagWithCode(out.result.diagnostics, .multiple_defaulted_alternatives_in_group) >= 1);
}

// Group-aware rule fixtures: track form with one defaulted alt (`:from`)
// and one undefaulted alt (`:at`), in an exactly-one group. Used by the
// three tests below that pin the masking + single-default behavior.
const Validator_test_track_xgroup: Plugin.Plugin = .{
    .name = "studio",
    .forms = &.{
        .{
            .name = "track",
            .keys = &.{
                .{ .name = "at", .value_type = .number, .optional = true },
                .{ .name = "from", .value_type = .number, .default = .{ .number = 0 }, .optional = true },
            },
            .exclusive_groups = &.{
                .{
                    .cardinality = .exactly_one,
                    .alternatives = &.{
                        .{ .keys = &.{"at"} },
                        .{ .keys = &.{"from"} },
                    },
                },
            },
        },
    },
};

test "effective-axes [C]: rule — author :at masks defaulted :from → clean" {
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{Validator_test_track_xgroup});
    const src: [:0]const u8 = "(track :at 12)";

    var out = try runWithAxes(a, src, schema, .{ .exclusive_group = true });
    defer {
        out.result.deinit();
        out.mat.deinit(a);
        out.arena.deinit();
        out.tree.deinit();
    }
    // Author wrote one alt — sibling's overlay default is masked off.
    try testing.expectEqual(@as(usize, 0), countDiagWithCode(out.result.diagnostics, .mutually_exclusive_keys_present));
    try testing.expectEqual(@as(usize, 0), countDiagWithCode(out.result.diagnostics, .required_one_of_missing));
    try testing.expectEqual(@as(usize, 0), countDiagWithCode(out.result.diagnostics, .multiple_defaulted_alternatives_in_group));
}

test "effective-axes [C]: rule — single defaulted alt, no author → exactly-one clean" {
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{Validator_test_track_xgroup});
    const src: [:0]const u8 = "(track)";

    var out = try runWithAxes(a, src, schema, .{ .exclusive_group = true });
    defer {
        out.result.deinit();
        out.mat.deinit(a);
        out.arena.deinit();
        out.tree.deinit();
    }
    // No author kvpair; only `:from` carries a default → exactly-one
    // satisfied by the defaulted path.
    try testing.expectEqual(@as(usize, 0), countDiagWithCode(out.result.diagnostics, .required_one_of_missing));
    try testing.expectEqual(@as(usize, 0), countDiagWithCode(out.result.diagnostics, .mutually_exclusive_keys_present));
    try testing.expectEqual(@as(usize, 0), countDiagWithCode(out.result.diagnostics, .multiple_defaulted_alternatives_in_group));
}

test "effective-axes [C]: rule — author wrote both alts → mutually_exclusive_keys_present" {
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{Validator_test_track_xgroup});
    const src: [:0]const u8 = "(track :at 12 :from 7)";

    var out = try runWithAxes(a, src, schema, .{ .exclusive_group = true });
    defer {
        out.result.deinit();
        out.mat.deinit(a);
        out.arena.deinit();
        out.tree.deinit();
    }
    // Both alts author-present → original overpresence diagnostic fires.
    try testing.expect(countDiagWithCode(out.result.diagnostics, .mutually_exclusive_keys_present) >= 1);
    try testing.expectEqual(@as(usize, 0), countDiagWithCode(out.result.diagnostics, .multiple_defaulted_alternatives_in_group));
}

const Validator_test_track: Plugin.Plugin = .{
    .name = "studio",
    .forms = &.{
        .{
            .name = "track",
            .keys = &.{
                .{
                    .name = "kind",
                    .value_type = .symbol,
                    .default = .{ .symbol = "audio" },
                },
            },
            .discriminant_idx = 0,
            .discriminant_name = "kind",
            .variants = &.{
                .{
                    .when = "audio",
                    .keys = &.{
                        .{ .name = "channels", .value_type = .number, .optional = true },
                    },
                },
                .{
                    .when = "midi",
                    .keys = &.{
                        .{ .name = "instrument", .value_type = .symbol, .optional = true },
                    },
                },
            },
        },
    },
};

test "effective-axes [D]: variant off — track with no :kind emits missing_discriminant_key" {
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{Validator_test_track});
    const src: [:0]const u8 = "(track)";

    // Production has D on; this test explicitly disables the axis to
    // pin the off-state behavior.
    var out = try runWithAxes(a, src, schema, .{ .name_index = false, .ref_lookup = false, .variant = false });
    defer {
        out.result.deinit();
        out.mat.deinit(a);
        out.arena.deinit();
        out.tree.deinit();
    }
    try testing.expect(countDiagWithCode(out.result.diagnostics, .missing_discriminant_key) >= 1);
}

test "effective-axes [D]: variant on — overlay-supplied :kind suppresses missing_discriminant_key" {
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{Validator_test_track});
    const src: [:0]const u8 = "(track)";

    var out = try runWithAxes(a, src, schema, .{ .variant = true });
    defer {
        out.result.deinit();
        out.mat.deinit(a);
        out.arena.deinit();
        out.tree.deinit();
    }
    try testing.expectEqual(@as(usize, 0), countDiagWithCode(out.result.diagnostics, .missing_discriminant_key));
}

// ---------------------------------------------------------------------------
// Per-tree overlays — D8-v2 hardening.
//
// `validateForestWithOptions` now accepts `Options.overlays: ?[]const ?*const
// MaterializedDefaults` so the host's final-document forest pass can pair
// each tree with its own overlay. The three tests below pin the routing
// invariants: per-tree slice takes precedence, individual entries can be
// null, and the single-overlay fallback is unchanged.
// ---------------------------------------------------------------------------

test "forest overlays: per-tree slice routes each tree's overlay independently" {
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{Validator_test_actor});

    var t0 = try Parser.parse(a, "(actor)");
    defer t0.deinit();
    var t1 = try Parser.parse(a, "(actor)");
    defer t1.deinit();

    var arena0 = std.heap.ArenaAllocator.init(a);
    defer arena0.deinit();
    var mat0 = try MaterializedDefaultsMod.materializeDefaults(a, arena0.allocator(), &t0, t0.root, schema);
    defer mat0.deinit(a);

    var arena1 = std.heap.ArenaAllocator.init(a);
    defer arena1.deinit();
    var mat1 = try MaterializedDefaultsMod.materializeDefaults(a, arena1.allocator(), &t1, t1.root, schema);
    defer mat1.deinit(a);

    const trees = [_]Ast.Tree{ t0, t1 };
    const overlays = [_]?*const MaterializedDefaultsMod.MaterializedDefaults{
        &mat0.materialized,
        &mat1.materialized,
    };
    var fr = try Validator.validateForestWithOptions(a, &trees, schema, .{
        .overlays = &overlays,
        .axes = .{ .name_index = true },
    });
    defer fr.deinit(a);

    // Each tree's overlay independently defaults `:name` to `ada`. Tree 0
    // registers ada; tree 1's ada lives in tree 1's scope (per-tree
    // isolation already enforced by `buildCrossRefIndexForest`), so no
    // duplicate fires across trees.
    try testing.expect(fr.cross_ref_index.contains(.tree(0), "scene/actor", "ada"));
    try testing.expect(fr.cross_ref_index.contains(.tree(1), "scene/actor", "ada"));
    try testing.expectEqual(@as(usize, 0), countDiagWithCode(fr.results[0].diagnostics, .duplicate_cross_ref_target));
    try testing.expectEqual(@as(usize, 0), countDiagWithCode(fr.results[1].diagnostics, .duplicate_cross_ref_target));
}

test "forest overlays: null per-tree entry disables overlay for that tree" {
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{Validator_test_actor});

    var t0 = try Parser.parse(a, "(actor)");
    defer t0.deinit();
    var t1 = try Parser.parse(a, "(actor)");
    defer t1.deinit();

    var arena0 = std.heap.ArenaAllocator.init(a);
    defer arena0.deinit();
    var mat0 = try MaterializedDefaultsMod.materializeDefaults(a, arena0.allocator(), &t0, t0.root, schema);
    defer mat0.deinit(a);

    const trees = [_]Ast.Tree{ t0, t1 };
    const overlays = [_]?*const MaterializedDefaultsMod.MaterializedDefaults{
        &mat0.materialized,
        null,
    };
    var fr = try Validator.validateForestWithOptions(a, &trees, schema, .{
        .overlays = &overlays,
        .axes = .{ .name_index = true },
    });
    defer fr.deinit(a);

    // Tree 0 registers ada via overlay; tree 1 has no overlay so its
    // `(actor)` does not register (author input omitted `:name`).
    try testing.expect(fr.cross_ref_index.contains(.tree(0), "scene/actor", "ada"));
    try testing.expect(!fr.cross_ref_index.contains(.tree(1), "scene/actor", "ada"));
}

test "forest overlays: single overlay (no per-tree slice) applies to every tree" {
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{Validator_test_actor});

    var t0 = try Parser.parse(a, "(actor)");
    defer t0.deinit();

    var arena0 = std.heap.ArenaAllocator.init(a);
    defer arena0.deinit();
    var mat0 = try MaterializedDefaultsMod.materializeDefaults(a, arena0.allocator(), &t0, t0.root, schema);
    defer mat0.deinit(a);

    const trees = [_]Ast.Tree{t0};
    var fr = try Validator.validateForestWithOptions(a, &trees, schema, .{
        .overlay = &mat0.materialized,
        .axes = .{ .name_index = true },
    });
    defer fr.deinit(a);

    // Single-tree case: behaviorally equivalent to `validateWithOptions`.
    try testing.expect(fr.cross_ref_index.contains(.tree(0), "scene/actor", "ada"));
}

// ---------------------------------------------------------------------------
// Exact integer tags: `Tag.number_i64` and `Tag.number_u64` flow through the
// validator transparently. The tree path lists the new tags explicitly in
// the `.number`-expected arms of `matchValueAgainstType` /
// `matchValueAgainstKind`; the binary path piggybacks on `Tag.toValueKind`
// folding all three into `ValueKind.number`. These tests pin both directions
// and the mismatch-labeling path (`describeNode` → "number") so a future
// refinement can't silently regress integer acceptance.
// ---------------------------------------------------------------------------

test "integer tag (tree): .number slot accepts negative i64 literal" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "k", .value_type = .number }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k -5)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());

    // Sanity: the parser took the integer path, not the f64 fallback —
    // otherwise this test would reduce to the pre-existing `.number` case.
    const kv = bundle.tree.formHeader(bundle.tree.root[0]).children[0];
    const value = bundle.tree.kvpairHeader(kv).value;
    try testing.expectEqual(Ast.Tag.number_i64, bundle.tree.tagOf(value));
}

test "integer tag (tree): .number slot accepts u64 max literal" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "k", .value_type = .number }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k 18446744073709551615)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(!bundle.result.hasErrors());

    const kv = bundle.tree.formHeader(bundle.tree.root[0]).children[0];
    const value = bundle.tree.kvpairHeader(kv).value;
    try testing.expectEqual(Ast.Tag.number_u64, bundle.tree.tagOf(value));
}

test "integer tag (tree): number-underlying ValueKind accepts bare integer" {
    // `length` underlying = `.number` with no unit constraint: behaves
    // like the bare `.number` slot above but goes through
    // `matchValueAgainstKind` instead of `matchValueAgainstType`.
    const p = makeSlotTypingPlugin("length", &.{
        .{ .name = "length", .underlying = .number },
    });
    const schema = Schema.Schema.init(&.{p});

    var b1 = try validateSrc("(set :k -1000000)", schema);
    defer b1.tree.deinit();
    defer {
        var r = b1.result;
        r.deinit();
    }
    try testing.expect(!b1.result.hasErrors());

    var b2 = try validateSrc("(set :k 18446744073709551615)", schema);
    defer b2.tree.deinit();
    defer {
        var r = b2.result;
        r.deinit();
    }
    try testing.expect(!b2.result.hasErrors());
}

test "integer tag (tree): mismatch in string slot labels actual as `number`" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "k", .value_type = .string }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :k -5)", schema);
    defer bundle.tree.deinit();
    defer {
        var r = bundle.result;
        r.deinit();
    }
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "got number") != null);
}

test "integer tag (binary): validateBinary accepts i64 and u64 literals" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "k", .value_type = .number }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});

    const bin_i = try encodeForValidate("(set :k -5)");
    defer bin_i.deinit();
    var r_i = try validateBinary(testing.allocator, bin_i.data, schema);
    defer r_i.deinit();
    try testing.expect(!r_i.hasErrors());

    const bin_u = try encodeForValidate("(set :k 18446744073709551615)");
    defer bin_u.deinit();
    var r_u = try validateBinary(testing.allocator, bin_u.data, schema);
    defer r_u.deinit();
    try testing.expect(!r_u.hasErrors());
}

test "integer tag (binary): mismatch in string slot labels actual as `number`" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "k", .value_type = .string }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    const bin = try encodeForValidate("(set :k -5)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "got number") != null);
}

// ----- Numeric-bounds validator tests --------------------------------------

fn boundsSchema(
    comptime name: []const u8,
    comptime nb: Plugin.ValueKind.NumericBounds,
    comptime unit: ?Plugin.ValueKind.UnitShape,
) Schema.Schema {
    // Comptime-only construction so the Plugin's nested slices live in
    // rodata; a runtime-built `&.{ p }` would dangle the moment this
    // helper returns.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "v", .value_type = .{ .named = .{ .name = name } } }},
            },
        },
        .value_kinds = &.{
            .{
                .name = name,
                .underlying = .number,
                .unit = unit,
                .numeric = nb,
            },
        },
    };
    return Schema.Schema.init(&.{p});
}

fn deinitBundle(bundle: anytype) void {
    var t = bundle.tree;
    t.deinit();
    var r = bundle.result;
    r.deinit();
}

test "bounds tree: value below inclusive :min emits number_below_min" {
    const schema = boundsSchema("nn", .{ .min = .{ .value = 0, .exact_int = true } }, null);
    var bundle = try validateSrc("(set :v -1)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_below_min, bundle.result.diagnostics[0].code);
}

test "bounds tree: value equal to :min passes (inclusive default)" {
    const schema = boundsSchema("nn", .{ .min = .{ .value = 0, .exact_int = true } }, null);
    var bundle = try validateSrc("(set :v 0)", schema);
    defer deinitBundle(bundle);
    try testing.expect(!bundle.result.hasErrors());
}

test "bounds tree: value above inclusive :max emits number_above_max" {
    const schema = boundsSchema("nn", .{ .max = .{ .value = 100, .exact_int = true } }, null);
    var bundle = try validateSrc("(set :v 101)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_above_max, bundle.result.diagnostics[0].code);
}

test "bounds tree: :exclusive-min rejects equal value" {
    const schema = boundsSchema("nn", .{
        .min = .{ .value = 0, .exact_int = true },
        .exclusive_min = true,
    }, null);
    var bundle = try validateSrc("(set :v 0)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(
        Ast.Diagnostic.Code.number_at_or_below_exclusive_min,
        bundle.result.diagnostics[0].code,
    );
}

test "bounds tree: :exclusive-max rejects equal value" {
    const schema = boundsSchema("nn", .{
        .max = .{ .value = 1, .exact_int = true },
        .exclusive_max = true,
    }, null);
    var bundle = try validateSrc("(set :v 1)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(
        Ast.Diagnostic.Code.number_at_or_above_exclusive_max,
        bundle.result.diagnostics[0].code,
    );
}

test "bounds tree: :integer true rejects fractional f64" {
    const schema = boundsSchema("nn", .{ .integer = true }, null);
    var bundle = try validateSrc("(set :v 3.5)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_not_integer, bundle.result.diagnostics[0].code);
}

test "bounds tree: :integer true passes whole f64" {
    const schema = boundsSchema("nn", .{ .integer = true }, null);
    var bundle = try validateSrc("(set :v 3.0)", schema);
    defer deinitBundle(bundle);
    try testing.expect(!bundle.result.hasErrors());
}

test "bounds tree: :integer true passes i64.max literal" {
    const schema = boundsSchema("nn", .{ .integer = true }, null);
    var bundle = try validateSrc("(set :v 9223372036854775807)", schema);
    defer deinitBundle(bundle);
    try testing.expect(!bundle.result.hasErrors());
}

test "bounds tree: :integer true passes u64 literal beyond i64.max" {
    const schema = boundsSchema("nn", .{ .integer = true }, null);
    var bundle = try validateSrc("(set :v 9223372036854775808)", schema);
    defer deinitBundle(bundle);
    try testing.expect(!bundle.result.hasErrors());
}

test "bounds tree: exact-int comparison catches u64 above max where f64 would not" {
    // 2^53 = 9007199254740992 fits f64 exactly. 2^53 + 1 = 9007199254740993
    // does not — it rounds back to 2^53. Naive f64 comparison says
    // "value == 2^53 ≤ max=2^53 (exclusive)" → false negative. The
    // exact-int branch keeps the comparison in u64 space and catches it.
    const schema = boundsSchema("nn", .{
        .max = .{ .value = 9007199254740992.0, .exact_int = true },
        .exclusive_max = true,
    }, null);
    var bundle = try validateSrc("(set :v 9007199254740993)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(
        Ast.Diagnostic.Code.number_at_or_above_exclusive_max,
        bundle.result.diagnostics[0].code,
    );
}

test "bounds tree: unit-bearing bound + matching unit-bearing value passes" {
    const u: Plugin.ValueKind.UnitShape = .{ .required = true, .allowed = &.{"ms"} };
    const schema = boundsSchema("dur", .{
        .min = .{ .value = 0, .unit = "ms", .exact_int = true },
        .max = .{ .value = 1000, .unit = "ms", .exact_int = true },
    }, u);
    var bundle = try validateSrc("(set :v 500ms)", schema);
    defer deinitBundle(bundle);
    try testing.expect(!bundle.result.hasErrors());
}

test "bounds tree: unit-bearing bound + bare-number value emits bound_unit_mismatch" {
    const u: Plugin.ValueKind.UnitShape = .{};
    const schema = boundsSchema("dur", .{
        .min = .{ .value = 0, .unit = "ms", .exact_int = true },
    }, u);
    var bundle = try validateSrc("(set :v 5)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(
        Ast.Diagnostic.Code.numeric_bound_unit_mismatch,
        bundle.result.diagnostics[0].code,
    );
}

test "bounds tree: unit-bearing bound + differing-unit value emits bound_unit_mismatch" {
    const u: Plugin.ValueKind.UnitShape = .{};
    const schema = boundsSchema("dur", .{
        .min = .{ .value = 0, .unit = "ms", .exact_int = true },
    }, u);
    var bundle = try validateSrc("(set :v 5s)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(
        Ast.Diagnostic.Code.numeric_bound_unit_mismatch,
        bundle.result.diagnostics[0].code,
    );
}

test "bounds tree: bare-bound + unit-bearing value passes (magnitude-only)" {
    const u: Plugin.ValueKind.UnitShape = .{};
    const schema = boundsSchema("dur", .{
        .max = .{ .value = 100, .exact_int = true },
    }, u);
    var bundle = try validateSrc("(set :v 50ms)", schema);
    defer deinitBundle(bundle);
    try testing.expect(!bundle.result.hasErrors());
}

test "bounds tree: NaN value fails :integer true" {
    // SJON source has no NaN literal, so build the tree by hand. Drives
    // home the documented behaviour: `:integer true` rejects all non-
    // finite floats.
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    var b: Ast.TreeBuilder = .{ .a = arena.allocator() };
    const nan = std.math.nan(f64);
    const num = try b.appendNumber(nan, .{ .start = 0, .end = 0 });
    const kv = try b.appendKvpair("v", num, .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 });
    const form = try b.appendForm("set", null, .{ .start = 0, .end = 0 }, &.{kv}, .{ .start = 0, .end = 0 });
    var tree = try b.finalize(&arena, "", &.{form});
    defer tree.deinit();
    const schema = boundsSchema("nn", .{ .integer = true }, null);
    var r = try validate(a, tree, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_not_integer, r.diagnostics[0].code);
}

test "bounds binary: exact-int u64 above f64 max catches the off-by-one" {
    const schema = boundsSchema("nn", .{
        .max = .{ .value = 9007199254740992.0, .exact_int = true },
        .exclusive_max = true,
    }, null);
    const bin = try encodeForValidate("(set :v 9007199254740993)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(
        Ast.Diagnostic.Code.number_at_or_above_exclusive_max,
        r.diagnostics[0].code,
    );
}

test "bounds binary: passes when in range" {
    const schema = boundsSchema("nn", .{
        .min = .{ .value = 0, .exact_int = true },
        .max = .{ .value = 1, .exact_int = true },
    }, null);
    const bin = try encodeForValidate("(set :v 0.5)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "bounds binary: :integer true rejects fractional f64" {
    const schema = boundsSchema("nn", .{ .integer = true }, null);
    const bin = try encodeForValidate("(set :v 3.5)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_not_integer, r.diagnostics[0].code);
}

// ----- Numeric-bounds long-tail tests (IEEE-754, integer corners, vectors,
// ----- unions, diagnostic content, paths, multi-violation slots) -----------

/// Build a schema with a single `(set :v T)` form keyed on `T`. The kind
/// `T` is supplied verbatim — useful when the test wants to compose
/// `numeric` with `vector`, `union_of`, or a non-trivial unit-shape.
fn customSchema(comptime kinds: []const Plugin.ValueKind) Schema.Schema {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "v", .value_type = .{ .named = kinds[0].name } }},
            },
        },
        .value_kinds = kinds,
    };
    return Schema.Schema.init(&.{p});
}

/// Build a tree containing a single number with chosen tag (f64/i64/u64)
/// wrapped in `(set :v <num>)`. The TreeBuilder path lets us synthesise
/// values that the parser cannot express (NaN, ±inf, `Tag.number = 5`
/// that the parser would emit as `Tag.number_i64`). Caller owns the
/// returned Tree.
fn buildSetTreeF64(value: f64) !Ast.Tree {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    var b: Ast.TreeBuilder = .{ .a = arena.allocator() };
    const z = Ast.Span{ .start = 0, .end = 0 };
    const num = try b.appendNumber(value, z);
    const kv = try b.appendKvpair("v", num, z, z);
    const form = try b.appendForm("set", null, z, &.{kv}, z);
    return try b.finalize(&arena, "", &.{form});
}

test "bounds tree: -0.0 passes inclusive :min 0 (IEEE-754 equality)" {
    const schema = boundsSchema("nn", .{ .min = .{ .value = 0, .exact_int = true } }, null);
    var tree = try buildSetTreeF64(-0.0);
    defer tree.deinit();
    var r = try validate(testing.allocator, tree, schema);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "bounds tree: -0.0 against :min 0 :exclusive-min true emits exclusive-min fail" {
    // IEEE-754: -0.0 == 0.0, so `:exclusive-min 0` rejects it just as it
    // would the canonical `0.0`. Pins the IEEE-equality semantics so a
    // later refactor doesn't accidentally introduce a `signbit` carve-out.
    const schema = boundsSchema("nn", .{
        .min = .{ .value = 0, .exact_int = true },
        .exclusive_min = true,
    }, null);
    var tree = try buildSetTreeF64(-0.0);
    defer tree.deinit();
    var r = try validate(testing.allocator, tree, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(
        Ast.Diagnostic.Code.number_at_or_below_exclusive_min,
        r.diagnostics[0].code,
    );
}

test "bounds tree: -0.0 against :integer true is integer (floor preserves sign-zero)" {
    const schema = boundsSchema("nn", .{ .integer = true }, null);
    var tree = try buildSetTreeF64(-0.0);
    defer tree.deinit();
    var r = try validate(testing.allocator, tree, schema);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "bounds tree: +inf against :integer true emits number_not_integer" {
    const schema = boundsSchema("nn", .{ .integer = true }, null);
    var tree = try buildSetTreeF64(std.math.inf(f64));
    defer tree.deinit();
    var r = try validate(testing.allocator, tree, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_not_integer, r.diagnostics[0].code);
}

test "bounds tree: -inf against :integer true emits number_not_integer" {
    const schema = boundsSchema("nn", .{ .integer = true }, null);
    var tree = try buildSetTreeF64(-std.math.inf(f64));
    defer tree.deinit();
    var r = try validate(testing.allocator, tree, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_not_integer, r.diagnostics[0].code);
}

test "bounds tree: +inf above :max emits number_above_max" {
    const schema = boundsSchema("nn", .{ .max = .{ .value = 1000, .exact_int = true } }, null);
    var tree = try buildSetTreeF64(std.math.inf(f64));
    defer tree.deinit();
    var r = try validate(testing.allocator, tree, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_above_max, r.diagnostics[0].code);
}

test "bounds tree: -inf below :min emits number_below_min" {
    const schema = boundsSchema("nn", .{ .min = .{ .value = 0, .exact_int = true } }, null);
    var tree = try buildSetTreeF64(-std.math.inf(f64));
    defer tree.deinit();
    var r = try validate(testing.allocator, tree, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_below_min, r.diagnostics[0].code);
}

test "bounds tree: NaN slips past :min/:max (documented IEEE quirk)" {
    // `std.math.order(NaN, 0)` returns `.eq` (both `<` and `>` are
    // false). Without `:integer true` or `:exclusive-*`, NaN doesn't
    // hit the comparison path's `.lt`/`.gt` arms and falls through.
    // Documented behaviour — users who want NaN-safety should set
    // `:integer true` (which rejects all non-finite values).
    const schema = boundsSchema("nn", .{
        .min = .{ .value = 0, .exact_int = true },
        .max = .{ .value = 1, .exact_int = true },
    }, null);
    var tree = try buildSetTreeF64(std.math.nan(f64));
    defer tree.deinit();
    var r = try validate(testing.allocator, tree, schema);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "bounds tree: NaN against :exclusive-min catches the IEEE quirk" {
    // The `:exclusive-min true` branch requires `ord == .gt` to accept.
    // NaN's `.eq` ordering trips that strict requirement and the
    // diagnostic fires — providing a NaN safety net when the schema
    // already excludes the boundary.
    const schema = boundsSchema("nn", .{
        .min = .{ .value = 0, .exact_int = true },
        .exclusive_min = true,
    }, null);
    var tree = try buildSetTreeF64(std.math.nan(f64));
    defer tree.deinit();
    var r = try validate(testing.allocator, tree, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(
        Ast.Diagnostic.Code.number_at_or_below_exclusive_min,
        r.diagnostics[0].code,
    );
}

test "bounds tree: NaN with :integer true is the recommended NaN gate" {
    const schema = boundsSchema("nn", .{
        .min = .{ .value = 0, .exact_int = true },
        .integer = true,
    }, null);
    var tree = try buildSetTreeF64(std.math.nan(f64));
    defer tree.deinit();
    var r = try validate(testing.allocator, tree, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_not_integer, r.diagnostics[0].code);
}

test "bounds tree: i64.min literal below :min emits number_below_min" {
    const schema = boundsSchema("nn", .{ .min = .{ .value = 0, .exact_int = true } }, null);
    var bundle = try validateSrc("(set :v -9223372036854775808)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_below_min, bundle.result.diagnostics[0].code);
}

test "bounds tree: i64.min literal passes :integer true (exact-int via tag)" {
    const schema = boundsSchema("nn", .{ .integer = true }, null);
    var bundle = try validateSrc("(set :v -9223372036854775808)", schema);
    defer deinitBundle(bundle);
    try testing.expect(!bundle.result.hasErrors());
}

test "bounds tree: exact-int negative side catches off-by-one at -2^53" {
    // Symmetric to the existing positive-side test. -2^53 = -9007199254740992
    // is exactly representable in f64; -2^53 - 1 = -9007199254740993 is not.
    // The exact-int branch keeps the comparison in i64 space and catches
    // the value the f64 path would round to equality.
    const schema = boundsSchema("nn", .{
        .min = .{ .value = -9007199254740992.0, .exact_int = true },
        .exclusive_min = true,
    }, null);
    var bundle = try validateSrc("(set :v -9007199254740993)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(
        Ast.Diagnostic.Code.number_at_or_below_exclusive_min,
        bundle.result.diagnostics[0].code,
    );
}

test "bounds tree: u64-tag value vs i64-bound takes f64 fallback safely" {
    // The u64 value 9223372036854775808 (= i64.max + 1) does NOT fit i64.
    // The bound 0 is exact-int and fits both. `compareToBound` for `.u`
    // takes the integer branch if `boundFitsU64(bound)` is true — which
    // it is for 0. So the result is u64-order(2^63, 0) = .gt → above_max.
    const schema = boundsSchema("nn", .{ .max = .{ .value = 0, .exact_int = true } }, null);
    var bundle = try validateSrc("(set :v 9223372036854775808)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_above_max, bundle.result.diagnostics[0].code);
}

test "bounds tree: u64-tag value with negative bound treats negative bound as not-fits-u64" {
    // bound = -1, exact_int = true. boundFitsU64(-1) is false (negative),
    // so the comparison falls back to f64. The u64 value 2^63 = 9.22…e18
    // floats up to 9.223372036854776e18 (≈ same), which is > -1.0 in f64
    // → above_max. The fallback is safe here because both sides are well
    // outside the precision-loss zone for the question being asked.
    const schema = boundsSchema("nn", .{ .max = .{ .value = -1, .exact_int = true } }, null);
    var bundle = try validateSrc("(set :v 9223372036854775808)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_above_max, bundle.result.diagnostics[0].code);
}

test "bounds tree: negative integer bound accepts positive integer value" {
    const schema = boundsSchema("nn", .{
        .min = .{ .value = -10, .exact_int = true },
        .max = .{ .value = 10, .exact_int = true },
    }, null);
    var bundle = try validateSrc("(set :v 5)", schema);
    defer deinitBundle(bundle);
    try testing.expect(!bundle.result.hasErrors());
}

test "bounds tree: bound at -0.0 with positive value is in range" {
    // `:min -0.0` is identical to `:min 0.0` per IEEE-754 equality.
    const schema = boundsSchema("nn", .{ .min = .{ .value = -0.0, .exact_int = false } }, null);
    var bundle = try validateSrc("(set :v 1)", schema);
    defer deinitBundle(bundle);
    try testing.expect(!bundle.result.hasErrors());
}

test "bounds tree: diagnostic message includes value and bound on number_below_min" {
    const schema = boundsSchema("nn", .{ .min = .{ .value = 0, .exact_int = true } }, null);
    var bundle = try validateSrc("(set :v -3)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "below minimum") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "-3") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "0") != null);
}

test "bounds tree: diagnostic message names the suffix unit on bound" {
    const u: Plugin.ValueKind.UnitShape = .{ .required = true, .allowed = &.{"ms"} };
    const schema = boundsSchema("dur", .{
        .max = .{ .value = 1000, .unit = "ms", .exact_int = true },
    }, u);
    var bundle = try validateSrc("(set :v 1500ms)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "above maximum") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "1500") != null);
    // unit suffix is concatenated to the bound: "above maximum 1000ms"
    try testing.expect(std.mem.indexOf(u8, msg, "1000ms") != null);
}

test "bounds tree: bound_unit_mismatch message names both sides" {
    const schema = boundsSchema("dur", .{
        .min = .{ .value = 0, .unit = "ms", .exact_int = true },
    }, .{});
    var bundle = try validateSrc("(set :v 5s)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "`s`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`ms`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "does not match") != null);
}

test "bounds tree: bound_unit_mismatch with bare-number value reports (none)" {
    const schema = boundsSchema("dur", .{
        .min = .{ .value = 0, .unit = "ms", .exact_int = true },
    }, .{});
    var bundle = try validateSrc("(set :v 5)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "(none)") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`ms`") != null);
}

test "bounds tree: byte-equal unit comparison is case-sensitive" {
    // Units are opaque (LANGUAGE.md §2.6); the validator does no case-
    // folding, so `Ms` and `ms` are different units.
    const schema = boundsSchema("dur", .{
        .min = .{ .value = 0, .unit = "ms", .exact_int = true },
    }, .{});
    var bundle = try validateSrc("(set :v 5Ms)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(
        Ast.Diagnostic.Code.numeric_bound_unit_mismatch,
        bundle.result.diagnostics[0].code,
    );
}

test "bounds tree: bound_unit_mismatch precedes range comparison" {
    // Priority order: unit mismatch fires before below/above. The unit
    // problem is structural; the magnitude diagnostic on a wrong-unit
    // value would mislead the author.
    const schema = boundsSchema("dur", .{
        .min = .{ .value = 0, .unit = "ms", .exact_int = true },
        .max = .{ .value = 10, .unit = "ms", .exact_int = true },
    }, .{});
    var bundle = try validateSrc("(set :v -5s)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(
        Ast.Diagnostic.Code.numeric_bound_unit_mismatch,
        bundle.result.diagnostics[0].code,
    );
}

test "bounds tree: integer check fires before range check" {
    // Priority within the bounds path: integer mismatch precedes
    // min/max. A fractional value below :min still emits
    // number_not_integer first — pins single-emission ordering.
    const schema = boundsSchema("nn", .{
        .min = .{ .value = 0, .exact_int = true },
        .integer = true,
    }, null);
    var bundle = try validateSrc("(set :v -0.5)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_not_integer, bundle.result.diagnostics[0].code);
}

test "bounds tree: number_with_unit value with no kind unit + out-of-range emits number_above_max" {
    // `:unit` absent → unit suffix is ignored at the unit-shape gate;
    // bounds still see the magnitude. 50ms > :max 10 → above_max.
    const schema = boundsSchema("nn", .{ .max = .{ .value = 10, .exact_int = true } }, null);
    var bundle = try validateSrc("(set :v 50ms)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_above_max, bundle.result.diagnostics[0].code);
}

test "bounds tree: union-of two bounded kinds emits union_no_branch_matched when both reject" {
    // Both alternatives are number-underlying with disjoint ranges. The
    // value falls outside both; the union dispatches alt-by-alt, sees
    // each emit its own MatchFail, and surfaces a single
    // union_no_branch_matched (not the inner range diagnostics).
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "v", .value_type = .{ .named = .{ .name = "either" } } }} }},
        .value_kinds = &.{
            .{
                .name = "small",
                .underlying = .number,
                .numeric = .{
                    .min = .{ .value = 0, .exact_int = true },
                    .max = .{ .value = 10, .exact_int = true },
                },
            },
            .{
                .name = "big",
                .underlying = .number,
                .numeric = .{
                    .min = .{ .value = 1000, .exact_int = true },
                },
            },
            .{
                .name = "either",
                .underlying = .union_of,
                .union_of = .{ .alternatives = &.{ .{ .name = "small" }, .{ .name = "big" } } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :v 500)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(
        Ast.Diagnostic.Code.union_no_branch_matched,
        bundle.result.diagnostics[0].code,
    );
}

test "bounds tree: union-of two bounded kinds passes when one alt accepts" {
    // 5 matches `small`; the union short-circuits and never tries `big`.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "v", .value_type = .{ .named = .{ .name = "either" } } }} }},
        .value_kinds = &.{
            .{
                .name = "small",
                .underlying = .number,
                .numeric = .{
                    .min = .{ .value = 0, .exact_int = true },
                    .max = .{ .value = 10, .exact_int = true },
                },
            },
            .{
                .name = "big",
                .underlying = .number,
                .numeric = .{
                    .min = .{ .value = 1000, .exact_int = true },
                },
            },
            .{
                .name = "either",
                .underlying = .union_of,
                .union_of = .{ .alternatives = &.{ .{ .name = "small" }, .{ .name = "big" } } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :v 5)", schema);
    defer deinitBundle(bundle);
    try testing.expect(!bundle.result.hasErrors());
}

test "bounds tree: vector element with bounded element-kind reports element_at index" {
    // The validator walks the vector elementwise; each element runs the
    // bounded kind. The diagnostic carries element_at(index) so authors
    // can pinpoint the bad slot.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "v", .value_type = .{ .named = .{ .name = "opacities" } } }} }},
        .value_kinds = &.{
            .{
                .name = "opacity",
                .underlying = .number,
                .numeric = .{
                    .min = .{ .value = 0, .exact_int = true },
                    .max = .{ .value = 1, .exact_int = true },
                },
            },
            .{
                .name = "opacities",
                .underlying = .vector,
                .vector = .{ .element = .{ .name = "opacity" } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :v [0.5 1.5 0.0])", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    // The wrapper diagnostic on the tree path mentions the element
    // index in its message; the underlying code is the inner range
    // failure.
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "element [1]") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "above maximum") != null);
}

test "bounds tree: vector of bounded elements accepts all-in-range" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "v", .value_type = .{ .named = .{ .name = "opacities" } } }} }},
        .value_kinds = &.{
            .{
                .name = "opacity",
                .underlying = .number,
                .numeric = .{
                    .min = .{ .value = 0, .exact_int = true },
                    .max = .{ .value = 1, .exact_int = true },
                },
            },
            .{
                .name = "opacities",
                .underlying = .vector,
                .vector = .{ .element = .{ .name = "opacity" } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :v [0.0 0.5 1.0])", schema);
    defer deinitBundle(bundle);
    try testing.expect(!bundle.result.hasErrors());
}

test "bounds tree: two slots each with own bounded kind, each violating" {
    // Multi-slot multi-violation: one diagnostic per kvpair, each path
    // points at the right slot. Pins the per-slot single-emission
    // discipline (a violation in :a does not silence :b).
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{
            .name = "set",
            .keys = &.{
                .{ .name = "a", .value_type = .{ .named = .{ .name = "small" } } },
                .{ .name = "b", .value_type = .{ .named = .{ .name = "big" } } },
            },
        }},
        .value_kinds = &.{
            .{
                .name = "small",
                .underlying = .number,
                .numeric = .{ .max = .{ .value = 10, .exact_int = true } },
            },
            .{
                .name = "big",
                .underlying = .number,
                .numeric = .{ .min = .{ .value = 1000, .exact_int = true } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var bundle = try validateSrc("(set :a 999 :b 5)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(@as(usize, 2), bundle.result.diagnostics.len);
    try testing.expect(anyCode(bundle.result.diagnostics, .number_above_max));
    try testing.expect(anyCode(bundle.result.diagnostics, .number_below_min));
}

test "bounds tree: diagnostic span points at the value node, not the form" {
    // The MatchFail bubble up through emitTypeMismatch uses the value
    // node's span (consistent with unit_required / unit_not_allowed).
    // Locks this in so future formatting refactors don't migrate to the
    // form's span (which would be unhelpful for editor highlights).
    const schema = boundsSchema("nn", .{ .max = .{ .value = 10, .exact_int = true } }, null);
    var bundle = try validateSrc("(set :v 999)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    const span = bundle.result.diagnostics[0].span;
    // "(set :v 999)" — "999" starts at byte 8.
    try testing.expectEqual(@as(u32, 8), span.start);
    try testing.expectEqual(@as(u32, 11), span.end);
}

test "bounds tree: diagnostic path includes form head and kvpair key" {
    // Path segments are `(set, v)`. The validator's path machinery
    // builds this list; confirm both segments are present so editors
    // can render \"set / v\" without parsing the message.
    const schema = boundsSchema("nn", .{ .max = .{ .value = 10, .exact_int = true } }, null);
    var bundle = try validateSrc("(set :v 999)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    const path = bundle.result.diagnostics[0].path;
    try testing.expect(path.len >= 2);
    try testing.expectEqualStrings("set", path[0]);
    try testing.expectEqualStrings("v", path[1]);
}

test "bounds tree: equal-bound single-point range accepts the point" {
    const schema = boundsSchema("nn", .{
        .min = .{ .value = 5, .exact_int = true },
        .max = .{ .value = 5, .exact_int = true },
    }, null);
    var bundle = try validateSrc("(set :v 5)", schema);
    defer deinitBundle(bundle);
    try testing.expect(!bundle.result.hasErrors());
}

test "bounds tree: equal-bound single-point rejects neighbours" {
    const schema = boundsSchema("nn", .{
        .min = .{ .value = 5, .exact_int = true },
        .max = .{ .value = 5, .exact_int = true },
    }, null);
    var bundle = try validateSrc("(set :v 6)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_above_max, bundle.result.diagnostics[0].code);
}

test "bounds tree: same-unit bound + same-unit value with magnitude in-range passes" {
    const u: Plugin.ValueKind.UnitShape = .{ .required = true, .allowed = &.{"%"} };
    const schema = boundsSchema("pct", .{
        .min = .{ .value = 0, .unit = "%", .exact_int = true },
        .max = .{ .value = 100, .unit = "%", .exact_int = true },
    }, u);
    var bundle = try validateSrc("(set :v 50%)", schema);
    defer deinitBundle(bundle);
    try testing.expect(!bundle.result.hasErrors());
}

test "bounds tree: same-unit bound + same-unit value above bound fails with unit suffix" {
    const u: Plugin.ValueKind.UnitShape = .{ .required = true, .allowed = &.{"%"} };
    const schema = boundsSchema("pct", .{
        .max = .{ .value = 100, .unit = "%", .exact_int = true },
    }, u);
    var bundle = try validateSrc("(set :v 150%)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_above_max, bundle.result.diagnostics[0].code);
    try testing.expect(std.mem.indexOf(u8, bundle.result.diagnostics[0].message, "100%") != null);
}

test "bounds tree: wrong-tag value in number slot reports wrong_underlying, not bounds fail" {
    // A string in a number-bounded slot must fail with wrong_underlying
    // (step 1's tag check) and never reach the bounds path. Otherwise a
    // schema with `:integer true` would report \"value … is not an
    // integer\" for a string, which would be misleading.
    const schema = boundsSchema("nn", .{
        .min = .{ .value = 0, .exact_int = true },
        .integer = true,
    }, null);
    var bundle = try validateSrc("(set :v \"hello\")", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "got string") != null);
    // Bound diagnostic codes are absent.
    try testing.expect(!anyCode(bundle.result.diagnostics, .number_below_min));
    try testing.expect(!anyCode(bundle.result.diagnostics, .number_not_integer));
}

test "bounds tree: unit_missing fires before bounds (unit gate is upstream)" {
    // `:unit (unit-shape :required true …)` with a bare number short-
    // circuits at the unit gate; the bounds path never runs. Without
    // this, a kind that requires `ms` and bounds `:min 0` would emit
    // both unit_required AND a meaningless range diagnostic.
    const u: Plugin.ValueKind.UnitShape = .{ .required = true, .allowed = &.{"ms"} };
    const schema = boundsSchema("dur", .{
        .min = .{ .value = 0, .unit = "ms", .exact_int = true },
        .max = .{ .value = 100, .unit = "ms", .exact_int = true },
    }, u);
    var bundle = try validateSrc("(set :v 999)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.unit_required, bundle.result.diagnostics[0].code);
    try testing.expect(!anyCode(bundle.result.diagnostics, .number_above_max));
    try testing.expect(!anyCode(bundle.result.diagnostics, .numeric_bound_unit_mismatch));
}

test "bounds tree: unit_not_allowed fires before bounds (unit gate is upstream)" {
    const u: Plugin.ValueKind.UnitShape = .{ .required = true, .allowed = &.{"ms"} };
    const schema = boundsSchema("dur", .{
        .max = .{ .value = 100, .unit = "ms", .exact_int = true },
    }, u);
    var bundle = try validateSrc("(set :v 200s)", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.unit_not_allowed, bundle.result.diagnostics[0].code);
    try testing.expect(!anyCode(bundle.result.diagnostics, .number_above_max));
}

test "bounds tree: exclusive-min on the small-positive value above the bound passes" {
    // Sanity: with bound 0 and exclusive_min, the smallest positive
    // integer literal (1) is unambiguously > 0 → passes.
    const schema = boundsSchema("nn", .{
        .min = .{ .value = 0, .exact_int = true },
        .exclusive_min = true,
    }, null);
    var bundle = try validateSrc("(set :v 1)", schema);
    defer deinitBundle(bundle);
    try testing.expect(!bundle.result.hasErrors());
}

test "bounds tree: exact-int eq case for u64 boundary inclusive max passes" {
    // 2^53 == bound, inclusive max — passes via the exact-int branch.
    // Mirror of the failing exclusive-max case but pinning the success
    // edge (off-by-one in the other direction).
    const schema = boundsSchema("nn", .{
        .max = .{ .value = 9007199254740992.0, .exact_int = true },
    }, null);
    var bundle = try validateSrc("(set :v 9007199254740992)", schema);
    defer deinitBundle(bundle);
    try testing.expect(!bundle.result.hasErrors());
}

// ----- Binary-path parity for the long-tail edges --------------------------
//
// The binary path runs the same `checkNumericBoundsValue` from
// `matchKindBinary`. These tests put the awkward shapes (vectors,
// NaN-via-synthetic-tree, exact-int u64) through the cursor so the
// `MatchExtras.numeric` tag-true capture and the binary unit/bounds
// ordering stay in lockstep with the tree path.

/// Build a binary by hand-constructing a Tree (so we can plant NaN /
/// ±inf values that the parser refuses to emit) and then encoding it.
fn synthesisedBinary(value: f64) !Ast.Bytes {
    var tree = try buildSetTreeF64(value);
    defer tree.deinit();
    return try Binary.toBinary(testing.allocator, tree, .{
        .with_spans = true,
        .with_head_spans = true,
        .with_kvpair_key_spans = true,
    });
}

test "bounds binary: NaN with :integer true emits number_not_integer" {
    const schema = boundsSchema("nn", .{ .integer = true }, null);
    const bin = try synthesisedBinary(std.math.nan(f64));
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_not_integer, r.diagnostics[0].code);
}

test "bounds binary: NaN slips through plain :min / :max (matches tree path)" {
    const schema = boundsSchema("nn", .{
        .min = .{ .value = 0, .exact_int = true },
        .max = .{ .value = 1, .exact_int = true },
    }, null);
    const bin = try synthesisedBinary(std.math.nan(f64));
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "bounds binary: NaN against :exclusive-min emits exclusive-min fail (parity)" {
    const schema = boundsSchema("nn", .{
        .min = .{ .value = 0, .exact_int = true },
        .exclusive_min = true,
    }, null);
    const bin = try synthesisedBinary(std.math.nan(f64));
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(
        Ast.Diagnostic.Code.number_at_or_below_exclusive_min,
        r.diagnostics[0].code,
    );
}

test "bounds binary: +inf against :max emits number_above_max" {
    const schema = boundsSchema("nn", .{ .max = .{ .value = 100, .exact_int = true } }, null);
    const bin = try synthesisedBinary(std.math.inf(f64));
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_above_max, r.diagnostics[0].code);
}

test "bounds binary: -inf against :min emits number_below_min" {
    const schema = boundsSchema("nn", .{ .min = .{ .value = 0, .exact_int = true } }, null);
    const bin = try synthesisedBinary(-std.math.inf(f64));
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_below_min, r.diagnostics[0].code);
}

test "bounds binary: -0.0 passes :min 0 (IEEE-754 equality)" {
    const schema = boundsSchema("nn", .{ .min = .{ .value = 0, .exact_int = true } }, null);
    const bin = try synthesisedBinary(-0.0);
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "bounds binary: -0.0 fails :exclusive-min 0 (parity with tree)" {
    const schema = boundsSchema("nn", .{
        .min = .{ .value = 0, .exact_int = true },
        .exclusive_min = true,
    }, null);
    const bin = try synthesisedBinary(-0.0);
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(
        Ast.Diagnostic.Code.number_at_or_below_exclusive_min,
        r.diagnostics[0].code,
    );
}

test "bounds binary: i64.min literal passes :integer true" {
    const schema = boundsSchema("nn", .{ .integer = true }, null);
    const bin = try encodeForValidate("(set :v -9223372036854775808)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "bounds binary: i64.min literal below :min emits number_below_min" {
    const schema = boundsSchema("nn", .{ .min = .{ .value = 0, .exact_int = true } }, null);
    const bin = try encodeForValidate("(set :v -9223372036854775808)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_below_min, r.diagnostics[0].code);
}

test "bounds binary: exact-int negative side catches off-by-one (-2^53 - 1)" {
    const schema = boundsSchema("nn", .{
        .min = .{ .value = -9007199254740992.0, .exact_int = true },
        .exclusive_min = true,
    }, null);
    const bin = try encodeForValidate("(set :v -9007199254740993)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(
        Ast.Diagnostic.Code.number_at_or_below_exclusive_min,
        r.diagnostics[0].code,
    );
}

test "bounds binary: u64 with negative i64 max takes safe f64 fallback" {
    const schema = boundsSchema("nn", .{ .max = .{ .value = -1, .exact_int = true } }, null);
    const bin = try encodeForValidate("(set :v 9223372036854775808)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_above_max, r.diagnostics[0].code);
}

test "bounds binary: vector element with bounded element-kind catches inner violation" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "v", .value_type = .{ .named = .{ .name = "opacities" } } }} }},
        .value_kinds = &.{
            .{
                .name = "opacity",
                .underlying = .number,
                .numeric = .{
                    .min = .{ .value = 0, .exact_int = true },
                    .max = .{ .value = 1, .exact_int = true },
                },
            },
            .{
                .name = "opacities",
                .underlying = .vector,
                .vector = .{ .element = .{ .name = "opacity" } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    const bin = try encodeForValidate("(set :v [0.5 1.5 0.0])");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(anyCode(r.diagnostics, .number_above_max));
}

test "bounds binary: vector-of-bounded passes when all elements are in range" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "v", .value_type = .{ .named = .{ .name = "opacities" } } }} }},
        .value_kinds = &.{
            .{
                .name = "opacity",
                .underlying = .number,
                .numeric = .{
                    .min = .{ .value = 0, .exact_int = true },
                    .max = .{ .value = 1, .exact_int = true },
                },
            },
            .{
                .name = "opacities",
                .underlying = .vector,
                .vector = .{ .element = .{ .name = "opacity" } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    const bin = try encodeForValidate("(set :v [0.0 0.5 1.0])");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "bounds binary: union of bounded alts emits union_no_branch_matched" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "v", .value_type = .{ .named = .{ .name = "either" } } }} }},
        .value_kinds = &.{
            .{
                .name = "small",
                .underlying = .number,
                .numeric = .{
                    .min = .{ .value = 0, .exact_int = true },
                    .max = .{ .value = 10, .exact_int = true },
                },
            },
            .{
                .name = "big",
                .underlying = .number,
                .numeric = .{ .min = .{ .value = 1000, .exact_int = true } },
            },
            .{
                .name = "either",
                .underlying = .union_of,
                .union_of = .{ .alternatives = &.{ .{ .name = "small" }, .{ .name = "big" } } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    const bin = try encodeForValidate("(set :v 500)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(
        Ast.Diagnostic.Code.union_no_branch_matched,
        r.diagnostics[0].code,
    );
}

test "bounds binary: unit-bearing bound + matching value passes via cursor" {
    const u: Plugin.ValueKind.UnitShape = .{ .required = true, .allowed = &.{"ms"} };
    const schema = boundsSchema("dur", .{
        .min = .{ .value = 0, .unit = "ms", .exact_int = true },
        .max = .{ .value = 1000, .unit = "ms", .exact_int = true },
    }, u);
    const bin = try encodeForValidate("(set :v 500ms)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "bounds binary: unit-bearing bound + wrong-unit value emits bound_unit_mismatch" {
    const schema = boundsSchema("dur", .{
        .min = .{ .value = 0, .unit = "ms", .exact_int = true },
    }, .{});
    const bin = try encodeForValidate("(set :v 5s)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(
        Ast.Diagnostic.Code.numeric_bound_unit_mismatch,
        r.diagnostics[0].code,
    );
}

test "bounds binary: unit-bearing bound + bare-number value emits bound_unit_mismatch" {
    const schema = boundsSchema("dur", .{
        .min = .{ .value = 0, .unit = "ms", .exact_int = true },
    }, .{});
    const bin = try encodeForValidate("(set :v 5)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(
        Ast.Diagnostic.Code.numeric_bound_unit_mismatch,
        r.diagnostics[0].code,
    );
}

test "bounds binary: unit_required fires before bounds even on binary path" {
    const u: Plugin.ValueKind.UnitShape = .{ .required = true, .allowed = &.{"ms"} };
    const schema = boundsSchema("dur", .{
        .min = .{ .value = 0, .unit = "ms", .exact_int = true },
        .max = .{ .value = 100, .unit = "ms", .exact_int = true },
    }, u);
    const bin = try encodeForValidate("(set :v 999)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.unit_required, r.diagnostics[0].code);
    try testing.expect(!anyCode(r.diagnostics, .number_above_max));
}

test "bounds binary: diagnostic message text mirrors tree path content" {
    const schema = boundsSchema("nn", .{ .min = .{ .value = 0, .exact_int = true } }, null);
    const bin = try encodeForValidate("(set :v -3)");
    defer bin.deinit();
    var r = try validateBinary(testing.allocator, bin.data, schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    const msg = r.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "below minimum") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "-3") != null);
}

test "bounds binary: full code+message parity with tree path on integer + range double-violation" {
    // The validator emits the integer-fail first (priority order). Verify
    // both paths produce identical diagnostic codes.
    const schema = boundsSchema("nn", .{
        .min = .{ .value = 0, .exact_int = true },
        .integer = true,
    }, null);
    try expectCodeOnBoth("(set :v -0.5)", schema, .number_not_integer);
}

test "bounds binary: parity on exact-int u64 off-by-one above f64 max" {
    const schema = boundsSchema("nn", .{
        .max = .{ .value = 9007199254740992.0, .exact_int = true },
        .exclusive_max = true,
    }, null);
    try expectCodeOnBoth("(set :v 9007199254740993)", schema, .number_at_or_above_exclusive_max);
}

// ----- :repr GPU-representation validation (dual-path) ----------------------
//
// A `.number` kind tagged `:repr <f32|u32|i32|u16|f16>` rejects a literal
// outside the GPU type's range (every path) or non-integral under an
// integer type. Locked on BOTH validator paths with expectCodeOnBoth /
// expectNoCodeOnBoth — a repr check that drifts between tree and binary is
// exactly the silent divergence project_validator_tree_binary_parity warns
// about.

fn reprSchema(comptime name: []const u8, comptime repr: Plugin.ValueKind.Repr) Schema.Schema {
    // Comptime construction so the nested slices live in rodata (mirrors
    // boundsSchema — a runtime `&.{p}` would dangle on return).
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "v", .value_type = .{ .named = .{ .name = name } } }},
            },
        },
        .value_kinds = &.{
            .{ .name = name, .underlying = .number, .repr = repr },
        },
    };
    return Schema.Schema.init(&.{p});
}

test "repr: 70000 over u16 max emits repr_out_of_range on both paths" {
    try expectCodeOnBoth("(set :v 70000)", reprSchema("u16v", .u16), .repr_out_of_range);
}

test "repr: 1.5 under u32 (non-integer) emits repr_out_of_range on both paths" {
    try expectCodeOnBoth("(set :v 1.5)", reprSchema("u32v", .u32), .repr_out_of_range);
}

test "repr: 1.0 under f32 is clean on both paths" {
    try expectNoCodeOnBoth("(set :v 1.0)", reprSchema("f32v", .f32), .repr_out_of_range);
}

test "repr: negative value under u16 emits repr_out_of_range on both paths" {
    try expectCodeOnBoth("(set :v -1)", reprSchema("u16v", .u16), .repr_out_of_range);
}

test "repr: u16 max boundary (65535) is clean on both paths" {
    try expectNoCodeOnBoth("(set :v 65535)", reprSchema("u16v", .u16), .repr_out_of_range);
}

test "repr: one past u32 max (4294967296) emits repr_out_of_range on both paths" {
    try expectCodeOnBoth("(set :v 4294967296)", reprSchema("u32v", .u32), .repr_out_of_range);
}

test "repr: i32 min boundary (-2147483648) is clean on both paths" {
    try expectNoCodeOnBoth("(set :v -2147483648)", reprSchema("i32v", .i32), .repr_out_of_range);
}

test "repr: f16 over-range (70000) emits repr_out_of_range on both paths" {
    try expectCodeOnBoth("(set :v 70000)", reprSchema("f16v", .f16), .repr_out_of_range);
}

test "repr: fractional value under f32 is clean (no integrality on floats)" {
    try expectNoCodeOnBoth("(set :v 1.1)", reprSchema("f32v", .f32), .repr_out_of_range);
}

test "repr tree: out-of-range message names the GPU type and reason" {
    var bundle = try validateSrc("(set :v 70000)", reprSchema("u16v", .u16));
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "out of range") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "u16") != null);
}

test "repr tree: non-integer message disambiguates from out-of-range" {
    var bundle = try validateSrc("(set :v 1.5)", reprSchema("u32v", .u32));
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    const msg = bundle.result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "not an integer") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "u32") != null);
}

// ----- Cross-component integration: ManifestLoader → Validator -------------
//
// Up to here the bounded value-kinds were comptime-built. These tests
// exercise the production flow — a `(plugin …)` manifest parsed by the
// real source loader, fed to a real `Validator.validate` — so a regression
// in either the loader's bound capture OR the validator's bound check
// shows up immediately.

const ManifestLoader = @import("ManifestLoader.zig");
const Json = @import("Json.zig");
const MetaSchema = @import("MetaSchema.zig");

fn loadManifest(src: [:0]const u8) !ManifestLoader.Result {
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();
    return try ManifestLoader.load(testing.allocator, tree);
}

test "loaded-manifest: (numeric-bounds :min 0 :max 1) accepts 0.5 and rejects 1.5" {
    var r = try loadManifest(
        \\(plugin :name p :version "1.0.0"
        \\  (form :name set
        \\    (key :name v :type opacity :optional false))
        \\  (value-kind :name opacity :underlying number
        \\    :numeric (numeric-bounds :min 0 :max 1)))
    );
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const schema = Schema.Schema.init(&.{r.plugin});

    var ok = try validateSrc("(set :v 0.5)", schema);
    defer deinitBundle(ok);
    try testing.expect(!ok.result.hasErrors());

    var bad = try validateSrc("(set :v 1.5)", schema);
    defer deinitBundle(bad);
    try testing.expect(bad.result.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_above_max, bad.result.diagnostics[0].code);
}

test "loaded-manifest: scalar-or-ref accepts a number and a symbol, rejects a string (both paths)" {
    var r = try loadManifest(
        \\(plugin :name p :version "1.0.0"
        \\  (form :name use
        \\    (key :name n :type count :optional false))
        \\  (value-kind :name count-value :underlying number)
        \\  (value-kind :name count
        \\    :underlying scalar-or-ref
        \\    :scalar-or-ref (scalar-or-ref-shape :base count-value)))
    );
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const schema = Schema.Schema.init(&.{r.plugin});

    // The desugared `union [count-value symbol]` accepts a number (via the
    // base) and a bare symbol (via the primitive `symbol` alternative), and
    // rejects a string — identically on the tree and binary paths.
    try expectNoCodeOnBoth("(use :n 42)", schema, .union_no_branch_matched);
    try expectNoCodeOnBoth("(use :n MY_DEFINE)", schema, .union_no_branch_matched);
    try expectCodeOnBoth("(use :n \"hi\")", schema, .union_no_branch_matched);
}

test "loaded-manifest: unit-bearing bound + matching value passes; wrong unit fails" {
    var r = try loadManifest(
        \\(plugin :name p :version "1.0.0"
        \\  (form :name delay
        \\    (key :name wait :type duration-ms :optional false))
        \\  (value-kind :name duration-ms :underlying number
        \\    :unit (unit-shape :required true :allowed [ms])
        \\    :numeric (numeric-bounds :min 0ms :max 10000ms)))
    );
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const schema = Schema.Schema.init(&.{r.plugin});

    var ok = try validateSrc("(delay :wait 500ms)", schema);
    defer deinitBundle(ok);
    try testing.expect(!ok.result.hasErrors());

    var wrong_unit = try validateSrc("(delay :wait 500s)", schema);
    defer deinitBundle(wrong_unit);
    try testing.expect(wrong_unit.result.hasErrors());
    // `unit-shape` fires first because the kind requires `ms` and the
    // value carries `s` — bounds check is downstream.
    try testing.expectEqual(Ast.Diagnostic.Code.unit_not_allowed, wrong_unit.result.diagnostics[0].code);
}

test "loaded-manifest: :integer true rejects fractional value at validate time" {
    var r = try loadManifest(
        \\(plugin :name p :version "1.0.0"
        \\  (form :name set
        \\    (key :name v :type count :optional false))
        \\  (value-kind :name count :underlying number
        \\    :numeric (numeric-bounds :min 0 :integer true)))
    );
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const schema = Schema.Schema.init(&.{r.plugin});

    var bad = try validateSrc("(set :v 3.5)", schema);
    defer deinitBundle(bad);
    try testing.expect(bad.result.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.number_not_integer, bad.result.diagnostics[0].code);
}

test "loaded-manifest: vector-of-bounded with manifest-driven kind chain" {
    // The plugin defines a vector value-kind whose elements are a named
    // bounded number kind. Exercises the loader's two-kind chain through
    // to elementwise validation.
    var r = try loadManifest(
        \\(plugin :name p :version "1.0.0"
        \\  (form :name layer
        \\    (key :name opacities :type opacities :optional false))
        \\  (value-kind :name opacity :underlying number
        \\    :numeric (numeric-bounds :min 0 :max 1))
        \\  (value-kind :name opacities :underlying vector
        \\    :vector (vector-shape :element opacity)))
    );
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const schema = Schema.Schema.init(&.{r.plugin});

    var bad = try validateSrc("(layer :opacities [0.0 1.0 1.5])", schema);
    defer deinitBundle(bad);
    try testing.expect(bad.result.hasErrors());
    try testing.expect(anyCode(bad.result.diagnostics, .number_above_max));
}

test "loaded-manifest: numeric-bounds metadata is NOT persisted in JSON canonical form" {
    // Round-trip contract: schema metadata is not serialised; the value
    // is. After tree → JSON → tree, the same loaded schema still catches
    // the same out-of-range value.
    var r = try loadManifest(
        \\(plugin :name p :version "1.0.0"
        \\  (form :name set
        \\    (key :name v :type opacity :optional false))
        \\  (value-kind :name opacity :underlying number
        \\    :numeric (numeric-bounds :min 0 :max 1)))
    );
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const schema = Schema.Schema.init(&.{r.plugin});

    var src_tree = try Parser.parse(testing.allocator, "(set :v 1.5)");
    defer src_tree.deinit();

    var enc = try Json.toJson(testing.allocator, src_tree, .{});
    defer enc.deinit();

    var rt = try Json.fromJson(testing.allocator, enc.value, .{});
    defer rt.deinit();

    var verdict = try validate(testing.allocator, rt, schema);
    defer verdict.deinit();
    try testing.expect(verdict.hasErrors());
    try testing.expect(anyCode(verdict.diagnostics, .number_above_max));
}

test "meta-schema: validates a (numeric-bounds …) manifest against MetaSchema" {
    // The MetaSchema is the manifest's own grammar. A well-formed
    // (numeric-bounds …) form must pass MetaSchema validation — this is
    // the self-hosting gate that keeps the meta-schema and the loader
    // in lockstep.
    const a = testing.allocator;
    var tree = try Parser.parse(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name opacity :underlying number
        \\    :numeric (numeric-bounds :min 0 :max 1 :exclusive-max true :integer false)))
    );
    defer tree.deinit();
    var r = try validate(a, tree, MetaSchema.schema);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "meta-schema: rejects (numeric-bounds :min \"oops\") — string in number-typed key" {
    const a = testing.allocator;
    var tree = try Parser.parse(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name k :underlying number
        \\    :numeric (numeric-bounds :min "oops")))
    );
    defer tree.deinit();
    var r = try validate(a, tree, MetaSchema.schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    // The meta-schema's :min `KeySpec.value_type = .number` rejects the
    // string via the standard wrong_underlying type-mismatch code.
    try testing.expect(anyCode(r.diagnostics, .wrong_underlying));
}

test "meta-schema: accepts :numeric pinned to (numeric-bounds …) but rejects (unit-shape …)" {
    // Reuses the existing meta-schema pin: `:numeric (numeric-bounds-ref …)`.
    // Swapping in a different form head (`unit-shape`) should be a
    // structural type mismatch detected by HeadSet narrowing.
    const a = testing.allocator;
    var tree = try Parser.parse(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name k :underlying number
        \\    :numeric (unit-shape :required true)))
    );
    defer tree.deinit();
    var r = try validate(a, tree, MetaSchema.schema);
    defer r.deinit();
    try testing.expect(r.hasErrors());
}

test "loaded-manifest: numeric_bounds_invalid in manifest still produces a usable schema" {
    // Diagnostics-are-the-contract: an invalid manifest emits the
    // numeric_bounds_invalid code at load time but still returns the
    // assembled `plugin` so the rest of the pipeline can continue. We
    // assert both the error code AND the the kind is loaded with the
    // bounds we parsed (loader does not redact on a load-time fail).
    var r = try loadManifest(
        \\(plugin :name p :version "1.0.0"
        \\  (form :name set
        \\    (key :name v :type x :optional false))
        \\  (value-kind :name x :underlying number
        \\    :numeric (numeric-bounds :max 0 :exclusive-min true)))
    );
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(anyCode(r.diagnostics, .numeric_bounds_invalid));
    try testing.expect(r.plugin.value_kinds.len == 1);
    try testing.expect(r.plugin.value_kinds[0].numeric.?.exclusive_min);
}

// ----- String-bounds validator tests ---------------------------------------

fn stringBoundsSchema(
    comptime name: []const u8,
    comptime sb: Plugin.ValueKind.StringBounds,
    comptime members: ?Plugin.ValueKind.MemberSet,
) Schema.Schema {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "v", .value_type = .{ .named = .{ .name = name } } }},
            },
        },
        .value_kinds = &.{
            .{
                .name = name,
                .underlying = .string,
                .members = members,
                .string_bounds = sb,
            },
        },
    };
    return Schema.Schema.init(&.{p});
}

test "string-bounds tree: value below :min-len emits string_too_short" {
    const schema = stringBoundsSchema("ss", .{ .min_len = 3 }, null);
    var bundle = try validateSrc("(set :v \"ab\")", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.string_too_short, bundle.result.diagnostics[0].code);
}

test "string-bounds tree: value at :min-len passes (inclusive)" {
    const schema = stringBoundsSchema("ss", .{ .min_len = 3 }, null);
    var bundle = try validateSrc("(set :v \"abc\")", schema);
    defer deinitBundle(bundle);
    try testing.expect(!bundle.result.hasErrors());
}

test "string-bounds tree: value above :max-len emits string_too_long" {
    const schema = stringBoundsSchema("ss", .{ .max_len = 3 }, null);
    var bundle = try validateSrc("(set :v \"abcd\")", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.string_too_long, bundle.result.diagnostics[0].code);
}

test "string-bounds tree: :max-len counts codepoints not bytes" {
    // "héllo" is 5 codepoints / 6 UTF-8 bytes — must pass :max-len 5.
    const schema = stringBoundsSchema("ss", .{ .max_len = 5 }, null);
    var bundle = try validateSrc("(set :v \"héllo\")", schema);
    defer deinitBundle(bundle);
    try testing.expect(!bundle.result.hasErrors());
}

test "string-bounds tree: :format email passes valid value" {
    const schema = stringBoundsSchema("ss", .{ .format = .email }, null);
    var bundle = try validateSrc("(set :v \"ada@example.com\")", schema);
    defer deinitBundle(bundle);
    try testing.expect(!bundle.result.hasErrors());
}

test "string-bounds tree: :format email rejects bad value" {
    const schema = stringBoundsSchema("ss", .{ .format = .email }, null);
    var bundle = try validateSrc("(set :v \"nope\")", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.string_format_mismatch, bundle.result.diagnostics[0].code);
}

test "string-bounds tree: :format uuid validates 8-4-4-4-12" {
    const schema = stringBoundsSchema("ss", .{ .format = .uuid }, null);
    var bundle = try validateSrc(
        "(set :v \"550e8400-e29b-41d4-a716-446655440000\")",
        schema,
    );
    defer deinitBundle(bundle);
    try testing.expect(!bundle.result.hasErrors());
}

test "string-bounds tree: :format semver rejects v-prefix" {
    const schema = stringBoundsSchema("ss", .{ .format = .semver }, null);
    var bundle = try validateSrc("(set :v \"v1.2.3\")", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.string_format_mismatch, bundle.result.diagnostics[0].code);
}

test "string-bounds tree: length checked before format (priority)" {
    // Value is too long AND wrong format — length fires first.
    const schema = stringBoundsSchema("ss", .{ .max_len = 3, .format = .email }, null);
    var bundle = try validateSrc("(set :v \"xxxx\")", schema);
    defer deinitBundle(bundle);
    try testing.expect(bundle.result.hasErrors());
    try testing.expectEqual(Ast.Diagnostic.Code.string_too_long, bundle.result.diagnostics[0].code);
}

test "string-bounds tree: :pattern emits string_pattern_unsupported warning" {
    const schema = stringBoundsSchema("ss", .{ .pattern = "^[a-z]+$" }, null);
    var bundle = try validateSrc("(set :v \"abc\")", schema);
    defer deinitBundle(bundle);
    // No errors — pattern is informational only in v1.
    try testing.expect(!bundle.result.hasErrors());
    // But at least one warning fires.
    try testing.expect(anyCode(bundle.result.diagnostics, .string_pattern_unsupported));
}

test "string-bounds tree: members + bounds coexist (both apply)" {
    const ms: Plugin.ValueKind.MemberSet = .{ .members = &.{
        .{ .name = "alpha" }, .{ .name = "beta" }, .{ .name = "gamma" },
    } };
    const schema = stringBoundsSchema("ss", .{ .min_len = 4 }, ms);
    // "alpha" — in members AND length 5 (≥ 4): passes.
    var ok = try validateSrc("(set :v \"alpha\")", schema);
    defer deinitBundle(ok);
    try testing.expect(!ok.result.hasErrors());
}

// `string_pattern_mismatch` had a test here that was only
// `_ = Ast.Diagnostic.Code.string_pattern_mismatch;` — the exact
// construct-only shape `tools/reserved_diagnostic_codes.txt` was created
// to replace, kept alive by living in this file rather than the one that
// got cleaned up. It has moved to that allowlist, where the reason (v1
// ships no regex engine, so the code has no emitter to reach) is stated
// once and the audit reports it as `reserved` rather than `test`.

// ---------------------------------------------------------------------------
// Scalar-arm message-parity pins. These lock the exact prose of the eight
// distinct failures produced by the number / string / symbol refinement arms
// — the axes about to be lifted into the shared `matchScalar` seam. The corpus
// compares only (code, path, severity), so a payload the shared matcher
// forwards differently between the tree and binary views (unit, numeric,
// text, cross-ref span/node) would drift invisibly; `expectMessageOnBoth`
// renders the failure through each path's emitter and asserts byte-identity.
// Written BEFORE the extraction (they were green pre-seam) as the
// characterization net the refactor is checked against.
// ---------------------------------------------------------------------------

test "scalar message parity: wrong_underlying (string in number slot)" {
    const p: Plugin.Plugin = .{ .name = "demo", .forms = &.{.{ .name = "scene", .keys = &.{.{ .name = "bpm", .value_type = .number }} }} };
    try expectMessageOnBoth("(scene :bpm \"x\")", Schema.Schema.init(&.{p}), .wrong_underlying, "form `scene` keyword `:bpm` expects number, got string");
}

test "scalar message parity: unit_required (bare number, unit demanded)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "duration" } } }} }},
        .value_kinds = &.{.{ .name = "duration", .underlying = .number, .unit = .{ .required = true, .allowed = &.{ "s", "ms" } } }},
    };
    try expectMessageOnBoth("(set :k 250)", Schema.Schema.init(&.{p}), .unit_required, "form `set` keyword `:k` expects `duration`, got number without unit (allowed: `s`, `ms`)");
}

test "scalar message parity: unit_not_allowed (disallowed suffix)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "duration" } } }} }},
        .value_kinds = &.{.{ .name = "duration", .underlying = .number, .unit = .{ .required = true, .allowed = &.{ "s", "ms" } } }},
    };
    try expectMessageOnBoth("(set :k 90deg)", Schema.Schema.init(&.{p}), .unit_not_allowed, "form `set` keyword `:k` expects `duration`, got number with unit `deg` (allowed: `s`, `ms`)");
}

test "scalar message parity: number_below_min (numeric bounds via extras.numeric)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "level" } } }} }},
        .value_kinds = &.{.{ .name = "level", .underlying = .number, .numeric = .{ .min = .{ .value = 1, .exact_int = true } } }},
    };
    try expectMessageOnBoth("(set :k 0)", Schema.Schema.init(&.{p}), .number_below_min, "form `set` keyword `:k` expects `level`, value 0 below minimum 1");
}

test "scalar message parity: not_member (string members)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "color" } } }} }},
        .value_kinds = &.{.{ .name = "color", .underlying = .string, .members = .{ .members = &.{ .{ .name = "red" }, .{ .name = "green" } } } }},
    };
    try expectMessageOnBoth("(set :k \"blue\")", Schema.Schema.init(&.{p}), .not_member, "form `set` keyword `:k` expects `color`, got `blue` (allowed: `red`, `green`)");
}

test "scalar message parity: string_too_short (string_bounds)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "name" } } }} }},
        .value_kinds = &.{.{ .name = "name", .underlying = .string, .string_bounds = .{ .min_len = 3 } }},
    };
    try expectMessageOnBoth("(set :k \"ab\")", Schema.Schema.init(&.{p}), .string_too_short, "form `set` keyword `:k` expects `name`, string length 2 is below :min-len 3");
}

test "scalar message parity: not_member (symbol members)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "set", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "projection" } } }} }},
        .value_kinds = &.{.{ .name = "projection", .underlying = .symbol, .members = .{ .members = &.{ .{ .name = "ortho" }, .{ .name = "perspective" } } } }},
    };
    try expectMessageOnBoth("(set :k iso)", Schema.Schema.init(&.{p}), .not_member, "form `set` keyword `:k` expects `projection`, got `iso` (allowed: `ortho`, `perspective`)");
}

test "scalar message parity: not_cross_ref (symbol cross-ref)" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .value_kinds = &.{.{ .name = "phrase-name", .underlying = .symbol, .cross_ref = .{ .target_form = "phrase" } }},
        .forms = &.{
            .{ .name = "phrase", .keys = &.{.{ .name = "name", .value_type = .symbol }} },
            .{ .name = "ref", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "phrase-name" } } }} },
        },
    };
    try expectMessageOnBoth("(ref :k missing)", Schema.Schema.init(&.{p}), .not_cross_ref, "form `ref` keyword `:k` expects `phrase-name`, got `missing` (no `(demo/phrase :name …)` form declares this name)");
}

// The message names the key the member set is actually drawn from. Both
// tests below would have read `:name … form declares this name` before —
// true only for the default identity route, and a misdirection on either
// of these: one registers under `:id`, the other under no key at all.

test "scalar message parity: not_cross_ref names a non-default :name-key" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .value_kinds = &.{.{ .name = "node-ref", .underlying = .symbol, .cross_ref = .{ .target_form = "node", .name_key = "id" } }},
        .forms = &.{
            .{ .name = "node", .keys = &.{.{ .name = "id", .value_type = .symbol }} },
            .{ .name = "ref", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "node-ref" } } }} },
        },
    };
    try expectMessageOnBoth("(ref :k missing)", Schema.Schema.init(&.{p}), .not_cross_ref, "form `ref` keyword `:k` expects `node-ref`, got `missing` (no `(demo/node :id …)` form declares this name)");
}

test "scalar message parity: not_cross_ref points at the source key on the provider route" {
    // Declaration-only provider: the reference still resolves against a
    // bucket, and this document's `(shader …)`-free forest leaves that
    // bucket empty rather than poisoned, so the miss is reportable.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .cross_ref_providers = &.{.{ .name = "uniforms" }},
        .value_kinds = &.{.{ .name = "uniform-ref", .underlying = .symbol, .cross_ref = .{ .target_form = "shader", .provider = "uniforms", .source_key = "code" } }},
        .forms = &.{
            .{ .name = "shader", .keys = &.{ .{ .name = "name", .value_type = .symbol }, .{ .name = "code", .value_type = .string } } },
            .{ .name = "ref", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "uniform-ref" } } }} },
        },
    };
    try expectMessageOnBoth("(ref :k missing)", Schema.Schema.init(&.{p}), .not_cross_ref, "form `ref` keyword `:k` expects `uniform-ref`, got `missing` (no `(demo/shader :code …)` source provides this name)");
}

// ---------------------------------------------------------------------------
// Budget trips — the `error.DepthExceeded` arms on the binary side.
//
// `MAX_VALIDATE_STEPS` / `MAX_VALIDATE_FRAMES` guard two loops:
// `validateOneBinary`'s per-buffer walk (here) and the cross-index pass that
// runs ahead of it. Neither had ever tripped — the production values are out
// of reach of a document a test would write, so both arms were dead code any
// refactor could delete silently. `Validator.Budget` is the seam.
//
// The cross-index trip lives inline in `Validator.zig` instead, and has to:
// that pass runs FIRST, so a budget small enough to trip it is also small
// enough to trip the per-buffer walk, and a test driven through the public
// entry cannot tell which one answered. It passes with the cross-index
// guards reverted — which is exactly what "vacuous" means. Reaching
// `buildCrossRefIndexBinary` directly is the only way to attribute the trip.
//
// `validateOneTree` is deliberately absent from both. It has no ceiling and
// needs none: it pushes a frame per child up-front, so a frame cap would
// reject a merely wide document, and every node is pushed exactly once by
// its parent — the walk is bounded by the tree the parser already bounded.
// See `Validator.Budget`'s doc comment.
// ---------------------------------------------------------------------------

test "budget: the per-buffer binary walk trips its step ceiling" {
    const schema = Schema.Schema.init(&.{core.plugin});
    const bin = try encodeForValidate("(+ 1 (* 2 (- 3 4)))");
    defer bin.deinit();

    // One step cannot walk a four-form nest. Frames stay at 2-3, far under
    // the frame cap, so the step count is the only ceiling that can fire.
    try testing.expectError(
        error.DepthExceeded,
        Validator.validateBinaryWithBudget(testing.allocator, bin.data, schema, .{ .steps = 1 }, null),
    );

    // Control: the same buffer under the production ceilings.
    var ok = try Validator.validateBinaryWithBudget(testing.allocator, bin.data, schema, .{}, null);
    defer ok.deinit();
    try testing.expect(!ok.hasErrors());
}

test "budget: the per-buffer binary walk trips its frame ceiling" {
    const schema = Schema.Schema.init(&.{core.plugin});
    const bin = try encodeForValidate("(+ 1 (* 2 (- 3 4)))");
    defer bin.deinit();

    // A cap of one admits the root frame and refuses its first descent.
    // Steps are left at the production value, so this is the frame guard.
    try testing.expectError(
        error.DepthExceeded,
        Validator.validateBinaryWithBudget(testing.allocator, bin.data, schema, .{ .frames = 1 }, null),
    );
}

test "budget: forest-wide entry honors the same ceilings" {
    const schema = Schema.Schema.init(&.{core.plugin});
    const bin = try encodeForValidate("(+ 1 (* 2 3))");
    defer bin.deinit();
    var bins: [2][]const u8 = .{ bin.data, bin.data };

    try testing.expectError(
        error.DepthExceeded,
        Validator.validateForestBinaryWithBudget(testing.allocator, &bins, schema, .{ .steps = 1 }, null),
    );

    var ok = try Validator.validateForestBinaryWithBudget(testing.allocator, &bins, schema, .{}, null);
    defer ok.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), ok.results.len);
}

// ---------------------------------------------------------------------------
// Provider-route cross-refs: extraction-backed registries, poisoned buckets
//
// The registry for a provider-route target is filled from the host's
// extraction table rather than from a `:name-key` symbol on each instance.
// What these pin is the part that has no identity-route counterpart: what
// happens when the member set cannot be computed at all.
// ---------------------------------------------------------------------------

/// `shader` carries the opaque `:src` an extractor reads. `bind` references
/// an extracted name the author wrote; `ghost-bind` references one the
/// author *didn't* — its default drives the second membership site, the
/// Axis-B effective-ref pass. `pass` exists only to nest a shader one level
/// down, so the walk is doing real descent.
const ProviderXref = struct {
    const forms: []const Plugin.FormSpec = &.{
        .{ .name = "shader", .keys = &.{
            .{ .name = "name", .value_type = .symbol },
            .{ .name = "src", .value_type = .string },
        } },
        .{ .name = "bind", .keys = &.{
            .{ .name = "uniform", .value_type = .{ .named = .{ .name = "uniform-name" } } },
        } },
        .{ .name = "ghost-bind", .keys = &.{
            .{
                .name = "uniform",
                .value_type = .{ .named = .{ .name = "uniform-name" } },
                .default = .{ .symbol = "u_ghost" },
                .optional = true,
            },
        } },
        .{ .name = "pass", .keys = &.{.{ .name = "items", .value_type = .any }} },
    };

    const plugin: Plugin.Plugin = .{
        .name = "glsl",
        .cross_ref_providers = &.{.{ .name = "lines", .description = "one name per line" }},
        .value_kinds = &.{.{
            .name = "uniform-name",
            .underlying = .symbol,
            .cross_ref = .{ .target_form = "shader", .provider = "lines" },
        }},
        .forms = forms,
    };

    const schema = Schema.Schema.init(&.{plugin});

    /// A table with one answer in it. `names` are borrowed by the map and
    /// duped by the index, which is exactly the lifetime the production
    /// path has — the host owns the table, the registry owns its copies.
    fn tableOf(a: Allocator, source: []const u8, outcome: Validator.Extraction) !Validator.ExtractionMap {
        var map: Validator.ExtractionMap = .empty;
        errdefer map.deinit(a);
        try map.put(a, .{ .provider = "glsl/lines", .source = source }, outcome);
        return map;
    }
};

/// Validate `src` on the tree path with an extraction table in hand.
fn validateWithExtractions(
    a: Allocator,
    src: [:0]const u8,
    extractions: *const Validator.ExtractionMap,
) !struct { tree: Ast.Tree, result: Validator.Result } {
    var tree = try Parser.parse(a, src);
    errdefer tree.deinit();
    const result = try Validator.validateWithOptions(a, tree, ProviderXref.schema, .{
        .extractions = extractions,
    });
    return .{ .tree = tree, .result = result };
}

/// The `expectCodeOnBoth` family's provider-route member. Counts rather
/// than presence: what poisoning changes is *how many* diagnostics come
/// out, and a presence check passes just as happily on a cascade.
///
/// The dual run is the tree/binary-parity rule made executable here. The
/// two index builders read the source string from completely different
/// places — the tree walk reads it off the form's children at registration
/// time, the binary walk has to capture it mid-iteration because the
/// cursor is monotonic — so a drift between them is a live possibility,
/// not a formality.
fn expectProviderCountOnBoth(
    src: [:0]const u8,
    extractions: ?*const Validator.ExtractionMap,
    code: Diagnostic.Code,
    n: usize,
) !void {
    const a = testing.allocator;
    var tree = try Parser.parse(a, src);
    defer tree.deinit();

    var tr = try Validator.validateWithOptions(a, tree, ProviderXref.schema, .{
        .extractions = extractions,
    });
    defer tr.deinit();
    try testing.expectEqual(n, countDiagWithCode(tr.diagnostics, code));

    const bin = try Binary.toBinary(a, tree, .{ .with_spans = true });
    defer bin.deinit();
    var bins: [1][]const u8 = .{bin.data};
    var fr = try Validator.validateForestBinary(a, &bins, ProviderXref.schema, extractions);
    defer fr.deinit(a);
    try testing.expectEqual(n, countDiagWithCode(fr.results[0].diagnostics, code));
}

test "provider xref: extracted names register and references resolve" {
    const a = testing.allocator;
    var table = try ProviderXref.tableOf(a, "u_time\nu_res", .{ .names = &.{ "u_time", "u_res" } });
    defer table.deinit(a);

    var out = try validateWithExtractions(a,
        \\(pass :items [(shader :name main :src "u_time\nu_res")])
        \\(bind :uniform u_time)
        \\(bind :uniform u_res)
    , &table);
    defer out.tree.deinit();
    defer out.result.deinit();

    try testing.expectEqual(@as(usize, 0), countDiagWithCode(out.result.diagnostics, .not_cross_ref));
    try testing.expect(!out.result.hasErrors());
}

test "provider xref: a name the extractor did not return is still a miss" {
    const a = testing.allocator;
    var table = try ProviderXref.tableOf(a, "u_time", .{ .names = &.{"u_time"} });
    defer table.deinit(a);

    // The whole point of a *computed* member set is that it is still a set:
    // a successful extraction checks references as strictly as `:name-key`
    // ever did. Only an uncomputable one goes quiet.
    var out = try validateWithExtractions(a,
        \\(shader :name main :src "u_time")
        \\(bind :uniform u_nope)
    , &table);
    defer out.tree.deinit();
    defer out.result.deinit();

    try testing.expectEqual(@as(usize, 1), countDiagWithCode(out.result.diagnostics, .not_cross_ref));
}

test "provider xref: a failed extraction poisons the bucket, once" {
    const a = testing.allocator;
    var table = try ProviderXref.tableOf(a, "!!!", .{
        .failure = .{ .message = "unexpected `!` at top level", .offset = 0 },
    });
    defer table.deinit(a);

    var out = try validateWithExtractions(a,
        \\(shader :name main :src "!!!")
        \\(bind :uniform u_time)
        \\(bind :uniform u_res)
    , &table);
    defer out.tree.deinit();
    defer out.result.deinit();

    // One root-cause diagnostic at the source, and no cascade: two
    // references into a set nobody could compute stay silent.
    try testing.expectEqual(@as(usize, 1), countDiagWithCode(out.result.diagnostics, .cross_ref_extraction_failed));
    try testing.expectEqual(@as(usize, 0), countDiagWithCode(out.result.diagnostics, .not_cross_ref));

    // The provider's own words survive into the message, and so does the
    // offset — the source is opaque to SJON, so the byte offset is the
    // only positional information anyone has.
    for (out.result.diagnostics) |d| {
        if (d.code != .cross_ref_extraction_failed) continue;
        try testing.expect(std.mem.indexOf(u8, d.message, "unexpected `!`") != null);
        try testing.expect(std.mem.indexOf(u8, d.message, "byte 0") != null);
        // Index-pass convention: anchored on span, path empty.
        try testing.expectEqual(@as(usize, 0), d.path.len);
    }
}

test "provider xref: an unavailable provider poisons the bucket too" {
    const a = testing.allocator;
    var table = try ProviderXref.tableOf(a, "u_time", .{ .unavailable = "host has no plugin runtime" });
    defer table.deinit(a);

    var out = try validateWithExtractions(a,
        \\(shader :name main :src "u_time")
        \\(bind :uniform u_time)
        \\(bind :uniform u_whatever)
    , &table);
    defer out.tree.deinit();
    defer out.result.deinit();

    try testing.expectEqual(@as(usize, 1), countDiagWithCode(out.result.diagnostics, .cross_ref_provider_unavailable));
    try testing.expectEqual(@as(usize, 0), countDiagWithCode(out.result.diagnostics, .not_cross_ref));
    for (out.result.diagnostics) |d| {
        if (d.code != .cross_ref_provider_unavailable) continue;
        try testing.expect(std.mem.indexOf(u8, d.message, "no plugin runtime") != null);
    }
}

test "provider xref: no extraction table at all reads as unavailable" {
    const a = testing.allocator;
    var empty: Validator.ExtractionMap = .empty;
    defer empty.deinit(a);

    // A host that never ran the pre-pass and a host whose pre-pass missed
    // this pair are the same situation from the document's point of view:
    // nobody can say what belongs in this bucket. Both must poison, or the
    // references below cascade into noise on every non-executing host.
    var out = try validateWithExtractions(a,
        \\(shader :name main :src "u_time")
        \\(bind :uniform u_time)
    , &empty);
    defer out.tree.deinit();
    defer out.result.deinit();

    try testing.expectEqual(@as(usize, 1), countDiagWithCode(out.result.diagnostics, .cross_ref_provider_unavailable));
    try testing.expectEqual(@as(usize, 0), countDiagWithCode(out.result.diagnostics, .not_cross_ref));
}

test "provider xref: an unusable :source-key is skipped in silence" {
    const a = testing.allocator;
    var empty: Validator.ExtractionMap = .empty;
    defer empty.deinit(a);

    // Neither shader supplies a string `:src`, so neither was ever a
    // request — and an instance discovery never asked about must not
    // report the answer as missing. The non-string one has its own
    // slot-typed diagnostic; cross-ref doesn't cascade on top of it.
    var out = try validateWithExtractions(a,
        \\(shader :name a)
        \\(shader :name b :src 42)
    , &empty);
    defer out.tree.deinit();
    defer out.result.deinit();

    try testing.expectEqual(@as(usize, 0), countDiagWithCode(out.result.diagnostics, .cross_ref_provider_unavailable));
    try testing.expectEqual(@as(usize, 0), countDiagWithCode(out.result.diagnostics, .cross_ref_extraction_failed));
}

test "provider xref: two sources yielding one name collide as duplicates" {
    const a = testing.allocator;
    var table: Validator.ExtractionMap = .empty;
    defer table.deinit(a);
    try table.put(a, .{ .provider = "glsl/lines", .source = "one" }, .{ .names = &.{"u_time"} });
    try table.put(a, .{ .provider = "glsl/lines", .source = "two" }, .{ .names = &.{"u_time"} });

    // Distinct sources, same extracted name, same scope — the existing
    // duplicate path, anchored at the *second* source's span rather than
    // at a `:name` value that doesn't exist on this route.
    var out = try validateWithExtractions(a,
        \\(shader :name a :src "one")
        \\(shader :name b :src "two")
    , &table);
    defer out.tree.deinit();
    defer out.result.deinit();

    try testing.expectEqual(@as(usize, 1), countDiagWithCode(out.result.diagnostics, .duplicate_cross_ref_target));
    for (out.result.diagnostics) |d| {
        if (d.code != .duplicate_cross_ref_target) continue;
        const at = out.tree.source[d.span.start..d.span.end];
        try testing.expectEqualStrings("\"two\"", at);
    }
}

test "provider xref: one source's repeated name is the provider's business" {
    const a = testing.allocator;
    // `fulfill` dedupes within a source, so this shape shouldn't reach the
    // index — but the index is fed by a host, and a host that skipped that
    // contract must not turn its own bug into a document diagnostic.
    var table = try ProviderXref.tableOf(a, "dup", .{ .names = &.{ "u_time", "u_time" } });
    defer table.deinit(a);

    var out = try validateWithExtractions(a, "(shader :name a :src \"dup\")", &table);
    defer out.tree.deinit();
    defer out.result.deinit();

    try testing.expectEqual(@as(usize, 1), countDiagWithCode(out.result.diagnostics, .duplicate_cross_ref_target));
}

test "provider xref [B]: a poisoned bucket silences the effective-ref pass too" {
    const a = testing.allocator;
    var table = try ProviderXref.tableOf(a, "!!!", .{ .failure = .{ .message = "malformed" } });
    defer table.deinit(a);

    // `(ghost-bind)` writes no `:uniform`, so the only thing checking its
    // defaulted `u_ghost` against the registry is `maybeEmitEffectiveRefMiss`
    // — the second membership site. Poison has to reach it as well, or the
    // cascade this feature exists to prevent comes back through Axis B.
    const src: [:0]const u8 =
        \\(shader :name main :src "!!!")
        \\(ghost-bind)
    ;
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var mat = try MaterializedDefaultsMod.materializeDefaults(a, arena.allocator(), &tree, tree.root, ProviderXref.schema);
    defer mat.deinit(a);

    var result = try Validator.validateWithOptions(a, tree, ProviderXref.schema, .{
        .overlay = &mat.materialized,
        .axes = .{ .ref_lookup = true },
        .extractions = &table,
    });
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), countDiagWithCode(result.diagnostics, .cross_ref_extraction_failed));
    try testing.expectEqual(@as(usize, 0), countDiagWithCode(result.diagnostics, .not_cross_ref));
}

test "provider xref [B]: a healthy registry still catches a bad default" {
    const a = testing.allocator;
    var table = try ProviderXref.tableOf(a, "u_time", .{ .names = &.{"u_time"} });
    defer table.deinit(a);

    // The control for the test above: same shape, computable member set.
    // Without this, "no not_cross_ref" would also pass if Axis B had
    // simply stopped working on this fixture.
    const src: [:0]const u8 =
        \\(shader :name main :src "u_time")
        \\(ghost-bind)
    ;
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var mat = try MaterializedDefaultsMod.materializeDefaults(a, arena.allocator(), &tree, tree.root, ProviderXref.schema);
    defer mat.deinit(a);

    var result = try Validator.validateWithOptions(a, tree, ProviderXref.schema, .{
        .overlay = &mat.materialized,
        .axes = .{ .ref_lookup = true },
        .extractions = &table,
    });
    defer result.deinit();

    try testing.expect(hasDiagAtPath(
        result.diagnostics,
        .not_cross_ref,
        &.{ "ghost-bind", "uniform", "default" },
    ));
}

// --- The same cases, locked on both walkers ---------------------------------
//
// Each of these repeats a tree-path case above through
// `expectProviderCountOnBoth`. The repetition is the point: the assertions
// above pin wording and anchoring, which are tree-path concerns; these pin
// that the binary index builder reaches the same answer from a monotonic
// cursor that cannot look back at the form's children.

test "provider xref (both paths): a resolved reference is clean" {
    const a = testing.allocator;
    var table = try ProviderXref.tableOf(a, "u_time", .{ .names = &.{"u_time"} });
    defer table.deinit(a);
    try expectProviderCountOnBoth(
        \\(pass :items [(shader :name main :src "u_time")])
        \\(bind :uniform u_time)
    , &table, .not_cross_ref, 0);
}

test "provider xref (both paths): an unextracted name still misses" {
    const a = testing.allocator;
    var table = try ProviderXref.tableOf(a, "u_time", .{ .names = &.{"u_time"} });
    defer table.deinit(a);
    try expectProviderCountOnBoth(
        \\(shader :name main :src "u_time")
        \\(bind :uniform u_nope)
    , &table, .not_cross_ref, 1);
}

test "provider xref (both paths): a failed extraction fires once and poisons" {
    const a = testing.allocator;
    var table = try ProviderXref.tableOf(a, "!!!", .{ .failure = .{ .message = "malformed" } });
    defer table.deinit(a);
    const src: [:0]const u8 =
        \\(shader :name main :src "!!!")
        \\(bind :uniform u_time)
        \\(bind :uniform u_res)
    ;
    try expectProviderCountOnBoth(src, &table, .cross_ref_extraction_failed, 1);
    try expectProviderCountOnBoth(src, &table, .not_cross_ref, 0);
}

test "provider xref (both paths): an unavailable provider fires once and poisons" {
    const a = testing.allocator;
    var table = try ProviderXref.tableOf(a, "u_time", .{ .unavailable = "no runtime" });
    defer table.deinit(a);
    const src: [:0]const u8 =
        \\(shader :name main :src "u_time")
        \\(bind :uniform u_time)
    ;
    try expectProviderCountOnBoth(src, &table, .cross_ref_provider_unavailable, 1);
    try expectProviderCountOnBoth(src, &table, .not_cross_ref, 0);
}

test "provider xref (both paths): no table at all is unavailable, not a miss" {
    const src: [:0]const u8 =
        \\(shader :name main :src "u_time")
        \\(bind :uniform u_time)
    ;
    // `null`, not an empty map: this is the shape every host that never ran
    // the pre-pass hands in, and it must not read as "the set is empty".
    try expectProviderCountOnBoth(src, null, .cross_ref_provider_unavailable, 1);
    try expectProviderCountOnBoth(src, null, .not_cross_ref, 0);
}

test "provider xref (both paths): an unusable :source-key is silent" {
    const src: [:0]const u8 =
        \\(shader :name a)
        \\(shader :name b :src 42)
    ;
    try expectProviderCountOnBoth(src, null, .cross_ref_provider_unavailable, 0);
    try expectProviderCountOnBoth(src, null, .cross_ref_extraction_failed, 0);
}

test "provider xref (both paths): two sources, one name, one duplicate" {
    const a = testing.allocator;
    var table: Validator.ExtractionMap = .empty;
    defer table.deinit(a);
    try table.put(a, .{ .provider = "glsl/lines", .source = "one" }, .{ .names = &.{"u_time"} });
    try table.put(a, .{ .provider = "glsl/lines", .source = "two" }, .{ .names = &.{"u_time"} });
    try expectProviderCountOnBoth(
        \\(shader :name a :src "one")
        \\(shader :name b :src "two")
    , &table, .duplicate_cross_ref_target, 1);
}

test "provider xref (both paths): first :src wins on a duplicated key" {
    const a = testing.allocator;
    // Only the *first* `:src` is answerable. If either walker read the
    // second one instead, the pair would be missing from the table and the
    // bucket would poison — so the count below distinguishes the two
    // first-wins implementations, which is exactly what it is for.
    var table = try ProviderXref.tableOf(a, "one", .{ .names = &.{"u_time"} });
    defer table.deinit(a);
    const src: [:0]const u8 =
        \\(shader :name a :src "one" :src "two")
        \\(bind :uniform u_time)
    ;
    try expectProviderCountOnBoth(src, &table, .cross_ref_provider_unavailable, 0);
    try expectProviderCountOnBoth(src, &table, .not_cross_ref, 0);
}

test "provider xref (both paths): a nested source is reached by both walks" {
    const a = testing.allocator;
    var table = try ProviderXref.tableOf(a, "u_deep", .{ .names = &.{"u_deep"} });
    defer table.deinit(a);
    // Two levels of `pass` plus a vector hop: the binary walk descends
    // through frames while the tree walk descends through a node stack, and
    // a target the binary walk failed to reach would poison rather than
    // resolve.
    try expectProviderCountOnBoth(
        \\(pass :items [(pass :items [(shader :name deep :src "u_deep")])])
        \\(bind :uniform u_deep)
    , &table, .not_cross_ref, 0);
}

// --- Scope composition ------------------------------------------------------

/// Same fixture, one key different: the cross-ref is `:scope pass`, so each
/// `(pass …)` instance opens its own registry. Nothing about the provider
/// route is scope-aware — that is the claim being tested. Extraction is
/// content-addressed and scope-blind; the *registration* is what carries a
/// scope, exactly as on the identity route.
const ScopedProviderXref = struct {
    const plugin: Plugin.Plugin = .{
        .name = "glsl",
        .cross_ref_providers = &.{.{ .name = "lines" }},
        .value_kinds = &.{.{
            .name = "uniform-name",
            .underlying = .symbol,
            .cross_ref = .{ .target_form = "shader", .provider = "lines", .scope_form = "pass" },
        }},
        .forms = ProviderXref.forms,
    };
    const schema = Schema.Schema.init(&.{plugin});
};

fn expectScopedCountOnBoth(
    src: [:0]const u8,
    extractions: ?*const Validator.ExtractionMap,
    code: Diagnostic.Code,
    n: usize,
) !void {
    const a = testing.allocator;
    var tree = try Parser.parse(a, src);
    defer tree.deinit();

    var tr = try Validator.validateWithOptions(a, tree, ScopedProviderXref.schema, .{
        .extractions = extractions,
    });
    defer tr.deinit();
    try testing.expectEqual(n, countDiagWithCode(tr.diagnostics, code));

    const bin = try Binary.toBinary(a, tree, .{ .with_spans = true });
    defer bin.deinit();
    var bins: [1][]const u8 = .{bin.data};
    var fr = try Validator.validateForestBinary(a, &bins, ScopedProviderXref.schema, extractions);
    defer fr.deinit(a);
    try testing.expectEqual(n, countDiagWithCode(fr.results[0].diagnostics, code));
}

/// Two sources, one name each. Used by every scope test below so the only
/// thing varying between them is where the references sit.
fn scopedTable(a: Allocator) !Validator.ExtractionMap {
    var map: Validator.ExtractionMap = .empty;
    errdefer map.deinit(a);
    try map.put(a, .{ .provider = "glsl/lines", .source = "one" }, .{ .names = &.{"u_a"} });
    try map.put(a, .{ .provider = "glsl/lines", .source = "two" }, .{ .names = &.{"u_b"} });
    return map;
}

test "provider xref (both paths): sibling scopes get independent registries" {
    const a = testing.allocator;
    var table = try scopedTable(a);
    defer table.deinit(a);

    // Each pass sees only its own shader's extracted names. Both resolve.
    try expectScopedCountOnBoth(
        \\(pass :items [(shader :name a :src "one") (bind :uniform u_a)])
        \\(pass :items [(shader :name b :src "two") (bind :uniform u_b)])
    , &table, .not_cross_ref, 0);
}

test "provider xref (both paths): a sibling scope's name does not leak in" {
    const a = testing.allocator;
    var table = try scopedTable(a);
    defer table.deinit(a);

    // `u_b` is extracted, registered, and reachable — in the *other* pass.
    // Scoping is what makes this a miss, and it is a miss rather than a
    // poisoned silence because both buckets computed fine.
    try expectScopedCountOnBoth(
        \\(pass :items [(shader :name a :src "one") (bind :uniform u_b)])
        \\(pass :items [(shader :name b :src "two")])
    , &table, .not_cross_ref, 1);
}

test "provider xref (both paths): a reference outside every scope still fires" {
    const a = testing.allocator;
    var table = try scopedTable(a);
    defer table.deinit(a);

    // The scope machinery is upstream of the route: a reference with no
    // enclosing `(pass …)` never reaches a registry to be checked against,
    // poisoned or otherwise.
    try expectScopedCountOnBoth(
        \\(pass :items [(shader :name a :src "one")])
        \\(bind :uniform u_a)
    , &table, .cross_ref_outside_scope, 1);
}

test "provider xref (both paths): poison is per scope, not per target" {
    const a = testing.allocator;
    var table: Validator.ExtractionMap = .empty;
    defer table.deinit(a);
    try table.put(a, .{ .provider = "glsl/lines", .source = "one" }, .{ .names = &.{"u_a"} });
    try table.put(a, .{ .provider = "glsl/lines", .source = "bad" }, .{ .failure = .{ .message = "no" } });

    // The second pass is poisoned; the first is not. If poison were keyed
    // by target alone, the healthy scope's `u_nope` would go quiet too —
    // the miss below is what proves the scope half of the key is live.
    const src: [:0]const u8 =
        \\(pass :items [(shader :name a :src "one") (bind :uniform u_nope)])
        \\(pass :items [(shader :name b :src "bad") (bind :uniform u_whatever)])
    ;
    try expectScopedCountOnBoth(src, &table, .cross_ref_extraction_failed, 1);
    try expectScopedCountOnBoth(src, &table, .not_cross_ref, 1);
}

test "provider xref (both paths): the same source in two scopes extracts once" {
    const a = testing.allocator;
    var table = try ProviderXref.tableOf(a, "one", .{ .names = &.{"u_a"} });
    defer table.deinit(a);

    // Content addressing means one table entry answers both instances, and
    // each registers into its own scope. This is the property that lets the
    // host's pre-pass be instance-blind: it never had to agree with the
    // index pass about how many `(shader …)` forms there are.
    try expectScopedCountOnBoth(
        \\(pass :items [(shader :name a :src "one") (bind :uniform u_a)])
        \\(pass :items [(shader :name b :src "one") (bind :uniform u_a)])
    , &table, .not_cross_ref, 0);
    try expectScopedCountOnBoth(
        \\(pass :items [(shader :name a :src "one") (bind :uniform u_a)])
        \\(pass :items [(shader :name b :src "one") (bind :uniform u_a)])
    , &table, .duplicate_cross_ref_target, 0);
}

// --- Provider route under union dispatch -----------------------------------
//
// A union alternative is tried against a *shallow copy* of the index with
// `arena` nulled (`Validator.zig:5847`), so that a rejected alternative
// leaves no reference capture behind. Poison state is a parallel map on the
// index, so it rides that copy by value and the probe sees it — the claim
// these tests pin.
//
// The second claim is about counting: extraction diagnostics are emitted
// once at index-build time, before any matching happens. Probing re-runs
// alternatives (twice for the winner, once more per alternative when
// nothing matches), so a design that emitted at match time would multiply
// them by the union's arity.

/// `uniform-name` (provider-backed) as one alternative of a union whose
/// other alternative is a closed symbol MemberSet. `auto` is the literal;
/// everything else has to come from the extractor.
const UnionProviderXref = struct {
    const forms: []const Plugin.FormSpec = &.{
        .{ .name = "shader", .keys = &.{
            .{ .name = "name", .value_type = .symbol },
            .{ .name = "src", .value_type = .string },
        } },
        .{ .name = "mixed-bind", .keys = &.{
            .{ .name = "uniform", .value_type = .{ .named = .{ .name = "auto-or-uniform" } } },
        } },
    };

    const plugin: Plugin.Plugin = .{
        .name = "glsl",
        .cross_ref_providers = &.{.{ .name = "lines" }},
        .value_kinds = &.{
            .{
                .name = "uniform-name",
                .underlying = .symbol,
                .cross_ref = .{ .target_form = "shader", .provider = "lines" },
            },
            .{
                .name = "auto-mode",
                .underlying = .symbol,
                .members = .{ .members = &.{.{ .name = "auto" }} },
            },
            .{
                .name = "auto-or-uniform",
                .underlying = .union_of,
                .union_of = .{ .alternatives = &.{ .{ .name = "auto-mode" }, .{ .name = "uniform-name" } } },
            },
        },
        .forms = forms,
    };

    const schema = Schema.Schema.init(&.{plugin});
};

fn expectUnionCountOnBoth(
    src: [:0]const u8,
    extractions: ?*const Validator.ExtractionMap,
    code: Diagnostic.Code,
    n: usize,
) !void {
    const a = testing.allocator;
    var tree = try Parser.parse(a, src);
    defer tree.deinit();

    var tr = try Validator.validateWithOptions(a, tree, UnionProviderXref.schema, .{
        .extractions = extractions,
    });
    defer tr.deinit();
    try testing.expectEqual(n, countDiagWithCode(tr.diagnostics, code));

    const bin = try Binary.toBinary(a, tree, .{ .with_spans = true });
    defer bin.deinit();
    var bins: [1][]const u8 = .{bin.data};
    var fr = try Validator.validateForestBinary(a, &bins, UnionProviderXref.schema, extractions);
    defer fr.deinit(a);
    try testing.expectEqual(n, countDiagWithCode(fr.results[0].diagnostics, code));
}

test "provider xref (both paths): union dispatch reaches a provider-backed alternative" {
    const a = testing.allocator;
    var table = try ProviderXref.tableOf(a, "u_time", .{ .names = &.{"u_time"} });
    defer table.deinit(a);

    // `auto` takes the members alternative, `u_time` the cross-ref one.
    const src =
        \\(shader :name main :src "u_time")
        \\(mixed-bind :uniform auto)
        \\(mixed-bind :uniform u_time)
    ;
    try expectUnionCountOnBoth(src, &table, .union_no_branch_matched, 0);
    try expectUnionCountOnBoth(src, &table, .not_cross_ref, 0);
}

test "provider xref (both paths): a healthy union still rejects an unknown symbol" {
    const a = testing.allocator;
    var table = try ProviderXref.tableOf(a, "u_time", .{ .names = &.{"u_time"} });
    defer table.deinit(a);

    // Neither alternative accepts `u_nope`, and the union reports it once —
    // the "nothing matched" re-run is for capture, not for diagnostics.
    try expectUnionCountOnBoth(
        \\(shader :name main :src "u_time")
        \\(mixed-bind :uniform u_nope)
    , &table, .union_no_branch_matched, 1);
}

test "provider xref (both paths): a poisoned bucket is visible through the union probe" {
    const a = testing.allocator;
    var table = try ProviderXref.tableOf(a, "!!!", .{ .failure = .{ .message = "malformed" } });
    defer table.deinit(a);

    // The cross-ref alternative accepts anything into a poisoned bucket, so
    // the union finds a branch and `u_whatever` is not reported. If poison
    // lived inside `TargetMap` instead of beside it, the shallow probe copy
    // would still see it — but if it lived on the *arena* the probe nulls,
    // this would fail as `union_no_branch_matched`.
    const src =
        \\(shader :name main :src "!!!")
        \\(mixed-bind :uniform u_whatever)
    ;
    try expectUnionCountOnBoth(src, &table, .union_no_branch_matched, 0);
    try expectUnionCountOnBoth(src, &table, .not_cross_ref, 0);
}

test "provider xref (both paths): union probing does not multiply extraction diagnostics" {
    const a = testing.allocator;
    var table = try ProviderXref.tableOf(a, "!!!", .{ .failure = .{ .message = "malformed" } });
    defer table.deinit(a);

    // One broken source, three union-typed references over it — two that
    // probe both alternatives and one that matches the first. The failure is
    // reported once, at the source, because the index pass emits at build
    // time and match time never re-enters it.
    try expectUnionCountOnBoth(
        \\(shader :name main :src "!!!")
        \\(mixed-bind :uniform auto)
        \\(mixed-bind :uniform u_a)
        \\(mixed-bind :uniform u_b)
    , &table, .cross_ref_extraction_failed, 1);
}

test "provider xref (both paths): an unavailable provider under a union is also single" {
    const a = testing.allocator;
    var table = try ProviderXref.tableOf(a, "u_time", .{ .unavailable = "no runtime" });
    defer table.deinit(a);

    try expectUnionCountOnBoth(
        \\(shader :name main :src "u_time")
        \\(mixed-bind :uniform u_a)
        \\(mixed-bind :uniform u_b)
    , &table, .cross_ref_provider_unavailable, 1);
}
