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

    pub fn expectEqual(swidy: *const Swidy, a: Value, b: Value) !void {
        try std.testing.expect(swidy.eql(a, b));
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

// const source: std.io.Reader = .fixed(
//     \\ fn myFunc {
//     \\     "a" -> "b";
//     \\ }
//     \\
//     \\ main myFunc: "a";
// );
