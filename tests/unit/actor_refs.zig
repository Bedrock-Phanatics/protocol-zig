const std = @import("std");
const root = @import("bedrock_protocol");
const actor_refs = root.actor_refs;
const corpus_file = @import("build_options").corpus_file;

const Swap = struct {
    runtime_a: u64 = 7,
    runtime_b: u64 = 900,
    unique_a: i64 = -7,
    unique_b: i64 = 90_000,

    pub fn runtime(self: Swap, id: u64) u64 {
        return if (id == self.runtime_a) self.runtime_b else if (id == self.runtime_b) self.runtime_a else id;
    }
    pub fn unique(self: Swap, id: i64) i64 {
        return if (id == self.unique_a) self.unique_b else if (id == self.unique_b) self.unique_a else id;
    }
};

fn roundTrip(buffer: []u8, packet: root.typed.Packet) !root.typed.Envelope {
    var w = root.Writer.init(buffer);
    const header: root.packet.Header = .{ .packet_id = root.registry.packetId(root.typed.packetKind(packet)).?, .sender_subclient = 1, .target_subclient = 2 };
    try root.typed.encode(&w, .{ .header = header, .packet = packet });
    return root.typed.decode(w.written(), .{});
}

test "only packets that can name an actor need rewriting" {
    for ([_]root.PacketKind{ .start_game, .add_player, .add_actor, .remove_actor, .move_player, .player_action, .set_actor_data, .set_actor_link, .animate, .emote, .mob_effect, .take_item_actor, .interact, .inventory_transaction, .boss_event, .update_abilities, .command_request, .move_actor_delta, .container_open }) |kind| {
        try std.testing.expect(actor_refs.packets.contains(kind));
    }
    for ([_]root.PacketKind{ .text, .set_time, .level_chunk, .update_block, .sub_chunk, .play_status, .network_stack_latency, .set_health }) |kind| {
        try std.testing.expect(!actor_refs.packets.contains(kind));
    }
}

test "nested entity links swap only the side that matches" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [256]u8 = undefined;
    const link: root.types.EntityLink = .{ .target_a = -7, .target_b = 55, .type = .riding, .immediate = true, .passenger_initiated = false, .vehicle_angular_velocity = 1.5 };
    var decoded = try roundTrip(&buffer, .{ .set_actor_link = .{ .link = link } });
    try std.testing.expect(try actor_refs.rewrite(arena.allocator(), &decoded.packet, Swap{}));
    try std.testing.expectEqual(@as(i64, 90_000), decoded.packet.set_actor_link.link.target_a);
    try std.testing.expectEqual(@as(i64, 55), decoded.packet.set_actor_link.link.target_b);
    try std.testing.expectEqual(@as(u2, 1), decoded.header.sender_subclient);

    const links = [_]root.types.EntityLink{ link, .{ .target_a = 55, .target_b = 90_000, .type = .passenger, .immediate = false, .passenger_initiated = true, .vehicle_angular_velocity = 0 } };
    var add = try roundTrip(&buffer, .{ .add_actor = .{
        .target_actor_id = 3,
        .target_runtime_id = 7,
        .actor_type = "minecraft:pig",
        .position = .{ .x = 1, .y = 2, .z = 3 },
        .velocity = .{ .x = 0, .y = 0, .z = 0 },
        .rotation = .{ .x = 0, .y = 0 },
        .y_head_rotation = 0,
        .y_body_rotation = 0,
        .attributes_list = .empty,
        .actor_data = .empty,
        .synched_properties = .{ .int_entries_list = .empty, .float_entries_list = .empty },
        .actor_links = .init(&links),
    } });
    try std.testing.expect(add.packet.add_actor.actor_links.data == .wire);
    try std.testing.expect(try actor_refs.rewrite(arena.allocator(), &add.packet, Swap{}));
    var out: [256]u8 = undefined;
    var w = root.Writer.init(&out);
    try root.typed.encode(&w, add);
    const again = try root.typed.decode(w.written(), .{});
    const swapped = try again.packet.add_actor.actor_links.toOwnedSlice(arena.allocator());
    try std.testing.expectEqual(@as(i64, 3), again.packet.add_actor.target_actor_id);
    try std.testing.expectEqual(@as(u64, 900), again.packet.add_actor.target_runtime_id);
    try std.testing.expectEqual(@as(i64, 90_000), swapped[0].target_a);
    try std.testing.expectEqual(@as(i64, 55), swapped[1].target_a);
    try std.testing.expectEqual(@as(i64, -7), swapped[1].target_b);
}

