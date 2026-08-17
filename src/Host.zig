//! SJON host contract. Cross-host shape that every wrapper (Zig CLI, Web,
//! Rust) mirrors. **D1 ships the inline-manifest constructor: a single
//! `.sjon` source declares its plugins inline and the host validates the
//! data forms against the composed schema.** Multi-file fixtures and
//! `(use-plugin …)` resolver wiring land in D3.
//!
//! Memory model: `HostResult` releases everything through `deinit()`
//! without a `gpa` parameter (matching the canonical convention in
//! `root.zig`'s header). Internally there are three independent arenas
//! to release in order:
//!   1. each `plugin_results[i].arena` (per-manifest)
//!   2. `tree.arena` (parsed source)
//!   3. `arena` (host's own — owns partition slices, diagnostics, paths)
//!
//! `Schema.init` stays pure: this module owns "what loaded vs. what
//! didn't" and emits resolution failures as diagnostics, not panics.
//!
//! **Schema preload (two-phase).** `preloadSchema` compiles a set of
//! standalone `(plugin …)` manifest sources into a `PreloadedSchema` once —
//! parse, load, aggregate-validate — so a host validating many documents
//! against the same external schema pays that cost a single time instead of
//! prepending the schema to every document and rebasing every diagnostic span
//! by the prefix length. Hand it back via `HostOptions.preloaded`: the
//! document pipeline treats its plugins as *additive* (composed before any
//! inline `(plugin …)` the document itself declares) and *borrows* the handle
//! — the `PreloadedSchema` must outlive every `HostResult` built against it,
//! and `HostResult.deinit` never touches its arenas (a result's own
//! `plugin_results` stays document-only, so the borrowed prefix is never
//! double-freed). No wire-format or diagnostic-code change: preload
//! diagnostics are manifest-source-local and document diagnostics stay
//! document-local, so there is nothing to rebase.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Ast = @import("Ast.zig");
const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
const ManifestLoader = @import("ManifestLoader.zig");
const Resolver = @import("Resolver.zig");
const Parser = @import("Parser.zig");
const Validator = @import("Validator.zig");
const ProviderExtraction = @import("ProviderExtraction.zig");
const Expr = @import("Expr.zig");
const MaterializedDefaults = @import("MaterializedDefaults.zig");
const Lowering = @import("Lowering.zig");
const wasm_plugin_invoker = @import("wasm_plugin_invoker.zig");
const core_plugin = @import("plugins/core.zig");
const SchemaExport = @import("SchemaExport/SchemaExport.zig");
const LoweringGraph = @import("LoweringGraph.zig");
const Sha256Pin = @import("Sha256Pin.zig");

const native_plugin_exec = builtin.target.cpu.arch != .wasm32 and build_options.plugin_exec;

/// Lazy import of the native PluginRuntime — only resolved on native
/// builds that opted into executable-plugin support. WASM hosts ship
/// the same code path through `sjon_host_invoke_plugin` (see
/// `src/wasm_plugin_invoker.zig`); they don't instantiate this type.
const PluginRuntime = if (native_plugin_exec) @import("PluginRuntime.zig") else opaque {};

