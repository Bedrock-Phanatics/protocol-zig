const std = @import("std");
const p = @import("bedrock_protocol");
const campaign = @import("../fuzz/campaign.zig");
const corpus_file = @import("build_options").corpus_file;

const DynamicValue = p.packets.client_bound_data_store.DynamicValue;

/// A ClientboundDataStore packet whose single change carries `depth` nested lists.
fn nestedDataStore(buffer: []u8, depth: usize) ![]const u8 {
    var w = p.Writer.init(buffer);
    try w.writeVarU32(p.registry.packetId(.client_bound_data_store).?);
    try w.writeVarU32(1); // one update
    try w.writeVarU32(1); // a change
    try w.writeString("store");
    try w.writeString("property");
    try w.writeU32(0);
    for (0..depth) |_| {
        try w.writeI32(5); // DynamicValue.list
        try w.writeVarU32(1);
    }
    try w.writeI32(0); // DynamicValue.none
    return w.written();
}

test "recursive values stop at the nesting limit instead of the stack" {
    var buffer: [16 * 1024]u8 = undefined;
    const shallow = try nestedDataStore(&buffer, 60);
    const decoded = try p.typed.decode(shallow, .{});
    try campaign.visit(decoded.packet);
    for ([_]usize{ 65, 1000, 3000 }) |depth| {
        try std.testing.expectError(error.LimitExceeded, p.typed.decode(try nestedDataStore(&buffer, depth), .{}));
    }
    try std.testing.expectError(error.LimitExceeded, p.typed.decode(shallow, .{ .max_nesting_depth = 8 }));
}

test "encoding a value nested deeper than any decoder accepts fails without writing" {
    var values: [200]DynamicValue = undefined;
    values[0] = .none;
    for (1..values.len) |i| values[i] = .{ .list = .init(values[i - 1 .. i]) };
    const packet: p.typed.Envelope = .{ .header = .{ .packet_id = p.registry.packetId(.client_bound_data_store).? }, .packet = .{
        .client_bound_data_store = .{ .updates = .init(&.{.{ .change = .{
            .data_store_name = "",
            .property = "",
            .update_count = 0,
            .the_new_property_value = values[values.len - 1],
        } }}) },
    } };
    var output = @as([4096]u8, @splat(0xa5));
    var w = p.Writer.init(&output);
    try std.testing.expectError(error.InvalidValue, p.typed.encode(&w, packet));
    try std.testing.expectEqual(@as(usize, 0), w.cursor);
    for (output) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
}

test "every truncation and corrupted byte of every corpus packet fails cleanly" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, corpus_file, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(text);
    var bytes: [64 * 1024]u8 = undefined;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next();
        _ = fields.next();
        const packet = try std.fmt.hexToBytes(&bytes, fields.next().?);
        for (0..packet.len) |len| try std.testing.expectError(error.EndOfStream, p.typed.decode(packet[0..len], .{}));
        for (packet) |*byte| {
            const original = byte.*;
            defer byte.* = original;
            for ([_]u8{ original ^ 0x80, original ^ 0x01, 0xff }) |value| {
                byte.* = value;
                _ = try campaign.check(packet);
            }
        }
    }
}

test "hostile element counts fail before touching the elements" {
    var buffer: [64]u8 = undefined;
    var w = p.Writer.init(&buffer);
    try w.writeVarU32(p.registry.packetId(.resource_pack_stack).?);
    try w.writeBool(false);
    try w.writeVarU32(60_000); // within every bound, far beyond the input
    try std.testing.expectError(error.EndOfStream, p.typed.decode(w.written(), .{}));
    try std.testing.expectError(error.LimitExceeded, p.typed.decode(w.written(), .{ .max_array_elements = 10 }));
}

test "coverage-guided packet decoding" {
    try std.testing.fuzz({}, fuzzPacket, .{});
}

fn fuzzPacket(_: void, smith: *std.testing.Smith) !void {
    var bytes: [2048]u8 = undefined;
    smith.bytesWithHash(&bytes, 0x2193_bed0);
    const len: usize = smith.valueRangeAtMostWithHash(u16, 0, bytes.len, 0x0c0d_ec00);
    _ = try campaign.check(bytes[0..len]);
}
