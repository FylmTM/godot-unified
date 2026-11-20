// deckbuilder (examples/deckbuilder/README.md): a co-op deck-building card battler. 1-4 heroes climb one act of
// FLOORS floors, each with their own deck, hand, energy and relics, playing their cards at once against the enemies.
//
// The files, by feature: game (this: the descriptors and the tick), tuning (every rule number), state, input (the aim
// and the commands), events, cards (the card table and a play), heroes (claiming, draws, damage), enemies, fight (the
// turns), run (the map, votes, nodes, rewards, the save point) and the scripted player (script).
package deckbuilder

import "unified:sim"

PLAYERS :: 4 // input slots: the most heroes in a run
TICK_HZ :: 32 // nothing moves: the rate only sets how soon a play lands, and the packet rate

// The game's version (sim.Game.version, part of the netcode's compat): bump it when a rule or constant changes what a
// tick computes without changing the State or Input layout, or two builds desync instead of refusing each other.
VERSION :: "1"

// The game's types for unified:sim: no World (nothing outside the block).
Game :: sim.Game(State, Input, sim.No_World, Event, Command, Setup, Profile, PLAYERS)
// What every system gets: the state, the inputs and commands, the tick's player changes.
Tick :: sim.Tick(Game)

// The game as played (the `play` tuning).
@(rodata)
GAME := Game {
	name                  = "deckbuilder",
	version               = VERSION,
	tick_hz               = TICK_HZ,
	init                  = init,
	tick                  = tick,
	save                  = save,
	scripted_commands     = scripted_commands,
	scripted_profile      = scripted_profile,
	input_delay_min_ticks = 2, // a card game: a play lands 62 ms later, and almost never a tick late
}

// The same game with the `quick` tuning: enemy HP divided by QUICK_HP_DIV, so the scripted player crosses the act.
// What the headless binary, the end-to-end suite and the bench run.
@(rodata)
GAME_QUICK := Game {
	name = "deckbuilder-quick",
	version = VERSION,
	tick_hz = TICK_HZ,
	setup = {tuning = .Quick},
	init = init,
	tick = tick,
	save = save,
	scripted_commands = scripted_commands,
	scripted_profile = scripted_profile,
	benches = {{what = "deckbuilder (quick tuning), 4 heroes against the boss", entities = 4, ticks = 600}},
	bench_prepare = bench_prepare,
	input_delay_min_ticks = 2,
}

// Tick 0: the camp, or the run the session's Setup continues.
init :: proc(t: ^Tick) {
	t.state.floor = NO_FLOOR
	if t.setup.version != 0 do continue_run(t)
}

// One tick: the systems in their order (examples/deckbuilder/README.md, Systems).
tick :: proc(t: ^Tick) {
	claim_heroes(t)
	apply_commands(t)
	#partial switch t.state.phase {
	case .Map:
		count_votes(t)
	case .Heroes:
		heroes_turn(t)
	case .Enemies:
		enemies_turn(t)
	case .Reward, .Rest:
		check_picked(t)
	case .Over:
		over_hold(t)
	}
}

// Each present player's commands, in slot order, each in the order sent, on the hero they play (a watcher only starts
// a run).
apply_commands :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for _, player in sim.next(&players) {
		for sent in sim.commands(t, player) {
			hero := hero_of(t.state, player) // a run started by an earlier command gave them one
			switch command in sent {
			case Command_Start_Run:
				start_run(t)
			case Command_Dev_Win_Fight:
				win_fight(t)
			case Command_Play_Card:
				if hero >= 0 do play_card(t, hero, command)
			case Command_End_Turn:
				if hero >= 0 do end_turn(t, hero, command.ready)
			case Command_Vote:
				if hero >= 0 do vote(t, hero, int(command.lane))
			case Command_Pick_Reward:
				if hero >= 0 do pick_reward(t, hero, int(command.offer))
			case Command_Rest:
				if hero >= 0 do rest(t, hero, command.choice, command.card)
			}
		}
	}
}

// Every enemy falls (Command_Dev_Win_Fight).
win_fight :: proc(t: ^Tick) {
	if t.state.phase != .Heroes && t.state.phase != .Enemies do return
	enemies := sim.iterate(&t.state.enemies)
	for _, handle in sim.next(&enemies) {
		sim.emit(t, Event_Enemy_Died{enemy = handle})
		sim.despawn(&t.state.enemies, handle)
	}
	check_fight_won(t)
}

// The save (sim.Game.save): the save point the run last entered, in this session's tuning; no run, none.
save :: proc(state: ^State, setup: ^Setup) -> bool {
	tuning := setup.tuning
	setup^ = state.save
	setup.tuning = tuning
	return true
}
