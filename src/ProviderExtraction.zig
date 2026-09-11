//! Runs the pure name-extractors behind provider-backed cross-refs, and
//! answers with a content-addressed table the validator looks results up
//! in (`Validator.ExtractionMap`).
//!
//! **Layering.** This module imports `Validator` for the table types and
//! `Validator` never imports it back. Fulfillment needs the plugin
//! invoker, which is host territory; a validator that could reach it
//! would be a validator that can execute, and the whole point of the
//! provider route is that the extraction happens *before* validation, in
//! the same layer as the lowering pass.
//!
//! **What a provider is.** A named, pinned, deterministic
//! `bytes → names` function. Two routes, one contract:
//!
//!   * native `CrossRefProvider.impl` — a Zig function, for statically
//!     linked plugins;
//!   * `wasm:<export>` — an ordinary plugin export over the existing ABI
//!     (`docs/executable-plugin-abi.md`): one `.string` argument in, one
//!     `.vector` of `.string` out. No ABI bump; `PLUGIN_ABI_VERSION`
//!     stays 2, because a provider call *is* a plugin call.
//!
//! Purity is structural rather than promised: the argument is the
//! document's own bytes, the ABI grants no imports, and the answer is a
//! list of names. There is nothing for a provider to observe.
//!
//! **Read-side descope, as a decision.** There is no `wasm_common`
//! driver, and therefore no `sjon-binary.wasm` allowlist entry either.
//! `sjon_validate_binary` is hardwired to `core_schema` on both artifacts,
//! so the binary envelope can never meet a user schema and a driver there
//! would be unreachable code — and `hosts/web/sjon-reader.ts` says the
//! same from the other side, where `sjon_host_invoke_plugin` is a null
//! stub present only so the invoker fails cleanly. `audit-wasm-imports`
//! rejects listed-but-unreached entries, so adding one would *break* the
//! audit rather than document an intention. If the binary envelope ever
//! gains a user-schema channel, the read-side driver and a real reader
//! bridge are their own plan.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Expr = @import("Expr.zig");
const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
const Validator = @import("Validator.zig");
const wasm_plugin_invoker = @import("wasm_plugin_invoker.zig");

/// Fulfillment never fails the host: a provider that cannot run, runs and
/// refuses, or answers off-contract is recorded in the table and reported
/// as a diagnostic by the index pass. Only running out of memory is an
/// error, and it is listed here for documentation.
pub const Error = error{OutOfMemory};

/// Most names one source may yield. A fixture provider can return 4097
/// trivially, so the ceiling is reachable by a sane input and takes a
/// direct trip test rather than a runtime seam.
pub const MAX_EXTRACTED_NAMES: usize = 4096;

/// The extraction table plus the arena that owns every byte in it —
/// names, failure messages, and both halves of each key. Owning the keys
/// costs one copy of each distinct source and buys a table that does not
/// pin the request arena it was built from.
pub const Table = struct {
    arena: std.heap.ArenaAllocator,
    map: Validator.ExtractionMap,

    pub fn deinit(self: *Table) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The answer for one `(provider, source)` pair, or null when the
    /// pair was never requested. A null here means the discovery walk and
    /// the index walk disagreed about which pairs exist — the table is
    /// total over its requests, including the ones that failed.
    pub fn get(self: *const Table, provider: []const u8, source: []const u8) ?Validator.Extraction {
        return self.map.get(.{ .provider = provider, .source = source });
    }
};

