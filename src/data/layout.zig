const std = @import("std");

/// Fixed-capacity layout tables. All operations after init are allocation-free.
/// Tables own backing storage; copying a table is not supported. Values are
/// shallow Zig values: resource destruction, synchronization and view lifetimes
/// are caller obligations. Swap removal invalidates row identity.
pub const Layout = enum { aos, soa, aosoa };
pub fn Table(comptime T: type, comptime layout: Layout, comptime lanes: usize) type {
    return switch (layout) {
        .aos => AoS(T),
        .soa => SoA(T),
        .aosoa => AoSoA(T, lanes),
    };
}

pub fn AoS(comptime T: type) type {
    return struct {
        const Self = @This();
        storage: []T,
        allocator: std.mem.Allocator,
        len: usize = 0,
        pub fn init(a: std.mem.Allocator, cap: usize) !Self {
            return .{ .storage = try a.alloc(T, cap), .allocator = a };
        }
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.storage);
            self.* = undefined;
        }
        pub fn capacity(self: *const Self) usize {
            return self.storage.len;
        }
        pub fn count(self: *const Self) usize {
            return self.len;
        }
        pub fn storageBytes(self: *const Self) usize {
            return self.storage.len * @sizeOf(T);
        }
        pub fn append(self: *Self, value: T) error{Full}!void {
            if (self.len >= self.storage.len) return error.Full;
            self.storage[self.len] = value;
            self.len += 1;
        }
        pub fn get(self: *const Self, i: usize) ?T {
            if (i >= self.len) return null;
            return self.storage[i];
        }
        pub fn set(self: *Self, i: usize, value: T) bool {
            if (i >= self.len) return false;
            self.storage[i] = value;
            return true;
        }
        pub fn swapRemove(self: *Self, i: usize) ?T {
            const old = self.get(i) orelse return null;
            self.len -= 1;
            if (i != self.len) self.storage[i] = self.storage[self.len];
            return old;
        }
        pub fn rows(self: *Self) []T {
            return self.storage[0..self.len];
        }
    };
}

pub fn SoA(comptime T: type) type {
    const List = std.MultiArrayList(T);
    return struct {
        const Self = @This();
        list: List,
        allocator: std.mem.Allocator,
        limit: usize,
        pub fn init(a: std.mem.Allocator, cap: usize) !Self {
            return .{ .list = try List.initCapacity(a, cap), .allocator = a, .limit = cap };
        }
        pub fn deinit(self: *Self) void {
            self.list.deinit(self.allocator);
            self.* = undefined;
        }
        pub fn capacity(self: *const Self) usize {
            return self.limit;
        }
        pub fn count(self: *const Self) usize {
            return self.list.len;
        }
        pub fn storageBytes(self: *const Self) usize {
            return List.capacityInBytes(self.list.capacity);
        }
        pub fn append(self: *Self, value: T) error{Full}!void {
            if (self.list.len >= self.limit) return error.Full;
            self.list.appendAssumeCapacity(value);
        }
        pub fn get(self: *const Self, i: usize) ?T {
            if (i >= self.list.len) return null;
            return self.list.get(i);
        }
        pub fn set(self: *Self, i: usize, value: T) bool {
            if (i >= self.list.len) return false;
            self.list.set(i, value);
            return true;
        }
        pub fn swapRemove(self: *Self, i: usize) ?T {
            const old = self.get(i) orelse return null;
            self.list.swapRemove(i);
            return old;
        }
        /// Column slices are valid only while their table and row membership live.
        pub fn column(self: *Self, comptime name: []const u8) []@FieldType(T, name) {
            if (self.list.len == 0) return &.{};
            return self.list.items(@field(List.Field, name));
        }
    };
}

