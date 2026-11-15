# godot

Contract v1, decided in the #9 sitting (2026-11-15, the decisions in that issue). `unified:godot` is everything that
touches Godot for a game built on `unified`; `unified:gdext` (its own SPEC.md) is the raw bindings underneath. Each
game has a thin extension (`games/<game>/simulation/extension`) that installs its sim and its glue.

## A game's extension

```odin
import "unified:godot"

View :: enum u8 {Player, Hud}       // scene view kinds: one scene each (found by the view index)
Multi :: enum u8 {Ball}             // MultiMesh view kinds
Frame :: godot.Frame(g.State, g.World, View, Multi)

GLUE := godot.Glue(g.State, g.Input, g.World, View, Multi) {
	sample_input = sample_input,     // main thread, every frame: Godot's input -> the local player's Input
	fill_frame   = fill_frame,       // session thread, every published tick: State -> views
	// optional
	scripted_input, scripted_commands, constants, bench, event_key, event_pos, compat, level,
	smoothing,                       // view.Smoothing in fill_frame's units (zero: the default, metres)
	is_2d,                           // event positions reach GDScript as Vector2 (else Vector3)
	max_views, max_multi, view_data_bytes, // the Frame's capacities (zero: 256, 16384, 16384)
}

sample_input :: proc(input: ^g.Input) {
	move := godot.action_vector("move_left", "move_right", "move_forward", "move_back")
	input.move_x, input.move_z = godot.axis_i8(move.x), godot.axis_i8(move.y)
	input.jump = godot.action_pressed("jump")
}

fill_frame :: proc(frame: ^Frame) {
	for player in 0 ..< g.PLAYERS do if frame.state.joined[player] {
		godot.push_view(frame, {key = view.Key(player + 1), kind = .Player, player = i8(player), pos = ...})
	}
	godot.push_view(frame, {key = HUD_KEY, kind = .Hud}, Hud_Data{balls = frame.state.balls})
	godot.push_multi(frame, {key = ball_key, kind = .Ball, pos = ...})
}

@(export, link_name = "<game>_init")
<game>_init :: proc "c" (gpa: gdi.InterfaceGetProcAddress, lib: gdi.ClassLibraryPtr, init: ^gdi.Initialization) -> gdi.Bool {
	context = runtime.default_context()
	godot.install(&g.GAME, GLUE)
	godot.set_transport(&transport)      // optional: online play (EOS...), never imported by unified:godot
	return godot.entry(gpa, lib, init)
}
```

Glue procs are named procs, never inline lambdas.

### Input

