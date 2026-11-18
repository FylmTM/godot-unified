// UnifiedSession: the GDScript-facing session node (src/godot/SPEC.md).
package godot

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:netcode"
import "unified:view"

Session_Node :: struct {
	using hdr:   gd.Instance_Header,
	view_root:   gd.Node, // where scene views are spawned, as its children (once root_set; before: the session's parent)
	root_id:     u64,
	root_set:    bool, // view_root was assigned (null included: no scene views)
	synced_root: u64, // the instance id of the root the scene views live under (views_root_changed when it changes)
	seed:        i64,
	ticks:       i64,
	name:        string,
	status:      Status_Kind,
	detail:      string,
	args:        Args,
	args_read:   bool,
	frame:       ^Frame_Data, // newest frame taken this process step (valid until the next one; nil once over)
	ended:       bool, // the session's Result came: one more frame is taken (its last), then none
	over:        bool, // that last frame was shown: views keep their pose, nothing is synced until the next start
	last_tick:   u32,
	quit_at_end: bool,
	sync_us:     f32,
	pending:     Start, // a start that waits for the previous session's goodbye (has_pending)
	has_pending: bool,
	roster_seen: u32, // roster.changes when roster_changed was last emitted
	mode:        Mode, // the session started last (the dev UI: no netsim in single player; catch-up only joining)
}

Args :: struct {
	autostart: bool, // start single player at once (headless checks)
	join:      string, // join_direct this address at once
	host_port: int, // host_direct on this port at once
	local_net: bool, // direct hosting listens on 127.0.0.1 only (tool runs: no firewall prompt)
	scripted:  bool, // scripted input (the offline binary's), for hash checks
	ticks:     int, // session length (0: endless)
	seed:      i64,
	quit:      bool, // quit when the session ends, printing its result
	devui:     bool, // dev UI shown at start
	lag_ms:    int, // netsim on remote links: this one-way latency, a quarter of it as jitter, 1% loss
	bench:     int, // single player sessions hold this many entities (Glue.bench)
	online:    bool, // host_online at once
	join_code: string, // join_online this code at once
}

@(private)
session_class: gd.Class
@(private)
active: ^Session_Node

