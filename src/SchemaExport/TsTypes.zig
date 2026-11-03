//! Model → TypeScript `.d.ts` bytes.
//!
//! Emits one interface or type alias per form (named `<plugin>_<form>`
//! PascalCase — an interface for the plain shapes, an alias whose
//! anonymous base is intersected by arm unions when an exclusive group
//! is structurally enforced), one type alias per value-kind, and a
//! barrel `Sjon<plugin>` union for discoverability. The output
//! describes the *canonical* JSON shape of `sjon to-json` — `$form`,
//! `$ns`, `$kw`, `$sym`, etc. — not the source-level S-expression
//! syntax.
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
    const globals = try dedupeGlobalFormNames(a, model);
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    current_global_forms = globals;
    defer current_global_forms = &.{};
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
    const globals = try dedupeGlobalFormNames(a, model);
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    current_global_forms = globals;
    defer current_global_forms = &.{};
    writeAll(&aw.writer, model, warnings, plugin.name) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return aw.toOwnedSlice();
}

threadlocal var current_filter: ?[]const u8 = null;

/// The unqualified-global enumeration a `form_locals` fallback offers
/// beside its local arms: every form name in the model, deduped by name,
/// in declaration order. Set for the duration of one emit (beside
/// `current_filter`) so `writeShape` reaches it without threading a
/// parameter through every writer.
threadlocal var current_global_forms: []const []const u8 = &.{};

/// Compute `current_global_forms`'s value. A bare (unqualified) head is
/// resolved local-first with shadowing at validate time, so the honest
/// unqualified fallback for a locals slot is the global catalog minus
/// the slot's local head names — never an open `$form: string`, which a
/// local value violating its enforced group would satisfy.
fn dedupeGlobalFormNames(a: Allocator, model: Model.Model) Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(a);
    outer: for (model.plugins) |p| {
        for (p.forms) |f| {
            for (names.items) |n| {
                if (std.mem.eql(u8, n, f.name)) continue :outer;
            }
            try names.append(a, f.name);
        }
    }
    return names.toOwnedSlice(a);
}

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
    // The helper rides directly under the brand prelude and before
    // imports/forms, once, and only when something in this file will
    // actually reference it.
    if (fileHasEnforcedGroup(model, filter_plugin)) {
        try w.writeAll(not_all_helper_decl);
        try w.writeByte('\n');
    }
    try w.writeByte('\n');
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
        .form_heads => |hs| {
            for (hs.refs) |ref| {
                // Only a `.global` head names a type in another file. A
                // `.local` body is emitted inline (same as `form_locals`,
                // which this walk also skips) and an `.unresolved` head
                // names nothing at all.
                if (ref.body != .global) continue;
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

/// The `_SjonNotAll` helper, spelled exactly as it must appear once per
/// output file: directly after the brand prelude, non-exported, only when
/// that file contains at least one structurally enforced group. The
/// underscore prefix avoids the barrel a plugin literally named `not-all`
/// would produce (`SjonNotAll`).
const not_all_helper_decl =
    "type _SjonNotAll<K extends string> = K extends K ? { [P in K]?: never } : never;";

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
    } else if (hasEnforcedFormGroup(f)) {
        try writeFormType(w, p, f);
    } else {
        try writeFormInterface(w, p, f);
    }
}

/// True when at least one form-level group on `f` is structurally
/// enforced (closed scope, no defaulted alternative key).
fn hasEnforcedFormGroup(f: Model.Form) bool {
    for (f.exclusive_groups) |g| {
        if (groupState(f, g) == .enforced) return true;
    }
    return false;
}

/// True when `name` is claimed by any enforced group over `scope_keys`
/// (the form's keys, or one variant's overlay). Only enforced groups
/// take their keys out of the base — a defaulted or open group leaves
/// every key where the interface spelling put it.
fn isKeyGroupedEnforced(
    open: bool,
    scope_keys: []const Model.Key,
    groups: []const Model.ExclusiveGroup,
    name: []const u8,
) bool {
    for (groups) |g| {
        if (groupStateForScope(open, scope_keys, g) != .enforced) continue;
        for (g.alternatives) |alt| {
            for (alt) |kn| {
                if (std.mem.eql(u8, kn, name)) return true;
            }
        }
    }
    return false;
}

/// The `Model.Key` named `name` in `scope_keys`, or null. The manifest
/// guarantees every alternative name resolves in its scope; the null arm
/// only exists for hand-built models.
fn scopeKey(keys: []const Model.Key, name: []const u8) ?Model.Key {
    for (keys) |k| {
        if (std.mem.eql(u8, k.name, name)) return k;
    }
    return null;
}

/// Whether this file needs `_SjonNotAll`: any enforced group anywhere in
/// the emitted forms — form-level, variant-scoped, or on a slot-local
/// form reached through a compound shape.
fn fileHasEnforcedGroup(model: Model.Model, filter_plugin: ?[]const u8) bool {
    for (model.plugins) |p| {
        if (filter_plugin) |only| {
            if (!std.mem.eql(u8, p.name, only)) continue;
        }
        for (p.forms) |f| {
            if (formHasEnforcedGroup(f)) return true;
        }
    }
    return false;
}

fn formHasEnforcedGroup(f: Model.Form) bool {
    if (hasEnforcedFormGroup(f)) return true;
    if (f.discriminator) |d| {
        for (d.variants) |v| {
            for (v.exclusive_groups) |g| {
                if (groupStateForScope(f.open, v.keys, g) == .enforced) return true;
            }
        }
    }
    for (f.keys) |k| {
        if (shapeHasEnforcedGroup(k.value)) return true;
    }
    switch (f.positional) {
        .kind => |shape| return shapeHasEnforcedGroup(shape),
        else => {},
    }
    return false;
}

fn shapeHasEnforcedGroup(shape: Model.ValueShape) bool {
    switch (shape) {
        .vector => |vs| return shapeHasEnforcedGroup(vs.element.*),
        .union_of => |alts| {
            for (alts) |alt| {
                if (shapeHasEnforcedGroup(alt.shape)) return true;
            }
            return false;
        },
        .form_locals => |forms| {
            for (forms) |lf| {
                if (formHasEnforcedGroup(lf)) return true;
            }
            return false;
        },
        .form_heads => |hs| {
            for (hs.refs) |ref| {
                switch (ref.body) {
                    .local => |lf| if (formHasEnforcedGroup(lf.*)) return true,
                    else => {},
                }
            }
            return false;
        },
        else => return false,
    }
}

/// Column geometry for the block-shaped arm union. The top-level alias
/// puts pipes at column 2; a variant branch nests four deeper.
const ArmLayout = struct {
    pipe: []const u8,
    key: []const u8,
    close: []const u8,
    cont: []const u8,
};

const arm_layout_top = ArmLayout{
    .pipe = "  ",
    .key = "      ",
    .close = "    ",
    .cont = "      ",
};

const arm_layout_variant = ArmLayout{
    .pipe = "      ",
    .key = "          ",
    .close = "        ",
    .cont = "          ",
};

