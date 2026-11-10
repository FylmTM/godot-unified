package godot_host

import gd "unified:gdext"
import "unified:netcode"
import "unified:sim"
import "unified:view"

// What a frame shows, cut down from the game's State on the session thread (the game's `extract` fills it).
// Fixed capacities: the Frame lives in a triple buffer, three copies, no allocation per frame.
MAX_SCENE_ITEMS :: 256
SCENE_DATA_BYTES :: 64 // a scene item's typed data (Scene_Kind.data)
MAX_NAMED :: 8 // player slots whose display names travel in the Frame
NAME_BYTES :: 32
MAX_BULK_ITEMS :: 16384 // memory only (three Frames): the per-frame cost follows the items pushed
HUD_BYTES :: 4096

// A scene view kind: its scene is `<Glue.scene_dir>/<name>.tscn`. `data` (optional) is the type of the
// per-item data its views get as properties: a plain struct of bools, integers, enums, f32, [2]f32 (Vector2),
// [3]f32 (Vector3) and [4]f32 (Color), at most SCENE_DATA_BYTES. The host sets each field as the view's
// property of the same name, on spawn and whenever its bytes change, before `_sim_update`.
Scene_Kind :: struct {
	name: string,
	data: typeid,
}

// A rich entity shown by a scene (`<Glue.scene_dir>/<kind>.tscn`), keyed by its deterministic spawn key.
// The scene's root decides how it is shown: a Node3D gets `pos` and `rot`; a Node2D gets `pos.xy` as its
// position (Godot 2D: x right, y down; pos.z unused) and the angle about Z (view.angle2d_of) as its rotation.
Scene_Item :: struct {
	key:      view.Key, // spawn key: a new key = a new view; must be non-zero
	kind:     u8, // index into Glue.scenes
	slot:     i8, // player slot, -1 for none
	entity:   u32, // the entity id the game's events carry (sim.Event.entity), 0 for none
	has_prev: bool,
	pos:      [3]f32, // at the frame's tick
	rot:      [4]f32, // unit quaternion (x, y, z, w); view.quat_yaw(yaw) for a heading, view.quat_angle2d(a) in 2D; zero = identity
	prev_pos: [3]f32, // at tick - 1 (has_prev)
	prev_rot: [4]f32,
	data:     [SCENE_DATA_BYTES]u8, // the kind's data (Scene_Kind.data), written by push_scene
}

// One instance of a MultiMesh bulk view (enemies, projectiles, gems). Position and rotation are interpolated
// (has_prev), not smoothed; scale, color and custom are the tick's. A 3D MultiMesh gets pos and a yaw about
// +Y; a 2D one (transform_format TRANSFORM_2D) gets pos.xy and `yaw` as the angle about Z (Node2D.rotation).
Bulk_Item :: struct {
	kind:     u8, // index into Glue.bulk_kinds
	has_prev: bool,
	pos:      [3]f32,
	prev_pos: [3]f32,
	yaw:      f32,
	prev_yaw: f32, // has_prev: interpolated along the shorter arc
	scale:    [3]f32, // per local axis (2D: x, y); zero = {1, 1, 1}
	color:    [4]f32, // MultiMesh instance color (use_colors), RGBA; zero = white
	custom:   [4]f32, // MultiMesh custom data (the game's shader reads it)
}

Net_Stats :: struct {
	rtt_ms:      f32,
	delay:       u32, // input delay, ticks
	rollbacks:   i32,
	resim_ticks: i32,
	depth_max:   i32,
}

Frame :: struct {
	tick:       u32, // the newest predicted tick
	verified:   u32,
	tick_hz:    u32,
	due_us:     i64, // when `tick` was due on the session clock (netcode.now_us); for alpha
	local_slot: i32, // -1 until the relay assigns one
	published:  u64, // publish counter (0: nothing yet)
	net:        Net_Stats,
	names:      [MAX_NAMED][NAME_BYTES]u8, // display names from the relay's roster, by slot (NUL-padded)
	n_scene:    int,
	n_bulk:     int,
	dropped:    int, // items push_scene / push_bulk refused (the Frame was full); the host warns once
	scene:      [MAX_SCENE_ITEMS]Scene_Item,
	bulk:       [MAX_BULK_ITEMS]Bulk_Item,
	hud:        [HUD_BYTES]u8, // the game's own HUD data (it decodes it in Glue.hud)
}