// FilesystemResolver depends on `std.Io.Dir.cwd()` which has no
// implementation on freestanding/wasm targets. Wasm hosts inject their
// own `resolver` via `HostOptions` — the auto-fs-resolver branch in
// `validateDocument` is hard-disabled for those targets.
const FilesystemResolver = if (builtin.os.tag == .freestanding) struct {
    pub const Stub = void;
} else @import("FilesystemResolver.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{OutOfMemory};

pub const FailurePolicy = enum { strict, lenient };

/// Default empty lowering environment — the default of
/// `HostOptions.lowering_env`. When the embedder supplies no constants a
/// hook's `numberEval` resolves nothing, so an author expression with a
/// free variable fails the hook rather than evaluating.
const empty_lowering_env: Expr.Env = .{};

pub const HostOptions = struct {
    /// Forward-declared. D1 does not gate emission on this field — D2's
    /// CLI sets `.strict` to drive its exit policy; LSP keeps `.lenient`.
    /// Defaulting to `.lenient` matches existing LSP behavior so a caller
    /// upgrading from raw `Schema.init` does not get surprise hard-fails.
    failure_policy: FailurePolicy = .lenient,

    /// Per-axis effective-validation switches. Production default is
    /// A+B+C+D on — see `Validator.EffectiveAxes` for the rationale.
    /// The effective-axes harness (`zig build effective-axes-harness`)
    /// flips bits explicitly to measure diagnostic-stream deltas. Not
    /// exposed over the WASM ABI — Zig-host only.
    effective_axes: Validator.EffectiveAxes = .{},

    /// Project root used by the default filesystem resolver. `null` means
    /// the resolver should treat the current working directory as root.
    project_root: ?[]const u8 = null,

    /// Absolute path to a `sjon-project.sjon` file the default resolver
    /// should index at startup. `null` means "no project file" — explicit
    /// `:path` references still resolve, but bare-name lookups fail.
    project_file: ?[]const u8 = null,

    /// Additional search roots checked after explicit `:path` and after
    /// `sjon-project.sjon`. D3 reads these.
    plugin_search_roots: []const []const u8 = &.{},

    /// Optional resolver. `null` triggers the default filesystem resolver
    /// when both `project_root` and `io` are set; otherwise references
    /// fail with `unresolved_plugin`.
    resolver: ?Resolver.Resolver = null,

    /// IO handle the default Zig filesystem resolver uses for
    /// `sjon-project.sjon` and per-plugin file reads. Required only when
    /// `resolver == null` and `project_root != null` — leaving it null
    /// in that combination means the host has no way to read the
    /// filesystem and falls back to "no resolver" (every reference
    /// becomes `unresolved_plugin`).
    ///
    /// Web/Rust hosts do **not** populate this field; they inject their
    /// own `resolver` instead (e.g., a `fetch`-backed callback or a
    /// language-native filesystem wrapper). `io` is the Zig host's
    /// dependency-injection slot for the bundled `FilesystemResolver`.
    io: ?Io = null,

    /// Optional lowering hook registry. `null` (default) means the
    /// lowering pass does not run — preserves byte-identical
    /// conformance for every fixture that does not declare `:lowering`.
    /// Non-null wires `Lowering.runLoweringPass` into the pipeline
    /// between materialization and final validation. See
    /// `docs/plugin-model-v1.md` and `src/Lowering.zig`.
    lowering_registry: ?*const Lowering.LoweringRegistry = null,

    /// Host-supplied evaluation environment for the lowering pass. The
    /// embedder populates it with named constants (e.g. `workgroup-size`)
    /// that a hook's `numberEval` resolves out of an author expression in
    /// a number slot. Defaults empty, so every existing caller and
    /// conformance fixture is byte-identical — only an embedder that
    /// injects bindings changes lowering behavior. Zig-API-only: there is
    /// no wire/ABI/diagnostic surface for it. See `src/Lowering.zig`.
    lowering_env: *const Expr.Env = &empty_lowering_env,

    /// Optional preloaded external schema (F9). When non-null, its plugins
    /// are brought into scope for this document as if declared ahead of any
    /// inline `(plugin …)` / `(use-plugin …)`: the composed user schema is
    /// `preloaded.plugins ++ document-loaded`, and the eval/validation schema
    /// prepends `core` as usual. Inline declarations remain honored and are
    /// additive (appended after the preloaded set); a name collision with a
    /// preloaded plugin surfaces as `ambiguous_form` at lookup, exactly like
    /// an inline-vs-inline collision.
    ///
    /// Borrowed, NOT owned: the pointee must outlive the returned
    /// `HostResult` / `HostEvalResult` (the same lifetime rule the
    /// `Validator` schema already follows). `deinit` never frees a preloaded
    /// arena — `plugin_results` stays document-only, so `plugins[i]` aliases
    /// `plugin_results[i].plugin` only for the document-loaded suffix.
    ///
    /// Aggregate validators: the preloaded set's aggregate diagnostics are
    /// reported once at `preloadSchema` time (on
    /// `PreloadedSchema.diagnostics`), so they are NOT re-run here unless this
    /// document itself contributes a plugin — in which case the combined set
    /// is re-validated and the preloaded-set aggregate diagnostics reappear
    /// alongside any new cross-set ones. Zig-API-only: no wire/ABI/diagnostic
    /// surface for it.
    preloaded: ?*const PreloadedSchema = null,
};

/// Phase tag on every host diagnostic. Lets consumers (CLI, LSP, audit
/// scripts) distinguish manifest-load failures from schema-aggregate
/// failures from lowering-runtime failures from data-validation failures
/// without consulting the code. The lowering pass stamps `.lowering`;
/// re-validation diagnostics on the lowered tree still stamp `.validation`
/// (they are validation in nature, just over a derived tree).
pub const Phase = enum { manifest, aggregate, lowering, validation };

/// Host-level diagnostic. Wraps a meta-schema or validator diagnostic
/// with phase + (for manifest phase) the `(plugin …)` declaration's
/// head span — the node whose ownership of the inner diagnostic the
/// host wants to make explicit. The inner `code` is preserved verbatim
/// so LSP click-to-source and `tools/audit_diagnostic_coverage.sh`
/// continue to see the original failure mode.
///
/// `path` and `message` lifetimes are tied to the enclosing
/// `HostResult.arena`.
pub const HostDiagnostic = struct {
    phase: Phase,
    code: Ast.Diagnostic.Code,
    severity: Ast.Diagnostic.Severity,
    message: []const u8,
    span: Ast.Span,
    path: []const []const u8,
    /// Set only when `phase == .manifest` and the diagnostic was emitted
    /// against an inline `(plugin …)` declaration. Points at the
    /// declaration's head span so a renderer can anchor the failure to
    /// the owning plugin without reparsing.
    declaration_span: ?Ast.Span = null,

    /// The wrapped diagnostic, minus the host's own additions (`phase`,
    /// `declaration_span`). Every field is copied verbatim — this is a
    /// projection, not a conversion — for the consumers that key on the
    /// inner shape, notably `Hints`.
    ///
    /// Exists because the two CLI renderers that build hint footers were
    /// each rebuilding this struct field-by-field, one comment apiece
    /// explaining that `HostDiagnostic` "wraps the validator's diagnostic
    /// verbatim". A field added to `Ast.Diagnostic` should reach both
    /// renderers by being added here once.
    pub fn inner(self: HostDiagnostic) Ast.Diagnostic {
        return .{
            .span = self.span,
            .message = self.message,
            .severity = self.severity,
            .code = self.code,
            .path = self.path,
        };
    }
};

/// One entry per top-level `data_forest` form whose head resolved as an
/// expr-func and returned a value cleanly. `forest_index` is the position
/// within `HostResult.data_forest`. `value` is deep-copied into the
/// enclosing `HostResult.arena` — borrowed lifetime; callers must not
/// free it directly. Used by the conformance harness's `(values …)`
/// assertions to verify plugin-exec codec round-trips.
pub const EvalResult = struct {
    forest_index: usize,
    value: Expr.Value,
};

/// Owned result of a host validate-document call.
///
/// Slices `plugin_results`, `plugins`, `declarations`, `references`,
/// `data_forest`, and `diagnostics` are allocated from `arena`.
/// Diagnostic strings + path elements also live in `arena`. Each
/// `plugin_results[i]` owns its own arena (per `ManifestLoader.Result`);
/// `plugins[i]` aliases `&plugin_results[loaded_idx].plugin` for the
/// subset of declarations that loaded cleanly.
///
/// With `HostOptions.preloaded != null`, `plugins` is `preloaded.plugins ++
/// document-loaded`: the leading `preloaded.plugins.len` entries are borrowed
/// from the preloaded bundle (their arenas owned there, must outlive this
/// result) and `plugins[i]` aliases `plugin_results[i - preloaded_len].plugin`
/// only for the document-loaded suffix. `plugin_results` stays document-only,
/// so `deinit` never frees a preloaded arena.
pub const HostResult = struct {
    arena: std.heap.ArenaAllocator,

    /// Parsed document. Owns its own arena via `tree.deinit()`.
    tree: Ast.Tree,

    /// One entry per `(plugin …)` declaration that loaded without
    /// err-severity diagnostics. Each owns its own arena.
    plugin_results: []ManifestLoader.Result,

    /// Borrowed view: `plugins[i] == &plugin_results[i].plugin`. Length
    /// matches `plugin_results.len` (only successful loads contribute).
    plugins: []const Plugin.Plugin,

    /// Pure aggregate over `plugins`. No allocation; not deinited.
    schema: Schema.Schema,

    /// Names in the project's `:plugins` index (arena-owned copies) —
    /// the did-you-mean candidate pool for `unresolved_plugin`, distinct
    /// from `plugins` (the *loaded* set: a typo'd reference never loads
    /// its target, but the target stays indexed). Best-effort: populated
    /// only when the host auto-constructed the filesystem resolver from
    /// `project_root`; empty with an injected `HostOptions.resolver` or
    /// no project.
    project_plugin_names: []const []const u8,

    /// Top-level partition over `tree.root` indices.
    declarations: []const Ast.NodeIndex,
    references: []const Ast.NodeIndex,
    data_forest: []const Ast.NodeIndex,

    /// Phase-tagged diagnostics from manifest load, schema aggregate,
    /// and data validation phases — concatenated in that order.
    diagnostics: []const HostDiagnostic,

    /// One entry per top-level `data_forest` form whose head resolved as
    /// an expr-func and whose `Expr.eval` returned a value successfully.
    /// Entries are arena-owned (values deep-copied into `arena`). Forms
    /// that failed to evaluate contribute a `plugin_func_*` diagnostic on
    /// `diagnostics` and no entry here. Stable across re-evaluation —
    /// `forest_index` is the position within `data_forest`.
    evaluated_results: []const EvalResult,

    /// Side-table of materialized defaults populated during the
    /// validation phase. One `Entry` per omitted declared key on a
    /// known data form whose `KeySpec.default` is non-null. Entries
    /// (and the string/vector contents of their `Expr.Value` payloads)
    /// are arena-owned. Hosts that need the *effective* kvpair shape —
    /// e.g. lifecycle hooks, codegen, downstream printers — consult
    /// the overlay; consumers that want literal author input keep
    /// walking `tree`. Expression defaults whose evaluation fails
    /// surface a `default_eval_failed` validation-phase diagnostic and
    /// contribute no entry.
    materialized_defaults: MaterializedDefaults.MaterializedDefaults,

    /// Lowered output tree, populated when `HostOptions.lowering_registry`
    /// was non-null at validate time. Roots are the forms emitted by
    /// every executed hook; spans inherit from the source forms so
    /// diagnostics surfaced via re-validation trace back to the
    /// author bytes. `tree.root.len == 0` when no hook executed (or
    /// when no registry was supplied).
    lowered_tree: ?Ast.Tree = null,

    /// Form-level provenance side-table mapping each lowered root form
    /// to its source form + hook id. Entries are arena-owned in the
    /// lowered tree's arena. Empty when `lowered_tree == null`.
    lowering_provenance: Lowering.LoweringProvenance = .{},

    /// Materialized-defaults overlay for `lowered_tree` — the terminal
    /// lowering layer's defaults, keyed on the lowered tree's node
    /// indices. Pair it with `lowered_tree` in an `EffectiveView` to
    /// resolve schema `:default`s on hook-emitted forms; the source
    /// `materialized_defaults` overlay is keyed on source NodeIndices
    /// and never matches a lowered form. Entries (and the string /
    /// vector contents of their payloads) are arena-owned by this
    /// `arena`; the `form` indices point into `lowered_tree`, kept
    /// alive alongside. Empty `.{}` whenever `lowered_tree == null`.
    lowered_materialized_defaults: MaterializedDefaults.MaterializedDefaults = .{},

    pub fn deinit(self: *HostResult) void {
        for (self.plugin_results) |*pr| pr.deinit();
        self.tree.deinit();
        if (self.lowered_tree) |*lt| lt.deinit();
        self.arena.deinit();
    }

    pub fn hasErrors(self: *const HostResult) bool {
        for (self.diagnostics) |d| if (d.severity == .err) return true;
        return false;
    }
};

/// Eagerly-loaded plugin set for a workspace's `sjon-project.sjon` file.
/// Returned by `Host.loadProject` and consumed by callers that want one
/// schema shared across many documents (the LSP is the canonical case).
/// Compare with `HostResult`, which builds a fresh schema per
/// single-document call.
///
/// Memory: `arena` backs `plugins`, `plugin_results` (outer slice),
/// `diagnostics`, `project_source`, and `project_uri`. Each
/// `plugin_results[i]` owns its own per-manifest arena. Caller must
/// invoke `LoadedProject.deinit()` exactly once.
pub const LoadedProject = struct {
    arena: std.heap.ArenaAllocator,
    /// Pure aggregate over `plugins`. No allocation; not deinited.
    schema: Schema.Schema,
    /// Plugins in declaration order: `plugins[0]` is the always-seeded
    /// `core` plugin; subsequent entries alias `plugin_results[i].plugin`
    /// for project entries that loaded cleanly.
    plugins: []const Plugin.Plugin,
    /// One entry per project plugin that loaded without err-severity
    /// diagnostics. Each owns its own arena.
    plugin_results: []ManifestLoader.Result,
    /// Phase-tagged diagnostics from project-file parse and per-manifest
    /// load failures. All entries carry `phase = .manifest`.
    diagnostics: []const HostDiagnostic,
    /// Source bytes of the project file when one was discovered and
    /// loaded. Null when no project root was supplied or the project
    /// file was missing. Lifetime: arena.
    project_source: ?[:0]const u8,
    /// `file://`-scheme URI of the project file. Null when no project
    /// file was discovered. Lifetime: arena.
    project_uri: ?[]const u8,
    /// Executable-plugin runtime holding every project plugin whose
    /// manifest resolved to wasm bytes, constructed on first use during
    /// the load. Null on a build that cannot execute plugins, on wasm32,
    /// and whenever no project plugin shipped a sidecar.
    ///
    /// Heap-allocated rather than stored inline because `LoadedProject`
    /// is returned by value and then moved into the caller's own storage
    /// (`lsp/Handler.project`); a runtime living in the struct would be
    /// byte-copied along with it, and wasmtime stores hold pointers into
    /// their own allocation. Freed here in `deinit`, before the arena, on
    /// the gpa the arena was built from.
    ///
    /// Lifetime against the LSP's `cross_ref_arena`: strictly longer. The
    /// index arena is replaced on every revalidation; this runtime lives
    /// for the whole project epoch and dies with the project it loaded.
    runtime: ?*PluginRuntime,

    pub fn deinit(self: *LoadedProject) void {
        if (comptime native_plugin_exec) {
            if (self.runtime) |rt| {
                const gpa = self.arena.child_allocator;
                rt.deinit(gpa);
                gpa.destroy(rt);
            }
        }
        for (self.plugin_results) |*pr| pr.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// The runtime as the opaque context `ProviderExtraction.Invoker` and
    /// `wasm_plugin_invoker` take. Null is the honest answer for "this
    /// host cannot run providers" — it is what turns a provider-backed
    /// cross-ref into `unavailable` rather than into silence.
    pub fn runtimeContext(self: *const LoadedProject) ?*anyopaque {
        const rt = self.runtime orelse return null;
        return @ptrCast(rt);
    }

    pub fn hasErrors(self: *const LoadedProject) bool {
        for (self.diagnostics) |d| if (d.severity == .err) return true;
        return false;
    }
};

/// Result of preloading an external schema once (F9). Each source in
/// `manifest_sources` is a standalone `(plugin …)` manifest; `preloadSchema`
/// loads the set into one self-contained, arena-owned bundle a caller can
/// hand to many `validateDocument` calls via `HostOptions.preloaded` without
/// re-parsing the schema per document.
///
/// Memory: shape mirrors `LoadedProject`. `arena` backs the `plugin_results`
/// (outer slice), `plugins`, and `diagnostics` slices; each
/// `plugin_results[i]` owns its own per-manifest arena. Caller invokes
/// `deinit()` exactly once — and only *after* every `HostResult` that
/// borrowed this bundle has itself been deinited (borrow-by-design; see
/// `HostOptions.preloaded`).
pub const PreloadedSchema = struct {
    arena: std.heap.ArenaAllocator,
    /// One entry per cleanly-loaded source, in `manifest_sources` order.
    /// Sources with parse / load / shape errors contribute no entry. Each
    /// owns its own arena.
    plugin_results: []ManifestLoader.Result,
    /// Borrowed view: `plugins[i] == &plugin_results[i].plugin`. User-only —
    /// no `core` is seeded (mirrors `HostResult.plugins`); the document-time
    /// pipeline prepends `core` itself.
    plugins: []const Plugin.Plugin,
    /// Pure aggregate over `plugins`. No allocation; not deinited.
    schema: Schema.Schema,
    /// Phase-tagged diagnostics from the manifest-load pass (`.manifest`,
    /// spans local to each source) and the five aggregate validators
    /// (`.aggregate`), concatenated in that order. Because every span is
    /// local to a manifest source (never the eventual document), a borrowing
    /// `validateDocument` needs no span rebasing — its own diagnostics are
    /// document-local by construction.
    diagnostics: []const HostDiagnostic,

    pub fn deinit(self: *PreloadedSchema) void {
        for (self.plugin_results) |*pr| pr.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn hasErrors(self: *const PreloadedSchema) bool {
        for (self.diagnostics) |d| if (d.severity == .err) return true;
        return false;
    }
};

/// The parsed tree plus the arena-backed derived state produced by the
/// manifest-resolution prefix shared by `validateDocument` and `evalExpr`.
/// The caller owns the arena (whose `a` allocator backs every slice here),
/// the diagnostics list, and the lazy plugin runtime — see `prepareDocument`.
const PreparedDocument = struct {
    tree: Ast.Tree,
    part: Partition,
    plugin_results: []ManifestLoader.Result,
    plugins: []Plugin.Plugin,
    schema: Schema.Schema,
    eval_schema: Schema.Schema,
    /// Names in the project's `:plugins` index (arena-owned copies).
    /// Best-effort: populated only when this pass auto-constructed the
    /// filesystem resolver; empty with an injected `options.resolver`
    /// or no project. See `HostResult.project_plugin_names`.
    project_plugin_names: []const []const u8,
};

/// Run the manifest-resolution prefix that `validateDocument` and `evalExpr`
/// share verbatim: parse → wrap parse diagnostics → partition → load inline
/// `(plugin …)` declarations → resolve `(use-plugin …)` references (building
/// the default filesystem resolver when the caller supplies project_root+io)
/// → dedupe plugin names → preflight resolved wasm → build the user-only and
/// core-prepended schemas → run the five aggregate validators.
///
/// Ownership contract. The CALLER owns `arena` (and passes its `a`), the
/// `diags` list, and the lazy plugin runtime (`runtime_storage` +
/// `runtime_initialized`); all three are threaded by pointer so the caller's
/// divergent tail (`runEvalPass` / `evalWithRuntime`) reaches the very runtime
/// instance this pass initialized during wasm preflight. `prepareDocument`
/// creates and returns the `tree` (a move the callers already perform into
/// their result structs) plus the arena-backed derived state. On error it
/// tears the tree and any adopted plugin Results back down; on success the
/// caller re-arms those two errdefers for its own tail.
fn prepareDocument(
    gpa: Allocator,
    a: Allocator,
    source: [:0]const u8,
    options: HostOptions,
    diags: *std.ArrayList(HostDiagnostic),
    runtime_storage: *(if (native_plugin_exec) PluginRuntime else void),
    runtime_initialized: *bool,
) Error!PreparedDocument {
    // Parse must succeed structurally. A returned tree may carry parse
    // diagnostics; those are forwarded into the host stream and the rest
    // of the pipeline still runs against the (possibly-partial) tree.
    var tree = Parser.parse(gpa, source) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    errdefer tree.deinit();

    for (tree.diagnostics) |d| {
        try diags.append(a, try wrapDiagnostic(a, d, .manifest, null));
    }

    const part = try partition(a, &tree);

    var plugin_results: std.ArrayList(ManifestLoader.Result) = .empty;
    errdefer for (plugin_results.items) |*pr| pr.deinit();

    for (part.declarations) |decl_idx| {
        const hdr = tree.formHeader(decl_idx);
        const decl_head_span = hdr.head_span;

        // Tree-copy substitution: the loader walks `tree.root`, and
        // we want it to see exactly one root (this declaration). The
        // copy aliases the original arena — never call `.deinit()` on it.
        var sub: Ast.Tree = tree;
        const sub_roots = try a.alloc(Ast.NodeIndex, 1);
        sub_roots[0] = decl_idx;
        sub.root = sub_roots;

        var loaded = ManifestLoader.load(gpa, sub) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            // `NotAPluginManifest` only fires when the gate predicate
            // disagrees with the loader — defensive shape mismatch.
            // Surface as `invalid_manifest` at the declaration head.
            error.NotAPluginManifest => {
                try diags.append(a, .{
                    .phase = .manifest,
                    .code = .invalid_manifest,
                    .severity = .err,
                    .message = try a.dupe(u8, "(plugin …) declaration rejected by manifest loader"),
                    .span = decl_head_span,
                    .path = &.{},
                    .declaration_span = decl_head_span,
                });
                continue;
            },
        };

        // `loaded` owns its arena from here until it is either dropped (the
        // `hasErrors` branch below) or adopted by `plugin_results`. Guard that
        // window: an OOM in the diagnostics loop or the `append` would
        // otherwise leak the whole Result — it isn't in `plugin_results.items`
        // yet, so the outer errdefer doesn't reach it. A normal iteration exit
        // (the `continue` after an explicit `deinit`, or a successful append)
        // discharges this errdefer without firing.
        errdefer loaded.deinit();

        for (loaded.diagnostics) |d| {
            try diags.append(a, try wrapDiagnostic(a, d, .manifest, decl_head_span));
        }

        if (loaded.hasErrors()) {
            // The plugin can't contribute to the schema. Drop the
            // Result here so its arena releases immediately rather
            // than leaking through the HostResult.
            loaded.deinit();
            continue;
        }

        try plugin_results.append(a, loaded);
    }

    // Resolver phase — every `(use-plugin …)` reference becomes a
    // resolver call. With no resolver installed, references fail with
    // `unresolved_plugin`; with one, the resolver returns either a
    // manifest envelope (manifest source plus optional wasm bytes; see
    // `Resolver.ManifestResolution`) — we hand the source off to
    // ManifestLoader mirroring the inline-manifest loop above — or a
    // structured failure.
    //
    // When the caller did not supply an explicit resolver, build the
    // default filesystem resolver so `sjon-project.sjon` lookups work
    // with no extra plumbing. Project-load diagnostics (from parsing the
    // project file and indexing each `:plugins` entry) are drained once
    // here so they appear under `phase = .manifest` alongside inline
    // manifest diagnostics.
    // Hosted builds may auto-construct a `FilesystemResolver` when the
    // caller supplies `project_root` + `io` and no explicit resolver.
    // Freestanding/wasm builds have no `Dir.cwd()`, so the branch is
    // gated at comptime and the local handle is replaced with a stub —
    // wasm hosts always inject `options.resolver` themselves.
    var owned_default_resolver: ?(if (builtin.os.tag == .freestanding) void else FilesystemResolver) = null;
    defer if (comptime builtin.os.tag != .freestanding) {
        if (owned_default_resolver) |*r| r.deinit();
    };

    const effective_resolver: ?Resolver.Resolver = blk: {
        if (options.resolver) |r| break :blk r;
        if (comptime builtin.os.tag == .freestanding) break :blk null;
        const root = options.project_root orelse break :blk null;
        const io = options.io orelse break :blk null;
        owned_default_resolver = try FilesystemResolver.init(
            gpa,
            io,
            root,
            options.project_file,
        );
        const project_diags = owned_default_resolver.?.takeProjectDiagnostics();
        for (project_diags) |d| {
            try diags.append(a, try wrapProjectDiagnostic(a, d));
        }
        break :blk owned_default_resolver.?.resolver();
    };

    // Did-you-mean candidate pool for `unresolved_plugin`: the project
    // index's plugin names, duped out of the resolver arena before the
    // deferred teardown. Harvested from the *index*, not the loaded set —
    // a typo'd `(use-plugin …)` means the real plugin never loads, but it
    // is still indexed. Best-effort: an injected `options.resolver` (wasm
    // hosts) exposes no name enumeration, so the pool stays empty there.
    var project_plugin_names: []const []const u8 = &.{};
    if (comptime builtin.os.tag != .freestanding) {
        if (owned_default_resolver) |*r| {
            var names: std.ArrayList([]const u8) = .empty;
            var name_it = r.iterateProjectPlugins();
            while (name_it.next()) |entry| {
                try names.append(a, try a.dupe(u8, entry.name));
            }
            project_plugin_names = names.items;
        }
    }

    for (part.references) |ref_idx| {
        const ref_hdr = tree.formHeader(ref_idx);
        const ref_head_span = ref_hdr.head_span;

        var parsed = try Resolver.parseReference(a, &tree, ref_idx);
        for (parsed.diagnostics) |d| {
            try diags.append(a, try wrapDiagnostic(a, d, .manifest, ref_head_span));
        }
        if (parsed.hasErrors()) continue;

        const resolver = effective_resolver orelse {
            try diags.append(a, .{
                .phase = .manifest,
                .code = .unresolved_plugin,
                .severity = .err,
                .message = try std.fmt.allocPrint(
                    a,
                    "no resolver configured for `(use-plugin \"{s}\" …)`",
                    .{parsed.reference.name},
                ),
                .span = parsed.reference.span,
                .path = &.{},
                .declaration_span = ref_head_span,
            });
            continue;
        };

        const resolution = try resolver.resolve(resolver.ctx, parsed.reference, a);
        switch (resolution) {
            .manifest => |m| {
                if (try enforceHashPin(a, parsed.reference, ref_head_span, m, diags)) continue;
                const before_len = plugin_results.items.len;
                try loadResolvedManifest(
                    gpa,
                    a,
                    m.source,
                    m.wasm,
                    parsed.reference,
                    ref_head_span,
                    &plugin_results,
                    diags,
                );
                // `loadResolvedManifest` only appends on success.
                if (plugin_results.items.len <= before_len) continue;

                // Dedupe: if the just-loaded plugin's name collides with
                // one already loaded from an earlier `(use-plugin)`
                // reference, emit `duplicate_plugin_name` and drop the
                // duplicate. Without this, `Schema.lookupForm` sees two
                // claimants for every form name and returns
                // `ambiguous_form` for any bare invocation — innocuous
                // duplicate references would corrupt schema lookup.
                const new_idx = plugin_results.items.len - 1;
                const new_name = plugin_results.items[new_idx].plugin.name;
                var is_duplicate = false;
                for (plugin_results.items[0..before_len]) |*pr| {
                    if (!std.mem.eql(u8, pr.plugin.name, new_name)) continue;
                    try diags.append(a, .{
                        .phase = .manifest,
                        .code = .duplicate_plugin_name,
                        .severity = .err,
                        .message = try std.fmt.allocPrint(
                            a,
                            "(use-plugin \"{s}\" …) resolves to plugin `:name {s}` already loaded by an earlier reference",
                            .{ parsed.reference.name, new_name },
                        ),
                        .span = parsed.reference.span,
                        .path = &.{},
                        .declaration_span = ref_head_span,
                    });
                    var popped = plugin_results.pop().?;
                    popped.deinit();
                    is_duplicate = true;
                    break;
                }
                if (is_duplicate) continue;

                if (m.wasm == null) {
                    // Manifest loaded, but no wasm bytes accompanied it.
                    // If the manifest declares `:impl "wasm:..."` exports
                    // the executable side is missing entirely — surface
                    // plugin_wasm_required so the failure shows up at
                    // load time rather than as a generic
                    // PluginFuncNotImplemented at eval time.
                    const loaded_plugin = &plugin_results.items[plugin_results.items.len - 1].plugin;
                    var missing_count: usize = 0;
                    for (loaded_plugin.expr_funcs) |func| {
                        if (func.wasm_export_name != null) missing_count += 1;
                    }
                    if (missing_count > 0) {
                        try diags.append(a, .{
                            .phase = .manifest,
                            .code = .plugin_wasm_required,
                            .severity = .err,
                            .message = try std.fmt.allocPrint(
                                a,
                                "(use-plugin \"{s}\" …) manifest declares {d} `:impl \"wasm:…\"` export(s) but resolver returned no wasm bytes",
                                .{ parsed.reference.name, missing_count },
                            ),
                            .span = parsed.reference.span,
                            .path = &.{},
                            .declaration_span = ref_head_span,
                        });
                    }
                } else if (comptime native_plugin_exec) {
                    // Pre-flight the resolved wasm bytes. On reject the
                    // helper appends the diagnostic and pops the plugin
                    // from `plugin_results`; we just `continue` past
                    // schema aggregation for this reference. On
                    // success the plugin stays registered and
                    // `runEvalPass` dispatches any `:impl "wasm:<name>"`
                    // call through the now-initialized runtime.
                    if (try preflightWasmIfPresent(
                        a,
                        gpa,
                        &plugin_results,
                        diags,
                        parsed.reference,
                        ref_head_span,
                        m,
                        runtime_storage,
                        runtime_initialized,
                    )) continue;
                }
            },
            .failure => |failure| {
                try diags.append(a, .{
                    .phase = .manifest,
                    .code = failure.code,
                    .severity = .err,
                    .message = try a.dupe(u8, failure.detail),
                    .span = parsed.reference.span,
                    .path = &.{},
                    .declaration_span = ref_head_span,
                });
            },
        }
    }

    // Freeze the document-loaded plugins into a borrowed view. This slice
    // stays DOCUMENT-ONLY: preloaded plugins (below) are borrowed from
    // `options.preloaded` — their arenas owned there — never adopted here, so
    // `HostResult.deinit`, which walks `plugin_results`, never touches a
    // preloaded arena.
    const plugin_results_slice = try plugin_results.toOwnedSlice(a);
    // After `toOwnedSlice`, the original `plugin_results` ArrayList is
    // empty, so the outer errdefer on its `.items` is a no-op. Re-arm
    // the cleanup against the new slice for the rest of this function so
    // a downstream OOM doesn't strand any per-plugin arenas.
    errdefer for (plugin_results_slice) |*pr| pr.deinit();

    // Public user schema = preloaded plugins (borrowed, if any) ++
    // document-loaded plugins, in that order — inline `(plugin …)` /
    // `(use-plugin …)` are additive on top of the preloaded set. No `core`
    // (user-only, mirroring `HostResult.schema` / `.plugins`). `plugins[i]`
    // aliases `plugin_results[i].plugin` only for the document-loaded suffix
    // (the first `preloaded.plugins.len` entries alias the preloaded bundle).
    const preloaded_plugins: []const Plugin.Plugin =
        if (options.preloaded) |pre| pre.plugins else &.{};
    const plugins_slice = try a.alloc(Plugin.Plugin, preloaded_plugins.len + plugin_results_slice.len);
    for (preloaded_plugins, 0..) |p, i| plugins_slice[i] = p;
    for (plugin_results_slice, 0..) |pr, i| plugins_slice[preloaded_plugins.len + i] = pr.plugin;
    const schema: Schema.Schema = .{ .plugins = plugins_slice };

    // Build the eval-pass / form-validator schema with core prepended:
    // core ++ preloaded ++ document. Forest validation and `runEvalPass` need
    // core in scope so top-level core forms (`(map [x] xs body)`,
    // `(if test then)`, `(* x y)` inside expression slots) resolve without
    // `unknown_form`, and the eval pass can dispatch core funcs. The
    // preloaded set is just more user plugins riding alongside the inline
    // ones. Aggregate validators (cross-refs / unions / forms / lowering /
    // defaults) keep using the user-only `schema` — they check schema-internal
    // consistency, not document-level form heads, and including core there
    // would either be a no-op or surface as confused duplicate-name
    // diagnostics. Public `HostResult.schema` / `HostResult.plugins` stays
    // user-only by design.
    const eval_plugins = try a.alloc(Plugin.Plugin, plugins_slice.len + 1);
    eval_plugins[0] = core_plugin.plugin;
    for (plugins_slice, 0..) |p, i| eval_plugins[i + 1] = p;
    const eval_schema: Schema.Schema = .{ .plugins = eval_plugins };

    // Aggregate phase — the five schema-internal validators, each owning a
    // gpa-allocated slice copied into the host arena then freed. Their order
    // is corpus-locked (see `runAggregateValidators`). Run ONLY when this
    // document contributed at least one plugin: when it didn't, any aggregate
    // diagnostics over the preloaded set were already reported by
    // `preloadSchema` (onto `PreloadedSchema.diagnostics`), and re-running
    // here would duplicate them. With no preloaded schema this is
    // byte-identical to the old unconditional run — the validators produce
    // nothing over zero plugins. (A document that DOES add a plugin
    // re-validates the combined set, re-reporting the preloaded-set aggregate
    // alongside any new cross-set diagnostics — documented on
    // `HostOptions.preloaded`.)
    if (plugin_results_slice.len > 0) {
        try runAggregateValidators(gpa, a, schema, diags);
    }

    return .{
        .tree = tree,
        .part = part,
        .plugin_results = plugin_results_slice,
        .plugins = plugins_slice,
        .schema = schema,
        .eval_schema = eval_schema,
        .project_plugin_names = project_plugin_names,
    };
}

/// Run the staged lowering pass — layer 0 over the source forest, then
/// each subsequent layer over the previous layer's emitted forms. Fills
/// the caller's `stage_trees` / `stage_mats` / `stage_terminals` buffers
/// (whose lifetimes the caller owns and threads into the final-forest
/// validation) and appends every `.lowering`-phase diagnostic to `diags`.
/// Returns the source forms that never lowered (the layer-0 terminals),
/// which `validateDocument` validates alongside each layer's terminals.
/// Only called when the caller supplied a `lowering_registry`.
fn runLoweringStages(
    gpa: Allocator,
    a: Allocator,
    tree: *const Ast.Tree,
    data_forest: []const Ast.NodeIndex,
    schema: Schema.Schema,
    eval_schema: Schema.Schema,
    source_overlay: *const MaterializedDefaults.MaterializedDefaults,
    effective_axes: Validator.EffectiveAxes,
    lowering_env: *const Expr.Env,
    registry: *const Lowering.LoweringRegistry,
    diags: *std.ArrayList(HostDiagnostic),
    stage_trees: *std.ArrayList(Lowering.LoweredTree),
    stage_mats: *std.ArrayList(MaterializedDefaults.Result),
    stage_terminals: *std.ArrayList([]const Ast.NodeIndex),
) Error![]const Ast.NodeIndex {
    var unlowered_roots: []const Ast.NodeIndex = data_forest;

    try stage_trees.ensureTotalCapacity(gpa, Lowering.MAX_LOWERING_STAGES);
    try stage_mats.ensureTotalCapacity(gpa, Lowering.MAX_LOWERING_STAGES);
    try stage_terminals.ensureTotalCapacity(gpa, Lowering.MAX_LOWERING_STAGES);

    var emitted_total: usize = 0;
    var active_tree: *const Ast.Tree = tree;
    var active_forest: []const Ast.NodeIndex = data_forest;
    var active_overlay: *const MaterializedDefaults.MaterializedDefaults = source_overlay;
    // Slot in `stage_trees` for the active layer's tree, or null for
    // layer 0 (the source tree, whose terminals are `unlowered_roots`).
    var active_slot: ?usize = null;

    var stage: usize = 0;
    while (true) : (stage += 1) {
        var pass_result = Lowering.runLoweringPassBudgeted(
            gpa,
            a,
            active_tree,
            active_forest,
            // `eval_schema` (core prepended), NOT the user-only `schema`:
            // the surface-validation gate and a hook's `numberEval` both
            // validate/evaluate author expressions in value slots
            // (`:count (* workgroup-size 1)`), which need core forms in
            // scope or they fail `unknown_form` — exactly the reasoning
            // that makes forest validation below use `eval_schema`.
            eval_schema,
            active_overlay,
            registry,
            effective_axes,
            lowering_env,
            &emitted_total,
            Lowering.MAX_LOWERING_STEPS,
        ) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
        };
        defer pass_result.deinit(gpa);

        for (pass_result.diagnostics) |d| {
            try diags.append(a, try wrapDiagnostic(a, d, .lowering, null));
        }

        // Decide this layer's terminal roots and whether to stop.
        var terminal: []const Ast.NodeIndex = undefined;
        var stop = false;
        if (pass_result.invocations.len == 0) {
            // Nothing lowered — every active root is terminal.
            terminal = active_forest;
            stop = true;
        } else if (stage + 1 >= Lowering.MAX_LOWERING_STAGES) {
            // Stage budget exhausted before this layer could lower.
            // Surface the cap at each would-lower form (the span chains
            // back to the original surface bytes) and stop; those forms
            // stay terminal and validate as authored.
            for (pass_result.invocations) |inv| {
                const head = active_tree.formHeader(inv.source_form_idx).head;
                const path = try a.alloc([]const u8, 2);
                path[0] = try a.dupe(u8, head);
                path[1] = try a.dupe(u8, "lowering");
                try diags.append(a, try wrapDiagnostic(a, .{
                    .span = active_tree.spanOf(inv.source_form_idx),
                    .message = try std.fmt.allocPrint(a, "form `({s} …)` would lower beyond the maximum staging depth of {d} layers", .{ head, Lowering.MAX_LOWERING_STAGES }),
                    .severity = .err,
                    .code = .lowering_output_too_large,
                    .path = path,
                }, .lowering, null));
            }
            terminal = active_forest;
            stop = true;
        } else {
            terminal = try filterUnloweredRoots(a, active_forest, pass_result.invocations);
        }
        if (active_slot) |s| stage_terminals.items[s] = terminal else unlowered_roots = terminal;
        if (stop) break;

        // Build this layer's lowered tree (spans inherit from
        // `active_tree`, chaining home) and materialize its overlay.
        const lt = Lowering.buildLoweredTree(gpa, pass_result.invocations, active_tree) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
        };
        stage_trees.appendAssumeCapacity(lt);
        const slot = stage_trees.items.len - 1;
        const lmat = MaterializedDefaults.materializeDefaults(
            gpa,
            a,
            &stage_trees.items[slot].tree,
            stage_trees.items[slot].tree.root,
            schema,
        ) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
        };
        stage_mats.appendAssumeCapacity(lmat);
        stage_terminals.appendAssumeCapacity(&.{}); // set when this layer is processed

        active_tree = &stage_trees.items[slot].tree;
        active_forest = active_tree.root;
        active_overlay = &stage_mats.items[slot].materialized;
        active_slot = slot;
    }

    return unlowered_roots;
}

