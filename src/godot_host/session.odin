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
	root_2d:     bool, // view_root is a Node2D: verified events also go out as sim_event_2d
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
	scripted:  bool, // scripted input (the offline binary's), for hash checks
	ticks:     int, // session length (0: endless)
	seed:      i64,
	quit:      bool, // quit when the session ends, printing its result
	devui:     bool, // dev UI shown at start
	lag_ms:    int, // netsim on remote links: this one-way latency, a quarter of it as jitter, 1% loss
	bench:     int, // single player sessions hold this many enemies (Glue.bench)
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
		init = proc(i: rawptr) {
			s := (^Session_Node)(i)
			s.seed = 1
			s.name = strings.clone("player")
		},
		fini = proc(i: rawptr) {
			s := (^Session_Node)(i)
			if active == s {
				session_end(s)
				active = nil
			}
			clear_pending(s)
			delete(s.name)
			delete(s.detail)
		},
		ready = proc(i: rawptr) {session_ready((^Session_Node)(i))},
		process = proc(i: rawptr, dt: f64) {session_process((^Session_Node)(i), dt)},
		// While the dev UI wants the mouse or keyboard, the game's GUI and _unhandled_input don't get them.
		input = proc(i: rawptr, ev: gd.InputEvent) {
			if !dev_wants_mouse() && !dev_wants_keyboard() do return
			is_key := gd.object_cast(gd.InputEventKey, ev, "InputEventKey").ptr != nil
			if (is_key && dev_wants_keyboard()) || (!is_key && dev_wants_mouse()) {
				gd.Viewport_set_input_as_handled(gd.Node_get_viewport(node_of((^Session_Node)(i))))
			}
		},
		notification = proc(i: rawptr, what: i32) {
			s := (^Session_Node)(i)
			switch what {
			case gd.Node_NOTIFICATION_EXIT_TREE:
				if active == s {
					session_end(s)
					views_clear()
					dev_shutdown()
					active = nil
				}
			case gd.Object_NOTIFICATION_EXTENSION_RELOADED:
				// New code, same Godot object: Odin state is fresh; Godot restored the saved properties.
				if !is_editor() && gd.Node_is_inside_tree(node_of(s)) do session_ready(s)
			}
		},
	}
	c := &session_class
	gd.register_class(c)
	gd.bind_property(
		c,
		"seed",
		proc(s: ^Session_Node) -> i64 {return s.seed},
		proc(s: ^Session_Node, v: i64) {s.seed = v},
	)
	gd.bind_property(
		c,
		"ticks",
		proc(s: ^Session_Node) -> i64 {return s.ticks},
		proc(s: ^Session_Node, v: i64) {s.ticks = v},
	)
	gd.bind_property(c, "view_root", proc(s: ^Session_Node) -> gd.Node {
			if !alive(s.root_id) do return {}
			return s.view_root
		}, proc(s: ^Session_Node, v: gd.Node) {
			s.view_root = v
			s.root_id = v.ptr != nil ? gdi.object_get_instance_id(v.ptr) : 0
			s.root_2d = v.ptr != nil && gd.object_cast(gd.Node2D, v, "Node2D").ptr != nil
			views_root_changed()
		})
	gd.bind_method(c, "start_single", proc(s: ^Session_Node) -> bool {return session_start(s, {mode = .Single})})
	gd.bind_method(c, "host_online", proc(s: ^Session_Node) -> bool {return session_start(s, {mode = .Host_Online})})
	gd.bind_method(c, "host_direct", proc(s: ^Session_Node, port: i64) -> bool {
		return session_start(s, {mode = .Host_Direct, port = int(port)})
	}, {"port"})
	gd.bind_method(c, "join_online", proc(s: ^Session_Node, code: string) -> bool {
		return session_start(s, {mode = .Join_Online, arg = code})
	}, {"code"})
	gd.bind_method(c, "join_direct", proc(s: ^Session_Node, address: string) -> bool {
		return session_start(s, {mode = .Join_Direct, arg = address})
	}, {"address"})
	gd.bind_method(
		c,
		"leave",
		proc(s: ^Session_Node) {
			if s.has_pending { 	// the waiting session never started
				clear_pending(s)
				emit_status(s, .Disconnected, "left")
			}
			if api.installed do api.stop()
		},
	)
	gd.bind_method(c, "press_action", proc(s: ^Session_Node, action: string) {
		i := button_index(action)
		if i < 0 {
			gd.print_warning(fmt.tprintf("unified: press_action(%q): not one of the game's button actions", action))
			return
		}
		press_button(i)
	}, {"action"})
	gd.bind_method(c, "send_command", proc(s: ^Session_Node, name: gd.StringName, args: gd.Dictionary) -> bool {
		name, args := name, args
		return send_command(gd.string_name_to_odin(&name), &args)
	}, {"name", "args"})
	gd.bind_method(c, "set_input_vector", proc(s: ^Session_Node, index: i64, v: gd.Vector3) {
		set_input_vector(int(index), {v.x, v.y, v.z})
	}, {"index", "vector"})
	gd.bind_method(c, "set_input_vector_2d", proc(s: ^Session_Node, index: i64, v: gd.Vector2) {
		set_input_vector(int(index), {v.x, v.y, 0})
	}, {"index", "vector"})
	gd.bind_method(c, "set_player_name", proc(s: ^Session_Node, name: string) {
		delete(s.name)
		s.name = strings.clone(name)
	}, {"name"})
	gd.bind_method(c, "hud", session_hud)
	gd.bind_method(c, "constants", session_constants)
	gd.bind_method(c, "get_status", proc(s: ^Session_Node) -> string {return STATUS_NAMES[s.status]})
	gd.bind_method(c, "is_running", proc(s: ^Session_Node) -> bool {return api.installed && api.running()})
	gd.bind_method(c, "get_tick", proc(s: ^Session_Node) -> i64 {return i64(s.last_tick)})
	gd.bind_method(c, "toggle_devui", proc(s: ^Session_Node) {dev_toggle()})
	gd.bind_method(c, "is_devui_visible", proc(s: ^Session_Node) -> bool {return dev_visible()})
	gd.bind_signal(c, "status_changed", {"status", string}, {"detail", string})
	gd.bind_signal(c, "lobby_code", {"code", string})
	gd.bind_signal(
		c,
		"sim_event",
		{"kind", gd.StringName},
		{"tick", i64},
		{"entity", i64},
		{"position", gd.Vector3},
		{"value", f64},
	)
	gd.bind_signal(
		c,
		"sim_event_2d",
		{"kind", gd.StringName},
		{"tick", i64},
		{"entity", i64},
		{"position", gd.Vector2},
		{"value", f64},
	)
}

