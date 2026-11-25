// horde (examples/horde/README.md): a 2D co-op horde arena. 1-4 heroes hold out against thousands of enemies with
// weapons that fire on their own: bolts, chain lightning and bombs.
//
// The files, by feature: game (this: the descriptor and the tick), tuning (every rule number), input, state, events,
// heroes (joins, picks, movement, damage, the phase), enemies (the neighbour grid, waves, steering, deaths), weapons
// (bolts, lightning, bombs, blasts), gems (XP and level-ups) and script (the scripted inputs and the bench's
// population).
package horde

import "unified:sim"

PLAYERS :: 4 // input slots: the most players in the game at once
TICK_HZ :: 64 // the library's rates are powers of two (sim.Game.tick_hz): the nearest to 60

// The game's version (sim.Game.version, part of the netcode's compat): bump it when a rule or constant changes what a
// tick computes without changing the State or Input layout, or two builds desync instead of refusing each other.
VERSION :: "2"

// The game's types for unified:sim: a World of scratch only (no physics, no level).
Game :: sim.Game(State, Input, World, Event, Command, sim.No_Setup, sim.No_Profile, PLAYERS)
// What every system gets: the state, the inputs and commands, the tick's player changes.
Tick :: sim.Tick(Game)

// The game: what the headless binary, the extension and the tests run.
@(rodata)
GAME := Game {
	name              = "horde",
	version           = VERSION,
	tick_hz           = TICK_HZ,
	tick              = tick,
	scripted_input    = scripted_input,
	scripted_commands = scripted_commands,
	bench_prepare     = bench_prepare,
	benches           = {
		{what = "horde holding 2000 enemies, 4 heroes with every weapon", entities = 2000, ticks = 600},
	},
}

// The tick's timing zones (sim.zone): the dev UI's stacked graph and `uni bench`'s zone row.
Zone :: enum u8 {
	Heroes,
	Waves,
	Steer,
	Weapons,
	Deaths,
	Gems,
	Phase,
}

// One tick: the systems in their order (examples/horde/README.md, Systems), each group a timing zone.
tick :: proc(t: ^Tick) {
	{
		sim.zone(t, Zone.Heroes)
		place_new_heroes(t)
		apply_commands(t)
		move_heroes(t)
	}
	{
		sim.zone(t, Zone.Waves)
		spawn_waves(t)
	}
	{
		sim.zone(t, Zone.Steer)
		enemy_grid_build(&t.world.grid, &t.state.enemies)
		steer_enemies(t)
		hurt_heroes(t)
	}
	{
		sim.zone(t, Zone.Weapons)
		fire_weapons(t)
		move_bolts(t)
		fly_bombs(t)
		age_blasts(t)
	}
	{
		sim.zone(t, Zone.Deaths)
		kill_enemies(t)
	}
	{
		sim.zone(t, Zone.Gems)
		pull_gems(t)
		level_up(t)
	}
	{
		sim.zone(t, Zone.Phase)
		respawn_heroes(t)
		advance_phase(t)
	}
}
