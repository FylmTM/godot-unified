// Commands in the harness (src/sim/SPEC.md "Commands"): the declared union is checked at create, a tick's
// record takes at most four per player, `tick` reads them per player in order with a type switch, they are
// part of what inputs_same compares and of compat_of, and malformed tick records are refused.
package test_sim

import "core:testing"

import "../toy"
import "unified:sim"
import "unified:wire"

Cmd_Padded :: struct {
	small: u8,
	large: u32,
}

Cmd_Pointer :: struct {
	pointer: ^int,
}

Cmd_Empty :: struct {}

Cmd_Max :: struct {
	bytes: [sim.COMMAND_MAX]u8,
}

Cmd_Too_Big :: struct {
	bytes: [sim.COMMAND_MAX + 1]u8,
}

Bump :: struct {
	amount: i32,
}

Cmd_Bump :: struct {
	amount: i32,
}

Cmd_Toggle :: struct {
	on:    bool,
	_pad:  [3]u8,
	also:  [2]b16,
	count: u32,
}

Toggles :: union {
	Cmd_Toggle,
}

// A bool's byte from another machine may hold anything: command_value reads every bool back as 0 or 1.
@(test)
command_bools_read_back_as_0_or_1 :: proc(t: ^testing.T) {
	bytes := [size_of(Cmd_Toggle)]u8{2, 0xAA, 0xAA, 0xAA, 0, 0, 0, 0x80, 7, 0, 0, 0}
	raw, ok := sim.command_from_bytes(Toggles, 0, bytes[:])
	testing.expect(t, ok)
	toggle := sim.command_value(&raw, Toggles).(Cmd_Toggle)
	got := transmute([size_of(Cmd_Toggle)]u8)toggle
	testing.expect_value(t, got, [size_of(Cmd_Toggle)]u8{1, 0xAA, 0xAA, 0xAA, 0, 0, 1, 0, 7, 0, 0, 0})
	testing.expect(t, toggle.on && !toggle.also[0] && toggle.also[1] && toggle.count == 7)
}

@(test)
command_unions_are_checked :: proc(t: ^testing.T) {
	Max :: union {
		Cmd_Max,
	}
	Padded :: union {
		Cmd_Padded,
	}
	Pointer :: union {
		Cmd_Pointer,
	}
	Empty :: union {
		Cmd_Empty,
	}
	Too_Big :: union {
		Cmd_Too_Big,
	}
	Not_A_Struct :: union {
		string,
	}
	Same_Name :: union {
		Bump,
		Cmd_Bump,
	} // "bump" twice: the prefix goes
	testing.expect_value(t, sim.union_violation(toy.Cmd, sim.COMMAND_MAX, sim.COMMAND_PREFIX), "")
	testing.expect_value(t, sim.union_violation(Max, sim.COMMAND_MAX, sim.COMMAND_PREFIX), "")
	refused := []typeid{Padded, Pointer, Empty, Too_Big, Not_A_Struct, Same_Name, Cmd_Bump}
	for type in refused {
		testing.expectf(t, sim.union_violation(type, sim.COMMAND_MAX, sim.COMMAND_PREFIX) != "", "%v accepted", type)
	}
}

bump :: proc(slot: int, amount: i32) -> sim.Raw_Command {
	raw := sim.command_make(toy.Cmd, toy.Cmd_Bump{amount})
	raw.slot = u8(slot)
	return raw
}

@(test)
a_tick_takes_four_commands_per_player :: proc(t: ^testing.T) {
	inputs: toy.Inputs
	for k in 0 ..< 4 {
		testing.expect(t, sim.add_command(&inputs, bump(2, i32(k))))
	}
	testing.expect(t, !sim.add_command(&inputs, bump(2, 4))) // the 5th waits
	testing.expect(t, sim.add_command(&inputs, bump(0, 10)))
	testing.expect(t, sim.add_command(&inputs, bump(3, 30)))
	testing.expect(t, sim.add_command(&inputs, bump(0, 11)))
	testing.expect(t, !sim.add_command(&inputs, bump(toy.PLAYERS, 0))) // no such slot
	testing.expect_value(t, inputs.command_count, 7)
	// By slot, each slot's in the order added.
	want := [?][2]i32{{0, 10}, {0, 11}, {2, 0}, {2, 1}, {2, 2}, {2, 3}, {3, 30}}
	for expected, i in want {
		raw := &inputs.commands[i]
		value, is_bump := sim.command_value(raw, toy.Cmd).(toy.Cmd_Bump)
		testing.expect(t, is_bump && i32(raw.slot) == expected[0] && value.amount == expected[1])
	}
	testing.expect_value(t, len(sim.slot_commands(&inputs, 0)), 2)
	testing.expect_value(t, len(sim.slot_commands(&inputs, 1)), 0)
	testing.expect_value(t, len(sim.slot_commands(&inputs, 2)), 4)
	testing.expect_value(t, len(sim.slot_commands(&inputs, 3)), 1)
	// At most TICK_COMMANDS in all.
	Big_State :: struct {
		players: sim.Players(u8, toy.Input, 8),
	}
	big: sim.Inputs(sim.Game(Big_State, toy.Input, toy.World, toy.Event, toy.Cmd, 8))
	for k in 0 ..< 32 {
		sim.add_command(&big, bump(k % 8, i32(k)))
	}
	testing.expect_value(t, big.command_count, sim.TICK_COMMANDS)
}

