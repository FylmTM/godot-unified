// The harness on the toy game: tables, handles and the iterator, the RNG and keyed rolls, the plain-data
// check, step/restore/checksum and the ring at each tick rate, typed events across rollback, input log and
// portable snapshot round trips, schema discovery.
package test_sim

import "core:strings"
import "core:testing"

import "../toy"
import "unified:sim"

Small :: sim.Table(toy.Thing, 4)

@(test)
zero_handle_is_null :: proc(t: ^testing.T) {
	table: Small
	_, handle, ok := sim.spawn(&table)
	testing.expect(t, ok)
	testing.expect_value(t, handle.index, 0)
	testing.expect(t, sim.get(&table, sim.Handle(toy.Thing){}) == nil)
	testing.expect(t, sim.get(&table, handle) == &table.items[0])
	testing.expect(t, sim.get(&table, sim.Handle(toy.Thing){index = 9, generation = 1}) == nil) // out of range
	testing.expect_value(t, size_of(sim.Handle(toy.Thing)), 8)
}

@(test)
stale_handles_are_rejected :: proc(t: ^testing.T) {
	table: Small
	_, first, _ := sim.spawn(&table)
	_, second, _ := sim.spawn(&table)
	testing.expect(t, sim.despawn(&table, first))
	testing.expect(t, sim.get(&table, first) == nil)
	testing.expect(t, !sim.despawn(&table, first))
	testing.expect(t, sim.get(&table, second) != nil)
	_, reused, _ := sim.spawn(&table) // LIFO reuse of the first slot, next generation
	testing.expect_value(t, reused.index, first.index)
	testing.expect(t, sim.get(&table, first) == nil)
	testing.expect(t, sim.get(&table, reused) != nil)
	testing.expect(t, sim.handle_key(reused) != sim.handle_key(first))
	testing.expect_value(t, table.count, 2)
	for _ in 0 ..< 2 {
		_, _, ok := sim.spawn(&table)
		testing.expect(t, ok)
	}
	_, _, full := sim.spawn(&table)
	testing.expect(t, !full)
}

// #154: a u16 generation wrapped after 65,536 reuses of one slot, and a stale handle then resolved to a
// new item. With u32 it takes 2^32.
@(test)
stale_handle_stays_stale_past_65536_reuses :: proc(t: ^testing.T) {
	table: Small
	_, stale, _ := sim.spawn(&table)
	sim.despawn(&table, stale)
	last: sim.Handle(toy.Thing)
	for _ in 0 ..< 70_000 {
		_, last, _ = sim.spawn(&table)
		if last.index != stale.index || sim.get(&table, stale) != nil {
			testing.fail_now(t, "a stale handle resolved to a new item")
		}
		sim.despawn(&table, last)
	}
	testing.expect_value(t, last.generation, 70_001)
	testing.expect_value(t, sim.handle_key(last), u64(70_001) << 32 | u64(last.index))
}

@(test)
tables_hold_more_than_65536 :: proc(t: ^testing.T) {
	Big :: sim.Table(u8, 70_000)
	table := new(Big)
	defer free(table)
	handle: sim.Handle(u8)
	for _ in 0 ..< 70_000 {
		_, handle, _ = sim.spawn(table)
	}
	testing.expect_value(t, handle.index, 69_999)
	testing.expect(t, sim.get(table, handle) != nil)
}

