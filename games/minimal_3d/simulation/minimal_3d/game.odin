package minimal_3d

import "unified:sim"

PLAYERS :: 4
MEMBERS :: 8
TICK_HZ :: 64
DT :: f32(1) / TICK_HZ

Game :: sim.Game(State, Input, World, PLAYERS)
Tick :: sim.Tick(State, Input, World, PLAYERS)

@(rodata)
GAME := Game {
	name          = "minimal_3d",
	version       = "1",
	tick_hz       = TICK_HZ,
	world_create  = world_create,
	world_destroy = world_destroy,
	init          = init,
	tick          = tick,
	events        = Event,
	commands      = Cmd,
}

world_create :: proc(seed: u64, content: []u8) -> ^World {
	return new(World)
}

world_destroy :: proc(world: ^World) {
	free(world)
}

init :: proc(state: ^State, world: ^World, seed: u64) {}

tick :: proc(t: ^Tick) {
	on_player_join(t)
	move_players(t)
	apply_commands(t)
	move_balls(t)
}
