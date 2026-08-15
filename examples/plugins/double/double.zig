//! `double` — minimal executable-plugin fixture.
//!
//! Implements three expr-func bodies in a single freestanding wasm32
//! module that satisfies the full ABI surface
//! (`docs/executable-plugin-abi.md`):
//!
//!   - `sjon_plugin_abi_version()`     — returns 2.
//!   - `sjon_plugin_alloc(len)`        — alloc inside the plugin's linear memory.
//!   - `sjon_plugin_free(ptr, len)`    — paired free.
//!
//! The expr-func exports — picked to exercise both the happy path and
//! the host-detected dispatch-time failure modes from spec §10
//! end-to-end, plus the §18 stretch round-trip coverage — are:
//!
//!   - `double(args_ptr, args_len)`    — happy path: read one number,
//!     double it, frame `(ok=1, number)`.
//!   - `trap(args_ptr, args_len)`      — calls `unreachable`. Web/Rust
//!     hosts catch the trap and surface `plugin_func_trapped`.
//!   - `fail(args_ptr, args_len)`      — returns an `ok=0` structured-
//!     error frame with code `domain` and a deterministic detail string.
//!     Hosts surface this as `plugin_func_failed`.
//!   - `huge(args_ptr, args_len)`      — returns a frame whose header
//!     claims a ~4 GiB payload without actually allocating it. Hosts
//!     MUST cap the reported length before allocating mirror buffers;
//!     they surface the rejection as `plugin_func_alloc_failed`.
//!   - `tag(args_ptr, args_len)`       — identity on a keyword arg. Pins
//!     the `0x04` vs `0x05` tag distinction (string vs keyword) round-
//!     trip across the plugin boundary. Used by
//!     `plugin-exec-keyword-roundtrip`.
//!   - `vec3_length(args_ptr, args_len)` — `sqrt(x² + y² + z²)` over a
//!     3-element number vector. Proves nested-value round-trip; the
//!     happy-path `double` only crosses bare numbers. Used by
//!     `plugin-exec-vector-roundtrip`.
//!   - `vector_sum(args_ptr, args_len)`  — sums all numeric elements
//!     of an arbitrarily-sized number vector. Stress-tests the codec
//!     allocator path and the host's mirror-buffer cap at length
//!     boundaries. Used by `plugin-exec-large-vector`.
//!   - `form_arity(args_ptr, args_len)`  — reads a form arg whose
//!     children-vector is empty and whose kvpair values are all
//!     numbers, returns `children_count + kvpair_count`. Pins the
//!     `Tag.form` (`0x07`) wire payload across the plugin boundary.
//!     Used by `plugin-exec-form-roundtrip`.
//!   - `forms_arity_sum(args_ptr, args_len)` — same shape applied to
//!     a vector-of-form arg, summing each element's arity. Pins
//!     `Tag.form` inside `Tag.vector`. Used by
//!     `plugin-exec-form-roundtrip`.
//!
//! Hand-rolls just the slice of the binary value codec it needs (number
//! tag + framed result / structured-error frame) so the plugin has no
//! host-side SDK dependency; the byte layout is pinned cross-host by
//! `src/PluginValueCodec.zig`'s tests.
//!
//! Imports MUST be empty per spec §7.1 — `std.heap.wasm_allocator` only
//! uses the `@wasmMemoryGrow` / `@wasmMemorySize` intrinsics, never an
//! `env.*` import, so the produced module satisfies that constraint.

const std = @import("std");

const wasm_allocator = std.heap.wasm_allocator;

const TAG_NUMBER: u8 = 0x01;
const TAG_KEYWORD: u8 = 0x05;
const TAG_VECTOR: u8 = 0x06;
const TAG_FORM: u8 = 0x07;
const FRAME_HEADER: usize = 8;

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

export fn double(args_ptr: ?[*]const u8, args_len: u32) callconv(.c) ?[*]u8 {
    const p = args_ptr orelse return null;
    const args = p[0..args_len];

    // Args layout per §9.2: [u32 count=1][u8 tag=0x01][f64 bits].
    if (args.len < 13) return null;
    const count = std.mem.readInt(u32, args[0..4], .little);
    if (count != 1) return null;
    if (args[4] != TAG_NUMBER) return null;
    const bits = std.mem.readInt(u64, args[5..13], .little);
    const n: f64 = @bitCast(bits);

    const doubled: f64 = n * 2.0;
    const doubled_bits: u64 = @bitCast(doubled);

    // Result frame per §9.3 / §9.4:
    //   [u32 ok=1][u32 len=9][u8 tag=0x01][f64 doubled].
    const payload_len: u32 = 9;
    const total = FRAME_HEADER + payload_len;
    const frame = wasm_allocator.alloc(u8, total) catch return null;

    std.mem.writeInt(u32, frame[0..4], 1, .little);
    std.mem.writeInt(u32, frame[4..8], payload_len, .little);
    frame[8] = TAG_NUMBER;
    std.mem.writeInt(u64, frame[9..17], doubled_bits, .little);

    return frame.ptr;
}