// The input actions the host samples on the main thread (Godot InputMap names).
Action_Map :: struct {
	move:    [4]string, // left, right, forward, back (Input.get_vector)
	buttons: []string, // bit i of Actions.held / pressed
}

// Sampled input, as the session thread sees it.
Actions :: struct {
	move:    [2]f32, // Input.get_vector: x right, y back (3D: forward is -Z; 2D: y down, the plane's +y)
	held:    u32, // buttons held at the sample
	pressed: u32, // buttons pressed since the previous sample taken by the sim (edges never get lost)
	// Vectors the game's scripts set with UnifiedSession.set_input_vector(i, v), latest value: what input
	// depends on the view, e.g. a third-person camera's look direction (move and aim are relative to it).
	vectors: [INPUT_VECTORS][3]f32,
}

INPUT_VECTORS :: 4

// What a game provides, typed by its State S, Input I and World W.
Glue :: struct($S, $I, $W: typeid) {
	scenes:            []Scene_Kind, // e.g. {{"player", Player_View}, {"crate"}}: <scene_dir>/<name>.tscn; index = kind
	scene_dir:         string, // where the scene views live, e.g. "res://game/views"
	bulk_kinds:        []string, // e.g. {"grunt", "runner", "brute", "projectile", "gem"}
	// Optional: the scene views' smoothing, in the units `extract` writes (zero: view.SMOOTHING_DEFAULT,
	// metres). A 2D game in pixels sets it, e.g. {tau_s = 0.1, teleport_dist = 64}; the host warns when 2D
	// views run with the default.
	smoothing:         view.Smoothing,
	actions:           Action_Map,
	// Session thread: fill the scene and bulk items (push_scene, push_bulk) and `out.hud` from the state at the
	// frame's tick (`cur`), the tick before (`prev`, nil when not in the ring; sim.prev_item finds an item's
	// previous tick) and the World (physics), which is at the frame's tick.
	extract:           proc(cur: ^S, prev: ^S, world: ^W, out: ^Frame),
	// Session thread: the local player's input from the sampled actions.
	sample:            proc(a: Actions, slot: int, tick: u32, state: ^S) -> I,
	// Session thread, optional: scripted input for headless checks (--scripted), the same as the offline binary's.
	scripted:          proc(seed: u64, slot: int, tick: u32, state: ^S) -> I,
	// Session thread, optional: the scripted commands that go with `scripted` (the offline binary's).
	scripted_commands: proc(seed: u64, slot: int, tick: u32, state: ^S, out: ^sim.Command_Out),
	// Main thread: the HUD Dictionary (contract v0) from a frame. Names: frame_player_name(f, slot). `f` is nil
	// before the first frame: fill every key with its empty value, so scripts never miss one.
	hud:               proc(f: ^Frame, d: ^gd.Dictionary),
	// Main thread, optional: the game's constants for its scripts (UnifiedSession.constants()), straight from
	// the sim's own definitions so scripts never copy them. The host adds `tick_hz`.
	constants:         proc(d: ^gd.Dictionary),
	// Optional, dev: prepare a single-player benchmark state after the game's init (`-- --bench N`: hold N
	// enemies). Single player only: it changes the initial state, which every peer would have to share.
	bench:             proc(s: ^S, w: ^W, n: int),
	// Session thread, optional: an event's position in the units `extract` writes (views, `_sim_event`,
	// `sim_event`, `sim_event_2d` all get it), e.g. metres or cells to pixels. `world` is the session's World as of
	// the newest frame: read constants from it (a level's scale), not per-tick state. Nil: the sim's units.
	event_pos:         proc(pos: [3]f32, world: ^W) -> [3]f32,
	// Optional: the scene view an event belongs to (its spawn key; 0 = none). Without it, events go to the
	// player view of their slot, else to the scene view whose Scene_Item.entity equals theirs.
	event_key:         proc(e: sim.Event) -> view.Key,
	compat:            u64, // build/game id the relay checks (0: derived from the game and level, sim.compat_of)
	// Optional: the level file (src/level/SPEC.md), e.g. "res://game/levels/park.level". Read with Godot's
	// FileAccess when a session starts (it lives in the PCK in exported builds) and handed to the sim as
	// its content; every peer must have the same file.
	level:             string,
}

