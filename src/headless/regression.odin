// Replay regressions (src/headless/README.md, Replay regressions): a recorded session kept with a game's tests as one
// that must reproduce. regression_run replays a replay folder's recording (its inputs.unil, and the snapshot.unis it
// continues when it starts after tick 0) against the expectation beside it (expected.unie), which blessing writes:
// every tick's checksum and events, and the state block on every tick sim.DEEP_CHECKSUM_EVERY divides, so a
// divergence names the first tick that differs and the fields that differ there.
//
// expected.unie: "UNIE", version u16, compat u64 (the blessing build's), content u64 (its levels' hash), recording u64
// (regression_recording_hash), layout u64 (sim.layout_hash of the State), block size u32, from u32, ticks u32, every
// u32; then per tick: its checksum u64, its event count u16, then per event: kind u8, size u8, its bytes (padding
// zeroed); then per stored block (each tick in from + 1 ..= from + ticks that `every` divides, in order): its packed
// size u32 and its bytes: the block XOR the stored block before it (the first: XOR zero) as runs, each a count of
// zero bytes then a count of literal bytes (both LEB128) and the literal bytes, until the block's size is covered.
package headless

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "unified:sim"
import "unified:wire"

// The expectation file's name in a replay folder.
REGRESSION_EXPECTED :: "expected.unie"
// Bump on any change to what expected.unie holds.
REGRESSION_VERSION :: 1
@(private)
REGRESSION_MAGIC :: "UNIE"

// What a replay regression found (regression_run).
Regression_Status :: enum u8 {
	Reproduces, // every tick's checksum and events are the blessed ones
	Diverges, // a tick differs: Regression.report names it and the fields
	Unblessed, // no expectation beside the recording, or one blessed from another recording or of another format
	Broken, // the recording does not replay here: it doesn't decode for this game, or its snapshot doesn't load
}

// A replay regression's result.
Regression :: struct {
	status:        Regression_Status,
	ticks:         int, // ticks replayed
	diverged_tick: u32, // the first tick whose checksum or events differ from the blessed ones (0: none)
	// What differs, or why it isn't checked ("" when it reproduces; temp-allocated): the first tick, its events or the
	// leaf fields of the first stored block that differs from then on, and whether another build blessed it.
	report:        string,
	blessed:       bool, // `bless`: a new expectation was written (it diverged or had none)
	synctest:      Synctest_Result, // `synctest`: the replay's sync-test (Run): mismatches, check, problem
}

// The expectation of a replay, in memory: what expected.unie holds.
@(private)
Expectation :: struct {
	compat, content, recording, layout: u64,
	block_size, from, ticks, every:     u32,
	sums:                               [dynamic]u64, // sums[k]: tick from + k + 1's checksum
	event_first:                        [dynamic]u32, // tick from + k + 1's events: events[event_first[k]:event_first[k + 1]]
	events:                             [dynamic]sim.Raw_Event,
	blocks:                             [dynamic]u8, // the packed stored blocks, back to back
	block_at:                           [dynamic]u32, // each stored block's offset in `blocks`, then its end
}

@(private)
expectation_destroy :: proc(expectation: ^Expectation) {
	delete(expectation.sums)
	delete(expectation.event_first)
	delete(expectation.events)
	delete(expectation.blocks)
	delete(expectation.block_at)
	expectation^ = {}
}

