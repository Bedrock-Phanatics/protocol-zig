const std = @import("std");
const p = @import("bedrock_protocol");
const campaign = @import("../fuzz/campaign.zig");
const corpus_file = @import("build_options").corpus_file;

const DynamicValue = p.packets.client_bound_data_store.DynamicValue;

/// A ClientboundDataStore packet whose single change carries `depth` nested lists.
fn nestedDataStore(buffer: []u8, depth: usize) ![]const u8 {
    var w = p.Writer.init(buffer);
    try w.writeVarU32(p.registry.packetId(.client_bound_data_store).?);
    try w.writeVarU32(1); // one update
    try w.writeVarU32(1); // a change
    try w.writeString("store");
    try w.writeString("property");
    try w.writeU32(0);
    for (0..depth) |_| {
        try w.writeI32(5); // DynamicValue.list
        try w.writeVarU32(1);
    }
    try w.writeI32(0); // DynamicValue.none
    return w.written();
}

test "recursive values stop at the nesting limit instead of the stack" {
    var buffer: [16 * 1024]u8 = undefined;
    const shallow = try nestedDataStore(&buffer, 60);
    const decoded = try p.typed.decode(shallow, .{});
    try campaign.visit(decoded.packet);
    for ([_]usize{ 65, 1000, 3000 }) |depth| {
        try std.testing.expectError(error.LimitExceeded, p.typed.decode(try nestedDataStore(&buffer, depth), .{}));
    }
    try std.testing.expectError(error.LimitExceeded, p.typed.decode(shallow, .{ .max_nesting_depth = 8 }));
}

test "encoding a value nested deeper than any decoder accepts fails without writing" {
    var values: [200]DynamicValue = undefined;
    values[0] = .none;
    for (1..values.len) |i| values[i] = .{ .list = .init(values[i - 1 .. i]) };
    const packet: p.typed.Envelope = .{ .header = .{ .packet_id = p.registry.packetId(.client_bound_data_store).? }, .packet = .{
        .client_bound_data_store = .{ .updates = .init(&.{.{ .change = .{
            .data_store_name = "",
            .property = "",
            .update_count = 0,
            .the_new_property_value = values[values.len - 1],
        } }}) },
    } };
    var output = @as([4096]u8, @splat(0xa5));
    var w = p.Writer.init(&output);
    try std.testing.expectError(error.InvalidValue, p.typed.encode(&w, packet));
    try std.testing.expectEqual(@as(usize, 0), w.cursor);
    for (output) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
}

test "every truncation and corrupted byte of every corpus packet fails cleanly" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, corpus_file, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(text);
    var bytes: [64 * 1024]u8 = undefined;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next();
        _ = fields.next();
        const packet = try std.fmt.hexToBytes(&bytes, fields.next().?);
        for (0..packet.len) |len| try std.testing.expectError(error.EndOfStream, p.typed.decode(packet[0..len], .{}));
        for (packet) |*byte| {
            const original = byte.*;
            defer byte.* = original;
            for ([_]u8{ original ^ 0x80, original ^ 0x01, 0xff }) |value| {
                byte.* = value;
                _ = try campaign.check(packet);
            }
        }
    }
}

test "hostile element counts fail before touching the elements" {
    var buffer: [64]u8 = undefined;
    var w = p.Writer.init(&buffer);
    try w.writeVarU32(p.registry.packetId(.resource_pack_stack).?);
    try w.writeBool(false);
    try w.writeVarU32(60_000); // within every bound, far beyond the input
    try std.testing.expectError(error.EndOfStream, p.typed.decode(w.written(), .{}));
    try std.testing.expectError(error.LimitExceeded, p.typed.decode(w.written(), .{ .max_array_elements = 10 }));
}

test "coverage-guided packet decoding" {
    try std.testing.fuzz({}, fuzzPacket, .{});
}

