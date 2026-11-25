// holdout (examples/holdout/README.md): 1 to 4 players defend a core in a walled yard against eight waves, in first
// person, with a hitscan rifle, grenades and revives.
//
// The files, by feature: game (this: the descriptor and the tick), tuning (every rule number), input, state, events,
// world (the physics world, the navigation mesh, the yard's markers), players (arrivals, movement, downs, revives,
// respawns), rifle (shots), grenades, enemies (spawning, targets, walking the mesh, attacks), bolts, run (the lobby,
// the waves, the end), and the scripted inputs (script).
package holdout

import "unified:physics"
import "unified:sim"

PLAYERS :: 4 // input slots: the most players in the game at once
TICK_HZ :: 64

// The game's version (sim.Game.version, part of the netcode's compat): bump it when a rule or constant changes what a
// tick computes without changing the State or Input layout, or two builds desync instead of refusing each other.
VERSION :: "3"

Game :: sim.Game(State, Input, World, Event, sim.No_Commands, sim.No_Setup, sim.No_Profile, PLAYERS)
// What every system gets: the state, the world, the inputs, the tick's player changes.
Tick :: sim.Tick(Game)

@(rodata)
GAME := Game {
	name           = "holdout",
	version        = VERSION,
	tick_hz        = TICK_HZ,
	levels         = {{"yard", #load("../../game/levels/yard.level")}}, // game/levels/yard.tscn's (uni bake --nav)
	world_create   = world_create,
	world_destroy  = world_destroy,
	extra          = extra,
	init           = init,
	tick           = tick,
	scripted_input = scripted_input,
	benches        = {{what = "holdout holding the last wave's enemies", entities = ENEMY_CAP, ticks = 600}},
	bench_prepare  = bench_prepare,
}

// The game's sim (a running session or an offline run).
Sim :: sim.Sim(Game)

// One tick: the systems in their order (examples/holdout/README.md, Systems). Shots, grenades and bolts are resolved
// after the physics step, on this tick's state, which is what sim.seen_rewind measures back from.
tick :: proc(t: ^Tick) {
	update_presence(t)
	run_phase(t)
	spawn_enemies(t)
	move_players(t)
	choose_targets(t)
	move_enemies(t)
	physics.step(t.world.phys)
	fire_rifles(t)
	throw_grenades(t)
	burn_fuses(t)
	fly_bolts(t)
	enemy_attacks(t)
	revive_players(t)
	respawn_players(t)
	end_run(t)
}
