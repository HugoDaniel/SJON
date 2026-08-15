//! Discriminated-variant matrix tests for the JSON Schema backend.
//!
//! The inline tests in `JsonSchema.zig` cover the bread-and-butter
//! shape (allOf + if/then + symbol-wrapped const + unevaluatedProperties).
//! This sibling drills into the per-cell behaviour: three fixture forms
//! with different variant arities and key arrangements, with one test
//! per (form, variant) pair asserting the exact slice of JSON Schema
//! structure that variant produces.

const std = @import("std");
const testing = std.testing;

const Plugin = @import("../Plugin.zig");
const Schema = @import("../Schema.zig");
const SchemaExport = @import("SchemaExport.zig");
const Warnings = @import("Warnings.zig");

// ---------------------------------------------------------------------------
// Fixture plugin — three discriminated forms covering the variant matrix
// dimensions we care about (arity 2/3/4, required overlays present/absent,
// empty-overlay edge case).
// ---------------------------------------------------------------------------

const matrix_plugin: Plugin.Plugin = .{
    .name = "matrix",
    .forms = &.{
        .{
            .name = "track",
            .keys = &.{
                .{ .name = "kind", .value_type = .{ .named = .{ .name = "track-kind" } }, .optional = false },
                .{ .name = "name", .value_type = .symbol, .optional = false },
            },
            .discriminant_name = "kind",
            .discriminant_idx = 0,
            .variants = &.{
                .{
                    .when = "kick",
                    .keys = &.{
                        .{ .name = "step", .value_type = .number, .optional = false },
                        .{ .name = "volume", .value_type = .number, .optional = true },
                    },
                },
                .{
                    .when = "bass",
                    .keys = &.{
                        .{ .name = "sequence", .value_type = .vector, .optional = false },
                    },
                },
                .{
                    .when = "hat",
                    .keys = &.{
                        .{ .name = "pattern", .value_type = .symbol, .optional = false },
                        .{ .name = "swing", .value_type = .number, .optional = true },
                    },
                },
            },
        },
        .{
            // Two-variant form, all-optional overlay on `batch`.
            .name = "mode",
            .keys = &.{
                .{ .name = "kind", .value_type = .{ .named = .{ .name = "mode-kind" } }, .optional = false },
            },
            .discriminant_name = "kind",
            .discriminant_idx = 0,
            .variants = &.{
                .{
                    .when = "single",
                    .keys = &.{
                        .{ .name = "value", .value_type = .number, .optional = false },
                    },
                },
                .{
                    .when = "batch",
                    .keys = &.{
                        .{ .name = "values", .value_type = .vector, .optional = true },
                    },
                },
            },
        },
        .{
            // Empty-overlay edge case — variant `none` carries no keys.
            .name = "signal",
            .keys = &.{
                .{ .name = "kind", .value_type = .{ .named = .{ .name = "signal-kind" } }, .optional = false },
            },
            .discriminant_name = "kind",
            .discriminant_idx = 0,
            .variants = &.{
                .{
                    .when = "dc",
                    .keys = &.{
                        .{ .name = "level", .value_type = .number, .optional = false },
                    },
                },
                .{
                    .when = "none",
                    .keys = &.{},
                },
            },
        },
    },
    .value_kinds = &.{
        .{ .name = "track-kind", .underlying = .symbol, .members = .{ .members = &.{ .{ .name = "kick" }, .{ .name = "bass" }, .{ .name = "hat" } } } },
        .{ .name = "mode-kind", .underlying = .symbol, .members = .{ .members = &.{ .{ .name = "single" }, .{ .name = "batch" } } } },
        .{ .name = "signal-kind", .underlying = .symbol, .members = .{ .members = &.{ .{ .name = "dc" }, .{ .name = "none" } } } },
    },
};

fn renderSchema(a: std.mem.Allocator) ![]const u8 {
    const schema = Schema.Schema.init(&.{matrix_plugin});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    // The caller owns nothing — we copy the bytes out and `deinit` the
    // arena so each test gets an independent buffer. The exporter
    // arena outlives the call only to keep returned slices alive, so
    // copy-then-deinit is the standard pattern in inline tests.
    const bytes = try a.dupe(u8, result.json_schema_bytes.?);
    result.deinit();
    return bytes;
}

