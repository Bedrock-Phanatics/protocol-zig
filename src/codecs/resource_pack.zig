const std = @import("std");
const Reader = @import("../codec/reader.zig").Reader;
const p = @import("../packets/resource_pack.zig");

fn readCount(r: *Reader) !usize {
    return r.readCollectionLength();
}
fn writeCount(w: anytype, count: usize) !void {
    if (count > std.math.maxInt(u32)) return error.InvalidValue;
    try w.writeVarU32(@intCast(count));
}
fn readFixedCount(r: *Reader) !usize {
    const count: usize = try r.readU32();
    if (count > r.limits.max_array_elements) return error.LimitExceeded;
    return count;
}
fn writeFixedCount(w: anytype, count: usize) !void {
    if (count > std.math.maxInt(u32)) return error.InvalidValue;
    try w.writeU32(@intCast(count));
}
fn validateAllocation(comptime T: type, r: *Reader, count: usize, minimum_wire_bytes: usize) !void {
    if (count > r.limits.max_packet_bytes / @sizeOf(T)) return error.LimitExceeded;
    if (minimum_wire_bytes != 0 and count > r.remaining() / minimum_wire_bytes) return error.EndOfStream;
}

fn decodeTexturePackInfo(r: *Reader) !p.TexturePackInfo {
    return .{
        .uuid = try r.readUuid(),
        .version = try r.readString(),
        .size = try r.readU64(),
        .content_key = try r.readString(),
        .sub_pack_name = try r.readString(),
        .content_identity = try r.readString(),
        .has_scripts = try r.readBool(),
        .addon_pack = try r.readBool(),
        .rtx_enabled = try r.readBool(),
        .download_url = try r.readString(),
    };
}
fn encodeTexturePackInfo(w: anytype, value: p.TexturePackInfo) !void {
    try w.writeUuid(value.uuid);
    try w.writeString(value.version);
    try w.writeU64(value.size);
    try w.writeString(value.content_key);
    try w.writeString(value.sub_pack_name);
    try w.writeString(value.content_identity);
    try w.writeBool(value.has_scripts);
    try w.writeBool(value.addon_pack);
    try w.writeBool(value.rtx_enabled);
    try w.writeString(value.download_url);
}
fn decodeStackResourcePack(r: *Reader) !p.StackResourcePack {
    return .{ .uuid = try r.readString(), .version = try r.readString(), .sub_pack_name = try r.readString() };
}
fn encodeStackResourcePack(w: anytype, value: p.StackResourcePack) !void {
    try w.writeString(value.uuid);
    try w.writeString(value.version);
    try w.writeString(value.sub_pack_name);
}
fn decodeExperiment(r: *Reader) !p.ExperimentData {
    return .{ .name = try r.readString(), .enabled = try r.readBool() };
}
fn encodeExperiment(w: anytype, value: p.ExperimentData) !void {
    try w.writeString(value.name);
    try w.writeBool(value.enabled);
}

pub fn decodeInfo(r: *Reader, allocator: std.mem.Allocator) !p.ResourcePacksInfoPacket {
    const required = try r.readBool();
    const addons = try r.readBool();
    const scripts = try r.readBool();
    const disable_vibrant = try r.readBool();
    const template_uuid = try r.readUuid();
    const template_version = try r.readString();
    const count = try readCount(r);
    try validateAllocation(p.TexturePackInfo, r, count, 32);
    const packs = try allocator.alloc(p.TexturePackInfo, count);
    errdefer allocator.free(packs);
    for (packs) |*pack| pack.* = try decodeTexturePackInfo(r);
    return .{ .texture_pack_required = required, .has_addons = addons, .has_scripts = scripts, .force_disable_vibrant_visuals = disable_vibrant, .world_template_uuid = template_uuid, .world_template_version = template_version, .texture_packs = packs };
}
pub fn encodeInfo(w: anytype, value: p.ResourcePacksInfoPacket) !void {
    try w.writeBool(value.texture_pack_required);
    try w.writeBool(value.has_addons);
    try w.writeBool(value.has_scripts);
    try w.writeBool(value.force_disable_vibrant_visuals);
    try w.writeUuid(value.world_template_uuid);
    try w.writeString(value.world_template_version);
    try writeCount(w, value.texture_packs.len);
    for (value.texture_packs) |pack| try encodeTexturePackInfo(w, pack);
}

