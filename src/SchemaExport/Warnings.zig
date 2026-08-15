//! Diagnostic surface for the schema exporter.
//!
//! Warnings are deliberately separate from `Ast.Diagnostic.Code` (the
//! wire-stable enum the validator emits): the exporter is a side
//! pipeline that runs on already-validated schemas, and its concerns
//! (mapping lossiness, M1-deferred constructs, downstream-target
//! naming hazards) don't belong on the validator's grep surface. New
//! variants here can be added freely without going through the
//! diagnostic-coverage audit.
//!
//! Embedding warnings into the emitted artifacts (`x-sjon-export-warnings`
//! in JSON Schema, leading `// WARNING:` block in TS) is the channel
//! that travels with the artifact; the in-memory `[]const Warning` on
//! `ExportResult` is what the CLI / WASM host renders.

const std = @import("std");

/// Severity ladder. `.err` upgrades CLI exit code to 1 even though the
/// exporter still produces output. `.warn` is the default for lossy
/// mappings the consumer should know about; `.info` is for purely
/// informational notes (e.g. "this construct is M1-deferred — emitted
/// as a stub").
pub const Severity = enum { info, warn, err };

/// Closed enum of warning kinds. Order is *not* wire-stable — downstream
/// tooling reads the `tag` field as a string, not the ordinal, so
/// variants may be added freely.
pub const Code = enum {
    /// A cross-ref slot's closed-set membership / cycle / scope rules
    /// cannot be enforced by JSON Schema or TS. The shape (bare symbol)
    /// is enforced; semantic membership is annotation-only.
    cross_ref_unenforceable,
    /// A key's default is an expression snapshot; the exporter only
    /// surfaces the head + arg-count via `x-sjon-default-expression`,
    /// the expression is never serialized as a JSON Schema `default`.
    expression_default_annotation_only,
    /// A slot whose declared type is `expr` accepts any expression
    /// shape — JSON Schema validates the `$expr` envelope, not the
    /// runtime result type.
    expression_slot_annotation_only,
    /// An exclusive group's source-order / source-presence rule isn't
    /// expressible in JSON Schema with full fidelity; v1 single-key
    /// alternatives map to `oneOf` / `not`, multi-key alternatives
    /// fall back to annotation-only.
    exclusive_group_unenforceable,
    /// A cross-ref declares `:acyclic true` — the cycle detector
    /// requires runtime SJON semantics. Annotation only.
    acyclic_unenforceable,
    /// A construct is recognised by the IR but the M1 backends emit it
    /// as a stub (e.g. number_with_unit, rich member sets, discriminated
    /// variants). Carries a `kind` hint in the message so callers know
    /// which milestone re-enables full emission.
    deferred_construct,
    /// A plugin form / kind name collides with a TS reserved word or a
    /// previously-emitted identifier. The TS backend prefixes with
    /// `Sjon` and warns; the JSON Schema is unaffected.
    ts_name_collision,
    /// An exact-int bound exceeds 2^53; downstream JSON Schema
    /// validators that round-trip through f64 lose precision.
    exact_int_overflow,
    /// A string-bounds `:pattern` is declared; the exporter records the
    /// pattern but JSON Schema validators may use a different regex
    /// engine, and SJON v1 doesn't execute regex at all.
    string_pattern_engine_mismatch,
    /// A string-bounds `:format` is unknown to JSON Schema's `format`
    /// vocabulary (e.g. `path`, `semver`); emitted under `x-sjon-format`
    /// only.
    string_format_unknown_to_jsonschema,
    /// Aggregate-phase validators flagged a schema-level issue. The
    /// exporter still produces output but flags the consumer.
    aggregate_phase_error,
    /// A discriminated form's variants were emitted as `allOf + oneOf +
    /// if/then` chain in JSON Schema and as a per-variant union of
    /// interfaces in TS. Informational because source-order ("variant
    /// keys must appear after the discriminant") remains unenforceable.
    variants_emitted_via_if_then,
    /// A `union_of` value-kind was emitted as JSON Schema `anyOf` over
    /// the resolved alternatives plus an `x-sjon-union-alternatives`
    /// annotation listing declaration order (SJON's first-match dispatch
    /// is not exposed; `anyOf` is the correct semantic match).
    union_emitted_via_anyof,
    /// A form-slot head-set was emitted as `oneOf` of `$ref`s into
    /// `#/$defs/form.<plugin>.<head>`, plus the `x-sjon-head-set`
    /// annotation. Same-document only in M2 — cross-plugin `$ref`s land
    /// with the per-plugin layout in M3.
    head_set_emitted_via_oneof_refs,
    /// A slot's `KeySpec.local_forms` were emitted as an *inline* anonymous
    /// union (one object schema per local, bodies emitted in place — not via
    /// `$ref`), plus a trailing open generic branch for the additive global
    /// fallback and an `x-sjon-local-forms` annotation. Informational — the
    /// local-first / global-fallback resolution order is SJON-only; the
    /// inline union accepts any branch (and the open branch any global form).
    local_forms_emitted_inline,
    /// A rich member-set was emitted as `oneOf` of `const`-pinned
    /// objects carrying `title` / `description` / `deprecated` /
    /// `x-sjon-deprecation-message`, replacing the M1 bare `enum`.
    rich_members_emitted_with_annotations,
    /// A numeric-bounds slot was emitted via the JSON Schema keywords
    /// `minimum` / `maximum` / `exclusiveMinimum` / `exclusiveMaximum`
    /// (plus `type: integer` when integer=true). Informational — the
    /// bound itself is enforced by JSON Schema; this note records that
    /// the SJON-level bound made it onto the wire.
    numeric_bounds_emitted_via_min_max,
    /// An exact-int bound exceeds the f64-precise-integer ceiling (2^53);
    /// the JSON Schema `minimum`/`maximum` keyword carries the value as a
    /// JSON number (lossy in non-bigint validators) and the exporter
    /// additionally emits `x-sjon-exact-bound: {min|max: "<digits>"}` so
    /// SJON-aware tools recover full precision.
    numeric_bound_exceeds_double_range,
    /// A unit-bearing number was emitted as a JSON Schema object with a
    /// `$num` 2-tuple via `prefixItems`. The magnitude slot carries any
    /// propagated numeric bounds; the unit slot carries an `enum` of the
    /// allowed unit strings (or `minLength: 1` when allowed is empty).
    number_with_unit_emitted_via_prefix_items,
    /// A string-bounds slot was emitted via the JSON Schema keywords
    /// `minLength` / `maxLength` / `pattern` / `format`. Informational —
    /// `pattern` and `format` semantics differ between SJON and JSON
    /// Schema (regex engine, codepoint vs UTF-16 length, custom formats);
    /// the deeper caveats remain on the existing `string_pattern_engine_mismatch`
    /// and `string_format_unknown_to_jsonschema` codes.
    string_bounds_emitted_via_keywords,
    /// A cross-ref slot was emitted with the `x-sjon-cross-ref`
    /// annotation carrying `target-form` / `name-key` / `acyclic` /
    /// `scope-form`. Informational — none of those four fields are
    /// enforceable by JSON Schema; consumers need SJON-aware validation
    /// to close the loop.
    cross_ref_annotation_only,
    /// An exclusive-group alternative with multiple keys (a "bundle":
    /// `[(:from :to) :at]`) was emitted as one `{required: [...]}` entry
    /// per bundle inside `oneOf` (or pairwise `not:{allOf}` for
    /// `at_most_one`). Informational — the source-order constraint and
    /// the bundle-atomicity (partial bundles fail) require SJON-aware
    /// runtime validation.
    multi_key_exclusive_emitted,
};

