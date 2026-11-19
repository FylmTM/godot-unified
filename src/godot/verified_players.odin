// Other players on the verified timeline (View_Policy.remote = .Verified): a scene view of such a kind that shows a
// player who isn't local is posed from final ticks only, played back VERIFIED_DELAY_TICKS behind the newest verified
// tick, instead of from the prediction: it never corrects, and it lags by about the round trip plus that delay.
// Everything else (the local players, the things a remote player carries, events) stays on the prediction. Dev UI
// builds can force it on for every kind (the Conditions panel, `--verified-players`), to compare with the prediction.
// The switch between the two is a snap: the view shows the other timeline's pose at once, with no glide.
//
// The session thread sends a sample of each player view per verified tick. A tick stepped as final is filled once more
// (the sim stands on it when netcode's `verified` hook runs); a tick verified because its prediction was right takes
// the pose the normal fill of that tick showed, kept in a ring by tick and dropped when a rollback re-simulates it. A
// tick no fill showed has no sample: playback interpolates across it. The main thread keeps each view's samples and a
// playback clock that runs at the tick rate, nudged toward its target by at most VERIFIED_RATE_MAX, never past the
// newest verified tick, and reset when it strays VERIFIED_WINDOW_TICKS from the target. Off (no kind asks for it, and
// not forced), it costs an atomic load per published and per verified tick.
package godot

import "core:sync"
import "unified:dmath"
import "unified:netcode"
import "unified:sim"

// How far behind the newest verified tick the playback clock aims (ticks): room for verified ticks arriving unevenly.
VERIFIED_DELAY_TICKS :: 4
// A playback clock this far from its target (ticks) jumps to it instead of drifting there.
VERIFIED_WINDOW_TICKS :: 12
// The most the playback clock runs faster or slower than the tick rate to reach its target (a fraction).
VERIFIED_RATE_MAX :: 0.02
// The samples a player view keeps on the main thread.
VERIFIED_HISTORY :: 32

@(private)
VERIFIED_RING :: 64 // the predicted fills the session thread keeps, by tick
@(private)
VERIFIED_PER_TICK :: 16 // the player views kept per tick

// One player view's pose at a verified tick, in sim units.
Verified_Sample :: struct {
	tick: u32,
	kind: u8,
	warp: u8, // its warp epoch: playback never interpolates across a change
	key:  u64,
	pose: Pose,
}

// A player view's verified samples (main thread): a ring, ticks increasing from the oldest.
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
// past the newest the newest's (no extrapolation); false when the history is empty.
verified_pose_at :: proc(history: ^Verified_History, play: f64, teleport_dist: f32) -> (pose: Pose, ok: bool) {
	if history.count == 0 do return
	newer := 0
	for newer < history.count && f64(verified_history_at(history, newer).tick) <= play do newer += 1
	if newer == 0 do return verified_history_at(history, 0).pose, true
	before := verified_history_at(history, newer - 1)
	if newer == history.count do return before.pose, true
	after := verified_history_at(history, newer)
	if before.warp != after.warp || dmath.length(after.pose.pos - before.pose.pos) > teleport_dist do return before.pose, true
	t := f32((play - f64(before.tick)) / f64(after.tick - before.tick))
	return {lerp3(before.pose.pos, after.pose.pos, t), nlerp(before.pose.rot, after.pose.rot, t)}, true
}

// The playback clock (a fractional tick) after a render frame of `dt_s`: it runs at `tick_hz` toward the target
// `verified` - VERIFIED_DELAY_TICKS, at most VERIFIED_RATE_MAX faster or slower, and never past `verified` (the newest
// verified tick). Not `started`, or VERIFIED_WINDOW_TICKS or more from the target, it is the target.
verified_clock_step :: proc(play: f64, started: bool, verified: u32, dt_s: f32, tick_hz: u32) -> f64 {
	target := f64(verified) - VERIFIED_DELAY_TICKS
	if !started || abs(target - play) >= VERIFIED_WINDOW_TICKS do return target
	rate := 1 + clamp((target - play) * 0.01, -VERIFIED_RATE_MAX, VERIFIED_RATE_MAX)
	return min(play + f64(max(dt_s, 0)) * f64(tick_hz) * rate, f64(verified))
}

// ---- the session thread

// Whether the dev UI forces every kind's remote players onto the verified timeline (atomic: the main thread sets it
// every frame).
@(private)
verified_players_on: bool

// The session thread's side, one per live session (when some kind asks for it, and in dev UI builds): the player views
// of recent predicted fills by tick, and the samples for the main thread.
Verified_Sampler :: struct {
	ring:   [VERIFIED_RING]Verified_Fill,
	queue:  Queue(Verified_Sample, 4096), // full: dropped (the main thread takes them every frame)
	was_on: bool,
	out:    Frame_Data, // a final tick's fill
	poses:  Pose_Memory, // left empty: a final tick's fill remembers no poses
}

// The player views one fill pushed.
@(private)
Verified_Fill :: struct {
	tick:    u32,
	valid:   bool, // no rollback re-simulated its tick since
	count:   int,
	samples: [VERIFIED_PER_TICK]Verified_Sample,
}

// A new sampler (at a session's start).
@(private)
verified_sampler_new :: proc() -> ^Verified_Sampler {
	sampler := new(Verified_Sampler)
	sampler.out.alloc = context.allocator
	return sampler
}

// Frees a sampler (nil: none) when its session is torn down.
@(private)
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
	on := api.remote_verified || sync.atomic_load(&verified_players_on)
	if !on && sampler.was_on do for &fill in sampler.ring do fill.valid = false
	sampler.was_on = on
	return on
}

