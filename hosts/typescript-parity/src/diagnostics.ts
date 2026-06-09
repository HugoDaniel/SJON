// Diagnostic surface for the second-host. The set is intentionally
// limited to the codes the conformance corpus exercises today; new
// codes are appended as the corpus grows.

export type DiagnosticCode =
  | 'unspecified'
  | 'unknown_form'
  // A form value in a slot that declares local forms whose head matched
  // neither a local form nor — after the additive fallback — any global
  // form. Emitted at the slot path; the generic `unknown_form` is
  // suppressed. Mirrors `Validator.zig:emitUnknownLocalForm`.
  | 'unknown_local_form'
  | 'unknown_key'
  // Cross-plugin ambiguity surfaced by the validator when a bare head /
  // value-kind name is claimed by more than one plugin. Mirrors
  // `Validator.zig:emitAmbiguous` and the `matchType` ambiguity branch.
  | 'ambiguous_form'
  | 'ambiguous_expr'
  | 'ambiguous_element_kind'
  | 'duplicate_key'
  | 'missing_required_key'
  | 'positional_not_allowed'
  | 'wrong_underlying'
  | 'not_member'
  // Severity `.warning`. Emitted on a successful match against a
  // MemberSet whose matched Member carries `deprecated: true`. The
  // value is still accepted; the message includes
  // `:deprecation-message` when set, otherwise generic
  // "is deprecated".
  | 'deprecated_member'
  | 'not_head_member'
  // A `:underlying union` / `scalar-or-ref` value rejected by every
  // alternative in the union's first-match dispatch.
  | 'union_no_branch_matched'
  | 'not_flag_member'
  | 'duplicate_positional_flag'
  | 'arity_mismatch'
  | 'expr_type_mismatch'
  | 'unknown_element_kind'
  | 'expr_kvpair_not_allowed'
  | 'recursion_depth'
  | 'vector_length_mismatch'
  | 'vector_too_short'
  | 'vector_too_long'
  | 'vector_bounds_invalid'
  | 'unit_required'
  | 'unit_not_allowed'
  | 'unit_forbidden'
  // Schema-load-phase: emitted by the manifest loader, not the validator.
  | 'too_many_keys'
  // Cross-ref family. Validate-time: `not_cross_ref`,
  // `duplicate_cross_ref_target`, `cross_ref_outside_scope`,
  // `cyclic_cross_ref`. Schema-aggregate-time (emitted by
  // `validateCrossRefs` in plugin.ts): the remainder.
  | 'not_cross_ref'
  | 'duplicate_cross_ref_target'
  | 'cross_ref_outside_scope'
  | 'cyclic_cross_ref'
  | 'unknown_cross_ref_target'
  | 'ambiguous_cross_ref_target'
  | 'cross_ref_name_key_unknown'
  | 'acyclic_without_self_edge'
  | 'unknown_cross_ref_scope'
  | 'ambiguous_cross_ref_scope'
  // Parser-emitted diagnostic. Fires when a pure-integer literal
  // exceeds the u64 (or, with a leading `-`, the i64) range so the
  // exact AST tag the Zig parser would emit isn't representable. The
  // TS-parity parser falls back to `Number.parseFloat` storage —
  // matching Zig's f64 fallback semantics — and surfaces this diag.
  | 'number_overflow_exact_integer'
  // Parser-emitted date diagnostics. The lexer accepts the 10-char
  // `YYYY-MM-DD` shape; the parser then rejects out-of-range
  // components (year 0, month outside 1..12, day outside
  // 1..daysInMonth, including the leap-year Feb 29 case).
  | 'date_invalid_year'
  | 'date_invalid_month'
  | 'date_invalid_day'
  // Parser-emitted time diagnostics. The lexer accepts the 8- or
  // 12-char shape (`HH:MM:SS` / `HH:MM:SS.fff`); the parser then
  // rejects out-of-range components (hour > 23, minute > 59,
  // second > 59). Millisecond range is enforced at the lexer level
  // (exactly 3 digits ⇒ 0..999).
  | 'time_invalid_hour'
  | 'time_invalid_minute'
  | 'time_invalid_second'
  // Host-layer codes — emitted by Host.validateDocument when partitioning
  // declarations, loading manifests, and resolving (use-plugin …)
  // references. `invalid_manifest` covers shape failures from the
  // partition / parse-reference / project-file passes; the rest are
  // resolver-phase outcomes.
  | 'invalid_manifest'
  | 'unresolved_plugin'
  | 'duplicate_plugin_name'
  | 'plugin_name_mismatch'
  | 'plugin_version_mismatch'
  | 'plugin_hash_mismatch'
  | 'project_file_not_found'
  // Numeric-bounds (`:numeric` refinement) family. The first six are
  // validate-time emissions from the `:number` arm of matchKind; the
  // seventh is a loader emission for an internally inconsistent
  // `(numeric-bounds …)` form (e.g. `:exclusive-min true` without
  // `:min`, an empty `:min > :max` range, or `:numeric` attached to a
  // non-`number` underlying).
  | 'number_below_min'
  | 'number_above_max'
  | 'number_at_or_below_exclusive_min'
  | 'number_at_or_above_exclusive_max'
  | 'number_not_integer'
  | 'numeric_bound_unit_mismatch'
  | 'numeric_bounds_invalid'
  // GPU representation tag (`:repr`). A `.number` value outside its
  // declared GPU type's range, or non-integral under `u16`/`u32`/`i32`.
  | 'repr_out_of_range'
  // String-bounds (`:string-bounds` refinement) family. The first four
  // are validate-time emissions from the `:string` arm of matchKind;
  // `string_pattern_unsupported` is a `.warning` (v1 builds have no
  // regex engine — the constraint is informational); `string_pattern_mismatch`
  // is reserved for the regex-engine milestone and is never emitted
  // in v1; `string_bounds_invalid` is loader-emitted for an internally
  // inconsistent `(string-bounds …)` form (empty range, negative bound,
  // wrong underlying, empty pattern, or a member literal that itself
  // fails the declared length / format).
  | 'string_too_short'
  | 'string_too_long'
  | 'string_format_mismatch'
  | 'string_pattern_mismatch'
  | 'string_pattern_unsupported'
  | 'string_bounds_invalid'
  // Multi-key exclusive-group bundle diagnostics. Validate-time:
  // `exclusive_bundle_partial` fires when a `(alt :keys [a b])`-style
  // bundle has some-but-not-all keys present and no sibling alt is
  // fully present to win the group. Manifest-load-time:
  // `exclusive_bundle_collision` fires when one key name appears in
  // two alternatives of the same group (the cross-group case still
  // emits `exclusive_group_invalid`).
  | 'exclusive_bundle_partial'
  | 'exclusive_bundle_collision'
  // v1.1 manifest-metadata diagnostics. All emitted by the manifest
  // loader; mirror src/ManifestLoader.zig + src/Ast.zig.
  // `plugin_wasm_self_hash_malformed` is err-severity (well-formedness);
  // `license_unrecognized` and `too_many_keywords` are advisory warnings;
  // `sjon_format_unsupported` is err-severity (host refuses to validate
  // against a manifest declaring a higher format version).
  | 'plugin_wasm_self_hash_malformed'
  | 'license_unrecognized'
  | 'too_many_keywords'
  | 'sjon_format_unsupported';

export interface Diagnostic {
  readonly code: DiagnosticCode;
  readonly message: string;
  readonly path: readonly string[];
  readonly span: { start: number; end: number };
  readonly severity: 'err' | 'warning';
}
