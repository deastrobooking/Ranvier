# Changelog

## Unreleased — first native validation

- Compile and run the full suite with Zig 0.17.1 for the first time; see [VALIDATION.md](VALIDATION.md).
- Fix `memory.SlotMap.init`: the `capacity` parameter shadowed the `capacity` method and did not compile.
- Fix `World.Chunk.read`/`write`: the declared-access checks were not evaluated at compile time, so every query callback failed to compile.
- Add compile-fail fixtures (`tests/compile_fail/`) for the query access contract and the component registry, run by `zig build test`.
- Add allocation-failure tests for world, command buffer, pool, layout tables and chunk encoding.
- Apply `zig fmt` to all sources; CI now checks formatting.
- Record the first measured benchmark results in [BENCHMARKS.md](BENCHMARKS.md).

## 0.2.0 — Archetype ECS and task graph

- Preserve v0.1 public `memory`, `data`, and `binary` modules.
- Add `ecs.World`, typed component registry/masks, explicitly sized archetype SoA tables, generation-checked entities, checked add/remove migration and bidirectional directory audit.
- Add typed callback queries with read/write/exclusion sets and a non-reentrant iteration guard.
- Add bounded, FIFO deferred spawn/add/remove/despawn buffer and per-command rejection reports.
- Add deterministic conflict/dependency planner `tasks.plan`; no thread executor.
- Add ECS demo and checksum-validated ECS-vs-flat-AoS whole-process benchmark.
- Add 10 ECS and 3 task-planner Zig named tests (not executed at the time of the 0.2.0 packaging), independent Python reference-model checks and updated CI.
- Decisions: retain Zig 0.17.1 and existing package fingerprint, keep licensing choice open, favor bounded storage and single-threaded correctness before parallel execution.

## 0.1.0 — Initial storage prototype

- Memory: SlotMap, Region, StableVec.
- Layout: AoS, SoA, AoSoA, packed records, cache-line model.
- Binary: relative references and RVC1 validation.
- Three-layout benchmark harness, independent Python fixture tests, CI.
