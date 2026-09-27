const std = @import("std");
const DecodeLimits = @import("limits.zig").DecodeLimits;
const DecodeError = @import("errors.zig").DecodeError;
const vectors = @import("vectors.zig");
const nbt = @import("nbt.zig");

pub const CountPrefix = enum { var_u32, u32le };

pub const Reader = struct {
    input: []const u8,
    cursor: usize = 0,
    limits: DecodeLimits,
    depth: usize = 0,

    pub fn init(input: []const u8, limits: DecodeLimits) DecodeError!Reader {
        if (!limits.valid() or input.len > limits.max_packet_bytes) return error.LimitExceeded;
        return .{ .input = input, .limits = limits };
    }

    pub inline fn remaining(self: *const Reader) usize {
        return self.input.len - self.cursor;
    }

    pub inline fn end(self: *const Reader) bool {
        return self.cursor == self.input.len;
    }

    pub fn finish(self: *const Reader) DecodeError!void {
        if (!self.end()) return error.TrailingData;
    }

    pub fn take(self: *Reader, count: usize) DecodeError![]const u8 {
        if (count > self.remaining()) return error.EndOfStream;
        const start = self.cursor;
        self.cursor += count;
        return self.input[start..self.cursor];
    }

    pub inline fn readU8(self: *Reader) DecodeError!u8 {
        return (try self.take(1))[0];
    }
    pub inline fn readI8(self: *Reader) DecodeError!i8 {
        return @bitCast(try self.readU8());
    }
    pub fn readBool(self: *Reader) DecodeError!bool {
        return switch (try self.readU8()) {
            0 => false,
            1 => true,
            else => error.InvalidBoolean,
        };
    }

    fn readInt(self: *Reader, comptime T: type, endian: std.builtin.Endian) DecodeError!T {
        const bytes = try self.take(@sizeOf(T));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], endian);
    }
    pub inline fn readU16(self: *Reader) DecodeError!u16 {
        return self.readInt(u16, .little);
    }
    pub inline fn readI16(self: *Reader) DecodeError!i16 {
        return self.readInt(i16, .little);
    }
    pub inline fn readU32(self: *Reader) DecodeError!u32 {
        return self.readInt(u32, .little);
    }
    pub inline fn readI32(self: *Reader) DecodeError!i32 {
        return self.readInt(i32, .little);
    }
    pub inline fn readU64(self: *Reader) DecodeError!u64 {
        return self.readInt(u64, .little);
    }
    pub inline fn readI64(self: *Reader) DecodeError!i64 {
        return self.readInt(i64, .little);
    }
    pub inline fn readU16Be(self: *Reader) DecodeError!u16 {
        return self.readInt(u16, .big);
    }
    pub inline fn readI16Be(self: *Reader) DecodeError!i16 {
        return self.readInt(i16, .big);
    }
    pub inline fn readU32Be(self: *Reader) DecodeError!u32 {
        return self.readInt(u32, .big);
    }
    pub inline fn readI32Be(self: *Reader) DecodeError!i32 {
        return self.readInt(i32, .big);
    }
    pub inline fn readU64Be(self: *Reader) DecodeError!u64 {
        return self.readInt(u64, .big);
    }
    pub inline fn readI64Be(self: *Reader) DecodeError!i64 {
        return self.readInt(i64, .big);
    }
    pub inline fn readF32(self: *Reader) DecodeError!f32 {
        return @bitCast(try self.readU32());
    }
    pub inline fn readF64(self: *Reader) DecodeError!f64 {
        return @bitCast(try self.readU64());
    }

    pub fn readVarU32(self: *Reader) DecodeError!u32 {
        var value: u32 = 0;
        var index: u3 = 0;
        while (index < 5) : (index += 1) {
            const byte = try self.readU8();
            if (index == 4 and byte & 0xf0 != 0) return error.VarIntOverflow;
            value |= @as(u32, byte & 0x7f) << @as(u5, index) * 7;
            if (byte & 0x80 == 0) {
                if (index != 0 and byte == 0) return error.NonCanonicalVarInt;
                return value;
            }
        }
        return error.VarIntOverflow;
    }
    pub fn readVarU64(self: *Reader) DecodeError!u64 {
        var value: u64 = 0;
        var index: u4 = 0;
        while (index < 10) : (index += 1) {
            const byte = try self.readU8();
            if (index == 9 and byte & 0xfe != 0) return error.VarIntOverflow;
            value |= @as(u64, byte & 0x7f) << @as(u6, index) * 7;
            if (byte & 0x80 == 0) {
                if (index != 0 and byte == 0) return error.NonCanonicalVarInt;
                return value;
            }
        }
        return error.VarIntOverflow;
    }
    pub inline fn readVarI32(self: *Reader) DecodeError!i32 {
        const v = try self.readVarU32();
        return @bitCast((v >> 1) ^ (0 -% (v & 1)));
    }
    pub inline fn readVarI64(self: *Reader) DecodeError!i64 {
        const v = try self.readVarU64();
        return @bitCast((v >> 1) ^ (0 -% (v & 1)));
    }

    fn readLength(self: *Reader, maximum: usize) DecodeError!usize {
        const length: usize = try self.readVarU32();
        if (length > maximum) return error.LimitExceeded;
        return length;
    }
    pub fn readString(self: *Reader) DecodeError![]const u8 {
        const bytes = try self.take(try self.readLength(self.limits.max_string_bytes));
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        return bytes;
    }
    pub fn readByteArray(self: *Reader) DecodeError![]const u8 {
        return self.take(try self.readLength(self.limits.max_byte_array_bytes));
    }
    pub fn readCount(self: *Reader, comptime prefix: CountPrefix) DecodeError!usize {
        const count: usize = switch (prefix) {
            .var_u32 => try self.readVarU32(),
            .u32le => try self.readU32(),
        };
        if (count > self.limits.max_array_elements) return error.LimitExceeded;
        return count;
    }
    pub fn readNbt(self: *Reader) DecodeError![]const u8 {
        return nbt.readDocument(self);
    }

    pub fn enter(self: *Reader) DecodeError!void {
        if (self.depth >= self.limits.max_nesting_depth) return error.LimitExceeded;
        self.depth += 1;
    }
    pub fn leave(self: *Reader) void {
        self.depth -= 1;
    }

    /// Bedrock sends a UUID as two little-endian u64 halves.
    pub fn readUuid(self: *Reader) DecodeError![16]u8 {
        const src = try self.take(16);
        var out: [16]u8 = undefined;
        for (0..8) |i| {
            out[i] = src[7 - i];
            out[i + 8] = src[15 - i];
        }
        return out;
    }
    pub fn readVec2f(self: *Reader) DecodeError!vectors.Vec2f {
        return .{ .x = try self.readF32(), .y = try self.readF32() };
    }
    pub fn readVec3f(self: *Reader) DecodeError!vectors.Vec3f {
        return .{ .x = try self.readF32(), .y = try self.readF32(), .z = try self.readF32() };
    }
    pub fn readBlockPosition(self: *Reader) DecodeError!vectors.BlockPosition {
        return .{ .x = try self.readVarI32(), .y = try self.readVarI32(), .z = try self.readVarI32() };
    }
    pub fn readChunkPosition(self: *Reader) DecodeError!vectors.ChunkPosition {
        return .{ .x = try self.readVarI32(), .z = try self.readVarI32() };
    }
    pub fn readSubChunkPosition(self: *Reader) DecodeError!vectors.SubChunkPosition {
        return .{ .x = try self.readI32(), .y = try self.readI32(), .z = try self.readI32() };
    }
};
