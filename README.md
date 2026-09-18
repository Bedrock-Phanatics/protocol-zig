# zig-protocol

Allocation-free Zig 0.16.0 Minecraft: Bedrock Edition protocol foundations with multi-version support for protocol 2168 (1.26.40), 2169 (1.26.45), and 2193 (1.26.50), verified against the CloudburstMC bedrock-codec serializers.

## Multi-version architecture

`Protocol` is an explicit enum (`v2168`, `v2169`, `v2193`) with `latest` and `fromVersion`. Every typed packet declares versioned structs and exposes `Shape(protocol)`, so each protocol gets exactly the fields its wire format carries and nothing else. Codecs dispatch on the same `comptime` protocol with exhaustive switches, making struct/codec drift a compile-time error. The typed decoder and the `unknown.known` classification are protocol-aware: packet IDs registered in later protocols (351, 352 from v2193) are only "known" from that protocol onwards.

Canonical single-packet fixtures are decoded and re-encoded byte-identically on every supported protocol as a regression net against accidental wire drift between versions.

### Normalized payloads

Every versioned packet shape exposes `normalize()` returning the module's `Canonical` type, and the typed union exposes `packet.normalized()`. Consumers can decode with the session protocol and then handle version-free payloads:

```zig
const env = try bp.typed.decode(P, bytes, .{});
switch (env.packet.normalized()) {
    .disconnect => |p| kick(p.reason, p.message),
    .set_time => |p| applyTime(p.time),
    .unknown => |u| forward(u.packet_id, u.raw),
    else => {},
}
```

`normalize()` is a lossy read-side mapping: fields absent from the decoded protocol take defaults, and re-encoding always uses the session shape via `bp.typed.encode`. While no divergent wire format exists between supported protocols, `Canonical` aliases the base shape; divergence only requires rewriting the module's `Canonical` and its per-version `normalize()`.

## Safety and ownership

`Reader`, generic packet envelopes, strings, byte arrays, generated packet payloads, and NBT document slices borrow their input. They must not outlive or mutate the backing buffer. `Writer` and DEFLATE APIs use caller-provided storage. Core decode paths do not allocate or retain global mutable state, so codec instances require no locks and may be used concurrently when their buffers are independent.

Centralized `DecodeLimits` bound packets, batches, decompressed data, packet counts, strings, arrays, NBT bytes, and NBT nesting. Malformed values return errors; external-input validation does not rely on Debug-only checks.

## Coverage

- Canonical VarInt/VarLong and ZigZag, fixed little/big-endian integers, floats, booleans, UTF-8 strings, byte arrays, vectors, block positions, and Bedrock UUID byte order.
- Lossless packet envelope forwarding across the complete legal 10-bit packet-ID domain.
- Compile-time protocol ID catalog with per-protocol known-packet queries.
- Typed multi-version codecs for the handshake/control baseline: Login, PlayStatus, both handshakes, Disconnect, SetTime, RemoveActor, MovePlayer, SetHealth, SetCommandsEnabled, SetDifficulty, RequestChunkRadius, ChunkRadiusUpdated, NetworkStackLatency, NetworkSettings, and RequestNetworkSettings. Disconnect uses the v975+ varint skip flag.
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
