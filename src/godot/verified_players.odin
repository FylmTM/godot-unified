// Other players on the verified timeline (View_Policy.remote = .Verified): a scene view of such a kind that shows a
// player who isn't local is posed from final ticks only, played back a few ticks behind the newest verified tick
// (VERIFIED_DELAY_TICKS, adapting to the gaps between samples), instead of from the prediction: it never corrects, and
// it lags by about the round trip plus that delay. Its view data comes from the same samples and its events are
// delivered when its pose reaches their tick, CONFIRMED only (the timeline is final: nothing is cancelled), so an effect
// lines up with the late body. It stays hidden until its first sample, and when its key leaves it stays until playback
// reaches the tick it left at. A replay has no sampler (every tick it shows is final). Dev UI builds can force it on
// for every kind (the Conditions panel, `--verified-players`), to compare with the prediction.
//
// The session thread keeps a sample of each such view per verified tick: a tick stepped as final is filled once more
// (the sim stands on it when netcode's `verified` hook runs); a tick verified because its prediction was right takes
// what the normal fill of that tick showed, kept in a ring by tick and dropped when a rollback re-simulates it. A tick
// no fill showed has no sample: playback interpolates across it. The main thread keeps each view's samples and a
// playback clock that runs at the tick rate, nudged toward its target by at most VERIFIED_RATE_MAX, never past the
// newest verified tick, and reset when it strays VERIFIED_WINDOW_TICKS from the target. With no `.Verified` kind, a
// release build has no sampler: a nil check.
//
// A sample's view data rides with it, whatever its kind's size: every holder of samples (the fills' ring, the queue to
// the main thread, each view's history) keeps their data in one flat buffer beside them, a slot per sample. The
// session's slots are as wide as its largest `.Verified` kind, allocated when it starts; the dev UI's switch, which
// forces every kind, widens them to the largest kind once, the first time it is on (the session thread's ring at once,
// the queue with a second buffer the samples queued from then on use: the main thread may be reading the first). A
// view's history has slots of its own kind's size, allocated when the view first plays late. Nothing allocates on a
// step otherwise. A session holds VERIFIED_RING × VERIFIED_PER_TICK + VERIFIED_QUEUE slots and each remote view
// VERIFIED_HISTORY more, so install refuses a kind whose data is past VIEW_DATA_MAX.
package godot

import "core:fmt"
import "core:sync"
import "unified:dmath"
import gd "unified:gdext"
import "unified:netcode"
import "unified:sim"

// How far behind the newest verified tick the playback clock aims (ticks), at least: room for verified ticks arriving
// unevenly. It adapts to the gaps between samples (a tick no fill showed has none, so the newest sample can be a few
// ticks behind the newest verified tick): the delay is the widest recent gap (Verified_Gaps), between this and
// VERIFIED_DELAY_MAX, so playback doesn't run past the newest sample and stall.
VERIFIED_DELAY_TICKS :: 4
// The most the playback delay grows to (ticks), however far apart samples come.
VERIFIED_DELAY_MAX :: 10
// A playback clock this far from its target (ticks) jumps to it instead of drifting there.
VERIFIED_WINDOW_TICKS :: 12
// The most the playback clock runs faster or slower than the tick rate to reach its target (a fraction): a short stall
// of a few ticks is made up in about a second.
VERIFIED_RATE_MAX :: 0.1
// The samples a view keeps on the main thread.
VERIFIED_HISTORY :: 32
// The most bytes of view data a scene view kind has (its View_ struct's size; this much is accepted): install refuses
// a kind past it. Samples on the verified timeline carry their data in slots of the largest sampled kind's size (the
// file's header), so this bounds what a session holds for them: VERIFIED_RING × VERIFIED_PER_TICK + VERIFIED_QUEUE
// slots, 20 MiB at this bound, and VERIFIED_HISTORY slots (128 KiB) per remote view.
VIEW_DATA_MAX :: 4096

@(private)
VERIFIED_RING :: 64 // the predicted fills the session thread keeps, by tick
@(private)
VERIFIED_PER_TICK :: 48 // the views kept per tick (more: dropped, reported once)
@(private)
VERIFIED_QUEUE :: 2048 // the samples on their way to the main thread (more: dropped, reported once)

