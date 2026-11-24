const std = @import("std");
const rv = @import("ranvier");
const Particle = struct { x: f32, v: f32, health: u32 };

pub fn main() !void {
    const a = std.heap.page_allocator;
    // Irregular lifetime: stable entity identity, even after slot reuse.
    var pool = try rv.memory.SlotMap(Particle).init(a, 8, 1);
    defer pool.deinit();
    const dead = try pool.insert(.{ .x = 0, .v = 1, .health = 100 });
    _ = pool.remove(dead);
    const alive = try pool.insert(.{ .x = 5, .v = 3, .health = 99 });
    if (pool.contains(dead) or !pool.contains(alive)) return error.IdentityFailure;

    // Frame-temporary storage with no allocation after setup.
    var scratch: [1024]u8 align(16) = undefined;
    var region = rv.memory.Region.init(&scratch);
    const scope = try region.mark();
    const backing = try region.alloc(u32, 32);
    var visible = rv.memory.StableVec(u32).init(backing);
    const first = try visible.append(10);
    _ = try visible.append(20);
    first.* = 11;
    std.debug.print("stable first={d}, used={d} bytes\n", .{ visible.items()[0], region.used() });
    try region.rewind(scope); // visible and first must not be used after rewind.

    // Hot columns: position and velocity only.
    var particles = try rv.data.SoA(Particle).init(a, 8);
    defer particles.deinit();
    try particles.append(pool.get(alive).?);
    try particles.append(.{ .x = 10, .v = 2, .health = 100 });
    const dt: f32 = 0.25;
    for (particles.column("x"), particles.column("v")) |*x, v| x.* += v * dt;
    std.debug.print("position={d}, health={d}\n", .{ particles.get(0).?.x, particles.get(0).?.health });

    // One allocation to encode; validation and views allocate nothing.
    const chunk = try rv.binary.WorldChunk.encode(a, &.{.{ .id = 1, .position = .{ 5, 0, 2 }, .label = "Tokyo" }});
    defer a.free(chunk);
    const scene = try rv.binary.WorldChunk.View.open(chunk);
    std.debug.print("scene: {d} node(s), label={s}, encoded={d} bytes\n", .{ scene.count, try scene.label(0), chunk.len });
}
