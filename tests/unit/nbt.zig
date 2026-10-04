const std = @import("std");
const root = @import("bedrock_protocol");
test "network NBT known fixture and malicious structures" {
    const fixture = [_]u8{ 10, 0, 3, 1, 'x', 2, 0 };
    var r = try root.Reader.init(&fixture, .{});
    try std.testing.expectEqualSlices(u8, &fixture, try root.nbt.readDocument(&r));
    try r.finish();
    var bad = try root.Reader.init(&.{ 9, 0, 0, 1 }, .{});
    try std.testing.expectError(error.InvalidNbt, root.nbt.readDocument(&bad));
}
test "NBT nesting limit is explicit" {
    const nested = [_]u8{ 10, 0, 10, 0, 10, 0, 10, 0, 0, 0, 0, 0 };
    var r = try root.Reader.init(&nested, .{ .max_nesting_depth = 1 });
    try std.testing.expectError(error.LimitExceeded, root.nbt.readDocument(&r));
}
test "NBT byte budget stops reads at the configured boundary" {
    const fixture = [_]u8{ 7, 0, 80 } ++ @as([40]u8, @splat(0xaa));
    var r = try root.Reader.init(&fixture, .{ .max_nbt_bytes = 8 });
    try std.testing.expectError(error.LimitExceeded, root.nbt.readDocument(&r));
    try std.testing.expect(r.cursor <= 8);
}

test "NBT byte budget includes the root name and preserves surrounding input" {
    const fixture = [_]u8{ 0xaa, 10, 3, 'n', 'b', 't', 0, 0xbb };
    for (1..6) |budget| {
        var r = try root.Reader.init(&fixture, .{ .max_nbt_bytes = budget });
        _ = try r.readU8();
        try std.testing.expectError(error.LimitExceeded, root.nbt.readDocument(&r));
        try std.testing.expect(r.cursor <= 1 + budget);
        try std.testing.expectEqualSlices(u8, &fixture, r.input);
    }
    var truncated = try root.Reader.init(fixture[1..4], .{});
    try std.testing.expectError(error.EndOfStream, root.nbt.readDocument(&truncated));
}

test "unsafe NBT nesting configurations are rejected" {
    const too_deep = root.DecodeLimits.max_supported_nesting_depth + 1;
    try std.testing.expectError(error.LimitExceeded, root.Reader.init(&.{0}, .{ .max_nesting_depth = too_deep }));
}
