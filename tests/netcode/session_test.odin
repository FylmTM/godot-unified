// L2 netcode tests on the toy, over loopback links with the network simulator, every participant stepped from one
// thread on a virtual clock (to the earliest wake any of them asks for). One harness: a host (relay + its own client in
// slot 0) or a plain relay, and remote clients.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:sim"

Client :: netcode.Client(toy.Game)
Host :: netcode.Host(toy.Game)
Relay :: netcode.Relay(toy.Game)
Hooks :: netcode.Hooks(toy.Game)
Client_Config :: netcode.Client_Config(toy.Game)

SEED :: 5
HOST_COLOR :: 7 // the host player's Profile (net_make)

// The Profile colour of the client on hub endpoint `endpoint` (net_join): each client's own, so a test can tell whose
// Profile reached a player.
endpoint_color :: proc(endpoint: int) -> u8 {
	return u8(10 + endpoint)
}

Watch :: struct {
	frames:        int,
	verified_upto: u32,
	in_order:      bool,
	events:        int,
	statuses:      [dynamic]netcode.Status,
	// verified_state: calls, and whether every one found the sim on the newest verified tick with its saved state
	states:        int,
	states_wrong:  int,
}

hooks_for :: proc(watch: ^Watch) -> Hooks {
	watch.in_order = true
	return {
		user = watch,
		sample = proc(user: rawptr, local, slot: int, tick: u32, state: ^toy.State) -> toy.Input {
			return toy.scripted_input(SEED, slot, tick)
		},
		commands = proc(
			user: rawptr,
			local, slot: int,
			tick: u32,
			state: ^toy.State,
			out: ^sim.Command_Out(toy.Command),
		) {
			toy.burst_commands(SEED, slot, tick, nil, out)
		},
		frame = proc(user: rawptr, simulation: ^toy.Sim, frame: netcode.Frame_Info) {
			watch := (^Watch)(user)
			watch.frames += 1
			assert(simulation.tick == frame.tick && frame.resim_from <= frame.tick && frame.verified <= frame.tick)
		},
		verified = proc(
			user: rawptr,
			simulation: ^toy.Sim,
			tick: u32,
			inputs: ^sim.Inputs(toy.Game),
			events: []sim.Raw_Event,
		) {
			watch := (^Watch)(user)
			if tick != watch.verified_upto + 1 && watch.verified_upto != 0 {
				watch.in_order = false
			}
			watch.verified_upto = tick
			watch.events += len(events)
		},
		status = proc(user: rawptr, status: netcode.Status, detail: string) {
			watch := (^Watch)(user)
			append(&watch.statuses, status)
		},
	}
}

// The verified_state hook a Net's watches get when it asks (Net.states): only hooks whose user is still the Watch
// (callers of hooks_for may replace the user, and with it every hook that reads it).
watch_verified_state :: proc(user: rawptr, simulation: ^toy.Sim) {
	watch := (^Watch)(user)
	watch.states += 1
	saved := sim.state_at(simulation, simulation.tick)
	if simulation.tick != watch.verified_upto || (saved != nil && saved^ != simulation.state) {
		watch.states_wrong += 1
	}
}

Net :: struct {
	clock:     netcode.Virtual_Clock,
	hub:       ^netcode.Hub, // remote side: endpoint 0 is the relay
	host:      ^Host, // nil: a plain relay
	relay:     ^Relay, // the host's, or the plain one
	clients:   [dynamic]^Client, // the remote clients
	watch:     [8]Watch, // [0]: the host's own client; [k]: the k-th remote
	recording: [dynamic]u8, // the relay's recording
	log:       sim.Input_Log(toy.Game), // decoded by net_log
	states:    bool, // the watches count verified_state calls (set before net_make)
}

// A Net's hooks for one of its watches: hooks_for's, with verified_state when the Net asks.
net_hooks :: proc(session: ^Net, watch: ^Watch) -> Hooks {
	hooks := hooks_for(watch)
	if session.states do hooks.verified_state = watch_verified_state
	return hooks
}

// The relay's recording so far, decoded (valid until the next call).
net_log :: proc(session: ^Net) -> ^sim.Input_Log(toy.Game) {
	sim.log_destroy(&session.log)
	ok: bool
	session.log, ok = sim.log_decode(session.recording[:], toy.Game)
	assert(ok, "the recording does not decode")
	return &session.log
}

