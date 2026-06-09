const std = @import("std");
const sjon = @import("sjon");
const Host = sjon.Host;
const Binary = sjon.Binary;
const Ast = sjon.Ast;
const SchemaExport = sjon.SchemaExport;
const Glob = sjon.Glob;
const Color = @import("Color.zig");
const SnippetRenderer = @import("SnippetRenderer.zig");
const DidYouMean = @import("DidYouMean.zig");
const Hints = @import("Hints.zig");
const Explanations = @import("Explanations.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;

pub const Format = enum { human, rich, json };

pub const ColorPolicy = enum { auto, always, never };

pub const Exit = struct {
    pub const ok: u8 = 0;
    pub const errors: u8 = 1;
    pub const usage: u8 = 2;
    pub const internal_error: u8 = 3;
};

pub const top_level_verbs = [_][]const u8{
    "check",   "validate", "export-schema", "export-lowering-graph",
    "explain", "plugin",   "project",       "completions",
};

pub const plugin_subcommands = [_][]const u8{ "hash", "info", "check", "list", "init" };

pub const project_subcommands = [_][]const u8{ "info", "verify", "lock", "sync" };

pub const common_flags = [_][]const u8{
    "--format=", "--project-root=", "--no-project", "--target=",
    "--output=", "--layout=",       "--draft=",     "--stdout",
    "--force",   "--check",         "--list",       "--help",
};

const usage_text =
    \\Usage:
    \\  sjon [check] FILE...            Check documents or the current project.
    \\                                  `check` is the default verb; bare `sjon`
    \\                                  and `sjon FILE.sjon` both route here.
    \\  sjon validate FILE              Validate a single SJON document.
    \\  sjon validate -                 Validate from stdin.
    \\  sjon export-schema FILE         Export the document's plugin schema
    \\                                  as JSON Schema 2020-12 / TypeScript.
    \\  sjon export-lowering-graph FILE Render the document's :lowering
    \\                                  :produces DAG as SJON to stdout.
    \\  sjon explain CODE               Explain a diagnostic code; --list for
    \\                                  the full catalogue.
    \\  sjon plugin SUB ...             Plugin manifest tools: hash | info |
    \\                                  check | list | init.
    \\  sjon project SUB ...            Project-file tools: info | verify |
    \\                                  lock | sync.
    \\  sjon completions SHELL          Print a shell-completion script
    \\                                  (bash | zsh | fish) to stdout.
    \\  sjon --help, -h                 Show this help.
    \\
    \\Options for validate:
    \\  --format=<human|json>           Output format (default: human).
    \\  --project-root=DIR              Force the project root (DIR must
    \\                                  contain sjon-project.sjon).
    \\  --no-project                    Disable project-file discovery
    \\                                  entirely; (use-plugin …) refs
    \\                                  fail with unresolved_plugin.
    \\
    \\Options for export-schema:
    \\  --target=<json-schema|typescript|both|intermediate>
    \\                                  Output target (default: both).
    \\  --output=PATH                   Output path; - for stdout (default: -).
    \\                                  With --target=both and stdout, emits
    \\                                  a {"jsonSchema": …, "tsTypes": …}
    \\                                  envelope. With a PATH, writes one
    \\                                  file per target (schema.json,
    \\                                  types.d.ts, export.json).
    \\  --layout=<aggregated|per-plugin>
    \\                                  Aggregated emits one schema.json
    \\                                  per directory; per-plugin emits one
    \\                                  <plugin>.schema.json per plugin plus
    \\                                  an index.d.ts barrel. Cross-plugin
    \\                                  refs use relative file paths.
    \\  --draft=2020-12                 JSON Schema draft (only 2020-12
    \\                                  is accepted in M1).
    \\  --project-root, --no-project    Same semantics as validate.
    \\
    \\When neither --project-root nor --no-project is given, the CLI walks
    \\up from FILE's directory (or cwd for stdin) looking for the nearest
    \\sjon-project.sjon. If none is found, references with explicit :path
    \\still resolve relative to FILE's directory; named references fail.
    \\
    \\Exit codes:
    \\  0  No errors.
    \\  1  Validation errors (check / validate) or err-severity export
    \\     warnings (export-schema).
    \\  2  Usage error.
    \\
;

pub const ProjectMode = union(enum) {
    auto,
    explicit: []const u8,
    disabled,
};

const Action = union(enum) {
    help,
    usage_error: []const u8,
    validate: ValidateOpts,
    export_schema: ExportSchemaOpts,
    export_lowering_graph: ExportLoweringGraphOpts,
    plugin_hash: PluginHashOpts,
    plugin_info: PluginPathOpts,
    plugin_check: PluginPathOpts,
    plugin_list,
    plugin_init: PluginInitOpts,
    project_info: ProjectVerbOpts,
    project_verify: ProjectVerbOpts,
    project_lock: ProjectVerbOpts,
    project_sync: ProjectSyncOpts,
    check: CheckOpts,
    explain: ExplainOpts,
    completions: CompletionsOpts,
};

pub const Shell = enum { bash, zsh, fish };

pub const CompletionsOpts = struct {
    shell: Shell,
};

pub const CheckOpts = struct {
    documents: []const []const u8 = &.{},
    format: Format = .human,
    project_mode: ProjectMode = .auto,
};

pub const ProjectVerbOpts = struct {
    format: Format = .human,
    project_mode: ProjectMode = .auto,
};

pub const ProjectSyncOpts = struct {
    format: Format = .human,
    project_mode: ProjectMode = .auto,
    check: bool = false,
};

pub const PluginPathOpts = struct {
    path: []const u8,
    format: Format = .human,
    project_mode: ProjectMode = .auto,
};

pub const PluginHashOpts = struct {
    path: []const u8,
    format: Format = .human,
};

pub const PluginInitOpts = struct {
    name: []const u8,
    output: []const u8 = "plugin.sjon",
    force: bool = false,
    to_stdout: bool = false,
};

pub const ExplainOpts = struct {
    code: ?[]const u8 = null,
    list: bool = false,
    format: Format = .human,
};

const ValidateOpts = struct {
    file: []const u8,
    format: Format,
    color: ColorPolicy = .auto,
    project_mode: ProjectMode = .auto,
};

pub const ExportTarget = enum { json_schema, typescript, both, intermediate };

const ExportSchemaOpts = struct {
    file: []const u8,
    target: ExportTarget = .both,
    output: []const u8 = "-",
    layout: SchemaExport.Layout = .aggregated,
    project_mode: ProjectMode = .auto,
};

const ExportLoweringGraphOpts = struct {
    file: []const u8,
    project_mode: ProjectMode = .auto,
};

pub const RunEnv = struct {
    stdout_is_tty: bool = false,
    no_color: bool = false,
    sjon_no_color: bool = false,
};

fn resolveColor(policy: ColorPolicy, env: RunEnv) bool {
    return switch (policy) {
        .always => true,
        .never => false,
        .auto => env.stdout_is_tty and !env.no_color and !env.sjon_no_color,
    };
}

pub fn run(
    gpa: Allocator,
    io: Io,
    args: []const [:0]const u8,
    stdout: *Writer,
    stderr: *Writer,
    env: RunEnv,
) !u8 {
    const action = parseArgs(args);
    switch (action) {
        .help => {
            try stdout.writeAll(usage_text);
            return Exit.ok;
        },
        .usage_error => |msg| {
            try stderr.print("sjon: {s}\n\n", .{msg});
            try stderr.writeAll(usage_text);
            return Exit.usage;
        },
        .validate => |opts| return runValidate(gpa, io, opts, stdout, stderr, env),
        .export_schema => |opts| return runExportSchema(gpa, io, opts, stdout, stderr),
        .export_lowering_graph => |opts| return runExportLoweringGraph(gpa, io, opts, stdout, stderr),
        .plugin_hash => |opts| return runPluginHash(gpa, io, opts, stdout, stderr),
        .plugin_info => |opts| return runPluginInfo(gpa, io, opts, stdout, stderr),
        .plugin_check => |opts| return runPluginCheck(gpa, io, opts, stdout, stderr),
        .plugin_list => return runPluginList(gpa, io, stdout, stderr),
        .plugin_init => |opts| return runPluginInit(gpa, io, opts, stdout, stderr),
        .project_info => |opts| return runProjectInfo(gpa, io, opts, stdout, stderr),
        .project_verify => |opts| return runProjectVerify(gpa, io, opts, stdout, stderr),
        .project_lock => |opts| return runProjectLock(gpa, io, opts, stdout, stderr),
        .project_sync => |opts| return runProjectSync(gpa, io, opts, stdout, stderr),
        .check => |opts| return runCheck(gpa, io, opts, stdout, stderr),
        .explain => |opts| return runExplain(opts, stdout, stderr),
        .completions => |opts| return runCompletions(opts, stdout),
    }
}

const ProjectFlag = enum { explicit_kw, no_project_kw };

fn projectModeAlreadySetUsage(current: ProjectMode, incoming: ProjectFlag) !?Action {
    return switch (current) {
        .auto => null,
        .explicit => switch (incoming) {
            .explicit_kw => .{ .usage_error = "--project-root given more than once" },
            .no_project_kw => .{ .usage_error = "--project-root and --no-project are mutually exclusive" },
        },
        .disabled => switch (incoming) {
            .explicit_kw => .{ .usage_error = "--project-root and --no-project are mutually exclusive" },
            .no_project_kw => .{ .usage_error = "--no-project given more than once" },
        },
    };
}

fn parseArgs(args: []const [:0]const u8) Action {
    if (args.len < 2) {
        return .{ .check = .{} };
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        return .help;
    }
    if (std.mem.eql(u8, cmd, "export-schema")) return parseExportSchemaArgs(args);
    if (std.mem.eql(u8, cmd, "export-lowering-graph")) return parseExportLoweringGraphArgs(args);
    if (std.mem.eql(u8, cmd, "plugin")) return parsePluginArgs(args);
    if (std.mem.eql(u8, cmd, "check")) return parseCheckArgs(args);
    if (std.mem.eql(u8, cmd, "project")) return parseProjectArgs(args);
    if (std.mem.eql(u8, cmd, "explain")) return parseExplainArgs(args);
    if (std.mem.eql(u8, cmd, "completions")) return parseCompletionsArgs(args);
    if (!std.mem.eql(u8, cmd, "validate") and !std.mem.startsWith(u8, cmd, "-")) {
        return parseImplicitCheck(args);
    }
    if (!std.mem.eql(u8, cmd, "validate")) {
        return .{ .usage_error = "unknown command" };
    }

    var format: Format = .human;
    var color: ColorPolicy = .auto;
    var file: ?[]const u8 = null;
    var project_mode: ProjectMode = .auto;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.startsWith(u8, arg, "--format=")) {
            const value = arg["--format=".len..];
            if (parseFormat(value)) |f| {
                format = f;
            } else {
                return .{ .usage_error = "unknown --format value (expected human|rich|json)" };
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--color=")) {
            const value = arg["--color=".len..];
            if (parseColor(value)) |c| {
                color = c;
            } else {
                return .{ .usage_error = "unknown --color value (expected auto|always|never)" };
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--project-root=")) {
            if (try projectModeAlreadySetUsage(project_mode, .explicit_kw)) |e| return e;
            const dir = arg["--project-root=".len..];
            if (dir.len == 0) return .{ .usage_error = "--project-root requires a directory" };
            project_mode = .{ .explicit = dir };
            continue;
        }
        if (std.mem.eql(u8, arg, "--project-root")) {
            if (try projectModeAlreadySetUsage(project_mode, .explicit_kw)) |e| return e;
            i += 1;
            if (i >= args.len) return .{ .usage_error = "--project-root requires a directory" };
            if (std.mem.startsWith(u8, args[i], "--")) {
                return .{ .usage_error = "--project-root requires a directory (got a flag instead)" };
            }
            project_mode = .{ .explicit = args[i] };
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-project")) {
            if (try projectModeAlreadySetUsage(project_mode, .no_project_kw)) |e| return e;
            project_mode = .disabled;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return .{ .usage_error = "unknown option" };
        }
        if (file != null) return .{ .usage_error = "extra positional argument" };
        file = arg;
    }

    const path = file orelse return .{ .usage_error = "validate requires a FILE argument (use - for stdin)" };
    return .{ .validate = .{ .file = path, .format = format, .color = color, .project_mode = project_mode } };
}

fn parseFormat(value: []const u8) ?Format {
    if (std.mem.eql(u8, value, "human")) return .human;
    if (std.mem.eql(u8, value, "rich")) return .rich;
    if (std.mem.eql(u8, value, "json")) return .json;
    return null;
}

fn parseColor(value: []const u8) ?ColorPolicy {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "always")) return .always;
    if (std.mem.eql(u8, value, "never")) return .never;
    return null;
}

