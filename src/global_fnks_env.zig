const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const panic = std.debug.panic;

pub const Swidy = @import("dynamically_scoped.zig").Swidy;

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

pub const Debugger = struct {
    swidy: *Swidy,
    active_value: Swidy.Value,
    all_fnks: Swidy.Value,
    /// list of pairs of (next_cases, env);
    stack: Swidy.Value,

    pub fn init(swidy: *Swidy) Debugger {
        var env = swidy.buildString("nil");
        env = swidy.envSet(swidy.buildString("@identity"), swidy.buildPair(
            swidy.buildString("fnkbody"),
            swidy.buildString("nil"),
        ), env);
        env = swidy.envSet(swidy.buildString("@eqAtoms?"), swidy.buildPair(
            swidy.buildString("external"),
            swidy.buildString(&std.mem.toBytes(&BuiltinFnks.@"eqAtoms?")),
        ), env);
        env = swidy.envSet(swidy.buildString("@join"), swidy.buildPair(
            swidy.buildString("external"),
            swidy.buildString(&std.mem.toBytes(&BuiltinFnks.join)),
        ), env);
        env = swidy.envSet(swidy.buildString("@split"), swidy.buildPair(
            swidy.buildString("external"),
            swidy.buildString(&std.mem.toBytes(&BuiltinFnks.split)),
        ), env);
        return .{
            .swidy = swidy,
            .active_value = swidy.buildString("nil"),
            .all_fnks = env,
            .stack = swidy.buildString("nil"),
        };
    }

    fn testHelper(debugger: *Debugger, in: []const u8, expected_out: []const u8) !void {
        const in_value = try debugger.swidy.buildSexpr(in);
        const expected_out_value = try debugger.swidy.buildSexpr(expected_out);
        const out = debugger.do(in_value);
        try debugger.swidy.expectEqual(expected_out_value, out);
    }

    pub fn do(debugger: *Debugger, in: Swidy.Value) Swidy.Value {
        const swidy = debugger.swidy;
        if (in.tag != .pair) return swidy.buildString("#error");
        var it = swidy.listIterator(in);
        const command = it.next() orelse return swidy.buildString("#error");
        if (false) { // hardcoded check for all commands
        } else if (swidy.isLit(command, "setActive")) {
            const value = it.next() orelse return swidy.buildString("#error");
            if (it.next() != null) return swidy.buildString("#error");

            debugger.active_value = value;

            return swidy.buildString("#inert");
        } else if (swidy.isLit(command, "getActive")) {
            if (it.next() != null) return swidy.buildString("#error");

            const value = debugger.active_value;

            return value;
        } else if (swidy.isLit(command, "getAllFnks")) {
            if (it.next() != null) return swidy.buildString("#error");

            const value = swidy.envAllKeys(debugger.all_fnks);

            return value;
        } else if (swidy.isLit(command, "getStack")) {
            if (it.next() != null) return swidy.buildString("#error");

            const value = debugger.stack;

            return value;
        } else if (swidy.isLit(command, "setStack")) {
            const value = it.next() orelse return swidy.buildString("#error");
            if (it.next() != null) return swidy.buildString("#error");

            debugger.stack = value;

            return swidy.buildString("#inert");
        } else if (swidy.isLit(command, "addFnk")) {
            const fnkname = it.next() orelse return swidy.buildString("#error");
            const fnkbody = it.next() orelse return swidy.buildString("#error");
            if (it.next() != null) return swidy.buildString("#error");

            const fnkdef = swidy.buildPair(swidy.buildString("fnkbody"), fnkbody);
            debugger.all_fnks = swidy.envSet(fnkname, fnkdef, debugger.all_fnks);

            return swidy.buildString("#inert");
        } else if (swidy.isLit(command, "getFnk")) {
            const fnkname = it.next() orelse return swidy.buildString("#error");
            if (it.next() != null) return swidy.buildString("#error");

            const value = swidy.envGet(fnkname, debugger.all_fnks) orelse return swidy.buildString("#error");

            return value;
        } else if (swidy.isLit(command, "call")) {
            const fnkname = it.next() orelse return swidy.buildString("#error");
            if (it.next() != null) return swidy.buildString("#error");

            debugger.call(fnkname) catch return swidy.buildString("#error");

            return swidy.buildString("#inert");
        } else if (swidy.isLit(command, "runAll")) {
            if (it.next() != null) return swidy.buildString("#error");

            while (!swidy.isNil(debugger.stack)) {
                debugger.step() catch return swidy.buildString("#error");
            }

            return swidy.buildString("#inert");
        } else if (swidy.isLit(command, "step")) {
            if (it.next() != null) return swidy.buildString("#error");

            debugger.step() catch return swidy.buildString("#error");

            return swidy.buildString("#inert");
        } else return swidy.buildString("#error");
    }

    fn call(debugger: *Debugger, fnkname: Swidy.Value) !void {
        const swidy = debugger.swidy;

        const fnkdef = swidy.envGet(fnkname, debugger.all_fnks) orelse return error.UnknownFnk;
        const kind, const fnkvalue = swidy.splitPair(fnkdef);
        if (swidy.isLit(kind, "fnkbody")) {
            debugger.stack = swidy.buildPair(
                swidy.buildPair(fnkvalue, swidy.buildString("nil")),
                debugger.stack,
            );
        } else if (swidy.isLit(kind, "external")) {
            const ptr_bytes: []const u8 = swidy.get(fnkvalue).string;
            const ptr: *const ExternalFnk = @ptrCast(std.mem.bytesToValue(*const ExternalFnk, ptr_bytes));
            debugger.active_value = ptr(swidy, debugger.active_value);
        } else return error.BadFnkDef;
    }

    fn step(debugger: *Debugger) !void {
        const swidy = debugger.swidy;

        if (!swidy.isNil(debugger.stack)) {
            const active_stack, const rest_stack = swidy.splitPair(debugger.stack);
            const active_cases, const active_env = swidy.splitPair(active_stack);

            if (!swidy.isNil(active_cases)) {
                const active_case, const rest_cases = swidy.splitPair(active_cases);

                const pattern = swidy.cr(active_case, &.{ .left, .left });
                const template = swidy.cr(active_case, &.{ .left, .right });
                const fnkname_template = swidy.cr(active_case, &.{ .right, .left });
                const next = swidy.cr(active_case, &.{ .right, .right });

                if (swidy.generateBindingsIntoEnv(pattern, debugger.active_value, active_env)) |new_active_env| {
                    const fnkname = try swidy.fillFromEnv(fnkname_template, new_active_env);
                    const active_value = try swidy.fillFromEnv(template, new_active_env);

                    debugger.active_value = active_value;
                    debugger.stack = swidy.buildPair(
                        swidy.buildPair(next, new_active_env),
                        rest_stack,
                    );
                    try debugger.call(fnkname);
                } else {
                    const new_active_stack = swidy.buildPair(rest_cases, active_env);
                    debugger.stack = swidy.buildPair(new_active_stack, rest_stack);
                }
            } else {
                debugger.stack = rest_stack;
            }
        }
    }
};

