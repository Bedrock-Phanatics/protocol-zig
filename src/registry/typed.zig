const std = @import("std");

const Limits = @import("../codec/limits.zig").DecodeLimits;
const Reader = @import("../codec/reader.zig").Reader;
const Writer = @import("../codec/writer.zig").Writer;
const Header = @import("../packet.zig").Header;
const Protocol = @import("../protocol.zig").Protocol;
const PacketId = @import("generated_packet_id.zig").PacketId;

const packets = struct {
    pub const login = @import("../packets/login.zig");
    pub const play_status = @import("../packets/play_status.zig");
    pub const server_to_client_handshake = @import("../packets/server_to_client_handshake.zig");
    pub const client_to_server_handshake = @import("../packets/client_to_server_handshake.zig");
    pub const disconnect = @import("../packets/disconnect.zig");
    pub const set_time = @import("../packets/set_time.zig");
    pub const network_settings = @import("../packets/network_settings.zig");
    pub const request_network_settings = @import("../packets/request_network_settings.zig");
    pub const network_stack_latency = @import("../packets/network_stack_latency.zig");
    pub const remove_actor = @import("../packets/remove_actor.zig");
    pub const move_player = @import("../packets/move_player.zig");
    pub const set_health = @import("../packets/set_health.zig");
    pub const set_commands_enabled = @import("../packets/set_commands_enabled.zig");
    pub const set_difficulty = @import("../packets/set_difficulty.zig");
    pub const request_chunk_radius = @import("../packets/request_chunk_radius.zig");
    pub const chunk_radius_updated = @import("../packets/chunk_radius_updated.zig");
    pub const text = @import("../packets/text.zig");
};

const codecs = struct {
    pub const login = @import("../codecs/login.zig");
    pub const play_status = @import("../codecs/play_status.zig");
    pub const server_to_client_handshake = @import("../codecs/server_to_client_handshake.zig");
    pub const client_to_server_handshake = @import("../codecs/client_to_server_handshake.zig");
    pub const disconnect = @import("../codecs/disconnect.zig");
    pub const set_time = @import("../codecs/set_time.zig");
    pub const network_settings = @import("../codecs/network_settings.zig");
    pub const request_network_settings = @import("../codecs/request_network_settings.zig");
    pub const network_stack_latency = @import("../codecs/network_stack_latency.zig");
    pub const remove_actor = @import("../codecs/remove_actor.zig");
    pub const move_player = @import("../codecs/move_player.zig");
    pub const set_health = @import("../codecs/set_health.zig");
    pub const set_commands_enabled = @import("../codecs/set_commands_enabled.zig");
    pub const set_difficulty = @import("../codecs/set_difficulty.zig");
    pub const request_chunk_radius = @import("../codecs/request_chunk_radius.zig");
    pub const chunk_radius_updated = @import("../codecs/chunk_radius_updated.zig");
    pub const text = @import("../codecs/text.zig");
};

const Known = struct {
    id: PacketId,
    since: Protocol,
};

const late_ids = [_]Known{
    .{ .id = .set_player_furnace_options, .since = .v2193 },
    .{ .id = .record_started, .since = .v2193 },
};

pub fn isKnownPacketId(comptime protocol: Protocol, packet_id: u10) bool {
    const e: PacketId = @enumFromInt(packet_id);
    if (std.enums.tagName(PacketId, e) == null) return false;
    inline for (late_ids) |known| {
        if (e == known.id and @intFromEnum(protocol) < @intFromEnum(known.since)) return false;
    }
    return true;
}

