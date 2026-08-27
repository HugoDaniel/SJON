//! Intermediate representation consumed by both schema-export backends.
//!
//! The IR is a 1:1 transformation of `Schema.Schema` into a shape that
//! has already resolved every `Plugin.ValueType.named` reference and
//! classified every refinement axis. Backends (`JsonSchema`, `TsTypes`)
//! walk the IR mechanically; lossy-mapping decisions, name collision
//! resolution, and warning emission live in `SchemaExport.zig`'s
//! lowering pass and not in the backends.
//!
//! Lifetime: every slice and string in this module is owned by the
//! enclosing `ExportResult.arena`. The IR is read-only after lowering.

const std = @import("std");
const Plugin = @import("../Plugin.zig");

/// Top-level export bundle.
pub const Model = struct {
    plugins: []const Plugin_,
    /// Format version stamp, copied onto every emitted artifact's
    /// `x-sjon-export-version` annotation.
    version: u32 = 1,
};

/// One emitted plugin namespace.
pub const Plugin_ = struct {
    name: []const u8,
    version: []const u8 = "",
    description: []const u8 = "",
    forms: []const Form,
    value_kinds: []const ValueKindEntry,
    /// Expression functions, presentation-lowered (see `ExprFuncEntry`).
    /// Consumed by the Markdown backend; the JSON Schema / TS backends
    /// ignore them (expr-funcs have no object shape to emit), and the
    /// intermediate writer deliberately omits them so its goldens stay
    /// byte-stable.
    expr_funcs: []const ExprFuncEntry = &.{},
};

/// One expression function. The lowering pass pre-renders each
/// overload's signature text so backends stay mechanical —
/// `Plugin.ValueType` never crosses into the IR.
pub const ExprFuncEntry = struct {
    name: []const u8,
    description: []const u8 = "",
    /// One rendered signature per overload (exactly one for the mono
    /// encoding), e.g. `(lerp a: number b: number t: number) -> number`.
    /// Opaque slots render as `_`, a variadic tail as `…type`.
    signatures: []const []const u8,
};

/// A resolved form spec.
pub const Form = struct {
    name: []const u8,
    description: []const u8 = "",
    keys: []const Key,
    positional: Positional,
    /// `true` when the source `FormSpec.open` is true — extra unknown
    /// keys round-trip via the canonical JSON bridge's `$$`-escape.
    open: bool = false,
    /// Discriminator + variants snapshot. M1 emits these as deferred
    /// stubs with warnings; full encoding lands in M2.
    discriminator: ?Discriminator = null,
    /// Source-level exclusive groups. M1 carries them through as
    /// annotation-only data; M2 wires them to `oneOf`/`not`.
    exclusive_groups: []const ExclusiveGroup = &.{},
    /// Lowering hook declaration, when one is attached. Annotation-only
    /// in every milestone — host owns the hook implementation.
    lowering: ?Lowering = null,
    /// Positional keyword flags declared via `:positional (flag-set …)`,
    /// or `null` when the form's positional is not a flag-set. The
    /// `positional` field itself widens to `.any` (flags don't constrain a
    /// child *value shape*); these carry the names + metadata for the
    /// `x-sjon-positional-flags` annotation. Annotation-only.
    positional_flags: ?[]const PositionalFlag = null,
};

/// One positional keyword flag carried through from a `(flag-set …)`
/// slot for the `x-sjon-positional-flags` annotation. `description`/`link`
/// are author-supplied tooling metadata (`""` / `null` when omitted).
pub const PositionalFlag = struct {
    name: []const u8,
    description: []const u8 = "",
    link: ?[]const u8 = null,
};

