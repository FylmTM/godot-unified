# godot

Status: draft, pending #358

`unified:godot` is everything that touches Godot for a game built on `unified`; `unified:gdext` (its own SPEC.md) is
the raw bindings underneath. Each game has a thin extension (`games/<game>/simulation/extension`) that installs its sim
and its glue. The editor's help is the reference for every class and member below: each is documented where it is
bound.

## A game's extension

```odin
import "unified:godot"

View :: enum u8 {Player}            // scene view kinds: one scene each (found by the view index)
MultiView :: enum u8 {Ball}         // MultiMesh view kinds
Data :: union {Data_Hud}            // session data types: Unified.data.hud
Frame :: godot.Frame(g.Game, View, MultiView)

GLUE := godot.Glue(g.Game, View, MultiView) {
	sample_input = sample_input,     // main thread, every frame: Godot's input -> the local player's Input
	fill_frame   = fill_frame,       // session thread, every published tick: State -> views and session data
	// optional
	data = Data, input_values = Input_Values, event_key,
	is_2d,                           // the sim's XY plane is Godot 2D: a sim.Position is a Vector2 (else Vector3)
	view_scale,                      // view units per sim unit (zero: 1), e.g. 32 px per metre (View space)
}

@(export, link_name = "<game>_init")
<game>_init :: proc "c" (gpa: godot.Get_Proc_Address, lib: godot.Class_Library, init: ^godot.Initialization) -> godot.Init_Result {
	// optional: the lobby (EOS online play) and the constants
	return godot.init(&g.GAME, GLUE, gpa, lib, init, eos.lobby({}), constants = constants)
}

constants :: proc() -> Data_Constants {return {speed = g.SPEED, ...}} // Unified.constants: init calls it once
```