fn parseShell(value: []const u8) ?Shell {
    if (std.mem.eql(u8, value, "bash")) return .bash;
    if (std.mem.eql(u8, value, "zsh")) return .zsh;
    if (std.mem.eql(u8, value, "fish")) return .fish;
    return null;
}

fn parseCompletionsArgs(args: []const [:0]const u8) Action {
    var shell: ?Shell = null;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.startsWith(u8, arg, "--")) return .{ .usage_error = "unknown option" };
        if (shell != null) return .{ .usage_error = "extra positional argument" };
        shell = parseShell(arg) orelse
            return .{ .usage_error = "`sjon completions` requires a shell (bash | zsh | fish)" };
    }
    const s = shell orelse return .{ .usage_error = "`sjon completions` requires a shell (bash | zsh | fish)" };
    return .{ .completions = .{ .shell = s } };
}

fn parsePluginArgs(args: []const [:0]const u8) Action {
    if (args.len < 3) return .{ .usage_error = "`sjon plugin` requires a subcommand (hash | info | check | list | init)" };
    const sub = args[2];
    if (std.mem.eql(u8, sub, "hash")) return parsePluginHashArgs(args);
    if (std.mem.eql(u8, sub, "info")) return parsePluginPathArgs(args, "info");
    if (std.mem.eql(u8, sub, "check")) return parsePluginPathArgs(args, "check");
    if (std.mem.eql(u8, sub, "list")) return parsePluginListArgs(args);
    if (std.mem.eql(u8, sub, "init")) return parsePluginInitArgs(args);
    return .{ .usage_error = "unknown `sjon plugin` subcommand" };
}

fn parsePluginPathArgs(args: []const [:0]const u8, sub: []const u8) Action {
    var format: Format = .human;
    var path: ?[]const u8 = null;
    var project_mode: ProjectMode = .auto;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.startsWith(u8, arg, "--format=")) {
            const v = arg["--format=".len..];
            if (parseFormat(v)) |f| {
                format = f;
            } else {
                return .{ .usage_error = "unknown --format value (expected human|rich|json)" };
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-project")) {
            project_mode = .disabled;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return .{ .usage_error = "unknown option" };
        }
        if (path != null) return .{ .usage_error = "extra positional argument" };
        path = arg;
    }
    const p = path orelse {
        if (std.mem.eql(u8, sub, "info"))
            return .{ .usage_error = "`sjon plugin info` requires a PATH" };
        return .{ .usage_error = "`sjon plugin check` requires a PATH" };
    };
    const opts: PluginPathOpts = .{ .path = p, .format = format, .project_mode = project_mode };
    if (std.mem.eql(u8, sub, "info")) return .{ .plugin_info = opts };
    return .{ .plugin_check = opts };
}

fn parsePluginListArgs(args: []const [:0]const u8) Action {
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.startsWith(u8, arg, "--format=")) continue;
        if (std.mem.startsWith(u8, arg, "--")) return .{ .usage_error = "unknown option" };
        return .{ .usage_error = "`sjon plugin list` takes no positional arguments" };
    }
    return .plugin_list;
}

fn parsePluginInitArgs(args: []const [:0]const u8) Action {
    var name: ?[]const u8 = null;
    var output: []const u8 = "plugin.sjon";
    var force = false;
    var to_stdout = false;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.startsWith(u8, arg, "--output=")) {
            output = arg["--output=".len..];
            if (output.len == 0) return .{ .usage_error = "--output requires a path" };
            continue;
        }
        if (std.mem.eql(u8, arg, "--force")) {
            force = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--stdout")) {
            to_stdout = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return .{ .usage_error = "unknown option" };
        if (name != null) return .{ .usage_error = "extra positional argument" };
        name = arg;
    }
    const n = name orelse return .{ .usage_error = "`sjon plugin init` requires a NAME" };
    if (!isValidPluginName(n)) {
        return .{ .usage_error = "plugin name must be a bare symbol (letters, digits, '-', '_')" };
    }
    return .{ .plugin_init = .{ .name = n, .output = output, .force = force, .to_stdout = to_stdout } };
}

fn isValidPluginName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

fn parseImplicitCheck(args: []const [:0]const u8) Action {
    return parseCheckArgsFrom(args, 1);
}

fn parseCheckArgs(args: []const [:0]const u8) Action {
    return parseCheckArgsFrom(args, 2);
}

fn parseCheckArgsFrom(args: []const [:0]const u8, start: usize) Action {
    var format: Format = .human;
    var project_mode: ProjectMode = .auto;
    var docs: std.ArrayList([]const u8) = .empty;
    var i: usize = start;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.startsWith(u8, arg, "--format=")) {
            const v = arg["--format=".len..];
            if (parseFormat(v)) |f| {
                format = f;
            } else {
                return .{ .usage_error = "unknown --format value (expected human|rich|json)" };
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-project")) {
            project_mode = .disabled;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--project-root=")) {
            const dir = arg["--project-root=".len..];
            if (dir.len == 0) return .{ .usage_error = "--project-root requires a directory" };
            project_mode = .{ .explicit = dir };
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return .{ .usage_error = "unknown option" };
        }
        docs.append(std.heap.page_allocator, arg) catch return .{ .usage_error = "out of memory" };
    }
    return .{ .check = .{
        .documents = docs.items,
        .format = format,
        .project_mode = project_mode,
    } };
}

fn parseProjectArgs(args: []const [:0]const u8) Action {
    if (args.len < 3) return .{ .usage_error = "`sjon project` requires a subcommand (info | verify | lock | sync)" };
    const sub = args[2];
    if (std.mem.eql(u8, sub, "info")) return parseProjectVerbArgs(args, "info");
    if (std.mem.eql(u8, sub, "verify")) return parseProjectVerbArgs(args, "verify");
    if (std.mem.eql(u8, sub, "lock")) return parseProjectVerbArgs(args, "lock");
    if (std.mem.eql(u8, sub, "sync")) return parseProjectSyncArgs(args);
    return .{ .usage_error = "unknown `sjon project` subcommand" };
}

fn parseProjectVerbArgs(args: []const [:0]const u8, sub: []const u8) Action {
    var format: Format = .human;
    var project_mode: ProjectMode = .auto;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.startsWith(u8, arg, "--format=")) {
            const v = arg["--format=".len..];
            if (parseFormat(v)) |f| {
                format = f;
            } else {
                return .{ .usage_error = "unknown --format value (expected human|rich|json)" };
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--project-root=")) {
            const dir = arg["--project-root=".len..];
            if (dir.len == 0) return .{ .usage_error = "--project-root requires a directory" };
            project_mode = .{ .explicit = dir };
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return .{ .usage_error = "unknown option" };
        return .{ .usage_error = "extra positional argument" };
    }
    const opts: ProjectVerbOpts = .{ .format = format, .project_mode = project_mode };
    if (std.mem.eql(u8, sub, "info")) return .{ .project_info = opts };
    if (std.mem.eql(u8, sub, "lock")) return .{ .project_lock = opts };
    return .{ .project_verify = opts };
}

fn parseProjectSyncArgs(args: []const [:0]const u8) Action {
    var format: Format = .human;
    var project_mode: ProjectMode = .auto;
    var check = false;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.startsWith(u8, arg, "--format=")) {
            const v = arg["--format=".len..];
            if (parseFormat(v)) |f| {
                format = f;
            } else {
                return .{ .usage_error = "unknown --format value (expected human|rich|json)" };
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--project-root=")) {
            const dir = arg["--project-root=".len..];
            if (dir.len == 0) return .{ .usage_error = "--project-root requires a directory" };
            project_mode = .{ .explicit = dir };
            continue;
        }
        if (std.mem.eql(u8, arg, "--check")) {
            check = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return .{ .usage_error = "unknown option" };
        return .{ .usage_error = "extra positional argument" };
    }
    return .{ .project_sync = .{ .format = format, .project_mode = project_mode, .check = check } };
}

fn parsePluginHashArgs(args: []const [:0]const u8) Action {
    var format: Format = .human;
    var path: ?[]const u8 = null;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.startsWith(u8, arg, "--format=")) {
            const value = arg["--format=".len..];
            if (parseFormat(value)) |f| {
                format = f;
            } else {
                return .{ .usage_error = "unknown --format value (expected human|rich|json)" };
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return .{ .usage_error = "unknown option" };
        }
        if (path != null) return .{ .usage_error = "extra positional argument" };
        path = arg;
    }
    const p = path orelse return .{ .usage_error = "`sjon plugin hash` requires a PATH argument" };
    return .{ .plugin_hash = .{ .path = p, .format = format } };
}

fn parseExplainArgs(args: []const [:0]const u8) Action {
    var code: ?[]const u8 = null;
    var list = false;
    var format: Format = .human;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--list")) {
            list = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--format=")) {
            const value = arg["--format=".len..];
            if (parseFormat(value)) |f| {
                format = f;
            } else {
                return .{ .usage_error = "unknown --format value (expected human|rich|json)" };
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return .{ .usage_error = "unknown option" };
        }
        if (code != null) return .{ .usage_error = "extra positional argument" };
        code = arg;
    }
    if (!list and code == null) {
        return .{ .usage_error = "`sjon explain` requires a CODE name or --list" };
    }
    return .{ .explain = .{ .code = code, .list = list, .format = format } };
}

