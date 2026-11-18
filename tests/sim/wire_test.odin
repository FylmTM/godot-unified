// Values from another machine (src/sim/SPEC.md, Input and Commands): a modified or buggy client can send any bytes,
// and every peer and every replay must read them alike without `tick` indexing out of bounds or seeing a NaN.
package test_sim

import "core:testing"

import "../toy"
import "unified:sim"

// A command whose enum field holds an undeclared value, or whose float is not finite, is left out (nil) on every peer
// alike, as one of the wrong size; a bit_set holds only its own elements.
@(test)
commands_from_the_wire_are_checked :: proc(t: ^testing.T) {
	MARK :: toy.Cmd_Mark {
		at     = {1, 2},
		count  = 3,
		shape  = .Ring,
		shapes = {.Dot},
	}
	decode :: proc(mark: toy.Cmd_Mark, poke: proc(bytes: []u8)) -> (toy.Cmd_Mark, bool) {
		mark := mark
		bytes := transmute([size_of(toy.Cmd_Mark)]u8)mark
		poke(bytes[:])
		raw, ok := sim.command_from_bytes(toy.Cmd, 1, bytes[:])
		assert(ok)
		value, is_mark := sim.command_value(&raw, toy.Cmd).(toy.Cmd_Mark)
		return value, is_mark
	}
	clean, clean_ok := decode(MARK, proc(bytes: []u8) {})
	testing.expect(t, clean_ok && clean == MARK)
	_, enum_ok := decode(MARK, proc(bytes: []u8) {bytes[offset_of(toy.Cmd_Mark, shape)] = 200})
	testing.expect(t, !enum_ok, "Cmd_Mark.shape = 200 (Shape has 3 members) reached the game")
	_, last_ok := decode(MARK, proc(bytes: []u8) {bytes[offset_of(toy.Cmd_Mark, shape)] = u8(max(toy.Shape))})
	testing.expect(t, last_ok, "the last declared value was refused")
	_, nan_ok := decode(MARK, proc(bytes: []u8) {
		(^u32)(&bytes[offset_of(toy.Cmd_Mark, weight)])^ = 0xFFC0_0000
	})
	testing.expect(t, !nan_ok, "a NaN weight reached the game")
	_, inf_ok := decode(MARK, proc(bytes: []u8) {
		(^u32)(&bytes[offset_of(toy.Cmd_Mark, area) + offset_of(toy.Mark_Area, corner)])^ = 0x7F80_0000
	})
	testing.expect(t, !inf_ok, "an infinite corner (a nested struct's array) reached the game")
	masked, masked_ok := decode(MARK, proc(bytes: []u8) {bytes[offset_of(toy.Cmd_Mark, shapes)] = 0b1000_0101})
	testing.expect(t, masked_ok)
	testing.expectf(
		t,
		transmute(u8)masked.shapes == 0b0000_0101,
		"shapes %08b: the bits of no Shape stay",
		transmute(u8)masked.shapes,
	)
}

Mode :: enum u8 {
	Walk,
	Run,
}

Moded_Input :: struct {
	mode:    Mode,
	buttons: toy.Buttons,
	_pad:    [2]u8,
}

Moded_Data :: struct {
	runs: u32,
}

Moded_State :: struct {
	players: sim.Players(Moded_Data, Moded_Input, 2),
	seen:    [8]Mode, // slot 0's mode on the last tick, then its buttons' bits
}

Moded_Event :: union {
	sim.Event_Player_Joined,
	sim.Event_Player_Left,
}

Moded :: sim.Game(Moded_State, Moded_Input, sim.No_World, Moded_Event, sim.No_Commands, 2)

MODED := Moded {
	name = "moded",
	version = "1",
	tick_hz = 64,
	tick = proc(t: ^sim.Tick(Moded)) {
		t.state.seen[0] = t.inputs.input[0].mode
		t.state.seen[1] = Mode(transmute(u8)t.inputs.input[0].buttons)
	},
}

// An Input may hold enums and bit_sets: a value outside an enum reads as its zero value and a bit_set holds only its
// own elements, in the tick and in the State's remembered input, while the caller's inputs stay as they were sent
// (logged and compared as raw bytes).
@(test)
inputs_from_the_wire_read_as_declared :: proc(t: ^testing.T) {
	simulation := sim.create(&MODED, 1)
	defer sim.destroy(simulation)
	inputs: sim.Inputs(Moded)
	inputs.present = {0}
	sim.join(&inputs, 0, 1)
	inputs.input[0] = {
		mode    = .Run,
		buttons = {.Spawn},
	}
	sim.step(simulation, &inputs)
	testing.expect_value(t, simulation.state.seen[0], Mode.Run) // valid: as sent
	bytes := cast(^[size_of(Moded_Input)]u8)&inputs.input[0]
	bytes[offset_of(Moded_Input, mode)] = 9
	bytes[offset_of(Moded_Input, buttons)] = 0b1000_0001
	sent := inputs
	sim.step(simulation, &inputs)
	testing.expect_value(t, simulation.state.seen[0], Mode.Walk)
	testing.expect_value(t, u8(simulation.state.seen[1]), 0b0000_0001)
	testing.expect_value(t, simulation.state.players.before[0], Moded_Input{mode = .Walk, buttons = {.Spawn}})
	testing.expect(t, sim.inputs_same(&inputs, &sent), "step changed the caller's inputs")
	testing.expect_value(t, bytes[offset_of(Moded_Input, mode)], 9)
}