/// One declared `:key value` slot on a form.
pub const Key = struct {
    name: []const u8,
    /// `true` when the key may be omitted. Combines the explicit
    /// `optional` flag with the implicit "has-default ⇒ optional"
    /// rule via `Plugin.KeySpec.effectiveOptional()`.
    optional: bool,
    description: []const u8 = "",
    value: ValueShape,
    default: ?Default = null,
    /// Sibling keys this key's presence demands, from
    /// `Plugin.KeySpec.requires`. Exports exactly on the JSON Schema
    /// channel as `dependentRequired`; TypeScript cannot express it in a
    /// plain interface, so it rides the JSDoc there.
    requires: []const []const u8 = &.{},
};

/// What kind of positional children a form accepts. Mirrors
/// `Plugin.PositionalSpec` but the `.kind` variant carries the resolved
/// `ValueShape` so backends don't have to re-walk the schema.
pub const Positional = union(enum) {
    none,
    any,
    kind: ValueShape,
};

/// Discriminator snapshot. Backends use this to detect a discriminated
/// form; M1 emits stubs + warnings.
pub const Discriminator = struct {
    key_name: []const u8,
    variants: []const Variant,
};

/// One variant gate. `keys` lists the variant-only keys; backends emit
/// them as additional optional properties with annotations. `when` is the
/// discriminant value list that selects the variant (`Plugin.Variant.when`,
/// `.len >= 1`): a one-value variant emits exactly as it did when `:when`
/// took one symbol (`const` / `Symbol_<"a">` / `"when": "a"`), a
/// multi-value one guards the same single branch with an enum
/// (`enum` / `Symbol_<"a" | "b">` / `"when": ["a", "b"]`) — the shape does
/// not multiply the output.
pub const Variant = struct {
    when: []const []const u8,
    keys: []const Key,
};

/// One exclusive-group constraint passed through annotation-only.
pub const ExclusiveGroup = struct {
    cardinality: Plugin.Cardinality,
    /// Alternatives expressed as key-name bundles. v1 is always one
    /// name per bundle; the slice-of-slices shape leaves headroom for
    /// multi-key bundles without an IR break.
    alternatives: []const []const []const u8,
};

/// Lowering hook annotation. Always annotation-only in emit.
pub const Lowering = struct {
    hook: []const u8,
    produces: []const []const u8,
};

