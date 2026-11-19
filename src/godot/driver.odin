// The session driver, generic over the game (a sim.Game): owns the netcode host or
// client and runs it on its own thread; the netcode hooks publish Frames, events and status for the main
// thread. `install` instantiates it for one game and fills the non-generic `api` the Godot classes call.
package godot

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import cnet "core:net"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "unified:level"
import "unified:netcode"
import "unified:sim"

// The game-independent face of the installed driver (main thread).
@(private)
Api :: struct {
	installed:       bool, // false: no game, or `problems` say why it wasn't installed
	problems:        []string, // what install found wrong with the game (reported at load; nothing registered)
	game_name:       string,
	tick_hz:         int,
	view_names:      []string, // the View enum's members, lowercased, by kind
	multi_names:     []string, // the MultiView enum's members, lowercased, by kind
	view_enum:       ^runtime.Type_Info, // the View enum (the class EnumView)
	multi_enum:      ^runtime.Type_Info, // the MultiView enum (the class EnumMultiView)
	level_enum:      ^runtime.Type_Info, // the State's level enum (the class EnumLevel; nil: no level field)
	is_2d:           bool, // a sim.Position is a Vector2 (Glue.is_2d)
	view_scale:      f32, // view units per sim unit (Glue.view_scale; 1 when unset)
	view_policy:     []Kind_Policy, // Glue.view_policy by kind, filled in
	multi_policy:    []Kind_Policy, // Glue.multi_policy by kind, filled in
	appear_verified: bool, // some kind appears on verified: the driver fills verified ticks too (verified_state)
	events:          []Event_Layout, // the game's event union, by kind (events.odin)
	commands:        []Command_Layout, // the game's command union, by kind (command.odin)
	commands_type:   typeid, // the union itself
	data:            []Data_Layout, // the game's session data types (Glue.data), by kind
	constants:       Data_Layout, // the constants' type (type nil: none)
	constants_bytes: []u8, // the constants' value (install's)
	input_values:    Data_Layout, // Glue.input_values (type nil: none)
	setup:           Data_Layout, // the game's Setup (sim.Game's; the class UnifiedSetup, no fields for sim.No_Setup)
	setup_default:   []u8, // Game.setup's bytes: a new UnifiedSetup's
	profile:         Data_Layout, // the game's Profile (the class UnifiedProfile, Unified.profile)
	// Why a Setup's bytes can't be a session's ("" when they can: sim.setup_violation).
	setup_problem:   proc(bytes: []u8) -> string,
	// A Setup or Profile from `key=value,...` (sim.struct_from_text), starting from `start`'s bytes, in place; "" or
	// why not (the session flags --setup and --profile).
	setup_text:      proc(bytes: []u8, text: string) -> string,
	profile_text:    proc(bytes: []u8, text: string) -> string,
	enum_types:      []^runtime.Type_Info, // the enums the event, command, data, constants and input types use
	sample_input:    proc(), // main thread: the game's sample_input into the host's sample
	start:           proc(request: Start) -> (ok: bool, err: string),
	stop:            proc(), // ask the session to end (it keeps running until it has said goodbye)
	hurry:           proc(), // a new session waits: cut the goodbye to at most HURRY_US after the stop
	stopping:        proc() -> bool, // stop was asked (by stop or a lobby failure) and the session is ending
	wait:            proc(), // join the session thread (after stop)
	running:         proc() -> bool,
	front:           proc() -> (frame: ^Frame_Data, fresh: bool),
	pop:             proc() -> (message: Message, ok: bool),
	// The oldest queued event if its tick is at most `shown` (the tick of the Frame on screen), taken; newer ones stay
	// queued for the frame that shows their tick.
	next_event:      proc(shown: u32) -> (event: Event_Message, ok: bool),
	events_dropped:  proc() -> int, // events that found their queue full, this session
	// The session thread's frame hook since the last call (events tracked, fill_frame, the Frame published), reset.
	take_fill_stats: proc() -> Fill_Stats,
	// How late the session thread woke from its sleeps since the last call, reset (wake.odin).
	take_wake_stats: proc() -> Wake_Summary,
	state:           proc() -> (state: any, tick: u32), // the newest predicted state and its tick (while want_state)
	// What the shown tick changed against the tick before (sim.state_changes; the Inspector's op log): its lines (at
	// most `limit`, temp-allocated), how many there are, and the two ticks (0: nothing published yet).
	changes:         proc(limit: int) -> (lines: []string, total: int, tick, before: u32),
	inputs:          proc() -> any, // an Inputs_View of the newest frame, for the Input panel (while want_state)
	// The oldest command a verified tick carried that the dev UI hasn't logged yet, taken (dev UI builds).
	next_confirmed:  proc() -> (note: Command_Note, ok: bool),
	// The session's recording so far, appended to `snapshot` and `log` (dev UI builds; false: none yet).
	recording:       proc(snapshot, log: ^[dynamic]u8) -> (info: Recording_Info, ok: bool),
	event_key:       proc(event: ^sim.Raw_Event, subject: Subject) -> (kind: u8, key: u64, route: Event_Route), // Glue.event_key (nil: by subject)
	result:          proc() -> string, // the finished session's result JSON (after a Result message)
	send:            proc(command: sim.Raw_Command, local: int) -> bool, // queue local player `local`'s command (false: full)
	// Ask the session to add local player `local` (1 ..< LOCAL_MAX) with this name and Profile's bytes, or to remove it.
	local_player:    proc(local: int, add: bool, name: string, profile: []u8) -> bool,
	// Ask a running single-player session to open to friends (Host_Online, Host_Direct on `port`) or to close (Single).
	open:            proc(mode: Mode, port: int) -> bool,
	replay_control:  proc(control: Replay_Control) -> bool, // queue a control for a running replay (false: full)
	// The State's `level` field (a sim.Active_Level): its byte offset (-1: none), and each level's scene (the res:// path
	// its .level file names, "": none), in Game.levels' order.
	level_offset:    int,
	level_scenes:    []string,
	// The verified-timeline option's sampler of the session (dev UI builds; nil: none): verified_players.odin.
	sampler:         proc() -> ^Verified_Sampler,
}

api: Api

// The session thread's frame hook (tracking the ticks' events, fill_frame, publishing the Frame), summed until the main
// thread takes it (UnifiedSession.take_sync_stats).
@(private)
Fill_Stats :: struct {
	frames:   u64,
	total_ns: u64,
	max_ns:   u64,
}

@(private)
fill_stats_add :: proc(stats: ^Fill_Stats, took: time.Duration) {
	ns := u64(max(took, 0))
	sync.atomic_add(&stats.frames, 1)
	sync.atomic_add(&stats.total_ns, ns)
	for {
		seen := sync.atomic_load(&stats.max_ns)
		if ns <= seen do break
		if _, ok := sync.atomic_compare_exchange_weak(&stats.max_ns, seen, ns); ok do break
	}
}
lobby: ^netcode.Lobby // the game's lobby service (godot.init; online play); nil: Host_Online/Join_Online fail

// The main thread asks for state copies only while the dev UI shows them (atomic).
@(private)
want_state: bool

// UnifiedSession.paused (atomics): the main thread's request, which the session thread applies to its host
// (netcode.host_set_paused, single player only), and whether the session is paused now, which the property reads.
@(private)
pause_want: bool
@(private)
pause_on: bool

// The control socket's `step` (atomics): the ticks the main thread asked a paused single-player session to step, in all
// (it adds to it), the ticks the session thread has taken of them (netcode.host_advance), and the predicted tick it
// reached.
@(private)
step_req: u32
@(private)
step_taken: u32
@(private)
step_tick: u32

// The debug draw groups the main thread shows (dev UI builds; atomic): applied to the session's sim before each step
// (sim.dev_enable), so the following ticks keep those groups' draws.
@(private)
draw_mask: u64

// The session sim's draw group names (sim.Dev.groups) for the main thread: copied when they change (dev UI builds).
@(private)
draw_groups: struct {
	mu:    sync.Mutex,
	names: [sim.DEBUG_GROUPS]string, // heap-allocated, kept between sessions
	seq:   u32, // atomic: bumped on every copy
}

// Network impairment for remote links (the dev UI's Conditions panel, --lag): the main thread publishes settings
// (set_netsim), the session thread applies them to every wrapped link.
@(private)
netsim_req: struct {
	mu:  sync.Mutex,
	gen: u32,
	set: Netsim_Settings,
}

// Publishes new impairment settings from the main thread (the dev UI's Conditions panel, the --lag argument); the
// session thread applies them to every wrapped link on its next loop iteration.
@(private)
set_netsim :: proc(settings: Netsim_Settings) {
	sync.mutex_lock(&netsim_req.mu)
	netsim_req.set = settings
	sync.atomic_add(&netsim_req.gen, 1)
	sync.mutex_unlock(&netsim_req.mu)
}

