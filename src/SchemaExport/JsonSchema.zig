//! Model → JSON Schema 2020-12 bytes.
//!
//! Pure consumer of `Model.Model`. Mapping rules live in the per-shape
//! helpers (`writeShape`, `writeForm`, …) and warning emission happens
//! upstream in `SchemaExport.lowerSchema`; this file does not classify
//! shapes or grow the warning list. Output is deterministic: properties
//! sorted alphabetically; arrays-of-things (forms, members, required
//! keys) emitted in declaration order.
//!
//! Target: a single top-level schema whose `oneOf` enumerates every
//! known form across the loaded plugins. Per-form definitions live in
//! `$defs/form.<plugin>.<form>` and value-kinds in
//! `$defs/kind.<plugin>.<kind>`. Cross-references between value-kinds
//! and forms use `$ref`; M1 inlines compound shapes where the simpler
//! emission is clearer.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Model = @import("Model.zig");
const Plugin = @import("../Plugin.zig");
const Warnings = @import("Warnings.zig");

pub const Error = error{OutOfMemory};

/// Emit a 2020-12 schema. The returned bytes are owned by `a`.
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

/// Per-plugin emit. Produces a self-contained schema whose `$defs` only
/// holds this plugin's forms and whose `oneOf` only enumerates this
/// plugin's forms. `$ref`s into other plugins resolve as
/// `./<other-plugin>.schema.json#/$defs/form.<other>.<head>`.
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
    /// When non-null, only emit `$defs` / `oneOf` entries for the named
    /// plugin and rewrite cross-plugin `$ref`s as relative file paths.
    filter_plugin: ?[]const u8,
};

/// Module-scoped current emit context. Set on entry to `writeRoot` and
/// read by every `$ref`-emitting site (currently only `form_heads`). The
/// alternative — plumbing `EmitContext` through every `writeShape` /
/// `writeKey` call — would touch ~30 signatures for a single decision
/// surface, and the emit pipeline is strictly single-threaded.
threadlocal var current_ctx: EmitContext = .{ .filter_plugin = null };

/// Module-scoped plugin currently being emitted. Set on entry to `writeForm`
/// (save/restore) so the `form_locals` arm can reuse `writeForm` for each
/// inline local — which needs the plugin for the `$ns` const. Same rationale
/// as `current_ctx`: threading it through ~30 shape-emitter signatures for a
/// single read site isn't worth it, and emit is single-threaded. Local forms
/// share the enclosing form's plugin, so nested `writeForm` calls re-set the
/// same value. The sentinel (empty name) is never read — `form_locals` is
/// only reachable via a key inside a `writeForm` call.
threadlocal var current_plugin: Model.Plugin_ = .{ .name = "", .forms = &.{}, .value_kinds = &.{} };

// ---------------------------------------------------------------------------
// Top-level — root object, $defs, oneOf over every form.
// ---------------------------------------------------------------------------

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

    // $defs — emit form definitions and named-kind definitions for the
    // plugin set in scope. In the aggregated layout every plugin's forms
    // appear; in the per-plugin layout the filter narrows to one plugin,
    // and cross-plugin `$ref`s in shape emitters rewrite to relative
    // file paths.
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

    // oneOf — every form in scope, in plugin × form declaration order.
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
        // An empty `oneOf` is invalid JSON Schema; emit a literal
        // `false` schema so consumers see "this schema rejects every
        // input" rather than a parse error.
        try w.beginObject();
        try w.objectField("not");
        try w.beginObject();
        try w.endObject();
        try w.endObject();
    }
    try w.endArray();

    try w.endObject();
}

// ---------------------------------------------------------------------------
// Form emission — object with $form const, $ns const, per-key properties.
// ---------------------------------------------------------------------------

