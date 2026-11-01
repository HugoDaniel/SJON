//! Per-document schema contexts and document overlays for the native server.
//!
//! The registry is the one owner of every open buffer:
//!
//!   * `OpenDocument` owns the current client bytes independently of any
//!     `Handler`, so moving a document between contexts never reads disk and
//!     never borrows source from the handler that is about to die;
//!   * a `Context` owns exactly one handler plus the schema/config owner that
//!     handler borrows from, and is torn down handler-first;
//!   * `Route` exposes the active handler and context identity for a URI.
//!
//! This task owns baseline contexts, legacy compatibility, source routes,
//! parse-only unavailable routes, and per-document declaration contexts.
//!
//! A configured document is prepared on every open and content change with
//! `Host.prepareSchema`, borrowing the selected bundle's preloaded baseline.
//! Documents without top-level `(plugin …)` / `(use-plugin …)` directives
//! discard that temporary preparation and share the baseline handler; a
//! directive-bearing document gets its own handler whose effective schema is
//! `core ++ baseline-preloaded ++ document-loaded`. Malformed declarations
//! stay document-local: they never replace the baseline or another document's
//! context, and they never install a partial bundle.

const std = @import("std");
const Handler = @import("Handler");
const sjon = @import("sjon");
const uri = @import("uri");
const discovery = @import("discovery");
const editor_config = @import("editor_config");
const schema_bundle = @import("schema_bundle");
const workspace_scan = @import("workspace_scan");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Ast = sjon.Ast;
const Host = sjon.Host;

/// Editor-local identifiers produced by the registry. These are strings, not
/// new `Ast.Diagnostic.Code` variants.
pub const codes = struct {
    pub const bundle_conflict: []const u8 = "sjon-lsp/bundle-conflict";
    pub const bundle_unavailable: []const u8 = "sjon-lsp/bundle-unavailable";
    pub const marker_deleted: []const u8 = "sjon-lsp/marker-deleted";
};

/// One saved-input notification. `uri` is the client spelling; paths are
/// decoded and normalized by the registry. Unknown URIs are ignored unless a
/// retained marker path names them.
pub const FileChangeKind = enum { created, changed, deleted };

pub const FileChange = struct {
    uri: []const u8,
    kind: FileChangeKind = .changed,
};

const NormalizedChange = struct {
    path: []const u8,
    kind: FileChangeKind,
};

/// The documents and source URIs whose reports a saved-input transaction
/// superseded, plus the ones the new state contributes. The caller publishes
/// full reports for `new_uris` and clears every `old_uris` entry absent from
/// them. Both slices are arena-owned by the caller's request arena.
pub const ReloadResult = struct {
    changed: bool = false,
    old_uris: []const []const u8 = &.{},
    new_uris: []const []const u8 = &.{},
};

/// One URI's saved-byte source report. `source` is the saved file bytes and
/// every diagnostic span indexes that slice. Open dirty buffers suppress
/// their saved contribution, so this value never mixes byte streams.
pub const SavedSourceReport = struct {
    uri: []const u8,
    source: []const u8,
    diagnostics: []const Handler.Diagnostic,
};

const SourceAccumulator = struct {
    uri: []const u8,
    source: []const u8,
    diagnostics: std.ArrayList(Handler.Diagnostic),
};

pub const RouteState = enum {
    /// No editor bundle applies: legacy project or core/in-memory behavior.
    unconfigured,
    /// A selected bundle compiled completely.
    ready,
    /// A selected input failed; schema-dependent results must be suppressed.
    unavailable,
    /// The document is a configuration, project, or known bundle source.
    source,
};

pub const Route = struct {
    state: RouteState,
    context_id: []const u8,
    handler: *Handler,
};

/// One open document's current route, sorted by URI for stable publication.
pub const DocumentRoute = struct {
    uri: []const u8,
    route: Route,
};

/// One legacy project source report. `source` and `diagnostics` are
/// arena-owned by the caller's request arena, while `uri` borrows the
/// handler's loaded project state.
pub const ProjectSource = struct {
    uri: []const u8,
    source: []const u8,
    diagnostics: []const Handler.Diagnostic,
};

/// One related location on an editor-local diagnostic. `uri` is explicit
/// because the pointed-at file need not be the reported document.
pub const EditorRelated = struct {
    message: []const u8,
    uri: []const u8,
    span: Ast.Span,
};

/// An editor-local diagnostic. `uri`/`span` identify where the diagnostic is
/// reported; related entries identify real configuration/source locations.
pub const EditorDiagnostic = struct {
    code: []const u8,
    severity: Ast.Diagnostic.Severity,
    message: []const u8,
    uri: []const u8,
    span: Ast.Span,
    related: []const EditorRelated = &.{},
};

/// One open buffer. `source` is owned by the registry and survives a move
/// between contexts; `context` is the currently active context.
pub const OpenDocument = struct {
    uri: []const u8,
    source: [:0]u8,
    version: i64,
    context_id: []const u8,
    context: *Context,
};

const ContextKind = enum {
    core,
    legacy,
    bundle,
    declaration,
    source,
    conflict,
    config_failure,
    marker_deleted,
};

const Context = struct {
    arena: std.heap.ArenaAllocator,
    id: []const u8,
    generation: u32,
    kind: ContextKind,
    state: RouteState,
    handler: Handler,
    /// Marker directory that selected this context, when one did. Every
    /// saved marker path below this directory is a known watch input.
    marker_dir: ?[]const u8 = null,
    /// Selected configuration path/URI for bundle, conflict, failure, and
    /// config source contexts.
    config_path: ?[]const u8 = null,
    config_uri: ?[]const u8 = null,
    /// Marker URI a `marker_deleted` context explains.
    marker_uri: ?[]const u8 = null,
    /// Normalized document path for a source-route context.
    source_path: ?[]const u8 = null,
    /// Baseline bundle context for a one-document declaration context.
    baseline: ?*Context = null,
    /// Owned when non-null; the handler and compiled schema borrow it.
    config: ?*editor_config.Config = null,
    /// Owned when non-null; `handler.schema` borrows `compiled.schema`.
    compiled: ?schema_bundle.Compiled = null,
    /// Owned when non-null; a one-document declaration context. The handler's
    /// schema and preparation diagnostics borrow this value. It borrows the
    /// baseline context's preloaded plugin storage, so declaration contexts
    /// are destroyed before any baseline.
    prepared: ?*Host.PreparedSchema = null,
    /// Saved disk inputs this context's declaration preparation depends on:
    /// every resolved manifest path (including failed loads) and the
    /// applicable same-directory project index. GPA-owned strings, replaced
    /// transactionally with the preparation.
    dependencies: []const []const u8 = &.{},
    /// Pre-rendered conflict descriptions with their real bundle spans,
    /// arena-owned.
    conflict_entries: []const ConflictEntry = &.{},
    /// Directory of the legacy `sjon-project.sjon` this context loaded, so a
    /// watched-file reload can re-run the same discovery. Arena-owned.
    project_root: ?[]const u8 = null,
};

const ConflictEntry = struct {
    message: []const u8,
    span: Ast.Span,
};

/// An owned, not-yet-installed declaration preparation. The caller either
/// hands it to a new declaration context or commits it onto an existing one
/// after the replacement handler has accepted the current buffer.
const DeclarationPreparation = struct {
    prepared: *Host.PreparedSchema,
    dependencies: []const []const u8,

    fn deinit(self: *DeclarationPreparation, gpa: Allocator) void {
        self.prepared.deinit();
        gpa.destroy(self.prepared);
        freeDependencies(gpa, self.dependencies);
        self.* = undefined;
    }
};

const ResolvedContext = struct {
    context: *Context,
    created: bool,
    generation_key: ?[]const u8 = null,
    next_generation: u32 = 0,
    /// A replacement preparation for an existing declaration context. The
    /// caller builds the replacement handler, inserts the current buffer, and
    /// only then releases the old preparation.
    pending: ?DeclarationPreparation = null,
};

