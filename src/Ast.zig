//! SJON AST.
//!
//! `Tree` is the canonical SoA AST (`std.MultiArrayList(Node)` +
//! `extra_data` + string pool + per-node comment ranges). Produced by
//! `Parser.parse` and walked natively by every public consumer
//! (Printer, Validator, Expr, Json, Binary, BinaryCursor). Self-
//! contained: comment text is dup'd into its arena so the tree
//! survives the source buffer.
//!
//! Ownership: every owned slice is arena-allocated; `tree.deinit()`
//! releases everything in one operation.
//!
//! Node tag variants (`Tag`):
//!   `form`              — `(head … children …)` constructor form.
//!   `vector`            — `[a b c]` ordered element list.
//!   `number`            — IEEE-754 f64; original source slice via `span`.
//!   `number_i64`        — exact signed 64-bit integer literal.
//!   `number_u64`        — exact unsigned 64-bit integer literal (only used
//!                         when value exceeds `i64.max`).
//!   `number_with_unit`  — f64 + unit suffix (e.g. `90deg`, `0.5em`, `-50%`).
//!   `string`            — escape-resolved bytes.
//!   `keyword`           — bare keyword used as a value (`:ortho`).
//!   `symbol`            — bare symbol used as a value (variable reference).
//!   `boolean_true` /
//!   `boolean_false`     — `true` / `false`.
//!   `nil`               — the `nil` literal.
//!   `kvpair`            — `:key value` form-child node.
//!
//! A form's children preserve **source order** as `[]const NodeIndex`,
//! where kvpair-tagged nodes represent keyword children. The parser
//! pairs `:kw v` greedily, except when `v` is itself a keyword token —
//! in that case `:kw` becomes a positional keyword value (a "flag").
//!
//! Value-kind vocabulary:
//!
//!   `ValueKind` is the abstract value-shape vocabulary — nine kinds
//!   (`nil`, `boolean`, `number`, `number_with_unit`, `string`,
//!   `keyword`, `symbol`, `vector`, `form`). Layer-specific tag enums
//!   are *refinements* of this vocabulary, each splitting a kind for a
//!   layer-local reason: `Ast.Tag` splits `boolean` (storage), adds
//!   `kvpair` (structural); `Binary.Tag` splits `boolean` and `form`
//!   (wire-byte); `BinaryCursor.NodeKind` aliases `ValueKind` directly.
//!   Project from a layer-specific tag to `ValueKind` via
//!   `Tag.toValueKind` (this file) or `Binary.Tag.toValueKind`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Date = @import("Date.zig");
const Time = @import("Time.zig");

/// Byte-offset span into the original source. End is exclusive.
pub const Span = struct {
    start: u32,
    end: u32,
};

/// Owned byte buffer + the allocator it came from. Returned by every SJON
/// encoder that produces a final byte stream (`Printer.print`,
/// `Edit.applyEdit*`, `Binary.toBinary`). `bytes.deinit()` releases via the
/// captured allocator so callers do not need to remember which `gpa` the
/// buffer came from.
///
/// Pairs with `Tree` / `Validator.Result` / `Json.Result` /
/// `Expr.Result` — every public output of SJON is an owned struct with
/// `.deinit()`.
pub const Bytes = struct {
    gpa: Allocator,
    data: []u8,

    pub fn deinit(self: *const Bytes) void {
        self.gpa.free(self.data);
    }
};

/// A number literal's parsed value plus optional unit suffix. The numeric
/// portion is parsed to f64; the unit (when present) is the raw lexed
/// suffix bytes — ASCII letters or a single `%`. `unit == null` for plain
/// numbers; the SoA `Tree` distinguishes the two via `Tag.number` vs
/// `Tag.number_with_unit`. Used internally by `Json.numberValueToJson` as
/// a tagged-pair intermediate.
pub const NumberValue = struct {
    value: f64,
    /// Borrowed; lifetime is the caller's responsibility.
    unit: ?[]const u8 = null,
};

/// A line or block comment captured from source. `text` is the raw source
/// slice (including the leading `;` or `#| … |#` delimiters), arena-owned.
pub const Comment = struct {
    span: Span,
    text: []const u8,
    kind: Kind,

    pub const Kind = enum { line, block };
};

