// The survivor's zones and debug draws (its steering and physics.debug_draw) are never state: a run with a Dev attached,
// every draw group on and the zones timed computes the checksums of a run without, across rollbacks.
package test_survivor

import "core:testing"
import "core:time"

import g "../survivor"
import "unified:headless"
import "unified:sim"

@(test)
draws_and_zones_change_nothing :: proc(t: ^testing.T) {
	TICKS :: 400
	plain := sim.create(&g.GAME_STRESS, 11)
	defer sim.destroy(plain)
	drawn := sim.create(&g.GAME_STRESS, 11)
	defer sim.destroy(drawn)
	sim.dev_attach(drawn, proc "contextless" () -> i64 {return time.tick_now()._nsec})
	sim.dev_enable(drawn, max(u64))
	commands: headless.Scripted_Commands(g.Game)
	defer headless.scripted_commands_destroy(&commands)
	inputs := make([]sim.Inputs(g.Game), TICKS + 1)
	defer delete(inputs)
	steer_lines, shapes := 0, 0
	for tick in u32(1) ..= TICKS {
		inputs[tick] = headless.scripted(&g.GAME_STRESS, plain, tick, 4, &commands)
		sim.step(plain, &inputs[tick])
		sim.step(drawn, &inputs[tick])
		if tick % 50 == 0 && tick > 20 {
			// a rollback 8 ticks back with drawing on: the draws come back with the same ticks
			testing.expect(t, sim.restore(drawn, tick - 8))
			for resim in tick - 7 ..= tick do sim.step(drawn, &inputs[resim])
		}
		testing.expect_value(t, sim.checksum(drawn), sim.checksum(plain))
		for shape in sim.debug_draws(drawn, tick).shapes {
			shapes += 1
			steer_lines += int(shape.group == u8(g.Zone.Steer))
		}
	}
	testing.expect(t, steer_lines > 0, "the steering draws who each enemy chases")
	testing.expect(t, shapes > steer_lines, "and physics.debug_draw its shapes")
	totals := sim.zone_totals(drawn)
	testing.expect_value(t, len(totals.names), len(g.Zone) + 1)
	testing.expect_value(t, totals.names[int(g.Zone.Steer)], "steer")
}
