package test_view

import "core:sync"
import "core:testing"
import "core:thread"
import "unified:view"

// ---- triple buffer and queue

Frame :: struct {
	seq:   u64,
	check: u64, // = seq * 3: a torn frame would break it
}

@(test)
triple_newest_wins :: proc(t: ^testing.T) {
	tb: view.Triple(Frame)
	view.triple_init(&tb)
	_, fresh := view.triple_front(&tb)
	testing.expect(t, !fresh)
	for i in u64(1) ..= 3 {
		view.triple_back(&tb)^ = {i, i * 3}
		view.triple_publish(&tb)
	}
	f, fresh2 := view.triple_front(&tb)
	testing.expect(t, fresh2)
	testing.expect_value(t, f.seq, 3)
	_, fresh3 := view.triple_front(&tb)
	testing.expect(t, !fresh3)
}

@(test)
triple_threads_never_tear :: proc(t: ^testing.T) {
	Ctx :: struct {
		tb:   view.Triple(Frame),
		done: bool,
	}
	ctx: Ctx
	view.triple_init(&ctx.tb)
	writer := thread.create_and_start_with_data(&ctx, proc(p: rawptr) {
		c := (^Ctx)(p)
		for i in u64(1) ..= 200_000 {
			view.triple_back(&c.tb)^ = {i, i * 3}
			view.triple_publish(&c.tb)
		}
		sync.atomic_store(&c.done, true)
	})
	last: u64
	for !sync.atomic_load(&ctx.done) {
		f, fresh := view.triple_front(&ctx.tb)
		if !fresh do continue
		testing.expect_value(t, f.check, f.seq * 3)
		testing.expect(t, f.seq > last)
		last = f.seq
	}
	thread.join(writer)
	thread.destroy(writer)
	f, _ := view.triple_front(&ctx.tb)
	testing.expect_value(t, f.seq, 200_000)
}

@(test)
queue_spsc :: proc(t: ^testing.T) {
	q: view.Queue(int, 4)
	for i in 0 ..< 4 do testing.expect(t, view.queue_push(&q, i))
	testing.expect(t, !view.queue_push(&q, 99)) // full
	testing.expect_value(t, view.queue_len(&q), 4)
	for i in 0 ..< 4 {
		v, ok := view.queue_pop(&q)
		testing.expect(t, ok)
		testing.expect_value(t, v, i)
	}
	_, ok := view.queue_pop(&q)
	testing.expect(t, !ok)
}

@(test)
alpha_clamps :: proc(t: ^testing.T) {
	testing.expect_value(t, view.alpha(1000, 1000, 15625), 0)
	testing.expect_value(t, view.alpha(1000 + 15625 / 2, 1000, 15625), f32(7812) / 15625)
	testing.expect_value(t, view.alpha(99999, 1000, 15625), 1)
	testing.expect_value(t, view.alpha(0, 1000, 15625), 0)
}

// ---- tracks

near :: proc(a, b: [3]f32, eps: f32 = 1e-4) -> bool {
	return view.length(a - b) <= eps
}

at :: proc(x: f32) -> view.Pose {
	return {{x, 0, 0}, view.IDENTITY}
}

@(test)
track_interpolates :: proc(t: ^testing.T) {
	tr: view.Track
	view.track_push(&tr, 10, at(0))
	view.track_push(&tr, 11, at(1))
	p := view.track_sample(&tr, 11, 0.25, 0.016)
	testing.expect(t, near(p.pos, {0.25, 0, 0}), "lerp between ticks")
	// only one sample of the pair: shows the newest
	view.track_push(&tr, 12, at(2))
	p = view.track_sample(&tr, 13, 0.5, 0.016)
	testing.expect(t, near(p.pos, {2, 0, 0}))
}

