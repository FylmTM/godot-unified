// The Box3D scaling benchmark (src/box3d_port/SPEC.md, phase 2): stacks of boxes on a ground, settled, then the
// step, save and restore times, the image size, and an 8-tick rollback (restore + 8 × (step + save)) per body count
// and worker count. Run on a release build:
// `odin run tests/box3d/scale -collection:unified=src -o:speed`.
package box3d_scale

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:time"
import b3 "unified:box3d_port"

DT :: f32(1.0 / 64)
SUBSTEPS :: 4
SETTLE :: 240 // steps before measuring, so contacts and islands exist
REPS :: 64
ROLLBACK :: 8

Result :: struct {
	step, save, restore, rollback, memcpy: f64, // µs, median
	image:                                 int,
}

median :: proc(xs: []f64) -> f64 {
	slice.sort(xs)
	return xs[len(xs) / 2]
}

us :: proc(t: time.Tick) -> f64 {
	return time.duration_microseconds(time.tick_since(t))
}

run :: proc(n, workers: int) -> (r: Result) {
	wd := b3.DefaultWorldDef()
	wd.workerCount = u32(workers)
	wd.enableSleep = false
	w := b3.CreateWorld(&wd)
	defer b3.DestroyWorld(w)

	bd := b3.DefaultBodyDef()
	bd.position = {0, -0.5, 0}
	ground := b3.CreateBody(w, &bd)
	sd := b3.DefaultShapeDef()
	gh := b3.MakeBoxHull(100, 0.5, 100)
	_ = b3.CreateHullShape(ground, &sd, &gh.base)
	box := b3.MakeBoxHull(0.4, 0.4, 0.4)
	side := 10
	for i in 0 ..< n {
		col := i % (side * side)
		layer := i / (side * side)
		d := b3.DefaultBodyDef()
		d.type = .dynamicBody
		d.position = {f32(col % side) * 1.0 - 5, 0.4 + f32(layer) * 0.85, f32(col / side) * 1.0 - 5}
		body := b3.CreateBody(w, &d)
		s := b3.DefaultShapeDef()
		s.density = 1
		_ = b3.CreateHullShape(body, &s, &box.base)
	}
	for _ in 0 ..< SETTLE {
		b3.World_Step(w, DT, SUBSTEPS)
	}

	cache := b3.CreateWorldStateCache()
	st := b3.CreateWorldState()
	defer {
		b3.DestroyWorldState(st)
		b3.DestroyWorldStateCache(cache)
	}
	b3.World_SaveState(w, cache, st)
	r.image = int(b3.WorldState_GetSize(st))

	samples: [REPS]f64
	for &s in samples {
		t := time.tick_now()
		b3.World_SaveState(w, cache, st)
		s = us(t)
	}
	r.save = median(samples[:])
	for &s in samples {
		t := time.tick_now()
		_ = b3.World_RestoreState(w, cache, st)
		s = us(t)
	}
	r.restore = median(samples[:])
	for &s in samples {
		_ = b3.World_RestoreState(w, cache, st)
		t := time.tick_now()
		b3.World_Step(w, DT, SUBSTEPS)
		s = us(t)
	}
	r.step = median(samples[:])

	// The rollback a client does on a late input: back to the saved tick, then re-simulate and re-save 8 ticks.
	ring: [ROLLBACK]^b3.WorldState
	for &slot in ring {
		slot = b3.CreateWorldState()
	}
	defer for slot in ring {
		b3.DestroyWorldState(slot)
	}
	rb: [16]f64
	for &s in rb {
		t := time.tick_now()
		_ = b3.World_RestoreState(w, cache, st)
		for slot in ring {
			b3.World_Step(w, DT, SUBSTEPS)
			b3.World_SaveState(w, cache, slot)
		}
		s = us(t)
	}
	r.rollback = median(rb[:])

	dst := make([]u8, r.image)
	defer delete(dst)
	src := b3.WorldState_GetData(st)
	for &s in samples {
		t := time.tick_now()
		mem.copy(raw_data(dst), src, r.image)
		s = us(t)
	}
	r.memcpy = median(samples[:])
	return
}

main :: proc() {
	fmt.println("bodies workers    step µs    save µs restore µs  rollback(8) µs   image bytes  memcpy µs")
	for n in ([]int{100, 1000, 2000}) {
		for workers in ([]int{1, 2, 4}) {
			r := run(n, workers)
			fmt.printf(
				"%6d %7d %10.1f %10.1f %10.1f %15.1f %13d %10.1f\n",
				n,
				workers,
				r.step,
				r.save,
				r.restore,
				r.rollback,
				r.image,
				r.memcpy,
			)
		}
	}
}
