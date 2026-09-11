//! SJON Language Server — WASM entry point.
//!
//! Hand-rolled JSON-RPC dispatcher (no lsp-kit dep — that pulls stdio
//! basic_server bits we don't need, and freestanding-wasm doesn't have
//! stdio anyway). The JS side feeds JSON messages in via
//! `sjon_lsp_send` and polls outgoing responses via `sjon_lsp_recv`.
//!
//! The same `Handler` powers the native build (see `main.zig`); only
//! the wire-shape translation is target-specific.
//!
//! JS contract — symmetrical to wgslender's WASM LSP:
//! ```
//! // Send:
//! const buf = encoder.encode(json);
//! const ptr = wasm.sjon_lsp_alloc(buf.length);
//! new Uint8Array(memory.buffer, ptr, buf.length).set(buf);
//! wasm.sjon_lsp_send(ptr, buf.length);
//!
//! // Drain responses:
//! for (;;) {
//!   const rptr = wasm.sjon_lsp_recv();
//!   if (!rptr) break;
//!   const len = new DataView(memory.buffer).getUint32(rptr, true);
//!   const msg = decoder.decode(new Uint8Array(memory.buffer, rptr + 4, len));
//!   wasm.sjon_lsp_dealloc(rptr, len + 4);
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Handler = @import("Handler");
// `sjon.version` re-exports the leaf `version.zig` constant. Routed
// through the module system rather than `@import("../version.zig")` —
// a relative import escaping this file's module directory is rejected
// by the compiler. The LSP wasm already links `sjon` transitively via
// `Handler`, so this adds no code.
const sjon_version = @import("sjon").version;
// The shared WASM JSON writers — one escaper home for the whole project
// (see `wasm_common.appendJsonString`). Reached via the `sjon` root
// re-export rather than a cross-directory relative import.
const wasm_common = @import("sjon").wasm_common;
const offsets = @import("offsets.zig");
const text_sync = @import("text_sync.zig");

// Wasm-only in production. The native build (the `lsp-wasm-dispatch`
// test target) is always a test build, so it gates to the testing
// allocator — that both makes the dispatch handlers unit-testable and
// leak-checks the outbox. The `.wasm32` branch is comptime-selected, so
// `std.testing.allocator` is never analyzed in the shipped artifact.
const wasm_allocator = if (builtin.target.cpu.arch == .wasm32)
    std.heap.wasm_allocator
else
    std.testing.allocator;

var handler: Handler = undefined;
var handler_initialized: bool = false;
var outbox: std.ArrayList([]u8) = .empty;
var offset_encoding: offsets.Encoding = .@"utf-16";
/// Whether the client accepts `WorkspaceEdit.documentChanges`, from
/// `capabilities.workspace.workspaceEdit.documentChanges`. Only that form
/// can carry a document version; see `appendWorkspaceEdit`.
var client_document_changes: bool = false;

// =========================================================================
// Exports
// =========================================================================

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

/// Returns `[u32 len][u8... json]` or null when the outbox is empty.
/// Caller frees with `sjon_lsp_dealloc(ptr, len + 4)`.
export fn sjon_lsp_recv() callconv(.c) ?[*]u8 {
    if (outbox.items.len == 0) return null;
    // Allocate the frame *before* popping: the JS pump reads null as
    // "outbox empty", so an allocation failure after the pop would drop
    // the reply on the floor and leave the client's request pending
    // forever. Failing before the pop keeps the message queued for the
    // next call.
    const head = outbox.items[0];
    const out = wasm_allocator.alloc(u8, 4 + head.len) catch return null;
    const msg = outbox.orderedRemove(0);
    defer wasm_allocator.free(msg);

    std.mem.writeInt(u32, out[0..4], @intCast(msg.len), .little);
    @memcpy(out[4..][0..msg.len], msg);
    return out.ptr;
}

// =========================================================================
// JSON-RPC dispatch
// =========================================================================

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
    } else if (eq(method, "initialized") or eq(method, "exit")) {
        // No-op.
    } else if (eq(method, "shutdown")) {
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
    } else if (eq(method, "textDocument/semanticTokens/full")) {
        handleSemanticTokensFull(id, params);
    } else if (eq(method, "textDocument/formatting")) {
        handleFormatting(id, params);
    } else if (eq(method, "textDocument/rangeFormatting")) {
        handleRangeFormatting(id, params);
    } else if (eq(method, "textDocument/codeAction")) {
        handleCodeAction(id, params);
    } else if (eq(method, "textDocument/definition")) {
        handleDefinition(id, params);
    } else if (eq(method, "textDocument/documentHighlight")) {
        handleDocumentHighlight(id, params);
    } else if (eq(method, "textDocument/selectionRange")) {
        handleSelectionRange(id, params);
    } else if (eq(method, "workspace/symbol")) {
        handleWorkspaceSymbol(id, params);
    } else if (eq(method, "textDocument/references")) {
        handleReferences(id, params);
    } else if (eq(method, "textDocument/prepareRename")) {
        handlePrepareRename(id, params);
    } else if (eq(method, "textDocument/rename")) {
        handleRename(id, params);
    } else if (eq(method, "workspace/didChangeWatchedFiles")) {
        // Intentional no-op. The native transport reloads the project
        // file + manifests from disk on this notification, but freestanding
        // WASM has no filesystem to read from — manifests reach the
        // schema only by being baked into the binary at compile time.
        // Returning early silences the would-be method-not-found path.
    } else if (eq(method, "sjon/setSchemas")) {
        // Non-standard extension: install user-authored (plugin …)
        // manifests as the live schema. The native transport resolves
        // schemas from the filesystem instead, so this method is
        // WASM-only (the playground "+ schema" panes).
        handleSetSchemas(id, params);
    } else if (eq(method, "sjon/effectiveDocument")) {
        // Non-standard extension: the document with every omitted
        // defaulted key spliced in, for a read-only "effective view"
        // pane. WASM-only for a structural reason, not a scheduling one
        // — lsp-kit's `basic_server.run` dispatches over a generated,
        // closed union of standard LSP methods, so the native transport
        // cannot route an `sjon/`-namespaced method without replacing
        // its message loop. `sjon/setSchemas` above is WASM-only for the
        // same reason.
        handleEffectiveDocument(id, params);
    } else if (eq(method, "sjon/evalDocument")) {
        // Non-standard extension: every expression root's computed value,
        // for the playground's output panel. WASM-only for the same
        // structural reason as the two above.
        handleEvalDocument(id, params);
    } else if (id) |req_id| {
        sendMethodNotFound(req_id, method);
    }
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// -- Method handlers --------------------------------------------------------

/// The `semanticTokensProvider.legend` object, built at comptime from
/// `SemanticToken`'s own name lists. Generated rather than hand-written
/// because the client maps every token's type index and modifier bit
/// through this object: a legend that disagreed with the enum would
/// recolour the whole document with no test able to see it from one side.
const semantic_legend_json = blk: {
    var s: []const u8 = "{\"tokenTypes\":[";
    for (Handler.SemanticToken.Type.legend, 0..) |name, i| {
        s = s ++ (if (i > 0) "," else "") ++ "\"" ++ name ++ "\"";
    }
    s = s ++ "],\"tokenModifiers\":[";
    for (Handler.SemanticToken.Mods.legend, 0..) |name, i| {
        s = s ++ (if (i > 0) "," else "") ++ "\"" ++ name ++ "\"";
    }
    break :blk s ++ "]}";
};

