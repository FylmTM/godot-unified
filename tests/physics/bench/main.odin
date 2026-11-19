// The physics row of `uni bench`: unified:physics apart from any game, so a Box3D or physics change that slows one
// operation shows here rather than as a small shift in a game's total. Everything goes through the plug-in, as the
// netcode runs it (physics.extra: the body table with the snapshot, the hashes a session uses).
//
// A pile: boxes stacked like bricks (each layer offset by half a box), so every box rests on four below and contacts
// cross the whole pile; kept awake. Every tick: a step, a save into a ring slot, the deep hash (the ticks peers
// compare), the awake-bodies hash (the other ticks), a restore of that slot (it must give the same hash back), and a
// batch of rays down onto the pile. Every IMAGE_EVERY ticks: a portable image of the slot as of a past tick (the world
// swapped out and back) and as the live tick (no swap; the same bytes), and its load into a second world (a late
// join; the loaded world must hash the same). Then 64 characters on a slab: their character_updates per
// tick, apart from the step. Then the capacity against the frame budget: a smaller pile (ROLLBACK_SIDE³ boxes, sized
// to the bench's time; the bodies that would fit the budget scale from it) steps and, every tick, rolls back as the netcode does at its prediction cap (a restore,
// CAP steps with a save every 2nd tick, a deep hash: it must hash as the forward tick did), on 1 and 4 workers. Then a
// large generated level (level.odin). One JSON line.
package physics_bench

import "core:fmt"
import "core:os"
import "core:slice"
import "core:time"

import "unified:physics"
import "unified:sim"

TICK_HZ :: 64
BODIES_SIDE :: 8 // 8 layers of 8 x 8: 512 boxes
BODIES :: BODIES_SIDE * BODIES_SIDE * BODIES_SIDE
HALF :: f32(0.25)
SETTLE_TICKS :: 64 // not measured: the pile lands
TICKS :: 600
RAYS :: 64 // per tick, straight down onto the pile
RING :: 16
IMAGE_EVERY :: 16
CHARACTERS :: 64
CHARACTER_TICKS :: 300
// The capacity pile: 125 boxes (the cost per body is flat from 64 to 216), for enough ticks that the p90 the capacity
// scales from leaves out the slowest ten (preempted samples on a busy machine).
ROLLBACK_SIDE :: 5
ROLLBACK_TICKS :: 100
CAP :: 14 // the netcode's prediction cap at 64 Hz (headless.prediction_window): the deepest rollback it makes

Stat :: struct {
	mean, p99: f64,
}

stat_of :: proc(samples: []f64) -> Stat {
	sum := 0.0
	for sample in samples do sum += sample
	slice.sort(samples)
	return {sum / f64(len(samples)), samples[max((99 * len(samples) + 99) / 100 - 1, 0)]}
}

stat_json :: proc(samples: []f64) -> string {
	stat := stat_of(samples)
	return fmt.tprintf(`{{"mean":%.2f,"p99":%.2f}}`, stat.mean, stat.p99)
}

micros :: proc(from, to: time.Tick) -> f64 {
	return time.duration_microseconds(time.tick_diff(from, to))
}

// No block: every body is the World's (made before `extra`).
No_State :: struct {}

pile_world :: proc(side := BODIES_SIDE, workers: i32 = 1) -> ^physics.World {
	world := physics.create({tick_hz = TICK_HZ, workers = workers})
	physics.create_box(world, physics.body_def(.Static, {0, -0.5, 0}), physics.shape_def(1), {30, 0.5, 30})
	shape_def := physics.shape_def(1)
	shape_def.density = 1
	for y in 0 ..< side {
		offset := f32(y % 2) * HALF // bricks: each layer half a box over
		for x in 0 ..< side {
			for z in 0 ..< side {
				pos := [3]f32{f32(x) * 2 * HALF - 2 + offset, HALF + f32(y) * 2 * HALF, f32(z) * 2 * HALF - 2 + offset}
				body_def := physics.body_def(.Dynamic, pos)
				body_def.enable_sleep = false // every tick costs the same: the whole pile stays awake
				physics.create_box(world, body_def, shape_def, {HALF, HALF, HALF})
			}
		}
	}
	return world
}

hash_of :: proc(extra: sim.Extra, tick: u32, buffer: ^[dynamic]u8) -> []u8 {
	clear(buffer)
	extra.hash(extra.data, tick, buffer)
	return buffer[:]
}

