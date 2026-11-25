package survivor

import "unified:sim"

Button :: enum u8 {
	Dash, // the dash starts on the press
}

Buttons :: bit_set[Button;u8]

// One player's input for one tick (3 bytes on the wire and in the log): the stick and the dash. Presence (joined or
// not) comes from the relay (sim.Inputs.present and its join records), not from the input.
Input :: struct {
	move_x:  i8,
	move_z:  i8,
	buttons: Buttons,
}

Inputs :: sim.Inputs(Game)

// The level-up options, in the order the HUD shows them.
Upgrade :: enum u8 {
	Fire_Rate,
	Damage,
	Move_Speed,
}

// The level-up pick (GDScript: a `CommandPick` with `upgrade` = an EnumUpgrade value): the oldest pending level-up goes
// to `upgrade` when it is one of that level's offers (upgrade_offers). A HUD names the level whose offers it showed, so
// a second press that lands after the first was taken is refused instead of spending the next level-up on a card the
// player never saw. A pick with nothing pending, for another level, or not offered, is ignored.
Command_Pick :: struct {
	upgrade: Upgrade,
	_pad:    u8,
	level:   u16, // the pending level-up it answers (oldest_pending_level); 0: the oldest, whichever (the script's)
}

// Dev commands (sim.DEV_COMMAND_PREFIX): the dev UI's Commands panel offers each as a form; a build without the dev UI
// never applies them. XP for a player (the form lists the session's players).
Command_Dev_Give_Xp :: struct {
	player: sim.Player,
	xp:     i32,
}

// The next wave, at once.
Command_Dev_Skip_Wave :: struct {}

// `count` enemies of a kind on the spawn ring.
Command_Dev_Spawn :: struct {
	count: u16,
	kind:  Enemy_Kind,
	_pad:  u8,
}

Command :: union {
	Command_Pick,
	Command_Dev_Give_Xp,
	Command_Dev_Skip_Wave,
	Command_Dev_Spawn,
}
