const std = @import("std");
const p = @import("bedrock_protocol");
const b = @import("bedwire");
const Mock = @import("mock_profile").Profile(p);

fn descriptor(comptime P: type) !b.Descriptor {
    comptime p.validateProfile(P);
    var entries: [std.enums.values(b.PacketKind).len]b.protocol.Entry = undefined;
    var count: usize = 0;
    inline for (std.enums.values(b.PacketKind)) |kind| {
        if (comptime @hasField(p.PacketKind, @tagName(kind))) {
            if (P.packetId(@field(p.PacketKind, @tagName(kind)))) |id| {
                entries[count] = .{ .kind = kind, .id = id };
                count += 1;
            }
        }
    }
    return b.protocol.build(P.protocol_number, .{
        .uses_request_network_settings = P.features.uses_request_network_settings,
        .supports_deflate = P.features.supports_deflate,
        .supports_snappy = P.features.supports_snappy,
        .compression_mode = @field(b.protocol.CompressionMode, @tagName(P.features.compression_mode)),
        .login_flow = @field(b.protocol.LoginFlow, @tagName(P.features.login_flow)),
        .resource_pack_flow = @field(b.protocol.ResourcePackFlow, @tagName(P.features.resource_pack_flow)),
    }, entries[0..count]);
}
test "real Bedwire admits both profile IDs and consumes decoded compression values" {
    inline for (.{ p.Current, Mock }) |P| {
        const desc = try descriptor(P);
        var server = try b.Session.init(std.testing.allocator, .server, &desc, .{ .limits = .{ .max_frame_bytes = 4096, .max_batch_bytes = 4096, .max_packet_bytes = 2048 } });
        defer server.deinit();
        var client = try b.Session.init(std.testing.allocator, .client, &desc, .{ .limits = .{ .max_frame_bytes = 4096, .max_batch_bytes = 4096, .max_packet_bytes = 2048 } });
        defer client.deinit();
        var storage: [128]u8 = undefined;
        var w = p.Writer.init(&storage);
        try P.encode(&w, .{ .header = .{ .packet_id = P.packetId(.request_network_settings).? }, .kind = .request_network_settings, .payload = &.{}, .value = .{ .typed = .{ .request_network_settings = .{ .client_protocol = @intCast(P.protocol_number) } } } });
        const frame = try client.encodeOne(w.written());
        var packets = try server.ingest(frame);
        const observed = packets.next().?;
        try std.testing.expectEqual(b.PacketKind.request_network_settings, observed.kind);
        const normalized = try P.decodeBorrowed(observed.bytes, .{});
        try std.testing.expectEqual(@as(i32, @intCast(P.protocol_number)), normalized.value.typed.request_network_settings.client_protocol);
        packets.deinit();
        try std.testing.expectEqual(b.State.network_settings, server.state);
        w.cursor = 0;
        try P.encode(&w, .{ .header = .{ .packet_id = P.packetId(.network_settings).? }, .kind = .network_settings, .payload = &.{}, .value = .{ .typed = .{ .network_settings = .{ .compression_threshold = 256, .compression_algorithm = 0, .client_throttle = false, .client_throttle_threshold = 0, .client_throttle_scalar = 0 } } } });
        const settings_frame = try server.encodeOne(w.written());
        var received = try client.ingest(settings_frame);
        defer received.deinit();
        const settings = (try P.decodeBorrowed(received.next().?.bytes, .{})).value.typed.network_settings;
        const algorithm: b.protocol.Algorithm = switch (settings.compression_algorithm) {
            0 => .deflate,
            1 => .snappy,
            else => return error.UnsupportedCompression,
        };
        try client.negotiateCompression(algorithm, settings.compression_threshold);
        try server.negotiateCompression(algorithm, settings.compression_threshold);
        try std.testing.expectEqual(b.State.authenticating, client.state);
        try std.testing.expectEqual(b.State.authenticating, server.state);
    }
}
