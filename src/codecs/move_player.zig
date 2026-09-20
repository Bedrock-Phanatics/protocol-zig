const std = @import("std");
const Reader = @import("../codec/reader.zig").Reader;
const p = @import("../packets/move_player.zig");
pub fn decode(r: *Reader) !p.MovePlayerPacket {
    const rid = try r.readVarU64();
    const pos = try r.readVec3f();
    const rot = try r.readVec3f();
    const mode = (std.enums.fromInt(p.MoveMode, try r.readU8()) orelse return error.InvalidEnum);
    const ground = try r.readBool();
    const ridden = try r.readVarU64();
    const present = try r.readBool();
    if (present != (mode == .teleport)) return error.InvalidEnum;
    const teleport: ?p.TeleportData = if (present) .{ .cause = try r.readI32(), .source_entity_type = try r.readI32() } else null;
    return .{ .entity_runtime_id = rid, .position = pos, .rotation = rot, .mode = mode, .on_ground = ground, .ridden_entity_runtime_id = ridden, .teleport = teleport, .tick = try r.readVarU64() };
}
pub fn encode(w: anytype, v: p.MovePlayerPacket) !void {
    if ((v.mode == .teleport) != (v.teleport != null)) return error.InvalidValue;
    try w.writeVarU64(v.entity_runtime_id);
    try w.writeVec3f(v.position);
    try w.writeVec3f(v.rotation);
    try w.writeU8(@intFromEnum(v.mode));
    try w.writeBool(v.on_ground);
    try w.writeVarU64(v.ridden_entity_runtime_id);
    try w.writeBool(v.teleport != null);
    if (v.teleport) |t| {
        try w.writeI32(t.cause);
        try w.writeI32(t.source_entity_type);
    }
    try w.writeVarU64(v.tick);
}
