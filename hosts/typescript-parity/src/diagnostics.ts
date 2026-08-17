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
  // Provider-route cross-refs (manifest format 1.2). The first three are
  // schema-aggregate-time, like their identity-route twins above, and this
  // host emits them.
  | 'unknown_cross_ref_provider'
  | 'ambiguous_cross_ref_provider'
  | 'cross_ref_source_key_unknown'
  // The last two are validate-time and this host never emits them: they
  // report on *running* an extractor, which needs the executable plugin
  // ABI the TS-parity port deliberately doesn't implement. They are listed
  // so the union stays a complete mirror of `Ast.Diagnostic.Code` — a host
  // reading someone else's diagnostics still has to name them.
  | 'cross_ref_extraction_failed'
  | 'cross_ref_provider_unavailable'
  // Schema-aggregate-time again, and this host emits it: two value-kinds
  // cross-referencing one target with differing specs. Detecting the
  // collapse needs only the declarations, not a running extractor.
  | 'cross_ref_target_collapse'
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
  // Value is not an exact multiple of `:multiple-of` (manifest format
  // 1.3). Checked after `:integer` and after the range bounds, so the
  // more basic violation is the one reported. Divisibility is decided in
  // exact integer space whenever both sides are whole.
  | 'number_not_multiple'
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
  // Exclusive-group family. Validate-time: `exclusive_bundle_partial`
  // fires when a `(alt :keys [a b])`-style bundle has some-but-not-all
  // keys present and no sibling alt is fully present to win the group.
  // Manifest-load-time: `exclusive_bundle_collision` fires when one key
  // name appears in two alternatives of the *same* group, and
  // `exclusive_group_invalid` covers every other malformed declaration —
  // fewer than two alts, an alt naming an undeclared key or the
  // discriminant, or one key shared across two groups on the same scope.
  // `mutually_exclusive_keys_present` fires when two alternatives of one
  // group are both fully present; `required_one_of_missing` when an
  // `exactly-one` group has none. Both are pathed at the form, once per
  // group — a group is about its alternatives, not its keys.
  | 'mutually_exclusive_keys_present'
  | 'required_one_of_missing'
  | 'exclusive_bundle_partial'
  | 'exclusive_bundle_collision'
  | 'exclusive_group_invalid'
  // A key carrying `:requires [b c]` is present while one or more of the
  // keys it names is absent (manifest format 1.3). The third inter-key
  // mechanism: `exclusive-group` bounds how many of a set may appear,
  // `(variant …)` gates keys on the discriminant's value, this gates one
  // key's requirement on another key's presence. One-directional, and
  // suppressed by `:open true` like every other closed-form shape rule.
  | 'dependent_key_missing'
  // Discriminated-form family. Validate-time: `missing_discriminant_key`
  // when a closed discriminated form carries no discriminant kvpair, so no
  // variant can be selected — one emit, in place of the pile of
  // missing-variant-key diagnostics that would otherwise follow.
  // Schema-aggregate-time (emitted by
  // `validateForms` in plugin.ts): `discriminant_not_closed_enum` when the
  // discriminant key's type is not a symbol value-kind with a non-empty
  // `:members`, `unknown_discriminant_value` for a `(variant :when …)` whose
  // value is not one of those members, `variant_key_collision` when one key
  // name is declared in two scopes of the same form.
  | 'missing_discriminant_key'
  | 'discriminant_not_closed_enum'
  | 'unknown_discriminant_value'
  | 'variant_key_collision'
  // Schema-aggregate-time: a `:union` alternative that is itself a union.
  // Rejected outright so union dispatch stays a flat loop. Emitted by
  // `validateUnions` in plugin.ts.
  | 'nested_union'
  // Severity `warning`. A symbol in a `:underlying union` slot is a
  // registered name in two or more of the union's cross-ref-backed
  // alternatives, so which entity the slot denotes is decided by the order
  // the alternatives were declared in. The document still validates —
  // first match still wins. Deliberately narrow: gated on cross-ref-backed
  // alternatives (a union overlapping on plain values is *designed* for
  // first-match), silent when the winning alternative is not itself a
  // reference, and deduplicated by bucket so two kinds pointing at one
  // target do not read as two entities.
  | 'union_ambiguous'
  // Per-head positional counts from a `(head :name … :min … :max …)`
  // entry. `positional_too_many` lands on the child that crosses the
  // ceiling (one report per crossing, not per extra child);
  // `positional_missing` at the parent form's head, where
  // `missing_required_key` lands, because a floor breach is an
  // end-of-children fact with no child to point at. Neither is
  // suppressed by `:open true` — openness widens the *keyword* surface,
  // and `:positional <bounded-kind>` opts into the count. Counts apply
  // only at a form's `:positional` slot; the same kind reused on a keyed
  // or vector-element slot carries its bounds inertly.
  | 'positional_too_many'
  | 'positional_missing'
  // v1.1 manifest-metadata diagnostics. All emitted by the manifest
  // loader; mirror src/ManifestLoader.zig + src/Ast.zig.
  // `plugin_wasm_self_hash_malformed` is err-severity (well-formedness);
  // `license_unrecognized` and `too_many_keywords` are advisory warnings;
  // `sjon_format_unsupported` is err-severity (host refuses to validate
  // against a manifest declaring a higher format version).
  | 'plugin_wasm_self_hash_malformed'
  | 'license_unrecognized'
  | 'too_many_keywords'
  | 'sjon_format_unsupported'
  // Pattern-query-time diagnostic (emitted by the PatternQuery walker, not
  // the validator): a `fast` / `slow` combinator expanded the query window
  // past the 2^53 tick ceiling. The offending combinator contributes no
  // haps; the rest of the pattern is queried normally. Mirrors
  // `src/PatternQuery.zig:emitTickOverflow`.
  | 'pattern_tick_overflow'
  // Pattern-compile-time diagnostics for `(pure …)` expression leaves
  // (emitted by `PatternQuery.compileTree`'s cycle-0 dry-run, tree path
  // only): the expression failed to evaluate (`_eval_failed`: unbound name,
  // div-by-zero, arity, budget), or evaluated to a value no hap can carry
  // (`_result_invalid`: a form — usually a misspelled function name — or a
  // vector / date / time). The leaf degrades to silence. A later-cycle
  // failure is instead a silent counted drop, not a diagnostic. ts-parity
  // has no Expr evaluator, so it never emits these — Web + Rust (via the
  // shared sjon.wasm) cover them; they are listed for wire-protocol parity.
  | 'pattern_value_eval_failed'
  | 'pattern_value_result_invalid';

export interface Diagnostic {
  readonly code: DiagnosticCode;
  readonly message: string;
  readonly path: readonly string[];
  readonly span: { start: number; end: number };
  readonly severity: 'err' | 'warning';
}
