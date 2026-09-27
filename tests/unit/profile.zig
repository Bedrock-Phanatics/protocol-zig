const std = @import("std");
const p = @import("bedrock_protocol");
test "session features require a supported initial compression algorithm" {
    try (p.SessionFeatures{}).validate();
    try (p.SessionFeatures{
        .compression_mode = .implicit,
        .initial_algorithm = .deflate,
        .supports_snappy = false,
    }).validate();
    try std.testing.expectError(error.UnsupportedProtocol, (p.SessionFeatures{ .compression_mode = .implicit }).validate());
    try std.testing.expectError(error.UnsupportedProtocol, (p.SessionFeatures{ .compression_mode = .absent, .initial_algorithm = .deflate }).validate());
    try std.testing.expectError(error.UnsupportedProtocol, (p.SessionFeatures{
        .compression_mode = .implicit,
        .initial_algorithm = .snappy,
        .supports_snappy = false,
    }).validate());
}
test "current profile decodes every known ID semantically and forwards unknown IDs" {
    comptime p.validateProfile(p.Current);
    const request = try p.Current.decodeBorrowed(&.{ 0xc1, 1, 0, 0, 8, 0x91 }, .{});
    try std.testing.expectEqual(p.PacketKind.request_network_settings, request.kind.?);
    try std.testing.expectEqual(@as(i32, 2193), request.value.typed.request_network_settings.client_network_version);
    try std.testing.expectError(error.EndOfStream, p.Current.decodeBorrowed(&.{ 11, 42 }, .{}));
    try std.testing.expect((try p.Current.decodeBorrowed(&.{ 0xff, 7, 42 }, .{})).value == .unknown);
    var storage: [32]u8 = undefined;
    var w = p.Writer.init(&storage);
    try p.Current.encode(&w, request);
    try std.testing.expectEqualSlices(u8, &.{ 0xc1, 1, 0, 0, 8, 0x91 }, w.written());
}

test "encoding rejects envelopes whose kind, ID and value disagree without writing" {
    const typed_value: p.typed.Packet = .{ .set_difficulty = .{ .difficulty = 1 } };
    const invalid = [_]p.BorrowedEnvelope{
        .{ .header = .{ .packet_id = p.Current.packetId(.login).? }, .kind = .login, .payload = "", .value = .{ .typed = typed_value } },
        .{ .header = .{ .packet_id = p.Current.packetId(.set_difficulty).? }, .kind = .login, .payload = "", .value = .{ .typed = typed_value } },
        .{ .header = .{ .packet_id = p.Current.packetId(.login).? }, .kind = .login, .payload = "raw", .value = .unknown },
        .{ .header = .{ .packet_id = 1023 }, .kind = null, .payload = "", .value = .{ .typed = typed_value } },
    };
    for (invalid) |envelope| {
        var bytes = [_]u8{0xa5} ** 32;
        const before = bytes;
        var writer = p.Writer.init(&bytes);
        writer.cursor = 3;
        try std.testing.expectError(error.InvalidValue, p.Current.encode(&writer, envelope));
        try std.testing.expectEqualSlices(u8, &before, &bytes);
        try std.testing.expectEqual(@as(usize, 3), writer.cursor);
    }
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
    const Mock = @import("mock_profile").Profile;
    comptime p.validateProfile(Mock);
    const fixture = [_]u8{ 0xe8, 0x6f, 0x91, 8, 0, 0 };
    var value = try Mock.decodeBorrowed(&fixture, .{});
    try std.testing.expectEqual(@as(u2, 1), value.header.sender_subclient);
    try std.testing.expectEqual(@as(u2, 3), value.header.target_subclient);
    try std.testing.expectEqual(@as(i32, 2193), value.value.typed.request_network_settings.client_network_version);
    var bytes: [32]u8 = undefined;
    var w = p.Writer.init(&bytes);
    try Mock.encode(&w, value);
    try std.testing.expectEqualSlices(u8, &fixture, w.written());
    value.value.typed.request_network_settings.client_network_version = 42;
    w.cursor = 0;
    try Mock.encode(&w, value);
    try std.testing.expectEqualSlices(u8, &.{ 0xe8, 0x6f, 42, 0, 0, 0 }, w.written());
    try std.testing.expectEqual(@as(?u10, 193), p.Current.packetId(.request_network_settings));
    try std.testing.expectEqual(@as(?u10, 1000), Mock.packetId(.request_network_settings));
    const current_value = try p.Current.decodeBorrowed(&.{ 0xc1, 1, 0, 0, 8, 0x91 }, .{});
    try std.testing.expectEqual(@as(i32, 2193), current_value.value.typed.request_network_settings.client_network_version);
}