fn fuzzPacket(_: void, smith: *std.testing.Smith) !void {
    var bytes: [2048]u8 = undefined;
    smith.bytesWithHash(&bytes, 0x2193_bed0);
    const len: usize = smith.valueRangeAtMostWithHash(u16, 0, bytes.len, 0x0c0d_ec00);
    _ = try campaign.check(bytes[0..len]);
}

test "both item-stack request decoders enforce action bounds before reading actions" {
    var buffer: [512]u8 = undefined;
    const actions = @as([101]p.types.StackRequestAction, @splat(.{ .lab_table_combine = .screenlabtablecombine }));
    inline for (.{
        p.packets.item_stack_request.ItemStackRequestPacketData,
        p.packets.player_auth_input.ItemStackRequestData,
    }) |Request| {
        for ([_]usize{ 1, 60, 61, 100 }) |count| {
            const request: Request = .{
                .client_request_id = -7,
                .actions = .init(actions[0..count]),
                .strings_to_filter = .empty,
                .strings_to_filter_origin = .anviltext,
            };
            var w = p.Writer.init(&buffer);
            try request.encode(&w);
            var r = try p.Reader.init(w.written(), .{});
            const decoded = try Request.decode(&r);
            try r.finish();
            try std.testing.expectEqual(count, decoded.actions.len);
            try std.testing.expectEqual(request.client_request_id, decoded.client_request_id);
            var it = decoded.actions.iterator();
            for (0..count) |_| try std.testing.expectEqualDeep(actions[0], (try it.next()).?);
            try std.testing.expectEqual(null, try it.next());

            if (count > 1) {
                var limited = try p.Reader.init(w.written(), .{ .max_array_elements = count - 1 });
                try std.testing.expectError(error.LimitExceeded, Request.decode(&limited));
            }
        }
        for ([_]u32{ 0, 101, 100_000, std.math.maxInt(u32) }) |count| {
            var w = p.Writer.init(&buffer);
            try w.writeVarI32(-7);
            try w.writeVarU32(count);
            const prefix_len = w.cursor;
            try w.writeU8(0xff);
            var r = try p.Reader.init(w.written(), .{});
            const expected: p.DecodeError = if (count > p.DecodeLimits.defaults.max_array_elements) error.LimitExceeded else error.InvalidValue;
            try std.testing.expectError(expected, Request.decode(&r));
            try std.testing.expectEqual(prefix_len, r.cursor);
            const request: Request = .{
                .client_request_id = -7,
                .actions = .init(actions[0..if (count == 0) 0 else 101]),
                .strings_to_filter = .empty,
                .strings_to_filter_origin = .anviltext,
            };
            var output = p.Writer.init(&buffer);
            try std.testing.expectError(error.InvalidValue, request.encode(&output));
        }
        var r = try p.Reader.init(&.{ 0, 1 }, .{});
        try std.testing.expectError(error.EndOfStream, Request.decode(&r));
    }
}

