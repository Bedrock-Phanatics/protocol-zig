const std = @import("std");
const Reader = @import("../codec/reader.zig").Reader;
const Writer = @import("../codec/writer.zig").Writer;
const packet = @import("../packets/text.zig");
const Protocol = @import("../protocol.zig").Protocol;

fn category(text_type: packet.TextType) u8 {
    return switch (text_type) {
        .raw, .tip, .system, .whisper_json, .json, .announcement_json => 0,
        .chat, .whisper, .announcement => 1,
        .translation, .popup, .jukebox_popup => 2,
    };
}

pub fn decode(comptime protocol: Protocol, r: *Reader) !packet.Shape(protocol) {
    switch (protocol) {
        .v2168, .v2169, .v2193 => {
            const needs_translation = try r.readBool();
            const wire_category = try r.readU8();
            const text_type = std.enums.fromInt(packet.TextType, try r.readU8()) orelse return error.InvalidEnum;
            if (wire_category != category(text_type)) return error.InvalidEnum;

            var value: packet.Shape(protocol) = .{
                .text_type = text_type,
                .needs_translation = needs_translation,
                .message = "",
            };
            switch (category(text_type)) {
                0 => value.message = try r.readString(),
                1 => {
                    value.source_name = try r.readString();
                    value.message = try r.readString();
                },
                2 => {
                    value.message = try r.readString();
                    const count = try r.readCollectionLength();
                    if (count > 4) return error.LimitExceeded;
                    value.parameters_len = @intCast(count);
                    for (value.parameters_buf[0..count]) |*parameter| parameter.* = try r.readString();
                },
                else => unreachable,
            }
            value.xuid = try r.readString();
            value.platform_chat_id = try r.readString();
            value.filtered_message = if (try r.readBool()) try r.readString() else null;
            return value;
        },
    }
}

pub fn encode(comptime protocol: Protocol, w: *Writer, p: packet.Shape(protocol)) !void {
    switch (protocol) {
        .v2168, .v2169, .v2193 => {
            const cat = category(p.text_type);
            if (cat != 2 and p.parameters_len != 0) return error.InvalidValue;
            if (p.parameters_len > 4) return error.InvalidValue;

            try w.writeBool(p.needs_translation);
            try w.writeU8(cat);
            try w.writeU8(@intFromEnum(p.text_type));
            switch (cat) {
                0 => try w.writeString(p.message),
                1 => {
                    try w.writeString(p.source_name);
                    try w.writeString(p.message);
                },
                2 => {
                    try w.writeString(p.message);
                    try w.writeVarU32(p.parameters_len);
                    for (p.parameters_buf[0..p.parameters_len]) |parameter| try w.writeString(parameter);
                },
                else => unreachable,
            }
            try w.writeString(p.xuid);
            try w.writeString(p.platform_chat_id);
            try w.writeBool(p.filtered_message != null);
            if (p.filtered_message) |message| try w.writeString(message);
        },
    }
}
