// In-process sessions: a relay thread plus one thread per client, over loopback or localhost UDP,
// each client's link wrapped in the network simulator for the chosen profile.
package netcode

import "core:fmt"
import cnet "core:net"
import "core:thread"
import "core:time"

import "../core"

Session_Config :: struct {
	clients:     int,
	transport:   string, // "loopback" or "udp"
	profile:     Profile,
	ticks:       u32,
	seed:        u32,
	late_player: int, // -1: none
	late_tick:   u32,
}

Session_Result :: struct {
	ok:         bool,
	desyncs:    int,
	replaced:   int,
	clients:    [dynamic]string, // JSON objects
	client_ok:  [dynamic]bool,
	log:        core.Input_Log,
	relay_net:  string,
}

@(private)
Client_Task :: struct {
	c:  ^Client,
	ok: bool,
}

session_run :: proc(cfg: Session_Config) -> (res: Session_Result) {
	timeout := f64(cfg.ticks) / 60 * 3 + 60
	start_players := cfg.clients - (cfg.late_player >= 0 ? 1 : 0)
	rcfg := Relay_Config {
		ticks         = cfg.ticks,
		seed          = cfg.seed,
		start_players = start_players,
		timeout_s     = timeout,
		name          = "relay",
	}
	hub: ^Hub
	relay_link: Link
	port := 0
	if cfg.transport == "udp" {
		ok: bool
		relay_link, ok = udp_listen(0)
		if !ok {
			fmt.eprintln("session: cannot bind a UDP port")
			return
		}
		port = udp_bound_port(&relay_link)
	} else {
		hub = hub_create(cfg.clients + 1)
		relay_link = loopback_link(hub, 0)
	}
	relay := relay_create(rcfg, relay_link)
	relay_ok := false
	relay_thread := thread.create_and_start_with_poly_data2(relay, &relay_ok, proc(r: ^Relay, ok: ^bool) {
		ok^ = relay_run(r)
	})

	make_client :: proc(cfg: Session_Config, hub: ^Hub, port: int, p: int, join: u32, timeout: f64) -> ^Client {
		link: Link
		if cfg.transport == "udp" {
			ok: bool
			link, ok = udp_connect({cnet.IP4_Loopback, port})
			assert(ok, "udp_connect failed")
		} else {
			link = loopback_link(hub, Peer(p + 1))
		}
		link = netsim_wrap(link, cfg.profile, cfg.seed * 7919 + u32(p) * 104729 + 17)
		ccfg := Client_Config {
			player    = p,
			join_tick = join,
			timeout_s = timeout,
			name      = fmt.aprintf("client%d", p),
		}
		return client_create(ccfg, link)
	}

	tasks := make([]Client_Task, cfg.clients)
	threads := make([]^thread.Thread, cfg.clients)
	defer delete(tasks)
	defer delete(threads)
	run_task :: proc(t: ^Client_Task) {
		t.ok = client_run(t.c)
	}
	for p in 0 ..< cfg.clients {
		if p == cfg.late_player {
			continue
		}
		tasks[p].c = make_client(cfg, hub, port, p, 0, timeout)
		threads[p] = thread.create_and_start_with_poly_data(&tasks[p], run_task)
	}
	if cfg.late_player >= 0 {
		// Connect the joiner ~1.5 s before its join tick, so the slot is assigned in time.
		sw := Stopwatch{start = now_tick()}
		for relay_clock(relay) + 90 < cfg.late_tick && elapsed_s(sw) < timeout {
			time.sleep(5 * time.Millisecond)
		}
		p := cfg.late_player
		tasks[p].c = make_client(cfg, hub, port, p, cfg.late_tick, timeout)
		threads[p] = thread.create_and_start_with_poly_data(&tasks[p], run_task)
	}
	for p in 0 ..< cfg.clients {
		thread.join(threads[p])
		thread.destroy(threads[p])
	}
	thread.join(relay_thread)
	thread.destroy(relay_thread)

	res.ok = relay_ok
	res.desyncs = relay.desyncs
	res.replaced = relay.replaced
	res.log = relay.log
	relay.log = {}
	res.relay_net = channel_stats_json(relay.ch)
	for p in 0 ..< cfg.clients {
		t := &tasks[p]
		append(&res.clients, client_json(t.c))
		append(&res.client_ok, t.ok)
		res.ok &&= t.ok
		delete(t.c.cfg.name)
		client_destroy(t.c)
	}
	relay_destroy(relay)
	if hub != nil {
		hub_destroy(hub)
	}
	return
}
