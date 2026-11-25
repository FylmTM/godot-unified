# `unified:godot`: the Godot host of a game built on `unified`

Everything that touches Godot for a game: the session node that runs the game's sim on its own thread (single
player, hosting or joining, through `unified:netcode`), the views that show its state, its events and commands as
GDScript classes, input sampling, the command line and the dev UI (`unified:devui`, reached only from `dev.odin`).
`unified:gdext` is the raw bindings underneath. Each game has a thin extension (`examples/<game>/simulation/extension`)
that installs its sim and its glue with `godot.init`; its scenes and scripts use the classes below. The editor's help
is the reference for every GDScript-facing class and member: each is documented where it is bound.

## A game's extension

The extension fills frames and samples input; its Godot calls go in GDScript or through `unified:godot` helpers, so it
never imports `unified:gdext` (`godot` names the entry point's types). The levels the session plays are the game's
(`sim.Game.levels`, embedded in the extension).

**Online play** goes through the `netcode.Lobby` the game passes to `godot.init`: `unified:godot` never imports a
platform SDK. The session opens the lobby with a `netcode.Lobby_Build` (the game's name, its build id
`sim.compat_of(game)`, level included, the project's stamped version, the player count), so a joiner on another
build is told before it joins.

**The editor loads the extension too**, so a game with problems is reported, never a panic that stops the load
(`install_problems` says what it checks).

### Input

`Glue.sample_input` runs on the main thread **once a frame**, and every tick that samples the local player takes the
newest sample, so one sample can feed several ticks: an `Input` is the controls' **state**, never a one-shot. The sim
derives presses from the tick before (`sim.buttons`); a one-shot value is a command. An `Input` holds no bools and
no floats: an axis is `dmath.axis_i8(x)`, a direction a `dmath.Dir2` / `Dir3`, a first-person look a `dmath.Aim`. A
game without an Input (`sim.No_Input`) has no `sample_input`: everything its players do is a command. An Input's
`sim.Seen` is the host's: the session thread stamps `netcode.client_seen` into each input it makes from a sample
(src/sim/README.md, Input).

**Local players.** `sample_input(local, input)` runs once a frame for each local player (several people on one
machine: a couch, guests of a remote-play stream, who arrive as pads), and the action helpers read **the sampled
player's device**, so one body serves them all: every device through Godot's Input singleton (the first player's
default, and how a game of one player plays), the keyboard and mouse, or one joypad. Godot's Input singleton keeps no
action state per device, so for a device the session follows the events of the actions the helpers asked for (a
joypad's events for the players on that pad, the keyboard's and mouse's for the players on it). A press latches for
the next sample, so a tap within one frame still reaches the sim; what the window or a pad loses without a release
(the focus gone, the pad unplugged) is released. Each local player is its own member of the session
(`src/netcode/README.md`, Local players), with its own commands and input values; a command sent for a local index
nobody plays, or queued by a player who left, is never sent as another's.

**Setup and Profile** (`src/sim/README.md`, Setup and Profile) are GDScript classes built from the game's types, as a
command's: a host's start takes a Setup (a joiner plays the host's), and the Profile is what a local player joins
with. A save (`src/sim/README.md`, Saves) comes as a Setup with the frame that shows it, to every player, so any of
them can host the continuation, also on a later build.

**Open to friends.** A running single-player session becomes a hosted one: the session thread opens the lobby or the
socket and adds it to the running host (`src/netcode/README.md`, Relay: open and closed). Closing lets nobody new in
while the players in stay. A lobby that fails after opening closes again and the session plays on as single player:
only a session hosted from the start ends with its lobby.

**Input values** are what only scripts know (a camera rig's look direction): the plain struct `Glue.input_values`
names, whose fields scripts set on `Unified.input` (local player 0's; another's `Unified.local_input(local)`) and
`sample_input` reads (`input_values`). The session samples before any other node's `_process` (Godot side), and emits
`UnifiedSession.input_wanted` just before: a script sets its values there, whatever its node's priority, and this
frame's sample takes them. Set in `_process`, they reach the next frame's sample.

**A pause menu pauses single player**: `UnifiedSession.paused` stops the session thread's host (netcode's single-player
pause), the views hold their last pose, and the session goes on as if no time had passed. Asked in the frame a session
was started, it holds from that session's first tick: the session thread takes its first step only once that frame
is over (`Start.hold`). With other players it reads false and the menu is an overlay: a game that pauses together
sends a command (`src/sim/README.md`, Game time). The SceneTree's own pause never stops the session: its node pumps
it whatever the tree's state.

**Game input is off** while a dev UI text field has the keyboard and while `UnifiedSession.game_input` is false (a
pause menu): the action helpers read nothing and latched taps drop; `Unified.input` still flows. When it comes back,
and when the window gets the focus back, a button still held counts only once released (the key that closed a menu,
the click that focused the window never fire), while a held direction reads at once (a stick held through a menu
keeps moving). An unfocused window still reads input: Godot releases what was held
when it lost the focus, and tool runs drive windows that never take it. A press on the dev UI never reaches the
actions (`src/devui/README.md`, How it works). The game's scripted player (`sim.Game.scripted_input`) replaces the
sample in `--scripted` runs, and its players join as the offline binary's scripted players do, so the session computes
what that run does: a host's local player k asks for slot k (refused when it is taken: nothing silently diverges) and
joins with that slot's `sim.Game.scripted_profile`, a joiner started with `--slot n` asks for slot n with slot n's
(without it, the relay picks the slot and the player joins with `Unified.profile`). `--profile`'s assignments go over
a scripted Profile too, and a Profile a script passes to `add_local_player` is kept as given.

### View space

The sim works in its own units and never converts; the views draw in Godot's (metres in 3D, pixels in 2D).
`Glue.is_2d` and `Glue.view_scale` say how they relate. Everything up to the hand-off is in sim units: `fill_frame`,
the event queue, the views' smoothing (whose defaults suit a sim in metres). The host maps a point once, on the main
thread, where it makes a Godot value from it: a scene view's position, a MultiMesh instance's origin (only the
origin: a mesh is drawn in view units), every `sim.Position` a script reads; and the inverse for one a script sets in
a command. Rotations, directions, lengths and input values are not mapped: a script scales a sim size with
`Unified.view_scale`. View space is `view_root`'s local space (the host warns once when `view_root` is not at the
world origin).

### Filling a frame

`fill_frame` runs on the session thread for every published tick and pushes what the main thread shows: scene views
(`push_view`, each standing for a **subject**: its identity, its key and what events reach it), MultiMesh instances
(`push_multi_view`) and session data (`push_data`). A Frame grows to what a fill pushes.

The host remembers every keyed item's pose, so a view or instance seen at tick − 1 interpolates from it and games
never pass previous poses. After a rollback the remembered pose is the old prediction, so the host sends an estimate
of the corrected one (`poses.odin`); a correction glides over the smoothing's `tau_s`, it never pops.

The host never guesses a teleport the sim can name: each thing has a **warp epoch** that moves on where it
teleports, pushed with the view (`View_Item.warp`): a body's is physics' (`physics.body_warp`, moved on by every
physics teleport), a thing that is no one body keeps a `u8` in its state and bumps it. A change snaps the view: no
interpolation and no correction crosses it. It is compared with the epoch the main thread last **showed**, not the
last fill's, because the hand-off drops frames the main thread never took. It is rollback-safe by construction: a
re-simulated teleport bumps the counter to the same value, an undone one puts the old value back and the view snaps
back. A long move with no bump still snaps past the smoothing's `teleport_dist`, the fallback.

**View kinds.** A scene view kind is a struct, the data its views carry, and the game's scene views are a union of
them (`View :: union {View_Card, View_Enemy}`; a kind with no data is an empty struct), as events, commands and session
data are: the type is the kind. `push_view` takes the data and so names the kind, and a value of a type the union
lacks does not compile; nothing pairs a kind with its data at run time. The kind's name is its type's without `View_`,
lowercased (`card`: its scenes' marker, the view index, `EnumView.CARD`). A MultiMesh kind carries no data, so the
MultiMesh kinds stay an enum. How a kind is shown is its **policy** (`Glue.view_policy`, by its type, only for a kind
that isn't the default; `multi_policy`): Odin literals, not properties spread over the kinds' scenes: a kind's
smoothing (a bullet, a heavy crate and a remote player want different ones) and, for a scene view, who poses its root.
How it looks stays in its scene: the marker's linger time, the node its views spawn under and whether they are pooled.
A script-posed kind's root is left alone and its script gets the pose the host would have set (`Posed_By.Script`), so
it can draw what the local player holds at render rate from the camera. A MultiMesh kind keeps a track per instance
only when its policy sets a smoothing: thousands of instances cost nothing per instance by default.

**Appear on verified** (`Appear.Verified`): a kind whose views must never show a mispredicted spawn. The session
thread knows since which tick each key is in the current timeline: the first fill that showed it, reset when a
rollback re-simulates that tick, and confirmed by a fill of the newest verified tick (netcode's `verified_state`)
that has it. Without that verified fill a key would never appear under steady mispredictions, since every predicted
fill gets re-simulated before it is verified; it costs one more `fill_frame` per step that re-stepped verified ticks,
only while some kind asks for it, in which every push of another kind (and every `push_data`) returns at once. The main thread creates the view once the newest verified tick reaches that tick;
such a view is never cancelled.

**Remote players on the verified timeline** (`Remote.Verified`, `verified_players.odin`): a kind whose views of other
players must never snap back, at the price of showing them late. Only that: a view of such a kind that shows a player
who isn't local plays final ticks; the local players' views, data-only views, the things a remote player carries and
MultiMesh instances stay on the prediction (a game wanting a carried thing late too gives it a kind of its own that shows the
player). Such a view's data and events follow its pose: an event reaches it when playback reaches the event's tick,
CONFIRMED only, never ahead of the body it belongs to, while the session's `sim_event` signal still has it on the
prediction. A view whose player becomes local, or stops being, snaps between the timelines. Predicted is the default:
a remote player in a co-op game is usually predicted well enough, and late is worse than corrected where players
interact closely.

**What a player sees is the game's choice, not a secret** (`src/sim/README.md`, Hidden information): every client
holds the whole state, and `fill_frame` decides what is shown. A card in an ally's hand pushed face down
(`godot.is_local` says whose a player is) is hidden from the honest client only.

### Data and classes

**Session data** (values that belong to no entity: a HUD's score, the wave) are the `Data_*` structs of `Glue.data`,
one value of each per tick. **Constants** (what `godot.init`'s `constants` proc returns, strings allowed) are copied
once at install. **Input values** are set by scripts. Session data is set from the newest predicted tick when its
bytes change (no interpolation), after the views and before the frame's events, and goes back to zero (one
`changed`) when a session ends; the objects live on, so connections survive. They are freed at Godot's shutdown
callback, while scripting still runs.

**Session data and input values are plain**, as the State is: no pointers and **no implicit padding** (a gap, even
the tail after a `bool`, is an explicit `_pad: [n]u8` field), because the host compares their bytes. `install`
refuses a type that isn't, naming the `_pad` to add; `godot.install_problems` reports the same without Godot, and a
game's own `the_extension_installs` test (the template's) calls it, so `uni test` catches it.

The host registers a class per such type at load, one per **view kind** (`View_Card` -> `ViewCard`), plus one per
**nested struct** any of them, the event and command unions, the Setup or the Profile hold (`Hud_Player` ->
`DataHudPlayer`, a RefCounted value whose fields are settable, so a command can take it), and a
class per enum they use. The view kinds are plain like session data (the host compares their bytes too). The engine
singleton `Unified` holds the data, the constants, the input values and the session. Godot classes have no namespaces,
so prefixes group them (`Data`, `View`, `Event`, `Command`, `Enum`); a name that clashes with an existing class is an
error and is not registered. What GDScript can't take is an install problem naming the field: a generic struct
(`Ring($T=u8, $N=4)`, which no class can be named after; sim's List, Queue and Bits are Arrays), and a class's field
named `true`, `false` or `null` (read as the literal; every other keyword reads as the attribute).

Every sim-facing field (events, commands, view and session data, constants, input values) converts by type, the same
everywhere:

- integers an `int`, f32 a `float`, bools a `bool`; an enum an `int` (its class names the members: `survivor.Phase`
  is `EnumPhase.LOBBY`, `EnumPhase.name(value)`); a bit_set an `Array[int]`;
- a handle and a `sim.Player` their key (an `int`, 0: none); a `sim.Entity` its index (an `int`, −1: none), the
  number its views are keyed by;
- a `sim.Position` a `Vector2` (`Glue.is_2d`) or `Vector3`, in view units; by shape, `[2]/[3]/[4]f32` a
  `Vector2/3/4` and `[2]/[3]/[4]i32` a `Vector2i/3i/4i`; `godot.Color` a `Color`, `godot.Quat` a `Quaternion`;
- other arrays and enumerated arrays a typed `Array` (an array of arrays untyped); a nested struct an object of its
  class (an anonymous struct, which has none, a `Dictionary`); a string (constants) a `String`;
- a `sim.List` or `sim.Queue` a typed `Array` of its live items (a Queue's oldest first), a `sim.Bits` an
  `Array[int]` of the indices it holds; a settable one (a Setup, a Profile, input values, a nested value, a command)
  takes such an Array back, refused past its capacity.

`_` fields are left out. Godot's own math types are refused at install: data maps by shape, so a game never imports
`unified:gdext`.

**Nested values** (a field that reads as an object of a nested struct's class, an `Array` or a `Dictionary`, in any of
those classes: session data, view data, events, commands, constants...) are the same value on every read while the
field's bytes don't change, so a HUD that reads `Unified.data` on every `changed` makes nothing for what didn't
change. A value a script holds never changes under it, and one whose field a script sets is that script's own (the next
read gives another), so a script can still change a value it read and put it into a command. Such an `Array` (or
`Dictionary`) is read-only, also in an Array or an object it holds: changing one in place never reached the sim
anyway; `duplicate()` gives one to change, and a settable field still takes a whole new one.

**Events and commands** are classes too: one per kind of the event union (`extends UnifiedEvent`) and of the command
union (`extends UnifiedCommand`), named `Event` / `Command` + the type in PascalCase without its prefix
(`Event_Rock_Hit` -> `EventRockHit`, `Command_Drop` -> `CommandDrop`), with a typed property per field. The library's
`sim.Event_Player_Joined` / `Event_Player_Left` are `EventPlayerJoined` and `EventPlayerLeft`. Handlers dispatch by
class, never by `kind`. A script makes a command with its class and sends it with `UnifiedSession.send_command`; the
sim gets it exactly once.

## Godot side

**`UnifiedSession`** is one node per app. **Whoever starts a session, the game follows it**: a session starts from a
script (`start_single`, `host_online`, ...), from the session flags on the command line when the node enters the
tree, or from a tool script. A game's app layer reacts to `status_changed` and `mode`, not to its own buttons, so
`uni coop` and the flags work in every game. Nothing about the session answers once it is over. A client's LAN token
is kept under `user://`, one per running copy of the game (`token_claim`), so a restarted copy takes its token back.

The game's view kinds, its `MultiView` enum and the State's level enum are enum classes like the rest, with fixed
names whatever the game named them (`EnumView`...). A scene view's scene holds a **`UnifiedView`** marker as a direct child of its root, its kind set in the scene by name
(the inspector's list; a name stays right when the union is reordered). Its root script declares `var data: ViewCard`
when the kind carries data: the host sets a new object before the view's `_ready`, so `_ready` reads it, and again
each time the data's bytes change, so a setter sees the old value and the new one and a view reacts to what changed
(a setter that uses `@onready` nodes waits for `is_node_ready()`). The data has a property of its own, so a field
never collides with the root's (a Control's `size`, a Node's `owner`). The root's class decides how it is posed: a
Node3D gets position and rotation, a Node2D position and angle, and any other root (a `Control`: a card in a hand, a
panel) only its data, never a pose. Its events, `_sim_despawned` and its linger are a posed view's. A kind's views
spawn under `view_root`, or under the node its marker's `parent_path` names from there (a hand's `HBoxContainer`,
which lays its cards out): the views are added at the end, so their order is the game's (a card's script moves
itself with `move_child` when its data changes), and a posed kind there is posed in that parent's space. A view
whose parent was freed under it spawns again on the next frame, under that parent if it is back, else under
`view_root` (an error, once).

**Pooled views.** A kind spawned and gone often (projectiles, pickups, enemies drawn as scenes) keeps its views
instead of freeing them when its marker sets `pool`. The pool is the host's, inside the view lifecycle, so linger,
revive, cancel and appear-on-verified behave as for any view: a view goes into its kind's pool only where it would
have been freed (its linger ended, or its spawn was cancelled), hidden and out of the tree, and the kind's next spawn
takes it back instead of instancing the scene. The host sets what it owns as for a new view: key, player, pose (no
glide from the old one) and data, which it set to null when the view went in, so the setter sees null and then the new
item's, as a new view's does; events reach it under its new key only. `_ready` does not run again: the host calls
`_sim_reused()`, where the script resets whatever it changed itself (an exit animation's transform or modulate, a
hidden child, a tween, a counter), and a pooled kind's data setter takes null. A pool keeps at most the most views of
its kind ever out at once, with no cap and nothing made ahead, and goes with the scene views (a level change, another
`view_root`, the session node leaving the tree). The switch is the scene's, not the kind's Odin policy, because the
scene's script is what must handle a reuse; and it is off by default, because a view with state of its own that is
reused without resetting it shows the old item's.

A MultiMeshInstance3D / 2D holding a **`UnifiedMultiView`** marker shows one MultiView kind. Views and their data are
set before any other node's `_process` (the session runs at priority −1000), so a view's own `_process` sees the
frame's pose. Its buffers are written again only when the frame or the interpolation moved (not while paused). A `view_root` that leaves the tree holds no views, so a play scene needs no teardown. Unset, it is
the session's parent: right for a session placed in the play scene (the template's); a session an autoload owns sets
`view_root = null` (no scene views) until its play scene hands over its root.

## Levels

The active level is state (`src/sim/README.md`, Levels), so the host reads it rather than being told: `install`
finds the State's `level` field (a `sim.Active_Level`, named so: `src/sim/README.md`, Levels), and each Frame
carries the level of its tick and of the newest verified tick. The level on screen (`UnifiedSession.level`) follows
the **verified** one, so a mispredicted change never shows and a rollback across a change costs the view nothing:

- **The scene.** With `level_root` set, the host loads the verified level's scene on a thread (the `res://` path its
  `.level` file names, so no index or naming convention is needed), emitting `level_changing`; once it is loaded it
  frees the old level's instance and every scene view, instances the new one under `level_root` and emits
  `level_changed`. Without `level_root` the game shows its level itself (a single-level game's play scene instances
  it), and `level` and the signals still follow the verified level.
- **The views hold.** Views sync only from frames of the level on screen: while a change is predicted but not
  verified, or the new scene still loads, the views keep their last pose and session data and events flow on. A
  view keyed by a level's marker (`sim.Entity`) is never shown against another level's scene: a marker index names
  a marker of the level active at its tick, and every scene view is dropped at the swap.
- **The sim keeps ticking** through a load. A game that wants players to wait for everyone's scene keeps that as
  state (a ready command and a timeout); the host has no barrier.

## Events

`install` reads the game's event union by RTTI once: each kind's player (its first `sim.Player` field) and subject
(its first `sim.Handle(T)` or `sim.Entity` field), found by type, whatever the fields are named.

- **States.** Every event is **Emitted** exactly once, the first time any simulation of its tick produces it, then
  exactly once either **Confirmed** (its tick is verified) or **Cancelled** (a re-simulation no longer produces it).
  One first produced at verification is Emitted and Confirmed in the same frame. Effects go on EMITTED, what must be
  final on CONFIRMED, undoing an effect on CANCELLED. Two events are the same across re-simulations when tick, kind,
  subject and index among the tick's events of that kind and subject match.
- **Identity.** Each state arrives as a new object to any script that keeps one; its `id` is the same in an event's
  EMITTED and its CONFIRMED or CANCELLED, and never repeats in the process. A re-simulation may change an event's
  fields but not its id. Events still pending when a session ends get no final state.
- **Objects only for listeners.** An event's object is made only when a view whose script has `_sim_event` or a
  connection to `sim_event` gets it; an event nobody listens to still reaches the dev UI and the control port, and
  costs no object. The host keeps the object it delivered last of each class and refills it for the next event of
  that class while no script holds it, so a heard event allocates nothing either. A script that keeps an event (in a
  member or an array; a `WeakRef` doesn't keep it) keeps it as it was; one that remembers only its instance id may
  see that id again: an event is told by its `id`. Its nested fields are nested values (Data and classes): kept on
  the reused object, the same while their bytes don't change.
- **Where.** Each event, in each state, goes first to its subject's views: those pushed with a subject of its subject
  field's type and the same key (a `Handle(T)` reaches only views pushed with a `Handle(T)` of that table; an
  `Entity` the views pushed with that `Entity`, of any kind: the kinds that take Entity events share one index space,
  a level's marker index); else (no such view, or no such field) its player's views; then to the `sim_event`
  signal. `Glue.event_key` reroutes a game's special events.
- **When.** An event is delivered once the Frame of its tick is shown, so an event about a view spawned at its tick
  finds the view. A tick's events arrive in emission order; cancels and confirmations of several ticks in tick order.

## Replays

A replay is a session kind (`UnifiedSession.replay(folder)`, `--replay`), so a game follows it like any other: the
game's own views, HUD and dev UI show a recording, an F3 note or a freeze folder, with pause, step, speed, seek and
loop. It feeds the sim from the recording instead of the network: no input, no commands, every tick final, so events
arrive Emitted and Confirmed together, and the recording's checkpoints are checked as it passes them (a recording of
another build plays and says where it first computes differently). `local_player` is the player it follows,
whoever recorded it at first, so a camera that tracks the local player's view follows them. It shows the verified
timeline: what a client predicted is not in a recording.

Every live session of a dev UI build is written to `<user data>/recordings/<local time>/` when it ends, also when the
app quits or the session node leaves the tree first (then up to its last verified tick; the newest `RECORDINGS_KEPT`
kept). A step back inside the sim's ring is a restore; further back, or forward past what was
played, the replay loads the nearest portable snapshot it kept of a tick it passed and steps to the target without
showing the ticks between, a slice of `REPLAY_SEEK_BUDGET` at a time, so a long seek never looks like a frozen
session thread and a leave ends it at once. Such a jump starts a new epoch in the Frame: every view snaps, events
still queued from before it are dropped (never shown, they never will be), and the events of ticks entered again
going forward arrive again. A note starts some seconds before its tick (the one shown when F3 opened, no later than
the recording reaches) and pauses on it.

The dev UI's Timeline panel drives a replay, and the Inspector's `changes` root is the op log: what the shown tick
changed in the State against the tick before, a line per leaf field (`sim.state_changes`), computed on the main
thread from the two states the session thread copies while the Inspector shows (live, after a rollback, the
corrected tick before).

## The control socket

An agent plays and checks a running game the way a person does, from outside the process: `uni drive` starts the
game with `--control <file>`, and the game (`control.odin`) listens on 127.0.0.1 at a port the OS picks, written to
that file, so several games, and several copies of one game, run side by side. Each connection carries one request
and its reply, a JSON line each; `uni drive -h` lists the verbs.

- **Only where asked.** The socket exists in dev UI builds only (a `--no-devui` build has none) and opens only with
  the flag. It listens on loopback with no authentication: anything on the machine may drive a game that was started
  for it, which is the point.
- **A driven session is a session.** Nothing here writes state. Input goes through Godot's Input singleton, which the
  game's `sample_input` reads as it reads a player's keys; input values a driver holds are written over what scripts
  set, after `input_wanted` and before the sample, so a rig that sets its look every frame can't undo them (and its
  camera still shows its own look); and a command goes through the session's queue as a
  script's `send_command`, so a driven session is recorded, replays, and plays online like any other. An input still
  reaches the sim after the session's input delay.
- **Exact steps.** A paused single-player session steps exactly the ticks asked (netcode's `host_advance`), each
  sampling the input held then. A press held for some ticks while paused asks for its steps one frame later, once
  the main thread's sample holds the press. A running session moves on its own clock between requests: ticks there
  are counted on the shown Frame.
- **The main thread.** The socket is polled at the end of the session's `_process`, after this frame's views and
  events, so a reply sees what the frame shows; a request that waits (a pause, a step, a timed press, a wait, a
  screenshot of the next drawn frame, a click's three frames of mouse events) keeps its connection until it is
  answered or times out. While the socket is open the session thread copies the newest state for every Frame (as
  for the Inspector), so a state query never waits for one.
- **What it reads.** State, session data and constants as JSON by RTTI (`sim.value_json`: a table by its live items,
  a player by its key, sim units); the event states the session delivered, kept in a ring with a serial per state;
  the visible controls with a text or a press, the dev UI's left out; a GDScript expression (Godot's `Expression`) on
  the current scene for anything else.

## The view index

Every build of the game's library scans the game's scenes for `UnifiedView` markers and builds the index (each kind
name to its scene's path) into the library, as a define (`views.odin`'s `VIEW_INDEX`): a view scene added, moved or
renamed rebuilds it, and no file holds the index. A scene's path is all an export needs: it ships every resource.
`uni bake --check` and the godot suite's `bake` step check the markers (a direct child of the root, a kind, each kind
in one scene). Games keep their scenes wherever they like (a level scene
outside `game/levels/` by its committed `.level`: `src/level/README.md`, Baking). At the first session the host checks
that every view kind has a scene and every indexed kind is one of them.

## How it works

- **Threads.** A session (single player is a host with no remote links) runs netcode's `host_step` / `client_step`
  on its own thread, of a raised class where the platform has one, the process opted out of background throttling
  while it runs (the platform files). The netcode hooks run
  there: `sample` takes the main thread's newest Input; `frame` feeds the re-simulated and new ticks' events to the
  tracker, calls `fill_frame` and publishes the Frame; `verified` confirms or cancels events. Godot is only called
  from the main thread. The thread counts how late each of its sleeps wakes (`wake.odin`; `take_sync_stats`), and
  `uni bench`'s wake row measures the same sleeps on the session thread's class with every core idle and busy: what a
  platform's thread class is chosen from.
- **The hand-off.** Lock-free where it is hot: a triple buffer of Frames (newest wins); an SPSC event queue (full:
  the event is dropped, never blocking the sim, counted and warned once); a small queue of its own for what must
  never be lost (statuses, the join code, desync reports, the result); a command queue; the input sample under a
  short mutex.
- **Main thread.** `UnifiedSession._process` runs before every other node: `input_wanted`, `sample_input`, take the
  newest Frame, spawn and pose the scene views (ticks P − 1 and P pushed into each view's track, sampled at
  alpha = (now − P's due time) / tick), write each MultiMesh's buffer and bounds in one `set_buffer`, set the session
  data, route the events of the ticks the Frame shows, then statuses, then the dev UI. The screen runs one tick
  behind the newest prediction and never extrapolates: an input reaches the screen after the next tick sample, the
  input delay, and one tick of interpolation.
- **View logic** (`handoff.odin`, `track.odin`, `view_set.odin`, `event_tracker.odin`, `poses.odin`: no Godot calls,
  tested without Godot). A rollback that re-publishes a tick with a different pose puts the difference into an error
  offset that decays (`Smoothing`). A key missing from a frame lingers (an exit animation, or a rollback that brings
  it back: it is revived, not respawned), unless its spawn was never verified and a re-simulation since the last
  Frame shown covered its spawn tick: then a rollback took it away and it is cancelled (`view_cancelled`). A short
  life the verified tick never caught up with (a bullet on a client with lag) still despawns; one whose end a later
  rollback proves mispredicted keeps its exit, as an EMITTED event later CANCELLED does. Re-simulations of ticks at
  or below the verified one are ignored, since they are final.
- **Data.** A view's data is set before the view enters the tree, then whenever its bytes differ from the last
  set's: its bytes copied into an object, fields converted only when a script reads them. Each view alternates two
  objects and refills the spare only when no script holds it, so a change makes no object (a script that keeps an old
  value keeps it unchanged: the view makes a new spare); a pooled view keeps its two across reuses. A root script
  without `data` for a kind that carries some is an error, once per kind.
- **Nested values** (`nested_cache.odin`). Every object of the game's classes keeps one cached value per nested field,
  made at the field's first read, with the bytes it was made from; a read whose bytes match returns it. When they
  differ, a struct's object that only the cache holds (its reference count, as the view data's spare) is refilled in
  place; otherwise the cache lets go of it, so a script that kept it keeps it unchanged, and makes another. An `Array`
  is never refilled (an extension can't read an Array's reference count), only made anew, read-only. Each nested
  object in a cached value points back at its cache, so a script that sets one of its fields detaches the value (a
  struct element detaches its whole Array) and the next read makes a fresh one.
- **Remote links** go through a live netsim (`netcode.netsim_live`) the dev UI's Conditions panel impairs.
- **The dev UI** (`dev.odin`, the only file that reaches `unified:devui`) graphs the frame, the sim and the net, and
  feeds its panels. Dev UI builds also record the session as it is verified (a portable snapshot of the first saved
  verified tick, then every verified tick's inputs, and this machine's checksum of each checksum tick), so an F3
  note carries what `uni headless <game> -- replay` replays and checks, naming the first tick it computes
  differently.
- **Every kind's remote players on the verified timeline** (dev UI builds; off unless switched on in the Conditions
  panel or by `--verified-players`): `Remote.Verified` forced on for every kind, to compare with the prediction.
- **Debug draws and zones** (dev UI builds; `src/sim/README.md`, Debug draws and zones). The session's sim gets a
  Dev timed on the netcode's clock. The groups shown (the dev UI's draw toggles, `UnifiedSession.debug_draw`,
  `--draw`) go to the session thread as one mask, applied to the sim before each step, so only shown groups are kept;
  the frame hook copies the shown tick's draws and the zones' totals into the Frame. The main thread draws them in
  view space under `view_root` on every fresh frame (`debug_draw.odin`: 3D, one line mesh over everything and
  billboard texts; 2D, a canvas item on top), so `uni tool --shots` captures them, and the zones are the `sim`
  group's stacked graph. They show the tick the views interpolate toward, as predicted.
- **The watchdog** (dev UI builds, `watchdog.odin`). A thread beside the session's watches its step counter by its
  own polls, never the wall clock, so a suspended laptop or a debugger's pause is not a freeze. A step stuck for
  `watchdog_polls` polls writes `<user data>/feedback/freeze-<time>/`: where it froze (the tick, `fill_frame` or the
  tick, the zone stack), the recording plus the inputs the client stepped after the last verified tick, so the
  folder replays headless into the frozen tick, which a deterministic sim reproduces under a debugger (on Windows a
  minidump too); then the process aborts.
- **Starting over.** `leave` asks the session to end; it says goodbye on its thread, for at most `GOODBYE_US` (a
  host waiting for peers that don't answer). A start while a session exists leaves it the same way first, so a game
  restarts or switches modes with one call, never a silent refusal. The start waits and begins at the end of the
  frame the old session is gone in (the goodbye cut to `HURRY_US`); a newer start replaces it, a `leave` cancels it.
  It waits also when the old session ended already: a script the session calls may be running on its last Frame,
  which is freed only once that frame's sync is over, and the old session's result (its line, its recording) is
  taken first. For the same reason the node leaving the tree from such a script ends its session once the frame is
  done. The new session starts with none of the old one's views. A session is one match: a host that restarts ends
  it for every player who joined (they get its goodbye and join the new one again), so a co-op game that plays
  another round without losing its players does that inside its sim, not with a restart.
- **Quitting** (`quit.odin`). Godot reports a sound's playback still held by the AudioServer at exit as a leak, so the
  session's quits (`UnifiedSession.quit`, and the one at the end of a `--quit-at-end` run) stop every audio player in
  the tree and quit once their playbacks are freed (at most `QUIT_AUDIO_WAIT`); meanwhile the session's frame does
  nothing else. An app stops its own sound sources first (the games' `Sfx.close`), or a sound started meanwhile is
  stopped too.
- **Editor.** Classes register at SCENE level and nothing runs in the editor; the class reference loads at EDITOR
  level. `deinitialize` stops the session thread, calls the lobby's optional `shutdown`, then `gd.shutdown`
  unregisters every class.
- **Command-line flags** (after `--`; `parse_command_line`): the game and its tool scripts read their own flags from
  the same command line, so other flags pass through; a bad value of one of ours, or a near miss of a name, prints an
  error and quits (exit 2). A build without the dev UI ignores the dev flags with a warning; the session flags
  (starting, hosting and joining, `--ticks`, `--quit-at-end`) work in every build, so `uni release` smoke-tests the
  public build with them. A `--quit-at-end` run quits with 1 when its session fails, to start or later (a join
  refused), else with 0 at its result.

## Library tooling

unified's GDScript, in `tools_godot/` at unified's root, which every project sees at `res://unified/tools_godot/`
(`src/cli/README.md`, Tool scripts, says how). The scripts compile under a game's strict typing (no warnings rule
exempts them), and a game's export leaves out `unified/*`. None of it knows a game's menus: a game drives its own UI
from its own tool scripts (`game/tools/`), which extend these by class name; each script's header says what it is.
