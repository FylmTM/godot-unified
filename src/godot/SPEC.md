# godot

Status: signed off 2026-11-15 (#9: contract v1, with its follow-ups #273-#287); 2026-11-16 the game API (#234, #240, #242).

`unified:godot` is everything that touches Godot for a game built on `unified`; `unified:gdext` (its own SPEC.md) is
the raw bindings underneath. Each game has a thin extension (`games/<game>/simulation/extension`) that installs its sim and its glue.

## A game's extension

```odin
import "unified:godot"

View :: enum u8 {Player}            // scene view kinds: one scene each (found by the view index)
MultiView :: enum u8 {Ball}         // MultiMesh view kinds
Data :: union {Data_Hud}            // session data types: Unified.data.hud
Frame :: godot.Frame(g.State, g.World, View, MultiView)

CONSTANTS := Data_Constants{speed = g.SPEED, ...} // Unified.constants: a package variable, copied at install

GLUE := godot.Glue(g.State, g.Input, g.World, g.Cmd, View, MultiView) {
	sample_input = sample_input,     // main thread, every frame: Godot's input -> the local player's Input
	fill_frame   = fill_frame,       // session thread, every published tick: State -> views and session data
	// optional
	data = Data, constants = CONSTANTS,
	scripted_input, scripted_commands, bench, event_key, compat, level,
	is_2d,                           // the sim's XY plane is Godot 2D: a sim.Position is a Vector2 (else Vector3)
	view_scale,                      // view units per sim unit (zero: 1), e.g. 32 px per metre (View space, below)
	smoothing,                       // view.Smoothing in sim units (zero: the default, for metres)
	max_views, max_multi, view_data_bytes, // the Frame's capacities (zero: 256, 16384, 16384)
}

sample_input :: proc(input: ^g.Input) {
	move := godot.action_vector("move_left", "move_right", "move_forward", "move_back")
	input.move_x, input.move_z = godot.axis_i8(move.x), godot.axis_i8(move.y)
	input.buttons = godot.buttons(g.Buttons, {.Jump = "jump", .Grab = "grab"})
}

fill_frame :: proc(f: ^Frame) {
	players := sim.iterate_present(&f.state.players)
	for data, player in sim.next(&players) {
		godot.push_view(f, {key = view.Key(sim.player_key(player)), kind = .Player, player = player, pos = ...})
	}
	godot.push_multi_view(f, {key = sim.handle_key(ball), kind = .Ball, pos = ..., rot = ...})
	godot.push_data(f, Data_Hud{balls = u32(f.state.balls.count)})
}

@(export, link_name = "<game>_init")
<game>_init :: proc "c" (gpa: gdi.InterfaceGetProcAddress, lib: gdi.ClassLibraryPtr, init: ^gdi.Initialization) -> gdi.Bool {
	context = runtime.default_context()
	godot.install(&g.GAME, GLUE)
	godot.set_transport(godot_eos.transport("<game>"))  // optional: EOS online play (src/godot_eos/SPEC.md)
	return godot.entry(gpa, lib, init)
}
```

Glue procs are named procs, never inline lambdas. A game's extension fills frames; its Godot calls go in GDScript or
through `unified:godot` helpers (the input helpers below), so it needs no Godot bindings of its own (`unified:gdext`
binds what the library uses: src/gdext/SPEC.md).

**Transports.** Online play goes through a `godot.Transport` the game sets (`glue.odin`): `open_host(user, compat,
events)` and `open_join(user, code, compat, events)` return the link and get the session's build id (`compat`: the
glue's, else `sim.compat_of(game, level)`), so a transport that lists games can publish it and tell a joiner on
another build before it joins; `pump`, `close`, and the optional `account`, `main_frame` and `shutdown`.
`unified:godot` never imports a transport: EOS is `unified:godot_eos`, one line in the game's init.

**`install` never stops the load.** The editor loads the extension too, so a problem is reported, not a panic:
`install` collects every one (no `sample_input` or `fill_frame`, a View / MultiView enum that doesn't count up from
0, the sim's game checks (`sim.game_violation`: tick rate, unions, the library's events, an event field named `tick`,
`kind` or `id`), the State's players field, plain State and Input, a data type that isn't a plain, padding-free
struct) and registers nothing of the game. They are printed with `print_error` when the
extension loads (the editor opens and shows why), and starting a session fails with the first one as its status.