/// A diagnostic produced during parse or validation. The parser and
/// validator both collect diagnostics rather than aborting — `Tree`
/// always represents a (possibly partial) parse so editors can render
/// under-construction code.
///
/// `code` is the stable, machine-matched identifier — the conformance
/// anchor (cf. LANGUAGE.md §7.6). Cross-host conformance asserts on
/// `(code, path, code-specific fields)`; `span` and `message` prose
/// are host-flavoured and never asserted on. `code = .unspecified`
/// covers parser diagnostics today (validator-side codes are
/// exhaustively wired).
///
/// `path` is the semantic path from the document root to the failing
/// node — a list of `head` / `key` / `index` steps (form heads as
/// bare strings, kvpair keys as bare strings, vector indices as
/// decimal strings). The parser and both validator paths (Tree and
/// Binary) emit these and agree on `(code, path)` for every
/// parity-tested case.
pub const Diagnostic = struct {
    span: Span,
    message: []const u8,
    severity: Severity = .err,
    code: Code = .unspecified,
    /// Semantic path from root to the failing node. Owned by the
    /// enclosing diagnostic arena (Validator.Result / Tree).
    path: []const []const u8 = &.{},

    pub const Severity = enum { err, warning };

    /// Stable diagnostic code surface (v1). Bare snake_case symbols,
    /// grouped by failure family. Adding a code is additive; renaming or
    /// removing one is a breaking change for downstream conformance
    /// fixtures.
    ///
    /// Wire form is `snake_case` everywhere — `@tagName`, the audit
    /// script (`tools/audit_diagnostic_coverage.sh`), and `expected.sjon`
    /// `:code` values. Kebab-case spellings (`unresolved-plugin`) appear
    /// only in human-facing prose (design notes, the diagnostic doc).
    /// Keep the two forms in sync; do not introduce a third.
    ///
    /// **Resolution** — head/key/value-kind name lookup outcomes.
    ///   * `unknown_form` — head not registered by any plugin.
    ///   * `unknown_key` — kvpair key not declared on the form (closed
    ///     forms only — `:open` silences this).
    ///   * `ambiguous_form` — head resolves to ≥ 2 plugins; qualify
    ///     with `<ns>/head`.
    ///   * `ambiguous_expr` — expression head resolves to ≥ 2 plugins.
    ///   * `ambiguous_element_kind` — `.named` value-kind reference
    ///     resolves to ≥ 2 plugins.
    ///   * `unknown_element_kind` — `.named` reference targets an
    ///     undeclared kind (a plugin-setup bug).
    ///   * `recursion_depth` — `.named` chain exceeds
    ///     `Schema.MAX_KIND_DEPTH`.
    ///   * `not_cross_ref` — symbol value isn't a registered name in
    ///     the cross-ref's target table (validate-time).
    ///   * `duplicate_cross_ref_target` — two forms in the document
    ///     forest define the same `(target_form, name)` pair
    ///     (validate-time; emitted at the *second*-by-stable-order
    ///     occurrence's `:name` value).
    ///   * `unknown_cross_ref_target` — a `(cross-ref :target X …)`
    ///     declares `X` but the aggregated schema has no form named
    ///     `X` (schema-aggregate-time).
    ///   * `ambiguous_cross_ref_target` — `:target` resolves to ≥ 2
    ///     forms (schema-aggregate-time).
    ///   * `cross_ref_name_key_unknown` — `:name-key` doesn't appear
    ///     on the target form, or that key's value isn't symbol-typed
    ///     (schema-aggregate-time).
    ///   * `acyclic_without_self_edge` — `(cross-ref … :acyclic true)`
    ///     declared on a kind whose target form has no key whose type
    ///     resolves to that kind (schema-aggregate-time; the flag would
    ///     be silently inert without this check).
    ///   * `cyclic_cross_ref` — a cycle of `:acyclic true` cross-ref
    ///     edges among forest forms (validate-time; emitted on each
    ///     cycle member's `:name` value span).
    ///   * `cross_ref_extraction_failed` /
    ///     `cross_ref_provider_unavailable` — a provider-route
    ///     cross-ref's member set could not be computed, because the
    ///     extractor rejected the source or because the host never ran
    ///     it (validate-time; both poison the bucket, so membership
    ///     misses against it stay silent).
    ///   * `cross_ref_target_collapse` — two value-kinds declare a
    ///     cross-ref on one target but disagree on how its members are
    ///     built; first-wins, so the loser's spec is inert
    ///     (schema-aggregate-time, `.warning`).
    ///
    /// **Form-shape rules** — kvpair / positional integrity.
    ///   * `duplicate_key` — same `:k` appears twice in one form
    ///     (kvpair lists carry map semantics; rejected even on `:open`).
    ///   * `missing_required_key` — `:optional false` key absent on a
    ///     closed form.
    ///   * `positional_not_allowed` — positional child on a form whose
    ///     `:positional` is `none` (closed forms only).
    ///   * `expr_kvpair_not_allowed` — expression head received a
    ///     `:kw v` argument but has not opted into labeled args
    ///     (`param_names` not declared). See also `expr_unknown_label`,
    ///     `expr_duplicate_label`, `expr_missing_label`, `expr_mixed_args`
    ///     for the labeled-call diagnostics on opted-in functions.
    ///   * `missing_discriminant_key` — discriminated form's
    ///     discriminant kvpair (e.g. `:kind`) is absent. Variant
    ///     required-key sweep is skipped to avoid noise.
    ///   * `unknown_discriminant_value` — schema-aggregate-time: a
    ///     `(variant :when X)` declaration's `X` is not a member of
    ///     the discriminant key's `MemberSet`.
    ///   * `discriminant_not_closed_enum` — schema-aggregate-time:
    ///     the discriminant key's value type doesn't resolve to a
    ///     `.symbol` underlying with a non-empty `MemberSet` (variant
    ///     exhaustiveness needs a closed enum).
    ///   * `variant_key_collision` — schema-aggregate-time: same key
    ///     name appears in `keys` and a variant, or in two variants.
    ///   * `mutually_exclusive_keys_present` — validate-time: ≥ 2
    ///     alternatives of the same `exclusive_groups` entry are
    ///     simultaneously present on a form (or active variant).
    ///   * `required_one_of_missing` — validate-time: an
    ///     `exclusive_groups` entry with `cardinality = .exactly_one`
    ///     has zero alternatives present.
    ///   * `exclusive_group_invalid` — manifest-time: a declared
    ///     `(exclusive-group …)` is malformed — fewer than two
    ///     alternatives, names a key not declared on the enclosing
    ///     scope, names the discriminant, or shares a key with another
    ///     group on the same scope.
    ///   * `exclusive_bundle_partial` — validate-time: a multi-key
    ///     alternative (`(alt :keys [from to])`) has some-but-not-all
    ///     keys present and no sibling alternative is fully present
    ///     to win. Bundles are all-or-nothing.
    ///   * `exclusive_bundle_collision` — manifest-time: one key name
    ///     appears in two alternatives of the same exclusive-group.
    ///     The cross-group variant keeps `exclusive_group_invalid`.
    ///
    /// **Type-level (typed slots)** — value-shape constraints.
    ///   * `wrong_underlying` — kvpair value or positional kind tag
    ///     doesn't match the declared `ValueType` (or the kind's
    ///     `Underlying`).
    ///   * `vector_length_mismatch` — typed-vector slot's `:len` not met.
    ///   * `unit_required` — bare `Tag.number` where `UnitShape.required`
    ///     is true.
    ///   * `unit_not_allowed` — `number_with_unit` whose suffix is not in
    ///     `UnitShape.allowed`.
    ///   * `not_member` — symbol/string value not in the kind's
    ///     `MemberSet.members`.
    ///   * `deprecated_member` — symbol/string value matched a member
    ///     of the kind's `MemberSet` whose `deprecated` flag is `true`.
    ///     Severity is `.warning`, not `.err` — validation still
    ///     succeeds. Diagnostic prose carries the member's
    ///     `:deprecation-message` when one is set, otherwise generic
    ///     "is deprecated".
    ///   * `not_head_member` — form value's head not in the kind's
    ///     `HeadSet.names`.
    ///   * `union_no_branch_matched` — value matched no alternative of a
    ///     `union_of` value-kind. Diagnostic lists the alternatives plus
    ///     the actual node tag.
    ///   * `nested_union` — a `union_of` alternative resolves to another
    ///     `union_of` kind (schema-aggregate-time; nesting is forbidden
    ///     so dispatch stays a flat loop).
    ///
    /// **Expression** — expression-vocabulary rules.
    ///   * `arity_mismatch` — wrong number of positional arguments to
    ///     an expression head.
    ///   * `expr_type_mismatch` — typed expression argument failed its
    ///     `params`/`rest` constraint (typed-signature funcs only;
    ///     opaque heads stay untyped), **or** an evaluated argument
    ///     value fell outside the function's domain at eval time: an
    ///     inverted `clamp`/`rand-range` range, an out-of-range `nth`
    ///     index, a zero-length `normalize`, a division by zero. The
    ///     static half is anchored at the offending argument and carries
    ///     its path; the runtime half is anchored at the form's head
    ///     with an empty path, because there is no declared slot to
    ///     name — the declared types are exactly what checked out. The
    ///     two never both fire for one form (`Host.runEvalPass` reports
    ///     only when the stream carries no error inside that form).
    ///
    /// **Manifest load (D0)** — host loader pre-pass diagnostics.
    ///   * `invalid_manifest` — meta-schema validation rejected a
    ///     `(plugin …)` declaration in the document or a referenced
    ///     manifest file. Emitted at the declaration site by the host
    ///     (D1 wires the emission path).
    ///
    /// **Plugin resolution (D0)** — `(use-plugin …)` reference outcomes.
    ///   * `unresolved_plugin` — the resolver returned no manifest /
    ///     WASM bytes for the reference (file missing, network failure,
    ///     unknown plugin name). Emitted at the reference site.
    ///   * `plugin_version_mismatch` — resolver returned bytes whose
    ///     declared version does not satisfy the reference's `:version`
    ///     constraint. Emitted at the reference site.
    ///   * `plugin_hash_mismatch` — resolver returned bytes whose
    ///     content hash does not match the reference's `:hash` pin.
    ///     Emitted at the reference site.
    ///
    /// **Project resolution (D3)** — `sjon-project.sjon` and named-lookup
    /// outcomes that sit one level above the resolver contract.
    ///   * `duplicate_plugin_name` — two `:plugins` entries in the project
    ///     file resolve to manifests carrying the same `:name`. Emitted at
    ///     the second entry's path-string span; the host refuses last-wins
    ///     so consumers can't accidentally shadow a plugin.
    ///   * `plugin_name_mismatch` — `(use-plugin "X" :path "...")` resolved
    ///     to a manifest whose `:name` is not `X`. Emitted at the reference
    ///     site; the loaded plugin is discarded so it can't sneak into the
    ///     schema under the wrong name.
    ///   * `project_file_not_found` — the host was given an explicit
    ///     project root (`--project-root DIR`) but `DIR/sjon-project.sjon`
    ///     is missing. Synthetic diagnostic with no source span.
    ///
    /// **Plugin runtime (D7)** — executable-plugin ABI outcomes. See
    /// `docs/executable-plugin-abi.md` §17 for the full table.
    ///   * `plugin_abi_mismatch` — plugin's `sjon_plugin_abi_version()`
    ///     export returned a version the host does not implement.
    ///     Emitted at the plugin reference at load time.
    ///   * `plugin_export_missing` — manifest declares `:impl
    ///     "wasm:<name>"` but the paired binary has no export `<name>`.
    ///     Emitted at the `:impl` reference at load time.
    ///   * `plugin_import_forbidden` — plugin binary declares an import
    ///     outside the v1 allowlist (which is empty). Emitted at the
    ///     plugin reference at load time.
    ///   * `plugin_wasm_required` — manifest references `wasm:*` impls
    ///     but the resolver returned `wasm = null`. Emitted at the
    ///     `:impl` reference at load time.
    ///   * `plugin_describe_invalid` — reserved for the v2 self-
    ///     describing path; declared in v1 for forward compatibility.
    ///   * `plugin_func_trapped` — runtime trap during dispatch
    ///     (unreachable, OOB, divide-by-zero). Emitted at the
    ///     `(expr ...)` call's span.
    ///   * `plugin_func_result_type` — returned value's type does not
    ///     match the manifest's declared `:result`. Emitted at the
    ///     `(expr ...)` call's span.
    ///   * `plugin_func_failed` — plugin returned an `ok=0` frame with
    ///     a structured `(code, detail)` error. Emitted at the
    ///     `(expr ...)` call's span.
    ///   * `plugin_func_alloc_failed` — the plugin's
    ///     `sjon_plugin_alloc(args_len)` returned `0`. Emitted at the
    ///     `(expr ...)` call's span.
    ///
    /// **Default materialization** — runtime failure to materialize a
    /// `KeySpec.default` (literal or expression) for an omitted key on
    /// a known data form.
    ///   * `default_eval_failed` — expression default failed to evaluate
    ///     (unknown/unimplemented function at runtime, unbound symbol,
    ///     division by zero, plugin runtime failure, or a malformed
    ///     retained program). Emitted at the omitted key's owning form
    ///     head with path `[<form-head> <key-name> default]`.
    ///
    /// **Lowering runtime** — host-owned form-lowering contract failures.
    /// See `docs/plugin-model-v1.md` and `src/Lowering.zig`.
    /// All codes stamp `phase = .lowering`; the re-validation pass on the
    /// lowered tree stamps `phase = .validation` with existing codes.
    ///   * `lowering_hook_missing` — `FormSpec.lowering.hook` names a
    ///     contract id with no entry in the host's `LoweringRegistry`.
    ///     Path: `[<source-head>, lowering]`.
    ///   * `lowering_hook_failed` — registered hook returned `HookFailed`.
    ///     Path: `[<source-head>, lowering]`.
    ///   * `lowering_produced_invalid_head` — hook emitted a form whose
    ///     head is not in `lowering_spec.produces`. Path:
    ///     `[<emitted-head>, lowering, produces]`.
    ///   * `lowering_produced_lowerable_head` — hook emitted a form
    ///     whose own `FormSpec.lowering` is non-null (single-pass v1
    ///     does not chain). Path: `[<emitted-head>, lowering]`.
    ///   * `lowering_output_too_large` — emitted forest exceeds
    ///     `MAX_LOWERED_FORMS` / `MAX_LOWERED_DEPTH` / `MAX_LOWERED_BYTES`.
    ///     Path: `[<source-head>, lowering]`.
    pub const Code = enum {
        unspecified,

        // Resolution
        unknown_form,
        unknown_key,
        ambiguous_form,
        ambiguous_expr,
        ambiguous_element_kind,
        unknown_element_kind,
        recursion_depth,
        not_cross_ref,
        duplicate_cross_ref_target,
        unknown_cross_ref_target,
        ambiguous_cross_ref_target,
        cross_ref_name_key_unknown,
        acyclic_without_self_edge,
        cyclic_cross_ref,
        unknown_cross_ref_scope,
        ambiguous_cross_ref_scope,
        cross_ref_outside_scope,

        // Form-shape rules
        duplicate_key,
        too_many_keys,
        missing_required_key,
        positional_not_allowed,
        expr_kvpair_not_allowed,
        missing_discriminant_key,
        unknown_discriminant_value,
        discriminant_not_closed_enum,
        variant_key_collision,
        mutually_exclusive_keys_present,
        multiple_defaulted_alternatives_in_group,
        required_one_of_missing,
        exclusive_group_invalid,

        // Type-level
        wrong_underlying,
        vector_length_mismatch,
        unit_required,
        unit_not_allowed,
        not_member,
        deprecated_member,
        not_head_member,
        union_no_branch_matched,
        nested_union,

        // Expression
        arity_mismatch,
        expr_type_mismatch,
        // Labeled expression args (Swift-style opt-in).
        //   * `expr_unknown_label` — kvpair label is not declared by the
        //     function's `param_names`.
        //   * `expr_duplicate_label` — same label given twice in one call.
        //   * `expr_missing_label` — labeled call omitted a declared name.
        //   * `expr_mixed_args` — positional and labeled args in the same
        //     call (strict mixing rule: a call is all-positional or
        //     all-labeled).
        // `expr_kvpair_not_allowed` (above) now means specifically
        // "this function has not opted into labels".
        expr_unknown_label,
        expr_duplicate_label,
        expr_missing_label,
        expr_mixed_args,

        // Manifest load (D0)
        invalid_manifest,

        // Plugin resolution (D0)
        unresolved_plugin,
        plugin_version_mismatch,
        plugin_hash_mismatch,

        // Project resolution (D3)
        duplicate_plugin_name,
        plugin_name_mismatch,
        project_file_not_found,

        // Plugin runtime (D7)
        plugin_abi_mismatch,
        plugin_export_missing,
        plugin_import_forbidden,
        plugin_wasm_required,
        plugin_describe_invalid,
        plugin_func_trapped,
        plugin_func_result_type,
        plugin_func_failed,
        plugin_func_alloc_failed,

        // Default materialization
        default_eval_failed,

        // Lowering runtime (D8-lowering-runtime v1)
        lowering_hook_missing,
        lowering_hook_failed,
        lowering_produced_invalid_head,
        lowering_produced_lowerable_head,
        lowering_output_too_large,

        // Numeric literals (exact-integer path)
        // Emitted by the parser when a pure-integer lexeme overflows u64
        // (≥ 2^64). The tree falls back to f64 storage so the value is
        // still readable, but exact round-trip is no longer guaranteed.
        number_overflow_exact_integer,

        // Date-literal component validation (parser-emitted)
        //   * `date_invalid_year` — year is `0000` (ISO 8601 disallows
        //     year 0; the lexer accepts the lexeme, the parser rejects
        //     the value). v1 also has no extended-year form, so any
        //     out-of-range year reaches this code via the year_zero
        //     path.
        //   * `date_invalid_month` — month outside `[1, 12]`.
        //   * `date_invalid_day` — day outside `[1, daysInMonth(year,
        //     month)]`, including the leap-year February 29 case.
        // The tree still emits a `Tag.date` node (defaulted to
        // `0001-01-01`) so downstream walks remain well-formed —
        // diagnostics are the contract, not aborts.
        date_invalid_year,
        date_invalid_month,
        date_invalid_day,

        // Time-literal component validation (parser-emitted)
        //   * `time_invalid_hour` — hour outside `[0, 23]` (so `24:00:00`
        //     is rejected; some older ISO 8601 profiles allow it as an
        //     "end of day" form, but the substrate keeps the invariant
        //     simple).
        //   * `time_invalid_minute` — minute outside `[0, 59]`.
        //   * `time_invalid_second` — second outside `[0, 59]`. No leap
        //     seconds — the substrate has no UTC concept and matches the
        //     `LocalTime` semantics of every standard library that
        //     doesn't model UTC explicitly.
        // The tree still emits a `Tag.time` node (defaulted to
        // `00:00:00.000`) so downstream walks remain well-formed —
        // diagnostics are the contract, not aborts. Millisecond range
        // is enforced by the lexer (exactly 3 digits ⇒ 0..999 by
        // construction), so no `time_invalid_millisecond` code exists.
        time_invalid_hour,
        time_invalid_minute,
        time_invalid_second,

        // Numeric bounds (value-kind `:numeric` refinement)
        //   * `number_below_min` — value strictly less than inclusive `:min`.
        //   * `number_above_max` — value strictly greater than inclusive `:max`.
        //   * `number_at_or_below_exclusive_min` — value ≤ `:min` when
        //     `:exclusive-min true`.
        //   * `number_at_or_above_exclusive_max` — value ≥ `:max` when
        //     `:exclusive-max true`.
        //   * `number_not_integer` — `:integer true` set and value is a
        //     fractional or non-finite (NaN / ±inf) float.
        //   * `numeric_bound_unit_mismatch` — bound carries a unit but the
        //     validated value has none, or carries a different unit.
        //   * `numeric_bounds_invalid` — loader-emitted when a
        //     `(numeric-bounds …)` form is internally inconsistent
        //     (e.g. `:exclusive-min` without `:min`, `:min > :max`, or
        //     attached to a kind whose `:underlying` is not `number`).
        number_below_min,
        number_above_max,
        number_at_or_below_exclusive_min,
        number_at_or_above_exclusive_max,
        number_not_integer,
        numeric_bound_unit_mismatch,
        numeric_bounds_invalid,

        // String bounds (value-kind `:string-bounds` refinement)
        //   * `string_too_short` — UTF-8 codepoint count below inclusive `:min-len`.
        //   * `string_too_long`  — UTF-8 codepoint count above inclusive `:max-len`.
        //   * `string_format_mismatch` — value doesn't satisfy declared `:format`
        //     (one of email / uri / path / uuid / semver).
        //   * `string_pattern_mismatch` — value doesn't match `:pattern`.
        //     Reserved for the regex-engine milestone; v1 builds never emit it.
        //   * `string_pattern_unsupported` — `:pattern` was declared but the
        //     running build has no regex engine. Warning, emitted at most
        //     once per kind per validation pass at the offending value's span.
        //   * `string_bounds_invalid` — loader-emitted when a
        //     `(string-bounds …)` form is internally inconsistent (empty
        //     range, negative bound, attached to a non-`string` underlying,
        //     empty `:pattern`, or a `(member-set …)` literal that itself
        //     fails the declared `:min-len` / `:max-len` / `:format`).
        string_too_short,
        string_too_long,
        string_format_mismatch,
        string_pattern_mismatch,
        string_pattern_unsupported,
        string_bounds_invalid,

        // Exclusive-group multi-key alternatives (`(alt :keys [a b])`).
        //   * `exclusive_bundle_partial` — validate-time: a multi-key
        //     bundle is partially present (some keys set, others
        //     missing) and no sibling alt is fully author-present to
        //     win the group. Bundles are all-or-nothing.
        //   * `exclusive_bundle_collision` — manifest-time: one key
        //     name appears in two alternatives of the **same**
        //     exclusive-group. The cross-group case still emits
        //     `exclusive_group_invalid`.
        exclusive_bundle_partial,
        exclusive_bundle_collision,

        // Manifest v1.1 metadata fields (Slice 2 of the local-packaging
        // plan). All append-only — wire-stable enum.
        //   * `plugin_wasm_resolved_outside_package` — manifest's
        //     `:wasm-file` path resolves outside its containing directory
        //     after normalization. Loudest, most security-relevant of the
        //     new codes (path-traversal blocker).
        //   * `plugin_wasm_self_hash_malformed` — `:wasm-sha256` is not
        //     `sha256-<64 lowercase hex>`. Authoring-time wire check.
        //   * `plugin_wasm_self_hash_mismatch` — author's `:wasm-sha256`
        //     stamp differs from the bytes on disk. Distinct from
        //     `plugin_hash_mismatch`, which is the consumer's pin.
        //   * `license_unrecognized` (advisory) — `:license` is not a
        //     canonical SPDX identifier.
        //   * `too_many_keywords` (advisory) — `:keywords` exceeds 16
        //     entries.
        //   * `sjon_format_unsupported` — manifest declares a `:sjon`
        //     version newer than this host implements. Errors loudly
        //     rather than silently falling back to v1.0 semantics.
        plugin_wasm_resolved_outside_package,
        plugin_wasm_self_hash_malformed,
        plugin_wasm_self_hash_mismatch,
        license_unrecognized,
        too_many_keywords,
        sjon_format_unsupported,

        // Project file v1.1 (Slice 3 of the local-packaging plan).
        //   * `unknown_project_key` (advisory) — the project file
        //     declares a top-level key the host doesn't recognize. Lets
        //     newer manifests work against older hosts without hard
        //     failure.
        //   * `glob_no_matches` (advisory) — a `:documents` pattern
        //     matched zero files. Almost always indicates a typo.
        //   * `pin_disagreement` — a project-level pin
        //     (`(plugin-entry …)` `:version`/`:hash`) disagrees with the
        //     value on a corresponding `(use-plugin … :version/:hash)`
        //     reference. Both sources cited via secondary spans.
        //   * `project_documents_outside_root` — a `:documents` glob
        //     resolves to paths outside the project root. Treated the
        //     same as `:wasm-file` package-escape: refused on lexical
        //     normalization, not realpath.
        unknown_project_key,
        glob_no_matches,
        pin_disagreement,
        project_documents_outside_root,

        // Lockfile diagnostics (Slice 12 of the local-packaging plan).
        //   * `lockfile_drift` — recorded hash disagrees with the
        //     on-disk bytes. Run `sjon project lock` to update or
        //     revert the offending plugin.
        //   * `lockfile_missing_entry` — project references a plugin
        //     that the lockfile does not record.
        //   * `lockfile_orphan` (advisory) — lockfile entry whose
        //     plugin is no longer referenced. Harmless but stale.
        //   * `lockfile_version_unsupported` — lockfile's `:version`
        //     exceeds this host's understanding.
        //   * `lockfile_corrupt` — parse or shape failure during
        //     lockfile load.
        lockfile_drift,
        lockfile_missing_entry,
        lockfile_orphan,
        lockfile_version_unsupported,
        lockfile_corrupt,
        /// A positional keyword flag is not in the form's declared
        /// `:positional (flag-set …)` set. Wire-stable: appended last.
        not_flag_member,
        /// A form's `:lowering :produces` graph contains a cycle: following
        /// produces-edges from a lowering form leads back to itself.
        /// Emitted by `Schema.validateLowering` at schema-aggregate time
        /// (before any hook runs), so staged lowering is guaranteed to
        /// terminate. Path: `[<plugin>, <form>, lowering]`. Wire-stable:
        /// appended last.
        lowering_cycle,
        /// A form's `:lowering :produces` lists a *qualified* head
        /// (`<plugin>/<form>`) whose plugin is not present in the loaded
        /// aggregate. Distinct from `unknown_form` (a bare or same-plugin
        /// head that resolves to no declared form): here the namespace was
        /// spelled explicitly but that plugin was never loaded, so the
        /// edge dangles on load order rather than on a typo. Emitted by
        /// `Schema.validateLowering` at schema-aggregate time. Path:
        /// `[<plugin>, <form>, lowering]`. Wire-stable: appended last.
        lowering_target_plugin_absent,
        /// A document repeats a declared positional keyword flag on one
        /// form, e.g. `(task :done :done)`. Distinct from `not_flag_member`
        /// (the flag is undeclared) and from the loader's `invalid_manifest`
        /// for a duplicate `(flag …)` *declaration*: here the flag is valid
        /// but written more than once on a single form instance. Emitted by
        /// the validator (tree + binary) on the second and later
        /// occurrences. Wire-stable: appended last.
        duplicate_positional_flag,
        /// A form that declares `:lowering` appears as a *positional child* of
        /// another form that also declares `:lowering`. Both hooks fire in the
        /// same lowering layer — the container consumes the child as data while
        /// the child lowers itself — producing overlapping / orphaned output
        /// (the confusing `duplicate_cross_ref_target` cascade this pre-empts).
        /// Container lowering wants the children to stay plain data: put
        /// `:lowering` on the container OR the child, never both. Emitted by
        /// the lowering pass (`runLoweringPass`) at runtime, not at schema
        /// load — the container→child positional relationship is a property of
        /// the *document*, invisible behind an `:open true` container when the
        /// produces-graph cycle check runs. Path: `[<child-head>, lowering]`.
        /// Wire-stable: appended last.
        lowering_nested_lowerable,
        /// A `Tag.number_with_unit` value landed in a slot whose value-kind
        /// declares `:unit (unit-shape :reject true)` — the slot demands bare
        /// numbers only. Distinct from `unit_not_allowed` (a unit outside a
        /// non-empty `:allowed` list): here *every* unit is rejected, so the
        /// message names no allowed set. Closes the silent `1.0f → 0` GPU
        /// backfill. Emitted by the validator (tree + binary). Wire-stable:
        /// appended last.
        unit_forbidden,
        /// A vector value has fewer elements than its value-kind's
        /// `:vector (vector-shape :min-len N …)`. Distinct from
        /// `vector_length_mismatch` (a fixed `:len`): this is the
        /// variable-arity floor. Emitted by the validator (tree + binary).
        /// Wire-stable: appended last.
        vector_too_short,
        /// A vector value has more elements than its value-kind's
        /// `:vector (vector-shape :max-len N …)` — the variable-arity
        /// ceiling. Emitted by the validator (tree + binary). Wire-stable:
        /// appended last.
        vector_too_long,
        /// Loader-emitted when a `(vector-shape …)` form is internally
        /// inconsistent: `:min-len > :max-len`, or `:len` combined with
        /// `:min-len`/`:max-len` (a fixed length already subsumes a range).
        /// Wire-stable: appended last.
        vector_bounds_invalid,
        /// A `.number` value doesn't fit its value-kind's `:repr` GPU
        /// representation type — either out of the type's range (e.g.
        /// `70000` under `:repr u16`) or non-integral under an integer
        /// type (e.g. `1.5` under `:repr u32`). The message disambiguates
        /// the two. Emitted by the validator (tree + binary). Wire-stable:
        /// appended last.
        repr_out_of_range,
        /// A form value in a slot carrying slot-local form definitions has a
        /// head that matches neither a local form nor — after the additive
        /// fallback — any global form via `Schema.lookupForm`. The carrier is
        /// either a keyed slot (`KeySpec.local_forms`) or a form's positional
        /// slot (`FormSpec.local_forms`); resolution is identical. Distinct
        /// from `unknown_form` (no slot-local context): here the resolver had a
        /// local registry and the head missed it *and* the global catalog, so
        /// the message names the allowed local heads. Emitted at the slot path
        /// — the key path for a keyed slot (e.g. `[canvas shape]`) or the
        /// parent form's path for a positional slot (e.g. `[canvas]`), not the
        /// missing head — by the validator (tree + binary); the generic
        /// `unknown_form` is suppressed for that node. Wire-stable: appended
        /// last.
        unknown_local_form,
        /// A pattern time-scaling combinator (`fast` / `slow`) expanded the
        /// query window past the `Pattern.MAX_TICK` (2^53) ceiling, so the
        /// scaled span cannot be represented exactly on the integer tick
        /// grid. Emitted by `PatternQuery` (the query walker, not the
        /// validator) at the offending combinator; that subtree contributes
        /// no haps while the rest of the query proceeds (collection over
        /// abort). Path: `[fast]` / `[slow]`. Wire-stable: appended last.
        pattern_tick_overflow,
        /// A pattern `(pure …)` leaf whose value is an `Expr` expression
        /// failed to evaluate at the compile-time dry-run (cycle 0, seed 0):
        /// an unbound name, division by zero, an arity error, or a resource
        /// budget. Emitted by `PatternQuery.compileTree` (tree path only —
        /// the binary path has no tree to evaluate); the leaf then degrades
        /// to `silence`. A *later-cycle* failure is instead a silent counted
        /// drop (a domain hole, not a document defect), so this code marks
        /// only statically-broken expressions. Path: `[pure]`. Wire-stable:
        /// appended last.
        pattern_value_eval_failed,
        /// A pattern `(pure …)` expression leaf evaluated at the dry-run but
        /// produced a value no hap can carry: a form (the usual cause is a
        /// misspelled function name — an unresolved head evaluates to a form
        /// literal, not an error), a vector, a date, or a time. Emitted by
        /// `PatternQuery.compileTree`; the leaf degrades to `silence`. Path:
        /// `[pure]`. Wire-stable: appended last.
        pattern_value_result_invalid,
        /// A `(cross-ref :provider p …)` names a provider no plugin in the
        /// aggregated schema declares. The provider-route twin of
        /// `unknown_cross_ref_target`, and like it a schema-aggregate-time
        /// diagnostic: span `{0,0}`, path `[<plugin>, <kind>, cross-ref]`.
        /// Wire-stable: appended last.
        unknown_cross_ref_provider,
        /// A bare `(cross-ref :provider p …)` resolves to ≥ 2 plugins'
        /// providers. The provider-route twin of
        /// `ambiguous_cross_ref_target`, same "qualify with
        /// `<plugin>/<name>`" remedy (schema-aggregate-time).
        /// Wire-stable: appended last.
        ambiguous_cross_ref_provider,
        /// A provider-route `(cross-ref … :source-key k)` names a key that
        /// the resolved `:target` form does not declare, or whose declared
        /// type is not string-shaped — so no instance could ever hand the
        /// provider anything. The provider-route twin of
        /// `cross_ref_name_key_unknown` (schema-aggregate-time).
        /// Wire-stable: appended last.
        cross_ref_source_key_unknown,
        /// A provider-route cross-ref's extractor ran against a source
        /// instance and reported failure (a parse error in the extracted
        /// content, typically). Validate-time, emitted once at the source
        /// value's span while building the cross-ref index; the bucket is
        /// then *poisoned*, so no `not_cross_ref` cascades against a member
        /// set nobody could compute. Path: empty, the index-pass convention
        /// its two neighbours (`duplicate_cross_ref_target`,
        /// `cyclic_cross_ref`) already follow. Wire-stable: appended last.
        cross_ref_extraction_failed,
        /// A provider-route cross-ref needed an extraction the host did not
        /// supply: the plugin was loaded without an executable runtime, the
        /// declared export is missing, or the build has plugin execution
        /// compiled out. Distinct from `cross_ref_extraction_failed` — the
        /// provider never ran, as opposed to running and rejecting its
        /// input — because the remedies are unrelated (fix the host wiring
        /// vs. fix the document's content). Same span, path, and poisoning
        /// behaviour. Wire-stable: appended last.
        cross_ref_provider_unavailable,
        /// Two value-kinds declare a `(cross-ref …)` on the *same* resolved
        /// target form, but disagree about how that target's member set is
        /// built — a different route (`:name-key` vs `:provider`), a
        /// different key, a different provider, or a different `:scope`.
        /// The registry is built once per target and first-wins by plugin ×
        /// value-kind order, so the loser's references are then checked
        /// against a set the *winner's* spec produced. Severity `.warning`:
        /// the schema still loads and every reference is still checked,
        /// just not the way the loser declared. Two kinds sharing a target
        /// with an *identical* spec are silent — that is a normal aliasing
        /// idiom, and both agree on the answer.
        ///
        /// Not `duplicate_cross_ref_target`, which is validate-time and
        /// about two *document instances* claiming one name; this one is
        /// schema-aggregate-time and about two *declarations* claiming one
        /// target. Span `{0,0}`, path `[<plugin>, <kind>, cross-ref]` on
        /// the losing kind. Wire-stable: appended last.
        cross_ref_target_collapse,
        /// A `:numeric (numeric-bounds … :multiple-of N)` value that is not
        /// an exact multiple of `N` — the alignment constraint (offsets of
        /// 4 or 256, sizes of 4) that a range and an integrality flag
        /// together cannot express.
        ///
        /// Checked *after* `:integer` and after the range bounds, so
        /// `250.5` under `:integer true :multiple-of 4` reads as "not an
        /// integer" and `-4` under `:min 0 :multiple-of 4` reads as "below
        /// minimum" — in both cases the more basic violation is the one
        /// worth reporting. Emitted by both walkers through the shared
        /// `checkNumericBoundsValue`.
        ///
        /// Divisibility is decided in **exact integer space** whenever the
        /// value and the divisor are both integral, so a `u64`/`i64` above
        /// 2^53 answers correctly where an f64 remainder would not. A
        /// fractional divisor falls back to an f64 remainder against a
        /// relative epsilon, and the loader warns at the declaration —
        /// binary floating point has no exact answer there, and every
        /// alignment rule uses an integer divisor anyway. Wire-stable:
        /// appended last.
        number_not_multiple,
        /// A key carrying `(key … :requires [b c])` is present, but one or
        /// more of the keys it names is absent. The message lists every
        /// absent requirement, so a key with three unmet dependencies
        /// produces one diagnostic naming three, not three diagnostics.
        ///
        /// The third inter-key mechanism, and the only one about
        /// *presence implying presence*: `exclusive-group` bounds how many
        /// of a set may appear, `(variant …)` gates keys on the
        /// discriminant's **value**, and this gates one key's requirement
        /// on another key's presence. One-directional — an absent
        /// dependent key constrains nothing.
        ///
        /// Emitted at the form's head span with the form's path, matching
        /// the other end-of-form sweeps, by both walkers. Presence follows
        /// the same rule exclusive groups use: author-written on the
        /// binary path, and author-written *or* overlay-defaulted on the
        /// tree path when axis C is on. Suppressed by `:open true`, like
        /// every other closed-form shape rule. Wire-stable: appended last.
        dependent_key_missing,
        /// Severity `.warning`. A symbol in a `:underlying union` slot is a
        /// registered name in **two or more** of the union's cross-ref-backed
        /// alternatives, so which entity the slot denotes is decided by the
        /// order the alternatives were declared in.
        ///
        /// The union's semantics are unchanged and the document still
        /// validates: first match still wins, and the winner is still the
        /// earliest accepting alternative. What this reports is that a second
        /// reading exists — duplicate-name detection is per-target, so two
        /// forms of *different* kinds may each define `same` without either
        /// bucket seeing a collision. A host that resolves the reference by
        /// its own table rather than by alternative order will disagree with
        /// the validator, silently. That is the defect; the repair is to
        /// rename one declaration or split the slot.
        ///
        /// Deliberately narrow. Gated on **cross-ref-backed** alternatives
        /// because a union whose halves overlap on plain values (the
        /// `scalar-or-ref-shape` desugar is exactly that) is *designed* for
        /// first-match, and flagging every overlap would bury the signal.
        /// Only when both readings pick out different *named entities in the
        /// document* is the order load-bearing in a way the author did not
        /// choose. Silent when the winning alternative is not itself
        /// cross-ref-backed — the slot then denotes no entity at all — and
        /// silent for a poisoned bucket, whose members nobody could compute
        /// and which therefore has no declaration to point at.
        ///
        /// Emitted at the value's span by both walkers, as one of the
        /// post-match advisories. Wire-stable: appended last.
        union_ambiguous,
        /// A form carries more positional children of one head than its
        /// `:positional` head-set allows: `(head :name fragment :max 1)`
        /// met a second `(fragment …)`.
        ///
        /// Emitted at the **offending child** — the one that crosses the
        /// ceiling — with that child's positional path step, not at the
        /// parent. That is what makes it actionable in an editor (the
        /// squiggle is on the line to delete), and it is what the
        /// single-pass binary walker can do without rewinding: the count
        /// crosses `max` exactly once, mid-stream. Exactly one diagnostic
        /// per form no matter how far over the ceiling the author went;
        /// the crossing child names the real count so the message stays
        /// honest.
        ///
        /// Unaffected by `:open`. A form that declares
        /// `:positional <bounded-kind>` has opted into the count; `:open`
        /// widens the *keyword* surface, and its sibling positional rules
        /// — `not_head_member`, `duplicate_positional_flag` — already fire
        /// on open forms for the same reason. Wire-stable: appended last.
        positional_too_many,
        /// A form carries fewer positional children of one head than its
        /// `:positional` head-set requires: `(head :name vertex :min 1)`
        /// saw none.
        ///
        /// Inherently an end-of-children fact, so it lands at the parent
        /// form's head span with the parent's path — the same place
        /// `missing_required_key` lands, and for the same reason: there is
        /// no child to point at. One diagnostic per unsatisfied head, each
        /// naming the head, the floor, and the count actually found.
        ///
        /// Unaffected by `:open`, per `positional_too_many` above. This is
        /// the one end-of-form sweep that is not about keywords, which is
        /// why it runs before the `open` short-circuit that suppresses all
        /// the others. Wire-stable: appended last.
        positional_missing,
    };

    /// Deep-copy this diagnostic into `a`: `message` and every `path`
    /// element are duplicated, so the returned diagnostic shares no memory
    /// with `self` and stays valid after the source arena is freed. `span`,
    /// `severity`, and `code` are plain values, copied verbatim. Use when a
    /// diagnostic must migrate between arenas — e.g. `Edit.applyEditToTree`
    /// rebuilding a self-contained tree from a borrowed source tree, so the
    /// edited tree's diagnostics no longer alias the source arena.
    ///
    /// `a` is expected to be arena-backed (as everywhere in this codebase):
    /// a mid-copy allocation failure leaves partial allocations that the
    /// caller's arena reclaims on `deinit`. O(message.len + Σ|path[i]|).
    pub fn dupe(self: Diagnostic, a: Allocator) Allocator.Error!Diagnostic {
        return .{
            .span = self.span,
            .message = try a.dupe(u8, self.message),
            .severity = self.severity,
            .code = self.code,
            .path = try dupePath(a, self.path),
        };
    }

    /// Everything but the text of a `gpa`-owned diagnostic, for
    /// `appendOwned` below. Split out so the call sites read as prose
    /// (`.{ .code = …, .span = …, .path_parts = … }`) instead of a
    /// six-positional-argument call.
    pub const Owned = struct {
        code: Code,
        span: Span,
        severity: Severity = .err,
        /// Borrowed for the duration of the call — `appendOwned` dupes
        /// each part into `gpa`, so these may point at tree-owned bytes.
        path_parts: []const []const u8 = &.{},
    };

    /// Format `fmt`/`args` into a `gpa`-owned message, dupe `path_parts`
    /// into a `gpa`-owned path, and append the result to `diags`.
    ///
    /// This is the **second** memory tier (see `root.zig`'s header): most
    /// of the codebase hands back arena-owned results whose `deinit` is
    /// self-contained, but the aggregate validators are called by a host
    /// that copies their diagnostics into *its* arena and then drops
    /// them, so theirs are individually owned and individually freed —
    /// `freeOwnedSlice` is the matching release.
    ///
    /// Leak-safe under partial OOM: the message, the path array, and each
    /// duped part are released if any later allocation fails. On success
    /// nothing runs and ownership transfers to `diags`. Getting that
    /// sequence right at each of the (previously two, hand-written) emit
    /// sites was the reason to have one of these.
    pub fn appendOwned(
        gpa: Allocator,
        diags: *std.ArrayList(Diagnostic),
        proto: Owned,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!void {
        const message = try std.fmt.allocPrint(gpa, fmt, args);
        errdefer gpa.free(message);

        const path = try gpa.alloc([]const u8, proto.path_parts.len);
        var filled: usize = 0;
        errdefer {
            for (path[0..filled]) |p| gpa.free(p);
            gpa.free(path);
        }
        for (proto.path_parts, 0..) |p, i| {
            path[i] = try gpa.dupe(u8, p);
            filled = i + 1;
        }

        try diags.append(gpa, .{
            .span = proto.span,
            .message = message,
            .severity = proto.severity,
            .code = proto.code,
            .path = path,
        });
    }

    /// Release what `appendOwned` allocated for each diagnostic — the
    /// message, every path part, and the path array — leaving the
    /// container alone. This is the shape an `errdefer` needs, where the
    /// `ArrayList`'s own `deinit` still has to run afterwards.
    pub fn freeOwnedContents(gpa: Allocator, diags: []const Diagnostic) void {
        for (diags) |d| {
            gpa.free(d.message);
            for (d.path) |p| gpa.free(p);
            gpa.free(d.path);
        }
    }

    /// `freeOwnedContents` plus the backing slice — the shape a
    /// `Result.deinit` needs, once the list has been finalized with
    /// `toOwnedSlice`.
    pub fn freeOwnedSlice(gpa: Allocator, diags: []const Diagnostic) void {
        freeOwnedContents(gpa, diags);
        gpa.free(diags);
    }
};

/// Deep-copy a diagnostic path — the outer slice and every element string
/// are duplicated into `a`, so the result shares no memory with `steps`.
/// Single owner of the path-dupe idiom used by `Diagnostic.dupe` and by every
/// resolver/loader that builds a hierarchical diagnostic path (`&.{step}` for
/// the common single-step case). `a` is expected arena-backed. O(Σ|steps[i]|).
pub fn dupePath(a: Allocator, steps: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, steps.len);
    for (steps, out) |step, *o| o.* = try a.dupe(u8, step);
    return out;
}

