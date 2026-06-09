const std = @import("std");
const Plugin = @import("../Plugin.zig");

pub const Model = struct {
    plugins: []const Plugin_,
    version: u32 = 1,
};

pub const Plugin_ = struct {
    name: []const u8,
    version: []const u8 = "",
    description: []const u8 = "",
    forms: []const Form,
    value_kinds: []const ValueKindEntry,
};

pub const Form = struct {
    name: []const u8,
    description: []const u8 = "",
    keys: []const Key,
    positional: Positional,
    open: bool = false,
    discriminator: ?Discriminator = null,
    exclusive_groups: []const ExclusiveGroup = &.{},
    lowering: ?Lowering = null,
    positional_flags: ?[]const PositionalFlag = null,
};

pub const PositionalFlag = struct {
    name: []const u8,
    description: []const u8 = "",
    link: ?[]const u8 = null,
};

pub const Key = struct {
    name: []const u8,
    optional: bool,
    description: []const u8 = "",
    value: ValueShape,
    default: ?Default = null,
};

pub const Positional = union(enum) {
    none,
    any,
    kind: ValueShape,
};

pub const Discriminator = struct {
    key_name: []const u8,
    variants: []const Variant,
};

pub const Variant = struct {
    when: []const u8,
    keys: []const Key,
};

pub const ExclusiveGroup = struct {
    cardinality: Plugin.Cardinality,
    alternatives: []const []const []const u8,
};

pub const Lowering = struct {
    hook: []const u8,
    produces: []const []const u8,
};

pub const ValueShape = union(enum) {
    any,
    nil,
    boolean,
    number,
    number_i64,
    number_u64,
    number_bounded: NumericBounds,
    number_with_unit: UnitShape,
    string,
    string_with_bounds: StringBounds,
    symbol,
    symbol_members: []const []const u8,
    symbol_members_rich: []const Member,
    string_members: []const []const u8,
    string_members_rich: []const Member,
    date,
    time,
    keyword,
    vector: VectorShape,
    form_any,
    form_heads: []const FormRef,
    form_locals: []const Form,
    expr,
    cross_ref: CrossRef,
    union_of: []const UnionAlternative,
    unresolved_named: UnresolvedNamed,

    pub fn isCompound(self: ValueShape) bool {
        return switch (self) {
            .vector, .union_of, .symbol_members, .symbol_members_rich, .string_members, .string_members_rich, .form_heads, .form_locals => true,
            else => false,
        };
    }
};

pub const UnresolvedNamed = struct {
    name: []const u8,
    namespace: ?[]const u8 = null,
};

pub const VectorShape = struct {
    len: ?u16,
    min_len: ?u16 = null,
    max_len: ?u16 = null,
    element: *const ValueShape,
};

pub const UnitShape = struct {
    required: bool,
    allowed: []const []const u8,
    bounds: ?NumericBounds = null,
};

pub const StringBounds = struct {
    min_len: ?u32 = null,
    max_len: ?u32 = null,
    pattern: ?[]const u8 = null,
    format: ?Plugin.ValueKind.StringBounds.Format = null,
};

pub const NumericBounds = struct {
    min: ?Bound = null,
    max: ?Bound = null,
    exclusive_min: bool = false,
    exclusive_max: bool = false,
    integer: bool = false,
    repr: ?Plugin.ValueKind.Repr = null,

    pub const Bound = struct {
        value: f64,
        unit: ?[]const u8 = null,
        exact_int: bool = false,
    };
};

pub const Member = struct {
    name: []const u8,
    label: []const u8 = "",
    description: []const u8 = "",
    deprecated: bool = false,
    deprecation_message: []const u8 = "",
};

pub const CrossRef = struct {
    target_form: []const u8,
    name_key: []const u8,
    acyclic: bool,
    scope_form: ?[]const u8,
};

pub const FormRef = struct {
    plugin: []const u8,
    name: []const u8,
};

pub const UnionAlternative = struct {
    name: []const u8,
    shape: ValueShape,
};

pub const ValueKindEntry = struct {
    name: []const u8,
    description: []const u8 = "",
    shape: ValueShape,
    origin_plugin: []const u8 = "",
};

pub const PerPluginArtifact = struct {
    plugin: []const u8,
    json_schema_bytes: ?[]const u8 = null,
    ts_types_bytes: ?[]const u8 = null,
    intermediate_bytes: ?[]const u8 = null,
};

pub const Default = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    string: []const u8,
    symbol: []const u8,
    vector: []const Default,
    expression: ExpressionSnapshot,
};

pub const ExpressionSnapshot = struct {
    head: []const u8,
    namespace: ?[]const u8,
    arg_count: u32,
};
