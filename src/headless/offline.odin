// Offline runs, generic over the game: scripted runs, sync-test, replay, snapshot/resume, all in
// memory (the CLI, unified:headless/modes, does the file I/O).
package headless

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"

import "unified:sim"

// A game as the headless runs, the end-to-end suites and the CLI drive it.
Headless :: struct($G: typeid) where intrinsics.type_is_specialization_of(G, sim.Game) {
	game:          ^G, // its scripted player (Game.scripted_input, scripted_commands) plays the runs
	// `bench`: fill the state with `count` entities and hold that population (optional).
	bench_prepare: proc(state: ^sim.part(G, sim.GAME_STATE), world: ^sim.part(G, sim.GAME_WORLD), count: int),
	// The game's standard benchmark: what `bench` runs without arguments (`uni bench`).
	bench:         Bench,
	// The game's content (its level file, src/level/SPEC.md), e.g. embedded with #load; the CLI's
	// `--level FILE` replaces it.
	content:       []u8,
}

// A benchmark's setup: `entities` entities held (with bench_prepare), a `window`-tick rollback every tick, for
// `ticks` ticks. `what` says what it measures.
Bench :: struct {
	what:     string,
	entities: int,
	window:   int, // 0: prediction_window(game), the deepest rollback the netcode makes
	ticks:    int,
}

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

Run_Result :: struct {
	final_tick:     u32,
	final_checksum: u64,
}

// A change of who holds a slot in a scripted run: from `tick` on, member `member` (the relay's id; 0: nobody).
Seat :: struct {
	tick:   u32,
	slot:   int,
	member: int,
}

// The script state of an offline run: who holds each slot (slot i is member i + 1 from tick 1, then `seats` change
// it). A tick takes what each slot's script sends for it: at most sim.COMMANDS_PER_SLOT commands (a session's relay
// would hold the rest for the next ticks; an offline run asserts a script never sends more).
Scripted_Commands :: struct($G: typeid) {
	out:    sim.Command_Out(sim.part(G, sim.GAME_CMD)),
	seats:  []Seat, // borrowed
	holder: [sim.MAX_PLAYERS]int, // the member in each slot (0: nobody)
	seated: bool, // holder is set
}

// Frees the output list of an offline run's scripted commands.
scripted_commands_destroy :: proc(commands: ^Scripted_Commands($G)) {
	delete(commands.out.list)
}

