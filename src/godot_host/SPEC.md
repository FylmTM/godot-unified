# godot_host and gdext

Decided autonomously 2026-11-09, pending developer review.

`src/gdext` holds the Odin bindings for Godot's GDExtension API. `src/godot_host` is everything that touches
Godot for a game built on `unified`. Each game has a thin extension (`games/<game>/simulation/extension`) that
installs its sim and its glue.

## gdext

- **Generated code.** `uni godot-gen` (~1 s fresh, cached by input hash) turns the committed
  `src/gdext/api/{extension_api,gdextension_interface}.json` (dumped from 4.7.2) and `bindings.txt` into
  git-ignored `gdi/gdi.gen.odin` (the C interface) and `api.gen.odin` (layouts, enums, typed wrappers
  `Class_method`). No Godot is needed to build.
- **Wrappers.** They use ptrcall. Strings in and out are Odin `string`s; a method with StringName parameters is
  a proc group that also takes interned `^StringName`s (`gd.sn("move_left")`, no per-call conversion; hot paths
  use it). Returns of RefCounted classes are `Ref(T)`, which the caller owns (`unref`). Vararg methods take
  `..any`. Debug builds check the main thread. `bindings.txt` lists only what Odin code uses (`tests/gdext`
  fails on an unused entry).
- **Extension classes.** `Class{name, parent, size, init, fini, notification, ready, process, input,
  runtime_only}`, then:
  - `bind_method(cls, name, proc(self: ^T, a: A, b: B) -> R, {"a", "b"})`, with 0–3 arguments and one typed
    trampoline per signature;
  - `bind_property(cls, name, get, set, hint)`;
  - `bind_signal(cls, name, {"arg", type}...)`;
  - `bind_script_virtual`, `emit_signal`, `call_script`;
  - `callable_create(proc, user, owner)`, `connect`;
  - `sn("name")` returns interned StringNames.
- **Callbacks.** Every Godot -> Odin callback opens a temp-allocator guard: a nested callback (Odin calls Godot,
  Godot calls back into Odin) never frees its caller's temp data.
- **Value conversions.** `to_variant`, `from_variant`, `variant_from_any`, and the `dict_*` / `array_*` helpers.
- **Tests.** `uni test --suite godot-bindings` runs a test class (`tests/godot`) under headless Godot (`--verbose`; an
  orphan StringName or a leak at exit fails it) covering every feature above, again through typed calls (checked to
  take ptrcall), a nested callback, plus a dev UI smoke test.

## godot_host API

```odin
godot_host.install(&GAME, glue)            // sim.Game(S, I, W, P) + Glue(S, I, W)
godot_host.set_transport(&transport)       // optional: online play (EOS...), never imported by godot_host
return godot_host.entry(gpa, lib, init)    // the extension's entry symbol
Glue { scenes: []Scene_Kind{name, data: typeid}, scene_dir, bulk_kinds, smoothing /* view.Smoothing in extract's units; zero: the default (a warning for 2D views) */,
       actions: {move: [4]string, buttons: []string},
       extract(cur, prev, world, ^Frame), sample(Actions, slot, tick, ^S) -> I, scripted(seed, slot, tick, ^S) -> I,
       scripted_commands(seed, slot, tick, ^S, ^sim.Command_Out) /* optional: --scripted sends these */,
       hud(^Frame /* nil: every key empty */, ^Dictionary), constants(^Dictionary), bench, event_key,
       event_pos(pos, ^W) -> pos /* optional: events in extract's units, e.g. metres or cells to pixels */, compat,
       level /* res:// path of the level file, read with FileAccess at session start: src/level/SPEC.md */ }
godot_host.app_version                     // application/config/version, read before the first session
Frame { tick, verified, due_us, local_slot, net, scene: [256]Scene_Item, bulk: [16384]Bulk_Item, dropped, hud: [4096]u8 }
Scene_Item { key, kind, slot, entity, has_prev, pos, rot /* quaternion */, prev_pos, prev_rot, data: [64]u8 }
Bulk_Item { kind, has_prev, pos, prev_pos, yaw, prev_yaw, scale: [3]f32 /* zero = 1 */, color /* zero = white */, custom }
push_scene(out, item) / push_scene(out, item, data: T) -> bool    // extract: append; false (and `dropped`) when full
push_bulk(out, item) -> bool
```

GDScript sees contract v0:

