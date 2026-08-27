//! `sjon validate` CLI — argument parsing, document loading, diagnostic
//! rendering. The thin entry in `main.zig` wires real stdio + argv into
//! `run`; the in-source tests in `Cli_tests.zig` drive `run` directly with
//! constructed argv arrays and `Writer.Allocating` buffers, so no
//! subprocess spawning is needed for end-to-end coverage.

const std = @import("std");
const sjon = @import("sjon");
const Host = sjon.Host;
const Binary = sjon.Binary;
const Ast = sjon.Ast;
const Schema = sjon.Schema;
const SchemaExport = sjon.SchemaExport;
const Glob = sjon.Glob;
const CappedRead = sjon.CappedRead;
const Explanations = sjon.Explanations;
const Completions = @import("Completions.zig");
const DiagnosticFormat = @import("DiagnosticFormat.zig");
const ValueText = @import("ValueText.zig");
const WatchSet = @import("WatchSet.zig");
const ShareLink = @import("ShareLink.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;

/// Everything `run` can propagate out to `main.zig`, which collapses all
/// of it to the documented internal-error exit (3).
///
/// The set is deliberately narrow, and the narrowness is the contract: a
/// verb reports the *user's* problem as a diagnostic and an exit code,
/// never as a Zig error. A missing or unreadable file becomes a message
/// on stderr (`loadSource`); a malformed document becomes collected
/// diagnostics. What escapes is only what no verb can act on — the
/// allocator gave up (`OutOfMemory`), the output channel died
/// (`WriteFailed`), or an evaluation ceiling tripped on input the
/// validator had already accepted: `DepthExceeded` / `MemoryBudgetExceeded`
/// from `Expr`, `HapBudgetExceeded` / `TickOverflow` from the pattern
/// layer (`PatternQuery` and `Pattern`).
///
/// Naming the set instead of leaving it inferred is what makes that a
/// contract rather than a description: a verb that begins propagating
/// something new stops compiling here, where the choice — render it as a
/// diagnostic, or widen this set on purpose — has to be made.
pub const Error = Allocator.Error || Writer.Error || error{
    DepthExceeded,
    MemoryBudgetExceeded,
    HapBudgetExceeded,
    TickOverflow,
};

/// Concrete output format. `human` is the existing GCC-style
/// (FILE:LINE:COL: severity: code: message) line format kept for
/// grep/awk pipelines. `rich` adds source snippets, secondary spans,
/// and hint footers. `json` emits a structured envelope for tooling.
pub const Format = enum { human, rich, json, github };

/// Format-policy selector — what `--format=` parses to. `auto` (the
/// default) resolves via `resolveFormat`: rich on a TTY, human when
/// piped, so scripts parsing today's line format see no change. The
/// explicit values force a format the way `--color=always|never`
/// force color.
pub const FormatPolicy = enum { auto, human, rich, json, github };

/// Color-policy selector. `auto` honors `NO_COLOR` / TTY detection;
/// `always` and `never` force the behavior (`resolveColor`).
pub const ColorPolicy = enum { auto, always, never };

pub const Exit = struct {
    pub const ok: u8 = 0;
    pub const errors: u8 = 1;
    pub const usage: u8 = 2;
    /// Internal error — OOM, IO failures the CLI couldn't otherwise
    /// classify, and anything `run` propagates (`src/cli/main.zig`
    /// catches it into this code rather than letting a raw error trace
    /// exit 1, which was indistinguishable from "validation errors").
    /// Distinct from `.usage` (user-fixable) and `.errors`
    /// (input-fixable).
    pub const internal_error: u8 = 3;
};

// ---------------------------------------------------------------------
// Completion verb tables — the single source of truth for both the
// dispatcher and the generated shell-completion scripts. `runCompletions`
// renders these into every script, so a script can never advertise a
// verb the table doesn't list; `Cli_tests.zig` asserts in the other
// direction (every entry round-trips through `parseArgs`, and every
// entry appears in each generated script). Add a verb here and the
// drift guard fails until the dispatcher recognises it too.
// ---------------------------------------------------------------------

/// Every top-level verb the dispatcher recognises (`parseArgs`). Order
/// is presentation-only.
pub const top_level_verbs = [_][]const u8{
    "check",   "validate", "export-schema", "export-lowering-graph",
    "explain", "plugin",   "project",       "completions",
    "fmt",     "eval",     "query",         "effective",
    "repl",    "share",
};

/// `sjon plugin <SUB>` subcommands (`parsePluginArgs`).
pub const plugin_subcommands = [_][]const u8{ "hash", "info", "check", "list", "init", "test" };

/// `sjon project <SUB>` subcommands (`parseProjectArgs`).
pub const project_subcommands = [_][]const u8{ "info", "verify", "lock", "sync" };

/// Common flags worth completing. Value-taking flags keep their `=`
/// suffix (bash/zsh complete `--flag=`; fish marks them `-r`). The
/// drift guard checks each flag's bare name (sans `--` / `=`) so the
/// representation can differ per shell.
pub const common_flags = [_][]const u8{
    "--format=", "--color=",  "--project-root=", "--no-project",
    "--target=", "--output=", "--layout=",       "--draft=",
    "--stdout",  "--force",   "--check",         "--list",
    "--watch",   "--help",
};

/// The tables above, bundled as slices for the `Completions` renderers.
/// `Cli` remains the single source of truth; `Completions` is a pure
/// consumer.
const completion_vocab: Completions.Vocabulary = .{
    .top_level_verbs = &top_level_verbs,
    .plugin_subcommands = &plugin_subcommands,
    .project_subcommands = &project_subcommands,
    .common_flags = &common_flags,
};

const usage_text =
    \\Usage:
    \\  sjon [check] FILE...            Check documents or the current project.
    \\                                  `check` is the default verb; bare `sjon`
    \\                                  and `sjon FILE.sjon` both route here.
    \\                                  --watch re-runs on any change to the
    \\                                  project's .sjon files (manifests too,
    \\                                  so a schema edit re-checks everything;
    \\                                  poll interval via --interval-ms=N).
    \\  sjon validate FILE              Validate a single SJON document.
    \\  sjon validate -                 Validate from stdin.
    \\  sjon eval FILE                  Validate, then print each expression
    \\  sjon eval -                     root's value (stdout is data only;
    \\                                  diagnostics go to stderr).
    \\  sjon effective FILE             Validate, then print the document
    \\  sjon effective -                with omitted defaults spliced in.
    \\                                  diff <(sjon effective a) <(sjon effective b)
    \\                                  compares what documents mean.
    \\  sjon repl                       Interactive loop: expressions print
    \\                                  their values, forms validate against
    \\                                  the project schema. :help inside.
    \\  sjon share DOC [SCHEMA...]      Print a playground deep link for a
    \\  sjon share -                    document (+ optional schema tabs).
    \\                                  Encodes bytes, validates nothing —
    \\                                  sharing a broken repro is the point.
    \\                                  --base=URL overrides the site.
    \\  sjon query FILE --begin=N --end=N [--seed=N]
    \\                                  Query the document's pattern over a
    \\                                  tick window (720720 ticks per cycle)
    \\                                  and print the (haps …) it produces.
    \\  sjon export-schema FILE         Export the document's plugin schema
    \\                                  as JSON Schema 2020-12 / TypeScript.
    \\  sjon export-lowering-graph FILE Render the document's :lowering
    \\                                  :produces DAG as SJON to stdout.
    \\  sjon fmt PATH...                Reformat documents in place,
    \\                                  preserving comments.
    \\  sjon fmt -                      Format stdin to stdout.
    \\  sjon explain CODE               Explain a diagnostic code; --list for
    \\                                  the full catalogue.
    \\  sjon plugin SUB ...             Plugin manifest tools: hash | info |
    \\                                  check | list | init | test.
    \\  sjon plugin test MANIFEST       Run the manifest's schema tests:
    \\    [--dir=PATH]                  <case>.sjon + <case>.expected.sjon
    \\                                  pairs (the conformance-corpus
    \\                                  expectation format) under tests/
    \\                                  beside the manifest, or --dir.
    \\  sjon project SUB ...            Project-file tools: info | verify |
    \\                                  lock | sync.
    \\  sjon completions SHELL          Print a shell-completion script
    \\                                  (bash | zsh | fish) to stdout.
    \\  sjon --help, -h                 Show this help.
    \\
    \\Options for validate:
    \\  --format=<auto|human|rich|json|github>
    \\                                  Output format. auto (the default)
    \\                                  renders rich on a terminal and the
    \\                                  grep-stable human lines when piped;
    \\                                  github emits ::error/::warning
    \\                                  workflow annotations for CI.
    \\  --color=<auto|always|never>     Colorize rich output; NO_COLOR and
    \\                                  SJON_NO_COLOR force it off (default: auto).
    \\  --project-root=DIR              Force the project root (DIR must
    \\    or --project-root DIR         contain sjon-project.sjon).
    \\  --no-project                    Disable project-file discovery
    \\                                  entirely; (use-plugin …) refs
    \\                                  fail with unresolved_plugin.
    \\
    \\Options for fmt:
    \\  --check                         Report which files would change,
    \\                                  write nothing, exit 1 if any would.
    \\  --format=<auto|human|rich|json> Format for parse-error output.
    \\                                  fmt never validates, so only parse
    \\                                  diagnostics ever appear.
    \\                                  Diagnostics go to stderr, keeping
    \\                                  stdout a clean data channel for
    \\                                  `sjon fmt -`.
    \\
    \\Options for export-schema:
    \\  --target=<json-schema|typescript|both|intermediate|markdown>
    \\                                  Output target (default: both —
    \\                                  markdown is asked for by name).
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
    \\The --project-root / --no-project flags apply to every verb that
    \\does project discovery — check, validate, export-schema,
    \\export-lowering-graph, project info|verify|lock|sync, and
    \\plugin info|check — in both the =-joined and space-separated form.
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
    \\  3  Internal error (I/O failure, plugin fault, or out of memory).
    \\
;

pub const ProjectMode = union(enum) {
    /// Walk up from FILE's directory looking for sjon-project.sjon.
    auto,
    /// Use the given DIR as project root; sjon-project.sjon must exist.
    explicit: []const u8,
    /// Disable project discovery and the default filesystem resolver.
    disabled,
};

const Action = union(enum) {
    help,
    usage_error: []const u8,
    /// Argument parsing itself failed for a reason the user cannot fix by
    /// editing their argv — today only OOM while collecting a variadic
    /// positional list. Routing that through `usage_error` printed the
    /// full usage text and exited 2, telling the user to fix a command
    /// line that was already correct.
    internal_error: []const u8,
    validate: ValidateOpts,
    export_schema: ExportSchemaOpts,
    export_lowering_graph: ExportLoweringGraphOpts,
    plugin_hash: PluginHashOpts,
    plugin_info: PluginPathOpts,
    plugin_check: PluginPathOpts,
    plugin_list,
    plugin_init: PluginInitOpts,
    plugin_test: PluginTestOpts,
    project_info: ProjectVerbOpts,
    project_verify: ProjectVerbOpts,
    project_lock: ProjectVerbOpts,
    project_sync: ProjectSyncOpts,
    check: CheckOpts,
    explain: ExplainOpts,
    completions: CompletionsOpts,
    fmt: FmtOpts,
    eval: EvalOpts,
    query: QueryOpts,
    effective: EffectiveOpts,
    share: ShareOpts,
    repl: ReplOpts,
};

/// `sjon fmt PATH…` — reformat documents in place.
///
/// No project-resolution knobs, unlike every other file-taking verb:
/// formatting is purely syntactic (parse → print), so it never resolves
/// `(use-plugin …)` refs and a project file would tell it nothing.
pub const FmtOpts = struct {
    /// Files to format. `"-"` means stdin→stdout (CP2).
    paths: []const []const u8 = &.{},
    /// Report which files would change, write nothing, exit non-zero
    /// if any would. Mirrors `project sync --check`.
    check: bool = false,
    format: FormatPolicy = .auto,
};

/// Shell dialect for `sjon completions`.
pub const Shell = enum { bash, zsh, fish };

pub const CompletionsOpts = struct {
    shell: Shell,
};

pub const CheckOpts = struct {
    /// Optional explicit document arguments. When empty, the project
    /// file's `:documents` glob list is used.
    documents: []const []const u8 = &.{},
    format: FormatPolicy = .auto,
    project_mode: ProjectMode = .auto,
    /// Re-run the check whenever any `.sjon` under the project root
    /// changes (mtime+size poll over `WatchSet`). Project-aware by
    /// construction: manifests and `sjon-project.sjon` are in the
    /// watched set, so a schema edit re-checks every document (C3).
    watch: bool = false,
    /// Poll interval for `--watch`, in milliseconds.
    interval_ms: u64 = 250,
};

/// Shared options for the read-only `sjon project info|verify` verbs.
pub const ProjectVerbOpts = struct {
    format: FormatPolicy = .auto,
    project_mode: ProjectMode = .auto,
};

/// `sjon project sync` — the write-side complement to `verify`. Same
/// project-resolution knobs plus `--check` (dry-run: report drift, never
/// write, exit non-zero when out of date).
pub const ProjectSyncOpts = struct {
    format: FormatPolicy = .auto,
    project_mode: ProjectMode = .auto,
    check: bool = false,
};

/// Shared shape for `sjon plugin info|check PATH` — both take one
/// manifest path and the global format flag.
pub const PluginPathOpts = struct {
    path: []const u8,
    format: FormatPolicy = .auto,
    project_mode: ProjectMode = .auto,
};

pub const PluginHashOpts = struct {
    /// Path to a `.sjon` (hashes the paired `.wasm`) or `.wasm` file
    /// directly. The CLI hands `.sjon` paths to the resolver's pairing
    /// rules; `.wasm` paths are hashed directly.
    path: []const u8,
    format: FormatPolicy = .auto,
};

pub const PluginInitOpts = struct {
    /// Plugin `:name` for the scaffold — a bare symbol (validated in the
    /// parser).
    name: []const u8,
    /// Destination path. Default mirrors the canonical `plugin.sjon`
    /// convention the resolver pairs with `plugin.wasm`.
    output: []const u8 = "plugin.sjon",
    /// Overwrite an existing file at `output` instead of refusing.
    force: bool = false,
    /// Print the scaffold to stdout instead of writing a file.
    to_stdout: bool = false,
};

/// `sjon plugin test MANIFEST [--dir=PATH]` — run the manifest's schema
/// tests: `<case>.sjon` documents validated against the manifest (+core,
/// via the F9 preload path) and compared against sibling
/// `<case>.expected.sjon` files in the conformance corpus's expectation
/// format — same parser (`ConformanceExpected`), same `(code, severity,
/// path)` in-order comparison.
pub const PluginTestOpts = struct {
    /// Manifest path (`plugin.sjon`).
    path: []const u8,
    /// Case directory. Null = `tests/` beside the manifest.
    dir: ?[]const u8 = null,
};

pub const ExplainOpts = struct {
    /// Diagnostic-code name (e.g. `"unresolved_plugin"`) — null when
    /// the user passed `--list`.
    code: ?[]const u8 = null,
    /// True when `--list` was passed; prints one-line summary for
    /// every code.
    list: bool = false,
    format: FormatPolicy = .auto,
};

const ValidateOpts = struct {
    /// Source path — `"-"` means stdin.
    file: []const u8,
    format: FormatPolicy = .auto,
    color: ColorPolicy = .auto,
    project_mode: ProjectMode = .auto,
};

/// `sjon eval FILE|-` — validate, then print each expression root's
/// evaluated value. Channel policy is `fmt`'s, not `validate`'s:
/// stdout carries only the data product, diagnostics go to stderr,
/// and a document with errors yields zero stdout bytes.
pub const EvalOpts = struct {
    /// Source path — `"-"` means stdin.
    file: []const u8,
    format: FormatPolicy = .auto,
    project_mode: ProjectMode = .auto,
};

