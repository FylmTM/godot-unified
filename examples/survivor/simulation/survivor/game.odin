// survivor (examples/survivor/README.md): a horde survival game at scale. Up to four players hold out in an arena
// against waves of enemies, with crates, barrels and a level-up pick.
//
// The files, by feature: game (this: the descriptors and the tick), tuning (every rule number), input, state,
// events, world (the physics world from the level, bodies, init), phase, players, enemies, weapons, barrels, grid (the
// enemies' neighbour grid) and the scripted inputs (script). The balance test's bot is the tests' (tests/bot.odin).
package survivor

import "unified:dmath"
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

Game :: sim.Game(State, Input, World, Event, Command, Setup, Profile, PLAYERS)
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
	scripted_profile  = scripted_profile,
	bench_prepare     = bench_prepare,
	save              = save,
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
	scripted_profile  = scripted_profile,
	benches           = {{what = "survivor (stress tuning) holding 1000 enemies", entities = 1000, ticks = 600}},
	bench_prepare     = bench_prepare,
	save              = save,
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

// One tick: the systems in their order (examples/survivor/README.md, Systems), each group a timing zone.
tick :: proc(t: ^Tick) {
	{
		sim.zone(t, Zone.Players)
		apply_dev_commands(t)
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
	physics.debug_draw(t, t.world.phys, {.Shapes, .Contacts, .Sleep}) // nothing unless the dev UI shows them
}

// The dev commands (input.odin), first in the tick, by whoever sent them: a build without the dev UI never gets one
// (sim.DEV_COMMAND_PREFIX).
apply_dev_commands :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for _, player in sim.next(&players) {
		for sent in sim.commands(t, player) {
			#partial switch command in sent {
			case Command_Dev_Give_Xp:
				if character := sim.player_data(t, command.player); character != nil do character.xp += command.xp
			case Command_Dev_Skip_Wave:
				// The wave is the match's age (advance_phase), so the match starts one wave earlier. Early in a match
				// that is before tick 0: the u32 wraps, and the age, a difference, stays exact.
				if t.state.phase == .Match do t.state.match_tick -= sim.Game_Time(t.state.tuning.wave_ticks)
			case Command_Dev_Spawn:
				for i in 0 ..< int(command.count) {
					if !spawn_enemy(t.state, command.kind, dmath.DIR8[i % 8] * SPAWN_RING, t.time) do break
				}
			}
		}
	}
}

extra :: proc(world: ^World) -> sim.Extra {
	return physics.extra(world.phys, State)
}
