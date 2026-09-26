//! Matchers for the regular expressions the protocol schema publishes. The
//! generator refuses any pattern without a reviewed matcher here.
const std = @import("std");

/// `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpeg$`
pub fn uuidJpeg(value: []const u8) bool {
    const suffix = ".jpeg";
    if (value.len != 36 + suffix.len or !std.mem.endsWith(u8, value, suffix)) return false;
    for (value[0..36], 0..) |c, i| {
        const dash = i == 8 or i == 13 or i == 18 or i == 23;
        if (dash != (c == '-')) return false;
        if (!dash and !(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// `^\w+:\w+$` with ASCII word characters.
pub fn namespacedWord(value: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, value, ':') orelse return false;
    if (colon == 0 or colon + 1 == value.len) return false;
    for (value[0..colon]) |c| if (!isWord(c)) return false;
    for (value[colon + 1 ..]) |c| if (!isWord(c)) return false;
    return true;
}

/// `^(?:catmullrom|linear)$`
pub fn splineType(value: []const u8) bool {
    return std.mem.eql(u8, value, "catmullrom") or std.mem.eql(u8, value, "linear");
}

test "patterns match exactly their regular expressions" {
    try std.testing.expect(uuidJpeg("0123abcd-0123-4567-89ab-cdef01234567.jpeg"));
    try std.testing.expect(!uuidJpeg("0123ABCD-0123-4567-89ab-cdef01234567.jpeg"));
    try std.testing.expect(!uuidJpeg("0123abcd-0123-4567-89ab-cdef01234567.jpg"));
    try std.testing.expect(!uuidJpeg("0123abcd00123-4567-89ab-cdef01234567.jpeg"));
    try std.testing.expect(namespacedWord("minecraft:free_1"));
    try std.testing.expect(!namespacedWord("minecraft:"));
    try std.testing.expect(!namespacedWord(":x"));
    try std.testing.expect(!namespacedWord("a:b:c"));
    try std.testing.expect(!namespacedWord("a-b:c"));
    try std.testing.expect(splineType("linear") and splineType("catmullrom"));
    try std.testing.expect(!splineType("Linear") and !splineType("linear "));
}
