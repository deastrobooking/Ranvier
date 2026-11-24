//! Must not compile: masks only accept components in the world's registry.
const rv = @import("ranvier");
const Position = struct { x: f32 };
const Velocity = struct { v: f32 };
const Health = struct { hp: u32 };
const World = rv.ecs.World(&.{ Position, Velocity, Health });

const Unregistered = struct { n: u8 };

export fn entry() u64 {
    return World.mask(&.{Unregistered});
}