/// Run the provider-extraction pre-pass over the forest that is about to
/// be validated.
///
/// Placed in lowering's layer, and for lowering's reason: the validator
/// must not be able to execute anything, so everything executable happens
/// ahead of it and hands over a finished table. What comes back is
/// content-addressed by `(provider, source)`, which is why this can run
/// over the whole forest in one walk while the index pass looks answers
/// up during its own.
///
/// The forest, not the source tree: a lowered form can be a cross-ref
/// target like any other, so an extraction the index pass will ask for
/// may only exist after lowering.
///
/// Cheap to skip — a schema whose cross-refs name no provider stops at an
/// allocation-free scan, so every document written before this feature
/// existed pays nothing measurable.
///
/// Public because the LSP runs its own forest pass rather than going
/// through `validateDocument`: it holds many open documents against one
/// schema and re-validates them together. `runtime` is the opaque context
/// from `LoadedProject.runtimeContext()` — null on any host that cannot
/// execute plugins, which yields a table of `unavailable` entries rather
/// than an absent one. Caller owns the returned `Table` and must
/// `deinit()` it; the validator dupes whatever it keeps, so the table can
/// be released as soon as the pass it fed has returned.
pub fn extractProviders(
    gpa: Allocator,
    schema: Schema.Schema,
    forest: []const Ast.Tree,
    runtime: ?*anyopaque,
) Error!ProviderExtraction.Table {
    var requests = Validator.collectExtractionRequests(gpa, schema, forest) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    defer requests.deinit();
    return ProviderExtraction.fulfill(
        gpa,
        schema,
        requests.items,
        ProviderExtraction.Invoker.plugins(runtime),
    );
}

test "extractProviders answers the pairs a document asks for" {
    const gpa = std.testing.allocator;

    const Fixture = struct {
        fn extract(a: Allocator, source: []const u8) Plugin.CrossRefProvider.ExtractError![]const []const u8 {
            var out: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, source, ' ');
            while (it.next()) |word| {
                if (word.len == 0) continue;
                try out.append(a, word);
            }
            return out.items;
        }
    };

    // A native `:impl`, so the pass is exercised on every build rather
    // than only where `-Dplugin-exec` and a wasm sidecar are available.
    const plugin: Plugin.Plugin = .{
        .name = "glsl",
        .cross_ref_providers = &.{.{ .name = "words", .impl = Fixture.extract }},
        .value_kinds = &.{.{
            .name = "uniform-name",
            .underlying = .symbol,
            .cross_ref = .{ .targets = &.{"shader"}, .provider = "words" },
        }},
        .forms = &.{.{ .name = "shader", .keys = &.{
            .{ .name = "name", .value_type = .symbol },
            .{ .name = "src", .value_type = .string },
        } }},
    };
    const schema = Schema.Schema.init(&.{plugin});

    var tree = try Parser.parse(gpa, "(shader :name a :src \"u_one u_two\")");
    defer tree.deinit();
    const forest = [_]Ast.Tree{tree};

    var table = try extractProviders(gpa, schema, &forest, null);
    defer table.deinit();

    const names = table.get("glsl/words", "u_one u_two").?.names;
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("u_one", names[0]);
    try std.testing.expectEqualStrings("u_two", names[1]);
}

test "extractProviders is a no-op for a schema with no provider route" {
    const gpa = std.testing.allocator;

    const plugin: Plugin.Plugin = .{
        .name = "glsl",
        .value_kinds = &.{.{
            .name = "uniform-name",
            .underlying = .symbol,
            .cross_ref = .{ .targets = &.{"shader"} },
        }},
        .forms = &.{.{ .name = "shader", .keys = &.{.{ .name = "name", .value_type = .symbol }} }},
    };
    var tree = try Parser.parse(gpa, "(shader :name a)");
    defer tree.deinit();
    const forest = [_]Ast.Tree{tree};

    var table = try extractProviders(gpa, Schema.Schema.init(&.{plugin}), &forest, null);
    defer table.deinit();
    try std.testing.expectEqual(@as(u32, 0), table.map.count());
}

