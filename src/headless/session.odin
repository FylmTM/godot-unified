// In-process sessions (the `session` mode, the end-to-end scenarios): a relay plus clients over loopback or localhost UDP, each
// client's link wrapped in the network simulator for the chosen profile. On the real clock, the relay
// and every client run on threads of their own that sleep until each step's next deadline; on a
// virtual clock (loopback only), one thread steps them all through test time as fast as it computes,
// deterministically.
package headless

// Used only inside generic procs: @(require) keeps -vet from calling them unused in a program that never
// instantiates those (a game's tests that run the sim offline only).
@(require) import "core:fmt"
@(require) import cnet "core:net"
@(require) import "core:strings"
@(require) import "core:sync"
@(require) import "core:thread"
@(require) import "core:time"

import "unified:netcode"
@(require) import "unified:sim"

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

Session_Result :: struct($Input: typeid, $PLAYERS: int) {
	ok:        bool, // every client verified every tick and disconnected cleanly, and nothing desynced
	desyncs:   int, // desyncs the relay detected and reported (a checksum tick on which players differ)
	desync:    netcode.Desync_Report, // the first one, with its typed detail (owned by the result)
	replaced:  int, // inputs the relay replaced (late or missing)
	clients:   []netcode.Client_Result, // one per player, in player order
	log:       sim.Input_Log(Input, PLAYERS), // the relay's official input log (its recording, in memory)
	relay_net: netcode.Channel_Stats,
}

session_result_destroy :: proc(result: ^Session_Result($Input, $PLAYERS)) {
	for client in result.clients {
		delete(client.checksums)
	}
	delete(result.clients)
	delete(result.desync.detail)
	sim.log_destroy(&result.log)
	result^ = {}
}

// Scripted hooks: every client samples the game's scripted input (and commands) for its player.
Scripted_User :: struct($State, $Input, $World: typeid, $PLAYERS: int) {
	headless: ^Headless(State, Input, World, PLAYERS),
	seed:     u64,
}

scripted_hooks :: proc(
	scripted: ^Scripted_User($State, $Input, $World, $PLAYERS),
) -> netcode.Hooks(State, Input, World, PLAYERS) {
	hooks := netcode.Hooks(State, Input, World, PLAYERS) {
		user = scripted,
		sample = proc(user: rawptr, player: int, tick: u32, state: ^State) -> Input {
			scripted := (^Scripted_User(State, Input, World, PLAYERS))(user)
			return scripted.headless.scripted_input(scripted.seed, player, tick, state)
		},
	}
	if scripted.headless.scripted_commands != nil {
		hooks.commands = proc(user: rawptr, player: int, tick: u32, state: ^State, out: ^sim.Command_Out) {
			scripted := (^Scripted_User(State, Input, World, PLAYERS))(user)
			scripted.headless.scripted_commands(scripted.seed, player, tick, state, out)
		}
	}
	return hooks
}

// A client stepped by run_client until `deadline` (µs); `ok` once it verified every tick.
Client_Task :: struct($State, $Input, $World: typeid, $PLAYERS: int) {
	client:   ^netcode.Client(State, Input, World, PLAYERS),
	deadline: i64,
	ok:       bool,
}

// Steps a client on this thread until the session ends for it (or the deadline).
run_client :: proc(task: ^Client_Task($State, $Input, $World, $PLAYERS)) {
	client := task.client
	for {
		now := netcode.now_us()
		wake := netcode.client_step(client, now)
		if client.status == .Disconnected || client.status == .Failed {
			break
		}
		if now > task.deadline {
			fmt.eprintfln(
				"%s: timeout (verified %d, predicted %d, local %d)",
				client.cfg.name,
				client.verified,
				client.predicted,
				client.local,
			)
			break
		}
		netcode.sleep_until(wake)
	}
	task.ok = client_done(client)
}

// The client verified every tick of its session and disconnected cleanly.
@(private)
client_done :: proc(client: ^netcode.Client($State, $Input, $World, $PLAYERS)) -> bool {
	return client.ticks != 0 && client.verified == client.ticks && client.status == .Disconnected
}

