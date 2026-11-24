# Ranvier Core architecture and contracts

## Goal

Deliver an experimental native Zig implementation of the storage and representation layer of the Ranvier research language, without pretending to implement a language-wide borrow checker. Application code owns its lifetimes; the library implements local checked operations. This is a research prototype, not a production-safety certification.

## Module map

| Module | Implemented | Operational boundary |
|---|---|---|
| `memory.SlotMap(T)` | fixed slots, embedded free list, generation retirement, explicit domain, copy-out access | single owner; unique nonzero domain per lifetime; no pointer borrow; T may contain pointers and ownership is shallow |
| `memory.Region` | checked aligned bump allocation, LIFO scopes, high-water mark | caller-provided byte buffer; no destructor handling; all rewound allocations invalid |
| `memory.StableVec(T)` | stable append into bounded typed backing slice | no VM reservation or automatic storage assignment; pointer lifetime bounded by backing |
| `data.AoS(T)` | fixed contiguous record array | swap-removal changes row identity |
| `data.SoA(T)` | fixed field columns using Zig `MultiArrayList` | column views are scoped by convention |
| `data.AoSoA(T, lanes)` | compile-time block generation via `@Struct` | fixed blocks, partially filled last block; native layout, not wire ABI |
| `data.PackedRecords` | inline u32-length byte records + u32 side index | append-only; external byte/index buffers must not alias or be modified externally |
| `data.cost.touchedLines` | exact unique-line count for monotone fields | not an execution-time, cache-miss or auto-layout model |
| `binary.RelRef`, `RelSlice` | base-relative checked offset access with explicit wire codecs | domain is supplied by caller; not absolute identity or lifetime proof |
| `binary.WorldChunk` | self-contained RVC1 encoding and validation | immutable backing contract; typed scalar decode, direct borrowed labels; no OS mmap wrapper |
| `ecs.World` | bounded archetypes, typed queries, slot-map IDs, migration, deferred commands | single-threaded; no escaped views; no dynamic registry/archetype allocation |
| `tasks.plan` | deterministic declared-resource DAG/waves | planner only; no executor, locks or proof of arbitrary Zig effects |

## Safety and resource model

Zig has no language-wide borrow checker. Types are ordinary structs, so fields can be changed and owners copied. Treat state fields as implementation details. Never use a copied or moved owning value to deinitialize twice. Do not copy regions with live marks; do not use markers from a previously destroyed/reinitialized region even if its address is reused. Keep region and StableVec backing storage at fixed addresses. Do not call concurrently on any of these types without external synchronization. Copying values is shallow; a handle to a value with a pointer field cannot ensure the pointee lifetime. No allocator or resource destructor is invoked on removing a row or slot; callers clean up resource-owning values.

SlotMap handles have a 64-bit caller-assigned domain, 32-bit index, and 32-bit generation. Generation starts at 1 and retires at max u32, never wraps. This guards identity within the pool's contract; it does not authenticate handles, prevent manually forged handles, or fix races. If a caller reuses domain identifiers, a handle from another pool lifetime can accidentally resolve. Use a central monotonic domain counter and stop on exhaustion. Allocation/removal are O(1) metadata operations after init; copying T adds a size-dependent cost; scanning is O(capacity).

Region allocation checks multiplication, pointer alignment arithmetic, and capacity before changing cursor. Returned memory is uninitialized. Scope rewinds are LIFO; a scope is consumed on successful rewind. High-water records historical use, not physical RSS. No OS or heap call happens inside Region. StableVec never changes backing allocation and returns a pointer into the caller's array; reference invalidation is the caller's responsibility. All tables/pools are fixed-capacity so their append paths need no allocator; SoA/AoSoA views can become semantically invalid when rows move.

Wire bytes are not native Zig structs. All accesses decode little endian scalars and check ranges. A trusted codec is part of the schema's trusted computing base. RelRef/RelSlice check extent and file alignment; only schema-specific validation can prove that an offset points to a semantically permitted object. WorldChunk supplies such a restricted schema. This is not a general graph or recursive binary verifier.

## Stage 2: ECS and dependency planning (v0.2)

The first and the graph-planning portion of the third items below are now present as source. See [ECS reference](ECS.md) for exact bounded-world, command-buffer, query and planner contracts. The executor, VM backend and actual Mach integration remain future work.

1. Build an entity directory backed by generation-checked IDs and dense archetype rows. Row swap-removal must update the moved entity's directory mapping. Each archetype signature uniquely identifies its column set. Reserve capacity in destination before migration; defer structural changes while queries live; apply a command buffer at a barrier. Write randomized tests against a reference entity/component map.
2. Add size-class pools/variable-size span allocation with explicit coalescing costs. Add VM reserve/commit implementations for Linux/macOS/Windows and a bounded fallback; prove range checks and page-alignment requirements. VM growth may page fault, so pre-touch for latency-critical work. The current StableVec does not implement Goose's multi-stack analysis or on-demand commit.
3. Build a task graph from declared resource reads and writes. Conflicts create ordering edges; an explicit dependency direction plus cycle check is required. Use scoped runtime access guards; arbitrary Zig globals remain outside the contract. Start with a sequential deterministic executor and add parallel workers only after correctness tests.
4. Add a Mach adapter pinned to the actual engine's Zig revision, separating immutable mapped assets, per-frame temporary memory and mutable component tables. Start with particle update + frame allocator + asset chunks. No Mach dependency in Core.
5. Add profile-guided layout recommendations (measure hot field sets, traversal, migration, SIMD, bandwidth, RSS), not automatic representation mutation in arbitrary Zig code. Later prototype static effect/lifetime analysis and a RanIR backend.

## Research traceability

The design follows the Ranvier v0.1 language reference and v0.2 data-oriented addendum: representation and storage are separate, no stale generation wrap, distinct-line union rather than counting one line per record, and validated relative domains. See also Goose's [implementation notes](https://github.com/aardappel/goose/blob/master/docs/implementation.md) and [benchmarks](https://github.com/aardappel/goose/blob/master/bench/design.md). The code is an original Zig prototype, not a Goose source port. Zig [0.17.1 language reference](https://ziglang.org/documentation/0.17.1/) and its standard library inform build/reflection/allocator choices.
