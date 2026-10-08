# protocol-zig

Minecraft: Bedrock Edition packet codecs for Zig: every packet of protocol
**2193** (Minecraft **1.26.51**), decoded into typed fields and encoded back
byte for byte.

protocol-zig supports **one stable protocol at a time**. When a new stable
protocol ships, the library moves to it and the old one is dropped; there is
no multi-version support.

The version constants identify the pinned schema release. Mojang released
[26.52](https://feedback.minecraft.net/hc/en-us/articles/49175370527501-Minecraft-Bedrock-Edition-26-52-Hotfix-Changelog)
on September 25, 2026, but the current protocolgen manifest still targets
1.26.51. Compatibility with 26.52 has not been verified against a matching
manifest or vanilla packet capture.

- **Complete:** all 231 packets have generated codecs; none are opaque payloads.
- **Zero-copy:** decoding never allocates. Strings, byte arrays, NBT and lists
  borrow the input buffer.
- **Strict:** canonical varints and booleans only, schema bounds enforced,
  every length checked against `DecodeLimits` before use, trailing bytes rejected.
- **Exact:** anything that decodes re-encodes to identical bytes.
- **Checked against an independent implementation:** the generated codecs are
  compared byte for byte with [gophertunnel](https://github.com/Sandertv/gophertunnel)
  on every CI run.

This library only handles packet data. Sockets, RakNet/NetherNet, batching,
compression, encryption and login live in
[Bedwire](https://github.com/Bedrock-Phanatics/bedwire), which builds on it.

Requires **Zig 0.17.0**.

## Install

```sh
zig fetch --save git+https://github.com/Bedrock-Phanatics/protocol-zig
```

```zig
// build.zig
const protocol = b.dependency("bedrock_protocol", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("bedrock_protocol", protocol.module("bedrock_protocol"));
```

## Usage

A "packet" here is one decompressed, decrypted game packet: the header varint
followed by its payload.

### Decode

```zig
const protocol = @import("bedrock_protocol");

const envelope = try protocol.Current.decodeBorrowed(bytes, .{});
switch (envelope.value) {
    .typed => |packet| switch (packet) {
        .text => |text| switch (text.body) {
            .author_and_message => |chat| std.debug.print("{s}: {s}\n", .{ chat.player_name, chat.message }),
            else => {},
        },
        else => {},
    },
    .unknown => {}, // an ID this version does not define; envelope.payload holds the body
}
```

`protocol.typed.decode(bytes, limits)` is the same without unknown-ID
forwarding: unknown IDs return `error.InvalidPacketId`.

### Encode

```zig
var buffer: [256]u8 = undefined;
var writer = protocol.Writer.init(&buffer);
try protocol.typed.encode(&writer, .{
    .header = .{ .packet_id = protocol.registry.packetId(.set_time).? },
    .packet = .{ .set_time = .{ .time = 6000 } },
});
send(writer.written());
```

Encoding first validates the whole value and measures it; nothing is written
unless everything is valid and fits. A header ID that does not match the
packet is rejected. `protocol.CountingWriter` measures without writing.

To proxy a packet, decode it, inspect or change fields, and encode the
envelope again with `protocol.Current.encode`. Lists you did not touch are
copied without re-parsing.

### Lists

Lists are `protocol.List(T, _)` values. Decoded lists keep their validated
wire bytes, so iterating decodes elements on demand:

```zig
var it = stack.texture_pack_list.iterator();
while (try it.next()) |pack| use(pack.pack_id);
```

Build lists for encoding from a slice with `.init(&items)` (or `.empty`).
`toOwnedSlice(allocator)` copies a list into memory you own. The examples
above are compiled and run by `tests/unit/readme.zig`.

### Lifetimes

A decoded packet borrows its input buffer: every string, byte array, NBT
document and list points into it. Keep the buffer alive while you use the
packet, or copy the parts you need. Keep that buffer unchanged: lazy lists
re-read validated bytes, and encoding trusts those bytes. Nothing is freed
because nothing is allocated. `List.toOwnedSlice` owns only the element array;
strings, NBT and nested lists inside its elements still borrow the original
buffer. Free the array with the allocator you passed.

Encode into a destination that does not overlap any borrowed source slices.
Encoding retains no pointers after it returns. Zig does not track these
lifetimes; the consumer must keep the input alive and unchanged.

### Limits and errors

`protocol.DecodeLimits` bounds packet size, string and byte-array length,
element counts, NBT size and nesting depth (recursive values and NBT). The
defaults suit a server; pass tighter limits for untrusted peers. Counts are
checked before any element is read, and no list element can be zero bytes on
the wire, so decode time is linear in the input size.

Decoding returns a `protocol.DecodeError`: `EndOfStream`, `VarIntOverflow`,
`NonCanonicalVarInt`, `InvalidBoolean`, `InvalidUtf8`, `LimitExceeded`,
`InvalidEnum` (unknown union tag), `InvalidPacketId`, `TrailingData`,
`InvalidValue` (a schema bound or invariant), `InvalidNbt`. Encoding returns
`protocol.EncodeError`: `NoSpaceLeft` or `InvalidValue`.

Enums are open: values the schema does not name are kept, not rejected. The
exception is an enum that repeats a union tag (such as a Text message type),
which must match its tag.

## Packets and registry

| Namespace | Contents |
| --- | --- |
| `protocol.packets.<name>.Packet` | One struct per packet, plus its packet-specific types |
| `protocol.types` | Types shared between packets |
| `protocol.registry` | `packetKind(id)`, `packetId(kind)`, `packetDirection(kind)` |
| `protocol.version` | The generated codecs; `protocol.protocol_version` and `protocol.minecraft_version` name the release |

Directions are the union of every independent source that accepts a packet
from a side, so a packet any vanilla peer sends is never rejected.

### External Zig consumers

`Current.encodedSize(envelope)` validates and measures both typed and unknown
packets before you allocate a destination. `typed.encodedSize(envelope)` does
the same for typed envelopes. Both include the header and all sub-client bits.
After changing a typed field, encoding uses that field rather than the
envelope's original `payload`. Replace a list with `.init(items)` to change its
elements; decoded wire lists and their counts must remain unchanged.
`.init(items)` borrows the item slice and its nested data until encoding ends.

Adapters can be generated at comptime from `typed.Packet`, a `union(PacketKind)`.
For each name in `@typeInfo(typed.Packet).@"union".field_names`, use
`@FieldType(typed.Packet, name)` for the packet type, `@field(PacketKind, name)`
for its kind, and the registry functions for its ID and direction. Struct
`field_names` and `@FieldType` expose packet fields recursively. Lists expose
`Element` and `iterator()`; optional and tagged-union fields retain their Zig
types. No runtime metadata or second packet registry is needed.

Reflection exposes Zig value types, not wire semantics: strings, byte arrays
and NBT are all `[]const u8`, and an integer's type does not identify its wire
encoding. Keep any integration-specific conversion policy downstream.

The one exception is actor references. `protocol/schema/actor-refs.json`
classifies every 64-bit integer field as an actor runtime ID, an actor unique
ID or neither, and generation fails while any field is unclassified.
`protocol.actor_refs.packets` is the set of packets that can hold a reference
anywhere, including nested lists, optionals and unions.
`protocol.actor_refs.rewrite(arena, &packet, map)` passes each reference to
`map.runtime(u64) u64` or `map.unique(i64) i64` and reports whether anything
changed. Lists that hold references are copied into `arena`.

### Profiles

A profile is a type with `protocol_number`, `features`, `packetKind`,
`packetId`, `packetDirection`, `decodeBorrowed` and `encode`.
`protocol.Current` is the built-in one; `protocol.validateProfile(P)` checks a
custom profile at compile time. Bedwire sessions are parameterised by a
profile, so version selection stays outside this library.

## How the codecs are made

| Path | Contents |
| --- | --- |
| `src/packets/` | One file per packet (generated) |
| `src/types/`, `src/types.zig` | Shared protocol types (generated) |
| `src/version.zig` | Packet IDs, kinds, directions and the `Packet` union (generated) |
| `src/codec/` | Reader, writer, lists, NBT and other wire primitives |
| `src/custom/` | Hand-written codecs the schema cannot express |
| `src/registry/`, `src/profile.zig`, `src/packet.zig` | Typed decode/encode, profiles and packet framing |
| `src/actor_refs.zig` | Actor ID lookup and rewriting |

Generated files start with a "Do not edit" header and are rewritten by
`tools/codegen generate`; never edit them by hand.

1. **Schema.** [protocolgen](https://github.com/bedrock-mc/protocolgen)
   reconciles Mojang's protocol docs with a dump of the dedicated server
   (Endstone). Its manifest is pinned by revision and checksum.
2. **Reviewed decisions.** `protocol/schema/reconciliation.json` records
   every change made on top of it: packet names, directions, removed deprecated
   IDs, enum values tied to union tags, cross-field checks, one hand-written
   codec, and documented source conflicts. Each one cites evidence and stops
   ingest if the manifest it was written against changes.
3. **Canonical schema.** `tools/codegen ingest` produces
   `protocol/schema/bedrock.json`, which `tools/codegen generate` turns
   into Zig.

See [protocol/README.md](protocol/README.md) for moving to the next stable
release.

### Known conflicts

For these packets the independent implementations disagree with the schema,
and no vanilla capture has settled it yet. protocol-zig follows the schema
(Mojang's docs plus the server dump). The evidence is in
`tools/differential/accepted-divergences.json`:

- Event (65)
- StructureTemplateDataResponse (133)
- CameraInstruction spline type (300)
- ServerboundDiagnostics (315)
- PlayerVideoCapture action order (324)
- CameraSpline (338)
- ClientboundAttributeLayerSync (345)

Two narrower cases:

- **InventorySlot container IDs** follow the schema (a fixed byte), while
  other implementations read a varint. The two encodings only differ at 128
  and above.
- **Crafting ingredients** are the one place protocol-zig departs from the
  schema: its map form cannot express molang descriptors, so a hand-written
  codec reads them the way gophertunnel and CloudburstMC do.

## Development

| Command | What it does |
| --- | --- |
| `zig build test` | Unit tests, generated-codec checks, hostile-input tests and a corpus replay |
| `zig build fuzz -Dfuzz-iterations=N` | Deterministic mutation fuzzing of every packet |
| `zig build bench` | Decode, decode-and-walk and proxy-path benchmarks |
| `zig build check -Dtarget=...` | Compile everything for another target |
| `zig build test-bedwire -Dbedwire-path=...` | Run Bedwire sessions over this library |
| `go -C tools/differential run .` | Compare the corpus with gophertunnel |

`tests/corpus.txt` holds one schema-valid sample of every packet from
every side that may send it (`<sender> <id> <hex>` per line). CI also
generates a larger corpus on every run and compares it with gophertunnel and
the Zig codecs.

The Zig package ships only `src`, `build.zig`, `build.zig.zon`, `README.md`
and `LICENSE`. Tests, tools and the schema live in the repository.

## License

See [LICENSE](LICENSE).
