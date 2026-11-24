const std = @import("std");
const rv = @import("ranvier");
const N = 1_000_000;
const rounds = 40;
const Record = extern struct { x: u32, v: u32, cold: [56]u8 };

/// Identical workload per executable, with whole-record construction and
/// checksum outside the hot loop. Integer arithmetic gives exact parity.
pub fn run(comptime layout: rv.data.Layout) !void {
    var t = try rv.data.Table(Record, layout, 16).init(std.heap.page_allocator, N);
    defer t.deinit();
    for (0..N) |i| {
        const value: u32 = @intCast(i);
        try t.append(.{ .x = value, .v = value % 17 + 1, .cold = @splat(@as(u8, @truncate(value))) });
    }
    for (0..rounds) |_| {
        switch (layout) {
            .aos => for (t.rows()) |*r| {
                r.x +%= r.v;
            },
            .soa => for (t.column("x"), t.column("v")) |*x, v| {
                x.* +%= v;
            },
            .aosoa => for (0..t.activeBlocks()) |block| {
                for (t.blockColumn(block, "x").?, t.blockColumn(block, "v").?) |*x, v| x.* +%= v;
            },
        }
    }
    var checksum: u64 = 0;
    // Read every cold field once; include it to retain initialized payloads.
    for (0..N) |i| {
        const row = t.get(i).?;
        checksum +%= row.x;
        checksum +%= row.cold[0];
    }
    std.debug.print("RESULT {s} {d} {d} {d} {d}\n", .{ @tagName(layout), N, rounds, t.storageBytes(), checksum });
}
