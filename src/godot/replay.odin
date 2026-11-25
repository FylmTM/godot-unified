// The replay session (src/godot/README.md, Replays): UnifiedSession.replay(folder) plays an F3 note, a session
// recording or a freeze folder through the game's own views, HUD and dev UI, with pause, step, speed, seek and loop.
// It feeds the sim from the recording instead of the network: no input, no commands, every tick final (its events
// arrive Emitted and Confirmed together), the recording's checkpoints checked as it passes them. It shows the
// verified timeline: what a client predicted at the time is not in a recording.
package godot

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:time"
import "unified:netcode"
import "unified:sim"

// How far before a note's tick its replay starts (it plays up to the noted tick and pauses there).
@(private)
REPLAY_LEAD_S :: 10

// How long one replay_step may spend stepping toward a seek's target before it lets the loop come round (the
// watchdog sees a step end, a stop is honoured, a newer control read): a long seek is many short steps.
@(private)
REPLAY_SEEK_BUDGET :: 8 * time.Millisecond

// The slowest and fastest replay speeds.
@(private)
REPLAY_SPEED_MIN :: 0.25
@(private)
REPLAY_SPEED_MAX :: 4

// What the main thread sees of a replay (Frame_Data.replay; zero: not a replay).
@(private)
Replay_View :: struct {
	active:      bool,
	first, last: u32, // the ticks it can show: the recording's first (its snapshot's) to its last
	paused:      bool,
	speed:       f32,
	loop:        [2]u32, // a range it plays over and over ({0, 0}: none)
	follow:      u64, // the player whose views and camera it follows (local_player)
	checkpoints: int, // checkpoints compared so far
	agreed:      u32, // the last checkpoint that agreed (0: none yet)
	diverged:    u32, // the first that didn't (0: none): "recorded by another build" or a real divergence
	other_build: bool, // recorded by another build (replayed against its checkpoints)
}

// A replay control from the main thread (UnifiedSession's replay methods; a small queue).
@(private)
Replay_Control :: struct {
	kind:  enum u8 {
		Pause,
		Play,
		Speed,
		Step, // value: ticks, negative back
		Seek, // value: the tick
		Loop, // value, value2: the range (0, 0: none)
		Follow, // value: a player's key
	},
	value: i64,
	other: i64,
	speed: f32,
}

// A keyframe: a portable snapshot of a tick the replay passed, for seeking back past the ring.
@(private)
Keyframe :: struct {
	tick:  u32,
	bytes: []u8,
}

// The replay's state (session thread; Driver.replay).
@(private)
Replay :: struct($G: typeid) {
	simulation:  ^sim.Sim(G),
	log:         sim.Input_Log(G),
	checkpoints: []sim.Checkpoint, // sorted by tick
	view:        Replay_View,
	stop_at:     u32, // a note's tick: play up to it, then pause (0: none)
	done:        bool, // at its last tick with Start.quit: the session ends
	due_us:      i64, // when the playhead's tick was due on the session clock
	keyframes:   [dynamic]Keyframe, // by tick; [0]: the recording's own start
	every:       u32, // keyframe spacing in ticks
	next_check:  int, // the first checkpoint not behind the playhead (checkpoints are sorted): replay_forward's cursor
	seeking:     bool, // a seek is on its way to seek_to: nothing is shown until it arrives (replay_seek_run)
	seek_to:     u32,
}

// The files a replay folder holds (an F3 note's, a session recording's, a freeze's).
@(private)
Replay_Folder_Json :: struct {
	player: u64, // note.json, session.json: who recorded it
	tick:   u32, // note.json: the noted tick
}

