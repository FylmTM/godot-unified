// The seeded-bug eval: determinism bugs planted in the toy, each caught by the detector meant for it. The proof that
// a passing suite means something: if a detector stops seeing its bug, its test here fails.
//
// Runtime bugs only; the static traps have planted cases of their own: f64, core:math, FMA, map, untyped float
// literals and globals in tick code (tests/lint), pointers, padding and bad unions in the state block (tests/sim:
// plain_data_check, declarations_are_checked).
package test_scenarios

import "core:strings"
import "core:testing"

import "../toy"
import "unified:headless"
import "unified:netcode"
import "unified:sim"

// Bug: the tick reads the World's count of the ticks it ran, which is never rolled back, so a re-simulated tick sees
// another count. Detector: rollback_every_tick (run_synctest).
@(test)
seeded_world_state_is_caught_by_rollback_every_tick :: proc(t: ^testing.T) {
	game := toy.GAME
	game.tick = proc(tick: ^toy.Tick) {
		toy.tick(tick)
		if data := toy.in_slot(tick.state, 0); data != nil do data.score += i32(tick.world.ticks_run % 3)
	}
	result := headless.run_synctest(&game, 120, 8, SUITE.seed, 2)
	testing.expectf(t, result.mismatches > 0, "a World count read by tick: synctest saw no mismatch")
}

// Bug: the tick emits an event built from the World's count of the ticks it ran, which is never rolled back: the
// state and its checksum are right, but a re-simulated tick emits another event than the first time, so a view shows
// doubled or cancelled effects after each rollback. Detector: rollback_every_tick (run_synctest compares each
// re-simulated tick's events with the first run's).
@(test)
seeded_world_state_in_an_event_is_caught_by_rollback_every_tick :: proc(t: ^testing.T) {
	game := toy.GAME
	game.tick = proc(tick: ^toy.Tick) {
		toy.tick(tick)
		if tick.number % 4 == 0 {
			sim.emit(tick, toy.Event_Expired{thing = {index = u32(tick.world.ticks_run % 32)}})
		}
	}
	result := headless.run_synctest(&game, 120, 8, SUITE.seed, 2)
	testing.expectf(
		t,
		result.mismatches > 0 && strings.contains(result.problem, "emitted other events"),
		"an event from the World: synctest saw %d mismatches (%q)",
		result.mismatches,
		result.problem,
	)
}

// Bug: a NaN reaches the state block (an unguarded 0/0): every peer on one CPU agrees, but its bits differ between x64
// and arm64, so a mixed session desyncs. Detector: the sync-test's NaN scan (sim.find_nan), which names the field.
@(test)
seeded_nan_in_the_block_is_caught_by_rollback_every_tick :: proc(t: ^testing.T) {
	game := toy.GAME
	game.tick = proc(tick: ^toy.Tick) {
		toy.tick(tick)
		if data := toy.in_slot(tick.state, 1); data != nil && tick.number == 50 {
			data.pos.y = data.pos.x * 0 / (data.pos.x - data.pos.x) // 0/0 at run time
		}
	}
	result := headless.run_synctest(&game, 120, 8, SUITE.seed, 2)
	testing.expectf(
		t,
		strings.has_prefix(result.problem, "tick 50: players.data[") &&
		strings.contains(result.problem, "].pos[1] is a NaN"),
		"a NaN in the block: synctest says %q",
		result.problem,
	)
}

// Bug: a counter every instance shares (a package global, or a library's static), reset when a world is created, as
// a C library's init would. Each run alone is deterministic and two back-to-back runs agree; two alive at once
// disturb each other. Detector: runs_match (run_interleaved).
@(private = "file")
shared_ticks: u32

@(test)
seeded_shared_state_is_caught_by_runs_match :: proc(t: ^testing.T) {
	game := toy.GAME
	game.world_create = proc(seed: u64, _: []sim.Level_File, _: sim.No_Setup) -> ^toy.World {
		shared_ticks = 0
		return new(toy.World)
	}
	game.tick = proc(tick: ^toy.Tick) {
		toy.tick(tick)
		shared_ticks += 1
		if data := toy.in_slot(tick.state, 0); data != nil do data.score += i32(shared_ticks % 3)
	}
	// back to back, each run alone looks deterministic: why runs_match interleaves its two runs
	first := headless.run_sim(&game, 120, SUITE.seed, 2)
	second := headless.run_sim(&game, 120, SUITE.seed, 2)
	testing.expect_value(t, second.final_checksum, first.final_checksum)
	result := headless.run_interleaved(&game, 120, SUITE.seed, 2)
	testing.expectf(t, result.mismatches > 0, "state shared by two instances: the interleaved runs agreed")
}

// Bug: the state takes a value from a memory address (as a sort or a hash by pointer would), so each machine
// computes its own, even on an ideal network with no rollback. Detector: the netcode's desync detection.
@(test)
seeded_address_dependence_is_caught_by_desync_detection :: proc(t: ^testing.T) {
	game := toy.GAME
	game.init = proc(t: ^toy.Tick) {
		address := u64(uintptr(t.world))
		t.state.spawned = u32(address ~ address >> 32)
	}
	network, _ := netcode.profile_by_name("ideal")
	result := headless.session_run(&game, {
		clients = 2,
		profile = network,
		ticks   = 120,
		seed    = SUITE.seed,
	})
	defer headless.session_result_destroy(&result)
	testing.expectf(t, result.desyncs > 0, "a state taken from an address: the session saw no desync")
}

// Bug: a rule that reads the World (player 0 scores on every 50th call of `tick`): a client that rolls back calls
// it more often, so the clients' states part. Detector: the desync detection, end to end: the relay finds the tick,
// tells every client, and the typed report names the field. On an ideal network nobody rolls back: no desync.
@(test)
a_desync_is_detected_and_reported :: proc(t: ^testing.T) {
	game := toy.GAME
	game.tick = proc(tick: ^toy.Tick) {
		toy.tick(tick)
		if data := toy.in_slot(tick.state, 0); tick.world.ticks_run % 50 == 0 && data != nil do data.score += 1
	}
	cfg := headless.Session_Config {
		clients = 3,
		profile = netcode.PROFILES[.Wan], // wan: rollbacks, so `tick` runs a different number of times
		ticks   = 640,
		seed    = 1,
	}
	result := headless.session_run(&game, cfg)
	defer headless.session_result_destroy(&result)
	testing.expect(t, result.desyncs > 0)
	testing.expect(t, !result.ok) // a desync fails the session
	testing.expectf(
		t,
		result.desync.tick > 0 && result.desync.tick % 16 == 0,
		"first desync at tick %d",
		result.desync.tick,
	)
	testing.expect(t, result.desync.diverged != {} && card(result.desync.diverged) < cfg.clients)
	testing.expectf(
		t,
		strings.contains(result.desync.detail, "players.data[0].score"),
		"the detail names the field: %q",
		result.desync.detail,
	)
	for client in result.clients {
		testing.expectf(t, client.stats.desyncs > 0, "player %d was not told", client.slot)
		testing.expect(t, !client.ok)
	}
	cfg.profile = netcode.PROFILES[.Ideal]
	ideal := headless.session_run(&game, cfg)
	defer headless.session_result_destroy(&ideal)
	testing.expect_value(t, ideal.desyncs, 0)
	testing.expect(t, ideal.ok)
}
