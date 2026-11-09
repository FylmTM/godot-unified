# 11: View binding and authoring (sim entities ↔ Godot)

Research for `unified` (2026-11-08). How sim entities get their Godot-side views (scenes, materials, animation, VFX,
audio, UI), and how entity templates and levels are authored. Sources: the view layer of the developer's current Unity
game, an early Godot host benchmark (1000 agents + 300 props driven from Odin; the code is gone, results in git:
`git show 6994822:docs/archive/bench/b/RESULTS.md`), `spec/netcode.md`, and the Godot docs linked at the end. Claims I
couldn't check against a primary source are marked *(unverified)*.

The plan already decided the direction: "`.tscn` scenes per entity kind… GDScript allowed in the view layer…
the extension runs the sim and maps sim entities to scenes". This doc works out how.

## TL;DR

- **The core loop**: a sim component names a view asset; one updater diffs sim entities against live views every
  render frame; views poll predicted/verified frames; events are deduplicated, confirmed or cancelled; interpolation
  and rollback error correction live in the updater, not in game scripts.
- **Fix three things that hurt in the current game's view layer:** (1) views keyed by entity handle get *hijacked* and
  churn after a rollback, so key them by a deterministic **spawn key** instead; (2) events are global and every view
  filters (a per-entity view subscribes to every event of its kind), so **route entity events to that entity's view**;
  (3) authoring needs a bake step, an asset DB and editor-only tooling (the slowest loops today), so make **prototypes
  code/data-first** and levels files both sides read.
- **Recommendation: option C** (scenes for rich kinds, native MultiMesh for bulk kinds), with B's API as the default
  path, all interpolation, error correction, pooling and event bookkeeping in a host-agnostic Odin `view` package,
  and a thin Godot adapter. Prototypes in Odin code plus data files; levels from glTF/layout files, previewed in Godot.

## 1. Lessons from the current game's view layer

- **Binding.** A sim component names the view asset; clearing it destroys the view, changing it recreates it. One
  updater per render frame diffs entities against live views. Each kind binds on **predicted** frames (projectiles:
  responsive) or **verified** ones (player characters: no false spawns). A view whose entity is gone is destroyed
  **after event dispatch**, so events about a dying entity still find it. Pooled views must unsubscribe from events
  on deactivate, and a manual-disposal flag lets a death event play out before the view returns itself. Pre-placed
  level entities are linked by index, not instantiated.
- **Hijacking.** Views keyed by entity handle break under rollback: a predicted spawn gets handle X; the verified
  re-simulation creates another entity first, which now gets X. With the same view asset, the old view is relinked to
  the wrong entity with the wrong data; with a different one, it is destroyed and recreated. Binding on verified, or
  re-polling everything every frame, only works around it.
- **Frames and interpolation.** Views read the verified frame, the predicted one, predicted − 1, and the previous
  update's head (re-simulated). Interpolation modes per kind: **prediction** (lerp predicted−1 → predicted by render
  alpha, plus error correction: the jump a rollback causes is decayed at a rate ramped by error size, snapped below a
  minimum, teleported above a distance); **snapshot** (verified frames only, ~4 ticks behind, never wrong);
  **exponential decay** (ease the transform toward the sim each frame; cheap, tolerates external writes). A sim-side
  teleport makes the view snap.
- **Events.** Dispatched once per update after the views update, so views for new entities exist. Duplicates from
  re-simulation are dropped by hashing (event id, tick, fields), with jittery fields left out. Non-synced events are
  later **confirmed or cancelled**; synced events fire only from verified frames. Poll for continuous visuals, use
  events for one-offs; late joiners never get past events.
- **Prototypes and maps.** A prototype is a serialized entity (component set plus initial values), materialized at
  spawn. Today it is authored on an editor prefab through generated components and indexed into an asset DB;
  level scenes are baked into a map asset (static colliders, navmesh, scene prototypes) on save, play and build. The
  bake isn't deterministic (float → fixed point), so its output must be shared, not recomputed.
- **Culling.** View culling filters which entities get views; prediction culling skips far entities in predicted
  frames.

### What the current game actually used, and what hurt

- **Every** entity view binds on predicted frames with exponential decay: no manual disposal, no view flags, no
  pooling. The player-character view alone is over 1,000 lines (its own body smoothing over sim re-attachments, the
  procedural rig).
- Events: audio and effects subscribe globally; per-entity views subscribe to every event of a kind and filter by
  entity. **No code handles cancelled events**: cancelled effects just play. Celebrations come from *verified state*
  that the audio code watches, not events. Time is in ticks; the view derives elapsed time.