@(test)
iterator_walks_live_items_in_index_order :: proc(t: ^testing.T) {
	Ten :: sim.Table(toy.Thing, 10)
	table: Ten
	handles: [10]sim.Handle(toy.Thing)
	for i in 0 ..< 10 {
		thing, handle, _ := sim.spawn(&table)
		thing.life = i32(i)
		handles[i] = handle
	}
	for i in ([]int{1, 4, 5, 9}) {
		sim.despawn(&table, handles[i])
	}
	seen: [dynamic]i32
	defer delete(seen)
	items := sim.iterate(&table)
	for thing, handle in sim.next(&items) {
		append(&seen, thing.life)
		testing.expect(t, sim.get(&table, handle) == thing) // the handle comes with the item
		if thing.life % 2 == 0 do sim.despawn(&table, handle) // despawning the current item is safe
	}
	testing.expect(t, len(seen) == 6 && seen[0] == 0 && seen[1] == 2 && seen[2] == 3 && seen[5] == 8)
	testing.expect_value(t, table.count, 2) // 3 and 7 are left
	left: [dynamic]i32
	defer delete(left)
	items = sim.iterate(&table)
	for thing, _ in sim.next(&items) do append(&left, thing.life)
	testing.expect(t, len(left) == 2 && left[0] == 3 && left[1] == 7)
	empty: Small
	none := sim.iterate(&empty)
	for _, _ in sim.next(&none) do testing.fail(t)
}

@(test)
prev_item_needs_the_same_generation :: proc(t: ^testing.T) {
	previous: Small
	_, first, _ := sim.spawn(&previous)
	sim.spawn(&previous)
	current := previous
	item, ok := sim.prev_item(&previous, &current, 0)
	testing.expect(t, ok && item == &previous.items[0])
	_, ok = sim.prev_item((^Small)(nil), &current, 0)
	testing.expect(t, !ok)
	sim.despawn(&current, first)
	_, ok = sim.prev_item(&previous, &current, 0) // gone this tick
	testing.expect(t, !ok)
	sim.spawn(&current) // slot 0 reused: a different item
	_, ok = sim.prev_item(&previous, &current, 0)
	testing.expect(t, !ok)
	_, ok = sim.prev_item(&previous, &current, 1)
	testing.expect(t, ok)
}

// SplitMix64's reference outputs for seed 0 (Vigna's splitmix64.c), so a change to the mixer is caught.
@(test)
rng_is_splitmix64 :: proc(t: ^testing.T) {
	rng := sim.rng_seed(0)
	testing.expect_value(t, size_of(sim.Rng), 8)
	testing.expect_value(t, sim.rng_next(&rng), 0xE220A8397B1DCDAF)
	testing.expect_value(t, sim.rng_next(&rng), 0x6E789E6AA1B965F4)
	testing.expect_value(t, sim.rng_next(&rng), 0x06C45D188009454F)
	again := sim.rng_seed(0)
	sim.rng_next(&again)
	testing.expect_value(t, sim.rng_next(&again), 0x6E789E6AA1B965F4) // the same seed, the same stream
}

@(test)
rng_below_is_in_range_and_unbiased :: proc(t: ^testing.T) {
	rng := sim.rng_seed(7)
	counts: [3]int
	for _ in 0 ..< 30_000 {
		value := sim.rng_below(&rng, 3)
		testing.expect(t, value < 3)
		counts[value] += 1
	}
	for count in counts {
		testing.expect(t, count > 9_500 && count < 10_500)
	}
	unit := sim.rng_f32(&rng)
	testing.expect(t, unit >= 0 && unit < 1)
	big := sim.rng_below(&rng, 0xFFFF_FFFF)
	testing.expect(t, big < 0xFFFF_FFFF)
}

Purpose :: enum u8 {
	Loot,
	Spread,
	Crit,
}

roll_tick :: proc(seed: u64, number: u32) -> toy.Tick {
	return toy.Tick{seed = seed, number = number}
}

