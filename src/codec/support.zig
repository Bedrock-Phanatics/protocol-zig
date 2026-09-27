const std = @import("std");
pub const Reader = @import("reader.zig").Reader;
pub const DecodeError = @import("errors.zig").DecodeError;
pub const EncodeError = @import("errors.zig").EncodeError;
pub const List = @import("list.zig").List;
pub const Bitset = @import("bitset.zig").Bitset;
pub const patterns = @import("patterns.zig");
const vectors = @import("vectors.zig");
pub const Vec2f = vectors.Vec2f;
pub const Vec3f = vectors.Vec3f;
pub const BlockPosition = vectors.BlockPosition;
pub const ChunkPosition = vectors.ChunkPosition;
pub const SubChunkPosition = vectors.SubChunkPosition;

pub const PrimKind = enum {
    bool,
    u8,
    i8,
    u16le,
    i16le,
    u32le,
    i32le,
    u64le,
    i64le,
    u16be,
    i16be,
    u32be,
    i32be,
    u64be,
    i64be,
    f32le,
    f64le,
    var_u32,
    var_u64,
    zigzag_i32,
    zigzag_i64,
    uuid,
    nbt,
    string,
    bytes,
    vec2f,
    vec3f,
    blockPosition,
    chunkPosition,
    subChunkPosition,
};

fn primSpec(comptime kind: PrimKind) struct { type, []const u8 } {
    return switch (kind) {
        .bool => .{ bool, "Bool" },
        .u8 => .{ u8, "U8" },
        .i8 => .{ i8, "I8" },
        .u16le => .{ u16, "U16" },
        .i16le => .{ i16, "I16" },
        .u32le => .{ u32, "U32" },
        .i32le => .{ i32, "I32" },
        .u64le => .{ u64, "U64" },
        .i64le => .{ i64, "I64" },
        .u16be => .{ u16, "U16Be" },
        .i16be => .{ i16, "I16Be" },
        .u32be => .{ u32, "U32Be" },
        .i32be => .{ i32, "I32Be" },
        .u64be => .{ u64, "U64Be" },
        .i64be => .{ i64, "I64Be" },
        .f32le => .{ f32, "F32" },
        .f64le => .{ f64, "F64" },
        .var_u32 => .{ u32, "VarU32" },
        .var_u64 => .{ u64, "VarU64" },
        .zigzag_i32 => .{ i32, "VarI32" },
        .zigzag_i64 => .{ i64, "VarI64" },
        .uuid => .{ [16]u8, "Uuid" },
        .nbt => .{ []const u8, "Nbt" },
        .string => .{ []const u8, "String" },
        .bytes => .{ []const u8, "ByteArray" },
        .vec2f => .{ Vec2f, "Vec2f" },
        .vec3f => .{ Vec3f, "Vec3f" },
        .blockPosition => .{ BlockPosition, "BlockPosition" },
        .chunkPosition => .{ ChunkPosition, "ChunkPosition" },
        .subChunkPosition => .{ SubChunkPosition, "SubChunkPosition" },
    };
}

pub fn lengthIsProduct(len: usize, factors: anytype, scale: u64) bool {
    var product: u128 = scale;
    inline for (factors) |factor| {
        if (factor < 0) return false;
        const next = @mulWithOverflow(product, @as(u128, @intCast(factor)));
        if (next[1] != 0) return false;
        product = next[0];
    }
    return product == len;
}

pub fn Prim(comptime kind: PrimKind) type {
    const spec = primSpec(kind);
    return struct {
        /// Set only for kinds where every bit pattern is a valid value.
        pub const fixed_size: ?usize = switch (kind) {
            .u8, .i8, .u16le, .i16le, .u32le, .i32le, .u64le, .i64le => @sizeOf(spec[0]),
            .u16be, .i16be, .u32be, .i32be, .u64be, .i64be, .f32le, .f64le => @sizeOf(spec[0]),
            .uuid => 16,
            .vec2f => 8,
            .vec3f, .subChunkPosition => 12,
            else => null,
        };
        pub fn decode(r: *Reader) DecodeError!spec[0] {
            return @field(Reader, "read" ++ spec[1])(r);
        }
        pub fn encode(value: spec[0], w: anytype) EncodeError!void {
            return @field(std.meta.Child(@TypeOf(w)), "write" ++ spec[1])(w, value);
        }
    };
}
