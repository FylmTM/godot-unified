package holdout

import "unified:sim"

// Every event the sim emits: the library's joins and leaves, and the game's own.
Event :: union {
	sim.Event_Player_Joined,
	sim.Event_Player_Left,
	Event_Shot,
	Event_Enemy_Hit,
	Event_Enemy_Died,
	Event_Player_Hurt,
	Event_Player_Downed,
	Event_Player_Revived,
	Event_Player_Respawned,
	Event_Grenade_Thrown,
	Event_Explosion,
	Event_Bolt_Fired,
	Event_Core_Hit,
	Event_Countdown,
	Event_Wave_Started,
	Event_Wave_Cleared,
	Event_Victory,
	Event_Core_Destroyed,
	Event_Lobby,
}

// A rifle shot from `from` (the shooter's eye, as the shot was resolved) to `to` (what it hit, else its range's end).
Event_Shot :: struct {
	from:   sim.Position,
	to:     sim.Position,
	player: sim.Player,
	hit:    bool, // it struck an enemy
}

// An enemy took a rifle hit or a blast.
Event_Enemy_Hit :: struct {
	at:       sim.Position,
	enemy:    sim.Handle(Enemy),
	damage:   i16,
	headshot: bool,
	_pad:     u8,
}

// An enemy died where it stood (its body is gone; the death is the view's).
Event_Enemy_Died :: struct {
	at:     sim.Position,
	enemy:  Enemy_Kind, // what it was
	_pad:   [3]u8,
	killer: sim.Player, // {}: a blast nobody threw, or nothing
}

Event_Player_Hurt :: struct {
	player: sim.Player,
	damage: i16,
	_pad:   [2]u8,
}

// A player went down at 0 HP: a teammate can revive them, else they get up at the core after RESPAWN_S.
Event_Player_Downed :: struct {
	at:     sim.Position,
	player: sim.Player,
}

Event_Player_Revived :: struct {
	player:  sim.Player,
	reviver: sim.Player,
}

Event_Player_Respawned :: struct {
	at:     sim.Position,
	player: sim.Player,
}

Event_Grenade_Thrown :: struct {
	at:      sim.Position,
	grenade: sim.Handle(Grenade),
	player:  sim.Player,
}

Event_Explosion :: struct {
	at: sim.Position,
}

Event_Bolt_Fired :: struct {
	at: sim.Position,
}

Event_Core_Hit :: struct {
	damage: i32,
	hp:     i32, // what the core has left
}

// A player pressed Ready in the lobby: the first wave starts in START_DELAY_S.
Event_Countdown :: struct {
	player: sim.Player,
}

Event_Wave_Started :: struct {
	wave: u8,
	_pad: [3]u8,
}

Event_Wave_Cleared :: struct {
	wave: u8,
	_pad: [3]u8,
}

// The last wave is cleared: the yard held.
Event_Victory :: struct {
	kills: u32,
}

// The core fell.
Event_Core_Destroyed :: struct {
	wave: u8,
	_pad: [3]u8,
}

// The run is over and the yard is back to the lobby: how far the run got.
Event_Lobby :: struct {
	wave: u8,
	won:  bool,
	_pad: [2]u8,
}
