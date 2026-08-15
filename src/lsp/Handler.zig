//! Pure SJON-aware LSP logic. No lsp-kit, no transport, no JSON-RPC.
//!
//! Both `main.zig` (native, lsp-kit dispatched) and `wasm.zig` (WASM,
//! hand-rolled JSON-RPC) sit on top of this and translate between
//! protocol shapes and the `Handler` API.
//!
//! The handler owns:
//!   - a built `Schema.Schema` — `core` only at construction time;
//!     `loadProject` swaps it for `core` plus every plugin manifest the
//!     workspace's `sjon-project.sjon` resolves successfully,
//!   - an optional `Host.LoadedProject` carrying the project file's URI,
//!     source, and any phase-tagged diagnostics produced while loading
//!     it (the transport surfaces these against the project file URI),
//!   - a URI-keyed map of `Document`s, each caching its parsed `Ast.Tree`
//!     and `Validator.Result`.
//!
//! Diagnostics are exposed as byte-offset-keyed `Diagnostic` records
//! the transports translate to LSP `Position`s. Keeping the offset domain
//! out of the transport's encoding choice (UTF-8 vs UTF-16) lets the same
//! Handler serve every encoding the protocol negotiates.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sjon = @import("sjon");
const DidYouMean = sjon.DidYouMean;
/// Bound as `uri_key` rather than `uri`: half the functions below take a
/// parameter of that name.
const uri_key = @import("uri");

const Ast = sjon.Ast;
const Expr = sjon.Expr;
const Host = sjon.Host;
const Parser = sjon.Parser;
const Plugin = sjon.Plugin;
const Schema = sjon.Schema;
const Validator = sjon.Validator;
const ManifestLoader = sjon.ManifestLoader;
const MaterializedDefaults = sjon.MaterializedDefaults;

/// Errors this module's public API can return.
///
/// Almost every entry point is `Allocator.Error` alone — the handler
/// parses, validates and renders, and none of those raise: the parser
/// collects diagnostics rather than failing, and the query surfaces
/// return `null` for "nothing here". `UnknownDocument` is the single
/// non-allocation failure, raised by `changeDocumentFull` for a URI the
/// handler was never told to open. Entry points that cannot raise it are
/// annotated `Allocator.Error` directly rather than widening to this set,
/// so a caller can tell from the signature which ones need the arm.
///
/// `OutOfMemory` is listed for documentation, per the house convention.
pub const Error = error{
    OutOfMemory,
    UnknownDocument,
};

/// One open document. Source is owned; `tree`, `validate_result` and
/// `materialized` are caches — invalidated and rebuilt on every full
/// change.
pub const Document = struct {
    /// Sentinel-terminated source bytes. Owned by `gpa`.
    source: [:0]u8,
    /// Client-supplied LSP document version.
    version: i64,
    /// Cached parse. Owned by its own arena.
    tree: Ast.Tree,
    /// Cached validation. Owned by its own arena.
    validate_result: Validator.Result,
    /// Effective values for keys the author omitted but the schema
    /// defaults. **Display-only** — see `rebuildMaterialized`. Rebuilt
    /// in lockstep with `validate_result`, so it is fresh for the same
    /// (source, schema) pair the diagnostics were computed from and
    /// needs no generation counter of its own.
    materialized: MaterializedDefaults.MaterializedDefaults = .{},
    /// Arena owning `materialized`'s entries and the string / vector
    /// contents of their values. Its own arena rather than
    /// `validate_result.arena`: that one belongs to `Validator.Result`
    /// and dies whenever the validator hands back a new result, which
    /// is not always when the overlay changes.
    materialized_arena: std.heap.ArenaAllocator,
    /// Where these bytes came from. Defaults to `.open` so every existing
    /// construction site keeps its meaning.
    origin: Origin = .open,

    /// How a document entered the handler's document set.
    ///
    /// Both kinds are full members of the document set and go through the
    /// same forest pass, so they share one lifecycle, one cache-key
    /// scheme, and one set of cached results. That is a bookkeeping
    /// convenience, **not** a semantic one: cross-ref scope stays
    /// per-tree (the LSP never sets `Validator.Options.share_scope`), so
    /// ingesting a workspace file cannot change any other document's
    /// diagnostics. What it does change is coverage — `getWorkspaceSymbols`
    /// reads the forest index, so ingested files become findable.
    ///
    /// The distinction exists because the two differ in exactly two
    /// places: an open buffer's text wins over the disk copy, and only an
    /// open buffer has a client-supplied version to key a result id on.
    pub const Origin = enum {
        /// The editor opened it. `version` is client-supplied, and the
        /// text may legitimately differ from what is on disk.
        open,
        /// The transport read it during a workspace enumeration and the
        /// editor has never opened it, so there is no client version to
        /// report and no reason to trust a stored one.
        workspace,
    };

    fn deinit(self: *Document, gpa: Allocator) void {
        self.materialized_arena.deinit();
        self.validate_result.deinit();
        self.tree.deinit();
        gpa.free(self.source);
    }
};

/// One file the transport enumerated on disk, offered to the handler
/// through `ingestWorkspaceFiles`. The handler never touches a
/// filesystem: enumeration, filtering, and reading are the transport's
/// job, which is what keeps this type the whole of the seam.
pub const WorkspaceFile = struct {
    uri: []const u8,
    source: []const u8,
};

/// What one `ingestWorkspaceFiles` call did. `clipped` is the count the
/// cap refused — transports are expected to surface it rather than let a
/// truncated workspace look like a complete one.
pub const WorkspaceIngest = struct {
    ingested: usize,
    clipped: usize,
};

/// Ceiling on workspace (never-opened) documents the handler will hold.
/// Each costs a parse, a validation result, and a defaults overlay, and a
/// stray `node_modules` in the root can otherwise make an editor session
/// swallow a repository. `ingestWorkspaceFilesWithCap` takes the cap as a
/// parameter so tests can drive the clip without materialising thousands
/// of files — the same shape `Expr.evalWithRuntimeBudget` uses.
pub const MAX_WORKSPACE_FILES: usize = 2048;

/// One document's entry in a `workspace/diagnostic` response.
pub const WorkspaceReport = struct {
    uri: []const u8,
    /// Null for files the editor has never opened, per the LSP shape:
    /// there is no client-supplied version to echo back.
    version: ?i64,
    /// Cache key the client may hand back as `previousResultId`. For an
    /// open document this is byte-identical to what
    /// `textDocument/diagnostic` publishes, so the two requests cannot
    /// disagree about the same file.
    result_id: []const u8,
    diagnostics: []const Diagnostic,
};

/// Severity as an editor should render it. `err` and `warning` match
/// `Ast.Diagnostic.Severity` one-for-one — repeated here so transports
/// don't have to reach into the SJON namespace.
///
/// `hint` has no counterpart there, deliberately. It is a presentational
/// rank only: nothing in the core grades a diagnostic as a hint, and no
/// code is *born* one. It exists so this layer can say "the validator was
/// right to complain, but this session was never in a position to check
/// it" without editing the wire code or the validator's own severity —
/// see `severityFor`.
pub const Severity = enum { err, warning, hint };

/// Transport-agnostic diagnostic. Span is byte offsets into the document
/// source. `code` is the bare snake_case tag from `Ast.Diagnostic.Code`
/// (e.g. `"unknown_form"`) — stable across SJON versions per LANGUAGE §7.6.
pub const Diagnostic = struct {
    span_start: u32,
    span_end: u32,
    severity: Severity,
    code: []const u8,
    message: []const u8,
    /// LSP `DiagnosticTag`s. Empty for most codes; transports map the
    /// slice to the LSP `tags: number[]` shape and omit the field when
    /// it's empty. Derived at translate time from the diagnostic's code
    /// — nothing in `Ast.Diagnostic` carries a tag.
    tags: []const Tag = &.{},
    /// LSP `relatedInformation` — other places the reader needs to look
    /// to understand this diagnostic. Empty for most codes. Derived at
    /// diagnostic-build time from the tree, schema, and cross-ref index
    /// the Handler already holds; nothing in `Ast.Diagnostic` carries it.
    related: []const Related = &.{},
    /// LSP `codeDescription.href` — the code's documentation page.
    ///
    /// Deliberately un-defaulted, unlike `tags` and `related`: every
    /// code has a page, so there is no "no href" case, and a default
    /// would let a construction site ship an empty one silently. A new
    /// site is a compile error until it calls `codeHref`.
    code_href: []const u8,

    /// One related location. `uri` is carried explicitly because a
    /// related site need not live in the diagnostic's own document.
    pub const Related = struct {
        uri: []const u8,
        span_start: u32,
        span_end: u32,
        message: []const u8,
    };

    /// LSP 3.15+ `DiagnosticTag`. Clients render `.deprecated` by
    /// striking through the span.
    ///
    /// The numbering is **not** `CompletionItem.Tag`'s: LSP gives
    /// `DiagnosticTag.Deprecated` the value 2 (1 is `Unnecessary`),
    /// while `CompletionItemTag.Deprecated` is 1. Two enums, same name,
    /// different wire values — hence two types rather than a shared one.
    pub const Tag = enum(u32) {
        deprecated = 2,
    };
};

/// One user-authored schema fed to `setUserSchemas`. `uri` identifies
/// the editor pane it came from (so the report routes back to it);
/// `text` is the raw `(plugin …)` manifest source.
pub const SchemaSource = struct {
    uri: []const u8,
    text: []const u8,
};

/// Result of loading one `SchemaSource`. `name` is the parsed
/// `(plugin :name <symbol>)` identifier — `""` when the manifest is
/// invalid or hasn't declared one (the transport falls back to a
/// positional label). `diagnostics` carries the schema's own
/// parse/meta/aggregate errors, span-keyed to its `text`. Reports are
/// index-aligned with the `sources` passed to `setUserSchemas`.
///
/// Lifetime: every field is owned by the `arena` passed to
/// `setUserSchemas` — valid until that arena is freed (after the
/// transport serializes the response).
pub const SchemaReport = struct {
    uri: []const u8,
    name: []const u8,
    diagnostics: []const Diagnostic,
};

/// Transport-agnostic hover payload. `contents` is Markdown allocated in
/// the request arena passed to `getHover`. `span_start`/`span_end` are
/// byte offsets the transport translates to an LSP `Range` so the editor
/// can highlight the hovered token.
pub const Hover = struct {
    contents: []const u8,
    span_start: u32,
    span_end: u32,
};

/// Transport-agnostic completion item. `kind` matches the LSP
/// `CompletionItemKind` enum (transports map to integer codes); `label`,
/// `detail`, `documentation`, and `insert_text` are arena-owned strings.
///
/// When `insert_text` is null the client uses `label` verbatim. When
/// non-null and `insert_text_format == .snippet`, the client interprets
/// `$1` / `${2:default}` / `$0` placeholders per the LSP snippet syntax.
pub const CompletionItem = struct {
    label: []const u8,
    kind: Kind,
    detail: []const u8 = "",
    documentation: []const u8 = "",
    insert_text: ?[]const u8 = null,
    insert_text_format: InsertTextFormat = .plain_text,
    /// LSP 3.15+ `CompletionItemTag`. The only currently-defined tag is
    /// `.deprecated`, which the client typically renders by striking
    /// through the label. Empty slice = no tags. Transports map the
    /// slice to the LSP `tags: number[]` shape.
    tags: []const Tag = &.{},
    /// LSP `sortText`. Editors sort items alphabetically by this field
    /// (falling back to `label` when null). The server uses it to bias
    /// required-missing keys, local-schema forms, and non-deprecated
    /// members to the top of the list without renaming the label.
    sort_text: ?[]const u8 = null,
    /// LSP `filterText`. Editors filter items by matching the user's
    /// typed prefix against this field (falling back to `label`). The
    /// server sets it explicitly when `insert_text` differs from
    /// `label` (snippets, `(head …)` wrappers) so client-side filtering
    /// matches what the user sees.
    filter_text: ?[]const u8 = null,
    /// LSP `commitCharacters`. Each byte is a character that, when
    /// typed, accepts the item and inserts the character after it.
    /// Empty = no commit characters (editor uses its defaults). Used
    /// by keyword-key completions so typing ` ` after the suggestion
    /// commits without firing the next completion context.
    commit_characters: []const u8 = &.{},

    pub const Kind = enum(u32) {
        function = 3,
        constructor = 4,
        field = 5,
        /// LSP `CompletionItemKind.EnumMember`. Used by member-value
        /// completion inside `(member-set …)`-typed slots.
        enum_member = 20,
    };

    pub const Tag = enum(u32) {
        deprecated = 1,
    };

    pub const InsertTextFormat = enum(u32) {
        plain_text = 1,
        snippet = 2,
    };
};

/// One text edit. The transport translates the byte span into an LSP
/// `Range`. `new_text` is arena-owned. Used by both formatting and
/// code-action paths — they're the same shape, just differently scoped.
pub const TextEdit = struct {
    span_start: u32,
    span_end: u32,
    new_text: []const u8,
};

/// One source location. Used by `findReferences` and goto-definition.
/// `uri` borrows from the handler's `tree_uris` slice (lifetime-bound to
/// the current cross-ref index epoch — safe within a single request).
/// `span_start`/`span_end` are byte offsets into that document's source.
pub const Location = struct {
    uri: []const u8,
    span_start: u32,
    span_end: u32,
};

/// One entry in the workspace symbol index — a cross-ref *definition*,
/// the only globally-addressable named thing SJON has. `container_name`
/// is the cross-ref target's canonical `plugin/form` name, so a picker
/// shows `p0` filed under `audio/phrase`. Canonical rather than the bare
/// head as written: two plugins may each declare a `phrase`, and the
/// qualified name is what tells their definitions apart.
///
/// `location` points at the name, not the whole form, so picking a
/// symbol lands the cursor exactly where `getDefinition` would.
/// Transports supply the LSP `SymbolKind` — the Handler stays
/// presentation-free, as it does for `DocumentSymbol`.
pub const SymbolInfo = struct {
    name: []const u8,
    container_name: []const u8,
    location: Location,
};

/// Atomic edit set for `rename`. Per-URI grouping mirrors LSP's
/// `WorkspaceEdit { changes }` payload — the transport assembles the
/// JSON shape from this directly.
pub const WorkspaceEdit = struct {
    changes: []const FileEdits,

    pub const FileEdits = struct {
        uri: []const u8,
        edits: []const TextEdit,
    };
};

/// One quickfix the LSP can offer the user. `edits` are applied
/// atomically; `diagnostics` is the set of diagnostics this action
/// resolves, which transports serialize into LSP
/// `CodeAction.diagnostics` so editors pair the fix with its squiggle.
///
/// Whole diagnostics rather than bare codes, because a code does not
/// identify a squiggle: one selection can cover two occurrences of the
/// same mistake, whose actions are then byte-identical in title and
/// code and distinguishable only by span. LSP types the field as
/// `Diagnostic[]` for exactly that reason — clients match the published
/// diagnostic, range included.
pub const CodeAction = struct {
    title: []const u8,
    edits: []const TextEdit,
    diagnostics: []const Diagnostic = &.{},
    /// LSP `CodeActionKind`. Defaults to `.quickfix` — every action here
    /// was one until materialize-defaults arrived, and a fix that forgot
    /// to say so should keep behaving as it did.
    kind: Kind = .quickfix,

    /// The subset of LSP `CodeActionKind` this server emits. The wire
    /// values are the protocol's dotted strings; `lspString` is the only
    /// place they are spelled, so both transports agree by construction.
    pub const Kind = enum {
        quickfix,
        refactor_rewrite,
        refactor_extract,
        refactor_inline,

        pub fn lspString(self: Kind) []const u8 {
            return switch (self) {
                .quickfix => "quickfix",
                .refactor_rewrite => "refactor.rewrite",
                .refactor_extract => "refactor.extract",
                .refactor_inline => "refactor.inline",
            };
        }

        /// Whether clients may auto-apply this action as *the* fix
        /// (LSP `isPreferred`). Only quickfixes qualify: a refactor is
        /// something the user chose, never something to run on their
        /// behalf because it was the single candidate.
        pub fn isPreferred(self: Kind) bool {
            return switch (self) {
                .quickfix => true,
                .refactor_rewrite, .refactor_extract, .refactor_inline => false,
            };
        }
    };
};

/// Hierarchical document symbol. `span` covers the whole construct (a
/// form's span); `selection_span` covers the head identifier so editors
/// can jump to it precisely. `children` is empty for leaf forms.
pub const DocumentSymbol = struct {
    name: []const u8,
    span_start: u32,
    span_end: u32,
    selection_start: u32,
    selection_end: u32,
    children: []const DocumentSymbol = &.{},
};

/// One foldable region — the byte span of a form `(...)` or vector
/// `[...]`. The transport translates the span into LSP `{startLine,
/// endLine}` and drops single-line entries (a fold over a single line
/// has nothing to collapse).
pub const FoldingRange = struct {
    span_start: u32,
    span_end: u32,
};

/// One link in an expand-selection chain — the byte span the editor
/// should select at that expansion step. `getSelectionRanges` returns
/// chains ordered innermost-first, which is the order LSP's nested
/// `SelectionRange.parent` links consume.
pub const SelectionRange = struct {
    span_start: u32,
    span_end: u32,
};

/// One inlay hint. Two families render through this type:
///
///   * **plugin-source hints** — ghost text right after a bare form
///     head, showing which plugin it resolves to, so the reader can see
///     at a glance that `(widget …)` actually binds to `ui/widget`.
///     Heads with an explicit `ns/` namespace, ambiguous heads (already
///     covered by a diagnostic + qualify-with-`ns/` quickfix), and
///     `core` heads (the implicit baseline — `+`, `if`, `vec3`
///     everywhere would be noise) produce none.
///   * **ghost defaults** — `:key value` before a form's closing paren
///     for every key the author omitted and the schema defaults, read
///     off the document's materialized overlay.
pub const InlayHint = struct {
    /// Byte offset where the hint renders — `head_span.end` for a
    /// plugin-source hint, the closing paren for a ghost default.
    offset: u32,
    /// Hint text. Either a plugin name (borrowed from the comptime-static
    /// plugin descriptor) or a `:key value` pair (arena-allocated).
    label: []const u8,
    /// Maps to LSP `InlayHintKind`. Null means "send no kind" and lets
    /// the client pick its default rendering.
    ///
    /// Ghost defaults are `.parameter`: they show a value the call site
    /// left implicit, which is exactly what the kind means elsewhere in
    /// LSP. Plugin-source hints stay null deliberately — they shipped
    /// before this field existed, and assigning one now would change how
    /// current clients render them for no new information.
    kind: ?Kind = null,
    /// Map to LSP `paddingLeft`. Inserts a small visual gap between
    /// the hint and the preceding token so `widget` doesn't run into
    /// `ui` as `widgetui`.
    padding_left: bool = false,
    /// Map to LSP `paddingRight`. Off by default — the next char is
    /// usually whitespace already.
    padding_right: bool = false,

    /// LSP `InlayHintKind`. Wire values are the protocol's, not ours.
    pub const Kind = enum(u32) {
        type = 1,
        parameter = 2,
    };
};

/// One semantic token — a byte span the client should colour by what the
/// *schema* says it is, rather than by what the grammar can see. The
/// TextMate grammar (`hosts/highlight`) stays the zero-config fallback and
/// keeps ownership of strings, numbers, and comments; these tokens layer
/// resolution on top: a head that resolved, a key the form actually
/// declares, a name that defines a cross-ref versus one that uses it.
///
/// **Unresolved constructs deliberately emit no token.** An unknown head or
/// key already carries a diagnostic squiggle; leaving it uncoloured next to
/// coloured neighbours makes "the server doesn't know this one" legible at a
/// glance, and inventing an `unknown` token type would only fight themes.
///
/// Spans are absolute bytes and the slice is sorted ascending and disjoint —
/// both are load-bearing, because the transports encode each token as a
/// delta from its predecessor (and translate to the negotiated encoding
/// there, not here).
pub const SemanticToken = struct {
    span_start: u32,
    span_end: u32,
    type: Type,
    mods: Mods = .{},

    /// Standard LSP token types only, so every client themes these out of
    /// the box with no custom legend mapping. The enum *values* index
    /// `Type.legend`, which is the wire contract with the client — append
    /// only, never reorder.
    pub const Type = enum(u32) {
        /// Plugin qualifier in a `ns/head` — the `ns` part alone.
        namespace = 0,
        /// Resolved data-form head. `macro` rather than `function` because
        /// a data form is a declaration, not a call.
        macro = 1,
        /// Resolved expr-func head.
        function = 2,
        /// `:key` the enclosing form's spec declares.
        property = 3,
        /// Symbol value in a member-set slot.
        enum_member = 4,
        /// Cross-ref name, defining or referencing.
        variable = 5,

        /// LSP names, positionally matched to the enum values above. The
        /// client is told this list once at `initialize` and thereafter
        /// receives bare indices, so the order is a wire contract.
        pub const legend = [_][]const u8{
            "namespace",
            "macro",
            "function",
            "property",
            "enumMember",
            "variable",
        };
    };

    /// Token modifiers, laid out as the bitset LSP puts on the wire: bit i
    /// is `Mods.legend[i]`. `packed struct(u32)` makes `@bitCast` the
    /// encoder, so the field order here *is* the bit order — same append-only
    /// rule as `Type`.
    pub const Mods = packed struct(u32) {
        /// The defining occurrence of a cross-ref name.
        declaration: bool = false,
        /// Vocabulary from the `core` plugin — always available, so themes
        /// can dim it against what this document's own plugins brought.
        default_library: bool = false,
        /// A member the schema marks deprecated.
        deprecated: bool = false,
        _pad: u29 = 0,

        pub const legend = [_][]const u8{
            "declaration",
            "defaultLibrary",
            "deprecated",
        };

        /// The wire bitset.
        pub fn bits(self: Mods) u32 {
            return @bitCast(self);
        }
    };

    comptime {
        // The legends are the client's only key to the indices and bits
        // below; a variant added without its name would silently shift
        // every later token's colour.
        std.debug.assert(Type.legend.len == @typeInfo(Type).@"enum".fields.len);
        std.debug.assert(Mods.legend.len == 3);
    }

    /// One token resolved into the negotiated encoding — line, character,
    /// and length all in that encoding's code units. The transports build
    /// these (each has its own byte↔position converter: native uses
    /// lsp-kit's, WASM its own drop-in), and `encode` turns them into the
    /// wire array. Splitting there keeps the conversion where the encoding
    /// is known and the delta arithmetic — the part that must not diverge
    /// between transports — in one place.
    pub const Position = struct {
        line: u32,
        character: u32,
        length: u32,
        type: Type,
        mods: Mods = .{},
    };

    /// LSP `SemanticTokens.data`: five uints per token, each relative to
    /// its predecessor. `deltaStart` is measured from the previous token
    /// when they share a line and from column zero after a line break —
    /// the protocol's rule, and the reason a client can't just read the
    /// array as absolute positions.
    ///
    /// Requires `toks` ascending (the order `getSemanticTokens` guarantees
    /// and the transports preserve); the deltas are unsigned, so a
    /// descending pair would wrap into a nonsense column rather than fail.
    pub fn encode(arena: Allocator, toks: []const Position) Allocator.Error![]u32 {
        const data = try arena.alloc(u32, toks.len * 5);
        var prev_line: u32 = 0;
        var prev_character: u32 = 0;
        for (toks, 0..) |t, i| {
            std.debug.assert(t.line > prev_line or
                (t.line == prev_line and t.character >= prev_character));
            const delta_line = t.line - prev_line;
            const base = i * 5;
            data[base + 0] = delta_line;
            data[base + 1] = if (delta_line == 0) t.character - prev_character else t.character;
            data[base + 2] = t.length;
            data[base + 3] = @intFromEnum(t.type);
            data[base + 4] = t.mods.bits();
            prev_line = t.line;
            prev_character = t.character;
        }
        std.debug.assert(data.len == toks.len * 5);
        return data;
    }
};

/// Transport-agnostic signature-help payload. Mirrors the LSP shape:
/// a list of overload signatures with a single "active" one and an
/// optional cursor-derived active parameter index. Today we only ever
/// emit one signature (SJON heads aren't overloaded), but the API is
/// shaped for plurality so future plugin overloads slot in cleanly.
pub const SignatureHelp = struct {
    signatures: []const Signature,
    /// Index into `signatures`. Always 0 in the single-signature world.
    active_signature: u32 = 0,
    /// Index into `signatures[active_signature].parameters`. `null` when
    /// the cursor sits outside any parameter (e.g. between args without
    /// a current key, or on an untyped expr-func).
    active_parameter: ?u32 = null,
};

pub const Signature = struct {
    /// Whole signature line: `head :k1 t1 :k2 t2 …` for forms,
    /// `head t1 t2 …rest` for expr-funcs. ASCII by construction (every
    /// component comes from plugin-declared identifiers + `appendValueType`),
    /// so byte offsets and UTF-16 code units coincide.
    label: []const u8,
    /// Free-text description from the matched `FormSpec` / `ExprFunc`.
    documentation: []const u8 = "",
    parameters: []const Parameter,
};

/// Inclusive-start, exclusive-end byte (== UTF-16 code unit) range
/// within the parent `Signature.label` — what the editor highlights
/// when this parameter is active.
pub const Parameter = struct {
    label_start: u32,
    label_end: u32,
};

allocator: Allocator,
schema: Schema.Schema,
/// Keyed by `uri.HashContext`, not byte-exactly: one file has more than one
/// legal URI spelling, and the workspace scanner's differs from the client's.
/// See that context's doc comment for what byte-exact keys cost.
documents: uri_key.HashMapUnmanaged(Document),
project: ?Host.LoadedProject,
/// Monotonic counter bumped on every `loadProject` / `setUserSchemas`
/// call. Pull-mode resultIds embed this so a cached `previousResultId`
/// from before a schema swap doesn't short-circuit to "unchanged" — the
/// diagnostics would actually differ even though the document hasn't.
schema_generation: u32,
/// User-authored schemas installed via `setUserSchemas` (the playground
/// "+ schema" panes). Each `Result` owns the arena its plugin borrows
/// from. Empty until the first `setUserSchemas` call.
///
/// Coupled lifetime with `composed_plugins`: `self.schema.plugins`
/// borrows `composed_plugins`, which borrows each Result's arena. The
/// two are always freed together, in `setUserSchemas` and `deinit`.
user_schemas: std.ArrayList(ManifestLoader.Result),
/// GPA-owned backing for `self.schema.plugins` when user schemas are
/// installed — `[core] ++ [each user_schemas[i].plugin]`. `&.{}` while
/// no user schema set has been installed (the schema then points at the
/// comptime core-only literal from `init`).
composed_plugins: []Plugin.Plugin,
/// Forest-wide cross-ref registry, replaced on every revalidation.
/// Owned by `cross_ref_arena`. Strings borrow from open documents'
/// trees, so the arena's lifetime must not exceed any contributing
/// tree. `null` until the first revalidation succeeds.
cross_ref_index: ?Validator.CrossRefIndex,
cross_ref_arena: ?std.heap.ArenaAllocator,
/// `tree_idx → URI` lookup, populated alongside `cross_ref_index`.
/// `Site.tree_idx` indexes into this slice. Strings duped into
/// `cross_ref_arena`, so the lookup stays valid across document
/// close/open cycles within one revalidation epoch. Empty when no
/// index is loaded.
tree_uris: [][]const u8,
/// Inverse of `tree_uris`: `URI → tree_idx`. Buckets live in the
/// handler's gpa; keys borrow from `tree_uris` (lifetime-bound to
/// `cross_ref_arena`). Rebuilt from scratch on every revalidation.
/// Cross-ref completion uses this to map the current document's
/// URI to the `Site.tree_idx` the index is keyed on without a
/// linear scan per keystroke.
/// Same keying as `documents` — a URI canonicalised by one map and not the
/// other would just move the split one layer down, into every cross-ref
/// feature that resolves the current document to its `tree_idx`.
uri_to_tree_idx: uri_key.HashMapUnmanaged(u32),

const Self = @This();

pub fn init(gpa: Allocator) Self {
    return .{
        .allocator = gpa,
        // Initial schema is the core expression vocabulary only.
        // `loadProject` (called from `initialize` once `rootUri` is known)
        // replaces this with a schema that includes manifest-loaded plugins.
        .schema = Schema.Schema.init(&.{sjon.plugins.core.plugin}),
        .documents = .empty,
        .project = null,
        .schema_generation = 0,
        .user_schemas = .empty,
        .composed_plugins = &.{},
        .cross_ref_index = null,
        .cross_ref_arena = null,
        .tree_uris = &.{},
        .uri_to_tree_idx = .empty,
    };
}

pub fn deinit(self: *Self) void {
    var it = self.documents.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(self.allocator);
    }
    self.documents.deinit(self.allocator);
    if (self.project != null) self.project.?.deinit();
    // `composed_plugins` and `user_schemas` are coupled — free the
    // GPA-owned backing slice, then release each plugin's arena.
    self.allocator.free(self.composed_plugins);
    for (self.user_schemas.items) |*r| r.deinit();
    self.user_schemas.deinit(self.allocator);
    if (self.cross_ref_arena) |*ar| ar.deinit();
    self.uri_to_tree_idx.deinit(self.allocator);
    self.* = undefined;
}

/// Resolve and load the workspace's `sjon-project.sjon` (when present)
/// and replace the schema with one that aggregates `core` plus every
/// successfully-loaded plugin. Idempotent — safe to call multiple times;
/// later calls tear down the previous project before installing the new
/// one. Open documents are NOT re-validated here; callers that need
/// cached diagnostics to reflect the new schema should follow up with
/// `revalidateOpenDocuments`, or use `reloadProject` to do both.
///
/// `workspace_root_path` is a filesystem path (not a URI); pass `null`
/// to skip lookup. Errors here are limited to OOM — every other failure
/// (missing project file, malformed manifest, etc.) is reported via the
/// project's `diagnostics` and should be surfaced by the transport.
pub fn loadProject(self: *Self, io: Io, workspace_root_path: ?[]const u8) Allocator.Error!void {
    var new_project = try sjon.loadProject(self.allocator, .{
        .project_root = workspace_root_path,
        .io = io,
    });
    errdefer new_project.deinit();

    if (self.project != null) self.project.?.deinit();
    self.project = new_project;
    self.schema = Schema.Schema.init(new_project.plugins);
    self.schema_generation +%= 1;
}

/// Re-parse and re-validate every open document against the current
/// schema, replacing each document's cached `tree` and `validate_result`.
/// Source bytes and version are untouched.
///
/// Use after a schema swap (typically via `loadProject`) so that the
/// next pull of `textDocument/diagnostic` reflects the new plugin set.
/// Errors limited to OOM. On OOM mid-iteration, documents already
/// updated stay updated; the rest keep their previous caches.
pub fn revalidateOpenDocuments(self: *Self) Allocator.Error!void {
    // Two-phase: reparse every doc (fresh trees), then run a single
    // forest revalidation so cross-document references resolve.
    var it = self.documents.iterator();
    while (it.next()) |entry| {
        const doc = entry.value_ptr;
        var tree = try Parser.parse(self.allocator, doc.source);
        errdefer tree.deinit();
        doc.tree.deinit();
        doc.tree = tree;
    }
    try self.revalidateForest();
}

/// The executable-plugin runtime this session can reach, or null when it
/// has none: every wasm build (`sjon-lsp.wasm` declares zero imports and
/// could not call out if it wanted to), a native build without
/// `-Dplugin-exec`, a session with no project loaded, and a project whose
/// plugins shipped no sidecars.
///
/// This is the session's *capability*, read as data rather than as a
/// comptime target check — which is what lets both behaviours be pinned
/// by tests that all compile for the native target.
fn providerRuntime(self: *const Self) ?*anyopaque {
    if (self.project) |*p| return p.runtimeContext();
    return null;
}

/// Release the cross-ref registry and everything whose lifetime is tied
/// to it, in one step.
///
/// `tree_uris` is allocated in `cross_ref_arena`, and `uri_to_tree_idx`'s
/// keys borrow from `tree_uris` — so the arena, the slice, and the map
/// are a single lifetime unit and must never be dropped apart. Splitting
/// them leaves the map probing freed key bytes on the next `get`.
fn dropCrossRefIndex(self: *Self) void {
    if (self.cross_ref_arena) |*ar| ar.deinit();
    self.cross_ref_arena = null;
    self.cross_ref_index = null;
    self.tree_uris = &.{};
    self.uri_to_tree_idx.clearRetainingCapacity();
}

/// The roots of `tree` that are document *data*: everything except its
/// plugin directives (`Host.isPluginDirectiveRoot`).
///
/// Both walks the Handler drives — validation and the defaults overlay —
/// take their roots from here, so the two always describe the same
/// document. That pairing is the whole reason this is a function and not
/// two inline filters.
///
/// Allocates only when the document has directives, which most do not;
/// otherwise it hands back `tree.root` itself. Either way the result is
/// read-only and borrows the tree's node storage.
fn dataRoots(a: Allocator, tree: *const Ast.Tree) Allocator.Error![]const Ast.NodeIndex {
    var directives: usize = 0;
    for (tree.root) |idx| {
        if (Host.isPluginDirectiveRoot(tree, idx)) directives += 1;
    }
    if (directives == 0) return tree.root;

    const out = try a.alloc(Ast.NodeIndex, tree.root.len - directives);
    var i: usize = 0;
    for (tree.root) |idx| {
        if (Host.isPluginDirectiveRoot(tree, idx)) continue;
        out[i] = idx;
        i += 1;
    }
    std.debug.assert(i == out.len);
    return out;
}