// ===========================================================================
// SoA AST.
//
// Layout:
//   * Each `Node` is 17 bytes packed into 3 SoA arrays via `MultiArrayList`.
//   * Form / kvpair payloads (Tag.form, Tag.kvpair) spill into `extra_data: []u32`.
//   * String content is concatenated into `strings`, ranged via
//     `string_index[i]..string_index[i+1]`.
//   * Comments live in a parallel SoA `comments` list, keyed by
//     `leading_comments_index[node]` and `trailing_comments_index[node]`.
// ===========================================================================

/// Index into `Tree.nodes`. The `invalid` sentinel marks "no such node".
/// All other values are stored as the underlying `u32`.
pub const NodeIndex = enum(u32) {
    invalid = std.math.maxInt(u32),
    _,

    pub inline fn from(i: u32) NodeIndex {
        std.debug.assert(i != std.math.maxInt(u32));
        return @enumFromInt(i);
    }
    pub inline fn raw(self: NodeIndex) u32 {
        return @intFromEnum(self);
    }
    pub inline fn isValid(self: NodeIndex) bool {
        return self != .invalid;
    }
};

/// Index into `Tree.string_index`. `invalid` marks "no string here".
pub const StringIndex = enum(u32) {
    invalid = std.math.maxInt(u32),
    _,

    pub inline fn from(i: u32) StringIndex {
        std.debug.assert(i != std.math.maxInt(u32));
        return @enumFromInt(i);
    }
    pub inline fn raw(self: StringIndex) u32 {
        return @intFromEnum(self);
    }
    pub inline fn isValid(self: StringIndex) bool {
        return self != .invalid;
    }
};

