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
	triple: view.Triple(Frame)
	view.triple_init(&triple)
	_, fresh := view.triple_front(&triple)
	testing.expect(t, !fresh)
	for i in u64(1) ..= 3 {
		view.triple_back(&triple)^ = {i, i * 3}
		view.triple_publish(&triple)
	}
	frame, fresh2 := view.triple_front(&triple)
	testing.expect(t, fresh2)
	testing.expect_value(t, frame.seq, 3)
	_, fresh3 := view.triple_front(&triple)
	testing.expect(t, !fresh3)
}

@(test)
triple_threads_never_tear :: proc(t: ^testing.T) {
	Shared :: struct {
		triple: view.Triple(Frame),
		done:   bool,
	}
	shared: Shared
	view.triple_init(&shared.triple)
	writer := thread.create_and_start_with_data(&shared, proc(data: rawptr) {
		shared := (^Shared)(data)
		for i in u64(1) ..= 200_000 {
			view.triple_back(&shared.triple)^ = {i, i * 3}
			view.triple_publish(&shared.triple)
		}
		sync.atomic_store(&shared.done, true)
	})
	last: u64
	for !sync.atomic_load(&shared.done) {
		frame, fresh := view.triple_front(&shared.triple)
		if !fresh do continue
		testing.expect_value(t, frame.check, frame.seq * 3)
		testing.expect(t, frame.seq > last)
		last = frame.seq
	}
	thread.join(writer)
	thread.destroy(writer)
	frame, _ := view.triple_front(&shared.triple)
	testing.expect_value(t, frame.seq, 200_000)
}

@(test)
queue_spsc :: proc(t: ^testing.T) {
	queue: view.Queue(int, 4)
	for i in 0 ..< 4 do testing.expect(t, view.queue_push(&queue, i))
	testing.expect(t, !view.queue_push(&queue, 99)) // full
	testing.expect_value(t, view.queue_len(&queue), 4)
	for i in 0 ..< 4 {
		item, ok := view.queue_pop(&queue)
		testing.expect(t, ok)
		testing.expect_value(t, item, i)
	}
	_, ok := view.queue_pop(&queue)
	testing.expect(t, view.queue_peek(&queue) == nil)
	testing.expect(t, view.queue_push(&queue, 7))
	testing.expect_value(t, view.queue_peek(&queue)^, 7) // peeking leaves it queued
	testing.expect_value(t, view.queue_len(&queue), 1)
	item, popped := view.queue_pop(&queue)
	testing.expect(t, popped && item == 7)
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
	track: view.Track
	view.track_push(&track, 10, at(0))
	view.track_push(&track, 11, at(1))
	pose := view.track_sample(&track, 11, 0.25, 0.016)
	testing.expect(t, near(pose.pos, {0.25, 0, 0}), "lerp between ticks")
	// only one sample of the pair: shows the newest
	view.track_push(&track, 12, at(2))
	pose = view.track_sample(&track, 13, 0.5, 0.016)
	testing.expect(t, near(pose.pos, {2, 0, 0}))
}

@(test)
track_smooths_corrections :: proc(t: ^testing.T) {
	smoothing := view.Smoothing {
		tau_s         = 0.1,
		teleport_dist = 4,
	}
	track: view.Track
	view.track_push(&track, 10, at(0), smoothing)
	view.track_push(&track, 11, at(1), smoothing)
	before := view.track_sample(&track, 11, 1, 0, smoothing)
	testing.expect(t, near(before.pos, {1, 0, 0}))
	// A rollback re-simulates tick 11 to x = 0.5: the display must not jump ...
	view.track_push(&track, 11, at(0.5), smoothing)
	after := view.track_sample(&track, 11, 1, 0, smoothing)
	testing.expect(t, near(after.pos, before.pos), "no jump on correction")
	// ... and converges with time constant tau: after 0.1 s, 1/e of the error is left.
	pose := view.track_sample(&track, 11, 1, 0.1, smoothing)
	testing.expectf(t, near(pose.pos, {0.5 + 0.5 * 0.36788, 0, 0}, 1e-3), "decay: %v", pose.pos)
	for _ in 0 ..< 60 do pose = view.track_sample(&track, 11, 1, 1.0 / 60, smoothing)
	testing.expect(t, near(pose.pos, {0.5, 0, 0}, 1e-3), "converged")
}

@(test)
track_teleports_snap :: proc(t: ^testing.T) {
	smoothing := view.SMOOTHING_DEFAULT
	track: view.Track
	view.track_push(&track, 10, at(0), smoothing)
	view.track_push(&track, 11, at(1), smoothing)
	_ = view.track_sample(&track, 11, 1, 0, smoothing)
	view.track_push(&track, 11, at(50), smoothing) // correction beyond teleport_dist: snap
	pose := view.track_sample(&track, 11, 1, 0, smoothing)
	testing.expect(t, near(pose.pos, {50, 0, 0}))
	view.track_push(&track, 12, at(100), smoothing) // a move beyond teleport_dist: no interpolation across it
	pose = view.track_sample(&track, 12, 0.5, 0, smoothing)
	testing.expect(t, near(pose.pos, {100, 0, 0}))
}

