//! Crafting recipe ingredient (`cerealizer<RecipeIngredient>::SerializedData`).
//!
//! The protocol schema models the descriptor as a string-to-string map followed
//! by an aux value. That is byte-identical to this codec for empty, item-name
//! and item-tag descriptors; a molang descriptor instead carries an i16 version
//! and no aux value, as gophertunnel and CloudburstMC read it. See the
//! `custom_types` decision in protocol/schema/reconciliation-2193.json.
const std = @import("std");
const codec = @import("../codec/support.zig");
const Reader = codec.Reader;
const DecodeError = codec.DecodeError;
const EncodeError = codec.EncodeError;

pub const RecipeIngredient = struct {
    descriptor: Descriptor,
    /// Number of items consumed; 0 to 64.
    count: i32,

    pub const Descriptor = union(enum) {
        /// No item. `aux` is the schema's aux value, conventionally 32767.
        empty: struct { aux: i32 },
        item: struct { name: []const u8, aux: i32 },
        molang: struct { expression: []const u8, version: i16 },
        item_tag: struct { tag: []const u8, aux: i32 },
    };

    const names = .{ .item = "name", .molang = "molang", .item_tag = "item_tag" };

    fn checkAux(aux: i32) error{InvalidValue}!void {
        if (aux < 0 or aux > 32767) return error.InvalidValue;
    }

    pub fn decode(r: *Reader) DecodeError!RecipeIngredient {
        var value: RecipeIngredient = undefined;
        switch (try r.readVarU32()) {
            0 => value.descriptor = .{ .empty = .{ .aux = try r.readVarI32() } },
            1 => {
                const kind = try r.readString();
                if (std.mem.eql(u8, kind, names.item)) {
                    value.descriptor = .{ .item = .{ .name = try r.readString(), .aux = try r.readVarI32() } };
                } else if (std.mem.eql(u8, kind, names.molang)) {
                    value.descriptor = .{ .molang = .{ .expression = try r.readString(), .version = try r.readI16() } };
                } else if (std.mem.eql(u8, kind, names.item_tag)) {
                    value.descriptor = .{ .item_tag = .{ .tag = try r.readString(), .aux = try r.readVarI32() } };
                } else return error.InvalidEnum;
            },
            else => return error.InvalidEnum,
        }
        switch (value.descriptor) {
            .empty => |d| try checkAux(d.aux),
            .item => |d| try checkAux(d.aux),
            .item_tag => |d| try checkAux(d.aux),
            .molang => {},
        }
        value.count = try r.readVarI32();
        if (value.count < 0 or value.count > 64) return error.InvalidValue;
        return value;
    }

    pub fn encode(self: RecipeIngredient, w: anytype) EncodeError!void {
        if (self.count < 0 or self.count > 64) return error.InvalidValue;
        switch (self.descriptor) {
            .empty => |d| {
                try checkAux(d.aux);
                try w.writeVarU32(0);
                try w.writeVarI32(d.aux);
            },
            .item => |d| {
                try checkAux(d.aux);
                try w.writeVarU32(1);
                try w.writeString(names.item);
                try w.writeString(d.name);
                try w.writeVarI32(d.aux);
            },
            .molang => |d| {
                try w.writeVarU32(1);
                try w.writeString(names.molang);
                try w.writeString(d.expression);
                try w.writeI16(d.version);
            },
            .item_tag => |d| {
                try checkAux(d.aux);
                try w.writeVarU32(1);
                try w.writeString(names.item_tag);
                try w.writeString(d.tag);
                try w.writeVarI32(d.aux);
            },
        }
        try w.writeVarI32(self.count);
    }
};

test "recipe ingredient descriptors round trip and match the schema map bytes" {
    const Writer = @import("../codec/writer.zig").Writer;
    const cases = [_][]const u8{
        &.{ 0, 0xfe, 0xff, 0x03, 2 }, // empty, aux 32767, count 1
        &([_]u8{ 1, 4 } ++ "name".* ++ [_]u8{3} ++ "abc".* ++ [_]u8{ 0, 4 }), // {"name": "abc"}, aux 0, count 2
        &([_]u8{ 1, 8 } ++ "item_tag".* ++ [_]u8{ 1, 't', 0xfe, 0xff, 0x03, 0 }), // {"item_tag": "t"}, aux 32767, count 0
        &([_]u8{ 1, 6 } ++ "molang".* ++ [_]u8{ 1, 'q', 12, 0, 2 }),
    };
    for (cases) |bytes| {
        var r: Reader = .{ .input = bytes, .limits = .{} };
        const value = try RecipeIngredient.decode(&r);
        try r.finish();
        var out: [64]u8 = undefined;
        var w = Writer.init(&out);
        try value.encode(&w);
        try std.testing.expectEqualSlices(u8, bytes, w.written());
    }
    var unknown: Reader = .{ .input = &([_]u8{ 1, 3 } ++ "tag".* ++ [_]u8{ 0, 0 }), .limits = .{} };
    try std.testing.expectError(error.InvalidEnum, RecipeIngredient.decode(&unknown));
    var many: Reader = .{ .input = &.{ 2, 0 }, .limits = .{} };
    try std.testing.expectError(error.InvalidEnum, RecipeIngredient.decode(&many));
}
