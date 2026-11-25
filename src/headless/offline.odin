// Offline runs, generic over the game: scripted runs, sync-test, replay, snapshot/resume, all in
// memory (the CLI, unified:headless/modes, does the file I/O).
package headless

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
@(require) import "core:slice" // only in generic procs
import "core:strings"

import "unified:sim"

// The longest rollback window a game's ring allows (sim.ring_size(tick_hz) - 1).
max_window :: proc(game: ^$G) -> int {
	return sim.ring_size(game.tick_hz) - 1
}

// The deepest rollback the netcode makes: its prediction cap, sim.ring_size(tick_hz) - 2 (14 ticks at 64 Hz).
prediction_window :: proc(game: ^$G) -> int {
	return sim.ring_size(game.tick_hz) - 2
}

// A run's checksums, one per tick from `first` on: sums[i] is the checksum after tick first + i.
// On disk (`--trace`): one "%06d %016x" line per tick, in order.
Trace :: struct {
	first: u32,
	sums:  [dynamic]u64,
}

// Appends the checksum of `tick`, which must follow the last one added (the first sets `first`).
trace_add :: proc(trace: ^Trace, tick: u32, checksum: u64) {
	if len(trace.sums) == 0 {
		trace.first = tick
	}
	assert(tick == trace.first + u32(len(trace.sums)), "trace ticks must be consecutive")
	append(&trace.sums, checksum)
}

// Frees the trace's checksums and empties it.
trace_destroy :: proc(trace: ^Trace) {
	delete(trace.sums)
	trace^ = {}
}

// The checksum of a tick, if the trace has it.
trace_at :: proc(trace: ^Trace, tick: u32) -> (checksum: u64, ok: bool) {
	if tick < trace.first || tick - trace.first >= u32(len(trace.sums)) {
		return
	}
	return trace.sums[tick - trace.first], true
}

// Writes the trace as its on-disk text (`--trace`); false if the write failed.
trace_write :: proc(trace: ^Trace, path: string) -> bool {
	builder := strings.builder_make(0, len(trace.sums) * 24)
	defer strings.builder_destroy(&builder)
	for checksum, i in trace.sums {
		fmt.sbprintf(&builder, "%06d %016x\n", trace.first + u32(i), checksum)
	}
	return os.write_entire_file(path, builder.buf[:]) == nil
}

// Where an offline run ended: its last tick and that tick's checksum.
Run_Result :: struct {
	final_tick:     u32,
	final_checksum: u64,
	// A replay against the log's checkpoints (the recorder's checksums): how many it compared, the last tick that
	// agreed and the first that didn't (0: none). It replays to the end either way, so the trace is whole.
	checkpoints:    int,
	agreed_tick:    u32,
	diverged_tick:  u32,
	// Game.save over the run (every tick is verified offline, sim.save_changed): how many times its Setup changed,
	// and the newest one's bytes hashed (0: none), as a session's clients count theirs (netcode.Client_Result).
	saves:          u32,
	save_hash:      u64,
}

// A run's save after tick `tick` into its result (`saved`: the last one, the session's Setup before the first).
@(private)
run_save :: proc(
	simulation: ^sim.Sim($G),
	tick: u32,
	saved: ^$Setup,
	result: ^Run_Result,
) where Setup ==
	sim.part(G, sim.GAME_SETUP) {
	if sim.save_changed(simulation, tick, saved) {
		result.saves += 1
		result.save_hash = sim.hash_bytes(sim.bytes_of(saved))
	}
}

// A change of who holds a slot in a scripted run: from `tick` on, member `member` (the relay's id; 0: nobody).
Seat :: struct {
	tick:   u32,
	slot:   int,
	member: int,
}

// The script state of an offline run: who holds each slot (slot i is member i + 1 from tick 1, then `seats` change
// it) and the Profile each slot's join brings (run_seat's, else Game.scripted_profile's, else zero). A tick takes what
// each slot's script sends for it: at most sim.COMMANDS_PER_SLOT commands (a session's relay would hold the rest for
// the next ticks; an offline run asserts a script never sends more).
Scripted_Commands :: struct($G: typeid) {
	out:      sim.Command_Out(sim.part(G, sim.GAME_COMMAND)),
	seats:    []Seat, // borrowed
	holder:   [sim.MAX_PLAYERS]int, // the member in each slot (0: nobody)
	seated:   bool, // holder is set
	profiled: sim.Slots, // slots whose Profile run_seat gave
	profile:  [sim.MAX_PLAYERS]sim.part(G, sim.GAME_PROFILE),
}

// The Profile the join of whoever is seated in `slot` brings: run_seat's, else the game's scripted one, else zero.
@(private)
scripted_profile :: proc(
	game: ^$G,
	seed: u64,
	slot: int,
	commands: ^Scripted_Commands(G),
) -> sim.part(G, sim.GAME_PROFILE) {
	if slot in commands.profiled do return commands.profile[slot]
	return game.scripted_profile(seed, slot) if game.scripted_profile != nil else {}
}

