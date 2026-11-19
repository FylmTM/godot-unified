// unified:godot without Godot: the session driver (its thread, frames, previous poses, the input hand-off, events,
// statuses, lobbies) installed with the toy game. The Godot-facing classes run under headless
// Godot (the godot suite's `session` step, tests/godot, tests/godot_views).
package test_godot_driver

import "core:encoding/json"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "unified:godot"
import "unified:headless"
import "unified:netcode"
import "unified:sim"

import "../toy"

@(private = "file")
seen: struct {
	dx:        i8, // what the main thread samples (atomic: the test's main thread sets it)
	extracted: int, // frames filled (atomic)
	bumps:     u32, // the local player's bump commands applied, in the last frame (atomic)
	bump_fold: u32,
	pumps:     int,
	closes:    int,
	hub:       ^netcode.Hub,
	hold:      int, // atomic: 1 hold fill_frame at the local player's join tick, 2 held there, 3 let go
	held_tick: u32,
	build:     netcode.Lobby_Build, // what the lobby's open_host got
	spin:      int, // atomic: 1 fill_frame spins (a frozen session thread) until 2
}

@(private = "file")
View :: enum u8 {
	Dot,
}

@(private = "file")
MultiView :: enum u8 {
	Spark,
}

@(private = "file")
GLUE := godot.Glue(toy.Game, View, MultiView) {
	sample_input = proc(_: int, input: ^toy.Input) {input.dx = sync.atomic_load(&seen.dx)},
	fill_frame = proc(frame: ^godot.Frame(toy.Game, View, MultiView)) {
		players := sim.iterate_present(&frame.state.players)
		for data, player in sim.next(&players) {
			godot.push_view(frame, player, {kind = .Dot, pos = {data.pos.x, 0, data.pos.y}})
			godot.push_multi_view(frame, {
				key  = sim.player_key(player),
				kind = .Spark,
				pos  = {data.pos.x, 1, 0},
			})
		}
		if local := sim.player_data(&frame.state.players, frame.local_players[0]); local != nil {
			sync.atomic_store(&seen.bumps, local.bumps)
			sync.atomic_store(&seen.bump_fold, local.bump_fold)
			// the join tick's events are queued, its Frame not published yet: hold here while the test looks
			if sync.atomic_load(&seen.hold) == 1 {
				seen.held_tick = frame.tick
				sync.atomic_store(&seen.hold, 2)
				for sync.atomic_load(&seen.hold) != 3 do time.sleep(time.Millisecond)
			}
		}
		for sync.atomic_load(&seen.spin) == 1 do time.sleep(time.Millisecond)
		sync.atomic_add(&seen.extracted, 1)
	},
	view_scale = 10, // event positions stay in sim units across the hand-off: the main thread maps them
	view_policy = {.Dot = {appear = .Verified}}, // the driver also fills verified ticks (fill_verified)
}

@(private = "file")
FAILING := netcode.Lobby {
	name = "fake",
	open_host = proc(build: netcode.Lobby_Build) -> (netcode.Link, bool) {return {}, false},
	pump = proc() -> netcode.Lobby_Status {return {stage = .Failed, detail = "fake: no lobby service"}},
	close = proc() {seen.closes += 1},
}

@(private = "file")
OPENING := netcode.Lobby {
	name = "fake",
	open_host = proc(build: netcode.Lobby_Build) -> (netcode.Link, bool) {
		seen.build = build
		return netcode.loopback_link(seen.hub, 0), true
	},
	pump = proc() -> netcode.Lobby_Status {
		seen.pumps += 1
		return {stage = .Ready, code = "ABC123"}
	},
	close = proc() {seen.closes += 1},
}

// Pops messages until `pred` holds or `ms` pass; returns every message seen.
@(private = "file")
drain :: proc(out: ^[dynamic]godot.Message, ms: int, done: proc(message: godot.Message) -> bool) -> bool {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < f64(ms) {
		for {
			message, ok := godot.api.pop()
			if !ok do break
			append(out, message)
			if done(message) do return true
		}
		time.sleep(2 * time.Millisecond)
	}
	return false
}

@(private = "file")
text :: proc(message: godot.Message) -> string {
	message := message
	return strings.clone(string(message.text[:message.len]), context.temp_allocator)
}