fn writeForm(w: *std.json.Stringify, p: Model.Plugin_, f: Model.Form) std.Io.Writer.Error!void {
    // Make the plugin visible to the `form_locals` arm of `writeShapeBody`,
    // which reuses `writeForm` for each inline local (same plugin). Saved /
    // restored so nested local emission leaves the value as it found it.
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
    // $form — required const.
    try w.objectField("$form");
    try w.beginObject();
    try w.objectField("const");
    try w.write(f.name);
    try w.endObject();
    // $ns — required const when the plugin has a name (always in M1).
    try w.objectField("$ns");
    try w.beginObject();
    try w.objectField("const");
    try w.write(p.name);
    try w.endObject();
    // Named keys — alphabetical for deterministic diffs across edits
    // that re-order the source declaration.
    const indices = Model.sortedKeys(f.keys);
    for (indices.slice()) |idx| {
        const k = f.keys[idx];
        var name_buf: [128]u8 = undefined;
        try w.objectField(try escapedFieldName(&name_buf, k.name));
        try writeKey(w, k);
    }
    // $children — only when positional accepts something.
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
            try writeChildrenBounds(w, shape);
            try w.endObject();
        },
    }
    try w.endObject(); // properties

    try w.objectField("required");
    try w.beginArray();
    try w.write("$form");
    // $ns is intentionally NOT in required — the JSON bridge only emits
    // it for namespaced source (`(plugin/form …)`), and bare invocations
    // round-trip without it. The properties entry above pins the const
    // when the key IS present.
    for (f.keys) |k| {
        if (k.optional) continue;
        var name_buf: [128]u8 = undefined;
        try w.write(try escapedFieldName(&name_buf, k.name));
    }
    try w.endArray();

    // `dependentRequired` is 2020-12's exact encoding of `:requires`:
    // "if this property is present, these must be too". Emitted only when
    // some key declares one, so a schema without dependencies is
    // byte-identical to before.
    var any_requires = false;
    for (f.keys) |k| {
        if (k.requires.len != 0) {
            any_requires = true;
            break;
        }
    }
    if (any_requires) {
        try w.objectField("dependentRequired");
        try w.beginObject();
        for (f.keys) |k| {
            if (k.requires.len == 0) continue;
            var name_buf: [128]u8 = undefined;
            try w.objectField(try escapedFieldName(&name_buf, k.name));
            try w.beginArray();
            for (k.requires) |r| {
                var req_buf: [128]u8 = undefined;
                try w.write(try escapedFieldName(&req_buf, r));
            }
            try w.endArray();
        }
        try w.endObject();
    }

    // Discriminated forms compose per-variant overlays via `allOf` of
    // `if/then`. Each `then` carries the overlay's properties and any
    // variant-required keys; the surrounding `unevaluatedProperties`
    // closes the schema, recognising properties evaluated by either the
    // base or any matched `then`. Exclusive groups join the same `allOf`
    // chain as `oneOf` (exactly_one) or `not:{allOf}` (at_most_one)
    // sub-schemas — they don't introduce new properties, but live on the
    // same composition surface so the schema stays one logical block.
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

    // Annotations
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
    // `:positional (flag-set …)` rides through as annotation-only metadata
    // — the `$children` shape above widened to a plain array, so this is
    // the only place the declared flag names + metadata survive.
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

