const std = @import("std");
const p = @import("bedrock_protocol");
const b = @import("bedwire");
const Mock = @import("mock_profile").Profile(p);

const ImplicitDeflate = struct {
    pub const protocol_number = Mock.protocol_number;
    pub const features: p.SessionFeatures = .{
        .uses_request_network_settings = false,
        .compression_mode = .implicit,
        .initial_algorithm = .deflate,
        .supports_snappy = false,
    };
    pub const packetKind = Mock.packetKind;
    pub const packetId = Mock.packetId;
    pub const packetDirection = Mock.packetDirection;
    pub const decodeBorrowed = Mock.decodeBorrowed;
    pub const encode = Mock.encode;
};

const limits: b.Limits = .{ .max_frame_bytes = 4096, .max_batch_bytes = 4096, .max_packet_bytes = 2048 };

test "external implicit deflate profile initializes without a descriptor" {
    var pool = try b.BufferPool.init(std.testing.allocator, limits, .{ .rx_slots = 1, .tx_slots = 1 });
    defer pool.deinit();
    var session = try b.SessionWithProfile(ImplicitDeflate).init(std.testing.allocator, .server, .{ .pool = &pool });
    defer session.deinit();
    try std.testing.expectEqual(b.State.authenticating, session.state);
    try std.testing.expectEqual(b.compression.Algorithm.deflate, session.compression.algorithm);
}

test "current and external profiles drive real Bedwire sessions" {
    inline for (.{ p.Current, Mock }) |Profile| {
        var pool = try b.BufferPool.init(std.testing.allocator, limits, .{ .rx_slots = 2, .tx_slots = 2 });
        defer pool.deinit();
        var server = try b.SessionWithProfile(Profile).init(std.testing.allocator, .server, .{ .pool = &pool });
        defer server.deinit();
        var client = try b.SessionWithProfile(Profile).init(std.testing.allocator, .client, .{ .pool = &pool });
        defer client.deinit();

        var storage: [128]u8 = undefined;
        var writer = p.Writer.init(&storage);
        try Profile.encode(&writer, .{
            .header = .{ .packet_id = Profile.packetId(.request_network_settings).? },
            .kind = .request_network_settings,
            .payload = &.{},
            .value = .{ .typed = .{ .request_network_settings = .{ .client_protocol = @intCast(Profile.protocol_number) } } },
        });
        const request_frame = try client.encodeOne(writer.written());
        var request_packets = try server.ingest(request_frame.bytes);
        request_frame.release();
        const request = request_packets.next().?;
        try std.testing.expectEqual(p.PacketKind.request_network_settings, request.kind);
        const normalized = try server.decodePacket(request);
        try std.testing.expectEqual(@as(i32, @intCast(Profile.protocol_number)), normalized.value.typed.request_network_settings.client_protocol);
        request_packets.deinit();
        try std.testing.expectEqual(b.State.network_settings, server.state);

        writer.cursor = 0;
        try Profile.encode(&writer, .{
            .header = .{ .packet_id = Profile.packetId(.network_settings).? },
            .kind = .network_settings,
            .payload = &.{},
            .value = .{ .typed = .{ .network_settings = .{
                .compression_threshold = 256,
                .compression_algorithm = 0,
                .client_throttle = false,
                .client_throttle_threshold = 0,
                .client_throttle_scalar = 0,
            } } },
        });
        const settings_frame = try server.encodeOne(writer.written());
        var settings_packets = try client.ingest(settings_frame.bytes);
        settings_frame.release();
        const settings = settings_packets.next().?;
        try client.negotiateFromSettings(settings);
        try server.negotiateCompression(.deflate, 256);
        settings_packets.deinit();
        try std.testing.expectEqual(b.State.authenticating, client.state);
        try std.testing.expectEqual(b.State.authenticating, server.state);
    }
}