`sample_input` runs on the main thread every frame and fills the local player's `Input` itself, explicitly, through
these helpers (main thread only; they read Godot's `Input` singleton) or the bindings:

- `action_held(action) -> bool`, `action_strength(action) -> f32`,
  `action_vector(negative_x, positive_x, negative_y, positive_y) -> [2]f32` (`Input.get_vector`: y is "back");
- `action_pressed(action) -> bool`: true for every press since the session thread last took the input, so a tap
  shorter than a tick is never lost (the host latches each press per action and clears it once a tick has taken a
  sample holding it);
- `input_value(name) -> [3]f32`: the latest value a script set with `UnifiedSession.set_input_value(name, value)`
  (a Vector3, a Vector2 with z = 0, or a float or bool in x): what only GDScript knows, such as a camera's look
  direction;
- `axis_i8(x) -> i8`: −1..1 to −127..127.

While a dev UI text field has the keyboard the action helpers return nothing pressed. The host hands the newest
sample to the session thread when a tick takes the local input; `scripted_input` replaces it in `--scripted` runs.
`Input` is what the player intends: interpreting it against the state is the sim's job.

### Filling a frame

`fill_frame(frame)` runs on the session thread for every published tick. `frame.state` and `frame.world` are the
tick's; `frame.tick`, `frame.local_player` (-1 until assigned). It pushes:

- `push_view(frame, View_Item{key, kind, player, entity, pos, rot})` and `push_view(frame, item, data)`: a scene
  view. `key` is the spawn key (non-zero; a new key is a new view), `player` the player it shows (-1: none) and
  `entity` the u64 its events carry (0: none): both route events to it. `pos` and `rot` (a unit quaternion; zero
  is the identity; `view.quat_yaw`, `view.quat_angle2d`) are in the units the views use. `data` is any plain
  struct, converted like an event field (below: an enum becomes its member name, an array of structs an Array of
  Dictionaries...; `_` fields are padding): the view gets each field as its script property of the same name, on
  spawn and whenever its bytes change. One kind always pushes the same data type (asserted).
- `push_multi(frame, Multi_Item{key, kind, pos, yaw, scale, color, custom})`: one MultiMesh instance. `key`
  identifies it across ticks (a handle's `sim.handle_key`; 0: never interpolated); keys are per kind. `scale` is
  per local axis (zero: 1), `color` the instance color (zero: white), `custom` the custom data.

Both return false when the Frame is full (counted; the host warns once). The host remembers every keyed item's
pose: a view or instance seen at tick − 1 interpolates from it, so games never pass previous poses, and physics
bodies interpolate like plain state. A re-fill of the same tick (after a rollback) keeps the tick − 1 pose.

The HUD is no special case: a `.Hud` view whose scene root is a Control (or any node that is not a Node2D or
Node3D: it gets data, no pose), pushed with its data each tick.

## Godot side

**`UnifiedSession`** (Node, one per app):

- methods: `start_single()`, `host_online()`, `host_direct(port)`, `join_online(code)`, `join_direct(address)`,
  `leave()`, `send_command(command: UnifiedCommand) -> bool`, `set_input_value(name: StringName, value)`,
  `constants() -> Dictionary` (`tick_hz` plus `Glue.constants`), `set_player_name(name)`, `get_status()`,
  `is_running()`, `get_tick()`, `get_local_player()` (-1 until assigned), `get_player_name(player)` (the synced
  name, "" when unknown), `toggle_devui()`, `is_devui_visible()`;
- properties: `view_root` (where scene views are made), `seed`, `ticks`;
- signals: `status_changed(status, detail)`, `lobby_code(code)`, `desync(tick, detail)`,
  `sim_event(event: UnifiedEvent, state: int)`;
- constants `EVENT_EMITTED`, `EVENT_CONFIRMED`, `EVENT_CANCELLED` (enum `EventState`).

Scripts reach it typed (`@onready var session: UnifiedSession = %UnifiedSession`), never by string.

**`UnifiedView`** (Node): the marker a scene view's scene holds, a direct child of its root. `kind` (the `View`
member's name, lowercased: set in the scene), `entity`, `player` (set by the host); signals `despawned` (the view's
key is gone: it lingers 0.25 s, then is freed) and `revived` (a rollback brought it back while lingering). The
root can be any node: a Node3D gets position and quaternion, a Node2D position and rotation (the angle about Z),
anything else (a Control HUD) only data. The root's script may define `_sim_update(position, yaw_or_rotation,
alpha)` (every frame, after the host moved it) and `_sim_event(event: UnifiedEvent, state: int)`.

**`UnifiedMultiView`** (Node): the marker under a MultiMeshInstance3D or MultiMeshInstance2D that the host fills
with the instances of one `Multi` kind: `kind`, `smooth` (rollback corrections glide like scene views' instead of
popping; off by default). Registered when it enters the tree. The MultiMesh's `transform_format` decides the
layout (2D: position, rotation about Z, scale per axis); `use_colors` and `use_custom_data` add 4 floats each. The
host owns `instance_count` and `visible_instance_count`.

**Events and commands as classes.** At load the host registers a class per kind of the game's event union
(`extends UnifiedEvent`, a RefCounted with `tick` and `kind`, the type name lowercased: `rock_hit`) and command union
(`extends UnifiedCommand`), named `Event` or `Command` + the Odin type in PascalCase (`Rock_Hit` ->
`EventRockHit`; an event's optional `Event_` prefix and a command's `Cmd_` are dropped first: `Event_Rock_Hit` ->
`EventRockHit`, kind `rock_hit`; `Cmd_Drop` -> `CommandDrop`), with a typed property per field. The
prefix groups them: Godot classes have no namespaces (an extension class can't nest, and GDScript can't alias a
native class as a constant), and no GDScript is generated. Field types: integers `int`, f32 `float`, bools, enums a `StringName` of the member's name lowercased,
bit_sets an `Array` of those, a handle its key (`int`), a `sim.Position` a `Vector2` (`Glue.is_2d`) or `Vector3`
in view units (`Glue.event_pos`), `[2]f32` / `[3]f32` / `[4]f32` a `Vector2` / `Vector3` / `Color`; `_` fields are
left out; a `player` field holding `sim.NO_PLAYER` is -1. An event field named `tick` or `kind` (UnifiedEvent's) and a
name that clashes with an existing class stop the install with an error. GDScript:

```gdscript
func _on_sim_event(event: UnifiedEvent, state: int) -> void:
	if event is EventRockHit and state == UnifiedSession.EVENT_EMITTED:
		_spark((event as EventRockHit).at)

