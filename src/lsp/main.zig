//! SJON Language Server — native entry point.
//!
//! Stdio + JSON-RPC via lsp-kit's `basic_server`. The `Server` struct
//! exposes the typed methods lsp-kit dispatches by name; each one resolves
//! the request URI's schema context through `context_registry` and forwards
//! to that context's transport-agnostic `Handler` (which is shared with the
//! WASM target). There is no singleton document handler.
//!
//! Scope today: initialize (retaining every workspace folder and loading
//! each root's `sjon-project.sjon` when no `sjon-lsp.sjon` wins), didOpen /
//! didChange (full sync) / didClose, per-document diagnostics from
//! `sjon-lsp.sjon` bundles or the applicable legacy project, pull-mode
//! `textDocument/diagnostic` (also surfaces project-file diagnostics on the
//! project URI), `textDocument/hover`,
//! `textDocument/completion` (form-head and key contexts driven by the
//! loaded schema), `textDocument/signatureHelp` (form keys / typed
//! expr-func params with cursor-driven active parameter),
//! `textDocument/definition` and `textDocument/declaration` (one cross-ref
//! resolution; declaration is an exact alias),
//! `textDocument/documentSymbol`,
//! `textDocument/foldingRange` (one fold per multi-line form/vector),
//! `textDocument/inlayHint` (plugin-source ghost text on bare form
//! heads, `core` excluded),
//! `textDocument/semanticTokens/full` (schema-resolved heads, keys,
//! members, and cross-ref names; `full` only),
//! `textDocument/formatting`, `textDocument/codeAction` (quickfixes
//! for `unknown_form`/`unknown_key` via Levenshtein nearest-name), and
//! `textDocument/didSave` and `workspace/didChangeWatchedFiles` (both
//! reread saved configuration/manifest bytes, rebuild affected contexts
//! transactionally, and publish or refresh diagnostics), and
//! `workspace/diagnostic` (enumerates `**/*.sjon` under the workspace
//! root and reports on-disk files alongside open buffers — native only,
//! since the handler owns no filesystem).

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const sjon = @import("sjon");
const sjon_version = sjon.version;
const uri = @import("uri");
const discovery = @import("discovery");
const context_registry = @import("context_registry");
const workspace_scan = @import("workspace_scan");
const text_sync = @import("text_sync");

const Allocator = std.mem.Allocator;

/// The one inferred error set left in this file, deliberately: everything
/// fallible here belongs to `lsp.basic_server.run`, whose own set is
/// inferred through the server type it is instantiated with, so there is
/// no name to write down. Zig's entry point is also the one place a wide
/// set costs nothing — the runtime reports it and exits. Every method on
/// `Server` below is annotated, because those are ours.
pub fn main(init: std.process.Init) !void {
    var read_buffer: [4096]u8 = undefined;
    var stdio_transport: lsp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());
    const transport: *lsp.Transport = &stdio_transport.transport;

    var server: Server = .init(init.gpa, init.io, transport);
    defer server.deinit();

    // `run` builds its message type by looking every declaration of
    // `Server` up in lsp-kit's two method-name tables, and at comptime each
    // candidate key and each byte compared is a backward branch. `Server`
    // has enough declarations that the lookups pass the 1000 branches an
    // evaluation gets by default, and the quota cannot be raised from
    // here, because `run` is analysed as its own function body with its own
    // count. A comptime call is memoized on its arguments, though, so the
    // same lookups are made here first under a raised quota, and `run` then
    // finds every answer cached and spends nothing on it.
    //
    // This stands in for a `@setEvalBranchQuota` inside lsp-kit's
    // `MessageType`, which upstream does not have. If it ever stops
    // covering the lookups, the build fails with "evaluation exceeded 1000
    // backwards branches" pointing into `basic_server.zig`.
    comptime {
        @setEvalBranchQuota(20_000);
        for (std.meta.declarations(Server)) |decl| {
            _ = lsp.isRequestMethod(decl.name);
            _ = lsp.isNotificationMethod(decl.name);
        }
    }

    try lsp.basic_server.run(init.io, init.gpa, transport, &server, std.log.err);
}

/// How this connection wants unsolicited diagnostics delivered. Selected
/// once at `initialize`: the presence of `textDocument.diagnostic` means
/// the client implements the pull model, and everything else falls back
/// to the push model (`textDocument/publishDiagnostics`). The pull
/// methods stay advertised and answerable in either mode; this enum only
/// governs unsolicited delivery.
const DiagnosticMode = enum { push, pull };

