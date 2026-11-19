// Input logs and portable snapshots: round trips, the desync diff, every Snap_Error.
package test_sim

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:testing"

import "../toy"
import "unified:sim"

@(test)
input_log_round_trip :: proc(t: ^testing.T) {
	input_log := sim.Input_Log(toy.Game) {
		seed    = 99,
		content = 0xC0FFEE,
		compat  = 0xB111D,
	}
	defer sim.log_destroy(&input_log)
	for k in 0 ..< 50 {
		inputs: toy.Inputs
		inputs.present = {0, 1}
		if k == 0 || k == 30 do sim.join(&inputs, 1, k + 2) // a join record, and another member later
		inputs.replaced = {1} if k % 7 == 0 else {}
		inputs.input[0] = toy.scripted_input(99, 0, u32(k + 1))
		inputs.input[1] = toy.scripted_input(99, 1, u32(k + 1))
		if k % 5 == 0 {
			bump := sim.command_make(toy.Cmd, toy.Cmd_Bump{i32(k)})
			bump.slot = 1
			sim.add_command(&inputs, bump)
			mark := sim.command_make(toy.Cmd, toy.Cmd_Mark{count = i16(k), shapes = {.Dot, .Star}})
			sim.add_command(&inputs, mark) // slot 0: goes before slot 1's
		}
		sim.log_append(&input_log, &inputs)
	}
	data := sim.log_encode(&input_log)
	defer delete(data)
	// an empty tick costs one byte for its record kind, one for its command count and one for its join count; a command, 3 bytes plus its
	// struct; a join record 3
	command_bytes := 10 * (2 * sim.COMMAND_HEAD + size_of(toy.Cmd_Bump) + size_of(toy.Cmd_Mark))
	tick_bytes := 10 + size_of([toy.PLAYERS]toy.Input)
	testing.expect_value(
		t,
		len(data),
		sim.LOG_HEADER +
		size_of(toy.Setup) +
		50 * (1 + tick_bytes) +
		command_bytes +
		2 * (sim.JOIN_BYTES + size_of(toy.Profile)),
	)
	back, ok := sim.log_decode(data, toy.Game)
	defer sim.log_destroy(&back)
	testing.expect(t, ok)
	testing.expect_value(t, back.seed, 99)
	testing.expect_value(t, back.content, 0xC0FFEE)
	testing.expect_value(t, back.compat, 0xB111D)
	testing.expect_value(t, len(back.ticks), 50)
	for k in 0 ..< 50 {
		decoded, original := sim.log_inputs(&back, k), sim.log_inputs(&input_log, k)
		testing.expect(t, sim.inputs_same(&decoded, &original) && decoded.replaced == original.replaced)
		testing.expect_value(t, decoded.joins[1], u16(k + 2) if k == 0 || k == 30 else 0)
		if k % 5 == 0 {
			commands := decoded.commands
			testing.expect(t, decoded.command_count == 2 && commands[0].slot == 0 && commands[1].slot == 1)
		}
	}
	_, bad := sim.log_decode(data[:len(data) - 1], toy.Game)
	testing.expect(t, !bad)
}

// A recording that never ended (a relay stopped mid-session) whose last tick is cut, by a torn write or a copy of a
// growing file, decodes to its whole ticks; a cut inside an ended log stays an error (input_log_round_trip).
@(test)
an_unended_log_with_a_cut_tail_keeps_its_whole_ticks :: proc(t: ^testing.T) {
	recording: [dynamic]u8
	defer delete(recording)
	stream: sim.Log_Stream
	setup := toy.Setup{}
	sim.log_stream_begin(&stream, sim.log_sink_memory(&recording), sim.log_header(&toy.GAME, 1, &setup, 0, 0))
	defer delete(stream.writer.buf)
	for k in 0 ..< 20 {
		inputs: toy.Inputs
		inputs.present = {0}
		if k == 0 do sim.join(&inputs, 0, 1)
		inputs.input[0] = toy.scripted_input(1, 0, u32(k + 1))
		sim.log_stream_tick(&stream, &inputs)
	}
	whole, whole_ok := sim.log_decode(recording[:], toy.Game)
	testing.expect(t, whole_ok && len(whole.ticks) == 20)
	sim.log_destroy(&whole)
	for short in ([]int{1, 3, 7}) {
		cut, cut_ok := sim.log_decode(recording[:len(recording) - short], toy.Game)
		testing.expectf(
			t,
			cut_ok && len(cut.ticks) == 19,
			"%d bytes short: %v, %d ticks",
			short,
			cut_ok,
			len(cut.ticks),
		)
		sim.log_destroy(&cut)
	}
}