var drop := CommandDrop.new()
drop.count = 3
session.send_command(drop)
```

`send_command` converts the object to the command's struct (enums by member name or value, integers range-checked);
a wrong value, no running session or a full queue (64 waiting) returns false with a `print_error` naming it.
The command reaches the sim exactly once, on the next tick the client samples.

The editor's help documents every class above (class reference XML loaded at extension start).

## Events

`install` reads the game's event union by RTTI once: each kind's name, its `player` field, its subject (the first
`sim.Handle(T)` field, else a u64 field named `entity`) and its `sim.Position` fields.

- **States.** Every event is **Emitted** exactly once, the first time any simulation of its tick produces it (a
  prediction, or the verified tick itself), then exactly once either **Confirmed** (its tick is verified) or
  **Cancelled** (a re-simulation no longer produces it). One first produced when its tick is verified is Emitted and
  Confirmed in the same frame. Effects and sounds on EMITTED, what must be final (score, banners) on CONFIRMED,
  undoing an effect on CANCELLED. The tracker (`view.Event_Tracker`) tells events apart by tick, kind, subject and
  index among the tick's events of that kind and subject.
- **Where.** Each event, in each state, goes first to its subject's view (`_sim_event(event, state)` on the root's
  script): the view `Glue.event_key` names when the game sets it (0: none), else the view keyed by its handle
  (`sim.handle_key`), else the views whose `entity` is its `entity` field, else its player's views. Then to the
  `sim_event` signal.
- **Order.** A tick's events arrive in emission order; cancels and confirmations of several ticks in tick order.

## The view index

`uni bake <game>` scans the game's scenes for `UnifiedView` markers and writes `res://unified_index.tres` (a
Resource whose metadata `views` maps each kind name to its scene's path), committed next to the game. Every build
of the game's library (`uni build`, `uni run`, any command that runs the game) refreshes it the same way, so a new
or renamed view scene needs no separate step; in CI it is only checked: the godot suite's `bake` step fails when
the committed one is stale. At the first session the host checks that every `View` member has a
scene and every indexed kind is a `View` member (an error names each one).

## How it works

- **Threads.** A session (single player = a host with no remote links; host; join) runs netcode's
  `host_step` / `client_step` on its own thread (macOS: the real-time time-constraint class; while a session runs
  the process opts out of background throttling: an NSProcessInfo activity on macOS, `timeBeginPeriod(1)` and no
  power throttling on Windows). The netcode hooks run there: `sample` takes the main thread's newest Input (or
  `scripted_input`); `commands` drains the command queue; `frame` feeds the re-simulated and new ticks' events to
  the tracker and calls `fill_frame`, then publishes the Frame; `verified` confirms or cancels events; `status` and
  `desync` post. Godot is only called from the main thread.
