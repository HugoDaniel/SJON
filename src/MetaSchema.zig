//! The bootstrap meta-plugin descriptor.
//!
//! `manifests/meta.sjon` is the single source of truth for the structure
//! of v1 portable plugin manifests (its own structure included).
//! `src/MetaSchema.generated.zig` is the comptime `Plugin` literal
//! generated from it by `tools/gen_meta_schema.zig`; this module
//! re-exports that literal as the host-facing descriptor.
//!
//! Why generate rather than parse meta.sjon at startup? The descriptor
//! must be a comptime constant: freestanding-wasm builds have no
//! filesystem, and `@embedFile` can't reach `manifests/` from `src/`. So
//! meta.sjon is compiled to a Zig literal at build time instead.
//!
//! The descriptor is the bootstrap — it lets the host validate any user
//! manifest (meta.sjon itself included) without first loading meta.sjon.
//! Validating meta.sjon against it produces zero diagnostics: the
//! self-validation contract in §10 of `docs/portable-manifest-v1.md`,
//! now a genuine fixed point (meta.sjon validates under rules generated
//! from meta.sjon).
//!
//! Update discipline: edit `manifests/meta.sjon`, then regenerate with
//!     zig build gen-meta-schema -- --regen
//! `zig build test` byte-compares the committed generated file against a
//! fresh generation, so an un-regenerated edit fails CI.

const std = @import("std");
const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
const Generated = @import("MetaSchema.generated.zig");

/// The meta-plugin descriptor. Schema initialisation:
/// `Schema.init(&.{ MetaSchema.plugin })` produces a one-plugin schema
/// suitable for validating any v1 portable manifest.
pub const plugin: Plugin.Plugin = Generated.plugin;

/// Convenience: a `Schema` containing only the meta-plugin. Used by the
/// loader and by self-validation tests.
pub const schema: Schema.Schema = Generated.schema;

// ---------------------------------------------------------------------------
// Tests — pin the shape of the descriptor. These guarded drift while the
// literal was hand-written; they now guard the meta.sjon → generated
// pipeline against an accidental shape change slipping through `--regen`.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "MetaSchema: plugin is named meta" {
    try testing.expectEqualStrings("meta", plugin.name);
}

test "MetaSchema: form / value-kind counts match meta.sjon" {
    try testing.expectEqual(@as(usize, 27), plugin.forms.len);
    try testing.expectEqual(@as(usize, 32), plugin.value_kinds.len);
    try testing.expectEqual(@as(usize, 0), plugin.expr_funcs.len);
}

test "MetaSchema: numeric-bounds form is registered with five optional keys" {
    var found: bool = false;
    for (plugin.forms) |f| {
        if (std.mem.eql(u8, f.name, "numeric-bounds")) {
            found = true;
            try testing.expectEqual(@as(usize, 5), f.keys.len);
            for (f.keys) |k| try testing.expect(k.optional);
        }
    }
    try testing.expect(found);
}

test "MetaSchema: flag form carries name + optional description/link keys" {
    var found: bool = false;
    for (plugin.forms) |f| {
        if (!std.mem.eql(u8, f.name, "flag")) continue;
        found = true;
        try testing.expectEqual(@as(usize, 3), f.keys.len);
        try testing.expectEqualStrings("name", f.keys[0].name);
        try testing.expect(!f.keys[0].optional);
        try testing.expectEqualStrings("description", f.keys[1].name);
        try testing.expect(f.keys[1].optional);
        try testing.expectEqualStrings("link", f.keys[2].name);
        try testing.expect(f.keys[2].optional);
    }
    try testing.expect(found);
}

test "MetaSchema: value-kind accepts :numeric pinning to numeric-bounds-ref" {
    var found_value_kind_form: bool = false;
    for (plugin.forms) |f| {
        if (!std.mem.eql(u8, f.name, "value-kind")) continue;
        found_value_kind_form = true;
        var saw_numeric_key: bool = false;
        for (f.keys) |k| {
            if (!std.mem.eql(u8, k.name, "numeric")) continue;
            saw_numeric_key = true;
            try testing.expect(k.optional);
            switch (k.value_type) {
                .named => |n| try testing.expectEqualStrings("numeric-bounds-ref", n.name),
                else => return error.TestUnexpectedResult,
            }
        }
        try testing.expect(saw_numeric_key);
    }
    try testing.expect(found_value_kind_form);
}

test "MetaSchema: plugin-decl heads include the four declaration heads" {
    // The head-set is the gate every declaring manifest passes *before* the
    // loader's own head chain sees it — a catalog missing from here fails
    // meta-validation with `unknown_local_form`, never reaching its branch.
    var found_plugin_decl: bool = false;
    for (plugin.value_kinds) |k| {
        if (std.mem.eql(u8, k.name, "plugin-decl")) {
            found_plugin_decl = true;
            const heads = k.heads orelse @panic("plugin-decl missing heads");
            try testing.expectEqual(@as(usize, 4), heads.names.len);
            try testing.expectEqualStrings("value-kind", heads.names[0]);
            try testing.expectEqualStrings("form", heads.names[1]);
            try testing.expectEqualStrings("expr-func", heads.names[2]);
            try testing.expectEqualStrings("cross-ref-provider", heads.names[3]);
        }
    }
    try testing.expect(found_plugin_decl);
}

