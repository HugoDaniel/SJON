//! SJON — deterministic S-expression data + optional safe expressions.
//!
//! Public API. Each function manages memory via an internal arena: every
//! intermediate allocation (tokens, AST nodes, diagnostics, …) is bulk-freed
//! when the caller calls `result.deinit()`.
//!
//! Memory model — one convention. Every public function that allocates
//! returns an owned struct with `.deinit()`. The struct is one of:
//! `Ast.Tree`, `Ast.Bytes`, `Validator.Result`, `Json.Result`, or
//! `Expr.Result`. None of them require the caller to remember which
//! allocator was used — `.deinit()` is self-contained.
//!
//! Bind these with `var` because four of the five hold an
//! `ArenaAllocator` whose `deinit` requires a mutable receiver:
//!
//! ```zig
//! var tree = try sjon.parse(gpa, src);
//! defer tree.deinit();
//! ```
//!
//! `Ast.Bytes` is the lone exception — its `deinit` is `*const` because
//! it only frees a single `gpa.free(self.data)` call. `var` works for
//! it too, so the uniform `var x = try …; defer x.deinit();` pattern
//! is correct for all five.
//!
//! The `Host` façade (`validateDocument`, `evalExpr`, `loadProject`,
//! `preloadSchema`) layers its own owned results — `HostResult`,
//! `HostEvalResult`, `LoadedProject`, `PreloadedSchema` — on the same
//! arena-backed `.deinit()` model. `PreloadedSchema` is additionally
//! *borrowed*: it must outlive each `HostResult` that composes it, and a
//! result's `deinit` never touches the preloaded arenas.
//!
//! A second tier exists, deliberately, and reading only the paragraph
//! above will mislead you about it. Some results take the allocator
//! back: `deinit(self, gpa)` rather than `deinit(self)` —
//! `Validator.ForestResult`, `Lowering.PassResult`,
//! `MaterializedDefaults.Result`. The tell is uniform: those structs
//! hold something no arena owns, because a *caller* is going to take it.
//! `ForestResult` hands out per-document `Result`s the LSP frees
//! independently; the two aggregate passes hand out individually-owned
//! diagnostics the host copies into its own arena and then drops. Use
//! this tier only when a result's parts genuinely outlive it
//! separately — otherwise an arena and a self-contained `deinit` is the
//! answer, and the gpa parameter is a way for a caller to pass the wrong
//! allocator. `Ast.Diagnostic.appendOwned` / `freeOwnedSlice` are the
//! shared emit/release pair for the diagnostic half of it.
//!
//! The same fork appears in service objects, and the `deinit` signature
//! decides it there too. `FilesystemResolver` owns an arena and nothing
//! else, so its `deinit` is self-contained and it stores `gpa` as a
//! field. `PluginRuntime` owns gpa-keyed instance maps, so its `deinit`
//! takes `gpa` and every method threads it. New modules: pick by asking
//! which `deinit` you need, not by preference — storing `gpa` next to a
//! `deinit(self, gpa)` is how a struct ends up with two allocators that
//! are only equal by convention.
//!
//! Iteration — three disciplines, one per shape. A reader who has
//! internalised one should not assume the next module follows it:
//!
//! - **Cursors** (`BinaryCursor`) — single-pass state machine. Every
//!   `next()` is paired with exactly one `read*` or `skipBody`; the
//!   pairing is the contract, runtime-unenforced.
//! - **Builders** (`Ast.TreeBuilder`) — order-independent appenders.
//!   `addString`, `addForm`, `addVector`, `addKvpair`, `appendNode`,
//!   `cloneNode` may be called in any order; the accumulated tree
//!   is the result.
//! - **Walkers** (`Validator`, `Expr`) — internal frame-stack loops
//!   that push-process-pop. Bounded depth (`MAX_VALIDATE_FRAMES`,
//!   `MAX_EVAL_DEPTH`); descent never uses the host stack.
//!
//! Recursion outside these walkers is allowed only under a named,
//! already-enforced depth ceiling — see the bounded-recursion
//! carve-out in `docs/zig-discipline.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Semantic version string for this build of SJON. Bumped on each release.
/// Defined in `version.zig` so the read-only `wasm_binary.zig` artifact
/// can reference it without pulling in `root.zig`.
pub const version = @import("version.zig").string;

