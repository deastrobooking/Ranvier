const std = @import("std");
const ecs = @import("world.zig");
const Position = struct { x: i32 };
const Velocity = struct { dx: i32 };
const Health = struct { hp: i32 };
const World = ecs.World(&.{ Position, Velocity, Health });
const Entity = ecs.Entity;
const p_mask = World.mask(&.{Position});
const v_mask = World.mask(&.{Velocity});
const h_mask = World.mask(&.{Health});
const pv_mask = p_mask | v_mask;
const ph_mask = p_mask | h_mask;
const all = pv_mask | h_mask;

fn fullWorld(domain: u64, cap: usize) !World {
    const configs = [_]ecs.ArchetypeConfig{
        .{ .mask = 0, .capacity = cap },
        .{ .mask = p_mask, .capacity = cap },
        .{ .mask = v_mask, .capacity = cap },
        .{ .mask = h_mask, .capacity = cap },
        .{ .mask = pv_mask, .capacity = cap },
        .{ .mask = ph_mask, .capacity = cap },
        .{ .mask = v_mask | h_mask, .capacity = cap },
        .{ .mask = all, .capacity = cap },
    };
    return World.init(std.testing.allocator, cap, domain, &configs);
}

test "registry masks, empty archetype, bad and duplicate configuration" {
    try std.testing.expectEqual(@as(ecs.Mask, 7), World.all_components);
    try std.testing.expectEqual(pv_mask, World.mask(&.{ Velocity, Position }));
    try std.testing.expectError(error.UnknownComponent, World.init(std.testing.allocator, 4, 1, &.{.{ .mask = 8, .capacity = 4 }}));
    try std.testing.expectError(error.DuplicateArchetype, World.init(std.testing.allocator, 4, 1, &.{ .{ .mask = 0, .capacity = 1 }, .{ .mask = 0, .capacity = 1 } }));
    try std.testing.expectError(error.InvalidDomain, World.init(std.testing.allocator, 4, 0, &.{}));
    var w = try fullWorld(1, 4);
    defer w.deinit() catch unreachable;
    const e = try w.spawn(.{});
    try std.testing.expectEqual(@as(ecs.Mask, 0), try w.signature(e));
    try std.testing.expect(w.validate());
    try w.add(e, Position{ .x = 42 });
    try w.remove(e, Position);
    try std.testing.expectEqual(@as(ecs.Mask, 0), try w.signature(e));
    try std.testing.expect(w.validate());
}

test "migration preserves shared data and swap-removal repairs source directory" {
    var w = try fullWorld(2, 10);
    defer w.deinit() catch unreachable;
    const e0 = try w.spawn(.{Position{ .x = 11 }});
    const e1 = try w.spawn(.{Position{ .x = 22 }});
    const e2 = try w.spawn(.{Position{ .x = 33 }});
    try w.add(e0, Velocity{ .dx = 7 });
    try std.testing.expectEqual(@as(i32, 33), (try w.get(e2, Position)).x);
    try std.testing.expectEqual(@as(i32, 11), (try w.get(e0, Position)).x);
    try std.testing.expectEqual(@as(i32, 7), (try w.get(e0, Velocity)).dx);
    try w.add(e0, Health{ .hp = 90 });
    try w.remove(e0, Velocity);
    try std.testing.expectEqual(ph_mask, try w.signature(e0));
    try std.testing.expectEqual(@as(i32, 90), (try w.get(e0, Health)).hp);
    try std.testing.expectError(error.MissingComponent, w.get(e0, Velocity));
    try w.despawn(e2);
    try std.testing.expectEqual(@as(i32, 22), (try w.get(e1, Position)).x);
    try std.testing.expect(w.validate());
    try std.testing.expectEqual(@as(usize, 2), w.count());
}

test "invalid entity, stale generation and foreign world IDs are rejected" {
    var a = try fullWorld(3, 2);
    defer a.deinit() catch unreachable;
    var b = try fullWorld(4, 2);
    defer b.deinit() catch unreachable;
    const old = try a.spawn(.{Position{ .x = 1 }});
    const foreign = try b.spawn(.{Position{ .x = 99 }});
    try std.testing.expectError(error.InvalidEntity, a.get(foreign, Position));
    try std.testing.expectError(error.InvalidEntity, a.despawn(foreign));
    try a.despawn(old);
    const new = try a.spawn(.{Position{ .x = 2 }});
    try std.testing.expectEqual(old.index, new.index);
    try std.testing.expect(old.generation != new.generation);
    try std.testing.expectError(error.InvalidEntity, a.get(old, Position));
    try std.testing.expectError(error.InvalidEntity, a.set(old, Position{ .x = 3 }));
    try std.testing.expectError(error.InvalidEntity, a.add(old, Health{ .hp = 1 }));
    try std.testing.expectError(error.InvalidEntity, a.remove(old, Position));
    try std.testing.expectError(error.InvalidEntity, a.despawn(old));
    try std.testing.expectEqual(@as(i32, 2), (try a.get(new, Position)).x);
    try std.testing.expect(a.validate() and b.validate());
}

