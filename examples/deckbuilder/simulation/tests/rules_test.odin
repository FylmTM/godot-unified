// deckbuilder's rule tests, each on a sync-tested run (headless.Run: every step re-simulated 8 ticks back and
// compared). A fight with known hands starts from a Setup (a saved run's shape: the decks are the test's), so nothing
// depends on what a shuffle dealt.
package test_deckbuilder

import "core:testing"
import "unified:headless"
import "unified:headless/scenarios"
import "unified:sim"

import g "../deckbuilder"

// A saved run on floor 0, lane 0 (always a fight) with one hero per deck, every card of a deck its own.
run_of :: proc(decks: ..[]g.Card_Id) -> (setup: g.Setup) {
	setup = {
		tuning   = .Play,
		version  = g.SAVE_VERSION,
		run_seed = 0x1234,
	}
	for deck, index in decks {
		hero := &setup.heroes[index]
		hero^ = {
			hero_class = .Vanguard,
			in_run     = true,
			hp         = g.VANGUARD_HP,
			max_hp     = g.VANGUARD_HP,
		}
		for id in deck do sim.append(&hero.deck, g.Saved_Card{id = id})
	}
	return
}

// A fight from `setup`, its heroes' players seated (their heroes claimed on tick 1), in its tuning.
fight_of :: proc(setup: g.Setup) -> headless.Run(g.Game) {
	heroes := 0
	for hero in setup.heroes do heroes += int(hero.in_run)
	game: ^g.Game = &g.GAME_QUICK if setup.tuning == .Quick else &g.GAME
	return headless.run_begin(game, 1, setup, seated = heroes)
}

hand_card :: proc(run: ^headless.Run(g.Game), hero, place: int) -> sim.Handle(g.Card) {
	return run.simulation.state.heroes[hero].hand.items[place]
}

first_enemy :: proc(run: ^headless.Run(g.Game)) -> (handle: sim.Handle(g.Enemy), enemy: ^g.Enemy) {
	enemies := sim.iterate(&run.simulation.state.enemies)
	for item, item_handle in sim.next(&enemies) do return item_handle, item
	return
}

STRIKES :: []g.Card_Id{.Strike, .Strike, .Strike, .Strike, .Strike, .Strike}

// A Strike lands on the tick it is played: the enemy takes its damage, the energy is spent, the card goes to the
// discard pile and the play is announced.
@(test)
a_play_resolves_on_the_tick_it_lands :: proc(t: ^testing.T) {
	run := fight_of(run_of(STRIKES))
	defer headless.run_end(&run)
	state := &run.simulation.state
	testing.expect_value(t, state.phase, g.Phase.Heroes)
	testing.expect_value(t, int(state.heroes[0].hand.count), g.HAND_SIZE)
	target, enemy := first_enemy(&run)
	hp := enemy.hp
	card := hand_card(&run, 0, 0)
	headless.run_command(&run, 0, g.Command_Play_Card{card = card, enemy = target})
	testing.expect_value(t, headless.run_events(&run, g.Event_Card_Played), 1)
	testing.expect_value(t, enemy.hp, hp - 6)
	testing.expect_value(t, state.heroes[0].energy, g.ENERGY - 1)
	testing.expect_value(t, int(state.heroes[0].hand.count), g.HAND_SIZE - 1)
	testing.expect_value(t, state.heroes[0].discard.items[0], card)
	scenarios.expect_synced(t, &run)
}

// Plays land in the relay's order: when an ally's Strikes kill the enemy first, the next player's Strike at it is
// refused (No_Target): their card stays in hand and their energy is kept.
@(test)
an_allys_kill_refuses_the_play :: proc(t: ^testing.T) {
	setup := run_of(STRIKES, STRIKES)
	setup.tuning = .Quick // enemies that fall to two or three Strikes
	run := fight_of(setup)
	defer headless.run_end(&run)
	state := &run.simulation.state
	target, enemy := first_enemy(&run)
	strikes := int(enemy.hp + 5) / 6 // what kills it (no block yet on the first turn)
	testing.expect(t, strikes <= 3, "the first enemy falls to the first hero's energy")
	inputs := headless.run_inputs(&run)
	for k in 0 ..< strikes do sim.add_command(&inputs, 0, g.Command_Play_Card{card = hand_card(&run, 0, k), enemy = target})
	late := hand_card(&run, 1, 0)
	sim.add_command(&inputs, 1, g.Command_Play_Card{card = late, enemy = target})
	headless.run_step(&run, &inputs)
	refused, found := headless.run_last_event(&run, g.Event_Play_Refused)
	testing.expect(t, found && refused.reason == .No_Target && refused.hero == 1, "the late play is refused")
	testing.expect_value(t, state.heroes[1].energy, g.ENERGY)
	testing.expect_value(t, hand_card(&run, 1, 0), late)
	testing.expect(t, sim.get(&state.enemies, target) == nil, "the enemy fell")
	scenarios.expect_synced(t, &run)
}

