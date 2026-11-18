package friendslop

import "unified:sim"

// Events (for the view; GDScript matches them by the type name, lowercased). `player` is the player the event is about
// (the Godot host routes it to their view), `entity` the level marker (sim.entity of its index) of an item, plate,
// bell, switch or lock, `position` where it happened (metres). Joins and leaves are the library's.

// A player's body appeared (they joined or came back).
Event_Spawned :: struct {
	position: sim.Position,
	player:   sim.Player,
}

Event_Jumped :: struct {
	position: sim.Position,
	player:   sim.Player,
}

// A jump pad launched a player (entity 0) or an item (player {}).
Event_Launched :: struct {
	entity:   sim.Entity,
	position: sim.Position, // the pad's
	player:   sim.Player,
}

// `player` grabbed an item (entity) or another player (held_player).
Event_Grabbed :: struct {
	entity:      sim.Entity, // the item (0: a player)
	position:    sim.Position, // the holder's
	player:      sim.Player, // the holder
	held_player: sim.Player, // the held player ({}: an item)
}

// `player` let go of what it held (also before a throw).
Event_Dropped :: struct {
	entity:      sim.Entity, // the item (0: a player)
	position:    sim.Position, // the holder's
	player:      sim.Player, // the holder
	held_player: sim.Player, // the dropped player ({}: an item)
}

Event_Thrown :: struct {
	entity:      sim.Entity, // the item (0: a player)
	position:    sim.Position, // the thrower's
	speed:       f32, // m/s along the aim
	player:      sim.Player, // the thrower
	held_player: sim.Player, // the thrown player ({}: an item)
}

// A player was hit by an item or a bumper.
Event_Hit :: struct {
	position: sim.Position,
	speed:    f32, // the knockback's horizontal speed
	player:   sim.Player,
}

Event_Broke_Free :: struct {
	position: sim.Position,
	player:   sim.Player,
}

Event_Fell :: struct {
	position: sim.Position, // where it fell below the kill height
	player:   sim.Player,
}

Event_Respawned :: struct {
	position: sim.Position,
	player:   sim.Player,
}

// The team reached a checkpoint (the player who reached it).
Event_Checkpoint :: struct {
	position: sim.Position, // the checkpoint's
	index:    i32, // the checkpoint's index (State.checkpoint)
	player:   sim.Player,
}

// A player walked through the start gate.
Event_Run_Started :: struct {
	position: sim.Position, // the gate's
	player:   sim.Player,
}

// The trophy (entity) reached the pedestal.
Event_Run_Finished :: struct {
	entity:   sim.Entity,
	position: sim.Position, // the finish volume's
	seconds:  f32, // the run's time
}

Event_Plate_On :: struct {
	entity:   sim.Entity,
	position: sim.Position,
	mass:     f32, // kg on the plate
}

Event_Plate_Off :: struct {
	entity:   sim.Entity,
	position: sim.Position,
	mass:     f32,
}

Event_Bell_Rung :: struct {
	entity:   sim.Entity,
	position: sim.Position, // where it was hit
	speed:    f32, // the hit's approach speed
}

// A switch (touched by `player`) or a lock (opened by a key: player {}) fired.
Event_Switch_On :: struct {
	entity:   sim.Entity,
	position: sim.Position,
	player:   sim.Player,
}

Event :: union {
	sim.Event_Player_Joined,
	sim.Event_Player_Left,
	Event_Spawned,
	Event_Jumped,
	Event_Launched,
	Event_Grabbed,
	Event_Dropped,
	Event_Thrown,
	Event_Hit,
	Event_Broke_Free,
	Event_Fell,
	Event_Respawned,
	Event_Checkpoint,
	Event_Run_Started,
	Event_Run_Finished,
	Event_Plate_On,
	Event_Plate_Off,
	Event_Bell_Rung,
	Event_Switch_On,
}
