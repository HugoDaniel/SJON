//! Internal tests for Json.zig (Tree ↔ std.json.Value bridge).
//!
//! Pulled out of `Json.zig` to keep the production file at ~624 LOC (was
//! 1392 with tests interleaved). Test discovery: `Json.zig` ends with
//! `test { _ = @import("Json_tests.zig"); }`, so these run transparently
//! under `_ = Json;` from `root.zig`'s test block.
//!
//! Tests access `Json` only through its public surface — every symbol
//! reached here is `pub` in `Json.zig`. Local `const` aliases at the top
//! re-spell those symbols unqualified to keep test bodies readable.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Json = @import("Json.zig");
const Parser = @import("Parser.zig");
const Printer = @import("Printer.zig");
const Schema = @import("Schema.zig");
const Plugin = @import("Plugin.zig");
const core = @import("plugins/core.zig");

const toJson = Json.toJson;
const fromJson = Json.fromJson;
const toJsonRoots = Json.toJsonRoots;
const fromJsonRoots = Json.fromJsonRoots;

fn parseToTree(src: [:0]const u8) !Ast.Tree {
    return try Parser.parse(testing.allocator, src);
}

test "atoms encode" {
    {
        const tree = try parseToTree("nil");
        defer {
            var t = tree;
            t.deinit();
        }
        var r = try toJson(testing.allocator, tree, .{});
        defer r.deinit();
        try testing.expect(r.value == .null);
    }
    {
        const tree = try parseToTree("true");
        defer {
            var t = tree;
            t.deinit();
        }
        var r = try toJson(testing.allocator, tree, .{});
        defer r.deinit();
        try testing.expect(r.value.bool);
    }
    {
        const tree = try parseToTree("42");
        defer {
            var t = tree;
            t.deinit();
        }
        var r = try toJson(testing.allocator, tree, .{});
        defer r.deinit();
        try testing.expectEqual(@as(i64, 42), r.value.integer);
    }
    {
        const tree = try parseToTree("3.5");
        defer {
            var t = tree;
            t.deinit();
        }
        var r = try toJson(testing.allocator, tree, .{});
        defer r.deinit();
        try testing.expectEqual(@as(f64, 3.5), r.value.float);
    }
    {
        const tree = try parseToTree(
            \\"hello"
        );
        defer {
            var t = tree;
            t.deinit();
        }
        var r = try toJson(testing.allocator, tree, .{});
        defer r.deinit();
        try testing.expectEqualStrings("hello", r.value.string);
    }
}

test "keyword canonical mode wraps in $kw" {
    const tree = try parseToTree(":foo");
    defer {
        var t = tree;
        t.deinit();
    }
    var r = try toJson(testing.allocator, tree, .{});
    defer r.deinit();
    try testing.expect(r.value == .object);
    const v = r.value.object.get("$kw") orelse unreachable;
    try testing.expectEqualStrings("foo", v.string);
}

test "keyword lossy mode flattens to string" {
    const tree = try parseToTree(":foo");
    defer {
        var t = tree;
        t.deinit();
    }
    var r = try toJson(testing.allocator, tree, .{ .mode = .compact });
    defer r.deinit();
    try testing.expectEqualStrings("foo", r.value.string);
}

test "vector encodes as array" {
    const tree = try parseToTree("[1 2 3]");
    defer {
        var t = tree;
        t.deinit();
    }
    var r = try toJson(testing.allocator, tree, .{});
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.value.array.items.len);
    try testing.expectEqual(@as(i64, 2), r.value.array.items[1].integer);
}

test "form encodes with $form and keyword children" {
    const tree = try parseToTree("(scene :bpm 130)");
    defer {
        var t = tree;
        t.deinit();
    }
    var r = try toJson(testing.allocator, tree, .{});
    defer r.deinit();
    try testing.expect(r.value == .object);
    const obj = r.value.object;
    try testing.expectEqualStrings("scene", obj.get("$form").?.string);
    try testing.expectEqual(@as(i64, 130), obj.get("bpm").?.integer);
}

test "form encodes namespace as $ns" {
    const tree = try parseToTree("(masagin/verb :ops 1)");
    defer {
        var t = tree;
        t.deinit();
    }
    var r = try toJson(testing.allocator, tree, .{});
    defer r.deinit();
    try testing.expectEqualStrings("verb", r.value.object.get("$form").?.string);
    try testing.expectEqualStrings("masagin", r.value.object.get("$ns").?.string);
}

test "expression form encodes with $expr when schema supplied" {
    const tree = try parseToTree("(+ 1 2)");
    defer {
        var t = tree;
        t.deinit();
    }
    const schema = Schema.Schema.init(&.{core.plugin});
    var r = try toJson(testing.allocator, tree, .{ .schema = schema });
    defer r.deinit();
    const expr = r.value.object.get("$expr") orelse unreachable;
    try testing.expectEqual(@as(usize, 3), expr.array.items.len);
    try testing.expectEqualStrings("+", expr.array.items[0].string);
    try testing.expectEqual(@as(i64, 1), expr.array.items[1].integer);
}

test "expression-shaped form falls back to $form without schema" {
    const tree = try parseToTree("(+ 1 2)");
    defer {
        var t = tree;
        t.deinit();
    }
    var r = try toJson(testing.allocator, tree, .{});
    defer r.deinit();
    try testing.expectEqualStrings("+", r.value.object.get("$form").?.string);
}

test "decode: $form with keyword and children" {
    var obj: std.json.ObjectMap = .empty;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try obj.put(a, "$form", .{ .string = "scene" });
    try obj.put(a, "bpm", .{ .integer = 130 });
    const v: std.json.Value = .{ .object = obj };

    var tree = try fromJson(testing.allocator, v, .{});
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    const f = tree.formHeader(tree.root[0]);
    try testing.expectEqualStrings("scene", f.head);
    try testing.expectEqual(@as(usize, 1), f.children.len);
    const kp = tree.kvpairHeader(f.children[0]);
    try testing.expectEqualStrings("bpm", kp.key);
    try testing.expectEqual(@as(f64, 130), tree.numberOf(kp.value));
}

