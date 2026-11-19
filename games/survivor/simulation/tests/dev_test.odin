// The survivor's zones and debug draws (its steering and physics.debug_draw) are never state: a run with a Dev
// attached, every draw group on and the zones timed computes the checksums of a run without, across rollbacks. And its
// dev commands apply.
package test_survivor

import "core:testing"
import "core:time"

import g "../survivor"
import "unified:headless"
import "unified:headless/scenarios"
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

// The dev commands: found by their names, applied by the tick (a spawn, XP, the next wave in a match), and only those.
@(test)
dev_commands_apply :: proc(t: ^testing.T) {
	testing.expect(t, sim.has_dev_commands(g.Cmd))
	testing.expect(t, !sim.command_is_dev(g.Cmd, 0), "Cmd_Pick is no dev command")
	testing.expect(t, sim.command_is_dev(g.Cmd, 1) && sim.command_is_dev(g.Cmd, 2) && sim.command_is_dev(g.Cmd, 3))
	run := headless.run_begin(&g.GAME, 3, seated = 2)
	defer headless.run_end(&run)
	simulation := run.simulation

	// In the lobby there is no wave to skip.
	inputs := headless.run_inputs(&run)
	testing.expect(t, sim.add_command(&inputs, 1, g.Cmd_Dev_Skip_Wave{}))
	headless.run_step(&run, &inputs)
	testing.expect_value(t, simulation.state.wave, 0)

	for simulation.state.phase == .Lobby && simulation.tick < 200 do step(&run, {0 = {move_z = 127}})
	testing.expect_value(t, simulation.state.phase, g.Phase.Match)
	before, wave := simulation.state.enemies.count, simulation.state.wave
	player := sim.player_in_slot(simulation, 0)
	xp := sim.player_data(simulation, player).xp
	inputs = headless.run_inputs(&run)
	testing.expect(t, sim.add_command(&inputs, 0, g.Cmd_Dev_Spawn{count = 5, kind = .Brute}))
	testing.expect(t, sim.add_command(&inputs, 0, g.Cmd_Dev_Give_Xp{player = player, xp = 7}))
	testing.expect(t, sim.add_command(&inputs, 1, g.Cmd_Dev_Skip_Wave{}))
	headless.run_step(&run, &inputs)
	testing.expect(t, simulation.state.enemies.count >= before + 5, "five more enemies")
	testing.expect_value(t, simulation.state.wave, wave + 1)
	testing.expect(t, sim.player_data(simulation, player).xp >= xp + 7, "the XP")
	for _ in 0 ..< 64 do step(&run)
	testing.expect_value(t, simulation.state.wave, wave + 1) // and it lasts
	scenarios.expect_synced(t, &run)
}