/// How a provider call reached its plugin, and what came back. Modelled as
/// an outcome rather than an error set so a test can drive `fulfill` with
/// a few lines of mock, and so every mapping from the invoker's error set
/// lives in one adapter instead of being re-derived per call site.
pub const Invoker = struct {
    /// Opaque `*PluginRuntime` on the native path; ignored on wasm32,
    /// where the host owns its own plugin pool. Mocks use it for whatever
    /// they like.
    ctx: ?*anyopaque = null,
    callFn: *const fn (
        ctx: ?*anyopaque,
        a: Allocator,
        plugin_name: []const u8,
        export_name: []const u8,
        source: []const u8,
    ) Allocator.Error!Outcome,

    pub const Outcome = union(enum) {
        /// A decoded plugin value. `fulfill` still checks its shape — the
        /// vector-of-strings contract is this module's to enforce.
        value: Expr.Value,
        /// The provider ran and refused, or the call itself broke.
        failed: []const u8,
        /// The provider could not be run at all on this host.
        unavailable: []const u8,
    };

    pub fn call(
        self: Invoker,
        a: Allocator,
        plugin_name: []const u8,
        export_name: []const u8,
        source: []const u8,
    ) Allocator.Error!Outcome {
        return self.callFn(self.ctx, a, plugin_name, export_name, source);
    }

    /// The production invoker: the same `wasm_plugin_invoker.invoke`
    /// dispatch expr-funcs use, with the runtime pointer the host
    /// threaded down (null when the build has `plugin_exec=false` or no
    /// runtime was constructed — which is `unavailable`, not silence).
    pub fn plugins(runtime: ?*anyopaque) Invoker {
        return .{ .ctx = runtime, .callFn = callThroughPluginInvoker };
    }
};

fn callThroughPluginInvoker(
    ctx: ?*anyopaque,
    a: Allocator,
    plugin_name: []const u8,
    export_name: []const u8,
    source: []const u8,
) Allocator.Error!Invoker.Outcome {
    const args = [_]Expr.Value{.{ .string = source }};
    // `.vector` as the declared result gets the invoker's own type check
    // for free; the element types are checked here.
    const value = wasm_plugin_invoker.invoke(a, ctx, plugin_name, export_name, .vector, &args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PluginFuncNotImplemented => return .{
            .unavailable = "this host cannot run plugin code (built without executable-plugin support, or no runtime was constructed)",
        },
        else => {
            const last = wasm_plugin_invoker.lastFailure();
            return .{ .failed = try describeInvokeFailure(a, err, last.code(), last.detail()) };
        },
    };
    return .{ .value = value };
}

fn describeInvokeFailure(
    a: Allocator,
    err: Expr.Error,
    code: []const u8,
    detail: []const u8,
) Allocator.Error![]const u8 {
    if (detail.len == 0) return std.fmt.allocPrint(a, "{s}", .{@errorName(err)});
    if (code.len == 0) return std.fmt.allocPrint(a, "{s}: {s}", .{ @errorName(err), detail });
    return std.fmt.allocPrint(a, "{s} ({s}): {s}", .{ @errorName(err), code, detail });
}

/// Run every requested `(provider, source)` pair exactly once and collect
/// the answers.
///
/// `requests` is what `Validator.collectExtractionRequests` (or its binary
/// twin) discovered: already deduplicated, so this walks them in order and
/// tolerates a repeat rather than assuming one can't happen. The returned
/// table is total over the requests — a pair that could not be run, or ran
/// and failed, gets an entry saying so, never an absence.
///
/// Complexity: one provider call per distinct pair. Per-call scratch is an
/// arena reset between requests, so a thousand sources do not accumulate
/// a thousand decoded plugin values.
pub fn fulfill(
    gpa: Allocator,
    schema: Schema.Schema,
    requests: []const Validator.ExtractionRequest,
    invoker: Invoker,
) Error!Table {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var table: Table = .{ .arena = undefined, .map = .empty };

    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();

    for (requests) |req| {
        _ = scratch.reset(.retain_capacity);

        const key: Validator.ExtractionKey = .{
            .provider = try a.dupe(u8, req.provider),
            .source = try a.dupe(u8, req.source),
        };
        const gop = try table.map.getOrPut(a, key);
        if (gop.found_existing) continue;

        gop.value_ptr.* = try runOne(a, scratch.allocator(), schema, req, invoker);
    }

    table.arena = arena;
    return table;
}

