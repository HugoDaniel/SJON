//! Model → TypeScript `.d.ts` bytes.
//!
//! Emits one interface per form (named `<plugin>_<form>` PascalCase),
//! one type alias per value-kind, and a barrel `Sjon<plugin>` union for
//! discoverability. The output describes the *canonical* JSON shape of
//! `sjon to-json` — `$form`, `$ns`, `$kw`, `$sym`, etc. — not the
//! source-level S-expression syntax.
//!
//! Branded primitives (`Keyword_<S>`, `Symbol_<S>`, `Date_`, `Time_`,
//! `Expr_`) sit at the top of every emit so consumers can `import` the
//! `.d.ts` directly into a TS project that's about to read SJON-as-JSON.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Model = @import("Model.zig");
const Plugin = @import("../Plugin.zig");
const Warnings = @import("Warnings.zig");

/// Branded TS alias for a GPU representation tag. The aliases are defined
/// in `writePrelude`; this maps the `Repr` enum to the alias name so a
/// `:repr`-tagged number renders as `F32` … `F16` instead of `number`.
fn reprTsAlias(r: Plugin.ValueKind.Repr) []const u8 {
    return switch (r) {
        .f32 => "F32",
        .u32 => "U32",
        .i32 => "I32",
        .u16 => "U16",
        .f16 => "F16",
    };
}

pub const Error = error{OutOfMemory};

pub fn emit(
    a: Allocator,
    model: Model.Model,
    warnings: []const Warnings.Warning,
) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    writeAll(&aw.writer, model, warnings, null) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return aw.toOwnedSlice();
}

/// Per-plugin emit. Produces a self-contained `.d.ts` for one plugin
/// with `import type` lines at the top for any cross-plugin form/kind
/// references. Cross-plugin form-head unions reference `<other>_<head>`
/// from a sibling file path.
pub fn emitForPlugin(
    a: Allocator,
    model: Model.Model,
    plugin: Model.Plugin_,
    warnings: []const Warnings.Warning,
) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    writeAll(&aw.writer, model, warnings, plugin.name) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return aw.toOwnedSlice();
}

threadlocal var current_filter: ?[]const u8 = null;

fn writeAll(
    w: *std.Io.Writer,
    model: Model.Model,
    warnings: []const Warnings.Warning,
    filter_plugin: ?[]const u8,
) std.Io.Writer.Error!void {
    current_filter = filter_plugin;
    defer current_filter = null;

    try writeHeader(w, model.version, warnings);
    try writePrelude(w);
    if (filter_plugin) |only| {
        try writeCrossPluginImports(w, model, only);
    }
    for (model.plugins) |p| {
        if (filter_plugin) |only| {
            if (!std.mem.eql(u8, p.name, only)) continue;
        }
        try w.writeAll("\n// ----- plugin: ");
        try w.writeAll(p.name);
        try w.writeAll(" -----\n\n");
        for (p.forms) |f| try writeForm(w, p, f);
        try writeBarrel(w, p);
    }
}

fn writeCrossPluginImports(
    w: *std.Io.Writer,
    model: Model.Model,
    this_plugin: []const u8,
) std.Io.Writer.Error!void {
    // Walk every form in this plugin and collect referenced (plugin, name)
    // pairs whose plugin is not `this_plugin`. Dedupe in-place against a
    // small append-only buffer so repeated references emit a single
    // `import type` line. Deterministic order: first-seen.
    var seen_buf: [128]ImportEntry = undefined;
    var seen_len: usize = 0;
    for (model.plugins) |p| {
        if (!std.mem.eql(u8, p.name, this_plugin)) continue;
        for (p.forms) |f| {
            try collectCrossPluginImports(w, f, this_plugin, &seen_buf, &seen_len);
        }
    }
    if (seen_len > 0) try w.writeByte('\n');
}

const ImportEntry = struct { plugin: []const u8, name: []const u8 };

fn collectCrossPluginImports(
    w: *std.Io.Writer,
    f: Model.Form,
    this_plugin: []const u8,
    seen_buf: []ImportEntry,
    seen_len: *usize,
) std.Io.Writer.Error!void {
    for (f.keys) |k| try emitCrossPluginRefsForShape(w, k.value, this_plugin, seen_buf, seen_len);
    if (f.discriminator) |d| {
        for (d.variants) |v| {
            for (v.keys) |k| try emitCrossPluginRefsForShape(w, k.value, this_plugin, seen_buf, seen_len);
        }
    }
    switch (f.positional) {
        .none, .any => {},
        .kind => |shape| try emitCrossPluginRefsForShape(w, shape, this_plugin, seen_buf, seen_len),
    }
}

fn emitCrossPluginRefsForShape(
    w: *std.Io.Writer,
    shape: Model.ValueShape,
    this_plugin: []const u8,
    seen_buf: []ImportEntry,
    seen_len: *usize,
) std.Io.Writer.Error!void {
    switch (shape) {
        .form_heads => |refs| {
            for (refs) |ref| {
                if (ref.plugin.len == 0) continue;
                if (std.mem.eql(u8, ref.plugin, this_plugin)) continue;
                // Dedupe by (plugin, name) — repeated references across
                // slots emit a single import.
                var already = false;
                var i: usize = 0;
                while (i < seen_len.*) : (i += 1) {
                    if (std.mem.eql(u8, seen_buf[i].plugin, ref.plugin) and
                        std.mem.eql(u8, seen_buf[i].name, ref.name))
                    {
                        already = true;
                        break;
                    }
                }
                if (already) continue;
                if (seen_len.* < seen_buf.len) {
                    seen_buf[seen_len.*] = .{ .plugin = ref.plugin, .name = ref.name };
                    seen_len.* += 1;
                }
                try w.writeAll("import type { ");
                try writeFormTypeName(w, ref.plugin, ref.name);
                try w.writeAll(" } from \"./");
                try w.writeAll(ref.plugin);
                try w.writeAll("\";\n");
            }
        },
        .vector => |vs| try emitCrossPluginRefsForShape(w, vs.element.*, this_plugin, seen_buf, seen_len),
        .union_of => |alts| {
            for (alts) |alt| try emitCrossPluginRefsForShape(w, alt.shape, this_plugin, seen_buf, seen_len);
        },
        else => {},
    }
}

