//! End-to-end tests for `Cli.run`. Each case constructs an argv slice
//! and a pair of `Writer.Allocating` buffers, calls `run`, and asserts
//! on the exit code plus rendered output. No subprocess spawning — the
//! same bytes the binary would print to stdout/stderr land in the
//! buffers here.
//!
//! The `sjon validate -` (stdin) path is not exercised here: redirecting
//! the process-global stdin from a unit test would mean either swapping
//! `Io` implementations mid-run or wrapping `loadSource` in another
//! seam. Keeping the CLI seam at `run` itself, the stdin branch is
//! covered manually (see Verification step 3 in the D2 plan).

const std = @import("std");
const testing = std.testing;
const Cli = @import("Cli.zig");
const build_options = @import("build_options");

const fixture_clean: [:0]const u8 = "conformance/cases/inline-manifest-clean/document.sjon";
const fixture_data_error: [:0]const u8 = "conformance/cases/inline-manifest-data-error/document.sjon";
const fixture_invalid: [:0]const u8 = "conformance/cases/inline-manifest-invalid/document.sjon";

const Captured = struct {
    code: u8,
    stdout: std.Io.Writer.Allocating,
    stderr: std.Io.Writer.Allocating,

    fn deinit(self: *Captured) void {
        self.stdout.deinit();
        self.stderr.deinit();
    }
};

fn invoke(args: []const [:0]const u8) !Captured {
    const a = testing.allocator;
    var stdout: std.Io.Writer.Allocating = .init(a);
    errdefer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(a);
    errdefer stderr.deinit();
    const code = try Cli.run(a, testing.io, args, &stdout.writer, &stderr.writer, .{});
    return .{ .code = code, .stdout = stdout, .stderr = stderr };
}

test "Cli: --help prints usage to stdout, exit 0" {
    var out = try invoke(&.{ "sjon", "--help" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "Usage:") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "validate") != null);
    try testing.expectEqual(@as(usize, 0), out.stderr.written().len);
}

test "Cli: -h short form matches --help" {
    var out = try invoke(&.{ "sjon", "-h" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "Usage:") != null);
}

test "Cli: no args dispatches to `sjon check`" {
    // Slice 11 default-verb dispatch — `sjon` alone routes to `check`,
    // which discovers the project file walking up from cwd. The
    // outcome depends on whether there's a project file in the
    // current working directory's ancestry. The contract here is that
    // it does NOT return a "missing command" usage error.
    var out = try invoke(&.{"sjon"});
    defer out.deinit();
    // 0 = clean check, 1 = check found errors (incl. "no project").
    // 2 would be a usage error we shouldn't see anymore.
    try testing.expect(out.code != 2);
}

test "Cli: validate without FILE is a usage error" {
    var out = try invoke(&.{ "sjon", "validate" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "FILE") != null);
}

test "Cli: unknown non-verb argument falls through to `sjon check`" {
    // Slice 11 default-verb dispatch — `sjon FILE` (or `sjon <typo>`)
    // treats the first positional as a `sjon check` document arg.
    // The check itself fails (no project file in cwd, file unreadable),
    // but the result is no longer "unknown command" — it's a normal
    // check failure.
    var out = try invoke(&.{ "sjon", "wat" });
    defer out.deinit();
    try testing.expect(out.code != 2);
}

test "Cli: unknown flag is a usage error" {
    var out = try invoke(&.{ "sjon", "validate", "--bogus", fixture_clean });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "unknown option") != null);
}

test "Cli: unknown --format value is a usage error" {
    var out = try invoke(&.{ "sjon", "validate", "--format=yaml", fixture_clean });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "format") != null);
}

test "Cli: nonexistent file is a usage error" {
    var out = try invoke(&.{ "sjon", "validate", "/definitely/does/not/exist.sjon" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "cannot read") != null);
}

test "Cli: clean fixture validates successfully (human format)" {
    var out = try invoke(&.{ "sjon", "validate", fixture_clean });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expectEqual(@as(usize, 0), out.stdout.written().len);
}

test "Cli: data-error fixture emits one diagnostic, exit 1 (human format)" {
    var out = try invoke(&.{ "sjon", "validate", fixture_data_error });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    const text = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, text, "missing_required_key") != null);
    try testing.expect(std.mem.indexOf(u8, text, "phase: validation") != null);
    try testing.expect(std.mem.indexOf(u8, text, "1 error") != null);
}

test "Cli: invalid fixture surfaces manifest + validation diagnostics" {
    var out = try invoke(&.{ "sjon", "validate", fixture_invalid });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    const text = out.stdout.written();
    // First diagnostic — manifest phase, missing :name on the (plugin …)
    // declaration.
    const idx_missing = std.mem.indexOf(u8, text, "missing_required_key") orelse return error.MissingExpectedDiagnostic;
    const idx_unknown = std.mem.indexOf(u8, text, "unknown_form") orelse return error.MissingExpectedDiagnostic;
    try testing.expect(idx_missing < idx_unknown);
    try testing.expect(std.mem.indexOf(u8, text, "phase: manifest") != null);
    try testing.expect(std.mem.indexOf(u8, text, "in declaration at") != null);
    try testing.expect(std.mem.indexOf(u8, text, "2 errors") != null);
}

test "Cli: --format=json on clean fixture emits empty diagnostics array" {
    var out = try invoke(&.{ "sjon", "validate", "--format=json", fixture_clean });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.stdout.written(), .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings(fixture_clean, obj.get("file").?.string);
    try testing.expectEqual(@as(usize, 0), obj.get("diagnostics").?.array.items.len);
}

test "Cli: --format=json on data-error fixture has line/col and null declaration_span" {
    var out = try invoke(&.{ "sjon", "validate", "--format=json", fixture_data_error });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.stdout.written(), .{});
    defer parsed.deinit();
    const diags = parsed.value.object.get("diagnostics").?.array;
    try testing.expectEqual(@as(usize, 1), diags.items.len);

    const d = diags.items[0].object;
    try testing.expectEqualStrings("missing_required_key", d.get("code").?.string);
    try testing.expectEqualStrings("error", d.get("severity").?.string);
    try testing.expectEqualStrings("validation", d.get("phase").?.string);
    try testing.expectEqual(std.json.Value{ .null = {} }, d.get("declaration_span").?);

    const span = d.get("span").?.object;
    try testing.expect(span.get("line").?.integer >= 1);
    try testing.expect(span.get("column").?.integer >= 1);
    try testing.expect(span.get("end").?.integer > span.get("start").?.integer);

    // Path round-trips as a JSON array of strings.
    const path = d.get("path").?.array;
    try testing.expectEqual(@as(usize, 1), path.items.len);
    try testing.expectEqualStrings("widget", path.items[0].string);
}

test "Cli: --format=json on invalid fixture has non-null declaration_span on manifest diag" {
    var out = try invoke(&.{ "sjon", "validate", "--format=json", fixture_invalid });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.stdout.written(), .{});
    defer parsed.deinit();
    const diags = parsed.value.object.get("diagnostics").?.array;
    try testing.expect(diags.items.len >= 2);

    const first = diags.items[0].object;
    try testing.expectEqualStrings("manifest", first.get("phase").?.string);
    try testing.expect(first.get("declaration_span").? != .null);
    const ds = first.get("declaration_span").?.object;
    try testing.expect(ds.get("line").?.integer >= 1);
}

// ---------------------------------------------------------------------------
// D3: project discovery + flag handling.
// ---------------------------------------------------------------------------

const fixture_resolved: [:0]const u8 = "conformance/cases/use-plugin-resolved/document.sjon";
const fixture_unresolved: [:0]const u8 = "conformance/cases/use-plugin-unresolved/document.sjon";

test "Cli: D3 walks up to find sjon-project.sjon and validates cleanly" {
    var out = try invoke(&.{ "sjon", "validate", fixture_resolved });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    // Project header lands on stdout; no diagnostics follow.
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "# project: ") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "sjon-project.sjon") != null);
}

test "Cli: D3 --no-project disables resolver, references unresolved" {
    var out = try invoke(&.{ "sjon", "validate", "--no-project", fixture_resolved });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    // No project header in human output (project_file is null).
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "# project:") == null);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "unresolved_plugin") != null);
}

test "Cli: D3 --project-root with missing sjon-project.sjon is a usage error" {
    var out = try invoke(&.{ "sjon", "validate", "--project-root", "/definitely/not/a/project", fixture_resolved });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    // The diagnostic code name appears in the message so the audit
    // script and machine consumers can match it without a structured
    // diagnostic stream (CLI usage errors don't get a HostResult).
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "project_file_not_found") != null);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "sjon-project.sjon") != null);
}

test "Cli: D3 --project-root=DIR short form works" {
    var out = try invoke(&.{
        "sjon",                                                 "validate",
        "--project-root=conformance/cases/use-plugin-resolved", fixture_resolved,
    });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
}

test "Cli: D3 --no-project + --project-root is a usage error" {
    var out = try invoke(&.{ "sjon", "validate", "--no-project", "--project-root", "x", fixture_resolved });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "mutually exclusive") != null);
}

test "Cli: D3 --project-root given twice yields a duplicate-flag usage error" {
    var out = try invoke(&.{ "sjon", "validate", "--project-root", "a", "--project-root", "b", fixture_resolved });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "given more than once") != null);
}

test "Cli: D3 --project-root refuses to swallow a following flag as the path" {
    var out = try invoke(&.{ "sjon", "validate", "--project-root", "--no-project", fixture_resolved });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "got a flag instead") != null);
}

test "Cli: D3 --project-root with no following arg is a usage error" {
    var out = try invoke(&.{ "sjon", "validate", "--project-root" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "--project-root requires a directory") != null);
}

test "Cli: D3 --format=json includes project_file path on resolved fixture" {
    var out = try invoke(&.{ "sjon", "validate", "--format=json", fixture_resolved });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.stdout.written(), .{});
    defer parsed.deinit();
    const project_file = parsed.value.object.get("project_file").?;
    try testing.expect(project_file == .string);
    try testing.expect(std.mem.endsWith(u8, project_file.string, "sjon-project.sjon"));
}

test "Cli: D3 --format=json sets project_file null when --no-project" {
    var out = try invoke(&.{ "sjon", "validate", "--format=json", "--no-project", fixture_unresolved });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.stdout.written(), .{});
    defer parsed.deinit();
    try testing.expectEqual(std.json.Value{ .null = {} }, parsed.value.object.get("project_file").?);
}

// ---------------------------------------------------------------------
// Shared project-flag grammar — Phase 8 item 5.
//
// `check`, `project info|verify|lock|sync`, and `plugin info|check` all
// do project discovery, so they route --project-root / --no-project
// through the same parser as `validate`: both the =-joined and the
// space-separated forms, with a uniform duplicate + mutual-exclusion
// guard. These pin that uniformity (before item 5 each verb hand-rolled
// a different, drifting subset — check had no guard, the project verbs
// dropped --no-project, plugin info dropped --project-root).
// ---------------------------------------------------------------------

test "Cli: check --project-root given twice is a usage error" {
    var out = try invoke(&.{ "sjon", "check", "--project-root=a", "--project-root=b" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "given more than once") != null);
}

test "Cli: check --project-root + --no-project is a usage error" {
    var out = try invoke(&.{ "sjon", "check", "--project-root=x", "--no-project" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "mutually exclusive") != null);
}

test "Cli: check --project-root space form is recognized (rejects a following flag)" {
    var out = try invoke(&.{ "sjon", "check", "--project-root", "--no-project" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "got a flag instead") != null);
}

test "Cli: check --project-root space form matches the =-joined form" {
    // Whatever an explicit root does downstream, the two spellings must
    // agree — pre-fix the space form was rejected as an unknown option.
    var eq = try invoke(&.{ "sjon", "check", "--project-root=/definitely/not/a/project" });
    defer eq.deinit();
    var sp = try invoke(&.{ "sjon", "check", "--project-root", "/definitely/not/a/project" });
    defer sp.deinit();
    try testing.expectEqual(eq.code, sp.code);
    try testing.expectEqualStrings(eq.stderr.written(), sp.stderr.written());
}

test "Cli: project verify --project-root + --no-project is a usage error" {
    var out = try invoke(&.{ "sjon", "project", "verify", "--project-root=x", "--no-project" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "mutually exclusive") != null);
}

test "Cli: project verify --project-root space form is recognized" {
    var out = try invoke(&.{ "sjon", "project", "verify", "--project-root", "--no-project" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "got a flag instead") != null);
}

test "Cli: project sync --project-root + --no-project is a usage error" {
    var out = try invoke(&.{ "sjon", "project", "sync", "--project-root=x", "--no-project" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "mutually exclusive") != null);
}

test "Cli: plugin info --project-root + --no-project is a usage error" {
    var out = try invoke(&.{ "sjon", "plugin", "info", "--project-root=x", "--no-project" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "mutually exclusive") != null);
}

// ---------------------------------------------------------------------
// export-schema
// ---------------------------------------------------------------------

test "Cli: export-schema with no FILE is a usage error" {
    var out = try invoke(&.{ "sjon", "export-schema" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "FILE") != null);
}

test "Cli: export-schema --target=bogus is a usage error" {
    var out = try invoke(&.{ "sjon", "export-schema", "--target=yaml", fixture_clean });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "--target") != null);
}

test "Cli: export-schema --draft=draft-07 rejected (M1 is 2020-12 only)" {
    var out = try invoke(&.{ "sjon", "export-schema", "--draft=draft-07", fixture_clean });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "2020-12") != null);
}

