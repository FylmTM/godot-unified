// What a game provides (the Glue), what fill_frame pushes, and what crosses from the session thread to the main thread
// (the Frame data). How a game uses them: src/godot/README.md.
package godot

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:sync"
import "unified:netcode"
import "unified:sim"

// A Frame's room when a session starts: each grows (on the session thread, which owns the slot it fills) when a push
// does not fit, so it settles after a few frames. Past the hard limits a fill_frame is a runaway loop: a panic.
@(private)
FRAME_VIEWS :: 64
@(private)
FRAME_MULTIS :: 1024
@(private)
FRAME_DATA_BYTES :: 4096
@(private)
FRAME_VIEWS_LIMIT :: 1 << 16
@(private)
FRAME_MULTIS_LIMIT :: 1 << 22
@(private)
FRAME_DATA_LIMIT :: 1 << 26

// A scene view this tick (fill_frame: push_view, after the subject it stands for). Its scene is the one the view index
// maps `kind` to. A view is identified by its kind and its subject's key (UnifiedView.key): a new subject is a new view.
View_Item :: struct($View: typeid) {
	kind:   View,
	// The player it shows ({}: its subject when that is a player, else none): get_player_view finds it by them, and
	// their events that no view took by subject come here. A view of a thing may show a player (a car's driver).
	player: sim.Player,
	pos:    sim.Position, // sim units (the host applies Glue.view_scale); 2D: pos.xy (Godot 2D: x right, y down)
	rot:    [4]f32, // unit quaternion (x, y, z, w); dmath.quat_yaw, godot.quat_turns_2d (2D); zero = identity
	// The subject's warp epoch: a value other than the one last shown snaps the view (no interpolation, no correction
	// glide). A body's is physics.body_warp (every physics teleport moves it on); a thing that is no one body keeps a
	// counter in its state and bumps it where it teleports. Rollback-safe: a re-simulated teleport bumps it to the
	// same value, an undone one puts the old value back (the view snaps back).
	warp:   u8,
}

// One MultiMesh instance this tick (fill_frame: push_multi_view). Position and rotation (on the shorter arc)
// interpolate from the instance with the same key at tick - 1 (the host remembers it); scale, color and custom are the
// tick's.
Multi_View_Item :: struct($MultiView: typeid) {
	key:    u64, // identifies the instance across ticks, per kind (a handle's sim.handle_key); 0: not interpolated
	kind:   MultiView,
	pos:    sim.Position, // like View_Item's
	rot:    [4]f32, // unit quaternion like View_Item's (2D: quat_turns_2d); zero = identity
	scale:  [3]f32, // per local axis (2D: x, y); zero = {1, 1, 1}
	color:  Color, // the instance color (use_colors), RGBA; zero = white
	custom: [4]f32, // the instance custom data (the game's shader reads it)
	warp:   u8, // the instance's warp epoch, like View_Item.warp (keyed instances only)
}

// Whether `player` is one of this client's local players at the frame's tick.
is_local :: proc(f: ^Frame($G, $View, $MultiView), player: sim.Player) -> bool {
	return local_index(f, player) >= 0
}

// Which of this client's local players `player` is (-1: none).
@(private)
local_index :: proc(f: ^Frame($G, $View, $MultiView), player: sim.Player) -> int {
	if player.id == 0 do return -1
	for local, index in f.local_players do if local == player do return index
	return -1
}

// What fill_frame gets (session thread): the tick's state and world, and where the items go. Its buffers grow to what
// a fill pushes; a fill past their hard limits is a runaway loop and panics.
Frame :: struct($G, $View, $MultiView: typeid) {
	state:         ^sim.part(G, sim.GAME_STATE),
	world:         ^sim.part(G, sim.GAME_WORLD), // at the frame's tick
	tick:          u32,
	// Who this client's local players are at this tick, by local index ({}: nobody, e.g. before a join tick): one
	// player's game reads [0]; is_local asks about a player.
	local_players: [LOCAL_MAX]sim.Player,
	seed:          u64, // the session's seed: a keyed roll the sim will make, computed early (sim.roll_below_at)
	setup:         ^sim.part(G, sim.GAME_SETUP), // the session's Setup (fixed for the session; a joiner's is the host's)
	time:          sim.Game_Time, // at this tick (sim.game_time): what a view reads timers and stamps with
	out:           ^Frame_Data, // what the main thread gets
	poses:         ^Pose_Memory, // every keyed item's pose at the fill before
}

