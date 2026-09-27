const std = @import("std");
const root = @import("bedrock_protocol");

test "canonical unsigned varints round trip" {
    const values = [_]u32{ 0, 1, 127, 128, 16384, std.math.maxInt(u32) };
    for (values) |expected| {
        var storage: [10]u8 = undefined;
        var writer = root.Writer.init(&storage);
        try writer.writeVarU32(expected);
        var reader = try root.Reader.init(writer.written(), .{});
        try std.testing.expectEqual(expected, try reader.readVarU32());
        try reader.finish();
    }
}

test "signed zigzag boundaries round trip" {
    const values = [_]i32{ std.math.minInt(i32), -1, 0, 1, 127, 128, std.math.maxInt(i32) };
    for (values) |expected| {
        var storage: [10]u8 = undefined;
        var writer = root.Writer.init(&storage);
        try writer.writeVarI32(expected);
        var reader = try root.Reader.init(writer.written(), .{});
        try std.testing.expectEqual(expected, try reader.readVarI32());
    }
}

test "malformed and non-canonical varints are rejected" {
    const cases = [_][]const u8{ &.{0x80}, &.{ 0x80, 0x00 }, &.{ 0xff, 0xff, 0xff, 0xff, 0x10 } };
    for (cases) |bytes| {
        var reader = try root.Reader.init(bytes, .{});
        try std.testing.expectError(if (bytes.len == 2) error.NonCanonicalVarInt else if (bytes.len == 1) error.EndOfStream else error.VarIntOverflow, reader.readVarU32());
    }
}

test "limits and UTF-8 are enforced without allocation" {
    var oversized = try root.Reader.init(&.{ 4, 't', 'e', 's', 't' }, .{ .max_string_bytes = 3 });
    try std.testing.expectError(error.LimitExceeded, oversized.readString());
    var invalid = try root.Reader.init(&.{ 2, 0xc3, 0x28 }, .{});
    try std.testing.expectError(error.InvalidUtf8, invalid.readString());
}
test "positions vectors and UUIDs use their Bedrock layouts" {
    var storage: [64]u8 = undefined;
    var w = root.Writer.init(&storage);
    const uuid = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    try w.writeChunkPosition(.{ .x = -2, .z = 300 });
    try w.writeSubChunkPosition(.{ .x = 1, .y = -2, .z = 3 });
    try w.writeBlockPosition(.{ .x = -1, .y = 64, .z = 1 });
    try w.writeVec3f(.{ .x = 1.25, .y = -2.5, .z = 3.0 });
    try w.writeUuid(uuid);
    try std.testing.expectEqualSlices(u8, &.{ 7, 6, 5, 4, 3, 2, 1, 0, 15, 14, 13, 12, 11, 10, 9, 8 }, w.written()[w.cursor - 16 ..]);

    var r = try root.Reader.init(w.written(), .{});
    try std.testing.expectEqual(root.ChunkPosition{ .x = -2, .z = 300 }, try r.readChunkPosition());
    try std.testing.expectEqual(root.SubChunkPosition{ .x = 1, .y = -2, .z = 3 }, try r.readSubChunkPosition());
    try std.testing.expectEqual(root.BlockPosition{ .x = -1, .y = 64, .z = 1 }, try r.readBlockPosition());
    try std.testing.expectEqual(root.Vec3f{ .x = 1.25, .y = -2.5, .z = 3.0 }, try r.readVec3f());
    try std.testing.expectEqual(uuid, try r.readUuid());
    try r.finish();
}

test "all signed and unsigned VarInt boundaries reject every truncated prefix" {
    inline for (.{ u32, u64, i32, i64 }, .{ "writeVarU32", "writeVarU64", "writeVarI32", "writeVarI64" }, .{ "readVarU32", "readVarU64", "readVarI32", "readVarI64" }) |T, write, read| {
        const values = [_]T{ std.math.minInt(T), 0, 1, 127, std.math.maxInt(T) };
        for (values) |value| {
            var bytes: [10]u8 = undefined;
            var w = root.Writer.init(&bytes);
            try @field(root.Writer, write)(&w, value);
            var r = try root.Reader.init(w.written(), .{});
            try std.testing.expectEqual(value, try @field(root.Reader, read)(&r));
            try r.finish();
            for (0..w.cursor) |length| {
                var short = try root.Reader.init(w.written()[0..length], .{});
                try std.testing.expectError(error.EndOfStream, @field(root.Reader, read)(&short));
            }
        }
    }
}

