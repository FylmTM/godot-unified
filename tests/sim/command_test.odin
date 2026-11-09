// Commands in the harness (src/sim/SPEC.md "Commands"): declared types are checked at create, a tick's record
// takes at most four per player, `tick` reads them per slot in order, they are part of what inputs_same
// compares and of compat_of, and malformed tick records are refused.
package test_sim

import "core:testing"

import "../toy"
import "unified:sim"
import "unified:wire"

Cmd_Padded :: struct {
	a: u8,
	b: u32,
}

Cmd_Pointer :: struct {
	p: ^int,
}

Cmd_Empty :: struct {}

Cmd_Max :: struct {
	bytes: [sim.COMMAND_MAX]u8,
}

Cmd_Too_Big :: struct {
	bytes: [sim.COMMAND_MAX + 1]u8,
}

@(test)
command_types_are_checked :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.commands_violation(toy.GAME.commands), "")
	testing.expect_value(t, sim.commands_violation({{"max", Cmd_Max}}), "")
	refused := [][]sim.Command_Kind {
		{{"padded", Cmd_Padded}},
		{{"pointer", Cmd_Pointer}},
		{{"empty", Cmd_Empty}},
		{{"too_big", Cmd_Too_Big}},
		{{"string", string}},
		{{"a", toy.Cmd_Bump}, {"b", toy.Cmd_Bump}}, // one type twice
		{{"a", toy.Cmd_Bump}, {"a", toy.Cmd_Mark}}, // one name twice
	}
	for kinds in refused {
		testing.expectf(t, sim.commands_violation(kinds) != "", "%v accepted", kinds[len(kinds) - 1].id)
	}
}

bump :: proc(slot: int, amount: i32) -> sim.Command {
	c, ok := sim.command_make(toy.GAME.commands, toy.Cmd_Bump{amount})
	assert(ok)
	c.slot = u8(slot)
	return c
}

@(test)
a_tick_takes_four_commands_per_player :: proc(t: ^testing.T) {
	in_: toy.Inputs
	for k in 0 ..< 4 {
		testing.expect(t, sim.add_command(&in_, bump(2, i32(k))))
	}
	testing.expect(t, !sim.add_command(&in_, bump(2, 4))) // the 5th waits
	testing.expect(t, sim.add_command(&in_, bump(0, 10)))
	testing.expect(t, sim.add_command(&in_, bump(3, 30)))
	testing.expect(t, sim.add_command(&in_, bump(0, 11)))
	testing.expect(t, !sim.add_command(&in_, bump(toy.SLOTS, 0))) // no such slot
	testing.expect_value(t, in_.n_commands, 7)
	// By slot, each slot's in the order added.
	want := [?][2]i32{{0, 10}, {0, 11}, {2, 0}, {2, 1}, {2, 2}, {2, 3}, {3, 30}}
	for w, i in want {
		c := &in_.commands[i]
		c.id = toy.Cmd_Bump
		b, _ := sim.command_as(c, toy.Cmd_Bump)
		testing.expect(t, i32(c.slot) == w[0] && b.amount == w[1])
	}
	testing.expect_value(t, len(sim.commands(&in_, 0)), 2)
	testing.expect_value(t, len(sim.commands(&in_, 1)), 0)
	testing.expect_value(t, len(sim.commands(&in_, 2)), 4)
	testing.expect_value(t, len(sim.commands(&in_, 3)), 1)
	// At most TICK_COMMANDS in all.
	big: sim.Inputs(toy.Input, 8)
	for k in 0 ..< 32 {
		sim.add_command(&big, bump(k % 8, i32(k)))
	}
	testing.expect_value(t, big.n_commands, sim.TICK_COMMANDS)
}

@(test)
tick_reads_commands_by_type :: proc(t: ^testing.T) {
	s := sim.create(&toy.GAME, 3)
	defer sim.destroy(s)
	in_: toy.Inputs
	in_.present = {0, 1}
	sim.add_command(&in_, bump(1, 5))
	sim.add_command(&in_, bump(1, -2))
	mark, ok := sim.command_make(toy.GAME.commands, toy.Cmd_Mark{at = {1, 2}, count = 3, shapes = {.Ring}})
	testing.expect(t, ok)
	sim.add_command(&in_, mark) // slot 0
	stray := bump(3, 100) // slot 3 is not present: ignored by the toy
	sim.add_command(&in_, stray)
	sim.step(s, &in_)
	st := &s.state
	testing.expect_value(t, st.bumps[1], 2)
	testing.expect_value(t, st.bump_sum[1], 3)
	testing.expect_value(t, st.bump_fold[1], toy.bump_fold(toy.bump_fold(0, 5), -2))
	testing.expect_value(t, st.marks[0], 1)
	testing.expect(t, st.last_mark[0].at == {1, 2} && st.last_mark[0].count == 3 && st.last_mark[0].shapes == {.Ring})
	testing.expect_value(t, st.bumps[3], 0)
	// An unknown kind or a wrong size never matches a type.
	in_ = {}
	in_.present = {0}
	odd := bump(0, 1)
	odd.kind = 9
	sim.add_command(&in_, odd)
	short := bump(0, 1)
	short.size = 3
	sim.add_command(&in_, short)
	sim.step(s, &in_)
	testing.expect_value(t, st.bumps[0], 0)
	testing.expect(t, in_.commands[0].id == nil && in_.commands[1].id == nil)
	_, as_mark := sim.command_as(&in_.commands[0], toy.Cmd_Mark)
	testing.expect(t, !as_mark)
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
	b.commands[0].id = nil // filled in by the harness: not compared
	testing.expect(t, sim.inputs_same(&a, &b))
}