- **The hand-off.** Lock-free where it is hot: a triple buffer of Frames (newest wins), an SPSC message queue
  (statuses, events; full: dropped, never blocking the sim), a command queue (64), and the input sample (a short
  mutex, once a frame and once a tick).
- **Main thread.** `UnifiedSession._process` runs at priority −1000, before every other node: `sample_input`, take
  the newest Frame, update the scene views (spawn by key into `view_root`, push poses of ticks P − 1 and P into each
  view's `view.Track`, sample at alpha = (now − P's due time) / tick with `Glue.smoothing`, set the pose, call
  `_sim_update`), write each MultiMesh's buffer in one `set_buffer`, route events, then the dev UI (`dev.odin`;
  `-define:UNIFIED_DEVUI=false` compiles it out, `src/devui/SPEC.md`). The screen runs one tick behind the newest
  prediction and never extrapolates.
- **Data.** A view's data is set after the view entered the tree (setters may use `@onready` nodes), on spawn and
  then only for fields whose bytes changed, before `_sim_update`; values are the newest tick's. A view whose root
  has no property for a data field is an error (reported once per kind and field).
- **Remote links.** Each goes through a `Dev_Link`: straight to the transport while the dev UI's netsim is off,
  through a `netcode.Net_Sim` while on.
- **Leave, then host or join.** `leave` asks the session to end; it says goodbye on its thread (a client's Leave is
  acked within ~0.5 s, a host waits up to 3 s). A start during the goodbye waits and starts as soon as the old
  session is gone (the goodbye cut to 1 s); a `leave` before that cancels it.
- **Editor.** Classes register at SCENE level; nothing runs in the editor. Hot reload is editor-only. `deinitialize`
  stops the session thread, then calls the transport's optional `shutdown`.

**Command-line flags** (after `--`): `--autostart` (single player at once), `--host-port N` (host directly on UDP
port N), `--join host:port`, `--host-online`, `--join-code CODE`, `--local-net` (direct hosting listens on 127.0.0.1
only), `--scripted` (scripted input and commands), `--ticks N`, `--seed N`, `--quit-at-end` (quit when the session
ends, printing its result), `--devui` (the dev UI shown at start), `--lag MS` (the dev netsim on remote links: MS
each way, a quarter of it jitter, 1% loss), `--bench N` (single player holds N entities, `Glue.bench`).

## Library tooling

`uni` mirrors `src/godot/tools/` into every game as `res://addons/unified/` (git-ignored there): `tool.gd`
(`UnifiedTool`, the base of every tool script `uni tool` runs: the `UNIFIED_RESULT` line, the strict error and
warning judgement, waits, real input events, screenshots, `--frames`) with `log_capture.gd` and `frame_log.gd`, and
`validate.gd` (the godot suite's `validate` step: every script compiles with warnings as errors, every scene loads
and instantiates, unknown `.tscn` properties, no `preload()` in the scripts the play scene loads (Godot 4.7 reports a
resource first preloaded during a worker-thread load as leaked), the main scene runs; a game adds checks in
`game/tools/validate.gd`, which extends it).

## Tests

`tests/godot_driver` runs the driver with the toy game and no Godot: frames, previous poses from the host's memory,
one press delivered once, confirmed events, the result, transport failure, the Dev_Link switch.
`tests/godot_views` (`uni test --suite godot-bindings`) runs a single-player toy session under headless Godot:
`UnifiedView` scene views in 2D and 3D and a Control one (pose, `_sim_update`, data as properties only when it
changes, a missing property's error), MultiMesh views (2D and 3D buffers, colors, custom data, rotation on the
shorter arc, scale per axis), typed event classes in every state to the views and the signal, typed commands
reaching the sim once with every field kind, the input sample and a latched press. Its `session_check.gd` checks
starting during a goodbye. Each game's `godot` suite: `validate`, `walk`, `tour`, `session` (a headless Godot
session's checksums equal the offline binary's), `editor`, `bake`.

## Open

- F3 extras: snapshot, input log, net stats.
- Real-time thread classes on Windows and Linux (to be measured).
- Running-game hot reload.