@(private)
register_session_class :: proc() {
	session_class = {
		name = "UnifiedSession",
		parent = "Node",
		size = size_of(Session_Node),
		init = proc(instance: rawptr) {
			session := (^Session_Node)(instance)
			session.seed = 1
			session.name = strings.clone("player")
		},
		fini = proc(instance: rawptr) {
			session := (^Session_Node)(instance)
			if active == session {
				session_end(session)
				active = nil
			}
			clear_pending(session)
			delete(session.name)
			delete(session.detail)
		},
		ready = proc(instance: rawptr) {session_ready((^Session_Node)(instance))},
		process = proc(instance: rawptr, dt: f64) {session_process((^Session_Node)(instance), dt)},
		notification = proc(instance: rawptr, what: i32) {
			session := (^Session_Node)(instance)
			switch what {
			case gd.Node_NOTIFICATION_EXIT_TREE:
				if active == session {
					session_end(session)
					views_clear()
					dev_shutdown()
					active = nil
				}
			case gd.Object_NOTIFICATION_EXTENSION_RELOADED:
				// New code, same Godot object: Odin state is fresh; Godot restored the saved properties.
				if !is_editor() && gd.Node_is_inside_tree(node_of(session)) do session_ready(session)
			}
		},
	}
	class := &session_class
	gd.register_class(class)
	gd.bind_property(
		class,
		"seed",
		proc(session: ^Session_Node) -> i64 {return session.seed},
		proc(session: ^Session_Node, value: i64) {session.seed = value},
	)
	gd.bind_property(
		class,
		"ticks",
		proc(session: ^Session_Node) -> i64 {return session.ticks},
		proc(session: ^Session_Node, value: i64) {session.ticks = value},
	)
	gd.bind_property(
		class,
		"game_input",
		proc(session: ^Session_Node) -> bool {return !input_sample.off},
		proc(session: ^Session_Node, on: bool) {set_game_input(on)},
	)
	gd.bind_property(class, "view_root", effective_root, proc(session: ^Session_Node, node: gd.Node) {
			session.view_root = node
			session.root_id = node.ptr != nil ? gdi.object_get_instance_id(node.ptr) : 0
			session.root_set = true
		}, .NODE_TYPE, "Node")
	gd.bind_method(
		class,
		"start_single",
		proc(session: ^Session_Node) -> bool {return session_start(session, {mode = .Single})},
	)
	gd.bind_method(
		class,
		"host_online",
		proc(session: ^Session_Node) -> bool {return session_start(session, {mode = .Host_Online})},
	)
	gd.bind_method(class, "host_direct", proc(session: ^Session_Node, port: i64) -> bool {
		return session_start(session, {mode = .Host_Direct, port = int(port)})
	}, {"port"})
	gd.bind_method(class, "join_online", proc(session: ^Session_Node, code: string) -> bool {
		return session_start(session, {mode = .Join_Online, arg = code})
	}, {"code"})
	gd.bind_method(class, "join_direct", proc(session: ^Session_Node, address: string) -> bool {
		return session_start(session, {mode = .Join_Direct, arg = address})
	}, {"address"})
	gd.bind_method(
		class,
		"leave",
		proc(session: ^Session_Node) {
			if session.has_pending { 	// the waiting session never started
				clear_pending(session)
				emit_status(session, .Disconnected, "left")
			}
			if api.installed do api.stop()
		},
	)
	gd.bind_method(
		class,
		"send_command",
		proc(session: ^Session_Node, command: gd.Object) -> bool {return send_command(command)},
		{"command"},
	)
	gd.bind_method(class, "set_input_value", proc(session: ^Session_Node, name: gd.StringName, value: gd.Variant) {
		name, value := name, value
		set_input_value(gd.string_name_to_odin(&name), input_value_of(&value))
	}, {"name", "value"})
	gd.bind_method(class, "set_player_name", proc(session: ^Session_Node, name: string) {
		delete(session.name)
		session.name = strings.clone(name)
	}, {"name"})
	gd.bind_method(class, "get_status", proc(session: ^Session_Node) -> string {return STATUS_NAMES[session.status]})
	// Players by key (sim.player_key), at the shown tick.
	gd.bind_method(class, "get_local_player", proc(session: ^Session_Node) -> i64 {
		return session.frame != nil ? i64(session.frame.local_player) : 0
	})
	gd.bind_method(class, "get_players", proc(session: ^Session_Node) -> gd.Array {
		players := gd.array_new()
		if session.frame != nil {
			for key in session.frame.slots do if key != 0 do gd.array_push(&players, i64(key))
		}
		return players
	})
	gd.bind_method(class, "get_known_players", proc(session: ^Session_Node) -> gd.Array {
		players := gd.array_new()
		if session.frame != nil {
			for key in session.frame.members[:session.frame.n_members] do gd.array_push(&players, i64(key))
		}
		return players
	})
	gd.bind_method(class, "get_player_slot", proc(session: ^Session_Node, player: i64) -> i64 {
		return i64(shown_slot(session, player))
	}, {"player"})
	gd.bind_method(class, "is_player_present", proc(session: ^Session_Node, player: i64) -> bool {
		return shown_slot(session, player) >= 0
	}, {"player"})
	gd.bind_method(class, "get_player_name", proc(session: ^Session_Node, player: i64) -> string {
		entry, ok := roster_entry(player)
		return ok ? strings.clone(netcode.text_string(&entry.name), context.temp_allocator) : ""
	}, {"player"})
	gd.bind_method(class, "get_player_platform", proc(session: ^Session_Node, player: i64) -> string {
		entry, ok := roster_entry(player)
		return ok ? strings.clone(netcode.text_string(&entry.platform), context.temp_allocator) : ""
	}, {"player"})
	gd.bind_method(class, "get_player_platform_id", proc(session: ^Session_Node, player: i64) -> string {
		entry, ok := roster_entry(player)
		return ok ? strings.clone(netcode.text_string(&entry.account), context.temp_allocator) : ""
	}, {"player"})
	gd.bind_method(class, "is_running", proc(session: ^Session_Node) -> bool {return api.installed && api.running()})
	gd.bind_method(class, "get_tick", proc(session: ^Session_Node) -> i64 {return i64(session.last_tick)})
	gd.bind_method(class, "take_sync_stats", take_sync_stats)
	gd.bind_method(class, "toggle_devui", proc(session: ^Session_Node) {dev_toggle()})
	gd.bind_method(class, "is_devui_visible", proc(session: ^Session_Node) -> bool {return dev_visible()})
	gd.bind_signal(class, "status_changed", {"status", string}, {"detail", string})
	gd.bind_signal(class, "lobby_code", {"code", string})
	gd.bind_signal(class, "desync", {"tick", i64}, {"detail", string})
	gd.bind_signal(class, "sim_event", {"event", gd.RefCounted}, {"state", i64})
	gd.bind_signal(class, "roster_changed")
	for name, state in EVENT_STATE_NAMES do gd.bind_constant(class, "EventState", name, i64(state))
}