/// Resolved value shape. Branches mirror `Plugin.ValueType` + every
/// refinement axis flattened to its own variant. The lowering pass
/// resolves `.named` references one hop deep; backends walk this
/// directly.
pub const ValueShape = union(enum) {
    any,
    nil,
    boolean,
    number,
    /// Exact 64-bit signed integer (lexed `Tag.number_i64`).
    number_i64,
    /// Exact 64-bit unsigned integer (lexed `Tag.number_u64`). Backends
    /// must handle the `value > i64.max` case where the JSON bridge
    /// emits a digit-string.
    number_u64,
    /// Number slot with numeric bounds (min/max + exclusive flags +
    /// integer flag). Carries no unit — the unit-bearing case is
    /// `number_with_unit` whose `UnitShape.bounds` propagates the same
    /// magnitude constraints.
    number_bounded: NumericBounds,
    /// `number_with_unit` slot. M1 emits as a stub.
    number_with_unit: UnitShape,
    string,
    /// String slot with bounds (length / pattern / format). Carried
    /// through; the bounds are annotation-only on most channels.
    string_with_bounds: StringBounds,
    symbol,
    /// Symbol member-set (compact). Each entry is the bare symbol
    /// name; backends translate to `{$sym: "name"}` for JSON Schema and
    /// `Symbol_<"name">` for TS.
    symbol_members: []const []const u8,
    /// Symbol member-set (rich variant). Each entry carries metadata.
    /// M1 emits the compact projection + a warning.
    symbol_members_rich: []const Member,
    /// String member-set (compact).
    string_members: []const []const u8,
    /// String member-set (rich variant).
    string_members_rich: []const Member,
    date,
    time,
    keyword,
    vector: VectorShape,
    /// Any form with the matching head set (form-as-slot).
    form_any,
    /// **Closed** set of accepted form heads — the slot rejects any head
    /// outside it (`not_head_member`), so backends emit `oneOf` with no
    /// open branch. Each entry carries the head's `name` and a `body`
    /// saying how the lowering pass resolved it *at the slot this shape
    /// was lowered for*: a `$ref` into `#/$defs` for a global, the
    /// inline body for a slot-local, a head-pin for neither. The TS
    /// backend uses `name` alone for `{$form: "<name>"}` discrimination
    /// on a global and the inline literal on a local.
    ///
    /// A head-set slot that also declares locals lands here, **not** in
    /// `form_locals`: the validator applies both mechanisms in order
    /// (narrow by head text, then resolve the narrowed head local-first),
    /// so the export has to say both. Overwriting one with the other is
    /// what dropped the narrowing, the `x-sjon-head-set` annotation and
    /// the per-head `contains` bounds from every such slot before S7b.
    ///
    /// The payload is a struct rather than a bare `[]const FormRef`
    /// because the set carries a bound of its own. S1's per-head counts
    /// ride on each `FormRef` precisely because they *are* per-head;
    /// `:min-children` / `:max-children` belong to the set, and there is
    /// nowhere else for them to live that does not amount to a parallel
    /// array the backends would have to keep aligned by hand.
    form_heads: HeadSetShape,
    /// **Open** slot-local union: the slot resolves these fully-lowered
    /// `Form`s local-first and then falls back additively to *any* global
    /// form, so backends emit an inline anonymous union — one object
    /// schema per local `Form` (reusing the per-form body emitters, so a
    /// discriminated local still gets its if/then) plus a trailing open
    /// generic branch for the fallback.
    ///
    /// This is the shape of a locals slot with **no** head-set: a keyed
    /// `:type form` slot (the loader rejects keyed locals on any other
    /// type, `ManifestLoader.zig:1312`, so a keyed locals slot is always
    /// this one) and a positional slot whose `:positional` is `.any` —
    /// including the implied `.any` the loader writes when locals appear
    /// with no `:positional` at all. Add a head-set and the slot closes,
    /// which is `form_heads` above.
    form_locals: []const Form,
    /// Any safe expression.
    expr,
    /// Cross-ref slot. Always emits a bare-symbol schema + a warning.
    cross_ref: CrossRef,
    /// Union-of alternatives in declared (first-match-dispatch) order.
    /// Each entry carries the alternative's source name (used for the
    /// `x-sjon-union-alternatives` annotation) plus the resolved shape
    /// (consumed by `anyOf` in JSON Schema and a `|`-union in TS).
    union_of: []const UnionAlternative,
    /// Named reference the lowering pass couldn't resolve. Backends
    /// emit as `unknown` + a warning. When the source reference was
    /// qualified (e.g. `paint/color`), `namespace` is non-null so the
    /// downstream artifact can preserve the user's surface text.
    unresolved_named: UnresolvedNamed,

    /// True iff this shape needs the backend to walk through it
    /// recursively (vectors with elements, member-sets, unions, etc.).
    /// Useful for collision detection during TS emission.
    pub fn isCompound(self: ValueShape) bool {
        return switch (self) {
            .vector, .union_of, .symbol_members, .symbol_members_rich, .string_members, .string_members_rich, .form_heads, .form_locals => true,
            else => false,
        };
    }
};

/// A value-kind reference the lowering pass could not resolve to a
/// concrete shape. Carries both the bare name and the optional
/// namespace so the rendered artifact preserves the user's input.
pub const UnresolvedNamed = struct {
    name: []const u8,
    namespace: ?[]const u8 = null,
};

pub const VectorShape = struct {
    /// Required element count. `null` = any length.
    len: ?u16,
    /// Inclusive element-count floor (`:min-len`). Emitted as `minItems`
    /// in JSON Schema. Only meaningful when `len` is null (a fixed length
    /// emits minItems == maxItems == len already).
    min_len: ?u16 = null,
    /// Inclusive element-count ceiling (`:max-len`). Emitted as `maxItems`.
    max_len: ?u16 = null,
    /// Element shape. `.any` when the source had no `:element` slot or
    /// the element was the `any` shortcut.
    element: *const ValueShape,
};

