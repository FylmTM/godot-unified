// The mover's golden trace: our own physics code (the mover, kinematic paths, the Extra's hash)
// pinned on every platform, like Box3D's results are in tests/box3d (GOLDEN there).
package test_physics

import "core:testing"

import "unified:physics"
import "unified:sim"

// The scene's block: what a game would keep. Its bytes and the Extra's hash (every referenced
// body's pose and velocities) make each value of the trace.
Golden :: struct {
	rider:    physics.Mover, // stands on the platform for a whole path cycle
	walker:   physics.Mover, // walks over a step and jumps
	target:   physics.Mover, // stands, is hit by a heavy box, gets up again
	platform: physics.Body_Ref,
	thrown:   physics.Body_Ref,
}

GOLDEN_TICKS :: 512 // 8 s: the platform's whole ping-pong cycle
GOLDEN_EVERY :: 128

// A change to src/physics, Box3D or the build flags that alters any of these fails here. If the
// change is intended, update the values in the same commit (with tests/box3d's GOLDEN and the
// games' reference runs when they change too).
GOLDEN_MOVERS := [GOLDEN_TICKS / GOLDEN_EVERY]u64 {
	0xc6fbc220c82ebad2,
	0xaf656bbf14eeec50,
	0xb18bbeed772fcf7a,
	0x492e32dfe79899ff,
}

@(test)
mover_golden_trace :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.plain_violation(type_info_of(Golden)), "")
	w := new_world()
	defer physics.destroy(w)
	ground(w)
	box(w, {-4, 0.15, 0}, {1, 0.15, 1}) // a 0.3 m step on the walker's way
	s: Golden
	s.platform = physics.ref_of(box(w, RIG_PATH.points[0], {1.5, 0.25, 1.5}, .kinematicBody, cat = CAT_PLATFORM))
	physics.mover_create(w, &s.rider, &MOVER, {0, 1.6, 6})
	physics.mover_create(w, &s.walker, &MOVER, {-8, 1.5, 0})
	physics.mover_create(w, &s.target, &MOVER, {4, 1.5, -2})
	e := physics.extra(w, Golden)

	got: [len(GOLDEN_MOVERS)]u64
	buf := make([dynamic]u8, context.temp_allocator)
	jumped, rode := false, true
	target_x0: f32
	for tk in 1 ..= GOLDEN_TICKS {
		physics.drive_kinematic(w, s.platform, physics.path_sample(&RIG_PATH, u32(tk), HZ), HZ)
		physics.mover_update(w, &s.rider, &MOVER, {}, false, 1, DT)
		// The walker heads +x over the step, jumps twice, then turns back.
		walk := tk < 300 ? [2]f32{0.6, 0} : [2]f32{-0.6, 0.3}
		physics.mover_update(w, &s.walker, &MOVER, walk, tk == 160 || tk == 360, 1, DT)
		physics.mover_update(w, &s.target, &MOVER, {}, false, 1, DT)
		if tk == 64 {
			// A heavy box (about the mover's mass) at 14 m/s: the drive's force cap gives way.
			s.thrown = physics.ref_of(
				box(w, {1, 1.4, -2}, {0.3, 0.3, 0.3}, .dynamicBody, cat = CAT_BOX, density = 400),
			)
			physics.set_velocity(w, s.thrown, {14, 0, 0})
			target_x0 = physics.position(w, s.target.body).x
		}
		step(w)
		jumped ||= tk > 160 && !physics.mover_grounded(&s.walker)
		if tk > 32 {
			rode &&= s.rider.ground == physics.link(s.platform)
		}
		if tk % GOLDEN_EVERY == 0 {
			clear(&buf)
			append(&buf, ..([^]u8)(&s)[:size_of(s)])
			e.hash(e.data, &s, u32(tk), &buf)
			got[tk / GOLDEN_EVERY - 1] = sim.hash_bytes(buf[:])
		}
	}
	// The scene does what it is for, so the trace covers walking, jumping, riding and being pushed.
	testing.expect(t, jumped, "the walker never left the ground")
	testing.expect(t, rode, "the rider left the platform")
	testing.expect(t, physics.position(w, s.walker.body).y > 1.1, "the walker fell through")
	pushed := physics.position(w, s.target.body).x - target_x0
	testing.expectf(t, pushed > 0.1, "the target was pushed only %v m", pushed)
	testing.expect(t, physics.mover_grounded(&s.target), "the target did not get up again")
	testing.expectf(
		t,
		got == GOLDEN_MOVERS,
		"mover golden trace changed: %x (pinned %x). If the change to src/physics, Box3D or the build flags is intended, update GOLDEN_MOVERS in tests/physics/golden_test.odin in the same commit",
		got,
		GOLDEN_MOVERS,
	)
}
