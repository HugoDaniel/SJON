//! Cross-host diagnostic shape — mirrors `src/wasm_common.zig`'s
//! `writeHostResult` JSON verbatim and `hosts/web/SjonHost.ts`'s
//! TypeScript typedefs. The structs deserialize the WASM payload and
//! serialize the host options that go back into WASM.

use serde::{Deserialize, Serialize};

/// Host pipeline phase the diagnostic was emitted in. Mirrors
/// `Host.Phase` in Zig.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
#[non_exhaustive]
pub enum Phase {
    /// Project + manifest discovery (project-file walk, resolver
    /// callbacks, manifest parsing, plugin pre-flight).
    Manifest,
    /// Schema aggregation across all loaded plugins.
    Aggregate,
    /// Data-form validation against the aggregated schema.
    Validation,
}

/// Severity classification on every diagnostic. Strict mode treats
/// any `Err` as a hard fail; warnings flow through both modes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
#[non_exhaustive]
pub enum Severity {
    /// Hard error — fails strict-mode validation.
    Err,
    /// Advisory — surfaced to the caller but never fails validation.
    Warning,
}

/// Byte-offset source span `[start, end)` into the original document.
/// `(0, 0)` is the synthetic span for diagnostics with no source
/// position (e.g., project-file load errors).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Span {
    /// Inclusive byte offset of the first byte of the span.
    pub start: u32,
    /// Exclusive byte offset of one past the last byte of the span.
    pub end: u32,
}

impl Span {
    /// Synthetic zero span (`start = end = 0`) used by diagnostics
    /// emitted before any document bytes are seen.
    pub const ZERO: Span = Span { start: 0, end: 0 };
}

/// One diagnostic in a `HostResult`. Field layout mirrors
/// `wasm_common.zig::writeHostDiagnostic`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostDiagnostic {
    /// Pipeline phase that emitted the diagnostic.
    pub phase: Phase,
    /// Wire-stable `snake_case` code (matches `Ast.Diagnostic.Code`).
    pub code: String,
    /// Severity classification.
    pub severity: Severity,
    /// Human-readable message — informational only; do not match on it.
    pub message: String,
    /// Source span the diagnostic points at.
    pub span: Span,
    /// Semantic path (form heads, kvpair keys, vector indices) leading
    /// down to the offending node.
    pub path: Vec<String>,
    /// Optional secondary span — present on diagnostics that carry a
    /// related declaration site (e.g., the `(plugin …)` head that
    /// declared an undefined function).
    pub declaration_span: Option<Span>,
}

/// Per-plugin summary entry in `loaded_plugins` — what the host
/// successfully pre-flighted and made available to validation/eval.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginSummary {
    /// Plugin `:name` from the manifest.
    pub name: String,
    /// Optional `:version` string from the manifest.
    pub version: Option<String>,
    /// Number of data forms the plugin contributed to the aggregated
    /// schema.
    pub form_count: u32,
}

/// Provenance for a materialized default value. Mirrors
/// `MaterializedDefaults.Origin` in Zig.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum DefaultOrigin {
    /// `:default <literal>` declared inline in the manifest.
    LiteralDefault,
    /// `:default (expr …)` — value produced by evaluating an expression.
    ExpressionDefault,
}

/// One materialized default for an omitted declared key on a known
/// data form. `path` is `[form-head, key-name]`; `value` is the JSON-
/// encoded `Expr.Value` produced by `wasm_common.appendValue` —
/// numbers stay as JSON numbers, strings as JSON strings, keywords as
/// `{"$kw":"…"}`, vectors as arrays.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MaterializedDefault {
    /// Semantic path to the omitted key: `[form-head, key-name]`.
    pub path: Vec<String>,
    /// Key name the default was materialized for.
    pub key: String,
    /// Whether the default came from a literal or an expression.
    pub origin: DefaultOrigin,
    /// JSON-encoded `Expr.Value` of the materialized default.
    pub value: serde_json::Value,
}

/// One top-level form's evaluated value. `index` keys into
/// `data_forest` (a Zig-internal partition the JSON consumer does not
/// otherwise see); `value` is the JSON-encoded `Expr.Value`. Used by
/// the conformance harness's `(values …)` assertions.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EvalResultEntry {
    /// Zig-side `data_forest` index of the originating top-level form.
    pub index: usize,
    /// JSON-encoded `Expr.Value` produced by evaluation.
    pub value: serde_json::Value,
}