/// Index into `Tree.extra_data`. The exact layout at the target depends
/// on the owning node's `Tag` — see Tag's per-variant comment.
pub const ExtraIndex = enum(u32) {
    invalid = std.math.maxInt(u32),
    _,

    pub inline fn from(i: u32) ExtraIndex {
        std.debug.assert(i != std.math.maxInt(u32));
        return @enumFromInt(i);
    }
    pub inline fn raw(self: ExtraIndex) u32 {
        return @intFromEnum(self);
    }
};

/// Output-shape selector shared by every encoder (Printer, Json, Binary,
/// Edit). Each module documents which variants are meaningful and how the
/// others alias.
///
/// |           | canonical                       | compact                    | full                            |
/// |-----------|---------------------------------|----------------------------|---------------------------------|
/// | Printer   | drops comments (deterministic)  | ≡ canonical (no smaller)   | preserves comments              |
/// | Json      | tagged shapes (round-trippable) | bare strings (one-way)     | ≡ canonical (no extra trivia)   |
/// | Binary    | spans on, comments off          | no spans / no comments     | all spans / all comments        |
/// | Edit      | drops comments                  | ≡ canonical                | preserves comments (default)    |
pub const Mode = enum {
    /// Deterministic, round-trippable, stable across runs and platforms.
    /// The default for every encoder. For modules whose only round-
    /// trippable shape is also their largest, `canonical == full`.
    canonical,
    /// Smaller than canonical. Drops information not needed for the
    /// canonical re-decode (e.g., bare-string keywords for JSON; no
    /// spans / no comments for Binary). One-way for some modules.
    compact,
    /// Larger than canonical. Preserves source trivia (comments,
    /// significant whitespace, all spans). Bidirectional.
    full,
};

/// The abstract value-shape vocabulary. SJON has ten value kinds:
/// `nil`, `boolean`, `number`, `number_with_unit`, `date`, `string`,
/// `keyword`, `symbol`, `vector`, `form`. Layer-specific tag enums
/// refine this:
///
/// - `Ast.Tag` (this file) splits `boolean` into `boolean_true` /
///   `boolean_false` because the truth value rides on the tag byte
///   (no `Data` payload). It also adds `kvpair`, a structural node
///   used to represent `(form :key val)` keyword pairs in source order
///   — not a value shape, hence absent here.
/// - `Binary.Tag` splits both `boolean` (wire byte = truth) and `form`
///   (`form_bare` vs `form_qualified`, signalling namespace presence
///   without a flag byte).
/// - `BinaryCursor.NodeKind` (`= ValueKind`, aliased) is the read-API
///   discriminator; it mirrors `ValueKind` exactly because the cursor
///   already exposes truth on `NodeView.tag` and namespace on
///   `FormView.namespace`.
///
/// Note: `Lexer.Token.Tag` is the lexer's *lexeme* vocabulary (`lparen`,
/// `comment_line`, `eof`, …). It is intentionally not part of this
/// vocabulary.
pub const ValueKind = enum(u8) {
    nil,
    boolean,
    number,
    number_with_unit,
    /// Calendar date (proleptic Gregorian, no time, no zone). Stored
    /// in the AST as `Tag.date` with a packed `(year, month, day)`
    /// triple in `Data.immediate`.
    date,
    /// Clock time (no date, no zone, no leap seconds). Stored in the
    /// AST as `Tag.time` with a packed `(hour, minute, second,
    /// millisecond)` quad in `Data.immediate` (low 40 bits).
    time,
    string,
    keyword,
    symbol,
    vector,
    form,
};

/// Discriminator for `Node.data`. Refines `ValueKind` with two splits
/// that earn payload bits in the SoA tree:
///
/// - `boolean_true` / `boolean_false` carry the truth value on the
///   tag itself, so `Data` stays unused for booleans (no `Data.bool`
///   variant pulls one bit through every node).
/// - `kvpair` is a structural child node (key + value, distinct from
///   a value-bearing tag); the source-order rendering and JSON shape
///   need the structural mark, but `kvpair` never appears at a value
///   position — `toValueKind()` is `unreachable` for it.
///
/// Each variant's payload layout is pinned in the comment beside it.
/// Project to the abstract spine via `toValueKind()`. The encoder
/// projects to the wire vocabulary via `Binary.Tag.fromAst(tag,
/// has_namespace)`.
pub const Tag = enum(u8) {
    /// `Data.single` = `ExtraIndex` into `extra_data` at the form header:
    ///     [0] head:           StringIndex
    ///     [1] namespace:      StringIndex (== invalid if no namespace)
    ///     [2] head_span_start: u32
    ///     [3] head_span_end:   u32
    ///     [4] child_count:     u32
    ///     [5..5+child_count]   children: NodeIndex (positional or kvpair)
    form,
    /// `Data.pair` = `{ extra_start, extra_end }`. The slice
    /// `extra_data[extra_start..extra_end]` is a list of `NodeIndex` for
    /// the vector elements.
    vector,
    /// `Data.single` = `ExtraIndex` into `extra_data` at the kvpair header:
    ///     [0] key:            StringIndex
    ///     [1] value:          NodeIndex
    ///     [2] key_span_start: u32
    ///     [3] key_span_end:   u32
    kvpair,
    /// `Data.immediate` = `@bitCast(u64, value: f64)`.
    number,
    /// Exact signed 64-bit integer literal. Emitted by the parser when the
    /// lexeme has no fractional/exponent part and fits in `i64`. The
    /// f64-loss-at-parse problem is the *reason* this tag exists — round-
    /// trips preserve every bit through Printer/Json/Binary.
    /// `Data.immediate` = `@bitCast(u64, value: i64)`.
    /// Use `Tree.numberI64Of` to read.
    number_i64,
    /// Exact unsigned 64-bit integer literal. Emitted by the parser only
    /// when the lexeme is non-negative and exceeds `i64.max` but fits in
    /// `u64`. Below `i64.max + 1` the parser prefers `number_i64`.
    /// `Data.immediate` = `value: u64`.
    /// Use `Tree.numberU64Of` to read.
    number_u64,
    /// Number literal with a unit suffix (e.g. `4b`, `90deg`, `50%`,
    /// `250ms`, `1.5e2hz`). `Data.single` = `ExtraIndex` into `extra_data`:
    ///     [0] f64 lo bits (low 32 bits of `@bitCast(u64, value)`)
    ///     [1] f64 hi bits (high 32 bits)
    ///     [2] unit `StringIndex` (interned, ASCII letters or `%`)
    /// Use `Tree.numberWithUnitOf` to read.
    number_with_unit,
    /// `Data.single` = `StringIndex` for the (escape-decoded) string body.
    string,
    /// `Data.single` = `StringIndex` for the keyword name (no leading `:`).
    keyword,
    /// `Data.single` = `StringIndex` for the symbol text.
    symbol,
    /// `Data` unused.
    boolean_true,
    /// `Data` unused.
    boolean_false,
    /// `Data` unused.
    nil,
    /// Calendar date: proleptic Gregorian `(year, month, day)`. Lex shape
    /// `YYYY-MM-DD` (strict 10 chars). The `(year:i16, month:u8, day:u8)`
    /// triple is packed via `Date.pack` into `Data.immediate` — no
    /// `extra_data` spill. Read via `Tree.dateOf`.
    date,
    /// Clock time: `(hour, minute, second, millisecond)`. Lex shapes
    /// `HH:MM:SS` (8 chars) or `HH:MM:SS.fff` (12 chars). The
    /// `(hour:u8, minute:u8, second:u8, millisecond:u16)` quad is
    /// packed via `Time.pack` into the low 40 bits of `Data.immediate`
    /// — no `extra_data` spill. Read via `Tree.timeOf`.
    time,

    /// True for the three plain numeric tags — `number` (f64), `number_i64`,
    /// `number_u64` — that read/match uniformly as "a number" wherever the
    /// exact integer/float split doesn't matter. Excludes `number_with_unit`:
    /// a unit-bearing literal is a distinct classification (see `toValueKind`),
    /// so slots and readers that must reject a stray unit stay explicit.
    /// The `Tag.isNumber: exhaustive classification pin` test forces any new
    /// tag to be classified here.
    pub fn isNumber(self: Tag) bool {
        return switch (self) {
            .number, .number_i64, .number_u64 => true,
            else => false,
        };
    }

    /// Project to the abstract value-shape vocabulary.
    /// `kvpair` is a structural node, not a value, and is `unreachable`
    /// — callers should never invoke this on a kvpair node.
    pub fn toValueKind(self: Tag) ValueKind {
        return switch (self) {
            .form => .form,
            .vector => .vector,
            .kvpair => unreachable,
            .number, .number_i64, .number_u64 => .number,
            .number_with_unit => .number_with_unit,
            .string => .string,
            .keyword => .keyword,
            .symbol => .symbol,
            .boolean_true, .boolean_false => .boolean,
            .nil => .nil,
            .date => .date,
            .time => .time,
        };
    }
};

