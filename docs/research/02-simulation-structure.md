# 02: Simulation structure

Researched 2026-11-07, trimmed 2026-11-08. The original was written for Rust and Bevy; the language is now Odin and
the host Godot, so code sketches and ECS-library comparisons were cut (kept in git history and
`../archive/stacks/`). Module specs supersede this doc once signed off. Claims marked **(unverified)** are inference.

## Recommendation

- **A small, purpose-built ECS-ish state store, independent of any host engine.** No off-the-shelf ECS for
  simulation state: every mainstream one (bevy_ecs, hecs, flecs, EnTT, shipyard) stores components in
  allocator-owned columns and snapshots by per-type clone or serialization. None gives "the whole state is one
  pointer-free block", which is the project's key idea. Projects that took rollback seriously (bones, petek, massive,
  Quantum) all built their own store. About 2–4k lines **(unverified estimate)**.
- **Layout: Quantum's model.** Generational entity handles, one sparse-set table per component type, a globals block
  (tick, RNG, player slots), and an in-arena heap for the few dynamic collections. No pointers, no padding, no
  `usize`: state is plain bytes. A snapshot is a memcpy, a checksum is XXH3 over the bytes, late join sends the
  bytes, and a desync diff is a field-level byte diff driven by layout descriptors.
- **Physics is the one big external state**, behind a save/load/hash seam (Box3D fork, see `01`).
- **Godot is the host and view only.** It reads the frame (predicted, predicted-previous, verified), keeps view-only
  state in nodes keyed by sim handles, and never writes sim state.
- **Gameplay code is plain functions over typed queries in an explicit, ordered list.** The always-on **sync-test
  mode** catches what static checks miss.

## Quantum's model: what it does, what to copy, what to drop

What Quantum does (Quantum 3 manual):

