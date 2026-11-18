package minimal_3d

import "unified:sim"

State :: struct {
	players: sim.Players(Player_Data, Input, PLAYERS),
	balls:   sim.Table(Ball, MAX_BALLS),
}

Player_Data :: struct {
	position: [2]f32,
}

Ball :: struct {
	pos:            [2]f32,
	height:         f32,
	vertical_speed: f32,
	thrower:        sim.Player,
}
