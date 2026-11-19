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
	relay:        ^Relay(G),
	client:       ^Client(G),
	hub:          ^Hub,
	waiting:      [dynamic]Link, // remote links added before the host's player is in (host_add_link)
	linked:       bool, // a remote link was added (host_solo); it also ends a single-player pause
	// The single-player pause (host_set_paused): the relay and the client run on session time, `now` less the time
	// spent paused, so from their side no time passed.
	paused:       bool,
	paused_at:    i64, // the `now` the pause began
	paused_total: i64, // µs spent paused before the current pause
}

// Whether the host never had a remote link: single player as it started (a pause that stops the clock is legal only
// then; opening the session to friends adds the first link).
host_solo :: proc(host: ^Host($G)) -> bool {
	return !host.linked
}

// Opens or closes the hosted session to new players (relay_set_open): open_online / close_online.
host_set_open :: proc(host: ^Host($G), open: bool) {
	relay_set_open(host.relay, open)
}

// Gives the host's own player its platform account once the lobby knows it (a single-player session opened to a
// lobby later: host_create had none), and tells every client (relay_set_account).
host_set_account :: proc(host: ^Host($G), account: Account, now: i64) {
	for &seat in host.client.locals {
		if seat.state == .Seated do relay_set_account(host.relay, seat.member, account, now)
	}
}

// The steps' poll while a host has no remote links (single player): nothing arrives from outside, so a step runs at
// its deadlines (the next tick of the relay or the client) and this is only the fallback before the clock starts.
@(private)
SOLO_POLL_US :: 50_000

// Creates the relay (its clock starts when the host's client connects, on the first steps) and
// the host's client in slot 0.
host_create :: proc(game: ^$G, cfg: Host_Config(G), hooks: Hooks(G)) -> ^Host(G) {
	host := new(Host(G))
	host.hub = hub_create(2)
	compat := sim.compat_of(game)
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
	host.linked = true
	host.relay.poll_us = POLL_US // datagrams from outside: poll for them
	if host.relay.started {
		relay_add_link(host.relay, link)
	} else {
		append(&host.waiting, link)
	}
}

// Steps the relay and the host's client; returns the earlier of their wake times. What one of them sends the other
// is taken in the same call (they talk in-process), so the host's own inputs and finalized ticks never wait for a
// wake, and a single-player host wakes only at its deadlines. `real_now` and the wake are the caller's clock; the relay
// and the client run on session time (host_session_time), which a single-player pause stops (host_set_paused).
host_step :: proc(host: ^Host($G), real_now: i64) -> i64 {
	if host.paused && host.linked do host_set_paused(host, false, real_now)
	if host.paused do return real_now + PAUSE_POLL_US
	now := real_now - host.paused_total // session time: the relay and the client never see a pause
	wake := host_step_at(host, now)
	if host.relay.started && len(host.waiting) > 0 {
		for link in host.waiting {
			relay_add_link(host.relay, link)
		}
		clear(&host.waiting)
		wake = now // serve them at once
	}
	return wake + host.paused_total
}

// The relay and the client stepped at session time `now`, with what they send each other taken at once; returns
// the earlier of their wakes (session time).
@(private)
host_step_at :: proc(host: ^Host($G), now: i64) -> i64 {
	relay_wake := relay_step(host.relay, now)
	client_wake := client_step(host.client, now)
	for _ in 0 ..< 4 { 	// inputs -> finalized tick -> its ack: a few rounds at most
		if hub_queued(host.hub, 0) == 0 && hub_queued(host.hub, 1) == 0 {
			break
		}
		relay_wake = relay_step(host.relay, now)
		client_wake = client_step(host.client, now)
	}
	return min(relay_wake, client_wake)
}

// Steps a paused single-player session by exactly `ticks` ticks and leaves it paused: the session time moves on in
// quarter-tick steps until the host's client has computed `ticks` more ticks (its predicted tick, the one it shows,
// which the relay's finalized ticks may keep a tick ahead of its scheduler), sampling its input as a running session
// does, so the log is one an unpaused run with the same inputs records; then the session time stands still again.
// Returns the ticks it stepped: fewer only at the session's end, 0 when the host is not paused (a pause is single
// player only: host_set_paused) or its clock has not started.
host_advance :: proc(host: ^Host($G), ticks: u32) -> u32 {
	client := host.client
	if !host.paused || host.linked || !client.started || ticks == 0 do return 0
	from := client.predicted
	quantum := max(i64(client.tm.tick_us / 4), 1) // under a tick: one tick at most per step
	// the scheduler's period is within 2% of a tick: a few quanta per tick, and a backstop for a session that ended
	for _ in 0 ..< int(ticks) * 8 + 16 {
		if client.predicted - from >= ticks || at_end(client, client.predicted) do break
		host.paused_total -= quantum // the frozen session time moves on
		host_step_at(host, host.paused_at - host.paused_total)
	}
	return client.predicted - from
}

// host_step's wake while paused: how soon a loop that sleeps until it notices a resume.
@(private)
PAUSE_POLL_US :: 10_000

// Pauses or resumes a single-player session (`now` on the clock host_step is given): while paused host_step steps
// nothing, and on resume the relay and the client go on from where they stopped, as if no time had passed. It is exact
// because nobody else waits: the same ticks get the same inputs, and the log is byte for byte the one an unpaused run
// records. Refused once the host has a remote link (online a pause is state, src/sim/README.md, Game time), and a link
// added while paused resumes at the next host_step. Returns whether the host is paused now.
host_set_paused :: proc(host: ^Host($G), paused: bool, now: i64) -> bool {
	if paused == host.paused do return host.paused
	if paused {
		if !host_solo(host) do return false
		host.paused, host.paused_at = true, now
	} else {
		host.paused = false
		host.paused_total += now - host.paused_at
	}
	return host.paused
}

// The session time at `now`: `now` less the time spent paused (frozen while paused). What the relay's and the
// client's times (a tick's due time) are measured on.
host_session_time :: proc(host: ^Host($G), now: i64) -> i64 {
	return (host.paused_at if host.paused else now) - host.paused_total
}

// Ends the session for everyone. Keep stepping until host_finished.
host_stop :: proc(host: ^Host($G), now: i64) {
	host_set_paused(host, false, now) // a stop while paused resumes first
	relay_stop(host.relay, host_session_time(host, now))
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
