const std = @import("std");

pub const DecodeLimits = struct {
    pub const max_supported_nesting_depth: usize = 128;

    max_packet_bytes: usize = 4 * 1024 * 1024,
    max_string_bytes: usize = 1024 * 1024,
    max_byte_array_bytes: usize = 8 * 1024 * 1024,
    max_array_elements: usize = 1_000_000,
    max_nbt_bytes: usize = 8 * 1024 * 1024,
    max_nesting_depth: usize = 64,

    pub const defaults: DecodeLimits = .{};

    /// Re-reads validated bytes. Limits only ever reject input, so relaxing
    /// them cannot change a parse.
    pub const revalidated: DecodeLimits = .{
        .max_packet_bytes = std.math.maxInt(usize),
        .max_string_bytes = std.math.maxInt(usize),
        .max_byte_array_bytes = std.math.maxInt(usize),
        .max_array_elements = std.math.maxInt(usize),
        .max_nbt_bytes = std.math.maxInt(usize),
        .max_nesting_depth = max_supported_nesting_depth,
    };

    pub fn valid(s: DecodeLimits) bool {
        return s.max_packet_bytes > 0 and s.max_string_bytes > 0 and s.max_byte_array_bytes > 0 and
            s.max_array_elements > 0 and s.max_nbt_bytes > 0 and s.max_nesting_depth > 0 and
            s.max_nesting_depth <= max_supported_nesting_depth;
    }
};
