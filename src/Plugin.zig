const std = @import("std");
const Expr = @import("Expr.zig");

pub const Plugin = struct {
    name: []const u8,
    version: []const u8 = "",
    wasm_file: ?[]const u8 = null,
    wasm_sha256: ?[]const u8 = null,
    authors: []const []const u8 = &.{},
    license: []const u8 = "",
    homepage: []const u8 = "",
    repository: []const u8 = "",
    keywords: []const []const u8 = &.{},
    sjon_format: []const u8 = "",
    forms: []const FormSpec = &.{},
    expr_funcs: []const ExprFunc = &.{},
    value_kinds: []const ValueKind = &.{},
};

pub const MAX_KEYWORDS: usize = 16;

pub const SUPPORTED_SJON_FORMAT: []const u8 = "1.1";

pub const FormSpec = struct {
    name: []const u8,
    keys: []const KeySpec = &.{},
    positional: PositionalSpec = .none,
    open: bool = false,
    description: []const u8 = "",
    discriminant_name: ?[]const u8 = null,
    discriminant_idx: ?u8 = null,
    variants: ?[]const Variant = null,
    exclusive_groups: []const ExclusiveGroup = &.{},
    lowering: ?LoweringSpec = null,
};

pub const LoweringSpec = struct {
    hook: []const u8,
    produces: []const []const u8,
};

pub const Variant = struct {
    when: []const u8,
    keys: []const KeySpec = &.{},
    exclusive_groups: []const ExclusiveGroup = &.{},
};

pub const ExclusiveGroup = struct {
    alternatives: []const Alternative,
    cardinality: Cardinality = .exactly_one,
};

pub const Alternative = struct {
    keys: []const []const u8,
};

pub const Cardinality = enum { exactly_one, at_most_one };

pub const MAX_FORM_KEYS: usize = 64;

pub const MAX_LOCAL_FORM_DEPTH: usize = 8;

pub const MAX_LOWERED_FORMS: usize = 1024;

pub const MAX_LOWERED_DEPTH: usize = 16;

pub const MAX_LOWERED_BYTES: usize = 256 * 1024;

pub const KeySpec = struct {
    name: []const u8,
    value_type: ValueType = .any,
    optional: bool = true,
    default: ?Default = null,
    description: []const u8 = "",
    walk_opaque: bool = false,
    local_forms: []const FormSpec = &.{},

    pub fn effectiveOptional(self: KeySpec) bool {
        return self.optional or self.default != null;
    }

    pub const Default = union(enum) {
        number: f64,
        string: []const u8,
        symbol: []const u8,
        boolean: bool,
        nil,
        vector: []const Default,
        expression: Expression,

        pub const Expression = struct {
            head: []const u8,
            namespace: ?[]const u8,
            arg_count: u32,
            program: []const u8,
        };
    };
};

pub const QualifiedRef = struct {
    name: []const u8,
    namespace: ?[]const u8 = null,
};

pub const PositionalSpec = union(enum) {
    none,
    any,
    kind: QualifiedRef,
    flag_set: FlagSet,

    pub const FlagSet = struct {
        flags: []const Flag,

        pub const Flag = struct {
            name: []const u8,
            description: []const u8 = "",
            link: ?[]const u8 = null,
        };
    };
};

pub const ValueType = union(enum) {
    any,
    number,
    string,
    symbol,
    boolean,
    nil,
    vector,
    form,
    expr,
    named: QualifiedRef,
};

