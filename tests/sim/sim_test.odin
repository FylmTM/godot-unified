// The harness on the toy game: tables and handles, RNG, plain-data check, step/restore/checksum,
// events across rollback, input log and portable snapshot round trips, schema discovery.
package test_sim

import "core:testing"

import "../toy"
import "unified:sim"

Small :: sim.Table(toy.Thing, 4)

@(test)
zero_handle_is_null :: proc(t: ^testing.T) {
	tb: Small
	_, h, ok := sim.spawn(&tb)
	testing.expect(t, ok)
	testing.expect_value(t, h.index, 0)
	testing.expect(t, sim.get(&tb, sim.Handle(toy.Thing){}) == nil)
	testing.expect(t, sim.get(&tb, h) == &tb.items[0])
	testing.expect(t, sim.get(&tb, sim.Handle(toy.Thing){index = 9, generation = 1}) == nil) // out of range
}

@(test)
stale_handles_are_rejected :: proc(t: ^testing.T) {
	tb: Small
	_, ha, _ := sim.spawn(&tb)
	_, hb, _ := sim.spawn(&tb)
	testing.expect(t, sim.despawn(&tb, ha))
	testing.expect(t, sim.get(&tb, ha) == nil)
	testing.expect(t, !sim.despawn(&tb, ha))
	testing.expect(t, sim.get(&tb, hb) != nil)
	_, ha2, _ := sim.spawn(&tb) // LIFO reuse of slot a, next generation
	testing.expect_value(t, ha2.index, ha.index)
	testing.expect(t, sim.get(&tb, ha) == nil)
	testing.expect(t, sim.get(&tb, ha2) != nil)
	testing.expect(t, sim.handle_key(ha2) != sim.handle_key(ha))
	testing.expect_value(t, tb.count, 2)
	for _ in 0 ..< 2 {
		_, _, ok := sim.spawn(&tb)
		testing.expect(t, ok)
	}
	_, _, full := sim.spawn(&tb)
	testing.expect(t, !full)
}

@(test)
rng_below_is_in_range_and_unbiased :: proc(t: ^testing.T) {
	r := sim.rng_seed(7)
	counts: [3]int
	for _ in 0 ..< 30_000 {
		v := sim.rng_below(&r, 3)
		testing.expect(t, v < 3)
		counts[v] += 1
	}
	for c in counts {
		testing.expect(t, c > 9_500 && c < 10_500)
	}
	testing.expect_value(t, sim.rng_seed(0).state, 1)
	f := sim.rng_f32(&r)
	testing.expect(t, f >= 0 && f < 1)
	big := sim.rng_below(&r, 0xFFFF_FFFF)
	testing.expect(t, big < 0xFFFF_FFFF)
}

Padded :: struct {
	a: u8,
	b: u32,
}

With_Pointer :: struct {
	p: ^int,
}

@(test)
plain_data_check :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.plain_violation(type_info_of(toy.State)), "")
	testing.expect_value(t, sim.plain_violation(type_info_of(toy.Input)), "")
	testing.expect(t, sim.plain_violation(type_info_of(Padded)) != "")
	testing.expect(t, sim.plain_violation(type_info_of(With_Pointer)) != "")
	testing.expect(t, sim.plain_violation(type_info_of([]u8)) != "")
	testing.expect(t, sim.layout_hash(toy.State) != sim.layout_hash(Padded))
}

run :: proc(s: ^toy.Sim, ticks: u32, players := 4) {
	for _ in 0 ..< ticks {
		tt := s.tick + 1
		in_: toy.Inputs
		for p in 0 ..< players {
			in_.present += {p}
			in_.input[p] = toy.script(s.seed, p, tt)
		}
		sim.step(s, &in_)
	}
}

