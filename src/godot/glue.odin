// What a game provides (the Glue) and what crosses from the session thread to the main thread (the Frame data):
// src/godot/SPEC.md.
package godot

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:sync"
import "unified:netcode"
import "unified:sim"

// The Frame's default capacities (Glue.max_views, max_multi, view_data_bytes override them per game). Memory only:
// three Frames are allocated when a session starts; the per-frame cost follows what fill_frame pushes.
DEFAULT_MAX_VIEWS :: 256
DEFAULT_MAX_MULTI :: 16384
DEFAULT_VIEW_DATA_BYTES :: 16384

// A scene view this tick (fill_frame: push_view). Its scene is the one the view index maps `kind` to. A view is
// identified by its kind and key.
View_Item :: struct($View: typeid) {
	// Unique within its kind (a handle's or a player's key, an index; 0 too): a new key = a new view. 0 with `player`
	// set: the player's key (sim.player_key).
	key:    u64,
	kind:   View,
	player: sim.Player, // the player it shows ({}: none): events whose subject is this player come here
	entity: u64, // the id the game's events carry in a u64 `entity` field (0: the key): those events come here
	pos:    [3]f32, // sim units (the host applies Glue.view_scale); 2D: pos.xy (Godot 2D: x right, y down)
	rot:    [4]f32, // unit quaternion (x, y, z, w); quat_yaw, quat_angle2d (2D); zero = identity
}

// One MultiMesh instance this tick (fill_frame: push_multi_view). Position and rotation interpolate from the
// instance with the same key at tick - 1 (the host remembers it); scale, color and custom are the tick's.
Multi_View_Item :: struct($MultiView: typeid) {
	key:    u64, // identifies the instance across ticks, per kind (a handle's sim.handle_key); 0: not interpolated
	kind:   MultiView,
	pos:    [3]f32,
	rot:    [4]f32, // unit quaternion like View_Item's (2D: quat_angle2d); zero = identity
	scale:  [3]f32, // per local axis (2D: x, y); zero = {1, 1, 1}
	color:  Color, // the instance color (use_colors), RGBA; zero = white
	custom: [4]f32, // the instance custom data (the game's shader reads it)
}

// What fill_frame gets (session thread): the tick's state and world, and where the items go.
Frame :: struct($G, $View, $MultiView: typeid) {
	state:        ^sim.part(G, sim.GAME_STATE),
	world:        ^sim.part(G, sim.GAME_WORLD), // at the frame's tick
	tick:         u32,
	local_player: sim.Player, // who this client plays at this tick ({}: nobody yet, e.g. before its join tick)
	local_slot:   int, // the slot the relay gave this client (-1: none yet)
	out:          ^Frame_Data, // what the main thread gets
	poses:        ^Pose_Memory, // every keyed item's pose at the fill before
}

// A scene view as published: the item, its previous pose (from the host's memory) and its data's place.
View_Out :: struct {
	key:         u64,
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
	rot:      [4]f32,
	prev_rot: [4]f32,
	scale:    [3]f32,
	color:    [4]f32,
	custom:   [4]f32,
}

// A session data value as published (push_data): its kind (the index in Glue.data) and its bytes' place.
Data_Out :: struct {
	kind:   u8,
	offset: u32, // into Frame_Data.data
	size:   u32,
}

// What crosses to the main thread every published tick (a triple buffer of three; capacities from the Glue).
Frame_Data :: struct {
	tick:         u32, // the newest predicted tick
	verified:     u32,
	tick_hz:      u32,
	due_us:       i64, // when `tick` was due on the session clock (netcode.now_us); for alpha
	local_player: u64, // the local player's key at `tick` (0: nobody yet)
	published:    u64, // publish counter (0: nothing yet)
	net:          netcode.Client_Stats, // the local client's (netcode.client_stats)
	slots:        [sim.MAX_PLAYERS]u64, // who holds each slot at `tick` (keys; 0: nobody)
	members:      []u64, // every player the state remembers at `tick` (keys, member order): members[:n_members]
	n_members:    int,
	views:        []View_Out,
	multis:       []Multi_Out,
	data:         []u8, // the views' and the session data's bytes, packed
	datas:        [MAX_DATA_TYPES]Data_Out, // the session data pushed this frame: datas[:n_datas]
	data_pushed:  u64, // the data kinds pushed this frame (one value per type per frame)
	n_views:      int,
	n_multis:     int,
	n_data:       int,
	n_datas:      int,
	dropped:      int, // items push_view / push_multi_view / push_data refused (the Frame was full); warned once
}

