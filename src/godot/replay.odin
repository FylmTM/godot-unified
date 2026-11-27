// The replay session (src/godot/README.md, Replays): UnifiedSession.replay(folder) plays an F3 note, a session
// recording or a freeze folder through the game's own views, HUD and dev UI, with pause, step, speed, seek and loop.
// It feeds the sim from the recording instead of the network: no input, no commands, every tick final (its events
// arrive Emitted and Confirmed together), the recording's checkpoints checked as it passes them. It shows the
// verified timeline: what a client predicted at the time is not in a recording.
package godot

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import gd "unified:gdext"
import "unified:netcode"
import "unified:sim"

// How far before a note's tick its replay starts (it plays up to the noted tick and pauses there).
@(private)
REPLAY_LEAD_S :: 10

// How long one replay_step may spend stepping toward a seek's target before it lets the loop come round (the
// watchdog sees a step end, a stop is honoured, a newer control read): a long seek is many short steps.
@(private)
REPLAY_SEEK_BUDGET :: 8 * time.Millisecond

// How much of the recording before its --replay-from a replay on the frame clock plays first (cut from the clip), so the
// game's cameras and the views' appearing have settled by the clip's first frame.
@(private)
REPLAY_CLIP_LEAD_S :: 1

// How much of the recording a clip cut around an event (--replay-at) shows before and after its tick, when
// --replay-before and --replay-after don't say.
REPLAY_AT_BEFORE_S :: 2
REPLAY_AT_AFTER_S :: 3

// The longest event name --replay-at takes (Replay_Event.name).
REPLAY_EVENT_NAME_MAX :: 64

// How often the session thread looks for the frame clock's next tick (replay_clock_ask): the main thread waits for it.
@(private)
REPLAY_CLOCK_POLL_US :: 250

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
	end:         u32, // where it stops (and a --quit-at-end run ends): `last`, or --replay-to's tick
	at:          u32, // a clip cut around an event (--replay-at): the tick whose step emitted it (0: none)
	fps:         u32, // the frame clock's frames per second (Replay_Clip.fps; 0: the real clock)
	clip_from:   u32, // on the frame clock: where the clip starts (the lead before it is cut: REPLAY_CLIP_LEAD_S)
	paused:      bool,
	speed:       f32,
	loop:        [2]u32, // a range it plays over and over ({0, 0}: none)
	follow:      u64, // the player whose views and camera it follows (local_player)
	checkpoints: int, // checkpoints compared so far
	agreed:      u32, // the last checkpoint that agreed (0: none yet)
	diverged:    u32, // the first that didn't (0: none): "recorded by another build" or a real divergence
	other_build: bool, // recorded by another build (replayed against its checkpoints)
}

// How a replay plays, as the --replay-* flags ask (Start.clip; zero: the whole recording at its own speed on the real
// clock, following whoever recorded it, a note stopping on its tick).
Replay_Clip :: struct {
	from, to: Replay_Point, // where it starts and where it stops (unset: the recording's first and last ticks)
	// Instead of from and to: the clip is cut around the tick whose step emitted this event (the n-th of its type in
	// the recording), `before` ahead of it and `after` past it (unset: REPLAY_AT_BEFORE_S, REPLAY_AT_AFTER_S), so a
	// recording made again keeps its clip on the same moment.
	at:       Replay_Event,
	before:   Replay_Point,
	after:    Replay_Point,
	speed:    f32, // its speed at the start (0: 1), within REPLAY_SPEED_MIN and REPLAY_SPEED_MAX
	player:   int, // follow the player in slot `player - 1` at `from` (0: whoever recorded it)
	// The frame clock (> 0): every frame of the main thread is 1/fps s of the recording however long it takes to draw,
	// and waits for the session thread to reach its tick, so frame n always shows the same moment (a movie written
	// with Godot's --fixed-fps; `uni render`). The views start moving on the first frame they are shown in.
	fps:      int,
}

// A moment of a recording as a flag names it: a tick (`300`), or seconds after its first tick (`4.5s`).
Replay_Point :: struct {
	set:     bool,
	seconds: bool,
	value:   f64,
}

// An event of the game's as --replay-at names it: `Event_Boss_Slam#2`, the second Event_Boss_Slam (its Odin type, its
// GDScript class EventBossSlam, or its name without the prefix, Boss_Slam; any case); `#n` left out: the first.
Replay_Event :: struct {
	set:      bool,
	n:        int, // which one: 1, the first
	name:     [REPLAY_EVENT_NAME_MAX]u8, // as written, without the #n
	name_len: int,
}

