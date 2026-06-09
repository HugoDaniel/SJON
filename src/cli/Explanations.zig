const std = @import("std");
const sjon = @import("sjon");
const Ast = sjon.Ast;

pub const Entry = struct {
    code: Ast.Diagnostic.Code,
    short: []const u8,
    long: []const u8 = "",
};

pub fn lookup(name: []const u8) ?Entry {
    for (table) |e| {
        if (std.mem.eql(u8, @tagName(e.code), name)) return e;
    }
    return null;
}

pub fn shortFor(code: Ast.Diagnostic.Code) []const u8 {
    for (table) |e| {
        if (e.code == code) return e.short;
    }
    return "";
}

pub fn all() []const Entry {
    return &table;
}

const table = [_]Entry{
    .{ .code = .unspecified, .short = "Generic catch-all when no more-specific code applies." },

    .{
        .code = .unknown_form,
        .short = "A form's head name is not declared by any loaded plugin.",
        .long =
        \\Forms must be declared by some plugin reachable from the document
        \\(either inlined as a `(plugin …)` declaration, or imported via
        \\`(use-plugin …)`). Qualified spellings (`<plugin>/<form>`) bypass
        \\ambiguity when two plugins declare the same name.
        \\
        \\If the head is a typo, the rich format suggests the nearest
        \\spelling under the loaded vocabulary. If the head exists in a
        \\plugin you forgot to import, the suggestion includes the import
        \\path.
        ,
    },
    .{
        .code = .unknown_local_form,
        .short = "Form head in a slot-local slot matches neither a local form nor any global form.",
        .long =
        \\A keyword slot may carry inline slot-local form definitions
        \\(`(key :name shape :type form (form …) (form …))`). A form value
        \\there resolves local-first: the local forms shadow same-named
        \\globals, and a head that isn't local still falls back to the
        \\global catalog (additive). Only when the head matches *neither* a
        \\local form *nor* any global form is this emitted — at the slot
        \\path (e.g. `[canvas shape]`), listing the allowed local heads. The
        \\generic `unknown_form` is suppressed for that node so you get one
        \\precise diagnostic, not two.
        \\
        \\A *qualified* head (`<plugin>/<form>`) bypasses the locals entirely
        \\and resolves against the global catalog only — so a typo'd
        \\qualified head yields `unknown_form`, not this.
        ,
    },
    .{ .code = .unknown_key, .short = "Form does not declare this `:keyword` and is not `:open true`." },
    .{ .code = .ambiguous_form, .short = "Two plugins declare a form with the same bare head — qualify the spelling." },
    .{ .code = .ambiguous_expr, .short = "Two plugins declare an expression with the same name — qualify the spelling." },
    .{ .code = .ambiguous_element_kind, .short = "Element kind reference matches multiple plugin-declared kinds." },
    .{ .code = .unknown_element_kind, .short = "Element kind name resolves to no plugin." },
    .{ .code = .recursion_depth, .short = "Validator's depth ceiling exceeded — the input is pathologically nested." },
    .{ .code = .not_cross_ref, .short = "Slot accepts a cross-ref but the value's value-kind has no `(cross-ref …)` refinement." },
    .{ .code = .duplicate_cross_ref_target, .short = "Two forms share the same `:name` value within one cross-ref's target scope." },
    .{ .code = .unknown_cross_ref_target, .short = "Cross-ref symbol does not match any declared `:name` in the target scope." },
    .{ .code = .ambiguous_cross_ref_target, .short = "Cross-ref symbol matches multiple targets — typically a name collision under scopes." },
    .{ .code = .cross_ref_name_key_unknown, .short = "The `:name-key` declared on a `(cross-ref …)` is not a key on the target form." },
    .{ .code = .acyclic_without_self_edge, .short = "`(cross-ref … :acyclic true)` declared on a kind that can't form cycles." },
    .{ .code = .cyclic_cross_ref, .short = "Acyclic cross-ref forms a cycle — at least one edge must be removed." },
    .{ .code = .unknown_cross_ref_scope, .short = "Cross-ref `:scope` is not a known form name." },
    .{ .code = .ambiguous_cross_ref_scope, .short = "Cross-ref `:scope` matches multiple form names; qualify the spelling." },
    .{ .code = .cross_ref_outside_scope, .short = "Cross-ref references a target outside the enclosing scope's instance." },

    .{ .code = .duplicate_key, .short = "Same `:key` appears twice on the same form." },
    .{ .code = .too_many_keys, .short = "Form has more keyword slots than `Plugin.MAX_FORM_KEYS` permits." },
    .{ .code = .missing_required_key, .short = "Form omits a `:key :optional false` slot with no default." },
    .{ .code = .positional_not_allowed, .short = "Form's `:positional` declaration is `none` but a positional child was provided." },
    .{ .code = .expr_kvpair_not_allowed, .short = "Expression function does not opt into labeled-call form (`:param-names`)." },
    .{ .code = .missing_discriminant_key, .short = "Discriminated form lacks the discriminant key." },
    .{ .code = .unknown_discriminant_value, .short = "Discriminant's value is not a member of its declared enum." },
    .{ .code = .discriminant_not_closed_enum, .short = "Discriminant key's value-kind does not declare a closed `(member-set …)`." },
    .{ .code = .variant_key_collision, .short = "Variant declares a key that already lives on the form's common keys." },
    .{ .code = .mutually_exclusive_keys_present, .short = "Multiple alternatives of an exclusive group are present at once." },
    .{ .code = .multiple_defaulted_alternatives_in_group, .short = "Exclusive group has more than one alternative with a `:default`." },
    .{ .code = .required_one_of_missing, .short = "`exactly-one` exclusive group has zero alternatives present." },
    .{ .code = .exclusive_group_invalid, .short = "Exclusive group declaration is malformed (overlapping alts, missing keys, …)." },

    .{ .code = .wrong_underlying, .short = "Value's structural shape does not match the declared `:underlying`." },
    .{ .code = .vector_length_mismatch, .short = "Vector value does not match the declared `:vector :len`." },
    .{ .code = .vector_too_short, .short = "Vector has fewer elements than the declared `:vector :min-len`." },
    .{ .code = .vector_too_long, .short = "Vector has more elements than the declared `:vector :max-len`." },
    .{ .code = .vector_bounds_invalid, .short = "`(vector-shape …)` declaration is internally inconsistent (`:len` with a range, or `:min-len` > `:max-len`)." },
    .{ .code = .unit_required, .short = "Number value lacks a unit but the kind requires one." },
    .{ .code = .unit_not_allowed, .short = "Number value carries a unit but the kind's `:allowed` list rejects it." },
    .{ .code = .unit_forbidden, .short = "Number value carries a unit but the kind's `:unit (unit-shape :reject true)` demands bare numbers." },
    .{ .code = .not_member, .short = "Closed `(member-set …)` does not include this value." },
    .{ .code = .deprecated_member, .short = "Member is declared `:deprecated true` — accepted, but the LSP marks it deprecated." },
    .{ .code = .not_head_member, .short = "Form's head is not in the kind's `(head-set …)` whitelist." },
    .{ .code = .not_flag_member, .short = "Positional keyword flag is not in the form's `:positional (flag-set …)` set." },
    .{ .code = .duplicate_positional_flag, .short = "A declared positional keyword flag is repeated on one form, e.g. `(task :done :done)`." },
    .{ .code = .union_no_branch_matched, .short = "No alternative in a `(union-shape …)` accepted the value." },
    .{ .code = .nested_union, .short = "Union alternative resolves to another union — flatten the alternatives." },

    .{ .code = .arity_mismatch, .short = "Expression function called with the wrong number of arguments." },
    .{ .code = .expr_type_mismatch, .short = "Expression argument's type does not satisfy the function's `:params` declaration." },
    .{ .code = .expr_unknown_label, .short = "Labeled-call kvpair key does not match any declared `:param-names`." },
    .{ .code = .expr_duplicate_label, .short = "Labeled call supplies the same label twice." },
    .{ .code = .expr_missing_label, .short = "Labeled call omits a declared parameter." },
    .{ .code = .expr_mixed_args, .short = "Call mixes positional and labeled arguments — pick one form." },

    .{ .code = .invalid_manifest, .short = "Manifest source failed to load (read error, malformed shape, etc.)." },

    .{
        .code = .unresolved_plugin,
        .short = "A `(use-plugin …)` reference's name is not in the project file.",
        .long =
        \\The host walks references in document order. For each, it asks
        \\the resolver to produce manifest bytes. The default
        \\`FilesystemResolver` consults the project file's `:plugins`
        \\index — if the bare name is missing, this code fires.
        \\
        \\Two ways out: add the manifest to `sjon-project.sjon`'s
        \\`:plugins` (preferred for reusable plugins), or use the
        \\`(use-plugin "name" :path "…")` shape to point the resolver at
        \\an explicit file (preferred for one-off includes).
        ,
    },
    .{ .code = .plugin_version_mismatch, .short = "`(use-plugin … :version …)` pin disagrees with the manifest's `:version`." },
    .{
        .code = .plugin_hash_mismatch,
        .short = "`(use-plugin … :hash …)` pin does not match the resolved wasm bytes.",
        .long =
        \\Hash pins are sha256 digests of the paired wasm binary,
        \\formatted as `sha256-<64 lowercase hex>`. Use them to ensure
        \\reproducibility against a specific build of a plugin.
        \\
        \\Compute the current digest with `sjon plugin hash <wasm>`;
        \\update the pin if the new bytes are intentional, or fetch the
        \\old binary if they aren't.
        ,
    },

    .{ .code = .duplicate_plugin_name, .short = "Two manifests in the project's `:plugins` index declare the same `:name`." },
    .{ .code = .plugin_name_mismatch, .short = "Resolved manifest's `:name` differs from the `(use-plugin …)` name." },
    .{ .code = .project_file_not_found, .short = "`sjon-project.sjon` not found at the requested or discovered root." },

    .{ .code = .plugin_abi_mismatch, .short = "Plugin wasm reports a `sjon_plugin_abi_version()` the host does not implement." },
    .{ .code = .plugin_export_missing, .short = "Manifest references a `:impl wasm:<name>` export the wasm binary does not define." },
    .{ .code = .plugin_import_forbidden, .short = "Plugin wasm imports a forbidden host symbol — ABI v2 plugins are pure." },
    .{ .code = .plugin_wasm_required, .short = "Manifest declares `:impl wasm:…` but the resolver returned no wasm bytes." },
    .{ .code = .plugin_describe_invalid, .short = "`sjon_plugin_describe()` output is malformed or inconsistent with the manifest." },
    .{ .code = .plugin_func_trapped, .short = "Plugin export trapped during invocation (unreachable, OOB memory, etc.)." },
    .{ .code = .plugin_func_result_type, .short = "Plugin export's return value's tag mismatches the manifest's declared `:result`." },
    .{ .code = .plugin_func_failed, .short = "Plugin export returned an error status — runtime semantic failure." },
    .{ .code = .plugin_func_alloc_failed, .short = "Plugin allocation hook (`sjon_alloc`) returned null." },

    .{ .code = .default_eval_failed, .short = "Expression-shaped `:default` failed at evaluation time." },

    .{ .code = .lowering_hook_missing, .short = "Host has no implementation registered for the `:lowering :hook` named by the manifest." },
    .{ .code = .lowering_hook_failed, .short = "Lowering hook returned an error or invalid output." },
    .{ .code = .lowering_produced_invalid_head, .short = "Lowering output's form head is not in the manifest's `:produces` whitelist." },
    .{ .code = .lowering_produced_lowerable_head, .short = "Lowering output's form head is itself a surface — lowering must terminate." },
    .{ .code = .lowering_output_too_large, .short = "Lowering output exceeded one of `MAX_LOWERED_FORMS` / `MAX_LOWERED_DEPTH` / `MAX_LOWERED_BYTES`." },
    .{
        .code = .lowering_cycle,
        .short = "A `:lowering :produces` graph cycles — following produces-edges leads back to a lowering form.",
        .long =
        \\Staged lowering follows `:produces` edges: a form's lowering hook
        \\emits forms whose heads are listed in `:produces`, and those forms
        \\may themselves be lowerable. The aggregate schema check builds this
        \\graph (nodes = lowering forms, edges = their `:produces` heads) and
        \\rejects any cycle, so staging is guaranteed to terminate before a
        \\single hook runs.
        \\
        \\Break the cycle: a chain like `a -> b -> a` means following the
        \\produces declarations loops forever. Re-point one `:produces` edge
        \\at a terminal (non-lowering) form, or drop the `:lowering` on one of
        \\the forms in the loop.
        ,
    },
    .{
        .code = .lowering_target_plugin_absent,
        .short = "A `:lowering :produces` head names a plugin that isn't loaded — a dangling cross-plugin edge.",
        .long =
        \\A `:produces` entry spelled `<plugin>/<form>` resolves against the
        \\loaded aggregate. When the named plugin is present but lacks the
        \\form you get `unknown_form`; when the plugin itself was never
        \\loaded, the edge dangles on load order rather than on a typo, and
        \\that is reported separately as `lowering_target_plugin_absent`.
        \\
        \\Fix it by loading the target plugin (add the missing `(use-plugin
        \\…)` / dependency) or by re-pointing the `:produces` entry at a form
        \\that the current plugin set actually declares.
        ,
    },
    .{
        .code = .lowering_nested_lowerable,
        .short = "A `:lowering` form is a positional child of another `:lowering` form — container and child can't both lower.",
        .long =
        \\Container lowering puts `:lowering` on a container and leaves its
        \\children plain data: the one hook invocation consumes every child at
        \\once. If a child *also* declares `:lowering`, both hooks fire in the
        \\same layer — the container consumes the child while the child lowers
        \\itself — and their output overlaps or orphans (often surfacing later
        \\as a confusing `duplicate_cross_ref_target`).
        \\
        \\Fix it by declaring `:lowering` on the container OR the child, never
        \\both. In container lowering the children stay data; only the
        \\container lowers. The check is emit-only, so lowering still runs — the
        \\diagnostic just names the contradiction at the child.
        ,
    },

    .{ .code = .number_overflow_exact_integer, .short = "Integer literal exceeds u64 — falls back to f64 with precision loss." },
    .{ .code = .date_invalid_year, .short = "Date year `0000` rejected (ISO 8601 disallows year 0)." },
    .{ .code = .date_invalid_month, .short = "Date month outside `[1, 12]`." },
    .{ .code = .date_invalid_day, .short = "Date day outside the month's valid range." },
    .{ .code = .time_invalid_hour, .short = "Time hour outside `[0, 23]`." },
    .{ .code = .time_invalid_minute, .short = "Time minute outside `[0, 59]`." },
    .{ .code = .time_invalid_second, .short = "Time second outside `[0, 59]` (no leap seconds)." },

    .{ .code = .number_below_min, .short = "Number value below inclusive `:min`." },
    .{ .code = .number_above_max, .short = "Number value above inclusive `:max`." },
    .{ .code = .number_at_or_below_exclusive_min, .short = "Number value ≤ `:min` when `:exclusive-min true`." },
    .{ .code = .number_at_or_above_exclusive_max, .short = "Number value ≥ `:max` when `:exclusive-max true`." },
    .{ .code = .number_not_integer, .short = "Value violates `:integer true` (fractional or non-finite)." },
    .{ .code = .numeric_bound_unit_mismatch, .short = "Bound carries a unit but the validated value does not match it." },
    .{ .code = .numeric_bounds_invalid, .short = "`(numeric-bounds …)` declaration is internally inconsistent." },
    .{ .code = .repr_out_of_range, .short = "Number value does not fit its value-kind's `:repr` GPU type (out of range, or non-integral under `u16`/`u32`/`i32`)." },

    .{ .code = .string_too_short, .short = "String shorter than `:min-len` UTF-8 codepoints." },
    .{ .code = .string_too_long, .short = "String longer than `:max-len` UTF-8 codepoints." },
    .{ .code = .string_format_mismatch, .short = "String value fails the declared `:format` (email/uri/path/uuid/semver)." },
    .{ .code = .string_pattern_mismatch, .short = "String value fails the declared `:pattern` (regex)." },
    .{ .code = .string_pattern_unsupported, .short = "Host build has no regex engine; the `:pattern` is stored but not checked." },
    .{ .code = .string_bounds_invalid, .short = "`(string-bounds …)` declaration is internally inconsistent." },

    .{ .code = .exclusive_bundle_partial, .short = "Multi-key bundle in an exclusive group is partially present." },
    .{ .code = .exclusive_bundle_collision, .short = "Same key appears in two alternatives of the same exclusive group." },

    .{
        .code = .plugin_wasm_resolved_outside_package,
        .short = "Manifest's `:wasm-file` resolves outside its own directory.",
        .long =
        \\The override is checked lexically against the manifest's
        \\directory — any `..` segments that walk above the directory
        \\boundary are rejected, as are absolute paths. The check uses
        \\lexical normalization (no realpath) so symlink hops are not
        \\caught; the goal is honest path-traversal blocking, not full
        \\filesystem containment.
        ,
    },
    .{ .code = .plugin_wasm_self_hash_malformed, .short = "`:wasm-sha256` is not in the canonical `sha256-<64 lowercase hex>` shape." },
    .{ .code = .plugin_wasm_self_hash_mismatch, .short = "Manifest's `:wasm-sha256` stamp disagrees with the bytes on disk." },
    .{ .code = .license_unrecognized, .short = "Advisory: `:license` is not a canonical SPDX identifier." },
    .{ .code = .too_many_keywords, .short = "Advisory: `:keywords` exceeds the soft cap of 16 entries." },
    .{ .code = .sjon_format_unsupported, .short = "Manifest declares a `:sjon` version newer than this host implements." },

    .{ .code = .unknown_project_key, .short = "Advisory: project file declared a top-level key the host doesn't recognize." },
    .{ .code = .glob_no_matches, .short = "Advisory: a `:documents` pattern matched zero files." },
    .{ .code = .pin_disagreement, .short = "Project `(plugin-entry … :version/:hash)` pin disagrees with a `(use-plugin …)` pin." },
    .{ .code = .project_documents_outside_root, .short = "`:documents` glob resolves outside the project root." },

    .{
        .code = .lockfile_drift,
        .short = "Lockfile entry's hash disagrees with the on-disk bytes.",
        .long =
        \\`sjon-project.lock` records the observed sha256 of each
        \\plugin's manifest and (optionally) its paired wasm. When
        \\`sjon project verify` (or any `sjon check` against a project
        \\with a lockfile) sees a hash that differs from the recorded
        \\one, it emits this code.
        \\
        \\Two ways out: `sjon project lock` to record the new bytes
        \\(if the change is intentional), or restore the old plugin
        \\bytes (if the change is accidental).
        ,
    },
    .{ .code = .lockfile_missing_entry, .short = "Project references a plugin the lockfile does not record." },
    .{ .code = .lockfile_orphan, .short = "Advisory: lockfile entry is no longer referenced by the project." },
    .{ .code = .lockfile_version_unsupported, .short = "Lockfile `:version` exceeds this host's understanding." },
    .{ .code = .lockfile_corrupt, .short = "Lockfile failed to parse or has the wrong top-level shape." },
};

const testing = std.testing;