@(private)
node_of :: proc(s: ^Session_Node) -> gd.Node {
	return gd.cast_to(gd.Node, s.obj)
}

@(private)
alive :: proc(id: u64) -> bool {
	return id != 0 && gdi.object_get_instance_from_id(id) != nil
}

@(private)
session_ready :: proc(s: ^Session_Node) {
	if is_editor() do return // the editor shows scenes; the game never runs in it
	if active != nil && active != s {
		gd.print_warning("unified: a second UnifiedSession; only the first one runs")
		return
	}
	active = s
	gd.Node_set_process_priority(node_of(s), -1000) // views are written before any other _process
	gd.Node_set_process(node_of(s), true)
	if !s.args_read {
		s.args_read = true
		s.args = parse_args()
		if s.args.seed != 0 do s.seed = s.args.seed
		if s.args.ticks != 0 do s.ticks = i64(s.args.ticks)
		s.quit_at_end = s.args.quit
		if s.args.lag_ms > 0 {
			l := f32(s.args.lag_ms)
			set_netsim({true, l, l / 4, 1})
		}
		read_app_version()
	}
	lag: Netsim_Settings
	if s.args.lag_ms > 0 do lag = {true, f32(s.args.lag_ms), f32(s.args.lag_ms) / 4, 1}
	dev_init(s.args.devui, lag)
	switch {
	case s.args.autostart:
		session_start(s, {mode = .Single, scripted = s.args.scripted})
	case s.args.host_port != 0:
		session_start(s, {mode = .Host_Direct, port = s.args.host_port, scripted = s.args.scripted})
	case s.args.join != "":
		session_start(s, {mode = .Join_Direct, arg = s.args.join, scripted = s.args.scripted})
	case s.args.online:
		session_start(s, {mode = .Host_Online, scripted = s.args.scripted})
	case s.args.join_code != "":
		session_start(s, {mode = .Join_Online, arg = s.args.join_code, scripted = s.args.scripted})
	}
	s.args.autostart, s.args.host_port, s.args.join, s.args.online, s.args.join_code = false, 0, "", false, ""
}