// Every kind of field the Input check compiles (src/sim/variant.odin, Wire_Check): a dense enum, a signed enum with
// holes, a bit_set of that enum and one of a range, in arrays and a nested struct.
Holed :: enum i16 {
	Zero  = 0,
	Low   = -3,
	High  = 7,
	Lower = -300,
}

Sparse :: enum u8 {
	A = 1,
	B = 4,
	C = 6,
}

Holed_Inner :: struct {
	holed: [2]Holed,
	range: bit_set[2 ..= 9;u16],
}

Mixed_Input :: struct {
	mode:    Mode,
	holes:   bit_set[Sparse;u8],
	inner:   Holed_Inner,
	buttons: toy.Buttons,
	_pad:    [3]u8,
}

Mixed_Data :: struct {
	unused: u32,
}

Mixed_State :: struct {
	players: sim.Players(Mixed_Data, Mixed_Input, 2),
}

Mixed_Event :: union {
	sim.Event_Player_Joined,
	sim.Event_Player_Left,
}

Mixed :: sim.Game(Mixed_State, Mixed_Input, sim.No_World, Mixed_Event, sim.No_Commands, 2)

MIXED := Mixed {
	name = "mixed",
	version = "1",
	tick_hz = 64,
	tick = proc(t: ^sim.Tick(Mixed)) {},
}

// The input as the tick must read it, written out by hand: undeclared enum values as 0, bit_sets without the bits of
// no element.
mixed_as_read :: proc(input: Mixed_Input) -> (read: Mixed_Input) {
	read = input
	if u8(read.mode) > u8(max(Mode)) do read.mode = .Walk
	for &holed in read.inner.holed {
		switch holed {
		case .Zero, .Low, .High, .Lower:
		case:
			holed = .Zero
		}
	}
	read.holes &= {.A, .B, .C}
	read.inner.range &= {2, 3, 4, 5, 6, 7, 8, 9}
	read.buttons &= {.Spawn}
	return
}

// Random bytes, and valid inputs among them, read as wire_fix reads them, through the check compiled at create.
@(test)
fuzz_inputs_read_as_declared :: proc(t: ^testing.T) {
	simulation := sim.create(&MIXED, 1)
	defer sim.destroy(simulation)
	inputs: sim.Inputs(Mixed)
	sim.join(&inputs, 0, 1)
	state: u64 = 0x9E37_79B9_7F4A_7C15
	for k in 0 ..< 4000 {
		bytes := cast(^[size_of(Mixed_Input)]u8)&inputs.input[0]
		for &b in bytes {
			state = state * 6364136223846793005 + 1442695040888963407
			b = u8(state >> 56)
		}
		if k % 4 != 3 do inputs.input[0] = mixed_as_read(inputs.input[0]) // valid
		switch k % 4 {
		case 1:
			// Stray bits in the bit_sets only: the enums are declared values.
			bytes[offset_of(Mixed_Input, holes)] |= u8(state >> 8)
			bytes[offset_of(Mixed_Input, inner) + offset_of(Holed_Inner, range) + 1] |= u8(state >> 16)
			bytes[offset_of(Mixed_Input, buttons)] |= u8(state >> 24)
		case 2:
			// One enum field off by a little: just past its range, or in a hole.
			value := i64(state >> 8 & 0xF) - 6
			switch state >> 40 % 3 {
			case 0:
				bytes[offset_of(Mixed_Input, mode)] = u8(value + 6)
			case:
				(^i16)(&inputs.input[0].inner.holed[state >> 40 % 3 - 1])^ = i16(value)
			}
		}
		inputs.input[0]._pad = {}
		sent := inputs.input[0]
		sim.step(simulation, &inputs)
		inputs.joins = {}
		want := mixed_as_read(sent)
		got := simulation.state.players.before[0]
		if !testing.expectf(t, got == want, "input %d: %v read as %v, want %v", k, sent, got, want) do return
	}
}

// An Input's enum must declare a member of value 0: an undeclared value reads as 0, and an absent player's input is
// all zeros. Without one, `tick` would read a value of no member (indexing an enumerated array with it is out of
// bounds), so the game is refused. The state's enums may start anywhere.
@(test)
an_input_enum_needs_a_zero_member :: proc(t: ^testing.T) {
	Stance :: enum u8 {
		Stand  = 1,
		Crouch = 2,
	}
	Stance_Input :: struct {
		stance: Stance,
		_pad:   [3]u8,
	}
	Stance_Data :: struct {
		unused: u32,
	}
	Stance_State :: struct {
		players: sim.Players(Stance_Data, Stance_Input, 2),
		last:    Stance,
		_pad:    [3]u8,
	}
	Stance_Event :: union {
		sim.Event_Player_Joined,
		sim.Event_Player_Left,
	}
	Stance_Game :: sim.Game(Stance_State, Stance_Input, sim.No_World, Stance_Event, sim.No_Commands, 2)
	game := Stance_Game {
		name = "stance",
		version = "1",
		tick_hz = 64,
		tick = proc(t: ^sim.Tick(Stance_Game)) {},
	}
	testing.expect_value(
		t,
		sim.game_violation(&game),
		"stance: the Input can't be sent between machines: Stance_Input.stance: Stance declares no member of value 0 (an undeclared value from another machine, and an absent player's input, read as 0)",
	)
	testing.expect_value(t, sim.plain_violation(type_info_of(Stance_State)), "")
	// Inside an array or a nested struct too; a bit_set of such an enum is fine (its zero value is empty).
	testing.expect(t, sim.wire_violation(type_info_of([2]Stance)) != "")
	testing.expect_value(t, sim.wire_violation(type_info_of(bit_set[Stance;u8])), "")
}