/// lsp-kit-typed dispatcher. Holds the offset encoding negotiated during
/// `initialize` and forwards every other method to `Handler`. Also keeps
/// the `transport` so server-initiated requests (`client/registerCapability`,
/// `workspace/diagnostic/refresh`) can be sent without going through
/// `basic_server.run`.
pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: *lsp.Transport,
    /// Owns every open buffer and every schema context this connection can
    /// route. There is no singleton document handler.
    registry: context_registry.Registry,
    offset_encoding: lsp.offsets.Encoding,
    /// Whether the client accepts `WorkspaceEdit.documentChanges`, from
    /// `capabilities.workspace.workspaceEdit.documentChanges`. Only that
    /// form can carry a document version, and a client that doesn't
    /// understand it sees an edit with no `changes` and applies nothing —
    /// hence a capability check rather than always sending the better shape.
    client_document_changes: bool,
    /// Monotonic counter for server-initiated request IDs. Wraps at u31
    /// to stay inside the LSP spec's signed-32-bit range.
    next_request_id: u31,
    /// Push or pull for this connection, from `initialize` capabilities.
    diagnostic_mode: DiagnosticMode,
    /// Whether push reports may carry `version`, from
    /// `textDocument.publishDiagnostics.versionSupport`. Always false in
    /// pull mode: unsolicited reports are never sent there.
    client_publish_version: bool,
    /// Whether the active diagnostic capability object accepts
    /// `relatedInformation` — `textDocument.diagnostic` in pull mode,
    /// `textDocument.publishDiagnostics` in push mode. Optional fields
    /// are read from the object for the mode that will actually deliver
    /// them, so a client's push-only announcement cannot leak into pull.
    client_related_information: bool,
    /// Whether the active mode's `tagSupport.valueSet` contains LSP
    /// `DiagnosticTag.Deprecated` (2). False when `tagSupport` is absent,
    /// its `valueSet` is absent, or the set omits 2.
    client_deprecated_tag: bool,
    /// Whether the active mode's `codeDescriptionSupport` is true.
    client_code_description: bool,
    /// `workspace.didChangeWatchedFiles.dynamicRegistration orelse false`.
    /// Independent of diagnostic mode: it gates only whether this server
    /// asks the client to register the `.sjon` watcher.
    client_watcher_dynamic_registration: bool,
    /// `workspace.diagnostics.refreshSupport orelse false`. Recorded
    /// independently of mode (a push client may announce it), but used
    /// only when a pull connection asks for a refresh.
    client_diagnostic_refresh_support: bool,
    /// GPA-owned URIs of source reports confirmed for push. A report that
    /// moved or disappeared is cleared from its old URI; the list replaces
    /// the former single-project tracker now that one connection can hold
    /// several roots.
    pushed_source_uris: std.ArrayList([]const u8),
    /// Whether the client has sent `shutdown`. Once set, no unsolicited
    /// diagnostics may be serialized or written, whatever notification
    /// the loop reads before `exit` (the spec still delivers `exit`, and
    /// local state may be updated). Every push path funnels through
    /// `publishReport`, so that one guard covers open, change, close,
    /// reload, and project-source publication.
    shutdown_received: bool,
    /// Pending `client/registerCapability` request id for the broad
    /// `.sjon` watcher. `onResponse` clears it and records rejection once.
    watcher_registration_id: ?u31,
    /// Set after a rejected watcher registration. Watching is unavailable
    /// for the connection; the server neither retries nor polls.
    watcher_rejected: bool,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, transport: *lsp.Transport) Server {
        return .{
            .gpa = gpa,
            .io = io,
            .transport = transport,
            .registry = context_registry.Registry.init(gpa, io),
            .offset_encoding = .@"utf-16",
            .client_document_changes = false,
            .next_request_id = 1,
            .diagnostic_mode = .push,
            .client_publish_version = false,
            .client_related_information = false,
            .client_deprecated_tag = false,
            .client_code_description = false,
            .client_watcher_dynamic_registration = false,
            .client_diagnostic_refresh_support = false,
            .pushed_source_uris = .empty,
            .shutdown_received = false,
            .watcher_registration_id = null,
            .watcher_rejected = false,
        };
    }

    pub fn deinit(self: *Server) void {
        for (self.pushed_source_uris.items) |p| self.gpa.free(p);
        self.pushed_source_uris.deinit(self.gpa);
        self.registry.deinit();
    }

    pub fn initialize(
        self: *Server,
        arena: std.mem.Allocator,
        request: lsp.types.InitializeParams,
    ) lsp.types.InitializeResult {
        if (request.capabilities.general) |general| {
            for (general.positionEncodings orelse &.{}) |encoding| {
                self.offset_encoding = switch (encoding) {
                    .@"utf-8" => .@"utf-8",
                    .@"utf-16" => .@"utf-16",
                    .@"utf-32" => .@"utf-32",
                    .custom_value => continue,
                };
                break;
            }
        }
        if (request.capabilities.workspace) |ws| {
            if (ws.workspaceEdit) |we| self.client_document_changes = we.documentChanges orelse false;
        }

        // Diagnostic delivery mode is a property of the connection, not of
        // the workspace: an empty `textDocument.diagnostic` object still
        // selects pull, and `dynamicRegistration` says nothing about
        // whether the client can answer a pull. Record it before the
        // project load so the first event after initialization already
        // uses the right mode. Optional diagnostic fields come from the
        // same object that owns the selected mode, so a flag announced
        // only for the other delivery model cannot leak across.
        if (request.capabilities.textDocument) |text_document| {
            if (text_document.diagnostic) |pull| {
                self.diagnostic_mode = .pull;
                self.client_publish_version = false;
                self.client_related_information = pull.relatedInformation orelse false;
                self.client_deprecated_tag = supportsDeprecatedTag(pull.tagSupport);
                self.client_code_description = pull.codeDescriptionSupport orelse false;
            } else if (text_document.publishDiagnostics) |push| {
                self.client_publish_version = push.versionSupport orelse false;
                self.client_related_information = push.relatedInformation orelse false;
                self.client_deprecated_tag = supportsDeprecatedTag(push.tagSupport);
                self.client_code_description = push.codeDescriptionSupport orelse false;
            }
        }

        // Watcher registration and refresh support are workspace-scoped
        // and independent of the diagnostic delivery mode: a push client
        // still needs the watcher to notice manifest edits. Refresh is
        // stored but only requested for pull connections.
        if (request.capabilities.workspace) |ws| {
            if (ws.didChangeWatchedFiles) |watched| {
                self.client_watcher_dynamic_registration =
                    watched.dynamicRegistration orelse false;
            }
            if (ws.diagnostics) |diagnostics| {
                self.client_diagnostic_refresh_support =
                    diagnostics.refreshSupport orelse false;
            }
        }

        // Schema discovery — retain every initialization workspace folder,
        // then let the registry discover an editor configuration or legacy
        // project per document. A root-level legacy project is loaded once
        // so its source report is available before any document is opened;
        // a root with `sjon-lsp.sjon` is left entirely to per-document
        // discovery and no sibling project is read eagerly.
        const folder_uris: []const []const u8 = blk: {
            const folders = request.workspaceFolders orelse break :blk &.{};
            const out = arena.alloc([]const u8, folders.len) catch
                break :blk &.{};
            for (folders, 0..) |folder, i| out[i] = folder.uri;
            break :blk out;
        };
        var roots: ?discovery.Roots = discovery.initializationRoots(
            arena,
            folder_uris,
            request.rootUri,
            request.rootPath,
        ) catch null;
        defer if (roots) |*value| value.deinit();
        if (roots) |value| {
            self.registry.configureRoots(value.items) catch |err| {
                std.log.warn("configureRoots failed: {s}", .{@errorName(err)});
            };
            for (value.items) |root| {
                self.registry.loadRootProject(root.path) catch |err| {
                    std.log.warn("loadRootProject failed: {s}", .{@errorName(err)});
                };
            }
        }

        const server_capabilities = serverCapabilities(self.offset_encoding);

        if (@import("builtin").mode == .Debug) {
            lsp.basic_server.validateServerCapabilities(Server, server_capabilities);
        }

        return .{
            .serverInfo = .{ .name = "sjon-lsp", .version = sjon_version },
            .capabilities = server_capabilities,
        };
    }

    pub fn initialized(self: *Server, arena: std.mem.Allocator, _: lsp.types.InitializedParams) void {
        // Push clients learn the project source's initial state from the
        // same report path a reload uses: an empty report for a clean
        // project, the real diagnostics for a broken one. Pull clients
        // ask for it directly and must not receive an unsolicited push.
        if (self.diagnostic_mode == .push) {
            self.syncProjectDiagnostics(arena) catch |err| {
                std.log.warn("syncProjectDiagnostics failed: {s}", .{@errorName(err)});
            };
        }

        // Ask the client to watch every `.sjon` file in the workspace, but
        // only when it announced dynamic registration for watched files.
        // The pattern is broad on purpose: it covers the project file,
        // every plugin manifest the project may reference now or later,
        // and any future `.sjon` file the user adds. Reload-on-change
        // is cheap (parse a few KB + revalidate cached docs).
        //
        // A rejected registration (for example a -32601 error response)
        // is delivered to `onResponse`, which marks watching unavailable and
        // logs once. It never becomes a reason to stop publishing or to
        // retry: diagnostics do not depend on the watcher.
        if (!self.client_watcher_dynamic_registration) return;
        self.registerSjonFileWatcher() catch |err| {
            std.log.warn("registerSjonFileWatcher failed: {s}", .{@errorName(err)});
        };
    }

    pub fn shutdown(self: *Server, _: std.mem.Allocator, _: void) ?void {
        // From here until `exit`, the loop can still deliver notifications
        // that mutate local state, but the client must receive no further
        // server-initiated diagnostics. Recorded rather than enforced here
        // so every push path inherits the rule at its one write point.
        self.shutdown_received = true;
        return null;
    }

    pub fn exit(_: *Server, _: std.mem.Allocator, _: void) void {}

    pub fn @"textDocument/didOpen"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.TextDocument.DidOpenParams,
    ) (Allocator.Error || lsp.Transport.WriteError)!void {
        _ = try self.registry.openDocument(
            params.textDocument.uri,
            params.textDocument.version,
            params.textDocument.text,
        );
        if (self.diagnostic_mode == .push) {
            try self.publishDocumentDiagnostics(arena, params.textDocument.uri);
        }
    }

    /// Adapts lsp-kit's offset converter to `text_sync`'s mapper
    /// contract, closing over the negotiated encoding. Deliberately
    /// `lsp.offsets` and not `src/lsp/offsets.zig`: this server reports
    /// every diagnostic and every navigation range through `lsp.offsets`,
    /// and computing edit offsets with a second converter would be a way
    /// for it to disagree with itself on the same document.
    ///
    /// Known limit inherited from that choice: lsp-kit counts lines by
    /// `\n` only, so a lone-`\r` document (classic Mac) is one line to this
    /// transport where the spec says many. `src/lsp/offsets.zig` handles
    /// all three terminators; the divergence stands because internal
    /// self-agreement matters more here than a terminator no editor that
    /// speaks LSP still writes, and it cannot be closed without patching a
    /// vendored dependency. CRLF is correct on both sides.
    const OffsetMapper = struct {
        encoding: lsp.offsets.Encoding,

        pub fn toIndex(self: OffsetMapper, source: []const u8, pos: text_sync.Position) usize {
            return lsp.offsets.positionToIndex(
                source,
                .{ .line = pos.line, .character = pos.character },
                self.encoding,
            );
        }
    };

    pub fn @"textDocument/didChange"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.TextDocument.DidChangeParams,
    ) (Handler.Error || lsp.Transport.WriteError)!void {
        // The splice needs the current text, so the lookup moves ahead of
        // `changeDocumentFull` — but it keeps raising the same error that
        // call used to, rather than turning a client protocol violation
        // into a silent no-op.
        const routed = self.routedDocument(params.textDocument.uri) orelse
            return error.UnknownDocument;
        const doc = routed.doc;

        // Collected and applied as one batch: an incremental change's
        // range is positioned against the text its predecessors in the
        // same notification produced, so they cannot be applied one at a
        // time against the stored document.
        const changes = try arena.alloc(text_sync.Change, params.contentChanges.len);
        for (params.contentChanges, changes) |change, *slot| {
            slot.* = switch (change) {
                .text_document_content_change_whole_document => |whole| .{
                    .range = null,
                    .text = whole.text,
                },
                .text_document_content_change_partial => |partial| .{
                    .range = .{
                        .start = .{
                            .line = partial.range.start.line,
                            .character = partial.range.start.character,
                        },
                        .end = .{
                            .line = partial.range.end.line,
                            .character = partial.range.end.character,
                        },
                    },
                    .text = partial.text,
                },
            };
        }
        // An empty batch is a successful change, not a no-op: the client
        // has supplied a new version, and reports must carry the version
        // actually validated. `applyChanges` returns the unchanged text,
        // so this republishes the same diagnostic set at the new version.
        const merged = try text_sync.applyChanges(
            arena,
            doc.source,
            changes,
            OffsetMapper{ .encoding = self.offset_encoding },
        );

        // One reparse for the batch, not one per change. The registry
        // re-associates the buffer when a declaration changes its context.
        _ = try self.registry.changeDocumentFull(
            params.textDocument.uri,
            params.textDocument.version,
            merged,
        );
        if (self.diagnostic_mode == .push) {
            try self.publishDocumentDiagnostics(arena, params.textDocument.uri);
        }
    }

    /// `includeText` is advertised false, so the optional `params.text` is
    /// ignored even when a client sends it. Saved disk bytes are the
    /// authority for configuration, projects, and manifests.
    pub fn @"textDocument/didSave"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.TextDocument.DidSaveParams,
    ) (Allocator.Error || lsp.Transport.WriteError)!void {
        try self.applySavedInputs(arena, &.{.{
            .uri = params.textDocument.uri,
            .kind = .changed,
        }});
    }

    pub fn @"textDocument/didClose"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.TextDocument.DidCloseParams,
    ) (Allocator.Error || lsp.Transport.WriteError)!void {
        // Capture the last version before the buffer disappears: the
        // empty clear must be attributed to the report it supersedes, or
        // a version-aware client keeps the old report as "current".
        const document_uri = params.textDocument.uri;
        const version: ?i32 = if (self.diagnostic_mode == .push and self.client_publish_version)
            if (self.registry.route(document_uri)) |route|
                if (route.handler.getDocument(document_uri)) |doc| lspVersion(doc.version) else null
            else
                null
        else
            null;

        self.registry.closeDocument(document_uri);

        if (self.diagnostic_mode == .push) {
            // Closing a dirty source discards the live overlay. If a saved
            // input still owns a report for this URI, restore it; otherwise
            // the report is genuinely gone and clears.
            if (try self.registry.savedSourceReportFor(arena, document_uri)) |saved| {
                const items = try self.diagnosticItems(arena, saved.source, saved.diagnostics);
                try self.publishReport(document_uri, version, items);
            } else {
                try self.publishReport(document_uri, version, &.{});
            }
        }
    }

    pub fn @"workspace/didChangeWatchedFiles"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.workspace.did_change_watched_files.Params,
    ) (Allocator.Error || lsp.Transport.WriteError)!void {
        // One broad registration covers every `.sjon` file. Only selected
        // markers and known configured dependencies are allowed to trigger
        // reload work; a wholly new marker takes effect after restart.
        var changes: std.ArrayList(context_registry.FileChange) = .empty;
        for (params.changes) |event| {
            if (!try self.registry.isKnownInputUri(arena, event.uri)) continue;
            try changes.append(arena, .{
                .uri = event.uri,
                .kind = switch (event.type) {
                    .Created => .created,
                    .Changed => .changed,
                    .Deleted => .deleted,
                    else => continue,
                },
            });
        }

        try self.applySavedInputs(arena, changes.items);
    }

    /// Shared saved-input transaction for `didSave` and watched events.
    /// Legacy projects retain their broad re-read behavior — inside the
    /// same transactional rebuild as configured contexts — and publish the
    /// open-document and project-source reports; configured contexts
    /// rebuild only from known inputs and publish old/new affected URIs so
    /// recovery clears stale source reports. Any failure keeps every old
    /// context (legacy and configured alike) and publishes nothing.
    fn applySavedInputs(
        self: *Server,
        arena: std.mem.Allocator,
        changes: []const context_registry.FileChange,
    ) (Allocator.Error || lsp.Transport.WriteError)!void {
        const legacy = self.registry.hasLegacyContexts();

        // `reloadSavedInputs` re-reads legacy projects into the replacement
        // registry and swaps only when every step succeeded, so a failure
        // anywhere in the reload — including between two legacy roots —
        // leaves the old registry complete and nothing is published.
        const result = self.registry.reloadSavedInputs(arena, changes) catch |err| switch (err) {
            error.OutOfMemory => {
                // OOM is internal: retain the old contexts and do not publish
                // an empty success report.
                std.log.warn("saved-input reload ran out of memory; retaining old contexts", .{});
                return;
            },
        };

        if (!result.changed and !legacy) return;

        switch (self.diagnostic_mode) {
            .push => {
                if (result.changed) {
                    try self.publishAffected(arena, result.old_uris, result.new_uris);
                }
                if (legacy) {
                    try self.publishOpenDiagnostics(arena);
                    try self.syncProjectDiagnostics(arena);
                }
            },
            .pull => {
                // Only a client that announced refresh support can act on
                // this; one without it gets the new state on its next pull,
                // whose result IDs changed with the generation.
                if (!self.client_diagnostic_refresh_support) return;
                if (!result.changed and !legacy) return;
                self.requestDiagnosticRefresh() catch |err| {
                    std.log.warn("workspace/diagnostic/refresh failed: {s}", .{@errorName(err)});
                };
            },
        }
    }

    pub fn @"textDocument/diagnostic"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.document_diagnostic.Params,
    ) Allocator.Error!lsp.types.document_diagnostic.Report {
        const empty: lsp.types.document_diagnostic.Report = .{
            .related_full_document_diagnostic_report = .{
                .items = &.{},
                .resultId = null,
                .relatedDocuments = null,
            },
        };

        // Project source diagnostics: a loaded legacy project is a source
        // route, not an ordinary document. This answers a pull on
        // `sjon-project.sjon` even when the editor never opened it.
        if (try self.registry.projectSourceFor(arena, params.textDocument.uri)) |project| {
            return .{
                .related_full_document_diagnostic_report = .{
                    .items = try self.diagnosticItems(arena, project.source, project.diagnostics),
                    .resultId = null,
                    .relatedDocuments = null,
                },
            };
        }

        // A selected configuration or manifest that is not open still owns
        // its saved-byte report. Pull may ask for it directly.
        if (self.registry.documentFor(params.textDocument.uri) == null) {
            if (try self.registry.savedSourceReportFor(arena, params.textDocument.uri)) |saved| {
                return .{
                    .related_full_document_diagnostic_report = .{
                        .items = try self.diagnosticItems(arena, saved.source, saved.diagnostics),
                        .resultId = null,
                        .relatedDocuments = null,
                    },
                };
            }
            return empty;
        }

        const routed = self.routedDocument(params.textDocument.uri) orelse return empty;
        const doc = routed.doc;

        // The Handler owns the one result-id scheme: `<doc_version>:
        // <schema_generation>` on the legacy path, prefixed with the
        // context identity when this handler serves a native schema
        // context. Both halves still matter: a doc edit bumps the version,
        // a manifest/project-file edit bumps the generation, and a context
        // move changes the prefix.
        const current_id = try routed.route.handler.diagnosticResultId(arena, doc);
        if (params.previousResultId) |prev| {
            if (std.mem.eql(u8, prev, current_id)) {
                return .{
                    .related_unchanged_document_diagnostic_report = .{
                        .resultId = current_id,
                        .relatedDocuments = null,
                    },
                };
            }
        }

        const handler_diags = (try routed.route.handler.getDiagnostics(arena, params.textDocument.uri)) orelse &.{};
        const items = try self.documentDiagnosticItems(
            arena,
            params.textDocument.uri,
            doc.source,
            handler_diags,
        );

        return .{
            .related_full_document_diagnostic_report = .{
                .items = items,
                .resultId = current_id,
                .relatedDocuments = null,
            },
        };
    }

    /// Workspace-wide pull diagnostics. Re-enumerates the workspace on
    /// every call so a file edited outside the editor is picked up: the
    /// handler holds parsed copies, and nothing else would refresh them.
    ///
    /// Reports open buffers alongside on-disk files. Both share one cache
    /// key scheme with `textDocument/diagnostic`, so a client pulling
    /// both cannot be told two different things about one file.
    pub fn @"workspace/diagnostic"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.workspace.diagnostic.Params,
    ) Allocator.Error!lsp.types.workspace.diagnostic.Report {
        const limits: workspace_scan.WorkspaceLimits = .{};
        var scan_budget = workspace_scan.Budget.init(limits.max_scan_entries);
        var scanned: std.ArrayList(Handler.WorkspaceFile) = .empty;
        var scan_stopped = false;
        for (self.registry.roots) |root| {
            const scan = workspace_scan.collectWithBudget(
                arena,
                self.io,
                root.path,
                &scan_budget,
            ) catch workspace_scan.Scan{ .files = &.{}, .stopped_early = false };
            scan_stopped = scan_stopped or scan.stopped_early;
            try scanned.appendSlice(arena, scan.files);
        }
        if (scan_stopped) {
            std.log.warn(
                "workspace scan stopped at {d} shared entries; some files were not examined",
                .{limits.max_scan_entries},
            );
        }

        // One global sort and one never-open budget across every root and
        // context. The registry keeps reference scope per handler; this
        // merge only decides which bytes each handler holds.
        const ingest = self.registry.ingestWorkspaceFiles(scanned.items, limits) catch |err| blk: {
            std.log.warn("workspace ingestion failed: {s}", .{@errorName(err)});
            break :blk Handler.WorkspaceIngest{ .ingested = 0, .clipped = 0 };
        };
        if (ingest.clipped > 0) {
            std.log.warn(
                "workspace ingestion clipped {d} files at the shared {d}-file limit",
                .{ ingest.clipped, limits.max_files },
            );
        }

        const reports = try self.registry.workspaceReports(arena);
        const projects = try self.registry.projectSources(arena);

        // Both slices are sorted by URI; insert each project source at its
        // first greater document URI so the output stays ordered without a
        // second sort. A project URI that is also an open buffer is replaced
        // by the project's own source report rather than duplicated.
        var items: std.ArrayList(lsp.types.workspace.diagnostic.Report.Document) = .empty;
        try items.ensureTotalCapacityPrecise(arena, reports.len + projects.len);
        var project_index: usize = 0;
        for (reports) |r| {
            while (project_index < projects.len and
                std.mem.lessThan(u8, projects[project_index].uri, r.uri))
            {
                try self.appendProjectSourceReport(arena, &items, projects[project_index]);
                project_index += 1;
            }
            if (project_index < projects.len and
                uri.HashContext.eql(.{}, projects[project_index].uri, r.uri))
            {
                try self.appendProjectSourceReport(arena, &items, projects[project_index]);
                project_index += 1;
                continue;
            }

            const source = if (self.registry.documentFor(r.uri)) |doc| doc.source else continue;
            const version: ?i32 = if (r.version) |v| @intCast(v) else null;

            // An id the client already holds means the document has not
            // changed since it last saw it — send the marker, not the
            // items, which is the whole point of the pull model.
            if (previousResultId(params.previousResultIds, r.uri)) |prev| {
                if (std.mem.eql(u8, prev, r.result_id)) {
                    items.appendAssumeCapacity(.{ .workspace_unchanged_document_diagnostic_report = .{
                        .uri = r.uri,
                        .version = version,
                        .resultId = r.result_id,
                    } });
                    continue;
                }
            }

            items.appendAssumeCapacity(.{ .workspace_full_document_diagnostic_report = .{
                .uri = r.uri,
                .version = version,
                .resultId = r.result_id,
                .items = try self.documentDiagnosticItems(
                    arena,
                    r.uri,
                    source,
                    r.diagnostics,
                ),
            } });
        }
        while (project_index < projects.len) : (project_index += 1) {
            try self.appendProjectSourceReport(arena, &items, projects[project_index]);
        }

        // Saved configuration and manifest reports join the same stable URI
        // order. A URI already represented by a document/project report is
        // skipped: that report already merged its saved contribution.
        const sources = try self.registry.savedSourceReports(arena);
        for (sources) |source_report| {
            if (containsWorkspaceReport(items.items, source_report.uri)) continue;
            try items.append(arena, .{ .workspace_full_document_diagnostic_report = .{
                .uri = source_report.uri,
                .version = null,
                .resultId = null,
                .items = try self.diagnosticItems(
                    arena,
                    source_report.source,
                    source_report.diagnostics,
                ),
            } });
        }
        std.mem.sort(lsp.types.workspace.diagnostic.Report.Document, items.items, {}, struct {
            fn lt(
                _: void,
                a: lsp.types.workspace.diagnostic.Report.Document,
                b: lsp.types.workspace.diagnostic.Report.Document,
            ) bool {
                return std.mem.lessThan(u8, workspaceDocumentUri(a), workspaceDocumentUri(b));
            }
        }.lt);
        return .{ .items = items.items };
    }

    /// Append the project source's complete report as a direct workspace
    /// diagnostic document. `version` is null: the project file is not an
    /// editor buffer, so there is no client version to echo, and
    /// `resultId` stays null so the client always gets the full source
    /// report.
    fn appendProjectSourceReport(
        self: *Server,
        arena: Allocator,
        items: *std.ArrayList(lsp.types.workspace.diagnostic.Report.Document),
        project: context_registry.ProjectSource,
    ) Allocator.Error!void {
        try items.append(arena, .{ .workspace_full_document_diagnostic_report = .{
            .uri = project.uri,
            .version = null,
            .resultId = null,
            .items = try self.diagnosticItems(arena, project.source, project.diagnostics),
        } });
    }

    fn previousResultId(
        previous: []const lsp.types.PreviousResultId,
        doc_uri: []const u8,
    ) ?[]const u8 {
        for (previous) |p| {
            if (std.mem.eql(u8, p.uri, doc_uri)) return p.value;
        }
        return null;
    }

    /// Map Handler diagnostics onto lsp-kit's `Diagnostic`, resolving
    /// byte spans against `source` in the negotiated encoding.
    ///
    /// Shared by `textDocument/diagnostic` and `textDocument/codeAction`:
    /// a quickfix's `diagnostics` must be byte-identical to what the
    /// pull-diagnostics response published, or the client cannot match
    /// the two. One mapping is how that stays true.
    fn diagnosticItems(
        self: *Server,
        arena: std.mem.Allocator,
        source: []const u8,
        diags: []const Handler.Diagnostic,
    ) Allocator.Error![]const lsp.types.Diagnostic {
        const items = try arena.alloc(lsp.types.Diagnostic, diags.len);
        for (diags, 0..) |d, i| {
            items[i] = .{
                .range = .{
                    .start = lsp.offsets.indexToPosition(source, d.span_start, self.offset_encoding),
                    .end = lsp.offsets.indexToPosition(source, d.span_end, self.offset_encoding),
                },
                .severity = switch (d.severity) {
                    .err => .Error,
                    .warning => .Warning,
                    .hint => .Hint,
                },
                .code = .{ .string = d.code },
                // Optional-field capability filtering happens here, once,
                // for push, document pull, workspace pull, and quick-fix
                // attachments. A client that did not announce a field
                // must not receive it, and the quick fix must be
                // byte-identical to the report that carried its
                // diagnostic.
                // Editor-local source reports carry no documentation link;
                // an empty href is the one honest "no page" value.
                .codeDescription = if (self.client_code_description and d.code_href.len != 0)
                    .{ .href = d.code_href }
                else
                    null,
                .source = if (std.mem.startsWith(u8, d.code, "sjon-lsp/")) "sjon-lsp" else "sjon",
                .message = d.message,
                .tags = try self.diagnosticTags(arena, d.tags),
                .relatedInformation = if (self.client_related_information)
                    try self.relatedInformation(arena, d.related)
                else
                    null,
            };
        }
        return items;
    }

    /// Translate one document's cached diagnostics, then append the
    /// native project-failure indicator when the workspace schema failed
    /// to load. Document push, document pull, and workspace pull all use
    /// this so an open file shows the actionable failure even when the
    /// user never opens `sjon-project.sjon`.
    ///
    /// The indicator is built as a transport-neutral `Handler.Diagnostic`
    /// and translated through `diagnosticItems`, so its optional fields
    /// obey the same connection capabilities as every other item. It is
    /// deliberately absent from `Handler` and the WASM transport.
    fn documentDiagnosticItems(
        self: *Server,
        arena: std.mem.Allocator,
        document_uri: []const u8,
        source: []const u8,
        diags: []const Handler.Diagnostic,
    ) Allocator.Error![]const lsp.types.Diagnostic {
        var items: std.ArrayList(lsp.types.Diagnostic) = .empty;
        try self.appendUniqueDiagnostics(
            arena,
            &items,
            try self.diagnosticItems(arena, source, diags),
        );

        // Editor-local failures are native-only and carry no documentation
        // link. They join the same report as the handler's parse diagnostics,
        // so an unavailable context cannot look clean while its schema is
        // missing.
        const editor = try self.registry.editorDiagnostics(arena, document_uri);
        try self.appendUniqueDiagnostics(
            arena,
            &items,
            try self.editorDiagnosticItems(arena, editor),
        );

        // An open saved source combines its live parse report with the
        // saved-byte source report. The registry suppresses this contribution
        // when the buffer differs from disk, so no span from one byte stream
        // is ever rendered against the other.
        if (try self.registry.savedSourceReportFor(arena, document_uri)) |saved| {
            try self.appendUniqueDiagnostics(
                arena,
                &items,
                try self.diagnosticItems(arena, saved.source, saved.diagnostics),
            );
        }

        const handler = self.registry.handlerFor(document_uri) orelse return items.items;
        const proj = handler.getProjectInfo() orelse return items.items;
        // A workspace with no project file is core-only by design, not a
        // schema-loading failure: the indicator is for a project that was
        // discovered and then failed to load.
        if (proj.project_uri == null or !proj.hasErrors()) return items.items;

        const indicator = try self.diagnosticItems(arena, source, &.{.{
            .span_start = 0,
            .span_end = 0,
            .severity = .err,
            .code = @tagName(sjon.Ast.Diagnostic.Code.unspecified),
            .message = "workspace schema loading failed; see sjon-project.sjon diagnostics",
            .code_href = Handler.codeHref(.unspecified),
        }});
        try self.appendUniqueDiagnostics(arena, &items, indicator);
        return items.items;
    }

    fn appendUniqueDiagnostics(
        self: *Server,
        arena: Allocator,
        items: *std.ArrayList(lsp.types.Diagnostic),
        candidates: []const lsp.types.Diagnostic,
    ) Allocator.Error!void {
        _ = self;
        for (candidates) |candidate| {
            var duplicate = false;
            for (items.items) |existing| {
                if (existing.range.start.line != candidate.range.start.line or
                    existing.range.start.character != candidate.range.start.character or
                    existing.range.end.line != candidate.range.end.line or
                    existing.range.end.character != candidate.range.end.character or
                    existing.severity != candidate.severity or
                    !std.mem.eql(u8, existing.source orelse "", candidate.source orelse "") or
                    !std.mem.eql(u8, existing.message, candidate.message))
                {
                    continue;
                }
                if (sameDiagnosticCode(existing.code, candidate.code)) duplicate = true;
            }
            if (!duplicate) try items.append(arena, candidate);
        }
    }

    /// Map editor-local diagnostics onto lsp-kit's `Diagnostic`. They use
    /// `source = "sjon-lsp"` and deliberately omit `codeDescription`: their
    /// strings are not `Ast.Diagnostic.Code` variants and have no
    /// `sjon explain` page to point at.
    fn editorDiagnosticItems(
        self: *Server,
        arena: std.mem.Allocator,
        diags: []const context_registry.EditorDiagnostic,
    ) Allocator.Error![]const lsp.types.Diagnostic {
        const items = try arena.alloc(lsp.types.Diagnostic, diags.len);
        for (diags, 0..) |d, i| {
            const source = self.editorSource(d.uri);
            items[i] = .{
                .range = .{
                    .start = lsp.offsets.indexToPosition(source, d.span.start, self.offset_encoding),
                    .end = lsp.offsets.indexToPosition(source, d.span.end, self.offset_encoding),
                },
                .severity = switch (d.severity) {
                    .err => .Error,
                    .warning => .Warning,
                },
                .code = .{ .string = d.code },
                .codeDescription = null,
                .source = "sjon-lsp",
                .message = d.message,
                .tags = null,
                .relatedInformation = if (self.client_related_information)
                    try self.editorRelatedInformation(arena, d.related)
                else
                    null,
            };
        }
        return items;
    }

    /// Source bytes for an editor-local diagnostic's primary URI. A marker
    /// or known source may not be open, but the registry still holds the
    /// document (source route) when it does. Falling back to an empty slice
    /// keeps byte-zero locations well-defined without inventing text.
    fn editorSource(self: *Server, document_uri: []const u8) []const u8 {
        if (self.registry.documentFor(document_uri)) |doc| return doc.source;
        return "";
    }

    fn editorRelatedInformation(
        self: *Server,
        arena: std.mem.Allocator,
        related: []const context_registry.EditorRelated,
    ) Allocator.Error!?[]const lsp.types.Diagnostic.RelatedInformation {
        if (related.len == 0) return null;
        var out: std.ArrayList(lsp.types.Diagnostic.RelatedInformation) = .empty;
        for (related) |r| {
            const doc = self.registry.documentFor(r.uri) orelse continue;
            try out.append(arena, .{
                .location = .{
                    .uri = r.uri,
                    .range = .{
                        .start = lsp.offsets.indexToPosition(doc.source, r.span.start, self.offset_encoding),
                        .end = lsp.offsets.indexToPosition(doc.source, r.span.end, self.offset_encoding),
                    },
                },
                .message = r.message,
            });
        }
        if (out.items.len == 0) return null;
        return out.items;
    }

    /// Serialize one complete `textDocument/publishDiagnostics` report
    /// and write it through the connection's transport.
    ///
    /// Every push path funnels through here so the notification name,
    /// parameter shape, and null-optional handling exist once. The
    /// diagnostics slice and URI live in the caller's request arena and
    /// are serialized synchronously before it is released.
    ///
    /// A client that has sent `shutdown` must not receive this
    /// notification again. Returning before serialization is the one
    /// guard the document, project, close, and reload paths all inherit.
    fn publishReport(
        self: *Server,
        document_uri: []const u8,
        version: ?i32,
        diagnostics: []const lsp.types.Diagnostic,
    ) (Allocator.Error || lsp.Transport.WriteError)!void {
        if (self.shutdown_received) return;
        try self.transport.writeNotification(
            self.io,
            self.gpa,
            "textDocument/publishDiagnostics",
            lsp.types.publish_diagnostics.Params,
            .{
                .uri = document_uri,
                .version = version,
                .diagnostics = diagnostics,
            },
            .{ .emit_null_optional_fields = false },
        );
    }

    /// Publish the complete current report for one open document. The
    /// Handler's cached validation is reused: push never re-validates and
    /// never builds a delta, so the editor's set is exactly the set a
    /// pull of the same URI would return.
    fn publishDocumentDiagnostics(
        self: *Server,
        arena: Allocator,
        document_uri: []const u8,
    ) (Allocator.Error || lsp.Transport.WriteError)!void {
        const route = self.registry.route(document_uri) orelse return;
        const doc = route.handler.getDocument(document_uri) orelse return;
        const handler_diags = (try route.handler.getDiagnostics(arena, document_uri)) orelse return;
        const items = try self.documentDiagnosticItems(arena, document_uri, doc.source, handler_diags);

        // Report the version actually validated. A version LSP's signed
        // 32-bit `integer` cannot represent is omitted rather than
        // wrapped or replaced with a newer one.
        const version: ?i32 = if (self.client_publish_version) lspVersion(doc.version) else null;
        try self.publishReport(document_uri, version, items);
    }

    /// Publish every open document's complete report, in stable URI order.
    /// Workspace-ingested files (`version == null`) are skipped: push after
    /// a reload covers open buffers plus the project sources, not every file
    /// on disk.
    fn publishOpenDiagnostics(
        self: *Server,
        arena: Allocator,
    ) (Allocator.Error || lsp.Transport.WriteError)!void {
        const routes = try self.registry.documentRoutes(arena);
        for (routes) |entry| {
            const doc = entry.route.handler.getDocument(entry.uri) orelse continue;
            if (doc.origin != .open) continue;
            const handler_diags = (try entry.route.handler.getDiagnostics(arena, entry.uri)) orelse continue;
            const items = try self.documentDiagnosticItems(arena, entry.uri, doc.source, handler_diags);
            const version: ?i32 = if (self.client_publish_version)
                lspVersion(doc.version)
            else
                null;
            try self.publishReport(entry.uri, version, items);
        }
    }

    /// Publish the current report for every URI a saved-input transaction
    /// contributed to, then clear every superseded URI that the new state no
    /// longer contains. This is plan 01's full-report producer attached to
    /// the reload transaction; push never sends a delta.
    fn publishAffected(
        self: *Server,
        arena: Allocator,
        old_uris: []const []const u8,
        new_uris: []const []const u8,
    ) (Allocator.Error || lsp.Transport.WriteError)!void {
        for (new_uris) |document_uri| {
            try self.publishUriReport(arena, document_uri);
        }
        for (old_uris) |document_uri| {
            if (containsUri(new_uris, document_uri)) continue;
            try self.publishReport(document_uri, null, &.{});
        }
    }

    fn publishUriReport(
        self: *Server,
        arena: Allocator,
        document_uri: []const u8,
    ) (Allocator.Error || lsp.Transport.WriteError)!void {
        if (self.registry.documentFor(document_uri)) |doc| {
            const handler = self.registry.handlerFor(document_uri) orelse return;
            const handler_diags = (try handler.getDiagnostics(arena, document_uri)) orelse &.{};
            const items = try self.documentDiagnosticItems(
                arena,
                document_uri,
                doc.source,
                handler_diags,
            );
            const version: ?i32 = if (self.client_publish_version and doc.origin == .open)
                lspVersion(doc.version)
            else
                null;
            try self.publishReport(document_uri, version, items);
            return;
        }

        if (try self.registry.savedSourceReportFor(arena, document_uri)) |saved| {
            const items = try self.diagnosticItems(arena, saved.source, saved.diagnostics);
            try self.publishReport(document_uri, null, items);
            return;
        }

        if (try self.registry.projectSourceFor(arena, document_uri)) |project| {
            const items = try self.diagnosticItems(arena, project.source, project.diagnostics);
            try self.publishReport(document_uri, null, items);
            return;
        }

        try self.publishReport(document_uri, null, &.{});
    }

    /// Publish current project-source reports, including an empty report
    /// when a previously broken project recovers or disappears. Tracking is
    /// GPA-owned and changes only after a successful write: a failed
    /// serialization or transport write leaves the last confirmed URI in
    /// place so a later attempt can still clear it.
    fn syncProjectDiagnostics(
        self: *Server,
        arena: Allocator,
    ) (Allocator.Error || lsp.Transport.WriteError)!void {
        const projects = try self.registry.projectSources(arena);

        // A URI that disappeared must clear the report it used to own.
        // Compare decoded URIs: the loader rebuilds the string on every
        // reload, so pointer equality says nothing.
        var index: usize = 0;
        while (index < self.pushed_source_uris.items.len) {
            const old_uri = self.pushed_source_uris.items[index];
            var still_current = false;
            for (projects) |project| {
                if (uri.HashContext.eql(.{}, old_uri, project.uri)) {
                    still_current = true;
                    break;
                }
            }
            if (still_current) {
                index += 1;
                continue;
            }
            try self.publishReport(old_uri, null, &.{});
            self.gpa.free(old_uri);
            _ = self.pushed_source_uris.swapRemove(index);
        }

        for (projects) |project| {
            const items = try self.diagnosticItems(arena, project.source, project.diagnostics);
            try self.publishReport(project.uri, null, items);

            // Only now is the report confirmed. Reuse the tracking string
            // when the URI is unchanged; a reload rebuilds the Handler's
            // copy, so byte equality is the test.
            var tracked = false;
            for (self.pushed_source_uris.items) |existing| {
                if (uri.HashContext.eql(.{}, existing, project.uri)) {
                    tracked = true;
                    break;
                }
            }
            if (tracked) continue;
            const owned = try self.gpa.dupe(u8, project.uri);
            errdefer self.gpa.free(owned);
            try self.pushed_source_uris.append(self.gpa, owned);
        }
    }

    /// Map the Handler's related locations onto lsp-kit's
    /// `DiagnosticRelatedInformation`. Null (not `[]`) when empty, for
    /// the same reason `diagnosticTags` returns null.
    ///
    /// Each location's byte offsets resolve against **its own**
    /// document's source: a relation may point outside the diagnostic's
    /// document. One whose document isn't open is dropped rather than
    /// mapped against the wrong text — a wrong range looks right and
    /// sends the reader somewhere arbitrary.
    fn relatedInformation(
        self: *Server,
        arena: std.mem.Allocator,
        related: []const Handler.Diagnostic.Related,
    ) Allocator.Error!?[]const lsp.types.Diagnostic.RelatedInformation {
        if (related.len == 0) return null;
        var out: std.ArrayList(lsp.types.Diagnostic.RelatedInformation) = .empty;
        for (related) |r| {
            const doc = self.registry.documentFor(r.uri) orelse continue;
            out.append(arena, .{
                .location = .{
                    .uri = r.uri,
                    .range = .{
                        .start = lsp.offsets.indexToPosition(doc.source, r.span_start, self.offset_encoding),
                        .end = lsp.offsets.indexToPosition(doc.source, r.span_end, self.offset_encoding),
                    },
                },
                .message = r.message,
            }) catch |err| return err;
        }
        if (out.items.len == 0) return null;
        return out.items;
    }

    /// Map the Handler's transport-neutral tags onto lsp-kit's enum,
    /// filtering individually by the active mode's `tagSupport` set. Null
    /// (not an empty slice) when none survive — LSP treats an absent
    /// `tags` as "untagged", and some clients read `[]` as an explicit,
    /// if empty, tag set.
    ///
    /// The two enums agree numerically (both are the LSP wire values),
    /// but they are mapped variant-by-variant rather than bit-cast so a
    /// future tag can't silently mis-map. The capability check sits on
    /// the mapped value for the same reason: adding a tag to `Handler`
    /// makes the switch non-exhaustive here instead of announcing a tag
    /// the client never said it understands.
    fn diagnosticTags(
        self: *const Server,
        arena: std.mem.Allocator,
        tags: []const Handler.Diagnostic.Tag,
    ) Allocator.Error!?[]const lsp.types.Diagnostic.Tag {
        if (tags.len == 0) return null;
        var out: std.ArrayList(lsp.types.Diagnostic.Tag) = .empty;
        for (tags) |t| {
            const tag: lsp.types.Diagnostic.Tag = switch (t) {
                .deprecated => .Deprecated,
            };
            if (tag == .Deprecated and !self.client_deprecated_tag) continue;
            try out.append(arena, tag);
        }
        if (out.items.len == 0) return null;
        return out.items;
    }

    const RoutedDocument = struct {
        route: context_registry.Route,
        doc: *const Handler.Document,
    };

    /// The request URI's active context plus the document it holds. Null
    /// when the URI is not an open buffer or its route has no document.
    fn routedDocument(self: *Server, document_uri: []const u8) ?RoutedDocument {
        const route = self.registry.route(document_uri) orelse return null;
        const doc = route.handler.getDocument(document_uri) orelse return null;
        return .{ .route = route, .doc = doc };
    }

    /// Schema-dependent methods are refused for an unavailable association
    /// and for source routes. Parse-only features (formatting, folding,
    /// symbols, selection ranges) remain available through the same handler.
    fn schemaAvailable(route: context_registry.Route) bool {
        return route.state == .ready or route.state == .unconfigured;
    }

    pub fn @"textDocument/prepareRename"(
        self: *Server,
        _: std.mem.Allocator,
        params: lsp.types.prepare_rename.Params,
    ) Allocator.Error!?lsp.types.prepare_rename.Result {
        const routed = self.routedDocument(params.textDocument.uri) orelse return null;
        if (!schemaAvailable(routed.route)) return null;
        const doc = routed.doc;
        const offset = lsp.offsets.positionToIndex(doc.source, params.position, self.offset_encoding);
        const pre = routed.route.handler.prepareRename(params.textDocument.uri, @intCast(offset)) orelse return null;
        const start = lsp.offsets.indexToPosition(doc.source, pre.span_start, self.offset_encoding);
        const end = lsp.offsets.indexToPosition(doc.source, pre.span_end, self.offset_encoding);
        return .{ .range = .{ .start = start, .end = end } };
    }

    /// One file's edits plus the document version they were computed
    /// against.
    const EditTarget = struct {
        uri: []const u8,
        version: ?i32,
        edits: []const lsp.types.TextEdit,
    };

    /// The document version as LSP's signed 32-bit `integer`, or null when
    /// the client's own version doesn't fit. Null means "unknown", which is
    /// a legal answer and a better one than a wrapped number.
    fn lspVersion(v: i64) ?i32 {
        return std.math.cast(i32, v);
    }

    const DocumentChange = std.meta.Child(
        @typeInfo(@FieldType(lsp.types.WorkspaceEdit, "documentChanges")).optional.child,
    );
    const DocumentEditItem = std.meta.Child(@FieldType(lsp.types.TextDocument.Edit, "edits"));

    /// Wrap per-file edits in the best `WorkspaceEdit` shape this client
    /// accepts.
    ///
    /// The `changes` map cannot carry a version, so edits computed against
    /// the buffer as it stood at request time apply unconditionally to
    /// whatever it holds when the user clicks. Byte-anchored refactors are
    /// the sharp case: inline can delete a region that is no longer the
    /// definition. `documentChanges` stamps each file's version, and the
    /// client refuses a stale edit rather than applying it to wrong text.
    ///
    /// Gated on the capability rather than always sent, because a client
    /// that never announced `documentChanges` support sees an edit with no
    /// `changes` and applies nothing at all.
    fn workspaceEdit(
        self: *const Server,
        arena: std.mem.Allocator,
        files: []const EditTarget,
    ) std.mem.Allocator.Error!lsp.types.WorkspaceEdit {
        if (!self.client_document_changes) {
            var changes: lsp.parser.Map(lsp.types.DocumentUri, []const lsp.types.TextEdit) = .{};
            for (files) |f| try changes.map.put(arena, f.uri, f.edits);
            return .{ .changes = changes };
        }

        const doc_changes = try arena.alloc(DocumentChange, files.len);
        for (files, doc_changes) |f, *slot| {
            const items = try arena.alloc(DocumentEditItem, f.edits.len);
            for (f.edits, items) |e, *item| item.* = .{ .text_edit = e };
            slot.* = .{ .text_document_edit = .{
                .textDocument = .{ .uri = f.uri, .version = f.version },
                .edits = items,
            } };
        }
        return .{ .documentChanges = doc_changes };
    }

    pub fn @"textDocument/rename"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.rename.Params,
    ) Allocator.Error!?lsp.types.WorkspaceEdit {
        const routed = self.routedDocument(params.textDocument.uri) orelse return null;
        if (!schemaAvailable(routed.route)) return null;
        const doc = routed.doc;
        const offset = lsp.offsets.positionToIndex(doc.source, params.position, self.offset_encoding);
        const result = (try routed.route.handler.rename(
            arena,
            params.textDocument.uri,
            @intCast(offset),
            params.newName,
        )) orelse return null;

        const we = switch (result) {
            .err => |e| {
                // LSP allows a `ResponseError` here, but lsp-kit's typed
                // dispatcher maps a returned Zig error to a code and
                // `@errorName` — there is no way to attach the reason.
                // So the reason goes out as a `window/showMessage`
                // warning first, and the result is null, which editors
                // render as "no rename performed". The log line stays
                // for server-side tooling.
                std.log.info("rename rejected: {s}", .{e.message});
                self.transport.writeNotification(
                    self.io,
                    self.gpa,
                    "window/showMessage",
                    lsp.types.window.ShowMessageParams,
                    .{ .type = .Warning, .message = e.message },
                    .{ .emit_null_optional_fields = false },
                ) catch |err| std.log.warn("window/showMessage failed: {s}", .{@errorName(err)});
                return null;
            },
            .edits => |w| w,
        };

        // Translate `WorkspaceEdit { changes: []FileEdits }` → one
        // `EditTarget` per file, then let `workspaceEdit` pick the shape.
        const targets = try arena.alloc(EditTarget, we.changes.len);
        for (we.changes, targets) |fe, *target| {
            const ref_doc = self.registry.documentFor(fe.uri) orelse {
                // Document closed between revalidation and this request.
                // Empty edit list keeps the URI in the response as a benign
                // no-op, with no version to assert about a file we no longer
                // hold.
                target.* = .{ .uri = fe.uri, .version = null, .edits = &.{} };
                continue;
            };
            const text_edits = try arena.alloc(lsp.types.TextEdit, fe.edits.len);
            for (fe.edits, text_edits) |e, *text_edit| {
                const start = lsp.offsets.indexToPosition(ref_doc.source, e.span_start, self.offset_encoding);
                const end = lsp.offsets.indexToPosition(ref_doc.source, e.span_end, self.offset_encoding);
                text_edit.* = .{
                    .range = .{ .start = start, .end = end },
                    .newText = e.new_text,
                };
            }
            target.* = .{ .uri = fe.uri, .version = lspVersion(ref_doc.version), .edits = text_edits };
        }
        return try self.workspaceEdit(arena, targets);
    }

    /// The `Location` both navigation requests return: definition and
    /// declaration are one operation in SJON, because a cross-ref has one
    /// authored `:name` that serves both roles. `gD` therefore reuses this
    /// body rather than forking a second resolution path.
    fn crossRefLocation(
        self: *Server,
        document_uri: []const u8,
        position: lsp.types.Position,
    ) Allocator.Error!?lsp.types.Definition.Result {
        const routed = self.routedDocument(document_uri) orelse return null;
        if (!schemaAvailable(routed.route)) return null;
        const doc = routed.doc;
        const offset = lsp.offsets.positionToIndex(doc.source, position, self.offset_encoding);
        const loc = routed.route.handler.getDefinition(document_uri, @intCast(offset)) orelse return null;

        // Scope is per-tree: `Handler.getDefinition` never resolves across
        // documents (the LSP does not set `share_scope`), so `loc.uri` is
        // in practice the requesting one and a declaration in another file
        // is out of scope. It is still re-looked up by the `Location`'s own
        // URI for the byte→position conversion — the index is forest-wide
        // by construction — and a document closed since the last
        // revalidation drops the jump.
        const def_doc = self.registry.documentFor(loc.uri) orelse return null;
        const start = lsp.offsets.indexToPosition(def_doc.source, loc.span_start, self.offset_encoding);
        const end = lsp.offsets.indexToPosition(def_doc.source, loc.span_end, self.offset_encoding);
        return .{ .definition = .{ .location = .{
            .uri = loc.uri,
            .range = .{ .start = start, .end = end },
        } } };
    }

    /// Goto-definition. A cross-ref name resolves to exactly one
    /// definition in its scope, so this returns the scalar `Location`
    /// arm rather than a list or `LocationLink[]`.
    pub fn @"textDocument/definition"(
        self: *Server,
        _: std.mem.Allocator,
        params: lsp.types.Definition.Params,
    ) Allocator.Error!?lsp.types.Definition.Result {
        return self.crossRefLocation(params.textDocument.uri, params.position);
    }

    /// Goto-declaration. An exact alias of `textDocument/definition`: SJON
    /// has no forward declaration distinct from the definition, so `gD`
    /// answers with the same `Location` and the same nulls as `gd` instead
    /// of pretending the two roles differ.
    pub fn @"textDocument/declaration"(
        self: *Server,
        _: std.mem.Allocator,
        params: lsp.types.declaration.Params,
    ) Allocator.Error!?lsp.types.Definition.Result {
        return self.crossRefLocation(params.textDocument.uri, params.position);
    }

    /// Highlight every occurrence of the cross-ref name under the
    /// cursor. Single-document by protocol; the handler filters.
    pub fn @"textDocument/documentHighlight"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.DocumentHighlight.Params,
    ) Allocator.Error!?[]const lsp.types.DocumentHighlight {
        const routed = self.routedDocument(params.textDocument.uri) orelse return null;
        if (!schemaAvailable(routed.route)) return null;
        const doc = routed.doc;
        const offset = lsp.offsets.positionToIndex(doc.source, params.position, self.offset_encoding);
        const highlights = (try routed.route.handler.getDocumentHighlights(
            arena,
            params.textDocument.uri,
            @intCast(offset),
        )) orelse return null;

        const out = try arena.alloc(lsp.types.DocumentHighlight, highlights.len);
        for (highlights, out) |hl, *slot| {
            const start = lsp.offsets.indexToPosition(doc.source, hl.span_start, self.offset_encoding);
            const end = lsp.offsets.indexToPosition(doc.source, hl.span_end, self.offset_encoding);
            slot.* = .{
                .range = .{ .start = start, .end = end },
                // `Highlight.Kind` mirrors `DocumentHighlightKind`'s wire
                // values, so the tag converts by number, not by table.
                .kind = @enumFromInt(@intFromEnum(hl.kind)),
            };
        }
        return out;
    }

    pub fn @"textDocument/selectionRange"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.SelectionRange.Params,
    ) Allocator.Error!?[]const lsp.types.SelectionRange {
        const routed = self.routedDocument(params.textDocument.uri) orelse return null;
        const doc = routed.doc;

        const byte_offsets = try arena.alloc(u32, params.positions.len);
        for (params.positions, byte_offsets) |pos, *slot| {
            slot.* = @intCast(lsp.offsets.positionToIndex(doc.source, pos, self.offset_encoding));
        }

        const chains = (try routed.route.handler.getSelectionRanges(
            arena,
            params.textDocument.uri,
            byte_offsets,
        )) orelse return null;

        const out = try arena.alloc(lsp.types.SelectionRange, chains.len);
        for (chains, byte_offsets, out) |chain, offset, *slot| {
            if (chain.len == 0) {
                // Nothing encloses this offset (whitespace between top-level
                // forms): a zero-width range with no parent. The entry still
                // exists — LSP pairs results to `positions` by index.
                const at = lsp.offsets.indexToPosition(doc.source, offset, self.offset_encoding);
                slot.* = .{ .range = .{ .start = at, .end = at } };
                continue;
            }
            // `parent` is a pointer chain, so build outermost-first: each
            // link's parent is already allocated by the time it is needed.
            var parent: ?*const lsp.types.SelectionRange = null;
            var i = chain.len;
            while (i > 0) : (i -= 1) {
                const r = chain[i - 1];
                const node = try arena.create(lsp.types.SelectionRange);
                node.* = .{
                    .range = .{
                        .start = lsp.offsets.indexToPosition(doc.source, r.span_start, self.offset_encoding),
                        .end = lsp.offsets.indexToPosition(doc.source, r.span_end, self.offset_encoding),
                    },
                    .parent = parent,
                };
                parent = node;
            }
            // The loop ends on the innermost link — the one LSP wants at
            // the top of the result entry.
            slot.* = parent.?.*;
        }
        return out;
    }

    pub fn @"workspace/symbol"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.workspace.Symbol.Params,
    ) Allocator.Error!?lsp.types.workspace.Symbol.Result {
        const syms = try self.registry.workspaceSymbols(arena, params.query);

        var out: std.ArrayList(lsp.types.SymbolInformation) = .empty;
        for (syms) |sym| {
            // A definition can outlive its document in a stale index;
            // without the source there is no byte→position translation,
            // and the editor could not open the location anyway.
            const doc = self.registry.documentFor(sym.location.uri) orelse continue;
            const start = lsp.offsets.indexToPosition(doc.source, sym.location.span_start, self.offset_encoding);
            const end = lsp.offsets.indexToPosition(doc.source, sym.location.span_end, self.offset_encoding);
            try out.append(arena, .{
                .name = sym.name,
                // Same kind `documentSymbol` gives forms — one icon
                // across both pickers reads as one language.
                .kind = .Constructor,
                .containerName = sym.container_name,
                .location = .{
                    .uri = sym.location.uri,
                    .range = .{ .start = start, .end = end },
                },
            });
        }
        return .{ .symbol_informations = out.items };
    }

    pub fn @"textDocument/references"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.reference.Params,
    ) Allocator.Error!?[]const lsp.types.Location {
        const routed = self.routedDocument(params.textDocument.uri) orelse return null;
        if (!schemaAvailable(routed.route)) return null;
        const doc = routed.doc;
        const offset = lsp.offsets.positionToIndex(doc.source, params.position, self.offset_encoding);
        const refs = (try routed.route.handler.findReferences(
            arena,
            params.textDocument.uri,
            @intCast(offset),
            params.context.includeDeclaration,
        )) orelse return null;

        // Translate handler `Location[]` → `lsp.types.Location[]`. We look
        // each site up by its own URI, so a reference in a document held by
        // another context still converts in that document's encoding. A
        // site whose document closed between revalidation and the request
        // is dropped silently.
        var out: std.ArrayList(lsp.types.Location) = .empty;
        for (refs) |r| {
            const ref_doc = self.registry.documentFor(r.uri) orelse continue;
            const start = lsp.offsets.indexToPosition(ref_doc.source, r.span_start, self.offset_encoding);
            const end = lsp.offsets.indexToPosition(ref_doc.source, r.span_end, self.offset_encoding);
            try out.append(arena, .{
                .uri = r.uri,
                .range = .{ .start = start, .end = end },
            });
        }
        return try out.toOwnedSlice(arena);
    }

    pub fn @"textDocument/hover"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.Hover.Params,
    ) Allocator.Error!?lsp.types.Hover {
        const routed = self.routedDocument(params.textDocument.uri) orelse return null;
        if (!schemaAvailable(routed.route)) return null;
        const doc = routed.doc;
        const offset = lsp.offsets.positionToIndex(doc.source, params.position, self.offset_encoding);
        const hov = (try routed.route.handler.getHover(arena, params.textDocument.uri, @intCast(offset))) orelse return null;
        const start = lsp.offsets.indexToPosition(doc.source, hov.span_start, self.offset_encoding);
        const end = lsp.offsets.indexToPosition(doc.source, hov.span_end, self.offset_encoding);
        return .{
            .contents = .{ .markup_content = .{ .kind = .markdown, .value = hov.contents } },
            .range = .{ .start = start, .end = end },
        };
    }

    pub fn @"textDocument/completion"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.completion.Params,
    ) Allocator.Error!?lsp.types.completion.Result {
        const routed = self.routedDocument(params.textDocument.uri) orelse return null;
        if (!schemaAvailable(routed.route)) return null;
        const doc = routed.doc;
        const offset = lsp.offsets.positionToIndex(doc.source, params.position, self.offset_encoding);
        const items_or_null = try routed.route.handler.getCompletion(arena, params.textDocument.uri, @intCast(offset));
        const handler_items = items_or_null orelse return null;
        const out = try arena.alloc(lsp.types.completion.Item, handler_items.len);
        for (handler_items, 0..) |it, i| {
            // LSP `tags` is `?[]const CompletionItemTag` — only allocate
            // and map when the Handler item carries at least one.
            const lsp_tags: ?[]const lsp.types.completion.Item.Tag = blk: {
                if (it.tags.len == 0) break :blk null;
                const dst = try arena.alloc(lsp.types.completion.Item.Tag, it.tags.len);
                for (it.tags, 0..) |t, ti| dst[ti] = @enumFromInt(@intFromEnum(t));
                break :blk dst;
            };
            // `commitCharacters` is `?[]const []const u8` — one byte per
            // entry; map each commit char to its own one-element string.
            const lsp_commit: ?[]const []const u8 = blk: {
                if (it.commit_characters.len == 0) break :blk null;
                const dst = try arena.alloc([]const u8, it.commit_characters.len);
                for (it.commit_characters, 0..) |c, ci| dst[ci] = try arena.dupe(u8, &[_]u8{c});
                break :blk dst;
            };
            out[i] = .{
                .label = it.label,
                .kind = @enumFromInt(@intFromEnum(it.kind)),
                .detail = if (it.detail.len > 0) it.detail else null,
                .documentation = if (it.documentation.len > 0)
                    .{ .string = it.documentation }
                else
                    null,
                .insertText = it.insert_text,
                .insertTextFormat = if (it.insert_text != null)
                    @as(lsp.types.InsertTextFormat, @enumFromInt(@intFromEnum(it.insert_text_format)))
                else
                    null,
                .tags = lsp_tags,
                .sortText = it.sort_text,
                .filterText = it.filter_text,
                .textEdit = if (it.text_edit) |te| .{ .text_edit = .{
                    .range = .{
                        .start = lsp.offsets.indexToPosition(doc.source, te.span_start, self.offset_encoding),
                        .end = lsp.offsets.indexToPosition(doc.source, te.span_end, self.offset_encoding),
                    },
                    .newText = te.new_text,
                } } else null,
                .commitCharacters = lsp_commit,
            };
        }
        return .{ .completion_items = out };
    }

    pub fn @"textDocument/signatureHelp"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.SignatureHelp.Params,
    ) Allocator.Error!?lsp.types.SignatureHelp {
        const routed = self.routedDocument(params.textDocument.uri) orelse return null;
        if (!schemaAvailable(routed.route)) return null;
        const doc = routed.doc;
        const offset = lsp.offsets.positionToIndex(doc.source, params.position, self.offset_encoding);
        const help = (try routed.route.handler.getSignatureHelp(arena, params.textDocument.uri, @intCast(offset))) orelse return null;

        const sigs = try arena.alloc(lsp.types.SignatureHelp.Signature, help.signatures.len);
        for (help.signatures, 0..) |s, i| {
            const ps = try arena.alloc(lsp.types.SignatureHelp.Signature.Parameter, s.parameters.len);
            for (s.parameters, 0..) |p, j| {
                ps[j] = .{ .label = .{ .tuple_1 = .{ p.label_start, p.label_end } } };
            }
            sigs[i] = .{
                .label = s.label,
                .documentation = if (s.documentation.len > 0)
                    .{ .markup_content = .{ .kind = .markdown, .value = s.documentation } }
                else
                    null,
                .parameters = ps,
            };
        }
        return .{
            .signatures = sigs,
            .activeSignature = help.active_signature,
            .activeParameter = help.active_parameter,
        };
    }

    pub fn @"textDocument/documentSymbol"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.DocumentSymbol.Params,
    ) Allocator.Error!?lsp.types.DocumentSymbol.Result {
        const routed = self.routedDocument(params.textDocument.uri) orelse return null;
        const doc = routed.doc;
        const handler_syms = (try routed.route.handler.getDocumentSymbols(arena, params.textDocument.uri)) orelse return null;
        const out = try translateSymbols(arena, doc.source, self.offset_encoding, handler_syms);
        return .{ .document_symbols = out };
    }

    fn translateSymbols(
        arena: std.mem.Allocator,
        source: []const u8,
        encoding: lsp.offsets.Encoding,
        handler_syms: []const Handler.DocumentSymbol,
    ) std.mem.Allocator.Error![]const lsp.types.DocumentSymbol {
        const out = try arena.alloc(lsp.types.DocumentSymbol, handler_syms.len);
        for (handler_syms, 0..) |s, i| {
            const range_start = lsp.offsets.indexToPosition(source, s.span_start, encoding);
            const range_end = lsp.offsets.indexToPosition(source, s.span_end, encoding);
            const sel_start = lsp.offsets.indexToPosition(source, s.selection_start, encoding);
            const sel_end = lsp.offsets.indexToPosition(source, s.selection_end, encoding);
            const child_slice = try translateSymbols(arena, source, encoding, s.children);
            out[i] = .{
                .name = if (s.name.len > 0) s.name else "(anonymous)",
                .kind = .Constructor,
                .range = .{ .start = range_start, .end = range_end },
                .selectionRange = .{ .start = sel_start, .end = sel_end },
                .children = child_slice,
            };
        }
        return out;
    }

    pub fn @"textDocument/foldingRange"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.FoldingRange.Params,
    ) Allocator.Error!?[]const lsp.types.FoldingRange {
        const routed = self.routedDocument(params.textDocument.uri) orelse return null;
        const doc = routed.doc;
        const folds = (try routed.route.handler.getFoldingRanges(arena, params.textDocument.uri)) orelse return null;

        var out: std.ArrayList(lsp.types.FoldingRange) = .empty;
        for (folds) |f| {
            const start_pos = lsp.offsets.indexToPosition(doc.source, f.span_start, self.offset_encoding);
            const end_pos = lsp.offsets.indexToPosition(doc.source, f.span_end, self.offset_encoding);
            // A fold collapses *between* startLine and endLine — single-line
            // ranges have nothing to hide, so skip them rather than emit noise.
            if (start_pos.line == end_pos.line) continue;
            try out.append(arena, .{
                .startLine = start_pos.line,
                .endLine = end_pos.line,
            });
        }
        return try out.toOwnedSlice(arena);
    }

    pub fn @"textDocument/semanticTokens/full"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.semantic_tokens.Params,
    ) Allocator.Error!?lsp.types.semantic_tokens.Result {
        const routed = self.routedDocument(params.textDocument.uri) orelse return null;
        if (!schemaAvailable(routed.route)) return null;
        const doc = routed.doc;
        const toks = (try routed.route.handler.getSemanticTokens(arena, params.textDocument.uri)) orelse return null;

        // Byte spans → the negotiated encoding, which is the only step
        // that differs between transports; `SemanticToken.encode` then
        // owns the delta arithmetic for both.
        const positions = try arena.alloc(Handler.SemanticToken.Position, toks.len);
        for (toks, positions) |t, *slot| {
            const start = lsp.offsets.indexToPosition(doc.source, t.span_start, self.offset_encoding);
            const end = lsp.offsets.indexToPosition(doc.source, t.span_end, self.offset_encoding);
            // No token spans a line: each covers a single head, key,
            // symbol, or namespace qualifier, none of which may contain a
            // newline. That is what lets the length be a column difference.
            std.debug.assert(start.line == end.line);
            slot.* = .{
                .line = start.line,
                .character = start.character,
                .length = end.character - start.character,
                .type = t.type,
                .mods = t.mods,
            };
        }

        return .{ .data = try Handler.SemanticToken.encode(arena, positions) };
    }

    pub fn @"textDocument/inlayHint"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.InlayHint.Params,
    ) Allocator.Error!?[]const lsp.types.InlayHint {
        const routed = self.routedDocument(params.textDocument.uri) orelse return null;
        if (!schemaAvailable(routed.route)) return null;
        const doc = routed.doc;
        const start_offset: u32 = @intCast(lsp.offsets.positionToIndex(doc.source, params.range.start, self.offset_encoding));
        const end_offset: u32 = @intCast(lsp.offsets.positionToIndex(doc.source, params.range.end, self.offset_encoding));
        const hints = (try routed.route.handler.getInlayHints(arena, params.textDocument.uri, start_offset, end_offset)) orelse return null;

        const out = try arena.alloc(lsp.types.InlayHint, hints.len);
        for (hints, 0..) |h, i| {
            out[i] = .{
                .position = lsp.offsets.indexToPosition(doc.source, h.offset, self.offset_encoding),
                .label = .{ .string = h.label },
                // Mapped variant-by-variant rather than by numeric value:
                // the two enums agree on the wire today, and a switch makes
                // a future divergence a compile error here instead of a
                // silently wrong hint kind.
                .kind = if (h.kind) |k| switch (k) {
                    .type => .Type,
                    .parameter => .Parameter,
                } else null,
                .paddingLeft = h.padding_left,
                .paddingRight = h.padding_right,
            };
        }
        return out;
    }

    pub fn @"textDocument/formatting"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.document_formatting.Params,
    ) Allocator.Error!?[]const lsp.types.TextEdit {
        const routed = self.routedDocument(params.textDocument.uri) orelse return null;
        const doc = routed.doc;
        const edits = (try routed.route.handler.getFormatEdits(arena, params.textDocument.uri)) orelse return null;
        const out = try arena.alloc(lsp.types.TextEdit, edits.len);
        for (edits, 0..) |e, i| {
            out[i] = .{
                .range = .{
                    .start = lsp.offsets.indexToPosition(doc.source, e.span_start, self.offset_encoding),
                    .end = lsp.offsets.indexToPosition(doc.source, e.span_end, self.offset_encoding),
                },
                .newText = e.new_text,
            };
        }
        return out;
    }

    pub fn @"textDocument/rangeFormatting"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.document_range_formatting.Params,
    ) Allocator.Error!?[]const lsp.types.TextEdit {
        const routed = self.routedDocument(params.textDocument.uri) orelse return null;
        const doc = routed.doc;
        const start_offset: u32 = @intCast(lsp.offsets.positionToIndex(doc.source, params.range.start, self.offset_encoding));
        const end_offset: u32 = @intCast(lsp.offsets.positionToIndex(doc.source, params.range.end, self.offset_encoding));
        const edits = (try routed.route.handler.getRangeFormatEdits(arena, params.textDocument.uri, start_offset, end_offset)) orelse return null;
        const out = try arena.alloc(lsp.types.TextEdit, edits.len);
        for (edits, 0..) |e, i| {
            out[i] = .{
                .range = .{
                    .start = lsp.offsets.indexToPosition(doc.source, e.span_start, self.offset_encoding),
                    .end = lsp.offsets.indexToPosition(doc.source, e.span_end, self.offset_encoding),
                },
                .newText = e.new_text,
            };
        }
        return out;
    }

    pub fn @"textDocument/codeAction"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.CodeAction.Params,
    ) Allocator.Error!?[]const lsp.types.CodeAction.Result {
        const routed = self.routedDocument(params.textDocument.uri) orelse return null;
        if (!schemaAvailable(routed.route)) return null;
        const doc = routed.doc;
        const start_offset: u32 = @intCast(lsp.offsets.positionToIndex(doc.source, params.range.start, self.offset_encoding));
        const end_offset: u32 = @intCast(lsp.offsets.positionToIndex(doc.source, params.range.end, self.offset_encoding));
        const handler_actions = (try routed.route.handler.getCodeActions(arena, params.textDocument.uri, start_offset, end_offset)) orelse return null;

        const out = try arena.alloc(lsp.types.CodeAction.Result, handler_actions.len);
        for (handler_actions, 0..) |act, i| {
            const text_edits = try arena.alloc(lsp.types.TextEdit, act.edits.len);
            for (act.edits, 0..) |e, j| {
                text_edits[j] = .{
                    .range = .{
                        .start = lsp.offsets.indexToPosition(doc.source, e.span_start, self.offset_encoding),
                        .end = lsp.offsets.indexToPosition(doc.source, e.span_end, self.offset_encoding),
                    },
                    .newText = e.new_text,
                };
            }
            const edit = try self.workspaceEdit(arena, &.{.{
                .uri = params.textDocument.uri,
                .version = lspVersion(doc.version),
                .edits = text_edits,
            }});

            out[i] = .{
                .code_action = .{
                    .title = act.title,
                    // Switched rather than mapped by string: lsp-kit's
                    // `CodeActionKind` is a typed enum, so a new Handler
                    // kind breaks the build here instead of shipping an
                    // action the client silently filters out.
                    .kind = switch (act.kind) {
                        .quickfix => .quickfix,
                        .refactor_rewrite => .@"refactor.rewrite",
                        .refactor_extract => .@"refactor.extract",
                        .refactor_inline => .@"refactor.inline",
                    },
                    .diagnostics = try self.diagnosticItems(arena, doc.source, act.diagnostics),
                    .edit = edit,
                    .isPreferred = act.kind.isPreferred(),
                },
            };
        }
        return out;
    }

    /// Record the watcher registration outcome. A rejection means watching
    /// is unavailable for this connection: log once, never retry or poll.
    pub fn onResponse(
        self: *Server,
        _: std.mem.Allocator,
        response: lsp.JsonRPCMessage.Response,
    ) void {
        const pending = self.watcher_registration_id orelse return;
        const response_id = switch (response.id orelse return) {
            .number => |number| number,
            else => return,
        };
        if (response_id != @as(i64, @intCast(pending))) return;
        self.watcher_registration_id = null;
        switch (response.result_or_error) {
            .result => {},
            .@"error" => |err| {
                if (!self.watcher_rejected) {
                    self.watcher_rejected = true;
                    std.log.warn(
                        "client rejected the .sjon watcher registration ({d}: {s}); watching is unavailable for this connection",
                        .{ @intFromEnum(err.code), err.message },
                    );
                }
            },
        }
    }

    /// Send `client/registerCapability` to ask the client to watch every
    /// `.sjon` file under the workspace root. Hand-crafted JSON because
    /// `Registration.registerOptions` is `?LSPAny` (a `std.json.Value`
    /// tree) and constructing one for a single watcher is more code than
    /// it saves. The request id is retained so `onResponse` can record a
    /// rejection without turning it into a retry loop.
    fn registerSjonFileWatcher(self: *Server) !void {
        const id = self.next_request_id;
        self.next_request_id +%= 1;
        self.watcher_registration_id = id;
        errdefer self.watcher_registration_id = null;
        const json = try std.fmt.allocPrint(self.gpa,
            \\{{"jsonrpc":"2.0","id":{d},"method":"client/registerCapability","params":{{"registrations":[{{"id":"sjon-watch","method":"workspace/didChangeWatchedFiles","registerOptions":{{"watchers":[{{"globPattern":"**/*.sjon"}}]}}}}]}}}}
        , .{id});
        defer self.gpa.free(json);
        try self.transport.writeJsonMessage(self.io, json);
    }

    /// Send `workspace/diagnostic/refresh` (no params, ?void result) so
    /// pull-mode editors re-fetch diagnostics for every open document.
    /// Optional per spec — clients without `refreshSupport` will just
    /// reply with method-not-found, which we ignore.
    fn requestDiagnosticRefresh(self: *Server) !void {
        const id = self.next_request_id;
        self.next_request_id +%= 1;
        try self.transport.writeRequest(
            self.io,
            self.gpa,
            .{ .number = id },
            "workspace/diagnostic/refresh",
            ?void,
            null,
            .{ .emit_null_optional_fields = false },
        );
    }
};