pub const Registry = struct {
    gpa: Allocator,
    io: Io,
    roots_arena: std.heap.ArenaAllocator,
    roots: []const discovery.Root = &.{},
    documents: uri.HashMapUnmanaged(OpenDocument),
    contexts: std.ArrayList(*Context),
    contexts_by_id: std.StringHashMapUnmanaged(*Context),
    /// Last generation number committed for a context identity. Keys live in
    /// `meta_arena`; a replacement of the same identity gets the next value.
    generations: std.StringHashMapUnmanaged(u32),
    meta_arena: std.heap.ArenaAllocator,
    /// Marker paths this connection has selected at least once. Retained
    /// across deletion so a recreated marker is a known input rather than a
    /// wholly new one.
    known_markers: std.StringHashMapUnmanaged(void),
    /// Selected markers currently observed deleted. Documents under these
    /// boundaries stay unavailable until the marker is recreated; a new
    /// document cannot rediscover a parent configuration past the boundary.
    deleted_markers: std.ArrayList(MarkerBlock),

    pub fn init(gpa: Allocator, io: Io) Registry {
        return .{
            .gpa = gpa,
            .io = io,
            .roots_arena = std.heap.ArenaAllocator.init(gpa),
            .documents = .empty,
            .contexts = .empty,
            .contexts_by_id = .empty,
            .generations = .empty,
            .meta_arena = std.heap.ArenaAllocator.init(gpa),
            .known_markers = .empty,
            .deleted_markers = .empty,
        };
    }

    /// Replace the initialization roots. Existing open documents keep their
    /// current contexts until they are next opened or changed.
    pub fn configureRoots(self: *Registry, roots: []const discovery.Root) Allocator.Error!void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const copies = try a.alloc(discovery.Root, roots.len);
        for (roots, 0..) |root, i| {
            copies[i] = .{
                .path = try a.dupe(u8, root.path),
                .uri = try a.dupe(u8, root.uri),
            };
        }

        self.roots_arena.deinit();
        self.roots_arena = arena;
        self.roots = copies;
    }

    /// Open or replace a document. The returned route is the active context
    /// after the operation.
    pub fn openDocument(
        self: *Registry,
        document_uri: []const u8,
        version: i64,
        text: []const u8,
    ) Allocator.Error!Route {
        return self.upsert(document_uri, version, text, false) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnknownDocument => unreachable,
        };
    }

    /// Replace an open document's bytes and re-associate it if discovery now
    /// selects a different context.
    pub fn changeDocumentFull(
        self: *Registry,
        document_uri: []const u8,
        version: i64,
        text: []const u8,
    ) Handler.Error!Route {
        return self.upsert(document_uri, version, text, true);
    }

    pub fn closeDocument(self: *Registry, document_uri: []const u8) void {
        const entry = self.documents.fetchRemove(document_uri) orelse return;
        const context = entry.value.context;
        context.handler.closeDocument(document_uri);
        self.gpa.free(entry.key);
        self.gpa.free(entry.value.source);
        // A declaration context exists for exactly one document. Closing that
        // document releases the preparation and its borrowed baseline view
        // instead of retaining an unreachable per-document context.
        if (context.kind == .declaration) self.removeContext(context);
    }

    pub fn route(self: *const Registry, document_uri: []const u8) ?Route {
        const doc = self.documents.getPtr(document_uri) orelse return null;
        return routeFromContext(doc.context);
    }

    /// The parsed document behind a URI, whether it is an open buffer or a
    /// workspace-ingested file. Used for target-URI source lookup: a
    /// definition or edit may name a document that this request's context
    /// does not hold, while the registry still knows which handler does.
    pub fn documentFor(self: *const Registry, document_uri: []const u8) ?*const Handler.Document {
        if (self.documents.getPtr(document_uri)) |doc| {
            return doc.context.handler.getDocument(document_uri);
        }
        for (self.contexts.items) |context| {
            if (context.handler.getDocument(document_uri)) |doc| return doc;
        }
        return null;
    }

    /// The handler that owns `document_uri`, open or workspace-ingested.
    /// Used where a report needs its project indicator but not a route.
    pub fn handlerFor(self: *const Registry, document_uri: []const u8) ?*const Handler {
        if (self.documents.getPtr(document_uri)) |doc| return &doc.context.handler;
        for (self.contexts.items) |context| {
            if (context.handler.getDocument(document_uri) != null) return &context.handler;
        }
        return null;
    }

    /// Saved disk inputs the document's active declaration context depends
    /// on: resolved manifest paths (recorded before their load is known) and
    /// the applicable same-directory `sjon-project.sjon`. Empty for ordinary
    /// documents, which share the bundle baseline. Borrowed from the context;
    /// valid until that document's context is replaced or the registry is
    /// deinitialized.
    pub fn savedDependencies(
        self: *const Registry,
        document_uri: []const u8,
    ) []const []const u8 {
        const doc = self.documents.getPtr(document_uri) orelse return &.{};
        return doc.context.dependencies;
    }

    /// Every open document's active route, sorted by URI. Push publication
    /// and workspace pulls walk this instead of a singleton handler.
    pub fn documentRoutes(
        self: *const Registry,
        arena: Allocator,
    ) Allocator.Error![]const DocumentRoute {
        const out = try arena.alloc(DocumentRoute, self.documents.count());
        var i: usize = 0;
        var it = self.documents.iterator();
        while (it.next()) |entry| : (i += 1) {
            out[i] = .{
                .uri = entry.key_ptr.*,
                .route = routeFromContext(entry.value_ptr.context),
            };
        }
        std.debug.assert(i == out.len);
        std.mem.sort(DocumentRoute, out, {}, struct {
            fn lt(_: void, a: DocumentRoute, b: DocumentRoute) bool {
                return std.mem.lessThan(u8, a.uri, b.uri);
            }
        }.lt);
        return out;
    }

    /// Load a root-level legacy project when the root has no editor
    /// configuration. This is the one eager load the native server does:
    /// a project source must answer pulls even before a document is opened.
    /// A root with `sjon-lsp.sjon` is left to per-document discovery, which
    /// never loads a sibling project eagerly.
    pub fn loadRootProject(self: *Registry, root_path: []const u8) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();

        const project_path = try std.fs.path.join(a, &.{ root_path, discovery.markers.project });
        const config_path = try std.fs.path.join(a, &.{ root_path, discovery.markers.config });
        const has_project = pathExists(self.io, project_path);
        const has_config = pathExists(self.io, config_path);
        if (!has_project and !has_config) return;

        // A root-level editor configuration is a selected marker even before
        // any document opens, so a watched edit can trigger rediscovery.
        try self.rememberMarkerDir(root_path);
        if (!has_project or has_config) return;

        const id = try std.fmt.allocPrint(a, "legacy:{s}", .{project_path});
        if (self.contextById(id) != null) return;

        try self.reserveNewContext();
        const generation = try self.prepareGeneration(id);
        const context = try self.createLegacy(id, generation.generation, root_path);
        self.contexts.appendAssumeCapacity(context);
        self.contexts_by_id.putAssumeCapacity(context.id, context);
        self.generations.putAssumeCapacity(generation.key, generation.next);
    }

    /// Every loaded legacy project source, sorted and deduplicated by decoded
    /// URI. One handler owns one project, so duplicate URIs can only come
    /// from two turns of the same reload; deduplication keeps publication
    /// from reporting the same source twice.
    pub fn projectSources(
        self: *const Registry,
        arena: Allocator,
    ) Allocator.Error![]const ProjectSource {
        var list: std.ArrayList(ProjectSource) = .empty;
        for (self.contexts.items) |context| {
            if (context.kind != .legacy) continue;
            const info = context.handler.getProjectInfo() orelse continue;
            const project_uri = info.project_uri orelse continue;
            const project_source = info.project_source orelse continue;
            const diagnostics = (try context.handler.getProjectDiagnostics(arena)) orelse continue;

            var duplicate = false;
            for (list.items) |existing| {
                if (uri.HashContext.eql(.{}, existing.uri, project_uri)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            try list.append(arena, .{
                .uri = project_uri,
                .source = project_source,
                .diagnostics = diagnostics,
            });
        }
        std.mem.sort(ProjectSource, list.items, {}, struct {
            fn lt(_: void, a: ProjectSource, b: ProjectSource) bool {
                return std.mem.lessThan(u8, a.uri, b.uri);
            }
        }.lt);
        return list.items;
    }

    /// The legacy project source with this URI, or null when no loaded
    /// project matches. Used by a pull for a project file the editor has
    /// not opened.
    pub fn projectSourceFor(
        self: *const Registry,
        arena: Allocator,
        document_uri: []const u8,
    ) Allocator.Error!?ProjectSource {
        const sources = try self.projectSources(arena);
        for (sources) |source| {
            if (uri.HashContext.eql(.{}, source.uri, document_uri)) return source;
        }
        return null;
    }

    /// Diagnostic reports for every document held by every context — open
    /// buffers and workspace-ingested files — in stable URI order.
    pub fn workspaceReports(
        self: *const Registry,
        arena: Allocator,
    ) Allocator.Error![]const Handler.WorkspaceReport {
        var list: std.ArrayList(Handler.WorkspaceReport) = .empty;
        for (self.contexts.items) |context| {
            const reports = try context.handler.getWorkspaceDiagnostics(arena);
            try list.appendSlice(arena, reports);
        }
        std.mem.sort(Handler.WorkspaceReport, list.items, {}, struct {
            fn lt(_: void, a: Handler.WorkspaceReport, b: Handler.WorkspaceReport) bool {
                return std.mem.lessThan(u8, a.uri, b.uri);
            }
        }.lt);
        return list.items;
    }

    /// Cross-ref symbols from every context that still owns a schema, merged
    /// in stable (name, URI, range) order. Unavailable/source contexts have
    /// no schema index, so they contribute nothing.
    pub fn workspaceSymbols(
        self: *const Registry,
        arena: Allocator,
        query: []const u8,
    ) Allocator.Error![]const Handler.SymbolInfo {
        var list: std.ArrayList(Handler.SymbolInfo) = .empty;
        for (self.contexts.items) |context| {
            if (context.state == .unavailable or context.state == .source) continue;
            const symbols = try context.handler.getWorkspaceSymbols(arena, query);
            try list.appendSlice(arena, symbols);
        }
        std.mem.sort(Handler.SymbolInfo, list.items, {}, struct {
            fn lt(_: void, a: Handler.SymbolInfo, b: Handler.SymbolInfo) bool {
                if (!std.mem.eql(u8, a.name, b.name)) return std.mem.lessThan(u8, a.name, b.name);
                if (!std.mem.eql(u8, a.location.uri, b.location.uri)) {
                    return std.mem.lessThan(u8, a.location.uri, b.location.uri);
                }
                return a.location.span_start < b.location.span_start;
            }
        }.lt);
        return list.items;
    }

    /// Ingest the scanned workspace files that belong to this registry.
    ///
    /// `files` may arrive root-by-root in any order; they are sorted
    /// globally by URI before any cap applies, so the surviving set is a
    /// property of the workspace rather than of directory iteration or
    /// context creation order. Open buffers shadow disk, and marker or
    /// known-source routes are excluded before accounting. One never-open
    /// file budget spans every context; each handler's cap is its
    /// already-held count plus the files admitted to it here, never a
    /// fresh per-handler allowance. Reference scope stays per-handler:
    /// grouping decides where bytes live, not what they can reference.
    pub fn ingestWorkspaceFiles(
        self: *Registry,
        files: []const Handler.WorkspaceFile,
        limits: workspace_scan.WorkspaceLimits,
    ) Allocator.Error!Handler.WorkspaceIngest {
        if (files.len == 0) return .{ .ingested = 0, .clipped = 0 };

        var scratch_state = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();

        const sorted = try scratch.dupe(Handler.WorkspaceFile, files);
        std.mem.sort(Handler.WorkspaceFile, sorted, {}, struct {
            fn lt(_: void, a: Handler.WorkspaceFile, b: Handler.WorkspaceFile) bool {
                return std.mem.lessThan(u8, a.uri, b.uri);
            }
        }.lt);

        // Count what every existing handler already holds. The shared
        // budget is the ceiling on never-open documents across contexts,
        // so one context's earlier admission is not another's to spend.
        var held_by_context: std.AutoHashMapUnmanaged(*Context, usize) = .empty;
        defer held_by_context.deinit(scratch);
        var total_held: usize = 0;
        for (self.contexts.items) |context| {
            const held = try workspaceHeldCount(&context.handler, scratch);
            try held_by_context.put(scratch, context, held);
            total_held += held;
        }
        var remaining_new = limits.max_files -| total_held;

        var groups: std.ArrayList(WorkspaceGroup) = .empty;
        defer groups.deinit(scratch);
        var seen: uri.HashMapUnmanaged(void) = .empty;
        defer seen.deinit(scratch);
        var clipped_before_handler: usize = 0;
        // A URI whose holder changed this ingest: the bytes move to
        // `context` and the previous holder loses them once the new bytes
        // are committed by the flush below. Closed afterwards so a flush
        // failure keeps the old holder's report rather than dropping the
        // URI's only one.
        const HolderMove = struct { context: *Context, uri: []const u8 };
        var moves: std.ArrayList(HolderMove) = .empty;
        defer moves.deinit(scratch);
        var totals: Handler.WorkspaceIngest = .{ .ingested = 0, .clipped = 0 };

        for (sorted) |file| {
            // The same file reached through two overlapping roots is one
            // candidate; the decoded-URI map treats its spellings alike.
            if (seen.contains(file.uri)) continue;
            try seen.put(scratch, file.uri, {});

            // An open buffer is the user's truth; the disk copy is only
            // the last save. It must not be replaced or counted.
            if (self.documents.getPtr(file.uri) != null) continue;

            const decoded = (try uri.fileUriToPath(scratch, file.uri)) orelse continue;
            const path = try std.fs.path.resolve(scratch, &.{decoded});
            if (isMarkerFile(path)) continue;

            var resolved = try self.ensureContext(file.uri, file.source);
            const target = resolved.context;

            // A pending preparation means this file's new disk bytes
            // changed its declarations while its declaration context still
            // holds the previous schema. Commit the preparation the way an
            // open-buffer edit does: build the replacement handler, ingest
            // the new bytes into it, and swap atomically so no report
            // mixes current parse text with stale declaration state.
            if (resolved.pending) |preparation| {
                // A pending preparation only exists for an already
                // registered declaration context.
                std.debug.assert(!resolved.created);
                var pending = preparation;
                resolved.pending = null;
                errdefer pending.deinit(self.gpa);
                var replacement = buildDeclarationHandler(
                    self.gpa,
                    target.id,
                    target.generation,
                    pending.prepared,
                );
                errdefer replacement.deinit();
                const result = try replacement.ingestWorkspaceFilesWithCap(
                    &.{file},
                    Handler.MAX_WORKSPACE_FILES,
                );

                const old_handler = target.handler;
                const old_prepared = target.prepared;
                const old_dependencies = target.dependencies;
                target.handler = replacement;
                target.prepared = pending.prepared;
                target.dependencies = pending.dependencies;
                totals.ingested += result.ingested;
                totals.clipped += result.clipped;
                var released_handler = old_handler;
                released_handler.deinit();
                if (old_prepared) |old| {
                    old.deinit();
                    self.gpa.destroy(old);
                }
                freeDependencies(self.gpa, old_dependencies);
                continue;
            }

            if (resolved.created) {
                self.contexts.appendAssumeCapacity(target);
                self.contexts_by_id.putAssumeCapacity(target.id, target);
                self.generations.putAssumeCapacity(
                    resolved.generation_key.?,
                    resolved.next_generation,
                );
                try held_by_context.put(scratch, target, 0);
            }

            // Configuration, project, and resolved manifest files are
            // source reports, not ordinary project data. Exclude them
            // before the file ceiling sees them.
            if (target.state == .source) continue;

            const is_new = target.handler.getDocument(file.uri) == null;
            var moved_from: ?*Context = null;
            if (is_new) {
                // One URI, one holder. The file may already be held by
                // another context — a declaration that disappeared moves it
                // onto the baseline, one that appeared moves it off. Such a
                // move is not a new admission against the shared budget.
                for (self.contexts.items) |other| {
                    if (other == target) continue;
                    if (other.handler.getDocument(file.uri) == null) continue;
                    moved_from = other;
                    break;
                }
            }
            if (is_new and moved_from == null) {
                if (remaining_new == 0) {
                    clipped_before_handler += 1;
                    continue;
                }
                remaining_new -= 1;
            }

            const group_index = try findOrAddGroup(&groups, scratch, target);
            const group = &groups.items[group_index];
            try group.files.append(scratch, file);
            if (is_new) group.new_count += 1;
            if (moved_from) |old| try moves.append(scratch, .{ .context = old, .uri = file.uri });
        }

        var totals_flush: Handler.WorkspaceIngest = .{ .ingested = 0, .clipped = 0 };
        for (groups.items) |group| {
            const held = held_by_context.get(group.context) orelse 0;
            // The handler's own ceiling still applies, but the cap it is
            // given is derived from this context's held plus admitted
            // files, not from a fresh global allowance.
            const cap = @min(
                Handler.MAX_WORKSPACE_FILES,
                held + group.new_count,
            );
            const result = try group.context.handler.ingestWorkspaceFilesWithCap(
                group.files.items,
                cap,
            );
            totals_flush.ingested += result.ingested;
            totals_flush.clipped += result.clipped;
        }
        totals.ingested += totals_flush.ingested;
        totals.clipped += totals_flush.clipped;
        totals.clipped += clipped_before_handler;

        // The new bytes are committed; now take the moved URIs away from
        // their previous holders. A declaration context is owned by exactly
        // one document identity, so the one that lost its document goes
        // away entirely — with its reports — instead of surviving as a
        // stale duplicate.
        for (moves.items) |move| {
            move.context.handler.closeDocument(move.uri);
            self.removeIfDeclaration(move.context);
        }
        return totals;
    }

    /// Editor-local diagnostics for an open document. Schema-dependent
    /// results stay in the handler; this supplies only configuration/bundle
    /// failures and typed configuration diagnostics for source routes.
    pub fn editorDiagnostics(
        self: *const Registry,
        arena: Allocator,
        document_uri: []const u8,
    ) Allocator.Error![]const EditorDiagnostic {
        const doc = self.documents.getPtr(document_uri) orelse return &.{};
        return editorDiagnosticsFor(self, arena, document_uri, doc.context);
    }

    pub fn deinit(self: *Registry) void {
        // Declaration handlers borrow their baseline bundle's preloaded plugin
        // storage. Release every declaration context first so no baseline
        // arena can die under a still-live borrowing handler.
        for (self.contexts.items) |context| {
            if (context.kind == .declaration) destroyContext(self.gpa, context);
        }
        for (self.contexts.items) |context| {
            if (context.kind != .declaration) destroyContext(self.gpa, context);
        }
        self.contexts.deinit(self.gpa);
        self.contexts_by_id.deinit(self.gpa);
        self.generations.deinit(self.gpa);
        self.known_markers.deinit(self.gpa);
        self.deleted_markers.deinit(self.gpa);
        self.meta_arena.deinit();

        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.source);
        }
        self.documents.deinit(self.gpa);
        self.roots_arena.deinit();
        self.* = undefined;
    }

    pub fn hasLegacyContexts(self: *const Registry) bool {
        for (self.contexts.items) |context| {
            if (context.kind == .legacy) return true;
        }
        return false;
    }

    /// True when `document_uri` names a selected marker or a saved input a
    /// configured context depends on. Legacy project manifests are not
    /// enumerated here: a pure legacy connection retains its broad reload.
    pub fn isKnownInputUri(
        self: *const Registry,
        arena: Allocator,
        document_uri: []const u8,
    ) Allocator.Error!bool {
        const decoded = (try uri.fileUriToPath(arena, document_uri)) orelse return false;
        const path = try std.fs.path.resolve(arena, &.{decoded});
        return self.isKnownInputPath(path);
    }

    pub fn isKnownInputPath(self: *const Registry, path: []const u8) bool {
        if (self.known_markers.contains(path)) return true;
        for (self.contexts.items) |context| {
            if (context.config_path) |config_path| {
                if (std.mem.eql(u8, config_path, path)) return true;
            }
            if (context.compiled) |*compiled| {
                for (compiled.sources) |source| {
                    if (std.mem.eql(u8, source.path, path)) return true;
                }
            }
            for (context.dependencies) |dependency| {
                if (std.mem.eql(u8, dependency, path)) return true;
            }
        }
        return false;
    }

    /// Saved-byte reports for every selected configuration and required
    /// manifest source, combined and deduplicated per decoded URI. An open
    /// buffer whose bytes differ from the saved file suppresses that URI's
    /// saved contribution: a report may never mix byte streams.
    pub fn savedSourceReports(
        self: *const Registry,
        arena: Allocator,
    ) Allocator.Error![]const SavedSourceReport {
        var list: std.ArrayList(SourceAccumulator) = .empty;

        for (self.contexts.items) |context| {
            switch (context.kind) {
                .bundle => {
                    const config = context.config orelse continue;
                    if (context.compiled) |*compiled| {
                        for (compiled.sources, compiled.reports) |source, report| {
                            const source_bytes = source.bytes orelse continue;
                            try appendSourceDiagnostics(
                                arena,
                                &list,
                                source.uri,
                                source_bytes,
                                try hostDiagnostics(arena, report.diagnostics),
                            );
                        }
                        for (compiled.config_reports) |report| {
                            try appendSourceDiagnostics(
                                arena,
                                &list,
                                config.uri,
                                config.source,
                                try configReportDiagnostics(arena, config.uri, report),
                            );
                        }
                        // A clean selected configuration still owns one
                        // (empty) source report, so recovery can clear it.
                        try appendSourceDiagnostics(
                            arena,
                            &list,
                            config.uri,
                            config.source,
                            &.{},
                        );
                    }
                },
                .config_failure => {
                    const config = context.config orelse continue;
                    var diagnostics: std.ArrayList(Handler.Diagnostic) = .empty;
                    for (config.diagnostics) |diagnostic| {
                        try appendConfigDiagnostic(arena, &diagnostics, config.uri, diagnostic);
                    }
                    for (config.parse_diagnostics) |diagnostic| {
                        try diagnostics.append(arena, astDiagnostic(diagnostic));
                    }
                    try appendSourceDiagnostics(
                        arena,
                        &list,
                        config.uri,
                        config.source,
                        try diagnostics.toOwnedSlice(arena),
                    );
                },
                .conflict => {
                    const config = context.config orelse continue;
                    var diagnostics: std.ArrayList(Handler.Diagnostic) = .empty;
                    for (config.diagnostics) |diagnostic| {
                        try appendConfigDiagnostic(arena, &diagnostics, config.uri, diagnostic);
                    }
                    for (config.parse_diagnostics) |diagnostic| {
                        try diagnostics.append(arena, astDiagnostic(diagnostic));
                    }
                    try appendSourceDiagnostics(
                        arena,
                        &list,
                        config.uri,
                        config.source,
                        try diagnostics.toOwnedSlice(arena),
                    );
                },
                .source, .core, .legacy, .declaration, .marker_deleted => {},
            }
        }

        var out: std.ArrayList(SavedSourceReport) = .empty;
        for (list.items) |*accumulator| {
            if (self.openDocumentByUri(accumulator.uri)) |doc| {
                if (!std.mem.eql(u8, doc.source, accumulator.source)) continue;
            }
            try out.append(arena, .{
                .uri = accumulator.uri,
                .source = accumulator.source,
                .diagnostics = try accumulator.diagnostics.toOwnedSlice(arena),
            });
        }
        std.mem.sort(SavedSourceReport, out.items, {}, struct {
            fn lt(_: void, a: SavedSourceReport, b: SavedSourceReport) bool {
                return std.mem.lessThan(u8, a.uri, b.uri);
            }
        }.lt);
        return out.toOwnedSlice(arena);
    }

    pub fn savedSourceReportFor(
        self: *const Registry,
        arena: Allocator,
        document_uri: []const u8,
    ) Allocator.Error!?SavedSourceReport {
        const reports = try self.savedSourceReports(arena);
        for (reports) |report| {
            if (uri.HashContext.eql(.{}, report.uri, document_uri)) return report;
        }
        return null;
    }

    /// Append one URI's saved diagnostics to a live buffer report, removing
    /// entries that describe the same byte span, code, and message. Returns
    /// `live` unchanged when the saved report is suppressed or absent.
    pub fn mergeSourceDiagnostics(
        self: *const Registry,
        arena: Allocator,
        document_uri: []const u8,
        live: []const Handler.Diagnostic,
    ) Allocator.Error![]const Handler.Diagnostic {
        const saved = (try self.savedSourceReportFor(arena, document_uri)) orelse
            return live;

        var out: std.ArrayList(Handler.Diagnostic) = .empty;
        try out.appendSlice(arena, live);
        for (saved.diagnostics) |diagnostic| {
            appendUniqueHandlerDiagnostic(&out, arena, diagnostic) catch |err| return err;
        }
        return out.toOwnedSlice(arena);
    }

    /// Apply saved-input changes from `didSave` or a watched-file event.
    ///
    /// The whole registry is rebuilt transactionally from owned current
    /// buffers (open bytes, not disk) plus workspace-ingested files.
    /// Legacy projects participate in the same replacement/rollback
    /// boundary: they are re-read into the replacement (`loadRootProject`
    /// and per-document discovery), so a failure after one root's project
    /// was successfully re-read still discards every replacement and keeps
    /// every old context — including all legacy ones. The old registry
    /// stays complete on allocation failure, and is released only after
    /// the replacement, its source reports, and its affected-URI sets are
    /// built as arena-owned copies that outlive the release. A deleted
    /// selected marker is an error boundary: documents that used it become
    /// parse-only marker-deleted routes instead of rediscovering a parent.
    ///
    /// Legacy projects keep their broad re-read behavior, so a rebuild
    /// also happens when no known input changed but a legacy context is
    /// loaded; `changed` still reports only whether a known input changed,
    /// which is what the publication branches downstream key on.
    pub fn reloadSavedInputs(
        self: *Registry,
        arena: Allocator,
        changes: []const FileChange,
    ) Allocator.Error!ReloadResult {
        var scratch_state = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();

        var normalized: std.ArrayList(NormalizedChange) = .empty;

        for (changes) |change| {
            const decoded = (try uri.fileUriToPath(scratch, change.uri)) orelse continue;
            const path = try std.fs.path.resolve(scratch, &.{decoded});
            var kind = change.kind;
            if (kind == .changed and !pathExists(self.io, path)) kind = .deleted;
            if (!self.isKnownInputPath(path)) continue;

            var replaced = false;
            for (normalized.items) |*existing| {
                if (!std.mem.eql(u8, existing.path, path)) continue;
                if (kind == .deleted) existing.kind = .deleted;
                replaced = true;
                break;
            }
            if (!replaced) try normalized.append(scratch, .{ .path = path, .kind = kind });
        }

        const changed = normalized.items.len != 0;
        // A workspace with legacy contexts rebuilds even without a known
        // input change: legacy projects re-read on every save, and that
        // re-read must happen inside the transactional boundary, not as a
        // separate mutation of the live contexts.
        if (!changed and !self.hasLegacyContexts()) return .{ .changed = false };

        var blocks: std.ArrayList(MarkerBlock) = .empty;
        for (normalized.items) |change| {
            if (change.kind != .deleted) continue;
            if (markerKind(change.path) == null) continue;
            try blocks.append(scratch, .{
                .path = change.path,
                .dir = std.fs.path.dirname(change.path) orelse ".",
                .uri = try uri.pathToFileUri(scratch, change.path),
                .kind = markerKind(change.path).?,
            });
        }

        var affected: std.StringHashMapUnmanaged(void) = .empty;
        defer affected.deinit(scratch);
        for (self.contexts.items) |context| {
            // A rebuild re-reads every legacy project from disk — both the
            // eager root loads and per-document discovery — so every
            // legacy context is affected by every reload. This preserves
            // the pre-bundle result-id behavior, where each `loadProject`
            // bumped the live handler's schema generation.
            if (contextAffected(context, normalized.items) or context.kind == .legacy) {
                try affected.put(scratch, context.id, {});
            }
        }

        var replacement = Registry.init(self.gpa, self.io);
        errdefer replacement.deinit();

        try replacement.configureRoots(self.roots);
        try replacement.copyKnownMarkers(self);
        try replacement.copyDeletedMarkers(self, normalized.items);
        for (blocks.items) |block| try replacement.appendDeletedMarker(block);
        try replacement.seedGenerations(self, &affected);

        for (self.roots) |root| try replacement.loadRootProject(root.path);

        const snapshots = try self.snapshotDocuments(scratch);
        var workspace_files: std.ArrayList(Handler.WorkspaceFile) = .empty;
        for (snapshots) |snapshot| {
            if (blockedMarkerForDocument(self, &replacement, snapshot.uri, snapshot.path)) |block| {
                switch (snapshot.origin) {
                    .open => try replacement.insertMarkerDeletedOpen(
                        block,
                        snapshot.uri,
                        snapshot.version,
                        snapshot.source,
                    ),
                    .workspace => try replacement.insertMarkerDeletedWorkspace(block, snapshot),
                }
                continue;
            }

            switch (snapshot.origin) {
                .open => _ = try replacement.openDocument(
                    snapshot.uri,
                    snapshot.version,
                    snapshot.source,
                ),
                .workspace => try workspace_files.append(scratch, .{
                    .uri = snapshot.uri,
                    .source = snapshot.source,
                }),
            }
        }
        if (workspace_files.items.len != 0) {
            _ = try replacement.ingestWorkspaceFiles(workspace_files.items, .{});
        }

        const old_uris = try self.collectContextUris(arena);
        const new_uris = try replacement.collectContextUris(arena);

        std.mem.swap(Registry, self, &replacement);
        replacement.deinit();

        return .{
            .changed = changed,
            .old_uris = old_uris,
            .new_uris = new_uris,
        };
    }

    fn openDocumentByUri(self: *const Registry, document_uri: []const u8) ?*OpenDocument {
        if (self.documents.getPtr(document_uri)) |doc| return doc;
        var it = self.documents.valueIterator();
        while (it.next()) |doc| {
            if (uri.HashContext.eql(.{}, doc.uri, document_uri)) return doc;
        }
        return null;
    }

    fn rememberMarkerDir(self: *Registry, marker_dir: []const u8) Allocator.Error!void {
        const a = self.meta_arena.allocator();
        inline for (.{ discovery.markers.config, discovery.markers.project }) |name| {
            const path = try std.fs.path.join(a, &.{ marker_dir, name });
            if (!self.known_markers.contains(path)) {
                try self.known_markers.put(self.gpa, path, {});
            }
        }
    }

    fn rememberConfigPath(self: *Registry, config_path: []const u8) Allocator.Error!void {
        if (std.fs.path.dirname(config_path)) |dir| try self.rememberMarkerDir(dir);
    }

    fn copyKnownMarkers(self: *Registry, source: *const Registry) Allocator.Error!void {
        var it = source.known_markers.keyIterator();
        while (it.next()) |key| {
            const copy = try self.meta_arena.allocator().dupe(u8, key.*);
            try self.known_markers.put(self.gpa, copy, {});
        }
    }

    /// Carry deletion boundaries into a replacement, dropping any marker
    /// whose file exists again or whose change event is a recreation.
    fn copyDeletedMarkers(
        self: *Registry,
        source: *const Registry,
        changes: []const NormalizedChange,
    ) Allocator.Error!void {
        for (source.deleted_markers.items) |block| {
            var recreated = pathExists(self.io, block.path);
            for (changes) |change| {
                if (!std.mem.eql(u8, change.path, block.path)) continue;
                if (change.kind != .deleted) recreated = true;
            }
            if (!recreated) try self.appendDeletedMarker(block);
        }
    }

    fn appendDeletedMarker(self: *Registry, block: MarkerBlock) Allocator.Error!void {
        for (self.deleted_markers.items) |existing| {
            if (std.mem.eql(u8, existing.path, block.path)) return;
        }
        const a = self.meta_arena.allocator();
        try self.deleted_markers.append(self.gpa, .{
            .path = try a.dupe(u8, block.path),
            .dir = try a.dupe(u8, block.dir),
            .uri = try a.dupe(u8, block.uri),
            .kind = block.kind,
        });
    }

    fn deletedMarkerFor(
        self: *Registry,
        document_uri: []const u8,
        document_path: []const u8,
    ) Allocator.Error!?MarkerBlock {
        var best: ?MarkerBlock = null;
        for (self.deleted_markers.items) |block| {
            if (!pathContains(block.dir, document_path)) continue;
            if (pathExists(self.io, block.path)) continue;
            if (best) |current| {
                if (block.dir.len <= current.dir.len) continue;
            }
            best = block;
        }
        const block = best orelse return null;

        var selection = try discovery.discover(self.gpa, self.io, self.roots, document_uri);
        defer selection.deinit();
        if (selection.marker_dir) |marker_dir| {
            if (!std.mem.eql(u8, marker_dir, block.dir) and pathContains(block.dir, marker_dir)) {
                return null;
            }
        }
        return block;
    }

    /// Seed the replacement's next-generation table with each old context's
    /// current generation. Affected contexts are bumped exactly once; an
    /// unaffected context rebuilt at the same identity therefore keeps its
    /// result id byte-identical.
    fn seedGenerations(
        self: *Registry,
        source: *const Registry,
        affected: *const std.StringHashMapUnmanaged(void),
    ) Allocator.Error!void {
        for (source.contexts.items) |context| {
            const next = if (affected.contains(context.id))
                context.generation +% 1
            else
                context.generation;
            const key = try self.meta_arena.allocator().dupe(u8, context.id);
            try self.generations.put(self.gpa, key, next);
        }
    }

    const Snapshot = struct {
        uri: []const u8,
        path: []const u8,
        source: []const u8,
        version: i64,
        origin: Handler.Document.Origin,
    };

    fn snapshotDocuments(self: *const Registry, arena: Allocator) Allocator.Error![]const Snapshot {
        var list: std.ArrayList(Snapshot) = .empty;

        var open_it = self.documents.valueIterator();
        while (open_it.next()) |doc| {
            const decoded = (try uri.fileUriToPath(arena, doc.uri)) orelse continue;
            try list.append(arena, .{
                .uri = doc.uri,
                .path = try std.fs.path.resolve(arena, &.{decoded}),
                .source = doc.source,
                .version = doc.version,
                .origin = .open,
            });
        }

        for (self.contexts.items) |context| {
            const reports = try context.handler.getWorkspaceDiagnostics(arena);
            for (reports) |report| {
                if (report.version != null) continue;
                if (self.openDocumentByUri(report.uri) != null) continue;
                const doc = context.handler.getDocument(report.uri) orelse continue;
                const decoded = (try uri.fileUriToPath(arena, report.uri)) orelse continue;
                try list.append(arena, .{
                    .uri = report.uri,
                    .path = try std.fs.path.resolve(arena, &.{decoded}),
                    .source = doc.source,
                    .version = 0,
                    .origin = .workspace,
                });
            }
        }

        std.mem.sort(Snapshot, list.items, {}, struct {
            fn lt(_: void, a: Snapshot, b: Snapshot) bool {
                return std.mem.lessThan(u8, a.uri, b.uri);
            }
        }.lt);
        return list.toOwnedSlice(arena);
    }

    /// Every URI the contexts' saved-input state names: configuration,
    /// marker, compiled sources, saved dependencies, and report documents,
    /// sorted and deduplicated. Each string is copied into `arena`, so the
    /// result never borrows `self`: the caller destroys the old registry
    /// before reading the old set back.
    fn collectContextUris(
        self: *const Registry,
        arena: Allocator,
    ) Allocator.Error![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;

        for (self.contexts.items) |context| {
            if (context.config_uri) |config_uri| try appendUniqueString(arena, &list, config_uri);
            if (context.marker_uri) |marker_uri| try appendUniqueString(arena, &list, marker_uri);
            if (context.compiled) |*compiled| {
                for (compiled.sources) |source| {
                    try appendUniqueString(arena, &list, source.uri);
                }
            }
            for (context.dependencies) |dependency| {
                try appendUniqueString(
                    arena,
                    &list,
                    try uri.pathToFileUri(arena, dependency),
                );
            }
            const reports = try context.handler.getWorkspaceDiagnostics(arena);
            for (reports) |report| try appendUniqueString(arena, &list, report.uri);
        }

        std.mem.sort([]const u8, list.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        return list.toOwnedSlice(arena);
    }

    fn ensureMarkerDeletedContext(
        self: *Registry,
        block: MarkerBlock,
    ) Allocator.Error!*Context {
        const id = try std.fmt.allocPrint(self.meta_arena.allocator(), "marker-deleted:{s}", .{block.path});
        if (self.contextById(id)) |existing| return existing;

        try self.reserveNewContext();
        const generation = try self.prepareGeneration(id);

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const id_copy = try a.dupe(u8, id);
        var handler = Handler.initWithOptions(self.gpa, .{
            .borrowed_schema = .{ .plugins = &.{} },
            .context_id = id_copy,
            .schema_generation = generation.generation,
            .diagnostic_mode = .parse_only,
        });
        errdefer handler.deinit();

        const marker_dir_copy = try a.dupe(u8, block.dir);
        const config_path_copy = try a.dupe(u8, block.path);
        const config_uri_copy = try a.dupe(u8, block.uri);
        const marker_uri_copy = try a.dupe(u8, block.uri);
        const context = try self.gpa.create(Context);
        context.* = .{
            .arena = arena,
            .id = id_copy,
            .generation = generation.generation,
            .kind = .marker_deleted,
            .state = .unavailable,
            .handler = handler,
            .marker_dir = marker_dir_copy,
            .config_path = config_path_copy,
            .config_uri = config_uri_copy,
            .marker_uri = marker_uri_copy,
        };
        self.contexts.appendAssumeCapacity(context);
        self.contexts_by_id.putAssumeCapacity(context.id, context);
        return context;
    }

    fn insertMarkerDeletedOpen(
        self: *Registry,
        block: MarkerBlock,
        document_uri: []const u8,
        version: i64,
        text: []const u8,
    ) Allocator.Error!void {
        const context = try self.ensureMarkerDeletedContext(block);
        const source_copy = try sentinelDupe(self.gpa, text);
        errdefer self.gpa.free(source_copy);
        const key_copy = try self.gpa.dupe(u8, document_uri);
        errdefer self.gpa.free(key_copy);
        try self.documents.ensureUnusedCapacity(self.gpa, 1);
        try context.handler.openDocument(document_uri, version, text);
        self.documents.putAssumeCapacity(key_copy, .{
            .uri = key_copy,
            .source = source_copy,
            .version = version,
            .context_id = context.id,
            .context = context,
        });
    }

    fn insertMarkerDeletedWorkspace(
        self: *Registry,
        block: MarkerBlock,
        snapshot: Snapshot,
    ) Allocator.Error!void {
        const context = try self.ensureMarkerDeletedContext(block);
        _ = try context.handler.ingestWorkspaceFilesWithCap(&.{.{
            .uri = snapshot.uri,
            .source = snapshot.source,
        }}, Handler.MAX_WORKSPACE_FILES);
    }

    fn upsert(
        self: *Registry,
        document_uri: []const u8,
        version: i64,
        text: []const u8,
        require_existing: bool,
    ) Handler.Error!Route {
        const existing: ?*OpenDocument = self.documents.getPtr(document_uri);
        if (require_existing and existing == null) return error.UnknownDocument;

        const source_copy = try sentinelDupe(self.gpa, text);
        errdefer self.gpa.free(source_copy);

        const key_copy: ?[]const u8 = if (existing == null) try self.gpa.dupe(u8, document_uri) else null;
        errdefer if (key_copy) |key| self.gpa.free(key);
        if (existing == null) try self.documents.ensureUnusedCapacity(self.gpa, 1);

        var resolved = try self.ensureContext(document_uri, text);
        var pending = resolved.pending;
        resolved.pending = null;
        errdefer {
            if (resolved.created) destroyContext(self.gpa, resolved.context);
            if (pending) |*preparation| preparation.deinit(self.gpa);
        }
        const target = resolved.context;

        // A directive-bearing document is re-prepared on every edit. The
        // replacement handler already holds the new bytes; commit it before
        // releasing the preparation the old handler borrowed.
        if (pending) |preparation| {
            var replacement = buildDeclarationHandler(
                self.gpa,
                target.id,
                target.generation,
                preparation.prepared,
            );
            errdefer replacement.deinit();
            try replacement.openDocument(document_uri, version, text);

            const old_handler = target.handler;
            const old_prepared = target.prepared;
            const old_dependencies = target.dependencies;

            // Rebind first: the replacement handler and its schema owner are
            // live before the old preparation is released.
            target.handler = replacement;
            target.prepared = preparation.prepared;
            target.dependencies = preparation.dependencies;
            pending = null;

            var released_handler = old_handler;
            released_handler.deinit();
            if (old_prepared) |old| {
                old.deinit();
                self.gpa.destroy(old);
            }
            freeDependencies(self.gpa, old_dependencies);

            if (existing) |doc| {
                if (doc.context != target) {
                    doc.context.handler.closeDocument(document_uri);
                    self.removeIfDeclaration(doc.context);
                }
                self.gpa.free(doc.source);
                doc.source = source_copy;
                doc.version = version;
                doc.context = target;
                doc.context_id = target.id;
            } else {
                self.documents.putAssumeCapacity(key_copy.?, .{
                    .uri = key_copy.?,
                    .source = source_copy,
                    .version = version,
                    .context_id = target.id,
                    .context = target,
                });
            }
            return routeFromContext(target);
        }

        if (existing) |doc| {
            if (doc.context == target) {
                try target.handler.changeDocumentFull(document_uri, version, text);
                self.gpa.free(doc.source);
                doc.source = source_copy;
                doc.version = version;
                doc.context_id = target.id;
                return routeFromContext(target);
            }
        }

        // Build and validate in the replacement before releasing anything the
        // old context still owns. A failed insert leaves the old route intact.
        try target.handler.openDocument(document_uri, version, text);

        if (resolved.created) {
            self.contexts.appendAssumeCapacity(target);
            self.contexts_by_id.putAssumeCapacity(target.id, target);
            self.generations.putAssumeCapacity(
                resolved.generation_key.?,
                resolved.next_generation,
            );
        }

        if (existing) |doc| {
            const old_context = doc.context;
            old_context.handler.closeDocument(document_uri);
            self.gpa.free(doc.source);
            doc.source = source_copy;
            doc.version = version;
            doc.context = target;
            doc.context_id = target.id;
            self.removeIfDeclaration(old_context);
        } else {
            self.documents.putAssumeCapacity(key_copy.?, .{
                .uri = key_copy.?,
                .source = source_copy,
                .version = version,
                .context_id = target.id,
                .context = target,
            });
        }
        return routeFromContext(target);
    }

    fn ensureContext(self: *Registry, document_uri: []const u8, text: []const u8) Allocator.Error!ResolvedContext {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();

        const decoded = (try uri.fileUriToPath(a, document_uri)) orelse
            return self.ensurePlain("core", .core, .unconfigured, null, &.{});

        const document_path = try std.fs.path.resolve(a, &.{decoded});

        // A marker file is never ordinary project data, even when it is also
        // the file that would be discovered as its own configuration.
        if (isMarkerFile(document_path)) {
            if (std.fs.path.dirname(document_path)) |dir| try self.rememberMarkerDir(dir);
            return self.ensureSource(document_path, text, a);
        }

        // A retained deleted marker is an error boundary even for a document
        // opened after the deletion: never rediscover a parent configuration.
        if (try self.deletedMarkerFor(document_uri, document_path)) |block| {
            const context = try self.ensureMarkerDeletedContext(block);
            return .{ .context = context, .created = false };
        }

        var selection = try discovery.discover(self.gpa, self.io, self.roots, document_uri);
        defer selection.deinit();
        if (selection.marker_dir) |dir| try self.rememberMarkerDir(dir);
        if (selection.config) |config| try self.rememberConfigPath(config.path);

        if (try self.isKnownSource(document_path, &selection, a)) {
            return self.ensureSource(document_path, text, a);
        }

        switch (selection.state) {
            .unconfigured => {
                if (selection.project_path) |project_path| {
                    const marker_dir = selection.marker_dir orelse
                        std.fs.path.dirname(project_path) orelse ".";
                    const id = try std.fmt.allocPrint(a, "legacy:{s}", .{project_path});
                    if (self.contextById(id)) |existing| {
                        return .{ .context = existing, .created = false };
                    }
                    try self.reserveNewContext();
                    const generation = try self.prepareGeneration(id);
                    const context = try self.createLegacy(
                        id,
                        generation.generation,
                        marker_dir,
                    );
                    return .{
                        .context = context,
                        .created = true,
                        .generation_key = generation.key,
                        .next_generation = generation.next,
                    };
                }
                return self.ensurePlain("core", .core, .unconfigured, null, &.{});
            },
            .ready => {
                const config = &selection.config.?;
                const bundle_index = selection.matching_bundles[0];
                const bundle = &config.bundles[bundle_index];
                const baseline_id = try std.fmt.allocPrint(
                    a,
                    "bundle:{s}:{s}",
                    .{ config.path, bundle.name },
                );
                const baseline = if (self.contextById(baseline_id)) |existing| existing else blk: {
                    try self.reserveNewContext();
                    const generation = try self.prepareGeneration(baseline_id);

                    const config_ptr = try self.gpa.create(editor_config.Config);
                    errdefer self.gpa.destroy(config_ptr);
                    config_ptr.* = selection.config.?;
                    selection.config = null;
                    errdefer config_ptr.deinit();

                    const context = try self.createBundle(
                        baseline_id,
                        generation.generation,
                        config_ptr,
                        bundle_index,
                    );
                    self.contexts.appendAssumeCapacity(context);
                    self.contexts_by_id.putAssumeCapacity(context.id, context);
                    self.generations.putAssumeCapacity(generation.key, generation.next);
                    break :blk context;
                };

                // A selected bundle that failed compilation is the whole
                // document's unavailable context. Declaration preparation
                // must not run against a schema that was never established.
                if (baseline.state != .ready) {
                    return .{ .context = baseline, .created = false };
                }

                return self.resolveDeclarations(
                    baseline,
                    document_path,
                    selection.marker_dir.?,
                    text,
                    a,
                );
            },
            .conflict => {
                const config = &selection.config.?;
                const id = try std.fmt.allocPrint(
                    a,
                    "conflict:{s}:{s}",
                    .{ config.path, document_path },
                );
                if (self.contextById(id)) |existing| {
                    return .{ .context = existing, .created = false };
                }

                try self.reserveNewContext();
                const generation = try self.prepareGeneration(id);

                const descriptions = try a.alloc(ConflictEntry, selection.matching_bundles.len);
                for (selection.matching_bundles, 0..) |bundle_index, i| {
                    descriptions[i] = try describeBundle(config, bundle_index, a);
                }

                const config_ptr = try self.gpa.create(editor_config.Config);
                errdefer self.gpa.destroy(config_ptr);
                config_ptr.* = selection.config.?;
                selection.config = null;
                errdefer config_ptr.deinit();

                const context = try self.createPlain(
                    id,
                    generation.generation,
                    .conflict,
                    .unavailable,
                    config_ptr,
                    descriptions,
                );
                return .{
                    .context = context,
                    .created = true,
                    .generation_key = generation.key,
                    .next_generation = generation.next,
                };
            },
            .config_failure => {
                const config = &selection.config.?;
                const id = try std.fmt.allocPrint(a, "config-failure:{s}", .{config.path});
                if (self.contextById(id)) |existing| {
                    return .{ .context = existing, .created = false };
                }

                try self.reserveNewContext();
                const generation = try self.prepareGeneration(id);

                const config_ptr = try self.gpa.create(editor_config.Config);
                errdefer self.gpa.destroy(config_ptr);
                config_ptr.* = selection.config.?;
                selection.config = null;
                errdefer config_ptr.deinit();

                const context = try self.createPlain(
                    id,
                    generation.generation,
                    .config_failure,
                    .unavailable,
                    config_ptr,
                    &.{},
                );
                return .{
                    .context = context,
                    .created = true,
                    .generation_key = generation.key,
                    .next_generation = generation.next,
                };
            },
        }
    }

    /// Prepare one configured document against the selected bundle's borrowed
    /// preload. Returns `null` when the document has no top-level plugin
    /// directive, in which case the caller shares the baseline context.
    fn prepareDeclarations(
        self: *Registry,
        baseline: *Context,
        marker_dir: []const u8,
        text: []const u8,
        scratch: Allocator,
    ) Allocator.Error!?DeclarationPreparation {
        const compiled = if (baseline.compiled) |*value| value else return null;
        const preloaded = if (compiled.preloaded) |*value| value else return null;

        const source = try scratch.dupeZ(u8, text);
        const project_file = try self.applicableProjectFile(marker_dir, scratch);

        const prepared = try self.gpa.create(Host.PreparedSchema);
        errdefer self.gpa.destroy(prepared);
        prepared.* = try Host.prepareSchema(self.gpa, source, .{
            .preloaded = preloaded,
            .project_root = marker_dir,
            .project_file = project_file,
            .io = self.io,
            // Schema-only by construction: no lowering registry, no runtime,
            // no sidecar reads. Configured declaration contexts never lower.
        });
        errdefer prepared.deinit();

        if (!prepared.has_directives) {
            // The temporary preparation was needed to decide that this
            // document belongs to the shared baseline. Release it before the
            // baseline handler owns the bytes.
            prepared.deinit();
            self.gpa.destroy(prepared);
            return null;
        }

        const dependencies = try self.collectDependencies(prepared, project_file);
        return .{ .prepared = prepared, .dependencies = dependencies };
    }

    fn resolveDeclarations(
        self: *Registry,
        baseline: *Context,
        document_path: []const u8,
        marker_dir: []const u8,
        text: []const u8,
        scratch: Allocator,
    ) Allocator.Error!ResolvedContext {
        var preparation: ?DeclarationPreparation = try self.prepareDeclarations(
            baseline,
            marker_dir,
            text,
            scratch,
        );
        errdefer if (preparation) |*owned| owned.deinit(self.gpa);

        const owned = preparation orelse
            return .{ .context = baseline, .created = false };

        const id = try std.fmt.allocPrint(
            scratch,
            "declaration:{s}:{s}",
            .{ baseline.id, document_path },
        );
        if (self.contextById(id)) |existing| {
            preparation = null;
            return .{ .context = existing, .created = false, .pending = owned };
        }

        try self.reserveNewContext();
        const generation = try self.prepareGeneration(id);
        // `createDeclaration` consumes the preparation and releases it on
        // failure; disarm the outer guard before handing ownership over.
        preparation = null;
        const context = try self.createDeclaration(
            id,
            generation.generation,
            owned,
            baseline,
            marker_dir,
        );
        return .{
            .context = context,
            .created = true,
            .generation_key = generation.key,
            .next_generation = generation.next,
        };
    }

    fn applicableProjectFile(
        self: *Registry,
        marker_dir: []const u8,
        scratch: Allocator,
    ) Allocator.Error!?[]const u8 {
        const path = try std.fs.path.join(
            scratch,
            &.{ marker_dir, discovery.markers.project },
        );
        if (!pathExists(self.io, path)) return null;
        return path;
    }

    /// Saved inputs of one document preparation. Resolved manifest paths are
    /// recorded before their load result is known; the same-directory project
    /// index is a dependency only when a `(use-plugin …)` reference actually
    /// caused it to be read.
    fn collectDependencies(
        self: *Registry,
        prepared: *const Host.PreparedSchema,
        project_file: ?[]const u8,
    ) Allocator.Error![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |path| self.gpa.free(path);
            list.deinit(self.gpa);
        }

        for (prepared.dependencies) |dependency| {
            const copy = try self.gpa.dupe(u8, dependency.source_path);
            list.append(self.gpa, copy) catch |err| {
                self.gpa.free(copy);
                return err;
            };
        }
        if (project_file) |path| {
            if (hasUsePluginRoot(&prepared.tree)) {
                const copy = try self.gpa.dupe(u8, path);
                list.append(self.gpa, copy) catch |err| {
                    self.gpa.free(copy);
                    return err;
                };
            }
        }

        if (list.items.len == 0) {
            list.deinit(self.gpa);
            return &.{};
        }
        return list.toOwnedSlice(self.gpa);
    }

    fn ensurePlain(
        self: *Registry,
        id: []const u8,
        kind: ContextKind,
        state: RouteState,
        config: ?*editor_config.Config,
        conflict_entries: []const ConflictEntry,
    ) Allocator.Error!ResolvedContext {
        if (self.contextById(id)) |existing| {
            return .{ .context = existing, .created = false };
        }
        try self.reserveNewContext();
        const generation = try self.prepareGeneration(id);
        const context = try self.createPlain(
            id,
            generation.generation,
            kind,
            state,
            config,
            conflict_entries,
        );
        return .{
            .context = context,
            .created = true,
            .generation_key = generation.key,
            .next_generation = generation.next,
        };
    }

    fn ensureSource(
        self: *Registry,
        document_path: []const u8,
        text: []const u8,
        scratch: Allocator,
    ) Allocator.Error!ResolvedContext {
        const id = try std.fmt.allocPrint(scratch, "source:{s}", .{document_path});
        if (self.contextById(id)) |existing| {
            return .{ .context = existing, .created = false };
        }
        try self.reserveNewContext();
        const generation = try self.prepareGeneration(id);

        var config_ptr: ?*editor_config.Config = null;
        errdefer if (config_ptr) |config| {
            config.deinit();
            self.gpa.destroy(config);
        };
        if (isConfigMarker(document_path)) {
            const source_z = try scratch.dupeZ(u8, text);
            const config = try self.gpa.create(editor_config.Config);
            errdefer self.gpa.destroy(config);
            config.* = try editor_config.parse(self.gpa, document_path, source_z);
            errdefer config.deinit();
            config_ptr = config;
        }

        const context = try self.createPlain(
            id,
            generation.generation,
            .source,
            .source,
            config_ptr,
            &.{},
        );
        if (context.marker_dir == null) {
            const dir = std.fs.path.dirname(document_path) orelse ".";
            context.marker_dir = try context.arena.allocator().dupe(u8, dir);
        }
        context.source_path = try context.arena.allocator().dupe(u8, document_path);
        return .{
            .context = context,
            .created = true,
            .generation_key = generation.key,
            .next_generation = generation.next,
        };
    }

    fn createPlain(
        self: *Registry,
        id: []const u8,
        generation: u32,
        kind: ContextKind,
        state: RouteState,
        config: ?*editor_config.Config,
        conflict_entries: []const ConflictEntry,
    ) Allocator.Error!*Context {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const id_copy = try a.dupe(u8, id);
        const parse_only = kind == .source or kind == .conflict or kind == .config_failure;

        var handler = Handler.initWithOptions(self.gpa, .{
            .borrowed_schema = if (parse_only) .{ .plugins = &.{} } else null,
            .context_id = id_copy,
            .schema_generation = generation,
            .diagnostic_mode = if (parse_only) .parse_only else .full,
        });
        errdefer handler.deinit();

        const entries = try a.alloc(ConflictEntry, conflict_entries.len);
        for (conflict_entries, 0..) |entry, i| {
            entries[i] = .{
                .message = try a.dupe(u8, entry.message),
                .span = entry.span,
            };
        }

        const context = try self.gpa.create(Context);
        var marker_dir: ?[]const u8 = null;
        var config_path: ?[]const u8 = null;
        var config_uri: ?[]const u8 = null;
        if (config) |owned| {
            marker_dir = try a.dupe(u8, std.fs.path.dirname(owned.path) orelse ".");
            config_path = try a.dupe(u8, owned.path);
            config_uri = try a.dupe(u8, owned.uri);
        }
        context.* = .{
            .arena = arena,
            .id = id_copy,
            .generation = generation,
            .kind = kind,
            .state = state,
            .handler = handler,
            .marker_dir = marker_dir,
            .config_path = config_path,
            .config_uri = config_uri,
            .config = config,
            .conflict_entries = entries,
        };
        return context;
    }

    fn createLegacy(
        self: *Registry,
        id: []const u8,
        generation: u32,
        marker_dir: []const u8,
    ) Allocator.Error!*Context {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const id_copy = try a.dupe(u8, id);
        // Legacy project handlers keep the compatibility result-id shape
        // (`version:generation`); the registry still keys their context by
        // project identity, but the wire string stays byte-identical to
        // what pre-bundle clients already hold.
        var handler = Handler.initWithOptions(self.gpa, .{
            .schema_generation = generation,
        });
        errdefer handler.deinit();
        try handler.loadProject(self.io, marker_dir);
        const project_root = try a.dupe(u8, marker_dir);
        const project_path = try std.fs.path.join(a, &.{ marker_dir, discovery.markers.project });
        const project_uri = try uri.pathToFileUri(a, project_path);

        const context = try self.gpa.create(Context);
        context.* = .{
            .arena = arena,
            .id = id_copy,
            .generation = generation,
            .kind = .legacy,
            .state = .unconfigured,
            .handler = handler,
            .marker_dir = project_root,
            .config_path = project_path,
            .config_uri = project_uri,
            .project_root = project_root,
        };
        return context;
    }

    fn createBundle(
        self: *Registry,
        id: []const u8,
        generation: u32,
        config: *editor_config.Config,
        bundle_index: usize,
    ) Allocator.Error!*Context {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const id_copy = try a.dupe(u8, id);
        var compiled = try schema_bundle.Compiled.load(
            self.gpa,
            self.io,
            id_copy,
            config,
            bundle_index,
        );
        errdefer compiled.deinit();

        const ready = compiled.state == .ready;
        var handler = Handler.initWithOptions(self.gpa, .{
            .borrowed_schema = if (ready) compiled.schema else .{ .plugins = &.{} },
            .context_id = id_copy,
            .schema_generation = generation,
            .diagnostic_mode = if (ready) .full else .parse_only,
        });
        errdefer handler.deinit();

        const marker_dir = std.fs.path.dirname(config.path) orelse ".";
        const marker_copy = try a.dupe(u8, marker_dir);
        const config_path_copy = try a.dupe(u8, config.path);
        const config_uri_copy = try a.dupe(u8, config.uri);

        const context = try self.gpa.create(Context);
        context.* = .{
            .arena = arena,
            .id = id_copy,
            .generation = generation,
            .kind = .bundle,
            .state = if (ready) .ready else .unavailable,
            .handler = handler,
            .marker_dir = marker_copy,
            .config_path = config_path_copy,
            .config_uri = config_uri_copy,
            .config = config,
            .compiled = compiled,
        };
        return context;
    }

    fn createDeclaration(
        self: *Registry,
        id: []const u8,
        generation: u32,
        preparation: DeclarationPreparation,
        baseline: *Context,
        marker_dir: []const u8,
    ) Allocator.Error!*Context {
        var owned = preparation;
        errdefer owned.deinit(self.gpa);

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const id_copy = try a.dupe(u8, id);
        var handler = buildDeclarationHandler(
            self.gpa,
            id_copy,
            generation,
            owned.prepared,
        );
        errdefer handler.deinit();

        const marker_copy = try a.dupe(u8, marker_dir);
        const context = try self.gpa.create(Context);
        context.* = .{
            .arena = arena,
            .id = id_copy,
            .generation = generation,
            .kind = .declaration,
            .state = .ready,
            .handler = handler,
            .marker_dir = marker_copy,
            .baseline = baseline,
            .prepared = owned.prepared,
            .dependencies = owned.dependencies,
        };
        return context;
    }

    /// A declaration context is owned by exactly one document identity. Once
    /// that document moves away or closes, retaining the context would retain
    /// a schema view nobody can reach.
    fn removeIfDeclaration(self: *Registry, context: *Context) void {
        if (context.kind != .declaration) return;
        self.removeContext(context);
    }

    fn removeContext(self: *Registry, context: *Context) void {
        for (self.contexts.items, 0..) |candidate, index| {
            if (candidate == context) {
                _ = self.contexts.swapRemove(index);
                break;
            }
        }
        _ = self.contexts_by_id.remove(context.id);
        destroyContext(self.gpa, context);
    }

    fn contextById(self: *const Registry, id: []const u8) ?*Context {
        return self.contexts_by_id.get(id);
    }

    fn reserveNewContext(self: *Registry) Allocator.Error!void {
        try self.contexts.ensureUnusedCapacity(self.gpa, 1);
        try self.contexts_by_id.ensureUnusedCapacity(self.gpa, 1);
    }

    const PreparedGeneration = struct {
        generation: u32,
        next: u32,
        key: []const u8,
    };

    fn prepareGeneration(self: *Registry, id: []const u8) Allocator.Error!PreparedGeneration {
        const gop = try self.generations.getOrPut(self.gpa, id);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.meta_arena.allocator().dupe(u8, id);
            gop.value_ptr.* = 0;
        }
        const generation = gop.value_ptr.*;
        gop.value_ptr.* = generation +% 1;
        return .{
            .generation = generation,
            .next = generation +% 1,
            .key = gop.key_ptr.*,
        };
    }

    fn isKnownSource(
        self: *Registry,
        document_path: []const u8,
        selection: *const discovery.Selection,
        scratch: Allocator,
    ) Allocator.Error!bool {
        if (selection.config) |*config| {
            return configContainsSource(config, document_path);
        }
        const marker_dir = selection.marker_dir orelse return false;
        const config_path = try std.fs.path.join(scratch, &.{ marker_dir, discovery.markers.config });
        if (!pathExists(self.io, config_path)) return false;

        var config = try editor_config.load(self.gpa, self.io, config_path);
        defer config.deinit();
        return configContainsSource(&config, document_path);
    }
};