// The slot a player (by key) holds at the shown tick (-1: absent, unknown, or no frame yet).
@(private)
shown_slot :: proc(session: ^Session_Node, player: i64) -> int {
	if session.frame == nil || player == 0 do return -1
	for key, slot in session.frame.slots do if key == u64(player) do return slot
	return -1
}

@(private)
node_of :: proc(session: ^Session_Node) -> gd.Node {
	return gd.cast_to(gd.Node, session.obj)
}

// Where scene views go: view_root once assigned (null, or a freed node: none), before that the session's parent.
@(private)
effective_root :: proc(session: ^Session_Node) -> gd.Node {
	if session.root_set do return alive(session.root_id) ? session.view_root : {}
	return gd.Node_get_parent(node_of(session))
}

@(private)
alive :: proc(id: u64) -> bool {
	return id != 0 && gdi.object_get_instance_from_id(id) != nil
}

@(private)
session_ready :: proc(session: ^Session_Node) {
	if is_editor() do return // the editor shows scenes; the game never runs in it
	if active != nil && active != session {
		gd.print_warning("unified: a second UnifiedSession; only the first one runs")
		return
	}
	active = session
	gd.Node_set_process_priority(node_of(session), -1000) // views are written before any other _process
	gd.Node_set_process(node_of(session), true)
	if !session.args_read {
		session.args_read = true
		problems: []string
		session.args, problems = parse_args()
		if len(problems) > 0 {
			for problem in problems do gd.print_error(fmt.tprintf("unified: %s", problem))
			gd.SceneTree_quit(gd.Node_get_tree(node_of(session)), 2) // like uni: a bad command line runs nothing
			return
		}
		if session.args.seed != 0 do session.seed = session.args.seed
		if session.args.ticks != 0 do session.ticks = i64(session.args.ticks)
		session.quit_at_end = session.args.quit
		if session.args.lag_ms > 0 {
			lag_ms := f32(session.args.lag_ms)
			set_netsim({true, {lag_ms, lag_ms / 4, 1}, {lag_ms, lag_ms / 4, 1}})
		}
		read_app_version()
	}
	lag: Netsim_Settings
	if session.args.lag_ms > 0 {
		lag_ms := f32(session.args.lag_ms)
		lag = {true, {lag_ms, lag_ms / 4, 1}, {lag_ms, lag_ms / 4, 1}}
	}
	dev_init(session.args.devui, lag)
	switch {
	case session.args.autostart:
		session_start(session, {mode = .Single, scripted = session.args.scripted})
	case session.args.host_port != 0:
		session_start(session, {
			mode     = .Host_Direct,
			port     = session.args.host_port,
			scripted = session.args.scripted,
		})
	case session.args.join != "":
		session_start(session, {
			mode     = .Join_Direct,
			arg      = session.args.join,
			scripted = session.args.scripted,
		})
	case session.args.online:
		session_start(session, {mode = .Host_Online, scripted = session.args.scripted})
	case session.args.join_code != "":
		session_start(session, {
			mode     = .Join_Online,
			arg      = session.args.join_code,
			scripted = session.args.scripted,
		})
	}
	delete(session.args.join) // session_start keeps its own copy
	delete(session.args.join_code)
	session.args.autostart, session.args.host_port, session.args.join, session.args.online, session.args.join_code =
		false, 0, "", false, ""
}

