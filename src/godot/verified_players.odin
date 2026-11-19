// Other players on the verified timeline (View_Policy.remote = .Verified): a scene view of such a kind that shows a
// player who isn't local is posed from final ticks only, played back VERIFIED_DELAY_TICKS behind the newest verified
// tick, instead of from the prediction: it never corrects, and it lags by about the round trip plus that delay. Its
// view data comes from the same samples and its events are delivered when playback reaches their tick, CONFIRMED only
// (the timeline is final: nothing is cancelled), so an effect lines up with the late body. It stays hidden until its
// first sample, and lingers after its key is gone until playback has shown its last one. Dev UI builds can force it on
// for every kind (the Conditions panel, `--verified-players`), to compare with the prediction.
//
// The session thread keeps a sample of each such view per verified tick: a tick stepped as final is filled once more
// (the sim stands on it when netcode's `verified` hook runs); a tick verified because its prediction was right takes
// what the normal fill of that tick showed, kept in a ring by tick and dropped when a rollback re-simulates it. A tick
// no fill showed has no sample: playback interpolates across it. The main thread keeps each view's samples and a
// playback clock that runs at the tick rate, nudged toward its target by at most VERIFIED_RATE_MAX, never past the
// newest verified tick, and reset when it strays VERIFIED_WINDOW_TICKS from the target. With no `.Verified` kind, a
// release build has no sampler: a nil check.
package godot

import "core:fmt"
import "core:sync"
import "unified:dmath"
import gd "unified:gdext"
import "unified:netcode"
import "unified:sim"

// How far behind the newest verified tick the playback clock aims (ticks): room for verified ticks arriving unevenly.
VERIFIED_DELAY_TICKS :: 4
// A playback clock this far from its target (ticks) jumps to it instead of drifting there.
VERIFIED_WINDOW_TICKS :: 12
// The most the playback clock runs faster or slower than the tick rate to reach its target (a fraction): a short stall
// of a few ticks is made up in about a second.
VERIFIED_RATE_MAX :: 0.1
// The samples a view keeps on the main thread.
VERIFIED_HISTORY :: 32
// The view data a sample carries, in bytes; a kind whose data is larger keeps the prediction's (reported once).
VERIFIED_DATA_MAX :: 96

@(private)
VERIFIED_RING :: 64 // the predicted fills the session thread keeps, by tick
@(private)
VERIFIED_PER_TICK :: 48 // the views kept per tick (more: dropped, reported once)

// One view's pose and data at a verified tick, in sim units.
Verified_Sample :: struct {
	tick:      u32,
	kind:      u8,
	warp:      u8, // its warp epoch: playback never interpolates across a change
	data_size: u8, // bytes of `data` (0: none, or more than VERIFIED_DATA_MAX)
	key:       u64,
	pose:      Pose,
	data_type: typeid, // nil: no data
	data:      [VERIFIED_DATA_MAX]u8,
}

// A view's verified samples (main thread): a ring, ticks increasing from the oldest.
Verified_History :: struct {
	samples: [VERIFIED_HISTORY]Verified_Sample,
	head:    u32, // where the next sample goes
	count:   int,
}

// Appends a sample. The newest tick again replaces it; an older tick starts the history over (a new timeline: another
// session, a seek).
verified_history_push :: proc(history: ^Verified_History, sample: Verified_Sample) {
	if history.count > 0 {
		newest := verified_history_at(history, history.count - 1)
		if sample.tick == newest.tick {
			newest^ = sample
			return
		}
		if sample.tick < newest.tick do history.count = 0
	}
	history.samples[history.head % VERIFIED_HISTORY] = sample
	history.head += 1
	history.count = min(history.count + 1, VERIFIED_HISTORY)
}

// The history's `index`th sample, the oldest first.
@(private)
verified_history_at :: proc(history: ^Verified_History, index: int) -> ^Verified_Sample {
	return &history.samples[(history.head - u32(history.count) + u32(index)) % VERIFIED_HISTORY]
}

// The pose at `play` (a fractional tick): between the samples around it, but never across a warp or a jump longer than
// `teleport_dist` (it holds the older one until the newer one's tick). Before the oldest sample it is the oldest's,
// past the newest the newest's (no extrapolation); false when the history is empty. `at` is the sample at or before
// `play` (the oldest when none is): the one whose data shows.
verified_pose_at :: proc(
	history: ^Verified_History,
	play: f64,
	teleport_dist: f32,
) -> (
	pose: Pose,
	ok: bool,
	at: ^Verified_Sample,
) {
	if history.count == 0 do return
	newer := 0
	for newer < history.count && f64(verified_history_at(history, newer).tick) <= play do newer += 1
	if newer == 0 {
		at = verified_history_at(history, 0)
		return at.pose, true, at
	}
	before := verified_history_at(history, newer - 1)
	if newer == history.count do return before.pose, true, before
	after := verified_history_at(history, newer)
	if before.warp != after.warp || dmath.length(after.pose.pos - before.pose.pos) > teleport_dist {
		return before.pose, true, before
	}
	t := f32((play - f64(before.tick)) / f64(after.tick - before.tick))
	return {lerp3(before.pose.pos, after.pose.pos, t), nlerp(before.pose.rot, after.pose.rot, t)}, true, before
}