// A scene view as published: the item, its previous pose (from the host's memory) and its data's place.
View_Out :: struct {
	key:         u64,
	kind:        u8,
	subject:     typeid, // the subject's type: sim.Player, sim.Entity, a sim.Handle(T); nil: none (push_view)
	has_prev:    bool,
	warp:        u8,
	since:       u32, // the earliest tick its key is known to be in the current timeline (appear-on-verified)
	player:      u64, // the player's key (sim.player_key; 0: none)
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
	warp:     u8,
	since:    u32, // like View_Out's (keyed instances; 0: none)
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

// What crosses to the main thread every published tick (a triple buffer of three; each grows as pushes need).
Frame_Data :: struct {
	tick:           u32, // the newest predicted tick
	verified:       u32,
	// The active level at `tick` and at the newest verified tick (the State's sim.Active_Level; id -1: none): the
	// main thread shows the verified one's scene and syncs views only from frames of the level on screen.
	level:          Level_Stamp,
	verified_level: Level_Stamp,
	tick_hz:        u32,
	setup:          [sim.SETUP_MAX]u8, // the session's Setup's bytes (UnifiedSession.setup)
	save:           [sim.SETUP_MAX]u8, // the newest Setup Game.save gave on a verified tick (netcode.client_save)
	saves:          u32, // how many times it changed this session (0: never): a new count is UnifiedSession.save_changed
	due_us:         i64, // when `tick` was due on the session clock (netcode.now_us); for alpha
	local_player:   u64, // local player 0's key at `tick` (0: nobody yet)
	local_players:  [LOCAL_MAX]u64, // each local player's key at `tick`, by local index (0: nobody)
	published:      u64, // publish counter (0: nothing yet)
	net:            netcode.Client_Stats, // the local client's (netcode.client_stats)
	slots:          [sim.MAX_PLAYERS]u64, // who holds each slot at `tick` (keys; 0: nobody)
	members:        []u64, // every player the state remembers at `tick` (keys, member order): members[:n_members]
	n_members:      int,
	views:          []View_Out,
	multis:         []Multi_Out,
	data:           []u8, // the views' and the session data's bytes, packed
	datas:          [MAX_DATA_TYPES]Data_Out, // the session data pushed this frame: datas[:n_datas]
	data_pushed:    u64, // the data kinds pushed this frame (one value per type per frame)
	n_views:        int,
	n_multis:       int,
	n_data:         int,
	n_datas:        int,
	// Dev UI builds: the shown tick's debug draws while any draw group is shown (sim.debug_draws), and the zones'
	// cumulative self times (sim.zone_totals: the zones by enum value, [sim.ZONES_MAX] "other"; zone_count 0: none).
	draws:          []sim.Debug_Shape, // draws[:n_draws]
	draw_text:      []u8, // their texts' bytes: draw_text[:n_draw_text]
	n_draws:        int,
	n_draw_text:    int,
	zone_ns:        [sim.ZONES_MAX + 1]i64,
	zone_count:     int,
	tick_us:        i64, // how long a tick lasts on screen (0: 1e6 / tick_hz; a replay at another speed)
	epoch:          u32, // bumped when the shown timeline jumps (a replay's seek): every view snaps
	replay:         Replay_View, // a replay session's state (active false: not one)
	alloc:          runtime.Allocator, // the views', multis' and data's (they grow on the session thread)
}

// What a game provides, typed by its game (a sim.Game) and its view kinds (enums); install checks it. Its procs are
// named procs, never inline lambdas.
Glue :: struct($G, $View, $MultiView: typeid) where intrinsics.type_is_specialization_of(G, sim.Game) {
	// Main thread, every frame, for each local player (`local`: its index): its Input from Godot's input (the action
	// helpers read its device, input.odin; its input values: input_values). nil for a game without one (sim.No_Input):
	// its players act through commands alone.
	sample_input: proc(local: int, input: ^sim.part(G, sim.GAME_INPUT)),
	// Session thread, every published tick: the views of the tick's state (push_view, push_multi_view) and the
	// session data (push_data).
	fill_frame:   proc(frame: ^Frame(G, View, MultiView)),
	// Optional: the game's session data types, a union of `Data_` structs (Unified.<name>, push_data).
	data:         typeid,
	// Each scene view kind's data type (push_view's `data`), `#partial {.Card = Card_View}`: a kind that pushes data
	// declares it, as Glue.data declares the session data, so GDScript has the classes of what it holds at load (its
	// enums, EnumX, and nested structs, DataX). A push with data of a kind not declared, or of another type, panics.
	view_data:    [View]typeid,
	// Optional: what only scripts know for sample_input (a camera's look direction), a plain struct: scripts set its
	// fields on Unified.input, sample_input reads them with input_values(T).
	input_values: typeid,
	// Optional, the view space (src/godot/README.md, View space): the sim's XY plane is shown in Godot 2D, x right,
	// y down (a sim.Position reaches GDScript as a Vector2, else a Vector3).
	is_2d:        bool,
	// Optional, the view space: view units per sim unit (zero: 1), e.g. 32 for 2D art drawn at 32 px per metre.
	view_scale:   f32,
	// Optional: how the host shows each scene view kind (`#partial {.Crate = {smoothing = {tau_s = 0.2}}}`); a kind
	// left out is host-posed with SMOOTHING_DEFAULT.
	view_policy:  [View]View_Policy,
	// Optional: how the host shows each MultiMesh kind. A kind whose smoothing is left zero interpolates its keyed
	// instances and lets corrections pop (no state per instance: the cheap default for thousands); one that sets it
	// gives each keyed instance a track whose corrections glide like a scene view's (`godot.SMOOTHING_DEFAULT` for
	// the defaults). `pose = .Script` is a scene view's only.
	multi_policy: [MultiView]View_Policy,

	// Main thread, optional: where an event (the game's union) goes, named the way push_view names a view, by kind
	// and subject: `godot.to_view(View.Player, subject.player)`, `to_view(View.Gate, subject.entity)`,
	// `to_view(View.Station)` (the one view of its kind); `{route = .No_View}`: none; the zero value (a bare
	// `return`): the routing by its subject (its first handle or sim.Entity field: the views pushed with that subject;
	// else, or when none is, its first sim.Player field: that player's views). So a game handles only its special
	// events.
	event_key:    proc(event: sim.part(G, sim.GAME_EVENT), subject: Subject) -> Event_Target(View),
}

// How the host shows one view kind (Glue.view_policy, multi_policy); the zero value is the default.
View_Policy :: struct {
	appear:    Appear,
	pose:      Posed_By,
	smoothing: Smoothing, // zero fields: their defaults (smoothing_of)
}

// When a view (or a keyed MultiMesh instance) of a kind first shows.
Appear :: enum u8 {
	// With the prediction: at once, and cancelled (_sim_cancelled) if a rollback removes it before its spawn tick is
	// verified. The default.
	Predicted,
	// Once a verified tick has its key: a mispredicted spawn never shows, and a key a rollback handed to another thing
	// shows only once that thing's spawn is final; from then on it is posed from the prediction like any other. A
	// view's appear effect goes in _ready; it gets its subject's events from its appearance on. Costs one more
	// fill_frame per step that re-stepped verified ticks (a rollback, a catch-up), only while some kind asks for it.
	Verified,
}

// Whether an item of a kind with `appear` shows yet: an item first known in the current timeline at tick `since`,
// with `verified` the newest verified tick.
appear_now :: proc(appear: Appear, since, verified: u32) -> bool {
	return appear == .Predicted || since <= verified
}

// Who sets a scene view's root pose.
Posed_By :: enum u8 {
	Host, // the host sets the root's position and rotation before any other node's _process: the default
	// The host calls the root script's `_sim_pose(position: Vector3, rotation: Quaternion)` (2D: `(position:
	// Vector2, rotation: float)`) with the pose it would have set, in view units, whenever it changes, and leaves the
	// root alone: the script may draw it elsewhere (what the local player holds, at render rate from the camera).
	Script,
}

// An event's subject as the host reads it (Glue.event_key): its first sim.Player field, and its first handle or
// sim.Entity field ({}, 0: none).
Subject :: struct {
	player: sim.Player,
	handle: u64, // the handle's key (sim.handle_key)
	entity: sim.Entity,
}

// An RGBA colour in sim-facing data (view and session data, events, commands, constants): a Color in GDScript. A
// plain [4]f32 is a Vector4.
Color :: distinct [4]f32

// A rotation (a unit quaternion: x, y, z, w) in sim-facing data: a Quaternion in GDScript.
Quat :: distinct [4]f32

// Where Glue.event_key sends an event: to_view's scene view, `{route = .No_View}`, or the zero value (by its subject).
Event_Target :: struct($View: typeid) {
	kind:  View,
	key:   u64, // the view's key, as push_view keys it (to_view)
	route: Event_Route,
}

// The scene view of `kind` that push_view made with this subject (none: the one view of its kind), as an
// Event_Target: Glue.event_key's answer.
to_view :: proc {
	to_view_alone,
	to_view_of_player,
	to_view_of_entity,
	to_view_of_handle,
}

// to_view of the one view of its kind (push_view_alone's, key 0).
to_view_alone :: proc(kind: $View) -> Event_Target(View) {
	return {kind, 0, .View}
}

// to_view of a player's view.
to_view_of_player :: proc(kind: $View, player: sim.Player) -> Event_Target(View) {
	return {kind, sim.player_key(player), .View}
}

// to_view of a fixed thing's view (keyed by its index, as push_view keys it).
to_view_of_entity :: proc(kind: $View, entity: sim.Entity) -> Event_Target(View) {
	index, ok := sim.entity_index(entity)
	if !ok do return {}
	return {kind, u64(index), .View}
}

// to_view of a table item's view.
to_view_of_handle :: proc(kind: $View, handle: sim.Handle($T)) -> Event_Target(View) {
	return {kind, sim.handle_key(handle), .View}
}

// Where Glue.event_key sends an event (Event_Target.route).
Event_Route :: enum u8 {
	Subject, // the routing by its subject (the default)
	View, // the scene view of the kind and key returned
	No_View, // no scene view (the sim_event signal still gets it)
}

@(private)
Mode :: enum u8 {
	Single,
	Host_Online,
	Host_Direct, // UDP on a port (LAN/dev)
	Join_Online,
	Join_Direct, // UDP to host:port
	Replay, // a recording, from the folder in Start.arg (replay.odin)
}

@(private)
Start :: struct {
	mode:         Mode,
	arg:          string, // join code or host:port
	port:         int, // Host_Direct
	local:        bool, // Host_Direct: listen on 127.0.0.1 only (--local-net), else on every interface
	name:         string,
	seed:         u64,
	ticks:        u32, // 0: endless
	scripted:     bool, // scripted input instead of the InputMap (headless checks)
	bench:        int, // Single only: Game.bench_prepare(count) after the game's init (dev benchmarks)
	token:        netcode.Token, // what the relay knows this player by when they come back over LAN (user://)
	// A host's: the session's Setup's bytes (has_setup; else the game's, Game.setup). A joiner gets the host's.
	setup:        [sim.SETUP_MAX]u8,
	has_setup:    bool,
	profile:      [sim.PROFILE_MAX]u8, // local player 0's Profile's bytes (Unified.profile at the start; scripted: Game.scripted_profile's)
	slot:         int, // a joiner's slot to ask for (-1: any; --slot)
	// --profile's assignments: laid over a scripted player's Profile too (Unified.profile has them already)
	profile_text: string,
	// Dev UI builds: watch the session thread for a freeze (watchdog.odin), dumping into `dumps` (<user data>/feedback)
	watchdog:     bool,
	dumps:        string,
	quit:         bool, // Replay: the session ends at the recording's last tick (--quit-at-end) instead of pausing there
}

@(private)
Status_Kind :: enum u8 {
	Idle,
	Connecting,
	Connected,
	Failed,
	Disconnected,
	Left,
	Reconnecting, // netcode.Status's names (the driver's status hook maps them: STATUS_OF)
	Recovering,
}

// The Godot status of each netcode.Status.
@(private)
STATUS_OF := [netcode.Status]Status_Kind {
	.Idle         = .Idle,
	.Connecting   = .Connecting,
	.Connected    = .Connected,
	.Failed       = .Failed,
	.Disconnected = .Disconnected,
	.Reconnecting = .Reconnecting,
	.Recovering   = .Recovering,
}

@(private)
STATUS_NAMES := [Status_Kind]string {
	.Idle         = "idle",
	.Connecting   = "connecting",
	.Connected    = "connected",
	.Failed       = "failed",
	.Disconnected = "disconnected",
	.Left         = "left",
	.Reconnecting = "reconnecting",
	.Recovering   = "recovering",
}

// Session thread -> main thread: an event in one of its states. Events have a queue of their own; one that finds it
// full is dropped (counted: the dev UI shows it, the host warns once).
Event_Message :: struct {
	action: Event_Action, // Emitted, Confirmed or Cancelled
	tick:   u32,
	id:     u64, // the same in its Emitted and its Confirmed or Cancelled; unique in the process (UnifiedEvent.id)
	event:  sim.Raw_Event, // positions in sim units (the main thread maps them as scripts read them)
}

// Session thread -> main thread: what must never be lost (statuses, the join code, desync reports, the result),
// in a small queue of its own.
Message :: struct {
	kind:   enum u8 {
		Status,
		Join_Code, // UnifiedSession.join_code
		Result,
		Desync, // the relay found the players' checksums of `tick` differ; text: who and what
		Mode, // a single-player session opened to friends (or failed to: text says why): UnifiedSession.mode
		Local_Refused, // the relay refused local player `local`'s Join (text: why): local_player_refused
		Link_Slow, // the link's round trip went past the game's ceiling (tick 1) or came back under it (tick 0)
	},
	status: Status_Kind,
	mode:   Mode,
	local:  u8,
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

// Pushes a scene view from fill_frame (session thread): after the frame, the subject the view stands for, then the
// item and, optionally, its data struct (set as the view's properties; a kind always pushes one data type and one
// subject type). The subject is the view's identity and its key (UnifiedView.key), and decides which events reach it
// (src/godot/README.md, Events): an event goes to the views pushed with its subject's type and key. The data, a plain
// struct, is set as the root's properties of the same names, converted like every sim-facing field
// (src/godot/README.md, Data and classes), when the view spawns and whenever its bytes change.
//
//   godot.push_view(f, player, {kind = .Ship, pos = ...}, Ship_View{...})  // a player's: keyed by sim.player_key
//   godot.push_view(f, sim.entity(i), {kind = .Gate, pos = ...})         // a fixed thing's: keyed by its index
//   godot.push_view(f, handle, {kind = .Rock, pos = ...})                // a table item's: keyed by sim.handle_key
//   godot.push_view(f, {kind = .Station, pos = ...})                     // none: the one view of its kind, key 0
push_view :: proc {
	push_view_alone,
	push_view_alone_data,
	push_view_of_player,
	push_view_of_player_data,
	push_view_of_entity,
	push_view_of_entity_data,
	push_view_of_handle,
	push_view_of_handle_data,
}

// No subject: the one view of its kind (key 0); only Glue.event_key sends it events. A player's view takes the player
// as its subject (push_view(f, player, item)): `item.player` here panics, every player's view would be key 0.
push_view_alone :: proc(frame: ^Frame($G, $View, $MultiView), item: View_Item(View), loc := #caller_location) {
	if item.player != {} do panic(ALONE_WITH_PLAYER, loc)
	push_view_out(frame, item, 0, nil, nil, nil, loc)
}

@(private)
ALONE_WITH_PLAYER :: "push_view: a view without a subject shows a player; a player's view takes them as its subject: push_view(f, player, {kind = ...})"

push_view_alone_data :: proc(
	frame: ^Frame($G, $View, $MultiView),
	item: View_Item(View),
	data: $D,
	loc := #caller_location,
) {
	if item.player != {} do panic(ALONE_WITH_PLAYER, loc)
	data := data
	push_view_out(frame, item, 0, nil, D, ([^]u8)(&data)[:size_of(D)], loc)
}

// A player's view: keyed by their key, through slot changes and rejoins; it shows them unless item.player says else.
push_view_of_player :: proc(
	frame: ^Frame($G, $View, $MultiView),
	player: sim.Player,
	item: View_Item(View),
	loc := #caller_location,
) {
	if player == {} do panic("push_view: the subject is nobody (Player{})", loc)
	item := item
	if item.player == {} do item.player = player
	push_view_out(frame, item, sim.player_key(player), sim.Player, nil, nil, loc)
}

push_view_of_player_data :: proc(
	frame: ^Frame($G, $View, $MultiView),
	player: sim.Player,
	item: View_Item(View),
	data: $D,
	loc := #caller_location,
) {
	if player == {} do panic("push_view: the subject is nobody (Player{})", loc)
	item, data := item, data
	if item.player == {} do item.player = player
	push_view_out(frame, item, sim.player_key(player), sim.Player, D, ([^]u8)(&data)[:size_of(D)], loc)
}

// A fixed thing's view (sim.entity(index): a level marker, an item of a fixed array): keyed by its index.
push_view_of_entity :: proc(
	frame: ^Frame($G, $View, $MultiView),
	entity: sim.Entity,
	item: View_Item(View),
	loc := #caller_location,
) {
	index, ok := sim.entity_index(entity)
	if !ok do panic("push_view: the subject is the zero Entity (none)", loc)
	push_view_out(frame, item, u64(index), sim.Entity, nil, nil, loc)
}

push_view_of_entity_data :: proc(
	frame: ^Frame($G, $View, $MultiView),
	entity: sim.Entity,
	item: View_Item(View),
	data: $D,
	loc := #caller_location,
) {
	index, ok := sim.entity_index(entity)
	if !ok do panic("push_view: the subject is the zero Entity (none)", loc)
	data := data
	push_view_out(frame, item, u64(index), sim.Entity, D, ([^]u8)(&data)[:size_of(D)], loc)
}

// A table item's view: keyed by sim.handle_key; only events whose subject is a Handle(T) of the same table reach it.
push_view_of_handle :: proc(
	frame: ^Frame($G, $View, $MultiView),
	handle: sim.Handle($T),
	item: View_Item(View),
	loc := #caller_location,
) {
	if handle == {} do panic("push_view: the subject is the null handle", loc)
	push_view_out(frame, item, sim.handle_key(handle), sim.Handle(T), nil, nil, loc)
}

push_view_of_handle_data :: proc(
	frame: ^Frame($G, $View, $MultiView),
	handle: sim.Handle($T),
	item: View_Item(View),
	data: $D,
	loc := #caller_location,
) {
	if handle == {} do panic("push_view: the subject is the null handle", loc)
	data := data
	push_view_out(frame, item, sim.handle_key(handle), sim.Handle(T), D, ([^]u8)(&data)[:size_of(D)], loc)
}

@(private)
push_view_out :: proc(
	frame: ^Frame($G, $View, $MultiView),
	item: View_Item(View),
	key: u64,
	subject: typeid,
	data_type: typeid,
	data: []u8,
	loc := #caller_location,
) {
	out := frame.out
	room(&out.views, out.n_views + 1, FRAME_VIEWS_LIMIT, out.alloc, loc)
	room(&out.data, out.n_data + len(data), FRAME_DATA_LIMIT, out.alloc, loc)
	kind := u8(item.kind)
	view_kind_types(kind, subject, data_type, loc)
	view_out := &out.views[out.n_views]
	out.n_views += 1
	view_out^ = {
		key         = key,
		kind        = kind,
		subject     = subject,
		player      = sim.player_key(item.player),
		pos         = ([3]f32)(item.pos),
		rot         = item.rot == {} ? IDENTITY : item.rot,
		warp        = item.warp,
		data_type   = data_type,
		data_offset = u32(out.n_data),
		data_size   = u32(len(data)),
	}
	copy(out.data[out.n_data:], data)
	out.n_data += len(data)
	previous, found, since := pose_remember(
		frame.poses,
		.View,
		kind,
		view_out.key,
		frame.tick,
		view_out.pos,
		view_out.rot,
		item.warp,
	)
	view_out.since = since
	if found do view_out.has_prev, view_out.prev_pos, view_out.prev_rot = true, previous.pos, previous.rot
}

// Session thread (fill_frame): one MultiMesh instance.
push_multi_view :: proc(
	frame: ^Frame($G, $View, $MultiView),
	item: Multi_View_Item(MultiView),
	loc := #caller_location,
) {
	out := frame.out
	room(&out.multis, out.n_multis + 1, FRAME_MULTIS_LIMIT, out.alloc, loc)
	multi_out := &out.multis[out.n_multis]
	out.n_multis += 1
	multi_out^ = {
		kind   = u8(item.kind),
		key    = item.key,
		pos    = ([3]f32)(item.pos),
		rot    = item.rot == {} ? IDENTITY : item.rot,
		scale  = item.scale,
		color  = ([4]f32)(item.color),
		custom = item.custom,
		warp   = item.warp,
	}
	if item.key != 0 {
		previous, found, since := pose_remember(
			frame.poses,
			.Multi,
			u8(item.kind),
			item.key,
			frame.tick,
			multi_out.pos,
			multi_out.rot,
			item.warp,
		)
		multi_out.since = since
		if found do multi_out.has_prev, multi_out.prev_pos, multi_out.prev_rot = true, previous.pos, previous.rot
	}
}

// Grows a Frame's buffer to hold `needed` items (doubling), on the session thread that owns the slot it fills.
@(private)
room :: proc(buffer: ^[]$T, needed, limit: int, alloc: runtime.Allocator, loc := #caller_location) {
	if needed <= len(buffer) do return
	if needed > limit do panic(fmt.tprintf("fill_frame pushed more than %d %v: a runaway loop?", limit, typeid_of(T)), loc)
	capacity := max(len(buffer), 16)
	for capacity < needed do capacity *= 2
	grown := make([]T, capacity, alloc)
	copy(grown, buffer^)
	delete(buffer^, alloc)
	buffer^ = grown
}

// Session thread (fill_frame): the session data value of type T this tick (a `Data_` struct of Glue.data), set as
// the properties of Unified.data.<name> when its bytes change. One value per type per frame (asserted).
push_data :: proc(frame: ^Frame($G, $View, $MultiView), data: $T, loc := #caller_location) {
	kind := data_kind(T, loc)
	out := frame.out
	if out.data_pushed & (1 << uint(kind)) != 0 do panic("push_data: a data type pushed twice in one frame", loc)
	room(&out.data, out.n_data + size_of(T), FRAME_DATA_LIMIT, out.alloc, loc)
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
}

// The index of a data type in Glue.data (a panic for another type).
@(private)
data_kind :: proc(type: typeid, loc := #caller_location) -> int {
	for layout, i in api.data do if layout.type.id == type do return i
	panic(fmt.tprintf("push_data: %v is not in Glue.data", type), loc)
}