// Online transports (EOS P2P...) plug in here: the game's extension registers one with set_transport, so
// godot_host never imports a platform SDK. All procs run on the session thread.
Transport :: struct {
	name:       string,
	user:       rawptr,
	// Host: open the transport and return the link the relay serves remote players on. Report the join
	// code with ev.code (now or later, from pump).
	open_host:  proc(user: rawptr, ev: ^Transport_Events) -> (netcode.Link, bool),
	// Join: return the link to the host's relay (packets may flow only once the transport connects).
	open_join:  proc(user: rawptr, code: string, ev: ^Transport_Events) -> (netcode.Link, bool),
	// Called every loop iteration while a session uses the transport (e.g. EOS_Platform_Tick).
	pump:       proc(user: rawptr, ev: ^Transport_Events),
	// The session ended (its links are already closed).
	close:      proc(user: rawptr),
	// Optional, MAIN thread, every frame (e.g. pumping the macOS main run loop for the SDK's HTTP).
	main_frame: proc(user: rawptr),
	// Optional, MAIN thread, once when the extension unloads (game exit), after the session thread is gone:
	// release the transport (an SDK left running at exit can crash in its own threads).
	shutdown:   proc(user: rawptr),
}

Transport_Events :: struct {
	ctx:  rawptr,
	code: proc(ctx: rawptr, code: string), // the lobby code to show (lobby_code signal)
	fail: proc(ctx: rawptr, reason: string), // ends the session with status "failed"
}

Mode :: enum u8 {
	Single,
	Host_Online,
	Host_Direct, // UDP on a port (LAN/dev)
	Join_Online,
	Join_Direct, // UDP to host:port
}

Start :: struct {
	mode:     Mode,
	arg:      string, // join code or host:port
	port:     int, // Host_Direct
	name:     string,
	seed:     u64,
	ticks:    u32, // 0: endless
	scripted: bool, // scripted input instead of the InputMap (headless checks)
	bench:    int, // Single only: Glue.bench(n) after the game's init (dev benchmarks)
	content:  []u8, // the level's bytes (Glue.level), copied by start
}

Status_Kind :: enum u8 {
	Idle,
	Connecting,
	Connected,
	Failed,
	Disconnected,
}

STATUS_NAMES := [Status_Kind]string {
	.Idle         = "idle",
	.Connecting   = "connecting",
	.Connected    = "connected",
	.Failed       = "failed",
	.Disconnected = "disconnected",
}

// Session thread -> main thread messages.
Message :: struct {
	kind:   enum u8 {
		Status,
		Lobby_Code,
		Event,
		Result,
	},
	status: Status_Kind,
	action: view.Event_Action,
	tick:   u32,
	event:  sim.Event,
	text:   [128]u8,
	len:    u8,
}

// A player's display name from the frame's roster ("" when unknown).
frame_player_name :: proc(f: ^Frame, slot: int) -> string {
	if slot < 0 || slot >= MAX_NAMED do return ""
	n := &f.names[slot]
	l := 0
	for l < NAME_BYTES && n[l] != 0 do l += 1
	return string(n[:l])
}

// Session thread (extract): appends a scene item; false when the Frame is full (counted in `dropped`).
push_scene_item :: proc(out: ^Frame, it: Scene_Item) -> bool {
	if out.n_scene >= MAX_SCENE_ITEMS {
		out.dropped += 1
		return false
	}
	out.scene[out.n_scene] = it
	out.n_scene += 1
	return true
}

// Session thread (extract): appends a scene item with its kind's data (Scene_Kind.data must be T).
push_scene_data :: proc(out: ^Frame, it: Scene_Item, data: $T, loc := #caller_location) -> bool {
	#assert(size_of(T) <= SCENE_DATA_BYTES, "scene data is at most SCENE_DATA_BYTES")
	assert(
		int(it.kind) < len(api.scenes) && api.scenes[it.kind].data == T,
		"push_scene: not the kind's data type",
		loc,
	)
	if !push_scene_item(out, it) do return false
	data := data
	copy(out.scene[out.n_scene - 1].data[:], ([^]u8)(&data)[:size_of(T)])
	return true
}

push_scene :: proc {
	push_scene_item,
	push_scene_data,
}

// Session thread (extract): appends a bulk item; false when the Frame is full (counted in `dropped`).
push_bulk :: proc(out: ^Frame, it: Bulk_Item) -> bool {
	if out.n_bulk >= MAX_BULK_ITEMS {
		out.dropped += 1
		return false
	}
	out.bulk[out.n_bulk] = it
	out.n_bulk += 1
	return true
}
