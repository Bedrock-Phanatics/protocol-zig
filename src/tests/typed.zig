const std = @import("std");
const root = @import("../root.zig");
test "typed control packets use canonical independent fixtures" {
    const cases = [_][]const u8{ &.{ 2, 0, 0, 0, 3 }, &.{ 10, 0xdf, 0x5d }, &.{ 42, 40 }, &.{ 59, 1 }, &.{ 60, 3 }, &.{ 70, 20 }, &.{ 0xc1, 0x01, 0, 0, 8, 0x90 } };
    for (cases) |wire| {
        const decoded = try root.typed.decode(wire, .{});
        var out: [64]u8 = undefined;
        var w = root.Writer.init(&out);
        try root.typed.encode(&w, decoded);
        try std.testing.expectEqualSlices(u8, wire, w.written());
    }
}
test "typed decoder rejects trailing bytes unknown IDs and packet ID mismatch" {
    try std.testing.expectError(error.TrailingData, root.typed.decode(&.{ 59, 1, 0 }, .{}));
    try std.testing.expectError(error.InvalidPacketId, root.typed.decode(&.{99}, .{}));
    var out: [16]u8 = undefined;
    var w = root.Writer.init(&out);
    try std.testing.expectError(error.InvalidValue, root.typed.encode(&w, .{ .header = .{ .packet_id = 42 }, .packet = .{ .set_difficulty = .{ .difficulty = 1 } } }));
    try std.testing.expectEqual(@as(usize, 0), w.written().len);
}
test "teleport presence must match move mode" {
    var out: [128]u8 = undefined;
    var w = root.Writer.init(&out);
    const p = root.packets.move_player.MovePlayerPacket{ .entity_runtime_id = 1, .position = .{ .x = 0, .y = 0, .z = 0 }, .rotation = .{ .x = 0, .y = 0, .z = 0 }, .mode = .normal, .on_ground = true, .ridden_entity_runtime_id = 0, .teleport = .{ .cause = 1, .source_entity_type = 2 }, .tick = 1 };
    try std.testing.expectError(error.InvalidValue, root.codecs.move_player.encode(&w, p));
}
test "disconnect uses a strict one-byte boolean" {
    try std.testing.expectError(error.InvalidBoolean, root.typed.decode(&.{ 5, 0, 2 }, .{}));
    try std.testing.expectError(error.InvalidBoolean, root.typed.decode(&.{ 5, 0, 0x80, 0 }, .{}));
}

test "all scalar typed fixtures round trip and reject truncation trailing data and short output" {
    const fixtures = [_][]const u8{
        &.{ 1, 0, 0, 8, 0x91, 1, 'x' }, &.{ 2, 0, 0, 0, 3 }, &.{ 3, 1, 'x' },                                               &.{4},                                &.{ 5, 0, 1 },
        &.{ 10, 2 },                    &.{ 14, 2 },         &([_]u8{ 19, 1 } ++ [_]u8{0} ** 24 ++ [_]u8{ 0, 1, 0, 0, 1 }), &.{ 42, 40 },                         &.{ 59, 1 },
        &.{ 60, 3 },                    &.{ 69, 2, 4 },      &.{ 70, 2 },                                                   &.{ 115, 1, 0, 0, 0, 0, 0, 0, 0, 1 }, &.{ 0x8f, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 },
        &.{ 0xc1, 1, 0, 0, 8, 0x91 },
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
