const std = @import("std");
const rv = @import("ranvier");
const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Health = struct { hp: u32 };
const World = rv.ecs.World(&.{ Position, Velocity, Health });
const Context = struct { dt: f32, commands: *World.CommandBuffer };
fn move(ctx: Context, chunk: World.Chunk(&.{Velocity}, &.{Position})) !void {
    for (chunk.ids(), chunk.write(Position), chunk.read(Velocity)) |id, *p, v| {
        p.x += v.x * ctx.dt;
        p.y += v.y * ctx.dt;
        if (p.x > 5) try ctx.commands.remove(id, Velocity);
    }
}
pub fn main() !void {
    const a = std.heap.page_allocator;
    var world = try World.init(a, 1024, 1, &.{
        .{ .mask = World.mask(&.{Position}), .capacity = 1024 },
        .{ .mask = World.mask(&.{ Position, Velocity }), .capacity = 1024 },
        .{ .mask = World.mask(&.{ Position, Velocity, Health }), .capacity = 32 },
        .{ .mask = World.mask(&.{ Position, Health }), .capacity = 32 },
    });
    defer world.deinit() catch unreachable;
    var commands = try World.CommandBuffer.init(a, world.domain(), 1024, 4096);
    defer commands.deinit();
    const entity = try world.spawn(.{ Position{ .x = 0, .y = 0 }, Velocity{ .x = 12, .y = 0 }, Health{ .hp = 100 } });
    const static_entity = try world.spawn(.{Position{ .x = 0, .y = 0 }});
    try world.forEach(&.{Velocity}, &.{Position}, &.{}, Context{ .dt = 0.5, .commands = &commands }, move);
    const report = try commands.flush(&world);
    if (report.applied != 1 or report.rejected != 0 or !world.validate()) return error.EcsFailure;
    if ((try world.signature(entity)) != World.mask(&.{ Position, Health })) return error.BadMigration;
    if ((try world.get(entity, Health)).hp != 100 or (try world.get(static_entity, Position)).x != 0) return error.BadValue;
    std.debug.print("entity {d} stopped at x={d}; migrations={d}\n", .{ entity.index, (try world.get(entity, Position)).x, report.applied });

    const graph = try rv.tasks.plan(&.{
        .{ .reads = World.mask(&.{Velocity}), .writes = World.mask(&.{Position}) },
        .{ .writes = World.mask(&.{Health}) },
        .{ .reads = World.mask(&.{ Position, Health }) },
    });
    for (graph.stages(), 0..) |wave, i| std.debug.print("wave {d}: system mask 0x{x}\n", .{ i, wave });
    // Planner only: forEach is currently sequential and non-reentrant.
}
