// The session driver, generic over the game (its State, Input, World and PLAYERS): owns the netcode host or
// client and runs it on its own thread; the netcode hooks publish Frames, events and status for the main
// thread. `install` instantiates it for one game and fills the non-generic `api` the Godot classes call.
package godot

import "base:runtime"
import "core:fmt"
import cnet "core:net"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "unified:netcode"
import "unified:sim"
import "unified:view"

// The game-independent face of the installed driver (main thread).
Api :: struct {
	installed:       bool, // false: no game, or `problems` say why it wasn't installed
	problems:        []string, // what install found wrong with the game (reported at load; nothing registered)
	game_name:       string,
	tick_hz:         int,
	view_names:      []string, // the View enum's members, lowercased, by kind
	multi_names:     []string, // the MultiView enum's members, lowercased, by kind
	smoothing:       view.Smoothing,
	is_2d:           bool, // event positions are Vector2s
	events:          []Event_Layout, // the game's event union, by kind (events.odin)
	commands:        []Command_Layout, // the game's command union, by kind (command.odin)
	commands_type:   typeid, // the union itself
	data:            []Data_Layout, // the game's session data types (Glue.data), by kind
	constants:       Data_Layout, // the constants' type (type nil: none)
	constants_bytes: []u8, // Glue.constants' value
	enum_types:      []^runtime.Type_Info, // the enums the event, command, data and constants types use
	sample_input:    proc(), // main thread: the game's sample_input into the host's sample
	start:           proc(request: Start) -> (ok: bool, err: string),
	stop:            proc(), // ask the session to end (it keeps running until it has said goodbye)
	hurry:           proc(), // a new session waits: cut the goodbye to at most HURRY_US after the stop
	stopping:        proc() -> bool, // stop was asked (by stop or a transport failure) and the session is ending
	wait:            proc(), // join the session thread (after stop)
	running:         proc() -> bool,
	front:           proc() -> (frame: ^Frame_Data, fresh: bool),
	pop:             proc() -> (message: Message, ok: bool),
	// The oldest queued event if its tick is at most `shown` (the tick of the Frame on screen), taken; newer ones stay
	// queued for the frame that shows their tick.
	next_event:      proc(shown: u32) -> (event: Event_Message, ok: bool),
	events_dropped:  proc() -> int, // events that found their queue full, this session
	state:           proc() -> any, // the newest predicted state, for the inspector (while want_state)
	inputs:          proc() -> any, // an Inputs_View of the newest frame, for the Input panel (while want_state)
	// The oldest command a verified tick carried that the dev UI hasn't logged yet, taken (dev UI builds).
	next_confirmed:  proc() -> (note: Command_Note, ok: bool),
	// The session's recording so far, appended to `snapshot` and `log` (dev UI builds; false: none yet).
	recording:       proc(snapshot, log: ^[dynamic]u8) -> (info: Recording_Info, ok: bool),
	event_key:       proc(event: ^sim.Raw_Event) -> (kind: u8, key: view.Key, ok: bool), // Glue.event_key (nil: by subject)
	level:           string, // Glue.level
	result:          proc() -> string, // the finished session's result JSON (after a Result message)
	send:            proc(command: sim.Raw_Command) -> bool, // queue a command for the running session (false: full)
}

api: Api
transport: ^Transport // set by the game's extension (online play); nil: Host_Online/Join_Online fail

// The main thread asks for state copies only while the dev UI shows them (atomic).
want_state: bool

// Registers the online transport (EOS P2P...) that Host_Online and Join_Online use. A game's extension calls it
// from its init entry point, so unified:godot never imports a platform SDK.
set_transport :: proc(new_transport: ^Transport) {
	transport = new_transport
}

// One direction of the dev netsim.
Netsim_Dir :: struct {
	latency_ms: f32,
	jitter_ms:  f32,
	loss_pct:   f32,
}

