// Offline runs, generic over the game: scripted runs, sync-test, replay, snapshot/resume, all in
// memory (the CLI, unified:headless/modes, does the file I/O).
package headless

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

@(require) import "unified:netcode" // only in generic procs
import "unified:sim"

// A game as the headless runs, the end-to-end suites and the CLI drive it.
Headless :: struct($State, $Input, $World: typeid, $PLAYERS: int) {
	game:              ^sim.Game(State, Input, World, PLAYERS),
	// Scripted input of `player` for a tick; `state` is the caller's current state (nil if none).
	scripted_input:    proc(seed: u64, player: int, tick: u32, state: ^State) -> Input,
	// Optional: the scripted commands of `player` for a tick (sim.send_command(out, command)); called right
	// after `scripted_input` for the same tick, in offline runs and by every client of a session.
	scripted_commands: proc(seed: u64, player: int, tick: u32, state: ^State, out: ^sim.Command_Out),
	// JSON fields describing a state, for the `sim` output (optional; temp-allocated).
	summary:           proc(state: ^State) -> string,
	// `bench`: fill the state with `count` entities and hold that population (optional).
	bench_prepare:     proc(state: ^State, world: ^World, count: int),
	// `bench`: the current entity count, for enemies_mean (optional).
	bench_count:       proc(state: ^State) -> int,
	// The game's standard benchmark: what `bench` runs without arguments (`uni bench`).
	bench:             Bench,
	// The game's content (its level file, src/level/SPEC.md), e.g. embedded with #load; the CLI's
	// `--level FILE` replaces it.
	content:           []u8,
}

// A benchmark's setup: `enemies` entities held (with bench_prepare), a `window`-tick rollback every tick, for
// `ticks` ticks. `what` says what it measures.
Bench :: struct {
	what:    string,
	enemies: int,
	window:  int,
	ticks:   int,
}

// The longest rollback window a game's ring allows (sim.ring_size(tick_hz) - 1).
max_window :: proc(game: ^sim.Game($State, $Input, $World, $PLAYERS)) -> int {
	return sim.ring_size(game.tick_hz) - 1
}

// A run's checksums, one per tick from `first` on: sums[i] is the checksum after tick first + i.
// On disk (`--trace`, a reference run's ref.trace): one "%06d %016x" line per tick, in order.
Trace :: struct {
	first: u32,
	sums:  [dynamic]u64,
}

trace_add :: proc(trace: ^Trace, tick: u32, checksum: u64) {
	if len(trace.sums) == 0 {
		trace.first = tick
	}
	assert(tick == trace.first + u32(len(trace.sums)), "trace ticks must be consecutive")
	append(&trace.sums, checksum)
}

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

trace_write :: proc(trace: ^Trace, path: string) -> bool {
	builder := strings.builder_make(0, len(trace.sums) * 24)
	defer strings.builder_destroy(&builder)
	for checksum, i in trace.sums {
		fmt.sbprintf(&builder, "%06d %016x\n", trace.first + u32(i), checksum)
	}
	return os.write_entire_file(path, builder.buf[:]) == nil
}

// Reads a trace file; fails on a malformed line or ticks out of order.
trace_read :: proc(path: string) -> (trace: Trace, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return
	}
	defer delete(data)
	text := string(data)
	for raw_line in strings.split_lines_iterator(&text) {
		line := strings.trim_right(raw_line, "\r")
		if line == "" {
			continue
		}
		space := strings.index_byte(line, ' ')
		tick, tick_ok := strconv.parse_u64_of_base(line[:max(space, 0)], 10)
		sum, sum_ok := strconv.parse_u64_of_base(line[space + 1:] if space > 0 else "", 16)
		in_order := len(trace.sums) == 0 || u32(tick) == trace.first + u32(len(trace.sums))
		if !tick_ok || !sum_ok || tick > u64(max(u32)) || !in_order {
			trace_destroy(&trace)
			return {}, false
		}
		trace_add(&trace, u32(tick), sum)
	}
	return trace, true
}

Run_Result :: struct {
	final_tick:     u32,
	final_checksum: u64,
	summary:        string,
}

// The scripted commands of an offline run that wait for a tick: as in a session, at most
// sim.COMMANDS_PER_PLAYER of a player go in one tick and the rest follow in order, and a script's send
// fails once netcode.COMMAND_QUEUE of its commands wait.
Scripted_Commands :: struct {
	waiting: [sim.MAX_PLAYERS][dynamic]sim.Raw_Command,
	out:     sim.Command_Out,
}

scripted_commands_destroy :: proc(commands: ^Scripted_Commands) {
	for &queue in commands.waiting {
		delete(queue)
	}
	delete(commands.out.list)
}