// What a game provides, typed by its game (a sim.Game) and its view kinds (enums).
Glue :: struct($G, $View, $MultiView: typeid) where intrinsics.type_is_specialization_of(G, sim.Game) {
	// Main thread, every frame: the local player's Input from Godot's input (the action helpers, input.odin).
	sample_input:    proc(input: ^sim.part(G, sim.GAME_INPUT)),
	// Session thread, every published tick: the views of the tick's state (push_view, push_multi_view) and the
	// session data (push_data).
	fill_frame:      proc(frame: ^Frame(G, View, MultiView)),
	// Optional: the game's session data types, a union of `Data_` structs (Unified.<name>, push_data).
	data:            typeid,
	// Optional: the game's fixed values for its scripts (Unified.constants): a package variable holding a plain
	// `Data_` struct (strings allowed), copied at install. Not a literal: `any` keeps its address.
	constants:       any,
	// Optional: what only scripts know for sample_input (a camera's look direction), a plain struct: scripts set its
	// fields on Unified.input, sample_input reads them with input_values(T).
	input_values:    typeid,
	// Optional: the views' smoothing, in sim units (zero: SMOOTHING_DEFAULT, for a sim in metres).
	smoothing:       Smoothing,
	// Optional, the view space: the sim's XY plane is shown in Godot 2D (a sim.Position reaches GDScript as a
	// Vector2, else a Vector3).
	is_2d:           bool,
	// Optional, the view space: view units per sim unit (zero: 1), e.g. 32 for 2D art drawn at 32 px per metre.
	// fill_frame, smoothing, events and commands are in sim units; the host scales a point where it makes a Godot
	// value (a scene view's position, a MultiMesh instance's origin, a sim.Position a script reads) and divides one a
	// script set (a command's). Scripts scale sizes with Unified.view_scale.
	view_scale:      f32,
	// Optional: the Frame's capacities (zero: DEFAULT_MAX_VIEWS, DEFAULT_MAX_MULTI, DEFAULT_VIEW_DATA_BYTES).
	max_views:       int,
	max_multi:       int,
	view_data_bytes: int,

	// Optional, dev: prepare a single-player benchmark state after the game's init (`-- --bench N`: hold N
	// entities). Single player only: it changes the initial state, which every peer would have to share.
	bench:           proc(state: ^sim.part(G, sim.GAME_STATE), world: ^sim.part(G, sim.GAME_WORLD), count: int),
	// Main thread, optional: where an event goes. `.View`: the scene view of that kind and key; `.No_View`: none;
	// `.Subject` (the zero value: a bare `return`): the routing by its subject (a handle field: the views with that
	// key; an `entity` field: the views whose entity equals it; else its first sim.Player field: that player's
	// views). So a game handles only its special events, from the subject the host read (sim.event_value(event,
	// Game_Event) reads the rest).
	event_key:       proc(event: ^sim.Raw_Event, subject: Subject) -> (kind: View, key: u64, route: Event_Route),
	compat:          u64, // build/game id the relay checks (0: derived from the game and level, sim.compat_of)
	// Optional: the level file (src/level/SPEC.md), e.g. "res://game/levels/park.level". Read with Godot's
	// FileAccess when a session starts (it lives in the PCK in exported builds) and handed to the sim as
	// its content; every peer must have the same file.
	level:           string,
}

// An event's subject as the host reads it (Glue.event_key): its first sim.Player field, and its first handle (as
// sim.handle_key, is_handle) or u64 `entity` field ({}, 0: none).
Subject :: struct {
	player:    sim.Player,
	entity:    u64,
	is_handle: bool,
}

// An RGBA colour in sim-facing data (view and session data, events, commands, constants): a Color in GDScript. A
// plain [4]f32 is a Vector4.
Color :: distinct [4]f32