const MarkerKind = enum { config, project };

const MarkerBlock = struct {
    path: []const u8,
    dir: []const u8,
    uri: []const u8,
    kind: MarkerKind,
};

fn markerKind(path: []const u8) ?MarkerKind {
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, discovery.markers.config)) return .config;
    if (std.mem.eql(u8, base, discovery.markers.project)) return .project;
    return null;
}

fn pathContains(base: []const u8, path: []const u8) bool {
    if (path.len < base.len) return false;
    if (!std.mem.startsWith(u8, path, base)) return false;
    if (path.len == base.len) return true;
    if (base.len != 0 and base[base.len - 1] == std.fs.path.sep) return true;
    return path[base.len] == std.fs.path.sep;
}

fn contextAffected(context: *const Context, changes: []const NormalizedChange) bool {
    for (changes) |change| {
        if (context.config_path) |config_path| {
            if (std.mem.eql(u8, config_path, change.path)) return true;
        }
        if (context.source_path) |source_path| {
            if (std.mem.eql(u8, source_path, change.path)) return true;
        }
        if (markerKind(change.path) != null) {
            if (context.marker_dir) |marker_dir| {
                const changed_dir = std.fs.path.dirname(change.path);
                if (changed_dir) |dir| {
                    if (std.mem.eql(u8, marker_dir, dir)) return true;
                }
            }
        }
        if (context.compiled) |*compiled| {
            for (compiled.sources) |source| {
                if (std.mem.eql(u8, source.path, change.path)) return true;
            }
        }
        for (context.dependencies) |dependency| {
            if (std.mem.eql(u8, dependency, change.path)) return true;
        }
    }
    return false;
}