fn handleInitialize(id: ?std.json.Value, params: ?std.json.Value) void {
    if (params) |p| if (p == .object) {
        if (p.object.get("capabilities")) |caps| if (caps == .object) {
            if (caps.object.get("workspace")) |ws| if (ws == .object) {
                if (ws.object.get("workspaceEdit")) |we| if (we == .object) {
                    if (we.object.get("documentChanges")) |dc| if (dc == .bool) {
                        client_document_changes = dc.bool;
                    };
                };
            };
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
    // `interFileDependencies` is true for the reason spelled out in
    // `main.zig`'s capability block: forest revalidation means an edit in
    // one document can change another's diagnostics. Kept in sync there.
    // change: 2 = Incremental. Ranged payloads are spliced via
    // `text_sync.applyChanges`; the whole-document form stays supported
    // as the spec-required fallback.
    buf.appendSlice(wasm_allocator, "\",\"textDocumentSync\":{\"openClose\":true,\"change\":2}," ++
        "\"diagnosticProvider\":{\"interFileDependencies\":true,\"workspaceDiagnostics\":false}," ++
        "\"hoverProvider\":true," ++
        "\"completionProvider\":{\"triggerCharacters\":[\"(\",\":\",\"[\"]}," ++
        "\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\"],\"retriggerCharacters\":[\" \"]}," ++
        "\"documentSymbolProvider\":true," ++
        "\"documentFormattingProvider\":true," ++
        "\"documentRangeFormattingProvider\":true," ++
        "\"foldingRangeProvider\":true," ++
        "\"inlayHintProvider\":true," ++
        // `full` only: SJON documents are small enough that a whole-file
        // recompute costs less than tracking deltas, and advertising
        // `range` or `full.delta` would invite requests we don't answer.
        // The legend is emitted from `SemanticToken`'s own lists below, so
        // the indices on the wire cannot drift from the enum.
        "\"semanticTokensProvider\":{\"full\":true,\"legend\":" ++ semantic_legend_json ++ "}," ++
        "\"codeActionProvider\":{\"codeActionKinds\":[\"quickfix\",\"refactor.rewrite\",\"refactor.extract\",\"refactor.inline\"]}," ++
        "\"definitionProvider\":true," ++
        "\"documentHighlightProvider\":true," ++
        "\"selectionRangeProvider\":true," ++
        "\"workspaceSymbolProvider\":true," ++
        "\"referencesProvider\":true," ++
        "\"renameProvider\":{\"prepareProvider\":true}}," ++
        "\"serverInfo\":{\"name\":\"sjon-lsp\",\"version\":\"") catch return;
    buf.appendSlice(wasm_allocator, sjon_version) catch return;
    buf.appendSlice(wasm_allocator, "\"}}") catch return;

    sendResultRaw(id, buf.items);
}

/// Restore the invariant that this server never holds text the client did
/// not send, by holding no text for `uri` at all.
///
/// Every sync failure below leaves the server's copy an edit behind. That
/// is not a lost edit — it is a *permanent* desynchronisation: each later
/// incremental change splices against a base the client no longer has, so
/// the copy drifts further with every keystroke for the rest of the
/// session. Wrong diagnostics are the mild consequence; the sharp one is
/// that extract and inline hand back byte-anchored edits computed against
/// text that isn't in the buffer, and the client applies them.
///
/// Dropping the document makes the features answer "unknown document"
/// instead of answering wrongly, and costs nothing to recover from: the
/// next whole-document change re-opens it (see `handleDidChange`), which
/// is what the playground sends on every keystroke. The native transport
/// has no equivalent because it propagates these errors to lsp-kit.
fn dropDesynced(uri: []const u8) void {
    handler.closeDocument(uri);
}

fn handleDidOpen(params: ?std.json.Value) void {
    const text_doc = getObject(params, "textDocument") orelse return;
    const uri = getString(text_doc, "uri") orelse return;
    const version = getInt(text_doc, "version") orelse 0;
    const text = getString(text_doc, "text") orelse return;
    // `openDocument` is atomic on failure, so there is usually nothing to
    // drop — unless this open was replacing a document that is now gone.
    handler.openDocument(uri, version, text) catch dropDesynced(uri);
}

/// Read one `contentChanges` entry. A whole-document change is
/// `{"text": "..."}`; an incremental one adds a `range`. Malformed
/// entries yield null and are dropped rather than guessed at.
fn parseContentChange(change: std.json.Value) ?text_sync.Change {
    if (change != .object) return null;
    const text_v = change.object.get("text") orelse return null;
    if (text_v != .string) return null;

    const range_v = change.object.get("range") orelse
        return .{ .range = null, .text = text_v.string };
    if (range_v != .object) return null;

    // `parsePosition` is the dispatcher's one JSON `Position` reader; it
    // clamps negative line/character values a malformed client might send
    // rather than trusting them into an unsigned cast.
    const start = parsePosition(range_v.object.get("start")) orelse return null;
    const end = parsePosition(range_v.object.get("end")) orelse return null;
    return .{
        .range = .{
            .start = .{ .line = start.line, .character = start.character },
            .end = .{ .line = end.line, .character = end.character },
        },
        .text = text_v.string,
    };
}

/// Adapts this transport's `offsets` converter to `text_sync`'s mapper
/// contract, closing over the negotiated encoding.
const OffsetMapper = struct {
    encoding: offsets.Encoding,

    pub fn toIndex(self: OffsetMapper, source: []const u8, pos: text_sync.Position) usize {
        return offsets.positionToIndex(
            source,
            .{ .line = pos.line, .character = pos.character },
            self.encoding,
        );
    }
};

fn handleDidChange(params: ?std.json.Value) void {
    const text_doc = getObject(params, "textDocument") orelse return;
    const uri = getString(text_doc, "uri") orelse return;
    const version = getInt(text_doc, "version") orelse 0;

    const p = params orelse return;
    if (p != .object) return;
    const changes_v = p.object.get("contentChanges") orelse return;
    if (changes_v != .array) return;

    // A lone range-less entry *is* the new document. Take it directly:
    // no base text is involved, so it can neither be desynchronised by
    // the current copy nor need one — which is also how a client
    // resynchronises a document `dropDesynced` let go of. The playground
    // sends exactly this on every keystroke.
    if (wholeDocumentText(changes_v.array.items)) |text| {
        handler.openDocument(uri, version, text) catch dropDesynced(uri);
        return;
    }

    const doc = handler.getDocument(uri) orelse return;

    // Collect first, then apply the whole batch as one unit: each change
    // is positioned against the text its predecessors produced, so they
    // cannot be applied independently.
    var changes: std.ArrayList(text_sync.Change) = .empty;
    defer changes.deinit(wasm_allocator);
    for (changes_v.array.items) |change| {
        // A malformed entry drops the *whole* notification rather than
        // just itself. Skipping one member and applying its neighbours
        // would splice later changes at positions that assume the
        // skipped edit happened — corrupting the buffer instead of
        // merely losing an edit.
        const parsed = parseContentChange(change) orelse return dropDesynced(uri);
        changes.append(wasm_allocator, parsed) catch return dropDesynced(uri);
    }
    if (changes.items.len == 0) return;

    const merged = text_sync.applyChanges(
        wasm_allocator,
        doc.source,
        changes.items,
        OffsetMapper{ .encoding = offset_encoding },
    ) catch return dropDesynced(uri);
    defer wasm_allocator.free(merged);

    // One reparse for the batch, not one per change.
    handler.changeDocumentFull(uri, version, merged) catch dropDesynced(uri);
}

/// The text of a batch that is a single whole-document replacement, or null
/// when the batch is incremental (or empty, or malformed).
fn wholeDocumentText(items: []const std.json.Value) ?[]const u8 {
    if (items.len != 1) return null;
    if (items[0] != .object) return null;
    if (items[0].object.get("range") != null) return null;
    const text_v = items[0].object.get("text") orelse return null;
    if (text_v != .string) return null;
    return text_v.string;
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

/// `sjon/effectiveDocument` — respond with `{ text }`, the document's
/// source with every omitted defaulted key spliced in, or `null` when
/// the URI isn't open.
///
/// `{ text }` rather than a bare string so the response can grow a
/// sibling field (a provenance map, say) without breaking the client
/// that reads it — the same shape `sjon/setSchemas` uses for `reports`.
fn handleEffectiveDocument(id: ?std.json.Value, params: ?std.json.Value) void {
    const req_id = id orelse return;
    const text_doc = getObject(params, "textDocument") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const uri = getString(text_doc, "uri") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    var arena_state: std.heap.ArenaAllocator = .init(wasm_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = (handler.getEffectiveDocument(arena, uri) catch {
        sendResultRawWithId(req_id, "null");
        return;
    }) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    blk: {
        buf.appendSlice(wasm_allocator, "{\"text\":") catch break :blk;
        appendJsonString(&buf, text) catch break :blk;
        buf.append(wasm_allocator, '}') catch break :blk;
        sendResultRawWithId(req_id, buf.items);
        return;
    }
    sendResultRawWithId(req_id, "null");
}

/// `sjon/evalDocument` — respond with `{ entries }`, one per expression
/// root, or `null` when the URI isn't open.
///
/// Each entry carries a `range` plus **exactly one** of `value` (the
/// rendered SJON text) and `error` (a `Handler.EvalEntry.Failure` tag).
/// Alternatives rather than a value-plus-status pair, so a client
/// switches on which key is present and cannot render a stale value
/// beside a failure.
fn handleEvalDocument(id: ?std.json.Value, params: ?std.json.Value) void {
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

    const entries = (handler.evalDocument(arena, uri) catch {
        sendResultRawWithId(req_id, "null");
        return;
    }) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    blk: {
        appendEvalEntries(&buf, doc.source, entries) catch break :blk;
        sendResultRawWithId(req_id, buf.items);
        return;
    }
    sendResultRawWithId(req_id, "null");
}

fn appendEvalEntries(
    buf: *std.ArrayList(u8),
    source: []const u8,
    entries: []const Handler.EvalEntry,
) Allocator.Error!void {
    const a = wasm_allocator;
    try buf.appendSlice(a, "{\"entries\":[");
    for (entries, 0..) |e, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.appendSlice(a, "{\"range\":");
        try appendRange(
            buf,
            offsets.indexToPosition(source, e.span_start, offset_encoding),
            offsets.indexToPosition(source, e.span_end, offset_encoding),
        );
        switch (e.outcome) {
            .value => |v| {
                try buf.appendSlice(a, ",\"value\":");
                try appendJsonString(buf, v);
            },
            .failure => |f| {
                try buf.appendSlice(a, ",\"error\":");
                try appendJsonString(buf, @tagName(f));
            },
        }
        try buf.append(a, '}');
    }
    try buf.appendSlice(a, "]}");
}

/// `sjon/setSchemas` — replace the user-authored schema set with the
/// `(plugin …)` manifests in `params.schemas` (an array of
/// `{uri, text}`). Responds with `{ reports: [{ uri, name, items: [] }] }`,
/// one report per source (index-aligned), where `name` is the parsed
/// plugin `:name` (for tab labels) and `items` are the schema's own
/// diagnostics, offset against its own `text`. A malformed payload or
/// OOM degrades to an empty report list rather than a hard error.
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
    const position = paramsPosition(params) orelse {
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
    const position = paramsPosition(params) orelse {
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
    const position = paramsPosition(params) orelse {
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
        // A fold collapses *between* startLine and endLine — single-line
        // ranges have nothing to hide, so skip them rather than emit noise.
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

fn handleSemanticTokensFull(id: ?std.json.Value, params: ?std.json.Value) void {
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

    const toks_or_null = handler.getSemanticTokens(arena, uri) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const toks = toks_or_null orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    appendSemanticTokens(&buf, arena, doc.source, toks) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    sendResultRawWithId(req_id, buf.items);
}

fn appendSemanticTokens(
    buf: *std.ArrayList(u8),
    arena: Allocator,
    source: []const u8,
    toks: []const Handler.SemanticToken,
) Allocator.Error!void {
    const a = wasm_allocator;

    // Byte spans → the negotiated encoding, which is the only step that
    // differs between transports; `SemanticToken.encode` then owns the
    // delta arithmetic for both.
    const positions = try arena.alloc(Handler.SemanticToken.Position, toks.len);
    for (toks, positions) |t, *slot| {
        const start = offsets.indexToPosition(source, t.span_start, offset_encoding);
        const end = offsets.indexToPosition(source, t.span_end, offset_encoding);
        // No token spans a line: every one covers a single head, key,
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

    const data = try Handler.SemanticToken.encode(arena, positions);
    try buf.appendSlice(a, "{\"data\":[");
    for (data, 0..) |n, i| {
        if (i > 0) try buf.append(a, ',');
        try appendUint(buf, n);
    }
    try buf.appendSlice(a, "]}");
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
        // Omitted when null rather than sent as 0: `InlayHintKind` has no
        // zero member, and "no kind" is a distinct client behaviour.
        if (h.kind) |kind| {
            try buf.appendSlice(a, ",\"kind\":");
            try appendUint(buf, @intFromEnum(kind));
        }
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

fn handleRangeFormatting(id: ?std.json.Value, params: ?std.json.Value) void {
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

    const edits_or_null = handler.getRangeFormatEdits(arena, uri, start_offset, end_offset) catch {
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

/// `textDocument/definition` → a single `Location`, or `null` when the
/// cursor isn't on a resolvable cross-ref site. The spec also allows
/// `Location[]` / `LocationLink[]`; a cross-ref name has exactly one
/// definition in its scope, so the scalar form is the honest one.
fn handleDefinition(id: ?std.json.Value, params: ?std.json.Value) void {
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

    const loc = handler.getDefinition(uri, byte_offset) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    // One location, but `appendLocations` owns the byte→position
    // translation (and the "its document closed" guard); slice off its
    // array brackets rather than duplicating that logic here.
    appendLocations(&buf, &.{loc}) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const inner = buf.items[1 .. buf.items.len - 1];
    if (inner.len == 0) {
        sendResultRawWithId(req_id, "null");
        return;
    }
    sendResultRawWithId(req_id, inner);
}

/// `textDocument/documentHighlight` → `DocumentHighlight[]`, or `null`
/// off any cross-ref site. Every span is in the requesting document, so
/// this translates against one source (unlike `appendLocations`).
fn handleDocumentHighlight(id: ?std.json.Value, params: ?std.json.Value) void {
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

    var arena_state: std.heap.ArenaAllocator = .init(wasm_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const highlights = (handler.getDocumentHighlights(arena, uri, byte_offset) catch {
        sendResultRawWithId(req_id, "null");
        return;
    }) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    appendDocumentHighlights(&buf, doc.source, highlights) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    sendResultRawWithId(req_id, buf.items);
}

/// `textDocument/selectionRange` → `SelectionRange[]`, one entry per
/// requested position (LSP requires that arity, so this never returns a
/// short array — an offset with nothing to expand gets a degenerate
/// empty range instead).
fn handleSelectionRange(id: ?std.json.Value, params: ?std.json.Value) void {
    const req_id = id orelse return;
    const text_doc = getObject(params, "textDocument") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const uri = getString(text_doc, "uri") orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    const positions_value = (if (params) |p| p.object.get("positions") else null) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };
    if (positions_value != .array) {
        sendResultRawWithId(req_id, "null");
        return;
    }

    const doc = handler.getDocument(uri) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    var arena_state: std.heap.ArenaAllocator = .init(wasm_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const positions = positions_value.array.items;
    const offsets_buf = arena.alloc(u32, positions.len) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    for (positions, offsets_buf) |p, *slot| {
        const pos = parsePosition(p) orelse {
            sendResultRawWithId(req_id, "null");
            return;
        };
        slot.* = @intCast(offsets.positionToIndex(doc.source, pos, offset_encoding));
    }

    const chains = (handler.getSelectionRanges(arena, uri, offsets_buf) catch {
        sendResultRawWithId(req_id, "null");
        return;
    }) orelse {
        sendResultRawWithId(req_id, "null");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    appendSelectionRanges(&buf, doc.source, chains, offsets_buf) catch {
        sendResultRawWithId(req_id, "null");
        return;
    };
    sendResultRawWithId(req_id, buf.items);
}

/// Write each chain as LSP's nested `{range, parent}` shape: the
/// top-level object is the innermost range and `parent` widens outward.
/// The Handler hands back innermost-first, so the chain is emitted in
/// order — each link but the last opens a `"parent":` slot the next one
/// fills — and every brace closes at the end.
///
/// An empty chain (an offset inside no root) becomes a zero-width range
/// at that offset with no parent — "selected nothing, nothing to widen
/// to" — which keeps the array's 1:1 arity with `positions`.
fn appendSelectionRanges(
    buf: *std.ArrayList(u8),
    source: []const u8,
    chains: []const []const Handler.SelectionRange,
    request_offsets: []const u32,
) Allocator.Error!void {
    const a = wasm_allocator;
    std.debug.assert(chains.len == request_offsets.len);
    try buf.append(a, '[');
    for (chains, request_offsets, 0..) |chain, offset, i| {
        if (i > 0) try buf.append(a, ',');
        if (chain.len == 0) {
            const at = offsets.indexToPosition(source, offset, offset_encoding);
            try buf.appendSlice(a, "{\"range\":");
            try appendRange(buf, at, at);
            try buf.append(a, '}');
            continue;
        }
        for (chain, 0..) |r, link| {
            const start = offsets.indexToPosition(source, r.span_start, offset_encoding);
            const end = offsets.indexToPosition(source, r.span_end, offset_encoding);
            try buf.appendSlice(a, "{\"range\":");
            try appendRange(buf, start, end);
            if (link + 1 < chain.len) try buf.appendSlice(a, ",\"parent\":");
        }
        try buf.appendNTimes(a, '}', chain.len);
    }
    try buf.append(a, ']');
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
    // `context.includeDeclaration` defaults to false per LSP, but most
    // editors send it as `true`. Tolerate missing context (return refs
    // without the declaration).
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
        .err => |e| {
            // The reason reaches the user as a `window/showMessage`
            // warning, then the result is null so the client treats the
            // rename as not performed. Same shape as the native
            // transport, whose typed dispatcher cannot attach a message
            // to a ResponseError; keeping one behaviour here means an
            // editor sees the same thing whichever artifact it drives.
            sendShowMessage(.warning, e.message);
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

/// A `WorkspaceEdit` over one or more files, in the best shape this client
/// accepts. Shared by rename and the code actions, so both carry versions
/// or neither does.
///
/// The `changes` map cannot carry a version, so edits computed against the
/// buffers as they stood at request time apply unconditionally to whatever
/// they hold when the user clicks. Byte-anchored refactors are the sharp
/// case: inline can delete a region that is no longer the definition.
/// `documentChanges` stamps each file's version, and the client refuses a
/// stale edit rather than applying it to wrong text.
///
/// Gated on the capability rather than always sent, because a client that
/// never announced `documentChanges` support sees an edit with no `changes`
/// and applies nothing at all. Mirrors `main.zig`'s `workspaceEdit`.
fn appendWorkspaceEdit(
    buf: *std.ArrayList(u8),
    we: Handler.WorkspaceEdit,
) Allocator.Error!void {
    const a = wasm_allocator;
    const versioned = client_document_changes;
    try buf.appendSlice(a, if (versioned) "{\"documentChanges\":[" else "{\"changes\":{");
    var emitted: usize = 0;
    for (we.changes) |fe| {
        // A file this server no longer holds is skipped rather than sent
        // with an empty edit list: without its source there are no ranges
        // to compute, and no version to assert either.
        const ref_doc = handler.getDocument(fe.uri) orelse continue;
        if (emitted > 0) try buf.append(a, ',');
        if (versioned) {
            try buf.appendSlice(a, "{\"textDocument\":{\"uri\":");
            try appendJsonString(buf, fe.uri);
            try buf.appendSlice(a, ",\"version\":");
            // LSP's `integer` is signed 32-bit. A version outside it
            // becomes `null` — "unknown", which is legal and better than a
            // wrapped number the client would refuse for the wrong reason.
            if (std.math.cast(i32, ref_doc.version)) |v| {
                try buf.print(a, "{d}", .{v});
            } else {
                try buf.appendSlice(a, "null");
            }
            try buf.appendSlice(a, "},\"edits\":");
            try appendTextEditList(buf, ref_doc.source, fe.edits);
            try buf.append(a, '}');
        } else {
            try appendJsonString(buf, fe.uri);
            try buf.append(a, ':');
            try appendTextEditList(buf, ref_doc.source, fe.edits);
        }
        emitted += 1;
    }
    try buf.appendSlice(a, if (versioned) "]}" else "}}");
}

/// `workspace/symbol` → `SymbolInformation[]`. Always an array, never
/// null: an empty workspace and an unmatched query both mean "no
/// symbols to show", and a picker renders that fine.
fn handleWorkspaceSymbol(id: ?std.json.Value, params: ?std.json.Value) void {
    const req_id = id orelse return;
    // A missing query is the "list everything" request, same as "".
    const query = blk: {
        const p = params orelse break :blk "";
        if (p != .object) break :blk "";
        break :blk getString(p.object, "query") orelse "";
    };

    var arena_state: std.heap.ArenaAllocator = .init(wasm_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const syms = handler.getWorkspaceSymbols(arena, query) catch {
        sendResultRawWithId(req_id, "[]");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    appendWorkspaceSymbols(&buf, syms) catch {
        sendResultRawWithId(req_id, "[]");
        return;
    };
    sendResultRawWithId(req_id, buf.items);
}

/// `SymbolInfo[]` → LSP `SymbolInformation[]`. Kind is `Constructor`
/// (9) to match `documentSymbol`: every named thing SJON exposes is a
/// form instance, and one icon across both pickers reads as one
/// language rather than two.
fn appendWorkspaceSymbols(
    buf: *std.ArrayList(u8),
    syms: []const Handler.SymbolInfo,
) Allocator.Error!void {
    const a = wasm_allocator;
    try buf.append(a, '[');
    var emitted: usize = 0;
    for (syms) |sym| {
        // Definitions can outlive their document in a stale index; skip
        // rather than emit a location the editor cannot open.
        const doc = handler.getDocument(sym.location.uri) orelse continue;
        if (emitted > 0) try buf.append(a, ',');
        const start = offsets.indexToPosition(doc.source, sym.location.span_start, offset_encoding);
        const end = offsets.indexToPosition(doc.source, sym.location.span_end, offset_encoding);
        try buf.appendSlice(a, "{\"name\":");
        try appendJsonString(buf, sym.name);
        try buf.appendSlice(a, ",\"kind\":9,\"containerName\":");
        try appendJsonString(buf, sym.container_name);
        try buf.appendSlice(a, ",\"location\":{\"uri\":");
        try appendJsonString(buf, sym.location.uri);
        try buf.appendSlice(a, ",\"range\":");
        try appendRange(buf, start, end);
        try buf.appendSlice(a, "}}");
        emitted += 1;
    }
    try buf.append(a, ']');
}

fn appendLocations(
    buf: *std.ArrayList(u8),
    locations: []const Handler.Location,
) Allocator.Error!void {
    const a = wasm_allocator;
    try buf.append(a, '[');
    var emitted: usize = 0;
    for (locations) |loc| {
        // Each location may live in a different document — look up its
        // source for the byte→position translation. Skip if its document
        // closed since the index was built.
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

/// `Highlight[]` → LSP `DocumentHighlight[]`. `Highlight.Kind` already
/// carries the protocol's numeric values, so the kind travels as-is.
fn appendDocumentHighlights(
    buf: *std.ArrayList(u8),
    source: []const u8,
    highlights: []const Handler.Highlight,
) Allocator.Error!void {
    const a = wasm_allocator;
    try buf.append(a, '[');
    for (highlights, 0..) |hl, i| {
        if (i > 0) try buf.append(a, ',');
        const start = offsets.indexToPosition(source, hl.span_start, offset_encoding);
        const end = offsets.indexToPosition(source, hl.span_end, offset_encoding);
        try buf.appendSlice(a, "{\"range\":");
        try appendRange(buf, start, end);
        try buf.appendSlice(a, ",\"kind\":");
        try buf.print(a, "{d}", .{@intFromEnum(hl.kind)});
        try buf.append(a, '}');
    }
    try buf.append(a, ']');
}

fn parsePosition(v: ?std.json.Value) ?offsets.Position {
    const value = v orelse return null;
    if (value != .object) return null;
    const line = value.object.get("line") orelse return null;
    const ch = value.object.get("character") orelse return null;
    if (line != .integer or ch != .integer) return null;
    // Client-supplied i64s: anything outside u32 is not a position. The
    // old `@intCast(@max(0, …))` only removed the negative half, so a
    // line of 4294967296 panicked here on native and truncated to line 0
    // in the ReleaseSmall artifact.
    return .{
        .line = std.math.cast(u32, line.integer) orelse return null,
        .character = std.math.cast(u32, ch.integer) orelse return null,
    };
}

/// Extract `params.position` via `parsePosition`, or null when params is
/// absent / not an object / carries no valid position. The unwrap the
/// position-taking handlers share (hover, completion, signatureHelp).
fn paramsPosition(params: ?std.json.Value) ?offsets.Position {
    const p = params orelse return null;
    if (p != .object) return null;
    return parsePosition(p.object.get("position"));
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
        try buf.appendSlice(a, ",\"kind\":");
        try appendJsonString(buf, act.kind.lspString());
        // Omitted rather than sent false: `isPreferred` absent and
        // `isPreferred: false` mean the same to a client, and the flag
        // only ever meant something for quickfixes.
        if (act.kind.isPreferred()) try buf.appendSlice(a, ",\"isPreferred\":true");
        try buf.appendSlice(a, ",\"diagnostics\":[");
        // Same serializer as `textDocument/diagnostic`, so the objects a
        // client matches against are byte-identical to the ones it was
        // published — a hand-rolled subset here would fail that match.
        try appendDiagnosticItems(buf, source, act.diagnostics);
        try buf.appendSlice(a, "],\"edit\":");
        // Through the same serializer rename uses, so the two can't drift
        // into carrying versions on one path and not the other.
        try appendWorkspaceEdit(buf, .{ .changes = &.{.{ .uri = uri, .edits = act.edits }} });
        try buf.append(a, '}');
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

// -- Response builders ------------------------------------------------------

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

/// Emit the comma-separated LSP `Diagnostic` objects for `diags` — the
/// inside of an `"items":[…]` array. `source` maps byte offsets to
/// positions, so the caller passes the document (or schema) text each
/// diagnostic's spans index into. Shared by the diagnostic-report and
/// schema-report builders.
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
        // LSP `DiagnosticSeverity`: Error 1, Warning 2, Information 3,
        // Hint 4.
        try appendUint(buf, switch (d.severity) {
            .err => @as(u32, 1),
            .warning => @as(u32, 2),
            .hint => @as(u32, 4),
        });
        try buf.appendSlice(a, ",\"source\":\"sjon\",\"code\":");
        try appendJsonString(buf, d.code);
        // Unconditional: every code has a documentation page.
        try buf.appendSlice(a, ",\"codeDescription\":{\"href\":");
        try appendJsonString(buf, d.code_href);
        try buf.appendSlice(a, "},\"message\":");
        try appendJsonString(buf, d.message);
        try appendRelatedInformation(buf, d);
        // `tags` is optional in LSP; omit it entirely when empty rather
        // than emitting `[]`, which some clients treat as "tagged".
        if (d.tags.len > 0) {
            try buf.appendSlice(a, ",\"tags\":[");
            for (d.tags, 0..) |t, ti| {
                if (ti > 0) try buf.append(a, ',');
                try appendUint(buf, @intFromEnum(t));
            }
            try buf.append(a, ']');
        }
        try buf.append(a, '}');
    }
}

/// Emit `"relatedInformation":[…]` for `d`, or nothing when it has no
/// relations (LSP treats the absent field as "none"; an explicit `[]`
/// reads as an empty-but-present list to some clients).
///
/// Each related location resolves its byte offsets against **its own**
/// document's source — `Related.uri` need not be the diagnostic's
/// document. A relation pointing at a document the handler doesn't have
/// open is dropped rather than mapped against the wrong text, which
/// would silently produce a plausible but wrong range.
fn appendRelatedInformation(
    buf: *std.ArrayList(u8),
    d: Handler.Diagnostic,
) Allocator.Error!void {
    if (d.related.len == 0) return;
    const a = wasm_allocator;

    var written: usize = 0;
    for (d.related) |r| {
        const doc = handler.getDocument(r.uri) orelse continue;
        const src = doc.source;
        try buf.appendSlice(a, if (written == 0) ",\"relatedInformation\":[" else ",");
        written += 1;

        const start = offsets.indexToPosition(src, r.span_start, offset_encoding);
        const end = offsets.indexToPosition(src, r.span_end, offset_encoding);
        try buf.appendSlice(a, "{\"location\":{\"uri\":");
        try appendJsonString(buf, r.uri);
        try buf.appendSlice(a, ",\"range\":{\"start\":{\"line\":");
        try appendUint(buf, start.line);
        try buf.appendSlice(a, ",\"character\":");
        try appendUint(buf, start.character);
        try buf.appendSlice(a, "},\"end\":{\"line\":");
        try appendUint(buf, end.line);
        try buf.appendSlice(a, ",\"character\":");
        try appendUint(buf, end.character);
        try buf.appendSlice(a, "}}},\"message\":");
        try appendJsonString(buf, r.message);
        try buf.append(a, '}');
    }
    if (written > 0) try buf.append(a, ']');
}

/// Serialize the `sjon/setSchemas` result: `{ reports: [{ uri, name,
/// items: [...] }] }`. Each report's diagnostic offsets are resolved
/// against that schema's own source text — `reports` is index-aligned
/// with `sources` by construction in `Handler.setUserSchemas`.
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

/// Thin wrapper over the shared escaper (`wasm_common.appendJsonString`) —
/// binds `wasm_allocator` so the ~30 call sites stay `appendJsonString(buf, s)`.
fn appendJsonString(buf: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try wasm_common.appendJsonString(buf, wasm_allocator, s);
}

/// Thin wrapper over the shared `wasm_common.appendUint` — binds
/// `wasm_allocator` so the call sites stay `appendUint(buf, n)`, mirroring the
/// `appendJsonString` wrapper above.
fn appendUint(buf: *std.ArrayList(u8), n: u32) Allocator.Error!void {
    try wasm_common.appendUint(buf, wasm_allocator, n);
}

fn appendIdJson(buf: *std.ArrayList(u8), id: std.json.Value) Allocator.Error!void {
    const a = wasm_allocator;
    switch (id) {
        .string => |s| try appendJsonString(buf, s),
        .integer => |n| {
            // SAFETY: std.json's `.integer` is an i64: at most 20 characters.
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

/// `window/showMessage` severities, by their wire values.
const MessageKind = enum(u8) { err = 1, warning = 2, info = 3, log = 4 };

/// Enqueue a `window/showMessage` notification — the one channel this
/// transport has for putting a sentence in front of the user outside a
/// diagnostic. Used where a request is refused for a reason the user can
/// act on and the result alone would say nothing.
fn sendShowMessage(kind: MessageKind, message: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(wasm_allocator);
    buf.appendSlice(wasm_allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"window/showMessage\",\"params\":{\"type\":") catch return;
    appendUint(&buf, @intFromEnum(kind)) catch return;
    buf.appendSlice(wasm_allocator, ",\"message\":") catch return;
    appendJsonString(&buf, message) catch return;
    buf.appendSlice(wasm_allocator, "}}") catch return;
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
    // The method name comes straight off untrusted client input, so it
    // must be escaped as JSON-string body (control chars included) — a
    // bare `\n` would otherwise break the response out of its string.
    wasm_common.appendJsonStringBody(&buf, wasm_allocator, method) catch return;
    buf.appendSlice(wasm_allocator, "\"}}") catch return;
    enqueue(buf.toOwnedSlice(wasm_allocator) catch return);
}

// -- JSON helpers -----------------------------------------------------------

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

// =========================================================================
// Tests — native only (the allocator gate makes the dispatcher driveable
// off-wasm; see `wasm_allocator`).
// =========================================================================

/// Dispatcher fixture for tests that drive real requests: brings up the
/// global `handler` the way `sjon_lsp_send` does on the wasm side, and
/// tears down both it and the outbox (the native test allocator
/// leak-checks both). The `sendMethodNotFound` tests below need none of
/// this — they never reach the handler.
///
/// `pub` for one caller outside this file: the never-panic harness in
/// `src/fuzz.zig`, which cannot reach `handleMessage` or the module-global
/// `outbox` directly. Nothing in the shipped artifact references it, so it
/// is never analyzed for wasm32 (and `audit-lsp-wasm-imports` would fail
/// loudly if that stopped being true).
pub const DispatchFixture = struct {
    pub fn init() DispatchFixture {
        handler = Handler.init(wasm_allocator);
        handler_initialized = true;
        outbox = .empty;
        // Both negotiated globals reset with the fixture: a test that
        // announced a capability must not leak it into the next one.
        offset_encoding = .@"utf-16";
        client_document_changes = false;
        return .{};
    }

    pub fn deinit(_: DispatchFixture) void {
        for (outbox.items) |m| wasm_allocator.free(m);
        outbox.deinit(wasm_allocator);
        handler.deinit();
        handler_initialized = false;
    }

    /// Feed one message in and say nothing about what it enqueued — the
    /// lenient sibling of `request` below, for callers whose input is
    /// arbitrary bytes and where "produced no response at all" is a legal
    /// outcome (a notification, or a message that isn't JSON).
    pub fn send(_: DispatchFixture, json_text: []const u8) void {
        handleMessage(json_text);
    }

    /// Every message enqueued so far, oldest first. Borrowed — the fixture
    /// still owns them and frees them in `deinit`.
    pub fn sent(_: DispatchFixture) []const []u8 {
        return outbox.items;
    }

    /// Feed one message in and parse the response it enqueued. Caller
    /// owns the returned `Parsed` (`defer .deinit()`); the raw message
    /// stays in the outbox for the fixture to free.
    fn request(_: DispatchFixture, json_text: []const u8) !std.json.Parsed(std.json.Value) {
        const before = outbox.items.len;
        handleMessage(json_text);
        try std.testing.expectEqual(before + 1, outbox.items.len);
        return std.json.parseFromSlice(std.json.Value, wasm_allocator, outbox.items[before], .{});
    }

    /// Install a cross-ref schema + a document that defines `p0` and
    /// references it — the shape every navigation test here needs.
    fn openCrossRefDoc(self: DispatchFixture) !void {
        var schemas = try self.request(
            \\{"jsonrpc":"2.0","id":1,"method":"sjon/setSchemas","params":{"schemas":[{"uri":"inmemory://schema/0","text":"(plugin :name audio :version \"1.0.0\" (value-kind :name phrase-name :underlying symbol :cross-ref (cross-ref :target phrase)) (form :name phrase (key :name name :type symbol :optional false)) (form :name jump (key :name target :type phrase-name :optional false)))"}]}}
        );
        defer schemas.deinit();

        // `(phrase :name p0)\n(jump :target p0)` — definition name `p0`
        // at line 0 chars 14..16, reference at line 1 chars 14..16.
        handleMessage(
            \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.sjon","version":1,"languageId":"sjon","text":"(phrase :name p0)\n(jump :target p0)"}}}
        );
    }
};

test "textDocument/definition returns the definition Location" {
    var fx = DispatchFixture.init();
    defer fx.deinit();
    try fx.openCrossRefDoc();

    // Cursor mid-reference: line 1, character 15.
    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///a.sjon"},"position":{"line":1,"character":15}}}
    );
    defer res.deinit();

    const loc = res.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("file:///a.sjon", loc.get("uri").?.string);
    const range = loc.get("range").?.object;
    const start = range.get("start").?.object;
    const end = range.get("end").?.object;
    try std.testing.expectEqual(@as(i64, 0), start.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 14), start.get("character").?.integer);
    try std.testing.expectEqual(@as(i64, 0), end.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 16), end.get("character").?.integer);
}

test "a position outside u32 is no position: hover answers null and didChange keeps the document" {
    var fx = DispatchFixture.init();
    defer fx.deinit();
    try fx.openCrossRefDoc();

    // line = 2^32: `parsePosition` used to @intCast this and panic.
    var hover = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///a.sjon"},"position":{"line":4294967296,"character":0}}}
    );
    defer hover.deinit();
    try std.testing.expect(hover.value.object.get("result").? == .null);

    // Same cast in the didChange range reader. A malformed change entry
    // is `handleDidChange`'s "desynced" case: the document is dropped
    // rather than edited at a wrapped offset, so definition answers null
    // until the client resyncs with a whole-document change.
    fx.send(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.sjon","version":2},"contentChanges":[{"range":{"start":{"line":0,"character":9999999999},"end":{"line":0,"character":9999999999}},"text":"x"}]}}
    );
    var dropped = try fx.request(
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///a.sjon"},"position":{"line":1,"character":15}}}
    );
    defer dropped.deinit();
    try std.testing.expect(dropped.value.object.get("result").? == .null);

    fx.send(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.sjon","version":3},"contentChanges":[{"text":"(phrase :name p0)\n(jump :target p0)"}]}}
    );
    var def = try fx.request(
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///a.sjon"},"position":{"line":1,"character":15}}}
    );
    defer def.deinit();
    try std.testing.expectEqualStrings("file:///a.sjon", def.value.object.get("result").?.object.get("uri").?.string);
}

test "textDocument/definition returns null off any cross-ref site" {
    var fx = DispatchFixture.init();
    defer fx.deinit();
    try fx.openCrossRefDoc();

    // Line 0, character 3 — inside the form head `phrase`.
    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///a.sjon"},"position":{"line":0,"character":3}}}
    );
    defer res.deinit();

    try std.testing.expect(res.value.object.get("result").? == .null);
}

test "textDocument/documentHighlight returns ranges with kinds" {
    var fx = DispatchFixture.init();
    defer fx.deinit();
    try fx.openCrossRefDoc();

    // Cursor mid-reference: line 1, character 15.
    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/documentHighlight","params":{"textDocument":{"uri":"file:///a.sjon"},"position":{"line":1,"character":15}}}
    );
    defer res.deinit();

    const items = res.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);

    // Definition first (line 0, Write=3), then the reference (line 1, Read=2).
    const def = items[0].object;
    try std.testing.expectEqual(@as(i64, 3), def.get("kind").?.integer);
    try std.testing.expectEqual(
        @as(i64, 0),
        def.get("range").?.object.get("start").?.object.get("line").?.integer,
    );
    const ref = items[1].object;
    try std.testing.expectEqual(@as(i64, 2), ref.get("kind").?.integer);
    try std.testing.expectEqual(
        @as(i64, 1),
        ref.get("range").?.object.get("start").?.object.get("line").?.integer,
    );
}

test "textDocument/documentHighlight returns null off any cross-ref site" {
    var fx = DispatchFixture.init();
    defer fx.deinit();
    try fx.openCrossRefDoc();

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/documentHighlight","params":{"textDocument":{"uri":"file:///a.sjon"},"position":{"line":0,"character":3}}}
    );
    defer res.deinit();

    try std.testing.expect(res.value.object.get("result").? == .null);
}

test "textDocument/selectionRange nests each widening step under parent" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    // `(a [1 2])` — element 4..5, vector 3..8, form 0..9. Single line, so
    // byte offsets and characters coincide.
    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.sjon","version":1,"languageId":"sjon","text":"(a [1 2])"}}}
    );

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/selectionRange","params":{"textDocument":{"uri":"file:///a.sjon"},"positions":[{"line":0,"character":4}]}}
    );
    defer res.deinit();

    const items = res.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), items.len);

    const inner = items[0].object;
    try expectCharRange(inner.get("range").?, 4, 5);
    const mid = inner.get("parent").?.object;
    try expectCharRange(mid.get("range").?, 3, 8);
    const outer = mid.get("parent").?.object;
    try expectCharRange(outer.get("range").?, 0, 9);
    // Root of the chain — no further expansion.
    try std.testing.expect(outer.get("parent") == null);
}

test "textDocument/selectionRange emits one entry per requested position" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.sjon","version":1,"languageId":"sjon","text":"(a 1)\n\n(b 2)"}}}
    );

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/selectionRange","params":{"textDocument":{"uri":"file:///a.sjon"},"positions":[{"line":0,"character":3},{"line":2,"character":3}]}}
    );
    defer res.deinit();

    const items = res.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try expectCharRange(items[0].object.get("range").?, 3, 4);
    try expectCharRange(items[1].object.get("range").?, 3, 4);
    // Different lines, same characters — check the second really is root 2.
    try std.testing.expectEqual(
        @as(i64, 2),
        items[1].object.get("range").?.object.get("start").?.object.get("line").?.integer,
    );
}

test "textDocument/selectionRange yields a degenerate range between roots" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.sjon","version":1,"languageId":"sjon","text":"(a 1)\n\n(b 2)"}}}
    );

    // Line 1 is the blank line between the two roots: nothing encloses
    // it, so the entry is an empty range at the position with no parent.
    // The array still has one entry — LSP requires positional arity.
    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/selectionRange","params":{"textDocument":{"uri":"file:///a.sjon"},"positions":[{"line":1,"character":0}]}}
    );
    defer res.deinit();

    const items = res.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    const range = items[0].object.get("range").?.object;
    try std.testing.expectEqual(@as(i64, 1), range.get("start").?.object.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 0), range.get("start").?.object.get("character").?.integer);
    try std.testing.expectEqual(@as(i64, 1), range.get("end").?.object.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 0), range.get("end").?.object.get("character").?.integer);
    try std.testing.expect(items[0].object.get("parent") == null);
}

