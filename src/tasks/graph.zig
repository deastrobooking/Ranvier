//! Deterministic dependency planner. No executor, synchronization or worker
//! threads are created. Access masks are declarations, not proven Zig effects.
const std = @import("std");
pub const Mask = u64;
pub const System = struct {
    reads: Mask = 0,
    writes: Mask = 0,
    /// Explicit predecessor system indices, encoded as bits.
    after: Mask = 0,
};
pub const Plan = struct {
    count: usize,
    dependencies: [64]Mask = @splat(0),
    waves: [64]Mask = @splat(0),
    wave_count: usize = 0,
    pub fn stages(self: *const Plan) []const Mask {
        return self.waves[0..self.wave_count];
    }
};
pub fn bit(i: usize) Mask {
    std.debug.assert(i < 64);
    return @as(Mask, 1) << @as(u6, @intCast(i));
}
pub fn conflicts(a: System, b: System) bool {
    return (a.writes & (b.reads | b.writes)) != 0 or (b.writes & a.reads) != 0;
}
/// Hazard edges follow registration order. Explicit dependencies may point
/// forward or backward; contradictions are detected as cycles. Each ready
/// wave is maximal under these edges and contains no declared conflicts.
pub fn plan(systems: []const System) error{ TooManySystems, UnknownDependency, Cycle }!Plan {
    if (systems.len > 64) return error.TooManySystems;
    const all: Mask = if (systems.len == 64) std.math.maxInt(Mask) else if (systems.len == 0) 0 else bit(systems.len) - 1;
    var result: Plan = .{ .count = systems.len };
    for (systems, 0..) |s, i| {
        if ((s.after & ~all) != 0) return error.UnknownDependency;
        result.dependencies[i] = s.after;
        for (systems[0..i], 0..) |earlier, j| {
            if (conflicts(earlier, s)) result.dependencies[i] |= bit(j);
        }
    }
    var remaining = all;
    while (remaining != 0) {
        var ready: Mask = 0;
        for (0..systems.len) |i| {
            if ((remaining & bit(i)) != 0 and (result.dependencies[i] & remaining) == 0) ready |= bit(i);
        }
        if (ready == 0) return error.Cycle;
        result.waves[result.wave_count] = ready;
        result.wave_count += 1;
        remaining &= ~ready;
    }
    return result;
}

test "independent tasks share a wave, conflicts and explicit dependencies order execution" {
    const p = try plan(&.{
        .{ .reads = 2, .writes = 1 }, // physics
        .{ .reads = 8, .writes = 4 }, // animation
        .{ .reads = 1 | 4 }, // render
        .{ .after = bit(2) }, // barrier/submit
    });
    try std.testing.expectEqualSlices(Mask, &.{ 3, 4, 8 }, p.stages());
    try std.testing.expectEqual(@as(Mask, 3), p.dependencies[2]);
}
test "read-read is safe; explicit reverse dependencies are supported if no cycle" {
    const p = try plan(&.{ .{ .reads = 1, .after = bit(1) }, .{ .reads = 1 } });
    try std.testing.expectEqualSlices(Mask, &.{ 2, 1 }, p.stages());
}
test "cycles and invalid dependencies are rejected; empty and 64-node plans work" {
    try std.testing.expectError(error.Cycle, plan(&.{.{ .after = 1 }}));
    try std.testing.expectError(error.Cycle, plan(&.{ .{ .writes = 1, .after = 2 }, .{ .reads = 1 } }));
    try std.testing.expectError(error.UnknownDependency, plan(&.{.{ .after = 2 }}));
    try std.testing.expectEqual(@as(usize, 0), (try plan(&.{})).wave_count);
    const many: [64]System = @splat(.{});
    const all = try plan(&many);
    try std.testing.expectEqualSlices(Mask, &.{std.math.maxInt(Mask)}, all.stages());
    const too_many: [65]System = @splat(.{});
    try std.testing.expectError(error.TooManySystems, plan(&too_many));
}