// A host with `remotes` remote clients under `wan`; `record`: the relay records the session (net_log); `game`: the
// host's game (default the toy; the remotes play the toy); `hooks`: its own client's (default its watch's);
// `linked`: its relay listens on the hub (else single player until the test adds the link).
net_make :: proc(
	session: ^Net,
	ticks: u32,
	remotes: int,
	record := true,
	setup := toy.Setup{},
	game: ^toy.Game = nil,
	hooks: Maybe(Hooks) = nil,
	linked := true,
) {
	session.clock.now = 1_000_000
	session.hub = netcode.hub_create(8)
	session.host = netcode.host_create(game != nil ? game : &toy.GAME, {
			seed = SEED,
			setup = setup,
			ticks = ticks,
			player_name = "Ada",
			profile = {color = HOST_COLOR},
			recording = record ? sim.log_sink_memory(&session.recording) : {},
			desync_detail = true,
		}, hooks.? or_else net_hooks(session, &session.watch[0]))
	session.relay = session.host.relay
	if linked do netcode.host_add_link(session.host, netcode.loopback_link(session.hub, 0))
	for _ in 0 ..< remotes {
		net_join(session)
	}
}

// A plain relay (no host player) whose clock starts once `start_players` clients connected; `desync_detail`: typed
// desync reports; `record`: it records the session (net_log); `game`: its game (default the toy).
net_make_relay :: proc(
	session: ^Net,
	start_players: int,
	ticks: u32,
	desync_detail := false,
	record := false,
	game: ^toy.Game = nil,
) {
	session.clock.now = 1_000_000
	session.hub = netcode.hub_create(8)
	session.relay = netcode.relay_create(game != nil ? game : &toy.GAME, {
		seed          = SEED,
		ticks         = ticks,
		start_players = start_players,
		desync_detail = desync_detail,
		recording     = record ? sim.log_sink_memory(&session.recording) : {},
	})
	netcode.relay_add_link(session.relay, netcode.loopback_link(session.hub, 0))
}

// The connection seated in `slot`, as the relay keeps it (a zero record when nobody sits there).
conn_in :: proc(relay: ^netcode.Relay($G), slot: int) -> netcode.Relay_Conn {
	conn := netcode.relay_conn(relay, slot)
	return conn^ if conn != nil else {provider = -1, snap_from = -1, locals = -1, report_from = netcode.NO_REPORTS}
}

// The lowest slot of the connection the relay asked for the snapshot of the joiner in `slot` (-1: none asked).
provider_slot :: proc(relay: ^netcode.Relay($G), slot: int) -> int {
	provider := conn_in(relay, slot).provider
	if provider < 0 do return -1
	for &seat, other in relay.seats {
		if seat.conn == provider do return other
	}
	return -1
}

// Whether the connection seated in `provider` is among those refused for the joiner in `slot`.
refused_slot :: proc(relay: ^netcode.Relay($G), slot: int, provider: int) -> bool {
	conn := relay.seats[provider].conn
	return conn >= 0 && int(conn) in conn_in(relay, slot).refused
}

// The link of a remote client: hub endpoint `endpoint` (0: the next remote's) of `hub` (default the session's)
// behind a network simulator of `raw` (default the built-in `profile`; an ideal one is the bare loopback link) on the
// session's clock, seeded with `seed` (0: by endpoint). `live`: a live netsim the test sets (netsim_set), returned.
net_link :: proc(
	session: ^Net,
	profile := netcode.Network.Wan,
	raw: Maybe(netcode.Profile) = nil,
	seed: u32 = 0,
	live := false,
	hub: ^netcode.Hub = nil,
	endpoint := 0,
) -> (
	link: netcode.Link,
	netsim: ^netcode.Net_Sim,
) {
	endpoint := endpoint != 0 ? endpoint : len(session.clients) + 1
	inner := netcode.loopback_link(hub != nil ? hub : session.hub, netcode.Peer(endpoint))
	seed := seed != 0 ? seed : u32(endpoint) * 7919
	if live do return netcode.netsim_live(inner, seed, &session.clock)
	return netcode.netsim_wrap(inner, raw.? or_else netcode.PROFILES[profile], seed, &session.clock), nil
}

