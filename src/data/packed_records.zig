const std = @import("std");

/// Fixed-buffer sequence of [u32 little-endian length][payload] records.
/// A separate u32 offset index gives O(1) lookup. No implicit struct casting.
/// Borrowed byte slices live only while the buffers live; append never relocates.
pub const PackedRecords = struct {
    bytes: []u8,
    offsets: []u32,
    used: usize = 0,
    len: usize = 0,
    pub fn init(bytes: []u8, offsets: []u32) PackedRecords {
        return .{ .bytes = bytes, .offsets = offsets };
    }
    pub fn append(self: *PackedRecords, value: []const u8) error{ Full, RecordTooLarge }!usize {
        if (value.len > std.math.maxInt(u32) or self.used > std.math.maxInt(u32)) return error.RecordTooLarge;
        if (self.len >= self.offsets.len or self.used > self.bytes.len or self.bytes.len - self.used < 4 or value.len > self.bytes.len - self.used - 4) return error.Full;
        const i = self.len;
        const start = self.used;
        // memmove supports source bytes overlapping the destination payload.
        @memmove(self.bytes[start + 4 ..][0..value.len], value);
        std.mem.writeInt(u32, self.bytes[start..][0..4], @intCast(value.len), .little);
        self.offsets[i] = @intCast(start);
        self.used += 4 + value.len;
        self.len += 1;
        return i;
    }
    pub fn get(self: *const PackedRecords, i: usize) ?[]const u8 {
        if (i >= self.len or self.used > self.bytes.len or i >= self.offsets.len) return null;
        const start: usize = self.offsets[i];
        if (start > self.used or self.used - start < 4) return null;
        const n: usize = std.mem.readInt(u32, self.bytes[start..][0..4], .little);
        if (n > self.used - start - 4) return null;
        return self.bytes[start + 4 ..][0..n];
    }
    pub fn encoded(self: *const PackedRecords) []const u8 {
        return self.bytes[0..self.used];
    }
};

test "inline variable-size records and bounded failures" {
    var bytes: [16]u8 = undefined;
    var index: [3]u32 = undefined;
    var p = PackedRecords.init(&bytes, &index);
    try std.testing.expectEqual(@as(usize, 0), try p.append("abc"));
    try std.testing.expectEqual(@as(usize, 1), try p.append(""));
    try std.testing.expectEqualStrings("abc", p.get(0).?);
    try std.testing.expectEqualStrings("", p.get(1).?);
    try std.testing.expectError(error.Full, p.append("too long"));
    try std.testing.expectEqual(@as(usize, 11), p.encoded().len);
    _ = try p.append("x");
    try std.testing.expect(p.get(3) == null);
    try std.testing.expectError(error.Full, p.append(""));
}