/// Emit one `oneOf` entry for a rich member-set member: a `const`-pinned
/// wire encoding plus title/description/deprecated annotations. The
/// `const` shape is `{$sym: "name"}` for symbol-underlying members and a
/// bare string for string-underlying members (matching the JSON bridge's
/// canonical-mode encoding).
///
/// A digit-leading member is the exception on both counts: a document
/// writes it as a unit-bearing number, so the JSON bridge encodes it as
/// `{"$num": [<magnitude>, "<unit>"]}` and that is what gets pinned. A
/// `$sym` const there would reject a document the validator accepts.
fn writeRichMember(
    w: *std.json.Stringify,
    m: Model.Member,
    underlying: MemberUnderlying,
) std.Io.Writer.Error!void {
    try w.beginObject();
    try w.objectField("const");
    if (m.numeric_spelling) |s| {
        try w.beginObject();
        try w.objectField("$num");
        try w.beginArray();
        try w.write(s.magnitude);
        try w.write(s.unit);
        try w.endArray();
        try w.endObject();
    } else switch (underlying) {
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

/// True iff at least one of `groups` can be encoded structurally.
/// Any group with ≥ 2 alternatives is enforceable; multi-key bundles
/// (`{required: [a, b]}`) are part of M3.
fn hasEnforceableExclusiveGroups(groups: []const Model.ExclusiveGroup) bool {
    for (groups) |g| if (isEnforceableExclusiveGroup(g)) return true;
    return false;
}

fn isEnforceableExclusiveGroup(g: Model.ExclusiveGroup) bool {
    if (g.alternatives.len < 2) return false;
    for (g.alternatives) |alt| if (alt.len == 0) return false;
    return true;
}

/// Write a `{required: [<bundle-keys…>]}` schema fragment. Multi-key
/// bundles list every key in the bundle — the JSON Schema `required`
/// keyword's contract is "all listed keys must be present," so the
/// resulting fragment matches the bundle-atomicity rule (all-or-nothing).
fn writeBundleRequired(w: *std.json.Stringify, bundle: []const []const u8) std.Io.Writer.Error!void {
    try w.beginObject();
    try w.objectField("required");
    try w.beginArray();
    for (bundle) |kn| try w.write(kn);
    try w.endArray();
    try w.endObject();
}

/// Emit one `oneOf`/`not` sub-schema for an exclusive group. Bundles
/// (single-key or multi-key) become `{required: [<keys>]}` fragments.
/// For `exactly_one` we emit `oneOf: [{required: [a]}, {required: [b, c]}, …]`;
/// for `at_most_one` we emit `not: {allOf: [...]}` when there are
/// exactly two alternatives and the pairwise `not: {anyOf: [{allOf:[…]}, …]}`
/// otherwise.
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

/// Emit one `{if, then}` entry inside `allOf` for a discriminated form.
/// `disc_key` is the discriminant key's name; `v.when` is the symbol
/// value that triggers this overlay (always wrapped as `{$sym: "<when>"}`
/// because discriminants are symbol-underlying per `Schema.validateForms`).
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
    try w.endObject(); // if

    try w.objectField("then");
    try w.beginObject();
    if (v.keys.len > 0) {
        try w.objectField("properties");
        try w.beginObject();
        const indices = Model.sortedKeys(v.keys);
        for (indices.slice()) |idx| {
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
    try w.endObject(); // then

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
        .expression => unreachable, // handled in writeKey
    }
}

// ---------------------------------------------------------------------------
// Shape emission. `writeShape` opens its own object; `writeShapeBody`
// expects the caller to have already opened one (used by writeKey to
// merge description + default into the same object).
// ---------------------------------------------------------------------------

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
            // Bridge can emit either integer or a digit-string when
            // value > i64.max. JSON Schema 2020-12 doesn't have a
            // native bigint type — emit a oneOf so both encodings pass.
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
            // Rich members → `oneOf` of `const`-pinned wire-shaped entries
            // each carrying title/description/deprecated metadata. Tools
            // that recognise JSON Schema annotations (editors, linters)
            // surface the rich text; consumers that ignore them still
            // get correct value validation.
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
            // 8-char `HH:MM:SS` or 12-char `HH:MM:SS.fff`.
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
                // Variable arity: emit whichever bound is present.
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
            // `oneOf` of `$ref`s into the `$defs` table, plus the
            // `x-sjon-head-set` annotation listing the accepted heads in
            // declaration order. Each `$ref` resolves to the full form
            // schema (with its own discriminator/exclusive-group chain),
            // so a head-set slot enforces the same constraints as a
            // top-level form would. In the per-plugin layout, refs into
            // other plugins resolve via a relative file path.
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
            // Inline anonymous union: one full object schema per local form
            // (reusing `writeForm`, so a discriminated local keeps its
            // if/then chain — bodies emitted in place, NOT as `$ref`s, since
            // locals have no global `$def`), plus a trailing open generic
            // branch (`{type:object, required:[$form]}`) for the additive
            // global fallback. `anyOf`, not `oneOf`: the open branch overlaps
            // every specific branch (a valid local also satisfies "any
            // object with $form"), so exactly-one would always fail — the
            // same reason `union_of` uses `anyOf`. The local-first / global
            // resolution order is SJON-only; it rides as `x-sjon-local-forms`.
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
            // One target keeps `target-form`, byte-identically; a group
            // gets `target-forms`, an array. Two keys rather than one
            // widened to "string or array", following `scope-form`'s
            // omit-when-inapplicable idiom below: a consumer that only
            // understands `target-form` then finds the field *absent* on a
            // group rather than reading a group as a single target it
            // cannot represent.
            if (cr.targets.len == 1) {
                try w.objectField("target-form");
                try w.write(cr.targets[0]);
            } else {
                try w.objectField("target-forms");
                try w.beginArray();
                for (cr.targets) |t| try w.write(t);
                try w.endArray();
            }
            try w.objectField("name-key");
            try w.write(cr.name_key);
            try w.objectField("acyclic");
            try w.write(cr.acyclic);
            if (cr.scope_form) |sf| {
                try w.objectField("scope-form");
                try w.write(sf);
            }
            // Omit-when-absent, like `scope-form` above. `name-key` and
            // `acyclic` stay unconditional even on the provider route
            // (where they carry loader-guaranteed defaults) — a consumer
            // reading this annotation as a record keeps the field set it
            // has always had, and the *prose* renderings are where the
            // route-specific wording lives.
            if (cr.provider) |p| {
                try w.objectField("provider");
                try w.write(p);
            }
            if (cr.source_key) |sk| {
                try w.objectField("source-key");
                try w.write(sk);
            }
            try w.endObject();
        },
        .union_of => |alts| {
            // `anyOf` (not `oneOf`) — SJON's first-match dispatch does
            // not require alternative-uniqueness, and "at-least-one
            // matches" is the looser-but-correct constraint for the
            // JSON Schema consumer. Dispatch order lives in the
            // annotation, where SJON-aware tooling can read it.
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
            // Wire shape: `{"$num": [<magnitude>, <unit>]}` per
            // `Json`'s `$num` encoding. We emit an object schema with `$num` as
            // a 2-tuple via `prefixItems`; `items: false` rejects extras.
            // The magnitude slot carries any propagated numeric bounds;
            // the unit slot is an `enum` of allowed units when non-empty.
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
            // magnitude
            try w.beginObject();
            try w.objectField("type");
            try w.write("number");
            if (u.bounds) |b| try writeNumericBoundsBody(w, b);
            try w.endObject();
            // unit
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
            try w.endObject(); // properties
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

/// Emit the JSON Schema numeric-bound keywords for a `NumericBounds`.
/// The caller has already opened the object and written the `type`
/// keyword. Bounds with `exact_int=true` whose magnitude exceeds 2^53
/// also emit `x-sjon-exact-bound` so SJON-aware tools can recover the
/// full-precision digit string.
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
    // Exact semantic match rather than an annotation: 2020-12's
    // `multipleOf` is "division by this keyword's value results in an
    // integer", which is the claim `:multiple-of` makes.
    if (b.multiple_of) |mo| {
        try w.objectField("multipleOf");
        try w.write(mo.value);
    }
    var exact_min_buf: [32]u8 = undefined;
    var exact_max_buf: [32]u8 = undefined;
    var exact_min: ?[]const u8 = null;
    var exact_max: ?[]const u8 = null;
    if (b.min) |min| {
        if (min.exceedsF64Precision()) {
            exact_min = std.fmt.bufPrint(&exact_min_buf, "{d:.0}", .{min.value}) catch return error.WriteFailed;
        }
    }
    if (b.max) |max| {
        if (max.exceedsF64Precision()) {
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
    // GPU representation tag. Annotation-only: ajv and other generic
    // validators ignore it; SJON-aware tooling reads the field's machine
    // type. `@tagName` yields the bare `"f32"` … `"f16"` wire string.
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

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Emit the per-head positional counts of a `$children` array, when the
/// slot's shape is a head-set with at least one bounded entry.
///
/// The encoding is one `contains` + `minContains` / `maxContains` per
/// bounded head, gathered in an `allOf` beside `items`. **Not**
/// `minItems` / `maxItems`: those bound the array's *total* length, which
/// is a different claim — `:min 1 :max 1` on `vertex` says nothing about
/// how many `constant` children there are. `contains` counts the
/// elements matching one subschema, which is exactly the per-head
/// question. `items` keeps the whole-set union it emits today.
///
/// `minContains: 0` is emitted explicitly for a ceiling-only head:
/// without it, `contains` would additionally demand at least one match,
/// turning "at most one fragment" into "exactly one".
///
/// Unbounded heads contribute nothing, so an all-unbounded head-set (and
/// therefore every schema written before bounds existed) emits no `allOf`
/// at all and stays byte-identical.
fn writeChildrenBounds(w: *std.json.Stringify, shape: Model.ValueShape) std.Io.Writer.Error!void {
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

    try w.objectField("allOf");
    try w.beginArray();
    for (refs) |ref| {
        if (!ref.isBounded()) continue;
        try w.beginObject();
        try w.objectField("contains");
        try w.beginObject();
        try w.objectField("$ref");
        var buf: [256]u8 = undefined;
        try w.write(try formatFormRef(&buf, ref));
        try w.endObject();
        try w.objectField("minContains");
        try w.write(ref.min);
        if (ref.max) |mx| {
            try w.objectField("maxContains");
            try w.write(mx);
        }
        try w.endObject();
    }
    try w.endArray();
}

/// Build a `$ref` string for a form. In the aggregated layout (`current_ctx.filter_plugin == null`)
/// this is always a same-document fragment `#/$defs/form.<plugin>.<head>`.
/// In the per-plugin layout, refs into a different plugin rewrite to the
/// sibling file `./<other-plugin>.schema.json#/$defs/form.<other>.<head>`.
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

/// `$`-prefixed user keys collide with discriminators on the wire, so
/// the JSON bridge encodes them as `$$<key>`. Mirror that here so a
/// schema describes the on-wire object key, not the source identifier.
/// `buf` is borrowed for the duration of the returned slice (the slice
/// points into `buf` when escaping is needed; `buf` is irrelevant when
/// `name` is returned verbatim).
fn escapedFieldName(buf: []u8, name: []const u8) std.Io.Writer.Error![]const u8 {
    if (name.len == 0 or name[0] != '$') return name;
    return std.fmt.bufPrint(buf, "${s}", .{name}) catch error.WriteFailed;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const SchemaExport = @import("SchemaExport.zig");
const Schema = @import("../Schema.zig");

test "emit: empty model produces a `false`-ish schema" {
    const a = testing.allocator;
    const schema: Schema.Schema = .{ .plugins = &.{} };
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "\"$schema\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"x-sjon-export-version\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"oneOf\"") != null);
}

test "emit: single form with primitive keys" {
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
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "\"form.test.row\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"const\": \"row\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"const\": \"test\"") != null);
    // n is required, s is not. Required array must list n but not s.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"n\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"s\"") != null);
}

test "emit: :repr emits the x-sjon-gpu-repr annotation" {
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
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "\"x-sjon-gpu-repr\": \"f32\"") != null);
    // Annotation-only: a repr-only kind emits no range keywords.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"minimum\"") == null);
}