// Opens a replay from the folder in Start.arg (session thread): the log, the snapshot it continues (if any), whose
// it is; false with a Failed status saying why.
@(private)
replay_open :: proc(driver: ^Driver($G, $View, $MultiView)) -> bool {
	folder := driver.req.arg
	fail :: proc(driver: ^Driver($G, $View, $MultiView), why: string) -> bool {
		post_status(driver, .Failed, why)
		return false
	}
	log_bytes, log_err := os.read_entire_file(fmt.tprintf("%s/inputs.unil", folder), context.temp_allocator)
	if log_err != nil do return fail(driver, fmt.tprintf("replay: no inputs.unil in %s", folder))
	input_log, log_ok := sim.log_decode(log_bytes, G)
	if !log_ok do return fail(driver, "replay: inputs.unil is not a recording of this game (or of another log version)")
	replay := new(Replay(G))
	replay.log = input_log
	driver.replay = replay
	snapshot, snapshot_err := os.read_entire_file(fmt.tprintf("%s/snapshot.unis", folder), context.allocator)
	other_build := input_log.compat != 0 && input_log.compat != sim.compat_of(driver.game)
	if snapshot_err == nil {
		simulation, err := sim.from_snapshot(driver.game, snapshot, any_build = true)
		if err != .None {
			delete(snapshot)
			return fail(driver, fmt.tprintf("replay: the snapshot does not load: %v", err))
		}
		replay.simulation = simulation
		append(&replay.keyframes, Keyframe{simulation.tick, snapshot})
	} else {
		replay.simulation = sim.create(driver.game, input_log.seed, input_log.setup)
		append(&replay.keyframes, Keyframe{0, nil})
	}
	if replay.simulation.tick != input_log.from {
		return fail(
			driver,
			fmt.tprintf(
				"replay: the log continues tick %d, its snapshot is tick %d",
				input_log.from,
				replay.simulation.tick,
			),
		)
	}
	sim.dev_attach(replay.simulation, replay_clock)
	replay.checkpoints = make([]sim.Checkpoint, len(input_log.checkpoints))
	copy(replay.checkpoints, input_log.checkpoints[:])
	sort_checkpoints(replay.checkpoints)
	replay.view = {
		active      = true,
		first       = input_log.from,
		last        = input_log.from + u32(len(input_log.ticks)),
		speed       = 1,
		other_build = other_build,
	}
	replay.every = max(256, u32(len(input_log.ticks)) / 64)
	about: Replay_Folder_Json
	for name in ([]string{"note.json", "session.json"}) {
		text, err := os.read_entire_file(fmt.tprintf("%s/%s", folder, name), context.temp_allocator)
		if err == nil do _ = json.unmarshal(text, &about)
	}
	replay.view.follow = about.player
	replay.view.paused = driver.req.paused
	if about.tick > replay.view.first {
		// a note opens before its moment and stops on it; a note's tick past the recording (one noted ahead of the
		// verified ticks the recording holds) stops on its last
		lead := u32(REPLAY_LEAD_S * driver.game.tick_hz)
		replay.stop_at = min(about.tick, replay.view.last)
		if replay.stop_at > replay.view.first + lead do replay_seek(driver, replay.stop_at - lead)
		replay_seek_run(driver, max(time.Duration)) // before the watchdog runs and anything is shown
	}
	replay.due_us = netcode.now_us()
	post_status(driver, .Connected, other_build ? "recorded by another build: checked against its checkpoints" : "")
	replay_publish(driver, replay.simulation.tick)
	return true
}

// The zones' clock in a replay (sim.dev_attach).
@(private)
replay_clock :: proc "contextless" () -> i64 {
	return time.tick_now()._nsec
}

@(private)
sort_checkpoints :: proc(checkpoints: []sim.Checkpoint) {
	for i in 1 ..< len(checkpoints) {
		for j := i; j > 0 && checkpoints[j - 1].tick > checkpoints[j].tick; j -= 1 {
			checkpoints[j - 1], checkpoints[j] = checkpoints[j], checkpoints[j - 1]
		}
	}
}

// Frees the replay (the session's end).
@(private)
replay_close :: proc(driver: ^Driver($G, $View, $MultiView)) {
	replay := driver.replay
	if replay == nil do return
	if replay.simulation != nil do sim.destroy(replay.simulation)
	sim.log_destroy(&replay.log)
	delete(replay.checkpoints)
	for keyframe in replay.keyframes do delete(keyframe.bytes)
	delete(replay.keyframes)
	free(replay)
	driver.replay = nil
}

