// The session driver, generic over the game (S state, I input, W world, P slots): owns the netcode host or
// client and runs it on its own thread; the netcode hooks publish Frames, events and status for the main
// thread. `install` instantiates it for one game and fills the non-generic `api` the Godot classes call.
package godot_host

import "core:fmt"
import cnet "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "unified:netcode"
import "unified:sim"
import "unified:view"

// The game-independent face of the installed driver (main thread).
Api :: struct {
	installed:   bool,
	game_name:   string,
	tick_hz:     int,
	scene_kinds: []string,
	bulk_kinds:  []string,
	actions:     Action_Map,
	event_names: []string,
	start:       proc(req: Start) -> (ok: bool, err: string),
	stop:        proc(), // ask the session to end (it keeps running until it has said goodbye)
	wait:        proc(), // join the session thread (after stop)
	running:     proc() -> bool,
	front:       proc() -> (f: ^Frame, fresh: bool),
	pop:         proc() -> (m: Message, ok: bool),
	hud:         proc(f: ^Frame, names: []string, d: rawptr),
	state:       proc() -> any, // the newest predicted state, for the inspector (while want_state)
	result:      proc() -> string, // the finished session's result JSON (after a Result message)
}

api: Api
transport: ^Transport // set by the game's extension (online play); nil: Host_Online/Join_Online fail

// The main thread asks for state copies only while the dev UI shows them.
want_state: bool

set_transport :: proc(t: ^Transport) {
	transport = t
}

// Network impairment for remote links (the dev UI's Netsim panel): the main thread publishes settings, the
// session thread applies them to every wrapped link.
Netsim_Settings :: struct {
	enabled:    bool,
	latency_ms: f32, // one way
	jitter_ms:  f32,
	loss_pct:   f32,
}

@(private)
netsim_req: struct {
	mu:  sync.Mutex,
	gen: u32,
	set: Netsim_Settings,
}

set_netsim :: proc(n: Netsim_Settings) {
	sync.mutex_lock(&netsim_req.mu)
	netsim_req.set = n
	sync.atomic_add(&netsim_req.gen, 1)
	sync.mutex_unlock(&netsim_req.mu)
}

@(private)
netsim_profile :: proc(n: Netsim_Settings) -> netcode.Profile {
	if !n.enabled do return {name = "devui"}
	return {
		name = "devui",
		latency = i64(n.latency_ms * 1000),
		jitter = i64(n.jitter_ms * 1000),
		loss = u32(n.loss_pct * 10),
	}
}

@(private)
Tick_Event :: struct {
	tick:  u32,
	nth:   u32, // among events of the same kind and entity in this tick
	event: sim.Event,
}

@(private)
tick_event_id :: proc(e: Tick_Event) -> view.Event_Id {
	return {
		tick = e.tick,
		kind = u32(e.event.kind),
		entity = u64(e.event.entity) | u64(e.event.slot) << 32,
		extra = u64(e.nth),
	}
}

Driver :: struct($S, $I, $W: typeid, $P: int) {
	game:      ^sim.Game(S, I, W, P),
	glue:      ^Glue(S, I, W),
	req:       Start,
	host:      ^netcode.Host(S, I, W, P),
	client:    ^netcode.Client(S, I, W, P), // the local player's client (the host's own in host modes)
	tev:       Transport_Events,
	uses_tp:   bool,
	thread:    ^thread.Thread,
	stop_req:  bool, // atomic
	finished:  bool, // atomic
	stopping:  bool,
	stop_at:   i64,
	frames:    view.Triple(Frame),
	states:    view.Triple(S),
	queue:     view.Queue(Message, 4096),
	tracker:   view.Event_Tracker(Tick_Event),
	published: u64,
	scratch:   [dynamic]Tick_Event,
	result:    string,
	nets:      [dynamic]^netcode.Net_Sim, // wrapped remote links (owned by the channel)
	net_gen:   u32,
}

// Wraps a remote link in a netsim (always, so the dev UI can impair it live; with zero settings it only queues).
@(private)
wrap_link :: proc(d: ^Driver($S, $I, $W, $P), link: netcode.Link) -> netcode.Link {
	w := netcode.netsim_wrap(link, {name = "devui", latency = 1}, u32(d.req.seed) | 1)
	ns := (^netcode.Net_Sim)(w.data)
	sync.mutex_lock(&netsim_req.mu)
	ns.profile = netsim_profile(netsim_req.set)
	d.net_gen = netsim_req.gen
	sync.mutex_unlock(&netsim_req.mu)
	append(&d.nets, ns)
	return w
}

