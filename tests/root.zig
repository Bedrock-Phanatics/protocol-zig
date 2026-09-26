//! Test entry point: `zig build test`.
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
}

test "deterministic hostile-input smoke" {
    try @import("fuzz/campaign.zig").run(20_000);
}