// Keyed rolls: deterministic, uniform, and each depends only on what it names (D7).
@(test)
keyed_rolls :: proc(t: ^testing.T) {
	tick := roll_tick(42, 100)
	// determinism: the same names give the same roll, whatever was rolled in between
	first := sim.roll_below(&tick, 1000, Purpose.Loot, key = 7, index = 3)
	sim.roll_below(&tick, 1000, Purpose.Spread)
	testing.expect_value(t, sim.roll_below(&tick, 1000, Purpose.Loot, key = 7, index = 3), first)
	// each name moves the roll: another seed, tick, purpose, key or index
	other_seed, other_tick := roll_tick(43, 100), roll_tick(42, 101)
	differs := 0
	for i in 0 ..< 64 {
		base := sim.roll_below(&tick, 1 << 30, Purpose.Loot, key = 5, index = i)
		differs += int(sim.roll_below(&other_seed, 1 << 30, Purpose.Loot, key = 5, index = i) != base)
		differs += int(sim.roll_below(&other_tick, 1 << 30, Purpose.Loot, key = 5, index = i) != base)
		differs += int(sim.roll_below(&tick, 1 << 30, Purpose.Crit, key = 5, index = i) != base)
		differs += int(sim.roll_below(&tick, 1 << 30, Purpose.Loot, key = 6, index = i) != base)
		differs += int(sim.roll_below(&tick, 1 << 30, Purpose.Loot, key = 5, index = i + 64) != base)
	}
	testing.expect_value(t, differs, 5 * 64)
	// distribution: 6 buckets over 60,000 rolls (keys and ticks varying), each within 4% of 10,000
	counts: [6]int
	for number in u32(0) ..< 600 {
		later := roll_tick(9, number)
		for key in u64(0) ..< 100 {
			counts[sim.roll_below(&later, 6, Purpose.Spread, key)] += 1
		}
	}
	for count in counts do testing.expect(t, count > 9_600 && count < 10_400)
	// neighbouring keys are independent: the low bit of key k and key k + 1 agree about half the time
	agree := 0
	for key in u64(0) ..< 10_000 {
		agree += int(sim.roll_below(&tick, 2, Purpose.Loot, key) == sim.roll_below(&tick, 2, Purpose.Loot, key + 1))
	}
	testing.expect(t, agree > 4_800 && agree < 5_200)
	// f32 rolls: [0, 1), mean about 1/2
	sum: f64
	for i in 0 ..< 10_000 {
		value := sim.roll_f32(&tick, Purpose.Spread, index = i)
		testing.expect(t, value >= 0 && value < 1)
		sum += f64(value)
	}
	testing.expect(t, sum / 10_000 > 0.49 && sum / 10_000 < 0.51)
}

Padded :: struct {
	small: u8,
	large: u32,
}

With_Pointer :: struct {
	pointer: ^int,
}

Sized :: struct {
	f: i64,
	a: i8,
	b: u8,
	c: i16,
	d: u32be,
	e: f32,
	g: enum u16 {
		A,
	},
	h: bit_set[0 ..< 16;u16],
	i: [8]u8,
}

Flags :: struct {
	on:   bool,
	_pad: [3]u8,
	more: b32,
}

@(test)
plain_data_check :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.plain_violation(type_info_of(toy.State)), "")
	testing.expect_value(t, sim.plain_violation(type_info_of(toy.Input)), "")
	testing.expect_value(t, sim.wire_violation(type_info_of(toy.Input)), "")
	testing.expect_value(t, sim.plain_violation(type_info_of(Sized)), "")
	testing.expect(t, sim.wire_violation(type_info_of(Sized)) != "", "Sized holds an f32: not an Input")
	testing.expect(t, sim.plain_violation(type_info_of(Padded)) != "")
	testing.expect(t, sim.plain_violation(type_info_of(With_Pointer)) != "")
	testing.expect(t, sim.plain_violation(type_info_of([]u8)) != "")
	// Platform-sized integers and any float but f32, also inside an enum, a bit_set or an array.
	Default_Enum :: enum {
		A,
	}
	Distinct_Int :: distinct int
	for type in ([]typeid{int, uint, uintptr, f64, f16, Default_Enum, bit_set[0 ..< 8;int], [2]f64, Distinct_Int}) {
		testing.expectf(t, sim.plain_violation(type_info_of(type)) != "", "%v accepted in the state", type)
	}
	// Bools and floats: in the state, yes; in an Input (from another machine), no.
	testing.expect_value(t, sim.plain_violation(type_info_of(Flags)), "")
	testing.expect(t, sim.wire_violation(type_info_of(Flags)) != "")
	testing.expect(t, sim.wire_violation(type_info_of([4]b8)) != "")
	testing.expect_value(t, sim.plain_violation(type_info_of([2]f32)), "")
	testing.expect(t, sim.wire_violation(type_info_of([2]f32)) != "")
	testing.expect(t, sim.layout_hash(toy.State) != sim.layout_hash(Padded))
}