// The playback clock (a fractional tick) after a render frame of `dt_s`: it runs at `tick_hz` toward the target
// `verified` - VERIFIED_DELAY_TICKS, at most VERIFIED_RATE_MAX faster or slower, and never past `verified` (the newest
// verified tick). Not `started`, or VERIFIED_WINDOW_TICKS or more from the target, it is the target.
verified_clock_step :: proc(play: f64, started: bool, verified: u32, dt_s: f32, tick_hz: u32) -> f64 {
	target := f64(verified) - VERIFIED_DELAY_TICKS
	if !started || abs(target - play) >= VERIFIED_WINDOW_TICKS do return target
	rate := 1 + clamp((target - play) * 0.05, -VERIFIED_RATE_MAX, VERIFIED_RATE_MAX)
	return min(play + f64(max(dt_s, 0)) * f64(tick_hz) * rate, f64(verified))
}

// Whether views of `kind` play on the verified timeline when they show a remote player: its policy says so, or the dev
// UI forces it (`forced`).
verified_kind :: proc(kind: u8, forced: bool) -> bool {
	return forced || (int(kind) < len(api.view_policy) && api.view_policy[kind].remote == .Verified)
}

// ---- the session thread

// Whether the dev UI forces every kind's remote players onto the verified timeline (atomic: the main thread sets it
// every frame).
@(private)
verified_players_on: bool

// Sessions' samplers so far: each new one's generation, so the main thread tells a new session's from the last one's.
@(private)
verified_generations: u64

// The session thread's side, one per live session (when some kind asks for it, and in dev UI builds): the views of
// recent predicted fills by tick, and the samples for the main thread (`queue`, popped with queue_pop).
Verified_Sampler :: struct {
	generation: u64,
	kinds:      [256]bool, // the view kinds whose policy is .Verified
	any_kind:   bool, // some is
	ring:       [VERIFIED_RING]Verified_Fill,
	queue:      Queue(Verified_Sample, 2048), // full: dropped (the main thread takes them every frame)
	was_on:     bool,
	overflow:   bool, // atomic: a fill had more views than VERIFIED_PER_TICK (the main thread reports it once)
	too_big:    u8, // atomic: a kind (+1) whose data is past VERIFIED_DATA_MAX (0: none)
	out:        Frame_Data, // a final tick's fill (the driver's)
	poses:      Pose_Memory, // left empty: a final tick's fill remembers no poses
}

// The views one fill pushed.
@(private)
Verified_Fill :: struct {
	tick:    u32,
	valid:   bool, // no rollback re-simulated its tick since
	count:   int,
	samples: [VERIFIED_PER_TICK]Verified_Sample,
}

// A new sampler for a session whose `.Verified` view kinds are `kinds` (none: only the dev UI's switch turns it on).
// verified_sampler_free frees it.
verified_sampler_new :: proc(kinds: []u8) -> ^Verified_Sampler {
	sampler := new(Verified_Sampler)
	sampler.generation = sync.atomic_add(&verified_generations, 1) + 1
	for kind in kinds do sampler.kinds[kind] = true
	sampler.any_kind = len(kinds) > 0
	sampler.out.alloc = context.allocator
	return sampler
}

// Frees a sampler (nil: none) when its session is torn down.
verified_sampler_free :: proc(sampler: ^Verified_Sampler) {
	if sampler == nil do return
	delete(sampler.out.views, sampler.out.alloc)
	delete(sampler.out.multis, sampler.out.alloc)
	delete(sampler.out.data, sampler.out.alloc)
	free(sampler)
}

// Whether sampling is on: some kind asks for it, or the dev UI forces it. Switched off, the ring is dropped: the
// rollbacks while off were not seen.
@(private)
verified_sampler_live :: proc(sampler: ^Verified_Sampler) -> bool {
	on := sampler.any_kind || sync.atomic_load(&verified_players_on)
	if !on && sampler.was_on do for &fill in sampler.ring do fill.valid = false
	sampler.was_on = on
	return on
}

