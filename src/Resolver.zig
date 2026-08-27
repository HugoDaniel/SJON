//! Plugin resolver contract. Maps a plugin reference (parsed from
//! `(use-plugin …)` syntax — D3) to manifest source bytes, WASM bytes,
//! or a structured failure. **D0 defines the contract; D3 ships the
//! filesystem implementation; Web/Rust hosts inject their own callbacks.**
//!
//! Resolution order for the filesystem default (D3):
//!   1. Explicit `:path "./vendor/foo.sjon"` override.
//!   2. `sjon-project.sjon` lookup (generalised from
//!      `src/lsp/SchemaConfig.zig`).
//!   3. Per-host search roots, then `~/.sjon/plugins/`.
//!   4. Fail with a `ResolverFailure` carrying `unresolved_plugin`.
//!
//! Web hosts wrap a `fetch`-based callback. Rust hosts wrap a
//! filesystem resolver matching Zig semantics. The Zig filesystem
//! resolver is one implementation, not the only one.

const std = @import("std");
const Ast = @import("Ast.zig");

/// A `(use-plugin …)` reference parsed from the document. D3 owns the
/// parser; D0 just defines the shape.
pub const Reference = struct {
    /// Bare name from `(use-plugin "name" …)` — used for
    /// `sjon-project.sjon` lookup and as a resolution-failure key.
    name: []const u8,

    /// Explicit `:path` override. Takes precedence over name lookup.
    explicit_path: ?[]const u8 = null,

    /// Pin from `(use-plugin … :version "x.y.z")`. The host enforces an
    /// exact-string match against the resolved manifest's top-level
    /// `:version` — for every resolver, not just the filesystem one —
    /// and emits `plugin_version_mismatch` on disagreement. Null =
    /// unpinned (no check).
    version: ?[]const u8 = null,

    /// Pin from `(use-plugin … :hash "sha256-<64 hex>")`. The host hashes
    /// the resolved wasm bytes with SHA-256 — for every resolver, not
    /// just the filesystem one — and emits `plugin_hash_mismatch` on any
    /// deviation (malformed pin, missing wasm, or digest mismatch). Null =
    /// unpinned (no check).
    hash: ?[]const u8 = null,

    /// Source span on the `(use-plugin …)` form. Host emits diagnostics
    /// at this span on failure.
    span: Ast.Span,
};

pub const Resolution = union(enum) {
    /// Successful resolution: an SJON manifest plus, optionally, the
    /// paired WASM binary that supplies executable expression-function
    /// bodies. The pairing invariant is non-negotiable — wasm cannot
    /// resolve without a manifest. See
    /// `docs/executable-plugin-abi.md` §3 (sidecar packaging) and §4
    /// (resolver protocol).
    manifest: ManifestResolution,

    /// Resolver explicitly failed. Host emits a diagnostic at the
    /// reference's span using `failure.code` and `failure.detail`.
    failure: ResolverFailure,
};

pub const ManifestResolution = struct {
    /// SJON manifest text. Always present; host parses + loads via
    /// `ManifestLoader`.
    source: []const u8,

    /// Paired WASM binary bytes, or null for declarative-only plugins.
    /// When non-null, the host runtime instantiates this and binds each
    /// `:impl "wasm:<name>"` reference to one of its exports. The D7
    /// runtime adapter is staged separately; until it lands, the host
    /// emits a deferral diagnostic when these bytes are present.
    wasm: ?[]const u8 = null,
};

pub const ResolverFailure = struct {
    /// Resolution-layer codes (`unresolved_plugin`,
    /// `plugin_version_mismatch`, `plugin_hash_mismatch`) plus the
    /// load-time pre-flight codes (`plugin_abi_mismatch`,
    /// `plugin_export_missing`, `plugin_import_forbidden`) that hosts
    /// running the executable-plugin ABI surface here when the resolver
    /// returned bytes but the runtime adapter rejected them. Other codes
    /// are not legal here — the host's `validateDocument` collapses them
    /// to `unresolved_plugin` rather than rendering an out-of-context
    /// diagnostic.
    code: Ast.Diagnostic.Code,

    /// Human-readable detail. Allocated in the `arena` passed to
    /// `ResolverFn` so its lifetime is tied to the host result.
    detail: []const u8,
};

/// This module's error surface, spelled per the repo convention (every
/// module with an error-returning API exports `pub const Error`).
///
/// Allocation only, deliberately: every *resolution* failure — missing
/// plugin, bad manifest, hash mismatch — is a `Resolution.failure` value
/// carrying a diagnostic code, never a thrown error. That is what lets a
/// partial-load flow survive one broken plugin instead of losing the
/// whole document. See `ResolverFn`.
pub const Error = std.mem.Allocator.Error;

