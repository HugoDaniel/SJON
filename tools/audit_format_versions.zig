//! Format-version reconciler — audit the version / ABI literals scattered
//! across the hosts against their one in-repo source of truth.
//!
//! ## Why audit-in-place, not generate-and-import
//!
//! A wire-format or plugin-ABI bump is never *only* a number change: every
//! host needs behavioral work to match (new tag bytes to decode, a new
//! pre-flight branch, a changed manifest surface). A single generated constant
//! imported everywhere would auto-propagate the number and *hide* that the host
//! logic never caught up — the record would look consistent while the behavior
//! lagged, exactly the failure the mid-May wire bumps slipped through. So each
//! host keeps its own independently-spelled literal, and this tool machine-
//! compares them: bump the truth, and every stale copy fails loudly, naming the
//! file that still needs hand-work. The web magic-byte test is deliberate
//! double-entry bookkeeping — kept, not collapsed.
//!
//! ## Truth kinds
//!
//!   * **compiled** — read straight off the `sjon` module: `Binary.wire_version`,
//!     `Binary.wire_magic`, the SchemaExport `Model.version` field default,
//!     and the package semver (`sjon.version`, declared once in
//!     `src/version.zig`). These can't drift; the compiler resolves them at
//!     build time.
//!   * **text-anchored** — `PLUGIN_ABI_VERSION` lives in `PluginRuntime.zig`,
//!     which comptime-asserts `-Dplugin-exec`; importing it would force that
//!     flag onto a plain audit build, so it is read as text like any copy.
//!
//! ## Copy-site rule: ≥1 occurrence, every occurrence must match
//!
//! For each copy anchor: **0 occurrences fails** (the site was renamed or
//! deleted out from under us — the audit has gone blind there, and a human must
//! re-point the anchor); **every occurrence's value token must equal the truth**
//! (any drift fails, naming the file and the stale token). This is a refinement
//! of the "exactly-one-match" rule the plan sketched: verifying *all*
//! occurrences neutralizes the ambiguity worry (there is no "which literal do I
//! read?" when every literal must match the same truth) while correctly
//! accepting legitimately-duplicated pins — e.g. `sjon-reader.test.ts` spells
//! magic byte 0 in two independent encoder tests. Truth anchors, by contrast,
//! require exactly one occurrence: there is only one declaration of each truth.
//!
//! Value normalization: integers parse through `parseInt` with `0x` support, so
//! `0x04` and `4` compare equal; string tokens have surrounding quotes stripped,
//! so `'1.1'` matches `"1.1"` matches `1.1`.
//!
//! This tool only ever audits — there is no `--regen` mode (a version literal is
//! never machine-writable; the whole point is that a human must react).

const std = @import("std");
const sjon = @import("sjon");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// A version/ABI value that copies must track. `int` covers ABI/wire versions
/// and magic bytes; `str` covers the package semver.
const Truth = union(enum) {
    int: u64,
    str: []const u8,
};

/// One literal spelled in a host that must equal a `Fact.truth`. `anchor` is a
/// fixed substring; the value token is whatever immediately follows each of its
/// occurrences in `path` (relative to the project root / cwd).
const Copy = struct {
    path: []const u8,
    anchor: []const u8,
};

/// A truth plus every place it is hand-copied.
const Fact = struct {
    name: []const u8,
    truth: Truth,
    copies: []const Copy,
};

