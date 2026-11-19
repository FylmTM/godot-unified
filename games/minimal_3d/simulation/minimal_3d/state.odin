package minimal_3d

import "unified:sim"

// The whole simulation state: one pointer-free block (checked by sim.create).
State :: struct {
	players: sim.Players(Player_Data, sim.No_Profile, Input, PLAYERS),
	balls:   sim.Table(Ball, MAX_BALLS),
}

// A player's data (the State's sim.Players): zeroed for someone new, kept while they are away.
Player_Data :: struct {
	position: [2]f32,
}

// A ball in the air: its ground position, height and vertical speed, and who threw it (who may have left).
Ball :: struct {
	pos:            [2]f32,
	height:         f32,
	vertical_speed: f32,
	thrower:        sim.Player,
}
