// The large-level rows of the physics bench: a generated level of LEVEL_SHAPES static shapes (75% boxes, 25% hulls of
// 40 points; 1 to 3 per body, one per 64 m², so it spans about 800 m) built as a game's level is (create_with_levels,
// level_change: one compound per cell and category), with 100 and then 500 dynamic bodies in the middle (half kept
// awake, half left to sleep). What each operation a session repeats costs beside a large level: a level change, the
// step, a save, a restore, the deep hash, a rollback of ROLLBACK_DEPTH ticks, the snapshot and the portable image (the
// level's compounds ride in it) and its load into a late joiner's world.
package physics_bench

import "core:fmt"
import "core:slice"
import "core:time"

import level_file "../../level_file"
import "unified:level"
import "unified:physics"
import "unified:sim"

LEVEL_SHAPES :: 10_000
LEVEL_TICKS :: 128 // measured, after SETTLE_TICKS
LEVEL_CHANGES :: 8 // level_change calls measured (each destroys the level's bodies and makes them again)
ROLLBACK_DEPTH :: 8 // restore the tick this far back, then this many steps with a save each
LEVEL_IMAGE_EVERY :: 32

Large_Area :: enum u8 {
	Large,
}

Large_Input :: struct {
	unused: u8,
	_pad:   [3]u8,
}

// The block a level change writes (sim.level_enter); the bodies are the World's.
Large_State :: struct {
	level:   sim.Active_Level(Large_Area),
	players: sim.Players(u32, sim.No_Profile, Large_Input, 1),
}

Large_Events :: union {
	sim.Event_Player_Joined,
	sim.Event_Player_Left,
}

Large_Game :: sim.Game(
	Large_State,
	Large_Input,
	physics.World,
	Large_Events,
	sim.No_Commands,
	sim.No_Setup,
	sim.No_Profile,
	1,
)

// A small deterministic generator (splitmix64), so every run measures the same level.
Rng :: struct {
	state: u64,
}