pub fn decodeStack(r: *Reader, allocator: std.mem.Allocator) !p.ResourcePackStackPacket {
    const required = try r.readBool();
    const pack_count = try readCount(r);
    try validateAllocation(p.StackResourcePack, r, pack_count, 3);
    const packs = try allocator.alloc(p.StackResourcePack, pack_count);
    errdefer allocator.free(packs);
    for (packs) |*pack| pack.* = try decodeStackResourcePack(r);
    const version = try r.readString();
    const experiment_count = try readFixedCount(r);
    try validateAllocation(p.ExperimentData, r, experiment_count, 2);
    const experiments = try allocator.alloc(p.ExperimentData, experiment_count);
    errdefer allocator.free(experiments);
    for (experiments) |*experiment| experiment.* = try decodeExperiment(r);
    return .{ .texture_pack_required = required, .texture_packs = packs, .base_game_version = version, .experiments = experiments, .experiments_previously_toggled = try r.readBool(), .include_editor_packs = try r.readBool() };
}
pub fn encodeStack(w: anytype, value: p.ResourcePackStackPacket) !void {
    try w.writeBool(value.texture_pack_required);
    try writeCount(w, value.texture_packs.len);
    for (value.texture_packs) |pack| try encodeStackResourcePack(w, pack);
    try w.writeString(value.base_game_version);
    try writeFixedCount(w, value.experiments.len);
    for (value.experiments) |experiment| try encodeExperiment(w, experiment);
    try w.writeBool(value.experiments_previously_toggled);
    try w.writeBool(value.include_editor_packs);
}

const response_names = [_][]const u8{ "cancel", "downloading", "downloadingfinished", "resourcepackstackfinished" };
pub fn decodeResponse(r: *Reader, allocator: std.mem.Allocator) !p.ResourcePackClientResponsePacket {
    const raw = try r.readVarU32();
    const response = std.enums.fromInt(p.PackResponse, raw) orelse return error.InvalidEnum;
    const name = try r.readString();
    if (!std.mem.eql(u8, name, response_names[raw])) return error.InvalidEnum;
    if (response != .send_packs) return .{ .response = response, .packs_to_download = &.{} };
    const count = try readCount(r);
    try validateAllocation([]const u8, r, count, 1);
    const packs = try allocator.alloc([]const u8, count);
    errdefer allocator.free(packs);
    for (packs) |*pack| pack.* = try r.readString();
    return .{ .response = response, .packs_to_download = packs };
}
pub fn encodeResponse(w: anytype, value: p.ResourcePackClientResponsePacket) !void {
    if (value.response != .send_packs and value.packs_to_download.len != 0) return error.InvalidValue;
    const raw = @intFromEnum(value.response);
    try w.writeVarU32(raw);
    try w.writeString(response_names[raw]);
    if (value.response == .send_packs) {
        try writeCount(w, value.packs_to_download.len);
        for (value.packs_to_download) |pack| try w.writeString(pack);
    }
}