- What hurt: an asset DB refresh of ~20 s when an asset is added; prototypes' collider
  layer filled on prefab save, which builders must replicate; maps rebaked on scene save; a codegen line-ending patch
  inside the SDK; a JSON export of the whole DB versioned just so tests can run without the editor; a loaded map
  asset holding live state (two sessions in one process read freed memory). **Levels were never hand-placed in
  Unity**: a level builder regenerates them from Python/Blender layout files ("hand edits… are lost on a rebuild").
  The editor was a bake target, not the authoring tool.

## 2. Design options for unified + Godot

Shared by all options (host-agnostic, in Odin): every viewed entity has a hashed `View` component in the state block.

```odin
View :: struct {
	kind:     Kind, // game enum: .Player, .Toy, .Dart, ...; .None = no view
	key:      u32,  // deterministic spawn key: map index, or hash(spawn tick, spawner key, per-tick seq)
	teleport: u8,   // bumped by teleport(); the view snaps when it changes
}
```

### (A) Odin drives Godot directly

The extension creates RenderingServer instances, MultiMeshes and nodes from code; no per-kind scenes.

```odin
frame :: proc "c" () {
	diff := view.sync(&vs, sess) // spawns, despawns, interpolated transforms per kind
	for s in diff.spawned do inst[s.slot] = rs_instance_for(s.kind) // mesh + material from a code table
	for k in Kind do gd.RenderingServer_multimesh_set_buffer(rs, mm[k], diff.xforms[k])
}
```

- **Pros**: fastest (the host benchmark: 1000 agents + 300 props in ~10 engine calls, 0.3–1.0 ms CPU/frame); works
  with today's bindings (no class registration); one language; everything agent-editable text.
- **Cons**: nothing visible or tweakable in the editor; animation, VFX, audio and UI all become Odin code against
  Godot APIs, with manual refcounting (the host benchmark leaked 822 objects before `defer unref`); against the
  decided direction (scenes per kind).

### (B) Godot owns views: a `.tscn` per kind

The extension pools and spawns `res://views/<kind>.tscn`, writes the interpolated transform, and calls the scene's
script; view logic is GDScript reading read-only sim state.

```gdscript
# res://views/toy.tscn, root script
extends SimView                       # Node3D subclass registered by the extension
@export var squeak: AudioStream

func _sim_spawned(f: SimFrame) -> void:  # from pool or new; entity and kind already set
	$Mesh.set_instance_shader_parameter(&"tint", f.color(entity, &"Toy.color"))
func _sim_update(f: SimFrame) -> void:   # every render frame, after the transform is written
	visible = f.get_f32(entity, &"Toy.broken_time") == 0.0
func _sim_event(e: SimEvent) -> void:    # only events whose entity is this one
	if e.type == &"ToyPicked": $Squeak.play()
func _sim_event_cancelled(e: SimEvent) -> void:
	$Squeak.stop()                        # or fade
func _sim_despawned() -> void:           # reset for the pool
	$Squeak.stop()
```

- **Pros**: assets, materials, AnimationTree, GPUParticles, AudioStreamPlayer3D all authored and previewed in the
  editor; GDScript hot-reloads; matches the decided direction; the scene is the obvious place for per-kind settings
  (bind mode, smoothing, linger, pool size as `@export`s on the root).
