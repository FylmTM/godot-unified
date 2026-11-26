// The character's golden trace: our own physics code (the character, kinematic paths, the Extra's hash)
// pinned on every platform, like Box3D's results are in box3d_test.odin (BOX3D_GOLDEN); and what every golden trace
// here is checked with (golden_check), on the library they were pinned on (GOLDEN_LIBRARY).
package test_physics

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

import "unified:headless/scenarios"
import "unified:physics"
import "unified:sim"

// The library the golden traces were pinned on: sim.LIBRARY_VERSION and the unified-box3d pin. A golden that moves
// on this library moved without a bump, which golden_check refuses (the library-sim-change skill).
GOLDEN_LIBRARY :: sim.Library {
	version = 2,
	box3d   = "3362633-r6",
}

// The library this build is.
@(private = "file")
library_now :: proc() -> sim.Library {
	return {version = sim.LIBRARY_VERSION, box3d = sim.box3d_pin()}
}

@(private = "file")
library_literal :: proc(library: sim.Library) -> string {
	return fmt.tprintf(
		"GOLDEN_LIBRARY :: sim.Library {{\n\tversion = %d,\n\tbox3d   = %q,\n}}",
		library.version,
		library.box3d,
	)
}

// A golden trace as its literal reads, `{0x..., ...}`: printed to paste, re-pinned as is.
@(private = "file")
golden_literal :: proc(hashes: []u64) -> string {
	text := strings.builder_make(context.temp_allocator)
	strings.write_byte(&text, '{')
	for hash, k in hashes {
		fmt.sbprintf(&text, "%s0x%016x", k > 0 ? ", " : "", hash)
	}
	strings.write_byte(&text, '}')
	return strings.to_string(text)
}

// The goldens are pinned on this build's library: after a bump (sim.LIBRARY_VERSION, the unified-box3d pin),
// `uni test --bless` re-pins GOLDEN_LIBRARY with the goldens that moved.
@(test)
goldens_are_pinned_on_this_library :: proc(t: ^testing.T) {
	now := library_now()
	if now.version == GOLDEN_LIBRARY.version && now.box3d == GOLDEN_LIBRARY.box3d do return
	if scenarios.BLESS {
		scenarios.bless_pin(t, "GOLDEN_LIBRARY", library_literal(GOLDEN_LIBRARY), library_literal(now))
		return
	}
	testing.expectf(
		t,
		false,
		"the golden traces were pinned on another library; after a meant bump: ./uni test --bless (the " +
		"library-sim-change skill). This build:\n%s",
		library_literal(now),
	)
}

// A golden trace's check: `got` is `pinned` (golden_verdict). A trace that moved fails, printing its new literal;
// under --bless (scenarios.BLESS) it is re-pinned instead (scenarios.bless_pin), unless this build is still
// GOLDEN_LIBRARY: a change that moves a golden bumps sim.LIBRARY_VERSION (or the unified-box3d pin), so that is
// refused, naming the values that moved. `what` names the trace in the messages.
golden_check :: proc(t: ^testing.T, what: string, got, pinned: []u64, loc := #caller_location) {
	pinned_on := GOLDEN_LIBRARY
	switch golden_verdict(pinned, got, pinned_on, library_now(), scenarios.BLESS) {
	case .Same, .Unpinned, .Predates:
	case .Refuse:
		// no literal: pasting it would pin the trace on the library that pinned the old one
		testing.expectf(
			t,
			false,
			"%s: the golden trace moved on the library it was pinned on (GOLDEN_LIBRARY): %s. A meant change to " +
			"src/physics, src/sim, src/dmath, Box3D, Odin or the build flags bumps sim.LIBRARY_VERSION, and then " +
			"./uni test --bless re-pins it (the library-sim-change skill); else find the cause",
			what,
			golden_moved(pinned, got),
			loc = loc,
		)
	case .Repin:
		scenarios.bless_pin(t, what, golden_literal(pinned), golden_literal(got), loc)
	case .Fail:
		testing.expectf(
			t,
			false,
			"%s: the golden trace moved. If the change was meant: ./uni test --bless (the library-sim-change " +
			"skill). The run now: %s",
			what,
			golden_literal(got),
			loc = loc,
		)
	}
}

