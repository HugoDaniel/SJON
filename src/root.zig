const std = @import("std");
const Allocator = std.mem.Allocator;

pub const version = @import("version.zig").string;

pub const Lexer = @import("Lexer.zig");
pub const Date = @import("Date.zig");
pub const Time = @import("Time.zig");
pub const Ast = @import("Ast.zig");
pub const Parser = @import("Parser.zig");
pub const Printer = @import("Printer.zig");
pub const Plugin = @import("Plugin.zig");
pub const Schema = @import("Schema.zig");
pub const Validator = @import("Validator.zig");
pub const Expr = @import("Expr.zig");
pub const Json = @import("Json.zig");
pub const Edit = @import("Edit.zig");
pub const Binary = @import("Binary.zig");
pub const BinaryCursor = @import("BinaryCursor.zig");
pub const MetaSchema = @import("MetaSchema.zig");
pub const ManifestLoader = @import("ManifestLoader.zig");
pub const Host = @import("Host.zig");
pub const MaterializedDefaults = @import("MaterializedDefaults.zig");
pub const EffectiveView = @import("EffectiveView.zig");
pub const Lowering = @import("Lowering.zig");
pub const LoweringGraph = @import("LoweringGraph.zig");
pub const Lowering_test_hooks = @import("Lowering_test_hooks.zig");
pub const Resolver = @import("Resolver.zig");
pub const FilesystemResolver = @import("FilesystemResolver.zig");

pub const Glob = @import("Glob.zig");

pub const Lockfile = @import("Lockfile.zig");

pub const PluginValueCodec = @import("PluginValueCodec.zig");

pub const StringFormats = @import("StringFormats.zig");

pub const SchemaExport = @import("SchemaExport/SchemaExport.zig");

pub const plugins = struct {
    pub const core = @import("plugins/core.zig");
};

pub const Mode = Ast.Mode;

pub const Error =
    Json.Error ||
    Edit.Error ||
    Binary.Error ||
    Expr.Error ||
    Validator.Error;

pub fn parse(gpa: Allocator, source: [:0]const u8) !Ast.Tree {
    std.debug.assert(source.len <= Binary.MAX_FILE_SIZE);
    std.debug.assert(source.len == 0 or source.ptr[source.len] == 0);
    return Parser.parse(gpa, source);
}

pub fn print(gpa: Allocator, tree: Ast.Tree, opts: Printer.Options) !Ast.Bytes {
    std.debug.assert(opts.indent <= 16);
    return Printer.print(gpa, tree, opts);
}

pub fn validate(gpa: Allocator, tree: Ast.Tree, schema: Schema.Schema) !Validator.Result {
    std.debug.assert(tree.root.len <= Binary.MAX_NODES);
    return Validator.validate(gpa, tree, schema);
}

pub fn validateDocument(
    gpa: Allocator,
    source: [:0]const u8,
    options: Host.HostOptions,
) Host.Error!Host.HostResult {
    std.debug.assert(source.len <= Binary.MAX_FILE_SIZE);
    std.debug.assert(source.len == 0 or source.ptr[source.len] == 0);
    return Host.validateDocument(gpa, source, options);
}

pub fn loadProject(
    gpa: Allocator,
    options: Host.HostOptions,
) Host.Error!Host.LoadedProject {
    return Host.loadProject(gpa, options);
}

pub fn evalExpr(
    gpa: Allocator,
    tree: Ast.Tree,
    idx: Ast.NodeIndex,
    env: *const Expr.Env,
    schema: Schema.Schema,
) !Expr.Result {
    return Expr.eval(gpa, &tree, idx, env, schema);
}

pub fn toJson(gpa: Allocator, tree: Ast.Tree, opts: Json.ToJsonOptions) !Json.Result {
    std.debug.assert(tree.root.len == 1);
    return Json.toJson(gpa, tree, opts);
}

pub fn fromJson(gpa: Allocator, value: std.json.Value, opts: Json.FromJsonOptions) !Ast.Tree {
    return Json.fromJson(gpa, value, opts);
}

pub fn toJsonRoots(gpa: Allocator, tree: Ast.Tree, opts: Json.ToJsonOptions) !Json.Result {
    std.debug.assert(tree.root.len <= Binary.MAX_NODES);
    return Json.toJsonRoots(gpa, tree, opts);
}

pub fn fromJsonRoots(gpa: Allocator, value: std.json.Value, opts: Json.FromJsonOptions) !Ast.Tree {
    std.debug.assert(value == .object);
    return Json.fromJsonRoots(gpa, value, opts);
}

pub fn applyEdit(
    gpa: Allocator,
    source: [:0]const u8,
    action: std.json.Value,
    opts: Edit.Options,
) !Ast.Bytes {
    std.debug.assert(source.len <= Binary.MAX_FILE_SIZE);
    std.debug.assert(source.len == 0 or source.ptr[source.len] == 0);
    return Edit.applyEdit(gpa, source, action, opts);
}

pub fn applyEditToTree(
    gpa: Allocator,
    tree: *const Ast.Tree,
    action: std.json.Value,
) !Ast.Tree {
    return Edit.applyEditToTree(gpa, tree, action);
}

pub fn toBinary(gpa: Allocator, tree: Ast.Tree, opts: Binary.ToBinaryOptions) !Ast.Bytes {
    std.debug.assert(tree.root.len <= Binary.MAX_NODES);
    std.debug.assert((opts.flags() & Binary.Flag.reserved_mask) == 0);
    return Binary.toBinary(gpa, tree, opts);
}

pub fn fromBinary(gpa: Allocator, bytes: []const u8, opts: Binary.FromBinaryOptions) !Ast.Tree {
    std.debug.assert(bytes.len <= Binary.MAX_FILE_SIZE);
    return Binary.fromBinary(gpa, bytes, opts);
}

pub fn validateBinary(
    gpa: Allocator,
    bytes: []const u8,
    schema: Schema.Schema,
) !Validator.Result {
    return try Validator.validateBinary(gpa, bytes, schema);
}

pub fn evalExprBinary(
    gpa: Allocator,
    bytes: []const u8,
    env: *const Expr.Env,
    schema: Schema.Schema,
) !Expr.Result {
    return try Expr.evalBinary(gpa, bytes, env, schema);
}

fn readExampleSentinel(gpa: Allocator, path: []const u8) ![:0]u8 {
    const io = std.testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    const buf = try gpa.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf, bytes);
    return buf;
}
