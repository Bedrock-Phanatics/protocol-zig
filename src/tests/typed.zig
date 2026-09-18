const std = @import("std");

const root = @import("../root.zig");

const Fixture = struct {
    tag: []const u8,
    wire: []const u8,
};

const fixtures = [_]Fixture{
    .{ .tag = "login", .wire = &.{ 0x01, 0x00, 0x00, 0x08, 0x79, 8, 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h' } },
    .{ .tag = "play_status", .wire = &.{ 0x02, 0x00, 0x00, 0x00, 0x03 } },
    .{ .tag = "server_to_client_handshake", .wire = &.{ 0x03, 3, 'k', 'e', 'y' } },
    .{ .tag = "client_to_server_handshake", .wire = &.{0x04} },
    .{ .tag = "disconnect", .wire = &.{ 0x05, 2, 0, 3, 'b', 'y', 'e', 3, 'b', 'y', 'e' } },
    .{ .tag = "disconnect", .wire = &.{ 0x05, 16, 1 } },
    .{ .tag = "set_time", .wire = &.{ 0x0a, 0x3c } },
    .{ .tag = "network_settings", .wire = &.{ 0x8f, 0x01, 0, 0, 0, 0, 0, 5, 0, 0, 0xa0, 0x40 } },
    .{ .tag = "request_network_settings", .wire = &.{ 0xc1, 0x01, 0x00, 0x00, 0x08, 0x79 } },
    .{ .tag = "network_stack_latency", .wire = &.{ 0x73, 1, 0, 0, 0, 0, 0, 0, 0, 1 } },
    .{ .tag = "remove_actor", .wire = &.{ 0x0e, 1 } },
    .{
        .tag = "move_player",
        .wire = &.{
            0x13,
            1,
            0,
            0,
            0x80,
            0x3f,
            0,
            0,
            0x80,
            0x3f,
            0,
            0,
            0x80,
            0x3f,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            1,
            0,
            0,
            5,
        },
    },
    .{ .tag = "set_health", .wire = &.{ 0x2a, 10 } },
    .{ .tag = "set_commands_enabled", .wire = &.{ 0x3b, 1 } },
    .{ .tag = "set_difficulty", .wire = &.{ 0x3c, 2 } },
    .{ .tag = "request_chunk_radius", .wire = &.{ 0x45, 8, 12 } },
    .{ .tag = "chunk_radius_updated", .wire = &.{ 0x46, 8 } },
};

const login_fixture_protocol_version: i32 = 2169;

test "canonical fixtures decode and re-encode byte-identically on every supported protocol" {
    inline for (fixtures) |fixture| {
        inline for (std.meta.fields(root.Protocol)) |field| {
            const protocol: root.Protocol = @enumFromInt(field.value);
            const decoded = try root.typed.decode(protocol, fixture.wire, .{});
            try std.testing.expect(decoded.packet != .unknown);
            try std.testing.expectEqualStrings(fixture.tag, @tagName(decoded.packet));

            var out: [256]u8 = undefined;
            var w = root.Writer.init(&out);
            try root.typed.encode(protocol, &w, decoded);
            try std.testing.expectEqualSlices(u8, fixture.wire, w.written());
        }
    }
}

test "version-carrying fields decode to the wire value regardless of protocol" {
    inline for (std.meta.fields(root.Protocol)) |field| {
        const protocol: root.Protocol = @enumFromInt(field.value);

        const login = try root.typed.decode(protocol, fixtures[0].wire, .{});
        try std.testing.expectEqual(login_fixture_protocol_version, login.packet.login.protocol_version);

        const request = try root.typed.decode(protocol, fixtures[8].wire, .{});
        try std.testing.expectEqual(login_fixture_protocol_version, request.packet.request_network_settings.client_protocol);
    }
}

test "play_status fixture carries player_spawn" {
    inline for (std.meta.fields(root.Protocol)) |field| {
        const protocol: root.Protocol = @enumFromInt(field.value);
        const decoded = try root.typed.decode(protocol, fixtures[1].wire, .{});
        try std.testing.expectEqual(root.packets.play_status.Status.player_spawn, decoded.packet.play_status.status);
    }
}

test "typed decoder rejects trailing bytes and packet ID mismatch" {
    try std.testing.expectError(error.TrailingData, root.typed.decode(.v2169, &.{ 2, 0, 0, 0, 3, 0xff }, .{}));

    var out: [16]u8 = undefined;
    var w = root.Writer.init(&out);
    try std.testing.expectError(error.InvalidPacketId, root.typed.encode(.v2169, &w, .{
        .header = .{ .packet_id = 1 },
        .packet = .{ .play_status = .{ .status = .login_success } },
    }));
    try std.testing.expectEqual(@as(usize, 0), w.written().len);
}

test "packet ids added in v2193 are known only from that protocol" {
    inline for ([_]u10{ 351, 352 }) |id| {
        var buf: [3]u8 = undefined;
        var w = root.Writer.init(&buf);
        try w.writeVarU32(id);
        const wire = w.written();

        const late = try root.typed.decode(.v2193, wire, .{});
        try std.testing.expect(late.packet == .unknown);
        try std.testing.expect(late.packet.unknown.known);

        const early = try root.typed.decode(.v2168, wire, .{});
        try std.testing.expect(early.packet == .unknown);
        try std.testing.expect(!early.packet.unknown.known);
    }
}

test "typed decoder treats unimplemented but valid protocol IDs as unknown" {
    const decoded = try root.typed.decode(.v2169, &.{99}, .{});
    try std.testing.expect(decoded.packet == .unknown);
    try std.testing.expect(decoded.packet.unknown.known);
    try std.testing.expectEqual(@as(u10, 99), decoded.packet.unknown.packet_id);
    try std.testing.expectEqual(@as(usize, 0), decoded.packet.unknown.raw.len);
}

test "typed decoder marks nonexistent packet IDs as unknown and not known" {
    const decoded = try root.typed.decode(.v2169, &.{20}, .{});
    try std.testing.expect(decoded.packet == .unknown);
    try std.testing.expect(!decoded.packet.unknown.known);
    try std.testing.expectEqual(@as(u10, 20), decoded.packet.unknown.packet_id);
}

test "typed decoder preserves unknown packet payload bytes" {
    const wire = &.{ 99, 0xaa, 0xbb, 0xcc };
    const decoded = try root.typed.decode(.v2169, wire, .{});
    try std.testing.expect(decoded.packet == .unknown);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb, 0xcc }, decoded.packet.unknown.raw);
}