@(private)
netsim_profile :: proc(enabled: bool, direction: Netsim_Dir) -> netcode.Profile {
	if !enabled do return {name = "devui"}
	return {
		name    = "devui",
		latency = i64(direction.latency_ms * 1000),
		jitter  = i64(direction.jitter_ms * 1000),
		loss    = u32(direction.loss_pct * 10),
	}
}

@(private)
Driver :: struct($G: typeid, $View, $MultiView: typeid) {
	game:            ^G,
	glue:            ^Glue(G, View, MultiView),
	req:             Start,
	host:            ^netcode.Host(G),
	client:          ^netcode.Client(G), // the local player's client (the host's own in host modes)
	online:          bool, // the session uses the lobby
	thread:          ^thread.Thread,
	stop_req:        bool, // atomic
	failed:          bool, // the lobby failed and its reason was posted (session thread)
	code_sent:       bool, // the lobby's code was posted
	hurry:           bool, // atomic
	finished:        bool, // atomic
	stopping:        bool,
	stop_at:         i64,
	slow:            bool, // the client's link was slow when last posted (Message.Link_Slow)
	frames:          Triple(Frame_Data),
	poses:           Pose_Memory, // every keyed item's pose at the fill before (session thread)
	// Appear-on-verified (api.appear_verified): the keys of the last verified tick filled, and that fill's Frame
	verified_poses:  Pose_Memory,
	verified_out:    Frame_Data,
	states:          Triple(State_Pair(sim.part(G, sim.GAME_STATE))),
	queue:           Queue(Message, 64), // statuses, the join code, desync reports, the result: never full in practice
	events:          Queue(Event_Message, 4096), // full: dropped and counted
	dropped:         int, // atomic: events that found `events` full
	fill:            Fill_Stats, // the frame hook's cost (atomic: the main thread takes it)
	wakes:           Wake_Stats, // how late the loop's sleeps woke (atomic: the main thread takes it)
	commands:        [LOCAL_MAX]Queue(sim.Raw_Command, netcode.COMMAND_QUEUE), // main thread -> hooks.commands, per local
	tracker:         Event_Tracker(Tick_Event),
	published:       u64,
	scratch:         [dynamic]Tick_Event,
	result:          string,
	bench:           G, // the game with Game.bench_prepare after init (req.bench > 0)
	alloc:           runtime.Allocator, // the starter's allocator: the session thread allocates what wait frees
	nets:            [dynamic]^netcode.Net_Sim, // the remote links' live netsims (owned by the channel)
	net_gen:         u32,
	local_mu:        sync.Mutex, // guards local_reqs
	local_reqs:      [LOCAL_MAX]Local_Request, // main thread -> session thread: add or remove a local player
	local_seen:      [LOCAL_MAX]u64, // the request generation the session thread applied last
	open_req:        Open_Request, // main thread -> session thread: open to friends, or close (guarded by local_mu)
	open_seen:       u64,
	opened:          Mode, // what it hosts on: opened to from single player, or hosted from the start (Single: not)
	open_code:       string, // the direct join code it opened with (opening again posts it again)
	roster:          u32, // the client's roster_changes last copied for the main thread
	account:         [2]string, // the host player's platform account (Lobby.account): platform, id
	inputs:          Triple(Inputs_View(G)), // for the dev UI's Input panel (while want_state)
	confirmed:       Queue(Command_Note, 256), // commands of verified ticks, for the dev UI (full: dropped)
	recording:       Recording, // the session so far, for F3 notes (dev UI builds)
	group_seq:       u32, // the sim's draw group names last copied (dev_publish)
	verified_level:  Level_Stamp, // the newest verified tick's level the frame hook found (session thread)
	// The watchdog (watchdog.odin): steps begun and ended (atomic; odd: a step in progress), fill_frame running
	// (atomic), its thread.
	step_seq:        u64,
	in_fill:         bool,
	watchdog:        ^Watchdog_Thread,
	watchdog_stop:   bool,
	// A replay session (Mode.Replay; replay.odin): its state, its controls from the main thread, the timeline's epoch
	replay:          ^Replay(G),
	replay_controls: Queue(Replay_Control, 16),
	epoch:           u32,
	sampler:         ^Verified_Sampler, // other players on the verified timeline (dev UI builds; verified_players.odin)
}

// The Inspector's state and the tick before it (the op log), copied while the dev UI shows them.
@(private)
State_Pair :: struct($State: typeid) {
	tick:   u32,
	before: u32,
	state:  State,
	prev:   State,
}

// What the dev UI's Input panel shows: the local player's newest input and the newest verified tick's.
@(private)
Inputs_View :: struct($G: typeid) {
	predicted_tick: u32,
	own:            sim.part(G, sim.GAME_INPUT), // the local player's input in the newest predicted tick (zero: no slot)
	verified_tick:  u32,
	slots:          [sim.part(G, sim.GAME_PLAYERS)]Input_Slot(sim.part(G, sim.GAME_INPUT)), // the verified tick's inputs, by slot (nobody's: all zero)
}

@(private)
Input_Slot :: struct($Input: typeid) {
	player:   u64, // who holds the slot at the predicted tick (sim.player_key; 0: nobody)
	present:  bool,
	replaced: bool, // the relay replaced a late input with the slot's last one
	input:    Input,
}

// A command a verified tick carried (any player's), for the dev UI's Commands panel.
@(private)
Command_Note :: struct {
	tick:    u32,
	command: sim.Raw_Command,
}

// The session recorded for F3 notes (dev UI builds): a portable snapshot of the first verified tick the ring still
// held, and the input log (UNIL) of every verified tick after it. A host records from its first tick, a joiner from
// its join. The session thread appends; the main thread copies it under the lock (api.recording).
@(private)
Recording :: struct {
	mu:          sync.Mutex,
	snapshot:    []u8, // nil until the first verified tick whose state was saved
	from:        u32, // the snapshot's tick
	last:        u32, // the newest tick in the log
	checkpoints: int, // the checksums the log holds
	log:         [dynamic]u8,
	stream:      sim.Log_Stream,
}

@(private)
Recording_Info :: struct {
	from, to:    u32, // the snapshot's tick, the log's last
	checkpoints: int, // the checksums of checksum ticks the log holds, to check a replay against
}

// Wraps a remote link in a live netsim the dev UI's Conditions panel impairs (ideal while it is off: datagrams go
// straight through) and returns the link to hand the netcode in place of `link`.
@(private)
wrap_link :: proc(driver: ^Driver($G, $View, $MultiView), link: netcode.Link) -> netcode.Link {
	wrapped, netsim := netcode.netsim_live(link, u32(driver.req.seed))
	sync.mutex_lock(&netsim_req.mu)
	netsim_apply(netsim, netsim_req.set)
	driver.net_gen = netsim_req.gen
	sync.mutex_unlock(&netsim_req.mu)
	append(&driver.nets, netsim)
	return wrapped
}

@(private)
netsim_apply :: proc(netsim: ^netcode.Net_Sim, settings: Netsim_Settings) {
	netcode.netsim_set(
		netsim,
		netsim_profile(settings.enabled, settings.up),
		netsim_profile(settings.enabled, settings.down),
	)
}

// The last event id an ended session gave out (main thread, between sessions): the next one continues after it.
@(private)
event_serial: u64

@(private)
g_game: rawptr
@(private)
g_glue: rawptr
@(private)
g_driver: rawptr
@(private)
g_bench_count: int

