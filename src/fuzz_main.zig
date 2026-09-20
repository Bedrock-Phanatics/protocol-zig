const std = @import("std");
pub fn main() !void {
    const count = @import("fuzz_options").iterations;
    try @import("tests/fuzz.zig").run(@import("root.zig"), count);
    std.debug.print("deterministic fuzz: {d} cases passed (current, external, envelope, NBT, primitives)\n", .{count});
}
