package test_godot_driver

import "core:math"
import "core:sync"
import "core:testing"
import "core:thread"
import "unified:godot"

// ---- triple buffer and queue

Frame :: struct {
	seq:   u64,
	check: u64, // = seq * 3: a torn frame would break it
}

@(test)
triple_newest_wins :: proc(t: ^testing.T) {
	triple: godot.Triple(Frame)
	godot.triple_init(&triple)
	_, fresh := godot.triple_front(&triple)
	testing.expect(t, !fresh)
	for i in u64(1) ..= 3 {
		godot.triple_back(&triple)^ = {i, i * 3}
		godot.triple_publish(&triple)
	}
	frame, fresh2 := godot.triple_front(&triple)
	testing.expect(t, fresh2)
	testing.expect_value(t, frame.seq, 3)
	_, fresh3 := godot.triple_front(&triple)
	testing.expect(t, !fresh3)
}

@(test)
triple_threads_never_tear :: proc(t: ^testing.T) {
	Shared :: struct {
		triple: godot.Triple(Frame),
		done:   bool,
	}
	shared: Shared
	godot.triple_init(&shared.triple)
	writer := thread.create_and_start_with_data(&shared, proc(data: rawptr) {
		shared := (^Shared)(data)
		for i in u64(1) ..= 200_000 {
			godot.triple_back(&shared.triple)^ = {i, i * 3}
			godot.triple_publish(&shared.triple)
		}
		sync.atomic_store(&shared.done, true)
	})
	last: u64
	for !sync.atomic_load(&shared.done) {
		frame, fresh := godot.triple_front(&shared.triple)
		if !fresh do continue
		testing.expect_value(t, frame.check, frame.seq * 3)
		testing.expect(t, frame.seq > last)
		last = frame.seq
	}
	thread.join(writer)
	thread.destroy(writer)
	frame, _ := godot.triple_front(&shared.triple)
	testing.expect_value(t, frame.seq, 200_000)
}

@(test)
queue_spsc :: proc(t: ^testing.T) {
	queue: godot.Queue(int, 4)
	for i in 0 ..< 4 do testing.expect(t, godot.queue_push(&queue, i))
	testing.expect(t, !godot.queue_push(&queue, 99)) // full
	for i in 0 ..< 4 {
		item, ok := godot.queue_pop(&queue)
		testing.expect(t, ok)
		testing.expect_value(t, item, i)
	}
	_, ok := godot.queue_pop(&queue)
	testing.expect(t, godot.queue_peek(&queue) == nil)
	testing.expect(t, godot.queue_push(&queue, 7))
	testing.expect_value(t, godot.queue_peek(&queue)^, 7) // peeking leaves it queued
	item, popped := godot.queue_pop(&queue)
	testing.expect(t, popped && item == 7)
	testing.expect(t, !ok)
}

@(test)
alpha_clamps :: proc(t: ^testing.T) {
	testing.expect_value(t, godot.alpha(1000, 1000, 15625), 0)
	testing.expect_value(t, godot.alpha(1000 + 15625 / 2, 1000, 15625), f32(7812) / 15625)
	testing.expect_value(t, godot.alpha(99999, 1000, 15625), 1)
	testing.expect_value(t, godot.alpha(0, 1000, 15625), 0)
}

// ---- tracks

near :: proc(a, b: [3]f32, eps: f32 = 1e-4) -> bool {
	return godot.length(a - b) <= eps
}

at :: proc(x: f32) -> godot.Pose {
	return {{x, 0, 0}, godot.IDENTITY}
}

@(test)
track_interpolates :: proc(t: ^testing.T) {
	track: godot.Track
	godot.track_push(&track, 10, at(0))
	godot.track_push(&track, 11, at(1))
	pose := godot.track_sample(&track, 11, 0.25, 0.016)
	testing.expect(t, near(pose.pos, {0.25, 0, 0}), "lerp between ticks")
	// only one sample of the pair: shows the newest
	godot.track_push(&track, 12, at(2))
	pose = godot.track_sample(&track, 13, 0.5, 0.016)
	testing.expect(t, near(pose.pos, {2, 0, 0}))
}