// The name a Replay_Event was written with (without its #n).
replay_event_name :: proc(event: ^Replay_Event) -> string {
	return string(event.name[:event.name_len])
}

// The kind (the variant index in the game's event union `Event`) the name `name` stands for: its type's name
// (Event_Boss_Slam, a library event's Event_Player_Joined), its GDScript class's (EventBossSlam) or the name without the
// prefix (Boss_Slam), in any case; -1 when no event type has it.
replay_event_kind :: proc(Event: typeid, name: string) -> int {
	// lower case without underscores or the Event prefix: what the three spellings share
	plain :: proc(name: string) -> string {
		lowered := strings.to_lower(name, context.temp_allocator)
		lowered, _ = strings.remove_all(lowered, "_", context.temp_allocator)
		return strings.trim_prefix(lowered, "event")
	}
	wanted := plain(name)
	for variant, kind in sim.union_variants(Event) {
		if plain(sim.variant_name(variant, sim.EVENT_PREFIX)) == wanted do return kind
	}
	return -1
}

// The ticks `point` (a length: ticks, or seconds) spans at `tick_hz`; `fallback_s` seconds when unset.
replay_point_ticks :: proc(point: Replay_Point, tick_hz: u32, fallback_s: f64) -> u32 {
	if !point.set do return u32(math.round(fallback_s * f64(tick_hz)))
	if point.seconds do return u32(math.round(point.value * f64(tick_hz)))
	return u32(point.value)
}

// The tick `point` names in a recording whose first tick is `first`, at `tick_hz` (`fallback` when unset).
replay_point_tick :: proc(point: Replay_Point, first: u32, tick_hz: u32, fallback: u32) -> u32 {
	if !point.set do return fallback
	if point.seconds do return first + u32(math.round(point.value * f64(tick_hz)))
	return u32(point.value)
}

