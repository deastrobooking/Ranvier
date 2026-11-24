//! Ranvier archetype ECS; single-threaded, bounded, explicit structural barrier.
const world = @import("world.zig");
pub const World = world.World;
pub const Entity = world.Entity;
pub const Mask = world.Mask;
pub const ArchetypeConfig = world.ArchetypeConfig;
pub const MutationError = world.MutationError;
pub const ConfigError = world.ConfigError;

test {
    _ = @import("tests.zig");
}