/// Run a forest revalidation across every open document, threading a
/// shared cross-ref registry. Each document's cached `validate_result`
/// is replaced; the registry replaces `cross_ref_index`. Documents are
/// fed to `Validator.validateForest` in URI-sorted order so the
/// surviving entry on duplicate-name collisions is deterministic.
///
/// This is also the session's one executable moment: the provider
/// extraction pre-pass runs here, over the same forest and just before
/// it, so provider-backed cross-refs resolve against real extracted
/// names. A session with no runtime (see `providerRuntime`) still runs
/// the pass — it comes back saying `unavailable`, which is what makes the
/// degradation loud instead of silent.
///
/// Empty document set: drops any existing index. OOM: drops the index
/// (lossy but safe — pointers can't dangle into freed-or-replaced
/// trees), per-document caches keep their previous state.
fn revalidateForest(self: *Self) Allocator.Error!void {
    const n = self.documents.count();
    if (n == 0) {
        self.dropCrossRefIndex();
        return;
    }

    const Pair = struct { uri: []const u8, doc: *Document };
    var pairs = try self.allocator.alloc(Pair, n);
    defer self.allocator.free(pairs);

    {
        var i: usize = 0;
        var it = self.documents.iterator();
        while (it.next()) |kv| : (i += 1) {
            pairs[i] = .{ .uri = kv.key_ptr.*, .doc = kv.value_ptr };
        }
    }

    std.mem.sort(Pair, pairs, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return std.mem.lessThan(u8, a.uri, b.uri);
        }
    }.lt);

    var trees = try self.allocator.alloc(Ast.Tree, n);
    defer self.allocator.free(trees);

    // Tree-copy substitution, the same move `Host.validateDocument`
    // makes: the node storage is shared, only the root view differs, so
    // the walk never sees a `(use-plugin …)` header as data. Call-scoped
    // because nothing downstream keeps the slice — `Result` holds an
    // arena and diagnostics, and a cross-ref `Site` records a node
    // index, not a position in this view.
    var roots_arena = std.heap.ArenaAllocator.init(self.allocator);
    defer roots_arena.deinit();
    for (pairs, 0..) |p, i| {
        trees[i] = p.doc.tree;
        trees[i].root = try dataRoots(roots_arena.allocator(), &p.doc.tree);
    }

    // Provider extraction is a pre-pass, in lowering's layer and for
    // lowering's reason: the validator must not be able to execute
    // anything, so everything executable runs ahead of it and hands over
    // a finished table. Content-addressed by `(provider, source)`, so one
    // pass over the whole forest answers every lookup the index pass
    // makes — including the cross-document ones, where a `(shader …)` in
    // one open file is the target of a reference in another.
    //
    // Borrowed for the call only: the index dupes the bytes it keeps, so
    // the table dies at the end of this function while `cross_ref_arena`
    // lives on to the next revalidation.
    var extractions = try Host.extractProviders(
        self.allocator,
        self.schema,
        trees,
        self.providerRuntime(),
    );
    defer extractions.deinit();

    var fr = try Validator.validateForestWithOptions(self.allocator, trees, self.schema, .{
        .extractions = &extractions.map,
    });
    // Past this point validateForest succeeded. The remaining work:
    // dup the URIs into the new index arena (so `tree_uris` borrows
    // from the same lifetime as the index), then hand off results.
    // Dup'ing first leaves the arena consistent if it OOMs.
    const arena_a = fr.index_arena.allocator();
    var new_tree_uris = arena_a.alloc([]const u8, n) catch |err| {
        fr.deinit(self.allocator);
        return err;
    };
    for (pairs, 0..) |p, i| {
        new_tree_uris[i] = arena_a.dupe(u8, p.uri) catch |err| {
            fr.deinit(self.allocator);
            return err;
        };
    }

    for (pairs, 0..) |p, i| {
        p.doc.validate_result.deinit();
        p.doc.validate_result = fr.results[i];
    }
    self.allocator.free(fr.results);

    // Overlays are rebuilt here, after the results land, so every path
    // that refreshes a document's diagnostics (open, change, close,
    // `setUserSchemas`, `reloadProject`) refreshes its defaults too —
    // this function is the single choke point for all of them. A
    // per-document OOM is swallowed for the same reason the index
    // rebuild below tolerates one: a stale overlay costs a wrong inlay
    // hint, while failing the whole revalidation costs every open
    // document its diagnostics.
    for (pairs) |p| self.rebuildMaterialized(p.doc) catch {};

    if (self.cross_ref_arena) |*ar| ar.deinit();
    self.cross_ref_arena = fr.index_arena;
    self.cross_ref_index = fr.cross_ref_index;
    self.tree_uris = new_tree_uris;

    // Rebuild the inverse map from scratch. Keys borrow from the freshly
    // duped `new_tree_uris` slice (same arena that backs `tree_uris`).
    self.uri_to_tree_idx.clearRetainingCapacity();
    try self.uri_to_tree_idx.ensureTotalCapacity(self.allocator, @intCast(n));
    for (new_tree_uris, 0..) |uri, i| {
        self.uri_to_tree_idx.putAssumeCapacityNoClobber(uri, @intCast(i));
    }
}

/// Recompute `doc.materialized` against the current schema, swapping in
/// a fresh arena only once the walk has succeeded (so a failed rebuild
/// leaves the previous overlay intact rather than a half-filled one).
///
/// **The overlay never reaches the validator.** `Validator.Options`
/// takes an `overlays` field (`Validator.EffectiveAxes`) that would make
/// defaulted keys participate in validation — passing this one there is
/// the mistake to avoid. LSP diagnostics must stay byte-identical to
/// what `sjon check` and the conformance corpus produce for the same
/// document; an editor that reports a different set of errors than the
/// build is worse than an editor with no defaults feature. Materialized
/// values exist here for *display and editing assists only*: inlay
/// hints, the materialize-defaults action, and the effective-document
/// view.
///
/// Same reasoning applies to the walk's own diagnostics.
/// `materializeDefaults` emits `default_eval_failed` for every
/// expression default it cannot evaluate — `Host.validateDocument`
/// surfaces those, and this deliberately drops them. A broken default
/// in a *schema* is not an error in the *document* the user is editing,
/// and reporting it against their document would put a diagnostic on a
/// span they cannot fix.
fn rebuildMaterialized(self: *Self, doc: *Document) Allocator.Error!void {
    var fresh: std.heap.ArenaAllocator = .init(self.allocator);
    errdefer fresh.deinit();

    // The same roots the validation walk took, for the reason stated on
    // `dataRoots`: an overlay describing a different document than the
    // diagnostics beside it is the failure to avoid, and the two stay
    // paired by both reading from one place. A `(plugin …)` root has no
    // defaults to materialize in any case — it is a schema, not an
    // instance of one.
    var result = try MaterializedDefaults.materializeDefaults(
        self.allocator,
        fresh.allocator(),
        &doc.tree,
        try dataRoots(fresh.allocator(), &doc.tree),
        self.schema,
    );
    const overlay = result.materialized;
    result.deinit(self.allocator);

    doc.materialized_arena.deinit();
    doc.materialized_arena = fresh;
    doc.materialized = overlay;
}

/// Composition of `loadProject` + `revalidateOpenDocuments`. Call this
/// from `workspace/didChangeWatchedFiles` so a manifest or project-file
/// edit on disk surfaces in every open document's diagnostics.
pub fn reloadProject(self: *Self, io: Io, workspace_root_path: ?[]const u8) Allocator.Error!void {
    try self.loadProject(io, workspace_root_path);
    try self.revalidateOpenDocuments();
}

/// Replace the user-authored schema set and recompose the live schema as
/// `core` + every successfully-loaded manifest, then re-validate open
/// documents so their cached diagnostics reflect the new vocabulary.
///
/// This is the filesystem-free analogue of `loadProject` for hosts that
/// have no project file (the playground): each `SchemaSource.text` is a
/// `(plugin …)` manifest authored in an editor pane. The whole set is
/// replaced on every call — callers always send all panes.
///
/// Returns one `SchemaReport` per source (index-aligned), carrying the
/// schema's parsed `:name` and its own parse/meta diagnostics. Reports
/// and every string they reference live in `arena`. A manifest with
/// error-severity diagnostics contributes no forms but still reports
/// them; valid manifests' forms become known (closed-by-default) in the
/// document's vocabulary.
///
/// Errors are limited to OOM. The schema swap is atomic: on OOM the
/// previous schema set stays installed and untouched.
pub fn setUserSchemas(
    self: *Self,
    arena: Allocator,
    sources: []const SchemaSource,
) Allocator.Error![]const SchemaReport {
    const reports = try arena.alloc(SchemaReport, sources.len);
    var diag_lists = try arena.alloc(std.ArrayList(Diagnostic), sources.len);
    for (diag_lists) |*l| l.* = .empty;

    // Built fresh; only swapped into `self` once every fallible step has
    // succeeded. On any earlier error the errdefer releases the lot and
    // `self` keeps its previous schema set.
    var new_schemas: std.ArrayList(ManifestLoader.Result) = .empty;
    errdefer {
        for (new_schemas.items) |*r| r.deinit();
        new_schemas.deinit(self.allocator);
    }

    for (sources, 0..) |src, i| {
        reports[i] = .{ .uri = try arena.dupe(u8, src.uri), .name = "", .diagnostics = &.{} };
        const kept = try self.loadOneSchema(arena, src, &diag_lists[i]);
        if (kept) |loaded| {
            new_schemas.append(self.allocator, loaded) catch |err| {
                var l = loaded;
                l.deinit();
                return err;
            };
            reports[i].name = try arena.dupe(u8, loaded.plugin.name);
        }
    }

    // Compose: core first, then each kept user plugin. Core's slices
    // point into static memory; user plugins' slices borrow their
    // Result's arena (kept alive in `new_schemas`).
    const composed = try self.allocator.alloc(Plugin.Plugin, 1 + new_schemas.items.len);
    errdefer self.allocator.free(composed);
    composed[0] = sjon.plugins.core.plugin;
    for (new_schemas.items, 0..) |*r, i| composed[i + 1] = r.plugin;

    // Infallible (and panic-free: `loadOneSchema` routes manifests through
    // `ManifestLoader`, which caps form keys at `MAX_FORM_KEYS`, so
    // `assertFormKeyCaps` cannot trip on user input).
    const new_schema = Schema.Schema.init(composed);

    // Aggregate-phase diagnostics — cross-refs, unions, discriminated
    // forms, lowering targets, and expression defaults that only resolve
    // once the whole schema is composed (parity with the native
    // `Host.validateProject` aggregate pass). Attribute each to the
    // authoring schema by matching `path[0]` (the plugin name) against the
    // report names, so a schema author sees feedback about their own
    // manifest's references, not just its structure. The validators
    // allocate from a scratch arena; translated messages are duped into
    // `arena` before it's freed.
    {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const groups = [_][]const Ast.Diagnostic{
            try new_schema.validateCrossRefs(sa),
            try new_schema.validateUnions(sa),
            try new_schema.validateForms(sa),
            try new_schema.validateLowering(sa),
            try new_schema.validateDefaults(sa),
        };
        for (groups) |group| {
            for (group) |d| {
                if (d.path.len == 0) continue;
                for (reports, 0..) |*r, i| {
                    if (r.name.len != 0 and std.mem.eql(u8, r.name, d.path[0])) {
                        try diag_lists[i].append(arena, try translateDupe(arena, d, .plain));
                        break;
                    }
                }
            }
        }
    }

    // Finalize each report's diagnostics — the last fallible step.
    for (reports, 0..) |*r, i| {
        r.diagnostics = try diag_lists[i].toOwnedSlice(arena);
    }

    // Point of no return: swap state in. No `try` past here, so the
    // errdefers above stay scoped to the pre-install failure window.
    self.allocator.free(self.composed_plugins);
    for (self.user_schemas.items) |*r| r.deinit();
    self.user_schemas.deinit(self.allocator);
    self.user_schemas = new_schemas;
    self.composed_plugins = composed;
    self.schema = new_schema;
    self.schema_generation +%= 1;

    // Refresh open-document caches against the new schema — the pull path
    // reads each doc's cached `validate_result`. OOM is non-fatal (mirror
    // of `closeDocument`): the schema is installed; any doc not refreshed
    // keeps its stale cache until its next edit re-validates it.
    self.revalidateOpenDocuments() catch {};

    return reports;
}

/// Parse and load one schema source into a `Plugin`. Appends the
/// schema's own parse + meta-validation diagnostics (translated,
/// span-keyed to `src.text`) into `out`. Returns the loaded `Result` for
/// the caller to keep when the manifest is valid, or `null` when it
/// carries error-severity diagnostics (still reported via `out`) or
/// isn't a `(plugin …)` manifest at all.
fn loadOneSchema(
    self: *Self,
    arena: Allocator,
    src: SchemaSource,
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!?ManifestLoader.Result {
    const text0 = try sentinelDupe(self.allocator, src.text);
    defer self.allocator.free(text0);

    var tree = try Parser.parse(self.allocator, text0);
    defer tree.deinit();

    for (tree.diagnostics) |d| try out.append(arena, try translateDupe(arena, d, .plain));

    var loaded = ManifestLoader.load(self.allocator, tree) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotAPluginManifest => {
            try out.append(arena, .{
                .span_start = 0,
                .span_end = 0,
                .severity = .err,
                .code = @tagName(Ast.Diagnostic.Code.unspecified),
                .message = "a schema must be a single (plugin …) manifest",
                .code_href = codeHref(.unspecified),
            });
            return null;
        },
    };
    errdefer loaded.deinit();

    for (loaded.diagnostics) |d| try out.append(arena, try translateDupe(arena, d, .plain));

    if (loaded.hasErrors()) {
        loaded.deinit();
        return null;
    }
    return loaded;
}

/// Expose the project info (URI, source, diagnostics) so transports can
/// surface workspace-level diagnostics on the project file. Returns null
/// when no project has been loaded or when the workspace has no project
/// file.
pub fn getProjectInfo(self: *const Self) ?*const Host.LoadedProject {
    if (self.project == null) return null;
    return &self.project.?;
}

/// Open a document. If the URI is already open, replaces its state.
/// Triggers a forest revalidation so cross-document references in
/// other open docs reflect the new doc's contents.
pub fn openDocument(self: *Self, uri: []const u8, version: i64, text: []const u8) Allocator.Error!void {
    // An opened URI is `.open` regardless of what it was before, which is
    // what promotes a previously-ingested workspace file rather than
    // duplicating it.
    try self.putDocument(uri, version, text, .open);

    // Revalidation owns the inserted state from this point on.
    try self.revalidateForest();
}

/// Insert or replace one document without revalidating. Shared by
/// `openDocument` and `ingestWorkspaceFiles`: the latter inserts a batch
/// and revalidates the forest once at the end, so the insert had to be
/// separable from the revalidation.
///
/// On any failure the document set is left exactly as it was found — a
/// half-inserted entry would outlive the error and be validated later as
/// if it were real.
fn putDocument(
    self: *Self,
    uri: []const u8,
    version: i64,
    text: []const u8,
    origin: Document.Origin,
) Allocator.Error!void {
    const source = try sentinelDupe(self.allocator, text);
    errdefer self.allocator.free(source);

    var tree = try Parser.parse(self.allocator, source);
    errdefer tree.deinit();

    // Insert the doc with an empty `validate_result` placeholder. The
    // caller's forest revalidation replaces it with the real result.
    var placeholder_arena = std.heap.ArenaAllocator.init(self.allocator);
    errdefer placeholder_arena.deinit();

    const gop = try self.documents.getOrPut(self.allocator, uri);
    if (gop.found_existing) {
        gop.value_ptr.deinit(self.allocator);
    } else {
        errdefer std.debug.assert(self.documents.remove(uri));
        gop.key_ptr.* = try self.allocator.dupe(u8, uri);
    }
    gop.value_ptr.* = .{
        .source = source,
        .version = version,
        .tree = tree,
        .validate_result = .{ .arena = placeholder_arena, .diagnostics = &.{} },
        .materialized_arena = .init(self.allocator),
        .origin = origin,
    };
}

/// Take a batch of on-disk files into the document set, then revalidate
/// the forest once. See `ingestWorkspaceFilesWithCap`; this is that with
/// the shipped ceiling.
pub fn ingestWorkspaceFiles(self: *Self, files: []const WorkspaceFile) Allocator.Error!WorkspaceIngest {
    return self.ingestWorkspaceFilesWithCap(files, MAX_WORKSPACE_FILES);
}

/// As `ingestWorkspaceFiles`, with the file ceiling supplied.
///
/// **Open documents win.** A URI the editor already has open keeps its
/// in-memory text: the buffer is the user's truth and the disk copy is
/// merely the last thing that got saved. Such a file is skipped, not
/// counted, and not overwritten.
///
/// **Clipping is a property of the file set, not of the walk order.**
/// Files are sorted by URI before the cap applies, so the same workspace
/// yields the same subset no matter what order the transport's directory
/// walk produced. The count refused comes back in `clipped` rather than
/// vanishing.
///
/// One revalidation runs at the end, not per file — the forest is
/// cross-document, so validating it n times mid-batch would produce n-1
/// results describing workspaces that never existed.
pub fn ingestWorkspaceFilesWithCap(
    self: *Self,
    files: []const WorkspaceFile,
    cap: usize,
) Allocator.Error!WorkspaceIngest {
    const sorted = try self.allocator.dupe(WorkspaceFile, files);
    defer self.allocator.free(sorted);
    std.mem.sort(WorkspaceFile, sorted, {}, struct {
        fn lt(_: void, a: WorkspaceFile, b: WorkspaceFile) bool {
            return std.mem.lessThan(u8, a.uri, b.uri);
        }
    }.lt);

    var held = self.workspaceDocumentCount();
    var out: WorkspaceIngest = .{ .ingested = 0, .clipped = 0 };
    for (sorted) |f| {
        if (self.documents.getPtr(f.uri)) |doc| {
            // Already present. An open buffer shadows disk; a workspace
            // entry is refreshed in place, which doesn't grow the set.
            if (doc.origin == .open) continue;
        } else if (held >= cap) {
            out.clipped += 1;
            continue;
        } else {
            held += 1;
        }
        try self.putDocument(f.uri, 0, f.source, .workspace);
        out.ingested += 1;
    }

    try self.revalidateForest();

    std.debug.assert(out.ingested + out.clipped <= files.len);
    std.debug.assert(self.workspaceDocumentCount() <= cap);
    return out;
}

fn workspaceDocumentCount(self: *const Self) usize {
    var n: usize = 0;
    var it = self.documents.valueIterator();
    while (it.next()) |doc| {
        if (doc.origin == .workspace) n += 1;
    }
    return n;
}

/// Diagnostics for every document the handler holds — open buffers and
/// ingested workspace files alike — for `workspace/diagnostic`.
///
/// Open documents are included rather than left to
/// `textDocument/diagnostic`. They share one forest and one cache key, so
/// the two requests report the same thing for the same file by
/// construction; excluding them here would instead invent a rule about
/// which request owns which file.
///
/// Sorted by URI: hash iteration order is arbitrary, and a Problems panel
/// that reshuffles between identical pulls is the kind of thing users
/// report as flicker.
pub fn getWorkspaceDiagnostics(
    self: *const Self,
    arena: Allocator,
) Allocator.Error![]const WorkspaceReport {
    const out = try arena.alloc(WorkspaceReport, self.documents.count());
    var i: usize = 0;
    var it = self.documents.iterator();
    while (it.next()) |entry| : (i += 1) {
        const uri = entry.key_ptr.*;
        const doc = entry.value_ptr;
        out[i] = .{
            .uri = uri,
            .version = switch (doc.origin) {
                .open => doc.version,
                .workspace => null,
            },
            .result_id = try self.diagnosticResultId(arena, doc),
            // Non-null: the URI came out of the map being iterated.
            .diagnostics = (try self.getDiagnostics(arena, uri)).?,
        };
    }
    std.debug.assert(i == out.len);

    std.mem.sort(WorkspaceReport, out, {}, struct {
        fn lt(_: void, a: WorkspaceReport, b: WorkspaceReport) bool {
            return std.mem.lessThan(u8, a.uri, b.uri);
        }
    }.lt);
    return out;
}

/// The cache key a client may hand back as `previousResultId`.
///
/// Both halves have to move for the short-circuit to be safe, and *what*
/// the first half is depends on the origin. An open document is keyed on
/// its client-supplied version — the editor bumps it on every keystroke,
/// and both diagnostic requests must derive the same string from it. A
/// workspace file has no version at all: it changes when someone edits it
/// outside the editor, so it is keyed on a hash of its content. Keying it
/// on a placeholder version would make every disk edit look unchanged and
/// leave stale errors on screen.
pub fn diagnosticResultId(
    self: *const Self,
    arena: Allocator,
    doc: *const Document,
) Allocator.Error![]const u8 {
    return switch (doc.origin) {
        .open => std.fmt.allocPrint(arena, "{d}:{d}", .{ doc.version, self.schema_generation }),
        .workspace => std.fmt.allocPrint(
            arena,
            "h{x}:{d}",
            .{ std.hash.Wyhash.hash(0, doc.source), self.schema_generation },
        ),
    };
}

/// Replace the source of an open document with `new_text` and re-validate.
/// Caller has already merged any incremental change ranges into `new_text`.
/// Also runs a forest revalidation so cross-document references in
/// every open doc reflect the new content of `uri`.
pub fn changeDocumentFull(self: *Self, uri: []const u8, version: i64, new_text: []const u8) Error!void {
    const entry = self.documents.getPtr(uri) orelse return error.UnknownDocument;

    const source = try sentinelDupe(self.allocator, new_text);
    errdefer self.allocator.free(source);

    var tree = try Parser.parse(self.allocator, source);
    errdefer tree.deinit();

    var placeholder_arena = std.heap.ArenaAllocator.init(self.allocator);
    errdefer placeholder_arena.deinit();

    entry.deinit(self.allocator);
    entry.* = .{
        .source = source,
        .version = version,
        .tree = tree,
        .validate_result = .{ .arena = placeholder_arena, .diagnostics = &.{} },
        .materialized_arena = .init(self.allocator),
    };

    try self.revalidateForest();
}

pub fn closeDocument(self: *Self, uri: []const u8) void {
    const entry = self.documents.fetchRemove(uri) orelse return;
    self.allocator.free(entry.key);
    var doc = entry.value;
    doc.deinit(self.allocator);

    // The closed doc's tree just went away. Any borrowed strings the
    // cross-ref index held into that tree are now dangling — drop the
    // index unconditionally, then attempt to rebuild it across the
    // remaining docs. OOM during rebuild leaves the index null;
    // remaining docs keep their previous validate_result, so they
    // miss cross-doc updates until the next successful revalidation.
    //
    // All four fields move as one lifetime unit: `tree_uris` lives in
    // `cross_ref_arena` and `uri_to_tree_idx`'s keys borrow from
    // `tree_uris`, so freeing the arena without clearing the map leaves
    // it holding keys into freed memory — and a `get` probe compares
    // against those freed bytes. `revalidateForest` only repopulates
    // them on its success path, and its failure here is swallowed.
    self.dropCrossRefIndex();
    self.revalidateForest() catch {};
}

pub fn getDocument(self: *const Self, uri: []const u8) ?*const Document {
    return self.documents.getPtr(uri);
}

/// Build the diagnostic list for `uri`. Returns null when the document
/// isn't open. The result is allocated in `arena` so the transport can
/// scope its lifetime to the request.
pub fn getDiagnostics(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
) Allocator.Error!?[]const Diagnostic {
    const doc = self.getDocument(uri) orelse return null;

    const parse_diags = doc.tree.diagnostics;
    const validate_diags = doc.validate_result.diagnostics;
    const total = parse_diags.len + validate_diags.len;
    var out = try arena.alloc(Diagnostic, total);
    // The session's capability, read once for the whole document: every
    // diagnostic in one report is graded against the same host.
    const mode = self.presentation();
    var i: usize = 0;
    for (parse_diags) |d| {
        out[i] = translate(d, mode);
        i += 1;
    }
    for (validate_diags) |d| {
        out[i] = translate(d, mode);
        // Enrichment is a post-translate pass rather than part of
        // `translate`: it needs an allocator, the document, and the
        // Handler's schema + cross-ref index, none of which the pure
        // code→shape mapping has. Parse diagnostics are skipped — every
        // derivable relation is a validation-level one.
        out[i].related = try self.relatedFor(arena, doc, uri, d);
        i += 1;
    }
    return out;
}

/// Related locations for one validation diagnostic, or an empty slice
/// when the code has no derivable relation (the common case).
///
/// Every derivation reads only what the Handler already holds — the
/// document's tree, the schema, and the forest cross-ref index. Nothing
/// is re-validated, and `Ast.Diagnostic` is not extended: the wire-stable
/// core stays out of the editor-presentation business.
fn relatedFor(
    self: *const Self,
    arena: Allocator,
    doc: *const Document,
    uri: []const u8,
    d: Ast.Diagnostic,
) Allocator.Error![]const Diagnostic.Related {
    return switch (d.code) {
        .duplicate_key => try duplicateKeyRelated(arena, doc, uri, d.span),
        .mutually_exclusive_keys_present => try self.exclusiveGroupRelated(arena, doc, uri, d.span),
        // `cross_ref_outside_scope` is deliberately absent: its match
        // arm returns before `appendReference`, so the offending
        // reference is never registered in the index and the Handler
        // would have to re-derive the scope chain to say anything
        // useful. `not_cross_ref` does register (typo'd references are
        // still reference sites), which is what makes this derivable.
        .not_cross_ref => try self.crossRefRelated(arena, uri, d.span),
        else => &.{},
    };
}

/// `duplicate_key` fires on the *second* occurrence's key span. Walk the
/// enclosing form for the first kvpair carrying the same key and point
/// there — the pair is what makes the error readable.
fn duplicateKeyRelated(
    arena: Allocator,
    doc: *const Document,
    uri: []const u8,
    span: Ast.Span,
) Allocator.Error![]const Diagnostic.Related {
    const tree = &doc.tree;
    const form_idx = findEnclosingFormIdx(tree, span.start) orelse return &.{};
    const dup_idx = findEnclosingKvpairIdx(tree, span.start) orelse return &.{};
    const dup_key = tree.kvpairHeader(dup_idx).key;

    for (tree.formHeader(form_idx).children) |child| {
        if (tree.tagOf(child) != .kvpair) continue;
        const kv = tree.kvpairHeader(child);
        // Stop at the diagnostic's own kvpair: anything at or past it is
        // the duplicate itself, not the occurrence it duplicates.
        if (kv.key_span.start == span.start) break;
        if (!std.mem.eql(u8, kv.key, dup_key)) continue;
        return try oneRelated(arena, uri, kv.key_span, try std.fmt.allocPrint(
            arena,
            ":{s} is first defined here",
            .{dup_key},
        ));
    }
    return &.{};
}

/// `mutually_exclusive_keys_present` anchors on the form, not on any one
/// key — so on its own it tells the reader *that* two alternatives
/// collided without showing which. Point at each present alternative's
/// key span.
fn exclusiveGroupRelated(
    self: *const Self,
    arena: Allocator,
    doc: *const Document,
    uri: []const u8,
    span: Ast.Span,
) Allocator.Error![]const Diagnostic.Related {
    const tree = &doc.tree;
    const form_idx = findEnclosingFormIdx(tree, span.start) orelse return &.{};
    const hdr = tree.formHeader(form_idx);
    const hit = switch (self.schema.lookupForm(hdr.head, hdr.namespace)) {
        .found => |f| f,
        // An ambiguous or unknown head has no single exclusive-group set
        // to read; the validator wouldn't have reached this code either.
        .not_found, .ambiguous => return &.{},
    };

    var out: std.ArrayList(Diagnostic.Related) = .empty;
    for (hit.form.exclusive_groups) |group| {
        for (group.alternatives) |alt| {
            for (alt.keys) |key_name| {
                const kv = findKvpairByKey(tree, hdr, key_name) orelse continue;
                try out.append(arena, .{
                    .uri = uri,
                    .span_start = kv.key_span.start,
                    .span_end = kv.key_span.end,
                    .message = try std.fmt.allocPrint(arena, ":{s} is present here", .{key_name}),
                });
            }
        }
    }
    // One present alternative is not a conflict; the validator only fires
    // this code at two or more, so a single hit means the walk missed
    // something and a lone "is present here" would read as an accusation.
    if (out.items.len < 2) return &.{};
    return out.items;
}

/// Candidate definitions for an unresolved cross-reference: registered
/// names close enough to the typo that `DidYouMean` would suggest them.
///
/// Bounded to the reference's own scope. Scope is per-tree, so a
/// same-named definition in another document is *not* a candidate —
/// jumping there would show the user a definition that this reference
/// cannot reach, and accepting the implied fix would leave the error in
/// place.
fn crossRefRelated(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    span: Ast.Span,
) Allocator.Error![]const Diagnostic.Related {
    const index = if (self.cross_ref_index) |*ix| ix else return &.{};
    const tree_idx = self.uri_to_tree_idx.get(uri) orelse return &.{};
    // The failing reference is in the index: `matchValueAgainstKind`
    // records the site before it checks resolvability.
    const site = locateCrossRefSite(index, tree_idx, span) orelse return &.{};
    if (site.is_definition) return &.{};

    var names: std.ArrayList([]const u8) = .empty;
    var it = index.iterateNames(site.scope, site.target);
    while (it.next()) |entry| try names.append(arena, entry.key_ptr.*);
    if (names.items.len == 0) return &.{};

    const suggestions = try DidYouMean.suggest(arena, site.name, names.items, MAX_RELATED_CANDIDATES);
    var out: std.ArrayList(Diagnostic.Related) = .empty;
    for (suggestions) |s| {
        const def = index.lookup(site.scope, site.target, s.name) orelse continue;
        std.debug.assert(def.tree_idx < self.tree_uris.len);
        try out.append(arena, .{
            .uri = self.tree_uris[def.tree_idx],
            .span_start = def.name_span.start,
            .span_end = def.name_span.end,
            .message = try std.fmt.allocPrint(arena, "did you mean '{s}', defined here?", .{s.name}),
        });
    }
    return out.items;
}

/// How many "did you mean" definitions a cross-ref diagnostic offers.
/// Three is the point past which a related-information list stops
/// reading as a suggestion and starts reading as a search result.
const MAX_RELATED_CANDIDATES: usize = 3;

/// Single-element `Related` slice — the shape most derivations return.
fn oneRelated(
    arena: Allocator,
    uri: []const u8,
    span: Ast.Span,
    message: []const u8,
) Allocator.Error![]const Diagnostic.Related {
    const out = try arena.alloc(Diagnostic.Related, 1);
    out[0] = .{
        .uri = uri,
        .span_start = span.start,
        .span_end = span.end,
        .message = message,
    };
    return out;
}

/// The first kvpair directly under `hdr` whose key is `key_name`.
fn findKvpairByKey(
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    key_name: []const u8,
) ?Ast.KvPairHeader {
    for (hdr.children) |child| {
        if (tree.tagOf(child) != .kvpair) continue;
        const kv = tree.kvpairHeader(child);
        if (std.mem.eql(u8, kv.key, key_name)) return kv;
    }
    return null;
}

/// Build the hover payload for the token at `byte_offset` in `uri`.
/// Returns null when there's no hover content (cursor outside any node,
/// on whitespace, or on a token without registered metadata).
pub fn getHover(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    byte_offset: u32,
) Allocator.Error!?Hover {
    const doc = self.getDocument(uri) orelse return null;
    const ctx = findHoverContext(&doc.tree, byte_offset) orelse return null;

    var buf: std.ArrayList(u8) = .empty;
    const base = switch (ctx) {
        .form_head => |fh| try self.renderHeadHover(arena, &buf, fh.hdr),
        .kvpair_key => |kk| try self.renderKvpairHover(arena, &buf, kk),
        .member_value => |mv| try self.renderMemberValueHover(arena, &buf, mv),
    } orelse return null;

    const with_value = try self.appendEvaluatedValue(arena, base, uri, byte_offset);
    return try appendExplanations(arena, with_value, doc, byte_offset);
}

/// Longest rendered value a hover shows before eliding. A hover is a
/// glance; the full value is the output panel's job. Pinned rather than
/// tuned — the truncation test asserts against this exact number, so
/// changing it is a deliberate edit and not a drift.
pub const MAX_HOVER_VALUE_BYTES: usize = 120;

/// Append `**=** \`<value>\`` when the cursor sits in an evaluable
/// expression. Returns `base` untouched otherwise — `evalExpressionAt`
/// already folds every "can't" into null.
///
/// Placed above the diagnostic explanations so the two orderings agree
/// about specificity: schema (what this *is*), value (what it *computes
/// to*), then problems. In practice they barely co-occur — a diagnostic
/// covering the cursor also covers the expression around it, which is
/// what makes the value null.
fn appendEvaluatedValue(
    self: *const Self,
    arena: Allocator,
    base: Hover,
    uri: []const u8,
    byte_offset: u32,
) Allocator.Error!Hover {
    const value = try self.evalExpressionAt(arena, uri, byte_offset, LSP_EVAL_BYTES) orelse return base;

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, std.mem.trimEnd(u8, base.contents, "\n"));
    try buf.appendSlice(arena, "\n\n**=** ");
    try appendCodeSpan(arena, &buf, truncateOnBoundary(value, MAX_HOVER_VALUE_BYTES));
    if (value.len > MAX_HOVER_VALUE_BYTES) try buf.appendSlice(arena, " …");

    return .{
        .contents = try buf.toOwnedSlice(arena),
        .span_start = base.span_start,
        .span_end = base.span_end,
    };
}

