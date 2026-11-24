const kernel = @import("kernel.zig");
pub fn main() !void {
    try kernel.run(.aosoa);
}
