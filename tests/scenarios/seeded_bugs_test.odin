// The seeded-bug eval (#123): determinism bugs planted in the toy, one game per bug, each caught by the
// detector meant for it. The proof that a passing suite means something: if a detector stops seeing its
// bug, its test here fails.
//
// Runtime bugs only; the static traps have planted cases of their own: f64, core:math, FMA, map,
// untyped float literals and globals in tick code (tests/lint: lint_catches_violations,
// lint_catches_escape_hatches), pointers, padding and bad unions in the state block (tests/sim:
// plain_data_check, bad_declarations_are_refused).
package test_scenarios

import "core:testing"

import "../toy"
import "unified:headless"
import "unified:netcode"
import "unified:sim"

// The toy with something outside its state block, where each bug lives.
Bug_World :: struct {
	toy:       toy.World,
	ticks_run: u32, // ticks this world computed, re-simulations included
}

Bug_Game :: sim.Game(toy.State, toy.Input, Bug_World, toy.PLAYERS)
Bug_Tick :: sim.Tick(toy.State, toy.Input, Bug_World, toy.PLAYERS)
Bug_Headless :: headless.Headless(toy.State, toy.Input, Bug_World, toy.PLAYERS)

// Bug: the World keeps a count of the ticks it ran and the tick reads it. It is never rolled back, so a
// re-simulated tick sees another count. Detector: rollback_every_tick (run_synctest).
@(test)
seeded_world_state_is_caught_by_rollback_every_tick :: proc(t: ^testing.T) {
	game := bug_game("world_not_rolled_back", tick = proc(tick: ^Bug_Tick) {
			toy_tick(tick)
			tick.world.ticks_run += 1
			if data := toy.in_slot(tick.state, 0); data != nil do data.score += i32(tick.world.ticks_run % 3)
		})
	bugged := bug_headless(&game)
	result := headless.run_synctest(&bugged, 120, 8, SUITE.seed, 2)
	testing.expectf(t, result.mismatches > 0, "a World count read by tick: synctest saw no mismatch")
}

// Bug: a counter every instance shares (a package global, or a library's static), reset when a world is
// created, as a C library's init would. Each run alone is deterministic and two back-to-back runs agree;
// two alive at once disturb each other. Detector: runs_match (run_interleaved).
@(private = "file")
shared_ticks: u32

@(test)
seeded_shared_state_is_caught_by_runs_match :: proc(t: ^testing.T) {
	game := bug_game("shared_between_instances", tick = proc(tick: ^Bug_Tick) {
			toy_tick(tick)
			shared_ticks += 1
			if data := toy.in_slot(tick.state, 0); data != nil do data.score += i32(shared_ticks % 3)
		}, world_create = proc(seed: u64, _: []u8) -> ^Bug_World {
			shared_ticks = 0
			return new(Bug_World)
		})
	bugged := bug_headless(&game)
	// back to back, each run alone looks deterministic: why runs_match interleaves its two runs
	first := headless.run_sim(&bugged, 120, SUITE.seed, 2)
	second := headless.run_sim(&bugged, 120, SUITE.seed, 2)
	testing.expect_value(t, second.final_checksum, first.final_checksum)
	result := headless.run_interleaved(&bugged, 120, SUITE.seed, 2)
	testing.expectf(t, result.mismatches > 0, "state shared by two instances: the interleaved runs agreed")
}

// Bug: the state takes a value from a memory address (as a sort or a hash by pointer would). Each
// machine has its own addresses. Detector: the netcode's desync detection (session_agrees).
@(test)
seeded_address_dependence_is_caught_by_desync_detection :: proc(t: ^testing.T) {
	game := bug_game("address_dependent", init = proc(state: ^toy.State, world: ^Bug_World, seed: u64) {
			state.rng = sim.rng_seed(seed)
			address := u64(uintptr(world))
			state.spawned = u32(address ~ address >> 32)
		})
	bugged := bug_headless(&game)
	network, _ := netcode.profile_by_name("ideal")
	result := headless.session_run(&bugged, {
		clients     = 2,
		transport   = "loopback",
		virtual     = true,
		profile     = network,
		ticks       = 120,
		seed        = SUITE.seed,
		late_player = -1,
	})
	defer headless.session_result_destroy(&result)
	testing.expectf(t, result.desyncs > 0, "a state taken from an address: the session saw no desync")
}

// The toy's tick on the toy's part of the World.
toy_tick :: proc(tick: ^Bug_Tick) {
	inner := toy.Tick {
		state          = tick.state,
		world          = &tick.world.toy,
		number         = tick.number,
		seed           = tick.seed,
		inputs         = tick.inputs,
		events         = tick.events,
		player_changes = tick.player_changes,
		players_layout = tick.players_layout,
	}
	toy.tick(&inner)
}

// The toy on a Bug_World, with one of its procs replaced.
bug_game :: proc(
	name: string,
	tick: proc(tick: ^Bug_Tick) = toy_tick,
	world_create: proc(seed: u64, content: []u8) -> ^Bug_World = bug_world_create,
	init: proc(state: ^toy.State, world: ^Bug_World, seed: u64) = bug_init,
) -> Bug_Game {
	return Bug_Game {
		name = name,
		version = "1",
		tick_hz = toy.HZ,
		world_create = world_create,
		world_destroy = proc(world: ^Bug_World) {free(world)},
		init = init,
		tick = tick,
		events = toy.Event,
		commands = toy.Cmd,
	}
}

bug_world_create :: proc(seed: u64, content: []u8) -> ^Bug_World {
	return new(Bug_World)
}

bug_init :: proc(state: ^toy.State, world: ^Bug_World, seed: u64) {
	state.rng = sim.rng_seed(seed)
}

bug_headless :: proc(game: ^Bug_Game) -> Bug_Headless {
	return Bug_Headless {
		game = game,
		scripted_input = proc(seed: u64, slot: int, tick: u32, state: ^toy.State) -> toy.Input {
			return toy.scripted_input(seed, slot, tick)
		},
	}
}
