//! Bounded deterministic hostile-input campaign: `zig build fuzz -Dfuzz-iterations=N`.
const std = @import("std");

pub fn main() !void {
    const iterations = @import("fuzz_options").iterations;
    try @import("campaign.zig").run(iterations);
    std.debug.print("deterministic fuzz: {d} cases passed\n", .{iterations});
}