Glue procs are named procs, never inline lambdas. `godot.init` is a `proc "c"` that sets the Odin context itself,
so the entry point is one call; the constants are a proc it calls once the context is set (they may format strings
or compute shapes), its value copied. A game's extension fills frames; its Godot calls go in GDScript or through
`unified:godot` helpers, so it never imports `unified:gdext` (`godot` names the entry point's types). The level the
session plays is the game's (`sim.Game.content`, embedded in the extension).

**Online play** goes through the `netcode.Lobby` the game passes to `godot.init` (`unified:godot` never imports a
platform SDK). The session opens it with a `Lobby_Build` (the game's name, the build id `sim.compat_of(game)`, its
level included, the project's stamped version, the player count), so a joiner on another build is told
before it joins. `godot.init` is `install` (the game, its Glue and its constants; tests call it alone), the lobby and
`entry` (the extension's callbacks for Godot), in their one valid order.

**`install` never stops the load.** The editor loads the extension too, so a problem is reported, not a panic:
`install` collects every one (no `sample_input` or `fill_frame`, a View / MultiView enum that doesn't count up from
0, `sim.game_violation`, a Glue struct type that isn't plain, a field of one of Godot's own types) and registers
nothing of the game. They are printed when the extension loads, and starting a session fails with the first one.

### Input

`sample_input` runs on the main thread **once a frame** and fills the local player's `Input` through these helpers
(they read Godot's `Input` singleton). Every tick that samples the local player takes the newest sample, so one
sample can feed several ticks: an `Input` is the controls' **state**, never a one-shot (`sim.buttons` derives presses
from the tick before; a one-shot value is a command).

- `buttons(Buttons, [Button]string) -> Buttons`: the Input's `buttons` bit_set, each button from its action through
  `action_down`; `action_down(action)`: held now, or tapped since a tick last took the input (latched);
  `action_strength(action)`, `action_vector(negative_x, positive_x, negative_y, positive_y)` (y is "back"): analog.
- `input_values(Input_Values) -> ^Input_Values`: what only scripts know (a camera's look direction). `Glue.input_values`
  names a plain struct; scripts set its fields on `Unified.input` (class `UnifiedInput`, typed like data, below), and
  `sample_input` reads the latest values. The session samples at process priority −1000: a value set in a node's
  `_process` at a later priority (the default 0) reaches the next frame's sample; set it from a node below −1000 or
  from `_input`.
- An axis is `dmath.axis_i8(x)`; a direction a `dmath.Dir2` / `Dir3`. An `Input` holds no bools and no floats.

**Game input is off** while a dev UI text field has the keyboard and while `UnifiedSession.game_input` is false (a
pause menu): the action helpers read nothing and latched taps drop; `Unified.input` still flows. When it comes back,
and when the window gets the focus back, an action still held counts only once released. An unfocused window still
reads input. A press on the dev UI never reaches the actions (`src/devui/SPEC.md`, Input). The game's scripted player
(`sim.Game.scripted_input`) replaces the sample in `--scripted` runs.

### View space

The sim works in its own units and never converts; the views draw in Godot's (metres in 3D, pixels in 2D). The Glue
says how they relate: `is_2d` (the sim's XY plane is Godot 2D, x right, y down) and `view_scale` (view units per sim
unit; 1 when unset). Everything up to the hand-off is in sim units (fill_frame, the event queue; the views'
smoothing suits a sim in metres). The host
maps a point once, on the main thread, where it makes a Godot value from it: a scene view's position, a MultiMesh
instance's origin (only the origin: a mesh is drawn in view units), and every `sim.Position` a script reads; the
inverse for one a script sets in a command. Rotations, directions, lengths and input values are not mapped; a script
scales a sim size with `Unified.view_scale`. View space is `view_root`'s local space (the host warns once when
`view_root` is not at the world origin).

### Filling a frame

`fill_frame(f)` runs on the session thread for every published tick, with `f.state`, `f.world`, `f.tick` and
`f.local_player` (the `sim.Player` this client plays then; `{}` before its join tick). It pushes:

- `push_view(f, View_Item{key, kind, player, pos, rot})` and `push_view(f, item, data)`: a scene view, identified by
  its **kind and key** (a `u64`, unique within its kind; a new key is a new view). A player's view keyed by
  `sim.player_key` survives a slot change and a rejoin (key 0 with `player` set means that key), a table thing's by
  `sim.handle_key`, a fixed thing's by its index (its events carry `sim.entity(index)`). The key and `player` route
  events to it (Events, below). `pos` is a `sim.Position` in sim units (2D: x, y). `rot` is a
  unit quaternion (zero: identity; `dmath.quat_yaw` from a facing, `godot.quat_angle2d`). `data` is a plain struct set as the view's
  properties of the same names, converted like any sim-facing field (Data and classes, below), on spawn and whenever
  its bytes change; one kind always pushes one data type.
- `push_multi_view(f, Multi_View_Item{key, kind, pos, rot, scale, color, custom})`: one MultiMesh instance. `key`
  (per kind; 0: never interpolated) identifies it across ticks; `rot` interpolates on the shorter arc; `scale` per
  axis (zero: 1), `color` (zero: white), `custom` the shader's custom data.
- `push_data(f, Data_Hud{...})`: the session data value of one type of `Glue.data` this tick (one per type, asserted).

A Frame grows to what a fill pushes (on the session thread, which owns the slot it fills; a fill past the hard
limits is a runaway loop and panics). The host remembers every keyed item's pose,
so a view or instance seen at tick − 1 interpolates from it and games never pass previous poses. After a rollback the
remembered tick − 1 pose is the old prediction, so the host sends an estimate of the corrected one: a re-filled tick
moves its tick − 1 by the same correction; a rollback with a new tick, or a fill after skipped ticks, takes the new
pose minus the last known one-tick motion. A view's history lacking tick − 1 starts from its last shown pose: a
correction glides over `tau`, it never pops.

### Data and classes

**Session data** (values that belong to no entity: a HUD's score, the wave) are the types of `Glue.data`, a union of
plain `Data_*` structs, each pushed with `push_data`. **Constants** (what `godot.init`'s `constants` proc returns, a
plain `Data_*` struct, strings allowed) are copied at install. **Input values** (`Glue.input_values`) are set by scripts.

The host registers a class per such type at load, plus one per **nested struct** any of them or the event and command
unions hold (`Hud_Player` -> `DataHudPlayer`, a RefCounted value: each read is a new one, its fields settable, so a
command can take it). The engine singleton **`Unified`** holds them: `Unified.data.<name>` (`Data_Hud` -> `.hud`, a
`DataHud` with a `changed` signal), `Unified.constants` (`UnifiedConstants`), `Unified.input` (`UnifiedInput`),
`Unified.session`, `Unified.tick_hz`, `Unified.view_scale`. Session data is set from the newest predicted tick when
its bytes change (no interpolation), after the views and before the frame's events, and goes back to zero (one
`changed`) when a session ends; the objects live on, so connections survive. They are freed at Godot's shutdown
callback, while scripting still runs.

Every sim-facing field (events, commands, view and session data, constants, input values) converts by type, the
same everywhere: integers `int`, f32 `float`, bools; an enum an `int` (its class names the members: `survivor.Phase`
is `EnumPhase.LOBBY`, `EnumPhase.name(value)`); a bit_set an `Array[int]`; a handle and a `sim.Player` their key (an
`int`, 0: none); a `sim.Position` a `Vector2` (`is_2d`) or `Vector3` in view units; by shape `[2]/[3]/[4]f32` a
`Vector2/3/4` and `[2]/[3]/[4]i32` a `Vector2i/3i/4i`; `godot.Color` a `Color`, `godot.Quat` a `Quaternion`; other
arrays and enumerated arrays a typed `Array` (an array of arrays untyped); a nested struct an object of its class (a
struct only view data uses has no class: a `Dictionary`); a string (constants) a `String`. `_` fields are left out.
Godot's own math types are refused at install: data maps by shape, so a game never imports `unified:gdext`.

**Events and commands** are classes too: one per kind of the event union (`extends UnifiedEvent`, a RefCounted with
`tick`, `kind` (a name for logs) and `id`) and of the command union (`extends UnifiedCommand`), named `Event` /
`Command` + the type in PascalCase without its prefix (`Event_Rock_Hit` -> `EventRockHit`, `Cmd_Drop` ->
`CommandDrop`), with a typed property per field. The library's `sim.Event_Player_Joined` / `Event_Player_Left` are
`EventPlayerJoined` (`player`, `slot`, `returning`) and `EventPlayerLeft`. Godot classes have no namespaces, so the
prefixes group them; a name that clashes with an existing class is an error and is not registered.

```gdscript
func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if event is EventRockHit and state == UnifiedSession.EVENT_EMITTED:
		var hit := event as EventRockHit
		_spark(hit.position)

var drop := CommandDrop.new()
drop.count = 3
session.send_command(drop)
```

Handlers dispatch by class, never by `kind`. `send_command` converts the object to the command's struct (a value it
cannot hold, no session or a full queue: false and an error naming it); the sim gets it exactly once.

## Godot side

**`UnifiedSession`** (Node, one per app; scripts reach it typed, `%UnifiedSession` or `Unified.session`): starts,
hosts, joins and leaves sessions; `status` (enum `Status`) and `status_changed`; the shown tick's `tick`,
`local_player`, `get_players()`, `get_player_slot(player)` and the roster's names; `get_view(kind, key)`,
`get_player_view(kind, player)`, `get_views(kind)` from the host's own tables; `sim_event`; `view_root`, `seed`,
`ticks`, `local_name`, `game_input`, `devui_visible`. Players are ints: a player's key, the same while they are in the
session whatever slot they hold (0: nobody). Nothing about the session answers once it is over. A client's LAN token
is kept in `user://unified_token_<n>`: each running copy of the game claims its own by an OS file lock held for the
process's life, so a restarted one takes its token back.

**`UnifiedView`** (Node): the marker a scene view's scene holds as a direct child of its root, `kind` set in the
scene; the host sets its `key` and keeps its `player` (the key of the player it shows; 0: none) current. The root can be any node: a Node3D gets position and quaternion, a Node2D position and rotation, anything else
only data, all before any other node's `_process` (the session runs at priority −1000), so a view's own `_process`
sees the frame's pose. Its script may define `_sim_event(event, state)`, `_sim_despawned()` (its key is gone: it
lingers `linger_s`, no longer posed, then is freed), `_sim_revived()` (a rollback brought it back while it lingered)
and `_sim_cancelled()` (a rollback removed it before its spawn tick was verified: freed at once). A `view_root` that
leaves the tree holds no views, so a play scene needs no teardown.

**`UnifiedMultiView`** (Node): the marker under a MultiMeshInstance3D / 2D the host fills with one `MultiView` kind
(`smooth`: rollback corrections glide). The MultiMesh's `transform_format`, `use_colors` and `use_custom_data` decide
the layout. The host owns `instance_count`, `visible_instance_count` and, unless the game set one before the first
frame, `custom_aabb` (the instances' origins grown by the mesh's reach: without it `set_buffer` transforms the mesh's
AABB by every instance).

## Events

`install` reads the game's event union by RTTI once: each kind's player (its first `sim.Player` field) and subject (its
first `sim.Handle(T)` or `sim.Entity` field), found by type, whatever the fields are named.

- **States.** Every event is **Emitted** exactly once, the first time any simulation of its tick produces it, then
  exactly once either **Confirmed** (its tick is verified) or **Cancelled** (a re-simulation no longer produces it).
  One first produced at verification is Emitted and Confirmed in the same frame. Effects on EMITTED, what must be
  final on CONFIRMED, undoing an effect on CANCELLED. Two events are the same across re-simulations when tick, kind,
  subject and index among the tick's events of that kind and subject match.
- **Identity.** Each state arrives as a new object; its `id` is the same in an event's EMITTED and its CONFIRMED or
  CANCELLED, and never repeats in the process. A re-simulation may change an event's fields but not its id. Events
  still pending when a session ends get no final state.
- **Where.** Each event, in each state, goes first to its subject's views: those keyed by its handle's key or its
  `Entity`'s index (of any kind), else (none has that key, or it has no such field) its player's views; then to the
  `sim_event` signal. `Glue.event_key(event, subject)` gets the event as the game's union and the `Subject{player,
  handle, entity}` the host read, and reroutes a game's special events: `.View` (the view of the kind and key it
  returns), `.No_View`, or `.Subject` (the zero value: a bare `return`).
- **When.** An event is delivered once the Frame of its tick is shown, so an event about a view spawned at its tick
  finds the view. A tick's events arrive in emission order; cancels and confirmations of several ticks in tick order.

## The view index

`uni bake <game>` scans the game's scenes for `UnifiedView` markers and writes `res://unified_index.tres` (each kind
name to its scene's path), committed next to the game; every build of the game's library refreshes it, and the godot
suite's `bake` step fails when the committed one is stale. Games keep their scenes wherever they like. At the first
session the host checks that every `View` member has a scene and every indexed kind is a member.

