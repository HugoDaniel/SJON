//! Plugin model for SJON.
//!
//! A `Plugin` is a comptime-defined struct describing a vocabulary that
//! extends SJON: data forms, expression functions, and named value kinds.
//! The built-in `core` plugin (in `src/plugins/core.zig`) ships the closed
//! v1 expression vocabulary; everything else is downstream (PNGine,
//! masagin, …) and lives outside this repo.
//!
//! Memory: plugin descriptors are static — every `[]const u8` field is
//! intended to be a string literal or otherwise long-lived. The `Schema`
//! that aggregates them keeps borrowed references; nothing is copied.

const std = @import("std");
const Expr = @import("Expr.zig");

/// Top-level plugin descriptor.
pub const Plugin = struct {
    /// Namespace token used in qualified lookups: `<name>/form`.
    name: []const u8,
    /// Declared `:version` from the manifest, or empty when the manifest
    /// declares none — the key is optional; a plugin without one is
    /// simply unversioned. The host compares this byte-for-byte against a
    /// `(use-plugin … :version "x.y.z")` pin and emits
    /// `plugin_version_mismatch` on disagreement, so a pin against an
    /// unversioned plugin is always a mismatch. Static plugin literals
    /// may leave this empty too.
    version: []const u8 = "",
    /// Optional manifest override naming the paired wasm sidecar path.
    /// Manifest-directory-relative; the resolver rejects paths that
    /// escape the package directory after normalization
    /// (`plugin_wasm_resolved_outside_package`). When null, the
    /// resolver falls back to its canonical pairing rules
    /// (`plugin.sjon` → `plugin.wasm`; else stem-pair).
    wasm_file: ?[]const u8 = null,
    /// Optional author's stamp of the paired wasm binary's sha256:
    /// `sha256-<64 lowercase hex>`. Complementary to `(use-plugin …
    /// :hash …)` pins — the manifest stamp says "these are the bytes
    /// I shipped"; the consumer pin says "these are the bytes I expect."
    /// The host verifies the stamp against the observed bytes when
    /// both are present (`plugin_wasm_self_hash_mismatch`).
    wasm_sha256: ?[]const u8 = null,
    /// Plugin authors. Each entry may be a bare symbol (e.g. `ada`) or
    /// a free-form string (e.g. `"Ada Lovelace <ada@example.com>"`).
    /// Currently descriptive metadata — no validation beyond per-element
    /// type checks. v1 manifests omit this field entirely.
    authors: []const []const u8 = &.{},
    /// Declared license. SPDX identifier preferred (e.g. `CC0-1.0`,
    /// `Apache-2.0`, `MPL-2.0`); arbitrary strings are accepted with an
    /// advisory `license_unrecognized` warning. Empty = unspecified.
    license: []const u8 = "",
    /// Optional homepage URL — informational metadata.
    homepage: []const u8 = "",
    /// Optional source-repository URL — informational metadata.
    repository: []const u8 = "",
    /// Free-form keywords for discovery / categorization. Symbol form
    /// expected (`[gui rendering ecs]`). Capped at `MAX_KEYWORDS = 16`
    /// with an advisory `too_many_keywords` warning when exceeded.
    keywords: []const []const u8 = &.{},
    /// Data-form constructors this plugin defines.
    forms: []const FormSpec = &.{},
    /// Safe-expression functions this plugin contributes.
    expr_funcs: []const ExprFunc = &.{},
    /// Plugin-defined value kinds (typed scalars / records). Used by the
    /// validator to type-check keyword values.
    value_kinds: []const ValueKind = &.{},
    /// Named, pure name-extractors this plugin contributes. Referenced by
    /// `(cross-ref :provider <name>)`. Contract: one string in, a vector
    /// of symbol-spelling strings out; deterministic; no capabilities.
    cross_ref_providers: []const CrossRefProvider = &.{},
};

/// Advisory cap on `:keywords` entries. Above this, the loader emits
/// `too_many_keywords` (warning, not error) so manifests don't bloat into
/// SEO-style keyword stuffing.
pub const MAX_KEYWORDS: usize = 16;

/// Description of one data-form constructor (e.g. `(scene …)`).
///
/// **Discriminated forms.** When `discriminant_idx != null`, the form
/// gates *additional* key sets on the value of one designated key (e.g.
/// `(track :kind kick :step 4)` — `:step` is only valid when
/// `:kind = kick`). Common keys (always allowed) live in `keys`;
/// per-`:when` extra keys live in `variants[i].keys`.
///
/// **Position constraint.** The discriminant kvpair must appear before
/// any variant-only key in document order. Variant-only kvpairs that
/// precede the discriminant are diagnosed as `unknown_key` with a hint
/// to put the discriminant first. Tree and binary paths apply the same
/// rule, so producers should emit the discriminant first.
pub const FormSpec = struct {
    /// Bare name as it appears in source: `scene` for `(scene …)`.
    name: []const u8,
    /// Allowed keyword children. The validator emits a diagnostic for any
    /// keyword whose name is not listed here (unless `open` is true).
    keys: []const KeySpec = &.{},
    /// Whether positional children (form / value siblings) are allowed.
    positional: PositionalSpec = .none,
    /// Positional slot-local form definitions. When non-empty, a form-shaped
    /// **positional** child of this form resolves its head **local-first**:
    /// against these specs by bare name before falling back to the global
    /// `Schema.lookupForm` catalog (additive layering — a local shadows a
    /// same-named global). A local match is validated in place against the
    /// matched spec; a head matching neither local nor global emits
    /// `unknown_local_form` at this form's path. These heads stay invisible to
    /// global lookup; a qualified head (`ns/foo`) bypasses locals entirely.
    /// The positional mirror of `KeySpec.local_forms` — the two carriers
    /// compose, both bounded by `MAX_LOCAL_FORM_DEPTH` at load time. The
    /// registry attaches whenever this is non-empty, independent of which
    /// `PositionalSpec` variant is declared (`.any` / head-set `.kind`); a
    /// `(flag-set …)` positional is mutually exclusive with locals (rejected at
    /// load), and locals with no `:positional` imply `.any` so they aren't
    /// dead behind `positional_not_allowed`.
    local_forms: []const FormSpec = &.{},
    /// If true, unknown keywords are accepted silently. Useful for forms
    /// that act as raw bags during prototyping.
    open: bool = false,
    /// Free-text help string surfaced by editor tooltips.
    description: []const u8 = "",
    /// Name of the discriminant key (must reference an entry in `keys`).
    /// Stored for diagnostics + round-tripping; the hot path uses
    /// `discriminant_idx` instead.
    discriminant_name: ?[]const u8 = null,
    /// Index into `keys` of the discriminant key. Resolved at load time
    /// by `ManifestLoader` (or set explicitly by static plugin literals).
    /// `null` when the form is not discriminated.
    discriminant_idx: ?u8 = null,
    /// Per-`:when` extra key sets. Each variant's `keys` are allowed only
    /// when the discriminant kvpair's value equals the variant's `when`.
    /// Names must not collide with `keys` or with another variant's keys.
    variants: ?[]const Variant = null,
    /// Cross-key cardinality constraints. Each group declares a set of
    /// alternative key bundles plus a required-presence rule
    /// (`exactly_one` / `at_most_one`). Used to express "`:notes` xor
    /// `:events`"-style rules without a per-form host hook.
    exclusive_groups: []const ExclusiveGroup = &.{},
    /// Declares this form as a *surface sugar* lowered by a host-owned
    /// contract before final validation. The manifest names the contract
    /// (`hook` id) and the set of form heads the contract may emit
    /// (`produces`); the host binds the id to actual lowering code and
    /// produces canonical forms. `null` = no lowering, the form is final
    /// data as declared. See `docs/plugin-model-v1.md`.
    ///
    /// **Top-level forms only.** A slot-local form (either carrier) must
    /// keep this `null`: `Schema.validateLowering` and the produces graph
    /// walk top-level forms, and the lowering worklist resolves a local
    /// head to its local body, never to a hook. `ManifestLoader` rejects a
    /// local's `:lowering` as `invalid_manifest`; `Schema.init` asserts it
    /// for static plugin literals.
    lowering: ?LoweringSpec = null,

    /// Find the base key spec named `name`, or null when this form
    /// declares no such key. Linear scan — `keys` is validator-capped at
    /// `MAX_FORM_KEYS`, so this stays cheap. The returned pointer borrows
    /// from `keys` (valid for the FormSpec's lifetime). Searches only the
    /// base `keys`, never per-`:when` variant keys: callers needing a
    /// variant key resolve the active variant first.
    pub fn keyByName(self: FormSpec, name: []const u8) ?*const KeySpec {
        for (self.keys) |*k| {
            if (std.mem.eql(u8, k.name, name)) return k;
        }
        return null;
    }
};