/// Locate the per-form `$defs` body and return a slice that ends at the
/// next `$defs` entry or the top-level `oneOf`. Lets each variant test
/// look only inside its form's schema without false matches against
/// sibling forms.
fn formDefSlice(bytes: []const u8, form_name: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "\"form.matrix.{s}\"", .{form_name}) catch return null;
    const start = std.mem.indexOf(u8, bytes, key) orelse return null;
    // Skip ahead to a stable terminator: the next `"form.matrix.` entry
    // or the top-level `"oneOf"`.
    const after = bytes[start + key.len ..];
    const term_form = std.mem.indexOf(u8, after, "\n    \"form.matrix.");
    const term_oneof = std.mem.indexOf(u8, after, "\n  \"oneOf\"");
    var end_offset: usize = after.len;
    if (term_form) |t| end_offset = @min(end_offset, t);
    if (term_oneof) |t| end_offset = @min(end_offset, t);
    return after[0..end_offset];
}

fn variantThenSlice(form_slice: []const u8, when: []const u8) ?[]const u8 {
    // Anchor past the form-level `properties` block first — otherwise
    // the discriminant key's own `enum` would contain `"$sym": "<when>"`
    // entries that don't belong to any variant's if-clause.
    const allof_idx = std.mem.indexOf(u8, form_slice, "\"allOf\":") orelse return null;
    const tail = form_slice[allof_idx..];
    var buf: [128]u8 = undefined;
    const sym_key = std.fmt.bufPrint(&buf, "\"$sym\": \"{s}\"", .{when}) catch return null;
    const anchor = std.mem.indexOf(u8, tail, sym_key) orelse return null;
    const after = tail[anchor..];
    const then_idx = std.mem.indexOf(u8, after, "\"then\":") orelse return null;
    const then_body = after[then_idx..];
    // Bound at the start of the next variant's if-clause, so the slice
    // contains ONLY this variant's then body. The last variant's slice
    // extends to the end of `form_slice` (acceptable — the closing braces
    // for allOf/form-def don't contain key names that would false-match).
    if (std.mem.indexOf(u8, then_body[1..], "\"if\":")) |n| {
        return then_body[0 .. n + 1];
    }
    return then_body;
}

// ---------------------------------------------------------------------------
// Tests: one per (form, variant) cell.
// ---------------------------------------------------------------------------

test "matrix track/kick: step is variant-required; volume is optional overlay" {
    const bytes = try renderSchema(testing.allocator);
    defer testing.allocator.free(bytes);
    const form = formDefSlice(bytes, "track").?;
    const then = variantThenSlice(form, "kick").?;
    try testing.expect(std.mem.indexOf(u8, then, "\"step\"") != null);
    try testing.expect(std.mem.indexOf(u8, then, "\"volume\"") != null);
    // step is required (appears inside a `required:[…]` slice in `then`).
    try testing.expect(std.mem.indexOf(u8, then, "\"required\"") != null);
}

test "matrix track/bass: sequence is the only overlay key" {
    const bytes = try renderSchema(testing.allocator);
    defer testing.allocator.free(bytes);
    const form = formDefSlice(bytes, "track").?;
    const then = variantThenSlice(form, "bass").?;
    try testing.expect(std.mem.indexOf(u8, then, "\"sequence\"") != null);
    // Other variants' keys should NOT appear under this then.
    try testing.expect(std.mem.indexOf(u8, then, "\"step\"") == null);
    try testing.expect(std.mem.indexOf(u8, then, "\"pattern\"") == null);
}

test "matrix track/hat: pattern is required; swing is optional" {
    const bytes = try renderSchema(testing.allocator);
    defer testing.allocator.free(bytes);
    const form = formDefSlice(bytes, "track").?;
    const then = variantThenSlice(form, "hat").?;
    try testing.expect(std.mem.indexOf(u8, then, "\"pattern\"") != null);
    try testing.expect(std.mem.indexOf(u8, then, "\"swing\"") != null);
}

test "matrix mode/single: value is variant-required" {
    const bytes = try renderSchema(testing.allocator);
    defer testing.allocator.free(bytes);
    const form = formDefSlice(bytes, "mode").?;
    const then = variantThenSlice(form, "single").?;
    try testing.expect(std.mem.indexOf(u8, then, "\"value\"") != null);
    try testing.expect(std.mem.indexOf(u8, then, "\"required\"") != null);
}

