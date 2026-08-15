//! GENERATED FILE — do not edit by hand.
//!
//! Source of truth: manifests/meta.sjon. Regenerate with:
//!     zig build gen-meta-schema -- --regen
//!
//! `zig build test` byte-compares this file against a fresh
//! generation, so editing meta.sjon without regenerating — or
//! hand-editing this file — fails CI. See tools/gen_meta_schema.zig.

const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
const std = @import("std");

const value_kinds = [_]Plugin.ValueKind{
    .{ .name = "underlying-tag", .underlying = .symbol, .description = "Closed set of valid :underlying values.", .members = .{ .members = &.{ .{ .name = "number" }, .{ .name = "string" }, .{ .name = "vector" }, .{ .name = "form" }, .{ .name = "symbol" }, .{ .name = "union" }, .{ .name = "scalar-or-ref" } } } },
    .{ .name = "cardinality-tag", .underlying = .symbol, .description = "Closed set of valid :cardinality values on (exclusive-group …).", .members = .{ .members = &.{ .{ .name = "exactly-one" }, .{ .name = "at-most-one" } } } },
    .{ .name = "type-ref", .underlying = .symbol, .description = "Primitive type name or value-kind reference." },
    .{ .name = "binding-ref", .underlying = .string, .description = "Symbolic :impl reference of the form \"<scheme>:<name>\"." },
    .{ .name = "symbol-list", .underlying = .vector, .description = "Vector of bare symbols.", .vector = .{ .element = .{ .name = "symbol" } } },
    .{ .name = "sha256-hash", .underlying = .string, .description = "Hex digest of the shape `sha256-<64 lowercase hex chars>`." },
    .{ .name = "spdx-id", .underlying = .string, .description = "SPDX license identifier (e.g. CC0-1.0, Apache-2.0). Free-form strings accepted with a warning." },
    .{ .name = "type-list", .underlying = .vector, .description = "Vector of type references (primitive names or value-kind names).", .vector = .{ .element = .{ .name = "type-ref" } } },
    .{ .name = "plugin-decl", .underlying = .form, .description = "A declaration sub-form inside (plugin …).", .heads = .{ .names = &.{ "value-kind", "form", "expr-func", "cross-ref-provider" } } },
    .{ .name = "key-decl", .underlying = .form, .description = "A (key …) | (variant …) | (exclusive-group …) sub-form.", .heads = .{ .names = &.{ "key", "variant", "exclusive-group" } } },
    .{ .name = "form-child-decl", .underlying = .form, .description = "A (key …) | (variant …) | (exclusive-group …) | (form …) sub-form inside (form …).", .heads = .{ .names = &.{ "key", "variant", "exclusive-group", "form" } } },
    .{ .name = "key-local-decl", .underlying = .form, .description = "An inline slot-local (form …) sub-form inside (key …).", .heads = .{ .names = &.{"form"} } },
    .{ .name = "alt-decl", .underlying = .form, .description = "An (alt …) sub-form inside (exclusive-group …).", .heads = .{ .names = &.{"alt"} } },
    .{ .name = "signature-spec", .underlying = .form, .description = "A (signature …) sub-form for multi-signature expr-func.", .heads = .{ .names = &.{"signature"} } },
    .{ .name = "arity-spec", .underlying = .form, .description = "Arity declaration: (fixed N) | (at-least N) | (range :min M :max N).", .heads = .{ .names = &.{ "fixed", "at-least", "range" } } },
    .{ .name = "vector-shape-ref", .underlying = .form, .description = "Slot pinned to a (vector-shape …) form.", .heads = .{ .names = &.{"vector-shape"} } },
    .{ .name = "unit-shape-ref", .underlying = .form, .description = "Slot pinned to a (unit-shape …) form.", .heads = .{ .names = &.{"unit-shape"} } },
    .{ .name = "numeric-bounds-ref", .underlying = .form, .description = "Slot pinned to a (numeric-bounds …) form.", .heads = .{ .names = &.{"numeric-bounds"} } },
    .{ .name = "string-bounds-ref", .underlying = .form, .description = "Slot pinned to a (string-bounds …) form.", .heads = .{ .names = &.{"string-bounds"} } },
    .{ .name = "string-format-tag", .underlying = .symbol, .description = "Closed set of valid :format values on (string-bounds …).", .members = .{ .members = &.{ .{ .name = "email" }, .{ .name = "uri" }, .{ .name = "path" }, .{ .name = "uuid" }, .{ .name = "semver" } } } },
    .{ .name = "repr-shape-ref", .underlying = .form, .description = "Slot pinned to a (repr-shape …) form.", .heads = .{ .names = &.{"repr-shape"} } },
    .{ .name = "repr-type-tag", .underlying = .symbol, .description = "Closed set of valid :type values on (repr-shape …).", .members = .{ .members = &.{ .{ .name = "f32" }, .{ .name = "u32" }, .{ .name = "i32" }, .{ .name = "u16" }, .{ .name = "f16" } } } },
    .{ .name = "scalar-or-ref-shape-ref", .underlying = .form, .description = "Slot pinned to a (scalar-or-ref-shape …) form.", .heads = .{ .names = &.{"scalar-or-ref-shape"} } },
    .{ .name = "member-set-ref", .underlying = .form, .description = "Slot pinned to a (member-set …) form.", .heads = .{ .names = &.{"member-set"} } },
    .{ .name = "member-decl", .underlying = .form, .description = "A (member …) sub-form inside (member-set …).", .heads = .{ .names = &.{"member"} } },
    .{ .name = "head-set-ref", .underlying = .form, .description = "Slot pinned to a (head-set …) form.", .heads = .{ .names = &.{"head-set"} } },
    .{ .name = "cross-ref-shape-ref", .underlying = .form, .description = "Slot pinned to a (cross-ref …) form.", .heads = .{ .names = &.{"cross-ref"} } },
    .{ .name = "union-shape-ref", .underlying = .form, .description = "Slot pinned to a (union-shape …) form.", .heads = .{ .names = &.{"union-shape"} } },
    .{ .name = "lowering-ref", .underlying = .form, .description = "Slot pinned to a (lowering …) form.", .heads = .{ .names = &.{"lowering"} } },
    .{ .name = "flag-decl", .underlying = .form, .description = "A (flag …) sub-form inside (flag-set …).", .heads = .{ .names = &.{"flag"} } },
    .{ .name = "flag-set-ref", .underlying = .form, .description = "Slot pinned to a (flag-set …) form.", .heads = .{ .names = &.{"flag-set"} } },
    .{ .name = "positional-ref", .underlying = .union_of, .description = "A form's :positional — a type-ref symbol or a (flag-set …) form.", .union_of = .{ .alternatives = &.{ .{ .name = "type-ref" }, .{ .name = "flag-set-ref" } } } },
};