fn blockedMarkerForDocument(
    old: *const Registry,
    replacement: *const Registry,
    document_uri: []const u8,
    document_path: []const u8,
) ?MarkerBlock {
    var best: ?MarkerBlock = null;
    for (replacement.deleted_markers.items) |block| {
        if (!pathContains(block.dir, document_path)) continue;
        if (best) |current| {
            if (block.dir.len <= current.dir.len) continue;
        }
        best = block;
    }
    const block = best orelse return null;

    var selection = discovery.discover(old.gpa, old.io, replacement.roots, document_uri) catch
        return block;
    defer selection.deinit();
    if (selection.marker_dir) |marker_dir| {
        if (!std.mem.eql(u8, marker_dir, block.dir) and pathContains(block.dir, marker_dir)) {
            // A still-existing marker below the deleted one is the nearer
            // boundary; deletion of an outer marker does not affect it.
            return null;
        }
    }
    return block;
}

/// Append `value` unless an equal URI is already present. The stored string
/// is copied into `arena`: `collectContextUris` receives storage owned by a
/// registry the caller destroys before reading the set back, so the list
/// must own every byte it returns, not borrow the passed-in slices.
fn appendUniqueString(
    arena: Allocator,
    list: *std.ArrayList([]const u8),
    value: []const u8,
) Allocator.Error!void {
    for (list.items) |existing| {
        if (uri.HashContext.eql(.{}, existing, value)) return;
    }
    try list.append(arena, try arena.dupe(u8, value));
}

fn handlerSeverity(severity: Ast.Diagnostic.Severity) Handler.Severity {
    return switch (severity) {
        .err => .err,
        .warning => .warning,
    };
}

fn sameHandlerDiagnostic(a: Handler.Diagnostic, b: Handler.Diagnostic) bool {
    return a.span_start == b.span_start and
        a.span_end == b.span_end and
        a.severity == b.severity and
        std.mem.eql(u8, a.code, b.code) and
        std.mem.eql(u8, a.message, b.message);
}

fn appendUniqueHandlerDiagnostic(
    list: *std.ArrayList(Handler.Diagnostic),
    arena: Allocator,
    diagnostic: Handler.Diagnostic,
) Allocator.Error!void {
    for (list.items) |existing| {
        if (sameHandlerDiagnostic(existing, diagnostic)) return;
    }
    try list.append(arena, diagnostic);
}

fn hostDiagnostics(
    arena: Allocator,
    diagnostics: []const Host.HostDiagnostic,
) Allocator.Error![]const Handler.Diagnostic {
    const out = try arena.alloc(Handler.Diagnostic, diagnostics.len);
    for (diagnostics, out) |diagnostic, *slot| {
        slot.* = .{
            .span_start = diagnostic.span.start,
            .span_end = diagnostic.span.end,
            .severity = handlerSeverity(diagnostic.severity),
            .code = @tagName(diagnostic.code),
            .message = diagnostic.message,
            .code_href = Handler.codeHref(diagnostic.code),
        };
    }
    return out;
}

fn astDiagnostic(diagnostic: Ast.Diagnostic) Handler.Diagnostic {
    return .{
        .span_start = diagnostic.span.start,
        .span_end = diagnostic.span.end,
        .severity = handlerSeverity(diagnostic.severity),
        .code = @tagName(diagnostic.code),
        .message = diagnostic.message,
        .code_href = Handler.codeHref(diagnostic.code),
    };
}

fn appendConfigDiagnostic(
    arena: Allocator,
    list: *std.ArrayList(Handler.Diagnostic),
    config_uri: []const u8,
    diagnostic: editor_config.Diagnostic,
) Allocator.Error!void {
    const related = try arena.alloc(Handler.Diagnostic.Related, diagnostic.related.len);
    for (diagnostic.related, related) |source, *slot| {
        slot.* = .{
            .uri = config_uri,
            .span_start = source.span.start,
            .span_end = source.span.end,
            .message = source.message,
        };
    }
    try appendUniqueHandlerDiagnostic(list, arena, .{
        .span_start = diagnostic.span.start,
        .span_end = diagnostic.span.end,
        .severity = .err,
        .code = diagnostic.code,
        .message = diagnostic.message,
        .related = related,
        // Editor-local identifiers have no `sjon explain` page.
        .code_href = "",
    });
}

fn configReportDiagnostics(
    arena: Allocator,
    config_uri: []const u8,
    report: schema_bundle.ConfigReport,
) Allocator.Error![]const Handler.Diagnostic {
    const related = try arena.alloc(Handler.Diagnostic.Related, report.related.len);
    for (report.related, related) |source, *slot| {
        slot.* = .{
            .uri = source.uri orelse config_uri,
            .span_start = source.span.start,
            .span_end = source.span.end,
            .message = source.message,
        };
    }
    const out = try arena.alloc(Handler.Diagnostic, 1);
    out[0] = .{
        .span_start = report.span.start,
        .span_end = report.span.end,
        .severity = handlerSeverity(report.severity),
        .code = report.code,
        .message = report.message,
        .related = related,
        .code_href = "",
    };
    return out;
}

fn appendSourceDiagnostics(
    arena: Allocator,
    list: *std.ArrayList(SourceAccumulator),
    source_uri: []const u8,
    source: []const u8,
    diagnostics: []const Handler.Diagnostic,
) Allocator.Error!void {
    var index: ?usize = null;
    for (list.items, 0..) |entry, i| {
        if (uri.HashContext.eql(.{}, entry.uri, source_uri)) {
            index = i;
            break;
        }
    }
    if (index == null) {
        try list.append(arena, .{
            .uri = source_uri,
            .source = source,
            .diagnostics = .empty,
        });
        index = list.items.len - 1;
    }
    const entry = &list.items[index.?];
    for (diagnostics) |diagnostic| {
        try appendUniqueHandlerDiagnostic(&entry.diagnostics, arena, diagnostic);
    }
}

/// One context's share of a workspace ingestion. Files stay in the global
/// URI order they arrived in, and `new_count` counts only never-before-held
/// documents so the per-handler cap can be derived from held + admitted.
const WorkspaceGroup = struct {
    context: *Context,
    files: std.ArrayList(Handler.WorkspaceFile),
    new_count: usize,
};

fn findOrAddGroup(
    groups: *std.ArrayList(WorkspaceGroup),
    arena: Allocator,
    context: *Context,
) Allocator.Error!usize {
    for (groups.items, 0..) |group, index| {
        if (group.context == context) return index;
    }
    try groups.append(arena, .{
        .context = context,
        .files = .empty,
        .new_count = 0,
    });
    return groups.items.len - 1;
}

/// Never-open documents a handler already holds. Open documents have a
/// client version; workspace-ingested ones deliberately have none, which
/// is exactly the existing `WorkspaceReport` distinction.
fn workspaceHeldCount(
    handler: *const Handler,
    arena: Allocator,
) Allocator.Error!usize {
    const reports = try handler.getWorkspaceDiagnostics(arena);
    var held: usize = 0;
    for (reports) |report| {
        if (report.version == null) held += 1;
    }
    return held;
}

fn routeFromContext(context: *Context) Route {
    return .{
        .state = context.state,
        .context_id = context.id,
        .handler = &context.handler,
    };
}

fn buildDeclarationHandler(
    gpa: Allocator,
    id: []const u8,
    generation: u32,
    prepared: *const Host.PreparedSchema,
) Handler {
    return Handler.initWithOptions(gpa, .{
        .borrowed_schema = prepared.validation_schema,
        .context_id = id,
        .schema_generation = generation,
        .prepared_schema = prepared,
        .diagnostic_mode = .full,
    });
}

fn destroyContext(gpa: Allocator, context: *Context) void {
    // Handler first: its documents borrow the schema and preparation the
    // owners below still hold. Only then may the preparation and the baseline
    // schema owner die.
    context.handler.deinit();
    if (context.prepared) |prepared| {
        prepared.deinit();
        gpa.destroy(prepared);
    }
    if (context.compiled) |*compiled| compiled.deinit();
    if (context.config) |config| {
        config.deinit();
        gpa.destroy(config);
    }
    freeDependencies(gpa, context.dependencies);
    context.arena.deinit();
    gpa.destroy(context);
}

fn freeDependencies(gpa: Allocator, dependencies: []const []const u8) void {
    if (dependencies.len == 0) return;
    for (dependencies) |path| gpa.free(path);
    gpa.free(dependencies);
}

/// True when a document root is an unqualified `(use-plugin …)` reference.
/// `PreparedSchema` exposes `has_directives` but not which kind, and only a
/// reference causes the same-directory project index to be read.
fn hasUsePluginRoot(tree: *const Ast.Tree) bool {
    for (tree.root) |index| {
        if (!Host.isPluginDirectiveRoot(tree, index)) continue;
        if (std.mem.eql(u8, tree.formHeader(index).head, "use-plugin")) return true;
    }
    return false;
}

fn isMarkerFile(path: []const u8) bool {
    return isConfigMarker(path) or
        std.mem.eql(u8, std.fs.path.basename(path), discovery.markers.project);
}

fn isConfigMarker(path: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(path), discovery.markers.config);
}

fn configContainsSource(config: *const editor_config.Config, document_path: []const u8) bool {
    if (std.mem.eql(u8, config.path, document_path)) return true;
    for (config.bundles) |bundle| {
        for (bundle.manifests) |manifest| {
            if (std.mem.eql(u8, manifest.path, document_path)) return true;
        }
    }
    return false;
}

fn describeBundle(
    config: *const editor_config.Config,
    bundle_index: usize,
    arena: Allocator,
) Allocator.Error!ConflictEntry {
    const bundle = &config.bundles[bundle_index];
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "bundle `");
    try out.appendSlice(arena, bundle.name);
    try out.appendSlice(arena, "` (patterns: ");
    for (bundle.patterns, 0..) |pattern, i| {
        if (i != 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, "`");
        try out.appendSlice(arena, pattern.source);
        try out.appendSlice(arena, "`");
    }
    try out.append(arena, ')');
    return .{ .message = try out.toOwnedSlice(arena), .span = bundle.span };
}

fn pathExists(io: Io, absolute_path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, absolute_path, .{}) catch return false;
    return true;
}

fn sentinelDupe(gpa: Allocator, text: []const u8) Allocator.Error![:0]u8 {
    const out = try gpa.allocSentinel(u8, text.len, 0);
    @memcpy(out, text);
    return out;
}

fn editorDiagnosticsFor(
    registry: *const Registry,
    arena: Allocator,
    document_uri: []const u8,
    context: *const Context,
) Allocator.Error![]const EditorDiagnostic {
    _ = registry;
    return switch (context.kind) {
        .core, .legacy, .declaration => &.{},
        .source => sourceDiagnostics(arena, context),
        .bundle => bundleDiagnostics(arena, document_uri, context),
        .conflict => conflictDiagnostics(arena, document_uri, context),
        .config_failure => configFailureDiagnostics(arena, document_uri, context),
        .marker_deleted => markerDeletedDiagnostics(arena, document_uri, context),
    };
}

fn sourceDiagnostics(
    arena: Allocator,
    context: *const Context,
) Allocator.Error![]const EditorDiagnostic {
    const config = context.config orelse return &.{};
    const out = try arena.alloc(EditorDiagnostic, config.diagnostics.len);
    for (config.diagnostics, 0..) |diagnostic, i| {
        out[i] = .{
            .code = diagnostic.code,
            .severity = .err,
            .message = diagnostic.message,
            .uri = config.uri,
            .span = diagnostic.span,
            .related = try relatedFromConfig(arena, config.uri, diagnostic.related),
        };
    }
    return out;
}

fn bundleDiagnostics(
    arena: Allocator,
    document_uri: []const u8,
    context: *const Context,
) Allocator.Error![]const EditorDiagnostic {
    if (context.state != .unavailable) return &.{};
    const config = context.config orelse return &.{};
    const compiled = if (context.compiled) |*value| value else return &.{};
    const bundle = &config.bundles[compiled.bundle_index];
    const reports = compiled.config_reports;

    const related = try arena.alloc(EditorRelated, reports.len);
    for (reports, 0..) |report, i| {
        related[i] = .{
            .message = report.message,
            .uri = config.uri,
            .span = report.span,
        };
    }

    const out = try arena.alloc(EditorDiagnostic, 1);
    out[0] = .{
        .code = codes.bundle_unavailable,
        .severity = .err,
        .message = try std.fmt.allocPrint(
            arena,
            "editor schema bundle `{s}` is unavailable; schema-dependent results are suppressed",
            .{bundle.name},
        ),
        .uri = document_uri,
        .span = .{ .start = 0, .end = 0 },
        .related = related,
    };
    return out;
}

fn conflictDiagnostics(
    arena: Allocator,
    document_uri: []const u8,
    context: *const Context,
) Allocator.Error![]const EditorDiagnostic {
    const config = context.config orelse return &.{};
    const related = try arena.alloc(EditorRelated, context.conflict_entries.len);
    for (context.conflict_entries, 0..) |entry, i| {
        related[i] = .{
            .message = entry.message,
            .uri = config.uri,
            .span = entry.span,
        };
    }

    const out = try arena.alloc(EditorDiagnostic, 1);
    out[0] = .{
        .code = codes.bundle_conflict,
        .severity = .err,
        .message = "document matches multiple editor schema bundles; schema-dependent results are suppressed",
        .uri = document_uri,
        .span = .{ .start = 0, .end = 0 },
        .related = related,
    };
    return out;
}

fn configFailureDiagnostics(
    arena: Allocator,
    document_uri: []const u8,
    context: *const Context,
) Allocator.Error![]const EditorDiagnostic {
    const config = context.config orelse return &.{};
    const related_count = config.diagnostics.len + config.parse_diagnostics.len;
    const related = try arena.alloc(EditorRelated, related_count);
    var next: usize = 0;
    for (config.diagnostics) |diagnostic| {
        related[next] = .{
            .message = diagnostic.message,
            .uri = config.uri,
            .span = diagnostic.span,
        };
        next += 1;
    }
    for (config.parse_diagnostics) |diagnostic| {
        related[next] = .{
            .message = diagnostic.message,
            .uri = config.uri,
            .span = diagnostic.span,
        };
        next += 1;
    }

    const out = try arena.alloc(EditorDiagnostic, 1);
    out[0] = .{
        .code = codes.bundle_unavailable,
        .severity = .err,
        .message = try std.fmt.allocPrint(
            arena,
            "editor configuration `{s}` is invalid; schema-dependent results are suppressed",
            .{config.path},
        ),
        .uri = document_uri,
        .span = .{ .start = 0, .end = 0 },
        .related = related,
    };
    return out;
}