@(private = "file")
is_result :: proc(message: godot.Message) -> bool {return message.kind == .Result}

// Takes every queued event whose tick is at most `shown`.
@(private = "file")
take_events :: proc(out: ^[dynamic]godot.Event_Message, shown: u32) {
	for {
		event := godot.api.next_event(shown) or_break
		append(out, event)
	}
}

// The recording of the session (driver.odin, what an F3 note carries): its snapshot and input log replay offline,
// agreeing with every checkpoint (this machine's checksum of each checksum tick) the log holds.
@(private = "file")
recording_replays :: proc(t: ^testing.T) {
	snapshot, log_bytes: [dynamic]u8
	defer delete(snapshot)
	defer delete(log_bytes)
	info, recorded := godot.api.recording(&snapshot, &log_bytes)
	if !testing.expect(t, recorded, "the session was recorded") do return
	testing.expectf(t, info.checkpoints > 0, "checkpoints to check: %v", info)
	input_log, log_ok := sim.log_decode(log_bytes[:], toy.Game)
	defer sim.log_destroy(&input_log)
	testing.expect(t, log_ok, "the input log decodes")
	testing.expect_value(t, len(input_log.ticks), int(info.to - info.from))
	testing.expect_value(t, input_log.from, info.from)
	testing.expect_value(t, len(input_log.checkpoints), info.checkpoints)
	result, ok := headless.run_replay(&toy.GAME, &input_log, snapshot = snapshot[:])
	testing.expectf(t, ok && result.checkpoints == info.checkpoints && result.diverged_tick == 0, "%v", result)
	testing.expect_value(t, result.final_tick, info.to)
	// kept as a session recording's folder for replay_plays
	_ = os.remove_all(REPLAY_DIR)
	_ = os.make_directory_all(REPLAY_DIR)
	_ = os.write_entire_file(REPLAY_DIR + "/snapshot.unis", snapshot[:])
	_ = os.write_entire_file(REPLAY_DIR + "/inputs.unil", log_bytes[:])
	recorded_range = {info.from, info.to}
}

@(private = "file")
REPLAY_DIR :: #directory + "/../../.out/test/replay"
@(private = "file")
recorded_range: [2]u32

// The newest Frame's tick and replay view (waits up to `ms` for `done`).
@(private = "file")
replay_wait :: proc(ms: int, done: proc(frame: ^godot.Frame_Data) -> bool) -> (frame: ^godot.Frame_Data, ok: bool) {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < f64(ms) {
		if front, _ := godot.api.front(); front != nil {
			frame = front
			if done(front) do return frame, true
		}
		time.sleep(2 * time.Millisecond)
	}
	return
}

// The replay session (replay.odin) on the recording recording_replays kept: it plays from the recording's first tick
// to its last, every tick final, the checkpoints agreeing; a step back inside the ring and a seek past it land on
// their ticks; the timeline's epoch moves with a jump; the session ends with a replay result.
@(private = "file")
replay_plays :: proc(t: ^testing.T) {
	ok, err := godot.api.start({mode = .Replay, arg = REPLAY_DIR, name = "viewer"})
	if !testing.expectf(t, ok, "replay start: %s", err) do return
	first, last := recorded_range[0], recorded_range[1]
	_, at_end := replay_wait(5000, proc(frame: ^godot.Frame_Data) -> bool {
		return frame.replay.active && frame.replay.paused && frame.tick == frame.replay.last
	})
	frame, _ := godot.api.front()
	if !testing.expect(t, at_end && frame != nil, "the replay plays to its last tick and pauses") do return
	testing.expect(t, frame.replay.first == first && frame.replay.last == last, "the recording's range")
	testing.expect_value(t, frame.verified, frame.tick) // every tick final
	testing.expectf(t, frame.replay.checkpoints > 0 && frame.replay.diverged == 0, "checkpoints: %v", frame.replay)
	epoch := frame.epoch
	testing.expect(t, godot.api.replay_control({kind = .Step, value = -2}))
	stepped, step_ok := replay_wait(
		2000,
		proc(frame: ^godot.Frame_Data) -> bool {return frame.tick == frame.replay.last - 2},
	)
	testing.expect(t, step_ok && stepped.epoch != epoch, "two ticks back, a new epoch")
	testing.expect(t, godot.api.replay_control({kind = .Seek, value = i64(first + 1)}))
	_, seek_ok := replay_wait(
		2000,
		proc(frame: ^godot.Frame_Data) -> bool {return frame.tick == frame.replay.first + 1},
	)
	testing.expect(t, seek_ok, "a seek back past the ring lands on its tick")
	godot.api.stop()
	messages: [dynamic]godot.Message
	defer delete(messages)
	testing.expect(t, drain(&messages, 3000, is_result), "a replay ends with a result")
	for godot.api.running() do time.sleep(time.Millisecond)
	testing.expectf(t, strings.contains(godot.api.result(), `"mode":"replay"`), "%s", godot.api.result())
	godot.api.wait()
}