// Reads the --replay-* flags in `args` into a Replay_Clip; a line in `problems` for each bad value.
@(private)
replay_clip_of :: proc(args: ^Args, problems: ^[dynamic]string) -> (clip: Replay_Clip) {
	point :: proc(problems: ^[dynamic]string, flag, text: string) -> (out: Replay_Point) {
		if text == "" do return
		trimmed := strings.trim_space(text)
		ok: bool
		if strings.has_suffix(trimmed, "s") {
			out.value, ok = strconv.parse_f64(trimmed[:len(trimmed) - 1])
			out.seconds = true
		} else {
			ticks: u64
			ticks, ok = strconv.parse_u64(trimmed, 10)
			ok = ok && ticks <= u64(max(u32))
			out.value = f64(ticks)
		}
		if !ok || !(out.value >= 0) || out.value > f64(max(u32)) {
			append(problems, fmt.tprintf("%s wants a tick or seconds (300, 4.5s), got %q", flag, text))
			return {}
		}
		out.set = true
		return
	}
	clip.from = point(problems, "--replay-from", args.replay_from)
	clip.to = point(problems, "--replay-to", args.replay_to)
	clip.before = point(problems, "--replay-before", args.replay_before)
	clip.after = point(problems, "--replay-after", args.replay_after)
	if args.replay_at != "" {
		name, _, which := strings.partition(strings.trim_space(args.replay_at), "#")
		n, n_ok := 1, true
		if which != "" do n, n_ok = strconv.parse_int(which, 10)
		if name == "" || len(name) > REPLAY_EVENT_NAME_MAX || !n_ok || n < 1 {
			append(
				problems,
				fmt.tprintf(
					"--replay-at wants an event's type and which one (Event_Boss_Slam, Event_Boss_Slam#2), got %q",
					args.replay_at,
				),
			)
		} else {
			clip.at = {
				set      = true,
				n        = n,
				name_len = len(name),
			}
			copy(clip.at.name[:], name)
		}
		if args.replay_from != "" || args.replay_to != "" {
			append(problems, "--replay-at cuts the clip around its event: no --replay-from or --replay-to with it")
		}
	} else if args.replay_before != "" || args.replay_after != "" {
		append(problems, "--replay-before and --replay-after are lengths around --replay-at's event: name one")
	}
	if clip.from.set && clip.to.set && clip.from.seconds == clip.to.seconds && clip.to.value <= clip.from.value {
		append(problems, fmt.tprintf("--replay-to %s is not after --replay-from %s", args.replay_to, args.replay_from))
	}
	if args.replay_speed != "" {
		speed, ok := strconv.parse_f32(strings.trim_space(args.replay_speed))
		if !ok || !(speed >= REPLAY_SPEED_MIN && speed <= REPLAY_SPEED_MAX) {
			append(
				problems,
				fmt.tprintf(
					"--replay-speed wants a speed from %v to %v, got %q",
					REPLAY_SPEED_MIN,
					REPLAY_SPEED_MAX,
					args.replay_speed,
				),
			)
		} else {
			clip.speed = speed
		}
	}
	clip.player = args.replay_player
	clip.fps = args.replay_fps
	return
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
	replay.view.end = replay.view.last
	clip := driver.req.clip
	followed := false // clip.player's holder was taken where the clip starts
	if clip.at.set || clip.from.set || clip.to.set || clip.fps > 0 {
		// a clip plays from where it asks to where it asks (a note's stop is not its own)
		first, last, hz := replay.view.first, replay.view.last, u32(driver.game.tick_hz)
		from, end: u32
		if clip.at.set {
			at, problem := replay_find_event(driver, &clip.at)
			if problem != "" do return fail(driver, problem)
			from = at - min(replay_point_ticks(clip.before, hz, REPLAY_AT_BEFORE_S), at - first)
			end = min(at + replay_point_ticks(clip.after, hz, REPLAY_AT_AFTER_S), last)
			replay.view.at = at
		} else {
			from = clamp(replay_point_tick(clip.from, first, hz, first), first, last)
			end = clamp(replay_point_tick(clip.to, first, hz, last), from, last)
		}
		replay.view.end = end
		replay.view.fps = u32(clip.fps)
		replay.view.clip_from = from
		start := from
		if clip.fps > 0 do start -= min(from - first, u32(REPLAY_CLIP_LEAD_S) * hz)
		if clip.player != 0 && start != from {
			// whose view: the slot's holder where the clip starts, not where its lead does
			replay_seek(driver, from)
			replay_seek_run(driver, max(time.Duration))
			replay_follow_slot(driver, clip.player) or_return
			followed = true
		}
		replay_seek(driver, start)
		replay_seek_run(driver, max(time.Duration)) // before the watchdog runs and anything is shown
	} else if about.tick > replay.view.first {
		// a note opens before its moment and stops on it; a note's tick past the recording (one noted ahead of the
		// verified ticks the recording holds) stops on its last
		lead := u32(REPLAY_LEAD_S * driver.game.tick_hz)
		replay.stop_at = min(about.tick, replay.view.last)
		if replay.stop_at > replay.view.first + lead do replay_seek(driver, replay.stop_at - lead)
		replay_seek_run(driver, max(time.Duration)) // before the watchdog runs and anything is shown
	}
	if clip.speed != 0 do replay.view.speed = clip.speed
	if clip.player != 0 && !followed do replay_follow_slot(driver, clip.player) or_return
	sync.atomic_store(&driver.clock_target, replay.simulation.tick)
	replay.due_us = netcode.now_us()
	post_status(driver, .Connected, other_build ? "recorded by another build: checked against its checkpoints" : "")
	replay_publish(driver, replay.simulation.tick)
	return true
}

// Follows the player in slot `player - 1` at the playhead's tick; false with a Failed status when nobody holds it.
@(private)
replay_follow_slot :: proc(driver: ^Driver($G, $View, $MultiView), player: int) -> bool {
	replay := driver.replay
	slots := replay.simulation.state.players.slots[:]
	holder := player <= len(slots) ? slots[player - 1] : {}
	if holder == {} {
		post_status(
			driver,
			.Failed,
			fmt.tprintf("replay: nobody holds slot %d at tick %d", player - 1, replay.simulation.tick),
		)
		return false
	}
	replay.view.follow = sim.player_key(holder)
	return true
}