test "legacy slot indices are bounded without copying or changing their order" {
    var buffer: [512]u8 = undefined;
    var slots: [257]u8 = undefined;
    for (&slots, 0..) |*slot, i| slot.* = @truncate(i);
    for ([_]usize{ 0, 1, 255, 256 }) |count| {
        const value: p.types.LegacySetSlot = .{ .container_enum = .inventorycontainer, .slots = slots[0..count] };
        var w = p.Writer.init(&buffer);
        try value.encode(&w);
        var r = try p.Reader.init(w.written(), .{});
        const decoded = try p.types.LegacySetSlot.decode(&r);
        try r.finish();
        try std.testing.expectEqualSlices(u8, value.slots, decoded.slots);
        try std.testing.expectEqual(buffer[r.cursor - count ..].ptr, decoded.slots.ptr);
        var limited = try p.Reader.init(w.written(), .{ .max_byte_array_bytes = 1 });
        if (count <= 1) {
            _ = try p.types.LegacySetSlot.decode(&limited);
        } else {
            try std.testing.expectError(error.LimitExceeded, p.types.LegacySetSlot.decode(&limited));
        }
    }
    for ([_]u32{ 257, 100_000, std.math.maxInt(u32) }) |count| {
        var w = p.Writer.init(&buffer);
        try w.writeU8(29);
        try w.writeVarU32(count);
        const prefix_len = w.cursor;
        var r = try p.Reader.init(w.written(), p.DecodeLimits.revalidated);
        try std.testing.expectError(error.InvalidValue, p.types.LegacySetSlot.decode(&r));
        try std.testing.expectEqual(prefix_len, r.cursor);
        try w.writeU8(0xff);
        r = try p.Reader.init(w.written(), p.DecodeLimits.revalidated);
        try std.testing.expectError(error.InvalidValue, p.types.LegacySetSlot.decode(&r));
        try std.testing.expectEqual(prefix_len, r.cursor);
    }
    const oversized: p.types.LegacySetSlot = .{ .container_enum = .inventorycontainer, .slots = &slots };
    var output = p.Writer.init(&buffer);
    try std.testing.expectError(error.InvalidValue, oversized.encode(&output));
    var truncated = try p.Reader.init(&.{ 29, 1 }, .{});
    try std.testing.expectError(error.EndOfStream, p.types.LegacySetSlot.decode(&truncated));
    var truncated_prefix = try p.Reader.init(&.{ 29, 0x80 }, .{});
    try std.testing.expectError(error.EndOfStream, p.types.LegacySetSlot.decode(&truncated_prefix));
    var overflow = try p.Reader.init(&.{ 29, 0xff, 0xff, 0xff, 0xff, 0x10 }, .{});
    try std.testing.expectError(error.VarIntOverflow, p.types.LegacySetSlot.decode(&overflow));
    var noncanonical = try p.Reader.init(&.{ 29, 0x80, 0 }, .{});
    try std.testing.expectError(error.NonCanonicalVarInt, p.types.LegacySetSlot.decode(&noncanonical));
    var duplicates = try p.Reader.init(&.{ 29, 3, 7, 7, 2 }, .{});
    try std.testing.expectEqualSlices(u8, &.{ 7, 7, 2 }, (try p.types.LegacySetSlot.decode(&duplicates)).slots);
}

test "inventory and movement reject oversized legacy slot lists at their prefixes" {
    var buffer: [512]u8 = undefined;
    for ([_]p.PacketKind{ .inventory_transaction, .player_auth_input }) |kind| {
        for ([_]u32{ 257, 100_000, std.math.maxInt(u32) }) |count| {
            var w = p.Writer.init(&buffer);
            try w.writeVarU32(p.Current.packetId(kind).?);
            if (kind == .player_auth_input) {
                try w.writeVec2f(.{ .x = 0, .y = 0 });
                try w.writeVec3f(.{ .x = 0, .y = 0, .z = 0 });
                try w.writeVec2f(.{ .x = 0, .y = 0 });
                try w.writeF32(0);
                try w.writeVarU32(0);
                try w.writeVarU32(0);
                try w.writeVarU32(0);
                try w.writeVarU32(0);
                try w.writeVec2f(.{ .x = 0, .y = 0 });
                try w.writeVarU64(1);
                try w.writeVec3f(.{ .x = 0, .y = 0, .z = 0 });
                try w.writeBool(true);
            }
            try w.writeVarI32(-7);
            try w.writeBool(true);
            try w.writeVarU32(1);
            try w.writeU8(29);
            try w.writeVarU32(count);
            try std.testing.expectError(error.InvalidValue, p.typed.decode(w.written(), p.DecodeLimits.revalidated));
            const prefix_len = w.cursor;
            try w.writeU8(0xff);
            var r = try p.Reader.init(w.written(), p.DecodeLimits.revalidated);
            _ = try r.readVarU32();
            if (kind == .inventory_transaction) {
                try std.testing.expectError(error.InvalidValue, p.packets.inventory_transaction.Packet.decode(&r));
            } else {
                try std.testing.expectError(error.InvalidValue, p.packets.player_auth_input.Packet.decode(&r));
            }
            try std.testing.expectEqual(prefix_len, r.cursor);
        }
    }
}