@(test)
track_rotation_interpolates_and_smooths :: proc(t: ^testing.T) {
	smoothing := view.SMOOTHING_DEFAULT
	track: view.Track
	view.track_push(&track, 1, {{}, view.quat_yaw(0)}, smoothing)
	view.track_push(&track, 2, {{}, view.quat_yaw(1)}, smoothing)
	pose := view.track_sample(&track, 2, 0.5, 0, smoothing)
	testing.expectf(t, abs(view.yaw_of(pose.rot) - 0.5) < 1e-3, "yaw %v", view.yaw_of(pose.rot))
	_ = view.track_sample(&track, 2, 1, 0, smoothing)
	view.track_push(&track, 2, {{}, view.quat_yaw(0.5)}, smoothing)
	pose = view.track_sample(&track, 2, 1, 0, smoothing)
	testing.expectf(t, abs(view.yaw_of(pose.rot) - 1) < 1e-3, "no rotation jump: %v", view.yaw_of(pose.rot))
	for _ in 0 ..< 120 do pose = view.track_sample(&track, 2, 1, 1.0 / 60, smoothing)
	testing.expectf(t, abs(view.yaw_of(pose.rot) - 0.5) < 1e-3, "converged: %v", view.yaw_of(pose.rot))
}

// 2D angles (about +Z): round trip across the circle, interpolation through a track, and independence from yaw.
@(test)
angle2d_round_trips_and_interpolates :: proc(t: ^testing.T) {
	for angle in ([]f32{0, 0.5, -1, 2, 3, -3}) {
		testing.expectf(t, abs(view.angle2d_of(view.quat_angle2d(angle)) - angle) < 1e-5, "angle %v", angle)
		testing.expectf(t, abs(view.yaw_of(view.quat_angle2d(angle))) < 1e-5, "angle %v has no yaw", angle)
	}
	testing.expect(t, abs(view.angle2d_of(view.IDENTITY)) < 1e-6)
	track: view.Track
	view.track_push(&track, 1, {{}, view.quat_angle2d(0)})
	view.track_push(&track, 2, {{}, view.quat_angle2d(1)})
	pose := view.track_sample(&track, 2, 0.5, 0)
	testing.expectf(t, abs(view.angle2d_of(pose.rot) - 0.5) < 1e-3, "angle %v", view.angle2d_of(pose.rot))
}

@(test)
track_rollback_drops_newer_predictions :: proc(t: ^testing.T) {
	track: view.Track
	for i in u32(1) ..= 4 do view.track_push(&track, i, at(f32(i)))
	_ = view.track_sample(&track, 4, 1, 0)
	view.track_push(&track, 2, at(2)) // re-simulated from tick 2: ticks 3, 4 are stale
	_, has3 := view.track_at(&track, 3)
	testing.expect(t, !has3)
	_, has2 := view.track_at(&track, 2)
	testing.expect(t, has2)
}

// ---- view sets

@(test)
set_lifetimes :: proc(t: ^testing.T) {
	view_set: view.View_Set(view.Key, int)
	defer view.set_destroy(&view_set)
	next := 100
	frame :: proc(view_set: ^view.View_Set(view.Key, int), keys: []view.Key, now: f64, next: ^int) -> (spawned: int) {
		view.set_begin(view_set)
		for key in keys {
			entry, is_new := view.set_see(view_set, key)
			if is_new {
				entry.view = next^
				entry.linger_s = 0.5
				next^ += 1
				spawned += 1
			}
		}
		view.set_end(view_set, now)
		return
	}
	testing.expect_value(t, frame(&view_set, {1, 2}, 0, &next), 2)
	testing.expect_value(t, frame(&view_set, {1, 2}, 0.1, &next), 0)
	// 2 disappears: lingers
	testing.expect_value(t, frame(&view_set, {1}, 0.2, &next), 0)
	testing.expect_value(t, len(view_set.despawned), 1)
	testing.expect_value(t, view_set.despawned[0], view.Key(2))
	testing.expect_value(t, view.set_get(&view_set, 2).phase, view.Phase.Lingering)
	// a rollback brings it back within the linger: same view, no respawn
	testing.expect_value(t, frame(&view_set, {1, 2}, 0.3, &next), 0)
	testing.expect_value(t, view.set_get(&view_set, 2).view, 101)
	testing.expect_value(t, view.set_get(&view_set, 2).phase, view.Phase.Alive)
	// gone for good: removed after the linger
	_ = frame(&view_set, {1}, 1.0, &next)
	_ = frame(&view_set, {1}, 1.4, &next)
	testing.expect_value(t, len(view_set.removed), 0)
	_ = frame(&view_set, {1}, 1.6, &next)
	testing.expect_value(t, len(view_set.removed), 1)
	testing.expect_value(t, view_set.removed[0], 101)
	testing.expect(t, view.set_get(&view_set, 2) == nil)
	// the same slot re-used under a new key gets a new view
	testing.expect_value(t, frame(&view_set, {1, 3}, 2, &next), 1)
	testing.expect_value(t, view.set_get(&view_set, 3).view, 102)
	// removed at once, without a linger
	removed, ok := view.set_remove(&view_set, 3)
	testing.expect(t, ok && removed == 102 && view.set_get(&view_set, 3) == nil)
	_, ok = view.set_remove(&view_set, 3)
	testing.expect(t, !ok)
}