// What golden_check does when a trace pinned on `pinned_on` gives `got` on `now` (scenarios.pin_verdict): every
// value of the trace is a result, the library its identity.
golden_verdict :: proc(pinned, got: []u64, pinned_on, now: sim.Library, bless: bool) -> scenarios.Pin_Verdict {
	moved := !slice.equal(pinned, got)
	return scenarios.pin_verdict(
		true,
		results_moved = moved,
		anything_moved = moved,
		identity_moved = pinned_on.version != now.version || pinned_on.box3d != now.box3d,
		bless = bless,
	)
}

// The values of a trace that moved, "[1] 0x... -> 0x..., ..." (temp-allocated).
@(private = "file")
golden_moved :: proc(pinned, got: []u64) -> string {
	text := strings.builder_make(context.temp_allocator)
	for value, k in got {
		if k < len(pinned) && pinned[k] == value do continue
		was := k < len(pinned) ? pinned[k] : 0
		fmt.sbprintf(&text, "%s[%d] 0x%016x -> 0x%016x", strings.builder_len(text) > 0 ? ", " : "", k, was, value)
	}
	return strings.to_string(text)
}

// The scene's block: what a game would keep. Its bytes and the Extra's hash make each value of the trace.
Golden :: struct {
	rider:    physics.Character, // stands on the platform for a whole path cycle
	walker:   physics.Character, // walks over a step and jumps
	target:   physics.Character, // stands, is hit by a heavy box, gets up again
	platform: physics.Body_Ref,
	thrown:   physics.Body_Ref,
}

GOLDEN_TICKS :: 512 // 8 s: the platform's whole ping-pong cycle
GOLDEN_EVERY :: 128

// A change to src/physics, Box3D or the build flags that alters any of these fails here (golden_check).
GOLDEN_CHARACTERS :: [GOLDEN_TICKS / GOLDEN_EVERY]u64 {
	0x32f947e417397067,
	0x2d9dc705fab02713,
	0x8c926e4adaa3b712,
	0xce7977c821247cd3,
}

// On 1 and on 4 workers: the same values.
@(test)
character_golden_trace :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.plain_violation(type_info_of(Golden)), "")
	for workers in ([]i32{1, 4}) {
		character_golden(t, workers)
	}
}

character_golden :: proc(t: ^testing.T, workers: i32) {
	world := new_world(workers)
	defer physics.destroy(world)
	ground(world)
	box(world, {-4, 0.15, 0}, {1, 0.15, 1}) // a 0.3 m step on the walker's way
	state: Golden
	state.platform, _ = box(world, RIG_PATH.points[0], {1.5, 0.25, 1.5}, .Kinematic, category = CAT_PLATFORM)
	physics.character_create(world, &state.rider, character_def(), {0, 1.6, 6})
	physics.character_create(world, &state.walker, character_def(), {-8, 1.5, 0})
	physics.character_create(world, &state.target, character_def(), {4, 1.5, -2})
	extra := physics.extra(world, Golden)

	got: [len(GOLDEN_CHARACTERS)]u64
	buf := make([dynamic]u8, context.temp_allocator)
	jumped, rode := false, true
	target_x0: f32
	for tick in 1 ..= GOLDEN_TICKS {
		physics.drive_kinematic(world, state.platform, physics.path_sample(&RIG_PATH, u32(tick), HZ))
		physics.character_update(world, &state.rider, character_def(), {}, false, 1)
		// The walker heads +x over the step, jumps twice, then turns back.
		walk := tick < 300 ? [2]f32{0.6, 0} : [2]f32{-0.6, 0.3}
		physics.character_update(world, &state.walker, character_def(), walk, tick == 160 || tick == 360, 1)
		physics.character_update(world, &state.target, character_def(), {}, false, 1)
		if tick == 64 {
			// A heavy box (about the character's mass) at 14 m/s: the drive's force cap gives way.
			state.thrown, _ = box(world, {1, 1.4, -2}, {0.3, 0.3, 0.3}, .Dynamic, category = CAT_BOX, density = 400)
			physics.body_set_linear_velocity(world, state.thrown, {14, 0, 0})
			target_x0 = physics.body_position(world, state.target.body).x
		}
		steps(world, 1)
		jumped ||= tick > 160 && !physics.character_grounded(&state.walker)
		if tick > 32 {
			rode &&= state.rider.ground == physics.link(state.platform)
		}
		if tick % GOLDEN_EVERY == 0 {
			clear(&buf)
			append(&buf, ..([^]u8)(&state)[:size_of(state)])
			extra.hash(extra.data, u32(tick), &buf)
			got[tick / GOLDEN_EVERY - 1] = sim.hash_bytes(buf[:])
		}
	}
	// The scene does what it is for, so the trace covers walking, jumping, riding and being pushed.
	testing.expect(t, jumped, "the walker never left the ground")
	testing.expect(t, rode, "the rider left the platform")
	testing.expect(t, physics.body_position(world, state.walker.body).y > 1.1, "the walker fell through")
	pushed := physics.body_position(world, state.target.body).x - target_x0
	testing.expectf(t, pushed > 0.1, "the target was pushed only %v m", pushed)
	testing.expect(t, physics.character_grounded(&state.target), "the target did not get up again")
	pinned := GOLDEN_CHARACTERS
	golden_check(t, fmt.tprintf("GOLDEN_CHARACTERS (%d workers)", workers), got[:], pinned[:])
}

