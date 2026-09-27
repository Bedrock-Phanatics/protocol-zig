pub const DecodeError = error{
    EndOfStream,
    VarIntOverflow,
    NonCanonicalVarInt,
    InvalidBoolean,
    InvalidUtf8,
    LimitExceeded,
    InvalidEnum,
    InvalidPacketId,
    TrailingData,
    InvalidValue,
    InvalidNbt,
};

pub const EncodeError = error{
    NoSpaceLeft,
    InvalidValue,
};