/// Result returned by `SjonHost::validate_document` — the WASM payload
/// JSON-decoded as
/// `{diagnostics, loadedPlugins, materializedDefaults, evaluatedResults}`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostResult {
    /// Diagnostics emitted across all pipeline phases.
    pub diagnostics: Vec<HostDiagnostic>,
    /// Per-plugin summary of every plugin that survived pre-flight.
    pub loaded_plugins: Vec<PluginSummary>,
    /// Defaults materialized for omitted declared keys.
    #[serde(default)]
    pub materialized_defaults: Vec<MaterializedDefault>,
    /// One entry per top-level form that produced an evaluated value.
    #[serde(default)]
    pub evaluated_results: Vec<EvalResultEntry>,
}

/// Result returned by `SjonHost::eval_expr` — the WASM payload
/// JSON-decoded as `{value, diagnostics, loadedPlugins}`. `value` is
/// `serde_json::Value::Null` when evaluation didn't run or raised an
/// error (the matching diagnostic appears in `diagnostics`).
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostEvalResult {
    /// JSON-encoded `Expr.Value` of the evaluated expression, or
    /// `Value::Null` on failure.
    pub value: serde_json::Value,
    /// Diagnostics emitted during evaluation.
    pub diagnostics: Vec<HostDiagnostic>,
    /// Plugins that survived pre-flight for this `eval_expr` call.
    pub loaded_plugins: Vec<PluginSummary>,
}

/// One emitted export warning. Mirrors `SchemaExport.Warnings.Warning`
/// in Zig. `code` is the bare `snake_case` enum tag (e.g.
/// `"cross_ref_unenforceable"`); `severity` ∈
/// `{info, warn, err}`. `plugin`/`form`/`key`/`kind` scope the warning
/// to a position in the schema and may be `None`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExportWarning {
    /// `info`, `warn`, or `err`.
    pub severity: String,
    /// Snake-case warning code (e.g. `"cross_ref_unenforceable"`).
    pub code: String,
    /// Human-readable message.
    pub message: String,
    /// Owning plugin name, if the warning is plugin-scoped.
    pub plugin: Option<String>,
    /// Form name, if the warning narrows further to a form.
    pub form: Option<String>,
    /// Form key, if the warning narrows further to a key.
    pub key: Option<String>,
    /// Internal kind tag the Zig-side warning emitter tagged the entry
    /// with — useful for grouping but not part of the wire-stable code.
    pub kind: Option<String>,
}

/// Aggregated artifacts when `layout == Aggregated`. Each field is
/// `Some` when the matching target was requested and `None` otherwise.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AggregatedArtifacts {
    /// JSON Schema 2020-12 source as a single string.
    pub json_schema: Option<String>,
    /// TypeScript `.d.ts` source.
    pub ts_types: Option<String>,
    /// Intermediate-IR JSON used for round-trip / debugging.
    pub intermediate: Option<String>,
}

/// One per-plugin artifact when `layout == PerPlugin`. Each plugin
/// produces its own JSON Schema / `.d.ts` / IR triple; cross-plugin
/// `$ref`s and `import type`s reach into sibling files.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PerPluginArtifact {
    /// Plugin name this artifact triple belongs to.
    pub plugin: String,
    /// JSON Schema 2020-12 source.
    pub json_schema: Option<String>,
    /// TypeScript `.d.ts` source.
    pub ts_types: Option<String>,
    /// Intermediate-IR JSON.
    pub intermediate: Option<String>,
}

/// Layout discriminator on `ExportSchemaResult`. `Aggregated` ↔
/// `aggregated`, `PerPlugin` ↔ `per-plugin` (kebab, matching the
/// request-side `ExportLayoutOption` and the Zig envelope literal).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
#[non_exhaustive]
pub enum ExportLayout {
    /// Single-file aggregated artifacts (`AggregatedArtifacts`).
    Aggregated,
    /// One artifact triple per plugin (`Vec<PerPluginArtifact>`).
    PerPlugin,
}

/// Result of `SjonHost::export_schema` — the envelope produced by
/// `wasm_common.writeExportSchemaResult` JSON-decoded.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportSchemaResult {
    /// Which `layout` variant was requested (controls which of
    /// `aggregated` / `per_plugin` is populated).
    pub layout: ExportLayout,
    /// Diagnostics emitted during the export pipeline.
    pub host_diagnostics: Vec<HostDiagnostic>,
    /// Plugins that contributed to the exported schema.
    pub loaded_plugins: Vec<PluginSummary>,
    /// Non-fatal export warnings (see `ExportWarning`).
    pub warnings: Vec<ExportWarning>,
    /// Populated when `layout == Aggregated`.
    pub aggregated: Option<AggregatedArtifacts>,
    /// Populated when `layout == PerPlugin`.
    pub per_plugin: Option<Vec<PerPluginArtifact>>,
}

