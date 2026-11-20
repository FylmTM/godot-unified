package deckbuilder

import "unified:sim"

// One player's input: their aim, the card they hold up and at whom, which their allies see live. The rules never read
// it: everything a player does is a command (a play is Command_Play_Card). 0 in a field: nothing.
Input :: struct {
	card:  u8, // the held card's place in their hand + 1
	enemy: u8, // the enemy aimed at: its table index + 1
	hero:  u8, // the hero aimed at: its index + 1
	_pad:  u8,
}

// A tick's inputs and commands, by slot.
Inputs :: sim.Inputs(Game)

// `start_run` (GDScript: CommandStartRun): at the camp, a new run for the players present.
Command_Start_Run :: struct {}

// `play_card` (GDScript: CommandPlayCard): the sender's hero plays `card` from their hand, at `enemy` (an Enemy card),
// at hero `ally` - 1 (an Ally card; 0: none), handing `extra` (Hand Off). Resolved on the tick it lands, in the relay's
// order: refused when it can't be played then (Refusal).
Command_Play_Card :: struct {
	card:  sim.Handle(Card),
	enemy: sim.Handle(Enemy),
	extra: sim.Handle(Card),
	ally:  u8,
	_pad:  [3]u8,
}

// `end_turn` (GDScript: CommandEndTurn): the sender's hero is done (`ready`) or plays on. A value, not a toggle.
Command_End_Turn :: struct {
	ready: bool,
}

// `vote` (GDScript: CommandVote): the sender's hero votes for the next floor's node in `lane`.
Command_Vote :: struct {
	lane: u8,
}

SKIP :: 255 // Command_Pick_Reward.offer: no card

// `pick_reward` (GDScript: CommandPickReward): the sender's hero takes offer `offer` into their deck, or SKIP.
Command_Pick_Reward :: struct {
	offer: u8,
}

Rest_Choice :: enum u8 {
	Heal, // REST_HEAL_PCT of max HP
	Upgrade, // `card`, one of the hero's deck
}

// `rest` (GDScript: CommandRest): at a rest node, the sender's hero heals or upgrades a card.
Command_Rest :: struct {
	choice: Rest_Choice,
	_pad:   [3]u8,
	card:   sim.Handle(Card),
}

// A dev command (the dev UI's Commands panel; refused by public builds): every enemy of the fight falls.
Command_Dev_Win_Fight :: struct {}

// Every command a player can send.
Command :: union {
	Command_Start_Run,
	Command_Play_Card,
	Command_End_Turn,
	Command_Vote,
	Command_Pick_Reward,
	Command_Rest,
	Command_Dev_Win_Fight,
}
