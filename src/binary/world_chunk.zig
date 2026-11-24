const std = @import("std");
const rel = @import("relative.zig");

/// RVC1 demonstration schema. A compact immutable binary scene chunk.
/// File representation is independent of native Zig ABI. See docs/FORMAT.md.
pub const header_size: usize = 32;
pub const node_size: usize = 24;
pub const version: u16 = 1;
pub const Error = rel.Error || error{ InvalidMagic, InvalidVersion, InvalidHeader, InvalidLayout, TooLarge };
pub const NodeInput = struct { id: u32, position: [3]f32, label: []const u8 };
pub const Node = struct {
    id: u32,
    position: [3]f32,
    label: rel.RelSlice(rel.Scalar(u8), u32),
};

fn read32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn write32(b: []u8, off: usize, n: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], n, .little);
}
fn finite(p: [3]f32) bool {
    for (p) |x| if (!std.math.isFinite(x)) return false;
    return true;
}
fn decodeNode(b: []const u8) Error!Node {
    if (b.len != node_size) return error.OutOfBounds;
    const pos: [3]f32 = .{ @bitCast(read32(b, 4)), @bitCast(read32(b, 8)), @bitCast(read32(b, 12)) };
    if (!finite(pos)) return error.InvalidValue;
    return .{ .id = read32(b, 0), .position = pos, .label = .{ .offset = read32(b, 16), .count = read32(b, 20) } };
}

/// Non-owning view. Caller must keep bytes alive and immutable (including any
/// file mapping and other aliases). No allocator, no object graph construction.
/// Label offsets are relative to the label blob, not to the entire file.
pub const View = struct {
    backing: []const u8,
    nodes: []const u8,
    labels: []const u8,
    count: usize,
    pub fn open(bytes: []const u8) Error!View {
        if (bytes.len < header_size) return error.InvalidHeader;
        if (!std.mem.eql(u8, bytes[0..4], "RVC1")) return error.InvalidMagic;
        if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.InvalidVersion;
        if (std.mem.readInt(u16, bytes[6..8], .little) != header_size or read32(bytes, 28) != 0) return error.InvalidHeader;
        if (bytes.len > std.math.maxInt(u32) or read32(bytes, 24) != bytes.len) return error.InvalidLayout;
        const count: usize = read32(bytes, 8);
        if (read32(bytes, 12) != header_size) return error.InvalidLayout;
        const node_bytes = std.math.mul(usize, count, node_size) catch return error.Overflow;
        if (node_bytes > bytes.len - header_size) return error.OutOfBounds;
        const label_start = header_size + node_bytes;
        if (read32(bytes, 16) != label_start or read32(bytes, 20) != bytes.len - label_start) return error.InvalidLayout;
        const view: View = .{ .backing = bytes, .nodes = bytes[header_size..label_start], .labels = bytes[label_start..], .count = count };
        for (0..count) |i| {
            const n = try view.node(i);
            _ = try n.label.bytes(view.labels);
        }
        return view;
    }
    pub fn node(self: View, i: usize) Error!Node {
        if (i >= self.count) return error.OutOfBounds;
        // count and extent were checked by open; decoded fields are checked again.
        return decodeNode(self.nodes[i * node_size ..][0..node_size]);
    }
    pub fn label(self: View, i: usize) Error![]const u8 {
        const n = try self.node(i);
        return n.label.bytes(self.labels);
    }
};

