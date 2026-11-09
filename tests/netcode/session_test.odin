// L2 netcode tests: a host (relay + its own client) and remote clients over loopback links with
// the network simulator, all stepped from one thread on a virtual clock, on the toy game.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:sim"

Client :: netcode.Client(toy.State, toy.Input, toy.World, toy.SLOTS)
Host :: netcode.Host(toy.State, toy.Input, toy.World, toy.SLOTS)
Hooks :: netcode.Hooks(toy.State, toy.Input, toy.World, toy.SLOTS)

SEED :: 5

Watch :: struct {
	frames:        int,
	verified_upto: u32,
	in_order:      bool,
	events:        int,
	statuses:      [dynamic]netcode.Status,
}

hooks_for :: proc(w: ^Watch) -> Hooks {
	w.in_order = true
	return {user = w, sample = proc(user: rawptr, slot: int, tick: u32, state: ^toy.State) -> toy.Input {
			return toy.script(SEED, slot, tick)
		}, commands = proc(user: rawptr, slot: int, tick: u32, state: ^toy.State, out: ^sim.Command_Out) {
			toy.script_commands(SEED, slot, tick, out)
		}, frame = proc(user: rawptr, s: ^toy.Sim, f: netcode.Frame_Info) {
			w := (^Watch)(user)
			w.frames += 1
			assert(sim.state_at(s, f.tick) != nil && f.resim_from <= f.tick && f.verified <= f.tick)
		}, verified = proc(user: rawptr, s: ^toy.Sim, tick: u32, events: []sim.Event) {
			w := (^Watch)(user)
			if tick != w.verified_upto + 1 && w.verified_upto != 0 {
				w.in_order = false
			}
			w.verified_upto = tick
			w.events += len(events)
		}, status = proc(user: rawptr, st: netcode.Status, detail: string) {
			w := (^Watch)(user)
			append(&w.statuses, st)
		}}
}

Net :: struct {
	clock:   netcode.Virtual_Clock,
	hub:     ^netcode.Hub, // remote side: endpoint 0 is the relay
	host:    ^Host,
	clients: [dynamic]^Client,
	watch:   [8]Watch,
}

net_make :: proc(n: ^Net, ticks: u32, remotes: int) {
	n.clock.now = 1_000_000
	n.hub = netcode.hub_create(8)
	n.host = netcode.host_create(
		&toy.GAME,
		{seed = SEED, ticks = ticks, name = "host", player = "Ada", quiet = true},
		hooks_for(&n.watch[0]),
	)
	netcode.host_add_link(n.host, netcode.loopback_link(n.hub, 0))
	for _ in 0 ..< remotes {
		net_join(n, netcode.PROFILES[1])
	}
}

net_join :: proc(n: ^Net, profile: netcode.Profile, slot := -1) -> ^Client {
	k := len(n.clients) + 1
	link := netcode.netsim_wrap(netcode.loopback_link(n.hub, netcode.Peer(k)), profile, u32(k) * 7919, &n.clock)
	c := netcode.client_create(
		&toy.GAME,
		{slot = slot, name = "remote", player = k == 1 ? "Grace" : "Linus", quiet = true},
		link,
		hooks_for(&n.watch[k]),
	)
	append(&n.clients, c)
	return c
}

net_destroy :: proc(n: ^Net) {
	for c in n.clients {
		netcode.client_destroy(c)
	}
	delete(n.clients)
	netcode.host_destroy(n.host)
	netcode.hub_destroy(n.hub)
	for &w in n.watch {
		delete(w.statuses)
	}
}

// Steps everything every 250 µs of virtual time for `seconds`, or until `done` says so.
net_run :: proc(n: ^Net, seconds: f64, done: proc(n: ^Net) -> bool = nil) {
	end := n.clock.now + i64(seconds * 1e6)
	for n.clock.now < end {
		n.clock.now += 250
		netcode.host_step(n.host, n.clock.now)
		for c in n.clients {
			netcode.client_step(c, n.clock.now)
		}
		if done != nil && done(n) {
			return
		}
	}
}

all_done :: proc(n: ^Net) -> bool {
	if !netcode.host_finished(n.host) {
		return false
	}
	for c in n.clients {
		if c.status != .Disconnected && c.status != .Failed {
			return false
		}
	}
	return true
}

// Every pair of clients agrees on every checksummed tick both verified.
expect_agree :: proc(t: ^testing.T, n: ^Net) {
	ref := n.host.client.checksums[:]
	testing.expect(t, len(ref) > 0)
	for c in n.clients {
		for e in c.checksums {
			for r in ref {
				if r[0] == e[0] {
					testing.expectf(t, r[1] == e[1], "slot %d disagrees at tick %d", c.slot, e[0])
				}
			}
		}
	}
	testing.expect_value(t, n.host.relay.desyncs, 0)
}