// Replays the recording in `folder` (a replay folder: inputs.unil, and snapshot.unis when the recording starts after
// tick 0) and compares every tick with the folder's expected.unie. The results decide: a recording replays whatever
// build or levels it was recorded or blessed with, so a change that computes nothing differently passes, and one that
// does (a rule, a re-baked level) diverges until blessed. `bless`: a recording that diverges or has no expectation
// gets a new one, written from this replay (`blessed`), and one that reproduces is left alone; one that diverges on
// the build that blessed it (the same sim.compat_of: its results moved without a version bump) is never blessed, and
// its report says so. `synctest`: the replay
// is a sync-tested run too (Run, rolled back `window` ticks every tick; a recording that continues a snapshot is
// replayed plainly).
regression_run :: proc(
	game: ^$G,
	folder: string,
	bless := false,
	synctest := false,
	window: u32 = 8,
) -> (
	result: Regression,
) {
	State :: sim.part(G, sim.GAME_STATE)
	Event :: sim.part(G, sim.GAME_EVENT)
	log_bytes, log_found := read_file(fmt.tprintf("%s/inputs.unil", folder))
	if !log_found {
		return {status = .Broken, report = "no inputs.unil"}
	}
	defer delete(log_bytes)
	input_log, decoded := sim.log_decode(log_bytes, G)
	if !decoded {
		return {
			status = .Broken,
			report = fmt.tprintf(
				"inputs.unil does not decode for %s (its Input, commands, Setup or Profile changed: record a new one)",
				game.name,
			),
		}
	}
	defer sim.log_destroy(&input_log)
	snapshot: []u8
	defer delete(snapshot)
	if input_log.from > 0 {
		found: bool
		snapshot, found = read_file(fmt.tprintf("%s/snapshot.unis", folder))
		if !found {
			return {
				status = .Broken,
				report = fmt.tprintf("the recording continues tick %d: no snapshot.unis", input_log.from),
			}
		}
	}

	got := Expectation {
		compat     = sim.compat_of(game),
		content    = sim.content_hash(game.levels),
		recording  = regression_recording_hash(log_bytes, snapshot),
		layout     = sim.layout_hash(State),
		block_size = size_of(State),
		from       = input_log.from,
		ticks      = u32(len(input_log.ticks)),
		every      = sim.DEEP_CHECKSUM_EVERY,
	}
	defer expectation_destroy(&got)
	run: Run(G)
	simulation: ^sim.Sim(G)
	synctested := synctest && snapshot == nil
	if synctested {
		run = run_begin_with_setup(game, input_log.seed, input_log.setup, window)
		simulation = run.simulation
	} else if snapshot != nil {
		err: sim.Snap_Error
		simulation, err = sim.from_snapshot(game, snapshot, any_build = true)
		if err != .None {
			return {
				status = .Broken,
				report = fmt.tprintf("snapshot.unis does not load: %v (record a new one)", err),
			}
		}
	} else {
		simulation = sim.create(game, input_log.seed, input_log.setup)
	}
	defer if synctested {
		run_end(&run)
	} else {
		sim.destroy(simulation)
	}
	if simulation.tick != input_log.from {
		return {
			status = .Broken,
			report = fmt.tprintf(
				"the log continues tick %d, its snapshot is tick %d",
				input_log.from,
				simulation.tick,
			),
		}
	}

	previous := make([]u8, size_of(State))
	defer delete(previous)
	variants := sim.union_variants(Event)
	for k in 0 ..< len(input_log.ticks) {
		inputs := sim.log_inputs(&input_log, k)
		if synctested {
			run_step_inputs(&run, &inputs)
		} else {
			sim.step(simulation, &inputs)
		}
		tick := simulation.tick
		append(&got.sums, sim.checksum(simulation))
		append(&got.event_first, u32(len(got.events)))
		for event in sim.events_at(simulation, tick) {
			canonical := event
			if int(event.kind) < len(variants) do zero_padding(variants[event.kind], canonical.data[:event.size])
			append(&got.events, canonical)
		}
		if tick % got.every == 0 {
			block := ([^]u8)(&simulation.state)[:size_of(State)]
			append(&got.block_at, u32(len(got.blocks)))
			pack_delta(&got.blocks, previous, block)
			copy(previous, block)
		}
	}
	append(&got.event_first, u32(len(got.events)))
	append(&got.block_at, u32(len(got.blocks)))
	result.ticks = len(input_log.ticks)
	if synctested do result.synctest = run.result

	path := fmt.tprintf("%s/%s", folder, REGRESSION_EXPECTED)
	want, readable := expectation_read(path)
	defer expectation_destroy(&want)
	switch {
	case !readable:
		result.status = .Unblessed
		result.report = fmt.tprintf("no %s (or one of another format)", REGRESSION_EXPECTED)
	case want.recording != got.recording ||
	     want.from != got.from ||
	     want.ticks != got.ticks ||
	     want.every != got.every:
		result.status = .Unblessed
		result.report = fmt.tprintf("%s was blessed from another recording", REGRESSION_EXPECTED)
	case:
		result.diverged_tick, result.report = expectation_compare(&want, &got, State, Event)
		if result.diverged_tick != 0 do result.status = .Diverges
	}
	// results that moved on the build that blessed them moved without a version bump: never blessed
	moved_unbumped := result.status == .Diverges && want.compat == got.compat
	if bless && result.status != .Reproduces && !moved_unbumped {
		result.blessed = write_file(path, expectation_encode(&got))
	}
	return
}