/// Host-lowering contract attached to a `FormSpec`. The contract is named
/// (`hook`) and bounded (`produces`), but the implementation is host-owned;
/// portable manifests carry the declaration, never the lowerer.
///
/// `hook` is a symbolic, versioned id, by convention `<vendor>/<surface>-v<n>`
/// (e.g. `pngine/pass-v1`). Hosts that do not implement the hook must fail
/// loudly before lowering-dependent validation rather than silently
/// validating the sugar form as final data.
///
/// `produces` is a closed list of allowed output form heads. Hosts may
/// emit only forms whose heads appear here. Names follow the same
/// resolution rules used by `ValueKind.HeadSet.names` and cross-ref
/// targets: bare names resolve against the aggregate schema; qualified
/// names (`<plugin>/<form>`) disambiguate across plugins.
pub const LoweringSpec = struct {
    /// Symbolic contract id. Manifest-time invariant: non-empty.
    hook: []const u8,
    /// Allowed output form heads. Manifest-time invariants enforced by
    /// `ManifestLoader`: non-empty, no duplicates, every entry resolves
    /// to a known form across the aggregate schema, and bare entries
    /// must not be ambiguous.
    produces: []const []const u8,
};

/// One extra key set on a discriminated form, selected by the
/// discriminant's value. Used inside `FormSpec.variants`.
pub const Variant = struct {
    /// The discriminant values that select this variant — the symbol(s)
    /// the manifest wrote under `:when`, one or several (`:when a` and
    /// `:when [a b]` are both spelled here as a list). `.len >= 1`. Every
    /// entry must be a member of the discriminant key's `MemberSet`
    /// (`unknown_discriminant_value` at aggregate time, once per entry),
    /// and a value selects **at most one** variant of a form: the loader
    /// rejects an empty vector, a repeat within one `:when`, and a value
    /// listed by two variants, all `invalid_manifest`. Selection is
    /// membership — see `selects`. One declaration reaching several
    /// values is what keeps the key-collision check as strict as it is:
    /// a key still lives in exactly one variant.
    when: []const []const u8,
    /// Extra keys allowed (and possibly required) while the discriminant's
    /// value selects this variant. Cap is `MAX_FORM_KEYS` per variant.
    keys: []const KeySpec = &.{},
    /// Variant-scoped exclusive groups. Same semantics as
    /// `FormSpec.exclusive_groups`, but the alternatives reference keys
    /// declared on this variant rather than the form's common keys.
    exclusive_groups: []const ExclusiveGroup = &.{},

    /// True when the discriminant value `value` selects this variant —
    /// byte-equality against any entry of `when`. Both validator walkers,
    /// the LSP and the overlay pre-resolution ask this one function.
    pub fn selects(self: Variant, value: []const u8) bool {
        for (self.when) |w| if (std.mem.eql(u8, w, value)) return true;
        return false;
    }

    /// The `:when` as the author would spell it: one symbol bare
    /// (`tri-strip`), a set bracketed (`[tri-strip line-strip]`). Every
    /// message that names a variant renders it through here, so a
    /// single-value variant reads exactly as it did when `:when` took one
    /// symbol. Allocated from `a`; the caller owns the bytes.
    pub fn whenText(self: Variant, a: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        std.debug.assert(self.when.len >= 1);
        if (self.when.len == 1) return try a.dupe(u8, self.when[0]);
        var buf: std.ArrayList(u8) = .empty;
        try buf.append(a, '[');
        for (self.when, 0..) |w, i| {
            if (i > 0) try buf.append(a, ' ');
            try buf.appendSlice(a, w);
        }
        try buf.append(a, ']');
        return try buf.toOwnedSlice(a);
    }
};

test "Variant.selects is membership; whenText spells one bare and several bracketed" {
    const one: Variant = .{ .when = &.{"a"} };
    const many: Variant = .{ .when = &.{ "tri-strip", "line-strip" } };
    try std.testing.expect(one.selects("a"));
    try std.testing.expect(!one.selects("b"));
    try std.testing.expect(many.selects("tri-strip"));
    try std.testing.expect(many.selects("line-strip"));
    try std.testing.expect(!many.selects("tri-list"));

    const a = std.testing.allocator;
    const t1 = try one.whenText(a);
    defer a.free(t1);
    try std.testing.expectEqualStrings("a", t1);
    const t2 = try many.whenText(a);
    defer a.free(t2);
    try std.testing.expectEqualStrings("[tri-strip line-strip]", t2);
}

/// Cross-key cardinality constraint on a `FormSpec` or `Variant`.
///
/// `alternatives` lists the mutually exclusive key bundles. With
/// `cardinality = .exactly_one`, exactly one alternative must be present;
/// with `.at_most_one`, zero or one. `at_least_one` is intentionally
/// absent — that is just two `optional: false` keys, no group needed.
///
/// Manifest-time invariants enforced by `ManifestLoader`:
///   * `alternatives.len >= 2`
///   * every name referenced by `alternatives[i].keys` exists in the
///     enclosing scope's `keys`
///   * no key appears in two different groups on the same scope
///   * a group on a `FormSpec` does not name the discriminant key
///
/// Each alternative is a *bundle* of one-or-more key names; a bundle is
/// "present" iff every key in `keys` is present on the form. Single-key
/// bundles (the v1 shape) and multi-key bundles (e.g. `(:from :to)` xor
/// `:at`) share one runtime path.
pub const ExclusiveGroup = struct {
    alternatives: []const Alternative,
    cardinality: Cardinality = .exactly_one,
};

pub const Alternative = struct {
    /// Key names (without `:`) whose simultaneous presence constitutes
    /// "this alternative is present." `keys.len >= 1`; multi-key entries
    /// are atomic — partial presence emits `exclusive_bundle_partial`.
    keys: []const []const u8,
};

pub const Cardinality = enum { exactly_one, at_most_one };

/// Maximum number of `:keyword` slots per form. Manifest-loaded forms
/// that exceed this cap are rejected at load time (see `ManifestLoader`);
/// plugins constructed directly in Zig may exceed it but lose
/// required-key tracking past index 63.
pub const MAX_FORM_KEYS: usize = 64;

/// Maximum nesting depth of slot-local form definitions — both carriers:
/// `KeySpec.local_forms` (a local under a `(key …)` slot) and
/// `FormSpec.local_forms` (a local positional child directly under a
/// `(form …)`). A top-level form's children are depth 1; a local form nested
/// in one is depth 2, and so on; the two carriers compose under this one
/// budget. Manifest-loaded local forms deeper than this are rejected at load
/// time (see `ManifestLoader.buildKey` / `buildForm`). Bounds the
/// FormSpec→{KeySpec, FormSpec}→FormSpec recursion so a hostile manifest
/// cannot blow the loader stack via inline locals.
pub const MAX_LOCAL_FORM_DEPTH: usize = 8;

/// Maximum number of emitted forms a single lowering invocation may
/// produce. Exceeded → `lowering_output_too_large`. See
/// `docs/plugin-model-v1.md` and `src/Lowering.zig`.
pub const MAX_LOWERED_FORMS: usize = 1024;

/// Maximum nesting depth of emitted forms in a lowering output. Counted
/// from the top-level `EmittedForm` (depth 1) down through `children`.
/// Exceeded → `lowering_output_too_large`.
pub const MAX_LOWERED_DEPTH: usize = 16;

/// Maximum nesting depth of emitted *vectors*, counted independently of
/// `MAX_LOWERED_DEPTH`. Exceeded → `lowering_output_too_large`.
///
/// Vectors are deliberately transparent to form depth (a form nested inside
/// a vector is one form-level down regardless of how many vectors wrap it),
/// which leaves vector-in-vector as an axis a hook could grow without
/// bound — and `Lowering.emitValueIntoTree` descends it on the host stack.
/// This is the ceiling that closes that axis. The two together bound the
/// emit walk at `MAX_LOWERED_DEPTH × MAX_LOWERED_VECTOR_DEPTH` frames.
pub const MAX_LOWERED_VECTOR_DEPTH: usize = 16;

/// Rough byte budget for lowering output: sum of head + key + string-
/// value lengths across emitted forms. Exceeded → `lowering_output_too_large`.
/// Not a precise allocation cap — sufficient to catch runaway hooks.
pub const MAX_LOWERED_BYTES: usize = 256 * 1024;

