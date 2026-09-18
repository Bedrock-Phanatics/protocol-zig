const std = @import("std");

const Reader = @import("../codec/reader.zig").Reader;
const Writer = @import("../codec/writer.zig").Writer;
const codecs = @import("../codecs/login.zig");
const Protocol = @import("../protocol.zig").Protocol;
const PacketId = @import("../registry/generated_packet_id.zig").PacketId;

pub const V2168 = struct {
    pub const id: PacketId = .login;
    protocol_version: i32,
    connection_request: []const u8,

    pub fn normalize(self: @This()) Canonical {
        return self;
    }
};

pub const V2169 = V2168;
pub const V2193 = V2168;

pub const Canonical = V2168;
pub const Current = V2193;

pub fn Shape(comptime protocol: Protocol) type {
    return switch (protocol) {
        .v2168 => V2168,
        .v2169 => V2169,
        .v2193 => V2193,
    };
}

test "login roundtrips on every supported protocol" {
    inline for (std.meta.fields(Protocol)) |field| {
        const protocol: Protocol = @enumFromInt(field.value);
        var buf: [64]u8 = undefined;
        var w = Writer.init(&buf);
        const original: Shape(protocol) = .{ .protocol_version = protocol.version(), .connection_request = "jwt" };
        try codecs.encode(protocol, &w, original);
        var r = try Reader.init(w.written(), .{});
        const decoded = try codecs.decode(protocol, &r);
        try std.testing.expectEqual(original.protocol_version, decoded.protocol_version);
        try std.testing.expectEqualStrings(original.connection_request, decoded.connection_request);
    }
}
