const std = @import("std");

const Reader = @import("../codec/reader.zig").Reader;
const Writer = @import("../codec/writer.zig").Writer;
const packet = @import("../packets/move_player.zig");
const Protocol = @import("../protocol.zig").Protocol;

pub fn decode(comptime protocol: Protocol, r: *Reader) !packet.Shape(protocol) {
    switch (protocol) {
        .v2168, .v2169, .v2193 => {
            const rid = try r.readVarU64();
            const pos = try r.readVec3f();
            const rot = try r.readVec3f();
            const mode = std.enums.fromInt(packet.MoveMode, try r.readU8()) orelse return error.InvalidEnum;
            const ground = try r.readBool();
            const ridden = try r.readVarU64();
            const present = try r.readBool();
            if (present != (mode == .teleport)) return error.InvalidEnum;
            const teleport: ?packet.TeleportData = if (present) .{
                .cause = std.enums.fromInt(packet.TeleportCause, try r.readI32()) orelse return error.InvalidEnum,
                .source_entity_type = try r.readI32(),
            } else null;
            return .{
                .entity_runtime_id = rid,
                .position = pos,
                .rotation = rot,
                .mode = mode,
                .on_ground = ground,
                .ridden_entity_runtime_id = ridden,
                .teleport = teleport,
                .tick = try r.readVarU64(),
            };
        },
    }
}

pub fn encode(comptime protocol: Protocol, w: *Writer, v: packet.Shape(protocol)) !void {
    switch (protocol) {
        .v2168, .v2169, .v2193 => {
            if ((v.mode == .teleport) != (v.teleport != null)) return error.InvalidValue;
            try w.writeVarU64(v.entity_runtime_id);
            try w.writeVec3f(v.position);
            try w.writeVec3f(v.rotation);
            try w.writeU8(@intFromEnum(v.mode));
            try w.writeBool(v.on_ground);
            try w.writeVarU64(v.ridden_entity_runtime_id);
            try w.writeBool(v.teleport != null);
            if (v.teleport) |t| {
                try w.writeI32(@intFromEnum(t.cause));
                try w.writeI32(t.source_entity_type);
            }
            try w.writeVarU64(v.tick);
        },
    }
}
