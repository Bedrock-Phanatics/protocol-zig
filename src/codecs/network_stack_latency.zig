const Reader = @import("../codec/reader.zig").Reader;
const Writer = @import("../codec/writer.zig").Writer;
const packet = @import("../packets/network_stack_latency.zig");
const Protocol = @import("../protocol.zig").Protocol;

pub fn decode(comptime protocol: Protocol, r: *Reader) !packet.Shape(protocol) {
    return switch (protocol) {
        .v2168, .v2169, .v2193 => .{ .timestamp = try r.readI64(), .from_server = try r.readBool() },
    };
}

pub fn encode(comptime protocol: Protocol, w: *Writer, p: packet.Shape(protocol)) !void {
    switch (protocol) {
        .v2168, .v2169, .v2193 => {
            try w.writeI64(p.timestamp);
            try w.writeBool(p.from_server);
        },
    }
}
