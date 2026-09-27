//! Packet identity for the current protocol version.
const version = @import("../generated/root.zig");

pub const PacketKind = version.Kind;
pub const PacketDirection = version.Direction;
pub const packetKind = version.packetKind;
pub const packetDirection = version.packetDirection;

pub fn packetId(kind: PacketKind) ?u10 {
    return version.packetId(kind);
}