/// One allocation; writes directly into the final wire buffer. Caller frees it.
/// IDs need not be unique; labels are byte strings, not assumed UTF-8.
pub fn encode(a: std.mem.Allocator, records: []const NodeInput) ![]u8 {
    if (records.len > std.math.maxInt(u32)) return error.TooLarge;
    const node_bytes = std.math.mul(usize, records.len, node_size) catch return error.TooLarge;
    const label_start = std.math.add(usize, header_size, node_bytes) catch return error.TooLarge;
    var total = label_start;
    for (records) |n| {
        if (!finite(n.position)) return error.InvalidValue;
        total = std.math.add(usize, total, n.label.len) catch return error.TooLarge;
    }
    if (total > std.math.maxInt(u32)) return error.TooLarge;
    const bytes = try a.alloc(u8, total);
    @memcpy(bytes[0..4], "RVC1");
    std.mem.writeInt(u16, bytes[4..6], version, .little);
    std.mem.writeInt(u16, bytes[6..8], header_size, .little);
    write32(bytes, 8, @intCast(records.len));
    write32(bytes, 12, header_size);
    write32(bytes, 16, @intCast(label_start));
    write32(bytes, 20, @intCast(total - label_start));
    write32(bytes, 24, @intCast(total));
    write32(bytes, 28, 0);
    var top = label_start;
    for (records, 0..) |n, i| {
        const b = bytes[header_size + i * node_size ..][0..node_size];
        write32(b, 0, n.id);
        for (n.position, 0..) |x, axis| write32(b, 4 + axis * 4, @bitCast(x));
        write32(b, 16, @intCast(top - label_start));
        write32(b, 20, @intCast(n.label.len));
        @memcpy(bytes[top..][0..n.label.len], n.label);
        top += n.label.len;
    }
    return bytes;
}

test "RVC1 round trip; all truncations fail; invalid relative label rejected" {
    const a = std.testing.allocator;
    const bytes = try encode(a, &.{ .{ .id = 1, .position = .{ 1, 2, 3 }, .label = "tree" }, .{ .id = 2, .position = .{ 4, 5, 6 }, .label = "" } });
    defer a.free(bytes);
    const view = try View.open(bytes);
    try std.testing.expectEqual(@as(usize, 2), view.count);
    try std.testing.expectEqual(@as(f32, 5), (try view.node(1)).position[1]);
    try std.testing.expectEqualStrings("tree", try view.label(0));
    try std.testing.expectEqualStrings("", try view.label(1));
    try std.testing.expectError(error.OutOfBounds, view.node(2));
    for (0..bytes.len) |n| {
        if (View.open(bytes[0..n])) |_| return error.UnexpectedAcceptedTruncation else |_| {}
    }
    const relocated = try a.dupe(u8, bytes);
    defer a.free(relocated);
    try std.testing.expectEqualStrings("tree", try (try View.open(relocated)).label(0));
    write32(relocated, header_size + 16, 0xffffffff);
    try std.testing.expectError(error.OutOfBounds, View.open(relocated));
    write32(relocated, header_size + 16, 0);
    write32(relocated, header_size + 4, 0x7fc00000);
    try std.testing.expectError(error.InvalidValue, View.open(relocated));
}

test "empty scene and header rejection" {
    const a = std.testing.allocator;
    const bytes = try encode(a, &.{});
    defer a.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), (try View.open(bytes)).count);
    bytes[0] = 'X';
    try std.testing.expectError(error.InvalidMagic, View.open(bytes));
    bytes[0] = 'R';
    bytes[4] = 2;
    try std.testing.expectError(error.InvalidVersion, View.open(bytes));
}

test "independently generated wire-format fixture" {
    const wire = @embedFile("fixtures/two_nodes.rvc");
    const view = try View.open(wire);
    try std.testing.expectEqual(@as(usize, 2), view.count);
    try std.testing.expectEqual(@as(u32, 7), (try view.node(0)).id);
    try std.testing.expectEqual(@as(f32, -2), (try view.node(0)).position[1]);
    try std.testing.expectEqualStrings("child", try view.label(1));
    const a = std.testing.allocator;
    const encoded = try encode(a, &.{ .{ .id = 7, .position = .{ 1.25, -2, 3 }, .label = "root" }, .{ .id = 9, .position = .{ 4, 5, 6 }, .label = "child" } });
    defer a.free(encoded);
    try std.testing.expectEqualSlices(u8, wire, encoded);
}
