// Commands (src/netcode/SPEC.md "Commands"): delivered exactly once and in order under loss, duplication and
// reordering; a late input's commands move to a later tick instead of being lost; the sender predicted them
// at the tick it sent them for and rolls back when the relay put them elsewhere; everyone else sees them at
// the relay's tick; the relay's log replays them.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:sim"

// What toy.scripted_commands sends from `player` over ticks first..last, in order.
sent_commands :: proc(player: int, first, last: u32) -> [dynamic]sim.Raw_Command {
	out := sim.Command_Out {
		commands = toy.Cmd,
		player   = player,
		cap      = 1 << 20,
	}
	for tick in first ..= last {
		toy.scripted_commands(SEED, player, tick, &out)
	}
	return out.list
}

// The commands of `player` in the relay's log, in tick order, with their ticks.
logged_commands :: proc(
	log: ^sim.Input_Log(toy.Input, toy.PLAYERS),
	player: int,
) -> (
	commands: [dynamic]sim.Raw_Command,
	ticks: [dynamic]u32,
) {
	for k in 0 ..< len(log.ticks) {
		inputs := sim.log_inputs(log, k)
		for command in sim.commands(&inputs, player) {
			append(&commands, command)
			append(&ticks, u32(k + 1))
		}
	}
	return
}

// Where the relay puts commands that all arrive in time: each in the tick it was sent for, at most
// COMMANDS_PER_PLAYER per tick, the rest in the next ticks in order.
placed_ticks :: proc(player: int, first, last: u32) -> (ticks: [dynamic]u32) {
	at, in_tick: u32 = 0, 0
	for tick in first ..= last {
		sent := sent_commands(player, tick, tick)
		defer delete(sent)
		for _ in sent {
			lands_at := max(tick, at)
			if lands_at == at && in_tick == sim.COMMANDS_PER_PLAYER {
				lands_at += 1
			}
			if lands_at != at {
				at, in_tick = lands_at, 0
			}
			in_tick += 1
			append(&ticks, lands_at)
		}
	}
	return
}

same_command :: proc(got, want: sim.Raw_Command) -> bool {
	return got.kind == want.kind && got.player == want.player && got.size == want.size && got.data == want.data
}

