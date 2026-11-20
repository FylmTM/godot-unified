// The scripted party over a whole session: it starts runs, crosses the map, fights, picks rewards and rests, reaches
// the boss and ends a run, as the reference run and the benchmark rely on.
package test_deckbuilder

import "core:log"
import "core:testing"
import "unified:headless"
import "unified:sim"

import g "../deckbuilder"

@(test)
the_scripted_party_crosses_the_act :: proc(t: ^testing.T) {
	simulation := sim.create(&g.GAME_QUICK, 7)
	defer sim.destroy(simulation)
	commands: headless.Scripted_Commands(g.Game)
	defer headless.scripted_commands_destroy(&commands)
	counts: [32]int
	deepest, runs_over, wins := 0, 0, 0
	for tick in u32(1) ..= 3600 {
		inputs := headless.scripted(&g.GAME_QUICK, simulation, tick, g.PLAYERS, &commands)
		sim.step(simulation, &inputs)
		for &raw in sim.events_at(simulation, tick) {
			counts[raw.kind] += 1
			#partial switch event in sim.event_value(&raw, g.Event) {
			case g.Event_Node_Entered:
				deepest = max(deepest, int(event.floor))
			case g.Event_Run_Over:
				runs_over += 1
				wins += int(event.won)
			}
		}
	}
	log.infof("deepest floor %d, runs over %d (won %d), events by kind %v", deepest, runs_over, wins, counts)
	testing.expectf(t, deepest == g.FLOORS - 1, "the party reached floor %d", deepest)
	testing.expect(t, runs_over >= 1, "a run ended")
}