test "Cli: export-schema --target=json-schema on inline fixture emits a 2020-12 schema" {
    var out = try invoke(&.{ "sjon", "export-schema", "--target=json-schema", "--no-project", fixture_clean });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "json-schema.org/draft/2020-12") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "\"$defs\"") != null);
}

test "Cli: export-schema --target=typescript emits the TS prelude" {
    var out = try invoke(&.{ "sjon", "export-schema", "--target=typescript", "--no-project", fixture_clean });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "Keyword<") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "Symbol_<") != null);
}

test "Cli: export-schema --target=both emits the dual envelope" {
    var out = try invoke(&.{ "sjon", "export-schema", "--target=both", "--no-project", fixture_clean });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "\"jsonSchema\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "\"tsTypes\"") != null);
}

// ---------------------------------------------------------------------
// M2 end-to-end coverage — one test per construct, exercising the
// manifest path through the CLI.
// ---------------------------------------------------------------------

const fixture_kit: [:0]const u8 = "examples/plugins/kit/plugin.sjon";
const fixture_kit_xor: [:0]const u8 = "examples/plugins/kit-xor/plugin.sjon";
const fixture_audio: [:0]const u8 = "examples/plugins/audio/plugin.sjon";
const fixture_enum_rich: [:0]const u8 = "examples/plugins/enum-rich/plugin.sjon";

test "Cli: export-schema kit fixture emits allOf if/then chain" {
    var out = try invoke(&.{ "sjon", "export-schema", "--target=json-schema", "--no-project", fixture_kit });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const bytes = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, bytes, "\"allOf\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"$sym\": \"kick\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"$sym\": \"bass\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"unevaluatedProperties\": false") != null);
}

test "Cli: export-schema kit fixture emits discriminated TS union" {
    var out = try invoke(&.{ "sjon", "export-schema", "--target=typescript", "--no-project", fixture_kit });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const bytes = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, bytes, "export type Kit_Track =") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "kind: Symbol_<\"kick\">") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "kind: Symbol_<\"bass\">") != null);
}

test "Cli: export-schema kit-xor fixture emits oneOf and not:{allOf}" {
    var out = try invoke(&.{ "sjon", "export-schema", "--target=json-schema", "--no-project", fixture_kit_xor });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const bytes = out.stdout.written();
    // exactly_one (phrase) → oneOf of required clauses.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"oneOf\"") != null);
    // at_most_one (tag) → not:{allOf}.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"not\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"x-sjon-exclusive-groups\"") != null);
}

test "Cli: export-schema kit-xor fixture emits exclusive-group JSDoc" {
    var out = try invoke(&.{ "sjon", "export-schema", "--target=typescript", "--no-project", fixture_kit_xor });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const bytes = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, bytes, "@sjon-exclusive-group exactly-one [notes, events]") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "@sjon-exclusive-group at-most-one [color, shape]") != null);
}

test "Cli: export-schema audio fixture emits anyOf + oneOf-of-refs" {
    var out = try invoke(&.{ "sjon", "export-schema", "--target=json-schema", "--no-project", fixture_audio });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const bytes = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, bytes, "\"anyOf\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"x-sjon-union-alternatives\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"$ref\": \"#/$defs/form.audio.n\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"$ref\": \"#/$defs/form.audio.rest\"") != null);
}

test "Cli: export-schema enum-rich fixture emits rich-member oneOf" {
    var out = try invoke(&.{ "sjon", "export-schema", "--target=json-schema", "--no-project", fixture_enum_rich });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const bytes = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, bytes, "\"oneOf\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"title\": \"Info\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"deprecated\": true") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"x-sjon-deprecation-message\"") != null);
}

test "Cli: export-schema enum-rich fixture emits @member JSDoc lines" {
    var out = try invoke(&.{ "sjon", "export-schema", "--target=typescript", "--no-project", fixture_enum_rich });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const bytes = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, bytes, "@member info — Info: Routine status") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "@member fatal — Fatal: Unrecoverable") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "@deprecated Use `error` instead") != null);
}

// ---------------------------------------------------------------------
// export-lowering-graph
// ---------------------------------------------------------------------

const fixture_lowering_two_stage: [:0]const u8 = "conformance/cases/lowering-two-stage/document.sjon";
const fixture_lowering_xplugin_cycle: [:0]const u8 = "conformance/cases/lowering-cross-plugin-cycle/document.sjon";

test "Cli: export-lowering-graph with no FILE is a usage error" {
    var out = try invoke(&.{ "sjon", "export-lowering-graph" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "FILE") != null);
}

test "Cli: export-lowering-graph renders the produces-graph as SJON" {
    var out = try invoke(&.{ "sjon", "export-lowering-graph", "--no-project", fixture_lowering_two_stage });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const bytes = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, bytes, "(lowering-graph") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "(node :form \"stage/a\" :produces [\"stage/a-normal\"])") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "(node :form \"stage/a-normal\" :produces [\"stage/a-normal-normal\"])") != null);
}

test "Cli: export-lowering-graph still emits the graph but exits 1 on a cycle" {
    var out = try invoke(&.{ "sjon", "export-lowering-graph", "--no-project", fixture_lowering_xplugin_cycle });
    defer out.deinit();
    // lowering_cycle is err-severity → exit 1, reported on stderr…
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "lowering_cycle") != null);
    // …but the cyclic graph still renders so the cycle is visible.
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "(node :form \"up/task\" :produces [\"down/row\"])") != null);
}

// ---------------------------------------------------------------------
// Slice 4-5 — verb-table + `plugin hash`.
// ---------------------------------------------------------------------

test "Cli: --format=rich is accepted (Slice 4 reservation)" {
    var out = try invoke(&.{ "sjon", "validate", "--format=rich", "--no-project", fixture_clean });
    defer out.deinit();
    // `rich` falls through to `human` until Slice 6 lands — exit code
    // tracks validation outcome, not formatter availability.
    try testing.expectEqual(@as(u8, 0), out.code);
}

test "Cli: --format=rich renders did-you-mean hint for unknown_key" {
    var out = try invoke(&.{
        "sjon",                           "validate",
        "--format=rich",                  "--no-project",
        "examples/unknown-key-typo.sjon",
    });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    const stdout = out.stdout.written();
    // Caret frame on the offending key…
    try testing.expect(std.mem.indexOf(u8, stdout, "(camera :mode ortho :zom 2)") != null);
    try testing.expect(std.mem.indexOf(u8, stdout, "^") != null);
    // …followed by the nearest-key note.
    try testing.expect(std.mem.indexOf(u8, stdout, "note: Did you mean `:zoom`?") != null);
}

test "Cli: rich output suggests a nearby plugin name for unresolved_plugin" {
    // devx plan 01 CP2 — the project index (not the loaded set) is the
    // candidate pool: a typo'd `(use-plugin …)` means the real plugin
    // never loads, but it is still in `sjon-project.sjon`'s index.
    var out = try invoke(&.{
        "sjon",                               "validate",
        "--format=rich",                      "--project-root=examples/hint-plugin-typo",
        "examples/hint-plugin-typo/doc.sjon",
    });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "Did you mean `shapes`?") != null);
}

test "Cli: rich output emits no suggestion when no plugin name is near" {
    var out = try invoke(&.{
        "sjon",                                   "validate",
        "--format=rich",                          "--project-root=examples/hint-plugin-typo",
        "examples/hint-plugin-typo/doc-far.sjon",
    });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "Did you mean") == null);
}

// The `uniforms` example (examples/plugins/uniforms/) — the provider
// cross-ref route executing for real, against the committed
// `plugin.wasm`. These three are the example's rot gate: they pin the
// resolve / miss / poison behaviors its header comments claim. They
// skip on a `-Dplugin-exec=false` build, where the same documents
// report `cross_ref_provider_unavailable` instead of extracting.
test "Cli: uniforms example resolves provider-extracted names" {
    if (!build_options.plugin_exec) return error.SkipZigTest;
    var out = try invoke(&.{
        "sjon",                                     "validate",
        "--project-root=examples/plugins/uniforms", "examples/plugins/uniforms/scene.sjon",
    });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
}

test "Cli: uniforms example reports a typo'd reference as not_cross_ref naming :src" {
    if (!build_options.plugin_exec) return error.SkipZigTest;
    var out = try invoke(&.{
        "sjon",                                     "validate",
        "--project-root=examples/plugins/uniforms", "examples/plugins/uniforms/scene-typo.sjon",
    });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    const text = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, text, "not_cross_ref") != null);
    // The provider-route message points at the source string, not at a
    // `:name-key` — that redirect is the repair route and the reason the
    // example exists.
    try testing.expect(std.mem.indexOf(u8, text, "(uniforms/shader :src") != null);
}

test "Cli: uniforms example poisons the bucket on a refused source" {
    if (!build_options.plugin_exec) return error.SkipZigTest;
    var out = try invoke(&.{
        "sjon",                                     "validate",
        "--project-root=examples/plugins/uniforms", "examples/plugins/uniforms/scene-malformed.sjon",
    });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    const text = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, text, "cross_ref_extraction_failed") != null);
    // Exactly one diagnostic: the resolvable and unresolvable binds into
    // the poisoned bucket both stay silent (unchecked, not accepted or
    // rejected).
    try testing.expect(std.mem.indexOf(u8, text, "not_cross_ref") == null);
    try testing.expect(std.mem.indexOf(u8, text, "1 error") != null);
}

test "Cli: --color=auto is accepted (Slice 4 reservation)" {
    var out = try invoke(&.{ "sjon", "validate", "--color=auto", "--no-project", fixture_clean });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
}

test "Cli: --color=bogus is a usage error" {
    var out = try invoke(&.{ "sjon", "validate", "--color=neon", "--no-project", fixture_clean });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "color") != null);
}

test "Cli: plugin hash on examples/plugins/double/plugin.wasm prints sha256" {
    var out = try invoke(&.{ "sjon", "plugin", "hash", "examples/plugins/double/plugin.wasm" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const bytes = out.stdout.written();
    try testing.expect(std.mem.startsWith(u8, bytes, "sha256-"));
    // 64 hex chars + the `sha256-` prefix + trailing newline = 72 bytes.
    try testing.expectEqual(@as(usize, 72), bytes.len);
}

test "Cli: plugin hash on examples/plugins/double/plugin.sjon resolves paired wasm" {
    var out = try invoke(&.{ "sjon", "plugin", "hash", "examples/plugins/double/plugin.sjon" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expect(std.mem.startsWith(u8, out.stdout.written(), "sha256-"));
}

test "Cli: plugin hash --format=json emits structured envelope" {
    var out = try invoke(&.{ "sjon", "plugin", "hash", "--format=json", "examples/plugins/double/plugin.wasm" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const bytes = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, bytes, "\"sha256\":") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"bytes\":") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"path\":") != null);
}

test "Cli: plugin hash --format=json survives a quote in the path" {
    // `path` is argv, spliced raw into hand-rolled JSON. A `"` — or the
    // realistic case, a Windows path's backslashes — produced a document
    // no parser accepts, from the one format whose purpose is parsing.
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "we\"ird.wasm", .data = "\x00asm\x01\x00\x00\x00" });
    const path = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/we\"ird.wasm", .{&tmp.sub_path}, 0);
    defer a.free(path);

    var out = try invoke(&.{ "sjon", "plugin", "hash", "--format=json", path });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);

    // The real check: a JSON parser accepts it and reads the path back.
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out.stdout.written(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(path, parsed.value.object.get("path").?.string);
    try testing.expect(parsed.value.object.get("sha256") != null);
}

test "Cli: plugin check --format=json carries the diagnostics behind its exit code" {
    // `plugin check --format=json` exited 1 with no machine-readable
    // reason: the diagnostics that decided the exit code were in no
    // field, so the machine format said strictly less than the human one.
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "plugin.sjon",
        .data =
        \\(plugin :name demo :version "1.0.0" :license "Not-A-Real-License"
        \\  (form :name box (key :name w :type number)))
        \\
        ,
    });
    const path = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/plugin.sjon", .{&tmp.sub_path}, 0);
    defer a.free(path);

    var out = try invoke(&.{ "sjon", "plugin", "check", "--format=json", path });
    defer out.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, a, out.stdout.written(), .{});
    defer parsed.deinit();
    const diags = parsed.value.object.get("diagnostics").?.array;
    try testing.expect(diags.items.len > 0);
    try testing.expect(diags.items[0].object.get("code") != null);
    try testing.expect(diags.items[0].object.get("severity") != null);
    try testing.expect(diags.items[0].object.get("message") != null);
}

test "Cli: plugin (no subcommand) is a usage error" {
    var out = try invoke(&.{ "sjon", "plugin" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "subcommand") != null);
}