// Installs the game: call once, before godot.entry. `constants`: the game's fixed values for its scripts
// (Unified.constants, a plain `Data_` struct, strings allowed), copied here (nil: none). It never stops the load (the
// editor loads the extension too): it collects every problem (install_problems) and registers nothing of the game;
// they are printed when the extension loads, and starting a session fails with the first one.
install :: proc(game: ^$G, glue: Glue(G, $View, $MultiView), constants: any = nil) {
	State :: sim.part(G, sim.GAME_STATE)
	Input :: sim.part(G, sim.GAME_INPUT)
	Event :: sim.part(G, sim.GAME_EVENT)
	Cmd :: sim.part(G, sim.GAME_CMD)
	Setup :: sim.part(G, sim.GAME_SETUP)
	Profile :: sim.part(G, sim.GAME_PROFILE)
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	This_Driver :: Driver(G, View, MultiView)
	This_Glue :: Glue(G, View, MultiView)
	context.allocator = runtime.heap_allocator() // everything here lives as long as the process
	problems := problems_of(game, glue, constants.id)
	if len(problems) > 0 {
		api = {
			game_name = game.name,
			tick_hz   = game.tick_hz,
			problems  = problems,
		}
		return
	}
	view_names, _ := enum_names(View)
	multi_names, _ := enum_names(MultiView)
	kept_glue := new(This_Glue)
	kept_glue^ = glue
	g_game = game
	g_glue = kept_glue
	api = {
		installed     = true,
		game_name     = game.name,
		tick_hz       = game.tick_hz,
		view_names    = view_names,
		view_enum     = type_info_of(View),
		multi_enum    = type_info_of(MultiView),
		multi_names   = multi_names,
		is_2d         = glue.is_2d,
		view_scale    = glue.view_scale == 0 ? 1 : glue.view_scale,
		events        = event_layouts(Event),
		commands      = command_layouts(Cmd),
		commands_type = Cmd,
		level_offset  = -1,
	}
	when intrinsics.type_has_field(State, "level") {
		when intrinsics.type_is_specialization_of(intrinsics.type_field_type(State, "level"), sim.Active_Level) {
			api.level_offset = int(offset_of(State, level))
			api.level_enum = type_info_of(intrinsics.type_field_type(intrinsics.type_field_type(State, "level"), "id"))
		}
	}
	api.level_scenes = make([]string, len(game.levels))
	for file, i in game.levels do api.level_scenes[i] = strings.clone(level.scene_of(file.bytes))
	api.view_policy = make([]Kind_Policy, len(view_names))
	api.multi_policy = make([]Kind_Policy, len(multi_names))
	for policy, kind in glue.view_policy do api.view_policy[int(kind)] = kind_policy(policy, false)
	for policy, kind in glue.multi_policy do api.multi_policy[int(kind)] = kind_policy(policy, true)
	for policy in glue.view_policy do api.appear_verified ||= policy.appear == .Verified
	for policy in glue.multi_policy do api.appear_verified ||= policy.appear == .Verified
	for variant in sim.union_variants(glue.data) do append_elem(&kept_data, data_layout(variant))
	api.data = kept_data[:]
	if constants.id != nil {
		api.constants = data_layout(type_info_of(constants.id))
		api.constants_bytes = slice.clone(([^]u8)(constants.data)[:type_info_of(constants.id).size])
	}
	if glue.input_values != nil do api.input_values = data_layout(type_info_of(glue.input_values))
	api.setup = data_layout(type_info_of(Setup))
	api.setup_default = slice.clone(sim.bytes_of(&game.setup))
	api.profile = data_layout(type_info_of(Profile))
	api.setup_problem = proc(bytes: []u8) -> string {
		setup: Setup
		if len(bytes) < size_of(Setup) do return "the Setup's bytes are cut short"
		copy(sim.bytes_of(&setup), bytes)
		return sim.setup_violation((^G)(g_game), &setup)
	}
	api.setup_text = proc(bytes: []u8, text: string) -> string {
		start: Setup
		copy(sim.bytes_of(&start), bytes)
		setup, problem := sim.struct_from_text(start, text)
		if problem == "" do problem = sim.setup_violation((^G)(g_game), &setup)
		if problem == "" do copy(bytes, sim.bytes_of(&setup))
		return problem
	}
	api.profile_text = proc(bytes: []u8, text: string) -> string {
		start: Profile
		copy(sim.bytes_of(&start), bytes)
		profile, problem := sim.struct_from_text(start, text)
		if problem == "" do copy(bytes, sim.bytes_of(&profile))
		return problem
	}
	enum_sources: [dynamic]^runtime.Type_Info
	for layout in api.events do append(&enum_sources, layout.type)
	for layout in api.commands do append(&enum_sources, layout.type)
	for layout in api.data do append(&enum_sources, layout.type)
	if api.constants.type != nil do append(&enum_sources, api.constants.type)
	if api.input_values.type != nil do append(&enum_sources, api.input_values.type)
	append(&enum_sources, api.setup.type, api.profile.type)
	enums: [dynamic]^runtime.Type_Info
	enum_types_of(enum_sources[:], &enums)
	api.enum_types = enums[:]
	if glue.event_key != nil {
		api.event_key = proc(event: ^sim.Raw_Event, subject: Subject) -> (u8, u64, Event_Route) {
			event_value := sim.event_value(event, sim.part(G, sim.GAME_EVENT))
			target := (^This_Glue)(g_glue).event_key(event_value, subject)
			return u8(target.kind), target.key, target.route
		}
	}
	api.sample_input = proc() {
		glue := (^This_Glue)(g_glue)
		if glue.sample_input == nil do return // a game without an Input (sim.No_Input)
		for active, local in input_sample.active {
			if !active do continue
			input_sample.current = local
			input: Input
			glue.sample_input(local, &input)
			input_sample_store(local, ([^]u8)(&input)[:size_of(Input)])
		}
		input_sample.current = 0
	}
	api.start = proc(request: Start) -> (bool, string) {
		if g_driver != nil do return false, "a session is already running"
		game := (^G)(g_game)
		glue := (^This_Glue)(g_glue)
		if (request.mode == .Host_Online || request.mode == .Join_Online) && lobby == nil {
			return false, "online play is not available in this build"
		}
		driver := new(This_Driver)
		driver.alloc = context.allocator
		driver.game = game
		driver.glue = glue
		driver.req = request
		driver.req.arg = strings.clone(request.arg)
		driver.req.name = strings.clone(request.name)
		driver.verified_level = NO_LEVEL
		driver.req.dumps = strings.clone(request.dumps)
		triple_init(&driver.frames)
		for &frame in driver.frames.slots {
			frame.alloc = context.allocator
			frame.views = make([]View_Out, FRAME_VIEWS)
			frame.multis = make([]Multi_Out, FRAME_MULTIS)
			frame.data = make([]u8, FRAME_DATA_BYTES)
			frame.members = make([]u64, sim.MEMBERS_PER_SLOT * sim.part(G, sim.GAME_PLAYERS))
		}
		roster_reset()
		pose_memory_init(&driver.poses, FRAME_VIEWS, FRAME_MULTIS)
		if api.appear_verified {
			pose_memory_init(&driver.verified_poses, FRAME_VIEWS, FRAME_MULTIS)
			driver.verified_out.alloc = context.allocator
		}
		when DEVUI do driver.sampler = verified_sampler_new()
		input_sample_reset()
		triple_init(&driver.states)
		triple_init(&driver.inputs)
		tracker_init(&driver.tracker, tick_event_id, event_serial) // ids never repeat in the process
		g_driver = driver
		driver.thread = thread.create_and_start_with_poly_data(driver, driver_run)
		return true, ""
	}
	api.stop = proc() {
		if g_driver == nil do return
		sync.atomic_store(&(^This_Driver)(g_driver).stop_req, true)
	}
	api.hurry = proc() {
		if g_driver == nil do return
		sync.atomic_store(&(^This_Driver)(g_driver).hurry, true)
	}
	api.stopping = proc() -> bool {
		return g_driver != nil && sync.atomic_load(&(^This_Driver)(g_driver).stop_req)
	}
	api.wait = proc() {
		if g_driver == nil do return
		driver := (^This_Driver)(g_driver)
		sync.atomic_store(&driver.stop_req, true)
		thread.join(driver.thread)
		thread.destroy(driver.thread)
		event_serial = driver.tracker.last_serial
		tracker_destroy(&driver.tracker)
		for &frame in driver.frames.slots {
			delete(frame.views, frame.alloc)
			delete(frame.multis, frame.alloc)
			delete(frame.data, frame.alloc)
			delete(frame.members)
			delete(frame.draws, frame.alloc)
			delete(frame.draw_text, frame.alloc)
		}
		for text in driver.account do delete(text)
		sim.log_stream_end(&driver.recording.stream)
		delete(driver.recording.log)
		delete(driver.recording.snapshot)
		pose_memory_destroy(&driver.poses)
		if driver.verified_poses.alloc.procedure != nil do pose_memory_destroy(&driver.verified_poses)
		delete(driver.verified_out.views, driver.verified_out.alloc)
		delete(driver.verified_out.multis, driver.verified_out.alloc)
		delete(driver.verified_out.data, driver.verified_out.alloc)
		verified_sampler_free(driver.sampler)
		delete(driver.scratch)
		delete(driver.req.arg)
		delete(driver.req.name)
		delete(driver.req.dumps)
		delete(driver.result)
		delete(driver.nets)
		free(driver)
		g_driver = nil
	}
	api.running = proc() -> bool {
		return g_driver != nil && !sync.atomic_load(&(^This_Driver)(g_driver).finished)
	}
	api.front = proc() -> (^Frame_Data, bool) {
		if g_driver == nil do return nil, false
		frame, fresh := triple_front(&(^This_Driver)(g_driver).frames)
		if frame.published == 0 do return nil, false
		return frame, fresh
	}
	api.pop = proc() -> (Message, bool) {
		if g_driver == nil do return {}, false
		return queue_pop(&(^This_Driver)(g_driver).queue)
	}
	api.next_event = proc(shown: u32) -> (Event_Message, bool) {
		if g_driver == nil do return {}, false
		events := &(^This_Driver)(g_driver).events
		if oldest := queue_peek(events); oldest == nil || oldest.tick > shown do return {}, false
		return queue_pop(events)
	}
	api.events_dropped = proc() -> int {
		if g_driver == nil do return 0
		return sync.atomic_load(&(^This_Driver)(g_driver).dropped)
	}
	api.take_fill_stats = proc() -> Fill_Stats {
		if g_driver == nil do return {}
		fill := &(^This_Driver)(g_driver).fill
		return {
			frames   = sync.atomic_exchange(&fill.frames, 0),
			total_ns = sync.atomic_exchange(&fill.total_ns, 0),
			max_ns   = sync.atomic_exchange(&fill.max_ns, 0),
		}
	}
	api.take_wake_stats = proc() -> Wake_Summary {
		if g_driver == nil do return {}
		driver := (^This_Driver)(g_driver)
		return wake_take(&driver.wakes, i64(1_000_000 / max(driver.game.tick_hz, 1)))
	}
	api.replay_control = proc(control: Replay_Control) -> bool {
		if g_driver == nil do return false
		driver := (^This_Driver)(g_driver)
		return driver.req.mode == .Replay && queue_push(&driver.replay_controls, control)
	}
	api.send = proc(command: sim.Raw_Command, local: int) -> bool {
		if g_driver == nil || local < 0 || local >= LOCAL_MAX do return false
		return queue_push(&(^This_Driver)(g_driver).commands[local], command)
	}
	api.open = proc(mode: Mode, port: int) -> bool {
		if g_driver == nil do return false
		driver := (^This_Driver)(g_driver)
		sync.guard(&driver.local_mu)
		driver.open_req = {
			gen  = driver.open_req.gen + 1,
			mode = mode,
			port = port,
		}
		return true
	}
	api.local_player = proc(local: int, add: bool, name: string, profile: []u8) -> bool {
		if g_driver == nil || local <= 0 || local >= LOCAL_MAX do return false
		driver := (^This_Driver)(g_driver)
		sync.guard(&driver.local_mu)
		request := &driver.local_reqs[local]
		request^ = {
			gen  = request.gen + 1,
			add  = add,
			name = text_of_name(name),
		}
		copy(request.profile[:], profile)
		return true
	}
	api.result = proc() -> string {
		if g_driver == nil do return ""
		return (^This_Driver)(g_driver).result
	}
	api.state = proc() -> (any, u32) {
		if g_driver == nil do return nil, 0
		driver := (^This_Driver)(g_driver)
		pair, _ := triple_front(&driver.states)
		if pair.tick == 0 do return nil, 0
		return pair.state, pair.tick
	}
	api.changes = proc(limit: int) -> (lines: []string, total: int, tick, before: u32) {
		if g_driver == nil do return
		driver := (^This_Driver)(g_driver)
		pair, _ := triple_front(&driver.states)
		if pair.tick == 0 do return
		lines, total = sim.state_changes(type_info_of(State), &pair.prev, &pair.state, limit)
		return lines, total, pair.tick, pair.before
	}
	api.inputs = proc() -> any {
		if g_driver == nil do return nil
		driver := (^This_Driver)(g_driver)
		inputs, _ := triple_front(&driver.inputs)
		return inputs^
	}
	api.sampler = proc() -> ^Verified_Sampler {
		return g_driver != nil ? (^This_Driver)(g_driver).sampler : nil
	}
	api.next_confirmed = proc() -> (Command_Note, bool) {
		if g_driver == nil do return {}, false
		return queue_pop(&(^This_Driver)(g_driver).confirmed)
	}
	api.recording = proc(snapshot, log: ^[dynamic]u8) -> (info: Recording_Info, ok: bool) {
		if g_driver == nil do return
		recording := &(^This_Driver)(g_driver).recording
		sync.guard(&recording.mu)
		if recording.snapshot == nil do return
		append(snapshot, ..recording.snapshot)
		append(log, ..recording.log[:])
		return {recording.from, recording.last, recording.checkpoints}, true
	}
}