fn writeHeader(
    w: *std.Io.Writer,
    version: u32,
    warnings: []const Warnings.Warning,
) std.Io.Writer.Error!void {
    try w.writeAll("// sjon-export-version: ");
    try printDecimal(w, version);
    try w.writeAll("\n// Generated by sjon — do not edit by hand.\n");
    try w.writeAll("// Describes the canonical JSON shape of `sjon to-json`.\n");
    if (warnings.len > 0) {
        try w.writeAll("//\n// Export warnings:\n");
        for (warnings) |wn| {
            try w.writeAll("//   [");
            try w.writeAll(@tagName(wn.severity));
            try w.writeAll(" ");
            try w.writeAll(@tagName(wn.code));
            try w.writeAll("] ");
            try w.writeAll(wn.message);
            try w.writeByte('\n');
        }
    }
    try w.writeByte('\n');
}

fn writePrelude(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(
        \\export type Keyword<S extends string = string> = { readonly $kw: S };
        \\export type Symbol_<S extends string = string> = { readonly $sym: S };
        \\export type SjonDate = { readonly $date: string };
        \\export type SjonTime = { readonly $time: string };
        \\export type SjonExpr<TResult = unknown> = { readonly $expr: unknown[] } & { readonly __sjonResult?: TResult };
        \\export type CrossRef<TargetForm extends string = string, S extends string = string> = Symbol_<S> & { readonly __sjonRef?: TargetForm };
        \\export type F32 = number & { readonly __sjonRepr?: "f32" };
        \\export type U32 = number & { readonly __sjonRepr?: "u32" };
        \\export type I32 = number & { readonly __sjonRepr?: "i32" };
        \\export type U16 = number & { readonly __sjonRepr?: "u16" };
        \\export type F16 = number & { readonly __sjonRepr?: "f16" };
        \\
        \\
    );
}

fn writeForm(
    w: *std.Io.Writer,
    p: Model.Plugin_,
    f: Model.Form,
) std.Io.Writer.Error!void {
    try writeFormDoc(w, f);
    if (f.discriminator) |d| {
        try writeDiscriminatedFormType(w, p, f, d);
    } else {
        try writeFormInterface(w, p, f);
    }
}

/// Form-level JSDoc: description (if any) followed by one
/// `@sjon-exclusive-group` line per exclusive group on the form. TS
/// cannot type-enforce cardinality — the JSDoc is documentation only,
/// matching the JSON Schema's `x-sjon-exclusive-groups` annotation.
fn writeFormDoc(w: *std.Io.Writer, f: Model.Form) std.Io.Writer.Error!void {
    const has_desc = f.description.len > 0;
    const has_groups = f.exclusive_groups.len > 0;
    if (!has_desc and !has_groups) return;
    // Multi-line block when both are present, single-line when only one.
    if (has_desc and !has_groups) {
        try w.writeAll("/** ");
        try w.writeAll(f.description);
        try w.writeAll(" */\n");
        return;
    }
    try w.writeAll("/**\n");
    if (has_desc) {
        try w.writeAll(" * ");
        try w.writeAll(f.description);
        try w.writeByte('\n');
        if (has_groups) try w.writeAll(" *\n");
    }
    for (f.exclusive_groups) |g| {
        try w.writeAll(" * @sjon-exclusive-group ");
        try w.writeAll(switch (g.cardinality) {
            .exactly_one => "exactly-one",
            .at_most_one => "at-most-one",
        });
        try w.writeAll(" [");
        for (g.alternatives, 0..) |alt, i| {
            if (i > 0) try w.writeAll(", ");
            for (alt, 0..) |kn, j| {
                if (j > 0) try w.writeAll(" + ");
                try w.writeAll(kn);
            }
        }
        try w.writeAll("]\n");
    }
    try w.writeAll(" */\n");
}

fn writeFormInterface(w: *std.Io.Writer, p: Model.Plugin_, f: Model.Form) std.Io.Writer.Error!void {
    try w.writeAll("export interface ");
    try writeFormTypeName(w, p.name, f.name);
    try w.writeAll(" {\n");
    try w.writeAll("  $form: \"");
    try w.writeAll(f.name);
    try w.writeAll("\";\n");
    try w.writeAll("  $ns: \"");
    try w.writeAll(p.name);
    try w.writeAll("\";\n");
    const indices = Model.sortedKeys(f.keys);
    for (indices.slice()) |idx| {
        try writeKey(w, f.keys[idx], "  ");
    }
    switch (f.positional) {
        .none => {},
        .any => try w.writeAll("  $children?: unknown[];\n"),
        .kind => |shape| {
            try writeChildCountsDoc(w, shape, "  ");
            try w.writeAll("  $children?: Array<");
            try writeShape(w, shape);
            try w.writeAll(">;\n");
        },
    }
    if (f.open) {
        try w.writeAll("  [key: string]: unknown;\n");
    }
    try w.writeAll("}\n\n");
}

/// TypeScript cannot express "exactly one element of this union in an
/// array" — no amount of tuple or template trickery reaches a per-member
/// count over a heterogeneous array. So the bounds ride as a doc comment
/// above the `$children` member and nothing more. Documented in
/// `docs/SCHEMA_EXPORT.md`: a silently weaker `.d.ts` is worse than a
/// documented one, because a consumer would otherwise read the absence of
/// a constraint as the absence of a rule.
///
/// Emitted for the two block-shaped form emitters only. The inline
/// local-form literal carries no JSDoc at all by design (it stays on one
/// line, see `writeInlineKey`), so it is left alone rather than given the
/// project's only single-line annotation.
fn writeChildCountsDoc(
    w: *std.Io.Writer,
    shape: Model.ValueShape,
    indent: []const u8,
) std.Io.Writer.Error!void {
    const refs = switch (shape) {
        .form_heads => |r| r,
        else => return,
    };
    var any = false;
    for (refs) |ref| {
        if (ref.isBounded()) {
            any = true;
            break;
        }
    }
    if (!any) return;

    try w.writeAll(indent);
    try w.writeAll("/** Positional counts (not expressible in TS):");
    var first = true;
    for (refs) |ref| {
        if (!ref.isBounded()) continue;
        try w.writeAll(if (first) " " else "; ");
        first = false;
        try w.writeAll(ref.name);
        try w.writeAll(": ");
        if (ref.max) |mx| {
            if (ref.min == mx) {
                try w.print("{d}", .{mx});
            } else {
                try w.print("{d}..{d}", .{ ref.min, mx });
            }
        } else {
            try w.print("{d}..", .{ref.min});
        }
    }
    try w.writeAll(" */\n");
}