@(test)
tick_reads_commands_by_type :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 3)
	defer sim.destroy(simulation)
	inputs: toy.Inputs
	sim.join(&inputs, 0, 1)
	sim.join(&inputs, 1, 2)
	sim.add_command(&inputs, bump(1, 5))
	sim.add_command(&inputs, bump(1, -2))
	mark := sim.command_make(toy.Cmd, toy.Cmd_Mark{at = {1, 2}, count = 3, shapes = {.Ring}})
	sim.add_command(&inputs, mark) // slot 0
	stray := bump(3, 100) // slot 3 is not present: nobody's
	sim.add_command(&inputs, stray)
	sim.step(simulation, &inputs)
	state := &simulation.state
	testing.expect_value(t, toy.in_slot(state, 1).bumps, 2)
	testing.expect_value(t, toy.in_slot(state, 1).bump_sum, 3)
	testing.expect_value(t, toy.in_slot(state, 1).bump_fold, toy.bump_fold(toy.bump_fold(0, 5), -2))
	testing.expect_value(t, toy.in_slot(state, 0).marks, 1)
	last := toy.in_slot(state, 0).last_mark
	testing.expect(t, last.at == {1, 2} && last.count == 3 && last.shapes == {.Ring})
	testing.expect(t, toy.in_slot(state, 3) == nil)
	// An unknown kind or a wrong size reads as no command.
	inputs = {}
	inputs.present = {0}
	odd := bump(0, 1)
	odd.kind = 9
	sim.add_command(&inputs, odd)
	short := bump(0, 1)
	short.size = 3
	sim.add_command(&inputs, short)
	sim.step(simulation, &inputs)
	testing.expect_value(t, toy.in_slot(state, 0).bumps, 0)
	testing.expect(t, sim.command_value(&inputs.commands[0], toy.Cmd) == nil)
	testing.expect(t, sim.command_value(&inputs.commands[1], toy.Cmd) == nil)
	// command_from_bytes refuses what isn't one of the game's (command_make and send_command: a compile error)
	_, made := sim.command_from_bytes(toy.Cmd, 0, {1, 2, 3})
	testing.expect(t, !made)
	_, made = sim.command_from_bytes(toy.Cmd, 2, {1, 2, 3, 4})
	testing.expect(t, !made)
}

@(test)
inputs_differ_by_their_commands :: proc(t: ^testing.T) {
	a, b: toy.Inputs
	a.present, b.present = {0}, {0}
	sim.add_command(&a, bump(0, 1))
	testing.expect(t, !sim.inputs_same(&a, &b))
	sim.add_command(&b, bump(0, 1))
	testing.expect(t, sim.inputs_same(&a, &b))
	b.commands[0].data[0] = 2
	testing.expect(t, !sim.inputs_same(&a, &b))
	b.commands[0] = bump(1, 1)
	testing.expect(t, !sim.inputs_same(&a, &b))
	b.commands[0] = bump(0, 1)
	testing.expect(t, sim.inputs_same(&a, &b))
}

Only_Bump :: union {
	toy.Cmd_Bump,
}

Renamed :: struct {
	at:     [2]f32,
	normal: [3]f32,
	weight: f32,
	count:  i16,
	shape:  toy.Shape,
	shapes: toy.Shapes,
	loud:   bool,
	_pad:   [3]u8,
}

Bump_And_Renamed :: union {
	toy.Cmd_Bump,
	Renamed,
}

Same_As_Toy :: union {
	toy.Cmd_Bump,
	toy.Cmd_Mark,
}

@(test)
compat_covers_the_command_types :: proc(t: ^testing.T) {
	compat := sim.compat_of(&toy.GAME)
	with_commands :: proc($Cmd: typeid) -> u64 {
		game := sim.Game(toy.State, toy.Input, toy.World, toy.Event, Cmd, toy.PLAYERS) {
			name    = toy.GAME.name,
			version = toy.GAME.version,
			tick_hz = toy.GAME.tick_hz,
		}
		return sim.compat_of(&game)
	}
	testing.expect(t, with_commands(Only_Bump) != compat)
	testing.expect(t, with_commands(Bump_And_Renamed) != compat) // the same layout under another name
	testing.expect_value(t, with_commands(Same_As_Toy), compat)
}