/// Validate a document whose source declares its plugins inline and uses
/// them in the same file. Pipeline:
///   1. parse `source` into a `Tree`; parse-time diagnostics flow into
///      `diagnostics` with `phase = .manifest`.
///   2. partition `tree.root` into declarations / references / data.
///   3. for each declaration, run `ManifestLoader.load` over a
///      single-root view of the tree and pass through any diagnostics
///      with `phase = .manifest, declaration_span = head_span`.
///   4. `Schema.init(loaded_plugins)` — pure; then run all three schema
///      aggregate validators and pass diagnostics through with
///      `phase = .aggregate`.
///   5. run `Validator.validate` over a data-forest view of the tree;
///      diagnostics carry `phase = .validation`.
///
/// `HostOptions.failure_policy` does NOT change what's emitted in D1 —
/// it only affects D2's CLI exit-code policy.
pub fn validateDocument(
    gpa: Allocator,
    source: [:0]const u8,
    options: HostOptions,
) Error!HostResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var diags: std.ArrayList(HostDiagnostic) = .empty;

    // Native executable-plugin runtime (lazy: only created when a
    // wasm-bearing manifest actually resolves). When `plugin_exec` is
    // off the storage compiles to `void` and the comptime branches
    // around it disappear; when on but the document carries no wasm
    // plugins, we never instantiate the wasmtime engine.
    // `runtime_initialized` guards `deinit` so the engine/linker
    // handles only roll back when we actually created them.
    var runtime_storage: if (native_plugin_exec) PluginRuntime else void = undefined;
    var runtime_initialized: bool = false;
    defer if (comptime native_plugin_exec) {
        if (runtime_initialized) runtime_storage.deinit(gpa);
    };

    const prepared = try prepareDocument(gpa, a, source, options, &diags, &runtime_storage, &runtime_initialized);
    var tree = prepared.tree;
    errdefer tree.deinit();
    errdefer for (prepared.plugin_results) |*pr| pr.deinit();
    const part = prepared.part;
    const schema = prepared.schema;
    const eval_schema = prepared.eval_schema;
    const plugins_slice = prepared.plugins;
    const plugin_results_slice = prepared.plugin_results;

    // Default materialization — built *before* validation so the overlay
    // is available to the validator (consumed by the effective-axes
    // path in commit 2). The overlay depends only on
    // (tree, schema, data_forest), all stable after the aggregate phase.
    // Entries land in the host arena (so they outlive the per-manifest
    // plugin arenas); gpa-side diagnostics are copied via `wrapDiagnostic`
    // before `mat_result.deinit(gpa)` releases them.
    //
    // Diagnostic-stream ordering: validator diagnostics are emitted into
    // `diags` first, then materializer diagnostics — this matches the
    // pre-reorder order so the conformance corpus stays byte-identical.
    var mat_result = MaterializedDefaults.materializeDefaults(
        gpa,
        a,
        &tree,
        part.data_forest,
        schema,
    ) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    defer mat_result.deinit(gpa);

    // Lowering — staged. Only runs when the caller supplied a registry.
    // Each layer runs `runLoweringPass` over the current active forest
    // (the source forest for layer 0, then each layer's emitted forms),
    // rebuilds a lowered tree, and materializes its overlay. Layering
    // stops when a layer lowers nothing, at `MAX_LOWERING_STAGES`, or when
    // the cumulative emitted-form budget (`MAX_LOWERING_STEPS`, threaded
    // via `emitted_total`) trips. Diagnostics from the pass stamp
    // `.lowering`. No registry → no-op, so the conformance corpus stays
    // byte-identical for fixtures that don't exercise lowering.
    //
    // The final forest validated below is the source forms that never
    // lowered, plus — per layer — the emitted forms terminal at that
    // layer. Emitted nodes inherit their source form's span, so by
    // transitivity a terminal form's span points back at the original
    // surface bytes.
    var lowered_tree: ?Ast.Tree = null;
    var lowering_provenance: Lowering.LoweringProvenance = .{};
    // The terminal layer's defaults overlay, returned in
    // `HostResult.lowered_materialized_defaults`. A slice header into the
    // host arena (see the transfer below); no extra cleanup. Stays `.{}`
    // when nothing lowered.
    var lowered_materialized: MaterializedDefaults.MaterializedDefaults = .{};
    // The terminal layer's tree is returned in `HostResult.lowered_tree`
    // (its arena freed by `HostResult.deinit`). Guard it so an error after
    // it is transferred frees it rather than leaking.
    errdefer if (lowered_tree) |*t| t.deinit();

    // Per-layer lowered trees + overlays, kept alive through the final
    // forest pass. Capacity is reserved to `MAX_LOWERING_STAGES` so
    // element addresses stay stable as the loop appends (the active-tree
    // / active-overlay pointers alias into these lists). `defer`s free the
    // buffers unconditionally; the `errdefer` frees still-owned elements
    // on an error before the success path transfers / frees them.
    var stage_trees: std.ArrayList(Lowering.LoweredTree) = .empty;
    defer stage_trees.deinit(gpa);
    errdefer for (stage_trees.items) |*lt| lt.deinit();
    var stage_mats: std.ArrayList(MaterializedDefaults.Result) = .empty;
    defer {
        for (stage_mats.items) |*m| m.deinit(gpa);
        stage_mats.deinit(gpa);
    }
    // Terminal roots per layer tree (aligned with `stage_trees`): the
    // roots that did NOT lower in that layer's pass. On the host arena.
    var stage_terminals: std.ArrayList([]const Ast.NodeIndex) = .empty;
    defer stage_terminals.deinit(gpa);

    // Source forms that never lowered (layer-0 terminals) stay in the
    // source tree / source overlay. Forms whose hook failed (missing,
    // errored, invalid head, bounds) also stay here and validate as
    // authored.
    var unlowered_roots: []const Ast.NodeIndex = part.data_forest;

    if (options.lowering_registry) |registry| {
        unlowered_roots = try runLoweringStages(
            gpa,
            a,
            &tree,
            part.data_forest,
            schema,
            eval_schema,
            &mat_result.materialized,
            options.effective_axes,
            options.lowering_env,
            registry,
            &diags,
            &stage_trees,
            &stage_mats,
            &stage_terminals,
        );
    }

    // Validation — final-document forest pass. Tree-copy substitution
    // shares each tree's node arena; only `root` differs per view.
    var source_view: Ast.Tree = tree;
    source_view.root = unlowered_roots;

    // Hoisted above the extraction pass: providers reach their plugins
    // through the same runtime the eval pass uses further down.
    const runtime_opt: ?*anyopaque = if (comptime native_plugin_exec)
        (if (runtime_initialized) @ptrCast(&runtime_storage) else null)
    else
        null;

    if (stage_trees.items.len > 0) {
        // Forest = source unlowered roots + each layer's terminal roots.
        const n = stage_trees.items.len;
        const forest = try a.alloc(Ast.Tree, 1 + n);
        const overlay_ptrs = try a.alloc(?*const MaterializedDefaults.MaterializedDefaults, 1 + n);
        forest[0] = source_view;
        overlay_ptrs[0] = &mat_result.materialized;
        for (0..n) |i| {
            var view = stage_trees.items[i].tree;
            view.root = stage_terminals.items[i];
            forest[1 + i] = view;
            overlay_ptrs[1 + i] = &stage_mats.items[i].materialized;
        }
        var extraction = try extractProviders(gpa, schema, forest, runtime_opt);
        defer extraction.deinit();

        // share_scope: the source and every lowered layer are logically
        // one document. A source `:ref` may resolve to a lowered target
        // (and vice versa); without this fuse the validator's per-tree
        // scope isolation (for the LSP's per-file workflow) would surface
        // `not_cross_ref` on every cross-tree reference.
        var fr = Validator.validateForestWithOptions(gpa, forest, eval_schema, .{
            .overlays = overlay_ptrs,
            .axes = options.effective_axes,
            .share_scope = true,
            .extractions = &extraction.map,
        }) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
        };
        defer fr.deinit(gpa);
        for (fr.results) |r| {
            for (r.diagnostics) |d| {
                try diags.append(a, try wrapDiagnostic(a, d, .validation, null));
            }
        }

        // The terminal (last) layer's tree is returned as `lowered_tree`
        // (its arena transfers to HostResult); the intermediate layer
        // trees are freed now. `clearRetainingCapacity` empties the list so
        // the `defer`/`errdefer` above don't touch the transferred tree.
        const last = n - 1;
        lowered_tree = stage_trees.items[last].tree;
        lowering_provenance = stage_trees.items[last].provenance;
        // The terminal layer's overlay entries are arena-owned (host
        // arena `a`); `stage_mats`'s deinit frees only its gpa-owned
        // diagnostics, so this slice header stays valid through the
        // return (the arena moves into `HostResult`, and the entries'
        // `form` indices point into the transferred `lowered_tree`).
        lowered_materialized = stage_mats.items[last].materialized;
        for (stage_trees.items[0..last]) |*lt| lt.deinit();
        stage_trees.clearRetainingCapacity();
    } else {
        // No lowering: single-tree forest, byte-equivalent to the prior
        // source-tree pass.
        const forest = [_]Ast.Tree{source_view};
        var extraction = try extractProviders(gpa, schema, &forest, runtime_opt);
        defer extraction.deinit();

        var fr = Validator.validateForestWithOptions(gpa, &forest, eval_schema, .{
            .overlay = &mat_result.materialized,
            .axes = options.effective_axes,
            .extractions = &extraction.map,
        }) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
        };
        defer fr.deinit(gpa);
        for (fr.results) |r| {
            for (r.diagnostics) |d| {
                try diags.append(a, try wrapDiagnostic(a, d, .validation, null));
            }
        }
    }

    for (mat_result.diagnostics) |d| {
        try diags.append(a, try wrapDiagnostic(a, d, .validation, null));
    }
    // Each layer's lowered-tree materialization can surface its own
    // defaults diagnostics (e.g. a bad computed default on an emitted
    // form). Append them in layer order, matching the single-stage order.
    for (stage_mats.items) |*m| {
        for (m.diagnostics) |d| {
            try diags.append(a, try wrapDiagnostic(a, d, .validation, null));
        }
    }

    // Eval pass — run every top-level form whose head resolves as an
    // expr-func so the runtime adapter's plugin_func_* errors land as
    // validation-phase diagnostics. Native builds (no wasm runtime —
    // `docs/executable-plugin-abi.md` §15.1) short-circuit on
    // `PluginFuncNotImplemented`, which this pass silently drops; that
    // is the documented "declarative-only on Zig native" stance.
    //
    // Nested expressions inside data forms are not walked by this pass
    // — the validator type-checks declared-result expressions in typed
    // slots statically, and the eval pass only needs plugin_func_*
    // coverage at top level for the conformance corpus. Broadening the
    // walk for runtime evaluation of nested forms is a separate scope
    // (e.g. computed-default evaluation per the default-materialization
    // overlay).
    var eval_results: std.ArrayList(EvalResult) = .empty;
    try runEvalPass(a, gpa, &tree, part.data_forest, eval_schema, &diags, &eval_results, runtime_opt);

    return .{
        .arena = arena,
        .tree = tree,
        .plugin_results = plugin_results_slice,
        .plugins = plugins_slice,
        .schema = schema,
        .project_plugin_names = prepared.project_plugin_names,
        .declarations = part.declarations,
        .references = part.references,
        .data_forest = part.data_forest,
        .diagnostics = try diags.toOwnedSlice(a),
        .evaluated_results = try eval_results.toOwnedSlice(a),
        .materialized_defaults = mat_result.materialized,
        .lowered_tree = lowered_tree,
        .lowering_provenance = lowering_provenance,
        .lowered_materialized_defaults = lowered_materialized,
    };
}

/// Build a workspace-scoped schema from the project file's `:plugins`
/// list. Always succeeds — every failure (missing project file,
/// malformed manifest, unreadable manifest) surfaces as a diagnostic on
/// the returned `LoadedProject.diagnostics`. Pass `options.project_root
/// = null` or `options.io = null` to get a core-only result with no
/// project file.
///
/// Pipeline:
///   1. construct a `FilesystemResolver` rooted at `options.project_root`
///      and pointed at `options.project_file` (or derived
///      `<project_root>/sjon-project.sjon` when null).
///   2. drain its project-load diagnostics (parse failures, malformed
///      shape, duplicate `:name`) into the host stream with
///      `phase = .manifest`.
///   3. iterate every indexed plugin via `iterateProjectPlugins`. For
///      each entry, parse the manifest source and run
///      `ManifestLoader.load`; surface per-manifest diagnostics with
///      `phase = .manifest`. Plugins that load cleanly contribute to
///      `plugin_results` and `plugins`.
///   4. seed `plugins[0] = core_plugin.plugin` (always present) and
///      build `Schema { .plugins = ... }`.
///
/// Freestanding/wasm builds: the `FilesystemResolver` branch is
/// comptime-disabled; the function returns a core-only result with no
/// diagnostics. Wasm hosts that need workspace loading must build the
/// equivalent over their own injected resolver — see the future
/// `Host.validateForest()` note in the module header.
pub fn loadProject(
    gpa: Allocator,
    options: HostOptions,
) Error!LoadedProject {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var diags: std.ArrayList(HostDiagnostic) = .empty;
    var plugin_results: std.ArrayList(ManifestLoader.Result) = .empty;
    errdefer for (plugin_results.items) |*pr| pr.deinit();

    var project_source: ?[:0]const u8 = null;
    var project_uri: ?[]const u8 = null;

    var runtime: ?*PluginRuntime = null;
    errdefer if (comptime native_plugin_exec) {
        if (runtime) |rt| {
            rt.deinit(gpa);
            gpa.destroy(rt);
        }
    };

    // FilesystemResolver depends on `std.Io.Dir.cwd()` which has no
    // implementation on freestanding/wasm. The branch is comptime-gated;
    // wasm hosts that want eager project loading would route through
    // their own resolver implementation (out of scope for this API).
    if (comptime builtin.os.tag != .freestanding) {
        if (options.project_root) |root| if (options.io) |io| {
            const project_file = if (options.project_file) |pf|
                try a.dupe(u8, pf)
            else
                try buildProjectFilePath(a, root);

            var fs = try FilesystemResolver.init(gpa, io, root, project_file);
            defer fs.deinit();

            const project_diags = fs.takeProjectDiagnostics();
            for (project_diags) |d| {
                try diags.append(a, try wrapProjectDiagnostic(a, d));
            }

            if (fs.getProjectSource()) |src| {
                project_source = try a.dupeZ(u8, src);
                project_uri = try buildFileUri(a, project_file);
            }

            // Wasm bytes are consumed by `register`, which copies what it
            // keeps — so one arena, reset per entry, rather than a
            // project-lifetime copy of every sidecar.
            var wasm_scratch = std.heap.ArenaAllocator.init(gpa);
            defer wasm_scratch.deinit();

            var it = fs.iterateProjectPlugins();
            while (it.next()) |entry| {
                const before = plugin_results.items.len;
                try loadProjectPlugin(gpa, a, entry, &plugin_results, &diags);
                if (comptime native_plugin_exec) {
                    // The manifest failed to load and contributed nothing;
                    // there is no plugin to register bytes against.
                    if (plugin_results.items.len == before) continue;

                    _ = wasm_scratch.reset(.retain_capacity);
                    const wasm = try fs.resolveProjectPluginWasm(wasm_scratch.allocator(), entry);
                    const bytes = wasm orelse continue;
                    try registerProjectPluginWasm(
                        gpa,
                        a,
                        &runtime,
                        &plugin_results.items[before].plugin,
                        bytes,
                        entry.manifest_path,
                        &diags,
                    );
                }
            }
        };
    }

    // Seed core[0] + every cleanly-loaded plugin. Index 0 mirrors the
    // legacy LSP behavior: `core` is always present and bare lookups
    // for core forms continue to work even if no project file exists.
    const plugin_results_slice = try plugin_results.toOwnedSlice(a);
    errdefer for (plugin_results_slice) |*pr| pr.deinit();

    const plugins_slice = try a.alloc(Plugin.Plugin, plugin_results_slice.len + 1);
    plugins_slice[0] = core_plugin.plugin;
    for (plugin_results_slice, 0..) |pr, i| plugins_slice[i + 1] = pr.plugin;
    const schema: Schema.Schema = .{ .plugins = plugins_slice };

    return .{
        .arena = arena,
        .schema = schema,
        .plugins = plugins_slice,
        .plugin_results = plugin_results_slice,
        .diagnostics = try diags.toOwnedSlice(a),
        .project_source = project_source,
        .project_uri = project_uri,
        .runtime = runtime,
    };
}