/// `s` cut to at most `max` bytes without splitting a UTF-8 sequence.
/// Rendered values embed the document's own string literals, so the cut
/// lands mid-codepoint the moment anyone writes a non-ASCII string — and
/// a hover carrying half a codepoint is a mojibake bug in every client at
/// once.
fn truncateOnBoundary(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    // Continuation bytes are 0b10xxxxxx; back off until `end` indexes a
    // leading byte. Bounded by the 4-byte maximum sequence length.
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

/// Append `s` as a markdown code span, fenced with enough backticks that
/// `s`'s own can't close it early (CommonMark's rule) and space-padded
/// when it starts or ends with one.
///
/// Hover contents are markdown and this one is built from document
/// content — a computed string carrying `**` or a link would otherwise
/// render as markup in every client. The code span makes the value inert
/// text, which is what it is.
fn appendCodeSpan(arena: Allocator, buf: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    var longest_run: usize = 0;
    var run: usize = 0;
    for (s) |c| {
        if (c == '`') {
            run += 1;
            longest_run = @max(longest_run, run);
        } else run = 0;
    }
    const fence = longest_run + 1;
    const pad = s.len > 0 and (s[0] == '`' or s[s.len - 1] == '`');

    try buf.appendNTimes(arena, '`', fence);
    if (pad) try buf.append(arena, ' ');
    try buf.appendSlice(arena, s);
    if (pad) try buf.append(arena, ' ');
    try buf.appendNTimes(arena, '`', fence);
}

/// How many diagnostic explanations one hover will carry.
///
/// Defensive rather than routinely exercised: the validator anchors each
/// diagnostic on a tight span (`missing_required_key` on the head token,
/// `unknown_key` on the key token) and stops descending once a container
/// fails, so two diagnostics containing the same offset is already
/// unusual. The bound exists so that if it ever happens the hover stays
/// a hover instead of becoming a diagnostics list.
const MAX_HOVER_EXPLANATIONS: usize = 2;

/// Append `**<code>** — <short explanation>` for each diagnostic whose
/// span contains the cursor, under a rule, capped at
/// `MAX_HOVER_EXPLANATIONS`.
///
/// This is what makes "hover tells me why" work in every editor with no
/// client support: `codeDescription` needs a client that follows links
/// and `data` needs one that reads it, but every LSP client renders
/// hover markdown.
///
/// Innermost first — diagnostics are sorted by span width so the most
/// specific explanation survives the cap. Prose comes from
/// `sjon.Explanations`, the same table `sjon explain` prints, so the CLI
/// and the editor can't describe a code differently.
fn appendExplanations(
    arena: Allocator,
    base: Hover,
    doc: *const Document,
    pos: u32,
) Allocator.Error!Hover {
    var hits: std.ArrayList(Ast.Diagnostic) = .empty;
    for (doc.validate_result.diagnostics) |d| {
        if (containsOffset(d.span, pos)) try hits.append(arena, d);
    }
    for (doc.tree.diagnostics) |d| {
        if (containsOffset(d.span, pos)) try hits.append(arena, d);
    }
    if (hits.items.len == 0) return base;

    std.mem.sort(Ast.Diagnostic, hits.items, {}, struct {
        fn narrower(_: void, a: Ast.Diagnostic, b: Ast.Diagnostic) bool {
            return (a.span.end - a.span.start) < (b.span.end - b.span.start);
        }
    }.narrower);

    var buf: std.ArrayList(u8) = .empty;
    // Trailing newlines from the schema section would stack with the
    // separator's own, opening a visible gap above the rule.
    try buf.appendSlice(arena, std.mem.trimEnd(u8, base.contents, "\n"));
    const shown = @min(hits.items.len, MAX_HOVER_EXPLANATIONS);
    for (hits.items[0..shown]) |d| {
        const name = @tagName(d.code);
        try buf.appendSlice(arena, "\n\n---\n\n**");
        try buf.appendSlice(arena, name);
        try buf.append(arena, '*');
        try buf.append(arena, '*');
        // Every variant has an entry — `Explanations`' completeness test
        // is a build gate — but a missing one degrades to the bare code
        // rather than dropping the section.
        if (sjon.Explanations.lookup(name)) |e| {
            try buf.appendSlice(arena, " — ");
            try buf.appendSlice(arena, e.short);
        }
    }

    return .{
        .contents = try buf.toOwnedSlice(arena),
        .span_start = base.span_start,
        .span_end = base.span_end,
    };
}

// ---------------------------------------------------------------------------
// Evaluated values
// ---------------------------------------------------------------------------

/// Result-arena byte budget for LSP-initiated evaluation — deliberately far
/// below `Expr.MAX_EVAL_BYTES` (64 MiB).
///
/// `Expr` is deterministic and sandboxed, so evaluating on the editor's
/// behalf is safe by construction; the only cost the editor can feel is
/// latency, and this is what caps it. A hover that computes nothing is a
/// missing tooltip, while a hover that stalls the request loop is a
/// broken editor — so the budget is sized for "the expressions people
/// actually write in a document," not for the largest an expression may be.
pub const LSP_EVAL_BYTES: usize = 4 << 20; // 4 MiB

/// Evaluate the expression enclosing `byte_offset` and render its value as
/// SJON source text, or null when there is nothing to evaluate.
///
/// Null — never an error — is the answer for every "can't": the cursor is
/// not in an expression, the expression or its document carries
/// diagnostics, or evaluation failed (unimplemented plugin func, type
/// mismatch, budget/step/depth ceiling). An editor affordance that
/// sometimes reports an error the diagnostics pass didn't raise is worse
/// than one that quietly shows nothing. `OutOfMemory` still propagates:
/// that is the host failing, not the expression.
///
/// The evaluated node is the **outermost** enclosing expression, not the
/// innermost. `(let [x 2] (* x 3))` with the cursor on `x` must evaluate
/// the `let` — the inner `(* x 3)` is not independently meaningful, since
/// the binding it needs lives in its parent. The walk stops at the first
/// non-expression ancestor, so an expression nested in a data form
/// (`(scene :fps (+ 1 2))`) evaluates the expression and not the form.
///
/// `byte_budget` is a parameter rather than a constant so tests can drive
/// the `MemoryBudgetExceeded` path with a small cap; callers pass
/// `LSP_EVAL_BYTES`.
pub fn evalExpressionAt(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    byte_offset: u32,
    byte_budget: usize,
) Allocator.Error!?[]const u8 {
    const doc = self.getDocument(uri) orelse return null;
    const root = self.exprRootAt(&doc.tree, doc.source, byte_offset) orelse return null;
    var used: usize = 0;
    return switch (try self.evalRoot(arena, doc, root, byte_budget, &used)) {
        .value => |v| v,
        .failure => null,
    };
}

/// One evaluated expression root. `span_*` are byte offsets into the
/// document source, as everywhere else in this API.
pub const EvalEntry = struct {
    span_start: u32,
    span_end: u32,
    outcome: Outcome,

    /// Exactly one of the two, which is why this is a union and not a
    /// value/error pair with a "check the other one" rule.
    pub const Outcome = union(enum) {
        /// Rendered as SJON source, the same text hover shows.
        value: []const u8,
        failure: Failure,
    };

    /// Why a root has no value. Closed and small on purpose: each variant
    /// is a *different thing for the reader to do*, and a set that splits
    /// finer than that would leak evaluator internals into a wire shape.
    /// Tag names are the wire identifiers — append, never rename.
    pub const Failure = enum {
        /// The expression (or something overlapping it) has diagnostics.
        /// Fix those; the value is meaningless until then.
        invalid,
        /// Declared by a plugin but not implemented in this server — a
        /// `:impl "wasm:…"` func with no runtime loaded, or a
        /// declaration-only one. Nothing about the document is wrong.
        unsupported,
        /// Hit a resource ceiling (byte budget, frame depth, step count).
        /// The document is fine; the answer is just too expensive here.
        limit,
        /// Evaluated and raised — type mismatch, division by zero, arity,
        /// unbound name. The expression is wrong in a way the validator
        /// did not catch.
        failed,
    };
};

/// Whole-document ceiling for `evalDocument`, shared across every root.
///
/// Per-root budgets don't compose: a document with N expensive
/// expressions would cost N × `LSP_EVAL_BYTES` for a single request, and
/// documents are allowed to be long. Roots are served in document order
/// until the shared pool runs out; the rest report `.limit`.
pub const LSP_EVAL_DOC_BYTES: usize = 16 << 20; // 16 MiB

/// Evaluate every expression root in `uri`. Null when the URI isn't open.
///
/// A **root** is a maximal expression: one whose enclosing form is not
/// itself an expression. That includes expressions nested in data forms —
/// `(scene :fps (+ 1 2))` yields one entry, for the `(+ 1 2)`. Restricting
/// to document-level expressions would report nothing for almost every
/// real file, since real files are data forms with expressions inside.
///
/// Entries come back in document order. Consumers render them beside the
/// source, and an order that tracked node-storage layout instead would be
/// stable but arbitrary.
pub fn evalDocument(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
) Allocator.Error!?[]const EvalEntry {
    return self.evalDocumentWithBudget(arena, uri, LSP_EVAL_DOC_BYTES);
}

/// `evalDocument` with the shared pool as a parameter, so tests can drive
/// the exhaustion path without building a 16 MiB document.
pub fn evalDocumentWithBudget(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    byte_budget: usize,
) Allocator.Error!?[]const EvalEntry {
    const doc = self.getDocument(uri) orelse return null;

    var roots: std.ArrayList(Ast.NodeIndex) = .empty;
    defer roots.deinit(self.allocator);
    const tags = doc.tree.nodes.items(.tag);
    var i: u32 = 0;
    while (i < tags.len) : (i += 1) {
        if (tags[i] != .form) continue;
        const idx = Ast.NodeIndex.from(i);
        if (!self.isExprForm(&doc.tree, idx)) continue;
        if (findParentFormIdx(&doc.tree, idx)) |parent| {
            // Not maximal — its value is reported by the ancestor that
            // encloses it, so reporting it too would double-count.
            if (self.isExprForm(&doc.tree, parent)) continue;
        }
        try roots.append(self.allocator, idx);
    }

    std.mem.sort(Ast.NodeIndex, roots.items, &doc.tree, struct {
        fn earlier(tree: *const Ast.Tree, a: Ast.NodeIndex, b: Ast.NodeIndex) bool {
            return tree.spanOf(a).start < tree.spanOf(b).start;
        }
    }.earlier);

    var entries = try arena.alloc(EvalEntry, roots.items.len);
    var remaining = byte_budget;
    for (roots.items, 0..) |idx, n| {
        var used: usize = 0;
        const outcome = try self.evalRoot(arena, doc, idx, @min(remaining, LSP_EVAL_BYTES), &used);
        remaining -= @min(remaining, used);
        const span = doc.tree.spanOf(idx);
        entries[n] = .{ .span_start = span.start, .span_end = span.end, .outcome = outcome };
    }
    return entries;
}

/// Evaluate one already-located root. Writes the result arena's high-water
/// capacity to `used_out` so a caller serving several roots can spend one
/// pool across them; a root that produced no value spent nothing.
fn evalRoot(
    self: *const Self,
    arena: Allocator,
    doc: *const Document,
    root: Ast.NodeIndex,
    byte_budget: usize,
    used_out: *usize,
) Allocator.Error!EvalEntry.Outcome {
    used_out.* = 0;
    if (overlapsAnyDiagnostic(doc, doc.tree.spanOf(root))) return .{ .failure = .invalid };
    if (byte_budget == 0) return .{ .failure = .limit };

    const empty_env: Expr.Env = .{};
    var result = Expr.evalWithRuntimeBudget(
        self.allocator,
        &doc.tree,
        root,
        &empty_env,
        self.schema,
        // No plugin runtime: the native server does not load one and the
        // WASM server cannot. A `:impl "wasm:…"` func therefore raises
        // `PluginFuncNotImplemented` and the whole expression declines.
        null,
        .{ .bytes = byte_budget },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MemoryBudgetExceeded, error.DepthExceeded => return .{ .failure = .limit },
        error.PluginFuncNotImplemented,
        error.PluginFuncResultType,
        error.PluginFuncFailed,
        error.PluginFuncTrapped,
        error.PluginFuncAllocFailed,
        => return .{ .failure = .unsupported },
        else => return .{ .failure = .failed },
    };
    defer result.deinit();
    used_out.* = result.arena.queryCapacity();

    var buf: std.ArrayList(u8) = .empty;
    // The `faithful` flag is for insertion sites (`materialize defaults`),
    // which must not write an approximation back into the document.
    // Display is exactly the case the approximation was written for.
    _ = try sjon.EffectiveDocument.appendExprValue(arena, &buf, result.value, 0);
    return .{ .value = try buf.toOwnedSlice(arena) };
}

/// The outermost expression enclosing `pos`, or null when `pos` is not
/// inside one. Walks up from the smallest enclosing form while each
/// successive parent is itself an expression.
fn exprRootAt(
    self: *const Self,
    tree: *const Ast.Tree,
    source: []const u8,
    pos: u32,
) ?Ast.NodeIndex {
    var idx = findEnclosingDelimIdxAtCursor(tree, source, pos, .form) orelse return null;
    if (!self.isExprForm(tree, idx)) return null;
    while (findParentFormIdx(tree, idx)) |parent| {
        if (!self.isExprForm(tree, parent)) break;
        idx = parent;
    }
    return idx;
}

/// Does this form's head name an expression function? Data forms shadow
/// expr funcs on a name collision, matching `renderHeadHover`'s lookup
/// order — one name resolves the same way everywhere or hover and
/// evaluation would disagree about what the document says. An ambiguous
/// head resolves to nothing: the evaluator would raise
/// `AmbiguousFunction` anyway, and refusing here keeps the walk from
/// climbing through a node no one can evaluate.
fn isExprForm(self: *const Self, tree: *const Ast.Tree, idx: Ast.NodeIndex) bool {
    const hdr = tree.formHeader(idx);
    if (hdr.head.len == 0) return false;
    switch (self.schema.lookupForm(hdr.head, hdr.namespace)) {
        .found, .ambiguous => return false,
        .not_found => {},
    }
    return switch (self.schema.lookupExprFunc(hdr.head, hdr.namespace)) {
        .found => true,
        .not_found, .ambiguous => false,
    };
}

/// Does any parse or validation diagnostic touch `span`?
///
/// The gate on evaluating. Broken code is not merely un-evaluable — it is
/// worse, because parser recovery makes a lot of it *look* evaluable:
/// `(+ 1 2` recovers to a complete form and would report `3` for an
/// expression the author has not finished writing. Both diagnostic lists
/// are consulted, the same pair `appendExplanations` reads.
fn overlapsAnyDiagnostic(doc: *const Document, span: Ast.Span) bool {
    for (doc.tree.diagnostics) |d| {
        if (diagnosticTouches(d.span, span)) return true;
    }
    for (doc.validate_result.diagnostics) |d| {
        if (diagnosticTouches(d.span, span)) return true;
    }
    return false;
}

/// Does the diagnostic at `d` concern the node spanning `span`?
///
/// Half-open intersection, with one carve-out: a **zero-width** `d` means
/// "something is missing *here*", and the thing missing from `(+ 1 2` is
/// its closing paren — which the parser anchors at offset 6, exactly
/// `span.end` of the form it recovered (`0..6`). Half-open intersection
/// alone reports no overlap there, so the point case tests inclusively at
/// both ends. A *non*-empty diagnostic starting at `span.end` stays
/// outside: the stray `)` in `(+ 1 2))` is a separate defect, and the
/// complete expression before it is still worth evaluating.
fn diagnosticTouches(d: Ast.Span, span: Ast.Span) bool {
    if (d.start == d.end) return d.start >= span.start and d.start <= span.end;
    return d.start < span.end and span.start < d.end;
}

const HoverContext = union(enum) {
    form_head: struct { hdr: Ast.FormHeader },
    kvpair_key: struct {
        parent_head: []const u8,
        parent_namespace: ?[]const u8,
        kv: Ast.KvPairHeader,
    },
    /// Cursor sits on a symbol or string value of a kvpair whose
    /// declared key resolves to a `(member-set …)`-typed slot. Hover
    /// renders the matched `Member`'s label / description /
    /// deprecation hint when one matches by byte-equality.
    member_value: struct {
        parent_head: []const u8,
        parent_namespace: ?[]const u8,
        key_name: []const u8,
        text: []const u8,
        span: Ast.Span,
    },
};

/// Locate the most specific hover context at `pos`. Cursor on a form's
/// head identifier yields `.form_head`; cursor on a kvpair's `:key`
/// (with the enclosing form known) yields `.kvpair_key`. Cursor inside a
/// form but off any meaningful sub-token falls back to the enclosing
/// form's head — a hover on `(scene| )` still shows scene info.
fn findHoverContext(tree: *const Ast.Tree, pos: u32) ?HoverContext {
    for (tree.root) |idx| {
        if (containsOffset(tree.spanOf(idx), pos)) {
            return descendForHover(tree, idx, pos, null, null);
        }
    }
    return null;
}

fn descendForHover(
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    pos: u32,
    parent_head: ?[]const u8,
    parent_ns: ?[]const u8,
) ?HoverContext {
    switch (tree.tagOf(idx)) {
        .form => {
            const hdr = tree.formHeader(idx);
            if (containsOffset(hdr.head_span, pos)) {
                return .{ .form_head = .{ .hdr = hdr } };
            }
            for (hdr.children) |child| {
                if (containsOffset(tree.spanOf(child), pos)) {
                    return descendForHover(tree, child, pos, hdr.head, hdr.namespace);
                }
            }
            return .{ .form_head = .{ .hdr = hdr } };
        },
        .vector => {
            for (tree.vectorElements(idx)) |child| {
                if (containsOffset(tree.spanOf(child), pos)) {
                    return descendForHover(tree, child, pos, parent_head, parent_ns);
                }
            }
            return null;
        },
        .kvpair => {
            const kv = tree.kvpairHeader(idx);
            if (containsOffset(kv.key_span, pos)) {
                if (parent_head) |ph| {
                    return .{ .kvpair_key = .{
                        .parent_head = ph,
                        .parent_namespace = parent_ns,
                        .kv = kv,
                    } };
                }
                return null;
            }
            if (containsOffset(tree.spanOf(kv.value), pos)) {
                // Symbol/string leaf in a kvpair value position: surface
                // as a `member_value` hover so the renderer can resolve
                // against the declared key's MemberSet (if any). Other
                // value shapes (forms, vectors, numbers) recurse as
                // before.
                const value_tag = tree.tagOf(kv.value);
                if ((value_tag == .symbol or value_tag == .string) and parent_head != null) {
                    const text = if (value_tag == .symbol)
                        tree.symbolText(kv.value)
                    else
                        tree.stringText(kv.value);
                    return .{ .member_value = .{
                        .parent_head = parent_head.?,
                        .parent_namespace = parent_ns,
                        .key_name = kv.key,
                        .text = text,
                        .span = tree.spanOf(kv.value),
                    } };
                }
                return descendForHover(tree, kv.value, pos, parent_head, parent_ns);
            }
            return null;
        },
        else => return null,
    }
}

fn containsOffset(span: Ast.Span, pos: u32) bool {
    return pos >= span.start and pos < span.end;
}

fn renderHeadHover(
    self: *const Self,
    arena: Allocator,
    buf: *std.ArrayList(u8),
    hdr: Ast.FormHeader,
) Allocator.Error!?Hover {
    if (hdr.head.len == 0) return null;

    const form_lookup = self.schema.lookupForm(hdr.head, hdr.namespace);
    switch (form_lookup) {
        .found => |hit| {
            try renderFormSpec(arena, buf, self.schema, hit, hdr);
            return .{
                .contents = try buf.toOwnedSlice(arena),
                .span_start = hdr.head_span.start,
                .span_end = hdr.head_span.end,
            };
        },
        .ambiguous => |amb| {
            try renderAmbiguousHead(arena, buf, hdr, amb, .form);
            return .{
                .contents = try buf.toOwnedSlice(arena),
                .span_start = hdr.head_span.start,
                .span_end = hdr.head_span.end,
            };
        },
        .not_found => {},
    }

    const expr_lookup = self.schema.lookupExprFunc(hdr.head, hdr.namespace);
    switch (expr_lookup) {
        .found => |hit| {
            try renderExprFunc(arena, buf, hit, hdr);
            return .{
                .contents = try buf.toOwnedSlice(arena),
                .span_start = hdr.head_span.start,
                .span_end = hdr.head_span.end,
            };
        },
        .ambiguous => |amb| {
            try renderAmbiguousHead(arena, buf, hdr, amb, .expr);
            return .{
                .contents = try buf.toOwnedSlice(arena),
                .span_start = hdr.head_span.start,
                .span_end = hdr.head_span.end,
            };
        },
        .not_found => return null,
    }
}

fn renderKvpairHover(
    self: *const Self,
    arena: Allocator,
    buf: *std.ArrayList(u8),
    kk: anytype,
) Allocator.Error!?Hover {
    const form_lookup = self.schema.lookupForm(kk.parent_head, kk.parent_namespace);
    const hit = switch (form_lookup) {
        .found => |h| h,
        else => return null,
    };
    if (hit.form.keyByName(kk.kv.key)) |key| {
        try renderKeySpec(arena, buf, self.schema, hit, key, kk.kv);
        return .{
            .contents = try buf.toOwnedSlice(arena),
            .span_start = kk.kv.key_span.start,
            .span_end = kk.kv.key_span.end,
        };
    }
    return null;
}

fn renderMemberValueHover(
    self: *const Self,
    arena: Allocator,
    buf: *std.ArrayList(u8),
    mv: anytype,
) Allocator.Error!?Hover {
    const form_lookup = self.schema.lookupForm(mv.parent_head, mv.parent_namespace);
    const hit = switch (form_lookup) {
        .found => |h| h,
        else => return null,
    };
    const key = hit.form.keyByName(mv.key_name) orelse return null;
    const vt = key.value_type;
    const named = switch (vt) {
        .named => |n| n,
        else => return null,
    };
    const kind_lookup = self.schema.lookupValueKind(named.name, named.namespace);
    const kind = switch (kind_lookup) {
        .found => |k| k,
        else => return null,
    };
    // A kind may carry both a member set and a cross-ref; a matched
    // member is the more specific answer (it has a label/description),
    // so the cross-ref rendering at the tail is the fallback, not a
    // rival — it also covers a cross-ref value that resolves to nothing,
    // where saying what *would* count is exactly what the hover is for.
    const m = kind.members orelse sjon.Plugin.ValueKind.MemberSet{ .members = &.{} };
    for (m.members) |mem| {
        if (!std.mem.eql(u8, mem.name, mv.text)) continue;
        try buf.appendSlice(arena, "**");
        try buf.appendSlice(arena, mem.name);
        try buf.appendSlice(arena, "** (kind `");
        try buf.appendSlice(arena, kind.name);
        try buf.appendSlice(arena, "`)");
        if (mem.label.len > 0) {
            try buf.appendSlice(arena, "\n\n");
            try buf.appendSlice(arena, mem.label);
        }
        if (mem.description.len > 0) {
            try buf.appendSlice(arena, "\n\n");
            try buf.appendSlice(arena, mem.description);
        }
        if (mem.deprecated) {
            try buf.appendSlice(arena, "\n\n**Deprecated**");
            if (mem.deprecation_message.len > 0) {
                try buf.appendSlice(arena, ": ");
                try buf.appendSlice(arena, mem.deprecation_message);
            }
        }
        return .{
            .contents = try buf.toOwnedSlice(arena),
            .span_start = mv.span.start,
            .span_end = mv.span.end,
        };
    }
    if (kind.cross_ref) |cr| {
        return renderCrossRefValueHover(arena, buf, mv, kind.name, cr);
    }
    return null;
}

/// Hover for a symbol sitting in a cross-ref-kinded slot, both routes.
/// Schema facts only — target form, and the key the member set is drawn
/// from (`:name-key` value on the identity route, provider extraction
/// over `:source-key` on the provider route). Resolution state is
/// deliberately absent: the `not_cross_ref` squiggle already reports a
/// miss, and goto-definition already answers "where".
fn renderCrossRefValueHover(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    mv: anytype,
    kind_name: []const u8,
    cr: sjon.Plugin.ValueKind.CrossRef,
) Allocator.Error!?Hover {
    try buf.appendSlice(arena, "**");
    try buf.appendSlice(arena, mv.text);
    try buf.appendSlice(arena, "** (kind `");
    try buf.appendSlice(arena, kind_name);
    try buf.appendSlice(arena, "`)\n\nCross-reference to `(");
    try buf.appendSlice(arena, cr.target_form);
    try buf.appendSlice(arena, " …)` — ");
    if (cr.provider) |p| {
        try buf.appendSlice(arena, "extracted from each target's `:");
        try buf.appendSlice(arena, cr.source_key);
        try buf.appendSlice(arena, "` by provider `");
        try buf.appendSlice(arena, p);
        try buf.appendSlice(arena, "`.");
    } else {
        try buf.appendSlice(arena, "declared by each target's `:");
        try buf.appendSlice(arena, cr.name_key);
        try buf.appendSlice(arena, "`.");
    }
    if (cr.scope_form) |sf| {
        try buf.appendSlice(arena, " Resolved within the enclosing `(");
        try buf.appendSlice(arena, sf);
        try buf.appendSlice(arena, " …)`.");
    }
    return .{
        .contents = try buf.toOwnedSlice(arena),
        .span_start = mv.span.start,
        .span_end = mv.span.end,
    };
}

fn renderFormSpec(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    schema: Schema.Schema,
    hit: Schema.FormHit,
    hdr: Ast.FormHeader,
) Allocator.Error!void {
    try buf.appendSlice(arena, "**(");
    if (hdr.namespace) |ns| {
        try buf.appendSlice(arena, ns);
        try buf.append(arena, '/');
    }
    try buf.appendSlice(arena, hit.form.name);
    try buf.appendSlice(arena, ")** — _from `");
    try buf.appendSlice(arena, hit.plugin.name);
    try buf.appendSlice(arena, "`_");
    if (hit.form.description.len > 0) {
        try buf.appendSlice(arena, "\n\n");
        try buf.appendSlice(arena, hit.form.description);
    }
    if (hit.form.keys.len > 0) {
        try buf.appendSlice(arena, "\n\n**Keys:**\n");
        for (hit.form.keys) |*k| {
            try buf.appendSlice(arena, "- `:");
            try buf.appendSlice(arena, k.name);
            try buf.appendSlice(arena, "` `");
            try appendValueType(arena, buf, k.value_type);
            try buf.append(arena, '`');
            // Same renderers the kvpair hover uses, in bullet form — the
            // list is a preview of each key's own hover, not a second
            // opinion about it.
            try appendConstraintSummary(arena, buf, schema, k.value_type, .bullet);
            try appendKeyObligation(arena, buf, k);
            if (k.description.len > 0) {
                try buf.appendSlice(arena, " — ");
                try buf.appendSlice(arena, k.description);
            }
            try buf.append(arena, '\n');
        }
    }
    switch (hit.form.positional) {
        .none => {},
        .any => try buf.appendSlice(arena, "\n_Accepts positional children._"),
        .kind => |k| {
            try buf.appendSlice(arena, "\n_Accepts positional children of kind `");
            if (k.namespace) |ns| {
                try buf.appendSlice(arena, ns);
                try buf.appendSlice(arena, "/");
            }
            try buf.appendSlice(arena, k.name);
            try buf.appendSlice(arena, "`._");
        },
        .flag_set => |fs| {
            // Compact inline list when no flag carries metadata; a
            // bulleted list (mirroring the Keys section) when any flag
            // has a `:description`/`:link` worth surfacing.
            var any_meta = false;
            for (fs.flags) |f| {
                if (f.description.len > 0 or f.link != null) {
                    any_meta = true;
                    break;
                }
            }
            if (any_meta) {
                try buf.appendSlice(arena, "\n\n**Positional flags:**\n");
                for (fs.flags) |f| {
                    try buf.appendSlice(arena, "- `:");
                    try buf.appendSlice(arena, f.name);
                    try buf.append(arena, '`');
                    if (f.description.len > 0) {
                        try buf.appendSlice(arena, " — ");
                        try buf.appendSlice(arena, f.description);
                    }
                    if (f.link) |link| {
                        try buf.appendSlice(arena, " ([docs](");
                        try buf.appendSlice(arena, link);
                        try buf.appendSlice(arena, "))");
                    }
                    try buf.append(arena, '\n');
                }
            } else {
                try buf.appendSlice(arena, "\n_Accepts positional flags: ");
                for (fs.flags, 0..) |f, i| {
                    if (i > 0) try buf.appendSlice(arena, ", ");
                    try buf.appendSlice(arena, ":");
                    try buf.appendSlice(arena, f.name);
                }
                try buf.appendSlice(arena, "._");
            }
        },
    }
    if (hit.form.open) {
        try buf.appendSlice(arena, "\n_Open form: accepts unknown keywords._");
    }
}

fn renderExprFunc(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    hit: Schema.ExprHit,
    hdr: Ast.FormHeader,
) Allocator.Error!void {
    try buf.appendSlice(arena, "**(");
    if (hdr.namespace) |ns| {
        try buf.appendSlice(arena, ns);
        try buf.append(arena, '/');
    }
    try buf.appendSlice(arena, hit.func.name);
    try buf.appendSlice(arena, " …)**");
    // The declared result, when there is one. An overloaded function
    // carries its results per-signature, not here, so this stays silent
    // for those — signature help is the surface that shows them.
    try appendResultArrow(arena, buf, hit.func.result);
    try buf.appendSlice(arena, " — _expression from `");
    try buf.appendSlice(arena, hit.plugin.name);
    try buf.appendSlice(arena, "`_");

    try buf.appendSlice(arena, "\n\n**Arity:** ");
    // SAFETY: `bufPrint` here can only fail with `NoSpaceLeft`, and every
    // string below is bounded well under 32 bytes — `Plugin.Arity`'s
    // payloads are `u8`, so the widest is `range`'s "255..255" (8), and
    // the widest literal prefix is "exactly " (8). The parameter index a
    // few lines down is a `usize` but bounded by `params.len`, and a
    // 20-digit index would need a manifest larger than memory.
    var num_buf: [32]u8 = undefined;
    switch (hit.func.arity) {
        .fixed => |n| try buf.appendSlice(arena, std.fmt.bufPrint(&num_buf, "exactly {d}", .{n}) catch unreachable),
        .at_least => |n| try buf.appendSlice(arena, std.fmt.bufPrint(&num_buf, "≥ {d}", .{n}) catch unreachable),
        .range => |r| try buf.appendSlice(arena, std.fmt.bufPrint(&num_buf, "{d}..{d}", .{ r.min, r.max }) catch unreachable),
    }

    if (hit.func.params) |params| {
        try buf.appendSlice(arena, "\n\n**Parameters:**\n");
        for (params, 0..) |p, i| {
            try buf.appendSlice(arena, std.fmt.bufPrint(&num_buf, "{d}. `", .{i}) catch unreachable);
            try appendValueType(arena, buf, p);
            try buf.appendSlice(arena, "`\n");
        }
        if (hit.func.rest) |r| {
            try buf.appendSlice(arena, "…rest: `");
            try appendValueType(arena, buf, r);
            try buf.appendSlice(arena, "`\n");
        }
    }

    if (hit.func.description.len > 0) {
        try buf.appendSlice(arena, "\n");
        try buf.appendSlice(arena, hit.func.description);
    }
}

fn renderKeySpec(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    schema: Schema.Schema,
    hit: Schema.FormHit,
    key: *const sjon.Plugin.KeySpec,
    kv: Ast.KvPairHeader,
) Allocator.Error!void {
    try buf.appendSlice(arena, "**:");
    try buf.appendSlice(arena, kv.key);
    try buf.appendSlice(arena, "** on **(");
    try buf.appendSlice(arena, hit.form.name);
    try buf.appendSlice(arena, ")** — `");
    try appendValueType(arena, buf, key.value_type);
    try buf.append(arena, '`');
    try appendKeyObligation(arena, buf, key);
    if (key.description.len > 0) {
        try buf.appendSlice(arena, "\n\n");
        try buf.appendSlice(arena, key.description);
    }
    // Constraints belong with the type they refine, above the provenance
    // footer — which stays the last thing in every hover.
    try appendConstraintSummary(arena, buf, schema, key.value_type, .block);
    try buf.appendSlice(arena, "\n\n_From plugin `");
    try buf.appendSlice(arena, hit.plugin.name);
    try buf.appendSlice(arena, "`._");
}

fn renderAmbiguousHead(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    hdr: Ast.FormHeader,
    amb: Schema.Ambiguous,
    flavour: enum { form, expr },
) Allocator.Error!void {
    try buf.appendSlice(arena, "**");
    try buf.appendSlice(arena, hdr.head);
    try buf.appendSlice(arena, "** — _ambiguous ");
    try buf.appendSlice(arena, switch (flavour) {
        .form => "form",
        .expr => "expression",
    });
    try buf.appendSlice(arena, "_\n\nDefined by:");
    for (amb.slice()) |p| {
        try buf.appendSlice(arena, " `");
        try buf.appendSlice(arena, p.name);
        try buf.append(arena, '`');
    }
    try buf.appendSlice(arena, "\n\nQualify with `<plugin>/");
    try buf.appendSlice(arena, hdr.head);
    try buf.appendSlice(arena, "` to disambiguate.");
}

/// Where a constraint summary is being rendered. The facts are identical;
/// only the wrapping differs — a key hover has a paragraph to spend, a
/// **Keys** bullet has the rest of one line.
const ConstraintStyle = enum {
    /// `\n\n**Constraints:** min 0, integer` — the kvpair hover.
    block,
    /// ` (min 0, integer)` — one entry in a form-head **Keys** list.
    bullet,
};

/// If `vt` names a value-kind carrying any refinement, append a one-line
/// "Constraints: …" summary onto `buf`. No-op for primitive types, for
/// unresolvable names, and for kinds that declare no refinement at all.
///
/// Every refinement family `Plugin.ValueKind` can carry is rendered here
/// — this is the single renderer both the kvpair hover and the form-head
/// **Keys** list use, so the two views can't drift. Facts are joined with
/// `, ` in a fixed family order; the wording mirrors the manifest syntax
/// (`min 0`, `length 2..4`, `units: px, em`) so a hover reads like the
/// declaration it came from.
///
/// The opener is written before the facts and rolled back if none
/// materialise — cheaper than a second predicate over the same fields,
/// and it cannot drift from what the family renderers actually emit.
fn appendConstraintSummary(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    schema: Schema.Schema,
    vt: sjon.Plugin.ValueType,
    style: ConstraintStyle,
) Allocator.Error!void {
    const kind = resolveValueKind(schema, vt) orelse return;

    const mark = buf.items.len;
    const opener: []const u8 = switch (style) {
        .block => "\n\n**Constraints:** ",
        .bullet => " (",
    };
    try buf.appendSlice(arena, opener);

    var first: bool = true;
    if (kind.numeric) |nb| try appendNumericFacts(arena, buf, &first, nb);
    if (kind.vector) |vs| try appendVectorFacts(arena, buf, &first, vs);
    if (kind.string_bounds) |sb| try appendStringFacts(arena, buf, &first, sb);
    if (kind.unit) |us| try appendUnitFacts(arena, buf, &first, us);
    if (kind.repr) |r| {
        try appendFactSep(arena, buf, &first);
        try buf.appendSlice(arena, "repr `");
        try buf.appendSlice(arena, @tagName(r));
        try buf.append(arena, '`');
    }
    if (kind.members) |ms| try appendMemberFacts(arena, buf, &first, ms);
    if (kind.union_of) |us| try appendUnionFacts(arena, buf, &first, us);
    if (kind.cross_ref) |cr| try appendCrossRefFacts(arena, buf, &first, cr);

    std.debug.assert(buf.items.len >= mark + opener.len);
    if (buf.items.len == mark + opener.len) {
        buf.shrinkRetainingCapacity(mark);
        return;
    }
    if (style == .bullet) try buf.append(arena, ')');
}

fn resolveValueKind(
    schema: Schema.Schema,
    vt: sjon.Plugin.ValueType,
) ?*const sjon.Plugin.ValueKind {
    const ref = switch (vt) {
        .named => |n| n,
        else => return null,
    };
    return switch (schema.lookupValueKind(ref.name, ref.namespace)) {
        .found => |k| k,
        else => null,
    };
}

/// The one-line "must I write this key?" marker, shared by the kvpair
/// hover and the **Keys** list so the two can't disagree about a key's
/// obligation. Three states, three renderings:
///
///   - has a default  → `` _(default: `4`)_ `` (implicitly optional)
///   - required       → `_(required)_`
///   - plain optional → nothing
///
/// A defaulted key is never also marked required: `effectiveOptional`
/// makes the default win, and showing both would be a contradiction.
fn appendKeyObligation(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    key: *const sjon.Plugin.KeySpec,
) Allocator.Error!void {
    if (key.default) |d| {
        try buf.appendSlice(arena, " _(default: `");
        try sjon.EffectiveDocument.appendDefaultLiteral(arena, buf, d, 0);
        try buf.appendSlice(arena, "`)_");
        return;
    }
    if (!key.effectiveOptional()) try buf.appendSlice(arena, " _(required)_");
}

// `appendDefaultLiteral` moved to `sjon.EffectiveDocument` with the
// splicer (devx plan 02 CP3).

/// Separate one fact from the previous. `first` starts true and is cleared
/// on the first call, so every fact renderer can open with this
/// unconditionally.
fn appendFactSep(arena: Allocator, buf: *std.ArrayList(u8), first: *bool) Allocator.Error!void {
    if (!first.*) try buf.appendSlice(arena, ", ");
    first.* = false;
}

fn appendNumericFacts(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    first: *bool,
    nb: sjon.Plugin.ValueKind.NumericBounds,
) Allocator.Error!void {
    if (nb.min) |b| {
        try appendFactSep(arena, buf, first);
        try appendBound(arena, buf, "min ", b, nb.exclusive_min);
    }
    if (nb.max) |b| {
        try appendFactSep(arena, buf, first);
        try appendBound(arena, buf, "max ", b, nb.exclusive_max);
    }
    if (nb.integer) {
        try appendFactSep(arena, buf, first);
        try buf.appendSlice(arena, "integer");
    }
}

/// `min 0` / `max 10db (exclusive)`. The unit rides directly on the number
/// because that is how it is written in source (`10db`, not `10 db`).
fn appendBound(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    label: []const u8,
    b: sjon.Plugin.ValueKind.NumericBounds.Bound,
    exclusive: bool,
) Allocator.Error!void {
    try buf.appendSlice(arena, label);
    try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{b.value}));
    if (b.unit) |u| try buf.appendSlice(arena, u);
    if (exclusive) try buf.appendSlice(arena, " (exclusive)");
}

fn appendVectorFacts(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    first: *bool,
    vs: sjon.Plugin.ValueKind.VectorShape,
) Allocator.Error!void {
    // `len` and the min/max pair are mutually exclusive (the loader
    // rejects the clash), so at most one length fact can fire.
    if (vs.len) |n| {
        try appendFactSep(arena, buf, first);
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "length {d}", .{n}));
    } else if (vs.min_len != null or vs.max_len != null) {
        try appendFactSep(arena, buf, first);
        try buf.appendSlice(arena, "length ");
        try appendLenBound(arena, buf, vs.min_len, "0");
        try buf.appendSlice(arena, "..");
        try appendLenBound(arena, buf, vs.max_len, "∞");
    }
    try appendFactSep(arena, buf, first);
    try buf.appendSlice(arena, "elements: ");
    try appendValueType(arena, buf, .{ .named = vs.element });
}

