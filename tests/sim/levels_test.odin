// src/sim/README.md, Levels: a game's levels are one identity (content_hash) and must match its level enum
// (levels_violation); the active level is a value in the block.
package test_sim

import "core:strings"
import "core:testing"

import "../toy"
import "unified:sim"

// Every level's name, bytes and place count in the levels' identity; none is 0.
@(test)
content_hash_covers_every_level :: proc(t: ^testing.T) {
	a := sim.Level_File{"meadow", {1, 2, 3}}
	b := sim.Level_File{"cave", {4, 5}}
	both := sim.content_hash({a, b})
	testing.expect_value(t, sim.content_hash(nil), 0)
	testing.expect(t, both != 0)
	testing.expect_value(t, sim.content_hash({a, b}), both)
	testing.expect(t, sim.content_hash({b, a}) != both, "another order")
	testing.expect(t, sim.content_hash({a, {"grotto", b.bytes}}) != both, "another name")
	testing.expect(t, sim.content_hash({a, {"cave", {4, 6}}}) != both, "other bytes")
	testing.expect(t, sim.content_hash({a}) != both, "fewer levels")
}

Three :: enum u8 {
	Hub,
	Route,
	Big_Cave,
}

Leveled :: struct {
	level:   sim.Active_Level(Three),
	players: sim.Players(u32, sim.No_Profile, toy.Input, 2),
}

Misnamed :: struct {
	area:    sim.Active_Level(Three),
	players: sim.Players(u32, sim.No_Profile, toy.Input, 2),
}

Unleveled :: struct {
	players: sim.Players(u32, sim.No_Profile, toy.Input, 2),
}

// What game_violation says of a game's levels and its State's Active_Level.
@(test)
levels_must_match_the_enum :: proc(t: ^testing.T) {
	three := []sim.Level_File{{"hub", {1}}, {"route", {2}}, {"big_cave", {3}}}
	Case :: struct {
		state:   typeid,
		levels:  []sim.Level_File,
		refusal: string, // "" when it runs
	}
	cases := []Case {
		{Leveled, three, ""},
		{Leveled, nil, ""}, // levels of the rules only
		{Unleveled, three[:1], ""}, // one level, never changed: no field needed
		{Unleveled, nil, ""},
		{Leveled, three[:2], "one level per member"},
		{Leveled, {three[1], three[0], three[2]}, "in the enum's order"},
		{Leveled, {three[0], three[1], {"cave", {3}}}, "in the enum's order"},
		{Misnamed, three, "name it `level`"},
		{Unleveled, three, "no `level: sim.Active_Level"},
	}
	for test_case, i in cases {
		reason := sim.levels_violation("game", type_info_of(test_case.state), test_case.levels)
		if test_case.refusal == "" {
			testing.expectf(t, reason == "", "case %d refused: %s", i, reason)
		} else {
			testing.expectf(t, strings.contains(reason, test_case.refusal), "case %d: %q", i, reason)
		}
	}
}

// The toy enters the meadow in init, and its travel command changes the level from the tick it is applied.
@(test)
level_enter_sets_the_block :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 3)
	defer sim.destroy(simulation)
	testing.expect_value(t, simulation.state.level, sim.Active_Level(toy.Area){since = 0, id = .Meadow})
	inputs: toy.Inputs
	inputs.present = {0}
	inputs.joins[0] = 1
	sim.step(simulation, &inputs)
	inputs.joins[0] = 0
	sim.step(simulation, &inputs)
	testing.expect(t, sim.add_command(&inputs, 0, toy.Command_Travel{.Cave}))
	sim.step(simulation, &inputs)
	testing.expect_value(t, simulation.state.level, sim.Active_Level(toy.Area){since = 3, id = .Cave})
}