// Frees the output list of an offline run's scripted commands.
scripted_commands_destroy :: proc(commands: ^Scripted_Commands($G)) {
	delete(commands.out.list)
}

// Scripted inputs and commands of a tick, on the run's Setup (simulation.setup): slots < `players` present (slot i is
// member i + 1), then as `commands.seats` say. A slot whose member the sim doesn't have there yet gets its join record.
scripted :: proc(
	game: ^$G,
	simulation: ^sim.Sim(G),
	tick: u32,
	players: int,
	commands: ^Scripted_Commands(G),
) -> (
	inputs: sim.Inputs(G),
) {
	return scripted_given(game, simulation, tick, players, commands, &simulation.state)
}

// scripted with the script handed `state` (scripted: the simulation's current one).
@(private)
scripted_given :: proc(
	game: ^$G,
	simulation: ^sim.Sim(G),
	tick: u32,
	players: int,
	commands: ^Scripted_Commands(G),
	state: ^$State,
) -> (
	inputs: sim.Inputs(G),
) {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	if !commands.seated {
		for slot in 0 ..< players do commands.holder[slot] = slot + 1
		commands.seated = true
	}
	for seat in commands.seats {
		if seat.tick == tick && seat.slot >= 0 && seat.slot < PLAYERS {
			commands.holder[seat.slot] = seat.member
		}
	}
	for slot in 0 ..< PLAYERS {
		member := commands.holder[slot]
		if member == 0 {
			sim.unseat(simulation, slot) // whoever held it leaves now
			continue
		}
		sim.seat(&inputs, simulation, slot, member, scripted_profile(game, simulation.seed, slot, commands))
		// No scripted player: one who sends zero Inputs (as the Godot driver plays it).
		inputs.input[slot] = sim.scripted_player_input(game, simulation.seed, slot, tick, state, simulation.setup)
		if game.scripted_commands == nil {
			continue
		}
		out := &commands.out
		out.slot = slot
		out.cap = sim.COMMANDS_PER_SLOT + 1 // one more than fits: a script that sends it is caught below
		clear(&out.list)
		game.scripted_commands(simulation.seed, slot, tick, state, simulation.setup, out)
		fmt.assertf(
			len(out.list) <= sim.COMMANDS_PER_SLOT,
			"%s's script sends slot %d more than %d commands at tick %d: a tick takes at most that many",
			game.name,
			slot,
			sim.COMMANDS_PER_SLOT,
			tick,
		)
		for command in out.list {
			fmt.assertf(sim.add_command(&inputs, command), "tick %d's scripted commands do not fit a tick", tick)
		}
	}
	return
}

// `sim`: scripted run for `ticks` ticks, on the game's default Setup or `setup`; records every tick's checksum into
// `trace` and its inputs into `input_log` (each optional).
run_sim :: proc {
	run_sim_default,
	run_sim_with_setup,
}

// run_sim with the game's default Setup (Game.setup).
run_sim_default :: proc(
	game: ^$G,
	ticks: u32,
	seed: u64,
	players: int,
	trace: ^Trace = nil,
	input_log: ^sim.Input_Log(G) = nil,
) -> Run_Result {
	return run_sim_with_setup(game, ticks, seed, players, game.setup, trace, input_log)
}

// run_sim with this Setup.
run_sim_with_setup :: proc(
	game: ^$G,
	ticks: u32,
	seed: u64,
	players: int,
	setup: $S,
	trace: ^Trace = nil,
	input_log: ^sim.Input_Log(G) = nil,
) -> (
	result: Run_Result,
) where S ==
	sim.part(G, sim.GAME_SETUP) {
	simulation := sim.create(game, seed, setup)
	defer sim.destroy(simulation)
	commands: Scripted_Commands(G)
	defer scripted_commands_destroy(&commands)
	if input_log != nil {
		input_log.seed = seed
		input_log.setup = simulation.setup
		input_log.content = simulation.content_hash
		input_log.compat = sim.compat_of(game)
	}
	saved := simulation.setup
	for tick in 1 ..= ticks {
		inputs := scripted(game, simulation, tick, players, &commands)
		if input_log != nil {
			sim.log_append(input_log, &inputs)
		}
		sim.step(simulation, &inputs)
		run_save(simulation, tick, &saved, &result)
		result.final_checksum = sim.checksum(simulation)
		if trace != nil {
			trace_add(trace, tick, result.final_checksum)
		}
		if input_log != nil && tick % sim.DEEP_CHECKSUM_EVERY == 0 {
			sim.log_checkpoint(input_log, tick, result.final_checksum) // the ticks peers compare
		}
	}
	result.final_tick = ticks
	return
}