// One view's pose at a verified tick, in sim units, and its view data's type and size (the bytes are in a slot beside
// it, in whatever holds it: verified_sampler_peek, verified_pose_at).
Verified_Sample :: struct {
	tick:      u32,
	kind:      u8,
	warp:      u8, // its warp epoch: playback never interpolates across a change
	data_size: u16, // bytes of view data (0: none)
	key:       u64,
	pose:      Pose,
	wide:      bool, // queued, its data is in the sampler's wide buffer (`queue_wide`)
	data_type: typeid, // nil: no data
}

// A view's verified samples (main thread): a ring, ticks increasing from the oldest, and their view data in a slot of
// `stride` bytes each (verified_history_make).
Verified_History :: struct {
	samples: [VERIFIED_HISTORY]Verified_Sample,
	data:    []u8, // VERIFIED_HISTORY slots, by the samples' ring index (nil: stride 0, no data)
	stride:  int,
	head:    u32, // where the next sample goes
	count:   int,
}

// A history whose samples carry up to `stride` bytes of view data: it allocates VERIFIED_HISTORY × `stride` bytes,
// freed by verified_history_destroy. A zero history holds samples without data.
verified_history_make :: proc(stride: int) -> Verified_History {
	return {data = stride > 0 ? make([]u8, VERIFIED_HISTORY * stride) : nil, stride = stride}
}

// Frees a history's data (verified_history_make).
verified_history_destroy :: proc(history: ^Verified_History) {
	delete(history.data)
	history.data = nil
}

