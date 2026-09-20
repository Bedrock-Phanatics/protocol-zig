const Reader = @import("../codec/reader.zig").Reader;
const packet = @import("../packets/network_settings.zig");

pub fn decodeRequest(reader: *Reader) !packet.RequestNetworkSettingsPacket {
    return .{ .client_protocol = try reader.readI32Be() };
}
pub fn encodeRequest(writer: anytype, value: packet.RequestNetworkSettingsPacket) !void {
    try writer.writeI32Be(value.client_protocol);
}
pub fn decode(reader: *Reader) !packet.NetworkSettingsPacket {
    return .{
        .compression_threshold = try reader.readU16(),
        .compression_algorithm = try reader.readU16(),
        .client_throttle = try reader.readBool(),
        .client_throttle_threshold = try reader.readU8(),
        .client_throttle_scalar = try reader.readF32(),
    };
}
pub fn encode(writer: anytype, value: packet.NetworkSettingsPacket) !void {
    try writer.writeU16(value.compression_threshold);
    try writer.writeU16(value.compression_algorithm);
    try writer.writeBool(value.client_throttle);
    try writer.writeU8(value.client_throttle_threshold);
    try writer.writeF32(value.client_throttle_scalar);
}
