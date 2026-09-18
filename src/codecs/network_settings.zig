const std = @import("std");

const Reader = @import("../codec/reader.zig").Reader;
const Writer = @import("../codec/writer.zig").Writer;
const packet = @import("../packets/network_settings.zig");
const Protocol = @import("../protocol.zig").Protocol;

pub fn decode(comptime protocol: Protocol, r: *Reader) !packet.Shape(protocol) {
    switch (protocol) {
        .v2168, .v2169, .v2193 => {
            return .{
                .compression_threshold = try r.readU16(),
                .compression_algorithm = std.enums.fromInt(packet.CompressionAlgorithm, try r.readU16()) orelse return error.InvalidEnum,
                .client_throttle = try r.readBool(),
                .client_throttle_threshold = try r.readU8(),
                .client_throttle_scalar = try r.readF32(),
            };
        },
    }
}

pub fn encode(comptime protocol: Protocol, w: *Writer, p: packet.Shape(protocol)) !void {
    switch (protocol) {
        .v2168, .v2169, .v2193 => {
            try w.writeU16(p.compression_threshold);
            try w.writeU16(@intFromEnum(p.compression_algorithm));
            try w.writeBool(p.client_throttle);
            try w.writeU8(p.client_throttle_threshold);
            try w.writeF32(p.client_throttle_scalar);
        },
    }
}