/// Strictness selector for `HostOptions` / `ExportSchemaOptions`.
/// `Strict` fails on any `Err` diagnostic; `Lenient` lets validation
/// finish and reports everything (default).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
#[non_exhaustive]
pub enum FailurePolicy {
    /// Fail on the first `Err`-severity diagnostic.
    Strict,
    /// Collect all diagnostics; don't bail early.
    #[default]
    Lenient,
}

/// Options threaded through to `Host.validateDocument`. `project_diagnostics`
/// is host-side metadata (the `FilesystemResolver` walks the project file
/// before WASM is loaded and returns any project-load errors here);
/// `validate_document` prepends them to the WASM result so they land
/// under `phase: Manifest` exactly like Zig's native pipeline.
///
/// # Examples
///
/// Pairing the bundled `FilesystemResolver` with `validate_document`
/// — the resolver returns project-load diagnostics through the second
/// tuple field, which `HostOptions::project_diagnostics` feeds back
/// into the result so the caller sees one merged stream:
///
/// ```no_run
/// use std::path::Path;
/// use std::sync::Arc;
/// use sjon_host::{FilesystemResolver, HostOptions, Resolver, SjonHost};
///
/// let case_dir = Path::new("./fixtures/project");
/// let project_file = case_dir.join("sjon-project.sjon");
/// let (resolver, project_diagnostics) =
///     FilesystemResolver::build(case_dir, Some(project_file.as_path()));
/// let resolver: Arc<dyn Resolver> = Arc::new(resolver);
///
/// let mut host = SjonHost::load(Path::new("./sjon.wasm"), Some(resolver))?;
/// let opts = HostOptions {
///     project_root: Some(case_dir.display().to_string()),
///     project_file: Some(project_file.display().to_string()),
///     project_diagnostics, // prepended in front of the WASM diagnostics
///     ..HostOptions::default()
/// };
/// let result = host.validate_document("(widget :name w0)\n", &opts)?;
/// # Ok::<(), sjon_host::SjonHostError>(())
/// ```
#[derive(Debug, Clone, Default)]
pub struct HostOptions {
    /// Root directory of the project being validated — surfaces in
    /// path-relative diagnostics produced inside WASM.
    pub project_root: Option<String>,
    /// Absolute path of the `sjon-project.sjon` driving the project,
    /// when one exists.
    pub project_file: Option<String>,
    /// Strict-vs-lenient toggle. See `FailurePolicy`.
    pub failure_policy: FailurePolicy,
    /// Host-side diagnostics emitted before WASM was invoked (typically
    /// from `FilesystemResolver::build`). Prepended onto
    /// `HostResult.diagnostics` under `phase: Manifest` so callers see
    /// one merged stream.
    pub project_diagnostics: Vec<HostDiagnostic>,
    /// The symbol a *held* position is spelled with: a value the author
    /// has deliberately not filled in yet. When set, a symbol whose text
    /// matches is accepted wherever a value may appear, without narrowing
    /// on the slot's declared kind or any of its refinements, and
    /// registers no cross-ref name. `None` (the default) validates
    /// exactly as before.
    ///
    /// The assertion is about the *run* — "this document is being typed"
    /// — and is made by whoever calls the host, never by the document: a
    /// manifest is loaded because the document said `(use-plugin …)`, so a
    /// document-level opt-in would let a document turn off its own type
    /// checking.
    ///
    /// `_` is the conventional spelling. SJON does not police the name.
    pub held_symbol: Option<String>,
}

/// Wire-format options sent into `sjon_host_validate_document`. The
/// `has_resolver` discriminant tells WASM whether to call back through
/// `sjon_host_resolve` or fail every reference as `unresolved_plugin`.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct WasmHostOptions<'a> {
    pub project_root: Option<&'a str>,
    pub project_file: Option<&'a str>,
    pub failure_policy: FailurePolicy,
    pub held_symbol: Option<&'a str>,
    pub has_resolver: bool,
}

/// Target selection for `SjonHost::export_schema`. Mirrors the
/// `--target` CLI flag and the WASM `target` option string.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Default)]
#[serde(rename_all = "kebab-case")]
#[non_exhaustive]
pub enum ExportTarget {
    /// Emit JSON Schema 2020-12 only.
    JsonSchema,
    /// Emit TypeScript `.d.ts` only.
    Typescript,
    /// Emit both JSON Schema and TypeScript (default).
    #[default]
    Both,
    /// Emit the intermediate IR alongside whatever `target` would
    /// normally produce — primarily for round-trip / debugging.
    Intermediate,
}