/// A form with at least one enforced exclusive group emits as an
/// anonymous-base type alias intersected by one arm-union per group,
/// in declaration order:
///
///     export type P_Choice = { base } & (arms…) & (arms…);
///
/// Grouped keys leave the base — even `:optional false` ones — because
/// only an active arm may require them; ordinary base keys keep the
/// interface path's sorted emission. Skipped groups (open, defaulted)
/// contribute no intersection and keep their keys in the base.
fn writeFormType(w: *std.Io.Writer, p: Model.Plugin_, f: Model.Form) std.Io.Writer.Error!void {
    try w.writeAll("export type ");
    try writeFormTypeName(w, p.name, f.name);
    try w.writeAll(" = {\n");
    try w.writeAll("  $form: \"");
    try w.writeAll(f.name);
    try w.writeAll("\";\n");
    try w.writeAll("  $ns: \"");
    try w.writeAll(p.name);
    try w.writeAll("\";\n");
    const indices = Model.sortedKeys(f.keys);
    for (indices.slice()) |idx| {
        if (isKeyGroupedEnforced(f.open, f.keys, f.exclusive_groups, f.keys[idx].name)) continue;
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
    try w.writeAll("}");
    var first = true;
    for (f.exclusive_groups) |g| {
        if (groupState(f, g) != .enforced) continue;
        try w.writeAll(if (first) " & (\n" else ") & (\n");
        first = false;
        try writeGroupArms(w, f.keys, g, arm_layout_top);
    }
    try w.writeAll(");\n\n");
}

/// The arm union of one enforced group, one line per arm at `layout`'s
/// pipe column (`at_most_one` leads with the none-arm). The caller
/// writes the wrapping `& (\n` before and `)` after.
fn writeGroupArms(
    w: *std.Io.Writer,
    scope_keys: []const Model.Key,
    group: Model.ExclusiveGroup,
    layout: ArmLayout,
) std.Io.Writer.Error!void {
    if (group.cardinality == .at_most_one) {
        try w.writeAll(layout.pipe);
        try w.writeAll("| { ");
        var first = true;
        for (group.alternatives) |alt| {
            for (alt) |kn| {
                if (!first) try w.writeAll("; ");
                first = false;
                try writeKeyName(w, kn);
                try w.writeAll("?: never");
            }
        }
        try w.writeAll(" }\n");
    }
    for (group.alternatives, 0..) |_, i| {
        try w.writeAll(layout.pipe);
        try w.writeAll("| ");
        try writeArm(w, scope_keys, group, i, layout, false);
        try w.writeByte('\n');
    }
}

/// The same arm union on one line, for an inline local-form literal:
/// `({ a: number } & _SjonNotAll<"b">) | ({ b: number } & _SjonNotAll<"a">)`.
/// The caller writes the wrapping ` & (` and `)`.
fn writeGroupArmsInline(
    w: *std.Io.Writer,
    scope_keys: []const Model.Key,
    group: Model.ExclusiveGroup,
) std.Io.Writer.Error!void {
    var wrote = false;
    if (group.cardinality == .at_most_one) {
        try w.writeAll("{");
        var first = true;
        for (group.alternatives) |alt| {
            for (alt) |kn| {
                try w.writeAll(if (first) " " else "; ");
                first = false;
                try writeKeyName(w, kn);
                try w.writeAll("?: never");
            }
        }
        try w.writeAll(" }");
        wrote = true;
    }
    for (group.alternatives, 0..) |_, i| {
        if (wrote) try w.writeAll(" | ");
        wrote = true;
        try writeArm(w, scope_keys, group, i, arm_layout_top, true);
    }
}

/// One alternative's arm: the alternative's keys required (original
/// value types, original JSDoc) intersected with one `_SjonNotAll<…>`
/// **per competing alternative**, in declaration order — never one
/// flattened key set, which a partial competitor would slip through.
///
/// Single-line shape when there is exactly one competitor and no key
/// JSDoc to carry; the multi-line shape otherwise (the ruling's
/// `P_Choice`). `inline` forces the single-line shape — inline local
/// literals carry no JSDoc by design.
fn writeArm(
    w: *std.Io.Writer,
    scope_keys: []const Model.Key,
    group: Model.ExclusiveGroup,
    alt_i: usize,
    layout: ArmLayout,
    one_line: bool,
) std.Io.Writer.Error!void {
    const alt = group.alternatives[alt_i];
    const multi = !one_line and (group.alternatives.len > 2 or armNeedsDoc(scope_keys, alt));
    if (!multi) {
        try w.writeAll("({ ");
        var first = true;
        for (alt) |kn| {
            if (!first) try w.writeAll("; ");
            first = false;
            if (scopeKey(scope_keys, kn)) |k| {
                try writeKeyName(w, k.name);
                try w.writeAll(": ");
                try writeShape(w, k.value);
            } else {
                try writeKeyName(w, kn);
                try w.writeAll(": unknown");
            }
        }
        try w.writeAll(" }");
        for (group.alternatives, 0..) |other, j| {
            if (j == alt_i) continue;
            try w.writeAll(" & ");
            try writeNotAllArg(w, other);
        }
        try w.writeAll(")");
        return;
    }
    try w.writeAll("({\n");
    for (alt) |kn| {
        var k = scopeKey(scope_keys, kn) orelse
            Model.Key{ .name = kn, .optional = false, .value = .any };
        k.optional = false;
        try writeKey(w, k, layout.key);
    }
    var n: usize = 0;
    const competitors = group.alternatives.len - 1;
    for (group.alternatives, 0..) |other, j| {
        if (j == alt_i) continue;
        if (n == 0) {
            try w.writeAll(layout.close);
            try w.writeAll("} & ");
        } else {
            try w.writeByte('\n');
            try w.writeAll(layout.cont);
            try w.writeAll("& ");
        }
        try writeNotAllArg(w, other);
        n += 1;
        if (n == competitors) try w.writeAll(")");
    }
    if (n == 0) {
        try w.writeAll(layout.close);
        try w.writeAll("})");
    }
}

/// `_SjonNotAll<"b1" | "b2">` — one competing alternative's key bundle.
fn writeNotAllArg(
    w: *std.Io.Writer,
    alt_names: []const []const u8,
) std.Io.Writer.Error!void {
    try w.writeAll("_SjonNotAll<");
    for (alt_names, 0..) |kn, i| {
        if (i > 0) try w.writeAll(" | ");
        try w.writeByte('"');
        try w.writeAll(kn);
        try w.writeByte('"');
    }
    try w.writeAll(">");
}

/// True when any key of `alt` carries the JSDoc that forces the
/// multi-line arm shape.
fn armNeedsDoc(scope_keys: []const Model.Key, alt: []const []const u8) bool {
    for (alt) |kn| {
        if (scopeKey(scope_keys, kn)) |k| {
            if (keyNeedsDoc(k)) return true;
        }
    }
    return false;
}

/// Form-level JSDoc: description (if any) followed by one
/// `@sjon-exclusive-group` line per exclusive group on the form. The
/// annotation is emitted for every group state; closed, default-free
/// groups additionally get structural arms (see `writeForm`), while
/// open and defaulted groups stay annotation-only. Matches the JSON
/// Schema's `x-sjon-exclusive-groups` annotation.
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
    try writeExclusiveGroupLines(w, f.exclusive_groups, "");
    try w.writeAll(" */\n");
}

