const Reader = @import("../codec/reader.zig").Reader;
const Writer = @import("../codec/writer.zig").Writer;
const packet = @import("../packets/server_to_client_handshake.zig");
const Protocol = @import("../protocol.zig").Protocol;

pub fn decode(comptime protocol: Protocol, r: *Reader) !packet.Shape(protocol) {
    switch (protocol) {
        .v2168, .v2169, .v2193 => return .{ .jwt = try r.readString() },
    }
}

pub fn encode(comptime protocol: Protocol, w: *Writer, p: packet.Shape(protocol)) !void {
    switch (protocol) {
        .v2168, .v2169, .v2193 => try w.writeString(p.jwt),
    }
}