@(test)
compat_covers_the_command_types :: proc(t: ^testing.T) {
	g := toy.GAME
	c := sim.compat_of(&g)
	g.commands = {{"bump", toy.Cmd_Bump}}
	testing.expect(t, sim.compat_of(&g) != c)
	g.commands = {{"bump", toy.Cmd_Bump}, {"marker", toy.Cmd_Mark}}
	testing.expect(t, sim.compat_of(&g) != c)
	g.commands = {{"bump", toy.Cmd_Bump}, {"mark", toy.Cmd_Mark}}
	testing.expect_value(t, sim.compat_of(&g), c)
}

@(test)
malformed_tick_records_are_refused :: proc(t: ^testing.T) {
	in_: toy.Inputs
	in_.present = {0, 1}
	sim.add_command(&in_, bump(0, 1))
	sim.add_command(&in_, bump(1, 2))
	w := wire.writer_make()
	defer delete(w.buf)
	sim.inputs_write(&w, &in_)
	good := w.buf[:]
	head := 9 + size_of([toy.SLOTS]toy.Input) - 1 // the command count's offset
	back: toy.Inputs
	r := wire.reader_make(good)
	testing.expect(t, sim.inputs_read(&r, &back) && sim.inputs_same(&back, &in_) && wire.r_remaining(&r) == 0)
	Bad :: struct {
		at:    int,
		value: u8,
	}
	bad := []Bad {
		{head, sim.TICK_COMMANDS + 1}, // too many
		{head + 1, toy.SLOTS}, // a slot out of range
		{head + 3, sim.COMMAND_MAX + 1}, // over COMMAND_MAX
		{head + 3, 200}, // longer than the record
	}
	for b, i in bad {
		data := make([]u8, len(good), context.temp_allocator)
		copy(data, good)
		data[b.at] = b.value
		r = wire.reader_make(data)
		testing.expectf(t, !sim.inputs_read(&r, &back), "case %d read", i)
	}
	// Slots out of order: slot 1's command first.
	ooo := in_
	ooo.commands[0], ooo.commands[1] = ooo.commands[1], ooo.commands[0]
	clear(&w.buf)
	sim.inputs_write(&w, &ooo)
	r = wire.reader_make(w.buf[:])
	testing.expect(t, !sim.inputs_read(&r, &back))
	// Five of one slot.
	five := in_
	five.n_commands = 5
	for k in 0 ..< 5 {
		five.commands[k] = bump(0, i32(k))
	}
	clear(&w.buf)
	sim.inputs_write(&w, &five)
	r = wire.reader_make(w.buf[:])
	testing.expect(t, !sim.inputs_read(&r, &back))
}

// Mutated input logs never crash the decoder; whatever it accepts replays.
@(test)
fuzz_input_log_decoder :: proc(t: ^testing.T) {
	lg := sim.Input_Log(toy.Input, toy.SLOTS) {
		seed = 4,
	}
	defer sim.log_destroy(&lg)
	for k in 0 ..< 40 {
		in_: toy.Inputs
		in_.present = {0, 1, 2}
		in_.input[1] = toy.script(4, 1, u32(k + 1))
		if k % 3 == 0 {
			sim.add_command(&in_, bump(k % 3, i32(k)))
			sim.add_command(&in_, bump(2, -i32(k)))
		}
		sim.log_append(&lg, &in_)
	}
	valid := sim.log_encode(&lg)
	defer delete(valid)
	x := u32(0xBADC_0FFE)
	next :: proc(x: ^u32) -> u32 {
		x^ ~= x^ << 13
		x^ ~= x^ >> 17
		x^ ~= x^ << 5
		return x^
	}
	accepted := 0
	for _ in 0 ..< 3000 {
		data := make([dynamic]u8, context.temp_allocator)
		append(&data, ..valid)
		switch next(&x) % 3 {
		case 0:
			resize(&data, int(next(&x)) % len(data))
		case:
			for _ in 0 ..< 1 + next(&x) % 4 {
				i := sim.LOG_HEADER + int(next(&x)) % (len(data) - sim.LOG_HEADER)
				data[i] = u8(next(&x))
			}
		}
		back, ok := sim.log_decode(data[:], toy.Input, toy.SLOTS)
		if ok {
			accepted += 1
			s := sim.create(&toy.GAME, back.seed)
			for k in 0 ..< len(back.ticks) {
				in_ := sim.log_inputs(&back, k)
				sim.step(s, &in_)
			}
			sim.destroy(s)
			sim.log_destroy(&back)
		}
	}
	testing.expect(t, accepted > 0)
}