next :: proc(rng: ^Rng) -> u64 {
	rng.state += 0x9e3779b97f4a7c15
	z := rng.state
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

// A uniform f32 in [lo, hi).
uniform :: proc(rng: ^Rng, lo, hi: f32) -> f32 {
	return lo + (hi - lo) * f32(next(rng) >> 40) / f32(1 << 24)
}

// The generated level's file: a ground slab and LEVEL_SHAPES shapes scattered over it.
large_level_file :: proc() -> []u8 {
	rng := Rng{7}
	side := f32(800) // LEVEL_SHAPES shapes at one per 64 m²
	bodies := make([dynamic]level.Body, context.temp_allocator)
	ground := make([]level.Shape, 1, context.temp_allocator)
	ground[0] = {
		kind = .Box,
		rot  = {0, 0, 0, 1},
		half = {side / 2, 0.5, side / 2},
	}
	append(&bodies, level.Body {
		name = "ground",
		pos = {0, -0.5, 0},
		rot = {0, 0, 0, 1},
		surface = {friction = 0.6},
		shapes = ground,
	})
	made := 0
	for made < LEVEL_SHAPES {
		count := min(int(next(&rng) % 3) + 1, LEVEL_SHAPES - made)
		shapes := make([]level.Shape, count, context.temp_allocator)
		for &shape in shapes {
			pos := [3]f32{uniform(&rng, -5, 5), uniform(&rng, 0, 3), uniform(&rng, -5, 5)}
			if next(&rng) % 4 == 0 {
				radius := uniform(&rng, 1, 6)
				points := make([][3]f32, 40, context.temp_allocator)
				for &point in points {
					point = pos + [3]f32{uniform(&rng, -1, 1), uniform(&rng, -1, 1), uniform(&rng, -1, 1)} * radius
				}
				shape = {
					kind   = .Hull,
					rot    = {0, 0, 0, 1},
					points = points,
				}
			} else {
				half := [3]f32{uniform(&rng, 0.5, 3), uniform(&rng, 0.5, 3), uniform(&rng, 0.5, 3)}
				shape = {
					kind = .Box,
					pos  = pos,
					rot  = {0, 0, 0, 1},
					half = half,
				}
			}
		}
		// Clear of the middle, where the dynamic bodies are.
		pos := [3]f32{uniform(&rng, -side / 2, side / 2), 0, uniform(&rng, -side / 2, side / 2)}
		if abs(pos.x) < 30 && abs(pos.z) < 30 do pos.x += 60
		append(&bodies, level.Body {
			name = "rock",
			pos = pos,
			rot = {0, 0, 0, 1},
			surface = {friction = 0.6, material = 1},
			shapes = shapes,
		})
		made += count
	}
	return level_file.encode(bodies[:], nil)
}

// One row: the level with `dynamic_bodies` dynamic bodies.
run_large_level :: proc(file: []u8, dynamic_bodies: int) -> string {
	levels := []sim.Level_File{{"large", file}}
	create_world :: proc(levels: []sim.Level_File) -> ^physics.World {
		world, problem := physics.create_with_levels({tick_hz = TICK_HZ}, levels)
		assert(problem == "", problem)
		return world
	}
	built := time.tick_now()
	world := create_world(levels)
	world_create_ms := time.duration_milliseconds(time.tick_since(built))
	defer physics.destroy(world)
	late := create_world(levels)
	defer physics.destroy(late)
	state, late_state: Large_State
	extra := physics.extra(world, Large_State)
	late_extra := physics.extra(late, Large_State)
	tick := sim.Tick(Large_Game) {
		state = &state,
		world = world,
	}
	late_tick := sim.Tick(Large_Game) {
		state = &late_state,
		world = late,
	}
	change_us: [LEVEL_CHANGES]f64
	for &us in change_us {
		start := time.tick_now()
		physics.level_change(&tick, world, Large_Area.Large)
		us = micros(start, time.tick_now())
	}
	physics.level_change(&late_tick, late, Large_Area.Large)
	statics := 0
	for entry in world.bodies do statics += int(.Level in entry.flags)

	// Boxes and balls over the middle: the odd ones never sleep.
	def := physics.shape_def(2)
	def.density = 1
	for i in 0 ..< dynamic_bodies {
		pos := [3]f32{f32(i % 10) * 3 - 15, 1 + f32(i / 100) * 1.5, f32(i / 10 % 10) * 3 - 15}
		body_def := physics.body_def(.Dynamic, pos)
		body_def.enable_sleep = i % 2 == 0
		if i % 4 < 2 {
			physics.create_box(world, body_def, def, {0.5, 0.5, 0.5})
		} else {
			physics.create_sphere(world, body_def, def, 0.5)
		}
	}
	for _ in 0 ..< SETTLE_TICKS do physics.step(world)

	step_us, save_us, restore_us, deep_us: [LEVEL_TICKS]f64
	rollback_us: [LEVEL_TICKS - ROLLBACK_DEPTH]f64
	load_us: [LEVEL_TICKS / LEVEL_IMAGE_EVERY]f64
	deep, again: [dynamic]u8
	defer delete(deep)
	defer delete(again)
	mismatches, image_bytes := 0, 0
	for k in 0 ..< LEVEL_TICKS {
		slot := k % RING
		start := time.tick_now()
		physics.step(world)
		stepped := time.tick_now()
		extra.save(extra.data, slot)
		saved := time.tick_now()
		hash_of(extra, 0, &deep)
		hashed := time.tick_now()
		ok := extra.restore(extra.data, slot)
		restored := time.tick_now()
		step_us[k] = micros(start, stepped)
		save_us[k] = micros(stepped, saved)
		deep_us[k] = micros(saved, hashed)
		restore_us[k] = micros(hashed, restored)
		if !ok do mismatches += 1
		if k >= ROLLBACK_DEPTH {
			// The rollback: back ROLLBACK_DEPTH ticks, then forward again saving each; it must hash as the forward tick.
			rollback := time.tick_now()
			if !extra.restore(extra.data, (k - ROLLBACK_DEPTH) % RING) do mismatches += 1
			for back in 1 ..= ROLLBACK_DEPTH {
				physics.step(world)
				extra.save(extra.data, (k - ROLLBACK_DEPTH + back) % RING)
			}
			rollback_us[k - ROLLBACK_DEPTH] = micros(rollback, time.tick_now())
			if !slice.equal(hash_of(extra, 0, &again), deep[:]) do mismatches += 1
		}
		if k % LEVEL_IMAGE_EVERY == 0 {
			image := extra.image(extra.data, slot, true)
			image_bytes = len(image)
			load := time.tick_now()
			if !late_extra.load(late_extra.data, image) do mismatches += 1
			load_us[k / LEVEL_IMAGE_EVERY] = micros(load, time.tick_now())
			if !slice.equal(hash_of(late_extra, 0, &again), deep[:]) do mismatches += 1
		}
	}
	assert(mismatches == 0, "the large level: a restore, rollback or late join did not give the same world back")
	return fmt.tprintf(
		`{{"shapes":%d,"statics":%d,"dynamic_bodies":%d,"world_create_ms":%.1f,"level_change_us":%s,"step_us":%s,"save_us":%s,"restore_us":%s,"hash_deep_us":%s,"rollback_us":%s,"rollback_depth":%d,"snapshot_bytes":%d,"image_bytes":%d,"load_us":%s}}`,
		LEVEL_SHAPES,
		statics,
		dynamic_bodies,
		world_create_ms,
		stat_json(change_us[:]),
		stat_json(step_us[:]),
		stat_json(save_us[:]),
		stat_json(restore_us[:]),
		stat_json(deep_us[:]),
		stat_json(rollback_us[:]),
		ROLLBACK_DEPTH,
		extra.size(extra.data, (LEVEL_TICKS - 1) % RING),
		image_bytes,
		stat_json(load_us[:]),
	)
}

// Both rows, as a JSON array.
run_large_levels :: proc() -> string {
	file := large_level_file()
	return fmt.tprintf(`[%s,%s]`, run_large_level(file, 100), run_large_level(file, 500))
}