/// Assert a `Range` value spans `start_char`..`end_char` on one line.
fn expectCharRange(range: std.json.Value, start_char: i64, end_char: i64) !void {
    const obj = range.object;
    try std.testing.expectEqual(start_char, obj.get("start").?.object.get("character").?.integer);
    try std.testing.expectEqual(end_char, obj.get("end").?.object.get("character").?.integer);
}

test "workspace/symbol lists cross-ref definitions matching the query" {
    var fx = DispatchFixture.init();
    defer fx.deinit();
    try fx.openCrossRefDoc();

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"workspace/symbol","params":{"query":"P0"}}
    );
    defer res.deinit();

    const items = res.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    const sym = items[0].object;
    try std.testing.expectEqualStrings("p0", sym.get("name").?.string);
    try std.testing.expectEqualStrings("audio/phrase", sym.get("containerName").?.string);
    // `Constructor` (9) — the kind documentSymbol already uses for forms.
    try std.testing.expectEqual(@as(i64, 9), sym.get("kind").?.integer);

    const loc = sym.get("location").?.object;
    try std.testing.expectEqualStrings("file:///a.sjon", loc.get("uri").?.string);
    const start = loc.get("range").?.object.get("start").?.object;
    try std.testing.expectEqual(@as(i64, 0), start.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 14), start.get("character").?.integer);
}

