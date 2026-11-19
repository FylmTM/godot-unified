// survivor (games/survivor/README.md): a horde survival game at scale. Up to four players hold out in an arena against
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
VERSION :: "8" // 8: the fire cooldown runs on while dead (sim.Timer)

// The game's levels, in GAME.levels' order (the State's `level` says which is active).
Level_Id :: enum u8 {
	Arena,
}

Game :: sim.Game(State, Input, World, Event, Cmd, sim.No_Setup, sim.No_Profile, PLAYERS)
Tick :: sim.Tick(Game)

// The game as played (the `play` tuning).
@(rodata)
GAME := Game {
	name              = "survivor",
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
	bench_prepare     = bench_prepare,
}

// The same game with the `stress` tuning and hash-driven scripted inputs: what the headless binary, the end-to-end
// suite and the bench run.
@(rodata)
GAME_STRESS := Game {
	name              = "survivor-stress",
	version           = VERSION,
	tick_hz           = TICK_HZ,
	levels            = {{"arena", #load("../../game/levels/arena.level")}},
	world_create      = world_create,
	world_destroy     = world_destroy,
	extra             = extra,
	init              = init_stress,
	tick              = tick,
	scripted_input    = scripted_input,
	scripted_commands = scripted_commands,
	bench_prepare     = bench_prepare,
}

// The tick's timing zones (sim.zone): the dev UI's stacked graph and `uni bench`'s zone row; also the draw groups of
// the debug draws made in them.
Zone :: enum u8 {
	Players,
	Waves,
	Steer,
	Weapons,
	Barrels,
	Pickups,
	Physics,
	Phase,
}

// One tick: the systems in their order (games/survivor/README.md, Systems), each group a timing zone.
tick :: proc(t: ^Tick) {
	{
		sim.zone(t, Zone.Players)
		update_players(t)
		pick_upgrades(t)
	}
	{
		sim.zone(t, Zone.Waves)
		spawn_waves(t)
	}
	{
		sim.zone(t, Zone.Steer)
		steer_enemies(t)
		hurt_players(t)
	}
	{
		sim.zone(t, Zone.Weapons)
		fire(t)
		move_projectiles(t)
	}
	{
		sim.zone(t, Zone.Barrels)
		explode_barrels(t)
		kill_enemies(t)
	}
	{
		sim.zone(t, Zone.Pickups)
		collect_gems(t)
		level_up(t)
	}
	{
		sim.zone(t, Zone.Physics)
		physics.step(t.world.phys)
		read_back(t)
	}
	{
		sim.zone(t, Zone.Phase)
		advance_phase(t)
	}
	physics.debug_draw(t.world.phys, t, {.Shapes, .Contacts, .Sleep}) // nothing unless the dev UI shows them
}

extra :: proc(world: ^World) -> sim.Extra {
	return physics.extra(world.phys, State)
}
