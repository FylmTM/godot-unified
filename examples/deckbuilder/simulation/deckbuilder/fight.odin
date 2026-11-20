// A fight: its start, the heroes' turn (plays, then everyone ready), the enemies' turn (one action a beat, on sim
// time), the round's end, and the outcome.
package deckbuilder

import "unified:sim"

Roll :: enum u8 {
	Run, // a new run's seed, from the session's seed and the runs started
	Map,
	Fight, // a fight's enemies and their targets (by floor)
	Draw, // a hero's shuffles in a fight (by hero and floor)
	Reward, // a hero's card offers (by hero and floor)
	Relic, // a hero's relics (by hero and floor)
	Vote, // a tied vote (by floor)
}

// Starts the fight of the node entered: the enemies, every hero's whole deck shuffled into their draw pile from their
// own stream for this floor, a hand, energy, and a clean slate (block, statuses).
start_fight :: proc(t: ^Tick) {
	t.state.fight = sim.rng_keyed(t.state.run_seed, Roll.Fight, 0, int(t.state.floor))
	spawn_fight(t)
	for &hero, index in t.state.heroes {
		if !hero.in_run do continue
		sim.clear(&hero.draw_pile)
		sim.clear(&hero.hand)
		sim.clear(&hero.discard)
		sim.clear(&hero.exhaust)
		cards := sim.iterate(&t.state.cards)
		for card, handle in sim.next(&cards) {
			if int(card.home) != index do continue
			card.holder = u8(index)
			sim.append(&hero.draw_pile, handle)
		}
		hero.draws = sim.rng_keyed(t.state.run_seed, Roll.Draw, u64(index), int(t.state.floor))
		sim.shuffle(&hero.draws, sim.slice(&hero.draw_pile))
		hero.block, hero.strength, hero.weak, hero.vulnerable = 0, 0, 0, 0
		hero.taunt, hero.whetstone_used, hero.down = false, false, false
	}
	t.state.round = 0
	start_round(t)
	if t.state.round == 1 {
		for &hero in t.state.heroes do if .Ember_Charm in hero.relics do hero.energy += EMBER_CHARM_ENERGY
	}
}

// The heroes' turn begins: hands drawn, energy back, block gone; the enemies show their next intents.
start_round :: proc(t: ^Tick) {
	t.state.round += 1
	t.state.phase = .Heroes
	for &hero, index in t.state.heroes {
		if !hero.in_run do continue
		hero.ready = false
		hero.block = 0
		hero.taunt = false
		hero.energy = ENERGY
		if !hero.down do draw(t, index, HAND_SIZE)
	}
}

// Ends a hero's turn (or takes it back while the heroes' turn lasts).
end_turn :: proc(t: ^Tick, index: int, ready: bool) {
	if t.state.phase != .Heroes do return
	t.state.heroes[index].ready = ready
}

// The heroes' turn ends once every awake hero still standing is ready (a sleeping one counts as ready; nobody here:
// it waits): the enemies' block goes, and each living enemy queues its action, in table order.
heroes_turn :: proc(t: ^Tick) {
	present := 0
	for &hero, index in t.state.heroes {
		if !awake(t, index) || hero.down do continue
		present += 1
		if !hero.ready do return
	}
	if present == 0 do return
	t.state.phase = .Enemies
	sim.clear(&t.state.actions)
	enemies := sim.iterate(&t.state.enemies)
	for enemy, handle in sim.next(&enemies) {
		enemy.block = 0
		sim.append(&t.state.actions, Enemy_Action{enemy = handle})
	}
	sim.timer_start(t, &t.state.beat, ENEMY_BEAT_S)
}

// The enemies' turn: one action every ENEMY_BEAT_S, then the round's end. Paced on sim time, so every client sees
// the same beats and a rollback through it costs nothing.
enemies_turn :: proc(t: ^Tick) {
	if !sim.timer_done(t, t.state.beat) do return
	if action, ok := sim.pop_front(&t.state.actions); ok {
		enemy_act(t, action.enemy)
		sim.timer_start(t, &t.state.beat, ENEMY_BEAT_S)
		if check_fight_lost(t) do return
		return
	}
	end_round(t)
}

// The round ends: statuses count down, hands go to the discard pile, the enemies choose their next intents, and the
// heroes' turn begins.
end_round :: proc(t: ^Tick) {
	for &hero in t.state.heroes {
		if !hero.in_run do continue
		if hero.weak > 0 do hero.weak -= 1
		if hero.vulnerable > 0 do hero.vulnerable -= 1
		for card in sim.slice(&hero.hand) do sim.append(&hero.discard, card)
		sim.clear(&hero.hand)
	}
	enemies := sim.iterate(&t.state.enemies)
	for enemy in sim.next(&enemies) {
		if enemy.weak > 0 do enemy.weak -= 1
		if enemy.vulnerable > 0 do enemy.vulnerable -= 1
		choose_intent(t, enemy)
	}
	start_round(t)
}

// Every enemy fell: the fight is won. Heroes down get up (REVIVE_PCT), every card goes home, and the reward comes (the
// boss: the run is won).
check_fight_won :: proc(t: ^Tick) {
	if t.state.enemies.count > 0 || (t.state.phase != .Heroes && t.state.phase != .Enemies) do return
	sim.emit(t, Event_Fight_Won{floor = t.state.floor})
	sim.clear(&t.state.actions)
	for &hero, index in t.state.heroes {
		if !hero.in_run do continue
		if hero.down {
			hero.down = false
			hero.hp = i16(i32(hero.max_hp) * REVIVE_PCT / 100)
		}
		if .Menders_Pouch in hero.relics do heal(t, index, MENDERS_POUCH_HEAL)
		hero.block, hero.ready = 0, false
		sim.clear(&hero.draw_pile)
		sim.clear(&hero.hand)
		sim.clear(&hero.discard)
		sim.clear(&hero.exhaust)
	}
	cards := sim.iterate(&t.state.cards)
	for card in sim.next(&cards) do card.holder = card.home
	if t.state.node == .Boss {
		end_run(t, won = true)
		return
	}
	start_reward(t)
}

// Every awake hero is down: the run is lost.
check_fight_lost :: proc(t: ^Tick) -> bool {
	for &hero, index in t.state.heroes do if awake(t, index) && !hero.down do return false
	for _, index in t.state.heroes do if awake(t, index) {
		end_run(t, won = false)
		return true
	}
	return false
}