- **Frame = all mutable state.** "All gameplay data (game state) is kept either in the sparse-set ECS data
  structures (entities and components) or in our custom heap-allocator (dynamic collections and custom data), as
  blittable memory-aligned C# structs" ([intro](https://doc.photonengine.com/quantum/v3/quantum-intro)). Systems
  must be stateless ([systems](https://doc.photonengine.com/quantum/v3/manual/quantum-ecs/systems)).
- **Several frame copies in a ring.** "Quantum's rollback model maintains a variable sized frame buffer… several
  copies of the game state data… are kept in memory blocks at separate locations", so any pointer is valid only
  within one Frame ([systems](https://doc.photonengine.com/quantum/v3/manual/quantum-ecs/systems)). The ring size is
  `RollbackWindow` ([config](https://doc.photonengine.com/quantum/v3/manual/config-files)). That copying a frame is a
  block copy of component buffers plus heap pages is my reading of the SDK **(unverified)**.
- **Sparse sets.** A filter walks the smallest component set and discards entities missing the others
  ([components](https://doc.photonengine.com/quantum/v3/manual/quantum-ecs/components)). `EntityRef` = index plus a
  version bumped when a slot is reused
  ([API](https://doc-api.photonengine.com/en/quantum/v3/struct_quantum_1_1_entity_ref.html)). Singleton components
  are enforced "deep in the core of the ECS data buffers".
- **Frame heap.** `list<T>`, `dictionary<K,V>` and `hash_set<T>` are pointers into a paged heap
  (`HeapPageShift` = 15, `HeapPageCount` = 256 by default, so 8 MB). They must be allocated and freed by hand or with
  `[AllocateOnComponentAdded]` / `[FreeOnComponentRemoved]`. Forgetting to null a freed pointer "will result in
  non-deterministic behavior", and a dictionary value pointer goes stale on growth
  ([DSL](https://doc.photonengine.com/quantum/v3/manual/quantum-ecs/dsl)). The DSL reorders fields to avoid padding.
- **Signals** are generated interfaces that systems implement: synchronous, decoupled calls between systems
  ([DSL](https://doc.photonengine.com/quantum/v3/manual/quantum-ecs/dsl)).
- **Events** fire from every (re)simulation. Duplicates are removed by a hash of event id, tick and fields
  (`nothashed` excludes fields). Non-`synced` events are confirmed or cancelled once their frame is verified;
  `synced` events dispatch only on verified input
  ([events](https://doc.photonengine.com/quantum/v3/manual/quantum-ecs/game-events)).
- **Commands** are serialized, polymorphic one-off messages that travel with a tick's input
  ([commands](https://doc.photonengine.com/quantum/v3/manual/commands)). **Assets** are immutable `AssetObject`s
  referenced by `AssetRef<T>` GUIDs from a DB outside the frame
  ([assets](https://doc.photonengine.com/quantum/v3/manual/assets/assets-simulation)). The RNG session lives in the
  frame ([RNG](https://doc.photonengine.com/quantum/v3/manual/rngsession)).
- **Physics is in the frame and "stateless"**: the broadphase is rebuilt every tick, and CCD is speculative because
  sweep CCD would be too expensive without persistent state
  ([queries](https://doc.photonengine.com/quantum/v3/manual/physics/queries)).
- **Prediction culling** runs only entities near the local player in predicted frames
  ([culling](https://doc.photonengine.com/quantum/v3/manual/prediction-culling)). **Checksums** are sent every
  `ChecksumInterval` ticks, and there is a costly cross-platform checksum mode
  ([config](https://doc.photonengine.com/quantum/v3/manual/config-files)).

**Copy:** the frame as the single source of truth; stateless systems; generational handles; sparse sets; the
globals block and RNG in state; immutable assets by reference; the event model (hashed dedup, synced and non-synced,
cancel on rollback); commands next to input; predicted, predicted-previous and verified frames for the view;
checksums; field packing.

**Drop or change:**

- **The `.qtn` DSL and codegen.** Plain Odin structs plus compile-time checks replace it.
- **Raw pointers into the frame.** Use handles.
- **Manual heap free.** Prefer inline fixed collections. Where heap collections exist, the derive generates their
  free-on-remove step.
- **The `SystemsConfig` asset.** OctoEscape's own notes say "an unregistered system silently never runs". Use a
  compile-time list instead.
- **Signal interfaces.** Plain function calls do the job.
- **Stateless in-frame physics.** We want a mature external engine instead (with its own state problem, below).
- **Prediction culling.** Not needed at 2–4 players and 1000 entities. Keep the hook.

## Why not an existing ECS

Per-type snapshot strategies (clone, reflect, serialize) allocate per frame, miss unregistered types silently, and
reorder entities on restore. flecs v4 removed snapshots; EnTT's `snapshot` is built for save games, not 60 Hz rings.
Details and sources: git history of this file.

## Proposed design sketch

### Data layout

```
Frame (one 64-byte-aligned byte block, little-endian; Win x64 and macOS ARM are both 64-bit LE)
├─ Header     tick, schema hash, layout table (offset/cap/len per region), allocator state
├─ Globals    RNG (xoshiro/PCG state), player slots, level id, singletons
├─ Entities   [EntitySlot { generation: u32, alive: u8, kind: u16, origin: u32 }; cap]  + free list
├─ Table<T>   per component type: sparse[u32; entity_cap] → dense index; dense_entities[Entity]; dense[T]
└─ Heap       size-class pages for List<T>/Map<K,V> payloads; free lists live in the header
```

- **Entity** = `{ index: u32, generation: u32 }`. `f.get::<T>(e)` returns `None` for a stale handle.
- **Sparse sets, not archetypes.** Add and remove are O(1) with no row moves. A join walks the smallest table, as in
  Quantum. At 1000+ entities, speed is not the constraint. Simplicity and determinism are. Each component type is
  one contiguous dense `[T]`: SoA across components, AoS within one.
- **Deterministic order for free.** Dense order follows the history of operations (swap-remove included), and that
  history is part of the state. Iteration is therefore identical everywhere, with no sorting.
- **Capacity:** each table starts at a capacity from level config. Growth happens only between systems: double the
  capacity and rebuild the layout. All references are indices or offsets, never pointers, so nothing needs fixing
  up. Snapshot slots are byte buffers resized on demand. Growth is rare and deterministic, because capacities are
  state.
- **Dynamic collections:** default to inline fixed-capacity vectors, bitsets and maps (sorted or
  open-addressed with a fixed hash). Handles into the heap are allowed where needed. The
  allocator's metadata lives inside the arena, so allocation rolls back too. Freed bytes are zeroed so the hash
  stays stable. 
- **Cost:** about 1000 entities × about 0.5 KB plus heap ≈ 1 MB. memcpy and xxh3 each run at tens of GB/s, so
  ≈ 50–100 µs **(unverified, to measure)**. Re-simulation, mostly physics, dominates rollback cost, not copying.
  Copy-on-write or dirty-page deltas are **not needed for rollback**. They matter for long histories: timeline scrub
  should store a keyframe about every second plus the input log, and re-simulate forward.

### Rules the code must follow

- State types are fixed-width ints, f32, bool-as-u8, handles, asset refs (stable ids resolved outside the snapshot),
  fixed collections, enums and other state structs. No pointers, slices, strings, `int`/`uint`, maps or dynamic
  arrays. Padding is rejected so hashes and desync diffs don't lie (how Odin enforces this: module spec).
- Systems are plain procedures over the frame, run from one explicit ordered list (the schedule is greppable and
  diffable). Structural removal is deferred to the end of a system.
- Signals become direct calls. Commands are a small enum carried in the tick's input set. RNG lives in globals,
  optionally per-entity streams seeded by (entity, tick, salt).
- Assets and config are text files and glTF loaded into immutable tables with stable ids; the session hashes them
  into the checksum seed. A config hot reload in a multiplayer session must travel as a command.
- Footgun guards for agents: the sim package cannot import the host, so it cannot read host input or time; checks ban
  maps with random order, wall-clock time, `core:math` transcendentals and mutable globals in sim code.

### External state: physics

A save / load / hash seam for anything the arena cannot hold. The snapshot record is `{arena bytes, physics bytes,
tick}`. Box3D (our fork) has the model we want: a complete world snapshot where handles created after the snapshot
fail validation after restore, and id pools are restored, so spawns and despawns inside the window just work.

- **Rule:** the arena is authoritative for which bodies exist. Physics callbacks are collected into an arena buffer
  and handled by a system in a fixed order.

### Late join, hot reload, tools

- **Late join** = zstd(snapshot record) plus the schema hash. It requires the same build, and the physics blobs
  require it anyway.
- **Layout descriptors** drive the in-game inspector, field-level desync diffs between two peers' snapshots, and
  state-keeping hot reload: migrate fields by name when a struct changes.

## Host and view: Godot

The sim is separate from the host. Godot's scene tree is not an ECS, and rollback addons such as netfox roll back
node properties, a different model from ours. Run the sim in a GDExtension (or link it) and use nodes as views.
How the sim binds to Godot nodes is in discussion (`WORK.md`). The cost of separation is a view-sync system: diff sim
entities against view entities each render frame, spawn and despawn views by `kind`, and write interpolated
transforms. The view world is derived and disposable.

### How the view reads state

- **Frames:** `predicted` (motion), `predicted_previous` (for interpolation), `verified` (scores, UI that must not
  flicker), as in Quantum's [frames](https://doc.photonengine.com/quantum/v3/manual/frames). The view gets `&Frame`
  only.
- **Interpolation:** render at `lerp(prev, curr, alpha)` with alpha taken from the tick accumulator. **Error
  correction:** when a rollback moves an entity's rendered pose, keep the old pose as an offset and decay it over
  about 100–200 ms. Quantum's `PreviousUpdatePredicted` exists for this.
- **Mapping:** `HashMap<Entity, ViewEntity>` plus the slot's `kind` and `origin` (a deterministic spawn key). This
  avoids Quantum's documented **EntityRef hijacking**, where a rollback reassigns a handle to a different logical
  entity ([doc](https://doc.photonengine.com/quantum/v3/concepts-and-patterns/entityref-hijacking)). Per kind: bind
  on predicted (responsive) or on verified (no false spawns).
- **View-only state** (the procedural tentacle rig, hit-stop, smoothing) lives on the host's view entities, keyed by
  sim handle. It is never hashed, survives rollbacks, and is rebuilt if the view entity is recreated.
- **Events:** a per-tick event buffer outside the arena, stored with the snapshot ring. The dispatcher uses
  Quantum's rules: dedup by (tick, type, hash of non-`nothashed` fields), confirm or cancel on verification
  (cancellable effects such as a sound can fade out), `synced` events only from verified ticks.

## Risks and unknowns

1. **Keeping external physics consistent** with the arena across rollbacks. Largely settled by phase 1 and 2.
2. **Sync-test cost** with physics: N re-simulations per frame, so N may need to be lower in dev play.
3. **Growth and relayout** complexity, and schema migration for hot reload. Deferrable: fixed capacities first.
4. **Owning a custom ECS:** maintenance and missing features (relations, observers). Keep it small.
5. **Registration order** of component types defines the layout. Sort by stable type name **(unverified)**.
