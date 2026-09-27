const std = @import("std");
const Reader = @import("reader.zig").Reader;
const DecodeError = @import("errors.zig").DecodeError;
const EncodeError = @import("errors.zig").EncodeError;
const DecodeLimits = @import("limits.zig").DecodeLimits;

/// A protocol list. Decoding validates every element once and keeps the
/// validated wire bytes, so decoding never allocates and re-encoding a
/// decoded list is a single copy.
///
/// Build lists with `init` (or `empty`). The `wire` form is produced only by
/// `decode`; its bytes are trusted when encoding, so never construct it by
/// hand. Elements produced by `iterator` borrow the same input buffer as the
/// list and must not outlive it. Iterating re-parses elements, so walking
/// nested lists costs time proportional to input size times nesting depth.
pub fn List(comptime T: type, comptime C: type) type {
    return struct {
        const Self = @This();

        len: usize = 0,
        data: Data = .{ .items = &.{} },

        pub const Element = T;
        pub const Data = union(enum) {
            /// Caller-provided values.
            items: []const T,
            /// Validated element bytes, without the count prefix.
            wire: []const u8,
        };
        pub const empty: Self = .{};

        fn fixedSize() ?usize {
            return if (@hasDecl(C, "fixed_size")) C.fixed_size else null;
        }

        pub fn init(items: []const T) Self {
            return .{ .len = items.len, .data = .{ .items = items } };
        }

        /// Validates `count` elements and borrows their bytes from the reader input.
        pub fn decode(r: *Reader, count: usize) DecodeError!Self {
            const start = r.cursor;
            if (comptime fixedSize()) |size| {
                const bytes = std.math.mul(usize, count, size) catch return error.EndOfStream;
                _ = try r.take(bytes);
            } else for (0..count) |_| _ = try C.decode(r);
            return .{ .len = count, .data = .{ .wire = r.input[start..r.cursor] } };
        }

        /// Writes the elements; the caller writes the count prefix.
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

        /// Copies the element values into caller-owned memory. Nested slices
        /// in the elements still borrow the original input.
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

            /// Returns the next element. Errors are only possible for a list
            /// whose `wire` bytes were not produced by `decode`.
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