// Checkpoints ride beside the ticks as tagged records: a stream and log_encode write the same bytes, a decoded log
// encodes byte-identical (checkpoints where they were recorded, not sorted), a stream cut after any byte reads to
// its last whole record, and a checkpoint of a tick the log doesn't hold yet is refused.
@(test)
log_checkpoints_round_trip :: proc(t: ^testing.T) {
	recording: [dynamic]u8
	defer delete(recording)
	stream: sim.Log_Stream
	setup := toy.Setup{}
	sim.log_stream_begin(
		&stream,
		sim.log_sink_memory(&recording),
		sim.log_header(&toy.GAME, 1, &setup, 0, 0, from = 4),
	)
	expected: sim.Input_Log(toy.Game)
	defer sim.log_destroy(&expected)
	expected.seed, expected.from = 1, 4
	for k in 0 ..< 40 {
		inputs: toy.Inputs
		inputs.present = {0}
		if k == 0 do sim.join(&inputs, 0, 1)
		inputs.input[0] = toy.scripted_input(1, 0, u32(k + 5))
		sim.log_stream_tick(&stream, &inputs)
		sim.log_append(&expected, &inputs)
		tick := u32(k + 5)
		if tick % 16 == 0 || tick == 9 { 	// judged late and out of order: 16 after 9's tick
			checked := tick == 16 ? u32(9) : tick == 9 ? u32(6) : tick
			sim.log_stream_checkpoint(&stream, checked, u64(checked) * 1000)
			sim.log_checkpoint(&expected, checked, u64(checked) * 1000)
		}
	}
	testing.expect(t, sim.log_stream_end(&stream))
	encoded := sim.log_encode(&expected)
	defer delete(encoded)
	testing.expect(t, string(encoded) == string(recording[:]), "a stream and log_encode write the same bytes")
	decoded, ok := sim.log_decode(recording[:], toy.Game)
	defer sim.log_destroy(&decoded)
	testing.expect(t, ok && decoded.from == 4 && len(decoded.ticks) == 40 && len(decoded.checkpoints) == 3)
	again := sim.log_encode(&decoded)
	defer delete(again)
	testing.expect(t, string(again) == string(recording[:]), "a decoded log encodes byte-identical")
	// unended (count 0): cut after any byte, the whole records before the cut
	unended := make([]u8, len(recording))
	defer delete(unended)
	copy(unended, recording[:])
	unended[33], unended[34], unended[35], unended[36] = 0, 0, 0, 0
	for cut in sim.LOG_HEADER + size_of(toy.Setup) ..< len(unended) {
		part, part_ok := sim.log_decode(unended[:cut], toy.Game)
		testing.expectf(t, part_ok && len(part.ticks) <= 40, "cut at %d", cut)
		sim.log_destroy(&part)
	}
	// a checkpoint of a tick the log doesn't hold before it
	early: sim.Input_Log(toy.Game)
	defer sim.log_destroy(&early)
	early.from = 4
	inputs: toy.Inputs
	sim.log_append(&early, &inputs)
	sim.log_checkpoint(&early, 5, 1)
	bytes := sim.log_encode(&early)
	defer delete(bytes)
	at := sim.LOG_HEADER + size_of(toy.Setup) + 1 + 10 + size_of([toy.PLAYERS]toy.Input) // after the tick record
	bytes[at + 1] = 6 // the checkpoint's tick: 6, one past the log
	_, early_ok := sim.log_decode(bytes, toy.Game)
	testing.expect(t, !early_ok, "a checkpoint of a tick the log doesn't hold")
}

