package drift

import "unified:sim"

// Events (for the view). Positions are on the plane (sim.position: z = 0), in metres. A `player` field names the
// player the event is about (the Godot host routes it to their ship's view); a rock event's subject is the rock's
// handle. Joins and leaves are the library's.

// A player's ship appeared at their slot's spawn (they joined or came back).
Event_Spawned :: struct {
	position: sim.Position,
	player:   sim.Player,
}

// A bullet left the ship's nose (`position`: the muzzle).
Event_Fired :: struct {
	position: sim.Position,
	player:   sim.Player,
}

Event_Boosted :: struct {
	position: sim.Position,
	player:   sim.Player,
}

// A ship warped from gate `from_gate` to `to_gate` (`position`: where it came out).
Event_Warped :: struct {
	position:  sim.Position,
	player:    sim.Player,
	from_gate: u8,
	to_gate:   u8,
}

// A bullet of `player` hit `rock` at `position` (the hit point).
Event_Rock_Hit :: struct {
	rock:     sim.Handle(Rock),
	position: sim.Position,
	player:   sim.Player,
	size:     Rock_Size,
}

// `rock` (of `size`, gone now) broke into two of the next size.
Event_Rock_Split :: struct {
	rock:     sim.Handle(Rock),
	position: sim.Position,
	size:     Rock_Size,
}

// `rock` (a small one, gone now) was shot to pieces.
Event_Rock_Destroyed :: struct {
	rock:     sim.Handle(Rock),
	position: sim.Position,
	size:     Rock_Size,
}

// A rock of `size` hit the station at `position` and is gone: `damage` is what it costs the station's HP during a
// match.
Event_Station_Hit :: struct {
	position: sim.Position,
	damage:   i32,
	size:     Rock_Size,
}

Event_Gem_Picked :: struct {
	position: sim.Position,
	player:   sim.Player,
}

// Wave `wave` (1..) started.
Event_Wave :: struct {
	wave: u16,
}

// `player` sent the `start` that began the match.
Event_Match_Started :: struct {
	player: sim.Player,
}

Event_Match_Over :: struct {
	seconds_survived: f32,
}

Event :: union {
	sim.Event_Player_Joined,
	sim.Event_Player_Left,
	Event_Spawned,
	Event_Fired,
	Event_Boosted,
	Event_Warped,
	Event_Rock_Hit,
	Event_Rock_Split,
	Event_Rock_Destroyed,
	Event_Station_Hit,
	Event_Gem_Picked,
	Event_Wave,
	Event_Match_Started,
	Event_Match_Over,
}
