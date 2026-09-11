//! SJON CLI entry point — `sjon validate FILE`, etc.
//!
//! Thin dispatcher: set up stdio writers, collect argv, hand the rest to
//! `Cli.run`. Every behavioural concern (argument parsing, source
//! loading, formatting, exit policy) lives in `Cli.zig` so the in-source
//! tests in `Cli_tests.zig` cover the same code path the binary runs.
//!
//! The one thing that cannot live there is the outermost catch: `run`
//! returns `!u8`, and anything it propagates (OOM, an unclassifiable IO
//! failure) used to reach the Zig runtime, which dumps an error trace and
//! exits **1** — the same code as "your document has validation errors".
//! `reportInternal` collapses every such escape to the documented exit 3.
//! The writers are therefore built before argv is collected, so even an
//! OOM in `args.toSlice` has somewhere to be reported.

const std = @import("std");
const Cli = @import("Cli.zig");

/// Turn a propagated error into the documented internal-error exit.
fn reportInternal(stderr: *std.Io.Writer, err: anyerror) u8 {
    // `catch {}` with no fallback: this *is* the fallback. If stderr is
    // itself the failing channel there is nowhere left to report, and the
    // exit code has to carry the whole signal.
    stderr.print("sjon: internal error: {s}\n", .{@errorName(err)}) catch {};
    return Cli.Exit.internal_error;
}

pub fn main(init: std.process.Init) u8 {
    // `writerStreaming`, not `writer`, on both channels. `File.writer`
    // "defaults to positional writing" (std/Io/File.zig:598-601), which
    // starts at offset 0 — right for a file this process opened and
    // wrong for one the shell handed us. stdout and stderr are inherited
    // fds whose offset belongs to the shell, so a positional writer made
    // `sjon fmt - >> log` write over the head of `log` rather than after
    // it, and `{ echo A; sjon edit F …; } > f` write over `A`. A pipe
    // hid it: positional writes are unavailable there, so the writer
    // fell back to streaming and the output was whole.
    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writerStreaming(init.io, &stdout_buf);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file = std.Io.File.stderr();
    var stderr_writer = stderr_file.writerStreaming(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch |err|
        return reportInternal(stderr, err);

    // TTY detection — used by the `--color=auto` rich-format heuristic.
    // Failure (e.g. WASI without a terminal concept) degrades to "not a
    // TTY", which is the safe default.
    const stdout_is_tty = stdout_file.isTty(init.io) catch false;
    const stdin_is_tty = std.Io.File.stdin().isTty(init.io) catch false;

    // NO_COLOR (per no-color.org) and SJON_NO_COLOR independently disable
    // color when set non-empty. Read once at startup and snapshot into
    // the RunEnv so the CLI itself stays test-friendly.
    const no_color = init.minimal.environ.containsUnempty(init.gpa, "NO_COLOR") catch false;
    const sjon_no_color = init.minimal.environ.containsUnempty(init.gpa, "SJON_NO_COLOR") catch false;

    // Iteration bound for `check --watch` (tests set it so the loop
    // terminates; unset = watch forever). Unparseable values read as
    // unset rather than erroring — an env var is not an argv.
    const watch_ticks: ?usize = blk: {
        var map = init.minimal.environ.createMap(init.gpa) catch break :blk null;
        defer map.deinit();
        const v = map.get("SJON_WATCH_TICKS") orelse break :blk null;
        break :blk std.fmt.parseInt(usize, v, 10) catch null;
    };

    var code = Cli.run(init.gpa, init.io, args, &stdout_writer.interface, stderr, .{
        .stdout_is_tty = stdout_is_tty,
        .stdin_is_tty = stdin_is_tty,
        .no_color = no_color,
        .sjon_no_color = sjon_no_color,
        .watch_ticks = watch_ticks,
    }) catch |err| reportInternal(stderr, err);

    // A failed stdout flush means the user never received the output the
    // exit code is describing — that outranks whatever `run` decided.
    stdout_writer.interface.flush() catch |err| {
        code = reportInternal(stderr, err);
    };
    stderr.flush() catch return Cli.Exit.internal_error;
    return code;
}
