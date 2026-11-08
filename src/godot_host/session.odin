// UnifiedSession: the GDScript-facing session node (contract v0, spec/godot_host.md).
package godot_host

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import "unified:devui"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:sim"
import "unified:view"

Session_Node :: struct {
	using hdr:   gd.Instance_Header,
	view_root:   gd.Node3D,
	root_id:     u64,
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
			delete(s.name)
			delete(s.detail)
		},
		ready = proc(i: rawptr) {session_ready((^Session_Node)(i))},
		process = proc(i: rawptr, dt: f64) {session_process((^Session_Node)(i), dt)},
		// While the dev UI wants the mouse or keyboard, the game's GUI and _unhandled_input don't get them.
		input = proc(i: rawptr, ev: gd.InputEvent) {
			if !devui.wants_mouse() && !devui.wants_keyboard() do return
			is_key := gd.object_cast(gd.InputEventKey, ev, "InputEventKey").ptr != nil
			if (is_key && devui.wants_keyboard()) || (!is_key && devui.wants_mouse()) {
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
					devui.shutdown()
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
	gd.bind_property(c, "view_root", proc(s: ^Session_Node) -> gd.Node3D {
			if !alive(s.root_id) do return {}
			return s.view_root
		}, proc(s: ^Session_Node, v: gd.Node3D) {
			s.view_root = v
			s.root_id = v.ptr != nil ? gdi.object_get_instance_id(v.ptr) : 0
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
	gd.bind_method(c, "leave", proc(s: ^Session_Node) {if api.installed do api.stop()})
	gd.bind_method(c, "choose_levelup", proc(s: ^Session_Node, option: i64) {
		press_button(button_index(fmt.tprintf("levelup_%d", option)))
	}, {"option"})
	gd.bind_method(c, "set_player_name", proc(s: ^Session_Node, name: string) {
		delete(s.name)
		s.name = strings.clone(name)
	}, {"name"})
	gd.bind_method(c, "hud", session_hud)
	gd.bind_method(c, "get_status", proc(s: ^Session_Node) -> string {return STATUS_NAMES[s.status]})
	gd.bind_method(c, "is_running", proc(s: ^Session_Node) -> bool {return api.installed && api.running()})
	gd.bind_method(c, "get_tick", proc(s: ^Session_Node) -> i64 {return i64(s.last_tick)})
	gd.bind_method(c, "toggle_devui", proc(s: ^Session_Node) {devui.visible = !devui.visible})
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
			devui.netsim = {true, l, l / 4, 1}
			set_netsim({true, l, l / 4, 1})
		}
	}
	if !devui.is_ready() do devui.init({visible = s.args.devui})
	switch {
	case s.args.autostart:
		session_start(s, {mode = .Single, scripted = s.args.scripted})
	case s.args.host_port != 0:
		session_start(s, {mode = .Host_Direct, port = s.args.host_port, scripted = s.args.scripted})
	case s.args.join != "":
		session_start(s, {mode = .Join_Direct, arg = s.args.join, scripted = s.args.scripted})
	}
	s.args.autostart, s.args.host_port, s.args.join = false, 0, ""
}

@(private)
session_start :: proc(s: ^Session_Node, req: Start) -> bool {
	if !api.installed {
		emit_status(s, .Failed, "no game installed in this extension")
		return false
	}
	if api.running() {
		emit_status(s, .Failed, "a session is already running")
		return false
	}
	api.wait() // a finished session's thread
	req := req
	req.seed = u64(s.seed)
	req.ticks = u32(max(s.ticks, 0))
	req.name = s.name
	ok, err := api.start(req)
	if !ok {
		emit_status(s, .Failed, err)
		return false
	}
	emit_status(s, .Connecting, "")
	return true
}

@(private)
session_end :: proc(s: ^Session_Node) {
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
	devui.shutdown()
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
	sample_input(devui.wants_keyboard())
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
	s.sync_us = f32(time.duration_microseconds(time.tick_since(t0)))
	dev_frame(s, dt)
}

@(private)
drain_messages :: proc(s: ^Session_Node) {
	if !api.installed do return
	for {
		m, ok := api.pop()
		if !ok do break
		text := string(m.text[:m.len])
		switch m.kind {
		case .Status:
			emit_status(s, m.status, text)
		case .Lobby_Code:
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
		devui.log(
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
	if api.installed && api.hud != nil && s.frame != nil {
		names := []string{s.name}
		api.hud(s.frame, names, &d)
		return d
	}
	gd.dict_set(&d, "phase", "lobby")
	gd.dict_set(&d, "tick", 0)
	gd.dict_set(&d, "time_s", 0.0)
	gd.dict_set(&d, "local_slot", -1)
	players := gd.array_new()
	gd.dict_set_move(&d, "players", &players)
	return d
}

// ---- dev UI

@(private)
dev_frame :: proc(s: ^Session_Node, dt: f64) {
	want_state = devui.visible
	if devui.visible && s.frame != nil {
		f := s.frame
		devui.stat("tick", "%d  verified %d  slot %d", f.tick, f.verified, f.local_slot)
		devui.stat(
			"net",
			"rtt %.0f ms  delay %d  rollbacks %d  resim %d",
			f.net.rtt_ms,
			f.net.delay,
			f.net.rollbacks,
			f.net.resim_ticks,
		)
		devui.stat("views", "%d scene  %d bulk  sync %.0f us", f.n_scene, f.n_bulk, s.sync_us)
		devui.plot("frame ms", f32(dt * 1000), 0, 50)
		devui.plot("rtt ms", f.net.rtt_ms, 0, 300)
		if st := api.state(); st != nil do devui.inspect("predicted state (read-only)", st)
	} else if devui.visible {
		devui.stat("session", "%s", STATUS_NAMES[s.status])
	}
	devui.frame(dt)
	if devui.netsim_changed {
		devui.netsim_changed = false
		n := devui.netsim
		set_netsim({n.enabled, n.latency_ms, n.jitter_ms, n.loss_pct})
	}
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
		case "--lag":
			a.lag_ms, _ = strconv.parse_int(next(strs, &i))
		case "--host-port":
			a.host_port, _ = strconv.parse_int(next(strs, &i))
		}
	}
	return
}