test "workspace/symbol returns an empty array when nothing matches" {
    var fx = DispatchFixture.init();
    defer fx.deinit();
    try fx.openCrossRefDoc();

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"workspace/symbol","params":{"query":"zzz"}}
    );
    defer res.deinit();

    try std.testing.expectEqual(@as(usize, 0), res.value.object.get("result").?.array.items.len);
}

test "initialize advertises definitionProvider" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );
    defer res.deinit();

    const caps = res.value.object.get("result").?.object.get("capabilities").?.object;
    try std.testing.expect(caps.get("definitionProvider").?.bool);
    try std.testing.expect(caps.get("documentHighlightProvider").?.bool);
    try std.testing.expect(caps.get("selectionRangeProvider").?.bool);
    try std.testing.expect(caps.get("workspaceSymbolProvider").?.bool);
}

test "sendMethodNotFound keeps the response valid JSON for a hostile method name" {
    // Reset the dispatcher globals (single-threaded test runner) and free
    // whatever the handler enqueues.
    outbox = .empty;
    defer {
        for (outbox.items) |m| wasm_allocator.free(m);
        outbox.deinit(wasm_allocator);
    }

    // An unknown method whose name carries a control char (\n) and a
    // quote — the classic JSON-injection shape. The request is valid
    // JSON; the framed response must be too.
    const request =
        \\{"jsonrpc":"2.0","id":7,"method":"evil\nme\"thod"}
    ;
    handleMessage(request);

    try std.testing.expectEqual(@as(usize, 1), outbox.items.len);
    const response = outbox.items[0];

    // The whole point: parse the framed response back. A raw newline
    // spliced into the error message makes this fail with SyntaxError.
    const parsed = try std.json.parseFromSlice(std.json.Value, wasm_allocator, response, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const err_obj = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32601), err_obj.get("code").?.integer);
    // The method name round-trips intact inside the message text.
    const message = err_obj.get("message").?.string;
    try std.testing.expect(std.mem.indexOf(u8, message, "evil\nme\"thod") != null);
}

