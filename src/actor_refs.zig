//! Finds and rewrites actor IDs in decoded packets.

const std = @import("std");
const version = @import("generated/root.zig");
const DecodeError = @import("codec/errors.zig").DecodeError;

pub const Ref = @import("codec/support.zig").ActorRef;
pub const Error = DecodeError || std.mem.Allocator.Error;

/// Packets that can carry an actor ID.
pub const packets: std.EnumSet(version.Kind) = blk: {
    @setEvalBranchQuota(1_000_000);
    var set: std.EnumSet(version.Kind) = .empty;
    const info = @typeInfo(version.Packet).@"union";
    for (info.field_names, info.field_types) |name, T| {
        if (reaches(T)) set.insert(@field(version.Kind, name));
    }
    break :blk set;
};

pub fn reaches(comptime T: type) bool {
    return reach(T, &.{});
}

/// Lists holding IDs are copied into `arena`; everything else still borrows the decoded input.
pub fn rewrite(arena: std.mem.Allocator, value: anytype, map: anytype) Error!bool {
    return walk(@TypeOf(value.*), arena, value, map);
}

fn reach(comptime T: type, comptime seen: []const type) bool {
    @setEvalBranchQuota(100_000);
    for (seen) |other| if (other == T) return false;
    const next = seen ++ .{T};
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (isList(T)) return reach(T.Element, next);
            if (@hasDecl(T, "actor_refs")) return true;
            for (info.field_types) |F| if (reach(F, next)) return true;
            return false;
        },
        .@"union" => |info| {
            if (@hasDecl(T, "actor_refs")) return true;
            for (info.field_types) |F| if (reach(F, next)) return true;
            return false;
        },
        .optional => |info| return reach(info.child, next),
        .array => |info| return reach(info.child, next),
        .pointer => |info| {
            if (reach(info.child, next)) @compileError(@typeName(T) ++ " hides actor references behind a slice the visitor cannot rewrite");
            return false;
        },
        else => return false,
    }
}

fn isList(comptime T: type) bool {
    return @hasDecl(T, "Element") and @hasDecl(T, "Data") and @hasDecl(T, "toOwnedSlice");
}

fn tag(comptime T: type, comptime name: []const u8) ?Ref {
    if (!@hasDecl(T, "actor_refs") or !@hasField(@TypeOf(T.actor_refs), name)) return null;
    return @field(T.actor_refs, name);
}

fn walk(comptime T: type, arena: std.mem.Allocator, value: *T, map: anytype) Error!bool {
    if (comptime !reaches(T)) return false;
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (comptime isList(T)) return list(T, null, arena, value, map);
            var changed = false;
            inline for (info.field_names, info.field_types) |name, F| {
                const ptr = &@field(value, name);
                const result = if (comptime tag(T, name)) |ref| try apply(F, ref, arena, ptr, map) else try walk(F, arena, ptr, map);
                changed = result or changed;
            }
            return changed;
        },
        .@"union" => switch (value.*) {
            inline else => |*payload, active| {
                const P = @TypeOf(payload.*);
                return if (comptime tag(T, @tagName(active))) |ref| apply(P, ref, arena, payload, map) else walk(P, arena, payload, map);
            },
        },
        .optional => |info| return if (value.*) |*inner| walk(info.child, arena, inner, map) else false,
        .array => |info| {
            var changed = false;
            for (value) |*item| changed = try walk(info.child, arena, item, map) or changed;
            return changed;
        },
        else => comptime unreachable,
    }
}

fn apply(comptime T: type, comptime ref: Ref, arena: std.mem.Allocator, value: *T, map: anytype) Error!bool {
    switch (T) {
        u64, i64 => {
            const old = value.*;
            value.* = switch (ref) {
                .runtime => @bitCast(map.runtime(@as(u64, @bitCast(old)))),
                .unique => @bitCast(map.unique(@as(i64, @bitCast(old)))),
            };
            return value.* != old;
        },
        else => switch (@typeInfo(T)) {
            .optional => |info| return if (value.*) |*inner| apply(info.child, ref, arena, inner, map) else false,
            .array => |info| {
                var changed = false;
                for (value) |*item| changed = try apply(info.child, ref, arena, item, map) or changed;
                return changed;
            },
            .@"struct" => if (comptime isList(T)) return list(T, ref, arena, value, map),
            else => {},
        },
    }
    @compileError("actor reference of unsupported type " ++ @typeName(T));
}

fn list(comptime T: type, comptime ref: ?Ref, arena: std.mem.Allocator, value: *T, map: anytype) Error!bool {
    if (value.len == 0) return false;
    const items = try value.toOwnedSlice(arena);
    var changed = false;
    for (items) |*item| {
        const result = if (ref) |r| try apply(T.Element, r, arena, item, map) else try walk(T.Element, arena, item, map);
        changed = result or changed;
    }
    if (changed) value.* = .init(items) else arena.free(items);
    return changed;
}