@(test)
track_smooths_corrections :: proc(t: ^testing.T) {
	smoothing := godot.Smoothing {
		tau_s         = 0.1,
		teleport_dist = 4,
	}
	track: godot.Track
	godot.track_push(&track, 10, at(0), smoothing)
	godot.track_push(&track, 11, at(1), smoothing)
	before := godot.track_sample(&track, 11, 1, 0, smoothing)
	testing.expect(t, near(before.pos, {1, 0, 0}))
	// A rollback re-simulates tick 11 to x = 0.5: the display must not jump ...
	godot.track_push(&track, 11, at(0.5), smoothing)
	after := godot.track_sample(&track, 11, 1, 0, smoothing)
	testing.expect(t, near(after.pos, before.pos), "no jump on correction")
	// ... and converges with time constant tau: after 0.1 s, 1/e of the error is left.
	pose := godot.track_sample(&track, 11, 1, 0.1, smoothing)
	testing.expectf(t, near(pose.pos, {0.5 + 0.5 * 0.36788, 0, 0}, 1e-3), "decay: %v", pose.pos)
	for _ in 0 ..< 60 do pose = godot.track_sample(&track, 11, 1, 1.0 / 60, smoothing)
	testing.expect(t, near(pose.pos, {0.5, 0, 0}, 1e-3), "converged")
}

@(test)
track_teleports_snap :: proc(t: ^testing.T) {
	smoothing := godot.SMOOTHING_DEFAULT
	track: godot.Track
	godot.track_push(&track, 10, at(0), smoothing)
	godot.track_push(&track, 11, at(1), smoothing)
	_ = godot.track_sample(&track, 11, 1, 0, smoothing)
	godot.track_push(&track, 11, at(50), smoothing) // correction beyond teleport_dist: snap
	pose := godot.track_sample(&track, 11, 1, 0, smoothing)
	testing.expect(t, near(pose.pos, {50, 0, 0}))
	godot.track_push(&track, 12, at(100), smoothing) // a move beyond teleport_dist: no interpolation across it
	pose = godot.track_sample(&track, 12, 0.5, 0, smoothing)
	testing.expect(t, near(pose.pos, {100, 0, 0}))
}

@(test)
track_rotation_interpolates_and_smooths :: proc(t: ^testing.T) {
	smoothing := godot.SMOOTHING_DEFAULT
	track: godot.Track
	godot.track_push(&track, 1, {{}, quat_yaw_angle(0)}, smoothing)
	godot.track_push(&track, 2, {{}, quat_yaw_angle(1)}, smoothing)
	pose := godot.track_sample(&track, 2, 0.5, 0, smoothing)
	testing.expectf(t, abs(godot.yaw_of(pose.rot) - 0.5) < 1e-3, "yaw %v", godot.yaw_of(pose.rot))
	_ = godot.track_sample(&track, 2, 1, 0, smoothing)
	godot.track_push(&track, 2, {{}, quat_yaw_angle(0.5)}, smoothing)
	pose = godot.track_sample(&track, 2, 1, 0, smoothing)
	testing.expectf(t, abs(godot.yaw_of(pose.rot) - 1) < 1e-3, "no rotation jump: %v", godot.yaw_of(pose.rot))
	for _ in 0 ..< 120 do pose = godot.track_sample(&track, 2, 1, 1.0 / 60, smoothing)
	testing.expectf(t, abs(godot.yaw_of(pose.rot) - 0.5) < 1e-3, "converged: %v", godot.yaw_of(pose.rot))
}

// 2D angles in turns (about +Z): round trip across the circle, a quarter turn is +x to +y, interpolation through a
// track, and independence from yaw.
@(test)
angle2d_round_trips_and_interpolates :: proc(t: ^testing.T) {
	for turns in ([]f32{0, 0.125, -0.25, 0.4, 0.49, -0.45}) {
		testing.expectf(t, abs(godot.turns_2d_of(godot.quat_turns_2d(turns)) - turns) < 1e-5, "turns %v", turns)
		testing.expectf(t, abs(godot.yaw_of(godot.quat_turns_2d(turns))) < 1e-5, "turns %v has no yaw", turns)
	}
	quarter := godot.quat_turns_2d(0.25)
	testing.expectf(t, abs(quarter.z - quarter.w) < 1e-6 && quarter.z > 0, "a quarter turn: %v", quarter)
	testing.expect(t, abs(godot.turns_2d_of(godot.IDENTITY)) < 1e-6)
	track: godot.Track
	godot.track_push(&track, 1, {{}, godot.quat_turns_2d(0)})
	godot.track_push(&track, 2, {{}, godot.quat_turns_2d(0.25)})
	pose := godot.track_sample(&track, 2, 0.5, 0)
	testing.expectf(t, abs(godot.turns_2d_of(pose.rot) - 0.125) < 1e-3, "turns %v", godot.turns_2d_of(pose.rot))
}

