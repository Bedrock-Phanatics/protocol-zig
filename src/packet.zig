const Reader = @import("codec/reader.zig").Reader;
const Writer = @import("codec/writer.zig").Writer;
const DecodeLimits = @import("codec/limits.zig").DecodeLimits;

pub const Header = packed struct(u14) {
    packet_id: u10,
    sender_subclient: u2 = 0,
    target_subclient: u2 = 0,

    pub fn fromWire(value: u32) error{InvalidPacketId}!Header {
        if (value > 0x3fff) return error.InvalidPacketId;
        return @bitCast(@as(u14, @intCast(value)));
    }
    pub fn toWire(self: Header) u32 {
        return @as(u14, @bitCast(self));
    }
};

/// Borrowed envelope. `payload` remains valid only while the input buffer does.
pub const Envelope = struct { header: Header, payload: []const u8 };

pub fn decode(input: []const u8, limits: DecodeLimits) !Envelope {
    var reader = try Reader.init(input, limits);
    const header = try Header.fromWire(try reader.readVarU32());
    return .{ .header = header, .payload = reader.input[reader.cursor..] };
}

pub fn encode(writer: *Writer, envelope: Envelope) !void {
    const header_bytes: usize = if (envelope.header.toWire() < 128) 1 else 2;
    const capacity = writer.remainingCapacity();
    if (header_bytes > capacity or envelope.payload.len > capacity - header_bytes) return error.NoSpaceLeft;
    try writer.writeVarU32(envelope.header.toWire());
    try writer.writeRaw(envelope.payload);
}
