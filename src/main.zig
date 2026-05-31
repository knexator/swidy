// const Version = @import("dynamically_scoped.zig");
const Version = @import("global_fnks_env.zig");
// const Version = @import("mutable_environments.zig");

pub const Swidy = Version.Swidy;
pub const main = Version.main;

comptime {
    const std = @import("std");
    std.testing.refAllDecls(Version);
}
