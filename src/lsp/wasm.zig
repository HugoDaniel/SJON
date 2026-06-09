const std = @import("std");
const Allocator = std.mem.Allocator;
const Handler = @import("Handler");
const sjon_version = @import("sjon").version;
const offsets = @import("offsets.zig");

const wasm_allocator = std.heap.wasm_allocator;

var handler: Handler = undefined;
var handler_initialized: bool = false;
var outbox: std.ArrayList([]u8) = .empty;
var offset_encoding: offsets.Encoding = .@"utf-16";

export fn sjon_lsp_alloc(len: u32) callconv(.c) ?[*]u8 {
    if (len == 0) return null;
    const slice = wasm_allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

export fn sjon_lsp_dealloc(ptr: [*]u8, len: u32) callconv(.c) void {
    if (len == 0) return;
    wasm_allocator.free(ptr[0..len]);
}

export fn sjon_lsp_send(ptr: [*]const u8, len: u32) callconv(.c) void {
    if (!handler_initialized) {
        handler = Handler.init(wasm_allocator);
        handler_initialized = true;
    }
    handleMessage(ptr[0..len]);
}

export fn sjon_lsp_recv() callconv(.c) ?[*]u8 {
    if (outbox.items.len == 0) return null;
    const msg = outbox.orderedRemove(0);
    defer wasm_allocator.free(msg);

    const out = wasm_allocator.alloc(u8, 4 + msg.len) catch return null;
    std.mem.writeInt(u32, out[0..4], @intCast(msg.len), .little);
    @memcpy(out[4..][0..msg.len], msg);
    return out.ptr;
}

fn handleMessage(json: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, wasm_allocator, json, .{
        .ignore_unknown_fields = true,
        .max_value_len = null,
    }) catch return;
    defer parsed.deinit();

    if (parsed.value != .object) return;
    const root = parsed.value.object;

    const method_val = root.get("method") orelse return;
    if (method_val != .string) return;
    const method = method_val.string;
    const id = root.get("id");
    const params = root.get("params");

    if (eq(method, "initialize")) {
        handleInitialize(id, params);
    } else if (eq(method, "initialized") or eq(method, "exit")) {} else if (eq(method, "shutdown")) {
        sendNullResult(id);
    } else if (eq(method, "textDocument/didOpen")) {
        handleDidOpen(params);
    } else if (eq(method, "textDocument/didChange")) {
        handleDidChange(params);
    } else if (eq(method, "textDocument/didClose")) {
        handleDidClose(params);
    } else if (eq(method, "textDocument/diagnostic")) {
        handleDiagnostic(id, params);
    } else if (eq(method, "textDocument/hover")) {
        handleHover(id, params);
    } else if (eq(method, "textDocument/completion")) {
        handleCompletion(id, params);
    } else if (eq(method, "textDocument/signatureHelp")) {
        handleSignatureHelp(id, params);
    } else if (eq(method, "textDocument/documentSymbol")) {
        handleDocumentSymbol(id, params);
    } else if (eq(method, "textDocument/foldingRange")) {
        handleFoldingRange(id, params);
    } else if (eq(method, "textDocument/inlayHint")) {
        handleInlayHint(id, params);
    } else if (eq(method, "textDocument/formatting")) {
        handleFormatting(id, params);
    } else if (eq(method, "textDocument/codeAction")) {
        handleCodeAction(id, params);
    } else if (eq(method, "textDocument/references")) {
        handleReferences(id, params);
    } else if (eq(method, "textDocument/prepareRename")) {
        handlePrepareRename(id, params);
    } else if (eq(method, "textDocument/rename")) {
        handleRename(id, params);
    } else if (eq(method, "workspace/didChangeWatchedFiles")) {} else if (eq(method, "sjon/setSchemas")) {
        handleSetSchemas(id, params);
    } else if (id) |req_id| {
        sendMethodNotFound(req_id, method);
    }
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn handleInitialize(id: ?std.json.Value, params: ?std.json.Value) void {
    if (params) |p| if (p == .object) {
        if (p.object.get("capabilities")) |caps| if (caps == .object) {
            if (caps.object.get("general")) |gen| if (gen == .object) {
                if (gen.object.get("positionEncodings")) |encs| if (encs == .array) {
                    for (encs.array.items) |enc| {
                        if (enc != .string) continue;
                        if (eq(enc.string, "utf-8")) {
                            offset_encoding = .@"utf-8";
                            break;
                        } else if (eq(enc.string, "utf-16")) {
                            offset_encoding = .@"utf-16";
                            break;
                        } else if (eq(enc.string, "utf-32")) {
                            offset_encoding = .@"utf-32";
                            break;
                        }
                    }
                };
            };
        };
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    buf.appendSlice(wasm_allocator, "{\"capabilities\":{\"positionEncoding\":\"") catch return;
    buf.appendSlice(wasm_allocator, switch (offset_encoding) {
        .@"utf-8" => "utf-8",
        .@"utf-16" => "utf-16",
        .@"utf-32" => "utf-32",
    }) catch return;
    buf.appendSlice(wasm_allocator, "\",\"textDocumentSync\":{\"openClose\":true,\"change\":1}," ++
        "\"diagnosticProvider\":{\"interFileDependencies\":false,\"workspaceDiagnostics\":false}," ++
        "\"hoverProvider\":true," ++
        "\"completionProvider\":{\"triggerCharacters\":[\"(\",\":\",\"[\"]}," ++
        "\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\"],\"retriggerCharacters\":[\" \"]}," ++
        "\"documentSymbolProvider\":true," ++
        "\"documentFormattingProvider\":true," ++
        "\"foldingRangeProvider\":true," ++
        "\"inlayHintProvider\":true," ++
        "\"codeActionProvider\":{\"codeActionKinds\":[\"quickfix\"]}," ++
        "\"referencesProvider\":true," ++
        "\"renameProvider\":{\"prepareProvider\":true}}," ++
        "\"serverInfo\":{\"name\":\"sjon-lsp\",\"version\":\"") catch return;
    buf.appendSlice(wasm_allocator, sjon_version) catch return;
    buf.appendSlice(wasm_allocator, "\"}}") catch return;

    sendResultRaw(id, buf.items);
}

fn handleDidOpen(params: ?std.json.Value) void {
    const text_doc = getObject(params, "textDocument") orelse return;
    const uri = getString(text_doc, "uri") orelse return;
    const version = getInt(text_doc, "version") orelse 0;
    const text = getString(text_doc, "text") orelse return;
    handler.openDocument(uri, version, text) catch {};
}

fn handleDidChange(params: ?std.json.Value) void {
    const text_doc = getObject(params, "textDocument") orelse return;
    const uri = getString(text_doc, "uri") orelse return;
    const version = getInt(text_doc, "version") orelse 0;

    const p = params orelse return;
    if (p != .object) return;
    const changes = p.object.get("contentChanges") orelse return;
    if (changes != .array) return;
    for (changes.array.items) |change| {
        if (change != .object) continue;
        if (change.object.get("range") != null) continue;
        const text_v = change.object.get("text") orelse continue;
        if (text_v != .string) continue;
        handler.changeDocumentFull(uri, version, text_v.string) catch {};
        return;
    }
}

fn handleDidClose(params: ?std.json.Value) void {
    const text_doc = getObject(params, "textDocument") orelse return;
    const uri = getString(text_doc, "uri") orelse return;
    handler.closeDocument(uri);
}

fn handleDiagnostic(id: ?std.json.Value, params: ?std.json.Value) void {
    const req_id = id orelse return;
    const text_doc = getObject(params, "textDocument") orelse {
        sendEmptyFullReport(req_id, null);
        return;
    };
    const uri = getString(text_doc, "uri") orelse {
        sendEmptyFullReport(req_id, null);
        return;
    };
    const previous_id: ?[]const u8 = blk: {
        const p = params orelse break :blk null;
        if (p != .object) break :blk null;
        const v = p.object.get("previousResultId") orelse break :blk null;
        if (v != .string) break :blk null;
        break :blk v.string;
    };

    const doc = handler.getDocument(uri) orelse {
        sendEmptyFullReport(req_id, null);
        return;
    };

    var arena_state: std.heap.ArenaAllocator = .init(wasm_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const current_id = std.fmt.allocPrint(
        arena,
        "{d}:{d}",
        .{ doc.version, handler.schema_generation },
    ) catch {
        sendEmptyFullReport(req_id, null);
        return;
    };

    if (previous_id) |prev| if (eq(prev, current_id)) {
        sendUnchangedReport(req_id, current_id);
        return;
    };

    const diags_or_null = handler.getDiagnostics(arena, uri) catch {
        sendEmptyFullReport(req_id, current_id);
        return;
    };
    const diags = diags_or_null orelse {
        sendEmptyFullReport(req_id, current_id);
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    appendFullReport(&buf, doc.source, diags, current_id) catch {
        sendEmptyFullReport(req_id, current_id);
        return;
    };
    sendResultRawWithId(req_id, buf.items);
}

fn handleSetSchemas(id: ?std.json.Value, params: ?std.json.Value) void {
    const req_id = id orelse return;

    var arena_state: std.heap.ArenaAllocator = .init(wasm_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sources: std.ArrayList(Handler.SchemaSource) = .empty;
    if (params) |p| if (p == .object) {
        if (p.object.get("schemas")) |sv| if (sv == .array) {
            for (sv.array.items) |item| {
                if (item != .object) continue;
                const uri = getString(item.object, "uri") orelse continue;
                const text = getString(item.object, "text") orelse continue;
                sources.append(arena, .{ .uri = uri, .text = text }) catch {
                    sendResultRawWithId(req_id, "{\"reports\":[]}");
                    return;
                };
            }
        };
    };

    const reports = handler.setUserSchemas(arena, sources.items) catch {
        sendResultRawWithId(req_id, "{\"reports\":[]}");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    appendSetSchemasResult(&buf, sources.items, reports) catch {
        sendResultRawWithId(req_id, "{\"reports\":[]}");
        return;
    };
    sendResultRawWithId(req_id, buf.items);
}

fn handleHover(id: ?std.json.Value, params: ?std.json.Value) void {
    const req_id = id orelse return;

    const text_doc = getObject(params, "textDocument") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const uri = getString(text_doc, "uri") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const pos_obj = getObject(params, "position") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const line_v = pos_obj.get("line") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const ch_v = pos_obj.get("character") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    if (line_v != .integer or ch_v != .integer) {
        sendResultRawWithId(req_id, "null");
        return;
    }
    const position: offsets.Position = .{
        .line = @intCast(@max(0, line_v.integer)),
        .character = @intCast(@max(0, ch_v.integer)),
    };

    const doc = handler.getDocument(uri) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const byte_offset: u32 = @intCast(offsets.positionToIndex(doc.source, position, offset_encoding));

    var arena_state: std.heap.ArenaAllocator = .init(wasm_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const hov_or_null = handler.getHover(arena, uri, byte_offset) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const hov = hov_or_null orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    const start = offsets.indexToPosition(doc.source, hov.span_start, offset_encoding);
    const end = offsets.indexToPosition(doc.source, hov.span_end, offset_encoding);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    appendHover(&buf, hov.contents, start, end) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    sendResultRawWithId(req_id, buf.items);
}

fn appendHover(
    buf: *std.ArrayList(u8),
    markdown: []const u8,
    start: offsets.Position,
    end: offsets.Position,
) Allocator.Error!void {
    const a = wasm_allocator;
    try buf.appendSlice(a, "{\"contents\":{\"kind\":\"markdown\",\"value\":");
    try appendJsonString(buf, markdown);
    try buf.appendSlice(a, "},\"range\":{\"start\":{\"line\":");
    try appendUint(buf, start.line);
    try buf.appendSlice(a, ",\"character\":");
    try appendUint(buf, start.character);
    try buf.appendSlice(a, "},\"end\":{\"line\":");
    try appendUint(buf, end.line);
    try buf.appendSlice(a, ",\"character\":");
    try appendUint(buf, end.character);
    try buf.appendSlice(a, "}}}");
}

fn handleCompletion(id: ?std.json.Value, params: ?std.json.Value) void {
    const req_id = id orelse return;

    const text_doc = getObject(params, "textDocument") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const uri = getString(text_doc, "uri") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const pos_obj = getObject(params, "position") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const line_v = pos_obj.get("line") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const ch_v = pos_obj.get("character") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    if (line_v != .integer or ch_v != .integer) {
        sendResultRawWithId(req_id, "null");
        return;
    }
    const position: offsets.Position = .{
        .line = @intCast(@max(0, line_v.integer)),
        .character = @intCast(@max(0, ch_v.integer)),
    };

    const doc = handler.getDocument(uri) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const byte_offset: u32 = @intCast(offsets.positionToIndex(doc.source, position, offset_encoding));

    var arena_state: std.heap.ArenaAllocator = .init(wasm_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items_or_null = handler.getCompletion(arena, uri, byte_offset) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const items = items_or_null orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    appendCompletionItems(&buf, items) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    sendResultRawWithId(req_id, buf.items);
}

fn appendCompletionItems(
    buf: *std.ArrayList(u8),
    items: []const Handler.CompletionItem,
) Allocator.Error!void {
    const a = wasm_allocator;
    try buf.append(a, '[');
    for (items, 0..) |it, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.appendSlice(a, "{\"label\":");
        try appendJsonString(buf, it.label);
        try buf.appendSlice(a, ",\"kind\":");
        try appendUint(buf, @intFromEnum(it.kind));
        if (it.detail.len > 0) {
            try buf.appendSlice(a, ",\"detail\":");
            try appendJsonString(buf, it.detail);
        }
        if (it.documentation.len > 0) {
            try buf.appendSlice(a, ",\"documentation\":");
            try appendJsonString(buf, it.documentation);
        }
        if (it.insert_text) |snippet| {
            try buf.appendSlice(a, ",\"insertText\":");
            try appendJsonString(buf, snippet);
            try buf.appendSlice(a, ",\"insertTextFormat\":");
            try appendUint(buf, @intFromEnum(it.insert_text_format));
        }
        if (it.tags.len > 0) {
            try buf.appendSlice(a, ",\"tags\":[");
            for (it.tags, 0..) |t, ti| {
                if (ti > 0) try buf.append(a, ',');
                try appendUint(buf, @intFromEnum(t));
            }
            try buf.append(a, ']');
        }
        if (it.sort_text) |s| {
            try buf.appendSlice(a, ",\"sortText\":");
            try appendJsonString(buf, s);
        }
        if (it.filter_text) |s| {
            try buf.appendSlice(a, ",\"filterText\":");
            try appendJsonString(buf, s);
        }
        if (it.commit_characters.len > 0) {
            try buf.appendSlice(a, ",\"commitCharacters\":[");
            for (it.commit_characters, 0..) |c, ci| {
                if (ci > 0) try buf.append(a, ',');
                try appendJsonString(buf, &[_]u8{c});
            }
            try buf.append(a, ']');
        }
        try buf.append(a, '}');
    }
    try buf.append(a, ']');
}

fn handleSignatureHelp(id: ?std.json.Value, params: ?std.json.Value) void {
    const req_id = id orelse return;

    const text_doc = getObject(params, "textDocument") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const uri = getString(text_doc, "uri") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const pos_obj = getObject(params, "position") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const line_v = pos_obj.get("line") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const ch_v = pos_obj.get("character") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    if (line_v != .integer or ch_v != .integer) {
        sendResultRawWithId(req_id, "null");
        return;
    }
    const position: offsets.Position = .{
        .line = @intCast(@max(0, line_v.integer)),
        .character = @intCast(@max(0, ch_v.integer)),
    };

    const doc = handler.getDocument(uri) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const byte_offset: u32 = @intCast(offsets.positionToIndex(doc.source, position, offset_encoding));

    var arena_state: std.heap.ArenaAllocator = .init(wasm_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const help_or_null = handler.getSignatureHelp(arena, uri, byte_offset) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const help = help_or_null orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    appendSignatureHelp(&buf, help) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    sendResultRawWithId(req_id, buf.items);
}

fn appendSignatureHelp(
    buf: *std.ArrayList(u8),
    help: Handler.SignatureHelp,
) Allocator.Error!void {
    const a = wasm_allocator;
    try buf.appendSlice(a, "{\"signatures\":[");
    for (help.signatures, 0..) |s, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.appendSlice(a, "{\"label\":");
        try appendJsonString(buf, s.label);
        if (s.documentation.len > 0) {
            try buf.appendSlice(a, ",\"documentation\":{\"kind\":\"markdown\",\"value\":");
            try appendJsonString(buf, s.documentation);
            try buf.append(a, '}');
        }
        try buf.appendSlice(a, ",\"parameters\":[");
        for (s.parameters, 0..) |p, j| {
            if (j > 0) try buf.append(a, ',');
            try buf.appendSlice(a, "{\"label\":[");
            try appendUint(buf, p.label_start);
            try buf.append(a, ',');
            try appendUint(buf, p.label_end);
            try buf.appendSlice(a, "]}");
        }
        try buf.appendSlice(a, "]}");
    }
    try buf.appendSlice(a, "],\"activeSignature\":");
    try appendUint(buf, help.active_signature);
    if (help.active_parameter) |ap| {
        try buf.appendSlice(a, ",\"activeParameter\":");
        try appendUint(buf, ap);
    }
    try buf.append(a, '}');
}

fn handleDocumentSymbol(id: ?std.json.Value, params: ?std.json.Value) void {
    const req_id = id orelse return;
    const text_doc = getObject(params, "textDocument") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const uri = getString(text_doc, "uri") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const doc = handler.getDocument(uri) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    var arena_state: std.heap.ArenaAllocator = .init(wasm_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const syms_or_null = handler.getDocumentSymbols(arena, uri) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const syms = syms_or_null orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    appendSymbolList(&buf, doc.source, syms) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    sendResultRawWithId(req_id, buf.items);
}

fn appendSymbolList(
    buf: *std.ArrayList(u8),
    source: []const u8,
    syms: []const Handler.DocumentSymbol,
) Allocator.Error!void {
    const a = wasm_allocator;
    try buf.append(a, '[');
    for (syms, 0..) |s, i| {
        if (i > 0) try buf.append(a, ',');
        const range_start = offsets.indexToPosition(source, s.span_start, offset_encoding);
        const range_end = offsets.indexToPosition(source, s.span_end, offset_encoding);
        const sel_start = offsets.indexToPosition(source, s.selection_start, offset_encoding);
        const sel_end = offsets.indexToPosition(source, s.selection_end, offset_encoding);
        try buf.appendSlice(a, "{\"name\":");
        try appendJsonString(buf, if (s.name.len > 0) s.name else "(anonymous)");
        try buf.appendSlice(a, ",\"kind\":9,\"range\":");
        try appendRange(buf, range_start, range_end);
        try buf.appendSlice(a, ",\"selectionRange\":");
        try appendRange(buf, sel_start, sel_end);
        try buf.appendSlice(a, ",\"children\":");
        try appendSymbolList(buf, source, s.children);
        try buf.append(a, '}');
    }
    try buf.append(a, ']');
}

fn appendRange(
    buf: *std.ArrayList(u8),
    start: offsets.Position,
    end: offsets.Position,
) Allocator.Error!void {
    const a = wasm_allocator;
    try buf.appendSlice(a, "{\"start\":{\"line\":");
    try appendUint(buf, start.line);
    try buf.appendSlice(a, ",\"character\":");
    try appendUint(buf, start.character);
    try buf.appendSlice(a, "},\"end\":{\"line\":");
    try appendUint(buf, end.line);
    try buf.appendSlice(a, ",\"character\":");
    try appendUint(buf, end.character);
    try buf.appendSlice(a, "}}");
}

fn handleFoldingRange(id: ?std.json.Value, params: ?std.json.Value) void {
    const req_id = id orelse return;
    const text_doc = getObject(params, "textDocument") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const uri = getString(text_doc, "uri") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const doc = handler.getDocument(uri) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    var arena_state: std.heap.ArenaAllocator = .init(wasm_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const folds_or_null = handler.getFoldingRanges(arena, uri) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const folds = folds_or_null orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    appendFoldingRanges(&buf, doc.source, folds) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    sendResultRawWithId(req_id, buf.items);
}

fn appendFoldingRanges(
    buf: *std.ArrayList(u8),
    source: []const u8,
    folds: []const Handler.FoldingRange,
) Allocator.Error!void {
    const a = wasm_allocator;
    try buf.append(a, '[');
    var first = true;
    for (folds) |f| {
        const start = offsets.indexToPosition(source, f.span_start, offset_encoding);
        const end = offsets.indexToPosition(source, f.span_end, offset_encoding);
        if (start.line == end.line) continue;
        if (!first) try buf.append(a, ',');
        first = false;
        try buf.appendSlice(a, "{\"startLine\":");
        try appendUint(buf, start.line);
        try buf.appendSlice(a, ",\"endLine\":");
        try appendUint(buf, end.line);
        try buf.append(a, '}');
    }
    try buf.append(a, ']');
}

fn handleInlayHint(id: ?std.json.Value, params: ?std.json.Value) void {
    const req_id = id orelse return;
    const text_doc = getObject(params, "textDocument") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const uri = getString(text_doc, "uri") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const range_obj = getObject(params, "range") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const start_pos = parsePosition(range_obj.get("start")) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const end_pos = parsePosition(range_obj.get("end")) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    const doc = handler.getDocument(uri) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const start_offset: u32 = @intCast(offsets.positionToIndex(doc.source, start_pos, offset_encoding));
    const end_offset: u32 = @intCast(offsets.positionToIndex(doc.source, end_pos, offset_encoding));

    var arena_state: std.heap.ArenaAllocator = .init(wasm_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const hints_or_null = handler.getInlayHints(arena, uri, start_offset, end_offset) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const hints = hints_or_null orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    appendInlayHints(&buf, doc.source, hints) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    sendResultRawWithId(req_id, buf.items);
}

fn appendInlayHints(
    buf: *std.ArrayList(u8),
    source: []const u8,
    hints: []const Handler.InlayHint,
) Allocator.Error!void {
    const a = wasm_allocator;
    try buf.append(a, '[');
    for (hints, 0..) |h, i| {
        if (i > 0) try buf.append(a, ',');
        const pos = offsets.indexToPosition(source, h.offset, offset_encoding);
        try buf.appendSlice(a, "{\"position\":{\"line\":");
        try appendUint(buf, pos.line);
        try buf.appendSlice(a, ",\"character\":");
        try appendUint(buf, pos.character);
        try buf.appendSlice(a, "},\"label\":");
        try appendJsonString(buf, h.label);
        if (h.padding_left) try buf.appendSlice(a, ",\"paddingLeft\":true");
        if (h.padding_right) try buf.appendSlice(a, ",\"paddingRight\":true");
        try buf.append(a, '}');
    }
    try buf.append(a, ']');
}

fn handleFormatting(id: ?std.json.Value, params: ?std.json.Value) void {
    const req_id = id orelse return;
    const text_doc = getObject(params, "textDocument") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const uri = getString(text_doc, "uri") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const doc = handler.getDocument(uri) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    var arena_state: std.heap.ArenaAllocator = .init(wasm_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const edits_or_null = handler.getFormatEdits(arena, uri) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const edits = edits_or_null orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    appendTextEdits(&buf, doc.source, edits) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    sendResultRawWithId(req_id, buf.items);
}

fn appendTextEdits(
    buf: *std.ArrayList(u8),
    source: []const u8,
    edits: []const Handler.TextEdit,
) Allocator.Error!void {
    const a = wasm_allocator;
    try buf.append(a, '[');
    for (edits, 0..) |e, i| {
        if (i > 0) try buf.append(a, ',');
        const start = offsets.indexToPosition(source, e.span_start, offset_encoding);
        const end = offsets.indexToPosition(source, e.span_end, offset_encoding);
        try buf.appendSlice(a, "{\"range\":");
        try appendRange(buf, start, end);
        try buf.appendSlice(a, ",\"newText\":");
        try appendJsonString(buf, e.new_text);
        try buf.append(a, '}');
    }
    try buf.append(a, ']');
}

fn handleCodeAction(id: ?std.json.Value, params: ?std.json.Value) void {
    const req_id = id orelse return;
    const text_doc = getObject(params, "textDocument") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const uri = getString(text_doc, "uri") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const range_obj = getObject(params, "range") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const start_pos = parsePosition(range_obj.get("start")) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const end_pos = parsePosition(range_obj.get("end")) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    const doc = handler.getDocument(uri) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const start_offset: u32 = @intCast(offsets.positionToIndex(doc.source, start_pos, offset_encoding));
    const end_offset: u32 = @intCast(offsets.positionToIndex(doc.source, end_pos, offset_encoding));

    var arena_state: std.heap.ArenaAllocator = .init(wasm_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const actions_or_null = handler.getCodeActions(arena, uri, start_offset, end_offset) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const actions = actions_or_null orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    appendCodeActions(&buf, doc.source, uri, actions) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    sendResultRawWithId(req_id, buf.items);
}

fn handleReferences(id: ?std.json.Value, params: ?std.json.Value) void {
    const req_id = id orelse return;
    const text_doc = getObject(params, "textDocument") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const uri = getString(text_doc, "uri") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const position = parsePosition(if (params) |p| p.object.get("position") else null) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    var include_declaration = false;
    if (params) |p| {
        if (p.object.get("context")) |ctx| if (ctx == .object) {
            if (ctx.object.get("includeDeclaration")) |incl| if (incl == .bool) {
                include_declaration = incl.bool;
            };
        };
    }

    const doc = handler.getDocument(uri) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const byte_offset: u32 = @intCast(offsets.positionToIndex(doc.source, position, offset_encoding));

    var arena_state: std.heap.ArenaAllocator = .init(wasm_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const refs_or_null = handler.findReferences(arena, uri, byte_offset, include_declaration) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const refs = refs_or_null orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    appendLocations(&buf, refs) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    sendResultRawWithId(req_id, buf.items);
}

fn handlePrepareRename(id: ?std.json.Value, params: ?std.json.Value) void {
    const req_id = id orelse return;
    const text_doc = getObject(params, "textDocument") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const uri = getString(text_doc, "uri") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const position = parsePosition(if (params) |p| p.object.get("position") else null) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    const doc = handler.getDocument(uri) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const byte_offset: u32 = @intCast(offsets.positionToIndex(doc.source, position, offset_encoding));

    const pre = handler.prepareRename(uri, byte_offset) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const start = offsets.indexToPosition(doc.source, pre.span_start, offset_encoding);
    const end = offsets.indexToPosition(doc.source, pre.span_end, offset_encoding);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    buf.appendSlice(wasm_allocator, "{\"range\":") catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    appendRange(&buf, start, end) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    buf.append(wasm_allocator, '}') catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    sendResultRawWithId(req_id, buf.items);
}

fn handleRename(id: ?std.json.Value, params: ?std.json.Value) void {
    const req_id = id orelse return;
    const params_obj: std.json.ObjectMap = blk: {
        if (params) |p| if (p == .object) break :blk p.object;
        sendResultRawWithId(req_id, "null");
        return;
    };
    const text_doc = getObject(params, "textDocument") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const uri = getString(text_doc, "uri") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const position = parsePosition(params_obj.get("position")) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const new_name = getString(params_obj, "newName") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    const doc = handler.getDocument(uri) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const byte_offset: u32 = @intCast(offsets.positionToIndex(doc.source, position, offset_encoding));

    var arena_state: std.heap.ArenaAllocator = .init(wasm_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result_or_null = handler.rename(arena, uri, byte_offset, new_name) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const result = result_or_null orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const we = switch (result) {
        .err => {
            sendResultRawWithId(req_id, "null");
            return;
        },
        .edits => |w| w,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    appendWorkspaceEdit(&buf, we) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    sendResultRawWithId(req_id, buf.items);
}

fn appendWorkspaceEdit(
    buf: *std.ArrayList(u8),
    we: Handler.WorkspaceEdit,
) Allocator.Error!void {
    const a = wasm_allocator;
    try buf.appendSlice(a, "{\"changes\":{");
    var emitted: usize = 0;
    for (we.changes) |fe| {
        const ref_doc = handler.getDocument(fe.uri) orelse continue;
        if (emitted > 0) try buf.append(a, ',');
        try appendJsonString(buf, fe.uri);
        try buf.append(a, ':');
        try appendTextEditList(buf, ref_doc.source, fe.edits);
        emitted += 1;
    }
    try buf.appendSlice(a, "}}");
}

fn appendLocations(
    buf: *std.ArrayList(u8),
    locations: []const Handler.Location,
) Allocator.Error!void {
    const a = wasm_allocator;
    try buf.append(a, '[');
    var emitted: usize = 0;
    for (locations) |loc| {
        const ref_doc = handler.getDocument(loc.uri) orelse continue;
        if (emitted > 0) try buf.append(a, ',');
        const start = offsets.indexToPosition(ref_doc.source, loc.span_start, offset_encoding);
        const end = offsets.indexToPosition(ref_doc.source, loc.span_end, offset_encoding);
        try buf.appendSlice(a, "{\"uri\":");
        try appendJsonString(buf, loc.uri);
        try buf.appendSlice(a, ",\"range\":");
        try appendRange(buf, start, end);
        try buf.append(a, '}');
        emitted += 1;
    }
    try buf.append(a, ']');
}

fn parsePosition(v: ?std.json.Value) ?offsets.Position {
    const value = v orelse return null;
    if (value != .object) return null;
    const line = value.object.get("line") orelse return null;
    const ch = value.object.get("character") orelse return null;
    if (line != .integer or ch != .integer) return null;
    return .{
        .line = @intCast(@max(0, line.integer)),
        .character = @intCast(@max(0, ch.integer)),
    };
}

fn appendCodeActions(
    buf: *std.ArrayList(u8),
    source: []const u8,
    uri: []const u8,
    actions: []const Handler.CodeAction,
) Allocator.Error!void {
    const a = wasm_allocator;
    try buf.append(a, '[');
    for (actions, 0..) |act, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.appendSlice(a, "{\"title\":");
        try appendJsonString(buf, act.title);
        try buf.appendSlice(a, ",\"kind\":\"quickfix\",\"isPreferred\":true,\"edit\":{\"changes\":{");
        try appendJsonString(buf, uri);
        try buf.append(a, ':');
        try appendTextEditList(buf, source, act.edits);
        try buf.appendSlice(a, "}}}");
    }
    try buf.append(a, ']');
}

fn appendTextEditList(
    buf: *std.ArrayList(u8),
    source: []const u8,
    edits: []const Handler.TextEdit,
) Allocator.Error!void {
    const a = wasm_allocator;
    try buf.append(a, '[');
    for (edits, 0..) |e, i| {
        if (i > 0) try buf.append(a, ',');
        const start = offsets.indexToPosition(source, e.span_start, offset_encoding);
        const end = offsets.indexToPosition(source, e.span_end, offset_encoding);
        try buf.appendSlice(a, "{\"range\":");
        try appendRange(buf, start, end);
        try buf.appendSlice(a, ",\"newText\":");
        try appendJsonString(buf, e.new_text);
        try buf.append(a, '}');
    }
    try buf.append(a, ']');
}

fn appendFullReport(
    buf: *std.ArrayList(u8),
    source: []const u8,
    diags: []const Handler.Diagnostic,
    result_id: []const u8,
) Allocator.Error!void {
    const a = wasm_allocator;
    try buf.appendSlice(a, "{\"kind\":\"full\",\"resultId\":");
    try appendJsonString(buf, result_id);
    try buf.appendSlice(a, ",\"items\":[");
    try appendDiagnosticItems(buf, source, diags);
    try buf.appendSlice(a, "]}");
}

fn appendDiagnosticItems(
    buf: *std.ArrayList(u8),
    source: []const u8,
    diags: []const Handler.Diagnostic,
) Allocator.Error!void {
    const a = wasm_allocator;
    for (diags, 0..) |d, i| {
        if (i > 0) try buf.append(a, ',');
        const start = offsets.indexToPosition(source, d.span_start, offset_encoding);
        const end = offsets.indexToPosition(source, d.span_end, offset_encoding);
        try buf.appendSlice(a, "{\"range\":{\"start\":{\"line\":");
        try appendUint(buf, start.line);
        try buf.appendSlice(a, ",\"character\":");
        try appendUint(buf, start.character);
        try buf.appendSlice(a, "},\"end\":{\"line\":");
        try appendUint(buf, end.line);
        try buf.appendSlice(a, ",\"character\":");
        try appendUint(buf, end.character);
        try buf.appendSlice(a, "}},\"severity\":");
        try appendUint(buf, switch (d.severity) {
            .err => @as(u32, 1),
            .warning => @as(u32, 2),
        });
        try buf.appendSlice(a, ",\"source\":\"sjon\",\"code\":");
        try appendJsonString(buf, d.code);
        try buf.appendSlice(a, ",\"message\":");
        try appendJsonString(buf, d.message);
        try buf.append(a, '}');
    }
}

fn appendSetSchemasResult(
    buf: *std.ArrayList(u8),
    sources: []const Handler.SchemaSource,
    reports: []const Handler.SchemaReport,
) Allocator.Error!void {
    std.debug.assert(sources.len == reports.len);
    const a = wasm_allocator;
    try buf.appendSlice(a, "{\"reports\":[");
    for (reports, 0..) |r, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.appendSlice(a, "{\"uri\":");
        try appendJsonString(buf, r.uri);
        try buf.appendSlice(a, ",\"name\":");
        try appendJsonString(buf, r.name);
        try buf.appendSlice(a, ",\"items\":[");
        try appendDiagnosticItems(buf, sources[i].text, r.diagnostics);
        try buf.appendSlice(a, "]}");
    }
    try buf.appendSlice(a, "]}");
}

fn appendJsonString(buf: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    const a = wasm_allocator;
    try buf.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(a, "\\\""),
        '\\' => try buf.appendSlice(a, "\\\\"),
        '\n' => try buf.appendSlice(a, "\\n"),
        '\r' => try buf.appendSlice(a, "\\r"),
        '\t' => try buf.appendSlice(a, "\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
            var esc_buf: [8]u8 = undefined;
            const s2 = std.fmt.bufPrint(&esc_buf, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(a, s2);
        },
        else => try buf.append(a, c),
    };
    try buf.append(a, '"');
}

fn appendUint(buf: *std.ArrayList(u8), n: u32) Allocator.Error!void {
    var num_buf: [10]u8 = undefined;
    const s = std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch unreachable;
    try buf.appendSlice(wasm_allocator, s);
}

fn appendIdJson(buf: *std.ArrayList(u8), id: std.json.Value) Allocator.Error!void {
    const a = wasm_allocator;
    switch (id) {
        .string => |s| try appendJsonString(buf, s),
        .integer => |n| {
            var num_buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch unreachable;
            try buf.appendSlice(a, s);
        },
        .null => try buf.appendSlice(a, "null"),
        else => try buf.appendSlice(a, "null"),
    }
}

fn sendEmptyFullReport(id: std.json.Value, result_id: ?[]const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    buf.appendSlice(wasm_allocator, "{\"kind\":\"full\",\"resultId\":") catch return;
    if (result_id) |rid| {
        appendJsonString(&buf, rid) catch return;
    } else {
        buf.appendSlice(wasm_allocator, "null") catch return;
    }
    buf.appendSlice(wasm_allocator, ",\"items\":[]}") catch return;
    sendResultRawWithId(id, buf.items);
}

fn sendUnchangedReport(id: std.json.Value, result_id: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    buf.appendSlice(wasm_allocator, "{\"kind\":\"unchanged\",\"resultId\":") catch return;
    appendJsonString(&buf, result_id) catch return;
    buf.append(wasm_allocator, '}') catch return;
    sendResultRawWithId(id, buf.items);
}

fn sendResultRaw(id: ?std.json.Value, result_json: []const u8) void {
    if (id) |i| sendResultRawWithId(i, result_json);
}

fn sendResultRawWithId(id: std.json.Value, result_json: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    buf.appendSlice(wasm_allocator, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendIdJson(&buf, id) catch return;
    buf.appendSlice(wasm_allocator, ",\"result\":") catch return;
    buf.appendSlice(wasm_allocator, result_json) catch return;
    buf.append(wasm_allocator, '}') catch return;
    enqueue(buf.toOwnedSlice(wasm_allocator) catch return);
}

fn sendNullResult(id: ?std.json.Value) void {
    if (id) |i| sendResultRawWithId(i, "null");
}

fn sendMethodNotFound(id: std.json.Value, method: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    buf.appendSlice(wasm_allocator, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendIdJson(&buf, id) catch return;
    buf.appendSlice(wasm_allocator, ",\"error\":{\"code\":-32601,\"message\":\"method not found: ") catch return;
    appendUnquoted(&buf, method) catch return;
    buf.appendSlice(wasm_allocator, "\"}}") catch return;
    enqueue(buf.toOwnedSlice(wasm_allocator) catch return);
}

fn appendUnquoted(buf: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    const a = wasm_allocator;
    for (s) |c| switch (c) {
        '"', '\\' => {
            try buf.append(a, '\\');
            try buf.append(a, c);
        },
        else => try buf.append(a, c),
    };
}

fn getObject(parent: ?std.json.Value, key: []const u8) ?std.json.ObjectMap {
    const p = parent orelse return null;
    if (p != .object) return null;
    const v = p.object.get(key) orelse return null;
    if (v != .object) return null;
    return v.object;
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        else => null,
    };
}

fn enqueue(slice: []u8) void {
    outbox.append(wasm_allocator, slice) catch wasm_allocator.free(slice);
}
