// Test-only example. The injected namespace is the public protocol module.
pub fn Profile(comptime p: type) type {
    return struct {
        pub const protocol_number: u32 = 7;
        pub const features: p.SessionFeatures = .{};
        pub fn packetKind(id: u10) ?p.PacketKind {
            if (id == 1000) return .request_network_settings;
            if (id == 193) return null;
            return p.Current.packetKind(id);
        }
        pub fn packetId(kind: p.PacketKind) ?u10 {
            if (kind == .request_network_settings) return 1000;
            return p.Current.packetId(kind);
        }
        pub const packetDirection = p.Current.packetDirection;
        pub fn decodeBorrowed(input: []const u8, limits: p.DecodeLimits) p.DecodeError!p.BorrowedEnvelope {
            const raw = try p.packet.decode(input, limits);
            if (raw.header.packet_id == 193) return .{ .header = raw.header, .payload = raw.payload, .kind = null, .value = .unknown };
            if (raw.header.packet_id != 1000) return p.Current.decodeBorrowed(input, limits);
            var r = try p.Reader.init(raw.payload, limits);
            const number = try r.readI32();
            try r.finish();
            return .{ .header = raw.header, .kind = .request_network_settings, .payload = raw.payload, .value = .{ .typed = .{ .request_network_settings = .{ .client_protocol = number } } } };
        }
        pub fn encode(w: *p.Writer, e: p.BorrowedEnvelope) p.EncodeError!void {
            if (e.kind != packetKind(e.header.packet_id)) return error.InvalidValue;
            if (e.kind == .request_network_settings) {
                if (e.value != .typed or e.value.typed != .request_network_settings) return error.InvalidValue;
                if (w.remainingCapacity() < 6) return error.NoSpaceLeft;
                try w.writeVarU32(e.header.toWire());
                try w.writeI32(e.value.typed.request_network_settings.client_protocol);
            } else if (e.header.packet_id == 193) {
                if (e.value != .unknown) return error.InvalidValue;
                try p.packet.encode(w, .{ .header = e.header, .payload = e.payload });
            } else try p.Current.encode(w, e);
        }
    };
}