@(test)
track_rollback_drops_newer_predictions :: proc(t: ^testing.T) {
	track: godot.Track
	for i in u32(1) ..= 4 do godot.track_push(&track, i, at(f32(i)))
	_ = godot.track_sample(&track, 4, 1, 0)
	godot.track_push(&track, 2, at(2)) // re-simulated from tick 2: ticks 3, 4 are stale
	_, has3 := godot.track_at(&track, 3)
	testing.expect(t, !has3)
	_, has2 := godot.track_at(&track, 2)
	testing.expect(t, has2)
}

// ---- view sets

@(test)
set_lifetimes :: proc(t: ^testing.T) {
	view_set: godot.View_Set(u64, int)
	defer godot.set_destroy(&view_set)
	next := 100
	frame :: proc(view_set: ^godot.View_Set(u64, int), keys: []u64, now: f64, next: ^int) -> (spawned: int) {
		godot.set_begin(view_set)
		for key in keys {
			entry, is_new, _ := godot.set_see(view_set, key)
			if is_new {
				entry.view = next^
				entry.linger_s = 0.5
				next^ += 1
				spawned += 1
			}
		}
		godot.set_end(view_set, now)
		return
	}
	testing.expect_value(t, frame(&view_set, {1, 2}, 0, &next), 2)
	testing.expect_value(t, frame(&view_set, {1, 2}, 0.1, &next), 0)
	// 2 disappears: lingers
	testing.expect_value(t, frame(&view_set, {1}, 0.2, &next), 0)
	testing.expect_value(t, len(view_set.despawned), 1)
	testing.expect_value(t, view_set.despawned[0], 2)
	testing.expect_value(t, godot.set_get(&view_set, 2).phase, godot.Phase.Lingering)
	// a rollback brings it back within the linger: same view, no respawn
	testing.expect_value(t, frame(&view_set, {1, 2}, 0.3, &next), 0)
	testing.expect_value(t, godot.set_get(&view_set, 2).view, 101)
	testing.expect_value(t, godot.set_get(&view_set, 2).phase, godot.Phase.Alive)
	// gone for good: removed after the linger
	_ = frame(&view_set, {1}, 1.0, &next)
	_ = frame(&view_set, {1}, 1.4, &next)
	testing.expect_value(t, len(view_set.removed), 0)
	_ = frame(&view_set, {1}, 1.6, &next)
	testing.expect_value(t, len(view_set.removed), 1)
	testing.expect_value(t, view_set.removed[0], 101)
	testing.expect(t, godot.set_get(&view_set, 2) == nil)
	// the same slot re-used under a new key gets a new view
	testing.expect_value(t, frame(&view_set, {1, 3}, 2, &next), 1)
	testing.expect_value(t, godot.set_get(&view_set, 3).view, 102)
	// removed at once, without a linger
	removed, ok := godot.set_remove(&view_set, 3)
	testing.expect(t, ok && removed == 102 && godot.set_get(&view_set, 3) == nil)
	_, ok = godot.set_remove(&view_set, 3)
	testing.expect(t, !ok)
}

// Views keyed by kind and key: the same key in two kinds is two views.
@(test)
set_wider_keys :: proc(t: ^testing.T) {
	Id :: struct {
		kind: u8,
		key:  u64,
	}
	view_set: godot.View_Set(Id, int)
	defer godot.set_destroy(&view_set)
	godot.set_begin(&view_set)
	a, spawned_a, _ := godot.set_see(&view_set, Id{0, 7})
	a.view = 1
	b, spawned_b, _ := godot.set_see(&view_set, Id{1, 7})
	b.view = 2
	godot.set_end(&view_set, 0)
	testing.expect(t, spawned_a && spawned_b)
	testing.expect_value(t, godot.set_get(&view_set, Id{0, 7}).view, 1)
	testing.expect_value(t, godot.set_get(&view_set, Id{1, 7}).view, 2)
}

// ---- predicted events

Ev :: struct {
	tick:   u32,
	kind:   u32,
	entity: u64,
}