### Input

`sample_input` runs on the main thread **once a frame** and fills the local player's `Input` itself, explicitly,
through these helpers (main thread only; they read Godot's `Input` singleton) or the bindings. The host keeps the
newest sample, and every tick that samples the local player takes it: frames and ticks don't line up, so one sample
can feed several ticks (a 64 Hz tick on a 60 Hz screen, a catch-up). So an `Input` is the controls' **state**, never
a one-shot: a button is down or up (`sim.buttons` derives presses and releases from the tick before, so a repeated
input never presses twice), and a one-shot value is a command.

- `buttons(Buttons, [Button]string) -> Buttons`: the Input's `buttons` bit_set, each button from its action through
  `action_down` (`input.buttons = godot.buttons(Buttons, {.Jump = "jump", .Grab = "grab"})`);
- `action_down(action) -> bool`: held now, or tapped since a tick last took the input (the host latches each tap
  until a tick takes a sample holding it), so a tap shorter than a frame still reaches the sim;
- `action_strength(action) -> f32`, `action_vector(negative_x, positive_x, negative_y, positive_y) -> [2]f32`
  (`Input.get_vector`: y is "back"): analog input;
- `input_value(name) -> [3]f32`: the latest value a script set with `UnifiedSession.set_input_value(name, value)`
  (a Vector3, a Vector2 with z = 0, or a float or bool in x): what only GDScript knows, such as a camera's look
  direction;
- `axis_i8(x) -> i8`: −1..1 to −127..127 (`dmath.axis_i8`); a stick decodes with `dmath.stick` (clamped to length
  1), a direction is a `dmath.Dir2` / `Dir3` (`dmath.dir2(vec)`, 2 or 4 bytes; zero: none). An `Input` holds no bools
  and no floats (`sim.wire_violation`).

**Game input is off** while a dev UI text field has the keyboard and while `UnifiedSession.game_input` is false (a
pause menu, a chat field: the shared pause menu turns it off while open): the action helpers read nothing and latched
taps drop, `input_value` still flows. When it comes back, and when the window gets the focus back, an action still
held counts only once it is released (the key that closed the menu, the click that focused the window never fire).
An unfocused window still reads input: Godot releases what was held when it lost the focus, and tool runs drive
windows that never take it. A press on the
dev UI never reaches the actions (it releases the actions it triggered: `src/devui/SPEC.md`, Input).
`scripted_input` replaces the sample in `--scripted` runs. `Input` is what the player intends: interpreting it
against the state is the sim's job.

### View space

The sim works in its own units (metres in every game so far) and never converts. The views draw in Godot's: metres
in 3D, pixels in 2D. The game says how the two relate once, in its Glue: `is_2d` (the sim's XY plane is Godot 2D, x
right, y down) and `view_scale` (view units per sim unit; drift: 32 px per metre; 1 when unset). Everything up to the
hand-off is in sim units: what `fill_frame` pushes, the host's smoothing and rollback estimates (`Glue.smoothing` in
sim units: the default suits metres), the event queue. The host maps a point once, on the main thread, where it
makes a Godot value from it: a scene view's position (and `_sim_update`'s), a MultiMesh instance's origin (only the
origin: a mesh is the view's content, drawn in view units, and `Multi_View_Item.scale` a multiplier), and every
`sim.Position` a script reads (events, view data, session data, constants); and the inverse for a `sim.Position` a
script sets in a command (the object keeps what was set: it reads back as set). Nothing else is mapped: rotations,
directions, lengths and input values stay as they are; a script scales a sim size (a radius from the constants) with
`Unified.view_scale`. View space is `view_root`'s local space; the host warns once when `view_root` is not at the
world origin (a script placing an effect at an event's position elsewhere, or sending the mouse's world position,
would be off by its transform). A 2D level is baked at the same scale (`src/level/SPEC.md`).

