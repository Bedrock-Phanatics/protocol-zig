//! Microbenchmarks: `zig build bench`.
//!
//! Packet cases replay one sample per packet from tests/corpus-2193.txt. Samples
//! are schema-valid but synthetic, so sizes differ from live traffic; use the
//! numbers to compare changes, not as absolute throughput. Decoding takes no
//! allocator, so every case performs zero heap allocations.
const std = @import("std");
const p = @import("bedrock_protocol");
const Mock = @import("mock_profile").Profile;
const options = @import("bench_options");

const budget_ns = 150 * std.time.ns_per_ms;

var io: std.Io = undefined;
var out: *std.Io.Writer = undefined;

pub fn main(init: std.process.Init) !void {
    io = init.io;
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    out = &stdout.interface;
    defer out.flush() catch {};

    const corpus = try std.Io.Dir.cwd().readFileAlloc(io, options.corpus_file, init.gpa, .limited(64 * 1024 * 1024));
    defer init.gpa.free(corpus);

    try out.print("{s:<44} {s:>10} {s:>10}\n", .{ "case", "ns/op", "MB/s" });
    try primitives();
    try packets(corpus);
}

/// Runs `op` repeatedly for the time budget and prints its cost.
fn measure(name: []const u8, bytes_per_op: usize, context: anytype, comptime op: fn (@TypeOf(context)) anyerror!void) !void {
    var iterations: u64 = 0;
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    var elapsed: i96 = 0;
    while (elapsed < budget_ns) {
        for (0..256) |_| try op(context);
        iterations += 256;
        elapsed = std.Io.Clock.awake.now(io).nanoseconds - start;
    }
    const ns = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
    const mbps = if (bytes_per_op == 0) 0 else @as(f64, @floatFromInt(bytes_per_op)) / ns * 1000.0;
    try out.print("{s:<44} {d:>10.1} {d:>10.0}\n", .{ name, ns, mbps });
}

fn primitives() !void {
    const Varint = struct {
        storage: [16]u8 = undefined,
        value: u64 = 0,
        fn roundTrip(self: *@This()) !void {
            var w = p.Writer.init(&self.storage);
            try w.writeVarU64(self.value);
            var r = try p.Reader.init(w.written(), .{});
            self.value +%= try r.readVarU64() | 1;
            std.mem.doNotOptimizeAway(self.value);
        }
    };
    var varint: Varint = .{};
    try measure("varint write+read", 0, &varint, Varint.roundTrip);

    const Lookup = struct {
        id: u10 = 0,
        fn kindAndId(self: *@This()) !void {
            self.id +%= 1;
            if (p.Current.packetKind(self.id)) |kind| std.mem.doNotOptimizeAway(p.Current.packetId(kind));
        }
    };
    var lookup: Lookup = .{};
    try measure("packet id -> kind -> id", 0, &lookup, Lookup.kindAndId);

    const Envelope = struct {
        input: []const u8,
        fn decode(self: *const @This()) !void {
            std.mem.doNotOptimizeAway((try p.packet.decode(self.input, .{})).payload.len);
        }
    };
    const raw = [_]u8{ 0xc1, 0x01 } ++ [_]u8{0} ** 64;
    try measure("header decode (raw forward)", raw.len, &Envelope{ .input = &raw }, Envelope.decode);

    const External = struct {
        input: []const u8,
        fn decode(self: *const @This()) !void {
            std.mem.doNotOptimizeAway((try Mock.decodeBorrowed(self.input, .{})).payload.len);
        }
    };
    try measure("external profile dispatch", 6, &External{ .input = &.{ 0xe8, 7, 0x91, 8, 0, 0 } }, External.decode);
}

const Case = struct {
    input: []const u8,
    output: []u8,

    fn decode(self: *const Case) !void {
        std.mem.doNotOptimizeAway(try p.typed.decode(self.input, .{}));
    }
    fn decodeAndWalk(self: *const Case) !void {
        const decoded = try p.typed.decode(self.input, .{});
        try walk(decoded.packet);
    }
    fn encode(self: *const Case) !void {
        const decoded = try p.typed.decode(self.input, .{});
        var w = p.Writer.init(self.output);
        try p.typed.encode(&w, decoded);
        std.mem.doNotOptimizeAway(w.cursor);
    }
};

/// Touches every lazily decoded list element, as a consumer inspecting the
/// whole packet would.
fn walk(value: anytype) p.DecodeError!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (comptime @hasDecl(T, "Element") and @hasDecl(T, "Iterator")) {
                var it = value.iterator();
                while (try it.next()) |element| try walk(element);
                return;
            }
            inline for (info.fields) |field| try walk(@field(value, field.name));
        },
        .@"union" => |info| if (info.tag_type != null) switch (value) {
            inline else => |payload| try walk(payload),
        },
        .optional => if (value) |payload| try walk(payload),
        .array => for (value) |element| try walk(element),
        else => std.mem.doNotOptimizeAway(value),
    }
}

const hot_packets = [_]p.PacketKind{
    .move_player,           .player_auth_input,  .text,                           .set_actor_data,
    .inventory_transaction, .item_stack_request, .item_stack_response,            .inventory_content,
    .level_chunk,           .sub_chunk,          .network_chunk_publisher_update, .add_actor,
    .available_commands,    .crafting_data,      .creative_content,               .start_game,
};

fn packets(corpus: []const u8) !void {
    var bytes: [64 * 1024]u8 = undefined;
    var output: [64 * 1024]u8 = undefined;
    for (hot_packets) |kind| {
        const input = findSample(corpus, kind, &bytes) orelse continue;
        const case: Case = .{ .input = input, .output = &output };
        var name: [64]u8 = undefined;
        try measure(try std.fmt.bufPrint(&name, "{s} decode ({d} B)", .{ @tagName(kind), input.len }), input.len, &case, Case.decode);
        try measure(try std.fmt.bufPrint(&name, "{s} decode + walk lists", .{@tagName(kind)}), input.len, &case, Case.decodeAndWalk);
        try measure(try std.fmt.bufPrint(&name, "{s} decode + encode (proxy)", .{@tagName(kind)}), input.len, &case, Case.encode);
    }
}

/// Returns the first corpus sample of `kind`, decoded into `storage`.
fn findSample(corpus: []const u8, kind: p.PacketKind, storage: []u8) ?[]const u8 {
    const id = p.Current.packetId(kind).?;
    var lines = std.mem.tokenizeAny(u8, corpus, "\r\n");
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next();
        const line_id = std.fmt.parseInt(u10, fields.next() orelse continue, 10) catch continue;
        if (line_id != id) continue;
        return std.fmt.hexToBytes(storage, fields.next() orelse return null) catch null;
    }
    return null;
}
