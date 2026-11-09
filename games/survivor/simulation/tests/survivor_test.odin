// The survivor game on the harness: plain-data state and input, presence-driven join and leave,
// events, and a short sync-test.
package test_survivor

import "core:testing"

import "../survivor"
import "unified:sim"

@(test)
state_is_plain_data :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.plain_violation(type_info_of(survivor.State)), "")
	testing.expect_value(t, sim.plain_violation(type_info_of(survivor.Input)), "")
	testing.expect_value(t, size_of(survivor.Input), 3)
	testing.expect_value(t, sim.commands_violation(survivor.GAME.commands), "")
}

step :: proc(s: ^survivor.Sim, present: sim.Players) {
	in_: survivor.Inputs
	in_.present = present
	for p in present {
		in_.input[p] = survivor.script(s.seed, p, s.tick + 1, &s.state)
	}
	sim.step(s, &in_)
}

has_event :: proc(s: ^survivor.Sim, tick: u32, kind: survivor.Event_Kind, slot: int) -> bool {
	for e in sim.events_at(s, tick) {
		if e.kind == u16(kind) && int(e.slot) == slot {
			return true
		}
	}
	return false
}

@(test)
presence_joins_and_leaves :: proc(t: ^testing.T) {
	s := sim.create(&survivor.GAME, 3)
	defer sim.destroy(s)
	step(s, {0})
	testing.expect(t, s.state.players[0].active && s.state.players[0].alive)
	testing.expect(t, !s.state.players[1].active)
	testing.expect(t, has_event(s, 1, .Player_Joined, 0))
	step(s, {0, 1})
	testing.expect(t, s.state.players[1].active)
	testing.expect(t, has_event(s, 2, .Player_Joined, 1))
	step(s, {1})
	testing.expect(t, !s.state.players[0].active && s.state.players[0].body == {})
	testing.expect(t, has_event(s, 3, .Player_Left, 0))
}

@(test)
synctest_short :: proc(t: ^testing.T) {
	s := sim.create(&survivor.GAME, 42)
	defer sim.destroy(s)
	forward: [241]u64
	for tt in 1 ..= u32(240) {
		step(s, {0, 1, 2, 3})
		forward[tt] = sim.checksum(s)
		if tt < 8 {
			continue
		}
		testing.expect(t, sim.restore(s, tt - 8))
		for u in tt - 7 ..= tt {
			step(s, {0, 1, 2, 3})
			if sim.checksum(s) != forward[u] {
				testing.expectf(t, false, "tick %d re-sim at %d differs", u, tt)
				return
			}
		}
	}
}
