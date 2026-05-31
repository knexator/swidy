const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const panic = std.debug.panic;

// builtin: identity (maybe), eqAtoms?, split, concat, addu32u32 (etc)

// keep all fnks as values?

pub const Swidy = struct {
    slots_pairs: std.ArrayListUnmanaged(Value.Pair),
    slots_strings: std.ArrayListUnmanaged(Value.String),
    strings: std.ArrayListUnmanaged(u8),

    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Swidy {
        return .{ .gpa = gpa, .slots_pairs = .empty, .slots_strings = .empty, .strings = .empty };
    }

    pub fn deinit(swidy: *Swidy) void {
        swidy.slots_pairs.deinit(swidy.gpa);
        swidy.slots_strings.deinit(swidy.gpa);
        swidy.strings.deinit(swidy.gpa);
    }

    pub fn eql(swidy: *const Swidy, a: Value, b: Value) bool {
        if (a == b) return true;
        return switch (swidy.get(a)) {
            .string => |a_str| switch (swidy.get(b)) {
                .pair => false,
                .string => |b_str| std.mem.eql(u8, a_str, b_str),
            },
            .pair => |a_pair| switch (swidy.get(b)) {
                .string => false,
                .pair => |b_pair| swidy.eql(a_pair.left, b_pair.left) and
                    swidy.eql(a_pair.right, b_pair.right),
            },
        };
    }

    pub fn expectEqual(swidy: *const Swidy, expected: Value, actual: Value) !void {
        try std.testing.expect(swidy.eql(expected, actual));
    }

    pub fn expectEqualAsStrings(swidy: *const Swidy, expected: Value, actual: Value, scratch: std.mem.Allocator) !void {
        const expected_str = try std.fmt.allocPrint(scratch, "{f}", .{swidy.fmt(expected)});
        defer scratch.free(expected_str);
        const actual_str = try std.fmt.allocPrint(scratch, "{f}", .{swidy.fmt(actual)});
        defer scratch.free(actual_str);
        try std.testing.expectEqualStrings(expected_str, actual_str);
    }

    // "{f}", .{swidy.fmt(value)}.
    pub fn fmt(swidy: *const Swidy, value: Value) struct {
        swidy: *const Swidy,
        value: Value,
        pub fn format(ctx: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (ctx.swidy.get(ctx.value)) {
                .string => |str| {
                    const charset = "0123456789ABCDEF";
                    var buf: [4]u8 = undefined;
                    buf[0] = '\\';
                    buf[1] = 'x';

                    try writer.writeByte('\"');
                    for (str) |c| {
                        if (std.ascii.isAlphanumeric(c)) {
                            try writer.writeByte(c);
                        } else {
                            buf[2] = charset[c >> 4];
                            buf[3] = charset[c & 15];
                            try writer.writeAll(&buf);
                        }
                    }
                    try writer.writeByte('\"');
                },
                .pair => |pair| try writer.print("({f} . {f})", .{
                    ctx.swidy.fmt(pair.left),
                    ctx.swidy.fmt(pair.right),
                }),
            }
        }
    } {
        return .{ .swidy = swidy, .value = value };
    }

    pub const Tag = enum(u1) { pair, string };
    pub const Value = packed struct(u32) {
        // TODO(perf-late): try swapping the order
        tag: Tag,
        index: u31,

        pub const Pair = struct {
            left: Value,
            right: Value,
        };

        pub const String = struct {
            start: u32,
            len: u32,
        };
    };

    pub fn get(swidy: *const Swidy, value: Value) union(enum) {
        string: []const u8,
        pair: struct { left: Value, right: Value },
    } {
        switch (value.tag) {
            .pair => {
                const asdf = swidy.slots_pairs.items[value.index];
                return .{ .pair = .{ .left = asdf.left, .right = asdf.right } };
            },
            .string => {
                const asdf = swidy.slots_strings.items[value.index];
                return .{ .string = swidy.strings.items[asdf.start..][0..asdf.len] };
            },
        }
    }

    fn createCell(swidy: *Swidy, comptime tag: Tag) Value {
        const slots = switch (tag) {
            .pair => &swidy.slots_pairs,
            .string => &swidy.slots_strings,
        };
        const result: Value = .{ .tag = tag, .index = std.math.cast(u31, slots.items.len) orelse OoM() };
        _ = slots.addOne(swidy.gpa) catch OoM();
        return result;
    }

    // TODO(perf): free and reuse cells
    // fn destroyCell

    fn buildSexpr(swidy: *Swidy, str: []const u8) !Value {
        errdefer std.log.err("failed to build sexpr for input {s}", .{str});
        var reader: std.Io.Reader = .fixed(str);
        const result = try Parser.sexpr(swidy, &reader);
        try Parser.whitespace(&reader, false);
        if (reader.bufferedLen() > 0) return error.MoreThanOneSexpr;
        return result;
    }

    pub fn buildPair(swidy: *Swidy, left: Value, right: Value) Value {
        const result = swidy.createCell(.pair);
        swidy.slots_pairs.items[result.index] = .{ .left = left, .right = right };
        return result;
    }

    fn splitPair(swidy: *Swidy, value: Value) [2]Value {
        assert(value.tag == .pair);
        const pair = swidy.get(value).pair;
        return .{ pair.left, pair.right };
    }

    pub fn buildString(swidy: *Swidy, bytes: []const u8) Value {
        // TODO(perf): string interning
        const string: Value.String = .{
            .start = std.math.cast(u32, swidy.strings.items.len) orelse OoM(),
            .len = std.math.cast(u32, bytes.len) orelse OoM(),
        };
        swidy.strings.appendSlice(swidy.gpa, bytes) catch OoM();

        const result = swidy.createCell(.string);
        swidy.slots_strings.items[result.index] = string;
        return result;
    }

    pub fn buildStringByParts(swidy: *Swidy) StringBuilder {
        return .{ .result = swidy.buildString(""), .swidy = swidy };
    }

    const StringBuilder = struct {
        result: Value,
        swidy: *Swidy,

        pub fn add(builder: *StringBuilder, part: []const u8) void {
            assert(builder.result.tag == .string);
            const string = &builder.swidy.slots_strings.items[builder.result.index];
            assert(string.start + string.len == builder.swidy.strings.items.len);
            builder.swidy.strings.appendSlice(builder.swidy.gpa, part) catch OoM();
            string.len = std.math.cast(u32, @as(usize, string.len) + part.len) orelse OoM();
        }
    };

    fn buildList(swidy: *Swidy, elements: []const Value, sentinel: ?Value) Value {
        var result = sentinel orelse swidy.buildString("nil");
        var it = std.mem.reverseIterator(elements);
        while (it.next()) |element| {
            result = swidy.buildPair(element, result);
        }
        return result;
    }

    fn cr(swidy: *const Swidy, value: Value, address: []const enum { left, right }) Value {
        //     return swidy.crSafe(value, address) orelse panic("bad address {any} for value {f}", .{ address, swidy.fmt(value) });
        // }

        // fn crSafe(swidy: *const Swidy, value: Value, address: []const enum { left, right }) ?Value {
        var result = value;
        for (address) |dir| {
            switch (swidy.get(result)) {
                // .string => return null,
                .string => panic("bad address {any} for value {f}", .{ address, swidy.fmt(value) }),
                .pair => |pair| result = switch (dir) {
                    .left => pair.left,
                    .right => pair.right,
                },
            }
        }
        return result;
    }

    pub fn eval(swidy: *Swidy, fnkname: Value, input: Value, known_fnks: Value) Value {
        if (fnkname.tag == .string and swidy.get(fnkname).string[0] == '@') {
            const builtin_name = swidy.get(fnkname).string[1..];
            inline for (@typeInfo(BuiltinFnks).@"struct".decls) |decl| {
                if (std.mem.eql(u8, decl.name, builtin_name)) {
                    const builtin = @field(BuiltinFnks, decl.name);
                    return builtin(swidy, input);
                }
            } else panic("unknown builtin: @{s}", .{builtin_name});
        } else {
            const fnkbody = swidy.lookup(fnkname, known_fnks) orelse swidy.buildString("nil");
            return swidy.eval_inner(fnkbody, input, swidy.buildString("nil"), known_fnks);
        }
    }

    fn eval_inner(swidy: *Swidy, fnkbody: Value, input: Value, parent_bindings: Value, known_fnks: Value) Value {
        var it = swidy.listIterator(fnkbody);
        while (it.next()) |case| {
            const pattern = swidy.cr(case, &.{ .left, .left });
            const template = swidy.cr(case, &.{ .left, .right });
            const fnkname_template = swidy.cr(case, &.{ .right, .left });
            const next = swidy.cr(case, &.{ .right, .right });

            if (swidy.generateBindings(pattern, input)) |bindings| {
                const all_bindings = swidy.concat(&.{ bindings, parent_bindings });
                const fnkname = swidy.fillBindings(fnkname_template, all_bindings);
                const new_input_v1 = swidy.fillBindings(template, all_bindings);
                const new_input_v2 = swidy.eval(fnkname, new_input_v1, known_fnks);
                return swidy.eval_inner(next, new_input_v2, all_bindings, known_fnks);
            }
        }
        return input;
    }

    fn generateBindingsIntoEnv(swidy: *Swidy, pattern: Value, value: Value, env: Value) ?Value {
        switch (swidy.get(pattern)) {
            .string => panic("bad pattern: {f}", .{swidy.fmt(pattern)}),
            .pair => |pattern_pair| {
                if (pattern_pair.left.tag == .string) {
                    if (swidy.isLit(pattern_pair.left, "lit")) {
                        return if (swidy.eql(pattern_pair.right, value)) env else null;
                    } else if (swidy.isLit(pattern_pair.left, "var")) {
                        if (pattern_pair.right.tag != .string) panic("bad pattern: {f}", .{swidy.fmt(pattern)});
                        return swidy.envSet(pattern_pair.right, value, env);
                    } else panic("bad pattern: {f}", .{swidy.fmt(pattern)});
                } else {
                    if (value.tag == .string) return null;
                    const env_1 = swidy.generateBindingsIntoEnv(
                        pattern_pair.left,
                        swidy.get(value).pair.left,
                        env,
                    ) orelse return null;
                    const env_2 = swidy.generateBindingsIntoEnv(
                        pattern_pair.right,
                        swidy.get(value).pair.right,
                        env_1,
                    ) orelse return null;
                    return env_2;
                }
            },
        }
    }

    fn generateBindings(swidy: *Swidy, pattern: Value, value: Value) ?Value {
        switch (swidy.get(pattern)) {
            .string => panic("bad pattern: {f}", .{swidy.fmt(pattern)}),
            .pair => |pattern_pair| {
                if (pattern_pair.left.tag == .string) {
                    if (swidy.isLit(pattern_pair.left, "lit")) {
                        return if (swidy.eql(pattern_pair.right, value)) swidy.buildString("nil") else null;
                    } else if (swidy.isLit(pattern_pair.left, "var")) {
                        if (pattern_pair.right.tag != .string) panic("bad pattern: {f}", .{swidy.fmt(pattern)});
                        return swidy.buildList(&.{swidy.buildPair(pattern_pair.right, value)}, null);
                    } else panic("bad pattern: {f}", .{swidy.fmt(pattern)});
                } else {
                    if (value.tag == .string) return null;
                    if (swidy.generateBindings(pattern_pair.left, swidy.get(value).pair.left)) |left_bindings| {
                        if (swidy.generateBindings(pattern_pair.right, swidy.get(value).pair.right)) |right_bindings| {
                            return swidy.concat(&.{ left_bindings, right_bindings });
                        } else return null;
                    } else return null;
                }
            },
        }
    }

    fn fillFromEnv(swidy: *Swidy, template: Value, env: Value) !Value {
        switch (swidy.get(template)) {
            .string => return error.BadTemplate,
            .pair => |template_pair| {
                if (template_pair.left.tag == .string) {
                    if (swidy.isLit(template_pair.left, "lit")) {
                        return template_pair.right;
                    } else if (swidy.isLit(template_pair.left, "var")) {
                        if (template_pair.right.tag != .string) return error.BadTemplate;
                        return swidy.envGet(template_pair.right, env) orelse error.UnboundVar;
                    } else return error.BadTemplate;
                } else return swidy.buildPair(
                    try swidy.fillFromEnv(template_pair.left, env),
                    try swidy.fillFromEnv(template_pair.right, env),
                );
            },
        }
    }

    fn fillBindings(swidy: *Swidy, template: Value, bindings: Value) Value {
        switch (swidy.get(template)) {
            .string => panic("bad template: {f}", .{swidy.fmt(template)}),
            .pair => |template_pair| {
                if (template_pair.left.tag == .string) {
                    if (swidy.isLit(template_pair.left, "lit")) {
                        return template_pair.right;
                    } else if (swidy.isLit(template_pair.left, "var")) {
                        if (template_pair.right.tag != .string) panic("bad template: {f}", .{swidy.fmt(template)});
                        return swidy.lookup(template_pair.right, bindings) orelse panic("unbound var: {f}", .{swidy.fmt(template_pair.right)});
                    } else panic("bad template: {f}", .{swidy.fmt(template)});
                } else return swidy.buildPair(
                    swidy.fillBindings(template_pair.left, bindings),
                    swidy.fillBindings(template_pair.right, bindings),
                );
            },
        }
    }

    fn concat(swidy: *Swidy, lists: []const Value) Value {
        var result = swidy.buildString("nil");
        var it = std.mem.reverseIterator(lists);
        while (it.next()) |list| {
            const reversed = swidy.reverse(list);
            var it_local = swidy.listIterator(reversed);
            while (it_local.next()) |element| {
                result = swidy.buildPair(element, result);
            }
        }
        return result;
    }

    fn reverse(swidy: *Swidy, list: Value) Value {
        var result = swidy.buildString("nil");
        var it = swidy.listIterator(list);
        while (it.next()) |element| {
            result = swidy.buildPair(element, result);
        }
        return result;
    }

    fn envGet(swidy: *const Swidy, key: Value, env: Value) ?Value {
        const dict, const parent_envs = .{
            swidy.cr(env, &.{.left}),
            swidy.cr(env, &.{.right}),
        };

        if (swidy.lookup(key, dict)) |r| return r;

        var it = swidy.listIterator(parent_envs);
        while (it.next()) |parent_env| {
            if (swidy.envGet(key, parent_env)) |r| return r;
        }

        return null;
    }

    fn envSet(swidy: *Swidy, key: Value, value: Value, old_env: Value) Value {
        const old_dict, const parent_envs = .{
            swidy.cr(old_env, &.{.left}),
            swidy.cr(old_env, &.{.right}),
        };

        const new_dict = swidy.buildPair(
            swidy.buildPair(key, value),
            old_dict,
        );

        return swidy.buildPair(new_dict, parent_envs);
    }

    fn lookup(swidy: *const Swidy, key: Value, dict: Value) ?Value {
        var it = swidy.listIterator(dict);
        while (it.next()) |pair| {
            const cur_key = swidy.cr(pair, &.{.left});
            const cur_value = swidy.cr(pair, &.{.right});
            if (swidy.eql(key, cur_key)) {
                return cur_value;
            }
        }
        return null;
    }

    fn isLit(swidy: *const Swidy, value: Value, lit: []const u8) bool {
        return value.tag == .string and
            std.mem.eql(u8, lit, swidy.get(value).string);
    }

    fn isNil(swidy: *const Swidy, value: Value) bool {
        return swidy.isLit(value, "nil");
    }

    fn isList(swidy: *const Swidy, value: Value) bool {
        var cur = value;
        while (cur.tag == .pair) {
            cur = swidy.get(cur).pair.right;
        }
        assert(cur.tag == .string);
        return swidy.isLit(cur, "nil");
    }

    fn listIterator(swidy: *const Swidy, list: Value) ListIterator {
        return .{ .swidy = swidy, .cur = list };
    }

    const ListIterator = struct {
        cur: Value,
        swidy: *const Swidy,

        pub fn next(it: *ListIterator) ?Value {
            if (it.cur.tag == .string) {
                if (!it.swidy.isNil(it.cur)) panic("unexpected non-nil sentinel: {s}", .{it.swidy.get(it.cur).string});
                return null;
            } else {
                const result = it.swidy.cr(it.cur, &.{.left});
                it.cur = it.swidy.cr(it.cur, &.{.right});
                return result;
            }
        }
    };

    const Parser = struct {
        fn expect(reader: *std.Io.Reader, expected: []const u8) !void {
            if (!try eat(reader, expected)) return error.BadInput;
        }

        fn eat(reader: *std.Io.Reader, expected: []const u8) !bool {
            const actual = try reader.peek(expected.len);
            if (std.mem.eql(u8, actual, expected)) {
                reader.toss(expected.len);
                return true;
            } else return false;
        }

        fn whitespace(reader: *std.Io.Reader, mandatory: bool) !void {
            var seen_any: bool = false;
            while (blk: {
                const b = reader.peekByte() catch |err| switch (err) {
                    error.EndOfStream => break :blk false,
                    inline else => |x| return x,
                };
                break :blk std.ascii.isWhitespace(b);
            }) {
                reader.toss(1);
                seen_any = true;
            }
            if (mandatory and !seen_any) return error.BadInput;
        }

        // fn fnk(swidy: *Swidy, reader: *std.Io.Reader) !Index {
        //     if (std.mem.eql(u8, "fn", ))
        // }

        // fn tree(swidy: *Swidy, reader: *std.Io.Reader) !Value {
        //     try whitespace(reader, false);
        //     if (reader.peekByte() == '(') {
        //         @panic("TODO");
        //     } else if (reader.peekByte() == '"') {
        //         const literal = swidy.buildString(try reader.takeDelimiter('"'));
        //         return swidy.buildPair(swidy.buildString("lit"), literal);
        //     } else {
        //         @panic("TODO");
        //     }
        // }

        fn sexpr(swidy: *Swidy, reader: *std.Io.Reader) !Value {
            const readHexDigit = struct {
                fn anon(c: u8) ?u8 {
                    return switch (c) {
                        '0'...'9' => c - '0',
                        'a'...'f' => c - 'a' + 10,
                        'A'...'F' => c - 'A' + 10,
                        else => null,
                    };
                }
            }.anon;

            try whitespace(reader, false);
            if (try eat(reader, "(")) {
                // TODO(correctness): remove artificial limit
                var elements_buffer: [128]Value = undefined;

                var elements: std.ArrayList(Value) = .initBuffer(&elements_buffer);
                var sentinel: ?Value = null;

                while (true) {
                    try whitespace(reader, false);
                    if (try eat(reader, ")")) {
                        break;
                    } else if (try eat(reader, ".")) {
                        sentinel = try sexpr(swidy, reader);
                        try whitespace(reader, false);
                        try expect(reader, ")");
                        break;
                    } else {
                        elements.appendBounded(try sexpr(swidy, reader)) catch OoM();
                    }
                }

                return swidy.buildList(elements.items, sentinel);
            } else if (try eat(reader, "\"")) {
                var builder = swidy.buildStringByParts();
                while (true) {
                    const b = try reader.takeByte();

                    switch (b) {
                        '\n' => return error.BadInput,
                        '"' => return builder.result,
                        '\\' => switch (try reader.takeByte()) {
                            // TODO?
                            // 'n',
                            // 'r',
                            // '\\',
                            // 't',
                            // '\'',
                            // '"' => builder.add(&.{"\""}),
                            'x' => {
                                const hi = readHexDigit(try reader.takeByte()) orelse return error.BadInput;
                                const lo = readHexDigit(try reader.takeByte()) orelse return error.BadInput;
                                builder.add(&.{hi * 16 + lo});
                            },
                            else => return error.BadInput,
                        },
                        else => builder.add(&.{b}),
                    }
                }
                // return swidy.buildString(try reader.takeDelimiter('"') orelse return error.BadInput);
            } else {
                // // TODO(correctness): remove artificial limit
                // var string_buffer: [512]u8 = undefined;

                // var string: std.ArrayList(u8) = .initBuffer(&string_buffer);
                // string.
                return error.BadInput;
            }
        }
    };

    fn OoM() noreturn {
        std.debug.panic("OoM", .{});
    }

    // all fnks must be pub, to be visible in reflection
    const BuiltinFnks = struct {
        pub fn identity(swidy: *Swidy, value: Swidy.Value) Swidy.Value {
            _ = swidy;
            return value;
        }

        pub fn @"eqAtoms?"(swidy: *Swidy, value: Swidy.Value) Swidy.Value {
            const result = switch (swidy.get(value)) {
                .string => false,
                .pair => |pair| if (pair.left.tag == .string and pair.right.tag == .string) swidy.eql(pair.left, pair.right) else false,
            };
            return swidy.buildString(if (result) "true" else "false");
        }

        pub fn join(swidy: *Swidy, value: Swidy.Value) Swidy.Value {
            var builder = swidy.buildStringByParts();
            var it = swidy.listIterator(value);
            while (it.next()) |element| {
                if (element.tag != .string) panic("unexpected non-string element: {f}", .{swidy.fmt(element)});
                builder.add(swidy.get(element).string);
            }
            return builder.result;
        }

        pub fn split(swidy: *Swidy, value: Swidy.Value) Swidy.Value {
            if (value.tag != .string) panic("unexpected non-string argument: {f}", .{swidy.fmt(value)});
            const string: Value.String = swidy.slots_strings.items[value.index];

            // TODO(correctness): remove artificial limit
            var elements_buffer: [128]Value = undefined;

            var elements: std.ArrayList(Value) = .initBuffer(&elements_buffer);
            for (0..string.len) |k| {
                const cur = swidy.createCell(.string);
                swidy.slots_strings.items[cur.index] = .{ .start = @intCast(string.start + k), .len = 1 };
                elements.appendBounded(cur) catch OoM();
            }

            return swidy.buildList(elements.items, null);
        }

        pub fn dyncall(swidy: *Swidy, value: Swidy.Value) Swidy.Value {
            // a -> @dyncall: ((stdlib . example) . foo)
            const path = swidy.get(swidy.cr(value, &.{ .left, .left })).string;
            const fnkname = std.mem.concatWithSentinel(swidy.gpa, u8, &.{
                swidy.get(swidy.cr(value, &.{ .left, .right })).string,
            }, 0) catch OoM();
            defer swidy.gpa.free(fnkname);
            const argument = swidy.cr(value, &.{.right});

            var dynlib = std.DynLib.open(path) catch panic("error while opening dynlib {s}", .{path});
            defer dynlib.close();

            const Signature = fn (swidy: *Swidy, value: Swidy.Value) callconv(.c) Swidy.Value;
            const fnk = dynlib.lookup(*const Signature, fnkname) orelse
                panic("couldn't find fn {s} in dynlib {s}", .{ fnkname, path });

            return fnk(swidy, argument);
        }

        // pub fn add_u8_u8(swidy: *Swidy, value: Swidy.Value) Swidy.Value {
        //     std.mem.readInt(comptime T: type, buffer: *const [?]u8, endian: Endian)
        //     switch (swidy.get(value)) {
        //         .bytes => return 1,
        //         .pair => return 2,
        //     }
        //     return value;
        // }
    };
};