event_id :: proc(event: Ev) -> godot.Event_Id {
	return {
		tick   = event.tick,
		kind   = event.kind,
		entity = event.entity,
	}
}

// One simulation of `tick` producing `events`, in order.
sim_tick :: proc(tracker: ^godot.Event_Tracker($E), tick: u32, events: ..E) {
	godot.tracker_begin_tick(tracker, tick)
	for event in events do godot.tracker_event(tracker, event)
	godot.tracker_end_tick(tracker, tick)
}

// The tick being verified, then the verification (what a session's verified hook does).
verify_tick :: proc(tracker: ^godot.Event_Tracker(Ev), tick: u32, events: ..Ev) {
	sim_tick(tracker, tick, ..events)
	godot.tracker_verified(tracker, tick)
}

@(test)
events_emitted_then_confirmed_or_cancelled :: proc(t: ^testing.T) {
	tracker: godot.Event_Tracker(Ev)
	godot.tracker_init(&tracker, event_id)
	defer godot.tracker_destroy(&tracker)
	boom := Ev{5, 1, 42}
	death := Ev{6, 2, 7}
	// predicted ticks 5, 6
	sim_tick(&tracker, 5, boom)
	sim_tick(&tracker, 6, death)
	testing.expect_value(t, len(tracker.out), 2)
	testing.expect_value(t, tracker.out[0], godot.Tracked(Ev){.Emitted, boom, 1})
	clear(&tracker.out)
	// rollback to 5: tick 5 produces the explosion again (not emitted twice), tick 6 no longer kills
	sim_tick(&tracker, 5, boom)
	sim_tick(&tracker, 6)
	testing.expect_value(t, len(tracker.out), 1)
	testing.expect_value(t, tracker.out[0], godot.Tracked(Ev){.Cancelled, death, 2})
	clear(&tracker.out)
	// tick 5 verified: confirmed once
	godot.tracker_verified(&tracker, 5)
	godot.tracker_verified(&tracker, 5)
	testing.expect_value(t, len(tracker.out), 1)
	testing.expect_value(t, tracker.out[0], godot.Tracked(Ev){.Confirmed, boom, 1})
	clear(&tracker.out)
	// re-simulating a verified tick (a rollback that starts there) emits nothing again
	sim_tick(&tracker, 5, boom)
	testing.expect_value(t, len(tracker.out), 0)
	// a re-simulated tick that produces a different event: emit the new one, cancel the old one
	sim_tick(&tracker, 7, Ev{7, 1, 1})
	sim_tick(&tracker, 7, Ev{7, 1, 2})
	testing.expect_value(t, len(tracker.out), 3) // emitted 1, emitted 2, cancelled 1
	testing.expect_value(t, tracker.out[1], godot.Tracked(Ev){.Emitted, Ev{7, 1, 2}, 4})
	testing.expect_value(t, tracker.out[2], godot.Tracked(Ev){.Cancelled, Ev{7, 1, 1}, 3})
	clear(&tracker.out)
	// tick 8 is first seen as it is verified: emitted and confirmed together; a predicted one of 8 that the
	// verified simulation drops is cancelled
	sim_tick(&tracker, 8, Ev{8, 3, 1})
	clear(&tracker.out)
	verify_tick(&tracker, 8, Ev{8, 4, 1})
	testing.expect_value(t, len(tracker.out), 4)
	testing.expect_value(t, tracker.out[0], godot.Tracked(Ev){.Emitted, Ev{8, 4, 1}, 6})
	testing.expect_value(t, tracker.out[1], godot.Tracked(Ev){.Cancelled, Ev{8, 3, 1}, 5})
	testing.expect_value(t, tracker.out[2], godot.Tracked(Ev){.Confirmed, Ev{7, 1, 2}, 4})
	testing.expect_value(t, tracker.out[3], godot.Tracked(Ev){.Confirmed, Ev{8, 4, 1}, 6})
}

// #240: an event keeps its serial from Emitted to Confirmed even when a re-simulation changes its data (Confirmed
// carries the final data); a cancelled event produced again is a new one; a new tracker continues the serials.
Hit :: struct {
	tick:   u32,
	entity: u64,
	at:     f32, // data: not part of the id
}

hit_id :: proc(hit: Hit) -> godot.Event_Id {
	return {tick = hit.tick, entity = hit.entity}
}