/// Single-pass labeled-switch tokenizer over `[:0]const u8` source.
pub const Lexer = @import("Lexer.zig");
/// Calendar-date primitive — packed `(year:i16, month:u8, day:u8)`.
pub const Date = @import("Date.zig");
/// Clock-time primitive — `(hour, minute, second, millisecond)`.
pub const Time = @import("Time.zig");
/// Pattern time core — shared `i64` tick grid (`PPC`, `Span`, checked
/// arithmetic) for pattern/driver/audio engines. Pure `std`-only.
pub const Pattern = @import("Pattern.zig");
/// Deterministic Strudel-style pattern query engine — interprets pattern
/// data as `query(window) -> [Hap]` on the `Pattern` tick grid. Hap value
/// vocabulary + hand-rolled `(haps …)` serializer here; engine + decoders
/// in following commits.
pub const PatternQuery = @import("PatternQuery.zig");
/// Deterministic pure-f64 math kernels (vendored musl): `sin64`/`cos64`/
/// `tan64`/`exp64`/`log64`/`pow64`. Bit-identical native vs wasm32 —
/// downstream packages (animation driver easings, audio envelopes) use
/// these instead of `@sin`/`@exp` builtins, which lower to platform libm.
pub const trig = @import("trig.zig");
/// AST node types and the `Tree` container produced by the parser.
pub const Ast = @import("Ast.zig");
/// Iterative-descent parser: source → `Ast.Tree` (SoA).
pub const Parser = @import("Parser.zig");
/// Canonical / full printer over `Ast.Tree`.
pub const Printer = @import("Printer.zig");
/// Plugin descriptors (`Plugin`, `FormSpec`, `ExprFunc`, …) used by schemas.
pub const Plugin = @import("Plugin.zig");
/// Comptime aggregator over one or more `Plugin` descriptors.
pub const Schema = @import("Schema.zig");
/// Tree × schema → diagnostics walker.
pub const Validator = @import("Validator.zig");
/// Safe-expression evaluator (closed v1 vocabulary).
pub const Expr = @import("Expr.zig");
/// JSON bridge: `Tree ↔ std.json.Value` with a tagged-object encoding.
pub const Json = @import("Json.zig");
/// Structural-edit operations (`apply_edit` reducer).
pub const Edit = @import("Edit.zig");
/// Binary IR — wire format, encoder, decoder.
pub const Binary = @import("Binary.zig");
/// Zero-allocation read cursor over a Binary IR file.
pub const BinaryCursor = @import("BinaryCursor.zig");
/// Bootstrap meta-plugin descriptor — describes v1 portable manifests.
pub const MetaSchema = @import("MetaSchema.zig");
/// Reads a v1 portable manifest into an in-memory `Plugin`.
pub const ManifestLoader = @import("ManifestLoader.zig");
/// Cross-host validating-host contract types (D0). Orchestration lands in D1.
pub const Host = @import("Host.zig");
/// Side-table overlay of materialized default values keyed by `(form, key)`.
/// Gives hosts effective values for omitted defaulted keys without
/// mutating the author tree.
pub const MaterializedDefaults = @import("MaterializedDefaults.zig");
/// Read-side composition over `Ast.Tree` + `MaterializedDefaults`. One
/// API for consumers asking "what is the effective value of `:key` on
/// this form?" without re-implementing the author-then-overlay
/// fallback.
pub const EffectiveView = @import("EffectiveView.zig");
/// Effective-document splicer: the author's source with omitted
/// defaults spliced in. Shared by the LSP (`getEffectiveDocument`,
/// materialize code action) and the CLI (`sjon effective`).
pub const EffectiveDocument = @import("EffectiveDocument.zig");
/// Host-owned form-lowering runtime — registry, hook contract, pass
/// driver, and lowered-tree provenance. See
/// `docs/plugin-model-v1.md`.
pub const Lowering = @import("Lowering.zig");
/// Renders the aggregate `:lowering :produces` DAG as SJON
/// (`sjon export-lowering-graph`). Derived from the same
/// `Schema.buildLoweringGraph` the static cycle check consumes.
pub const LoweringGraph = @import("LoweringGraph.zig");
/// Test-only lowering hooks. Real hooks — `pngine/pass-v1` and friends —
/// ship alongside the host that owns them; nothing here is meant for a
/// production consumer.
///
/// It is `pub` anyway, and the reason is a module boundary rather than an
/// oversight. `conformance_tests.zig`, `Host_tests.zig` and
/// `oom_tests.zig` all live *inside* this module and reach the file
/// directly, but `src/fuzz.zig` is its own test root that imports `sjon`
/// as a module: a relative import there would compile a second copy of
/// this file, and a second `Lowering.Hook` type with it, which
/// `LoweringRegistry.register` would reject. The re-export is how the
/// fuzz harness registers a hook at all. Dropping it means giving
/// `fuzz.zig` a named module of its own in `build.zig` — worth doing when
/// the aggregate's surface is being frozen, not before.
pub const Lowering_test_hooks = @import("Lowering_test_hooks.zig");
/// Expected-value decoder for value-carrying conformance fixtures. Shared
/// by the conformance runner (compares via `Expr.Value.equals`) and the
/// `expected.values.json` sibling generator (`tools/gen_expected_values.zig`,
/// which re-encodes through `wasm_common.appendValue`).
pub const ConformanceExpected = @import("ConformanceExpected.zig");
/// Prose explanation (`short` + optional `long`) for every
/// `Ast.Diagnostic.Code` variant, with a completeness test that fails the
/// build when a new code arrives without one. Lives in the library rather
/// than the CLI because both `sjon explain` and the LSP hover surface it.
pub const Explanations = @import("Explanations.zig");
/// Plugin reference resolver contract (D0). Filesystem impl lands in D3.
pub const Resolver = @import("Resolver.zig");
/// Default filesystem-backed `Resolver.Resolver` driven by `sjon-project.sjon`.
pub const FilesystemResolver = @import("FilesystemResolver.zig");