// A remote client asking for `slot` (-1: any) as `name` (default Grace for the first remote, then Linus) with
// `token`, its Profile its endpoint's colour (`config` replaces all of it), playing `game` (default the toy), on
// `link` (default net_link's of `profile`, `raw`, `seed`, `hub` and `endpoint`), with `hooks` (default its watch's:
// session.watch[endpoint], the last one shared past it).
net_join :: proc(
	session: ^Net,
	slot := -1,
	profile := netcode.Network.Wan,
	game: ^toy.Game = nil,
	name := "",
	token := netcode.Token{},
	raw: Maybe(netcode.Profile) = nil,
	config: Maybe(Client_Config) = nil,
	link: Maybe(netcode.Link) = nil,
	hooks: Maybe(Hooks) = nil,
	seed: u32 = 0,
	hub: ^netcode.Hub = nil,
	endpoint := 0,
) -> ^Client {
	endpoint := endpoint != 0 ? endpoint : len(session.clients) + 1
	client_link, has_link := link.?
	if !has_link do client_link, _ = net_link(session, profile, raw, seed, false, hub, endpoint)
	client_config, has_config := config.?
	if !has_config {
		client_config = {
			slot = slot,
			player_name = name != "" ? name : endpoint == 1 ? "Grace" : "Linus",
			profile = {color = endpoint_color(endpoint)},
			token = token,
		}
	}
	watch := &session.watch[min(endpoint, len(session.watch) - 1)]
	client := netcode.client_create(
		game != nil ? game : &toy.GAME,
		client_config,
		client_link,
		hooks.? or_else net_hooks(session, watch),
	)
	append(&session.clients, client)
	return client
}

net_destroy :: proc(session: ^Net) {
	for client in session.clients {
		netcode.client_destroy(client)
	}
	delete(session.clients)
	if session.host != nil {
		netcode.host_destroy(session.host)
	} else {
		netcode.relay_destroy(session.relay)
	}
	netcode.hub_destroy(session.hub)
	for &watch in session.watch {
		delete(watch.statuses)
	}
	delete(session.recording)
	sim.log_destroy(&session.log)
}

// Steps everyone for `seconds` of virtual time, or until `done` says so: each round steps the relay (or host) and
// every client, then jumps to the earliest wake any of them asked for. Remote client `hitched` (an index into
// session.clients) is not stepped: its process hitches, what arrives waits in its socket. `each` watches the session
// after every round (with `user`, the test's own record) and ends the run when it returns true.
net_run :: proc(
	session: ^Net,
	seconds: f64,
	done: proc(session: ^Net) -> bool = nil,
	hitched := -1,
	each: proc(session: ^Net, user: rawptr) -> bool = nil,
	user: rawptr = nil,
) {
	end := session.clock.now + i64(seconds * 1e6)
	for session.clock.now < end {
		now := session.clock.now
		wake := session.host != nil ? netcode.host_step(session.host, now) : netcode.relay_step(session.relay, now)
		for client, i in session.clients {
			if i == hitched do continue
			wake = min(wake, netcode.client_step(client, now))
		}
		stop := each != nil && each(session, user)
		if stop || (done != nil && done(session)) {
			return
		}
		session.clock.now = clamp(wake, now + 1, end)
	}
}

all_done :: proc(session: ^Net) -> bool {
	finished := session.host != nil ? netcode.host_finished(session.host) : netcode.relay_finished(session.relay)
	for client in session.clients {
		finished &&= netcode.client_finished(client)
	}
	return finished
}

// Every pair of clients (the host's own among them) agrees on every checksummed tick both verified, and the relay saw
// no desync.
expect_agree :: proc(t: ^testing.T, session: ^Net) {
	clients := make([dynamic]^Client, context.temp_allocator)
	if session.host != nil do append(&clients, session.host.client)
	append(&clients, ..session.clients[:])
	for client, i in clients {
		for other in clients[i + 1:] {
			for entry in client.checksums {
				for other_entry in other.checksums {
					if entry[0] == other_entry[0] {
						testing.expectf(
							t,
							entry[1] == other_entry[1],
							"slots %d and %d disagree at tick %d",
							client.slot,
							other.slot,
							entry[0],
						)
					}
				}
			}
		}
	}
	testing.expect_value(t, session.relay.desyncs, 0)
}

