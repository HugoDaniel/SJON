//! SJON Language Server — native entry point.
//!
//! Stdio + JSON-RPC via lsp-kit's `basic_server`. The `Server` struct
//! exposes the typed methods lsp-kit dispatches by name; each one
//! delegates to the transport-agnostic `Handler` (which is shared with
//! the WASM target).
//!
//! Scope today: initialize (with workspace schema discovery via
//! `sjon-project.sjon`), didOpen / didChange (full sync) / didClose,
//! pull-mode `textDocument/diagnostic` (also surfaces project-file
//! diagnostics on the project URI), `textDocument/hover`,
//! `textDocument/completion` (form-head and key contexts driven by the
//! loaded schema), `textDocument/signatureHelp` (form keys / typed
//! expr-func params with cursor-driven active parameter),
//! `textDocument/documentSymbol`,
//! `textDocument/foldingRange` (one fold per multi-line form/vector),
//! `textDocument/inlayHint` (plugin-source ghost text on bare form
//! heads, `core` excluded),
//! `textDocument/semanticTokens/full` (schema-resolved heads, keys,
//! members, and cross-ref names; `full` only),
//! `textDocument/formatting`, `textDocument/codeAction` (quickfixes
//! for `unknown_form`/`unknown_key` via Levenshtein nearest-name), and
//! `workspace/didChangeWatchedFiles` (re-runs schema discovery and
//! re-validates every open document, then asks the client to re-pull
//! diagnostics), and `workspace/diagnostic` (enumerates `**/*.sjon`
//! under the workspace root and reports on-disk files alongside open
//! buffers — native only, since the handler owns no filesystem).

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const sjon = @import("sjon");
const sjon_version = sjon.version;
const uri = @import("uri");
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

    try lsp.basic_server.run(init.io, init.gpa, transport, &server, std.log.err);
}