@(test)
driver_sessions :: proc(t: ^testing.T) {
	godot.install(&toy.GAME, GLUE)
	testing.expect(t, godot.api.installed)
	testing.expect_value(t, len(godot.api.view_names), 1)
	if len(godot.api.view_names) == 1 do testing.expect_value(t, godot.api.view_names[0], "dot")
	testing.expect_value(t, godot.api.tick_hz, toy.HZ)

	// Single player, 24 ticks (a checksum at 16, inside the recording): connected, frames published with the previous
	// poses the host remembered, the main thread's input sample reaches the sim, commands sent from the main thread
	// reach the sim once each, in order, verified events confirmed, a result at the end.
	{
		testing.expect(t, !godot.api.send({}, 0), "no session: nothing to send to")
		sync.atomic_store(&seen.dx, 1)
		godot.api.sample_input()
		ok, err := godot.api.start({
			mode     = .Single,
			seed     = 7,
			ticks    = 24,
			name     = "solo",
			scripted = false,
		})
		testing.expect(t, ok, err)
		godot.api.sample_input() // the main thread's sample (the session took none yet: a start clears it)
		for amount in ([]i32{3, -1, 8}) {
			command := sim.command_make(toy.Cmd, toy.Cmd_Bump{amount})
			testing.expect(t, godot.api.send(command, 0))
		}
		messages := make([dynamic]godot.Message, context.temp_allocator)
		testing.expect(t, drain(&messages, 5000, is_result), "the session ends with a result")
		events := make([dynamic]godot.Event_Message, context.temp_allocator)
		take_events(&events, max(u32))
		connected, joined := false, false
		for message in messages do if message.kind == .Status && message.status == .Connected do connected = true
		for &message in events {
			switch event in sim.event_value(&message.event, toy.Event) {
			case sim.Event_Player_Joined:
				if message.action == .Confirmed do joined = event.slot == 0 && event.player.id == 1 && !event.returning
			case toy.Event_Spawned, sim.Event_Player_Left, toy.Event_Expired:
			}
		}
		testing.expect_value(t, godot.api.events_dropped(), 0)
		testing.expect(t, connected, "a Connected status")
		for message in messages {
			testing.expect(t, message.kind != .Status || message.status != .Left, "a session that ran out never left")
		}
		testing.expect(t, joined, "the local player's join is confirmed")
		frame, _ := godot.api.front()
		testing.expect(
			t,
			frame != nil && frame.n_views == 1 && frame.n_multis == 1 && frame.local_player != 0,
			"the last frame shows the player",
		)
		if frame != nil {
			// the local player by key: in slot 0, the only one present and remembered, its view's player
			testing.expect_value(t, frame.slots[0], frame.local_player)
			testing.expect(t, frame.n_members == 1 && frame.members[0] == frame.local_player)
			testing.expect(t, frame.n_views == 1 && frame.views[0].player == frame.local_player)
			entry, known := godot.roster_entry(i64(frame.local_player))
			testing.expect(t, known && netcode.text_string(&entry.name) == "solo", "the roster names the player")
		}
		testing.expect(t, frame != nil && frame.tick >= 23, "the last frame is at the end")
		testing.expect(t, sync.atomic_load(&seen.extracted) > 0)
		if frame != nil && frame.n_views == 1 && frame.n_multis == 1 {
			// the sampled dx moved the dot every tick; the host remembered where it was one tick earlier
			dot, spark := frame.views[0], frame.multis[0]
			testing.expectf(t, dot.has_prev && dot.pos.x > dot.prev_pos.x, "a view's previous pose: %v", dot)
			testing.expectf(
				t,
				spark.has_prev && spark.pos.x > spark.prev_pos.x,
				"an instance's previous pose: %v",
				spark,
			)
		}
		testing.expect_value(t, sync.atomic_load(&seen.bumps), 3)
		testing.expect_value(
			t,
			sync.atomic_load(&seen.bump_fold),
			toy.bump_fold(toy.bump_fold(toy.bump_fold(0, 3), -1), 8),
		)
		testing.expect(t, strings.contains(godot.api.result(), "\"checksum"), godot.api.result())
		// for the dev UI: the three commands, each confirmed in a verified tick; the session's recording (an F3
		// note's) replays offline to the session's own checksum
		confirmed := 0
		for {
			_ = godot.api.next_confirmed() or_break
			confirmed += 1
		}
		testing.expect_value(t, confirmed, 3)
		recording_replays(t)
		for godot.api.running() do time.sleep(time.Millisecond)
		godot.api.wait()
		testing.expect(t, !godot.api.running())
		replay_plays(t)
	}

	// A tick's events are queued before its Frame is published: the main thread, showing an older Frame, must not get
	// them yet (they are about views it doesn't show), and gets them once the Frame of their tick is shown.
	{
		sync.atomic_store(&seen.hold, 1)
		ok, err := godot.api.start({mode = .Single, seed = 7, ticks = 20, name = "solo"})
		testing.expect(t, ok, err)
		start := time.tick_now()
		for sync.atomic_load(&seen.hold) != 2 && time.duration_seconds(time.tick_since(start)) < 5 {
			time.sleep(time.Millisecond)
		}
		testing.expect_value(t, sync.atomic_load(&seen.hold), 2)
		held := seen.held_tick
		shown: u32
		if frame, _ := godot.api.front(); frame != nil do shown = frame.tick
		testing.expectf(t, shown < held, "the held tick %d is not shown yet (%d)", held, shown)
		early := make([dynamic]godot.Event_Message, context.temp_allocator)
		take_events(&early, shown)
		for event in early do testing.expectf(t, event.tick <= shown, "event of tick %d before its frame", event.tick)
		sync.atomic_store(&seen.hold, 3)
		for godot.api.running() do time.sleep(time.Millisecond)
		frame, _ := godot.api.front()
		testing.expect(t, frame != nil && frame.tick >= held)
		late := make([dynamic]godot.Event_Message, context.temp_allocator)
		if frame != nil do take_events(&late, frame.tick)
		// the join's tick is after the shown frame and at most the held one (a catch-up may step several ticks at once)
		is_join :: proc(event: ^godot.Event_Message) -> bool {
			_, join := sim.event_value(&event.event, toy.Event).(sim.Event_Player_Joined)
			return join
		}
		for &event in early do testing.expect(t, !is_join(&event), "no join before its frame is shown")
		joined := false
		for &event in late do joined ||= is_join(&event) && event.tick > shown && event.tick <= held
		testing.expect(t, joined, "the join tick's events come once its frame is shown")
		godot.api.wait()
		sync.atomic_store(&seen.hold, 0)
	}

	// Online without a lobby service: refused before a thread starts.
	{
		ok, err := godot.api.start({mode = .Host_Online})
		testing.expect(t, !ok && err != "", "online needs a lobby")
	}

	// A lobby that fails to open: its reason is the only Failed status (no generic one after it).
	{
		godot.lobby = &FAILING
		defer godot.lobby = nil
		ok, _ := godot.api.start({mode = .Host_Online})
		testing.expect(t, ok)
		for godot.api.running() do time.sleep(time.Millisecond)
		messages := make([dynamic]godot.Message, context.temp_allocator)
		drain(&messages, 50, proc(message: godot.Message) -> bool {return false})
		failed: [dynamic]string
		failed.allocator = context.temp_allocator
		for message in messages {
			if message.kind == .Status && message.status == .Failed do append(&failed, text(message))
		}
		testing.expect_value(t, len(failed), 1)
		if len(failed) == 1 do testing.expect_value(t, failed[0], "fake: no lobby service")
		godot.api.wait()
	}

	// A lobby that opens: it gets the game's name, the session's build id (what the relay checks) and player count,
	// the code reaches the main thread once, pump runs, stop ends the session (nobody to say goodbye to) and closes
	// the lobby once.
	{
		seen.hub = netcode.hub_create(2)
		defer netcode.hub_destroy(seen.hub)
		seen.closes, seen.pumps = 0, 0
		godot.lobby = &OPENING
		defer godot.lobby = nil
		ok, _ := godot.api.start({mode = .Host_Online, seed = 3})
		testing.expect(t, ok)
		messages := make([dynamic]godot.Message, context.temp_allocator)
		got_code := drain(&messages, 2000, proc(message: godot.Message) -> bool {
			return message.kind == .Join_Code && text(message) == "ABC123"
		})
		testing.expect(t, got_code, "the lobby code is posted")
		time.sleep(50 * time.Millisecond)
		godot.api.stop()
		testing.expect(t, godot.api.stopping())
		testing.expect(t, drain(&messages, 5000, is_result), "a stopped session ends with a result")
		for godot.api.running() do time.sleep(time.Millisecond)
		godot.api.wait()
		testing.expect(t, seen.pumps > 0, "the lobby is pumped")
		testing.expect_value(t, seen.build.game, toy.GAME.name)
		testing.expect_value(t, seen.build.compat, sim.compat_of(&toy.GAME))
		testing.expect_value(t, seen.build.players, toy.PLAYERS)
		testing.expect_value(t, seen.closes, 1)
		codes := 0
		for message in messages do codes += int(message.kind == .Join_Code)
		testing.expect_value(t, codes, 1)
		// stopped (UnifiedSession.leave): this player left, whatever the link said
		left, disconnected := false, false
		for message in messages {
			if message.kind != .Status do continue
			left ||= message.status == .Left
			disconnected ||= message.status == .Disconnected
		}
		testing.expect(t, left && !disconnected, "a stopped session's status is Left, never Disconnected")
	}

	// Hosting direct on loopback only (a tool run): the join code is the address a friend types, 127.0.0.1 and the
	// bound port.
	{
		ok, err := godot.api.start({mode = .Host_Direct, seed = 3, port = 0, local = true})
		testing.expect(t, ok, err)
		messages := make([dynamic]godot.Message, context.temp_allocator)
		testing.expect(t, drain(&messages, 2000, proc(message: godot.Message) -> bool {
				return message.kind == .Join_Code
			}), "a join code is posted")
		code := text(messages[len(messages) - 1]) if len(messages) > 0 else ""
		port, port_ok := strconv.parse_int(strings.trim_prefix(code, "127.0.0.1:"))
		testing.expectf(t, strings.has_prefix(code, "127.0.0.1:") && port_ok && port > 0, "join code %q", code)
		godot.api.stop()
		testing.expect(t, drain(&messages, 5000, is_result), "a stopped session ends with a result")
		for godot.api.running() do time.sleep(time.Millisecond)
		godot.api.wait()
	}

	// The watchdog: fill_frame spins, the step never ends; after watchdog_polls polls the watchdog writes the freeze's
	// folder (freeze.json says it froze in fill_frame; the recording plus the inputs after it replay into the frozen
	// tick) and fires.
	watchdog_freezes(t)

	// A game with problems never stops the load: install collects them all and installs nothing (the editor opens; a
	// session fails with the reason).
	{
		Bad_View :: enum u8 {
			Dot = 1,
		}
		bad := godot.Glue(toy.Game, Bad_View, MultiView){}
		godot.install(&toy.GAME, bad)
		testing.expect(t, !godot.api.installed)
		testing.expectf(t, len(godot.api.problems) == 2, "both problems: %v", godot.api.problems)
		// a view policy install refuses: a script-posed MultiMesh kind, a ramp without its time constant
		policies := GLUE
		policies.multi_policy = {
			.Spark = {pose = .Script},
		}
		policies.view_policy = {
			.Dot = {smoothing = {ramp_dist = 2}},
		}
		godot.install(&toy.GAME, policies)
		testing.expect(t, !godot.api.installed)
		testing.expectf(t, len(godot.api.problems) == 2, "both policy problems: %v", godot.api.problems)
	}
}