// The session thread, a verified tick (dev UI builds): the recording starts at the first verified tick whose
// state the ring saved (a snapshot of it) and appends every verified tick after it.
@(private)
record_tick :: proc(
	driver: ^Driver($G, $View, $MultiView),
	simulation: ^sim.Sim(G),
	tick: u32,
	inputs: ^sim.Inputs(G),
) {
	Input :: sim.part(G, sim.GAME_INPUT)
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	recording := &driver.recording
	client := driver.client
	sync.guard(&recording.mu)
	if recording.snapshot == nil {
		if sim.state_at(simulation, tick) == nil do return
		recording.snapshot = sim.snapshot_encode(simulation, tick)
		recording.from, recording.last = tick, tick
		compat := driver_compat(driver)
		header := sim.log_header(
			simulation.game,
			simulation.seed,
			&simulation.setup,
			simulation.content_hash,
			compat,
			from = tick,
		)
		sim.log_stream_begin(&recording.stream, sim.log_sink_memory(&recording.log), header)
		return
	}
	if tick != recording.last + 1 do return // verified ticks come in order
	sim.log_stream_tick(&recording.stream, inputs)
	recording.last = tick
	// this machine's checksum of each checksum tick: the majority's in a healthy session, the diverged one if not
	if value, ok := netcode.client_checksum(client, tick); ok {
		sim.log_stream_checkpoint(&recording.stream, tick, value)
		recording.checkpoints += 1
	}
}

// Session thread (dev UI builds), in the frame hook: the shown tick's draws (while a group is shown), the zones'
// totals, and the group names when they changed.
@(private)
dev_publish :: proc(driver: ^Driver($G, $View, $MultiView), out: ^Frame_Data, simulation: ^sim.Sim(G), tick: u32) {
	out.n_draws, out.n_draw_text, out.zone_count = 0, 0, 0
	dev := simulation.dev
	if dev == nil do return
	if draws := sim.debug_draws(simulation, tick); draws != nil && dev.enabled != 0 {
		room(&out.draws, len(draws.shapes), sim.DEBUG_DRAWS_LIMIT, out.alloc)
		room(&out.draw_text, len(draws.text), FRAME_DATA_LIMIT, out.alloc)
		copy(out.draws, draws.shapes[:])
		copy(out.draw_text, draws.text[:])
		out.n_draws, out.n_draw_text = len(draws.shapes), len(draws.text)
	}
	out.zone_ns, out.zone_count = dev.zone_ns, dev.zone_count
	if dev.group_seq != driver.group_seq {
		driver.group_seq = dev.group_seq
		sync.guard(&draw_groups.mu)
		for &name, i in draw_groups.names {
			if name == dev.groups[i] do continue
			delete(name, runtime.heap_allocator())
			name = strings.clone(dev.groups[i], runtime.heap_allocator())
		}
		sync.atomic_add(&draw_groups.seq, 1)
	}
}

// The Input panel's view of the newest frame (session thread, while want_state).
@(private)
fill_inputs_view :: proc(
	out: ^Inputs_View($G),
	client: ^netcode.Client(G),
	info: netcode.Frame_Info,
	holders: []sim.Player,
) {
	out^ = {}
	out.predicted_tick, out.verified_tick = info.tick, info.verified
	if own := netcode.client_inputs(client, info.tick); client.slot >= 0 && own != nil {
		out.own = own.input[client.slot]
	}
	verified := netcode.client_inputs(client, info.verified)
	if verified == nil do return
	for &slot, i in out.slots {
		slot = {
			player   = i < len(holders) ? sim.player_key(holders[i]) : 0,
			present  = i in verified.present,
			replaced = i in verified.replaced,
			input    = verified.input[i],
		}
	}
}

// A view kind's policy as the host applies it: the smoothing filled in, and whether its views keep a track.
@(private)
Kind_Policy :: struct {
	appear:    Appear,
	pose:      Posed_By,
	smoothing: Smoothing, // smoothing_of(policy.smoothing)
	tracks:    bool, // scene views always; a MultiMesh kind when its policy sets a smoothing
}

@(private)
kind_policy :: proc(policy: View_Policy, multi: bool) -> Kind_Policy {
	return {
		appear    = policy.appear,
		pose      = policy.pose,
		smoothing = smoothing_of(policy.smoothing),
		tracks    = !multi || policy.smoothing != {},
	}
}

