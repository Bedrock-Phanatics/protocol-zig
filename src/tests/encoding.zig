const std = @import("std");
const p = @import("../root.zig");
test "packet failure preserves destination and cursor" {
    var bytes = [_]u8{0xa5} ** 3;
    const before = bytes;
    var w = p.Writer.init(&bytes);
    w.cursor = 1;
    try std.testing.expectError(error.NoSpaceLeft, p.packet.encode(&w, .{ .header = .{ .packet_id = 1023 }, .payload = &.{1} }));
    try std.testing.expectEqualSlices(u8, &before, &bytes);
    try std.testing.expectEqual(@as(usize, 1), w.cursor);
}
test "typed preflight rejects late invalid string without writes" {
    var bytes = [_]u8{0xa5} ** 128;
    const before = bytes;
    var w = p.Writer.init(&bytes);
    w.cursor = 3;
    const e: p.typed.Envelope = .{ .header = .{ .packet_id = 5 }, .packet = .{ .disconnect = .{ .reason = 0, .message_skipped = false, .message = "valid", .filtered_message = &.{0xff} } } };
    try std.testing.expectError(error.InvalidValue, p.typed.encode(&w, e));
    try std.testing.expectEqualSlices(u8, &before, &bytes);
    try std.testing.expectEqual(@as(usize, 3), w.cursor);
}
test "typed capacity failure never partially writes" {
    const e: p.typed.Envelope = .{ .header = .{ .packet_id = 193 }, .packet = .{ .request_network_settings = .{ .client_protocol = 2193 } } };
    for (0..6) |capacity| {
        var bytes = [_]u8{0xa5} ** 6;
        const before = bytes;
        var w = p.Writer.init(bytes[0..capacity]);
        try std.testing.expectError(error.NoSpaceLeft, p.typed.encode(&w, e));
        try std.testing.expectEqualSlices(u8, &before, &bytes);
        try std.testing.expectEqual(@as(usize, 0), w.cursor);
    }
}