fn appendStringFacts(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    first: *bool,
    sb: sjon.Plugin.ValueKind.StringBounds,
) Allocator.Error!void {
    if (sb.min_len != null or sb.max_len != null) {
        try appendFactSep(arena, buf, first);
        try buf.appendSlice(arena, "length ");
        try appendLenBound(arena, buf, sb.min_len, "0");
        try buf.appendSlice(arena, "..");
        try appendLenBound(arena, buf, sb.max_len, "∞");
    }
    if (sb.format) |fmt| {
        try appendFactSep(arena, buf, first);
        try buf.appendSlice(arena, "format `");
        try buf.appendSlice(arena, @tagName(fmt));
        try buf.append(arena, '`');
    }
    if (sb.pattern) |p| {
        try appendFactSep(arena, buf, first);
        try buf.appendSlice(arena, "pattern `");
        try buf.appendSlice(arena, p);
        // v1 stores patterns without running them (`string_pattern_unsupported`);
        // saying so keeps the hover from promising validation it won't do.
        try buf.appendSlice(arena, "` _(informational)_");
    }
}

/// One end of a length range: the number, or `absent` when unbounded.
fn appendLenBound(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    bound: anytype,
    absent: []const u8,
) Allocator.Error!void {
    if (bound) |n| {
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{n}));
    } else {
        try buf.appendSlice(arena, absent);
    }
}

fn appendUnitFacts(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    first: *bool,
    us: sjon.Plugin.ValueKind.UnitShape,
) Allocator.Error!void {
    if (us.allowed.len > 0) {
        try appendFactSep(arena, buf, first);
        try buf.appendSlice(arena, "units: ");
        for (us.allowed, 0..) |u, i| {
            if (i > 0) try buf.appendSlice(arena, ", ");
            // Backticked because this comma-separated list sits inside
            // the comma-separated fact list; without them a reader can't
            // see where the units end and the next fact begins.
            try buf.append(arena, '`');
            try buf.appendSlice(arena, u);
            try buf.append(arena, '`');
        }
    }
    // `required` and `reject` are mutually exclusive in a valid manifest;
    // rendering both arms independently keeps a malformed one legible.
    if (us.required) {
        try appendFactSep(arena, buf, first);
        try buf.appendSlice(arena, "unit required");
    }
    if (us.reject) {
        try appendFactSep(arena, buf, first);
        try buf.appendSlice(arena, "unit rejected");
    }
}

/// How many member names a summary spells out before eliding. A closed set
/// of five is a list worth reading; a set of fifty is a wall — and the
/// full set is a completion away.
const MAX_SUMMARISED_MEMBERS = 5;

fn appendMemberFacts(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    first: *bool,
    ms: sjon.Plugin.ValueKind.MemberSet,
) Allocator.Error!void {
    // An empty set is "no narrowing" (see `MemberSet`'s doc comment), so
    // it earns no fact — and would otherwise render a dangling "one of ".
    if (ms.members.len == 0) return;
    try appendFactSep(arena, buf, first);
    try buf.appendSlice(arena, "one of ");
    const shown = @min(ms.members.len, MAX_SUMMARISED_MEMBERS);
    for (ms.members[0..shown], 0..) |m, i| {
        if (i > 0) try buf.appendSlice(arena, ", ");
        try buf.append(arena, '`');
        try buf.appendSlice(arena, m.name);
        try buf.append(arena, '`');
        if (m.label.len > 0) {
            try buf.appendSlice(arena, " (");
            try buf.appendSlice(arena, m.label);
            try buf.append(arena, ')');
        }
    }
    if (shown < ms.members.len) {
        try buf.appendSlice(arena, try std.fmt.allocPrint(
            arena,
            " … (+{d} more)",
            .{ms.members.len - shown},
        ));
    }
}

fn appendUnionFacts(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    first: *bool,
    us: sjon.Plugin.ValueKind.UnionShape,
) Allocator.Error!void {
    if (us.alternatives.len == 0) return;
    try appendFactSep(arena, buf, first);
    try buf.appendSlice(arena, "one of ");
    for (us.alternatives, 0..) |alt, i| {
        if (i > 0) try buf.appendSlice(arena, ", ");
        try buf.append(arena, '`');
        try appendValueType(arena, buf, .{ .named = alt });
        try buf.append(arena, '`');
    }
}

/// `` cross-ref to `(shader …)` via provider `lines` over `:src` `` /
/// `` cross-ref to `(phrase …)` by `:name` ``, plus `` , scoped to
/// `(piece …)` `` when a scope form constrains resolution. Both routes
/// name the key the member set is actually drawn from — the same rule
/// the `not_cross_ref` message follows, and for the same reason: a
/// summary that always implied `:name` would send the provider route's
/// reader to declare names in a place that registers none.
fn appendCrossRefFacts(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    first: *bool,
    cr: sjon.Plugin.ValueKind.CrossRef,
) Allocator.Error!void {
    try appendFactSep(arena, buf, first);
    try buf.appendSlice(arena, "cross-ref to `(");
    try buf.appendSlice(arena, cr.target_form);
    try buf.appendSlice(arena, " …)`");
    if (cr.provider) |p| {
        try buf.appendSlice(arena, " via provider `");
        try buf.appendSlice(arena, p);
        try buf.appendSlice(arena, "` over `:");
        try buf.appendSlice(arena, cr.source_key);
        try buf.append(arena, '`');
    } else {
        try buf.appendSlice(arena, " by `:");
        try buf.appendSlice(arena, cr.name_key);
        try buf.append(arena, '`');
    }
    if (cr.scope_form) |sf| {
        try buf.appendSlice(arena, ", scoped to `(");
        try buf.appendSlice(arena, sf);
        try buf.appendSlice(arena, " …)`");
    }
}

fn appendValueType(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    vt: sjon.Plugin.ValueType,
) Allocator.Error!void {
    switch (vt) {
        .any => try buf.appendSlice(arena, "any"),
        .number => try buf.appendSlice(arena, "number"),
        .string => try buf.appendSlice(arena, "string"),
        .symbol => try buf.appendSlice(arena, "symbol"),
        .boolean => try buf.appendSlice(arena, "boolean"),
        .nil => try buf.appendSlice(arena, "nil"),
        .vector => try buf.appendSlice(arena, "vector"),
        .form => try buf.appendSlice(arena, "form"),
        .expr => try buf.appendSlice(arena, "expr"),
        .named => |n| {
            if (n.namespace) |ns| {
                try buf.appendSlice(arena, ns);
                try buf.appendSlice(arena, "/");
            }
            try buf.appendSlice(arena, n.name);
        },
    }
}

/// Build the completion list at `byte_offset`. Returns null when the
/// document isn't open or the cursor isn't in a recognised completion
/// context. An empty slice means "no candidates" and is distinct from
/// null — the editor should still treat it as "no completion".
pub fn getCompletion(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    byte_offset: u32,
) Allocator.Error!?[]const CompletionItem {
    const doc = self.getDocument(uri) orelse return null;
    const ctx = resolveContextAt(&doc.tree, doc.source, byte_offset);
    return switch (ctx.position) {
        .none => null,
        .form_head => try self.completionsForFormHead(arena, &doc.tree, ctx, byte_offset),
        .kvpair_key => try self.completionsForKeywordKey(arena, &doc.tree, byte_offset),
        .kvpair_value => try self.completionsForKvpairValue(arena, uri, doc, byte_offset),
        .vector_elem => try self.completionsForVectorElement(arena, uri, doc, byte_offset, ctx),
        .expr_arg => try self.completionsForExprArg(arena, &doc.tree, ctx, byte_offset),
    };
}

/// Structured cursor-context output for completion (and, eventually,
/// hover / signature-help / inlay-hints — they currently derive their
/// own context via single-purpose helpers). `position` is the kind of
/// slot the cursor sits in; `enclosing_form_idx` / `enclosing_kvpair_idx`
/// point at the nearest AST anchors (null when the parser hasn't
/// produced the relevant node yet because the input is mid-edit);
/// `prefix` is the run of symbol chars immediately before the cursor
/// — what the client will typically use for client-side filtering.
pub const ResolvedContext = struct {
    enclosing_form_idx: ?Ast.NodeIndex,
    enclosing_kvpair_idx: ?Ast.NodeIndex,
    /// Smallest form that strictly contains `enclosing_form_idx`. Used by
    /// the completion vocabulary narrower to ask "what does the slot
    /// expect?" — the partial form-head being typed cannot answer that,
    /// only its parent can.
    parent_form_idx: ?Ast.NodeIndex,
    position: Position,
    prefix: []const u8,

    pub const Position = enum {
        none,
        form_head,
        kvpair_key,
        kvpair_value,
        vector_elem,
        expr_arg,
    };
};

/// Resolve the structured cursor context from `(tree, source, cursor)`.
///
/// The AST identifies enclosing form / kvpair nodes; classification of
/// the slot kind (form-head vs key vs value) still relies on the source
/// text backscan in v1 because the parser drops zero-width gaps and
/// partial trees do not flag a kvpair value as "in progress." That
/// distinction would need either a token-precise position or a
/// dedicated cursor-aware parser entry point; the backscan is good
/// enough for typical mid-edit input.
pub fn resolveContextAt(
    tree: *const Ast.Tree,
    source: []const u8,
    cursor: u32,
) ResolvedContext {
    const enc = findEnclosingDelimIdxAtCursor(tree, source, cursor, .form);
    var ctx: ResolvedContext = .{
        .enclosing_form_idx = enc,
        .enclosing_kvpair_idx = findEnclosingKvpairIdx(tree, cursor),
        .parent_form_idx = if (enc) |e| findParentFormIdx(tree, e) else null,
        .position = .none,
        .prefix = prefixBefore(source, cursor),
    };
    if (classifyCompletionContext(source, cursor)) |c| {
        ctx.position = switch (c) {
            .form_head => .form_head,
            .keyword_key => .kvpair_key,
            .member_value => .kvpair_value,
        };
    }
    // Vector-element detection: the smallest enclosing vector contains
    // the cursor AND is more deeply nested than the smallest enclosing
    // form (when both exist). Direction: `vector_elem` takes priority
    // over the backscan-derived `kvpair_value` because a value-slot
    // walker can't tell the cursor sits inside a vector when the only
    // backwards-visible context is the kvpair key.
    if (findEnclosingDelimIdxAtCursor(tree, source, cursor, .vector)) |vec_idx| {
        const vec_span = tree.spanOf(vec_idx);
        const vec_size = vec_span.end - vec_span.start;
        const form_size: u32 = if (ctx.enclosing_form_idx) |f| blk: {
            const fs = tree.spanOf(f);
            break :blk fs.end - fs.start;
        } else std.math.maxInt(u32);
        if (vec_size < form_size) ctx.position = .vector_elem;
    }
    // `.expr_arg` fallback: cursor sits inside a form but isn't on the
    // head, isn't inside a kvpair, and the backscan didn't claim it as
    // form-head / kvpair-key / kvpair-value. Schema check (is the
    // enclosing head an expr-func?) lives in the dispatcher — the
    // resolver is intentionally schema-free.
    if (ctx.position == .none and ctx.enclosing_kvpair_idx == null) {
        if (ctx.enclosing_form_idx) |form_idx| {
            const hdr = tree.formHeader(form_idx);
            if (!containsOffset(hdr.head_span, cursor)) {
                ctx.position = .expr_arg;
            }
        }
    }
    return ctx;
}

/// Run of symbol chars immediately preceding `cursor`. Used as the
/// `filter_text` fallback for completion items that share their label
/// with the placeholder snippet — clients filter by prefix-matching
/// this against `filter_text` (falling back to `label`).
fn prefixBefore(source: []const u8, cursor: u32) []const u8 {
    var i: usize = @min(cursor, source.len);
    const end = i;
    while (i > 0 and isSymbolChar(source[i - 1])) i -= 1;
    return source[i..end];
}

/// Smallest `node_tag` node whose span strictly contains `pos`
/// (`start <= pos < end`), or null when none does. Linear over node
/// count; there are no ties — same-tag nodes that both contain a point
/// nest strictly, so their spans differ in size. Shared engine behind
/// the four `findEnclosing*Idx` helpers and the strict half of
/// `findEnclosingDelimIdxAtCursor`.
fn smallestContainingIdx(tree: *const Ast.Tree, pos: u32, comptime node_tag: Ast.Tag) ?Ast.NodeIndex {
    var best: ?Ast.NodeIndex = null;
    var best_size: u32 = std.math.maxInt(u32);
    const tags = tree.nodes.items(.tag);
    var i: u32 = 0;
    while (i < tags.len) : (i += 1) {
        if (tags[i] != node_tag) continue;
        const idx = Ast.NodeIndex.from(i);
        const span = tree.spanOf(idx);
        if (pos < span.start or pos >= span.end) continue;
        const size = span.end - span.start;
        if (size < best_size) {
            best = idx;
            best_size = size;
        }
    }
    return best;
}

/// Smallest vector whose span contains `cursor`. Linear over node
/// count. Used by the resolver to detect `.vector_elem` positions.
fn findEnclosingVectorIdx(tree: *const Ast.Tree, pos: u32) ?Ast.NodeIndex {
    return smallestContainingIdx(tree, pos, .vector);
}

/// Smallest kvpair whose span contains `cursor`. Linear over node
/// count (matches `findEnclosingFormIdx`'s strategy).
fn findEnclosingKvpairIdx(tree: *const Ast.Tree, pos: u32) ?Ast.NodeIndex {
    return smallestContainingIdx(tree, pos, .kvpair);
}

/// True when `kvpair_idx`'s value **is** `node_idx`, or is a vector with
/// `node_idx` among its elements — exactly the two shapes `unionSlotOf`
/// resolves a slot for, and no others.
///
/// The question `findEnclosingKvpairIdx` answers is "which kvpair's span
/// contains this byte", which is not the question the refactor resolvers
/// need. With F8 positional local forms a node can sit inside a form that is
/// itself inside an *ancestor's* kvpair, so the key that comes back belongs
/// to the ancestor's schema while `unionSlotOf` is being asked about the
/// immediate parent's. A parent that happens to declare a union under the
/// same key name then gets a refactor offered against the wrong slot — and
/// the edit lands, because both sides typecheck against schemas that were
/// never talking about the same slot.
fn kvpairHolds(tree: *const Ast.Tree, kvpair_idx: Ast.NodeIndex, node_idx: Ast.NodeIndex) bool {
    const value_idx = tree.kvpairHeader(kvpair_idx).value;
    if (value_idx == node_idx) return true;
    if (tree.tagOf(value_idx) != .vector) return false;
    for (tree.vectorElements(value_idx)) |elem| {
        if (elem == node_idx) return true;
    }
    return false;
}

/// Cursor-anchored companion to `findEnclosingFormIdx` /
/// `findEnclosingVectorIdx` for the completion and signature-help paths.
/// Same strict-containment scan, plus an EOF rule for live typing:
/// parser recovery finalises every unclosed frame with
/// `span.end == source.len` (`Parser.closeUnclosedFrames`), so a cursor
/// at EOF sits exactly on `span.end` of each unclosed frame and the
/// exclusive-end scan alone reports "no enclosing node" — typing
/// `(smoothstep l` at the end of the document produced no completions.
///
/// Among the `node_tag` nodes ending exactly at EOF, at most the
/// innermost can be closed: its close delimiter would have to be the
/// final source byte, and one delimiter closes exactly one node. When
/// the final byte is that delimiter the cursor sits after it — outside
/// — and the next-smallest node (necessarily unclosed) encloses the
/// cursor instead. Diagnostic-anchored callers (code actions) keep the
/// strict helpers: their positions point into the document, never at EOF.
fn findEnclosingDelimIdxAtCursor(
    tree: *const Ast.Tree,
    source: []const u8,
    cursor: u32,
    comptime node_tag: Ast.Tag,
) ?Ast.NodeIndex {
    comptime std.debug.assert(node_tag == .form or node_tag == .vector);
    std.debug.assert(cursor <= source.len);

    const strict = switch (node_tag) {
        .form => findEnclosingFormIdx(tree, cursor),
        .vector => findEnclosingVectorIdx(tree, cursor),
        else => unreachable,
    };
    if (strict) |idx| return idx;
    if (cursor != source.len or source.len == 0) return null;

    // Innermost + second-innermost nodes ending exactly at EOF. Nodes
    // sharing an end offset nest strictly, so sizes are distinct and
    // "innermost" is well-defined.
    var best: ?Ast.NodeIndex = null;
    var best_size: u32 = std.math.maxInt(u32);
    var second: ?Ast.NodeIndex = null;
    var second_size: u32 = std.math.maxInt(u32);
    const tags = tree.nodes.items(.tag);
    var i: u32 = 0;
    while (i < tags.len) : (i += 1) {
        if (tags[i] != node_tag) continue;
        const idx = Ast.NodeIndex.from(i);
        const span = tree.spanOf(idx);
        if (span.end != cursor or span.start >= cursor) continue;
        const size = span.end - span.start;
        if (size < best_size) {
            second = best;
            second_size = best_size;
            best = idx;
            best_size = size;
        } else if (size < second_size) {
            second = idx;
            second_size = size;
        }
    }
    const innermost = best orelse return null;
    const closer: u8 = if (node_tag == .form) ')' else ']';
    const enclosing = if (source[source.len - 1] == closer) second else innermost;
    if (enclosing) |e| std.debug.assert(tree.spanOf(e).end == cursor);
    if (enclosing) |e| std.debug.assert(tree.spanOf(e).start < cursor);
    return enclosing;
}

const CompletionContext = enum { form_head, keyword_key, member_value };

/// Classify the cursor's completion intent by walking back over symbol
/// chars (and any preceding whitespace) and checking the delimiter.
///
/// `member_value` fires when the cursor sits in value position of a
/// kvpair (`:key |` or `:key part|`). Detection: after walking back
/// over the would-be value's symbol chars + whitespace, the next
/// backward sequence is a symbol (the key name) preceded by `:`.
fn classifyCompletionContext(source: []const u8, cursor: u32) ?CompletionContext {
    var i: usize = @min(cursor, source.len);
    while (i > 0 and isSymbolChar(source[i - 1])) i -= 1;
    while (i > 0 and isWhitespace(source[i - 1])) i -= 1;
    if (i == 0) return null;
    switch (source[i - 1]) {
        '(' => return .form_head,
        ':' => return .keyword_key,
        else => {},
    }
    // Value position: previous backward run should be a symbol (the key
    // name) preceded by `:`. Walk back across that symbol and check.
    var j: usize = i;
    while (j > 0 and isSymbolChar(source[j - 1])) j -= 1;
    if (j < i and j > 0 and source[j - 1] == ':') return .member_value;
    return null;
}

/// For a cursor in value position, walk back over the value (if any),
/// then whitespace, then the keyword name, and return that key. Returns
/// null when the cursor isn't unambiguously inside a `:key value` slot.
fn findEnclosingKvpairKey(source: []const u8, cursor: u32) ?[]const u8 {
    var i: usize = @min(cursor, source.len);
    while (i > 0 and isSymbolChar(source[i - 1])) i -= 1;
    while (i > 0 and isWhitespace(source[i - 1])) i -= 1;
    const key_end = i;
    while (i > 0 and isSymbolChar(source[i - 1])) i -= 1;
    if (i == key_end) return null;
    if (i == 0 or source[i - 1] != ':') return null;
    return source[i..key_end];
}

fn isSymbolChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '+', '*', '/', '?', '!', '=', '<', '>', '%', '.', '$', '&' => true,
        else => false,
    };
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Vocabulary the form-head completion may emit at the cursor's slot.
/// Driven by the parent slot's typing — `.expr` when the slot expects an
/// expression (parent is an expr-func or kvpair value typed `.expr`),
/// `.form` when the slot is restricted to data forms, `.any` when the
/// slot is unconstrained (top-level, unknown parent, ambiguous head).
const Vocabulary = enum { any, expr, form };

/// Decide which vocabulary `(here|` should expose, given the parent
/// form's typing. Kvpair value_type wins over parent expr-func-ness —
/// in `(if (rule :cond (foo|)))` the immediate slot is `:cond`, not the
/// outer `if`; this matches the validator's walk order. Falls through
/// to `.any` whenever the schema can't answer (no parent, unknown head,
/// ambiguous head, key not declared).
fn resolveFormHeadVocabulary(
    self: *const Self,
    tree: *const Ast.Tree,
    ctx: ResolvedContext,
) Vocabulary {
    const parent = ctx.parent_form_idx orelse return .any;
    const parent_hdr = tree.formHeader(parent);

    // (a) kvpair value_type wins when present and the partial form sits
    // inside that kvpair (kv span overlaps the parent's children).
    if (ctx.enclosing_kvpair_idx) |kv_idx| {
        const kv_span = tree.spanOf(kv_idx);
        const parent_span = tree.spanOf(parent);
        if (kv_span.start >= parent_span.start and kv_span.end <= parent_span.end) {
            switch (self.schema.lookupForm(parent_hdr.head, parent_hdr.namespace)) {
                .found => |hit| {
                    const kv_hdr = tree.kvpairHeader(kv_idx);
                    if (hit.form.keyByName(kv_hdr.key)) |k| {
                        return switch (k.value_type) {
                            .expr => .expr,
                            .form => .form,
                            else => .any,
                        };
                    }
                },
                else => {},
            }
        }
    }

    // (b) parent form is itself an expr-func → positional arg expects expr.
    switch (self.schema.lookupExprFunc(parent_hdr.head, parent_hdr.namespace)) {
        .found => return .expr,
        else => {},
    }
    return .any;
}

fn completionsForFormHead(
    self: *const Self,
    arena: Allocator,
    tree: *const Ast.Tree,
    ctx: ResolvedContext,
    cursor: u32,
) Allocator.Error![]const CompletionItem {
    const vocab = self.resolveFormHeadVocabulary(tree, ctx);

    // Result-type narrowing applies when the partial form sits as a
    // positional arg of an expr-func parent (not inside one of its
    // kvpair children — that path is "any expression"). We compute the
    // expected type for the active arg position and filter candidates
    // whose declared result type can't satisfy it.
    var expected: ?sjon.Plugin.ValueType = null;
    if (vocab == .expr) {
        if (ctx.parent_form_idx) |pf_idx| {
            const pf_hdr = tree.formHeader(pf_idx);
            const pf_span = tree.spanOf(pf_idx);
            const inside_kvpair_child = if (ctx.enclosing_kvpair_idx) |kv| blk: {
                const kv_span = tree.spanOf(kv);
                break :blk kv_span.start >= pf_span.start and kv_span.end <= pf_span.end;
            } else false;
            if (!inside_kvpair_child) {
                switch (self.schema.lookupExprFunc(pf_hdr.head, pf_hdr.namespace)) {
                    .found => |hit| {
                        const arg_idx = positionalIndex(tree, pf_hdr.children, cursor);
                        expected = expectedArgType(hit.func, arg_idx);
                    },
                    else => {},
                }
            }
        }
    }

    var items: std.ArrayList(CompletionItem) = .empty;
    for (self.schema.plugins) |p| {
        if (vocab != .expr) {
            for (p.forms) |f| {
                const snippet = try buildFormSnippet(arena, self.schema, f);
                try items.append(arena, .{
                    .label = f.name,
                    .kind = .constructor,
                    .detail = try std.fmt.allocPrint(arena, "form ({s})", .{p.name}),
                    .documentation = f.description,
                    .insert_text = snippet,
                    .insert_text_format = if (snippet != null) .snippet else .plain_text,
                });
            }
        }
        if (vocab != .form) {
            for (p.expr_funcs) |*f| {
                if (!candidateMatches(f, expected)) continue;
                try items.append(arena, .{
                    .label = f.name,
                    .kind = .function,
                    .detail = try std.fmt.allocPrint(arena, "expr ({s})", .{p.name}),
                    .documentation = f.description,
                });
            }
        }
    }
    return items.toOwnedSlice(arena);
}

/// Argument-slot completions: cursor sits inside an expr-func call,
/// between args (`(+ 1 |)`, `(opaque |)`). Emits type-shaped literal
/// placeholders (e.g. `0` for `.number`) plus expr-func candidates
/// wrapped in `(name args)` snippets, both filtered by the expected
/// result type when the parent declares one. Returns null when the
/// enclosing form's head isn't a known expr-func — data forms have no
/// positional-arg completion path.
fn completionsForExprArg(
    self: *const Self,
    arena: Allocator,
    tree: *const Ast.Tree,
    ctx: ResolvedContext,
    cursor: u32,
) Allocator.Error!?[]const CompletionItem {
    const form_idx = ctx.enclosing_form_idx orelse return null;
    const hdr = tree.formHeader(form_idx);
    const hit = switch (self.schema.lookupExprFunc(hdr.head, hdr.namespace)) {
        .found => |h| h,
        else => return null,
    };
    const arg_idx = positionalIndex(tree, hdr.children, cursor);
    const expected = expectedArgType(hit.func, arg_idx);

    var items: std.ArrayList(CompletionItem) = .empty;
    if (expected) |exp| try appendLiteralPlaceholders(self.schema, arena, &items, exp);

    for (self.schema.plugins) |p| {
        for (p.expr_funcs) |*f| {
            if (!candidateMatches(f, expected)) continue;
            const snippet = try buildExprFuncCallSnippet(arena, self.schema, f.*);
            try items.append(arena, .{
                .label = f.name,
                .kind = .function,
                .detail = try std.fmt.allocPrint(arena, "expr ({s})", .{p.name}),
                .documentation = f.description,
                .insert_text = snippet,
                .insert_text_format = .snippet,
                .filter_text = f.name,
            });
        }
    }
    const out: []const CompletionItem = try items.toOwnedSlice(arena);
    return out;
}

/// Snippet for invoking `func` from an argument slot: `(name $1)` for
/// opaque mono funcs, `(name ${1:0} ${2:0})` for typed funcs whose
/// `params` declare per-position types. Overloaded (`signatures`)
/// funcs surface a single `$1` tab stop — picking which signature to
/// fill is a user choice the snippet can't make.
fn buildExprFuncCallSnippet(
    arena: Allocator,
    schema: Schema.Schema,
    func: sjon.Plugin.ExprFunc,
) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(arena, '(');
    try appendSnippetEscaped(arena, &buf, func.name);
    if (func.params) |params| {
        if (params.len == 0) {
            try buf.appendSlice(arena, " $1");
        } else {
            var tab: u32 = 1;
            for (params) |pt| {
                try buf.append(arena, ' ');
                try appendValueTypePlaceholder(arena, &buf, schema, pt, &tab);
            }
        }
    } else {
        try buf.appendSlice(arena, " $1");
    }
    try buf.append(arena, ')');
    return buf.toOwnedSlice(arena);
}

/// Emit literal-value placeholders matching `vt` (e.g. `0` for `.number`,
/// `true`/`false` for `.boolean`). `.any` and `.symbol` produce nothing
/// — the user types whatever they want. `.named` either enumerates the
/// kind's `members`, or recurses on the underlying primitive.
fn appendLiteralPlaceholders(
    schema: Schema.Schema,
    arena: Allocator,
    items: *std.ArrayList(CompletionItem),
    vt: sjon.Plugin.ValueType,
) Allocator.Error!void {
    switch (vt) {
        .any, .symbol => return,
        .number => try items.append(arena, .{
            .label = "0",
            .kind = .enum_member,
            .insert_text = "${1:0}",
            .insert_text_format = .snippet,
            .filter_text = "0",
        }),
        .string => try items.append(arena, .{
            .label = "\"\"",
            .kind = .enum_member,
            .insert_text = "\"${1:}\"",
            .insert_text_format = .snippet,
            .filter_text = "\"",
        }),
        .boolean => {
            try items.append(arena, .{ .label = "true", .kind = .enum_member, .filter_text = "true" });
            try items.append(arena, .{ .label = "false", .kind = .enum_member, .filter_text = "false" });
        },
        .nil => try items.append(arena, .{ .label = "nil", .kind = .enum_member, .filter_text = "nil" }),
        .vector => try items.append(arena, .{
            .label = "[]",
            .kind = .enum_member,
            .insert_text = "[${1}]",
            .insert_text_format = .snippet,
            .filter_text = "[",
        }),
        .form, .expr => try items.append(arena, .{
            .label = "()",
            .kind = .enum_member,
            .insert_text = "(${1:head})",
            .insert_text_format = .snippet,
            .filter_text = "(",
        }),
        .named => |n| switch (schema.lookupValueKind(n.name, n.namespace)) {
            .found => |k| {
                if (k.members) |m| {
                    const deprecated_tags: []const CompletionItem.Tag = &.{.deprecated};
                    for (m.members) |mem| {
                        try items.append(arena, .{
                            .label = mem.name,
                            .kind = .enum_member,
                            .detail = mem.label,
                            .documentation = mem.description,
                            .tags = if (mem.deprecated) deprecated_tags else &.{},
                            .filter_text = mem.name,
                        });
                    }
                    return;
                }
                const underlying: sjon.Plugin.ValueType = switch (k.underlying) {
                    .number => .number,
                    .string => .string,
                    .symbol => .symbol,
                    .vector => .vector,
                    .form => .form,
                    .union_of => return,
                };
                try appendLiteralPlaceholders(schema, arena, items, underlying);
            },
            else => return,
        },
    }
}

/// Expected type at positional argument `arg_idx` for `func`. Returns
/// null when the slot is opaque (no `params`/`rest`, or signature mix
/// disagrees on the type) — caller treats null as "no narrowing".
///
/// For overloaded (`signatures`) functions, the union across signatures
/// whose arity covers `arg_idx` decides: if any covering sig leaves the
/// slot opaque, returns null; if all covering sigs agree on a single
/// type, returns it; if they disagree, returns null. Conservative —
/// narrowing only when unambiguous, matching the validator's permissive
/// behavior on union types.
fn expectedArgType(
    func: *const sjon.Plugin.ExprFunc,
    arg_idx: usize,
) ?sjon.Plugin.ValueType {
    if (func.signatures) |sigs| {
        var agreed: ?sjon.Plugin.ValueType = null;
        var found_covering = false;
        for (sigs) |s| {
            if (!arityCoversIndex(s.arity, arg_idx)) continue;
            found_covering = true;
            const pt = s.paramType(arg_idx) orelse return null;
            if (agreed) |a| {
                if (!valueTypeEqual(a, pt)) return null;
            } else agreed = pt;
        }
        return if (found_covering) agreed else null;
    }
    if (func.params) |p| {
        if (arg_idx < p.len) return p[arg_idx];
        if (func.rest) |r| return r;
        return null;
    }
    return null;
}

/// Does `arity` reach position `i`? Used by `expectedArgType` to filter
/// signatures that couldn't be the active overload at this arg position.
fn arityCoversIndex(arity: sjon.Plugin.ExprFunc.Arity, i: usize) bool {
    return switch (arity) {
        .fixed => |k| i < k,
        .at_least => true,
        .range => |r| i < r.max,
    };
}

/// True iff `c`'s declared result type can satisfy `expected`. Opaque
/// candidates (no `result` / `signatures`) are kept (permissive) — we
/// don't want to hide a legitimate function just because it lacks a
/// type annotation. When `expected == null` no narrowing is requested.
fn candidateMatches(
    c: *const sjon.Plugin.ExprFunc,
    expected: ?sjon.Plugin.ValueType,
) bool {
    const exp = expected orelse return true;
    if (exp == .any) return true;
    if (c.signatures) |sigs| {
        for (sigs) |s| {
            const r = s.result orelse return true;
            if (r == .any) return true;
            if (valueTypeEqual(r, exp)) return true;
        }
        return false;
    }
    const r = c.result orelse return true;
    if (r == .any) return true;
    return valueTypeEqual(r, exp);
}

/// Compare two `ValueType` tagged unions including `.named` string
/// content. `std.meta.eql` would compare slice pointers for `.named`,
/// which fails across plugin reloads where the same name lives at
/// different addresses.
fn valueTypeEqual(a: sjon.Plugin.ValueType, b: sjon.Plugin.ValueType) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .named => |n| qualifiedRefEql(n, b.named),
        else => true,
    };
}

fn qualifiedRefEql(a: sjon.Plugin.QualifiedRef, b: sjon.Plugin.QualifiedRef) bool {
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    if (a.namespace == null and b.namespace == null) return true;
    if (a.namespace == null or b.namespace == null) return false;
    return std.mem.eql(u8, a.namespace.?, b.namespace.?);
}

/// Build a snippet body for a form: `name :req1 ${1:default} :req2 …$0`.
/// Returns null when the form has no required keys — letting the client
/// fall back to plain-text label insertion (no point in a single-tab-stop
/// snippet that adds nothing). The leading `(` is NOT included; the user
/// has already typed it by the time form-head completion fires.
fn buildFormSnippet(
    arena: Allocator,
    schema: Schema.Schema,
    form: sjon.Plugin.FormSpec,
) Allocator.Error!?[]const u8 {
    if (!hasRequiredKey(form)) return null;

    var buf: std.ArrayList(u8) = .empty;
    try appendSnippetEscaped(arena, &buf, form.name);
    var tab: u32 = 1;
    try appendFormBody(arena, &buf, schema, form, &tab);
    try buf.appendSlice(arena, "$0");
    return try buf.toOwnedSlice(arena);
}

/// Build a form-valued slot snippet: `(name :req ${1:default}…$0)`.
/// Used when a kvpair value slot is constrained to a specific form
/// head (`ValueKind.underlying == .form` with `heads.names`). Always
/// emits the wrapping parens; tab stops start at 1.
fn buildFormValueSnippet(
    arena: Allocator,
    schema: Schema.Schema,
    form: sjon.Plugin.FormSpec,
) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(arena, '(');
    try appendSnippetEscaped(arena, &buf, form.name);
    var tab: u32 = 1;
    try appendFormBody(arena, &buf, schema, form, &tab);
    try buf.appendSlice(arena, "$0)");
    return buf.toOwnedSlice(arena);
}

/// Append the `:k value` portion of a form snippet for every required
/// key in `form`, threading `*tab` so each placeholder uses a fresh
/// tab stop. The leading head and trailing `$0` belong to the caller.
fn appendFormBody(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    schema: Schema.Schema,
    form: sjon.Plugin.FormSpec,
    tab: *u32,
) Allocator.Error!void {
    for (form.keys) |k| {
        if (k.effectiveOptional()) continue;
        try buf.appendSlice(arena, " :");
        try appendSnippetEscaped(arena, buf, k.name);
        try buf.append(arena, ' ');
        try appendValueTypePlaceholder(arena, buf, schema, k.value_type, tab);
    }
}

fn hasRequiredKey(form: sjon.Plugin.FormSpec) bool {
    for (form.keys) |k| {
        if (!k.effectiveOptional()) return true;
    }
    return false;
}

/// Append `text` to `buf`, escaping `$`, `}`, and `\` so the snippet
/// engine treats them as literals. SJON identifiers don't normally
/// contain these, but the parser allows `$` in symbols (LANGUAGE §3.1).
fn appendSnippetEscaped(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    text: []const u8,
) Allocator.Error!void {
    for (text) |c| {
        if (c == '$' or c == '}' or c == '\\') try buf.append(arena, '\\');
        try buf.append(arena, c);
    }
}

