const std = @import("std");

pub const Protocol = enum(i32) {
    v2168 = 2168,
    v2169 = 2169,
    v2193 = 2193,

    pub const latest: Protocol = .v2193;

    pub fn version(self: Protocol) i32 {
        return @intFromEnum(self);
    }

    pub fn minecraftVersion(self: Protocol) []const u8 {
        return switch (self) {
            .v2168 => "1.26.40",
            .v2169 => "1.26.45",
            .v2193 => "1.26.50",
        };
    }

    pub fn fromVersion(value: i32) ?Protocol {
        return std.enums.fromInt(Protocol, value);
    }
};

test "protocol enum values match wire protocol numbers" {
    try std.testing.expectEqual(@as(i32, 2168), Protocol.v2168.version());
    try std.testing.expectEqual(@as(i32, 2169), Protocol.v2169.version());
    try std.testing.expectEqual(@as(i32, 2193), Protocol.v2193.version());
}

test "fromVersion accepts known versions and rejects unknown ones" {
    try std.testing.expectEqual(Protocol.v2169, Protocol.fromVersion(2169).?);
    try std.testing.expect(Protocol.fromVersion(2192) == null);
    try std.testing.expect(Protocol.fromVersion(-1) == null);
}

test "minecraft version is defined per protocol" {
    try std.testing.expectEqualStrings("1.26.45", Protocol.v2169.minecraftVersion());
    try std.testing.expectEqualStrings("1.26.50", Protocol.latest.minecraftVersion());
}