test "decode: $expr round-trips to a positional form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var args = std.json.Array.init(a);
    try args.append(.{ .string = "+" });
    try args.append(.{ .integer = 1 });
    try args.append(.{ .integer = 2 });

    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$expr", .{ .array = args });

    var tree = try fromJson(testing.allocator, .{ .object = obj }, .{});
    defer tree.deinit();
    const f = tree.formHeader(tree.root[0]);
    try testing.expectEqualStrings("+", f.head);
    try testing.expectEqual(@as(usize, 2), f.children.len);
    try testing.expectEqual(@as(f64, 1), tree.numberOf(f.children[0]));
}

test "expression form encodes namespace as $ns alongside $expr" {
    // Schema-aware encode: a qualified expr-func should round-trip with
    // both `$expr` (the positional shorthand) and `$ns` (the namespace
    // tag). The schema-less / form-shape path is covered by
    // "form encodes namespace as $ns" above.
    const ns_plugin: Plugin.Plugin = .{
        .name = "myns",
        .expr_funcs = &[_]Plugin.ExprFunc{.{ .name = "foo", .arity = .{ .at_least = 0 } }},
    };
    const tree = try parseToTree("(myns/foo 1 2)");
    defer {
        var t = tree;
        t.deinit();
    }
    const schema = Schema.Schema.init(&.{ns_plugin});
    var r = try toJson(testing.allocator, tree, .{ .schema = schema });
    defer r.deinit();
    const expr = r.value.object.get("$expr") orelse unreachable;
    try testing.expectEqual(@as(usize, 3), expr.array.items.len);
    try testing.expectEqualStrings("foo", expr.array.items[0].string);
    try testing.expectEqualStrings("myns", r.value.object.get("$ns").?.string);
}

test "decode: $expr with $ns produces a qualified form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var args = std.json.Array.init(a);
    try args.append(.{ .string = "foo" });
    try args.append(.{ .integer = 1 });

    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$expr", .{ .array = args });
    try obj.put(a, "$ns", .{ .string = "myns" });

    var tree = try fromJson(testing.allocator, .{ .object = obj }, .{});
    defer tree.deinit();
    const f = tree.formHeader(tree.root[0]);
    try testing.expectEqualStrings("foo", f.head);
    try testing.expectEqualStrings("myns", f.namespace.?);
    try testing.expectEqual(@as(usize, 1), f.children.len);
}

test "decode: $expr with non-string $ns is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var args = std.json.Array.init(a);
    try args.append(.{ .string = "foo" });

    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$expr", .{ .array = args });
    try obj.put(a, "$ns", .{ .integer = 42 });

    try testing.expectError(error.InvalidEncoding, fromJson(testing.allocator, .{ .object = obj }, .{}));
}

test "round-trip: $expr + $ns through toJson and fromJson" {
    // End-to-end fidelity: a qualified expr-func encoded with schema
    // present should decode back to a form with the original namespace.
    const ns_plugin: Plugin.Plugin = .{
        .name = "myns",
        .expr_funcs = &[_]Plugin.ExprFunc{.{ .name = "foo", .arity = .{ .at_least = 0 } }},
    };
    const tree = try parseToTree("(myns/foo 1 2)");
    defer {
        var t = tree;
        t.deinit();
    }
    const schema = Schema.Schema.init(&.{ns_plugin});
    var encoded = try toJson(testing.allocator, tree, .{ .schema = schema });
    defer encoded.deinit();

    var rt = try fromJson(testing.allocator, encoded.value, .{});
    defer rt.deinit();
    const f = rt.formHeader(rt.root[0]);
    try testing.expectEqualStrings("foo", f.head);
    try testing.expectEqualStrings("myns", f.namespace.?);
    try testing.expectEqual(@as(usize, 2), f.children.len);
}

test "round-trip: parse → toJson → fromJson → print" {
    const src =
        \\(scene :bpm 130 (canvas :name "main" [1 2 3]))
    ;
    const tree = try parseToTree(src);
    defer {
        var t = tree;
        t.deinit();
    }

    var json_result = try toJson(testing.allocator, tree, .{});
    defer json_result.deinit();

    var rebuilt = try fromJson(testing.allocator, json_result.value, .{});
    defer rebuilt.deinit();

    const printed = try Printer.print(testing.allocator, rebuilt, .{});
    defer printed.deinit();

    // Reconstructed text should parse cleanly and reach an equivalent tree.
    const printed_z = try testing.allocator.dupeZ(u8, printed.data);
    defer testing.allocator.free(printed_z);
    var reparsed = try Parser.parse(testing.allocator, printed_z);
    defer reparsed.deinit();
    try testing.expect(!reparsed.hasErrors());

    const f = reparsed.formHeader(reparsed.root[0]);
    try testing.expectEqualStrings("scene", f.head);
}

test "multi-root tree refuses to_json" {
    const tree = try parseToTree("1 2 3");
    defer {
        var t = tree;
        t.deinit();
    }
    try testing.expectError(error.MultipleRoots, toJson(testing.allocator, tree, .{}));
}

test "keyword $kw round-trips through fromJson" {
    var obj: std.json.ObjectMap = .empty;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try obj.put(a, "$kw", .{ .string = "hello" });

    var tree = try fromJson(testing.allocator, .{ .object = obj }, .{});
    defer tree.deinit();
    try testing.expectEqual(.keyword, tree.tagOf(tree.root[0]));
    const si: Ast.StringIndex = @enumFromInt(tree.dataOf(tree.root[0]).single);
    try testing.expectEqualStrings("hello", tree.stringSlice(si));
}

// ---------------------------------------------------------------------------
// Phase C5 — regression tests pinning the contract bugs that motivated the
// JSON-bridge redesign.
// ---------------------------------------------------------------------------