// The tick whose step emitted the `event.n`-th event of `event`'s type, the playhead stepped forward from where it is
// (the recording's start) until it, keeping the keyframes it passes, so the seek to the clip's start that follows is
// short; why not, else "": no event type of that name, or the recording holds fewer of them.
@(private)
replay_find_event :: proc(driver: ^Driver($G, $View, $MultiView), event: ^Replay_Event) -> (at: u32, problem: string) {
	replay := driver.replay
	Event :: sim.part(G, sim.GAME_EVENT)
	name := replay_event_name(event)
	kind := replay_event_kind(Event, name)
	if kind < 0 {
		names := make([dynamic]string, context.temp_allocator)
		for variant in sim.union_variants(Event) do append(&names, fmt.tprint(variant.id))
		return 0, fmt.tprintf(
			"replay: the game has no event %s: its events are %s",
			name,
			strings.join(names[:], ", ", context.temp_allocator),
		)
	}
	seen := 0
	for replay.simulation.tick < replay.view.last {
		replay_forward(driver, publish = false)
		tick := replay.simulation.tick
		for raw in sim.events_at(replay.simulation, tick) {
			if int(raw.kind) != kind do continue
			seen += 1
			if seen == event.n do return tick, ""
		}
	}
	span := fmt.tprintf("ticks %d to %d", replay.view.first, replay.view.last)
	if seen == 0 do return 0, fmt.tprintf("replay: %s never occurs in the recording (%s)", name, span)
	return 0, fmt.tprintf(
		"replay: %s#%d is past the last: the recording holds %d of them (%s)",
		name,
		event.n,
		seen,
		span,
	)
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
			if playhead >= replay.view.end do replay_seek(driver, replay.view.first)
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
	if replay.view.fps > 0 {
		// the frame clock: the ticks the main thread's frame waits for (replay_clock_ask), as soon as it asks
		target := min(sync.atomic_load(&driver.clock_target), replay.view.end)
		for replay.simulation.tick < target {
			replay_forward(driver)
			stepped = true
		}
		replay.due_us = now - tick_us
		if stepped do replay_publish(driver, replay.simulation.tick)
		return now + REPLAY_CLOCK_POLL_US
	}
	for !replay.view.paused && now - replay.due_us >= tick_us {
		if loop := replay.view.loop; loop != {} && replay.simulation.tick >= loop[1] {
			replay_seek(driver, loop[0])
			if !replay_seek_run(driver, REPLAY_SEEK_BUDGET) do return now
		}
		if replay.simulation.tick >= replay.view.end ||
		   (replay.stop_at != 0 && replay.simulation.tick >= replay.stop_at) {
			replay.view.paused = true // the end (or the note's tick): it stays there until leave()
			replay.done = driver.req.quit && replay.simulation.tick >= replay.view.end
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

// Main thread: the frame clock's tick (Replay_Clip.fps): the session thread steps the replay up to it and publishes it.
@(private)
replay_clock_ask :: proc(target: u32) {
	if api.installed && api.replay_clock != nil do api.replay_clock(target)
}

// Main thread: a control for the running replay (false: no replay, or its queue is full).
@(private)
replay_control :: proc(control: Replay_Control) -> bool {
	return api.installed && api.replay_control != nil && api.replay_control(control)
}

// ---- the frame clock (main thread)

// How long a frame on the frame clock waits for the session thread to reach its tick before it shows what it has.
@(private)
FRAME_CLOCK_WAIT :: 30 * time.Second

// The marker of the line a clip on the frame clock prints once its last frame is on screen (`uni render` reads it).
FRAME_CLOCK_MARKER :: "UNIFIED_CLIP "

// A replay on the frame clock (Replay_Clip.fps), on the main thread: the frame on screen. Frame 0 is the first frame
// the views are shown in (a game's play scene may open some frames after the replay started): before it the replay
// holds its first tick. Frame n shows the recording `n / fps` seconds (at the clip's speed) after it. The clip starts
// at the first frame at or after its --replay-from (`clip_first`), after a lead that lets the game settle.
@(private)
Frame_Clock :: struct {
	started:     bool, // frame 0 was shown: the clock runs
	over:        bool, // the clip's last frame was shown: it stays on it
	frame:       int, // the frame on screen
	frames:      int, // how many it shows: from `from` to `end` at its speed, the lead included
	from, end:   u32, // the ticks it starts (the lead's first) and stops at
	clip_from:   u32, // the tick the clip starts at (Replay_View.clip_from)
	at:          u32, // the event's tick of a clip cut around one (Replay_View.at; 0: none)
	speed:       f32,
	movie_frame: int, // Engine.get_process_frames() as frame 0 was drawn: the movie writer's number of it
	clip_first:  int, // the clip's first frame: the frames before it are the lead (REPLAY_CLIP_LEAD_S), cut
	alpha:       f32, // where the frame on screen sits between its tick and the one before (handoff's alpha)
	waited:      int, // frames shown before frame 0 (FRAME_CLOCK_START_FRAMES)
}

// How many frames a clip on the frame clock waits for the game to show the replay's views (its play scene) before a
// --quit-at-end run gives up and quits with exit code 1.
@(private)
FRAME_CLOCK_START_FRAMES :: 600

// The tick the clip frame `frame` waits for (the first at or after its moment) and its alpha.
frame_clock_tick :: proc(from: u32, frame, fps: int, tick_hz: u32, speed: f32) -> (tick: u32, alpha: f32) {
	ticks := f64(frame) * f64(tick_hz) * f64(speed) / f64(fps) // after `from`
	whole := math.ceil(ticks - 1e-6) // a moment within a millionth of a tick is that tick
	return from + u32(whole), clamp(f32(1 - (whole - ticks)), 0, 1)
}

// How many frames a clip from `from` to `end` takes at `fps` and `speed` (at least 1: its first).
frame_clock_frames :: proc(from, end: u32, fps: int, tick_hz: u32, speed: f32) -> int {
	frames := math.ceil(f64(end - from) * f64(fps) / (f64(tick_hz) * f64(speed)) - 1e-6)
	return max(int(frames), 1)
}

// Frame 0 is on screen (the lead's first, or the clip's when it has none): the clock starts.
@(private)
frame_clock_start :: proc(session: ^Session_Node, frame: ^Frame_Data) {
	speed := frame.replay.speed != 0 ? frame.replay.speed : 1
	fps, start, clip_from := int(frame.replay.fps), frame.tick, max(frame.replay.clip_from, frame.tick)
	lead := clip_from > start ? frame_clock_frames(start, clip_from, fps, frame.tick_hz, speed) : 0
	session.clock = {
		started     = true,
		from        = start,
		end         = frame.replay.end,
		clip_from   = clip_from,
		at          = frame.replay.at,
		speed       = speed,
		frames      = max(frame_clock_frames(start, frame.replay.end, fps, frame.tick_hz, speed), lead + 1),
		clip_first  = lead,
		movie_frame = gd.Engine_get_process_frames(gd.Engine_singleton()),
		alpha       = 1,
	}
}

// The newest Frame once it holds the tick this frame of the clock shows: asks the session thread for it and waits (at
// most FRAME_CLOCK_WAIT). The clip's last frame shown, it prints its FRAME_CLOCK_MARKER line, and a --quit-at-end run
// quits.
@(private)
frame_clock_wait :: proc(session: ^Session_Node, newest: ^Frame_Data, newest_fresh: bool) -> (^Frame_Data, bool) {
	frame, fresh := newest, newest_fresh
	clock := &session.clock
	fps := int(frame.replay.fps)
	target := frame.tick // before frame 0: whatever the replay holds (its first tick)
	if !clock.started {
		clock.waited += 1
		if clock.waited == FRAME_CLOCK_START_FRAMES && session.quit_at_end {
			gd.print_error(
				fmt.tprintf(
					"unified: the replay's views were not shown in %d frames: no clip",
					FRAME_CLOCK_START_FRAMES,
				),
			)
			quit_when_quiet(session, 1)
		}
	} else {
		if !clock.over {
			clock.frame += 1
			if clock.frame >= clock.frames {
				clock.over = true
				clock.frame = clock.frames - 1
				frame_clock_end(session, fps, frame.tick_hz)
			}
		}
		target, clock.alpha = frame_clock_tick(clock.from, clock.frame, fps, frame.tick_hz, clock.speed)
		target = min(target, clock.end)
	}
	replay_clock_ask(target)
	started := time.tick_now()
	for frame.tick < target && api.running() {
		if time.tick_since(started) > FRAME_CLOCK_WAIT {
			gd.print_error(
				fmt.tprintf("unified: the replay did not reach tick %d in time (at %d)", target, frame.tick),
			)
			break
		}
		time.sleep(100 * time.Microsecond)
		if later, later_fresh := api.front(); later != nil {
			frame = later
			fresh = fresh || later_fresh
		}
	}
	return frame, fresh
}

// The clip's last frame was shown: its line (which movie frames are the clip, its lead left out), and the quit of a
// --quit-at-end run.
@(private)
frame_clock_end :: proc(session: ^Session_Node, fps: int, tick_hz: u32) {
	clock := &session.clock
	fmt.printfln(
		`%s{{"movie_frame":%d,"frames":%d,"from":%d,"to":%d,"at":%d,"fps":%d,"tick_hz":%d,"speed":%v}}`,
		FRAME_CLOCK_MARKER,
		clock.movie_frame + clock.clip_first,
		clock.frames - clock.clip_first,
		clock.clip_from,
		clock.end,
		clock.at,
		fps,
		tick_hz,
		clock.speed,
	)
	if session.quit_at_end do quit_when_quiet(session, 0)
}