/// Pre-flight one project plugin's sidecar and register it with the
/// project runtime, constructing that runtime on first use.
///
/// Mirrors `preflightWasmIfPresent` — the same `declaredWasmExports` set,
/// the same `lastRegisterFailure` diagnostic — with one deliberate
/// difference: a rejected plugin is **kept**. The document path drops it
/// because the document is about to be evaluated against a module the
/// host just refused to instantiate. Project load is the editor's schema,
/// where dropping the plugin would take every form, key and completion in
/// the workspace with it — over a sidecar the author is most likely in
/// the middle of fixing. The diagnostic still fires, and the provider
/// route still reports `unavailable` at each site, so nothing goes quiet.
fn registerProjectPluginWasm(
    gpa: Allocator,
    a: Allocator,
    runtime: *?*PluginRuntime,
    plugin: *const Plugin.Plugin,
    bytes: []const u8,
    manifest_path: []const u8,
    diags: *std.ArrayList(HostDiagnostic),
) Error!void {
    if (comptime !native_plugin_exec) return;

    const declared = try declaredWasmExports(a, plugin);
    defer a.free(declared);

    if (runtime.* == null) {
        const rt = try gpa.create(PluginRuntime);
        errdefer gpa.destroy(rt);
        rt.* = try PluginRuntime.init(gpa);
        runtime.* = rt;
    }
    const rt = runtime.*.?;

    rt.register(gpa, plugin.name, bytes, declared) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        error.Rejected => {
            const failure = rt.lastRegisterFailure();
            // No `(use-plugin …)` reference exists at project-load time,
            // so the manifest path is the only anchor a reader can act
            // on; the span stays zero for the same reason.
            try diags.append(a, .{
                .phase = .manifest,
                .code = failure.code,
                .severity = .err,
                .message = try std.fmt.allocPrint(
                    a,
                    "plugin `{s}` (`{s}`): {s}",
                    .{ plugin.name, manifest_path, failure.detail },
                ),
                .span = .{ .start = 0, .end = 0 },
                .path = &.{},
                .declaration_span = null,
            });
        },
    };
}

/// Preload an external schema once from a set of standalone `(plugin …)`
/// manifest sources (F9). Returns a self-contained `PreloadedSchema` a
/// caller can hand to many `validateDocument` / `evalExpr` calls via
/// `HostOptions.preloaded`, so the schema is parsed and aggregated once
/// rather than re-prepended to (and re-loaded from) every document.
///
/// Each entry in `manifest_sources` must be a single top-level `(plugin …)`
/// form (the `ManifestLoader.load` contract). Never fails on user input:
/// parse failures, load errors, and shape violations become `.manifest`-phase
/// diagnostics, and the offending source contributes no plugin — a partial
/// preload still returns the plugins that loaded cleanly. The five schema
/// aggregate validators (`validateCrossRefs` / `Unions` / `Forms` /
/// `Lowering` / `Defaults`) then run over the loaded set and stamp
/// `.aggregate`.
///
/// No `core` is seeded (user-only, mirroring `HostResult.plugins` /
/// `HostResult.schema`); the document-time pipeline prepends `core` itself.
/// Ownership: the returned bundle is arena-backed and must outlive every
/// `HostResult` that borrows it — see `PreloadedSchema.deinit`.
pub fn preloadSchema(
    gpa: Allocator,
    manifest_sources: []const [:0]const u8,
) Error!PreloadedSchema {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var diags: std.ArrayList(HostDiagnostic) = .empty;
    var plugin_results: std.ArrayList(ManifestLoader.Result) = .empty;
    errdefer for (plugin_results.items) |*pr| pr.deinit();

    for (manifest_sources, 0..) |source, i| {
        try loadManifestSourceInto(
            gpa,
            a,
            source,
            .{ .preload_index = i },
            &plugin_results,
            &diags,
        );
    }

    // Freeze the loaded set into a borrowed view. After `toOwnedSlice` the
    // ArrayList is empty, so re-arm the per-plugin cleanup against the new
    // slice for the aggregate pass below.
    const plugin_results_slice = try plugin_results.toOwnedSlice(a);
    errdefer for (plugin_results_slice) |*pr| pr.deinit();

    const plugins_slice = try a.alloc(Plugin.Plugin, plugin_results_slice.len);
    for (plugin_results_slice, 0..) |pr, i| plugins_slice[i] = pr.plugin;
    const schema: Schema.Schema = .{ .plugins = plugins_slice };

    // Aggregate phase — the same five schema-internal validators the
    // document pipeline runs, over the preloaded (user-only) set. Diagnostics
    // stamp `.aggregate`.
    try runAggregateValidators(gpa, a, schema, &diags);

    return .{
        .arena = arena,
        .plugin_results = plugin_results_slice,
        .plugins = plugins_slice,
        .schema = schema,
        .diagnostics = try diags.toOwnedSlice(a),
    };
}

/// Build `<root>/sjon-project.sjon` (or `<root>sjon-project.sjon` if
/// `root` already ends with `/`). Mirrors the heuristic the legacy
/// SchemaConfig.load used.
fn buildProjectFilePath(a: Allocator, root: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, root);
    if (out.items.len == 0 or out.items[out.items.len - 1] != '/') {
        try out.append(a, '/');
    }
    try out.appendSlice(a, FilesystemResolver.PROJECT_FILE_NAME);
    return out.toOwnedSlice(a);
}

/// Build a `file://`-scheme URI from an absolute filesystem path. No
/// percent-encoding — paths with spaces or non-ASCII bytes pass through
/// as-is. (The LSP transport relies on this matching the URIs it
/// otherwise constructs.)
fn buildFileUri(a: Allocator, abs_path: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "file://");
    if (abs_path.len == 0 or abs_path[0] != '/') {
        try out.append(a, '/');
    }
    try out.appendSlice(a, abs_path);
    return out.toOwnedSlice(a);
}

/// Describes how to anchor the `invalid_manifest` diagnostic emitted when
/// a manifest source fails the `(plugin …)` shape gate (the loader's
/// `NotAPluginManifest`). The message is built lazily — only on that
/// rejection path — so a clean load allocates nothing extra. Each variant
/// names its caller's notion of "which source failed".
const ManifestSourceAnchor = union(enum) {
    /// A project-indexed manifest file, named by its filesystem path.
    project_file: []const u8,
    /// A preloaded manifest source, named by its ordinal in the
    /// `manifest_sources` slice passed to `preloadSchema`.
    preload_index: usize,

    fn notAManifestMessage(self: ManifestSourceAnchor, a: Allocator) Allocator.Error![]const u8 {
        return switch (self) {
            .project_file => |path| std.fmt.allocPrint(
                a,
                "manifest at `{s}` is not a (plugin …) form",
                .{path},
            ),
            .preload_index => |idx| std.fmt.allocPrint(
                a,
                "preloaded manifest source {d} is not a single (plugin …) form",
                .{idx},
            ),
        };
    }
};

/// Parse one out-of-document manifest `source`, run `ManifestLoader.load`,
/// surface parse + load diagnostics (spans local to `source`, phase
/// `.manifest`), and append the loaded `Result` to `plugin_results` when it
/// carries no error-severity diagnostics. `anchor` shapes the
/// `invalid_manifest` message on the `NotAPluginManifest` path. Mirrors the
/// inline-declaration loop in `prepareDocument`, factored so both the
/// project loader and the schema preloader (`preloadSchema`) share one
/// parse→load→wrap→append path. On the drop / clean-append paths `loaded`'s
/// arena is released or adopted; the errdefer covers only the transient
/// load→append window.
fn loadManifestSourceInto(
    gpa: Allocator,
    a: Allocator,
    source: [:0]const u8,
    anchor: ManifestSourceAnchor,
    plugin_results: *std.ArrayList(ManifestLoader.Result),
    diags: *std.ArrayList(HostDiagnostic),
) Allocator.Error!void {
    var manifest_tree = Parser.parse(gpa, source) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    defer manifest_tree.deinit();

    for (manifest_tree.diagnostics) |d| {
        try diags.append(a, try wrapDiagnostic(a, d, .manifest, null));
    }

    var loaded = ManifestLoader.load(gpa, manifest_tree) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        error.NotAPluginManifest => {
            try diags.append(a, .{
                .phase = .manifest,
                .code = .invalid_manifest,
                .severity = .err,
                .message = try anchor.notAManifestMessage(a),
                .span = .{ .start = 0, .end = 0 },
                .path = &.{},
                .declaration_span = null,
            });
            return;
        },
    };

    // Guard the load→append window: `loaded` owns its arena and isn't in
    // `plugin_results.items` yet, so an OOM in the diagnostics loop or the
    // `append` would leak it. The `hasErrors` drop and the successful append
    // both exit normally, discharging this errdefer without firing.
    errdefer loaded.deinit();

    for (loaded.diagnostics) |d| {
        try diags.append(a, try wrapDiagnostic(a, d, .manifest, null));
    }

    if (loaded.hasErrors()) {
        loaded.deinit();
        return;
    }

    try plugin_results.append(a, loaded);
}

/// Parse one project-indexed manifest source and fold it into the schema
/// aggregate. Thin wrapper over `loadManifestSourceInto`, anchored at the
/// manifest's filesystem path.
fn loadProjectPlugin(
    gpa: Allocator,
    a: Allocator,
    entry: FilesystemResolver.ProjectPluginEntry,
    plugin_results: *std.ArrayList(ManifestLoader.Result),
    diags: *std.ArrayList(HostDiagnostic),
) Allocator.Error!void {
    return loadManifestSourceInto(
        gpa,
        a,
        entry.manifest_source,
        .{ .project_file = entry.manifest_path },
        plugin_results,
        diags,
    );
}

const Partition = struct {
    declarations: []const Ast.NodeIndex,
    references: []const Ast.NodeIndex,
    data_forest: []const Ast.NodeIndex,
};

/// Whether a top-level root is a plugin **directive** rather than
/// document data: an unqualified `(plugin …)` declaration or a
/// `(use-plugin …)` reference. Neither is validated against the schema —
/// one *is* a schema, the other names one — so both are lifted out of
/// the forest before the validation walk sees it.
///
/// Public because the LSP has to lift exactly the same two heads from
/// exactly the same position, and the rule must have one definition.
/// `Handler` validates the document forest directly rather than through
/// `validateDocument`, so without this it walks the directives as data
/// and reports `unknown_form` on a header `sjon check` accepts — an
/// editor disagreeing with the build about a file the build says is
/// fine.
pub fn isPluginDirectiveRoot(tree: *const Ast.Tree, idx: Ast.NodeIndex) bool {
    if (tree.tagOf(idx) != .form) return false;
    const hdr = tree.formHeader(idx);
    if (hdr.namespace != null) return false;
    return std.mem.eql(u8, hdr.head, "plugin") or std.mem.eql(u8, hdr.head, "use-plugin");
}

fn partition(a: Allocator, tree: *const Ast.Tree) Allocator.Error!Partition {
    var decls: std.ArrayList(Ast.NodeIndex) = .empty;
    var refs: std.ArrayList(Ast.NodeIndex) = .empty;
    var data: std.ArrayList(Ast.NodeIndex) = .empty;

    for (tree.root) |idx| {
        if (isPluginDirectiveRoot(tree, idx)) {
            // The predicate already established `.form` with no
            // namespace, so the head is one of the two.
            if (std.mem.eql(u8, tree.formHeader(idx).head, "plugin")) {
                try decls.append(a, idx);
            } else {
                try refs.append(a, idx);
            }
            continue;
        }
        try data.append(a, idx);
    }

    return .{
        .declarations = try decls.toOwnedSlice(a),
        .references = try refs.toOwnedSlice(a),
        .data_forest = try data.toOwnedSlice(a),
    };
}

/// Roots of `forest` that did NOT lower this layer — `forest` minus the
/// forms named by `invocations[*].source_form_idx`. The lowered forms are
/// replaced by their emitted forms in the next layer's tree, so they drop
/// out of the validated forest to avoid double-emitting their sugar-schema
/// diagnostics. Result lives on `a`.
fn filterUnloweredRoots(
    a: Allocator,
    forest: []const Ast.NodeIndex,
    invocations: []const Lowering.Invocation,
) Allocator.Error![]const Ast.NodeIndex {
    const filtered = try a.alloc(Ast.NodeIndex, forest.len);
    var n: usize = 0;
    for (forest) |root_idx| {
        var lowered = false;
        for (invocations) |inv| {
            if (inv.source_form_idx == root_idx) {
                lowered = true;
                break;
            }
        }
        if (!lowered) {
            filtered[n] = root_idx;
            n += 1;
        }
    }
    return filtered[0..n];
}

pub fn wrapDiagnostic(
    a: Allocator,
    d: Ast.Diagnostic,
    phase: Phase,
    declaration_span: ?Ast.Span,
) Allocator.Error!HostDiagnostic {
    const path = try Ast.dupePath(a, d.path);
    return .{
        .phase = phase,
        .code = d.code,
        .severity = d.severity,
        .message = try a.dupe(u8, d.message),
        .span = d.span,
        .path = path,
        .declaration_span = declaration_span,
    };
}

/// Owned result of a host eval-expr call. Same lifetime model as
/// `HostResult` — three independent arenas to release in `deinit`:
///   1. each `plugin_results[i].arena` (per-manifest)
///   2. `tree.arena` (parsed source)
///   3. `value_arena` (owns `value` payload, when populated)
///   4. `arena` (host's own — owns partition slices, diagnostics, paths)
///
/// `value` is populated only when the document contains exactly one
/// data-forest form AND there were no err-severity diagnostics from
/// the manifest / aggregate phases AND the evaluator returned a value.
/// Evaluator errors land in `diagnostics` as `.validation`-phase
/// entries (same codes `runEvalPass` emits during `validateDocument`).
pub const HostEvalResult = struct {
    arena: std.heap.ArenaAllocator,
    tree: Ast.Tree,
    plugin_results: []ManifestLoader.Result,
    plugins: []const Plugin.Plugin,
    schema: Schema.Schema,
    diagnostics: []const HostDiagnostic,
    value: ?Expr.Value,
    value_arena: ?std.heap.ArenaAllocator,

    pub fn deinit(self: *HostEvalResult) void {
        if (self.value_arena) |*va| va.deinit();
        for (self.plugin_results) |*pr| pr.deinit();
        self.tree.deinit();
        self.arena.deinit();
    }

    pub fn hasErrors(self: *const HostEvalResult) bool {
        for (self.diagnostics) |d| if (d.severity == .err) return true;
        return false;
    }
};

/// Errors `evalExpr` raises before it even reaches the evaluator. Eval
/// errors themselves become validation-phase diagnostics — they do not
/// propagate out of the function.
pub const EvalExprError = Error || error{
    /// The document parsed but had no data-forest form to evaluate.
    /// Plugin declarations / `(use-plugin …)` references do not count.
    NoExpression,
    /// The document had more than one data-forest form. Callers wanting
    /// to eval a script must pass them one at a time.
    MultipleExpressions,
};