fn markerDeletedDiagnostics(
    arena: Allocator,
    document_uri: []const u8,
    context: *const Context,
) Allocator.Error![]const EditorDiagnostic {
    const marker_uri = context.marker_uri orelse return &.{};
    const related = try arena.alloc(EditorRelated, 1);
    related[0] = .{
        .message = "deleted editor schema marker",
        .uri = marker_uri,
        .span = .{ .start = 0, .end = 0 },
    };

    const out = try arena.alloc(EditorDiagnostic, 1);
    out[0] = .{
        .code = codes.marker_deleted,
        .severity = .err,
        .message = "the selected editor schema marker was deleted; schema-dependent results are suppressed until it is recreated or the server restarts",
        .uri = document_uri,
        .span = .{ .start = 0, .end = 0 },
        .related = related,
    };
    return out;
}

fn relatedFromConfig(
    arena: Allocator,
    config_uri: []const u8,
    related: []const editor_config.Related,
) Allocator.Error![]const EditorRelated {
    const out = try arena.alloc(EditorRelated, related.len);
    for (related, 0..) |entry, i| {
        out[i] = .{
            .message = entry.message,
            .uri = config_uri,
            .span = entry.span,
        };
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests — written before the implementation.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn writePlugin(
    fixture: *Fixture,
    sub_path: []const u8,
    name: []const u8,
    form: []const u8,
) !void {
    const source = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "(plugin :name {s} :version \"1.0.0\" (form :name {s} :open true))",
        .{ name, form },
        0,
    );
    defer testing.allocator.free(source);
    try fixture.write(sub_path, source);
}

/// A plugin declaring a `phrase` form whose `:name` is a cross-ref symbol.
/// Workspace-symbol and reference tests need a real cross-ref index entry;
/// a form head alone is not a globally addressable definition.
fn writeCrossRefPlugin(
    fixture: *Fixture,
    sub_path: []const u8,
    name: []const u8,
) !void {
    const source = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "(plugin :name {s} :version \"1.0.0\"\n" ++
            "  (value-kind :name phrase-name :underlying symbol :cross-ref (cross-ref :target phrase))\n" ++
            "  (form :name phrase (key :name name :type symbol :optional false)))\n",
        .{name},
        0,
    );
    defer testing.allocator.free(source);
    try fixture.write(sub_path, source);
}

/// The two-bundle workspace used by the shared-budget and merge tests:
/// `alpha/**` and `beta/**` select independent baseline contexts.
fn writeTwoBundleConfig(fixture: *Fixture) !void {
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name alpha :files [\"alpha/**\"] :manifests [\"alpha.sjon\"])" ++
            "(bundle :name beta :files [\"beta/**\"] :manifests [\"beta.sjon\"])" ++
            "])",
    );
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    dir: []const u8,

    fn init() !Fixture {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        const tmp = testing.tmpDir(.{});
        const sub: []const u8 = &tmp.sub_path;
        const relative = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", sub });
        const dir = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, relative, arena.allocator());
        return .{ .tmp = tmp, .arena = arena, .dir = dir };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        self.arena.deinit();
        self.* = undefined;
    }

    fn write(self: *Fixture, sub_path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub_path)) |parent| {
            try self.tmp.dir.createDirPath(testing.io, parent);
        }
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }

    fn remove(self: *Fixture, sub_path: []const u8) !void {
        try self.tmp.dir.deleteFile(testing.io, sub_path);
    }

    fn path(self: *Fixture, relative: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.dir, relative });
    }

    fn fileUri(self: *Fixture, relative: []const u8) ![]const u8 {
        return uri.pathToFileUri(self.arena.allocator(), try self.path(relative));
    }

    fn rootUri(self: *Fixture) ![]const u8 {
        return uri.pathToFileUri(self.arena.allocator(), self.dir);
    }

    fn registry(self: *Fixture) !Registry {
        var roots = try discovery.initializationRoots(
            testing.allocator,
            &.{try self.rootUri()},
            null,
            null,
        );
        defer roots.deinit();
        var reg = Registry.init(testing.allocator, testing.io);
        errdefer reg.deinit();
        try reg.configureRoots(roots.items);
        return reg;
    }
};

test "registry: two bundles keep open documents in separate handlers" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "alpha.sjon", "alpha", "alpha-form");
    try writePlugin(&fixture, "beta.sjon", "beta", "beta-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name alpha :files [\"alpha/**\"] :manifests [\"alpha.sjon\"])" ++
            "(bundle :name beta :files [\"beta/**\"] :manifests [\"beta.sjon\"])" ++
            "])",
    );
    try fixture.write("alpha/doc.sjon", "(alpha-form)\n");
    try fixture.write("beta/doc.sjon", "(beta-form)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const alpha_uri = try fixture.fileUri("alpha/doc.sjon");
    const beta_uri = try fixture.fileUri("beta/doc.sjon");
    const alpha = try registry.openDocument(alpha_uri, 1, "(alpha-form)\n");
    const beta = try registry.openDocument(beta_uri, 1, "(beta-form)\n");

    try testing.expectEqual(RouteState.ready, alpha.state);
    try testing.expectEqual(RouteState.ready, beta.state);
    try testing.expect(alpha.handler != beta.handler);
    try testing.expect(!std.mem.eql(u8, alpha.context_id, beta.context_id));

    try testing.expect(alpha.handler.getDocument(alpha_uri) != null);
    try testing.expect(alpha.handler.getDocument(beta_uri) == null);
    try testing.expect(beta.handler.getDocument(beta_uri) != null);
    try testing.expect(beta.handler.getDocument(alpha_uri) == null);

    try testing.expectEqual(@as(usize, 2), alpha.handler.schema.plugins.len);
    try testing.expectEqualStrings("alpha", alpha.handler.schema.plugins[1].name);
    try testing.expectEqual(@as(usize, 2), beta.handler.schema.plugins.len);
    try testing.expectEqualStrings("beta", beta.handler.schema.plugins[1].name);
}

test "registry: unmatched document uses applicable legacy project" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "legacy.sjon", "legacy", "legacy-form");
    try fixture.write("sjon-project.sjon", "(project :plugins [\"legacy.sjon\"])");
    try fixture.write("doc.sjon", "(legacy-form)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("doc.sjon");
    const route = try registry.openDocument(document_uri, 1, "(legacy-form)\n");

    try testing.expectEqual(RouteState.unconfigured, route.state);
    try testing.expect(route.handler.getProjectInfo() != null);
    const project = route.handler.getProjectInfo().?;
    try testing.expect(project.project_uri != null);
    try testing.expect(std.mem.endsWith(u8, project.project_uri.?, "/sjon-project.sjon"));
    try testing.expectEqual(@as(usize, 2), route.handler.schema.plugins.len);
    try testing.expectEqualStrings("legacy", route.handler.schema.plugins[1].name);
}

test "registry: root file with no marker uses unconfigured core" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.write("doc.sjon", "(anything)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("doc.sjon");
    const route = try registry.openDocument(document_uri, 1, "(anything)\n");

    try testing.expectEqual(RouteState.unconfigured, route.state);
    try testing.expect(route.handler.getProjectInfo() == null);
    try testing.expectEqual(@as(usize, 1), route.handler.schema.plugins.len);
    try testing.expectEqualStrings("core", route.handler.schema.plugins[0].name);
    try testing.expect(route.handler.getDocument(document_uri) != null);
}

test "registry: selected failed bundle is unavailable and never falls back" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    // A valid legacy project that would serve the document if the registry
    // ever fell back. The selected editor bundle must win and fail instead.
    try writePlugin(&fixture, "fallback.sjon", "fallback", "fallback-form");
    try fixture.write("sjon-project.sjon", "(project :plugins [\"fallback.sjon\"])");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name broken :files [\"doc.sjon\"] :manifests [\"missing.sjon\"])" ++
            "])",
    );
    try fixture.write("doc.sjon", "(fallback-form)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("doc.sjon");
    const route = try registry.openDocument(document_uri, 1, "(fallback-form)\n");

    try testing.expectEqual(RouteState.unavailable, route.state);
    try testing.expect(route.handler.getProjectInfo() == null);
    try testing.expectEqual(@as(usize, 0), route.handler.schema.plugins.len);
    try testing.expect(route.handler.getDocument(document_uri) != null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const diagnostics = try registry.editorDiagnostics(arena.allocator(), document_uri);
    try testing.expect(diagnostics.len >= 1);
    try testing.expectEqualStrings(codes.bundle_unavailable, diagnostics[0].code);
    try testing.expectEqualStrings(document_uri, diagnostics[0].uri);
    try testing.expect(diagnostics[0].related.len >= 1);
    try testing.expect(std.mem.endsWith(u8, diagnostics[0].related[0].uri, "/sjon-lsp.sjon"));
}

test "registry: unavailable retains parse diagnostics and suppresses schema results" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name broken :files [\"**/*.sjon\"] :manifests [\"missing.sjon\"])" ++
            "])",
    );
    const valid_source = "(unknown-form :key 1)\n";
    const invalid_source = "(plugin :name broken\n";
    try fixture.write("valid.sjon", valid_source);
    try fixture.write("invalid.sjon", invalid_source);

    var registry = try fixture.registry();
    defer registry.deinit();

    const valid_uri = try fixture.fileUri("valid.sjon");
    const invalid_uri = try fixture.fileUri("invalid.sjon");
    const valid = try registry.openDocument(valid_uri, 1, valid_source);
    const invalid = try registry.openDocument(invalid_uri, 1, invalid_source);

    try testing.expectEqual(RouteState.unavailable, valid.state);
    try testing.expectEqual(RouteState.unavailable, invalid.state);
    try testing.expectEqual(Handler.DiagnosticMode.parse_only, valid.handler.diagnostic_mode);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // A document that would have a schema diagnostic under any loaded schema
    // reports nothing: the unavailable context may not validate.
    const valid_diagnostics = (try valid.handler.getDiagnostics(arena.allocator(), valid_uri)).?;
    try testing.expectEqual(@as(usize, 0), valid_diagnostics.len);

    // The current buffer still parses, so its own syntax error survives.
    const invalid_diagnostics = (try invalid.handler.getDiagnostics(arena.allocator(), invalid_uri)).?;
    try testing.expect(invalid_diagnostics.len >= 1);
    const invalid_doc = invalid.handler.getDocument(invalid_uri).?;
    try testing.expect(invalid_doc.tree.hasErrors());
    try testing.expectEqual(
        invalid_doc.tree.diagnostics.len,
        invalid_diagnostics.len,
    );
}

test "registry: parse-only route still formats and folds" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name broken :files [\"doc.sjon\"] :manifests [\"missing.sjon\"])" ++
            "])",
    );
    const source = "(thing [1 2])\n";
    try fixture.write("doc.sjon", source);

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("doc.sjon");
    const route = try registry.openDocument(document_uri, 1, source);
    try testing.expectEqual(RouteState.unavailable, route.state);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const edits = (try route.handler.getFormatEdits(arena.allocator(), document_uri)).?;
    try testing.expectEqual(@as(usize, 1), edits.len);
    try testing.expectEqualStrings("(thing [1 2])\n", edits[0].new_text);

    const folds = (try route.handler.getFoldingRanges(arena.allocator(), document_uri)).?;
    try testing.expect(folds.len >= 2); // the root form and the vector

    const symbols = (try route.handler.getDocumentSymbols(arena.allocator(), document_uri)).?;
    try testing.expectEqual(@as(usize, 1), symbols.len);
    try testing.expectEqualStrings("thing", symbols[0].name);
}

test "registry: non-file URI uses in-memory behavior" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = "inmemory://schema/0.sjon";
    const source = "(memory-form)\n";
    const route = try registry.openDocument(document_uri, 1, source);

    try testing.expectEqual(RouteState.unconfigured, route.state);
    try testing.expect(route.context_id.len != 0);
    try testing.expect(route.handler.getProjectInfo() == null);
    try testing.expect(route.handler.getDocument(document_uri) != null);
    try testing.expectEqual(@as(usize, 1), route.handler.schema.plugins.len);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const edits = (try route.handler.getFormatEdits(arena.allocator(), document_uri)).?;
    try testing.expectEqualStrings(source, edits[0].new_text);
    const folds = (try route.handler.getFoldingRanges(arena.allocator(), document_uri)).?;
    try testing.expectEqual(@as(usize, 1), folds.len);
}

test "registry: moving a document preserves unsaved source and changes result identity" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "outer.sjon", "outer", "outer-form");
    try writePlugin(&fixture, "nested/inner.sjon", "inner", "inner-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name outer :files [\"**/*.sjon\"] :manifests [\"outer.sjon\"])" ++
            "])",
    );
    try fixture.write("nested/doc.sjon", "(outer-form)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("nested/doc.sjon");
    const unsaved = "(outer-form) ; unsaved buffer\n";
    const before = try registry.openDocument(document_uri, 1, unsaved);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const before_doc = before.handler.getDocument(document_uri).?;
    const before_id = try before.handler.diagnosticResultId(arena.allocator(), before_doc);
    const before_context = try arena.allocator().dupe(u8, before.context_id);

    // A nearer marker moves the document to a different bundle without any
    // saved copy of the unsaved buffer.
    try fixture.write(
        "nested/sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name inner :files [\"**/*.sjon\"] :manifests [\"inner.sjon\"])" ++
            "])",
    );

    const moved = try registry.changeDocumentFull(document_uri, 1, unsaved);
    try testing.expectEqual(RouteState.ready, moved.state);
    try testing.expect(moved.handler != before.handler);
    try testing.expect(!std.mem.eql(u8, before_context, moved.context_id));

    const moved_doc = moved.handler.getDocument(document_uri).?;
    try testing.expectEqualStrings(unsaved, moved_doc.source);
    try testing.expect(before.handler.getDocument(document_uri) == null);
    try testing.expectEqualStrings("inner", moved.handler.schema.plugins[1].name);

    const after_id = try moved.handler.diagnosticResultId(arena.allocator(), moved_doc);
    try testing.expect(!std.mem.eql(u8, before_id, after_id));
}

test "registry: config and known sources are not ordinary data" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "schemas/main.sjon", "main", "main-form");
    const config_source = "(sjon-lsp :version 1 :bundles [" ++
        "(bundle :name main :files [\"docs/**\"] :manifests [\"schemas/main.sjon\"])" ++
        "])";
    try fixture.write("sjon-lsp.sjon", config_source);
    try fixture.write("docs/doc.sjon", "(main-form)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const doc_uri = try fixture.fileUri("docs/doc.sjon");
    const regular = try registry.openDocument(doc_uri, 1, "(main-form)\n");
    try testing.expectEqual(RouteState.ready, regular.state);

    const config_uri = try fixture.fileUri("sjon-lsp.sjon");
    const config_route = try registry.openDocument(config_uri, 1, config_source);
    try testing.expectEqual(RouteState.source, config_route.state);
    try testing.expectEqual(Handler.DiagnosticMode.parse_only, config_route.handler.diagnostic_mode);
    try testing.expect(config_route.handler != regular.handler);
    try testing.expect(config_route.handler.getDocument(config_uri) != null);
    try testing.expect(regular.handler.getDocument(config_uri) == null);

    const manifest_uri = try fixture.fileUri("schemas/main.sjon");
    const manifest = "(plugin :name main :version \"1.0.0\" (form :name main-form :open true))\n";
    const manifest_route = try registry.openDocument(manifest_uri, 1, manifest);
    try testing.expectEqual(RouteState.source, manifest_route.state);
    try testing.expectEqual(Handler.DiagnosticMode.parse_only, manifest_route.handler.diagnostic_mode);
    try testing.expect(manifest_route.handler != regular.handler);
    try testing.expect(manifest_route.handler.getDocument(manifest_uri) != null);
    try testing.expect(regular.handler.getDocument(manifest_uri) == null);

    // The source route for a configuration carries its typed diagnostics from
    // the current buffer, not the saved bytes.
    const bad_source = "(sjon-lsp :version 1 :version 1 :bundles [])";
    try fixture.write("bad/sjon-lsp.sjon", bad_source);
    const bad_uri = try fixture.fileUri("bad/sjon-lsp.sjon");
    const bad_route = try registry.openDocument(bad_uri, 1, bad_source);
    try testing.expectEqual(RouteState.source, bad_route.state);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const diagnostics = try registry.editorDiagnostics(arena.allocator(), bad_uri);
    var found_duplicate = false;
    for (diagnostics) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, editor_config.codes.config_duplicate_key)) {
            found_duplicate = true;
        }
    }
    try testing.expect(found_duplicate);
}

test "registry: OOM replacement leaves old contexts serving and frees replacements once" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "outer.sjon", "outer", "outer-form");
    try writePlugin(&fixture, "nested/inner.sjon", "inner", "inner-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name outer :files [\"**/*.sjon\"] :manifests [\"outer.sjon\"])" ++
            "])",
    );
    try fixture.write("nested/doc.sjon", "(outer-form)\n");

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var registry = Registry.init(failing.allocator(), testing.io);
    var roots = try discovery.initializationRoots(
        testing.allocator,
        &.{try fixture.rootUri()},
        null,
        null,
    );
    defer roots.deinit();
    try registry.configureRoots(roots.items);

    const document_uri = try fixture.fileUri("nested/doc.sjon");
    const source = "(outer-form)\n";
    const before = try registry.openDocument(document_uri, 1, source);

    try fixture.write(
        "nested/sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name inner :files [\"**/*.sjon\"] :manifests [\"inner.sjon\"])" ++
            "])",
    );

    const start_alloc = failing.alloc_index;
    const start_resize = failing.resize_index;
    var moved = false;
    var offset: usize = 0;
    while (offset < (1 << 20)) {
        failing.fail_index = start_alloc + offset;
        failing.resize_fail_index = start_resize + offset;
        const next_offset: usize = if (offset == 0) 1 else offset * 2;
        if (registry.changeDocumentFull(document_uri, 2, source)) |route| {
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            moved = true;
            try testing.expectEqual(RouteState.ready, route.state);
            try testing.expect(route.handler != before.handler);
            try testing.expectEqualStrings("inner", route.handler.schema.plugins[1].name);
            break;
        } else |err| {
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            try testing.expectEqual(error.OutOfMemory, err);
            const still = registry.route(document_uri).?;
            try testing.expect(still.handler == before.handler);
            try testing.expectEqualStrings(before.context_id, still.context_id);
            try testing.expectEqualStrings(source, still.handler.getDocument(document_uri).?.source);
        }
        offset = next_offset;
    }
    try testing.expect(moved);

    registry.deinit();
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

const FreeRecord = struct { ptr: usize, len: usize };

const OrderAllocator = struct {
    backing: std.mem.Allocator,
    frees: [4096]FreeRecord = undefined,
    count: usize = 0,

    fn allocator(self: *OrderAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *OrderAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *OrderAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *OrderAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *OrderAllocator = @ptrCast(@alignCast(ctx));
        if (self.count < self.frees.len) {
            self.frees[self.count] = .{
                .ptr = @intFromPtr(memory.ptr),
                .len = memory.len,
            };
            self.count += 1;
        }
        self.backing.rawFree(memory, alignment, return_address);
    }

    fn exactFreeIndex(self: *const OrderAllocator, address: usize) ?usize {
        for (self.frees[0..self.count], 0..) |record, i| {
            if (record.ptr == address) return i;
        }
        return null;
    }

    fn containingFreeIndex(self: *const OrderAllocator, address: usize) ?usize {
        for (self.frees[0..self.count], 0..) |record, i| {
            if (address >= record.ptr and address < record.ptr + record.len) return i;
        }
        return null;
    }
};

test "registry: teardown releases document handlers before baseline schema owners" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "main.sjon", "main", "main-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name main :files [\"**/*.sjon\"] :manifests [\"main.sjon\"])" ++
            "])",
    );
    const source = "(main-form)\n";
    try fixture.write("a/doc.sjon", source);
    try fixture.write("b/doc.sjon", source);

    var order = OrderAllocator{ .backing = testing.allocator };
    var registry = Registry.init(order.allocator(), testing.io);
    var roots = try discovery.initializationRoots(
        testing.allocator,
        &.{try fixture.rootUri()},
        null,
        null,
    );
    defer roots.deinit();
    try registry.configureRoots(roots.items);

    const a_uri = try fixture.fileUri("a/doc.sjon");
    const b_uri = try fixture.fileUri("b/doc.sjon");
    const a = try registry.openDocument(a_uri, 1, source);
    const b = try registry.openDocument(b_uri, 1, source);
    try testing.expect(a.handler == b.handler);

    const a_doc = a.handler.getDocument(a_uri).?;
    const b_doc = b.handler.getDocument(b_uri).?;
    const a_source = @intFromPtr(a_doc.source.ptr);
    const b_source = @intFromPtr(b_doc.source.ptr);
    const schema_owner = @intFromPtr(a.handler.schema.plugins.ptr);

    registry.deinit();

    const a_free = order.exactFreeIndex(a_source) orelse return error.MissingDocumentFree;
    const b_free = order.exactFreeIndex(b_source) orelse return error.MissingDocumentFree;
    const schema_free = order.containingFreeIndex(schema_owner) orelse
        return error.MissingSchemaOwnerFree;
    try testing.expect(a_free < schema_free);
    try testing.expect(b_free < schema_free);
}

fn documentDiagnostics(
    route: Route,
    arena: Allocator,
    document_uri: []const u8,
) Allocator.Error![]const Handler.Diagnostic {
    return (try route.handler.getDiagnostics(arena, document_uri)) orelse &.{};
}

fn hasDiagnosticCode(diagnostics: []const Handler.Diagnostic, code: []const u8) bool {
    for (diagnostics) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, code)) return true;
    }
    return false;
}

fn hasPath(paths: []const []const u8, wanted: []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, wanted)) return true;
    }
    return false;
}