test "debugger" {
    var swidy: Swidy = .init(std.testing.allocator);
    defer swidy.deinit();

    var debugger: Debugger = .init(&swidy);

    try debugger.testHelper(
        \\ ("addFnk" "sum" (
        \\   (((("var" . "x") . ("lit" . "Z")) . ("var" . "x")) . (("lit" . "@identity") . ()))
        \\   (((("var" . "x") . (("lit" . "S") . ("var" . "y"))) . ((("lit" . "S") . ("var" . "x")) . ("var" . "y"))) . (("lit" . "sum") . ()))
        \\ ))
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("getFnk" "sum")
    ,
        \\ ("fnkbody" . (
        \\   (((("var" . "x") . ("lit" . "Z")) . ("var" . "x")) . (("lit" . "@identity") . ()))
        \\   (((("var" . "x") . (("lit" . "S") . ("var" . "y"))) . ((("lit" . "S") . ("var" . "x")) . ("var" . "y"))) . (("lit" . "sum") . ()))
        \\ ))
    );

    try debugger.testHelper(
        \\ ("setActive" ("Z" . "Z"))
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("call" "sum")
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("runAll")
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("getActive")
    ,
        \\ "Z"
    );

    try debugger.testHelper(
        \\ ("setActive" (("S" . ("S" . "Z")) . ("S" . ("S" . "Z"))))
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("call" "sum")
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("runAll")
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("getActive")
    ,
        \\ ("S" . ("S" . ("S" . ("S" . "Z"))))
    );
}

