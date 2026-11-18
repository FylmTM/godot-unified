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
	// an empty tick costs one byte for its command count and one for its join count; a command, 3 bytes plus its
	// struct; a join record 3
	command_bytes := 10 * (2 * sim.COMMAND_HEAD + size_of(toy.Cmd_Bump) + size_of(toy.Cmd_Mark))
	tick_bytes := 10 + size_of([toy.PLAYERS]toy.Input)
	testing.expect_value(t, len(data), sim.LOG_HEADER + 50 * tick_bytes + command_bytes + 2 * sim.JOIN_BYTES)
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
// layout or block size, other content, another build (game version, library), a damaged payload, an Extra's image
// the game can't take. Logs of another format version are refused too.
@(test)
snapshot_errors_are_values :: proc(t: ^testing.T) {
	level := []u8{1, 2, 3}
	simulation := sim.create(&toy.GAME, 7, level)
	defer sim.destroy(simulation)
	run(simulation, 20, 3)
	good := sim.snapshot_encode(simulation, 20)
	defer delete(good)
	other_version := toy.GAME
	other_version.version = "another"
	imaging := imaging_game()
	with_image := sim.create(&imaging, 7, level)
	defer sim.destroy(with_image)
	image_snapshot := sim.snapshot_encode(with_image, 0)
	defer delete(image_snapshot)
	Case :: struct {
		what:    string,
		game:    ^toy.Game,
		content: []u8,
		patch:   proc(data: []u8),
		bytes:   []u8, // instead of a patched copy of `good`
		want:    sim.Snap_Error,
	}
	cases := []Case {
		{"intact", &toy.GAME, level, nil, nil, .None},
		{"cut short", &toy.GAME, level, nil, good[:10], .Bad_Header},
		{"another magic", &toy.GAME, level, proc(data: []u8) {data[0] = 'X'}, nil, .Bad_Header},
		{
			"another format version",
			&toy.GAME,
			level,
			proc(data: []u8) {data[4] = u8(sim.SNAP_VERSION - 1)},
			nil,
			.Bad_Header,
		},
		{"another layout", &toy.GAME, level, proc(data: []u8) {data[sim.SNAP_HEADER - 17] ~= 1}, nil, .Layout_Differs},
		{
			"another block size",
			&toy.GAME,
			level,
			proc(data: []u8) {data[sim.SNAP_HEADER - 28] ~= 4},
			nil,
			.Layout_Differs,
		},
		{"other content", &toy.GAME, []u8{1, 2, 4}, nil, nil, .Content_Differs},
		{"no content", &toy.GAME, nil, nil, nil, .Content_Differs},
		{"another game version", &other_version, level, nil, nil, .Build_Differs},
		{
			"another library version",
			&toy.GAME,
			level,
			proc(data: []u8) {
				another := transmute([8]u8)u64le(
					sim.compat_of(&toy.GAME, []u8{1, 2, 3}, {version = sim.LIBRARY_VERSION + 1}),
				)
				copy(data[sim.SNAP_HEADER - 16:], another[:]) // the compat, before the payload digest
			},
			nil,
			.Build_Differs,
		},
		{"a damaged payload", &toy.GAME, level, proc(data: []u8) {data[len(data) - 1] ~= 1}, nil, .Checksum_Mismatch},
		{"an image the game has no Extra for", &toy.GAME, level, nil, image_snapshot, .Extra_Rejected},
	}
	for test_case in cases {
		data := slice.clone(test_case.bytes != nil ? test_case.bytes : good)
		defer delete(data)
		if test_case.patch != nil do test_case.patch(data)
		restored, err := sim.from_snapshot(test_case.game, data, test_case.content)
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
