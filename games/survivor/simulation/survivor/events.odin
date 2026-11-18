package survivor

import "unified:sim"

// Events (for the view). Positions are in metres: on the ground (y = 0) for enemies and gems, the body's centre for
// players and barrels. A `player` field names the player the event is about (the Godot host routes it to their
// view). Joins and leaves are the library's events.

Event_Player_Died :: struct {
	position: sim.Position,
	player:   sim.Player,
}

Event_Player_Respawned :: struct {
	position: sim.Position,
	player:   sim.Player,
}

Event_Enemy_Died :: struct {
	enemy:      sim.Handle(Enemy),
	position:   sim.Position,
	enemy_kind: Enemy_Kind,
}

// Items are a fixed array, not a table: the subject is the item, sim.entity(index) (its view is keyed by the index).
Event_Barrel_Exploded :: struct {
	entity:   sim.Entity,
	position: sim.Position,
}

Event_Gem_Collected :: struct {
	gem:      sim.Handle(Gem),
	position: sim.Position,
	xp:       i32, // the gem's value
	player:   sim.Player, // who collected it
}

Event_Level_Up :: struct {
	position: sim.Position,
	level:    i32, // the new level
	player:   sim.Player,
}

// The match starts when `player` leaves the start circle.
Event_Match_Started :: struct {
	position: sim.Position,
	player:   sim.Player,
}

Event_Match_Over :: struct {
	duration_s: f32, // the match's length in seconds
}

Event :: union {
	Event_Player_Died,
	Event_Player_Respawned,
	Event_Enemy_Died,
	Event_Barrel_Exploded,
	Event_Gem_Collected,
	Event_Level_Up,
	Event_Match_Started,
	Event_Match_Over,
	sim.Event_Player_Joined,
	sim.Event_Player_Left,
}