@(test)
events_keep_their_serial :: proc(t: ^testing.T) {
	tracker: godot.Event_Tracker(Hit)
	godot.tracker_init(&tracker, hit_id, 100)
	defer godot.tracker_destroy(&tracker)
	sim_tick(&tracker, 3, Hit{3, 1, 0.5}, Hit{3, 2, 0.5})
	testing.expect_value(t, tracker.out[0], godot.Tracked(Hit){.Emitted, Hit{3, 1, 0.5}, 101})
	testing.expect_value(t, tracker.out[1], godot.Tracked(Hit){.Emitted, Hit{3, 2, 0.5}, 102})
	clear(&tracker.out)
	// a rollback: the same hit lands elsewhere (same id, new data); the other one is gone
	sim_tick(&tracker, 3, Hit{3, 1, 0.75})
	testing.expect_value(t, len(tracker.out), 1)
	testing.expect_value(t, tracker.out[0], godot.Tracked(Hit){.Cancelled, Hit{3, 2, 0.5}, 102})
	clear(&tracker.out)
	// and back: the cancelled one is produced again, a new event
	sim_tick(&tracker, 3, Hit{3, 1, 0.75}, Hit{3, 2, 0.5})
	testing.expect_value(t, len(tracker.out), 1)
	testing.expect_value(t, tracker.out[0], godot.Tracked(Hit){.Emitted, Hit{3, 2, 0.5}, 103})
	clear(&tracker.out)
	godot.tracker_verified(&tracker, 3)
	testing.expect_value(t, tracker.out[0], godot.Tracked(Hit){.Confirmed, Hit{3, 1, 0.75}, 101})
	testing.expect_value(t, tracker.out[1], godot.Tracked(Hit){.Confirmed, Hit{3, 2, 0.5}, 103})
	next: godot.Event_Tracker(Hit)
	godot.tracker_init(&next, hit_id, tracker.last_serial)
	defer godot.tracker_destroy(&next)
	sim_tick(&next, 1, Hit{1, 1, 0})
	testing.expect_value(t, next.out[0].serial, 104)
}

// #152: a tick's cancels and confirmations come out in emission order (and ticks in order), whatever
// the map's order.
@(test)
events_keep_emission_order :: proc(t: ^testing.T) {
	tracker: godot.Event_Tracker(Ev)
	godot.tracker_init(&tracker, event_id)
	defer godot.tracker_destroy(&tracker)
	tick10 := []Ev{{10, 9, 1}, {10, 2, 500}, {10, 7, 3}, {10, 2, 4}, {10, 1, 99}, {10, 5, 0}, {10, 8, 2}}
	tick11 := []Ev{{11, 3, 3}, {11, 1, 1}, {11, 2, 2}}
	sim_tick(&tracker, 10, ..tick10)
	sim_tick(&tracker, 11, ..tick11)
	clear(&tracker.out)
	godot.tracker_verified(&tracker, 11)
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
	for event, i in tick12 do testing.expect_value(t, tracker.out[i], godot.Tracked(Ev){.Cancelled, event, tracker.out[i].serial})
}

// track_push_prev (#284): a corrected tick - 1 goes into the error term, and a tick - 1 the history lacks starts
// from the last shown pose: the display never jumps.
@(test)
track_push_prev_glides :: proc(t: ^testing.T) {
	smoothing := godot.Smoothing {
		tau_s         = 0.1,
		teleport_dist = 100,
	}
	track: godot.Track
	godot.track_push(&track, 1, {pos = {1, 0, 0}, rot = godot.IDENTITY}, smoothing)
	godot.track_push(&track, 2, {pos = {2, 0, 0}, rot = godot.IDENTITY}, smoothing)
	shown := godot.track_sample(&track, 2, 1, 0, smoothing) // at tick 2
	testing.expect_value(t, shown.pos.x, 2)
	// tick 3 after a rollback: tick 2 was really at 5, tick 3 at 6
	godot.track_push_prev(&track, 3, {pos = {5, 0, 0}, rot = godot.IDENTITY}, true, smoothing)
	godot.track_push(&track, 3, {pos = {6, 0, 0}, rot = godot.IDENTITY}, smoothing)
	glide := godot.track_sample(&track, 3, 0, 0, smoothing)
	testing.expectf(t, abs(glide.pos.x - 2) < 1e-4, "no jump at the correction: %v", glide.pos.x)
	// the renderer skipped ticks 4 and 5: tick 6 starts from the last shown pose
	godot.track_push_prev(&track, 6, {pos = {8, 0, 0}, rot = godot.IDENTITY}, true, smoothing)
	godot.track_push(&track, 6, {pos = {9, 0, 0}, rot = godot.IDENTITY}, smoothing)
	start := godot.track_sample(&track, 6, 0, 0, smoothing)
	testing.expectf(t, abs(start.pos.x - glide.pos.x) < 1e-4, "no jump after skipped ticks: %v", start.pos.x)
}

