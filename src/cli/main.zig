const std = @import("std");
const Cli = @import("Cli.zig");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(init.io, &stdout_buf);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file = std.Io.File.stderr();
    var stderr_writer = stderr_file.writer(init.io, &stderr_buf);

    const stdout_is_tty = stdout_file.isTty(init.io) catch false;

    const no_color = init.minimal.environ.containsUnempty(init.gpa, "NO_COLOR") catch false;
    const sjon_no_color = init.minimal.environ.containsUnempty(init.gpa, "SJON_NO_COLOR") catch false;

    const code = try Cli.run(init.gpa, init.io, args, &stdout_writer.interface, &stderr_writer.interface, .{
        .stdout_is_tty = stdout_is_tty,
        .no_color = no_color,
        .sjon_no_color = sjon_no_color,
    });
    try stdout_writer.interface.flush();
    try stderr_writer.interface.flush();
    return code;
}
