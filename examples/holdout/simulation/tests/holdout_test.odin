// holdout's own rules: a whole scripted run offline (the sim alone: the suite sync-tests the same inputs), then each
// rule on a sync-tested run the test steers (headless.Run).
package test_holdout

import "core:testing"

import g "../holdout"
import "unified:dmath"
import "unified:headless"
import "unified:headless/scenarios"
import "unified:nav"
import "unified:physics"
import "unified:sim"

// What a scripted run did, from its events and its state.
Played :: struct {
	shots, kills, headshots, wrong_headshots, explosions, bolts, core_hits, downs, respawns: int,
	waves_started, waves_cleared, defeats, lobbies:                                          int,
	gates_used:                                                                              [g.MAX_GATES]bool,
	on_deck, on_bridge, in_trench:                                                           int, // enemy-ticks there
	max_enemies:                                                                             int,
}

// `players` scripted players from tick 1 for `ticks` ticks (seed 7), offline.
play :: proc(players: int, ticks: u32) -> (played: Played) {
	simulation := sim.create(&g.GAME, 7)
	defer sim.destroy(simulation)
	for tick in 1 ..= ticks {
		inputs := sim.seated_inputs(simulation) // the players seated so far stay present
		for slot in 0 ..< players {
			if tick == 1 do sim.seat(&inputs, simulation, slot, slot + 1)
			inputs.input[slot] = sim.scripted_player_input(&g.GAME, 7, slot, tick, &simulation.state)
		}
		sim.step(simulation, &inputs)
		for &raw in sim.events_at(simulation, tick) {
			#partial switch event in sim.event_value(&raw, g.Event) {
			case g.Event_Shot:
				played.shots += 1
			case g.Event_Enemy_Hit:
				played.headshots += int(event.headshot)
				played.wrong_headshots += int(event.headshot && event.damage != g.RIFLE_DAMAGE * g.HEADSHOT_MULT)
			case g.Event_Enemy_Died:
				played.kills += 1
			case g.Event_Explosion:
				played.explosions += 1
			case g.Event_Bolt_Fired:
				played.bolts += 1
			case g.Event_Core_Hit:
				played.core_hits += 1
			case g.Event_Player_Downed:
				played.downs += 1
			case g.Event_Player_Respawned:
				played.respawns += 1
			case g.Event_Wave_Started:
				played.waves_started += 1
			case g.Event_Wave_Cleared:
				played.waves_cleared += 1
			case g.Event_Core_Destroyed:
				played.defeats += 1
			case g.Event_Lobby:
				played.lobbies += 1
			}
		}
		world := simulation.world
		played.max_enemies = max(played.max_enemies, int(simulation.state.enemies.count))
		enemies := sim.iterate(&simulation.state.enemies)
		for enemy in sim.next(&enemies) {
			played.on_deck += int(enemy.pos.y > 3.5 && enemy.pos.x > 22)
			played.on_bridge += int(enemy.pos.x > -20 && enemy.pos.x < -16 && enemy.pos.y > -0.5)
			played.in_trench += int(enemy.pos.y < -2)
			for gate, i in world.gates[:world.gate_count] {
				if dmath.dist_sq3(enemy.pos, gate) < 4 do played.gates_used[i] = true
			}
		}
	}
	return
}

