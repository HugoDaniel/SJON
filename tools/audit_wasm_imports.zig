//! Import-closure gate for the read-only `sjon-binary.wasm` artifact.
//!
//! The read-only artifact contract: `sjon-binary.wasm` (entry
//! `src/wasm_binary.zig`) must **never** import `Parser`, `Printer`,
//! `Json`, `Edit`, or the write-side `Binary` — the artifact's whole
//! point is to ship the IR consumer without dragging in `std.json`, the
//! parser, the printer, or edit logic. Today only dead-code elimination
//! backstops that rule; a stray file-scope import bloats the artifact and
//! nothing fails at build time. This tool makes the rule a *legible* gate:
//! BFS the import closure from the entry and fail, naming the exact chain,
//! if it reaches a write-side / host module.
//!
//! ## The column-0 rule
//!
//! Only **column-0** `@import("*.zig")` lines are followed — a file-scope
//! `const X = @import("Y.zig");` whose `const` sits at the left margin.
//! That is precisely how production dependencies are declared repo-wide;
//! a genuinely test-only or lazy reference lives brace-indented inside a
//! `fn` / `test` body (convention documented at `PatternQuery.zig`'s
//! `roundTrip`: "The local Parser import is test-only, so it does not
//! enter this module's wasm closure"). Scanning column-0 lines therefore
//! matches the closure the linker actually pulls into the artifact.
//!
//! A consequence, by design: a *test-only* import written at column 0
//! (file scope) IS flagged. The fix is to localize it into the test body
//! (where it belongs and costs nothing), not to weaken the checker.
//!
//! ## Allowlist, not blocklist
//!
//! `ALLOWED` enumerates the intended closure and everything else fails.
//! This inverted in r1-06: the previous `FORBIDDEN` list only caught the
//! write-side modules someone had thought to name, and had already
//! decayed — `PluginRuntime.zig` and `runtimes/wasmtime.zig` were sitting
//! in the closure, unlisted and therefore green. A stale `ALLOWED` entry
//! (listed but no longer reached) is also a failure, so the list cannot
//! drift away from reality in either direction.
//!
//! ## Blind spot (acceptable)
//!
//! An `@import` inside a function body (indented) evades this scan. That
//! is fine: such an import is a local/lazy reference, and the WASM
//! DCE pass still strips anything the exports don't reach, so a
//! genuinely-unused forbidden import cannot bloat the binary. DCE is the
//! backstop; this gate is the *early, named* signal DCE can't give — a
//! build-time chain instead of a mysterious size regression.
//!
//! Reads source as text (no `sjon` import) so it stays a cheap leaf tool.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Entry point of the read-only artifact's import closure (src-relative).
const ENTRY = "wasm_binary.zig";
const SRC_PREFIX = "src/";

/// One member of the intended read-only closure, with the role that earns
/// it a place there.
///
/// This is an **allowlist**, deliberately — it used to be a list of
/// forbidden modules, which is the weaker shape: it only catches the
/// write-side files someone thought to enumerate. It had already decayed.
/// `PluginRuntime.zig` and `runtimes/wasmtime.zig` entered the closure
/// (via `wasm_plugin_invoker.zig`'s comptime-gated import) and passed
/// clean, because nobody had added them to FORBIDDEN — as had
/// `Explanations.zig`, `FilesystemResolver.zig`, `Lockfile.zig`,
/// `wasm.zig`, and the `wasm_host_*` files. An allowlist inverts the
/// default: a new arrival fails until someone states why it belongs.
const Allowed = struct {
    path: []const u8,
    why: []const u8,
    /// True when the module is reachable in *text* but comptime-excluded
    /// from the wasm32 artifact. See `COMPTIME_NOTE`.
    comptime_excluded: bool = false,
};

/// Why two host-runtime modules sit in a read-only artifact's closure.
const COMPTIME_NOTE =
    "reached only through `wasm_plugin_invoker.zig`'s " ++
    "`if (native_plugin_exec) @import(...)`, which is false on wasm32 — " ++
    "so it is textually reachable but never linked into the artifact. " ++
    "This is the one audited exception to the column-0 rule.";