/// Zig 0.17 reflection: one native struct of fixed-width field arrays per block.
/// Not a persistent ABI. No cross-block contiguous field slice exists.
fn BlockType(comptime T: type, comptime lanes: usize) type {
    if (lanes == 0) @compileError("AoSoA lanes must be positive");
    const info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => @compileError("AoSoA requires a struct"),
    };
    if (info.is_tuple or info.field_names.len == 0) @compileError("AoSoA requires a nonempty named-field struct");
    var names: [info.field_names.len][]const u8 = undefined;
    var types: [info.field_names.len]type = undefined;
    var attrs: [info.field_names.len]std.lang.Type.Struct.FieldAttributes = undefined;
    for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, a, i| {
        if (a.@"comptime" or @sizeOf(F) == 0) @compileError("AoSoA fields must have nonzero runtime storage");
        names[i] = name;
        types[i] = [lanes]F;
        attrs[i] = .{ .@"align" = a.@"align" };
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

pub fn AoSoA(comptime T: type, comptime lanes: usize) type {
    const Block = BlockType(T, lanes);
    const fields = @typeInfo(T).@"struct".field_names;
    return struct {
        const Self = @This();
        blocks: []Block,
        allocator: std.mem.Allocator,
        limit: usize,
        len: usize = 0,
        pub const block_width = lanes;
        pub fn init(a: std.mem.Allocator, cap: usize) !Self {
            const n = cap / lanes + @as(usize, @intFromBool(cap % lanes != 0));
            return .{ .blocks = try a.alloc(Block, n), .allocator = a, .limit = cap };
        }
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.blocks);
            self.* = undefined;
        }
        pub fn capacity(self: *const Self) usize {
            return self.limit;
        }
        pub fn count(self: *const Self) usize {
            return self.len;
        }
        pub fn storageBytes(self: *const Self) usize {
            return self.blocks.len * @sizeOf(Block);
        }
        pub fn activeBlocks(self: *const Self) usize {
            return self.len / lanes + @as(usize, @intFromBool(self.len % lanes != 0));
        }
        fn store(self: *Self, i: usize, value: T) void {
            inline for (fields) |f| @field(self.blocks[i / lanes], f)[i % lanes] = @field(value, f);
        }
        pub fn append(self: *Self, value: T) error{Full}!void {
            if (self.len >= self.limit) return error.Full;
            self.store(self.len, value);
            self.len += 1;
        }
        pub fn get(self: *const Self, i: usize) ?T {
            if (i >= self.len) return null;
            var value: T = undefined;
            inline for (fields) |f| @field(value, f) = @field(self.blocks[i / lanes], f)[i % lanes];
            return value;
        }
        pub fn set(self: *Self, i: usize, value: T) bool {
            if (i >= self.len) return false;
            self.store(i, value);
            return true;
        }
        pub fn swapRemove(self: *Self, i: usize) ?T {
            const old = self.get(i) orelse return null;
            if (i != self.len - 1) self.store(i, self.get(self.len - 1).?);
            self.len -= 1;
            return old;
        }
        pub fn blockColumn(self: *Self, block: usize, comptime name: []const u8) ?[]@FieldType(T, name) {
            if (block >= self.activeBlocks()) return null;
            const n = @min(lanes, self.len - block * lanes);
            return @field(self.blocks[block], name)[0..n];
        }
    };
}

test "identical layout operations across AoS, SoA and AoSoA" {
    const P = struct { x: u32, health: u16 };
    inline for (.{ Layout.aos, Layout.soa, Layout.aosoa }) |kind| {
        var t = try Table(P, kind, 4).init(std.testing.allocator, 5);
        defer t.deinit();
        for (0..5) |i| try t.append(.{ .x = @intCast(i), .health = 100 });
        try std.testing.expectError(error.Full, t.append(.{ .x = 5, .health = 10 }));
        try std.testing.expect(t.set(2, .{ .x = 42, .health = 3 }));
        try std.testing.expectEqual(@as(u32, 42), t.get(2).?.x);
        try std.testing.expectEqual(@as(u32, 1), t.swapRemove(1).?.x);
        try std.testing.expectEqual(@as(u32, 4), t.get(1).?.x);
        try std.testing.expect(t.get(4) == null);
        try std.testing.expectEqual(@as(usize, 4), t.count());
    }
}

test "columns and partial blocks expose only live rows" {
    const P = struct { x: f32, v: f32 };
    var s = try SoA(P).init(std.testing.allocator, 5);
    defer s.deinit();
    var b = try AoSoA(P, 4).init(std.testing.allocator, 5);
    defer b.deinit();
    for (0..5) |_| {
        try s.append(.{ .x = 0, .v = 2 });
        try b.append(.{ .x = 0, .v = 2 });
    }
    for (s.column("x"), s.column("v")) |*x, v| x.* += v;
    for (0..b.activeBlocks()) |block| {
        for (b.blockColumn(block, "x").?, b.blockColumn(block, "v").?) |*x, v| x.* += v;
    }
    try std.testing.expectEqual(@as(usize, 1), b.blockColumn(1, "x").?.len);
    try std.testing.expect(b.blockColumn(2, "x") == null);
    for (0..5) |i| try std.testing.expectEqual(s.get(i).?.x, b.get(i).?.x);
}
