const std = @import("std");
const p = @import("../root.zig");
test "current profile decodes typed known opaque and unknown packets" {
    comptime p.validateProfile(p.Current);
    const request = try p.Current.decodeBorrowed(&.{ 0xc1, 1, 0, 0, 8, 0x91 }, .{});
    try std.testing.expectEqual(p.PacketKind.request_network_settings, request.kind.?);
    try std.testing.expectEqual(@as(i32, 2193), request.value.typed.request_network_settings.client_protocol);
    try std.testing.expect((try p.Current.decodeBorrowed(&.{ 11, 42 }, .{})).value == .known_opaque);
    try std.testing.expect((try p.Current.decodeBorrowed(&.{ 0xff, 7, 42 }, .{})).value == .unknown);
    var storage: [32]u8 = undefined;
    var w = p.Writer.init(&storage);
    try p.Current.encode(&w, request);
    try std.testing.expectEqualSlices(u8, &.{ 0xc1, 1, 0, 0, 8, 0x91 }, w.written());
}
test "profile checks trailing bytes and all subclient combinations" {
    try std.testing.expectError(error.TrailingData, p.Current.decodeBorrowed(&.{ 4, 1 }, .{}));
    for (0..4) |sender| for (0..4) |target| {
        var bytes: [16]u8 = undefined;
        var w = p.Writer.init(&bytes);
        try p.packet.encode(&w, .{ .header = .{ .packet_id = 1023, .sender_subclient = @intCast(sender), .target_subclient = @intCast(target) }, .payload = "xyz" });
        const borrowed = try p.Current.decodeBorrowed(w.written(), .{});
        var out: [16]u8 = undefined;
        var encoded = p.Writer.init(&out);
        try p.Current.encode(&encoded, borrowed);
        try std.testing.expectEqualSlices(u8, w.written(), encoded.written());
    };
}

test "external layout translates semantic values independently of current" {
    const Mock = @import("fixtures/mock_profile.zig").Profile(p);
    comptime p.validateProfile(Mock);
    const fixture = [_]u8{ 0xe8, 0x67, 0x91, 8, 0, 0 };
    var value = try Mock.decodeBorrowed(&fixture, .{});
    try std.testing.expectEqual(@as(u2, 1), value.header.sender_subclient);
    try std.testing.expectEqual(@as(u2, 3), value.header.target_subclient);
    try std.testing.expectEqual(@as(i32, 2193), value.value.typed.request_network_settings.client_protocol);
    var bytes: [32]u8 = undefined;
    var w = p.Writer.init(&bytes);
    try Mock.encode(&w, value);
    try std.testing.expectEqualSlices(u8, &fixture, w.written());
    value.value.typed.request_network_settings.client_protocol = 42;
    w.cursor = 0;
    try Mock.encode(&w, value);
    try std.testing.expectEqualSlices(u8, &.{ 0xe8, 0x67, 42, 0, 0, 0 }, w.written());
    try std.testing.expectEqual(@as(?u10, 193), p.Current.packetId(.request_network_settings));
    try std.testing.expectEqual(@as(?u10, 1000), Mock.packetId(.request_network_settings));
    const current_value = try p.Current.decodeBorrowed(&.{ 0xc1, 1, 0, 0, 8, 0x91 }, .{});
    try std.testing.expectEqual(@as(i32, 2193), current_value.value.typed.request_network_settings.client_protocol);
}
