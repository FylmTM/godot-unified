// What the Godot side shows of a tick: a card view per card in a hand, an enemy view per enemy (both Controls: data
// only), the run's and the heroes' session data, and the card and relic texts as constants. Hands are open: every
// player sees every hand, and each ally's aim (their Input) live.
package deckbuilder_extension

import "unified:godot"
import "unified:sim"

import g "../deckbuilder"

Frame :: godot.Frame(g.Game, View, MultiView)

View :: enum u8 {
	Card, // a card in a hand (game/views/card.tscn, in its holder's hand box)
	Enemy, // game/views/enemy.tscn, in the enemies' row
}

MultiView :: enum u8 {}

// A card in a hand.
Card_View :: struct {
	id:       g.Card_Id,
	upgraded: bool,
	hero:     u8, // whose hand holds it
	slot:     u8, // its place in that hand
	cost:     u8,
	target:   g.Target_Kind,
	playable: bool, // the local player could play it now (their hand, the heroes' turn, the energy)
	held:     bool, // its holder holds it up (their aim)
}

// An enemy in the fight.
Enemy_View :: struct {
	kind:          g.Enemy_Kind,
	weak:          u8,
	vulnerable:    u8,
	intent:        g.Intent_Kind,
	intent_target: u8, // a hero's index, or g.ALL_HEROES
	aimed:         u8, // a bit per hero aiming at it
	index:         u8, // its table index: what the Input names it by
	_pad:          u8,
	hp:            i16,
	max_hp:        i16,
	block:         i16,
	intent_amount: i16,
}

Data :: union {
	Data_Run,
	Data_Heroes,
}

// A card of the local hero's deck (a rest's upgrade picks one).
Deck_Card :: struct {
	card:     sim.Handle(g.Card), // its key
	id:       g.Card_Id,
	upgraded: bool,
	_pad:     [2]u8,
}

// The run (Unified.data.run): where the party is, the map and the votes, and the local hero's reward and deck.
Data_Run :: struct {
	phase:       g.Phase,
	floor:       u8, // g.NO_FLOOR: before the first node
	lane:        u8,
	node:        g.Node_Kind,
	won:         bool,
	local_hero:  i8, // the local player's hero (-1: none, watching or at the camp)
	round:       u16,
	map_nodes:   [g.FLOORS * g.LANES]g.Node_Kind, // floor * LANES + lane
	can_go:      [g.LANES]bool, // the next floor's lanes the party may vote for
	offer_count: u8,
	votes:       [g.LANES]u8,
	picked:      bool, // the local hero picked (Reward) or rested (Rest)
	offers:      [g.LUCKY_COIN_OFFERS]g.Card_Id,
	deck_count:  u8,
	_pad:        [3]u8,
	deck:        [g.DECK_MAX]Deck_Card,
}

// A hero's row (Unified.data.heroes.heroes[index]).
Hero_Row :: struct {
	player:     sim.Player, // their controller's key
	in_run:     bool,
	awake:      bool, // their player is here (else they sleep)
	ready:      bool,
	down:       bool,
	class:      g.Hero_Class,
	energy:     u8,
	strength:   i8,
	weak:       u8,
	vulnerable: u8,
	relics:     g.Relics,
	vote:       u8, // lane + 1
	picked:     bool,
	taunt:      bool,
	local:      bool, // the local player's
	aim_card:   u8, // the aim (their Input): a hand place + 1, an enemy's index + 1, a hero + 1
	aim_enemy:  u8,
	aim_hero:   u8,
	draw:       u8, // pile sizes
	discard:    u8,
	exhaust:    u8,
	hand:       u8,
	_pad:       u8,
	hp:         i16,
	max_hp:     i16,
	block:      i16,
}

Data_Heroes :: struct {
	heroes: [g.PLAYERS]Hero_Row,
}

fill_frame :: proc(f: ^Frame) {
	local := g.hero_of(f.state, f.local_players[0])
	fill_cards(f, local)
	fill_enemies(f)
	fill_run(f, local)
	fill_heroes(f, local)
}

// The aim of a hero's player (their newest Input), zero while asleep.
aim_of :: proc(f: ^Frame, hero: ^g.Hero) -> g.Input {
	slot, present := sim.player_slot(&f.state.players, hero.controller)
	return f.state.players.before[slot] if present else {}
}