fn parseExportSchemaArgs(args: []const [:0]const u8) Action {
    var target: ExportTarget = .both;
    var output: []const u8 = "-";
    var layout: SchemaExport.Layout = .aggregated;
    var file: ?[]const u8 = null;
    var project_mode: ProjectMode = .auto;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.startsWith(u8, arg, "--target=")) {
            const value = arg["--target=".len..];
            if (std.mem.eql(u8, value, "json-schema")) {
                target = .json_schema;
            } else if (std.mem.eql(u8, value, "typescript")) {
                target = .typescript;
            } else if (std.mem.eql(u8, value, "both")) {
                target = .both;
            } else if (std.mem.eql(u8, value, "intermediate")) {
                target = .intermediate;
            } else {
                return .{ .usage_error = "unknown --target value (expected json-schema|typescript|both|intermediate)" };
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--output=")) {
            output = arg["--output=".len..];
            if (output.len == 0) return .{ .usage_error = "--output requires a value (use - for stdout)" };
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--layout=")) {
            const value = arg["--layout=".len..];
            if (std.mem.eql(u8, value, "aggregated")) {
                layout = .aggregated;
            } else if (std.mem.eql(u8, value, "per-plugin")) {
                layout = .per_plugin;
            } else {
                return .{ .usage_error = "unknown --layout value (expected aggregated|per-plugin)" };
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--draft=")) {
            const value = arg["--draft=".len..];
            if (!std.mem.eql(u8, value, "2020-12")) {
                return .{ .usage_error = "unknown --draft value (M1 only accepts 2020-12)" };
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--project-root=")) {
            if (try projectModeAlreadySetUsage(project_mode, .explicit_kw)) |e| return e;
            const dir = arg["--project-root=".len..];
            if (dir.len == 0) return .{ .usage_error = "--project-root requires a directory" };
            project_mode = .{ .explicit = dir };
            continue;
        }
        if (std.mem.eql(u8, arg, "--project-root")) {
            if (try projectModeAlreadySetUsage(project_mode, .explicit_kw)) |e| return e;
            i += 1;
            if (i >= args.len) return .{ .usage_error = "--project-root requires a directory" };
            if (std.mem.startsWith(u8, args[i], "--")) {
                return .{ .usage_error = "--project-root requires a directory (got a flag instead)" };
            }
            project_mode = .{ .explicit = args[i] };
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-project")) {
            if (try projectModeAlreadySetUsage(project_mode, .no_project_kw)) |e| return e;
            project_mode = .disabled;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return .{ .usage_error = "unknown option" };
        }
        if (file != null) return .{ .usage_error = "extra positional argument" };
        file = arg;
    }
    const path = file orelse return .{ .usage_error = "export-schema requires a FILE argument (use - for stdin)" };
    return .{ .export_schema = .{
        .file = path,
        .target = target,
        .output = output,
        .layout = layout,
        .project_mode = project_mode,
    } };
}

fn parseExportLoweringGraphArgs(args: []const [:0]const u8) Action {
    var file: ?[]const u8 = null;
    var project_mode: ProjectMode = .auto;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.startsWith(u8, arg, "--project-root=")) {
            if (try projectModeAlreadySetUsage(project_mode, .explicit_kw)) |e| return e;
            const dir = arg["--project-root=".len..];
            if (dir.len == 0) return .{ .usage_error = "--project-root requires a directory" };
            project_mode = .{ .explicit = dir };
            continue;
        }
        if (std.mem.eql(u8, arg, "--project-root")) {
            if (try projectModeAlreadySetUsage(project_mode, .explicit_kw)) |e| return e;
            i += 1;
            if (i >= args.len) return .{ .usage_error = "--project-root requires a directory" };
            if (std.mem.startsWith(u8, args[i], "--")) {
                return .{ .usage_error = "--project-root requires a directory (got a flag instead)" };
            }
            project_mode = .{ .explicit = args[i] };
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-project")) {
            if (try projectModeAlreadySetUsage(project_mode, .no_project_kw)) |e| return e;
            project_mode = .disabled;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return .{ .usage_error = "unknown option" };
        }
        if (file != null) return .{ .usage_error = "extra positional argument" };
        file = arg;
    }
    const path = file orelse return .{ .usage_error = "export-lowering-graph requires a FILE argument (use - for stdin)" };
    return .{ .export_lowering_graph = .{
        .file = path,
        .project_mode = project_mode,
    } };
}

fn runValidate(
    gpa: Allocator,
    io: Io,
    opts: ValidateOpts,
    stdout: *Writer,
    stderr: *Writer,
    env: RunEnv,
) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const project = resolveProjectMode(arena, io, opts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ProjectFileNotFound => {
            const dir = opts.project_mode.explicit;
            try stderr.print(
                "sjon: error: project_file_not_found: --project-root {s} has no sjon-project.sjon\n",
                .{dir},
            );
            return Exit.usage;
        },
    };

    const source = loadSource(gpa, io, opts.file) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| {
            try stderr.print("sjon: cannot read {s}: {s}\n", .{ opts.file, @errorName(e) });
            return Exit.usage;
        },
    };
    defer gpa.free(source);

    const file_label = if (std.mem.eql(u8, opts.file, "-")) "<stdin>" else opts.file;

    var result = try Host.validateDocument(gpa, source, .{
        .failure_policy = .strict,
        .project_root = project.root,
        .project_file = project.file,
        .io = if (project.root != null) io else null,
    });
    defer result.deinit();

    const color_enabled = resolveColor(opts.color, env);
    switch (opts.format) {
        .human => try formatHuman(stdout, file_label, project.file, source, result.diagnostics),
        .rich => try formatRich(stdout, file_label, project.file, source, result.diagnostics, color_enabled),
        .json => try formatJson(stdout, file_label, project.file, source, result.diagnostics),
    }

    return if (result.hasErrors()) Exit.errors else Exit.ok;
}

const Project = struct {
    root: ?[]const u8,
    file: ?[]const u8,
};

const ProjectResolveError = error{ OutOfMemory, ProjectFileNotFound };

fn resolveProjectMode(arena: Allocator, io: Io, opts: ValidateOpts) ProjectResolveError!Project {
    return switch (opts.project_mode) {
        .auto => try discoverProjectAuto(arena, io, opts.file),
        .explicit => |dir| blk: {
            const file = try std.fmt.allocPrint(arena, "{s}/sjon-project.sjon", .{dir});
            const exists = blk2: {
                Io.Dir.cwd().access(io, file, .{}) catch break :blk2 false;
                break :blk2 true;
            };
            if (!exists) return ProjectResolveError.ProjectFileNotFound;
            break :blk .{ .root = try arena.dupe(u8, dir), .file = file };
        },
        .disabled => .{ .root = null, .file = null },
    };
}

fn discoverProjectAuto(arena: Allocator, io: Io, file: []const u8) Allocator.Error!Project {
    const start_dir = startDirFor(file);
    const fallback_root = try arena.dupe(u8, start_dir);

    var dir: []const u8 = start_dir;
    while (true) {
        const candidate = try std.fmt.allocPrint(arena, "{s}/sjon-project.sjon", .{dir});
        const exists = blk: {
            Io.Dir.cwd().access(io, candidate, .{}) catch break :blk false;
            break :blk true;
        };
        if (exists) {
            return .{ .root = try arena.dupe(u8, dir), .file = candidate };
        }
        const parent = std.fs.path.dirname(dir) orelse {
            if (!std.mem.eql(u8, dir, ".")) {
                dir = ".";
                continue;
            }
            break;
        };
        if (std.mem.eql(u8, parent, dir)) break;
        dir = parent;
    }
    return .{ .root = fallback_root, .file = null };
}

fn startDirFor(file: []const u8) []const u8 {
    if (file.len == 0 or std.mem.eql(u8, file, "-")) return ".";
    return std.fs.path.dirname(file) orelse ".";
}

fn loadSource(gpa: Allocator, io: Io, path: []const u8) ![:0]u8 {
    if (std.mem.eql(u8, path, "-")) {
        var stdin_file = Io.File.stdin();
        var buf: [4096]u8 = undefined;
        var stdin_reader = stdin_file.reader(io, &buf);
        return try stdin_reader.interface.allocRemainingAlignedSentinel(
            gpa,
            .limited(Binary.MAX_FILE_SIZE),
            .of(u8),
            0,
        );
    }
    return try Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(Binary.MAX_FILE_SIZE),
        .of(u8),
        0,
    );
}

fn runCheck(gpa: Allocator, io: Io, opts: CheckOpts, stdout: *Writer, stderr: *Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const project = try resolveProjectForVerb(arena, io, opts.project_mode, stderr) orelse return Exit.errors;
    var fs = sjon.FilesystemResolver.init(gpa, io, project.root.?, project.file.?) catch return Exit.internal_error;
    defer fs.deinit();

    try stdout.print("sjon check (project: {s})\n", .{project.file.?});
    try stdout.writeAll("\n==== phase: manifest ====\n");
    var manifest_errors: usize = 0;
    const manifest_diags = fs.takeProjectDiagnostics();
    for (manifest_diags) |d| {
        const sev_label = if (d.severity == .err) "err" else "warn";
        try stdout.print("{s} {s}: {s}\n", .{ sev_label, @tagName(d.code), d.message });
        if (d.severity == .err) manifest_errors += 1;
    }
    var plugins_loaded: usize = 0;
    var it = fs.iterateProjectPlugins();
    while (it.next()) |entry| {
        var tree = sjon.Parser.parse(gpa, entry.manifest_source) catch continue;
        defer tree.deinit();
        var loaded = sjon.ManifestLoader.load(gpa, tree) catch continue;
        defer loaded.deinit();
        if (loaded.hasErrors()) {
            try stdout.print("err {s}  {s}\n", .{ entry.name, entry.manifest_path });
            for (loaded.diagnostics) |d| {
                if (d.severity != .err) continue;
                try stdout.print("    {s}: {s}\n", .{ @tagName(d.code), d.message });
                manifest_errors += 1;
            }
        } else {
            const v = if (loaded.plugin.version.len > 0) loaded.plugin.version else "?";
            try stdout.print("ok  {s} {s}  {s}\n", .{ entry.name, v, entry.manifest_path });
            plugins_loaded += 1;
        }
    }

    try stdout.writeAll("\n==== phase: validation ====\n");
    const patterns = if (opts.documents.len > 0) opts.documents else fs.project_documents;
    const documents = expandDocumentPatterns(
        arena,
        io,
        project.root.?,
        patterns,
        fs.project_ignore,
        stdout,
    ) catch |err| switch (err) {
        error.OutOfMemory => return Exit.internal_error,
        error.WriteFailed => return Exit.internal_error,
    };
    var doc_errors: usize = 0;
    var doc_warnings: usize = 0;
    var docs_validated: usize = 0;
    if (documents.len == 0) {
        if (patterns.len == 0) {
            try stdout.writeAll("(no `:documents` glob set and no explicit args — nothing to validate)\n");
        }
    } else {
        for (documents) |doc_path| {
            var r = validateOneDoc(gpa, io, doc_path, project) catch |err| switch (err) {
                error.OutOfMemory => return Exit.internal_error,
                error.UnreadableFile => {
                    try stdout.print("?? {s}  unreadable\n", .{doc_path});
                    continue;
                },
            };
            defer r.result.deinit();
            const ec = countDiag(r.result.diagnostics, .err);
            const wc = countDiag(r.result.diagnostics, .warning);
            doc_errors += ec;
            doc_warnings += wc;
            docs_validated += 1;
            if (ec > 0) {
                try stdout.print("err {s}  {d} error(s), {d} warning(s)\n", .{ doc_path, ec, wc });
                for (r.result.diagnostics) |d| {
                    if (d.severity != .err) continue;
                    try stdout.print("    {s}: {s}\n", .{ @tagName(d.code), d.message });
                    break;
                }
            } else {
                try stdout.print("ok  {s}  0 errors, {d} warning(s)\n", .{ doc_path, wc });
            }
        }
    }

    try stdout.writeAll("\n----------------------------------------\n");
    try stdout.print("Summary: {d} plugin(s) loaded, {d} manifest error(s); {d} document(s), {d} error(s), {d} warning(s).\n", .{
        plugins_loaded,
        manifest_errors,
        docs_validated,
        doc_errors,
        doc_warnings,
    });
    return if (manifest_errors > 0 or doc_errors > 0) Exit.errors else Exit.ok;
}

