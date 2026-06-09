const std = @import("std");
const Schema = @import("Schema.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{OutOfMemory};

pub fn render(gpa: Allocator, schema: Schema.Schema) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const nodes = try Schema.buildLoweringGraph(schema, arena_state.allocator());

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    if (nodes.len == 0) {
        try out.appendSlice(gpa, "(lowering-graph)\n");
        return out.toOwnedSlice(gpa);
    }

    try out.appendSlice(gpa, "(lowering-graph\n");
    for (nodes) |node| {
        try out.appendSlice(gpa, "  (node :form \"");
        try out.appendSlice(gpa, node.name);
        try out.appendSlice(gpa, "\" :produces [");
        for (node.edges, 0..) |edge, i| {
            if (i > 0) try out.append(gpa, ' ');
            try out.append(gpa, '"');
            try out.appendSlice(gpa, edge);
            try out.append(gpa, '"');
        }
        try out.appendSlice(gpa, "])\n");
    }
    try out.appendSlice(gpa, ")\n");
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;
const Plugin = @import("Plugin.zig");
const Parser = @import("Parser.zig");
