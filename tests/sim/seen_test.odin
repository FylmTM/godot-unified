// What a player saw (src/sim/seen.odin): seen_of's whole ticks, seen_stamp finding the Input's Seen by its type,
// seen_rewind's half tick and cap, and an Input whose Seen the host could never fill refused.
package test_sim

import "core:strings"
import "core:testing"

import "../toy"
import "unified:sim"

Plain_Input :: struct {
	dx, dy: i8,
}

Aim_Input :: struct {
	move:    [2]i8,
	looking: sim.Seen, // any name
	_pad:    u8,
}

@(test)
seen_of_and_stamp :: proc(t: ^testing.T) {
	// the frame on screen at tick 100 (the picture about half a tick before it), the input for tick 102: 3 ticks
	testing.expect_value(t, sim.seen_of(102, 100), 3)
	testing.expect_value(t, sim.seen_of(100, 100), 1)
	testing.expect_value(t, sim.seen_of(99, 100), 1) // never 0 (unknown) for a host that showed a frame
	testing.expect_value(t, sim.seen_of(1000, 100), 255)
	testing.expect_value(t, sim.seen_of(max(u32), 0), 255)

	input := Aim_Input {
		move = {5, -5},
	}
	sim.seen_stamp(&input, 4)
	testing.expect_value(t, input, Aim_Input{move = {5, -5}, looking = 4})
	plain := Plain_Input {
		dx = 3,
	}
	sim.seen_stamp(&plain, 4) // an Input without a Seen: untouched
	testing.expect_value(t, plain, Plain_Input{dx = 3})
}

@(test)
seen_rewind_is_half_a_tick_short_and_capped :: proc(t: ^testing.T) {
	tick := sim.Tick(toy.Game) {
		dt = 1.0 / 64,
	}
	testing.expect_value(t, sim.seen_rewind(&tick, 0, 1), 0) // unknown: no rewind
	testing.expect_value(t, sim.seen_rewind(&tick, 1, 1), 0.5 / 64)
	testing.expect_value(t, sim.seen_rewind(&tick, 3, 1), 2.5 / 64)
	testing.expect_value(t, sim.seen_rewind(&tick, 255, 0.1), 0.1)
	testing.expect_value(t, sim.seen_rewind(&tick, 3, 0), 0)
	testing.expect_value(t, sim.seen_rewind(&tick, 3, -1), 0)
	testing.expect_value(t, sim.seen_rewind(&tick, 3, transmute(f32)u32(0x7FC0_0000)), 0) // a NaN cap
	testing.expect_value(t, sim.seen_rewind(&tick, 3, transmute(f32)u32(0x7F80_0000)), 2.5 / 64) // no cap
}

// A Seen must be a field of the Input itself, and one: the host stamps the first it finds by type.
Two_Seen_Input :: struct {
	a, b: sim.Seen,
	_pad: [2]u8,
}

Nested_Seen_Input :: struct {
	aim:  struct {
		seen: sim.Seen,
		_pad: u8,
	},
	_pad: [2]u8,
}

@(private = "file")
seen_violation_of :: proc($Input: typeid) -> string {
	Seen_Game :: sim.Game(struct {
			players: sim.Players(u32, sim.No_Profile, Input, 1),
		}, Input, sim.No_World, toy.Event, sim.No_Commands, sim.No_Setup, sim.No_Profile, 1)
	game := Seen_Game {
		name = "seen",
		version = "1",
		tick_hz = 64,
		tick = proc(t: ^sim.Tick(Seen_Game)) {},
	}
	return sim.game_violation(&game)
}

@(test)
an_input_seen_the_host_cannot_fill_is_refused :: proc(t: ^testing.T) {
	testing.expect_value(t, seen_violation_of(Aim_Input), "")
	two := seen_violation_of(Two_Seen_Input)
	testing.expectf(t, strings.contains(two, "more than one sim.Seen"), "%q", two)
	nested := seen_violation_of(Nested_Seen_Input)
	testing.expectf(t, strings.contains(nested, "`aim` holds a sim.Seen"), "%q", nested)
}
