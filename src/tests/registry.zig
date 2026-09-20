const std = @import("std");
const p = @import("../root.zig");
test "semantic mappings distinguish typed opaque and unknown" {
    try std.testing.expectEqual(p.PacketKind.login, p.registry.packetKind(1).?);
    try std.testing.expectEqual(@as(?u10, 193), p.registry.packetId(.request_network_settings));
    try std.testing.expect(p.registry.packetKind(1023) == null);
    try std.testing.expect(p.registry.hasCodec(.login));
    try std.testing.expect(p.registry.hasCodec(.resource_packs_info));
    try std.testing.expectEqual(p.registry.Coverage.borrowed_collection, p.registry.coverage(.resource_pack_stack));
    try std.testing.expect(!p.registry.hasCodec(.start_game));
    var seen = [_]bool{false} ** 1024;
    for (std.enums.values(p.PacketKind)) |kind| {
        const id = p.registry.packetId(kind).?;
        try std.testing.expect(!seen[id]);
        seen[id] = true;
        try std.testing.expectEqual(kind, p.registry.packetKind(id).?);
    }
    for (0..1024) |id| if (p.registry.packetKind(@intCast(id))) |kind| {
        try std.testing.expectEqual(@as(u10, @intCast(id)), p.registry.packetId(kind).?);
    };
}