/// Simple glob matcher used by `sjon-project.sjon` `:documents` and
/// `:ignore` patterns. Dialect: `*`, `**`, `?`, `{a,b}` — see
/// `src/Glob.zig`.
pub const Glob = @import("Glob.zig");

/// Lockfile format, parser, writer, and hash helpers for
/// `sjon-project.lock`. See `src/Lockfile.zig`.
pub const Lockfile = @import("Lockfile.zig");

/// Binary `Expr.Value` codec for the executable plugin ABI.
/// See `docs/executable-plugin-abi.md` §9.
pub const PluginValueCodec = @import("PluginValueCodec.zig");

/// Runs the pure name-extractors behind provider-backed cross-refs and
/// answers with the content-addressed table the validator looks results
/// up in. A host pre-pass, in the same layer as lowering.
pub const ProviderExtraction = @import("ProviderExtraction.zig");

/// Named-format checkers used by `:string-bounds :format …` (email,
/// uri, path, uuid, semver). Pure-Zig, zero-dependency.
pub const StringFormats = @import("StringFormats.zig");

/// The SJON string escape set — the one place a value becomes a quoted
/// source-text literal. Shared by `Printer`, `cli/ValueText`, and
/// `EffectiveDocument`, which previously each carried their own copy (and
/// the last of them escaped nothing, splicing syntax errors into user
/// documents). Pure-Zig leaf, `std`-only.
pub const StringEscape = @import("StringEscape.zig");

/// Canonical `sha256-<64 lowercase hex>` pin format — the well-formedness
/// predicate, parse-to-bytes, and render-from-digest shared by the
/// manifest loader, the host hash-pin enforcement, and the lockfile.
/// Pure-Zig leaf, `std`-only. See `src/Sha256Pin.zig`.
pub const Sha256Pin = @import("Sha256Pin.zig");

/// Damerau-Levenshtein nearest-name suggestion engine — the single
/// "did you mean?" source for both the CLI's rich diagnostics (via
/// `cli/Hints.zig`) and the LSP's quick-fix code actions (via
/// `lsp/Handler.zig`). Re-exported here so the LSP handler can share it
/// without a cross-directory relative import. Pure-Zig, `std`-only leaf.
pub const DidYouMean = @import("DidYouMean.zig");

/// Size-capped file reads shared by the CLI and the filesystem resolver
/// (an oversized file errors cleanly instead of OOM-ing). Re-exported so
/// `cli/Cli.zig` can reach it without a cross-directory relative import;
/// `FilesystemResolver.zig` imports the leaf directly. `std`-only.
pub const CappedRead = @import("CappedRead.zig");

/// Shared WASM output-framing + hand-rolled JSON writers. Both wasm
/// artifacts import the leaf directly; re-exported here so the LSP wasm
/// dispatcher can share the one escaper (no cross-directory relative
/// import). Every writer takes an explicit allocator, so it stays
/// natively testable — the leaf never touches `wasm_allocator`.
pub const wasm_common = @import("wasm_common.zig");

/// One-way schema exporter — turns a `Schema.Schema` into JSON Schema
/// 2020-12 and TypeScript `.d.ts` describing the canonical JSON shape
/// of `sjon to-json`. Intended for editors / codegen / downstream
/// consumers; not a runtime validator (the in-repo validator stays
/// authoritative). See `src/SchemaExport/SchemaExport.zig`.
pub const SchemaExport = @import("SchemaExport/SchemaExport.zig");

/// Built-in plugins shipped with SJON.
pub const plugins = struct {
    /// The `core` plugin: closed v1 expression vocabulary.
    pub const core = @import("plugins/core.zig");
    /// The `pattern` plugin: Strudel-style pattern combinators (data forms).
    /// Seeded only on the `PatternQuery` path, never in the default
    /// document schema.
    pub const pattern = @import("plugins/pattern.zig");
};

/// Output-shape selector shared by every encoder. See `Ast.Mode` for the
/// per-module mapping table.
pub const Mode = Ast.Mode;

/// Aggregate error set for SJON's **document-pipeline spine** — the six
/// members listed below (`Json`, `Edit`, `Binary`, `Expr`, `Validator`,
/// `PatternQuery`). Use this when wiring a CLI / FFI / consumer that
/// needs to enumerate the pipeline's failure surface in one place.
///
/// It is deliberately *not* the union of every module's `Error`. Modules
/// outside the spine — `Host`, `ManifestLoader`, `Lockfile`,
/// `LoweringGraph`, `Pattern`, `PluginValueCodec`, `Date`, `Time`,
/// `SchemaExport` — carry their own sets and are consumed directly,
/// because a caller reaching for those is already in a specific layer and
/// gains nothing from a wider union. Folding them in would make this set
/// grow without making any consumer's job easier.
///
/// Shared spine: `OutOfMemory` is implicit on every Zig error set and is
/// listed in each module's literal for explicitness. `DepthExceeded` is
/// deliberately shared across `Binary`, `Expr`, and `Validator` — see
/// those modules' `Error` doc-comments for the per-site meaning. A
/// consumer that needs to distinguish must do so from call-site context,
/// not from the error name. (`BinaryCursor.Error == Binary.Error` and
/// `Validator.Error == Binary.Error`; the explicit listing below is
/// documentation — `||` deduplicates.)
///
/// `Validator.validate` (the Tree path) only allocates, so its failure
/// surface is `Allocator.Error`, subsumed by every member below.
/// `PatternQuery.Error` is the newest member: it adds the pattern-eval
/// budgets (`HapBudgetExceeded`, `TickOverflow`) on top of the shared
/// `OutOfMemory` / `DepthExceeded` / `MemoryBudgetExceeded`.
pub const Error =
    Json.Error ||
    Edit.Error ||
    Binary.Error ||
    Expr.Error ||
    Validator.Error ||
    PatternQuery.Error;