test "sendMethodNotFound: a plain unknown method still yields a well-formed error" {
    outbox = .empty;
    defer {
        for (outbox.items) |m| wasm_allocator.free(m);
        outbox.deinit(wasm_allocator);
    }

    handleMessage(
        \\{"jsonrpc":"2.0","id":"abc","method":"textDocument/nonsense"}
    );

    try std.testing.expectEqual(@as(usize, 1), outbox.items.len);
    const parsed = try std.json.parseFromSlice(std.json.Value, wasm_allocator, outbox.items[0], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("abc", parsed.value.object.get("id").?.string);
    const err_obj = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings(
        "method not found: textDocument/nonsense",
        err_obj.get("message").?.string,
    );
}

test "initialize advertises interFileDependencies true" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );
    defer res.deinit();

    const caps = res.value.object.get("result").?.object.get("capabilities").?.object;
    const diag = caps.get("diagnosticProvider").?.object;
    // A cross-ref definition in one document decides whether a reference
    // in another resolves, and every edit reruns `validateForest` over the
    // whole open set — so an edit here really does change diagnostics there.
    try std.testing.expect(diag.get("interFileDependencies").?.bool);
    // Still no `workspace/diagnostic` handler; the client pulls per-document.
    try std.testing.expect(!diag.get("workspaceDiagnostics").?.bool);
}

test "diagnostic JSON includes tags: [2] for deprecated_member" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    var schemas = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"sjon/setSchemas","params":{"schemas":[{"uri":"inmemory://schema/0","text":"(plugin :name blog :version \"1.0.0\" (value-kind :name status :underlying symbol :members (member-set (member :name draft) (member :name archived :deprecated true))) (form :name post (key :name status :type status :optional false)))"}]}}
    );
    defer schemas.deinit();

    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.sjon","version":1,"languageId":"sjon","text":"(post :status archived)"}}}
    );

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///a.sjon"}}}
    );
    defer res.deinit();

    const items = res.value.object.get("result").?.object.get("items").?.array;
    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    const d = items.items[0].object;
    try std.testing.expectEqualStrings("deprecated_member", d.get("code").?.string);
    const tags = d.get("tags").?.array;
    try std.testing.expectEqual(@as(usize, 1), tags.items.len);
    // LSP `DiagnosticTag.Deprecated` is 2 — deliberately *not* the 1 that
    // `CompletionItemTag.Deprecated` uses.
    try std.testing.expectEqual(@as(i64, 2), tags.items[0].integer);
}

test "diagnostic JSON carries relatedInformation with location + message" {
    var fx = DispatchFixture.init();
    defer fx.deinit();
    try fx.openCrossRefDoc();

    // `p1` is undefined; `p0` (line 0, chars 14..16) is the near candidate.
    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///b.sjon","version":1,"languageId":"sjon","text":"(phrase :name p0)\n(jump :target p1)"}}}
    );

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///b.sjon"}}}
    );
    defer res.deinit();

    const items = res.value.object.get("result").?.object.get("items").?.array;
    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    const d = items.items[0].object;
    try std.testing.expectEqualStrings("not_cross_ref", d.get("code").?.string);

    const related = d.get("relatedInformation").?.array;
    try std.testing.expectEqual(@as(usize, 1), related.items.len);
    const r0 = related.items[0].object;

    const loc = r0.get("location").?.object;
    try std.testing.expectEqualStrings("file:///b.sjon", loc.get("uri").?.string);
    const range = loc.get("range").?.object;
    try std.testing.expectEqual(@as(i64, 0), range.get("start").?.object.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 14), range.get("start").?.object.get("character").?.integer);
    try std.testing.expectEqual(@as(i64, 16), range.get("end").?.object.get("character").?.integer);

    try std.testing.expect(std.mem.indexOf(u8, r0.get("message").?.string, "p0") != null);
}

