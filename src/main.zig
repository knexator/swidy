const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const panic = std.debug.panic;
const fatal = std.process.fatal;

const core = @import("core.zig");
const Swidy = core.Swidy;
const Debugger = core.Debugger;

comptime {
    std.testing.refAllDecls(core);
}

/// This can be global since stdin is a singleton.
var stdin_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;
/// This can be global since stdout is a singleton.
var stdout_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    assert(args.skip());

    const mode = args.next() orelse "help";

    if (std.mem.eql(u8, mode, "help")) {
        try Io.File.stdout().writeStreamingAll(io,
            \\Usage:
            \\  swity run [file]
            \\  swity debug
            \\  swity lsp
            \\
        );
    } else if (std.mem.eql(u8, mode, "lsp")) {
        panic("TODO", .{});
    } else if (std.mem.eql(u8, mode, "run")) {
        const file_name = args.next() orelse fatal("missing file name", .{});
        var file = try std.Io.Dir.cwd().openFile(io, file_name, .{ .allow_directory = false, .resolve_beneath = true });
        defer file.close(io);
        var file_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;
        var file_reader = file.reader(io, &file_buffer);
        try cmd_run(init.gpa, io, &file_reader.interface);
    } else if (std.mem.eql(u8, mode, "debug")) {
        try cmd_debug(init.gpa, io);
    } else {
        fatal("unknown command: {s}", .{mode});
    }

    return 0;
}

fn cmd_run(gpa: std.mem.Allocator, io: std.Io, file: *std.Io.Reader) !void {
    var swidy: Swidy = .init(gpa);
    defer swidy.deinit();

    var debugger: Debugger = .init(&swidy);

    try debugger.addFnks(file);
    try debugger.call(swidy.buildString("main"));
    try debugger.runAllWithoutBreakpoints();
    const result = debugger.active_value;

    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("{f}\n", .{swidy.fmt(result)});
    try stdout_writer.flush();
}

fn cmd_debug(gpa: std.mem.Allocator, io: std.Io) !void {
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stdin_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const stdin = &stdin_reader.interface;

    var swidy: Swidy = .init(gpa);
    defer swidy.deinit();

    var debugger: Debugger = .init(&swidy);

    while (true) {
        try stdout.print("> ", .{});
        try stdout.flush();
        const in = try Swidy.Parser.sexpr(&swidy, stdin);
        const out = debugger.do(in);
        try stdout.print("{f}\n", .{swidy.fmt(out)});
    }

    try stdout_writer.flush();
}
