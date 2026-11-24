const std = @import("std");

pub const Error = error{ OutOfBounds, Overflow, Misaligned, InvalidValue };

/// An explicitly encoded little-endian integer or IEEE floating scalar.
/// Never casts file bytes to a native pointer or reads native struct padding.
pub fn Scalar(comptime T: type) type {
    const Int = switch (T) {
        u8, u16, u32, u64, i8, i16, i32, i64 => T,
        f32 => u32,
        f64 => u64,
        else => @compileError("unsupported binary scalar"),
    };
    return struct {
        pub const Value = T;
        pub const encoded_size: usize = @sizeOf(Int);
        pub const file_alignment: usize = 1;
        pub fn decode(bytes: []const u8) Error!T {
            if (bytes.len != encoded_size) return error.OutOfBounds;
            const raw = std.mem.readInt(Int, bytes[0..encoded_size], .little);
            return @bitCast(raw);
        }
        pub fn encode(bytes: []u8, value: T) Error!void {
            if (bytes.len != encoded_size) return error.OutOfBounds;
            std.mem.writeInt(Int, bytes[0..encoded_size], @bitCast(value), .little);
        }
    };
}

fn requireOffset(comptime W: type) void {
    if (W != u8 and W != u16 and W != u32 and W != u64) @compileError("offset must be u8/u16/u32/u64");
}
fn requireCodec(comptime C: type) void {
    if (C.encoded_size == 0 or C.file_alignment == 0 or C.encoded_size % C.file_alignment != 0) @compileError("invalid codec geometry");
}
fn offsetValue(offset: anytype) Error!usize {
    if (offset > std.math.maxInt(usize)) return error.Overflow;
    return @intCast(offset);
}

/// Pool/base-relative byte offset. Zero is valid. Optional links use ?RelRef.
/// Codec is a trusted wire decoder, not a native struct type.
/// Callers must supply the intended domain. The offset has no global identity.
pub fn RelRef(comptime Codec: type, comptime W: type) type {
    comptime {
        requireOffset(W);
        requireCodec(Codec);
    }
    return struct {
        offset: W,
        pub fn resolve(self: @This(), domain: []const u8) Error!Codec.Value {
            const start = try offsetValue(self.offset);
            if (start % Codec.file_alignment != 0) return error.Misaligned;
            if (start > domain.len or Codec.encoded_size > domain.len - start) return error.OutOfBounds;
            return Codec.decode(domain[start..][0..Codec.encoded_size]);
        }
    };
}

/// Counted relative span. Validation is O(1) for extent and alignment only;
/// validateAll additionally decodes each element to check codec invariants.
/// Access rechecks bounds and invokes the codec rather than forging typed memory.
pub fn RelSlice(comptime Codec: type, comptime W: type) type {
    comptime {
        requireOffset(W);
        requireCodec(Codec);
    }
    return struct {
        const Self = @This();
        offset: W,
        count: u32,
        pub fn bytes(self: Self, domain: []const u8) Error![]const u8 {
            const start = try offsetValue(self.offset);
            if (start % Codec.file_alignment != 0) return error.Misaligned;
            const n = std.math.mul(usize, @as(usize, self.count), Codec.encoded_size) catch return error.Overflow;
            if (start > domain.len or n > domain.len - start) return error.OutOfBounds;
            return domain[start..][0..n];
        }
        pub fn at(self: Self, domain: []const u8, index: usize) Error!Codec.Value {
            if (index >= self.count) return error.OutOfBounds;
            const span = try self.bytes(domain);
            return Codec.decode(span[index * Codec.encoded_size ..][0..Codec.encoded_size]);
        }
        pub fn validateAll(self: Self, domain: []const u8) Error!void {
            const span = try self.bytes(domain);
            for (0..self.count) |i| _ = try Codec.decode(span[i * Codec.encoded_size ..][0..Codec.encoded_size]);
        }
    };
}

test "relative references survive relocation and reject invalid extent" {
    var a: [12]u8 = @splat(0);
    try Scalar(u32).encode(a[4..8], 0x12345678);
    const ref: RelRef(Scalar(u32), u32) = .{ .offset = 4 };
    const b = a;
    try std.testing.expectEqual(@as(u32, 0x12345678), try ref.resolve(&a));
    try std.testing.expectEqual(@as(u32, 0x12345678), try ref.resolve(&b));
    const bad: RelRef(Scalar(u32), u32) = .{ .offset = 10 };
    try std.testing.expectError(error.OutOfBounds, bad.resolve(&a));
    const span: RelSlice(Scalar(u32), u32) = .{ .offset = 4, .count = 2 };
    try span.validateAll(&a);
    try std.testing.expectEqual(@as(u32, 0), try span.at(&a, 1));
    try std.testing.expectError(error.OutOfBounds, span.at(&a, 2));
    const long: RelSlice(Scalar(u32), u32) = .{ .offset = 4, .count = 3 };
    try std.testing.expectError(error.OutOfBounds, long.bytes(&a));
}

test "wire codec enforces file alignment independently of host pointer alignment" {
    const AlignedU32 = struct {
        pub const Value = u32;
        pub const encoded_size = 4;
        pub const file_alignment = 4;
        pub fn decode(bytes: []const u8) Error!u32 {
            return Scalar(u32).decode(bytes);
        }
    };
    const domain: [9]u8 = @splat(0);
    const ref: RelRef(AlignedU32, u16) = .{ .offset = 1 };
    try std.testing.expectError(error.Misaligned, ref.resolve(&domain));
    const valid: RelRef(AlignedU32, u16) = .{ .offset = 4 };
    try std.testing.expectEqual(@as(u32, 0), try valid.resolve(&domain));
    const huge: RelSlice(Scalar(u64), u64) = .{ .offset = 0, .count = 0xffffffff };
    if (@sizeOf(usize) == 4) {
        try std.testing.expectError(error.Overflow, huge.bytes(&domain));
    } else {
        try std.testing.expectError(error.OutOfBounds, huge.bytes(&domain));
    }
}
