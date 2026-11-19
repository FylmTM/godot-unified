// friendslop (games/friendslop/README.md): a co-op physics sandbox. Up to four wobbly characters ride platforms, bounce
// on pads, carry and throw things and each other, and take the trophy along a route of physics puzzles.
//
// The files, by feature: game (this: the descriptor and the tick), tuning (every rule number), input, state, events,
// world (the physics world, what the sim reads from each level, init and the level change), players (arrivals,
// movement, stuns, falls), hands (grab, hold, drop, throw, break free), items, platforms, pads, hits (knockback,
// bumpers, bells), triggers (plates, switches, locks), phase (the run), and the scripted inputs (script).
package friendslop

import "unified:physics"
import "unified:sim"

TICK_HZ :: 64
PLAYERS :: 4 // input slots: the most players in the game at once

// The game's version (sim.Game.version, part of the netcode's compat): bump it when a rule or constant changes what a
// tick computes without changing the State or Input layout.
VERSION :: "8" // 8: respawns, pad and bell cooldowns and the thrown tag are sim.Timers (a tick earlier in places)

// The game's levels, in GAME.levels' order (the State's `level` says which is active): the hub yard and the route.
Level_Id :: enum u8 {
	Hub,
	Route,
}

Game :: sim.Game(State, Input, World, Event, Cmd, sim.No_Setup, sim.No_Profile, PLAYERS)
Tick :: sim.Tick(Game)

@(rodata)
GAME := Game {
	name              = "friendslop",
	version           = VERSION,
	tick_hz           = TICK_HZ,
	// game/levels/hub.tscn's and route.tscn's (uni bake)
	levels            = {
		{"hub", #load("../../game/levels/hub.level")},
		{"route", #load("../../game/levels/route.level")},
	},
	world_create      = world_create,
	world_destroy     = world_destroy,
	extra             = extra,
	init              = init,
	tick              = tick,
	scripted_input    = scripted_input,
	scripted_commands = scripted_commands,
}

// One tick: the systems in their order (games/friendslop/README.md, Systems).
tick :: proc(t: ^Tick) {
	update_presence(t)
	use_hands(t)
	update_holds(t)
	move_players(t)
	move_platforms(t)
	launch_from_pads(t)
	bump_players(t)
	physics.step(t.world.phys)
	apply_hits(t)
	age_throws(t)
	press_triggers(t)
	recover_from_stuns(t)
	respawn_fallen(t)
	return_fallen_items(t)
	advance_phase(t)
	travel(t)
}

extra :: proc(world: ^World) -> sim.Extra {
	return physics.extra(world.phys, State)
}
