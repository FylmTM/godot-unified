// Offline runs, generic over the game: scripted runs, sync-test, replay, snapshot/resume, all in
// memory (the CLI, unified:headless/modes, does the file I/O).
package headless

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "unified:netcode"
import "unified:sim"

// A game as the headless runs, the end-to-end suites and the CLI drive it.
Headless :: struct($S, $I, $W: typeid, $P: int) {
	game:            ^sim.Game(S, I, W, P),
	// Scripted input of `slot` for tick t; `state` is the caller's current state (nil if none).
	script:          proc(seed: u64, slot: int, t: u32, state: ^S) -> I,
	// Optional: the scripted commands of `slot` for tick t (sim.send_command(out, cmd)); called right after
	// `script` for the same tick, in offline runs and by every client of a session.
	script_commands: proc(seed: u64, slot: int, t: u32, state: ^S, out: ^sim.Command_Out),
	// JSON fields describing a state, for the `sim` output (optional; temp-allocated).
	summary:         proc(s: ^S) -> string,
	// `bench`: fill the state with n entities and hold that population (optional).
	bench_prepare:   proc(s: ^S, w: ^W, n: int),
	// `bench`: the current entity count, for enemies_mean (optional).
	bench_count:     proc(s: ^S) -> int,
	// The game's standard benchmark: what `bench` runs without arguments (`uni bench`).
	bench:           Bench,
	// The game's content (its level file, src/level/SPEC.md), e.g. embedded with #load; the CLI's
	// `--level FILE` replaces it.
	content:         []u8,
}

// A benchmark's setup: `enemies` entities held (with bench_prepare), a `window`-tick rollback every tick, for
// `ticks` ticks. `what` says what it measures.
Bench :: struct {
	what:    string,
	enemies: int,
	window:  int,
	ticks:   int,
}

// A run's checksums, one per tick from `first` on: sums[i] is the checksum after tick first + i.
// On disk (`--trace`, a reference run's ref.trace): one "%06d %016x" line per tick, in order.
Trace :: struct {
	first: u32,
	sums:  [dynamic]u64,
}

trace_add :: proc(tr: ^Trace, tick: u32, checksum: u64) {
	if len(tr.sums) == 0 {
		tr.first = tick
	}
	assert(tick == tr.first + u32(len(tr.sums)), "trace ticks must be consecutive")
	append(&tr.sums, checksum)
}

trace_destroy :: proc(tr: ^Trace) {
	delete(tr.sums)
	tr^ = {}
}

// The checksum of tick t, if the trace has it.
trace_at :: proc(tr: ^Trace, t: u32) -> (checksum: u64, ok: bool) {
	if t < tr.first || t - tr.first >= u32(len(tr.sums)) {
		return
	}
	return tr.sums[t - tr.first], true
}

trace_write :: proc(tr: ^Trace, path: string) -> bool {
	b := strings.builder_make(0, len(tr.sums) * 24)
	defer strings.builder_destroy(&b)
	for c, i in tr.sums {
		fmt.sbprintf(&b, "%06d %016x\n", tr.first + u32(i), c)
	}
	return os.write_entire_file(path, b.buf[:]) == nil
}

// Reads a trace file; fails on a malformed line or ticks out of order.
trace_read :: proc(path: string) -> (tr: Trace, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return
	}
	defer delete(data)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_right(line, "\r")
		if l == "" {
			continue
		}
		sp := strings.index_byte(l, ' ')
		tick, tok := strconv.parse_u64_of_base(l[:max(sp, 0)], 10)
		sum, sok := strconv.parse_u64_of_base(l[sp + 1:] if sp > 0 else "", 16)
		if !tok || !sok || tick > u64(max(u32)) || (len(tr.sums) > 0 && u32(tick) != tr.first + u32(len(tr.sums))) {
			trace_destroy(&tr)
			return {}, false
		}
		trace_add(&tr, u32(tick), sum)
	}
	return tr, true
}

Run_Result :: struct {
	final_tick:     u32,
	final_checksum: u64,
	summary:        string,
}

// The scripted commands of an offline run that wait for a tick: as in a session, at most
// sim.COMMANDS_PER_PLAYER of a player go in one tick and the rest follow in order, and a script's send
// fails once netcode.COMMAND_QUEUE of its commands wait.
Script_Commands :: struct {
	waiting: [sim.MAX_SLOTS][dynamic]sim.Command,
	out:     sim.Command_Out,
}

script_commands_destroy :: proc(sc: ^Script_Commands) {
	for &q in sc.waiting {
		delete(q)
	}
	delete(sc.out.list)
}

// Scripted inputs and commands of tick t: slots < players present.
scripted :: proc(
	h: ^Headless($S, $I, $W, $P),
	s: ^sim.Sim(S, I, W, P),
	t: u32,
	players: int,
	sc: ^Script_Commands,
) -> (
	in_: sim.Inputs(I, P),
) {
	for p in 0 ..< players {
		in_.present += {p}
		in_.input[p] = h.script(s.seed, p, t, &s.state)
		if h.script_commands == nil {
			continue
		}
		q := &sc.waiting[p]
		out := &sc.out
		out.kinds = h.game.commands
		out.slot = p
		out.cap = netcode.COMMAND_QUEUE - len(q)
		clear(&out.list)
		h.script_commands(s.seed, p, t, &s.state, out)
		append(q, ..out.list[:])
		n := 0
		for n < len(q) && sim.add_command(&in_, q[n]) {
			n += 1
		}
		remove_range(q, 0, n)
	}
	return
}

