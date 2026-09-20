const std = @import("std");
const protocol = @import("bedrock_protocol");
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var output: [256]u8 = undefined;
    var file = std.Io.File.stdout().writer(io, &output);
    const stdout = &file.interface;
    var storage: [10]u8 = undefined;
    var checksum: u64 = 0;
    const iterations: u64 = 5_000_000;
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |i| {
        var w = protocol.Writer.init(&storage);
        try w.writeVarU64(i);
        var r = try protocol.Reader.init(w.written(), .{});
        checksum +%= try r.readVarU64();
    }
    const elapsed = std.Io.Clock.awake.now(io).nanoseconds - start;
    const ns = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
    try stdout.print("varint round-trip: {d:.2} ns/op, {d:.2} Mops/s (checksum={d})\n", .{ ns, 1000.0 / ns, checksum });
    inline for (.{ "header", "typed", "opaque" }) |workload| {
        var buffer: [64]u8 = undefined;
        const began = std.Io.Clock.awake.now(io).nanoseconds;
        for (0..iterations) |i| {
            var writer = protocol.Writer.init(&buffer);
            if (comptime std.mem.eql(u8, workload, "header")) {
                const header: protocol.packet.Header = .{ .packet_id = @truncate(i), .sender_subclient = @truncate(i >> 10) };
                try writer.writeVarU32(header.toWire());
                const decoded = try protocol.packet.decode(writer.written(), .{});
                checksum +%= decoded.header.toWire();
            } else if (comptime std.mem.eql(u8, workload, "typed")) {
                try protocol.typed.encode(&writer, .{ .header = .{ .packet_id = 193 }, .packet = .{ .request_network_settings = .{ .client_protocol = @intCast(i) } } });
                const decoded = try protocol.typed.decode(writer.written(), .{});
                checksum +%= @intCast(decoded.packet.request_network_settings.client_protocol);
            } else {
                try protocol.packet.encode(&writer, .{ .header = .{ .packet_id = @truncate(i) }, .payload = "opaque payload" });
                const decoded = try protocol.packet.decode(writer.written(), .{});
                checksum +%= decoded.header.packet_id + decoded.payload.len;
            }
            std.mem.doNotOptimizeAway(writer.written());
        }
        const duration = std.Io.Clock.awake.now(io).nanoseconds - began;
        const latency = @as(f64, @floatFromInt(duration)) / @as(f64, @floatFromInt(iterations));
        try stdout.print("{s} round-trip: {d:.2} ns/op, {d:.2} Mops/s (checksum={d})\n", .{workload, latency, 1000.0 / latency, checksum});
    }
    try stdout.flush();
}
