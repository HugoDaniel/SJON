const std = @import("std");

pub const Severity = enum { info, warn, err };

pub const Code = enum {
    cross_ref_unenforceable,
    expression_default_annotation_only,
    expression_slot_annotation_only,
    exclusive_group_unenforceable,
    acyclic_unenforceable,
    deferred_construct,
    ts_name_collision,
    exact_int_overflow,
    string_pattern_engine_mismatch,
    string_format_unknown_to_jsonschema,
    aggregate_phase_error,
    variants_emitted_via_if_then,
    union_emitted_via_anyof,
    head_set_emitted_via_oneof_refs,
    local_forms_emitted_inline,
    rich_members_emitted_with_annotations,
    numeric_bounds_emitted_via_min_max,
    numeric_bound_exceeds_double_range,
    number_with_unit_emitted_via_prefix_items,
    string_bounds_emitted_via_keywords,
    cross_ref_annotation_only,
    multi_key_exclusive_emitted,
};

pub const Warning = struct {
    code: Code,
    severity: Severity,
    message: []const u8,
    plugin_name: ?[]const u8 = null,
    form_name: ?[]const u8 = null,
    key_name: ?[]const u8 = null,
    kind_name: ?[]const u8 = null,

    pub fn isError(self: Warning) bool {
        return self.severity == .err;
    }
};

pub fn anyError(warnings: []const Warning) bool {
    for (warnings) |w| if (w.isError()) return true;
    return false;
}
