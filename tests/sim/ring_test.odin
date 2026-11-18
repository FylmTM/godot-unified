// The ring: restore, unsaved steps, its size per tick rate, a failing Extra, the Extra's check.
package test_sim

import "core:testing"

import "../toy"
import "unified:sim"

// Steps with slots 0 ..< players present (slot i is member i + 1, joining when nobody holds the slot).
run :: proc(simulation: ^toy.Sim, ticks: u32, players := 4) {
	for _ in 0 ..< ticks {
		number := simulation.tick + 1
		inputs: toy.Inputs
		for slot in 0 ..< players {
			inputs.present += {slot}
			if sim.player_in_slot(simulation, slot) == {} do sim.join(&inputs, slot, slot + 1)
			inputs.input[slot] = toy.scripted_input(simulation.seed, slot, number)
		}
		sim.step(simulation, &inputs)
	}
}

// After a restore the later ticks are another timeline's: the ring doesn't answer for them until they are
// stepped again, and then with the new timeline's state and events.
@(test)
restore_drops_the_later_ticks :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 42)
	defer sim.destroy(simulation)
	run(simulation, 12)
	testing.expect(t, sim.state_at(simulation, 11) != nil && sim.state_at(simulation, 12) != nil)
	testing.expect(t, sim.restore(simulation, 10))
	for tick in u32(11) ..= 12 {
		testing.expect(t, sim.state_at(simulation, tick) == nil)
		testing.expect_value(t, len(sim.events_at(simulation, tick)), 0)
		testing.expect(t, !sim.restore(simulation, tick))
	}
	testing.expect_value(t, simulation.tick, 10) // the failed restores changed nothing
	testing.expect(t, sim.state_at(simulation, 10) != nil && sim.state_at(simulation, 9) != nil)
	// Tick 11 again with other inputs (nobody present): the new timeline's state and events.
	inputs: toy.Inputs
	sim.step(simulation, &inputs)
	after := sim.checksum(simulation)
	state := sim.state_at(simulation, 11)
	testing.expect(t, state != nil && state^ == simulation.state)
	testing.expect_value(t, left_events(simulation, 11), toy.PLAYERS)
	testing.expect(t, sim.state_at(simulation, 12) == nil) // still the old timeline's
	testing.expect_value(t, len(sim.events_at(simulation, 12)), 0)
	run(simulation, 1)
	testing.expect(t, sim.state_at(simulation, 12) != nil)
	testing.expect(t, sim.restore(simulation, 11))
	testing.expect_value(t, sim.checksum(simulation), after)
}

// How many players the step to `tick` saw leave.
left_events :: proc(simulation: ^toy.Sim, tick: u32) -> (count: int) {
	for &raw in sim.events_at(simulation, tick) {
		_, is_left := sim.event_value(&raw, toy.Event).(sim.Event_Player_Left)
		count += int(is_left)
	}
	return
}

// A slot answers only for the tick whose contents it holds: after a step that doesn't save, until save, it has the
// new tick's events and no state, and nothing of the tick it held a ring ago.
@(test)
an_unsaved_step_takes_the_slot_over :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 42)
	defer sim.destroy(simulation)
	ring := u32(len(simulation.ring))
	run(simulation, ring + 3)
	tick := simulation.tick + 1
	testing.expect(t, sim.state_at(simulation, tick - ring) != nil)
	inputs: toy.Inputs
	sim.step(simulation, &inputs, save = false)
	testing.expect(t, sim.state_at(simulation, tick - ring) == nil)
	testing.expect_value(t, len(sim.events_at(simulation, tick - ring)), 0)
	testing.expect(t, sim.state_at(simulation, tick) == nil)
	testing.expect_value(t, left_events(simulation, tick), toy.PLAYERS) // nobody present: everyone left
	sim.save(simulation)
	testing.expect(t, sim.state_at(simulation, tick) != nil)
	testing.expect_value(t, left_events(simulation, tick), toy.PLAYERS)
	// An unsaved step over a saved tick of an abandoned timeline: its own events, and no state.
	testing.expect(t, sim.restore(simulation, tick - 1))
	inputs.present = {0, 1, 2, 3}
	sim.step(simulation, &inputs, save = false)
	testing.expect(t, sim.state_at(simulation, tick) == nil && !sim.restore(simulation, tick))
	testing.expect_value(t, left_events(simulation, tick), 0) // the same players as before: nobody left
}