// Steps a relay on this thread until it is finished (or the deadline).
run_relay :: proc(relay: ^netcode.Relay($Input, $PLAYERS), deadline: i64) -> bool {
	for !netcode.relay_finished(relay) {
		now := netcode.now_us()
		wake := netcode.relay_step(relay, now)
		if now > deadline {
			fmt.eprintfln(
				"%s: timeout (clock %d, finalized %d, done %v)",
				relay.cfg.name,
				relay.clock,
				relay.finalized,
				relay.done,
			)
			return false
		}
		netcode.sleep_until(wake)
	}
	return true
}

session_timeout_s :: proc(ticks: u32, tick_hz: int) -> f64 {
	return f64(ticks) / f64(tick_hz) * 3 + 60
}

// A session's relay, transport and clients, before they run.
@(private)
Session :: struct($State, $Input, $World: typeid, $PLAYERS: int) {
	headless: ^Headless(State, Input, World, PLAYERS),
	cfg:      Session_Config,
	relay:    ^netcode.Relay(Input, PLAYERS),
	hub:      ^netcode.Hub,
	port:     int,
	clock:    ^netcode.Virtual_Clock, // nil: real time
	scripted: Scripted_User(State, Input, World, PLAYERS),
	tasks:    []Client_Task(State, Input, World, PLAYERS),
	deadline: i64,
}

session_run :: proc(
	headless: ^Headless($State, $Input, $World, $PLAYERS),
	cfg: Session_Config,
) -> (
	result: Session_Result(Input, PLAYERS),
) {
	clock := netcode.Virtual_Clock {
		now = 1_000_000,
	}
	session := Session(State, Input, World, PLAYERS) {
		headless = headless,
		cfg      = cfg,
		clock    = cfg.virtual ? &clock : nil,
		scripted = {headless, cfg.seed},
	}
	timeout := session_timeout_s(cfg.ticks, headless.game.tick_hz)
	session.deadline = session_now(&session) + i64(timeout * 1e6)
	recording: [dynamic]u8
	defer delete(recording)
	relay_cfg := netcode.Relay_Config {
		tick_hz       = headless.game.tick_hz,
		seed          = cfg.seed,
		ticks         = cfg.ticks,
		start_players = cfg.clients - (cfg.late_player >= 0 ? 1 : 0),
		compat        = sim.compat_of(headless.game, headless.content),
		content       = sim.content_hash(headless.content),
		name          = "relay",
		quiet         = cfg.virtual, // test time: wall-clock log lines would only be noise
		recording     = sim.log_sink_memory(&recording),
		desync_diff   = netcode.desync_diff_of(State),
	}
	session.relay = netcode.relay_create(relay_cfg, Input, PLAYERS)
	if cfg.transport == "udp" {
		link, ok := netcode.udp_listen(0, .Local)
		if !ok {
			fmt.eprintln("session: cannot bind a UDP port")
			netcode.relay_destroy(session.relay)
			return
		}
		session.port = netcode.udp_bound_port(&link)
		netcode.relay_add_link(session.relay, link)
	} else {
		session.hub = netcode.hub_create(cfg.clients + 1)
		netcode.relay_add_link(session.relay, netcode.loopback_link(session.hub, 0))
	}
	session.tasks = make([]Client_Task(State, Input, World, PLAYERS), cfg.clients)
	defer delete(session.tasks)
	result.ok = session_run_virtual(&session) if cfg.virtual else session_run_threads(&session)

	relay := session.relay
	result.desyncs = relay.desyncs
	result.desync = relay.first_desync
	result.desync.detail = strings.clone(relay.first_desync.detail)
	result.ok &&= relay.desyncs == 0
	result.replaced = relay.replaced
	if netcode.relay_end_recording(relay) {
		result.log, _ = sim.log_decode(recording[:], Input, PLAYERS)
	}
	result.relay_net = relay.ch.stats
	result.clients = make([]netcode.Client_Result, cfg.clients)
	for &task, player in session.tasks {
		if task.client == nil {
			result.clients[player].player = player
			result.ok = false
			continue
		}
		result.clients[player] = netcode.client_result(task.client)
		result.ok &&= task.ok
		delete(task.client.cfg.name)
		netcode.client_destroy(task.client)
	}
	netcode.relay_destroy(relay)
	if session.hub != nil {
		netcode.hub_destroy(session.hub)
	}
	return
}

@(private)
session_now :: proc(session: ^Session($State, $Input, $World, $PLAYERS)) -> i64 {
	return session.clock.now if session.clock != nil else netcode.now_us()
}

