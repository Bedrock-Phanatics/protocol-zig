const Protocol = @import("../protocol.zig").Protocol;
const PacketId = @import("../registry/generated_packet_id.zig").PacketId;
const Vec3f = @import("../types/vector.zig").Vec3f;

pub const MoveMode = enum(u8) {
    normal = 0,
    reset = 1,
    teleport = 2,
    rotation = 3,
};

pub const TeleportCause = enum(i32) {
    unknown = 0,
    project = 1,
    chant = 2,
    ender_pearl = 3,
    chorus_fruit = 4,
    command = 5,
    behavior = 6,
    _,
};

pub const TeleportData = struct {
    cause: TeleportCause,
    source_entity_type: i32,
};

pub const V2168 = struct {
    pub const id: PacketId = .move_player;
    entity_runtime_id: u64,
    position: Vec3f,
    rotation: Vec3f,
    mode: MoveMode,
    on_ground: bool,
    ridden_entity_runtime_id: u64,
    teleport: ?TeleportData,
    tick: u64,

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