test "emit: scalar-or-ref desugar (union [base symbol]) exports as anyOf" {
    const a = testing.allocator;
    // The shape `scalar-or-ref` desugars to at load time: `.union_of` with
    // alternatives `[count-value, symbol]` (the `symbol` primitive resolves
    // via the exporter's primitive shortcut). The union exports as `anyOf`.
    const p: Plugin.Plugin = .{
        .name = "refs",
        .forms = &.{.{
            .name = "use",
            .keys = &.{.{ .name = "n", .value_type = .{ .named = .{ .name = "count" } } }},
        }},
        .value_kinds = &.{
            .{ .name = "count-value", .underlying = .number },
            .{ .name = "count", .underlying = .union_of, .union_of = .{ .alternatives = &.{
                .{ .name = "count-value" },
                .{ .name = "symbol" },
            } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "\"anyOf\"") != null);
    // First-match dispatch order preserved in the annotation.
    try testing.expect(std.mem.indexOf(u8, bytes, "x-sjon-union-alternatives") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "count-value") != null);
}

test "emit: open form sets additionalProperties true" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{.{ .name = "scene", .open = true }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    try testing.expect(std.mem.indexOf(u8, result.json_schema_bytes.?, "\"additionalProperties\": true") != null);
}

test "emit: closed form sets additionalProperties false" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{.{ .name = "circle" }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    try testing.expect(std.mem.indexOf(u8, result.json_schema_bytes.?, "\"additionalProperties\": false") != null);
}

test "emit: typed vector emits minItems/maxItems" {
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
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "\"minItems\": 2") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"maxItems\": 2") != null);
}

