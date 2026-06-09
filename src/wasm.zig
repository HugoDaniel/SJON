const std = @import("std");
const sjon = @import("root.zig");
const common = @import("wasm_common.zig");
const wasm_host_resolver = @import("wasm_host_resolver.zig");
const wasm_plugin_invoker = @import("wasm_plugin_invoker.zig");
comptime {
    _ = wasm_plugin_invoker;
}

const Schema = sjon.Schema;
const Parser = sjon.Parser;
const Printer = sjon.Printer;
const Validator = sjon.Validator;
const Json = sjon.Json;
const Edit = sjon.Edit;
const Expr = sjon.Expr;
const Binary = sjon.Binary;
const Host = sjon.Host;

const wasm_allocator = std.heap.wasm_allocator;

const core_schema: Schema.Schema = Schema.Schema.init(&.{sjon.plugins.core.plugin});

export fn sjon_alloc(len: u32) callconv(.c) ?[*]u8 {
    if (len == 0) return null;
    const slice = wasm_allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

export fn sjon_free(ptr: [*]u8, len: u32) callconv(.c) void {
    if (len == 0) return;
    wasm_allocator.free(ptr[0..len]);
}

export fn sjon_describe() callconv(.c) ?[*]u8 {
    const text =
        \\{"name":"sjon","version":"
    ++ sjon.version ++
        \\","exports":["parse","print","validate","eval_expr","to_json","from_json","apply_edit","apply_edits","to_binary","from_binary","validate_binary","eval_expr_binary","host_validate_document","host_eval_expr","export_schema","export_lowering_graph","describe"],"plugins":["core"]}
    ;
    return common.frame(wasm_allocator, true, text) catch null;
}

export fn sjon_parse(src_ptr: [*]const u8, src_len: u32) callconv(.c) ?[*]u8 {
    return runParse(src_ptr[0..src_len]) catch |err| common.frameError(wasm_allocator, err) catch null;
}

export fn sjon_print(
    src_ptr: [*]const u8,
    src_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) callconv(.c) ?[*]u8 {
    return runPrint(src_ptr[0..src_len], opts_ptr[0..opts_len]) catch |err| common.frameError(wasm_allocator, err) catch null;
}

export fn sjon_validate(src_ptr: [*]const u8, src_len: u32) callconv(.c) ?[*]u8 {
    return runValidate(src_ptr[0..src_len]) catch |err| common.frameError(wasm_allocator, err) catch null;
}

export fn sjon_eval_expr(src_ptr: [*]const u8, src_len: u32) callconv(.c) ?[*]u8 {
    return runEvalExpr(src_ptr[0..src_len]) catch |err| common.frameError(wasm_allocator, err) catch null;
}

export fn sjon_to_json(
    src_ptr: [*]const u8,
    src_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) callconv(.c) ?[*]u8 {
    return runToJson(src_ptr[0..src_len], opts_ptr[0..opts_len]) catch |err| common.frameError(wasm_allocator, err) catch null;
}

export fn sjon_from_json(json_ptr: [*]const u8, json_len: u32) callconv(.c) ?[*]u8 {
    return runFromJson(json_ptr[0..json_len]) catch |err| common.frameError(wasm_allocator, err) catch null;
}

export fn sjon_apply_edit(
    src_ptr: [*]const u8,
    src_len: u32,
    action_ptr: [*]const u8,
    action_len: u32,
) callconv(.c) ?[*]u8 {
    return runApplyEdit(src_ptr[0..src_len], action_ptr[0..action_len]) catch |err| common.frameError(wasm_allocator, err) catch null;
}

export fn sjon_apply_edits(
    src_ptr: [*]const u8,
    src_len: u32,
    actions_ptr: [*]const u8,
    actions_len: u32,
) callconv(.c) ?[*]u8 {
    return runApplyEdits(src_ptr[0..src_len], actions_ptr[0..actions_len]) catch |err| common.frameError(wasm_allocator, err) catch null;
}

export fn sjon_to_binary(src_ptr: [*]const u8, src_len: u32) callconv(.c) ?[*]u8 {
    return runToBinary(src_ptr[0..src_len]) catch |err| common.frameError(wasm_allocator, err) catch null;
}

export fn sjon_from_binary(bin_ptr: [*]const u8, bin_len: u32) callconv(.c) ?[*]u8 {
    return runFromBinary(bin_ptr[0..bin_len]) catch |err| common.frameError(wasm_allocator, err) catch null;
}

export fn sjon_validate_binary(bin_ptr: [*]const u8, bin_len: u32) callconv(.c) ?[*]u8 {
    return runValidateBinary(bin_ptr[0..bin_len]) catch |err| common.frameError(wasm_allocator, err) catch null;
}

export fn sjon_eval_expr_binary(bin_ptr: [*]const u8, bin_len: u32) callconv(.c) ?[*]u8 {
    return runEvalExprBinary(bin_ptr[0..bin_len]) catch |err| common.frameError(wasm_allocator, err) catch null;
}

export fn sjon_host_validate_document(
    src_ptr: [*]const u8,
    src_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) callconv(.c) ?[*]u8 {
    return runHostValidateDocument(src_ptr[0..src_len], opts_ptr[0..opts_len]) catch |err| common.frameError(wasm_allocator, err) catch null;
}

export fn sjon_host_eval_expr(
    src_ptr: [*]const u8,
    src_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) callconv(.c) ?[*]u8 {
    return runHostEvalExpr(src_ptr[0..src_len], opts_ptr[0..opts_len]) catch |err| common.frameError(wasm_allocator, err) catch null;
}

export fn sjon_export_schema(
    src_ptr: [*]const u8,
    src_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) callconv(.c) ?[*]u8 {
    return runExportSchema(src_ptr[0..src_len], opts_ptr[0..opts_len]) catch |err| common.frameError(wasm_allocator, err) catch null;
}

export fn sjon_export_lowering_graph(
    src_ptr: [*]const u8,
    src_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) callconv(.c) ?[*]u8 {
    return runExportLoweringGraph(src_ptr[0..src_len], opts_ptr[0..opts_len]) catch |err| common.frameError(wasm_allocator, err) catch null;
}

fn runParse(src_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    var tree = try Parser.parse(wasm_allocator, src);
    defer tree.deinit();

    const json_text = try common.parseDiagnosticsJson(a, tree.diagnostics);
    return try common.frame(wasm_allocator, true, json_text);
}

fn runPrint(src_bytes: []const u8, opts_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    var tree = try Parser.parse(wasm_allocator, src);
    defer tree.deinit();

    const opts = try parsePrintOptions(a, opts_bytes);
    const out = try Printer.print(wasm_allocator, tree, opts);
    defer out.deinit();
    return try common.frame(wasm_allocator, true, out.data);
}

fn runValidate(src_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    var tree = try Parser.parse(wasm_allocator, src);
    defer tree.deinit();

    var result = try Validator.validate(wasm_allocator, tree, core_schema);
    defer result.deinit();

    const json_text = try common.validatorDiagnosticsJson(a, tree.diagnostics, result);
    return try common.frame(wasm_allocator, true, json_text);
}

fn runEvalExpr(src_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    var tree = try Parser.parse(wasm_allocator, src);
    defer tree.deinit();

    if (tree.root.len != 1) return error.MultipleRoots;

    const env: Expr.Env = .{};
    var result = try Expr.eval(wasm_allocator, &tree, tree.root[0], &env, core_schema);
    defer result.deinit();

    const json_text = try common.valueToJson(a, result.value);
    return try common.frame(wasm_allocator, true, json_text);
}

fn runToJson(src_bytes: []const u8, opts_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    var tree = try Parser.parse(wasm_allocator, src);
    defer tree.deinit();

    const opts = try parseToJsonOptions(a, opts_bytes);
    var result = try Json.toJson(wasm_allocator, tree, opts);
    defer result.deinit();

    const out = try std.json.Stringify.valueAlloc(a, result.value, .{});
    return try common.frame(wasm_allocator, true, out);
}

fn runFromJson(json_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, a, json_bytes, .{}) catch
        return error.InvalidJson;

    var tree = try Json.fromJson(wasm_allocator, parsed.value, .{});
    defer tree.deinit();

    const out = try Printer.print(wasm_allocator, tree, .{});
    defer out.deinit();
    return try common.frame(wasm_allocator, true, out.data);
}

fn runApplyEdit(src_bytes: []const u8, action_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, a, action_bytes, .{}) catch
        return error.InvalidAction;

    const out = try Edit.applyEdit(wasm_allocator, src, parsed.value, .{});
    defer out.deinit();
    return try common.frame(wasm_allocator, true, out.data);
}