const ALLOWED = [_]Allowed{
    .{ .path = "wasm_binary.zig", .why = "the entry point itself" },
    .{ .path = "wasm_common.zig", .why = "the shared framing protocol + value envelope" },
    .{ .path = "version.zig", .why = "the version string" },
    .{ .path = "Ast.zig", .why = "the SoA tree + wire-stable Diagnostic.Code" },
    .{ .path = "BinaryCursor.zig", .why = "the single-pass IR reader — the artifact's whole job" },
    .{ .path = "BinaryFormat.zig", .why = "wire-format constants and header parsing" },
    .{ .path = "Schema.zig", .why = "schema lookup over registered plugins" },
    .{ .path = "Plugin.zig", .why = "the plugin vocabulary types" },
    .{ .path = "Validator.zig", .why = "the binary validation walk" },
    .{ .path = "Expr.zig", .why = "evalBinary — expression evaluation over IR" },
    .{ .path = "MaterializedDefaults.zig", .why = "the defaults overlay the validator reads" },
    .{ .path = "Pattern.zig", .why = "tick algebra for pattern queries" },
    .{ .path = "PatternQuery.zig", .why = "the pattern query engine" },
    .{ .path = "PluginValueCodec.zig", .why = "plugin value encoding across the ABI" },
    .{ .path = "StringFormats.zig", .why = "named :format checkers used by string-bounds" },
    .{ .path = "Date.zig", .why = "date atoms (leaf, std-only)" },
    .{ .path = "Time.zig", .why = "time atoms (leaf, std-only)" },
    .{ .path = "trig.zig", .why = "vendored transcendentals — native/wasm bit reproducibility" },
    .{ .path = "plugins/core.zig", .why = "the core expression vocabulary" },
    .{ .path = "plugins/pattern.zig", .why = "the pattern combinator vocabulary" },
    .{ .path = "wasm_plugin_invoker.zig", .why = "host-invoke bridge; declarative-only unless -Dwasm-plugin-host" },
    .{ .path = "PluginRuntime.zig", .why = COMPTIME_NOTE, .comptime_excluded = true },
    .{ .path = "runtimes/wasmtime.zig", .why = COMPTIME_NOTE, .comptime_excluded = true },
};

/// The allowlist entry for `path`, or null when it does not belong in the
/// read-only closure.
fn allowedEntry(path: []const u8) ?Allowed {
    for (ALLOWED) |e| {
        if (std.mem.eql(u8, path, e.path)) return e;
    }
    return null;
}

/// Why `path` must not appear, for the common write-side modules. Falls
/// back to a generic message so an unrecognised newcomer still fails.
fn whyForbidden(path: []const u8) []const u8 {
    const known = [_]struct { pat: []const u8, why: []const u8 }{
        .{ .pat = "Parser.zig", .why = "the text parser — the read-only artifact decodes IR, never parses source" },
        .{ .pat = "Printer.zig", .why = "the canonical printer — write-side only" },
        .{ .pat = "Json.zig", .why = "the std.json bridge — the artifact exists to avoid std.json" },
        .{ .pat = "Edit.zig", .why = "structural edits — write-side only" },
        .{ .pat = "Binary.zig", .why = "the write-side Binary encoder/decoder — read IR via BinaryCursor + BinaryFormat" },
        .{ .pat = "Host.zig", .why = "the validating host — drags in Parser / ManifestLoader / Lowering / SchemaExport" },
        .{ .pat = "ManifestLoader.zig", .why = "manifest loading — host/write-side" },
        .{ .pat = "Lowering.zig", .why = "form lowering — host-side" },
        .{ .pat = "root.zig", .why = "the kitchen-sink aggregate — pulls the entire write side" },
        .{ .pat = "Lexer.zig", .why = "the lexer — text tokenization, parse-side" },
        .{ .pat = "SchemaExport/", .why = "the schema exporter — host/write-side codegen" },
    };
    for (known) |k| {
        if (std.mem.startsWith(u8, path, k.pat)) return k.why;
    }
    return "not on the read-only allowlist — if it genuinely belongs, add it to ALLOWED with its role";
}