fn workspaceDocumentUri(document: lsp.types.workspace.diagnostic.Report.Document) []const u8 {
    return switch (document) {
        .workspace_full_document_diagnostic_report => |report| report.uri,
        .workspace_unchanged_document_diagnostic_report => |report| report.uri,
    };
}

fn containsWorkspaceReport(
    documents: []const lsp.types.workspace.diagnostic.Report.Document,
    wanted: []const u8,
) bool {
    for (documents) |document| {
        if (uri.HashContext.eql(.{}, workspaceDocumentUri(document), wanted)) return true;
    }
    return false;
}

fn containsUri(uris: []const []const u8, wanted: []const u8) bool {
    for (uris) |candidate| {
        if (uri.HashContext.eql(.{}, candidate, wanted)) return true;
    }
    return false;
}

const DiagnosticCode = @TypeOf(@as(lsp.types.Diagnostic, undefined).code);

fn sameDiagnosticCode(a: DiagnosticCode, b: DiagnosticCode) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    return switch (left) {
        .string => |value| switch (right) {
            .string => |other| std.mem.eql(u8, value, other),
            else => false,
        },
        .number => |value| switch (right) {
            .number => |other| value == other,
            else => false,
        },
    };
}

/// True only when the active mode's `tagSupport.valueSet` contains LSP
/// `DiagnosticTag.Deprecated` (2). An absent `tagSupport`, an empty
/// `valueSet`, or a set without 2 all mean the client did not ask for
/// the tag.
fn supportsDeprecatedTag(tag_support: ?lsp.types.ClientCapabilities.TextDocument.Diagnostic.TagOptions) bool {
    const support = tag_support orelse return false;
    for (support.valueSet) |tag| {
        if (tag == .Deprecated) return true;
    }
    return false;
}