fill_cards :: proc(f: ^Frame, local: int) {
	for &hero, index in f.state.heroes {
		if !hero.in_run do continue
		aim := aim_of(f, &hero)
		for handle, slot in sim.slice(&hero.hand) {
			card := sim.get(&f.state.cards, handle)
			if card == nil do continue
			def := g.CARDS[card.id]
			godot.push_view(f, handle, {kind = .Card}, Card_View {
				id       = card.id,
				upgraded = card.upgraded,
				hero     = u8(index),
				slot     = u8(slot),
				cost     = def.cost,
				target   = def.target,
				playable = index ==
					local && f.state.phase == .Heroes && !hero.ready && !hero.down && hero.energy >= def.cost,
				held     = int(aim.card) == slot + 1,
			})
		}
	}
}

fill_enemies :: proc(f: ^Frame) {
	enemies := sim.iterate(&f.state.enemies)
	for enemy, handle in sim.next(&enemies) {
		aimed: u8
		for &hero, index in f.state.heroes {
			if hero.in_run && aim_of(f, &hero).enemy == u8(handle.index) + 1 do aimed |= 1 << uint(index)
		}
		godot.push_view(f, handle, {kind = .Enemy}, Enemy_View {
			kind          = enemy.kind,
			weak          = enemy.weak,
			vulnerable    = enemy.vulnerable,
			intent        = enemy.intent.kind,
			intent_target = enemy.intent.target,
			aimed         = aimed,
			index         = u8(handle.index),
			hp            = enemy.hp,
			max_hp        = enemy.max_hp,
			block         = enemy.block,
			intent_amount = enemy.intent.amount,
		})
	}
}

fill_run :: proc(f: ^Frame, local: int) {
	state := f.state
	run := Data_Run {
		phase      = state.phase,
		floor      = state.floor,
		lane       = state.lane,
		node       = state.node,
		won        = state.won,
		local_hero = i8(local),
		round      = state.round,
	}
	for floor in 0 ..< g.FLOORS {
		for lane in 0 ..< g.LANES do run.map_nodes[floor * g.LANES + lane] = state.map_nodes[floor][lane]
	}
	for lane in 0 ..< g.LANES do run.can_go[lane] = state.phase == .Map && g.can_go(state, lane)
	for &hero in state.heroes do if hero.in_run && hero.vote > 0 do run.votes[hero.vote - 1] += 1
	if local >= 0 {
		hero := &state.heroes[local]
		run.picked = hero.picked
		run.offer_count = hero.offer_count
		run.offers = hero.offers
		cards := sim.iterate(&state.cards)
		for card, handle in sim.next(&cards) {
			if int(card.home) != local || int(run.deck_count) >= g.DECK_MAX do continue
			run.deck[run.deck_count] = {
				card     = handle,
				id       = card.id,
				upgraded = card.upgraded,
			}
			run.deck_count += 1
		}
	}
	godot.push_data(f, run)
}

fill_heroes :: proc(f: ^Frame, local: int) {
	data: Data_Heroes
	for &hero, index in f.state.heroes {
		if !hero.in_run do continue
		aim := aim_of(f, &hero)
		_, present := sim.player_slot(&f.state.players, hero.controller)
		data.heroes[index] = {
			player     = hero.controller,
			in_run     = true,
			awake      = present,
			ready      = hero.ready,
			down       = hero.down,
			class      = hero.class,
			energy     = hero.energy,
			strength   = hero.strength,
			weak       = hero.weak,
			vulnerable = hero.vulnerable,
			relics     = hero.relics,
			vote       = hero.vote,
			picked     = hero.picked,
			taunt      = hero.taunt,
			local      = index == local,
			aim_card   = aim.card,
			aim_enemy  = aim.enemy,
			aim_hero   = aim.hero,
			draw       = u8(hero.draw_pile.count),
			discard    = u8(hero.discard.count),
			exhaust    = u8(hero.exhaust.count),
			hand       = u8(hero.hand.count),
			hp         = hero.hp,
			max_hp     = hero.max_hp,
			block      = hero.block,
		}
	}
	godot.push_data(f, data)
}
