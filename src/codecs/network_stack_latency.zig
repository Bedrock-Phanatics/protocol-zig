const Reader = @import("../codec/reader.zig").Reader;
const Packet = @import("../packets/network_stack_latency.zig").Packet;
pub fn decode(r: *Reader) !Packet {
    return .{ .timestamp = try r.readI64(), .needs_response = try r.readBool() };
}
pub fn encode(w: anytype, p: Packet) !void {
    try w.writeI64(p.timestamp);
    try w.writeBool(p.needs_response);
}
