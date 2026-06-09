const std = @import("std");
const sjon = @import("sjon");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Plugin = sjon.Plugin;
const Writer = std.Io.Writer;

const META_PATH = "manifests/meta.sjon";
const GENERATED_PATH = "src/MetaSchema.generated.zig";

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var regen = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--regen")) regen = true;
    }

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file = Io.File.stderr();
    var stderr_writer = stderr_file.writer(io, &stderr_buf);
    defer stderr_writer.interface.flush() catch {};
    const stderr = &stderr_writer.interface;

    const src = try readSentinel(gpa, io, META_PATH);
    defer gpa.free(src);

    var tree = try sjon.parse(gpa, src);
    defer tree.deinit();
    if (tree.hasErrors()) {
        try stderr.print("gen-meta-schema: {s} has parse errors\n", .{META_PATH});
        return 1;
    }

    var loaded = try sjon.ManifestLoader.loadUnchecked(gpa, tree);
    defer loaded.deinit();
    if (loaded.hasErrors()) {
        try stderr.print(
            "gen-meta-schema: {s} load produced {d} diagnostic(s)\n",
            .{ META_PATH, loaded.diagnostics.len },
        );
        return 1;
    }

    const bytes = try renderPlugin(gpa, loaded.plugin);
    defer gpa.free(bytes);

    if (regen) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = GENERATED_PATH, .data = bytes });
        try stderr.print("wrote {s} ({d} bytes)\n", .{ GENERATED_PATH, bytes.len });
        return 0;
    }

    const existing = Io.Dir.cwd().readFileAlloc(io, GENERATED_PATH, gpa, .unlimited) catch |err| {
        try stderr.print(
            "gen-meta-schema: cannot read {s}: {s} — run `zig build gen-meta-schema -- --regen`\n",
            .{ GENERATED_PATH, @errorName(err) },
        );
        return 1;
    };
    defer gpa.free(existing);

    if (std.mem.eql(u8, existing, bytes)) return 0;

    try stderr.print(
        "gen-meta-schema: {s} is stale (have {d} bytes, want {d}) — " ++
            "run `zig build gen-meta-schema -- --regen` and commit\n",
        .{ GENERATED_PATH, existing.len, bytes.len },
    );
    return 1;
}

fn readSentinel(gpa: Allocator, io: Io, path: []const u8) ![:0]u8 {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    const buf = try gpa.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf, bytes);
    return buf;
}

fn renderPlugin(gpa: Allocator, plugin: Plugin.Plugin) ![]u8 {
    var rough: std.Io.Writer.Allocating = .init(gpa);
    defer rough.deinit();
    emitFile(&rough.writer, plugin) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };

    const rough_z = try gpa.dupeZ(u8, rough.written());
    defer gpa.free(rough_z);

    var ast = try std.zig.Ast.parse(gpa, rough_z, .zig);
    defer ast.deinit(gpa);
    if (ast.errors.len != 0) {
        std.debug.panic("gen-meta-schema: emitted invalid Zig ({d} parse error(s))", .{ast.errors.len});
    }

    var pretty: std.Io.Writer.Allocating = .init(gpa);
    errdefer pretty.deinit();
    ast.render(gpa, &pretty.writer, .{}) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    return pretty.toOwnedSlice();
}

fn emitFile(w: *Writer, plugin: Plugin.Plugin) Writer.Error!void {
    try w.writeAll(
        \\//! GENERATED FILE — do not edit by hand.
        \\//!
        \\//! Source of truth: manifests/meta.sjon. Regenerate with:
        \\//!     zig build gen-meta-schema -- --regen
        \\//!
        \\//! `zig build test` byte-compares this file against a fresh
        \\//! generation, so editing meta.sjon without regenerating — or
        \\//! hand-editing this file — fails CI. See tools/gen_meta_schema.zig.
        \\
        \\const Plugin = @import("Plugin.zig");
        \\const Schema = @import("Schema.zig");
        \\const std = @import("std");
        \\
        \\
    );

    if (plugin.expr_funcs.len != 0) {
        std.debug.panic("gen-meta-schema: meta plugin gained expr_funcs; emitter has no support", .{});
    }

    try w.writeAll("const value_kinds = [_]Plugin.ValueKind{\n");
    for (plugin.value_kinds) |vk| try emitValueKind(w, vk);
    try w.writeAll("};\n\n");

    try w.writeAll("const forms = [_]Plugin.FormSpec{\n");
    for (plugin.forms) |f| try emitForm(w, f);
    try w.writeAll("};\n\n");

    try w.writeAll("pub const plugin: Plugin.Plugin = .{ .name = ");
    try emitString(w, plugin.name);
    if (plugin.version.len != 0) {
        try w.writeAll(", .version = ");
        try emitString(w, plugin.version);
    }
    try w.writeAll(", .forms = &forms, .value_kinds = &value_kinds };\n\n");

    try w.writeAll("pub const schema: Schema.Schema = .{ .plugins = &.{plugin} };\n\n");

    try w.writeAll(
        \\comptime {
        \\    for (forms) |f| std.debug.assert(f.keys.len <= Plugin.MAX_FORM_KEYS);
        \\}
        \\
    );
}

