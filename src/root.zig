//! Ranvier Core: explicit storage, representation, and binary access contracts.
pub const memory = @import("memory/root.zig");
pub const data = @import("data/root.zig");
pub const binary = @import("binary/root.zig");
pub const ecs = @import("ecs/root.zig");
pub const tasks = @import("tasks/root.zig");

test {
    _ = @import("memory/slot_map.zig");
    _ = @import("memory/region.zig");
    _ = @import("memory/stable_vec.zig");
    _ = @import("data/layout.zig");
    _ = @import("data/packed_records.zig");
    _ = @import("data/cost.zig");
    _ = @import("binary/relative.zig");
    _ = @import("binary/world_chunk.zig");
    _ = ecs;
    _ = tasks;
}

const std = @import("std");

test "integration: entity identity, frame scratch, packed chunk and hot table" {
    const a = std.testing.allocator;
    const C = struct { x: f32, v: f32 };
    var ids = try memory.SlotMap(C).init(a, 4, 123);
    defer ids.deinit();
    const id = try ids.insert(.{ .x = 1, .v = 2 });
    var table = try data.SoA(C).init(a, 4);
    defer table.deinit();
    try table.append(ids.get(id).?);
    for (table.column("x"), table.column("v")) |*x, v| x.* += v;
    try std.testing.expect(ids.set(id, table.get(0).?));
    var scratch: [64]u8 align(8) = undefined;
    var frame = memory.Region.init(&scratch);
    const mark = try frame.mark();
    var visible = memory.StableVec(u32).init(try frame.alloc(u32, 4));
    _ = try visible.append(id.index);
    try std.testing.expectEqual(id.index, visible.items()[0]);
    const blob = try binary.WorldChunk.encode(a, &.{.{ .id = id.index, .position = .{ ids.get(id).?.x, 0, 0 }, .label = "entity" }});
    defer a.free(blob);
    const view = try binary.WorldChunk.View.open(blob);
    try std.testing.expectEqual(@as(f32, 3), (try view.node(0)).position[0]);
    try frame.rewind(mark);
    _ = ids.remove(id);
    const replacement = try ids.insert(.{ .x = 0, .v = 0 });
    try std.testing.expect(id.index == replacement.index and !ids.contains(id));
}

fn storageSetupTeardown(a: std.mem.Allocator) !void {
    const C = struct { x: f32, v: f32 };
    var ids = try memory.SlotMap(C).init(a, 4, 9);
    defer ids.deinit();
    inline for (.{ data.Layout.aos, data.Layout.soa, data.Layout.aosoa }) |kind| {
        var table = try data.Table(C, kind, 4).init(a, 6);
        defer table.deinit();
        try table.append(.{ .x = 1, .v = 2 });
    }
    const blob = try binary.WorldChunk.encode(a, &.{.{ .id = 1, .position = .{ 0, 0, 0 }, .label = "n" }});
    defer a.free(blob);
    _ = try binary.WorldChunk.View.open(blob);
}
test "every allocation failure in pool, layout tables and chunk encoding is leak-free" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, storageSetupTeardown, .{});
}