fn category(text_type: p.TextType) u8 {
    return switch (text_type) {
        .raw, .tip, .system, .object_whisper, .object_announcement, .object => 0,
        .chat, .whisper, .announcement => 1,
        .translation, .popup, .jukebox_popup => 2,
    };
}
fn validateText(value: p.TextPacket) !void {
    if (value.message.len == 0 or value.message.len > 65536 or value.source_name.len > 256 or value.xuid.len > 64 or value.platform_chat_id.len > 256) return error.InvalidValue;
    if (value.filtered_message) |message| if (message.len > 65536) return error.InvalidValue;
    const parameters_expected = category(value.text_type) == 2;
    if ((parameters_expected and value.parameters.len > 4) or (!parameters_expected and value.parameters.len != 0)) return error.InvalidValue;
    if (category(value.text_type) != 1 and value.source_name.len != 0) return error.InvalidValue;
}
pub fn decodeText(r: *Reader, allocator: std.mem.Allocator) !p.TextPacket {
    const needs_translation = try r.readBool();
    const wire_category = try r.readU8();
    const text_type = std.enums.fromInt(p.TextType, try r.readU8()) orelse return error.InvalidEnum;
    if (wire_category != category(text_type)) return error.InvalidEnum;
    var source_name: []const u8 = "";
    var message: []const u8 = undefined;
    var parameters: []const []const u8 = &.{};
    var allocated_parameters: ?[][]const u8 = null;
    errdefer if (allocated_parameters) |allocated| allocator.free(allocated);
    switch (category(text_type)) {
        0 => message = try r.readString(),
        1 => {
            source_name = try r.readString();
            message = try r.readString();
        },
        2 => {
            message = try r.readString();
            const count = try readCount(r);
            if (count > 4) return error.LimitExceeded;
            try validateAllocation([]const u8, r, count, 1);
            const allocated = try allocator.alloc([]const u8, count);
            allocated_parameters = allocated;
            for (allocated) |*parameter| parameter.* = try r.readString();
            parameters = allocated;
        },
        else => unreachable,
    }
    const xuid = try r.readString();
    const platform = try r.readString();
    const filtered = if (try r.readBool()) try r.readString() else null;
    const result: p.TextPacket = .{ .text_type = text_type, .needs_translation = needs_translation, .source_name = source_name, .message = message, .parameters = parameters, .xuid = xuid, .platform_chat_id = platform, .filtered_message = filtered };
    validateText(result) catch return error.InvalidValue;
    return result;
}
pub fn encodeText(w: anytype, value: p.TextPacket) !void {
    try validateText(value);
    try w.writeBool(value.needs_translation);
    try w.writeU8(category(value.text_type));
    try w.writeU8(@intFromEnum(value.text_type));
    switch (category(value.text_type)) {
        0 => try w.writeString(value.message),
        1 => {
            try w.writeString(value.source_name);
            try w.writeString(value.message);
        },
        2 => {
            try w.writeString(value.message);
            try writeCount(w, value.parameters.len);
            for (value.parameters) |parameter| try w.writeString(parameter);
        },
        else => unreachable,
    }
    try w.writeString(value.xuid);
    try w.writeString(value.platform_chat_id);
    try w.writeBool(value.filtered_message != null);
    if (value.filtered_message) |message| try w.writeString(message);
}
pub fn deinitInfo(allocator: std.mem.Allocator, value: p.ResourcePacksInfoPacket) void {
    allocator.free(value.texture_packs);
}
pub fn deinitStack(allocator: std.mem.Allocator, value: p.ResourcePackStackPacket) void {
    allocator.free(value.texture_packs);
    allocator.free(value.experiments);
}
pub fn deinitResponse(allocator: std.mem.Allocator, value: p.ResourcePackClientResponsePacket) void {
    if (value.response == .send_packs) allocator.free(value.packs_to_download);
}
pub fn deinitText(allocator: std.mem.Allocator, value: p.TextPacket) void {
    if (category(value.text_type) == 2) allocator.free(value.parameters);
}

