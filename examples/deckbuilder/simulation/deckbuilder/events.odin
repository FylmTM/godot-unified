package deckbuilder

import "unified:sim"

// A run began, `heroes` strong.
Event_Run_Started :: struct {
	heroes: u8,
}

// A player took a hero (theirs again, or a sleeping one: README, Heroes).
Event_Hero_Claimed :: struct {
	player: sim.Player,
	hero:   u8,
}

// The party entered a node (a save point).
Event_Node_Entered :: struct {
	floor: u8,
	lane:  u8,
	node:  Node_Kind,
}

Event_Card_Played :: struct {
	card:   sim.Handle(Card),
	enemy:  sim.Handle(Enemy), // an Enemy card's target
	hero:   u8,
	played: Card_Id, // the card played
	ally:   u8, // an Ally card's target + 1
}

// A play that could not be played when it landed (the card stays, the energy is kept).
Event_Play_Refused :: struct {
	card:   sim.Handle(Card),
	hero:   u8,
	reason: Refusal,
}

// A card came into a hero's hand: drawn, or handed over.
Event_Card_Drawn :: struct {
	card: sim.Handle(Card),
	hero: u8,
}

Event_Enemy_Hit :: struct {
	enemy:   sim.Handle(Enemy),
	amount:  i16, // to its HP
	blocked: i16, // taken by its block
}

Event_Enemy_Died :: struct {
	enemy: sim.Handle(Enemy),
}

// An enemy acted on its intent.
Event_Enemy_Acted :: struct {
	enemy:  sim.Handle(Enemy),
	intent: Intent,
}

Event_Hero_Hit :: struct {
	hero:    u8,
	amount:  i16,
	blocked: i16,
}

Event_Hero_Blocked :: struct {
	hero:   u8,
	amount: i16,
}

Event_Hero_Healed :: struct {
	hero:   u8,
	amount: i16,
}

Event_Hero_Down :: struct {
	hero: u8,
}

Event_Fight_Won :: struct {
	floor: u8,
}

Event_Voted :: struct {
	hero: u8,
	lane: u8,
}

// A hero took a reward card (None: skipped).
Event_Reward_Picked :: struct {
	hero: u8,
	card: Card_Id,
}

Event_Relic_Gained :: struct {
	hero:  u8,
	relic: Relic,
}

Event_Rested :: struct {
	hero:   u8,
	choice: Rest_Choice,
}

Event_Run_Over :: struct {
	won:   bool,
	floor: u8,
}

// Every event the sim emits.
Event :: union {
	sim.Event_Player_Joined,
	sim.Event_Player_Left,
	Event_Run_Started,
	Event_Hero_Claimed,
	Event_Node_Entered,
	Event_Card_Played,
	Event_Play_Refused,
	Event_Card_Drawn,
	Event_Enemy_Hit,
	Event_Enemy_Died,
	Event_Enemy_Acted,
	Event_Hero_Hit,
	Event_Hero_Blocked,
	Event_Hero_Healed,
	Event_Hero_Down,
	Event_Fight_Won,
	Event_Voted,
	Event_Reward_Picked,
	Event_Relic_Gained,
	Event_Rested,
	Event_Run_Over,
}
