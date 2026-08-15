//! `todo-plugin` — companion wasm sidecar for examples/web-todo.
//!
//! Speaks the executable-plugin ABI (`docs/executable-plugin-abi.md`)
//! end-to-end. Three expr-funcs:
//!
//!   - `(sum xs)`         — xs is a vector of numbers; returns the sum.
//!   - `(count-done xs)`  — xs is a vector of `(todo …)` forms;
//!                          returns the count of items where `:done`
//!                          decodes as boolean true.
//!   - `(count-active xs)` — same, but counts the `:done false` items.
//!
//! Hand-rolls the slice of the v2 binary value codec the plugin needs:
//! the number tag (for sums), the vector tag (for arg lists), the form
//! tag (for individual `(todo …)` values), and the boolean tag (for
//! the `:done` kvpair value the count funcs match on). Strings /
//! keywords are skipped without binding their bytes — the plugin only
//! cares about the `:done` flag.
//!
//! Imports MUST be empty per spec §7.1 — `std.heap.wasm_allocator` only
//! uses the `@wasmMemoryGrow` / `@wasmMemorySize` intrinsics, never an
//! `env.*` import.

const std = @import("std");

const wasm_allocator = std.heap.wasm_allocator;

const TAG_NUMBER: u8 = 0x01;
const TAG_BOOLEAN: u8 = 0x02;
const TAG_NIL: u8 = 0x03;
const TAG_STRING: u8 = 0x04;
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

/// `(sum xs)` — xs is a vector of numbers; returns the sum.
export fn sum_vector(args_ptr: ?[*]const u8, args_len: u32) callconv(.c) ?[*]u8 {
    const p = args_ptr orelse return null;
    const args = p[0..args_len];

    var dec: Decoder = .{ .bytes = args };
    const arg_count = dec.readU32() catch return errFrame("decode", "args truncated at arg_count");
    if (arg_count != 1) return errFrame("arity", "sum expects exactly one argument");

    const tag = dec.readByte() catch return errFrame("decode", "args truncated at arg tag");
    if (tag != TAG_VECTOR) return errFrame("type", "argument must be a vector of numbers");

    const vec_len = dec.readU32() catch return errFrame("decode", "args truncated at vec len");
    var sum: f64 = 0.0;
    var i: u32 = 0;
    while (i < vec_len) : (i += 1) {
        const elem_tag = dec.readByte() catch return errFrame("decode", "args truncated at element tag");
        if (elem_tag != TAG_NUMBER) return errFrame("type", "vector element must be a number");
        const bits = dec.readU64() catch return errFrame("decode", "args truncated at element bits");
        sum += @as(f64, @bitCast(bits));
    }

    return numberFrame(sum);
}

/// `(count-done xs)` — xs is a vector of `(todo …)` forms; returns
/// the count of items where the `:done` kvpair is boolean `true`.
export fn count_done(args_ptr: ?[*]const u8, args_len: u32) callconv(.c) ?[*]u8 {
    return countByDone(args_ptr, args_len, true);
}

/// `(count-active xs)` — symmetrical to `count_done` but counts the
/// items whose `:done` is boolean `false`.
export fn count_active(args_ptr: ?[*]const u8, args_len: u32) callconv(.c) ?[*]u8 {
    return countByDone(args_ptr, args_len, false);
}

fn countByDone(args_ptr: ?[*]const u8, args_len: u32, want: bool) ?[*]u8 {
    const p = args_ptr orelse return null;
    const args = p[0..args_len];

    var dec: Decoder = .{ .bytes = args };
    const arg_count = dec.readU32() catch return errFrame("decode", "args truncated at arg_count");
    if (arg_count != 1) return errFrame("arity", "count expects exactly one argument");

    const tag = dec.readByte() catch return errFrame("decode", "args truncated at arg tag");
    if (tag != TAG_VECTOR) return errFrame("type", "argument must be a vector of (todo …) forms");

    const vec_len = dec.readU32() catch return errFrame("decode", "args truncated at vec len");
    var count: f64 = 0.0;
    var i: u32 = 0;
    while (i < vec_len) : (i += 1) {
        const matched = readFormAndCheckDone(&dec, want) catch |err| return switch (err) {
            error.Decode => errFrame("decode", "todo form decode failed"),
            error.NotAForm => errFrame("type", "vector element must be a form"),
            error.BadDoneType => errFrame("type", "todo :done must be boolean"),
            error.Truncated => errFrame("decode", "truncated value"),
        };
        if (matched) count += 1.0;
    }

    return numberFrame(count);
}

const CountError = error{ Decode, NotAForm, BadDoneType, Truncated };