// Views keyed by kind and key: the same key in two kinds is two views.
@(test)
set_wider_keys :: proc(t: ^testing.T) {
	Id :: struct {
		kind: u8,
		key:  view.Key,
	}
	view_set: view.View_Set(Id, int)
	defer view.set_destroy(&view_set)
	view.set_begin(&view_set)
	a, spawned_a := view.set_see(&view_set, Id{0, 7})
	a.view = 1
	b, spawned_b := view.set_see(&view_set, Id{1, 7})
	b.view = 2
	view.set_end(&view_set, 0)
	testing.expect(t, spawned_a && spawned_b)
	testing.expect_value(t, view.set_get(&view_set, Id{0, 7}).view, 1)
	testing.expect_value(t, view.set_get(&view_set, Id{1, 7}).view, 2)
}

@(test)
pool_reuses :: proc(t: ^testing.T) {
	pool: view.Pool(int)
	defer view.pool_destroy(&pool)
	_, ok := view.pool_get(&pool)
	testing.expect(t, !ok)
	view.pool_put(&pool, 7)
	item, ok2 := view.pool_get(&pool)
	testing.expect(t, ok2 && item == 7)
}

// ---- predicted events

Ev :: struct {
	tick:   u32,
	kind:   u32,
	entity: u64,
}

event_id :: proc(event: Ev) -> view.Event_Id {
	return {
		tick   = event.tick,
		kind   = event.kind,
		entity = event.entity,
	}
}

sim_tick :: proc(tracker: ^view.Event_Tracker(Ev), tick: u32, events: ..Ev) {
	view.tracker_begin_tick(tracker, tick)
	for event in events do view.tracker_event(tracker, event)
	view.tracker_end_tick(tracker, tick)
}

// The tick being verified, then the verification (what a session's verified hook does).
verify_tick :: proc(tracker: ^view.Event_Tracker(Ev), tick: u32, events: ..Ev) {
	view.tracker_begin_tick(tracker, tick)
	for event in events do view.tracker_event(tracker, event)
	view.tracker_end_tick(tracker, tick)
	view.tracker_verified(tracker, tick)
}

@(test)
events_emitted_then_confirmed_or_cancelled :: proc(t: ^testing.T) {
	tracker: view.Event_Tracker(Ev)
	view.tracker_init(&tracker, event_id)
	defer view.tracker_destroy(&tracker)
	boom := Ev{5, 1, 42}
	death := Ev{6, 2, 7}
	// predicted ticks 5, 6
	sim_tick(&tracker, 5, boom)
	sim_tick(&tracker, 6, death)
	testing.expect_value(t, len(tracker.out), 2)
	testing.expect_value(t, tracker.out[0], view.Tracked(Ev){.Emitted, boom})
	clear(&tracker.out)
	// rollback to 5: tick 5 produces the explosion again (not emitted twice), tick 6 no longer kills
	sim_tick(&tracker, 5, boom)
	sim_tick(&tracker, 6)
	testing.expect_value(t, len(tracker.out), 1)
	testing.expect_value(t, tracker.out[0], view.Tracked(Ev){.Cancelled, death})
	clear(&tracker.out)
	// tick 5 verified: confirmed once
	view.tracker_verified(&tracker, 5)
	view.tracker_verified(&tracker, 5)
	testing.expect_value(t, len(tracker.out), 1)
	testing.expect_value(t, tracker.out[0], view.Tracked(Ev){.Confirmed, boom})
	clear(&tracker.out)
	// re-simulating a verified tick (a rollback that starts there) emits nothing again
	sim_tick(&tracker, 5, boom)
	testing.expect_value(t, len(tracker.out), 0)
	// a re-simulated tick that produces a different event: emit the new one, cancel the old one
	sim_tick(&tracker, 7, Ev{7, 1, 1})
	sim_tick(&tracker, 7, Ev{7, 1, 2})
	testing.expect_value(t, len(tracker.out), 3) // emitted 1, emitted 2, cancelled 1
	testing.expect_value(t, tracker.out[1], view.Tracked(Ev){.Emitted, Ev{7, 1, 2}})
	testing.expect_value(t, tracker.out[2], view.Tracked(Ev){.Cancelled, Ev{7, 1, 1}})
	clear(&tracker.out)
	// tick 8 is first seen as it is verified: emitted and confirmed together; a predicted one of 8 that the
	// verified simulation drops is cancelled
	sim_tick(&tracker, 8, Ev{8, 3, 1})
	clear(&tracker.out)
	verify_tick(&tracker, 8, Ev{8, 4, 1})
	testing.expect_value(t, len(tracker.out), 4)
	testing.expect_value(t, tracker.out[0], view.Tracked(Ev){.Emitted, Ev{8, 4, 1}})
	testing.expect_value(t, tracker.out[1], view.Tracked(Ev){.Cancelled, Ev{8, 3, 1}})
	testing.expect_value(t, tracker.out[2], view.Tracked(Ev){.Confirmed, Ev{7, 1, 2}})
	testing.expect_value(t, tracker.out[3], view.Tracked(Ev){.Confirmed, Ev{8, 4, 1}})
}