comptime {
    // Error-convention gate. The aggregate above already self-gates its six
    // members (it references each `.Error`). These modules carry a public
    // error surface that sits outside that union; assert each still spells the
    // conventional `pub const Error`, so dropping or renaming one is a compile
    // break here rather than a silent drift from the convention.
    //
    // Deliberately absent, and why:
    //   * `Glob`, `Sha256Pin`, `DidYouMean`, `StringFormats`, `trig`,
    //     `Explanations`, `MetaSchema` — no error-returning API at all
    //     (predicates, parsers returning optionals, data tables). The
    //     convention is "every module with an error surface", not "every
    //     module", and adding a vacuous `Error` to a total function would
    //     be noise.
    //   * `PluginRuntime` — carries `pub const Error`, but root.zig cannot
    //     reference it here: it comptime-asserts -Dplugin-exec, so
    //     importing it would force that flag onto every build.
    for (.{
        EffectiveView,
        EffectiveDocument,
        MaterializedDefaults,
        Lowering,
        // Extended in r1-06: the list had stopped growing at the four
        // above while the error-surfaced module count roughly quadrupled,
        // so the "gate" covered a quarter of what it names.
        Host,
        ManifestLoader,
        Lockfile,
        LoweringGraph,
        Pattern,
        PluginValueCodec,
        Date,
        Time,
        SchemaExport,
        Resolver,
        FilesystemResolver,
        CappedRead,
        PatternQuery,
        Json,
        Edit,
        Binary,
        Expr,
        Validator,
    }) |M| {
        if (!@hasDecl(M, "Error")) {
            @compileError("module lacks the conventional `pub const Error`: " ++ @typeName(M));
        }
    }
}

// ---------------------------------------------------------------------------
// Public API. Each entrypoint walks the SoA `Ast.Tree` natively.
// ---------------------------------------------------------------------------

/// Parse SJON source into a SoA `Tree`. Caller must call `tree.deinit()`.
/// O(n) where n = source bytes; allocates from `gpa` (one arena per tree).
pub fn parse(gpa: Allocator, source: [:0]const u8) Allocator.Error!Ast.Tree {
    std.debug.assert(source.len <= Binary.MAX_FILE_SIZE);
    std.debug.assert(source.len == 0 or source.ptr[source.len] == 0);
    return Parser.parse(gpa, source);
}

/// Print a `Tree` to a freshly-allocated, caller-owned `Ast.Bytes`.
/// Caller must `result.deinit()`. O(n) length pre-pass + O(n) emit.
pub fn print(gpa: Allocator, tree: Ast.Tree, opts: Printer.Options) Allocator.Error!Ast.Bytes {
    std.debug.assert(opts.indent <= 16);
    return Printer.print(gpa, tree, opts);
}

/// Validate a `Tree` against a schema. Caller must `result.deinit()`.
/// O(n) walk; allocates only diagnostics.
pub fn validate(gpa: Allocator, tree: Ast.Tree, schema: Schema.Schema) Validator.Error!Validator.Result {
    // No width precondition: the tree walker has no node ceiling (see
    // CLAUDE.md), and the parser has none either, so a 1 << 20-root
    // document is ordinary input here. The binary path enforces
    // `MAX_NODES` at encode time with an error.
    return Validator.validate(gpa, tree, schema);
}

/// Validate a single-source document whose plugins are declared inline
/// alongside its data. Parses `source`, partitions top-level forms into
/// `(plugin …)` declarations vs. data, loads each declaration, runs
/// schema-aggregate validators, then validates the data forest against
/// the composed schema. Caller must `result.deinit()`.
///
/// The returned `HostResult.diagnostics` is a single phase-tagged slice
/// (manifest → aggregate → validation, in that order).
pub fn validateDocument(
    gpa: Allocator,
    source: [:0]const u8,
    options: Host.HostOptions,
) Host.Error!Host.HostResult {
    std.debug.assert(source.len <= Binary.MAX_FILE_SIZE);
    std.debug.assert(source.len == 0 or source.ptr[source.len] == 0);
    return Host.validateDocument(gpa, source, options);
}

/// Eagerly load every plugin declared in a workspace's
/// `sjon-project.sjon` file and return a `LoadedProject` carrying the
/// composed `Schema.Schema`. Always succeeds — project-file and
/// per-manifest failures surface as `phase = .manifest` diagnostics on
/// the result. Caller must `result.deinit()`.
pub fn loadProject(
    gpa: Allocator,
    options: Host.HostOptions,
) Host.Error!Host.LoadedProject {
    return Host.loadProject(gpa, options);
}