/// Append a snippet placeholder for `vt` and bump `*tab`. Each call uses
/// the next available tab stop. The placeholder default is chosen to be
/// a syntactically-valid SJON value where possible so editors that flatten
/// snippets to plain text still produce parseable output.
///
/// `.named` types are resolved via `schema.lookupValueKind` so kinds
/// with constraints surface a richer placeholder: a `.number` kind
/// with `unit.allowed` non-empty emits two consecutive tab stops
/// (`${n:0}${m:px}`), letting the user tab from the magnitude to the
/// unit suffix. Otherwise the name itself is the placeholder default.
fn appendValueTypePlaceholder(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    schema: Schema.Schema,
    vt: sjon.Plugin.ValueType,
    tab: *u32,
) Allocator.Error!void {
    const n = tab.*;
    tab.* += 1;
    const piece = switch (vt) {
        .string => try std.fmt.allocPrint(arena, "\"${d}\"", .{n}),
        .number => try std.fmt.allocPrint(arena, "${{{d}:0}}", .{n}),
        .boolean => try std.fmt.allocPrint(arena, "${{{d}|true,false|}}", .{n}),
        .symbol => try std.fmt.allocPrint(arena, "${{{d}:symbol}}", .{n}),
        .nil => try std.fmt.allocPrint(arena, "${{{d}:nil}}", .{n}),
        .vector => try std.fmt.allocPrint(arena, "[${d}]", .{n}),
        .form, .expr => try std.fmt.allocPrint(arena, "(${d})", .{n}),
        .any => try std.fmt.allocPrint(arena, "${d}", .{n}),
        .named => |ref| {
            // Unit-aware: number kind with at least one allowed unit
            // emits a number placeholder followed by a unit placeholder
            // on a fresh tab stop. The first allowed unit becomes the
            // default — picked deterministically so snippet behavior is
            // stable across runs.
            switch (schema.lookupValueKind(ref.name, ref.namespace)) {
                .found => |kind| {
                    if (kind.unit) |u| if (u.allowed.len > 0) {
                        const unit_tab = tab.*;
                        tab.* += 1;
                        try buf.appendSlice(
                            arena,
                            try std.fmt.allocPrint(arena, "${{{d}:0}}", .{n}),
                        );
                        try buf.appendSlice(
                            arena,
                            try std.fmt.allocPrint(arena, "${{{d}:", .{unit_tab}),
                        );
                        try appendSnippetEscaped(arena, buf, u.allowed[0]);
                        try buf.append(arena, '}');
                        return;
                    };
                },
                else => {},
            }
            try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "${{{d}:", .{n}));
            try appendSnippetEscaped(arena, buf, ref.name);
            try buf.append(arena, '}');
            return;
        },
    };
    try buf.appendSlice(arena, piece);
}

fn completionsForKeywordKey(
    self: *const Self,
    arena: Allocator,
    tree: *const Ast.Tree,
    cursor: u32,
) Allocator.Error![]const CompletionItem {
    const enclosing = findEnclosingForm(tree, cursor) orelse return &.{};
    const lookup = self.schema.lookupForm(enclosing.head, enclosing.namespace);
    const hit = switch (lookup) {
        .found => |h| h,
        else => return &.{},
    };

    // Collect names of kvpair keys already present in the enclosing
    // form so we can filter both direct duplicates and exclusive-group
    // siblings against them.
    var present: std.StringHashMapUnmanaged(void) = .empty;
    const tags = tree.nodes.items(.tag);
    for (enclosing.children) |child| {
        if (tags[@intFromEnum(child)] != .kvpair) continue;
        const kv = tree.kvpairHeader(child);
        try present.put(arena, kv.key, {});
    }

    // Discriminant narrowing: when the form declares a discriminant
    // and its symbol value is already typed, the matching variant's
    // keys become valid alongside the base keys. Use the validator's
    // canonical helper would require a complete form; the partial-
    // input completion path scans kvpair children directly.
    var active_variant: ?*const sjon.Plugin.Variant = null;
    if (hit.form.discriminant_name) |disc_name| {
        if (findKvpairSymbolValue(tree, enclosing, disc_name)) |value| {
            if (hit.form.variants) |variants| {
                for (variants) |*v| {
                    if (std.mem.eql(u8, v.when, value)) {
                        active_variant = v;
                        break;
                    }
                }
            }
        }
    }

    // For each exclusive group with one alternative already present,
    // mark every other key in the group as excluded — suggesting one
    // would invariably trigger a validator diagnostic.
    var excluded: std.StringHashMapUnmanaged(void) = .empty;
    for (hit.form.exclusive_groups) |grp| try excludeGroupIfTriggered(&excluded, arena, grp, present);
    if (active_variant) |v| {
        for (v.exclusive_groups) |grp| try excludeGroupIfTriggered(&excluded, arena, grp, present);
    }

    // Total candidate key count for the array preallocation.
    const variant_keys_len: usize = if (active_variant) |v| v.keys.len else 0;
    var items: std.ArrayList(CompletionItem) = .empty;
    try items.ensureTotalCapacity(arena, hit.form.keys.len + variant_keys_len);

    try appendKeyCandidates(arena, &items, hit.form.keys, present, excluded);
    if (active_variant) |v| try appendKeyCandidates(arena, &items, v.keys, present, excluded);

    return items.toOwnedSlice(arena);
}

/// Mark every alternative key of `grp` as excluded when at least one
/// of `grp`'s alternatives is already present in `present`. Used by
/// both base-form and active-variant exclusive groups.
fn excludeGroupIfTriggered(
    excluded: *std.StringHashMapUnmanaged(void),
    arena: Allocator,
    grp: sjon.Plugin.ExclusiveGroup,
    present: std.StringHashMapUnmanaged(void),
) Allocator.Error!void {
    var any_present = false;
    for (grp.alternatives) |alt| {
        for (alt.keys) |k| {
            if (present.contains(k)) {
                any_present = true;
                break;
            }
        }
        if (any_present) break;
    }
    if (!any_present) return;
    for (grp.alternatives) |alt| {
        for (alt.keys) |k| {
            if (!present.contains(k)) try excluded.put(arena, k, {});
        }
    }
}

/// Append `CompletionItem`s for every key in `keys` that isn't already
/// present or in the excluded set. Required keys sort before optional
/// via `sort_text`; `filter_text = label` so client-side prefix
/// matching keeps working.
fn appendKeyCandidates(
    arena: Allocator,
    items: *std.ArrayList(CompletionItem),
    keys: []const sjon.Plugin.KeySpec,
    present: std.StringHashMapUnmanaged(void),
    excluded: std.StringHashMapUnmanaged(void),
) Allocator.Error!void {
    for (keys) |k| {
        if (present.contains(k.name)) continue;
        if (excluded.contains(k.name)) continue;
        const sort_prefix: u8 = if (k.effectiveOptional()) '1' else '0';
        try items.append(arena, .{
            .label = k.name,
            .kind = .field,
            .detail = try keyDetail(arena, k),
            .documentation = k.description,
            .sort_text = try std.fmt.allocPrint(arena, "{c}_{s}", .{ sort_prefix, k.name }),
            .filter_text = k.name,
        });
    }
}

/// Return the symbol-typed value text of the first kvpair in
/// `form` whose key matches `key_name`. Used by discriminant
/// narrowing to read the current `:kind <symbol>` value.
fn findKvpairSymbolValue(
    tree: *const Ast.Tree,
    form: Ast.FormHeader,
    key_name: []const u8,
) ?[]const u8 {
    const tags = tree.nodes.items(.tag);
    for (form.children) |child| {
        if (tags[@intFromEnum(child)] != .kvpair) continue;
        const kv = tree.kvpairHeader(child);
        if (!std.mem.eql(u8, kv.key, key_name)) continue;
        if (tags[@intFromEnum(kv.value)] != .symbol) return null;
        return tree.symbolText(kv.value);
    }
    return null;
}

/// Build completion items for the value position of a kvpair. Dispatch
/// is keyed on the kvpair's resolved `ValueKind`:
///   * `kind.cross_ref` → names registered for that target in the
///     current document's scope (via `cross_ref_index`). Self-name is
///     filtered when the enclosing form's head canonicalises to the
///     same target (avoids `(phrase :name p :related-phrase p)`).
///   * `.number` + `kind.unit.allowed` non-empty → one unit-suffix item
///     per allowed unit, only when the cursor sits at the end of a
///     bare numeric literal.
///   * `kind.members`   → fixed enum-like list, deprecated members
///     carry the `.deprecated` tag.
/// Returns `&.{}` when the slot has no schema-driven candidates.
fn completionsForKvpairValue(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    doc: *const Document,
    cursor: u32,
) Allocator.Error![]const CompletionItem {
    const enclosing_form_idx = findEnclosingDelimIdxAtCursor(&doc.tree, doc.source, cursor, .form) orelse return &.{};
    const enclosing = doc.tree.formHeader(enclosing_form_idx);
    const lookup = self.schema.lookupForm(enclosing.head, enclosing.namespace);
    const hit = switch (lookup) {
        .found => |h| h,
        else => return &.{},
    };
    const key_name = findEnclosingKvpairKey(doc.source, cursor) orelse return &.{};

    const key = hit.form.keyByName(key_name) orelse return &.{};
    const vt = key.value_type;

    // Primitive-shape slots: `.boolean` and `.nil` value types have a
    // fixed, finite literal set we can surface without a value kind.
    switch (vt) {
        .boolean => return try literalSet(arena, &.{ "true", "false" }),
        .nil => return try literalSet(arena, &.{"nil"}),
        else => {},
    }

    const named = switch (vt) {
        .named => |n| n,
        else => return &.{},
    };
    const kind_lookup = self.schema.lookupValueKind(named.name, named.namespace);
    const kind = switch (kind_lookup) {
        .found => |k| k,
        else => return &.{},
    };

    // Cross-ref takes precedence over members — a kind shouldn't carry
    // both, but if it does, cross_ref is the more useful surface (named
    // symbols vs. abstract enum tags).
    if (kind.cross_ref) |xref| {
        return self.completionsForCrossRef(arena, uri, doc, enclosing_form_idx, xref);
    }

    // Number with declared `unit.allowed`: cursor at the end of a bare
    // numeric literal (no existing suffix) gets one suggestion per
    // allowed unit. Empty `allowed` ("any unit accepted") yields no
    // candidates — guessing units would mislead.
    if (kind.underlying == .number) {
        if (kind.unit) |u| if (u.allowed.len > 0) {
            if (findKvpairValueByKey(&doc.tree, enclosing, key_name)) |value_idx| {
                return try unitSuffixCompletions(arena, &doc.tree, value_idx, u.allowed, cursor);
            }
        };
    }

    // String with declared `format` (email / uri / path / uuid /
    // semver): emit a single template snippet whose body matches the
    // format's expected shape. Lets editors land a syntactically valid
    // starting point that the user can edit in place.
    if (kind.underlying == .string) {
        if (kind.string_bounds) |sb| if (sb.format) |fmt| {
            return try stringFormatSnippet(arena, fmt);
        };
    }

    // Form-valued slot: `.form` underlying with a non-empty `heads.names`
    // emits one `(head :req …)` snippet per allowed head. Each name is
    // resolved through the schema so the snippet body matches the
    // form's required keys; lookup misses fall back to a bare
    // `(head $0)` placeholder.
    if (kind.underlying == .form) {
        if (kind.heads) |hs| if (hs.names.len > 0) {
            return self.completionsForFormValuedSlot(arena, hs.names);
        };
    }

    const m = kind.members orelse return &.{};
    if (m.members.len == 0) return &.{};

    var items: std.ArrayList(CompletionItem) = .empty;
    try items.ensureTotalCapacity(arena, m.members.len);
    const deprecated_tags: []const CompletionItem.Tag = &.{.deprecated};
    for (m.members) |mem| {
        items.appendAssumeCapacity(.{
            .label = mem.name,
            .kind = .enum_member,
            .detail = mem.label,
            .documentation = mem.description,
            .tags = if (mem.deprecated) deprecated_tags else &.{},
        });
    }
    return items.toOwnedSlice(arena);
}

/// Completions for a cursor sitting inside a `[...]` vector. The
/// element kind comes from the kvpair whose value is the enclosing
/// vector → `ValueType.named` → `ValueKind.vector.element` → resolved
/// kind. Falls through to the member / cross-ref dispatch the kvpair
/// value path already implements, plus a number-with-unit arm that
/// fires when the cursor sits at the end of a bare-number element in
/// a vector whose element kind has `unit.allowed`. Vectors that
/// aren't a direct kvpair value (top-level, or nested) return empty —
/// v1 limitation.
fn completionsForVectorElement(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    doc: *const Document,
    cursor: u32,
    ctx: ResolvedContext,
) Allocator.Error![]const CompletionItem {
    const form_idx = ctx.enclosing_form_idx orelse return &.{};
    const tree = &doc.tree;
    const tags = tree.nodes.items(.tag);
    const vec_idx = findEnclosingDelimIdxAtCursor(tree, doc.source, cursor, .vector) orelse return &.{};

    // Within the enclosing form, find the kvpair whose value IS this
    // vector. Reading kvpair headers via the SoA tree is cheap.
    const form_header = tree.formHeader(form_idx);
    var owning_key: ?[]const u8 = null;
    for (form_header.children) |child| {
        if (tags[@intFromEnum(child)] != .kvpair) continue;
        const kv = tree.kvpairHeader(child);
        if (@intFromEnum(kv.value) == @intFromEnum(vec_idx)) {
            owning_key = kv.key;
            break;
        }
    }
    const key_name = owning_key orelse return &.{};

    const lookup = self.schema.lookupForm(form_header.head, form_header.namespace);
    const hit = switch (lookup) {
        .found => |h| h,
        else => return &.{},
    };
    const key = hit.form.keyByName(key_name) orelse return &.{};
    const vt = key.value_type;
    const named = switch (vt) {
        .named => |n| n,
        else => return &.{},
    };
    const vec_kind = switch (self.schema.lookupValueKind(named.name, named.namespace)) {
        .found => |k| k,
        else => return &.{},
    };
    const vec_shape = vec_kind.vector orelse return &.{};

    // The element name may be a primitive ("number", "string", ...) or a
    // named kind. Try the kind lookup; if the element is itself a
    // cross-ref symbol kind, surface the registered names.
    const elem_kind = switch (self.schema.lookupValueKind(vec_shape.element.name, vec_shape.element.namespace)) {
        .found => |k| k,
        else => return &.{},
    };

    if (elem_kind.cross_ref) |xref| {
        return self.completionsForCrossRef(arena, uri, doc, form_idx, xref);
    }

    // Number element with declared `unit.allowed`: locate the vector
    // element whose span ends exactly at the cursor; if its tag is a
    // bare-number variant, surface allowed-unit completions. Mirrors
    // the kvpair-value arm; same deferral for `.number_with_unit`.
    if (elem_kind.underlying == .number) {
        if (elem_kind.unit) |u| if (u.allowed.len > 0) {
            for (tree.vectorElements(vec_idx)) |elem_idx| {
                if (tree.spanOf(elem_idx).end == cursor) {
                    return try unitSuffixCompletions(arena, tree, elem_idx, u.allowed, cursor);
                }
            }
            return &.{};
        };
    }

    const m = elem_kind.members orelse return &.{};
    if (m.members.len == 0) return &.{};

    var items: std.ArrayList(CompletionItem) = .empty;
    try items.ensureTotalCapacity(arena, m.members.len);
    const deprecated_tags: []const CompletionItem.Tag = &.{.deprecated};
    for (m.members) |mem| {
        items.appendAssumeCapacity(.{
            .label = mem.name,
            .kind = .enum_member,
            .detail = mem.label,
            .documentation = mem.description,
            .tags = if (mem.deprecated) deprecated_tags else &.{},
        });
    }
    return items.toOwnedSlice(arena);
}

/// Build a `[]const CompletionItem` carrying one `.enum_member`-kinded
/// item per literal string in `literals`. Used by primitive-typed
/// slots (`.boolean`, `.nil`) where the candidate set is a fixed
/// keyword family.
fn literalSet(
    arena: Allocator,
    literals: []const []const u8,
) Allocator.Error![]const CompletionItem {
    var items: std.ArrayList(CompletionItem) = .empty;
    try items.ensureTotalCapacity(arena, literals.len);
    for (literals) |lit| {
        items.appendAssumeCapacity(.{
            .label = lit,
            .kind = .enum_member,
            .filter_text = lit,
        });
    }
    return items.toOwnedSlice(arena);
}

/// One quoted snippet whose body matches the `string_bounds.format`
/// shape — gives the user a syntactically reasonable starting point.
/// The tab stop is `$1` so accept-then-tab lands inside the quotes.
fn stringFormatSnippet(
    arena: Allocator,
    format: sjon.Plugin.ValueKind.StringBounds.Format,
) Allocator.Error![]const CompletionItem {
    const template: []const u8 = switch (format) {
        .email => "\"${1:user@example.com}\"",
        .uri => "\"${1:https://}\"",
        .path => "\"${1:./path}\"",
        .uuid => "\"${1:00000000-0000-0000-0000-000000000000}\"",
        .semver => "\"${1:1.0.0}\"",
    };
    const label: []const u8 = switch (format) {
        .email => "email",
        .uri => "URI",
        .path => "path",
        .uuid => "UUID",
        .semver => "semver",
    };
    const items = try arena.alloc(CompletionItem, 1);
    items[0] = .{
        .label = label,
        .kind = .enum_member,
        .detail = try std.fmt.allocPrint(arena, "string ({s})", .{label}),
        .insert_text = try arena.dupe(u8, template),
        .insert_text_format = .snippet,
        .filter_text = label,
    };
    return items;
}

/// One `(head :req …)` snippet per allowed head for a form-valued
/// slot. Each head name may be bare or `ns/form`; both are looked up
/// against the active schema. When resolution misses we still emit a
/// minimal `(head $0)` snippet — the user gets the head spelled out
/// but no required-key skeleton.
fn completionsForFormValuedSlot(
    self: *const Self,
    arena: Allocator,
    head_names: []const []const u8,
) Allocator.Error![]const CompletionItem {
    var items: std.ArrayList(CompletionItem) = .empty;
    try items.ensureTotalCapacity(arena, head_names.len);
    for (head_names) |raw_name| {
        var ns: ?[]const u8 = null;
        var name = raw_name;
        if (std.mem.indexOfScalar(u8, raw_name, '/')) |slash| {
            ns = raw_name[0..slash];
            name = raw_name[slash + 1 ..];
        }
        const snippet = switch (self.schema.lookupForm(name, ns)) {
            .found => |h| try buildFormValueSnippet(arena, self.schema, h.form.*),
            else => try std.fmt.allocPrint(arena, "({s} $0)", .{raw_name}),
        };
        const detail: []const u8 = switch (self.schema.lookupForm(name, ns)) {
            .found => |h| try std.fmt.allocPrint(arena, "form ({s})", .{h.plugin.name}),
            else => "",
        };
        const documentation: []const u8 = switch (self.schema.lookupForm(name, ns)) {
            .found => |h| h.form.description,
            else => "",
        };
        items.appendAssumeCapacity(.{
            .label = raw_name,
            .kind = .constructor,
            .detail = detail,
            .documentation = documentation,
            .insert_text = snippet,
            .insert_text_format = .snippet,
            .filter_text = raw_name,
        });
    }
    return items.toOwnedSlice(arena);
}

/// Names registered for `xref.target_form` in the scope the cursor
/// sits in. Returns empty when the cross-ref index isn't built
/// (validation hasn't run), the target doesn't resolve, this URI
/// isn't in the index, or no names are registered in the resolved
/// scope.
///
/// Scope resolution mirrors the validator (`Validator.findNearestScope`):
///   * `xref.scope_form == null`            → tree-scope (every name
///     registered in this document under the target).
///   * `xref.scope_form` set, ancestor match → lexical-scope keyed by
///     the innermost matching form's `NodeIndex` (the validator mints
///     the same id via `Validator.ScopeId.lexical`).
///   * `xref.scope_form` set, no match       → empty list. Surfacing
///     other scopes' names would mislead — the validator would emit
///     `cross_ref_outside_scope` on submit.
fn completionsForCrossRef(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    doc: *const Document,
    enclosing_form_idx: Ast.NodeIndex,
    xref: sjon.Plugin.ValueKind.CrossRef,
) Allocator.Error![]const CompletionItem {
    const xri = self.cross_ref_index orelse return &.{};
    const tree_idx = self.uri_to_tree_idx.get(uri) orelse return &.{};
    const enclosing = doc.tree.formHeader(enclosing_form_idx);

    const resolved = (try self.resolveCrossRefTargetAndScope(arena, doc, tree_idx, enclosing_form_idx, xref)) orelse return &.{};
    const canonical_target = resolved.canonical_target;
    const scope = resolved.scope;
    const target_hit = resolved.target_hit;

    // If the enclosing form IS a definition of the same target, find its
    // `:name-key` value and exclude that name so we don't suggest the
    // symbol the user is currently defining.
    var self_name: ?[]const u8 = null;
    const enc_lookup = self.schema.lookupForm(enclosing.head, enclosing.namespace);
    if (enc_lookup == .found) {
        const enc_hit = enc_lookup.found;
        if (enc_hit.plugin == target_hit.plugin and enc_hit.form == target_hit.form) {
            self_name = findKvpairValueText(doc, enclosing, xref.name_key);
        }
    }

    var items: std.ArrayList(CompletionItem) = .empty;
    var it = xri.iterateNames(scope, canonical_target);
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (self_name) |s| if (std.mem.eql(u8, s, name)) continue;
        try items.append(arena, .{
            .label = name,
            .kind = .enum_member,
            .detail = try std.fmt.allocPrint(arena, "ref → {s}", .{canonical_target}),
        });
    }
    return items.toOwnedSlice(arena);
}

/// Return the symbol-value text of the first kvpair in `enclosing`
/// whose key matches `key_name`, or null when no such kvpair exists or
/// its value isn't a symbol. Used by cross-ref completion to filter
/// the defining form's own name.
fn findKvpairValueText(
    doc: *const Document,
    enclosing: Ast.FormHeader,
    key_name: []const u8,
) ?[]const u8 {
    const tree = &doc.tree;
    const tags = tree.nodes.items(.tag);
    for (enclosing.children) |child| {
        if (tags[@intFromEnum(child)] != .kvpair) continue;
        const kv = tree.kvpairHeader(child);
        if (!std.mem.eql(u8, kv.key, key_name)) continue;
        if (tags[@intFromEnum(kv.value)] != .symbol) return null;
        const v_span = tree.spanOf(kv.value);
        return doc.source[v_span.start..v_span.end];
    }
    return null;
}

/// AST counterpart to `findKvpairValueText`: returns the value node of
/// the first kvpair in `enclosing` whose key matches `key_name`, or
/// null when no such kvpair exists.
fn findKvpairValueByKey(
    tree: *const Ast.Tree,
    enclosing: Ast.FormHeader,
    key_name: []const u8,
) ?Ast.NodeIndex {
    const tags = tree.nodes.items(.tag);
    for (enclosing.children) |child| {
        if (tags[@intFromEnum(child)] != .kvpair) continue;
        const kv = tree.kvpairHeader(child);
        if (std.mem.eql(u8, kv.key, key_name)) return kv.value;
    }
    return null;
}

/// One `.enum_member` item per allowed unit suffix. Fires only when
/// `value_idx` is a bare-number AST node (no existing suffix) and the
/// cursor sits exactly at the value's end-of-span — the unambiguous
/// "user finished typing a number, may want a unit" signal. Partial
/// suffix (`120m|`, AST tag `.number_with_unit`) is deferred until
/// `CompletionItem` carries a `text_edit` for clean replacement.
fn unitSuffixCompletions(
    arena: Allocator,
    tree: *const Ast.Tree,
    value_idx: Ast.NodeIndex,
    units: []const []const u8,
    cursor: u32,
) Allocator.Error![]const CompletionItem {
    switch (tree.tagOf(value_idx)) {
        .number, .number_i64, .number_u64 => {},
        else => return &.{},
    }
    if (tree.spanOf(value_idx).end != cursor) return &.{};

    var items: std.ArrayList(CompletionItem) = .empty;
    try items.ensureTotalCapacity(arena, units.len);
    for (units) |u| {
        items.appendAssumeCapacity(.{
            .label = u,
            .kind = .enum_member,
            .detail = "unit suffix",
            .insert_text = u,
            .filter_text = u,
        });
    }
    return items.toOwnedSlice(arena);
}

fn keyDetail(arena: Allocator, key: sjon.Plugin.KeySpec) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try appendValueType(arena, &buf, key.value_type);
    if (!key.effectiveOptional()) try buf.appendSlice(arena, " (required)");
    return buf.toOwnedSlice(arena);
}

/// Build signature help for the form enclosing `byte_offset`. Returns
/// null when the document is unknown, the cursor isn't inside any form,
/// the cursor is on the head identifier itself (signature help is for
/// arguments — completion handles head context), or the head doesn't
/// resolve to a known form / expression function.
///
/// Active-parameter semantics:
///   * Forms: the index of the key whose kvpair span contains the
///     cursor. `null` when the cursor sits between kvpairs.
///   * Typed expr-funcs: the positional-argument index by counting
///     completed children before the cursor, capped at the rest slot
///     (when present) or the last fixed param. `null` for opaque funcs
///     (no `params` annotation).
pub fn getSignatureHelp(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    byte_offset: u32,
) Allocator.Error!?SignatureHelp {
    const doc = self.getDocument(uri) orelse return null;
    const idx = findEnclosingDelimIdxAtCursor(&doc.tree, doc.source, byte_offset, .form) orelse return null;
    const hdr = doc.tree.formHeader(idx);
    if (hdr.head.len == 0) return null;
    // Cursor still on the head — completion territory, not sig-help.
    if (containsOffset(hdr.head_span, byte_offset)) return null;

    switch (self.schema.lookupForm(hdr.head, hdr.namespace)) {
        .found => |hit| return try buildFormSignature(arena, hit, &doc.tree, hdr, byte_offset),
        else => {},
    }
    switch (self.schema.lookupExprFunc(hdr.head, hdr.namespace)) {
        .found => |hit| return try buildExprSignature(arena, hit, &doc.tree, hdr, byte_offset),
        else => return null,
    }
}

fn buildFormSignature(
    arena: Allocator,
    hit: Schema.FormHit,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    cursor: u32,
) Allocator.Error!SignatureHelp {
    var label: std.ArrayList(u8) = .empty;
    try appendQualifiedHead(arena, &label, hdr.namespace, hit.form.name);

    var params = try arena.alloc(Parameter, hit.form.keys.len);
    for (hit.form.keys, 0..) |k, i| {
        try label.append(arena, ' ');
        const start: u32 = @intCast(label.items.len);
        try label.append(arena, ':');
        try label.appendSlice(arena, k.name);
        // `?` suffix marks optional — keeps the label compact while still
        // visually distinguishing required keys for the user. A key with
        // `:default` is effectively optional even when `:optional false`.
        if (k.effectiveOptional()) try label.append(arena, '?');
        try label.append(arena, ' ');
        try appendValueType(arena, &label, k.value_type);
        params[i] = .{ .label_start = start, .label_end = @intCast(label.items.len) };
    }

    const active = activeKeyIndex(tree, hdr, hit.form.keys, cursor);

    const sigs = try arena.alloc(Signature, 1);
    sigs[0] = .{
        .label = try label.toOwnedSlice(arena),
        .documentation = hit.form.description,
        .parameters = params,
    };
    return .{ .signatures = sigs, .active_signature = 0, .active_parameter = active };
}

/// Signature help for an expression call. An overloaded function
/// (`signatures`) contributes one LSP signature per overload with the
/// call's own shape selecting the active one; the mono encoding is
/// handled as a one-element overload set, so there is a single code path.
fn buildExprSignature(
    arena: Allocator,
    hit: Schema.ExprHit,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    cursor: u32,
) Allocator.Error!SignatureHelp {
    const func = hit.func;
    const mono = [_]sjon.Plugin.ExprFunc.Signature{.{
        .arity = func.arity,
        .params = func.params,
        .param_names = func.param_names,
        .rest = func.rest,
        .result = func.result,
    }};
    const specs: []const sjon.Plugin.ExprFunc.Signature = func.signatures orelse mono[0..];
    std.debug.assert(specs.len > 0);

    const sigs = try arena.alloc(Signature, specs.len);
    for (specs, 0..) |s, i| {
        sigs[i] = try buildOneExprSignature(arena, hdr.namespace, func.name, s, func.description);
    }

    const active_sig = try chooseActiveSignature(arena, func, specs, tree, hdr);
    std.debug.assert(active_sig < specs.len);
    return .{
        .signatures = sigs,
        .active_signature = active_sig,
        .active_parameter = activeParamIndex(specs[active_sig], tree, hdr, cursor),
    };
}

/// Render one overload as an LSP signature: `f :a number → \`number\``.
/// Parameter ranges cover the label *and* the type, so a client
/// highlighting the active parameter highlights the whole slot.
fn buildOneExprSignature(
    arena: Allocator,
    namespace: ?[]const u8,
    name: []const u8,
    sig: sjon.Plugin.ExprFunc.Signature,
    documentation: []const u8,
) Allocator.Error!Signature {
    var label: std.ArrayList(u8) = .empty;
    try appendQualifiedHead(arena, &label, namespace, name);

    const fixed = sig.params orelse &.{};
    var params = try arena.alloc(Parameter, fixed.len + @intFromBool(sig.rest != null));
    for (fixed, 0..) |p, i| {
        try label.append(arena, ' ');
        const start: u32 = @intCast(label.items.len);
        // A labeled-call overload shows its parameter names — otherwise
        // two overloads that differ only by label render identically and
        // the picker can't be read.
        if (sig.param_names) |names| {
            if (i < names.len) {
                try label.append(arena, ':');
                try label.appendSlice(arena, names[i]);
                try label.append(arena, ' ');
            }
        }
        try appendValueType(arena, &label, p);
        params[i] = .{ .label_start = start, .label_end = @intCast(label.items.len) };
    }
    if (sig.rest) |r| {
        try label.append(arena, ' ');
        const start: u32 = @intCast(label.items.len);
        try label.appendSlice(arena, "...");
        try appendValueType(arena, &label, r);
        params[fixed.len] = .{ .label_start = start, .label_end = @intCast(label.items.len) };
    }
    // Untyped, no rest — surface a `…` so the label reads as a call rather
    // than a bare name; no parameter ranges to highlight.
    if (params.len == 0) try label.appendSlice(arena, " …");
    try appendResultArrow(arena, &label, sig.result);

    return .{
        .label = try label.toOwnedSlice(arena),
        .documentation = documentation,
        .parameters = params,
    };
}

/// Which overload the call as written selects.
///
/// Labeled calls go through `Schema.resolveExprArgs` — the same resolver
/// the validator and `Expr` use — rather than re-deriving label matching
/// here; overload selection has one implementation in the codebase and
/// this is not it. Positional calls narrow on argument count alone,
/// matching `Validator.resolveFormExpression`'s deliberate choice not to
/// unify literal argument types statically.
///
/// Falls back to the first overload when nothing matches (a call that is
/// mid-edit or simply wrong): showing the first signature beats showing
/// none while the user is still typing.
fn chooseActiveSignature(
    arena: Allocator,
    func: *const sjon.Plugin.ExprFunc,
    specs: []const sjon.Plugin.ExprFunc.Signature,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
) Allocator.Error!u32 {
    if (specs.len == 1) return 0;

    switch (try Schema.resolveExprArgs(arena, func.*, tree, hdr)) {
        .err => {},
        .ok => |r| {
            if (r.signature) |chosen| {
                if (indexOfSignature(specs, chosen)) |i| return i;
            }
        },
    }

    const argc = hdr.children.len;
    for (specs, 0..) |s, i| {
        if (s.checkArity(argc)) return @intCast(i);
    }
    return 0;
}

/// Position of `needle` within `specs`. `resolveExprArgs` hands back a
/// *copy* of the signature it chose, so the slices it borrows — not the
/// struct's bytes — are what tie it back to its slot in the overload set.
/// Only labeled signatures can be chosen this way, and `param_names` is
/// exactly what makes a signature labeled.
fn indexOfSignature(
    specs: []const sjon.Plugin.ExprFunc.Signature,
    needle: sjon.Plugin.ExprFunc.Signature,
) ?u32 {
    const want = needle.param_names orelse return null;
    for (specs, 0..) |s, i| {
        const have = s.param_names orelse continue;
        if (have.ptr == want.ptr and have.len == want.len) return @intCast(i);
    }
    return null;
}

/// Index of the parameter the cursor sits in, within `sig`.
fn activeParamIndex(
    sig: sjon.Plugin.ExprFunc.Signature,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    cursor: u32,
) ?u32 {
    const fixed_len = if (sig.params) |p| p.len else 0;
    if (fixed_len == 0 and sig.rest == null) return null;
    const arg_idx = positionalIndex(tree, hdr.children, cursor);
    if (arg_idx < fixed_len) return @intCast(arg_idx);
    if (sig.rest != null) return @intCast(fixed_len);
    // Past the last fixed param and no rest slot — out of range.
    return null;
}

/// ` → \`number\`` for a declared result; nothing when `result` is null.
/// One renderer so hover and signature help spell the arrow identically.
fn appendResultArrow(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    result: ?sjon.Plugin.ValueType,
) Allocator.Error!void {
    const r = result orelse return;
    try buf.appendSlice(arena, " → `");
    try appendValueType(arena, buf, r);
    try buf.append(arena, '`');
}

fn appendQualifiedHead(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    namespace: ?[]const u8,
    name: []const u8,
) Allocator.Error!void {
    if (namespace) |ns| {
        try buf.appendSlice(arena, ns);
        try buf.append(arena, '/');
    }
    try buf.appendSlice(arena, name);
}

/// Find the kvpair child that contains `cursor` and map it back to its
/// index in `keys`. Returns null when the cursor sits between kvpairs
/// or on a key the form doesn't declare.
fn activeKeyIndex(
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    keys: []const sjon.Plugin.KeySpec,
    cursor: u32,
) ?u32 {
    for (hdr.children) |c_idx| {
        if (tree.tagOf(c_idx) != .kvpair) continue;
        const span = tree.spanOf(c_idx);
        if (cursor < span.start) return null;
        if (cursor >= span.end) continue;
        const kv = tree.kvpairHeader(c_idx);
        for (keys, 0..) |k, i| {
            if (std.mem.eql(u8, k.name, kv.key)) return @intCast(i);
        }
        return null;
    }
    return null;
}

/// Count completed children before `cursor` to derive a positional arg
/// index. A child whose span contains the cursor counts as the active
/// arg (its index, not the next one).
fn positionalIndex(tree: *const Ast.Tree, children: []const Ast.NodeIndex, cursor: u32) usize {
    var i: usize = 0;
    for (children) |c| {
        const span = tree.spanOf(c);
        if (cursor < span.start) break;
        if (cursor < span.end) break;
        i += 1;
    }
    return i;
}

/// Smallest form whose span contains `pos`. Linear over node count —
/// fine for typical document sizes (parser caps at MAX_PARSE_DEPTH).
fn findEnclosingForm(tree: *const Ast.Tree, pos: u32) ?Ast.FormHeader {
    if (findEnclosingFormIdx(tree, pos)) |idx| return tree.formHeader(idx);
    return null;
}

/// `findEnclosingForm` companion that returns the node index instead of
/// the materialised header. Code-action paths need both: header for
/// schema lookup, span via the index for insertion-point math.
fn findEnclosingFormIdx(tree: *const Ast.Tree, pos: u32) ?Ast.NodeIndex {
    return smallestContainingIdx(tree, pos, .form);
}

/// Smallest form whose span strictly contains `child`'s span — i.e. the
/// parent form in the AST nesting. Linear over node count; matches the
/// `findEnclosing*` family's strategy. Returns null at the top level.
fn findParentFormIdx(tree: *const Ast.Tree, child: Ast.NodeIndex) ?Ast.NodeIndex {
    const child_span = tree.spanOf(child);
    var best: ?Ast.NodeIndex = null;
    var best_size: u32 = std.math.maxInt(u32);
    const tags = tree.nodes.items(.tag);
    var i: u32 = 0;
    while (i < tags.len) : (i += 1) {
        if (tags[i] != .form) continue;
        const idx = Ast.NodeIndex.from(i);
        if (@intFromEnum(idx) == @intFromEnum(child)) continue;
        const span = tree.spanOf(idx);
        if (span.start > child_span.start or span.end < child_span.end) continue;
        const size = span.end - span.start;
        if (size < best_size) {
            best = idx;
            best_size = size;
        }
    }
    return best;
}

