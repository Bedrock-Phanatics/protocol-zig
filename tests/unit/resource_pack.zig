const std = @import("std");
const root = @import("bedrock_protocol");
const packets = root.packets;

const info_fixture = [_]u8{ 6, 0, 0, 0, 0 } ++ [_]u8{0} ** 16 ++ [_]u8{ 0, 1 } ++ [_]u8{0} ** 16 ++ [_]u8{0} ++ [_]u8{0} ** 8 ++ [_]u8{ 0, 0, 0, 0, 0, 0, 0 };
const stack_fixture = [_]u8{ 7, 0, 1, 1, 'p', 1, 'v', 0, 0, 1, 0, 0, 0, 1, 'e', 1, 0, 0 };
const response_fixture = [_]u8{ 8, 1, 11 } ++ "downloading".* ++ [_]u8{ 1, 3, 'a', '_', '1' };

fn roundTrip(wire: []const u8) !root.typed.Envelope {
    const decoded = try root.typed.decode(wire, .{});
    var output: [128]u8 = undefined;
    var w = root.Writer.init(&output);
    try root.typed.encode(&w, decoded);
    try std.testing.expectEqualSlices(u8, wire, w.written());
    for (0..wire.len) |length| {
        if (root.typed.decode(wire[0..length], .{})) |_| return error.AcceptedTruncation else |_| {}
    }
    return decoded;
}

test "resource pack client response borrows pack names from the input" {
    const decoded = try roundTrip(&response_fixture);
    const downloading = decoded.packet.resource_pack_client_response.response.downloading;
    try std.testing.expectEqualSlices(u8, "downloading", downloading.response_type);
    var it = downloading.downloading_packs.iterator();
    const name = (try it.next()).?;
    try std.testing.expectEqualSlices(u8, "a_1", name);
    try std.testing.expect(name.ptr == response_fixture[response_fixture.len - 3 ..].ptr);
    try std.testing.expect((try it.next()) == null);

    var bad = response_fixture;
    bad[bad.len - 1] = 0xff;
    try std.testing.expectError(error.InvalidUtf8, root.typed.decode(&bad, .{}));
}

test "resource packs info and stack fixtures decode semantically" {
    const info = (try roundTrip(&info_fixture)).packet.resource_packs_info;
    try std.testing.expectEqual(@as(usize, 1), info.resource_packs.len);
    var packs = info.resource_packs.iterator();
    const pack = (try packs.next()).?;
    try std.testing.expectEqual(@as(u64, 0), pack.pack_size);
    try std.testing.expectEqualSlices(u8, "", pack.cdn_url);

    const stack = (try roundTrip(&stack_fixture)).packet.resource_pack_stack;
    var entries = stack.texture_pack_list.iterator();
    const entry = (try entries.next()).?;
    try std.testing.expectEqualSlices(u8, "p", entry.pack_id);
    try std.testing.expectEqualSlices(u8, "v", entry.version);
    try std.testing.expectEqual(@as(usize, 1), stack.experiments.toggles.len);
}

test "hostile collection counts are rejected before elements are visited" {
    var bytes: [64]u8 = undefined;
    var w = root.Writer.init(&bytes);
    try w.writeU8(7);
    try w.writeBool(false);
    try w.writeVarU32(1_000_001);
    try std.testing.expectError(error.LimitExceeded, root.typed.decode(w.written(), .{}));

    w = root.Writer.init(&bytes);
    try w.writeU8(8);
    try w.writeVarU32(1);
    try w.writeString("downloading");
    try w.writeVarU32(70_000);
    try std.testing.expectError(error.InvalidValue, root.typed.decode(w.written(), .{}));
    try std.testing.expectError(error.LimitExceeded, root.typed.decode(w.written(), .{ .max_array_elements = 100 }));
}

test "owned list copies unwind every allocation failure" {
    const decoded = try root.typed.decode(&stack_fixture, .{});
    const list = decoded.packet.resource_pack_stack.texture_pack_list;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, value: @TypeOf(list)) !void {
            const owned = try value.toOwnedSlice(allocator);
            defer allocator.free(owned);
            try std.testing.expectEqualSlices(u8, "p", owned[0].pack_id);
        }
    }.run, .{list});
}

test "caller-built lists encode their items and match decoded wire lists" {
    const packs = [_]packets.resource_pack_stack.StackResourcePack{.{ .pack_id = "p", .version = "v", .sub_pack_name = "" }};
    const toggles = [_]root.types.ExperimentData{.{ .name = "e", .enabled = true }};
    const envelope: root.typed.Envelope = .{ .header = .{ .packet_id = 7 }, .packet = .{ .resource_pack_stack = .{
        .texture_pack_required = false,
        .texture_pack_list = .init(&packs),
        .base_game_version = "",
        .experiments = .{ .toggles = .init(&toggles), .experiments_ever_toggled = false },
        .include_editor_packs = false,
    } } };
    var output: [64]u8 = undefined;
    var w = root.Writer.init(&output);
    try root.typed.encode(&w, envelope);
    try std.testing.expectEqualSlices(u8, &stack_fixture, w.written());
}