// A play costs energy (the fourth Strike on 3 energy is refused) and needs its card in hand (the same card twice:
// the second is refused).
@(test)
a_play_needs_its_card_and_the_energy :: proc(t: ^testing.T) {
	run := fight_of(run_of({.Defend, .Defend, .Defend, .Defend, .Defend}))
	defer headless.run_end(&run)
	inputs := headless.run_inputs(&run)
	for k in 0 ..< 4 do sim.add_command(&inputs, 0, g.Command_Play_Card{card = hand_card(&run, 0, k)})
	headless.run_step(&run, &inputs)
	refused, _ := headless.run_last_event(&run, g.Event_Play_Refused)
	testing.expect_value(t, refused.reason, g.Refusal.No_Energy)
	testing.expect_value(t, run.simulation.state.heroes[0].block, 15)
	played := run.simulation.state.heroes[0].discard.items[0]
	headless.run_command(&run, 0, g.Command_Play_Card{card = played})
	refused, _ = headless.run_last_event(&run, g.Event_Play_Refused)
	testing.expect_value(t, refused.reason, g.Refusal.Not_In_Hand)
	scenarios.expect_synced(t, &run)
}

// Cards that target an ally: Cover blocks for them, Rally draws from their own pile, Channel gives them energy, and
// Hand Off moves a card into their hand, which goes home when the fight ends.
@(test)
ally_cards_reach_the_ally :: proc(t: ^testing.T) {
	run := fight_of(
		run_of(
			{.Cover, .Rally, .Channel, .Hand_Off, .Strike},
			{.Defend, .Defend, .Defend, .Defend, .Defend, .Defend, .Defend, .Defend},
		),
	)
	defer headless.run_end(&run)
	state := &run.simulation.state
	find :: proc(run: ^headless.Run(g.Game), id: g.Card_Id) -> sim.Handle(g.Card) {
		for card in sim.slice(&run.simulation.state.heroes[0].hand) {
			if sim.get(&run.simulation.state.cards, card).id == id do return card
		}
		return {}
	}
	cover, rally, channel := find(&run, .Cover), find(&run, .Rally), find(&run, .Channel)
	hand_off, strike := find(&run, .Hand_Off), find(&run, .Strike)
	inputs := headless.run_inputs(&run)
	sim.add_command(&inputs, 0, g.Command_Play_Card{card = cover, ally = 2})
	sim.add_command(&inputs, 0, g.Command_Play_Card{card = rally, ally = 2})
	sim.add_command(&inputs, 0, g.Command_Play_Card{card = channel, ally = 2})
	sim.add_command(&inputs, 0, g.Command_Play_Card{card = hand_off, ally = 2, extra = strike})
	headless.run_step(&run, &inputs)
	ally := &state.heroes[1]
	testing.expect_value(t, ally.block, 7)
	testing.expect_value(t, int(ally.hand.count), g.HAND_SIZE + 2 + 1) // Rally's two, and the Strike
	testing.expect_value(t, ally.energy, g.ENERGY + 1)
	testing.expect_value(t, int(ally.draw_pile.count), 8 - g.HAND_SIZE - 2)
	testing.expect_value(t, sim.get(&state.cards, strike).holder, 1)
	testing.expect_value(t, int(state.heroes[0].exhaust.count), 1) // Channel exhausts
	headless.run_command(&run, 0, g.Command_Dev_Win_Fight{})
	testing.expect_value(t, state.phase, g.Phase.Reward)
	testing.expect_value(t, sim.get(&state.cards, strike).holder, 0) // home after the fight
	scenarios.expect_synced(t, &run)
}