test "Cli: unknown plugin subcommand is a usage error" {
    var out = try invoke(&.{ "sjon", "plugin", "stomp" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
}

// ---------------------------------------------------------------------
// Completions — `sjon completions {bash|zsh|fish}`.
// ---------------------------------------------------------------------

test "Cli: completions with no shell is a usage error" {
    var out = try invoke(&.{ "sjon", "completions" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "shell") != null);
}

test "Cli: completions with an unknown shell is a usage error" {
    var out = try invoke(&.{ "sjon", "completions", "powershell" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "bash | zsh | fish") != null);
}

test "Cli: completions drift guard — every verb/sub/flag appears in each script" {
    const shells = [_][:0]const u8{ "bash", "zsh", "fish" };
    for (shells) |shell| {
        var out = try invoke(&.{ "sjon", "completions", shell });
        defer out.deinit();
        try testing.expectEqual(@as(u8, 0), out.code);
        try testing.expectEqual(@as(usize, 0), out.stderr.written().len);
        const script = out.stdout.written();

        for (Cli.top_level_verbs) |v|
            try testing.expect(std.mem.indexOf(u8, script, v) != null);
        for (Cli.plugin_subcommands) |s|
            try testing.expect(std.mem.indexOf(u8, script, s) != null);
        for (Cli.project_subcommands) |s|
            try testing.expect(std.mem.indexOf(u8, script, s) != null);
        // Flags render per-shell (`--format=` in bash/zsh, fish `-l format`),
        // so assert the bare name (sans leading `-` and trailing `=`) appears.
        for (Cli.common_flags) |flag| {
            var bare = flag;
            while (std.mem.startsWith(u8, bare, "-")) bare = bare[1..];
            if (std.mem.endsWith(u8, bare, "=")) bare = bare[0 .. bare.len - 1];
            try testing.expect(std.mem.indexOf(u8, script, bare) != null);
        }
    }
}

test "Cli: usage truth — help + completions advertise rich, --color, exit code 3" {
    // Drift guard for the human-facing tables: every real flag value and
    // reachable exit code must be documented, and completable flags must
    // be listed. Catches usage_text / common_flags falling behind the
    // parser (--format gained `rich`; --color= is a validate flag; exit
    // code 3 is internal_error).
    var out = try invoke(&.{ "sjon", "--help" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const help = out.stdout.written();

    // --format accepts rich (SnippetRenderer output), not just human|json.
    try testing.expect(std.mem.indexOf(u8, help, "rich") != null);
    // --color= is a real (validate) flag — documented and completable.
    try testing.expect(std.mem.indexOf(u8, help, "--color=") != null);
    var color_completable = false;
    for (Cli.common_flags) |flag| {
        if (std.mem.eql(u8, flag, "--color=")) color_completable = true;
    }
    try testing.expect(color_completable);
    // Exit code 3 (internal_error) is reachable and must be listed.
    try testing.expect(std.mem.indexOf(u8, help, "  3  ") != null);
}

test "Cli: nothing escapes main — every error is mapped to an exit code" {
    // `main` returns a bare `u8`, not `!u8`. That is the type-level
    // statement that no error reaches the Zig runtime, which dumps a
    // stack trace and exits **1** — indistinguishable from "this document
    // has validation errors". The usage text has promised a distinct
    // exit 3 for internal failures all along; before this, a propagated
    // OOM produced exit 1 and a trace. Re-adding a `try` at that level
    // changes the return type and fails this compile.
    const cli_main = @import("main.zig");
    const info = @typeInfo(@TypeOf(cli_main.main)).@"fn";
    try testing.expectEqual(u8, info.return_type.?);
}

test "Cli: out of memory while collecting argv exits 3, not 2" {
    // Collecting a variadic positional list is the one place argument
    // parsing can fail for a reason the user cannot fix by editing their
    // argv. It used to return `usage_error`, which printed the whole
    // usage text and exited 2 — telling the user to correct a command
    // line that was already correct.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const a = failing.allocator();
    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr.deinit();
    const code = try Cli.run(
        a,
        testing.io,
        &.{ "sjon", "fmt", "a.sjon", "b.sjon" },
        &stdout.writer,
        &stderr.writer,
        .{},
    );
    try testing.expectEqual(@as(u8, 3), code);
    try testing.expect(std.mem.indexOf(u8, stderr.written(), "internal error") != null);
    // ...and it must NOT dump the usage text at the user.
    try testing.expect(std.mem.indexOf(u8, stderr.written(), "Usage:") == null);
}

test "Cli: export-schema names the path it could not write, exit 3" {
    // The `--output` write path propagated its raw `Io` error, which named
    // neither the file nor the verb. `runFmt` already reported its own
    // write failures this way; the two verbs now agree.
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A regular file where the output *directory* must go: createDirPath
    // cannot succeed, and the failure is the OS's, not a fabricated one.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blocker", .data = "" });
    const out_arg = try std.fmt.allocPrintSentinel(
        a,
        "--output=.zig-cache/tmp/{s}/blocker/nested",
        .{&tmp.sub_path},
        0,
    );
    defer a.free(out_arg);

    var out = try invoke(&.{ "sjon", "export-schema", "--no-project", out_arg, fixture_clean });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 3), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "cannot create") != null);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "blocker/nested") != null);
}

test "Cli: completions bash emits a sourceable function" {
    var out = try invoke(&.{ "sjon", "completions", "bash" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const s = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, s, "_sjon()") != null);
    try testing.expect(std.mem.indexOf(u8, s, "complete -F _sjon sjon") != null);
}

test "Cli: completions zsh emits a #compdef header" {
    var out = try invoke(&.{ "sjon", "completions", "zsh" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expect(std.mem.startsWith(u8, out.stdout.written(), "#compdef sjon"));
}

test "Cli: completions fish emits `complete -c sjon` lines" {
    var out = try invoke(&.{ "sjon", "completions", "fish" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "complete -c sjon") != null);
}

test "Cli: every verb the usage text advertises is in the completion table" {
    // The two existing guards both run table → elsewhere: every entry
    // reaches each script, every entry parses. Neither could see a verb
    // that exists in the dispatcher and the help text but is *missing*
    // from the table — which is how `repl` and `share` went unlisted, so
    // shell completion never offered either, despite the table's own doc
    // comment calling itself the single source of truth. This guard runs
    // the other way: help text → table.
    var out = try invoke(&.{ "sjon", "--help" });
    defer out.deinit();
    var lines = std.mem.splitScalar(u8, out.stdout.written(), '\n');
    var checked: usize = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (!std.mem.startsWith(u8, trimmed, "sjon ")) continue;
        var words = std.mem.tokenizeScalar(u8, trimmed["sjon ".len..], ' ');
        const word = words.next() orelse continue;
        // `--help` is not a verb; `[check]` marks the default verb, whose
        // brackets are presentation.
        if (std.mem.startsWith(u8, word, "-")) continue;
        const verb = std.mem.trim(u8, word, "[]");
        var listed = false;
        for (Cli.top_level_verbs) |v| {
            if (std.mem.eql(u8, v, verb)) listed = true;
        }
        if (!listed) {
            std.debug.print(
                "usage text advertises `sjon {s}` but top_level_verbs does not list it\n",
                .{verb},
            );
            return error.TestUnexpectedResult;
        }
        checked += 1;
    }
    // Guard the guard: a help text that stopped matching the line shape
    // would pass vacuously.
    try testing.expect(checked >= Cli.top_level_verbs.len);
}

test "Cli: every top_level_verb is recognised by the dispatcher" {
    // Ties the completion table to parseArgs: a verb advertised in
    // completions must never fall through to the unknown-command branch.
    const a = testing.allocator;
    for (Cli.top_level_verbs) |verb| {
        // `sjon repl` with no argument reads the process's stdin, which
        // under the test runner never ends — running it here would hang
        // the suite rather than fail it. Its dispatch is covered by the
        // `runCliWithStdin` repl tests, which feed it a real transcript.
        if (std.mem.eql(u8, verb, "repl")) continue;
        const v = try a.dupeZ(u8, verb);
        defer a.free(v);
        var out = try invoke(&.{ "sjon", v });
        defer out.deinit();
        try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "unknown command") == null);
    }
}

// ---------------------------------------------------------------------
// Slice 8 — `sjon explain CODE`.
// ---------------------------------------------------------------------

test "Cli: explain unresolved_plugin prints short + long body" {
    var out = try invoke(&.{ "sjon", "explain", "unresolved_plugin" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const bytes = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, bytes, "unresolved_plugin") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "(use-plugin") != null);
}

test "Cli: explain --list emits every code" {
    var out = try invoke(&.{ "sjon", "explain", "--list" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const bytes = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, bytes, "unspecified") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "unresolved_plugin") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "pin_disagreement") != null);
}

test "Cli: explain unknown code is a usage error" {
    var out = try invoke(&.{ "sjon", "explain", "bogus_code_name" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "bogus_code_name") != null);
}

test "Cli: explain --format=json emits structured envelope" {
    var out = try invoke(&.{ "sjon", "explain", "--format=json", "unresolved_plugin" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const bytes = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, bytes, "\"code\":\"unresolved_plugin\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"short\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"long\"") != null);
}

test "Cli: explain prints the code's documentation url" {
    // devx plan 01 CP3 (D1) — the catalogue page URL closes the entry,
    // as the last line of output.
    var out = try invoke(&.{ "sjon", "explain", "unresolved_plugin" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const bytes = out.stdout.written();
    const url = "https://hugodaniel.com/pages/sjon/errors/unresolved_plugin";
    const idx = std.mem.indexOf(u8, bytes, url) orelse return error.MissingDocsUrl;
    try testing.expectEqualStrings(url ++ "\n", bytes[idx..]);
}

test "Cli: explain --list stays URL-free" {
    // One URL per row would be pure noise across the whole catalogue.
    var out = try invoke(&.{ "sjon", "explain", "--list" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "https://") == null);
}

test "Cli: rich help footer carries the documentation url" {
    var out = try invoke(&.{ "sjon", "validate", "--format=rich", "--no-project", fixture_data_error });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(
        u8,
        out.stdout.written(),
        "help: https://hugodaniel.com/pages/sjon/errors/missing_required_key",
    ) != null);
}

// ---------------------------------------------------------------------
// Slice 9 — `plugin info`, `plugin check`.
// ---------------------------------------------------------------------

test "Cli: plugin info on double prints summary" {
    var out = try invoke(&.{ "sjon", "plugin", "info", "examples/plugins/double/plugin.sjon" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const bytes = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, bytes, "plugin    double") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "expr-funcs") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "wasm") != null);
}

test "Cli: plugin info --format=json emits JSON envelope" {
    var out = try invoke(&.{ "sjon", "plugin", "info", "--format=json", "examples/plugins/double/plugin.sjon" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const bytes = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, bytes, "\"name\":\"double\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"expr_funcs\":1") != null);
}

test "Cli: plugin check passes on valid manifest" {
    var out = try invoke(&.{ "sjon", "plugin", "check", "examples/plugins/double/plugin.sjon" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
}

test "Cli: plugin check rejects malformed manifest" {
    // Reuse a known-broken conformance fixture (the manifest-error one).
    var out = try invoke(&.{ "sjon", "plugin", "check", "examples/plugins/double/example.sjon" });
    defer out.deinit();
    // The double example file is a data document, not a (plugin …)
    // — `check` should refuse it with non-zero exit.
    try testing.expect(out.code != 0);
}

// ---------------------------------------------------------------------
// `sjon plugin init NAME` — manifest scaffold.
// ---------------------------------------------------------------------

test "Cli: plugin init --stdout prints a parseable scaffold" {
    var out = try invoke(&.{ "sjon", "plugin", "init", "demo", "--stdout" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const s = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, s, "(plugin :name demo :version \"1.0.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "(form :name example") != null);
    try testing.expect(std.mem.indexOf(u8, s, "(key :name title :type string)") != null);
}

test "Cli: plugin init without NAME is a usage error" {
    var out = try invoke(&.{ "sjon", "plugin", "init" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "NAME") != null);
}

test "Cli: plugin init rejects a non-symbol NAME" {
    var out = try invoke(&.{ "sjon", "plugin", "init", "not a symbol" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "bare symbol") != null);
}

test "Cli: plugin init writes a manifest that `plugin check` accepts" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer a.free(root);

    const out_arg = try std.fmt.allocPrintSentinel(a, "--output={s}/plugin.sjon", .{root}, 0);
    defer a.free(out_arg);

    var made = try invoke(&.{ "sjon", "plugin", "init", "demo", out_arg });
    defer made.deinit();
    try testing.expectEqual(@as(u8, 0), made.code);
    try testing.expect(std.mem.indexOf(u8, made.stdout.written(), "created") != null);

    // The scaffold must be a valid manifest — `plugin check` gates on it.
    const check_path = try std.fmt.allocPrintSentinel(a, "{s}/plugin.sjon", .{root}, 0);
    defer a.free(check_path);
    var chk = try invoke(&.{ "sjon", "plugin", "check", check_path });
    defer chk.deinit();
    try testing.expectEqual(@as(u8, 0), chk.code);
    try testing.expect(std.mem.indexOf(u8, chk.stdout.written(), "plugin    demo") != null);
}

test "Cli: plugin init refuses to overwrite without --force, then obeys it" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plugin.sjon", .data = "; pre-existing\n" });
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer a.free(root);
    const out_arg = try std.fmt.allocPrintSentinel(a, "--output={s}/plugin.sjon", .{root}, 0);
    defer a.free(out_arg);

    var refused = try invoke(&.{ "sjon", "plugin", "init", "demo", out_arg });
    defer refused.deinit();
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(std.mem.indexOf(u8, refused.stderr.written(), "already exists") != null);

    var forced = try invoke(&.{ "sjon", "plugin", "init", "demo", out_arg, "--force" });
    defer forced.deinit();
    try testing.expectEqual(@as(u8, 0), forced.code);
}

// ---------------------------------------------------------------------
// Slice 10 — `sjon project info|verify`.
// ---------------------------------------------------------------------

test "Cli: project info reports `no project file` when none found" {
    var out = try invoke(&.{ "sjon", "project", "info" });
    defer out.deinit();
    // Whether or not a project file exists in cwd ancestry, the
    // command must respond — either with the project summary
    // (exit 0) or the not-found error (exit 1). The point of this
    // test is just to drive the dispatch.
    try testing.expect(out.code == 0 or out.code == 1);
}

test "Cli: project (no subcommand) is a usage error" {
    var out = try invoke(&.{ "sjon", "project" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "subcommand") != null);
}

// ---------------------------------------------------------------------
// `sjon project sync` — reconcile the lockfile (write only if changed).
// All write cases run against a tmpDir project so the repo is never
// mutated.
// ---------------------------------------------------------------------

/// Stand up a self-contained one-plugin project under a tmpDir and
/// return `(root_rel, root_arg)` where root_rel is the cwd-relative
/// project root and root_arg is the `--project-root=…` argv token.
fn syncFixture(a: std.mem.Allocator, tmp: *std.testing.TmpDir) !struct { root: []u8, arg: [:0]u8 } {
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "demo.sjon",
        .data = "(plugin :name demo :version \"1.0.0\" (form :name example (key :name title :type string)))",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "(project :plugins [\"demo.sjon\"])",
    });
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const arg = try std.fmt.allocPrintSentinel(a, "--project-root={s}", .{root}, 0);
    return .{ .root = root, .arg = arg };
}

// ---------------------------------------------------------------------
// `sjon project verify` — the lockfile-integrity reporting paths.
//
// This is the CLI's supply-chain feature: it is what answers "are the
// plugins on disk the ones this project was locked against?". Every
// branch below (drift, missing entry, orphan, corrupt, unsupported
// version) had zero coverage — `Cli_tests` touched "verify" only for
// flag-usage errors, and `Cli.zig` is the lowest-covered non-wasm
// module. Each case starts from a real lockfile written by the CLI
// itself, then breaks exactly one thing.
// ---------------------------------------------------------------------

const VerifyCase = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    arg: [:0]u8,

    fn init(a: std.mem.Allocator) !VerifyCase {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const fx = try syncFixture(a, &tmp);
        errdefer a.free(fx.root);
        errdefer a.free(fx.arg);
        // The lockfile is generated, never hand-written: a fixture that
        // hard-codes hashes stops testing the hashes.
        var out = try invoke(&.{ "sjon", "project", "lock", fx.arg });
        defer out.deinit();
        try testing.expectEqual(@as(u8, 0), out.code);
        return .{ .tmp = tmp, .root = fx.root, .arg = fx.arg };
    }

    fn deinit(self: *VerifyCase, a: std.mem.Allocator) void {
        a.free(self.root);
        a.free(self.arg);
        self.tmp.cleanup();
    }

    fn verify(self: *VerifyCase) !Captured {
        return invoke(&.{ "sjon", "project", "verify", self.arg });
    }

    fn write(self: *VerifyCase, name: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
    }

    fn readLockfile(self: *VerifyCase, a: std.mem.Allocator) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, "sjon-project.lock", a, .unlimited);
    }
};

