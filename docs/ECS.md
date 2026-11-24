# Ranvier ECS — Architecture and API reference

**v0.2.0 | Experimental native Zig | Archetype storage and structural barriers**

The ECS is a bounded, single-threaded implementation of the Ranvier data-oriented layout proposal. It reuses `memory.SlotMap(Location)` for identity and has no external packages. It separates entity identity from row address, component representation from lifetime, and iteration from structural mutation.

## 1. World construction and identity

```zig
const rv = @import("ranvier");
const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Health = struct { hp: u32 };
const W = rv.ecs.World(&.{ Position, Velocity, Health });

var world = try W.init(allocator, 1024, 1, &.{
    .{ .mask = W.mask(&.{Position}), .capacity = 512 },
    .{ .mask = W.mask(&.{ Position, Velocity }), .capacity = 512 },
    .{ .mask = W.mask(&.{ Position, Velocity, Health }), .capacity = 128 },
    .{ .mask = W.mask(&.{ Position, Health }), .capacity = 128 },
});
defer world.deinit() catch unreachable;
const e = try world.spawn(.{
    Position{ .x = 0, .y = 0 }, Velocity{ .x = 3, .y = 1 },
});
try world.add(e, Health{ .hp = 100 });
```

The registry contains 1–64 distinct, nonzero-sized runtime types. Bit `i` identifies registry entry `i`; masks are not portable across registries. Compile-time `W.mask` rejects duplicate or unregistered types. Components are plain copy-by-value values; resource ownership and pointed-to lifetimes remain caller obligations. Tags with zero-sized types, destructors, dynamic component registration and automatic type-wide storage transformations are not implemented.

`init` takes the maximum number of live entities across the world, a nonzero domain unique among all world lifetimes with possibly coexisting handles, and a list of unique archetype masks with capacities. Each archetype gets exactly the typed columns specified by its mask plus its dense ID column. Only present columns are allocated. Explicit capacities avoid allocation after setup; the sum of archetype capacities may exceed directory capacity and migration can fail even if the world has free entity slots. Configure empty archetype mask `0` if entities with no components must exist. No auto-creation or expansion of archetypes.

An entity handle is `(domain: u64, index: u32, generation: u32)`. Directory slots never wrap their generation; on exhaustion they retire. IDs remain unchanged across migration, but row indices and component addresses do not. Handles are not authenticated and domain uniqueness is not automatically managed.

## 2. Storage invariant and migration

For every archetype `a`, its live prefix of length `n_a` contains entity IDs and equal-length typed component columns. For every live handle `e`, the directory has a location `(a,r)` such that `ids_a[r] == e`, and each row has exactly one live directory entry. The full `validate()` audit checks both directions. It does not establish validity of arbitrary pointer fields or detect races.

Migration from component mask `A` to `B` (one add/remove operation) proceeds as follows:

1. Reject active query, stale handle, missing/present component mismatch, absent destination archetype or full destination.
2. Copy shared components `A & B` from the source row to the next destination row. Publish the same entity ID at the destination.
3. Update the migrating entity's directory entry. Fill the vacated source row by copying the old last row if necessary; repair the moved entity's directory entry.
4. Initialize the newly added column (for add) before returning to caller. No fallible allocation or external callback occurs inside migration.

Logical invariants hold at API boundaries. This is a single-threaded operation; temporary internal state during mutation is not safe to observe. Individual capacity failures have no side effects. There is no multi-operation transaction. Row order is unstable by design.

For `K` registered archetypes and `C` registered component types, lookup of an archetype is currently linear in `K`, metadata iteration inside migrations is linear in `C` (compile-time unrolled), plus the actual copied bytes. Handle lookup and validation are O(1) metadata operations; copying a component adds size-dependent cost. Query matching is O(K), then direct contiguous column iteration over matching rows. Preallocation eliminates allocator calls in these APIs, not cache misses, page faults, or application callback allocations.

## 3. Typed chunk queries

```zig
fn movement(dt: f32, chunk: W.Chunk(&.{Velocity}, &.{Position})) !void {
    for (chunk.write(Position), chunk.read(Velocity)) |*p, v| {
        p.x += v.x * dt;
        p.y += v.y * dt;
    }
}
try world.forEach(&.{Velocity}, &.{Position}, &.{}, 0.016, movement);
```

`forEach(reads, writes, without, context, callback)` selects archetypes containing all read/write types and none of the forbidden types. Nonempty matches are visited in configuration order. The callback receives a typed chunk with `ids()`, `count()`, `read(T)` (read or write declarations), and `write(T)` (write declarations only). Read-only columns are const slices. The required and forbidden masks cannot overlap. Read/write declarations must be disjoint; declaring a component writable also permits reading it.

