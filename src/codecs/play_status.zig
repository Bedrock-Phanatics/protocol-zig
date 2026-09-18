const std = @import("std");

const Reader = @import("../codec/reader.zig").Reader;
const Writer = @import("../codec/writer.zig").Writer;
const packet = @import("../packets/play_status.zig");
const Protocol = @import("../protocol.zig").Protocol;

pub fn decode(comptime protocol: Protocol, reader: *Reader) !packet.Shape(protocol) {
    switch (protocol) {
        .v2168, .v2169, .v2193 => {
            const raw = try reader.readI32Be();
            return .{ .status = std.enums.fromInt(packet.Status, raw) orelse return error.InvalidEnum };
        },
    }
}

pub fn encode(comptime protocol: Protocol, writer: *Writer, value: packet.Shape(protocol)) !void {
    switch (protocol) {
        .v2168, .v2169, .v2193 => try writer.writeI32Be(@intFromEnum(value.status)),
    }
}