/// `sjon effective FILE|-` — validate, then print the source with every
/// form's omitted defaults spliced in (`sjon.EffectiveDocument.render`,
/// the same splicer the LSP's effective-document view uses). A document
/// with nothing to splice prints byte-identically to its input. Same
/// channel policy as `eval`.
pub const EffectiveOpts = struct {
    /// Source path — `"-"` means stdin.
    file: []const u8,
    format: FormatPolicy = .auto,
    project_mode: ProjectMode = .auto,
};

/// `sjon repl` — line-buffered interactive loop. Deliberately dumb
/// about terminals in v1: no raw mode, no history, no completion; the
/// prompt is suppressed when stdin is not a TTY so piped transcripts
/// stay clean and deterministic. Every entry is independent — no
/// session bindings (`let` is entry-local by the language's own
/// scoping); a persistent binding store is a language-adjacent
/// decision this verb must not back into.
pub const ReplOpts = struct {
    format: FormatPolicy = .auto,
    project_mode: ProjectMode = .auto,
};

/// `sjon share DOC [SCHEMA…]` — print a playground deep link. `-`
/// reads the document from stdin (schemas stay paths). No validation
/// gate: `share` encodes bytes, and a broken document is exactly what
/// a repro link is for.
pub const ShareOpts = struct {
    /// Document path — `"-"` means stdin.
    doc: []const u8,
    /// Schema-tab sources, in playground tab order.
    schemas: []const []const u8 = &.{},
    base: []const u8 = ShareLink.DEFAULT_BASE,
};

/// `sjon query FILE --begin=N --end=N [--seed=N]` — query the document's
/// single pattern root over a tick window. Ticks mirror the
/// `sjon_query_pattern` ABI (i64, `PatternQuery.PPC` = 720720 per
/// cycle); `--seed` defaults to 0. No format/project knobs: patterns
/// compile against the fixed core+pattern schema, and the two-shape
/// `(haps …)` / `(diagnostics …)` text is already machine-stable.
pub const QueryOpts = struct {
    file: []const u8,
    begin: i64,
    end: i64,
    seed: i64 = 0,
};

pub const ExportTarget = enum { json_schema, typescript, both, intermediate, markdown };

const ExportSchemaOpts = struct {
    file: []const u8,
    target: ExportTarget = .both,
    /// `"-"` means stdout.
    output: []const u8 = "-",
    layout: SchemaExport.Layout = .aggregated,
    project_mode: ProjectMode = .auto,
};

/// `sjon export-lowering-graph FILE` — render the document's aggregate
/// `:lowering :produces` DAG as SJON to stdout. No target/layout knobs:
/// the graph is a single SJON artifact. Shares the project-mode flags so
/// `(use-plugin …)` refs resolve like the other verbs.
const ExportLoweringGraphOpts = struct {
    file: []const u8,
    project_mode: ProjectMode = .auto,
};

/// Environment knobs the CLI cares about beyond the regular argv/stdio.
/// Today: TTY-state for color heuristics, plus pre-resolved values of
/// `NO_COLOR` / `SJON_NO_COLOR`. main.zig reads the real environment
/// once at startup; tests can pass `.{}` to opt into the "no TTY, no
/// env" defaults.
pub const RunEnv = struct {
    /// True when `stdout` points at a terminal. Drives `--color=auto`.
    /// Defaults to false so tests don't accidentally enable color.
    stdout_is_tty: bool = false,
    /// `NO_COLOR` present and non-empty in the environment.
    no_color: bool = false,
    /// `SJON_NO_COLOR` present and non-empty.
    sjon_no_color: bool = false,
    /// True when `stdin` points at a terminal. Drives the REPL's
    /// prompt/banner suppression so piped transcripts stay clean.
    stdin_is_tty: bool = false,
    /// Iteration bound for `check --watch`'s poll loop, from
    /// `SJON_WATCH_TICKS`. Null (unset) = watch forever; tests inject a
    /// bound so the loop terminates deterministically.
    watch_ticks: ?usize = null,
};

/// Resolve the color policy against the RunEnv snapshot. `--color=auto`
/// honors TTY + the two env vars; `always` / `never` short-circuit.
fn resolveColor(policy: ColorPolicy, env: RunEnv) bool {
    return switch (policy) {
        .always => true,
        .never => false,
        .auto => env.stdout_is_tty and !env.no_color and !env.sjon_no_color,
    };
}

/// Resolve the format policy against the RunEnv snapshot. Explicit
/// values win; `.auto` picks the rich renderer exactly when stdout is
/// a terminal, so pipes keep the byte-stable human line format.
/// `NO_COLOR` does not demote rich to human — it only strips color
/// (`resolveColor`); the snippet frames themselves are not color.
fn resolveFormat(policy: FormatPolicy, env: RunEnv) Format {
    return switch (policy) {
        .human => .human,
        .rich => .rich,
        .json => .json,
        .github => .github,
        .auto => if (env.stdout_is_tty) .rich else .human,
    };
}

/// Drive the whole CLI. Returns the exit code; never calls
/// `std.process.exit` so tests can read the value back.
pub fn run(
    gpa: Allocator,
    io: Io,
    args: []const [:0]const u8,
    stdout: *Writer,
    stderr: *Writer,
    env: RunEnv,
) Error!u8 {
    var arg_arena = std.heap.ArenaAllocator.init(gpa);
    defer arg_arena.deinit();
    const action = parseArgs(arg_arena.allocator(), args);
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
        .internal_error => |msg| {
            try stderr.print("sjon: internal error: {s}\n", .{msg});
            return Exit.internal_error;
        },
        .validate => |opts| return runValidate(gpa, io, opts, stdout, stderr, env),
        .export_schema => |opts| return runExportSchema(gpa, io, opts, stdout, stderr),
        .export_lowering_graph => |opts| return runExportLoweringGraph(gpa, io, opts, stdout, stderr),
        .plugin_hash => |opts| return runPluginHash(gpa, io, opts, stdout, stderr, env),
        .plugin_info => |opts| return runPluginInfo(gpa, io, opts, stdout, stderr, env),
        .plugin_check => |opts| return runPluginCheck(gpa, io, opts, stdout, stderr, env),
        .plugin_list => return runPluginList(gpa, io, stdout, stderr),
        .plugin_init => |opts| return runPluginInit(gpa, io, opts, stdout, stderr),
        .plugin_test => |opts| return runPluginTest(gpa, io, opts, stdout, stderr),
        .project_info => |opts| return runProjectInfo(gpa, io, opts, stdout, stderr, env),
        .project_verify => |opts| return runProjectVerify(gpa, io, opts, stdout, stderr),
        .project_lock => |opts| return runProjectLock(gpa, io, opts, stdout, stderr),
        .project_sync => |opts| return runProjectSync(gpa, io, opts, stdout, stderr, env),
        .check => |opts| return runCheck(gpa, io, opts, stdout, stderr, env),
        .explain => |opts| return runExplain(opts, stdout, stderr, env),
        .completions => |opts| return runCompletions(opts, stdout),
        .fmt => |opts| return runFmt(gpa, io, opts, stdout, stderr, env),
        .eval => |opts| return runEval(gpa, io, opts, stdout, stderr, env),
        .query => |opts| return runQuery(gpa, io, opts, stdout, stderr),
        .effective => |opts| return runEffective(gpa, io, opts, stdout, stderr, env),
        .share => |opts| return runShare(gpa, io, opts, stdout, stderr),
        .repl => |opts| return runRepl(gpa, io, opts, stdout, stderr, env),
    }
}

const ProjectFlag = enum { explicit_kw, no_project_kw };

/// Distinguish "user passed both --project-root and --no-project" from
/// "user passed --project-root twice." Both are usage errors but the
/// message should match the actual mistake.
fn projectModeAlreadySetUsage(current: ProjectMode, incoming: ProjectFlag) ?Action {
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

/// Outcome of a per-flag parser (`parseProjectFlag`, `parseFormatFlag`).
/// `handled` — the flag (and, for the space-form `--project-root DIR`,
/// the following argument) was consumed and `i` advanced; the caller
/// should `continue`. `unhandled` — the arg isn't this flag; the caller
/// keeps looking. `usage` — a usage error the caller must return
/// immediately.
const FlagResult = union(enum) {
    handled,
    unhandled,
    usage: Action,
};

/// Parse the three project-resolution flags every project-doing verb
/// shares — `--project-root=DIR`, the space-form `--project-root DIR`,
/// and `--no-project` — enforcing the duplicate / mutual-exclusion guard
/// (`projectModeAlreadySetUsage`) uniformly. Advances `i` past a consumed
/// space-form argument. `validate`, `check`, `export-schema`,
/// `export-lowering-graph`, `project …`, and `plugin info|check` route
/// their arg loop through this so the grammar can't drift between verbs.
/// (`--format` stays per-verb: it's already uniform, and
/// `export-lowering-graph` deliberately has no format knob.)
fn parseProjectFlag(
    args: []const [:0]const u8,
    i: *usize,
    project_mode: *ProjectMode,
) FlagResult {
    const arg: []const u8 = args[i.*];
    if (std.mem.startsWith(u8, arg, "--project-root=")) {
        if (projectModeAlreadySetUsage(project_mode.*, .explicit_kw)) |e| return .{ .usage = e };
        const dir = arg["--project-root=".len..];
        if (dir.len == 0) return .{ .usage = .{ .usage_error = "--project-root requires a directory" } };
        project_mode.* = .{ .explicit = dir };
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--project-root")) {
        if (projectModeAlreadySetUsage(project_mode.*, .explicit_kw)) |e| return .{ .usage = e };
        i.* += 1;
        if (i.* >= args.len) return .{ .usage = .{ .usage_error = "--project-root requires a directory" } };
        // Refuse to swallow a following flag-looking arg as the path — a
        // typo like `--project-root --no-project` would otherwise walk
        // away with a nonsensical directory.
        if (std.mem.startsWith(u8, args[i.*], "--")) {
            return .{ .usage = .{ .usage_error = "--project-root requires a directory (got a flag instead)" } };
        }
        project_mode.* = .{ .explicit = args[i.*] };
        return .handled;
    }
    if (std.mem.eql(u8, arg, "--no-project")) {
        if (projectModeAlreadySetUsage(project_mode.*, .no_project_kw)) |e| return .{ .usage = e };
        project_mode.* = .disabled;
        return .handled;
    }
    return .unhandled;
}

/// Parse `--format=<value>`, the flag ten verbs share. Same three-way
/// result as `parseProjectFlag`, for the same reason: the call sites
/// differ in what surrounds it, not in how it is read.
///
/// `allow_github` is the only axis they actually varied on — `github`
/// emits per-diagnostic workflow annotations, which only mean something
/// for the two document-checking verbs — and it now also picks the error
/// message. That fixes a small lie: `validate` accepts `github` and told
/// anyone who mistyped a format that it expected `auto|human|rich|json`,
/// because the message had been copied in from a verb that doesn't.
fn parseFormatFlag(arg: []const u8, format: *FormatPolicy, allow_github: bool) FlagResult {
    if (!std.mem.startsWith(u8, arg, "--format=")) return .unhandled;
    const value = arg["--format=".len..];
    const parsed = parseFormat(value) orelse return .{ .usage = .{
        .usage_error = if (allow_github)
            "unknown --format value (expected auto|human|rich|json|github)"
        else
            "unknown --format value (expected auto|human|rich|json)",
    } };
    if (parsed == .github and !allow_github) return .{ .usage = .{ .usage_error = github_only_usage } };
    format.* = parsed;
    return .handled;
}

/// What every `--format` verb's argument loop collects. Which of these
/// fields is meaningful is the verb's business (`VerbShape`); collecting
/// them is not.
const VerbArgs = struct {
    format: FormatPolicy = .auto,
    color: ColorPolicy = .auto,
    project_mode: ProjectMode = .auto,
    positional: ?[]const u8 = null,
};

/// The grammar of one verb, as the differences between seven
/// near-identical argument loops.
const VerbShape = struct {
    /// argv index this verb's own arguments start at — 2 for a top-level
    /// verb (`sjon eval …`), 3 for a subcommand (`sjon plugin info …`).
    start: usize,
    /// Whether `--format=github` is accepted (`validate` and `check`).
    allow_github: bool = false,
    /// Whether `--color=` is accepted (`validate` only).
    allow_color: bool = false,
    /// Whether the verb takes a positional at all. When false, one is
    /// reported as an extra argument rather than collected.
    allow_positional: bool = true,
    /// Whether the project-resolution flags are accepted.
    allow_project: bool = true,
};

const VerbParse = union(enum) {
    ok: VerbArgs,
    usage: Action,
};

/// Parse the shared argument loop: `--format=`, optionally `--color=`,
/// the project flags, an unknown-option guard, and at most one
/// positional.
///
/// Seven verbs wrote this out, differing only in `VerbShape`'s five
/// fields and in the message for a missing positional — which stays with
/// the caller, because that message is the one part that genuinely
/// differs per verb ("eval requires a FILE argument (use - for stdin)"
/// against "`sjon plugin hash` requires a PATH argument"). Everything
/// above it was copies, which is how `validate`'s `--format` error came
/// to advertise a format set that wasn't its own.
fn parseVerbArgs(args: []const [:0]const u8, shape: VerbShape) VerbParse {
    var out: VerbArgs = .{};
    var i: usize = shape.start;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        switch (parseFormatFlag(arg, &out.format, shape.allow_github)) {
            .handled => continue,
            .usage => |e| return .{ .usage = e },
            .unhandled => {},
        }
        if (shape.allow_color and std.mem.startsWith(u8, arg, "--color=")) {
            out.color = parseColor(arg["--color=".len..]) orelse return .{ .usage = .{
                .usage_error = "unknown --color value (expected auto|always|never)",
            } };
            continue;
        }
        if (shape.allow_project) {
            switch (parseProjectFlag(args, &i, &out.project_mode)) {
                .handled => continue,
                .usage => |e| return .{ .usage = e },
                .unhandled => {},
            }
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return .{ .usage = .{ .usage_error = "unknown option" } };
        }
        if (!shape.allow_positional or out.positional != null) {
            return .{ .usage = .{ .usage_error = "extra positional argument" } };
        }
        out.positional = arg;
    }
    return .{ .ok = out };
}

fn parseArgs(allocator: Allocator, args: []const [:0]const u8) Action {
    // args[0] is the program name. Skip it.
    if (args.len < 2) {
        // Default-verb dispatch (Slice 11): `sjon` alone in a project
        // directory routes to `sjon check`. The actual project-file
        // walk happens inside `runCheck` — if walk fails, the check
        // command itself emits the user-facing message. Keeping the
        // route here means the default UX is "do the obvious thing"
        // without forcing the user to type `check`.
        return .{ .check = .{} };
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        return .help;
    }
    if (std.mem.eql(u8, cmd, "export-schema")) return parseExportSchemaArgs(args);
    if (std.mem.eql(u8, cmd, "export-lowering-graph")) return parseExportLoweringGraphArgs(args);
    if (std.mem.eql(u8, cmd, "plugin")) return parsePluginArgs(args);
    if (std.mem.eql(u8, cmd, "check")) return parseCheckArgs(allocator, args);
    if (std.mem.eql(u8, cmd, "project")) return parseProjectArgs(args);
    if (std.mem.eql(u8, cmd, "explain")) return parseExplainArgs(args);
    if (std.mem.eql(u8, cmd, "completions")) return parseCompletionsArgs(args);
    if (std.mem.eql(u8, cmd, "fmt")) return parseFmtArgs(allocator, args);
    if (std.mem.eql(u8, cmd, "eval")) return parseEvalArgs(args);
    if (std.mem.eql(u8, cmd, "query")) return parseQueryArgs(args);
    if (std.mem.eql(u8, cmd, "effective")) return parseEffectiveArgs(args);
    if (std.mem.eql(u8, cmd, "share")) return parseShareArgs(allocator, args);
    if (std.mem.eql(u8, cmd, "repl")) return parseReplArgs(args);
    // If the first positional doesn't match a known verb AND doesn't
    // look like a flag, treat it as a `sjon check FILE` invocation —
    // matches the plan's "do the obvious thing" UX for `sjon foo.sjon`.
    if (!std.mem.eql(u8, cmd, "validate") and !std.mem.startsWith(u8, cmd, "-")) {
        return parseImplicitCheck(allocator, args);
    }
    if (!std.mem.eql(u8, cmd, "validate")) {
        return .{ .usage_error = "unknown command" };
    }

    const parsed = switch (parseVerbArgs(args, .{ .start = 2, .allow_github = true, .allow_color = true })) {
        .ok => |v| v,
        .usage => |e| return e,
    };
    const path = parsed.positional orelse
        return .{ .usage_error = "validate requires a FILE argument (use - for stdin)" };
    return .{ .validate = .{
        .file = path,
        .format = parsed.format,
        .color = parsed.color,
        .project_mode = parsed.project_mode,
    } };
}