### Filling a frame

`fill_frame(f)` runs on the session thread for every published tick. `f.state` and `f.world` are the tick's;
`f.tick`, `f.local_player` (the `sim.Player` this client plays at that tick; `{}` before its join tick) and
`f.local_slot` (the slot the relay gave it; -1 before). It pushes:

- `push_view(f, View_Item{key, kind, player, entity, pos, rot})` and `push_view(f, item, data)`: a scene view. A
  view is identified by its **kind and key**: a key is unique within its kind only (0 is fine; the same key in
  another kind is another view), and a new key is a new view: a player's view keyed by `sim.player_key` survives a
  slot change and a rejoin, a table thing's by `sim.handle_key`, a fixed thing's by its index. `player` is the
  `sim.Player` it shows (`{}`: none) and `entity` the u64 its events carry (0: the key): both route events to it.
  `pos` and `rot` (a unit quaternion; zero is the identity; `view.quat_yaw`, `view.quat_angle2d`) are in the units
  the views use. `data` is any plain struct, converted like an event field (below: an enum is an int, an array of
  structs an Array of Dictionaries...; `_` fields are padding), and a field of Godot's own math types (`gd.Color`,
  `gd.Vector4`, `gd.Quaternion`, ...) as itself: the view gets each field as its script property of the same name,
  on spawn and whenever its bytes change. One kind always pushes the same data type (asserted).
