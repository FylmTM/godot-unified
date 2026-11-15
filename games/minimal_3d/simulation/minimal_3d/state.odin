package minimal_3d

import "unified:sim"

Input :: struct {
	dx:   i8, // -127 .. 127, right
	dy:   i8, // -127 .. 127, down
	_pad: [2]u8,
}

State :: struct {
	players: sim.Presence(Player_Data, PLAYERS, MEMBERS),
	balls:   sim.Table(Ball, MAX_BALLS),
}

World :: struct {
	_unused: u8,
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
