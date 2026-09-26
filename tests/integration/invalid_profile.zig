const p = @import("bedrock_protocol");
const Bad = struct {
    pub const protocol_number: u32 = 0;
    pub const features: p.SessionFeatures = .{};
    pub fn packetKind(_: u32) ?p.PacketKind {
        return null;
    }
    pub const packetId = p.Current.packetId;
    pub const decodeBorrowed = p.Current.decodeBorrowed;
    pub const encode = p.Current.encode;
};
comptime {
    p.validateProfile(Bad);
}