// (ffi "add" (23.0f 12.0f))

pub fn main2(init: std.process.Init) !u8 {
    const io = init.io;

    const args = (try init.minimal.args.toSlice(init.arena.allocator()))[1..];
    if (args.len != 1) {
        std.log.err("expected exactly 1 arg", .{});
        return 1;
    }
    const filename = args[0];

    var swidy: Swidy = .init(init.gpa);
    defer swidy.deinit();

    const cwd: std.Io.Dir = .cwd();
    const file = try cwd.openFile(io, filename, .{ .resolve_beneath = true, .allow_directory = false });
    var file_buffer: [1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);

    const main_expr = try Swidy.Parser.sexpr(&swidy, &file_reader.interface);
    const result = swidy.eval(
        swidy.cr(main_expr, &.{ .left, .left }),
        swidy.cr(main_expr, &.{ .left, .right }),
        swidy.cr(main_expr, &.{.right}),
    );

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try stdout_writer.print("{f}\n", .{swidy.fmt(result)});

    try stdout_writer.flush();

    return 0;
}

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

test "sexpr parsing" {
    var swidy: Swidy = .init(std.testing.allocator);
    defer swidy.deinit();

    const tests: []const @Tuple(&.{ []const u8, Swidy.Value }) = &.{
        .{ "\"hi\"", swidy.buildString("hi") },
        .{ "(\"hi\" . \"hey\")", swidy.buildPair(swidy.buildString("hi"), swidy.buildString("hey")) },
        .{ "(\"hi\")", swidy.buildPair(swidy.buildString("hi"), swidy.buildString("nil")) },
        .{ "(\"hi\" \"hey\")", swidy.buildPair(swidy.buildString("hi"), swidy.buildPair(swidy.buildString("hey"), swidy.buildString("nil"))) },
        .{ "()", swidy.buildString("nil") },
        .{ "( . \"nil\")", swidy.buildString("nil") },
        .{ "(\"hi\" \"hey\" . \"bye\")", swidy.buildPair(swidy.buildString("hi"), swidy.buildPair(swidy.buildString("hey"), swidy.buildString("bye"))) },
    };

    for (tests) |test_case| {
        var source: std.Io.Reader = .fixed(test_case[0]);
        try swidy.expectEqual(
            test_case[1],
            try Swidy.Parser.sexpr(&swidy, &source),
        );
    }
}

