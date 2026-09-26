//! Replays tests/corpus: every file is a complete packet that must decode,
//! consume its input exactly, re-encode byte for byte, and be accepted from
//! the direction its directory names.
const std = @import("std");
const root = @import("../root.zig");
const corpus_dir = @import("build_options").corpus_dir;

test "corpus packets round trip byte for byte" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var dir = try std.Io.Dir.openDirAbsolute(io, corpus_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var checked: usize = 0;
    var seen = [_][2]bool{.{ false, false }} ** 1024;
    const output = try gpa.alloc(u8, root.DecodeLimits.defaults.max_packet_bytes);
    defer gpa.free(output);
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".bin")) continue;
        const bytes = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(root.DecodeLimits.defaults.max_packet_bytes));
        defer gpa.free(bytes);
        const from_server = std.mem.startsWith(u8, entry.path, "server");
        errdefer std.debug.print("corpus file {s}\n", .{entry.path});
        const decoded = try root.typed.decode(bytes, .{});
        const kind = root.typed.packetKind(decoded.packet);
        const direction = root.registry.packetDirection(kind);
        const expected: root.PacketDirection = if (from_server) .server_to_client else .client_to_server;
        try std.testing.expect(direction == .bidirectional or direction == expected);
        try std.testing.expectEqual(bytes.len, try root.typed.encodedSize(decoded));
        var w = root.Writer.init(output);
        try root.typed.encode(&w, decoded);
        try std.testing.expectEqualSlices(u8, bytes, w.written());
        const borrowed = try root.Current.decodeBorrowed(bytes, .{});
        try std.testing.expect(borrowed.value == .typed);
        seen[decoded.header.packet_id][@intFromBool(from_server)] = true;
        checked += 1;
    }
    // Every packet and every direction it may travel has at least one fixture.
    for (std.enums.values(root.PacketKind)) |kind| {
        const id = root.registry.packetId(kind).?;
        const direction = root.registry.packetDirection(kind);
        if (direction != .server_to_client) try std.testing.expect(seen[id][0]);
        if (direction != .client_to_server) try std.testing.expect(seen[id][1]);
    }
    try std.testing.expect(checked > 0);
}