@(private)
session_start :: proc(session: ^Session_Node, request: Start) -> bool {
	if !api.installed {
		reason := "no game installed in this extension"
		if len(api.problems) > 0 do reason = fmt.tprintf("the game %s failed to install: %s", api.game_name, api.problems[0])
		emit_status(session, .Failed, reason)
		return false
	}
	if api.running() {
		// Leave, then Host or Join at once: the left session is still saying goodbye (<= 1 s once hurried). The
		// new one starts when it is gone (session_process); its own messages are dropped meanwhile.
		if !api.stopping() || session.has_pending {
			emit_status(session, .Failed, "a session is already running")
			return false
		}
		session.pending = request
		session.pending.arg = strings.clone(request.arg)
		session.has_pending = true
		api.hurry()
		emit_status(session, .Connecting, "")
		return true
	}
	return session_launch(session, request)
}

@(private)
session_launch :: proc(session: ^Session_Node, request: Start) -> bool {
	session.frame = nil // it points into the finished session, which wait frees
	session.ended, session.over = false, false
	api.wait() // a finished session's thread
	request := request
	if request.mode == .Single do request.bench = session.args.bench
	request.local = session.args.local_net
	request.seed = u64(session.seed)
	request.ticks = u32(max(session.ticks, 0))
	request.name = session.name
	request.token = client_token()
	level: []u8
	defer delete(level)
	if api.level != "" {
		level = read_res_file(api.level)
		if len(level) == 0 {
			emit_status(session, .Failed, fmt.tprintf("cannot read the level %s", api.level))
			return false
		}
		request.content = level
	}
	views_check_index()
	data_reset()
	session.mode = request.mode
	dev_session_started()
	ok, err := api.start(request)
	if !ok {
		emit_status(session, .Failed, err)
		return false
	}
	emit_status(session, .Connecting, "")
	return true
}

@(private)
clear_pending :: proc(session: ^Session_Node) {
	if session.has_pending do delete(session.pending.arg)
	session.pending, session.has_pending = {}, false
}

// Starts the waiting session once the previous one has finished.
@(private)
start_pending :: proc(session: ^Session_Node) {
	if !session.has_pending || api.running() do return
	request := session.pending
	session.has_pending = false
	session.pending = {}
	defer delete(request.arg)
	session_launch(session, request)
}

@(private)
session_end :: proc(session: ^Session_Node) {
	clear_pending(session)
	if api.installed {
		api.hurry() // a goodbye of at most 1 s on the main thread, not 3 (an unreachable peer)
		api.stop()
		api.wait()
	}
	session.frame = nil
	data_reset()
}

// Ends the active session, joins its thread and frees every view and the dev UI. Called when the extension
// unloads (exit or hot reload): the session thread runs this library's code, so it must be gone first.
@(private)
session_shutdown_all :: proc() {
	if active != nil do session_end(active)
	if api.installed do api.wait()
	views_clear()
	dev_shutdown()
	active = nil
}

@(private)
emit_status :: proc(session: ^Session_Node, status: Status_Kind, detail: string) {
	if status == session.status && detail == session.detail do return
	session.status = status
	delete(session.detail)
	session.detail = strings.clone(detail)
	gd.emit_signal(session.obj, gd.sn("status_changed"), STATUS_NAMES[status], detail)
}