/// Trap-on-call body. Argument shape is ignored — the host doesn't get
/// to see them. Used by host-side `plugin_func_trapped` coverage.
export fn trap(args_ptr: ?[*]const u8, args_len: u32) callconv(.c) ?[*]u8 {
    _ = args_ptr;
    _ = args_len;
    unreachable;
}

/// Returns a frame whose header claims a payload length far larger
/// than any reasonable plugin would emit (~4 GiB). The plugin only
/// allocates the 8-byte header — there is no real payload behind it.
/// Hosts MUST cap the reported length before allocating mirror
/// buffers; without the cap, the host would attempt a multi-GiB
/// allocation or read past the plugin's linear memory. Used by host-
/// side coverage of the oversized-frame rejection path.
export fn huge(args_ptr: ?[*]const u8, args_len: u32) callconv(.c) ?[*]u8 {
    _ = args_ptr;
    _ = args_len;

    const frame = wasm_allocator.alloc(u8, FRAME_HEADER) catch return null;
    std.mem.writeInt(u32, frame[0..4], 1, .little);
    std.mem.writeInt(u32, frame[4..8], 0xFFFFFFFF, .little);
    return frame.ptr;
}

/// Sum of an arbitrarily-sized number vector. Stress-tests the
/// codec's allocator/framing path at length boundaries; the host
/// must cap its mirror buffer before the plugin runs. Used by
/// `plugin-exec-large-vector` with a 10k-element vector. The decoder
/// rejects any non-number element tag — partial sums on hostile
/// input are uninteresting; we want a clean reject.
export fn vector_sum(args_ptr: ?[*]const u8, args_len: u32) callconv(.c) ?[*]u8 {
    const p = args_ptr orelse return null;
    const args = p[0..args_len];

    // Args layout: [u32 count=1][u8 tag=0x06][u32 vec_count=N]
    //              [u8 tag=0x01][f64] × N.
    if (args.len < 9) return null;
    const count = std.mem.readInt(u32, args[0..4], .little);
    if (count != 1) return null;
    if (args[4] != TAG_VECTOR) return null;
    const vec_count = std.mem.readInt(u32, args[5..9], .little);
    const expected: usize = 9 + @as(usize, vec_count) * 9;
    if (args.len < expected) return null;

    var sum: f64 = 0.0;
    var off: usize = 9;
    var i: u32 = 0;
    while (i < vec_count) : (i += 1) {
        if (args[off] != TAG_NUMBER) return null;
        off += 1;
        const bits = std.mem.readInt(u64, args[off..][0..8], .little);
        const n: f64 = @bitCast(bits);
        sum += n;
        off += 8;
    }
    const sum_bits: u64 = @bitCast(sum);

    // Result frame: [u32 ok=1][u32 len=9][u8 tag=0x01][f64].
    const payload_len: u32 = 9;
    const total = FRAME_HEADER + payload_len;
    const frame = wasm_allocator.alloc(u8, total) catch return null;

    std.mem.writeInt(u32, frame[0..4], 1, .little);
    std.mem.writeInt(u32, frame[4..8], payload_len, .little);
    frame[8] = TAG_NUMBER;
    std.mem.writeInt(u64, frame[9..17], sum_bits, .little);

    return frame.ptr;
}

