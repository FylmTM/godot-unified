// The standard benchmark's state (sim.Game.bench_prepare; the headless `bench`): the act's last node, `count` heroes
// (1 to PLAYERS) against the boss, each with their starter deck and three reward cards, as a run continued from a
// save is set up. The scripted players claim the heroes as they arrive and play the fight out.
package deckbuilder

import "unified:dmath"
import "unified:sim"

BENCH_SEED :: 0x5eed_dec4

bench_prepare :: proc(state: ^State, world: ^sim.No_World, count: int) {
	run := Setup {
		tuning   = .Quick,
		version  = SAVE_VERSION,
		floor    = FLOORS - 1,
		lane     = LANES / 2,
		run_seed = BENCH_SEED,
	}
	for index in 0 ..< dmath.clamp(count, 1, PLAYERS) {
		class := Hero_Class(index % 2)
		hero := &run.heroes[index]
		hero^ = {
			class  = class,
			in_run = true,
			max_hp = ARCANIST_HP if class == .Arcanist else VANGUARD_HP,
		}
		hero.hp = hero.max_hp
		starter := STARTER_ARCANIST if class == .Arcanist else STARTER_VANGUARD
		for id in starter do sim.append(&hero.deck, Saved_Card{id = id})
		for id in ([]Card_Id{.Cleave, .Heavy_Blow, .Linked_Guard}) do sim.append(&hero.deck, Saved_Card{id = id})
	}
	events := sim.Events {
		list = make([dynamic]sim.Raw_Event, context.temp_allocator),
	}
	t := Tick {
		state   = state,
		setup   = run,
		events  = &events,
		tick_hz = TICK_HZ,
	}
	continue_run(&t)
}