/// The capability set the `initialize` response advertises. Lifted out of
/// `initialize` so it can be handed to lsp-kit's own validator without
/// standing up a server and driving a request — that is what
/// `test "advertised capabilities match the implemented methods"` below
/// does, and it is the only gate on this file.
///
/// Everything here is a constant of the build except `positionEncoding`,
/// which is negotiated per client, so the parameter is the whole of the
/// per-connection state a caller has to supply.
///
/// The shapes matter as much as the values: lsp-kit reads a bare `true`
/// on `.inlayHintProvider` as a claim that `inlayHint/resolve` exists too
/// (`basic_server.zig:453-458`), and panics during `initialize` when it
/// does not. That is exactly what shipped, on the one code path no test
/// reached (audit 2026-08-27 §1).
fn serverCapabilities(encoding: lsp.offsets.Encoding) lsp.types.ServerCapabilities {
    return .{
        .positionEncoding = switch (encoding) {
            .@"utf-8" => .@"utf-8",
            .@"utf-16" => .@"utf-16",
            .@"utf-32" => .@"utf-32",
        },
        .textDocumentSync = .{
            .text_document_sync_options = .{
                .openClose = true,
                // Ranged payloads are spliced via
                // `text_sync.applyChanges`; the whole-document form
                // stays supported as the spec-required fallback.
                .change = .Incremental,
                // Saved inputs are reread from disk; client text is
                // deliberately not requested or trusted.
                .save = .{ .save_options = .{ .includeText = false } },
            },
        },
        .diagnosticProvider = .{
            .diagnostic_options = .{
                // True, but *not* because of cross-refs: scope is
                // per-tree (the LSP never sets
                // `Validator.Options.share_scope`), so a definition in
                // one document cannot resolve a reference in another.
                // `Handler_tests.zig`'s "cross-doc: per-tree default
                // isolates references" pins exactly that.
                //
                // What genuinely crosses files is the *schema*:
                // editing `sjon-project.sjon` or a manifest it names
                // re-runs discovery and changes every document's
                // diagnostics at once. A client that believes
                // otherwise leaves stale errors on screen after the
                // edit that fixed them.
                .interFileDependencies = true,
                // Native only. The handler is filesystem-free by
                // design, so workspace enumeration lives here; the
                // WASM transport has no filesystem to enumerate and
                // leaves this false.
                .workspaceDiagnostics = true,
            },
        },
        .hoverProvider = .{ .bool = true },
        .completionProvider = .{
            // `(`: form-head, `:`: keyword-key, `[`: vector element.
            .triggerCharacters = &.{ "(", ":", "[" },
        },
        .signatureHelpProvider = .{
            // `(` opens a fresh signature; ` ` re-targets the active
            // parameter as the user types successive args.
            .triggerCharacters = &.{"("},
            .retriggerCharacters = &.{" "},
        },
        .documentSymbolProvider = .{ .bool = true },
        .documentFormattingProvider = .{ .bool = true },
        .documentRangeFormattingProvider = .{ .bool = true },
        .foldingRangeProvider = .{ .bool = true },
        .inlayHintProvider = .{ .inlay_hint_options = .{ .resolveProvider = false } },
        .semanticTokensProvider = .{
            .semantic_tokens_options = .{
                // Both lists come from `SemanticToken`'s own legends,
                // so the indices and bits this server puts on the wire
                // cannot drift from the names the client maps them
                // through. Kept in sync with `wasm.zig`'s capability
                // JSON, which generates the same object at comptime.
                .legend = .{
                    .tokenTypes = &Handler.SemanticToken.Type.legend,
                    .tokenModifiers = &Handler.SemanticToken.Mods.legend,
                },
                // `full` only. SJON documents are small enough that a
                // whole-file recompute beats tracking deltas, and
                // advertising `range` or `full.delta` would invite
                // requests with no handler behind them.
                .full = .{ .bool = true },
            },
        },
        .codeActionProvider = .{
            .code_action_options = .{
                .codeActionKinds = &.{ .quickfix, .@"refactor.rewrite", .@"refactor.extract", .@"refactor.inline" },
            },
        },
        .definitionProvider = .{ .bool = true },
        .declarationProvider = .{ .bool = true },
        .documentHighlightProvider = .{ .bool = true },
        .selectionRangeProvider = .{ .bool = true },
        .workspaceSymbolProvider = .{ .bool = true },
        .referencesProvider = .{ .bool = true },
        .renameProvider = .{
            .rename_options = .{ .prepareProvider = true },
        },
    };
}