test "fnk" {
    var swidy: Swidy = .init(std.testing.allocator);
    defer swidy.deinit();

    // a list of (name . body) pairs,
    // with body being a list of cases,
    // with a case being ((pattern . template) . (fnkname . next)),
    const known_fnks: Swidy.Value = blk: {
        var source: std.Io.Reader = .fixed(
            \\ (("myFunc" . (
            \\      ((("lit" . "a") . ("lit" . "b")) . (("lit" . "@identity") . ()))
            \\      ((("var" . "x") . (("var" . "x") . ("var" . "x"))) . (("lit" . "@identity") . ()))
            \\ )))
        );
        break :blk try Swidy.Parser.sexpr(&swidy, &source);
    };
    const fnkname = swidy.buildString("myFunc");

    if (true) {
        const input_value = swidy.buildString("a");
        const result = swidy.eval(fnkname, input_value, known_fnks);
        try swidy.expectEqual(swidy.buildString("b"), result);
    }

    if (true) {
        const input_value = swidy.buildString("b");
        const result = swidy.eval(fnkname, input_value, known_fnks);
        try swidy.expectEqual(
            swidy.buildPair(
                swidy.buildString("b"),
                swidy.buildString("b"),
            ),
            result,
        );
    }
}

test "builtins" {
    var swidy: Swidy = .init(std.testing.allocator);
    defer swidy.deinit();

    const known_fnks: Swidy.Value = blk: {
        var source: std.Io.Reader = .fixed(
            \\ (("myFunc" . (
            \\      ((("lit" . "a") . ("lit" . "b")) . (("lit" . "@identity") . ()))
            \\      ((("lit" . "b") . (("lit" . "b") . ("lit" . "b"))) . (("lit" . "@eqAtoms?") . ()))
            \\      ((("lit" . "c") . (("lit" . "b") . ("lit" . "c"))) . (("lit" . "@eqAtoms?") . ()))
            \\      ((("lit" . "d") . (("lit" . "a") . (("lit" . "b") . ("lit" . "nil")))) . (("lit" . "@join") . ()))
            \\      ((("lit" . "e") . ("lit" . "ab")) . (("lit" . "@split") . ()))
            \\ )))
        );
        break :blk try Swidy.Parser.sexpr(&swidy, &source);
    };
    const fnkname = swidy.buildString("myFunc");

    if (true) {
        const input_value = swidy.buildString("a");
        const result = swidy.eval(fnkname, input_value, known_fnks);
        try swidy.expectEqual(swidy.buildString("b"), result);
    }

    if (true) {
        const input_value = swidy.buildString("b");
        const result = swidy.eval(fnkname, input_value, known_fnks);
        try swidy.expectEqualAsStrings(swidy.buildString("true"), result, std.testing.allocator);
    }

    if (true) {
        const input_value = swidy.buildString("c");
        const result = swidy.eval(fnkname, input_value, known_fnks);
        try swidy.expectEqualAsStrings(swidy.buildString("false"), result, std.testing.allocator);
    }

    if (true) {
        const input_value = swidy.buildString("d");
        const result = swidy.eval(fnkname, input_value, known_fnks);
        try swidy.expectEqualAsStrings(swidy.buildString("ab"), result, std.testing.allocator);
    }

    if (true) {
        const input_value = swidy.buildString("e");
        const result = swidy.eval(fnkname, input_value, known_fnks);
        try swidy.expectEqualAsStrings(swidy.buildList(&.{ swidy.buildString("a"), swidy.buildString("b") }, null), result, std.testing.allocator);
    }
}

