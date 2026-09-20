const Reader = @import("../codec/reader.zig").Reader;
const Packet = @import("../packets/client_to_server_handshake.zig").Packet;
pub fn decode(_: *Reader) !Packet {
    return .{};
}
pub fn encode(_: anytype, _: Packet) !void {}
