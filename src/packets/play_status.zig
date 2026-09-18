const Protocol = @import("../protocol.zig").Protocol;
const PacketId = @import("../registry/generated_packet_id.zig").PacketId;

pub const Status = enum(i32) {
    login_success = 0,
    login_failed_client = 1,
    login_failed_server = 2,
    player_spawn = 3,
    login_failed_invalid_tenant = 4,
    login_failed_vanilla_education = 5,
    login_failed_education_vanilla = 6,
    login_failed_server_full = 7,
    login_failed_editor_vanilla = 8,
    login_failed_vanilla_editor = 9,
};

pub const V2168 = struct {
    pub const id: PacketId = .play_status;
    status: Status,

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