@(test)
track_smooths_corrections :: proc(t: ^testing.T) {
	s := view.Smoothing {
		tau_s         = 0.1,
		teleport_dist = 4,
	}
	tr: view.Track
	view.track_push(&tr, 10, at(0), s)
	view.track_push(&tr, 11, at(1), s)
	before := view.track_sample(&tr, 11, 1, 0, s)
	testing.expect(t, near(before.pos, {1, 0, 0}))
	// A rollback re-simulates tick 11 to x = 0.5: the display must not jump ...
	view.track_push(&tr, 11, at(0.5), s)
	after := view.track_sample(&tr, 11, 1, 0, s)
	testing.expect(t, near(after.pos, before.pos), "no jump on correction")
	// ... and converges with time constant tau: after 0.1 s, 1/e of the error is left.
	p := view.track_sample(&tr, 11, 1, 0.1, s)
	testing.expectf(t, near(p.pos, {0.5 + 0.5 * 0.36788, 0, 0}, 1e-3), "decay: %v", p.pos)
	for _ in 0 ..< 60 do p = view.track_sample(&tr, 11, 1, 1.0 / 60, s)
	testing.expect(t, near(p.pos, {0.5, 0, 0}, 1e-3), "converged")
}

@(test)
track_teleports_snap :: proc(t: ^testing.T) {
	s := view.SMOOTHING_DEFAULT
	tr: view.Track
	view.track_push(&tr, 10, at(0), s)
	view.track_push(&tr, 11, at(1), s)
	_ = view.track_sample(&tr, 11, 1, 0, s)
	view.track_push(&tr, 11, at(50), s) // correction beyond teleport_dist: snap
	p := view.track_sample(&tr, 11, 1, 0, s)
	testing.expect(t, near(p.pos, {50, 0, 0}))
	view.track_push(&tr, 12, at(100), s) // a move beyond teleport_dist: no interpolation across it
	p = view.track_sample(&tr, 12, 0.5, 0, s)
	testing.expect(t, near(p.pos, {100, 0, 0}))
}

@(test)
track_rotation_interpolates_and_smooths :: proc(t: ^testing.T) {
	s := view.SMOOTHING_DEFAULT
	tr: view.Track
	view.track_push(&tr, 1, {{}, view.quat_yaw(0)}, s)
	view.track_push(&tr, 2, {{}, view.quat_yaw(1)}, s)
	p := view.track_sample(&tr, 2, 0.5, 0, s)
	testing.expectf(t, abs(view.yaw_of(p.rot) - 0.5) < 1e-3, "yaw %v", view.yaw_of(p.rot))
	_ = view.track_sample(&tr, 2, 1, 0, s)
	view.track_push(&tr, 2, {{}, view.quat_yaw(0.5)}, s)
	p = view.track_sample(&tr, 2, 1, 0, s)
	testing.expectf(t, abs(view.yaw_of(p.rot) - 1) < 1e-3, "no rotation jump: %v", view.yaw_of(p.rot))
	for _ in 0 ..< 120 do p = view.track_sample(&tr, 2, 1, 1.0 / 60, s)
	testing.expectf(t, abs(view.yaw_of(p.rot) - 0.5) < 1e-3, "converged: %v", view.yaw_of(p.rot))
}

@(test)
track_rollback_drops_newer_predictions :: proc(t: ^testing.T) {
	tr: view.Track
	for i in u32(1) ..= 4 do view.track_push(&tr, i, at(f32(i)))
	_ = view.track_sample(&tr, 4, 1, 0)
	view.track_push(&tr, 2, at(2)) // re-simulated from tick 2: ticks 3, 4 are stale
	_, has3 := view.track_at(&tr, 3)
	testing.expect(t, !has3)
	_, has2 := view.track_at(&tr, 2)
	testing.expect(t, has2)
}

// ---- view sets