@(private)
session_start :: proc(s: ^Session_Node, req: Start) -> bool {
	if !api.installed {
		emit_status(s, .Failed, "no game installed in this extension")
		return false
	}
	if api.running() {
		// Leave, then Host or Join at once: the left session is still saying goodbye (<= 1 s once hurried). The
		// new one starts when it is gone (session_process); its own messages are dropped meanwhile.
		if !api.stopping() || s.has_pending {
			emit_status(s, .Failed, "a session is already running")
			return false
		}
		s.pending = req
		s.pending.arg = strings.clone(req.arg)
		s.has_pending = true
		api.hurry()
		emit_status(s, .Connecting, "")
		return true
	}
	return session_launch(s, req)
}

@(private)
session_launch :: proc(s: ^Session_Node, req: Start) -> bool {
	s.frame = nil // it points into the finished session, which wait frees
	api.wait() // a finished session's thread
	req := req
	if req.mode == .Single do req.bench = s.args.bench
	req.seed = u64(s.seed)
	req.ticks = u32(max(s.ticks, 0))
	req.name = s.name
	level: []u8
	defer delete(level)
	if api.level != "" {
		level = read_res_file(api.level)
		if len(level) == 0 {
			emit_status(s, .Failed, fmt.tprintf("cannot read the level %s", api.level))
			return false
		}
		req.content = level
	}
	ok, err := api.start(req)
	if !ok {
		emit_status(s, .Failed, err)
		return false
	}
	emit_status(s, .Connecting, "")
	return true
}

@(private)
clear_pending :: proc(s: ^Session_Node) {
	if s.has_pending do delete(s.pending.arg)
	s.pending, s.has_pending = {}, false
}

// Starts the waiting session once the previous one has finished.
@(private)
start_pending :: proc(s: ^Session_Node) {
	if !s.has_pending || api.running() do return
	req := s.pending
	s.has_pending = false
	s.pending = {}
	defer delete(req.arg)
	session_launch(s, req)
}

@(private)
session_end :: proc(s: ^Session_Node) {
	clear_pending(s)
	if api.installed {
		api.stop()
		api.wait()
	}
	s.frame = nil
}

session_shutdown_all :: proc() {
	if active != nil do session_end(active)
	if api.installed do api.wait()
	views_clear()
	dev_shutdown()
	active = nil
}

@(private)
emit_status :: proc(s: ^Session_Node, st: Status_Kind, detail: string) {
	if st == s.status && detail == s.detail do return
	s.status = st
	delete(s.detail)
	s.detail = strings.clone(detail)
	gd.emit_signal(s.obj, gd.sn("status_changed"), STATUS_NAMES[st], detail)
}

@(private)
session_process :: proc(s: ^Session_Node, dt: f64) {
	if is_editor() || active != s do return
	sample_input(dev_wants_keyboard())
	if transport != nil && transport.main_frame != nil && api.running() do transport.main_frame(transport.user)
	t0 := time.tick_now()
	// the newest frame: views first, then the events of the ticks it covers
	fresh := false
	if api.installed {
		s.frame, fresh = api.front()
	}
	now := time.tick_now()
	if s.frame != nil {
		f := s.frame
		s.last_tick = f.tick
		tick_us := i64(1_000_000 / max(f.tick_hz, 1))
		a := view.alpha(now._nsec / 1000, f.due_us, tick_us)
		root := alive(s.root_id) ? s.view_root : {}
		views_sync(root, f, fresh, a, f32(dt))
	}
	drain_messages(s)
	start_pending(s)
	s.sync_us = f32(time.duration_microseconds(time.tick_since(t0)))
	sync.atomic_store(&want_state, dev_visible())
	dev_frame(s, dt)
}

@(private)
drain_messages :: proc(s: ^Session_Node) {
	if !api.installed do return
	for {
		m, ok := api.pop()
		if !ok do break
		text := string(m.text[:m.len])
		if s.has_pending && m.kind != .Result do continue // the left session's last words; the new one is connecting
		switch m.kind {
		case .Status:
			emit_status(s, m.status, text)
		case .Lobby_Code:
			fmt.printfln("unified: lobby code %s", text)
			gd.emit_signal(s.obj, gd.sn("lobby_code"), text)
		case .Event:
			route_event(s, m)
		case .Result:
			fmt.printfln("unified: result %s", api.result())
			if s.quit_at_end do gd.SceneTree_quit(gd.Node_get_tree(node_of(s)), 0)
		}
	}
}

