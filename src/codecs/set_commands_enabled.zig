const Reader = @import("../codec/reader.zig").Reader;
const Packet = @import("../packets/set_commands_enabled.zig").Packet;
pub fn decode(r: *Reader) !Packet {
    return .{ .enabled = try r.readBool() };
}
pub fn encode(w: anytype, p: Packet) !void {
    try w.writeBool(p.enabled);
}
