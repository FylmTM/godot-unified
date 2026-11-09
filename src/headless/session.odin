// In-process sessions for tests (T3, T6): a relay thread plus one thread per client, over loopback
// or localhost UDP, each client's link wrapped in the network simulator for the chosen profile.
// Every loop sleeps until the step's next deadline.
package headless

import "core:fmt"
import cnet "core:net"
import "core:sync"
import "core:thread"
import "core:time"

import "unified:netcode"
import "unified:sim"

Session_Config :: struct {
	clients:     int,
	transport:   string, // "loopback" or "udp"
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

session_run :: proc(h: ^Headless($S, $I, $W, $P), cfg: Session_Config) -> (res: Session_Result(I, P)) {
	timeout := session_timeout_s(cfg.ticks, h.game.tick_hz)
	deadline := netcode.now_us() + i64(timeout * 1e6)
	start_players := cfg.clients - (cfg.late_player >= 0 ? 1 : 0)
	rcfg := netcode.Relay_Config {
		tick_hz       = h.game.tick_hz,
		seed          = cfg.seed,
		ticks         = cfg.ticks,
		start_players = start_players,
		name          = "relay",
	}
	relay := netcode.relay_create(rcfg, I, P)
	hub: ^netcode.Hub
	port := 0
	if cfg.transport == "udp" {
		link, ok := netcode.udp_listen(0)
		if !ok {
			fmt.eprintln("session: cannot bind a UDP port")
			netcode.relay_destroy(relay)
			return
		}
		port = netcode.udp_bound_port(&link)
		netcode.relay_add_link(relay, link)
	} else {
		hub = netcode.hub_create(cfg.clients + 1)
		netcode.relay_add_link(relay, netcode.loopback_link(hub, 0))
	}
	Relay_Task :: struct {
		r:        ^netcode.Relay(I, P),
		deadline: i64,
		ok:       bool,
	}
	rt := Relay_Task{relay, deadline, false}
	relay_thread := thread.create_and_start_with_poly_data(&rt, proc(t: ^Relay_Task) {
		t.ok = run_relay(t.r, t.deadline)
	})

	user := Script_User(S, I, W, P){h, cfg.seed}
	make_client :: proc(
		h: ^Headless($S, $I, $W, $P),
		cfg: Session_Config,
		user: ^Script_User(S, I, W, P),
		hub: ^netcode.Hub,
		port: int,
		p: int,
		join: u32,
	) -> ^netcode.Client(S, I, W, P) {
		link: netcode.Link
		if cfg.transport == "udp" {
			ok: bool
			link, ok = netcode.udp_connect({cnet.IP4_Loopback, port})
			assert(ok, "udp_connect failed")
		} else {
			link = netcode.loopback_link(hub, netcode.Peer(p + 1))
		}
		link = netcode.netsim_wrap(link, cfg.profile, u32(cfg.seed) * 7919 + u32(p) * 104729 + 17)
		ccfg := netcode.Client_Config {
			slot      = p,
			join_tick = join,
			name      = fmt.aprintf("client%d", p),
		}
		return netcode.client_create(h.game, ccfg, link, script_hooks(user))
	}

	tasks := make([]Client_Task(S, I, W, P), cfg.clients)
	threads := make([]^thread.Thread, cfg.clients)
	defer delete(tasks)
	defer delete(threads)
	for p in 0 ..< cfg.clients {
		if p == cfg.late_player {
			continue
		}
		tasks[p] = {make_client(h, cfg, &user, hub, port, p, 0), deadline, false}
		threads[p] = thread.create_and_start_with_poly_data(&tasks[p], run_client)
	}
	if cfg.late_player >= 0 {
		// Connect the joiner ~1.5 s before its join tick, so the slot is assigned in time.
		lead := u32(h.game.tick_hz * 3 / 2)
		for netcode.relay_clock(relay) + lead < cfg.late_tick && netcode.now_us() < deadline {
			time.sleep(5 * time.Millisecond)
		}
		p := cfg.late_player
		tasks[p] = {make_client(h, cfg, &user, hub, port, p, cfg.late_tick), deadline, false}
		sync.atomic_thread_fence(.Seq_Cst)
		threads[p] = thread.create_and_start_with_poly_data(&tasks[p], run_client)
	}
	for p in 0 ..< cfg.clients {
		thread.join(threads[p])
		thread.destroy(threads[p])
	}
	thread.join(relay_thread)
	thread.destroy(relay_thread)

	res.ok = rt.ok
	res.desyncs = relay.desyncs
	res.replaced = relay.replaced
	res.log = relay.log
	relay.log = {}
	res.relay_net = netcode.channel_stats_json(relay.ch)
	for p in 0 ..< cfg.clients {
		t := &tasks[p]
		append(&res.clients, netcode.client_json(t.c))
		res.ok &&= t.ok
		delete(t.c.cfg.name)
		netcode.client_destroy(t.c)
	}
	netcode.relay_destroy(relay)
	if hub != nil {
		netcode.hub_destroy(hub)
	}
	return
}
