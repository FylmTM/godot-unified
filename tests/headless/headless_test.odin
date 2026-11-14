// unified:headless on the toy game, without a process per mode: the offline runs (sim, synctest,
// replay, snapshot/resume) agree with each other, traces and logs round-trip through files, and
// in-process sessions on the virtual clock finish with every checksum agreeing, a late joiner
// included. The standard end-to-end scenarios on the toy are in tests/scenarios.
package test_headless

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

import "../toy"
import "unified:headless"
import "unified:netcode"
import "unified:sim"

// Read-only: the runs only read it, so the tests share it.
HEADLESS := headless.Headless(toy.State, toy.Input, toy.World, toy.PLAYERS) {
	game = &toy.GAME,
	scripted_input = proc(seed: u64, player: int, tick: u32, state: ^toy.State) -> toy.Input {
		return toy.scripted_input(seed, player, tick)
	},
	scripted_commands = proc(seed: u64, player: int, tick: u32, state: ^toy.State, out: ^sim.Command_Out) {
		toy.scripted_commands(seed, player, tick, out)
	},
}

// An offline run gives a tick at most four commands of a player and the rest to the next ticks, in order,
// as the relay does (toy.scripted_commands sends six bumps, 100 * player + 0..5, at tick 250).
@(test)
offline_runs_hold_commands_over_the_limit_for_the_next_tick :: proc(t: ^testing.T) {
	input_log: sim.Input_Log(toy.Input, toy.PLAYERS)
	defer sim.log_destroy(&input_log)
	headless.run_sim(&HEADLESS, 260, 3, 2, nil, &input_log)
	for player in 0 ..< 2 {
		applied_at: [6]u32 // the tick each of the six bumps went into
		for k in 249 ..< 255 {
			inputs := sim.log_inputs(&input_log, k)
			testing.expect(t, len(sim.commands(&inputs, player)) <= sim.COMMANDS_PER_PLAYER)
			for &raw in sim.commands(&inputs, player) {
				bump := sim.command_value(&raw, toy.Command).(toy.Cmd_Bump) or_continue
				if i := int(bump.amount) - 100 * player; i >= 0 && i < 6 && applied_at[i] == 0 {
					applied_at[i] = u32(k + 1)
				}
			}
		}
		testing.expectf(
			t,
			applied_at[0] == 250 && slice.is_sorted(applied_at[:]) && applied_at[4] == 251,
			"player %d: ticks %v",
			player,
			applied_at,
		)
	}
}

temp_path :: proc(name: string) -> string {
	dir := os.temp_directory(context.temp_allocator) or_else "."
	path, _ := filepath.join(
		{dir, fmt.tprintf("unified-headless-test-%d-%s", os.get_pid(), name)},
		context.temp_allocator,
	)
	return path
}

@(test)
offline_modes_agree :: proc(t: ^testing.T) {
	log_path, trace_path := temp_path("run.log"), temp_path("run.trace")
	defer for path in ([]string{log_path, trace_path}) {
		os.remove(path)
	}
	trace, second_trace: headless.Trace
	defer headless.trace_destroy(&trace)
	defer headless.trace_destroy(&second_trace)
	input_log: sim.Input_Log(toy.Input, toy.PLAYERS)
	defer sim.log_destroy(&input_log)
	run := headless.run_sim(&HEADLESS, 300, 7, 3, &trace, &input_log)
	second_run := headless.run_sim(&HEADLESS, 300, 7, 3, &second_trace)
	testing.expect_value(t, run.final_checksum, second_run.final_checksum) // deterministic
	testing.expect(t, trace.first == 1 && len(trace.sums) == 300 && trace.sums[299] == run.final_checksum)
	synctest := headless.run_synctest(&HEADLESS, 300, 8, 7, 3)
	testing.expect_value(t, synctest.mismatches, 0)
	testing.expect(t, synctest.resimulated > 300)
	testing.expect_value(t, synctest.final_checksum, run.final_checksum)
	// Through files: the log and the trace read back as written, and the log replays to the trace.
	testing.expect(t, sim.log_write(log_path, &input_log) && headless.trace_write(&trace, trace_path))
	read_log, log_ok := sim.log_read(log_path, toy.Input, toy.PLAYERS)
	defer sim.log_destroy(&read_log)
	testing.expect(t, log_ok)
	read_trace, trace_ok := headless.trace_read(trace_path)
	defer headless.trace_destroy(&read_trace)
	testing.expect(t, trace_ok && read_trace.first == 1 && slice.equal(read_trace.sums[:], trace.sums[:]))
	replay_trace: headless.Trace
	defer headless.trace_destroy(&replay_trace)
	replay, replay_ok := headless.run_replay(&HEADLESS, &read_log, &replay_trace)
	testing.expect(t, replay_ok)
	testing.expect_value(t, replay.final_checksum, run.final_checksum)
	testing.expect(t, slice.equal(replay_trace.sums[:], trace.sums[:]))
	// Snapshot at 200, resume 100 ticks: the same ticks 201..300 as the straight run.
	snapshot, _ := headless.run_snapshot(&HEADLESS, 200, 7, 3)
	defer delete(snapshot)
	resume_trace: headless.Trace
	defer headless.trace_destroy(&resume_trace)
	resume, resume_ok := headless.run_resume(&HEADLESS, snapshot, 100, 3, &resume_trace)
	testing.expect(t, resume_ok)
	testing.expect_value(t, resume.final_tick, 300)
	testing.expect_value(t, resume.final_checksum, run.final_checksum)
	testing.expect(t, resume_trace.first == 201 && slice.equal(resume_trace.sums[:], trace.sums[200:]))
	checksum, has := headless.trace_at(&resume_trace, 250)
	testing.expect(t, has && checksum == trace.sums[249])
	_, has = headless.trace_at(&resume_trace, 200)
	testing.expect(t, !has)
}