const ValidatedDoc = struct {
    result: Host.HostResult,
};

fn validateOneDoc(gpa: Allocator, io: Io, path: []const u8, project: Project) !ValidatedDoc {
    const source = Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .unlimited,
        .of(u8),
        0,
    ) catch return error.UnreadableFile;
    defer gpa.free(source);
    var result = try Host.validateDocument(gpa, source, .{
        .failure_policy = .strict,
        .project_root = project.root,
        .project_file = project.file,
        .io = io,
    });
    errdefer result.deinit();
    return .{ .result = result };
}

fn countDiag(diags: []const Host.HostDiagnostic, sev: Ast.Diagnostic.Severity) usize {
    var n: usize = 0;
    for (diags) |d| if (d.severity == sev) {
        n += 1;
    };
    return n;
}

fn patternHasWildcards(s: []const u8) bool {
    for (s) |c| {
        if (c == '*' or c == '?' or c == '{') return true;
    }
    return false;
}

fn patternEscapesRoot(pattern: []const u8) bool {
    var p = pattern;
    while (std.mem.startsWith(u8, p, "./")) p = p[2..];
    if (std.mem.startsWith(u8, p, "../")) return true;
    if (std.mem.eql(u8, p, "..")) return true;
    if (std.mem.indexOf(u8, p, "/../") != null) return true;
    if (std.mem.endsWith(u8, p, "/..")) return true;
    return false;
}

fn expandDocumentPatterns(
    arena: Allocator,
    io: Io,
    project_root: []const u8,
    patterns: []const []const u8,
    ignore_patterns: []const []const u8,
    stdout: *Writer,
) (Allocator.Error || Writer.Error)![]const []const u8 {
    if (patterns.len == 0) return &.{};

    var filtered: std.ArrayList([]const u8) = .empty;
    for (patterns) |p| {
        if (patternEscapesRoot(p)) {
            try stdout.print("note: project_documents_outside_root: `{s}` escapes the project root; skipped\n", .{p});
            continue;
        }
        try filtered.append(arena, p);
    }
    const safe_patterns = filtered.items;
    if (safe_patterns.len == 0) return &.{};

    var any_wildcard = false;
    for (safe_patterns) |p| {
        if (patternHasWildcards(p)) {
            any_wildcard = true;
            break;
        }
    }
    if (!any_wildcard) {
        var out: std.ArrayList([]const u8) = .empty;
        for (safe_patterns) |p| try out.append(arena, try arena.dupe(u8, p));
        return out.toOwnedSlice(arena);
    }

    const normalized_patterns = try arena.alloc([]const u8, patterns.len);
    for (patterns, 0..) |p, i| {
        normalized_patterns[i] = if (std.mem.startsWith(u8, p, "./")) p[2..] else p;
    }

    var dir = Io.Dir.cwd().openDir(io, project_root, .{ .iterate = true }) catch {
        var out: std.ArrayList([]const u8) = .empty;
        for (patterns) |p| try out.append(arena, try arena.dupe(u8, p));
        return out.toOwnedSlice(arena);
    };
    defer dir.close(io);

    var walker = dir.walk(arena) catch return error.OutOfMemory;
    defer walker.deinit();

    const matched_flags = try arena.alloc(bool, patterns.len);
    for (matched_flags) |*b| b.* = false;

    var matches: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const rel = try arena.dupe(u8, entry.path);
        for (rel) |*c| if (c.* == '\\') {
            c.* = '/';
        };

        if (std.mem.eql(u8, rel, "sjon-project.sjon")) continue;
        if (std.mem.startsWith(u8, rel, ".git/")) continue;
        if (std.mem.startsWith(u8, rel, ".zig-cache/")) continue;
        if (std.mem.startsWith(u8, rel, "zig-out/")) continue;
        if (std.mem.startsWith(u8, rel, "node_modules/")) continue;

        var ignored = false;
        for (ignore_patterns) |ip| {
            if (Glob.match(ip, rel)) {
                ignored = true;
                break;
            }
        }
        if (ignored) continue;

        var any_match = false;
        for (normalized_patterns, 0..) |p, i| {
            if (Glob.match(p, rel)) {
                matched_flags[i] = true;
                any_match = true;
            }
        }
        if (!any_match) continue;
        if (seen.contains(rel)) continue;
        try seen.put(arena, rel, {});
        try matches.append(arena, rel);
    }

    for (patterns, matched_flags) |p, hit| {
        if (!hit) try stdout.print("note: glob_no_matches: `{s}` matched no files\n", .{p});
    }

    std.mem.sort([]const u8, matches.items, {}, lessThanStr);
    return matches.toOwnedSlice(arena);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn runProjectInfo(gpa: Allocator, io: Io, opts: ProjectVerbOpts, stdout: *Writer, stderr: *Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const project = try resolveProjectForVerb(arena, io, opts.project_mode, stderr) orelse return Exit.errors;
    var fs = sjon.FilesystemResolver.init(gpa, io, project.root.?, project.file.?) catch return Exit.internal_error;
    defer fs.deinit();

    switch (opts.format) {
        .json => {
            try stdout.writeAll("{\"root\":\"");
            try stdout.writeAll(project.root.?);
            try stdout.writeAll("\",\"project_file\":\"");
            try stdout.writeAll(project.file.?);
            try stdout.writeAll("\",\"plugins\":[");
            var it = fs.iterateProjectPlugins();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try stdout.writeAll(",");
                first = false;
                try stdout.print("{{\"name\":\"{s}\",\"path\":\"{s}\"}}", .{ entry.name, entry.manifest_path });
            }
            try stdout.writeAll("],\"documents\":[");
            for (fs.project_documents, 0..) |d, i| {
                if (i > 0) try stdout.writeAll(",");
                try stdout.print("\"{s}\"", .{d});
            }
            try stdout.writeAll("]}\n");
        },
        .human, .rich => {
            try stdout.print("project   {s}\n", .{project.file.?});
            try stdout.print("root      {s}\n", .{project.root.?});
            if (fs.project_name) |n| try stdout.print("name      {s}\n", .{n});
            if (fs.project_version) |v| try stdout.print("version   {s}\n", .{v});
            try stdout.writeAll("plugins:\n");
            var it = fs.iterateProjectPlugins();
            while (it.next()) |entry| {
                try stdout.print("  - {s}  {s}\n", .{ entry.name, entry.manifest_path });
            }
            if (fs.project_documents.len > 0) {
                try stdout.writeAll("documents:\n");
                for (fs.project_documents) |d| try stdout.print("  - {s}\n", .{d});
            }
            if (fs.project_search_roots.len > 0) {
                try stdout.writeAll("search-roots:\n");
                for (fs.project_search_roots) |r| try stdout.print("  - {s}\n", .{r});
            }
            if (fs.project_ignore.len > 0) {
                try stdout.writeAll("ignore:\n");
                for (fs.project_ignore) |p| try stdout.print("  - {s}\n", .{p});
            }
            if (fs.project_lockfile_disabled) {
                try stdout.writeAll("lockfile  <disabled>\n");
            } else if (fs.project_lockfile_path) |lf| {
                try stdout.print("lockfile  {s}\n", .{lf});
            }
            if (fs.project_exports) |exp| {
                try stdout.writeAll("exports:\n");
                if (exp.json_schema_dir) |d| try stdout.print("  json-schema  {s}\n", .{d});
                if (exp.typescript_dir) |d| try stdout.print("  typescript   {s}\n", .{d});
                try stdout.print("  layout       {s}\n", .{@tagName(exp.layout)});
            }
        },
    }
    return Exit.ok;
}

