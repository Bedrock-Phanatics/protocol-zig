const Reader = @import("../codec/reader.zig").Reader;
const Writer = @import("../codec/writer.zig").Writer;
const CountingWriter = @import("../codec/writer.zig").CountingWriter;
const Limits = @import("../codec/limits.zig").DecodeLimits;
const DecodeError = @import("../codec/errors.zig").DecodeError;
const EncodeError = @import("../codec/errors.zig").EncodeError;
const Header = @import("../packet.zig").Header;
const version = @import("../generated/root.zig");

pub const Packet = version.Packet;
pub const Envelope = struct { header: Header, packet: Packet };

pub fn packetKind(value: Packet) version.Kind {
    return value;
}

pub fn decode(input: []const u8, limits: Limits) DecodeError!Envelope {
    var r = try Reader.init(input, limits);
    const header = try Header.fromWire(try r.readVarU32());
    const kind = version.packetKind(header.packet_id) orelse return error.InvalidPacketId;
    const value = try version.decodePayload(&r, kind);
    try r.finish();
    return .{ .header = header, .packet = value };
}

pub fn encodedSize(e: Envelope) EncodeError!usize {
    var counter: CountingWriter = .{};
    try encodeTo(&counter, e);
    return counter.cursor;
}

/// Values and capacity are checked before any destination bytes change.
pub fn encode(w: *Writer, e: Envelope) EncodeError!void {
    if (try encodedSize(e) > w.remainingCapacity()) return error.NoSpaceLeft;
    try encodeTo(w, e);
}

fn encodeTo(w: anytype, e: Envelope) EncodeError!void {
    if (e.header.packet_id != version.packetId(e.packet)) return error.InvalidValue;
    try w.writeVarU32(e.header.toWire());
    try version.encodePayload(w, e.packet);
}
