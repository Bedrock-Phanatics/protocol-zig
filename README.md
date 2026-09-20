# protocol-zig

Allocation-free Zig 0.16.0 Minecraft: Bedrock Edition packet codecs and protocol foundations.

<p align="center">
    Join our <a href="https://discord.gg/Yv9qPRQNc3">Discord</a>!
</p>

The current catalog is protocol **2193 / Minecraft 1.26.50**, verified against [gophertunnel revision 7a556a0](https://github.com/Sandertv/gophertunnel/tree/7a556a07335b663744b50d38062636ad8283f314/minecraft/protocol).

`protocol-zig` supports the current protocol. External multiversion implementations own historical versions, translation, and profile selection.

## Current packets

```zig
const protocol = @import("bedrock_protocol");

const packet = try protocol.current.decodeBorrowed(bytes, .{});
if (packet.kind == .request_network_settings) {
    const version = packet.value.typed.request_network_settings.client_protocol;
    _ = version;
}

var writer = protocol.Writer.init(output);
try protocol.current.encode(&writer, packet);
```

`PacketKind` represents semantic identity. A `BorrowedEnvelope` preserves the header, optional semantic kind, raw payload, and a tagged `value`: `typed`, borrowed resource-pack control views, `known_opaque`, or `unknown`. Unknown and known-opaque packets are losslessly forwardable.

## External profiles

Profiles are namespace types specifying `protocol_number`, `features`, ID mappings, and `decodeBorrowed`/`encode` methods validated at compile time with `validateProfile(Profile)`.

```zig
pub fn packetKind(id: u10) ?protocol.PacketKind {
    return if (id == 1000) .request_network_settings else null;
}
pub fn packetId(kind: protocol.PacketKind) ?u10 {
    return if (kind == .request_network_settings) 1000 else null;
}
```

The executable [mock profile](src/tests/fixtures/mock_profile.zig) demonstrates external ID mapping, normalized re-encoding, and coexistence with the current profile.

## Ownership and memory

- **Borrowed views**: All borrowed slices and decoded string fields reference the input buffer. Input data must remain valid and immutable while accessing borrowed views. Encode destination buffers must not overlap borrowed source memory.
- **Typed & opaque codecs**: 16 scalar typed codecs cover core handshake and control packets. Unknown packets and catalog entries without typed codecs are handled as opaque payloads.
- **Allocating codecs**: Allocator-based codecs remain available under `codecs.resource_pack` when owned data is required.
- **Primitives & NBT**: Primitives support canonical VarInts, fixed-width integers, floats, booleans, UUIDs, and positions. An allocation-free NBT validator is included for wire validation.

## Ecosystem boundaries

- **Bedwire**: Handles 0xFE framing, batches, compression, encryption, authentication, and session orchestration.
- **nbt-zig**: Handles full NBT tree representation and serialization. `protocol-zig` provides lightweight wire validation only.
- **RakNet-Zig / NetherNet-Zig**: Handle lower-level transport protocols.

## Verification

```console
zig fmt --check build.zig build.zig.zon src benchmarks integration
zig build
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build fuzz -Dfuzz-iterations=100000
zig build bench
go test ./tools/ziggen2/main.go ./tools/ziggen2/main_test.go
go run ./tools/ziggen2/main.go --check
```
