// A value as JSON by RTTI (sim.value_json, value_json_at): tables, collections, enums, players and paths as the
// control socket answers a state query.
package test_sim

import "core:strings"
import "core:testing"

import "unified:sim"

Json_Kind :: enum u8 {
	Rock,
	Paper,
}

Json_Item :: struct {
	hp:   i32,
	kind: Json_Kind,
	_pad: [3]u8,
}

Json_State :: struct {
	items:   sim.Table(Json_Item, 4),
	bag:     sim.List(u16, 3),
	queue:   sim.Queue(u8, 3),
	open:    sim.Bits(70),
	flags:   bit_set[Json_Kind;u8],
	per:     [Json_Kind]f32,
	owner:   sim.Player,
	nobody:  [2]sim.No_Profile, // zero-size elements: each has an address but no bytes
	big:     [100]u8,
	speed:   f32,
	alive:   bool,
	_pad:    [3]u8,
	counter: u64,
}

json_of :: proc(state: ^Json_State, path := "") -> (text, problem: string) {
	out := strings.builder_make(context.temp_allocator)
	problem = sim.value_json_at(&out, type_info_of(Json_State), state, path)
	return strings.to_string(out), problem
}

json_state :: proc() -> (state: Json_State) {
	_, first, _ := sim.spawn(&state.items)
	item, _, _ := sim.spawn(&state.items)
	item.hp, item.kind = 7, .Paper
	sim.despawn(&state.items, first) // only index 1 is alive
	sim.append(&state.bag, 5)
	sim.append(&state.bag, 6)
	sim.append(&state.queue, 1)
	sim.append(&state.queue, 2)
	sim.append(&state.queue, 3)
	sim.pop_front(&state.queue)
	sim.append(&state.queue, 4) // wraps: oldest first is 2, 3, 4
	sim.incl(&state.open, 3)
	sim.incl(&state.open, 66)
	state.flags = {.Paper}
	state.per = {
		.Rock  = 0.5,
		.Paper = 1.25,
	}
	state.owner = sim.player_of_key(1 << 16 | 2)
	state.big[42] = 9
	state.speed = 3
	state.alive = true
	state.counter = 1 << 40
	return
}

@(test)
a_value_reads_as_json_the_way_tools_read_the_state :: proc(t: ^testing.T) {
	state := json_state()
	text, problem := json_of(&state)
	testing.expect_value(t, problem, "")
	testing.expect_value(
		t,
		text,
		`{"items":{"1":{"hp":7,"kind":"Paper"}},"bag":[5,6],"queue":[2,3,4],"open":[3,66],"flags":["Paper"],` +
		`"per":{"Rock":0.5,"Paper":1.25},"owner":65538,"nobody":[{},{}],"big":{"42":9},"speed":3,"alive":true,"counter":1099511627776}`,
	)
}

@(test)
a_path_names_a_field_an_item_or_an_element :: proc(t: ^testing.T) {
	state := json_state()
	cases := [?]struct {
		path, json: string,
	} {
		{"items[1].hp", "7"},
		{"items[0]", "null"},
		{"bag[1]", "6"},
		{"queue[0]", "2"},
		{"per[paper]", "1.25"},
		{"per", `{"Rock":0.5,"Paper":1.25}`},
		{"big[42]", "9"},
		{"owner", "65538"},
	}
	for test_case in cases {
		text, problem := json_of(&state, test_case.path)
		testing.expectf(t, problem == "" && text == test_case.json, "%s: %q %q", test_case.path, text, problem)
	}
	for bad in ([]string{"nope", "items[4]", "bag[2]", "speed.x", "items[0].hp", "per[stone]", "big[1"}) {
		text, problem := json_of(&state, bad)
		testing.expectf(t, problem != "" && text == "", "%s should not name anything: %q", bad, text)
	}
}
