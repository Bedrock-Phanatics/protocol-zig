//! The examples from README.md, kept compiling and passing.
const std = @import("std");
const protocol = @import("bedrock_protocol");

test "README: encode a packet" {
    var buffer: [256]u8 = undefined;
    var writer = protocol.Writer.init(&buffer);
    try protocol.typed.encode(&writer, .{
        .header = .{ .packet_id = protocol.registry.packetId(.set_time).? },
        .packet = .{ .set_time = .{ .time = 6000 } },
    });
    try std.testing.expectEqualSlices(u8, &.{ 10, 0xe0, 0x5d }, writer.written());
}

test "README: decode and inspect a packet" {
    var buffer: [256]u8 = undefined;
    var writer = protocol.Writer.init(&buffer);
    try protocol.typed.encode(&writer, .{
        .header = .{ .packet_id = protocol.registry.packetId(.text).? },
        .packet = .{ .text = .{
            .localize = false,
            .body = .{ .author_and_message = .{ .message_type = .chat, .player_name = "Steve", .message = "hi" } },
            .senders_xuid = "",
            .platform_id = "",
            .filtered_message = null,
        } },
    });
    const bytes = writer.written();

    const envelope = try protocol.Current.decodeBorrowed(bytes, .{});
    var seen = false;
    switch (envelope.value) {
        .typed => |packet| switch (packet) {
            .text => |text| switch (text.body) {
                .author_and_message => |chat| {
                    try std.testing.expectEqualStrings("Steve", chat.player_name);
                    try std.testing.expectEqualStrings("hi", chat.message);
                    seen = true;
                },
                else => {},
            },
            else => {},
        },
        .unknown => {},
    }
    try std.testing.expect(seen);

    // Proxy: re-encode the decoded envelope unchanged.
    var out: [256]u8 = undefined;
    var w = protocol.Writer.init(&out);
    try protocol.Current.encode(&w, envelope);
    try std.testing.expectEqualSlices(u8, bytes, w.written());
}

test "README: lists" {
    const packs = [_]protocol.packets.resource_pack_stack.StackResourcePack{
        .{ .pack_id = "4a8f...", .version = "1.0.0", .sub_pack_name = "" },
    };
    const stack: protocol.packets.resource_pack_stack.Packet = .{
        .texture_pack_required = false,
        .texture_pack_list = .init(&packs),
        .base_game_version = "*",
        .experiments = .{ .toggles = .empty, .experiments_ever_toggled = false },
        .include_editor_packs = false,
    };
    var it = stack.texture_pack_list.iterator();
    while (try it.next()) |pack| try std.testing.expectEqualStrings("1.0.0", pack.version);
}
