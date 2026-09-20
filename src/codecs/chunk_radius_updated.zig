const Reader = @import("../codec/reader.zig").Reader;
const Packet = @import("../packets/chunk_radius_updated.zig").Packet;
pub fn decode(r: *Reader) !Packet {
    return .{ .chunk_radius = try r.readVarI32() };
}
pub fn encode(w: anytype, p: Packet) !void {
    try w.writeVarI32(p.chunk_radius);
}