fn runApplyEdits(src_bytes: []const u8, actions_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    const out = try Edit.applyEditsFromJsonString(wasm_allocator, src, actions_bytes, .{});
    defer out.deinit();
    return try common.frame(wasm_allocator, true, out.data);
}

fn runToBinary(src_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    var tree = try Parser.parse(wasm_allocator, src);
    defer tree.deinit();

    const out = try Binary.toBinary(wasm_allocator, tree, .{});
    defer out.deinit();
    return try common.frame(wasm_allocator, true, out.data);
}

fn runFromBinary(bin_bytes: []const u8) ![*]u8 {
    var tree = try Binary.fromBinary(wasm_allocator, bin_bytes, .{});
    defer tree.deinit();

    const out = try Printer.print(wasm_allocator, tree, .{});
    defer out.deinit();
    return try common.frame(wasm_allocator, true, out.data);
}

fn runValidateBinary(bin_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var result = try sjon.validateBinary(wasm_allocator, bin_bytes, core_schema);
    defer result.deinit();

    const json_text = try common.validatorBinaryJson(a, result);
    return try common.frame(wasm_allocator, true, json_text);
}

fn runEvalExprBinary(bin_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const env: Expr.Env = .{};
    var result = try sjon.evalExprBinary(wasm_allocator, bin_bytes, &env, core_schema);
    defer result.deinit();

    const json_text = try common.valueToJson(a, result.value);
    return try common.frame(wasm_allocator, true, json_text);
}