/// Emit a discriminated form as a union of per-variant object types.
/// Each branch repeats `$form`/`$ns`/common keys, overrides the
/// discriminant key with a `Symbol_<"<when>">` brand, then layers the
/// variant overlay keys. TS narrows on the discriminant brand: a check
/// against `track.kind.$sym === "kick"` selects the matching branch
/// and the rest of the branch's properties become available.
fn writeDiscriminatedFormType(
    w: *std.Io.Writer,
    p: Model.Plugin_,
    f: Model.Form,
    d: Model.Discriminator,
) std.Io.Writer.Error!void {
    try w.writeAll("export type ");
    try writeFormTypeName(w, p.name, f.name);
    try w.writeAll(" =");
    for (d.variants) |v| {
        try w.writeAll("\n  | {\n");
        try w.writeAll("      $form: \"");
        try w.writeAll(f.name);
        try w.writeAll("\";\n");
        try w.writeAll("      $ns: \"");
        try w.writeAll(p.name);
        try w.writeAll("\";\n");
        // Common + discriminant keys, sorted alphabetically. The
        // discriminant gets its brand narrowed to the variant's `when`.
        const indices = Model.sortedKeys(f.keys);
        for (indices.slice()) |idx| {
            const k = f.keys[idx];
            if (std.mem.eql(u8, k.name, d.key_name)) {
                try writeDiscriminantKey(w, k, v.when, "      ");
            } else {
                try writeKey(w, k, "      ");
            }
        }
        // Variant overlay keys.
        const v_indices = Model.sortedKeys(v.keys);
        for (v_indices.slice()) |idx| {
            try writeKey(w, v.keys[idx], "      ");
        }
        switch (f.positional) {
            .none => {},
            .any => try w.writeAll("      $children?: unknown[];\n"),
            .kind => |shape| {
                try writeChildCountsDoc(w, shape, "      ");
                try w.writeAll("      $children?: Array<");
                try writeShape(w, shape);
                try w.writeAll(">;\n");
            },
        }
        if (f.open) try w.writeAll("      [key: string]: unknown;\n");
        try w.writeAll("    }");
    }
    try w.writeAll(";\n\n");
}

fn writeKey(w: *std.Io.Writer, k: Model.Key, indent: []const u8) std.Io.Writer.Error!void {
    const rich_members = richMembersOf(k.value);
    const has_expr_default = if (k.default) |d| d == .expression else false;
    const bounds_anno = numericBoundsOf(k.value);
    const string_anno = stringBoundsOf(k.value);
    const cross_ref_anno = crossRefOf(k.value);
    const unit_anno = unitOf(k.value);

    const has_axis_jsdoc = bounds_anno != null or string_anno != null or
        cross_ref_anno != null or unit_anno != null or k.requires.len != 0;
    const needs_doc = k.description.len > 0 or has_expr_default or
        rich_members != null or has_axis_jsdoc;

    if (needs_doc) {
        const use_block = rich_members != null or has_axis_jsdoc;
        if (use_block) {
            try w.writeAll(indent);
            try w.writeAll("/**\n");
            if (k.description.len > 0) {
                try w.writeAll(indent);
                try w.writeAll(" * ");
                try w.writeAll(k.description);
                try w.writeByte('\n');
            }
            if (has_expr_default) {
                try w.writeAll(indent);
                try w.writeAll(" * @default computed via `");
                try w.writeAll(k.default.?.expression.head);
                try w.writeAll("`\n");
            }
            if (rich_members) |members| {
                for (members) |m| try writeMemberDocLine(w, m, indent);
            }
            if (bounds_anno) |b| try writeNumericBoundsDoc(w, b, indent);
            if (k.requires.len != 0) {
                // Not expressible in a plain interface — it would need a
                // discriminated union over which keys are present.
                try w.writeAll(indent);
                try w.writeAll(" * @sjon-requires ");
                for (k.requires, 0..) |r, i| {
                    if (i != 0) try w.writeAll(", ");
                    try w.writeAll(r);
                }
                try w.writeByte('\n');
            }
            if (string_anno) |sb| try writeStringBoundsDoc(w, sb, indent);
            if (cross_ref_anno) |cr| try writeCrossRefDoc(w, cr, indent);
            if (unit_anno) |u| try writeUnitDoc(w, u, indent);
            try w.writeAll(indent);
            try w.writeAll(" */\n");
        } else {
            try w.writeAll(indent);
            try w.writeAll("/** ");
            if (k.description.len > 0) try w.writeAll(k.description);
            if (has_expr_default) {
                if (k.description.len > 0) try w.writeByte(' ');
                try w.writeAll("@default computed via `");
                try w.writeAll(k.default.?.expression.head);
                try w.writeByte('`');
            }
            try w.writeAll(" */\n");
        }
    }

    try w.writeAll(indent);
    try writeKeyName(w, k.name);
    if (k.optional) try w.writeByte('?');
    try w.writeAll(": ");
    try writeShape(w, k.value);
    try w.writeAll(";\n");
}