// Steps with slots 0 ..< players present (slot i is member i + 1, joining when nobody holds the slot).
run :: proc(simulation: ^toy.Sim, ticks: u32, players := 4) {
	for _ in 0 ..< ticks {
		number := simulation.tick + 1
		inputs: toy.Inputs
		for slot in 0 ..< players {
			inputs.present += {slot}
			if sim.slot_player(simulation, slot) == {} do sim.join(&inputs, slot, slot + 1)
			inputs.input[slot] = toy.scripted_input(simulation.seed, slot, number)
		}
		sim.step(simulation, &inputs)
	}
}

@(test)
restore_rewinds_and_resim_matches :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 42)
	defer sim.destroy(simulation)
	run(simulation, 30)
	at30 := sim.checksum(simulation)
	events30 := len(sim.events_at(simulation, 30))
	run(simulation, 10)
	at40 := sim.checksum(simulation)
	testing.expect(t, at40 != at30)
	testing.expect(t, sim.restore(simulation, 30))
	testing.expect_value(t, simulation.tick, 30)
	testing.expect_value(t, sim.checksum(simulation), at30)
	testing.expect_value(t, len(sim.events_at(simulation, 30)), events30)
	run(simulation, 10)
	testing.expect_value(t, sim.checksum(simulation), at40)
	run(simulation, 10)
	ring := u32(len(simulation.ring))
	testing.expect(t, !sim.restore(simulation, 50 - ring)) // overwritten in the ring
	testing.expect(t, sim.state_at(simulation, 50) != nil)
	testing.expect(t, sim.state_at(simulation, 50 - ring) == nil)
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

// A slot answers only for the tick whose contents it holds: between advance and save (and after step_unsaved)
// it has the new tick's events and no state, and nothing of the tick it held a ring ago.
@(test)
advance_takes_the_slot_over :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 42)
	defer sim.destroy(simulation)
	ring := u32(len(simulation.ring))
	run(simulation, ring + 3)
	tick := simulation.tick + 1
	testing.expect(t, sim.state_at(simulation, tick - ring) != nil)
	inputs: toy.Inputs
	sim.advance(simulation, &inputs)
	testing.expect(t, sim.state_at(simulation, tick - ring) == nil)
	testing.expect_value(t, len(sim.events_at(simulation, tick - ring)), 0)
	testing.expect(t, sim.state_at(simulation, tick) == nil)
	testing.expect_value(t, left_events(simulation, tick), toy.PLAYERS) // nobody present: everyone left
	sim.save(simulation)
	testing.expect(t, sim.state_at(simulation, tick) != nil)
	testing.expect_value(t, left_events(simulation, tick), toy.PLAYERS)
	// step_unsaved over a saved tick of an abandoned timeline: its own events, and no state.
	testing.expect(t, sim.restore(simulation, tick - 1))
	inputs.present = {0, 1, 2, 3}
	sim.step_unsaved(simulation, &inputs)
	testing.expect(t, sim.state_at(simulation, tick) == nil && !sim.restore(simulation, tick))
	testing.expect_value(t, left_events(simulation, tick), 0) // the same players as before: nobody left
}

// D8: the ring keeps ~250 ms at any tick rate, allocated at create: ring_size - 1 ticks back restore and
// re-simulate to the same checksum, one more is gone.
@(test)
ring_follows_the_tick_rate :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.ring_size(32), 8)
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

