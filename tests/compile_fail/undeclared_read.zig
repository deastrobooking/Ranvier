//! Must not compile: a query may only read components it declared.
const rv = @import("ranvier");
const Position = struct { x: f32 };
const Velocity = struct { v: f32 };
const Health = struct { hp: u32 };
const World = rv.ecs.World(&.{ Position, Velocity, Health });

export fn entry() void {
    var chunk: World.Chunk(&.{Velocity}, &.{Position}) = undefined;
    _ = &chunk;
    _ = chunk.read(Health);
}