@(test)
restore_rewinds_and_resim_matches :: proc(t: ^testing.T) {
	s := sim.create(&toy.GAME, 42)
	defer sim.destroy(s)
	run(s, 30)
	at30 := sim.checksum(s)
	ev30 := len(sim.events_at(s, 30))
	run(s, 10)
	at40 := sim.checksum(s)
	testing.expect(t, at40 != at30)
	testing.expect(t, sim.restore(s, 30))
	testing.expect_value(t, s.tick, 30)
	testing.expect_value(t, sim.checksum(s), at30)
	testing.expect_value(t, len(sim.events_at(s, 30)), ev30)
	run(s, 10)
	testing.expect_value(t, sim.checksum(s), at40)
	run(s, 10)
	testing.expect(t, !sim.restore(s, 50 - sim.RING)) // overwritten in the ring
	testing.expect(t, sim.state_at(s, 50) != nil)
	testing.expect(t, sim.state_at(s, 50 - sim.RING) == nil)
}

@(test)
events_follow_the_inputs :: proc(t: ^testing.T) {
	s := sim.create(&toy.GAME, 1)
	defer sim.destroy(s)
	in_: toy.Inputs
	in_.present = {0, 2}
	in_.input[0].buttons = 1
	sim.step(s, &in_)
	ev := sim.events_at(s, 1)
	testing.expect_value(t, len(ev), 3) // joined 0, spawned by 0, joined 2
	testing.expect_value(t, ev[0].kind, u16(toy.Event_Kind.Joined))
	testing.expect_value(t, ev[1].kind, u16(toy.Event_Kind.Spawned))
	testing.expect_value(t, ev[1].slot, 0)
	testing.expect_value(t, ev[2].slot, 2)
	in_.present = {0}
	sim.step(s, &in_)
	ev2 := sim.events_at(s, 2)
	testing.expect_value(t, len(ev2), 2) // spawned by 0 (button still down), left 2
	testing.expect_value(t, ev2[1].kind, u16(toy.Event_Kind.Left))
	// Re-simulating tick 2 with other inputs replaces its events.
	testing.expect(t, sim.restore(s, 1))
	in_.present = {0, 2}
	sim.step(s, &in_)
	testing.expect_value(t, len(sim.events_at(s, 2)), 1) // spawned only
}

@(test)
input_log_round_trip :: proc(t: ^testing.T) {
	lg := sim.Input_Log(toy.Input, toy.SLOTS) {
		seed    = 99,
		content = 0xC0FFEE,
	}
	defer sim.log_destroy(&lg)
	for k in 0 ..< 50 {
		in_: toy.Inputs
		in_.present = {0, 1}
		in_.replaced = {1} if k % 7 == 0 else {}
		in_.input[0] = toy.script(99, 0, u32(k + 1))
		in_.input[1] = toy.script(99, 1, u32(k + 1))
		if k % 5 == 0 {
			bump, _ := sim.command_make(toy.GAME.commands, toy.Cmd_Bump{i32(k)})
			bump.slot = 1
			sim.add_command(&in_, bump)
			mark, _ := sim.command_make(toy.GAME.commands, toy.Cmd_Mark{count = i16(k), shapes = {.Dot, .Star}})
			sim.add_command(&in_, mark) // slot 0: goes before slot 1's
		}
		sim.log_append(&lg, &in_)
	}
	data := sim.log_encode(&lg)
	defer delete(data)
	// an empty tick costs one byte for its command count; a command, 3 bytes plus its struct
	cmd_bytes := 10 * (2 * sim.COMMAND_HEAD + size_of(toy.Cmd_Bump) + size_of(toy.Cmd_Mark))
	testing.expect_value(t, len(data), sim.LOG_HEADER + 50 * (9 + size_of([toy.SLOTS]toy.Input)) + cmd_bytes)
	back, ok := sim.log_decode(data, toy.Input, toy.SLOTS)
	defer sim.log_destroy(&back)
	testing.expect(t, ok)
	testing.expect_value(t, back.seed, 99)
	testing.expect_value(t, back.content, 0xC0FFEE)
	testing.expect_value(t, len(back.ticks), 50)
	for k in 0 ..< 50 {
		a, b := sim.log_inputs(&back, k), sim.log_inputs(&lg, k)
		testing.expect(t, sim.inputs_same(&a, &b) && a.replaced == b.replaced)
		if k % 5 == 0 {
			testing.expect(t, a.n_commands == 2 && a.commands[0].slot == 0 && a.commands[1].slot == 1)
		}
	}
	_, bad := sim.log_decode(data[:len(data) - 1], toy.Input, toy.SLOTS)
	testing.expect(t, !bad)
}

