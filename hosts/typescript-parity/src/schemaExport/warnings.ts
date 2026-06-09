// Warning surface for the schema exporter — TypeScript port of
// `src/SchemaExport/Warnings.zig`. Code names match the Zig enum's
// snake_case tag names so cross-host parity tests can compare on the
// `code` string field.

export type WarningSeverity = 'info' | 'warn' | 'err';

/**
 * Closed set of warning codes the exporter emits. New codes can be
 * added freely — the order is not wire-stable; downstream tooling
 * reads the string value, not the position.
 */
export type WarningCode =
  | 'cross_ref_unenforceable'
  | 'expression_default_annotation_only'
  | 'expression_slot_annotation_only'
  | 'exclusive_group_unenforceable'
  | 'acyclic_unenforceable'
  | 'deferred_construct'
  | 'ts_name_collision'
  | 'exact_int_overflow'
  | 'string_pattern_engine_mismatch'
  | 'string_format_unknown_to_jsonschema'
  | 'aggregate_phase_error'
  | 'variants_emitted_via_if_then'
  | 'union_emitted_via_anyof'
  | 'head_set_emitted_via_oneof_refs'
  | 'local_forms_emitted_inline'
  | 'rich_members_emitted_with_annotations'
  | 'numeric_bounds_emitted_via_min_max'
  | 'numeric_bound_exceeds_double_range'
  | 'number_with_unit_emitted_via_prefix_items'
  | 'string_bounds_emitted_via_keywords'
  | 'cross_ref_annotation_only'
  | 'multi_key_exclusive_emitted';

export interface Warning {
  readonly code: WarningCode;
  readonly severity: WarningSeverity;
  readonly message: string;
  readonly pluginName: string | null;
  readonly formName: string | null;
  readonly keyName: string | null;
  readonly kindName: string | null;
}

export function isErr(w: Warning): boolean {
  return w.severity === 'err';
}

export function anyError(warnings: readonly Warning[]): boolean {
  for (const w of warnings) if (isErr(w)) return true;
  return false;
}

/** Builder helper used by `lower.ts` — keeps call sites concise. */
export function makeWarning(
  code: WarningCode,
  severity: WarningSeverity,
  message: string,
  scope: {
    pluginName?: string | null;
    formName?: string | null;
    keyName?: string | null;
    kindName?: string | null;
  } = {},
): Warning {
  return {
    code,
    severity,
    message,
    pluginName: scope.pluginName ?? null,
    formName: scope.formName ?? null,
    keyName: scope.keyName ?? null,
    kindName: scope.kindName ?? null,
  };
}