@(private = "file")
watchdog_freezes :: proc(t: ^testing.T) {
	dumps := #directory + "/../../.out/test/watchdog"
	_ = os.remove_all(dumps)
	_ = os.make_directory_all(dumps)
	polls, poll_ms, fire := godot.watchdog_polls, godot.watchdog_poll_ms, godot.watchdog_fire
	defer godot.watchdog_polls, godot.watchdog_poll_ms, godot.watchdog_fire = polls, poll_ms, fire
	godot.watchdog_polls, godot.watchdog_poll_ms = 3, 50
	godot.watchdog_fire = proc() {sync.atomic_store(&seen.spin, 2)} 	// let fill_frame go instead of aborting
	sync.atomic_store(&seen.spin, 0)
	extracted := sync.atomic_load(&seen.extracted)
	ok, err := godot.api.start({mode = .Single, seed = 5, name = "frozen", watchdog = true, dumps = dumps})
	testing.expectf(t, ok, "start: %s", err)
	for i := 0; i < 2000 && sync.atomic_load(&seen.extracted) < extracted + 40; i += 1 do time.sleep(time.Millisecond)
	sync.atomic_store(&seen.spin, 1)
	for i := 0; i < 5000 && sync.atomic_load(&seen.spin) != 2; i += 1 do time.sleep(time.Millisecond)
	testing.expect(t, sync.atomic_load(&seen.spin) == 2, "the watchdog fired")
	messages: [dynamic]godot.Message
	defer delete(messages)
	godot.api.stop()
	_ = drain(&messages, 5000, is_result)
	for godot.api.running() do time.sleep(time.Millisecond)
	godot.api.wait()
	entries, _ := os.read_all_directory_by_path(dumps, context.temp_allocator)
	if !testing.expectf(t, len(entries) == 1 && strings.has_prefix(entries[0].name, "freeze-"), "%v", entries) do return
	dir := entries[0].fullpath
	Freeze :: struct {
		tick:      u32,
		in_fill:   bool,
		recording: bool,
		from_tick: u32,
		to_tick:   u32,
	}
	freeze: Freeze
	text, _ := os.read_entire_file(
		strings.concatenate({dir, "/freeze.json"}, context.temp_allocator),
		context.temp_allocator,
	)
	testing.expect(t, json.unmarshal(text, &freeze) == nil, "freeze.json reads")
	testing.expectf(t, freeze.in_fill && freeze.recording && freeze.tick > 0, "%v", freeze)
	testing.expectf(t, freeze.to_tick == freeze.tick, "the inputs reach the frozen tick: %v", freeze)
	snapshot, _ := os.read_entire_file(
		strings.concatenate({dir, "/snapshot.unis"}, context.temp_allocator),
		context.temp_allocator,
	)
	log_bytes, _ := os.read_entire_file(
		strings.concatenate({dir, "/inputs.unil"}, context.temp_allocator),
		context.temp_allocator,
	)
	input_log, log_ok := sim.log_decode(log_bytes, toy.Game)
	defer sim.log_destroy(&input_log)
	simulation, snap_err := sim.from_snapshot(&toy.GAME, snapshot)
	if !testing.expect(t, log_ok && snap_err == .None, "the dump decodes") do return
	defer sim.destroy(simulation)
	for k in 0 ..< len(input_log.ticks) {
		inputs := sim.log_inputs(&input_log, k)
		sim.step(simulation, &inputs)
	}
	testing.expect_value(t, simulation.tick, freeze.tick)
}

