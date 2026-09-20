pub const profile = @import("profile.zig");
pub const Current = profile.Current;
pub const current = profile.current;
pub const validateProfile = profile.validateProfile;
pub const SessionFeatures = profile.SessionFeatures;
pub const BorrowedEnvelope = profile.BorrowedEnvelope;
pub const registry = @import("registry/root.zig");
pub const PacketKind = registry.PacketKind;
pub const DecodeLimits = @import("codec/limits.zig").DecodeLimits;
pub const DecodeError = @import("codec/errors.zig").DecodeError;
pub const EncodeError = @import("codec/errors.zig").EncodeError;
pub const Reader = @import("codec/reader.zig").Reader;
pub const Writer = @import("codec/writer.zig").Writer;
/// Deprecated compatibility helper. New session code should use Bedwire framing/compression.
pub const batch = @import("codec/batch.zig");
pub const nbt = @import("codec/nbt.zig");
pub const packet = @import("packet.zig");
pub const typed = @import("registry/typed.zig");
pub const PacketId = @import("registry/generated_packet_id.zig").PacketId;
pub const generated_packets = @import("packets/generated.zig");
pub const BlockPosition = @import("types/block_position.zig").BlockPosition;
pub const ChunkPosition = @import("types/position.zig").ChunkPosition;
pub const SubChunkPosition = @import("types/position.zig").SubChunkPosition;
pub const Rgba = @import("types/colour.zig").Rgba;
pub const Vec2f = @import("types/vector.zig").Vec2f;
pub const Vec3f = @import("types/vector.zig").Vec3f;
pub const packets = struct {
    pub const play_status = @import("packets/play_status.zig");
    pub const network_settings = @import("packets/network_settings.zig");
    pub const move_player = @import("packets/move_player.zig");
    pub const resource_pack = @import("packets/resource_pack.zig");
};
pub const codecs = struct {
    pub const play_status = @import("codecs/play_status.zig");
    pub const network_settings = @import("codecs/network_settings.zig");
    pub const move_player = @import("codecs/move_player.zig");
    pub const resource_pack = @import("codecs/resource_pack.zig");
};
test {
    _ = @import("tests/profile.zig");
    _ = @import("tests/encoding.zig");
    _ = @import("tests/registry.zig");
    _ = @import("tests/primitives.zig");
    _ = @import("tests/packet.zig");
    _ = @import("tests/audit.zig");
    _ = @import("tests/typed.zig");
    _ = @import("tests/nbt.zig");
    _ = @import("tests/compression.zig");
    _ = @import("tests/resource_pack.zig");
}

test "deterministic profile adversarial smoke" {
    try @import("tests/fuzz.zig").run(@This(), 20_000);
}
