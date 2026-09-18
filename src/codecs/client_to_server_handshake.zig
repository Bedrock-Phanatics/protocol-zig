const Reader = @import("../codec/reader.zig").Reader;
const Writer = @import("../codec/writer.zig").Writer;
const packet = @import("../packets/client_to_server_handshake.zig");
const Protocol = @import("../protocol.zig").Protocol;

pub fn decode(comptime protocol: Protocol, _: *Reader) !packet.Shape(protocol) {
    switch (protocol) {
        .v2168, .v2169, .v2193 => return .{},
    }
}

pub fn encode(comptime protocol: Protocol, _: *Writer, _: packet.Shape(protocol)) !void {
    switch (protocol) {
        .v2168, .v2169, .v2193 => {},
    }
}