/// `sqrt(x² + y² + z²)` over a 3-element number vector — proves
/// nested-value (vector-of-number) round-trip across the plugin
/// boundary. Used by `plugin-exec-vector-roundtrip`. The decoder
/// rejects any shape other than `[u32 count=1][u8 tag=0x06][u32
/// vec_count=3][u8 tag=0x01][f64] × 3]` — anything else is a host
/// bug or a hostile fixture, both surfaced as `null`.
export fn vec3_length(args_ptr: ?[*]const u8, args_len: u32) callconv(.c) ?[*]u8 {
    const p = args_ptr orelse return null;
    const args = p[0..args_len];

    // Args layout: [u32 count=1][u8 tag=0x06][u32 vec_count=3]
    //              [u8 tag=0x01][f64] × 3 = 4 + 1 + 4 + 3 * 9 = 36 bytes.
    if (args.len < 36) return null;
    const count = std.mem.readInt(u32, args[0..4], .little);
    if (count != 1) return null;
    if (args[4] != TAG_VECTOR) return null;
    const vec_count = std.mem.readInt(u32, args[5..9], .little);
    if (vec_count != 3) return null;

    var sumsq: f64 = 0.0;
    var off: usize = 9;
    inline for (0..3) |_| {
        if (args[off] != TAG_NUMBER) return null;
        off += 1;
        const bits = std.mem.readInt(u64, args[off..][0..8], .little);
        const n: f64 = @bitCast(bits);
        sumsq += n * n;
        off += 8;
    }
    const len: f64 = @sqrt(sumsq);
    const len_bits: u64 = @bitCast(len);

    // Result frame: [u32 ok=1][u32 len=9][u8 tag=0x01][f64].
    const payload_len: u32 = 9;
    const total = FRAME_HEADER + payload_len;
    const frame = wasm_allocator.alloc(u8, total) catch return null;

    std.mem.writeInt(u32, frame[0..4], 1, .little);
    std.mem.writeInt(u32, frame[4..8], payload_len, .little);
    frame[8] = TAG_NUMBER;
    std.mem.writeInt(u64, frame[9..17], len_bits, .little);

    return frame.ptr;
}

/// Identity on a keyword arg — `(tag :hello) → :hello`. Reads tag
/// `0x05` + length-prefixed UTF-8, frames the same back. Used by
/// `plugin-exec-keyword-roundtrip` to pin the `0x04` vs `0x05`
/// distinction across the plugin boundary.
export fn tag(args_ptr: ?[*]const u8, args_len: u32) callconv(.c) ?[*]u8 {
    const p = args_ptr orelse return null;
    const args = p[0..args_len];

    // Args layout per §9.2: [u32 count=1][u8 tag=0x05][u32 key_len][key_bytes].
    if (args.len < 9) return null;
    const count = std.mem.readInt(u32, args[0..4], .little);
    if (count != 1) return null;
    if (args[4] != TAG_KEYWORD) return null;
    const key_len = std.mem.readInt(u32, args[5..9], .little);
    if (args.len < 9 + key_len) return null;
    const key = args[9 .. 9 + key_len];

    // Result frame per §9.3 / §9.4:
    //   [u32 ok=1][u32 len][u8 tag=0x05][u32 key_len][key_bytes].
    const payload_len: u32 = @intCast(1 + 4 + key_len);
    const total = FRAME_HEADER + payload_len;
    const frame = wasm_allocator.alloc(u8, total) catch return null;

    std.mem.writeInt(u32, frame[0..4], 1, .little);
    std.mem.writeInt(u32, frame[4..8], payload_len, .little);
    frame[8] = TAG_KEYWORD;
    std.mem.writeInt(u32, frame[9..13], key_len, .little);
    @memcpy(frame[13 .. 13 + key_len], key);

    return frame.ptr;
}