// The watchdog's detector: the same odd step counter on `polls` polls in a row is a freeze; an even one (between
// steps) or one that moved is not, and a gap in polls (a suspended laptop: the watchdog's own clock stopped) changes
// nothing.
@(test)
watchdog_detects_a_stuck_step :: proc(t: ^testing.T) {
	detector: godot.Watchdog_Detector
	testing.expect(t, !godot.watchdog_poll(&detector, 7, 3))
	testing.expect(t, !godot.watchdog_poll(&detector, 7, 3))
	testing.expect(t, godot.watchdog_poll(&detector, 7, 3), "three polls in the same step")
	detector = {}
	for seq in ([]u64{2, 2, 2, 2}) do testing.expect(t, !godot.watchdog_poll(&detector, seq, 3), "between steps")
	for seq in ([]u64{3, 5, 7, 9}) do testing.expect(t, !godot.watchdog_poll(&detector, seq, 3), "steps moving on")
	testing.expect(t, !godot.watchdog_poll(&detector, 9, 3))
	testing.expect(t, godot.watchdog_poll(&detector, 9, 3), "then stuck")
}

// The host's pose memory (#284): tick - 1 as remembered, and its estimate after a rollback or skipped ticks.
@(test)
pose_memory_estimates_after_rollbacks :: proc(t: ^testing.T) {
	memory: godot.Pose_Memory
	godot.pose_memory_init(&memory, 4, 4)
	defer godot.pose_memory_destroy(&memory)
	remember :: proc(memory: ^godot.Pose_Memory, tick: u32, x: f32, rollback := false) -> (f32, bool) {
		godot.pose_memory_begin(memory, rollback)
		previous, found, _ := godot.pose_remember(memory, .View, 0, 7, tick, {x, 0, 0}, godot.IDENTITY)
		return previous.pos.x, found
	}
	_, found := remember(&memory, 10, 10)
	testing.expect(t, !found, "nothing before the first fill")
	x, _ := remember(&memory, 11, 11)
	testing.expect_value(t, x, 10) // the pose at tick - 1, as remembered
	x, _ = remember(&memory, 11, 13) // tick 11 again (a rollback moved it by 2): tick 10 moves with it
	testing.expect_value(t, x, 12)
	x, _ = remember(&memory, 12, 20, rollback = true) // a rollback with a new tick: 20 minus the last motion (1)
	testing.expect_value(t, x, 19)
	x, _ = remember(&memory, 15, 23) // ticks skipped: 23 minus the last motion (1)
	testing.expect_value(t, x, 22)
}