/// Canonicalise `head` (with optional `namespace`) into the
/// `"<plugin>/<form>"` form the cross-ref index keys against. Mirrors
/// the inline canonicalisation used in `completionsForCrossRef` for
/// `target_form`; reused for ancestor-walk scope resolution so both
/// paths agree on identity. If `head` itself carries a `plugin/name`
/// slash and `namespace` is null, the slash is split here so callers
/// can pass either bare or already-qualified strings. Returns null
/// when the schema lookup is `.not_found` or `.ambiguous` (caller
/// treats both as "no candidates").
fn canonicaliseFormHead(
    self: *const Self,
    arena: Allocator,
    head: []const u8,
    namespace: ?[]const u8,
) Allocator.Error!?[]const u8 {
    var ns = namespace;
    var name = head;
    if (ns == null) {
        if (std.mem.indexOfScalar(u8, head, '/')) |slash| {
            ns = head[0..slash];
            name = head[slash + 1 ..];
        }
    }
    const hit = switch (self.schema.lookupForm(name, ns)) {
        .found => |h| h,
        else => return null,
    };
    return try std.fmt.allocPrint(arena, "{s}/{s}", .{ hit.plugin.name, hit.form.name });
}

/// Walk the ancestor chain from `start` (inclusive) toward the root,
/// returning the innermost form whose canonical head equals
/// `canonical_scope`. Ancestors whose head doesn't resolve in the
/// schema are skipped (the walker continues upward). Returns null when
/// no ancestor matches — caller emits "no candidates" so completions
/// agree with the validator's `cross_ref_outside_scope` diagnostic.
///
/// Used by scope-aware cross-ref completion: given a `xref.scope_form`,
/// the LSP must find the nearest enclosing instance of that form to
/// pick the right `ScopeId.lexical(...)` — `lexical_id` is the form's
/// `@intFromEnum(NodeIndex)` (see `Validator.ScopeId.lexical`).
fn findEnclosingScopeFormIdx(
    self: *const Self,
    arena: Allocator,
    tree: *const Ast.Tree,
    start: Ast.NodeIndex,
    canonical_scope: []const u8,
) Allocator.Error!?Ast.NodeIndex {
    var cur: ?Ast.NodeIndex = start;
    while (cur) |idx| {
        const hdr = tree.formHeader(idx);
        if (try self.canonicaliseFormHead(arena, hdr.head, hdr.namespace)) |canon| {
            if (std.mem.eql(u8, canon, canonical_scope)) return idx;
        }
        cur = findParentFormIdx(tree, idx);
    }
    return null;
}

/// Linear scan for the kvpair node whose `key_span` exactly matches.
/// Used by `expr_kvpair_not_allowed` to recover the value node from the
/// diagnostic's key-only span. Key spans are unique within a tree because
/// each comes from a distinct source-byte range.
fn findKvpairByKeySpan(tree: *const Ast.Tree, key_span: Ast.Span) ?Ast.NodeIndex {
    const tags = tree.nodes.items(.tag);
    var i: u32 = 0;
    while (i < tags.len) : (i += 1) {
        if (tags[i] != .kvpair) continue;
        const idx = Ast.NodeIndex.from(i);
        const kvh = tree.kvpairHeader(idx);
        if (kvh.key_span.start == key_span.start and kvh.key_span.end == key_span.end) {
            return idx;
        }
    }
    return null;
}

/// Print the document via SJON's `Printer` (full mode — comments
/// preserved). Returns null when the document is unknown OR has parse
/// errors (we don't reformat broken syntax). The returned slice has
/// exactly one whole-document edit.
pub fn getFormatEdits(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
) Allocator.Error!?[]const TextEdit {
    const doc = self.getDocument(uri) orelse return null;
    if (doc.tree.hasErrors()) return null;

    const printed = try sjon.Printer.print(arena, doc.tree, .{ .mode = .full });
    const edits = try arena.alloc(TextEdit, 1);
    edits[0] = .{
        .span_start = 0,
        .span_end = @intCast(doc.source.len),
        .new_text = printed.data,
    };
    return edits;
}

/// Reformat only the top-level roots whose spans intersect
/// `[range_start, range_end)`, one `TextEdit` per covering root replacing
/// that root's own span. Returns null on unknown / parse-error documents
/// (parity with `getFormatEdits`); returns a non-null **empty** slice when
/// the range covers no root (e.g. it lies wholly in inter-root
/// whitespace) — "nothing to format" is distinct from "cannot format".
///
/// Each covering root is cloned into a single-root temp tree via
/// `TreeBuilder.cloneNode` and printed in `.full` mode. The clone's
/// **top-level leading comments are suppressed** before printing: a root
/// node's span does not cover the comments that lead it (they sit in the
/// inter-root gap), so printing them and replacing only the node span
/// would duplicate them. Inner comments (before children, before kvpair
/// values, trailing inside a form/vector) are on descendant nodes and are
/// preserved by the clone — those *are* inside the replaced span.
pub fn getRangeFormatEdits(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    range_start: u32,
    range_end: u32,
) Allocator.Error!?[]const TextEdit {
    const doc = self.getDocument(uri) orelse return null;
    if (doc.tree.hasErrors()) return null;

    var edits: std.ArrayList(TextEdit) = .empty;
    defer edits.deinit(arena);

    for (doc.tree.root) |root_idx| {
        const span = doc.tree.spanOf(root_idx);
        // Half-open intersection: a root [s,e) covers the request iff
        // `s < range_end and e > range_start`. A zero-width request
        // (start == end, e.g. a cursor) then matches only a root that
        // strictly contains it, so a cursor in inter-root whitespace
        // yields no edits.
        if (!(span.start < range_end and span.end > range_start)) continue;

        const new_text = try self.printRootFull(arena, &doc.tree, root_idx);
        try edits.append(arena, .{
            .span_start = span.start,
            .span_end = span.end,
            .new_text = new_text,
        });
    }

    return try edits.toOwnedSlice(arena);
}

/// Clone one root into a fresh single-root tree, suppress its top-level
/// leading comments (see `getRangeFormatEdits`), print `.full`, and
/// return the printed bytes with the trailing newline trimmed — the
/// printer terminates a document with `\n`, but a range edit replaces a
/// mid-document node span and must not inject one. Bytes are owned by
/// `arena`; the temp tree's own arena is released before return.
fn printRootFull(
    self: *const Self,
    arena: Allocator,
    tree: *const Ast.Tree,
    root_idx: Ast.NodeIndex,
) Allocator.Error![]const u8 {
    var tmp_arena = std.heap.ArenaAllocator.init(self.allocator);
    // Covers an OOM before `finalize` takes ownership; after finalize the
    // slot holds a fresh empty arena and `tmp_tree.deinit()` owns the real
    // one (matches the `cloneTree` test helper's contract).
    errdefer tmp_arena.deinit();
    var b: Ast.TreeBuilder = .{ .a = tmp_arena.allocator() };
    const roots = try tmp_arena.allocator().alloc(Ast.NodeIndex, 1);
    roots[0] = try b.cloneNode(tree, root_idx);
    b.setLeading(roots[0], .empty);

    var tmp_tree = try b.finalize(&tmp_arena, "", roots);
    defer tmp_tree.deinit();

    const printed = try sjon.Printer.print(arena, tmp_tree, .{ .mode = .full });
    return std.mem.trimEnd(u8, printed.data, "\n");
}

// ---------------------------------------------------------------------
// Bounded frame-stack tree walk
//
// The folding-range and inlay-hint services descend the SoA tree by the
// same rule: a form yields its header children, a vector its elements, a
// kvpair its value, a leaf nothing. `NodeWalker` is that rule expressed
// once — a pre-order iterator backed by a heap frame stack, so the
// descent never uses the host stack (matching the Parser/Validator/Expr
// discipline). Its depth ceiling mirrors the parser's own
// `MAX_PARSE_DEPTH`, so a pathologically nested document can't grow the
// frame stack without bound. Each yielded node also carries the head /
// namespace of its nearest enclosing form (null at the top level).
//
// The document-symbol and hover services descend the same tree but do
// not fit this iterator: `appendSymbols` is a tree *transform* (forms
// nest, vectors/kvpairs flatten) that assembles its output post-order,
// and the hover descent threads context toward a single cursor position
// and short-circuits. Both stay recursive; both are bounded by the
// parser's depth cap (see `findEnclosingForm`'s note).
// ---------------------------------------------------------------------

/// One node yielded by `NodeWalker`, tagged with its nearest enclosing
/// form's head / namespace (null at the document top level, unchanged
/// across transparent vector / kvpair nesting).
const WalkNode = struct {
    idx: Ast.NodeIndex,
    enclosing_head: ?[]const u8,
    enclosing_ns: ?[]const u8,
};

/// Pre-order tree iterator with a heap frame stack — the shared descent
/// for the LSP's whole-document walks. `init` seeds the stack with the
/// document roots; `next` yields each node once, in document order,
/// pushing its traversal children for later descent.
const NodeWalker = struct {
    tree: *const Ast.Tree,
    arena: Allocator,
    stack: std.ArrayList(Level),

    /// The ceiling on frame-stack depth. The parser refuses to build a
    /// tree deeper than this, so it is defensive for parser-produced
    /// trees — but it guarantees the frame stack is bounded regardless of
    /// where the tree came from.
    const MAX_WALK_DEPTH: usize = Parser.MAX_PARSE_DEPTH;

    /// A node's traversal children: a form's / vector's slice, a kvpair's
    /// single value, or nothing for a leaf. Normalising the kvpair's lone
    /// value into the same shape keeps the walk loop switch-free.
    const Kids = union(enum) {
        slice: []const Ast.NodeIndex,
        one: Ast.NodeIndex,
        none,

        fn len(k: Kids) usize {
            return switch (k) {
                .slice => |s| s.len,
                .one => 1,
                .none => 0,
            };
        }
        fn at(k: Kids, i: usize) Ast.NodeIndex {
            return switch (k) {
                .slice => |s| s[i],
                .one => |n| n,
                .none => unreachable,
            };
        }
    };

    const Level = struct {
        kids: Kids,
        i: usize,
        enclosing_head: ?[]const u8,
        enclosing_ns: ?[]const u8,
    };

    fn init(arena: Allocator, tree: *const Ast.Tree, roots: []const Ast.NodeIndex) Allocator.Error!NodeWalker {
        var w: NodeWalker = .{ .tree = tree, .arena = arena, .stack = .empty };
        try w.stack.append(arena, .{ .kids = .{ .slice = roots }, .i = 0, .enclosing_head = null, .enclosing_ns = null });
        return w;
    }

    fn childrenOf(tree: *const Ast.Tree, idx: Ast.NodeIndex) Kids {
        return switch (tree.tagOf(idx)) {
            .form => .{ .slice = tree.formHeader(idx).children },
            .vector => .{ .slice = tree.vectorElements(idx) },
            .kvpair => .{ .one = tree.kvpairHeader(idx).value },
            else => .none,
        };
    }

    /// Next node in pre-order, or null when the walk is exhausted.
    fn next(self: *NodeWalker) Allocator.Error!?WalkNode {
        while (self.stack.items.len > 0) {
            const top = &self.stack.items[self.stack.items.len - 1];
            if (top.i >= top.kids.len()) {
                _ = self.stack.pop();
                continue;
            }
            const idx = top.kids.at(top.i);
            top.i += 1;
            const node: WalkNode = .{
                .idx = idx,
                .enclosing_head = top.enclosing_head,
                .enclosing_ns = top.enclosing_ns,
            };
            // Push idx's children so the next `next()` descends into them
            // before advancing to idx's sibling (pre-order). A form
            // re-bases the enclosing context; vectors/kvpairs inherit it.
            if (self.stack.items.len < MAX_WALK_DEPTH) {
                const kids = childrenOf(self.tree, idx);
                if (kids.len() > 0) {
                    var enc_head = node.enclosing_head;
                    var enc_ns = node.enclosing_ns;
                    if (self.tree.tagOf(idx) == .form) {
                        const hdr = self.tree.formHeader(idx);
                        enc_head = hdr.head;
                        enc_ns = hdr.namespace;
                    }
                    try self.stack.append(self.arena, .{
                        .kids = kids,
                        .i = 0,
                        .enclosing_head = enc_head,
                        .enclosing_ns = enc_ns,
                    });
                }
            }
            return node;
        }
        return null;
    }
};

/// Build a hierarchical symbol tree — every form is a node, qualified
/// heads keep their `ns/head` name. Vectors and kvpair wrappers are
/// flattened: a `[(rect …) (circle …)]` value contributes two
/// sibling symbols, not a vector node. Returns null when the document
/// is unknown.
pub fn getDocumentSymbols(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
) Allocator.Error!?[]const DocumentSymbol {
    const doc = self.getDocument(uri) orelse return null;

    var roots: std.ArrayList(DocumentSymbol) = .empty;
    for (doc.tree.root) |idx| {
        try appendSymbols(arena, &doc.tree, idx, &roots);
    }
    const out: []const DocumentSymbol = try roots.toOwnedSlice(arena);
    return out;
}

fn appendSymbols(
    arena: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    out: *std.ArrayList(DocumentSymbol),
) Allocator.Error!void {
    switch (tree.tagOf(idx)) {
        .form => {
            const hdr = tree.formHeader(idx);
            const name = if (hdr.namespace) |ns|
                try std.fmt.allocPrint(arena, "{s}/{s}", .{ ns, hdr.head })
            else
                try arena.dupe(u8, hdr.head);
            var children: std.ArrayList(DocumentSymbol) = .empty;
            for (hdr.children) |c| try appendSymbols(arena, tree, c, &children);
            const span = tree.spanOf(idx);
            try out.append(arena, .{
                .name = name,
                .span_start = span.start,
                .span_end = span.end,
                .selection_start = hdr.head_span.start,
                .selection_end = hdr.head_span.end,
                .children = try children.toOwnedSlice(arena),
            });
        },
        .kvpair => {
            const kv = tree.kvpairHeader(idx);
            try appendSymbols(arena, tree, kv.value, out);
        },
        .vector => {
            for (tree.vectorElements(idx)) |el| try appendSymbols(arena, tree, el, out);
        },
        else => {},
    }
}

/// Enumerate every form `(...)` and vector `[...]` in the document
/// as a foldable region. Returns null when the document is unknown.
/// The transport drops single-line ranges and translates byte spans
/// into LSP positions.
pub fn getFoldingRanges(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
) Allocator.Error!?[]const FoldingRange {
    const doc = self.getDocument(uri) orelse return null;
    var out: std.ArrayList(FoldingRange) = .empty;
    var walker = try NodeWalker.init(arena, &doc.tree, doc.tree.root);
    while (try walker.next()) |node| {
        switch (doc.tree.tagOf(node.idx)) {
            .form, .vector => {
                const span = doc.tree.spanOf(node.idx);
                try out.append(arena, .{ .span_start = span.start, .span_end = span.end });
            },
            else => {},
        }
    }
    return try out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------
// Semantic tokens
// ---------------------------------------------------------------------

/// Classify every schema-resolvable construct in the document. One
/// `NodeWalker` pass applying the same resolution hover does per cursor —
/// heads against the form/expr vocabularies, `:key`s against the enclosing
/// form's spec, symbol values against member sets, and names against the
/// cross-ref index.
///
/// Returns null when the document is unknown; an empty slice when nothing
/// resolved (an all-unknown document is a legitimately colourless one).
/// The result is sorted ascending and disjoint — see `SemanticToken`.
///
/// O(nodes × schema lookup) plus one pass over the cross-ref index.
pub fn getSemanticTokens(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
) Allocator.Error!?[]const SemanticToken {
    const doc = self.getDocument(uri) orelse return null;
    const xrefs = try self.crossRefSpans(arena, uri);

    var out: std.ArrayList(SemanticToken) = .empty;
    var walker = try NodeWalker.init(arena, &doc.tree, doc.tree.root);
    while (try walker.next()) |node| {
        switch (doc.tree.tagOf(node.idx)) {
            .form => try self.appendHeadTokens(arena, &out, doc.tree.formHeader(node.idx)),
            .kvpair => try self.appendKvpairTokens(arena, &out, &doc.tree, node, &xrefs),
            .symbol => try appendCrossRefToken(arena, &out, doc.tree.spanOf(node.idx), &xrefs),
            else => {},
        }
    }

    const toks = try out.toOwnedSlice(arena);
    // Pre-order yields heads before their children, but a kvpair emits its
    // key *and* its member value while the value's own node comes later —
    // so document order is nearly right and one sort makes it exact.
    // Stable, so equal starts (which the disjointness assert then rejects)
    // can't vary run to run.
    std.mem.sort(SemanticToken, toks, {}, tokenLessThan);
    if (toks.len > 1) {
        for (toks[1..], toks[0 .. toks.len - 1]) |cur, prev| {
            std.debug.assert(prev.span_end <= cur.span_start);
        }
    }
    return toks;
}

fn tokenLessThan(_: void, a: SemanticToken, b: SemanticToken) bool {
    return a.span_start < b.span_start;
}

/// Pack a span into a hash-map key. Spans are byte offsets into one
/// document, so `(start, end)` fits a u64 with room to spare.
fn spanKey(span: Ast.Span) u64 {
    return (@as(u64, span.start) << 32) | @as(u64, span.end);
}

/// Every cross-ref site in `uri`'s tree, mapped span → is-definition.
///
/// Built once per request rather than calling `locateCrossRefSite` per
/// symbol: that scan is O(index) because it searches *for* one span, and
/// a whole-document walk would pay it once per symbol node. Same traversal,
/// inverted.
///
/// An empty map when there is no index yet or the document isn't in the
/// forest — both mean "no cross-ref colour", not an error.
fn crossRefSpans(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
) Allocator.Error!std.AutoHashMapUnmanaged(u64, bool) {
    var map: std.AutoHashMapUnmanaged(u64, bool) = .empty;
    const index = if (self.cross_ref_index) |*ix| ix else return map;
    const tree_idx = self.uri_to_tree_idx.get(uri) orelse return map;

    var def_scopes = index.by_scope.iterator();
    while (def_scopes.next()) |scope_entry| {
        var targets = scope_entry.value_ptr.iterator();
        while (targets.next()) |target_entry| {
            var names = target_entry.value_ptr.iterator();
            while (names.next()) |name_entry| {
                const site = name_entry.value_ptr.*;
                if (site.tree_idx != tree_idx) continue;
                try map.put(arena, spanKey(site.name_span), true);
            }
        }
    }

    var ref_scopes = index.references_by_scope.iterator();
    while (ref_scopes.next()) |scope_entry| {
        var targets = scope_entry.value_ptr.iterator();
        while (targets.next()) |target_entry| {
            var names = target_entry.value_ptr.iterator();
            while (names.next()) |name_entry| {
                for (name_entry.value_ptr.items) |site| {
                    if (site.tree_idx != tree_idx) continue;
                    // Definitions win a tie, matching how
                    // `locateCrossRefSite` orders its two scans.
                    const gop = try map.getOrPut(arena, spanKey(site.name_span));
                    if (!gop.found_existing) gop.value_ptr.* = false;
                }
            }
        }
    }
    return map;
}

/// A form head: the resolved head itself, preceded by its `ns` qualifier
/// when the author wrote one. Emits nothing for an unknown head (the
/// `unknown_form` squiggle says it better) or an ambiguous one (two
/// answers, and the quickfix is to qualify it).
fn appendHeadTokens(
    self: *const Self,
    arena: Allocator,
    out: *std.ArrayList(SemanticToken),
    hdr: Ast.FormHeader,
) Allocator.Error!void {
    if (hdr.head.len == 0) return;

    var kind: SemanticToken.Type = undefined;
    var owner: *const sjon.Plugin.Plugin = undefined;
    switch (self.schema.lookupForm(hdr.head, hdr.namespace)) {
        .found => |hit| {
            kind = .macro;
            owner = hit.plugin;
        },
        else => switch (self.schema.lookupExprFunc(hdr.head, hdr.namespace)) {
            .found => |hit| {
                kind = .function;
                owner = hit.plugin;
            },
            else => return,
        },
    }

    // `head_span` covers the token as written — `ns/head` and all — so the
    // qualifier's span is arithmetic on it rather than a stored field.
    var head_start = hdr.head_span.start;
    if (hdr.namespace) |ns| {
        const ns_len: u32 = @intCast(ns.len);
        std.debug.assert(hdr.head_span.end - hdr.head_span.start == ns_len + 1 + hdr.head.len);
        try out.append(arena, .{
            .span_start = hdr.head_span.start,
            .span_end = hdr.head_span.start + ns_len,
            .type = .namespace,
        });
        head_start += ns_len + 1; // past the `/`, which is neither token
    }

    try out.append(arena, .{
        .span_start = head_start,
        .span_end = hdr.head_span.end,
        .type = kind,
        .mods = .{ .default_library = std.mem.eql(u8, owner.name, "core") },
    });
}

/// A `:key` the enclosing form declares, plus that key's value when it
/// names a member of a member set. An undeclared key emits nothing.
fn appendKvpairTokens(
    self: *const Self,
    arena: Allocator,
    out: *std.ArrayList(SemanticToken),
    tree: *const Ast.Tree,
    node: WalkNode,
    xrefs: *const std.AutoHashMapUnmanaged(u64, bool),
) Allocator.Error!void {
    const enclosing = node.enclosing_head orelse return;
    const hit = switch (self.schema.lookupForm(enclosing, node.enclosing_ns)) {
        .found => |h| h,
        else => return,
    };
    const kv = tree.kvpairHeader(node.idx);
    const key = hit.form.keyByName(kv.key) orelse return;

    // The span includes the leading `:` — `:radius` reads as one thing.
    try out.append(arena, .{
        .span_start = kv.key_span.start,
        .span_end = kv.key_span.end,
        .type = .property,
    });

    if (tree.tagOf(kv.value) != .symbol) return;
    const value_span = tree.spanOf(kv.value);
    // A cross-ref site is coloured by the `.symbol` arm; two tokens over
    // one span is not a shape the relative wire encoding can express.
    if (xrefs.contains(spanKey(value_span))) return;

    const named = switch (key.value_type) {
        .named => |n| n,
        else => return,
    };
    const value_kind = switch (self.schema.lookupValueKind(named.name, named.namespace)) {
        .found => |k| k,
        else => return,
    };
    const set = value_kind.members orelse return;
    const text = tree.symbolText(kv.value);
    for (set.members) |member| {
        if (!std.mem.eql(u8, member.name, text)) continue;
        try out.append(arena, .{
            .span_start = value_span.start,
            .span_end = value_span.end,
            .type = .enum_member,
            .mods = .{ .deprecated = member.deprecated },
        });
        return;
    }
}

/// A symbol registered in the cross-ref index, as a definition or a use.
/// Symbols the index doesn't know — `let` binding names, positional
/// arguments, plain data — emit nothing.
fn appendCrossRefToken(
    arena: Allocator,
    out: *std.ArrayList(SemanticToken),
    span: Ast.Span,
    xrefs: *const std.AutoHashMapUnmanaged(u64, bool),
) Allocator.Error!void {
    const is_definition = xrefs.get(spanKey(span)) orelse return;
    try out.append(arena, .{
        .span_start = span.start,
        .span_end = span.end,
        .type = .variable,
        .mods = .{ .declaration = is_definition },
    });
}

/// Structural expand-selection: for each byte offset, the chain of spans
/// an editor cycles through as the user widens the selection — innermost
/// first, out to the enclosing root. One chain per offset, positionally
/// matched (LSP requires that arity). Returns null when the document is
/// unknown.
///
/// O(offsets × depth × siblings).
pub fn getSelectionRanges(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    offsets: []const u32,
) Allocator.Error!?[]const []const SelectionRange {
    const doc = self.getDocument(uri) orelse return null;
    const chains = try arena.alloc([]const SelectionRange, offsets.len);
    for (offsets, chains) |pos, *slot| {
        slot.* = try selectionChainAt(arena, &doc.tree, pos);
    }
    std.debug.assert(chains.len == offsets.len);
    return chains;
}

/// One offset's ancestor chain, innermost first.
///
/// Descends from the root containing `pos` through whichever child also
/// contains it, so the chain is an ancestor path *by construction* —
/// no span-overlap heuristics, and no dependence on unreachable nodes
/// being absent from the SoA arrays. Iterative, so a deep document
/// costs heap rather than host stack.
///
/// Two spans in a chain are not tree nodes: a form's head identifier
/// and a kvpair's `:key`. Both live in their parent's header, so when
/// `pos` lands on one it is prepended as the innermost link and the
/// walk ends there — expanding off `widget` selects `widget`, then
/// `(widget …)`.
///
/// An offset inside no root at all — whitespace between top-level
/// forms — yields an empty chain: there is nothing to expand to, and
/// the document as a whole is not a node.
fn selectionChainAt(
    arena: Allocator,
    tree: *const Ast.Tree,
    pos: u32,
) Allocator.Error![]const SelectionRange {
    var current: Ast.NodeIndex = for (tree.root) |idx| {
        if (containsOffset(tree.spanOf(idx), pos)) break idx;
    } else return &.{};

    var out: std.ArrayList(SelectionRange) = .empty;
    var depth: usize = 0;
    // Built outermost-first because that is the direction the descent
    // runs; reversed once at the end.
    descend: while (depth < NodeWalker.MAX_WALK_DEPTH) : (depth += 1) {
        try appendSelectionSpan(arena, &out, tree.spanOf(current));

        const header_span: ?Ast.Span = switch (tree.tagOf(current)) {
            .form => tree.formHeader(current).head_span,
            .kvpair => tree.kvpairHeader(current).key_span,
            else => null,
        };
        if (header_span) |hs| {
            if (containsOffset(hs, pos)) {
                try appendSelectionSpan(arena, &out, hs);
                break;
            }
        }

        const kids = NodeWalker.childrenOf(tree, current);
        var i: usize = 0;
        while (i < kids.len()) : (i += 1) {
            const child = kids.at(i);
            if (containsOffset(tree.spanOf(child), pos)) {
                current = child;
                continue :descend;
            }
        }
        break;
    }

    std.debug.assert(out.items.len > 0);
    std.mem.reverse(SelectionRange, out.items);
    if (std.debug.runtime_safety) {
        // Every link encloses the one before it: the chain only ever
        // widens, so an editor pressing "expand" never shrinks.
        for (out.items[1..], out.items[0 .. out.items.len - 1]) |outer, inner| {
            std.debug.assert(outer.span_start <= inner.span_start);
            std.debug.assert(outer.span_end >= inner.span_end);
        }
    }
    return out.items;
}

/// Append `span` unless it repeats the last link. A node whose span
/// equals its parent's would otherwise produce an expansion step that
/// selects nothing new — clients render that as a dead keypress.
fn appendSelectionSpan(
    arena: Allocator,
    out: *std.ArrayList(SelectionRange),
    span: Ast.Span,
) Allocator.Error!void {
    if (out.items.len > 0) {
        const last = out.items[out.items.len - 1];
        if (last.span_start == span.start and last.span_end == span.end) return;
    }
    try out.append(arena, .{ .span_start = span.start, .span_end = span.end });
}

/// Walk the document and emit inlay hints: one per bare form head that
/// resolves to a non-`core` plugin, plus one ghost `:key value` per
/// omitted-but-defaulted key on each form. `range_start`/`range_end`
/// clip the output to what the request covers — editors typically pass
/// the viewport, so out-of-view forms waste no bytes.
pub fn getInlayHints(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    range_start: u32,
    range_end: u32,
) Allocator.Error!?[]const InlayHint {
    const doc = self.getDocument(uri) orelse return null;
    var out: std.ArrayList(InlayHint) = .empty;
    var walker = try NodeWalker.init(arena, &doc.tree, doc.tree.root);
    while (try walker.next()) |node| {
        if (doc.tree.tagOf(node.idx) != .form) continue;
        const hdr = doc.tree.formHeader(node.idx);
        try self.maybeAppendHeadHint(arena, hdr, range_start, range_end, &out);
        try self.appendDefaultHints(arena, doc, node.idx, hdr, range_start, range_end, &out);
    }
    return try out.toOwnedSlice(arena);
}

/// Cap on the rendered value inside a ghost-default label, in bytes.
/// Past this the value is truncated at a codepoint boundary and an
/// ellipsis appended. Inlay hints share the code line with the code —
/// a hint wider than the expression it annotates hides the source it is
/// supposed to explain, and the exact value is a hover away.
pub const MAX_HINT_VALUE_BYTES = 32;

/// Emit one `:key value` ghost hint per overlay entry belonging to
/// `form_idx`, positioned on the form's closing paren — where the key
/// would go if the author wrote it, and where CP3's materialize action
/// inserts it.
fn appendDefaultHints(
    self: *const Self,
    arena: Allocator,
    doc: *const Document,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    range_start: u32,
    range_end: u32,
    out: *std.ArrayList(InlayHint),
) Allocator.Error!void {
    if (doc.materialized.entries.len == 0) return;

    const span = doc.tree.spanOf(form_idx);
    // A form the parser recovered from may end at EOF rather than on a
    // `)`. Anchoring a hint there drops ghost text into the middle of
    // the identifier the user is still typing, so skip until the form
    // is closed. The overlay itself stays populated — only the display
    // waits.
    if (span.end == 0 or span.end > doc.source.len) return;
    const anchor = span.end - 1;
    if (doc.source[anchor] != ')') return;
    if (!spanOverlaps(.{ .start = anchor, .end = span.end }, range_start, range_end)) return;

    // Resolved once per form, not once per entry: the entries already
    // name keys this form declares, so a single lookup serves them all.
    const form_spec: ?*const sjon.Plugin.FormSpec = switch (self.schema.lookupForm(hdr.head, hdr.namespace)) {
        .found => |hit| hit.form,
        else => null,
    };

    for (doc.materialized.entries) |*entry| {
        if (entry.form != form_idx) continue;

        // Faithfulness is ignored here and honoured by the materialize
        // action: an approximate rendering is fine to *show* and not
        // fine to *write*.
        var value: std.ArrayList(u8) = .empty;
        _ = try sjon.EffectiveDocument.appendEffectiveValue(arena, &value, entry, form_spec);

        var label: std.ArrayList(u8) = .empty;
        try label.append(arena, ':');
        try label.appendSlice(arena, entry.key);
        try label.append(arena, ' ');
        try appendTruncated(arena, &label, value.items);

        try out.append(arena, .{
            .offset = anchor,
            .label = try label.toOwnedSlice(arena),
            .kind = .parameter,
            .padding_left = true,
        });
    }
}

/// Append `value`, capped at `MAX_HINT_VALUE_BYTES` with an ellipsis.
/// Hint-only: the materialize action writes source into the document and
/// must never truncate it.
fn appendTruncated(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    value: []const u8,
) Allocator.Error!void {
    if (value.len <= MAX_HINT_VALUE_BYTES) {
        try buf.appendSlice(arena, value);
        return;
    }
    // Back off to a codepoint boundary: a label cut mid-sequence is
    // invalid UTF-8, which the transports would then have to serialize
    // into JSON.
    var cut: usize = MAX_HINT_VALUE_BYTES;
    while (cut > 0 and value[cut] & 0xC0 == 0x80) cut -= 1;
    try buf.appendSlice(arena, value[0..cut]);
    try buf.appendSlice(arena, "…");
}

/// Render `entry`'s effective value as the SJON source an author would
/// write. Returns false when that rendering is **not** faithful — i.e.
/// what landed in `buf` is a display approximation that must not be
/// written back into the document. Today that means a form value
/// anywhere in the tree: `Expr.Value.form` has lost the kvpair order and
/// comments the author's source had, so `(head …)` is the honest display
/// and there is no honest insertion.
///
/// Literal defaults render from the schema's `KeySpec.Default`, not from
/// the materialized `Expr.Value`, because the value is lossy for exactly
/// one arm: `Default.symbol` becomes `Expr.Value.keyword` (the runtime
/// value type has no symbol variant), so a `:default fast` would render
/// as `:fast` — a keyword where the schema declared a symbol. Harmless
/// in a hint, wrong in CP3's inserted text, and the two must agree about
/// what materializing produces.
///
/// Expression defaults have no literal to fall back on and render from
/// the computed value: showing `(* 2 16)` would just repeat what hover
/// already says, whereas `32` is the thing the document effectively
/// carries.
// `appendEffectiveValue` / `appendExprValue` moved to
// `sjon.EffectiveDocument` with the splicer (devx plan 02 CP3).

fn maybeAppendHeadHint(
    self: *const Self,
    arena: Allocator,
    hdr: Ast.FormHeader,
    range_start: u32,
    range_end: u32,
    out: *std.ArrayList(InlayHint),
) Allocator.Error!void {
    if (hdr.head.len == 0) return;
    // Qualified heads already display the plugin in source — adding a
    // hint would just duplicate `ui/widget` as `ui/widget ui`.
    if (hdr.namespace != null) return;
    if (!spanOverlaps(hdr.head_span, range_start, range_end)) return;

    const plugin: *const sjon.Plugin.Plugin = blk: {
        switch (self.schema.lookupForm(hdr.head, null)) {
            .found => |hit| break :blk hit.plugin,
            else => {},
        }
        switch (self.schema.lookupExprFunc(hdr.head, null)) {
            .found => |hit| break :blk hit.plugin,
            else => return,
        }
    };
    // Skip core: it's the implicit baseline (`+`, `if`, `vec3` are in
    // every file), and hinting them everywhere drowns out the cases
    // where the source plugin actually carries information.
    if (std.mem.eql(u8, plugin.name, "core")) return;

    try out.append(arena, .{
        .offset = hdr.head_span.end,
        .label = plugin.name,
        .padding_left = true,
    });
}

/// Build quickfix code actions for any diagnostic whose span overlaps
/// `[range_start, range_end)`. Each diagnostic code maps to its own
/// fix family — see `appendActionsFor` for the dispatch.
pub fn getCodeActions(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    range_start: u32,
    range_end: u32,
) Allocator.Error!?[]const CodeAction {
    const doc = self.getDocument(uri) orelse return null;

    var actions: std.ArrayList(CodeAction) = .empty;
    // The validator emits one `missing_required_key` diagnostic per
    // missing key, all sharing the form's `head_span`. We enumerate all
    // missing keys for that form on the first encounter and skip the
    // rest, so each missing key surfaces exactly one quickfix.
    var seen_missing_forms: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (doc.tree.diagnostics) |d| {
        if (!spanOverlaps(d.span, range_start, range_end)) continue;
        try self.appendActionsFor(arena, uri, doc, d, &actions, &seen_missing_forms);
    }
    for (doc.validate_result.diagnostics) |d| {
        if (!spanOverlaps(d.span, range_start, range_end)) continue;
        try self.appendActionsFor(arena, uri, doc, d, &actions, &seen_missing_forms);
    }
    try self.appendMaterializeAction(arena, doc, range_start, &actions);
    try self.appendExtractAction(arena, uri, doc, range_start, range_end, &actions);
    try self.appendInlineAction(arena, uri, doc, range_start, &actions);
    const out: []const CodeAction = try actions.toOwnedSlice(arena);
    return out;
}

/// Offer "Materialize omitted defaults" for the form under the cursor:
/// one edit inserting every key the schema defaults and the author left
/// out, in schema order, immediately before the closing paren.
///
/// The only action here that is **not** diagnostic-bound. Every other
/// one answers a squiggle; this one answers a question ("what is this
/// form actually configured as?") about a document with nothing wrong
/// with it. That is why it hangs off `range_start` — the cursor — rather
/// than off a diagnostic span, and why it carries no `diagnostics`.
///
/// Scoped to the innermost enclosing form, not the whole document: with
/// nested forms the user is looking at one of them, and materializing an
/// outer form's defaults while the cursor sits in an inner one would
/// edit text they are not reading.
fn appendMaterializeAction(
    self: *const Self,
    arena: Allocator,
    doc: *const Document,
    cursor: u32,
    out: *std.ArrayList(CodeAction),
) Allocator.Error!void {
    const form_idx = findEnclosingFormIdx(&doc.tree, cursor) orelse return;
    const ins = (try self.materializedInsertion(arena, doc, form_idx)) orelse return;

    const edits = try arena.alloc(TextEdit, 1);
    edits[0] = .{
        .span_start = ins.offset,
        .span_end = ins.offset,
        .new_text = ins.text,
    };
    try out.append(arena, .{
        .title = "Materialize omitted defaults",
        .edits = edits,
        .kind = .refactor_rewrite,
    });
}

/// Offer "Extract to named definition" for an inline form the cursor sits
/// on that occupies a `union{form, cross_ref}` slot — the one slot shape
/// where an inline form and a name reference are interchangeable spellings
/// (see the CP1 helper block for why the union, not a bare cross-ref, is the
/// precondition). The action produces two edits in the current document:
///   1. replace the inline form with a fresh, collision-free name;
///   2. hoist the form — with a `:<name_key> <fresh>` pair spliced in after
///      its head — to where the reference can still see it: a top-level
///      sibling when the cross-ref is unscoped, or inside the nearest
///      `scope_form` instance when scoped.
/// Together they leave the document valid — the rewritten reference resolves
/// to the hoisted definition (pinned by the "validates clean" test).
///
/// Cursor-driven, not diagnostic-bound: like the materialize action it
/// answers a question about a well-formed document rather than a squiggle,
/// so it hangs off `range_start` and carries no `diagnostics`.
///
/// v1 scope: only a form that does *not* already carry the `name_key` is
/// offered — splicing a second name pair over an existing one would
/// duplicate the key and invalidate the document, so a named inline form
/// (which is already effectively a definition) is left for a later pass.
/// Same-document only: the definition lands in the file that references it.
fn appendExtractAction(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    doc: *const Document,
    range_start: u32,
    range_end: u32,
    out: *std.ArrayList(CodeAction),
) Allocator.Error!void {
    if (!parsedCleanly(doc)) return;
    const site = (try self.findExtractSite(arena, uri, range_start, range_end)) orelse return;

    // Skip an already-named inline form: a second `name_key` pair would be a
    // duplicate key. `formHeader(...).children` is exactly what the index
    // builder scans for a form's `:name`, so this agrees with it.
    const f_hdr = doc.tree.formHeader(site.form_idx);
    if (findKvpairValueText(doc, f_hdr, site.xref.name_key) != null) return;

    const fresh = (try self.freshName(arena, uri, site)) orelse return;
    const placement = (try self.resolvePlacement(arena, &doc.tree, site)) orelse return;

    const f_span = doc.tree.spanOf(site.form_idx);
    if (f_span.end == 0 or f_span.end > doc.source.len) return;

    // The hoisted definition: the inline form verbatim, with `:<name_key>
    // <fresh>` spliced in right after the head token. `head_span.end` is the
    // byte just past the head, so the pair lands before the form's first key.
    const head_end = f_hdr.head_span.end;
    var def: std.ArrayList(u8) = .empty;
    try def.appendSlice(arena, doc.source[f_span.start..head_end]);
    try def.appendSlice(arena, " :");
    try def.appendSlice(arena, site.xref.name_key);
    try def.append(arena, ' ');
    try def.appendSlice(arena, fresh);
    try def.appendSlice(arena, doc.source[head_end..f_span.end]);

    // Where the definition is spliced, and the separator it needs there.
    var insert_offset: u32 = undefined;
    var insert_text: std.ArrayList(u8) = .empty;
    switch (placement) {
        .top_level_after => |root_idx| {
            // A new top-level sibling, on its own line after the root form.
            insert_offset = doc.tree.spanOf(root_idx).end;
            try insert_text.append(arena, '\n');
            try insert_text.appendSlice(arena, def.items);
        },
        .inside_scope => |scope_idx| {
            // Self-scope guard: when the resolved scope *is* the form whose
            // kvpair holds the reference, there is no valid placement. That
            // form's own kvpair values are validated with its parent scope
            // chain, so a definition hoisted into it would be invisible to
            // the reference (`cross_ref_outside_scope`). Suppress the offer
            // rather than emit an edit set that fails to validate.
            if (scope_idx == site.enclosing_form_idx) return;

            // Just before the scope form's closing paren, space-separated —
            // same splice point as the materialize action.
            const scope_span = doc.tree.spanOf(scope_idx);
            if (scope_span.end == 0 or scope_span.end > doc.source.len) return;
            const close = scope_span.end - 1;
            if (doc.source[close] != ')') return;
            insert_offset = close;
            try insert_text.append(arena, ' ');
            try insert_text.appendSlice(arena, def.items);
        },
    }

    // Two non-overlapping edits: the insertion always lands past the inline
    // form's close paren, so ordering is free — emitting the higher offset
    // first keeps the list back-to-front, the convention elsewhere here.
    const edits = try arena.alloc(TextEdit, 2);
    edits[0] = .{
        .span_start = insert_offset,
        .span_end = insert_offset,
        .new_text = try insert_text.toOwnedSlice(arena),
    };
    edits[1] = .{
        .span_start = f_span.start,
        .span_end = f_span.end,
        .new_text = fresh,
    };
    try out.append(arena, .{
        .title = "Extract to named definition",
        .edits = edits,
        .kind = .refactor_extract,
    });
}

/// Whether the document parsed without a single diagnostic — the
/// precondition the two cross-ref refactors need and the quickfixes don't.
///
/// Extract and inline are cursor-driven: they answer a question about a
/// well-formed document rather than about a squiggle, and both work by
/// *copying spans of source text* into new positions. On a document the
/// parser had to recover from, those spans are the parser's best guess.
/// Recovery finalises every unclosed frame at `source.len`, so mid-keystroke
/// text like `(track :lead (phrase :bars` presents a form whose span
/// swallows the rest of the file — and extract, which had a span-range guard
/// that this passes cleanly, would hoist a copy of that and leave two
/// unclosed forms where there was one.
///
/// A parse diagnostic anywhere disqualifies the whole document, not just the
/// broken root: refusing a refactor for a second while the user finishes
/// typing a paren costs nothing, and no narrower rule is honest about what a
/// recovered tree's spans mean.
fn parsedCleanly(doc: *const Document) bool {
    return doc.tree.diagnostics.len == 0;
}

/// Extract's inverse. When the cursor rests on a cross-ref *reference* in a
/// `union{form, cross_ref}` slot, offer `refactor.inline`: splice the
/// referenced definition's body — minus its `name_key` kvpair — over the
/// reference. Sole reference → also delete the definition ("Inline
/// definition"); multiple references → keep it ("Inline reference (keep
/// definition)"). Not offered on the definition itself.
///
/// Eligibility mirrors extract: the reference's slot must also admit an inline
/// form of the definition's head, or the spliced form would be
/// `wrong_underlying`. Same-document only (scope is per-tree).
fn appendInlineAction(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    doc: *const Document,
    range_start: u32,
    out: *std.ArrayList(CodeAction),
) Allocator.Error!void {
    if (!parsedCleanly(doc)) return;
    const index = if (self.cross_ref_index) |*ix| ix else return;
    const tree_idx = self.uri_to_tree_idx.get(uri) orelse return;

    // The cross-ref symbol under the cursor, and what it resolves to.
    const sym_idx = findEnclosingSymbolIdx(&doc.tree, range_start) orelse return;
    const ref_span = doc.tree.spanOf(sym_idx);
    const cr = locateCrossRefSite(index, tree_idx, ref_span) orelse return;

    // Inline dissolves a *use*, never a declaration.
    if (cr.is_definition) return;

    const def = index.lookup(cr.scope, cr.target, cr.name) orelse return;
    // Same-document only: a resolved reference and its definition share this
    // tree (LSP never sets `share_scope`); guard anyway. Cross-document
    // hoisting is out of scope, mirroring extract.
    if (def.tree_idx != tree_idx) return;

    // Eligibility: the reference's slot must also accept a form of the
    // definition's head. A pure (symbol-only) cross-ref slot fails this, so
    // inlining there — which would splice a form — is correctly not offered.
    const declaring_idx = findEnclosingFormIdx(&doc.tree, ref_span.start) orelse return;
    const declaring = doc.tree.formHeader(declaring_idx);
    const kvpair_idx = findEnclosingKvpairIdx(&doc.tree, ref_span.start) orelse return;
    // The mirror of the extract resolver's guard: a positional reference is
    // enclosed by an ancestor's kvpair without being its value.
    if (!kvpairHolds(&doc.tree, kvpair_idx, sym_idx)) return;
    const kvh = doc.tree.kvpairHeader(kvpair_idx);
    const union_kind = self.unionSlotOf(declaring, kvh.key) orelse return;
    if (!try self.unionHasFormAlt(arena, union_kind, cr.target)) return;

    // Acyclic self-reference guard: a reference nested inside its own
    // definition form can't be both spliced over and (in the sole-ref case)
    // deleted coherently. `acyclic` cross-refs are the only shape that admits
    // one; suppress rather than emit an incoherent edit.
    if (ref_span.start >= def.form_span.start and ref_span.end <= def.form_span.end) return;

    const body = (try strippedDefinitionBody(arena, doc, def)) orelse return;
    const refs = index.lookupReferences(cr.scope, cr.target, cr.name);

    if (refs.len == 1) {
        // Sole reference: splice the body over it and delete the definition,
        // trimming one adjacent whitespace run (a trailing newline, else the
        // separating space) so no blank line or double space survives.
        var del_start = def.form_span.start;
        var del_end = def.form_span.end;
        if (del_end < doc.source.len and std.ascii.isWhitespace(doc.source[del_end])) {
            while (del_end < doc.source.len and std.ascii.isWhitespace(doc.source[del_end])) {
                const c = doc.source[del_end];
                del_end += 1;
                if (c == '\n') break;
            }
        } else {
            while (del_start > 0 and std.ascii.isWhitespace(doc.source[del_start - 1])) del_start -= 1;
        }

        // Two non-overlapping edits (the definition form and the reference are
        // distinct nodes); LSP clients apply them position-independently.
        const edits = try arena.alloc(TextEdit, 2);
        edits[0] = .{ .span_start = del_start, .span_end = del_end, .new_text = "" };
        edits[1] = .{ .span_start = ref_span.start, .span_end = ref_span.end, .new_text = body };
        try out.append(arena, .{
            .title = "Inline definition",
            .edits = edits,
            .kind = .refactor_inline,
        });
    } else {
        // Multiple references: inline just this one, keep the definition.
        const edits = try arena.alloc(TextEdit, 1);
        edits[0] = .{ .span_start = ref_span.start, .span_end = ref_span.end, .new_text = body };
        try out.append(arena, .{
            .title = "Inline reference (keep definition)",
            .edits = edits,
            .kind = .refactor_inline,
        });
    }
}

/// The definition form's text with its `name_key` kvpair (and one leading
/// whitespace run) removed — the body an inline splices over a reference.
/// Null when the form span is out of range or the name kvpair can't be located
/// within it. The name kvpair is the one enclosing the definition's
/// name-value token, so no `name_key` string is needed here.
fn strippedDefinitionBody(
    arena: Allocator,
    doc: *const Document,
    def: Validator.CrossRefIndex.Site,
) Allocator.Error!?[]const u8 {
    const fs = def.form_span;
    if (fs.end == 0 or fs.end > doc.source.len or fs.start >= fs.end) return null;

    const kv_idx = findEnclosingKvpairIdx(&doc.tree, def.name_span.start) orelse return null;
    const kv_span = doc.tree.spanOf(kv_idx);
    if (kv_span.start < fs.start or kv_span.end > fs.end) return null;

    // Back over the single whitespace run before the pair so `(head :name p0
    // :bars 4)` collapses to `(head :bars 4)`, not `(head  :bars 4)`.
    var cut_start = kv_span.start;
    while (cut_start > fs.start and std.ascii.isWhitespace(doc.source[cut_start - 1])) cut_start -= 1;

    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(arena, doc.source[fs.start..cut_start]);
    try body.appendSlice(arena, doc.source[kv_span.end..fs.end]);
    return try body.toOwnedSlice(arena);
}

/// Build `form_idx`'s insertion, or null when there is nothing to
/// insert. Thin adapter over `sjon.EffectiveDocument.formInsertion` —
/// shared by the materialize action (one form, under the cursor) and
/// the effective document (every form), so the two can never disagree
/// about what materializing a form produces.
fn materializedInsertion(
    self: *const Self,
    arena: Allocator,
    doc: *const Document,
    form_idx: Ast.NodeIndex,
) Allocator.Error!?sjon.EffectiveDocument.Insertion {
    return sjon.EffectiveDocument.formInsertion(arena, doc.source, &doc.tree, &doc.materialized, &self.schema, form_idx);
}

/// The document as it effectively reads: the author's source with every
/// form's omitted defaults spliced in. Null when `uri` isn't open.
///
/// Thin adapter over `sjon.EffectiveDocument.render` — the splicer was
/// extracted so the CLI (`sjon effective`) prints the identical
/// document; the splice rationale lives in that module's header.
pub fn getEffectiveDocument(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
) Allocator.Error!?[]const u8 {
    const doc = self.getDocument(uri) orelse return null;
    return try sjon.EffectiveDocument.render(arena, doc.source, &doc.tree, &doc.materialized, &self.schema);
}

fn spanOverlaps(span: Ast.Span, range_start: u32, range_end: u32) bool {
    return span.start < range_end and span.end > range_start;
}

fn appendActionsFor(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    doc: *const Document,
    d: Ast.Diagnostic,
    out: *std.ArrayList(CodeAction),
    seen_missing_forms: *std.AutoHashMapUnmanaged(u32, void),
) Allocator.Error!void {
    switch (d.code) {
        .unknown_form => try self.appendUnknownFormFix(arena, doc, d, out),
        .unknown_key => try self.appendUnknownKeyFix(arena, doc, d, out),
        .ambiguous_form => try self.appendAmbiguousFormFix(arena, doc, d, out),
        .missing_required_key => try self.appendMissingRequiredKeyFix(arena, doc, d, out, seen_missing_forms),
        .expr_kvpair_not_allowed => try appendExprKvpairFix(arena, doc, d, out),
        .duplicate_key => try appendDuplicateKeyFix(arena, doc, d, out),
        .not_cross_ref, .cross_ref_outside_scope => try self.appendCrossRefFix(arena, uri, doc, d, out),
        .not_member => try self.appendNotMemberFix(arena, doc, d, out),
        else => {},
    }
}

/// Append a one-edit quickfix for diagnostic `d`: a single TextEdit
/// (`span_start`..`span_end` → `new_text`), labelled `title`, carrying
/// `d` itself so the editor pairs the action with the right squiggle.
/// Every single-edit code action shares this tail — only the title,
/// span, and replacement text vary.
///
/// This is the sole `CodeAction` construction site, so translating `d`
/// here is what makes the association total: no fix family can forget
/// to name the diagnostic it fixes.
fn appendSingleEditAction(
    arena: Allocator,
    out: *std.ArrayList(CodeAction),
    d: Ast.Diagnostic,
    title: []const u8,
    span_start: u32,
    span_end: u32,
    new_text: []const u8,
) Allocator.Error!void {
    const edits = try arena.alloc(TextEdit, 1);
    edits[0] = .{ .span_start = span_start, .span_end = span_end, .new_text = new_text };
    // `translate` borrows `d.message` from the document's tree, which
    // outlives the request arena this action is allocated in.
    //
    // `.plain`: this is a back-reference to a diagnostic the client was
    // already given, so its rendering was settled by the report that
    // carried it. A quick fix is offered only for codes the author can
    // fix in the document, and no such code is downgraded.
    const diags = try arena.alloc(Diagnostic, 1);
    diags[0] = translate(d, .plain);
    try out.append(arena, .{ .title = title, .edits = edits, .diagnostics = diags });
}

fn appendUnknownFormFix(
    self: *const Self,
    arena: Allocator,
    doc: *const Document,
    d: Ast.Diagnostic,
    out: *std.ArrayList(CodeAction),
) Allocator.Error!void {
    const bad = doc.source[d.span.start..d.span.end];
    const suggestion = (try self.closestFormName(arena, bad)) orelse return;

    const title = try std.fmt.allocPrint(arena, "Replace with `{s}`", .{suggestion});
    try appendSingleEditAction(arena, out, d, title, d.span.start, d.span.end, suggestion);
}

fn appendUnknownKeyFix(
    self: *const Self,
    arena: Allocator,
    doc: *const Document,
    d: Ast.Diagnostic,
    out: *std.ArrayList(CodeAction),
) Allocator.Error!void {
    // The diagnostic span covers `:wrongname` (with the leading colon);
    // we want to replace it with `:rightname`. Slice off the leading
    // ':' to compare against bare key names.
    if (d.span.end <= d.span.start + 1) return;
    const bad_with_colon = doc.source[d.span.start..d.span.end];
    if (bad_with_colon[0] != ':') return;
    const bad = bad_with_colon[1..];

    const enclosing = findEnclosingForm(&doc.tree, d.span.start) orelse return;
    const lookup = self.schema.lookupForm(enclosing.head, enclosing.namespace);
    const hit = switch (lookup) {
        .found => |h| h,
        else => return,
    };
    const suggestion = (try closestKeyName(arena, bad, hit.form.keys)) orelse return;

    const new_text = try std.fmt.allocPrint(arena, ":{s}", .{suggestion});
    const title = try std.fmt.allocPrint(arena, "Replace with `:{s}`", .{suggestion});
    try appendSingleEditAction(arena, out, d, title, d.span.start, d.span.end, new_text);
}

fn appendAmbiguousFormFix(
    self: *const Self,
    arena: Allocator,
    doc: *const Document,
    d: Ast.Diagnostic,
    out: *std.ArrayList(CodeAction),
) Allocator.Error!void {
    // The validator emits `ambiguous_form` only when the head was
    // unqualified (qualified lookup is .found or .not_found, never
    // ambiguous). The diagnostic span covers the bare head identifier.
    const head = doc.source[d.span.start..d.span.end];
    const lookup = self.schema.lookupForm(head, null);
    const claimants = switch (lookup) {
        .ambiguous => |amb| amb.slice(),
        else => return,
    };
    for (claimants) |p| {
        const new_text = try std.fmt.allocPrint(arena, "{s}/{s}", .{ p.name, head });
        const title = try std.fmt.allocPrint(arena, "Qualify with `{s}/{s}`", .{ p.name, head });
        try appendSingleEditAction(arena, out, d, title, d.span.start, d.span.end, new_text);
    }
}

fn appendMissingRequiredKeyFix(
    self: *const Self,
    arena: Allocator,
    doc: *const Document,
    d: Ast.Diagnostic,
    out: *std.ArrayList(CodeAction),
    seen_missing_forms: *std.AutoHashMapUnmanaged(u32, void),
) Allocator.Error!void {
    const form_idx = findEnclosingFormIdx(&doc.tree, d.span.start) orelse return;
    const gop = try seen_missing_forms.getOrPut(arena, form_idx.raw());
    if (gop.found_existing) return;

    const hdr = doc.tree.formHeader(form_idx);
    const lookup = self.schema.lookupForm(hdr.head, hdr.namespace);
    const hit = switch (lookup) {
        .found => |h| h,
        else => return,
    };

    const form_span = doc.tree.spanOf(form_idx);
    // Insert immediately before the closing `)`. Form spans always include
    // the parens, so end - 1 is the byte index of `)`.
    const close_paren = form_span.end - 1;

    for (hit.form.keys) |k| {
        if (k.effectiveOptional()) continue;
        if (kvpairChildPresent(&doc.tree, hdr.children, k.name)) continue;

        const stub = stubLiteral(k.value_type);
        const new_text = try std.fmt.allocPrint(arena, " :{s} {s}", .{ k.name, stub });
        const title = try std.fmt.allocPrint(arena, "Insert `:{s}` with stub", .{k.name});
        try appendSingleEditAction(arena, out, d, title, close_paren, close_paren, new_text);
    }
}

fn kvpairChildPresent(
    tree: *const Ast.Tree,
    children: []const Ast.NodeIndex,
    key: []const u8,
) bool {
    for (children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kvh = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kvh.key, key)) return true;
    }
    return false;
}

