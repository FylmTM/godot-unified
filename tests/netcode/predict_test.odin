// L2 netcode tests of a game's input guess (sim.Game.predict_input): the client predicts remote players with it, its
// own player with its own inputs, and a guess changes how often it rolls back, never what it computes.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:sim"

// A hook that knows a tap ends: a held Spawn is released from the second tick past the last one known.
@(private = "file")
release_taps :: proc(last: toy.Input, ticks_ahead: u32) -> toy.Input {
	predicted := last
	if ticks_ahead >= 2 do predicted.buttons -= {.Spawn}
	return predicted
}

// Three tapping clients on `wan`, 1280 ticks of `game`, recorded: every client's rollbacks summed, the first client's
// checksums (the caller deletes them) and the recording's bytes (deleted too).
@(private = "file")
tapping_session :: proc(
	t: ^testing.T,
	game: ^toy.Game,
) -> (
	rollbacks: int,
	checksums: [][2]u64,
	recording: [dynamic]u8,
) {
	session: Net
	session.clock.now = 1_000_000
	session.hub = netcode.hub_create(8)
	session.relay = netcode.relay_create(
		game,
		{seed = SEED, ticks = 1280, start_players = 3, recording = sim.log_sink_memory(&recording)},
	)
	netcode.relay_add_link(session.relay, netcode.loopback_link(session.hub, 0))
	defer net_destroy(&session)
	for endpoint in 1 ..= 3 {
		link := netcode.netsim_wrap(
			netcode.loopback_link(session.hub, netcode.Peer(endpoint)),
			netcode.PROFILES[.Wan],
			u32(endpoint) * 7919,
			&session.clock,
		)
		append(&session.clients, netcode.client_create(game, {slot = -1}, link, tap_hooks(&session.watch[endpoint])))
	}
	net_run(&session, 40, all_done)
	for client in session.clients {
		testing.expect_value(t, client.verified, u32(1280))
		rollbacks += client.stats.rollbacks
	}
	testing.expect_value(t, session.relay.desyncs, 0)
	expect_agree(t, &session)
	netcode.relay_end_recording(session.relay)
	checksums = make([][2]u64, len(session.clients[0].checksums))
	copy(checksums, session.clients[0].checksums[:])
	return
}

// The hook saves the rollbacks it guesses right (a tap's release), and changes nothing the session computes: the same
// checksums, the same recording (the relay repeats a missing input, never guesses).
@(test)
predict_input_saves_rollbacks_and_changes_nothing_else :: proc(t: ^testing.T) {
	game := toy.GAME // each test its own copy: tests run in parallel
	repeat_last, plain_checksums, plain_recording := tapping_session(t, &game)
	defer delete(plain_checksums)
	defer delete(plain_recording)
	game.predict_input = release_taps
	hooked, hooked_checksums, hooked_recording := tapping_session(t, &game)
	defer delete(hooked_checksums)
	defer delete(hooked_recording)
	testing.expectf(t, hooked * 10 <= repeat_last * 7, "%d rollbacks with the hook, %d without", hooked, repeat_last)
	testing.expect_value(t, len(hooked_checksums), len(plain_checksums))
	for entry, i in plain_checksums {
		if i < len(hooked_checksums) && hooked_checksums[i] != entry {
			testing.expectf(
				t,
				false,
				"tick %d: %x with the hook, %x without",
				entry[0],
				hooked_checksums[i][1],
				entry[1],
			)
			break
		}
	}
	testing.expect(t, string(hooked_recording[:]) == string(plain_recording[:]), "the recordings differ")
}

// A predicted tick's inputs: the hook's guess for the remote players from the newest finalized tick, the client's own
// input for its own slot (never guessed).
@(test)
predict_input_guesses_remote_players_only :: proc(t: ^testing.T) {
	game := toy.GAME
	game.predict_input = proc(last: toy.Input, ticks_ahead: u32) -> toy.Input {
		return {dx = i8(ticks_ahead), dy = 100}
	}
	session: Net
	session.clock.now = 1_000_000
	session.hub = netcode.hub_create(8)
	session.relay = netcode.relay_create(&game, {seed = SEED, start_players = 2})
	netcode.relay_add_link(session.relay, netcode.loopback_link(session.hub, 0))
	defer net_destroy(&session)
	net_join(&session, 0, .Wan, &game)
	client := net_join(&session, 1, .Wan, &game)
	checked := 0
	end := session.clock.now + 3_000_000
	for session.clock.now < end {
		now := session.clock.now
		wake := netcode.relay_step(session.relay, now)
		for other in session.clients do wake = min(wake, netcode.client_step(other, now))
		if client.predicted > client.verified + 1 && client.verified > 64 {
			tick := client.predicted
			inputs := netcode.client_inputs(client, tick)
			ahead := tick - client.fin_upto
			testing.expect_value(t, inputs.input[0], toy.Input{dx = i8(ahead), dy = 100})
			testing.expect_value(t, inputs.input[1], client.own[tick % netcode.OWN_RING])
			checked += 1
		}
		session.clock.now = clamp(wake, now + 1, end)
	}
	testing.expect(t, checked > 50)
}