// What run_interleaved found: how many of the second run's ticks differ from the first's, and the first one that does.
Interleaved_Result :: struct {
	mismatches:     int,
	second_start:   u32, // the first run's tick at which the second sim was created
	first_tick:     u32, // the first tick the second run computed differently (0: none)
	first, second:  u64, // the two checksums at first_tick
	final_checksum: u64,
}

// Two sims of one run alive in one process at once (cold vs warm): the first runs the scripted
// run; at its halfway tick a second sim is created (the first is warm) and replays the first's inputs one
// tick per tick of the first, half a run behind; the first is destroyed and the second runs the rest
// alone. Every tick of the second is compared with the first's. Catches state that instances share (a
// global, a library's static, reset or shared at world creation), which two back-to-back runs miss. Both sims play the
// game's default Setup or `setup`.
run_interleaved :: proc {
	run_interleaved_default,
	run_interleaved_with_setup,
}

// run_interleaved with the game's default Setup (Game.setup).
run_interleaved_default :: proc(game: ^$G, ticks: u32, seed: u64, players: int) -> Interleaved_Result {
	return run_interleaved_with_setup(game, ticks, seed, players, game.setup)
}

// run_interleaved with this Setup.
run_interleaved_with_setup :: proc(
	game: ^$G,
	ticks: u32,
	seed: u64,
	players: int,
	setup: $S,
) -> (
	result: Interleaved_Result,
) where S ==
	sim.part(G, sim.GAME_SETUP) {
	first := sim.create(game, seed, setup)
	commands: Scripted_Commands(G)
	defer scripted_commands_destroy(&commands)
	input_log: sim.Input_Log(G)
	defer sim.log_destroy(&input_log)
	forward := make([]u64, ticks + 1)
	defer delete(forward)
	second: ^sim.Sim(G)
	result.second_start = max(ticks / 2, 1)
	for tick in 1 ..= ticks {
		inputs := scripted(game, first, tick, players, &commands)
		sim.log_append(&input_log, &inputs)
		sim.step(first, &inputs)
		forward[tick] = sim.checksum(first)
		if tick == result.second_start {
			second = sim.create(game, seed, setup)
		}
		if second != nil {
			interleaved_step(second, &input_log, forward, &result)
		}
	}
	sim.destroy(first)
	if second != nil {
		for second.tick < ticks {
			interleaved_step(second, &input_log, forward, &result)
		}
		sim.destroy(second)
	}
	result.final_checksum = forward[ticks] if ticks > 0 else 0
	return
}

// The second sim's next tick, from the log, compared with the first run's checksum of it.
@(private)
interleaved_step :: proc(
	second: ^sim.Sim($G),
	input_log: ^sim.Input_Log(G),
	forward: []u64,
	result: ^Interleaved_Result,
) {
	inputs := sim.log_inputs(input_log, int(second.tick))
	sim.step(second, &inputs)
	if got := sim.checksum(second); got != forward[second.tick] {
		if result.mismatches == 0 {
			result.first_tick, result.first, result.second = second.tick, forward[second.tick], got
		}
		result.mismatches += 1
	}
}

// What a sync-tested run found (run_synctest, Run): a run passes with no mismatch, `check` and `problem` empty.
Synctest_Result :: struct {
	mismatches:     int,
	resimulated:    int, // ticks re-simulated
	final_checksum: u64, // the last forward tick's
	first_tick:     u32, // the first mismatching tick (0: none)
	first_at:       u32, // the tick whose rollback re-simulated it differently
	check:          string, // the first problem sim.block_violation or sim.check_extra found after a restore ("": none; temp-allocated)
	check_tick:     u32, // the tick it was restored to
	// The first other problem ("": none; temp-allocated): a NaN in the state block after a forward tick (sim.find_nan),
	// or a re-simulated tick that emitted other events than the first run (counted in `mismatches` too).
	problem:        string,
	events:         [256]int, // what the forward ticks emitted, by event kind (run_events)
}

