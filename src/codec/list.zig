const std = @import("std");
const Reader = @import("reader.zig").Reader;
const DecodeError = @import("errors.zig").DecodeError;
const EncodeError = @import("errors.zig").EncodeError;
const DecodeLimits = @import("limits.zig").DecodeLimits;

/// The `wire` form is produced only by `decode`; its bytes are trusted when
/// encoding, so never construct it by hand.
pub fn List(comptime T: type, comptime C: type) type {
    return struct {
        const Self = @This();

        len: usize = 0,
        data: Data = .{ .items = &.{} },

        pub const Element = T;
        pub const Data = union(enum) {
            items: []const T,
            wire: []const u8,
        };
        pub const empty: Self = .{};

        fn fixedSize() ?usize {
            return if (@hasDecl(C, "fixed_size")) C.fixed_size else null;
        }

        pub fn init(items: []const T) Self {
            return .{ .len = items.len, .data = .{ .items = items } };
        }

        pub fn decode(r: *Reader, count: usize) DecodeError!Self {
            const start = r.cursor;
            if (comptime fixedSize()) |size| {
                const bytes = std.math.mul(usize, count, size) catch return error.EndOfStream;
                _ = try r.take(bytes);
            } else for (0..count) |_| _ = try C.decode(r);
            return .{ .len = count, .data = .{ .wire = r.input[start..r.cursor] } };
        }

        pub fn encode(self: Self, w: anytype) EncodeError!void {
            switch (self.data) {
                .wire => |bytes| try w.writeRaw(bytes),
                .items => |items| for (items) |item| try C.encode(item, w),
            }
        }

        pub fn iterator(self: Self) Iterator {
            return switch (self.data) {
                .items => |items| .{ .items = items, .remaining = items.len, .reader = .{ .input = &.{}, .limits = DecodeLimits.revalidated } },
                .wire => |bytes| .{ .items = &.{}, .remaining = self.len, .reader = .{ .input = bytes, .limits = DecodeLimits.revalidated } },
            };
        }

        pub fn toOwnedSlice(self: Self, allocator: std.mem.Allocator) (DecodeError || std.mem.Allocator.Error)![]T {
            const out = try allocator.alloc(T, self.len);
            errdefer allocator.free(out);
            var it = self.iterator();
            for (out) |*item| item.* = (try it.next()) orelse return error.EndOfStream;
            return out;
        }

        pub const Iterator = struct {
            reader: Reader,
            items: []const T,
            remaining: usize,

            pub fn next(it: *Iterator) DecodeError!?T {
                if (it.remaining == 0) return null;
                it.remaining -= 1;
                if (it.items.len != 0) {
                    const item = it.items[0];
                    it.items = it.items[1..];
                    return item;
                }
                return try C.decode(&it.reader);
            }
        };
    };
}