// A session that steps two ticks a time from an item's first fill on (a busy machine: driver_sessions failed so under
// a cold verify): the item still gets a previous pose, on the line from the last one, and keeps one.
@(test)
pose_memory_estimates_when_every_fill_skips :: proc(t: ^testing.T) {
	memory: godot.Pose_Memory
	godot.pose_memory_init(&memory, 4, 4)
	defer godot.pose_memory_destroy(&memory)
	remember :: proc(memory: ^godot.Pose_Memory, tick: u32, x: f32) -> (f32, bool) {
		godot.pose_memory_begin(memory)
		previous, found, _ := godot.pose_remember(memory, .View, 0, 7, tick, {x, 0, 0}, godot.IDENTITY)
		return previous.pos.x, found
	}
	_, found := remember(&memory, 4, 4)
	testing.expect(t, !found, "nothing before the first fill")
	x: f32
	x, found = remember(&memory, 6, 6) // ticks 5 skipped, no motion known: a tick short of 6 on the line from 4
	testing.expect(t, found && x == 5, "a tick - 1 estimate after the first skip")
	x, found = remember(&memory, 8, 8) // then the last motion (1) as before
	testing.expect(t, found && x == 7, "and after every skip that follows")
	x, found = remember(&memory, 11, 14) // three ticks on: 14 minus the last known motion (1)
	testing.expect(t, found && x == 13, "the last one-tick motion once it is known")
}