test "Cli: project verify passes against the lockfile it just wrote" {
    // The baseline every case below deviates from. Without it, a broken
    // fixture would make all of them "pass" by failing for the wrong
    // reason.
    const a = testing.allocator;
    var c = try VerifyCase.init(a);
    defer c.deinit(a);

    var out = try c.verify();
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "ok  demo") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "lockfile_") == null);
}

test "Cli: project verify reports lockfile_drift when a manifest changed" {
    // The whole point of the feature: the bytes on disk are no longer the
    // bytes that were locked.
    const a = testing.allocator;
    var c = try VerifyCase.init(a);
    defer c.deinit(a);
    try c.write(
        "demo.sjon",
        "(plugin :name demo :version \"1.0.1\" (form :name example (key :name title :type string)))",
    );

    var out = try c.verify();
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "lockfile_drift on manifest") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "1 error(s)") != null);
}

test "Cli: project verify reports lockfile_missing_entry for an unlocked plugin" {
    const a = testing.allocator;
    var c = try VerifyCase.init(a);
    defer c.deinit(a);
    // A plugin added to the project after the lock was taken.
    try c.write(
        "extra.sjon",
        "(plugin :name extra :version \"1.0.0\" (form :name thing (key :name n :type number)))",
    );
    try c.write("sjon-project.sjon", "(project :plugins [\"demo.sjon\" \"extra.sjon\"])");

    var out = try c.verify();
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "lockfile_missing_entry") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "extra") != null);
    // The still-locked plugin must remain clean — one new plugin must not
    // invalidate the rest of the report.
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "ok  demo") != null);
}

test "Cli: project verify warns lockfile_orphan without failing the build" {
    // A dropped plugin leaves a stale entry. That is untidy, not unsafe:
    // nothing on disk contradicts the lock, so it warns and exits 0.
    const a = testing.allocator;
    var c = try VerifyCase.init(a);
    defer c.deinit(a);
    try c.write("sjon-project.sjon", "(project :plugins [])");

    var out = try c.verify();
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "lockfile_orphan") != null);
}

test "Cli: project verify reports lockfile_corrupt on unparseable bytes" {
    const a = testing.allocator;
    var c = try VerifyCase.init(a);
    defer c.deinit(a);
    try c.write("sjon-project.lock", "this is not a lockfile {{{\n");

    var out = try c.verify();
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "lockfile_corrupt") != null);
}

test "Cli: project verify reports lockfile_version_unsupported" {
    // A lockfile from a newer SJON. Refusing is the only safe answer: the
    // host cannot know what the fields it does not recognise constrain.
    const a = testing.allocator;
    var c = try VerifyCase.init(a);
    defer c.deinit(a);
    const bytes = try c.readLockfile(a);
    defer a.free(bytes);
    const bumped = try std.mem.replaceOwned(u8, a, bytes, ":version 1", ":version 99");
    defer a.free(bumped);
    try testing.expect(!std.mem.eql(u8, bytes, bumped));
    try c.write("sjon-project.lock", bumped);

    var out = try c.verify();
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "lockfile_version_unsupported") != null);
}

test "Cli: project sync creates, is idempotent, and --check tracks drift" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fx = try syncFixture(a, &tmp);
    defer a.free(fx.root);
    defer a.free(fx.arg);

    // --check before any lockfile exists → out of date, exit 1, no write.
    {
        var out = try invoke(&.{ "sjon", "project", "sync", fx.arg, "--check" });
        defer out.deinit();
        try testing.expectEqual(@as(u8, 1), out.code);
        try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "out of date") != null);
    }

    // First sync creates the lockfile (demo is "added"), exit 0.
    {
        var out = try invoke(&.{ "sjon", "project", "sync", fx.arg });
        defer out.deinit();
        try testing.expectEqual(@as(u8, 0), out.code);
        try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "+ demo") != null);
        try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "wrote") != null);
    }

    // The written lockfile is well-formed and records the plugin.
    const lock_path = try std.fmt.allocPrint(a, "{s}/sjon-project.lock", .{fx.root});
    defer a.free(lock_path);
    const lock_bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, lock_path, a, .unlimited);
    defer a.free(lock_bytes);
    try testing.expect(std.mem.indexOf(u8, lock_bytes, "(lockfile :version 1") != null);
    try testing.expect(std.mem.indexOf(u8, lock_bytes, "demo") != null);

    // Second sync is a no-op: up to date, no rewrite.
    {
        var out = try invoke(&.{ "sjon", "project", "sync", fx.arg });
        defer out.deinit();
        try testing.expectEqual(@as(u8, 0), out.code);
        try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "up to date") != null);
    }

    // And --check on the reconciled tree exits 0.
    {
        var out = try invoke(&.{ "sjon", "project", "sync", fx.arg, "--check" });
        defer out.deinit();
        try testing.expectEqual(@as(u8, 0), out.code);
        try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "up to date") != null);
    }
}

test "Cli: project sync --format=json emits the reconcile envelope" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fx = try syncFixture(a, &tmp);
    defer a.free(fx.root);
    defer a.free(fx.arg);

    var out = try invoke(&.{ "sjon", "project", "sync", fx.arg, "--format=json" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, out.stdout.written(), .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const added = obj.get("added").?.array;
    try testing.expectEqual(@as(usize, 1), added.items.len);
    try testing.expectEqualStrings("demo", added.items[0].string);
    try testing.expectEqual(true, obj.get("wrote").?.bool);
    try testing.expect(std.mem.endsWith(u8, obj.get("path").?.string, "sjon-project.lock"));
}

// ---------------------------------------------------------------------
// Color policy resolution — exercised through the CLI's observable
// behavior (`--color=always|never|auto` + RunEnv), since the resolver
// (`Cli.resolveColor`) is private.
// ---------------------------------------------------------------------

fn invokeEnv(args: []const [:0]const u8, env: Cli.RunEnv) !Captured {
    const a = testing.allocator;
    var stdout: std.Io.Writer.Allocating = .init(a);
    errdefer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(a);
    errdefer stderr.deinit();
    const code = try Cli.run(a, testing.io, args, &stdout.writer, &stderr.writer, env);
    return .{ .code = code, .stdout = stdout, .stderr = stderr };
}

test "Cli: --color=always emits ANSI escapes even without TTY" {
    var out = try invokeEnv(&.{ "sjon", "validate", "--color=always", "--format=rich", "--no-project", fixture_data_error }, .{
        .stdout_is_tty = false,
    });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "\x1b[") != null);
}

test "Cli: rich piped without --color renders the frame ANSI-free" {
    var out = try invokeEnv(&.{ "sjon", "validate", "--format=rich", "--no-project", fixture_data_error }, .{
        .stdout_is_tty = false,
    });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    // Rich structure without color: `--color=auto` off a TTY.
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "[missing_required_key]") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "\x1b") == null);
}

test "Cli: NO_COLOR and SJON_NO_COLOR strip ANSI on a TTY; a bare TTY keeps it" {
    var colored = try invokeEnv(&.{ "sjon", "validate", "--no-project", fixture_data_error }, .{
        .stdout_is_tty = true,
    });
    defer colored.deinit();
    try testing.expectEqual(@as(u8, 1), colored.code);
    try testing.expect(std.mem.indexOf(u8, colored.stdout.written(), "\x1b[") != null);

    var no_color = try invokeEnv(&.{ "sjon", "validate", "--no-project", fixture_data_error }, .{
        .stdout_is_tty = true,
        .no_color = true,
    });
    defer no_color.deinit();
    try testing.expectEqual(@as(u8, 1), no_color.code);
    try testing.expect(std.mem.indexOf(u8, no_color.stdout.written(), "\x1b") == null);

    var sjon_no_color = try invokeEnv(&.{ "sjon", "validate", "--no-project", fixture_data_error }, .{
        .stdout_is_tty = true,
        .sjon_no_color = true,
    });
    defer sjon_no_color.deinit();
    try testing.expect(std.mem.indexOf(u8, sjon_no_color.stdout.written(), "\x1b") == null);
}

test "Cli: repeated --color is last-wins" {
    var out = try invokeEnv(&.{ "sjon", "validate", "--color=never", "--color=always", "--format=rich", "--no-project", fixture_data_error }, .{});
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "\x1b[") != null);
}

// ---------------------------------------------------------------------
// Format policy resolution (devx plan 01 CP1) — `--format` defaults to
// `auto`: rich when stdout is a TTY, the byte-stable human format when
// piped. Explicit values always win, mirroring `--color`.
// ---------------------------------------------------------------------

test "Cli: default format is rich when stdout is a tty" {
    var out = try invokeEnv(&.{ "sjon", "validate", "--no-project", fixture_data_error }, .{
        .stdout_is_tty = true,
    });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    // Rich brackets the code (`error[<code>]: …`) and draws a caret
    // frame. A TTY also enables color, so ANSI escapes sit between
    // `error` and `[` — assert on the bracketed code, not `error[`.
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "[missing_required_key]") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "^") != null);
}

test "Cli: default format is human when stdout is piped" {
    var out = try invokeEnv(&.{ "sjon", "validate", "--no-project", fixture_data_error }, .{
        .stdout_is_tty = false,
    });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    // GCC-style FILE:LINE:COL lines, no rich bracketed code — pipes
    // stay byte-stable for grep/awk consumers.
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "[missing_required_key]") == null);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "missing_required_key") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), fixture_data_error) != null);
}

test "Cli: explicit --format=human wins on a tty" {
    var out = try invokeEnv(&.{ "sjon", "validate", "--format=human", "--no-project", fixture_data_error }, .{
        .stdout_is_tty = true,
    });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "[missing_required_key]") == null);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "missing_required_key") != null);
}

test "Cli: explicit --format=rich wins when piped" {
    var out = try invokeEnv(&.{ "sjon", "validate", "--format=rich", "--no-project", fixture_data_error }, .{
        .stdout_is_tty = false,
    });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "[missing_required_key]") != null);
}

// ---------------------------------------------------------------------
// `sjon fmt` — F4. Formats in place over `Printer` in `.full` mode, so
// comments survive; `--check` reports without writing. Every write case
// runs against a tmpDir so the repo is never mutated.
//
// Printer idempotence itself is pinned at the printer layer (see
// `Printer.zig`'s "lossless print is idempotent through reparse"); the
// idempotence case here is the end-to-end confirmation that the verb
// inherits it, not a second copy of that coverage.
// ---------------------------------------------------------------------

/// Write `data` into a tmpDir and return the cwd-relative path to it,
/// as a sentinel-terminated argv token. Caller frees.
fn fmtFixture(
    a: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    name: []const u8,
    data: []const u8,
) ![:0]u8 {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
    return std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, name }, 0);
}