/// One `* @sjon-exclusive-group …` content line per group, prefixed by
/// `indent`. Shared by the form-level doc (`""`) and the per-variant
/// branch doc (`"  "`) so both scopes spell the annotation identically.
fn writeExclusiveGroupLines(
    w: *std.Io.Writer,
    groups: []const Model.ExclusiveGroup,
    indent: []const u8,
) std.Io.Writer.Error!void {
    for (groups) |g| {
        try w.writeAll(indent);
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
}

/// Eligibility of one exclusive group for structural emission.
pub const GroupState = enum { enforced, skipped_open, defaulted };

/// Form-scoped eligibility decision.
pub fn groupState(form: Model.Form, group: Model.ExclusiveGroup) GroupState {
    return groupStateForScope(form.open, form.keys, group);
}

/// The scope a group constrains: a form's keys, or one variant's overlay
/// keys. `open` is the scope's own openness.
pub fn groupStateForScope(
    open: bool,
    keys: []const Model.Key,
    group: Model.ExclusiveGroup,
) GroupState {
    // An open scope round-trips unknown keys, and the runtime bypasses the
    // group sweep for it, so a structural arm here would reject documents
    // the validator accepts. Skipping wins over the default check: either
    // way the group contributes no arm.
    if (open) return .skipped_open;
    for (group.alternatives) |alternative| {
        for (alternative) |name| {
            // Any defaulted alternative skips the *whole* group, not just
            // that alternative: defaulted participation depends on whether
            // a sibling is fully author-present, so the ordinary presence
            // union is not equivalent.
            if (scopeKeyHasDefault(keys, name)) return .defaulted;
        }
    }
    return .enforced;
}

fn scopeKeyHasDefault(keys: []const Model.Key, name: []const u8) bool {
    for (keys) |k| {
        if (std.mem.eql(u8, k.name, name)) return k.default != null;
    }
    return false;
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
    const hs = switch (shape) {
        .form_heads => |h| h,
        else => return,
    };
    if (!hs.anyBounded()) return;

    try w.writeAll(indent);
    try w.writeAll("/** Positional counts (not expressible in TS):");
    var first = true;
    for (hs.refs) |ref| {
        if (!ref.isBounded()) continue;
        try w.writeAll(if (first) " " else "; ");
        first = false;
        try w.writeAll(ref.name);
        try w.writeAll(": ");
        try writeCountRange(w, ref.min, ref.max);
    }
    // The set's own count, named `any of the set` rather than by a head —
    // a reader has to be able to tell "at most one buffer" from "at most
    // one resource of any kind", and the two sit on the same line.
    if (hs.isBounded()) {
        try w.writeAll(if (first) " " else "; ");
        try w.writeAll("any of the set: ");
        try writeCountRange(w, hs.min_children, hs.max_children);
    }
    try w.writeAll(" */\n");
}

/// `2` for an exact count, `0..1` for a range, `1..` for a floor with no
/// ceiling. Shared by the per-head entries and the set's so the two read
/// alike on one line.
fn writeCountRange(w: *std.Io.Writer, min: u16, max: ?u16) std.Io.Writer.Error!void {
    if (max) |mx| {
        if (min == mx) {
            try w.print("{d}", .{mx});
        } else {
            try w.print("{d}..{d}", .{ min, mx });
        }
    } else {
        try w.print("{d}..", .{min});
    }
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
    // A form-level enforced group constrains keys every branch repeats,
    // so it intersects the whole union — parenthesised, because `|`
    // binds looser than `&` and a bare branch tail would constrain only
    // the last branch. Mirrors the JSON Schema side's allOf chain.
    const wrap = hasEnforcedFormGroup(f);
    if (wrap) {
        try w.writeAll(" = (");
    } else {
        try w.writeAll(" =");
    }
    for (d.variants) |v| {
        try writeDiscriminatedBranch(w, p, f, d, .{ .list = v.when }, v.keys, v.exclusive_groups);
    }
    // Members no variant selects get one residual branch — common keys
    // only, discriminant narrowed to exactly those members — so the union
    // covers the whole member set the validator accepts.
    if (discriminantKey(f, d)) |dk| {
        if (hasResidualMembers(dk, d)) {
            try writeDiscriminatedBranch(w, p, f, d, .{ .residual = .{ .members = dk.value, .d = d } }, &.{}, &.{});
        }
    }
    if (wrap) {
        try w.writeAll("\n)");
        for (f.exclusive_groups) |g| {
            if (groupState(f, g) != .enforced) continue;
            try w.writeAll(" & (\n");
            try writeGroupArms(w, f.keys, g, arm_layout_top);
            try w.writeAll(")");
        }
    }
    try w.writeAll(";\n\n");
}

/// One `| { … }` branch of a discriminated form's union: `$form`/`$ns`,
/// the common keys with the discriminant narrowed to `when`, then
/// `overlay` (a variant's keys, or none for the residual branch). A
/// variant carrying scoped exclusive groups gets their annotation as a
/// doc block above the branch — the group constrains that variant's
/// keys only, so the form-level doc and the residual branch stay clean.
/// When any of those groups is enforced, the branch object becomes an
/// anonymous base intersected by the group's arm union (`| ({ … } &
/// (…))`); form-level enforced groups remove their keys from every
/// branch instead, their arms riding outside the union.
fn writeDiscriminatedBranch(
    w: *std.Io.Writer,
    p: Model.Plugin_,
    f: Model.Form,
    d: Model.Discriminator,
    when: WhenSet,
    overlay: []const Model.Key,
    groups: []const Model.ExclusiveGroup,
) std.Io.Writer.Error!void {
    var any_enforced = false;
    for (groups) |g| {
        if (groupStateForScope(f.open, overlay, g) == .enforced) any_enforced = true;
    }
    if (groups.len > 0) {
        try w.writeAll("\n  /**\n");
        try writeExclusiveGroupLines(w, groups, "  ");
        try w.writeAll("  */\n");
        try w.writeAll(if (any_enforced) "  | ({\n" else "  | {\n");
    } else {
        try w.writeAll("\n  | {\n");
    }
    try w.writeAll("      $form: \"");
    try w.writeAll(f.name);
    try w.writeAll("\";\n");
    try w.writeAll("      $ns: \"");
    try w.writeAll(p.name);
    try w.writeAll("\";\n");
    // Common + discriminant keys, sorted alphabetically. The
    // discriminant gets its brand narrowed to the branch's `when`; keys
    // claimed by a form-level enforced group leave for its arms.
    const indices = Model.sortedKeys(f.keys);
    for (indices.slice()) |idx| {
        const k = f.keys[idx];
        if (isKeyGroupedEnforced(f.open, f.keys, f.exclusive_groups, k.name)) continue;
        if (std.mem.eql(u8, k.name, d.key_name)) {
            try writeDiscriminantKey(w, k, when, "      ");
        } else {
            try writeKey(w, k, "      ");
        }
    }
    // Variant overlay keys; those claimed by an enforced variant group
    // leave the base for that group's arms.
    const v_indices = Model.sortedKeys(overlay);
    for (v_indices.slice()) |idx| {
        if (isKeyGroupedEnforced(f.open, overlay, groups, overlay[idx].name)) continue;
        try writeKey(w, overlay[idx], "      ");
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
    if (any_enforced) {
        // The base object closes exactly once, before the first enforced
        // group's union; each further group joins with `) & (`. A `} & (`
        // per group would emit a stray `}` for every group after the
        // first and the file would not parse.
        var first_group = true;
        for (groups) |g| {
            if (groupStateForScope(f.open, overlay, g) != .enforced) continue;
            try w.writeAll(if (first_group) "    } & (\n" else "    ) & (\n");
            first_group = false;
            try writeGroupArms(w, overlay, g, arm_layout_variant);
        }
        try w.writeAll("    ))");
    } else {
        try w.writeAll("    }");
    }
}

/// Whether `k`'s slot renders a JSDoc block/line above the property —
/// shared by `writeKey` and the multi-line arm shape decision.
fn keyNeedsDoc(k: Model.Key) bool {
    const rich_members = richMembersOf(k.value);
    const has_expr_default = if (k.default) |d| d == .expression else false;
    const bounds_anno = numericBoundsOf(k.value);
    const string_anno = stringBoundsOf(k.value);
    const cross_ref_anno = crossRefOf(k.value);
    const unit_anno = unitOf(k.value);

    const has_axis_jsdoc = bounds_anno != null or string_anno != null or
        cross_ref_anno != null or unit_anno != null or k.requires.len != 0;
    return k.description.len > 0 or has_expr_default or
        rich_members != null or has_axis_jsdoc;
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
    const needs_doc = keyNeedsDoc(k);

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
    // `{d}` on a non-integer f64 writes the full expansion (`1e-70` is 72
    // characters); sized from std's bound so a legal bound never turns
    // into WriteFailed.
    var buf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
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
    when: WhenSet,
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
    try w.writeAll(": ");
    try writeWhenBrand(w, when);
    try w.writeAll(";\n");
}

/// The discriminant values one union branch stands for: a variant's `:when`
/// list, or the **residual** — every member of the discriminant's set that
/// no variant selects. Members no variant selects still validate (the
/// discriminant just gains no keys), so they need a branch too, or a
/// `triangle-list` primitive beside a strip-only variant would have no
/// type at all. The residual is written straight off the member shape,
/// skipping covered names, so no list is materialised.
const WhenSet = union(enum) {
    list: []const []const u8,
    residual: struct { members: Model.ValueShape, d: Model.Discriminator },
};

/// `Symbol_<"a">` for a one-value variant, `Symbol_<"a" | "b">` for a
/// multi-value one (or the residual set) — the brand's `S extends string`
/// parameter takes a literal union, so one field spells the whole set.
fn writeWhenBrand(w: *std.Io.Writer, when: WhenSet) std.Io.Writer.Error!void {
    try w.writeAll("Symbol_<");
    switch (when) {
        .list => |list| for (list, 0..) |x, i| {
            if (i > 0) try w.writeAll(" | ");
            try w.writeByte('"');
            try w.writeAll(x);
            try w.writeByte('"');
        },
        .residual => |r| {
            var written: usize = 0;
            var i: usize = 0;
            while (memberNameAt(r.members, i)) |name| : (i += 1) {
                if (variantCovers(r.d, name)) continue;
                if (written > 0) try w.writeAll(" | ");
                try w.writeByte('"');
                try w.writeAll(name);
                try w.writeByte('"');
                written += 1;
            }
            // The residual branch is emitted only behind `hasResidualMembers`,
            // which walks the same members with the same cover test — an
            // empty `Symbol_<>` here means the two drifted apart.
            std.debug.assert(written >= 1);
        },
    }
    try w.writeAll(">");
}

/// The `i`th member name of a symbol member-set shape, compact or rich;
/// null past the end, and null for any other shape (a discriminant that
/// is not a closed symbol set is `discriminant_not_closed_enum` at
/// aggregate time and never reaches export).
fn memberNameAt(shape: Model.ValueShape, i: usize) ?[]const u8 {
    return switch (shape) {
        .symbol_members => |ms| if (i < ms.len) ms[i] else null,
        .symbol_members_rich => |ms| if (i < ms.len) ms[i].name else null,
        else => null,
    };
}

/// True when some variant of `d` lists `name` in its `:when`.
fn variantCovers(d: Model.Discriminator, name: []const u8) bool {
    for (d.variants) |v| {
        for (v.when) |x| if (std.mem.eql(u8, x, name)) return true;
    }
    return false;
}

/// True when the discriminant's member set has a member no variant
/// selects — the condition for the residual branch. `key` is the
/// discriminant key.
fn hasResidualMembers(key: Model.Key, d: Model.Discriminator) bool {
    var i: usize = 0;
    while (memberNameAt(key.value, i)) |name| : (i += 1) {
        if (!variantCovers(d, name)) return true;
    }
    return false;
}

/// The discriminant key of `f`, or null when `d.key_name` names no key
/// (a hand-built Model; the loader guarantees the key exists).
fn discriminantKey(f: Model.Form, d: Model.Discriminator) ?Model.Key {
    for (f.keys) |k| if (std.mem.eql(u8, k.name, d.key_name)) return k;
    return null;
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
        .form_heads => |hs| {
            const refs = hs.refs;
            // Union of `{$form: "<name>"}` literals. TS narrows on the
            // `$form` discriminant. In per-plugin mode, cross-plugin
            // refs use the imported type name (`<Other>_<Name>`) so the
            // `import type` line at the top of the file actually carries
            // weight in the consumer's type tree.
            // A slot-local head has no global type to name, so it emits the
            // same inline object literal the `form_locals` arm below emits
            // — the local's keys are what a consumer wants IntelliSense on,
            // and `{$form: "<name>"}` alone would say less than the open
            // union it replaced.
            for (refs, 0..) |ref, i| {
                if (i > 0) try w.writeAll(" | ");
                if (ref.body == .local) {
                    try writeInlineLocalForm(w, ref.body.local.*);
                    continue;
                }
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
            // Inline anonymous union of object literals (one per local
            // form) plus the additive global fallback. TS narrows on the
            // `$form` discriminant. Every fallback arm names a global
            // head — none spells `$form: string` — because
            // excess-property checking fires on fresh object literals
            // only: an open arm admits every declared local head the
            // moment its value arrives through a variable, a function
            // parameter, or `JSON.parse`, and the slot's group stops
            // being enforced at compile time.
            //
            //   * unqualified arms — one `{ readonly $form: "<name>" }`
            //     per global the slot's local heads do not shadow. A
            //     bare head is resolved local-first with shadowing
            //     (Validator.resolveFormSpec), so a local name can never
            //     reach a global here;
            //   * qualified arms — one `{ readonly $form: "<name>";
            //     readonly $ns: string }` per global, shadowed names
            //     included: a qualified head bypasses locals, and the
            //     runtime resolves it against the plugin catalog
            //     (Schema.lookupForm → lookupGeneric), where a `$ns`
            //     naming no plugin — or a plugin without that form — is
            //     `unknown_form`. A qualified head naming a local-only
            //     name therefore has no arm, exactly as it has no
            //     resolution. The `$ns` spelling itself stays
            //     runtime-checked: the arms are head-shaped, the same
            //     one-way acceptance the fallback's key enforcement has
            //     always had (SCHEMA_EXPORT.md).
            var first = true;
            for (forms) |lf| {
                if (!first) try w.writeAll(" | ");
                first = false;
                try writeInlineLocalForm(w, lf);
            }
            for (current_global_forms) |name| {
                if (formListHasName(forms, name)) continue;
                if (!first) try w.writeAll(" | ");
                first = false;
                try w.writeAll("{ readonly $form: \"");
                try w.writeAll(name);
                try w.writeAll("\" }");
            }
            for (current_global_forms) |name| {
                if (!first) try w.writeAll(" | ");
                first = false;
                try w.writeAll("{ readonly $form: \"");
                try w.writeAll(name);
                try w.writeAll("\"; readonly $ns: string }");
            }
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

/// True when `forms` declares a local named `name` — the head the
/// *unqualified* fallback enumeration must exclude (it is resolved
/// local-first, so no bare-head value of that name can legitimately
/// reach a global). The qualified enumeration deliberately does NOT
/// consult this: a `$ns` head bypasses locals, so a global with the
/// same name stays reachable there.
fn formListHasName(forms: []const Model.Form, name: []const u8) bool {
    for (forms) |f| {
        if (std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
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
            try writeInlineDiscriminatedBranch(w, f, d, .{ .list = v.when }, v.keys, v.exclusive_groups);
        }
        // The residual branch, as in `writeDiscriminatedFormType`.
        if (discriminantKey(f, d)) |dk| {
            if (hasResidualMembers(dk, d)) {
                if (d.variants.len > 0) try w.writeAll(" | ");
                try writeInlineDiscriminatedBranch(w, f, d, .{ .residual = .{ .members = dk.value, .d = d } }, &.{}, &.{});
            }
        }
        try w.writeByte(')');
        // Form-level enforced groups intersect the parenthesised branch
        // union, exactly as the block-shaped discriminated emitter wraps
        // its own.
        for (f.exclusive_groups) |g| {
            if (groupState(f, g) != .enforced) continue;
            try w.writeAll(" & (");
            try writeGroupArmsInline(w, f.keys, g);
            try w.writeAll(")");
        }
        return;
    }
    try w.writeAll("{ $form: \"");
    try w.writeAll(f.name);
    try w.writeAll("\"; $ns?: string;");
    const indices = Model.sortedKeys(f.keys);
    for (indices.slice()) |idx| {
        if (isKeyGroupedEnforced(f.open, f.keys, f.exclusive_groups, f.keys[idx].name)) continue;
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
    // Enforced groups apply the same anonymous-base/intersection
    // construction inline; `&` binds tighter than `|`, so a slot union
    // member stays correctly scoped without extra parentheses.
    for (f.exclusive_groups) |g| {
        if (groupState(f, g) != .enforced) continue;
        try w.writeAll(" & (");
        try writeGroupArmsInline(w, f.keys, g);
        try w.writeAll(")");
    }
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

/// One `{ … }` branch of an inline discriminated local's union — the
/// one-line mirror of `writeDiscriminatedBranch`, including the
/// variant-group arm intersection.
fn writeInlineDiscriminatedBranch(
    w: *std.Io.Writer,
    f: Model.Form,
    d: Model.Discriminator,
    when: WhenSet,
    overlay: []const Model.Key,
    groups: []const Model.ExclusiveGroup,
) std.Io.Writer.Error!void {
    try w.writeAll("{ $form: \"");
    try w.writeAll(f.name);
    try w.writeAll("\"; $ns?: string;");
    const indices = Model.sortedKeys(f.keys);
    for (indices.slice()) |idx| {
        const k = f.keys[idx];
        if (isKeyGroupedEnforced(f.open, f.keys, f.exclusive_groups, k.name)) continue;
        try w.writeByte(' ');
        if (std.mem.eql(u8, k.name, d.key_name)) {
            try writeInlineDiscriminantKey(w, k, when);
        } else {
            try writeInlineKey(w, k);
        }
    }
    const v_indices = Model.sortedKeys(overlay);
    for (v_indices.slice()) |idx| {
        if (isKeyGroupedEnforced(f.open, overlay, groups, overlay[idx].name)) continue;
        try w.writeByte(' ');
        try writeInlineKey(w, overlay[idx]);
    }
    if (f.open) try w.writeAll(" [key: string]: unknown;");
    try w.writeAll(" }");
    for (groups) |g| {
        if (groupStateForScope(f.open, overlay, g) != .enforced) continue;
        try w.writeAll(" & (");
        try writeGroupArmsInline(w, overlay, g);
        try w.writeAll(")");
    }
}

/// Compact discriminant key for an inline local-form variant branch:
/// `kind: Symbol_<"<when>">;` (or the `Symbol_<"a" | "b">` set). Mirrors
/// `writeDiscriminantKey`.
fn writeInlineDiscriminantKey(w: *std.Io.Writer, k: Model.Key, when: WhenSet) std.Io.Writer.Error!void {
    try writeKeyName(w, k.name);
    try w.writeAll(": ");
    try writeWhenBrand(w, when);
    try w.writeAll(";");
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

test "emit: variant-scoped exclusive group JSDoc rides the variant branch" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "probe",
        .forms = &.{.{
            .name = "track",
            .keys = &.{.{ .name = "kind", .value_type = .{ .named = .{ .name = "kind-tag" } }, .optional = true }},
            .discriminant_idx = 0,
            .variants = &.{
                .{
                    .when = &.{"kick"},
                    .keys = &.{
                        .{ .name = "step", .value_type = .number, .optional = true },
                        .{ .name = "sweep", .value_type = .number, .optional = true },
                    },
                    .exclusive_groups = &.{
                        .{
                            .cardinality = .exactly_one,
                            .alternatives = &.{ .{ .keys = &.{"step"} }, .{ .keys = &.{"sweep"} } },
                        },
                    },
                },
                .{
                    .when = &.{"bass"},
                    .keys = &.{.{ .name = "sequence", .value_type = .any, .optional = true }},
                },
            },
        }},
        .value_kinds = &.{
            .{ .name = "kind-tag", .underlying = .symbol, .members = .{ .members = &.{ .{ .name = "kick" }, .{ .name = "bass" } } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    const anno = "@sjon-exclusive-group exactly-one [step, sweep]";
    try testing.expect(std.mem.indexOf(u8, bytes, anno) != null);
    // The annotation is scoped to the `kick` branch, not the form: it
    // appears exactly once (the `bass` variant and the residual branch
    // carry no groups) and after the alias header.
    var count: usize = 0;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, search, anno)) |at| {
        count += 1;
        search = at + anno.len;
    }
    try testing.expectEqual(@as(usize, 1), count);
    const type_at = std.mem.indexOf(u8, bytes, "export type Probe_Track =").?;
    const anno_at = std.mem.indexOf(u8, bytes, anno).?;
    const kick_at = std.mem.indexOf(u8, bytes, "kind: Symbol_<\"kick\">").?;
    try testing.expect(type_at < anno_at and anno_at < kick_at);
}

// ---------------------------------------------------------------------------
// Structural exclusive-group emission (anonymous base & per-competitor
// arms). The expected blocks below are the ruling's literal shapes
// (`.agent/runs/20261101-223007-architect-consult-ask32-rerun.log` §1-3).
// ---------------------------------------------------------------------------

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

test "emit: exactly-one two-alternative group emits a type alias with one arm per alternative" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{.{
            .name = "phrase",
            .keys = &.{
                .{ .name = "name", .value_type = .symbol, .optional = false },
                .{ .name = "notes", .value_type = .vector, .optional = true },
                .{ .name = "events", .value_type = .vector, .optional = true },
            },
            .exclusive_groups = &.{.{
                .cardinality = .exactly_one,
                .alternatives = &.{ .{ .keys = &.{"notes"} }, .{ .keys = &.{"events"} } },
            }},
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    const expected =
        \\export type X_Phrase = {
        \\  $form: "phrase";
        \\  $ns: "x";
        \\  name: Symbol_;
        \\} & (
        \\  | ({ notes: Array<unknown> } & _SjonNotAll<"events">)
        \\  | ({ events: Array<unknown> } & _SjonNotAll<"notes">)
        \\);
    ;
    try testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
    // The interface spelling is gone, and the grouped keys left the base —
    // only an arm may carry them.
    try testing.expect(std.mem.indexOf(u8, bytes, "interface X_Phrase") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "notes?:") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "events?:") == null);
}

test "emit: three alternatives intersect one _SjonNotAll per competing alternative" {
    // The ruling's `P_Choice` shape verbatim: an alternative is present
    // only when ALL its keys are, so each arm excludes each competitor as
    // its own bundle — never one flattened key set.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{
            .name = "choice",
            .keys = &.{
                .{ .name = "common", .value_type = .string, .optional = true },
                .{ .name = "a", .value_type = .string, .optional = true },
                .{ .name = "b1", .value_type = .string, .optional = true },
                .{ .name = "b2", .value_type = .number, .optional = true },
                .{ .name = "c", .value_type = .boolean, .optional = true },
            },
            .exclusive_groups = &.{.{
                .cardinality = .exactly_one,
                .alternatives = &.{ .{ .keys = &.{"a"} }, .{ .keys = &.{ "b1", "b2" } }, .{ .keys = &.{"c"} } },
            }},
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    const expected =
        \\export type P_Choice = {
        \\  $form: "choice";
        \\  $ns: "p";
        \\  common?: string;
        \\} & (
        \\  | ({
        \\      a: string;
        \\    } & _SjonNotAll<"b1" | "b2">
        \\      & _SjonNotAll<"c">)
        \\  | ({
        \\      b1: string;
        \\      b2: number;
        \\    } & _SjonNotAll<"a">
        \\      & _SjonNotAll<"c">)
        \\  | ({
        \\      c: boolean;
        \\    } & _SjonNotAll<"a">
        \\      & _SjonNotAll<"b1" | "b2">)
        \\);
    ;
    try testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
    // The flattened spelling — which would accept `a + b1 + b2` whenever
    // `c` is absent — must not appear anywhere.
    try testing.expect(std.mem.indexOf(u8, bytes, "_SjonNotAll<\"b1\" | \"b2\" | \"c\">") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "_SjonNotAll<\"a\" | \"b1\" | \"b2\">") == null);
}

test "emit: at-most-one group emits the none-arm first" {
    // The ruling's `Xkey_Tag` shape verbatim — a multi-key bundle and a
    // single-key competitor, none-arm leading the union.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "xkey",
        .forms = &.{.{
            .name = "tag",
            .keys = &.{
                .{ .name = "name", .value_type = .symbol, .optional = false },
                .{ .name = "prefix", .value_type = .string, .optional = true },
                .{ .name = "suffix", .value_type = .string, .optional = true },
                .{ .name = "literal", .value_type = .string, .optional = true },
            },
            .exclusive_groups = &.{.{
                .cardinality = .at_most_one,
                .alternatives = &.{ .{ .keys = &.{ "prefix", "suffix" } }, .{ .keys = &.{"literal"} } },
            }},
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    const expected =
        \\export type Xkey_Tag = {
        \\  $form: "tag";
        \\  $ns: "xkey";
        \\  name: Symbol_;
        \\} & (
        \\  | { prefix?: never; suffix?: never; literal?: never }
        \\  | ({ prefix: string; suffix: string } & _SjonNotAll<"literal">)
        \\  | ({ literal: string } & _SjonNotAll<"prefix" | "suffix">)
        \\);
    ;
    try testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
    // `?: never` is the only absence spelling.
    try testing.expect(std.mem.indexOf(u8, bytes, "?: undefined") == null);
}

test "emit: _SjonNotAll rides once per file, non-exported, after the brand prelude" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{.{
            .name = "f",
            .keys = &.{
                .{ .name = "a", .value_type = .string, .optional = true },
                .{ .name = "b", .value_type = .string, .optional = true },
            },
            .exclusive_groups = &.{.{
                .cardinality = .exactly_one,
                .alternatives = &.{ .{ .keys = &.{"a"} }, .{ .keys = &.{"b"} } },
            }},
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    try testing.expectEqual(@as(usize, 1), countOccurrences(bytes, not_all_helper_decl));
    // Non-exported: the declaration line never carries `export`.
    try testing.expect(std.mem.indexOf(u8, bytes, "export type _SjonNotAll") == null);
    // After the brand prelude's last line, before the first plugin section.
    const f16_at = std.mem.indexOf(u8, bytes, "export type F16").?;
    const helper_at = std.mem.indexOf(u8, bytes, not_all_helper_decl).?;
    const plugin_at = std.mem.indexOf(u8, bytes, "// ----- plugin:").?;
    try testing.expect(f16_at < helper_at and helper_at < plugin_at);
}

test "emit: ungrouped, open-only and defaulted-only files emit no helper" {
    const a = testing.allocator;

    // Ungrouped: interface spelling, byte-identical to the pre-group world.
    {
        const p: Plugin.Plugin = .{
            .name = "x",
            .forms = &.{.{
                .name = "row",
                .keys = &.{.{ .name = "n", .value_type = .number, .optional = false }},
            }},
        };
        const schema = Schema.Schema.init(&.{p});
        var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
        defer result.deinit();
        const bytes = result.ts_types_bytes.?;
        try testing.expect(std.mem.indexOf(u8, bytes, "_SjonNotAll") == null);
        try testing.expect(std.mem.indexOf(u8, bytes, "export interface X_Row {") != null);
    }

    // Open-only: the scope is skipped-open — keys stay, index signature
    // stays, no intersection, no helper.
    {
        const p: Plugin.Plugin = .{
            .name = "x",
            .forms = &.{.{
                .name = "scene",
                .open = true,
                .keys = &.{
                    .{ .name = "notes", .value_type = .vector, .optional = true },
                    .{ .name = "events", .value_type = .vector, .optional = true },
                },
                .exclusive_groups = &.{.{
                    .cardinality = .exactly_one,
                    .alternatives = &.{ .{ .keys = &.{"notes"} }, .{ .keys = &.{"events"} } },
                }},
            }},
        };
        const schema = Schema.Schema.init(&.{p});
        var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
        defer result.deinit();
        const bytes = result.ts_types_bytes.?;
        try testing.expect(std.mem.indexOf(u8, bytes, "_SjonNotAll") == null);
        try testing.expect(std.mem.indexOf(u8, bytes, "export interface X_Scene {") != null);
        try testing.expect(std.mem.indexOf(u8, bytes, "notes?: Array<unknown>;") != null);
        try testing.expect(std.mem.indexOf(u8, bytes, "[key: string]: unknown;") != null);
        // The annotation stays — skipping the arms is not skipping the docs.
        try testing.expect(std.mem.indexOf(u8, bytes, "@sjon-exclusive-group exactly-one [notes, events]") != null);
    }

    // Defaulted-only: any defaulted alternative key skips the whole group;
    // the keys keep their base optionality, no helper.
    {
        const p: Plugin.Plugin = .{
            .name = "x",
            .forms = &.{.{
                .name = "def",
                .keys = &.{
                    .{ .name = "c", .value_type = .number, .optional = true },
                    .{ .name = "d", .value_type = .number, .optional = true, .default = .{ .number = 1 } },
                },
                .exclusive_groups = &.{.{
                    .cardinality = .at_most_one,
                    .alternatives = &.{ .{ .keys = &.{"c"} }, .{ .keys = &.{"d"} } },
                }},
            }},
        };
        const schema = Schema.Schema.init(&.{p});
        var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
        defer result.deinit();
        const bytes = result.ts_types_bytes.?;
        try testing.expect(std.mem.indexOf(u8, bytes, "_SjonNotAll") == null);
        try testing.expect(std.mem.indexOf(u8, bytes, "export interface X_Def {") != null);
        try testing.expect(std.mem.indexOf(u8, bytes, "d?: number;") != null);
    }
}

test "emit: per-plugin artifacts carry the helper only in files that enforce a group" {
    const a = testing.allocator;
    const grouped: Plugin.Plugin = .{
        .name = "grp",
        .forms = &.{.{
            .name = "f",
            .keys = &.{
                .{ .name = "a", .value_type = .string, .optional = true },
                .{ .name = "b", .value_type = .string, .optional = true },
            },
            .exclusive_groups = &.{.{
                .cardinality = .exactly_one,
                .alternatives = &.{ .{ .keys = &.{"a"} }, .{ .keys = &.{"b"} } },
            }},
        }},
    };
    const plain: Plugin.Plugin = .{
        .name = "plain",
        .forms = &.{.{ .name = "g", .keys = &.{.{ .name = "n", .value_type = .number, .optional = false }} }},
    };
    const schema = Schema.Schema.init(&.{ grouped, plain });
    var result = try SchemaExport.exportSchema(a, schema, .{
        .target = .{ .json_schema = false, .ts_types = true },
        .layout = .per_plugin,
    });
    defer result.deinit();
    var grouped_bytes: ?[]const u8 = null;
    var plain_bytes: ?[]const u8 = null;
    for (result.per_plugin.?) |art| {
        if (std.mem.eql(u8, art.plugin, "grp")) grouped_bytes = art.ts_types_bytes;
        if (std.mem.eql(u8, art.plugin, "plain")) plain_bytes = art.ts_types_bytes;
    }
    try testing.expectEqual(@as(usize, 1), countOccurrences(grouped_bytes.?, not_all_helper_decl));
    try testing.expect(std.mem.indexOf(u8, plain_bytes.?, "_SjonNotAll") == null);
}

test "emit: multiple enforced groups compose in declaration order" {
    // The ruling's `P_Multi` shape verbatim: an exactly-one group followed
    // by an at-most-one group on one scope.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{
            .name = "multi",
            .keys = &.{
                .{ .name = "a", .value_type = .string, .optional = true },
                .{ .name = "b", .value_type = .string, .optional = true },
                .{ .name = "c", .value_type = .number, .optional = true },
                .{ .name = "d", .value_type = .number, .optional = true },
            },
            .exclusive_groups = &.{
                .{
                    .cardinality = .exactly_one,
                    .alternatives = &.{ .{ .keys = &.{"a"} }, .{ .keys = &.{"b"} } },
                },
                .{
                    .cardinality = .at_most_one,
                    .alternatives = &.{ .{ .keys = &.{"c"} }, .{ .keys = &.{"d"} } },
                },
            },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    const expected =
        \\export type P_Multi = {
        \\  $form: "multi";
        \\  $ns: "p";
        \\} & (
        \\  | ({ a: string } & _SjonNotAll<"b">)
        \\  | ({ b: string } & _SjonNotAll<"a">)
        \\) & (
        \\  | { c?: never; d?: never }
        \\  | ({ c: number } & _SjonNotAll<"d">)
        \\  | ({ d: number } & _SjonNotAll<"c">)
        \\);
    ;
    try testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
}

test "emit: a defaulted sibling group contributes no intersection and keeps its keys in the base" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{
            .name = "mixed",
            .keys = &.{
                .{ .name = "a", .value_type = .string, .optional = true },
                .{ .name = "b", .value_type = .string, .optional = true },
                .{ .name = "c", .value_type = .number, .optional = true },
                .{ .name = "d", .value_type = .number, .optional = true, .default = .{ .number = 0 } },
            },
            .exclusive_groups = &.{
                .{
                    .cardinality = .exactly_one,
                    .alternatives = &.{ .{ .keys = &.{"a"} }, .{ .keys = &.{"b"} } },
                },
                .{
                    .cardinality = .at_most_one,
                    .alternatives = &.{ .{ .keys = &.{"c"} }, .{ .keys = &.{"d"} } },
                },
            },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    const expected =
        \\export type P_Mixed = {
        \\  $form: "mixed";
        \\  $ns: "p";
        \\  c?: number;
        \\  d?: number;
        \\} & (
        \\  | ({ a: string } & _SjonNotAll<"b">)
        \\  | ({ b: string } & _SjonNotAll<"a">)
        \\);
    ;
    try testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
    // Exactly one group union: the defaulted group adds nothing.
    try testing.expectEqual(@as(usize, 1), countOccurrences(bytes, "} & (\n"));
}

test "emit: grouped required keys leave the base and are required in their arm" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{
            .name = "req",
            .keys = &.{
                .{ .name = "keep", .value_type = .string, .optional = false },
                .{ .name = "a", .value_type = .number, .optional = false },
                .{ .name = "b", .value_type = .number, .optional = false },
            },
            .exclusive_groups = &.{.{
                .cardinality = .exactly_one,
                .alternatives = &.{ .{ .keys = &.{"a"} }, .{ .keys = &.{"b"} } },
            }},
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    const expected =
        \\export type P_Req = {
        \\  $form: "req";
        \\  $ns: "p";
        \\  keep: string;
        \\} & (
        \\  | ({ a: number } & _SjonNotAll<"b">)
        \\  | ({ b: number } & _SjonNotAll<"a">)
        \\);
    ;
    try testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
    // `:optional false` grouped keys are never optional anywhere — only
    // an active arm requires them.
    try testing.expect(std.mem.indexOf(u8, bytes, "a?:") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "b?:") == null);
}

test "emit: grouped keys keep their JSDoc inside a multi-line arm" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{.{
            .name = "doc",
            .keys = &.{
                .{ .name = "notes", .value_type = .vector, .optional = true, .description = "Pitch-class sequence." },
                .{ .name = "events", .value_type = .vector, .optional = true, .description = "Time-stamped event list." },
            },
            .exclusive_groups = &.{.{
                .cardinality = .exactly_one,
                .alternatives = &.{ .{ .keys = &.{"notes"} }, .{ .keys = &.{"events"} } },
            }},
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    const expected =
        \\export type X_Doc = {
        \\  $form: "doc";
        \\  $ns: "x";
        \\} & (
        \\  | ({
        \\      /** Pitch-class sequence. */
        \\      notes: Array<unknown>;
        \\    } & _SjonNotAll<"events">)
        \\  | ({
        \\      /** Time-stamped event list. */
        \\      events: Array<unknown>;
        \\    } & _SjonNotAll<"notes">)
        \\);
    ;
    try testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
}

test "emit: variant-scoped group intersects inside its branch only" {
    // The ruling's `Probe_Track` shape verbatim: the arms nest in the
    // `kick` branch, the `bass` branch and the form JSDoc stay untouched.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "probe",
        .forms = &.{.{
            .name = "track",
            .keys = &.{.{ .name = "kind", .value_type = .{ .named = .{ .name = "kind-tag" } }, .optional = true }},
            .discriminant_idx = 0,
            .variants = &.{
                .{
                    .when = &.{"kick"},
                    .keys = &.{
                        .{ .name = "step", .value_type = .number, .optional = true },
                        .{ .name = "sweep", .value_type = .number, .optional = true },
                    },
                    .exclusive_groups = &.{.{
                        .cardinality = .exactly_one,
                        .alternatives = &.{ .{ .keys = &.{"step"} }, .{ .keys = &.{"sweep"} } },
                    }},
                },
                .{
                    .when = &.{"bass"},
                    .keys = &.{.{ .name = "sequence", .value_type = .any, .optional = true }},
                },
            },
        }},
        .value_kinds = &.{
            .{ .name = "kind-tag", .underlying = .symbol, .members = .{ .members = &.{ .{ .name = "kick" }, .{ .name = "bass" } } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    const expected =
        \\export type Probe_Track =
        \\  /**
        \\   * @sjon-exclusive-group exactly-one [step, sweep]
        \\  */
        \\  | ({
        \\      $form: "track";
        \\      $ns: "probe";
        \\      kind: Symbol_<"kick">;
        \\    } & (
        \\      | ({ step: number } & _SjonNotAll<"sweep">)
        \\      | ({ sweep: number } & _SjonNotAll<"step">)
        \\    ))
        \\  | {
        \\      $form: "track";
        \\      $ns: "probe";
        \\      kind: Symbol_<"bass">;
        \\      sequence?: unknown;
        \\    };
    ;
    try testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
    // The variant's group annotation still rides the branch, directly
    // above the armed `| ({` opening.
    const anno = " * @sjon-exclusive-group exactly-one [step, sweep]\n  */\n  | ({";
    try testing.expect(std.mem.indexOf(u8, bytes, anno) != null);
}

test "emit: two enforced groups on one variant close the base once and join with & (" {
    // The second enforced group must not write another `}` — the branch
    // base object was closed before the first group's union. The joiner
    // between groups is `    ) & (`; a per-group `} & (` emits a stray
    // brace and the file does not parse (tsc TS1005/TS1109).
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "probe",
        .forms = &.{.{
            .name = "track",
            .keys = &.{.{ .name = "kind", .value_type = .{ .named = .{ .name = "kind-tag" } }, .optional = true }},
            .discriminant_idx = 0,
            .variants = &.{.{
                .when = &.{"kick"},
                .keys = &.{
                    .{ .name = "step", .value_type = .number, .optional = true },
                    .{ .name = "sweep", .value_type = .number, .optional = true },
                    .{ .name = "gate", .value_type = .string, .optional = true },
                    .{ .name = "pass", .value_type = .string, .optional = true },
                },
                .exclusive_groups = &.{
                    .{
                        .cardinality = .exactly_one,
                        .alternatives = &.{ .{ .keys = &.{"step"} }, .{ .keys = &.{"sweep"} } },
                    },
                    .{
                        .cardinality = .at_most_one,
                        .alternatives = &.{ .{ .keys = &.{"gate"} }, .{ .keys = &.{"pass"} } },
                    },
                },
            }},
        }},
        .value_kinds = &.{
            .{ .name = "kind-tag", .underlying = .symbol, .members = .{ .members = &.{.{ .name = "kick" }} } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    const expected =
        \\export type Probe_Track =
        \\  /**
        \\   * @sjon-exclusive-group exactly-one [step, sweep]
        \\   * @sjon-exclusive-group at-most-one [gate, pass]
        \\  */
        \\  | ({
        \\      $form: "track";
        \\      $ns: "probe";
        \\      kind: Symbol_<"kick">;
        \\    } & (
        \\      | ({ step: number } & _SjonNotAll<"sweep">)
        \\      | ({ sweep: number } & _SjonNotAll<"step">)
        \\    ) & (
        \\      | { gate?: never; pass?: never }
        \\      | ({ gate: string } & _SjonNotAll<"pass">)
        \\      | ({ pass: string } & _SjonNotAll<"gate">)
        \\    ));
    ;
    try testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
    // The stray-brace spelling the second group used to emit: one `}`
    // per enforced group instead of one for the whole base.
    try testing.expect(std.mem.indexOf(u8, bytes, ")    } & (") == null);
    try testing.expectEqual(@as(usize, 1), countOccurrences(bytes, "} & (\n"));
}

test "emit: a defaulted variant group keeps its keys in the branch and emits no arms" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "probe",
        .forms = &.{.{
            .name = "track",
            .keys = &.{.{ .name = "kind", .value_type = .{ .named = .{ .name = "kind-tag" } }, .optional = true }},
            .discriminant_idx = 0,
            .variants = &.{.{
                .when = &.{"kick"},
                .keys = &.{
                    .{ .name = "step", .value_type = .number, .optional = true, .default = .{ .number = 0 } },
                    .{ .name = "sweep", .value_type = .number, .optional = true },
                },
                .exclusive_groups = &.{.{
                    .cardinality = .exactly_one,
                    .alternatives = &.{ .{ .keys = &.{"step"} }, .{ .keys = &.{"sweep"} } },
                }},
            }},
        }},
        .value_kinds = &.{
            .{ .name = "kind-tag", .underlying = .symbol, .members = .{ .members = &.{.{ .name = "kick" }} } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    // No arms, no helper — and the variant keys stay optional in the branch.
    try testing.expect(std.mem.indexOf(u8, bytes, "_SjonNotAll") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "step?: number;") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "sweep?: number;") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "@sjon-exclusive-group exactly-one [step, sweep]") != null);
}

test "emit: a form-level group on a discriminated form wraps the variant union" {
    // `|` binds looser than `&`, so the group cannot ride a branch tail;
    // the variant union is parenthesised and the group intersects the
    // whole thing, mirroring the JSON Schema side's allOf chain.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{
            .name = "gate",
            .keys = &.{
                .{ .name = "kind", .value_type = .{ .named = .{ .name = "gate-kind" } }, .optional = false },
                .{ .name = "a", .value_type = .number, .optional = true },
                .{ .name = "b", .value_type = .number, .optional = true },
            },
            .discriminant_idx = 0,
            .variants = &.{
                .{ .when = &.{"x"} },
                .{ .when = &.{"y"} },
            },
            .exclusive_groups = &.{.{
                .cardinality = .exactly_one,
                .alternatives = &.{ .{ .keys = &.{"a"} }, .{ .keys = &.{"b"} } },
            }},
        }},
        .value_kinds = &.{
            .{ .name = "gate-kind", .underlying = .symbol, .members = .{ .members = &.{ .{ .name = "x" }, .{ .name = "y" } } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    const expected =
        \\export type P_Gate = (
        \\  | {
        \\      $form: "gate";
        \\      $ns: "p";
        \\      kind: Symbol_<"x">;
        \\    }
        \\  | {
        \\      $form: "gate";
        \\      $ns: "p";
        \\      kind: Symbol_<"y">;
        \\    }
        \\) & (
        \\  | ({ a: number } & _SjonNotAll<"b">)
        \\  | ({ b: number } & _SjonNotAll<"a">)
        \\);
    ;
    try testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
    // The grouped common keys left every branch.
    try testing.expect(std.mem.indexOf(u8, bytes, "a?:") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "b?:") == null);
}

test "emit: two form-level groups on a discriminated form chain after the union" {
    // The `wrap` path closes the parenthesised variant union once and
    // joins each enforced form-level group with ` & (` — the same
    // composition the non-discriminated alias uses. Two groups on one
    // discriminated form pin that the wrap loop cannot emit a stray
    // brace either.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{
            .name = "gate",
            .keys = &.{
                .{ .name = "kind", .value_type = .{ .named = .{ .name = "gate-kind" } }, .optional = false },
                .{ .name = "a", .value_type = .number, .optional = true },
                .{ .name = "b", .value_type = .number, .optional = true },
                .{ .name = "c", .value_type = .string, .optional = true },
                .{ .name = "d", .value_type = .string, .optional = true },
            },
            .discriminant_idx = 0,
            .variants = &.{
                .{ .when = &.{"x"} },
                .{ .when = &.{"y"} },
            },
            .exclusive_groups = &.{
                .{
                    .cardinality = .exactly_one,
                    .alternatives = &.{ .{ .keys = &.{"a"} }, .{ .keys = &.{"b"} } },
                },
                .{
                    .cardinality = .at_most_one,
                    .alternatives = &.{ .{ .keys = &.{"c"} }, .{ .keys = &.{"d"} } },
                },
            },
        }},
        .value_kinds = &.{
            .{ .name = "gate-kind", .underlying = .symbol, .members = .{ .members = &.{ .{ .name = "x" }, .{ .name = "y" } } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    const expected =
        \\export type P_Gate = (
        \\  | {
        \\      $form: "gate";
        \\      $ns: "p";
        \\      kind: Symbol_<"x">;
        \\    }
        \\  | {
        \\      $form: "gate";
        \\      $ns: "p";
        \\      kind: Symbol_<"y">;
        \\    }
        \\) & (
        \\  | ({ a: number } & _SjonNotAll<"b">)
        \\  | ({ b: number } & _SjonNotAll<"a">)
        \\) & (
        \\  | { c?: never; d?: never }
        \\  | ({ c: string } & _SjonNotAll<"d">)
        \\  | ({ d: string } & _SjonNotAll<"c">)
        \\);
    ;
    try testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
}

test "emit: a local form with an enforced group intersects inline" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "draw",
        .forms = &.{.{
            .name = "canvas",
            .keys = &.{.{
                .name = "wrap",
                .value_type = .form,
                .optional = true,
                .local_forms = &.{.{
                    .name = "inner",
                    .keys = &.{
                        .{ .name = "tag", .value_type = .string, .optional = true },
                        .{ .name = "a", .value_type = .number, .optional = true },
                        .{ .name = "b", .value_type = .number, .optional = true },
                    },
                    .exclusive_groups = &.{.{
                        .cardinality = .exactly_one,
                        .alternatives = &.{ .{ .keys = &.{"a"} }, .{ .keys = &.{"b"} } },
                    }},
                }},
            }},
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    const inline_expected = "wrap?: { $form: \"inner\"; $ns?: string; tag?: string; } & (({ a: number } & _SjonNotAll<\"b\">) | ({ b: number } & _SjonNotAll<\"a\">))";
    try testing.expect(std.mem.indexOf(u8, bytes, inline_expected) != null);
    // The local's group needs the file-level helper too.
    try testing.expectEqual(@as(usize, 1), countOccurrences(bytes, not_all_helper_decl));
}

test "emit: the slot-local fallback enumerates globals on both arms and cannot absorb a local head" {
    // The additive fallback of a form_locals slot must not contain any
    // open `$form` arm: excess-property checking fires on fresh object
    // literals only, so a local value violating its enforced group
    // (both alternatives, or neither) satisfies an open arm the moment
    // it arrives through a variable, a function parameter, or
    // `JSON.parse`, and the group is not enforced at compile time. The
    // runtime resolves a bare head local-first with shadowing
    // (Validator.resolveFormSpec), so the unqualified arms are exactly
    // the global catalog minus the local head names; a qualified head
    // (`$ns` present) bypasses locals but still resolves against the
    // plugin catalog (Schema.lookupForm), so the qualified arms
    // enumerate every global — shadowed names included — and a
    // local-only name answers no arm at all.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "draw",
        .forms = &.{
            .{
                .name = "canvas",
                .keys = &.{.{
                    .name = "wrap",
                    .value_type = .form,
                    .optional = true,
                    .local_forms = &.{.{
                        .name = "inner",
                        .keys = &.{
                            .{ .name = "tag", .value_type = .string, .optional = true },
                            .{ .name = "a", .value_type = .number, .optional = true },
                            .{ .name = "b", .value_type = .number, .optional = true },
                        },
                        .exclusive_groups = &.{.{
                            .cardinality = .exactly_one,
                            .alternatives = &.{ .{ .keys = &.{"a"} }, .{ .keys = &.{"b"} } },
                        }},
                    }},
                }},
            },
            .{ .name = "line", .keys = &.{.{ .name = "from", .value_type = .vector, .optional = false }} },
            // A global whose name collides with the local head: shadowed
            // for bare heads, so the unqualified enumeration must exclude
            // it — only a qualified arm can reach it.
            .{ .name = "inner", .keys = &.{.{ .name = "radius", .value_type = .number, .optional = false }} },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    // Locals, then the unqualified globals in declaration order (canvas,
    // line) minus the shadowed local head `inner`, then one qualified
    // arm per global in the same order — `inner` included there.
    const expected_tail =
        "wrap?: { $form: \"inner\"; $ns?: string; tag?: string; } & (({ a: number } & _SjonNotAll<\"b\">) | ({ b: number } & _SjonNotAll<\"a\">))" ++
        " | { readonly $form: \"canvas\" }" ++
        " | { readonly $form: \"line\" }" ++
        " | { readonly $form: \"canvas\"; readonly $ns: string }" ++
        " | { readonly $form: \"line\"; readonly $ns: string }" ++
        " | { readonly $form: \"inner\"; readonly $ns: string };";
    try testing.expect(std.mem.indexOf(u8, bytes, expected_tail) != null);
    // No open `$form` arm of any spelling remains — neither the
    // unqualified `$form: string` with `$ns` optional nor the
    // qualified-any `$form: string` with `$ns` required.
    try testing.expect(std.mem.indexOf(u8, bytes, "$form: string") == null);
}

test "emit: a discriminated local form's variant group nests inline arms in its branch" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "draw",
        .forms = &.{.{
            .name = "canvas",
            .keys = &.{.{
                .name = "pick",
                .value_type = .form,
                .optional = true,
                .local_forms = &.{.{
                    .name = "choice",
                    .keys = &.{.{ .name = "kind", .value_type = .{ .named = .{ .name = "pick-kind" } }, .optional = true }},
                    .discriminant_idx = 0,
                    .variants = &.{.{
                        .when = &.{"x"},
                        .keys = &.{
                            .{ .name = "a", .value_type = .number, .optional = true },
                            .{ .name = "b", .value_type = .number, .optional = true },
                        },
                        .exclusive_groups = &.{.{
                            .cardinality = .exactly_one,
                            .alternatives = &.{ .{ .keys = &.{"a"} }, .{ .keys = &.{"b"} } },
                        }},
                    }},
                }},
            }},
        }},
        .value_kinds = &.{
            .{ .name = "pick-kind", .underlying = .symbol, .members = .{ .members = &.{ .{ .name = "x" }, .{ .name = "y" } } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    // The `x` branch carries the arms; the residual `y` branch stays bare.
    // The whole local union is parenthesised (inline discriminated
    // grammar), so the armed branch needs no parens of its own: `&`
    // already binds tighter than the surrounding `|`.
    const inline_expected = "pick?: ({ $form: \"choice\"; $ns?: string; kind: Symbol_<\"x\">; } & " ++
        "(({ a: number } & _SjonNotAll<\"b\">) | ({ b: number } & _SjonNotAll<\"a\">)) " ++
        "| { $form: \"choice\"; $ns?: string; kind: Symbol_<\"y\">; }) " ++
        "| { readonly $form: \"canvas\" } | { readonly $form: \"canvas\"; readonly $ns: string };";
    try testing.expect(std.mem.indexOf(u8, bytes, inline_expected) != null);
    try testing.expectEqual(@as(usize, 1), countOccurrences(bytes, not_all_helper_decl));
}

fn groupTestKey(name: []const u8, default: ?Model.Default) Model.Key {
    return .{ .name = name, .optional = true, .value = .any, .default = default };
}

fn groupTestForm(keys: []const Model.Key, open: bool) Model.Form {
    return .{ .name = "f", .keys = keys, .positional = .none, .open = open };
}

fn groupTestPair() Model.ExclusiveGroup {
    return .{
        .cardinality = .exactly_one,
        .alternatives = &.{ &.{"a"}, &.{"b"} },
    };
}

test "groupState: closed default-free group is enforced" {
    const keys = [_]Model.Key{
        groupTestKey("a", null),
        groupTestKey("b", null),
    };
    try testing.expectEqual(GroupState.enforced, groupState(groupTestForm(&keys, false), groupTestPair()));
}

test "groupState: an open scope is skipped-open" {
    const keys = [_]Model.Key{
        groupTestKey("a", null),
        groupTestKey("b", null),
    };
    try testing.expectEqual(GroupState.skipped_open, groupState(groupTestForm(&keys, true), groupTestPair()));
}

test "groupState: any defaulted alternative key defaults the whole group" {
    const keys = [_]Model.Key{
        groupTestKey("a", null),
        groupTestKey("b", .{ .string = "fallback" }),
    };
    try testing.expectEqual(GroupState.defaulted, groupState(groupTestForm(&keys, false), groupTestPair()));
}

test "groupState: a default outside the group does not default it" {
    const keys = [_]Model.Key{
        groupTestKey("a", null),
        groupTestKey("b", null),
        groupTestKey("c", .{ .string = "fallback" }),
    };
    try testing.expectEqual(GroupState.enforced, groupState(groupTestForm(&keys, false), groupTestPair()));
}

test "groupState: a defaulted sibling group does not skip an enforced one" {
    const keys = [_]Model.Key{
        groupTestKey("a", null),
        groupTestKey("b", null),
        groupTestKey("c", null),
        groupTestKey("d", .{ .string = "fallback" }),
    };
    const enforced: Model.ExclusiveGroup = .{
        .cardinality = .exactly_one,
        .alternatives = &.{ &.{"a"}, &.{"b"} },
    };
    const defaulted: Model.ExclusiveGroup = .{
        .cardinality = .at_most_one,
        .alternatives = &.{ &.{"c"}, &.{"d"} },
    };
    const form = groupTestForm(&keys, false);
    try testing.expectEqual(GroupState.enforced, groupState(form, enforced));
    try testing.expectEqual(GroupState.defaulted, groupState(form, defaulted));
}

test "groupState: open wins over a defaulted alternative key" {
    const keys = [_]Model.Key{
        groupTestKey("a", null),
        groupTestKey("b", .{ .string = "fallback" }),
    };
    try testing.expectEqual(GroupState.skipped_open, groupState(groupTestForm(&keys, true), groupTestPair()));
}

test "groupStateForScope: a variant group reads the variant keys, not the form keys" {
    const variant_keys = [_]Model.Key{
        groupTestKey("step", null),
        groupTestKey("sweep", null),
    };
    const form_keys = [_]Model.Key{
        groupTestKey("kind", null),
        groupTestKey("step", .{ .string = "fallback" }),
    };
    const group: Model.ExclusiveGroup = .{
        .cardinality = .exactly_one,
        .alternatives = &.{ &.{"step"}, &.{"sweep"} },
    };
    try testing.expectEqual(GroupState.enforced, groupStateForScope(false, &variant_keys, group));
    try testing.expectEqual(GroupState.defaulted, groupStateForScope(false, &form_keys, group));
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
                .{ .when = &.{"kick"}, .keys = &.{
                    .{ .name = "step", .value_type = .number, .optional = false },
                    .{ .name = "volume", .value_type = .number, .optional = true },
                } },
                .{ .when = &.{"bass"}, .keys = &.{
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

test "emit: a multi-value variant narrows the discriminant brand to a literal union" {
    // `(variant :when [tri-strip line-strip] …)` is one branch whose
    // discriminant field is `Symbol_<"tri-strip" | "line-strip">` — the
    // brand's `S extends string` parameter takes the union — not two
    // branches. A single-value sibling renders exactly as before.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "gfx",
        .forms = &.{.{
            .name = "prim",
            .keys = &.{.{ .name = "topology", .value_type = .{ .named = .{ .name = "topo" } }, .optional = false }},
            .discriminant_idx = 0,
            .variants = &.{
                .{ .when = &.{ "tri-strip", "line-strip" }, .keys = &.{
                    .{ .name = "strip-index-format", .value_type = .symbol, .optional = true },
                } },
                .{ .when = &.{"line-list"}, .keys = &.{
                    .{ .name = "line-width", .value_type = .number, .optional = false },
                } },
            },
        }},
        .value_kinds = &.{
            .{ .name = "topo", .underlying = .symbol, .members = .{ .members = &.{ .{ .name = "tri-list" }, .{ .name = "tri-strip" }, .{ .name = "line-list" }, .{ .name = "line-strip" } } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    const bytes = result.ts_types_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "topology: Symbol_<\"tri-strip\" | \"line-strip\">") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "topology: Symbol_<\"line-list\">") != null);
    // `tri-list` is a member no variant selects: it validates with common
    // keys only, so it gets the residual branch — three branches, not two
    // (and not four: the second strip does not multiply the first branch).
    try testing.expect(std.mem.indexOf(u8, bytes, "topology: Symbol_<\"tri-list\">") != null);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, bytes, "topology: Symbol_<"));
    // The residual branch carries no variant key.
    const residual_idx = std.mem.indexOf(u8, bytes, "topology: Symbol_<\"tri-list\">").?;
    const residual_end = std.mem.indexOfPos(u8, bytes, residual_idx, "}").?;
    try testing.expect(std.mem.indexOf(u8, bytes[residual_idx..residual_end], "strip-index-format") == null);
    try testing.expect(std.mem.indexOf(u8, bytes[residual_idx..residual_end], "line-width") == null);
}

test "emit: a discriminated form whose variants cover every member emits no residual branch" {
    // The kit shape — every member has a variant — is byte-for-byte what it
    // was: no fourth branch appears when there is nothing left over.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "kit",
        .forms = &.{.{
            .name = "track",
            .keys = &.{.{ .name = "kind", .value_type = .{ .named = .{ .name = "k" } }, .optional = false }},
            .discriminant_idx = 0,
            .variants = &.{
                .{ .when = &.{"kick"}, .keys = &.{.{ .name = "step", .value_type = .number, .optional = false }} },
                .{ .when = &.{"bass"}, .keys = &.{.{ .name = "sequence", .value_type = .vector, .optional = false }} },
            },
        }},
        .value_kinds = &.{
            .{ .name = "k", .underlying = .symbol, .members = .{ .members = &.{ .{ .name = "kick" }, .{ .name = "bass" } } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = false, .ts_types = true } });
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, result.ts_types_bytes.?, "kind: Symbol_<"));
}

test "emit: positional local forms render as inline $children union" {
    // Positional locals lower to `positional = .kind{.form_locals}`, so the
    // `$children` array becomes a typed `Array<…>` of the inline object-literal
    // union (one branch per local head, `$form` brand + keys) plus the
    // enumerated global fallback — the same rendering a keyed local slot
    // produces.
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
    // …and the trailing fallback enumerates the model's one global
    // (`canvas`), unqualified and qualified — no open arm remains.
    try testing.expect(std.mem.indexOf(u8, bytes, "{ readonly $form: \"canvas\" } | { readonly $form: \"canvas\"; readonly $ns: string }") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "$form: string") == null);
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
