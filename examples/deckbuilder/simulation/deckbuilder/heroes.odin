// The heroes: who plays which (claiming), and what happens to one (draws, block, damage, healing).
package deckbuilder

import "unified:dmath"
import "unified:sim"

// Every player who arrives takes a hero: the one they played before when it is still theirs, else the lowest hero of
// the run whose player is away (a sleeping one, or one whose player the session forgot). With none free they watch.
claim_heroes :: proc(t: ^Tick) {
	for player in t.player_changes.arrived {
		data := sim.player_data(t, player)
		data.watching = false
		if hero_of(t.state, player) >= 0 do continue
		data.watching = t.state.phase != .Camp
		for &hero, index in t.state.heroes {
			if !hero.in_run || sim.player_present(t, hero.controller) do continue
			hero.controller = player
			data.watching = false
			sim.emit(t, Event_Hero_Claimed{player = player, hero = u8(index)})
			break
		}
	}
}

// The hero `player` plays (-1: none).
hero_of :: proc(state: ^State, player: sim.Player) -> int {
	if player == {} do return -1
	for &hero, index in state.heroes do if hero.in_run && hero.controller == player do return index
	return -1
}

// Whether a hero is in the run and their player is here: an awake hero plays, readies and votes; a sleeping one is
// skipped, never targeted, and counts as ready.
awake :: proc(t: ^Tick, index: int) -> bool {
	hero := &t.state.heroes[index]
	return hero.in_run && sim.player_present(t, hero.controller)
}

// Draws `count` cards into a hero's hand, the draw pile's top first; an empty pile takes the discard pile, shuffled
// from the hero's own stream. A card past HAND_MAX goes to the discard pile.
draw :: proc(t: ^Tick, index: int, count: int) {
	hero := &t.state.heroes[index]
	for _ in 0 ..< count {
		if hero.draw_pile.count == 0 {
			if hero.discard.count == 0 do return
			for card in sim.slice(&hero.discard) do sim.append(&hero.draw_pile, card)
			sim.clear(&hero.discard)
			sim.shuffle(&hero.draws, sim.slice(&hero.draw_pile))
		}
		card, _ := sim.pop(&hero.draw_pile)
		if hero.hand.count >= HAND_MAX {
			sim.append(&hero.discard, card)
			continue
		}
		sim.append(&hero.hand, card)
		sim.emit(t, Event_Card_Drawn{card = card, hero = u8(index)})
	}
}

gain_block :: proc(t: ^Tick, index: int, amount: i16) {
	t.state.heroes[index].block += amount
	sim.emit(t, Event_Hero_Blocked{hero = u8(index), amount = amount})
}

heal :: proc(t: ^Tick, index: int, amount: i16) {
	hero := &t.state.heroes[index]
	healed := dmath.min(amount, hero.max_hp - hero.hp)
	if healed <= 0 do return
	hero.hp += healed
	sim.emit(t, Event_Hero_Healed{hero = u8(index), amount = healed})
}

// An enemy's attack on a hero: three halves while the hero is Vulnerable, taken by their block first. At 0 HP they
// are down for the rest of the fight.
hit_hero :: proc(t: ^Tick, index: int, damage: i16) {
	hero := &t.state.heroes[index]
	if hero.down do return
	damage := damage
	if hero.vulnerable > 0 do damage = damage * 3 / 2
	blocked := dmath.min(damage, hero.block)
	hero.block -= blocked
	taken := dmath.min(damage - blocked, hero.hp)
	hero.hp -= taken
	sim.emit(t, Event_Hero_Hit{hero = u8(index), amount = taken, blocked = blocked})
	if hero.hp <= 0 {
		hero.down = true
		sim.emit(t, Event_Hero_Down{hero = u8(index)})
	}
}