- **`UnifiedSession`**
  - methods: `start_single`, `host_online`, `join_online(code)`, `join_direct(addr)`, `leave`,
    `press_action(name)` (one of `Glue.actions.buttons`, as if pressed), `hud()`, `constants()` (`tick_hz` plus
    `Glue.constants`: scripts read the sim's constants instead of copying them);
  - signals: `status_changed`, `lobby_code`, `sim_event`, and `sim_event_2d` (the same, position a Vector2) when
    `view_root` is a Node2D;
  - added for the game client: `view_root` (any Node, a Node3D or Node2D in practice), `host_direct(port)`,
    `set_player_name`, `get_status`,
    `is_running`, `get_tick`, `toggle_devui`;
  - `set_input_vector(i, v)`: view-dependent input (a third-person camera's look direction and right), the
    latest value; the game's `sample` reads it as `Actions.vectors[i]` (i < 4); `set_input_vector_2d(i, v)` takes
    a Vector2 (z = 0), e.g. a 2D aim direction;
  - `send_command(name: StringName, args: Dictionary) -> bool` (signed off 2026-11-10): sends one of the game's
    commands (`sim.Game.commands`, src/sim/SPEC.md), delivered to the sim exactly once. The host converts the
    Dictionary into the command's struct by RTTI, no per-game glue: ints (range-checked), floats, bools, enums (a
    member's name in any case, or its value), bit_sets (an Array of member names or values), `[2]f32` / `[3]f32`
    from Vector2 / Vector3; every field must be given (fields named `_...` are padding: never). An unknown
    command, a missing or unknown field, a wrong type or range, no running session or a full queue (64 waiting)
    returns false with a `print_error` naming it. Main thread; queued to the session thread, which hands it to the
    client's `commands` hook (the command's tick is the next one the client samples).
- **`SimView`** (Node3D: `kind`, `entity`, `slot`, script virtuals `_sim_update(position: Vector3, yaw, alpha)`
  and `_sim_event(kind, data)`).
- **`SimView2D`** (Node2D: the same, with `_sim_update(position: Vector2, rotation, alpha)`).
- **`SimBulkView`** (MultiMeshInstance3D: `kind`), **`SimBulkView2D`** (MultiMeshInstance2D: `kind`); both join
  the `sim_bulk` group.

Plain Node3D / Node2D / MultiMeshInstance3D / MultiMeshInstance2D roots with the same script properties work too
(a plain bulk node joins `sim_bulk` itself). Scripts run without the extension that way, and the host uses
`Object.set`/`call`.

**2D views** (signed off 2026-11-09). A view scene's root class picks the mapping, so one game may mix both:

- Position: `Vector2(pos.x, pos.y)` in Godot's 2D coordinates (x right, y down), in `view_root`'s units (pixels
  unless it is scaled); `pos.z` is unused. `extract` writes view units (render side: f32 math is fine there), and
  a game in pixels sets `Glue.smoothing.teleport_dist` in pixels: a tick-to-tick move or a correction longer
  than it snaps.
- Rotation: the angle about Z (`Node2D.rotation`: 0 = +x, positive turns +x toward +y, clockwise on screen):
  `Scene_Item.rot = view.quat_angle2d(a)`, `Bulk_Item.yaw = a`. The host sets the root's `position` and
  `rotation`, then calls `_sim_update(Vector2, rotation, alpha)`; `_sim_event` data carries `position` as a
  Vector2. The `sim_event` signal keeps its Vector3; `sim_event_2d` carries a Vector2. Event positions are the
  sim's units unless the game sets `Glue.event_pos` (session thread, with the World) to convert them into the
  units its `extract` writes, so views and effects never scale them by hand (signed off 2026-11-10).
- Bulk: the MultiMesh's `transform_format` decides the layout: `TRANSFORM_2D` writes 8 floats per instance
  (`cs, -sn, 0, x,  sn, cs, 0, y`, uniform scale in cs/sn), `TRANSFORM_3D` 12; then the color (`use_colors`)
  and the custom data (`use_custom_data`), 4 floats each. A node whose MultiMesh has the other format is
  warned about once. The host owns `instance_count` and `visible_instance_count`.
- `Bulk_Item.color` (new, 16 bytes per item): the instance color when the MultiMesh uses colors (it was always
  white): tints and flashes need no shader, since the default materials multiply by it. Zero means white, so
  games that never set it are unchanged; an invisible instance is simply not emitted.

**Scene view data** (signed off 2026-11-10). A kind may name a data type (`Scene_Kind.data`): a plain struct
of bools, integers, enums (as int), f32, `[2]f32` (Vector2), `[3]f32` (Vector3) and `[4]f32` (Color), at most 64
bytes; fields starting with `_` are padding. `extract` writes it with `push_scene(out, item, data)` (asserted to
be the kind's type). The host sets each field as the view's property of the same name, after the view entered
the tree (setters may use `@onready` nodes) and then only when that field's bytes change, before
`_sim_update`. Values are the newest tick's (no interpolation). A view with no such property is warned about
once. Per-entity values that used to go through the HUD (a player's hp, a gate's charge) go here; the HUD stays
for the HUD.

**Bulk** (2026-11-10): position and rotation interpolate (`prev_yaw`, along the shorter arc); `scale` is per
local axis (2D: x, y), zero meaning 1; color and custom are the tick's. One pass over the frame's items fills
every bulk view's buffer. `MAX_BULK_ITEMS` 16384 costs memory only (three Frames); a full Frame counts
`dropped` and the host warns once.

## How it works

- **Threads.** A session (single player = a host with no remote links; host; join) runs netcode's
  `host_step`/`client_step` on its own thread. On macOS that thread uses the real-time (time-constraint) class
  and sleeps until the next deadline. While a session runs, the process opts out of background throttling
  (often a hosting player's game is in the background): on macOS, a user-initiated, latency-critical
  NSProcessInfo activity (no App Nap, no idle system sleep); on Windows, `timeBeginPeriod(1)` (Sleep rounds
  up to 15.6 ms without it) plus opting out of power throttling, since Windows 11 ignores a minimised
  process's timer request. The netcode hooks run there:
  - `sample` reads the input atomics, or scripted input in headless checks;
  - `frame` feeds the predicted ticks' events to the tracker and publishes a Frame (`extract`);
  - `verified` confirms or cancels events;
  - `status` posts the status.

  Godot is only called from the main thread.
- **Main thread.** `UnifiedSession._process` runs at priority −1000, before every other node:
  1. samples the InputMap actions into atomics (button presses accumulate until a tick takes them);
  2. takes the newest Frame;
  3. updates the scene views: spawn by key into `view_root`, push the poses of ticks P−1 and P into each view's
     `view.Track`, sample with alpha and `Glue.smoothing`, set position and quaternion (2D: position and
     rotation), call `_sim_update`;
  4. writes each bulk view's MultiMesh buffer in one `set_buffer` (one pass over the items; interpolated, stride
     from the MultiMesh's transform format and flags);
  5. routes events: predicted ones and cancels go to `_sim_event` on the entity's or slot's view, verified ones
     go to the `sim_event` signal;
  6. draws the dev UI (`dev.odin`; `-define:UNIFIED_DEVUI=false` compiles it out, see `src/devui/SPEC.md`).
- **Remote links.** Each goes through a `Dev_Link`: straight to the transport while the dev UI's Netsim panel is
  off, through a `netcode.Net_Sim` (created on first enable) while on, drained after.
- **Failures.** A transport's `fail(reason)` is the session's last status: no generic Failed follows it.
- **Leave, then Host or Join.** `leave` asks the session to end; it says goodbye on its thread (a client's Leave
  is acked within ~0.5 s, a host waits up to 3 s for its peers' acks). A start during the goodbye is accepted:
  it waits and starts as soon as the old session is gone. The goodbye is cut to 1 s, and the old session's
  last statuses and events are dropped. A `leave` before that cancels the waiting start.
- **Editor.** Classes register at SCENE level and nothing runs in the editor. Hot reload is editor-only.
  `deinitialize` stops the session thread, then calls the transport's optional `shutdown` (the survivor
  releases EOS there: left initialized, the SDK crashed in its own threads at exit, ~2 exits in 3). macOS dev builds are versioned files behind a symlink, because dyld
  never unloads an Odin dylib (thread-locals), so a same-path reload would keep the old code.
- **Tests.** `tests/godot_host` runs the driver with the toy game, no Godot: single player (frames, one press
  delivered once, confirmed events, result), transport failure (one Failed, its reason), transport open/stop/close,
  and the Dev_Link switch. `tests/godot_views` (`uni test --suite godot-bindings`) runs a single-player toy session
  under headless Godot with fixed 2D and 3D items: typed and plain 2D scene views and a 3D one under a Node2D
  view_root (position, rotation, `_sim_update`, a 2D `_sim_event`), the MultiMesh buffers of a typed 2D bulk view
  (colors and custom data, rotation on the shorter arc, scale per axis), a plain one (stride 8) and a 3D one, typed
  scene data set as properties only when it changes, `sim_event_2d`, and `send_command`: the toy's commands reach the
  sim once, in order, every field kind converted (read back through the HUD), and each refusal returns false with its
  error line (the suite expects those lines and no others). Its extension doesn't link Box3D. Its
  `session_check.gd`, on the same toy session, checks starting during a goodbye: leave then start single player,
  leave then host on the same port, and a start cancelled by a second leave.
- **Commands.** `uni build|run|editor <game>`; `uni test <game> --suite godot` steps `editor` and `session`.
  `session` runs a scripted single-player session under headless Godot and compares its checksums with the offline
  headless binary's.

## Open

- F3 extras: snapshot, input log, net stats.
- Typed `SimFrame` reads by reflection path for scripts.
- Pooling scene views.
- Real-time thread classes on Windows and Linux (to be measured).
- Running-game hot reload (needs the shim design).
