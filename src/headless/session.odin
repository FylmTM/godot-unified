// In-process sessions (the `session` mode, the end-to-end scenarios): a relay plus scripted clients over loopback, each
// client's link wrapped in the network simulator for the chosen profile, stepped by one thread through virtual time
// (as fast as it computes, deterministically). Real UDP on the real clock between processes is the `relay` and
// `client` modes (run_relay, run_client).
package headless

// Used only inside generic procs: @(require) keeps -vet from calling them unused in a program that never
// instantiates those (a game's tests that run the sim offline only).
@(require) import "core:fmt"
@(require) import "core:strings"

import "unified:netcode"
@(require) import "unified:sim"

// What session_run plays: `clients` scripted clients (slots 0 ..< clients) for `ticks` ticks behind `profile`
// (netcode.PROFILES, or one of its own), and optionally a late joiner and churning inputs.
Session_Config :: struct {
	clients:        int,
	profile:        netcode.Profile, // every client's link, both ways
	ticks:          u32,
	seed:           u64,
	late_tick:      u32, // the tick slot `late_slot` joins at (0: everyone starts together)
	late_slot:      int,
	// The late joiner connects once the relay's clock reaches late_tick and asks for no particular join tick, as a
	// player does (its join then takes what a player waits); else it connects ahead, present from late_tick exactly.
	late_as_player: bool,
	// Every slot's scripted input is drawn afresh every tick (the game's script asked for tick × CHURN_SPREAD + slot):
	// rollbacks on most ticks, the bound of real play from above (an analog stick changes every tick; the default
	// script holds an input for its period, all slots switching together). Commands keep the script's ticks.
	churn:          bool,
	// Every client attaches a sim.Dev (Client_Config.dev): its result reports each zone's time per stepped tick.
	dev:            bool,
}

// How far apart churn asks the script for consecutive ticks: a fresh draw for any script period up to it.
CHURN_SPREAD :: 4096

// What session_run reports (session_result_destroy frees it).
Session_Result :: struct($G: typeid) {
	ok:         bool, // every client verified every tick and disconnected cleanly, and nothing desynced
	desyncs:    int, // desyncs the relay detected and reported (a checksum tick on which players differ)
	desync:     netcode.Desync_Report, // the first one, with its typed detail (owned by the result)
	replaced:   int, // inputs the relay replaced (late or missing)
	clients:    []netcode.Client_Result, // one per slot, in slot order
	log:        sim.Input_Log(G), // the relay's official input log (its recording, in memory)
	relay_net:  netcode.Channel_Stats,
	// The late joiner's join (late_tick != 0): from its Hello to Connected (its snapshot restored and checked),
	// virtual µs, and the bytes it received by then (its snapshot, the finalized ticks since it). Its client result
	// has the snapshot's transfer (snapshot_bytes, snapshot_us) and its catch-up (client_steps.max_us).
	join_us:    i64,
	join_bytes: int,
}

// Frees what a session result owns (each client's checksums, the desync detail, the input log) and empties it.
session_result_destroy :: proc(result: ^Session_Result($G)) {
	for client in result.clients {
		delete(client.checksums)
		for zone in client.zones do delete(zone.name)
		delete(client.zones)
	}
	delete(result.clients)
	delete(result.desync.detail)
	sim.log_destroy(&result.log)
	result^ = {}
}

// Scripted hooks: every client samples the game's scripted input (and commands) for its slot.
Scripted_User :: struct($G: typeid) {
	game:  ^G,
	seed:  u64,
	churn: bool, // Session_Config.churn
}