/// Evaluate a single expression against the document's plugin schema.
/// Same prep pipeline as `validateDocument` (parse → partition →
/// declaration loading → resolver → schema aggregate) — then, instead
/// of materializing defaults and re-walking the data forest, pick the
/// single data-forest form and feed it to `Expr.eval` with the
/// aggregated schema. Plugin expr-funcs declared by loaded plugins
/// dispatch through the schema's `lookupExprFunc`, so callers can
/// invoke executable plugin functions (e.g. `(count-done items)`)
/// directly from the host.
///
/// Mirrors `validateDocument`'s diagnostic conventions: parse + manifest
/// loader diagnostics carry `.manifest`, schema-aggregate diagnostics
/// carry `.aggregate`, evaluator runtime failures carry `.validation`.
/// Defaults materialization, lowering, and final-document validation
/// are *not* run — none apply to a single in-flight expression.
pub fn evalExpr(
    gpa: Allocator,
    source: [:0]const u8,
    options: HostOptions,
) EvalExprError!HostEvalResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var diags: std.ArrayList(HostDiagnostic) = .empty;

    // The lazy plugin runtime is owned here and threaded by pointer into
    // `prepareDocument` (which initializes it during wasm preflight) so the
    // eval below dispatches `:impl "wasm:<name>"` calls through the same
    // instance. `runtime_initialized` guards `deinit` to the engine/linker
    // handles we actually created; see `prepareDocument` for the contract.
    var runtime_storage: if (native_plugin_exec) PluginRuntime else void = undefined;
    var runtime_initialized: bool = false;
    defer if (comptime native_plugin_exec) {
        if (runtime_initialized) runtime_storage.deinit(gpa);
    };

    const prepared = try prepareDocument(gpa, a, source, options, &diags, &runtime_storage, &runtime_initialized);
    var tree = prepared.tree;
    errdefer tree.deinit();
    errdefer for (prepared.plugin_results) |*pr| pr.deinit();
    const part = prepared.part;
    const schema = prepared.schema;
    const eval_schema = prepared.eval_schema;
    const plugins_slice = prepared.plugins;
    const plugin_results_slice = prepared.plugin_results;

    // Pick the single data-forest form to evaluate. Pre-eval errors
    // (parse / manifest / aggregate) suppress evaluation — there's no
    // point feeding a value to a broken schema, and we don't want to
    // double-emit the same failure as both schema and runtime.
    if (part.data_forest.len == 0) return error.NoExpression;
    if (part.data_forest.len > 1) return error.MultipleExpressions;
    const expr_idx = part.data_forest[0];

    var has_pre_eval_error = false;
    for (diags.items) |d| if (d.severity == .err) {
        has_pre_eval_error = true;
        break;
    };

    var value: ?Expr.Value = null;
    var value_arena: ?std.heap.ArenaAllocator = null;
    if (!has_pre_eval_error) {
        const empty_env: Expr.Env = .{};
        const runtime_opt: ?*anyopaque = if (comptime native_plugin_exec)
            (if (runtime_initialized) @ptrCast(&runtime_storage) else null)
        else
            null;
        if (Expr.evalWithRuntime(gpa, &tree, expr_idx, &empty_env, eval_schema, runtime_opt)) |result| {
            value = result.value;
            value_arena = result.arena;
        } else |err| {
            switch (err) {
                error.OutOfMemory => return Error.OutOfMemory,
                else => {
                    const head_span: Ast.Span = blk: {
                        if (tree.tagOf(expr_idx) == .form) {
                            break :blk tree.formHeader(expr_idx).head_span;
                        }
                        break :blk .{ .start = 0, .end = 0 };
                    };
                    const head: []const u8 = blk: {
                        if (tree.tagOf(expr_idx) == .form) {
                            break :blk tree.formHeader(expr_idx).head;
                        }
                        break :blk "<expression>";
                    };
                    // Unlike `runEvalPass` this entry point reports every
                    // error it is handed: the caller asked for one
                    // expression's value and got none, so there is nothing
                    // to defer to and no second phase to duplicate.
                    const c = evalErrorCode(err);
                    const message = try formatEvalErrorMessage(a, head, err, c);
                    try diags.append(a, .{
                        .phase = .validation,
                        .code = c,
                        .severity = .err,
                        .message = message,
                        .span = head_span,
                        .path = &.{},
                        .declaration_span = null,
                    });
                },
            }
        }
    }

    return .{
        .arena = arena,
        .tree = tree,
        .plugin_results = plugin_results_slice,
        .plugins = plugins_slice,
        .schema = schema,
        .diagnostics = try diags.toOwnedSlice(a),
        .value = value,
        .value_arena = value_arena,
    };
}

/// The one `Expr.Error` → `Diagnostic.Code` mapping, shared by both
/// evaluation entry points (`evalExpr` and `runEvalPass`) so the two
/// cannot drift. They had: `runEvalPass` mapped only the four
/// `plugin_func_*` codes and dropped every other error on the floor, so
/// `(clamp 5 10 0)` was a diagnostic through `evalExpr` and silence
/// through `validateDocument` — the path `sjon eval`, the playground and
/// the conformance corpus all run.
///
/// *Which* errors an entry point reports is a separate decision (see
/// `runEvalPass`); this only says with what code, once one is reported.
///
/// No variant here needs a `Diagnostic.Code` that does not already
/// exist: the value-domain pair (`TypeMismatch`, `DivisionByZero`) both
/// land on `expr_type_mismatch`, which `evalExpr` has bucketed them into
/// since it was written.
fn evalErrorCode(err: Expr.Error) Ast.Diagnostic.Code {
    return switch (err) {
        // Callers return this rather than diagnosing it — an allocator
        // failure is not a statement about the document.
        error.OutOfMemory => unreachable,
        error.PluginFuncResultType => .plugin_func_result_type,
        error.PluginFuncFailed => .plugin_func_failed,
        error.PluginFuncTrapped => .plugin_func_trapped,
        error.PluginFuncAllocFailed => .plugin_func_alloc_failed,
        error.UnknownFunction => .unknown_form,
        error.AmbiguousFunction => .ambiguous_form,
        error.ArityMismatch => .arity_mismatch,
        error.TypeMismatch => .expr_type_mismatch,
        error.DivisionByZero => .expr_type_mismatch,
        error.UnknownBinding => .unknown_form,
        error.InvalidLetBinding => .expr_type_mismatch,
        error.InvalidCondClause => .expr_type_mismatch,
        error.InvalidBinderShape => .expr_type_mismatch,
        error.KeywordInExpressionArgs => .expr_kvpair_not_allowed,
        // Both evaluation resource ceilings (frame/step depth and the
        // per-call byte budget) surface as `recursion_depth` — the wire
        // code for "eval hit a resource limit". Distinct `Expr.Error`
        // variants, same user-facing bucket.
        error.DepthExceeded => .recursion_depth,
        error.MemoryBudgetExceeded => .recursion_depth,
        error.PluginFuncNotImplemented => .plugin_func_failed,
    };
}

/// The message for a reported `Expr.Error`, keyed on the mapped `code`
/// for the plugin-runtime set (which carries the invoker's structured
/// detail) and on the error itself otherwise.
///
/// The two value-domain errors get wording that names the domain
/// failure instead of the error name, because they are the two an author
/// actually reaches by writing a document that type-checks: `TypeMismatch`
/// is the carrier for an inverted `clamp` range, an out-of-bounds `nth`,
/// a zero-length `normalize`. Rendering that as "TypeMismatch" would
/// point the reader at the declared types, which are fine — it is the
/// computed *values* the function rejected.
fn formatEvalErrorMessage(
    a: Allocator,
    head: []const u8,
    err: Expr.Error,
    code: Ast.Diagnostic.Code,
) Allocator.Error![]const u8 {
    return switch (code) {
        .plugin_func_result_type,
        .plugin_func_failed,
        .plugin_func_trapped,
        .plugin_func_alloc_failed,
        => try formatRuntimeFailureMessage(a, head, code, wasm_plugin_invoker.lastFailure()),
        else => switch (err) {
            error.TypeMismatch => try std.fmt.allocPrint(
                a,
                "`({s} …)` rejected its evaluated arguments: a value is outside the function's domain",
                .{head},
            ),
            error.DivisionByZero => try std.fmt.allocPrint(
                a,
                "division by zero while evaluating `({s} …)`",
                .{head},
            ),
            else => try std.fmt.allocPrint(a, "{s} while evaluating `({s} …)`", .{ @errorName(err), head }),
        },
    };
}

/// True when `diags` already carries an err-severity entry anchored
/// inside `extent`.
///
/// `runEvalPass`'s swallow rule used to *assert* that a validator-phase
/// diagnostic was already on the stream for every error it dropped. This
/// checks instead of asserting, which is what makes the rule true rather
/// than hopeful — the assertion did not hold for the value-domain errors,
/// which by construction have no validator counterpart.
///
/// Containment rather than equality because the two phases anchor
/// differently: the validator at the offending argument (`sqrt/0`), the
/// eval pass at the form's head. An empty diagnostic span is not
/// "anchored inside" anything — it is the synthetic sentinel used where
/// no source position exists — so it never counts as the match.
fn hasErrorWithin(diags: []const HostDiagnostic, extent: Ast.Span) bool {
    std.debug.assert(extent.start <= extent.end);
    for (diags) |d| {
        if (d.severity != .err) continue;
        if (d.span.start == d.span.end) continue;
        if (d.span.start >= extent.start and d.span.end <= extent.end) return true;
    }
    return false;
}

/// Evaluate every top-level form in `data_forest` whose head resolves
/// as an expr-func, reporting evaluation failures through
/// `evalErrorCode`. Two classes stay silent unconditionally — the v1
/// deferral and the two resource ceilings — and the rest report only
/// when the diagnostic stream does not already carry an error anchored
/// inside the same form. Successful results are deep-copied into `a` and
/// appended to `eval_results` so the host can surface them to callers
/// (e.g. conformance value assertions on plugin-exec codec round-trips).
fn runEvalPass(
    a: Allocator,
    gpa: Allocator,
    tree: *const Ast.Tree,
    data_forest: []const Ast.NodeIndex,
    schema: Schema.Schema,
    diags: *std.ArrayList(HostDiagnostic),
    eval_results: *std.ArrayList(EvalResult),
    runtime: ?*anyopaque,
) Error!void {
    const empty_env: Expr.Env = .{};
    // Everything the earlier phases reported. The already-reported check
    // scans this prefix only: entries this loop appends are anchored at
    // *other* top-level forms' heads, and top-level forms do not nest, so
    // they could never be the match — and excluding them keeps the scan
    // from growing with the number of failures already found.
    const pre_eval_len = diags.items.len;
    for (data_forest, 0..) |idx, forest_idx| {
        if (tree.tagOf(idx) != .form) continue;
        const hdr = tree.formHeader(idx);
        const hit = schema.lookupExprFunc(hdr.head, hdr.namespace);
        // `core` is deliberately not seeded into `validateDocument`'s
        // schema (see comment above), so special-form heads
        // (`let`/`if`/`cond`/`and`/`or`/`map`/`filter`/`any`/`all`/`fold`)
        // never resolve via `lookupExprFunc`. Surface them here
        // through the evaluator's hard-coded dispatch so a top-level
        // `(map [x] xs body)` produces a value in
        // `HostResult.evaluated_results` just like plugin-declared
        // expr-funcs do — the safe-expression invariants (pure,
        // bounded, no I/O) make this risk-free at the document
        // boundary.
        if (hit != .found and !Expr.isCoreSpecialForm(hdr.head, hdr.namespace)) continue;

        var result = Expr.evalWithRuntime(gpa, tree, idx, &empty_env, schema, runtime) catch |err| {
            const code: ?Ast.Diagnostic.Code = switch (err) {
                error.OutOfMemory => return Error.OutOfMemory,
                // Plugin-runtime failures report unconditionally. They
                // have no validator counterpart by construction — they
                // describe what the runtime did, not what the document
                // declared — so the duplicate-suppression rule below
                // cannot apply to them, and leaving them ungated keeps
                // this change strictly additive over the corpus.
                error.PluginFuncResultType,
                error.PluginFuncFailed,
                error.PluginFuncTrapped,
                error.PluginFuncAllocFailed,
                => evalErrorCode(err),
                // (b) A v1 deferral: `PluginFuncNotImplemented` on Zig
                // native, or a declared expr-func with neither `impl` nor
                // `wasm_export_name`. The documented "declarative-only on
                // Zig native" stance, not a document error.
                error.PluginFuncNotImplemented => null,
                // (c) An evaluation resource ceiling. A top-level expr too
                // deep or too large to evaluate *during validation* is not
                // itself a document error here — the standalone `evalExpr`
                // entry point still surfaces it as `recursion_depth`.
                //
                // Unreachable in practice as well as by policy:
                // `Expr.MAX_FRAMES` equals `Parser.MAX_PARSE_DEPTH`, so a
                // document deep enough to exhaust the frame stack never
                // parses. Pinned by "the deepest parseable expression
                // still evaluates" in `Host_tests.zig` — if `MAX_FRAMES`
                // is ever lowered this arm goes live, and that test goes
                // red first.
                error.DepthExceeded, error.MemoryBudgetExceeded => null,
                // (a) Everything else. These used to be swallowed whole on
                // the claim that "the validator already emitted the
                // matching diagnostic" — true for `UnknownFunction` /
                // `ArityMismatch`, false for every value-dependent domain
                // failure, which is precisely the class the validator
                // cannot see (it knows the declared types, not the
                // computed values). So `(clamp 5 10 0)`, `(nth [1 2 3] 9)`,
                // `(normalize [0 0])` and `(/ 1 0)` vanished silently.
                // Now the claim is checked rather than assumed: report
                // unless an error is already anchored inside this form.
                else => if (hasErrorWithin(diags.items[0..pre_eval_len], tree.spanOf(idx))) null else evalErrorCode(err),
            };
            if (code) |c| {
                const message = try formatEvalErrorMessage(a, hdr.head, err, c);
                try diags.append(a, .{
                    .phase = .validation,
                    .code = c,
                    .severity = .err,
                    .message = message,
                    .span = hdr.head_span,
                    .path = &.{},
                    .declaration_span = null,
                });
            }
            continue;
        };
        // Deep-copy into the host arena *before* releasing the eval
        // arena — `result.deinit()` invalidates `result.value`'s
        // string/keyword/vector/form storage.
        const cloned = Expr.deepCopyValue(a, result.value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // `result.value` is a Result value already capped to
            // MAX_VALUE_DEPTH by eval's final deepCopyValue, so copying it
            // again cannot exceed the ceiling.
            error.DepthExceeded => unreachable,
        };
        try eval_results.append(a, .{ .forest_index = forest_idx, .value = cloned });
        result.deinit();
    }
}

fn formatRuntimeFailureMessage(
    a: Allocator,
    head: []const u8,
    code: Ast.Diagnostic.Code,
    failure: *const wasm_plugin_invoker.LastFailure,
) Allocator.Error![]const u8 {
    const detail = failure.detail();
    const failure_code = failure.code();
    const prefix: []const u8 = switch (code) {
        .plugin_func_trapped => "plugin function trapped",
        .plugin_func_failed => "plugin function returned a structured failure",
        .plugin_func_result_type => "plugin function result type mismatch",
        .plugin_func_alloc_failed => "plugin function allocation failed",
        else => "plugin function failed",
    };
    if (detail.len > 0 and failure_code.len > 0) {
        return try std.fmt.allocPrint(
            a,
            "{s} in `({s} …)`: [{s}] {s}",
            .{ prefix, head, failure_code, detail },
        );
    }
    if (detail.len > 0) {
        return try std.fmt.allocPrint(
            a,
            "{s} in `({s} …)`: {s}",
            .{ prefix, head, detail },
        );
    }
    return try std.fmt.allocPrint(a, "{s} in `({s} …)`", .{ prefix, head });
}

const freeAggregateDiagnostics = Ast.Diagnostic.freeOwnedSlice;

/// Run the five schema-internal aggregate validators — cross-refs, unions,
/// forms, lowering, defaults — copying each one's gpa-allocated diagnostics
/// into the host arena under `phase = .aggregate` and freeing the backing
/// slice once copied. `validateDocument` and `evalExpr` run exactly this set
/// in exactly this order; the order is corpus-locked (it fixes the
/// aggregate-phase diagnostic-stream sequence), so the list must not be
/// reordered without re-baselining the conformance fixtures.
fn runAggregateValidators(
    gpa: Allocator,
    a: Allocator,
    schema: Schema.Schema,
    diags: *std.ArrayList(HostDiagnostic),
) Error!void {
    inline for (.{
        Schema.Schema.validateCrossRefs,
        Schema.Schema.validateUnions,
        Schema.Schema.validateForms,
        Schema.Schema.validateLowering,
        Schema.Schema.validateDefaults,
    }) |validate| {
        const agg = validate(schema, gpa) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
        };
        defer freeAggregateDiagnostics(gpa, agg);
        for (agg) |d| {
            try diags.append(a, try wrapDiagnostic(a, d, .aggregate, null));
        }
    }
}

/// Wrap a diagnostic whose `span` indexes into a *foreign* source (a
/// resolver-loaded manifest) — re-anchor at the user-document
/// `(use-plugin …)` span so the renderer's `file:line:col` stays
/// honest, and prepend the foreign location info into the message so
/// the user can still navigate to it.
fn wrapForeignDiagnostic(
    a: Allocator,
    d: Ast.Diagnostic,
    reference: Resolver.Reference,
    ref_head_span: Ast.Span,
) Allocator.Error!HostDiagnostic {
    const path = try Ast.dupePath(a, d.path);
    const message = try std.fmt.allocPrint(
        a,
        "in resolved manifest for `(use-plugin \"{s}\" …)` (manifest offset {d}): {s}",
        .{ reference.name, d.span.start, d.message },
    );
    return .{
        .phase = .manifest,
        .code = d.code,
        .severity = d.severity,
        .message = message,
        .span = reference.span,
        .path = path,
        .declaration_span = ref_head_span,
    };
}

