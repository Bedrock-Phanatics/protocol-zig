const Protocol = @import("../protocol.zig").Protocol;
const PacketId = @import("../registry/generated_packet_id.zig").PacketId;

pub const TextType = enum(u8) {
    raw = 0,
    chat = 1,
    translation = 2,
    popup = 3,
    jukebox_popup = 4,
    tip = 5,
    system = 6,
    whisper = 7,
    announcement = 8,
    whisper_json = 9,
    json = 10,
    announcement_json = 11,
};

pub const V2168 = struct {
    pub const id: PacketId = .text;
    text_type: TextType,
    needs_translation: bool,
    source_name: []const u8 = "",
    message: []const u8,
    parameters_buf: [4][]const u8 = undefined,
    parameters_len: u8 = 0,
    xuid: []const u8 = "",
    platform_chat_id: []const u8 = "",
    filtered_message: ?[]const u8 = null,

    pub fn parameters(self: *const @This()) []const []const u8 {
        return self.parameters_buf[0..self.parameters_len];
    }

    pub fn normalize(self: @This()) Canonical {
        return self;
    }
};

pub const V2169 = V2168;
pub const V2193 = V2168;

pub const Canonical = V2168;
pub const Current = V2193;

pub fn Shape(comptime protocol: Protocol) type {
    return switch (protocol) {
        .v2168 => V2168,
        .v2169 => V2169,
        .v2193 => V2193,
    };
}