// Players' views (pushed with the player as their subject, keyed by their key): each finds its own tick - 1 pose, not
// the first pushed one's.
@(test)
player_views_remember_their_own_poses :: proc(t: ^testing.T) {
	memory: godot.Pose_Memory
	godot.pose_memory_init(&memory, 4, 4)
	defer godot.pose_memory_destroy(&memory)
	data := godot.Frame_Data {
		alloc = context.allocator,
	}
	defer {
		delete(data.views)
		delete(data.data)
	}
	frame := godot.Frame(toy.Game, View, MultiView) {
		out   = &data,
		poses = &memory,
	}
	first := sim.Player {
		index = 0,
		id    = 1,
	}
	second := sim.Player {
		index = 1,
		id    = 2,
	}
	for tick in u32(10) ..= 11 {
		godot.pose_memory_begin(&memory)
		data.n_views = 0
		data.n_data = 0
		frame.tick = tick
		godot.push_view(&frame, first, {kind = .Dot, pos = {f32(tick), 0, 0}})
		godot.push_view(&frame, second, {kind = .Dot, pos = {100 + f32(tick), 0, 0}})
	}
	for player, i in ([2]sim.Player{first, second}) {
		view := data.views[i]
		testing.expect_value(t, view.key, sim.player_key(player))
		testing.expect_value(t, view.player, sim.player_key(player)) // a player's view shows them
		testing.expect_value(t, view.subject, typeid_of(sim.Player))
		testing.expect(t, view.has_prev, "each player's view has its tick - 1 pose")
		testing.expect_value(t, view.prev_pos.x, f32(100 * i + 10)) // its own, not the first player's
	}
}

