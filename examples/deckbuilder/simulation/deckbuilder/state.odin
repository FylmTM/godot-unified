package deckbuilder

import "unified:sim"

// What the party is doing: a run goes Map (vote) -> a node (Heroes and Enemies alternating in a fight; Reward after
// one; Rest) -> Map ... -> the boss -> Over -> Camp.
Phase :: enum u8 {
	Camp, // no run: anyone starts one (Cmd_Start_Run)
	Map, // the party votes on the next node (Cmd_Vote)
	Heroes, // a fight, the heroes' turn: everyone plays at once, then ends their turn (Cmd_End_Turn)
	Enemies, // a fight, the enemies' turn: one action per ENEMY_BEAT_S
	Reward, // after a fight: each hero picks a card or skips (Cmd_Pick_Reward)
	Rest, // a rest node: each hero heals or upgrades a card (Cmd_Rest)
	Over, // the run ended (State.won): OVER_HOLD_S, then the camp
}

// What a map node holds.
Node_Kind :: enum u8 {
	None, // no node there
	Fight,
	Elite, // a harder fight; its reward adds a relic
	Rest,
	Treasure, // a relic for every hero
	Boss,
}

Hero_Class :: enum u8 {
	Vanguard,
	Arcanist,
}

// A hero's lasting bonuses (README, Relics), each hero their own.
Relic :: enum u8 {
	Whetstone,
	Ember_Charm,
	Bond_Ring,
	Menders_Pouch,
	Lucky_Coin,
}

Relics :: bit_set[Relic;u8]

// A card of the run: in its home hero's deck, held now by `holder` (Hand Off moves it to an ally until the fight ends).
Card :: struct {
	id:       Card_Id,
	upgraded: bool,
	home:     u8, // the hero whose deck it is
	holder:   u8, // the hero whose piles hold it this fight
}

// A hero of the run, kept apart from the players (a session forgets its longest-absent member): `controller` plays it,
// and while they are away it sleeps (README, Heroes).
Hero :: struct {
	controller:     sim.Player,
	class:          Hero_Class,
	in_run:         bool,
	ready:          bool, // ended their turn
	down:           bool, // at 0 HP in this fight
	hp:             i16,
	max_hp:         i16,
	block:          i16,
	energy:         u8,
	strength:       i8, // for the fight
	weak:           u8, // turns left
	vulnerable:     u8, // turns left
	relics:         Relics,
	taunt:          bool, // enemies target this hero this round
	whetstone_used: bool, // the fight's first attack had its bonus
	picked:         bool, // Reward: picked or skipped; Rest: rested
	vote:           u8, // Map: the lane voted for + 1 (0: none yet)
	offer_count:    u8,
	offers:         [LUCKY_COIN_OFFERS]Card_Id, // Reward: the cards offered
	_pad:           [4]u8,
	draws:          sim.Rng, // the fight's shuffles (rng_keyed by the hero and the floor)
	draw_pile:      sim.List(sim.Handle(Card), PILE_MAX), // the top is the last item
	hand:           sim.List(sim.Handle(Card), HAND_MAX),
	discard:        sim.List(sim.Handle(Card), PILE_MAX),
	exhaust:        sim.List(sim.Handle(Card), PILE_MAX),
}

Enemy_Kind :: enum u8 {
	Gnasher,
	Spitter,
	Bulwark,
	Hollow_King, // the boss
}

// What an enemy does next, shown above it (its intent) before it does it.
Intent_Kind :: enum u8 {
	None,
	Attack, // `amount` to the target hero
	Attack_All, // `amount` to every hero
	Defend, // `amount` block to itself
	Fortify, // `amount` block to itself and FORTIFY_OTHER to another enemy
	Weaken, // the target hero: `amount` turns of Weak
	Mark, // the target hero: `amount` turns of Vulnerable, and marked for the Crush
	Crush, // `amount` to the marked hero
}

ALL_HEROES :: 255 // an intent's target when it hits everyone

Intent :: struct {
	kind:   Intent_Kind,
	target: u8, // a hero's index, or ALL_HEROES
	amount: i16,
}

Enemy :: struct {
	kind:       Enemy_Kind,
	step:       u8, // where it is in its intent cycle
	weak:       u8,
	vulnerable: u8,
	hp:         i16,
	max_hp:     i16,
	block:      i16,
	marked:     u8, // the Hollow King: the hero its Crush hits + 1
	_pad:       u8,
	intent:     Intent,
}

// One step of the enemies' turn: an enemy acts on its intent.
Enemy_Action :: struct {
	enemy: sim.Handle(Enemy),
}

// The whole simulation state: one pointer-free block. Everything a run is lives here, the save point included, so a
// rollback, a snapshot and a late join carry it.
State :: struct {
	run_seed:      u64, // names every stream of the run (0: no run)
	fight:         sim.Rng, // the fight's own rolls: enemies, their targets
	runs:          u32, // runs started this session: names the next run's seed
	round:         u16, // the fight's round
	phase:         Phase,
	floor:         u8, // the node's floor (NO_FLOOR: the run's first vote)
	lane:          u8,
	node:          Node_Kind,
	won:           bool, // Over: the boss fell
	boss_summoned: bool, // the Hollow King called its Gnashers
	_pad:          [4]u8,
	map_nodes:     [FLOORS][LANES]Node_Kind,
	beat:          sim.Timer, // the enemies' turn: the next action's time
	over_hold:     sim.Timer,
	heroes:        [PLAYERS]Hero,
	enemies:       sim.Table(Enemy, ENEMIES_MAX),
	actions:       sim.Queue(Enemy_Action, ACTIONS_MAX),
	cards:         sim.Table(Card, CARDS_MAX),
	save:          Setup, // the save point: the run as it entered its node (Game.save gives it)
	players:       sim.Players(Player_Data, Profile, Input, PLAYERS),
}

NO_FLOOR :: 255

// A player's data: nothing (a player plays a hero, kept in State.heroes).
Player_Data :: struct {
	watching: bool, // no hero was free when they came: they watch
}

// What a player chose before joining: the class of the hero a new run gives them.
Profile :: struct {
	class: Hero_Class,
	_pad:  [3]u8,
}

// Which rules a session plays: `quick` divides enemy HP (QUICK_HP_DIV) so a scripted run crosses the act.
Tuning :: enum u8 {
	Play,
	Quick,
}

SAVE_VERSION :: 1 // Setup.version of a saved run: a build that changes what a save holds bumps it and reads the older

// A card of a saved deck.
Saved_Card :: struct {
	id:       Card_Id,
	upgraded: bool,
}

// A hero of a saved run.
Saved_Hero :: struct {
	class:  Hero_Class,
	in_run: bool,
	relics: Relics,
	_pad:   u8,
	hp:     i16,
	max_hp: i16,
	deck:   sim.List(Saved_Card, DECK_MAX),
	_pad2:  [3]u8,
}

// The session's Setup: the tuning, and the run to continue (version 0: none, a new session starts at the camp). A
// save is this struct (Game.save), as JSON in the game's save file: it continues the run at the node it entered.
Setup :: struct {
	tuning:   Tuning,
	version:  u8, // SAVE_VERSION when it holds a run (0: none)
	floor:    u8, // the node the run entered
	lane:     u8,
	_pad:     [4]u8,
	run_seed: u64,
	heroes:   [PLAYERS]Saved_Hero,
}
