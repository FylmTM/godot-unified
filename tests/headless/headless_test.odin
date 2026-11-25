// unified:headless on the toy game, without a process per mode: what the standard scenarios on the toy
// (tests/scenarios) don't cover: the files the CLI writes, the build check of a replay, the sessions' JSON and their
// repeatability, and the netcode policies.
package test_headless

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"

import "../toy"
import "unified:headless"
import "unified:netcode"
import "unified:sim"

temp_path :: proc(name: string) -> string {
	dir := os.temp_directory(context.temp_allocator) or_else "."
	path, _ := filepath.join(
		{dir, fmt.tprintf("unified-headless-test-%d-%s", os.get_pid(), name)},
		context.temp_allocator,
	)
	return path
}

// What the offline runs prove here and nowhere else (tests/sim and the toy's suite prove sync-tests, replays and
// resumes): run_synctest ends on run_sim's checksum, the trace file holds every tick's checksum, the log reads back
// from its file, and a log another build recorded is refused (an unknown build's, 0, replays).
@(test)
offline_modes_agree :: proc(t: ^testing.T) {
	log_path, trace_path := temp_path("run.log"), temp_path("run.trace")
	defer for path in ([]string{log_path, trace_path}) {
		os.remove(path)
	}
	trace: headless.Trace
	defer headless.trace_destroy(&trace)
	input_log: sim.Input_Log(toy.Game)
	defer sim.log_destroy(&input_log)
	run := headless.run_sim(&toy.GAME, 300, 7, 3, &trace, &input_log)
	synctest := headless.run_synctest(&toy.GAME, 300, 8, 7, 3)
	testing.expect_value(t, synctest.final_checksum, run.final_checksum)
	testing.expect(t, headless.log_write(log_path, &input_log) && headless.trace_write(&trace, trace_path))
	trace_text, trace_err := os.read_entire_file(trace_path, context.temp_allocator)
	trace_lines := strings.split_lines(strings.trim_space(string(trace_text)), context.temp_allocator)
	testing.expect(t, trace_err == nil && len(trace_lines) == 300)
	testing.expect_value(t, trace_lines[299], fmt.tprintf("%06d %016x", 300, run.final_checksum))
	read_log, log_ok := headless.log_read(log_path, toy.Game)
	defer sim.log_destroy(&read_log)
	testing.expect(t, log_ok && read_log.compat == sim.compat_of(&toy.GAME))
	read_log.compat ~= 1
	_, other_build_ok := headless.run_replay(&toy.GAME, &read_log)
	testing.expect(t, !other_build_ok)
	read_log.compat = 0
	unknown, unknown_ok := headless.run_replay(&toy.GAME, &read_log)
	testing.expect(t, unknown_ok && unknown.final_checksum == run.final_checksum)
	// the checkpoints: every one agrees; one flipped is the first divergent, the one before it the last agreeing
	testing.expectf(
		t,
		unknown.checkpoints == 300 / sim.DEEP_CHECKSUM_EVERY &&
		unknown.diverged_tick == 0 &&
		unknown.agreed_tick == 288,
		"%v",
		unknown,
	)
	read_log.checkpoints[5].checksum ~= 1
	flipped, flipped_ok := headless.run_replay(&toy.GAME, &read_log)
	testing.expectf(
		t,
		!flipped_ok &&
		flipped.diverged_tick == read_log.checkpoints[5].tick &&
		flipped.agreed_tick == read_log.checkpoints[4].tick,
		"%v",
		flipped,
	)
	testing.expect_value(t, flipped.final_checksum, run.final_checksum) // replayed to the end anyway
	// another build: refused, unless any_build, then checked against its checkpoints
	read_log.checkpoints[5].checksum ~= 1
	read_log.compat = 1
	_, refused_ok := headless.run_replay(&toy.GAME, &read_log)
	testing.expect(t, !refused_ok, "another build's log is refused")
	other, other_ok := headless.run_replay(&toy.GAME, &read_log, any_build = true)
	testing.expect(
		t,
		other_ok && other.checkpoints == unknown.checkpoints,
		"any_build replays it against its checkpoints",
	)
}

// A game without a scripted player (Game.scripted_input is optional): its players send zero Inputs.
@(test)
a_game_without_a_scripted_player_runs :: proc(t: ^testing.T) {
	game := toy.GAME
	game.scripted_input = nil
	game.scripted_commands = nil
	result := headless.run_synctest(&game, 64, 8, 1, 2)
	testing.expect_value(t, result.mismatches, 0)
	testing.expect(t, result.resimulated > 0 && result.final_checksum != 0)
	session := headless.session_run(&game, {clients = 2, profile = netcode.PROFILES[.Wan], ticks = 160, seed = 1})
	defer headless.session_result_destroy(&session)
	testing.expect(t, session.ok, "a session of players without a script")
}

