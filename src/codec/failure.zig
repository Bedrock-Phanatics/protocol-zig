//! The count or length bound that rejected the last packet on this thread, so callers can report which field broke it.

pub const Failure = struct {
    /// The schema field, such as `Emote.emote_id`, or the decode limit, such as `max_string_bytes`.
    field: []const u8,
    observed: u64,
    limit: u64,
};

pub threadlocal var last: ?Failure = null;

/// Records a schema bound and returns the error generated code rejects it with.
pub fn invalid(comptime field: []const u8, observed: usize, limit: u64) error{InvalidValue} {
    @branchHint(.cold);
    last = .{ .field = field, .observed = observed, .limit = limit };
    return error.InvalidValue;
}

/// Records a decode limit and returns the error the reader rejects it with.
pub fn limited(comptime field: []const u8, observed: usize, limit: usize) error{LimitExceeded} {
    @branchHint(.cold);
    last = .{ .field = field, .observed = observed, .limit = limit };
    return error.LimitExceeded;
}

/// Takes the failure the last rejected packet recorded, leaving none behind for the next one.
pub fn take() ?Failure {
    defer last = null;
    return last;
}