/// A visited module in the BFS. `parent` threads the discovery chain back
/// to the entry so a forbidden hit can print how it was reached.
const Node = struct { path: []const u8, parent: ?usize };

/// A forbidden module reached from the entry closure.
const Finding = struct { via: usize, path: []const u8, line: usize };

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var out_buf: [8192]u8 = undefined;
    var out_file = Io.File.stdout();
    var out_writer = out_file.writer(io, &out_buf);
    defer out_writer.interface.flush() catch {};
    const out = &out_writer.interface;

    // Short-lived tool: one arena, freed at process exit.
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var nodes: std.ArrayList(Node) = .empty;
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    var reported: std.StringHashMapUnmanaged(void) = .empty;
    var findings: std.ArrayList(Finding) = .empty;

    try nodes.append(arena, .{ .path = ENTRY, .parent = null });
    try visited.put(arena, ENTRY, {});

    var i: usize = 0;
    while (i < nodes.items.len) : (i += 1) {
        const node = nodes.items[i];
        const full = try std.fmt.allocPrint(arena, SRC_PREFIX ++ "{s}", .{node.path});
        const bytes = Io.Dir.cwd().readFileAlloc(io, full, arena, .unlimited) catch |err| {
            try out.print("audit-wasm-imports: cannot read {s}: {s}\n", .{ full, @errorName(err) });
            return 2;
        };
        const dir = dirOf(node.path);

        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            if (!isColumnZero(line)) continue;
            var imports: std.ArrayList([]const u8) = .empty;
            try collectImports(arena, line, &imports);
            for (imports.items) |raw| {
                if (!std.mem.endsWith(u8, raw, ".zig")) continue; // std, build_options
                const resolved = try normalizeJoin(arena, dir, raw);
                if (allowedEntry(resolved) == null) {
                    // Sink: record the reach, do NOT descend into it (so a
                    // single forbidden module reports one chain, not its
                    // whole downstream fan-out).
                    if (!reported.contains(resolved)) {
                        try reported.put(arena, resolved, {});
                        try findings.append(arena, .{ .via = i, .path = resolved, .line = line_no });
                    }
                    continue;
                }
                if (!visited.contains(resolved)) {
                    try visited.put(arena, resolved, {});
                    try nodes.append(arena, .{ .path = resolved, .parent = i });
                }
            }
        }
    }

    // A stale allowlist entry — listed but no longer reached — is a
    // failure too. Same self-cleaning rule as the diagnostics allowlist:
    // the list can only shrink by accident, never grow by accident.
    var stale: std.ArrayList([]const u8) = .empty;
    for (ALLOWED) |e| {
        if (!visited.contains(e.path)) try stale.append(arena, e.path);
    }

    if (findings.items.len == 0 and stale.items.len == 0) {
        var linked: usize = 0;
        for (ALLOWED) |e| {
            if (!e.comptime_excluded) linked += 1;
        }
        try out.print(
            "audit-wasm-imports: OK — src/{s} import closure is exactly the {d} allowlisted module(s)" ++
                " ({d} linked, {d} comptime-excluded on wasm32).\n",
            .{ ENTRY, nodes.items.len, linked, nodes.items.len - linked },
        );
        return 0;
    }

    if (stale.items.len > 0) {
        try out.print(
            "audit-wasm-imports: FAIL — {d} allowlisted module(s) are no longer in the closure.\n" ++
                "Delete them from ALLOWED so the list keeps describing reality:\n\n",
            .{stale.items.len},
        );
        for (stale.items) |p| try out.print("  - {s}\n", .{p});
        try out.print("\n", .{});
        if (findings.items.len == 0) return 1;
    }

    try out.print(
        "audit-wasm-imports: FAIL — src/{s} reaches {d} module(s) outside the allowlist.\n\n" ++
            "The read-only sjon-binary.wasm artifact ships the IR consumer and nothing\n" ++
            "else (the read-only artifact contract). Unlisted reaches:\n\n",
        .{ ENTRY, findings.items.len },
    );
    for (findings.items) |f| {
        try out.print("  x {s}\n      {s}\n      ", .{ f.path, whyForbidden(f.path) });
        try printChain(out, nodes.items, f.via, f.path);
        try out.print("   (src/{s}:{d})\n\n", .{ nodes.items[f.via].path, f.line });
    }
    try out.print(
        "{d} forbidden reach(es). Localize a test-only import into its fn/test body, or\n" ++
            "move shared wire vocabulary into a leaf module. See the tool header for the\n" ++
            "column-0 scan rule and its (DCE-backstopped) blind spot.\n",
        .{findings.items.len},
    );
    return 1;
}

