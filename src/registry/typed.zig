const Reader = @import("../codec/reader.zig").Reader;
const Writer = @import("../codec/writer.zig").Writer;
const Limits = @import("../codec/limits.zig").DecodeLimits;
const Header = @import("../packet.zig").Header;
const registry = @import("generated_registry.zig");
const bindings = @import("bindings.zig");
pub const Packet = union(enum) {
    login: @import("../packets/login.zig").Packet,
    play_status: @import("../packets/play_status.zig").PlayStatusPacket,
    server_to_client_handshake: @import("../packets/server_to_client_handshake.zig").Packet,
    client_to_server_handshake: @import("../packets/client_to_server_handshake.zig").Packet,
    disconnect: @import("../packets/disconnect.zig").Packet,
    set_time: @import("../packets/set_time.zig").Packet,
    remove_actor: @import("../packets/remove_actor.zig").Packet,
    move_player: @import("../packets/move_player.zig").MovePlayerPacket,
    set_health: @import("../packets/set_health.zig").Packet,
    set_commands_enabled: @import("../packets/set_commands_enabled.zig").Packet,
    set_difficulty: @import("../packets/set_difficulty.zig").Packet,
    request_chunk_radius: @import("../packets/request_chunk_radius.zig").Packet,
    chunk_radius_updated: @import("../packets/chunk_radius_updated.zig").Packet,
    network_stack_latency: @import("../packets/network_stack_latency.zig").Packet,
    network_settings: @import("../packets/network_settings.zig").NetworkSettingsPacket,
    request_network_settings: @import("../packets/network_settings.zig").RequestNetworkSettingsPacket,
};
pub const Envelope = struct { header: Header, packet: Packet };
pub fn packetKind(value: Packet) registry.PacketKind {
    return switch (value) {
        inline else => |_, tag| @field(registry.PacketKind, @tagName(tag)),
    };
}
pub inline fn decode(input: []const u8, limits: Limits) !Envelope {
    var r = try Reader.init(input, limits);
    const header = try Header.fromWire(try r.readVarU32());
    const kind = registry.packetKind(header.packet_id) orelse return error.InvalidPacketId;
    const value = try decodePayload(&r, kind);
    try r.finish();
    return .{ .header = header, .packet = value };
}
pub inline fn decodePayload(r: *Reader, kind: registry.PacketKind) !Packet {
    inline for (bindings.entries) |B| {
        if (kind == B.kind) return @unionInit(Packet, @tagName(B.kind), try B.decode(r));
    }
    return error.InvalidPacketId;
}
pub fn encodedSize(e: Envelope) !usize {
    var counter: @import("../codec/writer.zig").CountingWriter = .{};
    try encodeTo(&counter, e);
    return counter.cursor;
}
/// Values and capacity are checked before any destination bytes are changed.
pub inline fn encode(w: *Writer, e: Envelope) !void {
    const size = try encodedSize(e);
    if (size > w.remainingCapacity()) return error.NoSpaceLeft;
    try encodeTo(w, e);
}
fn encodeTo(w: anytype, e: Envelope) !void {
    if (e.header.packet_id != registry.packetId(packetKind(e.packet)).?) return error.InvalidValue;
    try w.writeVarU32(e.header.toWire());
    try encodePayload(w, e.packet);
}
pub fn encodePayload(w: anytype, value_packet: Packet) !void {
    switch (value_packet) {
        inline else => |value, tag| {
            inline for (bindings.entries) |B| {
                if (comptime @field(registry.PacketKind, @tagName(tag)) == B.kind) try B.encode(w, value);
            }
        },
    }
}

comptime {
    const fields = @typeInfo(Packet).@"union".fields;
    if (fields.len != bindings.entries.len) @compileError("typed packet union and codec bindings differ");
    for (bindings.entries, 0..) |B, i| {
        if (!@hasField(Packet, @tagName(B.kind))) @compileError("codec has no typed packet field");
        for (bindings.entries[0..i]) |Previous| if (Previous.kind == B.kind) @compileError("duplicate typed codec binding");
    }
}
