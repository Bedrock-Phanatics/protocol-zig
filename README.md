# zig-protocol

Allocation-free Zig 0.16.0 Minecraft: Bedrock Edition protocol
<p align="center">
    Join our <a href="https://discord.gg/Yv9qPRQNc3">Discord</a>!
</p>

## Safety and ownership

`Reader`, generic packet envelopes, strings, byte arrays, generated packet payloads, and NBT document slices borrow their input. They must not outlive or mutate the backing buffer. `Writer` and DEFLATE APIs use caller-provided storage. Core decode paths do not allocate or retain global mutable state, so codec instances require no locks and may be used concurrently when their buffers are independent.

Centralized `DecodeLimits` bound packets, batches, decompressed data, packet counts, strings, arrays, NBT bytes, and NBT nesting. Malformed values return errors; external-input validation does not rely on Debug-only checks.

## Coverage

- Canonical VarInt/VarLong and ZigZag, fixed little/big-endian integers, floats, booleans, UTF-8 strings, byte arrays, vectors, block positions, and Bedrock UUID byte order.
- Lossless packet envelope forwarding across the complete legal 10-bit packet-ID domain.
- Compile-time protocol-2192 ID catalog and 236 separately organized generated packet modules.
- Typed codecs for the handshake/control baseline: Login, PlayStatus, both handshakes, Disconnect, SetTime, RemoveActor, MovePlayer, SetHealth, SetCommandsEnabled, SetDifficulty, RequestChunkRadius, ChunkRadiusUpdated, NetworkStackLatency, NetworkSettings, and RequestNetworkSettings.
- Allocation-free Bedrock network-little-endian NBT structural validation.
- Allocation-free batch iteration and bounded raw-DEFLATE decompression using Zig's standard library.

Generated catalog modules not listed as typed codecs are borrowed opaque payload models. They support lossless forwarding but not semantic field access yet. Snappy, batch encryption, full NBT materialization/encoding, and semantic codecs for complex gameplay packets remain unsupported and must not be inferred from catalog presence.

## Commands

```console
zig fmt build.zig src benchmarks
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build bench -Doptimize=ReleaseFast
```

Tests include canonical fixtures, malformed inputs, limits, full packet-ID forwarding, deterministic hostile-input stress, and a native `std.testing.fuzz` target.