/// lsp-kit-typed dispatcher. Holds the offset encoding negotiated during
/// `initialize` and forwards every other method to `Handler`. Also keeps
/// the `transport` so server-initiated requests (`client/registerCapability`,
/// `workspace/diagnostic/refresh`) can be sent without going through
/// `basic_server.run`.
pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: *lsp.Transport,
    handler: Handler,
    offset_encoding: lsp.offsets.Encoding,
    /// Whether the client accepts `WorkspaceEdit.documentChanges`, from
    /// `capabilities.workspace.workspaceEdit.documentChanges`. Only that
    /// form can carry a document version, and a client that doesn't
    /// understand it sees an edit with no `changes` and applies nothing —
    /// hence a capability check rather than always sending the better shape.
    client_document_changes: bool,
    /// Filesystem path of the workspace root, captured at `initialize`
    /// time so `workspace/didChangeWatchedFiles` can re-resolve
    /// `sjon-project.sjon` without retaining the request arena.
    /// Owned by `gpa`; null when the client supplied no workspace.
    workspace_path: ?[]const u8,
    /// Monotonic counter for server-initiated request IDs. Wraps at u31
    /// to stay inside the LSP spec's signed-32-bit range.
    next_request_id: u31,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, transport: *lsp.Transport) Server {
        return .{
            .gpa = gpa,
            .io = io,
            .transport = transport,
            .handler = Handler.init(gpa),
            .offset_encoding = .@"utf-16",
            .client_document_changes = false,
            .workspace_path = null,
            .next_request_id = 1,
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.workspace_path) |p| self.gpa.free(p);
        self.handler.deinit();
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

        // Schema discovery — resolve the workspace root, look for a
        // `sjon-project.sjon`, and load every plugin manifest it lists.
        // Failures here surface as project diagnostics on the project
        // file URI; OOM is the only error that escalates to the client.
        const workspace_path = resolveWorkspacePath(arena, request) catch null;
        // Stash a gpa-owned copy so `workspace/didChangeWatchedFiles`
        // can re-resolve the project file later. The arena copy
        // disappears when this request returns.
        if (workspace_path) |p| {
            self.workspace_path = self.gpa.dupe(u8, p) catch null;
        }
        self.handler.loadProject(self.io, workspace_path) catch |err| {
            std.log.warn("loadProject failed: {s}", .{@errorName(err)});
        };

        const server_capabilities = serverCapabilities(self.offset_encoding);

        if (@import("builtin").mode == .Debug) {
            lsp.basic_server.validateServerCapabilities(Server, server_capabilities);
        }

        return .{
            .serverInfo = .{ .name = "sjon-lsp", .version = sjon_version },
            .capabilities = server_capabilities,
        };
    }

    pub fn initialized(self: *Server, _: std.mem.Allocator, _: lsp.types.InitializedParams) void {
        // Ask the client to watch every `.sjon` file in the workspace.
        // The pattern is broad on purpose: it covers the project file,
        // every plugin manifest the project may reference now or later,
        // and any future `.sjon` file the user adds. Reload-on-change
        // is cheap (parse a few KB + revalidate cached docs).
        self.registerSjonFileWatcher() catch |err| {
            std.log.warn("registerSjonFileWatcher failed: {s}", .{@errorName(err)});
        };
    }

    pub fn shutdown(_: *Server, _: std.mem.Allocator, _: void) ?void {
        return null;
    }

    pub fn exit(_: *Server, _: std.mem.Allocator, _: void) void {}

    pub fn @"textDocument/didOpen"(
        self: *Server,
        _: std.mem.Allocator,
        params: lsp.types.TextDocument.DidOpenParams,
    ) Allocator.Error!void {
        try self.handler.openDocument(
            params.textDocument.uri,
            params.textDocument.version,
            params.textDocument.text,
        );
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
    ) Handler.Error!void {
        // The splice needs the current text, so the lookup moves ahead of
        // `changeDocumentFull` — but it keeps raising the same error that
        // call used to, rather than turning a client protocol violation
        // into a silent no-op.
        const doc = self.handler.getDocument(params.textDocument.uri) orelse
            return error.UnknownDocument;

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
        if (changes.len == 0) return;

        const merged = try text_sync.applyChanges(
            arena,
            doc.source,
            changes,
            OffsetMapper{ .encoding = self.offset_encoding },
        );

        // One reparse for the batch, not one per change.
        try self.handler.changeDocumentFull(
            params.textDocument.uri,
            params.textDocument.version,
            merged,
        );
    }

    pub fn @"textDocument/didClose"(
        self: *Server,
        _: std.mem.Allocator,
        params: lsp.types.TextDocument.DidCloseParams,
    ) Allocator.Error!void {
        self.handler.closeDocument(params.textDocument.uri);
    }

    pub fn @"workspace/didChangeWatchedFiles"(
        self: *Server,
        _: std.mem.Allocator,
        _: lsp.types.workspace.did_change_watched_files.Params,
    ) Allocator.Error!void {
        // We don't filter on the URI list. Watcher pattern is already
        // narrow (`.sjon` only) and `reloadProject` is cheap enough
        // that re-running on every match is simpler than tracking which
        // files matter as manifests vs regular docs.
        self.handler.reloadProject(self.io, self.workspace_path) catch |err| {
            std.log.warn("reloadProject failed: {s}", .{@errorName(err)});
            return;
        };
        // Pull-mode diagnostics: cached `validate_result`s are now fresh
        // but the editor doesn't know that. Ask it to re-pull.
        self.requestDiagnosticRefresh() catch |err| {
            std.log.warn("workspace/diagnostic/refresh failed: {s}", .{@errorName(err)});
        };
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

        // Project file diagnostics: when the editor pulls diagnostics on
        // `sjon-project.sjon`, return the schema-discovery report rather
        // than an empty one (the project file isn't an opened document).
        if (self.handler.getProjectInfo()) |proj| {
            // Decoded equality, matching the document map and
            // `ingestWorkspaceFiles`: `Host` builds this URI without
            // percent-encoding, and a client is free to send another
            // spelling of the same path.
            if (proj.project_uri) |purl| if (uri.HashContext.eql(.{}, purl, params.textDocument.uri)) {
                const proj_source = proj.project_source orelse return empty;
                const items = try arena.alloc(lsp.types.Diagnostic, proj.diagnostics.len);
                for (proj.diagnostics, 0..) |d, i| {
                    const start_pos = lsp.offsets.indexToPosition(proj_source, d.span.start, self.offset_encoding);
                    const end_pos = lsp.offsets.indexToPosition(proj_source, d.span.end, self.offset_encoding);
                    items[i] = .{
                        .range = .{ .start = start_pos, .end = end_pos },
                        .severity = switch (d.severity) {
                            .err => .Error,
                            .warning => .Warning,
                        },
                        .code = .{ .string = @tagName(d.code) },
                        .codeDescription = .{ .href = Handler.codeHref(d.code) },
                        .source = "sjon",
                        .message = d.message,
                    };
                }
                return .{
                    .related_full_document_diagnostic_report = .{
                        .items = items,
                        .resultId = null,
                        .relatedDocuments = null,
                    },
                };
            };
        }

        const doc = self.handler.getDocument(params.textDocument.uri) orelse return empty;

        // ResultId = `<doc_version>:<schema_generation>`. Both halves
        // matter: a doc edit bumps doc.version, a manifest/project-file
        // edit bumps schema_generation. The client short-circuits to
        // "unchanged" only when both are the same.
        const current_id = try std.fmt.allocPrint(
            arena,
            "{d}:{d}",
            .{ doc.version, self.handler.schema_generation },
        );
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

        const handler_diags = (try self.handler.getDiagnostics(arena, params.textDocument.uri)) orelse &.{};
        const items = try self.diagnosticItems(arena, doc.source, handler_diags);

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
        if (self.workspace_path) |root| {
            const scan = workspace_scan.collect(arena, self.io, root, .{}) catch
                workspace_scan.Scan{ .files = &.{}, .stopped_early = false };
            if (scan.stopped_early) {
                std.log.warn(
                    "workspace scan stopped at {d} entries; some files were not examined",
                    .{workspace_scan.MAX_SCAN_ENTRIES},
                );
            }
            const ingest = self.handler.ingestWorkspaceFiles(scan.files) catch
                Handler.WorkspaceIngest{ .ingested = 0, .clipped = 0 };
            if (ingest.clipped > 0) {
                std.log.warn(
                    "workspace diagnostics: {d} file(s) beyond the {d}-file cap were not analysed",
                    .{ ingest.clipped, Handler.MAX_WORKSPACE_FILES },
                );
            }
        }

        const reports = try self.handler.getWorkspaceDiagnostics(arena);
        // Appended, not indexed into a pre-sized slice: the `orelse continue`
        // below skips a report without filling its slot, and a pre-sized
        // slice would then serialize undefined memory. Unreachable today
        // (reports come from `handler.documents` and `getDocument` is an
        // unfiltered lookup on that same map in this same synchronous call) —
        // appending makes it stay correct if either half moves.
        var items: std.ArrayList(lsp.types.workspace.diagnostic.Report.Document) = .empty;
        try items.ensureTotalCapacityPrecise(arena, reports.len);
        for (reports) |r| {
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

            const doc = self.handler.getDocument(r.uri) orelse continue;
            items.appendAssumeCapacity(.{ .workspace_full_document_diagnostic_report = .{
                .uri = r.uri,
                .version = version,
                .resultId = r.result_id,
                .items = try self.diagnosticItems(arena, doc.source, r.diagnostics),
            } });
        }
        return .{ .items = items.items };
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
                .codeDescription = .{ .href = d.code_href },
                .source = "sjon",
                .message = d.message,
                .tags = try diagnosticTags(arena, d.tags),
                .relatedInformation = try self.relatedInformation(arena, d.related),
            };
        }
        return items;
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
            const doc = self.handler.getDocument(r.uri) orelse continue;
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

    /// Map the Handler's transport-neutral tags onto lsp-kit's enum.
    /// Null (not an empty slice) when there are none — LSP treats an
    /// absent `tags` as "untagged", and some clients read `[]` as an
    /// explicit, if empty, tag set.
    ///
    /// The two enums agree numerically (both are the LSP wire values),
    /// but they are mapped variant-by-variant rather than bit-cast so a
    /// future tag can't silently mis-map.
    fn diagnosticTags(
        arena: std.mem.Allocator,
        tags: []const Handler.Diagnostic.Tag,
    ) Allocator.Error!?[]const lsp.types.Diagnostic.Tag {
        if (tags.len == 0) return null;
        const out = try arena.alloc(lsp.types.Diagnostic.Tag, tags.len);
        for (tags, 0..) |t, i| {
            out[i] = switch (t) {
                .deprecated => .Deprecated,
            };
        }
        return out;
    }

    pub fn @"textDocument/prepareRename"(
        self: *Server,
        _: std.mem.Allocator,
        params: lsp.types.prepare_rename.Params,
    ) Allocator.Error!?lsp.types.prepare_rename.Result {
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;
        const offset = lsp.offsets.positionToIndex(doc.source, params.position, self.offset_encoding);
        const pre = self.handler.prepareRename(params.textDocument.uri, @intCast(offset)) orelse return null;
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
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;
        const offset = lsp.offsets.positionToIndex(doc.source, params.position, self.offset_encoding);
        const result = (try self.handler.rename(
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
            const ref_doc = self.handler.getDocument(fe.uri) orelse {
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

    /// Goto-definition. A cross-ref name resolves to exactly one
    /// definition in its scope, so this returns the scalar `Location`
    /// arm rather than a list or `LocationLink[]`.
    pub fn @"textDocument/definition"(
        self: *Server,
        _: std.mem.Allocator,
        params: lsp.types.Definition.Params,
    ) Allocator.Error!?lsp.types.Definition.Result {
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;
        const offset = lsp.offsets.positionToIndex(doc.source, params.position, self.offset_encoding);
        const loc = self.handler.getDefinition(params.textDocument.uri, @intCast(offset)) orelse return null;

        // The definition may live in another document (the index is
        // forest-wide); re-look it up for the byte→position conversion.
        // A document closed since the last revalidation drops the jump.
        const def_doc = self.handler.getDocument(loc.uri) orelse return null;
        const start = lsp.offsets.indexToPosition(def_doc.source, loc.span_start, self.offset_encoding);
        const end = lsp.offsets.indexToPosition(def_doc.source, loc.span_end, self.offset_encoding);
        return .{ .definition = .{ .location = .{
            .uri = loc.uri,
            .range = .{ .start = start, .end = end },
        } } };
    }

    /// Highlight every occurrence of the cross-ref name under the
    /// cursor. Single-document by protocol; the handler filters.
    pub fn @"textDocument/documentHighlight"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.DocumentHighlight.Params,
    ) Allocator.Error!?[]const lsp.types.DocumentHighlight {
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;
        const offset = lsp.offsets.positionToIndex(doc.source, params.position, self.offset_encoding);
        const highlights = (try self.handler.getDocumentHighlights(
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
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;

        const byte_offsets = try arena.alloc(u32, params.positions.len);
        for (params.positions, byte_offsets) |pos, *slot| {
            slot.* = @intCast(lsp.offsets.positionToIndex(doc.source, pos, self.offset_encoding));
        }

        const chains = (try self.handler.getSelectionRanges(
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
        const syms = try self.handler.getWorkspaceSymbols(arena, params.query);

        var out: std.ArrayList(lsp.types.SymbolInformation) = .empty;
        for (syms) |sym| {
            // A definition can outlive its document in a stale index;
            // without the source there is no byte→position translation,
            // and the editor could not open the location anyway.
            const doc = self.handler.getDocument(sym.location.uri) orelse continue;
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
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;
        const offset = lsp.offsets.positionToIndex(doc.source, params.position, self.offset_encoding);
        const refs = (try self.handler.findReferences(
            arena,
            params.textDocument.uri,
            @intCast(offset),
            params.context.includeDeclaration,
        )) orelse return null;

        // Translate handler `Location[]` → `lsp.types.Location[]`. We re-look
        // up each URI's document to convert byte offsets to LSP `Position`s
        // in the document's encoding. A site whose document closed between
        // revalidation and the request is dropped silently.
        var out: std.ArrayList(lsp.types.Location) = .empty;
        for (refs) |r| {
            const ref_doc = self.handler.getDocument(r.uri) orelse continue;
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
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;
        const offset = lsp.offsets.positionToIndex(doc.source, params.position, self.offset_encoding);
        const hov = (try self.handler.getHover(arena, params.textDocument.uri, @intCast(offset))) orelse return null;
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
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;
        const offset = lsp.offsets.positionToIndex(doc.source, params.position, self.offset_encoding);
        const items_or_null = try self.handler.getCompletion(arena, params.textDocument.uri, @intCast(offset));
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
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;
        const offset = lsp.offsets.positionToIndex(doc.source, params.position, self.offset_encoding);
        const help = (try self.handler.getSignatureHelp(arena, params.textDocument.uri, @intCast(offset))) orelse return null;

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
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;
        const handler_syms = (try self.handler.getDocumentSymbols(arena, params.textDocument.uri)) orelse return null;
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
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;
        const folds = (try self.handler.getFoldingRanges(arena, params.textDocument.uri)) orelse return null;

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
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;
        const toks = (try self.handler.getSemanticTokens(arena, params.textDocument.uri)) orelse return null;

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
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;
        const start_offset: u32 = @intCast(lsp.offsets.positionToIndex(doc.source, params.range.start, self.offset_encoding));
        const end_offset: u32 = @intCast(lsp.offsets.positionToIndex(doc.source, params.range.end, self.offset_encoding));
        const hints = (try self.handler.getInlayHints(arena, params.textDocument.uri, start_offset, end_offset)) orelse return null;

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
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;
        const edits = (try self.handler.getFormatEdits(arena, params.textDocument.uri)) orelse return null;
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
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;
        const start_offset: u32 = @intCast(lsp.offsets.positionToIndex(doc.source, params.range.start, self.offset_encoding));
        const end_offset: u32 = @intCast(lsp.offsets.positionToIndex(doc.source, params.range.end, self.offset_encoding));
        const edits = (try self.handler.getRangeFormatEdits(arena, params.textDocument.uri, start_offset, end_offset)) orelse return null;
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
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;
        const start_offset: u32 = @intCast(lsp.offsets.positionToIndex(doc.source, params.range.start, self.offset_encoding));
        const end_offset: u32 = @intCast(lsp.offsets.positionToIndex(doc.source, params.range.end, self.offset_encoding));
        const handler_actions = (try self.handler.getCodeActions(arena, params.textDocument.uri, start_offset, end_offset)) orelse return null;

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

    pub fn onResponse(_: *Server, _: std.mem.Allocator, _: lsp.JsonRPCMessage.Response) void {}

    /// Send `client/registerCapability` to ask the client to watch every
    /// `.sjon` file under the workspace root. Hand-crafted JSON because
    /// `Registration.registerOptions` is `?LSPAny` (a `std.json.Value`
    /// tree) and constructing one for a single watcher is more code than
    /// it saves. We don't track the response — `onResponse` ignores it.
    fn registerSjonFileWatcher(self: *Server) !void {
        const id = self.next_request_id;
        self.next_request_id +%= 1;
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

    /// Pick the most reliable workspace-root URI from `InitializeParams`
    /// and convert it to a filesystem path. Spec preference order:
    /// `workspaceFolders[0]` (current) → `rootUri` (deprecated) →
    /// `rootPath` (legacy). Returns null when none is supplied or none
    /// is a `file://` URI we know how to translate.
    fn resolveWorkspacePath(
        arena: std.mem.Allocator,
        request: lsp.types.InitializeParams,
    ) std.mem.Allocator.Error!?[]const u8 {
        if (request.workspaceFolders) |folders| {
            if (folders.len > 0) {
                if (try uri.fileUriToPath(arena, folders[0].uri)) |path| return path;
            }
        }
        if (request.rootUri) |root_uri| {
            if (try uri.fileUriToPath(arena, root_uri)) |path| return path;
        }
        if (request.rootPath) |path| return try arena.dupe(u8, path);
        return null;
    }
};

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
