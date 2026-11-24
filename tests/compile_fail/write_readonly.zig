//! Must not compile: a read-only component cannot be borrowed writable.
const rv = @import("ranvier");
const Position = struct { x: f32 };
const Velocity = struct { v: f32 };
const Health = struct { hp: u32 };
const World = rv.ecs.World(&.{ Position, Velocity, Health });

export fn entry() void {
    var chunk: World.Chunk(&.{Velocity}, &.{Position}) = undefined;
    _ = &chunk;
    _ = chunk.write(Velocity);
}
