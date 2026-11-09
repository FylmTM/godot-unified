// In-process sessions for tests (T3, T6): a relay plus clients over loopback or localhost UDP, each
// client's link wrapped in the network simulator for the chosen profile. On the real clock, the relay
// and every client run on threads of their own that sleep until each step's next deadline; on a
// virtual clock (loopback only), one thread steps them all through test time as fast as it computes,
// deterministically.
package headless

import "core:fmt"
import cnet "core:net"
import "core:sync"
import "core:thread"
import "core:time"

import "../netcode"
import "../sim"

Session_Config :: struct {
	clients:     int,
	transport:   string, // "loopback" or "udp"
	virtual:     bool, // step on a virtual clock (loopback only)
	profile:     netcode.Profile,
	ticks:       u32,
	seed:        u64,
	late_player: int, // -1: none
	late_tick:   u32,
}

Session_Result :: struct($I: typeid, $P: int) {
	ok:        bool,
	desyncs:   int,
	replaced:  int,
	clients:   [dynamic]string, // JSON objects (temp-allocated)
	log:       sim.Input_Log(I, P),
	relay_net: string,
}

// Script hooks: every client samples the game's scripted input for its slot.
@(private)
Script_User :: struct($S, $I, $W: typeid, $P: int) {
	h:    ^Headless(S, I, W, P),
	seed: u64,
}

script_hooks :: proc(u: ^Script_User($S, $I, $W, $P)) -> netcode.Hooks(S, I, W, P) {
	return {user = u, sample = proc(user: rawptr, slot: int, tick: u32, state: ^S) -> I {
			u := (^Script_User(S, I, W, P))(user)
			return u.h.script(u.seed, slot, tick, state)
		}}
}

@(private)
Client_Task :: struct($S, $I, $W: typeid, $P: int) {
	c:        ^netcode.Client(S, I, W, P),
	deadline: i64,
	ok:       bool,
}

// Steps a client on this thread until the session ends for it (or the deadline).
run_client :: proc(t: ^Client_Task($S, $I, $W, $P)) {
	c := t.c
	for {
		now := netcode.now_us()
		wake := netcode.client_step(c, now)
		if c.status == .Disconnected || c.status == .Failed {
			break
		}
		if now > t.deadline {
			fmt.eprintfln(
				"%s: timeout (verified %d, predicted %d, local %d)",
				c.cfg.name,
				c.verified,
				c.predicted,
				c.local,
			)
			break
		}
		netcode.sleep_until(wake)
	}
	t.ok = c.ticks != 0 && c.verified == c.ticks && c.status == .Disconnected
}

// Steps a relay on this thread until it is finished (or the deadline).
run_relay :: proc(r: ^netcode.Relay($I, $P), deadline: i64) -> bool {
	for !netcode.relay_finished(r) {
		now := netcode.now_us()
		wake := netcode.relay_step(r, now)
		if now > deadline {
			fmt.eprintfln("%s: timeout (clock %d, finalized %d, done %v)", r.cfg.name, r.clock, r.finalized, r.done)
			return false
		}
		netcode.sleep_until(wake)
	}
	return true
}

session_timeout_s :: proc(ticks: u32, hz: int) -> f64 {
	return f64(ticks) / f64(hz) * 3 + 60
}

// A session's relay, transport and clients, before they run.
@(private)
Session :: struct($S, $I, $W: typeid, $P: int) {
	h:        ^Headless(S, I, W, P),
	cfg:      Session_Config,
	relay:    ^netcode.Relay(I, P),
	hub:      ^netcode.Hub,
	port:     int,
	clock:    ^netcode.Virtual_Clock, // nil: real time
	user:     Script_User(S, I, W, P),
	tasks:    []Client_Task(S, I, W, P),
	deadline: i64,
}

session_run :: proc(h: ^Headless($S, $I, $W, $P), cfg: Session_Config) -> (res: Session_Result(I, P)) {
	vc := netcode.Virtual_Clock {
		now = 1_000_000,
	}
	ss := Session(S, I, W, P) {
		h     = h,
		cfg   = cfg,
		clock = cfg.virtual ? &vc : nil,
		user  = {h, cfg.seed},
	}
	timeout := session_timeout_s(cfg.ticks, h.game.tick_hz)
	ss.deadline = session_now(&ss) + i64(timeout * 1e6)
	rcfg := netcode.Relay_Config {
		tick_hz       = h.game.tick_hz,
		seed          = cfg.seed,
		ticks         = cfg.ticks,
		start_players = cfg.clients - (cfg.late_player >= 0 ? 1 : 0),
		compat        = sim.compat_of(h.game),
		name          = "relay",
		quiet         = cfg.virtual, // test time: wall-clock log lines would only be noise
	}
	ss.relay = netcode.relay_create(rcfg, I, P)
	if cfg.transport == "udp" {
		link, ok := netcode.udp_listen(0)
		if !ok {
			fmt.eprintln("session: cannot bind a UDP port")
			netcode.relay_destroy(ss.relay)
			return
		}
		ss.port = netcode.udp_bound_port(&link)
		netcode.relay_add_link(ss.relay, link)
	} else {
		ss.hub = netcode.hub_create(cfg.clients + 1)
		netcode.relay_add_link(ss.relay, netcode.loopback_link(ss.hub, 0))
	}
	ss.tasks = make([]Client_Task(S, I, W, P), cfg.clients)
	defer delete(ss.tasks)
	res.ok = session_run_virtual(&ss) if cfg.virtual else session_run_threads(&ss)

	relay := ss.relay
	res.desyncs = relay.desyncs
	res.replaced = relay.replaced
	res.log = relay.log
	relay.log = {}
	res.relay_net = netcode.channel_stats_json(relay.ch)
	for &t in ss.tasks {
		if t.c == nil {
			res.ok = false
			continue
		}
		append(&res.clients, netcode.client_json(t.c))
		res.ok &&= t.ok
		delete(t.c.cfg.name)
		netcode.client_destroy(t.c)
	}
	netcode.relay_destroy(relay)
	if ss.hub != nil {
		netcode.hub_destroy(ss.hub)
	}
	return
}

