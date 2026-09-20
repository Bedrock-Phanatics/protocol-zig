const Reader = @import("../codec/reader.zig").Reader;
const Packet = @import("../packets/login.zig").Packet;
pub fn decode(r: *Reader) !Packet {
    return .{ .client_protocol = try r.readI32Be(), .connection_request = try r.readByteArray() };
}
pub fn encode(w: anytype, p: Packet) !void {
    try w.writeI32Be(p.client_protocol);
    try w.writeByteArray(p.connection_request);
}