fn hasSuffix(paths: []const []const u8, suffix: []const u8) bool {
    for (paths) |path| {
        if (std.mem.endsWith(u8, path, suffix)) return true;
    }
    return false;
}

test "workspace contexts: never-open file cap is shared across contexts" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "alpha.sjon", "alpha", "alpha-form");
    try writePlugin(&fixture, "beta.sjon", "beta", "beta-form");
    try writeTwoBundleConfig(&fixture);
    try fixture.write("alpha/a.sjon", "(alpha-form)\n");
    try fixture.write("beta/b.sjon", "(beta-form)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    // One workspace pull with two roots still has one never-open ceiling.
    // The second context sees the first context's admission as already
    // spent, rather than each handler getting its own 2,048-file allowance.
    const limits: workspace_scan.WorkspaceLimits = .{ .max_files = 1 };

    const alpha = [_]Handler.WorkspaceFile{.{
        .uri = try fixture.fileUri("alpha/a.sjon"),
        .source = "(alpha-form)\n",
    }};
    const first = try registry.ingestWorkspaceFiles(&alpha, limits);
    try testing.expectEqual(@as(usize, 1), first.ingested);
    try testing.expectEqual(@as(usize, 0), first.clipped);

    const beta = [_]Handler.WorkspaceFile{.{
        .uri = try fixture.fileUri("beta/b.sjon"),
        .source = "(beta-form)\n",
    }};
    const second = try registry.ingestWorkspaceFiles(&beta, limits);
    try testing.expectEqual(@as(usize, 0), second.ingested);
    try testing.expectEqual(@as(usize, 1), second.clipped);

    // Re-seeing a file the handler already holds refreshes it without
    // spending new budget; the spent ceiling is not permanent clipping.
    const refreshed = try registry.ingestWorkspaceFiles(&alpha, limits);
    try testing.expectEqual(@as(usize, 1), refreshed.ingested);
    try testing.expectEqual(@as(usize, 0), refreshed.clipped);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const reports = try registry.workspaceReports(arena_state.allocator());
    try testing.expectEqual(@as(usize, 1), reports.len);
    try testing.expect(std.mem.endsWith(u8, reports[0].uri, "/alpha/a.sjon"));
}

test "workspace contexts: global URI order determines clipping" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "base.sjon", "base", "base-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name base :files [\"**/*.sjon\"] :manifests [\"base.sjon\"])" ++
            "])",
    );
    try fixture.write("a.sjon", "(base-form)\n");
    try fixture.write("z.sjon", "(base-form)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const a_uri = try fixture.fileUri("a.sjon");
    const z_uri = try fixture.fileUri("z.sjon");

    // The input deliberately arrives in reverse URI order. Clipping must
    // follow the globally sorted order, not the call order or hash order.
    const files = [_]Handler.WorkspaceFile{
        .{ .uri = z_uri, .source = "(base-form)\n" },
        .{ .uri = a_uri, .source = "(base-form)\n" },
    };
    const ingest = try registry.ingestWorkspaceFiles(&files, .{ .max_files = 1 });
    try testing.expectEqual(@as(usize, 1), ingest.ingested);
    try testing.expectEqual(@as(usize, 1), ingest.clipped);
    try testing.expect(registry.documentFor(a_uri) != null);
    try testing.expect(registry.documentFor(z_uri) == null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const reports = try registry.workspaceReports(arena_state.allocator());
    try testing.expectEqual(@as(usize, 1), reports.len);
    try testing.expect(std.mem.endsWith(u8, reports[0].uri, "/a.sjon"));
}

test "workspace contexts: markers and known non-dotted sources are excluded before cap accounting" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "schemas/main.sjon", "main", "main-form");
    const config = "(sjon-lsp :version 1 :bundles [" ++
        "(bundle :name main :files [\"zz/**\"] :manifests [\"schemas/main.sjon\"])" ++
        "])";
    try fixture.write("sjon-lsp.sjon", config);
    const document = "(main-form)\n";
    try fixture.write("zz/doc.sjon", document);

    var registry = try fixture.registry();
    defer registry.deinit();

    const doc_uri = try fixture.fileUri("zz/doc.sjon");
    const manifest = "(plugin :name main :version \"1.0.0\" (form :name main-form :open true))\n";
    // Both non-dotted sources sort before the only real document. If a
    // source consumed the single admission, the document would be clipped.
    const files = [_]Handler.WorkspaceFile{
        .{ .uri = try fixture.fileUri("schemas/main.sjon"), .source = manifest },
        .{ .uri = try fixture.fileUri("sjon-lsp.sjon"), .source = config },
        .{ .uri = doc_uri, .source = document },
    };
    const ingest = try registry.ingestWorkspaceFiles(&files, .{ .max_files = 1 });
    try testing.expectEqual(@as(usize, 1), ingest.ingested);
    try testing.expectEqual(@as(usize, 0), ingest.clipped);
    try testing.expect(registry.documentFor(doc_uri) != null);
}

test "workspace contexts: open buffers shadow disk during ingestion" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "base.sjon", "base", "base-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name base :files [\"**/*.sjon\"] :manifests [\"base.sjon\"])" ++
            "])",
    );
    const unsaved = "(base-form) ; unsaved buffer\n";
    try fixture.write("doc.sjon", "(base-form) ; disk copy\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("doc.sjon");
    const opened = try registry.openDocument(document_uri, 1, unsaved);
    try testing.expectEqual(RouteState.ready, opened.state);

    // Zero never-open allowance: the open buffer must neither be replaced
    // by the scanned disk copy nor consume the shared file budget.
    const files = [_]Handler.WorkspaceFile{.{
        .uri = document_uri,
        .source = "(base-form) ; disk copy\n",
    }};
    const ingest = try registry.ingestWorkspaceFiles(&files, .{ .max_files = 0 });
    try testing.expectEqual(@as(usize, 0), ingest.ingested);
    try testing.expectEqual(@as(usize, 0), ingest.clipped);

    const route = registry.route(document_uri).?;
    try testing.expectEqualStrings(unsaved, route.handler.getDocument(document_uri).?.source);
}

test "workspace contexts: workspace symbols merge in stable order" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writeCrossRefPlugin(&fixture, "alpha.sjon", "alpha");
    try writeCrossRefPlugin(&fixture, "beta.sjon", "beta");
    try writeTwoBundleConfig(&fixture);
    try fixture.write("alpha/a.sjon", "(phrase :name zed)\n");
    try fixture.write("beta/b.sjon", "(phrase :name alpha)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const alpha_uri = try fixture.fileUri("alpha/a.sjon");
    const beta_uri = try fixture.fileUri("beta/b.sjon");
    // Deliberately create the later-sorting context first: the merge must
    // order by symbol name, not by context creation or hash order.
    const files = [_]Handler.WorkspaceFile{
        .{ .uri = beta_uri, .source = "(phrase :name zed)\n" },
        .{ .uri = alpha_uri, .source = "(phrase :name alpha)\n" },
    };
    _ = try registry.ingestWorkspaceFiles(&files, .{});

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const symbols = try registry.workspaceSymbols(arena_state.allocator(), "");
    try testing.expectEqual(@as(usize, 2), symbols.len);
    try testing.expectEqualStrings("alpha", symbols[0].name);
    try testing.expectEqualStrings(alpha_uri, symbols[0].location.uri);
    try testing.expectEqualStrings("zed", symbols[1].name);
    try testing.expectEqualStrings(beta_uri, symbols[1].location.uri);
}

test "workspace contexts: diagnostics merge in stable order with context-sensitive result IDs" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "alpha.sjon", "alpha", "alpha-form");
    try writePlugin(&fixture, "beta.sjon", "beta", "beta-form");
    try writeTwoBundleConfig(&fixture);
    try fixture.write("alpha/a.sjon", "(unknown-alpha)\n");
    try fixture.write("beta/b.sjon", "(unknown-beta)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const alpha_uri = try fixture.fileUri("alpha/a.sjon");
    const beta_uri = try fixture.fileUri("beta/b.sjon");
    const files = [_]Handler.WorkspaceFile{
        .{ .uri = beta_uri, .source = "(unknown-beta)\n" },
        .{ .uri = alpha_uri, .source = "(unknown-alpha)\n" },
    };
    _ = try registry.ingestWorkspaceFiles(&files, .{});

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const reports = try registry.workspaceReports(arena_state.allocator());
    try testing.expectEqual(@as(usize, 2), reports.len);
    try testing.expectEqualStrings(alpha_uri, reports[0].uri);
    try testing.expectEqualStrings(beta_uri, reports[1].uri);
    for (reports) |report| {
        try testing.expectEqual(@as(?i64, null), report.version);
        try testing.expectEqual(@as(usize, 1), report.diagnostics.len);
        try testing.expectEqualStrings("unknown_form", report.diagnostics[0].code);
        try testing.expect(std.mem.startsWith(u8, report.result_id, "v2:"));
    }
    try testing.expect(std.mem.indexOf(u8, reports[0].result_id, "alpha") != null);
    try testing.expect(std.mem.indexOf(u8, reports[1].result_id, "beta") != null);
    try testing.expect(!std.mem.eql(u8, reports[0].result_id, reports[1].result_id));
}

test "workspace contexts: same-name symbols in two documents do not share references or rename" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writeCrossRefPlugin(&fixture, "alpha.sjon", "alpha");
    try writeCrossRefPlugin(&fixture, "beta.sjon", "beta");
    try writeTwoBundleConfig(&fixture);
    const source = "(phrase :name p0)\n";
    try fixture.write("alpha/a.sjon", source);
    try fixture.write("beta/b.sjon", source);

    var registry = try fixture.registry();
    defer registry.deinit();

    const alpha_uri = try fixture.fileUri("alpha/a.sjon");
    const beta_uri = try fixture.fileUri("beta/b.sjon");
    const files = [_]Handler.WorkspaceFile{
        .{ .uri = alpha_uri, .source = source },
        .{ .uri = beta_uri, .source = source },
    };
    _ = try registry.ingestWorkspaceFiles(&files, .{});

    const alpha_handler = registry.handlerFor(alpha_uri) orelse
        return error.MissingAlphaHandler;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Both documents declare `p0`; the merged symbol list keeps both, but
    // each context's reference/rename scope remains its own tree.
    const symbols = try registry.workspaceSymbols(arena, "p0");
    try testing.expectEqual(@as(usize, 2), symbols.len);
    try testing.expectEqualStrings("p0", symbols[0].name);
    try testing.expectEqualStrings("p0", symbols[1].name);
    try testing.expect(!std.mem.eql(u8, symbols[0].location.uri, symbols[1].location.uri));

    const doc = alpha_handler.getDocument(alpha_uri).?;
    const offset: u32 = @intCast(std.mem.indexOf(u8, doc.source, "p0").?);
    const references = (try alpha_handler.findReferences(arena, alpha_uri, offset, true)).?;
    try testing.expectEqual(@as(usize, 1), references.len);
    try testing.expectEqualStrings(alpha_uri, references[0].uri);

    const renamed = (try alpha_handler.rename(arena, alpha_uri, offset, "p1")) orelse
        return error.MissingRename;
    switch (renamed) {
        .err => return error.UnexpectedRenameError,
        .edits => |edits| {
            try testing.expectEqual(@as(usize, 1), edits.changes.len);
            try testing.expectEqualStrings(alpha_uri, edits.changes[0].uri);
            try testing.expectEqual(@as(usize, 1), edits.changes[0].edits.len);
        },
    }
}

test "workspace contexts: unrelated ready context survives another context failure" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "alpha.sjon", "alpha", "alpha-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name alpha :files [\"alpha/**\"] :manifests [\"alpha.sjon\"])" ++
            "(bundle :name broken :files [\"broken/**\"] :manifests [\"missing.sjon\"])" ++
            "])",
    );
    try fixture.write("alpha/a.sjon", "(alpha-form)\n");
    try fixture.write("broken/b.sjon", "(broken-form)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const alpha_uri = try fixture.fileUri("alpha/a.sjon");
    const broken_uri = try fixture.fileUri("broken/b.sjon");
    const files = [_]Handler.WorkspaceFile{
        .{ .uri = alpha_uri, .source = "(alpha-form)\n" },
        .{ .uri = broken_uri, .source = "(broken-form)\n" },
    };
    _ = try registry.ingestWorkspaceFiles(&files, .{});

    const alpha_handler = registry.handlerFor(alpha_uri) orelse
        return error.MissingAlphaHandler;
    const broken_handler = registry.handlerFor(broken_uri) orelse
        return error.MissingBrokenHandler;
    try testing.expect(alpha_handler != broken_handler);

    var broken_state: ?RouteState = null;
    for (registry.contexts.items) |context| {
        if (@intFromPtr(&context.handler) == @intFromPtr(broken_handler)) {
            broken_state = context.state;
        }
    }
    try testing.expectEqual(@as(?RouteState, .unavailable), broken_state);

    // Force the broken context through another replacement. The unrelated
    // ready context must keep the same handler and document.
    const broken_route = try registry.openDocument(broken_uri, 1, "(broken-form)\n");
    try testing.expectEqual(RouteState.unavailable, broken_route.state);
    try testing.expect(registry.handlerFor(alpha_uri).? == alpha_handler);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const reports = try registry.workspaceReports(arena_state.allocator());
    var found_alpha = false;
    for (reports) |report| {
        if (!std.mem.eql(u8, report.uri, alpha_uri)) continue;
        found_alpha = true;
        try testing.expectEqual(@as(usize, 0), report.diagnostics.len);
    }
    try testing.expect(found_alpha);
}

test "workspace contexts: ingested declaration edit rebuilds the document context" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "base.sjon", "base", "base-form");
    try writePlugin(&fixture, "extra.sjon", "extra", "extra-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name base :files [\"**/*.sjon\"] :manifests [\"base.sjon\"])" ++
            "])",
    );
    const declared_source = "(use-plugin \"extra\" :path \"extra.sjon\")\n(base-form)\n";
    try fixture.write("doc.sjon", declared_source);

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("doc.sjon");
    _ = try registry.ingestWorkspaceFiles(&.{
        .{ .uri = document_uri, .source = declared_source },
    }, .{});

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var reports = try registry.workspaceReports(arena);
    try testing.expectEqual(@as(usize, 1), reports.len);
    try testing.expectEqual(@as(usize, 0), reports[0].diagnostics.len);

    var prepared_before: ?*Host.PreparedSchema = null;
    for (registry.contexts.items) |context| {
        if (context.kind == .declaration) prepared_before = context.prepared;
    }
    try testing.expect(prepared_before != null);

    // The declaration now names a manifest that does not exist. The
    // ingested report must reflect the recomputed preparation, not the
    // previous declaration's schema and diagnostics.
    const edited_source = "(use-plugin \"missing\" :path \"missing.sjon\")\n(base-form)\n";
    try fixture.write("doc.sjon", edited_source);
    _ = try registry.ingestWorkspaceFiles(&.{
        .{ .uri = document_uri, .source = edited_source },
    }, .{});

    reports = try registry.workspaceReports(arena);
    try testing.expectEqual(@as(usize, 1), reports.len);
    try testing.expectEqual(@as(usize, 1), reports[0].diagnostics.len);
    try testing.expectEqualStrings("unresolved_plugin", reports[0].diagnostics[0].code);

    var prepared_after: ?*Host.PreparedSchema = null;
    for (registry.contexts.items) |context| {
        if (context.kind == .declaration) prepared_after = context.prepared;
    }
    try testing.expect(prepared_after != null);
    try testing.expect(prepared_after.? != prepared_before.?);
}

test "workspace contexts: ingested declaration removal drops the old context and its reports" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "base.sjon", "base", "base-form");
    try writePlugin(&fixture, "extra.sjon", "extra", "extra-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name base :files [\"**/*.sjon\"] :manifests [\"base.sjon\"])" ++
            "])",
    );
    const declared_source = "(use-plugin \"extra\" :path \"extra.sjon\")\n(base-form)\n";
    try fixture.write("doc.sjon", declared_source);

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("doc.sjon");
    _ = try registry.ingestWorkspaceFiles(&.{
        .{ .uri = document_uri, .source = declared_source },
    }, .{});

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var reports = try registry.workspaceReports(arena);
    try testing.expectEqual(@as(usize, 1), reports.len);
    try testing.expect(std.mem.indexOf(u8, reports[0].result_id, "declaration") != null);

    // The directive is gone from disk. The document belongs to the shared
    // baseline again, and the declaration context it used to own must not
    // survive as a second, stale report holder.
    const plain_source = "(base-form)\n";
    try fixture.write("doc.sjon", plain_source);
    _ = try registry.ingestWorkspaceFiles(&.{
        .{ .uri = document_uri, .source = plain_source },
    }, .{});

    reports = try registry.workspaceReports(arena);
    const matching = countReportsFor(reports, document_uri);
    try testing.expectEqual(@as(usize, 1), matching);
    const current = workspaceReportFor(reports, document_uri).?;
    try testing.expectEqual(@as(usize, 0), current.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, current.result_id, "declaration") == null);

    for (registry.contexts.items) |context| {
        try testing.expect(context.kind != .declaration);
    }
}

test "declaration contexts: ordinary documents continue sharing the baseline" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "base.sjon", "base", "base-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name base :files [\"**/*.sjon\"] :manifests [\"base.sjon\"])" ++
            "])",
    );
    const source = "(base-form)\n";
    try fixture.write("a/doc.sjon", source);
    try fixture.write("b/doc.sjon", source);

    var registry = try fixture.registry();
    defer registry.deinit();

    const a_uri = try fixture.fileUri("a/doc.sjon");
    const b_uri = try fixture.fileUri("b/doc.sjon");
    const a = try registry.openDocument(a_uri, 1, source);
    const b = try registry.openDocument(b_uri, 1, source);

    try testing.expectEqual(RouteState.ready, a.state);
    try testing.expectEqual(RouteState.ready, b.state);
    try testing.expect(a.handler == b.handler);
    try testing.expectEqualStrings(a.context_id, b.context_id);
    try testing.expect(a.handler.prepared_schema == null);
    try testing.expectEqual(@as(usize, 2), a.handler.schema.plugins.len);
    try testing.expectEqualStrings("core", a.handler.schema.plugins[0].name);
    try testing.expectEqualStrings("base", a.handler.schema.plugins[1].name);
}

test "declaration contexts: inline plugin composes additively without changing other documents" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "base.sjon", "base", "base-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name base :files [\"**/*.sjon\"] :manifests [\"base.sjon\"])" ++
            "])",
    );
    const ordinary_source = "(base-form)\n";
    const declared_source =
        "(plugin :name extra :version \"1.0.0\" (form :name extra-form :open true))\n" ++
        "(base-form)\n(extra-form)\n";
    try fixture.write("a/doc.sjon", ordinary_source);
    try fixture.write("b/doc.sjon", declared_source);
    try fixture.write("c/doc.sjon", "(extra-form)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const a_uri = try fixture.fileUri("a/doc.sjon");
    const b_uri = try fixture.fileUri("b/doc.sjon");
    const a = try registry.openDocument(a_uri, 1, ordinary_source);
    const baseline_handler = a.handler;
    const b = try registry.openDocument(b_uri, 1, declared_source);

    try testing.expectEqual(RouteState.ready, a.state);
    try testing.expectEqual(RouteState.ready, b.state);
    try testing.expect(a.handler == baseline_handler);
    try testing.expect(b.handler != a.handler);
    try testing.expect(b.handler.prepared_schema != null);
    try testing.expectEqual(@as(usize, 2), a.handler.schema.plugins.len);
    try testing.expectEqual(@as(usize, 3), b.handler.schema.plugins.len);
    try testing.expectEqualStrings("base", b.handler.schema.plugins[1].name);
    try testing.expectEqualStrings("extra", b.handler.schema.plugins[2].name);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a_diagnostics = try documentDiagnostics(a, arena, a_uri);
    const b_diagnostics = try documentDiagnostics(b, arena, b_uri);
    try testing.expectEqual(@as(usize, 0), a_diagnostics.len);
    try testing.expectEqual(@as(usize, 0), b_diagnostics.len);

    // A third ordinary document stays in the same baseline handler and cannot
    // see the inline plugin another document declared.
    const c_uri = try fixture.fileUri("c/doc.sjon");
    const c = try registry.openDocument(c_uri, 1, "(extra-form)\n");
    try testing.expect(c.handler == baseline_handler);
    const c_diagnostics = try documentDiagnostics(c, arena, c_uri);
    try testing.expect(hasDiagnosticCode(c_diagnostics, "unknown_form"));
    try testing.expectEqual(@as(usize, 0), (try documentDiagnostics(a, arena, a_uri)).len);
}

test "declaration contexts: explicit path resolves relative to the marker directory" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "base.sjon", "base", "base-form");
    try writePlugin(&fixture, "schemas/shapes.sjon", "shapes", "circle");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name base :files [\"**/*.sjon\"] :manifests [\"base.sjon\"])" ++
            "])",
    );
    const source = "(use-plugin \"shapes\" :path \"schemas/shapes.sjon\")\n(circle)\n";
    try fixture.write("nested/doc.sjon", source);

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("nested/doc.sjon");
    const route = try registry.openDocument(document_uri, 1, source);

    try testing.expectEqual(RouteState.ready, route.state);
    try testing.expect(route.handler.prepared_schema != null);
    try testing.expectEqual(@as(usize, 3), route.handler.schema.plugins.len);
    try testing.expectEqualStrings("shapes", route.handler.schema.plugins[2].name);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const diagnostics = try documentDiagnostics(route, arena_state.allocator(), document_uri);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);

    const dependencies = registry.savedDependencies(document_uri);
    try testing.expectEqual(@as(usize, 1), dependencies.len);
    try testing.expect(std.mem.endsWith(u8, dependencies[0], "/schemas/shapes.sjon"));
}