// The heroes' turn ends once every awake hero is ready; then the enemies act one at a time, ENEMY_BEAT_S apart, and
// the next round deals new hands.
@(test)
the_enemies_act_one_per_beat :: proc(t: ^testing.T) {
	run := fight_of(run_of(STRIKES, STRIKES))
	defer headless.run_end(&run)
	state := &run.simulation.state
	headless.run_command(&run, 0, g.Command_End_Turn{ready = true})
	testing.expect_value(t, state.phase, g.Phase.Heroes) // the other hero is not ready
	headless.run_command(&run, 1, g.Command_End_Turn{ready = true})
	testing.expect_value(t, state.phase, g.Phase.Enemies)
	enemies := int(state.enemies.count)
	acted: [dynamic]u32
	defer delete(acted)
	for _ in 0 ..< 4 * g.TICK_HZ {
		headless.run_step(&run)
		if _, found := headless.run_last_event(&run, g.Event_Enemy_Acted); found do append(&acted, run.simulation.tick)
		if state.phase == .Heroes do break
	}
	testing.expect_value(t, len(acted), enemies)
	beat := u32(sim.ticks(g.ENEMY_BEAT_S, g.TICK_HZ))
	for k in 1 ..< len(acted) do testing.expect_value(t, acted[k] - acted[k - 1], beat)
	testing.expect_value(t, state.phase, g.Phase.Heroes)
	testing.expect_value(t, state.round, 2)
	testing.expect_value(t, int(state.heroes[0].hand.count), g.HAND_SIZE)
	scenarios.expect_synced(t, &run)
}

// A hero whose player is away sleeps: the turn ends without them and no enemy targets them. Their player takes them
// back on returning; someone new in their place takes the lowest free hero.
@(test)
an_absent_players_hero_sleeps :: proc(t: ^testing.T) {
	run := fight_of(run_of(STRIKES, STRIKES))
	defer headless.run_end(&run)
	state := &run.simulation.state
	headless.run_seat(&run, 1, 0) // slot 1's player leaves
	headless.run_step(&run)
	headless.run_command(&run, 0, g.Command_End_Turn{ready = true})
	testing.expect_value(t, state.phase, g.Phase.Enemies) // the sleeping hero counts as ready
	for state.phase == .Enemies do headless.run_step(&run)
	testing.expect_value(t, state.heroes[1].hp, g.VANGUARD_HP) // never targeted
	headless.run_seat(&run, 1, 2) // they come back
	headless.run_step(&run)
	testing.expect_value(t, g.hero_of(state, sim.player_in_slot(run.simulation, 1)), 1)
	headless.run_seat(&run, 1, 0)
	headless.run_step(&run)
	headless.run_seat(&run, 1, 9) // someone new in their slot
	headless.run_step(&run)
	claimed, found := headless.run_last_event(&run, g.Event_Hero_Claimed)
	testing.expect(t, found && claimed.hero == 1, "the newcomer takes the free hero")
	scenarios.expect_synced(t, &run)
}

// With one hero down, the last standing hero's player leaving loses the run whichever turn it lands in: the heroes'
// turn doesn't wait for a hero who sleeps when every awake one is down.
@(test)
the_last_standing_player_leaving_loses_the_run_in_either_turn :: proc(t: ^testing.T) {
	for in_enemies_turn in ([]bool{false, true}) {
		run := fight_of(run_of(STRIKES, STRIKES))
		defer headless.run_end(&run)
		state := &run.simulation.state
		state.heroes[0].down, state.heroes[0].hp = true, 0
		headless.run_pin(&run)
		if in_enemies_turn {
			headless.run_command(&run, 1, g.Command_End_Turn{ready = true})
			testing.expect_value(t, state.phase, g.Phase.Enemies)
		}
		headless.run_seat(&run, 1, 0) // the last standing hero's player leaves
		for _ in 0 ..< 4 * g.TICK_HZ {
			headless.run_step(&run)
			if state.phase == .Over do break
		}
		testing.expect_value(t, state.phase, g.Phase.Over)
		over, found := headless.run_last_event(&run, g.Event_Run_Over)
		testing.expect(t, found && !over.won, "the run is lost")
		scenarios.expect_synced(t, &run)
	}
}