// Client hooks that sample the game's scripted input and commands for the client's slot, so a session's
// clients, the `client` mode and the online modes play without a human.
scripted_hooks :: proc(scripted: ^Scripted_User($G)) -> netcode.Hooks(G) {
	State :: sim.part(G, sim.GAME_STATE)
	Input :: sim.part(G, sim.GAME_INPUT)
	Command :: sim.part(G, sim.GAME_COMMAND)
	hooks := netcode.Hooks(G) {
		user = scripted,
	}
	// No scripted player: the client sends zero Inputs (no sample hook). A client without its sim yet (a late joiner
	// before its snapshot: `state` nil) plays zero Inputs and no commands: the script is never handed a nil state.
	if scripted.game.scripted_input != nil {
		hooks.sample = proc(user: rawptr, local, slot: int, tick: u32, state: ^State) -> Input {
			if state == nil do return {}
			scripted := (^Scripted_User(G))(user)
			// Churn wraps after ~1M ticks (4.5 h at 64 Hz): still a fresh draw every tick.
			asked := scripted.churn ? tick * CHURN_SPREAD + u32(slot) : tick
			return sim.scripted_player_input(scripted.game, scripted.seed, slot, asked, state)
		}
	}
	if scripted.game.scripted_commands != nil {
		hooks.commands = proc(
			user: rawptr,
			local, slot: int,
			tick: u32,
			state: ^State,
			out: ^sim.Command_Out(Command),
		) {
			if state == nil do return
			scripted := (^Scripted_User(G))(user)
			scripted.game.scripted_commands(scripted.seed, slot, tick, state, out)
		}
	}
	return hooks
}

// Steps a client on this thread on the real clock until it is finished, or `timeout_s` passed; true when it verified
// every tick of its session and disconnected cleanly.
run_client :: proc(client: ^netcode.Client($G), timeout_s: f64) -> bool {
	deadline := netcode.now_us() + i64(timeout_s * 1e6)
	for !netcode.client_finished(client) {
		now := netcode.now_us()
		wake := netcode.client_step(client, now)
		if now > deadline {
			fmt.eprintfln(
				"client: timeout (verified %d, predicted %d, local %d)",
				client.verified,
				client.predicted,
				client.local,
			)
			return false
		}
		netcode.sleep_until(wake)
	}
	return client_done(client)
}

// The client verified every tick of its session and disconnected cleanly.
@(private)
client_done :: proc(client: ^netcode.Client($G)) -> bool {
	return client.ticks != 0 && client.verified == client.ticks && client.status == .Disconnected
}

// Steps a relay on this thread on the real clock until it is finished, or `timeout_s` passed.
run_relay :: proc(relay: ^netcode.Relay($G), timeout_s: f64) -> bool {
	deadline := netcode.now_us() + i64(timeout_s * 1e6)
	for !netcode.relay_finished(relay) {
		now := netcode.now_us()
		wake := netcode.relay_step(relay, now)
		if now > deadline {
			fmt.eprintfln("relay: timeout (clock %d, finalized %d)", relay.clock, relay.finalized)
			return false
		}
		netcode.sleep_until(wake)
	}
	return true
}

// How long a session of `ticks` may take on the real clock before it counts as hung: three times its length
// plus a minute (slow CI runners, a late joiner's catch-up).
session_timeout_s :: proc(ticks: u32, tick_hz: int) -> f64 {
	return f64(ticks) / f64(tick_hz) * 3 + 60
}

