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
    tags: std.ArrayListUnmanaged(Tag),
    cells: std.ArrayListUnmanaged(Value),
    strings: std.ArrayListUnmanaged(u8),

    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Swidy {
        var result: Swidy = .{ .gpa = gpa, .tags = .empty, .cells = .empty, .strings = .empty };
        assert(result.buildString("nil") == 0);
        return result;
    }

    pub fn deinit(swidy: *Swidy) void {
        swidy.tags.deinit(swidy.gpa);
        swidy.cells.deinit(swidy.gpa);
        swidy.strings.deinit(swidy.gpa);
    }

    pub const Tag = enum(u1) { pair, string };
    pub const Index = u32;
    pub const Value = union {
        pair: Pair,
        string: String,

        pub const Pair = struct {
            left: Index,
            right: Index,
        };

        pub const String = struct {
            start: Index,
            len: u32,
        };
    };

    pub fn get(swidy: *const Swidy, index: Index) union(enum) {
        bytes: []const u8,
        pair: struct { left: Index, right: Index },
    } {
        switch (swidy.tags.items[index]) {
            .pair => {
                const asdf = swidy.cells.items[index].pair;
                return .{ .pair = .{ .left = asdf.left, .right = asdf.right } };
            },
            .string => {
                const asdf = swidy.cells.items[index].string;
                return .{ .bytes = swidy.strings.items[asdf.start..][0..asdf.len] };
            },
        }
    }

    fn createCell(swidy: *Swidy, tag: Tag) Index {
        assert(swidy.tags.items.len == swidy.cells.items.len);
        swidy.tags.append(swidy.gpa, tag) catch OoM();
        _ = swidy.cells.addOne(swidy.gpa) catch OoM();
        assert(swidy.tags.items.len == swidy.cells.items.len);
        return cast(swidy.cells.items.len - 1);
    }

    // TODO(perf): free and reuse cells
    // fn destroyCell

    pub fn buildPair(swidy: *Swidy, left: Index, right: Index) Index {
        const result = swidy.createCell(.pair);
        swidy.cells.items[result].pair = .{ .left = left, .right = right };
        return result;
    }

    pub fn buildString(swidy: *Swidy, bytes: []const u8) Index {
        // TODO(perf): string interning
        const string: Value.String = .{ .start = cast(swidy.strings.items.len), .len = cast(bytes.len) };
        swidy.strings.appendSlice(swidy.gpa, bytes) catch OoM();

        const result = swidy.createCell(.string);
        swidy.cells.items[result].string = string;
        return result;
    }

    // fn parseFnk(swidy: *Swidy, reader: *std.Io.Reader) !Index {
    //     if (std.mem.eql(u8, "fn", ))
    // }

    const Parser = struct {
        fn expect(reader: *std.Io.Reader, expected: []const u8) !void {
            const actual = try reader.take(expected.len);
            if (!std.mem.eql(u8, actual, expected)) return error.BadInput;
        }

        fn whitespace(reader: *std.Io.Reader, mandatory: bool) !void {
            var seen_any: bool = false;
            while (std.ascii.isWhitespace(try reader.peekByte())) {
                reader.toss(1);
                seen_any = true;
            }
            if (mandatory and !seen_any) return error.BadInput;
        }

        fn tree(swidy: *Swidy, reader: *std.Io.Reader) !Index {
            try whitespace(reader, false);
            if (reader.peekByte() == '(') {
                @panic("TODO");
            } else if (reader.peekByte() == '"') {
                const literal = swidy.buildString(try reader.takeDelimiter('"'));
                return swidy.buildPair(swidy.buildString("lit"), literal);
            } else {
                @panic("TODO");
            }
        }
    };

    // fn parseSexpr(swidy: *Swidy, reader: *std.Io.Reader) !Index {
    //     if (try reader.peekByte() == '(') {
    //     } else {
    //         reader.takeDelimiter(delimiter: u8)
    //     }
    // }

    fn OoM() noreturn {
        std.debug.panic("OoM", .{});
    }

    fn cast(value: usize) u32 {
        return std.math.cast(u32, value) orelse OoM();
    }
};

// (ffi "add" (23.0f 12.0f))

comptime {
    std.testing.refAllDecls(Swidy);
}

pub fn main(init: std.process.Init) !void {
    // const args = try init.minimal.args.toSlice(init.arena.allocator());

    const io = init.io;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try stdout_writer.print("swidy\n", .{});

    try stdout_writer.flush();
}

// test "asdf" {
//     const source: Reader = .fixed(
//         \\ fn myFunc {
//         \\     "a" -> "b";
//         \\ }
//         \\
//         \\ main myFunc: "a";
//     );
// }