@(test)
set_lifetimes :: proc(t: ^testing.T) {
	s: view.View_Set(int)
	defer view.set_destroy(&s)
	next := 100
	frame :: proc(s: ^view.View_Set(int), keys: []view.Key, now: f64, next: ^int) -> (spawned: int) {
		view.set_begin(s)
		for k in keys {
			e, sp := view.set_see(s, k)
			if sp {
				e.view = next^
				next^ += 1
				spawned += 1
			}
		}
		view.set_end(s, now, 0.5)
		return
	}
	testing.expect_value(t, frame(&s, {1, 2}, 0, &next), 2)
	testing.expect_value(t, frame(&s, {1, 2}, 0.1, &next), 0)
	// 2 disappears: lingers
	testing.expect_value(t, frame(&s, {1}, 0.2, &next), 0)
	testing.expect_value(t, len(s.despawned), 1)
	testing.expect_value(t, s.despawned[0], view.Key(2))
	testing.expect_value(t, view.set_get(&s, 2).phase, view.Phase.Lingering)
	// a rollback brings it back within the linger: same view, no respawn
	testing.expect_value(t, frame(&s, {1, 2}, 0.3, &next), 0)
	testing.expect_value(t, view.set_get(&s, 2).view, 101)
	testing.expect_value(t, view.set_get(&s, 2).phase, view.Phase.Alive)
	// gone for good: removed after the linger
	_ = frame(&s, {1}, 1.0, &next)
	_ = frame(&s, {1}, 1.4, &next)
	testing.expect_value(t, len(s.removed), 0)
	_ = frame(&s, {1}, 1.6, &next)
	testing.expect_value(t, len(s.removed), 1)
	testing.expect_value(t, s.removed[0], 101)
	testing.expect(t, view.set_get(&s, 2) == nil)
	// the same slot re-used under a new key gets a new view
	testing.expect_value(t, frame(&s, {1, 3}, 2, &next), 1)
	testing.expect_value(t, view.set_get(&s, 3).view, 102)
}

@(test)
pool_reuses :: proc(t: ^testing.T) {
	p: view.Pool(int)
	defer view.pool_destroy(&p)
	_, ok := view.pool_get(&p)
	testing.expect(t, !ok)
	view.pool_put(&p, 7)
	v, ok2 := view.pool_get(&p)
	testing.expect(t, ok2 && v == 7)
}

// ---- predicted events

Ev :: struct {
	tick:   u32,
	kind:   u32,
	entity: u64,
}

ev_id :: proc(e: Ev) -> view.Event_Id {
	return {tick = e.tick, kind = e.kind, entity = e.entity}
}

sim_tick :: proc(tr: ^view.Event_Tracker(Ev), tick: u32, evs: ..Ev) {
	view.tracker_begin_tick(tr, tick)
	for e in evs do view.tracker_event(tr, e)
	view.tracker_end_tick(tr, tick)
}

@(test)
events_fire_cancel_confirm :: proc(t: ^testing.T) {
	tr: view.Event_Tracker(Ev)
	view.tracker_init(&tr, ev_id)
	defer view.tracker_destroy(&tr)
	boom := Ev{5, 1, 42}
	death := Ev{6, 2, 7}
	// predicted ticks 5, 6
	sim_tick(&tr, 5, boom)
	sim_tick(&tr, 6, death)
	testing.expect_value(t, len(tr.out), 2)
	testing.expect_value(t, tr.out[0], view.Tracked(Ev){.Fire, boom})
	clear(&tr.out)
	// rollback to 5: tick 5 produces the explosion again (no second Fire), tick 6 no longer kills
	sim_tick(&tr, 5, boom)
	sim_tick(&tr, 6)
	testing.expect_value(t, len(tr.out), 1)
	testing.expect_value(t, tr.out[0], view.Tracked(Ev){.Cancel, death})
	clear(&tr.out)
	// tick 5 verified: confirmed once
	view.tracker_verified(&tr, 5)
	view.tracker_verified(&tr, 5)
	testing.expect_value(t, len(tr.out), 1)
	testing.expect_value(t, tr.out[0], view.Tracked(Ev){.Confirm, boom})
	clear(&tr.out)
	// re-simulating a verified tick (a rollback that starts there) fires nothing again
	sim_tick(&tr, 5, boom)
	testing.expect_value(t, len(tr.out), 0)
	// a re-simulated tick that produces a different event: fire the new one
	sim_tick(&tr, 7, Ev{7, 1, 1})
	sim_tick(&tr, 7, Ev{7, 1, 2})
	testing.expect_value(t, len(tr.out), 3) // fire 1, fire 2, cancel 1
	testing.expect_value(t, tr.out[1], view.Tracked(Ev){.Fire, Ev{7, 1, 2}})
	testing.expect_value(t, tr.out[2], view.Tracked(Ev){.Cancel, Ev{7, 1, 1}})
}