test "builtins" {
    var swidy: Swidy = .init(std.testing.allocator);
    defer swidy.deinit();

    var debugger: Debugger = .init(&swidy);

    try debugger.testHelper(
        \\ ("setActive" ("foo" . "foo"))
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("call" "@eqAtoms?")
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("getActive")
    ,
        \\ "true"
    );

    try debugger.testHelper(
        \\ ("setActive" ("foo" . "bar"))
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("call" "@eqAtoms?")
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("getActive")
    ,
        \\ "false"
    );

    try debugger.testHelper(
        \\ ("setActive" "foo")
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("call" "@split")
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("getActive")
    ,
        \\ ("f" "o" "o")
    );

    try debugger.testHelper(
        \\ ("call" "@join")
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("getActive")
    ,
        \\ "foo"
    );
}

const ExternalFnk = fn (swidy: *Swidy, value: Swidy.Value) callconv(.c) Swidy.Value;

const BuiltinFnks = struct {
    pub fn @"eqAtoms?"(swidy: *Swidy, value: Swidy.Value) callconv(.c) Swidy.Value {
        const result = switch (swidy.get(value)) {
            .string => false,
            .pair => |pair| if (pair.left.tag == .string and pair.right.tag == .string) swidy.eql(pair.left, pair.right) else false,
        };
        return swidy.buildString(if (result) "true" else "false");
    }

    pub fn join(swidy: *Swidy, value: Swidy.Value) callconv(.c) Swidy.Value {
        var builder = swidy.buildStringByParts();
        var it = swidy.listIterator(value);
        while (it.next()) |element| {
            if (element.tag != .string) panic("unexpected non-string element: {f}", .{swidy.fmt(element)});
            builder.add(swidy.get(element).string);
        }
        return builder.result;
    }

    pub fn split(swidy: *Swidy, value: Swidy.Value) callconv(.c) Swidy.Value {
        if (value.tag != .string) panic("unexpected non-string argument: {f}", .{swidy.fmt(value)});
        const string: Swidy.Value.String = swidy.slots_strings.items[value.index];

        // TODO(correctness): remove artificial limit
        var elements_buffer: [128]Swidy.Value = undefined;

        var elements: std.ArrayList(Swidy.Value) = .initBuffer(&elements_buffer);
        for (0..string.len) |k| {
            const cur = swidy.createCell(.string);
            swidy.slots_strings.items[cur.index] = .{ .start = @intCast(string.start + k), .len = 1 };
            elements.appendBounded(cur) catch Swidy.OoM();
        }

        return swidy.buildList(elements.items, null);
    }

    // TODO: remove and change to "get fnk address"
    pub fn dyncall(swidy: *Swidy, value: Swidy.Value) callconv(.c) Swidy.Value {
        // a -> @dyncall: ((stdlib . example) . foo)
        const path = swidy.get(swidy.cr(value, &.{ .left, .left })).string;
        const fnkname = std.mem.concatWithSentinel(swidy.gpa, u8, &.{
            swidy.get(swidy.cr(value, &.{ .left, .right })).string,
        }, 0) catch Swidy.OoM();
        defer swidy.gpa.free(fnkname);
        const argument = swidy.cr(value, &.{.right});

        var dynlib = std.DynLib.open(path) catch panic("error while opening dynlib {s}", .{path});
        defer dynlib.close();

        const Signature = fn (swidy: *Swidy, value: Swidy.Value) callconv(.c) Swidy.Value;
        const fnk = dynlib.lookup(*const Signature, fnkname) orelse
            panic("couldn't find fn {s} in dynlib {s}", .{ fnkname, path });

        return fnk(swidy, argument);
    }

    // pub fn add_u8_u8(swidy: *Swidy, value: Swidy.Value) callconv(.c) Swidy.Value {
    //     std.mem.readInt(comptime T: type, buffer: *const [?]u8, endian: Endian)
    //     ...
    // }
};