test "round-trip preserves symbols (canonical mode)" {
    const tree = try parseToTree("(let [r 0.5] (vec3 r r r))");
    defer {
        var t = tree;
        t.deinit();
    }

    var json_result = try toJson(testing.allocator, tree, .{});
    defer json_result.deinit();
    var rebuilt = try fromJson(testing.allocator, json_result.value, .{});
    defer rebuilt.deinit();

    const a_print = try Printer.print(testing.allocator, tree, .{});
    defer a_print.deinit();
    const b_print = try Printer.print(testing.allocator, rebuilt, .{});
    defer b_print.deinit();
    try testing.expectEqualStrings(a_print.data, b_print.data);
}

test "round-trip preserves reserved-prefix keyword keys" {
    const tree = try parseToTree("(thing :$form \"x\" :$kw \"y\")");
    defer {
        var t = tree;
        t.deinit();
    }

    var json_result = try toJson(testing.allocator, tree, .{});
    defer json_result.deinit();
    var rebuilt = try fromJson(testing.allocator, json_result.value, .{});
    defer rebuilt.deinit();

    const f = rebuilt.formHeader(rebuilt.root[0]);
    try testing.expectEqualStrings("thing", f.head);
    try testing.expectEqual(@as(usize, 2), f.children.len);

    var saw_form_kw = false;
    var saw_kw_kw = false;
    for (f.children) |child_idx| {
        if (rebuilt.tagOf(child_idx) != .kvpair) continue;
        const kp = rebuilt.kvpairHeader(child_idx);
        if (std.mem.eql(u8, kp.key, "$form")) saw_form_kw = true;
        if (std.mem.eql(u8, kp.key, "$kw")) saw_kw_kw = true;
    }
    try testing.expect(saw_form_kw);
    try testing.expect(saw_kw_kw);
}

test "round-trip preserves reserved-prefix form head" {
    const tree = try parseToTree("($form a b)");
    defer {
        var t = tree;
        t.deinit();
    }

    var json_result = try toJson(testing.allocator, tree, .{});
    defer json_result.deinit();
    var rebuilt = try fromJson(testing.allocator, json_result.value, .{});
    defer rebuilt.deinit();

    try testing.expectEqualStrings("$form", rebuilt.formHeader(rebuilt.root[0]).head);
}