/// Read the `version` field's compile-time default off `SchemaExport.Model.Model`
/// (the file namespace `.Model` re-exports the struct, also named `Model`)
/// without constructing one — `Model.plugins` has no default, so `Model{}`
/// won't compile. Reflection keeps this pinned to the real field.
fn schemaExportVersion() u64 {
    return comptime blk: {
        for (@typeInfo(sjon.SchemaExport.Model.Model).@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, "version")) {
                const dv = f.default_value_ptr orelse
                    @compileError("SchemaExport.Model.version lost its default");
                break :blk @as(*const f.type, @ptrCast(@alignCast(dv))).*;
            }
        }
        @compileError("SchemaExport.Model has no `version` field");
    };
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var out_buf: [8192]u8 = undefined;
    var out_file = Io.File.stdout();
    var out_writer = out_file.writer(io, &out_buf);
    defer out_writer.interface.flush() catch {};
    const out = &out_writer.interface;

    // The one text-anchored truth: PluginRuntime comptime-asserts -Dplugin-exec,
    // so read PLUGIN_ABI_VERSION as text rather than importing the module.
    const abi_truth = resolveIntTruth(
        io,
        gpa,
        "src/PluginRuntime.zig",
        "pub const PLUGIN_ABI_VERSION: u32 = ",
    ) catch |err| {
        try out.print(
            "audit-format-versions: cannot resolve PLUGIN_ABI_VERSION truth in " ++
                "src/PluginRuntime.zig: {s}\n",
            .{@errorName(err)},
        );
        return 1;
    };

    const facts = [_]Fact{
        .{
            .name = "plugin ABI version",
            .truth = .{ .int = abi_truth },
            .copies = &.{
                .{ .path = "hosts/web/SjonHost.ts", .anchor = "const PLUGIN_ABI_VERSION = " },
                .{ .path = "hosts/rust/src/wasm.rs", .anchor = "const PLUGIN_ABI_VERSION: u32 = " },
            },
        },
        .{
            .name = "binary wire version",
            .truth = .{ .int = sjon.Binary.wire_version },
            .copies = &.{
                .{ .path = "hosts/web/sjon-reader.test.ts", .anchor = "assert.equal(bin[4], " },
            },
        },
        .{
            .name = "binary magic byte 0",
            .truth = .{ .int = sjon.Binary.wire_magic[0] },
            .copies = &.{
                .{ .path = "hosts/web/sjon-reader.test.ts", .anchor = "assert.equal(bin[0], " },
            },
        },
        .{
            .name = "binary magic byte 1",
            .truth = .{ .int = sjon.Binary.wire_magic[1] },
            .copies = &.{
                .{ .path = "hosts/web/sjon-reader.test.ts", .anchor = "assert.equal(bin[1], " },
            },
        },
        .{
            .name = "binary magic byte 2",
            .truth = .{ .int = sjon.Binary.wire_magic[2] },
            .copies = &.{
                .{ .path = "hosts/web/sjon-reader.test.ts", .anchor = "assert.equal(bin[2], " },
            },
        },
        .{
            .name = "binary magic byte 3",
            .truth = .{ .int = sjon.Binary.wire_magic[3] },
            .copies = &.{
                .{ .path = "hosts/web/sjon-reader.test.ts", .anchor = "assert.equal(bin[3], " },
            },
        },
        .{
            .name = "schema export version",
            .truth = .{ .int = schemaExportVersion() },
            .copies = &.{
                .{ .path = "hosts/typescript-parity/src/schemaExport/lower.ts", .anchor = "plugins, version: " },
                .{ .path = "hosts/typescript-parity/test/schemaExport.test.ts", .anchor = "x-sjon-export-version'], " },
            },
        },
        // Every package manifest in the repo carries the one semver from
        // src/version.zig. Bump the truth there; this names each manifest
        // that still needs its hand-edit. The Cargo.toml anchor rides on the
        // `name` line so dependency `version = "…"` pins can never match.
        .{
            .name = "package semver",
            .truth = .{ .str = sjon.version },
            .copies = &.{
                .{ .path = "build.zig.zon", .anchor = ".version = " },
                .{ .path = "package.json", .anchor = "\"version\": " },
                .{ .path = "hosts/schema/package.json", .anchor = "\"version\": " },
                .{ .path = "hosts/web/package.json", .anchor = "\"version\": " },
                .{ .path = "hosts/typescript-parity/package.json", .anchor = "\"version\": " },
                .{ .path = "hosts/highlight/package.json", .anchor = "\"version\": " },
                .{ .path = "landing-page/package.json", .anchor = "\"version\": " },
                .{ .path = "editors/vscode/package.json", .anchor = "\"version\": " },
                .{ .path = "hosts/rust/Cargo.toml", .anchor = "name = \"sjon-host\"\nversion = " },
            },
        },
    };

    try out.writeAll("format-version audit\n");

    var fail_count: usize = 0;
    var copy_count: usize = 0;
    for (facts) |fact| {
        try out.print("  {s} = {f}\n", .{ fact.name, TruthFmt{ .t = fact.truth } });
        for (fact.copies) |copy| {
            copy_count += 1;
            const bytes = Io.Dir.cwd().readFileAlloc(io, copy.path, gpa, .unlimited) catch |err| {
                try out.print("    FAIL  {s}: cannot read ({s})\n", .{ copy.path, @errorName(err) });
                fail_count += 1;
                continue;
            };
            defer gpa.free(bytes);
            switch (checkCopy(bytes, copy.anchor, fact.truth)) {
                .ok => |n| try out.print("    ok    {s}  ({d}×)\n", .{ copy.path, n }),
                .vanished => {
                    try out.print(
                        "    FAIL  {s}: anchor \"{s}\" not found — re-point it\n",
                        .{ copy.path, copy.anchor },
                    );
                    fail_count += 1;
                },
                .mismatch => |m| {
                    try out.print(
                        "    FAIL  {s}: after \"{s}\" have `{s}`, want {f}\n",
                        .{ copy.path, copy.anchor, m.got, TruthFmt{ .t = fact.truth } },
                    );
                    fail_count += 1;
                },
            }
        }
    }

    try out.print(
        "\n{d} facts, {d} copies, {d} failure(s)\n",
        .{ facts.len, copy_count, fail_count },
    );
    return if (fail_count == 0) 0 else 1;
}