fn parseReplArgs(args: []const [:0]const u8) Action {
    const parsed = switch (parseVerbArgs(args, .{ .start = 2, .allow_positional = false })) {
        .ok => |v| v,
        .usage => |e| return e,
    };
    return .{ .repl = .{ .format = parsed.format, .project_mode = parsed.project_mode } };
}

fn parseShareArgs(allocator: Allocator, args: []const [:0]const u8) Action {
    var doc: ?[]const u8 = null;
    var schemas: std.ArrayList([]const u8) = .empty;
    var base: []const u8 = ShareLink.DEFAULT_BASE;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.startsWith(u8, arg, "--base=")) {
            base = arg["--base=".len..];
            if (base.len == 0) return .{ .usage_error = "--base requires a URL" };
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return .{ .usage_error = "unknown option" };
        }
        if (doc == null) {
            doc = arg;
        } else {
            schemas.append(allocator, arg) catch return .{ .internal_error = "out of memory collecting arguments" };
        }
    }
    const d = doc orelse return .{ .usage_error = "share requires a DOC argument (use - for stdin)" };
    return .{ .share = .{ .doc = d, .schemas = schemas.items, .base = base } };
}

fn parseQueryArgs(args: []const [:0]const u8) Action {
    var file: ?[]const u8 = null;
    var begin: ?i64 = null;
    var end: ?i64 = null;
    var seed: i64 = 0;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.startsWith(u8, arg, "--begin=")) {
            begin = std.fmt.parseInt(i64, arg["--begin=".len..], 10) catch
                return .{ .usage_error = "--begin expects an integer tick" };
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--end=")) {
            end = std.fmt.parseInt(i64, arg["--end=".len..], 10) catch
                return .{ .usage_error = "--end expects an integer tick" };
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--seed=")) {
            seed = std.fmt.parseInt(i64, arg["--seed=".len..], 10) catch
                return .{ .usage_error = "--seed expects an integer" };
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return .{ .usage_error = "unknown option" };
        }
        if (file != null) return .{ .usage_error = "extra positional argument" };
        file = arg;
    }
    const path = file orelse return .{ .usage_error = "query requires a FILE argument" };
    const b = begin orelse return .{ .usage_error = "query requires --begin=<tick> and --end=<tick>" };
    const e = end orelse return .{ .usage_error = "query requires --begin=<tick> and --end=<tick>" };
    if (b > e) return .{ .usage_error = "--begin must not exceed --end" };
    return .{ .query = .{ .file = path, .begin = b, .end = e, .seed = seed } };
}

fn parseEffectiveArgs(args: []const [:0]const u8) Action {
    const parsed = switch (parseVerbArgs(args, .{ .start = 2 })) {
        .ok => |v| v,
        .usage => |e| return e,
    };
    const path = parsed.positional orelse
        return .{ .usage_error = "effective requires a FILE argument (use - for stdin)" };
    return .{ .effective = .{
        .file = path,
        .format = parsed.format,
        .project_mode = parsed.project_mode,
    } };
}

fn parseEvalArgs(args: []const [:0]const u8) Action {
    const parsed = switch (parseVerbArgs(args, .{ .start = 2 })) {
        .ok => |v| v,
        .usage => |e| return e,
    };
    const path = parsed.positional orelse
        return .{ .usage_error = "eval requires a FILE argument (use - for stdin)" };
    return .{ .eval = .{
        .file = path,
        .format = parsed.format,
        .project_mode = parsed.project_mode,
    } };
}

/// Map a `--format=<value>` argument to its policy tag (`auto` is
/// accepted for symmetry with `--color=auto`). Returns null on invalid
/// input so the caller can emit the precise usage error.
fn parseFormat(value: []const u8) ?FormatPolicy {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "human")) return .human;
    if (std.mem.eql(u8, value, "rich")) return .rich;
    if (std.mem.eql(u8, value, "json")) return .json;
    if (std.mem.eql(u8, value, "github")) return .github;
    return null;
}

/// `--format=github` emits per-diagnostic workflow annotations, which
/// only mean something for the two document-checking verbs. Everything
/// else rejects it at parse time with this message.
const github_only_usage = "--format=github is only valid for check and validate";

/// Map a `--color=<value>` argument to its enum tag. Same return
/// contract as `parseFormat`.
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
    if (args.len < 3) return .{ .usage_error = "`sjon plugin` requires a subcommand (hash | info | check | list | init | test)" };
    const sub = args[2];
    if (std.mem.eql(u8, sub, "hash")) return parsePluginHashArgs(args);
    if (std.mem.eql(u8, sub, "info")) return parsePluginPathArgs(args, "info");
    if (std.mem.eql(u8, sub, "check")) return parsePluginPathArgs(args, "check");
    if (std.mem.eql(u8, sub, "list")) return parsePluginListArgs(args);
    if (std.mem.eql(u8, sub, "init")) return parsePluginInitArgs(args);
    if (std.mem.eql(u8, sub, "test")) return parsePluginTestArgs(args);
    return .{ .usage_error = "unknown `sjon plugin` subcommand" };
}

fn parsePluginPathArgs(args: []const [:0]const u8, sub: []const u8) Action {
    const parsed = switch (parseVerbArgs(args, .{ .start = 3 })) {
        .ok => |v| v,
        .usage => |e| return e,
    };
    const format = parsed.format;
    const project_mode = parsed.project_mode;
    const p = parsed.positional orelse {
        if (std.mem.eql(u8, sub, "info"))
            return .{ .usage_error = "`sjon plugin info` requires a PATH" };
        return .{ .usage_error = "`sjon plugin check` requires a PATH" };
    };
    const opts: PluginPathOpts = .{ .path = p, .format = format, .project_mode = project_mode };
    if (std.mem.eql(u8, sub, "info")) return .{ .plugin_info = opts };
    return .{ .plugin_check = opts };
}

fn parsePluginListArgs(args: []const [:0]const u8) Action {
    // `plugin list` takes no positional args. Accept `--format` for
    // forward compat with the json mode.
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

/// A scaffold `:name` is restricted to a plain identifier so the
/// generated manifest is always parseable — every example plugin name
/// (`double`, `kit-xor`, `enum-rich`, …) fits this charset. The grammar
/// permits richer symbols, but a scaffold shouldn't emit one that needs
/// escaping.
fn isValidPluginName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

fn parseImplicitCheck(allocator: Allocator, args: []const [:0]const u8) Action {
    // The first positional is part of the document list — start the
    // walk at i=1 so it's captured, not consumed as a verb.
    return parseCheckArgsFrom(allocator, args, 1);
}

fn parseCheckArgs(allocator: Allocator, args: []const [:0]const u8) Action {
    return parseCheckArgsFrom(allocator, args, 2);
}

fn parseCheckArgsFrom(allocator: Allocator, args: []const [:0]const u8, start: usize) Action {
    var format: FormatPolicy = .auto;
    var project_mode: ProjectMode = .auto;
    var docs: std.ArrayList([]const u8) = .empty;
    var watch = false;
    var interval_ms: u64 = 250;
    var i: usize = start;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--watch")) {
            watch = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--interval-ms=")) {
            interval_ms = std.fmt.parseInt(u64, arg["--interval-ms=".len..], 10) catch
                return .{ .usage_error = "--interval-ms expects a millisecond count" };
            if (interval_ms == 0) return .{ .usage_error = "--interval-ms must be at least 1" };
            continue;
        }
        switch (parseFormatFlag(arg, &format, true)) {
            .handled => continue,
            .usage => |e| return e,
            .unhandled => {},
        }
        switch (parseProjectFlag(args, &i, &project_mode)) {
            .handled => continue,
            .usage => |e| return e,
            .unhandled => {},
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return .{ .usage_error = "unknown option" };
        }
        docs.append(allocator, arg) catch return .{ .internal_error = "out of memory collecting arguments" };
    }
    return .{ .check = .{
        .documents = docs.items,
        .format = format,
        .project_mode = project_mode,
        .watch = watch,
        .interval_ms = interval_ms,
    } };
}

fn parseFmtArgs(allocator: Allocator, args: []const [:0]const u8) Action {
    var opts: FmtOpts = .{};
    var paths: std.ArrayList([]const u8) = .empty;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        switch (parseFormatFlag(arg, &opts.format, false)) {
            .handled => continue,
            .usage => |e| return e,
            .unhandled => {},
        }
        if (std.mem.eql(u8, arg, "--check")) {
            opts.check = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return .{ .usage_error = "unknown option" };
        }
        paths.append(allocator, arg) catch return .{ .internal_error = "out of memory collecting arguments" };
    }
    if (paths.items.len == 0) {
        return .{ .usage_error = "fmt requires at least one PATH (use - for stdin)" };
    }
    opts.paths = paths.items;
    return .{ .fmt = opts };
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
    const parsed = switch (parseVerbArgs(args, .{ .start = 3, .allow_positional = false })) {
        .ok => |v| v,
        .usage => |e| return e,
    };
    const opts: ProjectVerbOpts = .{ .format = parsed.format, .project_mode = parsed.project_mode };
    if (std.mem.eql(u8, sub, "info")) return .{ .project_info = opts };
    if (std.mem.eql(u8, sub, "lock")) return .{ .project_lock = opts };
    return .{ .project_verify = opts };
}

fn parseProjectSyncArgs(args: []const [:0]const u8) Action {
    var format: FormatPolicy = .auto;
    var project_mode: ProjectMode = .auto;
    var check = false;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        switch (parseFormatFlag(arg, &format, false)) {
            .handled => continue,
            .usage => |e| return e,
            .unhandled => {},
        }
        switch (parseProjectFlag(args, &i, &project_mode)) {
            .handled => continue,
            .usage => |e| return e,
            .unhandled => {},
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

fn parsePluginTestArgs(args: []const [:0]const u8) Action {
    var path: ?[]const u8 = null;
    var dir: ?[]const u8 = null;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.startsWith(u8, arg, "--dir=")) {
            dir = arg["--dir=".len..];
            if (dir.?.len == 0) return .{ .usage_error = "--dir requires a path" };
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return .{ .usage_error = "unknown option" };
        }
        if (path != null) return .{ .usage_error = "extra positional argument" };
        path = arg;
    }
    const p = path orelse return .{ .usage_error = "`sjon plugin test` requires a MANIFEST argument" };
    return .{ .plugin_test = .{ .path = p, .dir = dir } };
}

fn parsePluginHashArgs(args: []const [:0]const u8) Action {
    const parsed = switch (parseVerbArgs(args, .{ .start = 3, .allow_project = false })) {
        .ok => |v| v,
        .usage => |e| return e,
    };
    const p = parsed.positional orelse
        return .{ .usage_error = "`sjon plugin hash` requires a PATH argument" };
    return .{ .plugin_hash = .{ .path = p, .format = parsed.format } };
}

fn parseExplainArgs(args: []const [:0]const u8) Action {
    var code: ?[]const u8 = null;
    var list = false;
    var format: FormatPolicy = .auto;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--list")) {
            list = true;
            continue;
        }
        switch (parseFormatFlag(arg, &format, false)) {
            .handled => continue,
            .usage => |e| return e,
            .unhandled => {},
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
            } else if (std.mem.eql(u8, value, "markdown")) {
                target = .markdown;
            } else {
                return .{ .usage_error = "unknown --target value (expected json-schema|typescript|both|intermediate|markdown)" };
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
        switch (parseProjectFlag(args, &i, &project_mode)) {
            .handled => continue,
            .usage => |e| return e,
            .unhandled => {},
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
        switch (parseProjectFlag(args, &i, &project_mode)) {
            .handled => continue,
            .usage => |e| return e,
            .unhandled => {},
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
            // .explicit DIR was passed but DIR/sjon-project.sjon is missing.
            // Emit the diagnostic code name so machine consumers (and the
            // diagnostic-coverage audit) can grep for it.
            const dir = opts.project_mode.explicit;
            try stderr.print(
                "sjon: error: project_file_not_found: --project-root {s} has no sjon-project.sjon\n",
                .{dir},
            );
            return Exit.usage;
        },
    };

    const source = loadSource(gpa, io, opts.file) catch |err| switch (err) {
        // OOM is a real failure — propagate so `main`'s wrapper turns it
        // into the documented exit 3, rather than masquerading as a
        // usage error the reader is told to fix in their argv.
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
    switch (resolveFormat(opts.format, env)) {
        .human => try DiagnosticFormat.formatHuman(stdout, file_label, project.file, source, result.diagnostics),
        .rich => try DiagnosticFormat.formatRich(stdout, arena, file_label, project.file, source, result.diagnostics, &result.schema, result.project_plugin_names, color_enabled),
        .json => try DiagnosticFormat.formatJson(stdout, arena, file_label, project.file, source, result.diagnostics, &result.schema, result.project_plugin_names),
        .github => try DiagnosticFormat.formatGithub(stdout, file_label, source, result.diagnostics),
    }

    return if (result.hasErrors()) Exit.errors else Exit.ok;
}

// ---------------------------------------------------------------------
// `sjon eval` — devx A3. The terminal twin of the playground's
// evaluated-values panel: `Host.validateDocument` already evaluates
// every expression root, so this verb only renders `evaluated_results`
// — one `<head>: <value>` line per root (canonical SJON via
// `ValueText`), or the corpus `expected.values.json` object shape
// under `--format=json`.
// ---------------------------------------------------------------------

fn runEval(gpa: Allocator, io: Io, opts: EvalOpts, stdout: *Writer, stderr: *Writer, env: RunEnv) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const format = resolveFormat(opts.format, env);

    const validate_opts: ValidateOpts = .{ .file = opts.file, .project_mode = opts.project_mode };
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

    var result = try Host.validateDocument(gpa, source, .{
        .failure_policy = .strict,
        .project_root = project.root,
        .project_file = project.file,
        .io = if (project.root != null) io else null,
    });
    defer result.deinit();

    // Diagnostics — errors and warnings alike — render on stderr so
    // stdout stays a pure data channel; errors also suppress the data
    // product entirely (a broken document piped somewhere must yield
    // zero stdout bytes).
    if (result.diagnostics.len > 0) {
        switch (format) {
            .human, .github => try DiagnosticFormat.formatHuman(stderr, file_label, project.file, source, result.diagnostics),
            .rich => try DiagnosticFormat.formatRich(stderr, arena, file_label, project.file, source, result.diagnostics, &result.schema, result.project_plugin_names, resolveColor(.auto, env)),
            .json => try DiagnosticFormat.formatJson(stderr, arena, file_label, project.file, source, result.diagnostics, &result.schema, result.project_plugin_names),
        }
    }
    if (result.hasErrors()) return Exit.errors;

    switch (format) {
        .human, .rich, .github => {
            var buf: std.ArrayList(u8) = .empty;
            for (result.evaluated_results) |ev| {
                buf.clearRetainingCapacity();
                try ValueText.append(&buf, arena, ev.value);
                const hdr = result.tree.formHeader(result.data_forest[ev.forest_index]);
                if (hdr.namespace) |ns| {
                    try stdout.print("{s}/{s}: {s}\n", .{ ns, hdr.head, buf.items });
                } else {
                    try stdout.print("{s}: {s}\n", .{ hdr.head, buf.items });
                }
            }
        },
        .json => {
            // Byte-compatible with the corpus `expected.values.json`
            // siblings (`tools/gen_expected_values.zig`): object keyed
            // by decimal forest index (already ascending — the eval
            // pass walks the forest in order), values through the
            // `wasm_common.appendValue` envelope encoding.
            var buf: std.ArrayList(u8) = .empty;
            try buf.appendSlice(arena, "{\n");
            for (result.evaluated_results, 0..) |ev, i| {
                var key_buf: [24]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "{d}", .{ev.forest_index}) catch unreachable;
                try buf.appendSlice(arena, "  \"");
                try buf.appendSlice(arena, key);
                try buf.appendSlice(arena, "\": ");
                try sjon.wasm_common.appendValue(&buf, arena, ev.value);
                if (i + 1 < result.evaluated_results.len) try buf.append(arena, ',');
                try buf.append(arena, '\n');
            }
            try buf.appendSlice(arena, "}\n");
            try stdout.writeAll(buf.items);
        },
    }
    return Exit.ok;
}

