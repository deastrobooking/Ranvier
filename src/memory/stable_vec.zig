const std = @import("std");

/// Append-only vector over caller-provided initialized-or-uninitialized storage.
/// Growth up to capacity never relocates any item. No individual removal.
/// The caller owns backing storage and its lifetime; not a virtual-memory stack.
pub fn StableVec(comptime T: type) type {
    return struct {
        const Self = @This();
        storage: []T,
        len: usize = 0,
        pub fn init(buffer: []T) Self {
            return .{ .storage = buffer };
        }
        pub fn capacity(self: *const Self) usize {
            return self.storage.len;
        }
        pub fn append(self: *Self, value: T) error{Full}!*T {
            if (self.len >= self.storage.len) return error.Full;
            const item = &self.storage[self.len];
            item.* = value;
            self.len += 1;
            return item;
        }
        pub fn get(self: *Self, i: usize) ?*T {
            if (i >= self.len) return null;
            return &self.storage[i];
        }
        pub fn items(self: *const Self) []const T {
            return self.storage[0..self.len];
        }
    };
}

test "stable references survive append; full is explicit" {
    var backing: [3]u32 = undefined;
    var v = StableVec(u32).init(&backing);
    const p = try v.append(11);
    _ = try v.append(22);
    _ = try v.append(33);
    try std.testing.expect(p == v.get(0).?);
    p.* = 44;
    try std.testing.expectEqual(@as(u32, 44), v.items()[0]);
    try std.testing.expect(v.get(3) == null);
    try std.testing.expectError(error.Full, v.append(55));
}