// The views of a fill of `tick` that may play on the verified timeline: every player view of a `.Verified` kind (a
// local player's too: a view whose player changes needs its samples), every player view when forced.
@(private)
verified_collect :: proc(sampler: ^Verified_Sampler, out: ^Frame_Data, tick: u32, fill: ^Verified_Fill) {
	forced := sync.atomic_load(&verified_players_on)
	fill.tick, fill.valid, fill.count = tick, true, 0
	for &item in out.views[:out.n_views] {
		if item.player == 0 || !(forced || sampler.kinds[item.kind]) do continue
		if fill.count == VERIFIED_PER_TICK {
			sync.atomic_store(&sampler.overflow, true)
			break
		}
		sample := &fill.samples[fill.count]
		sample^ = {
			tick = tick,
			kind = item.kind,
			warp = item.warp,
			key  = item.key,
			pose = {item.pos, item.rot},
		}
		if item.data_type != nil {
			if item.data_size <= VERIFIED_DATA_MAX {
				sample.data_type, sample.data_size = item.data_type, u8(item.data_size)
				copy(sample.data[:], out.data[item.data_offset:][:item.data_size])
			} else {
				sync.atomic_store(&sampler.too_big, item.kind + 1)
			}
		}
		fill.count += 1
	}
}

// Session thread, after the fill of `info.tick` (netcode's frame hook; `out` its views): the ticks this step
// re-simulated before it are no longer what their fills showed; this one's views are kept for when its tick is
// verified.
verified_sampler_fill :: proc(sampler: ^Verified_Sampler, out: ^Frame_Data, info: netcode.Frame_Info) {
	if !verified_sampler_live(sampler) do return
	if info.tick - info.resim_from >= VERIFIED_RING {
		for &fill in sampler.ring do fill.valid = false
	} else {
		for tick in info.resim_from ..< info.tick do sampler.ring[tick % VERIFIED_RING].valid = false
	}
	verified_collect(sampler, out, info.tick, &sampler.ring[info.tick % VERIFIED_RING])
}

// Session thread, a newly verified `tick` (netcode's verified hook): its samples to the queue. `final` is its fill
// when it was stepped as final (the sim stands on it); nil when it was verified because the prediction was right: the
// kept fill that showed it is final (none, or one a rollback re-simulated since: no sample).
verified_sampler_verified :: proc(sampler: ^Verified_Sampler, tick: u32, final: ^Frame_Data) {
	if !verified_sampler_live(sampler) do return
	fill := &sampler.ring[tick % VERIFIED_RING]
	if final != nil {
		verified_collect(sampler, final, tick, fill)
	} else if !fill.valid || fill.tick != tick {
		return
	}
	for sample in fill.samples[:fill.count] do if !queue_push(&sampler.queue, sample) do break
}

// The driver's verified hook: a tick stepped as final is filled once more (a second fill_frame for that tick).
@(private)
verified_sampler_tick :: proc(driver: ^Driver($G, $View, $MultiView), simulation: ^sim.Sim(G), tick: u32) {
	sampler := driver.sampler
	if sampler == nil || driver.client == nil || !verified_sampler_live(sampler) do return
	if simulation.tick != tick {
		verified_sampler_verified(sampler, tick, nil)
		return
	}
	out := &sampler.out
	out.n_views, out.n_multis, out.n_data, out.n_datas, out.data_pushed = 0, 0, 0, 0, 0
	local_players := frame_local_players(driver.client, simulation.state.players.slots[:], tick)
	frame := make_frame(driver, simulation, &simulation.state, tick, local_players, out, &sampler.poses)
	run_fill(driver, &frame)
	verified_sampler_verified(sampler, tick, out)
}

// ---- the main thread

@(private)
VP: struct {
	forced:     bool, // the dev UI's switch, this frame
	wanted:     bool, // forced, or some kind asks for it
	generation: u64, // the session's sampler whose samples the histories hold (0: none)
	histories:  map[View_Id]Verified_History,
	play:       f64, // the playback clock (a fractional tick)
	started:    bool,
	locals:     [LOCAL_MAX]u64, // the shown frame's local players (keys)
	pending:    [dynamic]Verified_Event, // events waiting for playback to reach their tick, in arrival order
}

// A remote view's event, held until playback reaches its tick.
@(private)
Verified_Event :: struct {
	view:  View_Id,
	tick:  u32,
	event: gd.Variant, // a reference to its UnifiedEvent
}

// Main thread, every frame (dev UI builds): the dev UI's switch, for the views and the session thread.
@(private)
verified_players_want :: proc(on: bool) {
	VP.forced = on
	sync.atomic_store(&verified_players_on, on)
}