// A rotation (a unit quaternion: x, y, z, w) in sim-facing data: a Quaternion in GDScript.
Quat :: distinct [4]f32

// Where Glue.event_key sends an event.
Event_Route :: enum u8 {
	Subject, // the routing by its subject (the default)
	View, // the scene view of the kind and key returned
	No_View, // no scene view (the sim_event signal still gets it)
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

// Session thread -> main thread: an event in one of its states. Events have a queue of their own; one that finds it
// full is dropped (counted: the dev UI shows it, the host warns once).
Event_Message :: struct {
	action: Event_Action, // Emitted, Confirmed or Cancelled
	tick:   u32,
	id:     u64, // the same in its Emitted and its Confirmed or Cancelled; unique in the process (UnifiedEvent.id)
	event:  sim.Raw_Event, // positions in sim units (the main thread maps them as scripts read them)
}

// Session thread -> main thread: what must never be lost (statuses, the lobby code, desync reports, the result),
// in a small queue of its own.
Message :: struct {
	kind:   enum u8 {
		Status,
		Lobby_Code,
		Result,
		Desync, // the relay found the players' checksums of `tick` differ; text: who and what
	},
	status: Status_Kind,
	tick:   u32,
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
push_view_item :: proc(frame: ^Frame($G, $View, $MultiView), item: View_Item(View), loc := #caller_location) -> bool {
	return push_view_out(frame, item, nil, nil, loc)
}

// Session thread (fill_frame): a scene view with its data, set as the view's properties (a kind always pushes the
// same data type).
push_view_data :: proc(
	frame: ^Frame($G, $View, $MultiView),
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
	frame: ^Frame($G, $View, $MultiView),
	item: View_Item(View),
	data_type: typeid,
	data: []u8,
	loc := #caller_location,
) -> bool {
	out := frame.out
	if out.n_views >= len(out.views) || out.n_data + len(data) > len(out.data) {
		out.dropped += 1
		return false
	}
	kind := u8(item.kind)
	view_data_type(kind, data_type, loc)
	view_out := &out.views[out.n_views]
	out.n_views += 1
	view_out^ = {
		key         = u64(item.key if item.key != 0 || item.player == {} else sim.player_key(item.player)),
		kind        = kind,
		player      = sim.player_key(item.player),
		entity      = item.entity != 0 ? item.entity : u64(item.key),
		pos         = item.pos,
		rot         = item.rot == {} ? IDENTITY : item.rot,
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
push_multi_view :: proc(frame: ^Frame($G, $View, $MultiView), item: Multi_View_Item(MultiView)) -> bool {
	out := frame.out
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
		rot    = item.rot == {} ? IDENTITY : item.rot,
		scale  = item.scale,
		color  = ([4]f32)(item.color),
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
			multi_out.rot,
		)
		if found do multi_out.has_prev, multi_out.prev_pos, multi_out.prev_rot = true, previous.pos, previous.rot
	}
	return true
}

// Session thread (fill_frame): the session data value of type T this tick (a `Data_` struct of Glue.data), set as
// the properties of Unified.<name> when its bytes change. One value per type per frame (asserted); false when the
// Frame is full (counted in `dropped`).
push_data :: proc(frame: ^Frame($G, $View, $MultiView), data: $T, loc := #caller_location) -> bool {
	kind := data_kind(T, loc)
	out := frame.out
	if out.data_pushed & (1 << uint(kind)) != 0 do panic("push_data: a data type pushed twice in one frame", loc)
	if out.n_data + size_of(T) > len(out.data) {
		out.dropped += 1
		return false
	}
	data := data
	out.data_pushed |= 1 << uint(kind)
	out.datas[out.n_datas] = {
		kind   = u8(kind),
		offset = u32(out.n_data),
		size   = u32(size_of(T)),
	}
	out.n_datas += 1
	copy(out.data[out.n_data:], ([^]u8)(&data)[:size_of(T)])
	out.n_data += size_of(T)
	return true
}

// The index of a data type in Glue.data (a panic for another type).
@(private)
data_kind :: proc(type: typeid, loc := #caller_location) -> int {
	for layout, i in api.data do if layout.type.id == type do return i
	panic(fmt.tprintf("push_data: %v is not in Glue.data", type), loc)
}