pub const UnitShape = struct {
    /// `true` when the unit suffix must be present (no bare-number form).
    required: bool,
    /// Allowed unit suffixes. Empty = any non-empty unit accepted.
    allowed: []const []const u8,
    /// Numeric bounds on the magnitude slot, propagated when the value
    /// kind also declared `:numeric ...`. The bound applies to the
    /// `prefixItems[0]` (magnitude) entry of the `$num` tuple.
    bounds: ?NumericBounds = null,
};

pub const StringBounds = struct {
    min_len: ?u32 = null,
    max_len: ?u32 = null,
    pattern: ?[]const u8 = null,
    format: ?Plugin.ValueKind.StringBounds.Format = null,
};

/// Numeric bound mirror of `Plugin.ValueKind.NumericBounds`. Each bound
/// carries the value, an optional unit (matched against `UnitShape.allowed`
/// at validation time), and an exact-int flag that flips JSON Schema
/// emission to additionally emit `x-sjon-exact-bound: {"min|max": "<digits>"}`
/// when `|value| > 2^53`.
pub const NumericBounds = struct {
    min: ?Bound = null,
    max: ?Bound = null,
    /// `true` when the source `:exclusive-min` was set.
    exclusive_min: bool = false,
    /// `true` when the source `:exclusive-max` was set.
    exclusive_max: bool = false,
    /// `true` when the source declared the slot as an integer (`:integer true`).
    integer: bool = false,
    /// Divisor from `:multiple-of`. Exports exactly on the JSON Schema
    /// channel — 2020-12's `multipleOf` is "division by this keyword's
    /// value results in an integer", the same claim SJON makes — and is
    /// annotation-only everywhere else.
    multiple_of: ?Bound = null,
    /// GPU representation tag, propagated from `:repr (repr-shape …)`.
    /// Drives the `x-sjon-gpu-repr` JSON Schema annotation and a branded
    /// `F32`…`F16` TS alias. `null` when the source kind declared no
    /// `:repr`. Orthogonal to min/max/integer — a repr-only kind lowers
    /// to `number_bounded` with all of those null/false and just `repr`
    /// set.
    repr: ?Plugin.ValueKind.Repr = null,

    pub const Bound = struct {
        value: f64,
        unit: ?[]const u8 = null,
        /// Original source-text digits when the bound was declared as an
        /// exact integer literal (e.g. `9007199254740993`). Backends
        /// recover full precision via `x-sjon-exact-bound`.
        exact_int: bool = false,

        /// True when this bound is an exact integer beyond the 2^53 f64
        /// integer-precision ceiling — the point past which a non-bigint
        /// JSON/TS consumer may silently lose precision. The three export
        /// writers (JsonSchema, SchemaExport warnings, TsTypes) key their
        /// exact-bound annotations + lossiness warnings on this predicate.
        pub fn exceedsF64Precision(b: Bound) bool {
            return b.exact_int and @abs(b.value) > F64_PRECISE_INT_CEILING;
        }
    };
};

pub const Member = struct {
    name: []const u8,
    label: []const u8 = "",
    description: []const u8 = "",
    deprecated: bool = false,
    deprecation_message: []const u8 = "",
    /// Set when the member's spelling is digit-leading (`1d`, `2d`), in
    /// which case a document writes it as a **unit-bearing number** and
    /// not as a symbol. Every target has to know: the JSON bridge encodes
    /// such a value as `{"$num": [<magnitude>, "<unit>"]}`, so a schema
    /// pinning `{"$sym": "2d"}` would reject a document the validator
    /// accepts. `name` still carries the canonical spelling for prose.
    numeric_spelling: ?NumericSpelling = null,

    pub const NumericSpelling = struct {
        magnitude: u64,
        unit: []const u8,
    };
};

