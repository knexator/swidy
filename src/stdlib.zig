const Swidy = @import("core.zig").Swidy;
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

export fn add_u32_u32(swidy: *Swidy, value: Swidy.Value) callconv(.c) Swidy.Value {
    const a = std.mem.readInt(u32, asFixedLength(4, swidy.get(swidy.get(value).pair.left).string), .native);
    const b = std.mem.readInt(u32, asFixedLength(4, swidy.get(swidy.get(value).pair.right).string), .native);
    return swidy.buildString(&std.mem.toBytes(a + b));
}

fn asFixedLength(comptime N: usize, slice: []const u8) *const [N]u8 {
    if (slice.len != N) std.debug.panic("expected string of length {d}, found {s}", .{ N, slice });
    return slice[0..N];
}