fn runHostValidateDocument(src_bytes: []const u8, opts_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    const opts = try parseHostOptions(a, opts_bytes);

    const host_options: Host.HostOptions = .{
        .failure_policy = opts.failure_policy,
        .project_root = opts.project_root,
        .project_file = opts.project_file,
        .resolver = if (opts.has_resolver) wasm_host_resolver.build() else null,
    };

    var result = try Host.validateDocument(wasm_allocator, src, host_options);
    defer result.deinit();

    const json_text = try common.writeHostResult(a, result);
    return try common.frame(wasm_allocator, true, json_text);
}

fn runHostEvalExpr(src_bytes: []const u8, opts_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    const opts = try parseHostOptions(a, opts_bytes);

    const host_options: Host.HostOptions = .{
        .failure_policy = opts.failure_policy,
        .project_root = opts.project_root,
        .project_file = opts.project_file,
        .resolver = if (opts.has_resolver) wasm_host_resolver.build() else null,
    };

    var result = try Host.evalExpr(wasm_allocator, src, host_options);
    defer result.deinit();

    const json_text = try common.writeHostEvalResult(a, result);
    return try common.frame(wasm_allocator, true, json_text);
}

fn runExportSchema(src_bytes: []const u8, opts_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    const opts = try parseExportSchemaOptions(a, opts_bytes);

    const host_options: Host.HostOptions = .{
        .failure_policy = opts.failure_policy,
        .project_root = opts.project_root,
        .project_file = opts.project_file,
        .resolver = if (opts.has_resolver) wasm_host_resolver.build() else null,
    };

    const export_options: sjon.SchemaExport.ExportOptions = .{
        .target = opts.target,
        .layout = opts.layout,
        .draft = .@"2020-12",
    };

    var bundle = try Host.exportSchemaFromSource(wasm_allocator, src, host_options, export_options);
    defer bundle.deinit();

    const json_text = try common.writeExportSchemaResult(a, bundle);
    return try common.frame(wasm_allocator, true, json_text);
}

