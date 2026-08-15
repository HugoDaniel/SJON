//! Build-time gate for `sjon-lsp.wasm`'s one hard invariant: it
//! instantiates with **zero imports**.
//!
//! The playground and `gen-lsp-meta.mjs` both call
//! `WebAssembly.instantiate(mod, {})`, so a single declared import makes
//! the artifact fail to load outright — not degrade, fail. That is a
//! production outage, and it has happened once already (`build.zig`'s
//! `wasm_plugin_host = false` options module exists because of it).
//!
//! Until now the invariant was checked only at *runtime*, by
//! `check-examples` (in verify) and `gen-lsp-meta` (not in verify) — both
//! of which discover it by trying to instantiate. One `wasm_plugin_host`
//! flag mixup away from breaking with no build-time signal, and the
//! runtime failure names a missing import rather than the flag.
//!
//! So: read the artifact's import section directly. `extern` declarations
//! become wasm imports on wasm32-freestanding, which is exactly the class
//! the column-0 source scan in `audit_wasm_imports.zig` cannot see — this
//! checks the linked binary instead of the source graph, and the two are
//! complementary.
//!
//! Usage: audit-lsp-wasm-imports <path-to-sjon-lsp.wasm>

const std = @import("std");
const Io = std.Io;

/// Section id of the wasm import section (wasm core spec §5.5.5).
const IMPORT_SECTION_ID: u8 = 2;

const MAGIC = [_]u8{ 0x00, 0x61, 0x73, 0x6d };

/// A cursor over the module bytes. Every read is bounds-checked — the
/// input is a build artifact, but a truncated one must produce a clear
/// message rather than a panic.
const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, n: usize) ?[]const u8 {
        if (self.pos + n > self.bytes.len) return null;
        const out = self.bytes[self.pos..][0..n];
        self.pos += n;
        return out;
    }

    fn byte(self: *Reader) ?u8 {
        const b = self.take(1) orelse return null;
        return b[0];
    }

    /// Unsigned LEB128, as every wasm length and count is encoded.
    fn uleb(self: *Reader) ?u32 {
        var result: u32 = 0;
        var shift: u5 = 0;
        while (true) {
            const b = self.byte() orelse return null;
            const payload: u32 = b & 0x7f;
            result |= payload << shift;
            if (b & 0x80 == 0) return result;
            if (shift >= 28) return null; // malformed / over-long
            shift += 7;
        }
    }

    /// A length-prefixed UTF-8 name (module or field).
    fn name(self: *Reader) ?[]const u8 {
        const len = self.uleb() orelse return null;
        return self.take(len);
    }
};

/// Number of imports declared by `bytes`, or an error describing why the
/// module could not be read. Absent import section ⇒ 0.
const Scan = union(enum) {
    ok: u32,
    /// Import section present and non-empty; `list` holds `module.field`
    /// pairs for the message.
    imports: struct { count: u32, first: []const u8 },
    malformed: []const u8,
};