@(test)
bad_declarations_are_refused :: proc(t: ^testing.T) {
	Too_Big :: struct {
		bytes: [65]u8,
	}
	Not_Plain :: struct {
		pointer: ^int,
	}
	Big_Union :: union {
		Too_Big,
	}
	Pointer_Union :: union {
		Not_Plain,
	}
	No_Nil :: union #no_nil {
		sim.Event_Player_Joined,
		sim.Event_Player_Left,
	}
	No_Leave :: union {
		sim.Event_Player_Joined,
		toy.Event_Expired,
	}
	Event_Ticked :: struct {
		tick: u32, // every event carries its tick already (and its kind)
	}
	Reserved_Field :: union {
		sim.Event_Player_Joined,
		sim.Event_Player_Left,
		Event_Ticked,
	}
	testing.expect_value(t, sim.game_violation("toy", 64, toy.Cmd, toy.Event), "")
	testing.expect(t, sim.game_violation("toy", 64, Big_Union, toy.Event) != "")
	testing.expect(t, sim.game_violation("toy", 64, nil, Pointer_Union) != "")
	testing.expect(t, sim.game_violation("toy", 64, nil, No_Nil) != "")
	testing.expect(t, sim.game_violation("toy", 64, nil, No_Leave) != "") // the library's join and leave are listed
	testing.expect(t, strings.contains(sim.game_violation("toy", 64, nil, Reserved_Field), "`tick`"))
	testing.expect(t, sim.game_violation("toy", 64, nil, nil) != "")
	testing.expect(t, sim.game_violation("toy", 60, nil, toy.Event) != "") // not a power of two
	testing.expect(t, sim.game_violation("toy", 256, nil, toy.Event) != "") // above 128
	testing.expect(t, sim.game_violation("toy", 16, nil, toy.Event) != "") // below 32
}

@(test)
names_derive_from_the_types :: proc(t: ^testing.T) {
	commands := sim.command_names(toy.Cmd, context.temp_allocator)
	testing.expect(t, len(commands) == 2 && commands[0] == "bump" && commands[1] == "mark")
	events := sim.event_names(toy.Event, context.temp_allocator)
	testing.expect(
		t,
		len(events) == 4 && events[0] == "player_joined" && events[1] == "player_left" && events[3] == "expired",
	)
	// an event type may carry an Event_ prefix: the name leaves it out, like a command's Cmd_
	prefixed := sim.event_names(Prefixed_Events, context.temp_allocator)
	testing.expect(t, len(prefixed) == 2 && prefixed[0] == "rock_hit" && prefixed[1] == "plain")
}

Event_Rock_Hit :: struct {
	rock: u8,
}

Plain :: struct {
	value: u8,
}

Prefixed_Events :: union {
	Event_Rock_Hit,
	Plain,
}

@(test)
events_follow_the_inputs :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 1)
	defer sim.destroy(simulation)
	inputs: toy.Inputs
	sim.join(&inputs, 0, 1)
	sim.join(&inputs, 2, 7)
	inputs.input[0].buttons = {.Spawn}
	sim.step(simulation, &inputs)
	events := sim.events_at(simulation, 1)
	testing.expect_value(t, len(events), 3) // joined 0, joined 2 (the library's, first), spawned by 0
	if len(events) != 3 do return
	joined, is_joined := sim.event_value(&events[0], toy.Event).(sim.Event_Player_Joined)
	testing.expect(t, is_joined && joined.slot == 0 && joined.player.id == 1 && !joined.returning)
	second := sim.event_value(&events[1], toy.Event).(sim.Event_Player_Joined)
	testing.expect(t, second.slot == 2 && second.player.id == 7)
	spawned, is_spawned := sim.event_value(&events[2], toy.Event).(toy.Event_Spawned)
	testing.expect(t, is_spawned && spawned.player == joined.player)
	thing := sim.get(&simulation.state.things, spawned.thing)
	testing.expect(t, thing != nil && spawned.position == {thing.pos.x, thing.pos.y, 0})
	inputs = {}
	inputs.present = {0}
	inputs.input[0].buttons = {.Spawn}
	sim.step(simulation, &inputs)
	events = sim.events_at(simulation, 2)
	testing.expect_value(t, len(events), 1) // left 2 (the button still down: no press, no spawn)
	left, is_left := sim.event_value(&events[0], toy.Event).(sim.Event_Player_Left)
	testing.expect(t, is_left && left.player == second.player && left.slot == 2)
	// Re-simulating tick 2 with other inputs replaces its events: 2 stays, the button is released.
	testing.expect(t, sim.restore(simulation, 1))
	inputs.present = {0, 2}
	inputs.input[0].buttons = {}
	sim.step(simulation, &inputs)
	testing.expect_value(t, len(sim.events_at(simulation, 2)), 0)
	// pressed again (down now, up the tick before: sim.input_before): spawned
	inputs.input[0].buttons = {.Spawn}
	sim.step(simulation, &inputs)
	testing.expect_value(t, len(sim.events_at(simulation, 3)), 1)
	// A kind out of range or a wrong size reads as nil.
	broken := sim.Raw_Event {
		kind = 9,
		size = 1,
	}
	testing.expect(t, sim.event_value(&broken, toy.Event) == nil)
	broken = {
		kind = 0,
		size = 2,
	}
	testing.expect(t, sim.event_value(&broken, toy.Event) == nil)
}

