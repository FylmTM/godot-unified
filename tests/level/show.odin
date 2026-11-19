// A level as a physics game's only level, entered by init: what the tests that look at a level's built geometry use.
package test_level

import level_file "../level_file"
import "unified:physics"
import "unified:sim"

Show_Level :: enum u8 {
	Only,
}

Show :: struct {
	level:   sim.Active_Level(Show_Level),
	players: sim.Players(u32, sim.No_Profile, Pit_Input, 2),
}

Show_World :: struct {
	phys: ^physics.World,
}

Show_Game :: sim.Game(Show, Pit_Input, Show_World, Pit_Events, sim.No_Commands, sim.No_Setup, sim.No_Profile, 2)
Show_Tick :: sim.Tick(Show_Game)

SHOW := Show_Game {
	name = "show",
	version = "1",
	tick_hz = 64,
	world_create = proc(seed: u64, levels: []sim.Level_File, _: sim.No_Setup) -> ^Show_World {
		show_world := new(Show_World)
		problem: string
		show_world.phys, problem = physics.create_with_levels({tick_hz = 64}, levels)
		assert(problem == "", problem)
		return show_world
	},
	world_destroy = proc(show_world: ^Show_World) {
		physics.destroy(show_world.phys)
		free(show_world)
	},
	extra = proc(show_world: ^Show_World) -> sim.Extra {return physics.extra(show_world.phys, Show)},
	init = proc(t: ^Show_Tick) {physics.level_change(t, t.world.phys, Show_Level.Only)},
	tick = proc(t: ^Show_Tick) {physics.step(t.world.phys)},
}

// A sim of a copy of SHOW whose only level is `data`, entered by init (the world: show.world.phys). show_end frees it.
show :: proc(data: []u8) -> ^sim.Sim(Show_Game) {
	game := new_clone(SHOW)
	game.levels = make([]sim.Level_File, 1)
	game.levels[0] = {"only", data}
	return sim.create(game, 1)
}

// Frees a sim show made, and its game.
show_end :: proc(session: ^sim.Sim(Show_Game)) {
	game := session.game
	sim.destroy(session)
	delete(game.levels)
	free(game)
}

// A level file from Odin values (the shared oracle, tests/level_file).
encode :: level_file.encode