// One loop of the replay (session thread): the controls, then every tick due on the playhead's clock (at the
// replay's speed), then the Frame of the playhead's tick. A seek on its way takes the loop instead, for at most
// REPLAY_SEEK_BUDGET, and comes back at once until it arrives. Returns when to come back.
@(private)
replay_step :: proc(driver: ^Driver($G, $View, $MultiView), now: i64) -> (wake: i64) {
	replay := driver.replay
	for {
		control := queue_pop(&driver.replay_controls) or_break
		// where the playhead is, or goes: a seek on its way counts as arrived (a step after a seek steps from its target)
		playhead := replay.seek_to if replay.seeking else replay.simulation.tick
		switch control.kind {
		case .Pause:
			replay.view.paused = true
		case .Play:
			if playhead >= replay.view.last do replay_seek(driver, replay.view.first)
			replay.view.paused, replay.due_us, replay.stop_at = false, now, 0
		case .Speed:
			replay.view.speed = clamp(control.speed, REPLAY_SPEED_MIN, REPLAY_SPEED_MAX)
		case .Step:
			replay.view.paused = true
			target := clamp(i64(playhead) + control.value, i64(replay.view.first), i64(replay.view.last))
			replay_seek(driver, u32(target))
		case .Seek:
			replay_seek(driver, u32(clamp(control.value, i64(replay.view.first), i64(replay.view.last))))
			replay.due_us = now
		case .Loop:
			from, to := u32(max(control.value, 0)), u32(max(control.other, 0))
			replay.view.loop = from < to ? {max(from, replay.view.first), min(to, replay.view.last)} : {}
		case .Follow:
			replay.view.follow = u64(control.value)
		}
	}
	tick_us := i64(1_000_000 / f32(driver.game.tick_hz) / replay.view.speed)
	stepped := false
	if replay.seeking {
		if !replay_seek_run(driver, REPLAY_SEEK_BUDGET) do return now
		replay.due_us, stepped = now, true
	}
	for !replay.view.paused && now - replay.due_us >= tick_us {
		if loop := replay.view.loop; loop != {} && replay.simulation.tick >= loop[1] {
			replay_seek(driver, loop[0])
			if !replay_seek_run(driver, REPLAY_SEEK_BUDGET) do return now
		}
		if replay.simulation.tick >= replay.view.last ||
		   (replay.stop_at != 0 && replay.simulation.tick >= replay.stop_at) {
			replay.view.paused = true // the end (or the note's tick): it stays there until leave()
			replay.done = driver.req.quit && replay.simulation.tick >= replay.view.last
			break
		}
		replay_forward(driver)
		replay.due_us += tick_us
		stepped = true
	}
	if replay.view.paused do replay.due_us = now - tick_us // alpha 1: the screen shows exactly the tick
	if stepped || replay.view.paused do replay_publish(driver, replay.simulation.tick)
	return replay.view.paused ? now + 16_000 : replay.due_us + tick_us
}

// Steps the playhead one tick forward: its events Emitted and Confirmed at once, its checkpoint compared, a keyframe
// kept every `every` ticks.
@(private)
replay_forward :: proc(driver: ^Driver($G, $View, $MultiView), publish := true) {
	replay := driver.replay
	simulation := replay.simulation
	inputs := sim.log_inputs(&replay.log, int(simulation.tick - replay.log.from))
	sim.step(simulation, &inputs)
	tick := simulation.tick
	if publish {
		track_tick(driver, tick, sim.events_at(simulation, tick))
		tracker_verified(&driver.tracker, tick)
		flush_events(driver)
	}
	for replay.next_check < len(replay.checkpoints) && replay.checkpoints[replay.next_check].tick < tick {
		replay.next_check += 1
	}
	if replay.next_check < len(replay.checkpoints) && replay.checkpoints[replay.next_check].tick == tick {
		checkpoint := replay.checkpoints[replay.next_check]
		replay.next_check += 1
		replay.view.checkpoints += 1
		if checksum := sim.checksum(simulation); checksum == checkpoint.checksum {
			if replay.view.diverged == 0 do replay.view.agreed = tick
		} else if replay.view.diverged == 0 {
			replay.view.diverged = tick
			post_text(
				driver,
				.Desync,
				fmt.tprintf(
					"replay: first divergent checkpoint, tick %d; last agreeing: tick %d",
					tick,
					replay.view.agreed,
				),
			)
		}
	}
	if tick % replay.every == 0 && tick > replay.keyframes[len(replay.keyframes) - 1].tick {
		append(&replay.keyframes, Keyframe{tick, sim.snapshot_encode(simulation, tick)})
	}
}

