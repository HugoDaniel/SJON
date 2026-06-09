const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("Handler");
const sjon_version = @import("sjon").version;
const uri = @import("uri");

pub fn main(init: std.process.Init) !void {
    var read_buffer: [4096]u8 = undefined;
    var stdio_transport: lsp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());
    const transport: *lsp.Transport = &stdio_transport.transport;

    var server: Server = .init(init.gpa, init.io, transport);
    defer server.deinit();

    try lsp.basic_server.run(init.io, init.gpa, transport, &server, std.log.err);
}

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: *lsp.Transport,
    handler: Handler,
    offset_encoding: lsp.offsets.Encoding,
    workspace_path: ?[]const u8,
    next_request_id: u31,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, transport: *lsp.Transport) Server {
        return .{
            .gpa = gpa,
            .io = io,
            .transport = transport,
            .handler = Handler.init(gpa),
            .offset_encoding = .@"utf-16",
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

        const workspace_path = resolveWorkspacePath(arena, request) catch null;
        if (workspace_path) |p| {
            self.workspace_path = self.gpa.dupe(u8, p) catch null;
        }
        self.handler.loadProject(self.io, workspace_path) catch |err| {
            std.log.warn("loadProject failed: {s}", .{@errorName(err)});
        };

        const server_capabilities: lsp.types.ServerCapabilities = .{
            .positionEncoding = switch (self.offset_encoding) {
                .@"utf-8" => .@"utf-8",
                .@"utf-16" => .@"utf-16",
                .@"utf-32" => .@"utf-32",
            },
            .textDocumentSync = .{
                .text_document_sync_options = .{
                    .openClose = true,
                    .change = .Full,
                },
            },
            .diagnosticProvider = .{
                .diagnostic_options = .{
                    .interFileDependencies = false,
                    .workspaceDiagnostics = false,
                },
            },
            .hoverProvider = .{ .bool = true },
            .completionProvider = .{
                .triggerCharacters = &.{ "(", ":", "[" },
            },
            .signatureHelpProvider = .{
                .triggerCharacters = &.{"("},
                .retriggerCharacters = &.{" "},
            },
            .documentSymbolProvider = .{ .bool = true },
            .documentFormattingProvider = .{ .bool = true },
            .foldingRangeProvider = .{ .bool = true },
            .inlayHintProvider = .{ .bool = true },
            .codeActionProvider = .{
                .code_action_options = .{
                    .codeActionKinds = &.{.quickfix},
                },
            },
            .referencesProvider = .{ .bool = true },
            .renameProvider = .{
                .rename_options = .{ .prepareProvider = true },
            },
        };

        if (@import("builtin").mode == .Debug) {
            lsp.basic_server.validateServerCapabilities(Server, server_capabilities);
        }

        return .{
            .serverInfo = .{ .name = "sjon-lsp", .version = sjon_version },
            .capabilities = server_capabilities,
        };
    }

    pub fn initialized(self: *Server, _: std.mem.Allocator, _: lsp.types.InitializedParams) void {
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
    ) !void {
        try self.handler.openDocument(
            params.textDocument.uri,
            params.textDocument.version,
            params.textDocument.text,
        );
    }

    pub fn @"textDocument/didChange"(
        self: *Server,
        _: std.mem.Allocator,
        params: lsp.types.TextDocument.DidChangeParams,
    ) !void {
        for (params.contentChanges) |change| {
            switch (change) {
                .text_document_content_change_whole_document => |whole| {
                    try self.handler.changeDocumentFull(
                        params.textDocument.uri,
                        params.textDocument.version,
                        whole.text,
                    );
                },
                .text_document_content_change_partial => {
                    std.log.warn("ignoring partial change (server advertised Full sync)", .{});
                },
            }
        }
    }

    pub fn @"textDocument/didClose"(
        self: *Server,
        _: std.mem.Allocator,
        params: lsp.types.TextDocument.DidCloseParams,
    ) !void {
        self.handler.closeDocument(params.textDocument.uri);
    }

    pub fn @"workspace/didChangeWatchedFiles"(
        self: *Server,
        _: std.mem.Allocator,
        _: lsp.types.workspace.did_change_watched_files.Params,
    ) !void {
        self.handler.reloadProject(self.io, self.workspace_path) catch |err| {
            std.log.warn("reloadProject failed: {s}", .{@errorName(err)});
            return;
        };
        self.requestDiagnosticRefresh() catch |err| {
            std.log.warn("workspace/diagnostic/refresh failed: {s}", .{@errorName(err)});
        };
    }

    pub fn @"textDocument/diagnostic"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.document_diagnostic.Params,
    ) !lsp.types.document_diagnostic.Report {
        const empty: lsp.types.document_diagnostic.Report = .{
            .related_full_document_diagnostic_report = .{
                .items = &.{},
                .resultId = null,
                .relatedDocuments = null,
            },
        };

        if (self.handler.getProjectInfo()) |proj| {
            if (proj.project_uri) |purl| if (std.mem.eql(u8, purl, params.textDocument.uri)) {
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
        const items = try arena.alloc(lsp.types.Diagnostic, handler_diags.len);
        for (handler_diags, 0..) |d, i| {
            const start_pos = lsp.offsets.indexToPosition(doc.source, d.span_start, self.offset_encoding);
            const end_pos = lsp.offsets.indexToPosition(doc.source, d.span_end, self.offset_encoding);
            items[i] = .{
                .range = .{ .start = start_pos, .end = end_pos },
                .severity = switch (d.severity) {
                    .err => .Error,
                    .warning => .Warning,
                },
                .code = .{ .string = d.code },
                .source = "sjon",
                .message = d.message,
            };
        }

        return .{
            .related_full_document_diagnostic_report = .{
                .items = items,
                .resultId = current_id,
                .relatedDocuments = null,
            },
        };
    }

    pub fn @"textDocument/prepareRename"(
        self: *Server,
        _: std.mem.Allocator,
        params: lsp.types.prepare_rename.Params,
    ) !?lsp.types.prepare_rename.Result {
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;
        const offset = lsp.offsets.positionToIndex(doc.source, params.position, self.offset_encoding);
        const pre = self.handler.prepareRename(params.textDocument.uri, @intCast(offset)) orelse return null;
        const start = lsp.offsets.indexToPosition(doc.source, pre.span_start, self.offset_encoding);
        const end = lsp.offsets.indexToPosition(doc.source, pre.span_end, self.offset_encoding);
        return .{ .range = .{ .start = start, .end = end } };
    }

    pub fn @"textDocument/rename"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.rename.Params,
    ) !?lsp.types.WorkspaceEdit {
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
                std.log.info("rename rejected: {s}", .{e.message});
                return null;
            },
            .edits => |w| w,
        };

        var changes: lsp.parser.Map(lsp.types.DocumentUri, []const lsp.types.TextEdit) = .{};
        for (we.changes) |fe| {
            const ref_doc = self.handler.getDocument(fe.uri) orelse {
                try changes.map.put(arena, fe.uri, &.{});
                continue;
            };
            const text_edits = try arena.alloc(lsp.types.TextEdit, fe.edits.len);
            for (fe.edits, 0..) |e, j| {
                const start = lsp.offsets.indexToPosition(ref_doc.source, e.span_start, self.offset_encoding);
                const end = lsp.offsets.indexToPosition(ref_doc.source, e.span_end, self.offset_encoding);
                text_edits[j] = .{
                    .range = .{ .start = start, .end = end },
                    .newText = e.new_text,
                };
            }
            try changes.map.put(arena, fe.uri, text_edits);
        }
        return .{ .changes = changes };
    }

    pub fn @"textDocument/references"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.reference.Params,
    ) !?[]const lsp.types.Location {
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;
        const offset = lsp.offsets.positionToIndex(doc.source, params.position, self.offset_encoding);
        const refs = (try self.handler.findReferences(
            arena,
            params.textDocument.uri,
            @intCast(offset),
            params.context.includeDeclaration,
        )) orelse return null;

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
    ) !?lsp.types.Hover {
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
    ) !?lsp.types.completion.Result {
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;
        const offset = lsp.offsets.positionToIndex(doc.source, params.position, self.offset_encoding);
        const items_or_null = try self.handler.getCompletion(arena, params.textDocument.uri, @intCast(offset));
        const handler_items = items_or_null orelse return null;
        const out = try arena.alloc(lsp.types.completion.Item, handler_items.len);
        for (handler_items, 0..) |it, i| {
            const lsp_tags: ?[]const lsp.types.completion.Item.Tag = blk: {
                if (it.tags.len == 0) break :blk null;
                const dst = try arena.alloc(lsp.types.completion.Item.Tag, it.tags.len);
                for (it.tags, 0..) |t, ti| dst[ti] = @enumFromInt(@intFromEnum(t));
                break :blk dst;
            };
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
    ) !?lsp.types.SignatureHelp {
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
    ) !?lsp.types.DocumentSymbol.Result {
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
    ) !?[]const lsp.types.FoldingRange {
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;
        const folds = (try self.handler.getFoldingRanges(arena, params.textDocument.uri)) orelse return null;

        var out: std.ArrayList(lsp.types.FoldingRange) = .empty;
        for (folds) |f| {
            const start_pos = lsp.offsets.indexToPosition(doc.source, f.span_start, self.offset_encoding);
            const end_pos = lsp.offsets.indexToPosition(doc.source, f.span_end, self.offset_encoding);
            if (start_pos.line == end_pos.line) continue;
            try out.append(arena, .{
                .startLine = start_pos.line,
                .endLine = end_pos.line,
            });
        }
        return try out.toOwnedSlice(arena);
    }

    pub fn @"textDocument/inlayHint"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.InlayHint.Params,
    ) !?[]const lsp.types.InlayHint {
        const doc = self.handler.getDocument(params.textDocument.uri) orelse return null;
        const start_offset: u32 = @intCast(lsp.offsets.positionToIndex(doc.source, params.range.start, self.offset_encoding));
        const end_offset: u32 = @intCast(lsp.offsets.positionToIndex(doc.source, params.range.end, self.offset_encoding));
        const hints = (try self.handler.getInlayHints(arena, params.textDocument.uri, start_offset, end_offset)) orelse return null;

        const out = try arena.alloc(lsp.types.InlayHint, hints.len);
        for (hints, 0..) |h, i| {
            out[i] = .{
                .position = lsp.offsets.indexToPosition(doc.source, h.offset, self.offset_encoding),
                .label = .{ .string = h.label },
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
    ) !?[]const lsp.types.TextEdit {
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

    pub fn @"textDocument/codeAction"(
        self: *Server,
        arena: std.mem.Allocator,
        params: lsp.types.CodeAction.Params,
    ) !?[]const lsp.types.CodeAction.Result {
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
            var changes = std.json.ArrayHashMap([]const lsp.types.TextEdit){};
            try changes.map.put(arena, params.textDocument.uri, text_edits);

            out[i] = .{
                .code_action = .{
                    .title = act.title,
                    .kind = .quickfix,
                    .edit = .{ .changes = changes },
                    .isPreferred = true,
                },
            };
        }
        return out;
    }

    pub fn onResponse(_: *Server, _: std.mem.Allocator, _: lsp.JsonRPCMessage.Response) void {}

    fn registerSjonFileWatcher(self: *Server) !void {
        const id = self.next_request_id;
        self.next_request_id +%= 1;
        const json = try std.fmt.allocPrint(self.gpa,
            \\{{"jsonrpc":"2.0","id":{d},"method":"client/registerCapability","params":{{"registrations":[{{"id":"sjon-watch","method":"workspace/didChangeWatchedFiles","registerOptions":{{"watchers":[{{"globPattern":"**/*.sjon"}}]}}}}]}}}}
        , .{id});
        defer self.gpa.free(json);
        try self.transport.writeJsonMessage(self.io, json);
    }

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