// Four scripted players for four minutes: the run starts on a Ready press, waves come in from every gate and walk the
// mesh in 3D (down from the deck the east gate opens onto, over the bridge across the trench), the players shoot
// (headshots for HEADSHOT_MULT times RIFLE_DAMAGE) and throw grenades, spitters spit, enemies reach the core and the
// players, the downed get up again, waves are cleared, the core falls and the yard goes back to the lobby.
@(test)
a_scripted_run_plays_every_rule :: proc(t: ^testing.T) {
	played := play(4, 240 * g.TICK_HZ)
	testing.expectf(t, played.waves_started >= 3 && played.waves_cleared >= 2, "waves: %v", played)
	testing.expectf(t, played.gates_used == {true, true, true, false}, "every gate: %v", played.gates_used)
	testing.expectf(t, played.on_deck > 0 && played.on_bridge > 0, "the deck and the bridge: %v", played)
	testing.expect_value(t, played.in_trench, 0) // the bridge is the way across
	testing.expectf(t, played.kills > 50 && played.headshots > 0 && played.wrong_headshots == 0, "shots: %v", played)
	testing.expectf(t, played.explosions > 0 && played.bolts > 0 && played.core_hits > 0, "%v", played)
	testing.expectf(t, played.downs > 0 && played.respawns > 0, "downs: %v", played)
	testing.expectf(t, played.defeats >= 1 && played.lobbies >= 1, "the core fell, the lobby again: %v", played)
	testing.expect(t, played.max_enemies <= g.ENEMY_CAP)
}

// The yard's mesh: every gate reaches the core, whose goal is on the yard's floor (not on an island inside the core:
// the exporter leaves those out).
@(test)
the_yard_mesh_leads_every_gate_to_the_core :: proc(t: ^testing.T) {
	simulation := sim.create(&g.GAME, 7)
	defer sim.destroy(simulation)
	world := simulation.world
	field := nav.field(&world.fields, world.core_poly)
	for gate in world.gates[:world.gate_count] {
		poly, _ := nav.nearest(&world.mesh, gate, 5)
		testing.expectf(t, poly != nav.NO_POLY && field.cost[poly] < nav.UNREACHABLE, "gate %v reaches the core", gate)
	}
	testing.expect_value(t, world.core_goal.y, 0)
}

// One player: the first steps of each test's run.
@(private = "file")
solo :: proc() -> headless.Run(g.Game) {
	run := headless.run_begin(&g.GAME, 3, seated = 1)
	for _ in 0 ..< 4 do headless.run_step(&run)
	return run
}

// Ready in the lobby starts the countdown; START_DELAY_S later the first wave starts, and its enemies come in on the
// mesh with their bodies.
@(test)
ready_starts_the_waves :: proc(t: ^testing.T) {
	run := solo()
	defer headless.run_end(&run)
	state := &run.simulation.state
	inputs: [g.PLAYERS]g.Input
	inputs[0].buttons = {.Ready}
	headless.run_step(&run, inputs)
	testing.expect_value(t, state.phase, g.Phase.Countdown)
	_, counted := headless.run_last_event(&run, g.Event_Countdown)
	testing.expect(t, counted)
	for _ in 0 ..< int(g.START_DELAY_S * g.TICK_HZ) do headless.run_step(&run)
	testing.expect_value(t, state.phase, g.Phase.Wave)
	testing.expect_value(t, state.wave, 1)
	for _ in 0 ..< 3 * g.TICK_HZ do headless.run_step(&run)
	testing.expect(t, state.enemies.count > 0, "the first wave's enemies came in")
	enemies := sim.iterate(&state.enemies)
	for enemy in sim.next(&enemies) {
		testing.expect(t, enemy.poly != nav.NO_POLY && enemy.body != {}, "on the mesh, with a body")
	}
	scenarios.expect_synced(t, &run)
}

