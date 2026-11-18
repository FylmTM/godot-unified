// survivor (games/survivor/SPEC.md): a horde survival game at scale. Up to four players hold out in an arena against
// waves of enemies, with crates, barrels and a level-up pick.
//
// The files, by feature: game (this: the descriptors and the tick), tuning (every rule number), input, state,
// events, world (the physics world from the level, bodies, init), phase, players, enemies, weapons, barrels, grid (the
// enemies' neighbour grid) and the scripted inputs (script). The balance test's bot is the tests' (tests/bot.odin).
package survivor

import "unified:physics"
import "unified:sim"

TICK_HZ :: 64
PLAYERS :: 4 // input slots: the most players in the game at once

// The game's version (sim.Game.version, part of the netcode's compat): bump it when a rule or constant changes what a
// tick computes without changing the State or Input layout.
VERSION :: "6"

Game :: sim.Game(State, Input, World, Event, Cmd, PLAYERS)
Tick :: sim.Tick(Game)

// The game as played (the `play` tuning).
@(rodata)
GAME := Game {
	name              = "survivor",
	version           = VERSION,
	tick_hz           = TICK_HZ,
	content           = #load("../../game/levels/arena.level"), // the export of game/levels/arena.tscn (uni bake)
	world_create      = world_create,
	world_destroy     = world_destroy,
	extra             = extra,
	init              = init,
	tick              = tick,
	scripted_input    = scripted_input,
	scripted_commands = scripted_commands,
	bench_prepare     = bench_prepare,
}

// The same game with the `stress` tuning and hash-driven scripted inputs: what the headless binary, the end-to-end
// suite and the bench run.
@(rodata)
GAME_STRESS := Game {
	name              = "survivor-stress",
	version           = VERSION,
	tick_hz           = TICK_HZ,
	content           = #load("../../game/levels/arena.level"),
	world_create      = world_create,
	world_destroy     = world_destroy,
	extra             = extra,
	init              = init_stress,
	tick              = tick,
	scripted_input    = scripted_input,
	scripted_commands = scripted_commands,
	bench_prepare     = bench_prepare,
}

// One tick: the systems in the order the spec gives (games/survivor/SPEC.md, Systems).
tick :: proc(t: ^Tick) {
	update_players(t)
	pick_upgrades(t)
	spawn_waves(t)
	steer_enemies(t)
	hurt_players(t)
	fire(t)
	move_projectiles(t)
	explode_barrels(t)
	kill_enemies(t)
	collect_gems(t)
	level_up(t)
	physics.step(t.world.phys)
	read_back(t)
	advance_phase(t)
}

extra :: proc(world: ^World) -> sim.Extra {
	return physics.extra(world.phys, State)
}