/// Default literal for `:key` insertion when filling in a missing
/// required key. Pure-syntactic stub — values that fail downstream type
/// checks (e.g. a `nil` for a typed-vector slot) still parse, and the
/// follow-up diagnostic guides the user from there.
fn stubLiteral(vt: sjon.Plugin.ValueType) []const u8 {
    return switch (vt) {
        .string => "\"\"",
        .number => "0",
        .boolean => "false",
        .symbol => "_",
        .nil => "nil",
        .vector => "[]",
        // No obvious literal for forms / exprs / opaque kinds — `nil`
        // keeps the document parseable and the user fixes from there.
        .form, .expr, .any, .named => "nil",
    };
}

fn appendExprKvpairFix(
    arena: Allocator,
    doc: *const Document,
    d: Ast.Diagnostic,
    out: *std.ArrayList(CodeAction),
) Allocator.Error!void {
    // The diagnostic span covers `:key`. Drop everything from there up
    // to the value's span.start — that elides the key and any whitespace
    // or comments separating it from the value.
    const kvpair_idx = findKvpairByKeySpan(&doc.tree, d.span) orelse return;
    const kvh = doc.tree.kvpairHeader(kvpair_idx);
    const value_span = doc.tree.spanOf(kvh.value);
    if (value_span.start <= d.span.start) return;

    const title = try std.fmt.allocPrint(arena, "Drop `:{s}` (keep value)", .{kvh.key});
    try appendSingleEditAction(arena, out, d, title, d.span.start, value_span.start, "");
}

/// Replace a typo'd cross-ref symbol with the closest in-scope name.
/// Same fix surface for `not_cross_ref` (name not registered anywhere
/// the lookup considered) and `cross_ref_outside_scope` (registered,
/// but only outside the cursor's `:scope_form` chain) — both want to
/// nudge the user toward a name visible *here*.
///
/// Resolves the cross-ref kind by climbing from the diagnostic's
/// symbol span: enclosing kvpair → owning FormSpec's KeySpec →
/// `ValueKind` (or, when the kvpair holds a vector of cross-refs, the
/// element kind). Scope resolution mirrors `completionsForCrossRef`
/// (and the validator's own `findNearestScope`).
/// A cross-ref's canonical target form + the scope to query it under.
const ResolvedCrossRef = struct {
    canonical_target: []const u8,
    scope: Validator.ScopeId,
    target_hit: Schema.FormHit,
};

/// Canonicalise a cross-ref's target form to `<plugin>/<form>` and
/// resolve the scope to query. `scope_form == null` → tree-scope;
/// otherwise the innermost enclosing ancestor whose head canonicalises to
/// the declared scope form, its NodeIndex minted as the lexical id via
/// `Validator.ScopeId.lexical`, matching the validator. Returns null (each
/// caller returns its own empty result) when the target form is unknown,
/// or a declared scope form doesn't canonicalise / has no enclosing
/// ancestor. Shared by `completionsForCrossRef` and `appendCrossRefFix`.
fn resolveCrossRefTargetAndScope(
    self: *const Self,
    arena: Allocator,
    doc: *const Document,
    tree_idx: u32,
    enclosing_form_idx: Ast.NodeIndex,
    xref: sjon.Plugin.ValueKind.CrossRef,
) Allocator.Error!?ResolvedCrossRef {
    var target_ns: ?[]const u8 = null;
    var target_name = xref.target_form;
    if (std.mem.indexOfScalar(u8, xref.target_form, '/')) |slash| {
        target_ns = xref.target_form[0..slash];
        target_name = xref.target_form[slash + 1 ..];
    }
    const target_hit = switch (self.schema.lookupForm(target_name, target_ns)) {
        .found => |h| h,
        else => return null,
    };
    const canonical_target = try std.fmt.allocPrint(
        arena,
        "{s}/{s}",
        .{ target_hit.plugin.name, target_hit.form.name },
    );

    const scope: Validator.ScopeId = blk: {
        const sf_raw = xref.scope_form orelse break :blk .tree(tree_idx);
        const canon_scope = (try self.canonicaliseFormHead(arena, sf_raw, null)) orelse return null;
        const scope_form_idx = (try self.findEnclosingScopeFormIdx(arena, &doc.tree, enclosing_form_idx, canon_scope)) orelse return null;
        break :blk .lexical(tree_idx, @intFromEnum(scope_form_idx));
    };

    return .{ .canonical_target = canonical_target, .scope = scope, .target_hit = target_hit };
}

/// The kvpair slot a code-action diagnostic points at, resolved to the
/// value kind declared for it. Shared prefix of `appendCrossRefFix` and
/// `appendNotMemberFix`.
const KvpairSlot = struct {
    enclosing_form_idx: Ast.NodeIndex,
    enclosing: Ast.FormHeader,
    form_hit: Schema.FormHit,
    kind: *const sjon.Plugin.ValueKind,
};

/// Locate the enclosing form + kvpair around `d.span`, look the key up in
/// the form spec, and resolve its `.named` value type to a ValueKind.
/// Returns null (each caller returns void) when the span is degenerate,
/// there's no enclosing form/kvpair, the key is unknown, or the slot
/// isn't a named kind.
fn resolveKvpairSlotKind(self: *const Self, doc: *const Document, d: Ast.Diagnostic) ?KvpairSlot {
    if (d.span.end <= d.span.start or d.span.end > doc.source.len) return null;

    const enclosing_form_idx = findEnclosingFormIdx(&doc.tree, d.span.start) orelse return null;
    const enclosing_kvpair_idx = findEnclosingKvpairIdx(&doc.tree, d.span.start) orelse return null;
    const kvh = doc.tree.kvpairHeader(enclosing_kvpair_idx);

    const enclosing = doc.tree.formHeader(enclosing_form_idx);
    const form_hit = switch (self.schema.lookupForm(enclosing.head, enclosing.namespace)) {
        .found => |h| h,
        else => return null,
    };
    const key = form_hit.form.keyByName(kvh.key) orelse return null;
    const named = switch (key.value_type) {
        .named => |n| n,
        else => return null,
    };
    const kind = switch (self.schema.lookupValueKind(named.name, named.namespace)) {
        .found => |k| k,
        else => return null,
    };
    return .{
        .enclosing_form_idx = enclosing_form_idx,
        .enclosing = enclosing,
        .form_hit = form_hit,
        .kind = kind,
    };
}

fn appendCrossRefFix(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    doc: *const Document,
    d: Ast.Diagnostic,
    out: *std.ArrayList(CodeAction),
) Allocator.Error!void {
    const slot = self.resolveKvpairSlotKind(doc, d) orelse return;
    const enclosing_form_idx = slot.enclosing_form_idx;
    const enclosing = slot.enclosing;
    const form_hit = slot.form_hit;
    const kind = slot.kind;

    // Either the kvpair's value IS a cross-ref symbol, or it's a vector
    // whose element kind is. Anything else and the diagnostic shouldn't
    // have fired against this slot.
    const xref: sjon.Plugin.ValueKind.CrossRef = blk: {
        if (kind.cross_ref) |x| break :blk x;
        if (kind.vector) |vs| {
            const elem_kind = switch (self.schema.lookupValueKind(vs.element.name, vs.element.namespace)) {
                .found => |k| k,
                else => return,
            };
            if (elem_kind.cross_ref) |x| break :blk x;
        }
        return;
    };

    const xri = self.cross_ref_index orelse return;
    const tree_idx = self.uri_to_tree_idx.get(uri) orelse return;

    const resolved = (try self.resolveCrossRefTargetAndScope(arena, doc, tree_idx, enclosing_form_idx, xref)) orelse return;
    const canonical_target = resolved.canonical_target;
    const scope = resolved.scope;
    const target_hit = resolved.target_hit;

    // The diagnostic span is either the bad symbol itself OR the
    // enclosing vector (when the validator wrapped the leaf failure in
    // `MatchFail.element_at`). Resolve down to the actual symbol so
    // the edit replaces only the typo, not the whole `[...]`.
    const bad_span = resolveCrossRefBadSpan(&doc.tree, xri, scope, canonical_target, d.span) orelse return;
    const bad = doc.source[bad_span.start..bad_span.end];

    // When the enclosing form IS a definition of the same target,
    // suppress its own name from the candidate set (mirrors the
    // self-name filter in `completionsForCrossRef`).
    var self_name: ?[]const u8 = null;
    if (form_hit.plugin == target_hit.plugin and form_hit.form == target_hit.form) {
        self_name = findKvpairValueText(doc, enclosing, xref.name_key);
    }

    var names: std.ArrayList([]const u8) = .empty;
    var it = xri.iterateNames(scope, canonical_target);
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (self_name) |s| if (std.mem.eql(u8, s, name)) continue;
        try names.append(arena, name);
    }
    const suggestion = (try firstSuggestion(arena, bad, names.items)) orelse return;

    const title = try std.fmt.allocPrint(arena, "Replace with `{s}`", .{suggestion});
    try appendSingleEditAction(arena, out, d, title, bad_span.start, bad_span.end, suggestion);
}

/// Find the symbol span the cross-ref diagnostic actually points at.
///
/// `not_cross_ref` / `cross_ref_outside_scope` emit with `tree.spanOf(value_idx)`:
/// for a direct symbol-typed slot that's the symbol's span; for a
/// vector-of-cross-refs slot, the validator wraps the leaf failure in
/// `MatchFail.element_at` and emits at the *vector's* span instead.
/// This resolver normalises both shapes to the actual symbol span by
/// finding the first child symbol whose text isn't registered under
/// `(scope, target)` — the validator stops at the first failing
/// element, so the first non-registered symbol is the one the
/// diagnostic refers to.
fn resolveCrossRefBadSpan(
    tree: *const Ast.Tree,
    xri: Validator.CrossRefIndex,
    scope: Validator.ScopeId,
    canonical_target: []const u8,
    diag_span: Ast.Span,
) ?Ast.Span {
    const tags = tree.nodes.items(.tag);
    var i: u32 = 0;
    while (i < tags.len) : (i += 1) {
        const idx = Ast.NodeIndex.from(i);
        const span = tree.spanOf(idx);
        if (span.start != diag_span.start or span.end != diag_span.end) continue;
        switch (tags[i]) {
            .symbol => return span,
            .vector => {
                for (tree.vectorElements(idx)) |el| {
                    if (tree.tagOf(el) != .symbol) continue;
                    const text = tree.symbolText(el);
                    if (!xri.contains(scope, canonical_target, text)) {
                        return tree.spanOf(el);
                    }
                }
                return null;
            },
            else => return null,
        }
    }
    return null;
}

/// Replace a value that failed a member-set check with the closest
/// allowed member (Levenshtein-bounded, deprecated members excluded).
/// Handles both direct-value and vector-element shapes via the same
/// `element_at`-unwrapping pattern as the cross-ref fix.
fn appendNotMemberFix(
    self: *const Self,
    arena: Allocator,
    doc: *const Document,
    d: Ast.Diagnostic,
    out: *std.ArrayList(CodeAction),
) Allocator.Error!void {
    const slot = self.resolveKvpairSlotKind(doc, d) orelse return;
    const kind = slot.kind;

    // The kvpair value either IS the member-checked value, or a vector
    // whose element kind carries the member set.
    const member_set: sjon.Plugin.ValueKind.MemberSet = blk: {
        if (kind.members) |m| break :blk m;
        if (kind.vector) |vs| {
            const elem_kind = switch (self.schema.lookupValueKind(vs.element.name, vs.element.namespace)) {
                .found => |k| k,
                else => return,
            };
            if (elem_kind.members) |m| break :blk m;
        }
        return;
    };
    if (member_set.members.len == 0) return;

    const bad_span = resolveNotMemberBadSpan(&doc.tree, member_set.members, d.span) orelse return;
    const bad_node_tag = doc.tree.tagOf(findNodeBySpan(&doc.tree, bad_span) orelse return);
    const bad_text: []const u8 = switch (bad_node_tag) {
        .symbol => doc.tree.symbolText(findNodeBySpan(&doc.tree, bad_span).?),
        .string => doc.tree.stringText(findNodeBySpan(&doc.tree, bad_span).?),
        else => return,
    };

    var names: std.ArrayList([]const u8) = .empty;
    for (member_set.members) |m| {
        if (m.deprecated) continue;
        try names.append(arena, m.name);
    }
    const suggestion = (try firstSuggestion(arena, bad_text, names.items)) orelse return;

    // Member names today are bare identifiers — guard against future
    // names that would need `|…|` quoting in source by suppressing the
    // fix rather than producing syntactically invalid output.
    if (bad_node_tag == .symbol and !isPlainSymbol(suggestion)) return;

    const new_text: []const u8 = switch (bad_node_tag) {
        .string => try std.fmt.allocPrint(arena, "\"{s}\"", .{suggestion}),
        else => suggestion,
    };

    const title = try std.fmt.allocPrint(arena, "Replace with `{s}`", .{suggestion});
    try appendSingleEditAction(arena, out, d, title, bad_span.start, bad_span.end, new_text);
}

/// Normalise a `not_member` diagnostic span the same way
/// `resolveCrossRefBadSpan` handles cross-ref spans: the validator
/// emits at the enclosing vector when a leaf element fails inside
/// `MatchFail.element_at`, so we walk vector children for the first
/// non-member symbol/string when the diagnostic span turns out to be
/// a vector.
fn resolveNotMemberBadSpan(
    tree: *const Ast.Tree,
    members: []const sjon.Plugin.ValueKind.MemberSet.Member,
    diag_span: Ast.Span,
) ?Ast.Span {
    const tags = tree.nodes.items(.tag);
    var i: u32 = 0;
    while (i < tags.len) : (i += 1) {
        const idx = Ast.NodeIndex.from(i);
        const span = tree.spanOf(idx);
        if (span.start != diag_span.start or span.end != diag_span.end) continue;
        switch (tags[i]) {
            .symbol, .string => return span,
            .vector => {
                for (tree.vectorElements(idx)) |el| {
                    const el_tag = tree.tagOf(el);
                    const text: []const u8 = switch (el_tag) {
                        .symbol => tree.symbolText(el),
                        .string => tree.stringText(el),
                        else => continue,
                    };
                    if (!memberSetContains(members, text)) return tree.spanOf(el);
                }
                return null;
            },
            else => return null,
        }
    }
    return null;
}

fn memberSetContains(
    members: []const sjon.Plugin.ValueKind.MemberSet.Member,
    text: []const u8,
) bool {
    for (members) |m| {
        if (std.mem.eql(u8, m.name, text)) return true;
    }
    return false;
}

/// Smallest node whose span equals `target_span` exactly. Used by the
/// member-set fix to recover the value node from a normalised span.
/// Returns the first match found in node-index order; ties are
/// impossible for `.symbol` / `.string` / `.vector` because parser
/// spans are unique per token.
fn findNodeBySpan(tree: *const Ast.Tree, target_span: Ast.Span) ?Ast.NodeIndex {
    const tags = tree.nodes.items(.tag);
    var i: u32 = 0;
    while (i < tags.len) : (i += 1) {
        const span = tree.nodes.items(.span)[i];
        if (span.start == target_span.start and span.end == target_span.end) {
            return Ast.NodeIndex.from(i);
        }
    }
    return null;
}

