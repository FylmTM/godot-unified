# 02: Simulation structure (ECS library vs custom, and the host engine)

Researched 2026-11-07. Claims marked **(unverified)** are my inference or memory, not checked against a source.

## TL;DR and recommendation

- **Write a small, purpose-built ECS-ish state store in its own engine-agnostic Rust crate (`sim`)**, with no
  dependency on any host engine. Do not use an off-the-shelf ECS for simulation state. Every mainstream ECS
  (bevy_ecs, hecs, flecs, EnTT, shipyard, sparsey) stores components in allocator-owned, type-erased columns and
  snapshots by per-type clone, reflection or serialization. None gives "the whole state is one pointer-free block".
  That block is the project's key idea, and it is about 2–4k lines to build **(unverified estimate)**.
- **Layout: Quantum's model, in Rust.** Generational entity handles, one sparse-set table per component type, a
  globals block (tick, RNG, player slots), and an in-arena heap for the few dynamic collections. Everything is
  `Copy + NoUninit + CheckedBitPattern` (bytemuck), with no `usize` and no padding, so state is plain bytes. A
  snapshot is a memcpy, a checksum is xxh3 over the bytes, late join sends the bytes, and a desync diff is a
  field-level byte diff driven by derive-generated layout descriptors.
- **Physics is the one big external state.** The `sim` crate owns a physics world (Jolt or Rapier: see the physics
  research) behind a `SnapshotPart` trait (save, load, hash). The arena decides which bodies exist, and physics
  state is saved and restored next to it. This is the riskiest seam, so the spike tests it first.
- **Bevy or Godot is the host and view only.** It reads `&Frame` (predicted, predicted-previous, verified), keeps
  view-only state in its own entities keyed by sim handles, and never writes sim state. Using Bevy's World as sim
  state (bevy_ggrs style) gives up the memcpy block, adds registration footguns, ties tests to Bevy's release
  cadence, and cannot move to Godot.
- **Gameplay code is plain `fn(&mut Frame, &Assets)` in an explicit, compile-time ordered list.** Agents get
  "get by handle" access that never fights the borrow checker, and a fast query path for hot loops. The type system
  rejects pointers, `Vec`, `String`, `usize` and `HashMap` in state. Clippy `disallowed-*` lists ban non-deterministic
  APIs. The always-on **sync-test mode** catches the rest.

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

- **The `.qtn` DSL and codegen.** Rust derive macros replace it, so there is no separate build step.
- **Raw pointers into the frame.** Rust references borrowed from `&mut Frame` cannot outlive a tick by construction.
- **Manual heap free.** Prefer inline fixed collections. Where heap collections exist, the derive generates their
  free-on-remove step.
- **The `SystemsConfig` asset.** OctoEscape's own notes say "an unregistered system silently never runs". Use a
  compile-time list instead.
- **Signal interfaces.** Plain function calls do the job.
- **Stateless in-frame physics.** We want a mature external engine instead (with its own state problem, below).
- **Prediction culling.** Not needed at 2–4 players and 1000 entities. Keep the hook.

## Options compared

