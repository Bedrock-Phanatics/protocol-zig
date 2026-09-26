const std = @import("std");
const vectors = @import("vectors.zig");
const CountPrefix = @import("reader.zig").CountPrefix;
const nbt = @import("nbt.zig");
const DecodeLimits = @import("limits.zig").DecodeLimits;

/// Recursive values deeper than this are rejected on encode, so cyclic or
/// pathological caller data cannot exhaust the stack.
pub const max_encode_depth = DecodeLimits.max_supported_nesting_depth;

/// Writes into a caller-provided buffer and never past its end.
pub const Writer = Output(false);
/// Runs the same encoding operations to validate and measure a value without
/// touching any storage.
pub const CountingWriter = Output(true);

fn Output(comptime counting: bool) type {
    return struct {
        const Self = @This();
        const Error = error{NoSpaceLeft};

        buffer: []u8 = &.{},
        cursor: usize = 0,
        depth: usize = 0,

        pub fn init(buffer: []u8) Self {
            return .{ .buffer = buffer };
        }
        pub inline fn written(self: *const Self) []const u8 {
            return self.buffer[0..self.cursor];
        }
        pub inline fn remainingCapacity(self: *const Self) usize {
            return (if (counting) std.math.maxInt(usize) else self.buffer.len) - self.cursor;
        }

        pub fn writeRaw(self: *Self, bytes: []const u8) Error!void {
            if (bytes.len > self.remainingCapacity()) return error.NoSpaceLeft;
            if (!counting) @memcpy(self.buffer[self.cursor..][0..bytes.len], bytes);
            self.cursor += bytes.len;
        }
        pub inline fn writeU8(self: *Self, v: u8) Error!void {
            if (self.remainingCapacity() == 0) return error.NoSpaceLeft;
            if (!counting) self.buffer[self.cursor] = v;
            self.cursor += 1;
        }
        pub inline fn writeI8(self: *Self, v: i8) Error!void {
            try self.writeU8(@bitCast(v));
        }
        pub inline fn writeBool(self: *Self, v: bool) Error!void {
            try self.writeU8(@intFromBool(v));
        }

        fn writeInt(self: *Self, comptime T: type, v: T, endian: std.builtin.Endian) Error!void {
            if (@sizeOf(T) > self.remainingCapacity()) return error.NoSpaceLeft;
            if (!counting) std.mem.writeInt(T, self.buffer[self.cursor..][0..@sizeOf(T)], v, endian);
            self.cursor += @sizeOf(T);
        }
        pub inline fn writeU16(self: *Self, v: u16) Error!void {
            try self.writeInt(u16, v, .little);
        }
        pub inline fn writeI16(self: *Self, v: i16) Error!void {
            try self.writeInt(i16, v, .little);
        }
        pub inline fn writeU32(self: *Self, v: u32) Error!void {
            try self.writeInt(u32, v, .little);
        }
        pub inline fn writeI32(self: *Self, v: i32) Error!void {
            try self.writeInt(i32, v, .little);
        }
        pub inline fn writeU64(self: *Self, v: u64) Error!void {
            try self.writeInt(u64, v, .little);
        }
        pub inline fn writeI64(self: *Self, v: i64) Error!void {
            try self.writeInt(i64, v, .little);
        }
        pub inline fn writeU16Be(self: *Self, v: u16) Error!void {
            try self.writeInt(u16, v, .big);
        }
        pub inline fn writeI16Be(self: *Self, v: i16) Error!void {
            try self.writeInt(i16, v, .big);
        }
        pub inline fn writeU32Be(self: *Self, v: u32) Error!void {
            try self.writeInt(u32, v, .big);
        }
        pub inline fn writeI32Be(self: *Self, v: i32) Error!void {
            try self.writeInt(i32, v, .big);
        }
        pub inline fn writeU64Be(self: *Self, v: u64) Error!void {
            try self.writeInt(u64, v, .big);
        }
        pub inline fn writeI64Be(self: *Self, v: i64) Error!void {
            try self.writeInt(i64, v, .big);
        }
        pub inline fn writeF32(self: *Self, v: f32) Error!void {
            try self.writeU32(@bitCast(v));
        }
        pub inline fn writeF64(self: *Self, v: f64) Error!void {
            try self.writeU64(@bitCast(v));
        }

        pub fn writeVarU32(self: *Self, value: u32) Error!void {
            var v = value;
            while (v >= 0x80) : (v >>= 7) try self.writeU8(@as(u8, @truncate(v)) | 0x80);
            try self.writeU8(@truncate(v));
        }
        pub fn writeVarU64(self: *Self, value: u64) Error!void {
            var v = value;
            while (v >= 0x80) : (v >>= 7) try self.writeU8(@as(u8, @truncate(v)) | 0x80);
            try self.writeU8(@truncate(v));
        }
        /// Zigzag-encoded signed varint.
        pub inline fn writeVarI32(self: *Self, v: i32) Error!void {
            const bits: u32 = @bitCast(v);
            try self.writeVarU32((bits << 1) ^ @as(u32, @bitCast(v >> 31)));
        }
        /// Zigzag-encoded signed varint.
        pub inline fn writeVarI64(self: *Self, v: i64) Error!void {
            const bits: u64 = @bitCast(v);
            try self.writeVarU64((bits << 1) ^ @as(u64, @bitCast(v >> 63)));
        }

        /// Varint-prefixed text; rejects invalid UTF-8.
        pub fn writeString(self: *Self, v: []const u8) error{ NoSpaceLeft, InvalidValue }!void {
            if (!std.unicode.utf8ValidateSlice(v)) return error.InvalidValue;
            try self.writeByteArray(v);
        }
        /// Varint-prefixed bytes.
        pub fn writeByteArray(self: *Self, v: []const u8) error{ NoSpaceLeft, InvalidValue }!void {
            if (v.len > std.math.maxInt(u32)) return error.InvalidValue;
            try self.writeVarU32(@intCast(v.len));
            try self.writeRaw(v);
        }
        pub fn writeCount(self: *Self, comptime prefix: CountPrefix, count: usize) error{ NoSpaceLeft, InvalidValue }!void {
            if (count > std.math.maxInt(u32)) return error.InvalidValue;
            switch (prefix) {
                .var_u32 => try self.writeVarU32(@intCast(count)),
                .u32le => try self.writeU32(@intCast(count)),
            }
        }
        /// Writes a network NBT document after checking it is exactly one document.
        pub fn writeNbt(self: *Self, document: []const u8) error{ NoSpaceLeft, InvalidValue }!void {
            if (!nbt.isDocument(document)) return error.InvalidValue;
            try self.writeRaw(document);
        }

        /// Enters one level of a recursive value.
        pub fn enter(self: *Self) error{InvalidValue}!void {
            if (self.depth >= max_encode_depth) return error.InvalidValue;
            self.depth += 1;
        }
        pub fn leave(self: *Self) void {
            self.depth -= 1;
        }

        /// Bedrock sends a UUID as two little-endian u64 halves.
        pub fn writeUuid(self: *Self, v: [16]u8) Error!void {
            var wire: [16]u8 = undefined;
            for (0..8) |i| {
                wire[i] = v[7 - i];
                wire[i + 8] = v[15 - i];
            }
            try self.writeRaw(&wire);
        }
        pub fn writeVec2f(self: *Self, v: vectors.Vec2f) Error!void {
            try self.writeF32(v.x);
            try self.writeF32(v.y);
        }
        pub fn writeVec3f(self: *Self, v: vectors.Vec3f) Error!void {
            try self.writeF32(v.x);
            try self.writeF32(v.y);
            try self.writeF32(v.z);
        }
        pub fn writeBlockPosition(self: *Self, v: vectors.BlockPosition) Error!void {
            try self.writeVarI32(v.x);
            try self.writeVarI32(v.y);
            try self.writeVarI32(v.z);
        }
        pub fn writeChunkPosition(self: *Self, v: vectors.ChunkPosition) Error!void {
            try self.writeVarI32(v.x);
            try self.writeVarI32(v.z);
        }
        pub fn writeSubChunkPosition(self: *Self, v: vectors.SubChunkPosition) Error!void {
            try self.writeI32(v.x);
            try self.writeI32(v.y);
            try self.writeI32(v.z);
        }
    };
}