// A sync-tested run its caller steps: each step is a forward tick and a NaN scan of its block (sim.find_nan), then a
// restore `window` ticks back (never before a pinned tick), the block's and the extra's checks (sim.block_violation,
// sim.check_extra) and a re-simulation with the recorded inputs, each tick's checksum and events compared with the forward one's. A Dev is attached (a
// dev build): the forward ticks keep no draw group and the re-simulations every one, so state that depends on
// sim.drawing (or anything a draw does) shows as a mismatch, as a dev UI showing draws would desync. A game test drives it
// with the game's scripted player (run_scripted) or its own inputs (run_inputs, then run_step), seats and unseats
// members (run_seat), changes the state between steps (run_pin) and asserts `mismatches == 0`, `check == ""`,
// `problem == ""` (scenarios.expect_synced) and its own facts. `simulation` is at the newest tick between steps.
//
//   run := headless.run_begin(&GAME, seed, seated = 2) // slots 0, 1: members 1, 2, present after one step
//   defer headless.run_end(&run)
//   for _ in 1 ..= 600 do headless.run_scripted(&run, 2)
//
//   headless.run_seat(&run, 2, 7)        // member 7 holds slot 2 from the next step on (0: nobody)
//   headless.run_seat(&run, 2, 7, Profile{character = .Runner}) // ... joining with that Profile
//   inputs := headless.run_inputs(&run)  // the seated members present, join records where needed (sim.seat)
//   inputs.input[0] = input
//   sim.add_command(&inputs, 0, command) // a Command_X value, or the game's Command union
//   headless.run_step(&run, &inputs)
//   ship := sim.slot_data(run.simulation, 0)
//   headless.run_pin(&run)               // the test changed the state: never restore before this tick
//   scenarios.expect_synced(t, &run)     // every re-simulation agreed: no mismatch, check or problem
Run :: struct($G: typeid) {
	using result: Synctest_Result,
	simulation:   ^sim.Sim(G),
	window:       u32,
	start:        u32, // the tick it began at: 0, or its snapshot's (run_begin_from_snapshot)
	recorded:     [dynamic]sim.Inputs(G), // recorded[tick - start]: the inputs of that tick
	forward:      [dynamic]u64, // forward[tick - start]: its checksum
	floor:        u32, // never restored before (run_pin; the start)
	commands:     Scripted_Commands(G), // who holds each slot (run_seat, run_scripted) and run_scripted's commands
	kept_events:  [sim.MAX_RING_SIZE][dynamic]sim.Raw_Event, // each forward tick's events, by tick % MAX_RING_SIZE
	floats:       [dynamic]u32, // the State's float offsets (sim.find_nan)
	// run_scripted asks the script again with the state `window` ticks back and sets `problem` when it answers
	// otherwise (sim.Game.scripted_input). Off unless set: the standard scenarios set it (run_synctest's `script_check`).
	script_check: bool,
}

// A run of `game` from tick 0, on its levels, with its default Setup or `setup`, sync-tested `window` ticks back
// (1 ..= max_window(game)). `seated`: slots 0 ..< seated are seated (run_seat: slot i is member i + 1) and play one
// step with zero inputs, so their players are present at tick 1; 0: nobody is seated yet, no step.
//
//   run := headless.run_begin(&g.GAME, 1, setup = g.Setup{difficulty = .Hard}, seated = 2)
run_begin :: proc {
	run_begin_default,
	run_begin_with_setup,
}

// run_begin with the game's default Setup.
run_begin_default :: proc(game: ^$G, seed: u64, window: u32 = 8, seated := 0) -> Run(G) {
	return run_begin_with_setup(game, seed, game.setup, window, seated)
}

// run_begin with this Setup.
run_begin_with_setup :: proc(
	game: ^$G,
	seed: u64,
	setup: $S,
	window: u32 = 8,
	seated := 0,
) -> (
	run: Run(G),
) where S ==
	sim.part(G, sim.GAME_SETUP) {
	assert(window >= 1 && int(window) <= max_window(game))
	assert(seated >= 0 && seated <= sim.part(G, sim.GAME_PLAYERS), "seated: 0 to the game's player count")
	run.simulation = sim.create(game, seed, setup)
	sim.dev_attach(run.simulation) // draws on in the re-simulations only (run_step)
	run.window = window
	append(&run.recorded, sim.Inputs(G){})
	append(&run.forward, sim.checksum(run.simulation))
	if seated > 0 {
		for slot in 0 ..< seated do run_seat(&run, slot, slot + 1)
		inputs := run_inputs(&run)
		run_step(&run, &inputs)
	}
	return
}

// A run that continues `snapshot` (sim.from_snapshot: its tick, Setup and seed; `any_build` loads one another build
// wrote), sync-tested `window` ticks back (1 ..= max_window(game)) as run_begin's, never restored before the snapshot's
// tick: the first step already rolls back to it. Nobody is seated (run_seat): a test steps it with the inputs it has
// (run_step), as a recording that continues a snapshot is replayed (regression_run). On an error the run is empty:
// nothing to end.
run_begin_from_snapshot :: proc(
	game: ^$G,
	snapshot: []u8,
	window: u32 = 8,
	any_build := false,
) -> (
	run: Run(G),
	err: sim.Snap_Error,
) {
	assert(window >= 1 && int(window) <= max_window(game))
	simulation := sim.from_snapshot(game, snapshot, any_build = any_build) or_return
	run.simulation = simulation
	sim.dev_attach(simulation) // draws on in the re-simulations only (run_step)
	run.window = window
	run.start, run.floor = simulation.tick, simulation.tick
	append(&run.recorded, sim.Inputs(G){})
	append(&run.forward, sim.checksum(simulation))
	return
}

