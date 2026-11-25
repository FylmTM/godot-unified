// drift (examples/drift/README.md): the 2D example game. One to four players fly ships around a turning station in an
// arena drawn in Godot's 2D editor, shoot the rocks that drift in at it (big ones split, small ones drop gems) and warp
// through gates. Physics is Box3D locked to the plane (src/physics/README.md, 2D).
//
// The files, by feature: game (this: the descriptor and the tick), tuning (every rule number), input, state, events,
// world (the physics world from the level, bodies, init), ships, bullets, station, rocks, gates, gems, phase, and the
// scripted inputs (script).
package drift

import "unified:physics"
import "unified:sim"

TICK_HZ :: 64
PLAYERS :: 4 // input slots: the most players in the game at once

// The game's version (sim.Game.version, part of the netcode's compat): bump it when a rule or constant changes what a
// tick computes without changing the State or Input layout.
VERSION :: "2"

// The game's levels, in GAME.levels' order (the State's `level` says which is active).
Level_Id :: enum u8 {
	Arena,
}

Game :: sim.Game(State, Input, World, Event, Command, sim.No_Setup, sim.No_Profile, PLAYERS)
Tick :: sim.Tick(Game)

@(rodata)
GAME := Game {
	name              = "drift",
	version           = VERSION,
	tick_hz           = TICK_HZ,
	levels            = {{"arena", #load("../../game/levels/arena.level")}}, // game/levels/arena.tscn's (uni bake)
	world_create      = world_create,
	world_destroy     = world_destroy,
	extra             = extra,
	init              = init,
	tick              = tick,
	scripted_input    = scripted_input,
	scripted_commands = scripted_commands,
	benches           = {
		{what = "drift on the arena (2D physics locked to a plane: ships, splitting rocks)", ticks = 1800},
	},
}

// One tick: the systems in their order (examples/drift/README.md, Systems).
tick :: proc(t: ^Tick) {
	update_players(t)
	apply_commands(t)
	fly_ships(t)
	turn_station(t)
	physics.step(t.world.phys)
	move_bullets(t)
	hit_station(t)
	break_rocks(t)
	warp_ships(t)
	collect_gems(t)
	spawn_waves(t)
	advance_phase(t)
}

extra :: proc(world: ^World) -> sim.Extra {
	return physics.extra(world.phys, State)
}
