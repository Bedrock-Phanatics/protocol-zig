const Reader = @import("../codec/reader.zig").Reader;
const Packet = @import("../packets/set_health.zig").Packet;
pub fn decode(r: *Reader) !Packet {
    return .{ .health = try r.readVarI32() };
}
pub fn encode(w: anytype, p: Packet) !void {
    try w.writeVarI32(p.health);
}