fn readBack(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .unlimited);
}

test "Cli: fmt rewrites an unformatted file in place" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Ragged spacing plus a comment: the comment must survive (`.full`
    // mode), which is what distinguishes fmt from a canonical reprint.
    const path = try fmtFixture(a, &tmp, "doc.sjon", "; keep me\n(scene    :name    \"main\"   )\n");
    defer a.free(path);

    var out = try invoke(&.{ "sjon", "fmt", path });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);

    const after = try readBack(a, path);
    defer a.free(after);
    try testing.expectEqualStrings("; keep me\n(scene :name \"main\")\n", after);
}

test "Cli: fmt is idempotent" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fmtFixture(a, &tmp, "doc.sjon", "(scene    :name \"main\")\n");
    defer a.free(path);

    var first = try invoke(&.{ "sjon", "fmt", path });
    defer first.deinit();
    try testing.expectEqual(@as(u8, 0), first.code);
    const once = try readBack(a, path);
    defer a.free(once);

    var second = try invoke(&.{ "sjon", "fmt", path });
    defer second.deinit();
    try testing.expectEqual(@as(u8, 0), second.code);
    const twice = try readBack(a, path);
    defer a.free(twice);

    try testing.expectEqualStrings(once, twice);

    // A freshly-formatted document is `--check`-clean: the two verbs
    // agree on what "formatted" means.
    var checked = try invoke(&.{ "sjon", "fmt", "--check", path });
    defer checked.deinit();
    try testing.expectEqual(@as(u8, 0), checked.code);
}

test "Cli: fmt --check on a dirty file exits non-zero and does not write" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = "(scene    :name \"main\")\n";
    const path = try fmtFixture(a, &tmp, "doc.sjon", original);
    defer a.free(path);

    var out = try invoke(&.{ "sjon", "fmt", "--check", path });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "doc.sjon") != null);

    const after = try readBack(a, path);
    defer a.free(after);
    try testing.expectEqualStrings(original, after);
}

test "Cli: fmt --check on a clean file exits zero" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fmtFixture(a, &tmp, "doc.sjon", "(scene :name \"main\")\n");
    defer a.free(path);

    var out = try invoke(&.{ "sjon", "fmt", "--check", path });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
}

test "Cli: fmt on a parse-error file leaves it untouched and reports diagnostics" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Unbalanced paren — the parser recovers into a partial tree, but a
    // partial tree must never be printed back over the user's source.
    // Same decline policy as the LSP's `getFormatEdits`.
    const original = "(scene :name \"main\"\n";
    const path = try fmtFixture(a, &tmp, "broken.sjon", original);
    defer a.free(path);

    var out = try invoke(&.{ "sjon", "fmt", path });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);

    const after = try readBack(a, path);
    defer a.free(after);
    try testing.expectEqualStrings(original, after);

    // Assert on the *parse* diagnostic specifically. Before `fmt`
    // existed this case still exited 1 — `sjon fmt FILE` fell through
    // to implicit-check, which failed for want of a project file. Exit
    // code alone therefore proves nothing; the reported diagnostic is
    // what distinguishes fmt's decline from that fallthrough.
    //
    // On stderr, not stdout: fmt keeps stdout a data channel so
    // `sjon fmt -` can pipe. Unlike `validate`, which has no such
    // constraint and prints diagnostics to stdout.
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "unclosed delimiter") != null);
    try testing.expectEqual(@as(usize, 0), out.stdout.written().len);
    // And nothing beyond parsing: fmt is purely syntactic, so the
    // validator's `unknown_form` for `scene` must not appear.
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "unknown_form") == null);
}

test "Cli: fmt formats multiple paths, reporting per-file" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dirty = try fmtFixture(a, &tmp, "dirty.sjon", "(scene    :name \"a\")\n");
    defer a.free(dirty);
    const clean = try fmtFixture(a, &tmp, "clean.sjon", "(scene :name \"b\")\n");
    defer a.free(clean);

    var out = try invoke(&.{ "sjon", "fmt", dirty, clean });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);

    // Only the file that changed is reported — a formatter that names
    // every file it read is noise in a repo-wide run.
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "dirty.sjon") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "clean.sjon") == null);

    const after = try readBack(a, dirty);
    defer a.free(after);
    try testing.expectEqualStrings("(scene :name \"a\")\n", after);
}

// ---------------------------------------------------------------------
// `sjon fmt -` — stdin→stdout.
//
// These two spawn the built binary instead of calling `Cli.run`, the
// only tests in this file that do. The header explains why the
// in-process harness cannot reach stdin: `loadSource` reads
// `Io.File.stdin()` (fd 0), and `Cli.run`'s seam offers no way to
// substitute it. That left `sjon validate -` verified by hand; driving
// a real process is what makes the equivalent fmt path verified by CI
// instead.
//
// `zig build test` depends on `install_cli`, so the binary is always
// present there; the skip is for a bare `zig test` on this file.
// ---------------------------------------------------------------------

const cli_bin = "zig-out/bin/sjon";

/// Run the built CLI with `stdin_bytes` on its standard input, and
/// return its exit code plus captured streams.
///
/// Goes through `sh -c '… < file'` rather than `process.spawn` with a
/// stdin pipe: `process.run` hard-codes `.stdin = .ignore`, and feeding
/// a pipe by hand means reading stdout and stderr concurrently or
/// risking a deadlock when one fills. A redirect from a temp file has
/// neither problem.
fn runCliWithStdin(
    a: std.mem.Allocator,
    argv_tail: []const u8,
    stdin_bytes: []const u8,
) !std.process.RunResult {
    std.Io.Dir.cwd().access(testing.io, cli_bin, .{}) catch return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "stdin", .data = stdin_bytes });

    const cmd = try std.fmt.allocPrint(
        a,
        "{s} {s} < .zig-cache/tmp/{s}/stdin",
        .{ cli_bin, argv_tail, &tmp.sub_path },
    );
    defer a.free(cmd);

    return std.process.run(a, testing.io, .{ .argv = &.{ "/bin/sh", "-c", cmd } });
}

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |c| c,
        else => 255,
    };
}

test "Cli: fmt - reads stdin and writes formatted output to stdout" {
    const a = testing.allocator;
    const out = try runCliWithStdin(a, "fmt -", "; keep me\n(scene    :name   \"main\")\n");
    defer a.free(out.stdout);
    defer a.free(out.stderr);

    try testing.expectEqual(@as(u8, 0), exitCode(out.term));
    try testing.expectEqualStrings("; keep me\n(scene :name \"main\")\n", out.stdout);
    try testing.expectEqual(@as(usize, 0), out.stderr.len);

    // `-` is a destination, not a path. The first cut of this verb fell
    // through to the file branch and wrote a file literally named `-`
    // into the working directory — this test run created one in the
    // repo root before the stdin branch existed. Assert it stays gone.
    const stray = std.Io.Dir.cwd().access(testing.io, "-", .{});
    try testing.expectError(error.FileNotFound, stray);
}

test "Cli: fmt - with parse errors exits non-zero, emits nothing on stdout" {
    const a = testing.allocator;
    const out = try runCliWithStdin(a, "fmt -", "(scene :name \"main\"\n");
    defer a.free(out.stdout);
    defer a.free(out.stderr);

    try testing.expectEqual(@as(u8, 1), exitCode(out.term));
    // The whole point of the stderr channel policy: a consumer piping
    // `sjon fmt -` into a file must get zero bytes on a parse failure,
    // never a half-formatted document or an error message inline.
    try testing.expectEqual(@as(usize, 0), out.stdout.len);
    try testing.expect(std.mem.indexOf(u8, out.stderr, "unclosed delimiter") != null);
    try testing.expect(std.mem.indexOf(u8, out.stderr, "<stdin>") != null);
}

// ---------------------------------------------------------------------
// `sjon eval` — devx plan 02 CP1 (A3). Prints each expression root's
// evaluated value; stdout carries only the data product (the `fmt`
// channel policy), diagnostics go to stderr.
// ---------------------------------------------------------------------

const fixture_expr: [:0]const u8 = "conformance/cases/expr-all-positive/document.sjon";

test "Cli: eval prints each expression root's path and value" {
    var out = try invoke(&.{ "sjon", "eval", "--no-project", fixture_expr });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expectEqualStrings("all: true\n", out.stdout.written());
    try testing.expectEqual(@as(usize, 0), out.stderr.written().len);
}

test "Cli: eval on a document with no expressions prints nothing and exits 0" {
    var out = try invoke(&.{ "sjon", "eval", "--no-project", fixture_clean });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expectEqual(@as(usize, 0), out.stdout.written().len);
}

test "Cli: eval with diagnostics writes them to stderr, nothing to stdout, exits 1" {
    var out = try invoke(&.{ "sjon", "eval", "--no-project", fixture_data_error });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expectEqual(@as(usize, 0), out.stdout.written().len);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "missing_required_key") != null);
}

test "Cli: eval --format=json emits the expected.values.json value grammar" {
    // Byte-compatible with the corpus sibling files (`zig build
    // gen-expected-values`): object keyed by decimal forest index,
    // values through the `wasm_common.appendValue` encoding.
    var out = try invoke(&.{ "sjon", "eval", "--format=json", "--no-project", fixture_expr });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expectEqualStrings("{\n  \"0\": true\n}\n", out.stdout.written());
}

test "Cli: eval --format=json separates multiple expression roots" {
    // The comma between entries only exists with 2+ roots; a regression
    // here is invalid JSON for every multi-expression document.
    const a = testing.allocator;
    const out = try runCliWithStdin(a, "eval --format=json --no-project -", "(+ 1 2)\n(* 2 3)\n");
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    try testing.expectEqual(@as(u8, 0), exitCode(out.term));
    try testing.expectEqualStrings("{\n  \"0\": 3,\n  \"1\": 6\n}\n", out.stdout);
}

test "Cli: eval with warnings only keeps exit 0 and the data product" {
    // Diagnostics ride stderr; only *errors* suppress stdout. A
    // deprecated-member warning must leave the evaluated values intact.
    const a = testing.allocator;
    const doc =
        "(plugin :name probe :version \"1.0.0\"\n" ++
        "  (value-kind :name status\n" ++
        "    :underlying symbol\n" ++
        "    :members (member-set\n" ++
        "      (member :name draft :label \"Draft\")\n" ++
        "      (member :name archived :deprecated true)))\n" ++
        "  (form :name post\n" ++
        "    (key :name status :type status :optional false)))\n" ++
        "(post :status archived)\n" ++
        "(+ 1 2)\n";
    const out = try runCliWithStdin(a, "eval --no-project -", doc);
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    try testing.expectEqual(@as(u8, 0), exitCode(out.term));
    try testing.expect(std.mem.indexOf(u8, out.stderr, "deprecated_member") != null);
    try testing.expectEqualStrings("+: 3.0\n", out.stdout);
}

test "Cli: eval - reads stdin" {
    const a = testing.allocator;
    const out = try runCliWithStdin(a, "eval --no-project -", "(+ 1 2)\n");
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    try testing.expectEqual(@as(u8, 0), exitCode(out.term));
    // `3.0`, not `3`: arithmetic collapses exact integers to `.number`
    // (Expr.Value semantics), and the writer renders floats so they
    // re-lex as floats.
    try testing.expectEqualStrings("+: 3.0\n", out.stdout);
}

// ---------------------------------------------------------------------
// `sjon query` — devx plan 02 CP2 (A4). Pattern window → haps, the
// terminal mirror of `sjon_query_pattern`: ticks in (PPC grid), the
// two-shape `(haps …)` / `(diagnostics …)` serialization out.
// ---------------------------------------------------------------------

test "Cli: query prints (haps …) for a pattern document" {
    var out = try invoke(&.{
        "sjon",                                         "query",
        "--begin=0",                                    "--end=720720",
        "conformance/cases/pattern-pure/document.sjon",
    });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expectEqualStrings("(haps (hap :part [0 720720] bd))\n", out.stdout.written());
    try testing.expectEqual(@as(usize, 0), out.stderr.written().len);
}

test "Cli: query is deterministic: same seed and window, identical bytes" {
    const argv = [_][:0]const u8{
        "sjon",      "query",
        "--begin=0", "--end=720720",
        "--seed=42", "conformance/cases/pattern-expr-rand/document.sjon",
    };
    var first = try invoke(&argv);
    defer first.deinit();
    var second = try invoke(&argv);
    defer second.deinit();
    try testing.expectEqual(@as(u8, 0), first.code);
    try testing.expectEqualStrings(first.stdout.written(), second.stdout.written());
    try testing.expect(first.stdout.written().len > 0);
}

test "Cli: query routes (diagnostics …) to stderr and exits 1" {
    var out = try invoke(&.{
        "sjon",                                                     "query",
        "--begin=0",                                                "--end=720720",
        "conformance/cases/pattern-expr-eval-failed/document.sjon",
    });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expectEqual(@as(usize, 0), out.stdout.written().len);
    try testing.expect(std.mem.startsWith(u8, out.stderr.written(), "(diagnostics"));
}

test "Cli: query rejects a missing --begin/--end with a usage error" {
    var out = try invoke(&.{ "sjon", "query", "--begin=0", "conformance/cases/pattern-pure/document.sjon" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "--end") != null);
}