// `sim`: scripted run for `ticks` ticks; records every tick's checksum into `tr` and its inputs
// into `lg` (each optional).
run_sim :: proc(
	h: ^Headless($S, $I, $W, $P),
	ticks: u32,
	seed: u64,
	players: int,
	tr: ^Trace = nil,
	lg: ^sim.Input_Log(I, P) = nil,
) -> (
	res: Run_Result,
) {
	s := sim.create(h.game, seed, h.content)
	defer sim.destroy(s)
	sc: Script_Commands
	defer script_commands_destroy(&sc)
	if lg != nil {
		lg.seed = seed
		lg.content = s.content_hash
	}
	for t in 1 ..= ticks {
		inputs := scripted(h, s, t, players, &sc)
		if lg != nil {
			sim.log_append(lg, &inputs)
		}
		sim.step(s, &inputs)
		res.final_checksum = sim.checksum(s)
		if tr != nil {
			trace_add(tr, t, res.final_checksum)
		}
	}
	res.final_tick = ticks
	if h.summary != nil {
		res.summary = h.summary(&s.state)
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
// the recorded inputs and compare each tick's checksum with the forward one.
run_synctest :: proc(
	h: ^Headless($S, $I, $W, $P),
	ticks, window: u32,
	seed: u64,
	players: int,
) -> (
	res: Synctest_Result,
) {
	assert(window >= 1 && window < sim.RING)
	s := sim.create(h.game, seed, h.content)
	defer sim.destroy(s)
	sc: Script_Commands
	defer script_commands_destroy(&sc)
	recorded := make([]sim.Inputs(I, P), ticks + 1)
	forward := make([]u64, ticks + 1)
	defer delete(recorded)
	defer delete(forward)
	for t in 1 ..= ticks {
		recorded[t] = scripted(h, s, t, players, &sc)
		sim.step(s, &recorded[t])
		forward[t] = sim.checksum(s)
		if t < window {
			continue
		}
		base := t - window
		if !sim.restore(s, base) {
			if res.mismatches == 0 {
				res.first_tick, res.first_at = base, t
			}
			res.mismatches += 1
			continue
		}
		for u in base + 1 ..= t {
			sim.step(s, &recorded[u])
			res.resimulated += 1
			if sim.checksum(s) != forward[u] {
				if res.mismatches == 0 {
					res.first_tick, res.first_at = u, t
				}
				res.mismatches += 1
			}
		}
	}
	res.final_checksum = forward[ticks] if ticks > 0 else 0
	return
}

// `replay`: re-simulates an input log, recording every tick's checksum into `tr` (optional). Fails
// when the log was recorded with other content (another level).
run_replay :: proc(
	h: ^Headless($S, $I, $W, $P),
	lg: ^sim.Input_Log(I, P),
	tr: ^Trace = nil,
) -> (
	res: Run_Result,
	ok: bool,
) {
	if lg.content != sim.content_hash(h.content) {
		fmt.eprintfln(
			"replay: the log was recorded with another level (content %016x, this run has %016x; see --level)",
			lg.content,
			sim.content_hash(h.content),
		)
		return
	}
	s := sim.create(h.game, lg.seed, h.content)
	defer sim.destroy(s)
	for k in 0 ..< len(lg.ticks) {
		in_ := sim.log_inputs(lg, k)
		sim.step(s, &in_)
		res.final_checksum = sim.checksum(s)
		if tr != nil {
			trace_add(tr, u32(k + 1), res.final_checksum)
		}
	}
	res.final_tick = u32(len(lg.ticks))
	return res, true
}

// `snapshot`: scripted run to `ticks`, then a portable snapshot of that tick (the caller owns `data`).
run_snapshot :: proc(
	h: ^Headless($S, $I, $W, $P),
	ticks: u32,
	seed: u64,
	players: int,
) -> (
	data: []u8,
	checksum: u64,
) {
	s := sim.create(h.game, seed, h.content)
	defer sim.destroy(s)
	sc: Script_Commands
	defer script_commands_destroy(&sc)
	for t in 1 ..= ticks {
		in_ := scripted(h, s, t, players, &sc)
		sim.step(s, &in_)
	}
	return sim.snapshot_encode(s, ticks), sim.checksum(s)
}

// `resume`: restores a portable snapshot and continues the scripted run for `ticks` ticks with
// `players` players present, recording every tick's checksum into `tr` (optional).
run_resume :: proc(
	h: ^Headless($S, $I, $W, $P),
	data: []u8,
	ticks: u32,
	players: int,
	tr: ^Trace = nil,
) -> (
	res: Run_Result,
	ok: bool,
) {
	s, serr := sim.from_snapshot(h.game, data, h.content)
	if serr != .None {
		fmt.eprintfln("resume: not a valid snapshot for this build: %v", serr)
		return
	}
	defer sim.destroy(s)
	sc: Script_Commands // commands still waiting at the snapshot's tick are not in it (they are input)
	defer script_commands_destroy(&sc)
	start := s.tick
	for t in start + 1 ..= start + ticks {
		in_ := scripted(h, s, t, players, &sc)
		sim.step(s, &in_)
		res.final_checksum = sim.checksum(s)
		if tr != nil {
			trace_add(tr, t, res.final_checksum)
		}
	}
	res.final_tick = start + ticks
	return res, true
}