/// Preload an external schema once from a set of standalone `(plugin …)`
/// manifest sources, returning a self-contained `PreloadedSchema` that many
/// `validateDocument` calls can borrow via `HostOptions.preloaded` — the
/// schema is parsed and aggregated once rather than re-prepended to every
/// document. Never fails on user input: parse / load / shape errors become
/// `.manifest`-phase diagnostics and the offending source contributes no
/// plugin. Caller must `result.deinit()`, and only after every `HostResult`
/// that borrowed it. See `Host.preloadSchema`.
pub fn preloadSchema(
    gpa: Allocator,
    manifest_sources: []const [:0]const u8,
) Host.Error!Host.PreloadedSchema {
    return Host.preloadSchema(gpa, manifest_sources);
}

/// Evaluate a safe-expression node addressed by `(tree, idx)`.
/// Caller must `result.deinit()`. O(n) over the node subtree; bounded
/// frame-stack depth = `Expr.MAX_EVAL_DEPTH`. `tree` is consumed by
/// reference internally; the result's strings / vectors are deep-copied
/// into the result arena, so the caller may free `tree` immediately.
pub fn evalExpr(
    gpa: Allocator,
    tree: Ast.Tree,
    idx: Ast.NodeIndex,
    env: *const Expr.Env,
    schema: Schema.Schema,
) Expr.Error!Expr.Result {
    return Expr.eval(gpa, &tree, idx, env, schema);
}

/// Encode a single-root `Tree` to JSON. Caller must `result.deinit()`.
/// O(n) where n = nodes; allocates the result via `gpa`.
pub fn toJson(gpa: Allocator, tree: Ast.Tree, opts: Json.ToJsonOptions) Json.Error!Json.Result {
    // A multi-root tree is `error.MultipleRoots` from the bridge, not a
    // precondition — root count is parser output, i.e. user input.
    return Json.toJson(gpa, tree, opts);
}

/// Decode a JSON value back to a single-root `Tree`. Caller must `tree.deinit()`.
/// O(n) where n = JSON value nodes.
pub fn fromJson(gpa: Allocator, value: std.json.Value, opts: Json.FromJsonOptions) Json.Error!Ast.Tree {
    return Json.fromJson(gpa, value, opts);
}

/// Encode a `Tree` (any number of roots) wrapped in `{"$roots": [...]}`.
/// Caller must `result.deinit()`. O(n) over nodes.
pub fn toJsonRoots(gpa: Allocator, tree: Ast.Tree, opts: Json.ToJsonOptions) Json.Error!Json.Result {
    return Json.toJsonRoots(gpa, tree, opts);
}

/// Decode a `{"$roots": [...]}` wrapper into a multi-root `Tree`.
/// Caller must `tree.deinit()`. O(n) over JSON value nodes.
pub fn fromJsonRoots(gpa: Allocator, value: std.json.Value, opts: Json.FromJsonOptions) Json.Error!Ast.Tree {
    // A non-object is `error.InvalidEncoding` from the bridge; the value
    // is decoded caller input.
    return Json.fromJsonRoots(gpa, value, opts);
}

/// Apply a JSON-encoded structural edit to `source` and return the printed
/// result as `Ast.Bytes`. Caller must `result.deinit()`. Functional rebuild
/// on `Ast.Tree`: walk the source tree, emit unchanged subtrees via
/// `TreeBuilder.cloneNode`, transform at the edit's path. O(n) parse +
/// O(n) rebuild + O(n) emit.
pub fn applyEdit(
    gpa: Allocator,
    source: [:0]const u8,
    action: std.json.Value,
    opts: Edit.Options,
) Edit.Error!Ast.Bytes {
    std.debug.assert(source.len <= Binary.MAX_FILE_SIZE);
    std.debug.assert(source.len == 0 or source.ptr[source.len] == 0);
    return Edit.applyEdit(gpa, source, action, opts);
}

/// Apply a JSON-encoded structural edit to an already-parsed `Tree` and
/// return the edited tree. Caller must `result.deinit()`. Useful when a
/// caller already holds a tree (editor reducers, batched edits) — avoids
/// the parse/print round-trip `applyEdit` performs for source-bytes
/// callers. Same action shape and error contract as `applyEdit`.
pub fn applyEditToTree(
    gpa: Allocator,
    tree: *const Ast.Tree,
    action: std.json.Value,
) Edit.Error!Ast.Tree {
    return Edit.applyEditToTree(gpa, tree, action);
}

/// Encode a `Tree` to a Binary IR buffer as `Ast.Bytes`. Caller must
/// `result.deinit()`. O(n) emit; output ≤ `Binary.MAX_FILE_SIZE` bytes.
pub fn toBinary(gpa: Allocator, tree: Ast.Tree, opts: Binary.ToBinaryOptions) Binary.Error!Ast.Bytes {
    std.debug.assert(tree.root.len <= Binary.MAX_NODES);
    std.debug.assert((opts.flags() & Binary.Flag.reserved_mask) == 0);
    return Binary.toBinary(gpa, tree, opts);
}

