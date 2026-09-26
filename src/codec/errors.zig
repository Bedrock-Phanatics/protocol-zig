pub const DecodeError = error{
    /// The input ended inside a value.
    EndOfStream,
    VarIntOverflow,
    /// A varint used more bytes than its shortest form.
    NonCanonicalVarInt,
    InvalidBoolean,
    InvalidUtf8,
    /// A size or nesting depth exceeds the configured DecodeLimits.
    LimitExceeded,
    /// An unknown union tag or discriminant.
    InvalidEnum,
    InvalidPacketId,
    /// Bytes remained after a complete packet.
    TrailingData,
    /// A value violates a bound or invariant the protocol schema publishes.
    InvalidValue,
    InvalidNbt,
};

pub const EncodeError = error{
    /// The destination buffer is too small; nothing was written.
    NoSpaceLeft,
    /// A value violates a bound or invariant the protocol schema publishes.
    InvalidValue,
};
