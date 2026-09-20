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
        try stdout.print("{s} round-trip: {d:.2} ns/op, {d:.2} Mops/s (checksum={d})\n", .{ workload, latency, 1000.0 / latency, checksum });
    }
    const Mock = @import("mock_profile").Profile(protocol);
    inline for (.{ "varint-read", "varint-write", "header-decode", "header-encode", "kind-lookup", "id-lookup", "typed-decode", "typed-encode", "current-dispatch", "external-dispatch", "opaque-forward" }) |name| {
        var bytes: [64]u8 = undefined;
        var fixture = [_]u8{ 0xc1, 1, 0, 0, 8, 0x91 };
        var legacy = [_]u8{ 0xe8, 7, 0x91, 8, 0, 0 };
        const began = std.Io.Clock.awake.now(io).nanoseconds;
        for (0..iterations) |i| {
            var writer = protocol.Writer.init(&bytes);
            fixture[5] = @truncate(i);
            legacy[2] = @truncate(i);
            if (comptime std.mem.eql(u8, name, "varint-read")) {
                const input = [_]u8{ @as(u8, @truncate(i)) | 0x80, 1 };
                var r = try protocol.Reader.init(&input, .{});
                checksum +%= try r.readVarU32();
            } else if (comptime std.mem.eql(u8, name, "varint-write")) {
                try writer.writeVarU64(i);
                checksum +%= writer.cursor;
            } else if (comptime std.mem.eql(u8, name, "header-decode")) {
                const input = [_]u8{ @as(u8, @truncate(i)) | 0x80, @as(u8, @truncate(i >> 7)) & 0x7f };
                // Canonical two-byte headers have a nonzero terminal group.
                var canonical = input;
                canonical[1] |= 1;
                checksum +%= (try protocol.packet.decode(&canonical, .{})).header.toWire();
            } else if (comptime std.mem.eql(u8, name, "header-encode")) {
                try writer.writeVarU32((@as(protocol.packet.Header, .{ .packet_id = @truncate(i), .target_subclient = @truncate(i >> 10) })).toWire());
                checksum +%= writer.cursor;
            } else if (comptime std.mem.eql(u8, name, "kind-lookup")) {
                if (protocol.Current.packetKind(@truncate(i))) |kind| checksum +%= @intFromEnum(kind);
            } else if (comptime std.mem.eql(u8, name, "id-lookup")) {
                const kinds = std.enums.values(protocol.PacketKind);
                checksum +%= protocol.Current.packetId(kinds[i % kinds.len]).?;
            } else if (comptime std.mem.eql(u8, name, "typed-decode")) {
                checksum +%= @intCast((try protocol.typed.decode(&fixture, .{})).packet.request_network_settings.client_protocol);
            } else if (comptime std.mem.eql(u8, name, "typed-encode")) {
                try protocol.typed.encode(&writer, .{ .header = .{ .packet_id = 193 }, .packet = .{ .request_network_settings = .{ .client_protocol = @intCast(i) } } });
                checksum +%= writer.cursor;
            } else if (comptime std.mem.eql(u8, name, "current-dispatch")) {
                checksum +%= @intCast((try protocol.Current.decodeBorrowed(&fixture, .{})).value.typed.request_network_settings.client_protocol);
            } else if (comptime std.mem.eql(u8, name, "external-dispatch")) {
                checksum +%= @intCast((try Mock.decodeBorrowed(&legacy, .{})).value.typed.request_network_settings.client_protocol);
            } else {
                try protocol.packet.encode(&writer, .{ .header = .{ .packet_id = @truncate(i) }, .payload = "opaque payload" });
                checksum +%= writer.cursor;
            }
            std.mem.doNotOptimizeAway(writer.written());
        }
        const elapsed_work = std.Io.Clock.awake.now(io).nanoseconds - began;
        const latency = @as(f64, @floatFromInt(elapsed_work)) / @as(f64, @floatFromInt(iterations));
        try stdout.print("{s}: {d:.2} ns/op, {d:.2} Mops/s (checksum={d})\n", .{ name, latency, 1000.0 / latency, checksum });
    }
    try stdout.flush();
}