test "typed encoder roundtrips unknown packets" {
    const wire = &.{ 99, 0xaa, 0xbb, 0xcc };
    const decoded = try root.typed.decode(.v2169, wire, .{});

    var out: [16]u8 = undefined;
    var w = root.Writer.init(&out);
    try root.typed.encode(.v2169, &w, decoded);
    try std.testing.expectEqualSlices(u8, wire, w.written());
}

test "typed encoder rejects header/packet id mismatch for unknown packets" {
    var out: [16]u8 = undefined;
    var w = root.Writer.init(&out);
    try std.testing.expectError(error.InvalidPacketId, root.typed.encode(.v2169, &w, .{
        .header = .{ .packet_id = 100 },
        .packet = .{ .unknown = .{ .packet_id = 99, .raw = &.{}, .known = true } },
    }));
}

test "play_status decode rejects invalid enum values" {
    var r = try root.Reader.init(&.{ 0, 0, 0, 99 }, .{});
    try std.testing.expectError(error.InvalidEnum, root.codecs.play_status.decode(.v2169, &r));
}

test "disconnect rejects out-of-range flag values" {
    var r = try root.Reader.init(&.{ 0, 2 }, .{});
    try std.testing.expectError(error.InvalidBoolean, root.codecs.disconnect.decode(.v2169, &r));
}

test "every versioned shape exposes normalize returning its module Canonical" {
    inline for (std.meta.fields(root.Protocol)) |field| {
        const protocol: root.Protocol = @enumFromInt(field.value);

        inline for (.{
            root.packets.login,
            root.packets.play_status,
            root.packets.server_to_client_handshake,
            root.packets.client_to_server_handshake,
            root.packets.disconnect,
            root.packets.set_time,
            root.packets.network_settings,
            root.packets.request_network_settings,
            root.packets.network_stack_latency,
            root.packets.remove_actor,
            root.packets.move_player,
            root.packets.set_health,
            root.packets.set_commands_enabled,
            root.packets.set_difficulty,
            root.packets.request_chunk_radius,
            root.packets.chunk_radius_updated,
        }) |m| {
            const S = m.Shape(protocol);
            comptime std.debug.assert(@hasDecl(S, "normalize"));
            comptime std.debug.assert(@TypeOf(@as(S, undefined).normalize()) == m.Canonical);
        }
    }
}

test "normalized packets keep tag id and canonical fields across every supported protocol" {
    inline for (fixtures) |fixture| {
        inline for (std.meta.fields(root.Protocol)) |field| {
            const protocol: root.Protocol = @enumFromInt(field.value);
            const decoded = try root.typed.decode(protocol, fixture.wire, .{});
            const norm = decoded.packet.normalized();

            try std.testing.expectEqualStrings(@tagName(decoded.packet), @tagName(norm));
            try std.testing.expectEqual(decoded.packet.id(), norm.id());
        }
    }
}

test "normalized disconnect carries the canonical message" {
    inline for (std.meta.fields(root.Protocol)) |field| {
        const protocol: root.Protocol = @enumFromInt(field.value);
        const decoded = try root.typed.decode(protocol, fixtures[4].wire, .{});
        const norm = decoded.packet.normalized();

        try std.testing.expectEqual(root.packets.disconnect.Reason.cant_connect_no_internet, norm.disconnect.reason);
        try std.testing.expectEqualStrings("bye", norm.disconnect.message);
        try std.testing.expectEqualStrings("bye", norm.disconnect.filtered_message);
    }
}