fn writeNumericBoundsDoc(
    w: *std.Io.Writer,
    b: Model.NumericBounds,
    indent: []const u8,
) std.Io.Writer.Error!void {
    if (b.min) |min| {
        try w.writeAll(indent);
        try w.writeAll(if (b.exclusive_min) " * @exclusiveMinimum " else " * @minimum ");
        try printF64(w, min.value);
        if (min.unit) |u| {
            try w.writeAll(" (");
            try w.writeAll(u);
            try w.writeByte(')');
        }
        if (min.exceedsF64Precision()) {
            try w.writeAll(" [exact-int >2^53]");
        }
        try w.writeByte('\n');
    }
    if (b.max) |max| {
        try w.writeAll(indent);
        try w.writeAll(if (b.exclusive_max) " * @exclusiveMaximum " else " * @maximum ");
        try printF64(w, max.value);
        if (max.unit) |u| {
            try w.writeAll(" (");
            try w.writeAll(u);
            try w.writeByte(')');
        }
        if (max.exceedsF64Precision()) {
            try w.writeAll(" [exact-int >2^53]");
        }
        try w.writeByte('\n');
    }
    if (b.integer) {
        try w.writeAll(indent);
        try w.writeAll(" * @sjon-integer true\n");
    }
    // Not expressible in the type system — TS has no divisibility
    // constraint — so it rides the JSDoc alongside `@sjon-integer`.
    if (b.multiple_of) |mo| {
        try w.writeAll(indent);
        try w.writeAll(" * @sjon-multiple-of ");
        try printF64(w, mo.value);
        if (mo.unit) |u| {
            try w.writeAll(" (");
            try w.writeAll(u);
            try w.writeByte(')');
        }
        try w.writeByte('\n');
    }
}

fn writeStringBoundsDoc(
    w: *std.Io.Writer,
    sb: Model.StringBounds,
    indent: []const u8,
) std.Io.Writer.Error!void {
    if (sb.min_len) |n| {
        try w.writeAll(indent);
        try w.writeAll(" * @minLength ");
        try printDecimal(w, n);
        try w.writeByte('\n');
    }
    if (sb.max_len) |n| {
        try w.writeAll(indent);
        try w.writeAll(" * @maxLength ");
        try printDecimal(w, n);
        try w.writeByte('\n');
    }
    if (sb.pattern) |p| {
        try w.writeAll(indent);
        try w.writeAll(" * @pattern ");
        try w.writeAll(p);
        try w.writeByte('\n');
    }
    if (sb.format) |f| {
        try w.writeAll(indent);
        try w.writeAll(" * @format ");
        try w.writeAll(@tagName(f));
        try w.writeByte('\n');
    }
}

fn writeCrossRefDoc(
    w: *std.Io.Writer,
    cr: Model.CrossRef,
    indent: []const u8,
) std.Io.Writer.Error!void {
    try w.writeAll(indent);
    try w.writeAll(" * @sjon-cross-ref target=`");
    try writeJoined(w, cr.targets, " | ");
    // Prose names only what the route can carry. The provider route has
    // no `name-key` (rejected beside a provider) and no `acyclic` (cycle
    // edges need per-name declaration sites), so printing the struct's
    // defaults for them would read as a claim rather than a placeholder.
    // The structured annotations — `x-sjon-cross-ref` and the IR — keep
    // the full field set; only the human-facing renderings branch.
    if (cr.provider) |p| {
        try w.writeAll("` provider=`");
        try w.writeAll(p);
        if (cr.source_key) |sk| {
            try w.writeAll("` source-key=`");
            try w.writeAll(sk);
        }
        try w.writeByte('`');
    } else {
        try w.writeAll("` name-key=`");
        try w.writeAll(cr.name_key);
        try w.writeAll("` acyclic=");
        try w.writeAll(if (cr.acyclic) "true" else "false");
    }
    if (cr.scope_form) |sf| {
        try w.writeAll(" scope-form=`");
        try w.writeAll(sf);
        try w.writeByte('`');
    }
    try w.writeByte('\n');
}

fn writeUnitDoc(
    w: *std.Io.Writer,
    u: Model.UnitShape,
    indent: []const u8,
) std.Io.Writer.Error!void {
    try w.writeAll(indent);
    try w.writeAll(" * @sjon-unit required=");
    try w.writeAll(if (u.required) "true" else "false");
    if (u.allowed.len > 0) {
        try w.writeAll(" allowed=[");
        for (u.allowed, 0..) |s, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(s);
        }
        try w.writeByte(']');
    }
    try w.writeByte('\n');
    if (u.bounds) |b| try writeNumericBoundsDoc(w, b, indent);
}

fn numericBoundsOf(shape: Model.ValueShape) ?Model.NumericBounds {
    return switch (shape) {
        .number_bounded => |b| b,
        else => null,
    };
}

fn stringBoundsOf(shape: Model.ValueShape) ?Model.StringBounds {
    return switch (shape) {
        .string_with_bounds => |sb| sb,
        else => null,
    };
}

fn crossRefOf(shape: Model.ValueShape) ?Model.CrossRef {
    return switch (shape) {
        .cross_ref => |cr| cr,
        else => null,
    };
}

fn unitOf(shape: Model.ValueShape) ?Model.UnitShape {
    return switch (shape) {
        .number_with_unit => |u| u,
        else => null,
    };
}

fn printF64(w: *std.Io.Writer, v: f64) std.Io.Writer.Error!void {
    var buf: [64]u8 = undefined;
    const trunc: f64 = @trunc(v);
    const is_integer = trunc == v and @abs(v) < 1e18;
    const s = if (is_integer)
        std.fmt.bufPrint(&buf, "{d:.0}", .{v}) catch return error.WriteFailed
    else
        std.fmt.bufPrint(&buf, "{d}", .{v}) catch return error.WriteFailed;
    try w.writeAll(s);
}

