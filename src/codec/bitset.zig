const std = @import("std");
const Reader = @import("reader.zig").Reader;
const DecodeError = @import("errors.zig").DecodeError;
const EncodeError = @import("errors.zig").EncodeError;

/// A fixed-width bitset sent as an unsigned little-endian base-128 integer.
pub fn Bitset(comptime bits: u16) type {
    return struct {
        const Self = @This();
        pub const len = bits;
        const Int = std.meta.Int(.unsigned, bits);
        const max_bytes = (bits + 6) / 7;
        const Wide = std.meta.Int(.unsigned, max_bytes * 7);

        value: Int = 0,

        pub fn isSet(self: Self, index: usize) bool {
            return index < bits and (self.value >> @intCast(index)) & 1 != 0;
        }
        pub fn set(self: *Self, index: std.math.Log2Int(Int), enabled: bool) void {
            const mask = @as(Int, 1) << index;
            self.value = if (enabled) self.value | mask else self.value & ~mask;
        }

        pub fn decode(r: *Reader) DecodeError!Self {
            var value: Wide = 0;
            for (0..max_bytes) |i| {
                const byte = try r.readU8();
                value |= @as(Wide, byte & 0x7f) << @intCast(i * 7);
                if (byte & 0x80 == 0) {
                    if (i != 0 and byte == 0) return error.NonCanonicalVarInt;
                    if (value >> bits != 0) return error.VarIntOverflow;
                    return .{ .value = @intCast(value) };
                }
            }
            return error.VarIntOverflow;
        }

        pub fn encode(self: Self, w: anytype) EncodeError!void {
            var value: Wide = self.value;
            while (value >= 0x80) : (value >>= 7) try w.writeU8(@as(u8, @truncate(value)) | 0x80);
            try w.writeU8(@truncate(value));
        }
    };
}
