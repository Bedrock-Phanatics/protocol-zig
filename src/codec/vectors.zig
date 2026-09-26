//! Positions and vectors shared across the protocol.

pub const Vec2f = extern struct { x: f32, y: f32 };
pub const Vec3f = extern struct { x: f32, y: f32, z: f32 };
/// Sent as three zigzag varints.
pub const BlockPosition = struct { x: i32, y: i32, z: i32 };
/// Sent as two zigzag varints.
pub const ChunkPosition = struct { x: i32, z: i32 };
/// Sent as three little-endian i32s.
pub const SubChunkPosition = struct { x: i32, y: i32, z: i32 };