/// Decode a Binary IR buffer back to a `Tree`. Caller must `tree.deinit()`.
/// The decoder copies strings into its own arena, so the returned tree
/// is self-contained and `bytes` need not outlive the call. O(n) decode.
pub fn fromBinary(gpa: Allocator, bytes: []const u8, opts: Binary.FromBinaryOptions) Binary.Error!Ast.Tree {
    // No size assert here: `Binary.fromBinary` rejects oversized input with
    // `error.NodeCountExceeded` (these bytes are often unvalidated), so a
    // facade assert would panic ahead of the error it is meant to surface.
    return Binary.fromBinary(gpa, bytes, opts);
}

/// Validate a binary IR buffer against a schema. Streams `bytes` directly
/// via `BinaryCursor` — no intermediate `Tree` is built, which keeps the
/// `sjon-binary.wasm` artifact free of `Binary.fromBinary` and the
/// tree-builder code path. Diagnostic messages are owned by the returned
/// `Result`; the caller does NOT need to keep `bytes` alive past this
/// call. O(n) over the buffer.
pub fn validateBinary(
    gpa: Allocator,
    bytes: []const u8,
    schema: Schema.Schema,
) Validator.Error!Validator.Result {
    return try Validator.validateBinary(gpa, bytes, schema);
}

/// Evaluate a single-root binary IR buffer as a safe expression. Returns
/// `error.MultipleRoots` if the binary has more than one root. The
/// returned `Expr.Value` is fully owned by `result.arena`, so callers do
/// NOT need to keep `bytes` alive.
///
/// Implementation: streams `bytes` directly via `BinaryCursor` — no
/// intermediate `Tree` is built. O(n) over the buffer.
pub fn evalExprBinary(
    gpa: Allocator,
    bytes: []const u8,
    env: *const Expr.Env,
    schema: Schema.Schema,
) Expr.BinaryError!Expr.Result {
    return try Expr.evalBinary(gpa, bytes, env, schema);
}

test {
    // Every `pub const … = @import("…")` module above is referenced here so
    // its inline tests are collected. `refAllDecls` replaces the old
    // hand-maintained list — which had silently dropped `Glob`, `Lockfile`,
    // and `trig` (their inline tests were dead weight; `Glob.zig` read 0%
    // coverage with 19 live tests sitting right there).
    std.testing.refAllDecls(@This());
    // `refAllDecls` is shallow: it references `plugins` (a wrapper struct)
    // but not its nested modules, and it can't see test-only files that
    // aren't `pub` decls of root. Reference those explicitly.
    _ = plugins.core;
    _ = plugins.pattern;
    _ = @import("oom_tests.zig");
    _ = @import("conformance_tests.zig");
    _ = @import("composition_tests.zig");
    _ = @import("Host_tests.zig");
}

test "version constant is non-empty" {
    try std.testing.expect(version.len > 0);
}

test "Error aggregate covers every module's typed errors" {
    // Compile-time existence check: a representative variant from each
    // module's `Error` set must coerce into the aggregate. Adding a new
    // variant somewhere without folding it through `||` here is a
    // build-time failure, not a runtime surprise.
    inline for (.{
        @as(Error, error.MultipleRoots), // Json
        @as(Error, error.UnknownOp), // Edit
        @as(Error, error.InvalidMagic), // Binary
        @as(Error, error.TypeMismatch), // Expr
        @as(Error, error.DepthExceeded), // shared spine
    }) |e| {
        try std.testing.expect(@errorName(e).len > 0);
    }
}

// ---------------------------------------------------------------------------
// Example fixtures — pinned so doc / tutorial files don't bit-rot.
// Tests run with the repository root as the current working directory, so
// these read straight off disk rather than via `@embedFile` (which can't
// reach paths outside the `src/` package).
// ---------------------------------------------------------------------------

fn readExampleSentinel(gpa: Allocator, path: []const u8) ![:0]u8 {
    const io = std.testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    const buf = try gpa.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf, bytes);
    return buf;
}

test "examples/basic.sjon parses without diagnostics" {
    const a = std.testing.allocator;
    const src = try readExampleSentinel(a, "examples/basic.sjon");
    defer a.free(src);

    var tree = try parse(a, src);
    defer tree.deinit();
    try std.testing.expect(!tree.hasErrors());
}

test "examples/with-expressions.sjon parses, validates, and evaluates" {
    const a = std.testing.allocator;
    const src = try readExampleSentinel(a, "examples/with-expressions.sjon");
    defer a.free(src);

    var tree = try parse(a, src);
    defer tree.deinit();
    try std.testing.expect(!tree.hasErrors());

    const schema = Schema.Schema.init(&.{plugins.core.plugin});
    var vresult = try validate(a, tree, schema);
    defer vresult.deinit();
    try std.testing.expect(!vresult.hasErrors());

    // Every top-level item is itself a safe expression that evaluates
    // cleanly under an empty environment.
    const env: Expr.Env = .{};
    for (tree.root) |idx| {
        var r = try evalExpr(a, tree, idx, &env, schema);
        defer r.deinit();
    }
}