// What install refuses in a kind's policy (`kind`: its enum member's name).
@(private)
policy_problems :: proc(policy: View_Policy, kind: string, multi: bool, problems: ^[dynamic]string) {
	finite :: proc(value: f32) -> bool {return value == value && value > -1e30 && value < 1e30}
	smoothing := policy.smoothing
	field := fmt.tprintf("Glue.%s[.%s]", multi ? "multi_policy" : "view_policy", kind)
	if multi && policy.pose == .Script {
		append(problems, fmt.aprintf("%s: pose = .Script is for scene views (an instance has no script)", field))
	}
	distances_ok := finite(smoothing.teleport_dist) && smoothing.teleport_dist >= 0
	distances_ok &&= finite(smoothing.ramp_dist) && smoothing.ramp_dist >= 0
	if !finite(smoothing.tau_s) || !finite(smoothing.ramp_tau_s) || !distances_ok {
		append(problems, fmt.aprintf("%s: the smoothing's fields must be finite, its distances not negative", field))
	}
	if smoothing.ramp_dist > 0 && !(smoothing.ramp_tau_s > 0) {
		append(problems, fmt.aprintf("%s: a smoothing with ramp_dist needs ramp_tau_s > 0", field))
	}
}

// The problems `install` would report for this game, Glue and constants (empty: it installs), installing nothing: no
// fill_frame, no sample_input for a game with an Input (or one for a game without), a bad view_scale, a View or
// MultiView enum that doesn't count up from 0, sim.game_violation, netcode.game_violation, a Glue.data, constants or
// input values type that isn't a struct, isn't plain (pointers, implicit padding) or holds one of Godot's own types, a
// view policy it refuses. A game's own test calls it (the template's `the_extension_installs`), so `uni test` reports
// these in a second, without Godot. The list and its strings live as long as the process.
install_problems :: proc {
	install_problems_with_constants,
	install_problems_without_constants,
}

install_problems_with_constants :: proc(
	game: ^$G,
	glue: Glue(G, $View, $MultiView),
	constants: proc() -> $Constants,
) -> []string {
	context.allocator = runtime.heap_allocator()
	return problems_of(game, glue, Constants)
}

install_problems_without_constants :: proc(game: ^$G, glue: Glue(G, $View, $MultiView)) -> []string {
	context.allocator = runtime.heap_allocator()
	return problems_of(game, glue, nil)
}

// install_problems for any constants type (nil: none), in the context's allocator.
@(private)
problems_of :: proc(game: ^$G, glue: Glue(G, $View, $MultiView), constants: typeid) -> []string {
	Input :: sim.part(G, sim.GAME_INPUT)
	#assert(size_of(Input) <= MAX_INPUT_BYTES, "unified:godot: the game's Input is larger than MAX_INPUT_BYTES")
	problems: [dynamic]string
	if glue.fill_frame == nil {
		append(&problems, "the Glue needs fill_frame")
	}
	if glue.sample_input == nil && size_of(Input) > 0 {
		append(&problems, "the Glue needs sample_input: the game has an Input")
	}
	if glue.sample_input != nil && size_of(Input) == 0 {
		append(&problems, "the Glue has a sample_input, but the game has no Input (sim.No_Input)")
	}
	if !(glue.view_scale >= 0 && glue.view_scale < 1e9) {
		append(
			&problems,
			fmt.aprintf("Glue.view_scale is %v: view units per sim unit, positive (zero: 1)", glue.view_scale),
		)
	}
	if _, view_ok := enum_names(View); !view_ok {
		append(&problems, fmt.aprintf("the View enum %v must count up from 0", typeid_of(View)))
	}
	if _, multi_ok := enum_names(MultiView); !multi_ok {
		append(&problems, fmt.aprintf("the MultiView enum %v must count up from 0", typeid_of(MultiView)))
	}
	if reason := sim.game_violation(game); reason != "" {
		append(&problems, strings.clone(reason))
	}
	if reason := netcode.game_violation(game); reason != "" {
		append(&problems, strings.clone(reason))
	}
	data_problems(glue.data, constants, glue.input_values, &problems)
	// every type GDScript reads by field names and classes
	named := make([dynamic]^runtime.Type_Info, context.temp_allocator)
	for variant in sim.union_variants(sim.part(G, sim.GAME_EVENT)) do append(&named, variant)
	for variant in sim.union_variants(sim.part(G, sim.GAME_CMD)) do append(&named, variant)
	for variant in sim.union_variants(glue.data) do append(&named, variant)
	if constants != nil do append(&named, type_info_of(constants))
	if glue.input_values != nil do append(&named, type_info_of(glue.input_values))
	append(&named, type_info_of(sim.part(G, sim.GAME_SETUP)), type_info_of(sim.part(G, sim.GAME_PROFILE)))
	generic_problems(named[:], &problems)
	for policy, kind in glue.view_policy do policy_problems(policy, fmt.tprint(kind), false, &problems)
	for policy, kind in glue.multi_policy do policy_problems(policy, fmt.tprint(kind), true, &problems)
	return problems[:]
}

// The session data layouts (api.data's storage).
@(private)
kept_data: [dynamic]Data_Layout

// An enum's member names, lowercased, by value (allocated for the process's lifetime): View and MultiView kinds.
// ok false when the members don't count up from 0.
@(private)
enum_names :: proc($E: typeid) -> (names: []string, ok: bool) {
	context.allocator = runtime.heap_allocator()
	info := runtime.type_info_base(type_info_of(E)).variant.(runtime.Type_Info_Enum)
	names = make([]string, len(info.names))
	ok = true
	for name, i in info.names {
		ok &&= int(info.values[i]) == i
		names[i] = strings.to_lower(name)
	}
	return
}

@(private)
post :: proc(driver: ^Driver($G, $View, $MultiView), message: Message) {
	// 64 slots for a handful of messages per session: full only when the main thread stopped reading for good
	_ = queue_push(&driver.queue, message)
}

@(private)
post_text :: proc(driver: ^Driver($G, $View, $MultiView), kind: type_of(Message{}.kind), text: string) {
	message := Message {
		kind = kind,
	}
	message.len = u8(copy(message.text[:], text))
	post(driver, message)
}

@(private)
post_status :: proc(driver: ^Driver($G, $View, $MultiView), status: Status_Kind, detail: string) {
	message := Message {
		kind   = .Status,
		status = status,
	}
	message.len = u8(copy(message.text[:], detail))
	post(driver, message)
}

// Posts the tracker's output (positions in sim units: the main thread maps them as scripts read them).
@(private)
flush_events :: proc(driver: ^Driver($G, $View, $MultiView)) {
	for tracked in driver.tracker.out {
		raw := tracked.event.raw
		message := Event_Message {
			action = tracked.action,
			tick   = tracked.event.tick,
			id     = tracked.serial,
			event  = raw,
		}
		// full: the main thread is stalled; dropping an event beats blocking the sim (counted)
		if !queue_push(&driver.events, message) do sync.atomic_add(&driver.dropped, 1)
	}
	clear(&driver.tracker.out)
}

// Feeds one simulated tick's events to the tracker, numbering repeats of a kind and subject within the tick.
@(private)
track_tick :: proc(driver: ^Driver($G, $View, $MultiView), tick: u32, events: []sim.Raw_Event) {
	tracker_begin_tick(&driver.tracker, tick)
	clear(&driver.scratch)
	for &raw in events {
		event := Tick_Event {
			tick = tick,
			raw  = raw,
		}
		if int(raw.kind) < len(api.events) {
			event.player, event.entity = event_subject(&api.events[raw.kind], raw.data[:raw.size])
		}
		for earlier in driver.scratch {
			same := earlier.raw.kind == raw.kind && earlier.entity == event.entity && earlier.player == event.player
			if same do event.nth += 1
		}
		append(&driver.scratch, event)
		tracker_event(&driver.tracker, event)
	}
	tracker_end_tick(&driver.tracker, tick)
}

// A main thread request to open a running single-player session to friends (UnifiedSession.open_online, open_direct)
// or close it again (close_online: mode Single).
@(private)
Open_Request :: struct {
	gen:  u64,
	mode: Mode,
	port: int,
}