/// One provider call, from canonical name to recorded outcome. `a` owns
/// what survives into the table; `sa` is per-call scratch.
fn runOne(
    a: Allocator,
    sa: Allocator,
    schema: Schema.Schema,
    req: Validator.ExtractionRequest,
    invoker: Invoker,
) Error!Validator.Extraction {
    // Canonical form is always `<plugin>/<provider>`, so the split names
    // the owning plugin and the lookup cannot come back ambiguous.
    const q = Plugin.splitQualified(req.provider);
    const hit = switch (schema.lookupCrossRefProvider(q.name, q.namespace)) {
        .found => |h| h,
        else => return .{ .unavailable = try std.fmt.allocPrint(
            a,
            "provider `{s}` is not declared by any loaded plugin",
            .{req.provider},
        ) },
    };

    // Native impl first: a statically linked plugin that supplies one has
    // no wasm bytes to reach, and a plugin that supplies both is asking
    // for the one that needs no host support.
    if (hit.provider.impl) |extract| {
        const names = extract(sa, req.source) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ExtractionFailed => return .{ .failure = .{
                .message = try a.dupe(u8, "the provider rejected this source"),
            } },
        };
        return collectNames(a, sa, names);
    }

    const export_name = hit.provider.wasm_export_name orelse return .{ .unavailable = try std.fmt.allocPrint(
        a,
        "provider `{s}` declares no `:impl`, so there is nothing to run",
        .{req.provider},
    ) };

    return switch (try invoker.call(sa, hit.plugin.name, export_name, req.source)) {
        .unavailable => |why| .{ .unavailable = try a.dupe(u8, why) },
        .failed => |why| .{ .failure = .{ .message = try a.dupe(u8, why) } },
        .value => |v| try collectPluginValue(a, sa, v),
    };
}

/// Check the wire contract — a vector whose every element is a string —
/// and fold the payload into the same shape the native route produces.
/// A violation is a `failure` rather than a distinct code: from the
/// document's point of view the provider did not answer, and why it
/// misbehaved belongs in the message, not in the wire-stable enum.
fn collectPluginValue(a: Allocator, sa: Allocator, value: Expr.Value) Error!Validator.Extraction {
    const elements = switch (value) {
        .vector => |v| v,
        else => return .{ .failure = .{ .message = try std.fmt.allocPrint(
            a,
            "provider returned {s}, but a provider must return a vector of strings",
            .{@tagName(value)},
        ) } },
    };

    var names: std.ArrayList([]const u8) = .empty;
    try names.ensureTotalCapacity(sa, @min(elements.len, MAX_EXTRACTED_NAMES));
    for (elements, 0..) |el, i| {
        switch (el) {
            .string => |s| try names.append(sa, s),
            else => return .{ .failure = .{ .message = try std.fmt.allocPrint(
                a,
                "provider returned {s} at index {d}, but every element must be a string",
                .{ @tagName(el), i },
            ) } },
        }
    }
    return collectNames(a, sa, names.items);
}

