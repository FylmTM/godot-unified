// L2 netcode tests: a host (relay + its own client) and remote clients over loopback links with
// the network simulator, all stepped from one thread on a virtual clock, on the toy game.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:sim"

Client :: netcode.Client(toy.State, toy.Input, toy.World, toy.PLAYERS)
Host :: netcode.Host(toy.State, toy.Input, toy.World, toy.PLAYERS)
Hooks :: netcode.Hooks(toy.State, toy.Input, toy.World, toy.PLAYERS)

SEED :: 5

Watch :: struct {
	frames:        int,
	verified_upto: u32,
	in_order:      bool,
	events:        int,
	statuses:      [dynamic]netcode.Status,
}

hooks_for :: proc(watch: ^Watch) -> Hooks {
	watch.in_order = true
	return {
		user = watch,
		sample = proc(user: rawptr, player: int, tick: u32, state: ^toy.State) -> toy.Input {
			return toy.scripted_input(SEED, player, tick)
		},
		commands = proc(user: rawptr, player: int, tick: u32, state: ^toy.State, out: ^sim.Command_Out) {
			toy.scripted_commands(SEED, player, tick, out)
		},
		frame = proc(user: rawptr, simulation: ^toy.Sim, frame: netcode.Frame_Info) {
			watch := (^Watch)(user)
			watch.frames += 1
			assert(
				sim.state_at(simulation, frame.tick) != nil &&
				frame.resim_from <= frame.tick &&
				frame.verified <= frame.tick,
			)
		},
		verified = proc(user: rawptr, simulation: ^toy.Sim, tick: u32, events: []sim.Raw_Event) {
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

Net :: struct {
	clock:     netcode.Virtual_Clock,
	hub:       ^netcode.Hub, // remote side: endpoint 0 is the relay
	host:      ^Host,
	clients:   [dynamic]^Client,
	watch:     [8]Watch,
	recording: [dynamic]u8, // the relay's recording
	log:       sim.Input_Log(toy.Input, toy.PLAYERS), // decoded by net_log
}

// The relay's recording so far, decoded (valid until the next call).
net_log :: proc(session: ^Net) -> ^sim.Input_Log(toy.Input, toy.PLAYERS) {
	sim.log_destroy(&session.log)
	ok: bool
	session.log, ok = sim.log_decode(session.recording[:], toy.Input, toy.PLAYERS)
	assert(ok, "the recording does not decode")
	return &session.log
}

net_make :: proc(session: ^Net, ticks: u32, remotes: int) {
	session.clock.now = 1_000_000
	session.hub = netcode.hub_create(8)
	session.host = netcode.host_create(&toy.GAME, {
			seed          = SEED,
			ticks         = ticks,
			name          = "host",
			player_name   = "Ada",
			quiet         = true,
			recording     = sim.log_sink_memory(&session.recording),
			desync_detail = true,
		}, hooks_for(&session.watch[0]))
	netcode.host_add_link(session.host, netcode.loopback_link(session.hub, 0))
	for _ in 0 ..< remotes {
		net_join(session, netcode.PROFILES[1])
	}
}

net_join :: proc(session: ^Net, profile: netcode.Profile, player := -1) -> ^Client {
	endpoint := len(session.clients) + 1
	link := netcode.netsim_wrap(
		netcode.loopback_link(session.hub, netcode.Peer(endpoint)),
		profile,
		u32(endpoint) * 7919,
		&session.clock,
	)
	client := netcode.client_create(&toy.GAME, {
			slot        = player,
			name        = "remote",
			player_name = endpoint == 1 ? "Grace" : "Linus",
			quiet       = true,
		}, link, hooks_for(&session.watch[endpoint]))
	append(&session.clients, client)
	return client
}

net_destroy :: proc(session: ^Net) {
	for client in session.clients {
		netcode.client_destroy(client)
	}
	delete(session.clients)
	netcode.host_destroy(session.host)
	netcode.hub_destroy(session.hub)
	for &watch in session.watch {
		delete(watch.statuses)
	}
	delete(session.recording)
	sim.log_destroy(&session.log)
}

// Steps everything every 250 µs of virtual time for `seconds`, or until `done` says so.
net_run :: proc(session: ^Net, seconds: f64, done: proc(session: ^Net) -> bool = nil) {
	end := session.clock.now + i64(seconds * 1e6)
	for session.clock.now < end {
		session.clock.now += 250
		netcode.host_step(session.host, session.clock.now)
		for client in session.clients {
			netcode.client_step(client, session.clock.now)
		}
		if done != nil && done(session) {
			return
		}
	}
}

all_done :: proc(session: ^Net) -> bool {
	if !netcode.host_finished(session.host) {
		return false
	}
	for client in session.clients {
		if client.status != .Disconnected && client.status != .Failed {
			return false
		}
	}
	return true
}

// Every pair of clients agrees on every checksummed tick both verified.
expect_agree :: proc(t: ^testing.T, session: ^Net) {
	host_checksums := session.host.client.checksums[:]
	testing.expect(t, len(host_checksums) > 0)
	for client in session.clients {
		for entry in client.checksums {
			for host_entry in host_checksums {
				if host_entry[0] == entry[0] {
					testing.expectf(
						t,
						host_entry[1] == entry[1],
						"player %d disagrees at tick %d",
						client.slot,
						entry[0],
					)
				}
			}
		}
	}
	testing.expect_value(t, session.host.relay.desyncs, 0)
}

@(test)
host_and_two_remote_clients :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 640, 2)
	defer net_destroy(&session)
	net_run(&session, 30, all_done)
	testing.expect(t, all_done(&session))
	testing.expect_value(t, session.host.client.verified, 640)
	testing.expect_value(t, len(session.host.client.checksums), 640 / 16)
	for client in session.clients {
		testing.expect_value(t, client.verified, 640)
		testing.expect(t, client.first_tick > 1) // remote players join a running session
		testing.expect(t, len(client.checksums) > 0 && client.checksums[0][0] >= u64(client.first_tick))
	}
	expect_agree(t, &session)
	testing.expect(t, session.clients[0].rollbacks > 0) // wan profile: predictions miss
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
	late := net_join(&session, netcode.PROFILES[1])
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
			testing.expect_value(t, netcode.name_string(&entry.name), name)
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
	again := net_join(&session, netcode.PROFILES[0])
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
	testing.expect_value(t, session.host.client.rollbacks, 0)
	testing.expect_value(t, session.host.relay.replaced, 0)
}

@(test)
taken_player_is_rejected :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	client := net_join(&session, netcode.PROFILES[0], player = 0) // the host's own player
	net_run(&session, 1)
	testing.expect_value(t, client.status, netcode.Status.Failed)
	testing.expect_value(t, client.detail, "that player is taken")
}
