//! `uniforms`: a *real* cross-ref extractor, the kind the conformance
//! fixture (`conformance/fixtures/lines_extract.zig`) deliberately is
//! not. The corpus's `lines` provider splits on newlines because what
//! the corpus pins is the seam; this example is the downstream half its
//! header defers to: an extractor that actually parses something.
//!
//! It scans a WGSL source string and yields the name of every
//! module-scope uniform declaration:
//!
//!   @group(0) @binding(1) var<uniform> u_time: f32;
//!                                      ^^^^^^ extracted
//!
//! `var<storage>`, `var<workgroup>`, `var<private>`, and function-scope
//! `var` yield nothing. Line comments, nested block comments, and
//! whitespace between tokens are skipped, so a commented-out declaration
//! is not a name. A `var<uniform>` with no identifier after it makes the
//! whole extraction refuse (reported by the validator as
//! `cross_ref_extraction_failed`): refusal over silence, because a
//! truncated member set would mis-blame every reference that follows.
//!
//! Duplicates are kept: collapsing them is the host's extraction-table
//! job (a blob's internal redundancy is not a document error).
//!
//! Split from `uniforms_provider.zig` for the same reason the fixture is
//! split: this file is dependency-free and testable on the host target,
//! while the provider root reaches `std.heap.wasm_allocator`, which only
//! compiles for wasm.

const std = @import("std");

/// Walks a WGSL source and yields uniform names. `next()` returns null
/// both at end of source *and* at a malformed declaration, so check
/// `refused` afterwards to tell the two apart.
pub const Scan = struct {
    src: []const u8,
    i: usize = 0,
    refused: bool = false,

    pub fn next(self: *Scan) ?[]const u8 {
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == '/' and self.peek(1) == '/') {
                self.skipLineComment();
            } else if (c == '/' and self.peek(1) == '*') {
                self.skipBlockComment();
            } else if (isIdentStart(c)) {
                const word = self.readIdent();
                if (std.mem.eql(u8, word, "var")) {
                    if (self.uniformName()) |name| return name;
                    if (self.refused) return null;
                }
            } else {
                self.i += 1;
            }
        }
        return null;
    }

    /// Called with the cursor just past a `var` token. Consumes a
    /// `<uniform>` template and the declared name, if present; any other
    /// address space (or a template-less `var`) yields null and leaves
    /// scanning to resume wherever the cursor stopped.
    fn uniformName(self: *Scan) ?[]const u8 {
        self.skipTrivia();
        if (self.i >= self.src.len or self.src[self.i] != '<') return null;
        self.i += 1;
        self.skipTrivia();
        if (self.i >= self.src.len or !isIdentStart(self.src[self.i])) return null;
        if (!std.mem.eql(u8, self.readIdent(), "uniform")) return null;
        self.skipTrivia();
        if (self.i >= self.src.len or self.src[self.i] != '>') return null;
        self.i += 1;
        self.skipTrivia();
        if (self.i >= self.src.len or !isIdentStart(self.src[self.i])) {
            self.refused = true;
            return null;
        }
        return self.readIdent();
    }

    fn peek(self: *const Scan, off: usize) u8 {
        return if (self.i + off < self.src.len) self.src[self.i + off] else 0;
    }

    fn readIdent(self: *Scan) []const u8 {
        const start = self.i;
        while (self.i < self.src.len and isIdentChar(self.src[self.i])) self.i += 1;
        return self.src[start..self.i];
    }

    fn skipLineComment(self: *Scan) void {
        while (self.i < self.src.len and self.src[self.i] != '\n') self.i += 1;
    }

    /// WGSL block comments nest; an unterminated one consumes the rest
    /// of the source, which a scanner may safely treat as trivia.
    fn skipBlockComment(self: *Scan) void {
        var depth: usize = 0;
        while (self.i < self.src.len) {
            if (self.src[self.i] == '/' and self.peek(1) == '*') {
                depth += 1;
                self.i += 2;
            } else if (self.src[self.i] == '*' and self.peek(1) == '/') {
                depth -= 1;
                self.i += 2;
                if (depth == 0) return;
            } else {
                self.i += 1;
            }
        }
    }

    fn skipTrivia(self: *Scan) void {
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.i += 1;
            } else if (c == '/' and self.peek(1) == '/') {
                self.skipLineComment();
            } else if (c == '/' and self.peek(1) == '*') {
                self.skipBlockComment();
            } else {
                return;
            }
        }
    }
};

pub fn scan(source: []const u8) Scan {
    return .{ .src = source };
}

/// ASCII-only identifiers. WGSL permits more (XID_Start and friends);
/// an example provider trades that corner for readability, and a name
/// this scanner cannot read refuses rather than misreads.
fn isIdentStart(c: u8) bool {
    return c == '_' or std.ascii.isAlphabetic(c);
}

fn isIdentChar(c: u8) bool {
    return c == '_' or std.ascii.isAlphanumeric(c);
}

// ---------------------------------------------------------------------
// Scanner tests. `zig build test` runs them through the
// `uniforms-extract` test step; the wasm build never sees them.
// ---------------------------------------------------------------------

const testing = std.testing;

fn expectNames(source: []const u8, expected: []const []const u8) !void {
    var it = scan(source);
    for (expected) |want| {
        const got = it.next() orelse return error.TestExpectedEqual;
        try testing.expectEqualStrings(want, got);
    }
    try testing.expectEqual(@as(?[]const u8, null), it.next());
    try testing.expect(!it.refused);
}

test "scan: extracts uniform names, skips other address spaces" {
    try expectNames(
        \\@group(0) @binding(0) var<uniform> u_time: f32;
        \\@group(0) @binding(1) var<storage, read> data: array<f32>;
        \\var<private> counter: u32;
        \\@group(0) @binding(2) var < uniform > u_res: vec2f;
    , &.{ "u_time", "u_res" });
}

test "scan: function-scope var and var-prefixed identifiers yield nothing" {
    try expectNames(
        \\fn vs() { var pos = array<vec2f, 3>(); }
        \\fn f(variance: f32) -> f32 { return variance; }
    , &.{});
}

test "scan: comments are trivia, commented-out declarations are not names" {
    try expectNames(
        \\// var<uniform> u_dead: f32;
        \\/* var<uniform> u_also_dead: f32;
        \\   /* nested */ still inside */
        \\var</*between*/uniform> u_live: f32;
    , &.{"u_live"});
}

test "scan: a nameless var<uniform> refuses instead of truncating" {
    var it = scan("var<uniform> u_ok: f32; var<uniform> : f32;");
    try testing.expectEqualStrings("u_ok", it.next().?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
    try testing.expect(it.refused);
}

test "scan: duplicates are kept for the host's extraction table" {
    try expectNames(
        "var<uniform> u_twice: f32; var<uniform> u_twice: f32;",
        &.{ "u_twice", "u_twice" },
    );
}