fn runExportLoweringGraph(src_bytes: []const u8, opts_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    const opts = try parseHostOptions(a, opts_bytes);

    const host_options: Host.HostOptions = .{
        .failure_policy = opts.failure_policy,
        .project_root = opts.project_root,
        .project_file = opts.project_file,
        .resolver = if (opts.has_resolver) wasm_host_resolver.build() else null,
    };

    var bundle = try Host.exportLoweringGraphFromSource(wasm_allocator, src, host_options);
    defer bundle.deinit();

    return try common.frame(wasm_allocator, true, bundle.sjon);
}

fn parsePrintOptions(a: std.mem.Allocator, opts_bytes: []const u8) !Printer.Options {
    var opts: Printer.Options = .{};
    if (opts_bytes.len == 0) return opts;
    const parsed = std.json.parseFromSlice(std.json.Value, a, opts_bytes, .{}) catch
        return error.InvalidOptions;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidOptions,
    };
    if (obj.get("mode")) |m| switch (m) {
        .string => |s| {
            if (std.mem.eql(u8, s, "canonical")) opts.mode = .canonical else if (std.mem.eql(u8, s, "compact")) opts.mode = .compact else if (std.mem.eql(u8, s, "full")) opts.mode = .full else return error.InvalidOptions;
        },
        else => return error.InvalidOptions,
    };
    if (obj.get("indent")) |i| switch (i) {
        .integer => |n| if (n >= 0 and n <= 16) {
            opts.indent = @intCast(n);
        } else return error.InvalidOptions,
        else => return error.InvalidOptions,
    };
    if (obj.get("wrap_at")) |w| switch (w) {
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u16)) {
            opts.wrap_at = @intCast(n);
        } else return error.InvalidOptions,
        else => return error.InvalidOptions,
    };
    return opts;
}

fn parseToJsonOptions(a: std.mem.Allocator, opts_bytes: []const u8) !Json.ToJsonOptions {
    var opts: Json.ToJsonOptions = .{ .schema = core_schema };
    if (opts_bytes.len == 0) return opts;
    const parsed = std.json.parseFromSlice(std.json.Value, a, opts_bytes, .{}) catch
        return error.InvalidOptions;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidOptions,
    };
    if (obj.get("mode")) |m| switch (m) {
        .string => |s| {
            if (std.mem.eql(u8, s, "canonical")) opts.mode = .canonical else if (std.mem.eql(u8, s, "compact")) opts.mode = .compact else if (std.mem.eql(u8, s, "full")) opts.mode = .full else return error.InvalidOptions;
        },
        else => return error.InvalidOptions,
    };
    return opts;
}

const ParsedHostOptions = struct {
    failure_policy: Host.FailurePolicy = .lenient,
    project_root: ?[]const u8 = null,
    project_file: ?[]const u8 = null,
    has_resolver: bool = false,
};