test "examples/webgpu-render-pipeline.sjon lowers and validates clean" {
    // The example is documentation that must stay executable. Read the literal
    // file, register its reference hook `webgpu/render-pipeline-v1`, and run
    // the whole document through the host lower+validate pipeline. A clean
    // result proves the surface schema, the `(* 2 2)` computed values, the
    // `(depth-stencil)` defaults, and the lowering hook still agree — break any
    // and this test (not silent doc rot) catches it. The hook lives in
    // `Lowering_test_hooks.zig`; the inline `(plugin …)` needs no resolver.
    const a = std.testing.allocator;
    const src = try readExampleSentinel(a, "examples/webgpu-render-pipeline.sjon");
    defer a.free(src);

    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(a);
    try registry.register(a, Lowering_test_hooks.webgpu_render_pipeline_v1);

    var hr = try Host.validateDocument(a, src, .{ .lowering_registry = &registry });
    defer hr.deinit();

    if (hr.hasErrors()) {
        std.debug.print("\nwebgpu-render-pipeline.sjon diagnostics:\n", .{});
        for (hr.diagnostics) |d| {
            std.debug.print(
                "  [{s}] @{d}..{d}: {s}\n",
                .{ @tagName(d.code), d.span.start, d.span.end, d.message },
            );
        }
    }
    try std.testing.expect(!hr.hasErrors());
}

test "manifests/meta.sjon parses without diagnostics" {
    // Smoke check: the bootstrap meta-plugin source is syntactically
    // valid SJON. Semantic validation against the meta-plugin itself
    // is the next test — this guards the source against parser rot.
    const a = std.testing.allocator;
    const src = try readExampleSentinel(a, "manifests/meta.sjon");
    defer a.free(src);

    var tree = try parse(a, src);
    defer tree.deinit();
    try std.testing.expect(!tree.hasErrors());
}

test "manifests/meta.sjon self-validates against MetaSchema" {
    // The contract pinned in `manifests/meta.sjon` and §10 of
    // `docs/portable-manifest-v1.md`: validating the meta-plugin
    // source against the Zig MetaSchema descriptor produces zero
    // diagnostics. If this test fails, MetaSchema.zig and meta.sjon
    // have drifted apart.
    const a = std.testing.allocator;
    const src = try readExampleSentinel(a, "manifests/meta.sjon");
    defer a.free(src);

    var tree = try parse(a, src);
    defer tree.deinit();
    try std.testing.expect(!tree.hasErrors());

    var v = try validate(a, tree, MetaSchema.schema);
    defer v.deinit();

    if (v.hasErrors()) {
        std.debug.print("\nself-validation diagnostics:\n", .{});
        for (v.diagnostics) |d| {
            std.debug.print(
                "  [{s}] @{d}..{d}: {s}\n",
                .{ @tagName(d.code), d.span.start, d.span.end, d.message },
            );
        }
    }
    try std.testing.expect(!v.hasErrors());
}

test "manifests/meta.sjon round-trips through ManifestLoader" {
    // Loading the meta-plugin source must produce a Plugin equivalent
    // to MetaSchema.plugin (same form / value-kind counts; same
    // top-level name). Then validating meta.sjon against the LOADED
    // plugin must also produce zero diagnostics — the loader is
    // faithful.
    const a = std.testing.allocator;
    const src = try readExampleSentinel(a, "manifests/meta.sjon");
    defer a.free(src);

    var tree = try parse(a, src);
    defer tree.deinit();

    var loaded = try ManifestLoader.load(a, tree);
    defer loaded.deinit();

    try std.testing.expect(!loaded.hasErrors());
    try std.testing.expectEqualStrings("meta", loaded.plugin.name);
    try std.testing.expectEqual(MetaSchema.plugin.forms.len, loaded.plugin.forms.len);
    try std.testing.expectEqual(MetaSchema.plugin.value_kinds.len, loaded.plugin.value_kinds.len);
    try std.testing.expectEqual(MetaSchema.plugin.expr_funcs.len, loaded.plugin.expr_funcs.len);

    // Self-validate against the LOADED plugin.
    const loaded_schema: Schema.Schema = .{ .plugins = &.{loaded.plugin} };
    var v = try validate(a, tree, loaded_schema);
    defer v.deinit();
    try std.testing.expect(!v.hasErrors());
}

// ---------------------------------------------------------------------------
// Binary IR parity tests — Phase B4.
//
// The contract is `validate(parse(s)) ≡ validateBinary(toBinary(parse(s)))`
// and `evalExpr(parse(s)) ≡ evalExprBinary(toBinary(parse(s)))`. Run on
// every fixture so we catch parity drift between the text and binary
// dispatch paths.
// ---------------------------------------------------------------------------