@(private)
event_name :: proc(kind: u16) -> string {
	if int(kind) < len(api.event_names) do return api.event_names[kind]
	return fmt.tprintf("event_%d", kind)
}

@(private)
route_event :: proc(s: ^Session_Node, m: Message) {
	e := m.event
	name := event_name(e.kind)
	pos := gd.Vector3{e.pos.x, e.pos.y, e.pos.z}
	if m.action == .Confirm {
		// player events carry the slot as their entity (UI: slot colours, "is it me")
		entity := e.slot != sim.NO_SLOT ? i64(e.slot) : i64(e.entity)
		gd.emit_signal(s.obj, gd.sn("sim_event"), gd.sn(name)^, i64(m.tick), entity, pos, f64(e.value))
		if s.root_2d && alive(s.root_id) {
			pos2 := gd.Vector2{e.pos.x, e.pos.y}
			gd.emit_signal(s.obj, gd.sn("sim_event_2d"), gd.sn(name)^, i64(m.tick), entity, pos2, f64(e.value))
		}
		dev_log(
			m.tick,
			"%s entity %d slot %d value %.2f",
			name,
			e.entity,
			i32(e.slot) if e.slot != 0xFF else -1,
			e.value,
		)
		return
	}
	verified := s.frame != nil ? s.frame.verified : 0
	views_event(e, name, m.tick, m.action == .Cancel, m.tick > verified)
}

@(private)
session_hud :: proc(s: ^Session_Node) -> gd.Dictionary {
	d := gd.dict_new()
	// before the first frame the game fills every contract key with its empty value
	if api.installed && api.hud != nil do api.hud(s.frame, &d)
	return d
}

// The game's constants for scripts (Glue.constants) plus `tick_hz`.
@(private)
session_constants :: proc(s: ^Session_Node) -> gd.Dictionary {
	d := gd.dict_new()
	if !api.installed do return d
	gd.dict_set(&d, "tick_hz", i64(api.tick_hz))
	if api.constants != nil do api.constants(&d)
	return d
}

// ---- command line (user args after `--`)

@(private)
parse_args :: proc() -> (a: Args) {
	list := gd.OS_get_cmdline_user_args(gd.OS_singleton())
	defer gd.PackedStringArray_destroy(&list)
	n := int(gd.PackedStringArray_size(&list))
	strs := make([]string, n, context.temp_allocator)
	for i in 0 ..< n {
		strs[i] = gd.string_to_odin(cast(^gd.String)gdi.packed_string_array_operator_index(&list, i64(i)))
	}
	next :: proc(strs: []string, i: ^int) -> string {
		i^ += 1
		return i^ < len(strs) ? strs[i^] : ""
	}
	for i := 0; i < len(strs); i += 1 {
		switch strs[i] {
		case "--autostart":
			a.autostart = true
		case "--scripted":
			a.scripted = true
		case "--quit-at-end":
			a.quit = true
		case "--devui":
			a.devui = true
		case "--ticks":
			a.ticks, _ = strconv.parse_int(next(strs, &i))
		case "--seed":
			v, _ := strconv.parse_i64(next(strs, &i))
			a.seed = v
		case "--join":
			a.join = strings.clone(next(strs, &i))
		case "--bench":
			a.bench, _ = strconv.parse_int(next(strs, &i))
		case "--host-online":
			a.online = true
		case "--join-code":
			a.join_code = strings.clone(next(strs, &i))
		case "--lag":
			a.lag_ms, _ = strconv.parse_int(next(strs, &i))
		case "--host-port":
			a.host_port, _ = strconv.parse_int(next(strs, &i))
		}
	}
	return
}

// A file's bytes through Godot's FileAccess (res:// paths work in exported builds); empty if missing.
@(private)
read_res_file :: proc(path: string, allocator := context.allocator) -> []u8 {
	pba := gd.FileAccess_get_file_as_bytes(path)
	defer gd.PackedByteArray_destroy(&pba)
	n := gd.PackedByteArray_size(&pba)
	if n <= 0 do return nil
	out := make([]u8, n, allocator)
	copy(out, gdi.packed_byte_array_operator_index(&pba, 0)[:n])
	return out
}