test "decode rejects unknown discriminators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$weird", .{ .integer = 1 });

    try testing.expectError(
        error.UnknownDiscriminator,
        fromJson(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "unit-suffixed number encodes as $num and round-trips" {
    const tree = try parseToTree("90deg");
    defer {
        var t = tree;
        t.deinit();
    }

    // Encode → expect canonical {"$num": [90, "deg"]}.
    var json_result = try toJson(testing.allocator, tree, .{});
    defer json_result.deinit();

    const obj = switch (json_result.value) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    const num_v = obj.get("$num") orelse return error.TestMissingDiscriminator;
    const items = switch (num_v) {
        .array => |arr| arr.items,
        else => return error.TestExpectedArray,
    };
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqual(@as(i64, 90), items[0].integer);
    try testing.expectEqualStrings("deg", items[1].string);

    // Decode round-trip → canonical print equals original.
    var rebuilt = try fromJson(testing.allocator, json_result.value, .{});
    defer rebuilt.deinit();
    const printed = try Printer.print(testing.allocator, rebuilt, .{});
    defer printed.deinit();
    try testing.expectEqualStrings("90deg\n", printed.data);
}

test "lossy mode drops the unit" {
    const tree = try parseToTree("90deg");
    defer {
        var t = tree;
        t.deinit();
    }

    var json_result = try toJson(testing.allocator, tree, .{ .mode = .compact });
    defer json_result.deinit();

    // Lossy emits a bare JSON integer.
    try testing.expectEqual(@as(i64, 90), json_result.value.integer);
}

test "decode rejects malformed $num shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Wrong array length.
    {
        var arr = std.json.Array.init(a);
        try arr.append(.{ .integer = 4 });
        var obj: std.json.ObjectMap = .empty;
        try obj.put(a, "$num", .{ .array = arr });
        try testing.expectError(
            error.InvalidEncoding,
            fromJson(testing.allocator, .{ .object = obj }, .{}),
        );
    }
    // String payload (not array).
    {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(a, "$num", .{ .string = "4b" });
        try testing.expectError(
            error.InvalidEncoding,
            fromJson(testing.allocator, .{ .object = obj }, .{}),
        );
    }
    // Object payload (not array).
    {
        var inner: std.json.ObjectMap = .empty;
        try inner.put(a, "value", .{ .integer = 4 });
        try inner.put(a, "unit", .{ .string = "b" });
        var obj: std.json.ObjectMap = .empty;
        try obj.put(a, "$num", .{ .object = inner });
        try testing.expectError(
            error.InvalidEncoding,
            fromJson(testing.allocator, .{ .object = obj }, .{}),
        );
    }
    // Empty unit.
    {
        var arr = std.json.Array.init(a);
        try arr.append(.{ .integer = 4 });
        try arr.append(.{ .string = "" });
        var obj: std.json.ObjectMap = .empty;
        try obj.put(a, "$num", .{ .array = arr });
        try testing.expectError(
            error.InvalidEncoding,
            fromJson(testing.allocator, .{ .object = obj }, .{}),
        );
    }
}

test "user key literally named $num round-trips via $$num" {
    const tree = try parseToTree("(thing :$num \"x\")");
    defer {
        var t = tree;
        t.deinit();
    }

    var json_result = try toJson(testing.allocator, tree, .{});
    defer json_result.deinit();

    var rebuilt = try fromJson(testing.allocator, json_result.value, .{});
    defer rebuilt.deinit();

    const printed = try Printer.print(testing.allocator, rebuilt, .{});
    defer printed.deinit();
    try testing.expectEqualStrings("(thing :$num \"x\")\n", printed.data);
}

test "$num: 3-element array is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var arr = std.json.Array.init(a);
    try arr.append(.{ .integer = 4 });
    try arr.append(.{ .string = "b" });
    try arr.append(.{ .integer = 0 });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$num", .{ .array = arr });
    try testing.expectError(
        error.InvalidEncoding,
        fromJson(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "$num: non-string at index 1 is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var arr = std.json.Array.init(a);
    try arr.append(.{ .integer = 4 });
    try arr.append(.{ .integer = 99 });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$num", .{ .array = arr });
    try testing.expectError(
        error.InvalidEncoding,
        fromJson(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "$num: non-number at index 0 is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var arr = std.json.Array.init(a);
    try arr.append(.{ .string = "four" });
    try arr.append(.{ .string = "b" });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$num", .{ .array = arr });
    try testing.expectError(
        error.InvalidEncoding,
        fromJson(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "$num canonical: float value preserved as JSON float" {
    const tree = try parseToTree("0.5em");
    defer {
        var t = tree;
        t.deinit();
    }
    var json_result = try toJson(testing.allocator, tree, .{});
    defer json_result.deinit();
    const obj = json_result.value.object;
    const items = obj.get("$num").?.array.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqual(@as(f64, 0.5), items[0].float);
    try testing.expectEqualStrings("em", items[1].string);
}

test "$num canonical: negative integer value emitted as JSON integer" {
    const tree = try parseToTree("-50%");
    defer {
        var t = tree;
        t.deinit();
    }
    var json_result = try toJson(testing.allocator, tree, .{});
    defer json_result.deinit();
    const obj = json_result.value.object;
    const items = obj.get("$num").?.array.items;
    try testing.expectEqual(@as(i64, -50), items[0].integer);
    try testing.expectEqualStrings("%", items[1].string);
}

test "$num decodes both integer and float at index 0" {
    // Both integer and float JSON values must be accepted at slot 0.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        var arr = std.json.Array.init(a);
        try arr.append(.{ .integer = 90 });
        try arr.append(.{ .string = "deg" });
        var obj: std.json.ObjectMap = .empty;
        try obj.put(a, "$num", .{ .array = arr });
        var rebuilt = try fromJson(testing.allocator, .{ .object = obj }, .{});
        defer rebuilt.deinit();
        const nwu = rebuilt.numberWithUnitOf(rebuilt.root[0]);
        try testing.expectEqual(@as(f64, 90), nwu.value);
        try testing.expectEqualStrings("deg", nwu.unit);
    }
    {
        var arr = std.json.Array.init(a);
        try arr.append(.{ .float = 0.5 });
        try arr.append(.{ .string = "em" });
        var obj: std.json.ObjectMap = .empty;
        try obj.put(a, "$num", .{ .array = arr });
        var rebuilt = try fromJson(testing.allocator, .{ .object = obj }, .{});
        defer rebuilt.deinit();
        const nwu = rebuilt.numberWithUnitOf(rebuilt.root[0]);
        try testing.expectEqual(@as(f64, 0.5), nwu.value);
        try testing.expectEqualStrings("em", nwu.unit);
    }
}

test "$num inside a form's KP value round-trips" {
    const tree = try parseToTree("(scene :angle 90deg :delay 250ms)");
    defer {
        var t = tree;
        t.deinit();
    }
    var json_result = try toJson(testing.allocator, tree, .{});
    defer json_result.deinit();
    var rebuilt = try fromJson(testing.allocator, json_result.value, .{});
    defer rebuilt.deinit();
    const printed = try Printer.print(testing.allocator, rebuilt, .{});
    defer printed.deinit();
    try testing.expectEqualStrings(
        "(scene :angle 90deg :delay 250ms)\n",
        printed.data,
    );
}

test "$num inside vector round-trips" {
    const tree = try parseToTree("[4b 90deg 50% 250ms]");
    defer {
        var t = tree;
        t.deinit();
    }
    var json_result = try toJson(testing.allocator, tree, .{});
    defer json_result.deinit();
    var rebuilt = try fromJson(testing.allocator, json_result.value, .{});
    defer rebuilt.deinit();
    const printed = try Printer.print(testing.allocator, rebuilt, .{});
    defer printed.deinit();
    try testing.expectEqualStrings("[4b 90deg 50% 250ms]\n", printed.data);
}

test "$num: empty array payload is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const arr = std.json.Array.init(a);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$num", .{ .array = arr });
    try testing.expectError(
        error.InvalidEncoding,
        fromJson(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "lossy round-trip drops unit and bridges via bare JSON number" {
    // Lossy → bare number → fromJson(...) — produces a unitless tree.
    const tree = try parseToTree("90deg");
    defer {
        var t = tree;
        t.deinit();
    }
    var json_result = try toJson(testing.allocator, tree, .{ .mode = .compact });
    defer json_result.deinit();
    var rebuilt = try fromJson(testing.allocator, json_result.value, .{});
    defer rebuilt.deinit();
    // The unit is dropped in compact mode, leaving a bare integer
    // JSON number → the inverse path lands on `.number_i64`.
    try testing.expectEqual(.number_i64, rebuilt.tagOf(rebuilt.root[0]));
    try testing.expectEqual(@as(i64, 90), rebuilt.numberI64Of(rebuilt.root[0]));
}

test "comments are dropped on JSON round-trip" {
    var tree_soa = try parseToTree("; doc\n42");
    defer tree_soa.deinit();
    try testing.expect(!tree_soa.leading_comments_index[tree_soa.root[0].raw()].isEmpty());

    var json_result = try toJson(testing.allocator, tree_soa, .{});
    defer json_result.deinit();
    var rebuilt = try fromJson(testing.allocator, json_result.value, .{});
    defer rebuilt.deinit();

    try testing.expect(rebuilt.leading_comments_index[rebuilt.root[0].raw()].isEmpty());
    const printed = try Printer.print(testing.allocator, rebuilt, .{});
    defer printed.deinit();
    try testing.expectEqualStrings("42\n", printed.data);
}

test "multi-root via toJsonRoots / fromJsonRoots" {
    const tree = try parseToTree("1 2 3");
    defer {
        var t = tree;
        t.deinit();
    }

    var json_result = try toJsonRoots(testing.allocator, tree, .{});
    defer json_result.deinit();
    var rebuilt = try fromJsonRoots(testing.allocator, json_result.value, .{});
    defer rebuilt.deinit();

    try testing.expectEqual(@as(usize, 3), rebuilt.root.len);
    try testing.expectEqual(@as(f64, 1), rebuilt.numberOf(rebuilt.root[0]));
    try testing.expectEqual(@as(f64, 2), rebuilt.numberOf(rebuilt.root[1]));
    try testing.expectEqual(@as(f64, 3), rebuilt.numberOf(rebuilt.root[2]));
}

test "tree-level fromJson rejects $roots wrapper" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var arr = std.json.Array.init(a);
    try arr.append(.{ .integer = 1 });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$roots", .{ .array = arr });

    try testing.expectError(
        error.MultipleRoots,
        fromJson(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "Tree: parse → toJson → fromJson → print round-trip" {
    const src = "(scene :bpm 130 (canvas :name \"main\" [1 2 3]))";

    var tree2 = try Parser.parse(testing.allocator, src);
    defer tree2.deinit();
    var json_result = try toJson(testing.allocator, tree2, .{});
    defer json_result.deinit();

    var rebuilt2 = try fromJson(testing.allocator, json_result.value, .{});
    defer rebuilt2.deinit();
    const printed = try Printer.print(testing.allocator, rebuilt2, .{});
    defer printed.deinit();

    const printed_z = try testing.allocator.dupeZ(u8, printed.data);
    defer testing.allocator.free(printed_z);
    var reparsed = try Parser.parse(testing.allocator, printed_z);
    defer reparsed.deinit();
    try testing.expect(!reparsed.hasErrors());

    const reparse_root = reparsed.root[0];
    try testing.expectEqual(Ast.Tag.form, reparsed.tagOf(reparse_root));
    const hdr = reparsed.formHeader(reparse_root);
    try testing.expectEqualStrings("scene", hdr.head);
}

test "Tree: toJsonRoots / fromJsonRoots round-trip multi-root" {
    var tree2 = try Parser.parse(testing.allocator, "1 2 3");
    defer tree2.deinit();
    var json_result = try toJsonRoots(testing.allocator, tree2, .{});
    defer json_result.deinit();
    var rebuilt2 = try fromJsonRoots(testing.allocator, json_result.value, .{});
    defer rebuilt2.deinit();

    try testing.expectEqual(@as(usize, 3), rebuilt2.root.len);
    try testing.expectEqual(@as(f64, 1), rebuilt2.numberOf(rebuilt2.root[0]));
    try testing.expectEqual(@as(f64, 2), rebuilt2.numberOf(rebuilt2.root[1]));
    try testing.expectEqual(@as(f64, 3), rebuilt2.numberOf(rebuilt2.root[2]));
}

test "fixtures/json_roundtrip.sjon — every top-level form round-trips canonically" {
    const a = testing.allocator;

    const io = std.testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "fixtures/json_roundtrip.sjon", a, .unlimited);
    defer a.free(bytes);
    const src = try a.allocSentinel(u8, bytes.len, 0);
    defer a.free(src);
    @memcpy(src, bytes);

    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    try testing.expect(tree.root.len > 0);

    for (tree.root, 0..) |idx, i| {
        // Build a single-root sub-tree by cloning this root into a fresh
        // builder. Lets us run toJson (which requires single-root) and
        // print in isolation.
        var sub_soa = try cloneSingleRoot(a, &tree, idx);
        defer sub_soa.deinit();

        var json_result = try toJson(a, sub_soa, .{});
        defer json_result.deinit();
        var rebuilt = try fromJson(a, json_result.value, .{});
        defer rebuilt.deinit();

        const a_print = try Printer.print(a, sub_soa, .{});
        defer a_print.deinit();
        const b_print = try Printer.print(a, rebuilt, .{});
        defer b_print.deinit();

        testing.expectEqualStrings(a_print.data, b_print.data) catch |err| {
            std.debug.print("\nfixture #{d} round-trip mismatch:\n  before: {s}\n  after:  {s}\n", .{ i, a_print.data, b_print.data });
            return err;
        };
    }
}

// ---------------------------------------------------------------------------
// Long-tail JSON tests — atoms, special $-shapes, nested round-trips, and
// multi-root edge cases. Pinned alongside the per-bug fixtures above.
// ---------------------------------------------------------------------------

test "encode: every atom type has a stable JSON shape" {
    inline for (.{
        .{ "nil", "null" },
        .{ "true", "true" },
        .{ "false", "false" },
        .{ "0", "integer:0" },
        .{ "-1", "integer:-1" },
        .{ "3.14", "float:3.14" },
        .{ "\"\"", "string:" },
    }) |c| {
        const tree = try parseToTree(c[0]);
        defer {
            var t = tree;
            t.deinit();
        }
        var r = try toJson(testing.allocator, tree, .{});
        defer r.deinit();
        // Pin the kind only — exact bytes are checked by other tests.
        const tag = c[1];
        if (std.mem.startsWith(u8, tag, "null")) try testing.expect(r.value == .null);
        if (std.mem.startsWith(u8, tag, "true")) try testing.expect(r.value.bool == true);
        if (std.mem.startsWith(u8, tag, "false")) try testing.expect(r.value.bool == false);
        if (std.mem.startsWith(u8, tag, "integer:")) try testing.expect(r.value == .integer);
        if (std.mem.startsWith(u8, tag, "float:")) try testing.expect(r.value == .float);
        if (std.mem.startsWith(u8, tag, "string:")) try testing.expect(r.value == .string);
    }
}

test "encode: very large integer-valued number stays integer (within safe_int_max)" {
    // 2^53 - 1 is the largest f64-representable integer; numberToJson
    // must still emit it as a JSON integer.
    const tree = try parseToTree("9007199254740991");
    defer {
        var t = tree;
        t.deinit();
    }
    var r = try toJson(testing.allocator, tree, .{});
    defer r.deinit();
    try testing.expectEqual(@as(i64, 9007199254740991), r.value.integer);
}

test "encode: integer above safe_int_max emits exactly via number_i64" {
    // 2^54 = 18014398509481984. The legacy f64 path would fall back to
    // `.float` past safe_int_max, but the parser now lands a pure-int
    // literal in `.number_i64` and JSON emits it as exact `.integer`.
    const tree = try parseToTree("18014398509481984");
    defer {
        var t = tree;
        t.deinit();
    }
    var r = try toJson(testing.allocator, tree, .{});
    defer r.deinit();
    try testing.expectEqual(@as(i64, 18014398509481984), r.value.integer);
}

test "encode: i64.min emits exact integer (number_i64 path)" {
    const tree = try parseToTree("-9223372036854775808");
    defer {
        var t = tree;
        t.deinit();
    }
    try testing.expectEqual(.number_i64, tree.tagOf(tree.root[0]));
    var r = try toJson(testing.allocator, tree, .{});
    defer r.deinit();
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), r.value.integer);
}

test "encode: i64.max emits exact integer (number_i64 path)" {
    const tree = try parseToTree("9223372036854775807");
    defer {
        var t = tree;
        t.deinit();
    }
    try testing.expectEqual(.number_i64, tree.tagOf(tree.root[0]));
    var r = try toJson(testing.allocator, tree, .{});
    defer r.deinit();
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), r.value.integer);
}

test "encode: u64.max emits as number_string (above i64 range)" {
    // 18446744073709551615 = 2^64 - 1. Doesn't fit in std.json's i64
    // `.integer`, so JSON output uses `.number_string` carrying the
    // literal digits — RFC 8259 admits arbitrary-precision numbers and
    // std.json round-trips that variant byte-for-byte.
    const tree = try parseToTree("18446744073709551615");
    defer {
        var t = tree;
        t.deinit();
    }
    try testing.expectEqual(.number_u64, tree.tagOf(tree.root[0]));
    var r = try toJson(testing.allocator, tree, .{});
    defer r.deinit();
    try testing.expectEqualStrings("18446744073709551615", r.value.number_string);
}

test "encode: u64 just above i64.max emits as number_string" {
    // 2^63 = i64.max + 1 — the threshold where number_u64 stops fitting
    // into std.json's i64 integer variant.
    const tree = try parseToTree("9223372036854775808");
    defer {
        var t = tree;
        t.deinit();
    }
    try testing.expectEqual(.number_u64, tree.tagOf(tree.root[0]));
    var r = try toJson(testing.allocator, tree, .{});
    defer r.deinit();
    try testing.expectEqualStrings("9223372036854775808", r.value.number_string);
}

test "decode: number_string with u64.max round-trips into number_u64" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const num_str = try a.dupe(u8, "18446744073709551615");
    var tree = try fromJson(testing.allocator, .{ .number_string = num_str }, .{});
    defer tree.deinit();
    try testing.expectEqual(.number_u64, tree.tagOf(tree.root[0]));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), tree.numberU64Of(tree.root[0]));
}

test "decode: JSON integer becomes number_i64" {
    var tree = try fromJson(testing.allocator, .{ .integer = -42 }, .{});
    defer tree.deinit();
    try testing.expectEqual(.number_i64, tree.tagOf(tree.root[0]));
    try testing.expectEqual(@as(i64, -42), tree.numberI64Of(tree.root[0]));
}

test "round-trip: u64.max preserves exactly through parse → toJson → fromJson" {
    const src = "18446744073709551615";
    const tree = try parseToTree(src);
    defer {
        var t = tree;
        t.deinit();
    }
    var encoded = try toJson(testing.allocator, tree, .{});
    defer encoded.deinit();
    var rebuilt = try fromJson(testing.allocator, encoded.value, .{});
    defer rebuilt.deinit();
    try testing.expectEqual(.number_u64, rebuilt.tagOf(rebuilt.root[0]));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), rebuilt.numberU64Of(rebuilt.root[0]));
}

