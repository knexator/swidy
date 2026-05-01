const Swidy = @import("main.zig").Swidy;
const std = @import("std");

export fn example(swidy: *Swidy, value: Swidy.Value) callconv(.c) Swidy.Value {
    return swidy.buildPair(value, value);
}

test example {
    var swidy: Swidy = .init(std.testing.allocator);
    defer swidy.deinit();

    const x = swidy.buildString("x");
    const actual = example(&swidy, x);
    const expected = swidy.buildPair(x, x);

    try swidy.expectEqual(expected, actual);
}