pub const Debugger = struct {
    swidy: *Swidy,
    active_value: Swidy.Value,
    /// list of pairs of (next_cases, env); always has at least one element (the debugger state)
    stack: Swidy.Value,

    pub fn init(swidy: *Swidy) Debugger {
        return .{
            .swidy = swidy,
            .active_value = swidy.buildString("nil"),
            .stack = swidy.buildSexpr("((() . (() . ())))") catch unreachable,
        };
    }

    fn testHelper(debugger: *Debugger, in: []const u8, expected_out: []const u8) !void {
        const in_value = try debugger.swidy.buildSexpr(in);
        const expected_out_value = try debugger.swidy.buildSexpr(expected_out);
        const out = debugger.do(in_value);
        try debugger.swidy.expectEqual(expected_out_value, out);
    }

    pub fn doOld(debugger: *Debugger, in: Swidy.Value) !Swidy.Value {
        const swidy = debugger.swidy;
        if (in.tag != .pair) return swidy.buildString("#error");
        var it = swidy.listIterator(in);
        const command = it.next() orelse return swidy.buildString("#error");
        if (false) { // hardcoded check for all commands
        } else if (swidy.isLit(command, "set")) {
            const key = it.next() orelse return swidy.buildString("#error");
            const value = it.next() orelse return swidy.buildString("#error");
            if (it.next() != null) return swidy.buildString("#error");

            debugger.addVar(key, value);

            return swidy.buildString("#inert");
        } else if (swidy.isLit(command, "lookup")) {
            const key = it.next() orelse return swidy.buildString("#error");
            if (it.next() != null) return swidy.buildString("#error");

            const value = swidy.envGet(key, debugger.activeEnv()) orelse return swidy.buildString("#undefined");

            return swidy.buildPair(swidy.buildString("#found"), value);
        } else if (swidy.isLit(command, "fill")) {
            const template = it.next() orelse return swidy.buildString("#error");
            if (it.next() != null) return swidy.buildString("#error");

            const value = swidy.fillFromEnv(template, debugger.activeEnv()) catch return swidy.buildString("#error");

            return value;
        } else if (swidy.isLit(command, "debug")) {
            const fnkname = it.next() orelse return swidy.buildString("#error");
            const value = it.next() orelse return swidy.buildString("#error");
            if (it.next() != null) return swidy.buildString("#error");

            debugger.active_value = value;
            debugger.callFnk(fnkname);

            return swidy.buildString("#inert");
            // } else if (swidy.isLit(command, "step")) {
            //     if (it.next() != null) return swidy.buildString("#error");
            //     if (!swidy.isNil(debugger.next_cases)) {
            //         const active_case = swidy.cr(debugger.next_cases, &.{.left});
            //         debugger.next_cases = swidy.cr(debugger.next_cases, &.{.right});

            //         const pattern = swidy.cr(active_case, &.{ .left, .left });
            //         const template = swidy.cr(active_case, &.{ .left, .right });
            //         const fnkname_template = swidy.cr(active_case, &.{ .right, .left });
            //         const next = swidy.cr(active_case, &.{ .right, .right });

            //         if (swidy.generateBindingsIntoEnv(pattern, debugger.active_value, debugger.env)) |new_env| {
            //             debugger.env = new_env;
            //             debugger.active_value = swidy.fillFromEnv(template, debugger.env) catch return swidy.buildString("#error");
            //             debugger.stack =
            //         }
            //     }
        } else return swidy.buildString("#error");
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
        } else if (swidy.isLit(command, "prependCase")) {
            const case = it.next() orelse return swidy.buildString("#error");
            if (it.next() != null) return swidy.buildString("#error");

            debugger.prependCase(case);

            return swidy.buildString("#inert");
        } else if (swidy.isLit(command, "runAll")) {
            if (it.next() != null) return swidy.buildString("#error");

            // TODO(now)
            for (0..100) |_| {
                debugger.step() catch return swidy.buildString("#error");
            }

            return swidy.buildString("#inert");
        } else if (swidy.isLit(command, "step")) {
            if (it.next() != null) return swidy.buildString("#error");

            debugger.step() catch return swidy.buildString("#error");

            return swidy.buildString("#inert");
        } else return swidy.buildString("#error");
    }

    fn addVar(debugger: *Debugger, key: Swidy.Value, value: Swidy.Value) void {
        const swidy = debugger.swidy;

        const active_stack, const rest_stack = swidy.splitPair(debugger.stack);
        const active_cases, const active_env = swidy.splitPair(active_stack);

        const new_active_env = swidy.envSet(key, value, active_env);
        const new_active_stack = swidy.buildPair(active_cases, new_active_env);
        debugger.stack = swidy.buildPair(new_active_stack, rest_stack);
    }

    fn activeEnv(debugger: *Debugger) Swidy.Value {
        const swidy = debugger.swidy;

        const active_stack, const rest_stack = swidy.splitPair(debugger.stack);
        const active_cases, const active_env = swidy.splitPair(active_stack);
        _ = rest_stack;
        _ = active_cases;

        return active_env;
    }

    fn prependCase(debugger: *Debugger, case: Swidy.Value) void {
        const swidy = debugger.swidy;

        const active_stack, const rest_stack = swidy.splitPair(debugger.stack);
        const active_cases, const active_env = swidy.splitPair(active_stack);

        const new_active_cases = swidy.buildPair(case, active_cases);
        const new_active_stack = swidy.buildPair(new_active_cases, active_env);
        debugger.stack = swidy.buildPair(new_active_stack, rest_stack);
    }

    fn step(debugger: *Debugger) !void {
        const swidy = debugger.swidy;

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

                // TODO(now): generalize
                if (swidy.isLit(fnkname, "@identity")) {
                    debugger.active_value = active_value;
                    const new_active_stack = swidy.buildPair(next, new_active_env);
                    debugger.stack = swidy.buildPair(new_active_stack, rest_stack);
                } else @panic("TODO");
            } else {
                const new_active_stack = swidy.buildPair(rest_cases, active_env);
                debugger.stack = swidy.buildPair(new_active_stack, rest_stack);
            }
        } else if (!swidy.isNil(rest_stack)) {
            debugger.stack = rest_stack;
        }
    }

    // fn callFnk(debugger: *Debugger, fnkname: Swidy.Value) void {
    //     const swidy = debugger.swidy;

    //     const fnkname_body = swidy.envGet(fnkname, debugger.env) orelse swidy.buildString("nil");
    //     assert(swidy.isList(fnkname_body));
    //     debugger.next_cases = fnkname_body;
    //     debugger.stack = swidy.buildString("nil");
    // }
};

