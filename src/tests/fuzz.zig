const std = @import("std");
pub fn run(comptime p: type, iterations: usize) !void {
    const Mock = @import("mock_profile").Profile(p);
    var rng = std.Random.DefaultPrng.init(0x2193bed);
    var bytes: [256]u8 = undefined;
    var output: [512]u8 = undefined;
    const limits: p.DecodeLimits = .{ .max_packet_bytes = 256, .max_string_bytes = 128, .max_array_elements = 32, .max_nesting_depth = 8, .max_nbt_bytes = 256 };
    // Structured boundaries exercise nesting and counts that random bytes rarely reach.
    const nested = [_]u8{ 10, 0 } ** 10 ++ [_]u8{0} ** 10;
    var deep = try p.Reader.init(&nested, limits);
    if (p.nbt.readDocument(&deep)) |_| return error.AcceptedDeepNbt else |err| {
        if (err != error.LimitExceeded) return err;
    }
    const huge_count = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0x0f };
    const bad_info = [_]u8{ 6, 0, 0, 0, 0 } ++ [_]u8{0} ** 16 ++ [_]u8{0} ++ huge_count;
    const bad_stack = [_]u8{ 7, 0 } ++ huge_count;
    const bad_response = [_]u8{ 8, 1, 11 } ++ "downloading".* ++ huge_count;
    inline for (.{ bad_info, bad_stack, bad_response }) |fixture| {
        if (p.Current.decodeBorrowed(&fixture, limits)) |_| return error.AcceptedHugeCollection else |err| {
            if (err != error.LimitExceeded) return err;
        }
    }
    for (0..iterations) |i| {
        rng.random().bytes(&bytes);
        const length = rng.random().intRangeAtMost(usize, 0, bytes.len);
        const input = bytes[0..length];
        if (length > 0 and i % 2 == 0) bytes[0] = @intCast(i % 20);
        var r = try p.Reader.init(input, limits);
        _ = r.readVarU64() catch {};
        if (r.cursor > r.input.len) return error.CursorOutsideInput;
        r.cursor = 0;
        _ = p.nbt.readDocument(&r) catch {};
        if (r.cursor > r.input.len) return error.CursorOutsideInput;
        if (p.packet.decode(input, limits)) |raw| {
            var w = p.Writer.init(&output);
            try p.packet.encode(&w, raw);
            if (!std.mem.eql(u8, input, w.written())) return error.RawRoundTrip;
        } else |_| {}
        inline for (.{ p.Current, Mock }) |P| {
            if (P.decodeBorrowed(input, limits)) |value| {
                var w = p.Writer.init(&output);
                try P.encode(&w, value);
                const decoded = try P.decodeBorrowed(w.written(), limits);
                if (decoded.kind != value.kind) return error.SemanticRoundTrip;
                if (!std.mem.eql(u8, input, w.written())) return error.ProfileRoundTrip;
            } else |_| {}
        }
    }
}