/// Print `entry → … → via → forbidden` by walking parent pointers.
fn printChain(out: *std.Io.Writer, nodes: []const Node, via: usize, forbidden: []const u8) !void {
    var stack: [256][]const u8 = undefined;
    var n: usize = 0;
    var cur: ?usize = via;
    while (cur) |c| {
        stack[n] = nodes[c].path;
        n += 1;
        cur = nodes[c].parent;
        if (n == stack.len) break;
    }
    while (n > 0) {
        n -= 1;
        try out.print("{s} \u{2192} ", .{stack[n]});
    }
    try out.print("{s}", .{forbidden});
}

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested below).
// ---------------------------------------------------------------------------

/// Directory portion of a src-relative path ("" for a top-level file).
fn dirOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[0..idx];
    return "";
}

/// True when `line` begins at column 0 (no leading whitespace) — the
/// marker for a file-scope, production `const X = @import(...)` line.
fn isColumnZero(line: []const u8) bool {
    return line.len > 0 and line[0] != ' ' and line[0] != '\t';
}

const IMPORT_NEEDLE = "@import(\"";

/// Append every `@import("…")` argument on `line` to `out` (slices into
/// `line`; the `.zig` filter is applied by the caller so the helper stays
/// dumb). An unterminated `@import("` is skipped.
fn collectImports(gpa: Allocator, line: []const u8, out: *std.ArrayList([]const u8)) !void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, line, pos, IMPORT_NEEDLE)) |idx| {
        const start = idx + IMPORT_NEEDLE.len;
        const end_rel = std.mem.indexOfScalar(u8, line[start..], '"') orelse {
            pos = start;
            continue;
        };
        try out.append(gpa, line[start .. start + end_rel]);
        pos = start + end_rel + 1;
    }
}

/// Join `base_dir` (src-relative, possibly "") with an `@import` argument
/// `rel`, collapsing `.` / `..` / empty segments. Returns an owned,
/// src-relative, forward-slashed path.
fn normalizeJoin(gpa: Allocator, base_dir: []const u8, rel: []const u8) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);

    var it_base = std.mem.splitScalar(u8, base_dir, '/');
    while (it_base.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        try parts.append(gpa, seg);
    }
    var it_rel = std.mem.splitScalar(u8, rel, '/');
    while (it_rel.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        try parts.append(gpa, seg);
    }
    return try std.mem.join(gpa, "/", parts.items);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "dirOf: top-level, one, and two segments" {
    try testing.expectEqualStrings("", dirOf("Ast.zig"));
    try testing.expectEqualStrings("plugins", dirOf("plugins/core.zig"));
    try testing.expectEqualStrings("SchemaExport", dirOf("SchemaExport/SchemaExport.zig"));
}

test "isColumnZero: file-scope vs indented vs blank" {
    try testing.expect(isColumnZero("const Ast = @import(\"Ast.zig\");"));
    try testing.expect(!isColumnZero("    const Parser = @import(\"Parser.zig\");"));
    try testing.expect(!isColumnZero("\tconst x = 1;"));
    try testing.expect(!isColumnZero(""));
}

