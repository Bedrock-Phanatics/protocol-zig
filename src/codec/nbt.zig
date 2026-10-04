const std = @import("std");
const Reader = @import("reader.zig").Reader;
const DecodeError = @import("errors.zig").DecodeError;
const DecodeLimits = @import("limits.zig").DecodeLimits;

pub const Tag = enum(u8) {
    end = 0,
    byte = 1,
    short = 2,
    int = 3,
    long = 4,
    float = 5,
    double = 6,
    byte_array = 7,
    string = 8,
    list = 9,
    compound = 10,
    int_array = 11,
    long_array = 12,
};

const max_string_bytes = 32767;

/// A lone TAG_End is the one-byte encoding of an absent document.
pub fn readDocument(r: *Reader) DecodeError![]const u8 {
    const start = r.cursor;
    const original = r.input;
    const available = original.len - start;
    const allowed = @min(available, r.limits.max_nbt_bytes);
    r.input = original[0 .. start + allowed];
    defer r.input = original;

    readRoot(r) catch |err| {
        // Running out of the budget is a limit, not a truncated document.
        if (err == error.EndOfStream and allowed < available) return error.LimitExceeded;
        return err;
    };
    return r.input[start..r.cursor];
}

fn readRoot(r: *Reader) DecodeError!void {
    const tag = std.enums.fromInt(Tag, try r.readU8()) orelse return error.InvalidNbt;
    if (tag == .end) return;
    _ = try readString(r);
    try skipPayload(r, tag, 0);
}

pub fn isDocument(bytes: []const u8) bool {
    var r: Reader = .{ .input = bytes, .limits = DecodeLimits.revalidated };
    _ = readDocument(&r) catch return false;
    return r.end();
}

fn readString(r: *Reader) DecodeError![]const u8 {
    const len: usize = try r.readVarU32();
    if (len > max_string_bytes or len > r.limits.max_string_bytes) return error.LimitExceeded;
    const value = try r.take(len);
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
    return value;
}

fn readCount(r: *Reader) DecodeError!usize {
    const value = try r.readVarI32();
    if (value < 0) return error.InvalidNbt;
    const result: usize = @intCast(value);
    if (result > r.limits.max_array_elements) return error.LimitExceeded;
    return result;
}

fn skipPayload(r: *Reader, tag: Tag, depth: usize) DecodeError!void {
    if (depth > r.limits.max_nesting_depth) return error.LimitExceeded;
    switch (tag) {
        .end => return error.InvalidNbt,
        .byte => _ = try r.readI8(),
        .short => _ = try r.readI16(),
        .int => _ = try r.readVarI32(),
        .long => _ = try r.readVarI64(),
        .float => _ = try r.readF32(),
        .double => _ = try r.readF64(),
        .byte_array => {
            const n = try readCount(r);
            if (n > r.limits.max_byte_array_bytes) return error.LimitExceeded;
            _ = try r.take(n);
        },
        .string => _ = try readString(r),
        .list => {
            const child = std.enums.fromInt(Tag, try r.readU8()) orelse return error.InvalidNbt;
            const n = try readCount(r);
            if (child == .end and n != 0) return error.InvalidNbt;
            for (0..n) |_| try skipPayload(r, child, depth + 1);
        },
        .compound => while (true) {
            const child = std.enums.fromInt(Tag, try r.readU8()) orelse return error.InvalidNbt;
            if (child == .end) break;
            _ = try readString(r);
            try skipPayload(r, child, depth + 1);
        },
        .int_array => for (0..try readCount(r)) |_| {
            _ = try r.readVarI32();
        },
        .long_array => for (0..try readCount(r)) |_| {
            _ = try r.readVarI64();
        },
    }
}
