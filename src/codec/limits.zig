pub const DecodeLimits = struct {
    pub const max_supported_nesting_depth: usize = 128;
    /// Deprecated batch compatibility limits. Retained in valid() for API compatibility.
    max_batch_bytes: usize = 4 * 1024 * 1024,
    max_decompressed_batch_bytes: usize = 16 * 1024 * 1024,
    max_packets_per_batch: usize = 1024,
    max_packet_bytes: usize = 4 * 1024 * 1024,
    max_string_bytes: usize = 1024 * 1024,
    max_byte_array_bytes: usize = 8 * 1024 * 1024,
    max_array_elements: usize = 1_000_000,
    max_nbt_bytes: usize = 8 * 1024 * 1024,
    max_nesting_depth: usize = 64,
    pub const defaults: DecodeLimits = .{};
    pub fn valid(s: DecodeLimits) bool {
        return s.max_batch_bytes > 0 and s.max_decompressed_batch_bytes > 0 and
            s.max_packets_per_batch > 0 and s.max_packet_bytes > 0 and
            s.max_string_bytes > 0 and s.max_byte_array_bytes > 0 and
            s.max_array_elements > 0 and s.max_nbt_bytes > 0 and s.max_nesting_depth > 0 and
            s.max_nesting_depth <= max_supported_nesting_depth;
    }
};
