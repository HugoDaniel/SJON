//! Emit every `Ast.Diagnostic.Code` enum variant name, one per line, to stdout.
//!
//! The compiler-derived source of truth for the diagnostic-coverage audit
//! (`tools/audit_diagnostic_coverage.sh`), which reads this list rather than
//! text-scraping the `pub const Code = enum { … }` block out of `src/Ast.zig`
//! with awk/grep/sed. That scrape silently under-counts whenever the enum
//! block's formatting shifts — its own header flagged the near-miss where a
//! `number_i64`-style variant would slip past a too-narrow name class and never
//! be audited, the enforcement tool false-passing on the very codes it exists
//! to check. `@typeInfo` cannot drift: add a variant and it appears here on the
//! next build. Wired into `zig build audit-diagnostics`, whose run captures this
//! stdout and hands the file to the coverage script.

const std = @import("std");
const sjon = @import("sjon");
const Io = std.Io;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var out_file = Io.File.stdout();
    var out_writer = out_file.writer(io, &out_buf);
    defer out_writer.interface.flush() catch {};
    const out = &out_writer.interface;

    inline for (@typeInfo(sjon.Ast.Diagnostic.Code).@"enum".fields) |f| {
        try out.print("{s}\n", .{f.name});
    }
    return 0;
}