## How it works

- **Threads.** A session (single player = a host with no remote links) runs netcode's `host_step` / `client_step` on
  its own thread (macOS: the real-time time-constraint class; while a session runs the process opts out of background
  throttling). The netcode hooks run there: `sample` takes the main thread's newest Input; `frame` feeds the
  re-simulated and new ticks' events to the tracker, calls `fill_frame` and publishes the Frame; `verified` confirms
  or cancels events. Godot is only called from the main thread.
- **The hand-off.** Lock-free where it is hot: a triple buffer of Frames (newest wins); an SPSC event queue (full: the
  event is dropped, never blocking the sim, counted and warned once); a small queue of its own for what must never be
  lost (statuses, the lobby code, desync reports, the result); a command queue; the input sample under a short mutex.
- **Main thread.** `UnifiedSession._process` runs before every other node: `sample_input`, take the newest Frame,
  spawn and pose the scene views (ticks P − 1 and P pushed into each view's track, sampled at alpha = (now − P's due
  time) / tick, × `view_scale`), write each MultiMesh's buffer and bounds in one `set_buffer`, set the session data,
  route the events of the ticks the Frame shows, then statuses, then the dev UI. The screen runs one tick behind the
  newest prediction and never extrapolates; an input reaches the screen after the next tick sample, the input delay,
  and one tick of interpolation.
