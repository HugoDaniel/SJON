//! Conformance fixture — the native half of the `lines` cross-ref
//! provider, and the twin of `manifests/lines.sjon` in the
//! `cross-ref-provider-*` corpus cases.
//!
//! `lines_provider.zig` ships the same extractor as a wasm export; this
//! file ships it as `Plugin.CrossRefProvider.impl`, the route a
//! statically linked Zig plugin takes. Both drive `lines_extract`, so
//! the interesting question is not whether they extract the same names
//! — they cannot help it — but whether the two routes reach the *same
//! diagnostics* through the pre-pass and the index build.
//!
//! That is what the tests below are for, and why they are written
//! against the four semantics the executable-tier corpus cases pin
//! (resolve, miss, refuse, overflow) rather than against the extractor:
//! run the same source through the native route here and through
//! `manifests/lines.wasm` there, and a divergence shows up as a corpus
//! failure on one host and a green test on the other. Neither half needs
//! a wasm runtime to be checked.
//!
//! Registered as its own test step (`lines-plugin`), the
//! `examples/plugins/shapes.zig` pattern.

const std = @import("std");
const Allocator = std.mem.Allocator;

const sjon = @import("sjon");

const lines_extract = @import("lines_extract.zig");

const Plugin = sjon.Plugin;
const ProviderExtraction = sjon.ProviderExtraction;
const Schema = sjon.Schema;
const Validator = sjon.Validator;

/// The native twin of `manifests/lines.sjon`. Keep the two in step: a
/// key, a value-kind, or a provider name that exists on one side only
/// makes the cross-route comparison above vacuous.
pub const plugin: Plugin.Plugin = .{
    .name = "lines",
    .version = "1.0.0",
    .cross_ref_providers = &.{
        .{
            .name = "lines",
            .description = "One name per non-empty line.",
            .impl = lines_extract.extract,
        },
        .{
            .name = "lines-overflow",
            .description = "Emits as many names as its source asks for.",
            .impl = lines_extract.extractOverflow,
        },
    },
    .value_kinds = &.{
        .{
            .name = "uniform-name",
            .underlying = .symbol,
            .cross_ref = .{ .targets = &.{"shader"}, .provider = "lines" },
        },
        .{
            .name = "overflow-name",
            .underlying = .symbol,
            .cross_ref = .{ .targets = &.{"counter"}, .provider = "lines-overflow" },
        },
    },
    .forms = &.{
        .{ .name = "shader", .keys = &.{
            .{ .name = "name", .value_type = .symbol },
            .{ .name = "src", .value_type = .string },
        } },
        .{ .name = "bind", .keys = &.{
            .{ .name = "uniform", .value_type = .{ .named = .{ .name = "uniform-name" } } },
        } },
        .{ .name = "counter", .keys = &.{
            .{ .name = "name", .value_type = .symbol },
            .{ .name = "src", .value_type = .string },
        } },
        .{ .name = "use", .keys = &.{
            .{ .name = "n", .value_type = .{ .named = .{ .name = "overflow-name" } } },
        } },
    },
};

pub const schema = Schema.Schema.init(&.{plugin});

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

/// The whole native route in one call: discover the `(provider, source)`
/// pairs the document asks for, run them through the extractor, and
/// validate with the resulting table in hand.
///
/// `Invoker.plugins(null)` is the production invoker with no runtime
/// behind it — the native `impl` short-circuits ahead of it, so reaching
/// the invoker at all would mean the `impl` was not consulted, and the
/// call would come back `unavailable` rather than quietly passing.
fn validateNative(a: Allocator, src: [:0]const u8) !struct {
    tree: sjon.Ast.Tree,
    table: ProviderExtraction.Table,
    result: Validator.Result,

    fn deinit(self: *@This()) void {
        self.result.deinit();
        self.table.deinit();
        self.tree.deinit();
    }
} {
    var tree = try sjon.parse(a, src);
    errdefer tree.deinit();

    const forest = [_]sjon.Ast.Tree{tree};
    var requests = try Validator.collectExtractionRequests(a, schema, &forest);
    defer requests.deinit();

    var table = try ProviderExtraction.fulfill(
        a,
        schema,
        requests.items,
        ProviderExtraction.Invoker.plugins(null),
    );
    errdefer table.deinit();

    const result = try Validator.validateWithOptions(a, tree, schema, .{ .extractions = &table.map });
    return .{ .tree = tree, .table = table, .result = result };
}