test "Cli: query rejects a reversed window and non-integer ticks at parse time" {
    var reversed = try invoke(&.{ "sjon", "query", "--begin=5", "--end=1", "conformance/cases/pattern-pure/document.sjon" });
    defer reversed.deinit();
    try testing.expectEqual(@as(u8, 2), reversed.code);
    try testing.expect(std.mem.indexOf(u8, reversed.stderr.written(), "--begin must not exceed --end") != null);

    var not_int = try invoke(&.{ "sjon", "query", "--begin=abc", "--end=1", "conformance/cases/pattern-pure/document.sjon" });
    defer not_int.deinit();
    try testing.expectEqual(@as(u8, 2), not_int.code);
    try testing.expect(std.mem.indexOf(u8, not_int.stderr.written(), "--begin expects an integer tick") != null);
}

test "Cli: query requires exactly one top-level pattern; stdout stays empty" {
    const a = testing.allocator;
    const multi = try runCliWithStdin(a, "query --begin=0 --end=720720 -", "bd\nsn\n");
    defer a.free(multi.stdout);
    defer a.free(multi.stderr);
    try testing.expectEqual(@as(u8, 1), exitCode(multi.term));
    try testing.expect(std.mem.indexOf(u8, multi.stderr, "exactly one top-level pattern") != null);
    try testing.expectEqual(@as(usize, 0), multi.stdout.len);
}

test "Cli: query explains a tick-budget trip instead of dumping a trace" {
    // Every non-OOM `PatternQuery.Error` variant is reachable from argv
    // alone. `try`-ing the query call meant `--end=<i64.max>` propagated
    // out of `run` as a raw error: a stack trace on stderr and exit 1,
    // the same code as "this pattern has diagnostics".
    const a = testing.allocator;
    const over = try runCliWithStdin(
        a,
        "query --begin=0 --end=9223372036854775807 -",
        "(seq bd sn)\n",
    );
    defer a.free(over.stdout);
    defer a.free(over.stderr);
    try testing.expectEqual(@as(u8, 1), exitCode(over.term));
    try testing.expect(std.mem.indexOf(u8, over.stderr, "tick window") != null);
    // A trace would carry source locations; the message must stand alone.
    try testing.expect(std.mem.indexOf(u8, over.stderr, ".zig") == null);
    try testing.expectEqual(@as(usize, 0), over.stdout.len);
}

test "Cli: repl — an overflowing :query reports and the session continues" {
    // The REPL's `:query` propagated the same budget errors, which unwound
    // the read loop and ended the session. A bad window is an ordinary bad
    // argument: report it and take the next line.
    const a = testing.allocator;
    const out = try runCliWithStdin(
        a,
        "repl --no-project",
        "(seq bd sn)\n:query 0 9223372036854775807\n(+ 1 2)\n",
    );
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    try testing.expectEqual(@as(u8, 0), exitCode(out.term));
    try testing.expect(std.mem.indexOf(u8, out.stdout, ":query failed: tick window") != null);
    // The line after the failed :query still ran — the loop survived.
    try testing.expect(std.mem.indexOf(u8, out.stdout, "3") != null);
}

test "Cli: query on a broken parse reports the parse errors; stdout stays empty" {
    const a = testing.allocator;
    const broken = try runCliWithStdin(a, "query --begin=0 --end=720720 -", "(seq bd\n");
    defer a.free(broken.stdout);
    defer a.free(broken.stderr);
    try testing.expectEqual(@as(u8, 1), exitCode(broken.term));
    try testing.expect(broken.stderr.len > 0);
    try testing.expectEqual(@as(usize, 0), broken.stdout.len);
}

// ---------------------------------------------------------------------
// `sjon effective` — devx plan 02 CP3 (A5). Validate, then print the
// source with omitted defaults spliced in (`sjon.EffectiveDocument`).
// `diff <(sjon effective a.sjon) <(sjon effective b.sjon)` compares
// what documents *mean*, not how much their authors typed.
// ---------------------------------------------------------------------

test "Cli: effective splices omitted defaults into the printed document" {
    var out = try invoke(&.{
        "sjon",         "effective",
        "--no-project", "conformance/cases/default-materialize-literal/document.sjon",
    });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const text = out.stdout.written();
    // The omitted `:radius` default lands inside the form…
    try testing.expect(std.mem.indexOf(u8, text, "(circle :radius 32)") != null);
    // …and everything the author wrote survives verbatim (splice, not
    // re-print): the leading comment is untouched.
    try testing.expect(std.mem.indexOf(u8, text, "; Materialization corpus:") != null);
}

test "Cli: effective on a fully-explicit document is byte-identical to input" {
    var out = try invoke(&.{ "sjon", "effective", "--no-project", fixture_clean });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const original = try std.Io.Dir.cwd().readFileAlloc(testing.io, fixture_clean, testing.allocator, .unlimited);
    defer testing.allocator.free(original);
    try testing.expectEqualStrings(original, out.stdout.written());
}

test "Cli: effective with diagnostics writes them to stderr, no stdout, exits 1" {
    var out = try invoke(&.{ "sjon", "effective", "--no-project", fixture_data_error });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expectEqual(@as(usize, 0), out.stdout.written().len);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "missing_required_key") != null);
}

// ---------------------------------------------------------------------
// `--format=json` hints — devx plan 03 CP1 (B1). The suggestion
// machinery renders structurally for machine consumers: a `hints`
// array ({kind, text, replacement?}) per diagnostic when code-specific
// hints exist, and a `docs` catalogue URL on every diagnostic.
// ---------------------------------------------------------------------

test "Cli: json output carries hints with kind and text for a did-you-mean code" {
    var out = try invoke(&.{
        "sjon",                           "validate",
        "--format=json",                  "--no-project",
        "examples/unknown-key-typo.sjon",
    });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    const text = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, text, "\"hints\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"kind\": \"note\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Did you mean") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"docs\": \"https://hugodaniel.com/pages/sjon/errors/unknown_key\"") != null);
}

test "Cli: json output carries a machine-usable replacement for unknown_key" {
    var out = try invoke(&.{
        "sjon",                           "validate",
        "--format=json",                  "--no-project",
        "examples/unknown-key-typo.sjon",
    });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "\"replacement\": \":zoom\"") != null);
}

test "Cli: json output omits the hints key when no hint applies" {
    // missing_required_key has no registered hint builder — the object
    // carries `docs` but no `hints` array.
    var out = try invoke(&.{ "sjon", "validate", "--format=json", "--no-project", fixture_data_error });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    const text = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, text, "\"hints\"") == null);
    try testing.expect(std.mem.indexOf(u8, text, "\"docs\"") != null);
}

// ---------------------------------------------------------------------
// `--format=github` — devx plan 03 CP2 (B2). Workflow-command
// annotations for CI: one `::error` / `::warning` line per diagnostic
// on stdout, everything else on stderr, exit codes unchanged.
// ---------------------------------------------------------------------

test "Cli: github format emits an ::error workflow command per error" {
    var out = try invoke(&.{ "sjon", "validate", "--format=github", "--no-project", fixture_data_error });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    const text = out.stdout.written();
    try testing.expect(std.mem.startsWith(u8, text, "::error file="));
    try testing.expect(std.mem.indexOf(u8, text, fixture_data_error) != null);
    try testing.expect(std.mem.indexOf(u8, text, ",line=") != null);
    try testing.expect(std.mem.indexOf(u8, text, "::missing_required_key: ") != null);
}

test "Cli: github format maps warnings to ::warning" {
    var out = try invoke(&.{ "sjon", "validate", "--format=github", "--no-project", "examples/warning-deprecated.sjon" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expect(std.mem.startsWith(u8, out.stdout.written(), "::warning file="));
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "deprecated_member") != null);
}

test "Cli: github format is a usage error on explain" {
    var out = try invoke(&.{ "sjon", "explain", "--format=github", "unknown_form" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "github") != null);
}

test "Cli: check --format=github annotates document diagnostics, prose on stderr" {
    var out = try invoke(&.{
        "sjon",                               "check",
        "--format=github",                    "--project-root=examples/hint-plugin-typo",
        "examples/hint-plugin-typo/doc.sjon",
    });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    const text = out.stdout.written();
    // Annotations are the only stdout product…
    try testing.expect(std.mem.startsWith(u8, text, "::error file=examples/hint-plugin-typo/doc.sjon"));
    try testing.expect(std.mem.indexOf(u8, text, "unresolved_plugin") != null);
    // …and the phase/summary prose moves to stderr.
    try testing.expect(std.mem.indexOf(u8, text, "phase:") == null);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "phase: validation") != null);
}

// ---------------------------------------------------------------------
// `export-schema --target=markdown` — devx plan 06 CP2 (C2).
// ---------------------------------------------------------------------

test "Cli: export-schema --target=markdown writes the page" {
    var out = try invoke(&.{ "sjon", "export-schema", "--target=markdown", "--no-project", "examples/plugins/enum-rich/plugin.sjon" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    const page = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, page, "# enum-rich") != null);
    try testing.expect(std.mem.indexOf(u8, page, "## Forms") != null);
    try testing.expect(std.mem.indexOf(u8, page, "| Key | Type | Required | Default | Constraints |") != null);
}

test "Cli: export-schema markdown --layout=per-plugin emits one file per plugin via --output" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer a.free(root);
    const out_arg = try std.fmt.allocPrintSentinel(a, "--output={s}/ref", .{root}, 0);
    defer a.free(out_arg);

    var out = try invoke(&.{
        "sjon",                                   "export-schema",
        "--target=markdown",                      "--layout=per-plugin",
        out_arg,                                  "--no-project",
        "examples/plugins/enum-rich/plugin.sjon",
    });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);

    const page_path = try std.fmt.allocPrint(a, "{s}/ref/enum-rich.md", .{root});
    defer a.free(page_path);
    const page = try std.Io.Dir.cwd().readFileAlloc(testing.io, page_path, a, .unlimited);
    defer a.free(page);
    try testing.expect(std.mem.indexOf(u8, page, "# enum-rich") != null);
}

// ---------------------------------------------------------------------
// `sjon check --watch` — devx plan 04 CP2 (A2/C3). Poll loop over the
// WatchSet core; SJON_WATCH_TICKS (RunEnv.watch_ticks) bounds the loop
// so tests terminate.
// ---------------------------------------------------------------------

test "Cli: check --watch with SJON_WATCH_TICKS=1 runs once and exits 0" {
    var out = try invokeEnv(&.{
        "sjon",                                                      "check",
        "--watch",                                                   "--interval-ms=1",
        "--project-root=conformance/cases/use-plugin-version-match",
    }, .{ .watch_ticks = 1 });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "watching") != null);
}

test "Cli: check --watch does not clear the screen when stdout is piped" {
    var out = try invokeEnv(&.{
        "sjon",                                                      "check",
        "--watch",                                                   "--interval-ms=1",
        "--project-root=conformance/cases/use-plugin-version-match",
    }, .{ .watch_ticks = 1 });
    defer out.deinit();
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "\x1b") == null);
}

test "Cli: check --watch without a project reports and exits instead of looping" {
    var out = try invokeEnv(&.{ "sjon", "check", "--watch", "--no-project" }, .{ .watch_ticks = 1 });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "no sjon-project.sjon") != null);
}

test "Cli: check --watch rejects a zero or non-numeric poll interval" {
    var zero = try invoke(&.{ "sjon", "check", "--watch", "--interval-ms=0" });
    defer zero.deinit();
    try testing.expectEqual(@as(u8, 2), zero.code);
    try testing.expect(std.mem.indexOf(u8, zero.stderr.written(), "--interval-ms must be at least 1") != null);

    var word = try invoke(&.{ "sjon", "check", "--watch", "--interval-ms=fast" });
    defer word.deinit();
    try testing.expectEqual(@as(u8, 2), word.code);
    try testing.expect(std.mem.indexOf(u8, word.stderr.written(), "millisecond count") != null);
}

test "Cli: check --watch --format=github keeps stdout a pure annotation stream" {
    // The watch header and check prose move to stderr; a clean project
    // emits zero annotations, so stdout must be byte-empty.
    var out = try invokeEnv(&.{
        "sjon",            "check",
        "--watch",         "--interval-ms=1",
        "--format=github", "--project-root=conformance/cases/use-plugin-version-match",
    }, .{ .watch_ticks = 1 });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expectEqual(@as(usize, 0), out.stdout.written().len);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "watching") != null);
}

test "Cli: check reads :documents relative to the project root, not the cwd" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "(project :plugins [\"./shapes.sjon\"] :documents [\"doc.sjon\"])\n",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "shapes.sjon",
        .data = "(plugin :name shapes :version \"1.0.0\"\n  (form :name circle\n    (key :name r :type number :optional false)))\n",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "doc.sjon",
        .data = "(use-plugin \"shapes\")\n\n(circle :r 4)\n",
    });

    var root_buf: [160]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "--project-root=.zig-cache/tmp/{s}", .{&tmp.sub_path});
    var root_arg_buf: [160:0]u8 = undefined;
    @memcpy(root_arg_buf[0..root.len], root);
    root_arg_buf[root.len] = 0;
    const root_arg: [:0]const u8 = root_arg_buf[0..root.len :0];

    var out = try invoke(&.{ "sjon", "check", root_arg });
    defer out.deinit();
    // The document must be found and validated (clean), not "unreadable".
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "?? ") == null);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "1 document(s)") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "0 unreadable") != null);
}

