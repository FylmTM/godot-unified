# Survivor client (Godot content)

Decided autonomously 2026-11-09, pending developer review.

The Godot side of `games/survivor/`: everything except `simulation/`. Hand-written `.tscn`/`.gd`, no editor needed.

## Layout

```
project.godot          Forward+, 1280x720, canvas_items stretch, InputMap, autoloads, audio buses
export_presets.cfg     "macOS" (universal, thinned by tools/release.py) and "Windows Desktop"; library from .uni/bin/
game/survivor.gdextension   entry unified_init, res://.uni/bin/libsurvivor.dylib | survivor.dll | libsurvivor.so
game/autoload/         Settings (user://settings.cfg), Sfx (procedural sounds), Game (flow + session)
game/session/          MockSession: the contract in GDScript with a fake sim
game/ui/               theme (code-built), main menu, settings, connect overlay, HUD, Esc menu
game/arena/            level (floor, walls, pillars, lights), start circle, arena (views root, camera), follow camera
game/views/            player/crate/barrel scenes (GameView), GameBulkView (MultiMesh)
game/fx/, game/shaders/  event effects; floor, start circle, bulk (toon + hit flash), gem shaders
game/tools/            validate.gd, ui_walk.gd, log_capture.gd (not exported)
```

## Flow

`Game` owns the session for the app's lifetime: the native `UnifiedSession` if `ClassDB.class_exists`, else
`MockSession` (`-- --mock` forces it). States: MENU → CONNECTING → PLAYING, driven by `status_changed`:
`connected` loads the arena; `failed`/`disconnected` leave to the menu, which shows the detail once. The sim's own
phases (lobby → match → over → lobby) are read from `hud()` every frame (`Game.hud`); the arena never reloads
between matches. Esc opens an overlay; the sim never pauses. `-- --smoke-test` starts single player at boot.

## Session contract (v0 plus these details)

GDScript drives views through `Object.set/call` only, so the same scenes work with the native host and the mock,
and load without the library (Godot replaces unknown native node types with a placeholder `Node`).

- `view_root: Node3D` property (extension): set by the arena on load, cleared on exit; views spawn under it.
- Scene views: `res://game/views/<kind>.tscn`, root `Node3D` with script properties `kind`, `entity`, `slot` (-1 if
  not a player), set before `add_child`. Each frame: `position` = interpolated body centre, then
  `_sim_update(position, yaw, alpha)`. Entity events: `_sim_event(kind, {tick, position, value})`.
- Bulk views: `MultiMeshInstance3D` in group `sim_bulk` under `view_root`, property `kind` (grunt, runner, brute,
  projectile, gem). 3D transforms + custom data (r = hit flash 0..1, g = age in s), no colours; positions on the
  floor plane (y = 0), the shaders lift the meshes.
- `set_player_name(name)` and `hud().players[i].name` (extension, optional): names fall back to "P<n>".
- `host_direct(port)` (extension): LAN/dev hosting from the address panel (port 7777); the lobby panel shows this
  machine's first private IPv4 `host:port` where the code would be.
- Views may get `_sim_event("despawned", {})` (they linger ~0.25 s; exit animation) and `_sim_event("revived", {})`
  when a rollback brings one back; the host also sets the root's rotation (player views reset it).
- Single player emits `status_changed("connected", …)` from `start_single()`; failures carry a readable detail.
- Input is sampled natively from the InputMap; GDScript only handles `menu` (Esc) and, with the mock, `toggle_devui`.

## Checks

`python tools/dev.py game validate` (compile every script, load and instantiate every scene, flag unknown `.tscn`
properties, run the menu 30 frames; ~0.5 s) and `game walk` (headless scripted walk through every flow with the mock,
real input events; ~2.5 s). `game shots` runs the walk in a window and writes PNGs to `games/survivor/.uni/shots/`.
`tools/game.py` lists in `.godot/extension_list.cfg` only the extensions whose library exists for this host.

## Art direction

Stylized low-poly primitives with toon shading on a dark slate arena with a 2 m grid. Players warm and bright
(orange, gold, pink, violet per slot) with a glowing floor ring; enemies cool per kind (steel-blue hex capsule
grunts, teal three-sided runners, violet brute cubes); glowing yellow projectiles and green gems (bloom); wooden
crates and red barrels. Cyan for the start circle, wall trim and codes. No assets: meshes are primitives, sounds
are synthesized at boot.
