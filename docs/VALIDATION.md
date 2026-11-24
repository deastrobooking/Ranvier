# Validation status — v0.2.0

## Executed

First native validation: 2026-11-24, Zig 0.17.1, aarch64-macos (Apple M3 Pro, macOS 26.5.1).

| Check | Result |
|---|---|
| `zig build test --summary all` (debug) | 35/35 tests passed; 4/4 compile-fail fixtures rejected with the expected diagnostic |
| `zig build test -Doptimize=safe` | 35/35 passed |
| `zig build test -Doptimize=fast` | 35/35 passed |
| `zig build test -Dtarget=x86_64-macos` (Rosetta) | 35/35 passed |
| `zig build demo`, `zig build ecs-demo` | ran; output as expected |
| `zig build bench -Doptimize=fast` + `benchmarks/run.py` | built; every run matched the independent Python checksum |
| `zig build bench-ecs -Doptimize=fast` + `benchmarks/run_ecs.py` | built; every run matched the independent Python checksum |
| `zig fmt --check build.zig build.zig.zon src tests examples benchmarks` | clean |
| `python3 scripts/reference_checks.py` | 2 unittest cases passed |
| `python3 scripts/ecs_reference_checks.py` | 4 unittest cases passed |

The 35 tests are 32 named tests plus 3 import/discovery blocks. They include a 5,000-operation randomized ECS model comparison, directory repair, stale and wrong-world IDs, migration failures, typed filtering, deferred command order, query-guard rejection, and induced failure of every allocation in world, command-buffer, pool, layout-table and chunk-encoding setup (`std.testing.checkAllAllocationFailures`).

The compile-fail fixtures in `tests/compile_fail/` cover reading an undeclared component, writing a read-only component, overlapping read/write sets, and an unregistered component. `zig build test` fails if any of them compiles.

Measured benchmark numbers are in [BENCHMARKS.md](BENCHMARKS.md).

## Compiled but not executed

The test binary compiles in Debug and ReleaseSafe for `x86_64-linux`, `aarch64-linux`, `x86_64-windows`, `x86-linux` (32-bit) and `wasm32-wasi`. These binaries were not run. The GitHub Actions matrix (Linux/macOS/Windows, debug and safe) has never run because the repository is not published.

## Defects found by the first compilation

The v0.1 and v0.2 sources were authored without a compiler. Compiling them found two errors; both are fixed.

1. `memory.SlotMap.init` had a parameter named `capacity` that shadowed the `capacity` method. Zig rejects this. The parameter is now `cap`.
2. `World.Chunk.read` and `World.Chunk.write` checked the declared access sets with a runtime `if`, so the `@compileError` branch was always analyzed and every query callback failed to compile. The conditions are now `comptime`. The compile-fail fixtures guard this contract in both directions.

No logic errors were found in the storage, migration, command-buffer or planner code by the existing tests or by review.

## Not done

- No tests have executed on Linux, Windows or a 32-bit target.
- No sanitizer, fuzzing or memory-checker runs beyond Zig safe mode and the testing allocator's leak detection.
- No kernel-only timings, hardware-counter measurements or frame-latency distributions.
- No license has been selected; see LICENSE.

## Reproduce

```sh
zig version                        # 0.17.1
zig fmt --check build.zig build.zig.zon src tests examples benchmarks
zig build test --summary all
zig build test -Doptimize=safe --summary all
zig build demo
zig build ecs-demo
zig build bench -Doptimize=fast
zig build bench-ecs -Doptimize=fast
python3 benchmarks/run.py --skip-build
python3 benchmarks/run_ecs.py --skip-build
python3 scripts/reference_checks.py
python3 scripts/ecs_reference_checks.py
```