/// Wrap a project-file-load diagnostic. Spans index into the project
/// file (or are zero), neither of which match the user document — zero
/// the span so the renderer falls back to "no precise location" and
/// the message remains the source of truth.
fn wrapProjectDiagnostic(
    a: Allocator,
    d: Ast.Diagnostic,
) Allocator.Error!HostDiagnostic {
    const path = try Ast.dupePath(a, d.path);
    return .{
        .phase = .manifest,
        .code = d.code,
        .severity = d.severity,
        .message = try a.dupe(u8, d.message),
        .span = .{ .start = 0, .end = 0 },
        .path = path,
        .declaration_span = null,
    };
}

/// Mirror the inline-manifest declaration loop for a resolver-returned
/// manifest source: parse, run `ManifestLoader.load`, surface diagnostics
/// against the reference's head span, and only contribute the plugin if
/// it loaded cleanly *and* its `:name` matches the reference.
fn loadResolvedManifest(
    gpa: Allocator,
    a: Allocator,
    bytes: []const u8,
    wasm_bytes: ?[]const u8,
    reference: Resolver.Reference,
    ref_head_span: Ast.Span,
    plugin_results: *std.ArrayList(ManifestLoader.Result),
    diags: *std.ArrayList(HostDiagnostic),
) Allocator.Error!void {
    // Parser needs a sentinel-terminated buffer; resolvers return
    // ordinary `[]const u8`. Copy into the host arena.
    const sentinel_buf = try a.allocSentinel(u8, bytes.len, 0);
    @memcpy(sentinel_buf, bytes);

    var manifest_tree = Parser.parse(gpa, sentinel_buf) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    // ManifestLoader.load copies every string + path it surfaces into its
    // own arena, so the parsed tree is safe to release immediately after
    // the load returns regardless of outcome.
    defer manifest_tree.deinit();

    for (manifest_tree.diagnostics) |d| {
        try diags.append(a, try wrapForeignDiagnostic(a, d, reference, ref_head_span));
    }

    var loaded = ManifestLoader.load(gpa, manifest_tree) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        error.NotAPluginManifest => {
            try diags.append(a, .{
                .phase = .manifest,
                .code = .invalid_manifest,
                .severity = .err,
                .message = try std.fmt.allocPrint(
                    a,
                    "manifest for `(use-plugin \"{s}\" …)` is not a (plugin …) form",
                    .{reference.name},
                ),
                .span = reference.span,
                .path = &.{},
                .declaration_span = ref_head_span,
            });
            return;
        },
    };

    // Same unique-ownership window the allocs below already guard: until
    // `loaded` reaches `plugin_results`, an OOM here would drop its arena on
    // the floor. Match this function's manual-catch idiom rather than a
    // top-level errdefer (which would double-free against those guards).
    for (loaded.diagnostics) |d| {
        const wrapped = wrapForeignDiagnostic(a, d, reference, ref_head_span) catch |err| {
            loaded.deinit();
            return err;
        };
        diags.append(a, wrapped) catch |err| {
            loaded.deinit();
            return err;
        };
    }

    if (loaded.hasErrors()) {
        loaded.deinit();
        return;
    }

    if (!std.mem.eql(u8, loaded.plugin.name, reference.name)) {
        // allocPrint can OOM before we hand the plugin's arena off to
        // `plugin_results`; release it eagerly via the inner-block
        // errdefer, then deinit on the success path right before return.
        const mismatch_message = std.fmt.allocPrint(
            a,
            "(use-plugin \"{s}\" …) resolved to a manifest whose :name is `{s}`",
            .{ reference.name, loaded.plugin.name },
        ) catch |err| {
            loaded.deinit();
            return err;
        };
        diags.append(a, .{
            .phase = .manifest,
            .code = .plugin_name_mismatch,
            .severity = .err,
            .message = mismatch_message,
            .span = reference.span,
            .path = &.{},
            .declaration_span = ref_head_span,
        }) catch |err| {
            loaded.deinit();
            return err;
        };
        loaded.deinit();
        return;
    }

    // Enforce the `(use-plugin … :version "x")` pin. Same shape as the
    // :name check above: byte-compare against the manifest's `:version`
    // (captured by `ManifestLoader.buildPlugin`); on mismatch emit a
    // manifest-phase diagnostic at the reference span and drop the
    // loaded plugin. Exact-string match — no semver ranges in v1.
    if (reference.version) |pinned_version| {
        if (!std.mem.eql(u8, loaded.plugin.version, pinned_version)) {
            const mismatch_message = std.fmt.allocPrint(
                a,
                "(use-plugin \"{s}\" :version \"{s}\") pin differs from manifest :version `{s}`",
                .{ reference.name, pinned_version, loaded.plugin.version },
            ) catch |err| {
                loaded.deinit();
                return err;
            };
            diags.append(a, .{
                .phase = .manifest,
                .code = .plugin_version_mismatch,
                .severity = .err,
                .message = mismatch_message,
                .span = reference.span,
                .path = &.{},
                .declaration_span = ref_head_span,
            }) catch |err| {
                loaded.deinit();
                return err;
            };
            loaded.deinit();
            return;
        }
    }

    // Verify the manifest's `:wasm-sha256` self-stamp (author's claim)
    // against the bytes the resolver actually returned. Distinct from
    // the consumer-side `(use-plugin … :hash …)` pin enforced upstream
    // in `enforceHashPin`. Both can co-exist; when they agree, the
    // chain author→consumer→observed is tight.
    if (loaded.plugin.wasm_sha256) |stamp| {
        if (wasm_bytes) |bytes_for_hash| {
            const expected_bytes = Sha256Pin.parse(stamp);
            if (expected_bytes) |expected| {
                var actual_bytes: [Sha256.digest_length]u8 = undefined;
                Sha256.hash(bytes_for_hash, &actual_bytes, .{});
                if (!std.mem.eql(u8, &expected, &actual_bytes)) {
                    const actual_hex = std.fmt.bytesToHex(actual_bytes, .lower);
                    diags.append(a, .{
                        .phase = .manifest,
                        .code = .plugin_wasm_self_hash_mismatch,
                        .severity = .err,
                        .message = std.fmt.allocPrint(
                            a,
                            "manifest `:wasm-sha256 {s}` does not match wasm bytes (actual `sha256-{s}`)",
                            .{ stamp, actual_hex },
                        ) catch |err| {
                            loaded.deinit();
                            return err;
                        },
                        .span = reference.span,
                        .path = &.{},
                        .declaration_span = ref_head_span,
                    }) catch |err| {
                        loaded.deinit();
                        return err;
                    };
                    loaded.deinit();
                    return;
                }
            }
            // Malformed pins are caught at manifest load time by
            // `plugin_wasm_self_hash_malformed`; no need to repeat here.
        }
    }

    // Until `append` returns, `loaded` is unique-owned by this call;
    // an OOM here would otherwise drop its arena on the floor.
    plugin_results.append(a, loaded) catch |err| {
        loaded.deinit();
        return err;
    };
}

const Sha256 = std.crypto.hash.sha2.Sha256;

/// Enforce `(use-plugin … :hash "sha256-<64 hex>")` against the
/// resolved wasm bytes. Returns true (and appends a manifest-phase
/// `plugin_hash_mismatch` diagnostic) when:
///   * the pin is malformed (wrong prefix, wrong length, non-lowercase
///     hex);
///   * the manifest carries no wasm bytes to hash;
///   * the SHA-256 of the wasm bytes differs from the pin.
/// Returns false when no pin is set or the pin matches. Strict
/// lowercase-hex enforcement keeps the pin canonical so reproducibility
/// audits don't bikeshed casing.
fn enforceHashPin(
    a: Allocator,
    ref: Resolver.Reference,
    ref_head_span: Ast.Span,
    m: Resolver.ManifestResolution,
    diags: *std.ArrayList(HostDiagnostic),
) Allocator.Error!bool {
    const pin = ref.hash orelse return false;

    const expected_bytes = Sha256Pin.parse(pin) orelse {
        try diags.append(a, .{
            .phase = .manifest,
            .code = .plugin_hash_mismatch,
            .severity = .err,
            .message = try std.fmt.allocPrint(
                a,
                "(use-plugin \"{s}\" :hash \"{s}\") pin is malformed; expected `sha256-<64 lowercase hex chars>`",
                .{ ref.name, pin },
            ),
            .span = ref.span,
            .path = &.{},
            .declaration_span = ref_head_span,
        });
        return true;
    };

    const wasm_bytes = m.wasm orelse {
        try diags.append(a, .{
            .phase = .manifest,
            .code = .plugin_hash_mismatch,
            .severity = .err,
            .message = try std.fmt.allocPrint(
                a,
                "(use-plugin \"{s}\" :hash \"{s}\") pin set but the resolved manifest has no wasm to hash",
                .{ ref.name, pin },
            ),
            .span = ref.span,
            .path = &.{},
            .declaration_span = ref_head_span,
        });
        return true;
    };

    var actual_bytes: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(wasm_bytes, &actual_bytes, .{});

    if (!std.mem.eql(u8, &expected_bytes, &actual_bytes)) {
        const actual_hex = std.fmt.bytesToHex(actual_bytes, .lower);
        try diags.append(a, .{
            .phase = .manifest,
            .code = .plugin_hash_mismatch,
            .severity = .err,
            .message = try std.fmt.allocPrint(
                a,
                "(use-plugin \"{s}\" :hash \"{s}\") pin does not match wasm bytes (actual `sha256-{s}`)",
                .{ ref.name, pin, actual_hex },
            ),
            .span = ref.span,
            .path = &.{},
            .declaration_span = ref_head_span,
        });
        return true;
    }

    return false;
}

/// Native pre-flight + instance registration for a wasm-bearing
/// manifest. Mirrors `hosts/rust/src/wasm.rs:preflight_and_register`
/// and `hosts/web/SjonHost.ts`'s `handleResolve` callback — same spec
/// §16 ordering, same `(code, path)` diagnostic taxonomy. Runs on the
/// successful-load arm of the `(use-plugin …)` resolver loop, right
/// after `enforceHashPin` and the duplicate-name dedupe.
///
/// Returns `true` when pre-flight rejected the plugin (caller should
/// `continue` the resolver loop — the plugin was popped from
/// `plugin_results` and a diagnostic was appended), `false` when the
/// plugin is fit to stay registered for `runEvalPass` to dispatch
/// into.
///
/// On `plugin_exec=false` or wasm32 targets, this is a comptime no-op
/// that returns `false` without touching the runtime — the historical
/// "declarative-only" behavior is preserved.
/// Every `wasm:<export>` name a plugin declares, across both catalogs
/// that can declare one. Spec §16 pre-flight verifies each is genuinely
/// exported by the sidecar module before the plugin loads.
///
/// Undiscriminated on purpose: a cross-ref provider call *is* an ordinary
/// plugin call, so "does this export exist" is one question for both
/// catalogs, and an expr-func and a provider naming the same export
/// coalesce here — legal when deliberate, with the per-catalog
/// result-shape checks downstream as the backstop when it isn't. The Web
/// and Rust hosts enumerate the same two catalogs out of
/// `sjon_manifest_meta`'s payload; keep the three in step.
///
/// Split out of `preflightWasmIfPresent` so the enumeration is testable
/// on builds without `-Dplugin-exec`, where pre-flight itself compiles
/// out. Caller owns the returned slice.
pub fn declaredWasmExports(a: Allocator, plugin: *const Plugin.Plugin) Error![][]const u8 {
    var declared: std.ArrayList([]const u8) = .empty;
    errdefer declared.deinit(a);
    for (plugin.expr_funcs) |func| {
        if (func.wasm_export_name) |name| try declared.append(a, name);
    }
    for (plugin.cross_ref_providers) |provider| {
        if (provider.wasm_export_name) |name| try declared.append(a, name);
    }
    return declared.toOwnedSlice(a);
}

test "declaredWasmExports enumerates both catalogs, and skips what declares no export" {
    const gpa = std.testing.allocator;
    const plugin: Plugin.Plugin = .{
        .name = "glsl",
        .expr_funcs = &.{
            .{ .name = "double", .wasm_export_name = "double" },
            // Declarative-only: nothing to pre-flight.
            .{ .name = "describe" },
        },
        .cross_ref_providers = &.{
            .{ .name = "lines", .wasm_export_name = "extract_lines" },
            // Native `:impl` (or none at all) reaches no export either.
            .{ .name = "native" },
        },
    };

    const declared = try declaredWasmExports(gpa, &plugin);
    defer gpa.free(declared);

    try std.testing.expectEqual(@as(usize, 2), declared.len);
    try std.testing.expectEqualStrings("double", declared[0]);
    try std.testing.expectEqualStrings("extract_lines", declared[1]);
}

fn preflightWasmIfPresent(
    a: Allocator,
    gpa: Allocator,
    plugin_results: *std.ArrayList(ManifestLoader.Result),
    diags: *std.ArrayList(HostDiagnostic),
    ref: Resolver.Reference,
    ref_head_span: Ast.Span,
    m: Resolver.ManifestResolution,
    runtime_storage: anytype,
    runtime_initialized: *bool,
) Error!bool {
    if (comptime !native_plugin_exec) return false;

    const bytes = m.wasm orelse return false;

    // Walk the just-loaded plugin for `:impl "wasm:<name>"` exports.
    // The plugin sits at the top of `plugin_results` because the loop
    // above appended it just before calling us.
    const loaded_idx = plugin_results.items.len - 1;
    const loaded_plugin = &plugin_results.items[loaded_idx].plugin;

    const declared = try declaredWasmExports(a, loaded_plugin);
    defer a.free(declared);
    // We pre-flight even when the manifest has zero `:impl "wasm:<name>"`
    // exports: spec §16 says the host MUST verify ABI version + required
    // exports + import-emptiness whenever the resolver returns wasm
    // bytes. The `plugin-exec-abi-mismatch` corpus case asserts this
    // (the manifest has no `wasm:` impls but the sibling `.wasm`
    // reports ABI 99 — pre-flight is what surfaces the failure).

    if (!runtime_initialized.*) {
        runtime_storage.* = try PluginRuntime.init(gpa);
        runtime_initialized.* = true;
    }

    runtime_storage.register(gpa, loaded_plugin.name, bytes, declared) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        error.Rejected => {
            const failure = runtime_storage.lastRegisterFailure();
            try diags.append(a, .{
                .phase = .manifest,
                .code = failure.code,
                .severity = .err,
                // Dupe out of the runtime's arena (which outlives this
                // call but stays opaque to callers) into the host arena
                // (which is what HostResult.diagnostics borrows from).
                .message = try a.dupe(u8, failure.detail),
                .span = ref.span,
                .path = &.{},
                .declaration_span = ref_head_span,
            });
            var popped = plugin_results.pop().?;
            popped.deinit();
            return true;
        },
    };
    return false;
}

// ---------------------------------------------------------------------------
// Schema export — convenience wrappers around `SchemaExport.exportSchema`.
//
// `exportSchema` is the lowest-level entry: caller already holds a
// `Schema.Schema` (e.g. from `HostResult.schema` or `LoadedProject.schema`)
// and just wants the artifacts.
//
// `exportSchemaFromSource` mirrors `validateDocument`'s pipeline so a
// caller can hand it a source string and receive both the validation
// result and the export bundle in one call. Useful for the CLI and for
// any host that wants to render aggregate diagnostics alongside the
// export warnings.
// ---------------------------------------------------------------------------

/// Pure export: walk a pre-built `Schema.Schema` and produce the
/// requested artifacts. Caller owns the returned `ExportResult` and
/// must call `deinit()` exactly once.
pub fn exportSchema(
    gpa: Allocator,
    schema: Schema.Schema,
    options: SchemaExport.ExportOptions,
) SchemaExport.Error!SchemaExport.ExportResult {
    return try SchemaExport.exportSchema(gpa, schema, options);
}