@(test)
host_and_two_remote_clients :: proc(t: ^testing.T) {
	n: Net
	net_make(&n, 640, 2)
	defer net_destroy(&n)
	net_run(&n, 30, all_done)
	testing.expect(t, all_done(&n))
	testing.expect_value(t, n.host.client.verified, 640)
	testing.expect_value(t, len(n.host.client.checksums), 640 / 16)
	for c in n.clients {
		testing.expect_value(t, c.verified, 640)
		testing.expect(t, c.first_tick > 1) // remote players join a running session
		testing.expect(t, len(c.checksums) > 0 && c.checksums[0][0] >= u64(c.first_tick))
	}
	expect_agree(t, &n)
	testing.expect(t, n.clients[0].rollbacks > 0) // wan profile: predictions miss
	for k in 0 ..= 2 {
		w := &n.watch[k]
		testing.expect(t, w.in_order)
		testing.expect_value(t, w.verified_upto, 640)
		testing.expect(t, w.frames > 0)
		testing.expect(
			t,
			len(w.statuses) >= 3 && w.statuses[1] == .Connected && w.statuses[len(w.statuses) - 1] == .Disconnected,
		)
	}
	// The relay's log replays to the verified result.
	s := sim.create(&toy.GAME, SEED)
	defer sim.destroy(s)
	for k in 0 ..< len(n.host.relay.log.ticks) {
		in_ := sim.log_inputs(&n.host.relay.log, k)
		sim.step(s, &in_)
	}
	testing.expect_value(t, s.tick, 640)
	testing.expect_value(t, sim.checksum(s), n.host.client.chk[(640 / 16) % netcode.CHK_RING].value)
}

@(test)
late_join_and_leave :: proc(t: ^testing.T) {
	n: Net
	net_make(&n, 0, 1) // endless
	defer net_destroy(&n)
	net_run(&n, 3)
	testing.expect_value(t, n.clients[0].status, netcode.Status.Connected)
	late := net_join(&n, netcode.PROFILES[1])
	net_run(&n, 4)
	testing.expect_value(t, late.status, netcode.Status.Connected)
	testing.expect_value(t, late.slot, 2)
	testing.expect(t, late.first_tick > 64 * 3)
	testing.expect(t, late.verified > late.first_tick)
	testing.expect(t, len(n.host.relay.log.commands) > 0) // the snapshot's history had commands
	expect_agree(t, &n)
	// The roster: every client knows every name.
	for c in ([]^Client{n.host.client, n.clients[0], late}) {
		testing.expect_value(t, netcode.client_player_name(c, 0), "Ada")
		testing.expect_value(t, netcode.client_player_name(c, 1), "Grace")
		testing.expect_value(t, netcode.client_player_name(c, 2), "Linus")
		testing.expect(t, c.connected[0] && c.connected[1] && c.connected[2] && !c.connected[3])
	}
	// The first remote leaves: it disappears from `present` and the others go on.
	netcode.client_stop(n.clients[0], n.clock.now)
	net_run(&n, 2)
	testing.expect_value(t, n.clients[0].status, netcode.Status.Disconnected)
	last := n.host.relay.log.ticks[len(n.host.relay.log.ticks) - 1]
	testing.expect(t, 1 not_in last.present)
	testing.expect(t, 0 in last.present && 2 in last.present)
	// Its slot is free again for the next joiner.
	again := net_join(&n, netcode.PROFILES[0])
	net_run(&n, 3)
	testing.expect_value(t, again.slot, 1)
	testing.expect_value(t, again.status, netcode.Status.Connected)
	expect_agree(t, &n)
	netcode.host_stop(n.host, n.clock.now)
	net_run(&n, 5, all_done)
	testing.expect(t, all_done(&n))
	testing.expect(t, late.verified > 64 * 9)
}

@(test)
single_player_host :: proc(t: ^testing.T) {
	n: Net
	net_make(&n, 128, 0)
	defer net_destroy(&n)
	net_run(&n, 10, all_done)
	testing.expect(t, all_done(&n))
	testing.expect_value(t, n.host.client.verified, 128)
	testing.expect_value(t, n.host.client.rollbacks, 0)
	testing.expect_value(t, n.host.relay.replaced, 0)
}

@(test)
taken_slot_is_rejected :: proc(t: ^testing.T) {
	n: Net
	net_make(&n, 0, 0)
	defer net_destroy(&n)
	c := net_join(&n, netcode.PROFILES[0], slot = 0) // the host's own slot
	net_run(&n, 1)
	testing.expect_value(t, c.status, netcode.Status.Failed)
	testing.expect_value(t, c.detail, "that player slot is taken")
}
