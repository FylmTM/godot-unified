package minimal_3d

import "unified:sim"

PLAYERS :: 4
TICK_HZ :: 64

Game :: sim.Game(State, Input, sim.No_World, Event, Cmd, PLAYERS)
Tick :: sim.Tick(Game)

@(rodata)
GAME := Game {
	name              = "minimal_3d",
	version           = "1",
	tick_hz           = TICK_HZ,
	tick              = tick,
	scripted_input    = scripted_input,
	scripted_commands = scripted_commands,
}

tick :: proc(t: ^Tick) {
	place_new_players(t)
	move_players(t)
	throw_balls(t)
	move_balls(t)
}
