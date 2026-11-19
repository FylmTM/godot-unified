// minimal_3d (games/minimal_3d/README.md): 1-4 players move capsules on a floor and throw balls straight up.
//
// The files, by feature: game (this: the descriptor and the tick), input (the input and the commands), state, events,
// players, balls, the co-op pause (pause) and the scripted inputs (script).
package minimal_3d

import "unified:sim"

PLAYERS :: 4 // input slots: the most players in the game at once
TICK_HZ :: 64

// The game's version (sim.Game.version, part of the netcode's compat): bump it when a rule or constant changes what a
// tick computes without changing the State or Input layout, or two builds desync instead of refusing each other.
VERSION :: "2" // 2: the co-op pause, a throw cooldown

// The game's types for unified:sim: no World (no physics, no level).
Game :: sim.Game(State, Input, sim.No_World, Event, Cmd, sim.No_Setup, sim.No_Profile, PLAYERS)
// What every system gets: the state, the inputs and commands, the tick's player changes.
Tick :: sim.Tick(Game)

// The game: what the headless binary, the GDExtension and the tests run.
@(rodata)
GAME := Game {
	name              = "minimal_3d",
	version           = VERSION,
	tick_hz           = TICK_HZ,
	tick              = tick,
	scripted_input    = scripted_input,
	scripted_commands = scripted_commands,
}

// One tick: the systems in their order (games/minimal_3d/README.md, Systems).
tick :: proc(t: ^Tick) {
	place_new_players(t) // presence first: people come and go while paused
	apply_pause(t) // commands are read on paused ticks too
	if t.paused do return // the co-op pause: no system runs (a physics game returns before physics.step)
	move_players(t)
	throw_balls(t)
	move_balls(t)
}
