// The physics row of `uni bench` (#260): Box3D through unified:physics on a fixed scene, apart from any game, so a
// Box3D upgrade that slows one operation shows here rather than as a small shift in a game's total. A pile of boxes
// kept awake on a ground slab; every tick: a step (4 substeps), a save into a ring slot (the in-process snapshot every
// tick's save makes), the deep hash (the whole world, as on the ticks peers compare), a restore of that slot (what a
// rollback starts with; it must give the same hash back) and a batch of rays down onto the pile. One JSON line.
package physics_bench

import "core:fmt"
import "core:os"
import "core:slice"
import "core:time"

import box3d "box3d:bindings"
import "unified:physics"

BODIES_SIDE :: 8 // an 8 x 8 x 8 stack: 512 boxes
BODIES :: BODIES_SIDE * BODIES_SIDE * BODIES_SIDE
SETTLE_TICKS :: 64 // not measured: the stack falls and lands
TICKS :: 600
RAYS :: 64 // per tick, straight down onto the pile
RING :: 16
DT :: f32(1.0 / 64)
SUBSTEPS :: 4

Stat :: struct {
	mean, p99: f64,
}

stat_of :: proc(samples: []f64) -> Stat {
	sum := 0.0
	for sample in samples do sum += sample
	slice.sort(samples)
	return {sum / f64(len(samples)), samples[max((99 * len(samples) + 99) / 100 - 1, 0)]}
}

stat_json :: proc(stat: Stat) -> string {
	return fmt.tprintf(`{{"mean":%.2f,"p99":%.2f}}`, stat.mean, stat.p99)
}

add_box :: proc(world: ^physics.World, pos, half: [3]f32, type: physics.Body_Type) {
	body_def := physics.default_body_def()
	body_def.type = type
	body_def.position = pos
	body_def.enable_sleep = false // every tick costs the same: the whole pile stays awake
	body := physics.create_body(world, &body_def)
	shape_def := physics.default_shape_def()
	hull := physics.make_box_hull(half.x, half.y, half.z)
	physics.create_hull_shape(world, body, &shape_def, &hull.base)
}

main :: proc() {
	world := physics.create()
	defer physics.destroy(world)
	add_box(world, {0, -0.5, 0}, {30, 0.5, 30}, .Static_Body)
	for x in 0 ..< BODIES_SIDE {
		for y in 0 ..< BODIES_SIDE {
			for z in 0 ..< BODIES_SIDE {
				pos := [3]f32{f32(x) * 0.8 - 2.8, 0.5 + f32(y) * 0.8, f32(z) * 0.8 - 2.8}
				add_box(world, pos, {0.25, 0.25, 0.25}, .Dynamic_Body)
			}
		}
	}
	for _ in 0 ..< SETTLE_TICKS {
		physics.step(world, DT, SUBSTEPS)
	}
	ring: [RING]box3d.WorldSnapshot
	defer {
		for &snapshot in ring do box3d.DestroyWorldSnapshot(&snapshot)
	}
	step_us, save_us, hash_us, restore_us, rays_us: [TICKS]f64
	micros :: proc(from, to: time.Tick) -> f64 {return time.duration_microseconds(time.tick_diff(from, to))}
	mismatches, hits := 0, 0
	for tick in 0 ..< TICKS {
		slot := &ring[tick % RING]
		start := time.tick_now()
		physics.step(world, DT, SUBSTEPS)
		stepped := time.tick_now()
		box3d.World_SaveSnapshot(world.id, slot)
		saved := time.tick_now()
		hash := box3d.World_HashState(world.id)
		hashed := time.tick_now()
		restored_ok := box3d.World_RestoreSnapshot(world.id, slot)
		restored := time.tick_now()
		for ray in 0 ..< RAYS {
			origin := [3]f32{f32(ray % 8) * 0.8 - 2.8, 20, f32(ray / 8) * 0.8 - 2.8}
			if _, ok := physics.world_cast_ray_closest(world, origin, {0, -30, 0}); ok do hits += 1
		}
		raycast := time.tick_now()
		if !restored_ok || box3d.World_HashState(world.id) != hash {
			mismatches += 1 // a restore that doesn't give the saved world back
		}
		step_us[tick] = micros(start, stepped)
		save_us[tick] = micros(stepped, saved)
		hash_us[tick] = micros(saved, hashed)
		restore_us[tick] = micros(hashed, restored)
		rays_us[tick] = micros(restored, raycast)
	}
	snapshot_bytes := ring[(TICKS - 1) % RING].size
	fmt.printfln(
		`{{"mode":"physics-bench","bodies":%d,"ticks":%d,"substeps":%d,"rays":%d,"step_us":%s,"save_us":%s,"hash_deep_us":%s,"restore_us":%s,"rays_us":%s,"snapshot_bytes":%d,"ray_hits":%d,"mismatches":%d}}`,
		BODIES,
		TICKS,
		SUBSTEPS,
		RAYS,
		stat_json(stat_of(step_us[:])),
		stat_json(stat_of(save_us[:])),
		stat_json(stat_of(hash_us[:])),
		stat_json(stat_of(restore_us[:])),
		stat_json(stat_of(rays_us[:])),
		snapshot_bytes,
		hits,
		mismatches,
	)
	if mismatches > 0 do os.exit(1)
}
