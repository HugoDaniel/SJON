//! Owned-handle table for preloaded schemas — the kitchen-sink artifact's
//! ownership record behind the ABI's stable `u32` schema handles.
//!
//! `Host.preloadSchema` returns an arena-backed `PreloadedSchema` a host
//! wants to hold across many validate/eval calls. A wasm ABI cannot hand
//! a pointer to the embedder, so the wasm layer mints one nonzero `u32`
//! handle per owned `*PreloadedSchema` and keeps the pointer here.
//!
//! ## Ownership rule — one instance, one thread
//!
//! A `Table` belongs to exactly one wasm instance. Raw ABI handles carry
//! no owner token: a foreign ID that happens to equal a live local ID is
//! indistinguishable at this layer, which is why the Web/Rust wrappers
//! brand handles per host on top of this table. Within one instance the
//! table is driven only from the instance's synchronous call boundary —
//! one wasm instance cannot run two exports concurrently over its linear
//! memory — so nothing here adds synchronization, by design rather than
//! by omission.
//!
//! ## Why a stale handle can never alias a newer schema
//!
//! Handles come from a monotonic counter (`next`) that only ever
//! advances. `free` removes the map entry but never returns the ID to
//! circulation; `next` skips 0 (0 is never a handle) and, once the `u32`
//! space is exhausted by wraparound, parks ON 0 — the exhausted sentinel
//! — making `put` fail with `HandleExhausted` instead of reissuing.
//! Therefore ID N names at most one `*PreloadedSchema` over the whole
//! life of the table: a stale ID finds no entry (it was removed at
//! `free`) and can never be minted again for a newer schema. That
//! non-aliasing guarantee — rather than any pointer-as-handle shortcut —
//! is the entire reason this table exists; see `docs/plans/consumer-api/
//! 03-schema-handles.md` ("Pointer-as-handle with stale-ID aliasing is
//! not an acceptable shortcut").
//!
//! ## Allocator discipline
//!
//! No allocator is stored; every call threads the caller's `gpa`
//! (`.empty` + allocator-per-call, per house convention). `put` takes
//! ownership of the schema ONLY on success; on `OutOfMemory` ownership
//! stays with the caller, who must `deinit` and `destroy` it — the
//! inline tests below pin that contract, and `src/oom_tests.zig` sweeps
//! it under a `FailingAllocator`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Host = @import("Host.zig");

/// Every fallible table operation's error set. `OutOfMemory` surfaces the
/// map insert; the two handle refusals are ABI-level errors — handle
/// bookkeeping must never mint a new `Ast.Diagnostic.Code` (the
/// diagnostic-code enum is a wire-stable surface).
pub const Error = error{
    OutOfMemory,
    InvalidSchemaHandle,
    HandleExhausted,
};

/// Ownership record mapping stable `u32` handles to the
/// `*PreloadedSchema` values one wasm instance holds on an embedder's
/// behalf. See the module header for the single-instance ownership rule
/// and the stale-ID non-aliasing argument.
pub const Table = struct {
    /// Live entries only: `free` removes the entry before destroying the
    /// schema, so a freed handle's metadata never lingers (and the table
    /// never grows with dead handles).
    entries: std.AutoHashMapUnmanaged(u32, *Host.PreloadedSchema) = .empty,
    /// Next handle to mint. Starts at 1 (0 is never a handle), advances
    /// monotonically, and parks on 0 — the exhausted sentinel — once the
    /// `u32` space wraps, refusing further puts instead of reissuing.
    next: u32 = 1,

    /// Insert `schema` under a fresh handle and return it.
    ///
    /// Ownership: on success the table owns `schema` until the matching
    /// `free` (or `deinit`); on `OutOfMemory` ownership stays with the
    /// caller, who must `deinit` + `destroy` it — the failed put creates
    /// no entry and burns no ID (the counter advances only on success).
    /// O(1) amortized.
    pub fn put(self: *Table, gpa: Allocator, schema: *Host.PreloadedSchema) Error!u32 {
        if (self.next == 0) return error.HandleExhausted;
        const id = self.next;
        try self.entries.put(gpa, id, schema);
        self.next +%= 1; // wraps to 0 exactly once, arming the sentinel
        std.debug.assert(self.entries.get(id) == schema);
        return id;
    }

    /// Borrow the schema behind `handle`.
    ///
    /// The borrow lasts for one synchronous validate/eval call; the table
    /// keeps ownership. Zero, unknown, and stale (freed) IDs all return
    /// `InvalidSchemaHandle` — 0 is never inserted, and freed IDs are
    /// removed from the map rather than reused. O(1).
    pub fn get(self: *const Table, handle: u32) Error!*const Host.PreloadedSchema {
        return self.entries.get(handle) orelse error.InvalidSchemaHandle;
    }

    /// Release the schema behind `handle`.
    ///
    /// Total and idempotent: zero, unknown, and already-freed IDs are
    /// no-ops. The entry is removed from the map BEFORE the schema is
    /// destroyed, so the dying schema is unreachable through the table
    /// from the moment `free` begins. O(1).
    pub fn free(self: *Table, gpa: Allocator, handle: u32) void {
        const schema = self.entries.get(handle) orelse return;
        std.debug.assert(self.entries.remove(handle));
        schema.deinit();
        gpa.destroy(schema);
    }

    /// Release every live schema and the map itself. The instance-
    /// shutdown path; per-handle `free` is the normal exit. O(n).
    pub fn deinit(self: *Table, gpa: Allocator) void {
        var it = self.entries.valueIterator();
        while (it.next()) |slot| {
            const schema = slot.*;
            schema.deinit();
            gpa.destroy(schema);
        }
        self.entries.deinit(gpa);
        self.* = .{};
    }
};