test "a diagnostic with no relations omits relatedInformation" {
    var fx = DispatchFixture.init();
    defer fx.deinit();
    try fx.openCrossRefDoc();

    // Unknown head: no derivable relation.
    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///c.sjon","version":1,"languageId":"sjon","text":"(wibble :x 1)"}}}
    );

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///c.sjon"}}}
    );
    defer res.deinit();

    const items = res.value.object.get("result").?.object.get("items").?.array;
    try std.testing.expect(items.items.len > 0);
    try std.testing.expect(items.items[0].object.get("relatedInformation") == null);
}

test "diagnostic JSON carries codeDescription pointing at the code's page" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.sjon","version":1,"languageId":"sjon","text":"(unclosed :key 1"}}}
    );

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///a.sjon"}}}
    );
    defer res.deinit();

    const items = res.value.object.get("result").?.object.get("items").?.array;
    try std.testing.expect(items.items.len > 0);
    for (items.items) |item| {
        const d = item.object;
        const href = d.get("codeDescription").?.object.get("href").?.string;
        const code = d.get("code").?.string;
        try std.testing.expect(std.mem.startsWith(u8, href, "https://hugodaniel.com/pages/sjon/errors/"));
        try std.testing.expect(std.mem.endsWith(u8, href, code));
    }
}

test "code action JSON carries the diagnostic it fixes" {
    // LSP `CodeAction.diagnostics` is `Diagnostic[]`, and it is how a
    // client pairs a quickfix with the squiggle it resolves. Two
    // identically-titled actions over one selection are indistinguishable
    // without it.
    var fx = DispatchFixture.init();
    defer fx.deinit();

    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.sjon","version":1,"languageId":"sjon","text":"[(clmp 1 0 2) (clmp 3 0 4)]"}}}
    );

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///a.sjon"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":27}},"context":{"diagnostics":[]}}}
    );
    defer res.deinit();

    const actions = res.value.object.get("result").?.array;
    try std.testing.expectEqual(@as(usize, 2), actions.items.len);

    for (actions.items) |act| {
        const diags = act.object.get("diagnostics").?.array;
        try std.testing.expectEqual(@as(usize, 1), diags.items.len);
        const d = diags.items[0].object;
        try std.testing.expectEqualStrings("unknown_form", d.get("code").?.string);
        try std.testing.expect(d.get("message").?.string.len > 0);

        // The diagnostic's range must be the one this action's edit
        // rewrites — that identity is the whole point of the field.
        const edit = act.object.get("edit").?.object
            .get("changes").?.object
            .get("file:///a.sjon").?.array.items[0].object;
        const edit_start = edit.get("range").?.object.get("start").?.object;
        const diag_start = d.get("range").?.object.get("start").?.object;
        try std.testing.expectEqual(
            edit_start.get("character").?.integer,
            diag_start.get("character").?.integer,
        );
    }
}

test "inlay hint JSON carries ghost defaults with kind: 2" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    var schemas = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"sjon/setSchemas","params":{"schemas":[{"uri":"inmemory://schema/0","text":"(plugin :name p :version \"1.0.0\" (form :name scene (key :name fps :type number :default 60)))"}]}}
    );
    defer schemas.deinit();

    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.sjon","version":1,"languageId":"sjon","text":"(scene)"}}}
    );

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/inlayHint","params":{"textDocument":{"uri":"file:///a.sjon"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":7}}}}
    );
    defer res.deinit();

    const hints = res.value.object.get("result").?.array;
    var ghost: ?std.json.ObjectMap = null;
    for (hints.items) |h| {
        if (std.mem.startsWith(u8, h.object.get("label").?.string, ":fps")) ghost = h.object;
    }
    const g = ghost orelse return error.TestMissingGhostHint;

    try std.testing.expectEqualStrings(":fps 60", g.get("label").?.string);
    // LSP `InlayHintKind.Parameter` is 2.
    try std.testing.expectEqual(@as(i64, 2), g.get("kind").?.integer);
    // On the closing paren, character 6 of `(scene)`.
    try std.testing.expectEqual(@as(i64, 6), g.get("position").?.object.get("character").?.integer);
    try std.testing.expect(g.get("paddingLeft").?.bool);

    // The plugin-source hint rides in the same response and must NOT have
    // gained a kind — it shipped without one, and clients render unkinded
    // hints differently.
    var plugin_hint: ?std.json.ObjectMap = null;
    for (hints.items) |h| {
        if (std.mem.eql(u8, h.object.get("label").?.string, "p")) plugin_hint = h.object;
    }
    const ph = plugin_hint orelse return error.TestMissingPluginHint;
    try std.testing.expect(ph.get("kind") == null);
}

test "code action JSON distinguishes refactor from quickfix" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    var schemas = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"sjon/setSchemas","params":{"schemas":[{"uri":"inmemory://schema/0","text":"(plugin :name p :version \"1.0.0\" (form :name scene (key :name fps :type number :default 60)))"}]}}
    );
    defer schemas.deinit();

    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.sjon","version":1,"languageId":"sjon","text":"(scene)"}}}
    );

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///a.sjon"},"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":1}},"context":{"diagnostics":[]}}}
    );
    defer res.deinit();

    const actions = res.value.object.get("result").?.array;
    var materialize: ?std.json.ObjectMap = null;
    for (actions.items) |act| {
        if (std.mem.eql(u8, act.object.get("title").?.string, "Materialize omitted defaults")) {
            materialize = act.object;
        }
    }
    const m = materialize orelse return error.TestMissingMaterializeAction;

    try std.testing.expectEqualStrings("refactor.rewrite", m.get("kind").?.string);
    // A refactor is a choice, never something a client should auto-apply
    // as "the" fix for the cursor position.
    try std.testing.expect(m.get("isPreferred") == null);
    try std.testing.expectEqual(@as(usize, 0), m.get("diagnostics").?.array.items.len);
}

test "code action offers refactor.extract at a union cross-ref slot" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    // A `union{form, cross_ref}` slot: `(track :lead …)` accepts either an
    // inline `(phrase …)` or a name referencing a `(phrase :name …)`.
    var schemas = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"sjon/setSchemas","params":{"schemas":[{"uri":"inmemory://schema/0","text":"(plugin :name song :version \"1.0.0\" (value-kind :name phrase-inline :underlying form :heads (head-set :names [phrase])) (value-kind :name phrase-ref :underlying symbol :cross-ref (cross-ref :target phrase)) (value-kind :name phrase-or-ref :underlying union :union (union-shape :alternatives [phrase-inline phrase-ref])) (form :name phrase (key :name name :type symbol :optional true)) (form :name track (key :name lead :type phrase-or-ref)))"}]}}
    );
    defer schemas.deinit();

    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.sjon","version":1,"languageId":"sjon","text":"(track :lead (phrase))"}}}
    );

    // Cursor inside the inline `(phrase)` — character 14.
    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///a.sjon"},"range":{"start":{"line":0,"character":14},"end":{"line":0,"character":14}},"context":{"diagnostics":[]}}}
    );
    defer res.deinit();

    const actions = res.value.object.get("result").?.array;
    var extract: ?std.json.ObjectMap = null;
    for (actions.items) |act| {
        if (std.mem.eql(u8, act.object.get("kind").?.string, "refactor.extract")) {
            extract = act.object;
        }
    }
    const e = extract orelse return error.TestMissingExtractAction;

    // A refactor the user chose — never auto-applied.
    try std.testing.expect(e.get("isPreferred") == null);
    // Two edits in the one document: the reference rewrite + the hoisted
    // definition, nested under `edit.changes[uri]`.
    const edits = e.get("edit").?.object
        .get("changes").?.object
        .get("file:///a.sjon").?.array;
    try std.testing.expectEqual(@as(usize, 2), edits.items.len);
}

// ---------------------------------------------------------------------------
// Versioned WorkspaceEdits
//
// The `changes` map has nowhere to put a version, so an edit computed at
// request time applies to whatever the buffer holds when the user clicks it
// — and these edits are byte-anchored, so inline can delete a region that
// stopped being the definition in between. `documentChanges` stamps the
// version and lets the client refuse.
// ---------------------------------------------------------------------------

/// `initialize` announcing `workspace.workspaceEdit.documentChanges`.
fn initializeWithDocumentChanges(fx: DispatchFixture) !void {
    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":100,"method":"initialize","params":{"capabilities":{"workspace":{"workspaceEdit":{"documentChanges":true}}}}}
    );
    res.deinit();
}

/// Open `(track :lead (phrase))` under the extract schema at `version`, and
/// return the `refactor.extract` action's `edit` object.
fn extractEditAt(fx: DispatchFixture, version: []const u8) !std.json.Parsed(std.json.Value) {
    var schemas = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"sjon/setSchemas","params":{"schemas":[{"uri":"inmemory://schema/0","text":"(plugin :name song :version \"1.0.0\" (value-kind :name phrase-inline :underlying form :heads (head-set :names [phrase])) (value-kind :name phrase-ref :underlying symbol :cross-ref (cross-ref :target phrase)) (value-kind :name phrase-or-ref :underlying union :union (union-shape :alternatives [phrase-inline phrase-ref])) (form :name phrase (key :name name :type symbol :optional true)) (form :name track (key :name lead :type phrase-or-ref)))"}]}}
    );
    schemas.deinit();

    var buf: [512]u8 = undefined;
    handleMessage(try std.fmt.bufPrint(
        &buf,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///a.sjon\",\"version\":{s},\"languageId\":\"sjon\",\"text\":\"(track :lead (phrase))\"}}}}}}",
        .{version},
    ));

    return fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///a.sjon"},"range":{"start":{"line":0,"character":14},"end":{"line":0,"character":14}},"context":{"diagnostics":[]}}}
    );
}

fn extractEditOf(parsed: std.json.Parsed(std.json.Value)) !std.json.ObjectMap {
    for (parsed.value.object.get("result").?.array.items) |act| {
        if (std.mem.eql(u8, act.object.get("kind").?.string, "refactor.extract")) {
            return act.object.get("edit").?.object;
        }
    }
    return error.TestMissingExtractAction;
}

test "a code action's edit carries the document version when the client asked for it" {
    var fx = DispatchFixture.init();
    defer fx.deinit();
    try initializeWithDocumentChanges(fx);

    var res = try extractEditAt(fx, "7");
    defer res.deinit();
    const edit = try extractEditOf(res);

    // `changes` and `documentChanges` are alternatives, not both: a client
    // that honours the second would apply the first as well.
    try std.testing.expect(edit.get("changes") == null);
    const dc = edit.get("documentChanges").?.array;
    try std.testing.expectEqual(@as(usize, 1), dc.items.len);

    const td = dc.items[0].object.get("textDocument").?.object;
    try std.testing.expectEqualStrings("file:///a.sjon", td.get("uri").?.string);
    try std.testing.expectEqual(@as(i64, 7), td.get("version").?.integer);
    // The same two edits as the unversioned shape — only the wrapper moved.
    try std.testing.expectEqual(@as(usize, 2), dc.items[0].object.get("edits").?.array.items.len);
}