test "emit: variable-arity vector emits :min-len/:max-len as minItems/maxItems" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{.{
            .name = "f",
            .keys = &.{.{ .name = "xs", .value_type = .{ .named = .{ .name = "list" } } }},
        }},
        .value_kinds = &.{
            .{ .name = "list", .underlying = .vector, .vector = .{ .len = null, .min_len = 1, .max_len = 4, .element = .{ .name = "number" } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = true } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "\"minItems\": 1") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"maxItems\": 4") != null);
    // A variable-arity vector projects to a TS Array, not a fixed tuple.
    const ts = result.ts_types_bytes.?;
    try testing.expect(std.mem.indexOf(u8, ts, "Array<") != null);
}

test "emit: symbol member-set produces enum of $sym objects" {
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
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "\"enum\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "evenodd") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "nonzero") != null);
}

test "emit: $-prefixed user key gets $$-escaped in properties" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{.{
            .name = "f",
            .keys = &.{.{ .name = "$reserved", .value_type = .string }},
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    try testing.expect(std.mem.indexOf(u8, result.json_schema_bytes.?, "\"$$reserved\"") != null);
}

test "emit: discriminated form emits allOf if/then chain" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "kit",
        .forms = &.{
            .{
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
            },
        },
        .value_kinds = &.{
            .{ .name = "track-kind", .underlying = .symbol, .members = .{ .members = &.{ .{ .name = "kick" }, .{ .name = "bass" } } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    // The allOf wrapper carries one if/then per variant.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"allOf\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"if\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"then\"") != null);
    // Symbol-wrapped discriminant constants.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"$sym\": \"kick\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"$sym\": \"bass\"") != null);
    // Closed discriminated form uses unevaluatedProperties, not additionalProperties.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"unevaluatedProperties\": false") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"additionalProperties\"") == null);
    // Annotation kept for SJON-aware consumers (no longer "M1 stub" wording).
    try testing.expect(std.mem.indexOf(u8, bytes, "\"x-sjon-discriminant\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "M1 stub") == null);
}

test "emit: discriminated form's then carries variant-required keys" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "kit",
        .forms = &.{.{
            .name = "track",
            .keys = &.{.{ .name = "kind", .value_type = .{ .named = .{ .name = "k" } }, .optional = false }},
            .discriminant_idx = 0,
            .variants = &.{
                .{ .when = "kick", .keys = &.{
                    .{ .name = "step", .value_type = .number, .optional = false },
                } },
            },
        }},
        .value_kinds = &.{
            .{ .name = "k", .underlying = .symbol, .members = .{ .members = &.{.{ .name = "kick" }} } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    // The then clause carries a `required` listing `step`.
    const then_idx = std.mem.indexOf(u8, bytes, "\"then\"") orelse return error.TestExpectedNotFound;
    const after_then = bytes[then_idx..];
    try testing.expect(std.mem.indexOf(u8, after_then, "\"step\"") != null);
}

test "emit: exclusive group exactly_one becomes oneOf of required clauses" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "kit",
        .forms = &.{.{
            .name = "phrase",
            .keys = &.{
                .{ .name = "notes", .value_type = .vector, .optional = true },
                .{ .name = "events", .value_type = .vector, .optional = true },
            },
            .exclusive_groups = &.{
                .{
                    .cardinality = .exactly_one,
                    .alternatives = &.{
                        .{ .keys = &.{"notes"} },
                        .{ .keys = &.{"events"} },
                    },
                },
            },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "\"allOf\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"oneOf\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"notes\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"events\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"unevaluatedProperties\": false") != null);
    // Annotation kept.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"x-sjon-exclusive-groups\"") != null);
}

test "emit: exclusive group at_most_one becomes not allOf" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "kit",
        .forms = &.{.{
            .name = "tag",
            .keys = &.{
                .{ .name = "color", .value_type = .string, .optional = true },
                .{ .name = "shape", .value_type = .string, .optional = true },
            },
            .exclusive_groups = &.{
                .{
                    .cardinality = .at_most_one,
                    .alternatives = &.{
                        .{ .keys = &.{"color"} },
                        .{ .keys = &.{"shape"} },
                    },
                },
            },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "\"not\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"allOf\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"color\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"shape\"") != null);
}

test "emit: rich symbol member-set produces oneOf with title/description/deprecated" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "enum_rich",
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
                    .{ .name = "fatal", .deprecated = true, .deprecation_message = "Use `error` instead." },
                } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "\"oneOf\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"$sym\": \"info\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"title\": \"Info\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"description\": \"Routine status.\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"deprecated\": true") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"x-sjon-deprecation-message\": \"Use `error` instead.\"") != null);
    // M1 stub annotation is gone.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"x-sjon-deferred\": \"symbol_members_rich\"") == null);
}

