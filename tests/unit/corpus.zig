//! Replays tests/corpus.txt. Every line is a complete packet that must decode
//! from the side that sent it, consume its input exactly and re-encode byte
//! for byte. Every packet must have a sample for each side that may send it.
//! Every strict prefix and every single corrupted byte of every sample is
//! replayed as hostile input.
const std = @import("std");
const root = @import("bedrock_protocol");
const campaign = @import("../fuzz/campaign.zig");
const corpus_file = @import("build_options").corpus_file;

test "corpus packets round trip byte for byte" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, corpus_file, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(text);
    const bytes = try gpa.alloc(u8, root.DecodeLimits.defaults.max_packet_bytes);
    defer gpa.free(bytes);
    const output = try gpa.alloc(u8, root.DecodeLimits.defaults.max_packet_bytes);
    defer gpa.free(output);

    var seen = [_][2]bool{.{ false, false }} ** 1024;
    var checked: usize = 0;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        errdefer std.debug.print("corpus line: {s}\n", .{line[0..@min(line.len, 64)]});
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const from_server = std.mem.eql(u8, fields.next().?, "server");
        _ = fields.next().?;
        const packet = try std.fmt.hexToBytes(bytes, fields.next().?);

        const decoded = try root.typed.decode(packet, .{});
        const direction = root.registry.packetDirection(root.typed.packetKind(decoded.packet));
        const expected: root.PacketDirection = if (from_server) .server_to_client else .client_to_server;
        try std.testing.expect(direction == .bidirectional or direction == expected);
        try std.testing.expectEqual(packet.len, try root.typed.encodedSize(decoded));
        var w = root.Writer.init(output);
        try root.typed.encode(&w, decoded);
        try std.testing.expectEqualSlices(u8, packet, w.written());
        try std.testing.expect((try root.Current.decodeBorrowed(packet, .{})).value == .typed);
        seen[decoded.header.packet_id][@intFromBool(from_server)] = true;

        // A prefix follows the same parse path and runs out of input.
        for (0..packet.len) |n| try std.testing.expectError(error.EndOfStream, root.typed.decode(packet[0..n], .{}));
        // A corrupted byte is rejected or still round-trips exactly.
        for (packet) |*byte| {
            const original = byte.*;
            defer byte.* = original;
            for ([_]u8{ original ^ 0x80, original ^ 0x01, 0xff }) |value| {
                byte.* = value;
                _ = try campaign.check(packet);
            }
        }
        checked += 1;
    }
    for (std.enums.values(root.PacketKind)) |kind| {
        const id = root.registry.packetId(kind).?;
        const direction = root.registry.packetDirection(kind);
        if (direction != .server_to_client) try std.testing.expect(seen[id][0]);
        if (direction != .client_to_server) try std.testing.expect(seen[id][1]);
    }
    try std.testing.expect(checked > 0);
}
