const std = @import("std");

/// Fixed-capacity pool with non-relocating slots and generation-checked identity.
/// domain must be unique among all pool lifetimes whose handles may coexist.
/// Not thread-safe. Owning values must be removed/cleaned up by the caller.
pub fn SlotMap(comptime T: type) type {
    return struct {
        const Self = @This();
        const none = std.math.maxInt(u32);
        pub const Value = T;
        pub const Handle = struct {
            domain: u64,
            index: u32,
            generation: u32,
        };
        const Slot = struct {
            value: T = undefined,
            generation: u32 = 1,
            next: u32 = none,
            occupied: bool = false,
        };
        pub const Entry = struct { handle: Handle, value: T };

        slots: []Slot,
        allocator: std.mem.Allocator,
        domain: u64,
        head: u32,
        live: usize = 0,
        retired: usize = 0,

        pub fn init(a: std.mem.Allocator, cap: usize, domain: u64) !Self {
            if (domain == 0) return error.InvalidDomain;
            if (cap > none) return error.CapacityOverflow;
            const slots = try a.alloc(Slot, cap);
            for (slots, 0..) |*s, i| {
                s.* = .{ .next = if (i + 1 < cap) @intCast(i + 1) else none };
            }
            return .{ .slots = slots, .allocator = a, .domain = domain, .head = if (cap == 0) none else 0 };
        }
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.slots);
            self.* = undefined;
        }
        pub fn count(self: *const Self) usize {
            return self.live;
        }
        pub fn capacity(self: *const Self) usize {
            return self.slots.len;
        }
        pub fn retiredCount(self: *const Self) usize {
            return self.retired;
        }
        pub fn insert(self: *Self, value: T) error{Full}!Handle {
            if (self.head == none) return error.Full;
            const i = self.head;
            const s = &self.slots[i];
            self.head = s.next;
            s.next = none;
            s.value = value;
            s.occupied = true;
            self.live += 1;
            return .{ .domain = self.domain, .index = i, .generation = s.generation };
        }
        pub fn contains(self: *const Self, h: Handle) bool {
            if (h.domain != self.domain or h.index >= self.slots.len) return false;
            const s = &self.slots[h.index];
            return s.occupied and s.generation == h.generation;
        }
        /// Copy-out, not an arena borrow; no pointer into a reusable slot escapes.
        pub fn get(self: *const Self, h: Handle) ?T {
            if (!self.contains(h)) return null;
            return self.slots[h.index].value;
        }
        pub fn set(self: *Self, h: Handle, value: T) bool {
            if (!self.contains(h)) return false;
            self.slots[h.index].value = value;
            return true;
        }
        /// Returns the old value. Retires the slot on generation exhaustion.
        pub fn remove(self: *Self, h: Handle) ?T {
            if (!self.contains(h)) return null;
            const s = &self.slots[h.index];
            const value = s.value;
            s.occupied = false;
            s.value = undefined;
            self.live -= 1;
            if (s.generation == std.math.maxInt(u32)) {
                self.retired += 1;
            } else {
                s.generation += 1;
                s.next = self.head;
                self.head = h.index;
            }
            return value;
        }
        /// Scan by physical slot. Mutating the pool during a scan is unsupported.
        pub fn next(self: *const Self, cursor: *usize) ?Entry {
            while (cursor.* < self.slots.len) {
                const i = cursor.*;
                cursor.* += 1;
                const s = &self.slots[i];
                if (s.occupied) return .{ .handle = .{ .domain = self.domain, .index = @intCast(i), .generation = s.generation }, .value = s.value };
            }
            return null;
        }
    };
}

test "slot reuse rejects stale, out of range, wrong domain, double removal" {
    const Pool = SlotMap(u32);
    var p = try Pool.init(std.testing.allocator, 2, 1);
    defer p.deinit();
    const a = try p.insert(11);
    const b = try p.insert(22);
    try std.testing.expectError(error.Full, p.insert(33));
    try std.testing.expectEqual(@as(?u32, 11), p.remove(a));
    try std.testing.expect(p.remove(a) == null);
    const c = try p.insert(33);
    try std.testing.expectEqual(a.index, c.index);
    try std.testing.expect(a.generation != c.generation);
    try std.testing.expect(p.get(a) == null);
    try std.testing.expectEqual(@as(?u32, 22), p.get(b));
    try std.testing.expect(p.get(.{ .domain = 2, .index = c.index, .generation = c.generation }) == null);
    try std.testing.expect(p.get(.{ .domain = 1, .index = 200, .generation = 1 }) == null);
    try std.testing.expect(p.set(c, 44));
    try std.testing.expectEqual(@as(?u32, 44), p.get(c));
    var cursor: usize = 0;
    var n: usize = 0;
    while (p.next(&cursor)) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "slot generation exhaustion retires rather than wraps" {
    var p = try SlotMap(u8).init(std.testing.allocator, 1, 7);
    defer p.deinit();
    p.slots[0].generation = std.math.maxInt(u32);
    const h = try p.insert(9);
    try std.testing.expectEqual(@as(?u8, 9), p.remove(h));
    try std.testing.expectEqual(@as(usize, 1), p.retiredCount());
    try std.testing.expectError(error.Full, p.insert(10));
}

test "zero capacity, zero domain" {
    try std.testing.expectError(error.InvalidDomain, SlotMap(u8).init(std.testing.allocator, 1, 0));
    var p = try SlotMap(u8).init(std.testing.allocator, 0, 5);
    defer p.deinit();
    try std.testing.expectError(error.Full, p.insert(0));
}

test "deterministic churn preserves live identities and rejects stale handles" {
    const P = SlotMap(u32);
    var pool = try P.init(std.testing.allocator, 32, 92);
    defer pool.deinit();
    var live: [32]?P.Handle = @splat(null);
    var stale: [32]?P.Handle = @splat(null);
    var values: [32]u32 = @splat(0);
    var state: u32 = 0x9e3779b9;
    for (0..4096) |step| {
        state = state *% 1664525 +% 1013904223;
        const i: usize = @intCast((state >> 16) % 32);
        if (live[i]) |h| {
            try std.testing.expectEqual(@as(?u32, values[i]), pool.remove(h));
            stale[i] = h;
            live[i] = null;
        } else {
            values[i] = @intCast(step);
            live[i] = try pool.insert(values[i]);
        }
        var n: usize = 0;
        for (live, stale, values) |h, old, expected| {
            if (h) |current| {
                n += 1;
                try std.testing.expectEqual(@as(?u32, expected), pool.get(current));
            }
            if (old) |dead| try std.testing.expect(!pool.contains(dead));
        }
        try std.testing.expectEqual(n, pool.count());
    }
}
