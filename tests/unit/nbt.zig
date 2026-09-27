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
    const fixture = [_]u8{ 7, 0, 80 } ++ ([_]u8{0xaa} ** 40);
    var r = try root.Reader.init(&fixture, .{ .max_nbt_bytes = 8 });
    try std.testing.expectError(error.LimitExceeded, root.nbt.readDocument(&r));
    try std.testing.expect(r.cursor <= 8);
}

test "unsafe NBT nesting configurations are rejected" {
    const too_deep = root.DecodeLimits.max_supported_nesting_depth + 1;
    try std.testing.expectError(error.LimitExceeded, root.Reader.init(&.{0}, .{ .max_nesting_depth = too_deep }));
}
