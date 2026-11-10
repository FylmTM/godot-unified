// Commands (src/netcode/SPEC.md "Commands"): delivered exactly once and in order under loss, duplication and
// reordering; a late input's commands move to a later tick instead of being lost; the sender predicted them
// at the tick it sent them for and rolls back when the relay put them elsewhere; everyone else sees them at
// the relay's tick; the relay's log replays them.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:sim"

// What toy.script_commands sends from `slot` over ticks first..last, in order.
scripted_commands :: proc(slot: int, first, last: u32) -> [dynamic]sim.Command {
	out := sim.Command_Out {
		kinds = toy.GAME.commands,
		slot  = slot,
		cap   = 1 << 20,
	}
	for t in first ..= last {
		toy.script_commands(SEED, slot, t, &out)
	}
	return out.list
}

// The commands of `slot` in the relay's log (typed, for sim.command_as), in tick order, with their ticks.
logged_commands :: proc(
	lg: ^sim.Input_Log(toy.Input, toy.SLOTS),
	slot: int,
) -> (
	cmds: [dynamic]sim.Command,
	ticks: [dynamic]u32,
) {
	for k in 0 ..< len(lg.ticks) {
		in_ := sim.log_inputs(lg, k)
		sim.bind_commands(&in_, toy.GAME.commands)
		for c in sim.commands(&in_, slot) {
			append(&cmds, c)
			append(&ticks, u32(k + 1))
		}
	}
	return
}

// Where the relay puts commands that all arrive in time: each in the tick it was sent for, at most
// COMMANDS_PER_PLAYER per tick, the rest in the next ticks in order.
placed_ticks :: proc(slot: int, first, last: u32) -> (ticks: [dynamic]u32) {
	at, in_tick: u32 = 0, 0
	for t in first ..= last {
		sent := scripted_commands(slot, t, t)
		defer delete(sent)
		for _ in sent {
			tk := max(t, at)
			if tk == at && in_tick == sim.COMMANDS_PER_PLAYER {
				tk += 1
			}
			if tk != at {
				at, in_tick = tk, 0
			}
			in_tick += 1
			append(&ticks, tk)
		}
	}
	return
}

same_command :: proc(a, b: sim.Command) -> bool {
	return a.kind == b.kind && a.slot == b.slot && a.size == b.size && a.data == b.data
}

@(test)
commands_arrive_exactly_once_in_order_under_loss_duplication_and_reordering :: proc(t: ^testing.T) {
	TICKS :: 1600
	n: Net
	net_make(&n, TICKS, 0)
	defer net_destroy(&n)
	for _ in 0 ..< 3 {
		net_join(&n, netcode.PROFILES[2]) // bad: 8% loss, 3% duplicates, 5% reordering
	}
	net_run(&n, 60, all_done)
	testing.expect(t, all_done(&n))
	expect_agree(t, &n)
	lg := &n.host.relay.log
	clients := []^Client{n.host.client, n.clients[0], n.clients[1], n.clients[2]}
	for c in clients {
		testing.expect_value(t, c.verified, TICKS)
		// Every command sent for a tick up to the end, once, in the order sent (one sent in the last
		// ticks may arrive after the session ended).
		want := scripted_commands(c.slot, c.first_tick, TICKS)
		defer delete(want)
		got, at := logged_commands(lg, c.slot)
		defer delete(got)
		defer delete(at)
		late := scripted_commands(c.slot, TICKS - 64, TICKS)
		defer delete(late)
		testing.expectf(
			t,
			len(got) <= len(want) && len(got) >= len(want) - len(late),
			"slot %d: %d commands logged, %d sent",
			c.slot,
			len(got),
			len(want),
		)
		for g, i in got {
			if i >= len(want) || !same_command(g, want[i]) {
				testing.expectf(t, false, "slot %d: logged command %d is not the %d-th sent", c.slot, i, i)
				break
			}
		}
		for k in sim.COMMANDS_PER_PLAYER ..< len(at) {
			if at[k] == at[k - sim.COMMANDS_PER_PLAYER] {
				testing.expectf(
					t,
					false,
					"slot %d: more than %d commands in tick %d",
					c.slot,
					sim.COMMANDS_PER_PLAYER,
					at[k],
				)
				break
			}
		}
		// The verified state applied exactly the logged ones, in order.
		fold: u32
		sum: i32
		bumps: u32
		for &g in got {
			if b, ok := sim.command_as(&g, toy.Cmd_Bump); ok {
				bumps += 1
				sum += b.amount
				fold = toy.bump_fold(fold, b.amount)
			}
		}
		st := &c.sim.state
		testing.expect_value(t, st.bumps[c.slot], bumps)
		testing.expect_value(t, st.bump_sum[c.slot], sum)
		testing.expect_value(t, st.bump_fold[c.slot], fold)
	}
}

// A sender whose packets stop for a while, with hooks that send one bump when armed.
Sender :: struct {
	armed: bool,
	sent:  u32, // the tick the bump was sent for (W)
}

