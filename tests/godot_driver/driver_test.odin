// unified:godot without Godot: the session driver (its thread, frames, previous poses, the input hand-off, events,
// statuses, lobbies) installed with the toy game. The Godot-facing classes run under headless
// Godot (the godot suite's `session` step, tests/godot, tests/godot_views).
package test_godot_driver

import "core:encoding/json"
import "core:fmt"
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
	dx:           i8, // what the main thread samples (atomic: the test's main thread sets it)
	extracted:    int, // frames filled (atomic)
	bumps:        u32, // the local player's bump commands applied, in the last frame (atomic)
	bump_fold:    u32,
	pumps:        int,
	closes:       int,
	hub:          ^netcode.Hub,
	hold:         int, // atomic: 1 hold fill_frame at the local player's join tick, 2 held there, 3 let go
	held_tick:    u32,
	build:        netcode.Lobby_Build, // what the lobby's open_host got
	spin:         int, // atomic: 1 fill_frame spins (a frozen session thread) until 2
	setup:        u32, // atomic: the last Frame's Setup's life_bonus + 1 (0: no Setup)
	color:        u32, // atomic: the local player's colour (their Profile's)
	second_color: u32, // atomic: the colour of whoever holds slot 1
	local_dx:     i32, // atomic: the last Frame's local_inputs[0].dx + 100 when local player 0 plays (0: never)
	nobody_dx:    i32, // atomic: the last Frame's local_inputs[1].dx (nobody plays local index 1)
	second_bumps: u32, // atomic: the bumps of local player 1's player, in the last Frame
	scribble:     bool, // atomic: fill_frame writes the Setup it reads (a fill must never write)
}

@(private = "file")
View :: union {
	View_Dot,
}

@(private = "file")
View_Dot :: struct {}

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
			godot.push_view(frame, player, {pos = {data.pos.x, 0, data.pos.y}}, View_Dot{})
			godot.push_multi_view(frame, {
				key  = sim.player_key(player),
				kind = .Spark,
				pos  = {data.pos.x, 1, 0},
			})
		}
		if local := sim.player_data(&frame.state.players, frame.local_players[0]); local != nil {
			sync.atomic_store(&seen.local_dx, i32(frame.local_inputs[0].dx) + 100)
			sync.atomic_store(&seen.nobody_dx, i32(frame.local_inputs[1].dx))
			sync.atomic_store(&seen.bumps, local.bumps)
			sync.atomic_store(&seen.bump_fold, local.bump_fold)
			sync.atomic_store(&seen.color, local.color)
			if second := sim.slot_data(&frame.state.players, 1); second != nil do sync.atomic_store(&seen.second_color, second.color)
			if second := sim.player_data(&frame.state.players, frame.local_players[1]); second != nil {
				sync.atomic_store(&seen.second_bumps, second.bumps)
			}
			// the join tick's events are queued, its Frame not published yet: hold here while the test looks
			if sync.atomic_load(&seen.hold) == 1 {
				seen.held_tick = frame.tick
				sync.atomic_store(&seen.hold, 2)
				for sync.atomic_load(&seen.hold) != 3 do time.sleep(time.Millisecond)
			}
		}
		for sync.atomic_load(&seen.spin) == 1 do time.sleep(time.Millisecond)
		if sync.atomic_load(&seen.scribble) do frame.setup.life_bonus += 1
		if frame.setup != nil do sync.atomic_store(&seen.setup, u32(frame.setup.life_bonus) + 1)
		sync.atomic_add(&seen.extracted, 1)
	},
	view_scale = 10, // event positions stay in sim units across the hand-off: the main thread maps them
	// the driver also fills verified ticks (fill_verified) and samples them (verified_players.odin)
	view_policy = {{View_Dot, {appear = .Verified, remote = .Verified}}},
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

// Pops messages until `done` holds or `ms` pass; returns every message seen. The time is checked after a pop, never
// between a sleep and the next one: a test thread descheduled past the deadline (a loaded CI runner, the session
// thread at a higher priority) still sees the message that came meanwhile.
@(private = "file")
drain :: proc(out: ^[dynamic]godot.Message, ms: int, done: proc(message: godot.Message) -> bool) -> bool {
	start := time.tick_now()
	for {
		for {
			message, ok := godot.api.pop()
			if !ok do break
			append(out, message)
			if done(message) do return true
		}
		if time.duration_milliseconds(time.tick_since(start)) >= f64(ms) do return false
		time.sleep(2 * time.Millisecond)
	}
}

@(private = "file")
text :: proc(message: godot.Message) -> string {
	message := message
	return strings.clone(string(message.text[:message.len]), context.temp_allocator)
}

@(private = "file")
is_result :: proc(message: godot.Message) -> bool {return message.kind == .Result}