@(test)
input_log_round_trip :: proc(t: ^testing.T) {
	input_log := sim.Input_Log(toy.Input, toy.PLAYERS) {
		seed    = 99,
		content = 0xC0FFEE,
		compat  = 0xB111D,
	}
	defer sim.log_destroy(&input_log)
	for k in 0 ..< 50 {
		inputs: toy.Inputs
		inputs.present = {0, 1}
		if k == 0 || k == 30 do sim.join(&inputs, 1, k + 2) // a join record, and another member later
		inputs.replaced = {1} if k % 7 == 0 else {}
		inputs.input[0] = toy.scripted_input(99, 0, u32(k + 1))
		inputs.input[1] = toy.scripted_input(99, 1, u32(k + 1))
		if k % 5 == 0 {
			bump, _ := sim.command_make(toy.Cmd, toy.Cmd_Bump{i32(k)})
			bump.slot = 1
			sim.add_command(&inputs, bump)
			mark, _ := sim.command_make(toy.Cmd, toy.Cmd_Mark{count = i16(k), shapes = {.Dot, .Star}})
			sim.add_command(&inputs, mark) // slot 0: goes before slot 1's
		}
		sim.log_append(&input_log, &inputs)
	}
	data := sim.log_encode(&input_log)
	defer delete(data)
	// an empty tick costs one byte for its command count and one for its join count; a command, 3 bytes plus its
	// struct; a join record 3
	command_bytes := 10 * (2 * sim.COMMAND_HEAD + size_of(toy.Cmd_Bump) + size_of(toy.Cmd_Mark))
	tick_bytes := 10 + size_of([toy.PLAYERS]toy.Input)
	testing.expect_value(t, len(data), sim.LOG_HEADER + 50 * tick_bytes + command_bytes + 2 * sim.JOIN_BYTES)
	back, ok := sim.log_decode(data, toy.Input, toy.PLAYERS)
	defer sim.log_destroy(&back)
	testing.expect(t, ok)
	testing.expect_value(t, back.seed, 99)
	testing.expect_value(t, back.content, 0xC0FFEE)
	testing.expect_value(t, back.compat, 0xB111D)
	testing.expect_value(t, len(back.ticks), 50)
	for k in 0 ..< 50 {
		decoded, original := sim.log_inputs(&back, k), sim.log_inputs(&input_log, k)
		testing.expect(t, sim.inputs_same(&decoded, &original) && decoded.replaced == original.replaced)
		testing.expect_value(t, decoded.member[1], u16(k + 2) if k == 0 || k == 30 else 0)
		if k % 5 == 0 {
			commands := decoded.commands
			testing.expect(t, decoded.command_count == 2 && commands[0].slot == 0 && commands[1].slot == 1)
		}
	}
	_, bad := sim.log_decode(data[:len(data) - 1], toy.Input, toy.PLAYERS)
	testing.expect(t, !bad)
}

