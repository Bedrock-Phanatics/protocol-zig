const Reader = @import("../codec/reader.zig").Reader;
const Packet = @import("../packets/request_chunk_radius.zig").Packet;
pub fn decode(r: *Reader) !Packet {
    return .{ .chunk_radius = try r.readVarI32(), .max_chunk_radius = try r.readU8() };
}
pub fn encode(w: anytype, p: Packet) !void {
    try w.writeVarI32(p.chunk_radius);
    try w.writeU8(p.max_chunk_radius);
}