- **View logic** (`handoff.odin`, `track.odin`, `view_set.odin`, `event_tracker.odin`: no Godot calls, tested without
  Godot). Each view keeps the poses of its last 4 ticks; a rollback that re-publishes a tick with a different pose
  puts the difference into an error offset that decays as `exp(-dt / tau)`; a correction or move longer than
  `teleport_dist` snaps. A key missing from a frame lingers (an exit animation, or a rollback that brings it back: it
  is revived, not respawned). Re-simulations of ticks at or below the verified one are ignored, since they are final.
- **Data.** A view's data is set after the view entered the tree (setters may use `@onready` nodes), then only for
  fields whose bytes changed; a root without a property for a field is an error (once per kind and field).
- **Remote links** go through a live netsim (`netcode.netsim_live`) the dev UI's Conditions panel impairs.
- **The dev UI** (`dev.odin`, the only file that reaches `unified:devui`; `-define:UNIFIED_DEVUI=false` compiles it
  out). It graphs the frame, the sim and the net, and shows the Inspector, Input, Events, Commands and Conditions
  panels (`src/devui/SPEC.md`). Dev UI builds also record the session as it is verified (a portable snapshot of the
  first saved verified tick, then every verified tick's inputs), so an F3 note carries `snapshot.unis`, `inputs.unil`
  and `note.json`, which `uni headless <game> -- replay` replays to the noted checksum.
- **Leave, then host or join.** `leave` asks the session to end; it says goodbye on its thread (a client's within
  ~0.5 s, a host's up to 3 s). A start during the goodbye waits and starts as soon as the old session is gone (the
  goodbye cut to 1 s); a `leave` before that cancels it.
- **Editor.** Classes register at SCENE level; nothing runs in the editor; the class reference loads at EDITOR level.
  `deinitialize` stops the session thread, calls the lobby's optional `shutdown`, then `gd.shutdown` unregisters
  every class.

**Command-line flags** (after `--`): `--autostart`, `--host-port N`, `--join host:port`, `--host-online`,
`--join-code CODE`, `--local-net`, `--quit-at-end`, and the dev flags `--scripted`, `--ticks N`, `--seed N`,
`--devui`, `--lag MS`, `--bench N` (`Args` says what each does). The game and its tool scripts read their own flags
from the same command line, so other flags pass through; a bad value of one of these, or a near miss of a name
(`--tiks`), prints an error and quits (exit 2). A build without the dev UI ignores the dev flags with a warning.

## Library tooling

`uni` mirrors `src/godot/tools/` into every game as `res://addons/unified/` (git-ignored there): `level_export.gd`
(`uni bake`'s level exporter), `tool.gd` (`UnifiedTool`, the base of every script `uni tool` runs: the result line,
the strict error judgement, waits, input events, screenshots, `--frames`) and `validate.gd` (the godot suite's
`validate` step: every script compiles with warnings as errors, every scene loads, the main scene runs; a game adds
checks in `game/tools/validate.gd`).