@(test)
malformed_tick_records_are_refused :: proc(t: ^testing.T) {
	inputs: toy.Inputs
	inputs.present = {0, 1}
	sim.add_command(&inputs, bump(0, 1))
	sim.add_command(&inputs, bump(1, 2))
	writer := wire.writer_make()
	defer delete(writer.buf)
	sim.inputs_write(&writer, &inputs)
	good := writer.buf[:]
	head := 9 + size_of([toy.PLAYERS]toy.Input) - 1 // the command count's offset
	back: toy.Inputs
	reader := wire.reader_make(good)
	testing.expect(
		t,
		sim.inputs_read(&reader, &back) && sim.inputs_same(&back, &inputs) && wire.r_remaining(&reader) == 0,
	)
	Bad :: struct {
		at:    int,
		value: u8,
	}
	bad := []Bad {
		{head, sim.TICK_COMMANDS + 1}, // too many
		{head + 1, toy.PLAYERS}, // a player out of range
		{head + 3, sim.COMMAND_MAX + 1}, // over COMMAND_MAX
		{head + 3, 200}, // longer than the record
	}
	for case_, i in bad {
		data := make([]u8, len(good), context.temp_allocator)
		copy(data, good)
		data[case_.at] = case_.value
		reader = wire.reader_make(data)
		testing.expectf(t, !sim.inputs_read(&reader, &back), "case %d read", i)
	}
	// A slot past PLAYERS (4) present or replaced: the tick can't mark seats that don't exist.
	for at in ([]int{0, 3, 4, 7}) {
		data := make([]u8, len(good), context.temp_allocator)
		copy(data, good)
		data[at] |= at % 4 == 0 ? 0x10 : 0x80 // slot 4, or slot 31
		reader = wire.reader_make(data)
		testing.expectf(t, !sim.inputs_read(&reader, &back), "a slot past PLAYERS at byte %d read", at)
	}
	// Players out of order: player 1's command first.
	out_of_order := inputs
	out_of_order.commands[0], out_of_order.commands[1] = out_of_order.commands[1], out_of_order.commands[0]
	clear(&writer.buf)
	sim.inputs_write(&writer, &out_of_order)
	reader = wire.reader_make(writer.buf[:])
	testing.expect(t, !sim.inputs_read(&reader, &back))
	// Five of one player.
	five := inputs
	five.command_count = 5
	for k in 0 ..< 5 {
		five.commands[k] = bump(0, i32(k))
	}
	clear(&writer.buf)
	sim.inputs_write(&writer, &five)
	reader = wire.reader_make(writer.buf[:])
	testing.expect(t, !sim.inputs_read(&reader, &back))
	// One member in two join records (the relay never writes it; stepped, the second leave would overrun the tick's
	// left list).
	twice := inputs
	twice.member[0], twice.member[1] = 9, 9
	clear(&writer.buf)
	sim.inputs_write(&writer, &twice)
	reader = wire.reader_make(writer.buf[:])
	testing.expect(t, !sim.inputs_read(&reader, &back))
}

// Mutated input logs never crash the decoder; whatever it accepts replays.
@(test)
fuzz_input_log_decoder :: proc(t: ^testing.T) {
	input_log := sim.Input_Log(toy.Game) {
		seed = 4,
	}
	defer sim.log_destroy(&input_log)
	for k in 0 ..< 40 {
		inputs: toy.Inputs
		inputs.present = {0, 1, 2}
		inputs.input[1] = toy.scripted_input(4, 1, u32(k + 1))
		if k % 3 == 0 {
			sim.add_command(&inputs, bump(k % 3, i32(k)))
			sim.add_command(&inputs, bump(2, -i32(k)))
		}
		sim.log_append(&input_log, &inputs)
	}
	valid := sim.log_encode(&input_log)
	defer delete(valid)
	state := u32(0xBADC_0FFE)
	next :: proc(state: ^u32) -> u32 {
		state^ ~= state^ << 13
		state^ ~= state^ >> 17
		state^ ~= state^ << 5
		return state^
	}
	accepted := 0
	for _ in 0 ..< 3000 {
		data := make([dynamic]u8, context.temp_allocator)
		append(&data, ..valid)
		switch next(&state) % 3 {
		case 0:
			resize(&data, int(next(&state)) % len(data))
		case:
			for _ in 0 ..< 1 + next(&state) % 4 {
				i := sim.LOG_HEADER + int(next(&state)) % (len(data) - sim.LOG_HEADER)
				data[i] = u8(next(&state))
			}
		}
		back, ok := sim.log_decode(data[:], toy.Game)
		if ok {
			accepted += 1
			simulation := sim.create(&toy.GAME, back.seed)
			for k in 0 ..< len(back.ticks) {
				inputs := sim.log_inputs(&back, k)
				sim.step(simulation, &inputs)
			}
			sim.destroy(simulation)
			sim.log_destroy(&back)
		}
	}
	testing.expect(t, accepted > 0)
}
