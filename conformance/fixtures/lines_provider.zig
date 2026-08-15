//! Conformance fixture — the portable half of the `lines` cross-ref
//! provider. Built by the top-level `plugin-fixtures` build step into
//! every `conformance/cases/cross-ref-provider-*/manifests/lines.wasm`
//! that needs it (the resolver pairs `lines.sjon` with `lines.wasm`).
//!
//! A provider call *is* a plugin call: same zero-import ABI as an
//! expr-func (`docs/executable-plugin-abi.md`), no version bump, one
//! `.string` argument in and one `.vector` of `.string` out. So this
//! module declares the three standard v2 exports plus two extractors:
//!
//!   - `extract_lines(args_ptr, args_len)` — one name per non-empty
//!     line. Refuses with a structured-error frame when the source
//!     carries `lines_extract.failure_marker`, which is how
//!     `cross-ref-provider-extraction-failed` reaches
//!     `cross_ref_extraction_failed` end-to-end.
//!   - `extract_lines_overflow(args_ptr, args_len)` — reads the source
//!     as a decimal count and emits that many names, so
//!     `cross-ref-provider-overflow` can trip
//!     `ProviderExtraction.MAX_EXTRACTED_NAMES` from a one-line
//!     document.
//!
//! Both drive `lines_extract`, which is also what the native `impl`
//! twin (`lines_plugin.zig`) links — the two routes share the one
//! definition of what counts as a name, so a corpus case that passes
//! here and there is proving agreement rather than coincidence.
//!
//! The value codec is hand-rolled to the slice this fixture needs
//! (string in, vector-of-string out) so the plugin has no host-side SDK
//! dependency; the byte layout is pinned cross-host by
//! `src/PluginValueCodec.zig`'s tests. Imports MUST be empty per spec
//! §7.1 — `std.heap.wasm_allocator` only reaches the
//! `@wasmMemoryGrow` / `@wasmMemorySize` intrinsics, never an `env.*`
//! import.

const std = @import("std");

const lines_extract = @import("lines_extract.zig");

const wasm_allocator = std.heap.wasm_allocator;

const TAG_STRING: u8 = 0x04;
const TAG_VECTOR: u8 = 0x06;
const FRAME_HEADER: usize = 8;

/// Per-name wire cost: tag byte + u32 length prefix.
const NAME_OVERHEAD: usize = 1 + 4;

export fn sjon_plugin_abi_version() callconv(.c) u32 {
    return 2;
}

export fn sjon_plugin_alloc(len: u32) callconv(.c) ?[*]u8 {
    if (len == 0) return null;
    const slice = wasm_allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

export fn sjon_plugin_free(ptr: ?[*]u8, len: u32) callconv(.c) void {
    if (len == 0) return;
    if (ptr) |p| wasm_allocator.free(p[0..len]);
}

export fn extract_lines(args_ptr: ?[*]const u8, args_len: u32) callconv(.c) ?[*]u8 {
    const source = readSourceArg(args_ptr, args_len) orelse return null;

    // Pass one: measure. Nothing is allocated until the whole source has
    // been walked, so a refusal costs no allocation at all.
    var payload_len: usize = 1 + 4;
    var count: u32 = 0;
    var measure = lines_extract.scan(source);
    while (measure.next()) |name| {
        payload_len += NAME_OVERHEAD + name.len;
        count += 1;
    }
    if (measure.refused) return refusalFrame(
        "malformed",
        "source carries the `" ++ lines_extract.failure_marker ++ "` marker line",
    );

    // Pass two: write. `Scan` is deterministic over the same bytes, so
    // the second walk yields exactly what the first one measured.
    const frame = beginVectorFrame(payload_len, count) orelse return null;
    var off: usize = FRAME_HEADER + 1 + 4;
    var write = lines_extract.scan(source);
    while (write.next()) |name| off = writeName(frame, off, name);
    return frame.ptr;
}

export fn extract_lines_overflow(args_ptr: ?[*]const u8, args_len: u32) callconv(.c) ?[*]u8 {
    const source = readSourceArg(args_ptr, args_len) orelse return null;

    const count = lines_extract.overflowCount(source) catch return refusalFrame(
        "malformed",
        "source is not a name count this fixture will spell",
    );

    var buf: [lines_extract.max_overflow_name_len]u8 = undefined;
    var payload_len: usize = 1 + 4;
    for (0..count) |i| payload_len += NAME_OVERHEAD + lines_extract.overflowName(&buf, i).len;

    const frame = beginVectorFrame(payload_len, @intCast(count)) orelse return null;
    var off: usize = FRAME_HEADER + 1 + 4;
    for (0..count) |i| off = writeName(frame, off, lines_extract.overflowName(&buf, i));
    return frame.ptr;
}

/// Args layout per §9.2 for a one-string call:
/// `[u32 count=1][u8 tag=0x04][u32 len][bytes]`. Any other shape is a
/// host bug or a hostile fixture, both surfaced as `null`.
fn readSourceArg(args_ptr: ?[*]const u8, args_len: u32) ?[]const u8 {
    const p = args_ptr orelse return null;
    const args = p[0..args_len];

    if (args.len < 9) return null;
    if (std.mem.readInt(u32, args[0..4], .little) != 1) return null;
    if (args[4] != TAG_STRING) return null;
    const len = std.mem.readInt(u32, args[5..9], .little);
    if (args.len < 9 + len) return null;
    return args[9 .. 9 + len];
}

/// Allocate an `ok=1` frame and write the header plus the vector's tag
/// and element count, leaving the elements to the caller.
fn beginVectorFrame(payload_len: usize, count: u32) ?[]u8 {
    const frame = wasm_allocator.alloc(u8, FRAME_HEADER + payload_len) catch return null;
    std.mem.writeInt(u32, frame[0..4], 1, .little);
    std.mem.writeInt(u32, frame[4..8], @intCast(payload_len), .little);
    frame[FRAME_HEADER] = TAG_VECTOR;
    std.mem.writeInt(u32, frame[FRAME_HEADER + 1 ..][0..4], count, .little);
    return frame;
}

/// One `[u8 tag=0x04][u32 len][bytes]` element; returns the next offset.
fn writeName(frame: []u8, off: usize, name: []const u8) usize {
    frame[off] = TAG_STRING;
    std.mem.writeInt(u32, frame[off + 1 ..][0..4], @intCast(name.len), .little);
    @memcpy(frame[off + 5 ..][0..name.len], name);
    return off + NAME_OVERHEAD + name.len;
}

/// §9.3 `ok=0` frame: `[u32 code_len][code][u32 detail_len][detail]`.
/// The host turns this into a `failure` entry in the extraction table,
/// which the index pass reports as `cross_ref_extraction_failed`.
fn refusalFrame(code: []const u8, detail: []const u8) ?[*]u8 {
    const payload_len = 4 + code.len + 4 + detail.len;
    const frame = wasm_allocator.alloc(u8, FRAME_HEADER + payload_len) catch return null;

    std.mem.writeInt(u32, frame[0..4], 0, .little);
    std.mem.writeInt(u32, frame[4..8], @intCast(payload_len), .little);

    var off: usize = FRAME_HEADER;
    std.mem.writeInt(u32, frame[off..][0..4], @intCast(code.len), .little);
    off += 4;
    @memcpy(frame[off..][0..code.len], code);
    off += code.len;
    std.mem.writeInt(u32, frame[off..][0..4], @intCast(detail.len), .little);
    off += 4;
    @memcpy(frame[off..][0..detail.len], detail);

    return frame.ptr;
}
