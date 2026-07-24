const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const panic = std.debug.panic;

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

    pub fn createCell(swidy: *Swidy, comptime tag: Tag) Value {
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

    pub fn buildSexpr(swidy: *Swidy, str: []const u8) !Value {
        errdefer std.log.err("failed to build sexpr for input {s}", .{str});
        var reader: std.Io.Reader = .fixed(str);
        const result = try Parser.eatSexpr(swidy, &reader, .explicit);
        try Parser.whitespace(&reader, false);
        if (reader.bufferedLen() > 0) return error.MoreThanOneSexpr;
        return result;
    }

    pub fn buildPair(swidy: *Swidy, left: Value, right: Value) Value {
        const result = swidy.createCell(.pair);
        swidy.slots_pairs.items[result.index] = .{ .left = left, .right = right };
        return result;
    }

    pub fn splitPair(swidy: *Swidy, value: Value) [2]Value {
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

    pub fn buildList(swidy: *Swidy, elements: []const Value, sentinel: ?Value) Value {
        var result = sentinel orelse swidy.buildString("nil");
        var it = std.mem.reverseIterator(elements);
        while (it.next()) |element| {
            result = swidy.buildPair(element, result);
        }
        return result;
    }

    pub fn cr(swidy: *const Swidy, value: Value, address: []const enum { left, right }) Value {
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

    pub fn isLit(swidy: *const Swidy, value: Value, lit: []const u8) bool {
        return value.tag == .string and
            std.mem.eql(u8, lit, swidy.get(value).string);
    }

    pub fn isNil(swidy: *const Swidy, value: Value) bool {
        return swidy.isLit(value, "nil");
    }

    pub fn isList(swidy: *const Swidy, value: Value) bool {
        var cur = value;
        while (cur.tag == .pair) {
            cur = swidy.get(cur).pair.right;
        }
        assert(cur.tag == .string);
        return swidy.isLit(cur, "nil");
    }

    pub fn listIterator(swidy: *const Swidy, list: Value) ListIterator {
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

    pub const Parser = struct {
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

        pub fn whitespace(reader: *std.Io.Reader, mandatory: bool) !void {
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

        pub fn atEnd(reader: *std.Io.Reader) !bool {
            _ = reader.peekByte() catch |err| switch (err) {
                error.EndOfStream => return true,
                inline else => |x| return x,
            };
            return false;
        }

        pub fn eatSexpr(swidy: *Swidy, reader: *std.Io.Reader, mode: enum { tree, explicit }) !Value {
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
                        sentinel = try eatSexpr(swidy, reader, mode);
                        try whitespace(reader, false);
                        try expect(reader, ")");
                        break;
                    } else {
                        elements.appendBounded(try eatSexpr(swidy, reader, mode)) catch OoM();
                    }
                }

                return swidy.buildList(elements.items, if (mode == .tree)
                    sentinel orelse swidy.buildPair(swidy.buildString("lit"), swidy.buildString("nil"))
                else
                    sentinel);
            } else {
                const word = try eatWord(swidy, reader);
                if (mode == .explicit and !word.quoted) return error.BadInput;
                if (mode == .tree) return swidy.buildPair(swidy.buildString(if (word.quoted) "lit" else "var"), word.value);
                return word.value;
            }
        }

        pub fn eatFnk(swidy: *Swidy, reader: *std.Io.Reader) !Value {
            const fnkname = try eatSexpr(swidy, reader, .explicit);
            const fnkbody = try eatCases(swidy, reader);
            return swidy.buildPair(fnkname, swidy.buildPair(
                swidy.buildString("fnkbody"),
                fnkbody,
            ));
        }

        fn eatCases(swidy: *Swidy, reader: *std.Io.Reader) !Value {
            try whitespace(reader, false);
            try expect(reader, "{");

            // TODO(correctness): remove artificial limit
            var cases_buffer: [128]Value = undefined;
            var cases: std.ArrayList(Value) = .initBuffer(&cases_buffer);

            try whitespace(reader, false);
            while (!try eat(reader, "}")) {
                const pattern = try eatSexpr(swidy, reader, .tree);

                try whitespace(reader, false);
                try expect(reader, "->");

                const fnkname_or_template = try eatSexpr(swidy, reader, .tree);
                try whitespace(reader, false);

                const fnkname, const template = if (try eat(reader, ":"))
                    .{ fnkname_or_template, try eatSexpr(swidy, reader, .tree) }
                else
                    .{ swidy.buildPair(swidy.buildString("lit"), swidy.buildString("@identity")), fnkname_or_template };

                try whitespace(reader, false);

                const nested = if (try eat(reader, ";"))
                    swidy.buildString("nil")
                else
                    try eatCases(swidy, reader);

                try cases.appendBounded(swidy.buildPair(
                    swidy.buildPair(pattern, template),
                    swidy.buildPair(fnkname, nested),
                ));

                try whitespace(reader, false);
            }

            return swidy.buildList(cases.items, null);
        }

        fn eatWord(swidy: *Swidy, reader: *std.Io.Reader) !struct { quoted: bool, value: Value } {
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

            const word_borders = "(){}.:;\"<>" ++ std.ascii.whitespace;

            try whitespace(reader, false);
            if (try eat(reader, "\"")) { // read a quoted value
                var builder = swidy.buildStringByParts();
                const result = blk: while (true) {
                    const b = try reader.takeByte();

                    switch (b) {
                        '\n' => return error.BadInput,
                        '"' => break :blk builder.result,
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
                };
                return .{ .quoted = true, .value = result };
            } else if (std.mem.indexOfScalar(u8, word_borders, try reader.peekByte()) == null) {
                var builder = swidy.buildStringByParts();
                const result = blk: while (true) {
                    if (try atEnd(reader)) break :blk builder.result;
                    const b = try reader.peekByte();
                    if (std.mem.indexOfScalar(u8, word_borders, b) != null) {
                        break :blk builder.result;
                    } else {
                        reader.toss(1);
                        builder.add(&.{b});
                    }
                };
                return .{ .quoted = false, .value = result };
            } else return error.BadInput;
        }
    };

    pub fn OoM() noreturn {
        std.debug.panic("OoM", .{});
    }

    pub fn generateBindingsIntoEnv(swidy: *Swidy, pattern: Value, value: Value, env: Value) ?Value {
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

    pub fn envSet(swidy: *Swidy, key: Value, value: Value, old_env: Value) Value {
        return swidy.buildPair(
            swidy.buildPair(key, value),
            old_env,
        );
    }

    pub fn envGet(swidy: *const Swidy, key: Value, env: Value) ?Value {
        var it = swidy.listIterator(env);
        while (it.next()) |pair| {
            const cur_key = swidy.cr(pair, &.{.left});
            const cur_value = swidy.cr(pair, &.{.right});
            if (swidy.eql(key, cur_key)) {
                return cur_value;
            }
        }
        return null;
    }

    pub fn envAllKeys(swidy: *Swidy, env: Value) Value {
        var elements: std.ArrayList(Value) = .empty;
        defer elements.deinit(swidy.gpa);

        var it = swidy.listIterator(env);
        while (it.next()) |pair| {
            const cur_key, const cur_value = swidy.splitPair(pair);
            _ = cur_value;
            elements.append(swidy.gpa, cur_key) catch OoM();
        }

        return swidy.buildList(elements.items, null);
    }

    pub fn fillFromEnv(swidy: *Swidy, template: Value, env: Value) !Value {
        errdefer std.log.err("some error for template {f} and env {f}", .{ swidy.fmt(template), swidy.fmt(env) });
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
                try Swidy.Parser.eatSexpr(&swidy, &source, .explicit),
            );
        }
    }

    test "fnk parsing" {
        var swidy: Swidy = .init(std.testing.allocator);
        defer swidy.deinit();

        const text =
            \\"sum" {
            \\  ("+1" . y) -> ("foo" . y): ("z" . x);
            \\  ("+2" . y) -> ("foo" . y): ("z" . x) {
            \\    ("+1" . y) -> ("z" . x);
            \\  }
            \\}
            \\
        ;
        var source: std.Io.Reader = .fixed(text);
        _ = try Parser.eatFnk(&swidy, &source);
    }
};

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
        env = swidy.envSet(swidy.buildString("@breakpoint"), swidy.buildPair(
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
        try debugger.swidy.expectEqualAsStrings(expected_out_value, out, debugger.swidy.gpa);
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
                const hit_breakpoint = debugger.step() catch return swidy.buildString("#error");
                if (hit_breakpoint) break;
            }

            return swidy.buildString("#inert");
        } else if (swidy.isLit(command, "step")) {
            if (it.next() != null) return swidy.buildString("#error");

            _ = debugger.step() catch return swidy.buildString("#error");

            return swidy.buildString("#inert");
        } else return swidy.buildString("#error");
    }

    pub fn runAllWithoutBreakpoints(debugger: *Debugger) !void {
        while (!debugger.swidy.isNil(debugger.stack)) {
            _ = try debugger.step();
        }
    }

    pub fn call(debugger: *Debugger, fnkname: Swidy.Value) !void {
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

    /// returns true if it hit a breakpoint
    pub fn step(debugger: *Debugger) !bool {
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
                    return swidy.isLit(fnkname, "@breakpoint");
                } else {
                    const new_active_stack = swidy.buildPair(rest_cases, active_env);
                    debugger.stack = swidy.buildPair(new_active_stack, rest_stack);
                }
            } else {
                debugger.stack = rest_stack;
            }
        }

        return false;
    }

    pub fn addFnks(debugger: *Debugger, reader: *std.Io.Reader) !void {
        try Swidy.Parser.whitespace(reader, false);
        while (!try Swidy.Parser.atEnd(reader)) {
            const another = try Swidy.Parser.eatFnk(debugger.swidy, reader);
            debugger.all_fnks = debugger.swidy.buildPair(another, debugger.all_fnks);
            try Swidy.Parser.whitespace(reader, false);
        }
    }
};