// A player who arrives with no hero free watches, and takes a hero the moment its player leaves.
@(test)
a_watcher_takes_a_hero_that_frees :: proc(t: ^testing.T) {
	run := fight_of(run_of(STRIKES, STRIKES))
	defer headless.run_end(&run)
	state := &run.simulation.state
	headless.run_seat(&run, 2, 3) // a third player: no hero free
	headless.run_step(&run)
	watcher := sim.player_in_slot(run.simulation, 2)
	testing.expect(t, sim.player_data(run.simulation, watcher).watching, "watching")
	headless.run_seat(&run, 1, 0) // hero 1's player leaves
	headless.run_step(&run)
	testing.expect_value(t, g.hero_of(state, watcher), 1)
	testing.expect(t, !sim.player_data(run.simulation, watcher).watching, "playing")
	claimed, found := headless.run_last_event(&run, g.Event_Hero_Claimed)
	testing.expect(t, found && claimed.hero == 1 && claimed.player == watcher, "claimed")
	scenarios.expect_synced(t, &run)
}

// A shuffle comes from the hero's stream for the floor, never the tick: the same run entering its first node on
// another tick (the votes later) deals the same hands.
@(test)
the_deal_does_not_depend_on_the_tick :: proc(t: ^testing.T) {
	hands :: proc(wait: int) -> (ids: [2][g.HAND_SIZE]g.Card_Id) {
		run := headless.run_begin(&g.GAME, 3, seated = 2)
		defer headless.run_end(&run)
		headless.run_command(&run, 0, g.Command_Start_Run{})
		for _ in 0 ..< wait do headless.run_step(&run)
		inputs := headless.run_inputs(&run)
		for slot in 0 ..< 2 do sim.add_command(&inputs, slot, g.Command_Vote{lane = 1})
		headless.run_step(&run, &inputs)
		state := &run.simulation.state
		for &hero, index in state.heroes[:2] {
			for card, k in sim.slice(&hero.hand) do ids[index][k] = sim.get(&state.cards, card).id
		}
		return
	}
	testing.expect_value(t, hands(0), hands(5))
}

// The most-voted lane wins; a tie is settled by the floor's own stream, the same on every run of the seed.
@(test)
the_party_votes_on_the_next_node :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 3, seated = 3)
	defer headless.run_end(&run)
	headless.run_command(&run, 0, g.Command_Start_Run{})
	inputs := headless.run_inputs(&run)
	sim.add_command(&inputs, 0, g.Command_Vote{lane = 2})
	sim.add_command(&inputs, 1, g.Command_Vote{lane = 0})
	headless.run_step(&run, &inputs)
	testing.expect_value(t, run.simulation.state.phase, g.Phase.Map) // the third hero has not voted
	headless.run_command(&run, 2, g.Command_Vote{lane = 2})
	testing.expect_value(t, run.simulation.state.floor, 0)
	testing.expect_value(t, run.simulation.state.lane, 2)
	scenarios.expect_synced(t, &run)
}

// The save (Game.save) is the run as it entered its node; as JSON and back, a new session continues it from there:
// the same enemies, the same hands.
@(test)
a_save_continues_the_run :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 5, seated = 2)
	defer headless.run_end(&run)
	headless.run_command(&run, 0, g.Command_Start_Run{})
	inputs := headless.run_inputs(&run)
	for slot in 0 ..< 2 do sim.add_command(&inputs, slot, g.Command_Vote{lane = 0})
	headless.run_step(&run, &inputs)
	state := &run.simulation.state
	saved := run.simulation.setup
	testing.expect(t, g.save(state, &saved) && saved.version == g.SAVE_VERSION && saved.floor == 0, "a save")
	text := sim.setup_to_json(&saved, context.temp_allocator)
	back, problem := sim.setup_from_json(&g.GAME, text)
	testing.expect_value(t, problem, "")
	continued := headless.run_begin(&g.GAME, 99, back, seated = 2)
	defer headless.run_end(&continued)
	again := &continued.simulation.state
	testing.expect_value(t, again.enemies.count, state.enemies.count)
	for k in 0 ..< int(state.enemies.count) do testing.expect_value(t, again.enemies.items[k], state.enemies.items[k])
	for index in 0 ..< 2 {
		mine, theirs := &state.heroes[index], &again.heroes[index]
		testing.expect_value(t, theirs.hand.count, mine.hand.count)
		for k in 0 ..< int(mine.hand.count) {
			testing.expect_value(
				t,
				sim.get(&again.cards, theirs.hand.items[k]).id,
				sim.get(&state.cards, mine.hand.items[k]).id,
			)
		}
	}
}