// Runs a whole session in this process on a virtual clock: a relay and `cfg.clients` scripted clients over loopback,
// each behind the netsim profile. The `session` mode and the end-to-end scenarios use it.
session_run :: proc(game: ^$G, cfg: Session_Config) -> (result: Session_Result(G)) {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	assert(cfg.clients >= 1 && cfg.clients <= PLAYERS)
	assert(cfg.late_tick == 0 || (cfg.late_slot >= 1 && cfg.late_slot < cfg.clients && cfg.late_tick >= 2))
	clock := netcode.Virtual_Clock {
		now = 1_000_000,
	}
	recording: [dynamic]u8
	defer delete(recording)
	relay := netcode.relay_create(game, {
		seed          = cfg.seed,
		ticks         = cfg.ticks,
		start_players = cfg.clients - (cfg.late_tick != 0 ? 1 : 0),
		recording     = sim.log_sink_memory(&recording),
		desync_detail = true,
	})
	hub := netcode.hub_create(cfg.clients + 1)
	netcode.relay_add_link(relay, netcode.loopback_link(hub, 0))
	clients := make([]^netcode.Client(G), cfg.clients)
	defer delete(clients)
	scripted := Scripted_User(G){game, cfg.seed, cfg.churn}
	new_client :: proc(
		game: ^G,
		cfg: Session_Config,
		hub: ^netcode.Hub,
		clock: ^netcode.Virtual_Clock,
		scripted: ^Scripted_User(G),
		slot: int,
		join: u32,
	) -> ^netcode.Client(G) {
		link := netcode.loopback_link(hub, netcode.Peer(slot + 1))
		link = netcode.netsim_wrap(link, cfg.profile, u32(cfg.seed) * 7919 + u32(slot) * 104729 + 17, clock)
		client_cfg := netcode.Client_Config(G) {
			slot      = slot,
			join_tick = join,
			dev       = cfg.dev,
		}
		if game.scripted_profile != nil {
			client_cfg.profile = game.scripted_profile(cfg.seed, slot)
		}
		return netcode.client_create(game, client_cfg, link, scripted_hooks(scripted))
	}
	for slot in 0 ..< cfg.clients {
		if cfg.late_tick == 0 || slot != cfg.late_slot {
			clients[slot] = new_client(game, cfg, hub, &clock, &scripted, slot, 0)
		}
	}
	deadline := clock.now + i64(session_timeout_s(cfg.ticks, game.tick_hz) * 1e6)
	lead := u32(game.tick_hz * 3 / 2) // a joiner connects ~1.5 s before its join tick
	join_from: i64
	result.ok = true
	for {
		if cfg.late_tick != 0 &&
		   clients[cfg.late_slot] == nil &&
		   relay.clock + (cfg.late_as_player ? 0 : lead) >= cfg.late_tick {
			join := cfg.late_as_player ? 0 : cfg.late_tick
			clients[cfg.late_slot] = new_client(game, cfg, hub, &clock, &scripted, cfg.late_slot, join)
			join_from = clock.now
		}
		wake := netcode.relay_step(relay, clock.now)
		running := !netcode.relay_finished(relay)
		for client, slot in clients {
			if client == nil || netcode.client_finished(client) {
				continue
			}
			wake = min(wake, netcode.client_step(client, clock.now))
			if slot == cfg.late_slot && join_from != 0 && result.join_us == 0 && client.status == .Connected {
				result.join_us = clock.now - join_from
				result.join_bytes = client.ch.stats.bytes_recv
			}
			running = true
		}
		if !running {
			break
		}
		if clock.now > deadline {
			fmt.eprintfln("session: timeout at relay clock %d (finalized %d)", relay.clock, relay.finalized)
			result.ok = false
			break
		}
		clock.now = max(wake, clock.now + 1)
	}
	result.desyncs = relay.desyncs
	result.desync = relay.first_desync
	result.desync.detail = strings.clone(relay.first_desync.detail)
	result.ok &&= relay.desyncs == 0
	result.replaced = relay.replaced
	if netcode.relay_end_recording(relay) {
		log_ok: bool
		result.log, log_ok = sim.log_decode(recording[:], G)
		if !log_ok {
			fmt.eprintln("session: the relay's recording does not decode")
			result.ok = false
		}
	}
	result.relay_net = relay.ch.stats
	result.clients = make([]netcode.Client_Result, cfg.clients)
	for client, slot in clients {
		if client == nil {
			result.clients[slot].slot = slot
			result.ok = false
			continue
		}
		result.clients[slot] = netcode.client_result(client)
		result.ok &&= client_done(client)
		netcode.client_destroy(client)
	}
	netcode.relay_destroy(relay)
	netcode.hub_destroy(hub)
	return
}