// The hash expected.unie keeps of the recording it was blessed from: its inputs.unil's bytes and, for one that
// continues a snapshot, snapshot.unis's.
regression_recording_hash :: proc(log_bytes, snapshot: []u8) -> u64 {
	hash := sim.hash_bytes(log_bytes)
	if snapshot != nil do hash ~= sim.hash_bytes(snapshot) * 0x9E3779B97F4A7C15
	return hash
}

// The replay folders under `dir` (each subdirectory holding an inputs.unil), sorted by path; temp-allocated. None
// when `dir` doesn't exist.
regression_folders :: proc(dir: string) -> []string {
	folders := make([dynamic]string, context.temp_allocator)
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return nil
	for entry in entries {
		if entry.type != .Directory do continue
		inputs, _ := filepath.join({entry.fullpath, "inputs.unil"}, context.temp_allocator)
		if os.exists(inputs) do append(&folders, entry.fullpath)
	}
	slice.sort(folders[:])
	return folders[:]
}

// The first tick of `got` that differs from `want` (0: none) and what differs: its events, else the leaf fields of the
// first stored block from that tick on that differs (else the Extra, outside the block); temp-allocated.
@(private)
expectation_compare :: proc(want, got: ^Expectation, $State, $Event: typeid) -> (diverged: u32, report: string) {
	text := strings.builder_make(context.temp_allocator)
	for k in 0 ..< int(got.ticks) {
		events := sim.events_diff(
			got.events[got.event_first[k]:got.event_first[k + 1]],
			want.events[want.event_first[k]:want.event_first[k + 1]],
			Event,
		)
		if got.sums[k] == want.sums[k] && events == "" do continue
		diverged = got.from + u32(k) + 1
		fmt.sbprintf(&text, "first differs at tick %d", diverged)
		if events != "" do fmt.sbprintf(&text, "; its events (blessed, then now): %s", events)
		if got.sums[k] != want.sums[k] do block_report(&text, want, got, type_info_of(State), diverged)
		break
	}
	if diverged == 0 do return
	if want.compat != got.compat {
		fmt.sbprintf(&text, "; blessed by another build (compat %016x, this build %016x)", want.compat, got.compat)
	} else {
		fmt.sbprint(
			&text,
			"; on the build that blessed it (sim.compat_of did not move): a meant change bumps Game.version or " +
			"sim.LIBRARY_VERSION before it is blessed",
		)
	}
	if want.content != got.content do fmt.sbprint(&text, "; blessed with other levels")
	return diverged, strings.to_string(text)
}

// Appends the leaf fields of the first stored block at or after `from` that differs, or that none does.
@(private)
block_report :: proc(text: ^strings.Builder, want, got: ^Expectation, state: ^runtime.Type_Info, from: u32) {
	if want.layout != got.layout || want.block_size != got.block_size {
		fmt.sbprint(text, "; the State's layout changed since the blessing (no field diff)")
		return
	}
	block_want := make([]u8, got.block_size, context.temp_allocator)
	block_got := make([]u8, got.block_size, context.temp_allocator)
	first := (got.from / got.every + 1) * got.every // the first stored tick
	for i in 0 ..< len(got.block_at) - 1 {
		tick := first + u32(i) * got.every
		ok_want := unpack_delta(want.blocks[want.block_at[i]:want.block_at[i + 1]], block_want)
		ok_got := unpack_delta(got.blocks[got.block_at[i]:got.block_at[i + 1]], block_got)
		if !ok_want || !ok_got {
			fmt.sbprint(text, "; a stored block does not unpack")
			return
		}
		if tick < from || string(block_want) == string(block_got) do continue
		lines, total := sim.state_changes(state, raw_data(block_want), raw_data(block_got), 8)
		fmt.sbprintf(
			text,
			"; at tick %d (blessed vs now): %s",
			tick,
			strings.join(lines, "; ", context.temp_allocator),
		)
		if total > len(lines) do fmt.sbprintf(text, "; and %d more", total - len(lines))
		return
	}
	fmt.sbprint(text, "; every stored block from then on agrees: what differs is outside the block (the Extra)")
}

