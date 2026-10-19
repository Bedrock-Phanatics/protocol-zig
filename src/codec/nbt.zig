//! Bedrock network NBT stays borrowed bytes here. nbt-zig's scanner checks it in place,
//! so decoding still never allocates.

const std = @import("std");
const nbt = @import("nbt");
const Reader = @import("reader.zig").Reader;
const DecodeError = @import("errors.zig").DecodeError;
const DecodeLimits = @import("limits.zig").DecodeLimits;

pub const Tag = nbt.TagType;

const max_string_bytes = 32767;

/// A lone TAG_End is the one-byte encoding of an absent document. The cursor only
/// moves when the whole document is valid.
pub fn readDocument(r: *Reader) DecodeError![]const u8 {
    const start = r.cursor;
    const len = nbt.scanOptionalDocument(r.input[start..], options(r.limits)) catch |err| return decodeError(err);
    r.cursor += len;
    return r.input[start..r.cursor];
}

pub fn isDocument(bytes: []const u8) bool {
    var strict = options(DecodeLimits.revalidated);
    strict.reject_trailing_bytes = true;
    _ = nbt.scanOptionalDocument(bytes, strict) catch return false;
    return true;
}

/// Our depth counts levels below the root while nbt-zig counts the root as well.
/// Running past `max_nbt_bytes` is a limit, not a truncated document.
fn options(limits: DecodeLimits) nbt.Options {
    return .{
        .encoding = .bedrock_network,
        .max_depth = limits.max_nesting_depth + 1,
        .max_collection_length = limits.max_array_elements,
        .max_compound_entries = std.math.maxInt(usize),
        .max_string_bytes = @min(max_string_bytes, limits.max_string_bytes),
        .max_byte_array_length = limits.max_byte_array_bytes,
        .max_input_bytes = limits.max_nbt_bytes,
        .reject_noncanonical_varints = true,
    };
}

fn decodeError(err: nbt.ScanError) DecodeError {
    return switch (err) {
        error.UnexpectedEndOfInput => error.EndOfStream,
        error.SizeLimitExceeded, error.DepthLimitExceeded, error.InvalidOptions => error.LimitExceeded,
        error.VarIntOverflow => error.VarIntOverflow,
        error.NonCanonicalVarInt => error.NonCanonicalVarInt,
        error.InvalidUtf8 => error.InvalidUtf8,
        error.TrailingData => error.TrailingData,
        error.InvalidTag,
        error.InvalidRoot,
        error.InvalidLength,
        error.InvalidListType,
        error.InvalidModifiedUtf8,
        error.DuplicateName,
        error.TypeMismatch,
        => error.InvalidNbt,
    };
}
