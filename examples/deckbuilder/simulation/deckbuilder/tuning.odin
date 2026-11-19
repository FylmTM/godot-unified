// Every rule number in one place (examples/deckbuilder/README.md names them where the rules use them).
package deckbuilder

FLOORS :: 8 // the act: floors 0 ..< FLOORS, the boss on the last
LANES :: 3 // nodes per floor; a path moves to the same lane or a neighbouring one

HAND_SIZE :: 5 // cards drawn at the start of each of the heroes' turns
HAND_MAX :: 10 // a hand holds at most this many: a card drawn or handed past it goes to the discard pile
ENERGY :: 3 // each hero's energy at the start of the heroes' turn
DECK_MAX :: 32 // cards in a hero's deck: a reward past it is lost
PILE_MAX :: 48 // cards in a draw, discard or exhaust pile (every deck's cards handed to one hero, and more)
CARDS_MAX :: PLAYERS * DECK_MAX // the run's cards (every hero's deck)
ENEMIES_MAX :: 6 // enemies in a fight
ACTIONS_MAX :: ENEMIES_MAX // the enemies' turn: one action per living enemy
OFFERS :: 3 // card rewards offered after a fight (LUCKY_COIN_OFFERS with the Lucky Coin)
LUCKY_COIN_OFFERS :: 4

ENEMY_BEAT_S :: 0.5 // seconds between two enemy actions: the enemies' turn plays out on sim time
OVER_HOLD_S :: 5.0 // seconds the run's end shows before the camp
REVIVE_PCT :: 25 // a hero down at a fight's end gets up with this % of their max HP

VANGUARD_HP :: 70
ARCANIST_HP :: 55
REST_HEAL_PCT :: 30 // rest: heal this % of max HP (or upgrade a card)
SCALE_HEROES :: 1 // an enemy's HP is hp * (heroes in the run + SCALE_HEROES) / 2
QUICK_HP_DIV :: 4 // the `quick` tuning (Setup.tuning): enemy HP divided by this, so a scripted run crosses the act

WHETSTONE_BONUS :: 4 // the first attack of each fight
BOND_RING_BLOCK :: 2 // whenever a card targets an ally
MENDERS_POUCH_HEAL :: 5 // after each fight won
EMBER_CHARM_ENERGY :: 1 // on the first turn of each fight

@(rodata)
STARTER_VANGUARD := [?]Card_Id{.Strike, .Strike, .Strike, .Strike, .Defend, .Defend, .Defend, .Defend, .Cover, .Cover}
@(rodata)
STARTER_ARCANIST := [?]Card_Id {
	.Strike,
	.Strike,
	.Strike,
	.Strike,
	.Strike,
	.Defend,
	.Defend,
	.Defend,
	.Channel,
	.Channel,
}
STARTER_SIZE :: 10 // both starters: the scripted player names deck cards by it (script.odin)