// An event's subject is found by type, whatever the field's name: its first handle or sim.Entity field. A u64 named
// `entity` is just a number.
@(test)
event_subjects_by_type :: proc(t: ^testing.T) {
	Event_Lit :: struct {
		lamp: sim.Entity,
		by:   sim.Player,
	}
	Event_Counted :: struct {
		entity: u64,
	}
	Event_Moved :: struct {
		thing: sim.Handle(toy.Thing),
		to:    sim.Entity,
	}
	Events :: union {
		Event_Lit,
		Event_Counted,
		Event_Moved,
	}
	layouts := godot.event_layouts(Events)
	by := sim.Player {
		index = 1,
		id    = 2,
	}
	lit := Event_Lit {
		lamp = sim.entity(3),
		by   = by,
	}
	player, subject := godot.event_subject(&layouts[0], ([^]u8)(&lit)[:size_of(lit)])
	testing.expect_value(t, player, sim.player_key(by))
	testing.expect_value(t, subject, u64(sim.entity(3)))
	testing.expect(t, !layouts[0].subject_is_handle)
	index, ok := sim.entity_index(sim.Entity(subject))
	testing.expect(t, ok && index == 3, "the lamp's view is the one keyed 3")
	testing.expect_value(t, layouts[1].subject, -1)
	testing.expect(t, layouts[2].subject_is_handle, "the first of a handle and an Entity is the subject")
	_, none := sim.entity_index({})
	testing.expect(t, !none, "the zero Entity is none")
}

// The pose memory grows past its starting room (a fill that pushes more than it was made for): every item, the ones
// remembered before the growth too, finds its tick - 1 pose on the next fill.
@(test)
pose_memory_grows :: proc(t: ^testing.T) {
	memory: godot.Pose_Memory
	godot.pose_memory_init(&memory, 4, 4)
	defer godot.pose_memory_destroy(&memory)
	COUNT :: 1000
	for tick in u32(1) ..= 2 {
		godot.pose_memory_begin(&memory)
		found_all := true
		for key in u64(1) ..= COUNT {
			previous, found, _ := godot.pose_remember(
				&memory,
				.Multi,
				0,
				key,
				tick,
				{f32(key), f32(tick), 0},
				godot.IDENTITY,
			)
			if tick == 2 do found_all &&= found && previous.pos == {f32(key), 1, 0}
		}
		if tick == 2 do testing.expect(t, found_all, "every key finds its tick - 1 pose after growing")
	}
}

// is_local: one of this client's local players at the frame's tick, whatever its local index; nobody and a remote
// player are not.
@(test)
is_local_names_this_clients_players :: proc(t: ^testing.T) {
	frame: godot.Frame(toy.Game, View, MultiView)
	couch := sim.Player {
		index = 3,
		id    = 7,
	}
	remote := sim.Player {
		index = 1,
		id    = 2,
	}
	frame.local_players[2] = couch // local 0 and 1 not in (yet)
	testing.expect(t, godot.is_local(&frame, couch))
	testing.expect(t, !godot.is_local(&frame, remote))
	testing.expect(t, !godot.is_local(&frame, {}))
}

// Glue.event_key names a view as push_view keys it: a player's by their key, a fixed thing's by its index (an
// Entity is index + 1), the one view of a kind by 0.
@(test)
to_view_keys_as_push_view_does :: proc(t: ^testing.T) {
	player := sim.Player {
		index = 1,
		id    = 4,
	}
	testing.expect_value(
		t,
		godot.to_view(View.Dot, player),
		godot.Event_Target(View){.Dot, sim.player_key(player), .View},
	)
	testing.expect_value(t, godot.to_view(View.Dot, sim.entity(5)), godot.Event_Target(View){.Dot, 5, .View})
	testing.expect_value(t, godot.to_view(View.Dot), godot.Event_Target(View){.Dot, 0, .View})
	testing.expect_value(t, godot.to_view(View.Dot, sim.Entity(0)).route, godot.Event_Route.Subject) // none: by subject
}
