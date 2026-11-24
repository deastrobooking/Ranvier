//! Same heterogeneous movement workload for archetype ECS and a flat AoS.
//! Whole-process benchmark includes initialization, iteration and teardown.
const std = @import("std");
const rv = @import("ranvier");
const N = 200_000;
const rounds = 80;
const Position = struct { x: u32 };
const Velocity = struct { v: u32 };
const Cold = struct { bytes: [56]u8 };
const World = rv.ecs.World(&.{ Position, Velocity, Cold });
const MoveChunk = World.Chunk(&.{Velocity}, &.{Position});
fn move(_: void, chunk: MoveChunk) !void {
    for (chunk.write(Position), chunk.read(Velocity)) |*p, v| p.x +%= v.v;
}
const SumChunk = World.Chunk(&.{ Position, Cold }, &.{});
fn sum(checksum: *u64, chunk: SumChunk) !void {
    for (chunk.read(Position), chunk.read(Cold)) |p, c| {
        checksum.* +%= p.x;
        checksum.* +%= c.bytes[0];
    }
}
fn initValues(i: usize) struct { p: Position, v: Velocity, c: Cold } {
    const x: u32 = @intCast(i);
    return .{ .p = .{ .x = x }, .v = .{ .v = x % 17 + 1 }, .c = .{ .bytes = @splat(@as(u8, @truncate(x))) } };
}
fn ecs() !u64 {
    var w = try World.init(std.heap.page_allocator, N, 100, &.{
        .{ .mask = World.mask(&.{ Position, Cold }), .capacity = N / 2 },
        .{ .mask = World.mask(&.{ Position, Velocity, Cold }), .capacity = N / 2 },
    });
    defer w.deinit() catch unreachable;
    for (0..N) |i| {
        const v = initValues(i);
        if (i % 2 == 0) {
            _ = try w.spawn(.{ v.p, v.v, v.c });
        } else {
            _ = try w.spawn(.{ v.p, v.c });
        }
    }
    for (0..rounds) |_| try w.forEach(&.{Velocity}, &.{Position}, &.{}, {}, move);
    var checksum: u64 = 0;
    try w.forEach(&.{ Position, Cold }, &.{}, &.{}, &checksum, sum);
    if (!w.validate()) return error.InvalidWorld;
    return checksum;
}
const Row = struct { p: Position, v: Velocity, c: Cold, moving: bool };
fn aos() !u64 {
    const a = std.heap.page_allocator;
    const rows = try a.alloc(Row, N);
    defer a.free(rows);
    for (rows, 0..) |*row, i| {
        const v = initValues(i);
        row.* = .{ .p = v.p, .v = v.v, .c = v.c, .moving = i % 2 == 0 };
    }
    for (0..rounds) |_| for (rows) |*row| {
        if (row.moving) row.p.x +%= row.v.v;
    };
    var checksum: u64 = 0;
    for (rows) |row| {
        checksum +%= row.p.x;
        checksum +%= row.c.bytes[0];
    }
    return checksum;
}
pub fn run(comptime archetypes: bool) !void {
    const checksum = if (archetypes) try ecs() else try aos();
    std.debug.print("RESULT {s} {d} {d} {d}\n", .{ if (archetypes) "ecs" else "aos", N, rounds, checksum });
}