/// Layout selection for `SjonHost::export_schema`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Default)]
#[serde(rename_all = "kebab-case")]
#[non_exhaustive]
pub enum ExportLayoutOption {
    /// One artifact triple aggregating every plugin (default).
    #[default]
    Aggregated,
    /// One artifact triple per plugin.
    PerPlugin,
}

/// Caller-facing options for `SjonHost::export_schema`. Aside from
/// `target` + `layout` these mirror `HostOptions` so a caller who
/// already configured `HostOptions` for validation only needs to
/// supply the two extra fields.
#[derive(Debug, Clone, Default)]
pub struct ExportSchemaOptions {
    /// Project-root directory; same semantics as
    /// `HostOptions::project_root`.
    pub project_root: Option<String>,
    /// Project-file path; same semantics as
    /// `HostOptions::project_file`.
    pub project_file: Option<String>,
    /// Strict-vs-lenient toggle.
    pub failure_policy: FailurePolicy,
    /// Which artifact(s) to emit.
    pub target: ExportTarget,
    /// Aggregated vs per-plugin layout.
    pub layout: ExportLayoutOption,
}

/// Wire-format options sent into `sjon_export_schema`. The `draft`
/// is pinned at `"2020-12"`; the kebab-cased `target` and `layout`
/// match the Zig option parser at `wasm.zig`.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct WasmExportSchemaOptions<'a> {
    pub project_root: Option<&'a str>,
    pub project_file: Option<&'a str>,
    pub failure_policy: FailurePolicy,
    pub has_resolver: bool,
    pub target: ExportTarget,
    pub layout: ExportLayoutOption,
    pub draft: &'static str,
}

/// One step of a §11.2 path: a string names a form's keyword value, an
/// integer names a positional child of a form or an element of a vector.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum PathStep {
    /// The value of the keyword pair with this key.
    Key(String),
    /// The n-th positional child, keyword pairs skipped.
    Index(u32),
}

/// Where a node is: which root of the document, and the §11.2 path from
/// that root down to it, plus the two fields an editor draws with.
///
/// `root` and `path` are an edit action's two fields verbatim. An address
/// is where a node is, not which node it is: insert a sibling before the
/// target and the same address names a different node, so re-derive
/// addresses from the document that comes back after a batch.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Address {
    /// Which root of the document, indexing the forest left to right.
    pub root: u32,
    /// The §11.2 path from that root down to the node.
    pub path: Vec<PathStep>,
    /// The node's own bytes, `[start, end)`.
    pub span: (u32, u32),
    /// The node's tag: `form`, `number`, `string`, `symbol`, and so on.
    pub kind: String,
}

/// One row of a [`NodeTable`]: an addressable node, where it is, and
/// where its bytes are.
///
/// A `:key value` pair gets no row. §11.2 addresses a pair's *value*, so
/// the pair has no address of its own; its key span rides on the value's
/// row as [`key_span`](NodeRow::key_span).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NodeRow {
    /// This row's index, equal to its position in `nodes`.
    pub i: u32,
    /// The row index of the container this node sits in, `-1` for a root.
    pub parent: i64,
    /// Which root of the document this node is under.
    pub root: u32,
    /// This row's own §11.2 path step from its parent, `None` for a root.
    pub seg: Option<PathStep>,
    /// The node's tag: `form`, `number`, `string`, `symbol`, and so on.
    pub kind: String,
    /// The node's own bytes, `[start, end)`.
    pub span: (u32, u32),
    /// A form's head bytes. Absent on every other kind.
    #[serde(default)]
    pub head_span: Option<(u32, u32)>,
    /// The `:key` bytes of the pair this node is the value of.
    #[serde(default)]
    pub key_span: Option<(u32, u32)>,
}

/// A parse diagnostic as the envelope's `appendDiagnostic` writes it:
/// span, severity, code, message. Narrower than [`HostDiagnostic`] on
/// purpose — nothing before validation has a phase, a semantic path, or a
/// declaration site to report.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParseDiagnostic {
    /// Source span the diagnostic points at.
    pub span: Span,
    /// Severity classification.
    pub severity: Severity,
    /// Wire-stable `snake_case` code (matches `Ast.Diagnostic.Code`).
    pub code: String,
    /// Human-readable message — informational only; do not match on it.
    pub message: String,
}

/// Every addressable node of one document, plus the diagnostics from the
/// same parse.
///
/// Rows are pre-order: a parent always precedes its children and siblings
/// are in source order, so the innermost node containing a byte is the
/// *last* row whose span contains it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NodeTable {
    /// One row per addressable node, pre-order.
    pub nodes: Vec<NodeRow>,
    /// What the parser reported about the same bytes.
    pub diagnostics: Vec<ParseDiagnostic>,
}