fn runProjectVerify(gpa: Allocator, io: Io, opts: ProjectVerbOpts, stdout: *Writer, stderr: *Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const project = try resolveProjectForVerb(arena, io, opts.project_mode, stderr) orelse return Exit.errors;
    var fs = sjon.FilesystemResolver.init(gpa, io, project.root.?, project.file.?) catch return Exit.internal_error;
    defer fs.deinit();

    var error_count: usize = 0;
    const project_diags = fs.takeProjectDiagnostics();
    for (project_diags) |d| {
        try stdout.print("{s}: {s}: {s}\n", .{ @tagName(d.severity), @tagName(d.code), d.message });
        if (d.severity == .err) error_count += 1;
    }

    var lockfile: ?sjon.Lockfile.Lockfile = blk: {
        if (fs.project_lockfile_disabled) break :blk null;
        const lf_path = if (fs.project_lockfile_path) |p| p else try std.fmt.allocPrint(arena, "{s}/sjon-project.lock", .{project.root.?});
        const bytes = Io.Dir.cwd().readFileAllocOptions(io, lf_path, arena, .unlimited, .of(u8), 0) catch break :blk null;
        const parsed = sjon.Lockfile.parse(gpa, bytes) catch |err| switch (err) {
            error.OutOfMemory => return Exit.internal_error,
            error.UnsupportedVersion => {
                try stdout.writeAll("err lockfile_version_unsupported: lockfile :version exceeds host max\n");
                error_count += 1;
                break :blk null;
            },
            error.Corrupt => {
                try stdout.writeAll("err lockfile_corrupt: lockfile failed to parse\n");
                error_count += 1;
                break :blk null;
            },
        };
        break :blk parsed;
    };
    defer if (lockfile) |*lf| lf.deinit();

    var seen_names: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_names.deinit(arena);
    var it = fs.iterateProjectPlugins();
    while (it.next()) |entry| {
        try seen_names.put(arena, entry.name, {});
        var tree = sjon.Parser.parse(gpa, entry.manifest_source) catch continue;
        defer tree.deinit();
        var loaded = sjon.ManifestLoader.load(gpa, tree) catch {
            try stdout.print("err {s}: failed to load manifest\n", .{entry.name});
            error_count += 1;
            continue;
        };
        defer loaded.deinit();
        if (loaded.hasErrors()) {
            try stdout.print("err {s}  {s}\n", .{ entry.name, entry.manifest_path });
            for (loaded.diagnostics) |d| {
                if (d.severity != .err) continue;
                try stdout.print("    {s}: {s}\n", .{ @tagName(d.code), d.message });
                error_count += 1;
            }
            continue;
        }
        for (loaded.diagnostics) |d| {
            if (d.severity == .err) continue;
            try stdout.print("warn {s}  {s}: {s}\n", .{ entry.name, @tagName(d.code), d.message });
        }

        if (lockfile) |lf| {
            if (lf.find(entry.name)) |locked| {
                const m_hash = try sjon.Lockfile.hashBytes(arena, entry.manifest_source);
                if (!std.mem.eql(u8, m_hash, locked.manifest_hash)) {
                    try stdout.print("err {s}  lockfile_drift on manifest: locked {s} got {s}\n", .{ entry.name, locked.manifest_hash, m_hash });
                    error_count += 1;
                    continue;
                }
                if (locked.wasm_hash) |lh| {
                    const wasm_path = try sjonToPairedWasm(arena, entry.manifest_path);
                    if (Io.Dir.cwd().readFileAlloc(io, wasm_path, arena, .unlimited)) |wasm_bytes| {
                        const wh = try sjon.Lockfile.hashBytes(arena, wasm_bytes);
                        if (!std.mem.eql(u8, wh, lh)) {
                            try stdout.print("err {s}  lockfile_drift on wasm: locked {s} got {s}\n", .{ entry.name, lh, wh });
                            error_count += 1;
                            continue;
                        }
                    } else |_| {
                        try stdout.print("err {s}  lockfile_drift: expected wasm at `{s}` but it is unreadable\n", .{ entry.name, wasm_path });
                        error_count += 1;
                        continue;
                    }
                }
            } else {
                try stdout.print("err {s}  lockfile_missing_entry: project references plugin not in lockfile\n", .{entry.name});
                error_count += 1;
                continue;
            }
        }
        try stdout.print("ok  {s} {s}  {s}\n", .{
            entry.name,
            if (loaded.plugin.version.len > 0) loaded.plugin.version else "?",
            entry.manifest_path,
        });
    }

    if (lockfile) |lf| {
        for (lf.plugins) |locked| {
            if (!seen_names.contains(locked.name)) {
                try stdout.print("warn {s}  lockfile_orphan: lockfile records plugin no longer referenced\n", .{locked.name});
            }
        }
    }

    if (error_count > 0) {
        try stdout.print("\n{d} error(s)\n", .{error_count});
        return Exit.errors;
    }
    return Exit.ok;
}

fn runProjectLock(gpa: Allocator, io: Io, opts: ProjectVerbOpts, stdout: *Writer, stderr: *Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const project = try resolveProjectForVerb(arena, io, opts.project_mode, stderr) orelse return Exit.errors;
    var fs = sjon.FilesystemResolver.init(gpa, io, project.root.?, project.file.?) catch return Exit.internal_error;
    defer fs.deinit();

    const project_bytes = Io.Dir.cwd().readFileAlloc(io, project.file.?, arena, .unlimited) catch {
        try stderr.writeAll("sjon project lock: cannot read project file\n");
        return Exit.errors;
    };
    const project_hash = try sjon.Lockfile.hashBytes(arena, project_bytes);

    var entries: std.ArrayList(sjon.Lockfile.LockedEntry) = .empty;
    var it = fs.iterateProjectPlugins();
    while (it.next()) |entry| {
        var tree = sjon.Parser.parse(gpa, entry.manifest_source) catch continue;
        defer tree.deinit();
        var loaded = sjon.ManifestLoader.load(gpa, tree) catch continue;
        defer loaded.deinit();
        if (loaded.hasErrors()) {
            try stderr.print("sjon project lock: refusing to lock — `{s}` has manifest errors\n", .{entry.name});
            return Exit.errors;
        }
        const m_hash = try sjon.Lockfile.hashBytes(arena, entry.manifest_source);
        var w_hash: ?[]const u8 = null;
        const wasm_path = try sjonToPairedWasm(arena, entry.manifest_path);
        if (Io.Dir.cwd().readFileAlloc(io, wasm_path, arena, .unlimited)) |wasm_bytes| {
            w_hash = try sjon.Lockfile.hashBytes(arena, wasm_bytes);
        } else |_| {}
        try entries.append(arena, .{
            .name = try arena.dupe(u8, entry.name),
            .version = try arena.dupe(u8, loaded.plugin.version),
            .path = try arena.dupe(u8, entry.manifest_path),
            .manifest_hash = m_hash,
            .wasm_hash = w_hash,
            .resolved_from = .project_plugins,
        });
    }
    sjon.Lockfile.sortEntries(entries.items);

    var lf: sjon.Lockfile.Lockfile = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .project_hash = project_hash,
        .generated_at = null,
        .sjon_version = null,
        .plugins = entries.items,
    };
    defer lf.arena.deinit();

    const bytes = try sjon.Lockfile.write(arena, lf);
    const lockfile_path = if (fs.project_lockfile_path) |p| p else try std.fmt.allocPrint(arena, "{s}/sjon-project.lock", .{project.root.?});
    var cwd = Io.Dir.cwd();
    cwd.writeFile(io, .{ .sub_path = lockfile_path, .data = bytes }) catch |err| {
        try stderr.print("sjon project lock: cannot write `{s}`: {s}\n", .{ lockfile_path, @errorName(err) });
        return Exit.errors;
    };
    try stdout.print("wrote {s} ({d} plugin(s))\n", .{ lockfile_path, entries.items.len });
    return Exit.ok;
}

fn runProjectSync(gpa: Allocator, io: Io, opts: ProjectSyncOpts, stdout: *Writer, stderr: *Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const project = try resolveProjectForVerb(arena, io, opts.project_mode, stderr) orelse return Exit.errors;
    var fs = sjon.FilesystemResolver.init(gpa, io, project.root.?, project.file.?) catch return Exit.internal_error;
    defer fs.deinit();

    const project_bytes = Io.Dir.cwd().readFileAlloc(io, project.file.?, arena, .unlimited) catch {
        try stderr.writeAll("sjon project sync: cannot read project file\n");
        return Exit.errors;
    };
    const project_hash = try sjon.Lockfile.hashBytes(arena, project_bytes);

    var entries: std.ArrayList(sjon.Lockfile.LockedEntry) = .empty;
    var it = fs.iterateProjectPlugins();
    while (it.next()) |entry| {
        var tree = sjon.Parser.parse(gpa, entry.manifest_source) catch continue;
        defer tree.deinit();
        var loaded = sjon.ManifestLoader.load(gpa, tree) catch continue;
        defer loaded.deinit();
        if (loaded.hasErrors()) {
            try stderr.print("sjon project sync: refusing to sync — `{s}` has manifest errors\n", .{entry.name});
            return Exit.errors;
        }
        const m_hash = try sjon.Lockfile.hashBytes(arena, entry.manifest_source);
        var w_hash: ?[]const u8 = null;
        const wasm_path = try sjonToPairedWasm(arena, entry.manifest_path);
        if (Io.Dir.cwd().readFileAlloc(io, wasm_path, arena, .unlimited)) |wasm_bytes| {
            w_hash = try sjon.Lockfile.hashBytes(arena, wasm_bytes);
        } else |_| {}
        try entries.append(arena, .{
            .name = try arena.dupe(u8, entry.name),
            .version = try arena.dupe(u8, loaded.plugin.version),
            .path = try arena.dupe(u8, entry.manifest_path),
            .manifest_hash = m_hash,
            .wasm_hash = w_hash,
            .resolved_from = .project_plugins,
        });
    }
    sjon.Lockfile.sortEntries(entries.items);

    const lockfile_path = if (fs.project_lockfile_path) |p|
        p
    else
        try std.fmt.allocPrint(arena, "{s}/sjon-project.lock", .{project.root.?});
    const existing_bytes: ?[:0]u8 = Io.Dir.cwd().readFileAllocOptions(io, lockfile_path, arena, .unlimited, .of(u8), 0) catch null;

    var old_lf: ?sjon.Lockfile.Lockfile = null;
    defer if (old_lf) |*lf| lf.deinit();
    var lockfile_unreadable = false;
    if (existing_bytes) |bytes| {
        if (sjon.Lockfile.parse(gpa, bytes)) |parsed| {
            old_lf = parsed;
        } else |err| switch (err) {
            error.OutOfMemory => return Exit.internal_error,
            error.UnsupportedVersion => {
                try stdout.writeAll("note lockfile_version_unsupported: regenerating from manifests\n");
                lockfile_unreadable = true;
            },
            error.Corrupt => {
                try stdout.writeAll("note lockfile_corrupt: regenerating from manifests\n");
                lockfile_unreadable = true;
            },
        }
    }

    var added: std.ArrayList([]const u8) = .empty;
    var updated: std.ArrayList([]const u8) = .empty;
    var unchanged: usize = 0;
    for (entries.items) |e| {
        const locked = if (old_lf) |lf| lf.find(e.name) else null;
        if (locked) |l| {
            if (std.mem.eql(u8, e.manifest_hash, l.manifest_hash) and wasmHashEql(e.wasm_hash, l.wasm_hash)) {
                unchanged += 1;
            } else {
                try updated.append(arena, e.name);
            }
        } else {
            try added.append(arena, e.name);
        }
    }
    var removed: std.ArrayList([]const u8) = .empty;
    if (old_lf) |lf| {
        for (lf.plugins) |l| {
            if (!entriesContain(entries.items, l.name)) try removed.append(arena, try arena.dupe(u8, l.name));
        }
    }

    var lf_out: sjon.Lockfile.Lockfile = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .project_hash = project_hash,
        .generated_at = null,
        .sjon_version = null,
        .plugins = entries.items,
    };
    defer lf_out.arena.deinit();
    const new_bytes = try sjon.Lockfile.write(arena, lf_out);

    const up_to_date = existing_bytes != null and !lockfile_unreadable and
        std.mem.eql(u8, existing_bytes.?, new_bytes);

    if (opts.check) {
        switch (opts.format) {
            .json => try writeSyncJson(stdout, added.items, updated.items, removed.items, unchanged, false, lockfile_path),
            .human, .rich => {
                try printSyncSummary(stdout, added.items, updated.items, removed.items, unchanged, lockfile_unreadable, existing_bytes == null);
                if (up_to_date) {
                    try stdout.print("up to date: {s}\n", .{lockfile_path});
                } else {
                    try stdout.print("out of date: {s} would change (run `sjon project sync`)\n", .{lockfile_path});
                }
            },
        }
        return if (up_to_date) Exit.ok else Exit.errors;
    }

    if (up_to_date) {
        switch (opts.format) {
            .json => try writeSyncJson(stdout, added.items, updated.items, removed.items, unchanged, false, lockfile_path),
            .human, .rich => try stdout.print("up to date: {s} ({d} plugin(s))\n", .{ lockfile_path, entries.items.len }),
        }
        return Exit.ok;
    }

    var cwd = Io.Dir.cwd();
    cwd.writeFile(io, .{ .sub_path = lockfile_path, .data = new_bytes }) catch |err| {
        try stderr.print("sjon project sync: cannot write `{s}`: {s}\n", .{ lockfile_path, @errorName(err) });
        return Exit.errors;
    };
    switch (opts.format) {
        .json => try writeSyncJson(stdout, added.items, updated.items, removed.items, unchanged, true, lockfile_path),
        .human, .rich => {
            try printSyncSummary(stdout, added.items, updated.items, removed.items, unchanged, lockfile_unreadable, existing_bytes == null);
            try stdout.print("wrote {s} ({d} plugin(s))\n", .{ lockfile_path, entries.items.len });
        },
    }
    return Exit.ok;
}