// ---------------------------------------------------------------------
// `sjon effective` — devx A5. Validate, then print the source with the
// materialized-defaults overlay spliced in via
// `sjon.EffectiveDocument.render` — the same splicer the LSP's
// effective-document view uses, so the two surfaces cannot disagree. A
// document with nothing to splice prints byte-identically to its input.
// ---------------------------------------------------------------------

fn runEffective(gpa: Allocator, io: Io, opts: EffectiveOpts, stdout: *Writer, stderr: *Writer, env: RunEnv) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const format = resolveFormat(opts.format, env);

    const validate_opts: ValidateOpts = .{ .file = opts.file, .project_mode = opts.project_mode };
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

    var result = try Host.validateDocument(gpa, source, .{
        .failure_policy = .strict,
        .project_root = project.root,
        .project_file = project.file,
        .io = if (project.root != null) io else null,
    });
    defer result.deinit();

    // Same channel policy as `eval`: diagnostics on stderr, and errors
    // suppress the data product — a broken document piped somewhere
    // must yield zero stdout bytes.
    if (result.diagnostics.len > 0) {
        switch (format) {
            .human, .github => try DiagnosticFormat.formatHuman(stderr, file_label, project.file, source, result.diagnostics),
            .rich => try DiagnosticFormat.formatRich(stderr, arena, file_label, project.file, source, result.diagnostics, &result.schema, result.project_plugin_names, resolveColor(.auto, env)),
            .json => try DiagnosticFormat.formatJson(stderr, arena, file_label, project.file, source, result.diagnostics, &result.schema, result.project_plugin_names),
        }
    }
    if (result.hasErrors()) return Exit.errors;

    const effective = try sjon.EffectiveDocument.render(
        arena,
        source,
        &result.tree,
        &result.materialized_defaults,
        &result.schema,
    );
    try stdout.writeAll(effective);
    return Exit.ok;
}

// ---------------------------------------------------------------------
// `sjon repl` — devx F1. Line-buffered eval/validate loop. Each
// balanced entry runs through `Host.validateDocument` — one call
// yields both the validation diagnostics (a pasted form against the
// project schema) and `evaluated_results` (expression roots), so the
// REPL and `sjon eval` can never disagree. Safe by construction: Expr
// is pure and step/depth/byte-budgeted.
// ---------------------------------------------------------------------

/// Delimiter-balance scanner for entry accumulation — comment- and
/// string-aware bracket counting, not a parse. `;` comments run to end
/// of line; `"…"` strings are single-line (an unterminated one resets
/// at the line break and the real parser reports it); `"""…"""` blocks
/// span lines.
const ReplBalance = struct {
    depth: i64 = 0,
    mode: enum { normal, string, triple } = .normal,

    fn feedLine(self: *ReplBalance, line: []const u8) void {
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            switch (self.mode) {
                .string => switch (c) {
                    '\\' => i += 1,
                    '"' => self.mode = .normal,
                    else => {},
                },
                .triple => {
                    if (c == '"' and i + 2 < line.len and line[i + 1] == '"' and line[i + 2] == '"') {
                        self.mode = .normal;
                        i += 2;
                    }
                },
                .normal => switch (c) {
                    ';' => return, // comment to end of line
                    '"' => {
                        if (i + 2 < line.len and line[i + 1] == '"' and line[i + 2] == '"') {
                            self.mode = .triple;
                            i += 2;
                        } else {
                            self.mode = .string;
                        }
                    },
                    '(', '[' => self.depth += 1,
                    ')', ']' => self.depth -= 1,
                    else => {},
                },
            }
        }
        // A plain string cannot span lines — reset and let the parser
        // report the unterminated literal.
        if (self.mode == .string) self.mode = .normal;
    }

    fn complete(self: *const ReplBalance) bool {
        return self.mode == .normal and self.depth <= 0;
    }
};

// A miscount here is a hang-class bug — the interactive loop waits for
// a close that already happened — and the piped-transcript tests can't
// see it (EOF salvages the entry either way), so the scanner is pinned
// directly.
test "ReplBalance: brackets inside strings and comments do not count" {
    var b: ReplBalance = .{};
    b.feedLine("(f \"(\") ; (also (ignored");
    try std.testing.expect(b.complete());

    var esc: ReplBalance = .{};
    esc.feedLine("(s \"a\\\"b(\")");
    try std.testing.expect(esc.complete());
}

test "ReplBalance: triple-quoted blocks span lines and shield brackets" {
    var b: ReplBalance = .{};
    b.feedLine("(note \"\"\"");
    try std.testing.expect(!b.complete());
    b.feedLine("mid ) not counted");
    try std.testing.expect(!b.complete());
    b.feedLine("\"\"\")");
    try std.testing.expect(b.complete());
}

test "ReplBalance: an unterminated plain string resets at the line break" {
    var b: ReplBalance = .{};
    b.feedLine("(s \"unterminated");
    try std.testing.expect(!b.complete());
    b.feedLine(")");
    try std.testing.expect(b.complete());
}

test "ReplBalance: vectors count like parens" {
    var b: ReplBalance = .{};
    b.feedLine("(v [1");
    try std.testing.expect(!b.complete());
    b.feedLine("2])");
    try std.testing.expect(b.complete());
}

fn runRepl(gpa: Allocator, io: Io, opts: ReplOpts, stdout: *Writer, stderr: *Writer, env: RunEnv) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const format = resolveFormat(opts.format, env);

    const validate_opts: ValidateOpts = .{ .file = "-", .project_mode = opts.project_mode };
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

    const interactive = env.stdin_is_tty;
    if (interactive) {
        if (project.file) |pf| {
            try stdout.print("sjon repl — project {s} (try :help, :quit exits)\n", .{pf});
        } else {
            try stdout.writeAll("sjon repl — core vocabulary only, no project loaded (try :help, :quit exits)\n");
        }
    }

    const line_buf = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(line_buf);
    var stdin_file = Io.File.stdin();
    var stdin_reader = stdin_file.reader(io, line_buf);

    var entry: std.ArrayList(u8) = .empty;
    defer entry.deinit(gpa);
    var bal: ReplBalance = .{};
    var last_entry: ?[:0]const u8 = null;

    if (interactive) {
        try stdout.writeAll("sjon> ");
        try stdout.flush();
    }
    while (true) {
        // A read failure is not an EOF: swallowing it would end the
        // session with exit 0 and no explanation — a paste one byte
        // past the line buffer must say so, not look like a clean quit.
        const maybe_line = stdin_reader.interface.takeDelimiter('\n') catch |err| {
            try stdout.flush();
            try stderr.print("sjon repl: {s}\n", .{switch (err) {
                error.StreamTooLong => "input line exceeds the 64 KiB line buffer",
                error.ReadFailed => "reading stdin failed",
            }});
            return Exit.errors;
        };
        const line = maybe_line orelse break;
        if (entry.items.len == 0) {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0 and trimmed[0] == ':') {
                if (std.mem.eql(u8, trimmed, ":quit")) break;
                try runReplCommand(gpa, io, arena, trimmed, project, last_entry, stdout);
                try stdout.flush();
                if (interactive) {
                    try stdout.writeAll("sjon> ");
                    try stdout.flush();
                }
                continue;
            }
        }
        try entry.appendSlice(gpa, line);
        try entry.append(gpa, '\n');
        bal.feedLine(line);
        if (bal.complete()) {
            const has_content = std.mem.trim(u8, entry.items, " \t\r\n").len > 0;
            if (has_content) {
                const source = try arena.dupeZ(u8, entry.items);
                last_entry = source;
                try runReplEntry(gpa, io, arena, source, project, stdout, env, format);
                try stdout.flush();
            }
            entry.clearRetainingCapacity();
            bal = .{};
            if (interactive) {
                try stdout.writeAll("sjon> ");
                try stdout.flush();
            }
        }
    }
    // A trailing unbalanced entry at EOF still runs — the parser's
    // unclosed-delimiter diagnostic is the useful goodbye.
    if (std.mem.trim(u8, entry.items, " \t\r\n").len > 0) {
        const source = try arena.dupeZ(u8, entry.items);
        try runReplEntry(gpa, io, arena, source, project, stdout, env, format);
    }
    try stdout.flush();
    return Exit.ok;
}

/// One balanced entry: validate (schema-aware), report diagnostics,
/// print each evaluated expression root's value.
fn runReplEntry(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    source: [:0]const u8,
    project: Project,
    stdout: *Writer,
    env: RunEnv,
    format: Format,
) !void {
    var result = try Host.validateDocument(gpa, source, .{
        .failure_policy = .strict,
        .project_root = project.root,
        .project_file = project.file,
        .io = if (project.root != null) io else null,
    });
    defer result.deinit();

    if (result.diagnostics.len > 0) {
        // The transcript is the conversation — everything on stdout.
        switch (format) {
            .human, .github => try DiagnosticFormat.formatHuman(stdout, "<repl>", null, source, result.diagnostics),
            .rich => try DiagnosticFormat.formatRich(stdout, arena, "<repl>", null, source, result.diagnostics, &result.schema, result.project_plugin_names, resolveColor(.auto, env)),
            .json => try DiagnosticFormat.formatJson(stdout, arena, "<repl>", null, source, result.diagnostics, &result.schema, result.project_plugin_names),
        }
    }
    if (result.hasErrors()) return;

    var buf: std.ArrayList(u8) = .empty;
    for (result.evaluated_results) |ev| {
        buf.clearRetainingCapacity();
        try ValueText.append(&buf, arena, ev.value);
        try stdout.print("{s}\n", .{buf.items});
    }
}

/// `:commands` other than `:quit` (handled by the loop). v1 set per the
/// plan: `:help`, `:schema`, `:explain CODE`, `:load` is deferred to
/// the project flags. Unknown commands get a pointer, not a parse.
fn runReplCommand(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    cmd: []const u8,
    project: Project,
    last_entry: ?[:0]const u8,
    stdout: *Writer,
) !void {
    if (std.mem.eql(u8, cmd, ":help")) {
        try stdout.writeAll(
            \\:help          this list
            \\:schema        loaded plugins and their form heads
            \\:explain CODE  the diagnostic catalogue entry for CODE
            \\:query B E [S] query the last entry as a pattern over ticks
            \\               [B, E] with seed S (720720 ticks per cycle)
            \\:quit          exit (EOF works too)
            \\anything else  a balanced SJON entry: expressions print their
            \\               values, forms validate against the loaded schema
            \\
        );
        return;
    }
    if (std.mem.eql(u8, cmd, ":schema")) {
        // The vocabulary at a glance: every project-indexed plugin and
        // its form heads. Core is always in scope and unlisted noise.
        var lp = try Host.loadProject(gpa, .{
            .project_root = project.root,
            .project_file = project.file,
            .io = if (project.root != null) io else null,
        });
        defer lp.deinit();
        var listed: usize = 0;
        for (lp.plugins) |p| {
            if (std.mem.eql(u8, p.name, "core")) continue;
            try stdout.print("{s}", .{p.name});
            if (p.version.len > 0) try stdout.print(" {s}", .{p.version});
            try stdout.writeAll(":");
            for (p.forms) |f| try stdout.print(" ({s} …)", .{f.name});
            try stdout.writeAll("\n");
            listed += 1;
        }
        if (listed == 0) try stdout.writeAll("core vocabulary only — no project plugins loaded\n");
        return;
    }
    if (std.mem.startsWith(u8, cmd, ":explain ")) {
        const name = std.mem.trim(u8, cmd[":explain ".len..], " \t");
        const entry = Explanations.lookup(name) orelse {
            try stdout.print("unknown code `{s}` (see :explain --list via `sjon explain --list`)\n", .{name});
            return;
        };
        try writeExplanation(stdout, name, entry);
        return;
    }
    if (std.mem.startsWith(u8, cmd, ":query")) {
        const rest = std.mem.trim(u8, cmd[":query".len..], " \t");
        var it = std.mem.tokenizeAny(u8, rest, " \t");
        const begin_txt = it.next() orelse {
            try stdout.writeAll("usage: :query BEGIN END [SEED] (ticks; 720720 per cycle)\n");
            return;
        };
        const end_txt = it.next() orelse {
            try stdout.writeAll("usage: :query BEGIN END [SEED] (ticks; 720720 per cycle)\n");
            return;
        };
        const seed_txt = it.next();
        const begin = std.fmt.parseInt(i64, begin_txt, 10) catch {
            try stdout.writeAll(":query expects integer ticks\n");
            return;
        };
        const end = std.fmt.parseInt(i64, end_txt, 10) catch {
            try stdout.writeAll(":query expects integer ticks\n");
            return;
        };
        const seed: i64 = if (seed_txt) |t| std.fmt.parseInt(i64, t, 10) catch {
            try stdout.writeAll(":query expects an integer seed\n");
            return;
        } else 0;
        if (begin > end) {
            try stdout.writeAll(":query BEGIN must not exceed END\n");
            return;
        }
        const source = last_entry orelse {
            try stdout.writeAll("nothing to query yet — enter a pattern first\n");
            return;
        };
        var tree = try sjon.Parser.parse(gpa, source);
        defer tree.deinit();
        if (tree.hasErrors() or tree.root.len != 1) {
            try stdout.writeAll(":query needs the last entry to be one well-formed pattern\n");
            return;
        }
        var result = sjon.PatternQuery.queryTree(
            gpa,
            &tree,
            tree.root[0],
            pattern_schema,
            .{ .begin = begin, .end = end },
            seed,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A budget trip is an ordinary bad `:query` argument, not a
            // reason to end the session: propagating it here unwound the
            // whole REPL loop and exited.
            else => |e| {
                try stdout.print(":query failed: {s}\n", .{queryBudgetMessage(e)});
                return;
            },
        };
        defer result.deinit();
        const text = try sjon.PatternQuery.resultToText(arena, result);
        try stdout.writeAll(text);
        try stdout.writeAll("\n");
        return;
    }
    try stdout.print("unknown command `{s}` (try :help)\n", .{cmd});
}

// ---------------------------------------------------------------------
// `sjon share` — devx D2. A local file becomes a live-validating repro
// link: bytes through the hash-state codec, no parsing, no gate.
// ---------------------------------------------------------------------

fn runShare(gpa: Allocator, io: Io, opts: ShareOpts, stdout: *Writer, stderr: *Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = loadSource(gpa, io, opts.doc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| {
            try stderr.print("sjon: cannot read {s}: {s}\n", .{ opts.doc, @errorName(e) });
            return Exit.usage;
        },
    };
    defer gpa.free(doc);

    const schemas = try arena.alloc([]const u8, opts.schemas.len);
    for (opts.schemas, 0..) |path, i| {
        schemas[i] = CappedRead.readFile(io, path, arena, CappedRead.MAX_FILE_SIZE) catch |err| {
            try stderr.print("sjon: cannot read {s}: {s}\n", .{ path, @errorName(err) });
            return Exit.usage;
        };
    }

    const url = try ShareLink.buildUrl(arena, opts.base, doc, schemas);
    if (url.len > ShareLink.SIZE_WARN_BYTES) {
        try stderr.print(
            "sjon share: note — the link is large ({d} bytes); the playground handles it, but some chat apps and servers truncate long URLs\n",
            .{url.len},
        );
    }
    try stdout.writeAll(url);
    try stdout.writeAll("\n");
    return Exit.ok;
}

