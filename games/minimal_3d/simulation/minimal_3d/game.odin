package minimal_3d

import "unified:sim"

PLAYERS :: 4
TICK_HZ :: 64

Game :: sim.Game(State, Input, World, Event, Cmd, PLAYERS)
Tick :: sim.Tick(State, Input, World, Event, Cmd, PLAYERS)

@(rodata)
GAME := Game {
	name          = "minimal_3d",
	version       = "1",
	tick_hz       = TICK_HZ,
	world_create  = world_create,
	world_destroy = world_destroy,
	init          = init,
	tick          = tick,
}

world_create :: proc(seed: u64, content: []u8) -> ^World {
	return new(World)
}

world_destroy :: proc(world: ^World) {
	free(world)
}

init :: proc(t: ^Tick) {}

tick :: proc(t: ^Tick) {
	on_player_join(t)
	move_players(t)
	apply_commands(t)
	move_balls(t)
}