fn wasmHashEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn entriesContain(entries: []const sjon.Lockfile.LockedEntry, name: []const u8) bool {
    for (entries) |e| if (std.mem.eql(u8, e.name, name)) return true;
    return false;
}

fn printSyncSummary(
    out: *Writer,
    added: []const []const u8,
    updated: []const []const u8,
    removed: []const []const u8,
    unchanged: usize,
    regenerated: bool,
    bootstrap: bool,
) !void {
    if (bootstrap) try out.writeAll("no lockfile present — creating one\n");
    if (regenerated) try out.writeAll("previous lockfile unreadable — regenerating\n");
    for (added) |n| try out.print("  + {s}\n", .{n});
    for (updated) |n| try out.print("  ~ {s}\n", .{n});
    for (removed) |n| try out.print("  - {s}\n", .{n});
    if (added.len == 0 and updated.len == 0 and removed.len == 0) {
        try out.print("  (no plugin changes; {d} unchanged)\n", .{unchanged});
    }
}

fn writeSyncJson(
    out: *Writer,
    added: []const []const u8,
    updated: []const []const u8,
    removed: []const []const u8,
    unchanged: usize,
    wrote: bool,
    path: []const u8,
) !void {
    var w: std.json.Stringify = .{ .writer = out, .options = .{ .whitespace = .indent_2 } };
    try w.beginObject();
    try w.objectField("added");
    try writeJsonStrArray(&w, added);
    try w.objectField("updated");
    try writeJsonStrArray(&w, updated);
    try w.objectField("removed");
    try writeJsonStrArray(&w, removed);
    try w.objectField("unchanged");
    try w.write(unchanged);
    try w.objectField("wrote");
    try w.write(wrote);
    try w.objectField("path");
    try w.write(path);
    try w.endObject();
    try out.writeByte('\n');
}

fn writeJsonStrArray(w: *std.json.Stringify, items: []const []const u8) !void {
    try w.beginArray();
    for (items) |s| try w.write(s);
    try w.endArray();
}

fn resolveProjectForVerb(
    arena: Allocator,
    io: Io,
    mode: ProjectMode,
    stderr: *Writer,
) !?Project {
    const opts: ValidateOpts = .{ .file = "-", .format = .human, .project_mode = mode };
    const project = resolveProjectMode(arena, io, opts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ProjectFileNotFound => {
            try stderr.writeAll("sjon project: no sjon-project.sjon found.\n");
            return null;
        },
    };
    if (project.root == null or project.file == null) {
        try stderr.writeAll("sjon project: no sjon-project.sjon found.\n");
        return null;
    }
    return project;
}

fn runPluginInfo(gpa: Allocator, io: Io, opts: PluginPathOpts, stdout: *Writer, stderr: *Writer) !u8 {
    return runPluginDescribe(gpa, io, opts, stdout, stderr, .descriptive);
}

fn runPluginCheck(gpa: Allocator, io: Io, opts: PluginPathOpts, stdout: *Writer, stderr: *Writer) !u8 {
    return runPluginDescribe(gpa, io, opts, stdout, stderr, .gating);
}

const PluginDescribeMode = enum { descriptive, gating };

fn runPluginDescribe(
    gpa: Allocator,
    io: Io,
    opts: PluginPathOpts,
    stdout: *Writer,
    stderr: *Writer,
    mode: PluginDescribeMode,
) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const manifest_source = Io.Dir.cwd().readFileAllocOptions(
        io,
        opts.path,
        arena,
        .unlimited,
        .of(u8),
        0,
    ) catch |err| {
        try stderr.print("sjon plugin: cannot read `{s}`: {s}\n", .{ opts.path, @errorName(err) });
        return Exit.usage;
    };

    var tree = sjon.Parser.parse(gpa, manifest_source) catch |err| switch (err) {
        error.OutOfMemory => return Exit.internal_error,
    };
    defer tree.deinit();

    var loaded = sjon.ManifestLoader.load(gpa, tree) catch |err| switch (err) {
        error.OutOfMemory => return Exit.internal_error,
        error.NotAPluginManifest => {
            try stderr.print("sjon plugin: `{s}` is not a (plugin …) manifest\n", .{opts.path});
            return Exit.errors;
        },
    };
    defer loaded.deinit();

    const wasm_path = if (std.mem.endsWith(u8, opts.path, ".sjon"))
        try sjonToPairedWasm(arena, opts.path)
    else
        opts.path;
    const wasm_bytes = Io.Dir.cwd().readFileAlloc(io, wasm_path, arena, .unlimited) catch null;

    var wasm_sha: ?[]const u8 = null;
    if (wasm_bytes) |bytes_for_hash| {
        const Sha256 = std.crypto.hash.sha2.Sha256;
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(bytes_for_hash, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        wasm_sha = try std.fmt.allocPrint(arena, "sha256-{s}", .{hex});
    }

    switch (opts.format) {
        .json => try renderPluginInfoJson(stdout, opts.path, &loaded, wasm_path, wasm_bytes, wasm_sha),
        .human, .rich => try renderPluginInfoHuman(stdout, opts.path, &loaded, wasm_path, wasm_bytes, wasm_sha),
    }

    if (mode == .descriptive) return Exit.ok;
    return if (loaded.hasErrors()) Exit.errors else Exit.ok;
}

fn renderPluginInfoHuman(
    out: *Writer,
    manifest_path: []const u8,
    loaded: *sjon.ManifestLoader.Result,
    wasm_path: []const u8,
    wasm_bytes: ?[]const u8,
    wasm_sha: ?[]const u8,
) !void {
    const p = loaded.plugin;
    try out.print("plugin    {s} {s}\n", .{ p.name, p.version });
    try out.print("manifest  {s}\n", .{manifest_path});
    if (p.license.len > 0) try out.print("license   {s}\n", .{p.license});
    if (p.homepage.len > 0) try out.print("homepage  {s}\n", .{p.homepage});
    if (p.repository.len > 0) try out.print("repo      {s}\n", .{p.repository});
    if (p.authors.len > 0) {
        try out.writeAll("authors  ");
        for (p.authors, 0..) |a, i| {
            if (i > 0) try out.writeAll(",");
            try out.writeAll(" ");
            try out.writeAll(a);
        }
        try out.writeAll("\n");
    }
    if (p.keywords.len > 0) {
        try out.writeAll("keywords ");
        for (p.keywords, 0..) |k, i| {
            if (i > 0) try out.writeAll(",");
            try out.writeAll(" ");
            try out.writeAll(k);
        }
        try out.writeAll("\n");
    }
    try out.print("forms      {d}\n", .{p.forms.len});
    try out.print("value-kinds {d}\n", .{p.value_kinds.len});
    try out.print("expr-funcs  {d}\n", .{p.expr_funcs.len});
    if (wasm_bytes) |b| {
        try out.print("wasm      {s} ({d} bytes) {s}\n", .{ wasm_path, b.len, wasm_sha orelse "" });
    } else {
        try out.writeAll("wasm      <none — declarative-only>\n");
    }
    if (loaded.hasErrors()) {
        try out.writeAll("\nmanifest diagnostics:\n");
        for (loaded.diagnostics) |d| {
            try out.print("  {s}: {s}\n", .{ @tagName(d.code), d.message });
        }
    }
}

fn renderPluginInfoJson(
    out: *Writer,
    manifest_path: []const u8,
    loaded: *sjon.ManifestLoader.Result,
    wasm_path: []const u8,
    wasm_bytes: ?[]const u8,
    wasm_sha: ?[]const u8,
) !void {
    const p = loaded.plugin;
    try out.writeAll("{\"name\":\"");
    try out.writeAll(p.name);
    try out.writeAll("\",\"version\":\"");
    try out.writeAll(p.version);
    try out.writeAll("\",\"manifest\":\"");
    try out.writeAll(manifest_path);
    try out.writeAll("\",\"forms\":");
    try out.print("{d}", .{p.forms.len});
    try out.writeAll(",\"value_kinds\":");
    try out.print("{d}", .{p.value_kinds.len});
    try out.writeAll(",\"expr_funcs\":");
    try out.print("{d}", .{p.expr_funcs.len});
    try out.writeAll(",\"wasm\":");
    if (wasm_bytes) |b| {
        try out.print("{{\"path\":\"{s}\",\"bytes\":{d},\"sha256\":\"{s}\"}}", .{ wasm_path, b.len, wasm_sha orelse "" });
    } else {
        try out.writeAll("null");
    }
    try out.writeAll("}\n");
}

fn runPluginList(gpa: Allocator, io: Io, stdout: *Writer, stderr: *Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const project = discoverProjectAuto(arena, io, "-") catch |err| switch (err) {
        error.OutOfMemory => return Exit.internal_error,
    };
    const project_file = project.file orelse {
        try stderr.writeAll("sjon plugin list: no sjon-project.sjon found in cwd or any parent.\n");
        return Exit.errors;
    };
    const project_root = project.root orelse "";

    var fs = sjon.FilesystemResolver.init(gpa, io, project_root, project_file) catch |err| switch (err) {
        error.OutOfMemory => return Exit.internal_error,
    };
    defer fs.deinit();

    try stdout.writeAll("NAME              VERSION   MANIFEST\n");
    var it = fs.iterateProjectPlugins();
    while (it.next()) |entry| {
        var tree = sjon.Parser.parse(gpa, entry.manifest_source) catch continue;
        defer tree.deinit();
        var loaded = sjon.ManifestLoader.load(gpa, tree) catch continue;
        defer loaded.deinit();
        const v = if (loaded.plugin.version.len > 0) loaded.plugin.version else "?";
        try stdout.print("{s: <18}{s: <10}{s}\n", .{ entry.name, v, entry.manifest_path });
    }
    return Exit.ok;
}

fn runPluginInit(gpa: Allocator, io: Io, opts: PluginInitOpts, stdout: *Writer, stderr: *Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = try renderManifestTemplate(arena, opts.name);

    if (opts.to_stdout) {
        try stdout.writeAll(bytes);
        return Exit.ok;
    }

    if (!opts.force) {
        const exists = blk: {
            Io.Dir.cwd().access(io, opts.output, .{}) catch break :blk false;
            break :blk true;
        };
        if (exists) {
            try stderr.print("sjon plugin init: `{s}` already exists (use --force to overwrite)\n", .{opts.output});
            return Exit.errors;
        }
    }

    var cwd = Io.Dir.cwd();
    cwd.writeFile(io, .{ .sub_path = opts.output, .data = bytes }) catch |err| {
        try stderr.print("sjon plugin init: cannot write `{s}`: {s}\n", .{ opts.output, @errorName(err) });
        return Exit.errors;
    };
    try stdout.print("created {s} (plugin :name {s})\n", .{ opts.output, opts.name });
    return Exit.ok;
}