fn countCode(diags: []const sjon.Ast.Diagnostic, code: sjon.Ast.Diagnostic.Code) usize {
    var n: usize = 0;
    for (diags) |d| {
        if (d.code == code) n += 1;
    }
    return n;
}

test "lines plugin: extracted names register and references resolve" {
    var out = try validateNative(testing.allocator,
        \\(shader :name main :src "u_time\nu_res")
        \\(bind :uniform u_time)
        \\(bind :uniform u_res)
    );
    defer out.deinit();

    try testing.expectEqual(@as(usize, 0), out.result.diagnostics.len);
}

test "lines plugin: a reference outside the extracted set misses" {
    var out = try validateNative(testing.allocator,
        \\(shader :name main :src "u_time\nu_res")
        \\(bind :uniform u_tim)
    );
    defer out.deinit();

    try testing.expectEqual(@as(usize, 1), countCode(out.result.diagnostics, .not_cross_ref));
}

test "lines plugin: a refused source poisons its bucket instead of cascading" {
    // One `cross_ref_extraction_failed` at the source, and *no*
    // `not_cross_ref` for the two references that can no longer be
    // checked. Reporting those too would blame the document for a
    // provider's refusal — the poisoned-bucket rule, on the native route.
    var out = try validateNative(testing.allocator,
        \\(shader :name main :src "u_time\n!malformed")
        \\(bind :uniform u_time)
        \\(bind :uniform u_res)
    );
    defer out.deinit();

    try testing.expectEqual(@as(usize, 1), countCode(out.result.diagnostics, .cross_ref_extraction_failed));
    try testing.expectEqual(@as(usize, 0), countCode(out.result.diagnostics, .not_cross_ref));
}

test "lines plugin: the per-source name ceiling trips through the native route" {
    var over = try validateNative(testing.allocator, std.fmt.comptimePrint(
        \\(counter :name c :src "{d}")
        \\(use :n n0)
    , .{ProviderExtraction.MAX_EXTRACTED_NAMES + 1}));
    defer over.deinit();

    try testing.expectEqual(@as(usize, 1), countCode(over.result.diagnostics, .cross_ref_extraction_failed));
    try testing.expectEqual(@as(usize, 0), countCode(over.result.diagnostics, .not_cross_ref));

    // Control: exactly at the ceiling is fine, so the trip above is the
    // ceiling and not the fixture running out of something else.
    var at = try validateNative(testing.allocator, std.fmt.comptimePrint(
        \\(counter :name c :src "{d}")
        \\(use :n n0)
    , .{ProviderExtraction.MAX_EXTRACTED_NAMES}));
    defer at.deinit();

    try testing.expectEqual(@as(usize, 0), at.result.diagnostics.len);
}

test "lines plugin: the overflow corpus source is one over the ceiling" {
    // `conformance/cases/cross-ref-provider-overflow/document.sjon` spells
    // the count as a literal, because a corpus fixture cannot import a Zig
    // constant. This is the tripwire that keeps the two in step: move
    // `MAX_EXTRACTED_NAMES` and this fails, naming the case to update.
    try testing.expectEqual(@as(usize, 4096), ProviderExtraction.MAX_EXTRACTED_NAMES);
    try testing.expectEqual(
        ProviderExtraction.MAX_EXTRACTED_NAMES + 1,
        try lines_extract.overflowCount("4097"),
    );
}