/// Per-node payload. Untagged because `Tag` lives in a parallel SoA array.
pub const Data = extern union {
    immediate: u64,
    pair: extern struct { a: u32, b: u32 },
    single: u32,
};

/// One AST node in the SoA representation. The 17-byte footprint is
/// distributed across three parallel arrays in `MultiArrayList`.
pub const Node = struct {
    tag: Tag,
    span: Span,
    data: Data,
};

/// Range into `Tree.comments`. `start == end` means "no comments".
pub const CommentRange = packed struct {
    start: u32,
    end: u32,

    pub const empty: CommentRange = .{ .start = 0, .end = 0 };

    pub inline fn isEmpty(self: CommentRange) bool {
        return self.start == self.end;
    }
    pub inline fn len(self: CommentRange) u32 {
        std.debug.assert(self.end >= self.start);
        return self.end - self.start;
    }
};

comptime {
    std.debug.assert(@sizeOf(Data) == 8);
    std.debug.assert(@sizeOf(CommentRange) == 8);
    std.debug.assert(@sizeOf(Tag) == 1);
    // Per-node SoA footprint = sizeof(Tag) + sizeof(Span) + sizeof(Data).
    // We can't take @sizeOf(Node) directly (Zig pads it), but the SoA
    // arrays are tightly packed by `MultiArrayList`.
    std.debug.assert(@sizeOf(Span) == 8);
}

/// Parsed SJON tree, SoA edition. Self-contained: every owned slice lives
/// in `arena`.
pub const Tree = struct {
    /// Backing arena. Owns every slice owned by this tree.
    arena: std.heap.ArenaAllocator,
    /// Borrowed source. Spans index into this slice. The tree does NOT
    /// copy the source.
    source: [:0]const u8,

    /// SoA node storage — three parallel arrays (tag / span / data).
    nodes: std.MultiArrayList(Node).Slice,

    /// Form / kvpair / vector spill buffer (Tag.form, Tag.kvpair, Tag.vector).
    /// Each owning node points into this with an index range. Arena-owned.
    extra_data: []const u32,

    /// Concatenated string content (escape-decoded for strings). Arena-owned.
    strings: []const u8,
    /// `n+1` offsets into `strings` for `n` strings. Arena-owned.
    string_index: []const u32,

    /// Top-level node indices, in source order. Arena-owned.
    root: []const NodeIndex,

    /// Per-node leading-comment ranges. `len == nodes.len`. Arena-owned.
    leading_comments_index: []const CommentRange,
    /// Per-node trailing-comment ranges (a comment before the closing
    /// delimiter — meaningful for `.form` and `.vector`).
    /// `len == nodes.len`. Arena-owned.
    trailing_comments_index: []const CommentRange,

    /// SoA storage for all comments (any kind, any owner) in source order.
    comments: std.MultiArrayList(Comment).Slice,

    /// Comments after the last top-level node (or in an empty file).
    tree_trailing_comments: CommentRange,

    /// Parse / lex diagnostics. Arena-owned.
    diagnostics: []const Diagnostic,

    pub fn deinit(self: *Tree) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *Tree) Allocator {
        return self.arena.allocator();
    }

    pub fn hasErrors(self: *const Tree) bool {
        for (self.diagnostics) |d| if (d.severity == .err) return true;
        return false;
    }

    // -----------------------------------------------------------------
    // Accessors
    // -----------------------------------------------------------------

    pub fn tagOf(self: *const Tree, idx: NodeIndex) Tag {
        return self.nodes.items(.tag)[idx.raw()];
    }
    pub fn spanOf(self: *const Tree, idx: NodeIndex) Span {
        return self.nodes.items(.span)[idx.raw()];
    }
    pub fn dataOf(self: *const Tree, idx: NodeIndex) Data {
        return self.nodes.items(.data)[idx.raw()];
    }

    pub fn stringSlice(self: *const Tree, s: StringIndex) []const u8 {
        const i = s.raw();
        std.debug.assert(i + 1 < self.string_index.len);
        return self.strings[self.string_index[i]..self.string_index[i + 1]];
    }

    pub fn formHeader(self: *const Tree, idx: NodeIndex) FormHeader {
        std.debug.assert(self.tagOf(idx) == .form);
        const hdr = self.dataOf(idx).single;
        const head_idx: StringIndex = @enumFromInt(self.extra_data[hdr]);
        const ns_raw: u32 = self.extra_data[hdr + 1];
        const ns_idx: StringIndex = @enumFromInt(ns_raw);
        const head_span = Span{
            .start = self.extra_data[hdr + 2],
            .end = self.extra_data[hdr + 3],
        };
        const count = self.extra_data[hdr + 4];
        const children = @as([*]const NodeIndex, @ptrCast(self.extra_data[hdr + 5 ..].ptr))[0..count];
        return .{
            .head = self.stringSlice(head_idx),
            .namespace = if (ns_idx == .invalid) null else self.stringSlice(ns_idx),
            .head_span = head_span,
            .children = children,
        };
    }

    pub fn vectorElements(self: *const Tree, idx: NodeIndex) []const NodeIndex {
        std.debug.assert(self.tagOf(idx) == .vector);
        const d = self.dataOf(idx).pair;
        std.debug.assert(d.b >= d.a);
        return @as([*]const NodeIndex, @ptrCast(self.extra_data[d.a..d.b].ptr))[0 .. d.b - d.a];
    }

    pub fn kvpairHeader(self: *const Tree, idx: NodeIndex) KvPairHeader {
        std.debug.assert(self.tagOf(idx) == .kvpair);
        const hdr = self.dataOf(idx).single;
        const key_idx: StringIndex = @enumFromInt(self.extra_data[hdr]);
        const value_idx: NodeIndex = @enumFromInt(self.extra_data[hdr + 1]);
        return .{
            .key = self.stringSlice(key_idx),
            .value = value_idx,
            .key_span = .{
                .start = self.extra_data[hdr + 2],
                .end = self.extra_data[hdr + 3],
            },
        };
    }

    /// Resolve the form a walker descends into for `child`, or `null` if
    /// the child is not form-shaped. Nested data attaches two ways: a
    /// direct positional `.form`, or a `.kvpair` whose value is a `.form`
    /// (`:slot (inner)`). A scalar, a vector, and a kvpair holding a
    /// non-form value are all "not a form" and are not descended.
    ///
    /// Lives here rather than in a walker because two of them need it —
    /// `Lowering` and `MaterializedDefaults` — and `Lowering` imports
    /// `MaterializedDefaults`, so the copy that used to sit in the latter
    /// could not simply import the former. Both already import `Ast`, and
    /// this is a pure `Tree` query, so it belongs next to `formHeader`
    /// and `kvpairHeader` anyway. Any future walker that disagrees about
    /// which children count as forms would be a bug, not a variation.
    pub fn childForm(self: *const Tree, child: NodeIndex) ?NodeIndex {
        return switch (self.tagOf(child)) {
            .form => child,
            .kvpair => blk: {
                const kvh = self.kvpairHeader(child);
                break :blk if (self.tagOf(kvh.value) == .form) kvh.value else null;
            },
            else => null,
        };
    }

    /// Polymorphic number read — accepts `.number`, `.number_i64`, and
    /// `.number_u64`, returning the value as f64. For integer tags the
    /// conversion is lossy beyond 2^53; callers that need exact bits
    /// must dispatch on `tagOf` and use `numberI64Of` / `numberU64Of`.
    pub fn numberOf(self: *const Tree, idx: NodeIndex) f64 {
        const d = self.dataOf(idx).immediate;
        return switch (self.tagOf(idx)) {
            .number => @bitCast(d),
            .number_i64 => @floatFromInt(@as(i64, @bitCast(d))),
            .number_u64 => @floatFromInt(d),
            else => unreachable,
        };
    }

    /// Read a `Tag.number_i64` node. Exact — no precision loss.
    pub fn numberI64Of(self: *const Tree, idx: NodeIndex) i64 {
        std.debug.assert(self.tagOf(idx) == .number_i64);
        return @bitCast(self.dataOf(idx).immediate);
    }

    /// Read a `Tag.number_u64` node. Exact — no precision loss. Only set
    /// for values in `(i64.max, u64.max]`.
    pub fn numberU64Of(self: *const Tree, idx: NodeIndex) u64 {
        std.debug.assert(self.tagOf(idx) == .number_u64);
        return self.dataOf(idx).immediate;
    }

    /// Read a `Tag.date` node. Returns the validated `Date` value
    /// packed in `Data.immediate`. Caller-side cost is one bit unpack;
    /// the value satisfies `Date.init`'s invariants because the
    /// parser / builder funnel construction through `Date.init`.
    pub fn dateOf(self: *const Tree, idx: NodeIndex) Date {
        std.debug.assert(self.tagOf(idx) == .date);
        return Date.unpack(self.dataOf(idx).immediate);
    }

    /// Read a `Tag.time` node. Returns the validated `Time` value
    /// packed in the low 40 bits of `Data.immediate`. Caller-side
    /// cost is one bit unpack; the value satisfies `Time.init`'s
    /// invariants because the parser / builder funnel construction
    /// through `Time.init`.
    pub fn timeOf(self: *const Tree, idx: NodeIndex) Time {
        std.debug.assert(self.tagOf(idx) == .time);
        return Time.unpack(self.dataOf(idx).immediate);
    }

    /// Read a `Tag.number_with_unit` node. Returns the f64 value and the
    /// borrowed unit slice (lifetime: `Tree`).
    ///
    /// Complexity: O(1). The f64 is reassembled from two u32 halves in
    /// `extra_data`; the unit comes from the pool indexed by the third
    /// slot.
    pub fn numberWithUnitOf(self: *const Tree, idx: NodeIndex) NumberWithUnit {
        std.debug.assert(self.tagOf(idx) == .number_with_unit);
        const hdr = self.dataOf(idx).single;
        std.debug.assert(hdr + 2 < self.extra_data.len);
        const lo: u64 = self.extra_data[hdr];
        const hi: u64 = self.extra_data[hdr + 1];
        const bits: u64 = lo | (hi << 32);
        const unit_idx: StringIndex = @enumFromInt(self.extra_data[hdr + 2]);
        const unit = self.stringSlice(unit_idx);
        std.debug.assert(unit.len > 0);
        return .{ .value = @bitCast(bits), .unit = unit };
    }

    /// Borrowed text of a `Tag.symbol` node (lifetime: `Tree`).
    pub fn symbolText(self: *const Tree, idx: NodeIndex) []const u8 {
        std.debug.assert(self.tagOf(idx) == .symbol);
        const si: StringIndex = @enumFromInt(self.dataOf(idx).single);
        return self.stringSlice(si);
    }

    /// Borrowed text of a `Tag.keyword` node (lifetime: `Tree`).
    /// Returns the keyword name without the leading `:`.
    pub fn keywordText(self: *const Tree, idx: NodeIndex) []const u8 {
        std.debug.assert(self.tagOf(idx) == .keyword);
        const si: StringIndex = @enumFromInt(self.dataOf(idx).single);
        return self.stringSlice(si);
    }

    /// Borrowed text of a `Tag.string` node (lifetime: `Tree`).
    pub fn stringText(self: *const Tree, idx: NodeIndex) []const u8 {
        std.debug.assert(self.tagOf(idx) == .string);
        const si: StringIndex = @enumFromInt(self.dataOf(idx).single);
        return self.stringSlice(si);
    }

    /// SoA accessors for a comment range. Consumers iterate
    /// `0..r.len()` and read by index — no AoS materialisation needed.
    pub fn commentSpans(self: *const Tree, r: CommentRange) []const Span {
        if (r.isEmpty()) return &.{};
        return self.comments.items(.span)[r.start..r.end];
    }
    pub fn commentTexts(self: *const Tree, r: CommentRange) [][]const u8 {
        if (r.isEmpty()) return &.{};
        return self.comments.items(.text)[r.start..r.end];
    }
    pub fn commentKinds(self: *const Tree, r: CommentRange) []const Comment.Kind {
        if (r.isEmpty()) return &.{};
        return self.comments.items(.kind)[r.start..r.end];
    }
};

/// Materialised view of a form node's header. Returned by `Tree.formHeader`.
pub const FormHeader = struct {
    head: []const u8,
    namespace: ?[]const u8,
    head_span: Span,
    children: []const NodeIndex,
};

/// Materialised view of a kvpair node's header. Returned by `Tree.kvpairHeader`.
pub const KvPairHeader = struct {
    key: []const u8,
    value: NodeIndex,
    key_span: Span,
};

/// Materialised view of a `Tag.number_with_unit` node. Returned by
/// `Tree.numberWithUnitOf`. The `unit` slice is borrowed from the tree's
/// string pool.
pub const NumberWithUnit = struct {
    value: f64,
    unit: []const u8,
};

// ---------------------------------------------------------------------------
// TreeBuilder — incremental SoA construction. Used by Parser, Json, Binary,
// Edit, and any other consumer that builds an `Ast.Tree`.
// ---------------------------------------------------------------------------