fn writeMemberDocLine(w: *std.Io.Writer, m: Model.Member, indent: []const u8) std.Io.Writer.Error!void {
    try w.writeAll(indent);
    try w.writeAll(" * @member ");
    try w.writeAll(m.name);
    if (m.label.len > 0) {
        try w.writeAll(" — ");
        try w.writeAll(m.label);
    }
    if (m.description.len > 0) {
        try w.writeAll(": ");
        try w.writeAll(m.description);
    }
    if (m.deprecated) {
        try w.writeAll(" @deprecated");
        if (m.deprecation_message.len > 0) {
            try w.writeByte(' ');
            try w.writeAll(m.deprecation_message);
        }
    }
    try w.writeByte('\n');
}

fn writeDiscriminantKey(
    w: *std.Io.Writer,
    k: Model.Key,
    when: []const u8,
    indent: []const u8,
) std.Io.Writer.Error!void {
    if (k.description.len > 0) {
        try w.writeAll(indent);
        try w.writeAll("/** ");
        try w.writeAll(k.description);
        try w.writeAll(" */\n");
    }
    try w.writeAll(indent);
    try writeKeyName(w, k.name);
    try w.writeAll(": Symbol_<\"");
    try w.writeAll(when);
    try w.writeAll("\">;\n");
}

fn writeKeyName(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    if (needsQuotedKey(name)) {
        try w.writeByte('"');
        try writeDollarEscaped(w, name);
        try w.writeByte('"');
    } else {
        try w.writeAll(name);
    }
}