/// The exporter's mirror of `Plugin.CrossRef`. `provider` and `source_key`
/// are the provider route (`Plugin.CrossRef`'s doc comment has the two
/// routes); both are null on the identity route and both are non-null on
/// the provider one — the pair moves together, since a source key without
/// a provider is rejected at manifest load. Nothing here is enforceable by
/// any export target: the provider route is *less* enforceable than the
/// identity one, because the member set doesn't exist until a host runs an
/// extraction pre-pass over a document the exporter never sees.
pub const CrossRef = struct {
    /// Every listed target, in manifest order; never empty. A group's
    /// members share one namespace in the engine, which no export target
    /// can express — but the `intermediate` target is a first-class
    /// consumer surface, so it carries the whole list rather than a
    /// first-target summary an IR reader could mistake for the truth.
    targets: []const []const u8,
    name_key: []const u8,
    acyclic: bool,
    scope_form: ?[]const u8,
    provider: ?[]const u8 = null,
    source_key: ?[]const u8 = null,
};

/// The exporter's mirror of `Plugin.ValueKind.HeadSet`: the resolved
/// members, plus the count over the whole set.
///
/// Two levels of bound reach the backends, and only one of them lives on
/// a member. `FormRef.min` / `.max` are per head; `min_children` /
/// `max_children` count children of *any* head in the set, which is the
/// claim per-head bounds structurally cannot make. Both are meaningful
/// only where this shape reached the model through a form's
/// `:positional` slot — the scope rule in
/// `docs/portable-manifest-v1.md` §4.5.
///
/// `0` / `null` is "unbounded", so a head-set written before S10 exports
/// byte-identically, which is what keeps the goldens honest.
pub const HeadSetShape = struct {
    refs: []const FormRef,
    min_children: u16 = 0,
    max_children: ?u16 = null,

    /// True when the set itself declares a count worth emitting.
    /// `FormRef.isBounded`'s counterpart, one level up.
    pub fn isBounded(self: HeadSetShape) bool {
        return self.min_children != 0 or self.max_children != null;
    }

    /// True when *anything* here declares a count — some head, or the
    /// set. The `$children` backends gate their bounds emission on this,
    /// so an all-unbounded head-set emits no bounds block at all.
    pub fn anyBounded(self: HeadSetShape) bool {
        if (self.isBounded()) return true;
        for (self.refs) |r| {
            if (r.isBounded()) return true;
        }
        return false;
    }

    /// True when the slot demands at least one positional child — some
    /// head's `:min`, or the set's `:min-children`. Distinct from
    /// `anyBounded` because a ceiling-only slot is bounded and demands
    /// nothing, and the difference decides whether `$children` is
    /// `required`.
    pub fn hasFloor(self: HeadSetShape) bool {
        if (self.min_children > 0) return true;
        for (self.refs) |r| {
            if (r.min > 0) return true;
        }
        return false;
    }
};