// A teammate who holds Use beside a downed player for REVIVE_S gets them up with REVIVE_HP; letting go starts over.
@(test)
use_revives_a_downed_teammate :: proc(t: ^testing.T) {
	run := headless.run_begin(&g.GAME, 3, seated = 2)
	defer headless.run_end(&run)
	for _ in 0 ..< 4 do headless.run_step(&run)
	simulation := run.simulation
	helper := sim.player_in_slot(simulation, 0)
	downed := sim.player_in_slot(simulation, 1)
	down := sim.player_data(simulation, downed)
	down.downed, down.hp = true, 0 // no respawn timer running: down until revived
	beside := physics.body_position(simulation.world.phys, down.controller.body) + {0.9, 0, 0}
	physics.character_teleport(simulation.world.phys, &sim.player_data(simulation, helper).controller, beside)
	headless.run_pin(&run)
	inputs: [g.PLAYERS]g.Input
	inputs[0].buttons = {.Use}
	revive_ticks := int(g.REVIVE_S * g.TICK_HZ)
	for _ in 0 ..< revive_ticks / 2 do headless.run_step(&run, inputs)
	testing.expect(t, down.revive_ticks > 0)
	headless.run_step(&run) // let go
	testing.expect_value(t, down.revive_ticks, 0)
	for _ in 0 ..< revive_ticks - 1 do headless.run_step(&run, inputs)
	testing.expect(t, down.downed, "not yet")
	headless.run_step(&run, inputs)
	testing.expect(t, !down.downed && down.hp == g.REVIVE_HP, "up again")
	revived, found := headless.run_last_event(&run, g.Event_Player_Revived)
	testing.expect(t, found && revived.player == downed && revived.reviver == helper)
	scenarios.expect_synced(t, &run)
}

// A player who falls out of the yard goes down; no one revives them, so RESPAWN_S later they get up at their spawn
// with PLAYER_HP.
@(test)
a_downed_player_alone_respawns :: proc(t: ^testing.T) {
	run := solo()
	defer headless.run_end(&run)
	simulation := run.simulation
	player := sim.player_in_slot(simulation, 0)
	data := sim.player_data(simulation, player)
	physics.character_teleport(simulation.world.phys, &data.controller, {0, g.KILL_Y - 5, 0})
	headless.run_pin(&run)
	headless.run_step(&run)
	testing.expect(t, data.downed && data.hp == 0, "down")
	for _ in 0 ..< int(g.RESPAWN_S * g.TICK_HZ) do headless.run_step(&run)
	respawned, found := headless.run_last_event(&run, g.Event_Player_Respawned)
	testing.expect(t, found && respawned.player == player, "respawned")
	testing.expect(t, !data.downed && data.hp == g.PLAYER_HP)
	at := physics.body_position(simulation.world.phys, data.controller.body)
	testing.expect(t, dmath.dist_sq2(at.xz, simulation.world.spawns[0].xz) < 0.01, "at the spawn")
	scenarios.expect_synced(t, &run)
}

// The last wave cleared: the yard held (Event_Victory), and OVER_HOLD_S later the lobby again, everything reset.
@(test)
clearing_the_last_wave_wins :: proc(t: ^testing.T) {
	run := solo()
	defer headless.run_end(&run)
	state := &run.simulation.state
	state.phase, state.wave, state.core_hp = .Wave, g.WAVES, 10
	for &spawned in state.spawned do spawned = 255
	headless.run_pin(&run)
	headless.run_step(&run)
	_, won := headless.run_last_event(&run, g.Event_Victory)
	testing.expect(t, won && state.phase == .Over && state.won)
	for _ in 0 ..< int(g.OVER_HOLD_S * g.TICK_HZ) do headless.run_step(&run)
	lobby, back := headless.run_last_event(&run, g.Event_Lobby)
	testing.expect(t, back && lobby.won && lobby.wave == g.WAVES, "back to the lobby")
	testing.expect(t, state.phase == .Lobby && state.wave == 0 && state.core_hp == g.CORE_HP)
	scenarios.expect_synced(t, &run)
}

// The core at 0 during a wave: the run is lost (Event_Core_Destroyed).
@(test)
the_core_falling_loses :: proc(t: ^testing.T) {
	run := solo()
	defer headless.run_end(&run)
	state := &run.simulation.state
	state.phase, state.wave, state.core_hp = .Wave, 3, 0
	headless.run_pin(&run)
	headless.run_step(&run)
	lost, found := headless.run_last_event(&run, g.Event_Core_Destroyed)
	testing.expect(t, found && lost.wave == 3 && state.phase == .Over && !state.won)
	scenarios.expect_synced(t, &run)
}