fn emitValueKind(w: *Writer, vk: Plugin.ValueKind) Writer.Error!void {
    if (vk.unit != null) panicVk("uses :unit", vk.name);
    if (vk.numeric != null) panicVk("uses :numeric", vk.name);
    if (vk.cross_ref != null) panicVk("uses :cross-ref", vk.name);
    if (vk.string_bounds != null) panicVk("uses :string-bounds", vk.name);

    try w.writeAll(".{ .name = ");
    try emitString(w, vk.name);
    try w.print(", .underlying = {s}", .{underlyingTag(vk.underlying)});
    if (vk.description.len != 0) {
        try w.writeAll(", .description = ");
        try emitString(w, vk.description);
    }
    if (vk.members) |ms| {
        try w.writeAll(", .members = .{ .members = &.{");
        for (ms.members, 0..) |m, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll(" .{ .name = ");
            try emitString(w, m.name);
            if (m.label.len != 0) {
                try w.writeAll(", .label = ");
                try emitString(w, m.label);
            }
            if (m.description.len != 0) {
                try w.writeAll(", .description = ");
                try emitString(w, m.description);
            }
            if (m.deprecated) try w.writeAll(", .deprecated = true");
            if (m.deprecation_message.len != 0) {
                try w.writeAll(", .deprecation_message = ");
                try emitString(w, m.deprecation_message);
            }
            try w.writeAll(" }");
        }
        try w.writeAll(" } }");
    }
    if (vk.vector) |vs| {
        try w.writeAll(", .vector = .{");
        if (vs.len) |n| try w.print(" .len = {d},", .{n});
        try w.writeAll(" .element = ");
        try emitQualifiedRef(w, vs.element);
        try w.writeAll(" }");
    }
    if (vk.heads) |hs| {
        try w.writeAll(", .heads = .{ .names = &.{");
        for (hs.names, 0..) |nm, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeByte(' ');
            try emitString(w, nm);
        }
        try w.writeAll(" } }");
    }
    if (vk.union_of) |us| {
        try w.writeAll(", .union_of = .{ .alternatives = &.{");
        for (us.alternatives, 0..) |alt, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeByte(' ');
            try emitQualifiedRef(w, alt);
        }
        try w.writeAll(" } }");
    }
    try w.writeAll(" },\n");
}

fn emitForm(w: *Writer, f: Plugin.FormSpec) Writer.Error!void {
    if (f.discriminant_name != null or f.discriminant_idx != null) panicForm("is discriminated", f.name);
    if (f.variants != null) panicForm("has variants", f.name);
    if (f.exclusive_groups.len != 0) panicForm("has exclusive_groups", f.name);
    if (f.lowering != null) panicForm("has a lowering contract", f.name);

    try w.writeAll(".{ .name = ");
    try emitString(w, f.name);
    if (f.description.len != 0) {
        try w.writeAll(", .description = ");
        try emitString(w, f.description);
    }
    if (f.open) try w.writeAll(", .open = true");
    switch (f.positional) {
        .none => {},
        .any => try w.writeAll(", .positional = .any"),
        .kind => |q| {
            try w.writeAll(", .positional = .{ .kind = ");
            try emitQualifiedRef(w, q);
            try w.writeAll(" }");
        },
        .flag_set => panicForm("uses a flag-set positional", f.name),
    }
    if (f.keys.len != 0) {
        try w.writeAll(", .keys = &.{");
        for (f.keys) |k| {
            try w.writeByte(' ');
            try emitKey(w, k);
        }
        try w.writeAll(" }");
    }
    try w.writeAll(" },\n");
}

fn emitKey(w: *Writer, k: Plugin.KeySpec) Writer.Error!void {
    if (k.default != null) {
        std.debug.panic(
            "gen-meta-schema: key '{s}' carries a :default; Default emission is not implemented",
            .{k.name},
        );
    }
    try w.writeAll(".{ .name = ");
    try emitString(w, k.name);
    try w.writeAll(", .value_type = ");
    try emitValueType(w, k.value_type);
    if (!k.optional) try w.writeAll(", .optional = false");
    if (k.walk_opaque) try w.writeAll(", .walk_opaque = true");
    if (k.description.len != 0) {
        try w.writeAll(", .description = ");
        try emitString(w, k.description);
    }
    try w.writeAll(" },");
}

fn emitValueType(w: *Writer, vt: Plugin.ValueType) Writer.Error!void {
    switch (vt) {
        .any => try w.writeAll(".any"),
        .number => try w.writeAll(".number"),
        .string => try w.writeAll(".string"),
        .symbol => try w.writeAll(".symbol"),
        .boolean => try w.writeAll(".boolean"),
        .nil => try w.writeAll(".nil"),
        .vector => try w.writeAll(".vector"),
        .form => try w.writeAll(".form"),
        .expr => try w.writeAll(".expr"),
        .named => |q| {
            try w.writeAll(".{ .named = ");
            try emitQualifiedRef(w, q);
            try w.writeAll(" }");
        },
    }
}

fn emitQualifiedRef(w: *Writer, q: Plugin.QualifiedRef) Writer.Error!void {
    try w.writeAll(".{ .name = ");
    try emitString(w, q.name);
    if (q.namespace) |ns| {
        try w.writeAll(", .namespace = ");
        try emitString(w, ns);
    }
    try w.writeAll(" }");
}

fn emitString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => {
            if (c < 0x20) {
                try w.print("\\x{x:0>2}", .{c});
            } else {
                try w.writeByte(c);
            }
        },
    };
    try w.writeByte('"');
}

fn underlyingTag(u: Plugin.ValueKind.Underlying) []const u8 {
    return switch (u) {
        .number => ".number",
        .string => ".string",
        .vector => ".vector",
        .form => ".form",
        .symbol => ".symbol",
        .union_of => ".union_of",
    };
}

fn panicVk(reason: []const u8, name: []const u8) noreturn {
    std.debug.panic("gen-meta-schema: value-kind '{s}' {s}; emitter has no support", .{ name, reason });
}

fn panicForm(reason: []const u8, name: []const u8) noreturn {
    std.debug.panic("gen-meta-schema: form '{s}' {s}; emitter has no support", .{ name, reason });
}