// Frees the run's sim and records.
run_end :: proc(run: ^Run($G)) {
	sim.destroy(run.simulation)
	delete(run.recorded)
	delete(run.forward)
	scripted_commands_destroy(&run.commands)
	for &events in run.kept_events do delete(events)
	delete(run.floats)
}

// One forward tick, then its sync-test: with `inputs` (run_inputs, filled by the test), with the seated members
// present (run_inputs) playing `input` by slot, or with no input:
//
//   headless.run_step(&run, inputs_by_slot)  // [PLAYERS]Input
//   headless.run_step(&run)                  // the seated present, zero input
//
// run_command steps with a slot's command.
run_step :: proc {
	run_step_inputs,
	run_step_by_slot,
	run_step_seated,
}

// run_step with the seated members present playing `input` by slot.
run_step_by_slot :: proc(
	run: ^Run($G),
	input: [$N]$I,
) where N == sim.part(G, sim.GAME_PLAYERS) &&
	I == sim.part(G, sim.GAME_INPUT) {
	inputs := run_inputs(run)
	inputs.input = input
	run_step_inputs(run, &inputs)
}

// run_step with the seated members present and zero input.
run_step_seated :: proc(run: ^Run($G)) {
	inputs := run_inputs(run)
	run_step_inputs(run, &inputs)
}

// One forward tick and its sync-test (run_step) in which `slot` sends `command` (a Command_X value, or the game's Command
// union; it must fit: asserted), the seated members present, with no input or playing `input` by slot:
//
//   headless.run_command(&run, 1, g.Command_Pick{choice = 2})
//   headless.run_command(&run, inputs_by_slot, 0, g.Command_Fire{})
run_command :: proc {
	run_command_seated,
	run_command_by_slot,
}

// run_command with no input.
run_command_seated :: proc(
	run: ^Run($G),
	slot: int,
	command: $C,
	loc := #caller_location,
) where C == sim.part(G, sim.GAME_COMMAND) ||
	intrinsics.type_is_variant_of(sim.part(G, sim.GAME_COMMAND), C) {
	inputs := run_inputs(run)
	sent := sim.add_command(&inputs, slot, command)
	assert(sent, "run_command: a command that doesn't fit the tick", loc)
	run_step_inputs(run, &inputs)
}

// run_command with the seated members playing `input` by slot.
run_command_by_slot :: proc(
	run: ^Run($G),
	input: [$N]$I,
	slot: int,
	command: $C,
	loc := #caller_location,
) where N == sim.part(G, sim.GAME_PLAYERS) &&
	I == sim.part(G, sim.GAME_INPUT) &&
	(C == sim.part(G, sim.GAME_COMMAND) || intrinsics.type_is_variant_of(sim.part(G, sim.GAME_COMMAND), C)) {
	inputs := run_inputs(run)
	inputs.input = input
	sent := sim.add_command(&inputs, slot, command)
	assert(sent, "run_command: a command that doesn't fit the tick", loc)
	run_step_inputs(run, &inputs)
}

// run_step with these inputs.
run_step_inputs :: proc(run: ^Run($G), inputs: ^sim.Inputs(G)) {
	simulation := run.simulation
	append(&run.recorded, inputs^)
	sim.dev_enable(simulation, 0)
	sim.step(simulation, inputs)
	tick := simulation.tick
	append(&run.forward, sim.checksum(simulation))
	run.final_checksum = run.forward[tick - run.start]
	kept := &run.kept_events[tick % sim.MAX_RING_SIZE]
	clear(kept)
	for event in sim.events_at(simulation, tick) {
		run.events[event.kind] += 1
		append(kept, event)
	}
	if run.problem == "" do run.problem = sim.find_nan(simulation, &run.floats)
	if tick < run.window do return
	from := max(tick - run.window, run.floor)
	if from == tick do return
	if !sim.restore(simulation, from) {
		if run.mismatches == 0 {
			run.first_tick, run.first_at = from, tick
		}
		run.mismatches += 1
		return
	}
	if run.check == "" {
		reason := sim.block_violation(&simulation.state)
		if reason == "" do reason = sim.check_extra(simulation)
		if reason != "" do run.check, run.check_tick = reason, from
	}
	sim.dev_enable(simulation, max(u64))
	defer sim.dev_enable(simulation, 0)
	for resim in from + 1 ..= tick {
		sim.step(simulation, &run.recorded[resim - run.start])
		run.resimulated += 1
		events := sim.events_diff(
			sim.events_at(simulation, resim),
			run.kept_events[resim % sim.MAX_RING_SIZE][:],
			sim.part(G, sim.GAME_EVENT),
		)
		if events != "" && run.problem == "" {
			run.problem = fmt.tprintf("tick %d re-simulated at tick %d emitted other events: %s", resim, tick, events)
		}
		if sim.checksum(simulation) != run.forward[resim - run.start] || events != "" {
			if run.mismatches == 0 {
				run.first_tick, run.first_at = resim, tick
			}
			run.mismatches += 1
		}
	}
}

