// A host: the relay plus the host player's own client in one process, joined by an in-process
// loopback link. Remote players reach the same relay through links added with host_add_link (UDP,
// EOS P2P, ...). Single player is a host with no remote links: the same code path, no special case.
package netcode

@(require) import "unified:sim" // only in generic types and procs: a compile that instantiates none flags it unused

// A session of game G hosted in this process (host_create): the relay's settings and the host player's own. Written
// as a literal at the call (`host_create(&GAME, {seed = 7, setup = Setup{mode = .Hard}}, hooks)`).
Host_Config :: struct($G: typeid) {
	seed:          u64,
	setup:         Maybe(sim.part(G, sim.GAME_SETUP)), // the session's Setup (nil: the game's, Game.setup)
	profile:       sim.part(G, sim.GAME_PROFILE), // the host player's
	ticks:         u32, // 0: endless
	compat:        u64, // build/game id the relay checks (0: sim.compat_of(game))
	player_name:   string, // the host player's display name
	// Optional: the host player's own platform account (the Godot host asks its lobby, Lobby.account), borrowed for the
	// host's lifetime.
	account:       Account,
	recording:     sim.Log_Sink, // optional: the session's input log (Relay_Config.recording)
	desync_detail: bool, // typed desync reports (Relay_Config.desync_detail)
	dev:           bool, // the host player's client attaches a sim.Dev (Client_Config.dev)
}

// The relay and the host player's own client in one process (host_create), joined by a loopback hub. Driven by
// host_step.
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
host_create :: proc(game: ^$G, cfg: Host_Config(G), hooks: Hooks(G)) -> ^Host(G) {
	host := new(Host(G))
	host.hub = hub_create(2)
	compat := cfg.compat if cfg.compat != 0 else sim.compat_of(game)
	host.relay = relay_create(
	game,
	{
		seed          = cfg.seed,
		setup         = cfg.setup,
		ticks         = cfg.ticks,
		start_players = 1,
		compat        = compat,
		local_start   = true, // the only start player is the host's own client
		recording     = cfg.recording,
		desync_detail = cfg.desync_detail,
	},
	)
	host.relay.poll_us = SOLO_POLL_US
	relay_add_link(host.relay, loopback_link(host.hub, 0, cfg.account))
	client_config := Client_Config(G) {
		slot        = 0,
		profile     = cfg.profile,
		compat      = compat,
		player_name = cfg.player_name,
		dev         = cfg.dev,
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