sender_hooks :: proc(s: ^Sender, w: ^Watch) -> Hooks {
	h := hooks_for(w)
	h.user = s
	h.commands = proc(user: rawptr, slot: int, tick: u32, state: ^toy.State, out: ^sim.Command_Out) {
		s := (^Sender)(user)
		if s.armed && sim.send_command(out, toy.Cmd_Bump{777}) {
			s.armed = false
			s.sent = tick
		}
	}
	h.frame, h.verified, h.status = nil, nil, nil
	return h
}

// No commands from anyone else.
quiet_hooks :: proc(w: ^Watch) -> Hooks {
	h := hooks_for(w)
	h.commands = nil
	return h
}

@(test)
a_late_inputs_command_moves_to_a_later_tick_and_the_sender_rolls_back :: proc(t: ^testing.T) {
	n: Net
	n.clock.now = 1_000_000
	n.hub = netcode.hub_create(8)
	n.host = netcode.host_create(
		&toy.GAME,
		{seed = SEED, ticks = 0, name = "host", quiet = true},
		quiet_hooks(&n.watch[0]),
	)
	netcode.host_add_link(n.host, netcode.loopback_link(n.hub, 0))
	defer net_destroy(&n)
	link, gate := gate_wrap(netcode.loopback_link(n.hub, 1))
	snd: Sender
	c := netcode.client_create(
		&toy.GAME,
		{slot = -1, name = "sender", quiet = true},
		link,
		sender_hooks(&snd, &n.watch[1]),
	)
	append(&n.clients, c)
	net_run(&n, 2)
	testing.expect_value(t, c.status, netcode.Status.Connected)
	// The sender's packets stop (its own client keeps running), it sends a bump for tick W and predicts it
	// there; the relay gets the inputs for W too late and finalizes W without them.
	gate.block_out = true
	snd.armed = true
	net_run(&n, 0.05)
	w := snd.sent
	testing.expect(t, w > c.verified)
	net_run(&n, 0.1, proc(n: ^Net) -> bool {return n.clients[0].predicted >= (^Sender)(n.clients[0].hooks.user).sent})
	pred := &c.pred_inputs[w % netcode.PRED_RING]
	testing.expect_value(t, len(sim.commands(pred, c.slot)), 1) // predicted at W
	rollbacks := c.rollbacks
	net_run(&n, 0.3)
	gate.block_out = false
	net_run(&n, 2)
	testing.expect_value(t, c.status, netcode.Status.Connected)
	testing.expect(t, c.rollbacks > rollbacks)
	// The log: W replaced the sender's input and holds no command; the bump is in one later tick T, once.
	lg := &n.host.relay.log
	testing.expect(t, c.slot in lg.ticks[w - 1].replaced)
	testing.expect_value(t, len(sim.log_commands(lg, int(w - 1))), 0)
	tt: u32
	count := 0
	for k in 0 ..< len(lg.ticks) {
		if n := len(sim.log_commands(lg, k)); n > 0 {
			count += n
			tt = u32(k + 1)
		}
	}
	testing.expect_value(t, count, 1)
	testing.expect(t, tt > w)
	// Replaying the log: the bump lands at T; the sender and the host's client verified that history.
	s := sim.create(&toy.GAME, SEED)
	defer sim.destroy(s)
	for k in 0 ..< len(lg.ticks) {
		if u32(k + 1) > c.verified || u32(k + 1) > n.host.client.verified {
			break
		}
		in_ := sim.log_inputs(lg, k)
		sim.step(s, &in_)
		testing.expect_value(t, s.state.bumps[c.slot], u32(s.tick >= tt))
		for x in ([]^Client{c, n.host.client}) {
			for e in x.checksums {
				if e[0] == u64(s.tick) {
					testing.expectf(
						t,
						e[1] == sim.checksum(s),
						"slot %d differs from the log at tick %d",
						x.slot,
						s.tick,
					)
				}
			}
		}
	}
	testing.expect_value(t, c.sim.state.bump_sum[c.slot], 777)
	testing.expect_value(t, n.host.client.sim.state.bump_sum[c.slot], 777)
	expect_agree(t, &n)
}

// The host's own commands always arrive in time: each lands in the tick it was sent for, except that
// a tick takes at most four of a player's (toy.script_commands sends six at tick 250: two wait for 251).
@(test)
the_fifth_command_of_a_tick_waits_for_the_next :: proc(t: ^testing.T) {
	n: Net
	net_make(&n, 400, 1)
	defer net_destroy(&n)
	net_run(&n, 20, all_done)
	testing.expect(t, all_done(&n))
	expect_agree(t, &n)
	got, at := logged_commands(&n.host.relay.log, 0)
	defer delete(got)
	defer delete(at)
	want := placed_ticks(0, 1, 400)
	defer delete(want)
	testing.expect_value(t, len(at), len(want))
	for k in 0 ..< min(len(at), len(want)) {
		if at[k] != want[k] {
			testing.expectf(t, false, "command %d is in tick %d, not %d", k, at[k], want[k])
			break
		}
	}
	burst := 0
	for tk in at {
		burst += int(tk == 251)
	}
	testing.expect(t, burst >= 2) // the burst's 5th and 6th
}