/// One accepted head of a head-set, pre-resolved by the lowering pass
/// against the slot the head-set was lowered for. `plugin` is the
/// owning plugin for a `.global` head and the enclosing plugin for a
/// `.local` one; it is the empty string only for `.unresolved`.
pub const FormRef = struct {
    plugin: []const u8,
    name: []const u8,
    /// Positional-count bounds carried over from the source
    /// `HeadSet.Head`. Meaningful only where this `FormRef` reached the
    /// model through a form's `:positional` slot — the scope rule in
    /// `docs/portable-manifest-v1.md` §4.5 — so the backends read them
    /// only when emitting `$children`. `0` / `null` is "unbounded", and
    /// an all-unbounded head-set therefore exports byte-identically to
    /// before bounds existed, which is what keeps the goldens honest.
    min: u16 = 0,
    max: ?u16 = null,
    /// What this head resolves to. Defaulted to `.global` so every
    /// construction site that predates slot-aware resolution keeps its
    /// meaning; only `lowerFormKind` sets anything else.
    body: Body = .global,

    /// The three ways a head-set member can resolve, in the order the
    /// validator tries them (`Validator.validateFormHead` step 0).
    ///
    /// A head-set kind is plugin-wide and reusable, so *which* of these
    /// applies is a property of the **slot**, not of the kind: the same
    /// `bgl-resource` can be `.local` on a slot that declares the body
    /// inline and `.unresolved` on one that does not. That is why the
    /// lowering threads the slot's registry rather than resolving once
    /// per kind — see `SchemaExport.Context.locals`.
    pub const Body = union(enum) {
        /// A unique global form. Backends emit a `$ref` into
        /// `#/$defs/form.<plugin>.<name>`.
        global,
        /// A slot-local form (`FormSpec.local_forms`) shadowing — or
        /// standing in for — the global catalog. Locals have no global
        /// `$def`, so the body is emitted *in place*, the same way
        /// `ValueShape.form_locals` emits its arms.
        local: *const Form,
        /// Nothing in scope resolves this head: no slot-local body, no
        /// unique global. Backends emit a head-pinned open object
        /// (`{properties: {$form: {const: <name>}}, required: [$form]}`)
        /// and **never** a `$ref` — the pre-slot-aware exporter wrote
        /// the empty-plugin sentinel into the path (`#/$defs/form..ghost`),
        /// and an unresolvable `$ref` makes ajv reject the whole
        /// document at compile time rather than the one slot.
        unresolved,
    };

    /// True when this entry declares a count worth emitting.
    pub fn isBounded(self: FormRef) bool {
        return self.min != 0 or self.max != null;
    }
};

/// One arm of a `union_of` shape: the source-declared alternative name
/// plus its resolved shape. Backends emit them in declaration order to
/// preserve first-match dispatch semantics (annotation-only — JSON
/// Schema `anyOf` accepts in any order).
pub const UnionAlternative = struct {
    name: []const u8,
    shape: ValueShape,
};

/// A named value-kind preserved alongside its plugin so backends can
/// emit reusable `$defs` entries. Forms that reference a kind get a
/// `$ref` (JSON Schema) or `type` alias (TS) pointing here.
pub const ValueKindEntry = struct {
    name: []const u8,
    description: []const u8 = "",
    shape: ValueShape,
    /// Plugin that owns this kind. Captured from `Schema.lookupValueKind`'s
    /// `FormHit.plugin.name` during lowering so the per-plugin layout
    /// backends can emit cross-file `$ref` / `import` lines.
    origin_plugin: []const u8 = "",
};

/// One per-plugin export artifact, produced when `ExportOptions.layout`
/// is `.per_plugin`. Each artifact is independently writable to disk; the
/// CLI emits `<dir>/<plugin>.schema.json` + `<dir>/<plugin>.d.ts` +
/// `<dir>/<plugin>.export.json` per entry.
pub const PerPluginArtifact = struct {
    plugin: []const u8,
    json_schema_bytes: ?[]const u8 = null,
    ts_types_bytes: ?[]const u8 = null,
    intermediate_bytes: ?[]const u8 = null,
    markdown_bytes: ?[]const u8 = null,
};

/// A literal default value. Expression-shaped defaults are not encoded
/// here — they surface as a `Warning` with the `expression_default_annotation_only`
/// code; the IR only carries snapshot metadata via `expression_head`/
/// `expression_arg_count`.
pub const Default = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    /// String content, owned by the IR arena.
    string: []const u8,
    /// Symbol content, owned by the IR arena.
    symbol: []const u8,
    /// Vector default — element types follow the literal subset.
    vector: []const Default,
    /// Expression snapshot — captured for annotation only.
    expression: ExpressionSnapshot,
};

