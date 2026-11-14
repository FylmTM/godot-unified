// A host: the relay plus the host player's own client in one process, joined by an in-process
// loopback link. Remote players reach the same relay through links added with host_add_link (UDP,
// EOS P2P, ...). Single player is a host with no remote links: the same code path, no special case.
package netcode

import "unified:sim"

Host_Config :: struct {
	seed:        u64,
	ticks:       u32, // 0: endless
	compat:      u64, // build/game id the relay checks (0: sim.compat_of(game, content))
	content:     []u8, // the game's content (the level, src/level/SPEC.md); borrowed for the host's lifetime
	name:        string, // for log lines
	player_name: string, // the host player's display name
	poll_us:     i64,
	quiet:       bool,
}

Host :: struct($State, $Input, $World: typeid, $PLAYERS: int) {
	relay:   ^Relay(Input, PLAYERS),
	client:  ^Client(State, Input, World, PLAYERS),
	hub:     ^Hub,
	waiting: [dynamic]Link, // remote links added before the host's player is in (host_add_link)
}

// Creates the relay (its clock starts when the host's client connects, on the first steps) and
// the host's client as player 0.
host_create :: proc(
	game: ^sim.Game($State, $Input, $World, $PLAYERS),
	cfg: Host_Config,
	hooks: Hooks(State, Input, World, PLAYERS),
) -> ^Host(State, Input, World, PLAYERS) {
	host := new(Host(State, Input, World, PLAYERS))
	host.hub = hub_create(2)
	compat := cfg.compat if cfg.compat != 0 else sim.compat_of(game, cfg.content)
	relay_config := Relay_Config {
		tick_hz       = game.tick_hz,
		seed          = cfg.seed,
		ticks         = cfg.ticks,
		start_players = 1,
		compat        = compat,
		content       = sim.content_hash(cfg.content),
		name          = cfg.name,
		poll_us       = cfg.poll_us,
		quiet         = cfg.quiet,
		local_start   = true, // the only start player is the host's own client
	}
	host.relay = relay_create(relay_config, Input, PLAYERS)
	relay_add_link(host.relay, loopback_link(host.hub, 0))
	client_config := Client_Config {
		player      = 0,
		compat      = compat,
		content     = cfg.content,
		name        = cfg.name,
		player_name = cfg.player_name,
		poll_us     = cfg.poll_us,
		quiet       = cfg.quiet,
	}
	host.client = client_create(game, client_config, loopback_link(host.hub, 1), hooks)
	return host
}

// Adds a transport for remote players (the host owns it from now on). The relay serves it once the host's
// own player is in (its clock started), so a remote Hello already waiting on the link (a player who connected
// while the host waited for them) joins as a remote player instead of taking the host's player 0.
host_add_link :: proc(host: ^Host($State, $Input, $World, $PLAYERS), link: Link) {
	if host.relay.started {
		relay_add_link(host.relay, link)
	} else {
		append(&host.waiting, link)
	}
}

// Steps the relay and the host's client; returns the earlier of their wake times.
host_step :: proc(host: ^Host($State, $Input, $World, $PLAYERS), now: i64) -> i64 {
	relay_wake := relay_step(host.relay, now)
	client_wake := client_step(host.client, now)
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
host_stop :: proc(host: ^Host($State, $Input, $World, $PLAYERS), now: i64) {
	relay_stop(host.relay, now)
}

host_finished :: proc(host: ^Host($State, $Input, $World, $PLAYERS)) -> bool {
	status := host.client.status
	return relay_finished(host.relay) && (status == .Disconnected || status == .Failed)
}

host_destroy :: proc(host: ^Host($State, $Input, $World, $PLAYERS)) {
	for &link in host.waiting {
		link_close(&link)
	}
	delete(host.waiting)
	client_destroy(host.client)
	relay_destroy(host.relay)
	hub_destroy(host.hub)
	free(host)
}