test "advertised capabilities match the implemented methods" {
    // lsp-kit's validator is a comptime cross-check between the capability
    // set and `Server`'s method names: a capability with no handler behind
    // it, or a handler no capability announces, is a panic. `initialize`
    // already calls it, which is why the mismatch was reachable at all —
    // but only in a Debug build, and only on a live connection, and nothing
    // in the build graph ever opened one (every `lsp-*.test.ts` drives
    // `sjon-lsp.wasm`, whose dispatcher validates nothing).
    //
    // So this is the gate: it runs the same check in `zig build test`,
    // where a mismatch is red before it is an outage. Restore the
    // pre-fix `.inlayHintProvider = .{ .bool = true }` and this test
    // aborts, naming `inlayHint/resolve` (audit 2026-08-27 §1). A panic
    // in a test is a failing test, which is the red this wants.
    //
    // The encoding is the only free parameter and it does not reach the
    // check, so any of the three does.
    lsp.basic_server.validateServerCapabilities(Server, serverCapabilities(.@"utf-16"));
}

/// An in-memory `lsp.Transport` that records every serialized JSON-RPC
/// message. Test-only: it exists so a push-client contract ("nothing is
/// written to the wire unless the reload committed") can be asserted
/// without a process boundary.
const RecordingTransport = struct {
    transport: lsp.Transport = undefined,
    buffer: [64 * 1024]u8 = undefined,
    starts: [128]usize = undefined,
    count: usize = 0,
    used: usize = 0,
    overflowed: bool = false,

    fn init(self: *RecordingTransport) void {
        self.transport = .{
            .vtable = &.{
                .readJsonMessage = &RecordingTransport.readStub,
                .writeJsonMessage = &RecordingTransport.write,
            },
        };
    }

    fn readStub(_: *lsp.Transport, _: std.Io, _: std.mem.Allocator) lsp.Transport.ReadError![]u8 {
        return error.EndOfStream;
    }

    fn write(
        transport: *lsp.Transport,
        _: std.Io,
        json_message: []const u8,
    ) lsp.Transport.WriteError!void {
        const self: *RecordingTransport = @fieldParentPtr("transport", transport);
        if (self.count >= self.starts.len or self.used + json_message.len > self.buffer.len) {
            self.overflowed = true;
            return;
        }
        self.starts[self.count] = self.used;
        @memcpy(self.buffer[self.used..][0..json_message.len], json_message);
        self.used += json_message.len;
        self.count += 1;
    }

    fn message(self: *const RecordingTransport, index: usize) []const u8 {
        const start = self.starts[index];
        const end = if (index + 1 < self.count) self.starts[index + 1] else self.used;
        return self.buffer[start..end];
    }

    fn countMethod(self: *const RecordingTransport, method: []const u8) usize {
        var total: usize = 0;
        for (0..self.count) |index| {
            if (std.mem.indexOf(u8, self.message(index), method) != null) total += 1;
        }
        return total;
    }
};

