# Reproducible benchmark protocol

`python benchmarks/run.py` builds three native executables in Zig 0.17.1 `fast` mode, then runs them in shuffled deterministic order with two warmups and seven measured trials each by default. Each creates one million 64-byte logical records with x, velocity, and cold payload, performs 40 rounds of integer position integration, then reads all positions and one cold byte per record. The Python runner independently calculates the expected checksum; every run must match. It prints median elapsed time and AoS-relative speedup and writes raw CSV trials. Change output path with `--out`; choose repetitions with `--runs`, `--warmups`; `--skip-build` runs existing executables (verify their build configuration first).

Timings are whole-process wall time including allocation, initialization, computation, checksum, printing, process startup, and teardown. They are deliberately **not kernel-only timings**. `storage_bytes` is logical allocated table backing size, not peak RSS or allocator overhead. The workload reads a hot subset, so it is not representative of every workload. It measures explicit library layout choices, not the proposed Ranvier compiler. Measured results are listed at the end of this document.

For research use, record CPU/cache topology, OS, Zig version, target, optimization mode, governor, core affinity, thermal state, and raw trials. Compare `debug`, `safe`, and `fast` only within equivalent configurations; repeat at multiple working-set sizes, and measure kernel-only time and hardware counters in a follow-up harness. Add workloads for whole-row traversal, sparse random access, migrations, and SIMD. Report medians and distributions, not only the best case. Do not claim Go/Rust/C++ superiority without equivalent implementations and controls.

Linux example after building (when perf is available and permitted):

```sh
perf stat -r 5 -e cycles,instructions,cache-references,cache-misses ./zig-out/bin/ranvier-bench-soa
```

The `cost.touchedLines` function counts distinct cache-line addresses, not actual cache misses. For example with one 4-byte field in eight 8-byte records on a 64-byte line aligned at address 0, it returns one, not eight. `scripts/reference_checks.py` compares the interval-counting algorithm with a brute-force set union on 1,000 generated layouts. This Python reference is independent evidence for the algorithm, not a test of the Zig code.

## ECS vs flat AoS (v0.2)

`zig build bench-ecs -Doptimize=fast`, then `python3 benchmarks/run_ecs.py --skip-build`. The benchmark builds 200,000 logical entities, half moving, with Position, optional Velocity, and 56 cold bytes. It performs 80 movement passes, then sums positions and one cold byte per entity. The ECS uses two archetypes; the AoS stores all fields and a moving flag. Every run must match a Python checksum. Initialization, final checksum, teardown and an ECS invariant audit are included in whole-process timing; the AoS has no equivalent directory audit. These are deliberately unequal representations with different identity guarantees. Do not interpret the result as an isolated iteration-speed comparison. Future studies should measure kernel-only time, memory, migration throughput, allocation count, cache misses and p95/p99 frame latency under matched semantics.

## Measured results

One machine, one session; treat these as a first data point, not a characterization.

- Date: 2026-11-24
- CPU: Apple M3 Pro (6 performance + 6 efficiency cores), 18 GB RAM
- OS: macOS 26.5.1, aarch64
- Compiler: Zig 0.17.1, `-Doptimize=fast`, native target
- Protocol: runner defaults (2 warmups, 7 measured trials, shuffled order), no core pinning, machine otherwise idle but not isolated
- Every run matched the independently computed checksum

Layout benchmark (`benchmarks/run.py`; 1,000,000 records, 40 rounds), whole-process wall time in ms:

| Layout | Median | Min | Max | Relative to AoS (median) |
|---|---|---|---|---|
| AoS | 54.7 | 53.3 | 60.3 | 1.00x |
| SoA | 20.0 | 19.4 | 24.7 | 2.74x |
| AoSoA (16 lanes) | 18.6 | 17.9 | 19.2 | 2.94x |

ECS benchmark (`benchmarks/run_ecs.py`; 200,000 entities, 80 rounds), whole-process wall time in ms:

| Representation | Median | Min | Max | Relative to AoS (median) |
|---|---|---|---|---|
| Flat AoS with moving flag | 13.7 | 13.4 | 16.0 | 1.00x |
| Archetype ECS (2 archetypes) | 7.5 | 7.4 | 7.8 | 1.83x |

A second session on the same machine gave medians within 12% of these (AoS 55.0, SoA 19.5, AoSoA 18.7; flat AoS 12.1, ECS 6.9). The caveats above apply in full: these timings include process startup, allocation, initialization, checksum and teardown, and the ECS run also includes an invariant audit that the flat AoS run lacks. They do not isolate iteration speed.