@(test)
portable_snapshot_round_trip :: proc(t: ^testing.T) {
	original := sim.create(&toy.GAME, 7)
	defer sim.destroy(original)
	run(original, 90, 3)
	data := sim.snapshot_encode(original, 90)
	defer delete(data)
	restored, restore_err := sim.from_snapshot(&toy.GAME, data)
	testing.expect_value(t, restore_err, sim.Snap_Error.None)
	if restored == nil {
		return
	}
	defer sim.destroy(restored)
	testing.expect_value(t, restored.tick, 90)
	testing.expect_value(t, restored.seed, 7)
	testing.expect_value(t, sim.checksum(restored), sim.checksum(original))
	run(original, 60, 3)
	run(restored, 60, 3)
	testing.expect_value(t, sim.checksum(restored), sim.checksum(original))
	data[len(data) - 1] ~= 1 // the payload digest must catch corruption
	_, err := sim.from_snapshot(&toy.GAME, data)
	testing.expect_value(t, err, sim.Snap_Error.Checksum_Mismatch)
}

@(test)
schema_finds_tables :: proc(t: ^testing.T) {
	schema := sim.schema_of(toy.State)
	things: ^sim.Table_Info
	for &table in schema.tables {
		testing.expect(t, table.name != "pos") // [4][2]f32: an array, but not of structs
		if table.name == "things" {
			things = &table
		}
	}
	if !testing.expect(t, things != nil) {
		return
	}
	testing.expect_value(t, things.cap, 32)
	testing.expect(t, things.elem.id == toy.Thing)
	simulation := sim.create(&toy.GAME, 3)
	defer sim.destroy(simulation)
	_, handle, _ := sim.spawn(&simulation.state.things)
	base := ([^]u8)(&simulation.state)
	item := rawptr(&base[things.items_off + int(handle.index) * things.elem.size])
	testing.expect(t, item == rawptr(sim.get(&simulation.state.things, handle)))
	slot := (^sim.Slot)(&base[things.slots_off + int(handle.index) * size_of(sim.Slot)])
	testing.expect(t, slot.alive)
}

// An extra state that can be told to fail its restore.
Flaky :: struct {
	fail: bool,
}

flaky_game :: proc(flaky: rawptr) -> toy.Game {
	game := toy.GAME
	game.world_create = proc(seed: u64, _: []u8) -> ^toy.World {return new(toy.World)}
	game.extras = proc(world: ^toy.World) -> []sim.Extra {
		@(static) extra: [1]sim.Extra
		extra[0] = {
			data = g_flaky,
			save = proc(data: rawptr, slot: int) {},
			restore = proc(data: rawptr, slot: int) -> bool {return !(^Flaky)(data).fail},
			hash = proc(data: rawptr, state: rawptr, tick: u32, out: ^[dynamic]u8) {},
			image = proc(data: rawptr, slot: int) -> []u8 {return nil},
			load = proc(data: rawptr, bytes: []u8) -> bool {return true},
		}
		return extra[:]
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

@(test)
snapshot_errors_are_values :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 7)
	defer sim.destroy(simulation)
	run(simulation, 20, 3)
	data := sim.snapshot_encode(simulation, 20)
	defer delete(data)
	_, err := sim.from_snapshot(&toy.GAME, data[:10])
	testing.expect_value(t, err, sim.Snap_Error.Bad_Header)
	data[sim.SNAP_HEADER - 17] ~= 1 // the layout hash
	_, err = sim.from_snapshot(&toy.GAME, data)
	testing.expect_value(t, err, sim.Snap_Error.Layout_Differs)
	data[sim.SNAP_HEADER - 17] ~= 1
	// another block size (a state that grew) is another build's state too, not a bad header
	data[sim.SNAP_HEADER - 28] ~= 4 // the block size's low byte
	_, err = sim.from_snapshot(&toy.GAME, data)
	testing.expect_value(t, err, sim.Snap_Error.Layout_Differs)
	data[sim.SNAP_HEADER - 28] ~= 4
	// magic and version come first: a wrong magic is a bad header whatever follows
	data[0] = 'X'
	_, err = sim.from_snapshot(&toy.GAME, data)
	testing.expect_value(t, err, sim.Snap_Error.Bad_Header)
}

Swapped_Commands :: union {
	toy.Cmd_Mark,
	toy.Cmd_Bump,
}

