const std = @import("std");
const root = @import("bedrock_protocol");

test "typed decoder rejects trailing bytes unknown IDs and packet ID mismatch" {
    try std.testing.expectError(error.TrailingData, root.typed.decode(&.{ 59, 1, 0 }, .{}));
    try std.testing.expectError(error.InvalidPacketId, root.typed.decode(&.{ 0xff, 0x07 }, .{}));
    var out: [16]u8 = undefined;
    var w = root.Writer.init(&out);
    try std.testing.expectError(error.InvalidValue, root.typed.encode(&w, .{ .header = .{ .packet_id = 42 }, .packet = .{ .set_difficulty = .{ .difficulty = 1 } } }));
    try std.testing.expectEqual(@as(usize, 0), w.written().len);
}

test "disconnect message presence is a strict union tag" {
    try std.testing.expectError(error.InvalidEnum, root.typed.decode(&.{ 5, 0, 2 }, .{}));
    try std.testing.expectError(error.NonCanonicalVarInt, root.typed.decode(&.{ 5, 0, 0x80, 0 }, .{}));
    const hidden = try root.typed.decode(&.{ 5, 0, 1 }, .{});
    try std.testing.expect(hidden.packet.disconnect.messages == .empty);
}

test "move player teleport data is independent of the position mode" {
    const wire = [_]u8{ 19, 1 } ++ [_]u8{0} ** 24 ++ [_]u8{ 0, 1, 0, 1, 2, 0, 0, 0, 3, 0, 0, 0, 1 };
    const decoded = try root.typed.decode(&wire, .{});
    const teleport = decoded.packet.move_player.teleport_data.?;
    try std.testing.expectEqual(@as(i32, 2), teleport.teleportation_cause);
    try std.testing.expectEqual(@as(i32, 3), teleport.source_actor_type);
    var out: [64]u8 = undefined;
    var w = root.Writer.init(&out);
    try root.typed.encode(&w, decoded);
    try std.testing.expectEqualSlices(u8, &wire, w.written());
}

test "scalar typed fixtures round trip and reject truncation trailing data and short output" {
    const fixtures = [_][]const u8{
        &.{ 1, 0, 0, 8, 0x91, 1, 'x' }, &.{ 2, 0, 0, 0, 3 },  &.{ 3, 1, 'x' },                                               &.{4},                                &.{ 5, 0, 1 },
        &.{ 10, 2 },                    &.{ 14, 2 },          &([_]u8{ 19, 1 } ++ [_]u8{0} ** 24 ++ [_]u8{ 0, 1, 0, 0, 1 }), &.{ 42, 40 },                         &.{ 59, 1 },
        &.{ 60, 3 },                    &.{ 69, 2, 4 },       &.{ 70, 2 },                                                   &.{ 115, 1, 0, 0, 0, 0, 0, 0, 0, 1 }, &.{ 0x8f, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 },
        &.{ 0xc1, 1, 0, 0, 8, 0x91 },   &.{ 10, 0xdf, 0x5d },
    };
    for (fixtures) |wire| {
        const decoded = try root.typed.decode(wire, .{});
        try std.testing.expectEqual(wire.len, try root.typed.encodedSize(decoded));
        var storage: [128]u8 = undefined;
        var w = root.Writer.init(&storage);
        try root.typed.encode(&w, decoded);
        try std.testing.expectEqualSlices(u8, wire, w.written());
        for (0..wire.len) |length| {
            if (root.typed.decode(wire[0..length], .{})) |_| return error.AcceptedTruncation else |_| {}
            @memset(&storage, 0xa5);
            var short = root.Writer.init(storage[0..length]);
            try std.testing.expectError(error.NoSpaceLeft, root.typed.encode(&short, decoded));
            try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 128), &storage);
        }
        @memcpy(storage[0..wire.len], wire);
        storage[wire.len] = 0;
        try std.testing.expectError(error.TrailingData, root.typed.decode(storage[0 .. wire.len + 1], .{}));
    }
}