// Scripted inputs and commands of a tick: players < `players` present.
scripted :: proc(
	headless: ^Headless($State, $Input, $World, $PLAYERS),
	simulation: ^sim.Sim(State, Input, World, PLAYERS),
	tick: u32,
	players: int,
	commands: ^Scripted_Commands,
) -> (
	inputs: sim.Inputs(Input, PLAYERS),
) {
	for player in 0 ..< players {
		inputs.present += {player}
		inputs.input[player] = headless.scripted_input(simulation.seed, player, tick, &simulation.state)
		if headless.scripted_commands == nil {
			continue
		}
		queue := &commands.waiting[player]
		out := &commands.out
		out.commands = headless.game.commands
		out.player = player
		out.cap = netcode.COMMAND_QUEUE - len(queue)
		clear(&out.list)
		headless.scripted_commands(simulation.seed, player, tick, &simulation.state, out)
		append(queue, ..out.list[:])
		added := 0
		for added < len(queue) && sim.add_command(&inputs, queue[added]) {
			added += 1
		}
		remove_range(queue, 0, added)
	}
	return
}

// `sim`: scripted run for `ticks` ticks; records every tick's checksum into `trace` and its inputs
// into `input_log` (each optional).
run_sim :: proc(
	headless: ^Headless($State, $Input, $World, $PLAYERS),
	ticks: u32,
	seed: u64,
	players: int,
	trace: ^Trace = nil,
	input_log: ^sim.Input_Log(Input, PLAYERS) = nil,
) -> (
	result: Run_Result,
) {
	simulation := sim.create(headless.game, seed, headless.content)
	defer sim.destroy(simulation)
	commands: Scripted_Commands
	defer scripted_commands_destroy(&commands)
	if input_log != nil {
		input_log.seed = seed
		input_log.content = simulation.content_hash
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
	if headless.summary != nil {
		result.summary = headless.summary(&simulation.state)
	}
	return
}

Synctest_Result :: struct {
	mismatches:     int,
	resimulated:    int, // ticks re-simulated
	final_checksum: u64,
	first_tick:     u32, // the first mismatching tick (0: none)
	first_at:       u32, // the tick whose rollback re-simulated it differently
}

// `synctest`: every tick, once `window` ticks exist, restore `window` ticks back, re-simulate with
// the recorded inputs and compare each tick's checksum with the forward one. `window` is at most
// max_window(game) (the ring's depth).
run_synctest :: proc(
	headless: ^Headless($State, $Input, $World, $PLAYERS),
	ticks, window: u32,
	seed: u64,
	players: int,
) -> (
	result: Synctest_Result,
) {
	assert(window >= 1 && int(window) <= max_window(headless.game))
	simulation := sim.create(headless.game, seed, headless.content)
	defer sim.destroy(simulation)
	commands: Scripted_Commands
	defer scripted_commands_destroy(&commands)
	recorded := make([]sim.Inputs(Input, PLAYERS), ticks + 1)
	forward := make([]u64, ticks + 1)
	defer delete(recorded)
	defer delete(forward)
	for tick in 1 ..= ticks {
		recorded[tick] = scripted(headless, simulation, tick, players, &commands)
		sim.step(simulation, &recorded[tick])
		forward[tick] = sim.checksum(simulation)
		if tick < window {
			continue
		}
		base := tick - window
		if !sim.restore(simulation, base) {
			if result.mismatches == 0 {
				result.first_tick, result.first_at = base, tick
			}
			result.mismatches += 1
			continue
		}
		for resim in base + 1 ..= tick {
			sim.step(simulation, &recorded[resim])
			result.resimulated += 1
			if sim.checksum(simulation) != forward[resim] {
				if result.mismatches == 0 {
					result.first_tick, result.first_at = resim, tick
				}
				result.mismatches += 1
			}
		}
	}
	result.final_checksum = forward[ticks] if ticks > 0 else 0
	return
}

// `replay`: re-simulates an input log, recording every tick's checksum into `trace` (optional). Fails
// when the log was recorded with other content (another level).
run_replay :: proc(
	headless: ^Headless($State, $Input, $World, $PLAYERS),
	input_log: ^sim.Input_Log(Input, PLAYERS),
	trace: ^Trace = nil,
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
	simulation := sim.create(headless.game, input_log.seed, headless.content)
	defer sim.destroy(simulation)
	for k in 0 ..< len(input_log.ticks) {
		inputs := sim.log_inputs(input_log, k)
		sim.step(simulation, &inputs)
		result.final_checksum = sim.checksum(simulation)
		if trace != nil {
			trace_add(trace, u32(k + 1), result.final_checksum)
		}
	}
	result.final_tick = u32(len(input_log.ticks))
	return result, true
}

// `snapshot`: scripted run to `ticks`, then a portable snapshot of that tick (the caller owns `data`).
run_snapshot :: proc(
	headless: ^Headless($State, $Input, $World, $PLAYERS),
	ticks: u32,
	seed: u64,
	players: int,
) -> (
	data: []u8,
	checksum: u64,
) {
	simulation := sim.create(headless.game, seed, headless.content)
	defer sim.destroy(simulation)
	commands: Scripted_Commands
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
	headless: ^Headless($State, $Input, $World, $PLAYERS),
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
	// commands still waiting at the snapshot's tick are not in it (they are input)
	commands: Scripted_Commands
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