/// Apply the per-source cap, drop repeats, and copy what survives onto
/// the table's arena.
///
/// Duplicates *within* one source are the provider's business — a name is
/// a name, and a blob's internal redundancy is not a document error, so
/// the first occurrence is kept and the rest go silently. Duplicates
/// across two sources in one scope stay the document's business and keep
/// firing `duplicate_cross_ref_target` at the index pass.
fn collectNames(a: Allocator, sa: Allocator, names: []const []const u8) Error!Validator.Extraction {
    if (names.len > MAX_EXTRACTED_NAMES) return .{ .failure = .{ .message = try std.fmt.allocPrint(
        a,
        "provider returned {d} names, over the {d}-name ceiling for one source",
        .{ names.len, MAX_EXTRACTED_NAMES },
    ) } };

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var out: std.ArrayList([]const u8) = .empty;
    try out.ensureTotalCapacity(a, names.len);
    for (names) |n| {
        const gop = try seen.getOrPut(sa, n);
        if (gop.found_existing) continue;
        gop.value_ptr.* = {};
        out.appendAssumeCapacity(try a.dupe(u8, n));
    }
    return .{ .names = out.items };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

/// Mock invoker: answers every call from a script the test sets up, so
/// the shape checks and caps below are exercised without a wasm runtime.
const MockInvoker = struct {
    outcome: Invoker.Outcome,
    calls: usize = 0,
    last_source: []const u8 = "",

    fn invoker(self: *MockInvoker) Invoker {
        return .{ .ctx = self, .callFn = call };
    }

    fn call(
        ctx: ?*anyopaque,
        _: Allocator,
        _: []const u8,
        _: []const u8,
        source: []const u8,
    ) Allocator.Error!Invoker.Outcome {
        const self: *MockInvoker = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.last_source = source;
        return self.outcome;
    }
};

/// `wasm:extract_lines` on the wasm route; the native-impl tests build
/// their own plugin with `.impl` set instead.
fn wasmSchemaPlugin() Plugin.Plugin {
    return .{
        .name = "glsl",
        .cross_ref_providers = &.{.{ .name = "lines", .wasm_export_name = "extract_lines" }},
    };
}

fn stringVector(a: Allocator, items: []const []const u8) Allocator.Error!Expr.Value {
    const vals = try a.alloc(Expr.Value, items.len);
    for (items, vals) |s, *v| v.* = .{ .string = s };
    return .{ .vector = vals };
}

test "fulfill: the wasm route decodes a vector of strings into names" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var mock: MockInvoker = .{ .outcome = .{ .value = try stringVector(arena.allocator(), &.{ "u_one", "u_two" }) } };
    const schema = Schema.Schema.init(&.{wasmSchemaPlugin()});
    const requests = [_]Validator.ExtractionRequest{.{ .provider = "glsl/lines", .source = "src" }};

    var table = try fulfill(gpa, schema, &requests, mock.invoker());
    defer table.deinit();

    const got = table.get("glsl/lines", "src").?;
    try testing.expectEqual(@as(usize, 2), got.names.len);
    try testing.expectEqualStrings("u_one", got.names[0]);
    try testing.expectEqualStrings("u_two", got.names[1]);
    try testing.expectEqualStrings("src", mock.last_source);
}

test "fulfill: the native impl and the wasm route agree on the same source" {
    // The determinism assertion the plan asks for: one source, two
    // transports, one table. If these ever diverge, a plugin's behaviour
    // depends on how its host was built.
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const Fixture = struct {
        fn extract(a: Allocator, source: []const u8) Plugin.CrossRefProvider.ExtractError![]const []const u8 {
            var out: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, source, '\n');
            while (it.next()) |line| {
                if (line.len == 0) continue;
                try out.append(a, line);
            }
            return out.items;
        }
    };

    const source = "u_one\nu_two";
    const requests = [_]Validator.ExtractionRequest{.{ .provider = "glsl/lines", .source = source }};

    const native_plugin: Plugin.Plugin = .{
        .name = "glsl",
        .cross_ref_providers = &.{.{ .name = "lines", .impl = Fixture.extract }},
    };
    var native = try fulfill(gpa, Schema.Schema.init(&.{native_plugin}), &requests, Invoker.plugins(null));
    defer native.deinit();

    var mock: MockInvoker = .{ .outcome = .{ .value = try stringVector(arena.allocator(), &.{ "u_one", "u_two" }) } };
    var portable = try fulfill(gpa, Schema.Schema.init(&.{wasmSchemaPlugin()}), &requests, mock.invoker());
    defer portable.deinit();

    const from_native = native.get("glsl/lines", source).?.names;
    const from_wasm = portable.get("glsl/lines", source).?.names;
    try testing.expectEqual(from_native.len, from_wasm.len);
    for (from_native, from_wasm) |n, w| try testing.expectEqualStrings(n, w);
}

test "fulfill: a native impl is preferred over a declared export" {
    // A plugin that supplies both is asking for the route that needs no
    // host support — and the mock proves the invoker was never called.
    const gpa = testing.allocator;

    const Fixture = struct {
        fn extract(a: Allocator, _: []const u8) Plugin.CrossRefProvider.ExtractError![]const []const u8 {
            const out = try a.alloc([]const u8, 1);
            out[0] = "from-native";
            return out;
        }
    };
    const p: Plugin.Plugin = .{
        .name = "glsl",
        .cross_ref_providers = &.{.{
            .name = "lines",
            .impl = Fixture.extract,
            .wasm_export_name = "extract_lines",
        }},
    };

    var mock: MockInvoker = .{ .outcome = .{ .failed = "should not be reached" } };
    const requests = [_]Validator.ExtractionRequest{.{ .provider = "glsl/lines", .source = "src" }};
    var table = try fulfill(gpa, Schema.Schema.init(&.{p}), &requests, mock.invoker());
    defer table.deinit();

    try testing.expectEqualStrings("from-native", table.get("glsl/lines", "src").?.names[0]);
    try testing.expectEqual(@as(usize, 0), mock.calls);
}