test "round-trip: i64.min preserves exactly through parse → toJson → fromJson" {
    const src = "-9223372036854775808";
    const tree = try parseToTree(src);
    defer {
        var t = tree;
        t.deinit();
    }
    var encoded = try toJson(testing.allocator, tree, .{});
    defer encoded.deinit();
    var rebuilt = try fromJson(testing.allocator, encoded.value, .{});
    defer rebuilt.deinit();
    try testing.expectEqual(.number_i64, rebuilt.tagOf(rebuilt.root[0]));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), rebuilt.numberI64Of(rebuilt.root[0]));
}

test "encode: negative zero round-trips as 0" {
    // -0.0 and 0 differ in IEEE-754 bit pattern but JSON has no separate
    // representation. Pin: emitted as integer 0.
    const tree = try parseToTree("-0");
    defer {
        var t = tree;
        t.deinit();
    }
    var r = try toJson(testing.allocator, tree, .{});
    defer r.deinit();
    try testing.expectEqual(@as(i64, 0), r.value.integer);
}

test "decode: number_string variant accepted" {
    // std.json may emit `.number_string` for numbers it didn't fold;
    // the decoder must call parseFloat and produce a Tree number node.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const num_str = try a.dupe(u8, "42.5");
    var tree = try fromJson(testing.allocator, .{ .number_string = num_str }, .{});
    defer tree.deinit();
    try testing.expectEqual(.number, tree.tagOf(tree.root[0]));
    try testing.expectEqual(@as(f64, 42.5), tree.numberOf(tree.root[0]));
}