/// One declared `:keyword value` slot on a form. Listed in `FormSpec.keys`.
pub const KeySpec = struct {
    /// Keyword name without leading `:`.
    name: []const u8,
    /// Expected type of the paired value.
    value_type: ValueType = .any,
    /// True when the key may be omitted entirely. A key with a non-null
    /// `default` is implicitly optional regardless of this flag — see
    /// `effectiveOptional()` for the canonical rule.
    optional: bool = true,
    /// Static fallback for omitted optional keys. When non-null the
    /// validator skips the missing-required-key diagnostic for this slot
    /// and consumers may substitute the default value at evaluation time.
    /// The default's structural type must be compatible with `value_type`;
    /// the manifest loader enforces this at load time.
    default: ?Default = null,
    /// Free-text help string surfaced by editor tooltips.
    description: []const u8 = "",
    /// Sibling keys this key's presence demands. When this key is present
    /// and any named key is absent, the validator emits
    /// `dependent_key_missing` naming every absent one. Empty (the
    /// default) means no dependency, and an *absent* key constrains
    /// nothing — the rule is one-directional by construction, so mutual
    /// dependence is two `requires` lists.
    ///
    /// Names resolve within the scope this key is declared in: a base key
    /// names base keys, a variant key names that variant's keys or the
    /// form's base keys (both are unconditionally in scope once the
    /// variant is active). The loader rejects an unresolvable name, a
    /// self-reference, a requirement that is already non-optional (it can
    /// never fire), a requirement inside the same exclusive group (the
    /// group says "at most one", this says "both"), and cycles.
    ///
    /// Like every other closed-form shape rule, this is suppressed by
    /// `FormSpec.open` — both walkers return before the end-of-form
    /// sweeps on an open form.
    requires: []const []const u8 = &.{},
    /// When true, the validator's tree walk does not descend into a
    /// form-shaped value paired with this key — the value's head and
    /// inner contents are treated as opaque to the surrounding schema.
    /// Used by MetaSchema's `:default` slot to allow expression-shaped
    /// defaults (`:default (pi)`) whose heads aren't meta-known. The
    /// slot-level type check still runs via `matchValueAgainstType`.
    walk_opaque: bool = false,
    /// Slot-local form definitions. When non-empty (and `value_type` is
    /// `.form`), a form-shaped value paired with this key resolves its head
    /// **local-first**: against these specs by bare name before falling back
    /// to the global `Schema.lookupForm` catalog (additive layering — a local
    /// shadows a same-named global). A local match is validated in place
    /// against the matched spec; a head matching neither local nor global
    /// emits `unknown_local_form` at the slot path. These heads stay invisible
    /// to global lookup. A qualified head (`ns/foo`) bypasses locals entirely.
    /// Mutually exclusive with `walk_opaque` in practice (an opaque slot is
    /// never descended into). The FormSpec→KeySpec→FormSpec cycle is through
    /// slices; nesting is bounded by `MAX_LOCAL_FORM_DEPTH` at load time.
    local_forms: []const FormSpec = &.{},

    /// Canonical "may be omitted" predicate. Combines the explicit
    /// `optional` flag with the implicit "has-default ⇒ optional" rule.
    pub fn effectiveOptional(self: KeySpec) bool {
        return self.optional or self.default != null;
    }

    /// Fallback value usable as a `KeySpec.default`. Mirrors the AST
    /// tags allowed in a kvpair value:
    ///   - literal shapes (number/string/symbol/boolean/nil/vector)
    ///     capture the value directly.
    ///   - `.expression` stores a cheap classification snapshot
    ///     (head/namespace/arg count) plus a one-root Binary IR program.
    ///     The aggregate phase uses the snapshot to type-check the
    ///     declared `:result` against `value_type`; materialization feeds
    ///     the program to `Expr.evalBinary` when the key is omitted.
    /// Keyword cannot appear as a kvpair value through source (parser's
    /// greedy rule). Vectors nest only the literal shapes; vectors with
    /// expression elements are deferred to a follow-up slice.
    pub const Default = union(enum) {
        number: f64,
        string: []const u8,
        symbol: []const u8,
        boolean: bool,
        nil,
        vector: []const Default,
        expression: Expression,

        /// Validate-time snapshot of an expression-shaped default.
        /// `head`/`namespace`/`arg_count` are the cheap classification
        /// surface — what `Schema.validateDefaults` and
        /// `Validator.resolveFormExpressionBinary` need to verdict the
        /// declared result without decoding the program.
        /// `program` is the evaluable payload: one-root Binary IR for
        /// the whole expression subtree, plugin-arena owned. The future
        /// materialization pass feeds it to `Expr.evalBinary`.
        pub const Expression = struct {
            head: []const u8,
            namespace: ?[]const u8,
            arg_count: u32,
            program: []const u8,
        };
    };
};

/// Qualified reference to a plugin-declared value kind. `name` is the bare
/// kind name (`color`); `namespace` is the owning plugin's name (`paint`)
/// when the author wrote `paint/color`, or `null` when they wrote just
/// `color`. Bare refs resolve when unambiguous; ambiguous bare refs surface
/// as `ambiguous_element_kind` with a hint to qualify. Same shape as
/// `FormSpec.namespace` and `KeySpec.Default.Expression.namespace` so all
/// three vocabularies use one rule for cross-plugin disambiguation.
pub const QualifiedRef = struct {
    name: []const u8,
    namespace: ?[]const u8 = null,
};

/// What kind of positional children a form accepts.
pub const PositionalSpec = union(enum) {
    /// No positional children allowed (only `:key value` pairs).
    none,
    /// Any number of positional children, untyped.
    any,
    /// Any number of positional children, each matching the named
    /// `ValueKind`. Lookup follows `KeySpec.value_type = .{ .named = ... }`.
    /// `namespace` qualifies the value-kind reference when set
    /// (`plugin/color`); `null` means the manifest wrote a bare name and
    /// the validator resolves it across all loaded plugins.
    kind: QualifiedRef,
    /// Any number of positional **keyword flags**, each of whose text
    /// (colon-stripped) must match one of `FlagSet.flags` by `name`. A
    /// non-keyword positional in this slot is `wrong_underlying`; a
    /// keyword outside the set is `not_flag_member`; a flag repeated on
    /// one form is `duplicate_positional_flag`. Declared inline via
    /// `:positional (flag-set (flag :name done) (flag :name archived))`.
    flag_set: FlagSet,

    /// Closed set of allowed positional keyword flags for
    /// `PositionalSpec.flag_set`. The validator matches on `name` alone;
    /// the optional `description`/`link` metadata rides along for hovers,
    /// schema export, and docs.
    pub const FlagSet = struct {
        flags: []const Flag,

        /// One declared positional keyword flag. `name` is bare (no
        /// leading `:`), compared against the flag keyword's colon-stripped
        /// text. `description`/`link` are author-supplied tooling metadata
        /// (`""`/`null` when omitted); the validator ignores them.
        pub const Flag = struct {
            name: []const u8,
            description: []const u8 = "",
            link: ?[]const u8 = null,
        };
    };
};

/// Coarse-grained type tags. Plugin-defined `value_kinds` are referenced
/// by name through `.named`; `any` is the escape hatch.
///
/// `Tag.keyword` is intentionally absent: SJON's parser greedy rule
/// (`:k1 :k2` → both promote to positional flags) means a kvpair value
/// can never be a `Tag.keyword` through source. Plugins wanting an
/// "atom value" use `.symbol` (`(scene :mode loop)` → kvpair `mode`=`loop`)
/// or wrap in a vector (`[:loop]`).
pub const ValueType = union(enum) {
    /// Any value is acceptable. Default.
    any,
    number,
    string,
    symbol,
    boolean,
    nil,
    /// A `[…]` vector with arbitrary element type.
    vector,
    /// A nested `(…)` form. Element type checked by the form's own spec.
    form,
    /// A safe-expression form whose head is in the expression vocabulary.
    expr,
    /// Reference to a plugin-defined value kind by name. `namespace` is
    /// non-null when the author qualified the reference (`plugin/kind`).
    named: QualifiedRef,
};

/// The primitive type-name catalog: the built-in names accepted in a schema
/// type reference. Single source of truth for the schema's
/// `isPrimitiveTypeName` membership test (`.has`) and the validator's
/// `resolvePrimitiveShortcut` name→ValueType resolution (`.get`).
///
/// The map value is the `ValueType` a name resolves to on the shortcut path,
/// or `null` for a name that is a catalog member but is deliberately NOT
/// collapsed to its ValueType tag. `expr` is such a member: a `.named{"expr"}`
/// reference must stay named (resolved via the value-kind / expr-vocabulary
/// path) rather than becoming the `.expr` primitive — an asymmetry the
/// validator's type matcher relies on. Both a catalog miss and `expr` yield
/// null on the shortcut path, while `.has` still reports `expr` as a member.
pub const primitive_type_names = std.StaticStringMap(?ValueType).initComptime(.{
    .{ "any", .any },
    .{ "number", .number },
    .{ "string", .string },
    .{ "symbol", .symbol },
    .{ "boolean", .boolean },
    .{ "nil", .nil },
    .{ "vector", .vector },
    .{ "form", .form },
    .{ "expr", null },
});

/// A qualified name split into its optional `namespace` and bare `name`.
pub const QualifiedName = struct {
    namespace: ?[]const u8,
    name: []const u8,
};

/// Split `text` on its first `/` into `(namespace, name)`. With no slash,
/// `namespace` is null and `name` is the whole text.
///
/// Unlike `Parser.splitNamespace`, a leading or trailing slash is NOT
/// special-cased: `"/x"` yields `namespace = ""` and `"x/"` yields
/// `name = ""`. That is deliberate — this serves the Schema/Validator
/// lookup sites, which hand the pieces straight to `lookupForm` /
/// `lookupExprFunc`, where an empty namespace or name simply misses. The
/// parser and manifest loader want the guarded semantics and keep using
/// `splitNamespace`; do not consolidate the two without checking the edge
/// behaviour at every call site.
pub fn splitQualified(text: []const u8) QualifiedName {
    if (std.mem.indexOfScalar(u8, text, '/')) |slash| {
        return .{ .namespace = text[0..slash], .name = text[slash + 1 ..] };
    }
    return .{ .namespace = null, .name = text };
}