test "declaration contexts: named reference requires the same-directory project index" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "schemas/parent.sjon", "parent", "parent-form");
    try fixture.write("sjon-project.sjon", "(project :plugins [\"schemas/parent.sjon\"])");
    try writePlugin(&fixture, "nested/base.sjon", "base", "base-form");
    try fixture.write(
        "nested/sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name nested :files [\"**/*.sjon\"] :manifests [\"base.sjon\"])" ++
            "])",
    );
    const source = "(use-plugin \"parent\")\n(parent-form)\n";
    try fixture.write("nested/doc.sjon", source);

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("nested/doc.sjon");
    const before = try registry.openDocument(document_uri, 1, source);

    try testing.expectEqual(RouteState.ready, before.state);
    try testing.expectEqual(@as(usize, 2), before.handler.schema.plugins.len);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before_diagnostics = try documentDiagnostics(before, arena, document_uri);
    try testing.expect(hasDiagnosticCode(before_diagnostics, "unresolved_plugin"));

    // Only the same-directory project index may answer the bare name; the
    // parent project above the nearest configuration is not consulted.
    try writePlugin(&fixture, "nested/schemas/parent.sjon", "parent", "parent-form");
    try fixture.write(
        "nested/sjon-project.sjon",
        "(project :plugins [\"schemas/parent.sjon\"])",
    );

    const after = try registry.changeDocumentFull(document_uri, 2, source);
    try testing.expectEqual(RouteState.ready, after.state);
    try testing.expectEqual(@as(usize, 3), after.handler.schema.plugins.len);
    try testing.expectEqualStrings("parent", after.handler.schema.plugins[2].name);
    const after_diagnostics = try documentDiagnostics(after, arena, document_uri);
    try testing.expectEqual(@as(usize, 0), after_diagnostics.len);

    const dependencies = registry.savedDependencies(document_uri);
    try testing.expect(hasSuffix(dependencies, "/nested/schemas/parent.sjon"));
    try testing.expect(hasSuffix(dependencies, "/nested/sjon-project.sjon"));
}

test "declaration contexts: inline-only document does not eagerly load the project" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "base.sjon", "base", "base-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name base :files [\"**/*.sjon\"] :manifests [\"base.sjon\"])" ++
            "])",
    );
    // Reading this project would produce an error for the missing manifest.
    try fixture.write("sjon-project.sjon", "(project :plugins [\"missing.sjon\"])");
    const source =
        "(plugin :name inline :version \"1.0.0\" (form :name inline-form :open true))\n" ++
        "(inline-form)\n";
    try fixture.write("doc.sjon", source);

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("doc.sjon");
    const route = try registry.openDocument(document_uri, 1, source);

    try testing.expectEqual(RouteState.ready, route.state);
    try testing.expectEqual(@as(usize, 3), route.handler.schema.plugins.len);
    try testing.expectEqualStrings("inline", route.handler.schema.plugins[2].name);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const diagnostics = try documentDiagnostics(route, arena_state.allocator(), document_uri);
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
    try testing.expectEqual(@as(usize, 0), registry.savedDependencies(document_uri).len);
}

test "declaration contexts: malformed declaration remains document-local" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "base.sjon", "base", "base-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name base :files [\"**/*.sjon\"] :manifests [\"base.sjon\"])" ++
            "])",
    );
    const ordinary_source = "(base-form)\n";
    const malformed_source = "(plugin)\n(base-form)\n";
    try fixture.write("a/doc.sjon", ordinary_source);
    try fixture.write("b/doc.sjon", malformed_source);

    var registry = try fixture.registry();
    defer registry.deinit();

    const a_uri = try fixture.fileUri("a/doc.sjon");
    const b_uri = try fixture.fileUri("b/doc.sjon");
    const a = try registry.openDocument(a_uri, 1, ordinary_source);
    const baseline_handler = a.handler;
    const b = try registry.openDocument(b_uri, 1, malformed_source);

    try testing.expectEqual(RouteState.ready, b.state);
    try testing.expect(b.handler != a.handler);
    try testing.expect(b.handler.prepared_schema != null);
    try testing.expect(a.handler == baseline_handler);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(@as(usize, 0), (try documentDiagnostics(a, arena, a_uri)).len);
    try testing.expect((try documentDiagnostics(b, arena, b_uri)).len > 0);
    try testing.expectEqual(@as(usize, 2), b.handler.schema.plugins.len);
}

test "declaration contexts: adding and removing a directive moves the document" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "base.sjon", "base", "base-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name base :files [\"**/*.sjon\"] :manifests [\"base.sjon\"])" ++
            "])",
    );
    const ordinary_source = "(base-form)\n";
    const declared_source =
        "(plugin :name extra :version \"1.0.0\" (form :name extra-form :open true))\n" ++
        "(base-form)\n";
    try fixture.write("doc.sjon", ordinary_source);

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("doc.sjon");
    const first = try registry.openDocument(document_uri, 1, ordinary_source);
    const baseline_id = try fixture.arena.allocator().dupe(u8, first.context_id);
    const baseline_handler = first.handler;
    const baseline_contexts = registry.contexts.items.len;
    try testing.expect(first.handler.prepared_schema == null);

    const declared = try registry.changeDocumentFull(document_uri, 2, declared_source);
    try testing.expectEqual(RouteState.ready, declared.state);
    try testing.expect(!std.mem.eql(u8, baseline_id, declared.context_id));
    try testing.expect(declared.handler != baseline_handler);
    try testing.expect(declared.handler.prepared_schema != null);
    try testing.expectEqual(@as(usize, 3), declared.handler.schema.plugins.len);
    try testing.expectEqual(baseline_contexts + 1, registry.contexts.items.len);

    const ordinary = try registry.changeDocumentFull(document_uri, 3, ordinary_source);
    try testing.expectEqual(RouteState.ready, ordinary.state);
    try testing.expectEqualStrings(baseline_id, ordinary.context_id);
    try testing.expect(ordinary.handler == baseline_handler);
    try testing.expect(ordinary.handler.prepared_schema == null);
    try testing.expectEqual(@as(usize, 2), ordinary.handler.schema.plugins.len);
    try testing.expectEqual(baseline_contexts, registry.contexts.items.len);
}

test "declaration contexts: every edit rebuilds preparation and current parse diagnostics" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "base.sjon", "base", "base-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name base :files [\"**/*.sjon\"] :manifests [\"base.sjon\"])" ++
            "])",
    );
    const valid_source =
        "(plugin :name inline :version \"1.0.0\" (form :name inline-form :open true))\n" ++
        "(inline-form)\n";
    const broken_source =
        "(plugin :name inline :version \"1.0.0\" (form :name inline-form :open true))\n" ++
        "(+ 1";
    try fixture.write("doc.sjon", valid_source);

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("doc.sjon");
    const first = try registry.openDocument(document_uri, 1, valid_source);
    const first_prepared = first.handler.prepared_schema.?;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(@as(usize, 0), (try documentDiagnostics(first, arena, document_uri)).len);

    const broken = try registry.changeDocumentFull(document_uri, 2, broken_source);
    try testing.expectEqual(RouteState.ready, broken.state);
    const broken_prepared = broken.handler.prepared_schema.?;
    try testing.expect(broken_prepared != first_prepared);
    try testing.expectEqualStrings(broken_source, broken.handler.getDocument(document_uri).?.source);
    try testing.expect(broken.handler.getDocument(document_uri).?.tree.hasErrors());
    const broken_diagnostics = try documentDiagnostics(broken, arena, document_uri);
    try testing.expect(broken_diagnostics.len > 0);
    for (broken_diagnostics) |diagnostic| {
        try testing.expect(diagnostic.span_end <= broken_source.len);
    }

    const repaired = try registry.changeDocumentFull(document_uri, 3, valid_source);
    try testing.expect(repaired.handler.prepared_schema.? != broken_prepared);
    try testing.expectEqual(@as(usize, 0), (try documentDiagnostics(repaired, arena, document_uri)).len);
}

test "declaration contexts: manifest-only resolution preserves plugin_wasm_required" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "base.sjon", "base", "base-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name base :files [\"**/*.sjon\"] :manifests [\"base.sjon\"])" ++
            "])",
    );
    try fixture.write(
        "schemas/wasmish.sjon",
        "(plugin :name wasmish :version \"1.0.0\"\n" ++
            "  (form :name wasm-form :open true)\n" ++
            "  (expr-func :name double :params [number] :result number :impl \"wasm:double\"))\n",
    );
    // A paired sidecar exists. Manifest-only resolution must not read it; if
    // it did, the missing-wasm diagnostic would disappear.
    try fixture.write("schemas/wasmish.wasm", "not actually wasm");
    const source = "(use-plugin \"wasmish\" :path \"schemas/wasmish.sjon\")\n(wasm-form)\n";
    try fixture.write("doc.sjon", source);

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("doc.sjon");
    const route = try registry.openDocument(document_uri, 1, source);

    try testing.expectEqual(RouteState.ready, route.state);
    try testing.expectEqual(@as(usize, 3), route.handler.schema.plugins.len);
    try testing.expectEqualStrings("wasmish", route.handler.schema.plugins[2].name);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const diagnostics = try documentDiagnostics(route, arena_state.allocator(), document_uri);
    try testing.expect(hasDiagnosticCode(diagnostics, "plugin_wasm_required"));

    const dependencies = registry.savedDependencies(document_uri);
    try testing.expectEqual(@as(usize, 1), dependencies.len);
    try testing.expect(std.mem.endsWith(u8, dependencies[0], "/schemas/wasmish.sjon"));
}

test "declaration contexts: resolved manifest and applicable project are saved dependencies" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "base.sjon", "base", "base-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name base :files [\"**/*.sjon\"] :manifests [\"base.sjon\"])" ++
            "])",
    );
    try writePlugin(&fixture, "schemas/named.sjon", "named", "named-form");
    try fixture.write("schemas/broken.sjon", "(not-a-plugin)\n");
    try fixture.write("sjon-project.sjon", "(project :plugins [\"schemas/named.sjon\"])");
    const source =
        "(use-plugin \"named\")\n" ++
        "(use-plugin \"broken\" :path \"schemas/broken.sjon\")\n" ++
        "(named-form)\n";
    try fixture.write("doc.sjon", source);

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("doc.sjon");
    const route = try registry.openDocument(document_uri, 1, source);

    try testing.expectEqual(RouteState.ready, route.state);
    const dependencies = registry.savedDependencies(document_uri);
    try testing.expectEqual(@as(usize, 3), dependencies.len);
    try testing.expect(hasSuffix(dependencies, "/schemas/named.sjon"));
    try testing.expect(hasSuffix(dependencies, "/schemas/broken.sjon"));
    try testing.expect(hasSuffix(dependencies, "/sjon-project.sjon"));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const diagnostics = try documentDiagnostics(route, arena_state.allocator(), document_uri);
    try testing.expect(diagnostics.len > 0);
}

fn savedReportFor(
    reports: []const SavedSourceReport,
    suffix: []const u8,
) ?SavedSourceReport {
    for (reports) |report| {
        if (std.mem.endsWith(u8, report.uri, suffix)) return report;
    }
    return null;
}

fn workspaceReportFor(
    reports: []const Handler.WorkspaceReport,
    document_uri: []const u8,
) ?Handler.WorkspaceReport {
    for (reports) |report| {
        if (uri.HashContext.eql(.{}, report.uri, document_uri)) return report;
    }
    return null;
}

fn countReportsFor(
    reports: []const Handler.WorkspaceReport,
    document_uri: []const u8,
) usize {
    var count: usize = 0;
    for (reports) |report| {
        if (uri.HashContext.eql(.{}, report.uri, document_uri)) count += 1;
    }
    return count;
}

fn reloadChanged(
    registry: *Registry,
    arena: Allocator,
    document_uri: []const u8,
) !ReloadResult {
    return registry.reloadSavedInputs(arena, &.{.{ .uri = document_uri, .kind = .changed }});
}

test "reload: saved manifest edit rebuilds only affected contexts" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "alpha.sjon", "alpha", "alpha-old");
    try writePlugin(&fixture, "beta.sjon", "beta", "beta-form");
    try writeTwoBundleConfig(&fixture);
    try fixture.write("alpha/doc.sjon", "(alpha-old)\n");
    try fixture.write("beta/doc.sjon", "(beta-form)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const alpha_uri = try fixture.fileUri("alpha/doc.sjon");
    const beta_uri = try fixture.fileUri("beta/doc.sjon");
    _ = try registry.openDocument(alpha_uri, 1, "(alpha-old)\n");
    _ = try registry.openDocument(beta_uri, 1, "(beta-form)\n");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const beta_before = try registry.route(beta_uri).?.handler.diagnosticResultId(
        arena,
        registry.route(beta_uri).?.handler.getDocument(beta_uri).?,
    );
    const alpha_before = try registry.route(alpha_uri).?.handler.diagnosticResultId(
        arena,
        registry.route(alpha_uri).?.handler.getDocument(alpha_uri).?,
    );

    try writePlugin(&fixture, "alpha.sjon", "alpha", "alpha-v2");
    const outcome = try reloadChanged(&registry, arena, try fixture.fileUri("alpha.sjon"));
    try testing.expect(outcome.changed);

    const after_alpha = registry.route(alpha_uri).?;
    const after_beta = registry.route(beta_uri).?;
    try testing.expectEqual(RouteState.ready, after_alpha.state);
    try testing.expectEqualStrings("alpha-v2", after_alpha.handler.schema.plugins[1].forms[0].name);
    try testing.expectEqualStrings("(alpha-old)\n", after_alpha.handler.getDocument(alpha_uri).?.source);

    const beta_after = try after_beta.handler.diagnosticResultId(
        arena,
        after_beta.handler.getDocument(beta_uri).?,
    );
    const alpha_after = try after_alpha.handler.diagnosticResultId(
        arena,
        after_alpha.handler.getDocument(alpha_uri).?,
    );
    try testing.expectEqualStrings(beta_before, beta_after);
    try testing.expect(!std.mem.eql(u8, alpha_before, alpha_after));
}

