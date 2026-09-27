//! Test entry point: `zig build test`.
const std = @import("std");

test {
    _ = @import("unit/primitives.zig");
    _ = @import("unit/nbt.zig");
    _ = @import("unit/packet.zig");
    _ = @import("unit/encoding.zig");
    _ = @import("unit/registry.zig");
    _ = @import("unit/profile.zig");
    _ = @import("unit/typed.zig");
    _ = @import("unit/resource_pack.zig");
    _ = @import("unit/generated.zig");
    _ = @import("unit/corpus.zig");
    _ = @import("unit/hostile.zig");
    _ = @import("unit/readme.zig");
}

test "deterministic hostile-input smoke" {
    const gpa = std.testing.allocator;
    const corpus = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, @import("build_options").corpus_file, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(corpus);
    _ = try @import("fuzz/campaign.zig").run(corpus, 20_000);
}