const testing = std.testing;

/// Build one real owned `*Host.PreloadedSchema` with the leak-checked
/// allocator. The caller owns it until a successful `Table.put`.
fn makeOwned() !*Host.PreloadedSchema {
    const schema = try testing.allocator.create(Host.PreloadedSchema);
    schema.* = try Host.preloadSchema(testing.allocator, &.{});
    return schema;
}

/// Build one real owned schema and insert it, transferring ownership to
/// `table` only on success — the documented `put` contract, so the
/// errdefer ordering here (deinit the arena, then destroy the struct)
/// is the cleanup a real caller owes on failure.
fn putFresh(table: *Table) !u32 {
    const schema = try testing.allocator.create(Host.PreloadedSchema);
    errdefer testing.allocator.destroy(schema);
    schema.* = try Host.preloadSchema(testing.allocator, &.{});
    errdefer schema.deinit();
    return table.put(testing.allocator, schema);
}

test "put mints nonzero increasing IDs and get returns the same schema" {
    var table: Table = .{};
    defer table.deinit(testing.allocator);

    const id_a = try putFresh(&table);
    const id_b = try putFresh(&table);

    try testing.expect(id_a != 0);
    try testing.expect(id_b != 0);
    try testing.expect(id_b > id_a);

    const pa = try table.get(id_a);
    const pb = try table.get(id_b);
    try testing.expect(pa != pb); // two distinct owned values
    try testing.expect((try table.get(id_a)) == pa); // stable across calls
}

test "get rejects zero, unknown, and stale handles" {
    var table: Table = .{};
    defer table.deinit(testing.allocator);

    const id = try putFresh(&table);
    _ = try table.get(id); // the live handle resolves

    try testing.expectError(error.InvalidSchemaHandle, table.get(0));
    try testing.expectError(error.InvalidSchemaHandle, table.get(id + 1000));

    table.free(testing.allocator, id);
    try testing.expectError(error.InvalidSchemaHandle, table.get(id)); // stale
}

test "free is total: zero, unknown, and already-freed IDs are no-ops" {
    var table: Table = .{};
    defer table.deinit(testing.allocator);

    table.free(testing.allocator, 0); // zero — never a handle
    table.free(testing.allocator, 7); // unknown

    const id = try putFresh(&table);
    table.free(testing.allocator, id); // the real free
    table.free(testing.allocator, id); // stale — freed exactly once

    try testing.expectEqual(@as(usize, 0), table.entries.count());
}

test "freed IDs are never reused" {
    var table: Table = .{};
    defer table.deinit(testing.allocator);

    const id_a = try putFresh(&table);
    table.free(testing.allocator, id_a);
    const id_b = try putFresh(&table);

    try testing.expect(id_b > id_a); // monotonic past the freed one
    // The stale handle refuses rather than aliasing the newer schema.
    try testing.expectError(error.InvalidSchemaHandle, table.get(id_a));
    _ = try table.get(id_b);
}

test "deinit frees every live entry (leak-checked)" {
    var table: Table = .{};
    // No deferred deinit: this test's subject IS deinit. The
    // std.testing.allocator leak check at exit is the assertion that all
    // three schemas and the map itself were released.
    _ = try putFresh(&table);
    _ = try putFresh(&table);
    _ = try putFresh(&table);
    try testing.expectEqual(@as(usize, 3), table.entries.count());

    table.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), table.entries.count());
}

test "next == 0 is the exhausted sentinel: put refuses rather than reissues" {
    var table: Table = .{};
    defer table.deinit(testing.allocator);

    // The exhaustion seam, driven directly: minting 2^32 handles is not
    // a testable input, so the sentinel is reached as a seam (the same
    // discipline as the Budget seams in Expr / Validator / PatternQuery).
    table.next = 0;

    const schema = try makeOwned();
    try testing.expectError(error.HandleExhausted, table.put(testing.allocator, schema));
    try testing.expectEqual(@as(usize, 0), table.entries.count());

    // Ownership never left the caller — clean up by hand.
    schema.deinit();
    testing.allocator.destroy(schema);
}

test "failed put leaves ownership with the caller and creates no entry" {
    var table: Table = .{};
    defer table.deinit(testing.allocator);

    const schema = try makeOwned();

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, table.put(failing.allocator(), schema));

    // No entry and no burned ID — and the hand cleanup below is the sole
    // destroy, so a `put` that had also kept or freed the pointer trips
    // the allocator's leak / double-free check.
    try testing.expectEqual(@as(usize, 0), table.entries.count());
    try testing.expectEqual(@as(u32, 1), table.next);

    schema.deinit();
    testing.allocator.destroy(schema);
}