fn scanImports(bytes: []const u8, buf: []u8) Scan {
    var r: Reader = .{ .bytes = bytes };
    const magic = r.take(4) orelse return .{ .malformed = "file shorter than the 4-byte magic" };
    if (!std.mem.eql(u8, magic, &MAGIC)) return .{ .malformed = "not a wasm module (bad magic)" };
    _ = r.take(4) orelse return .{ .malformed = "missing version word" };

    while (r.pos < bytes.len) {
        const id = r.byte() orelse return .{ .malformed = "truncated section id" };
        const size = r.uleb() orelse return .{ .malformed = "truncated section size" };
        const body = r.take(size) orelse return .{ .malformed = "section size runs past end of file" };
        if (id != IMPORT_SECTION_ID) continue;

        var sec: Reader = .{ .bytes = body };
        const count = sec.uleb() orelse return .{ .malformed = "truncated import count" };
        if (count == 0) return .{ .ok = 0 };

        const mod = sec.name() orelse return .{ .malformed = "truncated import module name" };
        const field = sec.name() orelse return .{ .malformed = "truncated import field name" };
        const first = std.fmt.bufPrint(buf, "{s}.{s}", .{ mod, field }) catch "…";
        return .{ .imports = .{ .count = count, .first = first } };
    }
    // No import section at all — the expected shape.
    return .{ .ok = 0 };
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var out_file = Io.File.stdout();
    var out_writer = out_file.writer(io, &out_buf);
    defer out_writer.interface.flush() catch {};
    const out = &out_writer.interface;

    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try out.print("audit-lsp-wasm-imports: expected a path to sjon-lsp.wasm\n", .{});
        return 2;
    }
    const path = args[1];

    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| {
        try out.print("audit-lsp-wasm-imports: cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return 2;
    };

    var name_buf: [512]u8 = undefined;
    switch (scanImports(bytes, &name_buf)) {
        .ok => {
            try out.print(
                "audit-lsp-wasm-imports: OK — {s} declares no imports ({d} bytes).\n",
                .{ path, bytes.len },
            );
            return 0;
        },
        .imports => |i| {
            try out.print(
                "audit-lsp-wasm-imports: FAIL — {s} declares {d} import(s), first `{s}`.\n\n" ++
                    "The playground and gen-lsp-meta.mjs instantiate this artifact with no\n" ++
                    "imports (`instantiate(mod, {{}})`), so any declared import makes it fail to\n" ++
                    "load outright — a production outage, not a degradation.\n\n" ++
                    "Usual cause: an `extern` declaration reached the linked module. On\n" ++
                    "wasm32-freestanding those become imports. Check that `sjon-lsp.wasm` is\n" ++
                    "built with the `wasm_plugin_host = false` options module (build.zig).\n",
                .{ path, i.count, i.first },
            );
            return 1;
        },
        .malformed => |why| {
            try out.print("audit-lsp-wasm-imports: FAIL — {s}: {s}\n", .{ path, why });
            return 1;
        },
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// Header of any valid module: magic + version.
const HEADER = MAGIC ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 };

test "a module with no sections declares no imports" {
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(u32, 0), scanImports(&HEADER, &buf).ok);
}

test "an empty import section declares no imports" {
    // id=2, size=1, count=0
    const m = HEADER ++ [_]u8{ 0x02, 0x01, 0x00 };
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(u32, 0), scanImports(&m, &buf).ok);
}

test "a non-empty import section is reported with its first name" {
    // id=2, size, count=1, "env", "f", kind=func, typeidx=0
    const body = [_]u8{ 0x01, 0x03, 'e', 'n', 'v', 0x01, 'f', 0x00, 0x00 };
    const m = HEADER ++ [_]u8{ 0x02, body.len } ++ body;
    var buf: [64]u8 = undefined;
    const got = scanImports(&m, &buf);
    try testing.expectEqual(@as(u32, 1), got.imports.count);
    try testing.expectEqualStrings("env.f", got.imports.first);
}

test "other sections are skipped, not misread as imports" {
    // A type section (id=1) sitting before an empty import section.
    const m = HEADER ++ [_]u8{ 0x01, 0x01, 0x00 } ++ [_]u8{ 0x02, 0x01, 0x00 };
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(u32, 0), scanImports(&m, &buf).ok);
}

test "malformed input is diagnosed, never panics" {
    var buf: [64]u8 = undefined;
    try testing.expect(scanImports("", &buf) == .malformed);
    try testing.expect(scanImports("nope", &buf) == .malformed);
    try testing.expect(scanImports(&(MAGIC ++ [_]u8{0x01}), &buf) == .malformed);
    // Section claiming more bytes than remain.
    try testing.expect(scanImports(&(HEADER ++ [_]u8{ 0x02, 0x7f }), &buf) == .malformed);
}

test "uleb128 decodes multi-byte lengths" {
    var r: Reader = .{ .bytes = &[_]u8{ 0xE5, 0x8E, 0x26 } };
    try testing.expectEqual(@as(u32, 624485), r.uleb().?);
}