test "emit: rich string member-set produces oneOf with bare-string consts" {
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
                    .{ .name = "manual", .description = "Human-driven." },
                } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "\"const\": \"auto\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"const\": \"manual\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"$sym\"") == null);
}

test "emit: rich member info warning replaces M1 deferred_construct" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{.{ .name = "row", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "s" } } }} }},
        .value_kinds = &.{
            .{
                .name = "s",
                .underlying = .symbol,
                .members = .{ .members = &.{.{ .name = "a", .label = "A" }} },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    var saw = false;
    for (result.warnings) |wn| {
        if (wn.code == .rich_members_emitted_with_annotations) {
            try testing.expectEqual(Warnings.Severity.info, wn.severity);
            saw = true;
        }
        if (wn.code == .deferred_construct and wn.kind_name != null and std.mem.eql(u8, wn.kind_name.?, "s")) {
            return error.UnexpectedDeferredWarning;
        }
    }
    try testing.expect(saw);
}

test "emit: union_of produces anyOf plus x-sjon-union-alternatives" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "audio",
        .forms = &.{.{
            .name = "voice",
            .keys = &.{.{ .name = "step", .value_type = .{ .named = .{ .name = "note-or-event" } }, .optional = false }},
        }},
        .value_kinds = &.{
            .{ .name = "note-or-event", .underlying = .union_of, .union_of = .{ .alternatives = &.{ .{ .name = "note" }, .{ .name = "event" } } } },
            .{ .name = "note", .underlying = .string },
            .{ .name = "event", .underlying = .symbol },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "\"anyOf\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"x-sjon-union-alternatives\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"note\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"event\"") != null);
    // The M1 stub annotation is gone.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"x-sjon-deferred\": \"union_of\"") == null);
}