Netsim_Settings :: struct {
	enabled: bool,
	up:      Netsim_Dir, // to the relay
	down:    Netsim_Dir, // from it
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

Driver :: struct($State, $Input, $World: typeid, $PLAYERS: int, $View, $MultiView: typeid) {
	game:      ^sim.Game(State, Input, World, PLAYERS),
	glue:      ^Glue(State, Input, World, View, MultiView),
	req:       Start,
	host:      ^netcode.Host(State, Input, World, PLAYERS),
	client:    ^netcode.Client(State, Input, World, PLAYERS), // the local player's client (the host's own in host modes)
	tev:       Transport_Events,
	uses_tp:   bool,
	thread:    ^thread.Thread,
	stop_req:  bool, // atomic
	failed:    bool, // the transport's fail hook posted the reason (session thread)
	hurry:     bool, // atomic
	finished:  bool, // atomic
	stopping:  bool,
	stop_at:   i64,
	frames:    view.Triple(Frame_Data),
	poses:     Pose_Memory, // every keyed item's pose at the fill before (session thread)
	states:    view.Triple(State),
	queue:     view.Queue(Message, 64), // statuses, the lobby code, desync reports, the result: never full in practice
	events:    view.Queue(Event_Message, 4096), // full: dropped and counted
	dropped:   int, // atomic: events that found `events` full
	commands:  view.Queue(sim.Raw_Command, netcode.COMMAND_QUEUE), // main thread -> the client's hooks.commands
	tracker:   view.Event_Tracker(Tick_Event),
	published: u64,
	scratch:   [dynamic]Tick_Event,
	result:    string,
	bench:     sim.Game(State, Input, World, PLAYERS), // the game with Glue.bench after init (req.bench > 0)
	alloc:     runtime.Allocator, // the starter's allocator: the session thread allocates what wait frees
	nets:      [dynamic]^Dev_Link, // wrapped remote links (owned by the channel)
	net_gen:   u32,
	roster:    u32, // the client's roster_changes last copied for the main thread
	account:   [2]string, // the host player's platform account (Transport.account): platform, id
	inputs:    view.Triple(Inputs_View(Input, PLAYERS)), // for the dev UI's Input panel (while want_state)
	confirmed: view.Queue(Command_Note, 256), // commands of verified ticks, for the dev UI (full: dropped)
	recording: Recording, // the session so far, for F3 notes (dev UI builds)
}

// What the dev UI's Input panel shows: the local player's newest input and the newest verified tick's.
Inputs_View :: struct($Input: typeid, $PLAYERS: int) {
	predicted_tick: u32,
	own:            Input, // the local player's input in the newest predicted tick (zero: no slot)
	verified_tick:  u32,
	slots:          [PLAYERS]Input_Slot(Input), // the verified tick's inputs, by slot (nobody's: all zero)
}

Input_Slot :: struct($Input: typeid) {
	player:   u64, // who holds the slot at the predicted tick (sim.player_key; 0: nobody)
	present:  bool,
	replaced: bool, // the relay replaced a late input with the slot's last one
	input:    Input,
}

// A command a verified tick carried (any player's), for the dev UI's Commands panel.
Command_Note :: struct {
	tick:    u32,
	command: sim.Raw_Command,
}

// The session recorded for F3 notes (dev UI builds): a portable snapshot of the first verified tick the ring still
// held, and the input log (UNIL) of every verified tick after it. A host records from its first tick, a joiner from
// its join. The session thread appends; the main thread copies it under the lock (api.recording).
Recording :: struct {
	mu:       sync.Mutex,
	snapshot: []u8, // nil until the first verified tick whose state was saved
	from:     u32, // the snapshot's tick
	last:     u32, // the newest tick in the log
	check:    [2]u64, // (tick, checksum) of the newest tick the client checksummed after `from` (tick 0: none yet)
	log:      [dynamic]u8,
	stream:   sim.Log_Stream,
}

Recording_Info :: struct {
	from, to:   u32, // the snapshot's tick, the log's last
	check_tick: u32, // a tick the log reaches and its checksum, to check a replay against (0: none yet)
	check:      u64,
}

// A remote link the dev UI's Conditions panel can impair live. While the netsim is off, datagrams go straight to
// the inner link (no copies, no queue); the netcode.Net_Sim is created on the first enable, and after a
// disable it keeps delivering until its queues are empty.
Dev_Link :: struct {
	inner: netcode.Link,
	sim:   netcode.Link, // the netsim wrapping inner (data == nil: not created yet); owns inner once created
	on:    bool,
	seed:  u32,
}

// Wraps a remote link so the Conditions panel can impair it live; returns the Dev_Link to apply settings to and the
// link to hand the netcode in place of `inner` (closing it frees the Dev_Link).
dev_link_wrap :: proc(inner: netcode.Link, seed: u32) -> (^Dev_Link, netcode.Link) {
	dev_link := new(Dev_Link)
	dev_link^ = {
		inner = inner,
		seed  = seed | 1,
	}
	return dev_link, {
		data    = dev_link,
		send    = dev_link_send,
		recv    = dev_link_recv,
		close   = dev_link_close,
		event   = inner.event == nil ? nil : dev_link_event,
		// the transport's own: it frees the peer (UDP) or closes its connection (EOS), netsim on or off
		forget  = inner.forget == nil ? nil : proc(data: rawptr, peer: netcode.Peer) {
			netcode.link_forget(&(^Dev_Link)(data).inner, peer)
		},
		account = inner.account == nil ? nil : proc(data: rawptr, peer: netcode.Peer) -> (netcode.Account, bool) {
			return netcode.link_account(&(^Dev_Link)(data).inner, peer)
		},
	}
}

// Applies the panel's settings (the link's thread).
dev_link_set :: proc(dev_link: ^Dev_Link, settings: Netsim_Settings) {
	up, down := netsim_profile(settings.enabled, settings.up), netsim_profile(settings.enabled, settings.down)
	dev_link.on = !netcode.profile_is_ideal(up) || !netcode.profile_is_ideal(down)
	if dev_link.on && dev_link.sim.data == nil {
		// a profile that isn't ideal, so netsim_wrap wraps; both directions are set below
		dev_link.sim = netcode.netsim_wrap(dev_link.inner, netcode.profile_is_ideal(up) ? down : up, dev_link.seed)
	}
	if dev_link.sim.data != nil {
		net_sim := (^netcode.Net_Sim)(dev_link.sim.data)
		net_sim.profile, net_sim.profile_in, net_sim.split = up, down, true
	}
}

@(private)
dev_link_draining :: proc(dev_link: ^Dev_Link) -> bool {
	if dev_link.sim.data == nil do return false
	net_sim := (^netcode.Net_Sim)(dev_link.sim.data)
	return dev_link.on || len(net_sim.outgoing) > 0 || len(net_sim.incoming) > 0
}

@(private)
dev_link_send :: proc(data: rawptr, to: netcode.Peer, bytes: []u8) {
	dev_link := (^Dev_Link)(data)
	if dev_link.on {
		dev_link.sim.send(dev_link.sim.data, to, bytes)
	} else {
		dev_link.inner.send(dev_link.inner.data, to, bytes)
	}
}

@(private)
dev_link_recv :: proc(data: rawptr, buf: []u8) -> (size: int, from: netcode.Peer, ok: bool) {
	dev_link := (^Dev_Link)(data)
	if dev_link_draining(dev_link) do return dev_link.sim.recv(dev_link.sim.data, buf)
	return dev_link.inner.recv(dev_link.inner.data, buf)
}

@(private)
dev_link_event :: proc(data: rawptr) -> (peer: netcode.Peer, kind: netcode.Link_Event_Kind, ok: bool) {
	dev_link := (^Dev_Link)(data)
	return dev_link.inner.event(dev_link.inner.data)
}

@(private)
dev_link_close :: proc(data: rawptr) {
	dev_link := (^Dev_Link)(data)
	if dev_link.sim.data != nil {
		netcode.link_close(&dev_link.sim) // closes inner too
	} else {
		netcode.link_close(&dev_link.inner)
	}
	free(dev_link)
}

@(private)
wrap_link :: proc(
	driver: ^Driver($State, $Input, $World, $PLAYERS, $View, $MultiView),
	link: netcode.Link,
) -> netcode.Link {
	dev_link, wrapped := dev_link_wrap(link, u32(driver.req.seed))
	sync.mutex_lock(&netsim_req.mu)
	dev_link_set(dev_link, netsim_req.set)
	driver.net_gen = netsim_req.gen
	sync.mutex_unlock(&netsim_req.mu)
	append(&driver.nets, dev_link)
	return wrapped
}

@(private)
g_game: rawptr
@(private)
g_glue: rawptr
@(private)
g_driver: rawptr
@(private)
g_bench_count: int

// Installs the game: call once, before godot.entry. It never stops the load: a game with problems (a bad Glue, a
// sim that fails the game checks, a data type that clashes) is reported with print_error when the extension loads
// and nothing of it is registered, so the editor still opens and a session fails with the reason.
install :: proc(
	game: ^sim.Game($State, $Input, $World, $PLAYERS),
	glue: Glue(State, Input, World, $View, $MultiView),
) {
	This_Driver :: Driver(State, Input, World, PLAYERS, View, MultiView)
	This_Glue :: Glue(State, Input, World, View, MultiView)
	#assert(size_of(Input) <= MAX_INPUT_BYTES, "unified:godot: the game's Input is larger than MAX_INPUT_BYTES")
	context.allocator = runtime.heap_allocator() // everything here lives as long as the process
	problems: [dynamic]string
	if glue.sample_input == nil || glue.fill_frame == nil {
		append(&problems, "the Glue needs sample_input and fill_frame")
	}
	view_names, view_ok := enum_names(View)
	multi_names, multi_ok := enum_names(MultiView)
	if !view_ok do append(&problems, fmt.aprintf("the View enum %v must count up from 0", typeid_of(View)))
	if !multi_ok do append(&problems, fmt.aprintf("the MultiView enum %v must count up from 0", typeid_of(MultiView)))
	if reason := sim.game_violation(game.name, game.tick_hz, game.commands, game.events); reason != "" {
		append(&problems, strings.clone(reason))
	}
	if _, reason := sim.players_layout_of(type_info_of(State), PLAYERS); reason != "" {
		append(&problems, strings.clone(reason))
	}
	if reason := sim.plain_violation(type_info_of(State)); reason != "" {
		append(&problems, fmt.aprintf("State: %s", reason))
	}
	if reason := sim.plain_violation(type_info_of(Input)); reason != "" {
		append(&problems, fmt.aprintf("Input: %s", reason))
	}
	data_problems(glue.data, glue.constants.id, &problems)
	if glue.constants.id != nil && glue.constants.data == nil do append(&problems, "Glue.constants holds no value")
	if len(problems) > 0 {
		api = {
			game_name = game.name,
			tick_hz   = game.tick_hz,
			problems  = problems[:],
		}
		return
	}
	kept_glue := new(This_Glue)
	kept_glue^ = glue
	g_game = game
	g_glue = kept_glue
	api = {
		installed     = true,
		game_name     = game.name,
		tick_hz       = game.tick_hz,
		view_names    = view_names,
		multi_names   = multi_names,
		smoothing     = glue.smoothing == {} ? view.SMOOTHING_DEFAULT : glue.smoothing,
		is_2d         = glue.is_2d,
		events        = event_layouts(game.events),
		commands      = command_layouts(game.commands),
		commands_type = game.commands,
		level         = glue.level,
	}
	for variant in sim.union_variants(glue.data) do append_elem(&kept_data, data_layout(variant))
	api.data = kept_data[:]
	if glue.constants.id != nil {
		api.constants = data_layout(type_info_of(glue.constants.id))
		api.constants_bytes = slice.clone(([^]u8)(glue.constants.data)[:type_info_of(glue.constants.id).size])
	}
	enum_sources: [dynamic]^runtime.Type_Info
	for layout in api.events do append(&enum_sources, layout.type)
	for layout in api.commands do append(&enum_sources, layout.type)
	for layout in api.data do append(&enum_sources, layout.type)
	if api.constants.type != nil do append(&enum_sources, api.constants.type)
	enums: [dynamic]^runtime.Type_Info
	enum_types_of(enum_sources[:], &enums)
	api.enum_types = enums[:]
	if glue.event_key != nil {
		api.event_key = proc(event: ^sim.Raw_Event) -> (u8, view.Key, bool) {
			kind, key, ok := (^This_Glue)(g_glue).event_key(event)
			return u8(kind), key, ok
		}
	}
	api.sample_input = proc() {
		glue := (^This_Glue)(g_glue)
		input, held: Input
		glue.sample_input(&input)
		input_sample.no_press = true
		glue.sample_input(&held)
		input_sample.no_press = false
		input_sample_store(([^]u8)(&input)[:size_of(Input)], ([^]u8)(&held)[:size_of(Input)])
	}
	api.start = proc(request: Start) -> (bool, string) {
		if g_driver != nil do return false, "a session is already running"
		game := (^sim.Game(State, Input, World, PLAYERS))(g_game)
		glue := (^This_Glue)(g_glue)
		if (request.mode == .Host_Online || request.mode == .Join_Online) && transport == nil {
			return false, "online play is not available in this build"
		}
		driver := new(This_Driver)
		driver.alloc = context.allocator
		driver.game = game
		driver.glue = glue
		driver.req = request
		driver.req.arg = strings.clone(request.arg)
		driver.req.name = strings.clone(request.name)
		driver.req.content = slice.clone(request.content)
		view.triple_init(&driver.frames)
		max_views := glue.max_views > 0 ? glue.max_views : DEFAULT_MAX_VIEWS
		max_multi := glue.max_multi > 0 ? glue.max_multi : DEFAULT_MAX_MULTI
		data_bytes := glue.view_data_bytes > 0 ? glue.view_data_bytes : DEFAULT_VIEW_DATA_BYTES
		players_layout, _ := sim.players_layout_of(type_info_of(State), PLAYERS)
		for &frame in driver.frames.slots {
			frame.views = make([]View_Out, max_views)
			frame.multis = make([]Multi_Out, max_multi)
			frame.data = make([]u8, data_bytes)
			frame.members = make([]u64, players_layout.members)
		}
		roster_reset()
		pose_memory_init(&driver.poses, max_views, max_multi)
		input_sample_reset()
		view.triple_init(&driver.states)
		view.triple_init(&driver.inputs)
		view.tracker_init(&driver.tracker, tick_event_id)
		driver.tev = {
			ctx = driver,
			code = proc(ctx: rawptr, code: string) {post_text((^This_Driver)(ctx), .Lobby_Code, code)},
			fail = proc(ctx: rawptr, reason: string) {
				driver := (^This_Driver)(ctx)
				post_status(driver, .Failed, reason)
				driver.failed = true
				sync.atomic_store(&driver.stop_req, true)
			},
		}
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
		view.tracker_destroy(&driver.tracker)
		for &frame in driver.frames.slots {
			delete(frame.views)
			delete(frame.multis)
			delete(frame.data)
			delete(frame.members)
		}
		for text in driver.account do delete(text)
		sim.log_stream_end(&driver.recording.stream)
		delete(driver.recording.log)
		delete(driver.recording.snapshot)
		pose_memory_destroy(&driver.poses)
		delete(driver.scratch)
		delete(driver.req.arg)
		delete(driver.req.name)
		delete(driver.req.content)
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
		frame, fresh := view.triple_front(&(^This_Driver)(g_driver).frames)
		if frame.published == 0 do return nil, false
		return frame, fresh
	}
	api.pop = proc() -> (Message, bool) {
		if g_driver == nil do return {}, false
		return view.queue_pop(&(^This_Driver)(g_driver).queue)
	}
	api.next_event = proc(shown: u32) -> (Event_Message, bool) {
		if g_driver == nil do return {}, false
		events := &(^This_Driver)(g_driver).events
		if oldest := view.queue_peek(events); oldest == nil || oldest.tick > shown do return {}, false
		return view.queue_pop(events)
	}
	api.events_dropped = proc() -> int {
		if g_driver == nil do return 0
		return sync.atomic_load(&(^This_Driver)(g_driver).dropped)
	}
	api.send = proc(command: sim.Raw_Command) -> bool {
		if g_driver == nil do return false
		return view.queue_push(&(^This_Driver)(g_driver).commands, command)
	}
	api.result = proc() -> string {
		if g_driver == nil do return ""
		return (^This_Driver)(g_driver).result
	}
	api.state = proc() -> any {
		if g_driver == nil do return nil
		driver := (^This_Driver)(g_driver)
		state, _ := view.triple_front(&driver.states)
		return state^
	}
	api.inputs = proc() -> any {
		if g_driver == nil do return nil
		driver := (^This_Driver)(g_driver)
		inputs, _ := view.triple_front(&driver.inputs)
		return inputs^
	}
	api.next_confirmed = proc() -> (Command_Note, bool) {
		if g_driver == nil do return {}, false
		return view.queue_pop(&(^This_Driver)(g_driver).confirmed)
	}
	api.recording = proc(snapshot, log: ^[dynamic]u8) -> (info: Recording_Info, ok: bool) {
		if g_driver == nil do return
		recording := &(^This_Driver)(g_driver).recording
		sync.guard(&recording.mu)
		if recording.snapshot == nil do return
		append(snapshot, ..recording.snapshot)
		append(log, ..recording.log[:])
		return {recording.from, recording.last, u32(recording.check[0]), recording.check[1]}, true
	}
}

// The session thread, a verified tick (dev UI builds): the recording starts at the first verified tick whose
// state the ring saved (a snapshot of it) and appends every verified tick after it.
@(private)
record_tick :: proc(
	driver: ^Driver($State, $Input, $World, $PLAYERS, $View, $MultiView),
	simulation: ^sim.Sim(State, Input, World, PLAYERS),
	tick: u32,
) {
	recording := &driver.recording
	client := driver.client
	sync.guard(&recording.mu)
	if recording.snapshot == nil {
		if sim.state_at(simulation, tick) == nil do return
		recording.snapshot = sim.snapshot_encode(simulation, tick)
		recording.from, recording.last = tick, tick
		compat := driver.glue.compat != 0 ? driver.glue.compat : sim.compat_of(driver.game, driver.req.content)
		header := sim.Log_Header {
			seed       = simulation.seed,
			content    = simulation.content_hash,
			compat     = compat,
			players    = PLAYERS,
			input_size = size_of(Input),
		}
		sim.log_stream_begin(&recording.stream, sim.log_sink_memory(&recording.log), header)
		return
	}
	if tick != recording.last + 1 do return // verified ticks come in order
	sim.log_stream_tick(&recording.stream, &client.fin[tick % netcode.FIN_RING])
	recording.last = tick
	if count := len(client.checksums); count > 0 && client.checksums[count - 1][0] > u64(recording.from) {
		recording.check = client.checksums[count - 1]
	}
}

// The Input panel's view of the newest frame (session thread, while want_state).
@(private)
fill_inputs_view :: proc(
	out: ^Inputs_View($Input, $PLAYERS),
	client: ^netcode.Client($State, Input, $World, PLAYERS),
	info: netcode.Frame_Info,
	holders: []sim.Player,
) {
	out^ = {}
	out.predicted_tick, out.verified_tick = info.tick, info.verified
	if client.slot >= 0 {
		if info.tick <= info.verified {
			out.own = client.fin[info.tick % netcode.FIN_RING].input[client.slot]
		} else {
			out.own = client.pred_inputs[info.tick % netcode.PRED_RING].input[client.slot]
		}
	}
	if info.verified == 0 do return
	verified := &client.fin[info.verified % netcode.FIN_RING]
	for &slot, i in out.slots {
		slot = {
			player   = i < len(holders) ? sim.player_key(holders[i]) : 0,
			present  = i in verified.present,
			replaced = i in verified.replaced,
			input    = verified.input[i],
		}
	}
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
post :: proc(driver: ^Driver($State, $Input, $World, $PLAYERS, $View, $MultiView), message: Message) {
	// 64 slots for a handful of messages per session: full only when the main thread stopped reading for good
	_ = view.queue_push(&driver.queue, message)
}

@(private)
post_text :: proc(
	driver: ^Driver($State, $Input, $World, $PLAYERS, $View, $MultiView),
	kind: type_of(Message{}.kind),
	text: string,
) {
	message := Message {
		kind = kind,
	}
	message.len = u8(copy(message.text[:], text))
	post(driver, message)
}

@(private)
post_status :: proc(
	driver: ^Driver($State, $Input, $World, $PLAYERS, $View, $MultiView),
	status: Status_Kind,
	detail: string,
) {
	message := Message {
		kind   = .Status,
		status = status,
	}
	message.len = u8(copy(message.text[:], detail))
	post(driver, message)
}

// Posts the tracker's output: each event's sim.Position fields converted into view units first (Glue.event_pos).
@(private)
flush_events :: proc(driver: ^Driver($State, $Input, $World, $PLAYERS, $View, $MultiView), world: ^World) {
	for tracked in driver.tracker.out {
		raw := tracked.event.raw
		if driver.glue.event_pos != nil && int(raw.kind) < len(api.events) {
			for offset in api.events[raw.kind].positions {
				position := (^sim.Position)(&raw.data[offset])
				position^ = driver.glue.event_pos(position^, world)
			}
		}
		message := Event_Message {
			action = tracked.action,
			tick   = tracked.event.tick,
			event  = raw,
		}
		// full: the main thread is stalled; dropping an event beats blocking the sim (counted)
		if !view.queue_push(&driver.events, message) do sync.atomic_add(&driver.dropped, 1)
	}
	clear(&driver.tracker.out)
}

// Feeds one simulated tick's events to the tracker, numbering repeats of a kind and subject within the tick.
@(private)
track_tick :: proc(
	driver: ^Driver($State, $Input, $World, $PLAYERS, $View, $MultiView),
	tick: u32,
	events: []sim.Raw_Event,
) {
	view.tracker_begin_tick(&driver.tracker, tick)
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
		view.tracker_event(&driver.tracker, event)
	}
	view.tracker_end_tick(&driver.tracker, tick)
}

@(private)
driver_hooks :: proc(
	driver: ^Driver($State, $Input, $World, $PLAYERS, $View, $MultiView),
) -> netcode.Hooks(State, Input, World, PLAYERS) {
	This_Driver :: Driver(State, Input, World, PLAYERS, View, MultiView)
	return {
		user = driver,
		sample = proc(user: rawptr, slot: int, tick: u32, state: ^State) -> Input {
			driver := (^This_Driver)(user)
			if driver.req.scripted && driver.glue.scripted_input != nil {
				return driver.glue.scripted_input(driver.req.seed, slot, tick, state)
			}
			input: Input
			input_sample_take(([^]u8)(&input)[:size_of(Input)])
			return input
		},
		// Commands sent from GDScript (send_command), in order; what the client can't take yet stays queued.
		commands = proc(user: rawptr, slot: int, tick: u32, state: ^State, out: ^sim.Command_Out) {
			driver := (^This_Driver)(user)
			if driver.req.scripted {
				if driver.glue.scripted_commands != nil {
					driver.glue.scripted_commands(driver.req.seed, slot, tick, state, out)
				}
				return
			}
			for len(out.list) < out.cap {
				command := view.queue_pop(&driver.commands) or_break
				sim.push_command(out, command)
			}
		},
		frame = proc(user: rawptr, simulation: ^sim.Sim(State, Input, World, PLAYERS), info: netcode.Frame_Info) {
			driver := (^This_Driver)(user)
			for tick in info.resim_from ..= info.tick do track_tick(driver, tick, sim.events_at(simulation, tick))
			flush_events(driver, simulation.world)
			current := sim.state_at(simulation, info.tick)
			if current == nil do current = &simulation.state
			out := view.triple_back(&driver.frames)
			out.n_views, out.n_multis, out.n_data, out.n_datas, out.data_pushed, out.dropped = 0, 0, 0, 0, 0, 0
			client := driver.client
			driver.published += 1
			out.published = driver.published
			out.tick = info.tick
			out.verified = info.verified
			out.tick_hz = u32(driver.game.tick_hz)
			out.due_us = i64(client.next_tick_us - client.tm.tick_us)
			members, slots := sim.players_of(simulation, current)
			local := client.slot >= 0 ? slots[client.slot] : {}
			out.local_player = sim.player_key(local)
			out.slots = {}
			for holder, slot in slots do out.slots[slot] = sim.player_key(holder)
			out.n_members = 0
			for member, index in members {
				if member.id != 0 && out.n_members < len(out.members) {
					out.members[out.n_members] = sim.player_key({u16(index), member.id})
					out.n_members += 1
				}
			}
			roster_copy(client.roster[:], &driver.roster, client.roster_changes)
			out.net = {
				rtt_ms      = f32(netcode.client_rtt_ms(client)),
				delay       = client.delay,
				rollbacks   = i32(client.rollbacks),
				resim_ticks = i32(client.resim_ticks),
				depth_max   = i32(client.depth_max),
				stalls      = i32(client.stall_ticks),
				replaced    = i32(client.own_replaced),
				steps       = {i32(client.steps[.Verified]), i32(client.steps[.Resim]), i32(client.steps[.Predicted])},
				step_us     = {client.step_us[.Verified], client.step_us[.Resim], client.step_us[.Predicted]},
				last_msg_us = client.last_msg_us,
				bytes_in    = i64(client.ch.stats.bytes_recv),
				bytes_out   = i64(client.ch.stats.bytes_sent),
				desyncs     = i32(client.desyncs),
			}
			pose_memory_begin(&driver.poses, info.resim_from < info.tick)
			frame := Frame(State, World, View, MultiView) {
				state        = current,
				world        = simulation.world,
				tick         = info.tick,
				local_player = local,
				local_slot   = client.slot,
				out          = out,
				poses        = &driver.poses,
			}
			driver.glue.fill_frame(&frame)
			view.triple_publish(&driver.frames)
			if sync.atomic_load(&want_state) {
				view.triple_back(&driver.states)^ = current^
				view.triple_publish(&driver.states)
				fill_inputs_view(view.triple_back(&driver.inputs), client, info, slots[:])
				view.triple_publish(&driver.inputs)
			}
		},
		verified = proc(
			user: rawptr,
			simulation: ^sim.Sim(State, Input, World, PLAYERS),
			tick: u32,
			events: []sim.Raw_Event,
		) {
			driver := (^This_Driver)(user)
			track_tick(driver, tick, events)
			view.tracker_verified(&driver.tracker, tick)
			flush_events(driver, simulation.world)
			when DEVUI {
				inputs := &driver.client.fin[tick % netcode.FIN_RING]
				for command in inputs.commands[:inputs.command_count] {
					_ = view.queue_push(&driver.confirmed, Command_Note{tick, command})
				}
				record_tick(driver, simulation, tick)
			}
		},
		status = proc(user: rawptr, status: netcode.Status, detail: string) {
			driver := (^This_Driver)(user)
			if driver.failed do return // the transport's failure is the session's last word
			post_status(driver, Status_Kind(status), detail)
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
}

// How long a stopping session may say goodbye (peers that don't answer: the relay's 3 s End timeout), and the
// cap when a new session waits for it (a reachable peer acks in one round trip; the rest time out).
GOODBYE_US :: 3_000_000
HURRY_US :: 1_000_000

@(private)
driver_run :: proc(driver: ^Driver($State, $Input, $World, $PLAYERS, $View, $MultiView)) {
	context.allocator = driver.alloc // (the temp allocator stays this thread's own)
	set_realtime_thread(driver.game.tick_hz)
	session_power_begin()
	if !driver_open(driver) {
		driver_close(driver)
		session_power_end() // before finished: the next session's thread may begin its own right after
		sync.atomic_store(&driver.finished, true)
		return
	}
	for {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD() // this thread's temp data lives one iteration
		now := netcode.now_us()
		if driver.uses_tp && transport.pump != nil do transport.pump(transport.user, &driver.tev)
		if len(driver.nets) > 0 && sync.atomic_load(&netsim_req.gen) != driver.net_gen {
			sync.mutex_lock(&netsim_req.mu)
			for dev_link in driver.nets do dev_link_set(dev_link, netsim_req.set)
			driver.net_gen = netsim_req.gen
			sync.mutex_unlock(&netsim_req.mu)
		}
		if sync.atomic_load(&driver.stop_req) && !driver.stopping {
			driver.stopping = true
			driver.stop_at = now
			if driver.host != nil do netcode.host_stop(driver.host, now)
			else do netcode.client_stop(driver.client, now)
		}
		wake: i64
		if driver.host != nil {
			wake = netcode.host_step(driver.host, now)
			if netcode.host_finished(driver.host) do break
		} else {
			wake = netcode.client_step(driver.client, now)
			if driver.client.status == .Failed || driver.client.status == .Disconnected do break
		}
		goodbye: i64 = sync.atomic_load(&driver.hurry) ? HURRY_US : GOODBYE_US
		if driver.stopping && now - driver.stop_at > goodbye do break
		if driver.uses_tp do wake = min(wake, now + 4_000)
		netcode.sleep_until(wake)
	}
	driver.result = strings.clone(netcode.client_json(netcode.client_result(driver.client, context.temp_allocator)))
	post(driver, Message{kind = .Result})
	driver_close(driver)
	session_power_end()
	sync.atomic_store(&driver.finished, true)
}

@(private)
driver_open :: proc(driver: ^Driver($State, $Input, $World, $PLAYERS, $View, $MultiView)) -> bool {
	request := &driver.req
	game := driver.game
	hooks := driver_hooks(driver)
	host_config := netcode.Host_Config {
		desync_detail = DEVUI, // typed desync reports where the dev UI is (every build for now)
		player_name   = request.name,
		seed          = request.seed,
		ticks         = request.ticks,
		compat        = driver.glue.compat,
		content       = request.content,
		name          = "host",
		quiet         = true,
	}
	client_config := netcode.Client_Config {
		player_name = request.name,
		slot        = -1,
		token       = request.token,
		compat      = driver.glue.compat,
		content     = request.content,
		name        = "client",
		quiet       = true,
	}
	switch request.mode {
	case .Single:
		if request.bench > 0 && driver.glue.bench != nil {
			// The same game, with the benchmark state prepared after init (this process is the only peer).
			g_bench_count = request.bench
			driver.bench = game^
			driver.bench.init = proc(state: ^State, world: ^World, seed: u64) {
				game := (^sim.Game(State, Input, World, PLAYERS))(g_game)
				glue := (^Glue(State, Input, World, View, MultiView))(g_glue)
				game.init(state, world, seed)
				glue.bench(state, world, g_bench_count)
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
		post_text(driver, .Lobby_Code, fmt.tprintf("%d", netcode.udp_bound_port(&link)))
		netcode.host_add_link(driver.host, wrap_link(driver, link))
	case .Host_Online:
		driver.uses_tp = true
		link, ok := transport.open_host(transport.user, session_compat(driver), &driver.tev)
		if !ok {
			// the transport's fail hook may have posted the real reason already
			if !driver.failed do post_status(driver, .Failed, fmt.tprintf("%s: cannot host", transport.name))
			return false
		}
		if transport.account != nil {
			if account, has := transport.account(transport.user); has {
				driver.account = {strings.clone(account.platform), strings.clone(account.id)}
				host_config.account = {driver.account[0], driver.account[1]}
			}
		}
		driver.host = netcode.host_create(game, host_config, hooks)
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
	case .Join_Online:
		driver.uses_tp = true
		link, ok := transport.open_join(transport.user, request.arg, session_compat(driver), &driver.tev)
		if !ok {
			if !driver.failed {
				post_status(driver, .Failed, fmt.tprintf("%s: cannot join %q", transport.name, request.arg))
			}
			return false
		}
		driver.client = netcode.client_create(game, client_config, wrap_link(driver, link), hooks)
	}
	if driver.host != nil do driver.client = driver.host.client
	return true
}

// The session's build id, as the relay computes it (the glue's, else derived from the game and the level).
@(private)
session_compat :: proc(driver: ^Driver($State, $Input, $World, $PLAYERS, $View, $MultiView)) -> u64 {
	if driver.glue.compat != 0 do return driver.glue.compat
	return sim.compat_of(driver.game, driver.req.content)
}

@(private)
driver_close :: proc(driver: ^Driver($State, $Input, $World, $PLAYERS, $View, $MultiView)) {
	if driver.host != nil {
		netcode.host_destroy(driver.host)
	} else if driver.client != nil {
		netcode.client_destroy(driver.client)
	}
	driver.host, driver.client = nil, nil
	if driver.uses_tp && transport.close != nil do transport.close(transport.user)
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