test "fulfill: duplicates within one source are the provider's business" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var mock: MockInvoker = .{
        .outcome = .{ .value = try stringVector(arena.allocator(), &.{ "u_one", "u_two", "u_one" }) },
    };
    const requests = [_]Validator.ExtractionRequest{.{ .provider = "glsl/lines", .source = "src" }};
    var table = try fulfill(gpa, Schema.Schema.init(&.{wasmSchemaPlugin()}), &requests, mock.invoker());
    defer table.deinit();

    // First occurrence kept, the rest dropped silently — no diagnostic,
    // because a blob's internal redundancy is not a document error.
    const names = table.get("glsl/lines", "src").?.names;
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("u_one", names[0]);
    try testing.expectEqualStrings("u_two", names[1]);
}

test "fulfill: a repeated request runs the provider once" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    // Discovery already dedupes, so this is defensive rather than
    // load-bearing — but content addressing is only a real guarantee if
    // the table enforces it too.
    var mock: MockInvoker = .{ .outcome = .{ .value = try stringVector(arena.allocator(), &.{"u_one"}) } };
    const requests = [_]Validator.ExtractionRequest{
        .{ .provider = "glsl/lines", .source = "src" },
        .{ .provider = "glsl/lines", .source = "src" },
    };
    var table = try fulfill(gpa, Schema.Schema.init(&.{wasmSchemaPlugin()}), &requests, mock.invoker());
    defer table.deinit();

    try testing.expectEqual(@as(usize, 1), mock.calls);
    try testing.expectEqual(@as(u32, 1), table.map.count());
}

test "fulfill: the per-source name ceiling trips" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const over = try a.alloc([]const u8, MAX_EXTRACTED_NAMES + 1);
    for (over, 0..) |*n, i| n.* = try std.fmt.allocPrint(a, "u_{d}", .{i});

    var mock: MockInvoker = .{ .outcome = .{ .value = try stringVector(a, over) } };
    const requests = [_]Validator.ExtractionRequest{.{ .provider = "glsl/lines", .source = "src" }};
    var table = try fulfill(gpa, Schema.Schema.init(&.{wasmSchemaPlugin()}), &requests, mock.invoker());
    defer table.deinit();

    const got = table.get("glsl/lines", "src").?;
    try testing.expect(std.mem.indexOf(u8, got.failure.message, "ceiling") != null);

    // Control: one under the cap is fine, so the trip above is the cap
    // and not the fixture.
    var mock_ok: MockInvoker = .{ .outcome = .{ .value = try stringVector(a, over[0..MAX_EXTRACTED_NAMES]) } };
    var ok = try fulfill(gpa, Schema.Schema.init(&.{wasmSchemaPlugin()}), &requests, mock_ok.invoker());
    defer ok.deinit();
    try testing.expectEqual(MAX_EXTRACTED_NAMES, ok.get("glsl/lines", "src").?.names.len);
}