test "debugger again" {
    var swidy: Swidy = .init(std.testing.allocator);
    defer swidy.deinit();

    var debugger: Debugger = .init(&swidy);

    try debugger.testHelper(
        \\ ("setActive" (
        \\   (((("var" . "x") . ("lit" . "Z")) . ("var" . "x")) . (("lit" . "@identity") . ()))
        \\   (((("var" . "x") . (("lit" . "S") . ("var" . "y"))) . ((("lit" . "S") . ("var" . "x")) . ("var" . "y"))) . (("lit" . "sum") . ()))
        \\ ))
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("prependCase"
        \\   ((("var" . "sum") . ("lit" . "nil")) . (("lit" . "@identity") . ()))
        \\ )
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("runAll")
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("prependCase"
        \\   ((("var" . "_") . ("var" . "sum")) . (("lit" . "@identity") . ()))
        \\ )
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
        \\ (
        \\   (((("var" . "x") . ("lit" . "Z")) . ("var" . "x")) . (("lit" . "@identity") . ()))
        \\   (((("var" . "x") . (("lit" . "S") . ("var" . "y"))) . ((("lit" . "S") . ("var" . "x")) . ("var" . "y"))) . (("lit" . "sum") . ()))
        \\ )
    );
}

test "debugger" {
    if (true) return error.SkipZigTest;

    var swidy: Swidy = .init(std.testing.allocator);
    defer swidy.deinit();

    var debugger: Debugger = .init(&swidy);

    try debugger.testHelper(
        \\ ("set" "sum" (
        \\   (((("var" . "x") . ("lit" . "Z")) . ("var" . "x")) . (("lit" . "@identity") . ()))
        \\   (((("var" . "x") . (("lit" . "S") . ("var" . "y"))) . ((("lit" . "S") . ("var" . "x")) . ("var" . "y"))) . (("lit" . "sum") . ()))
        \\ ))
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("lookup" "sum")
    ,
        \\ ("#found" . (
        \\   (((("var" . "x") . ("lit" . "Z")) . ("var" . "x")) . (("lit" . "@identity") . ()))
        \\   (((("var" . "x") . (("lit" . "S") . ("var" . "y"))) . ((("lit" . "S") . ("var" . "x")) . ("var" . "y"))) . (("lit" . "sum") . ()))
        \\ ))
    );

    try debugger.testHelper(
        \\ ("fill" ("var" . "sum"))
    ,
        \\ (
        \\   (((("var" . "x") . ("lit" . "Z")) . ("var" . "x")) . (("lit" . "@identity") . ()))
        \\   (((("var" . "x") . (("lit" . "S") . ("var" . "y"))) . ((("lit" . "S") . ("var" . "x")) . ("var" . "y"))) . (("lit" . "sum") . ()))
        \\ )
    );

    try debugger.testHelper(
        \\ ("fill" ("var" . "foo"))
    ,
        \\ "#error"
    );

    try debugger.testHelper(
        \\ ("debug" "sum" (("S" . ("S" . "Z")) . ("S" . ("S" . "Z"))))
    ,
        \\ "#inert"
    );

    // try debugger.testHelper(
    //     \\ ("see" "active_value")
    // ,
    //     \\ (("S" . ("S" . "Z")) . ("S" . ("S" . "Z")))
    // );

    // try debugger.testHelper(
    //     \\ ("step")
    // ,
    //     \\ "#inert"
    // );

    // try debugger.testHelper(
    //     \\ ("see" "active_value")
    // ,
    //     \\ (("S" . ("S" . "Z")) . ("S" . ("S" . "Z")))
    // );

    // try debugger.testHelper(
    //     \\ ("see" "cases")
    // ,
    //     \\ (
    //     \\   (((("var" . "x") . (("lit" . "S") . ("var" . "y"))) . ((("lit" . "S") . ("var" . "x")) . ("var" . "y"))) . (("lit" . "sum") . ()))
    //     \\ )
    // );

    // try debugger.testHelper(
    //     \\ ("step")
    // ,
    //     \\ "#inert"
    // );

    // try debugger.testHelper(
    //     \\ ("see" "active_value")
    // ,
    //     \\ ("S" . ("S" . ("S" . ("S" . "Z"))))
    // );

    // try debugger.testHelper(
    //     \\ ("see" "cases")
    // ,
    //     \\ ()
    // );

    // try debugger.testHelper(
    //     \\ ("debug" "sum" (("S" . ("S" . "Z")) . ("S" . ("S" . "Z"))))
    // ,
    //     \\ "#inert"
    // );

    // try debugger.testHelper(
    //     \\ ("step")
    // ,
    //     \\ "#inert"
    // );

    // try debugger.testHelper(
    //     \\ ("see" "cases")
    // ,
    //     \\ (
    //     \\   (((("var" . "x") . (("lit" . "S") . ("var" . "y"))) . ((("lit" . "S") . ("var" . "x")) . ("var" . "y"))) . (("lit" . "sum") . ()))
    //     \\ )
    // );

    // try debugger.testHelper(
    //     \\ ("step_into")
    // ,
    //     \\ "#inert"
    // );

    // const input, const fnkname, const all_fnks = blk: {
    //     var asdf_reader: std.Io.Reader = .fixed(
    //         \\(("sum" . (("S" . ("S" . "Z")) . ("S" . ("S" . "Z")))) . (
    //         \\  ("sum" . (
    //         \\    (((("var" . "x") . ("lit" . "Z")) . ("var" . "x")) . (("lit" . "@identity") . ()))
    //         \\    (((("var" . "x") . (("lit" . "S") . ("var" . "y"))) . ((("lit" . "S") . ("var" . "x")) . ("var" . "y"))) . (("lit" . "sum") . ()))
    //         \\  ))
    //         \\))
    //     );
    //     const asdf = try Swidy.Parser.sexpr(&swidy, &asdf_reader);
    //     const input = swidy.cr(asdf, &.{ .left, .right });
    //     const fnkname = swidy.cr(asdf, &.{ .left, .left });
    //     const all_fnks = swidy.cr(asdf, &.{.right});
    //     break :blk .{ input, fnkname, all_fnks };
    // };
    // var debugger: Debugger =
}