// ---------------------------------------------------------------------
// `sjon query` — devx A4. The terminal mirror of `sjon_query_pattern`
// (`src/wasm.zig` `runQueryPattern`): parse, require exactly one root,
// compile + query it against the fixed core+pattern schema, and print
// the two-shape serialization — `(haps …)` on stdout, `(diagnostics …)`
// on stderr with exit 1. Deterministic by construction: same source,
// window, and seed produce identical bytes.
// ---------------------------------------------------------------------

/// The schema `sjon query` compiles against — the same core + pattern
/// pair `sjon_query_pattern` uses (`src/wasm.zig`, grep
/// `pattern_schema`).
const pattern_schema: Schema.Schema = Schema.Schema.init(&.{ sjon.plugins.core.plugin, sjon.plugins.pattern.plugin });

/// The non-OOM half of `PatternQuery.Error` — every variant reachable
/// from user input alone (`--end=9223372036854775807`, a deep or wide
/// pattern), which is why both query call sites have to handle them
/// rather than `try`. Splitting OOM out keeps it on the propagate-to-
/// exit-3 path where it belongs.
const QueryBudgetError = error{
    DepthExceeded,
    MemoryBudgetExceeded,
    HapBudgetExceeded,
    TickOverflow,
};

/// Explain a budget trip in the user's terms. Exhaustive by construction:
/// a new `PatternQuery.Error` variant makes the `else => |e|` arms at the
/// call sites stop coercing to `QueryBudgetError`, so it cannot be added
/// without being explained here.
fn queryBudgetMessage(err: QueryBudgetError) []const u8 {
    return switch (err) {
        error.TickOverflow => "tick window lies outside the representable range (|tick| must not exceed 2^53)",
        error.DepthExceeded => "pattern nests deeper than the query engine allows",
        error.MemoryBudgetExceeded => "query exceeded its memory budget — narrow the window",
        error.HapBudgetExceeded => "query window produces more haps than the budget allows — narrow it",
    };
}

fn runQuery(gpa: Allocator, io: Io, opts: QueryOpts, stdout: *Writer, stderr: *Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = loadSource(gpa, io, opts.file) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| {
            try stderr.print("sjon: cannot read {s}: {s}\n", .{ opts.file, @errorName(e) });
            return Exit.usage;
        },
    };
    defer gpa.free(source);

    const file_label = if (std.mem.eql(u8, opts.file, "-")) "<stdin>" else opts.file;

    var tree = try sjon.Parser.parse(gpa, source);
    defer tree.deinit();
    if (tree.hasErrors()) {
        try reportParseErrors(arena, stderr, file_label, source, tree.diagnostics, .human);
        return Exit.errors;
    }
    if (tree.root.len != 1) {
        try stderr.writeAll("sjon query: the document must contain exactly one top-level pattern\n");
        return Exit.errors;
    }

    var result = sjon.PatternQuery.queryTree(
        gpa,
        &tree,
        tree.root[0],
        pattern_schema,
        .{ .begin = opts.begin, .end = opts.end },
        opts.seed,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| {
            try stderr.print("sjon query: {s}\n", .{queryBudgetMessage(e)});
            return Exit.errors;
        },
    };
    defer result.deinit();

    const text = try sjon.PatternQuery.resultToText(arena, result);
    if (result.diagnostics.len > 0) {
        try stderr.writeAll(text);
        try stderr.writeAll("\n");
        return Exit.errors;
    }
    try stdout.writeAll(text);
    try stdout.writeAll("\n");
    return Exit.ok;
}

// ---------------------------------------------------------------------
// `sjon fmt` — F4. Reformat documents in place.
//
// Purely syntactic: parse → `Printer.print` → compare → write if it
// differs. No project resolution, no validation, so an unresolvable
// `(use-plugin …)` or an unknown form never blocks formatting — only a
// *parse* error does.
//
// Two decisions worth stating outright, because both are load-bearing:
//
//   * `.full` mode, not `.canonical`. Canonical mode drops comments; a
//     formatter that silently deletes the user's comments is not a
//     formatter. This is also what the LSP's `getFormatEdits` uses, so
//     `sjon fmt` and format-on-save produce identical bytes.
//   * A broken parse is never written back. The parser recovers into a
//     *partial* tree, so printing it would silently discard whatever it
//     failed to parse — turning a syntax error into data loss. Same
//     decline policy as `Handler.getFormatEdits`, which returns null on
//     `tree.hasErrors()`.
//
// Channel policy — `fmt` splits the streams differently from `validate`,
// because `fmt -` makes stdout a *data* channel:
//
//   * stdout — the formatted document (stdin mode), or the list of files
//     touched / would-be-touched (file mode, like `gofmt -l`, so the
//     output pipes to xargs).
//   * stderr — diagnostics, always. `validate` prints them to stdout,
//     but here that would interleave a syntax error into the document
//     bytes a pipe consumer is reading. One rule for both modes rather
//     than a mode-dependent stream.
// ---------------------------------------------------------------------

fn runFmt(gpa: Allocator, io: Io, opts: FmtOpts, stdout: *Writer, stderr: *Writer, env: RunEnv) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const format = resolveFormat(opts.format, env);

    // Distinct from `dirty`: a file we could not parse is a failure,
    // whereas a file that merely needs reformatting is only a failure
    // under `--check`.
    var failed = false;
    var dirty = false;

    for (opts.paths) |path| {
        const is_stdin = std.mem.eql(u8, path, "-");
        const label = if (is_stdin) "<stdin>" else path;

        const source = loadSource(gpa, io, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |e| {
                try stderr.print("sjon fmt: cannot read {s}: {s}\n", .{ label, @errorName(e) });
                return Exit.usage;
            },
        };
        defer gpa.free(source);

        var tree = try sjon.Parser.parse(gpa, source);
        defer tree.deinit();

        if (tree.hasErrors()) {
            failed = true;
            try reportParseErrors(arena, stderr, label, source, tree.diagnostics, format);
            continue;
        }

        const printed = try sjon.Printer.print(gpa, tree, .{ .mode = .full });
        defer printed.deinit();

        const changed = !std.mem.eql(u8, printed.data, source);
        if (changed) dirty = true;

        if (opts.check) {
            if (changed) try stdout.print("would reformat {s}\n", .{label});
            continue;
        }
        if (is_stdin) {
            // Always emit, changed or not: a pipe consumer asked for the
            // formatted document, not for a diff.
            try stdout.writeAll(printed.data);
            continue;
        }
        if (!changed) continue;

        var cwd = Io.Dir.cwd();
        cwd.writeFile(io, .{ .sub_path = path, .data = printed.data }) catch |err| {
            try stderr.print("sjon fmt: cannot write {s}: {s}\n", .{ path, @errorName(err) });
            return Exit.internal_error;
        };
        try stdout.print("formatted {s}\n", .{path});
    }

    if (failed) return Exit.errors;
    if (opts.check and dirty) return Exit.errors;
    return Exit.ok;
}

/// Render a file's parse diagnostics through the shared formatters, so
/// `sjon fmt --format=json` is machine-readable like every other verb.
/// `project_file` is always null: fmt does no project discovery.
///
/// `out` is stderr, not stdout — see the channel policy above.
fn reportParseErrors(
    arena: Allocator,
    out: *Writer,
    path: []const u8,
    source: []const u8,
    diags: []const Ast.Diagnostic,
    format: Format,
) !void {
    const host_diags = try arena.alloc(Host.HostDiagnostic, diags.len);
    for (diags, 0..) |d, i| {
        host_diags[i] = .{
            // `.manifest`, not a `.parse` variant that doesn't exist:
            // `Host.validateDocument` already forwards parse
            // diagnostics under `.manifest` (`Host.zig:443`), so the
            // same broken file reports the same phase whether the user
            // ran `sjon validate` or `sjon fmt`. `Phase` is also
            // deserialized by the Rust host, so growing it would be a
            // multi-host parity change for no user-visible gain.
            .phase = .manifest,
            .code = d.code,
            .severity = d.severity,
            .message = d.message,
            .span = d.span,
            .path = d.path,
        };
    }
    switch (format) {
        .human, .github => try DiagnosticFormat.formatHuman(out, path, null, source, host_diags),
        // Rich needs a schema to render refinements; fmt never resolves
        // one, so pass null and let the renderer fall back to plain.
        .rich => try DiagnosticFormat.formatRich(out, arena, path, null, source, host_diags, null, null, false),
        .json => try DiagnosticFormat.formatJson(out, arena, path, null, source, host_diags, null, null),
    }
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

/// Walk up from `dirname(file)` (or cwd when file == "-") looking for
/// `sjon-project.sjon`. When found, returns the discovered file plus the
/// directory containing it. When nothing is found, falls back to using
/// `dirname(file)` (or cwd) as `project_root` with no project file —
/// that way explicit `:path` references still resolve relative to the
/// document's directory.
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
            // `dirname` returns null for paths with no separator (e.g., "foo"
            // or "."). Try cwd once before giving up.
            if (!std.mem.eql(u8, dir, ".")) {
                dir = ".";
                continue;
            }
            break;
        };
        if (std.mem.eql(u8, parent, dir)) break; // root reached
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
            .limited(CappedRead.MAX_FILE_SIZE),
            .of(u8),
            0,
        );
    }
    return try CappedRead.readFileZ(io, path, gpa, CappedRead.MAX_FILE_SIZE);
}

// ---------------------------------------------------------------------
// `sjon check` — Slice 11 of the local-packaging plan.
// Headline verb. Discovers the project, runs every plugin's manifest
// load + preflight, validates each document in `:documents` (or the
// explicit args), prints a summary.
// ---------------------------------------------------------------------

fn runCheck(gpa: Allocator, io: Io, opts: CheckOpts, stdout: *Writer, stderr: *Writer, env: RunEnv) !u8 {
    if (!opts.watch) return runCheckOnce(gpa, io, opts, stdout, stderr, env);
    return runCheckWatch(gpa, io, opts, stdout, stderr, env);
}

/// The `--watch` loop: run, then poll the project's `.sjon` set and
/// re-run on any fingerprint change. `env.watch_ticks` bounds the
/// number of poll iterations (null = forever); each re-run is the
/// plain `runCheckOnce`, so watch output and one-shot output can never
/// drift. A manifest or `sjon-project.sjon` edit is just another
/// changed file — every document re-checks against the new schema.
fn runCheckWatch(gpa: Allocator, io: Io, opts: CheckOpts, stdout: *Writer, stderr: *Writer, env: RunEnv) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const project = try resolveProjectForVerb(arena, io, opts.project_mode, stderr) orelse return Exit.errors;
    const root = project.root.?;

    const annotate = resolveFormat(opts.format, env) == .github;
    const prose: *Writer = if (annotate) stderr else stdout;

    var snap = try WatchSet.scan(gpa, io, root, .{});
    defer snap.deinit();
    // Said once, up front: a clipped walk yields a partial watched set
    // whose membership depends on directory iteration order, so diffs
    // against it can misreport. Watching continues — degraded beats
    // dead — but not silently. The flag no longer means only "hit the
    // entry ceiling": an unreadable directory raises it too, so the
    // message names both causes rather than asserting the wrong one.
    if (snap.stopped_early) try stderr.print(
        "sjon check --watch: watching a partial file set — the scan stopped early " ++
            "(over {d} entries, or a directory that could not be read)\n",
        .{WatchSet.MAX_SCAN_ENTRIES},
    );

    var code = try runWatchIteration(gpa, io, opts, stdout, stderr, env, prose, snap.count());
    var ticks: usize = 0;
    while (true) {
        if (env.watch_ticks) |max| {
            if (ticks >= max) return code;
        }
        ticks += 1;
        io.sleep(
            .{ .nanoseconds = @as(i96, @intCast(opts.interval_ms)) * std.time.ns_per_ms },
            .awake,
        ) catch {};

        var next = try WatchSet.scan(gpa, io, root, .{});
        var scratch = std.heap.ArenaAllocator.init(gpa);
        const d = WatchSet.diff(scratch.allocator(), &snap, &next) catch |err| {
            scratch.deinit();
            next.deinit();
            return err;
        };
        const dirty = !d.isEmpty();
        scratch.deinit();
        if (dirty) {
            snap.deinit();
            snap = next;
            code = try runWatchIteration(gpa, io, opts, stdout, stderr, env, prose, snap.count());
        } else {
            next.deinit();
        }
    }
}

/// One watch cycle: optional screen clear (TTY only — a piped consumer
/// must never see ANSI), the header line that is the loop's entire UI,
/// then the ordinary check.
fn runWatchIteration(
    gpa: Allocator,
    io: Io,
    opts: CheckOpts,
    stdout: *Writer,
    stderr: *Writer,
    env: RunEnv,
    prose: *Writer,
    watched: usize,
) !u8 {
    if (env.stdout_is_tty) try stdout.writeAll("\x1b[2J\x1b[H");
    const ns = std.Io.Clock.now(.real, io).nanoseconds;
    const secs_of_day: u64 = @intCast(@mod(@divTrunc(ns, std.time.ns_per_s), 86400));
    try prose.print("watching {d} file(s) · last run {d:0>2}:{d:0>2}:{d:0>2}\n\n", .{
        watched,
        secs_of_day / 3600,
        (secs_of_day % 3600) / 60,
        secs_of_day % 60,
    });
    const code = try runCheckOnce(gpa, io, opts, stdout, stderr, env);
    // The process-level writers only flush at exit; a watch session
    // must land each run's output on the terminal as it happens.
    try stdout.flush();
    try stderr.flush();
    return code;
}

