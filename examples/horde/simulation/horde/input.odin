package horde

import "unified:sim"

// One player's input for one tick: the stick, each axis -127..127 (dmath.axis_i8). Weapons fire on their own.
Input :: struct {
	dx: i8, // right
	dy: i8, // down
}

// A tick's inputs and commands, by slot.
Inputs :: sim.Inputs(Game)

// The level-up options (upgrade_offers deals three per level).
Upgrade :: enum u8 {
	Bolt_Count, // one more bolt per fan
	Bolt_Pierce, // each bolt pierces one more enemy
	Fire_Rate, // fans come BOLT_INTERVAL_LEVELUP_TICKS sooner
	Chains, // lightning reaches one more enemy
	Bomb_Radius, // blasts grow by BLAST_RADIUS_LEVELUP
	Move_Speed, // HERO_SPEED_LEVELUP faster
	Max_Hp, // HERO_HP_LEVELUP more, healed as much
}

// `pick` (GDScript: CommandPick): the oldest pending level-up goes to `upgrade` when it is one of that level's offers
// (upgrade_offers). A pick with nothing pending, or not offered, is ignored.
Command_Pick :: struct {
	upgrade: Upgrade,
}

// Dev command (sim.DEV_COMMAND_PREFIX): `count` enemies of a kind on the spawn ring.
Command_Dev_Spawn :: struct {
	count: u16,
	kind:  Enemy_Kind,
	_pad:  u8,
}

// Every command a player can send.
Command :: union {
	Command_Pick,
	Command_Dev_Spawn,
}