test "fixed integer widths and float bit patterns survive exact wire round trips" {
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64 }, .{ "U8", "I8", "U16", "I16", "U32", "I32", "U64", "I64" }) |T, suffix| {
        for ([_]T{ std.math.minInt(T), 0, 1, std.math.maxInt(T) }) |value| {
            var bytes: [8]u8 = undefined;
            var w = root.Writer.init(&bytes);
            try @field(root.Writer, "write" ++ suffix)(&w, value);
            try std.testing.expectEqual(@sizeOf(T), w.cursor);
            var r = try root.Reader.init(w.written(), .{});
            try std.testing.expectEqual(value, try @field(root.Reader, "read" ++ suffix)(&r));
            for (0..w.cursor) |length| {
                var short = try root.Reader.init(w.written()[0..length], .{});
                try std.testing.expectError(error.EndOfStream, @field(root.Reader, "read" ++ suffix)(&short));
            }
        }
    }
    inline for (.{ u16, i16, u32, i32, u64, i64 }, .{ "U16Be", "I16Be", "U32Be", "I32Be", "U64Be", "I64Be" }) |T, suffix| {
        var bytes: [8]u8 = undefined;
        var w = root.Writer.init(&bytes);
        try @field(root.Writer, "write" ++ suffix)(&w, @as(T, 1));
        try std.testing.expectEqual(@as(u8, 1), bytes[w.cursor - 1]);
        for (bytes[0 .. w.cursor - 1]) |b| try std.testing.expectEqual(@as(u8, 0), b);
        var r = try root.Reader.init(w.written(), .{});
        try std.testing.expectEqual(@as(T, 1), try @field(root.Reader, "read" ++ suffix)(&r));
    }
    for ([_]u32{ 0, 0x80000000, 0x3f800000, 0x7f800000, 0x7fc00001 }) |bits| {
        var bytes: [4]u8 = undefined;
        var w = root.Writer.init(&bytes);
        try w.writeF32(@bitCast(bits));
        var r = try root.Reader.init(&bytes, .{});
        try std.testing.expectEqual(bits, @as(u32, @bitCast(try r.readF32())));
    }
    for ([_]u64{ 0, 0x8000000000000000, 0x3ff0000000000000, 0x7ff0000000000000, 0x7ff8000000000001 }) |bits| {
        var bytes: [8]u8 = undefined;
        var w = root.Writer.init(&bytes);
        try w.writeF64(@bitCast(bits));
        var r = try root.Reader.init(&bytes, .{});
        try std.testing.expectEqual(bits, @as(u64, @bitCast(try r.readF64())));
    }
}

test "truncation never advances beyond input" {
    var r = try root.Reader.init(&.{ 0xff, 0xff, 0xff }, .{});
    try std.testing.expectError(error.EndOfStream, r.readU64());
    try std.testing.expect(r.cursor <= r.input.len);
}

test "bounded parser stress on deterministic hostile input" {
    var prng = std.Random.DefaultPrng.init(0xbed0c2192);
    const random = prng.random();
    var bytes: [96]u8 = undefined;
    for (0..20_000) |_| {
        random.bytes(&bytes);
        const len = random.intRangeAtMost(usize, 0, bytes.len);
        var r = try root.Reader.init(bytes[0..len], .{ .max_packet_bytes = bytes.len });
        _ = r.readVarU64() catch {};
        try std.testing.expect(r.cursor <= r.input.len);
    }
}

test "native fuzz target for reader and envelope" {
    try std.testing.fuzz({}, fuzzParser, .{});
}

fn fuzzParser(_: void, smith: *std.testing.Smith) !void {
    var bytes: [256]u8 = undefined;
    smith.bytesWithHash(&bytes, 0x5ef77a31);
    const len: usize = smith.valueRangeAtMostWithHash(u16, 0, bytes.len, 0x96653389);
    var r = root.Reader.init(bytes[0..len], .{ .max_packet_bytes = bytes.len, .max_string_bytes = 64, .max_byte_array_bytes = 128, .max_array_elements = 32 }) catch return;
    _ = r.readVarU32() catch {};
    try std.testing.expect(r.cursor <= r.input.len);
    _ = root.packet.decode(bytes[0..len], r.limits) catch {};
}