test "validateBinary parity on examples/basic.sjon" {
    const a = std.testing.allocator;
    const src = try readExampleSentinel(a, "examples/basic.sjon");
    defer a.free(src);

    var tree = try parse(a, src);
    defer tree.deinit();
    const schema = Schema.Schema.init(&.{plugins.core.plugin});

    var via_text = try validate(a, tree, schema);
    defer via_text.deinit();

    const bin = try toBinary(a, tree, Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var via_bin = try validateBinary(a, bin.data, schema);
    defer via_bin.deinit();

    try std.testing.expectEqual(via_text.diagnostics.len, via_bin.diagnostics.len);
}

test "validateBinary parity on examples/with-expressions.sjon" {
    const a = std.testing.allocator;
    const src = try readExampleSentinel(a, "examples/with-expressions.sjon");
    defer a.free(src);

    var tree = try parse(a, src);
    defer tree.deinit();
    const schema = Schema.Schema.init(&.{plugins.core.plugin});

    var via_text = try validate(a, tree, schema);
    defer via_text.deinit();
    try std.testing.expect(!via_text.hasErrors());

    const bin = try toBinary(a, tree, Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var via_bin = try validateBinary(a, bin.data, schema);
    defer via_bin.deinit();
    try std.testing.expect(!via_bin.hasErrors());
}

test "evalExprBinary parity: every expression in examples/with-expressions.sjon" {
    const a = std.testing.allocator;
    const src = try readExampleSentinel(a, "examples/with-expressions.sjon");
    defer a.free(src);

    var tree = try parse(a, src);
    defer tree.deinit();
    const schema = Schema.Schema.init(&.{plugins.core.plugin});
    const env: Expr.Env = .{};

    for (tree.root) |idx| {
        var via_text = try evalExpr(a, tree, idx, &env, schema);
        defer via_text.deinit();

        // Re-parse just this root's source span as its own tree, encode
        // to a binary, decode, eval — exercising the binary parity path.
        const span = tree.spanOf(idx);
        const sub_src_buf = src[span.start..span.end];
        const sub_src = try a.allocSentinel(u8, sub_src_buf.len, 0);
        defer a.free(sub_src);
        @memcpy(sub_src, sub_src_buf);

        var sub_tree = try parse(a, sub_src);
        defer sub_tree.deinit();

        const bin = try toBinary(a, sub_tree, Binary.ToBinaryOptions.forMode(.compact));
        defer bin.deinit();

        var via_bin = try evalExprBinary(a, bin.data, &env, schema);
        defer via_bin.deinit();

        try std.testing.expect(Expr.Value.equals(via_text.value, via_bin.value));
    }
}

test "WASM in-process round-trip: text → toBinary → fromBinary → print" {
    const a = std.testing.allocator;
    const src = "(scene :bpm 130 (canvas :name \"main\" [1 2 3]))";

    var tree = try parse(a, src);
    defer tree.deinit();

    const bin = try toBinary(a, tree, Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();

    var rebuilt = try fromBinary(a, bin.data, .{});
    defer rebuilt.deinit();

    const printed = try print(a, rebuilt, .{});
    defer printed.deinit();

    const direct = try print(a, tree, .{});
    defer direct.deinit();

    try std.testing.expectEqualStrings(direct.data, printed.data);
}

// ---------------------------------------------------------------------------
// Canonical-print idempotence — Phase 2 property.
//
// Canonical printing is deterministic: emitting and re-parsing must reach
// a fixed point on the very first round trip. Concretely, for every form
// `F` in `fixtures/json_roundtrip.sjon`:
//
//   print(parse(F)) == print(parse(print(parse(F))))
//
// If the printer ever produced output that re-parses into a different
// tree, this property would fail on the second pass. Iterating over every
// top-level form catches drift on a per-encoding basis (atoms, vectors,
// keyword pairs, qualified heads, sigil-escaped reserved keys, …).
// ---------------------------------------------------------------------------

test "canonical-print idempotence: every form in fixtures/json_roundtrip.sjon" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "fixtures/json_roundtrip.sjon", a, .unlimited);
    defer a.free(bytes);
    const src = try a.allocSentinel(u8, bytes.len, 0);
    defer a.free(src);
    @memcpy(src, bytes);

    var tree = try parse(a, src);
    defer tree.deinit();
    try std.testing.expect(!tree.hasErrors());
    try std.testing.expect(tree.root.len > 0);

    for (tree.root, 0..) |idx, i| {
        // Re-parse just this root's source span as its own single-root tree.
        const span = tree.spanOf(idx);
        const sub_src_buf = src[span.start..span.end];
        const sub_src = try a.allocSentinel(u8, sub_src_buf.len, 0);
        defer a.free(sub_src);
        @memcpy(sub_src, sub_src_buf);

        var sub = try parse(a, sub_src);
        defer sub.deinit();

        const first = try print(a, sub, .{});
        defer first.deinit();

        const sentinel_first = try a.allocSentinel(u8, first.data.len, 0);
        defer a.free(sentinel_first);
        @memcpy(sentinel_first, first.data);

        var reparsed = try parse(a, sentinel_first);
        defer reparsed.deinit();
        try std.testing.expect(!reparsed.hasErrors());

        const second = try print(a, reparsed, .{});
        defer second.deinit();

        std.testing.expectEqualStrings(first.data, second.data) catch |err| {
            std.debug.print("\nidempotence break at fixture #{d}:\n  first:  {s}\n  second: {s}\n", .{ i, first.data, second.data });
            return err;
        };
    }
}