The world rejects structural edits, direct `get/set/signature`, reentrant queries, and `deinit` while a query is active. A callback error releases the guard but does not roll back prior writes or commands enqueued by that callback. The query is sequential and non-reentrant; the guard is not a lock, an ownership checker, or a concurrency primitive. Do not retain chunk pointers/slices after a callback or access another alias of storage; Zig cannot enforce this lifetime contract. The struct fields are implementation details, not a second access API. `contains`, `count`, and `countIn` return identity/count metadata and are usable during sequential callbacks.

## 4. Deferred mutation

```zig
var commands = try W.CommandBuffer.init(allocator, world.domain(), 512, 8192);
defer commands.deinit();
try commands.add(e, Health{ .hp = 50 }); // rejects at flush if already present
try commands.remove(e, Velocity);
const report = try commands.flush(&world);
```

The buffer is bounded by command count and a byte payload arena. Queue operations `spawn(tuple)`, `add(id, value)`, `remove(id, T)`, `despawn(id)` never allocate after `init`; insufficient capacity and wrong domain are rejected before enqueuing. Native component bytes are internal shallow copies in registry order, **not a wire format** and not safe to construct from external data. `spawn` assigns identity only during flush; the report counts successful spawns, but does not return their IDs or support same-batch spawn tickets.

Flush applies FIFO commands at the barrier. It rejects individual invalid operations (including stale IDs, duplicate adds, missing archetypes, insufficient destination capacity) and continues. The report has `applied`, `rejected`, `spawned`, and `first_failure` with zero-based index and reason. All processed entries are consumed; a batch is **not atomic**. A `WrongDomain` or `QueryActive` failure rejects the whole flush before processing and preserves the queued entries. `clear` discards them explicitly. Queueing during query is permitted, flushing is not. Never share a command buffer across threads without synchronization.

## 5. Public API summary

| Function | Contract |
|---|---|
| `World(&.{T,...})` | Create specialized registry |
| `W.mask(&.{T,...})` | Compile-time signature |
| `W.init(a, entity_capacity, domain, configs)` | Allocate all tables/directory; may fail |
| `world.spawn(tuple)` | Create typed entity |
| `world.despawn(id)` | Delete, retire or advance generation, repair rows |
| `world.add(id, value)` / `remove(id,T)` | Checked one-component migration |
| `world.get(id,T)` / `set(id,value)` | Copy out/in; only outside query |
| `world.signature(id)` | Return current component mask |
| `world.contains(id)` | Check handle identity |
| `world.count()` / `countIn(mask)` | Count live entities; null for unknown mask |
| `world.forEach(reads,writes,without,ctx,run)` | Scoped typed column traversal |
| `world.validate()` | Full invariant audit (diagnostic, not hot-path) |
| `W.CommandBuffer.init(a,domain,commands,bytes)` | Preallocate deferred mutation buffer |
| `buffer.flush(&world)` | Ordered barrier; report failures |
| `world.deinit()` | Release ownership; rejected during a query |

## 6. Scheduling foundation

`rv.tasks.plan` builds a deterministic dependency graph for at most 64 systems. Resource masks are declared by the caller; use the same registry order for ECS component resources. A system is `{ reads, writes, after }`. `after` is a separate mask over **system indices**, not component types.

For systems `i` and `j`, an access conflict exists if either writes a resource the other reads or writes. By default a conflict edge goes from earlier registered to later registered system. Explicit `after` edges may reference any valid system index, and can introduce cycles; cycles and unknown indices are rejected. Wave generation selects all nodes whose predecessors have already completed, ensuring no declared conflicts within a wave. No actual execution, mutexes, worker pool, or transitive effect checking is implemented. The planner is O(S²) time and O(S) 64-bit masks for S <= 64 systems. A future parallel ECS API must replace the sequential query guard with validated per-resource leases and isolate per-worker command buffers.

## 7. Mach integration strategy

Keep simulation state separate from rendering. `World` owns Position, Velocity, Health, Pose, etc.; `rv.binary` owns validated immutable asset data; `rv.memory.Region` owns temporary per-frame data; the renderer maintains GPU buffers and handles rather than raw pointers to ECS rows. Four local cameras can share the same simulation snapshot, then execute per-camera visibility/draw passes. Apply structural commands at the end of simulation or a deliberately chosen barrier before publishing a render snapshot. GPU upload/camera scheduling and the actual Mach API adapter are not implemented here, because no engine revision or compatible toolchain was supplied.

## 8. Research and limits

This source prototype realizes the data-oriented storage, generational identity, and explicit task-declaration mechanisms in the Ranvier language addendum. It does not prove memory safety for Zig programs, automatic effect verification, WCET, no physical page faults, or benchmark superiority. Next: run the CI matrix on Linux and Windows, benchmark hot-only/migration-heavy workloads separately, add chunk-level jobs and deterministic per-worker command merging, then introduce bounded parallel execution and VM-backed stable growth.
