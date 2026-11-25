// The Seen a host stamps (netcode.client_seen): stable over a session, so an idle player whose only changing input
// byte could be its Seen costs its peers no rollbacks.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:sim"

@(private = "file")
Seen_Run :: struct {
	sender: ^Client,
	seens:  [dynamic]sim.Seen, // every input the sender sampled, in order
}

// A relay and two clients on the Wan profile for 20 s: the sender idle but for the Seen its sample hook stamps, the
// receiver idle. The sender's Seen settles on the input delay plus two and changes only when the delay does; the
// receiver predicted it right (a repeat of the last input) all along.
@(test)
seen_is_stable_over_a_session :: proc(t: ^testing.T) {
	session: Net
	net_make_relay(&session, 2, 0)
	defer net_destroy(&session)
	run: Seen_Run
	defer delete(run.seens)
	sender := Hooks {
		user = &run,
		sample = proc(user: rawptr, local, slot: int, tick: u32, state: ^toy.State, setup: toy.Setup) -> toy.Input {
			run := (^Seen_Run)(user)
			input: toy.Input
			sim.seen_stamp(&input, netcode.client_seen(run.sender, tick))
			append(&run.seens, input.seen)
			return input
		},
	}
	receiver := Hooks {
		sample = proc(
			user: rawptr,
			local, slot: int,
			tick: u32,
			state: ^toy.State,
			setup: toy.Setup,
		) -> toy.Input {return {}},
	}
	run.sender = net_join(&session, hooks = sender)
	net_join(&session, hooks = receiver)
	net_run(&session, 20)

	changes, stamped := 0, 0
	for seen, i in run.seens {
		if seen != 0 do stamped += 1
		if i > 0 && seen != run.seens[i - 1] do changes += 1
	}
	delay := netcode.client_stats(run.sender).delay
	testing.expectf(
		t,
		len(run.seens) > 1000 && stamped > len(run.seens) - 64,
		"%v of %v stamped",
		stamped,
		len(run.seens),
	)
	// sampled for the tick `delay` past the one about to be predicted: the newest prediction is delay + 1 ticks back
	testing.expect_value(t, run.seens[len(run.seens) - 1], sim.Seen(delay + 2))
	testing.expectf(t, changes <= 4, "the Seen changed %v times in 20 s", changes)
	rollbacks := netcode.client_stats(session.clients[1]).rollbacks
	testing.expectf(t, rollbacks <= 4, "the receiver rolled back %v times on an idle player's Seen", rollbacks)
}