main :: proc() {
	world := pile_world()
	defer physics.destroy(world)
	extra := physics.extra(world, No_State)
	late := pile_world() // the late joiner's world, loaded from images
	defer physics.destroy(late)
	late_extra := physics.extra(late, No_State)
	for _ in 0 ..< SETTLE_TICKS do physics.step(world)

	step_us, save_us, deep_us, shallow_us, restore_us, rays_us: [TICKS]f64
	image_us, image_live_us, load_us: [(TICKS + IMAGE_EVERY - 1) / IMAGE_EVERY]f64
	deep, again, loaded, past: [dynamic]u8
	defer delete(deep)
	defer delete(again)
	defer delete(loaded)
	defer delete(past)
	mismatches, hits, image_bytes := 0, 0, 0
	for tick in 0 ..< TICKS {
		slot := tick % RING
		start := time.tick_now()
		physics.step(world)
		stepped := time.tick_now()
		extra.save(extra.data, slot)
		saved := time.tick_now()
		hash_of(extra, 0, &deep) // a multiple of sim.DEEP_CHECKSUM_EVERY: the whole world
		deep_hashed := time.tick_now()
		hash_of(extra, 1, &again) // the awake bodies
		shallow_hashed := time.tick_now()
		restored_ok := extra.restore(extra.data, slot)
		restored := time.tick_now()
		for ray in 0 ..< RAYS {
			origin := [3]f32{f32(ray % 8) * 0.5 - 2, 20, f32(ray / 8) * 0.5 - 2}
			if _, ok := physics.world_cast_ray_closest(world, origin, {0, -30, 0}); ok do hits += 1
		}
		rays_done := time.tick_now()
		if !restored_ok || !slice.equal(hash_of(extra, 0, &again), deep[:]) {
			mismatches += 1 // a restore that doesn't give the saved world back
		}
		step_us[tick] = micros(start, stepped)
		save_us[tick] = micros(stepped, saved)
		deep_us[tick] = micros(saved, deep_hashed)
		shallow_us[tick] = micros(deep_hashed, shallow_hashed)
		restore_us[tick] = micros(shallow_hashed, restored)
		rays_us[tick] = micros(restored, rays_done)
		if tick % IMAGE_EVERY == 0 {
			image_start := time.tick_now()
			swapped := extra.image(extra.data, slot, false)
			imaged := time.tick_now()
			clear(&past)
			append(&past, ..swapped)
			live_start := time.tick_now()
			image := extra.image(extra.data, slot, true)
			live_imaged := time.tick_now()
			load_ok := late_extra.load(late_extra.data, image)
			load_done := time.tick_now()
			image_bytes = len(image)
			if !slice.equal(past[:], image) do mismatches += 1 // the live image must be the slot's
			if !load_ok || !slice.equal(hash_of(late_extra, 0, &loaded), deep[:]) do mismatches += 1
			image_us[tick / IMAGE_EVERY] = micros(image_start, imaged)
			image_live_us[tick / IMAGE_EVERY] = micros(live_start, live_imaged)
			load_us[tick / IMAGE_EVERY] = micros(live_imaged, load_done)
		}
	}
	snapshot_bytes := extra.size(extra.data, (TICKS - 1) % RING)
	characters_us := run_characters()
	one, one_mismatches := run_rollback(1)
	four, four_mismatches := run_rollback(4)
	large_level := run_large_levels()
	mismatches += one_mismatches + four_mismatches
	fmt.printfln(
		`{{"mode":"physics-bench","bodies":%d,"ticks":%d,"rays":%d,"characters":%d,"step_us":%s,"save_us":%s,"hash_deep_us":%s,"hash_us":%s,"restore_us":%s,"rays_us":%s,"image_us":%s,"image_live_us":%s,"load_us":%s,"characters_us":%s,"snapshot_bytes":%d,"image_bytes":%d,"ray_hits":%d,"rollback":{{"bodies":%d,"cap":%d,"workers_1":%s,"workers_4":%s}},"large_level":%s,"mismatches":%d}}`,
		BODIES,
		TICKS,
		RAYS,
		CHARACTERS,
		stat_json(step_us[:]),
		stat_json(save_us[:]),
		stat_json(deep_us[:]),
		stat_json(shallow_us[:]),
		stat_json(restore_us[:]),
		stat_json(rays_us[:]),
		stat_json(image_us[:]),
		stat_json(image_live_us[:]),
		stat_json(load_us[:]),
		stat_json(characters_us[:]),
		snapshot_bytes,
		image_bytes,
		hits,
		ROLLBACK_SIDE * ROLLBACK_SIDE * ROLLBACK_SIDE,
		CAP,
		one,
		four,
		large_level,
		mismatches,
	)
	if mismatches > 0 do os.exit(1)
}