test "reload: failed reload publishes nothing stale to a push client" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sub: []const u8 = &tmp.sub_path;
    const relative = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", sub });
    const dir = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, relative, arena);

    const writeFixture = struct {
        fn write(
            tmp_dir: *std.testing.TmpDir,
            sub_path: []const u8,
            data: []const u8,
        ) !void {
            if (std.fs.path.dirname(sub_path)) |parent| {
                try tmp_dir.dir.createDirPath(testing.io, parent);
            }
            try tmp_dir.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
        }
    }.write;

    // Two independent legacy roots, each with its own manifest, project,
    // and a document that is valid only under its root's current schema.
    try writeFixture(&tmp, "one/one.sjon", "(plugin :name one :version \"1.0.0\" (form :name one-form :open true))\n");
    try writeFixture(&tmp, "one/sjon-project.sjon", "(project :plugins [\"one.sjon\"])\n");
    try writeFixture(&tmp, "one/doc.sjon", "(one-form)\n");
    try writeFixture(&tmp, "two/two.sjon", "(plugin :name two :version \"1.0.0\" (form :name two-form :open true))\n");
    try writeFixture(&tmp, "two/sjon-project.sjon", "(project :plugins [\"two.sjon\"])\n");
    try writeFixture(&tmp, "two/doc.sjon", "(two-form)\n");

    const one_dir = try std.fs.path.join(arena, &.{ dir, "one" });
    const two_dir = try std.fs.path.join(arena, &.{ dir, "two" });
    const one_folder = try uri.pathToFileUri(arena, one_dir);
    const two_folder = try uri.pathToFileUri(arena, two_dir);
    const one_doc = try uri.pathToFileUri(arena, try std.fs.path.join(arena, &.{ one_dir, "doc.sjon" }));
    const two_doc = try uri.pathToFileUri(arena, try std.fs.path.join(arena, &.{ two_dir, "doc.sjon" }));
    const one_project = try uri.pathToFileUri(
        arena,
        try std.fs.path.join(arena, &.{ one_dir, "sjon-project.sjon" }),
    );

    var recorder = RecordingTransport{};
    recorder.init();

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var server = Server.init(failing.allocator(), testing.io, &recorder.transport);
    errdefer server.deinit();

    _ = server.initialize(arena, .{
        .capabilities = .{},
        .workspaceFolders = &.{
            .{ .uri = one_folder, .name = "one" },
            .{ .uri = two_folder, .name = "two" },
        },
    });

    try server.@"textDocument/didOpen"(arena, .{
        .textDocument = .{
            .uri = one_doc,
            .languageId = .{ .custom_value = "sjon" },
            .version = 1,
            .text = "(one-form)\n",
        },
    });
    try server.@"textDocument/didOpen"(arena, .{
        .textDocument = .{
            .uri = two_doc,
            .languageId = .{ .custom_value = "sjon" },
            .version = 1,
            .text = "(two-form)\n",
        },
    });

    // Both open documents published one clean report: that is the set of
    // reports the push client holds for the rest of this test.
    try testing.expectEqual(@as(usize, 2), recorder.count);
    try testing.expectEqual(@as(usize, 2), recorder.countMethod("textDocument/publishDiagnostics"));
    const baseline = recorder.count;

    // Both manifests lose their old form on disk. A reload that commits
    // makes every open document's form unknown; the old schemas are what
    // the client's held reports still describe.
    try writeFixture(&tmp, "one/one.sjon", "(plugin :name one :version \"1.0.0\" (form :name one-v2 :open true))\n");
    try writeFixture(&tmp, "two/two.sjon", "(plugin :name two :version \"1.0.0\" (form :name two-v2 :open true))\n");

    const pullCount = struct {
        fn count(
            srv: *Server,
            arena_alloc: std.mem.Allocator,
            document_uri: []const u8,
        ) Allocator.Error!usize {
            const report = try srv.@"textDocument/diagnostic"(arena_alloc, .{
                .textDocument = .{ .uri = document_uri },
            });
            return report.related_full_document_diagnostic_report.items.len;
        }
    }.count;

    // A failed reload is swallowed by the save handler (it only logs), so
    // the publication stream and the pull answers are the entire witness.
    // Each iteration fails the n-th allocation of that attempt itself, so
    // the sweep walks the reload's phases in order regardless of how many
    // allocations earlier failed attempts consumed.
    var saw_retained = false;
    var completed = false;
    var n: usize = 0;
    while (n < 8192) : (n += 1) {
        failing.fail_index = failing.alloc_index + n;
        failing.resize_fail_index = failing.resize_index + n;
        // A publication-phase failure escapes as a write error; the
        // pre-existing publication rule owns that recovery window, so the
        // sweep only records it and classifies by state.
        server.@"textDocument/didSave"(arena, .{
            .textDocument = .{ .uri = one_project },
        }) catch {};
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);

        const one_dirty = try pullCount(&server, arena, one_doc) != 0;
        const two_dirty = try pullCount(&server, arena, two_doc) != 0;

        if (one_dirty != two_dirty) {
            // Root one serving the new manifest while root two still
            // serves the old one — with nothing or something published —
            // is the stale-report defect: the reports the client holds
            // describe a state the server can no longer serve uniformly.
            return error.PartialLegacyMutation;
        }
        if (one_dirty and two_dirty) {
            // The reload committed; the failure (if any) landed in
            // publication, whose recovery window is the pre-existing
            // publication rule. Stop sampling.
            completed = true;
            break;
        }

        // Nothing committed. The client must have seen nothing new.
        if (recorder.count != baseline) return error.UnexpectedPublication;
        saw_retained = true;
    }
    try testing.expect(saw_retained);
    try testing.expect(completed);

    server.deinit();
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}