/// True when `name` is a syntactically valid SJON symbol (i.e., can be
/// emitted bare without `|…|` quoting). Matches `isSymbolChar`'s
/// vocabulary plus the symbol-start-character constraint.
fn isPlainSymbol(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!isSymbolChar(c)) return false;
    }
    return true;
}

fn appendDuplicateKeyFix(
    arena: Allocator,
    doc: *const Document,
    d: Ast.Diagnostic,
    out: *std.ArrayList(CodeAction),
) Allocator.Error!void {
    // Diagnostic span = `key_span` of the duplicate (second-or-later)
    // kvpair. The kvpair node's own span covers `:key value` exactly,
    // so we delete that plus the whitespace separating it from the
    // preceding sibling.
    const kvpair_idx = findKvpairByKeySpan(&doc.tree, d.span) orelse return;
    const kvh = doc.tree.kvpairHeader(kvpair_idx);
    const kvpair_span = doc.tree.spanOf(kvpair_idx);

    var sweep_start: u32 = kvpair_span.start;
    while (sweep_start > 0 and isWhitespace(doc.source[sweep_start - 1])) {
        sweep_start -= 1;
    }

    // Refuse to silently take a comment with the deletion. Two cases:
    // (a) the kvpair itself straddles a comment (e.g. `:k ; note\n  v`),
    // (b) the whitespace we just consumed re-glues the line we'd land
    //     on — if that line ends in a comment, the trailing `)` or next
    //     kvpair would be swallowed by it.
    for (doc.source[sweep_start..kvpair_span.end]) |b| {
        if (b == ';') return;
    }
    var s = sweep_start;
    while (s > 0) {
        const c = doc.source[s - 1];
        if (c == '\n') break;
        if (c == ';') return;
        s -= 1;
    }

    const title = try std.fmt.allocPrint(arena, "Remove duplicate `:{s}`", .{kvh.key});
    try appendSingleEditAction(arena, out, d, title, sweep_start, kvpair_span.end, "");
}

/// Nearest declared form/expr-func name to `target`, or null when none
/// is within `DidYouMean.MAX_DISTANCE`. Shares the Damerau-Levenshtein
/// engine (and its distance-then-alphabetical ranking) with the CLI's
/// rich diagnostics, so both surfaces suggest identically.
fn closestFormName(self: *const Self, arena: Allocator, target: []const u8) Allocator.Error!?[]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (self.schema.plugins) |p| {
        for (p.forms) |f| try names.append(arena, f.name);
        for (p.expr_funcs) |f| try names.append(arena, f.name);
    }
    return firstSuggestion(arena, target, names.items);
}

fn closestKeyName(arena: Allocator, target: []const u8, keys: []const sjon.Plugin.KeySpec) Allocator.Error!?[]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (keys) |k| try names.append(arena, k.name);
    return firstSuggestion(arena, target, names.items);
}

/// The single best `DidYouMean` suggestion for `target` among
/// `candidates`, or null when none is within `DidYouMean.MAX_DISTANCE`.
fn firstSuggestion(arena: Allocator, target: []const u8, candidates: []const []const u8) Allocator.Error!?[]const u8 {
    const suggestions = try DidYouMean.suggest(arena, target, candidates, 1);
    return if (suggestions.len == 0) null else suggestions[0].name;
}

/// The LSP tags a diagnostic code earns. `Ast.Diagnostic` carries no tag
/// of its own — the wire-stable core has no opinion about editor
/// presentation — so the mapping is derived here, in one place both
/// translators call so they can't drift apart.
///
/// Returned slices are comptime-known, hence static: no allocation, and
/// safe to hand out of the arena's lifetime.
fn tagsFor(code: Ast.Diagnostic.Code) []const Diagnostic.Tag {
    const deprecated: []const Diagnostic.Tag = &.{.deprecated};
    return switch (code) {
        // Completion already strikes through deprecated members
        // (`memberCompletionItems`), so tagging the diagnostic keeps the
        // two surfaces telling the user the same thing about the same
        // member.
        .deprecated_member => deprecated,
        else => &.{},
    };
}

/// Which presentational downgrades apply to a batch of diagnostics.
///
/// A per-call argument rather than a field read inside `translate`
/// because not every translation happens on behalf of a session: a code
/// action's attached diagnostic is a back-reference to a squiggle the
/// client already holds, and a schema report describes a manifest, not a
/// document. Both say `.plain` and mean it.
const Presentation = enum {
    /// Report every diagnostic exactly as its producer graded it.
    plain,
    /// This session cannot execute providers at all, so a provider that
    /// "was not run" is a fact about the host, not about the document.
    providers_unrunnable,
};

/// What this session can offer a document right now.
///
/// Read as data — the capability, not the target. `sjon-lsp.wasm` always
/// lands on `.providers_unrunnable` because it can never hold a runtime,
/// but so does a native build without `-Dplugin-exec`, a session with no
/// project, and a project whose plugins shipped no sidecars. That is what
/// lets both branches be pinned by tests compiled for one target.
fn presentation(self: *const Self) Presentation {
    return if (self.providerRuntime() == null) .providers_unrunnable else .plain;
}

/// The severity an editor should render, which is not always the severity
/// the producer assigned. One place, called by both translators, for the
/// same reason `tagsFor` is: two mappings of the same thing drift.
///
/// The single override today is `cross_ref_provider_unavailable` on a
/// session that cannot run providers. The validator is right to emit it —
/// those names really are unchecked — but on a host that could never have
/// checked them it is a standing property of the editor, not a defect in
/// the file, and a permanent red squiggle on correct source trains people
/// to ignore red squiggles. Downgraded to a hint: still visible, still
/// carrying its code and its docs link, no longer an accusation.
///
/// Nothing here reaches the wire. `Ast.Diagnostic` keeps its `.err`, the
/// conformance corpus keeps its expectations, and the same document
/// validated by a host that *can* run providers reports the error at full
/// strength.
fn severityFor(code: Ast.Diagnostic.Code, severity: Ast.Diagnostic.Severity, mode: Presentation) Severity {
    if (mode == .providers_unrunnable and code == .cross_ref_provider_unavailable) return .hint;
    return switch (severity) {
        .err => .err,
        .warning => .warning,
    };
}

fn translate(d: Ast.Diagnostic, mode: Presentation) Diagnostic {
    return .{
        .span_start = d.span.start,
        .span_end = d.span.end,
        .severity = severityFor(d.code, d.severity, mode),
        .code = @tagName(d.code),
        .message = d.message,
        .tags = tagsFor(d.code),
        .code_href = codeHref(d.code),
    };
}

/// The docs base + href builder live with the explanations catalogue
/// (`sjon.Explanations`) so the CLI links the same pages without
/// importing the LSP layer; `codeDescription` is the protocol home for
/// the value here. Re-exported so LSP call sites keep reading
/// `Handler.codeHref`.
pub const DOCS_BASE = sjon.Explanations.DOCS_BASE;
pub const codeHref = sjon.Explanations.codeHref;

/// Like `translate`, but dupes `message` into `arena`. Used by
/// `setUserSchemas`, where the source diagnostic's backing tree is
/// deinit'd before the report is serialized — `translate`'s borrowed
/// `message` would dangle. `code` is a comptime `@tagName`, so it needs
/// no copy.
fn translateDupe(arena: Allocator, d: Ast.Diagnostic, mode: Presentation) Allocator.Error!Diagnostic {
    return .{
        .span_start = d.span.start,
        .span_end = d.span.end,
        .severity = severityFor(d.code, d.severity, mode),
        .code = @tagName(d.code),
        .message = try arena.dupe(u8, d.message),
        .tags = tagsFor(d.code),
        .code_href = codeHref(d.code),
    };
}

/// Allocate a `[:0]u8` copy of `bytes`. Required because `Parser.parse`
/// asserts a sentinel.
fn sentinelDupe(gpa: Allocator, bytes: []const u8) Allocator.Error![:0]u8 {
    const buf = try gpa.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf, bytes);
    return buf;
}

// ---------------------------------------------------------------------------
// Cross-ref-driven editor features (find-references, rename).
//
// All driven by the forest-wide `cross_ref_index` populated during the
// last revalidation: `by_scope` for definitions, `references_by_scope`
// for use sites. The cursor → (scope, target, name) resolution is a
// linear scan over the index keyed by name_span — simpler than walking
// the AST + reconstructing scope chains, fast enough at typical doc
// sizes (the registry has at most one entry per cross-ref-typed value
// in the workspace).
// ---------------------------------------------------------------------------

/// Smallest `.symbol` node whose span contains `pos`. Mirrors
/// `findEnclosingFormIdx`'s tag-filtered scan; symbol leaves have
/// distinct spans within a tree.
fn findEnclosingSymbolIdx(tree: *const Ast.Tree, pos: u32) ?Ast.NodeIndex {
    return smallestContainingIdx(tree, pos, .symbol);
}

/// What the cursor resolves to in the cross-ref index. `is_definition`
/// distinguishes `(phrase :name p0 …)`'s `p0` from `(track :sequence
/// [p0])`'s `p0` — the same name, but the index records them under
/// different paths and `findReferences` / `rename` need both.
const CrossRefSite = struct {
    scope: Validator.ScopeId,
    target: []const u8,
    name: []const u8,
    is_definition: bool,
};

/// Find a definition or reference Site whose `(tree_idx, name_span)`
/// matches `cursor`. Definitions checked first — when a single span is
/// both (which can't happen with the current index, since definitions
/// register the `:name-key` value and references register the symbol
/// values that point at it, never the same node), the definition wins.
fn locateCrossRefSite(
    index: *const Validator.CrossRefIndex,
    tree_idx: u32,
    cursor: Ast.Span,
) ?CrossRefSite {
    var def_scope_iter = index.by_scope.iterator();
    while (def_scope_iter.next()) |scope_entry| {
        var target_iter = scope_entry.value_ptr.iterator();
        while (target_iter.next()) |target_entry| {
            var name_iter = target_entry.value_ptr.iterator();
            while (name_iter.next()) |name_entry| {
                const s = name_entry.value_ptr.*;
                if (s.tree_idx == tree_idx and s.name_span.start == cursor.start and s.name_span.end == cursor.end) {
                    return .{
                        .scope = scope_entry.key_ptr.*,
                        .target = target_entry.key_ptr.*,
                        .name = name_entry.key_ptr.*,
                        .is_definition = true,
                    };
                }
            }
        }
    }
    var ref_scope_iter = index.references_by_scope.iterator();
    while (ref_scope_iter.next()) |scope_entry| {
        var target_iter = scope_entry.value_ptr.iterator();
        while (target_iter.next()) |target_entry| {
            var name_iter = target_entry.value_ptr.iterator();
            while (name_iter.next()) |name_entry| {
                for (name_entry.value_ptr.items) |s| {
                    if (s.tree_idx == tree_idx and s.name_span.start == cursor.start and s.name_span.end == cursor.end) {
                        return .{
                            .scope = scope_entry.key_ptr.*,
                            .target = target_entry.key_ptr.*,
                            .name = name_entry.key_ptr.*,
                            .is_definition = false,
                        };
                    }
                }
            }
        }
    }
    return null;
}

/// Build the LSP `Location[]` for every reference of the name under
/// the cursor. Returns null when:
///   - the document isn't open, or
///   - no cross-ref index has been built yet, or
///   - the cursor isn't on a registered cross-ref site.
///
/// Returns an empty slice when the cursor IS on a site but no
/// references have been recorded (a definition with zero uses).
///
/// Cross-document references work transparently: a reference in URI X
/// to a definition in URI Y is included regardless of which document
/// the cursor lives in, as long as both are open.
pub fn findReferences(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    byte_offset: u32,
    include_declaration: bool,
) Allocator.Error!?[]const Location {
    const doc = self.getDocument(uri) orelse return null;
    const index = if (self.cross_ref_index) |*ix| ix else return null;
    const tree_idx = self.uri_to_tree_idx.get(uri) orelse return null;

    const sym_idx = findEnclosingSymbolIdx(&doc.tree, byte_offset) orelse return null;
    const cursor_span = doc.tree.spanOf(sym_idx);

    const site = locateCrossRefSite(index, tree_idx, cursor_span) orelse return null;

    const refs = index.lookupReferences(site.scope, site.target, site.name);
    const def: ?Validator.CrossRefIndex.Site = index.lookup(site.scope, site.target, site.name);

    var total: usize = refs.len;
    if (include_declaration and def != null) total += 1;

    const out = try arena.alloc(Location, total);
    var w: usize = 0;
    if (include_declaration) {
        if (def) |d| {
            out[w] = .{
                .uri = self.tree_uris[d.tree_idx],
                .span_start = d.name_span.start,
                .span_end = d.name_span.end,
            };
            w += 1;
        }
    }
    for (refs) |r| {
        out[w] = .{
            .uri = self.tree_uris[r.tree_idx],
            .span_start = r.name_span.start,
            .span_end = r.name_span.end,
        };
        w += 1;
    }
    return out[0..w];
}

/// Where the cross-ref symbol under the cursor is defined. Returns null
/// when:
///   - the document isn't open, or
///   - no cross-ref index has been built yet, or
///   - the cursor isn't on a registered cross-ref site, or
///   - the site is a reference whose name resolves to no definition in
///     scope (a typo). The `not_cross_ref` diagnostic already tells that
///     story; a jump to an arbitrary near-match would tell it worse.
///
/// A cursor ON the definition name returns that definition — standard
/// LSP behavior, and why this shares `locateCrossRefSite` with
/// `findReferences` instead of filtering to reference sites.
///
/// Allocation-free (the `Location` borrows `tree_uris`, valid for the
/// current index epoch), so no arena and no error set — same shape as
/// `prepareRename`.
///
/// Scope is per-tree: the LSP never sets `Validator.Options.share_scope`,
/// so a reference never resolves across documents and the returned URI is
/// in practice the requesting one. `Location` carries it anyway — it is
/// the shape both transports already translate, and the index is
/// forest-wide by construction.
pub fn getDefinition(
    self: *const Self,
    uri: []const u8,
    byte_offset: u32,
) ?Location {
    const doc = self.getDocument(uri) orelse return null;
    const index = if (self.cross_ref_index) |*ix| ix else return null;
    const tree_idx = self.uri_to_tree_idx.get(uri) orelse return null;
    std.debug.assert(tree_idx < self.tree_uris.len);

    const sym_idx = findEnclosingSymbolIdx(&doc.tree, byte_offset) orelse return null;
    const cursor_span = doc.tree.spanOf(sym_idx);

    const site = locateCrossRefSite(index, tree_idx, cursor_span) orelse return null;
    const def = index.lookup(site.scope, site.target, site.name) orelse return null;

    std.debug.assert(def.tree_idx < self.tree_uris.len);
    std.debug.assert(def.name_span.start <= def.name_span.end);
    return .{
        .uri = self.tree_uris[def.tree_idx],
        .span_start = def.name_span.start,
        .span_end = def.name_span.end,
    };
}

// ---------------------------------------------------------------------------
// Refactor actions: extract / inline (plan 11).
//
// Both operate on a `union{form-alt, cross_ref-alt}` slot — the one slot
// shape where an inline form and a name reference are interchangeable
// spellings. A pure cross-ref slot has `underlying == .symbol` and rejects a
// form outright (Validator `matchScalar`), so there is nothing to extract
// there; the union is what makes "could have written a name here" true.
//
// CP1 is the pure resolution layer — eligibility, placement, fresh-name —
// exposed as `pub` helpers so the tests exercise them directly. CP2/CP3 wire
// them into `getCodeActions` as `refactor.extract` / `refactor.inline`.
// ---------------------------------------------------------------------------

/// An eligible extract site: an inline form `F` sitting in a
/// `union{form, cross_ref}` slot whose cross-ref alternative targets `F`'s
/// head. `enclosing_form_idx` is the form that *declares* the slot (F's
/// parent), which drives scope resolution; `xref` is the matched cross-ref
/// alternative, whose `scope_form` decides placement and whose `name_key`
/// (CP2) names the hoisted definition's key.
pub const ExtractSite = struct {
    form_idx: Ast.NodeIndex,
    head: []const u8,
    head_ns: ?[]const u8,
    enclosing_form_idx: Ast.NodeIndex,
    xref: sjon.Plugin.ValueKind.CrossRef,
};

/// Where an extracted definition is inserted so the validator's scoping
/// rules keep it visible to the original site.
pub const Placement = union(enum) {
    /// Unscoped cross-ref: insert as a top-level sibling, after this
    /// outermost-ancestor form.
    top_level_after: Ast.NodeIndex,
    /// Scoped cross-ref: insert inside this `scope_form` instance (before
    /// its closing paren).
    inside_scope: Ast.NodeIndex,
};

/// Resolve the extract site the cursor sits on, or null when the cursor is
/// not on an inline form in a `union{form, cross_ref}` slot. Pure over the
/// document + schema — no edits, no diagnostics.
///
/// `range_end` is accepted for symmetry with the LSP selection range (CP2
/// passes it); the anchor is `range_start`, the byte the cursor rests on.
pub fn findExtractSite(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    range_start: u32,
    range_end: u32,
) Allocator.Error!?ExtractSite {
    _ = range_end;
    const doc = self.getDocument(uri) orelse return null;

    // The inline form the cursor is on (`F`).
    const form_idx = findEnclosingFormIdx(&doc.tree, range_start) orelse return null;
    const hdr = doc.tree.formHeader(form_idx);

    // The slot F sits in: F's parent form declares the key; the enclosing
    // kvpair carries it. Anchor the kvpair scan on F's opening paren, which
    // lies inside the outer kvpair but before any of F's own inner pairs.
    const parent_form_idx = findParentFormIdx(&doc.tree, form_idx) orelse return null;
    const f_span = doc.tree.spanOf(form_idx);
    const kvpair_idx = findEnclosingKvpairIdx(&doc.tree, f_span.start) orelse return null;
    // …and only if that kvpair actually holds F. A positional F is enclosed
    // by an ancestor's pair without belonging to it; see `kvpairHolds`.
    if (!kvpairHolds(&doc.tree, kvpair_idx, form_idx)) return null;
    const kvh = doc.tree.kvpairHeader(kvpair_idx);

    // The slot F's parent declares must be a union (directly, or as a vector's
    // element kind when F is one element of a `[…]`).
    const parent = doc.tree.formHeader(parent_form_idx);
    const union_kind = self.unionSlotOf(parent, kvh.key) orelse return null;

    // …with a cross-ref alternative whose target is F's own head — i.e. a
    // name reference could have stood in for the inline form.
    const canonical_head = (try self.canonicaliseFormHead(arena, hdr.head, hdr.namespace)) orelse return null;
    const xref = (try self.findCrossRefAlt(arena, union_kind, canonical_head)) orelse return null;

    return .{
        .form_idx = form_idx,
        .head = hdr.head,
        .head_ns = hdr.namespace,
        .enclosing_form_idx = parent_form_idx,
        .xref = xref,
    };
}

/// The cross-ref alternative of `union_kind` whose target canonicalises to
/// `canonical_head`, or null when the union has none. First match wins,
/// mirroring the validator's alternative-dispatch order.
fn findCrossRefAlt(
    self: *const Self,
    arena: Allocator,
    union_kind: *const sjon.Plugin.ValueKind,
    canonical_head: []const u8,
) Allocator.Error!?sjon.Plugin.ValueKind.CrossRef {
    const us = union_kind.union_of orelse return null;
    for (us.alternatives) |alt| {
        const alt_kind = switch (self.schema.lookupValueKind(alt.name, alt.namespace)) {
            .found => |k| k,
            else => continue,
        };
        const cr = alt_kind.cross_ref orelse continue;
        const canon_target = (try self.canonicaliseFormHead(arena, cr.target_form, null)) orelse continue;
        if (std.mem.eql(u8, canon_target, canonical_head)) return cr;
    }
    return null;
}

/// The `union{…}` ValueKind of the slot declared by `declaring`'s key
/// `key_name` — directly, or as the element kind of a `.vector` slot. Null
/// when the form/key/kind isn't schema-known or the slot isn't a union.
/// Shared by the extract-site and inline-site resolvers so the two agree on
/// exactly which slots are union-shaped.
fn unionSlotOf(
    self: *const Self,
    declaring: Ast.FormHeader,
    key_name: []const u8,
) ?*const sjon.Plugin.ValueKind {
    const form_hit = switch (self.schema.lookupForm(declaring.head, declaring.namespace)) {
        .found => |h| h,
        else => return null,
    };
    const key = form_hit.form.keyByName(key_name) orelse return null;
    const named = switch (key.value_type) {
        .named => |n| n,
        else => return null,
    };
    const slot_kind = switch (self.schema.lookupValueKind(named.name, named.namespace)) {
        .found => |k| k,
        else => return null,
    };
    if (slot_kind.union_of != null) return slot_kind;
    if (slot_kind.vector) |vs| {
        switch (self.schema.lookupValueKind(vs.element.name, vs.element.namespace)) {
            .found => |elem| if (elem.union_of != null) return elem,
            else => {},
        }
    }
    return null;
}

/// True when `union_kind` has a `.form` alternative that accepts a form whose
/// canonical head is `canonical_head` — the bare `form` primitive shortcut, a
/// `heads`-less `.form` kind (accepts any head), or one whose `heads` list
/// includes it. The mirror of `findCrossRefAlt`: splicing an inline form over
/// a reference validates only when the reference's slot also admits that form.
fn unionHasFormAlt(
    self: *const Self,
    arena: Allocator,
    union_kind: *const sjon.Plugin.ValueKind,
    canonical_head: []const u8,
) Allocator.Error!bool {
    const us = union_kind.union_of orelse return false;
    for (us.alternatives) |alt| {
        // The `form` primitive shortcut accepts any form head.
        if (alt.namespace == null and std.mem.eql(u8, alt.name, "form")) return true;
        const alt_kind = switch (self.schema.lookupValueKind(alt.name, alt.namespace)) {
            .found => |k| k,
            else => continue,
        };
        if (alt_kind.underlying != .form) continue;
        const hs = alt_kind.heads orelse return true; // no narrowing → any head
        for (hs.names) |h| {
            const canon_h = (try self.canonicaliseFormHead(arena, h, null)) orelse continue;
            if (std.mem.eql(u8, canon_h, canonical_head)) return true;
        }
    }
    return false;
}

/// Where `site`'s extracted definition must land to stay in scope of the
/// original reference. Unscoped cross-refs hoist to the top-level root;
/// scoped ones land inside the nearest enclosing `scope_form`. Null when a
/// scoped cross-ref has no matching ancestor (the validator would already
/// flag `cross_ref_outside_scope`, so there is nowhere valid to place it).
pub fn resolvePlacement(
    self: *const Self,
    arena: Allocator,
    tree: *const Ast.Tree,
    site: ExtractSite,
) Allocator.Error!?Placement {
    if (site.xref.scope_form) |sf_raw| {
        const canon_scope = (try self.canonicaliseFormHead(arena, sf_raw, null)) orelse return null;
        const scope_idx = (try self.findEnclosingScopeFormIdx(arena, tree, site.enclosing_form_idx, canon_scope)) orelse return null;
        return .{ .inside_scope = scope_idx };
    }
    // Unscoped: walk to the outermost ancestor form — the top-level root the
    // reference lives under — and hoist the definition after it.
    var top = site.enclosing_form_idx;
    while (findParentFormIdx(tree, top)) |p| top = p;
    return .{ .top_level_after = top };
}

/// Synthesize a fresh, collision-free name for `site`'s hoisted definition:
/// `<head>-<n>` for the smallest `n ≥ 1` not already defined under the
/// reference's `(scope, target)` in the cross-ref index. Null when the
/// document or its tree index is gone; falls back to `<head>-1` when no
/// index has been built (nothing to collide with).
pub fn freshName(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    site: ExtractSite,
) Allocator.Error!?[]const u8 {
    const doc = self.getDocument(uri) orelse return null;

    // Index first, then the map — the order every other reader uses. The
    // two share a lifetime (see `dropCrossRefIndex`), so probing the map
    // while the index is null is reading through a dropped registry.
    const xri = self.cross_ref_index orelse
        return try std.fmt.allocPrint(arena, "{s}-1", .{site.head});
    const tree_idx = self.uri_to_tree_idx.get(uri) orelse return null;

    // Reuse the fix/completion path's scope+target resolution so the
    // collision set is exactly the names the reference would resolve against.
    const resolved = (try self.resolveCrossRefTargetAndScope(arena, doc, tree_idx, site.enclosing_form_idx, site.xref)) orelse
        return try std.fmt.allocPrint(arena, "{s}-1", .{site.head});

    // The registered-name set is finite and each candidate is distinct, so
    // the first free `<head>-<n>` is found within (count + 1) iterations.
    var n: u32 = 1;
    while (true) : (n += 1) {
        const candidate = try std.fmt.allocPrint(arena, "{s}-{d}", .{ site.head, n });
        if (!xri.contains(resolved.scope, resolved.canonical_target, candidate)) return candidate;
    }
}

/// Every cross-ref definition in the workspace whose name matches
/// `query`, sorted by name, then URI, then position.
///
/// The match is a case-insensitive substring test — deliberately not
/// fuzzy. Fuzzy scoring is the client's job (VS Code re-ranks whatever
/// a server returns), and a server-side scorer would fight it.
/// An empty query matches everything.
///
/// Never null: no index (nothing validated yet) and no match are both
/// "an empty workspace index", which is exactly what a symbol picker
/// wants to show. `getDefinition` returns null instead because there
/// the distinction — no index vs. not a symbol — changes what the
/// editor does.
///
/// O(definitions × query) plus the sort. Names and container names
/// borrow the index's arena, valid for the current epoch; the slice
/// itself is arena-owned.
pub fn getWorkspaceSymbols(
    self: *const Self,
    arena: Allocator,
    query: []const u8,
) Allocator.Error![]const SymbolInfo {
    const index = if (self.cross_ref_index) |*ix| ix else return &.{};

    var out: std.ArrayList(SymbolInfo) = .empty;
    var scope_iter = index.by_scope.iterator();
    while (scope_iter.next()) |scope_entry| {
        var target_iter = scope_entry.value_ptr.iterator();
        while (target_iter.next()) |target_entry| {
            var name_iter = target_entry.value_ptr.iterator();
            while (name_iter.next()) |name_entry| {
                const name = name_entry.key_ptr.*;
                if (!containsIgnoreCase(name, query)) continue;
                const site = name_entry.value_ptr.*;
                // A stale index (rebuild failed after a close) can name a
                // tree that no longer has a URI. Skip rather than index
                // out of bounds — the entry is unreachable anyway.
                if (site.tree_idx >= self.tree_uris.len) continue;
                try out.append(arena, .{
                    .name = name,
                    .container_name = target_entry.key_ptr.*,
                    .location = .{
                        .uri = self.tree_uris[site.tree_idx],
                        .span_start = site.name_span.start,
                        .span_end = site.name_span.end,
                    },
                });
            }
        }
    }

    // Hash-map iteration order is arbitrary; a symbol picker that
    // reshuffles between identical queries is unusable, and the two
    // transports must agree. Sort into a total order.
    std.mem.sort(SymbolInfo, out.items, {}, symbolInfoLessThan);
    return out.items;
}

/// Total order over workspace symbols: name, then URI, then position.
/// The last two only decide ties, but they make the order total — two
/// same-named definitions in different documents must not swap between
/// calls.
fn symbolInfoLessThan(_: void, a: SymbolInfo, b: SymbolInfo) bool {
    return switch (std.mem.order(u8, a.name, b.name)) {
        .lt => true,
        .gt => false,
        .eq => switch (std.mem.order(u8, a.location.uri, b.location.uri)) {
            .lt => true,
            .gt => false,
            .eq => a.location.span_start < b.location.span_start,
        },
    };
}

/// ASCII case-insensitive substring test. An empty needle matches
/// everything (an empty query lists the whole workspace). Non-ASCII
/// bytes compare exactly — SJON symbols are ASCII identifiers, so
/// folding beyond that would be dead code.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var i: usize = 0;
        while (i < needle.len) : (i += 1) {
            if (std.ascii.toLower(haystack[start + i]) != std.ascii.toLower(needle[i])) break;
        } else return true;
    }
    return false;
}

/// One occurrence to highlight while the cursor rests on a cross-ref
/// symbol. Spans are byte offsets into the *requesting* document —
/// unlike `Location`, no URI: `textDocument/documentHighlight` is
/// single-document by protocol.
pub const Highlight = struct {
    span_start: u32,
    span_end: u32,
    kind: Kind,

    /// LSP `DocumentHighlightKind` values, verbatim so transports need
    /// no mapping table. `Text = 1` is deliberately absent: every
    /// highlight SJON produces comes from a cross-ref site whose role is
    /// known, so there is nothing to emit it for.
    pub const Kind = enum(u32) {
        read = 2,
        write = 3,
    };
};

/// Every occurrence of the cross-ref symbol under the cursor *within
/// this document*: the definition (`.write`) and each reference
/// (`.read`). Null on the same conditions as `findReferences` — closed
/// document, no index yet, or a cursor that isn't on a registered site.
///
/// An unresolved reference yields just itself: the site exists, only its
/// definition doesn't.
///
/// The URI filter is what makes this single-document, not the scope
/// policy. Cross-ref scopes happen to be per-tree today (see
/// `getDefinition`), but the index is forest-wide, so filtering is a
/// correctness requirement here rather than a formality.
pub fn getDocumentHighlights(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    byte_offset: u32,
) Allocator.Error!?[]const Highlight {
    const doc = self.getDocument(uri) orelse return null;
    const index = if (self.cross_ref_index) |*ix| ix else return null;
    const tree_idx = self.uri_to_tree_idx.get(uri) orelse return null;

    const sym_idx = findEnclosingSymbolIdx(&doc.tree, byte_offset) orelse return null;
    const cursor_span = doc.tree.spanOf(sym_idx);

    const site = locateCrossRefSite(index, tree_idx, cursor_span) orelse return null;

    const refs = index.lookupReferences(site.scope, site.target, site.name);
    const def: ?Validator.CrossRefIndex.Site = index.lookup(site.scope, site.target, site.name);

    var out: std.ArrayList(Highlight) = .empty;
    // Definition first, mirroring `findReferences`' ordering so the two
    // views of one name agree on sequence.
    if (def) |d| {
        if (d.tree_idx == tree_idx) try out.append(arena, .{
            .span_start = d.name_span.start,
            .span_end = d.name_span.end,
            .kind = .write,
        });
    }
    for (refs) |r| {
        if (r.tree_idx != tree_idx) continue;
        try out.append(arena, .{
            .span_start = r.name_span.start,
            .span_end = r.name_span.end,
            .kind = .read,
        });
    }
    // The cursor sits on a site in this document, so that site is in the
    // set: a highlight request never comes back empty.
    std.debug.assert(out.items.len > 0);
    return out.items;
}

/// `prepareRename` result: the byte span of the symbol the editor will
/// prompt the user to rename. Returning null tells the editor the
/// cursor isn't on a renameable identifier.
pub const PrepareRename = struct {
    span_start: u32,
    span_end: u32,
};

/// Decide whether the cursor is on a renameable cross-ref site, and if
/// so, return the byte span the editor should highlight while the user
/// types the new name. Same cursor-resolution path as `findReferences`.
pub fn prepareRename(
    self: *const Self,
    uri: []const u8,
    byte_offset: u32,
) ?PrepareRename {
    const doc = self.getDocument(uri) orelse return null;
    const index = if (self.cross_ref_index) |*ix| ix else return null;
    const tree_idx = self.uri_to_tree_idx.get(uri) orelse return null;

    const sym_idx = findEnclosingSymbolIdx(&doc.tree, byte_offset) orelse return null;
    const cursor_span = doc.tree.spanOf(sym_idx);

    const site = locateCrossRefSite(index, tree_idx, cursor_span) orelse return null;
    // A provider-backed name has no renameable defining occurrence — it
    // is bytes inside an opaque string. Decline at prepare time so a
    // well-behaved client never opens a prompt `rename` would refuse.
    if (index.providerBacked(site.scope, site.target) != null) return null;
    return .{ .span_start = cursor_span.start, .span_end = cursor_span.end };
}

/// Diagnostic explaining why a rename was rejected. Currently the only
/// failure mode is collision with an existing name in the same scope —
/// the editor surfaces this as a notification.
pub const RenameError = struct {
    message: []const u8,
};

pub const RenameResult = union(enum) {
    edits: WorkspaceEdit,
    err: RenameError,
};

/// Build the workspace-wide edit list to rename the cross-ref symbol
/// under the cursor to `new_name`. Returns:
///   - `null` when the cursor isn't on a cross-ref site (caller maps to
///     LSP "no-op" / null result),
///   - `.err` when `new_name` would collide with an existing definition
///     in the same scope,
///   - `.edits` with one `TextEdit` per definition + reference site,
///     grouped by URI.
///
/// The collision check ignores `new_name == old_name` (a rename to the
/// same name is a no-op, not an error).
pub fn rename(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    byte_offset: u32,
    new_name: []const u8,
) Allocator.Error!?RenameResult {
    const doc = self.getDocument(uri) orelse return null;
    const index = if (self.cross_ref_index) |*ix| ix else return null;
    const tree_idx = self.uri_to_tree_idx.get(uri) orelse return null;

    const sym_idx = findEnclosingSymbolIdx(&doc.tree, byte_offset) orelse return null;
    const cursor_span = doc.tree.spanOf(sym_idx);

    const site = locateCrossRefSite(index, tree_idx, cursor_span) orelse return null;

    // Provider-route buckets refuse outright: the def Site a provider
    // registers spans the *whole source literal* (a provider returns
    // names, not offsets), so the identity-route edit set below would
    // replace the source string with `new_name`. Reached only by a
    // client that skipped prepareRename — which already declined.
    if (index.providerBacked(site.scope, site.target)) |provider| {
        return .{ .err = .{
            .message = try std.fmt.allocPrint(
                arena,
                "cannot rename `{s}`: the name is extracted from opaque content by provider `{s}` — edit the source string instead",
                .{ site.name, provider },
            ),
        } };
    }

    // Collision check. A rename to the same name is allowed (no-op).
    if (!std.mem.eql(u8, site.name, new_name)) {
        if (index.lookup(site.scope, site.target, new_name)) |_| {
            return .{ .err = .{
                .message = try std.fmt.allocPrint(
                    arena,
                    "cannot rename: `{s}` already declared in this scope",
                    .{new_name},
                ),
            } };
        }
    }

    // Collect every site to edit: definition + references.
    var sites: std.ArrayList(Validator.CrossRefIndex.Site) = .empty;
    if (index.lookup(site.scope, site.target, site.name)) |def| {
        try sites.append(arena, def);
    }
    for (index.lookupReferences(site.scope, site.target, site.name)) |s| {
        try sites.append(arena, s);
    }

    // Group by URI. The number of distinct URIs is bounded by
    // `tree_uris.len`; build the per-URI edit lists in input order so
    // the output is deterministic for tests.
    const max_files = self.tree_uris.len;
    var per_uri = try arena.alloc(std.ArrayList(TextEdit), max_files);
    for (per_uri) |*lst| lst.* = .empty;

    for (sites.items) |s| {
        try per_uri[s.tree_idx].append(arena, .{
            .span_start = s.name_span.start,
            .span_end = s.name_span.end,
            .new_text = new_name,
        });
    }

    var file_edits: std.ArrayList(WorkspaceEdit.FileEdits) = .empty;
    for (per_uri, 0..) |lst, i| {
        if (lst.items.len == 0) continue;
        try file_edits.append(arena, .{
            .uri = self.tree_uris[i],
            .edits = lst.items,
        });
    }
    return .{ .edits = .{ .changes = file_edits.items } };
}

test {
    _ = @import("Handler_tests.zig");
}