// `member` (the relay's id; 0: nobody) holds `slot` from the next step on: run_inputs makes it present, with its join
// record when someone else holds it, bringing `profile` when given (else Game.scripted_profile's, else zero);
// run_scripted plays it.
run_seat :: proc {
	run_seat_plain,
	run_seat_with_profile,
}

// run_seat with the game's scripted Profile (or zero).
run_seat_plain :: proc(run: ^Run($G), slot: int, member: int) {
	assert(slot >= 0 && slot < sim.part(G, sim.GAME_PLAYERS) && member >= 0 && member <= 0xFFFF)
	run.commands.holder[slot] = member
	run.commands.seated = true
	run.commands.profiled -= {slot}
}

// run_seat with this Profile.
run_seat_with_profile :: proc(
	run: ^Run($G),
	slot: int,
	member: int,
	profile: $P,
) where P ==
	sim.part(G, sim.GAME_PROFILE) {
	run_seat_plain(run, slot, member)
	run.commands.profiled += {slot}
	run.commands.profile[slot] = profile
}

// The next step's inputs for a test to fill (input, commands): every seated member present (run_seat), with a join
// record where the sim has someone else in that slot (sim.seat).
run_inputs :: proc(run: ^Run($G)) -> (inputs: sim.Inputs(G)) {
	simulation := run.simulation
	for slot in 0 ..< sim.part(G, sim.GAME_PLAYERS) {
		member := run.commands.holder[slot]
		if member == 0 {
			sim.unseat(simulation, slot) // whoever held it leaves now
			continue
		}
		sim.seat(
			&inputs,
			simulation,
			slot,
			member,
			scripted_profile(simulation.game, simulation.seed, slot, &run.commands),
		)
	}
	return
}

// One forward tick played by the game's scripted player, then its sync-test: unless someone was seated already
// (run_seat, an earlier call), slots < `players` present (slot i is member i + 1); then as `seats` say (taken on the
// first call), as run_sim plays. With `script_check`, the script is asked again with the state `window` ticks back
// (when the ring has it): a different input or command sets `problem`, as a session's clients would each hand it
// their own prediction and play another player than an offline run (sim.Game.scripted_input).
run_scripted :: proc(run: ^Run($G), players: int, seats: []Seat = nil) {
	if run.commands.seats == nil do run.commands.seats = seats
	simulation := run.simulation
	tick := simulation.tick + 1
	inputs := scripted(simulation.game, simulation, tick, players, &run.commands)
	older_tick := simulation.tick - min(simulation.tick, run.window)
	if older := sim.state_at(simulation, older_tick);
	   run.script_check && run.problem == "" && older_tick < simulation.tick && older != nil {
		again := scripted_given(simulation.game, simulation, tick, players, &run.commands, older)
		if !script_inputs_same(&inputs, &again) {
			run.problem = fmt.tprintf(
				"%s's scripted player reads the state: for tick %d it answered otherwise given tick %d's state than tick %d's (a session's clients hand it their own predictions: a session would play another player than an offline run; sim.Game.scripted_input)",
				simulation.game.name,
				tick,
				older_tick,
				simulation.tick,
			)
		}
	}
	run_step(run, &inputs)
}

// Whether two ticks' scripted inputs hold the same Inputs and commands (their presence is the harness's, alike).
@(private)
script_inputs_same :: proc(a, b: ^sim.Inputs($G)) -> bool {
	if a.command_count != b.command_count do return false
	if !bytes_same(&a.input, &b.input, size_of(a.input)) do return false
	return bytes_same(&a.commands, &b.commands, a.command_count * size_of(a.commands[0]))
}

// Whether `size` bytes at `a` and `b` are the same (a non-generic home for its import: -vet).
@(private)
bytes_same :: proc(a, b: rawptr, size: int) -> bool {
	return runtime.memory_compare(a, b, size) == 0
}

// The test changed the state (or the World) at the current tick: save it again, and never restore before it.
run_pin :: proc(run: ^Run($G)) {
	simulation := run.simulation
	sim.save(simulation)
	run.forward[simulation.tick - run.start] = sim.checksum(simulation)
	run.floor = simulation.tick
}

// The last event of type E (a variant of the game's Event union) the newest tick emitted; found is false for none.
run_last_event :: proc(
	run: ^Run($G),
	$E: typeid,
) -> (
	event: E,
	found: bool,
) where intrinsics.type_is_variant_of(sim.part(G, sim.GAME_EVENT), E) {
	for &raw in sim.events_at(run.simulation, run.simulation.tick) {
		if value, is := sim.event_value(&raw, sim.part(G, sim.GAME_EVENT)).(E); is do event, found = value, true
	}
	return
}