// Session thread: the open or close the main thread asked for since the last look. Opening adds a link to the running
// host (netcode.host_add_link: its relay polls from then on, its client keeps its in-process link) and posts the join
// code and the new mode; a failure posts the mode it stays in (single player) with the reason. Closing lets nobody new
// in while the players in stay (netcode.host_set_open). Opening again reopens what it opened.
@(private)
driver_open_requests :: proc(driver: ^Driver($G, $View, $MultiView), now: i64) {
	request: Open_Request
	{
		sync.guard(&driver.local_mu)
		if driver.open_req.gen == driver.open_seen do return
		driver.open_seen = driver.open_req.gen
		request = driver.open_req
	}
	host := driver.host
	if host == nil do return // a joiner: nothing to open or close
	switch {
	case request.mode == .Single:
		netcode.host_set_open(host, false)
		post_text(driver, .Join_Code, "")
	case driver.opened != .Single && request.mode == driver.opened:
		netcode.host_set_open(host, true)
		if driver.opened == .Host_Direct do post_text(driver, .Join_Code, driver.open_code)
		if driver.opened == .Host_Online do driver.code_sent = false // lobby_pump posts it again
	case driver.opened != .Single:
		post_mode(driver, driver.opened, "this session opened another way before")
	case request.mode == .Host_Direct:
		link, ok := netcode.udp_listen(request.port, driver.req.local ? .Local : .Lan)
		if !ok {
			post_mode(driver, .Single, fmt.tprintf("cannot listen on UDP port %d", request.port))
			return
		}
		driver.open_code = strings.clone(direct_join_code(netcode.udp_bound_port(&link), driver.req.local))
		netcode.host_add_link(host, wrap_link(driver, link))
		netcode.host_set_open(host, true)
		driver.opened = .Host_Direct
		post_text(driver, .Join_Code, driver.open_code)
		post_mode(driver, .Host_Direct, "")
	case request.mode == .Host_Online:
		if lobby == nil {
			post_mode(driver, .Single, "online play is not available in this build")
			return
		}
		driver.online = true
		link, ok := lobby.open_host(lobby_build(driver))
		if !ok {
			detail := lobby.pump().detail
			lobby.close()
			driver.online = false
			post_mode(driver, .Single, detail != "" ? detail : fmt.tprintf("%s: cannot host", lobby.name))
			return
		}
		if lobby.account != nil {
			if account, has := lobby.account(); has {
				driver.account = {strings.clone(account.platform), strings.clone(account.id)}
				netcode.host_set_account(host, {driver.account[0], driver.account[1]}, now)
			}
		}
		netcode.host_add_link(host, wrap_link(driver, link))
		netcode.host_set_open(host, true)
		driver.opened = .Host_Online
		post_mode(driver, .Host_Online, "")
	}
}

// Posts the session's mode (a single-player session opened to friends, or what it stays) and why.
@(private)
post_mode :: proc(driver: ^Driver($G, $View, $MultiView), mode: Mode, detail: string) {
	message := Message {
		kind = .Mode,
		mode = mode,
	}
	message.len = u8(copy(message.text[:], detail))
	post(driver, message)
}

// Why the relay refused a local player's Join, for the game (local_player_refused).
@(private)
refused_reason :: proc(why: netcode.Reject_Reason) -> string {
	#partial switch why {
	case .Full:
		return "the session is full"
	case .Slot_Taken:
		return "that slot is taken"
	case .Closed:
		return "the session takes no new players"
	case .Incompatible:
		return "the session runs another build"
	case .Newer_Connection:
		return "this player is in the session on a newer connection"
	}
	return fmt.tprint(why)
}

// A main thread request about a local player (UnifiedSession.add_local_player, remove_local_player).
@(private)
Local_Request :: struct {
	gen:     u64,
	add:     bool,
	name:    netcode.Player_Name,
	profile: [sim.PROFILE_MAX]u8,
}

@(private)
text_of_name :: proc(name: string) -> netcode.Player_Name {
	return netcode.text_of(netcode.NAME_MAX, name)
}

// Session thread: the local player requests the main thread made since the last look, applied to the client.
@(private)
driver_local_requests :: proc(driver: ^Driver($G, $View, $MultiView), now: i64) {
	Profile :: sim.part(G, sim.GAME_PROFILE)
	if driver.client == nil do return
	sync.guard(&driver.local_mu)
	for &request, local in driver.local_reqs {
		if request.gen == driver.local_seen[local] do continue
		driver.local_seen[local] = request.gen
		if request.add {
			cfg := netcode.Local_Config(G) {
				slot        = -1,
				player_name = netcode.text_string(&request.name),
				profile     = (^Profile)(&request.profile)^,
			}
			netcode.client_add_player(driver.client, local, cfg)
		} else {
			netcode.client_remove_player(driver.client, local, now)
		}
	}
}

@(private)
driver_hooks :: proc(driver: ^Driver($G, $View, $MultiView)) -> netcode.Hooks(G) {
	State :: sim.part(G, sim.GAME_STATE)
	Input :: sim.part(G, sim.GAME_INPUT)
	Cmd :: sim.part(G, sim.GAME_CMD)
	This_Driver :: Driver(G, View, MultiView)
	hooks := netcode.Hooks(G) {
		user = driver,
		// A local player's Join refused: the main thread frees its index and tells the game (local_player_refused).
		seat = proc(user: rawptr, local: int, seated: bool, why: netcode.Reject_Reason) {
			if seated do return
			message := Message {
				kind  = .Local_Refused,
				local = u8(local),
			}
			message.len = u8(copy(message.text[:], refused_reason(why)))
			post((^This_Driver)(user), message)
		},
		sample = proc(user: rawptr, local, slot: int, tick: u32, state: ^State) -> Input {
			driver := (^This_Driver)(user)
			if driver.req.scripted && driver.game.scripted_input != nil {
				// a joiner before its snapshot has no state: the script is never handed a nil one
				return state != nil ? sim.scripted_player_input(driver.game, driver.req.seed, slot, tick, state) : {}
			}
			input: Input
			input_sample_take(local, ([^]u8)(&input)[:size_of(Input)])
			sim.seen_stamp(&input, netcode.client_seen(driver.client, tick))
			return input
		},
		// Commands sent from GDScript (send_command), in order; what the client can't take yet stays queued.
		commands = proc(user: rawptr, local, slot: int, tick: u32, state: ^State, out: ^sim.Command_Out(Cmd)) {
			driver := (^This_Driver)(user)
			if driver.req.scripted {
				if driver.game.scripted_commands != nil && state != nil {
					driver.game.scripted_commands(driver.req.seed, slot, tick, state, out)
				}
				return
			}
			for len(out.list) < out.cap {
				command := queue_pop(&driver.commands[local]) or_break
				sim.push_command(out, command)
			}
		},
		frame = proc(user: rawptr, simulation: ^sim.Sim(G), info: netcode.Frame_Info) {
			driver := (^This_Driver)(user)
			for tick in info.resim_from ..= info.tick do track_tick(driver, tick, sim.events_at(simulation, tick))
			flush_events(driver)
			client := driver.client
			current := sim.state_at(simulation, info.tick)
			if current == nil do current = &simulation.state
			local_players := frame_local_players(client, current.players.slots[:], info.tick)
			publish_frame(
				driver,
				simulation,
				info,
				// session time, back on the real clock (a paused single player's), for alpha
				i64(client.next_tick_us - client.tm.tick_us) + (driver.host != nil ? driver.host.paused_total : 0),
				local_players,
				client,
			)
		},
		verified = proc(
			user: rawptr,
			simulation: ^sim.Sim(G),
			tick: u32,
			inputs: ^sim.Inputs(G),
			events: []sim.Raw_Event,
		) {
			driver := (^This_Driver)(user)
			track_tick(driver, tick, events)
			tracker_verified(&driver.tracker, tick)
			flush_events(driver)
			when DEVUI {
				for command in inputs.commands[:inputs.command_count] {
					_ = queue_push(&driver.confirmed, Command_Note{tick, command})
				}
				record_tick(driver, simulation, tick, inputs)
				verified_sampler_tick(driver, simulation, tick)
			}
		},
		status = proc(user: rawptr, status: netcode.Status, detail: string) {
			driver := (^This_Driver)(user)
			if driver.failed do return // the lobby's failure is the session's last word
			// The session ended after this player asked to leave (UnifiedSession.leave): STATUS_LEFT, whatever came
			// first (the host's goodbye, a lost link).
			if status == .Disconnected && driver.stopping {
				post_status(driver, .Left, "")
				return
			}
			post_status(driver, STATUS_OF[status], detail)
		},
		restored = proc(user: rawptr, simulation: ^sim.Sim(G), tick: u32) {
			driver := (^This_Driver)(user)
			tracker_restored(&driver.tracker, tick) // what was predicted before the snapshot will never be verified
			flush_events(driver)
			when DEVUI {
				// The recording's snapshot and inputs no longer lead to this state: it starts over from the next
				// verified tick the ring saved.
				recording := &driver.recording
				sync.guard(&recording.mu)
				delete(recording.snapshot)
				recording.snapshot = nil
				clear(&recording.log)
				recording.checkpoints = 0
			}
		},
		desync = proc(user: rawptr, report: netcode.Desync_Report) {
			driver := (^This_Driver)(user)
			message := Message {
				kind = .Desync,
				tick = report.tick,
			}
			text := fmt.tprintf(
				"players %v differ%s%s",
				report.diverged,
				report.detail != "" ? ": " : "",
				report.detail,
			)
			message.len = u8(copy(message.text[:], text))
			post(driver, message)
		},
	}
	if api.appear_verified {
		hooks.verified_state = proc(user: rawptr, simulation: ^sim.Sim(G)) {fill_verified(
				(^This_Driver)(user),
				simulation,
			)}
	}
	return hooks
}