/// Always returns a structured-error frame. Used by host-side
/// `plugin_func_failed` coverage. Code + detail are deterministic so
/// the assertion in the host test can match by value.
export fn fail(args_ptr: ?[*]const u8, args_len: u32) callconv(.c) ?[*]u8 {
    _ = args_ptr;
    _ = args_len;

    const code = "domain";
    const detail = "plugin reported a structured failure";

    // §9.3 ok=0 frame body: [u32 code_len][code][u32 detail_len][detail].
    const payload_len: u32 = @intCast(4 + code.len + 4 + detail.len);
    const total = FRAME_HEADER + payload_len;
    const frame = wasm_allocator.alloc(u8, total) catch return null;

    std.mem.writeInt(u32, frame[0..4], 0, .little); // ok = 0
    std.mem.writeInt(u32, frame[4..8], payload_len, .little);
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

/// Result of walking one flat form payload — the new offset lets the
/// caller chain walks (e.g. `forms_arity_sum` walking a vector of forms).
const FormWalk = struct { arity: u32, end: usize };

/// Walk a `Tag.form` payload starting at `start` (after the tag byte
/// has already been consumed). `head_len/head/ns_len/ns/child_count/
/// kv_count + kvpairs` per §9.1. Returns `null` on any size/tag
/// mismatch, on a non-zero `child_count` (this fixture only crosses
/// flat forms — children-bearing forms are a future fixture), or on
/// a kvpair value that isn't `Tag.number`.
fn walkFormFlat(buf: []const u8, start: usize) ?FormWalk {
    var off = start;

    if (buf.len < off + 4) return null;
    const head_len = std.mem.readInt(u32, buf[off..][0..4], .little);
    off += 4;
    if (buf.len < off + head_len) return null;
    off += head_len;

    if (buf.len < off + 4) return null;
    const ns_len = std.mem.readInt(u32, buf[off..][0..4], .little);
    off += 4;
    if (buf.len < off + ns_len) return null;
    off += ns_len;

    if (buf.len < off + 4) return null;
    const child_count = std.mem.readInt(u32, buf[off..][0..4], .little);
    if (child_count != 0) return null;
    off += 4;

    if (buf.len < off + 4) return null;
    const kv_count = std.mem.readInt(u32, buf[off..][0..4], .little);
    off += 4;

    var i: u32 = 0;
    while (i < kv_count) : (i += 1) {
        if (buf.len < off + 4) return null;
        const key_len = std.mem.readInt(u32, buf[off..][0..4], .little);
        off += 4;
        if (buf.len < off + key_len) return null;
        off += key_len;
        if (buf.len < off + 9) return null;
        if (buf[off] != TAG_NUMBER) return null;
        off += 9;
    }

    return .{ .arity = child_count + kv_count, .end = off };
}

/// Returns `children_count + kvpair_count` for a flat form arg. Used
/// by `plugin-exec-form-roundtrip` to prove `Tag.form` (`0x07`)
/// crosses the plugin boundary intact. Rejects any non-flat shape.
export fn form_arity(args_ptr: ?[*]const u8, args_len: u32) callconv(.c) ?[*]u8 {
    const p = args_ptr orelse return null;
    const args = p[0..args_len];

    // Args layout: [u32 count=1][u8 tag=0x07][form payload].
    if (args.len < 5) return null;
    const count = std.mem.readInt(u32, args[0..4], .little);
    if (count != 1) return null;
    if (args[4] != TAG_FORM) return null;

    const r = walkFormFlat(args, 5) orelse return null;
    const arity: f64 = @floatFromInt(r.arity);
    const bits: u64 = @bitCast(arity);

    // Result frame: [u32 ok=1][u32 len=9][u8 tag=0x01][f64].
    const payload_len: u32 = 9;
    const total = FRAME_HEADER + payload_len;
    const frame = wasm_allocator.alloc(u8, total) catch return null;

    std.mem.writeInt(u32, frame[0..4], 1, .little);
    std.mem.writeInt(u32, frame[4..8], payload_len, .little);
    frame[8] = TAG_NUMBER;
    std.mem.writeInt(u64, frame[9..17], bits, .little);

    return frame.ptr;
}

/// Sums `children_count + kvpair_count` over each form in a vector-
/// of-form arg. Used by `plugin-exec-form-roundtrip` to prove
/// `Tag.form` (`0x07`) nests correctly inside `Tag.vector` (`0x06`).
export fn forms_arity_sum(args_ptr: ?[*]const u8, args_len: u32) callconv(.c) ?[*]u8 {
    const p = args_ptr orelse return null;
    const args = p[0..args_len];

    // Args layout: [u32 count=1][u8 tag=0x06][u32 vec_count=N]
    //              [[u8 tag=0x07][form payload]] × N.
    if (args.len < 9) return null;
    const count = std.mem.readInt(u32, args[0..4], .little);
    if (count != 1) return null;
    if (args[4] != TAG_VECTOR) return null;
    const vec_count = std.mem.readInt(u32, args[5..9], .little);

    var off: usize = 9;
    var sum: u32 = 0;
    var i: u32 = 0;
    while (i < vec_count) : (i += 1) {
        if (args.len < off + 1) return null;
        if (args[off] != TAG_FORM) return null;
        off += 1;
        const r = walkFormFlat(args, off) orelse return null;
        sum += r.arity;
        off = r.end;
    }

    const total_arity: f64 = @floatFromInt(sum);
    const bits: u64 = @bitCast(total_arity);

    // Result frame: [u32 ok=1][u32 len=9][u8 tag=0x01][f64].
    const payload_len: u32 = 9;
    const total = FRAME_HEADER + payload_len;
    const frame = wasm_allocator.alloc(u8, total) catch return null;

    std.mem.writeInt(u32, frame[0..4], 1, .little);
    std.mem.writeInt(u32, frame[4..8], payload_len, .little);
    frame[8] = TAG_NUMBER;
    std.mem.writeInt(u64, frame[9..17], bits, .little);

    return frame.ptr;
}
