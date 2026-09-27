# protocol-zig

Minecraft: Bedrock Edition packet codecs for Zig: every packet of protocol
**2193** (Minecraft **1.26.50 / 1.26.51**), decoded into typed fields and
encoded back byte for byte.

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

Requires **Zig 0.16.0**.

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
packet, or copy the parts you need. Nothing is freed because nothing is
allocated.

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
| `protocol.v2193` | The version namespace everything above points at |

Directions are the union of every independent source that accepts a packet
from a side, so a packet any vanilla peer sends is never rejected.

### Profiles

A profile is a type with `protocol_number`, `features`, `packetKind`,
`packetId`, `packetDirection`, `decodeBorrowed` and `encode`.
`protocol.Current` is the built-in one; `protocol.validateProfile(P)` checks a
custom profile at compile time. Bedwire sessions are parameterised by a
profile, so version selection stays outside this library.

## How the codecs are made

`src/v2193` is generated. Nothing in it is edited by hand.

1. **Schema.** [protocolgen](https://github.com/bedrock-mc/protocolgen)
   reconciles Mojang's protocol docs with a dump of the dedicated server
   (Endstone). Its manifest is pinned by revision and checksum.
2. **Reviewed decisions.** `protocol/schema/reconciliation-2193.json` records
   every change made on top of it: packet names, directions, removed deprecated
   IDs, enum values tied to union tags, cross-field checks, one hand-written
   codec, and documented source conflicts. Each one cites evidence and stops
   ingest if the manifest it was written against changes.
3. **Canonical schema.** `tools/codegen ingest` produces
   `protocol/schema/bedrock-2193.json`, which `tools/codegen generate` turns
   into Zig.

See [protocol/README.md](protocol/README.md) for the update workflow and
`tools/codegen diff` for reviewing a new protocol version at the schema level.

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
| `zig build test --fuzz=N` | Coverage-guided fuzzing (Linux and macOS) |
| `zig build bench` | Decode, decode-and-walk and proxy-path benchmarks |
| `zig build check -Dtarget=...` | Compile everything for another target |
| `zig build test-bedwire -Dbedwire-path=...` | Run Bedwire sessions over this library |
| `go -C tools/differential run .` | Compare the corpus with gophertunnel |

`tests/corpus-2193.txt` holds one schema-valid sample of every packet from
every side that may send it (`<sender> <id> <hex>` per line). CI also
generates a larger corpus on every run and compares it with gophertunnel and
the Zig codecs.

## License

See [LICENSE](LICENSE).