- `push_multi_view(f, Multi_View_Item{key, kind, pos, rot, scale, color, custom})`: one MultiMesh instance. `key`
  identifies it across ticks (a handle's `sim.handle_key`; 0: never interpolated); keys are per kind. `rot` is a
  unit quaternion like a view's (zero: identity), interpolated with nlerp on the shorter arc; `scale` is per local
  axis (zero: 1), `color` the instance color (zero: white), `custom` the custom data.
- `push_data(f, Data_Hud{...})`: the session data value of one type of `Glue.data` this tick (below). One value per
  type per frame (asserted), from anywhere in `fill_frame`.

Each returns false when the Frame is full (counted; the host warns once). The host remembers every keyed item's
pose: a view or instance seen at tick − 1 interpolates from it, so games never pass previous poses, and physics
bodies interpolate like plain state. After a rollback the remembered tick − 1 pose is the old prediction, so the
host sends an estimate of the corrected one (#284, measured under `--lag`): a re-filled tick moves its tick − 1 by
the same correction; a rollback with a new tick, or a fill after skipped ticks, takes the new pose minus the last
known one-tick motion. The views feed it into their error term (`view.track_push_prev`), and when a view's history
lacks tick − 1 (the main thread skipped a frame, or the sim several ticks) its last shown pose starts it: a
correction glides over `tau`, it never pops.

### Session data and constants

Values that belong to no entity, no key and no scene (a HUD's score, the wave, a timer) are **session data**: the
game lists their types in `Glue.data` (a union of plain, padding-free structs named `Data_*`) and `fill_frame` pushes
each with `push_data`. The host registers a class per type at load (`Data_Hud` -> `DataHud`, extends Object) with a
typed property per field and a `changed` signal, keeps one live instance per type, sets its values from the newest
predicted tick's bytes (no interpolation) when they change and emits `changed`, after the views and before the
frame's events (a handler reads the current values). When a session ends they go back to zero and `changed` fires
once; the objects live on, so connections survive. Nested structs and arrays inside stay Dictionaries and Arrays.

**Constants** are the game's fixed values for its scripts: `Glue.constants` holds a package variable of a plain
`Data_*` struct (strings allowed: constants never cross threads; not a literal, which an `any` can't keep), copied at
install and converted once at load into the class `UnifiedConstants` through the same mechanism (registered with no
properties when the game has none).

**`Unified`** is an engine singleton (class and singleton, like Godot's `Input`), registered at load in the game and
the editor: `Unified.data` (a `UnifiedData`, with a typed property per data type named from it: `Data_Hud` ->
`Unified.data.hud: DataHud`), `Unified.constants` (`UnifiedConstants`), `Unified.session` (the active
`UnifiedSession`, null when none) and `Unified.tick_hz`. Typed in GDScript with editor completion, nothing looked up
by string:

```gdscript
func _ready() -> void:
	Unified.data.hud.changed.connect(_redraw)

func _redraw() -> void:
	balls_label.text = "Balls: %d" % Unified.data.hud.balls
	phase_label.text = EnumPhase.name(Unified.data.hud.phase)
```

Its objects are freed at Godot's shutdown callback, while scripting still runs, so a lambda connected to `changed`
never outlives GDScript.

## Godot side

Godot hosts the game through GDExtension (a LibGodot host would run the same init unchanged; a later option). An
entity kind is drawn by scene views (`UnifiedView`) up to a few hundred at once, or by a multi view
(`UnifiedMultiView`, one MultiMesh) above that. View logic is GDScript by default; Odin, in the game's extension,
for what is performance-critical or shared across games.

**`UnifiedSession`** (Node, one per app):

- `game_input` (bool, default true): off, the action helpers read nothing (Input, above);
- methods: `start_single()`, `host_online()`, `host_direct(port)`, `join_online(code)`, `join_direct(address)`,
  `leave()`, `send_command(command: UnifiedCommand) -> bool`, `set_input_value(name: StringName, value)`,
  `set_player_name(name)`, `get_status()`,
  `is_running()`, `get_tick()`, `toggle_devui()`, `is_devui_visible()`, `take_sync_stats()` (the main thread's
  view-sync cost since the last call, as a Dictionary: frames, events, and microseconds summed for the scene views,
  the MultiMesh build and upload, the event delivery and the whole sync; `uni view-bench` reads it);
- players, by handle: a player reaches GDScript as its key (`sim.player_key`, an int; 0 is nobody), the same while
  they are in the session, whatever slot they hold. At the shown tick: `get_players()` (the present ones, slot
  order), `get_known_players()` (every one the state remembers, present or not), `get_local_player()` (0 until this
  client's join tick), `get_player_slot(player)` (-1 when absent), `is_player_present(player)`. From the relay's
  roster, still answering after the player left: `get_player_name(player)`, `get_player_platform(player)` and
  `get_player_platform_id(player)` (the account the transport vouched for: "eos" and the product user id; empty on
  LAN, in single player and in replays; a LAN token is never shown). A client's LAN token is kept in
  `user://unified_token_<n>` (each running copy of the game on a machine claims its own; a restarted one takes its
  token back);
- properties: `view_root` (where scene views are made, as its children: a node picked in the inspector or set from
  a script; until it is set, the session's parent; null: no scene views), `seed`, `ticks`;
- signals: `status_changed(status, detail)`, `lobby_code(code)`, `desync(tick, detail)`,
  `sim_event(event: UnifiedEvent, state: int)`, `roster_changed()` (a name, a connection or an account changed);
- constants `EVENT_EMITTED`, `EVENT_CONFIRMED`, `EVENT_CANCELLED` (enum `EventState`).

Scripts reach it typed (`@onready var session: UnifiedSession = %UnifiedSession`), never by string.

**`UnifiedView`** (Node): the marker a scene view's scene holds, a direct child of its root. `kind` (the `View`
member's name, lowercased: set in the scene), `linger_s` (how long the view stays once its key is gone, default
0.25 s: set in the scene), `entity` and `player` (the player's key, 0: none), which the host keeps current. The
root can be any node: a Node3D gets position and quaternion, a Node2D position and rotation (the angle about Z),
anything else only data. The root's script may define:

- `_sim_update(position, yaw_or_rotation, alpha)`: every frame, after the host moved it;
- `_sim_event(event: UnifiedEvent, state: int)`: its events (Events, below);
- `_sim_despawned()`: its key is gone. It lingers `linger_s`, then is freed; while it lingers the host no longer sets
  its pose, so an exit animation may move it;
- `_sim_revived()`: a rollback brought it back while it lingered (posed again);
- `_sim_cancelled()`: a rollback removed it before its spawn tick was ever verified (it existed only in a wrong
  prediction): freed at once, no linger, never despawned.

**`UnifiedMultiView`** (Node): the marker under a MultiMeshInstance3D or MultiMeshInstance2D that the host fills
with the instances of one `MultiView` kind: `kind`, `smooth` (rollback corrections glide like scene views' instead of
popping; off by default). Registered when it enters the tree. The MultiMesh's `transform_format` decides the
layout (2D: position, rotation about Z, scale per axis); `use_colors` and `use_custom_data` add 4 floats each. The
host owns `instance_count`, `visible_instance_count` and, unless the game set one before the first frame,
`custom_aabb`: each frame the instances' origins grown by the mesh's reach times the largest scale (without it,
`set_buffer` makes Godot transform the mesh's AABB by every instance, most of the upload's cost).

**Events, commands and enums as classes.** At load the host registers a class per kind of the game's event union
(`extends UnifiedEvent`, a RefCounted with `tick`, `kind` and `id`, the type name lowercased: `rock_hit`) and command union
(`extends UnifiedCommand`), named `Event` or `Command` + the Odin type in PascalCase without its prefix
(`Event_Rock_Hit` -> `EventRockHit`, kind `rock_hit`; `Cmd_Drop` -> `CommandDrop`; an event type without `Event_`
is named the same way), with a typed property per field. The
prefix groups them: Godot classes have no namespaces (an extension class can't nest, and GDScript can't alias a
native class as a constant), and no GDScript is generated. Field types (events, commands, view and session data,
constants): integers `int`, f32 `float`, bools, enums an `int` (below), bit_sets an `Array[int]`, a handle its key
(`int`), a `sim.Player` its key (`int`, 0: nobody; a command's from one), a `sim.Position` a `Vector2`
(`Glue.is_2d`) or `Vector3` in view units (`Glue.view_scale`), `[2]f32` / `[3]f32` / `[4]f32` a `Vector2` / `Vector3` /
`Color`, Godot's own math types as themselves, other arrays and enumerated arrays a typed `Array` (`Array[int]`,
`Array[Vector2]`, `Array[Dictionary]` for structs; an array of arrays stays untyped), a nested struct a
`Dictionary`, a string (constants) a `String`; `_` fields are left out. The library's `sim.Event_Player_Joined` and
`Event_Player_Left`, in every game's union, are `EventPlayerJoined` (`player`, `slot`, `returning`) and
`EventPlayerLeft` (`player`, `slot`). A name that clashes with an existing class is an error, and that class is not
registered. Each enum type the event, command, session data and constants types use (nested ones too) is a class of
integer constants named like them: `survivor.Phase` is `EnumPhase.LOBBY`, `.MATCH`, `.OVER` (members uppercased), plus
`EnumPhase.name(value)`, the member's name lowercased, for display. An enum only scene-view data uses still reaches
its view as an int, with no class. GDScript:

```gdscript
func _on_sim_event(event: UnifiedEvent, state: int) -> void:
	if event is EventRockHit and state == UnifiedSession.EVENT_EMITTED:
		_spark((event as EventRockHit).at)

var drop := CommandDrop.new()
drop.count = 3
session.send_command(drop)
```

`send_command` converts the object to the command's struct (enums by value, integers range-checked; a handle set as
its key, 0: none; a `sim.Position` set in view units, divided by `Glue.view_scale`; a nested struct set as a
Dictionary of its fields by name, a field left out keeping its value; a property reads back as it was set); a wrong
value, no running session or a full queue (64 waiting) returns false with a `print_error` naming it.
The command reaches the sim exactly once, on the next tick the client samples.

The editor's help documents every class above (class reference XML loaded at extension start).

## Events

`install` reads the game's event union by RTTI once: each kind's name, its player (the first `sim.Player` field),
its subject (the first `sim.Handle(T)` field, else a u64 field named `entity`) and its `sim.Position` fields.

- **States.** Every event is **Emitted** exactly once, the first time any simulation of its tick produces it (a
  prediction, or the verified tick itself), then exactly once either **Confirmed** (its tick is verified) or
  **Cancelled** (a re-simulation no longer produces it). One first produced when its tick is verified is Emitted and
  Confirmed in the same frame. Effects and sounds on EMITTED, what must be final (score, banners) on CONFIRMED,
  undoing an effect on CANCELLED. The tracker (`view.Event_Tracker`) tells events apart by tick, kind, subject and
  index among the tick's events of that kind and subject.
- **Identity.** Each state arrives as a new object; its `id` (an int) is the same in an event's EMITTED and in its
  CONFIRMED or CANCELLED, and never repeats in the process (an event cancelled and produced again later is a new
  one, a new id). A re-simulation may change an event's fields but not its id: CONFIRMED carries the final ones. A
  game undoes on CANCELLED only what is worth undoing (drift: a mispredicted shot's flash and sound), keyed by id:

  ```gdscript
  var _shots: Dictionary[int, int] = {}  # a shot's event id -> its sound

  func _sim_event(event: UnifiedEvent, state: int) -> void:
  	if event is EventFired:
  		match state:
  			UnifiedSession.EVENT_EMITTED: _shots[event.id] = Sfx.play(&"fire")
  			UnifiedSession.EVENT_CANCELLED: if _shots.has(event.id): Sfx.stop(_shots[event.id])
  			UnifiedSession.EVENT_CONFIRMED: pass
  		if state != UnifiedSession.EVENT_EMITTED: _shots.erase(event.id)
  ```

  Events still pending when a session ends get no final state (scripts drop what they keep per session); after
  dropped events (the queue full, below) a script may see a final state for an id it never saw, or miss one.
- **Where.** Each event, in each state, goes first to its subject's views (`_sim_event(event, state)` on the root's
  script): the views keyed by its handle (`sim.handle_key`, of any kind), else the views whose `entity` is its
  `entity` field (a view's entity defaults to its key), else its player's views (those whose `player` is its
  player). Then to the `sim_event` signal. A game routes its special events itself with `Glue.event_key`, which
  returns a kind, a key and a `godot.Event_Route`: `.View` (the view of that kind and key), `.No_View` (none) or
  `.Subject` (the zero value, so a bare `return`: the routing by subject above).
- **When.** An event is delivered once the Frame of its tick is shown: the session thread queues a tick's events
  before it publishes that tick's Frame, and the main thread delivers only those up to the shown Frame's tick, the
  newer ones waiting for the next frame (so an event about a view spawned at its tick finds the view).
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
- **The hand-off.** Lock-free where it is hot: a triple buffer of Frames (newest wins), an SPSC event queue (4096;
  full: the event is dropped, never blocking the sim, and counted: the dev UI's `views` line shows it and the host
  warns once), a small SPSC queue of its own for what must never be lost (statuses, the lobby code, desync reports,
  the result), a command queue (64), and the input sample (a short mutex, once a frame and once a tick). Dev UI
  builds add the Input panel's view (a triple buffer, while the dev UI is shown), the commands verified ticks
  carried (an SPSC queue, 256; full: dropped) and the recording (below, a mutex per verified tick).
- **Main thread.** `UnifiedSession._process` runs at priority −1000, before every other node: `sample_input`, take
  the newest Frame, update the scene views (spawn by key into `view_root`, push poses of ticks P − 1 and P into each
  view's `view.Track`, sample at alpha = (now − P's due time) / tick with `Glue.smoothing`, set the pose (× `view_scale`), call
  `_sim_update`), write each MultiMesh's buffer (every instance interpolated at alpha) and bounds in one
  `set_custom_aabb` and one `set_buffer`, set the session data, route the events of the
  ticks the Frame shows, then statuses and the result, then the dev UI (`dev.odin`;
  `-define:UNIFIED_DEVUI=false` compiles it out, `src/devui/SPEC.md`). The screen runs one tick behind the newest
  prediction and never extrapolates.
- **Data.** A view's data is set after the view entered the tree (setters may use `@onready` nodes), on spawn and
  then only for fields whose bytes changed, before `_sim_update`; values are the newest tick's. A view whose root
  has no property for a data field is an error (reported once per kind and field).
- **Remote links.** Each goes through a `Dev_Link`: straight to the transport while the dev UI's netsim is off,
  through a `netcode.Net_Sim` while on.
- **The dev UI** (`dev.odin`, the only file that reaches `unified:devui`). Graph groups: `frame` (frame time; the
  main thread split views / dev ui / game / render), `sim` (sim thread ms by step kind, ticks ahead, the marks
  rollback, late input, stall, desync; the `ticks/s` line: `new` (each tick's first step: the tick rate while the
  session keeps pace), `re-run` (rollbacks) and, on a joiner, `catch-up` (new ticks stepped late, every input known:
  it fell behind; a host or single player steps most ticks that way, so it isn't shown there)), `net` (round trip,
  bandwidth, relay silence). Panels: the Inspector (the newest predicted State, `constants`, each session data type
  as `data.<name>`, all read-only), Input (the local player's input in the newest predicted tick; the newest
  verified tick's inputs by slot: player, present, replaced), Events (every event in each state), Commands (sent
  from `send_command`, confirmed when a verified tick carries it, refused when the queue is full), Conditions (its
  network part greyed in single player: there are no remote links to impair). A session start restarts the
  frames line.
- **Recording** (dev UI builds). The session thread records the session as it is verified: a portable snapshot of
  the first verified tick whose state the ring saved (a host's tick 1, a joiner's first after its join), then every
  verified tick's inputs as an input log (`UNIL`, from the snapshot's tick on), in memory, and the newest checksum
  the client computed past the snapshot. An F3 note gets it (`on_feedback`): `snapshot.unis`, `inputs.unil` and
  `note.json` (game, version, bug, the session's status, local player, shown and verified tick, the recording's
  ticks, a tick with the session's checksum of it, the net stats) next to the screenshot and `note.txt`.
  `uni headless <game> -- replay --snapshot snapshot.unis --log inputs.unil --trace F` replays it; the trace's line
  for the checked tick must hold that checksum. A build without the dev UI records nothing.
- **Leave, then host or join.** `leave` asks the session to end; it says goodbye on its thread (a client's Leave is
  acked within ~0.5 s, a host waits up to 3 s). A start during the goodbye waits and starts as soon as the old
  session is gone (the goodbye cut to 1 s); a `leave` before that cancels it.
- **Editor.** Classes register at SCENE level (the `Unified` singleton too); nothing runs in the editor. Hot reload
  is editor-only. Godot's shutdown callback frees the `Unified` objects; `deinitialize` stops the session thread,
  then calls the transport's optional `shutdown`.

**Command-line flags** (after `--`): `--autostart` (single player at once), `--host-port N` (host directly on UDP
port N), `--join host:port`, `--host-online`, `--join-code CODE`, `--local-net` (direct hosting listens on 127.0.0.1
only), `--scripted` (scripted input and commands), `--ticks N`, `--seed N`, `--quit-at-end` (quit when the session
ends, printing its result), `--devui` (the dev UI shown at start), `--lag MS` (the dev netsim on remote links: MS
each way, a quarter of it jitter, 1% loss), `--bench N` (single player holds N entities, `Glue.bench`). The game and
its tool scripts read their own flags from the same command line, so other flags pass through; a missing or bad value
of one of these, or a near miss of one of their names (`--tiks`), prints an error and quits (exit 2), like `uni`.
`--scripted`, `--ticks`, `--seed`, `--devui`, `--lag` and `--bench` are dev flags: a build without the dev UI (`uni
release --no-devui`) ignores them with a warning (`godot.parse_command_line`, tested in `tests/godot_driver`).

## Replay sessions (specified; built after the foundations review, #124)

Signed off in the #10 sitting (D9). Built in this order: F3 notes that replay (done), the op log, the replay session.

- **Recordings.** While the dev UI is in the build every session is recorded as above and written when it ends to
  `<user data>/recordings/<local time>/` (`snapshot.unis`, `inputs.unil`, `session.json`), the last 10 kept. One
  mechanism for every session kind: a host's recording starts at its tick 1, a joiner's at its join. An online
  session is never paused or rewound live: it is recorded, then replayed.
- **A replay session.** `UnifiedSession.replay(folder)` (a recording or an F3 note) starts a session that feeds the
  sim from the file instead of the network: no input, no commands, every tick final, so events arrive emitted and
  confirmed together. Views, events and session data work as live. Controls: pause and play, step one tick forward
  or back, speed (¼× to 4×), loop a tick range. A step back within the sim's ring restores; further back re-runs
  from the file's snapshot. It shows the verified timeline: what a client predicted at the time is not in a
  recording (the live dev UI's rollback marks and event states show that).
- **The dev UI.** A Timeline panel while a replay session runs (the tick, play/pause, step, speed, loop range); the
  op log: what the shown tick changed, a field-by-field diff of the State against the tick before (by RTTI, as
  `sim.snapshot_diff` reads two blocks), as an Inspector root `changes` (`rocks[3].pos: (1, 2) -> (1, 3)`).

## Library tooling

`uni` mirrors `src/godot/tools/` into every game as `res://addons/unified/` (git-ignored there): `tool.gd`
(`UnifiedTool`, the base of every tool script `uni tool` runs: the `UNIFIED_RESULT` line, the strict error and
warning judgement, waits, real input events, screenshots, `--frames`) with `log_capture.gd` and `frame_log.gd`, and
`validate.gd` (the godot suite's `validate` step: every script compiles with warnings as errors, every scene loads
and instantiates, unknown `.tscn` properties, no `preload()` in the scripts the play scene loads (Godot 4.7 reports a
resource first preloaded during a worker-thread load as leaked), the main scene runs; a game adds checks in
`game/tools/validate.gd`, which extends it).

## Tests

`tests/godot_driver` runs the driver with the toy game and no Godot: frames (the local player, the slots and the
remembered players by key, the roster), previous poses from the host's memory and their estimates after a rollback
or skipped ticks, the input sample, confirmed events, a tick's events held until its Frame is shown (a
`fill_frame` held to force the race), the result, the commands verified ticks carried, the session's recording
replaying offline to the session's own checksum, transport failure, a game with problems installing nothing, the
Dev_Link switch. `tests/godot` (the bindings suite) also checks that a press on a dev UI button leaves the action it
is bound to released, and a press elsewhere doesn't.
`tests/godot_views` (`uni test --suite godot-bindings`) runs a single-player toy session under headless Godot:
`UnifiedView` scene views in 2D and 3D (pose, `_sim_update`, data as properties only when it changes, a missing
property's error, the same key in two kinds, entity defaulting to the key, `_sim_despawned` once and no pose while it
lingers), MultiMesh views (2D and 3D buffers, colors, custom data, a full rotation on the shorter arc, scale per
axis, bounds holding every instance, a game's own `custom_aabb` kept), session data on `Unified` (typed, `changed`, back to zero when the session ends), constants (strings, nested
structs, enumerated arrays), an enum class, typed event classes in every state to the views and the signal, one `id` per event across its states, `event_key` routing (a named view, none, by subject)
(`EventPlayerJoined` with the local player's key), the session's players by key (slot, presence, name, no
platform, `roster_changed`), typed commands reaching the sim once with every field kind (a handle, a position in sim units, a nested struct),
the input sample, a latched tap spawning once, game input off and a held action swallowed when it comes back. Its `session_check.gd` checks
starting during a goodbye. Each game's `godot` suite: `validate`, `walk`, `tour`, `session` (a headless Godot
session's checksums equal the offline binary's), `editor`, `bake`.

## Open

- Replay sessions, recordings on disk and the op log (above, #124).
- Real-time thread classes on Windows and Linux (to be measured).
- Running-game hot reload.