@(private)
session_process :: proc(session: ^Session_Node, dt: f64) {
	if is_editor() || active != session do return
	dev_begin()
	input_sample_begin(dev_wants_keyboard())
	if api.installed do api.sample_input()
	if lobby != nil && lobby.main_frame != nil && api.running() do lobby.main_frame()
	started := time.tick_now()
	// the newest frame: views first, then the events of the ticks it covers
	fresh := false
	if api.installed && !session.over {
		session.frame, fresh = api.front()
		session.over = session.ended
	} else {
		session.frame = nil
	}
	now := time.tick_now()
	if session.frame != nil {
		frame := session.frame
		session.last_tick = frame.tick
		tick_us := i64(1_000_000 / max(frame.tick_hz, 1))
		alpha := view.alpha(now._nsec / 1000, frame.due_us, tick_us)
		root := effective_root(session)
		root_id := root.ptr != nil ? gdi.object_get_instance_id(root.ptr) : 0
		if root_id != session.synced_root {
			views_root_changed() // the views lived under the old root
			session.synced_root = root_id
			view_space_check(root)
		}
		views_sync(root, frame, fresh, alpha, f32(dt))
		if fresh && !session.ended do data_sync(frame) // data went back to zero at the Result
	}
	delivering := time.tick_now()
	drain_events(session)
	V.stats.delivery += time.tick_since(delivering)
	drain_messages(session)
	if changes := sync.atomic_load(&roster.changes); changes != session.roster_seen {
		session.roster_seen = changes
		gd.emit_signal(session.obj, gd.sn("roster_changed"))
	}
	start_pending(session)
	took := time.tick_since(started)
	session.sync_us = f32(time.duration_microseconds(took))
	if session.frame != nil {
		V.stats.frames += 1
		V.stats.fresh += fresh ? 1 : 0
		V.stats.total += took
		V.stats.total_max = max(V.stats.total_max, took)
	}
	sync.atomic_store(&want_state, dev_wants_state())
	dev_frame(session, dt)
}

// Delivers the queued events of the ticks the shown Frame covers (tick <= its tick), in order; newer ones wait for the
// frame that shows their tick, so an event never reaches a view before the view's tick is on screen.
@(private)
drain_events :: proc(session: ^Session_Node) {
	if !api.installed do return
	for session.frame != nil {
		event := api.next_event(session.frame.tick) or_break
		if !session.has_pending do route_event(session, event) // else: the left session's; the new one is connecting
	}
	if dropped := api.events_dropped(); dropped > 0 {
		report_once(
			"events-dropped",
			fmt.tprintf(
				"unified: %d events were dropped: the main thread stalled while the session thread queued more than it holds",
				dropped,
			),
			false,
		)
	}
}

@(private)
drain_messages :: proc(session: ^Session_Node) {
	if !api.installed do return
	for {
		message, ok := api.pop()
		if !ok do break
		text := string(message.text[:message.len])
		if session.has_pending && message.kind != .Result do continue // the left session's last words; the new one is connecting
		switch message.kind {
		case .Status:
			emit_status(session, message.status, text)
		case .Lobby_Code:
			fmt.printfln("unified: lobby code %s", text)
			gd.emit_signal(session.obj, gd.sn("lobby_code"), text)
		case .Desync:
			fmt.printfln("unified: desync at tick %d: %s", message.tick, text)
			dev_note(message.tick, fmt.tprintf("desync: %s", text))
			gd.emit_signal(session.obj, gd.sn("desync"), i64(message.tick), text)
		case .Result:
			fmt.printfln("unified: result %s", api.result())
			if !session.has_pending {
				data_reset()
				session.ended = true
			}
			if session.quit_at_end do gd.SceneTree_quit(gd.Node_get_tree(node_of(session)), 0)
		}
	}
}

// An event in one of its states (EVENT_EMITTED, then EVENT_CONFIRMED or EVENT_CANCELLED), as an object of its
// class (sim_classes.odin): to the subject's view (_sim_event(event, state)), then to the sim_event signal, in the
// order the ticks emitted them.
@(private)
route_event :: proc(session: ^Session_Node, message: Event_Message) {
	raw := message.event
	if int(raw.kind) >= len(api.events) do return // another build's event: never from this game's sim
	layout := &api.events[raw.kind]
	event := new_event_object(int(raw.kind), message.tick, message.id, raw.data[:raw.size])
	if event.ptr == nil do return // its class failed to register (an error said why)
	// the Variant holds a reference and ours goes: the event is freed with the Variant unless a script kept it
	held := gd.variant_from_any(event)
	defer gd.variant_destroy(&held)
	gd.unref(transmute(gd.RefCounted)event)
	state := i64(message.action)
	V.stats.events += 1
	views_event(layout, &raw, state, held)
	gd.emit_signal(session.obj, NAMES.sim_event, held, state)
	dev_event(message.tick, message.id, message.action, layout, raw.data[:raw.size])
}