/// Builder for `Tree`. Allocates into the destination arena directly,
/// so there's no scratch / dup phase. The arena outlives every list and
/// every slice; `finalize` simply hands the slices to a `Tree`.
pub const TreeBuilder = struct {
    /// Arena allocator for the destination tree. All builder allocations
    /// land here.
    a: Allocator,

    nodes: std.MultiArrayList(Node) = .{},
    extra_data: std.ArrayList(u32) = .empty,
    strings: std.ArrayList(u8) = .empty,
    string_index: std.ArrayList(u32) = .empty,
    comments: std.MultiArrayList(Comment) = .{},
    leading_index: std.ArrayList(CommentRange) = .empty,
    trailing_index: std.ArrayList(CommentRange) = .empty,

    pub fn addString(self: *TreeBuilder, text: []const u8) Allocator.Error!StringIndex {
        // Always seed the string_index with a sentinel entry (offset 0)
        // so `string_index[i+1]` is always valid.
        if (self.string_index.items.len == 0) {
            try self.string_index.append(self.a, 0);
        }
        const i: u32 = @intCast(self.string_index.items.len - 1);
        try self.strings.appendSlice(self.a, text);
        try self.string_index.append(self.a, @intCast(self.strings.items.len));
        return StringIndex.from(i);
    }

    pub fn appendNode(self: *TreeBuilder, node: Node) Allocator.Error!NodeIndex {
        const i: u32 = @intCast(self.nodes.len);
        try self.nodes.append(self.a, node);
        try self.leading_index.append(self.a, .empty);
        try self.trailing_index.append(self.a, .empty);
        return NodeIndex.from(i);
    }

    pub fn setLeading(self: *TreeBuilder, idx: NodeIndex, range: CommentRange) void {
        self.leading_index.items[idx.raw()] = range;
    }

    pub fn setTrailing(self: *TreeBuilder, idx: NodeIndex, range: CommentRange) void {
        self.trailing_index.items[idx.raw()] = range;
    }

    pub fn addCommentRange(self: *TreeBuilder, src: []const Comment) Allocator.Error!CommentRange {
        if (src.len == 0) return .empty;
        const start: u32 = @intCast(self.comments.len);
        for (src) |c| {
            // Dup comment text into the destination arena so the resulting
            // tree is self-contained — `Parser.parse` deinits the
            // intermediate legacy tree before returning, so any aliased
            // comment slice would dangle.
            const text_copy = try self.a.dupe(u8, c.text);
            try self.comments.append(self.a, .{
                .span = c.span,
                .text = text_copy,
                .kind = c.kind,
            });
        }
        const end: u32 = @intCast(self.comments.len);
        return .{ .start = start, .end = end };
    }

    /// Append a `Tag.form` node, spilling the form header (head /
    /// namespace / head-span / child-count / children) into `extra_data`
    /// in the layout described on `Tag.form`.
    pub fn addForm(
        self: *TreeBuilder,
        head: StringIndex,
        namespace: ?StringIndex,
        head_span: Span,
        children: []const NodeIndex,
        span: Span,
    ) Allocator.Error!NodeIndex {
        const ns_raw: u32 = if (namespace) |n| n.raw() else StringIndex.invalid.raw();
        const hdr_at: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.appendSlice(self.a, &.{
            head.raw(),
            ns_raw,
            head_span.start,
            head_span.end,
            @intCast(children.len),
        });
        for (children) |ci| try self.extra_data.append(self.a, ci.raw());
        return self.appendNode(.{
            .tag = .form,
            .span = span,
            .data = .{ .single = hdr_at },
        });
    }

    /// Append a `Tag.vector` node, spilling element indices into
    /// `extra_data` and recording the range in `Data.pair`.
    pub fn addVector(
        self: *TreeBuilder,
        elements: []const NodeIndex,
        span: Span,
    ) Allocator.Error!NodeIndex {
        const start: u32 = @intCast(self.extra_data.items.len);
        for (elements) |ci| try self.extra_data.append(self.a, ci.raw());
        const end: u32 = @intCast(self.extra_data.items.len);
        return self.appendNode(.{
            .tag = .vector,
            .span = span,
            .data = .{ .pair = .{ .a = start, .b = end } },
        });
    }

    /// Append a `Tag.kvpair` node, spilling the key / value / key-span
    /// header into `extra_data` per the layout on `Tag.kvpair`. The
    /// `span` should cover the whole `:key value` source range.
    pub fn addKvpair(
        self: *TreeBuilder,
        key: StringIndex,
        value: NodeIndex,
        key_span: Span,
        span: Span,
    ) Allocator.Error!NodeIndex {
        const hdr_at: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.appendSlice(self.a, &.{
            key.raw(),
            value.raw(),
            key_span.start,
            key_span.end,
        });
        return self.appendNode(.{
            .tag = .kvpair,
            .span = span,
            .data = .{ .single = hdr_at },
        });
    }

    /// Copy a `CommentRange` from another `Tree` into this builder.
    /// Each comment's `.text` is dup'd into the destination arena so the
    /// resulting tree is self-contained.
    pub fn cloneCommentRange(
        self: *TreeBuilder,
        src_tree: *const Tree,
        range: CommentRange,
    ) Allocator.Error!CommentRange {
        if (range.isEmpty()) return .empty;
        const start: u32 = @intCast(self.comments.len);
        var i: u32 = range.start;
        while (i < range.end) : (i += 1) {
            const span = src_tree.comments.items(.span)[i];
            const text = src_tree.comments.items(.text)[i];
            const kind = src_tree.comments.items(.kind)[i];
            const text_copy = try self.a.dupe(u8, text);
            try self.comments.append(self.a, .{
                .span = span,
                .text = text_copy,
                .kind = kind,
            });
        }
        const end: u32 = @intCast(self.comments.len);
        return .{ .start = start, .end = end };
    }

    // -----------------------------------------------------------------
    // Ergonomic appenders.
    //
    // Mirror the AST tag taxonomy so callers building synthesized trees
    // (e.g. the lowering pass — `src/Lowering.zig`) need not hand-pack
    // `Node` values or pre-intern strings. Each method interns into the
    // builder's pool, appends one node, and returns the `NodeIndex`.
    // The `addForm` / `addVector` / `addKvpair` low-level methods above
    // still exist for callers that already hold `StringIndex` handles
    // (the parser and the `cloneNode` recursion).
    // -----------------------------------------------------------------

    pub fn appendNumber(self: *TreeBuilder, n: f64, span: Span) Allocator.Error!NodeIndex {
        return self.appendNode(.{
            .tag = .number,
            .span = span,
            .data = .{ .immediate = @bitCast(n) },
        });
    }

    /// Pack a `number_with_unit` payload into `extra_data` and return the
    /// header offset (the value stored in the node's `.single` slot).
    /// Sole owner of the `[f64 lo][f64 hi][unit pool idx]` layout that
    /// `Tree.numberWithUnitOf` reads back — the parser, the JSON/binary
    /// decoders, and `cloneNode` all route through here so the pack and
    /// the unpack cannot drift. Interns `unit` into the string pool
    /// (asserted non-empty by the reader). The f64 is split into two u32
    /// halves so `extra_data` (a `u32` pool) can hold the whole payload.
    pub fn packNumberWithUnit(self: *TreeBuilder, value: f64, unit: []const u8) Allocator.Error!u32 {
        const unit_si = try self.addString(unit);
        const bits: u64 = @bitCast(value);
        const hdr_at: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.appendSlice(self.a, &.{
            @truncate(bits),
            @truncate(bits >> 32),
            unit_si.raw(),
        });
        return hdr_at;
    }

    /// Append a `Tag.number_with_unit` node (an f64 plus a unit suffix,
    /// e.g. `90deg`). Packs the payload via `packNumberWithUnit` and
    /// appends the node. Ergonomic-family member — see the block comment
    /// above the appenders; callers that decode onto an explicit node
    /// stack (the binary `Decoder`) call `packNumberWithUnit` directly.
    pub fn appendNumberWithUnit(self: *TreeBuilder, value: f64, unit: []const u8, span: Span) Allocator.Error!NodeIndex {
        const hdr_at = try self.packNumberWithUnit(value, unit);
        return self.appendNode(.{
            .tag = .number_with_unit,
            .span = span,
            .data = .{ .single = hdr_at },
        });
    }

    /// Append an exact signed 64-bit integer node (`Tag.number_i64`).
    /// Read back via `Tree.numberI64Of`.
    pub fn appendNumberI64(self: *TreeBuilder, value: i64, span: Span) Allocator.Error!NodeIndex {
        return self.appendNode(.{
            .tag = .number_i64,
            .span = span,
            .data = .{ .immediate = @bitCast(value) },
        });
    }

    /// Append an exact unsigned 64-bit integer node (`Tag.number_u64`).
    /// Only meaningful for values in `(i64.max, u64.max]`; below that the
    /// parser prefers `appendNumberI64`. Read back via `Tree.numberU64Of`.
    pub fn appendNumberU64(self: *TreeBuilder, value: u64, span: Span) Allocator.Error!NodeIndex {
        return self.appendNode(.{
            .tag = .number_u64,
            .span = span,
            .data = .{ .immediate = value },
        });
    }

    /// Append a calendar-date node (`Tag.date`); the `Date` is packed into
    /// the immediate slot. Read back via `Tree.dateOf`.
    pub fn appendDate(self: *TreeBuilder, value: Date, span: Span) Allocator.Error!NodeIndex {
        return self.appendNode(.{
            .tag = .date,
            .span = span,
            .data = .{ .immediate = value.pack() },
        });
    }

    /// Append a clock-time node (`Tag.time`); the `Time` is packed into the
    /// immediate slot. Read back via `Tree.timeOf`.
    pub fn appendTime(self: *TreeBuilder, value: Time, span: Span) Allocator.Error!NodeIndex {
        return self.appendNode(.{
            .tag = .time,
            .span = span,
            .data = .{ .immediate = value.pack() },
        });
    }

    pub fn appendString(self: *TreeBuilder, text: []const u8, span: Span) Allocator.Error!NodeIndex {
        const si = try self.addString(text);
        return self.appendNode(.{
            .tag = .string,
            .span = span,
            .data = .{ .single = si.raw() },
        });
    }

    pub fn appendSymbol(self: *TreeBuilder, text: []const u8, span: Span) Allocator.Error!NodeIndex {
        const si = try self.addString(text);
        return self.appendNode(.{
            .tag = .symbol,
            .span = span,
            .data = .{ .single = si.raw() },
        });
    }

    pub fn appendKeyword(self: *TreeBuilder, text: []const u8, span: Span) Allocator.Error!NodeIndex {
        const si = try self.addString(text);
        return self.appendNode(.{
            .tag = .keyword,
            .span = span,
            .data = .{ .single = si.raw() },
        });
    }

    pub fn appendBoolean(self: *TreeBuilder, value: bool, span: Span) Allocator.Error!NodeIndex {
        return self.appendNode(.{
            .tag = if (value) .boolean_true else .boolean_false,
            .span = span,
            .data = .{ .immediate = 0 },
        });
    }

    pub fn appendNil(self: *TreeBuilder, span: Span) Allocator.Error!NodeIndex {
        return self.appendNode(.{
            .tag = .nil,
            .span = span,
            .data = .{ .immediate = 0 },
        });
    }

    /// Append a form by raw head + namespace strings — interns each into
    /// the builder's string pool before delegating to `addForm`. The
    /// `kvpairs` and `children` slices are concatenated in order; if a
    /// caller wants to preserve kvpair/positional grouping per source
    /// order they should pass a single merged slice instead.
    pub fn appendForm(
        self: *TreeBuilder,
        head: []const u8,
        namespace: ?[]const u8,
        head_span: Span,
        children: []const NodeIndex,
        span: Span,
    ) Allocator.Error!NodeIndex {
        const head_si = try self.addString(head);
        const ns_si: ?StringIndex = if (namespace) |ns| try self.addString(ns) else null;
        return self.addForm(head_si, ns_si, head_span, children, span);
    }

    /// Append a kvpair by raw key string — interns into the builder's
    /// string pool before delegating to `addKvpair`.
    pub fn appendKvpair(
        self: *TreeBuilder,
        key: []const u8,
        value: NodeIndex,
        key_span: Span,
        span: Span,
    ) Allocator.Error!NodeIndex {
        const key_si = try self.addString(key);
        return self.addKvpair(key_si, value, key_span, span);
    }

    /// Append a vector by element list (alias of `addVector`, exposed
    /// here so callers using the ergonomic family stay on one prefix).
    pub fn appendVector(
        self: *TreeBuilder,
        elements: []const NodeIndex,
        span: Span,
    ) Allocator.Error!NodeIndex {
        return self.addVector(elements, span);
    }

    /// Tree-level fields threaded past the builder's own SoA pools when
    /// finalizing: the trailing comments after the last root, and the
    /// diagnostics list. Both default empty, so `finalize` is
    /// `finalizeWith(…, .{})`. `diagnostics` is borrowed by the returned
    /// `Tree` — allocate it from the arena being finalized (so the
    /// snapshot owns it) or pass a static/empty slice.
    pub const FinalizeExtras = struct {
        tree_trailing_comments: CommentRange = .empty,
        diagnostics: []const Diagnostic = &.{},
    };

    /// Finalize the builder into a `Tree`. Takes a pointer to the
    /// caller's `ArenaAllocator`, snapshots its up-to-date state into
    /// the returned `Tree`, and resets the caller's slot to an empty
    /// arena. `Tree.deinit` then owns the buffer chain; a stray
    /// `arena.deinit()` on the caller's slot becomes a safe no-op,
    /// so `errdefer arena.deinit()` on the build path is still safe.
    ///
    /// Why-pointer-not-value: writes through `arena.allocator()`
    /// update the caller's `arena.state` directly. Capturing the
    /// arena by value before the final allocations would freeze a
    /// stale `state.buffer_list.first` and `Tree.deinit` would walk
    /// half the chain.
    ///
    /// `source` is borrowed — the tree does not copy it. Spans on
    /// appended nodes are caller-supplied; passing `{0,0}` is fine
    /// for synthesized trees that don't index into real source bytes.
    /// `roots` is dup'd into the arena. This is the sole owner of the
    /// full `Tree` literal and the string-index sentinel seed — every
    /// decoder (`Binary.fromBinary`, `Json.fromJson*`,
    /// `Edit.buildEditedTree`) routes through here rather than hand-
    /// spelling the field list.
    pub fn finalizeWith(
        self: *TreeBuilder,
        arena_state: *std.heap.ArenaAllocator,
        source: [:0]const u8,
        roots: []const NodeIndex,
        extras: FinalizeExtras,
    ) Allocator.Error!Tree {
        // The string_index sentinel is normally appended on the first
        // `addString` call; ensure it's present so `string_index[i+1]`
        // never reads off the end (matches the cloneTree fallback).
        if (self.string_index.items.len == 0) {
            try self.string_index.append(self.a, 0);
        }
        const roots_dup = try self.a.dupe(NodeIndex, roots);

        // Snapshot the up-to-date arena, then clear the caller's slot
        // so their `arena.deinit()` (or errdefer) is a no-op. The
        // returned Tree now owns every node in the chain.
        const owned = arena_state.*;
        arena_state.* = std.heap.ArenaAllocator.init(arena_state.child_allocator);

        return .{
            .arena = owned,
            .source = source,
            .nodes = self.nodes.toOwnedSlice(),
            .extra_data = self.extra_data.items,
            .strings = self.strings.items,
            .string_index = self.string_index.items,
            .root = roots_dup,
            .leading_comments_index = self.leading_index.items,
            .trailing_comments_index = self.trailing_index.items,
            .comments = self.comments.toOwnedSlice(),
            .tree_trailing_comments = extras.tree_trailing_comments,
            .diagnostics = extras.diagnostics,
        };
    }

    /// `finalizeWith` with no tree-trailing comments and no diagnostics —
    /// the common case for synthesized trees (the lowering pass, the
    /// `cloneNode` callers). See `finalizeWith` for the arena contract.
    pub fn finalize(
        self: *TreeBuilder,
        arena_state: *std.heap.ArenaAllocator,
        source: [:0]const u8,
        roots: []const NodeIndex,
    ) Allocator.Error!Tree {
        return self.finalizeWith(arena_state, source, roots, .{});
    }

    /// Clone a subtree from another `Tree` into this builder, recursively.
    /// Strings are re-interned into this builder's pool; comments are
    /// dup'd via `cloneCommentRange`. Recursion is bounded by the source
    /// tree's depth (≤ `Parser.MAX_PARSE_DEPTH`).
    pub fn cloneNode(
        self: *TreeBuilder,
        src_tree: *const Tree,
        src_idx: NodeIndex,
    ) Allocator.Error!NodeIndex {
        const tag = src_tree.tagOf(src_idx);
        const span = src_tree.spanOf(src_idx);
        const idx: NodeIndex = switch (tag) {
            .number, .number_i64, .number_u64 => try self.appendNode(.{
                .tag = tag,
                .span = span,
                .data = .{ .immediate = src_tree.dataOf(src_idx).immediate },
            }),
            .number_with_unit => blk: {
                const nu = src_tree.numberWithUnitOf(src_idx);
                break :blk try self.appendNumberWithUnit(nu.value, nu.unit, span);
            },
            .string, .keyword, .symbol => blk: {
                const src_si: StringIndex = @enumFromInt(src_tree.dataOf(src_idx).single);
                const new_si = try self.addString(src_tree.stringSlice(src_si));
                break :blk try self.appendNode(.{
                    .tag = tag,
                    .span = span,
                    .data = .{ .single = new_si.raw() },
                });
            },
            .boolean_true, .boolean_false, .nil => try self.appendNode(.{
                .tag = tag,
                .span = span,
                .data = .{ .immediate = 0 },
            }),
            .date => try self.appendNode(.{
                .tag = .date,
                .span = span,
                .data = .{ .immediate = src_tree.dataOf(src_idx).immediate },
            }),
            .time => try self.appendNode(.{
                .tag = .time,
                .span = span,
                .data = .{ .immediate = src_tree.dataOf(src_idx).immediate },
            }),
            .vector => blk: {
                const src_elements = src_tree.vectorElements(src_idx);
                var new_elements = try std.ArrayList(NodeIndex).initCapacity(self.a, src_elements.len);
                for (src_elements) |elem_idx| {
                    const ni = try self.cloneNode(src_tree, elem_idx);
                    new_elements.appendAssumeCapacity(ni);
                }
                const vec_idx = try self.addVector(new_elements.items, span);
                // Vectors carry trailing comments (a comment before `]`)
                // just as forms do; clone them for parity with the `.form`
                // arm — the leading side is handled by the shared tail.
                const trailing_src = src_tree.trailing_comments_index[src_idx.raw()];
                const trailing_dst = try self.cloneCommentRange(src_tree, trailing_src);
                self.setTrailing(vec_idx, trailing_dst);
                break :blk vec_idx;
            },
            .form => blk: {
                const hdr = src_tree.formHeader(src_idx);
                const head_si = try self.addString(hdr.head);
                const ns_si: ?StringIndex = if (hdr.namespace) |n|
                    try self.addString(n)
                else
                    null;
                var new_children = try std.ArrayList(NodeIndex).initCapacity(self.a, hdr.children.len);
                for (hdr.children) |child_idx| {
                    const ni = try self.cloneNode(src_tree, child_idx);
                    new_children.appendAssumeCapacity(ni);
                }
                const form_idx = try self.addForm(head_si, ns_si, hdr.head_span, new_children.items, span);
                const trailing_src = src_tree.trailing_comments_index[src_idx.raw()];
                const trailing_dst = try self.cloneCommentRange(src_tree, trailing_src);
                self.setTrailing(form_idx, trailing_dst);
                break :blk form_idx;
            },
            .kvpair => blk: {
                const kvh = src_tree.kvpairHeader(src_idx);
                const value_idx = try self.cloneNode(src_tree, kvh.value);
                const key_si = try self.addString(kvh.key);
                break :blk try self.addKvpair(key_si, value_idx, kvh.key_span, span);
            },
        };

        const leading_src = src_tree.leading_comments_index[src_idx.raw()];
        const leading_dst = try self.cloneCommentRange(src_tree, leading_src);
        self.setLeading(idx, leading_dst);

        return idx;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "Tree: comptime size invariants" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Data));
    try testing.expectEqual(@as(usize, 8), @sizeOf(CommentRange));
    try testing.expectEqual(@as(usize, 1), @sizeOf(Tag));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Span));
}

