// Saves: Game.save through save_changed, and a Setup as JSON and back (setup_to_json, setup_from_json, value_from_json).
package test_sim

import "base:runtime"
import "core:strings"
import "core:testing"

import "../toy"
import "unified:sim"

Hero_Class :: enum u8 {
	Vanguard,
	Arcanist,
}

Relic :: enum u8 {
	Coin,
	Lantern,
	Anchor,
}

Saved_Hero :: struct {
	class: Hero_Class,
	_pad:  u8,
	hp:    i16,
	deck:  sim.List(u8, 12),
	_pad2: [3]u8,
}

// A run save's shape: nested Lists of structs, enums by name, a bit_set, an enumerated array, f32, bool, a u64 past
// i64's range, a long array (value_json writes it as an object of its non-zero elements).
Run_Setup :: struct {
	seed:     u64,
	floor:    u8,
	hard:     bool,
	relics:   bit_set[Relic;u8],
	_pad:     u8,
	scale:    f32,
	heroes:   sim.List(Saved_Hero, 4),
	by_kind:  [Hero_Class]i16,
	seen:     [80]u8,
	order:    sim.Queue(u8, 3),
	_pad2:    [5]u8,
	unlocked: sim.Bits(10),
}

Save_State :: struct {
	floor:   u32,
	spawned: u32,
	players: sim.Players(u32, sim.No_Profile, sim.No_Input, 2),
}

Save_Game :: sim.Game(Save_State, sim.No_Input, sim.No_World, toy.Event, sim.No_Commands, Run_Setup, sim.No_Profile, 2)

SAVE_GAME := Save_Game {
	name = "save",
	version = "1",
	tick_hz = 64,
	setup = {scale = 1, floor = 1}, // the defaults a save that lacks them keeps
	tick = proc(t: ^sim.Tick(Save_Game)) {t.state.floor = t.number / 10},
	// every tick gives the floor: the save changes when a new floor starts (every 10 ticks)
	save = proc(state: ^Save_State, setup: ^Run_Setup) -> bool {
		setup.floor = u8(state.floor)
		return true
	},
}

run_setup :: proc() -> (setup: Run_Setup) {
	setup.seed = 0xF000_0000_0000_0001 // past i64's range
	setup.floor = 3
	setup.hard = true
	setup.relics = {.Coin, .Anchor}
	setup.scale = 1.25
	vanguard := Saved_Hero {
		class = .Vanguard,
		hp    = -2,
	}
	for card in ([]u8{1, 1, 2, 7}) do sim.append(&vanguard.deck, card)
	arcanist := Saved_Hero {
		class = .Arcanist,
		hp    = 40,
	}
	sim.append(&arcanist.deck, 9)
	sim.append(&setup.heroes, vanguard)
	sim.append(&setup.heroes, arcanist)
	setup.by_kind = {
		.Vanguard = 3,
		.Arcanist = -4,
	}
	setup.seen[2], setup.seen[70] = 5, 6
	sim.append(&setup.order, 4)
	sim.append(&setup.order, 5)
	return
}

// A Setup goes to JSON and back to the same bytes, its names readable in the text.
@(test)
a_setup_round_trips_through_json :: proc(t: ^testing.T) {
	setup := run_setup()
	text := sim.setup_to_json(&setup, context.temp_allocator)
	for name in ([]string{`"class":"Arcanist"`, `"relics":["Coin","Anchor"]`, `"deck":[1,1,2,7]`, `"seed":17293822569102704641`}) {
		testing.expectf(t, strings.contains(text, name), "%s in %s", name, text)
	}
	back, problem := sim.setup_from_json(&SAVE_GAME, text)
	testing.expect_value(t, problem, "")
	testing.expect(t, string(sim.bytes_of(&back)) == string(sim.bytes_of(&setup)), "the same bytes back")
	// reading allocates nothing unless it reports a problem
	again: Run_Setup
	{
		context.allocator, context.temp_allocator = runtime.panic_allocator(), runtime.panic_allocator()
		problem = sim.value_from_json(type_info_of(Run_Setup), &again, text)
	}
	testing.expect(t, problem == "" && again == setup, "read with no allocator")
}

