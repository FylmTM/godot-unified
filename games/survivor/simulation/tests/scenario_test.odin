// The rollback scenario: a seeded run that forces barrel explosions, player deaths and respawns,
// and whole-match resets (all bodies destroyed and rebuilt) every few ticks, so they land inside
// rollback windows. Checked by sync-test at two window sizes and by a session of four clients on a bad network.
package test_survivor

import "core:testing"

import "../survivor"
import "unified:headless"
import "unified:headless/scenarios"
import "unified:sim"

BARRELS := [8]int{2, 7, 12, 17, 22, 27, 32, 37}

// survivor.tick with forced events by tick number (deterministic: same ticks on every peer).
scenario_tick :: proc(t: ^survivor.Tick) {
	if t.state.phase == .Match {
		if t.number % 23 == 0 {
			item := &t.state.items[BARRELS[(t.number / 23) % 8]]
			if item.alive {
				item.hp = 0 // explodes this tick
			}
		}
		if t.number % 37 == 0 {
			slot := int(t.number / 37) % survivor.PLAYERS
			survivor.damage_player(t, sim.player_in_slot(t, slot), 1000)
		}
		if t.number % 500 == 0 {
			for slot in 0 ..< survivor.PLAYERS {
				// everyone: match over, then a reset
				survivor.damage_player(t, sim.player_in_slot(t, slot), 1000)
			}
		}
	}
	survivor.tick(t)
}

SCENARIO := survivor.Game {
	name              = "survivor-scenario",
	version           = survivor.VERSION,
	tick_hz           = survivor.TICK_HZ,
	content           = #load("../../game/levels/arena.level"),
	world_create      = survivor.world_create,
	world_destroy     = survivor.world_destroy,
	extra             = survivor.extra,
	init              = survivor.init_stress, // the dense stress spawner
	tick              = scenario_tick,
	scripted_input    = survivor.scripted_input,
	scripted_commands = survivor.scripted_commands,
}

SCENARIO_SUITE := scenarios.Suite(survivor.Game) {
	game    = &SCENARIO,
	players = survivor.PLAYERS,
	seed    = 13,
	ticks   = 900,
}

// The forced events land inside rollback windows of two sizes, and every re-simulated tick matches.
@(test)
scenario_synctest :: proc(t: ^testing.T) {
	for window in ([]u32{8, 13}) {
		run := headless.run_begin(&SCENARIO, 11, window = window)
		defer headless.run_end(&run)
		for _ in 1 ..= 1600 do headless.run_scripted(&run, survivor.PLAYERS)
		scenarios.expect_synced(t, &run)
		explosions := headless.run_events(&run, survivor.Event_Barrel_Exploded)
		deaths := headless.run_events(&run, survivor.Event_Player_Died)
		respawns := headless.run_events(&run, survivor.Event_Player_Respawned)
		overs := headless.run_events(&run, survivor.Event_Match_Over)
		starts := headless.run_events(&run, survivor.Event_Match_Started)
		testing.expectf(t, explosions >= 20, "window %d: explosions %d", window, explosions)
		testing.expectf(
			t,
			deaths >= 12 && respawns >= 10,
			"window %d: deaths %d, respawns %d",
			window,
			deaths,
			respawns,
		)
		testing.expectf(t, overs >= 2 && starts >= 3, "window %d: overs %d, starts %d", window, overs, starts)
	}
}

// The same events under prediction and rollback: four clients on a bad network agree.
@(test)
scenario_networked :: proc(t: ^testing.T) {scenarios.session_agrees(t, &SCENARIO_SUITE, 4, .Bad)}
