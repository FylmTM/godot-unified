// minimal_3d (games/minimal_3d/README.md): 1-4 players move capsules on a floor and throw balls straight up.
//
// The files, by feature: game (this: the descriptor and the tick), input (the input and the command), state, events,
// players, balls and the scripted inputs (script).
package minimal_3d

import "unified:sim"

PLAYERS :: 4 // input slots: the most players in the game at once
TICK_HZ :: 64

// The game's types for unified:sim: no World (no physics, no level).
Game :: sim.Game(State, Input, sim.No_World, Event, Cmd, PLAYERS)
// What every system gets: the state, the inputs and commands, the tick's player changes.
Tick :: sim.Tick(Game)

// The game: what the headless binary, the GDExtension and the tests run.
@(rodata)
GAME := Game {
	name              = "minimal_3d",
	version           = "1",
	tick_hz           = TICK_HZ,
	tick              = tick,
	scripted_input    = scripted_input,
	scripted_commands = scripted_commands,
}

// One tick: the systems in their order (games/minimal_3d/README.md, Systems).
tick :: proc(t: ^Tick) {
	place_new_players(t)
	move_players(t)
	throw_balls(t)
	move_balls(t)
}
