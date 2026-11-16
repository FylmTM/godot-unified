package minimal_3d

import "unified:sim"

Event :: union {
	sim.Event_Player_Joined,
	sim.Event_Player_Left,
	Event_Ball_Dropped,
}

Event_Ball_Dropped :: struct {
	player: sim.Player,
	speed:  u8,
}
