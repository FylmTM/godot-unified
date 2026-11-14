// UnifiedSession: the GDScript-facing session node (contract v0, src/godot_host/SPEC.md).
package godot_host

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:sim"
import "unified:view"

Session_Node :: struct {
	using hdr:   gd.Instance_Header,
	view_root:   gd.Node, // a Node3D or Node2D (any Node): views are spawned as its children
	root_id:     u64,
	root_2d:     bool, // the last view_root set is a Node2D: event positions are Vector2s
	seed:        i64,
	ticks:       i64,
	name:        string,
	status:      Status_Kind,
	detail:      string,
	args:        Args,
	args_read:   bool,
	frame:       ^Frame, // newest frame taken this process step (valid until the next one)
	last_tick:   u32,
	quit_at_end: bool,
	sync_us:     f32,
	pending:     Start, // a start that waits for the previous session's goodbye (has_pending)
	has_pending: bool,
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
		"view_root",
		proc(session: ^Session_Node) -> gd.Node {
			if !alive(session.root_id) do return {}
			return session.view_root
		},
		proc(session: ^Session_Node, node: gd.Node) {
			session.view_root = node
			session.root_id = node.ptr != nil ? gdi.object_get_instance_id(node.ptr) : 0
			// kept while view_root is cleared: a game's events stay Vector2s (2D) or Vector3s between scenes
			if node.ptr != nil do session.root_2d = gd.object_cast(gd.Node2D, node, "Node2D").ptr != nil
			views_root_changed()
		},
	)
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
	gd.bind_method(class, "press_action", proc(session: ^Session_Node, action: string) {
		button := button_index(action)
		if button < 0 {
			gd.print_warning(fmt.tprintf("unified: press_action(%q): not one of the game's button actions", action))
			return
		}
		press_button(button)
	}, {"action"})
	gd.bind_method(
		class,
		"send_command",
		proc(session: ^Session_Node, name: gd.StringName, args: gd.Dictionary) -> bool {
			name, args := name, args
			return send_command(gd.string_name_to_odin(&name), &args)
		},
		{"name", "args"},
	)
	gd.bind_method(class, "set_input_vector", proc(session: ^Session_Node, index: i64, vector: gd.Vector3) {
		set_input_vector(int(index), {vector.x, vector.y, vector.z})
	}, {"index", "vector"})
	gd.bind_method(class, "set_input_vector_2d", proc(session: ^Session_Node, index: i64, vector: gd.Vector2) {
		set_input_vector(int(index), {vector.x, vector.y, 0})
	}, {"index", "vector"})
	gd.bind_method(class, "set_player_name", proc(session: ^Session_Node, name: string) {
		delete(session.name)
		session.name = strings.clone(name)
	}, {"name"})
	gd.bind_method(class, "hud", session_hud)
	gd.bind_method(class, "constants", session_constants)
	gd.bind_method(class, "get_status", proc(session: ^Session_Node) -> string {return STATUS_NAMES[session.status]})
	gd.bind_method(class, "is_running", proc(session: ^Session_Node) -> bool {return api.installed && api.running()})
	gd.bind_method(class, "get_tick", proc(session: ^Session_Node) -> i64 {return i64(session.last_tick)})
	gd.bind_method(class, "toggle_devui", proc(session: ^Session_Node) {dev_toggle()})
	gd.bind_method(class, "is_devui_visible", proc(session: ^Session_Node) -> bool {return dev_visible()})
	gd.bind_signal(class, "status_changed", {"status", string}, {"detail", string})
	gd.bind_signal(class, "lobby_code", {"code", string})
	gd.bind_signal(class, "desync", {"tick", i64}, {"detail", string})
	gd.bind_signal(class, "sim_event", {"event", gd.StringName}, {"state", i64}, {"data", gd.Dictionary})
	for name, state in EVENT_STATE_NAMES do gd.bind_constant(class, "EventState", name, i64(state))
}

@(private)
node_of :: proc(session: ^Session_Node) -> gd.Node {
	return gd.cast_to(gd.Node, session.obj)
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
		session.args = parse_args()
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
		session_start(session, {mode = .Host_Direct, port = session.args.host_port, scripted = session.args.scripted})
	case session.args.join != "":
		session_start(session, {mode = .Join_Direct, arg = session.args.join, scripted = session.args.scripted})
	case session.args.online:
		session_start(session, {mode = .Host_Online, scripted = session.args.scripted})
	case session.args.join_code != "":
		session_start(session, {mode = .Join_Online, arg = session.args.join_code, scripted = session.args.scripted})
	}
	session.args.autostart, session.args.host_port, session.args.join, session.args.online, session.args.join_code =
		false, 0, "", false, ""
}