/// Owned result of `exportSchemaFromSource` — holds the
/// `validateDocument` output plus the export. Caller owns both arenas
/// and must call `deinit()` exactly once.
pub const ExportSchemaBundle = struct {
    host_result: HostResult,
    export_result: SchemaExport.ExportResult,

    pub fn deinit(self: *ExportSchemaBundle) void {
        self.export_result.deinit();
        self.host_result.deinit();
    }

    pub fn hasErrors(self: *const ExportSchemaBundle) bool {
        return self.host_result.hasErrors() or self.export_result.hasErrors();
    }
};

/// Parse + load + aggregate (via `validateDocument`) and then export
/// the resulting schema. Aggregate diagnostics flow onto
/// `bundle.host_result.diagnostics`; export warnings onto
/// `bundle.export_result.warnings`. Caller chooses whether to treat
/// either set as fatal.
pub fn exportSchemaFromSource(
    gpa: Allocator,
    source: [:0]const u8,
    host_options: HostOptions,
    export_options: SchemaExport.ExportOptions,
) (Error || SchemaExport.Error)!ExportSchemaBundle {
    var host_result = try validateDocument(gpa, source, host_options);
    errdefer host_result.deinit();
    const export_result = try SchemaExport.exportSchema(gpa, host_result.schema, export_options);
    return .{ .host_result = host_result, .export_result = export_result };
}

/// Owned result of `exportLoweringGraphFromSource` — the
/// `validateDocument` output (so callers can surface aggregate
/// diagnostics, e.g. `lowering_cycle`) plus the rendered graph bytes.
/// Caller owns it and must call `deinit()` exactly once.
pub const LoweringGraphBundle = struct {
    host_result: HostResult,
    /// `(lowering-graph …)` SJON, owned by `gpa`.
    sjon: []u8,
    gpa: Allocator,

    pub fn deinit(self: *LoweringGraphBundle) void {
        self.gpa.free(self.sjon);
        self.host_result.deinit();
    }

    pub fn hasErrors(self: *const LoweringGraphBundle) bool {
        return self.host_result.hasErrors();
    }
};

/// Parse + load + aggregate (via `validateDocument`) and render the
/// resulting schema's lowering produces-graph as SJON. The graph is
/// derived from the aggregate even when the document carries no lowering
/// registry — it is a static artifact of the loaded plugins, not of a
/// runtime pass. Aggregate diagnostics (including `lowering_cycle`) flow
/// onto `bundle.host_result.diagnostics`; the graph still renders so a
/// cyclic graph is visible rather than hidden behind an abort.
pub fn exportLoweringGraphFromSource(
    gpa: Allocator,
    source: [:0]const u8,
    host_options: HostOptions,
) (Error || LoweringGraph.Error)!LoweringGraphBundle {
    var host_result = try validateDocument(gpa, source, host_options);
    errdefer host_result.deinit();
    const sjon = try LoweringGraph.render(gpa, host_result.schema);
    return .{ .host_result = host_result, .sjon = sjon, .gpa = gpa };
}

/// The identity slice of a plugin manifest a host needs before a full
/// load: the plugin's own `:name` and every `:impl "wasm:<export>"`
/// export name it declares, across both catalogs that can declare one.
/// All slices are owned by the `a` arena the caller passes.
///
/// Replaces the per-host manifest scrapers (the web regex and the Rust
/// byte-walker), which anchored on the FIRST `:name` in *source order*
/// and so mis-extracted a nested `(expr-func :name … )` that precedes
/// the plugin's own `:name` — a silent misname of the plugin pool key
/// on otherwise valid manifests. A structural walk cannot be fooled that
/// way.
pub const ManifestMeta = struct {
    /// The plugin `:name`, or null when `source` is not a well-formed
    /// `(plugin …)` manifest carrying a `:name` — there is then no key to
    /// pool the plugin under, and the loader re-derives the canonical
    /// `invalid_manifest` diagnostic from the bytes downstream.
    name: ?[]const u8,
    /// Every declared `:impl "wasm:<export>"` name, expr-funcs first and
    /// then cross-ref providers, each in declaration order.
    ///
    /// Undiscriminated: it is the list a host pre-flights, and pre-flight
    /// asks one question — does the module export this? A consumer that
    /// ever needs per-catalog prose would grow a field here and on two
    /// hosts, which is a decision for then rather than a shape to carry
    /// speculatively.
    wasm_impls: []const []const u8,
};

/// Peek a manifest `source`'s `ManifestMeta` by structural walk — parse,
/// `ManifestLoader.load`, then read `plugin.name` + every declared
/// `wasm_export_name`. `gpa` backs the transient parse/load (freed before
/// returning); the returned slices are owned by `a`.
pub fn manifestMeta(gpa: Allocator, a: Allocator, source: []const u8) Error!ManifestMeta {
    const empty: ManifestMeta = .{ .name = null, .wasm_impls = &.{} };

    const src = try gpa.dupeZ(u8, source);
    defer gpa.free(src);

    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();

    var loaded = ManifestLoader.load(gpa, tree) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        // Root isn't a single `(plugin …)` form: no name to surface.
        error.NotAPluginManifest => return empty,
    };
    defer loaded.deinit();

    // A manifest that fails meta-validation carries an empty `name` and no
    // built plugin; treat as "no usable name", matching the scrapers'
    // null-on-absent contract. Structural (non-fatal) diagnostics still
    // leave the name populated — surface it, exactly as the scrapers did.
    if (loaded.plugin.name.len == 0) return empty;

    const name = try a.dupe(u8, loaded.plugin.name);
    // Through the same enumeration `preflightWasmIfPresent` uses, so the
    // native pre-flight and the two host-side ones cannot drift on which
    // catalogs count. The names borrow `loaded`, which dies at return.
    const declared = try declaredWasmExports(a, &loaded.plugin);
    defer a.free(declared);
    var impls: std.ArrayList([]const u8) = .empty;
    try impls.ensureTotalCapacity(a, declared.len);
    for (declared) |w| impls.appendAssumeCapacity(try a.dupe(u8, w));
    return .{ .name = name, .wasm_impls = try impls.toOwnedSlice(a) };
}

test "Host.exportLoweringGraphFromSource renders the produces-graph from source" {
    const a = std.testing.allocator;
    const src =
        \\(plugin :name g :version "1.0.0"
        \\  (form :name a :open true
        \\    :lowering (lowering :hook g/a-v1 :produces [b]))
        \\  (form :name b :open true))
        \\(a)
    ;
    var bundle = try exportLoweringGraphFromSource(a, src, .{});
    defer bundle.deinit();
    try std.testing.expect(std.mem.indexOf(u8, bundle.sjon, "(node :form \"g/a\" :produces [\"g/b\"])") != null);
}

test "Host.exportSchema mirrors SchemaExport.exportSchema on a static plugin" {
    const a = std.testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "smoke",
        .forms = &.{.{ .name = "row", .keys = &.{.{ .name = "n", .value_type = .number }} }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try exportSchema(a, schema, .{});
    defer result.deinit();
    try std.testing.expect(result.json_schema_bytes != null);
    try std.testing.expect(result.ts_types_bytes != null);
    try std.testing.expect(std.mem.indexOf(u8, result.json_schema_bytes.?, "form.smoke.row") != null);
}

test "Host.exportSchemaFromSource loads inline plugin + exports its schema" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\(plugin :name greet :version "1.0"
        \\  (form :name hello
        \\    (key :name who :type string)))
    ;
    var bundle = try exportSchemaFromSource(a, src, .{}, .{});
    defer bundle.deinit();
    // The greet plugin loaded without errors.
    try std.testing.expect(!bundle.host_result.hasErrors());
    try std.testing.expect(bundle.export_result.json_schema_bytes != null);
    try std.testing.expect(std.mem.indexOf(u8, bundle.export_result.json_schema_bytes.?, "form.greet.hello") != null);
}

// ---------------------------------------------------------------------------
// preloadSchema (F9) — two-phase schema construction. Load a set of
// standalone `(plugin …)` manifest sources once into an arena-owned,
// self-contained `PreloadedSchema`; later `validateDocument` calls borrow it
// via `HostOptions.preloaded` (commit 3). Never fails on user input — parse /
// load failures become `.manifest`-phase diagnostics and the offending source
// contributes no plugin. The five aggregate validators run over the loaded set
// and stamp `.aggregate`. No `core` is seeded (user-only, mirroring
// `HostResult.plugins`).
// ---------------------------------------------------------------------------

test "preloadSchema: clean multi-source preload aggregates every plugin, no core" {
    const a = std.testing.allocator;
    const sources = [_][:0]const u8{
        "(plugin :name shapes :version \"1.0.0\")",
        "(plugin :name colors :version \"2.0.0\")",
    };
    var pre = try preloadSchema(a, &sources);
    defer pre.deinit();

    try std.testing.expectEqual(@as(usize, 0), pre.diagnostics.len);
    try std.testing.expect(!pre.hasErrors());
    // No core seeded: plugins are exactly the loaded user manifests, in order.
    try std.testing.expectEqual(@as(usize, 2), pre.plugins.len);
    try std.testing.expectEqual(@as(usize, 2), pre.plugin_results.len);
    try std.testing.expectEqualStrings("shapes", pre.plugins[0].name);
    try std.testing.expectEqualStrings("colors", pre.plugins[1].name);
    // The public schema is a pure aggregate over the same borrowed slice.
    try std.testing.expectEqual(pre.plugins.ptr, pre.schema.plugins.ptr);
    // Borrowed view: plugins[i] aliases plugin_results[i].plugin.
    try std.testing.expectEqualStrings(pre.plugin_results[0].plugin.name, pre.plugins[0].name);
}

test "preloadSchema: a source with load errors contributes diagnostics and no plugin" {
    const a = std.testing.allocator;
    const sources = [_][:0]const u8{
        "(plugin :name ok :version \"1.0.0\")",
        // `:underlying string` under a `:cross-ref` is a load-time
        // wrong_underlying (err); the whole source is dropped.
        \\(plugin :name broken :version "1.0.0"
        \\  (value-kind :name bogus
        \\    :underlying string
        \\    :cross-ref (cross-ref :target phrase)))
        ,
    };
    var pre = try preloadSchema(a, &sources);
    defer pre.deinit();

    // The good plugin still loads; the broken source contributes none.
    try std.testing.expectEqual(@as(usize, 1), pre.plugins.len);
    try std.testing.expectEqualStrings("ok", pre.plugins[0].name);
    try std.testing.expect(pre.hasErrors());
    var saw_wrong_underlying = false;
    for (pre.diagnostics) |d| {
        if (d.code == .wrong_underlying) saw_wrong_underlying = true;
        // Every load-phase diagnostic is stamped `.manifest`.
        try std.testing.expectEqual(Phase.manifest, d.phase);
    }
    try std.testing.expect(saw_wrong_underlying);
}

test "preloadSchema: a source violating the single-(plugin) contract is invalid_manifest" {
    const a = std.testing.allocator;
    // Two top-level roots pass per-root meta-validation but fail the
    // loader's single-root shape gate (`root.len != 1` →
    // NotAPluginManifest) — the reliable trigger for the anchor's
    // invalid_manifest message. Contributes no plugin.
    const sources = [_][:0]const u8{
        \\(plugin :name a :version "1.0.0")
        \\(plugin :name b :version "1.0.0")
        ,
    };
    var pre = try preloadSchema(a, &sources);
    defer pre.deinit();

    try std.testing.expectEqual(@as(usize, 0), pre.plugins.len);
    try std.testing.expectEqual(@as(usize, 1), pre.diagnostics.len);
    try std.testing.expectEqual(Ast.Diagnostic.Code.invalid_manifest, pre.diagnostics[0].code);
    try std.testing.expectEqual(Phase.manifest, pre.diagnostics[0].phase);
    try std.testing.expect(pre.hasErrors());
}

test "preloadSchema: aggregate validators run over the combined preloaded set" {
    const a = std.testing.allocator;
    const sources = [_][:0]const u8{
        // Loads cleanly (symbol underlying is valid for cross-ref), but its
        // `:target ghost` resolves to no form in the aggregate → an
        // .aggregate-phase unknown_cross_ref_target.
        \\(plugin :name dangler :version "1.0.0"
        \\  (value-kind :name ref-kind
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :target ghost)))
        ,
        "(plugin :name bystander :version \"1.0.0\")",
    };
    var pre = try preloadSchema(a, &sources);
    defer pre.deinit();

    // Both manifests load cleanly — the failure is schema-internal, not a load error.
    try std.testing.expectEqual(@as(usize, 2), pre.plugins.len);
    var saw_dangling = false;
    for (pre.diagnostics) |d| {
        if (d.code == .unknown_cross_ref_target) {
            saw_dangling = true;
            try std.testing.expectEqual(Phase.aggregate, d.phase);
        }
    }
    try std.testing.expect(saw_dangling);
}

test "preloadSchema: empty source list is a clean, empty preload" {
    const a = std.testing.allocator;
    const sources = [_][:0]const u8{};
    var pre = try preloadSchema(a, &sources);
    defer pre.deinit();

    try std.testing.expectEqual(@as(usize, 0), pre.plugins.len);
    try std.testing.expectEqual(@as(usize, 0), pre.plugin_results.len);
    try std.testing.expectEqual(@as(usize, 0), pre.diagnostics.len);
    try std.testing.expect(!pre.hasErrors());
}

test "Host.manifestMeta reads the plugin's own :name past a leading nested (expr-func :name …) (A.2)" {
    const a = std.testing.allocator;
    // A perfectly valid manifest whose first positional child is an
    // `(expr-func :name boom …)`. The retired per-host scrapers (JS regex
    // / Rust byte-walker) both anchored on the FIRST `:name` in source
    // order and returned `boom`; the structural walk returns the plugin's
    // own `:name real`, and the expr-func's `:impl "wasm:boom_impl"`.
    const src =
        \\(plugin
        \\  (expr-func :name boom
        \\    :arity (fixed 1)
        \\    :params [number]
        \\    :result number
        \\    :impl "wasm:boom_impl")
        \\  :name real
        \\  :version "1.0.0")
    ;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const meta = try manifestMeta(a, arena.allocator(), src);
    try std.testing.expect(meta.name != null);
    try std.testing.expectEqualStrings("real", meta.name.?);
    try std.testing.expectEqual(@as(usize, 1), meta.wasm_impls.len);
    try std.testing.expectEqualStrings("boom_impl", meta.wasm_impls[0]);
}

test "Host.manifestMeta surfaces cross-ref provider exports alongside expr-func ones" {
    const a = std.testing.allocator;
    // What a host pre-flights: both catalogs, expr-funcs first. A
    // provider whose export the module lacks has to fail the load the
    // same way an expr-func's would — the alternative is a failed
    // extraction at validate time, which reads like a document problem
    // rather than a packaging one.
    const src =
        \\(plugin :name glsl :version "1.0.0" :sjon "1.2"
        \\  (expr-func :name double
        \\    :arity (fixed 1)
        \\    :params [number]
        \\    :result number
        \\    :impl "wasm:double_impl")
        \\  (cross-ref-provider :name lines
        \\    :description "one name per line"
        \\    :impl "wasm:extract_lines"))
    ;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const meta = try manifestMeta(a, arena.allocator(), src);
    try std.testing.expectEqualStrings("glsl", meta.name.?);
    try std.testing.expectEqual(@as(usize, 2), meta.wasm_impls.len);
    try std.testing.expectEqualStrings("double_impl", meta.wasm_impls[0]);
    try std.testing.expectEqualStrings("extract_lines", meta.wasm_impls[1]);
}

test "Host.manifestMeta returns a null name for a non-manifest source (A.2)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // Not a `(plugin …)` root: nothing to key the plugin pool on. The
    // scrapers returned null here too (the loader re-derives
    // invalid_manifest from the bytes downstream).
    const meta = try manifestMeta(a, arena.allocator(), "(not-a-plugin :x 1)");
    try std.testing.expect(meta.name == null);
    try std.testing.expectEqual(@as(usize, 0), meta.wasm_impls.len);
}
