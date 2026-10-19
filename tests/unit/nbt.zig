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

test "failed NBT leaves the reader where it started" {
    const inputs = [_][]const u8{
        &.{ 0xaa, 10, 0, 1, 0, 0x63 },
        &.{ 0xaa, 10, 0, 8, 0, 2, 0xff, 0xfe, 0 },
        &.{ 0xaa, 9, 0, 1, 0x80, 0x89, 0x7a },
    };
    for (inputs) |input| {
        var r = try root.Reader.init(input, .{});
        _ = try r.readU8();
        if (root.nbt.readDocument(&r)) |_| return error.TestUnexpectedResult else |_| {}
        try std.testing.expectEqual(@as(usize, 1), r.cursor);
    }
}

test "absent NBT is one TAG_End byte" {
    var r = try root.Reader.init(&.{ 0, 0xaa }, .{});
    try std.testing.expectEqualSlices(u8, &.{0}, try root.nbt.readDocument(&r));
    try std.testing.expectEqual(@as(usize, 1), r.cursor);
    try std.testing.expect(root.nbt.isDocument(&.{0}));
    try std.testing.expect(!root.nbt.isDocument(&.{ 0, 0 }));
    try std.testing.expect(!root.nbt.isDocument(&.{}));
}

test "NBT keeps the protocol's varint and limit rules" {
    var r = try root.Reader.init(&.{ 3, 0, 0x80, 0 }, .{});
    try std.testing.expectError(error.NonCanonicalVarInt, root.nbt.readDocument(&r));

    const bytes = [_]u8{ 7, 0, 8, 1, 2, 3, 4 };
    r = try root.Reader.init(&bytes, .{ .max_byte_array_bytes = 3 });
    try std.testing.expectError(error.LimitExceeded, root.nbt.readDocument(&r));
    r = try root.Reader.init(&bytes, .{ .max_byte_array_bytes = 4 });
    try std.testing.expectEqualSlices(u8, &bytes, try root.nbt.readDocument(&r));

    const entries = [_]u8{ 10, 0, 1, 0, 1, 1, 1, 'a', 2, 1, 1, 'b', 3, 0 };
    r = try root.Reader.init(&entries, .{ .max_array_elements = 1 });
    try std.testing.expectError(error.LimitExceeded, root.nbt.readDocument(&r));
    r = try root.Reader.init(&entries, .{ .max_array_elements = 3 });
    try std.testing.expectEqualSlices(u8, &entries, try root.nbt.readDocument(&r));

    const long_string = [_]u8{ 8, 0, 0x80, 0x80, 0x02 } ++ @as([32768]u8, @splat('x'));
    r = try root.Reader.init(&long_string, .{});
    try std.testing.expectError(error.LimitExceeded, root.nbt.readDocument(&r));
}

test "shared NBT scanning agrees with the old hand-written scanner" {
    const legacy = @import("../support/legacy_nbt.zig");
    const seeds = [_][]const u8{
        &.{ 10, 0, 3, 1, 'x', 2, 0 },
        &.{ 10, 0, 9, 1, 'l', 3, 4, 2, 4, 11, 1, 'i', 4, 0x80, 0x01, 3, 8, 1, 's', 2, 'h', 'i', 0 },
        &.{ 10, 0, 10, 1, 'c', 7, 1, 'b', 6, 1, 2, 3, 12, 1, 'L', 2, 0xfe, 0xff, 0x7f, 5, 1, 'f', 0, 0, 128, 63, 0, 0 },
        &.{ 9, 0, 10, 4, 1, 1, 'a', 1, 0, 0 },
        &.{0},
    };
    for (seeds) |seed| {
        var old = try root.Reader.init(seed, .{});
        var new = try root.Reader.init(seed, .{});
        try std.testing.expectEqual(seed.len, (try legacy.readDocument(&old)).len);
        try std.testing.expectEqual(seed.len, (try root.nbt.readDocument(&new)).len);
    }

    var prng: std.Random.DefaultPrng = .init(0x5ca1ab1e);
    const random = prng.random();
    var buffer: [64]u8 = undefined;

    for (0..200_000) |iteration| {
        const seed = seeds[iteration % seeds.len];
        @memcpy(buffer[0..seed.len], seed);
        var len = seed.len;
        if (iteration % 3 != 0) buffer[random.uintLessThan(usize, len)] ^= random.int(u8);
        if (iteration % 4 == 0) len = random.uintLessThan(usize, len + 1);
        const input = buffer[0..len];

        const limits: root.DecodeLimits = .{ .max_nesting_depth = 1 + random.uintLessThan(usize, 4) };
        var old = try root.Reader.init(input, limits);
        var new = try root.Reader.init(input, limits);
        const old_result = legacy.readDocument(&old);
        const new_result = root.nbt.readDocument(&new);

        if (old_result) |old_bytes| {
            try std.testing.expectEqual(old_bytes.len, (try new_result).len);
        } else |_| {
            try std.testing.expect(std.meta.isError(new_result));
        }
    }
}
