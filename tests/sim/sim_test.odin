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
	testing.expect_value(t, sim.plain_violation(type_info_of(toy.Inputs)), "")
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
		seed = 99,
	}
	defer sim.log_destroy(&lg)
	for k in 0 ..< 50 {
		in_: toy.Inputs
		in_.present = {0, 1}
		in_.replaced = {1} if k % 7 == 0 else {}
		in_.input[0] = toy.script(99, 0, u32(k + 1))
		in_.input[1] = toy.script(99, 1, u32(k + 1))
		append(&lg.ticks, in_)
	}
	data := sim.log_encode(&lg)
	defer delete(data)
	testing.expect_value(t, len(data), sim.LOG_HEADER + 50 * size_of(toy.Inputs))
	back, ok := sim.log_decode(data, toy.Input, toy.SLOTS)
	defer sim.log_destroy(&back)
	testing.expect(t, ok)
	testing.expect_value(t, back.seed, 99)
	testing.expect_value(t, len(back.ticks), 50)
	for k in 0 ..< 50 {
		testing.expect(t, back.ticks[k] == lg.ticks[k])
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
	b := sim.from_snapshot(&toy.GAME, data)
	testing.expect(t, b != nil)
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
	testing.expect(t, sim.from_snapshot(&toy.GAME, data) == nil)
}

@(test)
schema_finds_tables :: proc(t: ^testing.T) {
	sc := sim.schema_of(toy.State)
	things, ok := sim.find_table(sc, "things")
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, things.cap, 32)
	testing.expect(t, things.elem.id == toy.Thing)
	_, pos_is_global := sim.find_table(sc, "pos") // [4][2]f32: an array, but not of structs
	testing.expect(t, !pos_is_global)
	s := sim.create(&toy.GAME, 3)
	defer sim.destroy(s)
	_, h, _ := sim.spawn(&s.state.things)
	ptr, _, live := sim.entity_ptr(&s.state, things, int(h.index))
	testing.expect(t, live)
	testing.expect(t, ptr == rawptr(sim.get(&s.state.things, h)))
}

@(test)
ticks_of_seconds :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.ticks_of(1, 64), 64)
	testing.expect_value(t, sim.ticks_of(0.25, 64), 16)
	testing.expect_value(t, sim.ticks_of(3, 64), 192)
}