test "other actors and absent references are left alone" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [128]u8 = undefined;
    var take = try roundTrip(&buffer, .{ .take_item_actor = .{ .item_runtime_id = 900, .actor_runtime_id = 7 } });
    try std.testing.expect(try actor_refs.rewrite(arena.allocator(), &take.packet, Swap{}));
    try std.testing.expectEqual(@as(u64, 7), take.packet.take_item_actor.item_runtime_id);
    try std.testing.expectEqual(@as(u64, 900), take.packet.take_item_actor.actor_runtime_id);

    var other = try roundTrip(&buffer, .{ .take_item_actor = .{ .item_runtime_id = 8, .actor_runtime_id = 9 } });
    try std.testing.expect(!try actor_refs.rewrite(arena.allocator(), &other.packet, Swap{}));

    var block = try roundTrip(&buffer, .{ .command_block_update = .{ .target = .{ .entity_command_target = 7 }, .command = "", .last_output = "", .name = "", .filtered_name = "", .track_output = false, .tick_delay = 0, .execute_on_first_tick = false } });
    try std.testing.expect(try actor_refs.rewrite(arena.allocator(), &block.packet, Swap{}));
    try std.testing.expectEqual(@as(u64, 900), block.packet.command_block_update.target.entity_command_target);
}

test "corpus packets swap and swap back byte for byte" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, corpus_file, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(text);
    const bytes = try gpa.alloc(u8, root.DecodeLimits.defaults.max_packet_bytes);
    defer gpa.free(bytes);
    const first = try gpa.alloc(u8, root.DecodeLimits.defaults.max_packet_bytes);
    defer gpa.free(first);
    const second = try gpa.alloc(u8, root.DecodeLimits.defaults.max_packet_bytes);
    defer gpa.free(second);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var changed: usize = 0;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        errdefer std.debug.print("corpus line: {s}\n", .{line[0..@min(line.len, 64)]});
        _ = arena.reset(.retain_capacity);
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next().?;
        _ = fields.next().?;
        const packet = try std.fmt.hexToBytes(bytes, fields.next().?);
        var decoded = try root.typed.decode(packet, .{});
        const kind = root.typed.packetKind(decoded.packet);

        const any = try actor_refs.rewrite(arena.allocator(), &decoded.packet, Shift{});
        if (!actor_refs.packets.contains(kind)) try std.testing.expect(!any);
        if (any) changed += 1;
        var w = root.Writer.init(first);
        try root.typed.encode(&w, decoded);
        var back = try root.typed.decode(w.written(), .{});
        _ = try actor_refs.rewrite(arena.allocator(), &back.packet, Shift{ .undo = true });
        var w2 = root.Writer.init(second);
        try root.typed.encode(&w2, back);
        try std.testing.expectEqualSlices(u8, packet, w2.written());
    }
    try std.testing.expect(changed != 0);
}

// Corpus ids are random, so shift them all
const Shift = struct {
    undo: bool = false,

    pub fn runtime(self: Shift, id: u64) u64 {
        return if (self.undo) id -% 1 else id +% 1;
    }
    pub fn unique(self: Shift, id: i64) i64 {
        return if (self.undo) id -% 1 else id +% 1;
    }
};
