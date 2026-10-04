const registry = @import("registry/root.zig");
const typed = @import("registry/typed.zig");
const packet = @import("packet.zig");
const Reader = @import("codec/reader.zig").Reader;
const Writer = @import("codec/writer.zig").Writer;
const Counter = @import("codec/writer.zig").CountingWriter;
const Limits = @import("codec/limits.zig").DecodeLimits;
const DecodeError = @import("codec/errors.zig").DecodeError;
const EncodeError = @import("codec/errors.zig").EncodeError;
const version = @import("generated/root.zig");
const Kind = registry.PacketKind;
const PacketDirection = registry.PacketDirection;

pub const SessionFeatures = struct {
    uses_request_network_settings: bool = true,
    supports_deflate: bool = true,
    supports_snappy: bool = true,
    initial_algorithm: CompressionAlgorithm = .none,
    compression_mode: enum { absent, implicit, marked } = .marked,
    login_flow: enum { certificate_chain, oidc } = .oidc,
    resource_pack_flow: enum { classic, with_validation } = .with_validation,

    pub fn validate(self: SessionFeatures) error{UnsupportedProtocol}!void {
        if (self.compression_mode == .marked and !self.supports_deflate and !self.supports_snappy) return error.UnsupportedProtocol;
        if (self.compression_mode == .implicit and self.initial_algorithm == .none) return error.UnsupportedProtocol;
        if (self.compression_mode == .absent and self.initial_algorithm != .none) return error.UnsupportedProtocol;
        if (self.initial_algorithm == .deflate and !self.supports_deflate) return error.UnsupportedProtocol;
        if (self.initial_algorithm == .snappy and !self.supports_snappy) return error.UnsupportedProtocol;
    }
};
pub const CompressionAlgorithm = enum { none, deflate, snappy };
pub const BorrowedEnvelope = struct {
    header: packet.Header,
    kind: ?Kind,
    payload: []const u8,
    value: union(enum) {
        typed: typed.Packet,
        unknown,
    },
};
pub const Current = struct {
    pub const protocol_number: u32 = version.protocol_version;
    pub const minecraft_version = version.minecraft_version;
    pub const features: SessionFeatures = .{};
    pub const packetKind = registry.packetKind;
    pub const packetId = registry.packetId;
    pub const packetDirection = registry.packetDirection;
    pub fn decodeBorrowed(input: []const u8, limits: Limits) DecodeError!BorrowedEnvelope {
        const raw = try packet.decode(input, limits);
        const kind = packetKind(raw.header.packet_id) orelse
            return .{ .header = raw.header, .kind = null, .payload = raw.payload, .value = .unknown };
        var r = try Reader.init(raw.payload, limits);
        const value = try version.decodePayload(&r, kind);
        try r.finish();
        return .{ .header = raw.header, .kind = kind, .payload = raw.payload, .value = .{ .typed = value } };
    }
    pub fn encode(w: *Writer, e: BorrowedEnvelope) EncodeError!void {
        var counter: Counter = .{};
        try encodeTo(&counter, e);
        if (counter.cursor > w.remainingCapacity()) return error.NoSpaceLeft;
        try encodeTo(w, e);
    }
    fn encodeTo(w: anytype, e: BorrowedEnvelope) EncodeError!void {
        if (e.kind != packetKind(e.header.packet_id)) return error.InvalidValue;
        switch (e.value) {
            .typed => |value| if (e.kind != typed.packetKind(value)) return error.InvalidValue,
            .unknown => if (e.kind != null) return error.InvalidValue,
        }
        try w.writeVarU32(e.header.toWire());
        switch (e.value) {
            .typed => |value| try version.encodePayload(w, value),
            .unknown => try w.writeRaw(e.payload),
        }
    }
};
pub fn validateProfile(comptime P: type) void {
    const number: u32 = P.protocol_number;
    const features: SessionFeatures = P.features;
    comptime features.validate() catch @compileError("incompatible session features");
    checkFunction(@TypeOf(P.packetKind), fn (u10) ?Kind);
    checkFunction(@TypeOf(P.packetId), fn (Kind) ?u10);
    checkFunction(@TypeOf(P.packetDirection), fn (Kind) PacketDirection);
    checkFunction(@TypeOf(P.decodeBorrowed), fn ([]const u8, Limits) DecodeError!BorrowedEnvelope);
    checkFunction(@TypeOf(P.encode), fn (*Writer, BorrowedEnvelope) EncodeError!void);
    _ = .{ number, features };
}
fn checkFunction(comptime Actual: type, comptime Expected: type) void {
    const actual = @typeInfo(Actual).@"fn";
    const expected = @typeInfo(Expected).@"fn";
    if (actual.is_generic or actual.attrs.varargs or actual.return_type != expected.return_type or actual.param_types.len != expected.param_types.len) @compileError("incompatible profile function signature");
    for (actual.param_types, expected.param_types) |a, e| if (a != e) @compileError("incompatible profile function parameter");
}