test "splitQualified: first slash wins; leading/trailing slashes keep empty pieces" {
    const bare = splitQualified("phrase");
    try std.testing.expect(bare.namespace == null);
    try std.testing.expectEqualStrings("phrase", bare.name);

    const q = splitQualified("audio/phrase");
    try std.testing.expectEqualStrings("audio", q.namespace.?);
    try std.testing.expectEqualStrings("phrase", q.name);

    // First slash wins (matches std.mem.indexOfScalar).
    const two = splitQualified("a/b/c");
    try std.testing.expectEqualStrings("a", two.namespace.?);
    try std.testing.expectEqualStrings("b/c", two.name);

    // Unguarded edges: leading slash → empty namespace; trailing → empty name.
    const lead = splitQualified("/x");
    try std.testing.expectEqualStrings("", lead.namespace.?);
    try std.testing.expectEqualStrings("x", lead.name);

    const trail = splitQualified("x/");
    try std.testing.expectEqualStrings("x", trail.namespace.?);
    try std.testing.expectEqualStrings("", trail.name);
}

/// A safe-expression function.
///
/// `impl` is the runtime dispatch hook. When non-null the evaluator calls
/// it via `Expr.applyFunction`; when null calling the func at runtime
/// produces `error.PluginFuncNotImplemented`. Declaring without
/// implementing is a supported state for plugins that want the validator
/// to recognise the head before committing to evaluator semantics — the
/// shape of the type now matches the runtime contract.
///
/// **Typed signature** (optional). Plugins may annotate `params`, `rest`,
/// and `result` to enable validate-time argument type checking:
///   * `params` — type per fixed positional position (length matches
///     `arity` for fixed; the prefix for at_least/range).
///   * `rest` — type for trailing positionals beyond `params.len`. Only
///     meaningful with `at_least` or `range` arities.
///   * `result` — return type. The validator uses it for declared-result
///     flow: nested expression arguments, expression-valued slots, and
///     expression-shaped defaults can be type-checked without evaluating
///     the expression body.
///
/// When `params` is null the validator skips argument typing and matches
/// today's behaviour ("expression positional args are untyped"). Special
/// forms like `let`/`if`/`cond` leave `params` null (opaque signature)
/// because their typing depends on bound values or branch evaluation.
pub const ExprFunc = struct {
    /// Callable name (e.g. `+`, `lerp`, `vec3`, `b`).
    name: []const u8,
    /// Argument count contract for the mono encoding. Ignored when
    /// `signatures` is non-null (the overloaded encoding owns arity).
    arity: Arity = .{ .at_least = 0 },
    /// Free-text description for editor tooltips.
    description: []const u8 = "",
    /// Runtime dispatch. `null` means declaration-only.
    impl: ?Impl = null,
    /// Set by the manifest loader when `:impl` is `wasm:<name>` (D7).
    /// The host runtime adapter dispatches via this export name when
    /// `impl` is null. Other `:impl` schemes (`host:*`) are reserved
    /// and remain unimplemented in v1; their bodies stay declaration-
    /// only at this layer.
    wasm_export_name: ?[]const u8 = null,
    /// Mono-encoding typed positional parameters. `params[i]` is the
    /// expected type for the i-th positional argument. `null` means
    /// the function is opaque to validator typing.
    params: ?[]const ValueType = null,
    /// Declared parameter names — opt-in for Swift-style labeled call
    /// form. When non-null and `param_names.len == fixed_arity`, the
    /// function accepts `(f :a 1 :b 2)` in addition to `(f 1 2)`. Names
    /// live on a different axis from `params`: they describe slot
    /// identity, not type, so an opaque function (no `params`) can
    /// still declare names. Invariants: arity must be `.fixed`, `rest`
    /// must be `null`, `param_names.len <= fixed_arity`, no duplicates.
    /// Partial coverage (`< fixed_arity`) is allowed for tooltips but
    /// does not enable labeled calls.
    param_names: ?[]const []const u8 = null,
    /// Mono-encoding variadic-tail type. When non-null, every positional
    /// past `params.len` (or all positionals when `params` is null and
    /// arity is variadic) takes this type.
    rest: ?ValueType = null,
    /// Mono-encoding declared result type. Reserved for slot-flow
    /// narrowing in a later step; not currently consulted by the
    /// validator.
    result: ?ValueType = null,
    /// Overload set. When non-null the function is polymorphic — the
    /// validator dispatches by arity-then-type-unification across these
    /// signatures and the mono fields are ignored. When null the mono
    /// fields above describe the single signature. Loaders / static
    /// declarations pick whichever encoding is more concise; mixing
    /// them on the same `ExprFunc` is rejected by the manifest loader.
    signatures: ?[]const Signature = null,

    /// One typed signature. Mirrors the typed-arg fields of `ExprFunc`;
    /// shared between the mono encoding (where the fields live directly
    /// on `ExprFunc`) and the multi-signature encoding (where multiple
    /// `Signature`s sit in `signatures`).
    pub const Signature = struct {
        arity: Arity,
        params: ?[]const ValueType = null,
        /// See `ExprFunc.param_names` — same semantics, per-overload.
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

        /// Expected type for the i-th positional argument, or `null`
        /// when this signature is opaque (no `params`/`rest`).
        pub fn paramType(self: Signature, i: usize) ?ValueType {
            if (self.params) |ps| {
                if (i < ps.len) return ps[i];
            }
            return self.rest;
        }

        /// True iff this signature accepts the labeled call form —
        /// arity is `.fixed N`, no `rest`, every slot is named.
        pub fn labeledEnabled(self: Signature) bool {
            const fixed = switch (self.arity) {
                .fixed => |k| k,
                else => return false,
            };
            if (self.rest != null) return false;
            const names = self.param_names orelse return false;
            return names.len == fixed;
        }

        /// Index of `name` in `param_names`, or null if absent.
        pub fn indexOfLabel(self: Signature, name: []const u8) ?u8 {
            const names = self.param_names orelse return null;
            for (names, 0..) |n, i| {
                if (std.mem.eql(u8, n, name)) return @intCast(i);
            }
            return null;
        }
    };

    /// Implementation signature. Receives an allocator (the result arena)
    /// and the resolved argument values; returns a new value or an error.
    /// Strings / vectors in the returned value must be allocated from the
    /// supplied allocator.
    pub const Impl = *const fn (
        a: std.mem.Allocator,
        args: []const Expr.Value,
    ) Expr.Error!Expr.Value;

    pub const Arity = union(enum) {
        /// Exact arity.
        fixed: u8,
        /// Minimum number of arguments; no maximum.
        at_least: u8,
        /// Inclusive `[min, max]` range.
        range: struct { min: u8, max: u8 },
    };

    /// Yields the function's signature(s). Mono ExprFuncs surface a
    /// single derived `Signature` from the top-level fields; overloaded
    /// ExprFuncs surface their declared `signatures`. The validator
    /// always drives off this iterator, never branching on the encoding.
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

    /// Number of signatures the function carries — 1 for mono,
    /// `signatures.len` otherwise.
    pub fn signatureCount(self: ExprFunc) usize {
        if (self.signatures) |sigs| return sigs.len;
        return 1;
    }

    /// True if any signature accepts `n` arguments.
    pub fn checkArity(self: ExprFunc, n: usize) bool {
        var it = self.signatureIter();
        while (it.next()) |sig| if (sig.checkArity(n)) return true;
        return false;
    }

    /// Mono-shaped paramType retained for back-compat with the existing
    /// validator call sites that haven't migrated to overload-aware
    /// dispatch. For overloaded functions this collapses to the first
    /// signature whose arity is unbounded — an approximation only
    /// suitable for non-dispatching diagnostics. Prefer `signatureIter`.
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

    /// Verify `param_names` invariants on every signature. Called by the
    /// manifest loader and exercised in tests for static declarations.
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

/// A named, pure name-extractor: the second route a `CrossRef` can take
/// to its member set.
///
/// Where the identity route reads a symbol out of each target instance's
/// `:name-key` kvpair, the provider route reads a **string** out of the
/// instance's `:source-key` kvpair and hands it to one of these. The
/// provider is the only consumer allowed to see inside content SJON
/// treats as opaque (a GLSL body, embedded DDL, a regex).
///
/// **Purity contract — structural, not conventional.** The input is the
/// source bytes and nothing else: no document handle, no schema, no
/// filesystem, no clock. Validation therefore stays a deterministic
/// function of (document, schema, pinned plugin set), and the portable
/// route inherits that from the zero-import WASM ABI — a module with no
/// imports has no clock, no randomness, and no I/O to disagree about.
/// Environmental extractors ("does this path exist?") are permanently
/// out of scope; they are facts about the world, not about the document.
///
/// **Execution lives outside the validator.** Neither field below is
/// consulted during validation: a host pre-pass turns declared providers
/// into a content-addressed `(provider, source bytes) → names | failure`
/// table and the validator looks results up. `Schema.init` stays pure and
/// `Validator.validate` keeps its zero injection points.
///
/// Declaration-only (both fields null) is legal, exactly as it is for
/// `ExprFunc` — the aggregate pass still resolves the reference; it just
/// can never be fulfilled at extraction time, which surfaces as
/// `cross_ref_provider_unavailable` rather than silence.
pub const CrossRefProvider = struct {
    /// Bare name as referenced by `(cross-ref :provider <name>)`.
    /// Qualified lookups spell it `<plugin>/<name>`.
    name: []const u8,
    /// Free-text description surfaced by editor tooltips.
    description: []const u8 = "",
    /// Native implementation for static Zig plugins (mirrors
    /// `ExprFunc.impl`). `null` means declaration-only on this route.
    impl: ?Extract = null,
    /// Set by the manifest loader when `:impl` is `wasm:<export>`
    /// (mirrors `ExprFunc.wasm_export_name`). The host runtime adapter
    /// dispatches via this export name when `impl` is null. At most one
    /// of `impl` / `wasm_export_name` is meaningful.
    wasm_export_name: ?[]const u8 = null,

    /// Native extraction signature. Receives an allocator and the source
    /// bytes; returns the extracted names, which must be allocated from
    /// the supplied allocator. Order is provider-chosen but must be
    /// deterministic for a given input — it is part of the registration
    /// order the index pass and the corpus both pin.
    pub const Extract = *const fn (
        a: std.mem.Allocator,
        source: []const u8,
    ) ExtractError![]const []const u8;

    /// Failure vocabulary of the native route. `ExtractionFailed` is the
    /// "this source is malformed for me" answer and surfaces as
    /// `cross_ref_extraction_failed`; it is a diagnosis, not a bug.
    pub const ExtractError = error{
        OutOfMemory,
        ExtractionFailed,
    };
};

/// A plugin-declared value kind (typed scalar, record, or compound).
///
/// `vector`, `unit`, `members`, `heads`, and `cross_ref` are optional
/// refinements:
///   * `vector` shapes a `.vector` underlying — pinning element kind and
///     (optionally) length. Element kind is a name string resolved at
///     validate-time via `Schema.lookupValueKind`, with shortcuts for the
///     primitive `Plugin.ValueType` tags ("number", "string", "symbol",
///     "form", "any").
///   * `unit` constrains a `.number` underlying — requiring a unit
///     suffix and / or restricting it to an allowed list.
///   * `members` constrains a `.symbol` or `.string` underlying to a
///     closed set of allowed values. Useful for declaring enums like
///     `:projection :ortho|:perspective` or string variants.
///   * `heads` constrains a `.form` underlying to a closed set of
///     allowed form head names — the form-as-slot pinning case
///     (OpenAPI-style discriminator). Useful for slots like
///     `:shape (point …) | (rect …) | (circle …)`.
///   * `cross_ref` constrains a `.symbol` underlying to a *document-
///     discovered* closed set: the names of every form in the validated
///     forest whose head matches `target_form`. The set is populated at
///     validate time (not manifest time), making this the only refinement
///     whose member list is determined by the document content. Useful
///     for slots like `:sequence [p0 p1 p2]` referencing
///     `(phrase :name p0 …)` siblings, or `:parent track-id` references.
///   * `union_of` makes the kind dispatch to one of several alternative
///     value-kinds — the first alternative whose own constraints accept
///     the value wins. Used for slots that mix tag categories, e.g.
///     `:notes [E4 (n G4 0.5b) _]` (symbol + form) or `:value 1 |
///     [0 0 0 1] | (+ 1 …)` (number + vector + form). Each alternative
///     is a named value-kind or a primitive shortcut; nesting unions is
///     rejected at schema-aggregate time.
///   * `string_bounds` constrains a `.string` underlying with optional
///     UTF-8 codepoint length range, regex pattern, and named format
///     (email / uri / path / uuid / semver). Orthogonal to `members`:
///     both may co-exist, with the loader cross-checking that each
///     member literal satisfies the declared bounds.
pub const ValueKind = struct {
    name: []const u8,
    underlying: Underlying,
    description: []const u8 = "",
    /// Only meaningful when `underlying == .vector`.
    vector: ?VectorShape = null,
    /// Only meaningful when `underlying == .number`.
    unit: ?UnitShape = null,
    /// Only meaningful when `underlying == .number`. Range / integrality
    /// constraints; orthogonal to `unit`.
    numeric: ?NumericBounds = null,
    /// Only meaningful when `underlying == .symbol` or `.string`.
    members: ?MemberSet = null,
    /// Only meaningful when `underlying == .form`.
    heads: ?HeadSet = null,
    /// Only meaningful when `underlying == .symbol`. Document-discovered
    /// closed set: every form across the validated forest whose head
    /// matches `target_form` contributes its `:name-key` value.
    cross_ref: ?CrossRef = null,
    /// Only meaningful when `underlying == .union_of`. The alternatives
    /// are tried in order; the first successful match wins. A failure
    /// reports the alternative the value's node shape could only have
    /// meant, when there is exactly one (`Validator.determinedArm`);
    /// otherwise the collapsed `union_no_branch_matched`.
    union_of: ?UnionShape = null,
    /// Only meaningful when `underlying == .string`. Length / pattern /
    /// format constraints. Orthogonal to `members`: both may co-exist —
    /// `members` is a closed enum, `string_bounds` is an additional
    /// predicate. The loader cross-checks that every member literal
    /// satisfies the declared bounds (length + format), so the validator
    /// can apply members-or-bounds in either order without divergence.
    /// All four sub-fields default `null`, so non-string kinds pay only
    /// one optional-pointer slot.
    string_bounds: ?StringBounds = null,
    /// Only meaningful when `underlying == .number`. GPU representation
    /// tag (`f32`/`u32`/`i32`/`u16`/`f16`). Orthogonal to `unit` and
    /// `numeric` — all three may co-exist and each is checked
    /// independently. Drives range/integrality validation
    /// (`repr_out_of_range`) and the schema export's `x-sjon-gpu-repr`
    /// annotation + branded TS alias. `null` = no GPU-type narrowing.
    repr: ?Repr = null,

    /// `Tag.keyword`, `boolean`, and `nil` are intentionally absent.
    /// `keyword`: greedy pairing rule means it cannot occur as a kvpair value.
    /// `boolean` / `nil`: cardinality is fixed (2 / 1) — no meaningful
    /// refinement axis. `symbol` is included because closed-set enumeration
    /// (via `members`) is a meaningful refinement. `union_of` delegates
    /// to a closed list of alternative value-kinds — the only refinement
    /// whose dispatch is "try until one accepts".
    pub const Underlying = enum { number, string, vector, form, symbol, union_of };

    /// GPU representation tag for a `.number` underlying. Opt-in via
    /// `:repr (repr-shape :type <f32|u32|i32|u16|f16>)`. Names the machine
    /// type a downstream GPU emitter encodes the number as, so (a) the
    /// schema export can surface it (`x-sjon-gpu-repr` + a branded TS
    /// alias) and (b) the validator rejects a literal that doesn't fit the
    /// type's range / integrality before the emitter silently wraps it.
    ///
    /// Orthogonal to `unit` and `numeric` — all three may co-exist on one
    /// kind and each is checked independently. The tag names are a
    /// wire-stable surface (they appear in the JSON-Schema annotation and
    /// the conformance corpus): append-only, never reorder / rename.
    ///
    /// Primitive type names require `@"…"` quoting as enum tags; `@tagName`
    /// still yields the bare `"f32"` … `"f16"` strings used on the wire.
    pub const Repr = enum {
        f32,
        u32,
        i32,
        u16,
        f16,

        /// The closed (min, max, integer) triple a literal must satisfy to
        /// fit this GPU type. Range-only: precision narrowing (e.g.
        /// `16777217` losing its low bit in f32) is the emitter's accepted
        /// lossy step, not a validation failure. Every bound is exact in
        /// f64 — the integer maxes are all < 2^53, and the float maxes are
        /// f32/f16 magnitudes that widen to f64 losslessly.
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
        /// Required element count. `null` accepts any length.
        len: ?u16 = null,
        /// Inclusive lower bound on element count (`:min-len`). `null` = no
        /// floor. Mutually exclusive with `len` (a fixed length subsumes a
        /// range); the loader emits `vector_bounds_invalid` on the clash.
        min_len: ?u16 = null,
        /// Inclusive upper bound on element count (`:max-len`). `null` = no
        /// ceiling. Mutually exclusive with `len`.
        max_len: ?u16 = null,
        /// Element kind name. Resolved via `Schema.lookupValueKind` or one
        /// of the primitive shortcuts ("number", "string", "symbol",
        /// "form", "any"). `element.namespace` is non-null when the
        /// author wrote `plugin/kind`; bare references resolve when
        /// unambiguous.
        element: QualifiedRef,
    };

    pub const UnitShape = struct {
        /// If true, a bare `Tag.number` (no unit) is rejected.
        required: bool = false,
        /// If true, a `Tag.number_with_unit` (a number carrying *any* unit
        /// suffix) is rejected — the slot demands bare numbers only. Closes
        /// the silent `1.0f → 0` defect where a stray suffix on a plain
        /// numeric slot validates and the consumer drops it. Mutually
        /// exclusive with `required` (which demands a unit) and with a
        /// non-empty `allowed` (which lists permitted units): the loader
        /// emits `invalid_manifest` on either clash.
        reject: bool = false,
        /// Allowed unit suffixes. Empty slice = any non-empty unit accepted.
        allowed: []const []const u8 = &.{},
    };

    /// Numeric range / integrality constraints for `.number` underlying.
    /// Bounds may carry a unit; semantics in `Validator.matchValueAgainstKind`.
    /// `exclusive_min`/`exclusive_max` are only meaningful when the matching
    /// bound is non-null; loader emits `numeric_bounds_invalid` otherwise.
    pub const NumericBounds = struct {
        min: ?Bound = null,
        max: ?Bound = null,
        exclusive_min: bool = false,
        exclusive_max: bool = false,
        integer: bool = false,
        /// Divisibility constraint: the value must be an exact multiple of
        /// this bound. Carries a unit like `min` / `max`, under the same
        /// byte-equality rule, so `:multiple-of 256b` beside `:min 0b` is
        /// expressible. `null` = no divisibility constraint.
        ///
        /// The loader rejects zero and non-finite divisors
        /// (`numeric_bounds_invalid`, error) and warns on a *fractional*
        /// one, because the check runs in exact integer space only when
        /// both the value and the divisor are integral — the alignment
        /// case every GPU schema actually wants. See
        /// `Validator.checkNumericBoundsValue`.
        multiple_of: ?Bound = null,

        /// A bound value with optional unit. `unit` is borrowed from the
        /// schema arena (interned string-pool lifetime).
        pub const Bound = struct {
            value: f64,
            /// When non-null, the value being validated must carry a
            /// byte-equal unit suffix.
            unit: ?[]const u8 = null,
            /// True when the literal was lexed as `Tag.number_i64` /
            /// `Tag.number_u64`. Lets the validator use integer-space
            /// comparison when the value is also exact, avoiding f64
            /// round-trip loss above 2^53.
            exact_int: bool = false,
        };
    };

    /// Length / pattern / format constraints for `.string` underlying.
    /// Each sub-field is independent and may be `null`. The validator
    /// applies them in cheapest-to-most-expensive order: length first,
    /// then `:format` (O(n) hand-written checker), then `:pattern` (v1
    /// emits a `string_pattern_unsupported` warning rather than running
    /// a regex; engine landing is a follow-up milestone).
    ///
    /// Length is measured in UTF-8 codepoints (not bytes), since the
    /// parser guarantees well-formed UTF-8 and codepoint count matches
    /// the user's mental model for "characters".
    ///
    /// The set of accepted formats is closed (see `Format`); unknown
    /// formats are rejected at manifest load.
    pub const StringBounds = struct {
        /// Inclusive lower bound on UTF-8 codepoint count.
        min_len: ?u32 = null,
        /// Inclusive upper bound on UTF-8 codepoint count.
        max_len: ?u32 = null,
        /// Raw pattern source, interned in the schema arena. v1 stores
        /// but does not execute — validator emits
        /// `string_pattern_unsupported` instead of `string_pattern_mismatch`.
        pattern: ?[]const u8 = null,
        /// Named, closed format. Loader rejects unknown names; the
        /// `string-format-tag` value-kind in the meta-schema gates entry.
        format: ?Format = null,

        /// Closed set of named string formats. Append-only — adding new
        /// variants is wire-stable, reordering / renaming is not.
        pub const Format = enum { email, uri, path, uuid, semver };
    };

    /// Closed-set membership constraint for `.symbol` and `.string`
    /// underlyings. Comparison is byte-equality on `Member.name`.
    ///
    /// For `.symbol` underlying: each `Member.name` is a bare symbol
    /// identifier (e.g. `"ortho"`, no leading `:`). For `.string`
    /// underlying: literal contents (e.g. `"rgb"`).
    ///
    /// `members` must be non-empty. An empty list is treated as "no
    /// narrowing" by the validator (same as the outer `members = null`);
    /// plugin authors should set the field to null rather than supply
    /// `&.{}`.
    pub const MemberSet = struct {
        members: []const Member,

        /// One entry in a `MemberSet`. `name` is the only required field
        /// and is what the validator matches against (byte-equality).
        /// The remaining fields are optional editor/UX metadata: empty
        /// strings count as "absent" everywhere, so plugin authors only
        /// fill what they need. Wire syntax: either compact
        /// (`(member-set :values [a b c])` → one entry per name with
        /// only `name` set) or rich (`(member-set (member :name a …))`
        /// — see `docs/portable-manifest-v1.md` §4.4).
        pub const Member = struct {
            name: []const u8,
            label: []const u8 = "",
            description: []const u8 = "",
            /// When true, the validator emits a `deprecated_member`
            /// warning on use and the LSP tags completions as
            /// deprecated. Membership itself still passes.
            deprecated: bool = false,
            /// Optional replacement hint shown alongside the warning /
            /// hover when `deprecated == true`. Empty = generic prose.
            deprecation_message: []const u8 = "",
            /// Set when this member's declared spelling is digit-leading
            /// (`1d`, `2d`, `50%`) and therefore cannot be written as a
            /// bare symbol — the lexer reads it as a unit-bearing number.
            /// `name` still holds the spelling (`"2d"`), so diagnostics,
            /// exports, and completions are unchanged in shape; this is
            /// the **match key**, because the validator compares a parsed
            /// `(value, unit)` pair rather than text. Two reasons for the
            /// pair: the binary walker has no source text to compare
            /// against, and the pair makes `2d`, `2.0d`, and `02d` the
            /// same member for free.
            ///
            /// Null for ordinary symbol members, which is every member
            /// declared before format 1.3. Meaningful only on a
            /// `.symbol` underlying — the loader rejects it elsewhere.
            numeric_spelling: ?NumericSpelling = null,
        };

        /// The parsed `(value, unit)` identity of a digit-leading member
        /// spelling.
        pub const NumericSpelling = struct {
            /// The spelling's numeric portion, which the loader has
            /// already checked is a non-negative integer at or below
            /// `MAX_SPELLING_VALUE`. Integer-keyed on purpose: no f64
            /// equality, and it is the range where every host's
            /// number→text agrees, so the canonical `Member.name` the
            /// loader derives is byte-identical across the four
            /// exporters.
            value: u64,
            /// Unit suffix, interned in the schema arena. Never empty — a
            /// unitless number is not a member spelling, and the loader
            /// rejects one.
            unit: []const u8,

            /// 2^53, the f64 exact-integer ceiling. A member spelling is
            /// an enum name, so nothing real comes close; the cap exists
            /// so the value has one text form in every host rather than
            /// diverging into exponent notation.
            pub const MAX_SPELLING_VALUE: u64 = 1 << 53;

            /// The integer key for a literal's magnitude, or null when
            /// that magnitude cannot be a member spelling: non-finite,
            /// fractional, negative, or above `MAX_SPELLING_VALUE`.
            ///
            /// The loader's rejection and the validator's match test are
            /// the same question, so they ask it here rather than each
            /// spelling out four conditions. Rejecting a fractional
            /// magnitude is what keeps `2.5d` from rounding into `2d`.
            pub fn keyOf(magnitude: f64) ?u64 {
                if (!std.math.isFinite(magnitude)) return null;
                if (@floor(magnitude) != magnitude) return null;
                if (magnitude < 0) return null;
                if (magnitude > @as(f64, @floatFromInt(MAX_SPELLING_VALUE))) return null;
                return @intFromFloat(magnitude);
            }

            /// The canonical spelling of a `(key, unit)` pair. The loader
            /// derives `Member.name` with it, so `02d` and `2.0d` both
            /// declare `2d`; the validator names a member it matched
            /// numerically with it. One function, so a spelling cannot
            /// read one way in a manifest and another in a diagnostic.
            pub fn canonical(
                a: std.mem.Allocator,
                key: u64,
                unit: []const u8,
            ) std.mem.Allocator.Error![]const u8 {
                return std.fmt.allocPrint(a, "{d}{s}", .{ key, unit });
            }
        };
    };

    /// Closed-set head-name constraint for `.form` underlying. The
    /// validator structurally checks the form's head against each
    /// `Head.name` (byte-equality, no namespace canonicalisation —
    /// that's a host concern). Useful for slot pinning like
    /// `:shape (point | rect | circle)`.
    ///
    /// `heads` must be non-empty. An empty list is treated as "no
    /// narrowing" by the validator (same as `heads = null`) — and by the
    /// positional count sweep, which therefore tallies nothing even when
    /// the set declares `min_children`. Plugin authors should set the
    /// field to null rather than supply `&.{}`; the loader refuses
    /// `(head-set)` outright, so only a Zig-constructed schema can get
    /// here. Mirrors `MemberSet`'s rule, which `matchScalar` enforces.
    ///
    /// Counts come at two levels, and both are enforced at a form's
    /// `:positional` slot and inert anywhere else the same kind is
    /// reused (a keyed slot holds one value; a `vector-shape :element`
    /// is a value, not a child list). See
    /// `docs/portable-manifest-v1.md` §4.5.
    ///
    ///   * **Per head** — `Head.min` / `Head.max`: how many positional
    ///     children may (or must) carry *that* head.
    ///   * **Over the set** — `min_children` / `max_children`: how many
    ///     children of *any* head in the set the slot holds. "Exactly
    ///     one of buffer / sampler / texture" is this level and cannot
    ///     be said by the first: every per-head bound is satisfied by a
    ///     form carrying one of each, and by a form carrying none.
    ///
    /// The two are independent. `:max-children 2` over heads each
    /// `:max 1` ("one of each, up to two") needs both; `:min-children 1
    /// :max-children 1` over heads each `:max 1` is "exactly one, and
    /// not two of the same", where the per-head ceilings are redundant
    /// with the set's. That redundancy is why the validator states a
    /// suppression rule — see `Validator.tallyPositionalHead`.
    pub const HeadSet = struct {
        heads: []const Head,

        /// Inclusive floor on how many positional children of the
        /// enclosing form may carry *any* head in this set. 0 = no
        /// floor. Wire syntax: `(head-set :min-children 1 …)`.
        min_children: u16 = 0,
        /// Inclusive ceiling over the whole set. `null` = unbounded.
        max_children: ?u16 = null,

        /// True when neither level carries a count bound — no head, and
        /// not the set. This is the fast path for the validator's
        /// per-form count sweep: nothing to tally, so the counters are
        /// never allocated.
        ///
        /// Note that the compact `:names [a b c]` spelling no longer
        /// implies this. It cannot carry a *per-head* bound (that needs
        /// `(head …)` children), but `:min-children` / `:max-children`
        /// sit on the set itself and are legal beside it — deliberately,
        /// since "exactly one of these four" wants no per-head metadata.
        pub fn isUnbounded(self: HeadSet) bool {
            if (self.min_children != 0 or self.max_children != null) return false;
            for (self.heads) |h| if (h.min != 0 or h.max != null) return false;
            return true;
        }

        /// One entry in a `HeadSet`. `name` is the only required field
        /// and is what the validator matches against (byte-equality).
        /// Wire syntax: either compact (`(head-set :names [a b c])` →
        /// one unbounded entry per name) or rich
        /// (`(head-set (head :name a :min 1 :max 1) …)`) — see
        /// `docs/portable-manifest-v1.md` §4.5.
        pub const Head = struct {
            name: []const u8,
            /// Inclusive floor on how many positional children of the
            /// enclosing form may carry this head. 0 = no floor (the
            /// default, and what every compact-spelling head gets).
            min: u16 = 0,
            /// Inclusive ceiling. `null` = unbounded.
            max: ?u16 = null,
            /// Author-supplied editor metadata; the validator ignores it.
            description: []const u8 = "",
        };
    };

    /// Alternative-list constraint for `.union_of` underlying. Each
    /// alternative names a value-kind (or a primitive shortcut: `number`,
    /// `string`, `vector`, `form`, `symbol`, `any`) declared elsewhere in
    /// the schema. The validator tries alternatives in declaration order;
    /// the first whose own constraints accept the value wins. Nesting —
    /// an alternative that itself resolves to another union — is rejected
    /// at schema-aggregate time so dispatch stays a flat loop.
    ///
    /// `alternatives` must have ≥ 2 entries; single-alt unions are a bug
    /// (the underlying kind would be a cleaner spelling). Each alternative
    /// may be qualified (`plugin/kind`) when the bare name would collide
    /// across plugins; bare names resolve when unambiguous.
    pub const UnionShape = struct {
        alternatives: []const QualifiedRef,
    };

    /// Document-spanning name-reference constraint for `.symbol`
    /// underlying. The set of acceptable values is the names supplied by
    /// every listed target form anywhere in the validated forest.
    /// Resolution lives in the validator, not the manifest — the registry
    /// is rebuilt on every validate call.
    ///
    /// **Two routes to those names**, mutually exclusive and separated at
    /// manifest-load time:
    ///   * **identity** (`name_key`, the default) — each instance's name
    ///     is the symbol under that keyword child. Today's behaviour.
    ///   * **provider** (`provider` + `source_key`) — each instance
    ///     carries an opaque *string* under `source_key`, and the named
    ///     `CrossRefProvider` extracts the names from it. The extraction
    ///     itself runs in a host pre-pass, never in the validator.
    ///
    /// `targets` holds the head names of the forms whose instances supply
    /// names (e.g. `"phrase"` for `:sequence` slots referencing
    /// `(phrase :name p0 …)`). Each manifest spelling is kept verbatim
    /// here, possibly qualified; the validator's index pass canonicalises
    /// each once per validate call (`Schema.canonicalFormName`) to the
    /// **qualified** `<plugin>/<form>` spelling and matches form heads
    /// against that.
    ///
    /// `.len >= 1` always. With more than one entry the listed targets
    /// share **one namespace**: a name supplied by any of them satisfies a
    /// reference, and a name supplied by two of them is
    /// `duplicate_cross_ref_target` — caught at the declaration rather
    /// than silently resolved to whichever target the walk reached first.
    /// `:acyclic true` is rejected at load with more than one target
    /// (cycle edges are defined over a target's *self*-referential keys,
    /// and "self" is not well defined across a group).
    ///
    /// `name_key` is the kvpair key under which each instance carries
    /// its name on the identity route. Defaults to `"name"`.
    ///
    /// `provider` is the possibly-qualified `CrossRefProvider` name on the
    /// provider route; null means the identity route. `source_key` is the
    /// kvpair key holding the string handed to it (default `"src"`), and
    /// is meaningless — rejected at load — without `provider`.
    ///
    /// `acyclic`, when true, asks the validator to detect cycles among
    /// edges declared on the sole target's self-referential keys (any key
    /// whose effective `value_type` resolves back to this kind, scalar
    /// or single-vector hop). Used for `:parent`-style chains;
    /// `cyclic_cross_ref` diagnostics fire at validate time. Identity
    /// route only: cycle edges are defined over per-name declaration
    /// sites, and extracted names share one source span.
    ///
    /// `scope_form` opts the cross-ref into per-form lexical scoping —
    /// each instance of `scope_form` (qualified or bare) opens a fresh
    /// scope; references resolve only against names defined inside the
    /// nearest enclosing instance. Null = tree-scoped (PR 2 default).
    /// Example: `(cross-ref :target phrase :scope piece)` → each
    /// `(piece …)` carries its own `phrase` registry. Composes with both
    /// routes.
    pub const CrossRef = struct {
        /// The listed target forms, in manifest order. Never empty.
        targets: []const []const u8,
        name_key: []const u8 = "name",
        acyclic: bool = false,
        scope_form: ?[]const u8 = null,
        /// Provider route: possibly-qualified `CrossRefProvider` name.
        /// Null = identity route. Never set together with a non-default
        /// `name_key` — the loader rejects the combination.
        provider: ?[]const u8 = null,
        /// Provider route: kvpair key on each target whose string value is
        /// handed to the provider. Read on *every* listed target. Ignored
        /// on the identity route.
        source_key: []const u8 = "src",

        /// Allocate a one-element `targets` slice, name included. The
        /// literal `&.{"phrase"}` spelling only works when the name is
        /// comptime-known; a loader or host building one from a runtime
        /// string needs this. Both the slice and the name are owned by `a`.
        pub fn dupeOne(
            a: std.mem.Allocator,
            target: []const u8,
        ) std.mem.Allocator.Error![]const []const u8 {
            const list = try a.alloc([]const u8, 1);
            list[0] = try a.dupe(u8, target);
            // The write half of the `.len >= 1` invariant three readers
            // assert (`soleTarget`, `describeTargets`, `crossRefBucketKey`).
            std.debug.assert(list.len == 1);
            return list;
        }

        /// The single target, or null when this cross-ref lists several.
        /// The axes that are single-target *by construction* — cycle
        /// detection, which the loader rejects for a group — read through
        /// this rather than indexing `targets[0]`, so the assumption is
        /// stated where it is relied on instead of being implied by a
        /// subscript.
        pub fn soleTarget(self: CrossRef) ?[]const u8 {
            std.debug.assert(self.targets.len >= 1);
            return if (self.targets.len == 1) self.targets[0] else null;
        }

        /// Render the target list for a human-facing message: the bare
        /// spelling for one target (no allocation, and every existing
        /// message stays byte-identical), `a | b` for a group — the same
        /// separator the union and member-set messages use for "one of
        /// these".
        ///
        /// **Ownership depends on the count**, which is why every caller
        /// passes an arena: one target returns a slice *borrowed* from the
        /// schema, several return a fresh allocation on `a`. There is no
        /// unconditional `free` for the result, so do not call this with an
        /// allocator whose frees you have to pair by hand.
        pub fn describeTargets(
            self: CrossRef,
            a: std.mem.Allocator,
        ) std.mem.Allocator.Error![]const u8 {
            std.debug.assert(self.targets.len >= 1);
            if (self.targets.len == 1) return self.targets[0];
            return std.mem.join(a, " | ", self.targets);
        }

        /// True when `name` is one of the listed targets, compared
        /// verbatim (pre-canonicalisation). For loader-side checks only;
        /// the validator compares canonical names.
        pub fn listsTarget(self: CrossRef, name: []const u8) bool {
            for (self.targets) |t| if (std.mem.eql(u8, t, name)) return true;
            return false;
        }
    };
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "ExprFunc.checkArity fixed" {
    const f: ExprFunc = .{ .name = "vec3", .arity = .{ .fixed = 3 } };
    try testing.expect(!f.checkArity(2));
    try testing.expect(f.checkArity(3));
    try testing.expect(!f.checkArity(4));
}

test "ExprFunc.checkArity at_least" {
    const f: ExprFunc = .{ .name = "+", .arity = .{ .at_least = 0 } };
    try testing.expect(f.checkArity(0));
    try testing.expect(f.checkArity(7));
}

test "ExprFunc.checkArity range" {
    const f: ExprFunc = .{ .name = "if", .arity = .{ .range = .{ .min = 2, .max = 3 } } };
    try testing.expect(!f.checkArity(1));
    try testing.expect(f.checkArity(2));
    try testing.expect(f.checkArity(3));
    try testing.expect(!f.checkArity(4));
}

test "Plugin defaults compile" {
    const p: Plugin = .{ .name = "x" };
    try testing.expectEqualStrings("x", p.name);
    try testing.expectEqual(@as(usize, 0), p.forms.len);
    try testing.expectEqual(@as(usize, 0), p.expr_funcs.len);
}

test "FormSpec.lowering defaults to null" {
    const f: FormSpec = .{ .name = "scene" };
    try testing.expect(f.lowering == null);
}

test "FormSpec.lowering carries hook + produces" {
    const f: FormSpec = .{
        .name = "pass",
        .lowering = .{
            .hook = "pngine/pass-v1",
            .produces = &.{ "shader", "texture", "pipeline" },
        },
    };
    try testing.expect(f.lowering != null);
    try testing.expectEqualStrings("pngine/pass-v1", f.lowering.?.hook);
    try testing.expectEqual(@as(usize, 3), f.lowering.?.produces.len);
    try testing.expectEqualStrings("shader", f.lowering.?.produces[0]);
    try testing.expectEqualStrings("texture", f.lowering.?.produces[1]);
    try testing.expectEqualStrings("pipeline", f.lowering.?.produces[2]);
}

test "KeySpec.effectiveOptional reflects default presence" {
    var k: KeySpec = .{ .name = "title", .optional = false };
    try testing.expect(!k.effectiveOptional());
    k.default = .{ .string = "Untitled" };
    try testing.expect(k.effectiveOptional());
}

test "KeySpec.local_forms defaults to empty" {
    const k: KeySpec = .{ .name = "shape" };
    try testing.expectEqual(@as(usize, 0), k.local_forms.len);
}

test "KeySpec.local_forms carries inline FormSpec cycle" {
    // FormSpec → KeySpec → FormSpec recurses through slices: a slot whose
    // local form itself declares a local-form slot must compile and round-trip.
    const k: KeySpec = .{
        .name = "shape",
        .value_type = .form,
        .local_forms = &.{
            .{
                .name = "group",
                .keys = &.{
                    .{
                        .name = "child",
                        .value_type = .form,
                        .local_forms = &.{
                            .{ .name = "circle", .keys = &.{
                                .{ .name = "r", .value_type = .number, .optional = false },
                            } },
                        },
                    },
                },
            },
        },
    };
    try testing.expectEqual(@as(usize, 1), k.local_forms.len);
    try testing.expectEqualStrings("group", k.local_forms[0].name);
    const nested = k.local_forms[0].keys[0].local_forms;
    try testing.expectEqual(@as(usize, 1), nested.len);
    try testing.expectEqualStrings("circle", nested[0].name);
}

test "ExprFunc.signatureIter mono surfaces single derived signature" {
    const f: ExprFunc = .{
        .name = "vec3",
        .arity = .{ .fixed = 3 },
        .params = &[_]ValueType{ .number, .number, .number },
        .result = .vector,
    };
    var it = f.signatureIter();
    const first = it.next() orelse return error.TestUnexpectedResult;
    try testing.expect(first.checkArity(3));
    try testing.expectEqual(ValueType.number, first.paramType(0).?);
    try testing.expectEqual(ValueType.number, first.paramType(2).?);
    try testing.expect(it.next() == null);
    try testing.expectEqual(@as(usize, 1), f.signatureCount());
}

test "ExprFunc.signatureIter overloaded yields each declared signature" {
    const sigs = [_]ExprFunc.Signature{
        .{ .arity = .{ .fixed = 3 }, .params = &[_]ValueType{ .number, .number, .number }, .result = .number },
        .{ .arity = .{ .fixed = 3 }, .params = &[_]ValueType{ .vector, .vector, .number }, .result = .vector },
    };
    const f: ExprFunc = .{ .name = "lerp", .signatures = &sigs };
    try testing.expectEqual(@as(usize, 2), f.signatureCount());
    try testing.expect(f.checkArity(3));
    try testing.expect(!f.checkArity(2));
    var it = f.signatureIter();
    const first = it.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(ValueType.number, first.paramType(0).?);
    const second = it.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(ValueType.vector, second.paramType(0).?);
    try testing.expect(it.next() == null);
}

test "ExprFunc.checkArity unions arity across overloads" {
    const sigs = [_]ExprFunc.Signature{
        .{ .arity = .{ .fixed = 1 } },
        .{ .arity = .{ .fixed = 3 } },
    };
    const f: ExprFunc = .{ .name = "weird", .signatures = &sigs };
    try testing.expect(f.checkArity(1));
    try testing.expect(!f.checkArity(2));
    try testing.expect(f.checkArity(3));
    try testing.expect(!f.checkArity(4));
}

test "ValueKind.NumericBounds defaults are all null/false" {
    const nb: ValueKind.NumericBounds = .{};
    try testing.expect(nb.min == null);
    try testing.expect(nb.max == null);
    try testing.expect(!nb.exclusive_min);
    try testing.expect(!nb.exclusive_max);
    try testing.expect(!nb.integer);
}

test "ValueKind.NumericBounds.Bound carries unit + exact_int" {
    const b: ValueKind.NumericBounds.Bound = .{
        .value = 1000.0,
        .unit = "ms",
        .exact_int = true,
    };
    try testing.expectEqual(@as(f64, 1000.0), b.value);
    try testing.expectEqualStrings("ms", b.unit.?);
    try testing.expect(b.exact_int);
}

test "ValueKind carries numeric refinement alongside unit" {
    const vk: ValueKind = .{
        .name = "duration-ms",
        .underlying = .number,
        .unit = .{ .required = true, .allowed = &.{"ms"} },
        .numeric = .{
            .min = .{ .value = 0.0 },
            .max = .{ .value = 10000.0, .exact_int = true },
        },
    };
    try testing.expect(vk.unit != null);
    try testing.expect(vk.numeric != null);
    try testing.expectEqual(@as(f64, 0.0), vk.numeric.?.min.?.value);
    try testing.expectEqual(@as(f64, 10000.0), vk.numeric.?.max.?.value);
    try testing.expect(vk.numeric.?.max.?.exact_int);
}

test "QualifiedRef defaults namespace to null" {
    const r: QualifiedRef = .{ .name = "color" };
    try testing.expectEqualStrings("color", r.name);
    try testing.expect(r.namespace == null);
}

test "ValueType.named carries namespace alongside name" {
    const bare: ValueType = .{ .named = .{ .name = "color" } };
    const qualified: ValueType = .{ .named = .{ .name = "color", .namespace = "paint" } };
    try testing.expectEqualStrings("color", bare.named.name);
    try testing.expect(bare.named.namespace == null);
    try testing.expectEqualStrings("color", qualified.named.name);
    try testing.expectEqualStrings("paint", qualified.named.namespace.?);
}

test "PositionalSpec.kind carries namespace" {
    const ps: PositionalSpec = .{ .kind = .{ .name = "color", .namespace = "paint" } };
    switch (ps) {
        .kind => |q| {
            try testing.expectEqualStrings("color", q.name);
            try testing.expectEqualStrings("paint", q.namespace.?);
        },
        else => return error.TestExpectedKind,
    }
}

test "VectorShape.element and UnionShape.alternatives accept qualified refs" {
    const vs: ValueKind.VectorShape = .{ .element = .{ .name = "color", .namespace = "paint" } };
    try testing.expectEqualStrings("paint", vs.element.namespace.?);

    const alts = [_]QualifiedRef{
        .{ .name = "color", .namespace = "paint" },
        .{ .name = "swatch" },
    };
    const us: ValueKind.UnionShape = .{ .alternatives = &alts };
    try testing.expectEqual(@as(usize, 2), us.alternatives.len);
    try testing.expectEqualStrings("paint", us.alternatives[0].namespace.?);
    try testing.expect(us.alternatives[1].namespace == null);
}