test "collectImports: every arg, unfiltered by extension" {
    const a = testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(a);
    try collectImports(a, "const Ast = @import(\"Ast.zig\");", &out);
    try collectImports(a, "const v = @import(\"version.zig\").string;", &out);
    try collectImports(a, "const s = @import(\"std\");", &out);
    try collectImports(a, "no imports on this line", &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("Ast.zig", out.items[0]);
    try testing.expectEqualStrings("version.zig", out.items[1]);
    try testing.expectEqualStrings("std", out.items[2]);
}

test "normalizeJoin: collapses . and .. against the importing dir" {
    const a = testing.allocator;
    const cases = [_]struct { base: []const u8, rel: []const u8, want: []const u8 }{
        .{ .base = "", .rel = "Ast.zig", .want = "Ast.zig" },
        .{ .base = "plugins", .rel = "../Ast.zig", .want = "Ast.zig" },
        .{ .base = "plugins", .rel = "./pattern.zig", .want = "plugins/pattern.zig" },
        .{ .base = "SchemaExport", .rel = "Model.zig", .want = "SchemaExport/Model.zig" },
        .{ .base = "a/b", .rel = "../../x.zig", .want = "x.zig" },
    };
    for (cases) |c| {
        const got = try normalizeJoin(a, c.base, c.rel);
        defer a.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "allowedEntry: the read-only set passes, write-side modules do not" {
    // Members of the intended closure.
    try testing.expect(allowedEntry("Ast.zig") != null);
    try testing.expect(allowedEntry("BinaryCursor.zig") != null);
    try testing.expect(allowedEntry("Validator.zig") != null);
    try testing.expect(allowedEntry("Expr.zig") != null);
    try testing.expect(allowedEntry("plugins/core.zig") != null);

    // Write-side / host modules.
    try testing.expect(allowedEntry("Parser.zig") == null);
    try testing.expect(allowedEntry("Binary.zig") == null);
    try testing.expect(allowedEntry("Host.zig") == null);
    try testing.expect(allowedEntry("SchemaExport/Model.zig") == null);
    try testing.expect(allowedEntry("SchemaExport/SchemaExport.zig") == null);

    // The point of inverting: a module nobody thought to forbid — every
    // one of these was in the real closure or one edit away, and passed
    // clean under the old blocklist.
    try testing.expect(allowedEntry("Explanations.zig") == null);
    try testing.expect(allowedEntry("FilesystemResolver.zig") == null);
    try testing.expect(allowedEntry("Lockfile.zig") == null);
    try testing.expect(allowedEntry("wasm.zig") == null);
    try testing.expect(allowedEntry("Glob.zig") == null);
}

test "whyForbidden: names the known write-side modules, falls back otherwise" {
    try testing.expect(std.mem.indexOf(u8, whyForbidden("Parser.zig"), "text parser") != null);
    try testing.expect(std.mem.indexOf(u8, whyForbidden("SchemaExport/Model.zig"), "schema exporter") != null);
    // An unrecognised newcomer still gets an actionable message.
    try testing.expect(std.mem.indexOf(u8, whyForbidden("BrandNew.zig"), "allowlist") != null);
}

test "comptime-excluded members are flagged as such, not silently linked" {
    // PluginRuntime / wasmtime reach the closure through
    // `wasm_plugin_invoker.zig`'s `if (native_plugin_exec) @import(...)`,
    // false on wasm32. They are allowed but must stay marked, so the OK
    // line never claims they ship in the artifact.
    try testing.expect(allowedEntry("PluginRuntime.zig").?.comptime_excluded);
    try testing.expect(allowedEntry("runtimes/wasmtime.zig").?.comptime_excluded);
    try testing.expect(!allowedEntry("BinaryCursor.zig").?.comptime_excluded);
}
