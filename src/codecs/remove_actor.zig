const Reader = @import("../codec/reader.zig").Reader;
const Packet = @import("../packets/remove_actor.zig").Packet;
pub fn decode(r: *Reader) !Packet {
    return .{ .entity_unique_id = try r.readVarI64() };
}
pub fn encode(w: anytype, p: Packet) !void {
    try w.writeVarI64(p.entity_unique_id);
}