test "fulfill: an off-contract result is a failure, not a new code" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const requests = [_]Validator.ExtractionRequest{.{ .provider = "glsl/lines", .source = "src" }};
    const schema = Schema.Schema.init(&.{wasmSchemaPlugin()});

    // Not a vector at all.
    var not_vector: MockInvoker = .{ .outcome = .{ .value = .{ .string = "u_one" } } };
    var t1 = try fulfill(gpa, schema, &requests, not_vector.invoker());
    defer t1.deinit();
    try testing.expect(std.mem.indexOf(u8, t1.get("glsl/lines", "src").?.failure.message, "vector of strings") != null);

    // A vector, but an element is not a string. Symbols are *not* quietly
    // accepted: a lenient reader here is how two hosts start disagreeing.
    const mixed = try a.alloc(Expr.Value, 2);
    mixed[0] = .{ .string = "u_one" };
    mixed[1] = .{ .keyword = "u_two" };
    var bad_element: MockInvoker = .{ .outcome = .{ .value = .{ .vector = mixed } } };
    var t2 = try fulfill(gpa, schema, &requests, bad_element.invoker());
    defer t2.deinit();
    try testing.expect(std.mem.indexOf(u8, t2.get("glsl/lines", "src").?.failure.message, "index 1") != null);
}

test "fulfill: an unrunnable provider is unavailable, not silence" {
    const gpa = testing.allocator;
    const requests = [_]Validator.ExtractionRequest{.{ .provider = "glsl/lines", .source = "src" }};

    // Declared, but with neither an impl nor an export to reach.
    const declaration_only: Plugin.Plugin = .{
        .name = "glsl",
        .cross_ref_providers = &.{.{ .name = "lines" }},
    };
    var mock: MockInvoker = .{ .outcome = .{ .failed = "should not be reached" } };
    var t1 = try fulfill(gpa, Schema.Schema.init(&.{declaration_only}), &requests, mock.invoker());
    defer t1.deinit();
    try testing.expect(std.mem.indexOf(u8, t1.get("glsl/lines", "src").?.unavailable, "nothing to run") != null);
    try testing.expectEqual(@as(usize, 0), mock.calls);

    // Declared nowhere: the schema-aggregate pass has already said
    // `unknown_cross_ref_provider`, and discovery normally declines these
    // — the entry exists so a lookup never comes back absent.
    var t2 = try fulfill(gpa, Schema.Schema.init(&.{wasmSchemaPlugin()}), &.{
        .{ .provider = "glsl/nope", .source = "src" },
    }, mock.invoker());
    defer t2.deinit();
    try testing.expect(std.mem.indexOf(u8, t2.get("glsl/nope", "src").?.unavailable, "not declared") != null);

    // A host that cannot run plugin code at all. `Invoker.plugins(null)`
    // is the real production invoker with no runtime behind it, which is
    // exactly what a `plugin_exec=false` build hands over.
    var t3 = try fulfill(gpa, Schema.Schema.init(&.{wasmSchemaPlugin()}), &requests, Invoker.plugins(null));
    defer t3.deinit();
    try testing.expect(t3.get("glsl/lines", "src").? == .unavailable);
}

test "fulfill: the table owns its bytes" {
    // Keys and names are copied, so the table outlives the request arena
    // it was built from. Freeing the source out from under it and then
    // reading through would be a use-after-free the allocator catches.
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var mock: MockInvoker = .{ .outcome = .{ .value = try stringVector(arena.allocator(), &.{"u_one"}) } };

    var scratch: std.heap.ArenaAllocator = .init(gpa);
    const owned_source = try scratch.allocator().dupe(u8, "src");
    const requests = [_]Validator.ExtractionRequest{.{ .provider = "glsl/lines", .source = owned_source }};

    var table = try fulfill(gpa, Schema.Schema.init(&.{wasmSchemaPlugin()}), &requests, mock.invoker());
    defer table.deinit();
    scratch.deinit();

    try testing.expectEqualStrings("u_one", table.get("glsl/lines", "src").?.names[0]);
}

test "fulfill: out of memory is reported, never half-built" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var mock: MockInvoker = .{ .outcome = .{ .value = try stringVector(arena.allocator(), &.{ "u_one", "u_two" }) } };
    const schema = Schema.Schema.init(&.{wasmSchemaPlugin()});
    const requests = [_]Validator.ExtractionRequest{
        .{ .provider = "glsl/lines", .source = "a" },
        .{ .provider = "glsl/lines", .source = "b" },
    };

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = i });
        if (fulfill(failing.allocator(), schema, &requests, mock.invoker())) |t| {
            var table = t;
            table.deinit();
            break;
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
    } else return error.NeverSucceeded;
}