// Rotation about +Y by `yaw` radians (Godot's up axis).
quat_yaw_angle :: proc(yaw: f32) -> [4]f32 {
	return {0, math.sin(yaw * 0.5), 0, math.cos(yaw * 0.5)}
}

// ---- warp epochs and per-kind smoothing (Glue.view_policy)

// A 3-unit respawn that reaches the view as a rollback correction (shorter than teleport_dist): without a warp it
// glides from the old place; with the epoch bumped it is on the new pose in the first frame.
@(test)
track_warp_snaps_where_a_move_glides :: proc(t: ^testing.T) {
	smoothing := godot.SMOOTHING_DEFAULT
	frame :: proc(track: ^godot.Track, shown: ^u8, warp: u8, x: f32, smoothing: godot.Smoothing) -> f32 {
		godot.track_warp(track, shown, warp)
		godot.track_push(track, 11, at(x), smoothing)
		return godot.track_sample(track, 11, 1, 1.0 / 120, smoothing).pos.x
	}
	gliding, snapping: godot.Track
	glide_shown, snap_shown: u8
	for track in ([]^godot.Track{&gliding, &snapping}) {
		godot.track_push(track, 10, at(0.7), smoothing)
		godot.track_push(track, 11, at(0.7), smoothing)
		_ = godot.track_sample(track, 11, 1, 0, smoothing)
	}
	glided := frame(&gliding, &glide_shown, 0, 3.7, smoothing)
	snapped := frame(&snapping, &snap_shown, 1, 3.7, smoothing)
	testing.expectf(t, glided < 1, "the same move without a warp glides: %v", glided)
	testing.expectf(t, abs(snapped - 3.7) < 1e-4, "a warp snaps: %v", snapped)
	testing.expect_value(t, snap_shown, 1)
}

// The fill that carried the change was never shown (the triple buffer dropped it): the next one still differs from
// the shown epoch and snaps; a re-filled tick of the same epoch keeps gliding; an undone teleport snaps back.
@(test)
track_warp_against_the_shown_epoch :: proc(t: ^testing.T) {
	smoothing := godot.SMOOTHING_DEFAULT
	track: godot.Track
	shown: u8
	godot.track_push(&track, 10, at(0), smoothing)
	godot.track_push(&track, 11, at(0.1), smoothing)
	_ = godot.track_sample(&track, 11, 1, 0, smoothing)
	// tick 12's fill (warp 1, x = 3) dropped; tick 13's arrives with its tick - 1 pose
	testing.expect(t, godot.track_warp(&track, &shown, 1))
	godot.track_push_prev(&track, 13, at(3), true, smoothing)
	godot.track_push(&track, 13, at(3.1), smoothing)
	pose := godot.track_sample(&track, 13, 0, 0, smoothing)
	testing.expectf(t, abs(pose.pos.x - 3) < 1e-4, "snapped to the new epoch's tick - 1: %v", pose.pos.x)
	// a rollback re-fills 13 a little elsewhere, same epoch: a glide, no snap
	testing.expect(t, !godot.track_warp(&track, &shown, 1))
	_ = godot.track_sample(&track, 13, 1, 0, smoothing)
	godot.track_push(&track, 13, at(3.3), smoothing)
	pose = godot.track_sample(&track, 13, 1, 0, smoothing)
	testing.expectf(t, abs(pose.pos.x - 3.1) < 1e-4, "a correction in the same epoch glides: %v", pose.pos.x)
	// the verified timeline has no teleport: the old epoch comes back, the view snaps back
	testing.expect(t, godot.track_warp(&track, &shown, 0))
	godot.track_push(&track, 13, at(0.3), smoothing)
	pose = godot.track_sample(&track, 13, 1, 0, smoothing)
	testing.expectf(t, abs(pose.pos.x - 0.3) < 1e-4, "an undone teleport snaps back: %v", pose.pos.x)
	// 255 -> 0 is a change too
	shown = 255
	testing.expect(t, godot.track_warp(&track, &shown, 0))
}