// What the script of a_scripted_player_reads_the_sessions_setup saw: how many calls (input and commands) got the
// session's Setup, and how many another (one test uses them).
@(private = "file")
script_setup_seen: struct {
	right, wrong: int,
}

// The scripted player reads the session's Setup, never a copy in the State: an offline run hands it the run's
// (Sim.setup), a session's clients the relay's (from their Welcome, a late joiner's included).
@(test)
a_scripted_player_reads_the_sessions_setup :: proc(t: ^testing.T) {
	SETUP :: toy.Setup {
		life_bonus = 5,
	}
	tally :: proc(setup: toy.Setup) {
		if setup == SETUP do sync.atomic_add(&script_setup_seen.right, 1)
		else do sync.atomic_add(&script_setup_seen.wrong, 1)
	}
	game := toy.GAME
	game.scripted_input = proc(seed: u64, slot: int, tick: u32, state: ^toy.State, setup: toy.Setup) -> toy.Input {
		tally(setup)
		return toy.scripted_input(seed, slot, tick, state, setup)
	}
	game.scripted_commands = proc(
		seed: u64,
		slot: int,
		tick: u32,
		state: ^toy.State,
		setup: toy.Setup,
		out: ^sim.Command_Out(toy.Command),
	) {
		tally(setup)
		toy.scripted_commands(seed, slot, tick, state, setup, out)
	}
	headless.run_sim(&game, 64, 1, 2, SETUP)
	testing.expect_value(t, script_setup_seen.wrong, 0)
	testing.expect_value(t, script_setup_seen.right, 64 * 2 * 2) // each tick, each slot: its input and its commands
	script_setup_seen = {}
	session := headless.session_run(
		&game,
		{clients = 3, profile = netcode.PROFILES[.Wan], ticks = 200, seed = 1, late_tick = 100, late_slot = 2},
		SETUP,
	)
	defer headless.session_result_destroy(&session)
	testing.expect(t, session.ok, "the session")
	testing.expect_value(t, sync.atomic_load(&script_setup_seen.wrong), 0)
	testing.expect(t, sync.atomic_load(&script_setup_seen.right) > 0, "the clients' scripts ran")
}

// The same session twice on the virtual clock: identical, to the byte.
@(test)
virtual_sessions_repeat :: proc(t: ^testing.T) {
	cfg := headless.Session_Config {
		clients = 2,
		profile = netcode.PROFILES[.Wan],
		ticks   = 320,
		seed    = 3,
	}
	first := headless.session_run(&toy.GAME, cfg)
	defer headless.session_result_destroy(&first)
	second := headless.session_run(&toy.GAME, cfg)
	defer headless.session_result_destroy(&second)
	testing.expect(t, first.ok && second.ok)
	// Wall time, the one thing that may differ (how many client steps stepped the sim may not).
	testing.expect_value(t, first.clients[0].client_steps.count, second.clients[0].client_steps.count)
	first.clients[0].step_us, second.clients[0].step_us = {}, {}
	first.clients[0].client_steps, second.clients[0].client_steps = {}, {}
	json := netcode.client_json(first.clients[0]) // what the CLI prints
	testing.expect(
		t,
		strings.has_prefix(json, `{"slot":0,"member":`) &&
		strings.contains(json, `,"final_tick":320,"checksums":[[16,"`),
	)
	testing.expect_value(t, json, netcode.client_json(second.clients[0]))
	testing.expect_value(t, first.relay_net, second.relay_net)
}

// Start players far from the relay (up to 300 ms round trip, the most a client plays smoothly at, and the
// `bad` profile) keep their inputs from tick 1 on: the relay's clock starts half a second after Welcome,
// so a far player's first inputs reach the relay in time. Nothing replaced, across network seeds.
@(test)
far_start_players_keep_their_first_inputs :: proc(t: ^testing.T) {
	profiles := [?]netcode.Profile {
		{
			name    = "far",
			latency = 150_000,
			jitter  = 10_000,
		},
		{
			name    = "far-lossy",
			latency = 140_000,
			jitter  = 10_000,
			loss    = 20,
		},
		netcode.PROFILES[.Bad], // bad: 120 ± 40 ms each way, loss, reordering
	}
	for profile in profiles {
		for seed in u64(1) ..= 4 {
			cfg := headless.Session_Config {
				clients = 2,
				profile = profile,
				ticks   = 192,
				seed    = seed,
			}
			result := headless.session_run(&toy.GAME, cfg)
			defer headless.session_result_destroy(&result)
			testing.expectf(t, result.ok, "%s, seed %d: the session failed", profile.name, seed)
			first_replaced := -1
			for tick, k in result.log.ticks {
				if tick.replaced != {} {
					first_replaced = k + 1
					break
				}
			}
			testing.expectf(
				t,
				result.replaced == 0,
				"%s, seed %d: %d inputs replaced, the first at tick %d",
				profile.name,
				seed,
				result.replaced,
				first_replaced,
			)
		}
	}
}
