const kernel = @import("ecs_kernel.zig");
pub fn main() !void {
    try kernel.run(true);
}