// Session thread: fills and publishes the Frame of `info.tick` (the netcode's frame hook; a replay's playhead), seen
// by `local_players` (by local index; [0] the first); `due_us`: when that tick was due on the session clock.
// `client`: the live session's (nil: a replay, which has no roster, net stats or input panel).
@(private)
publish_frame :: proc(
	driver: ^Driver($G, $View, $MultiView),
	simulation: ^sim.Sim(G),
	info: netcode.Frame_Info,
	due_us: i64,
	local_players: [LOCAL_MAX]sim.Player,
	client: ^netcode.Client(G),
) {
	started := time.tick_now()
	current := sim.state_at(simulation, info.tick)
	if current == nil do current = &simulation.state
	out := triple_back(&driver.frames)
	out.n_views, out.n_multis, out.n_data, out.n_datas, out.data_pushed = 0, 0, 0, 0, 0
	driver.published += 1
	out.published = driver.published
	out.tick = info.tick
	out.verified = info.verified
	out.level = level_stamp(current)
	if verified := sim.state_at(simulation, info.verified); verified != nil {
		driver.verified_level = level_stamp(verified)
	}
	out.verified_level = driver.verified_level
	out.tick_hz = u32(driver.game.tick_hz)
	copy(out.setup[:], sim.bytes_of(&simulation.setup))
	if client != nil {
		save, saves := netcode.client_save(client)
		copy(out.save[:], sim.bytes_of(&save))
		out.saves = saves
	}
	out.due_us = due_us
	out.tick_us, out.epoch = 0, driver.epoch
	if replay := driver.replay; replay != nil do replay_view(replay, out)
	slots := current.players.slots
	out.local_player = sim.player_key(local_players[0])
	for player, index in local_players do out.local_players[index] = sim.player_key(player)
	out.slots = {}
	for holder, slot in slots do out.slots[slot] = sim.player_key(holder)
	out.n_members = 0
	for member, index in current.players.members {
		if member.id != 0 && out.n_members < len(out.members) {
			out.members[out.n_members] = sim.player_key({u16(index), member.id})
			out.n_members += 1
		}
	}
	if client != nil {
		roster_copy(client.roster[:], &driver.roster, client.roster_changes)
		out.net = netcode.client_stats(client)
	}
	pose_memory_begin(&driver.poses, info.resim_from < info.tick, info.resim_from)
	frame := Frame(G, View, MultiView) {
		state         = current,
		world         = simulation.world,
		tick          = info.tick,
		local_players = local_players,
		seed          = simulation.seed,
		setup         = &simulation.setup,
		time          = sim.game_time(current, info.tick),
		out           = out,
		poses         = &driver.poses,
	}
	sync.atomic_store(&driver.in_fill, true)
	driver.glue.fill_frame(&frame)
	sync.atomic_store(&driver.in_fill, false)
	when DEVUI {
		dev_publish(driver, out, simulation, info.tick)
		if client != nil && driver.sampler != nil do verified_sampler_fill(driver.sampler, out, info)
	}
	triple_publish(&driver.frames)
	fill_stats_add(&driver.fill, time.tick_since(started))
	if sync.atomic_load(&want_state) {
		pair := triple_back(&driver.states)
		pair.tick, pair.state = info.tick, current^
		// the tick before as the ring has it (live: after a rollback, the corrected one; none: no change shown)
		before := sim.state_at(simulation, info.tick - 1)
		pair.before = before != nil ? info.tick - 1 : info.tick
		pair.prev = before != nil ? before^ : current^
		triple_publish(&driver.states)
		if client != nil {
			fill_inputs_view(triple_back(&driver.inputs), client, info, slots[:])
			triple_publish(&driver.inputs)
		}
	}
}

// Who the client's local players are at `tick`, from who holds each slot, by local index ({}: not in).
@(private)
frame_local_players :: proc(
	client: ^netcode.Client($G),
	slots: []sim.Player, // the State's players.slots
	tick: u32,
) -> (
	players: [LOCAL_MAX]sim.Player,
) {
	for &seat, index in client.locals {
		if seat.state == .Seated && tick >= seat.first_tick do players[index] = slots[seat.slot]
	}
	return
}

// Appear-on-verified (netcode's verified_state hook, while some kind asks for it): the sim stands on the newest
// verified tick; fill it into a scratch Frame for its keys, which the next frame's pose memory reads (`since`).
@(private)
fill_verified :: proc(driver: ^Driver($G, $View, $MultiView), simulation: ^sim.Sim(G)) {
	out := &driver.verified_out
	out.n_views, out.n_multis, out.n_data, out.n_datas, out.data_pushed = 0, 0, 0, 0, 0
	pose_memory_begin(&driver.verified_poses)
	frame := Frame(G, View, MultiView) {
		state         = &simulation.state,
		world         = simulation.world,
		tick          = simulation.tick,
		local_players = frame_local_players(driver.client, simulation.state.players.slots[:], simulation.tick),
		seed          = simulation.seed,
		setup         = &simulation.setup,
		time          = sim.game_time(&simulation.state, simulation.tick),
		out           = out,
		poses         = &driver.verified_poses,
	}
	sync.atomic_store(&driver.in_fill, true) // the watchdog
	driver.glue.fill_frame(&frame)
	sync.atomic_store(&driver.in_fill, false)
	driver.poses.verified = &driver.verified_poses
	driver.poses.verified_tick = simulation.tick
}

// How long a stopping session may say goodbye (peers that don't answer: the relay's 3 s End timeout), and the
// cap when a new session waits for it (a reachable peer acks in one round trip; the rest time out).
@(private)
GOODBYE_US :: 3_000_000
@(private)
HURRY_US :: 1_000_000

@(private)
driver_run :: proc(driver: ^Driver($G, $View, $MultiView)) {
	context.allocator = driver.alloc // (the temp allocator stays this thread's own)
	set_realtime_thread(driver.game.tick_hz)
	session_power_begin()
	sync.atomic_store(&pause_on, false) // a session starts unpaused, whatever the last one asked
	sync.atomic_store(&pause_want, false)
	sync.atomic_store(&step_taken, sync.atomic_load(&step_req)) // a step asked of an earlier session is over
	if !driver_open(driver) {
		driver_close(driver)
		session_power_end() // before finished: the next session's thread may begin its own right after
		sync.atomic_store(&driver.finished, true)
		return
	}
	watchdog_start(driver)
	for {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD() // this thread's temp data lives one iteration
		now := netcode.now_us()
		if driver.online do lobby_pump(driver)
		driver_local_requests(driver, now)
		driver_open_requests(driver, now)
		if len(driver.nets) > 0 && sync.atomic_load(&netsim_req.gen) != driver.net_gen {
			sync.mutex_lock(&netsim_req.mu)
			for netsim in driver.nets do netsim_apply(netsim, netsim_req.set)
			driver.net_gen = netsim_req.gen
			sync.mutex_unlock(&netsim_req.mu)
		}
		when DEVUI {
			if driver.client != nil && driver.client.sim != nil {
				sim.dev_enable(driver.client.sim, sync.atomic_load(&draw_mask))
			}
			if driver.replay != nil do sim.dev_enable(driver.replay.simulation, sync.atomic_load(&draw_mask))
		}
		if driver.replay != nil {
			if sync.atomic_load(&driver.stop_req) || driver.replay.done do break // a replay says goodbye to nobody
			sync.atomic_add(&driver.step_seq, 1)
			wake := replay_step(driver, now)
			sync.atomic_add(&driver.step_seq, 1)
			wake_sleep(&driver.wakes, min(wake, now + 16_000))
			continue
		}
		if sync.atomic_load(&driver.stop_req) && !driver.stopping {
			driver.stopping = true
			driver.stop_at = now
			if driver.host != nil do netcode.host_stop(driver.host, now)
			else do netcode.client_stop(driver.client, now)
		}
		wake: i64
		if driver.host != nil {
			// the single-player pause: refused (stays off) once the session has a remote link
			if want := sync.atomic_load(&pause_want); want != driver.host.paused {
				netcode.host_set_paused(driver.host, want && !driver.stopping, now)
			}
			sync.atomic_store(&pause_on, driver.host.paused)
		}
		sync.atomic_add(&driver.step_seq, 1) // odd: in a step (the watchdog)
		if driver.host != nil {
			if asked := sync.atomic_load(&step_req); asked != sync.atomic_load(&step_taken) {
				// the control socket's step: exact ticks of a paused session (none when it is not paused)
				netcode.host_advance(driver.host, asked - sync.atomic_load(&step_taken))
				sync.atomic_store(&step_tick, driver.host.client.predicted)
				sync.atomic_store(&step_taken, asked)
			}
			wake = netcode.host_step(driver.host, now)
		} else {
			wake = netcode.client_step(driver.client, now)
		}
		sync.atomic_add(&driver.step_seq, 1)
		if driver.host != nil ? netcode.host_finished(driver.host) : netcode.client_finished(driver.client) do break
		if driver.client.slow != driver.slow {
			driver.slow = driver.client.slow
			post(driver, Message{kind = .Link_Slow, tick = u32(driver.slow)})
		}
		goodbye: i64 = sync.atomic_load(&driver.hurry) ? HURRY_US : GOODBYE_US
		if driver.stopping && now - driver.stop_at > goodbye do break
		if driver.online do wake = min(wake, now + 4_000)
		wake_sleep(&driver.wakes, wake)
	}
	if replay := driver.replay; replay != nil {
		driver.result = fmt.aprintf(
			`{{"mode":"replay","tick":%d,"first":%d,"last":%d,"checkpoints":%d,"agreed_tick":%d,"diverged_tick":%d,"ok":%v}}`,
			replay.simulation.tick,
			replay.view.first,
			replay.view.last,
			replay.view.checkpoints,
			replay.view.agreed,
			replay.view.diverged,
			replay.view.diverged == 0,
		)
	} else {
		driver.result = strings.clone(
			netcode.client_json(netcode.client_result(driver.client, context.temp_allocator)),
		)
	}
	post(driver, Message{kind = .Result})
	watchdog_end(driver)
	driver_close(driver)
	session_power_end()
	sync.atomic_store(&driver.finished, true)
}