fn renderManifestTemplate(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena,
        \\; SJON plugin manifest — scaffolded by `sjon plugin init`.
        \\; Pair with a matching `.wasm` for executable expr-funcs, or keep it
        \\; declarative. See docs/AUTHORING.md for the full manifest grammar.
        \\(plugin :name {s} :version "1.0.0"
        \\  (form :name example
        \\    (key :name title :type string)))
        \\
    , .{name});
}

fn runPluginHash(
    gpa: Allocator,
    io: Io,
    opts: PluginHashOpts,
    stdout: *Writer,
    stderr: *Writer,
) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const wasm_path = if (std.mem.endsWith(u8, opts.path, ".sjon"))
        try sjonToPairedWasm(arena, opts.path)
    else
        opts.path;

    const bytes = Io.Dir.cwd().readFileAlloc(io, wasm_path, arena, .unlimited) catch |err| {
        try stderr.print("sjon plugin hash: cannot read `{s}`: {s}\n", .{ wasm_path, @errorName(err) });
        return Exit.usage;
    };

    const Sha256 = std.crypto.hash.sha2.Sha256;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);

    switch (opts.format) {
        .json => {
            try stdout.print(
                "{{\"path\":\"{s}\",\"sha256\":\"sha256-{s}\",\"bytes\":{d}}}\n",
                .{ wasm_path, hex, bytes.len },
            );
        },
        .human, .rich => {
            try stdout.print("sha256-{s}\n", .{hex});
        },
    }
    return Exit.ok;
}

fn runExplain(opts: ExplainOpts, stdout: *Writer, stderr: *Writer) !u8 {
    if (opts.list) return runExplainList(opts.format, stdout);
    const name = opts.code orelse return Exit.usage;
    const entry = Explanations.lookup(name) orelse {
        try stderr.print("sjon explain: unknown code `{s}`\n", .{name});
        return Exit.usage;
    };
    switch (opts.format) {
        .json => {
            try stdout.writeAll("{\"code\":\"");
            try stdout.writeAll(name);
            try stdout.writeAll("\",\"short\":");
            try writeJsonString(stdout, entry.short);
            try stdout.writeAll(",\"long\":");
            try writeJsonString(stdout, entry.long);
            try stdout.writeAll("}\n");
        },
        .human, .rich => {
            try stdout.print("{s}\n  {s}\n", .{ name, entry.short });
            if (entry.long.len > 0) {
                try stdout.writeAll("\n");
                try stdout.writeAll(entry.long);
                if (entry.long[entry.long.len - 1] != '\n') try stdout.writeAll("\n");
            }
        },
    }
    return Exit.ok;
}

fn runExplainList(format: Format, stdout: *Writer) !u8 {
    const entries = Explanations.all();
    switch (format) {
        .json => {
            try stdout.writeAll("[");
            for (entries, 0..) |e, i| {
                if (i > 0) try stdout.writeAll(",");
                try stdout.writeAll("{\"code\":\"");
                try stdout.writeAll(@tagName(e.code));
                try stdout.writeAll("\",\"short\":");
                try writeJsonString(stdout, e.short);
                try stdout.writeAll("}");
            }
            try stdout.writeAll("]\n");
        },
        .human, .rich => {
            for (entries) |e| try stdout.print("{s}  {s}\n", .{ @tagName(e.code), e.short });
        },
    }
    return Exit.ok;
}

fn runCompletions(opts: CompletionsOpts, stdout: *Writer) !u8 {
    switch (opts.shell) {
        .bash => try writeBashCompletions(stdout),
        .zsh => try writeZshCompletions(stdout),
        .fish => try writeFishCompletions(stdout),
    }
    return Exit.ok;
}

fn writeWordList(out: *Writer, words: []const []const u8) !void {
    for (words, 0..) |w, i| {
        if (i != 0) try out.writeByte(' ');
        try out.writeAll(w);
    }
}

fn flagBareName(flag: []const u8) []const u8 {
    var s = flag;
    while (std.mem.startsWith(u8, s, "-")) s = s[1..];
    if (std.mem.endsWith(u8, s, "=")) s = s[0 .. s.len - 1];
    return s;
}

fn writeBashCompletions(out: *Writer) !void {
    try out.writeAll(
        \\# sjon bash completion.
        \\# Generated by `sjon completions bash`. Source it, or install into
        \\# your bash-completion.d directory:
        \\#   sjon completions bash > /usr/local/etc/bash_completion.d/sjon
        \\_sjon() {
        \\    local cur="${COMP_WORDS[COMP_CWORD]}"
        \\    local verbs="
    );
    try writeWordList(out, &top_level_verbs);
    try out.writeAll(
        \\"
        \\    local plugin_subs="
    );
    try writeWordList(out, &plugin_subcommands);
    try out.writeAll(
        \\"
        \\    local project_subs="
    );
    try writeWordList(out, &project_subcommands);
    try out.writeAll(
        \\"
        \\    local flags="
    );
    try writeWordList(out, &common_flags);
    try out.writeAll(
        \\"
        \\
        \\    if [ "$COMP_CWORD" -eq 1 ]; then
        \\        COMPREPLY=( $(compgen -W "$verbs" -- "$cur") )
        \\        return
        \\    fi
        \\
        \\    case "${COMP_WORDS[1]}" in
        \\        plugin)
        \\            if [ "$COMP_CWORD" -eq 2 ]; then
        \\                COMPREPLY=( $(compgen -W "$plugin_subs" -- "$cur") )
        \\                return
        \\            fi
        \\            ;;
        \\        project)
        \\            if [ "$COMP_CWORD" -eq 2 ]; then
        \\                COMPREPLY=( $(compgen -W "$project_subs" -- "$cur") )
        \\                return
        \\            fi
        \\            ;;
        \\    esac
        \\
        \\    if [[ "$cur" == -* ]]; then
        \\        COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
        \\        return
        \\    fi
        \\
        \\    COMPREPLY=( $(compgen -f -- "$cur") )
        \\}
        \\complete -F _sjon sjon
        \\
    );
}

fn writeZshCompletions(out: *Writer) !void {
    try out.writeAll(
        \\#compdef sjon
        \\# sjon zsh completion. Generated by `sjon completions zsh`. Install
        \\# onto your $fpath as `_sjon`, e.g.:
        \\#   sjon completions zsh > "${fpath[1]}/_sjon"
        \\_sjon() {
        \\    local -a verbs plugin_subs project_subs flags
        \\    verbs=(
    );
    try writeWordList(out, &top_level_verbs);
    try out.writeAll(
        \\)
        \\    plugin_subs=(
    );
    try writeWordList(out, &plugin_subcommands);
    try out.writeAll(
        \\)
        \\    project_subs=(
    );
    try writeWordList(out, &project_subcommands);
    try out.writeAll(
        \\)
        \\    flags=(
    );
    try writeWordList(out, &common_flags);
    try out.writeAll(
        \\)
        \\
        \\    if (( CURRENT == 2 )); then
        \\        _describe -t commands 'sjon command' verbs
        \\        return
        \\    fi
        \\
        \\    case "${words[2]}" in
        \\        plugin)
        \\            if (( CURRENT == 3 )); then
        \\                _describe -t commands 'plugin subcommand' plugin_subs
        \\                return
        \\            fi
        \\            ;;
        \\        project)
        \\            if (( CURRENT == 3 )); then
        \\                _describe -t commands 'project subcommand' project_subs
        \\                return
        \\            fi
        \\            ;;
        \\    esac
        \\
        \\    _describe -t options 'option' flags
        \\    _files
        \\}
        \\
        \\_sjon "$@"
        \\
    );
}

fn writeFishCompletions(out: *Writer) !void {
    try out.writeAll(
        \\# sjon fish completion. Generated by `sjon completions fish`. Install
        \\# to ~/.config/fish/completions/sjon.fish:
        \\#   sjon completions fish > ~/.config/fish/completions/sjon.fish
        \\
        \\# Top-level verbs (offered only before a subcommand is given).
        \\complete -c sjon -f -n '__fish_use_subcommand' -a '
    );
    try writeWordList(out, &top_level_verbs);
    try out.writeAll(
        \\'
        \\
        \\# `plugin` subcommands.
        \\complete -c sjon -f -n '__fish_seen_subcommand_from plugin' -a '
    );
    try writeWordList(out, &plugin_subcommands);
    try out.writeAll(
        \\'
        \\
        \\# `project` subcommands.
        \\complete -c sjon -f -n '__fish_seen_subcommand_from project' -a '
    );
    try writeWordList(out, &project_subcommands);
    try out.writeAll(
        \\'
        \\
        \\# Flags. Value-taking flags are marked `-r` (require an argument).
        \\
    );
    for (common_flags) |flag| {
        const bare = flagBareName(flag);
        const takes_value = std.mem.endsWith(u8, flag, "=");
        try out.print("complete -c sjon -l {s}{s}\n", .{ bare, if (takes_value) " -r" else "" });
    }
}

fn sjonToPairedWasm(arena: Allocator, manifest_path: []const u8) Allocator.Error![]const u8 {
    const slash_idx = std.mem.lastIndexOfScalar(u8, manifest_path, '/');
    const base = if (slash_idx) |i| manifest_path[i + 1 ..] else manifest_path;
    if (std.mem.eql(u8, base, "plugin.sjon")) {
        const dir_end = manifest_path.len - "plugin.sjon".len;
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(arena, manifest_path[0..dir_end]);
        try buf.appendSlice(arena, "plugin.wasm");
        return try buf.toOwnedSlice(arena);
    }
    const stem_end = manifest_path.len - ".sjon".len;
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, manifest_path[0..stem_end]);
    try buf.appendSlice(arena, ".wasm");
    return try buf.toOwnedSlice(arena);
}

fn formatRich(
    out: *Writer,
    file_label: []const u8,
    project_file: ?[]const u8,
    source: []const u8,
    diags: []const Host.HostDiagnostic,
    color_enabled: bool,
) !void {
    const styler: Color.Styler = .{ .enabled = color_enabled };
    if (project_file) |path| try out.print("# project: {s}\n", .{path});
    var error_count: usize = 0;
    for (diags) |d| {
        const sev_style: Color.Style = if (d.severity == .err) .red else .yellow;
        try styler.write(out, sev_style);
        try out.writeAll(severityWord(d.severity));
        try styler.write(out, .reset);
        try out.print("[{s}]: {s}\n", .{ @tagName(d.code), d.message });

        try SnippetRenderer.render(out, file_label, source, .{
            .span = d.span,
            .label = "",
            .role = .primary,
        }, &.{}, styler);

        if (d.path.len > 0) {
            try out.writeAll("  at ");
            try writePath(out, d.path);
            try out.print(" (phase: {s})\n", .{@tagName(d.phase)});
        }

        if (d.severity == .err) error_count += 1;
    }
    if (error_count > 0) {
        try styler.write(out, .bold);
        try out.print("{d} error{s}\n", .{ error_count, if (error_count == 1) "" else "s" });
        try styler.write(out, .reset);
    }
}