test "all inventory transaction action lists preserve boundaries and reject oversized encoding" {
    const Transaction = p.packets.inventory_transaction.InventoryTransactionTransaction;
    const item: p.types.NetworkItemStackDescriptor = .{ .id = 0, .stack_size = 0, .aux_value = 0, .net_id_variant = null, .block_runtime_id = 0, .user_data_buffer = &.{} };
    const zero: p.Vec3f = .{ .x = 0, .y = 0, .z = 0 };
    const action: p.types.InventoryAction = .{ .source = .{ .source_type = .container_inventory, .container_id = 2, .bit_flags = null }, .slot = 7, .from_item = item, .to_item = item };
    var actions = @as([101]p.types.InventoryAction, @splat(action));
    actions[0].slot = 255;
    var buffer: [8192]u8 = undefined;
    var output: [8192]u8 = undefined;
    for ([_]usize{ 0, 1, 50, 51, 99, 100, 101 }) |count| {
        const list = p.List(p.types.InventoryAction, p.types.InventoryAction).init(actions[0..count]);
        const transactions = [_]Transaction{
            .{ .normal_transaction_data = list },
            .{ .inventory_mismatch_data = list },
            .{ .item_use_inventory_transaction = .{
                .actions = list,
                .action_type = .place,
                .trigger_type = .player_input,
                .position = .{ .x = 1, .y = 2, .z = 3 },
                .face = 2,
                .slot = 7,
                .hand = .mainhand,
                .item = item,
                .from_position = zero,
                .click_position = zero,
                .target_block_id = 4,
                .client_interact_prediction = .success,
                .client_cooldown_state = .off,
            } },
            .{ .item_use_on_actor_inventory_transaction = .{
                .actions = list,
                .runtime_id = 123,
                .action_type = .attack,
                .slot = 7,
                .item = item,
                .from_position = zero,
                .hit_position = zero,
            } },
            .{ .item_release_inventory_transaction = .{
                .actions = list,
                .action_type = .release,
                .slot = 7,
                .item = item,
                .from_position = zero,
            } },
        };
        for (transactions) |transaction| {
            const envelope: p.typed.Envelope = .{
                .header = .{ .packet_id = p.Current.packetId(.inventory_transaction).?, .sender_subclient = 2, .target_subclient = 3 },
                .packet = .{ .inventory_transaction = .{ .legacy_request_id = -7, .legacy_set_item_slots = null, .transaction = transaction } },
            };
            var w = p.Writer.init(&buffer);
            if (count > 100) {
                @memset(&buffer, 0xa5);
                try std.testing.expectError(error.InvalidValue, p.typed.encode(&w, envelope));
                try std.testing.expectEqual(@as(usize, 0), w.cursor);
                for (buffer) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
                continue;
            }
            try p.typed.encode(&w, envelope);
            try std.testing.expectEqual(w.cursor, try p.typed.encodedSize(envelope));
            const decoded = try p.typed.decode(w.written(), .{});
            try std.testing.expectEqualDeep(envelope.header, decoded.header);
            try std.testing.expectEqual(@as(i32, -7), decoded.packet.inventory_transaction.legacy_request_id);
            const decoded_actions = switch (decoded.packet.inventory_transaction.transaction) {
                inline else => |value| if (comptime @hasField(@TypeOf(value), "actions")) value.actions else value,
            };
            try std.testing.expectEqual(count, decoded_actions.len);
            try std.testing.expectEqual(.wire, std.meta.activeTag(decoded_actions.data));
            var it = decoded_actions.iterator();
            for (actions[0..count]) |expected| try std.testing.expectEqualDeep(expected, (try it.next()).?);
            try std.testing.expectEqual(null, try it.next());
            var encoded = p.Writer.init(&output);
            try p.typed.encode(&encoded, decoded);
            try std.testing.expectEqualSlices(u8, w.written(), encoded.written());
            if (count > 1) try std.testing.expectError(error.LimitExceeded, p.typed.decode(w.written(), .{ .max_array_elements = count - 1 }));
            if (std.meta.activeTag(transaction) == .item_use_inventory_transaction) {
                const nested: p.packets.player_auth_input.PackedItemUseLegacyInventoryTransaction = .{
                    .legacy_request_id = -7,
                    .legacy_set_item_slots = null,
                    .item_use_transaction = transaction.item_use_inventory_transaction,
                };
                w.cursor = 0;
                try nested.encode(&w);
                var r = try p.Reader.init(w.written(), .{});
                const nested_decoded = try p.packets.player_auth_input.PackedItemUseLegacyInventoryTransaction.decode(&r);
                try r.finish();
                try std.testing.expectEqual(count, nested_decoded.item_use_transaction.actions.len);
                encoded.cursor = 0;
                try nested_decoded.encode(&encoded);
                try std.testing.expectEqualSlices(u8, w.written(), encoded.written());
            }
        }
    }
}