pub const Editor = struct {
    swidy: Swidy,
    state: Swidy.Value,

    pub fn initFromString(gpa: std.mem.Allocator, str: []const u8) !Editor {
        var swidy: Swidy = .init(gpa);
        var reader: std.Io.Reader = .fixed(str);
        const doc = try Swidy.Parser.sexpr(&swidy, &reader);
        return .{ .swidy = swidy, .state = doc };
    }

    test "foo" {
        var editor: Editor = try .initFromString(std.testing.allocator, "()");
        defer editor.swidy.deinit();

        // command: create fnk
        editor.sendLine("fnk");
        // name of the fnk
        editor.sendLine("sum");

        editor.sendLine("newcase");
        editor.sendLine("(x . \"Z\")");
        editor.sendLine("@identity");
        editor.sendLine("x");
        editor.sendLine(";");

        editor.sendLine("newcase");
        editor.sendLine("(x . (\"S\" . rest))");
        editor.sendLine("sum");
        editor.sendLine("((\"S\" . x) . rest)");
        editor.sendLine(";");

        editor.sendLine("do");
        editor.sendLine("sum");
        editor.sendLine("(\"Z\" . \"Z\")");
    }
};

// comptime {
//     _ = Editor;
// }

// const source: std.io.Reader = .fixed(
//     \\ fn myFunc {
//     \\     "a" -> "b";
//     \\ }
//     \\
//     \\ main myFunc: "a";
// );
