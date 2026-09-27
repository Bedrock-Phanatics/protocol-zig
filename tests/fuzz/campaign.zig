//! Deterministic hostile-input campaign.
//!
//! Every input either fails with a DecodeError or decodes to a value that
//! re-encodes to exactly the same bytes, measures to the same size, decodes
//! the same through the profile, and whose lazily decoded lists all iterate
//! without error. Inputs are random bytes and mutations (truncation, bit
//! flips, byte edits, insertions, deletions and splices) of the corpus.
const std = @import("std");
const p = @import("bedrock_protocol");
const Mock = @import("mock_profile").Profile;

const max_input = 16 * 1024;

pub const Stats = struct { inputs: usize = 0, decoded: usize = 0 };

pub fn run(corpus: []const u8, iterations: usize) !Stats {
    var packets: [1024][]const u8 = undefined;
    var storage: [512 * 1024]u8 = undefined;
    const seeds = try loadCorpus(corpus, &packets, &storage);

    try structuredCases();

    var stats: Stats = .{};
    var rng = std.Random.DefaultPrng.init(0x2193bed);
    const random = rng.random();
    var input: [max_input]u8 = undefined;
    for (0..iterations) |i| {
        const len = if (i % 4 == 0 or seeds.len == 0)
            randomInput(random, &input)
        else
            mutate(random, &input, seeds[random.uintLessThan(usize, seeds.len)], seeds);
        stats.inputs += 1;
        if (try check(input[0..len])) stats.decoded += 1;
    }
    return stats;
}

/// Checks one input against every invariant; reports whether it decoded.
pub fn check(input: []const u8) !bool {
    var output: [max_input + 16]u8 = undefined;

    if (p.packet.decode(input, .{})) |raw| {
        var w = p.Writer.init(&output);
        try p.packet.encode(&w, raw);
        if (!std.mem.eql(u8, input, w.written())) return error.EnvelopeRoundTrip;
    } else |_| {}

    // Tight limits must fail cleanly as well.
    _ = p.typed.decode(input, .{ .max_string_bytes = 16, .max_array_elements = 4, .max_nesting_depth = 2, .max_nbt_bytes = 32 }) catch {};
    inline for (.{ p.Current, Mock }) |Profile| {
        if (Profile.decodeBorrowed(input, .{})) |value| {
            var w = p.Writer.init(&output);
            try Profile.encode(&w, value);
            if (!std.mem.eql(u8, input, w.written())) return error.ProfileRoundTrip;
        } else |_| {}
    }

    const decoded = p.typed.decode(input, .{}) catch return false;
    if (try p.typed.encodedSize(decoded) != input.len) return error.SizeMismatch;
    var w = p.Writer.init(&output);
    try p.typed.encode(&w, decoded);
    if (!std.mem.eql(u8, input, w.written())) return error.TypedRoundTrip;
    visit(decoded.packet) catch return error.LazyListFailed;
    return true;
}

/// Walks a decoded value, iterating every lazily decoded list. Decoding
/// validated these bytes, so iteration must never fail.
pub fn visit(value: anytype) p.DecodeError!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (comptime @hasDecl(T, "Element") and @hasDecl(T, "Iterator")) {
                var it = value.iterator();
                var count: usize = 0;
                while (try it.next()) |element| : (count += 1) try visit(element);
                if (count != value.len) return error.InvalidValue;
                return;
            }
            inline for (info.fields) |field| try visit(@field(value, field.name));
        },
        .@"union" => |info| if (info.tag_type != null) switch (value) {
            inline else => |payload| try visit(payload),
        },
        .optional => if (value) |payload| try visit(payload),
        .array => for (value) |element| try visit(element),
        else => {},
    }
}

fn loadCorpus(text: []const u8, packets: [][]const u8, storage: []u8) ![]const []const u8 {
    var count: usize = 0;
    var used: usize = 0;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        if (line[0] == '#' or count == packets.len) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next();
        _ = fields.next();
        const hex = fields.next() orelse return error.BadCorpus;
        if (used + hex.len / 2 > storage.len) break;
        packets[count] = try std.fmt.hexToBytes(storage[used..], hex);
        used += packets[count].len;
        count += 1;
    }
    return packets[0..count];
}

fn randomInput(random: std.Random, out: []u8) usize {
    const len = random.intRangeAtMost(usize, 0, 256);
    random.bytes(out[0..len]);
    // Bias the header toward real packet IDs.
    if (len > 0 and random.boolean()) out[0] = random.intRangeAtMost(u8, 1, 127);
    return len;
}

fn mutate(random: std.Random, out: []u8, seed: []const u8, seeds: []const []const u8) usize {
    var len = @min(seed.len, out.len);
    @memcpy(out[0..len], seed[0..len]);
    const edits = random.intRangeAtMost(usize, 1, 4);
    for (0..edits) |_| {
        if (len == 0) break;
        const at = random.uintLessThan(usize, len);
        switch (random.int(u3)) {
            0 => len = at + 1, // truncate
            1 => out[at] ^= @as(u8, 1) << random.int(u3), // flip a bit
            2 => out[at] = random.int(u8), // overwrite a byte
            3 => out[at] = ([_]u8{ 0x00, 0x01, 0x7f, 0x80, 0xff })[random.uintLessThan(usize, 5)],
            4 => if (len < out.len) { // insert a byte
                std.mem.copyBackwards(u8, out[at + 1 .. len + 1], out[at..len]);
                out[at] = random.int(u8);
                len += 1;
            },
            5 => { // delete a byte
                std.mem.copyForwards(u8, out[at .. len - 1], out[at + 1 .. len]);
                len -= 1;
            },
            6 => { // splice the tail of another packet
                const other = seeds[random.uintLessThan(usize, seeds.len)];
                const from = random.uintLessThan(usize, other.len);
                const n = @min(other.len - from, out.len - at);
                @memcpy(out[at..][0..n], other[from..][0..n]);
                len = at + n;
            },
            7 => { // an overlong varint run
                const n = @min(6, len - at);
                @memset(out[at..][0..n], 0xff);
            },
        }
    }
    return len;
}

/// Hand-built hostile shapes that random mutation rarely reaches.
fn structuredCases() !void {
    // Deeply nested NBT stops at the nesting limit.
    const nested = [_]u8{ 10, 0 } ** 80 ++ [_]u8{0} ** 80;
    var r = try p.Reader.init(&nested, .{});
    if (p.nbt.readDocument(&r)) |_| return error.AcceptedDeepNbt else |err| if (err != error.LimitExceeded) return err;

    // Counts far beyond the input fail without visiting every element.
    const huge_count = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0x0f };
    for ([_][]const u8{
        &([_]u8{ 7, 0 } ++ huge_count),
        &([_]u8{ 7, 0, 0xfe, 0xff, 0x3f }),
        &([_]u8{ 6, 0, 0, 0, 0 } ++ [_]u8{0} ** 16 ++ [_]u8{0} ++ huge_count),
    }) |input| {
        if (p.typed.decode(input, .{})) |_| return error.AcceptedHugeCollection else |_| {}
    }
}