test "emit: union_of info warning replaces M1 deferred_construct" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "audio",
        .forms = &.{.{ .name = "f", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "u" } } }} }},
        .value_kinds = &.{
            .{ .name = "u", .underlying = .union_of, .union_of = .{ .alternatives = &.{ .{ .name = "string" }, .{ .name = "symbol" } } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    var saw_info = false;
    for (result.warnings) |wn| {
        if (wn.code == .union_emitted_via_anyof) {
            try testing.expectEqual(Warnings.Severity.info, wn.severity);
            saw_info = true;
        }
        if (wn.code == .deferred_construct and wn.kind_name != null and std.mem.eql(u8, wn.kind_name.?, "u")) {
            return error.UnexpectedDeferredWarning;
        }
    }
    try testing.expect(saw_info);
}

test "emit: head-set produces oneOf of $refs into $defs" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "shapes",
        .forms = &.{
            .{ .name = "circle" },
            .{ .name = "rect" },
            .{
                .name = "badge",
                .keys = &.{.{ .name = "shape", .value_type = .{ .named = .{ .name = "shape-form" } } }},
            },
        },
        .value_kinds = &.{
            .{ .name = "shape-form", .underlying = .form, .heads = .{ .heads = &.{ .{ .name = "circle" }, .{ .name = "rect" } } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    // The `badge.shape` slot uses oneOf of $refs, not a bare-form stub.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"$ref\": \"#/$defs/form.shapes.circle\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"$ref\": \"#/$defs/form.shapes.rect\"") != null);
    // The annotation stays for SJON-aware consumers.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"x-sjon-head-set\"") != null);
}

test "emit: bounded head-set on $children emits contains/minContains/maxContains" {
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
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    // `items` keeps the whole-set union — the per-head counts are a
    // separate claim and ride in `allOf` beside it.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"items\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"contains\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"minContains\": 1") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"maxContains\": 1") != null);
    // The ceiling-only head emits `minContains: 0` explicitly: without it,
    // `contains` would also demand at least one match, turning "at most
    // one fragment" into "exactly one".
    try testing.expect(std.mem.indexOf(u8, bytes, "\"minContains\": 0") != null);
    // NOT minItems/maxItems: those bound the array's total length, which
    // is a different claim than a per-head count.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"minItems\"") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"maxItems\"") == null);
}

test "emit: an unbounded head-set on $children emits no allOf at all" {
    // The drift gate for every golden written before bounds existed: a
    // compact `:names [a b]` head-set must export byte-identically.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "gfx",
        .forms = &.{
            .{ .name = "vertex" },
            .{ .name = "fragment" },
            .{ .name = "render-pipeline", .positional = .{ .kind = .{ .name = "loose-section" } } },
        },
        .value_kinds = &.{.{
            .name = "loose-section",
            .underlying = .form,
            .heads = .{ .heads = &.{ .{ .name = "vertex" }, .{ .name = "fragment" } } },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "\"$children\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"contains\"") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"minContains\"") == null);
}

test "emit: positional local forms render as inline $children union" {
    // The positional mirror of key-slot locals: inline `(form …)` children
    // under a `(form …)` lower to `positional = .kind{.form_locals}`, so the
    // `$children.items` slot carries the same inline `anyOf` union (local
    // bodies emitted in place + an open global-fallback branch +
    // `x-sjon-local-forms`) that a keyed local slot uses.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "draw",
        .forms = &.{.{
            .name = "canvas",
            // Loader implies `.any` when locals are present; model that here.
            .positional = .any,
            .local_forms = &.{
                .{ .name = "circle", .keys = &.{.{ .name = "r", .value_type = .number, .optional = false }} },
                .{ .name = "rect" },
            },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    // `$children.items` carries the inline union, not a bare `{type:array}`.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"$children\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"anyOf\"") != null);
    // Both local bodies are emitted in place (their `$form` consts).
    try testing.expect(std.mem.indexOf(u8, bytes, "\"circle\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"rect\"") != null);
    // The additive open branch + the SJON-only ordering annotation.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"x-sjon-local-forms\"") != null);
    // The warning fires at the positional slot: form-scoped, no key_name.
    var saw = false;
    for (result.warnings) |warn| {
        if (warn.code == .local_forms_emitted_inline and
            warn.form_name != null and std.mem.eql(u8, warn.form_name.?, "canvas"))
        {
            try testing.expect(warn.key_name == null);
            saw = true;
        }
    }
    try testing.expect(saw);
}

test "emit: flag-set produces x-sjon-positional-flags with metadata" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "tasks",
        .forms = &.{.{
            .name = "task",
            .positional = .{ .flag_set = .{ .flags = &.{
                .{ .name = "done", .description = "Marks complete.", .link = "https://example.com/done" },
                .{ .name = "archived" },
            } } },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "\"x-sjon-positional-flags\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"done\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"Marks complete.\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"https://example.com/done\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"archived\"") != null);
    // The widened positional still emits a generic `$children` array.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"$children\"") != null);
}

test "emit: empty-string flag metadata — description dropped, link kept" {
    // Long-tail asymmetry the parity hosts must mirror exactly: an empty
    // `description` is gated out by `len > 0`, but `link` rides on
    // presence (the optional is non-null), so an empty `link` survives as
    // `""`. A flag with both empty therefore exports as `{name, link:""}`.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "tasks",
        .forms = &.{.{
            .name = "task",
            .positional = .{ .flag_set = .{ .flags = &.{
                .{ .name = "done", .description = "", .link = "" },
            } } },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    // The flag is present with an empty link…
    try testing.expect(std.mem.indexOf(u8, bytes, "\"link\": \"\"") != null);
    // …but no `description` field is emitted for the empty string.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"description\"") == null);
}

test "emit: exclusive group warning is now info-severity" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "kit",
        .forms = &.{.{
            .name = "phrase",
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
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    var saw = false;
    for (result.warnings) |wn| {
        if (wn.code == .exclusive_group_unenforceable) {
            try testing.expectEqual(Warnings.Severity.info, wn.severity);
            saw = true;
        }
    }
    try testing.expect(saw);
}

test "emit: variants info warning replaces M1 deferred_construct" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "kit",
        .forms = &.{.{
            .name = "track",
            .keys = &.{.{ .name = "kind", .value_type = .{ .named = .{ .name = "k" } }, .optional = false }},
            .discriminant_idx = 0,
            .variants = &.{.{ .when = "kick", .keys = &.{} }},
        }},
        .value_kinds = &.{
            .{ .name = "k", .underlying = .symbol, .members = .{ .members = &.{.{ .name = "kick" }} } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    var saw_info = false;
    for (result.warnings) |wn| {
        if (wn.code == .variants_emitted_via_if_then) {
            try testing.expectEqual(Warnings.Severity.info, wn.severity);
            saw_info = true;
        }
        if (wn.code == .deferred_construct and wn.form_name != null and std.mem.eql(u8, wn.form_name.?, "track")) {
            return error.UnexpectedDeferredWarning;
        }
    }
    try testing.expect(saw_info);
}

test "emit: literal default surfaces as JSON Schema default" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{.{
            .name = "f",
            .keys = &.{.{ .name = "n", .value_type = .number, .default = .{ .number = 42 } }},
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    try testing.expect(std.mem.indexOf(u8, result.json_schema_bytes.?, "\"default\": 42") != null);
}

test {
    _ = @import("JsonSchema_tests.zig");
}