@(test)
host_and_two_remote_clients :: proc(t: ^testing.T) {
	session := Net {
		states = true,
	}
	net_make(&session, 640, 2)
	defer net_destroy(&session)
	net_run(&session, 30, all_done)
	testing.expect(t, all_done(&session))
	testing.expect_value(t, session.host.client.verified, 640)
	// verified_state: the sim on the newest verified tick, every call (remote clients under wan mispredict and roll back)
	for watch in session.watch[:3] {
		testing.expectf(
			t,
			watch.states > 0 && watch.states_wrong == 0,
			"verified_state %d, %d wrong",
			watch.states,
			watch.states_wrong,
		)
	}
	testing.expect_value(t, len(session.host.client.checksums), 640 / 16)
	for client in session.clients {
		testing.expect_value(t, client.verified, 640)
		testing.expect(t, client.first_tick > 1) // remote players join a running session
		testing.expect(t, len(client.checksums) > 0 && client.checksums[0][0] >= u64(client.first_tick))
	}
	expect_agree(t, &session)
	testing.expect(t, session.clients[0].stats.rollbacks > 0) // wan profile: predictions miss
	for k in 0 ..= 2 {
		watch := &session.watch[k]
		testing.expect(t, watch.in_order)
		testing.expect_value(t, watch.verified_upto, 640)
		testing.expect(t, watch.frames > 0)
		testing.expect(
			t,
			len(watch.statuses) >= 3 &&
			watch.statuses[1] == .Connected &&
			watch.statuses[len(watch.statuses) - 1] == .Disconnected,
		)
	}
	// The relay's log replays to the verified result.
	simulation := sim.create(&toy.GAME, SEED)
	defer sim.destroy(simulation)
	input_log := net_log(&session)
	for k in 0 ..< len(input_log.ticks) {
		inputs := sim.log_inputs(input_log, k)
		sim.step(simulation, &inputs)
	}
	testing.expect_value(t, simulation.tick, 640)
	testing.expect_value(t, sim.checksum(simulation), session.host.client.chk[(640 / 16) % netcode.CHK_RING].value)
}

@(test)
late_join_and_leave :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 1) // endless
	defer net_destroy(&session)
	net_run(&session, 3)
	testing.expect_value(t, session.clients[0].status, netcode.Status.Connected)
	late := net_join(&session)
	net_run(&session, 4)
	testing.expect_value(t, late.status, netcode.Status.Connected)
	testing.expect_value(t, late.slot, 2)
	testing.expect(t, late.first_tick > 64 * 3)
	testing.expect(t, late.verified > late.first_tick)
	testing.expect(t, len(net_log(&session).commands) > 0) // the snapshot's history had commands
	expect_agree(t, &session)
	// The roster: every client knows every member, by member id (in the order they came), with its slot.
	for client in ([]^Client{session.host.client, session.clients[0], late}) {
		names := [?]string{"Ada", "Grace", "Linus"}
		for name, k in names {
			entry := netcode.client_member(client, u16(k + 1))
			if !testing.expect(t, entry != nil) do continue
			testing.expect_value(t, netcode.text_string(&entry.name), name)
			testing.expect(t, entry.connected && int(entry.slot) == k)
		}
		testing.expect(t, netcode.client_member(client, 4) == nil)
	}
	// The first remote leaves: it disappears from `present` and the others go on.
	netcode.client_stop(session.clients[0], session.clock.now)
	net_run(&session, 2)
	testing.expect_value(t, session.clients[0].status, netcode.Status.Disconnected)
	input_log := net_log(&session)
	last := input_log.ticks[len(input_log.ticks) - 1]
	testing.expect(t, 1 not_in last.present)
	testing.expect(t, 0 in last.present && 2 in last.present)
	// Its player is free again for the next joiner.
	again := net_join(&session, profile = .Ideal)
	net_run(&session, 3)
	testing.expect_value(t, again.slot, 1)
	testing.expect_value(t, again.status, netcode.Status.Connected)
	expect_agree(t, &session)
	netcode.host_stop(session.host, session.clock.now)
	net_run(&session, 5, all_done)
	testing.expect(t, all_done(&session))
	testing.expect(t, late.verified > 64 * 9)
}