test "inventory variants and movement reject action counts before reading payloads" {
    var buffer: [256]u8 = undefined;
    for ([_]u32{ 101, 100_000, std.math.maxInt(u32) }) |count| {
        for ([_]p.DecodeLimits{ .defaults, .revalidated }) |limits| {
            const expected: p.DecodeError = if (count > limits.max_array_elements) error.LimitExceeded else error.InvalidValue;
            for (0..6) |path| {
                var w = p.Writer.init(&buffer);
                const kind: p.PacketKind = if (path == 5) .player_auth_input else .inventory_transaction;
                try w.writeVarU32(p.Current.packetId(kind).?);
                if (path == 5) {
                    try w.writeVec2f(.{ .x = 0, .y = 0 });
                    try w.writeVec3f(.{ .x = 0, .y = 0, .z = 0 });
                    try w.writeVec2f(.{ .x = 0, .y = 0 });
                    try w.writeF32(0);
                    try w.writeVarU32(0);
                    try w.writeVarU32(0);
                    try w.writeVarU32(0);
                    try w.writeVarU32(0);
                    try w.writeVec2f(.{ .x = 0, .y = 0 });
                    try w.writeVarU64(1);
                    try w.writeVec3f(.{ .x = 0, .y = 0, .z = 0 });
                    try w.writeBool(true);
                }
                try w.writeVarI32(-7);
                try w.writeBool(false);
                if (path != 5) try w.writeVarU32(@intCast(path));
                try w.writeVarU32(count);
                try std.testing.expectError(expected, p.typed.decode(w.written(), limits));
                const prefix_len = w.cursor;
                try w.writeU8(0xff);
                var r = try p.Reader.init(w.written(), limits);
                _ = try r.readVarU32();
                if (path == 5) {
                    try std.testing.expectError(expected, p.packets.player_auth_input.Packet.decode(&r));
                } else {
                    try std.testing.expectError(expected, p.packets.inventory_transaction.Packet.decode(&r));
                }
                try std.testing.expectEqual(prefix_len, r.cursor);
            }
        }
    }
    for (0..5) |tag| {
        var w = p.Writer.init(&buffer);
        try w.writeVarU32(@intCast(tag));
        try w.writeVarU32(1);
        var r = try p.Reader.init(w.written(), .{});
        try std.testing.expectError(error.EndOfStream, p.packets.inventory_transaction.InventoryTransactionTransaction.decode(&r));
        try w.writeU8(0x80);
        r = try p.Reader.init(w.written(), .{});
        try std.testing.expectError(error.EndOfStream, p.packets.inventory_transaction.InventoryTransactionTransaction.decode(&r));
    }
}
