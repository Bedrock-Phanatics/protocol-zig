const std = @import("std");
const root = @import("../root.zig");
const packets = root.packets.resource_pack;
const codec = root.codecs.resource_pack;

fn allocator() std.mem.Allocator {
    return std.testing.allocator;
}

test "resource pack client response canonical fixture" {
    const fixture = [_]u8{ 1, 11, 'd', 'o', 'w', 'n', 'l', 'o', 'a', 'd', 'i', 'n', 'g', 1, 3, 'a', '_', '1' };
    var r = try root.Reader.init(&fixture, .{});
    const value = try codec.decodeResponse(&r, allocator());
    defer codec.deinitResponse(allocator(), value);
    try std.testing.expectEqual(packets.PackResponse.send_packs, value.response);
    try std.testing.expectEqualSlices(u8, "a_1", value.packs_to_download[0]);
    try r.finish();
    var output: [64]u8 = undefined;
    var w = root.Writer.init(&output);
    try codec.encodeResponse(&w, value);
    try std.testing.expectEqualSlices(u8, &fixture, w.written());
}

test "resource pack response rejects mismatched state name" {
    var r = try root.Reader.init(&.{ 1, 6, 'c', 'a', 'n', 'c', 'e', 'l', 0 }, .{});
    try std.testing.expectError(error.InvalidEnum, codec.decodeResponse(&r, allocator()));
}

test "text authored and translated fixtures round trip" {
    const authored = [_]u8{ 0, 1, 1, 3, 'B', 'o', 'b', 2, 'h', 'i', 0, 0, 0 };
    var authored_reader = try root.Reader.init(&authored, .{});
    const authored_value = try codec.decodeText(&authored_reader, allocator());
    try authored_reader.finish();
    var output: [128]u8 = undefined;
    var authored_writer = root.Writer.init(&output);
    try codec.encodeText(&authored_writer, authored_value);
    try std.testing.expectEqualSlices(u8, &authored, authored_writer.written());

    const translated = [_]u8{ 1, 2, 2, 3, 'k', 'e', 'y', 2, 1, 'a', 1, 'b', 0, 0, 0 };
    var translated_reader = try root.Reader.init(&translated, .{});
    const translated_value = try codec.decodeText(&translated_reader, allocator());
    defer codec.deinitText(allocator(), translated_value);
    try translated_reader.finish();
    var translated_writer = root.Writer.init(&output);
    try codec.encodeText(&translated_writer, translated_value);
    try std.testing.expectEqualSlices(u8, &translated, translated_writer.written());
}

test "text rejects inconsistent category and oversized parameter count" {
    var category_reader = try root.Reader.init(&.{ 0, 0, 1 }, .{});
    try std.testing.expectError(error.InvalidEnum, codec.decodeText(&category_reader, allocator()));

    const too_many = [_][]const u8{ "1", "2", "3", "4", "5" };
    var output: [128]u8 = undefined;
    var w = root.Writer.init(&output);
    try std.testing.expectError(error.InvalidValue, codec.encodeText(&w, .{ .text_type = .translation, .needs_translation = true, .message = "key", .parameters = &too_many }));
    try std.testing.expectEqual(@as(usize, 0), w.written().len);
}
test "text decode frees parameters when later validation fails" {
    var bytes: [256]u8 = undefined;
    var w = root.Writer.init(&bytes);
    try w.writeBool(false);
    try w.writeU8(2);
    try w.writeU8(@intFromEnum(packets.TextType.translation));
    try w.writeString("key");
    try w.writeVarU32(1);
    try w.writeString("parameter");
    try w.writeString("x" ** 65);
    try w.writeString("");
    try w.writeBool(false);

    var r = try root.Reader.init(w.written(), .{});
    try std.testing.expectError(error.InvalidValue, codec.decodeText(&r, allocator()));
}
test "hostile collection counts are rejected before allocation" {
    var no_space: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&no_space);

    var info_bytes: [64]u8 = undefined;
    var info_writer = root.Writer.init(&info_bytes);
    try info_writer.writeBool(false);
    try info_writer.writeBool(false);
    try info_writer.writeBool(false);
    try info_writer.writeBool(false);
    try info_writer.writeUuid([_]u8{0} ** 16);
    try info_writer.writeString("");
    try info_writer.writeVarU32(1_000_000);
    var info_reader = try root.Reader.init(info_writer.written(), .{});
    try std.testing.expectError(error.LimitExceeded, codec.decodeInfo(&info_reader, fixed.allocator()));

    fixed.reset();
    var stack_bytes: [16]u8 = undefined;
    var stack_writer = root.Writer.init(&stack_bytes);
    try stack_writer.writeBool(false);
    try stack_writer.writeVarU32(1_000_000);
    var stack_reader = try root.Reader.init(stack_writer.written(), .{});
    try std.testing.expectError(error.LimitExceeded, codec.decodeStack(&stack_reader, fixed.allocator()));

    fixed.reset();
    var response_bytes: [32]u8 = undefined;
    var response_writer = root.Writer.init(&response_bytes);
    try response_writer.writeVarU32(1);
    try response_writer.writeString("downloading");
    try response_writer.writeVarU32(1_000_000);
    var response_reader = try root.Reader.init(response_writer.written(), .{});
    try std.testing.expectError(error.LimitExceeded, codec.decodeResponse(&response_reader, fixed.allocator()));
}

test "borrowed response validates all strings and stays on input" {
    const bytes = [_]u8{ 1, 11 } ++ "downloading".* ++ [_]u8{ 1, 3 } ++ "abc".*;
    var r = try root.Reader.init(&bytes, .{});
    const v = try codec.decodeResponseBorrowed(&r);
    try r.finish();
    try std.testing.expectEqual(packets.PackResponse.send_packs, v.response);
    var it = v.packs_to_download.iterator();
    const name = (try it.next()).?;
    try std.testing.expectEqualSlices(u8, "abc", name);
    try std.testing.expect(name.ptr == bytes[bytes.len - 3 ..].ptr);
    try std.testing.expect((try it.next()) == null);
    for (0..bytes.len) |length| {
        var short = try root.Reader.init(bytes[0..length], .{});
        if (codec.decodeResponseBorrowed(&short)) |_| return error.AcceptedTruncation else |_| {}
    }
    var bad = bytes;
    bad[bad.len - 1] = 0xff;
    var invalid = try root.Reader.init(&bad, .{});
    try std.testing.expectError(error.InvalidUtf8, codec.decodeResponseBorrowed(&invalid));
}