const forms = [_]Plugin.FormSpec{
    .{ .name = "plugin", .description = "Top-level manifest form — wraps a plugin's declarations.", .positional = .{ .kind = .{ .name = "plugin-decl" } }, .keys = &.{
        .{ .name = "name", .value_type = .symbol, .optional = false },
        .{ .name = "version", .value_type = .string, .optional = false },
        .{ .name = "description", .value_type = .string },
        .{ .name = "wasm-file", .value_type = .string },
        .{ .name = "wasm-sha256", .value_type = .{ .named = .{ .name = "sha256-hash" } } },
        .{ .name = "authors", .value_type = .vector },
        .{ .name = "license", .value_type = .{ .named = .{ .name = "spdx-id" } } },
        .{ .name = "homepage", .value_type = .string },
        .{ .name = "repository", .value_type = .string },
        .{ .name = "keywords", .value_type = .{ .named = .{ .name = "symbol-list" } } },
        .{ .name = "sjon", .value_type = .string },
    } },
    .{ .name = "value-kind", .description = "Declares a named refinement of one underlying primitive.", .keys = &.{
        .{ .name = "name", .value_type = .symbol, .optional = false },
        .{ .name = "underlying", .value_type = .{ .named = .{ .name = "underlying-tag" } }, .optional = false },
        .{ .name = "description", .value_type = .string },
        .{ .name = "vector", .value_type = .{ .named = .{ .name = "vector-shape-ref" } } },
        .{ .name = "unit", .value_type = .{ .named = .{ .name = "unit-shape-ref" } } },
        .{ .name = "numeric", .value_type = .{ .named = .{ .name = "numeric-bounds-ref" } } },
        .{ .name = "string-bounds", .value_type = .{ .named = .{ .name = "string-bounds-ref" } } },
        .{ .name = "repr", .value_type = .{ .named = .{ .name = "repr-shape-ref" } } },
        .{ .name = "scalar-or-ref", .value_type = .{ .named = .{ .name = "scalar-or-ref-shape-ref" } } },
        .{ .name = "members", .value_type = .{ .named = .{ .name = "member-set-ref" } } },
        .{ .name = "heads", .value_type = .{ .named = .{ .name = "head-set-ref" } } },
        .{ .name = "cross-ref", .value_type = .{ .named = .{ .name = "cross-ref-shape-ref" } } },
        .{ .name = "union", .value_type = .{ .named = .{ .name = "union-shape-ref" } } },
    } },
    .{ .name = "vector-shape", .description = "Pins element kind and (optional) length on a :vector underlying.", .keys = &.{
        .{ .name = "len", .value_type = .number },
        .{ .name = "min-len", .value_type = .number },
        .{ .name = "max-len", .value_type = .number },
        .{ .name = "element", .value_type = .{ .named = .{ .name = "type-ref" } }, .optional = false },
    } },
    .{ .name = "unit-shape", .description = "Pins unit-suffix requirements on a :number underlying.", .keys = &.{
        .{ .name = "required", .value_type = .boolean },
        .{ .name = "reject", .value_type = .boolean },
        .{ .name = "allowed", .value_type = .{ .named = .{ .name = "symbol-list" } } },
    } },
    .{ .name = "numeric-bounds", .description = "Range / integrality constraints on a :number underlying.", .keys = &.{
        .{ .name = "min", .value_type = .number },
        .{ .name = "max", .value_type = .number },
        .{ .name = "exclusive-min", .value_type = .boolean },
        .{ .name = "exclusive-max", .value_type = .boolean },
        .{ .name = "integer", .value_type = .boolean },
    } },
    .{ .name = "string-bounds", .description = "Length / pattern / format constraints on a :string underlying.", .keys = &.{
        .{ .name = "min-len", .value_type = .number },
        .{ .name = "max-len", .value_type = .number },
        .{ .name = "pattern", .value_type = .string },
        .{ .name = "format", .value_type = .{ .named = .{ .name = "string-format-tag" } } },
    } },
    .{ .name = "repr-shape", .description = "GPU representation tag (f32|u32|i32|u16|f16) for a :number underlying.", .keys = &.{
        .{ .name = "type", .value_type = .{ .named = .{ .name = "repr-type-tag" } }, .optional = false },
    } },
    .{ .name = "scalar-or-ref-shape", .description = "Shorthand for `union [<base> symbol]` — a scalar kind or a symbolic reference. Desugars at load time.", .keys = &.{
        .{ .name = "base", .value_type = .{ .named = .{ .name = "type-ref" } }, .optional = false },
    } },
    .{ .name = "member-set", .description = "Closed-set membership for :symbol or :string underlyings.", .positional = .{ .kind = .{ .name = "member-decl" } }, .keys = &.{
        .{ .name = "values", .value_type = .{ .named = .{ .name = "symbol-list" } } },
    } },
    .{ .name = "member", .description = "One entry in a (member-set …). Carries optional editor metadata.", .keys = &.{
        .{ .name = "name", .value_type = .symbol, .optional = false },
        .{ .name = "label", .value_type = .string },
        .{ .name = "description", .value_type = .string },
        .{ .name = "deprecated", .value_type = .boolean },
        .{ .name = "deprecation-message", .value_type = .string },
    } },
    .{ .name = "flag", .description = "One positional keyword flag inside (flag-set …). Carries optional editor metadata.", .keys = &.{
        .{ .name = "name", .value_type = .symbol, .optional = false },
        .{ .name = "description", .value_type = .string },
        .{ .name = "link", .value_type = .string },
    } },
    .{ .name = "flag-set", .description = "Closed set of positional keyword flags for a form's :positional.", .positional = .{ .kind = .{ .name = "flag-decl" } } },
    .{ .name = "head-set", .description = "Closed-set head-name pinning for :form underlyings.", .keys = &.{
        .{ .name = "names", .value_type = .{ .named = .{ .name = "symbol-list" } }, .optional = false },
    } },
    .{ .name = "cross-ref", .description = "Document-spanning name-reference constraint for :symbol underlyings.", .keys = &.{
        .{ .name = "target", .value_type = .symbol, .optional = false },
        .{ .name = "name-key", .value_type = .symbol },
        .{ .name = "acyclic", .value_type = .boolean },
        .{ .name = "scope", .value_type = .symbol },
        .{ .name = "provider", .value_type = .symbol },
        .{ .name = "source-key", .value_type = .symbol },
    } },
    .{ .name = "union-shape", .description = "Pins alternative kind names on a :union underlying.", .keys = &.{
        .{ .name = "alternatives", .value_type = .{ .named = .{ .name = "type-list" } }, .optional = false },
    } },
    .{ .name = "form", .description = "Declares a data-form constructor (e.g. (scene …)).", .positional = .{ .kind = .{ .name = "form-child-decl" } }, .keys = &.{
        .{ .name = "name", .value_type = .symbol, .optional = false },
        .{ .name = "description", .value_type = .string },
        .{ .name = "positional", .value_type = .{ .named = .{ .name = "positional-ref" } } },
        .{ .name = "open", .value_type = .boolean },
        .{ .name = "discriminant", .value_type = .symbol },
        .{ .name = "lowering", .value_type = .{ .named = .{ .name = "lowering-ref" } } },
    } },
    .{ .name = "variant", .description = "Per-discriminant-value extra key set on a discriminated form.", .positional = .{ .kind = .{ .name = "key-decl" } }, .keys = &.{
        .{ .name = "when", .value_type = .symbol, .optional = false },
    } },
    .{ .name = "key", .description = "One declared :keyword value slot on a form.", .positional = .{ .kind = .{ .name = "key-local-decl" } }, .keys = &.{
        .{ .name = "name", .value_type = .symbol, .optional = false },
        .{ .name = "type", .value_type = .{ .named = .{ .name = "type-ref" } }, .optional = false },
        .{ .name = "optional", .value_type = .boolean },
        .{ .name = "default", .value_type = .any, .walk_opaque = true },
        .{ .name = "walk-opaque", .value_type = .boolean },
        .{ .name = "description", .value_type = .string },
    } },
    .{ .name = "expr-func", .description = "Declares a safe-expression function.", .positional = .{ .kind = .{ .name = "signature-spec" } }, .keys = &.{
        .{ .name = "name", .value_type = .symbol, .optional = false },
        .{ .name = "arity", .value_type = .{ .named = .{ .name = "arity-spec" } } },
        .{ .name = "params", .value_type = .{ .named = .{ .name = "type-list" } } },
        .{ .name = "param-names", .value_type = .{ .named = .{ .name = "symbol-list" } } },
        .{ .name = "rest", .value_type = .{ .named = .{ .name = "type-ref" } } },
        .{ .name = "result", .value_type = .{ .named = .{ .name = "type-ref" } } },
        .{ .name = "description", .value_type = .string },
        .{ .name = "impl", .value_type = .{ .named = .{ .name = "binding-ref" } } },
    } },
    .{ .name = "cross-ref-provider", .description = "Declares a pure name-extractor backing a provider-route cross-ref.", .keys = &.{
        .{ .name = "name", .value_type = .symbol, .optional = false },
        .{ .name = "description", .value_type = .string },
        .{ .name = "impl", .value_type = .{ .named = .{ .name = "binding-ref" } } },
    } },
    .{ .name = "signature", .description = "One overload of a multi-signature expr-func.", .keys = &.{
        .{ .name = "arity", .value_type = .{ .named = .{ .name = "arity-spec" } }, .optional = false },
        .{ .name = "params", .value_type = .{ .named = .{ .name = "type-list" } } },
        .{ .name = "param-names", .value_type = .{ .named = .{ .name = "symbol-list" } } },
        .{ .name = "rest", .value_type = .{ .named = .{ .name = "type-ref" } } },
        .{ .name = "result", .value_type = .{ .named = .{ .name = "type-ref" } } },
    } },
    .{ .name = "fixed", .description = "Exact-arity declaration: (fixed N).", .positional = .any },
    .{ .name = "at-least", .description = "Lower-bound arity declaration: (at-least N).", .positional = .any },
    .{ .name = "range", .description = "Inclusive-range arity declaration: (range :min M :max N).", .keys = &.{
        .{ .name = "min", .value_type = .number, .optional = false },
        .{ .name = "max", .value_type = .number, .optional = false },
    } },
    .{ .name = "exclusive-group", .description = "Cross-key cardinality constraint on (form …) or (variant …).", .positional = .{ .kind = .{ .name = "alt-decl" } }, .keys = &.{
        .{ .name = "cardinality", .value_type = .{ .named = .{ .name = "cardinality-tag" } } },
    } },
    .{ .name = "alt", .description = "One alternative key bundle inside (exclusive-group …).", .keys = &.{
        .{ .name = "keys", .value_type = .{ .named = .{ .name = "symbol-list" } }, .optional = false },
    } },
    .{ .name = "lowering", .description = "Host-owned lowering contract attached to a (form …). The hook is symbolic and versioned (e.g. pngine/pass-v1); :produces is a closed list of form heads the contract may emit.", .keys = &.{
        .{ .name = "hook", .value_type = .symbol, .optional = false },
        .{ .name = "produces", .value_type = .{ .named = .{ .name = "symbol-list" } }, .optional = false },
    } },
};

pub const plugin: Plugin.Plugin = .{ .name = "meta", .version = "1.0.0", .forms = &forms, .value_kinds = &value_kinds };

pub const schema: Schema.Schema = .{ .plugins = &.{plugin} };

comptime {
    for (forms) |f| std.debug.assert(f.keys.len <= Plugin.MAX_FORM_KEYS);
}