// A save from another build: a field it lacks keeps the default, a key this build lacks (of any shape) is skipped;
// what this build can't hold is refused, and the default comes back.
@(test)
a_setup_from_another_build :: proc(t: ^testing.T) {
	older, problem := sim.setup_from_json(&SAVE_GAME, `{"seed":7,"heroes":[{"hp":5,"deck":[3]}]}`)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, older.seed, 7)
	testing.expect_value(t, older.floor, 1) // the default
	testing.expect_value(t, older.scale, 1)
	testing.expect(
		t,
		older.heroes.count == 1 && older.heroes.items[0].hp == 5 && older.heroes.items[0].class == .Vanguard,
	)
	newer, newer_problem := sim.setup_from_json(
		&SAVE_GAME,
		` { "gold" : 12, "floor": 4, "map": {"nodes": [[1, 2], {"x": "a\"b"}], "ok": true, "n": null}, "_pad": 9 } `,
	)
	testing.expect_value(t, newer_problem, "")
	testing.expect_value(t, newer.floor, 4)
	refused := [?][2]string {
		{`{"floor":300}`, "out of"},
		{`{"heroes":[{"class":"Bard"}]}`, "Bard"},
		{`{"relics":["Coin","Sword"]}`, "Sword"},
		{`{"heroes":[{},{},{},{},{}]}`, "more than 4"},
		{`{"heroes":[{"class":7}]}`, "outside its declared values"}, // reads, but not as sent: setup_violation
		{`{"hard":2}`, "true or false"},
		{`{"floor":1} x`, "after the value"},
		{`{"floor":1`, "expected"},
		{`[1]`, "not an object"},
		{`{"seen":{"90":1}}`, "no element"},
		{`{"unlocked":[3,63]}`, "below 10"}, // a Bits holds its N indices, not its word's 64
		{`{"floor":1,"floor":2}`, "twice"},
		{`{"later":{"a":1,"a":2}}`, "twice"}, // in a skipped value too
		{`{"floor":0x1}`, "expected"},
		{`{"floor":+1}`, "integer"},
		{`{"floor":01}`, "integer"},
		{`{"floor":"1"}`, "integer"},
		{`{"scale":0x1p3}`, "expected"},
		{`{"scale":NaN}`, "number"},
		{`{"scale":"NaN"}`, "not finite"}, // reads, but not as sent
		{`{"hard":yes}`, "true or false"},
		{`{"floor":1,}`, "expected"},
		{`{"later":[1,]}`, "expected"},
		{`{"later":"a\qb"}`, "bad string"},
	}
	for entry in refused {
		setup, why := sim.setup_from_json(&SAVE_GAME, entry[0])
		testing.expectf(t, strings.contains(why, entry[1]), "%s: %q (wanted %q)", entry[0], why, entry[1])
		testing.expect(t, string(sim.bytes_of(&setup)) == string(sim.bytes_of(&SAVE_GAME.setup)), "the default back")
	}
	// nesting past JSON_DEPTH_MAX is a problem, never a deep recursion, also in a value it skips
	deep := strings.concatenate(
		{`{"later":`, strings.repeat("[", 20_000, context.temp_allocator), "}"},
		context.temp_allocator,
	)
	_, why := sim.setup_from_json(&SAVE_GAME, deep)
	testing.expectf(t, strings.contains(why, "nested deeper"), "%q", why)
	escaped, escaped_problem := sim.setup_from_json(&SAVE_GAME, `{"floor":5,"unlocked":[0,9]}`)
	testing.expect(t, escaped_problem == "" && escaped.floor == 5, escaped_problem)
	testing.expect(t, sim.has(&escaped.unlocked, 9) && !sim.has(&escaped.unlocked, 1))
}

// A Setup from another machine that no reader made: a Bits bit past its size and a List past its capacity don't read
// as sent (setup_violation), as an enum outside its values doesn't.
@(test)
a_setup_past_its_collections_does_not_read :: proc(t: ^testing.T) {
	setup := run_setup()
	testing.expect_value(t, sim.setup_violation(&SAVE_GAME, &setup), "")
	past_bits := setup
	past_bits.unlocked.words[0] |= 1 << 10
	testing.expect(t, sim.setup_violation(&SAVE_GAME, &past_bits) != "", "a Bits bit past N")
	past_list := setup
	past_list.heroes.count = 5
	testing.expect(t, sim.setup_violation(&SAVE_GAME, &past_list) != "", "a List past its capacity")
	past_queue := setup
	past_queue.order.head = 3
	testing.expect(t, sim.setup_violation(&SAVE_GAME, &past_queue) != "", "a Queue's head past its capacity")
}

// save_changed: Game.save's Setup on a tick, true only when its bytes differ from the last one; the session's Setup
// before the first.
@(test)
save_changed_reports_each_new_save_once :: proc(t: ^testing.T) {
	simulation := sim.create(&SAVE_GAME, 1)
	defer sim.destroy(simulation)
	saved := simulation.setup
	changes: [dynamic]u32
	defer delete(changes)
	for tick in u32(1) ..= 35 {
		inputs: sim.Inputs(Save_Game)
		sim.step(simulation, &inputs)
		if sim.save_changed(simulation, tick, &saved) do append(&changes, tick)
	}
	// floor 0 from tick 1 differs from the default's 1; floor 1 at tick 10 (== the default, but the last save was 0)
	testing.expect_value(t, len(changes), 4)
	if len(changes) == 4 do testing.expect(t, changes[0] == 1 && changes[1] == 10 && changes[2] == 20 && changes[3] == 30)
	testing.expect_value(t, saved.floor, 3)
	testing.expect(t, !sim.save_changed(simulation, 35, &saved), "the same save again is no change")
	testing.expect(t, sim.save_changed(simulation, 25, &saved), "an older tick in the ring")
	testing.expect_value(t, saved.floor, 2)
	testing.expect(t, !sim.save_changed(simulation, 1, &saved), "a tick gone from the ring")
}