// Takes every queued event of the timeline `epoch` whose tick is at most `shown`.
@(private = "file")
take_events :: proc(out: ^[dynamic]godot.Event_Message, shown: u32, epoch: u32 = 0) {
	for {
		event := godot.api.next_event(shown, epoch) or_break
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
	// The session thread stamps every input it samples with its Seen (netcode.client_seen) once its sim exists.
	stamped := 0
	for &logged in input_log.ticks {
		if logged.input[0].seen != 0 do stamped += 1
		testing.expect(t, logged.input[0].seen != 0 || stamped == 0, "a Seen once stamped stays stamped")
	}
	testing.expectf(t, stamped > 0, "%v of %v inputs carry a Seen", stamped, len(input_log.ticks))
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

// How long a wait for the session thread gives up after (each returns as soon as it sees what it waits for): a CI
// runner busy with the other test binaries can take seconds for what takes milliseconds here.
@(private = "file")
WAIT_MS :: 30_000
@(private = "file")
WAIT_S :: WAIT_MS / 1000
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
	defer if godot.api.running() { 	// a failed check below leaves no session for the next one to trip over
		godot.api.stop()
		godot.api.wait()
	}
	testing.expect(t, godot.api.sampler() == nil, "a replay plays nothing late: every tick it shows is final")
	first, last := recorded_range[0], recorded_range[1]
	_, at_end := replay_wait(WAIT_MS, proc(frame: ^godot.Frame_Data) -> bool {
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
		WAIT_MS,
		proc(frame: ^godot.Frame_Data) -> bool {return frame.tick == frame.replay.last - 2},
	)
	testing.expect(t, step_ok && stepped.epoch != epoch, "two ticks back, a new epoch")
	testing.expect(t, godot.api.replay_control({kind = .Seek, value = i64(first + 1)}))
	_, seek_ok := replay_wait(
		WAIT_MS,
		proc(frame: ^godot.Frame_Data) -> bool {return frame.tick == frame.replay.first + 1},
	)
	testing.expect(t, seek_ok, "a seek back past the ring lands on its tick")
	godot.api.stop()
	messages: [dynamic]godot.Message
	defer delete(messages)
	testing.expect(t, drain(&messages, WAIT_MS, is_result), "a replay ends with a result")
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
		testing.expect(t, godot.api.sampler() != nil, "a .Verified kind: the session samples the verified timeline")
		godot.api.sample_input() // the main thread's sample (the session took none yet: a start clears it)
		for amount in ([]i32{3, -1, 8}) {
			command := sim.command_make(toy.Command, toy.Command_Bump{amount})
			testing.expect(t, godot.api.send(command, 0))
		}
		messages := make([dynamic]godot.Message, context.temp_allocator)
		testing.expect(t, drain(&messages, WAIT_MS, is_result), "the session ends with a result")
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
		// fill_frame saw the main thread's newest sample (dx 1) as local player 0's, and nothing for a local index
		// nobody plays
		testing.expect_value(t, sync.atomic_load(&seen.local_dx), 101)
		testing.expect_value(t, sync.atomic_load(&seen.nobody_dx), 0)
		if frame != nil && frame.n_views == 1 && frame.n_multis == 1 {
			// the sampled dx moved the dot every tick; the host remembered where it was one tick earlier
			dot, spark := frame.views[0], frame.multis[0]
			testing.expectf(t, dot.has_prev && dot.pos.x > dot.prev_pos.x, "a view's previous pose: %v", dot)
			testing.expectf(
				t,
				spark.has_prev && spark.pos.x > frame.multi_prev[0].pos.x,
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

	replay_events_after_a_seek(t)
	replay_cuts_around_an_event(t)
	sessions_start_paused(t)
	local_commands_stay_their_players(t)
	fill_frame_writing_is_reported(t)

	// A tick's events are queued before its Frame is published: the main thread, showing an older Frame, must not get
	// them yet (they are about views it doesn't show), and gets them once the Frame of their tick is shown.
	{
		sync.atomic_store(&seen.hold, 1)
		sync.atomic_store(&seen.setup, 0)
		bonus := toy.Setup {
			life_bonus = 5,
		}
		setup: [sim.SETUP_MAX]u8
		copy(setup[:], sim.bytes_of(&bonus))
		ok, err := godot.api.start(
			{mode = .Single, seed = 7, ticks = 20, name = "solo", setup = setup, has_setup = true},
		)
		testing.expect(t, ok, err)
		start := time.tick_now()
		for sync.atomic_load(&seen.hold) != 2 && time.duration_seconds(time.tick_since(start)) < WAIT_S {
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
		testing.expect_value(t, sync.atomic_load(&seen.setup), 6) // fill_frame reads the session's Setup
		godot.api.wait()
		sync.atomic_store(&seen.hold, 0)
	}

	// A scripted session's local player joins with the game's scripted Profile for slot 0 (the offline run's), not
	// Unified.profile's.
	{
		sync.atomic_store(&seen.color, 0)
		ok, err := godot.api.start({mode = .Single, seed = 7, ticks = 8, name = "solo", scripted = true})
		testing.expect(t, ok, err)
		messages := make([dynamic]godot.Message, context.temp_allocator)
		testing.expect(t, drain(&messages, WAIT_MS, is_result), "the scripted session ends with a result")
		for godot.api.running() do time.sleep(time.Millisecond)
		godot.api.wait()
		testing.expect_value(t, sync.atomic_load(&seen.color), u32(toy.scripted_profile(7, 0).color))
	}

	// A scripted host's local player k holds slot k with slot k's scripted Profile: local 1 here. (A taken slot is
	// refused, Slot_Taken: tests/netcode, a_refused_local_player_taken_back_keeps_the_connection.)
	{
		sync.atomic_store(&seen.second_color, 0)
		ok, err := godot.api.start({mode = .Single, seed = 7, ticks = 48, name = "solo", scripted = true})
		testing.expect(t, ok, err)
		for frame, _ := godot.api.front(); frame == nil || frame.tick < 4; frame, _ = godot.api.front() {
			time.sleep(time.Millisecond)
		}
		testing.expect(t, godot.api.local_player(1, true, "Second", nil))
		messages := make([dynamic]godot.Message, context.temp_allocator)
		testing.expect(t, drain(&messages, WAIT_MS, is_result), "the session ends with a result")
		for godot.api.running() do time.sleep(time.Millisecond)
		godot.api.wait()
		testing.expect_value(t, sync.atomic_load(&seen.second_color), u32(toy.scripted_profile(7, 1).color))
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
		got_code := drain(&messages, WAIT_MS, proc(message: godot.Message) -> bool {
			return message.kind == .Join_Code && text(message) == "ABC123"
		})
		testing.expect(t, got_code, "the lobby code is posted")
		time.sleep(50 * time.Millisecond)
		godot.api.stop()
		testing.expect(t, drain(&messages, WAIT_MS, is_result), "a stopped session ends with a result")
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
		testing.expect(t, drain(&messages, WAIT_MS, proc(message: godot.Message) -> bool {
				return message.kind == .Join_Code
			}), "a join code is posted")
		code := text(messages[len(messages) - 1]) if len(messages) > 0 else ""
		port, port_ok := strconv.parse_int(strings.trim_prefix(code, "127.0.0.1:"))
		testing.expectf(t, strings.has_prefix(code, "127.0.0.1:") && port_ok && port > 0, "join code %q", code)
		godot.api.stop()
		testing.expect(t, drain(&messages, WAIT_MS, is_result), "a stopped session ends with a result")
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
		// no fill_frame, no sample_input, a View that is no union
		testing.expectf(t, len(godot.api.problems) == 3, "all three problems: %v", godot.api.problems)
		// a game with an Input whose Glue has no sample_input
		missing := GLUE
		missing.sample_input = nil
		godot.install(&toy.GAME, missing)
		testing.expect(t, !godot.api.installed)
		testing.expectf(t, len(godot.api.problems) == 1, "no sample_input: %v", godot.api.problems)
		// a view policy install refuses: a script-posed MultiMesh kind on the verified timeline, a ramp without its time
		// constant, age channels on a scene view kind (they are MultiMesh custom data)
		policies := GLUE
		policies.multi_policy = {
			.Spark = {pose = .Script, remote = .Verified},
		}
		policies.view_policy = {{View_Dot, {smoothing = {ramp_dist = 2}, ages = {0}}}}
		godot.install(&toy.GAME, policies)
		testing.expect(t, !godot.api.installed)
		testing.expectf(t, len(godot.api.problems) == 4, "the four policy problems: %v", godot.api.problems)
		// a policy for a type that is no View kind, and one kind twice
		kinds := GLUE
		kinds.view_policy = {{Stats, {}}, {View_Dot, {}}, {View_Dot, {}}}
		godot.install(&toy.GAME, kinds)
		testing.expect(t, !godot.api.installed)
		testing.expectf(t, len(godot.api.problems) == 2, "not a kind, a kind twice: %v", godot.api.problems)
	}

	// A game without an Input (sim.No_Input): its Glue has no sample_input, the main thread's sample does nothing,
	// and the commands sent from the main thread drive it. A sample_input for it is a problem.
	{
		godot.install(&toy.STILL, STILL_GLUE)
		testing.expectf(t, godot.api.installed, "a Glue without sample_input installs: %v", godot.api.problems)
		sync.atomic_store(&seen.bumps, 0)
		ok, err := godot.api.start({mode = .Single, seed = 7, ticks = 24, name = "solo"})
		testing.expect(t, ok, err)
		godot.api.sample_input()
		for amount in ([]i32{3, -1}) {
			testing.expect(t, godot.api.send(sim.command_make(toy.Command, toy.Command_Bump{amount}), 0))
		}
		messages := make([dynamic]godot.Message, context.temp_allocator)
		testing.expect(t, drain(&messages, WAIT_MS, is_result), "the session ends with a result")
		for godot.api.running() do time.sleep(time.Millisecond)
		godot.api.wait()
		testing.expect_value(t, sync.atomic_load(&seen.bumps), 2)
		sampling := STILL_GLUE
		sampling.sample_input = proc(_: int, _: ^sim.No_Input) {}
		godot.install(&toy.STILL, sampling)
		testing.expectf(t, len(godot.api.problems) == 1, "a sample_input without an Input: %v", godot.api.problems)
	}

	// A game with no scene views (`View :: union {}`: its screen drawn from session data alone): it installs with no
	// view kind, and its sessions run, filling and publishing frames.
	{
		No_View :: union {}
		empty := godot.Glue(toy.Game, No_View, MultiView) {
			sample_input = GLUE.sample_input,
			fill_frame = proc(_: ^godot.Frame(toy.Game, No_View, MultiView)) {sync.atomic_add(&seen.extracted, 1)},
		}
		problems := godot.install_problems(&toy.GAME, empty)
		testing.expectf(t, len(problems) == 0, "an empty View union is no install problem: %v", problems)
		godot.install(&toy.GAME, empty)
		testing.expectf(t, godot.api.installed, "an empty View union installs: %v", godot.api.problems)
		testing.expect_value(t, len(godot.api.view_names), 0)
		filled := sync.atomic_load(&seen.extracted)
		ok, err := godot.api.start({mode = .Single, seed = 7, ticks = 24, name = "solo"})
		testing.expect(t, ok, err)
		godot.api.sample_input()
		messages := make([dynamic]godot.Message, context.temp_allocator)
		testing.expect(t, drain(&messages, WAIT_MS, is_result), "the session ends with a result")
		for godot.api.running() do time.sleep(time.Millisecond)
		godot.api.wait()
		testing.expect(t, sync.atomic_load(&seen.extracted) > filled, "its frames were filled")
	}
}

// The Glue of the toy without an Input: no sample_input; fill_frame keeps the local player's bump count.
@(private = "file")
STILL_GLUE := godot.Glue(toy.Still_Game, View, MultiView) {
	fill_frame = proc(frame: ^godot.Frame(toy.Still_Game, View, MultiView)) {
		if local := sim.player_data(&frame.state.players, frame.local_players[0]); local != nil {
			sync.atomic_store(&seen.bumps, local.bumps)
		}
	},
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
	_ = drain(&messages, WAIT_MS, is_result)
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

// A replay's events across a seek (a scripted session's recording, which spawns things): the events queued before the
// seek, never shown, are dropped once the seek's Frame is on screen; playing on from there, each event of the ticks the
// replay moves into arrives once in each state, in tick order, on the new timeline only.
@(private = "file")
replay_events_after_a_seek :: proc(t: ^testing.T) {
	ok, err := godot.api.start({mode = .Single, seed = 11, ticks = 96, name = "recorder", scripted = true})
	if !testing.expectf(t, ok, "start: %s", err) do return
	messages := make([dynamic]godot.Message, context.temp_allocator)
	testing.expect(t, drain(&messages, WAIT_MS, is_result), "the recorded session ends")
	snapshot, log_bytes: [dynamic]u8
	defer delete(snapshot)
	defer delete(log_bytes)
	info, recorded := godot.api.recording(&snapshot, &log_bytes)
	for godot.api.running() do time.sleep(time.Millisecond)
	godot.api.wait()
	if !testing.expect(t, recorded && info.to > info.from + 40, "a recording to replay") do return
	dir :: #directory + "/../../.out/test/replay_events"
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	_ = os.write_entire_file(dir + "/snapshot.unis", snapshot[:])
	_ = os.write_entire_file(dir + "/inputs.unil", log_bytes[:])

	ok, err = godot.api.start({mode = .Replay, arg = dir, name = "viewer"})
	if !testing.expectf(t, ok, "replay start: %s", err) do return
	defer godot.api.wait()
	testing.expect(t, godot.api.replay_control({kind = .Speed, speed = 4}))
	_, at_end := replay_wait(WAIT_MS, proc(frame: ^godot.Frame_Data) -> bool {
		return frame.replay.paused && frame.tick == frame.replay.last
	})
	if !testing.expect(t, at_end, "the replay plays to its end (its events queued, none taken)") do return
	first := info.from
	testing.expect(t, godot.api.replay_control({kind = .Seek, value = i64(first + 1)}))
	seek_frame, seek_ok := replay_wait(WAIT_MS, proc(frame: ^godot.Frame_Data) -> bool {
		return frame.tick == frame.replay.first + 1
	})
	if !testing.expect(t, seek_ok, "the seek lands") do return
	epoch := seek_frame.epoch
	stale := make([dynamic]godot.Event_Message, context.temp_allocator)
	take_events(&stale, seek_frame.tick, epoch)
	testing.expectf(t, len(stale) == 0, "nothing from before the seek: %d events", len(stale))
	testing.expect(t, godot.api.replay_control({kind = .Play}))
	events := make([dynamic]godot.Event_Message, context.temp_allocator)
	start := time.tick_now()
	for time.duration_seconds(time.tick_since(start)) < WAIT_S {
		frame, _ := godot.api.front()
		if frame == nil do continue
		take_events(&events, frame.tick, frame.epoch)
		if frame.replay.paused && frame.tick == frame.replay.last do break
		time.sleep(time.Millisecond)
	}
	testing.expectf(t, len(events) >= 2, "the ticks played again have events: %d", len(events))
	Seen_Event :: struct {
		id:     u64,
		action: godot.Event_Action,
	}
	once := make(map[Seen_Event]bool, context.temp_allocator)
	last_tick := first + 1
	for event in events {
		testing.expect_value(t, event.epoch, epoch)
		testing.expectf(t, event.tick > first + 1 && event.tick >= last_tick, "tick %d in order", event.tick)
		last_tick = event.tick
		key := Seen_Event{event.id, event.action}
		testing.expectf(t, !once[key], "event %d %v arrives once", event.id, event.action)
		once[key] = true
	}
	for event in events do testing.expectf(t, once[{event.id, .Emitted}] && once[{event.id, .Confirmed}], "%d both states", event.id)
	godot.api.stop()
	_ = drain(&messages, WAIT_MS, is_result)
}

// --replay-at (replay.odin, replay_find_event) on a recording of a scripted offline run: the clip is cut around the tick
// whose step emitted the n-th event of the type, as an offline replay of the recording finds it (an n of 2 or more whose
// event's tick no neighbour of its type shares, so an n off by one lands elsewhere); a type the game has not, one the
// recording never emits and an n past the last are refused, saying so. The recording (two players) says not who
// recorded it: the replay follows P1, the host; --replay-player 2 follows slot 1's holder.
@(private = "file")
replay_cuts_around_an_event :: proc(t: ^testing.T) {
	input_log: sim.Input_Log(toy.Game)
	headless.run_sim(&toy.GAME, 400, 13, 2, input_log = &input_log)
	dir :: #directory + "/../../.out/test/replay_at"
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	_ = os.write_entire_file(dir + "/inputs.unil", sim.log_encode(&input_log, context.temp_allocator))
	messages := make([dynamic]godot.Message, context.temp_allocator)
	defer sim.log_destroy(&input_log)
	emitted: [dynamic]headless.Event_At
	defer delete(emitted)
	_, replayed := headless.run_replay(&toy.GAME, &input_log, events = &emitted)
	testing.expect(t, replayed, "the recording replays offline")
	LEFT :: 1 // sim.Event_Player_Left's kind
	// an event to cut around: the n-th of its kind (n from 2), whose tick neither neighbour of its kind shares
	kind, n, at, kind_count, left := -1, 0, u32(0), 0, 0
	for event in emitted do if event.kind == LEFT do left += 1
	pick: for event, i in emitted {
		which, shared := 1, false
		for other in emitted[:i] {
			if other.kind != event.kind do continue
			which += 1
			shared = other.tick == event.tick
		}
		for other in emitted[i + 1:] {
			if other.kind != event.kind do continue
			shared ||= other.tick == event.tick
			break
		}
		if shared || which < 2 do continue
		kind, n, at = int(event.kind), which, event.tick
		for other in emitted do if int(other.kind) == kind do kind_count += 1
		break pick
	}
	if !testing.expectf(t, kind >= 0, "an event to cut around, with neighbours on other ticks: %v", emitted) do return
	name := fmt.tprint(sim.union_variants(toy.Event)[kind].id)
	first, last := input_log.from, input_log.from + u32(len(input_log.ticks))

	replay_at :: proc(anchor: string, before := "", after := "") -> godot.Replay_Clip {
		flags := make([dynamic]string, context.temp_allocator)
		append(&flags, "--replay-at", anchor)
		if before != "" do append(&flags, "--replay-before", before)
		if after != "" do append(&flags, "--replay-after", after)
		args, _, _ := godot.parse_command_line(flags[:], true)
		delete(args.replay_at)
		delete(args.replay_before)
		delete(args.replay_after)
		return args.clip
	}
	ok, err := godot.api.start(
		{mode = .Replay, arg = dir, name = "viewer", clip = replay_at(fmt.tprintf("%s#%d", name, n), "3", "5")},
	)
	if !testing.expectf(t, ok, "replay start: %s", err) do return
	frame, shown := replay_wait(WAIT_MS, proc(frame: ^godot.Frame_Data) -> bool {return frame.replay.at != 0})
	if testing.expect(t, shown, "the clip is shown") {
		testing.expectf(
			t,
			frame.replay.at == at,
			"%s#%d: on tick %d, the offline replay's %d",
			name,
			n,
			frame.replay.at,
			at,
		)
		testing.expect_value(t, frame.replay.clip_from, max(at - 3, first))
		testing.expect_value(t, frame.replay.end, min(at + 5, last))
		testing.expectf(
			t,
			frame.slots[0] != 0 && frame.slots[1] != 0 && frame.local_player == frame.slots[0],
			"nobody named: it follows P1 (%d), not %d",
			frame.slots[0],
			frame.local_player,
		)
	}
	godot.api.stop()
	_ = drain(&messages, WAIT_MS, is_result)
	for godot.api.running() do time.sleep(time.Millisecond)
	godot.api.wait()
	second := replay_at(fmt.tprintf("%s#%d", name, n), "3", "5")
	second.player = 2
	ok, err = godot.api.start({mode = .Replay, arg = dir, name = "viewer", clip = second})
	if testing.expectf(t, ok, "replay start: %s", err) {
		frame, shown = replay_wait(WAIT_MS, proc(frame: ^godot.Frame_Data) -> bool {return frame.replay.at != 0})
		testing.expectf(
			t,
			shown && frame.slots[1] != 0 && frame.local_player == frame.slots[1],
			"--replay-player 2 follows slot 1's holder",
		)
		godot.api.stop()
		_ = drain(&messages, WAIT_MS, is_result)
		for godot.api.running() do time.sleep(time.Millisecond)
		godot.api.wait()
	}

	refusals := []struct {
		anchor, want: string,
	} {
		{"Event_Nope", "the game has no event Event_Nope"},
		{fmt.tprintf("%s#%d", name, kind_count + 1), fmt.tprintf("holds %d of them", kind_count)},
		{"Event_Player_Left", "Event_Player_Left never occurs"},
	}
	for refusal, i in refusals {
		if i == 2 && left > 0 do continue // the recording has a leave
		ok, err = godot.api.start({mode = .Replay, arg = dir, name = "viewer", clip = replay_at(refusal.anchor)})
		if !testing.expectf(t, ok, "replay start: %s", err) do continue
		clear(&messages)
		failed := drain(&messages, WAIT_MS, proc(message: godot.Message) -> bool {
			return message.kind == .Status && message.status == .Failed
		})
		why := failed ? text(messages[len(messages) - 1]) : ""
		testing.expectf(t, strings.contains(why, refusal.want), "--replay-at %s: refused with %q", refusal.anchor, why)
		godot.api.stop()
		for godot.api.running() do time.sleep(time.Millisecond)
		godot.api.wait()
	}
}

// Start.paused: a session started paused shows its first tick and waits (the GDScript `start_single(); paused = true`
// in one frame: Start.hold keeps its first step for the next frame, which the pause reaches first); it steps exactly
// what is asked (the control socket's step), and goes on when unpaused.
@(private = "file")
sessions_start_paused :: proc(t: ^testing.T) {
	ok, err := godot.api.start({mode = .Single, seed = 7, name = "solo", hold = true})
	if !testing.expectf(t, ok, "start: %s", err) do return
	time.sleep(60 * time.Millisecond)
	frame, _ := godot.api.front()
	testing.expect(t, frame == nil || frame.tick == 0, "a held session takes no step")
	godot.api.set_paused(true) // what a script sets in the frame it started the session
	godot.api.release() // the session node's next frame
	waited := time.tick_now()
	for !godot.api.paused() && time.duration_seconds(time.tick_since(waited)) < WAIT_S do time.sleep(time.Millisecond)
	testing.expect(t, godot.api.paused(), "it pauses")
	time.sleep(100 * time.Millisecond)
	frame, _ = godot.api.front()
	// the first tick is the one the clock's start computes (a paused host whose clock never started could not step)
	testing.expectf(
		t,
		frame == nil || frame.tick <= 1,
		"paused on its first tick: %v",
		frame.tick if frame != nil else 0,
	)
	from: u32 = frame != nil ? frame.tick : 0
	goal, asked := godot.api.step(3)
	testing.expect(t, asked)
	for taken, _ := godot.api.stepped(); taken != goal; taken, _ = godot.api.stepped() {
		if time.duration_seconds(time.tick_since(waited)) > 5 do break
		time.sleep(time.Millisecond)
	}
	taken, tick := godot.api.stepped()
	testing.expectf(t, taken == goal && tick == from + 3, "three ticks stepped: %d of %d, tick %d", taken, goal, tick)
	godot.api.set_paused(false)
	for frame, _ = godot.api.front(); frame == nil || frame.tick < 8; frame, _ = godot.api.front() {
		if time.duration_seconds(time.tick_since(waited)) > 5 do break
		time.sleep(time.Millisecond)
	}
	testing.expect(t, frame != nil && frame.tick >= 8, "unpaused, it goes on")
	godot.api.wait()

	// Start.paused itself (a restart's: the waiting start carries what was set meanwhile)
	ok, err = godot.api.start({mode = .Single, seed = 7, name = "solo", paused = true})
	if !testing.expectf(t, ok, "start: %s", err) do return
	waited = time.tick_now()
	for !godot.api.paused() && time.duration_seconds(time.tick_since(waited)) < WAIT_S do time.sleep(time.Millisecond)
	time.sleep(60 * time.Millisecond)
	frame, _ = godot.api.front()
	testing.expect(
		t,
		godot.api.paused() && (frame == nil || frame.tick <= 1),
		"Start.paused: paused on its first tick",
	)
	godot.api.wait()
}

// A local player's queued commands are that player's alone: one removed and another added in its place in one frame
// (both done, the removal first) never sends what the removed one queued.
@(private = "file")
local_commands_stay_their_players :: proc(t: ^testing.T) {
	ok, err := godot.api.start({mode = .Single, seed = 7, name = "solo"})
	if !testing.expectf(t, ok, "start: %s", err) do return
	defer godot.api.wait()
	godot.api.sample_input()
	waited := time.tick_now()
	second_key :: proc() -> u64 {
		frame, _ := godot.api.front()
		return frame != nil ? frame.local_players[1] : 0
	}
	for frame, _ := godot.api.front(); frame == nil || frame.tick < 4; frame, _ = godot.api.front() {
		time.sleep(time.Millisecond)
	}
	testing.expect(t, godot.api.local_player(1, true, "Second", nil))
	for second_key() == 0 && time.duration_seconds(time.tick_since(waited)) < WAIT_S do time.sleep(time.Millisecond)
	first_second := second_key()
	if !testing.expect(t, first_second != 0, "local player 1 joins") do return
	// hold the session thread in fill_frame: what follows is one main-thread frame, before it looks
	sync.atomic_store(&seen.hold, 1)
	for sync.atomic_load(&seen.hold) != 2 && time.duration_seconds(time.tick_since(waited)) < WAIT_S do time.sleep(time.Millisecond)
	testing.expect(t, godot.api.send(sim.command_make(toy.Command, toy.Command_Bump{5}), 1))
	testing.expect(t, godot.api.local_player(1, false, "", nil))
	testing.expect(t, godot.api.local_player(1, true, "Third", nil))
	sync.atomic_store(&seen.hold, 3)
	// with a token the player added at index 1 is the same member again, so its key need not change: wait for the
	// session thread to have taken both requests, then for the added one to be seated
	time.sleep(100 * time.Millisecond)
	for second_key() == 0 && time.duration_seconds(time.tick_since(waited)) < WAIT_S do time.sleep(time.Millisecond)
	testing.expect(t, second_key() != 0, "removed, then another added in its place")
	time.sleep(100 * time.Millisecond)
	testing.expect_value(t, sync.atomic_load(&seen.second_bumps), 0)
	sync.atomic_store(&seen.hold, 0)
}

// A fill_frame that writes what it reads (the Setup here) is reported once (dev UI builds): the ring's state is what a
// re-simulation restores from.
@(private = "file")
fill_frame_writing_is_reported :: proc(t: ^testing.T) {
	sync.atomic_store(&seen.scribble, true)
	defer sync.atomic_store(&seen.scribble, false)
	ok, err := godot.api.start({mode = .Single, seed = 7, ticks = 40, name = "solo"})
	if !testing.expectf(t, ok, "start: %s", err) do return
	messages := make([dynamic]godot.Message, context.temp_allocator)
	testing.expect(t, drain(&messages, WAIT_MS, is_result), "the session ends")
	problems := 0
	for message in messages do if message.kind == .Problem && strings.contains(text(message), "fill_frame wrote") do problems += 1
	testing.expect_value(t, problems, 1)
	for godot.api.running() do time.sleep(time.Millisecond)
	godot.api.wait()
}

// `uni drive command` finds a command by its name or its type's, in any case; not by another spelling.
@(test)
commands_are_named_either_way :: proc(t: ^testing.T) {
	layouts := []string{"bump", "dev_spawn"}
	testing.expect_value(t, godot.command_kind_named(layouts, "bump"), 0)
	testing.expect_value(t, godot.command_kind_named(layouts, "Command_Bump"), 0)
	testing.expect_value(t, godot.command_kind_named(layouts, "command_dev_spawn"), 1)
	testing.expect_value(t, godot.command_kind_named(layouts, "Command_Dev_Spawn"), 1)
	testing.expect_value(t, godot.command_kind_named(layouts, "cmd_bump"), -1)
	testing.expect_value(t, godot.command_kind_named(layouts, "Command_"), -1)
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

// The host's pose memory: tick - 1 as remembered, and its estimate after a rollback or skipped ticks.
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
		godot.push_view(&frame, first, {pos = {f32(tick), 0, 0}}, View_Dot{})
		godot.push_view(&frame, second, {pos = {100 + f32(tick), 0, 0}}, View_Dot{})
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
		godot.to_view(View_Dot, player),
		godot.Event_Target{View_Dot, sim.player_key(player), .View},
	)
	testing.expect_value(t, godot.to_view(View_Dot, sim.entity(5)), godot.Event_Target{View_Dot, 5, .View})
	testing.expect_value(t, godot.to_view(View_Dot), godot.Event_Target{View_Dot, 0, .View})
	testing.expect_value(t, godot.to_view(View_Dot, sim.Entity(0)).route, godot.Event_Route.Subject) // none: by subject
}

@(private = "file")
Ring :: struct($T: typeid, $N: int) {
	items: [N]T,
}

@(private = "file")
Data_Generic :: struct {
	ring: Ring(u8, 4),
	bag:  sim.List(u8, 4), // a sim collection: an Array, no problem
}

@(private = "file")
Generic_Data :: union {
	Data_Generic,
}

@(private = "file")
Data_Keyword :: struct {
	class: u8, // fine: GDScript reads `row.class` as the attribute
	null:  u8, // `row.null` is the literal
}

@(private = "file")
Keyword_Data :: union {
	Data_Keyword,
}

@(private = "file")
View_Keyword :: struct {
	class: u8, // fine: a view kind is a class like any other (`data.class`)
	Node:  u8, // fine: a field, not a script var
	true:  u8, // `data.true` is the literal
}

@(private = "file")
Keyword_View :: union {
	View_Keyword,
}

// What GDScript can't read is an install problem naming the field: in a class (session data, a view kind) only
// `true`, `false` and `null`.
@(test)
a_name_gdscript_cant_take_is_an_install_problem :: proc(t: ^testing.T) {
	glue := godot.Glue(toy.Game, Keyword_View, MultiView) {
		sample_input = GLUE.sample_input,
		fill_frame = proc(_: ^godot.Frame(toy.Game, Keyword_View, MultiView)) {},
		data = Keyword_Data,
	}
	problems := godot.install_problems(&toy.GAME, glue)
	names := strings.join(problems, "\n", context.temp_allocator)
	testing.expectf(t, len(problems) == 2, "%v", problems)
	for field in ([]string{"Data_Keyword.null", "View_Keyword.true"}) {
		testing.expectf(t, strings.contains(names, field), "%s: %v", field, problems)
	}
	testing.expectf(t, !strings.contains(names, "Data_Keyword.class"), "a class's `class` field reads: %v", problems)
}

// A generic struct in what GDScript reads (here session data) is an install problem naming its field: no class can be
// named after it (`Ring($T=u8, $N=4)`), and Godot would fail at load. sim's collections are Arrays, never a problem.
@(test)
a_generic_struct_is_an_install_problem :: proc(t: ^testing.T) {
	glue := GLUE
	glue.data = Generic_Data
	problems := godot.install_problems(&toy.GAME, glue)
	testing.expectf(t, len(problems) == 1 && strings.contains(problems[0], "Data_Generic.ring"), "%v", problems)
}

@(private = "file")
Stats :: struct {
	waves: u8,
}

@(private = "file")
Data_Stats :: struct {
	stats: Stats, // nested: the class DataStats, which Data_Stats is too
}

@(private = "file")
Stats_Data :: union {
	Data_Stats,
}

// Two types that would be the same class are an install problem naming both: Godot would refuse the second at load,
// leaving it out of GDScript (here session data and the struct nested in it).
@(test)
a_class_name_collision_is_an_install_problem :: proc(t: ^testing.T) {
	glue := GLUE
	glue.data = Stats_Data
	problems := godot.install_problems(&toy.GAME, glue)
	testing.expectf(t, len(problems) == 1, "%v", problems)
	if len(problems) == 1 {
		testing.expect_value(
			t,
			problems[0],
			"Data_Stats and Stats would both be the class DataStats: rename one of them",
		)
	}
}

@(private = "file")
View_Small :: struct {
	hp: i32,
}

@(private = "file")
View_Huge :: struct {
	bytes: [godot.VIEW_DATA_MAX + 4]u8,
}

@(private = "file")
Huge_View :: union {
	View_Small,
	View_Huge,
}

// A view kind past VIEW_DATA_MAX is an install problem naming it (its views' samples on the verified timeline would
// hold too much), never a failure while a session runs.
@(test)
a_view_kind_past_the_data_bound_is_an_install_problem :: proc(t: ^testing.T) {
	glue := godot.Glue(toy.Game, Huge_View, MultiView) {
		sample_input = GLUE.sample_input,
		fill_frame = proc(_: ^godot.Frame(toy.Game, Huge_View, MultiView)) {},
	}
	problems := godot.install_problems(&toy.GAME, glue)
	testing.expectf(t, len(problems) == 1 && strings.contains(problems[0], "View_Huge"), "%v", problems)
}

@(private = "file")
View_At_Bound :: struct {
	bytes: [godot.VIEW_DATA_MAX]u8,
}

@(private = "file")
Bound_View :: union {
	View_At_Bound,
}

// A view kind of exactly VIEW_DATA_MAX installs.
@(test)
a_view_kind_at_the_data_bound_installs :: proc(t: ^testing.T) {
	glue := godot.Glue(toy.Game, Bound_View, MultiView) {
		sample_input = GLUE.sample_input,
		fill_frame = proc(_: ^godot.Frame(toy.Game, Bound_View, MultiView)) {},
	}
	problems := godot.install_problems(&toy.GAME, glue)
	testing.expectf(t, len(problems) == 0, "%v", problems)
}