/// Allocator wrapper for the reload aliasing probe. It records the byte
/// range of every free that flows through it and retires every recorded
/// range a later allocation lands on, so "freed and never reused" is
/// answerable by pointer arithmetic alone — with no reliance on page
/// faults, poisoned bytes, or how long freed pages stay mapped.
const FreedRangeTracker = struct {
    child: Allocator,
    ranges: std.ArrayList(Range) = .empty,

    const Range = struct { start: usize, end: usize };

    fn init(child: Allocator) FreedRangeTracker {
        return .{ .child = child };
    }

    fn deinit(self: *FreedRangeTracker) void {
        self.ranges.deinit(testing.allocator);
    }

    fn allocator(self: *FreedRangeTracker) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *FreedRangeTracker = @ptrCast(@alignCast(ctx));
        const result = self.child.rawAlloc(len, alignment, return_address) orelse return null;
        self.retire(@intFromPtr(result), @intFromPtr(result) + len);
        return result;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *FreedRangeTracker = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, return_address)) return false;
        if (new_len < memory.len) {
            self.record(memory.ptr + new_len, memory.ptr + memory.len);
        } else {
            self.retire(@intFromPtr(memory.ptr), @intFromPtr(memory.ptr) + new_len);
        }
        return true;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *FreedRangeTracker = @ptrCast(@alignCast(ctx));
        const result = self.child.rawRemap(memory, alignment, new_len, return_address) orelse
            return null;
        if (result != memory.ptr) {
            self.record(memory.ptr, memory.ptr + memory.len);
        }
        self.retire(@intFromPtr(result), @intFromPtr(result) + new_len);
        return result;
    }

    fn free(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *FreedRangeTracker = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, return_address);
        self.record(memory.ptr, memory.ptr + memory.len);
    }

    fn record(self: *FreedRangeTracker, start: [*]u8, end: [*]u8) void {
        self.ranges.append(testing.allocator, .{
            .start = @intFromPtr(start),
            .end = @intFromPtr(end),
        }) catch @panic("FreedRangeTracker journal exhausted memory");
    }

    /// A live allocation retires every recorded range it overlaps, so an
    /// address the child allocator reused never reads as a dangle.
    fn retire(self: *FreedRangeTracker, start: usize, end: usize) void {
        var i: usize = 0;
        while (i < self.ranges.items.len) {
            const range = self.ranges.items[i];
            if (range.start < end and start < range.end) {
                _ = self.ranges.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    fn aliasesFreed(self: *const FreedRangeTracker, bytes: []const u8) bool {
        const start = @intFromPtr(bytes.ptr);
        const end = start + bytes.len;
        for (self.ranges.items) |range| {
            if (range.start < end and start < range.end) return true;
        }
        return false;
    }
};

test "reload: affected URI sets do not alias the destroyed registry" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "alpha.sjon", "alpha", "alpha-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [(bundle :name alpha :files [\"docs/**\"] :manifests [\"alpha.sjon\"])])",
    );
    try fixture.write("docs/doc.sjon", "(alpha-form)\n");

    // The registry and the request arena share the tracker: every URI the
    // reload returns must live in a still-live tracker block, never in a
    // range the destroyed old registry released inside the call.
    var tracker = FreedRangeTracker.init(testing.allocator);
    defer tracker.deinit();
    var registry = Registry.init(tracker.allocator(), testing.io);
    defer registry.deinit();
    var roots = try discovery.initializationRoots(
        testing.allocator,
        &.{try fixture.rootUri()},
        null,
        null,
    );
    defer roots.deinit();
    try registry.configureRoots(roots.items);

    const document_uri = try fixture.fileUri("docs/doc.sjon");
    _ = try registry.openDocument(document_uri, 1, "(alpha-form)\n");

    var arena_state = std.heap.ArenaAllocator.init(tracker.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try writePlugin(&fixture, "alpha.sjon", "alpha", "alpha-v2");
    const outcome = try reloadChanged(&registry, arena, try fixture.fileUri("alpha.sjon"));
    try testing.expect(outcome.changed);
    try testing.expect(outcome.old_uris.len > 0);
    try testing.expect(outcome.new_uris.len > 0);

    for (outcome.old_uris, 0..) |affected, i| {
        if (tracker.aliasesFreed(affected)) {
            std.debug.print(
                "old_uris[{d}] at 0x{x} aliases registry memory freed by the reload\n",
                .{ i, @intFromPtr(affected.ptr) },
            );
            return error.AffectedUriAliasesDestroyedRegistry;
        }
    }
    for (outcome.new_uris, 0..) |affected, i| {
        if (tracker.aliasesFreed(affected)) {
            std.debug.print(
                "new_uris[{d}] at 0x{x} aliases registry memory freed by the reload\n",
                .{ i, @intFromPtr(affected.ptr) },
            );
            return error.AffectedUriAliasesDestroyedRegistry;
        }
    }
}

test "reload: saved config edit moves associations and preserves current buffers" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "alpha.sjon", "alpha", "alpha-form");
    try writePlugin(&fixture, "beta.sjon", "beta", "beta-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [(bundle :name alpha :files [\"alpha/**\"] :manifests [\"alpha.sjon\"])])",
    );
    try fixture.write("alpha/doc.sjon", "(alpha-form)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("alpha/doc.sjon");
    const unsaved = "(alpha-form) ; current buffer\n";
    const before = try registry.openDocument(document_uri, 1, unsaved);
    try testing.expectEqual(RouteState.ready, before.state);

    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [(bundle :name beta :files [\"beta/**\"] :manifests [\"beta.sjon\"])])",
    );

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const outcome = try reloadChanged(
        &registry,
        arena_state.allocator(),
        try fixture.fileUri("sjon-lsp.sjon"),
    );
    try testing.expect(outcome.changed);

    const after = registry.route(document_uri).?;
    try testing.expectEqual(RouteState.unconfigured, after.state);
    try testing.expectEqual(@as(usize, 1), after.handler.schema.plugins.len);
    try testing.expectEqualStrings("core", after.handler.schema.plugins[0].name);
    try testing.expectEqualStrings(unsaved, after.handler.getDocument(document_uri).?.source);
}

test "reload: atomic source replacement reads the new saved generation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "alpha.sjon", "alpha", "old-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [(bundle :name alpha :files [\"docs/**\"] :manifests [\"alpha.sjon\"])])",
    );
    try fixture.write("docs/doc.sjon", "(old-form)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("docs/doc.sjon");
    const manifest_uri = try fixture.fileUri("alpha.sjon");
    _ = try registry.openDocument(document_uri, 1, "(old-form)\n");

    try writePlugin(&fixture, "alpha.sjon", "alpha", "new-form");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const outcome = try reloadChanged(&registry, arena, manifest_uri);
    try testing.expect(outcome.changed);

    const route = registry.route(document_uri).?;
    try testing.expectEqual(RouteState.ready, route.state);
    try testing.expectEqualStrings("new-form", route.handler.schema.plugins[1].forms[0].name);

    const diagnostics = try documentDiagnostics(route, arena, document_uri);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqualStrings("unknown_form", diagnostics[0].code);
}

test "reload: unsaved source edit leaves dependents on the saved generation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "alpha.sjon", "alpha", "saved-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [(bundle :name alpha :files [\"docs/**\"] :manifests [\"alpha.sjon\"])])",
    );
    try fixture.write("docs/doc.sjon", "(saved-form)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("docs/doc.sjon");
    const manifest_uri = try fixture.fileUri("alpha.sjon");
    const route = try registry.openDocument(document_uri, 1, "(saved-form)\n");
    try testing.expectEqualStrings("saved-form", route.handler.schema.plugins[1].forms[0].name);

    const dirty =
        "(plugin :name alpha :version \"1.0.0\" (form :name dirty-form :open true))\n";
    const source_route = try registry.openDocument(manifest_uri, 1, dirty);
    try testing.expectEqual(RouteState.source, source_route.state);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Opening the buffer is not a save: the dependents still use the last
    // saved generation and the dirty buffer's report is suppressed.
    const still = registry.route(document_uri).?;
    try testing.expectEqualStrings("saved-form", still.handler.schema.plugins[1].forms[0].name);
    try testing.expect((try registry.savedSourceReportFor(arena, manifest_uri)) == null);
}

test "reload: open saved source combines aligned reports and deduplicates parse diagnostics" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const broken = "(plugin :name broken :version \"1.0.0\"\n  (form :name broken-form :open true";
    try fixture.write("broken.sjon", broken);
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [(bundle :name broken :files [\"docs/**\"] :manifests [\"broken.sjon\"])])",
    );
    try fixture.write("docs/doc.sjon", "(broken-form)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("docs/doc.sjon");
    const manifest_uri = try fixture.fileUri("broken.sjon");
    _ = try registry.openDocument(document_uri, 1, "(broken-form)\n");
    const source_route = try registry.openDocument(manifest_uri, 1, broken);
    try testing.expectEqual(RouteState.source, source_route.state);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const saved = (try registry.savedSourceReportFor(arena, manifest_uri)) orelse
        return error.MissingSavedReport;
    try testing.expect(saved.diagnostics.len > 0);
    try testing.expectEqualStrings(broken, saved.source);

    const live = (try source_route.handler.getDiagnostics(arena, manifest_uri)) orelse
        return error.MissingLiveReport;
    try testing.expect(live.len > 0);

    const merged = try registry.mergeSourceDiagnostics(arena, manifest_uri, live);
    // The saved report's parse diagnostics are already present in the live
    // parse; combining must not add a second copy.
    try testing.expectEqual(live.len, merged.len);
    for (merged) |diagnostic| {
        try testing.expect(diagnostic.span_end <= broken.len);
    }
}

test "reload: closing a dirty source restores the saved-byte source report" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.write("broken.sjon", "(plugin :name broken :version \"1.0.0\"");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [(bundle :name broken :files [\"docs/**\"] :manifests [\"broken.sjon\"])])",
    );
    try fixture.write("docs/doc.sjon", "(broken-form)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("docs/doc.sjon");
    const manifest_uri = try fixture.fileUri("broken.sjon");
    _ = try registry.openDocument(document_uri, 1, "(broken-form)\n");

    const dirty =
        "(plugin :name broken :version \"1.0.0\" (form :name broken-form :open true))\n";
    _ = try registry.openDocument(manifest_uri, 1, dirty);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect((try registry.savedSourceReportFor(arena, manifest_uri)) == null);

    registry.closeDocument(manifest_uri);

    const restored = (try registry.savedSourceReportFor(arena, manifest_uri)) orelse
        return error.MissingRestoredReport;
    try testing.expect(restored.diagnostics.len > 0);
}

test "reload: deleted selected marker invalidates without parent fallback" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "outer.sjon", "outer", "outer-form");
    try writePlugin(&fixture, "inner/inner.sjon", "inner", "inner-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [(bundle :name outer :files [\"**/*.sjon\"] :manifests [\"outer.sjon\"])])",
    );
    try fixture.write(
        "inner/sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [(bundle :name inner :files [\"**/*.sjon\"] :manifests [\"inner.sjon\"])])",
    );
    try fixture.write("inner/doc.sjon", "(inner-form)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("inner/doc.sjon");
    const config_uri = try fixture.fileUri("inner/sjon-lsp.sjon");
    const before = try registry.openDocument(document_uri, 1, "(inner-form)\n");
    try testing.expectEqual(RouteState.ready, before.state);
    try testing.expectEqualStrings("inner", before.handler.schema.plugins[1].name);

    try fixture.remove("inner/sjon-lsp.sjon");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const outcome = try registry.reloadSavedInputs(arena, &.{
        .{ .uri = config_uri, .kind = .deleted },
    });
    try testing.expect(outcome.changed);

    const after = registry.route(document_uri).?;
    try testing.expectEqual(RouteState.unavailable, after.state);
    try testing.expectEqual(Handler.DiagnosticMode.parse_only, after.handler.diagnostic_mode);
    try testing.expectEqual(@as(usize, 0), after.handler.schema.plugins.len);
    try testing.expectEqualStrings("(inner-form)\n", after.handler.getDocument(document_uri).?.source);

    const diagnostics = try registry.editorDiagnostics(arena, document_uri);
    var saw_marker_deleted = false;
    for (diagnostics) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, codes.marker_deleted)) saw_marker_deleted = true;
    }
    try testing.expect(saw_marker_deleted);
    try testing.expect(!std.mem.endsWith(u8, after.context_id, ":outer"));

    // A document opened after the deletion cannot rediscover the parent
    // configuration either; the retained boundary keeps it unavailable.
    const fresh_uri = try fixture.fileUri("inner/new.sjon");
    const fresh = try registry.openDocument(fresh_uri, 1, "(outer-form)\n");
    try testing.expectEqual(RouteState.unavailable, fresh.state);
    const fresh_diagnostics = try registry.editorDiagnostics(arena, fresh_uri);
    var fresh_marker_deleted = false;
    for (fresh_diagnostics) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, codes.marker_deleted)) {
            fresh_marker_deleted = true;
        }
    }
    try testing.expect(fresh_marker_deleted);
}

test "reload: recreated known marker recovers the same boundary" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "outer.sjon", "outer", "outer-form");
    try writePlugin(&fixture, "inner/inner.sjon", "inner", "inner-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [(bundle :name outer :files [\"**/*.sjon\"] :manifests [\"outer.sjon\"])])",
    );
    const nested_config =
        "(sjon-lsp :version 1 :bundles [(bundle :name inner :files [\"**/*.sjon\"] :manifests [\"inner.sjon\"])])";
    try fixture.write("inner/sjon-lsp.sjon", nested_config);
    try fixture.write("inner/doc.sjon", "(inner-form)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("inner/doc.sjon");
    const config_uri = try fixture.fileUri("inner/sjon-lsp.sjon");
    const unsaved = "(inner-form) ; unsaved\n";
    _ = try registry.openDocument(document_uri, 1, unsaved);

    try fixture.remove("inner/sjon-lsp.sjon");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = try registry.reloadSavedInputs(arena, &.{
        .{ .uri = config_uri, .kind = .deleted },
    });
    try testing.expectEqual(RouteState.unavailable, registry.route(document_uri).?.state);

    try fixture.write("inner/sjon-lsp.sjon", nested_config);
    const outcome = try reloadChanged(&registry, arena, config_uri);
    try testing.expect(outcome.changed);

    const after = registry.route(document_uri).?;
    try testing.expectEqual(RouteState.ready, after.state);
    try testing.expectEqualStrings("inner", after.handler.schema.plugins[1].name);
    try testing.expectEqualStrings(unsaved, after.handler.getDocument(document_uri).?.source);
    try testing.expect(std.mem.endsWith(u8, after.context_id, ":inner"));
}

test "reload: wholly new marker takes effect after restart" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "outer.sjon", "outer", "outer-form");
    try writePlugin(&fixture, "nested/inner.sjon", "inner", "inner-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [(bundle :name outer :files [\"**/*.sjon\"] :manifests [\"outer.sjon\"])])",
    );
    try fixture.write("nested/doc.sjon", "(outer-form)\n");

    var registry = try fixture.registry();

    const document_uri = try fixture.fileUri("nested/doc.sjon");
    const new_config_uri = try fixture.fileUri("nested/sjon-lsp.sjon");
    _ = try registry.openDocument(document_uri, 1, "(outer-form)\n");

    try fixture.write(
        "nested/sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [(bundle :name inner :files [\"**/*.sjon\"] :manifests [\"inner.sjon\"])])",
    );

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(!try registry.isKnownInputUri(arena, new_config_uri));
    const ignored = try reloadChanged(&registry, arena, new_config_uri);
    try testing.expect(!ignored.changed);
    try testing.expectEqualStrings("outer", registry.route(document_uri).?.handler.schema.plugins[1].name);

    // A restart is the documented recovery for a wholly new marker.
    registry.deinit();
    var restarted = try fixture.registry();
    defer restarted.deinit();
    const after = try restarted.openDocument(document_uri, 1, "(outer-form)\n");
    try testing.expectEqual(RouteState.ready, after.state);
    try testing.expectEqualStrings("inner", after.handler.schema.plugins[1].name);
}

test "reload: source diagnostics shared by contexts are combined before replacement publish" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.write("shared.sjon", "(plugin :name shared :version \"1.0.0\"");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name alpha :files [\"alpha/**\"] :manifests [\"shared.sjon\"])" ++
            "(bundle :name beta :files [\"beta/**\"] :manifests [\"shared.sjon\"])" ++
            "])",
    );
    try fixture.write("alpha/doc.sjon", "(shared-form)\n");
    try fixture.write("beta/doc.sjon", "(shared-form)\n");

    var registry = try fixture.registry();
    defer registry.deinit();
    _ = try registry.openDocument(try fixture.fileUri("alpha/doc.sjon"), 1, "(shared-form)\n");
    _ = try registry.openDocument(try fixture.fileUri("beta/doc.sjon"), 1, "(shared-form)\n");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reports = try registry.savedSourceReports(arena);

    const shared = savedReportFor(reports, "/shared.sjon") orelse
        return error.MissingSharedReport;
    try testing.expect(shared.diagnostics.len > 0);

    var shared_count: usize = 0;
    for (reports) |report| {
        if (std.mem.endsWith(u8, report.uri, "/shared.sjon")) shared_count += 1;
    }
    // Two bundle contexts both include this source; one URI owns one
    // deduplicated report.
    try testing.expectEqual(@as(usize, 1), shared_count);
}

test "reload: OOM rebuild retains old contexts and never publishes empty success" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "alpha.sjon", "alpha", "alpha-old");
    try writePlugin(&fixture, "beta.sjon", "beta", "beta-form");
    try writeTwoBundleConfig(&fixture);
    try fixture.write("alpha/doc.sjon", "(alpha-old)\n");
    try fixture.write("beta/doc.sjon", "(beta-form)\n");

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var registry = Registry.init(failing.allocator(), testing.io);
    var roots = try discovery.initializationRoots(
        testing.allocator,
        &.{try fixture.rootUri()},
        null,
        null,
    );
    defer roots.deinit();
    try registry.configureRoots(roots.items);

    const alpha_uri = try fixture.fileUri("alpha/doc.sjon");
    const beta_uri = try fixture.fileUri("beta/doc.sjon");
    const before = try registry.openDocument(alpha_uri, 1, "(alpha-old)\n");
    _ = try registry.openDocument(beta_uri, 1, "(beta-form)\n");

    try writePlugin(&fixture, "alpha.sjon", "alpha", "alpha-v2");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const start_alloc = failing.alloc_index;
    const start_resize = failing.resize_index;
    var rebuilt = false;
    var saw_oom = false;
    var offset: usize = 0;
    while (offset < (1 << 20)) {
        failing.fail_index = start_alloc + offset;
        failing.resize_fail_index = start_resize + offset;
        const next_offset: usize = if (offset == 0) 1 else offset * 2;
        if (registry.reloadSavedInputs(arena, &.{.{
            .uri = try fixture.fileUri("alpha.sjon"),
            .kind = .changed,
        }})) |outcome| {
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            try testing.expect(outcome.changed);
            rebuilt = true;
            break;
        } else |err| {
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            try testing.expectEqual(error.OutOfMemory, err);
            saw_oom = true;

            const still = registry.route(alpha_uri) orelse return error.MissingOldRoute;
            try testing.expect(still.handler == before.handler);
            try testing.expectEqual(RouteState.ready, still.state);
            try testing.expectEqualStrings("alpha-old", still.handler.schema.plugins[1].forms[0].name);
            try testing.expectEqualStrings(
                "(alpha-old)\n",
                still.handler.getDocument(alpha_uri).?.source,
            );
            const reports = try registry.savedSourceReports(arena);
            try testing.expect(savedReportFor(reports, "/alpha.sjon") != null);
        }
        offset = next_offset;
    }
    try testing.expect(saw_oom);
    try testing.expect(rebuilt);

    registry.deinit();
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "reload: OOM after a successful legacy reload retains every legacy context" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "legacy.sjon", "legacy", "legacy-old");
    try fixture.write("sjon-project.sjon", "(project :plugins [\"legacy.sjon\"])");
    try fixture.write("doc.sjon", "(legacy-old)\n");

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var registry = Registry.init(failing.allocator(), testing.io);
    var roots = try discovery.initializationRoots(
        testing.allocator,
        &.{try fixture.rootUri()},
        null,
        null,
    );
    defer roots.deinit();
    try registry.configureRoots(roots.items);
    try registry.loadRootProject(roots.items[0].path);

    const document_uri = try fixture.fileUri("doc.sjon");
    const before = try registry.openDocument(document_uri, 1, "(legacy-old)\n");
    try testing.expectEqualStrings("legacy-old", before.handler.schema.plugins[1].forms[0].name);

    try writePlugin(&fixture, "legacy.sjon", "legacy", "legacy-v2");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const start_alloc = failing.alloc_index;
    const start_resize = failing.resize_index;
    var saw_oom = false;
    var reloaded = false;
    var offset: usize = 0;
    while (offset < (1 << 20)) {
        failing.fail_index = start_alloc + offset;
        failing.resize_fail_index = start_resize + offset;
        // Saving an ordinary document is not a known-input change; the
        // legacy project is still re-read, inside the same transactional
        // rebuild as every bundle context.
        if (registry.reloadSavedInputs(arena, &.{.{
            .uri = document_uri,
            .kind = .changed,
        }})) |outcome| {
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            try testing.expect(!outcome.changed);
            reloaded = true;
            break;
        } else |err| {
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            try testing.expectEqual(error.OutOfMemory, err);
            saw_oom = true;

            // The failure may land after the replacement had already
            // re-read the legacy project from disk. The old context must
            // still own the document, the old schema, and the old project
            // source report regardless.
            const still = registry.route(document_uri) orelse return error.MissingOldRoute;
            try testing.expect(still.handler == before.handler);
            try testing.expectEqualStrings(
                "legacy-old",
                still.handler.schema.plugins[1].forms[0].name,
            );
            try testing.expectEqualStrings(
                "(legacy-old)\n",
                still.handler.getDocument(document_uri).?.source,
            );
            var project_report = false;
            for (try registry.projectSources(arena)) |source| {
                if (std.mem.endsWith(u8, source.uri, "/sjon-project.sjon")) project_report = true;
            }
            try testing.expect(project_report);
        }
        offset = if (offset == 0) 1 else offset * 2;
    }
    try testing.expect(saw_oom);
    try testing.expect(reloaded);
    try testing.expectEqualStrings(
        "legacy-v2",
        registry.route(document_uri).?.handler.schema.plugins[1].forms[0].name,
    );

    registry.deinit();
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "reload: failure between two legacy roots changes no context" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "one/one.sjon", "one", "one-old");
    try writePlugin(&fixture, "two/two.sjon", "two", "two-old");
    try fixture.write("one/sjon-project.sjon", "(project :plugins [\"one.sjon\"])");
    try fixture.write("two/sjon-project.sjon", "(project :plugins [\"two.sjon\"])");
    try fixture.write("one/doc.sjon", "(one-old)\n");
    try fixture.write("two/doc.sjon", "(two-old)\n");

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var registry = Registry.init(failing.allocator(), testing.io);
    var roots = try discovery.initializationRoots(
        testing.allocator,
        &.{ try fixture.fileUri("one"), try fixture.fileUri("two") },
        null,
        null,
    );
    defer roots.deinit();
    try registry.configureRoots(roots.items);
    for (roots.items) |root| try registry.loadRootProject(root.path);

    const one_doc = try fixture.fileUri("one/doc.sjon");
    const two_doc = try fixture.fileUri("two/doc.sjon");
    const before_one = try registry.openDocument(one_doc, 1, "(one-old)\n");
    const before_two = try registry.openDocument(two_doc, 1, "(two-old)\n");
    try testing.expect(before_one.handler != before_two.handler);
    try testing.expectEqualStrings("one-old", before_one.handler.schema.plugins[1].forms[0].name);
    try testing.expectEqualStrings("two-old", before_two.handler.schema.plugins[1].forms[0].name);

    // Only root one's manifest changes on disk.
    try writePlugin(&fixture, "one/one.sjon", "one", "one-v2");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const start_alloc = failing.alloc_index;
    const start_resize = failing.resize_index;
    var saw_oom = false;
    var reloaded = false;
    var offset: usize = 0;
    while (offset < (1 << 20)) {
        failing.fail_index = start_alloc + offset;
        failing.resize_fail_index = start_resize + offset;
        // An ordinary save in root one still re-reads both roots' legacy
        // projects; the reload must be all-or-nothing across them.
        if (registry.reloadSavedInputs(arena, &.{.{
            .uri = one_doc,
            .kind = .changed,
        }})) |outcome| {
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            try testing.expect(!outcome.changed);
            reloaded = true;
            break;
        } else |err| {
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            try testing.expectEqual(error.OutOfMemory, err);
            saw_oom = true;

            // A failure anywhere between the two roots — including after
            // the first root's project was successfully re-read — must
            // leave both contexts exactly as they were.
            const still_one = registry.route(one_doc) orelse return error.MissingOneRoute;
            const still_two = registry.route(two_doc) orelse return error.MissingTwoRoute;
            try testing.expect(still_one.handler == before_one.handler);
            try testing.expect(still_two.handler == before_two.handler);
            try testing.expectEqualStrings(
                "one-old",
                still_one.handler.schema.plugins[1].forms[0].name,
            );
            try testing.expectEqualStrings(
                "two-old",
                still_two.handler.schema.plugins[1].forms[0].name,
            );
            try testing.expectEqualStrings(
                "(one-old)\n",
                still_one.handler.getDocument(one_doc).?.source,
            );
            try testing.expectEqualStrings(
                "(two-old)\n",
                still_two.handler.getDocument(two_doc).?.source,
            );
        }
        offset = if (offset == 0) 1 else offset * 2;
    }
    try testing.expect(saw_oom);
    try testing.expect(reloaded);

    // The successful reload re-read root one's manifest; root two's
    // manifest is untouched on disk and keeps its old form.
    const after_one = registry.route(one_doc).?;
    const after_two = registry.route(two_doc).?;
    try testing.expectEqualStrings("one-v2", after_one.handler.schema.plugins[1].forms[0].name);
    try testing.expectEqualStrings("two-old", after_two.handler.schema.plugins[1].forms[0].name);

    registry.deinit();
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "reload: pure legacy project retains manifest reload behavior" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "legacy.sjon", "legacy", "legacy-old");
    try fixture.write("sjon-project.sjon", "(project :plugins [\"legacy.sjon\"])");
    try fixture.write("doc.sjon", "(legacy-old)\n");

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("doc.sjon");
    const route = try registry.openDocument(document_uri, 1, "(legacy-old)\n");
    try testing.expectEqualStrings("legacy-old", route.handler.schema.plugins[1].forms[0].name);

    // Pinning: this is the pre-bundle behavior Task 11 must not regress.
    try writePlugin(&fixture, "legacy.sjon", "legacy", "legacy-v2");
    var reload_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer reload_arena.deinit();
    const outcome = try registry.reloadSavedInputs(
        reload_arena.allocator(),
        &.{.{ .uri = document_uri, .kind = .changed }},
    );
    try testing.expect(!outcome.changed);

    const after = registry.route(document_uri).?;
    try testing.expectEqualStrings("legacy-v2", after.handler.schema.plugins[1].forms[0].name);
}

test "declaration contexts: no sidecar discovery or lowering occurs" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try writePlugin(&fixture, "base.sjon", "base", "base-form");
    try fixture.write(
        "sjon-lsp.sjon",
        "(sjon-lsp :version 1 :bundles [" ++
            "(bundle :name base :files [\"**/*.sjon\"] :manifests [\"base.sjon\"])" ++
            "])",
    );
    try fixture.write(
        "schemas/lowered.sjon",
        "(plugin :name lowered :version \"1.0.0\"\n" ++
            "  (form :name pass\n" ++
            "    :lowering (lowering :hook p/entry-v1 :produces [thing])\n" ++
            "    :open true))\n",
    );
    try fixture.write("schemas/lowered.wasm", "not actually wasm");
    const source = "(use-plugin \"lowered\" :path \"schemas/lowered.sjon\")\n(pass)\n";
    try fixture.write("doc.sjon", source);

    var registry = try fixture.registry();
    defer registry.deinit();

    const document_uri = try fixture.fileUri("doc.sjon");
    const route = try registry.openDocument(document_uri, 1, source);

    try testing.expectEqual(RouteState.ready, route.state);
    const prepared = route.handler.prepared_schema.?;
    for (prepared.diagnostics) |diagnostic| {
        try testing.expect(diagnostic.phase != .lowering);
        try testing.expect(diagnostic.code != .lowering_hook_missing);
    }

    const dependencies = registry.savedDependencies(document_uri);
    try testing.expectEqual(@as(usize, 1), dependencies.len);
    try testing.expect(std.mem.endsWith(u8, dependencies[0], "/schemas/lowered.sjon"));
    try testing.expect(!hasSuffix(dependencies, ".wasm"));
}
