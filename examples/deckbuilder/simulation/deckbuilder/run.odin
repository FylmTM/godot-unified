// A run: its start (or its continuation from a save), the map and the votes, the nodes (fights, rewards, rests,
// treasure), the save point and the end.
package deckbuilder

import "unified:sim"

// Starts a run for the players present, in slot order: a hero each, of their Profile's class, with its starter deck.
start_run :: proc(t: ^Tick) {
	if t.state.phase != .Camp do return
	stream := sim.rng_keyed(t.seed, Roll.Run, u64(t.state.runs))
	t.state.runs += 1
	t.state.run_seed = sim.rng_next(&stream) | 1 // never 0: 0 is no run
	t.state.heroes = {}
	sim.despawn_all(&t.state.cards)
	count := 0
	players := sim.iterate_present(t)
	for data, player in sim.next(&players) {
		hero := &t.state.heroes[count]
		class := sim.player_profile(t, player).hero_class
		hero^ = {
			controller = player,
			hero_class = class,
			in_run     = true,
		}
		hero.max_hp = ARCANIST_HP if class == .Arcanist else VANGUARD_HP
		hero.hp = hero.max_hp
		starter := STARTER_ARCANIST if class == .Arcanist else STARTER_VANGUARD
		for id in starter do add_card(t, count, id, false)
		data.watching = false
		count += 1
	}
	sim.emit(t, Event_Run_Started{heroes = u8(count)})
	generate_map(t)
	t.state.floor, t.state.lane = NO_FLOOR, LANES / 2
	open_map(t)
}

// Continues the run a save holds (the session's Setup, at tick 0): its heroes, asleep until their players come,
// entering the node it was saved at, so a fight quit midway is dealt again.
continue_run :: proc(t: ^Tick) {
	run := t.setup
	t.state.run_seed = run.run_seed
	for &saved, index in run.heroes {
		if !saved.in_run do continue
		hero := &t.state.heroes[index]
		hero^ = {
			hero_class = saved.hero_class,
			in_run     = true,
			hp         = saved.hp,
			max_hp     = saved.max_hp,
			relics     = saved.relics,
		}
		for card in sim.slice(&saved.deck) do add_card(t, index, card.id, card.upgraded)
	}
	generate_map(t)
	enter_node(t, int(run.floor), int(run.lane))
}

// A card into a hero's deck (false: the deck or the run is full).
add_card :: proc(t: ^Tick, hero: int, id: Card_Id, upgraded: bool) -> bool {
	in_deck := 0
	cards := sim.iterate(&t.state.cards)
	for card in sim.next(&cards) do in_deck += 1 if int(card.home) == hero else 0
	if in_deck >= DECK_MAX do return false
	card, _, ok := sim.spawn(&t.state.cards)
	if !ok do return false
	card^ = {
		id       = id,
		upgraded = upgraded,
		home     = u8(hero),
		holder   = u8(hero),
	}
	return true
}

// The act's map from the run's stream: fights on the first floors, an elite in the middle, a treasure, a rest before
// the boss, which stands alone in the middle lane on the last floor.
generate_map :: proc(t: ^Tick) {
	stream := sim.rng_keyed(t.state.run_seed, Roll.Map)
	for floor in 0 ..< FLOORS {
		for lane in 0 ..< LANES {
			kind := Node_Kind.Fight
			switch floor {
			case 3, 5:
				kind = .Elite if sim.rng_below(&stream, 3) == 0 else .Fight
			case 4:
				middle := [3]Node_Kind{.Fight, .Treasure, .Rest}
				kind = middle[sim.rng_below(&stream, 3)]
			case FLOORS - 2:
				kind = .Rest
			case FLOORS - 1:
				kind = .Boss if lane == LANES / 2 else .None
			}
			t.state.map_nodes[floor][lane] = kind
		}
	}
}

// Whether the party may go to `lane` on the next floor: a node there, the same lane or a neighbouring one (any lane
// for the first floor).
can_go :: proc(state: ^State, lane: int) -> bool {
	next := 0 if state.floor == NO_FLOOR else int(state.floor) + 1
	if next >= FLOORS || lane < 0 || lane >= LANES || state.map_nodes[next][lane] == .None do return false
	return state.floor == NO_FLOOR || (lane >= int(state.lane) - 1 && lane <= int(state.lane) + 1)
}

// The vote opens: every hero's vote cleared.
open_map :: proc(t: ^Tick) {
	t.state.phase = .Map
	for &hero in t.state.heroes do hero.vote = 0
}

vote :: proc(t: ^Tick, index: int, lane: int) {
	if t.state.phase != .Map || !can_go(t.state, lane) do return
	t.state.heroes[index].vote = u8(lane) + 1
	sim.emit(t, Event_Voted{hero = u8(index), lane = u8(lane)})
}

// Once every awake hero voted, the most-voted lane wins, a tie settled by the floor's vote stream.
count_votes :: proc(t: ^Tick) {
	votes: [LANES]int
	voters := 0
	for &hero, index in t.state.heroes {
		if !awake(t, index) do continue
		if hero.vote == 0 do return
		votes[hero.vote - 1] += 1
		voters += 1
	}
	if voters == 0 do return
	most := 0
	for count in votes do most = count if count > most else most
	tied: [LANES]int
	ties := 0
	for count, lane in votes {
		if count == most {
			tied[ties] = lane
			ties += 1
		}
	}
	next := 0 if t.state.floor == NO_FLOOR else int(t.state.floor) + 1
	stream := sim.rng_keyed(t.state.run_seed, Roll.Vote, 0, next)
	enter_node(t, next, tied[sim.rng_below(&stream, u32(ties))])
}

