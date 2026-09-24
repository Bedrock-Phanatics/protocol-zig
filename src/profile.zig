const registry = @import("registry/root.zig");
const typed = @import("registry/typed.zig");
const packet = @import("packet.zig");
const Reader = @import("codec/reader.zig").Reader;
const Writer = @import("codec/writer.zig").Writer;
const Counter = @import("codec/writer.zig").CountingWriter;
const Limits = @import("codec/limits.zig").DecodeLimits;
const DecodeError = @import("codec/errors.zig").DecodeError;
const EncodeError = @import("codec/errors.zig").EncodeError;
const packs = @import("codecs/resource_pack.zig");
const Kind = registry.PacketKind;
const PacketDirection = registry.PacketDirection;

/// Wire capabilities only. Session policy and version selection belong to callers.
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
/// All slices, including collection views and typed string fields, borrow the input.
pub const BorrowedEnvelope = struct {
    header: packet.Header,
    kind: ?Kind,
    payload: []const u8,
    value: union(enum) {
        typed: typed.Packet,
        resource_packs_info: packs.BorrowedInfo,
        resource_pack_stack: packs.BorrowedStack,
        resource_pack_client_response: packs.BorrowedResponse,
        known_opaque,
        unknown,
    },
};
pub const Current = struct {
    pub const protocol_number: u32 = 2193;
    pub const minecraft_version = "1.26.50";
    pub const features: SessionFeatures = .{};
    pub const packetKind = registry.packetKind;
    pub const packetId = registry.packetId;
    pub const packetDirection = registry.packetDirection;
    pub inline fn decodeBorrowed(input: []const u8, limits: Limits) DecodeError!BorrowedEnvelope {
        const raw = try packet.decode(input, limits);
        const kind = packetKind(raw.header.packet_id);
        var result: BorrowedEnvelope = .{ .header = raw.header, .kind = kind, .payload = raw.payload, .value = .unknown };
        const known = kind orelse return result;
        var r = try Reader.init(raw.payload, limits);
        switch (known) {
            .resource_packs_info => result.value = .{ .resource_packs_info = try packs.decodeInfoBorrowed(&r) },
            .resource_pack_stack => result.value = .{ .resource_pack_stack = try packs.decodeStackBorrowed(&r) },
            .resource_pack_client_response => result.value = .{ .resource_pack_client_response = try packs.decodeResponseBorrowed(&r) },
            else => {
                if (registry.hasCodec(known)) {
                    result.value = .{ .typed = try typed.decodePayload(&r, known) };
                    try r.finish();
                } else result.value = .known_opaque;
                return result;
            },
        }
        try r.finish();
        return result;
    }
    pub fn encode(w: *Writer, e: BorrowedEnvelope) EncodeError!void {
        var counter: Counter = .{};
        try encodeTo(&counter, e);
        if (counter.cursor > w.remainingCapacity()) return error.NoSpaceLeft;
        try encodeTo(w, e);
    }
    fn encodeTo(w: anytype, e: BorrowedEnvelope) EncodeError!void {
        if (e.kind != packetKind(e.header.packet_id)) return error.InvalidValue;
        const expected: ?Kind = switch (e.value) {
            .typed => |v| typed.packetKind(v),
            .resource_packs_info => .resource_packs_info,
            .resource_pack_stack => .resource_pack_stack,
            .resource_pack_client_response => .resource_pack_client_response,
            .known_opaque => blk: {
                const kind = e.kind orelse return error.InvalidValue;
                if (registry.coverage(kind) != .known_opaque) return error.InvalidValue;
                break :blk kind;
            },
            .unknown => null,
        };
        if (expected != e.kind) return error.InvalidValue;
        try w.writeVarU32(e.header.toWire());
        switch (e.value) {
            .typed => |v| try typed.encodePayload(w, v),
            .resource_packs_info => |v| try packs.encodeInfoBorrowed(w, v),
            .resource_pack_stack => |v| try packs.encodeStackBorrowed(w, v),
            .resource_pack_client_response => |v| try packs.encodeResponseBorrowed(w, v),
            .known_opaque, .unknown => try w.writeRaw(e.payload),
        }
    }
};
pub const current = Current;
/// A profile is a namespace type; selection and calls remain statically dispatched.
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
    if (actual.is_generic or actual.is_var_args or actual.return_type != expected.return_type or actual.params.len != expected.params.len) @compileError("incompatible profile function signature");
    for (actual.params, expected.params) |a, e| if (a.type != e.type) @compileError("incompatible profile function parameter");
}