| Option | Snapshot mechanism | Fit for memcpy rollback | Notes |
|---|---|---|---|
| **bevy_ecs** (0.19.1, standalone usable) via **bevy_ggrs 0.22** | Per registered component and resource: Copy, Clone or Reflect strategies into a per-frame `HashMap` keyed by `RollbackId`; checksums XOR per-type hashes ([architecture](https://docs.rs/crate/bevy_ggrs/latest/source/docs/architecture.md)) | Poor | Documented pitfalls: unstable query order, `Events<T>` and `Local<T>` not snapshotted, unregistered types silently not rolled back, `Entity` ids change on restore (needs `MapEntities`), restore triggers change detection on everything ([pitfalls](https://docs.rs/crate/bevy_ggrs/latest/source/docs/pitfalls.md)). Clone "allocates on the heap each frame". |
| **hecs 0.11** | `serialize` module (row or column, serde) ([docs](https://docs.rs/hecs/latest/hecs/)) | Poor | "An unordered collection of entities": no iteration-order guarantee. rs-ecs (a hecs derivative) can snapshot worlds but needs a hand-filled `Cloner` per type ([rs-ecs](https://lib.rs/crates/rs-ecs)). |
| **flecs v4** (C) | None | Poor | "The snapshot feature has been removed from v4" ([migration guide](https://www.flecs.dev/flecs/MigrationGuide.html)). |
| **EnTT 3.15** (C++) | `snapshot` and `continuous_loader`: serialize through an archive, remap entities ([docs](https://skypjack.github.io/entt/classentt_1_1basic__continuous__loader.html)) | Medium | Built for save games and network sync, not 60 Hz ring buffers. C++ only. |
| **shipyard, sparsey** | Sparse-set storage, no first-class snapshot **(unverified)** | Poor | Same allocator-owned storage problem. |
| **bones_ecs** (Fish Folk) | `World::clone()`: "if it can't be cloned, it can't go in the world"; deterministic iteration, single-threaded ([wiki](https://github.imc.re/fishfolk/bones/wiki/Why-Create-an-ECS%3F)) | Medium | Built because Bevy needed per-type registration. Closest in spirit, but clone-based and tied to the bones framework. |
| **petek** | Clone opt-in per type; restores archetype order; checksums; 10k entities: snapshot 131 µs ([repo](https://github.com/kadircanyildirm-crypto/petek)) | Medium | Experimental, 0 stars, not on crates.io. A design reference. |
| **massive-ecs** (C#) | Bitset/sparse ECS with `SaveFrame()` / `Rollback(n)`; about 0.25 ms per save in their benchmark ([repo](https://github.com/nilpunch/massive-ecs)) | Good | C#. Shows that a rollback-first sparse ECS is small. |
| **Custom arena (recommended)** | memcpy of one `Vec<u8>` | Native | We maintain it. Ergonomics are ours to design. |

The pattern: projects that took rollback seriously (bones, petek, massive, Quantum) all built their own store. They
did it because general-purpose ECSs optimize for parallel scheduling and archetype iteration, and rollback needs
something simpler: one cheap, complete, ordered copy.

## Proposed design sketch

### Data layout

```
Frame (one 64-byte-aligned Vec<u8>, little-endian; Win x64 and macOS ARM are both 64-bit LE)
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
  up. Snapshot slots are `Vec<u8>`s resized on demand. Growth is rare and deterministic, because capacities are
  state.
- **Dynamic collections:** default to inline `FixedVec<T, N>`, `BitSet<N>` and `FixedMap<K, V, N>` (sorted or
  open-addressed with a fixed hash). `List<T>` and `Map<K,V>` handles into the heap are allowed where needed. The
  allocator's metadata lives inside the arena, so allocation rolls back too. Freed bytes are zeroed so the hash
  stays stable. The derive generates free-on-remove for owned handles.
- **Cost:** about 1000 entities × about 0.5 KB plus heap ≈ 1 MB. memcpy and xxh3 each run at tens of GB/s, so
  ≈ 50–100 µs **(unverified, to measure)**. Re-simulation, mostly physics, dominates rollback cost, not copying.
  Copy-on-write or dirty-page deltas are **not needed for rollback**. They matter for long histories: timeline scrub
  should store a keyframe about every second plus the input log, and re-simulate forward.

### Types the compiler polices

```rust
#[derive(Component)]                // generates: State impl (requires every field: State), layout descriptor
pub struct Octopus {               // (name, offsets, types) for inspector, diff, schema hash, hot-reload migration
    pub config: AssetRef<OctopusConfig>,   // u64 stable id; resolved via &Assets, outside the snapshot
    pub mode: OctopusMode,                 // #[repr(u8)] enum → CheckedBitPattern
    pub velocity: Vec3,                    // deterministic-number type (see numbers research)
    pub carried_by: Option<Entity>,        // niche-free Option<Entity> provided by the crate
    pub arms: FixedVec<ArmTask, 8>,
    pub emote: EmoteKind,
    pub emote_tick: Tick,                  // time in ticks, like OctoEscape today
}
// `State` is implemented for: fixed-width ints, the number type, bool-as-u8, Entity, AssetRef, Tick,
// FixedVec/BitSet/FixedMap, List/Map handles, #[repr(u8/u16)] enums, other State structs.
// Not implemented for: &T, Box, Vec, String, usize/isize, HashMap, f32/f64 (if fixed-point wins) → compile error.
```

The derive also rejects padding by requiring `NoUninit`, which bytemuck's derive enforces
([bytemuck](https://docs.rs/bytemuck/latest/bytemuck/)). Without that, padding bytes would make hashes and desync
diffs lie.

### A gameplay system

```rust
pub fn emote(f: &mut Frame, a: &Assets) {
    // Fast path: typed join; borrows two different tables at once (checked at runtime per table, like RefCell).
    for (e, (oct, link)) in f.query_mut::<(&mut Octopus, &PlayerLink)>() {
        let cfg = a.get(oct.config);
        let Some(input) = f.input(link.player) else { oct.emote = EmoteKind::None; continue };
        if input.emote.was_released() { oct.emote = choose(input, cfg); oct.emote_tick = f.tick(); }
        if f.tick().since(oct.emote_tick) > cfg.duration(oct.emote) { oct.emote = EmoteKind::None; }
    }
}

pub fn friend_throw(f: &mut Frame, a: &Assets) {
    // "Handle" path: iterate a copied entity list, touch any entity freely. Never fights the borrow checker.
    for e in f.entities_with::<(Octopus, Carrying)>() {
        let friend = f.get::<Carrying>(e).unwrap().friend;
        let Some(fo) = f.get_mut::<Octopus>(friend) else { continue };   // stale handle → None
        fo.mode = OctopusMode::Air;
        f.events.emit(FriendThrown { carrier: e, friend });               // to the view; not state
        f.destroy_later(some_toy);                                         // structural removal at system end
    }
}

pub const SYSTEMS: &[System] = &[          // the schedule IS this list; compile-time, greppable, diffable
    sys!(input::apply_commands), sys!(spawn::players), sys!(octopus::movement), sys!(emote),
    sys!(physics::step),                    // external engine stepped as an ordinary system
    sys!(friends::friend_throw), sys!(objectives::update), sys!(cleanup::destroy_deferred),
];
```

- **Signals become function calls.** Replace `ISignalOnX` with `damage::apply(f, e, amount)` called directly.
  Component add and remove hooks only where the derive needs them (heap frees).
- **Commands:** a `Command` enum (serde/bitcode) carried in the tick's input set and applied by the first system.
  Rare and discrete, as OctoEscape does today.
- **RNG:** `f.rng()` from globals. Optional per-entity streams seeded by (entity, tick, salt), so adding a system
  does not shift every other roll.
- **Assets and config:** text files (RON/TOML) and glTF loaded into an immutable `Assets` with stable `AssetRef`
  ids. The session hashes all loaded assets into the checksum seed. A config hot reload in a multiplayer session
  must travel as a command, or clients diverge.
- **Footgun guards for agents:** the `sim` crate cannot depend on the host, so it cannot read host input or time.
  `clippy.toml` `disallowed-types` (std `HashMap`/`HashSet`, `Instant`, `SystemTime`) and `disallowed-methods`
  (`f32::sin` and the like if floats win, `rand::thread_rng`). A CI grep or dylint bans `static mut`, `thread_local!`
  and atomics in `sim`. Sync-test runs in every test and every dev session.

### External state: physics

A `SnapshotPart` trait (`save(&mut Vec<u8>)`, `load(&[u8])`, `hash() -> u64`) for anything the arena cannot hold.
The snapshot record is `{arena bytes, physics bytes, tick}`.

- **Jolt:** `SaveState`/`RestoreState` cover state modified by the simulation, not settings such as friction.
  `RestoreState` does not undo bodies added or removed in the rolled-back frames. Bodies must keep identical IDs
  (`CreateBodyWithID`). Cross-platform determinism needs `CROSS_PLATFORM_DETERMINISTIC` (about 8% slower), precise
  FP and no FMA contraction ([Jolt docs](https://jrouwe.github.io/JoltPhysics/index.html)).
- **Rapier:** serde-serializable sets plus `enhanced-determinism`. Snapshots load only in the same build. Event
  handlers and hooks are not included ([Rapier](https://rapier.rs/docs/user_guides/rust/serialization)).
- **Box2D 3.2** (2D, so a reference only) has the model we want: a full snapshot API where handles created after the
  snapshot fail validation after restore, plus `b2World_GetStateHash`
  ([snapshot](https://box2d.org/documentation/group__snapshot.html)).
- **Rule:** the arena is authoritative for which bodies exist (a `Body { id }` component). After a restore, a
  reconcile pass adds or removes bodies with fixed IDs to match the arena, then loads the physics blob. Physics
  callbacks are collected into an arena buffer and handled by a system in a fixed order (Jolt warns that listener
  order is non-deterministic).

### Late join, hot reload, tools

- **Late join** = zstd(snapshot record) plus the schema hash. It requires the same build, and the physics blobs
  require it anyway.
- **Layout descriptors** drive the in-game inspector, field-level desync diffs between two peers' snapshots, and
  state-keeping hot reload: migrate fields by name when a struct changes.

## The Bevy and Godot answer

**Option (b): separate engine-agnostic `sim` crate, with the host as view.** Arguments:

1. **The key design idea survives.** Under (a), state is scattered across Bevy archetypes plus `Resource`s.
   Snapshots become per-type clones into hash maps, checksums become XORs of opted-in types, and late join becomes
   Reflect serialization. Every unregistered type is a silent desync
   ([pitfalls](https://docs.rs/crate/bevy_ggrs/latest/source/docs/pitfalls.md)).
2. **Correctness is checkable.** In (b), state the sim doesn't own cannot exist. In (a), Bevy's `Local`, `Events`,
   change detection, `GlobalTransform` and query order are all documented traps.
3. **Fast agent loops.** `sim` tests compile without Bevy or wgpu, and headless N-client loopback is a plain
   `cargo test`. Bevy ships about every 4–6 months with breaking changes (0.19 in June 2026,
   [news](https://bevy.org/news/bevy-0-19/)), and bevy_ggrs lags each release. Under (b) the churn reaches only the
   view layer.
4. **Portability.** The same crate goes behind Godot (gdext), a custom wgpu host, or headless CI. The host choice
   can be revisited without touching gameplay.

**The cost of (b) is the bridge, but a different bridge from Unity–Quantum's.** That pain came from the DSL, map
baking, an asset DB export, and two physics worlds. Here components are plain Rust, the sim loads levels from glTF
itself (one physics world, owned by the sim), and assets are files both sides read. What remains is a view-sync
system: diff sim entities against view entities each render frame, spawn and despawn views by `kind`, and write
interpolated transforms. Two entity worlds exist, but the view world is derived and disposable. Expect about 200–500
lines per host plus per-kind view code **(unverified estimate)**.

**When (a) would win:** a fast prototype that leans on Avian (ECS-native physics) and Bevy tooling, with no
cross-platform determinism requirement. Avian's `enhanced-determinism` exists, but full cross-platform determinism
is still described as needing more testing ([Avian docs](https://docs.rs/avian3d),
[PR #457](https://github.com/Jondolf/avian/pull/457)). That conflicts with the Mac↔Windows crossplay requirement.

**Godot:** the case is stronger still. The scene tree is not an ECS. Godot rollback addons such as netfox roll back
node properties ([netfox](https://github.com/foxssake/netfox)), a different model from ours. Klotho (C#) also keeps
its deterministic core engine-free and runs its server without Godot
([asset](https://godotengine.org/asset-library/asset/edit/23181)). Run `sim` as a GDExtension (or link it into the
host) and use nodes as views.

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

1. **Keeping external physics consistent** with the arena across rollbacks (body add and remove, constraint order,
   callback order). Highest risk. The physics research and the spike settle it.
2. **Rust ergonomics** of `&mut Frame` with several tables borrowed at once: runtime borrow checks versus the
   handle path. Agents may write slower but correct code. Acceptable at this scale.
3. **Sync-test cost** with physics: N re-simulations per frame. With N = 4–8 and 1000 bodies, the tick must stay
   around 1–2 ms **(unverified)**. N may need to be lower in dev play.
4. **Growth and relayout** complexity, and schema migration for hot reload. Both are deferrable: fixed capacities
   first.
5. **Owning a custom ECS:** maintenance, missing features (relations, observers). Mitigation: keep it small and
   build only what gameplay needs.
6. **The number type** (float versus fixed) changes `State` impls and `disallowed-methods`, not the layout. Covered
   by the determinism research.
7. **Registration order** of component types defines the layout. Sort by stable type name, never by link order
   (`inventory`/`linkme` order is not guaranteed) **(unverified)**.

## Spike proposal (about 1–2 weeks of agent time)

Build `sim` (arena, tables, handles, globals and RNG, `FixedVec`, one heap `List<T>`, events, commands, sync-test)
plus a physics `SnapshotPart` (Jolt via a Rust binding, or Rapier). Port a slice of OctoEscape: simplified octopus
movement, emotes, toy pick-up and throw, and 1000 entities including about 300 dynamic toy bodies. Add a headless
N-client loopback runner and a minimal Bevy view with interpolation and view mapping.

**Pass:**
- Arena snapshot and restore of 1000 entities in < 100 µs, and arena plus physics in < 0.5 ms, on an M-series Mac
  and on Windows x64.
- Sync-test (rollback 4 ticks every tick) holds 60 Hz headless with the full slice. A 10k-tick random-input replay
  gives identical per-tick checksums twice, and across a restored-snapshot branch.
- The same replay gives identical checksums on macOS ARM and Windows x64 (with the chosen number type and physics
  flags).
- Five deliberately planted bugs are caught by a compile error or by sync-test within 10 ticks: a `static` counter,
  a std `HashMap` iteration, a `Vec` in a component, a body added without arena tracking, and an RNG call in a
  view-only path.
- An agent adds a new mechanic (for example "slap knocks toys") from a one-paragraph spec, with no state outside
  `Frame` and fewer than 3 compile-fix rounds.
- The Bevy view shows no visible jitter at 144 Hz with 150 ms simulated RTT. A mispredicted spawn does not hijack
  another entity's view.
- An edit to the `sim` crate followed by `cargo test` of the slice takes < 10 s on the Mac.

**Fail (rethink):** physics restore cannot be made to match the arena without rebuilding the physics world each
rollback, or the handle-and-query API forces unsafe code or constant borrow fights in ordinary gameplay. In the
second case, re-evaluate a bones-style `World::clone()` store.
