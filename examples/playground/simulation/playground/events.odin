package playground

import "unified:sim"

// Every event the sim emits: the library's joins and leaves, and the game's own. Each names who did it (`player`) when
// a player did, and where (`position`, metres).
Event :: union {
	sim.Event_Player_Joined,
	sim.Event_Player_Left,
	Event_Scene_Entered,
	Event_Shot,
	Event_Exploded,
	Event_Spawned,
	Event_Grabbed,
	Event_Released,
	Event_Joint_Broke,
	Event_Sensor_Entered,
}

// Everyone is in `scene` now (`player` picked it; {}: the session's start).
Event_Scene_Entered :: struct {
	player: sim.Player,
	scene:  Scene,
	_pad:   [3]u8,
}

// A bullet left `player`'s camera ({}: the turret's) at `position`.
Event_Shot :: struct {
	player:   sim.Player,
	position: sim.Position,
}

// An explosion at `position`, set off by `player`.
Event_Exploded :: struct {
	player:   sim.Player,
	position: sim.Position,
}

// `player` spawned a body at `position`.
Event_Spawned :: struct {
	player:   sim.Player,
	position: sim.Position,
}

// `player` grabbed a body at `position`.
Event_Grabbed :: struct {
	player:   sim.Player,
	position: sim.Position,
}

// `player` let go of what they held.
Event_Released :: struct {
	player: sim.Player,
}

// A joint of the Breakable scene broke at `position`.
Event_Joint_Broke :: struct {
	position: sim.Position,
}

// A body entered sensor `sensor` of the Sensors scene at `position`.
Event_Sensor_Entered :: struct {
	position: sim.Position,
	sensor:   u8,
	_pad:     [3]u8,
}
