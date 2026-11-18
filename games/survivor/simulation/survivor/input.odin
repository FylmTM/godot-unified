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

// The level-up pick (GDScript: a `CommandPick` with `upgrade` = an EnumUpgrade value): one pending level-up goes to
// `upgrade`. A pick with nothing pending is ignored.
Cmd_Pick :: struct {
	upgrade: Upgrade,
}

Cmd :: union {
	Cmd_Pick,
}
