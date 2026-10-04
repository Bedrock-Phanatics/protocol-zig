const std = @import("std");
const root = @import("bedrock_protocol");
const v = root.version;

comptime {
    const kinds = @typeInfo(v.Kind).@"enum".field_names;
    if (kinds.len != 231) @compileError("protocol 2193 defines 231 packets");
    for (kinds) |kind| {
        const P = @field(v.packets, kind).Packet;
        if (!@hasDecl(P, "decode") or !@hasDecl(P, "encode")) @compileError(kind ++ " has no codec");
        const fields = @typeInfo(P).@"struct".field_names;
        if (fields.len == 1 and std.mem.eql(u8, fields[0], "payload")) @compileError(kind ++ " is an opaque payload");
    }
}

test "every generated packet codec is instantiated for both writers" {
    var storage: [64]u8 = undefined;
    inline for (@typeInfo(v.Kind).@"enum".field_values) |tag| {
        const kind: v.Kind = @fromBackingInt(@intCast(tag));
        var r = try root.Reader.init(&.{}, .{});
        if (v.decodePayload(&r, kind)) |value| {
            var w = root.Writer.init(&storage);
            try v.encodePayload(&w, value);
            var counter: root.CountingWriter = .{};
            try v.encodePayload(&counter, value);
        } else |_| {}
    }
}

test "empty packets decode from an empty payload" {
    for ([_]v.Kind{ .client_to_server_handshake, .server_settings_request, .refresh_entitlements, .client_bound_close_form, .client_bound_data_driven_ui_reload, .resource_packs_ready_for_validation }) |kind| {
        var r = try root.Reader.init(&.{}, .{});
        _ = try v.decodePayload(&r, kind);
        try r.finish();
    }
}
