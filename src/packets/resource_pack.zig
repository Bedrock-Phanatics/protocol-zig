pub const TexturePackInfo = struct {
    uuid: [16]u8,
    version: []u8,
    size: u64,
    content_key: []u8,
    sub_pack_name: []u8,
    content_identity: []u8,
    has_scripts: bool,
    addon_pack: bool,
    rtx_enabled: bool,
    download_url: []u8,
};

pub const StackResourcePack = struct {
    uuid: []u8,
    version: []u8,
    sub_pack_name: []u8,
};

pub const ExperimentData = struct { name: []u8, enabled: bool };

pub const ResourcePacksInfoPacket = struct {
    texture_pack_required: bool,
    has_addons: bool,
    has_scripts: bool,
    force_disable_vibrant_visuals: bool,
    world_template_uuid: [16]u8,
    world_template_version: []const u8,
    texture_packs: []TexturePackInfo,
};

pub const ResourcePackStackPacket = struct {
    texture_pack_required: bool,
    texture_packs: []StackResourcePack,
    base_game_version: []const u8,
    experiments: []ExperimentData,
    experiments_previously_toggled: bool,
    include_editor_packs: bool,
};

pub const PackResponse = enum(u32) { refused = 0, send_packs = 1, all_packs_downloaded = 2, completed = 3 };
pub const ResourcePackClientResponsePacket = struct { response: PackResponse, packs_to_download: []const []const u8 };

pub const TextType = enum(u8) {
    raw = 0,
    chat = 1,
    translation = 2,
    popup = 3,
    jukebox_popup = 4,
    tip = 5,
    system = 6,
    whisper = 7,
    announcement = 8,
    object_whisper = 9,
    object = 10,
    object_announcement = 11,
};
pub const TextPacket = struct {
    text_type: TextType,
    needs_translation: bool,
    source_name: []const u8 = "",
    message: []const u8,
    parameters: []const []const u8 = &.{},
    xuid: []const u8 = "",
    platform_chat_id: []const u8 = "",
    filtered_message: ?[]const u8 = null,
};