@(private)
driver_open :: proc(driver: ^Driver($G, $View, $MultiView)) -> bool {
	request := &driver.req
	game := driver.game
	hooks := driver_hooks(driver)
	Setup :: sim.part(G, sim.GAME_SETUP)
	Profile :: sim.part(G, sim.GAME_PROFILE)
	host_config := netcode.Host_Config(G) {
		desync_detail = DEVUI, // typed desync reports where the dev UI is (every build for now)
		dev           = DEVUI, // debug draws and zones (dev UI builds)
		player_name   = request.name,
		profile       = (^Profile)(&request.profile)^,
		seed          = request.seed,
		ticks         = request.ticks,
	}
	if request.has_setup do host_config.setup = (^Setup)(&request.setup)^
	client_config := netcode.Client_Config(G) {
		player_name = request.name,
		profile     = (^Profile)(&request.profile)^,
		slot        = -1,
		token       = request.token,
		dev         = DEVUI,
	}
	switch request.mode {
	case .Single:
		if request.bench > 0 && game.bench_prepare != nil {
			// The same game, with the benchmark state prepared after init (this process is the only peer).
			g_bench_count = request.bench
			driver.bench = game^
			driver.bench.init = proc(t: ^sim.Tick(G)) {
				game := (^G)(g_game)
				if game.init != nil do game.init(t)
				game.bench_prepare(t.state, t.world, g_bench_count)
			}
			driver.host = netcode.host_create(&driver.bench, host_config, hooks)
		} else {
			driver.host = netcode.host_create(game, host_config, hooks)
		}
	case .Host_Direct:
		link, ok := netcode.udp_listen(request.port, request.local ? .Local : .Lan)
		if !ok {
			post_status(driver, .Failed, fmt.tprintf("cannot listen on UDP port %d", request.port))
			return false
		}
		driver.host = netcode.host_create(game, host_config, hooks)
		// Hosted from the start, opened as if from single player: closing and opening again work alike.
		driver.opened = .Host_Direct
		driver.open_code = strings.clone(direct_join_code(netcode.udp_bound_port(&link), request.local))
		post_text(driver, .Join_Code, driver.open_code)
		netcode.host_add_link(driver.host, wrap_link(driver, link))
	case .Host_Online:
		driver.online = true
		link, ok := lobby.open_host(lobby_build(driver))
		if !ok {
			lobby_failed(driver, lobby.pump().detail, fmt.tprintf("%s: cannot host", lobby.name))
			return false
		}
		if lobby.account != nil {
			if account, has := lobby.account(); has {
				driver.account = {strings.clone(account.platform), strings.clone(account.id)}
				host_config.account = {driver.account[0], driver.account[1]}
			}
		}
		driver.host = netcode.host_create(game, host_config, hooks)
		driver.opened = .Host_Online
		netcode.host_add_link(driver.host, wrap_link(driver, link))
	case .Join_Direct:
		endpoint, ok := cnet.parse_endpoint(request.arg)
		if !ok {
			if host, port, split := split_host_port(request.arg); split {
				if resolved, resolve_err := cnet.resolve_ip4(fmt.tprintf("%s:%d", host, port)); resolve_err == nil {
					endpoint, ok = resolved, true
				}
			}
		}
		if !ok {
			post_status(driver, .Failed, fmt.tprintf("bad address %q (want host:port)", request.arg))
			return false
		}
		link, link_ok := netcode.udp_connect(endpoint)
		if !link_ok {
			post_status(driver, .Failed, "cannot open a UDP socket")
			return false
		}
		driver.client = netcode.client_create(game, client_config, wrap_link(driver, link), hooks)
	case .Replay:
		return replay_open(driver)
	case .Join_Online:
		driver.online = true
		link, ok := lobby.open_join(lobby_build(driver), request.arg)
		if !ok {
			lobby_failed(driver, lobby.pump().detail, fmt.tprintf("%s: cannot join %q", lobby.name, request.arg))
			return false
		}
		driver.client = netcode.client_create(game, client_config, wrap_link(driver, link), hooks)
	}
	if driver.host != nil do driver.client = driver.host.client
	return true
}

// What the session's lobby carries: the game's name, its build id as the relay computes it (the glue's, else derived
// from the game and the level), the project's stamped version and the player count.
@(private)
lobby_build :: proc(driver: ^Driver($G, $View, $MultiView)) -> netcode.Lobby_Build {
	return {
		game    = driver.game.name,
		compat  = driver_compat(driver),
		version = app_version,
		players = sim.part(G, sim.GAME_PLAYERS),
	}
}

// The session's build id as the relay computes it: from the game and the level.
@(private)
driver_compat :: proc(driver: ^Driver($G, $View, $MultiView)) -> u64 {
	return sim.compat_of(driver.game)
}

// Pumps the lobby (session thread): its code goes to the main thread once, a failure ends the session with its
// reason.
@(private)
lobby_pump :: proc(driver: ^Driver($G, $View, $MultiView)) {
	status := lobby.pump()
	if status.code != "" && !driver.code_sent {
		driver.code_sent = true
		post_text(driver, .Join_Code, status.code)
	}
	if status.stage == .Failed && !driver.failed {
		lobby_failed(driver, status.detail, "the lobby failed")
	}
}

// The lobby failed (to open, or later): its reason (else `fallback`) is the session's last status. A single-player
// session that opened to friends plays on instead: the lobby closes, nobody new gets in, the mode is single player
// again (the reason with it).
@(private)
lobby_failed :: proc(driver: ^Driver($G, $View, $MultiView), reason, fallback: string) {
	if driver.req.mode == .Single && driver.opened == .Host_Online {
		lobby.close()
		driver.online = false
		driver.opened = .Single
		driver.code_sent = false
		netcode.host_set_open(driver.host, false)
		post_text(driver, .Join_Code, "")
		post_mode(driver, .Single, reason != "" ? reason : fallback)
		return
	}
	post_status(driver, .Failed, reason != "" ? reason : fallback)
	driver.failed = true
	sync.atomic_store(&driver.stop_req, true)
}

@(private)
driver_close :: proc(driver: ^Driver($G, $View, $MultiView)) {
	sync.atomic_store(&pause_on, false)
	sync.atomic_store(&pause_want, false)
	replay_close(driver)
	if driver.host != nil {
		netcode.host_destroy(driver.host)
	} else if driver.client != nil {
		netcode.client_destroy(driver.client)
	}
	driver.host, driver.client = nil, nil
	if driver.online do lobby.close()
	delete(driver.open_code)
	driver.open_code = ""
}

@(private)
split_host_port :: proc(address: string) -> (host: string, port: int, ok: bool) {
	colon := strings.last_index_byte(address, ':')
	if colon <= 0 do return
	for digit in address[colon + 1:] {
		if digit < '0' || digit > '9' do return
		port = port * 10 + int(digit - '0')
	}
	return address[:colon], port, port > 0 && port < 65536
}