test "Cli: check fails when a :documents entry cannot be read" {
    // A `:documents` path that was deleted (or lost its read permission)
    // used to print `?? … unreadable` and still exit 0 — CI stayed green
    // on a project whose documents had silently stopped existing, while
    // `sjon fmt` treated the same condition as fatal. The unreadable
    // count now reaches both the summary and the exit gate.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "(project :plugins [\"./shapes.sjon\"] :documents [\"gone.sjon\"])\n",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "shapes.sjon",
        .data = "(plugin :name shapes :version \"1.0.0\"\n  (form :name circle\n    (key :name r :type number :optional false)))\n",
    });

    var root_buf: [160]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "--project-root=.zig-cache/tmp/{s}", .{&tmp.sub_path});
    var root_arg_buf: [160:0]u8 = undefined;
    @memcpy(root_arg_buf[0..root.len], root);
    root_arg_buf[root.len] = 0;
    const root_arg: [:0]const u8 = root_arg_buf[0..root.len :0];

    var out = try invoke(&.{ "sjon", "check", root_arg });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "gone.sjon  unreadable") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "1 unreadable") != null);
}

/// A project whose one referenced manifest parses cleanly but whose root
/// form is not `(plugin …)` — `ManifestLoader.NotAPluginManifest`, the
/// error three verbs used to `catch continue` into nothing.
fn notAManifestFixture(a: std.mem.Allocator, tmp: *std.testing.TmpDir) ![:0]u8 {
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "(project :plugins [\"./shapes.sjon\"])\n",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "shapes.sjon",
        .data = "(not-a-plugin :name shapes)\n",
    });
    return std.fmt.allocPrintSentinel(a, "--project-root=.zig-cache/tmp/{s}", .{&tmp.sub_path}, 0);
}

test "Cli: lock and sync refuse a project whose manifest failed to load" {
    // A manifest that fails to index is absent from
    // `iterateProjectPlugins`, so `collectLockedEntries` simply walked
    // zero plugins and reported success: `project lock` wrote
    // `:plugins []` and exited 0, and `project sync` called that "up to
    // date" — for a project that references a plugin. The lockfile
    // recorded a state that never existed, which is precisely what a
    // lockfile exists to prevent. `project verify` had always refused;
    // the three verbs now agree.
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_arg = try notAManifestFixture(a, &tmp);
    defer a.free(root_arg);

    // `check` and `verify` were already right — pin them so the shared
    // resolver screening cannot regress unnoticed.
    {
        var out = try invoke(&.{ "sjon", "check", root_arg });
        defer out.deinit();
        try testing.expectEqual(@as(u8, 1), out.code);
        try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "1 manifest error(s)") != null);
    }
    {
        var out = try invoke(&.{ "sjon", "project", "verify", root_arg });
        defer out.deinit();
        try testing.expectEqual(@as(u8, 1), out.code);
    }

    for ([_][:0]const u8{ "lock", "sync" }) |verb| {
        var out = try invoke(&.{ "sjon", "project", verb, root_arg });
        defer out.deinit();
        try testing.expectEqual(@as(u8, 1), out.code);
        try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "load error(s)") != null);
    }

    // Nothing was written: the refusal must precede the lockfile write.
    const lock_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/sjon-project.lock", .{&tmp.sub_path});
    defer a.free(lock_path);
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(testing.io, lock_path, .{}),
    );
}

test "Cli: a `..` document pattern is skipped once, and stays skipped" {
    // The escape filter built `safe_patterns` and then used the
    // *unfiltered* list for the walk, the advisory loop, and the
    // unreadable-root fallback. So `../secret.sjon` was announced as
    // skipped and then handed straight back to the caller to read, and
    // it collected a second `glob_no_matches` advisory on the way.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data =
        \\(project :plugins ["./shapes.sjon"] :documents ["../escape.sjon" "*.sjon" "nope/*.sjon"])
        \\
        ,
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "shapes.sjon",
        .data = "(plugin :name shapes :version \"1.0.0\"\n  (form :name circle\n    (key :name r :type number :optional false)))\n",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "doc.sjon",
        .data = "(use-plugin \"shapes\")\n\n(circle :r 4)\n",
    });

    var root_buf: [160]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "--project-root=.zig-cache/tmp/{s}", .{&tmp.sub_path});
    var root_arg_buf: [160:0]u8 = undefined;
    @memcpy(root_arg_buf[0..root.len], root);
    root_arg_buf[root.len] = 0;
    const root_arg: [:0]const u8 = root_arg_buf[0..root.len :0];

    var out = try invoke(&.{ "sjon", "check", root_arg });
    defer out.deinit();
    const text = out.stdout.written();

    // Announced once...
    try testing.expect(std.mem.indexOf(u8, text, "project_documents_outside_root") != null);
    // ...and not a second time as a no-match advisory. (`nope/*.sjon` is
    // in the list precisely so this asserts the advisory is *selective*,
    // not merely absent.)
    try testing.expect(std.mem.indexOf(u8, text, "glob_no_matches: `nope/*.sjon`") != null);
    try testing.expect(std.mem.indexOf(u8, text, "glob_no_matches: `../escape.sjon`") == null);
    // ...and never resurrected as something to read: the skip note is the
    // only line in the whole report that may name it.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "escape.sjon"));
    // The sibling glob still expanded: skipping one pattern must not
    // disable the rest.
    try testing.expect(std.mem.indexOf(u8, text, "doc.sjon") != null);
}

test "Cli: check --watch says so when the scan came back partial" {
    // `WatchSet.stopped_early` was tested; the CLI line that acts on it
    // never was. Without this, the consumer could be deleted or made
    // conditional and every WatchSet test would still pass — the flag
    // exists only to reach the user.
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "(project :plugins [] :documents [])\n",
    });
    try tmp.dir.createDirPath(testing.io, "locked");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "locked/inner.sjon", .data = "(a)\n" });

    var locked = try tmp.dir.openDir(testing.io, "locked", .{ .iterate = true });
    defer locked.close(testing.io);
    locked.setPermissions(testing.io, @enumFromInt(0)) catch return error.SkipZigTest;
    defer locked.setPermissions(testing.io, .default_dir) catch {};

    const root_arg = try std.fmt.allocPrintSentinel(
        a,
        "--project-root=.zig-cache/tmp/{s}",
        .{&tmp.sub_path},
        0,
    );
    defer a.free(root_arg);

    // Establish the premise *independently* of the thing under test:
    // running as root defeats the permission bits, and a skip keyed off
    // the absent message would turn a deleted consumer into a green run.
    // This is the same open `WatchSet.scan` performs.
    if (tmp.dir.openDir(testing.io, "locked", .{ .iterate = true })) |readable| {
        var d = readable;
        d.close(testing.io);
        return error.SkipZigTest;
    } else |_| {}

    var out = try invokeEnv(
        &.{ "sjon", "check", "--watch", "--interval-ms=1", root_arg },
        .{ .watch_ticks = 1 },
    );
    defer out.deinit();
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "partial file set") != null);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "stopped early") != null);
}

test "Cli: check --watch re-runs when a file changes between ticks" {
    const a = testing.allocator;
    std.Io.Dir.cwd().access(testing.io, cli_bin, .{}) catch return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "(project :plugins [\"./shapes.sjon\"] :documents [\"doc.sjon\"])\n",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "shapes.sjon",
        .data = "(plugin :name shapes :version \"1.0.0\"\n  (form :name circle\n    (key :name r :type number :optional false)))\n",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "doc.sjon",
        .data = "(use-plugin \"shapes\")\n\n(circle :r 4)\n",
    });

    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    // 12 ticks × 100ms ≈ a 1.2s ceiling; the breaking edit lands at
    // ~0.3s, well inside it. Assertions are on run counts (two check
    // runs, second one failing), never on wall-clock.
    const cmd = try std.fmt.allocPrint(
        a,
        "SJON_WATCH_TICKS=12 {s} check --watch --interval-ms=100 --project-root={s} & pid=$!; sleep 0.3; printf '(use-plugin \"shapes\")\\n(circle :r \"bad\")\\n' > {s}/doc.sjon; wait $pid",
        .{ cli_bin, root, root },
    );
    defer a.free(cmd);

    const out = try std.process.run(a, testing.io, .{ .argv = &.{ "/bin/sh", "-c", cmd } });
    defer a.free(out.stdout);
    defer a.free(out.stderr);

    // Last run saw the broken doc → exit 1.
    try testing.expectEqual(@as(u8, 1), exitCode(out.term));
    // Two full check runs happened…
    const first = std.mem.indexOf(u8, out.stdout, "Summary:") orelse return error.MissingFirstRun;
    const second = std.mem.indexOfPos(u8, out.stdout, first + 1, "Summary:") orelse return error.MissingSecondRun;
    _ = second;
    // …and the re-run reports the new diagnostic.
    try testing.expect(std.mem.indexOf(u8, out.stdout, "1 error") != null);
}

// ---------------------------------------------------------------------
// `sjon plugin test` — devx plan 05 (C1). The conformance-corpus
// expectation format as the schema author's assertion language.
// ---------------------------------------------------------------------

const test_manifest_src =
    "(plugin :name probe :version \"1.0.0\"\n" ++
    "  (value-kind :name status\n" ++
    "    :underlying symbol\n" ++
    "    :members (member-set\n" ++
    "      (member :name draft :label \"Draft\")\n" ++
    "      (member :name archived :deprecated true)))\n" ++
    "  (form :name post\n" ++
    "    (key :name status :type status :optional false)))\n";

const SchemaTestDir = struct {
    tmp: std.testing.TmpDir,
    manifest_arg: [:0]u8,
    dir_arg: [:0]u8,

    fn init(a: std.mem.Allocator) !SchemaTestDir {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "plugin.sjon", .data = test_manifest_src });
        try tmp.dir.createDirPath(testing.io, "cases");
        const manifest_arg = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/plugin.sjon", .{&tmp.sub_path}, 0);
        errdefer a.free(manifest_arg);
        const dir_arg = try std.fmt.allocPrintSentinel(a, "--dir=.zig-cache/tmp/{s}/cases", .{&tmp.sub_path}, 0);
        return .{ .tmp = tmp, .manifest_arg = manifest_arg, .dir_arg = dir_arg };
    }

    fn addCase(self: *SchemaTestDir, name: []const u8, doc: []const u8, expected: []const u8) !void {
        var buf: [128]u8 = undefined;
        const doc_path = try std.fmt.bufPrint(&buf, "cases/{s}.sjon", .{name});
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = doc_path, .data = doc });
        var buf2: [128]u8 = undefined;
        const exp_path = try std.fmt.bufPrint(&buf2, "cases/{s}.expected.sjon", .{name});
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = exp_path, .data = expected });
    }

    fn deinit(self: *SchemaTestDir, a: std.mem.Allocator) void {
        a.free(self.manifest_arg);
        a.free(self.dir_arg);
        self.tmp.cleanup();
    }
};

test "Cli: plugin test passes a case whose diagnostics match expected" {
    const a = testing.allocator;
    var fx = try SchemaTestDir.init(a);
    defer fx.deinit(a);
    try fx.addCase(
        "deprecated-use",
        "(post :status archived)\n",
        "(diagnostics\n  (diagnostic :code deprecated_member :severity warning :path [post status]))\n",
    );
    var out = try invoke(&.{ "sjon", "plugin", "test", fx.manifest_arg, fx.dir_arg });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "ok") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "deprecated-use") != null);
}

test "Cli: plugin test fails on a code mismatch and names the case" {
    const a = testing.allocator;
    var fx = try SchemaTestDir.init(a);
    defer fx.deinit(a);
    try fx.addCase(
        "wrong-code",
        "(post :status archived)\n",
        "(diagnostics\n  (diagnostic :code unknown_form :severity warning :path [post status]))\n",
    );
    var out = try invoke(&.{ "sjon", "plugin", "test", fx.manifest_arg, fx.dir_arg });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    const text = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, text, "wrong-code") != null);
    try testing.expect(std.mem.indexOf(u8, text, "unknown_form") != null);
    try testing.expect(std.mem.indexOf(u8, text, "deprecated_member") != null);
}

test "Cli: plugin test fails on a path mismatch, printing expected vs got" {
    const a = testing.allocator;
    var fx = try SchemaTestDir.init(a);
    defer fx.deinit(a);
    try fx.addCase(
        "wrong-path",
        "(post :status archived)\n",
        "(diagnostics\n  (diagnostic :code deprecated_member :severity warning :path [post wrong]))\n",
    );
    var out = try invoke(&.{ "sjon", "plugin", "test", fx.manifest_arg, fx.dir_arg });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    const text = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, text, "expected") != null);
    try testing.expect(std.mem.indexOf(u8, text, "got") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[post wrong]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[post status]") != null);
}

test "Cli: plugin test reports an unreadable manifest as usage, exit 2" {
    var out = try invoke(&.{ "sjon", "plugin", "test", "no-such-plugin.sjon" });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 2), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "cannot read") != null);
}

test "Cli: plugin test refuses a manifest that does not load cleanly" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "broken.sjon", .data = "(nope)\n" });
    const arg = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/broken.sjon", .{&tmp.sub_path}, 0);
    defer a.free(arg);
    var out = try invoke(&.{ "sjon", "plugin", "test", arg });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "does not load cleanly") != null);
}

test "Cli: plugin test fails a case whose expectation file is missing" {
    const a = testing.allocator;
    var fx = try SchemaTestDir.init(a);
    defer fx.deinit(a);
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "cases/lonely.sjon", .data = "(post :status draft)\n" });
    var out = try invoke(&.{ "sjon", "plugin", "test", fx.manifest_arg, fx.dir_arg });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "missing expectation") != null);
}