// The pile of ROLLBACK_SIDE³ boxes on `workers` threads: each tick a forward step and its save, then the rollback the
// netcode makes at its cap: restore the tick CAP back, step CAP ticks saving every 2nd (and the last), deep-hash the
// result, which must be the forward tick's. Returns {"step_us","rollback_us","step_plus_rollback_p99_us",
// "step_plus_rollback_p90_us"} and the ticks whose re-simulation hashed otherwise. The p90 of each tick's step plus its
// rollback is what the capacity scales from: the p99 of 100 ticks is their second slowest, which two preempted samples
// on a busy machine decide.
run_rollback :: proc(workers: i32) -> (json: string, mismatches: int) {
	world := pile_world(ROLLBACK_SIDE, workers)
	defer physics.destroy(world)
	extra := physics.extra(world, No_State)
	for _ in 0 ..< SETTLE_TICKS do physics.step(world)
	for tick in 0 ..= CAP {
		physics.step(world)
		extra.save(extra.data, tick % RING)
	}
	forward, again: [dynamic]u8
	defer delete(forward)
	defer delete(again)
	step_us, rollback_us, both_us: [ROLLBACK_TICKS]f64
	for k in 0 ..< ROLLBACK_TICKS {
		tick := CAP + 1 + k
		start := time.tick_now()
		physics.step(world)
		extra.save(extra.data, tick % RING)
		stepped := time.tick_now()
		hash_of(extra, 0, &forward)
		resumed := time.tick_now()
		if !extra.restore(extra.data, (tick - CAP) % RING) do mismatches += 1
		for back in 1 ..= CAP {
			physics.step(world)
			if back % 2 == 0 || back == CAP do extra.save(extra.data, (tick - CAP + back) % RING)
		}
		hash_of(extra, 0, &again)
		done := time.tick_now()
		if !slice.equal(again[:], forward[:]) do mismatches += 1
		step_us[k] = micros(start, stepped)
		rollback_us[k] = micros(resumed, done)
		both_us[k] = step_us[k] + rollback_us[k]
	}
	step, rollback := stat_of(step_us[:]), stat_of(rollback_us[:])
	slice.sort(both_us[:])
	return fmt.tprintf(
			`{{"step_us":{{"mean":%.2f,"p99":%.2f}},"rollback_us":{{"mean":%.2f,"p99":%.2f}},"step_plus_rollback_p99_us":%.2f,"step_plus_rollback_p90_us":%.2f}}`,
			step.mean,
			step.p99,
			rollback.mean,
			rollback.p99,
			step.p99 + rollback.p99,
			both_us[(90 * ROLLBACK_TICKS + 99) / 100 - 1],
		),
		mismatches
}

// 64 characters on a slab, each walking its own circle and jumping now and then: the time of their
// character_updates per tick (up to 9 rays each, joints made and destroyed), apart from the step.
run_characters :: proc() -> (us: [CHARACTER_TICKS]f64) {
	world := physics.create({tick_hz = TICK_HZ})
	defer physics.destroy(world)
	physics.create_box(world, physics.body_def(.Static, {0, -0.5, 0}), physics.shape_def(1), {40, 0.5, 40})
	characters: [CHARACTERS]physics.Character
	def := physics.CHARACTER_DEFAULT
	def.category = 2
	for &character, i in characters {
		physics.character_create(world, &character, def, {f32(i % 8) * 4 - 14, 1.2, f32(i / 8) * 4 - 14})
	}
	// directions round a circle, from a fixed table: no trig
	DIRECTIONS :: [8][2]f32 {
		{1, 0},
		{0.7071, 0.7071},
		{0, 1},
		{-0.7071, 0.7071},
		{-1, 0},
		{-0.7071, -0.7071},
		{0, -1},
		{0.7071, -0.7071},
	}
	directions := DIRECTIONS
	for tick in 0 ..< CHARACTER_TICKS {
		start := time.tick_now()
		for &character, i in characters {
			move := directions[(tick / 16 + i) % 8]
			physics.character_update(world, &character, def, move, (tick + i * 7) % 96 == 0, 1)
		}
		us[tick] = micros(start, time.tick_now())
		physics.step(world)
	}
	return
}