fn runCheckOnce(gpa: Allocator, io: Io, opts: CheckOpts, stdout: *Writer, stderr: *Writer, env: RunEnv) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `--format=github` turns stdout into a pure annotation stream: the
    // phase/summary prose moves to stderr so a CI log keeps the story
    // while the annotation parser sees only workflow commands. Other
    // formats keep today's fixed prose report.
    const annotate = resolveFormat(opts.format, env) == .github;
    const prose: *Writer = if (annotate) stderr else stdout;

    const project = try resolveProjectForVerb(arena, io, opts.project_mode, stderr) orelse return Exit.errors;
    var fs = sjon.FilesystemResolver.init(gpa, io, project.root.?, project.file.?) catch return Exit.internal_error;
    defer fs.deinit();

    // -- Manifest phase --
    try prose.print("sjon check (project: {s})\n", .{project.file.?});
    try prose.writeAll("\n==== phase: manifest ====\n");
    var manifest_errors: usize = 0;
    const manifest_diags = fs.takeProjectDiagnostics();
    for (manifest_diags) |d| {
        const sev_label = if (d.severity == .err) "err" else "warn";
        try prose.print("{s} {s}: {s}\n", .{ sev_label, @tagName(d.code), d.message });
        if (d.severity == .err) manifest_errors += 1;
    }
    var plugins_loaded: usize = 0;
    var it = fs.iterateProjectPlugins();
    while (it.next()) |entry| {
        // `Parser.parse` returns `Allocator.Error` and nothing else — it
        // collects syntax errors into the tree rather than raising. So
        // `catch continue` here could only ever have swallowed OOM,
        // reporting the plugin as "skipped" on a machine that was out
        // of memory.
        var tree = try sjon.Parser.parse(gpa, entry.manifest_source);
        defer tree.deinit();
        var loaded = sjon.ManifestLoader.load(gpa, tree) catch |err| switch (err) {
            error.OutOfMemory => return Exit.internal_error,
            // Not reachable through this iterator today: the resolver
            // runs the same `load` while indexing and only manifests
            // that load cleanly reach `name_index` (see
            // `FilesystemResolver`'s `invalid_manifest` arm), so the
            // user sees this as a project diagnostic instead. Reported
            // rather than `unreachable` — a resolver that ever stops
            // pre-screening must not turn into a panic here.
            error.NotAPluginManifest => {
                try prose.print("err {s}  {s}\n    not a plugin manifest (root form is not `(plugin …)`)\n", .{ entry.name, entry.manifest_path });
                manifest_errors += 1;
                continue;
            },
        };
        defer loaded.deinit();
        if (loaded.hasErrors()) {
            try prose.print("err {s}  {s}\n", .{ entry.name, entry.manifest_path });
            for (loaded.diagnostics) |d| {
                if (d.severity != .err) continue;
                try prose.print("    {s}: {s}\n", .{ @tagName(d.code), d.message });
                manifest_errors += 1;
            }
        } else {
            const v = if (loaded.plugin.version.len > 0) loaded.plugin.version else "?";
            try prose.print("ok  {s} {s}  {s}\n", .{ entry.name, v, entry.manifest_path });
            plugins_loaded += 1;
        }
    }

    // -- Document phase --
    try prose.writeAll("\n==== phase: validation ====\n");
    // Patterns from explicit args take precedence over the project's
    // `:documents`. Both go through glob expansion — literal paths fall
    // through as a single-element list.
    const patterns = if (opts.documents.len > 0) opts.documents else fs.project_documents;
    const documents = expandDocumentPatterns(
        arena,
        io,
        project.root.?,
        patterns,
        fs.project_ignore,
        prose,
    ) catch |err| switch (err) {
        error.OutOfMemory => return Exit.internal_error,
        error.WriteFailed => return Exit.internal_error,
    };
    var doc_errors: usize = 0;
    var doc_warnings: usize = 0;
    var docs_validated: usize = 0;
    // A listed document that could not be read at all. Counted, printed,
    // and folded into the exit gate: a `:documents` entry that was
    // deleted or lost its read permission is a broken project, not a
    // clean one, and `runFmt` already treats the same condition as
    // fatal. Leaving it uncounted meant CI went green on a project
    // whose documents had silently stopped existing.
    var unreadable_docs: usize = 0;
    if (documents.len == 0) {
        if (patterns.len == 0) {
            try prose.writeAll("(no `:documents` glob set and no explicit args — nothing to validate)\n");
        }
        // If patterns were set but resolved to nothing, expandDocumentPatterns
        // has already emitted `glob_no_matches` advisories.
    } else {
        // Provenance decides how a path reads: `:documents` entries and
        // their glob expansions are project-root-relative (the expander
        // walks the root), while explicit argv documents are the user's
        // cwd-relative paths. Joining the wrong way breaks the other
        // case, so branch on where the pattern list came from.
        const docs_from_project = opts.documents.len == 0;
        for (documents) |doc_path| {
            const read_path = if (docs_from_project and !std.fs.path.isAbsolute(doc_path))
                try std.fs.path.join(arena, &.{ project.root.?, doc_path })
            else
                doc_path;
            var doc = validateOneDoc(gpa, io, read_path, project) catch |err| switch (err) {
                error.OutOfMemory => return Exit.internal_error,
                error.UnreadableFile => {
                    try prose.print("?? {s}  unreadable\n", .{doc_path});
                    unreadable_docs += 1;
                    continue;
                },
            };
            defer doc.deinit(gpa);
            if (annotate) {
                // Annotations carry the resolvable path — a CI runner
                // maps `file=` against its checkout, not the project
                // file's relative spelling.
                try DiagnosticFormat.formatGithub(stdout, read_path, doc.source, doc.result.diagnostics);
            }
            const ec = countDiag(doc.result.diagnostics, .err);
            const wc = countDiag(doc.result.diagnostics, .warning);
            doc_errors += ec;
            doc_warnings += wc;
            docs_validated += 1;
            if (ec > 0) {
                try prose.print("err {s}  {d} error(s), {d} warning(s)\n", .{ doc_path, ec, wc });
                // Show the first error inline so the user sees something
                // actionable without re-running `sjon validate`.
                for (doc.result.diagnostics) |d| {
                    if (d.severity != .err) continue;
                    try prose.print("    {s}: {s}\n", .{ @tagName(d.code), d.message });
                    break;
                }
            } else {
                try prose.print("ok  {s}  0 errors, {d} warning(s)\n", .{ doc_path, wc });
            }
        }
    }

    // -- Summary --
    try prose.writeAll("\n----------------------------------------\n");
    try prose.print("Summary: {d} plugin(s) loaded, {d} manifest error(s); {d} document(s), {d} error(s), {d} warning(s), {d} unreadable.\n", .{
        plugins_loaded,
        manifest_errors,
        docs_validated,
        doc_errors,
        doc_warnings,
        unreadable_docs,
    });
    return if (manifest_errors > 0 or doc_errors > 0 or unreadable_docs > 0) Exit.errors else Exit.ok;
}

const ValidatedDoc = struct {
    result: Host.HostResult,
    /// The document bytes, gpa-owned — kept so `--format=github` can
    /// map diagnostic spans to line/column. Freed by `deinit`.
    source: [:0]u8,

    fn deinit(self: *ValidatedDoc, gpa: Allocator) void {
        self.result.deinit();
        gpa.free(self.source);
    }
};

fn validateOneDoc(gpa: Allocator, io: Io, path: []const u8, project: Project) !ValidatedDoc {
    const source = CappedRead.readFileZ(io, path, gpa, CappedRead.MAX_FILE_SIZE) catch return error.UnreadableFile;
    errdefer gpa.free(source);
    var result = try Host.validateDocument(gpa, source, .{
        .failure_policy = .strict,
        .project_root = project.root,
        .project_file = project.file,
        .io = io,
    });
    errdefer result.deinit();
    return .{ .result = result, .source = source };
}

fn countDiag(diags: []const Host.HostDiagnostic, sev: Ast.Diagnostic.Severity) usize {
    var n: usize = 0;
    for (diags) |d| if (d.severity == sev) {
        n += 1;
    };
    return n;
}

/// Returns true when `s` contains any wildcard character understood by
/// `Glob.match`. Used to decide whether to walk the filesystem or treat
/// the pattern as a literal path.
fn patternHasWildcards(s: []const u8) bool {
    for (s) |c| {
        if (c == '*' or c == '?' or c == '{') return true;
    }
    return false;
}

/// Returns true when `pattern` contains a `..` path segment — meaning
/// it could resolve to a file outside the project root. Pure lexical
/// check (we don't resolve symlinks); used to gate the document
/// expander before walking.
fn patternEscapesRoot(pattern: []const u8) bool {
    // Strip leading `./` first so `./.. /x` still triggers.
    var p = pattern;
    while (std.mem.startsWith(u8, p, "./")) p = p[2..];
    if (std.mem.startsWith(u8, p, "../")) return true;
    if (std.mem.eql(u8, p, "..")) return true;
    if (std.mem.indexOf(u8, p, "/../") != null) return true;
    if (std.mem.endsWith(u8, p, "/..")) return true;
    return false;
}