test "Cli: plugin test reports an expectation with parse errors as that case's failure" {
    // `(diagnostics` unclosed: the parser recovers into a partial tree
    // the decoder accepts, so the hasErrors check *after* decode is
    // what catches it — this pins that ordering (and its message).
    const a = testing.allocator;
    var fx = try SchemaTestDir.init(a);
    defer fx.deinit(a);
    try fx.addCase("unclosed", "(post :status draft)\n", "(diagnostics\n");
    var out = try invoke(&.{ "sjon", "plugin", "test", fx.manifest_arg, fx.dir_arg });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "parse errors") != null);
}

test "Cli: plugin test fails on a count mismatch and dumps the actual stream" {
    const a = testing.allocator;
    var fx = try SchemaTestDir.init(a);
    defer fx.deinit(a);
    // Zero expected vs one actual — the most common authoring failure,
    // and the branch that prints the full "got […]" dump.
    try fx.addCase("miscount", "(post :status archived)\n", "(diagnostics)\n");
    var out = try invoke(&.{ "sjon", "plugin", "test", fx.manifest_arg, fx.dir_arg });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    const text = out.stdout.written();
    try testing.expect(std.mem.indexOf(u8, text, "count mismatch: expected 0, got 1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "got [warning deprecated_member] [post status]") != null);
}

test "Cli: plugin test fails on a severity mismatch" {
    const a = testing.allocator;
    var fx = try SchemaTestDir.init(a);
    defer fx.deinit(a);
    try fx.addCase(
        "wrong-severity",
        "(post :status archived)\n",
        "(diagnostics\n  (diagnostic :code deprecated_member :severity err :path [post status]))\n",
    );
    var out = try invoke(&.{ "sjon", "plugin", "test", fx.manifest_arg, fx.dir_arg });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "severity mismatch: expected err, got warning") != null);
}

test "Cli: plugin test passes an empty expectation against a clean document" {
    const a = testing.allocator;
    var fx = try SchemaTestDir.init(a);
    defer fx.deinit(a);
    try fx.addCase("clean", "(post :status draft)\n", "(diagnostics)\n");
    var out = try invoke(&.{ "sjon", "plugin", "test", fx.manifest_arg, fx.dir_arg });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
}

test "Cli: plugin test reports a malformed expected.sjon as the case's failure, not a crash" {
    const a = testing.allocator;
    var fx = try SchemaTestDir.init(a);
    defer fx.deinit(a);
    try fx.addCase("broken-expectation", "(post :status draft)\n", "(oops)\n");
    var out = try invoke(&.{ "sjon", "plugin", "test", fx.manifest_arg, fx.dir_arg });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "broken-expectation") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "malformed") != null);
}

test "Cli: plugin test with zero cases is a usage-level report, exit 1" {
    const a = testing.allocator;
    var fx = try SchemaTestDir.init(a);
    defer fx.deinit(a);
    var out = try invoke(&.{ "sjon", "plugin", "test", fx.manifest_arg, fx.dir_arg });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "no test case") != null);
}

test "Cli: plugin test discovers tests/ beside the manifest" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plugin.sjon", .data = test_manifest_src });
    try tmp.dir.createDirPath(testing.io, "tests");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tests/clean.sjon", .data = "(post :status draft)\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tests/clean.expected.sjon", .data = "(diagnostics)\n" });

    const manifest_arg = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/plugin.sjon", .{&tmp.sub_path}, 0);
    defer a.free(manifest_arg);
    var out = try invoke(&.{ "sjon", "plugin", "test", manifest_arg });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "ok  clean") != null);
}

test "Cli: plugin test summary line counts pass/fail and exits accordingly" {
    const a = testing.allocator;
    var fx = try SchemaTestDir.init(a);
    defer fx.deinit(a);
    try fx.addCase("clean", "(post :status draft)\n", "(diagnostics)\n");
    try fx.addCase(
        "wrong",
        "(post :status archived)\n",
        "(diagnostics\n  (diagnostic :code unknown_form :severity warning :path [post status]))\n",
    );
    var out = try invoke(&.{ "sjon", "plugin", "test", fx.manifest_arg, fx.dir_arg });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.indexOf(u8, out.stdout.written(), "1 passed, 1 failed") != null);
}

// ---------------------------------------------------------------------
// `sjon share` — devx plan 07 (D2). A failing file becomes a
// playground deep link; byte-format pinned against
// landing-page/src/playground/hash-state.ts.
// ---------------------------------------------------------------------

fn shareFixture(a: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8, data: []const u8) ![:0]u8 {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
    return std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, name }, 0);
}

test "Cli: share emits s= with unpadded url-safe base64, round-tripping unicode" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const doc = try shareFixture(a, &tmp, "doc.sjon", "(café)");
    defer a.free(doc);
    var out = try invoke(&.{ "sjon", "share", doc });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expectEqualStrings(
        "https://hugodaniel.com/pages/sjon/playground#s=KGNhZsOpKQ\n",
        out.stdout.written(),
    );
}

test "Cli: share appends sc= as a JSON array of schema texts in order" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const doc = try shareFixture(a, &tmp, "doc.sjon", "(café)");
    defer a.free(doc);
    const sx = try shareFixture(a, &tmp, "x.sjon", "(x)");
    defer a.free(sx);
    const sy = try shareFixture(a, &tmp, "y.sjon", "(y)");
    defer a.free(sy);
    var out = try invoke(&.{ "sjon", "share", "--base=http://localhost:4321/pages/sjon/playground", doc, sx, sy });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expectEqualStrings(
        "http://localhost:4321/pages/sjon/playground#s=KGNhZsOpKQ&sc=WyIoeCkiLCIoeSkiXQ\n",
        out.stdout.written(),
    );
}

test "Cli: share - reads the document from stdin" {
    const a = testing.allocator;
    const out = try runCliWithStdin(a, "share -", "(a)");
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    try testing.expectEqual(@as(u8, 0), exitCode(out.term));
    try testing.expectEqualStrings(
        "https://hugodaniel.com/pages/sjon/playground#s=KGEp\n",
        out.stdout,
    );
}

test "Cli: share warns on stderr past the size threshold, still prints the URL" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const big = try a.alloc(u8, 9000);
    defer a.free(big);
    @memset(big, 'x');
    const doc = try shareFixture(a, &tmp, "big.sjon", big);
    defer a.free(doc);
    var out = try invoke(&.{ "sjon", "share", doc });
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expect(std.mem.startsWith(u8, out.stdout.written(), "https://"));
    try testing.expect(std.mem.indexOf(u8, out.stderr.written(), "large") != null);
}

test "Cli: share rejects a missing DOC, an empty --base, and an unreadable schema" {
    var missing = try invoke(&.{ "sjon", "share" });
    defer missing.deinit();
    try testing.expectEqual(@as(u8, 2), missing.code);
    try testing.expect(std.mem.indexOf(u8, missing.stderr.written(), "DOC") != null);

    var empty_base = try invoke(&.{ "sjon", "share", "--base=", "x.sjon" });
    defer empty_base.deinit();
    try testing.expectEqual(@as(u8, 2), empty_base.code);
    try testing.expect(std.mem.indexOf(u8, empty_base.stderr.written(), "--base requires a URL") != null);

    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const doc = try shareFixture(a, &tmp, "doc.sjon", "(a)");
    defer a.free(doc);
    var bad_schema = try invoke(&.{ "sjon", "share", doc, "no-such-schema.sjon" });
    defer bad_schema.deinit();
    try testing.expectEqual(@as(u8, 2), bad_schema.code);
    try testing.expect(std.mem.indexOf(u8, bad_schema.stderr.written(), "cannot read") != null);
    // No half-built URL escapes on the data channel.
    try testing.expectEqual(@as(usize, 0), bad_schema.stdout.written().len);
}

// ---------------------------------------------------------------------
// `sjon repl` — devx plan 10 (F1). Line-buffered loop; every test
// spawns the binary with piped stdin (fd 0 has no in-process seam) and
// asserts on the transcript — deterministic, no timing, no ANSI when
// piped.
// ---------------------------------------------------------------------

test "Cli: repl — an expression line prints its value" {
    const a = testing.allocator;
    const out = try runCliWithStdin(a, "repl --no-project", "(+ 1 2)\n");
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    try testing.expectEqual(@as(u8, 0), exitCode(out.term));
    try testing.expectEqualStrings("3.0\n", out.stdout);
}

test "Cli: repl — a multi-line form evaluates once balanced" {
    const a = testing.allocator;
    const out = try runCliWithStdin(a, "repl --no-project", "(+ 1\n   2)\n");
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    try testing.expectEqual(@as(u8, 0), exitCode(out.term));
    try testing.expectEqualStrings("3.0\n", out.stdout);
}

test "Cli: repl — :quit and EOF both exit 0" {
    const a = testing.allocator;
    const quit = try runCliWithStdin(a, "repl --no-project", ":quit\n(+ 1 2)\n");
    defer a.free(quit.stdout);
    defer a.free(quit.stderr);
    try testing.expectEqual(@as(u8, 0), exitCode(quit.term));
    // Nothing after :quit runs.
    try testing.expect(std.mem.indexOf(u8, quit.stdout, "3") == null);

    const eof = try runCliWithStdin(a, "repl --no-project", "");
    defer a.free(eof.stdout);
    defer a.free(eof.stderr);
    try testing.expectEqual(@as(u8, 0), exitCode(eof.term));
}

test "Cli: repl — piped stdin produces no prompt bytes" {
    const a = testing.allocator;
    const out = try runCliWithStdin(a, "repl --no-project", "(+ 1 2)\n");
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "sjon>") == null);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "\x1b") == null);
}

test "Cli: repl — a malformed entry reports diagnostics and the loop continues" {
    const a = testing.allocator;
    const out = try runCliWithStdin(a, "repl --no-project", "(oops\n)\n(+ 1 2)\n");
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    try testing.expectEqual(@as(u8, 0), exitCode(out.term));
    try testing.expect(std.mem.indexOf(u8, out.stdout, "unknown_form") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "3.0") != null);
}

test "Cli: repl — :schema lists loaded form heads" {
    const a = testing.allocator;
    const out = try runCliWithStdin(
        a,
        "repl --project-root=conformance/cases/use-plugin-version-match",
        ":schema\n",
    );
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    try testing.expectEqual(@as(u8, 0), exitCode(out.term));
    try testing.expect(std.mem.indexOf(u8, out.stdout, "shapes") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "circle") != null);
}

test "Cli: repl — :explain unknown_form prints the catalogue entry" {
    const a = testing.allocator;
    const out = try runCliWithStdin(a, "repl --no-project", ":explain unknown_form\n");
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    try testing.expectEqual(@as(u8, 0), exitCode(out.term));
    try testing.expect(std.mem.indexOf(u8, out.stdout, "not declared by any loaded plugin") != null);
}

test "Cli: repl — a pasted form validates against the project schema and reports (code, path)" {
    const a = testing.allocator;
    const out = try runCliWithStdin(
        a,
        "repl --project-root=conformance/cases/use-plugin-version-match",
        "(use-plugin \"shapes\") (circle :r \"nope\")\n",
    );
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    try testing.expectEqual(@as(u8, 0), exitCode(out.term));
    try testing.expect(std.mem.indexOf(u8, out.stdout, "circle") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "error") != null);
}

test "Cli: repl — :query over the last pattern entry prints haps" {
    const a = testing.allocator;
    const out = try runCliWithStdin(a, "repl --no-project", "bd\n:query 0 720720\n");
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    try testing.expectEqual(@as(u8, 0), exitCode(out.term));
    try testing.expect(std.mem.indexOf(u8, out.stdout, "(haps (hap :part [0 720720] bd))") != null);
}

test "Cli: repl — :help lists the command set" {
    const a = testing.allocator;
    const out = try runCliWithStdin(a, "repl --no-project", ":help\n");
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    try testing.expectEqual(@as(u8, 0), exitCode(out.term));
    try testing.expect(std.mem.indexOf(u8, out.stdout, ":schema") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout, ":quit") != null);
}

test "Cli: repl — :query argument errors answer inline and the loop survives" {
    const a = testing.allocator;
    const out = try runCliWithStdin(
        a,
        "repl --no-project",
        ":query\n:query a b\n:query 5 1\n:query 0 1\n:bogus\n(+ 1 2)\n",
    );
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    try testing.expectEqual(@as(u8, 0), exitCode(out.term));
    const so = out.stdout;
    try testing.expect(std.mem.indexOf(u8, so, "usage: :query") != null);
    try testing.expect(std.mem.indexOf(u8, so, "integer ticks") != null);
    try testing.expect(std.mem.indexOf(u8, so, "must not exceed") != null);
    try testing.expect(std.mem.indexOf(u8, so, "nothing to query yet") != null);
    try testing.expect(std.mem.indexOf(u8, so, "unknown command") != null);
    // The expression after five bad commands still evaluates — nothing
    // above tore the loop down.
    try testing.expect(std.mem.indexOf(u8, so, "3.0") != null);
}

test "Cli: repl — a line exceeding the line buffer reports on stderr, not a silent exit 0" {
    const a = testing.allocator;
    // One un-newlined line past the REPL's 64 KiB line buffer. The
    // reader raises `StreamTooLong`; treating that as EOF would end the
    // session with exit 0 and no explanation.
    const big = try a.alloc(u8, 80 * 1024);
    defer a.free(big);
    @memset(big, 'x');
    const out = try runCliWithStdin(a, "repl --no-project", big);
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    try testing.expect(exitCode(out.term) != 0);
    try testing.expect(std.mem.indexOf(u8, out.stderr, "64 KiB") != null);
}