// The session thread's memory gives no previous pose across a change of epoch, for scene views and instances: no
// interpolation and no correction estimate crosses a teleport.
@(test)
pose_memory_forgets_across_a_warp :: proc(t: ^testing.T) {
	fill :: proc(memory: ^godot.Pose_Memory, domain: godot.Pose_Domain, tick: u32, x: f32, warp: u8) -> bool {
		godot.pose_memory_begin(memory)
		_, found, _ := godot.pose_remember(memory, domain, 1, 7, tick, {x, 0, 0}, godot.IDENTITY, warp)
		return found
	}
	for domain in godot.Pose_Domain {
		memory: godot.Pose_Memory
		godot.pose_memory_init(&memory, 4, 4)
		defer godot.pose_memory_destroy(&memory)
		_ = fill(&memory, domain, 5, 0, 0)
		testing.expect(t, fill(&memory, domain, 6, 0.1, 0), "the same epoch: tick - 1 known")
		testing.expect(t, !fill(&memory, domain, 7, 3, 1), "a new epoch: no tick - 1")
		testing.expect(t, fill(&memory, domain, 8, 3.1, 1), "then known again")
		testing.expect(t, !fill(&memory, domain, 8, 0.2, 0), "a re-fill that undid the teleport: no estimate")
	}
}

// A view at rest stays unchanged (within float noise) across frames the main thread skipped: the glide that starts
// from the last shown pose leaves a correction of a few ulps, which must not re-pose a script-posed view every frame
// (the cold-start flake of the godot_views check "an unchanged pose is not handed over again").
@(test)
track_at_rest_across_skipped_frames :: proc(t: ^testing.T) {
	smoothing := godot.SMOOTHING_DEFAULT
	rest := godot.Pose{{1, 2, 3}, godot.qmul(quat_yaw_angle(0.75), [4]f32{0.149, 0, 0, 0.989})}
	track: godot.Track
	godot.track_push(&track, 1, rest, smoothing)
	godot.track_push_prev(&track, 2, rest, true, smoothing)
	godot.track_push(&track, 2, rest, smoothing)
	shown := godot.track_sample(&track, 2, 1, 0.016, smoothing)
	for tick in u32(5) ..< 40 {
		if tick % 3 != 0 do continue // the main thread skipped two of every three ticks
		godot.track_push_prev(&track, tick, rest, true, smoothing)
		godot.track_push(&track, tick, rest, smoothing)
		for alpha in ([]f32{0, 0.5, 1}) {
			pose := godot.track_sample(&track, tick, alpha, 0.016, smoothing)
			testing.expectf(t, godot.pose_unchanged(pose, shown), "tick %d: %v vs %v", tick, pose, shown)
		}
	}
}

// Appear-on-verified's `since`: kept across clean fills; reset by a rollback that re-simulated it; confirmed by a
// verified fill that has the key (also under steady rollbacks, where a reset alone would never let it appear); a key
// a rollback handed to another thing (missing from the verified fill) waits for its own.
@(test)
pose_memory_since :: proc(t: ^testing.T) {
	memory, verified: godot.Pose_Memory
	godot.pose_memory_init(&memory, 4, 4)
	defer godot.pose_memory_destroy(&memory)
	godot.pose_memory_init(&verified, 4, 4)
	defer godot.pose_memory_destroy(&verified)
	fill :: proc(memory: ^godot.Pose_Memory, tick, resim_from: u32, key: u64 = 7) -> u32 {
		godot.pose_memory_begin(memory, resim_from < tick, resim_from)
		_, _, since := godot.pose_remember(memory, .View, 1, key, tick, {}, godot.IDENTITY)
		return since
	}
	verified_fill :: proc(memory, verified: ^godot.Pose_Memory, tick: u32, keys: ..u64) {
		godot.pose_memory_begin(verified)
		for key in keys do godot.pose_remember(verified, .View, 1, key, tick, {}, godot.IDENTITY)
		memory.verified, memory.verified_tick = verified, tick
	}
	testing.expect_value(t, fill(&memory, 10, 10), 10) // first shown at 10
	testing.expect_value(t, fill(&memory, 11, 11), 10) // clean fills keep it
	testing.expect_value(t, fill(&memory, 12, 12), 10)
	testing.expect_value(t, fill(&memory, 14, 9), 14) // a rollback from 9 re-simulated 10: proves nothing
	// steady rollbacks: every fill re-simulates its `since`
	for tick in u32(15) ..< 20 do testing.expect_value(t, fill(&memory, tick, tick - 3), tick)
	verified_fill(&memory, &verified, 12, 7)
	testing.expect_value(t, fill(&memory, 20, 17), 12) // the verified fill at 12 had it: final at 12
	testing.expect_value(t, fill(&memory, 21, 21), 12)
	// another key (a handle a rollback gave another thing): not in the verified fill, counted from its fill
	testing.expect_value(t, fill(&memory, 22, 22, 9), 22)
	testing.expect(t, !godot.appear_now(.Verified, 22, 21) && godot.appear_now(.Verified, 22, 22))
	testing.expect(t, godot.appear_now(.Predicted, 22, 0), "a predicted kind shows at once")
}

