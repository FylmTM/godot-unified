// A sync-test at the library layer, so a Box3D upgrade is proven here before physics' tests run: a stack settles
// and falls asleep, a push wakes it, and the run rolls back SYNC_WINDOW ticks after every tick and re-simulates.
// Every re-simulated tick must hash (the whole world, and the awake bodies) as a straight run with one worker does,
// on 1 and 4 workers, so both transitions happen inside rollback windows and the worker count changes nothing.
package test_b3

import "core:testing"

import box3d "box3d:bindings"
import "unified:b3"
import "unified:physics"

SYNC_TICKS :: 320
SYNC_WINDOW :: 8
WAKE_TICK :: 200 // the push; the stack is asleep before it

Sync_Scene :: struct {
	phys:  ^physics.World,
	stack: [4]b3.Body_Id,
}

// Both hashes after a tick: the deep one peers compare and the cheap one physics checks between.
Sync_Hash :: [2]u64

sync_scene_make :: proc(workers: i32) -> Sync_Scene {
	scene := Sync_Scene {
		phys = physics.create({workers = workers}),
	}
	box_body(scene.phys.id, .Static_Body, {0, -0.5, 0}, {10, 0.5, 10})
	for &body, i in scene.stack {
		body = box_body(scene.phys.id, .Dynamic_Body, {0, 0.5 + f32(i) * 1.01, 0}, {0.5, 0.5, 0.5})
	}
	return scene
}

// One tick: the input is a function of the tick (a push on the top box at WAKE_TICK), then the step.
sync_tick :: proc(scene: ^Sync_Scene, tick: int) {
	if tick == WAKE_TICK {
		b3.body_apply_linear_impulse_to_center(scene.stack[3], {3, 0, 1}, true)
	}
	b3.world_step(scene.phys.id, DT, SUBSTEPS)
}

sync_hash :: proc(scene: ^Sync_Scene) -> Sync_Hash {
	return {b3.world_hash_state(scene.phys.id), b3.world_hash_awake_bodies(scene.phys.id)}
}

stack_awake :: proc(scene: ^Sync_Scene) -> bool {
	for body in scene.stack {
		if box3d.Body_IsAwake(body) do return true
	}
	return false
}

// The straight run: each tick's hashes, and whether the stack was awake after it.
sync_reference :: proc(reference: ^[SYNC_TICKS]Sync_Hash, awake: ^[SYNC_TICKS]bool) {
	scene := sync_scene_make(1)
	defer physics.destroy(scene.phys)
	for tick in 0 ..< SYNC_TICKS {
		sync_tick(&scene, tick)
		reference[tick] = sync_hash(&scene)
		awake[tick] = stack_awake(&scene)
	}
}

// The rollback run on `workers`: returns how many re-simulated ticks hashed differently from the reference.
sync_rollback :: proc(workers: i32, reference: ^[SYNC_TICKS]Sync_Hash) -> (mismatches: int) {
	scene := sync_scene_make(workers)
	defer physics.destroy(scene.phys)
	ring: [SYNC_WINDOW + 1]b3.World_Snapshot // the state before each tick of the window
	defer for &snapshot in ring do b3.destroy_world_snapshot(&snapshot)
	for tick in 0 ..< SYNC_TICKS {
		b3.world_save_snapshot(scene.phys.id, &ring[tick % len(ring)])
		sync_tick(&scene, tick)
		if sync_hash(&scene) != reference[tick] do mismatches += 1
		from := max(0, tick + 1 - SYNC_WINDOW)
		if !b3.world_restore_snapshot(scene.phys.id, &ring[from % len(ring)]) do return SYNC_TICKS
		for resim in from ..= tick {
			if resim > from do b3.world_save_snapshot(scene.phys.id, &ring[resim % len(ring)])
			sync_tick(&scene, resim)
			if sync_hash(&scene) != reference[resim] do mismatches += 1
		}
	}
	return
}

@(test)
sync_test_sleep_and_wake :: proc(t: ^testing.T) {
	reference: [SYNC_TICKS]Sync_Hash
	awake: [SYNC_TICKS]bool
	sync_reference(&reference, &awake)
	// The scene does what the test is for: the stack falls asleep before the push and wakes with it.
	fell_asleep := -1
	for tick in 1 ..< WAKE_TICK {
		if awake[tick - 1] && !awake[tick] do fell_asleep = tick
	}
	testing.expectf(
		t,
		fell_asleep > 0 && !awake[WAKE_TICK - 1],
		"the stack never fell asleep before tick %d",
		WAKE_TICK,
	)
	testing.expect(t, awake[WAKE_TICK], "the push didn't wake the stack")
	for workers in ([]i32{1, 4}) {
		mismatches := sync_rollback(workers, &reference)
		testing.expectf(t, mismatches == 0, "%d workers: %d re-simulated ticks differ", workers, mismatches)
	}
}