test "capacity and missing-archetype failures leave source and destination unchanged" {
    var w = try World.init(std.testing.allocator, 3, 5, &.{
        .{ .mask = p_mask, .capacity = 3 }, .{ .mask = pv_mask, .capacity = 1 },
    });
    defer w.deinit() catch unreachable;
    const a = try w.spawn(.{Position{ .x = 5 }});
    const b = try w.spawn(.{ Position{ .x = 7 }, Velocity{ .dx = 10 } });
    try std.testing.expectError(error.ArchetypeFull, w.add(a, Velocity{ .dx = 1 }));
    try std.testing.expectError(error.MissingArchetype, w.add(a, Health{ .hp = 100 }));
    try std.testing.expectError(error.AlreadyPresent, w.add(a, Position{ .x = 7 }));
    try std.testing.expectError(error.MissingComponent, w.remove(a, Velocity));
    try std.testing.expectEqual(p_mask, try w.signature(a));
    try std.testing.expectEqual(@as(i32, 5), (try w.get(a, Position)).x);
    try std.testing.expectEqual(@as(i32, 10), (try w.get(b, Velocity)).dx);
    _ = try w.spawn(.{Position{ .x = 100 }});
    try std.testing.expectError(error.EntityCapacity, w.spawn(.{Position{ .x = 2 }}));
    try std.testing.expectError(error.ArchetypeFull, w.spawn(.{ Position{ .x = 1 }, Velocity{ .dx = 2 } }));
    try std.testing.expect(w.validate());
    try std.testing.expectEqual(@as(usize, 3), w.count());
}

const MoveChunk = World.Chunk(&.{Velocity}, &.{Position});
const Move = struct {
    fn run(sum: *usize, chunk: MoveChunk) !void {
        for (chunk.write(Position), chunk.read(Velocity), chunk.ids()) |*p, v, id| {
            p.x += v.dx;
            if (id.domain == 0) return error.BadDomain;
            sum.* += 1;
        }
    }
};
test "typed multi-archetype queries include required and exclude forbidden components" {
    var w = try fullWorld(6, 8);
    defer w.deinit() catch unreachable;
    const a = try w.spawn(.{ Position{ .x = 1 }, Velocity{ .dx = 2 } });
    const b = try w.spawn(.{ Position{ .x = 10 }, Velocity{ .dx = 3 }, Health{ .hp = 1 } });
    const c = try w.spawn(.{Position{ .x = 5 }});
    var count: usize = 0;
    try w.forEach(&.{Velocity}, &.{Position}, &.{Health}, &count, Move.run);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(i32, 3), (try w.get(a, Position)).x);
    try std.testing.expectEqual(@as(i32, 10), (try w.get(b, Position)).x);
    try w.forEach(&.{Velocity}, &.{Position}, &.{}, &count, Move.run);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(@as(i32, 5), (try w.get(a, Position)).x);
    try std.testing.expectEqual(@as(i32, 13), (try w.get(b, Position)).x);
    try std.testing.expectEqual(@as(i32, 5), (try w.get(c, Position)).x);
    try std.testing.expect(w.validate());
}

const ReadChunk = World.Chunk(&.{Position}, &.{});
const GuardContext = struct { w: *World, commands: *World.CommandBuffer };
const Guard = struct {
    fn noop(_: void, _: ReadChunk) !void {}
    fn run(ctx: GuardContext, chunk: ReadChunk) !void {
        const e = chunk.ids()[0];
        try std.testing.expectError(error.QueryActive, ctx.w.spawn(.{Position{ .x = 0 }}));
        try std.testing.expectError(error.QueryActive, ctx.w.despawn(e));
        try std.testing.expectError(error.QueryActive, ctx.w.add(e, Velocity{ .dx = 1 }));
        try std.testing.expectError(error.QueryActive, ctx.w.remove(e, Position));
        try std.testing.expectError(error.QueryActive, ctx.w.get(e, Position));
        try std.testing.expectError(error.QueryActive, ctx.w.set(e, Position{ .x = 0 }));
        try std.testing.expectError(error.QueryActive, ctx.w.deinit());
        try std.testing.expectError(error.QueryActive, ctx.w.forEach(&.{Position}, &.{}, &.{}, {}, noop));
        try ctx.commands.add(e, Velocity{ .dx = 2 });
        try std.testing.expectError(error.QueryActive, ctx.commands.flush(ctx.w));
        return error.CallbackFailure;
    }
};
test "query guard rejects world mutation, preserves commands and releases on callback error" {
    var w = try fullWorld(7, 4);
    defer w.deinit() catch unreachable;
    var commands = try World.CommandBuffer.init(std.testing.allocator, w.domain(), 4, 32);
    defer commands.deinit();
    const e = try w.spawn(.{Position{ .x = 9 }});
    try std.testing.expectError(error.CallbackFailure, w.forEach(&.{Position}, &.{}, &.{}, GuardContext{ .w = &w, .commands = &commands }, Guard.run));
    try std.testing.expectEqual(@as(usize, 1), commands.count());
    try std.testing.expectEqual(p_mask, try w.signature(e));
    const report = try commands.flush(&w);
    try std.testing.expectEqual(@as(usize, 1), report.applied);
    try std.testing.expectEqual(@as(i32, 2), (try w.get(e, Velocity)).dx);
    try std.testing.expect(w.validate());
}

