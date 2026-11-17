// The character's golden trace: our own physics code (the character, kinematic paths, the Extra's hash)
// pinned on every platform, like Box3D's results are in tests/b3 (GOLDEN there).
package test_physics

import "core:testing"

import "unified:physics"
import "unified:sim"

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

// A change to src/physics, Box3D or the build flags that alters any of these fails here. If the
// change is intended, update the values in the same commit (with tests/b3's GOLDEN and the
// games' reference runs when they change too).
GOLDEN_CHARACTERS := [GOLDEN_TICKS / GOLDEN_EVERY]u64 {
	0x82a758bfac90b21f,
	0xe1fd6c627ffd6815,
	0x6197a25c12088a1e,
	0xcdb5e608c03aba83,
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
	state.platform = box(world, RIG_PATH.points[0], {1.5, 0.25, 1.5}, .Kinematic_Body, cat = CAT_PLATFORM)
	physics.character_create(world, &state.rider, &CHARACTER, {0, 1.6, 6})
	physics.character_create(world, &state.walker, &CHARACTER, {-8, 1.5, 0})
	physics.character_create(world, &state.target, &CHARACTER, {4, 1.5, -2})
	extra := physics.extra(world, Golden)

	got: [len(GOLDEN_CHARACTERS)]u64
	buf := make([dynamic]u8, context.temp_allocator)
	jumped, rode := false, true
	target_x0: f32
	for tick in 1 ..= GOLDEN_TICKS {
		physics.drive_kinematic(world, state.platform, physics.path_sample(&RIG_PATH, u32(tick), HZ), HZ)
		physics.character_update(world, &state.rider, &CHARACTER, {}, false, 1, DT)
		// The walker heads +x over the step, jumps twice, then turns back.
		walk := tick < 300 ? [2]f32{0.6, 0} : [2]f32{-0.6, 0.3}
		physics.character_update(world, &state.walker, &CHARACTER, walk, tick == 160 || tick == 360, 1, DT)
		physics.character_update(world, &state.target, &CHARACTER, {}, false, 1, DT)
		if tick == 64 {
			// A heavy box (about the character's mass) at 14 m/s: the drive's force cap gives way.
			state.thrown = box(world, {1, 1.4, -2}, {0.3, 0.3, 0.3}, .Dynamic_Body, cat = CAT_BOX, density = 400)
			physics.body_set_linear_velocity(world, state.thrown, {14, 0, 0})
			target_x0 = physics.body_position(world, state.target.body).x
		}
		step(world)
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
	testing.expectf(
		t,
		got == GOLDEN_CHARACTERS,
		"character golden trace on %d workers changed: %x (pinned %x). If the change to src/physics, Box3D or the build flags is intended, update GOLDEN_CHARACTERS in tests/physics/golden_test.odin in the same commit",
		workers,
		got,
		GOLDEN_CHARACTERS,
	)
}