/// Resolve a single plugin reference. Allocate any returned bytes
/// (`manifest.source`, `manifest.wasm`, `failure.detail`) from `arena`;
/// the host's `HostResult.arena` is the eventual owner.
///
/// The only error this is allowed to fail with is `OutOfMemory`. Every
/// other failure mode is a `Resolution.failure` value, not a thrown
/// error — that's how partial-load flows survive a missing plugin
/// without poisoning the whole document.
pub const ResolverFn = *const fn (
    ctx: *anyopaque,
    ref: Reference,
    arena: std.mem.Allocator,
) std.mem.Allocator.Error!Resolution;

pub const Resolver = struct {
    ctx: *anyopaque,
    resolve: ResolverFn,
};

// ---------------------------------------------------------------------
// `(use-plugin …)` parser.
//
// Surface form (positional name, then optional kvpairs):
//
//   (use-plugin "shapes")
//   (use-plugin "shapes" :path "./vendor/shapes.sjon")
//   (use-plugin "shapes" :version "1.0.0")   ; exact-string pin, no ranges
//   (use-plugin "shapes" :hash "sha256-…")
//
// All parse failures become arena-allocated `Ast.Diagnostic` entries on
// `ParsedReference.diagnostics`; the only thrown error is `OutOfMemory`.
// The host wraps these with `phase = .manifest` so they land alongside
// inline manifest diagnostics.
// ---------------------------------------------------------------------

pub const ParsedReference = struct {
    reference: Reference,
    /// Diagnostics from the parse itself. Empty on success. Each entry's
    /// `message` and `path` slices are allocated from the caller-supplied
    /// arena.
    diagnostics: []const Ast.Diagnostic,

    pub fn hasErrors(self: ParsedReference) bool {
        for (self.diagnostics) |d| if (d.severity == .err) return true;
        return false;
    }
};

/// Parse a `(use-plugin "name" …)` form at `idx`. Caller owns nothing
/// returned — every byte (`name`, `explicit_path`, …, diagnostic
/// `message`/`path`) is allocated from `arena`.
pub fn parseReference(
    arena: std.mem.Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) std.mem.Allocator.Error!ParsedReference {
    std.debug.assert(tree.tagOf(idx) == .form);
    const hdr = tree.formHeader(idx);
    std.debug.assert(hdr.namespace == null);
    std.debug.assert(std.mem.eql(u8, hdr.head, "use-plugin"));

    const full_span = tree.spanOf(idx);

    var diags: std.ArrayList(Ast.Diagnostic) = .empty;
    var ref: Reference = .{ .name = "", .span = full_span };

    var name_seen = false;
    var saw_extra_positional = false;
    for (hdr.children) |ci| {
        switch (tree.tagOf(ci)) {
            .kvpair => {
                const kv = tree.kvpairHeader(ci);
                if (std.mem.eql(u8, kv.key, "path")) {
                    if (try expectStringValue(arena, tree, kv, "path", &diags)) |s| {
                        ref.explicit_path = s;
                    }
                } else if (std.mem.eql(u8, kv.key, "version")) {
                    // Reserved — the v1 FilesystemResolver doesn't enforce
                    // semver yet; D7+ resolvers (lockfile, registry) will.
                    if (try expectStringValue(arena, tree, kv, "version", &diags)) |s| {
                        ref.version = s;
                    }
                } else if (std.mem.eql(u8, kv.key, "hash")) {
                    if (try expectStringValue(arena, tree, kv, "hash", &diags)) |s| {
                        ref.hash = s;
                    }
                } else {
                    try diags.append(arena, .{
                        .span = kv.key_span,
                        .severity = .err,
                        .code = .unknown_key,
                        .message = try std.fmt.allocPrint(
                            arena,
                            "unknown key `:{s}` on (use-plugin …); expected :path, :version, or :hash",
                            .{kv.key},
                        ),
                        .path = try Ast.dupePath(arena, &.{"use-plugin"}),
                    });
                }
            },
            .string => {
                if (name_seen) {
                    if (!saw_extra_positional) {
                        try diags.append(arena, .{
                            .span = tree.spanOf(ci),
                            .severity = .err,
                            .code = .invalid_manifest,
                            .message = try arena.dupe(u8, "(use-plugin …) takes a single positional name"),
                            .path = try Ast.dupePath(arena, &.{"use-plugin"}),
                        });
                        saw_extra_positional = true;
                    }
                } else {
                    ref.name = try arena.dupe(u8, tree.stringText(ci));
                    ref.span = tree.spanOf(ci);
                    name_seen = true;
                }
            },
            else => {
                // Anything else in the positional slot — symbol, number,
                // vector — is malformed.
                if (!name_seen) {
                    try diags.append(arena, .{
                        .span = tree.spanOf(ci),
                        .severity = .err,
                        .code = .invalid_manifest,
                        .message = try arena.dupe(u8, "(use-plugin …) name must be a string literal"),
                        .path = try Ast.dupePath(arena, &.{"use-plugin"}),
                    });
                    name_seen = true; // suppress duplicate "missing name"
                }
            },
        }
    }

    if (!name_seen) {
        try diags.append(arena, .{
            .span = hdr.head_span,
            .severity = .err,
            .code = .invalid_manifest,
            .message = try arena.dupe(u8, "(use-plugin …) requires a name string"),
            .path = try Ast.dupePath(arena, &.{"use-plugin"}),
        });
    }

    return .{
        .reference = ref,
        .diagnostics = try diags.toOwnedSlice(arena),
    };
}