@(private)
g_game: rawptr
@(private)
g_glue: rawptr
@(private)
g_driver: rawptr

// Installs the game: call once, before godot_host.entry.
install :: proc(game: ^sim.Game($S, $I, $W, $P), glue: Glue(S, I, W)) {
	D :: Driver(S, I, W, P)
	gl := new(Glue(S, I, W))
	gl^ = glue
	g_game = game
	g_glue = gl
	api = {
		installed   = true,
		game_name   = game.name,
		tick_hz     = game.tick_hz,
		scene_kinds = glue.scene_kinds,
		bulk_kinds  = glue.bulk_kinds,
		actions     = glue.actions,
		event_names = game.event_names,
	}
	api.start = proc(req: Start) -> (bool, string) {
		if g_driver != nil do return false, "a session is already running"
		game := (^sim.Game(S, I, W, P))(g_game)
		glue := (^Glue(S, I, W))(g_glue)
		if (req.mode == .Host_Online || req.mode == .Join_Online) && transport == nil {
			return false, "online play is not available in this build"
		}
		d := new(D)
		d.game = game
		d.glue = glue
		d.req = req
		d.req.arg = strings.clone(req.arg)
		d.req.name = strings.clone(req.name)
		d.req.profile = strings.clone(req.profile)
		view.triple_init(&d.frames)
		view.triple_init(&d.states)
		view.tracker_init(&d.tracker, tick_event_id)
		d.tev = {
			ctx = d,
			code = proc(ctx: rawptr, code: string) {post_text((^D)(ctx), .Lobby_Code, code)},
			fail = proc(ctx: rawptr, reason: string) {
				d := (^D)(ctx)
				post_status(d, .Failed, reason)
				sync.atomic_store(&d.stop_req, true)
			},
		}
		g_driver = d
		d.thread = thread.create_and_start_with_poly_data(d, driver_run)
		return true, ""
	}
	api.stop = proc() {
		if g_driver == nil do return
		sync.atomic_store(&(^D)(g_driver).stop_req, true)
	}
	api.wait = proc() {
		if g_driver == nil do return
		d := (^D)(g_driver)
		sync.atomic_store(&d.stop_req, true)
		thread.join(d.thread)
		thread.destroy(d.thread)
		view.tracker_destroy(&d.tracker)
		delete(d.scratch)
		delete(d.req.arg)
		delete(d.req.name)
		delete(d.req.profile)
		delete(d.result)
		delete(d.nets)
		free(d)
		g_driver = nil
	}
	api.running = proc() -> bool {
		return g_driver != nil && !sync.atomic_load(&(^D)(g_driver).finished)
	}
	api.front = proc() -> (^Frame, bool) {
		if g_driver == nil do return nil, false
		f, fresh := view.triple_front(&(^D)(g_driver).frames)
		if f.published == 0 do return nil, false
		return f, fresh
	}
	api.pop = proc() -> (Message, bool) {
		if g_driver == nil do return {}, false
		return view.queue_pop(&(^D)(g_driver).queue)
	}
	api.hud = proc(f: ^Frame, names: []string, d: rawptr) {
		glue := (^Glue(S, I, W))(g_glue)
		if glue.hud != nil do glue.hud(f, names, auto_cast d)
	}
	api.result = proc() -> string {
		if g_driver == nil do return ""
		return (^D)(g_driver).result
	}
	api.state = proc() -> any {
		if g_driver == nil do return nil
		d := (^D)(g_driver)
		s, _ := view.triple_front(&d.states)
		return s^
	}
}

@(private)
post :: proc(d: ^Driver($S, $I, $W, $P), m: Message) {
	_ = view.queue_push(&d.queue, m) // full: the main thread is stalled; dropping beats blocking the sim
}

@(private)
post_text :: proc(d: ^Driver($S, $I, $W, $P), kind: type_of(Message{}.kind), text: string) {
	m := Message {
		kind = kind,
	}
	n := copy(m.text[:], text)
	m.len = u8(n)
	post(d, m)
}