/// What the IR keeps for an expression-shaped default. The Binary IR
/// payload from `Plugin.KeySpec.Default.Expression` is intentionally
/// dropped — backends cannot evaluate it, and serializing the bytes
/// would inflate exports for no consumer benefit.
pub const ExpressionSnapshot = struct {
    head: []const u8,
    namespace: ?[]const u8,
    arg_count: u32,
};

/// 2^53 — the largest magnitude at which every integer is exactly
/// representable in an f64. An `exact_int` bound above this loses
/// precision as a JSON number, so both backends emit it as an exact
/// decimal string instead. The core canonical-number printers
/// (`Printer`/`Json`/`Expr`) keep their own 2^53 copies for a different
/// job — integer-elision on output — and are deliberately NOT folded
/// into this one: their bit-behavior is corpus-pinned.
pub const F64_PRECISE_INT_CEILING: f64 = 9007199254740992.0;

/// A form's key indices sorted alphabetically by name, returned by value so
/// callers don't hand-roll a `[MAX_FORM_KEYS]u16` scratch buffer. Bind the
/// result to a local before iterating `slice()`: the slice borrows the inline
/// `buf`, so the `SortedKeys` must outlive the loop.
pub const SortedKeys = struct {
    buf: [Plugin.MAX_FORM_KEYS]u16 = undefined,
    len: usize,

    /// The sorted index prefix. Borrows `self`, which must outlive the slice.
    pub fn slice(self: *const SortedKeys) []const u16 {
        return self.buf[0..self.len];
    }
};

/// Sort `keys` by name into a by-value `SortedKeys` (zero-alloc; the buffer is
/// inline and pinned to `Plugin.MAX_FORM_KEYS`, the hard per-form/per-variant
/// key cap, so a full key set always fits with no `@min` clamp and no silent
/// truncation). Both schema backends sort keys this way so the emitted schema
/// stays diff-stable when the source declaration is re-ordered; key names are
/// unique within a form, so the ordering is total.
pub fn sortedKeys(keys: []const Key) SortedKeys {
    std.debug.assert(keys.len <= Plugin.MAX_FORM_KEYS);
    var result: SortedKeys = .{ .len = keys.len };
    const view = result.buf[0..keys.len];
    for (view, 0..) |*slot, i| slot.* = @intCast(i);
    std.mem.sort(u16, view, keys, struct {
        fn lt(ks: []const Key, a: u16, b: u16) bool {
            return std.mem.order(u8, ks[a].name, ks[b].name) == .lt;
        }
    }.lt);
    return result;
}

test "ValueShape.isCompound classifies leaves vs containers" {
    const tag_only: ValueShape = .number;
    try std.testing.expect(!tag_only.isCompound());

    const members: ValueShape = .{ .symbol_members = &.{ "a", "b" } };
    try std.testing.expect(members.isCompound());
}

test "sortedKeys orders indices by key name, diff-stable" {
    const keys = [_]Key{
        .{ .name = "zeta", .optional = false, .value = .number },
        .{ .name = "alpha", .optional = false, .value = .number },
        .{ .name = "mid", .optional = false, .value = .number },
    };
    const sorted = sortedKeys(&keys);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 0 }, sorted.slice());
}

test "Bound.exceedsF64Precision flags exact ints past 2^53" {
    const B = NumericBounds.Bound;
    try std.testing.expect((B{ .value = 1e18, .exact_int = true }).exceedsF64Precision());
    // @abs handles a negative bound the same way.
    try std.testing.expect((B{ .value = -1e18, .exact_int = true }).exceedsF64Precision());
    // Exactly the ceiling is not *past* it (strict >).
    try std.testing.expect(!(B{ .value = F64_PRECISE_INT_CEILING, .exact_int = true }).exceedsF64Precision());
    // Never flagged when the bound wasn't an exact integer, however large.
    try std.testing.expect(!(B{ .value = 1e300, .exact_int = false }).exceedsF64Precision());
}