// The player views of a fill of `tick`.
@(private)
verified_collect :: proc(out: ^Frame_Data, tick: u32, fill: ^Verified_Fill) {
	fill.tick, fill.valid, fill.count = tick, true, 0
	for &item in out.views[:out.n_views] {
		if item.player == 0 || fill.count == VERIFIED_PER_TICK do continue
		fill.samples[fill.count] = {
			tick = tick,
			kind = item.kind,
			warp = item.warp,
			key  = item.key,
			pose = {item.pos, item.rot},
		}
		fill.count += 1
	}
}

// After a live session's fill of `info.tick` (the frame hook): the ticks this step re-simulated before it are no longer
// what their fills showed; this one's player views are kept for when its tick is verified.
@(private)
verified_sampler_fill :: proc(sampler: ^Verified_Sampler, out: ^Frame_Data, info: netcode.Frame_Info) {
	if !verified_sampler_live(sampler) do return
	if info.tick - info.resim_from >= VERIFIED_RING {
		for &fill in sampler.ring do fill.valid = false
	} else {
		for tick in info.resim_from ..< info.tick do sampler.ring[tick % VERIFIED_RING].valid = false
	}
	verified_collect(out, info.tick, &sampler.ring[info.tick % VERIFIED_RING])
}

// A newly verified tick (netcode's `verified` hook): its player views to the main thread. Stepped as final, the sim
// stands on it and it is filled once more; verified because the prediction was right, the fill that showed it is
// final (none: no sample).
@(private)
verified_sampler_tick :: proc(driver: ^Driver($G, $View, $MultiView), simulation: ^sim.Sim(G), tick: u32) {
	sampler := driver.sampler
	if sampler == nil || driver.client == nil || !verified_sampler_live(sampler) do return
	fill := &sampler.ring[tick % VERIFIED_RING]
	if simulation.tick == tick {
		out := &sampler.out
		out.n_views, out.n_multis, out.n_data, out.n_datas, out.data_pushed = 0, 0, 0, 0, 0
		frame := Frame(G, View, MultiView) {
			state         = &simulation.state,
			world         = simulation.world,
			tick          = tick,
			local_players = frame_local_players(driver.client, simulation.state.players.slots[:], tick),
			seed          = simulation.seed,
			time          = sim.game_time(&simulation.state, tick),
			out           = out,
			poses         = &sampler.poses,
		}
		sync.atomic_store(&driver.in_fill, true) // the watchdog
		driver.glue.fill_frame(&frame)
		sync.atomic_store(&driver.in_fill, false)
		verified_collect(out, tick, fill)
	} else if !fill.valid || fill.tick != tick {
		return
	}
	verified_send(sampler, fill)
}

// A verified tick's player views to the main thread.
@(private)
verified_send :: proc(sampler: ^Verified_Sampler, fill: ^Verified_Fill) {
	for sample in fill.samples[:fill.count] do if !queue_push(&sampler.queue, sample) do break
}

// ---- the main thread

@(private)
VP: struct {
	forced:    bool, // the dev UI's switch, this frame
	wanted:    bool, // forced, or some kind asks for it
	sampler:   ^Verified_Sampler, // the session's whose samples the histories hold
	histories: map[View_Id]Verified_History,
	play:      f64, // the playback clock (a fractional tick)
	started:   bool,
}

// Main thread, every frame (dev UI builds): the dev UI's switch, for the views and the session thread.
@(private)
verified_players_want :: proc(on: bool) {
	VP.forced = on
	sync.atomic_store(&verified_players_on, on)
}

// Main thread, every frame before the views are posed: the session thread's samples into each view's history, and the
// playback clock.
@(private)
verified_players_sync :: proc(frame: ^Frame_Data, fresh: bool, dt_s: f32) {
	VP.wanted = VP.forced || api.remote_verified
	sampler := api.installed && api.sampler != nil ? api.sampler() : nil
	if !VP.wanted || sampler != VP.sampler {
		clear(&VP.histories)
		VP.sampler, VP.started = sampler, false
	}
	if sampler == nil do return
	for {
		sample := queue_pop(&sampler.queue) or_break
		if !VP.wanted do continue // samples of before it was switched off
		id := View_Id{sample.kind, sample.key}
		if id not_in VP.histories do VP.histories[id] = {}
		verified_history_push(&VP.histories[id], sample)
	}
	if !VP.wanted do return
	if fresh {
		// players gone for a while: their views went too
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
}

// The pose a scene view shows on the verified timeline (sim units): for a view of a Remote.Verified kind (any kind,
// when the dev UI forces it) that shows a player who isn't local and has samples.
@(private)
verified_players_pose :: proc(scene_view: ^Scene_View, frame: ^Frame_Data) -> (pose: Pose, ok: bool) {
	if !VP.wanted || !VP.started || scene_view.player == 0 do return
	if !VP.forced && kind_of(scene_view.kind).remote != .Verified do return
	for local in frame.local_players do if local == scene_view.player do return
	id := View_Id{scene_view.kind, scene_view.key}
	if id not_in VP.histories do return
	return verified_pose_at(&VP.histories[id], VP.play, kind_of(scene_view.kind).smoothing.teleport_dist)
}

// Forgets every history (main thread: the views were cleared).
@(private)
verified_players_clear :: proc() {
	delete(VP.histories)
	VP.histories, VP.sampler, VP.started = nil, nil, false
}
