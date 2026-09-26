//! Minecraft: Bedrock Edition protocol codecs.
//!
//! Decoding never allocates: strings, byte arrays, NBT and lists in a decoded
//! packet borrow the input buffer and are valid only while it is.

pub const profile = @import("profile.zig");
pub const Current = profile.Current;
pub const validateProfile = profile.validateProfile;
pub const SessionFeatures = profile.SessionFeatures;
pub const CompressionAlgorithm = profile.CompressionAlgorithm;
pub const BorrowedEnvelope = profile.BorrowedEnvelope;

pub const registry = @import("registry/root.zig");
pub const PacketKind = registry.PacketKind;
pub const PacketDirection = registry.PacketDirection;
pub const typed = @import("registry/typed.zig");
pub const packet = @import("packet.zig");

pub const DecodeLimits = @import("codec/limits.zig").DecodeLimits;
pub const DecodeError = @import("codec/errors.zig").DecodeError;
pub const EncodeError = @import("codec/errors.zig").EncodeError;
pub const Reader = @import("codec/reader.zig").Reader;
pub const Writer = @import("codec/writer.zig").Writer;
pub const CountingWriter = @import("codec/writer.zig").CountingWriter;
pub const List = @import("codec/list.zig").List;
pub const Bitset = @import("codec/bitset.zig").Bitset;
pub const nbt = @import("codec/nbt.zig");

/// Protocol 2193 (Minecraft 1.26.50).
pub const v2193 = @import("v2193/root.zig");
pub const PacketId = v2193.Id;
/// Packet definitions of the current version, one namespace per packet.
pub const packets = v2193.packets;
/// Protocol types shared by more than one packet in the current version.
pub const types = v2193.types;

const vectors = @import("codec/vectors.zig");
pub const Vec2f = vectors.Vec2f;
pub const Vec3f = vectors.Vec3f;
pub const BlockPosition = vectors.BlockPosition;
pub const ChunkPosition = vectors.ChunkPosition;
pub const SubChunkPosition = vectors.SubChunkPosition;

test {
    _ = @import("codec/patterns.zig");
    _ = @import("custom/root.zig");
    _ = @import("tests/primitives.zig");
    _ = @import("tests/nbt.zig");
    _ = @import("tests/packet.zig");
    _ = @import("tests/encoding.zig");
    _ = @import("tests/registry.zig");
    _ = @import("tests/profile.zig");
    _ = @import("tests/typed.zig");
    _ = @import("tests/resource_pack.zig");
    _ = @import("tests/generated.zig");
    _ = @import("tests/corpus.zig");
}

test "deterministic profile adversarial smoke" {
    try @import("tests/fuzz.zig").run(@This(), 20_000);
}
