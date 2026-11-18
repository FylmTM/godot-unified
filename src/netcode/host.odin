// A host: the relay plus the host player's own client in one process, joined by an in-process
// loopback link. Remote players reach the same relay through links added with host_add_link (UDP,
// EOS P2P, ...). Single player is a host with no remote links: the same code path, no special case.
package netcode

import "unified:sim"

Host_Config :: struct {
	seed:          u64,
	ticks:         u32, // 0: endless
	compat:        u64, // build/game id the relay checks (0: sim.compat_of(game, content))
	content:       []u8, // the game's content (the level, src/level/SPEC.md); borrowed for the host's lifetime
	player_name:   string, // the host player's display name
	account:       Account, // optional: the host player's own platform account (borrowed for the host's lifetime)
	recording:     sim.Log_Sink, // optional: the session's input log (Relay_Config.recording)
	desync_detail: bool, // typed desync reports (Relay_Config.desync_detail)
}

Host :: struct($G: typeid) {
	relay:   ^Relay(G),
	client:  ^Client(G),
	hub:     ^Hub,
	waiting: [dynamic]Link, // remote links added before the host's player is in (host_add_link)
}

// The steps' poll while a host has no remote links (single player): nothing arrives from outside, so a step runs at
// its deadlines (the next tick of the relay or the client) and this is only the fallback before the clock starts.
SOLO_POLL_US :: 50_000

// Creates the relay (its clock starts when the host's client connects, on the first steps) and
// the host's client in slot 0.
host_create :: proc(game: ^$G, cfg: Host_Config, hooks: Hooks(G)) -> ^Host(G) {
	host := new(Host(G))
	host.hub = hub_create(2)
	compat := cfg.compat if cfg.compat != 0 else sim.compat_of(game, cfg.content)
	host.relay = relay_create(
	game,
	{
		seed          = cfg.seed,
		ticks         = cfg.ticks,
		start_players = 1,
		content       = cfg.content,
		compat        = compat,
		local_start   = true, // the only start player is the host's own client
		recording     = cfg.recording,
		desync_detail = cfg.desync_detail,
	},
	)
	host.relay.poll_us = SOLO_POLL_US
	relay_add_link(host.relay, loopback_link(host.hub, 0, cfg.account))
	client_config := Client_Config {
		slot        = 0,
		compat      = compat,
		content     = cfg.content,
		player_name = cfg.player_name,
	}
	host.client = client_create(game, client_config, loopback_link(host.hub, 1), hooks)
	host.client.poll_us = SOLO_POLL_US // its only link is in-process: host_step hands it what the relay sends at once
	return host
}

// Adds a transport for remote players (the host owns it from now on). The relay serves it once the host's
// own player is in (its clock started), so a remote Hello already waiting on the link (a player who connected
// while the host waited for them) joins as a remote player instead of taking the host's player 0.
host_add_link :: proc(host: ^Host($G), link: Link) {
	host.relay.poll_us = POLL_US // datagrams from outside: poll for them
	if host.relay.started {
		relay_add_link(host.relay, link)
	} else {
		append(&host.waiting, link)
	}
}

// Steps the relay and the host's client; returns the earlier of their wake times. What one of them sends the other
// is taken in the same call (they talk in-process), so the host's own inputs and finalized ticks never wait for a
// wake, and a single-player host wakes only at its deadlines.
host_step :: proc(host: ^Host($G), now: i64) -> i64 {
	relay_wake := relay_step(host.relay, now)
	client_wake := client_step(host.client, now)
	for _ in 0 ..< 4 { 	// inputs -> finalized tick -> its ack: a few rounds at most
		if hub_queued(host.hub, 0) == 0 && hub_queued(host.hub, 1) == 0 {
			break
		}
		relay_wake = relay_step(host.relay, now)
		client_wake = client_step(host.client, now)
	}
	if host.relay.started && len(host.waiting) > 0 {
		for link in host.waiting {
			relay_add_link(host.relay, link)
		}
		clear(&host.waiting)
		relay_wake = now // serve them at once
	}
	return min(relay_wake, client_wake)
}

// Ends the session for everyone. Keep stepping until host_finished.
host_stop :: proc(host: ^Host($G), now: i64) {
	relay_stop(host.relay, now)
}

// Whether the session is over on both halves: the relay finished and the host's client disconnected or failed.
// The loop that steps the host stops on it before host_destroy.
host_finished :: proc(host: ^Host($G)) -> bool {
	return relay_finished(host.relay) && client_finished(host.client)
}

// Frees the host: its client, its relay (ending its recording), every link they own and the loopback hub.
host_destroy :: proc(host: ^Host($G)) {
	for &link in host.waiting {
		link_close(&link)
	}
	delete(host.waiting)
	client_destroy(host.client)
	relay_destroy(host.relay)
	hub_destroy(host.hub)
	free(host)
}