@(test)
portable_snapshot_round_trip :: proc(t: ^testing.T) {
	original := sim.create(&toy.GAME, 7)
	defer sim.destroy(original)
	run(original, 90, 3)
	data := sim.snapshot_encode(original, 90)
	defer delete(data)
	restored, restore_err := sim.from_snapshot(&toy.GAME, data)
	testing.expect_value(t, restore_err, sim.Snap_Error.None)
	if restored == nil {
		return
	}
	defer sim.destroy(restored)
	testing.expect_value(t, restored.tick, 90)
	testing.expect_value(t, restored.seed, 7)
	testing.expect_value(t, sim.checksum(restored), sim.checksum(original))
	run(original, 60, 3)
	run(restored, 60, 3)
	testing.expect_value(t, sim.checksum(restored), sim.checksum(original))
	data[len(data) - 1] ~= 1 // the payload digest must catch corruption
	_, err := sim.from_snapshot(&toy.GAME, data)
	testing.expect_value(t, err, sim.Snap_Error.Checksum_Mismatch)
}

// A snapshot taken again and again into one buffer (a client's kept desync images) allocates nothing once the buffer
// has its size, on the heap or the temp allocator (the State's layout hash is derived once, at create), and carries
// that layout hash.
@(test)
snapshot_encode_into_allocates_nothing :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 7)
	defer sim.destroy(simulation)
	run(simulation, 40, 3)
	out: [dynamic]u8
	defer delete(out)
	sim.snapshot_encode_into(simulation, 40, &out)
	heap := Counting {
		inner = context.allocator,
	}
	temp := Counting {
		inner = context.temp_allocator,
	}
	context.allocator = {counting_proc, &heap}
	context.temp_allocator = {counting_proc, &temp}
	for _ in 0 ..< 8 {
		run(simulation, 1, 3)
		sim.snapshot_encode_into(simulation, simulation.tick, &out)
	}
	sim.snapshot_encode_into(simulation, simulation.tick - 3, &out)
	testing.expect_value(t, heap.allocs, 0)
	testing.expect_value(t, temp.allocs, 0)
	layout := (^u64le)(&out[4 + 2 + 8 + 8 + 4 + 4])^ // after the magic, version, seed, content, tick and block size
	testing.expect_value(t, u64(layout), sim.layout_hash(toy.State))
}

// Counts the allocations (and resizes) that go through it to the allocator it wraps.
Counting :: struct {
	inner:  runtime.Allocator,
	allocs: int,
}

counting_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	counting := (^Counting)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		counting.allocs += 1
	}
	return counting.inner.procedure(counting.inner.data, mode, size, alignment, old_memory, old_size, location)
}

// The desync report walks the State: a table's item by index down to the leaf field, a slot's liveness, a global.
@(test)
snapshot_diff_names_the_fields :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 3)
	defer sim.destroy(simulation)
	_, handle, _ := sim.spawn(&simulation.state.things)
	sim.save(simulation)
	before := sim.snapshot_encode(simulation, 0)
	defer delete(before)
	sim.get(&simulation.state.things, handle).pos.y = 2
	simulation.state.spawned = 5
	sim.spawn(&simulation.state.things)
	sim.save(simulation)
	after := sim.snapshot_encode(simulation, 0)
	defer delete(after)
	diff := sim.snapshot_diff(toy.State, before, after)
	testing.expect(t, strings.contains(diff, "things[0].pos[1] 0 vs 2"), diff)
	testing.expect(t, strings.contains(diff, "things[1]: its slot"), diff)
	testing.expect(t, strings.contains(diff, "spawned 0 vs 5"), diff)
	testing.expect_value(t, sim.snapshot_diff(toy.State, before, before), "")
}

// A game whose Extra images `extra_image` (a snapshot with an image a game without an Extra must refuse).
extra_image := [4]u8{1, 2, 3, 4}