/// Decode one form from `dec` and return whether its `:done` kvpair
/// equals `want`. Skips everything else.
fn readFormAndCheckDone(dec: *Decoder, want: bool) CountError!bool {
    const tag = dec.readByte() catch return error.Truncated;
    if (tag != TAG_FORM) return error.NotAForm;

    // head_len, head bytes
    const head_len = dec.readU32() catch return error.Decode;
    _ = dec.skip(head_len) catch return error.Truncated;
    // ns_len, ns bytes
    const ns_len = dec.readU32() catch return error.Decode;
    _ = dec.skip(ns_len) catch return error.Truncated;
    // child_count + children — we don't need positional children, just skip them.
    const child_count = dec.readU32() catch return error.Decode;
    var i: u32 = 0;
    while (i < child_count) : (i += 1) try skipValue(dec);

    // kvpair_count + kvpairs.
    const kv_count = dec.readU32() catch return error.Decode;
    var matched: bool = false;
    var k: u32 = 0;
    while (k < kv_count) : (k += 1) {
        const key_len = dec.readU32() catch return error.Decode;
        const key = dec.readSlice(key_len) catch return error.Truncated;
        const v_tag = dec.readByte() catch return error.Truncated;
        if (std.mem.eql(u8, key, "done")) {
            if (v_tag != TAG_BOOLEAN) return error.BadDoneType;
            const b = dec.readByte() catch return error.Truncated;
            if ((b == 1) == want) matched = true;
        } else {
            try skipPayload(dec, v_tag);
        }
    }
    return matched;
}

/// Skip one full encoded value (tag + payload). Recurses on container
/// shapes; bounded by `MAX_VALUE_DEPTH` enforced host-side.
fn skipValue(dec: *Decoder) CountError!void {
    const tag = dec.readByte() catch return error.Truncated;
    try skipPayload(dec, tag);
}

fn skipPayload(dec: *Decoder, tag: u8) CountError!void {
    switch (tag) {
        TAG_NUMBER => _ = dec.skip(8) catch return error.Truncated,
        TAG_BOOLEAN => _ = dec.skip(1) catch return error.Truncated,
        TAG_NIL => {},
        TAG_STRING, TAG_KEYWORD => {
            const n = dec.readU32() catch return error.Decode;
            _ = dec.skip(n) catch return error.Truncated;
        },
        TAG_VECTOR => {
            const n = dec.readU32() catch return error.Decode;
            var i: u32 = 0;
            while (i < n) : (i += 1) try skipValue(dec);
        },
        TAG_FORM => {
            const head_len = dec.readU32() catch return error.Decode;
            _ = dec.skip(head_len) catch return error.Truncated;
            const ns_len = dec.readU32() catch return error.Decode;
            _ = dec.skip(ns_len) catch return error.Truncated;
            const child_count = dec.readU32() catch return error.Decode;
            var i: u32 = 0;
            while (i < child_count) : (i += 1) try skipValue(dec);
            const kv_count = dec.readU32() catch return error.Decode;
            var k: u32 = 0;
            while (k < kv_count) : (k += 1) {
                const key_len = dec.readU32() catch return error.Decode;
                _ = dec.skip(key_len) catch return error.Truncated;
                try skipValue(dec);
            }
        },
        else => return error.Decode,
    }
}

const Decoder = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn need(self: *Decoder, n: usize) error{Truncated}!void {
        if (self.pos + n > self.bytes.len) return error.Truncated;
    }

    fn readByte(self: *Decoder) error{Truncated}!u8 {
        try self.need(1);
        const b = self.bytes[self.pos];
        self.pos += 1;
        return b;
    }

    fn readU32(self: *Decoder) error{Truncated}!u32 {
        try self.need(4);
        const v = std.mem.readInt(u32, self.bytes[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    fn readU64(self: *Decoder) error{Truncated}!u64 {
        try self.need(8);
        const v = std.mem.readInt(u64, self.bytes[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }

    fn readSlice(self: *Decoder, n: u32) error{Truncated}![]const u8 {
        try self.need(n);
        const s = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    fn skip(self: *Decoder, n: u32) error{Truncated}!void {
        try self.need(n);
        self.pos += n;
    }
};

/// Build `[u32 ok=1][u32 len=9][u8 0x01][f64 value]`.
fn numberFrame(value: f64) ?[*]u8 {
    const payload_len: u32 = 9;
    const total = FRAME_HEADER + payload_len;
    const frame = wasm_allocator.alloc(u8, total) catch return null;
    std.mem.writeInt(u32, frame[0..4], 1, .little);
    std.mem.writeInt(u32, frame[4..8], payload_len, .little);
    frame[8] = TAG_NUMBER;
    const bits: u64 = @bitCast(value);
    std.mem.writeInt(u64, frame[9..17], bits, .little);
    return frame.ptr;
}

/// Build a structured-error frame.
fn errFrame(code: []const u8, detail: []const u8) ?[*]u8 {
    const payload_len: u32 = @intCast(4 + code.len + 4 + detail.len);
    const total = FRAME_HEADER + payload_len;
    const frame = wasm_allocator.alloc(u8, total) catch return null;
    std.mem.writeInt(u32, frame[0..4], 0, .little);
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