// ---------------------------------------------------------------------------
// Truth resolution (text-anchored) — exactly one occurrence, parseable int.
// ---------------------------------------------------------------------------

/// Resolve a text-anchored integer truth: the anchor must occur exactly once
/// (there is only one declaration of each truth), and the token after it must
/// parse as an int. Returns `error.AnchorNotFound` / `AnchorAmbiguous` /
/// `BadToken`; file-read errors are inferred in.
fn resolveIntTruth(io: Io, gpa: Allocator, path: []const u8, anchor: []const u8) !u64 {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);

    var count: usize = 0;
    var after: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, pos, anchor)) |idx| {
        count += 1;
        after = idx + anchor.len;
        pos = idx + anchor.len;
    }
    if (count == 0) return error.AnchorNotFound;
    if (count > 1) return error.AnchorAmbiguous;
    return parseIntToken(extractToken(bytes[after..])) orelse error.BadToken;
}

// ---------------------------------------------------------------------------
// Copy checking — ≥1 occurrence, every occurrence must equal the truth.
// ---------------------------------------------------------------------------

const CopyResult = union(enum) {
    ok: usize, // occurrence count, all matched
    vanished, // zero occurrences
    mismatch: struct { got: []const u8 }, // first occurrence that differed
};

fn checkCopy(bytes: []const u8, anchor: []const u8, truth: Truth) CopyResult {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, pos, anchor)) |idx| {
        const after = idx + anchor.len;
        pos = after;
        count += 1;
        const token = extractToken(bytes[after..]);
        if (!truthMatches(truth, token)) return .{ .mismatch = .{ .got = token } };
    }
    if (count == 0) return .vanished;
    return .{ .ok = count };
}

// ---------------------------------------------------------------------------
// Token extraction + normalization.
// ---------------------------------------------------------------------------

/// The value token immediately after an anchor: a quoted string (through its
/// closing quote) or a run of identifier characters (`0x04`, `2`, `1`). Leading
/// whitespace is skipped so an anchor need not end in a space.
fn extractToken(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) : (start += 1) {}
    const rest = s[start..];
    if (rest.len == 0) return rest;
    const q = rest[0];
    if (q == '\'' or q == '"') {
        if (std.mem.indexOfScalar(u8, rest[1..], q)) |end| return rest[0 .. end + 2];
        return rest; // unterminated — return as-is, comparison will fail
    }
    var i: usize = 0;
    while (i < rest.len and (std.ascii.isAlphanumeric(rest[i]) or rest[i] == '_')) : (i += 1) {}
    return rest[0..i];
}

