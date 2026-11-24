# Ranvier Core

**Version 0.2.0 | Native Zig research framework | Experimental**

Explicit data-oriented storage, compact binary representations, and predictable allocation. This is the first implementation milestone for the proposed Ranvier language, with no Mach dependency, garbage collector, background runtime, or external packages. It targets Zig **0.17.1** (not earlier Zig versions). v0.2 adds a bounded archetype ECS, deferred commands and a conflict-aware task graph planner. The compiler/frontend, automatic lifetime/effect checking, parallel executor and OS virtual-memory backend are future work.

## Build and test

Install the exact release from [ziglang.org/download](https://ziglang.org/download/). Use a compatible revision of Mach rather than changing its Zig compiler without checking compatibility.

```sh
zig version                       # expected 0.17.1
zig build test --summary all       # unit + integration tests
zig build test -Doptimize=safe --summary all
zig build demo                     # memory, SoA and binary example
zig build ecs-demo                 # ECS query, deferred migration, graph
zig build bench-ecs -Doptimize=fast # two ECS benchmark executables
python3 benchmarks/run_ecs.py      # ECS vs flat AoS checksum + timings
zig build bench -Doptimize=fast    # builds 3 benchmark executables
python3 benchmarks/run.py          # builds + records measured CSV results
python3 scripts/reference_checks.py # independent binary/layout checks
python3 scripts/ecs_reference_checks.py # independent ECS/graph model checks
```

If investigating build-system compatibility, `zig test src/root.zig` directly tests the core module. `zig build test` also compiles the fixtures in `tests/compile_fail/` and fails if any of them is accepted. The repository includes a GitHub Actions matrix for Linux, macOS and Windows; it will run after you publish/push this repository.

**Build validation status:** verified with Zig 0.17.1 on aarch64-macos: 35/35 tests pass in debug, safe and fast modes, both demos run, and both benchmark suites match their independent checksums. The test binary also compiles for Linux, Windows, 32-bit x86 and wasm32, but has not been executed there. See [validation status](docs/VALIDATION.md) for details and [benchmark protocol](docs/BENCHMARKS.md) for measured results.

## Import into another Zig project

Place or vendor this directory beside the consumer's build manifest. Add a path dependency to your `build.zig.zon`:

```zig
.dependencies = .{
    .ranvier = .{ .path = "vendor/ranvier-core" },
},
```

In the consumer's `build.zig`, use its existing `target`, `optimize`, and executable module:

```zig
const ranvier = b.dependency("ranvier", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("ranvier", ranvier.module("ranvier"));
```

No source generation or C toolchain is required by the Core package itself. The package's own build is verified with 0.17.1; the consumer snippet above has not been exercised from a separate project.

## Start with SoA

```zig
const std = @import("std");
const rv = @import("ranvier");
const Particle = struct { x: f32, v: f32, health: u32 };

pub fn main() !void {
    var table = try rv.data.SoA(Particle).init(std.heap.page_allocator, 4096);
    defer table.deinit();
    try table.append(.{ .x = 0, .v = 10, .health = 100 });
    for (table.column("x"), table.column("v")) |*x, v| x.* += v * 0.016;
}
```

Use `rv.data.AoS(Particle)` or `rv.data.AoSoA(Particle, 16)` to choose other layouts. `get`, `set`, `count`, `capacity`, `append`, `swapRemove`, and `storageBytes` share a common contract; use `rows`, `column`, or `blockColumn` for the corresponding representation. AoSoA blocks are generated from reflected record fields using Zig 0.17.1 `@Struct`. The framework does not infer which layout is best.

## Choose storage by lifetime

| Need | API |
|---|---|
| Frame-local allocations | `memory.Region.init(buffer)`, `alloc(T,n)`, `mark`, `rewind`, `reset` |
| Stable addresses during append | `memory.StableVec(T).init(typed_buffer)`, `append`, `items` |
| Reusable object identity | `memory.SlotMap(T).init(allocator, capacity, domain)` |
| Contiguous records | `data.AoS(T)` |
| Contiguous fields | `data.SoA(T)` |
| Chunked contiguous fields | `data.AoSoA(T, lanes)` |
| Variable-size byte records | `data.PackedRecords.init(bytes, offsets)` |
| Exact distinct line counts | `data.cost.touchedLines(base, rows, stride, fields, line_size)` |
| Checked relative offsets | `binary.RelRef(Codec, W)`, `binary.RelSlice(Codec, W)` |
| Versioned binary assets | `binary.WorldChunk.encode`, `binary.WorldChunk.View.open` |
| Archetype entity storage | `ecs.World(&.{T,...})` |
| Deferred structural changes | `World.CommandBuffer` |
| Conflict-aware scheduling plan | `tasks.plan(systems)` |

All owners are non-copyable by convention. No general memory-safety guarantee: callers must keep backing storage alive, refrain from forging fields or markers, synchronize access, and manage resource-owning elements. The public APIs are designed for value/handle based access, but Zig cannot enforce borrow lifetimes globally. See [architecture and safety contracts](docs/ARCHITECTURE.md) before integration. See [RVC1 binary format](docs/FORMAT.md) for byte offsets and [benchmark protocol](docs/BENCHMARKS.md) for measurements.

## Start with archetype ECS

```zig
const Position = struct { x: f32 };
const Velocity = struct { v: f32 };
const W = rv.ecs.World(&.{ Position, Velocity });

fn move(dt: f32, chunk: W.Chunk(&.{Velocity}, &.{Position})) !void {
    for (chunk.write(Position), chunk.read(Velocity)) |*p, v| {
        p.x += v.v * dt;
    }
}

// In main or an engine setup function:
var world = try W.init(std.heap.page_allocator, 1024, 1, &.{
    .{ .mask = W.mask(&.{Position}), .capacity = 1024 },
    .{ .mask = W.mask(&.{ Position, Velocity }), .capacity = 1024 },
});
defer world.deinit() catch unreachable;
const e = try world.spawn(.{ Position{ .x = 0 }, Velocity{ .v = 10 } });
try world.forEach(&.{Velocity}, &.{Position}, &.{}, @as(f32, 0.016), move);
var commands = try W.CommandBuffer.init(std.heap.page_allocator, world.domain(), 128, 4096);
defer commands.deinit();
try commands.remove(e, Velocity);
const report = try commands.flush(&world);
if (report.rejected != 0) return error.CommandRejected;
```

The ECS uses preallocated typed columns and the existing generation-safe entity directory. Structural mutation is disallowed during a query; enqueue and flush at the barrier. The task planner schedules declared dependency waves only; no worker threads are started. See [ECS architecture and API reference](docs/ECS.md), [changelog](docs/CHANGELOG.md), and [validation status](docs/VALIDATION.md) for limits and test status.

## Suggested next milestone

Run the CI matrix on Linux and Windows; implement chunk-level parallel queries with independently owned command queues and deterministic merging. Then add real worker execution, OS-managed virtual-memory backends and a Mach adapter against a compatible pinned engine revision. These remain future work.

## Licensing

No license has been selected by the project owner. `LICENSE` is a licensing decision notice, not an open-source grant. Choose and replace it before public distribution. No third-party source code is bundled.