// Scripted inputs and commands of a tick: slots < `players` present (slot i is member i + 1), then as
// `commands.seats` say. A slot whose member the sim doesn't have there yet gets its join record.
scripted :: proc(
	headless: ^Headless($G),
	simulation: ^sim.Sim(G),
	tick: u32,
	players: int,
	commands: ^Scripted_Commands(G),
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
			continue
		}
		inputs.present += {slot}
		if int(sim.player_in_slot(simulation, slot).id) != member {
			sim.join(&inputs, slot, member)
		}
		// No scripted player: one who sends zero Inputs (as the Godot driver plays it).
		if headless.game.scripted_input != nil {
			inputs.input[slot] = headless.game.scripted_input(simulation.seed, slot, tick, &simulation.state)
		}
		if headless.game.scripted_commands == nil {
			continue
		}
		out := &commands.out
		out.slot = slot
		out.cap = sim.COMMANDS_PER_SLOT + 1 // one more than fits: a script that sends it is caught below
		clear(&out.list)
		headless.game.scripted_commands(simulation.seed, slot, tick, &simulation.state, out)
		fmt.assertf(
			len(out.list) <= sim.COMMANDS_PER_SLOT,
			"%s's script sends slot %d more than %d commands at tick %d: a tick takes at most that many",
			headless.game.name,
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

// `sim`: scripted run for `ticks` ticks; records every tick's checksum into `trace` and its inputs into `input_log`
// (each optional).
run_sim :: proc(
	headless: ^Headless($G),
	ticks: u32,
	seed: u64,
	players: int,
	trace: ^Trace = nil,
	input_log: ^sim.Input_Log(G) = nil,
) -> (
	result: Run_Result,
) {
	simulation := sim.create(headless.game, seed, headless.content)
	defer sim.destroy(simulation)
	commands: Scripted_Commands(G)
	defer scripted_commands_destroy(&commands)
	if input_log != nil {
		input_log.seed = seed
		input_log.content = simulation.content_hash
		input_log.compat = sim.compat_of(headless.game, headless.content)
	}
	for tick in 1 ..= ticks {
		inputs := scripted(headless, simulation, tick, players, &commands)
		if input_log != nil {
			sim.log_append(input_log, &inputs)
		}
		sim.step(simulation, &inputs)
		result.final_checksum = sim.checksum(simulation)
		if trace != nil {
			trace_add(trace, tick, result.final_checksum)
		}
	}
	result.final_tick = ticks
	return
}

Interleaved_Result :: struct {
	mismatches:     int,
	second_start:   u32, // the first run's tick at which the second sim was created
	first_tick:     u32, // the first tick the second run computed differently (0: none)
	first, second:  u64, // the two checksums at first_tick
	final_checksum: u64,
}

// Two sims of one run alive in one process at once (#123, cold vs warm): the first runs the scripted
// run; at its halfway tick a second sim is created (the first is warm) and replays the first's inputs one
// tick per tick of the first, half a run behind; the first is destroyed and the second runs the rest
// alone. Every tick of the second is compared with the first's. Catches state that instances share (a
// global, a library's static, reset or shared at world creation), which two back-to-back runs miss.
run_interleaved :: proc(headless: ^Headless($G), ticks: u32, seed: u64, players: int) -> (result: Interleaved_Result) {
	first := sim.create(headless.game, seed, headless.content)
	commands: Scripted_Commands(G)
	defer scripted_commands_destroy(&commands)
	input_log: sim.Input_Log(G)
	defer sim.log_destroy(&input_log)
	forward := make([]u64, ticks + 1)
	defer delete(forward)
	second: ^sim.Sim(G)
	result.second_start = max(ticks / 2, 1)
	for tick in 1 ..= ticks {
		inputs := scripted(headless, first, tick, players, &commands)
		sim.log_append(&input_log, &inputs)
		sim.step(first, &inputs)
		forward[tick] = sim.checksum(first)
		if tick == result.second_start {
			second = sim.create(headless.game, seed, headless.content)
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

Synctest_Result :: struct {
	mismatches:     int,
	resimulated:    int, // ticks re-simulated
	final_checksum: u64, // the last forward tick's
	first_tick:     u32, // the first mismatching tick (0: none)
	first_at:       u32, // the tick whose rollback re-simulated it differently
	check:          string, // the first problem sim.check_extra found after a restore ("": none; temp-allocated)
	check_tick:     u32, // the tick it was restored to
	// The first other problem ("": none; temp-allocated): a NaN in the state block after a forward tick (sim.find_nan),
	// or a re-simulated tick that emitted other events than the first run (counted in `mismatches` too).
	problem:        string,
	events:         [256]int, // what the forward ticks emitted, by event kind (run_events)
}

// A sync-tested run its caller steps: each step is a forward tick and a NaN scan of its block (sim.find_nan), then a
// restore `window` ticks back (never before a pinned tick), the extra's check (sim.check_extra) and a re-simulation
// with the recorded inputs, each tick's checksum and events compared with the forward one's. A game test drives it
// with its own inputs (run_step) or the game's scripted player (run_scripted), changes the state between steps
// (run_pin) and asserts `mismatches == 0`, `check == ""`, `problem == ""` and its own facts. `simulation` is at the newest tick between steps.
//
//   run := headless.run_begin(&g.GAME, seed, LEVEL)
//   defer headless.run_end(&run)
//   for _ in 1 ..= 600 do headless.run_scripted(&run, 4)
Run :: struct($G: typeid) {
	using result: Synctest_Result,
	simulation:   ^sim.Sim(G),
	window:       u32,
	recorded:     [dynamic]sim.Inputs(G), // recorded[tick]: the inputs of that tick
	forward:      [dynamic]u64, // forward[tick]: its checksum
	floor:        u32, // never restored before (run_pin)
	commands:     Scripted_Commands(G), // run_scripted's
	kept_events:  [sim.MAX_RING_SIZE][dynamic]sim.Raw_Event, // each forward tick's events, by tick % MAX_RING_SIZE
	floats:       [dynamic]u32, // the State's float offsets (sim.find_nan)
}

// A run of `game` from tick 0, sync-tested `window` ticks back (1 ..= max_window(game)).
run_begin :: proc(game: ^$G, seed: u64, content: []u8 = nil, window: u32 = 8) -> (run: Run(G)) {
	assert(window >= 1 && int(window) <= max_window(game))
	run.simulation = sim.create(game, seed, content)
	run.window = window
	append(&run.recorded, sim.Inputs(G){})
	append(&run.forward, sim.checksum(run.simulation))
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

// One forward tick with `inputs`, then its sync-test.
run_step :: proc(run: ^Run($G), inputs: ^sim.Inputs(G)) {
	simulation := run.simulation
	append(&run.recorded, inputs^)
	sim.step(simulation, inputs)
	tick := simulation.tick
	append(&run.forward, sim.checksum(simulation))
	run.final_checksum = run.forward[tick]
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
	if reason := sim.check_extra(simulation); reason != "" && run.check == "" {
		run.check, run.check_tick = reason, from
	}
	for resim in from + 1 ..= tick {
		sim.step(simulation, &run.recorded[resim])
		run.resimulated += 1
		events := sim.events_diff(
			sim.events_at(simulation, resim),
			run.kept_events[resim % sim.MAX_RING_SIZE][:],
			sim.part(G, sim.GAME_EVENT),
		)
		if events != "" && run.problem == "" {
			run.problem = fmt.tprintf("tick %d re-simulated at tick %d emitted other events: %s", resim, tick, events)
		}
		if sim.checksum(simulation) != run.forward[resim] || events != "" {
			if run.mismatches == 0 {
				run.first_tick, run.first_at = resim, tick
			}
			run.mismatches += 1
		}
	}
}

// One forward tick played by the game's scripted player, then its sync-test: slots < `players` present (slot i is
// member i + 1), then as `seats` say (taken on the first call), as run_sim plays.
run_scripted :: proc(run: ^Run($G), players: int, seats: []Seat = nil) {
	if !run.commands.seated do run.commands.seats = seats
	runs := Headless(G) {
		game    = run.simulation.game,
		content = run.simulation.content,
	}
	inputs := scripted(&runs, run.simulation, run.simulation.tick + 1, players, &run.commands)
	run_step(run, &inputs)
}

// The test changed the state (or the World) at the current tick: save it again, and never restore before it.
run_pin :: proc(run: ^Run($G)) {
	simulation := run.simulation
	sim.save(simulation)
	run.forward[simulation.tick] = sim.checksum(simulation)
	run.floor = simulation.tick
}

// How many events of type E (a variant of the game's Event union) the forward ticks emitted.
run_events :: proc(
	run: ^Run($G),
	$E: typeid,
) -> int where intrinsics.type_is_variant_of(sim.part(G, sim.GAME_EVENT), E) {
	return run.events[intrinsics.type_variant_index_of(sim.part(G, sim.GAME_EVENT), E)]
}

// `synctest`: run_scripted for `ticks` ticks, rolling back `window` ticks every tick (at most max_window(game), the
// ring's depth). `seats`: who comes and goes (Seat; none: slots < players all along).
run_synctest :: proc(
	headless: ^Headless($G),
	ticks, window: u32,
	seed: u64,
	players: int,
	seats: []Seat = nil,
) -> Synctest_Result {
	run := run_begin(headless.game, seed, headless.content, window)
	defer run_end(&run)
	for _ in 1 ..= ticks do run_scripted(&run, players, seats)
	return run.result
}

// `replay`: re-simulates an input log, recording every tick's checksum into `trace` (optional). Fails
// when the log was recorded with other content (another level) or by another build (its compat; 0: unknown, any).
run_replay :: proc(
	headless: ^Headless($G),
	input_log: ^sim.Input_Log(G),
	trace: ^Trace = nil,
	snapshot: []u8 = nil,
) -> (
	result: Run_Result,
	ok: bool,
) {
	if input_log.content != sim.content_hash(headless.content) {
		fmt.eprintfln(
			"replay: the log was recorded with another level (content %016x, this run has %016x; see --level)",
			input_log.content,
			sim.content_hash(headless.content),
		)
		return
	}
	if compat := sim.compat_of(headless.game, headless.content); input_log.compat != 0 && input_log.compat != compat {
		fmt.eprintfln(
			"replay: the log was recorded by another build (compat %016x, this build is %016x)",
			input_log.compat,
			compat,
		)
		return
	}
	simulation: ^sim.Sim(G)
	if snapshot != nil {
		// the log starts after the snapshot's tick (a session recorded from a joiner's join: an F3 note)
		err: sim.Snap_Error
		simulation, err = sim.from_snapshot(headless.game, snapshot, headless.content)
		if err != .None {
			fmt.eprintfln("replay: the snapshot does not load: %v", err)
			return
		}
	} else {
		simulation = sim.create(headless.game, input_log.seed, headless.content)
	}
	defer sim.destroy(simulation)
	for k in 0 ..< len(input_log.ticks) {
		inputs := sim.log_inputs(input_log, k)
		sim.step(simulation, &inputs)
		result.final_checksum = sim.checksum(simulation)
		if trace != nil {
			trace_add(trace, simulation.tick, result.final_checksum)
		}
	}
	result.final_tick = simulation.tick
	return result, true
}

// `snapshot`: scripted run to `ticks`, then a portable snapshot of that tick (the caller owns `data`).
run_snapshot :: proc(headless: ^Headless($G), ticks: u32, seed: u64, players: int) -> (data: []u8, checksum: u64) {
	simulation := sim.create(headless.game, seed, headless.content)
	defer sim.destroy(simulation)
	commands: Scripted_Commands(G)
	defer scripted_commands_destroy(&commands)
	for tick in 1 ..= ticks {
		inputs := scripted(headless, simulation, tick, players, &commands)
		sim.step(simulation, &inputs)
	}
	return sim.snapshot_encode(simulation, ticks), sim.checksum(simulation)
}

// `resume`: restores a portable snapshot and continues the scripted run for `ticks` ticks with
// `players` players present, recording every tick's checksum into `trace` (optional).
run_resume :: proc(
	headless: ^Headless($G),
	data: []u8,
	ticks: u32,
	players: int,
	trace: ^Trace = nil,
) -> (
	result: Run_Result,
	ok: bool,
) {
	simulation, snap_err := sim.from_snapshot(headless.game, data, headless.content)
	if snap_err != .None {
		fmt.eprintfln("resume: not a valid snapshot for this build: %v", snap_err)
		return
	}
	defer sim.destroy(simulation)
	commands: Scripted_Commands(G)
	defer scripted_commands_destroy(&commands)
	start := simulation.tick
	for tick in start + 1 ..= start + ticks {
		inputs := scripted(headless, simulation, tick, players, &commands)
		sim.step(simulation, &inputs)
		result.final_checksum = sim.checksum(simulation)
		if trace != nil {
			trace_add(trace, tick, result.final_checksum)
		}
	}
	result.final_tick = start + ticks
	return result, true
}
