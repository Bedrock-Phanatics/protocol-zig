const Reader = @import("../codec/reader.zig").Reader;
const Packet = @import("../packets/disconnect.zig").Packet;
pub fn decode(r: *Reader) !Packet {
    const reason = try r.readVarI32();
    const skipped = try r.readBool();
    if (skipped) return .{ .reason = reason, .message_skipped = true };
    return .{ .reason = reason, .message_skipped = false, .message = try r.readString(), .filtered_message = try r.readString() };
}
pub fn encode(w: anytype, p: Packet) !void {
    try w.writeVarI32(p.reason);
    try w.writeBool(p.message_skipped);
    if (!p.message_skipped) {
        try w.writeString(p.message);
        try w.writeString(p.filtered_message);
    }
}
