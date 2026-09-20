pub const current = @import("generated_registry.zig");
pub const PacketKind = current.PacketKind;
pub const packetId = current.packetId;
pub const packetKind = current.packetKind;
pub const Coverage = enum { scalar, borrowed_collection, known_opaque };
pub fn coverage(kind: PacketKind) Coverage {
    return switch (kind) {
        .resource_packs_info, .resource_pack_stack, .resource_pack_client_response => .borrowed_collection,
        else => if (@import("bindings.zig").hasCodec(kind)) .scalar else .known_opaque,
    };
}
pub fn hasCodec(kind: PacketKind) bool {
    return coverage(kind) != .known_opaque;
}