@(private)
post_status :: proc(d: ^Driver($S, $I, $W, $P), st: Status_Kind, detail: string) {
	m := Message {
		kind   = .Status,
		status = st,
	}
	m.len = u8(copy(m.text[:], detail))
	post(d, m)
}

@(private)
flush_events :: proc(d: ^Driver($S, $I, $W, $P)) {
	for a in d.tracker.out {
		post(d, Message{kind = .Event, action = a.action, tick = a.event.tick, event = a.event.event})
	}
	clear(&d.tracker.out)
}

// Feeds one simulated tick's events to the tracker (numbering repeats of a kind+entity within the tick).
@(private)
track_tick :: proc(d: ^Driver($S, $I, $W, $P), tick: u32, events: []sim.Event) {
	view.tracker_begin_tick(&d.tracker, tick)
	clear(&d.scratch)
	for e in events {
		nth: u32
		for prev in d.scratch {
			if prev.event.kind == e.kind && prev.event.entity == e.entity && prev.event.slot == e.slot do nth += 1
		}
		te := Tick_Event{tick, nth, e}
		append(&d.scratch, te)
		view.tracker_event(&d.tracker, te)
	}
	view.tracker_end_tick(&d.tracker, tick)
}

@(private)
driver_hooks :: proc(d: ^Driver($S, $I, $W, $P)) -> netcode.Hooks(S, I, W, P) {
	D :: Driver(S, I, W, P)
	return {user = d, sample = proc(user: rawptr, slot: int, tick: u32, state: ^S) -> I {
			d := (^D)(user)
			if d.req.scripted && d.glue.scripted != nil do return d.glue.scripted(d.req.seed, slot, tick, state)
			return d.glue.sample(take_actions(), slot, tick, state)
		}, frame = proc(user: rawptr, s: ^sim.Sim(S, I, W, P), f: netcode.Frame_Info) {
			d := (^D)(user)
			for t in f.resim_from ..= f.tick do track_tick(d, t, sim.events_at(s, t))
			flush_events(d)
			cur := sim.state_at(s, f.tick)
			if cur == nil do cur = &s.state
			prev := f.tick > 0 ? sim.state_at(s, f.tick - 1) : nil
			out := view.triple_back(&d.frames)
			out.n_scene, out.n_bulk = 0, 0
			d.glue.extract(cur, prev, s.world, out)
			c := d.client
			d.published += 1
			out.published = d.published
			out.tick = f.tick
			out.verified = f.verified
			out.tick_hz = u32(d.game.tick_hz)
			out.due_us = i64(c.next_tick_us - c.tm.tick_us)
			out.local_slot = i32(c.slot)
			out.net = {
				rtt_ms      = f32(netcode.client_rtt_ms(c)),
				delay       = c.delay,
				rollbacks   = i32(c.rollbacks),
				resim_ticks = i32(c.resim_ticks),
				depth_max   = i32(c.depth_max),
			}
			view.triple_publish(&d.frames)
			if sync.atomic_load(&want_state) {
				view.triple_back(&d.states)^ = cur^
				view.triple_publish(&d.states)
			}
		}, verified = proc(user: rawptr, s: ^sim.Sim(S, I, W, P), tick: u32, events: []sim.Event) {
			d := (^D)(user)
			track_tick(d, tick, events)
			view.tracker_verified(&d.tracker, tick)
			flush_events(d)
		}, status = proc(user: rawptr, st: netcode.Status, detail: string) {
			d := (^D)(user)
			post_status(d, Status_Kind(st), detail)
		}}
}

