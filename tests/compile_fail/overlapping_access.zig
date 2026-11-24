//! Must not compile: a component cannot be both read and written by one query.
const rv = @import("ranvier");
const Position = struct { x: f32 };
const Velocity = struct { v: f32 };
const Health = struct { hp: u32 };
const World = rv.ecs.World(&.{ Position, Velocity, Health });

export fn entry() void {
    var chunk: World.Chunk(&.{Position}, &.{Position}) = undefined;
    _ = &chunk;
}