@(test)
session_on_the_virtual_clock :: proc(t: ^testing.T) {
	cfg := headless.Session_Config {
		clients     = 3,
		transport   = "loopback",
		virtual     = true,
		profile     = netcode.PROFILES[2], // bad: loss, jitter, reordering
		ticks       = 640,
		seed        = 11,
		late_player = 2,
		late_tick   = 320,
	}
	result := headless.session_run(&HEADLESS, cfg)
	defer headless.session_result_destroy(&result)
	testing.expect(t, result.ok)
	testing.expect_value(t, result.desyncs, 0)
	testing.expect_value(t, len(result.clients), 3)
	testing.expect_value(t, len(result.log.ticks), 640)
	// The relay's log replays to every client's last verified checksum (tick 640).
	simulation := sim.create(&toy.GAME, 11)
	defer sim.destroy(simulation)
	for k in 0 ..< len(result.log.ticks) {
		inputs := sim.log_inputs(&result.log, k)
		sim.step(simulation, &inputs)
	}
	for client, i in result.clients {
		testing.expect_value(t, client.player, i)
		testing.expect_value(t, client.final_tick, 640)
		last := client.checksums[len(client.checksums) - 1] if len(client.checksums) > 0 else {}
		testing.expectf(t, last == {640, sim.checksum(simulation)}, "client %d's last verified checksum: %v", i, last)
	}
	testing.expect(t, result.clients[2].join_tick >= 320 && result.clients[2].checksums[0][0] >= 320)
	// The JSON the CLI prints is built from these results.
	json := netcode.client_json(result.clients[0])
	testing.expect(t, strings.has_prefix(json, `{"player":0,"final_tick":640,"checksums":[[16,"`))
}

// The same session twice on the virtual clock: identical, to the byte.
@(test)
virtual_sessions_repeat :: proc(t: ^testing.T) {
	cfg := headless.Session_Config {
		clients     = 2,
		transport   = "loopback",
		virtual     = true,
		profile     = netcode.PROFILES[1],
		ticks       = 320,
		seed        = 3,
		late_player = -1,
	}
	first := headless.session_run(&HEADLESS, cfg)
	defer headless.session_result_destroy(&first)
	second := headless.session_run(&HEADLESS, cfg)
	defer headless.session_result_destroy(&second)
	testing.expect(t, first.ok && second.ok)
	first.clients[0].step_us, second.clients[0].step_us = {}, {} // wall time, the one thing that may differ
	testing.expect_value(t, netcode.client_json(first.clients[0]), netcode.client_json(second.clients[0]))
	testing.expect_value(t, first.relay_net, second.relay_net)
}

// Start players far from the relay (up to 300 ms round trip, the most a client plays smoothly at, and the
// `bad` profile) keep their inputs from tick 1 on: the relay's clock starts half a second after Welcome,
// so a far player's first inputs reach the relay in time. Nothing replaced, across network seeds.
@(test)
far_start_players_keep_their_first_inputs :: proc(t: ^testing.T) {
	profiles := [?]netcode.Profile {
		{name = "far", latency = 150_000, jitter = 10_000},
		{name = "far-lossy", latency = 140_000, jitter = 10_000, loss = 20},
		netcode.PROFILES[2], // bad: 120 ± 40 ms each way, loss, reordering
	}
	for profile in profiles {
		for seed in u64(1) ..= 4 {
			cfg := headless.Session_Config {
				clients     = 2,
				transport   = "loopback",
				virtual     = true,
				profile     = profile,
				ticks       = 192,
				seed        = seed,
				late_player = -1,
			}
			result := headless.session_run(&HEADLESS, cfg)
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