// Appends a sample with its view data (`data`: sample.data_size bytes, at most the history's stride; copied). The
// newest tick again replaces it; an older tick starts the history over (a new timeline: another session, a seek).
verified_history_push :: proc(history: ^Verified_History, sample: Verified_Sample, data: []u8 = nil) {
	assert(len(data) == int(sample.data_size) && len(data) <= history.stride)
	ring_slot := history.head % VERIFIED_HISTORY
	if history.count > 0 {
		newest_slot := (history.head - 1) % VERIFIED_HISTORY
		newest := &history.samples[newest_slot]
		if sample.tick == newest.tick {
			newest^ = sample
			copy(history.data[int(newest_slot) * history.stride:], data)
			return
		}
		if sample.tick < newest.tick do history.count = 0
	}
	history.samples[ring_slot] = sample
	copy(history.data[int(ring_slot) * history.stride:], data)
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
// `play` (the oldest when none is): the one whose data shows, `data` (valid until the next push).
verified_pose_at :: proc(
	history: ^Verified_History,
	play: f64,
	teleport_dist: f32,
) -> (
	pose: Pose,
	ok: bool,
	at: ^Verified_Sample,
	data: []u8,
) {
	if history.count == 0 do return
	newer := 0
	for newer < history.count && f64(verified_history_at(history, newer).tick) <= play do newer += 1
	shown := max(newer - 1, 0)
	at, data, ok = verified_history_at(history, shown), verified_history_data(history, shown), true
	pose = at.pose
	if newer == 0 || newer == history.count do return
	after := verified_history_at(history, newer)
	if at.warp != after.warp || dmath.length(after.pose.pos - at.pose.pos) > teleport_dist do return
	t := f32((play - f64(at.tick)) / f64(after.tick - at.tick))
	pose = {lerp3(at.pose.pos, after.pose.pos, t), nlerp(at.pose.rot, after.pose.rot, t)}
	return
}

// The history's `index`th sample's view data, the oldest first (nil: none). Valid until the next push.
@(private)
verified_history_data :: proc(history: ^Verified_History, index: int) -> []u8 {
	ring_slot := int((history.head - u32(history.count) + u32(index)) % VERIFIED_HISTORY)
	size := int(history.samples[ring_slot].data_size)
	return size > 0 ? history.data[ring_slot * history.stride:][:size] : nil
}

// The playback clock (a fractional tick) after a render frame of `dt_s`: it runs at `tick_hz` toward the target
// `verified` - `delay` (verified_delay), at most VERIFIED_RATE_MAX faster or slower, and never past `verified` (the
// newest verified tick). Not `started`, or VERIFIED_WINDOW_TICKS or more from the target, it is the target.
verified_clock_step :: proc(play: f64, started: bool, verified: u32, delay: f64, dt_s: f32, tick_hz: u32) -> f64 {
	target := f64(verified) - delay
	if !started || abs(target - play) >= VERIFIED_WINDOW_TICKS do return target
	rate := 1 + clamp((target - play) * 0.05, -VERIFIED_RATE_MAX, VERIFIED_RATE_MAX)
	return min(play + f64(max(dt_s, 0)) * f64(tick_hz) * rate, f64(verified))
}

// The widest recent gap between a view's consecutive samples (ticks; 1: none missing), which the playback delay covers:
// it widens at once and narrows a tick per second.
Verified_Gaps :: struct {
	peak:    u32,
	decay_s: f32, // since it last narrowed
}

// A gap of `gap` ticks between two samples of a view. One wider than VERIFIED_RING is a view coming back after a while,
// not a run of unsampled ticks: ignored.
verified_gaps_see :: proc(gaps: ^Verified_Gaps, gap: u32) {
	if gap <= VERIFIED_RING && gap > gaps.peak do gaps.peak, gaps.decay_s = gap, 0
}

// A render frame of `dt_s`: the peak narrows by a tick each second.
verified_gaps_step :: proc(gaps: ^Verified_Gaps, dt_s: f32) {
	gaps.decay_s += max(dt_s, 0)
	for gaps.decay_s >= 1 {
		gaps.decay_s -= 1
		if gaps.peak > 0 do gaps.peak -= 1
	}
}

// The playback delay for these gaps (ticks): the widest, within VERIFIED_DELAY_TICKS ..= VERIFIED_DELAY_MAX.
verified_delay :: proc(gaps: Verified_Gaps) -> f64 {
	return f64(clamp(gaps.peak, VERIFIED_DELAY_TICKS, VERIFIED_DELAY_MAX))
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
// recent predicted fills by tick, and the samples for the main thread (`queue`: verified_sampler_peek, queue_pop).
Verified_Sampler :: struct {
	generation:    u64,
	kinds:         [256]bool, // the view kinds whose policy is .Verified
	any_kind:      bool, // some is
	forced_stride: int, // the slot width the dev UI's switch needs: the largest kind's data (0: no switch)
	ring:          [VERIFIED_RING]Verified_Fill,
	ring_stride:   int, // the most bytes of view data a fill's sample carries: a slot of `ring_data`
	ring_data:     []u8, // the fills' samples' view data, a slot per sample (VERIFIED_RING × VERIFIED_PER_TICK)
	queue:         Queue(Verified_Sample, VERIFIED_QUEUE), // full: dropped (the main thread takes them every frame)
	queue_stride:  int, // a slot of `queue_data`
	queue_data:    []u8, // the queued samples' view data, a slot per queue index (VERIFIED_QUEUE)
	// The same at forced_stride (nil until the dev UI's switch is first on), for every sample queued from then on
	// (Verified_Sample.wide): the main thread may still be reading `queue_data`.
	queue_wide:    []u8,
	was_on:        bool,
	forced:        bool, // the dev UI's switch as verified_sampler_live last read it: the slots are wide when on
	overflow:      bool, // atomic: a fill had more views than VERIFIED_PER_TICK (the main thread reports it once)
	dropped:       bool, // atomic: the queue was full (the main thread reports it once)
	out:           Frame_Data, // a final tick's fill (the driver's)
	poses:         Pose_Memory, // left empty: a final tick's fill remembers no poses
}

// The views one fill pushed.
@(private)
Verified_Fill :: struct {
	tick:    u32,
	valid:   bool, // no rollback re-simulated its tick since
	count:   int,
	samples: [VERIFIED_PER_TICK]Verified_Sample,
	data:    []u8, // its samples' view data, a slot each: its part of the sampler's ring_data
}

// A new sampler for a session whose `.Verified` view kinds are `kinds` (none: only the dev UI's switch turns it on).
// Its samples carry up to `data_stride` bytes of view data, the largest View_ struct of those kinds, and up to
// `forced_stride` once the dev UI's switch forces every kind: the largest of them all (0: a build without the switch).
// Both are at most VIEW_DATA_MAX. It allocates (VERIFIED_RING × VERIFIED_PER_TICK + VERIFIED_QUEUE) × `data_stride`
// bytes for their data, and that many at `forced_stride` the first time the switch is on (verified_sampler_live);
// verified_sampler_free frees it.
verified_sampler_new :: proc(kinds: []u8, data_stride: int, forced_stride := 0) -> ^Verified_Sampler {
	assert(data_stride >= 0 && data_stride <= VIEW_DATA_MAX && forced_stride <= VIEW_DATA_MAX)
	sampler := new(Verified_Sampler)
	sampler.generation = sync.atomic_add(&verified_generations, 1) + 1
	for kind in kinds do sampler.kinds[kind] = true
	sampler.any_kind = len(kinds) > 0
	sampler.forced_stride = forced_stride
	sampler.queue_stride = data_stride
	if data_stride > 0 do sampler.queue_data = make([]u8, VERIFIED_QUEUE * data_stride)
	verified_ring_resize(sampler, data_stride)
	sampler.out.alloc = context.allocator
	return sampler
}

// The fills' slots at `stride` bytes (session thread): a new ring_data, the kept samples' data moved into it.
@(private)
verified_ring_resize :: proc(sampler: ^Verified_Sampler, stride: int) {
	old, old_stride := sampler.ring_data, sampler.ring_stride
	sampler.ring_data = stride > 0 ? make([]u8, VERIFIED_RING * VERIFIED_PER_TICK * stride) : nil
	sampler.ring_stride = stride
	fill_bytes := VERIFIED_PER_TICK * stride
	for &fill, i in sampler.ring {
		previous := fill.data
		fill.data = sampler.ring_data[i * fill_bytes:][:fill_bytes]
		for sample, j in fill.samples[:fill.count] {
			size := int(sample.data_size)
			copy(fill.data[j * stride:][:size], previous[j * old_stride:][:size])
		}
	}
	delete(old)
}

// Frees a sampler (nil: none) when its session is torn down.
verified_sampler_free :: proc(sampler: ^Verified_Sampler) {
	if sampler == nil do return
	delete(sampler.out.views, sampler.out.alloc)
	frame_multis_free(&sampler.out)
	delete(sampler.out.data, sampler.out.alloc)
	delete(sampler.ring_data)
	delete(sampler.queue_data)
	delete(sampler.queue_wide)
	free(sampler)
}

// The oldest sample the session thread queued and its view data (main thread; nil: none), valid until
// queue_pop(&sampler.queue) takes it.
verified_sampler_peek :: proc(sampler: ^Verified_Sampler) -> (sample: ^Verified_Sample, data: []u8) {
	index, queued := queue_oldest_index(&sampler.queue)
	if !queued do return
	sample = &sampler.queue.items[index]
	if sample.data_size == 0 do return
	// a wide sample was pushed after queue_wide was set (the push releases what this index acquired)
	buffer, stride := sampler.queue_data, sampler.queue_stride
	if sample.wide do buffer, stride = sampler.queue_wide, sampler.forced_stride
	return sample, buffer[index * stride:][:sample.data_size]
}

// Whether sampling is on: some kind asks for it, or the dev UI forces it. Switched off, the ring is dropped: the
// rollbacks while off were not seen. Forced the first time, the slots widen to forced_stride.
@(private)
verified_sampler_live :: proc(sampler: ^Verified_Sampler) -> bool {
	forced := sync.atomic_load(&verified_players_on)
	on := sampler.any_kind || forced
	if !on && sampler.was_on do for &fill in sampler.ring do fill.valid = false
	sampler.was_on, sampler.forced = on, forced
	if forced && sampler.ring_stride < sampler.forced_stride {
		verified_ring_resize(sampler, sampler.forced_stride)
		sampler.queue_wide = make([]u8, VERIFIED_QUEUE * sampler.forced_stride)
	}
	return on
}

// The views of a fill of `tick` that may play on the verified timeline: every player view of a `.Verified` kind (a
// local player's too: a view whose player changes needs its samples), every player view when forced.
@(private)
verified_collect :: proc(sampler: ^Verified_Sampler, out: ^Frame_Data, tick: u32, fill: ^Verified_Fill) {
	fill.tick, fill.valid, fill.count = tick, true, 0
	for &item in out.views[:out.n_views] {
		if item.player == 0 || !(sampler.forced || sampler.kinds[item.kind]) do continue
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
		if item.data_type != nil && item.data_size > 0 {
			// the slot is the largest data of the kinds sampled (verified_sampler_new, verified_sampler_live)
			assert(
				int(item.data_size) <= sampler.ring_stride,
				"a view's data is wider than the verified samples' slot",
			)
			sample.data_type, sample.data_size = item.data_type, u16(item.data_size)
			slot := fill.data[fill.count * sampler.ring_stride:][:item.data_size]
			copy(slot, out.data[item.data_offset:][:item.data_size])
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
	wide := sampler.queue_wide != nil // from then on every sample's data goes there
	buffer, stride := sampler.queue_data, sampler.queue_stride
	if wide do buffer, stride = sampler.queue_wide, sampler.forced_stride
	for &sample, i in fill.samples[:fill.count] {
		index, room := queue_next_index(&sampler.queue)
		if !room {
			sync.atomic_store(&sampler.dropped, true)
			break
		}
		size := int(sample.data_size)
		copy(buffer[index * stride:][:size], fill.data[i * sampler.ring_stride:][:size])
		sample.wide = wide
		queue_push(&sampler.queue, sample)
	}
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
	wanted:     bool, // a session samples (not a replay), and the switch or some kind asks for it
	overflowed: bool, // the session thread dropped views past VERIFIED_PER_TICK: a view without samples stays predicted
	generation: u64, // the session's sampler whose samples the histories hold (0: none)
	histories:  map[View_Id]Verified_History,
	gaps:       Verified_Gaps,
	play:       f64, // the playback clock (a fractional tick)
	started:    bool,
	locals:     [LOCAL_MAX]u64, // the shown frame's local players (keys)
	pending:    [dynamic]Verified_Event, // events waiting for their view's pose to reach their tick, in arrival order
}

// A remote view's event, held until its pose reaches its tick.
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
// playback clock, and the held events their views' poses reached. No sampler (a replay, where every tick is final; no
// session): nothing plays late.
@(private)
verified_players_sync :: proc(frame: ^Frame_Data, fresh: bool, dt_s: f32) {
	sampler := api.installed && api.sampler != nil ? api.sampler() : nil
	VP.wanted = (VP.forced || api.remote_verified) && sampler != nil
	generation := sampler != nil ? sampler.generation : 0
	if !VP.wanted || generation != VP.generation {
		verified_players_forget()
		VP.generation = generation
	}
	if sampler == nil do return
	VP.locals = frame.local_players
	VP.overflowed = sync.atomic_load(&sampler.overflow)
	if VP.overflowed {
		report_once(
			"verified-overflow",
			fmt.tprintf(
				"unified: more than %d views of .Verified kinds in one tick: the rest stay on the prediction",
				VERIFIED_PER_TICK,
			),
		)
	}
	if sync.atomic_load(&sampler.dropped) {
		report_once(
			"verified-dropped",
			"unified: the verified timeline's samples came faster than the main thread took them: some were dropped",
		)
	}
	for {
		sample, data := verified_sampler_peek(sampler)
		if sample == nil do break
		if VP.wanted { 	// (else a sample of before it was switched off)
			id := View_Id{sample.kind, sample.key}
			if id not_in VP.histories do VP.histories[id] = verified_history_make(api.view_types[sample.kind].size)
			history := &VP.histories[id]
			if history.count > 0 {
				newest := verified_history_at(history, history.count - 1).tick
				if sample.tick > newest do verified_gaps_see(&VP.gaps, sample.tick - newest)
			}
			verified_history_push(history, sample^, data)
		}
		_, _ = queue_pop(&sampler.queue)
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
		for id in gone {
			_, history := delete_key(&VP.histories, id)
			verified_history_destroy(&history)
		}
	}
	verified_gaps_step(&VP.gaps, dt_s)
	VP.play = verified_clock_step(VP.play, VP.started, frame.verified, verified_delay(VP.gaps), dt_s, frame.tick_hz)
	VP.started = true
	// the held events whose view's pose reached their tick, in order (a view gone: dropped; one now on the prediction:
	// at once)
	kept := 0
	for &held in VP.pending {
		entry := set_get(&V.set, held.view)
		if entry != nil && entry.view != nil && verified_players_applies(entry.view) {
			if f64(held.tick) > verified_shown_tick(held.view) {
				VP.pending[kept] = held
				kept += 1
				continue
			}
		}
		if entry != nil do call_sim_event_now(entry.view, held.event, i64(Event_Action.Confirmed))
		gd.variant_destroy(&held.event)
	}
	resize(&VP.pending, kept)
}

// The tick a view's verified pose shows: the playback clock, or its newest sample's tick when playback is past it.
@(private)
verified_shown_tick :: proc(id: View_Id) -> f64 {
	history, has := &VP.histories[id]
	if !has || history.count == 0 do return -1
	return min(VP.play, f64(verified_history_at(history, history.count - 1).tick))
}

// Whether a scene view plays on the verified timeline now: its kind does, it has a pose (a data-only view, a Control,
// has none to delay: it stays on the prediction), and it shows a player who isn't local. While the session thread
// drops views past VERIFIED_PER_TICK, one with no samples stays on the prediction.
@(private)
verified_players_applies :: proc(scene_view: ^Scene_View) -> bool {
	if !VP.wanted || scene_view.player == 0 || scene_view.mode == .Other do return false
	if !verified_kind(scene_view.kind, VP.forced) do return false
	for local in VP.locals do if local == scene_view.player do return false
	return !VP.overflowed || View_Id{scene_view.kind, scene_view.key} in VP.histories
}

// How a scene view is posed this frame: from the prediction (`applies` false), hidden (it plays on the verified
// timeline and has no sample yet), or the verified pose (sim units) with the sample whose data shows (`at`, its view
// data `data`).
@(private)
verified_players_pose :: proc(
	scene_view: ^Scene_View,
) -> (
	pose: Pose,
	applies: bool,
	at: ^Verified_Sample,
	data: []u8,
) {
	if !verified_players_applies(scene_view) do return
	applies = true
	if !VP.started do return
	history, has := &VP.histories[View_Id{scene_view.kind, scene_view.key}]
	if !has do return
	ok: bool
	pose, ok, at, data = verified_pose_at(history, VP.play, kind_of(scene_view.kind).smoothing.teleport_dist)
	if !ok do at, data = nil, nil
	return
}

// Whether a view whose key is missing from the frame keeps showing: it plays on the verified timeline and playback
// hasn't reached `gone_tick`, the tick of the first frame that lacked its key (it lingers until its late pose got
// there).
@(private)
verified_players_keeps :: proc(scene_view: ^Scene_View, gone_tick: u32) -> bool {
	return scene_view != nil && verified_players_applies(scene_view) && f64(gone_tick) > VP.play
}

// A view on the verified timeline leaves: its held events are delivered now (its pose showed what it got to).
@(private)
verified_players_flush :: proc(id: View_Id, scene_view: ^Scene_View) {
	kept := 0
	for &held in VP.pending {
		if held.view != id {
			VP.pending[kept] = held
			kept += 1
			continue
		}
		call_sim_event_now(scene_view, held.event, i64(Event_Action.Confirmed))
		gd.variant_destroy(&held.event)
	}
	resize(&VP.pending, kept)
}

// An event for a view that plays on the verified timeline: held until its pose reaches `tick` and delivered CONFIRMED
// then (true); an EMITTED or CANCELLED one is dropped (true: the final timeline has neither). False: deliver it now,
// the view is on the prediction, or it is CONFIRMED and its pose reached `tick` already. The events are drained after
// the views are posed, so a frame whose playback strides past `tick` (a long frame, a jump to the target) takes it
// here, after verified_players_sync released the held ones: held, it would come a frame late. The ones still held are
// past the shown tick, and confirmations come in tick order, so delivering it now keeps the view's events in order.
@(private)
verified_players_hold :: proc(scene_view: ^Scene_View, event: gd.Variant, state: i64, tick: u32) -> bool {
	if !verified_players_applies(scene_view) do return false
	if state != i64(Event_Action.Confirmed) do return true
	id := View_Id{scene_view.kind, scene_view.key}
	if f64(tick) <= verified_shown_tick(id) do return false
	append(&VP.pending, Verified_Event{id, tick, gd.variant_from_any(event)})
	return true
}

// Forgets every history, and delivers the held events to their views now (main thread: another session, the session
// ended, the option off).
@(private)
verified_players_forget :: proc() {
	for _, &history in VP.histories do verified_history_destroy(&history)
	clear(&VP.histories)
	for &held in VP.pending {
		if entry := set_get(&V.set, held.view); entry != nil do call_sim_event_now(entry.view, held.event, i64(Event_Action.Confirmed))
		gd.variant_destroy(&held.event)
	}
	clear(&VP.pending)
	VP.started, VP.gaps, VP.overflowed = false, {}, false
}

// Frees what the verified timeline holds (main thread: the views were cleared, so the held events go undelivered).
@(private)
verified_players_clear :: proc() {
	for &held in VP.pending do gd.variant_destroy(&held.event)
	clear(&VP.pending)
	verified_players_forget()
	delete(VP.histories)
	delete(VP.pending)
	VP.histories, VP.pending, VP.generation = nil, nil, 0
}