// How many events of type E (a variant of the game's Event union) the forward ticks emitted.
run_events :: proc(
	run: ^Run($G),
	$E: typeid,
) -> int where intrinsics.type_is_variant_of(sim.part(G, sim.GAME_EVENT), E) {
	return run.events[intrinsics.type_variant_index_of(sim.part(G, sim.GAME_EVENT), E)]
}

// `synctest`: run_scripted for `ticks` ticks, rolling back `window` ticks every tick (at most max_window(game), the
// ring's depth), on the game's default Setup or `setup`. `seats`: who comes and goes (Seat; none: slots < players all
// along). `script_check`: Run.script_check.
run_synctest :: proc {
	run_synctest_default,
	run_synctest_with_setup,
}

// run_synctest with the game's default Setup (Game.setup).
run_synctest_default :: proc(
	game: ^$G,
	ticks, window: u32,
	seed: u64,
	players: int,
	seats: []Seat = nil,
	script_check := false,
) -> Synctest_Result {
	return run_synctest_with_setup(game, ticks, window, seed, players, game.setup, seats, script_check)
}

// run_synctest with this Setup.
run_synctest_with_setup :: proc(
	game: ^$G,
	ticks, window: u32,
	seed: u64,
	players: int,
	setup: $S,
	seats: []Seat = nil,
	script_check := false,
) -> Synctest_Result where S ==
	sim.part(G, sim.GAME_SETUP) {
	run := run_begin_with_setup(game, seed, setup, window = window)
	run.script_check = script_check
	defer run_end(&run)
	for _ in 1 ..= ticks do run_scripted(&run, players, seats)
	return run.result
}

// `replay`: re-simulates an input log with the Setup it recorded, recording every tick's checksum into `trace`
// (optional). Fails when the log was recorded with other levels or by another build (its compat; 0: unknown, any).
run_replay :: proc(
	game: ^$G,
	input_log: ^sim.Input_Log(G),
	trace: ^Trace = nil,
	snapshot: []u8 = nil,
	any_build := false,
) -> (
	result: Run_Result,
	ok: bool,
) {
	if input_log.content != sim.content_hash(game.levels) {
		fmt.eprintfln(
			"replay: the log was recorded with other levels (content %016x, this run has %016x; see --level)",
			input_log.content,
			sim.content_hash(game.levels),
		)
		return
	}
	if compat := sim.compat_of(game); input_log.compat != 0 && input_log.compat != compat {
		if !any_build {
			fmt.eprintfln(
				"replay: the log was recorded by another build (compat %016x, this build is %016x; --any-build replays it against its checkpoints)",
				input_log.compat,
				compat,
			)
			return
		}
		fmt.eprintfln(
			"replay: recorded by another build (compat %016x): comparing %d checkpoints",
			input_log.compat,
			len(input_log.checkpoints),
		)
	}
	simulation: ^sim.Sim(G)
	if snapshot != nil {
		// the log starts after the snapshot's tick (a session recorded from a joiner's join: an F3 note)
		err: sim.Snap_Error
		simulation, err = sim.from_snapshot(game, snapshot, any_build = any_build)
		if err != .None {
			fmt.eprintfln("replay: the snapshot does not load: %v", err)
			return
		}
	} else {
		simulation = sim.create(game, input_log.seed, input_log.setup)
	}
	defer sim.destroy(simulation)
	if simulation.tick != input_log.from {
		fmt.eprintfln("replay: the log continues tick %d, the run starts at tick %d", input_log.from, simulation.tick)
		return
	}
	checkpoints := make([]sim.Checkpoint, len(input_log.checkpoints), context.temp_allocator)
	copy(checkpoints, input_log.checkpoints[:])
	slice.sort_by(checkpoints, proc(a, b: sim.Checkpoint) -> bool {return a.tick < b.tick})
	next := 0
	saved := simulation.setup
	for k in 0 ..< len(input_log.ticks) {
		inputs := sim.log_inputs(input_log, k)
		sim.step(simulation, &inputs)
		run_save(simulation, simulation.tick, &saved, &result)
		result.final_checksum = sim.checksum(simulation)
		if trace != nil {
			trace_add(trace, simulation.tick, result.final_checksum)
		}
		for next < len(checkpoints) && checkpoints[next].tick <= simulation.tick {
			checkpoint := checkpoints[next]
			next += 1
			if checkpoint.tick != simulation.tick do continue
			result.checkpoints += 1
			if checkpoint.checksum == result.final_checksum {
				if result.diverged_tick == 0 do result.agreed_tick = checkpoint.tick
			} else if result.diverged_tick == 0 {
				result.diverged_tick = checkpoint.tick
				fmt.eprintfln(
					"replay: first divergent checkpoint: tick %d (recorded %016x, replayed %016x); last agreeing: tick %d",
					checkpoint.tick,
					checkpoint.checksum,
					result.final_checksum,
					result.agreed_tick,
				)
			}
		}
	}
	result.final_tick = simulation.tick
	return result, result.diverged_tick == 0
}