// A zero policy is the default; tau_s < 0 snaps; teleport_dist defaults on its own.
@(test)
smoothing_of_fills_defaults :: proc(t: ^testing.T) {
	testing.expect_value(t, godot.smoothing_of({}), godot.SMOOTHING_DEFAULT)
	testing.expect_value(t, godot.smoothing_of({tau_s = 0.2}), godot.Smoothing{tau_s = 0.2, teleport_dist = 4})
	testing.expect_value(t, godot.smoothing_of({tau_s = -1, teleport_dist = 6}).tau_s, 0)
	snap := godot.smoothing_of({tau_s = -1})
	track: godot.Track
	godot.track_push(&track, 1, at(1), snap)
	_ = godot.track_sample(&track, 1, 1, 0, snap)
	godot.track_push(&track, 1, at(2), snap)
	pose := godot.track_sample(&track, 1, 1, 0, snap)
	testing.expectf(t, abs(pose.pos.x - 2) < 1e-4, "tau_s < 0 snaps a correction: %v", pose.pos.x)
}

// The correction left after `dt` of a correction of length `correction`.
correction_left :: proc(smoothing: godot.Smoothing, correction, dt: f32) -> f32 {
	track: godot.Track
	godot.track_push(&track, 1, at(0), smoothing)
	_ = godot.track_sample(&track, 1, 1, 0, smoothing)
	godot.track_push(&track, 1, at(correction), smoothing)
	return correction - godot.track_sample(&track, 1, 1, dt, smoothing).pos.x
}

// Two kinds, the same correction: each decays with its own tau.
@(test)
smoothing_per_kind :: proc(t: ^testing.T) {
	light := correction_left(godot.smoothing_of({tau_s = 0.05}), 1, 0.1)
	heavy := correction_left(godot.smoothing_of({tau_s = 0.2, teleport_dist = 6}), 1, 0.1)
	testing.expectf(t, abs(light - math.exp(f32(-2))) < 1e-3, "tau 0.05 after 0.1 s: %v", light)
	testing.expectf(t, abs(heavy - math.exp(f32(-0.5))) < 1e-3, "tau 0.2 after 0.1 s: %v", heavy)
}

// The ramp: a large error closes faster than the plain decay, a tiny one as the plain decay, and it never overshoots
// whatever the frame's length.
@(test)
smoothing_ramp :: proc(t: ^testing.T) {
	plain := godot.smoothing_of({tau_s = 0.2})
	ramp := godot.smoothing_of({tau_s = 0.2, ramp_dist = 2, ramp_tau_s = 0.05})
	large_ramp, large_plain := correction_left(ramp, 3, 0.05), correction_left(plain, 3, 0.05)
	testing.expectf(t, large_ramp < large_plain / 2, "large: %v vs %v", large_ramp, large_plain)
	tiny_ramp, tiny_plain := correction_left(ramp, 0.001, 0.05), correction_left(plain, 0.001, 0.05)
	testing.expectf(t, abs(tiny_ramp - tiny_plain) < 1e-5, "tiny: %v vs %v", tiny_ramp, tiny_plain)
	for dt in ([]f32{0.016, 0.1, 1, 10}) {
		rest := correction_left(ramp, 3, dt)
		testing.expectf(t, rest >= 0 && rest <= 3, "no overshoot at dt %v: %v", dt, rest)
	}
}
