const std = @import("std");

/// Borrowed fixed-buffer bump region. Never reallocates; no OS or heap calls.
/// Keep Region at a stable address while scopes exist. Do not copy owners.
/// Allocated memory is uninitialized; references expire at rewind/reset.
pub const Region = struct {
    const Self = @This();
    pub const Scope = struct {
        owner: *const Self,
        saved: usize,
        id: u64,
        parent: u64,
    };
    buffer: []u8,
    cursor: usize = 0,
    high_water: usize = 0,
    top: u64 = 0,
    serial: u64 = 0,

    pub fn init(buffer: []u8) Self {
        return .{ .buffer = buffer };
    }
    pub fn used(self: *const Self) usize {
        return self.cursor;
    }
    pub fn highWater(self: *const Self) usize {
        return self.high_water;
    }
    pub fn mark(self: *Self) error{ScopeExhausted}!Scope {
        if (self.serial == std.math.maxInt(u64)) return error.ScopeExhausted;
        self.serial += 1;
        const scope: Scope = .{ .owner = self, .saved = self.cursor, .id = self.serial, .parent = self.top };
        self.top = scope.id;
        return scope;
    }
    pub fn rewind(self: *Self, scope: Scope) error{InvalidScope}!void {
        if (scope.owner != self or self.top == 0 or self.top != scope.id or scope.saved > self.cursor) return error.InvalidScope;
        self.cursor = scope.saved;
        self.top = scope.parent;
    }
    pub fn reset(self: *Self) error{ActiveScope}!void {
        if (self.top != 0) return error.ActiveScope;
        self.cursor = 0;
    }
    pub fn alloc(self: *Self, comptime T: type, n: usize) error{ InvalidCount, OutOfMemory }![]T {
        if (@sizeOf(T) == 0 or n == 0) return error.InvalidCount;
        const size = std.math.mul(usize, @sizeOf(T), n) catch return error.OutOfMemory;
        const addr = std.math.add(usize, @intFromPtr(self.buffer.ptr), self.cursor) catch return error.OutOfMemory;
        const a = @alignOf(T);
        const padding = (a - addr % a) % a;
        const start = std.math.add(usize, self.cursor, padding) catch return error.OutOfMemory;
        if (start > self.buffer.len or size > self.buffer.len - start) return error.OutOfMemory;
        const bytes = self.buffer[start..][0..size];
        const ptr: [*]T = @ptrCast(@alignCast(bytes.ptr));
        self.cursor = start + size;
        self.high_water = @max(self.high_water, self.cursor);
        return ptr[0..n];
    }
};

test "region alignment, nested LIFO marks, and high water" {
    var buf: [129]u8 align(16) = undefined;
    var r = Region.init(buf[1..]);
    const outer = try r.mark();
    const words = try r.alloc(u64, 4);
    @memset(words, 9);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(words.ptr) % @alignOf(u64));
    const saved = r.used();
    const inner = try r.mark();
    _ = try r.alloc(u8, 17);
    try std.testing.expectError(error.InvalidScope, r.rewind(outer));
    try std.testing.expectError(error.ActiveScope, r.reset());
    try r.rewind(inner);
    try std.testing.expectEqual(saved, r.used());
    try std.testing.expectError(error.InvalidScope, r.rewind(inner));
    try r.rewind(outer);
    try std.testing.expectEqual(@as(usize, 0), r.used());
    try std.testing.expect(r.highWater() >= 49);
    try std.testing.expectError(error.OutOfMemory, r.alloc(u64, std.math.maxInt(usize)));
    try std.testing.expectEqual(@as(usize, 0), r.used());
    try std.testing.expectError(error.InvalidCount, r.alloc(u8, 0));
}

test "region rejects foreign mark and capacity overflow" {
    var a: [8]u8 = undefined;
    var b: [8]u8 = undefined;
    var r = Region.init(&a);
    var s = Region.init(&b);
    const m = try r.mark();
    const other = try s.mark();
    try std.testing.expectError(error.InvalidScope, r.rewind(other));
    try std.testing.expectError(error.OutOfMemory, r.alloc(u8, 9));
    try r.rewind(m);
    try s.rewind(other);
}