test "decode: malformed number_string surfaces InvalidEncoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad_num = try a.dupe(u8, "not-a-number");
    try testing.expectError(
        error.InvalidEncoding,
        fromJson(testing.allocator, .{ .number_string = bad_num }, .{}),
    );
}

test "encode then decode: nested form within form preserves shape" {
    const src = "(outer :k (inner :x 1 (deep :y 2)))";
    const tree = try parseToTree(src);
    defer {
        var t = tree;
        t.deinit();
    }
    var r = try toJson(testing.allocator, tree, .{});
    defer r.deinit();
    var rebuilt = try fromJson(testing.allocator, r.value, .{});
    defer rebuilt.deinit();
    const printed = try Printer.print(testing.allocator, rebuilt, .{});
    defer printed.deinit();
    try testing.expectEqualStrings("(outer :k (inner :x 1 (deep :y 2)))\n", printed.data);
}

test "encode: empty form produces $form with no $children key" {
    const tree = try parseToTree("(empty-form)");
    defer {
        var t = tree;
        t.deinit();
    }
    var r = try toJson(testing.allocator, tree, .{});
    defer r.deinit();
    const obj = r.value.object;
    try testing.expectEqualStrings("empty-form", obj.get("$form").?.string);
    try testing.expect(obj.get("$children") == null);
}