// Starts moving the playhead to `target` without showing the ticks between: back inside the ring a restore, else the
// nearest keyframe at or before the target when it is behind the playhead or ahead of it, then the ticks to the target
// (replay_seek_run, a slice at a time). A newer seek replaces one on its way. On arrival the views snap (a new epoch),
// the events queued before it are dropped, and events arrive again for ticks the replay moves into going forward.
@(private)
replay_seek :: proc(driver: ^Driver($G, $View, $MultiView), target: u32) {
	replay := driver.replay
	if target == replay.simulation.tick && !replay.seeking do return
	replay.seeking, replay.seek_to = true, target
	keyframe := replay.keyframes[0]
	for candidate in replay.keyframes do if candidate.tick <= target do keyframe = candidate
	if target < replay.simulation.tick && sim.restore(replay.simulation, target) {
		replay.next_check = 0 // the cursor moves on again from the first
	} else if target < replay.simulation.tick || keyframe.tick > replay.simulation.tick {
		fresh: ^sim.Sim(G)
		if keyframe.bytes != nil {
			fresh, _ = sim.from_snapshot(driver.game, keyframe.bytes, any_build = true)
		} else {
			fresh = sim.create(driver.game, replay.log.seed, replay.log.setup)
		}
		if fresh == nil {
			replay.seeking = false // the playhead stays where it is
			return
		}
		dev := replay.simulation.dev
		enabled := dev != nil ? dev.enabled : 0
		sim.destroy(replay.simulation)
		replay.simulation = fresh
		replay.next_check = 0
		sim.dev_attach(fresh, replay_clock)
		sim.dev_enable(fresh, enabled)
	}
}

// Steps a seek on its way toward its target for at most `budget` (checking a stop between ticks); true once it
// arrived: the tracker starts over and the timeline has a new epoch (every view snaps). Nothing is shown meanwhile.
@(private)
replay_seek_run :: proc(driver: ^Driver($G, $View, $MultiView), budget: time.Duration) -> (arrived: bool) {
	replay := driver.replay
	if !replay.seeking do return true
	started := time.tick_now()
	for replay.simulation.tick < replay.seek_to {
		if time.tick_since(started) >= budget || sync.atomic_load(&driver.stop_req) do return false
		replay_forward(driver, publish = false)
	}
	replay.seeking = false
	// the tick tracker starts over: a tick entered again going forward has its events again
	serial := driver.tracker.last_serial
	tracker_destroy(&driver.tracker)
	tracker_init(&driver.tracker, tick_event_id, serial)
	driver.epoch += 1
	driver.poses.fill += 2 // no remembered pose crosses the jump
	return true
}

// Publishes the playhead's Frame (every tick final: verified = the tick).
@(private)
replay_publish :: proc(driver: ^Driver($G, $View, $MultiView), tick: u32) {
	replay := driver.replay
	simulation := replay.simulation
	current := sim.state_at(simulation, tick)
	if current == nil do current = &simulation.state
	local: sim.Player
	for holder in current.players.slots do if holder != {} && sim.player_key(holder) == replay.view.follow do local = holder
	publish_frame(
		driver,
		simulation,
		{tick = tick, verified = tick, resim_from = tick},
		replay.due_us,
		{0 = local},
		nil,
	)
}

// The Frame's view of the replay (publish_frame).
@(private)
replay_view :: proc(replay: ^Replay($G), out: ^Frame_Data) {
	out.replay = replay.view
	out.tick_us = i64(1_000_000 / f32(replay.simulation.game.tick_hz) / replay.view.speed)
}

// Main thread: a control for the running replay (false: no replay, or its queue is full).
@(private)
replay_control :: proc(control: Replay_Control) -> bool {
	return api.installed && api.replay_control != nil && api.replay_control(control)
}