fn parseHostOptions(a: std.mem.Allocator, opts_bytes: []const u8) !ParsedHostOptions {
    var opts: ParsedHostOptions = .{};
    if (opts_bytes.len == 0) return opts;
    const parsed = std.json.parseFromSlice(std.json.Value, a, opts_bytes, .{}) catch
        return error.InvalidOptions;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidOptions,
    };
    if (obj.get("projectRoot")) |v| switch (v) {
        .string => |s| opts.project_root = s,
        .null => {},
        else => return error.InvalidOptions,
    };
    if (obj.get("projectFile")) |v| switch (v) {
        .string => |s| opts.project_file = s,
        .null => {},
        else => return error.InvalidOptions,
    };
    if (obj.get("failurePolicy")) |v| switch (v) {
        .string => |s| {
            if (std.mem.eql(u8, s, "strict")) opts.failure_policy = .strict else if (std.mem.eql(u8, s, "lenient")) opts.failure_policy = .lenient else return error.InvalidOptions;
        },
        else => return error.InvalidOptions,
    };
    if (obj.get("hasResolver")) |v| switch (v) {
        .bool => |b| opts.has_resolver = b,
        else => return error.InvalidOptions,
    };
    return opts;
}

const ParsedExportSchemaOptions = struct {
    failure_policy: Host.FailurePolicy = .lenient,
    project_root: ?[]const u8 = null,
    project_file: ?[]const u8 = null,
    has_resolver: bool = false,
    target: sjon.SchemaExport.Target = .{},
    layout: sjon.SchemaExport.Layout = .aggregated,
};

fn parseExportSchemaOptions(a: std.mem.Allocator, opts_bytes: []const u8) !ParsedExportSchemaOptions {
    var opts: ParsedExportSchemaOptions = .{};
    if (opts_bytes.len == 0) return opts;
    const parsed = std.json.parseFromSlice(std.json.Value, a, opts_bytes, .{}) catch
        return error.InvalidOptions;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidOptions,
    };
    if (obj.get("projectRoot")) |v| switch (v) {
        .string => |s| opts.project_root = s,
        .null => {},
        else => return error.InvalidOptions,
    };
    if (obj.get("projectFile")) |v| switch (v) {
        .string => |s| opts.project_file = s,
        .null => {},
        else => return error.InvalidOptions,
    };
    if (obj.get("failurePolicy")) |v| switch (v) {
        .string => |s| {
            if (std.mem.eql(u8, s, "strict")) opts.failure_policy = .strict else if (std.mem.eql(u8, s, "lenient")) opts.failure_policy = .lenient else return error.InvalidOptions;
        },
        else => return error.InvalidOptions,
    };
    if (obj.get("hasResolver")) |v| switch (v) {
        .bool => |b| opts.has_resolver = b,
        else => return error.InvalidOptions,
    };
    if (obj.get("target")) |v| switch (v) {
        .string => |s| {
            if (std.mem.eql(u8, s, "json-schema")) {
                opts.target = .{ .json_schema = true, .ts_types = false, .intermediate = false };
            } else if (std.mem.eql(u8, s, "typescript")) {
                opts.target = .{ .json_schema = false, .ts_types = true, .intermediate = false };
            } else if (std.mem.eql(u8, s, "both")) {
                opts.target = .{ .json_schema = true, .ts_types = true, .intermediate = false };
            } else if (std.mem.eql(u8, s, "intermediate")) {
                opts.target = .{ .json_schema = false, .ts_types = false, .intermediate = true };
            } else return error.InvalidOptions;
        },
        else => return error.InvalidOptions,
    };
    if (obj.get("layout")) |v| switch (v) {
        .string => |s| {
            if (std.mem.eql(u8, s, "aggregated")) opts.layout = .aggregated else if (std.mem.eql(u8, s, "per-plugin")) opts.layout = .per_plugin else return error.InvalidOptions;
        },
        else => return error.InvalidOptions,
    };
    if (obj.get("draft")) |v| switch (v) {
        .string => |s| {
            if (!std.mem.eql(u8, s, "2020-12")) return error.InvalidOptions;
        },
        else => return error.InvalidOptions,
    };
    return opts;
}

fn toSentinel(a: std.mem.Allocator, bytes: []const u8) ![:0]const u8 {
    const buf = try a.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf, bytes);
    return buf;
}
