// A host: the relay plus the host player's own client in one process, joined by an in-process
// loopback link. Remote players reach the same relay through links added with host_add_link (UDP,
// EOS P2P, ...). Single player is a host with no remote links: the same code path, no special case.
package netcode

import "../sim"

Host_Config :: struct {
	seed:    u64,
	ticks:   u32, // 0: endless
	compat:  u64, // build/game id the relay checks (0: sim.compat_of(game))
	name:    string, // for log lines
	player:  string, // the host player's display name
	poll_us: i64,
	quiet:   bool,
}

Host :: struct($S, $I, $W: typeid, $P: int) {
	relay:  ^Relay(I, P),
	client: ^Client(S, I, W, P),
	hub:    ^Hub,
}

// Creates the relay (its clock starts when the host's client connects, on the first steps) and
// the host's client in slot 0.
host_create :: proc(game: ^sim.Game($S, $I, $W, $P), cfg: Host_Config, hooks: Hooks(S, I, W, P)) -> ^Host(S, I, W, P) {
	h := new(Host(S, I, W, P))
	h.hub = hub_create(2)
	compat := cfg.compat if cfg.compat != 0 else sim.compat_of(game)
	rcfg := Relay_Config {
		tick_hz       = game.tick_hz,
		seed          = cfg.seed,
		ticks         = cfg.ticks,
		start_players = 1,
		compat        = compat,
		name          = cfg.name,
		poll_us       = cfg.poll_us,
		quiet         = cfg.quiet,
	}
	h.relay = relay_create(rcfg, I, P)
	relay_add_link(h.relay, loopback_link(h.hub, 0))
	ccfg := Client_Config {
		slot    = 0,
		compat  = compat,
		name    = cfg.name,
		player  = cfg.player,
		poll_us = cfg.poll_us,
		quiet   = cfg.quiet,
	}
	h.client = client_create(game, ccfg, loopback_link(h.hub, 1), hooks)
	return h
}

// Adds a transport for remote players (the relay owns it from now on).
host_add_link :: proc(h: ^Host($S, $I, $W, $P), link: Link) -> int {
	return relay_add_link(h.relay, link)
}

// Steps the relay and the host's client; returns the earlier of their wake times.
host_step :: proc(h: ^Host($S, $I, $W, $P), now: i64) -> i64 {
	a := relay_step(h.relay, now)
	b := client_step(h.client, now)
	return min(a, b)
}

// Ends the session for everyone. Keep stepping until host_finished.
host_stop :: proc(h: ^Host($S, $I, $W, $P), now: i64) {
	relay_stop(h.relay, now)
}

host_finished :: proc(h: ^Host($S, $I, $W, $P)) -> bool {
	st := h.client.status
	return relay_finished(h.relay) && (st == .Disconnected || st == .Failed)
}

host_destroy :: proc(h: ^Host($S, $I, $W, $P)) {
	client_destroy(h.client)
	relay_destroy(h.relay)
	hub_destroy(h.hub)
	free(h)
}
