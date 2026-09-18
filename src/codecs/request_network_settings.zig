const Reader = @import("../codec/reader.zig").Reader;
const Writer = @import("../codec/writer.zig").Writer;
const packet = @import("../packets/request_network_settings.zig");
const Protocol = @import("../protocol.zig").Protocol;

pub fn decode(comptime protocol: Protocol, r: *Reader) !packet.Shape(protocol) {
    return switch (protocol) {
        .v2168, .v2169, .v2193 => .{ .client_protocol = try r.readI32Be() },
    };
}

pub fn encode(comptime protocol: Protocol, w: *Writer, p: packet.Shape(protocol)) !void {
    switch (protocol) {
        .v2168, .v2169, .v2193 => try w.writeI32Be(p.client_protocol),
    }
}
