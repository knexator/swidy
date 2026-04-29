const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

// builtin: identity (maybe), eqAtoms?, split, concat, addu32u32 (etc)

// keep all fnks as values?

pub fn add(swidy: *Swidy, value: Swidy.Value) Swidy.Value {
    switch (swidy.get(value)) {
        .bytes => return 1,
        .pair => return 2,
    }
    // return value;
}

comptime {
    std.testing.refAllDecls(Swidy);
    _ = add;
}

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

    pub fn buildPair(swidy: *Swidy, left: Value, right: Value) Value {
        const result = swidy.createCell(.pair);
        swidy.slots_pairs.items[result.index] = .{ .left = left, .right = right };
        return result;
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

    fn buildList(swidy: *Swidy, elements: []const Value, sentinel: ?Value) Value {
        var result = sentinel orelse swidy.buildString("nil");
        var it = std.mem.reverseIterator(elements);
        while (it.next()) |element| {
            result = swidy.buildPair(element, result);
        }
        return result;
    }

    fn cr(swidy: *const Swidy, value: Value, address: []const enum { left, right }) Value {
        var result = value;
        for (address) |dir| {
            const pair = swidy.get(result).pair;
            result = switch (dir) {
                .left => pair.left,
                .right => pair.right,
            };
        }
        return result;
    }

    pub fn eval(swidy: *Swidy, fnkname: Value, input: Value, known_fnks: Value) Value {
        const fnkbody = swidy.lookup(fnkname, known_fnks) orelse swidy.buildString("nil");
        return swidy.eval_inner(fnkbody, input, swidy.buildString("nil"), known_fnks);
    }

    fn eval_inner(swidy: *Swidy, fnkbody: Value, input: Value, parent_bindings: Value, known_fnks: Value) Value {
        var it = swidy.listIterator(fnkbody);
        while (it.next()) |case| {
            const pattern = swidy.cr(case, &.{ .left, .left });
            const template = swidy.cr(case, &.{ .left, .right });
            const fnkname = swidy.cr(case, &.{ .right, .left });
            const next = swidy.cr(case, &.{ .right, .right });

            if (swidy.generateBindings(pattern, input)) |bindings| {
                const all_bindings = swidy.concat(&.{ bindings, parent_bindings });
                const new_input_v1 = swidy.fillBindings(template, all_bindings);
                const new_input_v2 = swidy.eval(fnkname, new_input_v1, known_fnks);
                return swidy.eval_inner(next, new_input_v2, all_bindings, known_fnks);
            }
        }
        return input;
    }

    fn generateBindings(swidy: *Swidy, pattern: Value, value: Value) ?Value {
        switch (swidy.get(pattern)) {
            .string => unreachable,
            .pair => |pattern_pair| {
                if (pattern_pair.left.tag == .string) {
                    if (swidy.isLit(pattern_pair.left, "lit")) {
                        return if (swidy.eql(pattern_pair.right, value)) swidy.buildString("nil") else null;
                    } else if (swidy.isLit(pattern_pair.left, "var")) {
                        assert(pattern_pair.right.tag == .string);
                        return swidy.buildList(&.{swidy.buildPair(pattern_pair.right, value)}, null);
                    } else unreachable;
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

    fn fillBindings(swidy: *Swidy, template: Value, bindings: Value) Value {
        switch (swidy.get(template)) {
            .string => unreachable,
            .pair => |template_pair| {
                if (template_pair.left.tag == .string) {
                    if (swidy.isLit(template_pair.left, "lit")) {
                        return template_pair.right;
                    } else if (swidy.isLit(template_pair.left, "var")) {
                        assert(template_pair.right.tag == .string);
                        return swidy.lookup(template_pair.right, bindings) orelse unreachable;
                    } else unreachable;
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

    fn listIterator(swidy: *const Swidy, list: Value) ListIterator {
        return .{ .swidy = swidy, .cur = list };
    }

    const ListIterator = struct {
        cur: Value,
        swidy: *const Swidy,

        pub fn next(it: *ListIterator) ?Value {
            if (it.cur.tag == .string) {
                assert(it.swidy.isNil(it.cur));
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
            while (std.ascii.isWhitespace(try reader.peekByte())) {
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
                return swidy.buildString(try reader.takeDelimiter('"') orelse return error.BadInput);
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
};

// (ffi "add" (23.0f 12.0f))

pub fn main(init: std.process.Init) !void {
    // const args = try init.minimal.args.toSlice(init.arena.allocator());

    const io = init.io;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try stdout_writer.print("swidy\n", .{});

    try stdout_writer.flush();
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
            \\      ((("lit" . "a") . ("lit" . "b")) . (("lit" . "identity") . ()))
            \\ )))
        );
        break :blk try Swidy.Parser.sexpr(&swidy, &source);
    };
    const input_value = swidy.buildString("a");
    const fnkname = swidy.buildString("myFunc");

    const result = swidy.eval(fnkname, input_value, known_fnks);

    try swidy.expectEqual(swidy.buildString("b"), result);
}

// const source: std.io.Reader = .fixed(
//     \\ fn myFunc {
//     \\     "a" -> "b";
//     \\ }
//     \\
//     \\ main myFunc: "a";
// );