test "Tree: NodeIndex sentinel" {
    try testing.expect(NodeIndex.invalid == .invalid);
    try testing.expect(!NodeIndex.invalid.isValid());
    const i = NodeIndex.from(7);
    try testing.expectEqual(@as(u32, 7), i.raw());
    try testing.expect(i.isValid());
}

test "Tree: form children preserve source order" {
    const Parser = @import("Parser.zig");
    var tree = try Parser.parse(testing.allocator, "(scene 1 :bpm 130 2)");
    defer tree.deinit();

    const root = tree.root[0];
    try testing.expectEqual(Tag.form, tree.tagOf(root));
    const hdr = tree.formHeader(root);
    try testing.expectEqualStrings("scene", hdr.head);
    try testing.expectEqual(@as(usize, 3), hdr.children.len);
    // Pure-integer literals now land on `.number_i64`; the parser switched
    // to integer-first parsing for exact round-trip of large integers.
    try testing.expectEqual(Tag.number_i64, tree.tagOf(hdr.children[0]));
    try testing.expectEqual(Tag.kvpair, tree.tagOf(hdr.children[1]));
    try testing.expectEqual(Tag.number_i64, tree.tagOf(hdr.children[2]));
    try testing.expectEqual(@as(f64, 1), tree.numberOf(hdr.children[0]));
    const kvh = tree.kvpairHeader(hdr.children[1]);
    try testing.expectEqualStrings("bpm", kvh.key);
    try testing.expectEqual(@as(f64, 130), tree.numberOf(kvh.value));
    try testing.expectEqual(@as(f64, 2), tree.numberOf(hdr.children[2]));
}

test "Tree: leading comment lookup by NodeIndex" {
    const Parser = @import("Parser.zig");
    var tree = try Parser.parse(testing.allocator,
        \\; greeting
        \\42
    );
    defer tree.deinit();

    const r = tree.leading_comments_index[tree.root[0].raw()];
    try testing.expect(!r.isEmpty());
    const texts = tree.commentTexts(r);
    try testing.expectEqual(@as(usize, 1), texts.len);
    try testing.expectEqualStrings("; greeting", texts[0]);
}

test "Tree: NumberValue / NumberWithUnit comptime invariants" {
    // NumberValue's f64 + nullable slice must remain a small POD.
    // Two pointers (slice ptr + len) + tag byte + f64 + padding.
    try testing.expect(@sizeOf(NumberValue) <= 32);
    // The materialised view is a plain f64 + slice — no hidden state.
    try testing.expect(@sizeOf(NumberWithUnit) <= 32);
    // The Tag enum stays one byte even after adding number_with_unit.
    try testing.expectEqual(@as(usize, 1), @sizeOf(Tag));
}

test "Tree: numberWithUnitOf preserves f64 bit pattern (NaN, Inf, -0)" {
    // The SoA tree stores f64 as two u32s in extra_data; this test
    // pins that the round-trip survives all special bit patterns. We
    // build directly via TreeBuilder since the lexer cannot produce
    // NaN/Inf literals.
    const cases = [_]f64{ std.math.nan(f64), std.math.inf(f64), -0.0 };
    inline for (cases, 0..) |val, i| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var b: TreeBuilder = .{ .a = a };
        _ = try b.appendNumberWithUnit(val, "deg", .{ .start = 0, .end = 0 });

        if (b.string_index.items.len == 0) try b.string_index.append(a, 0);

        const tree = Tree{
            .arena = arena,
            .source = "",
            .nodes = b.nodes.toOwnedSlice(),
            .extra_data = b.extra_data.items,
            .strings = b.strings.items,
            .string_index = b.string_index.items,
            .root = &[_]NodeIndex{NodeIndex.from(0)},
            .leading_comments_index = b.leading_index.items,
            .trailing_comments_index = b.trailing_index.items,
            .comments = b.comments.toOwnedSlice(),
            .tree_trailing_comments = .empty,
            .diagnostics = &.{},
        };
        // Tree owns the arena via copy; do NOT deinit since arena.deinit
        // already runs on scope exit. Skip the value-with-arena pattern.
        _ = i;

        const got = tree.numberWithUnitOf(NodeIndex.from(0));
        try testing.expectEqualStrings("deg", got.unit);
        if (std.math.isNan(val)) {
            try testing.expect(std.math.isNan(got.value));
        } else {
            const got_bits: u64 = @bitCast(got.value);
            try testing.expectEqual(@as(u64, @bitCast(val)), got_bits);
        }
    }
}

test "Tree: numberI64Of / numberU64Of preserve exact values at the ends of their ranges" {
    // Built via TreeBuilder so this test is independent of parser support
    // (the parser path lands in a separate commit). Pins the bit-exact
    // round-trip through Data.immediate for both signed and unsigned tags.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var b: TreeBuilder = .{ .a = a };
    const i_min: i64 = std.math.minInt(i64);
    const i_max: i64 = std.math.maxInt(i64);
    const u_max: u64 = std.math.maxInt(u64);

    _ = try b.appendNode(.{ .tag = .number_i64, .span = .{ .start = 0, .end = 0 }, .data = .{ .immediate = @bitCast(i_min) } });
    _ = try b.appendNode(.{ .tag = .number_i64, .span = .{ .start = 0, .end = 0 }, .data = .{ .immediate = @bitCast(i_max) } });
    _ = try b.appendNode(.{ .tag = .number_u64, .span = .{ .start = 0, .end = 0 }, .data = .{ .immediate = u_max } });

    if (b.string_index.items.len == 0) try b.string_index.append(a, 0);

    const root = try a.alloc(NodeIndex, 3);
    root[0] = NodeIndex.from(0);
    root[1] = NodeIndex.from(1);
    root[2] = NodeIndex.from(2);

    const tree = Tree{
        .arena = arena,
        .source = "",
        .nodes = b.nodes.toOwnedSlice(),
        .extra_data = b.extra_data.items,
        .strings = b.strings.items,
        .string_index = b.string_index.items,
        .root = root,
        .leading_comments_index = b.leading_index.items,
        .trailing_comments_index = b.trailing_index.items,
        .comments = b.comments.toOwnedSlice(),
        .tree_trailing_comments = .empty,
        .diagnostics = &.{},
    };

    try testing.expectEqual(i_min, tree.numberI64Of(tree.root[0]));
    try testing.expectEqual(i_max, tree.numberI64Of(tree.root[1]));
    try testing.expectEqual(u_max, tree.numberU64Of(tree.root[2]));

    // toValueKind folds both integer tags into the abstract `.number` kind,
    // so schema/validator code that asks about ValueKind sees one shape.
    try testing.expectEqual(ValueKind.number, Tag.number_i64.toValueKind());
    try testing.expectEqual(ValueKind.number, Tag.number_u64.toValueKind());
}

test "Tree: parser dispatches Tag.number_i64 vs Tag.number_with_unit" {
    const Parser = @import("Parser.zig");
    var tree = try Parser.parse(testing.allocator, "42 90deg");
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 2), tree.root.len);
    // Pure-integer literal lands on the exact-integer tag; unit-bearing
    // literals stay on the f64-backed `.number_with_unit` tag.
    try testing.expectEqual(Tag.number_i64, tree.tagOf(tree.root[0]));
    try testing.expectEqual(Tag.number_with_unit, tree.tagOf(tree.root[1]));
    try testing.expectEqual(@as(i64, 42), tree.numberI64Of(tree.root[0]));
    const nu = tree.numberWithUnitOf(tree.root[1]);
    try testing.expectEqual(@as(f64, 90.0), nu.value);
    try testing.expectEqualStrings("deg", nu.unit);
}

test "Tag.isNumber classifies the plain numeric group" {
    // The three plain numeric tags — no unit, no other payload.
    try testing.expect(Tag.number.isNumber());
    try testing.expect(Tag.number_i64.isNumber());
    try testing.expect(Tag.number_u64.isNumber());
    // number_with_unit is a *unit-bearing* number — deliberately excluded,
    // mirroring toValueKind's split (.number vs .number_with_unit).
    try testing.expect(!Tag.number_with_unit.isNumber());
    // A spread of non-numeric tags.
    try testing.expect(!Tag.string.isNumber());
    try testing.expect(!Tag.form.isNumber());
    try testing.expect(!Tag.date.isNumber());
    try testing.expect(!Tag.boolean_true.isNumber());
}

test "Tag.isNumber: exhaustive classification pin" {
    // The switch below has no `else`, so a future Tag variant is a compile
    // error HERE until it is explicitly classified numeric or not — the one
    // site to update when the enum grows. Keep in lockstep with isNumber.
    inline for (std.meta.fields(Tag)) |f| {
        const tag: Tag = @enumFromInt(f.value);
        const want = switch (tag) {
            .number, .number_i64, .number_u64 => true,
            .number_with_unit,
            .form,
            .vector,
            .kvpair,
            .string,
            .keyword,
            .symbol,
            .boolean_true,
            .boolean_false,
            .nil,
            .date,
            .time,
            => false,
        };
        try testing.expectEqual(want, tag.isNumber());
    }
}

test "Tree: parser interns repeated unit strings" {
    const Parser = @import("Parser.zig");
    var tree = try Parser.parse(testing.allocator, "[90deg 180deg 270deg]");
    defer tree.deinit();

    const v = tree.vectorElements(tree.root[0]);
    try testing.expectEqual(@as(usize, 3), v.len);
    // Three nodes share the same "deg" string. The string pool may
    // deduplicate or not, but every readback must equal "deg".
    for (v) |idx| {
        const nu = tree.numberWithUnitOf(idx);
        try testing.expectEqualStrings("deg", nu.unit);
    }
}