test "FIFO deferred spawn, add, remove, despawn and stale command rejection" {
    var w = try fullWorld(8, 8);
    defer w.deinit() catch unreachable;
    var commands = try World.CommandBuffer.init(std.testing.allocator, w.domain(), 8, 64);
    defer commands.deinit();
    const e = try w.spawn(.{Position{ .x = 9 }});
    const kept = try w.spawn(.{Position{ .x = 5 }});
    try commands.add(e, Velocity{ .dx = 2 });
    try commands.remove(e, Position);
    try commands.despawn(e);
    try commands.add(e, Health{ .hp = 100 }); // rejected after deletion
    try commands.add(kept, Health{ .hp = 6 });
    try commands.spawn(.{ Health{ .hp = 99 }, Position{ .x = 77 }, Velocity{ .dx = 11 } });
    try commands.spawn(.{});
    try std.testing.expectEqual(@as(usize, 2), w.count());
    const report = try commands.flush(&w);
    try std.testing.expectEqual(@as(usize, 6), report.applied);
    try std.testing.expectEqual(@as(usize, 1), report.rejected);
    try std.testing.expectEqual(@as(usize, 2), report.spawned);
    try std.testing.expectEqual(@as(usize, 3), report.first_failure.?.index);
    try std.testing.expect(report.first_failure.?.reason == error.InvalidEntity);
    try std.testing.expectEqual(@as(usize, 3), w.count());
    try std.testing.expect(!w.contains(e));
    try std.testing.expectEqual(@as(i32, 6), (try w.get(kept, Health)).hp);
    try std.testing.expectEqual(@as(?usize, 1), w.countIn(all));
    try std.testing.expectEqual(@as(?usize, 1), w.countIn(0));
    const Inspect = struct {
        fn run(_: void, chunk: World.Chunk(&.{ Position, Velocity, Health }, &.{})) !void {
            try std.testing.expectEqual(@as(i32, 77), chunk.read(Position)[0].x);
            try std.testing.expectEqual(@as(i32, 11), chunk.read(Velocity)[0].dx);
            try std.testing.expectEqual(@as(i32, 99), chunk.read(Health)[0].hp);
        }
    };
    try w.forEach(&.{ Position, Velocity, Health }, &.{}, &.{}, {}, Inspect.run);
    try std.testing.expectEqual(@as(usize, 0), commands.count());
    try std.testing.expectEqual(@as(usize, 0), commands.payloadUsed());
    try std.testing.expect(w.validate());
}

test "bounded command buffer rejects overflows atomically and wrong-world flush preserves queue" {
    var w = try fullWorld(9, 4);
    defer w.deinit() catch unreachable;
    var other = try fullWorld(10, 4);
    defer other.deinit() catch unreachable;
    var commands = try World.CommandBuffer.init(std.testing.allocator, w.domain(), 2, @sizeOf(Velocity));
    defer commands.deinit();
    const e = try w.spawn(.{Position{ .x = 3 }});
    const f = try other.spawn(.{Position{ .x = 7 }});
    try std.testing.expectError(error.WrongDomain, commands.add(f, Velocity{ .dx = 1 }));
    try std.testing.expectError(error.PayloadCapacity, commands.spawn(.{ Position{ .x = 3 }, Velocity{ .dx = 1 } }));
    try std.testing.expectEqual(@as(usize, 0), commands.count());
    try commands.add(e, Velocity{ .dx = 2 });
    try std.testing.expectError(error.PayloadCapacity, commands.add(e, Health{ .hp = 5 }));
    try commands.remove(e, Position);
    try std.testing.expectError(error.CommandCapacity, commands.despawn(e));
    try std.testing.expectError(error.WrongDomain, commands.flush(&other));
    try std.testing.expectEqual(@as(usize, 2), commands.count());
    try std.testing.expectEqual(@as(usize, 2), (try commands.flush(&w)).applied);
    try std.testing.expectEqual(v_mask, try w.signature(e));
    try std.testing.expect(w.validate() and other.validate());
}