// The main thread's view-sync cost since the last call (Sync_Stats), and starts counting anew: `frames` and
// `fresh` (frames that showed a new tick), `events` (deliveries), and in microseconds summed over the frames
// `scene_us`, `multi_build_us`, `multi_upload_us`, `delivery_us`, `total_us`, plus the slowest frame's
// `total_max_us`.
@(private)
take_sync_stats :: proc(session: ^Session_Node) -> gd.Dictionary {
	stats := V.stats
	V.stats = {}
	us :: time.duration_microseconds
	dict := gd.dict_new()
	gd.dict_set(&dict, "frames", i64(stats.frames))
	gd.dict_set(&dict, "fresh", i64(stats.fresh))
	gd.dict_set(&dict, "events", i64(stats.events))
	gd.dict_set(&dict, "scene_us", us(stats.scene))
	gd.dict_set(&dict, "multi_build_us", us(stats.multi_build))
	gd.dict_set(&dict, "multi_upload_us", us(stats.multi_upload))
	gd.dict_set(&dict, "delivery_us", us(stats.delivery))
	gd.dict_set(&dict, "total_us", us(stats.total))
	gd.dict_set(&dict, "total_max_us", us(stats.total_max))
	return dict
}

// set_input_value's value as the [3]f32 input_value returns: a Vector3, a Vector2 (z = 0), or a number or bool in x.
@(private)
input_value_of :: proc(value: ^gd.Variant) -> [3]f32 {
	#partial switch gd.variant_type(value) {
	case .VECTOR3:
		vector, _ := gd.from_variant(gd.Vector3, value)
		return {vector.x, vector.y, vector.z}
	case .VECTOR2:
		vector, _ := gd.from_variant(gd.Vector2, value)
		return {vector.x, vector.y, 0}
	case .FLOAT, .INT:
		number, _ := gd.from_variant(f64, value)
		return {f32(number), 0, 0}
	case .BOOL:
		flag, _ := gd.from_variant(bool, value)
		return {flag ? 1 : 0, 0, 0}
	}
	gd.print_error("unified: set_input_value: want a Vector3, Vector2, float, int or bool")
	return {}
}

// ---- command line (user args after `--`)

@(private)
parse_args :: proc() -> (args: Args, problems: []string) {
	list := gd.OS_get_cmdline_user_args(gd.OS_singleton())
	defer gd.PackedStringArray_destroy(&list)
	count := int(gd.PackedStringArray_size(&list))
	user_args := make([]string, count, context.temp_allocator)
	for i in 0 ..< count {
		user_args[i] = gd.string_to_odin(cast(^gd.String)gdi.packed_string_array_operator_index(&list, i64(i)))
	}
	ignored: []string
	args, problems, ignored = parse_command_line(user_args, DEVUI)
	for flag in ignored {
		gd.print_warning(fmt.tprintf("unified: %s is a dev flag; this build has no dev UI and ignores it", flag))
	}
	return
}

// The flags unified:godot reads, and whether each takes a value. Every other flag on the command line belongs to
// the game or a tool script, which share it.
@(private)
FLAGS := [?]struct {
	name:  string,
	value: bool,
	dev:   bool, // a dev flag: a build without the dev UI ignores it
} {
	{"--autostart", false, false},
	{"--host-port", true, false},
	{"--join", true, false},
	{"--host-online", false, false},
	{"--join-code", true, false},
	{"--local-net", false, false},
	{"--quit-at-end", false, false},
	{"--scripted", false, true},
	{"--ticks", true, true},
	{"--seed", true, true},
	{"--devui", false, true},
	{"--lag", true, true},
	{"--bench", true, true},
}

