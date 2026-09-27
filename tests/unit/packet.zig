const std = @import("std");
const root = @import("bedrock_protocol");

test "all legal packet IDs are forwarded losslessly" {
    var id: u16 = 0;
    while (id <= 1023) : (id += 1) {
        var bytes: [8]u8 = undefined;
        var writer = root.Writer.init(&bytes);
        const expected: root.packet.Envelope = .{
            .header = .{ .packet_id = @intCast(id), .sender_subclient = 3, .target_subclient = 2 },
            .payload = &.{ 9, 8, 7 },
        };
        try root.packet.encode(&writer, expected);
        const decoded = try root.packet.decode(writer.written(), .{});
        try std.testing.expectEqual(expected.header, decoded.header);
        try std.testing.expectEqualSlices(u8, expected.payload, decoded.payload);
    }
}

test "header rejects values outside the 14-bit Bedrock domain" {
    try std.testing.expectError(error.InvalidPacketId, root.packet.Header.fromWire(0x4000));
}