@(test)
portable_snapshot_round_trip :: proc(t: ^testing.T) {
	a := sim.create(&toy.GAME, 7)
	defer sim.destroy(a)
	run(a, 90, 3)
	data := sim.snapshot_encode(a, 90)
	defer delete(data)
	b, berr := sim.from_snapshot(&toy.GAME, data)
	testing.expect_value(t, berr, sim.Snap_Error.None)
	if b == nil {
		return
	}
	defer sim.destroy(b)
	testing.expect_value(t, b.tick, 90)
	testing.expect_value(t, b.seed, 7)
	testing.expect_value(t, sim.checksum(b), sim.checksum(a))
	run(a, 60, 3)
	run(b, 60, 3)
	testing.expect_value(t, sim.checksum(b), sim.checksum(a))
	data[len(data) - 1] ~= 1 // the payload digest must catch corruption
	_, err := sim.from_snapshot(&toy.GAME, data)
	testing.expect_value(t, err, sim.Snap_Error.Checksum_Mismatch)
}

@(test)
schema_finds_tables :: proc(t: ^testing.T) {
	sc := sim.schema_of(toy.State)
	things: ^sim.Table_Info
	for &tb in sc.tables {
		testing.expect(t, tb.name != "pos") // [4][2]f32: an array, but not of structs
		if tb.name == "things" {
			things = &tb
		}
	}
	if !testing.expect(t, things != nil) {
		return
	}
	testing.expect_value(t, things.cap, 32)
	testing.expect(t, things.elem.id == toy.Thing)
	s := sim.create(&toy.GAME, 3)
	defer sim.destroy(s)
	_, h, _ := sim.spawn(&s.state.things)
	base := ([^]u8)(&s.state)
	testing.expect(
		t,
		rawptr(&base[things.items_off + int(h.index) * things.elem.size]) == rawptr(sim.get(&s.state.things, h)),
	)
	slot := (^sim.Slot)(&base[things.slots_off + int(h.index) * size_of(sim.Slot)])
	testing.expect(t, slot.alive)
}

// An extra state that can be told to fail its restore.
Flaky :: struct {
	fail: bool,
}

flaky_game :: proc(f: rawptr) -> toy.Game {
	g := toy.GAME
	g.world_create = proc(seed: u64, _: []u8) -> ^toy.World {return new(toy.World)}
	g.extras = proc(w: ^toy.World) -> []sim.Extra {
		@(static) extra: [1]sim.Extra
		extra[0] = {
			name = "flaky",
			data = g_flaky,
			save = proc(data: rawptr, slot: int) {},
			restore = proc(data: rawptr, slot: int) -> bool {return !(^Flaky)(data).fail},
			hash = proc(data: rawptr, state: rawptr, out: ^[dynamic]u8) {},
			image = proc(data: rawptr, slot: int) -> []u8 {return nil},
			load = proc(data: rawptr, bytes: []u8) -> bool {return true},
		}
		return extra[:]
	}
	g_flaky = (^Flaky)(f)
	return g
}

g_flaky: ^Flaky

@(test)
failed_restore_leaves_the_block :: proc(t: ^testing.T) {
	f: Flaky
	game := flaky_game(rawptr(&f))
	s := sim.create(&game, 7)
	defer sim.destroy(s)
	run(s, 10, 3)
	before := s.state
	f.fail = true
	testing.expect(t, !sim.restore(s, 5))
	testing.expect_value(t, s.tick, 10)
	testing.expect(t, s.state == before)
	f.fail = false
	testing.expect(t, sim.restore(s, 5))
	testing.expect_value(t, s.tick, 5)
}

@(test)
snapshot_errors_are_values :: proc(t: ^testing.T) {
	a := sim.create(&toy.GAME, 7)
	defer sim.destroy(a)
	run(a, 20, 3)
	data := sim.snapshot_encode(a, 20)
	defer delete(data)
	_, err := sim.from_snapshot(&toy.GAME, data[:10])
	testing.expect_value(t, err, sim.Snap_Error.Bad_Header)
	data[sim.SNAP_HEADER - 9] ~= 1 // the layout hash
	_, err = sim.from_snapshot(&toy.GAME, data)
	testing.expect_value(t, err, sim.Snap_Error.Layout_Differs)
}