fn stripQuotes(token: []const u8) []const u8 {
    if (token.len >= 2) {
        const q = token[0];
        if ((q == '\'' or q == '"') and token[token.len - 1] == q) return token[1 .. token.len - 1];
    }
    return token;
}

fn parseIntToken(token: []const u8) ?u64 {
    if (token.len == 0) return null;
    if (token.len > 2 and (std.mem.startsWith(u8, token, "0x") or std.mem.startsWith(u8, token, "0X")))
        return std.fmt.parseInt(u64, token[2..], 16) catch null;
    return std.fmt.parseInt(u64, token, 10) catch null;
}

fn truthMatches(truth: Truth, token: []const u8) bool {
    return switch (truth) {
        .int => |v| if (parseIntToken(token)) |n| n == v else false,
        .str => |s| std.mem.eql(u8, stripQuotes(token), s),
    };
}

// ---------------------------------------------------------------------------
// Formatting.
// ---------------------------------------------------------------------------

const TruthFmt = struct {
    t: Truth,
    pub fn format(self: TruthFmt, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.t) {
            .int => |v| try w.print("{d}", .{v}),
            .str => |s| try w.print("\"{s}\"", .{s}),
        }
    }
};

test "extractToken: unquoted hex, dec, and quoted string" {
    try std.testing.expectEqualStrings("0x04", extractToken("0x04);"));
    try std.testing.expectEqualStrings("2", extractToken("2;"));
    try std.testing.expectEqualStrings("1", extractToken("1),"));
    try std.testing.expectEqualStrings("'1.1'", extractToken("'1.1';"));
    try std.testing.expectEqualStrings("\"1.1\"", extractToken("\"1.1\";"));
    try std.testing.expectEqualStrings("2", extractToken("  2;")); // leading ws
}

test "parseIntToken: hex equals decimal" {
    try std.testing.expectEqual(@as(?u64, 4), parseIntToken("0x04"));
    try std.testing.expectEqual(@as(?u64, 4), parseIntToken("4"));
    try std.testing.expectEqual(@as(?u64, 83), parseIntToken("0x53"));
    try std.testing.expectEqual(@as(?u64, null), parseIntToken("nope"));
}

test "truthMatches: int and string normalization" {
    try std.testing.expect(truthMatches(.{ .int = 4 }, "0x04"));
    try std.testing.expect(truthMatches(.{ .int = 2 }, "2"));
    try std.testing.expect(!truthMatches(.{ .int = 2 }, "3"));
    try std.testing.expect(truthMatches(.{ .str = "1.1" }, "'1.1'"));
    try std.testing.expect(truthMatches(.{ .str = "1.1" }, "\"1.1\""));
    try std.testing.expect(!truthMatches(.{ .str = "1.1" }, "'1.2'"));
}

test "checkCopy: vanished, ok-with-duplicates, mismatch" {
    const truth: Truth = .{ .int = 83 };
    switch (checkCopy("nothing here", "bin[0], ", truth)) {
        .vanished => {},
        else => try std.testing.expect(false),
    }
    // Two legitimate occurrences of the same correct value → ok(2).
    const dup = "assert.equal(bin[0], 0x53);\nassert.equal(bin[0], 0x53); // again";
    switch (checkCopy(dup, "bin[0], ", truth)) {
        .ok => |n| try std.testing.expectEqual(@as(usize, 2), n),
        else => try std.testing.expect(false),
    }
    switch (checkCopy("assert.equal(bin[0], 0x99);", "bin[0], ", truth)) {
        .mismatch => |m| try std.testing.expectEqualStrings("0x99", m.got),
        else => try std.testing.expect(false),
    }
}

test "schemaExportVersion tracks the Model field default" {
    // Mirrors the compiled truth the audit uses; guards the reflection helper.
    try std.testing.expectEqual(@as(u64, 1), schemaExportVersion());
}