fn expectStringValue(
    arena: std.mem.Allocator,
    tree: *const Ast.Tree,
    kv: Ast.KvPairHeader,
    key_name: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
) std.mem.Allocator.Error!?[]const u8 {
    if (tree.tagOf(kv.value) != .string) {
        try diags.append(arena, .{
            .span = tree.spanOf(kv.value),
            .severity = .err,
            .code = .invalid_manifest,
            .message = try std.fmt.allocPrint(
                arena,
                "(use-plugin …) :{s} must be a string",
                .{key_name},
            ),
            .path = try Ast.dupePath(arena, &.{"use-plugin"}),
        });
        return null;
    }
    return try arena.dupe(u8, tree.stringText(kv.value));
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;
const Parser = @import("Parser.zig");

fn parseSingleRef(a: std.mem.Allocator, src: [:0]const u8) !struct {
    tree: Ast.Tree,
    parsed: ParsedReference,
} {
    var tree = try Parser.parse(a, src);
    errdefer tree.deinit();
    try testing.expect(tree.root.len >= 1);
    const idx = tree.root[0];
    const parsed = try parseReference(tree.arena.allocator(), &tree, idx);
    return .{ .tree = tree, .parsed = parsed };
}

test "parseReference: bare name" {
    const a = testing.allocator;
    var got = try parseSingleRef(a, "(use-plugin \"shapes\")\n");
    defer got.tree.deinit();

    try testing.expectEqualStrings("shapes", got.parsed.reference.name);
    try testing.expect(got.parsed.reference.explicit_path == null);
    try testing.expect(got.parsed.reference.version == null);
    try testing.expect(got.parsed.reference.hash == null);
    try testing.expectEqual(@as(usize, 0), got.parsed.diagnostics.len);
}

test "parseReference: with explicit path, version, and hash" {
    const a = testing.allocator;
    var got = try parseSingleRef(
        a,
        "(use-plugin \"shapes\" :path \"./vendor/shapes.sjon\" :version \"1.0.0\" :hash \"sha256-abc\")\n",
    );
    defer got.tree.deinit();

    try testing.expectEqualStrings("shapes", got.parsed.reference.name);
    try testing.expectEqualStrings("./vendor/shapes.sjon", got.parsed.reference.explicit_path.?);
    try testing.expectEqualStrings("1.0.0", got.parsed.reference.version.?);
    try testing.expectEqualStrings("sha256-abc", got.parsed.reference.hash.?);
    try testing.expectEqual(@as(usize, 0), got.parsed.diagnostics.len);
}

test "parseReference: missing name emits invalid_manifest" {
    const a = testing.allocator;
    var got = try parseSingleRef(a, "(use-plugin)\n");
    defer got.tree.deinit();

    try testing.expectEqual(@as(usize, 1), got.parsed.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.invalid_manifest, got.parsed.diagnostics[0].code);
    try testing.expect(got.parsed.hasErrors());
}

test "parseReference: unknown key emits unknown_key" {
    const a = testing.allocator;
    var got = try parseSingleRef(a, "(use-plugin \"shapes\" :registry \"x\")\n");
    defer got.tree.deinit();

    try testing.expectEqualStrings("shapes", got.parsed.reference.name);
    try testing.expectEqual(@as(usize, 1), got.parsed.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.unknown_key, got.parsed.diagnostics[0].code);
}

test "parseReference: non-string :path is invalid_manifest" {
    const a = testing.allocator;
    var got = try parseSingleRef(a, "(use-plugin \"shapes\" :path foo)\n");
    defer got.tree.deinit();

    try testing.expectEqualStrings("shapes", got.parsed.reference.name);
    try testing.expect(got.parsed.reference.explicit_path == null);
    try testing.expectEqual(@as(usize, 1), got.parsed.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.invalid_manifest, got.parsed.diagnostics[0].code);
}

test "parseReference: extra positional emits one invalid_manifest, name keeps first" {
    const a = testing.allocator;
    var got = try parseSingleRef(a, "(use-plugin \"shapes\" \"audio\")\n");
    defer got.tree.deinit();

    try testing.expectEqualStrings("shapes", got.parsed.reference.name);
    try testing.expectEqual(@as(usize, 1), got.parsed.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.invalid_manifest, got.parsed.diagnostics[0].code);
}

test "parseReference: name span anchors on the literal, not the form head" {
    const a = testing.allocator;
    var got = try parseSingleRef(a, "(use-plugin \"shapes\")\n");
    defer got.tree.deinit();

    // "shapes" sits at offset 13 (after `(use-plugin "`), span length 8 incl. quotes.
    try testing.expect(got.parsed.reference.span.start > 0);
    try testing.expect(got.parsed.reference.span.end > got.parsed.reference.span.start);
}
