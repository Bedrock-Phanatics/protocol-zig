const std = @import("std");

const Reader = @import("../codec/reader.zig").Reader;
const Writer = @import("../codec/writer.zig").Writer;
const packet = @import("../packets/disconnect.zig");
const Protocol = @import("../protocol.zig").Protocol;

pub fn decode(comptime protocol: Protocol, r: *Reader) !packet.Shape(protocol) {
    switch (protocol) {
        .v2168, .v2169, .v2193 => {
            const reason = std.enums.fromInt(packet.Reason, try r.readVarI32()) orelse return error.InvalidEnum;
            const skipped = try r.readVarU32();
            if (skipped > 1) return error.InvalidBoolean;
            if (skipped == 1) return .{ .reason = reason, .message_skipped = true };
            return .{
                .reason = reason,
                .message_skipped = false,
                .message = try r.readString(),
                .filtered_message = try r.readString(),
            };
        },
    }
}

pub fn encode(comptime protocol: Protocol, w: *Writer, p: packet.Shape(protocol)) !void {
    switch (protocol) {
        .v2168, .v2169, .v2193 => {
            try w.writeVarI32(@intFromEnum(p.reason));
            try w.writeVarU32(if (p.message_skipped) 1 else 0);
            if (!p.message_skipped) {
                try w.writeString(p.message);
                try w.writeString(p.filtered_message);
            }
        },
    }
}