// The client of `player` (`join`: its join tick, 0 for a starting player).
@(private)
session_client :: proc(
	session: ^Session($State, $Input, $World, $PLAYERS),
	player: int,
	join: u32,
) -> ^netcode.Client(State, Input, World, PLAYERS) {
	cfg := session.cfg
	link: netcode.Link
	if cfg.transport == "udp" {
		ok: bool
		link, ok = netcode.udp_connect({cnet.IP4_Loopback, session.port})
		assert(ok, "udp_connect failed")
	} else {
		link = netcode.loopback_link(session.hub, netcode.Peer(player + 1))
	}
	link_seed := u32(cfg.seed) * 7919 + u32(player) * 104729 + 17
	link = netcode.netsim_wrap(link, cfg.profile, link_seed, session.clock)
	client_cfg := netcode.Client_Config {
		player    = player,
		join_tick = join,
		content   = session.headless.content,
		name      = fmt.aprintf("client%d", player),
		quiet     = session.clock != nil,
	}
	return netcode.client_create(session.headless.game, client_cfg, link, scripted_hooks(&session.scripted))
}

// Real time: the relay and each client on a thread of its own.
@(private)
session_run_threads :: proc(session: ^Session($State, $Input, $World, $PLAYERS)) -> bool {
	Relay_Task :: struct {
		relay:    ^netcode.Relay(Input, PLAYERS),
		deadline: i64,
		ok:       bool,
	}
	relay_task := Relay_Task{session.relay, session.deadline, false}
	relay_thread := thread.create_and_start_with_poly_data(&relay_task, proc(task: ^Relay_Task) {
		task.ok = run_relay(task.relay, task.deadline)
	})
	cfg := session.cfg
	threads := make([]^thread.Thread, cfg.clients)
	defer delete(threads)
	for player in 0 ..< cfg.clients {
		if player == cfg.late_player {
			continue
		}
		session.tasks[player] = {session_client(session, player, 0), session.deadline, false}
		threads[player] = thread.create_and_start_with_poly_data(&session.tasks[player], run_client)
	}
	if cfg.late_player >= 0 {
		// Connect the joiner ~1.5 s before its join tick, so the relay seats it in time.
		lead := u32(session.headless.game.tick_hz * 3 / 2)
		for netcode.relay_clock(session.relay) + lead < cfg.late_tick && netcode.now_us() < session.deadline {
			time.sleep(5 * time.Millisecond)
		}
		player := cfg.late_player
		session.tasks[player] = {session_client(session, player, cfg.late_tick), session.deadline, false}
		sync.atomic_thread_fence(.Seq_Cst)
		threads[player] = thread.create_and_start_with_poly_data(&session.tasks[player], run_client)
	}
	for player in 0 ..< cfg.clients {
		thread.join(threads[player])
		thread.destroy(threads[player])
	}
	thread.join(relay_thread)
	thread.destroy(relay_thread)
	return relay_task.ok
}

// Virtual time: one thread steps the relay and every client, jumping to the earliest wake time.
@(private)
session_run_virtual :: proc(session: ^Session($State, $Input, $World, $PLAYERS)) -> bool {
	cfg := session.cfg
	clock := session.clock
	for player in 0 ..< cfg.clients {
		if player != cfg.late_player {
			session.tasks[player] = {session_client(session, player, 0), session.deadline, false}
		}
	}
	lead := u32(session.headless.game.tick_hz * 3 / 2)
	for {
		late := cfg.late_player
		if late >= 0 && session.tasks[late].client == nil && session.relay.clock + lead >= cfg.late_tick {
			session.tasks[late] = {session_client(session, late, cfg.late_tick), session.deadline, false}
		}
		wake := netcode.relay_step(session.relay, clock.now)
		running := !netcode.relay_finished(session.relay)
		for &task in session.tasks {
			if task.client == nil || task.client.status == .Disconnected || task.client.status == .Failed {
				continue
			}
			wake = min(wake, netcode.client_step(task.client, clock.now))
			running = true
		}
		if !running {
			break
		}
		if clock.now > session.deadline {
			fmt.eprintfln(
				"session: timeout at relay clock %d (finalized %d)",
				session.relay.clock,
				session.relay.finalized,
			)
			return false
		}
		clock.now = max(wake, clock.now + 1)
	}
	for &task in session.tasks {
		if task.client != nil {
			task.ok = client_done(task.client)
		}
	}
	return true
}