test "Tree: numberWithUnitOf asserts on wrong tag" {
    // Negative-space test: calling on a plain integer node trips the
    // debug assert. Skip in release where assert is disabled.
    if (@import("builtin").mode != .Debug) return;
    // We can't easily test panics without process isolation. Pin only
    // the tagOf precondition to document the invariant. The literal
    // `42` parses to `.number_i64` now.
    const Parser = @import("Parser.zig");
    var tree = try Parser.parse(testing.allocator, "42");
    defer tree.deinit();
    try testing.expectEqual(Tag.number_i64, tree.tagOf(tree.root[0]));
}

// Test helper: build a fresh `Tree` by cloning every root of `src` via
// `TreeBuilder.cloneNode`.
fn cloneTree(gpa: Allocator, src: *const Tree) Allocator.Error!Tree {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var b: TreeBuilder = .{ .a = a };
    const root_indices = try a.alloc(NodeIndex, src.root.len);
    for (src.root, 0..) |idx, i| {
        root_indices[i] = try b.cloneNode(src, idx);
    }
    const tree_trailing = try b.cloneCommentRange(src, src.tree_trailing_comments);
    // Test helper: shallow dupe is acceptable here — the source tree
    // outlives every clone in these tests (deep-copy is `Diagnostic.dupe`,
    // used on the production `Edit.buildEditedTree` path).
    const diagnostics_dup = try a.dupe(Diagnostic, src.diagnostics);

    return b.finalizeWith(&arena, src.source, root_indices, .{
        .tree_trailing_comments = tree_trailing,
        .diagnostics = diagnostics_dup,
    });
}

test "TreeBuilder.cloneNode: round-trip preserves print output" {
    const Parser = @import("Parser.zig");
    const Printer = @import("Printer.zig");
    const fixtures = [_][:0]const u8{
        "42",
        "\"hello\"",
        ":kw",
        "true",
        "false",
        "nil",
        "[1 2 3]",
        "(scene 1 :bpm 130 2)",
        "(masagin/verb :n 1)",
        "[90deg 180deg 270deg]",
        "(outer (inner :a 1 :b [2 3]) :tail :flag)",
    };
    inline for (fixtures) |src| {
        var tree = try Parser.parse(testing.allocator, src);
        defer tree.deinit();

        var clone = try cloneTree(testing.allocator, &tree);
        defer clone.deinit();

        const a_bytes = try Printer.print(testing.allocator, tree, .{});
        defer a_bytes.deinit();
        const b_bytes = try Printer.print(testing.allocator, clone, .{});
        defer b_bytes.deinit();
        try testing.expectEqualStrings(a_bytes.data, b_bytes.data);
    }
}

test "TreeBuilder.cloneNode: preserves leading and trailing comments (lossless)" {
    const Parser = @import("Parser.zig");
    const Printer = @import("Printer.zig");
    const src: [:0]const u8 =
        \\; tree leading
        \\(scene
        \\  ; before child
        \\  1
        \\  ; before kvpair
        \\  :bpm 130
        \\  ; trailing inside form
        \\)
        \\; tree trailing
    ;
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();

    var clone = try cloneTree(testing.allocator, &tree);
    defer clone.deinit();

    const a_bytes = try Printer.print(testing.allocator, tree, .{ .mode = .full });
    defer a_bytes.deinit();
    const b_bytes = try Printer.print(testing.allocator, clone, .{ .mode = .full });
    defer b_bytes.deinit();
    try testing.expectEqualStrings(a_bytes.data, b_bytes.data);
}

test "TreeBuilder.cloneNode: preserves a vector's trailing comment" {
    // Regression: the `.vector` arm cloned only leading comments, so a
    // comment trailing the last element (before `]`) was dropped — while
    // the `.form` arm cloned both. `Printer` renders vector trailing
    // comments (Printer.zig `.full` mode), so the loss was in the clone.
    const Parser = @import("Parser.zig");
    const Printer = @import("Printer.zig");
    const src: [:0]const u8 =
        \\(scene [
        \\  1
        \\  ; trailing inside vector
        \\])
    ;
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();

    var clone = try cloneTree(testing.allocator, &tree);
    defer clone.deinit();

    const a_bytes = try Printer.print(testing.allocator, tree, .{ .mode = .full });
    defer a_bytes.deinit();
    const b_bytes = try Printer.print(testing.allocator, clone, .{ .mode = .full });
    defer b_bytes.deinit();
    try testing.expectEqualStrings(a_bytes.data, b_bytes.data);
}

test "TreeBuilder.cloneNode: preserves f64 NaN / Inf / -0 bit patterns" {
    // Build directly via TreeBuilder since the lexer cannot emit NaN/Inf.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var b: TreeBuilder = .{ .a = a };
    _ = try b.appendNumberWithUnit(std.math.nan(f64), "deg", .{ .start = 0, .end = 0 });
    if (b.string_index.items.len == 0) try b.string_index.append(a, 0);

    const root_indices = try a.alloc(NodeIndex, 1);
    root_indices[0] = NodeIndex.from(0);

    var tree = Tree{
        .arena = arena,
        .source = "",
        .nodes = b.nodes.toOwnedSlice(),
        .extra_data = b.extra_data.items,
        .strings = b.strings.items,
        .string_index = b.string_index.items,
        .root = root_indices,
        .leading_comments_index = b.leading_index.items,
        .trailing_comments_index = b.trailing_index.items,
        .comments = b.comments.toOwnedSlice(),
        .tree_trailing_comments = .empty,
        .diagnostics = &.{},
    };
    // Tree shares the arena with the outer scope; do not deinit here.

    var clone = try cloneTree(testing.allocator, &tree);
    defer clone.deinit();

    const got = clone.numberWithUnitOf(clone.root[0]);
    try testing.expect(std.math.isNan(got.value));
    try testing.expectEqualStrings("deg", got.unit);
}

test "TreeBuilder.addForm / addVector / addKvpair: round-trip via Printer" {
    const Printer = @import("Printer.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var b: TreeBuilder = .{ .a = a };

    // Build `(scene 1 :bpm 130 [2 3])` from primitives.
    const num1 = try b.appendNode(.{
        .tag = .number,
        .span = .{ .start = 0, .end = 0 },
        .data = .{ .immediate = @bitCast(@as(f64, 1)) },
    });
    const num130 = try b.appendNode(.{
        .tag = .number,
        .span = .{ .start = 0, .end = 0 },
        .data = .{ .immediate = @bitCast(@as(f64, 130)) },
    });
    const bpm_si = try b.addString("bpm");
    const kv = try b.addKvpair(bpm_si, num130, .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 });
    const num2 = try b.appendNode(.{
        .tag = .number,
        .span = .{ .start = 0, .end = 0 },
        .data = .{ .immediate = @bitCast(@as(f64, 2)) },
    });
    const num3 = try b.appendNode(.{
        .tag = .number,
        .span = .{ .start = 0, .end = 0 },
        .data = .{ .immediate = @bitCast(@as(f64, 3)) },
    });
    const vec = try b.addVector(&.{ num2, num3 }, .{ .start = 0, .end = 0 });
    const head_si = try b.addString("scene");
    const form = try b.addForm(head_si, null, .{ .start = 0, .end = 0 }, &.{ num1, kv, vec }, .{ .start = 0, .end = 0 });

    const root_indices = try a.alloc(NodeIndex, 1);
    root_indices[0] = form;

    const tree = Tree{
        .arena = arena,
        .source = "",
        .nodes = b.nodes.toOwnedSlice(),
        .extra_data = b.extra_data.items,
        .strings = b.strings.items,
        .string_index = b.string_index.items,
        .root = root_indices,
        .leading_comments_index = b.leading_index.items,
        .trailing_comments_index = b.trailing_index.items,
        .comments = b.comments.toOwnedSlice(),
        .tree_trailing_comments = .empty,
        .diagnostics = &.{},
    };
    // Note: we intentionally do NOT call tree.deinit() here since the
    // arena is owned by this test scope and deinit'd on scope exit.
    _ = tree.arena;

    const printed = try Printer.print(testing.allocator, tree, .{});
    defer printed.deinit();
    try testing.expectEqualStrings("(scene 1 :bpm 130 [2 3])\n", printed.data);
}

test "TreeBuilder ergonomic appenders + finalize: round-trip via Printer" {
    const Printer = @import("Printer.zig");
    const Parser = @import("Parser.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();

    var b: TreeBuilder = .{ .a = arena.allocator() };

    // Build a form covering every ergonomic appender. The reference
    // print is whatever the parser produces from the equivalent source —
    // pinned via a Parser round-trip rather than a hand-coded string so
    // we don't bake the Printer's layout heuristics into the test.
    const num130 = try b.appendNumber(130, .{ .start = 0, .end = 0 });
    const kv_bpm = try b.appendKvpair("bpm", num130, .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 });
    const s_demo = try b.appendString("demo", .{ .start = 0, .end = 0 });
    const kv_title = try b.appendKvpair("title", s_demo, .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 });
    const b_on = try b.appendBoolean(true, .{ .start = 0, .end = 0 });
    const kv_on = try b.appendKvpair("on", b_on, .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 });
    const b_off = try b.appendBoolean(false, .{ .start = 0, .end = 0 });
    const kv_off = try b.appendKvpair("off", b_off, .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 });
    const nil_v = try b.appendNil(.{ .start = 0, .end = 0 });
    const kv_z = try b.appendKvpair("z", nil_v, .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 });
    const sym_main = try b.appendSymbol("main", .{ .start = 0, .end = 0 });
    const kv_tag = try b.appendKvpair("tag", sym_main, .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 });
    const n1 = try b.appendNumber(1, .{ .start = 0, .end = 0 });
    const n2 = try b.appendNumber(2, .{ .start = 0, .end = 0 });
    const v12 = try b.appendVector(&.{ n1, n2 }, .{ .start = 0, .end = 0 });

    const form = try b.appendForm(
        "scene",
        null,
        .{ .start = 0, .end = 0 },
        &.{ kv_bpm, kv_title, kv_on, kv_off, kv_z, kv_tag, v12 },
        .{ .start = 0, .end = 0 },
    );

    var tree = try b.finalize(&arena, "", &.{form});
    defer tree.deinit();

    const printed = try Printer.print(testing.allocator, tree, .{});
    defer printed.deinit();

    // Cross-check: parsing the same content and printing it produces the
    // same bytes. The Printer's canonical layout is whatever it is —
    // we're pinning equivalence, not a literal format.
    const src: [:0]const u8 =
        "(scene :bpm 130 :title \"demo\" :on true :off false :z nil :tag main [1 2])";
    var parsed = try Parser.parse(testing.allocator, src);
    defer parsed.deinit();
    const parsed_printed = try Printer.print(testing.allocator, parsed, .{});
    defer parsed_printed.deinit();
    try testing.expectEqualStrings(parsed_printed.data, printed.data);
}

test "TreeBuilder ergonomic appenders: keyword + qualified form head" {
    const Printer = @import("Printer.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();

    var b: TreeBuilder = .{ .a = arena.allocator() };

    // (masagin/verb :mode :loop)
    const kw_loop = try b.appendKeyword("loop", .{ .start = 0, .end = 0 });
    const kv_mode = try b.appendKvpair("mode", kw_loop, .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 });
    const form = try b.appendForm(
        "verb",
        "masagin",
        .{ .start = 0, .end = 0 },
        &.{kv_mode},
        .{ .start = 0, .end = 0 },
    );

    var tree = try b.finalize(&arena, "", &.{form});
    defer tree.deinit();

    const printed = try Printer.print(testing.allocator, tree, .{});
    defer printed.deinit();
    try testing.expectEqualStrings("(masagin/verb :mode :loop)\n", printed.data);
}

test "TreeBuilder.finalize: validates via the existing validator" {
    // Spot-check that a synthesized tree walks through Validator.validate
    // without panicking. Validation against an empty schema produces
    // unknown_form, which is fine — we only care that the walk is well-
    // formed (lookups don't OOB, headers resolve, etc.).
    const Validator = @import("Validator.zig");
    const Schema = @import("Schema.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();

    var b: TreeBuilder = .{ .a = arena.allocator() };
    const num = try b.appendNumber(42, .{ .start = 0, .end = 0 });
    const kv = try b.appendKvpair("a", num, .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 });
    const form = try b.appendForm("sugar", null, .{ .start = 0, .end = 0 }, &.{kv}, .{ .start = 0, .end = 0 });

    var tree = try b.finalize(&arena, "", &.{form});
    defer tree.deinit();

    const schema: Schema.Schema = .{ .plugins = &.{} };
    var v = try Validator.validate(testing.allocator, tree, schema);
    defer v.deinit();
    // One diagnostic — unknown_form on `sugar` — confirms the walker
    // visited the synthesized head.
    var saw_unknown_form = false;
    for (v.diagnostics) |d| {
        if (d.code == .unknown_form) saw_unknown_form = true;
    }
    try testing.expect(saw_unknown_form);
}

test "Diagnostic.dupe: deep-copies message and path, survives source free" {
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    const sa = src_arena.allocator();
    const path = try sa.alloc([]const u8, 2);
    path[0] = try sa.dupe(u8, "alpha");
    path[1] = try sa.dupe(u8, "beta");
    const original: Diagnostic = .{
        .span = .{ .start = 1, .end = 4 },
        .message = try sa.dupe(u8, "boom"),
        .code = .unknown_form,
        .path = path,
    };

    var dst_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer dst_arena.deinit();
    const copy = try original.dupe(dst_arena.allocator());

    // Distinct storage: nothing in the copy aliases the source arena.
    try testing.expect(copy.message.ptr != original.message.ptr);
    try testing.expect(copy.path.ptr != original.path.ptr);
    try testing.expect(copy.path[0].ptr != original.path[0].ptr);
    try testing.expect(copy.path[1].ptr != original.path[1].ptr);

    // Free the source arena — the copy must remain intact (no dangle).
    src_arena.deinit();

    try testing.expectEqualStrings("boom", copy.message);
    try testing.expectEqual(@as(usize, 2), copy.path.len);
    try testing.expectEqualStrings("alpha", copy.path[0]);
    try testing.expectEqualStrings("beta", copy.path[1]);
    try testing.expectEqual(Diagnostic.Code.unknown_form, copy.code);
    try testing.expectEqual(original.span, copy.span);
    try testing.expectEqual(Diagnostic.Severity.err, copy.severity);
}