// `snapshot`: scripted run to `ticks`, on the game's default Setup or `setup`, then a portable snapshot of that tick
// (the caller owns `data`). The snapshot carries the Setup, so run_resume continues on it.
run_snapshot :: proc {
	run_snapshot_default,
	run_snapshot_with_setup,
}

// run_snapshot with the game's default Setup (Game.setup).
run_snapshot_default :: proc(game: ^$G, ticks: u32, seed: u64, players: int) -> (data: []u8, checksum: u64) {
	return run_snapshot_with_setup(game, ticks, seed, players, game.setup)
}

// run_snapshot with this Setup.
run_snapshot_with_setup :: proc(
	game: ^$G,
	ticks: u32,
	seed: u64,
	players: int,
	setup: $S,
) -> (
	data: []u8,
	checksum: u64,
) where S ==
	sim.part(G, sim.GAME_SETUP) {
	simulation := sim.create(game, seed, setup)
	defer sim.destroy(simulation)
	commands: Scripted_Commands(G)
	defer scripted_commands_destroy(&commands)
	for tick in 1 ..= ticks {
		inputs := scripted(game, simulation, tick, players, &commands)
		sim.step(simulation, &inputs)
	}
	return sim.snapshot_encode(simulation, ticks), sim.checksum(simulation)
}

// `resume`: restores a portable snapshot and continues the scripted run for `ticks` ticks with
// `players` players present, recording every tick's checksum into `trace` (optional).
run_resume :: proc(
	game: ^$G,
	data: []u8,
	ticks: u32,
	players: int,
	trace: ^Trace = nil,
) -> (
	result: Run_Result,
	ok: bool,
) {
	simulation, snap_err := sim.from_snapshot(game, data)
	if snap_err != .None {
		fmt.eprintfln("resume: not a valid snapshot for this build: %v", snap_err)
		return
	}
	defer sim.destroy(simulation)
	commands: Scripted_Commands(G)
	defer scripted_commands_destroy(&commands)
	start := simulation.tick
	for tick in start + 1 ..= start + ticks {
		inputs := scripted(game, simulation, tick, players, &commands)
		sim.step(simulation, &inputs)
		result.final_checksum = sim.checksum(simulation)
		if trace != nil {
			trace_add(trace, tick, result.final_checksum)
		}
	}
	result.final_tick = start + ticks
	return result, true
}

// What `predict-stats` measures: the rollbacks a client `depth` ticks deep would have had over a recorded log, with
// the remote players' inputs guessed by repeating their last one and by the game's sim.Game.predict_input (the same
// count when it has none), summed over every slot as the observing client.
Prediction_Stats :: struct {
	ticks:         int,
	depth:         u32,
	repeat_last:   int,
	predict_input: int,
}

// Replays a log's inputs through the client's prediction rule, offline (no sim runs): a client verifying tick T
// predicted it from the newest tick it knew, T - depth, or the tick of its last rollback if later (a rollback predicts
// the ticks after it again). A tick whose guess differs from the final inputs in presence, in a remote input's bytes,
// or by a remote command (never predicted) costs one rollback, and the guesses after it start over from it.
prediction_stats :: proc(game: ^$G, input_log: ^sim.Input_Log(G), depth: u32) -> (stats: Prediction_Stats) {
	Input :: sim.part(G, sim.GAME_INPUT)
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	stats.ticks = len(input_log.ticks)
	stats.depth = depth
	guess :: proc(game: ^$G, last: $Input, ahead: u32, hooked: bool) -> Input {
		return hooked && game.predict_input != nil ? game.predict_input(last, ahead) : last
	}
	for observer in 0 ..< PLAYERS {
		for hooked in ([]bool{false, true}) {
			rolled_back := 0 // the tick (log index + 1) of the last rollback
			count := 0
			for k in 0 ..< len(input_log.ticks) {
				tick := k + 1
				final := &input_log.ticks[k]
				base := max(tick - int(depth), rolled_back)
				if observer not_in final.present || base < 1 {
					continue
				}
				known := &input_log.ticks[base - 1]
				wrong := final.present - {observer} != known.present - {observer}
				for slot in final.present - {observer} {
					predicted := guess(game, known.input[slot], u32(tick - base), hooked)
					actual := final.input[slot]
					wrong ||= transmute([size_of(Input)]u8)predicted != transmute([size_of(Input)]u8)actual
				}
				for command in sim.log_commands(input_log, k) {
					wrong ||= int(command.slot) != observer
				}
				if wrong {
					count += 1
					rolled_back = tick
				}
			}
			if hooked {
				stats.predict_input += count
			} else {
				stats.repeat_last += count
			}
		}
	}
	return
}