// Zeroes the bytes of a value of `type` that no field covers (its padding), so equal values have equal bytes.
@(private)
zero_padding :: proc(type: ^runtime.Type_Info, bytes: []u8) {
	covered: [sim.EVENT_MAX]bool
	assert(len(bytes) <= len(covered))
	cover_fields(type, covered[:len(bytes)])
	for &byte, i in bytes do if !covered[i] do byte = 0
}

// Marks the bytes of a value of `type` that its leaf fields cover.
@(private)
cover_fields :: proc(type: ^runtime.Type_Info, mask: []bool) {
	#partial switch info in runtime.type_info_base(type).variant {
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(info.field_count) {
			cover_fields(info.types[i], mask[info.offsets[i]:][:info.types[i].size])
		}
	case runtime.Type_Info_Array:
		for i in 0 ..< info.count do cover_fields(info.elem, mask[i * info.elem_size:][:info.elem_size])
	case runtime.Type_Info_Enumerated_Array:
		for i in 0 ..< info.count do cover_fields(info.elem, mask[i * info.elem_size:][:info.elem_size])
	case:
		for &covered in mask do covered = true
	}
}

// Appends `block` XOR `previous` as runs (zeros, then literals, both LEB128 counts, then the literal bytes).
@(private)
pack_delta :: proc(out: ^[dynamic]u8, previous, block: []u8) {
	i := 0
	for i < len(block) {
		zeros := i
		for zeros < len(block) && block[zeros] == previous[zeros] do zeros += 1
		literals := zeros
		// a literal run ends at the first 4 equal bytes in a row (a shorter gap costs more as a new run)
		for literals < len(block) {
			if block[literals] != previous[literals] {
				literals += 1
				continue
			}
			same := literals
			for same < len(block) && same - literals < 4 && block[same] == previous[same] do same += 1
			if same - literals >= 4 || same == len(block) do break
			literals = same
		}
		put_uleb(out, zeros - i)
		put_uleb(out, literals - zeros)
		for k in zeros ..< literals do append(out, block[k] ~ previous[k])
		i = literals
	}
}

// XORs pack_delta's runs into `block`; false when they don't cover it exactly.
@(private)
unpack_delta :: proc(packed: []u8, block: []u8) -> bool {
	at, i := 0, 0
	for i < len(block) {
		zeros, ok_zeros := get_uleb(packed, &at)
		literals, ok_literals := get_uleb(packed, &at)
		if !ok_zeros || !ok_literals || i + zeros + literals > len(block) || at + literals > len(packed) do return false
		i += zeros
		for k in 0 ..< literals do block[i + k] ~= packed[at + k]
		at += literals
		i += literals
	}
	return at == len(packed)
}

@(private)
put_uleb :: proc(out: ^[dynamic]u8, value: int) {
	value := u64(value)
	for value >= 0x80 {
		append(out, u8(value & 0x7f) | 0x80)
		value >>= 7
	}
	append(out, u8(value))
}

@(private)
get_uleb :: proc(bytes: []u8, at: ^int) -> (value: int, ok: bool) {
	shift: uint
	for at^ < len(bytes) && shift < 63 {
		byte := bytes[at^]
		at^ += 1
		value |= int(byte & 0x7f) << shift
		if byte < 0x80 do return value, true
		shift += 7
	}
	return 0, false
}