// Main thread, every frame before the views are posed: the session thread's samples into each view's history, the
// playback clock, and the held events playback has reached to their views.
@(private)
verified_players_sync :: proc(frame: ^Frame_Data, fresh: bool, dt_s: f32) {
	VP.wanted = VP.forced || api.remote_verified
	sampler := api.installed && api.sampler != nil ? api.sampler() : nil
	generation := sampler != nil ? sampler.generation : 0
	if !VP.wanted || generation != VP.generation {
		verified_players_forget()
		VP.generation = generation
	}
	if sampler == nil do return
	VP.locals = frame.local_players
	if sync.atomic_load(&sampler.overflow) {
		report_once(
			"verified-overflow",
			fmt.tprintf(
				"unified: more than %d views of .Verified kinds in one tick: the rest show late without samples",
				VERIFIED_PER_TICK,
			),
		)
	}
	if kind := sync.atomic_load(&sampler.too_big); kind > 0 {
		report_once(
			"verified-data",
			fmt.tprintf(
				"unified: view kind %d's data is larger than %d bytes: its remote views keep the prediction's data",
				kind - 1,
				VERIFIED_DATA_MAX,
			),
		)
	}
	for {
		sample := queue_pop(&sampler.queue) or_break
		if !VP.wanted do continue // samples of before it was switched off
		id := View_Id{sample.kind, sample.key}
		if id not_in VP.histories do VP.histories[id] = {}
		verified_history_push(&VP.histories[id], sample)
	}
	if !VP.wanted do return
	if fresh {
		// views gone for a while: their histories went too
		gone := make([dynamic]View_Id, context.temp_allocator)
		for id, &history in VP.histories {
			if history.count == 0 ||
			   verified_history_at(&history, history.count - 1).tick + VERIFIED_RING < frame.verified {
				append(&gone, id)
			}
		}
		for id in gone do delete_key(&VP.histories, id)
	}
	VP.play = verified_clock_step(VP.play, VP.started, frame.verified, dt_s, frame.tick_hz)
	VP.started = true
	// the held events playback reached, in order, to their views if they are still there
	delivered := 0
	for &held in VP.pending {
		if f64(held.tick) > VP.play do break
		if entry := set_get(&V.set, held.view); entry != nil do call_sim_event_now(entry.view, held.event, i64(Event_Action.Confirmed))
		gd.variant_destroy(&held.event)
		delivered += 1
	}
	if delivered > 0 do remove_range(&VP.pending, 0, delivered)
}

// Whether a scene view plays on the verified timeline now: its kind does, and it shows a player who isn't local.
@(private)
verified_players_applies :: proc(scene_view: ^Scene_View) -> bool {
	if !VP.wanted || scene_view.player == 0 || !verified_kind(scene_view.kind, VP.forced) do return false
	for local in VP.locals do if local == scene_view.player do return false
	return true
}

// How a scene view is posed this frame: from the prediction (`applies` false), hidden (it plays on the verified
// timeline and has no sample yet), or the verified pose (sim units) with the sample whose data shows (`at`).
@(private)
verified_players_pose :: proc(scene_view: ^Scene_View) -> (pose: Pose, applies: bool, at: ^Verified_Sample) {
	if !verified_players_applies(scene_view) do return {}, false, nil
	applies = true
	if !VP.started do return
	history, has := &VP.histories[View_Id{scene_view.kind, scene_view.key}]
	if !has do return
	ok: bool
	pose, ok, at = verified_pose_at(history, VP.play, kind_of(scene_view.kind).smoothing.teleport_dist)
	if !ok do at = nil
	return
}

// Whether a view whose key is gone from the frame keeps showing: it plays on the verified timeline and playback isn't
// a tick past its last sample yet (it lingers until its late pose got there and showed).
@(private)
verified_players_keeps :: proc(scene_view: ^Scene_View) -> bool {
	if scene_view == nil || !verified_players_applies(scene_view) do return false
	history, has := &VP.histories[View_Id{scene_view.kind, scene_view.key}]
	return has && history.count > 0 && f64(verified_history_at(history, history.count - 1).tick) + 1 > VP.play
}

// An event for a view that plays on the verified timeline: held until playback reaches `tick` and delivered CONFIRMED
// then (true); an EMITTED or CANCELLED one is dropped (true: the final timeline has neither). False: the view is on the
// prediction, deliver it now.
@(private)
verified_players_hold :: proc(scene_view: ^Scene_View, event: gd.Variant, state: i64, tick: u32) -> bool {
	if !verified_players_applies(scene_view) do return false
	if state == i64(Event_Action.Confirmed) {
		append(&VP.pending, Verified_Event{View_Id{scene_view.kind, scene_view.key}, tick, gd.variant_from_any(event)})
	}
	return true
}

// Forgets every history and held event (main thread: another session, the views cleared, the option off).
@(private)
verified_players_forget :: proc() {
	clear(&VP.histories)
	for &held in VP.pending do gd.variant_destroy(&held.event)
	clear(&VP.pending)
	VP.started = false
}

// Frees what the verified timeline holds (main thread: the views were cleared).
@(private)
verified_players_clear :: proc() {
	verified_players_forget()
	delete(VP.histories)
	delete(VP.pending)
	VP.histories, VP.pending, VP.generation = nil, nil, 0
}