// #152: a tick's cancels and confirmations come out in emission order (and ticks in order), whatever
// the map's order.
@(test)
events_keep_emission_order :: proc(t: ^testing.T) {
	tracker: view.Event_Tracker(Ev)
	view.tracker_init(&tracker, event_id)
	defer view.tracker_destroy(&tracker)
	tick10 := []Ev{{10, 9, 1}, {10, 2, 500}, {10, 7, 3}, {10, 2, 4}, {10, 1, 99}, {10, 5, 0}, {10, 8, 2}}
	tick11 := []Ev{{11, 3, 3}, {11, 1, 1}, {11, 2, 2}}
	sim_tick(&tracker, 10, ..tick10)
	sim_tick(&tracker, 11, ..tick11)
	clear(&tracker.out)
	view.tracker_verified(&tracker, 11)
	testing.expect_value(t, len(tracker.out), len(tick10) + len(tick11))
	for event, i in tick10 do testing.expect_value(t, tracker.out[i].event, event)
	for event, i in tick11 do testing.expect_value(t, tracker.out[len(tick10) + i].event, event)
	clear(&tracker.out)
	// cancels too: tick 12 predicted with five events, re-simulated with none
	tick12 := []Ev{{12, 4, 4}, {12, 1, 9}, {12, 3, 1}, {12, 2, 7}, {12, 6, 6}}
	sim_tick(&tracker, 12, ..tick12)
	clear(&tracker.out)
	sim_tick(&tracker, 12)
	testing.expect_value(t, len(tracker.out), len(tick12))
	for event, i in tick12 do testing.expect_value(t, tracker.out[i], view.Tracked(Ev){.Cancelled, event})
}

// track_push_prev (#284): a corrected tick - 1 goes into the error term, and a tick - 1 the history lacks starts
// from the last shown pose: the display never jumps.
@(test)
track_push_prev_glides :: proc(t: ^testing.T) {
	smoothing := view.Smoothing {
		tau_s         = 0.1,
		teleport_dist = 100,
	}
	track: view.Track
	view.track_push(&track, 1, {pos = {1, 0, 0}, rot = view.IDENTITY}, smoothing)
	view.track_push(&track, 2, {pos = {2, 0, 0}, rot = view.IDENTITY}, smoothing)
	shown := view.track_sample(&track, 2, 1, 0, smoothing) // at tick 2
	testing.expect_value(t, shown.pos.x, 2)
	// tick 3 after a rollback: tick 2 was really at 5, tick 3 at 6
	view.track_push_prev(&track, 3, {pos = {5, 0, 0}, rot = view.IDENTITY}, true, smoothing)
	view.track_push(&track, 3, {pos = {6, 0, 0}, rot = view.IDENTITY}, smoothing)
	glide := view.track_sample(&track, 3, 0, 0, smoothing)
	testing.expectf(t, abs(glide.pos.x - 2) < 1e-4, "no jump at the correction: %v", glide.pos.x)
	// the renderer skipped ticks 4 and 5: tick 6 starts from the last shown pose
	view.track_push_prev(&track, 6, {pos = {8, 0, 0}, rot = view.IDENTITY}, true, smoothing)
	view.track_push(&track, 6, {pos = {9, 0, 0}, rot = view.IDENTITY}, smoothing)
	start := view.track_sample(&track, 6, 0, 0, smoothing)
	testing.expectf(t, abs(start.pos.x - glide.pos.x) < 1e-4, "no jump after skipped ticks: %v", start.pos.x)
}
