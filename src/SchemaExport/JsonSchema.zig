const std = @import("std");
const Allocator = std.mem.Allocator;

const Model = @import("Model.zig");
const Warnings = @import("Warnings.zig");

pub const Error = error{OutOfMemory};

pub fn emit(
    a: Allocator,
    model: Model.Model,
    warnings: []const Warnings.Warning,
) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    var w: std.json.Stringify = .{
        .writer = &aw.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    writeRoot(&w, model, warnings, .{ .filter_plugin = null }) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    aw.writer.writeByte('\n') catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

pub fn emitForPlugin(
    a: Allocator,
    model: Model.Model,
    plugin: Model.Plugin_,
    warnings: []const Warnings.Warning,
) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    var w: std.json.Stringify = .{
        .writer = &aw.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    writeRoot(&w, model, warnings, .{ .filter_plugin = plugin.name }) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    aw.writer.writeByte('\n') catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

const EmitContext = struct {
    filter_plugin: ?[]const u8,
};

threadlocal var current_ctx: EmitContext = .{ .filter_plugin = null };

threadlocal var current_plugin: Model.Plugin_ = .{ .name = "", .forms = &.{}, .value_kinds = &.{} };

fn writeRoot(
    w: *std.json.Stringify,
    model: Model.Model,
    warnings: []const Warnings.Warning,
    ctx: EmitContext,
) std.Io.Writer.Error!void {
    current_ctx = ctx;
    defer current_ctx = .{ .filter_plugin = null };

    try w.beginObject();
    try w.objectField("$schema");
    try w.write("https://json-schema.org/draft/2020-12/schema");
    try w.objectField("x-sjon-export-version");
    try w.write(model.version);

    if (warnings.len > 0) {
        try w.objectField("x-sjon-export-warnings");
        try w.beginArray();
        for (warnings) |wn| try writeWarning(w, wn);
        try w.endArray();
    }

    try w.objectField("$defs");
    try w.beginObject();
    for (model.plugins) |p| {
        if (ctx.filter_plugin) |only| {
            if (!std.mem.eql(u8, p.name, only)) continue;
        }
        for (p.forms) |f| {
            var key_buf: [256]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "form.{s}.{s}", .{ p.name, f.name }) catch return error.WriteFailed;
            try w.objectField(key);
            try writeForm(w, p, f);
        }
    }
    try w.endObject();

    try w.objectField("oneOf");
    try w.beginArray();
    var any_form = false;
    for (model.plugins) |p| {
        if (ctx.filter_plugin) |only| {
            if (!std.mem.eql(u8, p.name, only)) continue;
        }
        for (p.forms) |f| {
            any_form = true;
            try w.beginObject();
            try w.objectField("$ref");
            var ref_buf: [256]u8 = undefined;
            const ref = std.fmt.bufPrint(&ref_buf, "#/$defs/form.{s}.{s}", .{ p.name, f.name }) catch return error.WriteFailed;
            try w.write(ref);
            try w.endObject();
        }
    }
    if (!any_form) {
        try w.beginObject();
        try w.objectField("not");
        try w.beginObject();
        try w.endObject();
        try w.endObject();
    }
    try w.endArray();

    try w.endObject();
}

fn writeForm(w: *std.json.Stringify, p: Model.Plugin_, f: Model.Form) std.Io.Writer.Error!void {
    const saved_plugin = current_plugin;
    current_plugin = p;
    defer current_plugin = saved_plugin;

    try w.beginObject();
    try w.objectField("type");
    try w.write("object");
    if (f.description.len > 0) {
        try w.objectField("description");
        try w.write(f.description);
    }
    try w.objectField("properties");
    try w.beginObject();
    try w.objectField("$form");
    try w.beginObject();
    try w.objectField("const");
    try w.write(f.name);
    try w.endObject();
    try w.objectField("$ns");
    try w.beginObject();
    try w.objectField("const");
    try w.write(p.name);
    try w.endObject();
    var indices: [64]u16 = undefined;
    const n_keys = @min(f.keys.len, indices.len);
    for (0..n_keys) |i| indices[i] = @intCast(i);
    sortKeysAlphabetically(f.keys, indices[0..n_keys]);
    for (indices[0..n_keys]) |idx| {
        const k = f.keys[idx];
        var name_buf: [128]u8 = undefined;
        try w.objectField(try escapedFieldName(&name_buf, k.name));
        try writeKey(w, k);
    }
    switch (f.positional) {
        .none => {},
        .any => {
            try w.objectField("$children");
            try w.beginObject();
            try w.objectField("type");
            try w.write("array");
            try w.endObject();
        },
        .kind => |shape| {
            try w.objectField("$children");
            try w.beginObject();
            try w.objectField("type");
            try w.write("array");
            try w.objectField("items");
            try writeShape(w, shape);
            try w.endObject();
        },
    }
    try w.endObject();

    try w.objectField("required");
    try w.beginArray();
    try w.write("$form");
    for (f.keys) |k| {
        if (k.optional) continue;
        var name_buf: [128]u8 = undefined;
        try w.write(try escapedFieldName(&name_buf, k.name));
    }
    try w.endArray();

    const has_discriminator = f.discriminator != null;
    const has_enforceable_groups = hasEnforceableExclusiveGroups(f.exclusive_groups);
    if (has_discriminator or has_enforceable_groups) {
        try w.objectField("allOf");
        try w.beginArray();
        if (f.discriminator) |d| {
            for (d.variants) |v| try writeVariantOverlay(w, d.key_name, v);
        }
        for (f.exclusive_groups) |g| {
            if (isEnforceableExclusiveGroup(g)) try writeExclusiveGroup(w, g);
        }
        try w.endArray();
        try w.objectField("unevaluatedProperties");
        try w.write(f.open);
    } else {
        try w.objectField("additionalProperties");
        try w.write(f.open);
    }

    if (f.discriminator) |d| {
        try w.objectField("x-sjon-discriminant");
        try w.beginObject();
        try w.objectField("key");
        try w.write(d.key_name);
        try w.objectField("variants");
        try w.beginArray();
        for (d.variants) |v| {
            try w.beginObject();
            try w.objectField("when");
            try w.write(v.when);
            try w.objectField("keys");
            try w.beginArray();
            for (v.keys) |vk| try w.write(vk.name);
            try w.endArray();
            try w.endObject();
        }
        try w.endArray();
        try w.endObject();
    }
    if (f.exclusive_groups.len > 0) {
        try w.objectField("x-sjon-exclusive-groups");
        try w.beginArray();
        for (f.exclusive_groups) |g| {
            try w.beginObject();
            try w.objectField("cardinality");
            try w.write(@tagName(g.cardinality));
            try w.objectField("alternatives");
            try w.beginArray();
            for (g.alternatives) |alt| {
                try w.beginArray();
                for (alt) |kn| try w.write(kn);
                try w.endArray();
            }
            try w.endArray();
            try w.endObject();
        }
        try w.endArray();
    }
    if (f.lowering) |low| {
        try w.objectField("x-sjon-lowering");
        try w.beginObject();
        try w.objectField("hook");
        try w.write(low.hook);
        try w.objectField("produces");
        try w.beginArray();
        for (low.produces) |head| try w.write(head);
        try w.endArray();
        try w.endObject();
    }
    if (f.positional_flags) |flags| {
        try w.objectField("x-sjon-positional-flags");
        try w.beginArray();
        for (flags) |flag| {
            try w.beginObject();
            try w.objectField("name");
            try w.write(flag.name);
            if (flag.description.len > 0) {
                try w.objectField("description");
                try w.write(flag.description);
            }
            if (flag.link) |link| {
                try w.objectField("link");
                try w.write(link);
            }
            try w.endObject();
        }
        try w.endArray();
    }
    try w.endObject();
}

const MemberUnderlying = enum { symbol, string };

fn writeRichMember(
    w: *std.json.Stringify,
    m: Model.Member,
    underlying: MemberUnderlying,
) std.Io.Writer.Error!void {
    try w.beginObject();
    try w.objectField("const");
    switch (underlying) {
        .symbol => {
            try w.beginObject();
            try w.objectField("$sym");
            try w.write(m.name);
            try w.endObject();
        },
        .string => try w.write(m.name),
    }
    if (m.label.len > 0) {
        try w.objectField("title");
        try w.write(m.label);
    }
    if (m.description.len > 0) {
        try w.objectField("description");
        try w.write(m.description);
    }
    if (m.deprecated) {
        try w.objectField("deprecated");
        try w.write(true);
    }
    if (m.deprecation_message.len > 0) {
        try w.objectField("x-sjon-deprecation-message");
        try w.write(m.deprecation_message);
    }
    try w.endObject();
}

fn hasEnforceableExclusiveGroups(groups: []const Model.ExclusiveGroup) bool {
    for (groups) |g| if (isEnforceableExclusiveGroup(g)) return true;
    return false;
}

fn isEnforceableExclusiveGroup(g: Model.ExclusiveGroup) bool {
    if (g.alternatives.len < 2) return false;
    for (g.alternatives) |alt| if (alt.len == 0) return false;
    return true;
}

fn writeBundleRequired(w: *std.json.Stringify, bundle: []const []const u8) std.Io.Writer.Error!void {
    try w.beginObject();
    try w.objectField("required");
    try w.beginArray();
    for (bundle) |kn| try w.write(kn);
    try w.endArray();
    try w.endObject();
}

fn writeExclusiveGroup(w: *std.json.Stringify, g: Model.ExclusiveGroup) std.Io.Writer.Error!void {
    try w.beginObject();
    switch (g.cardinality) {
        .exactly_one => {
            try w.objectField("oneOf");
            try w.beginArray();
            for (g.alternatives) |alt| try writeBundleRequired(w, alt);
            try w.endArray();
        },
        .at_most_one => {
            try w.objectField("not");
            try w.beginObject();
            if (g.alternatives.len == 2) {
                try w.objectField("allOf");
                try w.beginArray();
                for (g.alternatives) |alt| try writeBundleRequired(w, alt);
                try w.endArray();
            } else {
                try w.objectField("anyOf");
                try w.beginArray();
                for (g.alternatives, 0..) |a_alt, i| {
                    for (g.alternatives[i + 1 ..]) |b_alt| {
                        try w.beginObject();
                        try w.objectField("allOf");
                        try w.beginArray();
                        try writeBundleRequired(w, a_alt);
                        try writeBundleRequired(w, b_alt);
                        try w.endArray();
                        try w.endObject();
                    }
                }
                try w.endArray();
            }
            try w.endObject();
        },
    }
    try w.endObject();
}

fn writeVariantOverlay(w: *std.json.Stringify, disc_key: []const u8, v: Model.Variant) std.Io.Writer.Error!void {
    try w.beginObject();

    try w.objectField("if");
    try w.beginObject();
    try w.objectField("properties");
    try w.beginObject();
    try w.objectField(disc_key);
    try w.beginObject();
    try w.objectField("const");
    try w.beginObject();
    try w.objectField("$sym");
    try w.write(v.when);
    try w.endObject();
    try w.endObject();
    try w.endObject();
    try w.objectField("required");
    try w.beginArray();
    try w.write(disc_key);
    try w.endArray();
    try w.endObject();

    try w.objectField("then");
    try w.beginObject();
    if (v.keys.len > 0) {
        try w.objectField("properties");
        try w.beginObject();
        var indices: [64]u16 = undefined;
        const n_keys = @min(v.keys.len, indices.len);
        for (0..n_keys) |i| indices[i] = @intCast(i);
        sortKeysAlphabetically(v.keys, indices[0..n_keys]);
        for (indices[0..n_keys]) |idx| {
            const k = v.keys[idx];
            var name_buf: [128]u8 = undefined;
            try w.objectField(try escapedFieldName(&name_buf, k.name));
            try writeKey(w, k);
        }
        try w.endObject();
        var any_required = false;
        for (v.keys) |k| {
            if (!k.optional) {
                any_required = true;
                break;
            }
        }
        if (any_required) {
            try w.objectField("required");
            try w.beginArray();
            for (v.keys) |k| {
                if (k.optional) continue;
                var name_buf: [128]u8 = undefined;
                try w.write(try escapedFieldName(&name_buf, k.name));
            }
            try w.endArray();
        }
    }
    try w.endObject();

    try w.endObject();
}

fn writeKey(w: *std.json.Stringify, k: Model.Key) std.Io.Writer.Error!void {
    try w.beginObject();
    if (k.description.len > 0) {
        try w.objectField("description");
        try w.write(k.description);
    }
    try writeShapeBody(w, k.value);
    if (k.default) |d| {
        switch (d) {
            .expression => |e| {
                try w.objectField("x-sjon-default-expression");
                try w.beginObject();
                try w.objectField("head");
                try w.write(e.head);
                if (e.namespace) |ns| {
                    try w.objectField("namespace");
                    try w.write(ns);
                }
                try w.objectField("arg-count");
                try w.write(e.arg_count);
                try w.endObject();
            },
            else => {
                try w.objectField("default");
                try writeDefaultLiteral(w, d);
            },
        }
    }
    try w.endObject();
}

fn writeDefaultLiteral(w: *std.json.Stringify, d: Model.Default) std.Io.Writer.Error!void {
    switch (d) {
        .nil => try w.write(null),
        .boolean => |b| try w.write(b),
        .number => |n| try w.write(n),
        .string => |s| try w.write(s),
        .symbol => |s| {
            try w.beginObject();
            try w.objectField("$sym");
            try w.write(s);
            try w.endObject();
        },
        .vector => |vs| {
            try w.beginArray();
            for (vs) |child| try writeDefaultLiteral(w, child);
            try w.endArray();
        },
        .expression => unreachable,
    }
}

fn writeShape(w: *std.json.Stringify, shape: Model.ValueShape) std.Io.Writer.Error!void {
    try w.beginObject();
    try writeShapeBody(w, shape);
    try w.endObject();
}

fn writeShapeBody(w: *std.json.Stringify, shape: Model.ValueShape) std.Io.Writer.Error!void {
    switch (shape) {
        .any => {},
        .nil => {
            try w.objectField("type");
            try w.write("null");
        },
        .boolean => {
            try w.objectField("type");
            try w.write("boolean");
        },
        .number => {
            try w.objectField("type");
            try w.write("number");
        },
        .number_bounded => |b| {
            if (b.integer) {
                try w.objectField("type");
                try w.write("integer");
            } else {
                try w.objectField("type");
                try w.write("number");
            }
            try writeNumericBoundsBody(w, b);
        },
        .number_i64 => {
            try w.objectField("type");
            try w.write("integer");
            try w.objectField("x-sjon-int-width");
            try w.write("i64");
        },
        .number_u64 => {
            try w.objectField("oneOf");
            try w.beginArray();
            try w.beginObject();
            try w.objectField("type");
            try w.write("integer");
            try w.endObject();
            try w.beginObject();
            try w.objectField("type");
            try w.write("string");
            try w.objectField("pattern");
            try w.write("^[0-9]+$");
            try w.endObject();
            try w.endArray();
            try w.objectField("x-sjon-int-width");
            try w.write("u64");
        },
        .string => {
            try w.objectField("type");
            try w.write("string");
        },
        .string_with_bounds => |sb| {
            try w.objectField("type");
            try w.write("string");
            if (sb.min_len) |n| {
                try w.objectField("minLength");
                try w.write(n);
            }
            if (sb.max_len) |n| {
                try w.objectField("maxLength");
                try w.write(n);
            }
            if (sb.pattern) |p| {
                try w.objectField("pattern");
                try w.write(p);
                try w.objectField("x-sjon-pattern-engine");
                try w.write("deferred-in-sjon-runtime");
            }
            if (sb.format) |f| {
                switch (f) {
                    .email, .uri, .uuid => {
                        try w.objectField("format");
                        try w.write(@tagName(f));
                    },
                    .path, .semver => {
                        try w.objectField("x-sjon-format");
                        try w.write(@tagName(f));
                    },
                }
            }
            try w.objectField("x-sjon-length-unit");
            try w.write("codepoint");
        },
        .symbol => {
            try w.objectField("type");
            try w.write("object");
            try w.objectField("properties");
            try w.beginObject();
            try w.objectField("$sym");
            try w.beginObject();
            try w.objectField("type");
            try w.write("string");
            try w.endObject();
            try w.endObject();
            try w.objectField("required");
            try w.beginArray();
            try w.write("$sym");
            try w.endArray();
            try w.objectField("additionalProperties");
            try w.write(false);
        },
        .symbol_members => |names| {
            try w.objectField("enum");
            try w.beginArray();
            for (names) |n| {
                try w.beginObject();
                try w.objectField("$sym");
                try w.write(n);
                try w.endObject();
            }
            try w.endArray();
        },
        .symbol_members_rich => |members| {
            try w.objectField("oneOf");
            try w.beginArray();
            for (members) |m| try writeRichMember(w, m, .symbol);
            try w.endArray();
        },
        .string_members => |names| {
            try w.objectField("enum");
            try w.beginArray();
            for (names) |n| try w.write(n);
            try w.endArray();
        },
        .string_members_rich => |members| {
            try w.objectField("oneOf");
            try w.beginArray();
            for (members) |m| try writeRichMember(w, m, .string);
            try w.endArray();
        },
        .date => {
            try w.objectField("type");
            try w.write("object");
            try w.objectField("properties");
            try w.beginObject();
            try w.objectField("$date");
            try w.beginObject();
            try w.objectField("type");
            try w.write("string");
            try w.objectField("pattern");
            try w.write("^[0-9]{4}-[0-9]{2}-[0-9]{2}$");
            try w.objectField("format");
            try w.write("date");
            try w.endObject();
            try w.endObject();
            try w.objectField("required");
            try w.beginArray();
            try w.write("$date");
            try w.endArray();
            try w.objectField("additionalProperties");
            try w.write(false);
        },
        .time => {
            try w.objectField("type");
            try w.write("object");
            try w.objectField("properties");
            try w.beginObject();
            try w.objectField("$time");
            try w.beginObject();
            try w.objectField("type");
            try w.write("string");
            try w.objectField("pattern");
            try w.write("^[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{3})?$");
            try w.objectField("format");
            try w.write("time");
            try w.endObject();
            try w.endObject();
            try w.objectField("required");
            try w.beginArray();
            try w.write("$time");
            try w.endArray();
            try w.objectField("additionalProperties");
            try w.write(false);
        },
        .keyword => {
            try w.objectField("type");
            try w.write("object");
            try w.objectField("properties");
            try w.beginObject();
            try w.objectField("$kw");
            try w.beginObject();
            try w.objectField("type");
            try w.write("string");
            try w.endObject();
            try w.endObject();
            try w.objectField("required");
            try w.beginArray();
            try w.write("$kw");
            try w.endArray();
            try w.objectField("additionalProperties");
            try w.write(false);
        },
        .vector => |vs| {
            try w.objectField("type");
            try w.write("array");
            try w.objectField("items");
            try writeShape(w, vs.element.*);
            if (vs.len) |n| {
                try w.objectField("minItems");
                try w.write(n);
                try w.objectField("maxItems");
                try w.write(n);
            } else {
                if (vs.min_len) |n| {
                    try w.objectField("minItems");
                    try w.write(n);
                }
                if (vs.max_len) |n| {
                    try w.objectField("maxItems");
                    try w.write(n);
                }
            }
        },
        .form_any => {
            try w.objectField("type");
            try w.write("object");
            try w.objectField("required");
            try w.beginArray();
            try w.write("$form");
            try w.endArray();
        },
        .form_heads => |refs| {
            try w.objectField("oneOf");
            try w.beginArray();
            for (refs) |ref| {
                try w.beginObject();
                try w.objectField("$ref");
                var buf: [256]u8 = undefined;
                const path = try formatFormRef(&buf, ref);
                try w.write(path);
                try w.endObject();
            }
            try w.endArray();
            try w.objectField("x-sjon-head-set");
            try w.beginArray();
            for (refs) |ref| try w.write(ref.name);
            try w.endArray();
        },
        .form_locals => |forms| {
            try w.objectField("anyOf");
            try w.beginArray();
            for (forms) |lf| try writeForm(w, current_plugin, lf);
            try w.beginObject();
            try w.objectField("type");
            try w.write("object");
            try w.objectField("required");
            try w.beginArray();
            try w.write("$form");
            try w.endArray();
            try w.endObject();
            try w.endArray();
            try w.objectField("x-sjon-local-forms");
            try w.beginArray();
            for (forms) |lf| try w.write(lf.name);
            try w.endArray();
        },
        .expr => {
            try w.objectField("type");
            try w.write("object");
            try w.objectField("properties");
            try w.beginObject();
            try w.objectField("$expr");
            try w.beginObject();
            try w.objectField("type");
            try w.write("array");
            try w.endObject();
            try w.endObject();
            try w.objectField("required");
            try w.beginArray();
            try w.write("$expr");
            try w.endArray();
            try w.objectField("x-sjon-expr");
            try w.write("schema validates $expr envelope only; runtime result type not enforced");
        },
        .cross_ref => |cr| {
            try w.objectField("type");
            try w.write("object");
            try w.objectField("properties");
            try w.beginObject();
            try w.objectField("$sym");
            try w.beginObject();
            try w.objectField("type");
            try w.write("string");
            try w.endObject();
            try w.endObject();
            try w.objectField("required");
            try w.beginArray();
            try w.write("$sym");
            try w.endArray();
            try w.objectField("additionalProperties");
            try w.write(false);
            try w.objectField("x-sjon-cross-ref");
            try w.beginObject();
            try w.objectField("target-form");
            try w.write(cr.target_form);
            try w.objectField("name-key");
            try w.write(cr.name_key);
            try w.objectField("acyclic");
            try w.write(cr.acyclic);
            if (cr.scope_form) |sf| {
                try w.objectField("scope-form");
                try w.write(sf);
            }
            try w.endObject();
        },
        .union_of => |alts| {
            try w.objectField("anyOf");
            try w.beginArray();
            for (alts) |alt| try writeShape(w, alt.shape);
            try w.endArray();
            try w.objectField("x-sjon-union-alternatives");
            try w.beginArray();
            for (alts) |alt| try w.write(alt.name);
            try w.endArray();
        },
        .number_with_unit => |u| {
            try w.objectField("type");
            try w.write("object");
            try w.objectField("properties");
            try w.beginObject();
            try w.objectField("$num");
            try w.beginObject();
            try w.objectField("type");
            try w.write("array");
            try w.objectField("prefixItems");
            try w.beginArray();
            try w.beginObject();
            try w.objectField("type");
            try w.write("number");
            if (u.bounds) |b| try writeNumericBoundsBody(w, b);
            try w.endObject();
            try w.beginObject();
            try w.objectField("type");
            try w.write("string");
            if (u.allowed.len > 0) {
                try w.objectField("enum");
                try w.beginArray();
                for (u.allowed) |s| try w.write(s);
                try w.endArray();
            } else {
                try w.objectField("minLength");
                try w.write(1);
            }
            try w.endObject();
            try w.endArray();
            try w.objectField("minItems");
            try w.write(2);
            try w.objectField("maxItems");
            try w.write(2);
            try w.objectField("items");
            try w.write(false);
            try w.endObject();
            try w.endObject();
            try w.objectField("required");
            try w.beginArray();
            try w.write("$num");
            try w.endArray();
            try w.objectField("additionalProperties");
            try w.write(false);
            try w.objectField("x-sjon-unit");
            try w.beginObject();
            try w.objectField("required");
            try w.write(u.required);
            try w.objectField("allowed");
            try w.beginArray();
            for (u.allowed) |s| try w.write(s);
            try w.endArray();
            try w.endObject();
        },
        .unresolved_named => |u| {
            try w.objectField("x-sjon-unresolved");
            if (u.namespace) |ns| {
                var buf: [256]u8 = undefined;
                const display = std.fmt.bufPrint(&buf, "{s}/{s}", .{ ns, u.name }) catch return error.WriteFailed;
                try w.write(display);
            } else {
                try w.write(u.name);
            }
        },
    }
}

fn writeNumericBoundsBody(w: *std.json.Stringify, b: Model.NumericBounds) std.Io.Writer.Error!void {
    if (b.min) |min| {
        if (b.exclusive_min) {
            try w.objectField("exclusiveMinimum");
        } else {
            try w.objectField("minimum");
        }
        try w.write(min.value);
    }
    if (b.max) |max| {
        if (b.exclusive_max) {
            try w.objectField("exclusiveMaximum");
        } else {
            try w.objectField("maximum");
        }
        try w.write(max.value);
    }
    var exact_min_buf: [32]u8 = undefined;
    var exact_max_buf: [32]u8 = undefined;
    var exact_min: ?[]const u8 = null;
    var exact_max: ?[]const u8 = null;
    if (b.min) |min| {
        if (min.exact_int and @abs(min.value) > 9007199254740992.0) {
            exact_min = std.fmt.bufPrint(&exact_min_buf, "{d:.0}", .{min.value}) catch return error.WriteFailed;
        }
    }
    if (b.max) |max| {
        if (max.exact_int and @abs(max.value) > 9007199254740992.0) {
            exact_max = std.fmt.bufPrint(&exact_max_buf, "{d:.0}", .{max.value}) catch return error.WriteFailed;
        }
    }
    if (exact_min != null or exact_max != null) {
        try w.objectField("x-sjon-exact-bound");
        try w.beginObject();
        if (exact_min) |s| {
            try w.objectField("min");
            try w.write(s);
        }
        if (exact_max) |s| {
            try w.objectField("max");
            try w.write(s);
        }
        try w.endObject();
    }
    if (b.repr) |r| {
        try w.objectField("x-sjon-gpu-repr");
        try w.write(@tagName(r));
    }
}

fn writeWarning(w: *std.json.Stringify, wn: Warnings.Warning) std.Io.Writer.Error!void {
    try w.beginObject();
    try w.objectField("code");
    try w.write(@tagName(wn.code));
    try w.objectField("severity");
    try w.write(@tagName(wn.severity));
    try w.objectField("message");
    try w.write(wn.message);
    if (wn.plugin_name) |p| {
        try w.objectField("plugin");
        try w.write(p);
    }
    if (wn.form_name) |f| {
        try w.objectField("form");
        try w.write(f);
    }
    if (wn.key_name) |k| {
        try w.objectField("key");
        try w.write(k);
    }
    if (wn.kind_name) |k| {
        try w.objectField("kind");
        try w.write(k);
    }
    try w.endObject();
}

fn formatFormRef(buf: []u8, ref: Model.FormRef) std.Io.Writer.Error![]const u8 {
    if (current_ctx.filter_plugin) |only| {
        if (!std.mem.eql(u8, ref.plugin, only)) {
            return std.fmt.bufPrint(buf, "./{s}.schema.json#/$defs/form.{s}.{s}", .{
                ref.plugin, ref.plugin, ref.name,
            }) catch error.WriteFailed;
        }
    }
    return std.fmt.bufPrint(buf, "#/$defs/form.{s}.{s}", .{ ref.plugin, ref.name }) catch error.WriteFailed;
}

fn escapedFieldName(buf: []u8, name: []const u8) std.Io.Writer.Error![]const u8 {
    if (name.len == 0 or name[0] != '$') return name;
    return std.fmt.bufPrint(buf, "${s}", .{name}) catch error.WriteFailed;
}

fn sortKeysAlphabetically(keys: []const Model.Key, indices: []u16) void {
    std.mem.sort(u16, indices, keys, struct {
        fn lt(ks: []const Model.Key, a: u16, b: u16) bool {
            return std.mem.order(u8, ks[a].name, ks[b].name) == .lt;
        }
    }.lt);
}

const testing = std.testing;
const SchemaExport = @import("SchemaExport.zig");
const Schema = @import("../Schema.zig");
const Plugin = @import("../Plugin.zig");