fn needsQuotedKey(name: []const u8) bool {
    if (name.len == 0) return true;
    if (!isIdentStart(name[0])) return true;
    for (name[1..]) |c| if (!isIdentCont(c)) return true;
    return false;
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

/// Apply the `$$`-escape used on the canonical JSON wire so the TS
/// describes the on-wire object key for a `$`-prefixed user key.
fn writeDollarEscaped(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    if (name.len > 0 and name[0] == '$') {
        try w.writeByte('$');
    }
    try w.writeAll(name);
}

// ---------------------------------------------------------------------------
// Shape emission — emits a TS type expression.
// ---------------------------------------------------------------------------

fn writeShape(w: *std.Io.Writer, shape: Model.ValueShape) std.Io.Writer.Error!void {
    switch (shape) {
        .any => try w.writeAll("unknown"),
        .nil => try w.writeAll("null"),
        .boolean => try w.writeAll("boolean"),
        .number => try w.writeAll("number"),
        // A `:repr`-tagged number renders as its branded GPU alias
        // (`F32`…`F16`); a plain bounded number stays `number` (min/max are
        // not expressible in a TS structural type — they're JSON-Schema /
        // JSDoc concerns).
        .number_bounded => |b| try w.writeAll(if (b.repr) |r| reprTsAlias(r) else "number"),
        .number_i64, .number_u64 => try w.writeAll("bigint"),
        .string => try w.writeAll("string"),
        .string_with_bounds => try w.writeAll("string"),
        .symbol => try w.writeAll("Symbol_"),
        .keyword => try w.writeAll("Keyword"),
        .date => try w.writeAll("SjonDate"),
        .time => try w.writeAll("SjonTime"),
        .expr => try w.writeAll("SjonExpr"),
        .symbol_members => |names| try writeBrandedUnion(w, "Symbol_", names),
        .symbol_members_rich => |members| try writeRichBrandedUnion(w, "Symbol_", members),
        .string_members => |names| try writeStringLiteralUnion(w, names),
        .string_members_rich => |members| try writeRichStringLiteralUnion(w, members),
        .vector => |vs| {
            if (vs.len) |n| {
                // Fixed-length vector → readonly tuple type.
                try w.writeAll("readonly [");
                var i: u16 = 0;
                while (i < n) : (i += 1) {
                    if (i > 0) try w.writeAll(", ");
                    try writeShape(w, vs.element.*);
                }
                try w.writeAll("]");
            } else {
                try w.writeAll("Array<");
                try writeShape(w, vs.element.*);
                try w.writeAll(">");
            }
        },
        .form_any => try w.writeAll("{ readonly $form: string; readonly $ns?: string }"),
        .form_heads => |refs| {
            // Union of `{$form: "<name>"}` literals. TS narrows on the
            // `$form` discriminant. In per-plugin mode, cross-plugin
            // refs use the imported type name (`<Other>_<Name>`) so the
            // `import type` line at the top of the file actually carries
            // weight in the consumer's type tree.
            for (refs, 0..) |ref, i| {
                if (i > 0) try w.writeAll(" | ");
                const use_imported = if (current_filter) |this|
                    ref.plugin.len > 0 and !std.mem.eql(u8, ref.plugin, this)
                else
                    false;
                if (use_imported) {
                    try writeFormTypeName(w, ref.plugin, ref.name);
                } else {
                    try w.writeAll("{ readonly $form: \"");
                    try w.writeAll(ref.name);
                    try w.writeAll("\" }");
                }
            }
        },
        .form_locals => |forms| {
            // Inline anonymous union of object literals (one per local form),
            // plus a trailing open generic branch for the additive global
            // fallback. TS narrows on the `$form` discriminant; the open
            // branch makes the slot accept any global form (required-key
            // enforcement on that branch is SJON-runtime-only — the
            // open-branch round-trip caveat in SCHEMA_EXPORT.md).
            for (forms) |lf| {
                try writeInlineLocalForm(w, lf);
                try w.writeAll(" | ");
            }
            try w.writeAll("{ readonly $form: string; readonly $ns?: string }");
        },
        .cross_ref => |cr| {
            // A group is a union of brands, one per target — the same
            // shape a `:union` of cross-ref kinds would produce, and the
            // only honest TS reading of "this name may come from either
            // form". One target emits exactly what it always did.
            for (cr.targets, 0..) |t, i| {
                if (i > 0) try w.writeAll(" | ");
                try w.writeAll("CrossRef<\"");
                try w.writeAll(t);
                try w.writeAll("\">");
            }
        },
        .union_of => |alts| {
            for (alts, 0..) |alt, i| {
                if (i > 0) try w.writeAll(" | ");
                try writeShape(w, alt.shape);
            }
        },
        .number_with_unit => |u| {
            if (u.allowed.len == 0) {
                try w.writeAll("readonly [number, string]");
            } else {
                for (u.allowed, 0..) |unit, i| {
                    if (i > 0) try w.writeAll(" | ");
                    try w.writeAll("readonly [number, \"");
                    try w.writeAll(unit);
                    try w.writeAll("\"]");
                }
            }
        },
        .unresolved_named => try w.writeAll("unknown"),
    }
}

/// Emit a slot-local form as an inline anonymous object-literal type (no
/// `export interface NAME` header — locals have no global type name). Mirrors
/// `writeFormInterface` / `writeDiscriminatedFormType` bodies compactly on one
/// line. `$ns` is optional (locals are bare-invoked, so the JSON bridge omits
/// it). A discriminated local emits a parenthesised union of per-variant
/// branches so TS narrows on the discriminant brand, matching the JSON side's
/// if/then reuse.
fn writeInlineLocalForm(w: *std.Io.Writer, f: Model.Form) std.Io.Writer.Error!void {
    if (f.discriminator) |d| {
        try w.writeByte('(');
        for (d.variants, 0..) |v, vi| {
            if (vi > 0) try w.writeAll(" | ");
            try w.writeAll("{ $form: \"");
            try w.writeAll(f.name);
            try w.writeAll("\"; $ns?: string;");
            const indices = Model.sortedKeys(f.keys);
            for (indices.slice()) |idx| {
                const k = f.keys[idx];
                try w.writeByte(' ');
                if (std.mem.eql(u8, k.name, d.key_name)) {
                    try writeInlineDiscriminantKey(w, k, v.when);
                } else {
                    try writeInlineKey(w, k);
                }
            }
            const v_indices = Model.sortedKeys(v.keys);
            for (v_indices.slice()) |idx| {
                try w.writeByte(' ');
                try writeInlineKey(w, v.keys[idx]);
            }
            if (f.open) try w.writeAll(" [key: string]: unknown;");
            try w.writeAll(" }");
        }
        try w.writeByte(')');
        return;
    }
    try w.writeAll("{ $form: \"");
    try w.writeAll(f.name);
    try w.writeAll("\"; $ns?: string;");
    const indices = Model.sortedKeys(f.keys);
    for (indices.slice()) |idx| {
        try w.writeByte(' ');
        try writeInlineKey(w, f.keys[idx]);
    }
    switch (f.positional) {
        .none => {},
        .any => try w.writeAll(" $children?: unknown[];"),
        .kind => |shape| {
            try w.writeAll(" $children?: Array<");
            try writeShape(w, shape);
            try w.writeAll(">;");
        },
    }
    if (f.open) try w.writeAll(" [key: string]: unknown;");
    try w.writeAll(" }");
}

/// Compact single-line key for an inline local-form literal: `name?: T;`
/// (no JSDoc / indentation — the inline union stays on one line). The value
/// shape recurses through `writeShape`, so a nested local slot expands too.
fn writeInlineKey(w: *std.Io.Writer, k: Model.Key) std.Io.Writer.Error!void {
    try writeKeyName(w, k.name);
    if (k.optional) try w.writeByte('?');
    try w.writeAll(": ");
    try writeShape(w, k.value);
    try w.writeByte(';');
}

/// Compact discriminant key for an inline local-form variant branch:
/// `kind: Symbol_<"<when>">;`. Mirrors `writeDiscriminantKey`.
fn writeInlineDiscriminantKey(w: *std.Io.Writer, k: Model.Key, when: []const u8) std.Io.Writer.Error!void {
    try writeKeyName(w, k.name);
    try w.writeAll(": Symbol_<\"");
    try w.writeAll(when);
    try w.writeAll("\">;");
}

fn writeBrandedUnion(w: *std.Io.Writer, brand: []const u8, names: []const []const u8) std.Io.Writer.Error!void {
    if (names.len == 0) {
        try w.writeAll(brand);
        return;
    }
    for (names, 0..) |n, i| {
        if (i > 0) try w.writeAll(" | ");
        try w.writeAll(brand);
        try w.writeAll("<\"");
        try w.writeAll(n);
        try w.writeAll("\">");
    }
}

/// Write `parts` separated by `sep`. One part writes just that part, so a
/// single-target cross-ref annotation is byte-identical to the
/// pre-group output.
fn writeJoined(
    w: *std.Io.Writer,
    parts: []const []const u8,
    sep: []const u8,
) std.Io.Writer.Error!void {
    for (parts, 0..) |part, i| {
        if (i > 0) try w.writeAll(sep);
        try w.writeAll(part);
    }
}

fn writeStringLiteralUnion(w: *std.Io.Writer, names: []const []const u8) std.Io.Writer.Error!void {
    if (names.len == 0) {
        try w.writeAll("string");
        return;
    }
    for (names, 0..) |n, i| {
        if (i > 0) try w.writeAll(" | ");
        try w.writeByte('"');
        try w.writeAll(n);
        try w.writeByte('"');
    }
}

/// Rich-member branded union — same structural type as compact, but
/// receives a JSDoc enrichment block at the consuming key (see
/// `writeKey`). The TS compiler ignores the JSDoc when computing the
/// type; editors and language servers surface it as hover content.
///
/// A digit-leading member breaks the brand: a document writes `2d` as a
/// unit-bearing number, which the JSON bridge encodes as a
/// `[magnitude, unit]` pair, so the alternative is the tuple type
/// `number_with_unit` already uses rather than `Symbol_<"2d">`. Getting
/// this wrong would make the `.d.ts` reject a document the validator
/// accepts, so it is not a cosmetic difference.
fn writeRichBrandedUnion(w: *std.Io.Writer, brand: []const u8, members: []const Model.Member) std.Io.Writer.Error!void {
    if (members.len == 0) {
        try w.writeAll(brand);
        return;
    }
    for (members, 0..) |m, i| {
        if (i > 0) try w.writeAll(" | ");
        if (m.numeric_spelling) |s| {
            try w.print("readonly [{d}, \"{s}\"]", .{ s.magnitude, s.unit });
            continue;
        }
        try w.writeAll(brand);
        try w.writeAll("<\"");
        try w.writeAll(m.name);
        try w.writeAll("\">");
    }
}

fn writeRichStringLiteralUnion(w: *std.Io.Writer, members: []const Model.Member) std.Io.Writer.Error!void {
    if (members.len == 0) {
        try w.writeAll("string");
        return;
    }
    for (members, 0..) |m, i| {
        if (i > 0) try w.writeAll(" | ");
        try w.writeByte('"');
        try w.writeAll(m.name);
        try w.writeByte('"');
    }
}

/// If `shape` carries rich member metadata, return the slice so the
/// caller can enrich the JSDoc block. Returns `null` for any shape
/// that doesn't have per-member annotations to surface.
fn richMembersOf(shape: Model.ValueShape) ?[]const Model.Member {
    return switch (shape) {
        .symbol_members_rich => |m| m,
        .string_members_rich => |m| m,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Per-plugin barrel — a union of every form in the plugin so consumers
// can `Sjon<Plugin> = …` and narrow on `$form`.
// ---------------------------------------------------------------------------

fn writeBarrel(w: *std.Io.Writer, p: Model.Plugin_) std.Io.Writer.Error!void {
    if (p.forms.len == 0) return;
    try w.writeAll("export type Sjon");
    try writePascalCase(w, p.name);
    try w.writeAll(" =");
    for (p.forms) |f| {
        try w.writeAll("\n  | ");
        try writeFormTypeName(w, p.name, f.name);
    }
    try w.writeAll(";\n\n");
}

// ---------------------------------------------------------------------------
// Naming.
// ---------------------------------------------------------------------------

fn writeFormTypeName(w: *std.Io.Writer, plugin_name: []const u8, form_name: []const u8) std.Io.Writer.Error!void {
    try writePascalCase(w, plugin_name);
    try w.writeByte('_');
    try writePascalCase(w, form_name);
}

/// Upper-camel-case a kebab- or snake-case identifier. `fill-rule` →
/// `FillRule`; `circle` → `Circle`. Non-identifier bytes are dropped.
fn writePascalCase(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    var upper_next = true;
    for (name) |c| {
        switch (c) {
            '-', '_', ' ', '/' => upper_next = true,
            else => {
                if (upper_next) {
                    try w.writeByte(std.ascii.toUpper(c));
                    upper_next = false;
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}

fn printDecimal(w: *std.Io.Writer, n: u32) std.Io.Writer.Error!void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return error.WriteFailed;
    try w.writeAll(s);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const SchemaExport = @import("SchemaExport.zig");
const Schema = @import("../Schema.zig");

test "emit: empty model produces just the prelude" {
    const a = testing.allocator;
    const schema: Schema.Schema = .{ .plugins = &.{} };
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "Keyword<") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "Symbol_<") != null);
}

test "emit: single form generates a typed interface" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "test",
        .forms = &.{
            .{
                .name = "row",
                .keys = &.{
                    .{ .name = "n", .value_type = .number, .optional = false },
                    .{ .name = "s", .value_type = .string },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "interface Test_Row") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "$form: \"row\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "$ns: \"test\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "n: number") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "s?: string") != null);
}

test "emit: open form gets index signature" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{.{ .name = "scene", .open = true }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    try testing.expect(std.mem.indexOf(u8, result.ts_types_bytes.?, "[key: string]: unknown") != null);
}

test "emit: typed fixed-length vector becomes a readonly tuple" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{.{
            .name = "f",
            .keys = &.{.{ .name = "pt", .value_type = .{ .named = .{ .name = "point" } } }},
        }},
        .value_kinds = &.{
            .{ .name = "point", .underlying = .vector, .vector = .{ .len = 2, .element = .{ .name = "number" } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    try testing.expect(std.mem.indexOf(u8, result.ts_types_bytes.?, "readonly [number, number]") != null);
}

test "emit: :repr-tagged number renders as its branded GPU alias" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "gpu",
        .forms = &.{.{
            .name = "f",
            .keys = &.{.{ .name = "ch", .value_type = .{ .named = .{ .name = "channel" } } }},
        }},
        .value_kinds = &.{
            .{ .name = "channel", .underlying = .number, .repr = .f32 },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    // The branded alias is declared in the prelude…
    try testing.expect(std.mem.indexOf(u8, bytes, "export type F32 = number & { readonly __sjonRepr?: \"f32\" };") != null);
    // …and the field uses it instead of bare `number`.
    try testing.expect(std.mem.indexOf(u8, bytes, "ch?: F32") != null);
}

test "emit: repr-only kind with no :numeric still brands (u16)" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "gpu",
        .forms = &.{.{
            .name = "f",
            .keys = &.{.{ .name = "w", .value_type = .{ .named = .{ .name = "px" } }, .optional = false }},
        }},
        .value_kinds = &.{
            .{ .name = "px", .underlying = .number, .repr = .u16 },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    try testing.expect(std.mem.indexOf(u8, result.ts_types_bytes.?, "w: U16") != null);
}

test "emit: symbol member-set becomes branded union" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{.{
            .name = "f",
            .keys = &.{.{ .name = "fill", .value_type = .{ .named = .{ .name = "fill-rule" } } }},
        }},
        .value_kinds = &.{
            .{
                .name = "fill-rule",
                .underlying = .symbol,
                .members = .{ .members = &.{ .{ .name = "evenodd" }, .{ .name = "nonzero" } } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "Symbol_<\"evenodd\">") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "Symbol_<\"nonzero\">") != null);
}

test "emit: rich symbol member-set surfaces JSDoc per member" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{.{
            .name = "row",
            .keys = &.{.{ .name = "level", .value_type = .{ .named = .{ .name = "severity" } } }},
        }},
        .value_kinds = &.{
            .{
                .name = "severity",
                .underlying = .symbol,
                .members = .{ .members = &.{
                    .{ .name = "info", .label = "Info", .description = "Routine status." },
                    .{ .name = "fatal", .deprecated = true, .deprecation_message = "Use error." },
                } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    // Structural type: branded union with literal names.
    try testing.expect(std.mem.indexOf(u8, bytes, "Symbol_<\"info\">") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "Symbol_<\"fatal\">") != null);
    // JSDoc: @member lines with label/description and @deprecated.
    try testing.expect(std.mem.indexOf(u8, bytes, "@member info — Info: Routine status.") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "@member fatal @deprecated Use error.") != null);
}

test "emit: rich string member-set surfaces JSDoc per member" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{.{ .name = "row", .keys = &.{.{ .name = "mode", .value_type = .{ .named = .{ .name = "modes" } } }} }},
        .value_kinds = &.{
            .{
                .name = "modes",
                .underlying = .string,
                .members = .{ .members = &.{
                    .{ .name = "auto", .label = "Auto" },
                } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "mode?: \"auto\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "@member auto — Auto") != null);
}

test "emit: exclusive group JSDoc lists cardinality and key bundles" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{
            .{
                .name = "phrase",
                .description = "A note sequence.",
                .keys = &.{
                    .{ .name = "notes", .value_type = .vector, .optional = true },
                    .{ .name = "events", .value_type = .vector, .optional = true },
                },
                .exclusive_groups = &.{
                    .{
                        .cardinality = .exactly_one,
                        .alternatives = &.{ .{ .keys = &.{"notes"} }, .{ .keys = &.{"events"} } },
                    },
                },
            },
            .{
                .name = "tag",
                .keys = &.{
                    .{ .name = "color", .value_type = .string, .optional = true },
                    .{ .name = "shape", .value_type = .string, .optional = true },
                },
                .exclusive_groups = &.{
                    .{
                        .cardinality = .at_most_one,
                        .alternatives = &.{ .{ .keys = &.{"color"} }, .{ .keys = &.{"shape"} } },
                    },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "@sjon-exclusive-group exactly-one [notes, events]") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "@sjon-exclusive-group at-most-one [color, shape]") != null);
    // Description is preserved alongside the group lines.
    try testing.expect(std.mem.indexOf(u8, bytes, "A note sequence.") != null);
}

test "emit: discriminated form becomes a union of per-variant object types" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "kit",
        .forms = &.{.{
            .name = "track",
            .keys = &.{
                .{ .name = "kind", .value_type = .{ .named = .{ .name = "track-kind" } }, .optional = false },
                .{ .name = "name", .value_type = .string, .optional = true },
            },
            .discriminant_idx = 0,
            .variants = &.{
                .{ .when = "kick", .keys = &.{
                    .{ .name = "step", .value_type = .number, .optional = false },
                    .{ .name = "volume", .value_type = .number, .optional = true },
                } },
                .{ .when = "bass", .keys = &.{
                    .{ .name = "sequence", .value_type = .vector, .optional = false },
                } },
            },
        }},
        .value_kinds = &.{
            .{ .name = "track-kind", .underlying = .symbol, .members = .{ .members = &.{ .{ .name = "kick" }, .{ .name = "bass" } } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    // Discriminated form is a `type` (union), not an `interface`.
    try testing.expect(std.mem.indexOf(u8, bytes, "export type Kit_Track =") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "export interface Kit_Track") == null);
    // Per-variant branches narrow the discriminant brand.
    try testing.expect(std.mem.indexOf(u8, bytes, "kind: Symbol_<\"kick\">") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "kind: Symbol_<\"bass\">") != null);
    // Variant overlay keys are present in each branch.
    try testing.expect(std.mem.indexOf(u8, bytes, "step: number") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "sequence: ") != null);
}

test "emit: positional local forms render as inline $children union" {
    // Positional locals lower to `positional = .kind{.form_locals}`, so the
    // `$children` array becomes a typed `Array<…>` of the inline object-literal
    // union (one branch per local head, `$form` brand + keys) plus the open
    // global-fallback branch — the same rendering a keyed local slot produces.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "draw",
        .forms = &.{.{
            .name = "canvas",
            .positional = .any, // loader implies `.any` when locals present
            .local_forms = &.{
                .{ .name = "circle", .keys = &.{.{ .name = "r", .value_type = .number, .optional = false }} },
                .{ .name = "rect" },
            },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    // `$children` is a typed `Array<…>`, not the widened `unknown[]`.
    try testing.expect(std.mem.indexOf(u8, bytes, "$children?: Array<") != null);
    // Each local head brands its `$form` literal in the inline union…
    try testing.expect(std.mem.indexOf(u8, bytes, "$form: \"circle\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "$form: \"rect\"") != null);
    // …and the trailing open branch keeps the additive global fallback open.
    try testing.expect(std.mem.indexOf(u8, bytes, "$form: string") != null);
}

test "emit: bounded head-set counts ride as a $children doc comment" {
    // TS cannot express "exactly one element of this union in an array",
    // so the bounds are prose above the member. Documented as a known
    // weakening in `docs/SCHEMA_EXPORT.md` rather than left implicit.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "gfx",
        .forms = &.{
            .{ .name = "vertex" },
            .{ .name = "fragment" },
            .{ .name = "constant" },
            .{ .name = "render-pipeline", .positional = .{ .kind = .{ .name = "pipeline-section" } } },
        },
        .value_kinds = &.{.{
            .name = "pipeline-section",
            .underlying = .form,
            .heads = .{ .heads = &.{
                .{ .name = "vertex", .min = 1, .max = 1 },
                .{ .name = "fragment", .max = 1 },
                .{ .name = "constant" },
            } },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "Positional counts (not expressible in TS): vertex: 1; fragment: 0..1 */") != null);
    // The unbounded head contributes nothing — the comment lists what is
    // constrained, not every head in the set.
    try testing.expect(std.mem.indexOf(u8, bytes, "constant:") == null);
    // The type itself is unchanged: still the whole-set array.
    try testing.expect(std.mem.indexOf(u8, bytes, "$children?: Array<") != null);
}

test "emit: PascalCase converts kebab + snake to camel" {
    const a = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try writePascalCase(&aw.writer, "fill-rule");
    try testing.expectEqualStrings("FillRule", aw.written());
}