// Independent simple reference state per logical entity. No archetype or row
// indices in the oracle: compare every live entity after each random mutation.
const Model = struct { e: ?Entity = null, pos: ?i32 = null, vel: ?i32 = null, hp: ?i32 = null };
fn random(state: *u64) u64 {
    state.* ^= state.* << 13;
    state.* ^= state.* >> 7;
    state.* ^= state.* << 17;
    return state.*;
}
test "5000 deterministic operations against a reference component model" {
    const cap = 24;
    var w = try fullWorld(11, cap);
    defer w.deinit() catch unreachable;
    var model: [cap]Model = @splat(.{});
    var rng: u64 = 0xcafe12345678;
    for (0..5000) |step| {
        const i: usize = @intCast(random(&rng) % cap);
        const op = random(&rng) % 8;
        const val: i32 = @intCast(step);
        const m = &model[i];
        if (m.e) |e| {
            switch (op) {
                0 => {
                    try w.despawn(e);
                    m.* = .{};
                    try std.testing.expect(!w.contains(e));
                },
                1 => if (m.pos != null) {
                    try w.remove(e, Position);
                    m.pos = null;
                } else {
                    try w.add(e, Position{ .x = val });
                    m.pos = val;
                },
                2 => if (m.vel != null) {
                    try w.remove(e, Velocity);
                    m.vel = null;
                } else {
                    try w.add(e, Velocity{ .dx = val });
                    m.vel = val;
                },
                3 => if (m.hp != null) {
                    try w.remove(e, Health);
                    m.hp = null;
                } else {
                    try w.add(e, Health{ .hp = val });
                    m.hp = val;
                },
                4 => if (m.pos != null) {
                    try w.set(e, Position{ .x = val });
                    m.pos = val;
                },
                5 => if (m.vel != null) {
                    try w.set(e, Velocity{ .dx = val });
                    m.vel = val;
                },
                6 => if (m.hp != null) {
                    try w.set(e, Health{ .hp = val });
                    m.hp = val;
                },
                else => {},
            }
        } else {
            m.e = try w.spawn(.{Position{ .x = val }});
            m.pos = val;
        }
        var total: usize = 0;
        for (model) |expected| {
            if (expected.e) |e| {
                total += 1;
                var signature: ecs.Mask = 0;
                if (expected.pos) |x| {
                    signature |= p_mask;
                    try std.testing.expectEqual(x, (try w.get(e, Position)).x);
                } else {
                    try std.testing.expectError(error.MissingComponent, w.get(e, Position));
                }
                if (expected.vel) |x| {
                    signature |= v_mask;
                    try std.testing.expectEqual(x, (try w.get(e, Velocity)).dx);
                } else {
                    try std.testing.expectError(error.MissingComponent, w.get(e, Velocity));
                }
                if (expected.hp) |x| {
                    signature |= h_mask;
                    try std.testing.expectEqual(x, (try w.get(e, Health)).hp);
                } else {
                    try std.testing.expectError(error.MissingComponent, w.get(e, Health));
                }
                try std.testing.expectEqual(signature, try w.signature(e));
            }
        }
        try std.testing.expectEqual(total, w.count());
        try std.testing.expect(w.validate());
    }
}

test "zero entity capacity and zero-capacity archetype are well defined" {
    var w = try World.init(std.testing.allocator, 0, 12, &.{.{ .mask = p_mask, .capacity = 0 }});
    defer w.deinit() catch unreachable;
    try std.testing.expectError(error.ArchetypeFull, w.spawn(.{Position{ .x = 1 }}));
    try std.testing.expect(w.validate());
}

fn setupUseTeardown(a: std.mem.Allocator) !void {
    var w = try World.init(a, 8, 13, &.{
        .{ .mask = p_mask, .capacity = 8 },
        .{ .mask = pv_mask, .capacity = 8 },
        .{ .mask = all, .capacity = 8 },
    });
    defer w.deinit() catch unreachable;
    var commands = try World.CommandBuffer.init(a, w.domain(), 4, 64);
    defer commands.deinit();
    const e = try w.spawn(.{Position{ .x = 1 }});
    try commands.add(e, Velocity{ .dx = 2 });
    try commands.spawn(.{ Position{ .x = 3 }, Velocity{ .dx = 4 }, Health{ .hp = 5 } });
    const report = try commands.flush(&w);
    if (report.applied != 2 or !w.validate()) return error.TestUnexpectedResult;
}
test "every allocation failure in world and command-buffer setup is reported and leak-free" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, setupUseTeardown, .{});
}