// Enters a node: the save point (the run as it is now), then what the node holds.
enter_node :: proc(t: ^Tick, floor, lane: int) {
	t.state.floor, t.state.lane = u8(floor), u8(lane)
	t.state.node = t.state.map_nodes[floor][lane]
	save_point(t)
	sim.emit(t, Event_Node_Entered{floor = u8(floor), lane = u8(lane), node = t.state.node})
	switch t.state.node {
	case .Fight, .Elite, .Boss:
		start_fight(t)
	case .Rest:
		t.state.phase = .Rest
		for &hero in t.state.heroes do hero.picked = false
	case .Treasure:
		for _, index in t.state.heroes do gain_relic(t, index)
		open_map(t)
	case .None:
		open_map(t)
	}
}

// The save point: the run as it enters its node (State.save, which Game.save gives).
save_point :: proc(t: ^Tick) {
	run := &t.state.save
	run^ = {
		tuning   = t.setup.tuning,
		version  = SAVE_VERSION,
		floor    = t.state.floor,
		lane     = t.state.lane,
		run_seed = t.state.run_seed,
	}
	for &hero, index in t.state.heroes {
		if !hero.in_run do continue
		saved := &run.heroes[index]
		saved^ = {
			hero_class = hero.hero_class,
			in_run     = true,
			relics     = hero.relics,
			hp         = hero.hp,
			max_hp     = hero.max_hp,
		}
	}
	cards := sim.iterate(&t.state.cards)
	for card in sim.next(&cards) {
		sim.append(&run.heroes[card.home].deck, Saved_Card{id = card.id, upgraded = card.upgraded})
	}
}

// After a fight: each hero is offered cards from their own reward stream (LUCKY_COIN_OFFERS with the Lucky Coin), an
// elite adds a relic each.
start_reward :: proc(t: ^Tick) {
	t.state.phase = .Reward
	for &hero, index in t.state.heroes {
		hero.picked = !hero.in_run
		hero.offer_count = 0
		hero.offers = {}
		if !hero.in_run do continue
		stream := sim.rng_keyed(t.state.run_seed, Roll.Reward, u64(index), int(t.state.floor))
		offers := LUCKY_COIN_OFFERS if .Lucky_Coin in hero.relics else OFFERS
		pool := len(Card_Id) - int(REWARD_FIRST)
		for hero.offer_count < u8(offers) {
			id := Card_Id(int(REWARD_FIRST) + int(sim.rng_below(&stream, u32(pool))))
			taken := false
			for offered in hero.offers[:hero.offer_count] do taken ||= offered == id
			if taken do continue
			hero.offers[hero.offer_count] = id
			hero.offer_count += 1
		}
		if t.state.node == .Elite do gain_relic(t, index)
	}
}

pick_reward :: proc(t: ^Tick, index: int, offer: int) {
	hero := &t.state.heroes[index]
	if t.state.phase != .Reward || hero.picked do return
	picked := Card_Id.None
	if offer != SKIP {
		if offer < 0 || offer >= int(hero.offer_count) do return
		picked = hero.offers[offer]
		if !add_card(t, index, picked, false) do picked = .None
	}
	hero.picked = true
	sim.emit(t, Event_Reward_Picked{hero = u8(index), card = picked})
}

// A rest: heal REST_HEAL_PCT of max HP, or upgrade one of the hero's cards.
rest :: proc(t: ^Tick, index: int, choice: Rest_Choice, card: sim.Handle(Card)) {
	hero := &t.state.heroes[index]
	if t.state.phase != .Rest || hero.picked do return
	switch choice {
	case .Heal:
		heal(t, index, i16(i32(hero.max_hp) * REST_HEAL_PCT / 100))
	case .Upgrade:
		upgraded := sim.get(&t.state.cards, card)
		if upgraded == nil || int(upgraded.home) != index || upgraded.upgraded do return
		upgraded.upgraded = true
	}
	hero.picked = true
	sim.emit(t, Event_Rested{hero = u8(index), choice = choice})
}

// Reward and Rest end once every awake hero picked (a sleeping one skips): the vote for the next floor opens.
check_picked :: proc(t: ^Tick) {
	if t.state.phase != .Reward && t.state.phase != .Rest do return
	for &hero, index in t.state.heroes do if awake(t, index) && !hero.picked do return
	open_map(t)
}

// A relic the hero doesn't have, from their own relic stream (none when they have them all).
gain_relic :: proc(t: ^Tick, index: int) {
	hero := &t.state.heroes[index]
	if !hero.in_run || card(hero.relics) == len(Relic) do return
	stream := sim.rng_keyed(t.state.run_seed, Roll.Relic, u64(index), int(t.state.floor))
	for {
		relic := Relic(sim.rng_below(&stream, len(Relic)))
		if relic in hero.relics do continue
		hero.relics += {relic}
		sim.emit(t, Event_Relic_Gained{hero = u8(index), relic = relic})
		return
	}
}

// The run ends (the boss fell, or every awake hero is down): OVER_HOLD_S of its outcome, then the camp. Its save
// goes: nothing to continue.
end_run :: proc(t: ^Tick, won: bool) {
	t.state.phase = .Over
	t.state.won = won
	t.state.save = {}
	sim.timer_start(t, &t.state.over_hold, OVER_HOLD_S)
	sim.emit(t, Event_Run_Over{won = won, floor = t.state.floor})
}

// After the hold, back to the camp: no heroes, no cards, no run.
over_hold :: proc(t: ^Tick) {
	if !sim.timer_done(t, t.state.over_hold) do return
	t.state.phase = .Camp
	t.state.run_seed = 0
	t.state.heroes = {}
	sim.despawn_all(&t.state.cards)
	sim.despawn_all(&t.state.enemies)
	sim.clear(&t.state.actions)
}
