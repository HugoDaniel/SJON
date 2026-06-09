const std = @import("std");
const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
const Generated = @import("MetaSchema.generated.zig");

pub const plugin: Plugin.Plugin = Generated.plugin;

pub const schema: Schema.Schema = Generated.schema;

const testing = std.testing;