imaging_game :: proc() -> toy.Game {
	game := toy.GAME
	game.extra = proc(world: ^toy.World) -> sim.Extra {
		return {
			save = proc(data: rawptr, slot: int) {},
			restore = proc(data: rawptr, slot: int) -> bool {return true},
			hash = proc(data: rawptr, tick: u32, out: ^[dynamic]u8) {},
			image = proc(data: rawptr, slot: int, live: bool) -> []u8 {return extra_image[:]},
			load = proc(data: rawptr, bytes: []u8) -> bool {return len(bytes) == len(extra_image)},
		}
	}
	return game
}

// Every reason a snapshot doesn't restore is a value: a cut or foreign header, another format version, another
// layout or block size, other levels, another build (game version, library), a damaged payload, an Extra's image
// the game can't take. Logs of another format version are refused too.
@(test)
snapshot_errors_are_values :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 7)
	defer sim.destroy(simulation)
	run(simulation, 20, 3)
	good := sim.snapshot_encode(simulation, 20)
	defer delete(good)
	other_version := toy.GAME
	other_version.version = "another"
	other_levels := toy.GAME
	other_levels.levels = {{"meadow", {1, 2, 4}}, toy.GAME.levels[1]}
	renamed_levels := toy.GAME
	renamed_levels.levels = {toy.GAME.levels[1], toy.GAME.levels[0]}
	imaging := imaging_game()
	with_image := sim.create(&imaging, 7)
	defer sim.destroy(with_image)
	image_snapshot := sim.snapshot_encode(with_image, 0)
	defer delete(image_snapshot)
	Case :: struct {
		what:  string,
		game:  ^toy.Game,
		patch: proc(data: []u8),
		bytes: []u8, // instead of a patched copy of `good`
		want:  sim.Snap_Error,
	}
	cases := []Case {
		{"intact", &toy.GAME, nil, nil, .None},
		{"cut short", &toy.GAME, nil, good[:10], .Bad_Header},
		{"another magic", &toy.GAME, proc(data: []u8) {data[0] = 'X'}, nil, .Bad_Header},
		{
			"another format version",
			&toy.GAME,
			proc(data: []u8) {data[4] = u8(sim.SNAP_VERSION - 1)},
			nil,
			.Bad_Header,
		},
		{"another layout", &toy.GAME, proc(data: []u8) {data[sim.SNAP_HEADER - 17] ~= 1}, nil, .Layout_Differs},
		{
			"another block size",
			&toy.GAME,
			proc(data: []u8) {data[sim.SNAP_HEADER - 28] ~= 4},
			nil,
			.Layout_Differs,
		},
		{"other level bytes", &other_levels, nil, nil, .Content_Differs},
		{"the levels in another order", &renamed_levels, nil, nil, .Content_Differs},
		{"another game version", &other_version, nil, nil, .Build_Differs},
		{
			"another library version",
			&toy.GAME,
			proc(data: []u8) {
				another := transmute([8]u8)u64le(sim.compat_of(&toy.GAME, {version = sim.LIBRARY_VERSION + 1}))
				copy(data[sim.SNAP_HEADER - 16:], another[:]) // the compat, before the payload digest
			},
			nil,
			.Build_Differs,
		},
		{"a damaged payload", &toy.GAME, proc(data: []u8) {data[len(data) - 1] ~= 1}, nil, .Checksum_Mismatch},
		{"an image the game has no Extra for", &toy.GAME, nil, image_snapshot, .Extra_Rejected},
	}
	for test_case in cases {
		data := slice.clone(test_case.bytes != nil ? test_case.bytes : good)
		defer delete(data)
		if test_case.patch != nil do test_case.patch(data)
		restored, err := sim.from_snapshot(test_case.game, data)
		testing.expectf(t, err == test_case.want, "%s: %v, wanted %v", test_case.what, err, test_case.want)
		if restored != nil do sim.destroy(restored)
	}
	// A log of another format version is refused too (only the current one is read).
	input_log := sim.Input_Log(toy.Game) {
		seed = 5,
	}
	defer sim.log_destroy(&input_log)
	inputs: toy.Inputs
	sim.log_append(&input_log, &inputs)
	data := sim.log_encode(&input_log)
	defer delete(data)
	back, ok := sim.log_decode(data, toy.Game)
	testing.expect(t, ok && back.seed == 5 && len(back.ticks) == 1)
	sim.log_destroy(&back)
	data[4] = u8(sim.LOG_VERSION - 1) // the version, little-endian, after the magic
	_, ok = sim.log_decode(data, toy.Game)
	testing.expect(t, !ok)
}