@(test)
compat_tells_builds_apart :: proc(t: ^testing.T) {
	a := toy.GAME
	c := sim.compat_of(&a)
	testing.expect(t, c != 0)
	testing.expect_value(t, sim.compat_of(&a), c) // stable
	b := a
	b.version = "2"
	testing.expect(t, sim.compat_of(&b) != c)
	b = a
	b.name = "toy-variant"
	testing.expect(t, sim.compat_of(&b) != c)
	b = a
	b.tick_hz = 128
	testing.expect(t, sim.compat_of(&b) != c)
	Other_Input :: struct {
		dx, dy:  i8,
		buttons: u16,
	}
	o := sim.Game(toy.State, Other_Input, toy.World, toy.SLOTS) {
		name    = a.name,
		version = a.version,
		tick_hz = a.tick_hz,
	}
	testing.expect(t, sim.compat_of(&o) != c) // same size, another layout
}

@(test)
inputs_compare_as_bytes :: proc(t: ^testing.T) {
	F :: struct {
		x: f32,
	}
	a, b: sim.Inputs(F, 2)
	a.present = {0}
	b.present = {0}
	b.replaced = {0}
	testing.expect(t, sim.inputs_same(&a, &b)) // `replaced` is informational
	b.input[0].x = -0.0
	testing.expect(t, !sim.inputs_same(&a, &b)) // -0.0 == +0.0 as floats, not as bytes
	nan := transmute(f32)u32(0x7FC0_0000)
	a.input[0].x = nan
	b.input[0].x = nan
	testing.expect(t, sim.inputs_same(&a, &b)) // NaN != NaN as floats
	b.present = {0, 1}
	testing.expect(t, !sim.inputs_same(&a, &b))
}

// src/level/SPEC.md: the content (level) a sim was created with is part of its identity. Logs and
// snapshots of another format version are refused (only the current one is read).
@(test)
content_identity :: proc(t: ^testing.T) {
	level_a := []u8{1, 2, 3}
	level_b := []u8{1, 2, 4}
	testing.expect_value(t, sim.content_hash(nil), 0)
	testing.expect(t, sim.compat_of(&toy.GAME, level_a) != sim.compat_of(&toy.GAME, level_b))
	testing.expect(t, sim.compat_of(&toy.GAME, level_a) != sim.compat_of(&toy.GAME))
	a := sim.create(&toy.GAME, 7, level_a)
	defer sim.destroy(a)
	testing.expect_value(t, a.content_hash, sim.content_hash(level_a))
	ins: toy.Inputs
	ins.present = {0}
	sim.step(a, &ins)
	snap := sim.snapshot_encode(a, 1)
	defer delete(snap)
	_, err := sim.from_snapshot(&toy.GAME, snap, level_b)
	testing.expect_value(t, err, sim.Snap_Error.Content_Differs)
	_, err = sim.from_snapshot(&toy.GAME, snap)
	testing.expect_value(t, err, sim.Snap_Error.Content_Differs)
	b, err2 := sim.from_snapshot(&toy.GAME, snap, level_a)
	testing.expect_value(t, err2, sim.Snap_Error.None)
	if b != nil do sim.destroy(b)

	// The current version round-trips; any other version is refused.
	lg := sim.Input_Log(toy.Input, toy.SLOTS) {
		seed    = 5,
		content = sim.content_hash(level_a),
	}
	defer sim.log_destroy(&lg)
	sim.log_append(&lg, &ins)
	data := sim.log_encode(&lg)
	defer delete(data)
	back, ok := sim.log_decode(data, toy.Input, toy.SLOTS)
	testing.expect(t, ok && back.seed == 5 && back.content == lg.content && len(back.ticks) == 1)
	sim.log_destroy(&back)
	data[4] = u8(sim.LOG_VERSION - 1) // the version, little-endian, after the magic
	_, ok = sim.log_decode(data, toy.Input, toy.SLOTS)
	testing.expect(t, !ok)
	snap[4] = u8(sim.SNAP_VERSION - 1)
	_, err = sim.from_snapshot(&toy.GAME, snap, level_a)
	testing.expect_value(t, err, sim.Snap_Error.Bad_Header)
}