/// Validated wire elements; all data and iterator results borrow the original input.
pub fn Collection(comptime T: type, comptime decodeElement: anytype) type {
    return struct {
        const Self = @This();
        bytes: []const u8,
        count: usize,
        limits: @import("../codec/limits.zig").DecodeLimits,
        pub const Iterator = struct {
            reader: Reader,
            left: usize,
            pub fn next(self: *Iterator) !?T {
                if (self.left == 0) {
                    try self.reader.finish();
                    return null;
                }
                const value = try decodeElement(&self.reader);
                self.left -= 1;
                return value;
            }
        };
        pub fn iterator(self: Self) Iterator {
            return .{ .reader = .{ .input = self.bytes, .cursor = 0, .limits = self.limits }, .left = self.count };
        }
        pub fn read(r: *Reader, length: usize) !Self {
            if (length > r.limits.max_array_elements) return error.LimitExceeded;
            if (length > r.remaining()) return error.EndOfStream;
            const start = r.cursor;
            for (0..length) |_| _ = try decodeElement(r);
            return .{ .bytes = r.input[start..r.cursor], .count = length, .limits = r.limits };
        }
    };
}
fn decodeString(r: *Reader) ![]const u8 {
    return r.readString();
}
pub const TexturePacks = Collection(p.TexturePackInfo, decodeTexturePackInfo);
pub const StackPacks = Collection(p.StackResourcePack, decodeStackResourcePack);
pub const Experiments = Collection(p.ExperimentData, decodeExperiment);
pub const PackNames = Collection([]const u8, decodeString);
pub const BorrowedInfo = struct {
    texture_pack_required: bool,
    has_addons: bool,
    has_scripts: bool,
    force_disable_vibrant_visuals: bool,
    world_template_uuid: [16]u8,
    world_template_version: []const u8,
    texture_packs: TexturePacks,
};
pub const BorrowedStack = struct {
    texture_pack_required: bool,
    texture_packs: StackPacks,
    base_game_version: []const u8,
    experiments: Experiments,
    experiments_previously_toggled: bool,
    include_editor_packs: bool,
};
pub const BorrowedResponse = struct { response: p.PackResponse, packs_to_download: PackNames };
pub fn decodeInfoBorrowed(r: *Reader) !BorrowedInfo {
    return .{
        .texture_pack_required = try r.readBool(),
        .has_addons = try r.readBool(),
        .has_scripts = try r.readBool(),
        .force_disable_vibrant_visuals = try r.readBool(),
        .world_template_uuid = try r.readUuid(),
        .world_template_version = try r.readString(),
        .texture_packs = try TexturePacks.read(r, try readCount(r)),
    };
}
pub fn decodeStackBorrowed(r: *Reader) !BorrowedStack {
    return .{
        .texture_pack_required = try r.readBool(),
        .texture_packs = try StackPacks.read(r, try readCount(r)),
        .base_game_version = try r.readString(),
        .experiments = try Experiments.read(r, try readFixedCount(r)),
        .experiments_previously_toggled = try r.readBool(),
        .include_editor_packs = try r.readBool(),
    };
}
pub fn decodeResponseBorrowed(r: *Reader) !BorrowedResponse {
    const raw = try r.readVarU32();
    const response = std.enums.fromInt(p.PackResponse, raw) orelse return error.InvalidEnum;
    if (!std.mem.eql(u8, try r.readString(), response_names[raw])) return error.InvalidEnum;
    return .{ .response = response, .packs_to_download = try PackNames.read(r, if (response == .send_packs) try readCount(r) else 0) };
}
fn encodeCollection(w: anytype, collection: anytype, comptime encodeElement: anytype) !void {
    var iterator = collection.iterator();
    while (iterator.next() catch return error.InvalidValue) |value| try encodeElement(w, value);
}
fn encodeString(w: anytype, value: []const u8) !void {
    try w.writeString(value);
}
pub fn encodeInfoBorrowed(w: anytype, value: BorrowedInfo) !void {
    try w.writeBool(value.texture_pack_required);
    try w.writeBool(value.has_addons);
    try w.writeBool(value.has_scripts);
    try w.writeBool(value.force_disable_vibrant_visuals);
    try w.writeUuid(value.world_template_uuid);
    try w.writeString(value.world_template_version);
    try writeCount(w, value.texture_packs.count);
    try encodeCollection(w, value.texture_packs, encodeTexturePackInfo);
}
pub fn encodeStackBorrowed(w: anytype, value: BorrowedStack) !void {
    try w.writeBool(value.texture_pack_required);
    try writeCount(w, value.texture_packs.count);
    try encodeCollection(w, value.texture_packs, encodeStackResourcePack);
    try w.writeString(value.base_game_version);
    try writeFixedCount(w, value.experiments.count);
    try encodeCollection(w, value.experiments, encodeExperiment);
    try w.writeBool(value.experiments_previously_toggled);
    try w.writeBool(value.include_editor_packs);
}
pub fn encodeResponseBorrowed(w: anytype, value: BorrowedResponse) !void {
    if (value.response != .send_packs and (value.packs_to_download.count != 0 or value.packs_to_download.bytes.len != 0)) return error.InvalidValue;
    const raw = @intFromEnum(value.response);
    try w.writeVarU32(raw);
    try w.writeString(response_names[raw]);
    if (value.response == .send_packs) {
        try writeCount(w, value.packs_to_download.count);
        try encodeCollection(w, value.packs_to_download, encodeString);
    }
}
