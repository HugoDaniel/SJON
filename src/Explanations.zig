//! Long-form explanations for every `Ast.Diagnostic.Code` variant.
//!
//! Surfaced by `sjon explain CODE` and the `help:` footer in rich
//! diagnostics. Every code in the wire-stable enum has an entry; the
//! audit test below enforces it — a new code without an entry fails
//! `zig build test`.
//!
//! Memory: the table holds only string literals — no allocations,
//! no per-call buffers.

const std = @import("std");
const Ast = @import("Ast.zig");

pub const Entry = struct {
    code: Ast.Diagnostic.Code,
    /// One-line summary. Always present.
    short: []const u8,
    /// Multi-paragraph body. May be empty when the short summary
    /// suffices — codes whose semantics are non-obvious (cross-refs,
    /// exclusive groups, pin protocols) get richer bodies.
    long: []const u8 = "",
};

/// Look up an entry by name (e.g. `"unresolved_plugin"`). Returns null
/// when the name is unknown — the CLI uses this for both `sjon explain
/// foo` typo handling and for the `--list` walker.
///
/// Two steps, and the split is the point: the *name* half is
/// `stringToEnum`, which is the codified idiom for resolving a closed
/// name set (the previous linear `@tagName` compare was a third idiom
/// for the same problem); the *entry* half is a comptime index, so an
/// unknown name is `null` and a known code is total.
pub fn lookup(name: []const u8) ?Entry {
    const code = std.meta.stringToEnum(Ast.Diagnostic.Code, name) orelse return null;
    return byCode(code);
}

/// The entry for `code`. Total — every variant has one, proven at
/// compile time by `by_code` below.
pub fn byCode(code: Ast.Diagnostic.Code) Entry {
    return by_code[@intFromEnum(code)];
}

/// `Code` ordinal → entry, built once at compile time.
///
/// Building it *is* the completeness check, which is the part worth
/// having: a code with no entry, or two entries for one code, is now a
/// compile error naming the code, rather than a test failure — and the
/// audit test below (which predates this) becomes a second opinion
/// instead of the only one. Adding a `Diagnostic.Code` variant without
/// its explanation stops the build in the same commit that adds it.
const by_code = blk: {
    const fields = @typeInfo(Ast.Diagnostic.Code).@"enum".fields;
    var slots: [fields.len]?Entry = @splat(null);
    for (table) |e| {
        const i = @intFromEnum(e.code);
        if (slots[i] != null) @compileError("duplicate explanation entry for `" ++ @tagName(e.code) ++ "`");
        slots[i] = e;
    }
    var out: [fields.len]Entry = undefined;
    for (&out, slots, fields) |*slot, filled, f| {
        slot.* = filled orelse @compileError("missing explanation for `" ++ f.name ++ "`");
    }
    break :blk out;
};

/// Slice over every entry — used by `sjon explain --list` and the
/// audit step.
pub fn all() []const Entry {
    return &table;
}

/// Base of the published diagnostic catalogue. The pages under it are
/// generated from this table by `zig build gen-explanations`, so the
/// set of valid slugs and the set of `Code` variants are the same set
/// by construction.
///
/// Hardcoding the project's own docs host is deliberate — nothing in
/// the LSP protocol (or the CLI) lets a consumer learn a documentation
/// URL from elsewhere, and a configurable base would be a setting with
/// no second correct value.
pub const DOCS_BASE = "https://hugodaniel.com/pages/sjon/errors";

/// The documentation URL for `code`. Total — every variant has a page —
/// and allocation-free: `inline else` makes `@tagName(c)` comptime, so
/// each arm returns a string literal built at compile time.
pub fn codeHref(code: Ast.Diagnostic.Code) []const u8 {
    return switch (code) {
        inline else => |c| DOCS_BASE ++ "/" ++ @tagName(c),
    };
}