@(private)
driver_run :: proc(d: ^Driver($S, $I, $W, $P)) {
	set_thread_class(.Realtime, d.game.tick_hz)
	if !driver_open(d) {
		driver_close(d)
		sync.atomic_store(&d.finished, true)
		return
	}
	for {
		now := netcode.now_us()
		if d.uses_tp && transport.pump != nil do transport.pump(transport.user, &d.tev)
		if len(d.nets) > 0 && sync.atomic_load(&netsim_req.gen) != d.net_gen {
			sync.mutex_lock(&netsim_req.mu)
			for ns in d.nets do ns.profile = netsim_profile(netsim_req.set)
			d.net_gen = netsim_req.gen
			sync.mutex_unlock(&netsim_req.mu)
		}
		if sync.atomic_load(&d.stop_req) && !d.stopping {
			d.stopping = true
			d.stop_at = now
			if d.host != nil do netcode.host_stop(d.host, now)
			else do netcode.client_stop(d.client, now)
		}
		wake: i64
		if d.host != nil {
			wake = netcode.host_step(d.host, now)
			if netcode.host_finished(d.host) do break
		} else {
			wake = netcode.client_step(d.client, now)
			if d.client.status == .Failed || d.client.status == .Disconnected do break
		}
		if d.stopping && now - d.stop_at > 3_000_000 do break
		if d.uses_tp do wake = min(wake, now + 4_000)
		netcode.sleep_until(wake)
	}
	d.result = clone_json(netcode.client_json(d.client))
	post(d, Message{kind = .Result})
	driver_close(d)
	sync.atomic_store(&d.finished, true)
}

@(private)
driver_open :: proc(d: ^Driver($S, $I, $W, $P)) -> bool {
	r := &d.req
	g := d.game
	hooks := driver_hooks(d)
	host_cfg := netcode.Host_Config {
		seed   = r.seed,
		ticks  = r.ticks,
		compat = d.glue.compat,
		name   = "host",
		quiet  = true,
	}
	client_cfg := netcode.Client_Config {
		slot   = -1,
		compat = d.glue.compat,
		name   = "client",
		quiet  = true,
	}
	switch r.mode {
	case .Single:
		d.host = netcode.host_create(g, host_cfg, hooks)
	case .Host_Direct:
		link, ok := netcode.udp_listen(r.port)
		if !ok {
			post_status(d, .Failed, fmt.tprintf("cannot listen on UDP port %d", r.port))
			return false
		}
		d.host = netcode.host_create(g, host_cfg, hooks)
		post_text(d, .Lobby_Code, fmt.tprintf("%d", netcode.udp_bound_port(&link)))
		netcode.host_add_link(d.host, wrap_link(d, link))
	case .Host_Online:
		d.uses_tp = true
		link, ok := transport.open_host(transport.user, &d.tev)
		if !ok {
			post_status(d, .Failed, fmt.tprintf("%s: cannot host", transport.name))
			return false
		}
		d.host = netcode.host_create(g, host_cfg, hooks)
		netcode.host_add_link(d.host, wrap_link(d, link))
	case .Join_Direct:
		ep, ok := cnet.parse_endpoint(r.arg)
		if !ok {
			if host, port, split := split_host_port(r.arg); split {
				if ep4, rerr := cnet.resolve_ip4(fmt.tprintf("%s:%d", host, port)); rerr == nil {
					ep, ok = ep4, true
				}
			}
		}
		if !ok {
			post_status(d, .Failed, fmt.tprintf("bad address %q (want host:port)", r.arg))
			return false
		}
		link, lok := netcode.udp_connect(ep)
		if !lok {
			post_status(d, .Failed, "cannot open a UDP socket")
			return false
		}
		d.client = netcode.client_create(g, client_cfg, wrap_link(d, link), hooks)
	case .Join_Online:
		d.uses_tp = true
		link, ok := transport.open_join(transport.user, r.arg, &d.tev)
		if !ok {
			post_status(d, .Failed, fmt.tprintf("%s: cannot join %q", transport.name, r.arg))
			return false
		}
		d.client = netcode.client_create(g, client_cfg, wrap_link(d, link), hooks)
	}
	if d.host != nil do d.client = d.host.client
	return true
}

@(private)
driver_close :: proc(d: ^Driver($S, $I, $W, $P)) {
	if d.host != nil {
		netcode.host_destroy(d.host)
	} else if d.client != nil {
		netcode.client_destroy(d.client)
	}
	d.host, d.client = nil, nil
	if d.uses_tp && transport.close != nil do transport.close(transport.user)
}

@(private)
clone_json :: proc(s: string) -> string {
	return strings.clone(s)
}

@(private)
split_host_port :: proc(s: string) -> (host: string, port: int, ok: bool) {
	i := strings.last_index_byte(s, ':')
	if i <= 0 do return
	p := 0
	for c in s[i + 1:] {
		if c < '0' || c > '9' do return
		p = p * 10 + int(c - '0')
	}
	return s[:i], p, p > 0 && p < 65536
}