- **Cons**: per-node cost at 1000+ (Godot's own docs: nodes have "extra overhead" and servers are for "tens of
  thousands of instances"); GDScript needs a typed way to read sim state, which needs **extension class
  registration** (missing in our Odin bindings: ~1–1.5k lines, 1–2 weeks per the host benchmark's estimate); the
  benchmark's `frame` callback runs *after* `_process`, so the sync must move earlier (a registered `UnifiedSession`
  node with a very low `process_priority`) or GDScript sees last frame's data.

### (C) Hybrid: bulk kinds as MultiMesh, rich kinds as scenes

B's API, plus a second render mode per kind. A bulk kind is still authored in Godot, as a resource rather than a
scene.

```gdscript
# res://views/dart.tres   (SimBulkView resource)
mesh = preload("res://art/dart.glb::mesh")
material = preload("res://art/toon.tres")
custom_data = [&"Dart.owner_color"]   # packed into MultiMesh INSTANCE_CUSTOM by native code
```

```odin
// Odin: one pass over the kind's dense table, written straight into the PackedFloat32Array
for b, i in vs.bound[kind] do write_3x4(buf, i, view.pose(&vs, b, alpha)); buf_custom(buf, i, ...)
gd.RenderingServer_multimesh_set_buffer(rs, mm[kind], buf)
```

- **Pros**: scenes where richness matters (players, bosses, crabs), native speed where count matters (1000 enemies,
  projectiles, shards); both editor-authored; the host benchmark already proves the bulk path. A bulk kind can be
  promoted to a scene (a boss) without touching the sim, since the sim only knows `kind`.
- **Cons**: two render paths to maintain; bulk kinds get no per-instance scripts, animation or audio (events for
  them go to global listeners: an audio router, a VFX router); per-instance animation for bulk needs vertex animation
  textures *(unverified need)*.

### Authoring templates (prototypes) and levels

| | **T1: Godot scenes as source, baked** | **T2: code/data-first** |
|---|---|---|
| Prototype | `.tscn` with a `SimPrototype` node and one Resource per component (`ToyComponent.tres`), classes generated from the Odin structs | Odin spawn procs (`spawn_toy(f, at, cfg)`) plus tuning data files the sim loads and hot-reloads |
| Level | Godot scene with prototype instances and collision shapes; `unified bake` parses the `.tscn` text (no Godot needed) into a level blob | glTF from the Blender/Python pipeline (geometry + node extras: `{"sim": {"kind": "hoop", "channel": 3}}`) or a `layout.json`; sim reads colliders and markers, Godot imports the same file for visuals |
| Editor preview | native: the prototype scene is also its view | an `EditorScenePostImport` script swaps markers for their kind's view scene, so the level looks right in the editor |
| Pros | drag, place and tweak in the editor; one file per kind | no bake, no DB, no generated Godot classes; tests and agents never need the editor; one source of truth; matches how the current game's levels are made |
| Cons | generated per-component classes, a bake step, two schemas to keep in sync: the family of pains listed above | placement happens in Blender/scripts, not in Godot; numbers need hot reload to tweak live |

A middle option (T3): Godot level scenes containing only `SimMarker` nodes (kind + a few exported overrides), parsed
from the `.tscn` by the CLI. Components themselves are never authored in Godot.

## 3. Rollback concerns

The shared Odin `view` package handles all of these the same way for every option; the table shows what differs.

| Concern | Mechanism (all options) | A | B | C |
|---|---|---|---|---|
| **Spawn/despawn churn** | Bind per kind on `.Predicted` or `.Verified`. Views keyed by **`View.key`**, not handle: if a rollback re-creates the same logical entity under another handle, the view is *rebound*, not recreated (no hijacking). A view whose entity disappears **lingers hidden** for `linger_ticks` (default: until that tick is verified) and is revived if the key reappears; only then does it go back to the pool. Per-kind pools, prewarmed. | free-list of instances | `SimView` pool per kind; `_sim_despawned` must reset | as B; bulk = swap-remove in the buffer |
| **Predicted events and cancellation** | Event buffer per tick stored with the snapshot ring; key = (type, tick, entity key, hashed fields); confirmed or cancelled when the tick is verified; `synced` only from verified. Dispatch after spawns (new views exist), before despawns (dying views still get them). Entity events go to that view, every event also to global listeners (signals on `UnifiedSession`). | Odin callbacks | `_sim_event`, `_sim_event_cancelled` | bulk kinds: global routers only |
| **Interpolation, teleports** | Odin computes every pose: lerp/nlerp of predicted−1 → predicted (both from the snapshot ring, which holds re-simulated states after a rollback), plus error correction (keep the last rendered pose, decay the offset, snap below a minimum, teleport above a distance), snap when `View.teleport` changes. Our own clock, not Godot's physics interpolation: the tick rate is nudged ±2% for time sync (`spec/netcode.md`) and rollbacks rewrite history. | written to RS | written to `Node3D.transform` before `_sim_update` | both |
| **Determinism boundary** | The view API is read-only (`SimFrame` has no setters); the only way in is input and commands. In dev builds, checksum the state block before and after the view phase (one XXH3 over the block) to catch native writes. | needs that check most | GDScript cannot write at all | same |
| **Editor preview** | | none, unless the extension draws in the editor | open `views/<kind>.tscn`; a `@tool` script can fake state | bulk resources preview as a mesh |
| **1000+ entities** | | proven: ~1 ms CPU for 1300 instances (host benchmark) | unmeasured; GDScript `_sim_update` on 1000 nodes is probably several ms *(unverified)* | bulk path proven; scenes only for tens to low hundreds |

Also worth adding later: a snapshot-interpolation mode (verified-only, delayed) for remote entities, view culling,
and prediction culling. None are needed for 4 players in one level.

## 4. Recommendation

**Option C with T2 authoring.** Everything rollback-specific lives in an Odin package that knows nothing about Godot
and is tested headless; the Godot adapter only applies diffs and calls scripts.

**Odin side (`unified:view`, host-agnostic):**

```odin
Bind      :: enum u8 { Predicted, Verified }
Smoothing :: enum u8 { Predicted, Decay, Snapshot }
Kind_Info :: struct { bind: Bind, smoothing: Smoothing, linger_ticks: u16, bulk: bool }

View_Sync :: struct { /* bindings by key, per-kind dense pose arrays, played-event set, error offsets */ }

init     :: proc(vs: ^View_Sync, kinds: []Kind_Info)
sync     :: proc(vs: ^View_Sync, s: ^Session, alpha: f32) -> ^Diff // spawned, rebound, despawned, events, cancelled
pose     :: proc(vs: ^View_Sync, b: Binding, alpha: f32) -> Pose // interpolated + error-corrected
teleport :: proc(f: ^Frame, e: Handle, pos: Vec3, rot: Quat)    // sim side: sets transform, bumps View.teleport
```

**Godot side (GDExtension classes):**

- `UnifiedSession` (Node): runs the sim, clock, input polling (`_sim_poll_input`), and the view sync early in the
  frame. Signals `sim_event(e)`, `sim_event_confirmed(e)`, `sim_event_cancelled(e)`. `predicted()` and `verified()`
  return `SimFrame`.
- `SimView` (Node3D): root of a kind's scene. Properties `entity`, `kind`; virtuals `_sim_spawned`, `_sim_update`,
  `_sim_event`, `_sim_event_cancelled`, `_sim_despawned`; `@export`s for bind, smoothing, linger and pool size.
- `SimBulkView` (Resource): mesh, material, custom-data fields.
- `SimFrame` (RefCounted): `tick`, `is_verified`, `has(entity, &"Toy")`, `get_f32/get_i32/get_vec3/color(entity,
  &"Comp.field")`, `global(&"Global.field")`. Field lookups are resolved once from Odin's type info into offsets and
  cached by StringName.
- Kind → view by convention: `res://views/<kind>.tscn` or `.tres`, checked at startup (a missing view is an error,
  not a silent invisible entity).

UI (HUD, goals) reads `session.verified()` for anything that must not flicker and `predicted()` for the local
player's immediate state. Audio and VFX: one-offs from predicted events with cancel fades, celebrations from
verified state or synced events, loops from state.

## Questions for the developer

1. **C over pure B?** Accept two render paths (scenes plus native MultiMesh) for the 1000-entity case, or start B-only
   and add bulk later?
2. **Class registration in our Odin bindings** (1–2 weeks est.) is the price of B and C: `SimView`, `SimFrame` and
   virtuals need it. Accept it, or start with a push-only bridge (Odin sets properties and calls `Object.callp`, no
   GDScript→Odin calls) and register classes later?
3. **Authoring: T2 (code/data-first, glTF/layout levels), T1 (Godot scenes baked) or T3 (Godot level
   scenes with markers only)?** I recommend T2, since the current game's levels already come from scripts.
4. **Spawn keys**: OK to require every spawn to carry a deterministic key (a few lines per spawn site, enforced by
   the spawn API), in exchange for no hijacking and no view churn?
5. **Default bind and smoothing**: the current game binds on predicted frames with exponential decay everywhere. Keep
   that as the default, with Verified for player characters?
6. **How much view logic in GDScript vs Odin?** The character rig (over 1,000 lines today) is the test: GDScript for
   speed of iteration, or Odin for speed and the "one language" rule? (Earlier host research suggested writing the
   rig ourselves, host-agnostic.)
7. **Benchmark before deciding**: 1000 `SimView` scenes with a trivial `_sim_update` vs 1000 bulk instances, to set
   the scene-count budget per frame.

## Sources

Ideas from existing Godot rollback add-ons, in our terms: roll back node properties and play a sound once per tick
(dedupe by tick and identifier); nodes spawned inside the rollback window are deactivated, not freed, while a rollback
could still need them (one contiguous liveness interval per node); a `teleport()` on the interpolator; ticks counted
by timers and animation players stepped per tick. ECS bridges that make nodes the entities (or components Resources)
are the opposite of our pointer-free state block, useful only as a T1 authoring reference.

Godot 4.7: [MultiMesh](https://docs.godotengine.org/en/stable/classes/class_multimesh.html)
(`set_buffer_interpolated`, `reset_instance_physics_interpolation`, custom data),
[MultiplayerSpawner](https://docs.godotengine.org/en/stable/classes/class_multiplayerspawner.html) (a list of
spawnable scenes plus `spawn_function(data)`: the same "kind → scene" registry idea, without rollback),
[using servers](https://docs.godotengine.org/en/stable/tutorials/performance/using_servers.html),
[physics interpolation](https://docs.godotengine.org/en/stable/tutorials/physics/interpolation/physics_interpolation_introduction.html).