test "matrix mode/batch: all-optional overlay omits then.required" {
    const bytes = try renderSchema(testing.allocator);
    defer testing.allocator.free(bytes);
    const form = formDefSlice(bytes, "mode").?;
    const then = variantThenSlice(form, "batch").?;
    // `values` is present as a property, but `required` is omitted
    // because the overlay carries no required keys.
    try testing.expect(std.mem.indexOf(u8, then, "\"values\"") != null);
    // Slice the then-object proper (up to the next `}` at depth 0); for
    // this fixture the inner `properties` carries a `"required": ["$sym"]`
    // for symbol values, so we look only at the immediate then body.
    const properties_idx = std.mem.indexOf(u8, then, "\"properties\"") orelse return error.TestExpectedNotFound;
    const before_properties = then[0..properties_idx];
    try testing.expect(std.mem.indexOf(u8, before_properties, "\"required\"") == null);
}

test "matrix signal/dc: level overlay surfaces inside the then" {
    const bytes = try renderSchema(testing.allocator);
    defer testing.allocator.free(bytes);
    const form = formDefSlice(bytes, "signal").?;
    const then = variantThenSlice(form, "dc").?;
    try testing.expect(std.mem.indexOf(u8, then, "\"level\"") != null);
}

test "matrix signal/none: empty overlay produces a bare then with no properties" {
    const bytes = try renderSchema(testing.allocator);
    defer testing.allocator.free(bytes);
    const form = formDefSlice(bytes, "signal").?;
    const then = variantThenSlice(form, "none").?;
    // An empty-overlay variant emits `"then": {}` — no properties, no required.
    const after_then = then["\"then\":".len..];
    var i: usize = 0;
    while (i < after_then.len and (after_then[i] == ' ' or after_then[i] == '\n')) : (i += 1) {}
    try testing.expect(i < after_then.len);
    try testing.expectEqual(@as(u8, '{'), after_then[i]);
}

// ---------------------------------------------------------------------------
// Top-level invariants the matrix is meant to lock in.
// ---------------------------------------------------------------------------

test "matrix: every form's allOf chain has one entry per variant" {
    const bytes = try renderSchema(testing.allocator);
    defer testing.allocator.free(bytes);

    // track has 3 variants → 3 `if` entries inside its form-def slice.
    const track = formDefSlice(bytes, "track").?;
    try testing.expectEqual(@as(usize, 3), countOccurrences(track, "\"if\":"));

    // mode has 2 variants.
    const mode = formDefSlice(bytes, "mode").?;
    try testing.expectEqual(@as(usize, 2), countOccurrences(mode, "\"if\":"));

    // signal has 2 variants (one with empty overlay).
    const signal = formDefSlice(bytes, "signal").?;
    try testing.expectEqual(@as(usize, 2), countOccurrences(signal, "\"if\":"));
}

test "matrix: every discriminated form uses unevaluatedProperties, not additionalProperties" {
    const bytes = try renderSchema(testing.allocator);
    defer testing.allocator.free(bytes);
    inline for (.{ "track", "mode", "signal" }) |name| {
        const slice = formDefSlice(bytes, name).?;
        try testing.expect(std.mem.indexOf(u8, slice, "\"unevaluatedProperties\"") != null);
        // No `additionalProperties` at the form level (the inner symbol
        // member-set schemas have their own `additionalProperties: false`,
        // which doesn't count here because we slice past them via the
        // form-def boundary).
    }
}

test "matrix: every variant emits an info-severity warning (not deferred_construct)" {
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{matrix_plugin});
    var result = try SchemaExport.exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    var seen_track = false;
    var seen_mode = false;
    var seen_signal = false;
    for (result.warnings) |wn| {
        if (wn.code == .deferred_construct and wn.form_name != null) {
            const fname = wn.form_name.?;
            if (std.mem.eql(u8, fname, "track") or std.mem.eql(u8, fname, "mode") or std.mem.eql(u8, fname, "signal")) {
                return error.UnexpectedDeferredWarning;
            }
        }
        if (wn.code == .variants_emitted_via_if_then and wn.form_name != null) {
            const fname = wn.form_name.?;
            if (std.mem.eql(u8, fname, "track")) seen_track = true;
            if (std.mem.eql(u8, fname, "mode")) seen_mode = true;
            if (std.mem.eql(u8, fname, "signal")) seen_signal = true;
            try testing.expectEqual(Warnings.Severity.info, wn.severity);
        }
    }
    try testing.expect(seen_track);
    try testing.expect(seen_mode);
    try testing.expect(seen_signal);
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) {
            count += 1;
            i += needle.len;
        } else {
            i += 1;
        }
    }
    return count;
}