test "encode: form with only positional children includes $children array" {
    const tree = try parseToTree("(stack 1 2 3)");
    defer {
        var t = tree;
        t.deinit();
    }
    var r = try toJson(testing.allocator, tree, .{});
    defer r.deinit();
    const obj = r.value.object;
    const children = obj.get("$children").?.array.items;
    try testing.expectEqual(@as(usize, 3), children.len);
    try testing.expectEqual(@as(i64, 1), children[0].integer);
    try testing.expectEqual(@as(i64, 3), children[2].integer);
}

test "$expr: empty array payload raises InvalidExprForm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const arr = std.json.Array.init(a);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$expr", .{ .array = arr });
    try testing.expectError(
        error.InvalidExprForm,
        fromJson(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "$expr: non-string head raises InvalidExprForm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var arr = std.json.Array.init(a);
    try arr.append(.{ .integer = 99 });
    try arr.append(.{ .integer = 1 });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$expr", .{ .array = arr });
    try testing.expectError(
        error.InvalidExprForm,
        fromJson(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "$expr: unknown sibling key raises UnknownDiscriminator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var arr = std.json.Array.init(a);
    try arr.append(.{ .string = "+" });
    try arr.append(.{ .integer = 1 });
    try arr.append(.{ .integer = 2 });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$expr", .{ .array = arr });
    try obj.put(a, "extra", .{ .integer = 1 });
    try testing.expectError(
        error.UnknownDiscriminator,
        fromJson(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "$expr: $-prefixed unknown sibling raises UnknownDiscriminator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var arr = std.json.Array.init(a);
    try arr.append(.{ .string = "+" });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$expr", .{ .array = arr });
    try obj.put(a, "$foo", .{ .integer = 1 });
    try testing.expectError(
        error.UnknownDiscriminator,
        fromJson(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "$expr: empty $ns raises InvalidEncoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var arr = std.json.Array.init(a);
    try arr.append(.{ .string = "foo" });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$expr", .{ .array = arr });
    try obj.put(a, "$ns", .{ .string = "" });
    try testing.expectError(
        error.InvalidEncoding,
        fromJson(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "$expr: $ns containing slash raises InvalidEncoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var arr = std.json.Array.init(a);
    try arr.append(.{ .string = "foo" });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$expr", .{ .array = arr });
    try obj.put(a, "$ns", .{ .string = "a/b" });
    try testing.expectError(
        error.InvalidEncoding,
        fromJson(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "$form: non-string head raises InvalidFormHead" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$form", .{ .integer = 99 });
    try testing.expectError(
        error.InvalidFormHead,
        fromJson(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "$ns: non-string namespace raises InvalidEncoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$form", .{ .string = "head" });
    try obj.put(a, "$ns", .{ .integer = 1 });
    try testing.expectError(
        error.InvalidEncoding,
        fromJson(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "$kw: non-string payload raises InvalidEncoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$kw", .{ .integer = 1 });
    try testing.expectError(
        error.InvalidEncoding,
        fromJson(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "$sym: non-string payload raises InvalidEncoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$sym", .{ .integer = 1 });
    try testing.expectError(
        error.InvalidEncoding,
        fromJson(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "$date: non-string payload raises InvalidEncoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$date", .{ .integer = 1 });
    try testing.expectError(
        error.InvalidEncoding,
        fromJson(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "$time: non-string payload raises InvalidEncoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$time", .{ .integer = 1 });
    try testing.expectError(
        error.InvalidEncoding,
        fromJson(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "decode: empty object surfaces InvalidEncoding (no recognised keys)" {
    const obj: std.json.ObjectMap = .empty;
    try testing.expectError(
        error.InvalidEncoding,
        fromJson(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "fromJsonRoots: empty wrapper produces empty multi-root tree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const arr = std.json.Array.init(a);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$roots", .{ .array = arr });
    var tree = try fromJsonRoots(testing.allocator, .{ .object = obj }, .{});
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 0), tree.root.len);
}

test "fromJsonRoots: missing $roots key raises InvalidEncoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "other", .{ .integer = 1 });
    try testing.expectError(
        error.InvalidEncoding,
        fromJsonRoots(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "fromJsonRoots: $roots non-array raises InvalidEncoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$roots", .{ .integer = 1 });
    try testing.expectError(
        error.InvalidEncoding,
        fromJsonRoots(testing.allocator, .{ .object = obj }, .{}),
    );
}

test "fromJsonRoots: non-object input raises InvalidEncoding" {
    try testing.expectError(
        error.InvalidEncoding,
        fromJsonRoots(testing.allocator, .{ .integer = 5 }, .{}),
    );
}

test "compact mode: keyword and symbol both flatten to bare strings" {
    const tree = try parseToTree("(thing :a :b sym)");
    defer {
        var t = tree;
        t.deinit();
    }
    var r = try toJson(testing.allocator, tree, .{ .mode = .compact });
    defer r.deinit();
    // Children include the flag keyword `:a` (positional flag) and the
    // symbol `sym` — both must be plain strings in compact mode, not
    // objects.
    const children = r.value.object.get("$children").?.array.items;
    try testing.expect(children[0] == .string);
    // Last positional should be the symbol.
    try testing.expect(children[children.len - 1] == .string);
}

test "round-trip preserves vector-of-vector structure" {
    const tree = try parseToTree("[[1 2] [3 4] [5 6]]");
    defer {
        var t = tree;
        t.deinit();
    }
    var r = try toJson(testing.allocator, tree, .{});
    defer r.deinit();
    var rebuilt = try fromJson(testing.allocator, r.value, .{});
    defer rebuilt.deinit();
    const printed = try Printer.print(testing.allocator, rebuilt, .{});
    defer printed.deinit();
    try testing.expectEqualStrings("[[1 2] [3 4] [5 6]]\n", printed.data);
}

test "encode then decode preserves boolean inside a vector" {
    const tree = try parseToTree("[true false true]");
    defer {
        var t = tree;
        t.deinit();
    }
    var r = try toJson(testing.allocator, tree, .{});
    defer r.deinit();
    var rebuilt = try fromJson(testing.allocator, r.value, .{});
    defer rebuilt.deinit();
    const elements = rebuilt.vectorElements(rebuilt.root[0]);
    try testing.expectEqual(@as(usize, 3), elements.len);
    try testing.expectEqual(.boolean_true, rebuilt.tagOf(elements[0]));
    try testing.expectEqual(.boolean_false, rebuilt.tagOf(elements[1]));
    try testing.expectEqual(.boolean_true, rebuilt.tagOf(elements[2]));
}

test "decode: $expr with single element (head only, no args)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var arr = std.json.Array.init(a);
    try arr.append(.{ .string = "noop" });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$expr", .{ .array = arr });
    var tree = try fromJson(testing.allocator, .{ .object = obj }, .{});
    defer tree.deinit();
    try testing.expectEqualStrings("noop", tree.formHeader(tree.root[0]).head);
    try testing.expectEqual(@as(usize, 0), tree.formHeader(tree.root[0]).children.len);
}

fn cloneSingleRoot(gpa: Allocator, src: *const Ast.Tree, idx: Ast.NodeIndex) Allocator.Error!Ast.Tree {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var b: Ast.TreeBuilder = .{ .a = a };
    const root_idx = try b.cloneNode(src, idx);
    const root_indices = try a.alloc(Ast.NodeIndex, 1);
    root_indices[0] = root_idx;

    if (b.string_index.items.len == 0) try b.string_index.append(a, 0);

    return Ast.Tree{
        .arena = arena,
        .source = src.source,
        .nodes = b.nodes.toOwnedSlice(),
        .extra_data = b.extra_data.items,
        .strings = b.strings.items,
        .string_index = b.string_index.items,
        .root = root_indices,
        .leading_comments_index = b.leading_index.items,
        .trailing_comments_index = b.trailing_index.items,
        .comments = b.comments.toOwnedSlice(),
        .tree_trailing_comments = .empty,
        .diagnostics = &.{},
    };
}

// ---------------------------------------------------------------------------
// Clock-time tagged-object encoding
// ---------------------------------------------------------------------------

test "time canonical mode wraps in $time (no fractional)" {
    const tree = try parseToTree("12:34:56");
    defer {
        var t = tree;
        t.deinit();
    }
    var r = try toJson(testing.allocator, tree, .{});
    defer r.deinit();
    const obj = r.value.object;
    const time_v = obj.get("$time") orelse unreachable;
    try testing.expectEqualStrings("12:34:56", time_v.string);
}

test "time canonical mode wraps in $time (with fractional)" {
    const tree = try parseToTree("12:34:56.789");
    defer {
        var t = tree;
        t.deinit();
    }
    var r = try toJson(testing.allocator, tree, .{});
    defer r.deinit();
    const obj = r.value.object;
    const time_v = obj.get("$time") orelse unreachable;
    try testing.expectEqualStrings("12:34:56.789", time_v.string);
}

test "time canonical: ms-zero round-trips to 8-char form" {
    // 12:34:56.000 must canonicalise to 12:34:56 — preserves the byte-
    // for-byte round-trip rule shared with the Printer.
    const tree = try parseToTree("12:34:56.000");
    defer {
        var t = tree;
        t.deinit();
    }
    var r = try toJson(testing.allocator, tree, .{});
    defer r.deinit();
    try testing.expectEqualStrings("12:34:56", r.value.object.get("$time").?.string);
}

test "time lossy mode flattens to bare string" {
    const tree = try parseToTree("12:34:56.789");
    defer {
        var t = tree;
        t.deinit();
    }
    var r = try toJson(testing.allocator, tree, .{ .mode = .compact });
    defer r.deinit();
    try testing.expectEqualStrings("12:34:56.789", r.value.string);
}

test "decode: $time produces a Tag.time node" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$time", .{ .string = "12:34:56.789" });

    var tree = try fromJson(testing.allocator, .{ .object = obj }, .{});
    defer tree.deinit();
    try testing.expectEqual(Ast.Tag.time, tree.tagOf(tree.root[0]));
    const t = tree.timeOf(tree.root[0]);
    try testing.expectEqual(@as(u16, 789), t.millisecond);
}

test "decode: $time rejects malformed string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$time", .{ .string = "25:00:00" });
    try testing.expectError(error.InvalidEncoding, fromJson(testing.allocator, .{ .object = obj }, .{}));
}

test "fromJson: rejects JSON nested past MAX_JSON_DEPTH" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Build 2000 nested arrays by hand — bypasses std.json's own scanner
    // nesting limit (a `[[[…]]]` source string couldn't reach here) and lands
    // the innermost value at depth 2000, well past MAX_JSON_DEPTH (1024).
    var over: std.json.Value = .{ .integer = 1 };
    for (0..2000) |_| {
        var arr = std.json.Array.init(a);
        try arr.append(over);
        over = .{ .array = arr };
    }
    try testing.expectError(error.DepthExceeded, fromJson(testing.allocator, over, .{}));

    // Control: nesting comfortably under the cap still decodes to a tree.
    var under: std.json.Value = .{ .integer = 1 };
    for (0..300) |_| {
        var arr = std.json.Array.init(a);
        try arr.append(under);
        under = .{ .array = arr };
    }
    var tree = try fromJson(testing.allocator, under, .{});
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 1), tree.root.len);
}