/// Expand `:documents` patterns against the project root. Literal paths
/// pass through unchanged. Wildcard patterns walk the project tree and
/// match each `.sjon` file via `Glob.match`. Paths matching any pattern
/// in `ignore_patterns` are filtered. `sjon-project.sjon` and any path
/// in `plugin_paths` are always filtered out — they're never documents.
/// The returned slice is arena-owned and POSIX-normalized (forward
/// slashes). Emits a `glob_no_matches` advisory line per pattern that
/// resolves to nothing.
fn expandDocumentPatterns(
    arena: Allocator,
    io: Io,
    project_root: []const u8,
    patterns: []const []const u8,
    ignore_patterns: []const []const u8,
    stdout: *Writer,
) (Allocator.Error || Writer.Error)![]const []const u8 {
    if (patterns.len == 0) return &.{};

    // Refuse patterns containing `..` segments — they would escape the
    // project root, and `:documents` should never point outside the
    // project. Emit `project_documents_outside_root` and skip the
    // offending pattern.
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

    // Fast path: no wildcards anywhere → return patterns verbatim
    // (after duplication so the caller's arena owns them).
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

    // Normalize patterns by stripping leading `./`. The walker emits
    // paths relative to the start dir without that prefix, so a pattern
    // like `./*.sjon` from the project file would otherwise match
    // nothing. We don't strip `..` because that would break out of the
    // project root, which is not what `:documents` should ever do.
    //
    // Over `safe_patterns`, not `patterns`: normalizing the unfiltered
    // list resurrected the very `../…` entries the escape filter had
    // just announced it was skipping, and gave each of them a second
    // `glob_no_matches` advisory on top of the skip note.
    const normalized_patterns = try arena.alloc([]const u8, safe_patterns.len);
    for (safe_patterns, 0..) |p, i| {
        normalized_patterns[i] = if (std.mem.startsWith(u8, p, "./")) p[2..] else p;
    }

    // Walk the project root once, collecting candidate paths. The walker
    // emits paths relative to the start dir using the host path
    // separator; we normalize to forward slashes for `Glob.match`.
    var dir = Io.Dir.cwd().openDir(io, project_root, .{ .iterate = true }) catch {
        // Project root unreadable — fall back to literal handling, over
        // the *filtered* list. Falling back over `patterns` handed the
        // caller a `../…` path to read as a document immediately after
        // printing that it had been skipped.
        var out: std.ArrayList([]const u8) = .empty;
        for (safe_patterns) |p| try out.append(arena, try arena.dupe(u8, p));
        return out.toOwnedSlice(arena);
    };
    defer dir.close(io);

    var walker = dir.walk(arena) catch return error.OutOfMemory;
    defer walker.deinit();

    // Per-pattern matched flag — used to emit the `glob_no_matches`
    // advisory only when a pattern resolved to nothing. Parallel to
    // `normalized_patterns`, hence `safe_patterns.len`.
    const matched_flags = try arena.alloc(bool, safe_patterns.len);
    for (matched_flags) |*b| b.* = false;

    var matches: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    // A mid-walk iterate failure used to end discovery with no marker:
    // the user got a shorter document list and an otherwise clean
    // report. Same clipped-scan class `WatchSet` reports as
    // `stopped_early`.
    var stopped_early = false;
    while (true) {
        const maybe_entry = walker.next(io) catch |err| {
            stopped_early = true;
            try stdout.print(
                "note: document discovery stopped early ({s}); the list below may be incomplete\n",
                .{@errorName(err)},
            );
            break;
        };
        const entry = maybe_entry orelse break;
        if (entry.kind != .file) continue;
        // Normalize path separators. On POSIX this is a no-op; on
        // Windows the walker may emit backslashes that `Glob.match`
        // doesn't recognize.
        const rel = try arena.dupe(u8, entry.path);
        for (rel) |*c| if (c.* == '\\') {
            c.* = '/';
        };

        // Always exclude the project file itself — it's not a document
        // even when it happens to match the user's pattern.
        if (std.mem.eql(u8, rel, "sjon-project.sjon")) continue;
        // Also skip files inside `.zig-cache/`, `.git/`, etc. — these
        // would otherwise spam the document list when the user types
        // a broad pattern like `**/*.sjon`.
        if (std.mem.startsWith(u8, rel, ".git/")) continue;
        if (std.mem.startsWith(u8, rel, ".zig-cache/")) continue;
        if (std.mem.startsWith(u8, rel, "zig-out/")) continue;
        if (std.mem.startsWith(u8, rel, "node_modules/")) continue;

        // Ignore filter — match any ignore pattern → skip.
        var ignored = false;
        for (ignore_patterns) |ip| {
            if (Glob.match(ip, rel)) {
                ignored = true;
                break;
            }
        }
        if (ignored) continue;

        // Try each pattern. First match wins, but record per-pattern
        // hits for the advisory.
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

    // Emit advisories for patterns with zero matches — but only when the
    // walk actually finished. After an early stop, "matched no files" is
    // a claim the walk is in no position to make.
    if (!stopped_early) {
        for (safe_patterns, matched_flags) |p, hit| {
            if (!hit) try stdout.print("note: glob_no_matches: `{s}` matched no files\n", .{p});
        }
    }

    std.mem.sort([]const u8, matches.items, {}, lessThanStr);
    return matches.toOwnedSlice(arena);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ---------------------------------------------------------------------
// `sjon project info|verify` — Slice 10 of the local-packaging plan.
// Read-only project-level inspection. `info` summarizes the project
// file; `verify` runs every plugin's manifest-load + preflight check
// and gates on errors.
// ---------------------------------------------------------------------

fn runProjectInfo(gpa: Allocator, io: Io, opts: ProjectVerbOpts, stdout: *Writer, stderr: *Writer, env: RunEnv) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const project = try resolveProjectForVerb(arena, io, opts.project_mode, stderr) orelse return Exit.errors;
    var fs = sjon.FilesystemResolver.init(gpa, io, project.root.?, project.file.?) catch return Exit.internal_error;
    defer fs.deinit();

    switch (resolveFormat(opts.format, env)) {
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
        .human, .rich, .github => {
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
    // Project-load diagnostics (duplicate :name, missing manifests).
    const project_diags = fs.takeProjectDiagnostics();
    for (project_diags) |d| {
        try stdout.print("{s}: {s}: {s}\n", .{ @tagName(d.severity), @tagName(d.code), d.message });
        if (d.severity == .err) error_count += 1;
    }

    // Try loading the lockfile when one is referenced and not disabled.
    var lockfile: ?sjon.Lockfile.Lockfile = blk: {
        if (fs.project_lockfile_disabled) break :blk null;
        const lf_path = if (fs.project_lockfile_path) |p| p else try std.fmt.allocPrint(arena, "{s}/sjon-project.lock", .{project.root.?});
        const bytes = CappedRead.readFileZ(io, lf_path, arena, CappedRead.MAX_FILE_SIZE) catch break :blk null;
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

    // Per-plugin meta-validation + optional drift check.
    var seen_names: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_names.deinit(arena);
    var it = fs.iterateProjectPlugins();
    while (it.next()) |entry| {
        try seen_names.put(arena, entry.name, {});
        var tree = try sjon.Parser.parse(gpa, entry.manifest_source);
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
        // Surface warnings even when there are no errors — codes like
        // `license_unrecognized` and `too_many_keywords` would otherwise
        // be invisible to anyone running `sjon project verify` to
        // sanity-check their project.
        for (loaded.diagnostics) |d| {
            if (d.severity == .err) continue;
            try stdout.print("warn {s}  {s}: {s}\n", .{ entry.name, @tagName(d.code), d.message });
        }

        // Lockfile drift check.
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
                    if (CappedRead.readFile(io, wasm_path, arena, CappedRead.MAX_FILE_SIZE)) |wasm_bytes| {
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

    // Orphan check — lockfile entries that the project no longer references.
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

const CollectedLock = struct {
    entries: std.ArrayList(sjon.Lockfile.LockedEntry),
    project_hash: []const u8,
};

/// Build the current lock entry set from the project's on-disk
/// manifests — the prefix shared by `lock` and `sync`. Reads and hashes
/// the project file, walks its `:plugins`, parses + loads each manifest,
/// hashes the manifest and its paired wasm, and returns the name-sorted
/// entries plus the project-file hash. Returns null after printing a
/// `sjon project <verb>: …` error when the project file is unreadable or
/// any manifest has errors — the caller then exits non-zero. `verb` is
/// "lock" or "sync" (it also names the action in the refusal message).
fn collectLockedEntries(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    fs: *sjon.FilesystemResolver,
    project_file: []const u8,
    verb: []const u8,
    stderr: *Writer,
) !?CollectedLock {
    // Project-load diagnostics gate the whole operation. A manifest that
    // failed to index is simply absent from `iterateProjectPlugins`, so
    // without this the walk below just yields fewer entries and both
    // verbs report success: `sjon project lock` wrote `:plugins []` for a
    // project that references a plugin, and `sync` called that "up to
    // date", both exit 0. A lockfile that omits a plugin the project
    // references records a state that never existed — the one thing a
    // lockfile must not do. `runProjectVerify` already refuses; these two
    // now agree with it.
    var project_errors: usize = 0;
    for (fs.takeProjectDiagnostics()) |d| {
        if (d.severity != .err) continue;
        try stderr.print("sjon project {s}: {s}: {s}\n", .{ verb, @tagName(d.code), d.message });
        project_errors += 1;
    }
    if (project_errors > 0) {
        try stderr.print(
            "sjon project {s}: refusing to {s} — the project has {d} load error(s)\n",
            .{ verb, verb, project_errors },
        );
        return null;
    }

    const project_bytes = CappedRead.readFile(io, project_file, arena, CappedRead.MAX_FILE_SIZE) catch {
        try stderr.print("sjon project {s}: cannot read project file\n", .{verb});
        return null;
    };
    const project_hash = try sjon.Lockfile.hashBytes(arena, project_bytes);

    var entries: std.ArrayList(sjon.Lockfile.LockedEntry) = .empty;
    var it = fs.iterateProjectPlugins();
    while (it.next()) |entry| {
        var tree = try sjon.Parser.parse(gpa, entry.manifest_source);
        defer tree.deinit();
        var loaded = sjon.ManifestLoader.load(gpa, tree) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Pre-screened away by the resolver (see the note at the
            // `check` site); refused rather than skipped so the shape of
            // this arm can never become "write a lockfile anyway".
            error.NotAPluginManifest => {
                try stderr.print("sjon project {s}: refusing to {s} — `{s}` is not a plugin manifest\n", .{ verb, verb, entry.name });
                return null;
            },
        };
        defer loaded.deinit();
        if (loaded.hasErrors()) {
            try stderr.print("sjon project {s}: refusing to {s} — `{s}` has manifest errors\n", .{ verb, verb, entry.name });
            return null;
        }
        const m_hash = try sjon.Lockfile.hashBytes(arena, entry.manifest_source);
        var w_hash: ?[]const u8 = null;
        const wasm_path = try sjonToPairedWasm(arena, entry.manifest_path);
        if (CappedRead.readFile(io, wasm_path, arena, CappedRead.MAX_FILE_SIZE)) |wasm_bytes| {
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
    return .{ .entries = entries, .project_hash = project_hash };
}

fn runProjectLock(gpa: Allocator, io: Io, opts: ProjectVerbOpts, stdout: *Writer, stderr: *Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const project = try resolveProjectForVerb(arena, io, opts.project_mode, stderr) orelse return Exit.errors;
    var fs = sjon.FilesystemResolver.init(gpa, io, project.root.?, project.file.?) catch return Exit.internal_error;
    defer fs.deinit();

    const collected = try collectLockedEntries(gpa, io, arena, &fs, project.file.?, "lock", stderr) orelse return Exit.errors;
    const project_hash = collected.project_hash;
    const entries = collected.entries;

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

// ---------------------------------------------------------------------
// `sjon project sync` — reconcile the lockfile with the on-disk
// manifests, writing only when the result changes. The write-side
// complement to `verify`.
//
// Idempotency is by byte-compare: `Lockfile.write` is pure rendering
// over name-sorted entries with `generated_at`/`sjon_version` pinned to
// null (see `runProjectLock`), so "did anything change?" reduces to
// comparing freshly-rendered bytes against the file on disk. `--check`
// is the same reconcile without the write, exiting non-zero when the
// lockfile is out of date (additions and removals count, not just hash
// drift — stricter than `verify`'s recorded-hash check).
// ---------------------------------------------------------------------

fn runProjectSync(gpa: Allocator, io: Io, opts: ProjectSyncOpts, stdout: *Writer, stderr: *Writer, env: RunEnv) !u8 {
    const format = resolveFormat(opts.format, env);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const project = try resolveProjectForVerb(arena, io, opts.project_mode, stderr) orelse return Exit.errors;
    var fs = sjon.FilesystemResolver.init(gpa, io, project.root.?, project.file.?) catch return Exit.internal_error;
    defer fs.deinit();

    // Build the current entry set from the on-disk manifests (same shape
    // `runProjectLock` records); refuse if any manifest is broken.
    const collected = try collectLockedEntries(gpa, io, arena, &fs, project.file.?, "sync", stderr) orelse return Exit.errors;
    const project_hash = collected.project_hash;
    const entries = collected.entries;

    // -- Load the existing lockfile (for classification + byte compare).
    // Missing → bootstrap; corrupt / unsupported → note it and
    // regenerate (treat as if absent). --
    const lockfile_path = if (fs.project_lockfile_path) |p|
        p
    else
        try std.fmt.allocPrint(arena, "{s}/sjon-project.lock", .{project.root.?});
    const existing_bytes: ?[:0]u8 = CappedRead.readFileZ(io, lockfile_path, arena, CappedRead.MAX_FILE_SIZE) catch null;

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

    // -- Classify current entries against the old lockfile. --
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

    // -- Render the would-be lockfile and reduce "changed?" to a byte
    // compare. --
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

    // -- `--check`: dry run. Report and gate the exit code; never write. --
    if (opts.check) {
        switch (format) {
            .json => try writeSyncJson(stdout, added.items, updated.items, removed.items, unchanged, false, lockfile_path),
            .human, .rich, .github => {
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

    // -- No change: leave the file (and its mtime) untouched. --
    if (up_to_date) {
        switch (format) {
            .json => try writeSyncJson(stdout, added.items, updated.items, removed.items, unchanged, false, lockfile_path),
            .human, .rich, .github => try stdout.print("up to date: {s} ({d} plugin(s))\n", .{ lockfile_path, entries.items.len }),
        }
        return Exit.ok;
    }

    // -- Changed: write the reconciled lockfile. --
    var cwd = Io.Dir.cwd();
    cwd.writeFile(io, .{ .sub_path = lockfile_path, .data = new_bytes }) catch |err| {
        try stderr.print("sjon project sync: cannot write `{s}`: {s}\n", .{ lockfile_path, @errorName(err) });
        return Exit.errors;
    };
    switch (format) {
        .json => try writeSyncJson(stdout, added.items, updated.items, removed.items, unchanged, true, lockfile_path),
        .human, .rich, .github => {
            try printSyncSummary(stdout, added.items, updated.items, removed.items, unchanged, lockfile_unreadable, existing_bytes == null);
            try stdout.print("wrote {s} ({d} plugin(s))\n", .{ lockfile_path, entries.items.len });
        },
    }
    return Exit.ok;
}

/// Optional-hash equality: both null (declarative-only) counts as equal.
fn wasmHashEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn entriesContain(entries: []const sjon.Lockfile.LockedEntry, name: []const u8) bool {
    for (entries) |e| if (std.mem.eql(u8, e.name, name)) return true;
    return false;
}

/// Human reconcile summary: a `+/~/-` line per added/updated/removed
/// plugin, plus the bootstrap / regenerate banners. Shared by the write
/// and `--check` paths.
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

/// Common project-resolution helper for the project verbs. Returns a
/// `Project` with both `root` and `file` populated, or null after
/// emitting an error to stderr.
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

// ---------------------------------------------------------------------
// `sjon plugin info|check|list` — Slice 9 of the local-packaging plan.
// Read-only descriptive surfaces over a plugin manifest. `info` is
// always exit-0 (descriptive); `check` is the gating variant that
// returns exit-1 on errors.
// ---------------------------------------------------------------------

fn runPluginInfo(gpa: Allocator, io: Io, opts: PluginPathOpts, stdout: *Writer, stderr: *Writer, env: RunEnv) !u8 {
    return runPluginDescribe(gpa, io, opts, stdout, stderr, env, .descriptive);
}

fn runPluginCheck(gpa: Allocator, io: Io, opts: PluginPathOpts, stdout: *Writer, stderr: *Writer, env: RunEnv) !u8 {
    return runPluginDescribe(gpa, io, opts, stdout, stderr, env, .gating);
}

const PluginDescribeMode = enum { descriptive, gating };

fn runPluginDescribe(
    gpa: Allocator,
    io: Io,
    opts: PluginPathOpts,
    stdout: *Writer,
    stderr: *Writer,
    env: RunEnv,
    mode: PluginDescribeMode,
) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const manifest_source = CappedRead.readFileZ(io, opts.path, arena, CappedRead.MAX_FILE_SIZE) catch |err| {
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
    const wasm_bytes = CappedRead.readFile(io, wasm_path, arena, CappedRead.MAX_FILE_SIZE) catch null;

    var wasm_sha: ?[]const u8 = null;
    if (wasm_bytes) |bytes_for_hash| {
        wasm_sha = try sjon.Lockfile.hashBytes(arena, bytes_for_hash);
    }

    switch (resolveFormat(opts.format, env)) {
        .json => try renderPluginInfoJson(stdout, opts.path, &loaded, wasm_path, wasm_bytes, wasm_sha),
        .human, .rich, .github => try renderPluginInfoHuman(stdout, opts.path, &loaded, wasm_path, wasm_bytes, wasm_sha),
    }

    if (mode == .descriptive) return Exit.ok;
    // Gating mode (`plugin check`): non-zero exit on any manifest
    // error. Preflight diagnostics are reported via the manifest
    // loader; the runtime preflight is a follow-up (Slice 11 hooks
    // PluginRuntime in for full coverage).
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
    // `:version` is optional; print `?` for an unversioned plugin, the same
    // spelling `plugin list` and `project verify` use.
    try out.print("plugin    {s} {s}\n", .{ p.name, if (p.version.len > 0) p.version else "?" });
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

/// The `--format=json` object for `plugin info` and `plugin check`.
///
/// Every string goes through `writeJsonString` (i.e. `std.json.Stringify`),
/// never `writeAll`. `manifest_path` and `wasm_path` come from argv, and
/// `name` / `version` from the manifest, so one `"` — or a Windows path's
/// backslashes, the realistic case — used to emit a document no JSON
/// parser accepts, from a flag whose entire purpose is to be parsed.
fn renderPluginInfoJson(
    out: *Writer,
    manifest_path: []const u8,
    loaded: *sjon.ManifestLoader.Result,
    wasm_path: []const u8,
    wasm_bytes: ?[]const u8,
    wasm_sha: ?[]const u8,
) !void {
    const p = loaded.plugin;
    try out.writeAll("{\"name\":");
    try writeJsonString(out, p.name);
    try out.writeAll(",\"version\":");
    try writeJsonString(out, p.version);
    try out.writeAll(",\"manifest\":");
    try writeJsonString(out, manifest_path);
    try out.print(",\"forms\":{d}", .{p.forms.len});
    try out.print(",\"value_kinds\":{d}", .{p.value_kinds.len});
    try out.print(",\"expr_funcs\":{d}", .{p.expr_funcs.len});
    try out.writeAll(",\"wasm\":");
    if (wasm_bytes) |b| {
        try out.writeAll("{\"path\":");
        try writeJsonString(out, wasm_path);
        try out.print(",\"bytes\":{d},\"sha256\":", .{b.len});
        try writeJsonString(out, wasm_sha orelse "");
        try out.writeAll("}");
    } else {
        try out.writeAll("null");
    }
    // `plugin check --format=json` exited 1 with no machine-readable
    // reason: the diagnostics that *decided* that exit code appeared in
    // no field at all, so the machine format was strictly less useful
    // than the human one. Always emitted — empty on a clean manifest —
    // so a consumer can index it unconditionally.
    try out.writeAll(",\"diagnostics\":[");
    for (loaded.diagnostics, 0..) |d, i| {
        if (i > 0) try out.writeAll(",");
        try out.writeAll("{\"code\":");
        try writeJsonString(out, @tagName(d.code));
        try out.writeAll(",\"severity\":");
        try writeJsonString(out, @tagName(d.severity));
        try out.writeAll(",\"message\":");
        try writeJsonString(out, d.message);
        try out.writeAll("}");
    }
    try out.writeAll("]}\n");
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
    var unloadable: usize = 0;
    var it = fs.iterateProjectPlugins();
    while (it.next()) |entry| {
        // Re-parse the manifest to get :version. The iterator yields
        // only path + source, not the parsed Plugin.
        var tree = try sjon.Parser.parse(gpa, entry.manifest_source);
        defer tree.deinit();
        var loaded = sjon.ManifestLoader.load(gpa, tree) catch |err| switch (err) {
            error.OutOfMemory => return Exit.internal_error,
            // Pre-screened away by the resolver (see the note at the
            // `check` site). If one ever gets through, the row still
            // belongs in the listing — `plugin list` answers "what does
            // the project reference", and dropping it would make the
            // project look smaller than it is.
            error.NotAPluginManifest => {
                try stdout.print("{s: <18}{s: <10}{s}\n", .{ entry.name, "!", entry.manifest_path });
                unloadable += 1;
                continue;
            },
        };
        defer loaded.deinit();
        const v = if (loaded.plugin.version.len > 0) loaded.plugin.version else "?";
        try stdout.print("{s: <18}{s: <10}{s}\n", .{ entry.name, v, entry.manifest_path });
    }
    if (unloadable > 0) {
        try stderr.print("sjon plugin list: {d} manifest(s) marked `!` are not `(plugin …)` forms\n", .{unloadable});
        return Exit.errors;
    }
    return Exit.ok;
}

// ---------------------------------------------------------------------
// `sjon plugin init NAME` — scaffold a minimal, valid (plugin …)
// manifest (cargo-init style). Refuses to clobber an existing file
// without --force; `--stdout` prints the scaffold instead of writing.
// The template parses + loads clean, so `sjon plugin check` passes on
// the freshly-written file.
// ---------------------------------------------------------------------

fn runPluginInit(gpa: Allocator, io: Io, opts: PluginInitOpts, stdout: *Writer, stderr: *Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = try renderManifestTemplate(arena, opts.name);

    if (opts.to_stdout) {
        try stdout.writeAll(bytes);
        return Exit.ok;
    }

    // Overwrite guard — probe existence unless --force was given.
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

/// Render the scaffold manifest with `name` interpolated. The only
/// format placeholder is `{s}`; the template carries no literal braces,
/// so no escaping is needed.
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

// ---------------------------------------------------------------------
// `sjon plugin hash PATH` — Slice 5 of the local-packaging plan.
// Smallest scope, immediate user value: print `sha256-<hex>` for the
// paired wasm binary so an author can fill `:wasm-sha256` or a
// consumer can fill a `(use-plugin :hash …)` pin without shelling
// out to `shasum`.
// ---------------------------------------------------------------------

fn runPluginHash(
    gpa: Allocator,
    io: Io,
    opts: PluginHashOpts,
    stdout: *Writer,
    stderr: *Writer,
    env: RunEnv,
) !u8 {
    // Resolve the wasm path. Two cases:
    //   * `.sjon` path → use the canonical pairing rules:
    //     `plugin.sjon` → `plugin.wasm`; else `<stem>.wasm`.
    //   * `.wasm` path or anything else → hash that file directly.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const wasm_path = if (std.mem.endsWith(u8, opts.path, ".sjon"))
        try sjonToPairedWasm(arena, opts.path)
    else
        opts.path;

    const bytes = CappedRead.readFile(io, wasm_path, arena, CappedRead.MAX_FILE_SIZE) catch |err| {
        try stderr.print("sjon plugin hash: cannot read `{s}`: {s}\n", .{ wasm_path, @errorName(err) });
        return Exit.usage;
    };

    const pin = try sjon.Lockfile.hashBytes(arena, bytes);

    switch (resolveFormat(opts.format, env)) {
        .json => {
            // `wasm_path` is argv; a `"` or a Windows backslash spliced
            // raw produced unparseable JSON. See `renderPluginInfoJson`.
            try stdout.writeAll("{\"path\":");
            try writeJsonString(stdout, wasm_path);
            try stdout.writeAll(",\"sha256\":");
            try writeJsonString(stdout, pin);
            try stdout.print(",\"bytes\":{d}}}\n", .{bytes.len});
        },
        .human, .rich, .github => {
            try stdout.print("{s}\n", .{pin});
        },
    }
    return Exit.ok;
}

// ---------------------------------------------------------------------
// `sjon plugin test` — devx C1. The conformance-corpus discipline for
// schema authors: each case document validates against the manifest
// under test (+core, via `Host.preloadSchema` — the same F9 path the
// legacy corpus replay uses), and its diagnostic stream is compared
// in-order against a sibling expectation in the corpus's
// `expected.sjon` format, through the same decoder
// (`sjon.ConformanceExpected`). A broken manifest fails fast before
// any case runs — testing documents against a schema that doesn't
// load answers nothing.
// ---------------------------------------------------------------------

fn runPluginTest(gpa: Allocator, io: Io, opts: PluginTestOpts, stdout: *Writer, stderr: *Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const manifest_source = CappedRead.readFileZ(io, opts.path, arena, CappedRead.MAX_FILE_SIZE) catch |err| {
        try stderr.print("sjon plugin test: cannot read `{s}`: {s}\n", .{ opts.path, @errorName(err) });
        return Exit.usage;
    };

    var pre = try Host.preloadSchema(gpa, &.{manifest_source});
    defer pre.deinit();
    if (pre.hasErrors()) {
        try DiagnosticFormat.formatHuman(stderr, opts.path, null, manifest_source, pre.diagnostics);
        try stderr.writeAll("sjon plugin test: the manifest does not load cleanly — fix it first (`sjon plugin check`)\n");
        return Exit.errors;
    }

    const dir_path = opts.dir orelse blk: {
        const parent = std.fs.path.dirname(opts.path) orelse ".";
        break :blk try std.fs.path.join(arena, &.{ parent, "tests" });
    };

    // Case discovery: every `<name>.sjon` that is not itself an
    // expectation pairs with `<name>.expected.sjon`. Sorted so the
    // report order is deterministic.
    var case_names: std.ArrayList([]const u8) = .empty;
    {
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
            try stderr.print("sjon plugin test: no test case directory at `{s}` (create <case>.sjon + <case>.expected.sjon pairs, or pass --dir)\n", .{dir_path});
            return Exit.errors;
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (true) {
            // Not `catch null`: a test runner must never report "N passed"
            // over a suite it failed to finish enumerating. The cases it
            // never reached would read as cases that do not exist, which
            // is the one wrong answer a test runner can give.
            const maybe_entry = it.next(io) catch |err| {
                try stderr.print(
                    "sjon plugin test: cannot enumerate `{s}`: {s}\n",
                    .{ dir_path, @errorName(err) },
                );
                return Exit.internal_error;
            };
            const entry = maybe_entry orelse break;
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".sjon")) continue;
            if (std.mem.endsWith(u8, entry.name, ".expected.sjon")) continue;
            try case_names.append(arena, try arena.dupe(u8, entry.name[0 .. entry.name.len - ".sjon".len]));
        }
    }
    std.mem.sort([]const u8, case_names.items, {}, lessThanStr);

    if (case_names.items.len == 0) {
        try stderr.print("sjon plugin test: no test cases under `{s}` (expected <case>.sjon + <case>.expected.sjon pairs)\n", .{dir_path});
        return Exit.errors;
    }

    var passed: usize = 0;
    var failed: usize = 0;
    for (case_names.items) |name| {
        const ok = try runOneSchemaCase(gpa, io, arena, &pre, dir_path, name, stdout);
        if (ok) passed += 1 else failed += 1;
    }

    try stdout.print("\n{d} passed, {d} failed\n", .{ passed, failed });
    return if (failed > 0) Exit.errors else Exit.ok;
}

/// Run one `<name>.sjon` / `<name>.expected.sjon` pair. Returns pass
/// (true) / fail (false); every user-input problem — missing or
/// malformed expectation, mismatched stream — is a case failure with a
/// report line, never an error.
fn runOneSchemaCase(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    pre: *const Host.PreloadedSchema,
    dir_path: []const u8,
    name: []const u8,
    stdout: *Writer,
) !bool {
    const doc_path = try std.fmt.allocPrint(arena, "{s}/{s}.sjon", .{ dir_path, name });
    const exp_path = try std.fmt.allocPrint(arena, "{s}/{s}.expected.sjon", .{ dir_path, name });

    const doc_source = CappedRead.readFileZ(io, doc_path, arena, CappedRead.MAX_FILE_SIZE) catch |err| {
        try stdout.print("FAIL {s} — cannot read `{s}`: {s}\n", .{ name, doc_path, @errorName(err) });
        return false;
    };
    const exp_source = CappedRead.readFileZ(io, exp_path, arena, CappedRead.MAX_FILE_SIZE) catch {
        try stdout.print("FAIL {s} — missing expectation `{s}`\n", .{ name, exp_path });
        return false;
    };

    var exp_tree = try sjon.Parser.parse(gpa, exp_source);
    defer exp_tree.deinit();
    var expected = sjon.ConformanceExpected.parseExpectedDiagnostics(arena, &exp_tree) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try stdout.print("FAIL {s} — malformed expectation `{s}` (corpus expected.sjon format: `(diagnostics (diagnostic :code C :severity S :path [..]) …)`)\n", .{ name, exp_path });
            return false;
        },
    };
    defer expected.deinit(arena);
    if (exp_tree.hasErrors()) {
        try stdout.print("FAIL {s} — malformed expectation `{s}` (parse errors)\n", .{ name, exp_path });
        return false;
    }

    var result = try Host.validateDocument(gpa, doc_source, .{
        .failure_policy = .strict,
        .preloaded = pre,
    });
    defer result.deinit();
    const actual = result.diagnostics;

    if (expected.items.len != actual.len) {
        try stdout.print("FAIL {s} — diagnostic count mismatch: expected {d}, got {d}\n", .{ name, expected.items.len, actual.len });
        for (actual) |d| {
            try stdout.print("  got [{s} {s}] ", .{ @tagName(d.severity), @tagName(d.code) });
            try writeBracketPath(stdout, d.path);
            try stdout.print(" — {s}\n", .{d.message});
        }
        return false;
    }
    for (expected.items, actual, 0..) |exp, got, i| {
        if (exp.code != got.code) {
            try stdout.print("FAIL {s} — diagnostic {d} code mismatch: expected {s}, got {s}\n", .{ name, i, @tagName(exp.code), @tagName(got.code) });
            return false;
        }
        if (exp.severity != got.severity) {
            try stdout.print("FAIL {s} — diagnostic {d} severity mismatch: expected {s}, got {s}\n", .{ name, i, @tagName(exp.severity), @tagName(got.severity) });
            return false;
        }
        if (!sjon.ConformanceExpected.pathEqual(exp.path, got.path)) {
            try stdout.print("FAIL {s} — diagnostic {d} path mismatch\n  expected ", .{ name, i });
            try writeBracketPath(stdout, exp.path);
            try stdout.writeAll("\n  got      ");
            try writeBracketPath(stdout, got.path);
            try stdout.writeAll("\n");
            return false;
        }
    }
    try stdout.print("ok  {s}\n", .{name});
    return true;
}

fn writeBracketPath(out: *Writer, path: []const []const u8) !void {
    try out.writeAll("[");
    for (path, 0..) |seg, i| {
        if (i > 0) try out.writeAll(" ");
        try out.writeAll(seg);
    }
    try out.writeAll("]");
}

// ---------------------------------------------------------------------
// `sjon explain CODE` / `sjon explain --list` — Slice 8.
// Prints the long-form explanation for a diagnostic code. Used as
// the `help:` footer cross-reference in rich-format output.
// ---------------------------------------------------------------------

/// The plain-text catalogue entry: `CODE`, the indented one-liner, the
/// long body when there is one, and the published page URL last — the
/// same URL the rich renderer's `help:` footer links.
///
/// One renderer because there is one format. `sjon explain CODE` and the
/// REPL's `:explain CODE` printed byte-identical output from two copies
/// of this, which stays true only until someone edits one of them.
fn writeExplanation(stdout: *Writer, name: []const u8, entry: Explanations.Entry) Writer.Error!void {
    try stdout.print("{s}\n  {s}\n", .{ name, entry.short });
    if (entry.long.len > 0) {
        try stdout.writeAll("\n");
        try stdout.writeAll(entry.long);
        if (entry.long[entry.long.len - 1] != '\n') try stdout.writeAll("\n");
    }
    try stdout.print("\n{s}\n", .{Explanations.codeHref(entry.code)});
}

fn runExplain(opts: ExplainOpts, stdout: *Writer, stderr: *Writer, env: RunEnv) !u8 {
    const format = resolveFormat(opts.format, env);
    if (opts.list) return runExplainList(format, stdout);
    const name = opts.code orelse return Exit.usage;
    const entry = Explanations.lookup(name) orelse {
        try stderr.print("sjon explain: unknown code `{s}`\n", .{name});
        return Exit.usage;
    };
    switch (format) {
        .json => {
            try stdout.writeAll("{\"code\":\"");
            try stdout.writeAll(name);
            try stdout.writeAll("\",\"short\":");
            try writeJsonString(stdout, entry.short);
            try stdout.writeAll(",\"long\":");
            try writeJsonString(stdout, entry.long);
            try stdout.writeAll("}\n");
        },
        .human, .rich, .github => {
            try writeExplanation(stdout, name, entry);
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
        .human, .rich, .github => {
            for (entries) |e| try stdout.print("{s}  {s}\n", .{ @tagName(e.code), e.short });
        },
    }
    return Exit.ok;
}

// ---------------------------------------------------------------------
// `sjon completions SHELL` — emit a shell-completion script to stdout.
// The verb/subcommand/flag candidate lists come from the comptime
// tables at the top of this file, so the scripts can't drift from the
// dispatcher. Exhaustive `switch (opts.shell)` — adding a Shell variant
// is a compile error until it has a renderer.
// ---------------------------------------------------------------------

fn runCompletions(opts: CompletionsOpts, stdout: *Writer) !u8 {
    switch (opts.shell) {
        .bash => try Completions.writeBash(stdout, completion_vocab),
        .zsh => try Completions.writeZsh(stdout, completion_vocab),
        .fish => try Completions.writeFish(stdout, completion_vocab),
    }
    return Exit.ok;
}

/// Pair a manifest path with its expected wasm path using the
/// resolver's canonical rules. Mirrors `FilesystemResolver.pairedWasmPath`
/// without depending on it (the CLI shouldn't pull in resolver
/// internals for one helper). Returns an arena-owned slice.
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
    // Strip `.sjon`, append `.wasm`.
    const stem_end = manifest_path.len - ".sjon".len;
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, manifest_path[0..stem_end]);
    try buf.appendSlice(arena, ".wasm");
    return try buf.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------
// export-schema runner — bridges CLI options to the SchemaExport pipeline.
// Aggregate diagnostics from `validateDocument` print to stderr in the
// same human format `validate` uses; the requested artifacts go to
// stdout (or `--output` files). Exit codes: 0 clean, 1 if any
// err-severity warning fires (in the export OR aggregate stream), 2
// on a usage / IO failure.
// ---------------------------------------------------------------------

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
            .markdown = opts.target == .markdown,
        },
        .layout = opts.layout,
    });
    defer bundle.deinit();

    // Aggregate-phase diagnostics first so the user sees them above the
    // emitted artifacts when stdout is redirected to a file.
    if (bundle.host_result.diagnostics.len > 0) {
        try DiagnosticFormat.formatHuman(stderr, file_label, project.file, source, bundle.host_result.diagnostics);
    }

    emitExport(arena, io, opts, &bundle, stdout, stderr) catch |err| switch (err) {
        // The path and the OS reason were already printed at the failing
        // write; a raw propagated `error.AccessDenied` names neither.
        error.ExportWriteFailed => return Exit.internal_error,
        else => |e| return e,
    };

    return if (bundle.hasErrors()) Exit.errors else Exit.ok;
}

// export-lowering-graph runner — renders the aggregate `:lowering
// :produces` DAG as SJON to stdout. Aggregate diagnostics (e.g.
// `lowering_cycle`, `lowering_target_plugin_absent`) print to stderr in
// the same human format `validate` uses, above the graph, so a cyclic
// graph is still emitted and visible. Exit codes match export-schema:
// 0 clean, 1 if any err-severity aggregate diagnostic fires, 2 on a
// usage / IO failure.
// ---------------------------------------------------------------------
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

    // Aggregate diagnostics first so they sit above the graph when stdout
    // is redirected to a file.
    if (bundle.host_result.diagnostics.len > 0) {
        try DiagnosticFormat.formatHuman(stderr, file_label, project.file, source, bundle.host_result.diagnostics);
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

    // Warnings → stderr (human-readable list).
    for (er.warnings) |wn| {
        try stderr.print("sjon export-schema: [{s} {s}] {s}\n", .{ @tagName(wn.severity), @tagName(wn.code), wn.message });
    }

    if (to_stdout) {
        switch (opts.target) {
            .json_schema => try stdout.writeAll(er.json_schema_bytes.?),
            .typescript => try stdout.writeAll(er.ts_types_bytes.?),
            .intermediate => try stdout.writeAll(er.intermediate_bytes.?),
            .markdown => try stdout.writeAll(er.markdown_bytes.?),
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

    // PATH output — write one or more files per target. The path is
    // taken as a directory; the file names follow the convention in
    // §7 of the plan.
    try writeFileTargets(arena, io, opts.output, er, stderr);
}

fn writeFileTargets(
    arena: Allocator,
    io: Io,
    dir: []const u8,
    er: *SchemaExport.ExportResult,
    stderr: *Writer,
) !void {
    var cwd = Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch |err| {
        try stderr.print("sjon export-schema: cannot create {s}: {s}\n", .{ dir, @errorName(err) });
        return error.ExportWriteFailed;
    };
    if (er.per_plugin) |arts| {
        // Per-plugin layout: one set of files per plugin
        // (`<dir>/<plugin>.schema.json` + `<plugin>.d.ts` + `<plugin>.export.json`),
        // and a `<dir>/index.d.ts` barrel that re-exports every plugin's
        // `Sjon<Plugin>` union.
        for (arts) |art| {
            if (art.json_schema_bytes) |bytes| {
                const path = try std.fmt.allocPrint(arena, "{s}/{s}.schema.json", .{ dir, art.plugin });
                try writeFile(io, path, bytes, stderr);
            }
            if (art.ts_types_bytes) |bytes| {
                const path = try std.fmt.allocPrint(arena, "{s}/{s}.d.ts", .{ dir, art.plugin });
                try writeFile(io, path, bytes, stderr);
            }
            if (art.intermediate_bytes) |bytes| {
                const path = try std.fmt.allocPrint(arena, "{s}/{s}.export.json", .{ dir, art.plugin });
                try writeFile(io, path, bytes, stderr);
            }
            if (art.markdown_bytes) |bytes| {
                const path = try std.fmt.allocPrint(arena, "{s}/{s}.md", .{ dir, art.plugin });
                try writeFile(io, path, bytes, stderr);
            }
        }
        if (er.ts_types_bytes != null) {
            // Barrel: re-export every plugin so consumers can do
            // `import { SjonShapes } from "<dir>"`.
            const barrel = try buildIndexBarrel(arena, arts);
            const path = try std.fmt.allocPrint(arena, "{s}/index.d.ts", .{dir});
            try writeFile(io, path, barrel, stderr);
        }
        return;
    }
    if (er.json_schema_bytes) |bytes| {
        const path = try std.fmt.allocPrint(arena, "{s}/schema.json", .{dir});
        try writeFile(io, path, bytes, stderr);
    }
    if (er.ts_types_bytes) |bytes| {
        const path = try std.fmt.allocPrint(arena, "{s}/types.d.ts", .{dir});
        try writeFile(io, path, bytes, stderr);
    }
    if (er.intermediate_bytes) |bytes| {
        const path = try std.fmt.allocPrint(arena, "{s}/export.json", .{dir});
        try writeFile(io, path, bytes, stderr);
    }
    if (er.markdown_bytes) |bytes| {
        const path = try std.fmt.allocPrint(arena, "{s}/schema.md", .{dir});
        try writeFile(io, path, bytes, stderr);
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

/// Write one export artifact. A failure is reported here, with the path
/// and the OS reason, and collapses to one sentinel the runner maps to
/// exit 3 — mirroring how `runFmt` handles its own write failures.
/// Propagating the raw `Io` error instead named neither the file nor the
/// verb, and (before `main` grew its wrapper) surfaced as a stack trace.
fn writeFile(io: Io, path: []const u8, bytes: []const u8, stderr: *Writer) !void {
    var cwd = Io.Dir.cwd();
    cwd.writeFile(io, .{ .sub_path = path, .data = bytes }) catch |err| {
        try stderr.print("sjon export-schema: cannot write {s}: {s}\n", .{ path, @errorName(err) });
        return error.ExportWriteFailed;
    };
}

fn writeJsonString(out: *Writer, s: []const u8) !void {
    var stringify: std.json.Stringify = .{ .writer = out };
    try stringify.write(s);
}