@(test)
commands_arrive_exactly_once_in_order_under_loss_duplication_and_reordering :: proc(t: ^testing.T) {
	TICKS :: 1600
	session: Net
	net_make(&session, TICKS, 0)
	defer net_destroy(&session)
	for _ in 0 ..< 3 {
		net_join(&session, netcode.PROFILES[2]) // bad: 8% loss, 3% duplicates, 5% reordering
	}
	net_run(&session, 60, all_done)
	testing.expect(t, all_done(&session))
	expect_agree(t, &session)
	log := net_log(&session)
	clients := []^Client{session.host.client, session.clients[0], session.clients[1], session.clients[2]}
	for client in clients {
		testing.expect_value(t, client.verified, TICKS)
		// Every command sent for a tick up to the end, once, in the order sent (one sent in the last
		// ticks may arrive after the session ended).
		want := sent_commands(client.player, client.first_tick, TICKS)
		defer delete(want)
		got, at := logged_commands(log, client.player)
		defer delete(got)
		defer delete(at)
		late := sent_commands(client.player, TICKS - 64, TICKS)
		defer delete(late)
		testing.expectf(
			t,
			len(got) <= len(want) && len(got) >= len(want) - len(late),
			"player %d: %d commands logged, %d sent",
			client.player,
			len(got),
			len(want),
		)
		for command, i in got {
			if i >= len(want) || !same_command(command, want[i]) {
				testing.expectf(t, false, "player %d: logged command %d is not the %d-th sent", client.player, i, i)
				break
			}
		}
		for k in sim.COMMANDS_PER_PLAYER ..< len(at) {
			if at[k] == at[k - sim.COMMANDS_PER_PLAYER] {
				testing.expectf(
					t,
					false,
					"player %d: more than %d commands in tick %d",
					client.player,
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
		for &command in got {
			if bump, ok := sim.command_value(&command, toy.Cmd).(toy.Cmd_Bump); ok {
				bumps += 1
				sum += bump.amount
				fold = toy.bump_fold(fold, bump.amount)
			}
		}
		state := &client.sim.state
		testing.expect_value(t, state.bumps[client.player], bumps)
		testing.expect_value(t, state.bump_sum[client.player], sum)
		testing.expect_value(t, state.bump_fold[client.player], fold)
	}
}

// A sender whose packets stop for a while, with hooks that send one bump when armed.
Sender :: struct {
	armed: bool,
	sent:  u32, // the tick the bump was sent for (W)
}

sender_hooks :: proc(sender: ^Sender, watch: ^Watch) -> Hooks {
	hooks := hooks_for(watch)
	hooks.user = sender
	hooks.commands = proc(user: rawptr, player: int, tick: u32, state: ^toy.State, out: ^sim.Command_Out) {
		sender := (^Sender)(user)
		if sender.armed && sim.send_command(out, toy.Cmd_Bump{777}) {
			sender.armed = false
			sender.sent = tick
		}
	}
	hooks.frame, hooks.verified, hooks.status = nil, nil, nil
	return hooks
}

// No commands from anyone else.
quiet_hooks :: proc(watch: ^Watch) -> Hooks {
	hooks := hooks_for(watch)
	hooks.commands = nil
	return hooks
}

@(test)
a_late_inputs_command_moves_to_a_later_tick_and_the_sender_rolls_back :: proc(t: ^testing.T) {
	session: Net
	session.clock.now = 1_000_000
	session.hub = netcode.hub_create(8)
	session.host = netcode.host_create(
		&toy.GAME,
		{seed = SEED, ticks = 0, name = "host", quiet = true, recording = sim.log_sink_memory(&session.recording)},
		quiet_hooks(&session.watch[0]),
	)
	netcode.host_add_link(session.host, netcode.loopback_link(session.hub, 0))
	defer net_destroy(&session)
	link, gate := gate_wrap(netcode.loopback_link(session.hub, 1))
	sender: Sender
	client := netcode.client_create(
		&toy.GAME,
		{player = -1, name = "sender", quiet = true},
		link,
		sender_hooks(&sender, &session.watch[1]),
	)
	append(&session.clients, client)
	net_run(&session, 2)
	testing.expect_value(t, client.status, netcode.Status.Connected)
	// The sender's packets stop (its own client keeps running), it sends a bump for tick W and predicts it
	// there; the relay gets the inputs for W too late and finalizes W without them.
	gate.block_out = true
	sender.armed = true
	net_run(&session, 0.05)
	sent_for := sender.sent
	testing.expect(t, sent_for > client.verified)
	net_run(&session, 0.1, proc(session: ^Net) -> bool {
		return session.clients[0].predicted >= (^Sender)(session.clients[0].hooks.user).sent
	})
	predicted := &client.pred_inputs[sent_for % netcode.PRED_RING]
	testing.expect_value(t, len(sim.commands(predicted, client.player)), 1) // predicted at W
	rollbacks := client.rollbacks
	net_run(&session, 0.3)
	gate.block_out = false
	net_run(&session, 2)
	testing.expect_value(t, client.status, netcode.Status.Connected)
	testing.expect(t, client.rollbacks > rollbacks)
	// The log: W replaced the sender's input and holds no command; the bump is in one later tick T, once.
	log := net_log(&session)
	testing.expect(t, client.player in log.ticks[sent_for - 1].replaced)
	testing.expect_value(t, len(sim.log_commands(log, int(sent_for - 1))), 0)
	bump_tick: u32
	count := 0
	for k in 0 ..< len(log.ticks) {
		if logged := len(sim.log_commands(log, k)); logged > 0 {
			count += logged
			bump_tick = u32(k + 1)
		}
	}
	testing.expect_value(t, count, 1)
	testing.expect(t, bump_tick > sent_for)
	// Replaying the log: the bump lands at T; the sender and the host's client verified that history.
	simulation := sim.create(&toy.GAME, SEED)
	defer sim.destroy(simulation)
	for k in 0 ..< len(log.ticks) {
		if u32(k + 1) > client.verified || u32(k + 1) > session.host.client.verified {
			break
		}
		inputs := sim.log_inputs(log, k)
		sim.step(simulation, &inputs)
		testing.expect_value(t, simulation.state.bumps[client.player], u32(simulation.tick >= bump_tick))
		for verifier in ([]^Client{client, session.host.client}) {
			for entry in verifier.checksums {
				if entry[0] == u64(simulation.tick) {
					testing.expectf(
						t,
						entry[1] == sim.checksum(simulation),
						"player %d differs from the log at tick %d",
						verifier.player,
						simulation.tick,
					)
				}
			}
		}
	}
	testing.expect_value(t, client.sim.state.bump_sum[client.player], 777)
	testing.expect_value(t, session.host.client.sim.state.bump_sum[client.player], 777)
	expect_agree(t, &session)
}

// The host's own commands always arrive in time: each lands in the tick it was sent for, except that
// a tick takes at most four of a player's (toy.scripted_commands sends six at tick 250: two wait for 251).
@(test)
the_fifth_command_of_a_tick_waits_for_the_next :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 400, 1)
	defer net_destroy(&session)
	net_run(&session, 20, all_done)
	testing.expect(t, all_done(&session))
	expect_agree(t, &session)
	got, at := logged_commands(net_log(&session), 0)
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
	for tick in at {
		burst += int(tick == 251)
	}
	testing.expect(t, burst >= 2) // the burst's 5th and 6th
}