fn formatHuman(
    out: *Writer,
    file_label: []const u8,
    project_file: ?[]const u8,
    source: []const u8,
    diags: []const Host.HostDiagnostic,
) !void {
    if (project_file) |path| try out.print("# project: {s}\n", .{path});
    var error_count: usize = 0;
    for (diags) |d| {
        const lc = indexToLineCol(source, d.span.start);
        try out.print("{s}:{d}:{d}: {s}: {s}: {s}\n", .{
            file_label,
            lc.line,
            lc.column,
            severityWord(d.severity),
            @tagName(d.code),
            d.message,
        });
        if (d.path.len > 0) {
            try out.writeAll("  at ");
            try writePath(out, d.path);
            try out.print(" (phase: {s}", .{@tagName(d.phase)});
            if (d.phase == .manifest) {
                if (d.declaration_span) |ds| {
                    const dlc = indexToLineCol(source, ds.start);
                    try out.print(", in declaration at {d}:{d}", .{ dlc.line, dlc.column });
                }
            }
            try out.writeAll(")\n");
        }
        if (d.severity == .err) error_count += 1;
    }
    if (error_count > 0) {
        try out.print("{d} error{s}\n", .{ error_count, if (error_count == 1) "" else "s" });
    }
}

fn severityWord(s: Ast.Diagnostic.Severity) []const u8 {
    return switch (s) {
        .err => "error",
        .warning => "warning",
    };
}

fn writePath(out: *Writer, path: []const []const u8) !void {
    for (path, 0..) |seg, i| {
        if (i > 0) try out.writeAll("/");
        try out.writeAll(seg);
    }
}

fn formatJson(
    out: *Writer,
    file_label: []const u8,
    project_file: ?[]const u8,
    source: []const u8,
    diags: []const Host.HostDiagnostic,
) !void {
    var w: std.json.Stringify = .{
        .writer = out,
        .options = .{ .whitespace = .indent_2 },
    };
    try w.beginObject();
    try w.objectField("file");
    try w.write(file_label);
    try w.objectField("project_file");
    if (project_file) |p| try w.write(p) else try w.write(null);
    try w.objectField("diagnostics");
    try w.beginArray();
    for (diags) |d| {
        try w.beginObject();
        try w.objectField("phase");
        try w.write(@tagName(d.phase));
        try w.objectField("code");
        try w.write(@tagName(d.code));
        try w.objectField("severity");
        try w.write(severityWord(d.severity));
        try w.objectField("message");
        try w.write(d.message);
        try w.objectField("span");
        try writeSpanJson(&w, source, d.span);
        try w.objectField("path");
        try w.beginArray();
        for (d.path) |seg| try w.write(seg);
        try w.endArray();
        try w.objectField("declaration_span");
        if (d.declaration_span) |ds| {
            try writeSpanJson(&w, source, ds);
        } else {
            try w.write(null);
        }
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();
    try out.writeByte('\n');
}

fn writeSpanJson(w: *std.json.Stringify, source: []const u8, span: Ast.Span) !void {
    const lc = indexToLineCol(source, span.start);
    try w.beginObject();
    try w.objectField("start");
    try w.write(span.start);
    try w.objectField("end");
    try w.write(span.end);
    try w.objectField("line");
    try w.write(lc.line);
    try w.objectField("column");
    try w.write(lc.column);
    try w.endObject();
}

fn runExportSchema(
    gpa: Allocator,
    io: Io,
    opts: ExportSchemaOpts,
    stdout: *Writer,
    stderr: *Writer,
) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const validate_opts: ValidateOpts = .{
        .file = opts.file,
        .format = .human,
        .project_mode = opts.project_mode,
    };
    const project = resolveProjectMode(arena, io, validate_opts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ProjectFileNotFound => {
            const dir = opts.project_mode.explicit;
            try stderr.print(
                "sjon: error: project_file_not_found: --project-root {s} has no sjon-project.sjon\n",
                .{dir},
            );
            return Exit.usage;
        },
    };

    const source = loadSource(gpa, io, opts.file) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| {
            try stderr.print("sjon: cannot read {s}: {s}\n", .{ opts.file, @errorName(e) });
            return Exit.usage;
        },
    };
    defer gpa.free(source);

    const file_label = if (std.mem.eql(u8, opts.file, "-")) "<stdin>" else opts.file;

    var bundle = try Host.exportSchemaFromSource(gpa, source, .{
        .failure_policy = .strict,
        .project_root = project.root,
        .project_file = project.file,
        .io = if (project.root != null) io else null,
    }, .{
        .target = .{
            .json_schema = opts.target == .json_schema or opts.target == .both,
            .ts_types = opts.target == .typescript or opts.target == .both,
            .intermediate = opts.target == .intermediate,
        },
        .layout = opts.layout,
    });
    defer bundle.deinit();

    if (bundle.host_result.diagnostics.len > 0) {
        try formatHuman(stderr, file_label, project.file, source, bundle.host_result.diagnostics);
    }

    try emitExport(arena, io, opts, &bundle, stdout, stderr);

    return if (bundle.hasErrors()) Exit.errors else Exit.ok;
}

fn runExportLoweringGraph(
    gpa: Allocator,
    io: Io,
    opts: ExportLoweringGraphOpts,
    stdout: *Writer,
    stderr: *Writer,
) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const validate_opts: ValidateOpts = .{
        .file = opts.file,
        .format = .human,
        .project_mode = opts.project_mode,
    };
    const project = resolveProjectMode(arena, io, validate_opts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ProjectFileNotFound => {
            const dir = opts.project_mode.explicit;
            try stderr.print(
                "sjon: error: project_file_not_found: --project-root {s} has no sjon-project.sjon\n",
                .{dir},
            );
            return Exit.usage;
        },
    };

    const source = loadSource(gpa, io, opts.file) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| {
            try stderr.print("sjon: cannot read {s}: {s}\n", .{ opts.file, @errorName(e) });
            return Exit.usage;
        },
    };
    defer gpa.free(source);

    const file_label = if (std.mem.eql(u8, opts.file, "-")) "<stdin>" else opts.file;

    var bundle = try Host.exportLoweringGraphFromSource(gpa, source, .{
        .failure_policy = .strict,
        .project_root = project.root,
        .project_file = project.file,
        .io = if (project.root != null) io else null,
    });
    defer bundle.deinit();

    if (bundle.host_result.diagnostics.len > 0) {
        try formatHuman(stderr, file_label, project.file, source, bundle.host_result.diagnostics);
    }

    try stdout.writeAll(bundle.sjon);

    return if (bundle.hasErrors()) Exit.errors else Exit.ok;
}

fn emitExport(
    arena: Allocator,
    io: Io,
    opts: ExportSchemaOpts,
    bundle: *Host.ExportSchemaBundle,
    stdout: *Writer,
    stderr: *Writer,
) !void {
    const er = &bundle.export_result;
    const to_stdout = std.mem.eql(u8, opts.output, "-");

    for (er.warnings) |wn| {
        try stderr.print("sjon export-schema: [{s} {s}] {s}\n", .{ @tagName(wn.severity), @tagName(wn.code), wn.message });
    }

    if (to_stdout) {
        switch (opts.target) {
            .json_schema => try stdout.writeAll(er.json_schema_bytes.?),
            .typescript => try stdout.writeAll(er.ts_types_bytes.?),
            .intermediate => try stdout.writeAll(er.intermediate_bytes.?),
            .both => {
                try stdout.writeAll("{\n  \"jsonSchema\": ");
                try writeJsonString(stdout, er.json_schema_bytes.?);
                try stdout.writeAll(",\n  \"tsTypes\": ");
                try writeJsonString(stdout, er.ts_types_bytes.?);
                try stdout.writeAll("\n}\n");
            },
        }
        return;
    }

    try writeFileTargets(arena, io, opts.output, er);
}

fn writeFileTargets(
    arena: Allocator,
    io: Io,
    dir: []const u8,
    er: *SchemaExport.ExportResult,
) !void {
    var cwd = Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch |err| switch (err) {
        else => return err,
    };
    if (er.per_plugin) |arts| {
        for (arts) |art| {
            if (art.json_schema_bytes) |bytes| {
                const path = try std.fmt.allocPrint(arena, "{s}/{s}.schema.json", .{ dir, art.plugin });
                try writeFile(io, path, bytes);
            }
            if (art.ts_types_bytes) |bytes| {
                const path = try std.fmt.allocPrint(arena, "{s}/{s}.d.ts", .{ dir, art.plugin });
                try writeFile(io, path, bytes);
            }
            if (art.intermediate_bytes) |bytes| {
                const path = try std.fmt.allocPrint(arena, "{s}/{s}.export.json", .{ dir, art.plugin });
                try writeFile(io, path, bytes);
            }
        }
        if (er.ts_types_bytes != null) {
            const barrel = try buildIndexBarrel(arena, arts);
            const path = try std.fmt.allocPrint(arena, "{s}/index.d.ts", .{dir});
            try writeFile(io, path, barrel);
        }
        return;
    }
    if (er.json_schema_bytes) |bytes| {
        const path = try std.fmt.allocPrint(arena, "{s}/schema.json", .{dir});
        try writeFile(io, path, bytes);
    }
    if (er.ts_types_bytes) |bytes| {
        const path = try std.fmt.allocPrint(arena, "{s}/types.d.ts", .{dir});
        try writeFile(io, path, bytes);
    }
    if (er.intermediate_bytes) |bytes| {
        const path = try std.fmt.allocPrint(arena, "{s}/export.json", .{dir});
        try writeFile(io, path, bytes);
    }
}

fn buildIndexBarrel(
    arena: Allocator,
    arts: []const SchemaExport.Model.PerPluginArtifact,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "// Generated by sjon — per-plugin barrel.\n");
    for (arts) |art| {
        try buf.appendSlice(arena, "export * from \"./");
        try buf.appendSlice(arena, art.plugin);
        try buf.appendSlice(arena, "\";\n");
    }
    return buf.toOwnedSlice(arena);
}

fn writeFile(io: Io, path: []const u8, bytes: []const u8) !void {
    var cwd = Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn writeJsonString(out: *Writer, s: []const u8) !void {
    var stringify: std.json.Stringify = .{ .writer = out };
    try stringify.write(s);
}

const LineCol = struct { line: u32, column: u32 };

fn indexToLineCol(source: []const u8, index: u32) LineCol {
    var line: u32 = 1;
    var line_start: usize = 0;
    const stop = @min(@as(usize, index), source.len);
    var i: usize = 0;
    while (i < stop) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .line = line, .column = @as(u32, @intCast(stop - line_start)) + 1 };
}