@(private)
session_start :: proc(session: ^Session_Node, request: Start) -> bool {
	if !api.installed {
		emit_status(session, .Failed, "no game installed in this extension")
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
	api.wait() // a finished session's thread
	request := request
	if request.mode == .Single do request.bench = session.args.bench
	request.local = session.args.local_net
	request.seed = u64(session.seed)
	request.ticks = u32(max(session.ticks, 0))
	request.name = session.name
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
		api.stop()
		api.wait()
	}
	session.frame = nil
}

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
	sample_input(dev_wants_keyboard())
	if transport != nil && transport.main_frame != nil && api.running() do transport.main_frame(transport.user)
	started := time.tick_now()
	// the newest frame: views first, then the events of the ticks it covers
	fresh := false
	if api.installed {
		session.frame, fresh = api.front()
	}
	now := time.tick_now()
	if session.frame != nil {
		frame := session.frame
		session.last_tick = frame.tick
		tick_us := i64(1_000_000 / max(frame.tick_hz, 1))
		alpha := view.alpha(now._nsec / 1000, frame.due_us, tick_us)
		root := alive(session.root_id) ? session.view_root : {}
		views_sync(root, frame, fresh, alpha, f32(dt))
	}
	drain_messages(session)
	start_pending(session)
	session.sync_us = f32(time.duration_microseconds(time.tick_since(started)))
	sync.atomic_store(&want_state, dev_visible())
	dev_frame(session, dt)
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
		case .Event:
			route_event(session, message)
		case .Desync:
			fmt.printfln("unified: desync at tick %d: %s", message.tick, text)
			dev_log(message.tick, "desync: %s", text)
			gd.emit_signal(session.obj, gd.sn("desync"), i64(message.tick), text)
		case .Result:
			fmt.printfln("unified: result %s", api.result())
			if session.quit_at_end do gd.SceneTree_quit(gd.Node_get_tree(node_of(session)), 0)
		}
	}
}

// An event in one of its states (EVENT_EMITTED, then EVENT_CONFIRMED or EVENT_CANCELLED), with its fields as a
// Dictionary (events.odin) plus `tick`: to the subject's view (_sim_event(event, state, data)), then to the
// sim_event signal, in the order the ticks emitted them.
@(private)
route_event :: proc(session: ^Session_Node, message: Message) {
	raw := message.event
	if int(raw.kind) >= len(api.events) do return // another build's event: never from this game's sim
	layout := &api.events[raw.kind]
	data := event_dictionary(layout, raw.data[:raw.size], session.root_2d)
	defer gd.Dictionary_destroy(&data)
	gd.dict_set(&data, "tick", i64(message.tick))
	state := i64(message.action)
	views_event(layout, &raw, state, &data)
	gd.emit_signal(session.obj, gd.sn("sim_event"), gd.sn(layout.name)^, state, data)
	if message.action == .Confirmed {
		player, entity := event_subject(layout, raw.data[:raw.size])
		dev_log(
			message.tick,
			"%s player %d entity %d",
			layout.name,
			i32(player) if player != u32(sim.NO_PLAYER) else -1,
			entity,
		)
	}
}

@(private)
session_hud :: proc(session: ^Session_Node) -> gd.Dictionary {
	dict := gd.dict_new()
	// before the first frame the game fills every contract key with its empty value
	if api.installed && api.hud != nil do api.hud(session.frame, &dict)
	return dict
}

// The game's constants for scripts (Glue.constants) plus `tick_hz`.
@(private)
session_constants :: proc(session: ^Session_Node) -> gd.Dictionary {
	dict := gd.dict_new()
	if !api.installed do return dict
	gd.dict_set(&dict, "tick_hz", i64(api.tick_hz))
	if api.constants != nil do api.constants(&dict)
	return dict
}

// ---- command line (user args after `--`)

@(private)
parse_args :: proc() -> (args: Args) {
	list := gd.OS_get_cmdline_user_args(gd.OS_singleton())
	defer gd.PackedStringArray_destroy(&list)
	count := int(gd.PackedStringArray_size(&list))
	user_args := make([]string, count, context.temp_allocator)
	for i in 0 ..< count {
		user_args[i] = gd.string_to_odin(cast(^gd.String)gdi.packed_string_array_operator_index(&list, i64(i)))
	}
	next :: proc(user_args: []string, index: ^int) -> string {
		index^ += 1
		return index^ < len(user_args) ? user_args[index^] : ""
	}
	for i := 0; i < len(user_args); i += 1 {
		switch user_args[i] {
		case "--autostart":
			args.autostart = true
		case "--scripted":
			args.scripted = true
		case "--quit-at-end":
			args.quit = true
		case "--devui":
			args.devui = true
		case "--ticks":
			args.ticks, _ = strconv.parse_int(next(user_args, &i))
		case "--seed":
			seed, _ := strconv.parse_i64(next(user_args, &i))
			args.seed = seed
		case "--join":
			args.join = strings.clone(next(user_args, &i))
		case "--bench":
			args.bench, _ = strconv.parse_int(next(user_args, &i))
		case "--host-online":
			args.online = true
		case "--join-code":
			args.join_code = strings.clone(next(user_args, &i))
		case "--lag":
			args.lag_ms, _ = strconv.parse_int(next(user_args, &i))
		case "--host-port":
			args.host_port, _ = strconv.parse_int(next(user_args, &i))
		case "--local-net":
			args.local_net = true
		}
	}
	return
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
