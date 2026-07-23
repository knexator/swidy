const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const panic = std.debug.panic;

const core = @import("core.zig");
const Swidy = core.Swidy;
const Debugger = core.Debugger;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;

    var swidy: Swidy = .init(init.gpa);
    defer swidy.deinit();

    var debugger: Debugger = .init(&swidy);

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    while (true) {
        try stdout_writer.print("> ", .{});
        try stdout_writer.flush();
        const in = try Swidy.Parser.sexpr(&swidy, stdin_reader);
        const out = debugger.do(in);
        try stdout_writer.print("{f}\n", .{swidy.fmt(out)});
    }
    try stdout_writer.flush();

    return 0;
}