// A kept tick (snapshot_keep) encodes, after the ring moved past it, to the bytes snapshot_encode gave while the ring
// held it: for a game without an Extra and for one whose Extra has no keep (imaged at once). Keeping again allocates
// nothing; an empty slot or a tick out of the ring is refused.
@(test)
a_kept_tick_encodes_as_the_ring_did :: proc(t: ^testing.T) {
	imaging := imaging_game()
	for game in ([]^toy.Game{&toy.GAME, &imaging}) {
		simulation := sim.create(game, 7)
		defer sim.destroy(simulation)
		out: [dynamic]u8
		defer delete(out)
		_, _, empty := sim.snapshot_encode_kept(simulation, 0, &out)
		testing.expect(t, !empty)
		wanted: [sim.KEEP_SLOTS][]u8
		defer for bytes in wanted do delete(bytes)
		for k in 0 ..< sim.KEEP_SLOTS {
			run(simulation, 16, 3)
			wanted[k] = sim.snapshot_encode(simulation, simulation.tick)
			testing.expect(t, sim.snapshot_keep(simulation, simulation.tick, k))
		}
		run(simulation, 2 * u32(sim.ring_size(game.tick_hz)), 3) // the kept ticks left the ring long ago
		testing.expect(t, !sim.snapshot_keep(simulation, 16, 0))
		testing.expect(t, !sim.snapshot_keep(simulation, simulation.tick, sim.KEEP_SLOTS))
		for k in 0 ..< sim.KEEP_SLOTS {
			bytes, tick, ok := sim.snapshot_encode_kept(simulation, k, &out)
			testing.expect(t, ok && tick == u32(16 * (k + 1)))
			testing.expectf(t, string(bytes) == string(wanted[k]), "keep slot %d: other bytes", k)
		}
		counting := Counting {
			inner = context.allocator,
		}
		context.allocator = {counting_proc, &counting}
		for k in 0 ..< sim.KEEP_SLOTS {
			run(simulation, 1, 3)
			sim.snapshot_keep(simulation, simulation.tick, k)
		}
		testing.expect_value(t, counting.allocs, 0)
	}
}

// An unended recording damaged in the middle (an unknown record kind with whole ticks after it) is refused: only a
// record cut where the bytes run out is a torn tail.
@(test)
an_unended_log_damaged_in_the_middle_is_refused :: proc(t: ^testing.T) {
	recording: [dynamic]u8
	defer delete(recording)
	stream: sim.Log_Stream
	setup := toy.Setup{}
	sim.log_stream_begin(&stream, sim.log_sink_memory(&recording), sim.log_header(&toy.GAME, 1, &setup, 0, 0))
	defer delete(stream.writer.buf)
	second := 0 // where the second tick's record begins
	for k in 0 ..< 6 {
		if k == 1 do second = len(recording)
		inputs: toy.Inputs
		inputs.present = {0}
		if k == 0 do sim.join(&inputs, 0, 1)
		sim.log_stream_tick(&stream, &inputs)
	}
	recording[second] = 7 // an unknown record kind, four whole ticks after it
	damaged, ok := sim.log_decode(recording[:], toy.Game)
	defer sim.log_destroy(&damaged)
	testing.expectf(t, !ok, "a damaged middle reads as a %d-tick recording (of 6)", len(damaged.ticks))
}

// A desync image whose List count is past its capacity (a crafted or damaged client's): the report says so and walks
// the array once, not the count.
@(test)
the_desync_diff_bounds_a_collection_by_its_capacity :: proc(t: ^testing.T) {
	simulation := sim.create(&BAG_GAME, 3)
	defer sim.destroy(simulation)
	sim.append(&simulation.state.bag, toy.Thing{life = 1})
	sim.save(simulation)
	honest := sim.snapshot_encode(simulation, 0)
	defer delete(honest)
	simulation.state.bag.items[0].life = 2
	simulation.state.bag.count = 4_000_000 // what a crafted image says
	sim.save(simulation)
	crafted := sim.snapshot_encode(simulation, 0)
	defer delete(crafted)
	diff := sim.snapshot_diff(Bag_State, honest, crafted)
	testing.expectf(t, strings.contains(diff, "count 4000000 past its capacity 4"), "%s", diff)
	testing.expectf(t, strings.contains(diff, "1 vs 4 items"), "%s", diff)
	testing.expectf(t, !strings.contains(diff, "bag[4]"), "the walk stays inside the array: %s", diff)
}