test "run" {
    const code =
        \\ "sum" {
        \\     ("nil" . y) -> "@identity": y;
        \\     (("+1" . x) . y) -> "sum": (x . ("+1" . y));
        \\ }
        \\ "mul" {
        \\     ("nil" . y) -> "@identity": "nil";
        \\     (("+1" . x) . y) -> "mul": (x . y) {
        \\         x_times_y -> "sum": (x_times_y  . y);
        \\     }
        \\ }
        \\ "main" {
        \\     _ -> "mul": (
        \\         ("+1" "+1")
        \\         .
        \\         ("+1" "+1" "+1")
        \\     );
        \\ }
    ;
    const expected =
        \\ ("+1" "+1" "+1" "+1" "+1" "+1")
    ;

    var swidy: Swidy = .init(std.testing.allocator);
    defer swidy.deinit();

    var debugger: Debugger = .init(&swidy);
    var source: std.Io.Reader = .fixed(code);
    try debugger.addFnks(&source);
    try debugger.call(swidy.buildString("main"));
    try debugger.runAllWithoutBreakpoints();

    const expected_value = try debugger.swidy.buildSexpr(expected);
    try debugger.swidy.expectEqualAsStrings(expected_value, debugger.active_value, debugger.swidy.gpa);
}

test "editor" {
    var swidy: Swidy = .init(std.testing.allocator);
    defer swidy.deinit();

    var debugger: Debugger = .init(&swidy);

    try debugger.testHelper(
        \\ ("addFnk" "setAt" (
        \\   (((("var" . "value") ("lit" . "nil") ("var" . "newpart") . ("lit" . "nil")) . ("var" . "newpart")) . (("lit" . "@identity") . ()))
        \\   ((((("var" . "value_left") . ("var" . "value_right")) (("lit" . "left") . ("var" . "rest")) ("var" . "newpart") . ("lit" . "nil")) . 
        \\       (("var" . "value_left") ("var" . "rest") ("var" . "newpart") . ("lit" . "nil"))) . (("lit" . "setAt") . (
        \\           ((("var" . "newvalue") . (("var" . "newvalue") . ("var" . "value_right"))) . (("lit" . "@identity") . ()))
        \\   )))
        \\   ((((("var" . "value_left") . ("var" . "value_right")) (("lit" . "right") . ("var" . "rest")) ("var" . "newpart") . ("lit" . "nil")) . 
        \\       (("var" . "value_right") ("var" . "rest") ("var" . "newpart") . ("lit" . "nil"))) . (("lit" . "setAt") . (
        \\           ((("var" . "newvalue") . (("var" . "value_left") . ("var" . "newvalue"))) . (("lit" . "@identity") . ()))
        \\   )))
        \\   ((("var" . "other") . ("lit" . "bad args!")) . (("lit" . "@identity") . ()))
        \\ ))
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("setActive" (("foo" "bar" "baz") ("right" "left") "xxx"))
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("call" "setAt")
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
        \\ ("foo" "xxx" "baz")
    );

    try debugger.testHelper(
        \\ ("addFnk" "getAt" (
        \\   (((("var" . "value") . ("lit" . "nil")) . ("var" . "value")) . (("lit" . "@identity") . ()))
        \\   ((((("var" . "value_left") . ("var" . "value_right")) . (("lit" . "left") . ("var" . "rest"))) . 
        \\       (("var" . "value_left") . ("var" . "rest"))) . (("lit" . "getAt") . ()))
        \\   ((((("var" . "value_left") . ("var" . "value_right")) . (("lit" . "right") . ("var" . "rest"))) . 
        \\       (("var" . "value_right") . ("var" . "rest"))) . (("lit" . "getAt") . ()))
        \\   ((("var" . "other") . ("lit" . "bad args!")) . (("lit" . "@identity") . ()))
        \\ ))
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("addFnk" "dynamicChangeAt" (
        \\   (((("var" . "value") . ("var" . "address")) . (("var" . "value") . ("var" . "address"))) . (("lit" . "getAt") . (
        \\       ((("var" . "old_value") . ("var" . "old_value")) . (("lit" . "@breakpoint") . (
        \\            ((("var" . "new_value") . (("var" . "value") ("var" . "address") ("var" . "new_value") . ("lit" . "nil"))) . (("lit" . "setAt") . ()))
        \\       )))
        \\   )))
        \\ ))
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("setActive" (("foo" "bar" "baz") . ("right" "left")))
    ,
        \\ "#inert"
    );

    try debugger.testHelper(
        \\ ("call" "dynamicChangeAt")
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
        \\ "bar"
    );

    try debugger.testHelper(
        \\ ("setActive" "xxx")
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
        \\ ("foo" "xxx" "baz")
    );

    // _ =
    //     \\ changeAtDynamic {
    //     \\   ( address . ( activeValue . _ ) -> getAt: (address . activeValue) {
    //     \\       old_value -> debugStop: old_value { // user should now setActiveValue
    //     \\           new_value -> setAt: (address . new_value) {
    //     \\              foo -> setActiveValue: foo;
    //     \\           }
    //     \\      }
    //     \\   }
    //     \\ }
    // ;
}

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
