const Kind = @import("generated_registry.zig").PacketKind;
pub const entries = .{
    Binding(.login, @import("../codecs/login.zig"), "decode", "encode"),
    Binding(.play_status, @import("../codecs/play_status.zig"), "decode", "encode"),
    Binding(.server_to_client_handshake, @import("../codecs/server_to_client_handshake.zig"), "decode", "encode"),
    Binding(.client_to_server_handshake, @import("../codecs/client_to_server_handshake.zig"), "decode", "encode"),
    Binding(.disconnect, @import("../codecs/disconnect.zig"), "decode", "encode"),
    Binding(.set_time, @import("../codecs/set_time.zig"), "decode", "encode"),
    Binding(.remove_actor, @import("../codecs/remove_actor.zig"), "decode", "encode"),
    Binding(.move_player, @import("../codecs/move_player.zig"), "decode", "encode"),
    Binding(.set_health, @import("../codecs/set_health.zig"), "decode", "encode"),
    Binding(.set_commands_enabled, @import("../codecs/set_commands_enabled.zig"), "decode", "encode"),
    Binding(.set_difficulty, @import("../codecs/set_difficulty.zig"), "decode", "encode"),
    Binding(.request_chunk_radius, @import("../codecs/request_chunk_radius.zig"), "decode", "encode"),
    Binding(.chunk_radius_updated, @import("../codecs/chunk_radius_updated.zig"), "decode", "encode"),
    Binding(.network_stack_latency, @import("../codecs/network_stack_latency.zig"), "decode", "encode"),
    Binding(.network_settings, @import("../codecs/network_settings.zig"), "decode", "encode"),
    Binding(.request_network_settings, @import("../codecs/network_settings.zig"), "decodeRequest", "encodeRequest"),
};
fn Binding(comptime tag: Kind, comptime codec: type, comptime decode_name: []const u8, comptime encode_name: []const u8) type {
    return struct {
        pub const kind = tag;
        pub const decode = @field(codec, decode_name);
        pub const encode = @field(codec, encode_name);
    };
}
pub fn hasCodec(kind: Kind) bool {
    inline for (entries) |B| if (kind == B.kind) return true;
    return false;
}