// Two blocks whose bytes differ only in where a Queue's head is (the same live items, so other checksums): the report
// names the head.
@(test)
the_desync_diff_names_a_queue_differing_only_in_its_head :: proc(t: ^testing.T) {
	Holder :: struct {
		queue: sim.Queue(u8, 4),
	}
	a, b: Holder
	sim.append(&a.queue, 5)
	sim.append(&a.queue, 5) // [5, 5], head 0
	sim.append(&b.queue, 5)
	sim.append(&b.queue, 5)
	sim.pop_front(&b.queue)
	sim.append(&b.queue, 5) // [5, 5], head 1
	testing.expect(t, a != b, "the bytes differ")
	lines, total := sim.state_changes(type_info_of(Holder), &a, &b)
	testing.expectf(t, total == 1 && len(lines) == 1 && lines[0] == "queue: head 0 vs 1", "%v", lines)
}

Bag_State :: struct {
	players: sim.Players(toy.Player_Data, sim.No_Profile, toy.Input, toy.PLAYERS),
	bag:     sim.List(toy.Thing, 4),
}

Bag_Game :: sim.Game(Bag_State, toy.Input, sim.No_World, toy.Event, toy.Cmd, sim.No_Setup, sim.No_Profile, toy.PLAYERS)

BAG_GAME := Bag_Game {
	name = "bag",
	version = "1",
	tick_hz = 64,
	tick = proc(t: ^sim.Tick(Bag_Game)) {},
}

// find_nan names a Queue's item oldest first, as the desync report does.
@(test)
find_nan_names_a_queue_item_as_the_diff_does :: proc(t: ^testing.T) {
	simulation := sim.create(&NAN_QUEUE_GAME, 1)
	defer sim.destroy(simulation)
	inputs: sim.Inputs(Nan_Queue_Game)
	sim.step(simulation, &inputs)
	before := simulation.state
	sim.step(simulation, &inputs)
	lines, _ := sim.state_changes(type_info_of(Nan_Queue_State), &before, &simulation.state)
	diff_names_second := false
	for line in lines do diff_names_second ||= strings.has_prefix(line, "queue[1]")
	floats: [dynamic]u32
	defer delete(floats)
	nan := sim.find_nan(simulation, &floats)
	testing.expectf(t, diff_names_second, "the diff names the NaN as queue[1] (oldest first): %v", lines)
	testing.expectf(t, strings.contains(nan, "queue[1] "), "find_nan names it %q", nan)
}

Nan_Queue_State :: struct {
	queue:   sim.Queue(f32, 4),
	players: sim.Players(u32, sim.No_Profile, toy.Input, 1),
}

Nan_Queue_Game :: sim.Game(
	Nan_Queue_State,
	toy.Input,
	sim.No_World,
	toy.Event,
	sim.No_Commands,
	sim.No_Setup,
	sim.No_Profile,
	1,
)

NAN_QUEUE_GAME := Nan_Queue_Game {
	name = "nan_queue",
	version = "1",
	tick_hz = 64,
	tick = proc(t: ^sim.Tick(Nan_Queue_Game)) {
		switch t.number {
		case 1:
			sim.append(&t.state.queue, 1)
			sim.append(&t.state.queue, 2)
			sim.append(&t.state.queue, 3)
		case 2:
			sim.pop_front(&t.state.queue)
			sim.pop_front(&t.state.queue) // head 2: items[2] = 3 is the oldest
			sim.append(&t.state.queue, transmute(f32)u32(0x7FC0_0000)) // items[3]: the queue's second item
		}
	},
}