pub const CanonicalPacket = union(enum) {
    login: packets.login.Canonical,
    play_status: packets.play_status.Canonical,
    server_to_client_handshake: packets.server_to_client_handshake.Canonical,
    client_to_server_handshake: packets.client_to_server_handshake.Canonical,
    disconnect: packets.disconnect.Canonical,
    set_time: packets.set_time.Canonical,
    network_settings: packets.network_settings.Canonical,
    request_network_settings: packets.request_network_settings.Canonical,
    network_stack_latency: packets.network_stack_latency.Canonical,
    remove_actor: packets.remove_actor.Canonical,
    move_player: packets.move_player.Canonical,
    set_health: packets.set_health.Canonical,
    set_commands_enabled: packets.set_commands_enabled.Canonical,
    set_difficulty: packets.set_difficulty.Canonical,
    request_chunk_radius: packets.request_chunk_radius.Canonical,
    chunk_radius_updated: packets.chunk_radius_updated.Canonical,
    text: packets.text.Canonical,
    unknown: UnknownPacket,

    pub fn id(self: @This()) u10 {
        return switch (self) {
            .unknown => |u| u.packet_id,
            inline else => |payload| @intFromEnum(@TypeOf(payload).id),
        };
    }
};

pub const UnknownPacket = struct {
    packet_id: u10,
    raw: []const u8,
    known: bool,
};

pub fn Packet(comptime protocol: Protocol) type {
    return union(enum) {
        login: packets.login.Shape(protocol),
        play_status: packets.play_status.Shape(protocol),
        server_to_client_handshake: packets.server_to_client_handshake.Shape(protocol),
        client_to_server_handshake: packets.client_to_server_handshake.Shape(protocol),
        disconnect: packets.disconnect.Shape(protocol),
        set_time: packets.set_time.Shape(protocol),
        network_settings: packets.network_settings.Shape(protocol),
        request_network_settings: packets.request_network_settings.Shape(protocol),
        network_stack_latency: packets.network_stack_latency.Shape(protocol),
        remove_actor: packets.remove_actor.Shape(protocol),
        move_player: packets.move_player.Shape(protocol),
        set_health: packets.set_health.Shape(protocol),
        set_commands_enabled: packets.set_commands_enabled.Shape(protocol),
        set_difficulty: packets.set_difficulty.Shape(protocol),
        request_chunk_radius: packets.request_chunk_radius.Shape(protocol),
        chunk_radius_updated: packets.chunk_radius_updated.Shape(protocol),
        text: packets.text.Shape(protocol),
        unknown: UnknownPacket,

        pub fn id(self: @This()) u10 {
            return switch (self) {
                .unknown => |u| u.packet_id,
                inline else => |payload| @intFromEnum(@TypeOf(payload).id),
            };
        }

        pub fn normalized(self: @This()) CanonicalPacket {
            return switch (self) {
                .unknown => |u| .{ .unknown = u },
                inline else => |payload, tag| @unionInit(CanonicalPacket, @tagName(tag), payload.normalize()),
            };
        }
    };
}

pub fn Envelope(comptime protocol: Protocol) type {
    return struct { header: Header, packet: Packet(protocol) };
}

pub fn decode(comptime protocol: Protocol, input: []const u8, limits: Limits) !Envelope(protocol) {
    var r = try Reader.init(input, limits);
    const h = try Header.fromWire(try r.readVarU32());

    const PacketT = Packet(protocol);
    const value: PacketT = blk: {
        inline for (std.meta.fields(PacketT)) |field| {
            if (field.type == UnknownPacket) continue;
            if (h.packet_id == @intFromEnum(field.type.id)) {
                const codec = @field(codecs, field.name);
                break :blk @unionInit(PacketT, field.name, try codec.decode(protocol, &r));
            }
        }
        break :blk .{ .unknown = .{
            .packet_id = h.packet_id,
            .raw = r.readRemaining(),
            .known = isKnownPacketId(protocol, h.packet_id),
        } };
    };

    try r.finish();
    return .{ .header = h, .packet = value };
}

pub fn encode(comptime protocol: Protocol, w: *Writer, e: Envelope(protocol)) !void {
    switch (e.packet) {
        .unknown => |u| {
            if (e.header.packet_id != u.packet_id) return error.InvalidPacketId;
            try w.writeVarU32(e.header.toWire());
            try w.writeRaw(u.raw);
        },
        inline else => |payload, tag| {
            if (e.header.packet_id != @intFromEnum(@TypeOf(payload).id)) return error.InvalidPacketId;
            try w.writeVarU32(e.header.toWire());
            const codec = @field(codecs, @tagName(tag));
            try codec.encode(protocol, w, payload);
        },
    }
}