// Reads unified:godot's flags from the user args (after `--`; strings are cloned or temp-allocated). `problems`:
// a missing or bad value of one of its flags, or a near miss of one of its names (`--tiks`), each a line to report
// before quitting; any other flag is the game's. Without the dev UI (`dev_flags` false) the dev flags are `ignored`.
parse_command_line :: proc(
	user_args: []string,
	dev_flags: bool,
) -> (
	args: Args,
	problems: []string,
	ignored: []string,
) {
	found_problems := make([dynamic]string, context.temp_allocator)
	found_ignored := make([dynamic]string, context.temp_allocator)
	number :: proc(problems: ^[dynamic]string, flag, text: string, low, high: i64) -> i64 {
		value, ok := strconv.parse_i64(text)
		if !ok || value < low || value > high {
			append(problems, fmt.tprintf("%s wants a whole number from %d to %d, got %q", flag, low, high, text))
		}
		return value
	}
	for i := 0; i < len(user_args); i += 1 {
		arg := user_args[i]
		flag_index := -1
		for flag, k in FLAGS do if flag.name == arg do flag_index = k
		if flag_index < 0 {
			name := arg
			if eq := strings.index_byte(arg, '='); eq > 0 do name = arg[:eq]
			if !strings.has_prefix(name, "--") do continue // a value of the game's flags
			for flag in FLAGS {
				if name == flag.name {
					append(&found_problems, fmt.tprintf("%s: write %s VALUE", arg, flag.name))
				} else if near_miss(name, flag.name) {
					append(&found_problems, fmt.tprintf("unknown flag %s: did you mean %s?", arg, flag.name))
				}
			}
			continue
		}
		flag := FLAGS[flag_index]
		value := ""
		if flag.value {
			if i + 1 < len(user_args) {
				i += 1
				value = user_args[i]
			}
		}
		if flag.dev && !dev_flags {
			append(&found_ignored, flag.name)
			continue
		}
		switch flag.name {
		case "--autostart":
			args.autostart = true
		case "--scripted":
			args.scripted = true
		case "--quit-at-end":
			args.quit = true
		case "--devui":
			args.devui = true
		case "--host-online":
			args.online = true
		case "--local-net":
			args.local_net = true
		case "--ticks":
			args.ticks = int(number(&found_problems, flag.name, value, 0, 1 << 31 - 1))
		case "--seed":
			args.seed = number(&found_problems, flag.name, value, min(i64), max(i64))
		case "--bench":
			args.bench = int(number(&found_problems, flag.name, value, 0, 1 << 31 - 1))
		case "--lag":
			args.lag_ms = int(number(&found_problems, flag.name, value, 0, 10_000))
		case "--host-port":
			args.host_port = int(number(&found_problems, flag.name, value, 1, 65535))
		case "--join":
			if value == "" do append(&found_problems, "--join wants host:port")
			args.join = strings.clone(value)
		case "--join-code":
			if value == "" do append(&found_problems, "--join-code wants a code")
			args.join_code = strings.clone(value)
		}
	}
	return args, found_problems[:], found_ignored[:]
}

// Whether `name` is one edit (insert, delete, replace, or swap of neighbours) from `flag`, or two for flags of seven
// letters or more: a mistyped flag of ours, not some other flag. Flags under four letters match only exactly (the
// games' `--lan` is one edit from `--lag`).
@(private)
near_miss :: proc(name, flag: string) -> bool {
	letters := len(flag) - 2
	if letters < 4 do return false
	limit := letters >= 7 ? 2 : 1
	if abs(len(name) - len(flag)) > limit do return false
	// optimal string alignment distance, rows of at most 32 characters (flag names are short)
	if len(name) > 31 || len(flag) > 31 do return false
	rows: [3][32]int // row i (of name's prefix length i) is rows[(i + 1) % 3]
	for j in 0 ..= len(flag) do rows[1][j] = j
	for i in 1 ..= len(name) {
		before, previous, current := &rows[(i + 2) % 3], &rows[i % 3], &rows[(i + 1) % 3]
		current[0] = i
		for j in 1 ..= len(flag) {
			cost := name[i - 1] == flag[j - 1] ? 0 : 1
			current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
			if i > 1 && j > 1 && name[i - 1] == flag[j - 2] && name[i - 2] == flag[j - 1] {
				current[j] = min(current[j], before[j - 2] + 1)
			}
		}
	}
	return rows[(len(name) + 1) % 3][len(flag)] <= limit
}

// A file's bytes through Godot's FileAccess (res:// paths work in exported builds); empty if missing.
@(private)
read_res_file :: proc(path: string, allocator := context.allocator) -> []u8 {
	bytes := gd.FileAccess_get_file_as_bytes(path)
	defer gd.PackedByteArray_destroy(&bytes)
	size := gd.PackedByteArray_size(&bytes)
	if size <= 0 do return nil
	out := make([]u8, size, allocator)
	copy(out, gdi.packed_byte_array_operator_index(&bytes, 0)[:size])
	return out
}
