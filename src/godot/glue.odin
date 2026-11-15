// What a game provides (the Glue) and what crosses from the session thread to the main thread (the Frame data):
// src/godot/SPEC.md.
package godot

import "base:runtime"
import "core:sync"
import gd "unified:gdext"
import "unified:netcode"
import "unified:sim"
import "unified:view"

// The Frame's default capacities (Glue.max_views, max_multi, view_data_bytes override them per game). Memory only:
// three Frames are allocated when a session starts; the per-frame cost follows what fill_frame pushes.
DEFAULT_MAX_VIEWS :: 256
DEFAULT_MAX_MULTI :: 16384
DEFAULT_VIEW_DATA_BYTES :: 16384

// A scene view this tick (fill_frame: push_view). Its scene is the one the view index maps `kind` to.
View_Item :: struct($View: typeid) {
	key:    view.Key, // spawn key: a new key = a new view; must be non-zero
	kind:   View,
	player: sim.Player, // the player it shows ({}: none): events whose subject is this player come here
	entity: u64, // the id the game's events carry in a u64 `entity` field (0: none): those events come here
	pos:    [3]f32, // in the views' units; 2D: pos.xy (Godot 2D: x right, y down)
	rot:    [4]f32, // unit quaternion (x, y, z, w); view.quat_yaw, view.quat_angle2d (2D); zero = identity
}

// One MultiMesh instance this tick (fill_frame: push_multi). Position and rotation interpolate from the instance
// with the same key at tick - 1 (the host remembers it); scale, color and custom are the tick's.
Multi_Item :: struct($MultiView: typeid) {
	key:    u64, // identifies the instance across ticks, per kind (a handle's sim.handle_key); 0: not interpolated
	kind:   MultiView,
	pos:    [3]f32,
	yaw:    f32, // 3D: about +Y; 2D: the angle about Z (Node2D.rotation)
	scale:  [3]f32, // per local axis (2D: x, y); zero = {1, 1, 1}
	color:  [4]f32, // the instance color (use_colors), RGBA; zero = white
	custom: [4]f32, // the instance custom data (the game's shader reads it)
}

// What fill_frame gets (session thread): the tick's state and world, and where the items go.
Frame :: struct($State, $World, $View, $MultiView: typeid) {
	state:        ^State,
	world:        ^World, // at the frame's tick
	tick:         u32,
	local_player: sim.Player, // who this client plays at this tick ({}: nobody yet, e.g. before its join tick)
	local_slot:   int, // the slot the relay gave this client (-1: none yet)
	data:         ^Frame_Data, // what the main thread gets
	poses:        ^Pose_Memory, // every keyed item's pose at the fill before
}

Net_Stats :: struct {
	rtt_ms:      f32,
	delay:       u32, // input delay, ticks
	rollbacks:   i32,
	resim_ticks: i32,
	depth_max:   i32,
	// cumulative, for the dev UI's graphs (the host takes differences)
	stalls:      i32, // ticks held back by the prediction cap
	replaced:    i32, // ticks where the relay replaced our input (it arrived too late)
	steps:       [3]i32, // ticks stepped: verified, re-simulated, predicted
	step_us:     [3]i64, // time stepping them, µs
	last_msg_us: i64, // when the relay's last message arrived (netcode.now_us)
	bytes_in:    i64,
	bytes_out:   i64,
	desyncs:     i32, // the relay's desync reports so far
}

// A scene view as published: the item, its previous pose (from the host's memory) and its data's place.
View_Out :: struct {
	key:         view.Key,
	kind:        u8,
	has_prev:    bool,
	player:      u64, // the player's key (sim.player_key; 0: none)
	entity:      u64,
	pos:         [3]f32,
	rot:         [4]f32,
	prev_pos:    [3]f32,
	prev_rot:    [4]f32,
	data_type:   typeid, // nil: no data
	data_offset: u32, // into Frame_Data.data
	data_size:   u32,
}

// A MultiMesh instance as published.
Multi_Out :: struct {
	kind:     u8,
	has_prev: bool,
	key:      u64,
	pos:      [3]f32,
	prev_pos: [3]f32,
	yaw:      f32,
	prev_yaw: f32,
	scale:    [3]f32,
	color:    [4]f32,
	custom:   [4]f32,
}

// What crosses to the main thread every published tick (a triple buffer of three; capacities from the Glue).
Frame_Data :: struct {
	tick:         u32, // the newest predicted tick
	verified:     u32,
	tick_hz:      u32,
	due_us:       i64, // when `tick` was due on the session clock (netcode.now_us); for alpha
	local_player: u64, // the local player's key at `tick` (0: nobody yet)
	published:    u64, // publish counter (0: nothing yet)
	net:          Net_Stats,
	slots:        [sim.MAX_PLAYERS]u64, // who holds each slot at `tick` (keys; 0: nobody)
	members:      []u64, // every player the state remembers at `tick` (keys, member order): members[:n_members]
	n_members:    int,
	views:        []View_Out,
	multis:       []Multi_Out,
	data:         []u8, // the views' data, packed
	n_views:      int,
	n_multis:     int,
	n_data:       int,
	dropped:      int, // items push_view / push_multi refused (the Frame was full); the host warns once
}

