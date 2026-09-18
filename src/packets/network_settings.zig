const Protocol = @import("../protocol.zig").Protocol;
const PacketId = @import("../registry/generated_packet_id.zig").PacketId;

pub const CompressionAlgorithm = enum(u16) {
    zlib = 0,
    snappy = 1,
    none = 255,
    _,
};

pub const V2168 = struct {
    pub const id: PacketId = .network_settings;
    compression_threshold: u16,
    compression_algorithm: CompressionAlgorithm,
    client_throttle: bool,
    client_throttle_threshold: u8,
    client_throttle_scalar: f32,

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
