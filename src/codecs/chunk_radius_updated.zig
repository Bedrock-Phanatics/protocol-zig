const Reader = @import("../codec/reader.zig").Reader;
const Writer = @import("../codec/writer.zig").Writer;
const packet = @import("../packets/chunk_radius_updated.zig");
const Protocol = @import("../protocol.zig").Protocol;

pub fn decode(comptime protocol: Protocol, r: *Reader) !packet.Shape(protocol) {
    return switch (protocol) {
        .v2168, .v2169, .v2193 => .{ .chunk_radius = try r.readVarI32() },
    };
}

pub fn encode(comptime protocol: Protocol, w: *Writer, p: packet.Shape(protocol)) !void {
    switch (protocol) {
        .v2168, .v2169, .v2193 => try w.writeVarI32(p.chunk_radius),
    }
}