const table = [_]Entry{
    .{ .code = .unspecified, .short = "Generic catch-all when no more-specific code applies." },

    // --- Resolution
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
        \\A slot may carry inline slot-local form definitions on either a
        \\keyword (`(key :name shape :type form (form …) (form …))`) or a
        \\form's positional slot (inline `(form …)` children directly under
        \\the parent `(form …)`). A form value in that slot resolves
        \\local-first: the local forms shadow same-named globals, and a head
        \\that isn't local still falls back to the global catalog (additive).
        \\Only when the head matches *neither* a local form *nor* any global
        \\form is this emitted — at the slot path: the key path for a keyword
        \\slot (e.g. `[canvas shape]`) or the parent form's path for a
        \\positional slot (e.g. `[canvas]`), listing the allowed local heads.
        \\The generic `unknown_form` is suppressed for that node so you get one
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
    .{ .code = .not_cross_ref, .short = "Symbol is not a registered name for the cross-ref's target — no target instance declares (or provides) it." },
    .{ .code = .duplicate_cross_ref_target, .short = "Two forms share the same `:name` value within one cross-ref's target scope." },
    .{ .code = .unknown_cross_ref_target, .short = "The `:target` declared on a `(cross-ref …)` resolves to no form in the aggregated schema." },
    .{ .code = .ambiguous_cross_ref_target, .short = "Cross-ref symbol matches multiple targets — typically a name collision under scopes." },
    .{ .code = .cross_ref_name_key_unknown, .short = "The `:name-key` declared on a `(cross-ref …)` is not a key on the target form." },
    .{ .code = .acyclic_without_self_edge, .short = "`(cross-ref … :acyclic true)` declared on a kind that can't form cycles." },
    .{ .code = .cyclic_cross_ref, .short = "Acyclic cross-ref forms a cycle — at least one edge must be removed." },
    .{ .code = .unknown_cross_ref_scope, .short = "Cross-ref `:scope` is not a known form name." },
    .{ .code = .ambiguous_cross_ref_scope, .short = "Cross-ref `:scope` matches multiple form names; qualify the spelling." },
    .{ .code = .cross_ref_outside_scope, .short = "Cross-ref references a target outside the enclosing scope's instance." },
    .{
        .code = .unknown_cross_ref_provider,
        .short = "Cross-ref `:provider` names an extractor no loaded plugin declares.",
        .long =
        \\A `(cross-ref :provider p …)` draws its member set from a
        \\`(cross-ref-provider :name p …)` declared by some plugin. This
        \\fires when no loaded plugin declares `p`.
        \\
        \\Usual causes: the plugin that declares the provider is missing
        \\from `:plugins`, or the name is misspelled. Providers live in
        \\their own catalog, so an expression function or form of the same
        \\name does not satisfy the reference.
        ,
    },
    .{
        .code = .ambiguous_cross_ref_provider,
        .short = "Bare cross-ref `:provider` name is declared by two or more plugins — qualify the spelling.",
        .long =
        \\Two loaded plugins declare a provider with the same bare name,
        \\so `:provider uniforms` cannot pick one. Qualify it with the
        \\owning plugin: `:provider glsl/uniforms`.
        \\
        \\Same rule the other bare-or-qualified vocabularies follow —
        \\forms, expression functions, and value kinds all resolve bare
        \\names only when exactly one plugin claims them.
        ,
    },
    .{
        .code = .cross_ref_source_key_unknown,
        .short = "The `:source-key` declared on a provider-route `(cross-ref …)` is not a string-typed key on the target form.",
        .long =
        \\A provider-route cross-ref reads the string under `:source-key`
        \\from each `:target` instance and hands it to the provider. This
        \\fires when the target form declares no such key, or declares it
        \\with a type that is not string-shaped — either way no instance
        \\could ever supply the provider with anything, so the member set
        \\would silently be empty.
        \\
        \\`:source-key` defaults to `src`; declare the key on the target
        \\form, or point `:source-key` at the key that actually holds the
        \\content.
        ,
    },
    .{
        .code = .cross_ref_extraction_failed,
        .short = "A cross-ref provider ran against this source and rejected it, so the set of valid names here is unknown.",
        .long =
        \\The names this cross-ref accepts are extracted from the string
        \\under `:source-key` by the declared provider. The provider ran
        \\and reported a failure — usually the content itself doesn't
        \\parse, and the message carries the provider's own explanation.
        \\
        \\Because no member set could be computed, references into this
        \\target are *not* checked: fixing the source restores checking.
        \\That is why one broken source produces one diagnostic here
        \\rather than an "unknown name" error at every reference site.
        ,
    },
    .{
        .code = .cross_ref_provider_unavailable,
        .short = "The provider backing this cross-ref could not be run, so the set of valid names here is unknown.",
        .long =
        \\Unlike `cross_ref_extraction_failed`, the provider never ran at
        \\all. The usual causes are host-side, not document-side: the
        \\declaring plugin was loaded without an executable runtime, its
        \\WASM module doesn't export the function the manifest's `:impl`
        \\names, or this build has plugin execution compiled out.
        \\
        \\As with a failed extraction the target is left unchecked rather
        \\than reported as empty, so a host that cannot execute plugins
        \\validates everything else about the document and stays silent
        \\about member names it has no way to know.
        ,
    },
    .{
        .code = .cross_ref_target_collapse,
        .short = "Two value-kinds cross-reference the same form but disagree on how its member set is built — the first one declared wins.",
        .long =
        \\A target form's member set is collected once, not once per
        \\referring value-kind. When two `(cross-ref …)` declarations name
        \\the same target and differ — one reads a `:name-key`, the other
        \\runs a `:provider`; or they name different keys, providers, or
        \\`:scope` forms — the first in plugin × value-kind order builds
        \\the set and the second's declaration has no effect. References
        \\through the losing kind are still checked, but against the
        \\winner's names.
        \\
        \\Two kinds that declare the *same* spec on one target are fine and
        \\stay silent: that is ordinary aliasing, and both agree on what
        \\the members are. To fix a real disagreement, give the kinds
        \\distinct `:target` forms, or make the two declarations match.
        ,
    },

    // --- Form shape
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
    .{
        .code = .dependent_key_missing,
        .short = "A key that is present requires sibling keys that are absent.",
        .long =
        \\A key declared as `(key :name offset … :requires [buffer])` may only
        \\appear alongside the keys it names. Writing `:offset` without
        \\`:buffer` fires this; writing neither is fine, because the rule only
        \\applies once the dependent key is present.
        \\
        \\The message lists every absent requirement at once, so a key with
        \\three unmet dependencies produces one diagnostic naming three, not
        \\three separate complaints.
        \\
        \\Two repairs. Supply the keys it names — usually right, since the
        \\dependent key is typically meaningless without them (a `:offset`
        \\into no buffer describes nothing). Or drop the dependent key, if it
        \\was written by mistake.
        \\
        \\**Which of the three mechanisms is this?** A form has three ways to
        \\relate keys, and picking the wrong one is the common mistake:
        \\
        \\  * `:requires` — presence implies presence. "If `:offset` is here,
        \\    `:buffer` must be too." One-directional; the reverse is fine.
        \\  * `(exclusive-group …)` — bounds *how many* of a set may appear.
        \\    "At most one of `:color` / `:gradient`." Symmetric.
        \\  * `(variant …)` — gates keys on another key's **value**, not its
        \\    presence. "`:strip-index-format` applies only when `:topology`
        \\    is `triangle-strip`."
        \\
        \\If your rule mentions a specific value, you want a variant. If it
        \\counts, you want a group. If it says "then also", you want this.
        ,
    },

    // --- Types
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
    .{
        .code = .positional_too_many,
        .short = "More positional children carry this head than the `(head-set …)` entry's `:max` allows.",
        .long =
        \\A `(head-set …)` says which heads a positional slot accepts. A
        \\`(head …)` entry inside one can also say **how many**:
        \\
        \\```
        \\(value-kind :name pipeline-section :underlying form
        \\  :heads (head-set
        \\    (head :name vertex   :min 1 :max 1)
        \\    (head :name fragment :max 1)
        \\    (head :name constant)))
        \\```
        \\
        \\`vertex` exactly once, `fragment` at most once, `constant` any
        \\number of times. A second `(fragment …)` under a form whose
        \\`:positional` is that kind reports here.
        \\
        \\The diagnostic lands on the child that crosses the ceiling, not
        \\on the parent, so the squiggle is on the line to delete. You get
        \\one per form regardless of how far over you went — the crossing
        \\child names the real count, so the message stays honest without
        \\repeating itself down the rest of the list.
        \\
        \\Two ways to fix it, and which one is right depends on what you
        \\meant. Delete or merge the extra child, if the duplicate was a
        \\mistake. Or raise the bound in the manifest, if the schema was
        \\stricter than the domain.
        \\
        \\`:open true` does not silence this. Openness widens which
        \\*keywords* a form accepts; it says nothing about its positional
        \\children, and the neighbouring positional rules
        \\(`not_head_member`, `duplicate_positional_flag`) fire on open
        \\forms too.
        \\
        \\Bounds count only at a form's `:positional` slot. The same kind
        \\reused on a `(key …)` slot or as a `vector-shape :element` carries
        \\them inertly — a keyed slot holds one value, and a vector element
        \\is a value rather than a child list.
        ,
    },
    .{
        .code = .positional_missing,
        .short = "Fewer positional children carry this head than the `(head-set …)` entry's `:min` requires.",
        .long =
        \\The floor half of a `(head …)` count bound. Given
        \\`(head :name vertex :min 1)` on the kind a form's `:positional`
        \\names, a form with no `(vertex …)` child reports here.
        \\
        \\It is an end-of-children fact — you cannot know a head is absent
        \\until the children run out — so it lands at the parent form's
        \\head with the parent's path, exactly where `missing_required_key`
        \\lands and for the same reason: there is no child to point at. One
        \\diagnostic per unsatisfied head, each naming the head, the floor,
        \\and what was actually found.
        \\
        \\The repair is to add the missing child, or to lower `:min` if the
        \\schema was stricter than the domain. `:min 0` (the default) means
        \\the head is allowed but not required.
        \\
        \\`:open true` does not silence this either, which makes it the one
        \\end-of-form sweep openness leaves alone. Every other one —
        \\required keys, the discriminant gate, exclusive groups, key
        \\dependencies — is about *keywords*, and that is the surface
        \\`:open` widens. Positional children are a different surface, and
        \\declaring `:positional <bounded-kind>` opts into their count.
        ,
    },
    .{ .code = .not_flag_member, .short = "Positional keyword flag is not in the form's `:positional (flag-set …)` set." },
    .{ .code = .duplicate_positional_flag, .short = "A declared positional keyword flag is repeated on one form, e.g. `(task :done :done)`." },
    .{ .code = .union_no_branch_matched, .short = "No alternative in a `(union-shape …)` accepted the value." },
    .{ .code = .nested_union, .short = "Union alternative resolves to another union — flatten the alternatives." },
    .{
        .code = .union_ambiguous,
        .short = "A name is registered by two cross-ref alternatives of one union, so declaration order decides which.",
        .long =
        \\A warning, not an error. The document validates and the union's
        \\rule is unchanged: alternatives are tried in declaration order and
        \\the first one that accepts wins. What this reports is that a
        \\*second* reading exists.
        \\
        \\Given a union of two reference kinds:
        \\
        \\```
        \\(value-kind :name pipeline-ref :underlying union
        \\  :union (union-shape :alternatives [render-pipeline-ref compute-pipeline-ref]))
        \\```
        \\
        \\a document that names both a `(render-pipeline :name same)` and a
        \\`(compute-pipeline :name same)` makes `(dispatch :pipeline same)`
        \\resolvable two ways. Neither declaration is a duplicate —
        \\duplicate detection is per-target, and these are different targets
        \\— so nothing else complains.
        \\
        \\Why that is worth a warning: SJON picks by alternative order, and
        \\a consumer that resolves the same reference through its own table
        \\may well pick by something else. Two mechanisms, two answers, and
        \\the disagreement is silent. Order is doing work the author never
        \\chose.
        \\
        \\Two repairs. Rename one of the declarations, which is right when
        \\the collision was an accident. Or split the slot into two keys
        \\with one reference kind each, which is right when both entities
        \\legitimately keep the name and the *slot* was overloaded.
        \\
        \\It stays quiet in the cases where order is the design. A union
        \\like `[byte-count symbol]` overlaps on purpose and names no
        \\entity, so nothing warns. Nor does a union whose winning
        \\alternative is a plain member set — the slot then denotes a
        \\member, not a reference. Only two *references* to differently-named
        \\entities trip it.
        ,
    },

    // --- Expressions
    .{ .code = .arity_mismatch, .short = "Expression function called with the wrong number of arguments." },
    .{
        .code = .expr_type_mismatch,
        .short = "Expression argument's type does not satisfy the function's `:params` declaration.",
        .long =
        \\Two failures share this code, and the message tells them apart.
        \\
        \\The static one is the declared-type check: an argument whose
        \\type does not satisfy the head's `:params` / `:rest`. It is
        \\anchored at the offending argument and names it by path
        \\(`sqrt/0`).
        \\
        \\The runtime one fires when the types are fine but an evaluated
        \\*value* falls outside the function's domain — `(clamp 5 10 0)`
        \\with lo above hi, `(nth [1 2 3] 9)` past the end,
        \\`(normalize [0 0])` with no direction, `(/ 1 0)`. The validator
        \\cannot reach these: it knows what a slot declares, not what an
        \\expression computes. They are anchored at the form's head with
        \\no path, and the form yields no value while its neighbours keep
        \\evaluating.
        ,
    },
    .{ .code = .expr_unknown_label, .short = "Labeled-call kvpair key does not match any declared `:param-names`." },
    .{ .code = .expr_duplicate_label, .short = "Labeled call supplies the same label twice." },
    .{ .code = .expr_missing_label, .short = "Labeled call omits a declared parameter." },
    .{ .code = .expr_mixed_args, .short = "Call mixes positional and labeled arguments — pick one form." },

    // --- Manifest load (D0)
    .{ .code = .invalid_manifest, .short = "Manifest source failed to load (read error, malformed shape, etc.)." },

    // --- Plugin resolution (D0)
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

    // --- Project resolution (D3)
    .{ .code = .duplicate_plugin_name, .short = "Two manifests in the project's `:plugins` index declare the same `:name`." },
    .{ .code = .plugin_name_mismatch, .short = "Resolved manifest's `:name` differs from the `(use-plugin …)` name." },
    .{ .code = .project_file_not_found, .short = "`sjon-project.sjon` not found at the requested or discovered root." },

    // --- Plugin runtime (D7)
    .{ .code = .plugin_abi_mismatch, .short = "Plugin wasm reports a `sjon_plugin_abi_version()` the host does not implement." },
    .{ .code = .plugin_export_missing, .short = "Manifest references a `:impl wasm:<name>` export the wasm binary does not define." },
    .{ .code = .plugin_import_forbidden, .short = "Plugin wasm imports a forbidden host symbol — ABI v2 plugins are pure." },
    .{ .code = .plugin_wasm_required, .short = "Manifest declares `:impl wasm:…` but the resolver returned no wasm bytes." },
    .{ .code = .plugin_describe_invalid, .short = "`sjon_plugin_describe()` output is malformed or inconsistent with the manifest." },
    .{ .code = .plugin_func_trapped, .short = "Plugin export trapped during invocation (unreachable, OOB memory, etc.)." },
    .{ .code = .plugin_func_result_type, .short = "Plugin export's return value's tag mismatches the manifest's declared `:result`." },
    .{ .code = .plugin_func_failed, .short = "Plugin export returned an error status — runtime semantic failure." },
    .{ .code = .plugin_func_alloc_failed, .short = "Plugin allocation hook (`sjon_alloc`) returned null." },

    // --- Default materialization
    .{ .code = .default_eval_failed, .short = "Expression-shaped `:default` failed at evaluation time." },

    // --- Lowering
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

    // --- Numeric / date / time
    .{ .code = .number_overflow_exact_integer, .short = "Integer literal exceeds u64 — falls back to f64 with precision loss." },
    .{ .code = .date_invalid_year, .short = "Date year `0000` rejected (ISO 8601 disallows year 0)." },
    .{ .code = .date_invalid_month, .short = "Date month outside `[1, 12]`." },
    .{ .code = .date_invalid_day, .short = "Date day outside the month's valid range." },
    .{ .code = .time_invalid_hour, .short = "Time hour outside `[0, 23]`." },
    .{ .code = .time_invalid_minute, .short = "Time minute outside `[0, 59]`." },
    .{ .code = .time_invalid_second, .short = "Time second outside `[0, 59]` (no leap seconds)." },

    // --- Numeric bounds
    .{ .code = .number_below_min, .short = "Number value below inclusive `:min`." },
    .{ .code = .number_above_max, .short = "Number value above inclusive `:max`." },
    .{ .code = .number_at_or_below_exclusive_min, .short = "Number value ≤ `:min` when `:exclusive-min true`." },
    .{ .code = .number_at_or_above_exclusive_max, .short = "Number value ≥ `:max` when `:exclusive-max true`." },
    .{ .code = .number_not_integer, .short = "Value violates `:integer true` (fractional or non-finite)." },
    .{
        .code = .number_not_multiple,
        .short = "Value is not an exact multiple of `:multiple-of`.",
        .long =
        \\`:multiple-of N` in a `(numeric-bounds …)` block says the value must
        \\divide evenly by `N`. It is the alignment constraint a range and an
        \\integrality flag cannot express between them: a byte offset that must
        \\land on a 256-byte boundary is not "between 0 and X" and not merely
        \\"an integer", it is a multiple of 256.
        \\
        \\Three checks run in order, and only the first failure is reported. So
        \\`250.5` under `:integer true :multiple-of 4` is `number_not_integer`,
        \\`-256` under `:min 0 :multiple-of 256` is `number_below_min`, and you
        \\see this code only once the value is otherwise acceptable. Fix the
        \\reported problem and re-run; a second one may be waiting.
        \\
        \\Divisibility is decided in exact integer space whenever the value and
        \\the divisor are both whole numbers, so a value above 2^53 answers
        \\correctly rather than being rounded first. A *fractional* divisor
        \\(`:multiple-of 0.25`) is compared with a small tolerance instead —
        \\binary floating point has no exact answer there — and the schema
        \\author is warned about it at the declaration. Alignment rules use
        \\whole divisors, so this caveat rarely applies in practice.
        \\
        \\Negative values are fine: `-512` is a multiple of `256`. If the
        \\divisor carries a unit, the value must carry a byte-equal one, the
        \\same rule `:min` and `:max` follow.
        ,
    },
    .{ .code = .numeric_bound_unit_mismatch, .short = "Bound carries a unit but the validated value does not match it." },
    .{ .code = .numeric_bounds_invalid, .short = "`(numeric-bounds …)` declaration is internally inconsistent." },
    .{ .code = .repr_out_of_range, .short = "Number value does not fit its value-kind's `:repr` GPU type (out of range, or non-integral under `u16`/`u32`/`i32`)." },

    // --- String bounds
    .{ .code = .string_too_short, .short = "String shorter than `:min-len` UTF-8 codepoints." },
    .{ .code = .string_too_long, .short = "String longer than `:max-len` UTF-8 codepoints." },
    .{ .code = .string_format_mismatch, .short = "String value fails the declared `:format` (email/uri/path/uuid/semver)." },
    .{ .code = .string_pattern_mismatch, .short = "String value fails the declared `:pattern` (regex)." },
    .{ .code = .string_pattern_unsupported, .short = "Host build has no regex engine; the `:pattern` is stored but not checked." },
    .{ .code = .string_bounds_invalid, .short = "`(string-bounds …)` declaration is internally inconsistent." },

    // --- Exclusive bundles
    .{ .code = .exclusive_bundle_partial, .short = "Multi-key bundle in an exclusive group is partially present." },
    .{ .code = .exclusive_bundle_collision, .short = "Same key appears in two alternatives of the same exclusive group." },

    // --- v1.1 packaging metadata (Slice 2)
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

    // --- Project v1.1 (Slice 3)
    .{ .code = .unknown_project_key, .short = "Advisory: project file declared a top-level key the host doesn't recognize." },
    .{ .code = .glob_no_matches, .short = "Advisory: a `:documents` pattern matched zero files." },
    .{ .code = .pin_disagreement, .short = "Project `(plugin-entry … :version/:hash)` pin disagrees with a `(use-plugin …)` pin." },
    .{ .code = .project_documents_outside_root, .short = "`:documents` glob resolves outside the project root." },

    // --- Lockfile (Slice 12)
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

    // --- Pattern query
    .{
        .code = .pattern_tick_overflow,
        .short = "A `fast` / `slow` combinator expanded the query window past the 2^53 tick ceiling.",
        .long =
        \\Pattern time is integer ticks on a fixed grid (`PPC` per cycle).
        \\`fast n` queries its child over a window scaled up by `n`; chain
        \\enough of them (e.g. `(fast 1000000000 (fast 1000000000 bd))`) and
        \\the scaled window magnitude exceeds `2^53`, the largest integer a
        \\TypeScript `number` represents exactly. Rather than drift or
        \\overflow, the engine refuses: the offending combinator contributes
        \\no haps and emits this code, while the rest of the pattern is
        \\queried normally (collection over abort). The same trip fires
        \\bit-identically in every host.
        ,
    },
    .{
        .code = .pattern_value_eval_failed,
        .short = "A `(pure …)` expression leaf failed to evaluate at the cycle-0 dry-run.",
        .long =
        \\A form in `(pure …)` value position is an expression of time —
        \\`(pure (* 0.5 (+ 1 (sin (* (tau) cycle)))))` — evaluated per hap
        \\with `cycle` / `tick` / `seed` bound. At compile time the engine
        \\dry-runs it once at cycle 0 / seed 0; static validity is
        \\seed-independent, so cycle 0 catches the whole document-defect class
        \\— an unbound name, division by zero, an arity error, a resource
        \\budget. The leaf then degrades to `silence` and this code is
        \\collected. A failure that only appears at a *later* cycle (e.g.
        \\`(/ 1 (- cycle 2))` at cycle 2) is NOT this code: it is a domain
        \\hole, so that one hap is silently dropped and the rest of the
        \\pattern queries normally.
        ,
    },
    .{
        .code = .pattern_value_result_invalid,
        .short = "A `(pure …)` expression evaluated but produced a value no hap can carry.",
        .long =
        \\The cycle-0 dry-run of a `(pure …)` expression leaf succeeded, but
        \\its result is a form, a vector, a date, or a time — none of which a
        \\hap value can be (a hap carries a symbol / string / keyword /
        \\number / boolean / nil). The most common cause is a misspelled
        \\function name: an unresolved head does not error, it evaluates to a
        \\form *literal* (SJON's form-construction semantics), which then
        \\fails this shape check. The leaf degrades to `silence`. Fix the
        \\name, or have the expression reduce to a scalar.
        ,
    },
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Explanations: every Diagnostic.Code variant has an entry" {
    // Audit step — every code in the wire-stable enum must have an
    // entry. Append-only enum means this guard is one-way, but it
    // prevents accidental omissions from sneaking through review.
    inline for (@typeInfo(Ast.Diagnostic.Code).@"enum".fields) |f| {
        const found = lookup(f.name);
        if (found == null) {
            std.debug.print("missing explanation for `{s}`\n", .{f.name});
            return error.TestExpectedNonNull;
        }
    }
}

test "Explanations.lookup: returns null for unknown code" {
    try testing.expect(lookup("definitely_not_a_code") == null);
}

test "Explanations.all: yields every entry" {
    const entries = all();
    try testing.expect(entries.len > 0);
}
