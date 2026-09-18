const Protocol = @import("../protocol.zig").Protocol;
const PacketId = @import("../registry/generated_packet_id.zig").PacketId;

pub const Reason = enum(i32) {
    unknown = 0,
    cant_connect_no_internet = 1,
    no_permissions = 2,
    unrecoverable_error = 3,
    third_party_blocked = 4,
    third_party_no_internet = 5,
    third_party_bad_ip = 6,
    third_party_no_server_or_server_locked = 7,
    version_mismatch = 8,
    skin_issue = 9,
    invite_session_not_found = 10,
    edu_level_settings_missing = 11,
    local_server_not_found = 12,
    legacy_disconnect = 13,
    user_leave_game_attempted = 14,
    platform_locked_skins_error = 15,
    realms_world_unassigned = 16,
    realms_server_cant_connect = 17,
    realms_server_hidden = 18,
    realms_server_disabled_beta = 19,
    realms_server_disabled = 20,
    cross_platform_disabled = 21,
    cant_connect = 22,
    session_not_found = 23,
    client_settings_incompatible_with_server = 24,
    server_full = 25,
    invalid_platform_skin = 26,
    edition_version_mismatch = 27,
    edition_mismatch = 28,
    editor_version_mismatch = 29,
    editor_mismatch = 30,
    server_full_sub_client = 31,
    _,
};

pub const V2168 = struct {
    pub const id: PacketId = .disconnect;
    reason: Reason,
    message_skipped: bool,
    message: []const u8 = "",
    filtered_message: []const u8 = "",

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