@(private)
session_now :: proc(ss: ^Session($S, $I, $W, $P)) -> i64 {
	return ss.clock.now if ss.clock != nil else netcode.now_us()
}

// The client of slot p (`join`: its join tick, 0 for a starting player).
@(private)
session_client :: proc(ss: ^Session($S, $I, $W, $P), p: int, join: u32) -> ^netcode.Client(S, I, W, P) {
	cfg := ss.cfg
	link: netcode.Link
	if cfg.transport == "udp" {
		ok: bool
		link, ok = netcode.udp_connect({cnet.IP4_Loopback, ss.port})
		assert(ok, "udp_connect failed")
	} else {
		link = netcode.loopback_link(ss.hub, netcode.Peer(p + 1))
	}
	link = netcode.netsim_wrap(link, cfg.profile, u32(cfg.seed) * 7919 + u32(p) * 104729 + 17, ss.clock)
	ccfg := netcode.Client_Config {
		slot      = p,
		join_tick = join,
		name      = fmt.aprintf("client%d", p),
		quiet     = ss.clock != nil,
	}
	return netcode.client_create(ss.h.game, ccfg, link, script_hooks(&ss.user))
}

// Real time: the relay and each client on a thread of its own.
@(private)
session_run_threads :: proc(ss: ^Session($S, $I, $W, $P)) -> bool {
	Relay_Task :: struct {
		r:        ^netcode.Relay(I, P),
		deadline: i64,
		ok:       bool,
	}
	rt := Relay_Task{ss.relay, ss.deadline, false}
	relay_thread := thread.create_and_start_with_poly_data(&rt, proc(t: ^Relay_Task) {
		t.ok = run_relay(t.r, t.deadline)
	})
	cfg := ss.cfg
	threads := make([]^thread.Thread, cfg.clients)
	defer delete(threads)
	for p in 0 ..< cfg.clients {
		if p == cfg.late_player {
			continue
		}
		ss.tasks[p] = {session_client(ss, p, 0), ss.deadline, false}
		threads[p] = thread.create_and_start_with_poly_data(&ss.tasks[p], run_client)
	}
	if cfg.late_player >= 0 {
		// Connect the joiner ~1.5 s before its join tick, so the slot is assigned in time.
		lead := u32(ss.h.game.tick_hz * 3 / 2)
		for netcode.relay_clock(ss.relay) + lead < cfg.late_tick && netcode.now_us() < ss.deadline {
			time.sleep(5 * time.Millisecond)
		}
		p := cfg.late_player
		ss.tasks[p] = {session_client(ss, p, cfg.late_tick), ss.deadline, false}
		sync.atomic_thread_fence(.Seq_Cst)
		threads[p] = thread.create_and_start_with_poly_data(&ss.tasks[p], run_client)
	}
	for p in 0 ..< cfg.clients {
		thread.join(threads[p])
		thread.destroy(threads[p])
	}
	thread.join(relay_thread)
	thread.destroy(relay_thread)
	return rt.ok
}

// Virtual time: one thread steps the relay and every client, jumping to the earliest wake time.
@(private)
session_run_virtual :: proc(ss: ^Session($S, $I, $W, $P)) -> bool {
	cfg := ss.cfg
	vc := ss.clock
	for p in 0 ..< cfg.clients {
		if p != cfg.late_player {
			ss.tasks[p] = {session_client(ss, p, 0), ss.deadline, false}
		}
	}
	lead := u32(ss.h.game.tick_hz * 3 / 2)
	for {
		if cfg.late_player >= 0 && ss.tasks[cfg.late_player].c == nil && ss.relay.clock + lead >= cfg.late_tick {
			ss.tasks[cfg.late_player] = {session_client(ss, cfg.late_player, cfg.late_tick), ss.deadline, false}
		}
		wake := netcode.relay_step(ss.relay, vc.now)
		running := !netcode.relay_finished(ss.relay)
		for &t in ss.tasks {
			if t.c == nil || t.c.status == .Disconnected || t.c.status == .Failed {
				continue
			}
			wake = min(wake, netcode.client_step(t.c, vc.now))
			running = true
		}
		if !running {
			break
		}
		if vc.now > ss.deadline {
			fmt.eprintfln("session: timeout at relay clock %d (finalized %d)", ss.relay.clock, ss.relay.finalized)
			return false
		}
		vc.now = max(wake, vc.now + 1)
	}
	for &t in ss.tasks {
		if t.c != nil {
			t.ok = t.c.ticks != 0 && t.c.verified == t.c.ticks && t.c.status == .Disconnected
		}
	}
	return true
}