test "MetaSchema: cross-ref form types both routes' keys" {
    // Identity (`:name-key`) and provider (`:provider` + `:source-key`) are
    // both typed here; the *exclusions* between them are the loader's job
    // (`invalid_manifest`), not the meta-schema's — a meta-schema can say
    // "this key is a symbol", not "not with that other key".
    var found: bool = false;
    for (plugin.forms) |f| {
        if (!std.mem.eql(u8, f.name, "cross-ref")) continue;
        found = true;
        try testing.expectEqual(@as(usize, 6), f.keys.len);
        try testing.expectEqualStrings("target", f.keys[0].name);
        try testing.expect(!f.keys[0].optional);
        try testing.expectEqualStrings("provider", f.keys[4].name);
        try testing.expect(f.keys[4].optional);
        try testing.expect(f.keys[4].value_type == .symbol);
        try testing.expectEqualStrings("source-key", f.keys[5].name);
        try testing.expect(f.keys[5].optional);
        try testing.expect(f.keys[5].value_type == .symbol);
    }
    try testing.expect(found);
}

test "MetaSchema: cross-ref-provider form carries name + description + binding-ref impl" {
    var found: bool = false;
    for (plugin.forms) |f| {
        if (!std.mem.eql(u8, f.name, "cross-ref-provider")) continue;
        found = true;
        try testing.expectEqual(@as(usize, 3), f.keys.len);
        try testing.expectEqualStrings("name", f.keys[0].name);
        try testing.expect(!f.keys[0].optional);
        try testing.expectEqualStrings("description", f.keys[1].name);
        try testing.expect(f.keys[1].optional);
        try testing.expectEqualStrings("impl", f.keys[2].name);
        try testing.expect(f.keys[2].optional);
        // Same `"<scheme>:<name>"` kind the expr-func `:impl` uses — the
        // provider route reuses that convention rather than minting one.
        switch (f.keys[2].value_type) {
            .named => |n| try testing.expectEqualStrings("binding-ref", n.name),
            else => return error.TestUnexpectedResult,
        }
    }
    try testing.expect(found);
}

test "MetaSchema: key form accepts inline (form …) positionals via key-local-decl" {
    // Slot-local forms (KeySpec.local_forms) are authored as inline `(form …)`
    // children of a `(key …)`. For `ManifestLoader.load`'s meta-validation pass
    // to admit them, the `key` meta-form must carry `:positional key-local-decl`
    // and that value-kind must pin the slot to the `form` head. Pinned here so a
    // forgotten `--regen` (or a meta.sjon revert) fails the build.
    var found_key_form: bool = false;
    for (plugin.forms) |f| {
        if (!std.mem.eql(u8, f.name, "key")) continue;
        found_key_form = true;
        switch (f.positional) {
            .kind => |ref| try testing.expectEqualStrings("key-local-decl", ref.name),
            else => @panic("key form's :positional is not key-local-decl"),
        }
    }
    try testing.expect(found_key_form);

    var found_kind: bool = false;
    for (plugin.value_kinds) |k| {
        if (!std.mem.eql(u8, k.name, "key-local-decl")) continue;
        found_kind = true;
        try testing.expectEqual(Plugin.ValueKind.Underlying.form, k.underlying);
        const heads = k.heads orelse @panic("key-local-decl missing heads");
        try testing.expectEqual(@as(usize, 1), heads.names.len);
        try testing.expectEqualStrings("form", heads.names[0]);
    }
    try testing.expect(found_kind);
}

test "MetaSchema: form meta-form admits inline (form …) positionals via form-child-decl" {
    // Positional slot-local forms (FormSpec.local_forms) are authored as inline
    // `(form …)` children directly under a `(form …)`. For `ManifestLoader.load`'s
    // meta-validation to admit them, the `form` meta-form must carry
    // `:positional form-child-decl`, whose head-set adds `form` to the
    // key/variant/exclusive-group heads that `key-decl` already allows. `variant`
    // keeps the narrower `key-decl` (no positional locals there). Pinned so a
    // forgotten `--regen` (or a meta.sjon revert) fails the build.
    var found_form: bool = false;
    for (plugin.forms) |f| {
        if (!std.mem.eql(u8, f.name, "form")) continue;
        found_form = true;
        switch (f.positional) {
            .kind => |ref| try testing.expectEqualStrings("form-child-decl", ref.name),
            else => @panic("form meta-form's :positional is not form-child-decl"),
        }
    }
    try testing.expect(found_form);

    var found_kind: bool = false;
    for (plugin.value_kinds) |k| {
        if (!std.mem.eql(u8, k.name, "form-child-decl")) continue;
        found_kind = true;
        try testing.expectEqual(Plugin.ValueKind.Underlying.form, k.underlying);
        const heads = k.heads orelse @panic("form-child-decl missing heads");
        try testing.expectEqual(@as(usize, 4), heads.names.len);
        try testing.expectEqualStrings("key", heads.names[0]);
        try testing.expectEqualStrings("variant", heads.names[1]);
        try testing.expectEqualStrings("exclusive-group", heads.names[2]);
        try testing.expectEqualStrings("form", heads.names[3]);
    }
    try testing.expect(found_kind);
}

test "MetaSchema: walk_opaque is set exactly on the key form's :default slot" {
    // The one walk_opaque slot in the meta-plugin — it lets `(key …
    // :default (pi))` carry an expression-shaped default without the
    // validator descending into it. Generated from meta.sjon's
    // `:walk-opaque true`; pinned here so the pipeline can't drop it.
    var found: bool = false;
    for (plugin.forms) |f| {
        for (f.keys) |k| {
            if (!k.walk_opaque) continue;
            try testing.expectEqualStrings("key", f.name);
            try testing.expectEqualStrings("default", k.name);
            found = true;
        }
    }
    try testing.expect(found);
}

test "MetaSchema: schema convenience constant references the plugin" {
    try testing.expectEqual(@as(usize, 1), schema.plugins.len);
    try testing.expectEqualStrings("meta", schema.plugins[0].name);
}