test "the stamped version follows the buffer, not the open" {
    var fx = DispatchFixture.init();
    defer fx.deinit();
    try initializeWithDocumentChanges(fx);

    var first = try extractEditAt(fx, "7");
    first.deinit();

    // A stamp fixed at open time would pass the test above and still send
    // the client a version it has moved past.
    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.sjon","version":11},"contentChanges":[{"text":"(track :lead (phrase))"}]}}
    );

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///a.sjon"},"range":{"start":{"line":0,"character":14},"end":{"line":0,"character":14}},"context":{"diagnostics":[]}}}
    );
    defer res.deinit();
    const edit = try extractEditOf(res);
    const td = edit.get("documentChanges").?.array.items[0].object.get("textDocument").?.object;
    try std.testing.expectEqual(@as(i64, 11), td.get("version").?.integer);
}

test "a client that never asked keeps the unversioned changes map" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    // No `initialize` at all — the shape a client that cannot read
    // `documentChanges` must still get, or it applies nothing.
    var res = try extractEditAt(fx, "7");
    defer res.deinit();
    const edit = try extractEditOf(res);

    try std.testing.expect(edit.get("documentChanges") == null);
    try std.testing.expectEqual(
        @as(usize, 2),
        edit.get("changes").?.object.get("file:///a.sjon").?.array.items.len,
    );
}

test "rename edits carry versions through the same serializer" {
    var fx = DispatchFixture.init();
    defer fx.deinit();
    try initializeWithDocumentChanges(fx);

    var schemas = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"sjon/setSchemas","params":{"schemas":[{"uri":"inmemory://schema/0","text":"(plugin :name song :version \"1.0.0\" (value-kind :name phrase-ref :underlying symbol :cross-ref (cross-ref :target phrase)) (form :name phrase (key :name name :type symbol)) (form :name track (key :name lead :type phrase-ref)))"}]}}
    );
    schemas.deinit();

    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.sjon","version":5,"languageId":"sjon","text":"(phrase :name p0)\n(track :lead p0)"}}}
    );

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///a.sjon"},"position":{"line":0,"character":15},"newName":"p1"}}
    );
    defer res.deinit();

    const edit = res.value.object.get("result").?.object;
    try std.testing.expect(edit.get("changes") == null);
    const td = edit.get("documentChanges").?.array.items[0].object.get("textDocument").?.object;
    try std.testing.expectEqual(@as(i64, 5), td.get("version").?.integer);
}

test "a rejected rename tells the client why before answering null" {
    // The handler's refusal carries a reason (`cannot rename to \`)(\`:
    // not a symbol`, `already declared in this scope`, the provider-backed
    // refusal) and the transport used to drop it on the floor: the client
    // saw a null result, which editors render as nothing at all. A
    // `window/showMessage` warning ahead of the null puts the reason in
    // front of the user; the result stays null so clients keep treating
    // the rename as not performed.
    var fx = DispatchFixture.init();
    defer fx.deinit();
    try initializeWithDocumentChanges(fx);

    var schemas = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"sjon/setSchemas","params":{"schemas":[{"uri":"inmemory://schema/0","text":"(plugin :name song :version \"1.0.0\" (value-kind :name phrase-ref :underlying symbol :cross-ref (cross-ref :target phrase)) (form :name phrase (key :name name :type symbol)) (form :name track (key :name lead :type phrase-ref)))"}]}}
    );
    schemas.deinit();

    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.sjon","version":5,"languageId":"sjon","text":"(phrase :name p0)\n(track :lead p0)"}}}
    );

    const before = fx.sent().len;
    handleMessage(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///a.sjon"},"position":{"line":0,"character":15},"newName":"has space"}}
    );
    try std.testing.expectEqual(before + 2, fx.sent().len);

    var notice = try std.json.parseFromSlice(std.json.Value, wasm_allocator, fx.sent()[before], .{});
    defer notice.deinit();
    try std.testing.expectEqualStrings("window/showMessage", notice.value.object.get("method").?.string);
    const params = notice.value.object.get("params").?.object;
    try std.testing.expectEqual(@as(i64, 2), params.get("type").?.integer); // MessageType.Warning
    const message = params.get("message").?.string;
    try std.testing.expect(std.mem.indexOf(u8, message, "has space") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "not a symbol") != null);

    var res = try std.json.parseFromSlice(std.json.Value, wasm_allocator, fx.sent()[before + 1], .{});
    defer res.deinit();
    try std.testing.expectEqual(@as(i64, 2), res.value.object.get("id").?.integer);
    try std.testing.expect(res.value.object.get("result").? == .null);
}

test "code action offers refactor.inline at a union cross-ref reference" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    // Same `union{form, cross_ref}` slot; here the document *references* a named
    // `(phrase :name p0 …)` — the shape inline dissolves.
    var schemas = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"sjon/setSchemas","params":{"schemas":[{"uri":"inmemory://schema/0","text":"(plugin :name song :version \"1.0.0\" (value-kind :name phrase-inline :underlying form :heads (head-set :names [phrase])) (value-kind :name phrase-ref :underlying symbol :cross-ref (cross-ref :target phrase)) (value-kind :name phrase-or-ref :underlying union :union (union-shape :alternatives [phrase-inline phrase-ref])) (form :name phrase (key :name name :type symbol :optional true)) (form :name track (key :name lead :type phrase-or-ref)))"}]}}
    );
    defer schemas.deinit();

    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.sjon","version":1,"languageId":"sjon","text":"(phrase :name p0)\n(track :lead p0)"}}}
    );

    // Cursor on the reference `p0` — line 1, character 13.
    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///a.sjon"},"range":{"start":{"line":1,"character":13},"end":{"line":1,"character":13}},"context":{"diagnostics":[]}}}
    );
    defer res.deinit();

    const actions = res.value.object.get("result").?.array;
    var inline_act: ?std.json.ObjectMap = null;
    for (actions.items) |act| {
        if (std.mem.eql(u8, act.object.get("kind").?.string, "refactor.inline")) {
            inline_act = act.object;
        }
    }
    const e = inline_act orelse return error.TestMissingInlineAction;

    // A refactor the user chose — never auto-applied.
    try std.testing.expect(e.get("isPreferred") == null);
    // Sole reference → two edits: the splice + the definition's deletion.
    const edits = e.get("edit").?.object
        .get("changes").?.object
        .get("file:///a.sjon").?.array;
    try std.testing.expectEqual(@as(usize, 2), edits.items.len);
}

test "initialize advertises every code action kind" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
    );
    defer res.deinit();

    // A client filters by kind: an unadvertised `refactor.extract` is one
    // a conforming client never asks for, so the action would be invisible
    // no matter how correct the Handler is.
    const kinds = res.value.object.get("result").?.object
        .get("capabilities").?.object
        .get("codeActionProvider").?.object
        .get("codeActionKinds").?.array;
    var saw_quickfix = false;
    var saw_refactor = false;
    var saw_extract = false;
    var saw_inline = false;
    for (kinds.items) |k| {
        if (std.mem.eql(u8, k.string, "quickfix")) saw_quickfix = true;
        if (std.mem.eql(u8, k.string, "refactor.rewrite")) saw_refactor = true;
        if (std.mem.eql(u8, k.string, "refactor.extract")) saw_extract = true;
        if (std.mem.eql(u8, k.string, "refactor.inline")) saw_inline = true;
    }
    try std.testing.expect(saw_quickfix);
    try std.testing.expect(saw_refactor);
    try std.testing.expect(saw_extract);
    try std.testing.expect(saw_inline);
}

test "sjon/effectiveDocument returns the spliced text" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    var schemas = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"sjon/setSchemas","params":{"schemas":[{"uri":"inmemory://schema/0","text":"(plugin :name p :version \"1.0.0\" (form :name scene (key :name fps :type number :default 60)))"}]}}
    );
    defer schemas.deinit();

    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.sjon","version":1,"languageId":"sjon","text":"(scene)"}}}
    );

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"sjon/effectiveDocument","params":{"textDocument":{"uri":"file:///a.sjon"}}}
    );
    defer res.deinit();

    try std.testing.expectEqualStrings(
        "(scene :fps 60)",
        res.value.object.get("result").?.object.get("text").?.string,
    );
}

test "sjon/effectiveDocument on an unopened uri yields null" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"sjon/effectiveDocument","params":{"textDocument":{"uri":"file:///nope.sjon"}}}
    );
    defer res.deinit();

    try std.testing.expect(res.value.object.get("result").? == .null);
}

test "sjon/evalDocument returns the entries as JSON" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    var schemas = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"sjon/setSchemas","params":{"schemas":[{"uri":"inmemory://schema/0","text":"(plugin :name p :version \"1.0.0\" (form :name scene (key :name fps :type number :optional true)))"}]}}
    );
    defer schemas.deinit();

    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.sjon","version":1,"languageId":"sjon","text":"(scene :fps (+ 1 2))\n(/ 1 0)"}}}
    );

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"sjon/evalDocument","params":{"textDocument":{"uri":"file:///a.sjon"}}}
    );
    defer res.deinit();

    const entries = res.value.object.get("result").?.object.get("entries").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), entries.len);

    // The nested expression, ranged in the negotiated encoding rather than
    // the byte offsets the Handler speaks.
    try std.testing.expectEqualStrings("3", entries[0].object.get("value").?.string);
    const start = entries[0].object.get("range").?.object.get("start").?.object;
    try std.testing.expectEqual(@as(i64, 0), start.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 12), start.get("character").?.integer);

    // A failed root carries the kind and no value — the two fields are
    // alternatives, so a client can switch on presence.
    try std.testing.expectEqualStrings("failed", entries[1].object.get("error").?.string);
    try std.testing.expect(entries[1].object.get("value") == null);
    try std.testing.expect(entries[0].object.get("error") == null);
}

test "sjon/evalDocument on an unopened uri yields null" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"sjon/evalDocument","params":{"textDocument":{"uri":"file:///nope.sjon"}}}
    );
    defer res.deinit();

    try std.testing.expect(res.value.object.get("result").? == .null);
}

test "semanticTokens/full returns the relative-encoded data array" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    var schemas = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"sjon/setSchemas","params":{"schemas":[{"uri":"inmemory://schema/0","text":"(plugin :name p :version \"1.0.0\" (form :name scene (key :name fps :type number :optional true)))"}]}}
    );
    defer schemas.deinit();

    // `(scene :fps 60)\n(+ 1 2)`
    // `scene` at char 1 len 5 (macro), `:fps` at char 7 len 4 (property),
    // `+` on the next line at char 1 len 1 (function, defaultLibrary).
    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.sjon","version":1,"languageId":"sjon","text":"(scene :fps 60)\n(+ 1 2)"}}}
    );

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"file:///a.sjon"}}}
    );
    defer res.deinit();

    const data = res.value.object.get("result").?.object.get("data").?.array.items;
    // Hand-computed quintuples. `deltaStart` is relative to the previous
    // token on the same line and absolute after a line break; the last
    // token's modifier bitset is 0b10 — bit 1 is `defaultLibrary`.
    const want = [_]i64{
        0, 1, 5, 1, 0,
        0, 6, 4, 3, 0,
        1, 1, 1, 2, 2,
    };
    try std.testing.expectEqual(want.len, data.len);
    for (want, data) |w, got| try std.testing.expectEqual(w, got.integer);
}

