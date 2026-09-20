pub const current = @import("generated_registry.zig");
pub const PacketKind = current.PacketKind;
pub const packetId = current.packetId;
pub const packetKind = current.packetKind;
pub const direction = current.direction;
pub const hasCodec = @import("bindings.zig").hasCodec;