pub const ExprFunc = struct {
    name: []const u8,
    arity: Arity = .{ .at_least = 0 },
    description: []const u8 = "",
    impl: ?Impl = null,
    wasm_export_name: ?[]const u8 = null,
    params: ?[]const ValueType = null,
    param_names: ?[]const []const u8 = null,
    rest: ?ValueType = null,
    result: ?ValueType = null,
    signatures: ?[]const Signature = null,

    pub const Signature = struct {
        arity: Arity,
        params: ?[]const ValueType = null,
        param_names: ?[]const []const u8 = null,
        rest: ?ValueType = null,
        result: ?ValueType = null,

        pub fn checkArity(self: Signature, n: usize) bool {
            return switch (self.arity) {
                .fixed => |k| n == k,
                .at_least => |k| n >= k,
                .range => |r| n >= r.min and n <= r.max,
            };
        }

        pub fn paramType(self: Signature, i: usize) ?ValueType {
            if (self.params) |ps| {
                if (i < ps.len) return ps[i];
            }
            return self.rest;
        }

        pub fn labeledEnabled(self: Signature) bool {
            const fixed = switch (self.arity) {
                .fixed => |k| k,
                else => return false,
            };
            if (self.rest != null) return false;
            const names = self.param_names orelse return false;
            return names.len == fixed;
        }

        pub fn indexOfLabel(self: Signature, name: []const u8) ?u8 {
            const names = self.param_names orelse return null;
            for (names, 0..) |n, i| {
                if (std.mem.eql(u8, n, name)) return @intCast(i);
            }
            return null;
        }
    };

    pub const Impl = *const fn (
        a: std.mem.Allocator,
        args: []const Expr.Value,
    ) Expr.Error!Expr.Value;

    pub const Arity = union(enum) {
        fixed: u8,
        at_least: u8,
        range: struct { min: u8, max: u8 },
    };

    pub const SignatureIter = struct {
        func: *const ExprFunc,
        idx: usize = 0,

        pub fn next(self: *SignatureIter) ?Signature {
            if (self.func.signatures) |sigs| {
                if (self.idx >= sigs.len) return null;
                defer self.idx += 1;
                return sigs[self.idx];
            }
            if (self.idx > 0) return null;
            self.idx += 1;
            return .{
                .arity = self.func.arity,
                .params = self.func.params,
                .param_names = self.func.param_names,
                .rest = self.func.rest,
                .result = self.func.result,
            };
        }
    };

    pub fn signatureIter(self: *const ExprFunc) SignatureIter {
        return .{ .func = self };
    }

    pub fn signatureCount(self: ExprFunc) usize {
        if (self.signatures) |sigs| return sigs.len;
        return 1;
    }

    pub fn checkArity(self: ExprFunc, n: usize) bool {
        var it = self.signatureIter();
        while (it.next()) |sig| if (sig.checkArity(n)) return true;
        return false;
    }

    pub fn paramType(self: ExprFunc, i: usize) ?ValueType {
        if (self.params) |ps| {
            if (i < ps.len) return ps[i];
        }
        return self.rest;
    }

    pub const ParamNamesError = error{
        ParamNamesRequiresFixedArity,
        ParamNamesForbidsRest,
        ParamNamesTooLong,
        ParamNamesDuplicate,
    };

    pub fn validateParamNames(self: ExprFunc) ParamNamesError!void {
        var it = self.signatureIter();
        while (it.next()) |sig| try validateSignatureNames(sig);
    }

    fn validateSignatureNames(sig: Signature) ParamNamesError!void {
        const names = sig.param_names orelse return;
        const fixed = switch (sig.arity) {
            .fixed => |k| k,
            else => return error.ParamNamesRequiresFixedArity,
        };
        if (sig.rest != null) return error.ParamNamesForbidsRest;
        if (names.len > fixed) return error.ParamNamesTooLong;
        for (names, 0..) |n, i| {
            for (names[i + 1 ..]) |m| {
                if (std.mem.eql(u8, n, m)) return error.ParamNamesDuplicate;
            }
        }
    }
};

pub const ValueKind = struct {
    name: []const u8,
    underlying: Underlying,
    description: []const u8 = "",
    vector: ?VectorShape = null,
    unit: ?UnitShape = null,
    numeric: ?NumericBounds = null,
    members: ?MemberSet = null,
    heads: ?HeadSet = null,
    cross_ref: ?CrossRef = null,
    union_of: ?UnionShape = null,
    string_bounds: ?StringBounds = null,
    repr: ?Repr = null,

    pub const Underlying = enum { number, string, vector, form, symbol, union_of };

    pub const Repr = enum {
        f32,
        u32,
        i32,
        u16,
        f16,

        pub const Spec = struct { min: f64, max: f64, integer: bool };

        pub fn spec(self: Repr) Spec {
            return switch (self) {
                .f32 => .{ .min = -@as(f64, std.math.floatMax(f32)), .max = @as(f64, std.math.floatMax(f32)), .integer = false },
                .f16 => .{ .min = -@as(f64, std.math.floatMax(f16)), .max = @as(f64, std.math.floatMax(f16)), .integer = false },
                .u16 => .{ .min = 0, .max = @as(f64, std.math.maxInt(u16)), .integer = true },
                .u32 => .{ .min = 0, .max = @as(f64, std.math.maxInt(u32)), .integer = true },
                .i32 => .{ .min = @as(f64, std.math.minInt(i32)), .max = @as(f64, std.math.maxInt(i32)), .integer = true },
            };
        }
    };

    pub const VectorShape = struct {
        len: ?u16 = null,
        min_len: ?u16 = null,
        max_len: ?u16 = null,
        element: QualifiedRef,
    };

    pub const UnitShape = struct {
        required: bool = false,
        reject: bool = false,
        allowed: []const []const u8 = &.{},
    };

    pub const NumericBounds = struct {
        min: ?Bound = null,
        max: ?Bound = null,
        exclusive_min: bool = false,
        exclusive_max: bool = false,
        integer: bool = false,

        pub const Bound = struct {
            value: f64,
            unit: ?[]const u8 = null,
            exact_int: bool = false,
        };
    };

    pub const StringBounds = struct {
        min_len: ?u32 = null,
        max_len: ?u32 = null,
        pattern: ?[]const u8 = null,
        format: ?Format = null,

        pub const Format = enum { email, uri, path, uuid, semver };
    };

    pub const MemberSet = struct {
        members: []const Member,

        pub const Member = struct {
            name: []const u8,
            label: []const u8 = "",
            description: []const u8 = "",
            deprecated: bool = false,
            deprecation_message: []const u8 = "",
        };
    };

    pub const HeadSet = struct {
        names: []const []const u8,
    };

    pub const UnionShape = struct {
        alternatives: []const QualifiedRef,
    };

    pub const CrossRef = struct {
        target_form: []const u8,
        name_key: []const u8 = "name",
        acyclic: bool = false,
        scope_form: ?[]const u8 = null,
    };
};

const testing = std.testing;
