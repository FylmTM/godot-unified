// L2 netcode tests of a game's input guess (sim.Game.predict_input): the client predicts remote players with it, its
// own player with its own inputs, and a guess changes how often it rolls back, never what it computes.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"

// A hook that knows a tap ends (it saves the rollbacks of a tap's release: tests/headless/predict_stats_test.odin)
// changes nothing the session computes: the same checksums, the same recording (the relay repeats a missing input,
// never guesses).
@(test)
predict_input_changes_nothing_the_session_computes :: proc(t: ^testing.T) {
	game := toy.GAME // each test its own copy: tests run in parallel
	plain := tap_session(t, &game)
	defer tap_destroy(&plain)
	game.predict_input = proc(last: toy.Input, ticks_ahead: u32) -> toy.Input {
		predicted := last
		if ticks_ahead >= 2 do predicted.buttons -= {.Spawn} // released from the second tick past the last one known
		return predicted
	}
	hooked := tap_session(t, &game)
	defer tap_destroy(&hooked)
	testing.expect_value(t, len(hooked.checksums), len(plain.checksums))
	for entry, i in plain.checksums {
		if i < len(hooked.checksums) && hooked.checksums[i] != entry {
			testing.expectf(
				t,
				false,
				"tick %d: %x with the hook, %x without",
				entry[0],
				hooked.checksums[i][1],
				entry[1],
			)
			break
		}
	}
	testing.expect(t, string(hooked.recording[:]) == string(plain.recording[:]), "the recordings differ")
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
	net_make_relay(&session, 2, 0, game = &game)
	defer net_destroy(&session)
	net_join(&session, 0, .Wan, &game)
	net_join(&session, 1, .Wan, &game)
	Check :: struct {
		t:       ^testing.T,
		checked: int,
	}
	check := Check {
		t = t,
	}
	guesses := proc(session: ^Net, user: rawptr) -> bool {
		check := (^Check)(user)
		client := session.clients[1]
		if client.predicted > client.verified + 1 && client.verified > 64 {
			tick := client.predicted
			inputs := netcode.client_inputs(client, tick)
			ahead := tick - client.fin_upto
			testing.expect_value(check.t, inputs.input[0], toy.Input{dx = i8(ahead), dy = 100})
			testing.expect_value(check.t, inputs.input[1], client.locals[0].own[tick % netcode.OWN_RING])
			check.checked += 1
		}
		return false
	}
	net_run(&session, 3, each = guesses, user = &check)
	testing.expect(t, check.checked > 50)
}