/// A single warning attached to an emit. Lifetime: `message`, `path`,
/// and string fields are owned by the enclosing `ExportResult.arena`.
pub const Warning = struct {
    code: Code,
    severity: Severity,
    message: []const u8,
    /// Plugin namespace the warning belongs to. `null` for aggregate
    /// warnings spanning multiple plugins.
    plugin_name: ?[]const u8 = null,
    /// Form name, when the warning is scoped to a form. `null` when the
    /// warning is scoped to a value-kind or to a higher level.
    form_name: ?[]const u8 = null,
    /// Key name, when the warning is scoped to a key on a form. `null`
    /// at form or kind scope.
    key_name: ?[]const u8 = null,
    /// Value-kind name, when the warning is scoped to a kind rather
    /// than a form/key.
    kind_name: ?[]const u8 = null,

    pub fn isError(self: Warning) bool {
        return self.severity == .err;
    }
};

/// True iff any `.err`-severity warning is present.
pub fn anyError(warnings: []const Warning) bool {
    for (warnings) |w| if (w.isError()) return true;
    return false;
}

test "anyError detects err-severity entries" {
    const empty: []const Warning = &.{};
    try std.testing.expect(!anyError(empty));

    const only_warn = [_]Warning{.{ .code = .deferred_construct, .severity = .warn, .message = "x" }};
    try std.testing.expect(!anyError(&only_warn));

    const with_err = [_]Warning{
        .{ .code = .deferred_construct, .severity = .warn, .message = "x" },
        .{ .code = .aggregate_phase_error, .severity = .err, .message = "y" },
    };
    try std.testing.expect(anyError(&with_err));
}

test "Warning.isError matches severity field" {
    const w: Warning = .{ .code = .deferred_construct, .severity = .err, .message = "x" };
    try std.testing.expect(w.isError());
    const i: Warning = .{ .code = .deferred_construct, .severity = .info, .message = "x" };
    try std.testing.expect(!i.isError());
}