// What a game provides, typed by its State, Input and World and its view kinds (enums).
Glue :: struct($State, $Input, $World, $View, $MultiView: typeid) {
	// Main thread, every frame: the local player's Input from Godot's input (the action helpers, input.odin).
	sample_input:      proc(input: ^Input),
	// Session thread, every published tick: the views of the tick's state (push_view, push_multi).
	fill_frame:        proc(frame: ^Frame(State, World, View, MultiView)),
	// Optional: the views' smoothing, in the units fill_frame writes (zero: view.SMOOTHING_DEFAULT, metres). A 2D
	// game in pixels sets it, e.g. {tau_s = 0.1, teleport_dist = 64}; the host warns when 2D views run with the
	// default.
	smoothing:         view.Smoothing,
	// Optional: event positions (sim.Position fields) reach GDScript as Vector2 (else Vector3).
	is_2d:             bool,
	// Optional: the Frame's capacities (zero: DEFAULT_MAX_VIEWS, DEFAULT_MAX_MULTI, DEFAULT_VIEW_DATA_BYTES).
	max_views:         int,
	max_multi:         int,
	view_data_bytes:   int,
	// Session thread, optional: scripted input for headless checks (--scripted), the same as the offline binary's.
	scripted_input:    proc(seed: u64, slot: int, tick: u32, state: ^State) -> Input,
	// Session thread, optional: the scripted commands that go with `scripted_input` (the offline binary's).
	scripted_commands: proc(seed: u64, slot: int, tick: u32, state: ^State, out: ^sim.Command_Out),
	// Main thread, optional: the game's constants for its scripts (UnifiedSession.constants()), straight from
	// the sim's own definitions so scripts never copy them. The host adds `tick_hz`.
	constants:         proc(dict: ^gd.Dictionary),
	// Optional, dev: prepare a single-player benchmark state after the game's init (`-- --bench N`: hold N
	// entities). Single player only: it changes the initial state, which every peer would have to share.
	bench:             proc(state: ^State, world: ^World, count: int),
	// Session thread, optional: an event's sim.Position fields in the units fill_frame writes (views and the
	// event classes get them), e.g. metres or cells to pixels. `world` is the session's World as of the newest
	// frame: read constants from it (a level's scale), not per-tick state. Nil: the sim's units.
	event_pos:         proc(position: sim.Position, world: ^World) -> sim.Position,
	// Main thread, optional: the scene view an event goes to (its spawn key; 0 = none), overriding the routing
	// by its subject (a handle field: the view with that key; an `entity` field: the view whose item's entity
	// equals it; else its first sim.Player field: that player's views). sim.event_value(event, Game_Event) reads it.
	event_key:         proc(event: ^sim.Raw_Event) -> view.Key,
	compat:            u64, // build/game id the relay checks (0: derived from the game and level, sim.compat_of)
	// Optional: the level file (src/level/SPEC.md), e.g. "res://game/levels/park.level". Read with Godot's
	// FileAccess when a session starts (it lives in the PCK in exported builds) and handed to the sim as
	// its content; every peer must have the same file.
	level:             string,
}

// Online transports (EOS P2P...) plug in here: the game's extension registers one with set_transport, so
// unified:godot never imports a platform SDK. All procs run on the session thread.
Transport :: struct {
	name:       string,
	user:       rawptr,
	// Host: open the transport and return the link the relay serves remote players on. Report the join
	// code with events.code (now or later, from pump).
	open_host:  proc(user: rawptr, events: ^Transport_Events) -> (netcode.Link, bool),
	// Join: return the link to the host's relay (packets may flow only once the transport connects).
	open_join:  proc(user: rawptr, code: string, events: ^Transport_Events) -> (netcode.Link, bool),
	// Called every loop iteration while a session uses the transport (e.g. EOS_Platform_Tick).
	pump:       proc(user: rawptr, events: ^Transport_Events),
	// The session ended (its links are already closed).
	close:      proc(user: rawptr),
	// Optional, MAIN thread, every frame (e.g. pumping the macOS main run loop for the SDK's HTTP).
	main_frame: proc(user: rawptr),
	// Optional, MAIN thread, once when the extension unloads (game exit), after the session thread is gone:
	// release the transport (an SDK left running at exit can crash in its own threads).
	shutdown:   proc(user: rawptr),
	// Optional: the local user's platform account (EOS: its product user id), once open_host succeeded: the host's
	// own player's (UnifiedSession.get_player_platform_id). The strings are copied at once.
	account:    proc(user: rawptr) -> (netcode.Account, bool),
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
	local:    bool, // Host_Direct: listen on 127.0.0.1 only (--local-net), else on every interface
	name:     string,
	seed:     u64,
	ticks:    u32, // 0: endless
	scripted: bool, // scripted input instead of the InputMap (headless checks)
	bench:    int, // Single only: Glue.bench(count) after the game's init (dev benchmarks)
	content:  []u8, // the level's bytes (Glue.level), copied by start
	token:    netcode.Token, // what the relay knows this player by when they come back over LAN (user://)
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
		Desync, // the relay found the players' checksums of `tick` differ; text: who and what
	},
	status: Status_Kind,
	action: view.Event_Action, // Emitted, Confirmed or Cancelled
	tick:   u32,
	event:  sim.Raw_Event, // positions already in view units
	text:   [128]u8,
	len:    u8,
}