@(test)
single_player_host :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 128, 0)
	defer net_destroy(&session)
	net_run(&session, 10, all_done)
	testing.expect(t, all_done(&session))
	testing.expect_value(t, session.host.client.verified, 128)
	testing.expect_value(t, session.host.client.stats.rollbacks, 0)
	testing.expect_value(t, session.host.relay.replaced, 0)
}

// A host with no remote links (single player) wakes at its deadlines only, about twice a tick (the relay's tick
// and the client's), and verifies every tick on time: its relay and client hand each other datagrams in the same
// host_step. Once a remote link is added it polls again (POLL_US).
@(test)
single_player_wakes_at_its_deadlines :: proc(t: ^testing.T) {
	watch: Watch
	defer delete(watch.statuses)
	host := netcode.host_create(&toy.GAME, {seed = SEED}, hooks_for(&watch))
	defer netcode.host_destroy(host)
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	clock := netcode.Virtual_Clock {
		now = 1_000_000,
	}
	run :: proc(host: ^Host, clock: ^netcode.Virtual_Clock, seconds: i64) -> (steps: int) {
		end := clock.now + seconds * 1_000_000
		for clock.now < end {
			wake := netcode.host_step(host, clock.now)
			clock.now = max(wake, clock.now + 1)
			steps += 1
		}
		return
	}
	run(host, &clock, 1) // the clock starts
	from := host.client.verified
	steps := run(host, &clock, 4)
	verified := int(host.client.verified - from)
	testing.expectf(t, steps <= 3 * 4 * toy.GAME.tick_hz, "%d steps in 4 s", steps)
	testing.expectf(t, verified >= 4 * toy.GAME.tick_hz - 1, "%d ticks verified in 4 s", verified)
	testing.expect_value(t, host.relay.replaced, 0)
	testing.expect_value(t, host.client.delay, 1)
	testing.expect_value(t, host.client.stats.stall_ticks, 0)
	netcode.host_add_link(host, netcode.loopback_link(hub, 0))
	steps = run(host, &clock, 1)
	testing.expectf(t, steps >= 900, "%d steps in 1 s with a remote link", steps)
}

@(test)
taken_slot_is_rejected :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	client := net_join(&session, 0, .Ideal) // the host's own slot
	net_run(&session, 1)
	testing.expect_value(t, client.status, netcode.Status.Failed)
	testing.expect_value(t, client.detail, "that slot is taken")
}

// A remote Hello already waiting when the host starts (a player who connected while the host waited for them) joins
// as a remote player: the host's own player always gets slot 0.
@(test)
a_hello_before_the_host_starts_joins_as_a_remote :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	remote := net_join(&session, profile = .Ideal)
	netcode.client_step(remote, session.clock.now) // its Hello waits on the relay's link before the host's first step
	net_run(&session, 3)
	testing.expect_value(t, session.host.client.slot, 0)
	testing.expect_value(t, remote.slot, 1)
	testing.expect_value(t, remote.status, netcode.Status.Connected)
	expect_agree(t, &session)
}

// At the prediction cap a rollback's target is often a predicted tick that wasn't saved (every
// PREDICTED_SAVE_EVERY-th is): the client restores the one before it, which the ring still holds at full depth, and
// re-steps from there. A round trip past the cap keeps the client there for the whole run.
@(test)
rollbacks_at_the_cap_restore_past_unsaved_ticks :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	far := netcode.Profile {
		name    = "far",
		latency = 180_000,
		jitter  = 20_000,
		loss    = 20,
	}
	client := net_join(&session, raw = far, seed = 11)
	net_run(&session, 12)
	testing.expect_value(t, client.status, netcode.Status.Connected)
	testing.expect(t, client.stats.stall_ticks > 0, "never at the cap")
	testing.expect_value(t, int(client.stats.depth_max), int(client.tm.prediction_cap))
	testing.expect(t, client.stats.rollbacks > 50)
	expect_agree(t, &session)
}