test "initialize advertises the semantic tokens legend" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
    );
    defer res.deinit();

    const provider = res.value.object.get("result").?.object
        .get("capabilities").?.object
        .get("semanticTokensProvider").?.object;

    // The client is told the legend once and thereafter receives bare
    // indices, so both lists are positional wire contracts.
    const types = provider.get("legend").?.object.get("tokenTypes").?.array.items;
    try std.testing.expectEqual(Handler.SemanticToken.Type.legend.len, types.len);
    for (Handler.SemanticToken.Type.legend, types) |want, got| {
        try std.testing.expectEqualStrings(want, got.string);
    }
    const mods = provider.get("legend").?.object.get("tokenModifiers").?.array.items;
    try std.testing.expectEqual(Handler.SemanticToken.Mods.legend.len, mods.len);
    for (Handler.SemanticToken.Mods.legend, mods) |want, got| {
        try std.testing.expectEqualStrings(want, got.string);
    }

    // `full: true` only — delta and range variants are out of scope, and
    // advertising one we don't implement invites requests we can't answer.
    try std.testing.expect(provider.get("full").?.bool);
    try std.testing.expect(provider.get("range") == null);
}

test "semantic token deltas count utf-16 units across a surrogate pair" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    var schemas = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"sjon/setSchemas","params":{"schemas":[{"uri":"inmemory://schema/0","text":"(plugin :name p :version \"1.0.0\" (form :name scene (key :name label :type string :optional true) (key :name fps :type number :optional true)))"}]}}
    );
    defer schemas.deinit();

    // `(scene :label "<emoji>" :fps 60)` — U+1F600 is 4 UTF-8 bytes but 2
    // UTF-16 code units, so `:fps` sits at character 19, not byte 21.
    // Written as a JSON surrogate escape rather than a literal, so the
    // codepoint under test is legible in the source.
    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.sjon","version":1,"languageId":"sjon","text":"(scene :label \"\ud83d\ude00\" :fps 60)"}}}
    );

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"file:///a.sjon"}}}
    );
    defer res.deinit();

    const data = res.value.object.get("result").?.object.get("data").?.array.items;
    try std.testing.expectEqual(@as(usize, 15), data.len);
    // `:label` starts 6 units after `scene`; `:fps` starts 12 units after
    // `:label`. Byte arithmetic would say 14 — that gap is the bug this
    // test exists to catch.
    try std.testing.expectEqual(@as(i64, 6), data[6].integer);
    try std.testing.expectEqual(@as(i64, 12), data[11].integer);
}

// --- incremental text sync (plan 06 CP2) --------------------------------
//
// These drive `textDocument/didChange` and then read the stored text back
// through `sjon/effectiveDocument`, which returns `doc.source` byte-for-byte
// when no schema is installed (nothing to materialize). That makes it an
// exact read of what the splice produced, rather than an inference from
// diagnostics.

/// Open `text` as `file:///a.sjon` at version 1, with no schema installed.
fn openPlain(fx: DispatchFixture, text_json: []const u8) void {
    _ = fx;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///a.sjon\",\"version\":1,\"languageId\":\"sjon\",\"text\":\"{s}\"}}}}}}",
        .{text_json},
    ) catch unreachable;
    handleMessage(msg);
}

/// The stored text of `file:///a.sjon`, read back through the dispatcher.
fn storedText(fx: DispatchFixture) !std.json.Parsed(std.json.Value) {
    return fx.request(
        \\{"jsonrpc":"2.0","id":99,"method":"sjon/effectiveDocument","params":{"textDocument":{"uri":"file:///a.sjon"}}}
    );
}

test "ranged didChange applies a splice" {
    var fx = DispatchFixture.init();
    defer fx.deinit();
    openPlain(fx, "(scene :fps 60)");

    // Characters 12..14 are `60`. A full-replace reading of this payload
    // would take `text` as the whole document and leave `30` behind.
    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.sjon","version":2},"contentChanges":[{"range":{"start":{"line":0,"character":12},"end":{"line":0,"character":14}},"text":"30"}]}}
    );

    var res = try storedText(fx);
    defer res.deinit();
    try std.testing.expectEqualStrings(
        "(scene :fps 30)",
        res.value.object.get("result").?.object.get("text").?.string,
    );
}

test "multiple contentChanges apply in order" {
    var fx = DispatchFixture.init();
    defer fx.deinit();
    openPlain(fx, "(a)");

    // The second range is expressed against the text the first one
    // produced — `(bb)` — not against `(a)`. Resolving both against the
    // original would put the second edit on `)`.
    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.sjon","version":2},"contentChanges":[{"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":2}},"text":"bb"},{"range":{"start":{"line":0,"character":2},"end":{"line":0,"character":3}},"text":"c"}]}}
    );

    var res = try storedText(fx);
    defer res.deinit();
    try std.testing.expectEqualStrings(
        "(bc)",
        res.value.object.get("result").?.object.get("text").?.string,
    );
}

test "range-less contentChange still replaces the whole doc" {
    var fx = DispatchFixture.init();
    defer fx.deinit();
    openPlain(fx, "(a)");

    // Spec-required fallback: a client may send a whole-document change
    // even to a server advertising incremental sync.
    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.sjon","version":2},"contentChanges":[{"text":"(zzz)"}]}}
    );

    var res = try storedText(fx);
    defer res.deinit();
    try std.testing.expectEqualStrings(
        "(zzz)",
        res.value.object.get("result").?.object.get("text").?.string,
    );
}

test "ranged didChange decodes utf-16 positions across a surrogate pair" {
    var fx = DispatchFixture.init();
    defer fx.deinit();
    // `(x "<U+1F600>ab")` — the emoji is 4 UTF-8 bytes but 2 UTF-16 code
    // units, so `a` sits at character 6 and byte 8.
    openPlain(fx, "(x \\\"\\ud83d\\ude00ab\\\")");

    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.sjon","version":2},"contentChanges":[{"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":7}},"text":"Z"}]}}
    );

    var res = try storedText(fx);
    defer res.deinit();
    // Byte-indexing the character offsets would splice into the middle of
    // the emoji and corrupt it. The emoji must come back intact.
    try std.testing.expectEqualStrings(
        "(x \"\u{1F600}Zb\")",
        res.value.object.get("result").?.object.get("text").?.string,
    );
}

test "initialize advertises incremental text sync" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );
    defer res.deinit();

    const sync = res.value.object.get("result").?.object
        .get("capabilities").?.object.get("textDocumentSync").?.object;
    try std.testing.expect(sync.get("openClose").?.bool);
    // 2 = Incremental. 1 (Full) is what this server advertised before
    // it could apply ranges.
    try std.testing.expectEqual(@as(i64, 2), sync.get("change").?.integer);
}

test "a malformed contentChange drops the whole batch, and the document with it" {
    var fx = DispatchFixture.init();
    defer fx.deinit();
    openPlain(fx, "(a)");

    // The first change is well-formed, the second has no `end`. Applying
    // only the first would leave a buffer the client believes it has
    // edited twice, so the batch is refused whole. But refusing it also
    // leaves this server's copy an edit behind *for good* — every later
    // incremental change would splice against a base the client no longer
    // has. So the document goes too.
    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.sjon","version":2},"contentChanges":[{"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":2}},"text":"bb"},{"range":{"start":{"line":0,"character":0}},"text":"c"}]}}
    );

    var gone = try storedText(fx);
    defer gone.deinit();
    try std.testing.expect(gone.value.object.get("result").? == .null);

    // The sharp consequence of the old behaviour: a refactor offered
    // against the stale copy carries byte offsets into text the buffer
    // does not have, and the client applies them. With no document there
    // is nothing to offer.
    var actions = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///a.sjon"},"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":1}},"context":{"diagnostics":[]}}}
    );
    defer actions.deinit();
    try std.testing.expect(actions.value.object.get("result").? == .null);
}

test "a whole-document change resynchronises a dropped document" {
    var fx = DispatchFixture.init();
    defer fx.deinit();
    openPlain(fx, "(a)");

    // Same malformed batch — the document is dropped…
    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.sjon","version":2},"contentChanges":[{"range":{"start":{"line":0,"character":0}},"text":"c"}]}}
    );

    // …and the client's next full sync brings it back, with no didOpen.
    // This is the recovery path that makes dropping cheap: the playground
    // sends exactly this shape on every keystroke.
    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.sjon","version":3},"contentChanges":[{"text":"(b)"}]}}
    );

    var res = try storedText(fx);
    defer res.deinit();
    try std.testing.expectEqualStrings(
        "(b)",
        res.value.object.get("result").?.object.get("text").?.string,
    );
}

test "an incremental change against a dropped document is refused, not invented" {
    var fx = DispatchFixture.init();
    defer fx.deinit();
    openPlain(fx, "(a)");

    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.sjon","version":2},"contentChanges":[{"range":{"start":{"line":0,"character":0}},"text":"c"}]}}
    );

    // A ranged change carries no base text, so there is nothing to
    // resynchronise from. Answering it would mean guessing.
    handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.sjon","version":3},"contentChanges":[{"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":2}},"text":"z"}]}}
    );

    var gone = try storedText(fx);
    defer gone.deinit();
    try std.testing.expect(gone.value.object.get("result").? == .null);
}

test "rangeFormatting reformats only the covering root" {
    var fx = DispatchFixture.init();
    defer fx.deinit();
    // Two roots, root[0] messy. `\\u0020` is not needed — plain spaces.
    openPlain(fx, "(alpha    1)\\n(beta 2)");

    // Range strictly inside root[0]: line 0, characters 0..5.
    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":7,"method":"textDocument/rangeFormatting","params":{"textDocument":{"uri":"file:///a.sjon"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}}}}
    );
    defer res.deinit();

    const edits = res.value.object.get("result").?.array;
    try std.testing.expectEqual(@as(usize, 1), edits.items.len);
    try std.testing.expectEqualStrings(
        "(alpha 1)",
        edits.items[0].object.get("newText").?.string,
    );
    // The edit's range must be root[0]'s own span: chars 0..12 on line 0.
    const range = edits.items[0].object.get("range").?.object;
    try std.testing.expectEqual(@as(i64, 0), range.get("start").?.object.get("character").?.integer);
    try std.testing.expectEqual(@as(i64, 12), range.get("end").?.object.get("character").?.integer);
}

test "initialize advertises range formatting" {
    var fx = DispatchFixture.init();
    defer fx.deinit();

    var res = try fx.request(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );
    defer res.deinit();

    const caps = res.value.object.get("result").?.object.get("capabilities").?.object;
    try std.testing.expect(caps.get("documentRangeFormattingProvider").?.bool);
}