@(test)
compat_tells_builds_apart :: proc(t: ^testing.T) {
	base := toy.GAME
	compat := sim.compat_of(&base)
	testing.expect(t, compat != 0)
	testing.expect_value(t, sim.compat_of(&base), compat) // stable
	other := base
	other.version = "2"
	testing.expect(t, sim.compat_of(&other) != compat)
	other = base
	other.name = "toy-variant"
	testing.expect(t, sim.compat_of(&other) != compat)
	other = base
	other.tick_hz = 128
	testing.expect(t, sim.compat_of(&other) != compat)
	other = base
	other.events = nil
	testing.expect(t, sim.compat_of(&other) != compat)
	other = base
	other.commands = Swapped_Commands // the same structs, other kinds
	testing.expect(t, sim.compat_of(&other) != compat)
	Other_Input :: struct {
		dx, dy:  i8,
		buttons: u16,
	}
	other_input := sim.Game(toy.State, Other_Input, toy.World, toy.PLAYERS) {
		name    = base.name,
		version = base.version,
		tick_hz = base.tick_hz,
	}
	testing.expect(t, sim.compat_of(&other_input) != compat) // same size, another layout
}

@(test)
inputs_compare_as_bytes :: proc(t: ^testing.T) {
	Float_Input :: struct {
		x: f32,
	}
	a, b: sim.Inputs(Float_Input, 2)
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
	simulation := sim.create(&toy.GAME, 7, level_a)
	defer sim.destroy(simulation)
	testing.expect_value(t, simulation.content_hash, sim.content_hash(level_a))
	inputs: toy.Inputs
	sim.join(&inputs, 0, 1)
	sim.step(simulation, &inputs)
	snap := sim.snapshot_encode(simulation, 1)
	defer delete(snap)
	_, err := sim.from_snapshot(&toy.GAME, snap, level_b)
	testing.expect_value(t, err, sim.Snap_Error.Content_Differs)
	_, err = sim.from_snapshot(&toy.GAME, snap)
	testing.expect_value(t, err, sim.Snap_Error.Content_Differs)
	restored, restore_err := sim.from_snapshot(&toy.GAME, snap, level_a)
	testing.expect_value(t, restore_err, sim.Snap_Error.None)
	if restored != nil do sim.destroy(restored)
	// Another build with the same state layout (here another game version) refuses the snapshot.
	other := toy.GAME
	other.version = "another"
	_, err = sim.from_snapshot(&other, snap, level_a)
	testing.expect_value(t, err, sim.Snap_Error.Build_Differs)
	// ... and so does a snapshot taken by a build on another library version (its compat in the header).
	another := transmute([8]u8)u64le(sim.compat_of(&toy.GAME, level_a, {version = sim.LIBRARY_VERSION + 1}))
	at := sim.SNAP_HEADER - 16 // the compat, before the payload digest
	copy(snap[at:], another[:])
	_, err = sim.from_snapshot(&toy.GAME, snap, level_a)
	testing.expect_value(t, err, sim.Snap_Error.Build_Differs)

	// The current version round-trips; any other version is refused.
	input_log := sim.Input_Log(toy.Input, toy.PLAYERS) {
		seed    = 5,
		content = sim.content_hash(level_a),
	}
	defer sim.log_destroy(&input_log)
	sim.log_append(&input_log, &inputs)
	data := sim.log_encode(&input_log)
	defer delete(data)
	back, ok := sim.log_decode(data, toy.Input, toy.PLAYERS)
	testing.expect(t, ok && back.seed == 5 && back.content == input_log.content && len(back.ticks) == 1)
	sim.log_destroy(&back)
	data[4] = u8(sim.LOG_VERSION - 1) // the version, little-endian, after the magic
	_, ok = sim.log_decode(data, toy.Input, toy.PLAYERS)
	testing.expect(t, !ok)
	snap[4] = u8(sim.SNAP_VERSION - 1)
	_, err = sim.from_snapshot(&toy.GAME, snap, level_a)
	testing.expect_value(t, err, sim.Snap_Error.Bad_Header)
}