// expected.unie's bytes (the file header's layout).
@(private)
expectation_encode :: proc(expectation: ^Expectation) -> []u8 {
	writer := wire.writer_make(64 + len(expectation.sums) * 10 + len(expectation.blocks), context.temp_allocator)
	wire.w_bytes(&writer, transmute([]u8)string(REGRESSION_MAGIC))
	wire.w_u16(&writer, REGRESSION_VERSION)
	wire.w_u64(&writer, expectation.compat)
	wire.w_u64(&writer, expectation.content)
	wire.w_u64(&writer, expectation.recording)
	wire.w_u64(&writer, expectation.layout)
	wire.w_u32(&writer, expectation.block_size)
	wire.w_u32(&writer, expectation.from)
	wire.w_u32(&writer, expectation.ticks)
	wire.w_u32(&writer, expectation.every)
	for k in 0 ..< int(expectation.ticks) {
		wire.w_u64(&writer, expectation.sums[k])
		events := expectation.events[expectation.event_first[k]:expectation.event_first[k + 1]]
		wire.w_u16(&writer, u16(len(events)))
		for &event in events {
			wire.w_u8(&writer, event.kind)
			wire.w_u8(&writer, event.size)
			wire.w_bytes(&writer, event.data[:event.size])
		}
	}
	for i in 0 ..< len(expectation.block_at) - 1 {
		packed := expectation.blocks[expectation.block_at[i]:expectation.block_at[i + 1]]
		wire.w_u32(&writer, u32(len(packed)))
		wire.w_bytes(&writer, packed)
	}
	return writer.buf[:]
}

// Reads expected.unie; false when it is missing, of another version or malformed.
@(private)
expectation_read :: proc(path: string) -> (expectation: Expectation, ok: bool) {
	data := read_file(path) or_return
	defer delete(data)
	reader := wire.reader_make(data)
	if string(wire.r_bytes(&reader, len(REGRESSION_MAGIC))) != REGRESSION_MAGIC ||
	   wire.r_u16(&reader) != REGRESSION_VERSION {
		return
	}
	expectation.compat = wire.r_u64(&reader)
	expectation.content = wire.r_u64(&reader)
	expectation.recording = wire.r_u64(&reader)
	expectation.layout = wire.r_u64(&reader)
	expectation.block_size = wire.r_u32(&reader)
	expectation.from = wire.r_u32(&reader)
	expectation.ticks = wire.r_u32(&reader)
	expectation.every = wire.r_u32(&reader)
	if !reader.ok || expectation.every == 0 || int(expectation.ticks) * 10 > wire.r_remaining(&reader) {
		return {}, false
	}
	for _ in 0 ..< expectation.ticks {
		append(&expectation.sums, wire.r_u64(&reader))
		append(&expectation.event_first, u32(len(expectation.events)))
		count := wire.r_u16(&reader) // read once: a range's end is evaluated before every iteration
		for _ in 0 ..< count {
			event := sim.Raw_Event {
				kind = wire.r_u8(&reader),
				size = wire.r_u8(&reader),
			}
			if int(event.size) > sim.EVENT_MAX do reader.ok = false
			if !reader.ok do break
			copy(event.data[:], wire.r_bytes(&reader, int(event.size)))
			append(&expectation.events, event)
		}
		if !reader.ok do break
	}
	append(&expectation.event_first, u32(len(expectation.events)))
	for reader.ok && wire.r_remaining(&reader) > 0 {
		size := int(wire.r_u32(&reader))
		append(&expectation.block_at, u32(len(expectation.blocks)))
		append(&expectation.blocks, ..wire.r_bytes(&reader, size))
	}
	append(&expectation.block_at, u32(len(expectation.blocks)))
	if !reader.ok {
		expectation_destroy(&expectation)
		return {}, false
	}
	return expectation, true
}

// A file's bytes (the caller owns them); false when it can't be read. (Non-generic: regression_run's core:os.)
@(private)
read_file :: proc(path: string) -> (data: []u8, ok: bool) {
	bytes, err := os.read_entire_file(path, context.allocator)
	return bytes, err == nil
}