// The relay's roster as the client last got it, for the main thread (UnifiedSession's name and platform getters):
// every member of the session, by member id - 1, kept after the session ends until the next one starts.
@(private)
roster: struct {
	mu:      sync.Mutex,
	entries: [dynamic]netcode.Roster_Entry,
	changes: u32, // bumped on every copy (atomic): roster_changed
}

// Main thread: a player's roster entry by key (false: not known).
roster_entry :: proc(key: i64) -> (entry: netcode.Roster_Entry, ok: bool) {
	player := sim.player_of_key(u64(key))
	sync.guard(&roster.mu)
	index := int(player.id) - 1
	if player.id == 0 || index >= len(roster.entries) || roster.entries[index].member != player.id do return
	return roster.entries[index], true
}

// Session thread: the client's roster, when it changed since the last copy.
@(private)
roster_copy :: proc(entries: []netcode.Roster_Entry, seen: ^u32, changes: u32) {
	if seen^ == changes do return
	seen^ = changes
	sync.guard(&roster.mu)
	if roster.entries.allocator.procedure == nil {
		roster.entries.allocator = runtime.heap_allocator() // lives as long as the process
	}
	resize(&roster.entries, len(entries))
	copy(roster.entries[:], entries)
	sync.atomic_add(&roster.changes, 1)
}

@(private)
roster_reset :: proc() {
	sync.guard(&roster.mu)
	clear(&roster.entries)
	sync.atomic_add(&roster.changes, 1)
}

// Session thread (fill_frame): a scene view; false when the Frame is full (counted in `dropped`).
push_view_item :: proc(
	frame: ^Frame($State, $World, $View, $MultiView),
	item: View_Item(View),
	loc := #caller_location,
) -> bool {
	return push_view_out(frame, item, nil, nil, loc)
}

// Session thread (fill_frame): a scene view with its data, set as the view's properties (a kind always pushes the
// same data type).
push_view_data :: proc(
	frame: ^Frame($State, $World, $View, $MultiView),
	item: View_Item(View),
	data: $T,
	loc := #caller_location,
) -> bool {
	data := data
	return push_view_out(frame, item, T, ([^]u8)(&data)[:size_of(T)], loc)
}

// Pushes a scene view from fill_frame, with or without its data struct; false when the Frame is full.
push_view :: proc {
	push_view_item,
	push_view_data,
}

@(private)
push_view_out :: proc(
	frame: ^Frame($State, $World, $View, $MultiView),
	item: View_Item(View),
	data_type: typeid,
	data: []u8,
	loc := #caller_location,
) -> bool {
	out := frame.data
	if item.key == 0 do panic("push_view: a view's key must be non-zero", loc)
	if out.n_views >= len(out.views) || out.n_data + len(data) > len(out.data) {
		out.dropped += 1
		return false
	}
	kind := u8(item.kind)
	view_data_type(kind, data_type, loc)
	view_out := &out.views[out.n_views]
	out.n_views += 1
	view_out^ = {
		key         = item.key,
		kind        = kind,
		player      = sim.player_key(item.player),
		entity      = item.entity,
		pos         = item.pos,
		rot         = item.rot == {} ? view.IDENTITY : item.rot,
		data_type   = data_type,
		data_offset = u32(out.n_data),
		data_size   = u32(len(data)),
	}
	copy(out.data[out.n_data:], data)
	out.n_data += len(data)
	previous, found := pose_remember(frame.poses, .View, kind, u64(item.key), frame.tick, view_out.pos, view_out.rot)
	if found do view_out.has_prev, view_out.prev_pos, view_out.prev_rot = true, previous.pos, previous.rot
	return true
}

// Session thread (fill_frame): one MultiMesh instance; false when the Frame is full (counted in `dropped`).
push_multi :: proc(frame: ^Frame($State, $World, $View, $MultiView), item: Multi_Item(MultiView)) -> bool {
	out := frame.data
	if out.n_multis >= len(out.multis) {
		out.dropped += 1
		return false
	}
	multi_out := &out.multis[out.n_multis]
	out.n_multis += 1
	multi_out^ = {
		kind   = u8(item.kind),
		key    = item.key,
		pos    = item.pos,
		yaw    = item.yaw,
		scale  = item.scale,
		color  = item.color,
		custom = item.custom,
	}
	if item.key != 0 {
		previous, found := pose_remember(
			frame.poses,
			.Multi,
			u8(item.kind),
			item.key,
			frame.tick,
			item.pos,
			{item.yaw, 0, 0, 0},
		)
		if found do multi_out.has_prev, multi_out.prev_pos, multi_out.prev_yaw = true, previous.pos, previous.rot.x
	}
	return true
}