// D8: the ring keeps ~250 ms at any tick rate, allocated at create: ring_size - 1 ticks back restore and
// re-simulate to the same checksum, one more is gone.
@(test)
ring_follows_the_tick_rate :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.ring_size(32), 10) // the floor: a cap of 250 ms, as at the other rates
	testing.expect_value(t, sim.ring_size(64), 16)
	testing.expect_value(t, sim.ring_size(128), 32)
	for hz in ([]int{32, 64, 128}) {
		game := toy.GAME
		game.tick_hz = hz
		simulation := sim.create(&game, 5)
		defer sim.destroy(simulation)
		ring := u32(len(simulation.ring))
		testing.expect_value(t, int(ring), sim.ring_size(hz))
		run(simulation, 100)
		at100 := sim.checksum(simulation)
		testing.expect(t, !sim.restore(simulation, 100 - ring))
		testing.expect(t, sim.restore(simulation, 100 - (ring - 1)))
		run(simulation, ring - 1)
		testing.expect_value(t, simulation.tick, 100)
		testing.expect_value(t, sim.checksum(simulation), at100)
	}
}

// An extra state that can be told to fail its restore.
Flaky :: struct {
	fail: bool,
}

flaky_game :: proc(flaky: rawptr) -> toy.Game {
	game := toy.GAME

	game.extra = proc(world: ^toy.World) -> sim.Extra {
		return {
			data = g_flaky,
			save = proc(data: rawptr, slot: int) {},
			restore = proc(data: rawptr, slot: int) -> bool {return !(^Flaky)(data).fail},
			hash = proc(data: rawptr, tick: u32, out: ^[dynamic]u8) {},
			image = proc(data: rawptr, slot: int, live: bool) -> []u8 {return nil},
			load = proc(data: rawptr, bytes: []u8) -> bool {return true},
		}
	}
	g_flaky = (^Flaky)(flaky)
	return game
}

g_flaky: ^Flaky

@(test)
failed_restore_leaves_the_block :: proc(t: ^testing.T) {
	flaky: Flaky
	game := flaky_game(rawptr(&flaky))
	simulation := sim.create(&game, 7)
	defer sim.destroy(simulation)
	run(simulation, 10, 3)
	before := simulation.state
	flaky.fail = true
	testing.expect(t, !sim.restore(simulation, 5))
	testing.expect_value(t, simulation.tick, 10)
	testing.expect(t, simulation.state == before)
	flaky.fail = false
	testing.expect(t, sim.restore(simulation, 5))
	testing.expect_value(t, simulation.tick, 5)
}

// An extra whose check fails while `broken` is set.
Checked :: struct {
	broken: bool,
}

g_checked: ^Checked

@(test)
check_extra_runs_the_extras_check :: proc(t: ^testing.T) {
	checked: Checked
	g_checked = &checked
	defer g_checked = nil
	plain := sim.create(&toy.GAME, 7)
	defer sim.destroy(plain)
	testing.expect_value(t, sim.check_extra(plain), "") // no extra: nothing to disagree
	game := toy.GAME
	game.extra = proc(world: ^toy.World) -> sim.Extra {
		return {
			data = g_checked,
			save = proc(data: rawptr, slot: int) {},
			restore = proc(data: rawptr, slot: int) -> bool {return true},
			hash = proc(data: rawptr, tick: u32, out: ^[dynamic]u8) {},
			image = proc(data: rawptr, slot: int, live: bool) -> []u8 {return nil},
			load = proc(data: rawptr, bytes: []u8) -> bool {return true},
			check = proc(data: rawptr, state: rawptr) -> string {
				return "a broken ref" if (^Checked)(data).broken else ""
			},
		}
	}
	simulation := sim.create(&game, 7)
	defer sim.destroy(simulation)
	testing.expect_value(t, sim.check_extra(simulation), "")
	checked.broken = true
	testing.expect_value(t, sim.check_extra(simulation), "a broken ref")
}
