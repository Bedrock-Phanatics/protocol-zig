const std = @import("std");
const p = @import("../root.zig");
test "registry IDs, kinds and directions are a bijection" {
    try std.testing.expectEqual(p.PacketDirection.server_to_client, p.registry.packetDirection(.set_time));
    try std.testing.expectEqual(p.PacketDirection.bidirectional, p.registry.packetDirection(.request_chunk_radius));
    try std.testing.expectEqual(p.PacketDirection.client_to_server, p.registry.packetDirection(.server_bound_data_store));
    try std.testing.expectEqual(p.PacketKind.login, p.registry.packetKind(1).?);
    try std.testing.expectEqual(@as(?u10, 193), p.registry.packetId(.request_network_settings));
    try std.testing.expect(p.registry.packetKind(1023) == null);
    var seen = [_]bool{false} ** 1024;
    for (std.enums.values(p.PacketKind)) |kind| {
        const id = p.registry.packetId(kind).?;
        try std.testing.expect(!seen[id]);
        seen[id] = true;
        try std.testing.expectEqual(kind, p.registry.packetKind(id).?);
    }
    inline for (@typeInfo(p.PacketKind).@"enum".fields) |field| {
        try std.testing.expectEqual(p.registry.packetId(@field(p.PacketKind, field.name)).?, @intFromEnum(@field(p.PacketId, field.name)));
    }
    for (0..1024) |id| if (p.registry.packetKind(@intCast(id))) |kind| {
        try std.testing.expectEqual(@as(u10, @intCast(id)), p.registry.packetId(kind).?);
    };
}

test "deprecated IDs absent from protocol 2193 decode as unknown packets" {
    for ([_]u10{ 55, 117, 163, 173, 197 }) |id| {
        try std.testing.expect(p.registry.packetKind(id) == null);
        var bytes: [8]u8 = undefined;
        var w = p.Writer.init(&bytes);
        try p.packet.encode(&w, .{ .header = .{ .packet_id = id }, .payload = &.{ 1, 2 } });
        const decoded = try p.Current.decodeBorrowed(w.written(), .{});
        try std.testing.expect(decoded.value == .unknown);
        try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, decoded.payload);
    }
}
