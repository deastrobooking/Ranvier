const std = @import("std");

pub const Field = struct { offset: usize, size: usize };
/// Exact distinct cache-line address count for monotonically ordered,
/// nonoverlapping byte fields of fixed-stride records. NOT a cache-miss model.
/// O(rows * fields), constant auxiliary storage. base is a byte address.
pub fn touchedLines(base: usize, rows: usize, stride: usize, fields: []const Field, line_size: usize) error{ InvalidLayout, Overflow }!usize {
    if (line_size == 0 or stride == 0) return error.InvalidLayout;
    var prev_end: usize = 0;
    for (fields) |f| {
        if (f.size == 0 or f.offset < prev_end or f.offset > stride or f.size > stride - f.offset) return error.InvalidLayout;
        prev_end = f.offset + f.size;
    }
    if (fields.len == 0 or rows == 0) return 0;
    // Reject overflowing layouts before scanning.
    const last_base = try std.math.add(usize, base, try std.math.mul(usize, rows - 1, stride));
    _ = try std.math.add(usize, last_base, prev_end - 1);
    var total: usize = 0;
    var last: ?usize = null;
    for (0..rows) |i| {
        const row = base + i * stride;
        for (fields) |f| {
            const lo = (row + f.offset) / line_size;
            const hi = (row + (f.offset + f.size - 1)) / line_size;
            const new_lines = if (last) |l| blk: {
                if (hi <= l) break :blk 0;
                if (lo <= l) break :blk hi - l;
                break :blk hi - lo + 1;
            } else hi - lo + 1;
            total = try std.math.add(usize, total, new_lines);
            last = hi;
        }
    }
    return total;
}

test "cache lines are a union, not a count per record" {
    try std.testing.expectEqual(@as(usize, 1), try touchedLines(0, 8, 8, &.{.{ .offset = 0, .size = 4 }}, 64));
    try std.testing.expectEqual(@as(usize, 2), try touchedLines(60, 1, 8, &.{.{ .offset = 0, .size = 8 }}, 64));
    try std.testing.expectEqual(@as(usize, 2), try touchedLines(0, 2, 64, &.{.{ .offset = 4, .size = 4 }}, 64));
    try std.testing.expectEqual(@as(usize, 1), try touchedLines(0, 1, 64, &.{ .{ .offset = 0, .size = 4 }, .{ .offset = 48, .size = 4 } }, 64));
    try std.testing.expectError(error.InvalidLayout, touchedLines(0, 1, 8, &.{.{ .offset = 7, .size = 2 }}, 64));
    try std.testing.expectError(error.Overflow, touchedLines(std.math.maxInt(usize), 2, 8, &.{.{ .offset = 0, .size = 4 }}, 64));
}