// Bodies on a level mesh and a height field (the terrain fixture: crates on its conveyor deck, balls down its hill),
// checksummed on the deep-checksum ticks (the whole world, its baked geometry included): the pin that every platform
// collides with mesh BVHs and height fields alike, which no box-only golden or shipped level covers. Update it in
// the same commit as a change that is meant to alter it.
GOLDEN_TERRAIN :: [4]u64{0x20c29c903b979abe, 0x8ec8692c6586b5fd, 0xd45b1bc231948c51, 0x04edeff9d99dc47f}

@(test)
terrain_golden_trace :: proc(t: ^testing.T) {
	simulation := sim.create(&TERRAIN, 5)
	defer sim.destroy(simulation)
	got: [4]u64
	for tick in u32(1) ..= 128 {
		inputs := sim.Inputs(Terrain_Game) {
			present = {0, 1},
		}
		sim.step(simulation, &inputs)
		if tick % 32 == 0 do got[tick / 32 - 1] = sim.checksum(simulation)
	}
	pinned := GOLDEN_TERRAIN
	golden_check(t, "GOLDEN_TERRAIN", got[:], pinned[:])
}

// What golden_check does (golden_verdict): a trace that moved on the library it was pinned on is refused even under
// --bless; on another library it re-pins under --bless and fails without it.
@(test)
a_golden_verdict_follows_the_library :: proc(t: ^testing.T) {
	pinned := []u64{1, 2, 3, 4}
	moved := []u64{1, 2, 30, 4}
	library := sim.Library {
		version = 1,
		box3d   = "a-r1",
	}
	bumped := sim.Library {
		version = 2,
		box3d   = "a-r1",
	}
	upgraded := sim.Library {
		version = 1,
		box3d   = "b-r1",
	}
	for bless in ([]bool{false, true}) {
		repinned: scenarios.Pin_Verdict = bless ? .Repin : .Fail
		testing.expect_value(t, golden_verdict(pinned, pinned, library, library, bless), scenarios.Pin_Verdict.Same)
		testing.expect_value(t, golden_verdict(pinned, pinned, library, bumped, bless), scenarios.Pin_Verdict.Same)
		testing.expect_value(t, golden_verdict(pinned, moved, library, library, bless), scenarios.Pin_Verdict.Refuse)
		testing.expect_value(t, golden_verdict(pinned, moved, library, bumped, bless), repinned)
		testing.expect_value(t, golden_verdict(pinned, moved, library, upgraded, bless), repinned)
	}
}
