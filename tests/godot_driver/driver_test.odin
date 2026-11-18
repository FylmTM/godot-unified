// unified:godot without Godot: the session driver (its thread, frames, previous poses, the input hand-off, events,
// statuses, transports) installed with the toy game, and the dev UI's switchable netsim link. The Godot-facing classes run under headless
// Godot (the godot suite's `session` step, tests/godot, tests/godot_views).
package test_godot_driver

import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "unified:godot"
import "unified:netcode"
import "unified:sim"
import "unified:view"

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
	compat:    u64, // what the transport's open_host got
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
	sample_input = proc(input: ^toy.Input) {input.dx = sync.atomic_load(&seen.dx)},
	fill_frame = proc(frame: ^godot.Frame(toy.Game, View, MultiView)) {
		players := sim.iterate_present(&frame.state.players)
		for data, player in sim.next(&players) {
			godot.push_view(frame, {
				kind   = .Dot,
				player = player,
				pos    = {data.pos.x, 0, data.pos.y},
			})
			godot.push_multi_view(frame, {
				key  = sim.player_key(player),
				kind = .Spark,
				pos  = {data.pos.x, 1, 0},
			})
		}
		if local := sim.player_data(&frame.state.players, frame.local_player); local != nil {
			sync.atomic_store(&seen.bumps, local.bumps)
			sync.atomic_store(&seen.bump_fold, local.bump_fold)
			// the join tick's events are queued, its Frame not published yet: hold here while the test looks
			if sync.atomic_load(&seen.hold) == 1 {
				seen.held_tick = frame.tick
				sync.atomic_store(&seen.hold, 2)
				for sync.atomic_load(&seen.hold) != 3 do time.sleep(time.Millisecond)
			}
		}
		sync.atomic_add(&seen.extracted, 1)
	},
	view_scale = 10, // event positions stay in sim units across the hand-off: the main thread maps them
}

@(private = "file")
FAILING := godot.Transport {
	name = "fake",
	open_host = proc(_: rawptr, compat: u64, events: ^godot.Transport_Events) -> (netcode.Link, bool) {
		events.fail(events.ctx, "fake: no lobby service")
		return {}, false
	},
	close = proc(_: rawptr) {seen.closes += 1},
}

@(private = "file")
OPENING := godot.Transport {
	name = "fake",
	open_host = proc(_: rawptr, compat: u64, events: ^godot.Transport_Events) -> (netcode.Link, bool) {
		seen.compat = compat
		events.code(events.ctx, "ABC123")
		return netcode.loopback_link(seen.hub, 0), true
	},
	pump = proc(_: rawptr, events: ^godot.Transport_Events) {seen.pumps += 1},
	close = proc(_: rawptr) {seen.closes += 1},
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

// The recording of the session (driver.odin, what an F3 note carries): its snapshot and input log replay offline to
// the checksum the session computed of a tick the log reaches.
@(private = "file")
recording_replays :: proc(t: ^testing.T) {
	snapshot, log_bytes: [dynamic]u8
	defer delete(snapshot)
	defer delete(log_bytes)
	info, recorded := godot.api.recording(&snapshot, &log_bytes)
	if !testing.expect(t, recorded, "the session was recorded") do return
	testing.expectf(t, info.check_tick > info.from && info.check_tick <= info.to, "a tick to check: %v", info)
	input_log, log_ok := sim.log_decode(log_bytes[:], toy.Game)
	defer sim.log_destroy(&input_log)
	testing.expect(t, log_ok, "the input log decodes")
	testing.expect_value(t, len(input_log.ticks), int(info.to - info.from))
	simulation, err := sim.from_snapshot(&toy.GAME, snapshot[:])
	if !testing.expect_value(t, err, sim.Snap_Error.None) do return
	defer sim.destroy(simulation)
	checked := false
	for k in 0 ..< len(input_log.ticks) {
		inputs := sim.log_inputs(&input_log, k)
		sim.step(simulation, &inputs)
		if simulation.tick == info.check_tick {
			testing.expect_value(t, sim.checksum(simulation), info.check)
			checked = true
		}
	}
	testing.expect(t, checked, "the replay reached the checked tick")
	testing.expect_value(t, simulation.tick, info.to)
}

@(test)
driver_sessions :: proc(t: ^testing.T) {
	godot.install(&toy.GAME, GLUE)
	testing.expect(t, godot.api.installed)
	testing.expect_value(t, len(godot.api.view_names), 1)
	if len(godot.api.view_names) == 1 do testing.expect_value(t, godot.api.view_names[0], "dot")
	testing.expect_value(t, godot.api.tick_hz, toy.HZ)

	// Single player, 40 ticks: connected, frames published with the previous poses the host remembered, the
	// main thread's input sample reaches the sim, commands sent from the main thread reach the sim once each, in
	// order, verified events confirmed, a result at the end.
	{
		testing.expect(t, !godot.api.send({}), "no session: nothing to send to")
		sync.atomic_store(&seen.dx, 1)
		godot.api.sample_input()
		ok, err := godot.api.start({
			mode     = .Single,
			seed     = 7,
			ticks    = 40,
			name     = "solo",
			scripted = false,
		})
		testing.expect(t, ok, err)
		godot.api.sample_input() // the main thread's sample (the session took none yet: a start clears it)
		for amount in ([]i32{3, -1, 8}) {
			command := sim.command_make(toy.Cmd, toy.Cmd_Bump{amount})
			testing.expect(t, godot.api.send(command))
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
		// ids (#240): never 0; an event's Emitted and its final state share one, and no two events do
		emitted := make(map[u64]int, context.temp_allocator)
		finals := make(map[u64]int, context.temp_allocator)
		for message in events {
			testing.expect(t, message.id != 0, "an event has an id")
			if message.action == .Emitted do emitted[message.id] += 1
			else do finals[message.id] += 1
		}
		testing.expect(t, len(emitted) > 0, "events")
		for id, count in emitted {
			testing.expectf(t, count == 1, "id %d emitted once (%d)", id, count)
			testing.expectf(t, finals[id] <= 1, "id %d has at most one final state", id)
		}
		for id in finals do testing.expectf(t, id in emitted, "id %d: a final state of an emitted event", id)
		testing.expect(t, connected, "a Connected status")
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
			testing.expect(t, known && netcode.name_string(&entry.name) == "solo", "the roster names the player")
		}
		testing.expect(t, frame != nil && frame.tick >= 39, "the last frame is at the end")
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

	// Online without a transport: refused before a thread starts.
	{
		ok, err := godot.api.start({mode = .Host_Online})
		testing.expect(t, !ok && err != "", "online needs a transport")
	}

	// A transport that fails to open: its reason is the only Failed status (no generic one after it).
	{
		godot.set_transport(&FAILING)
		defer godot.set_transport(nil)
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

	// A transport that opens: it gets the session's build id (what the relay checks), the code reaches the main
	// thread, pump runs, stop ends the session (nobody to say goodbye to) and closes the transport once.
	{
		seen.hub = netcode.hub_create(2)
		defer netcode.hub_destroy(seen.hub)
		seen.closes, seen.pumps = 0, 0
		godot.set_transport(&OPENING)
		defer godot.set_transport(nil)
		ok, _ := godot.api.start({mode = .Host_Online, seed = 3})
		testing.expect(t, ok)
		messages := make([dynamic]godot.Message, context.temp_allocator)
		got_code := drain(&messages, 2000, proc(message: godot.Message) -> bool {
			return message.kind == .Lobby_Code && text(message) == "ABC123"
		})
		testing.expect(t, got_code, "the lobby code is posted")
		time.sleep(50 * time.Millisecond)
		godot.api.stop()
		testing.expect(t, godot.api.stopping())
		testing.expect(t, drain(&messages, 5000, is_result), "a stopped session ends with a result")
		for godot.api.running() do time.sleep(time.Millisecond)
		godot.api.wait()
		testing.expect(t, seen.pumps > 0, "the transport is pumped")
		testing.expect_value(t, seen.compat, sim.compat_of(&toy.GAME))
		testing.expect_value(t, seen.closes, 1)
	}

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
	}
}

@(private = "file")
g_forgot: [dynamic]netcode.Peer // the peers the wrapped link was told to forget

// The dev UI's netsim link: straight through while off (no queue), impaired while on, drained after. `forget` reaches
// the transport either way (EOS closes the peer's connection with it, UDP frees the peer number).
@(test)
dev_link_passes_through_while_off :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	inner := netcode.loopback_link(hub, 0)
	inner.forget = proc(data: rawptr, peer: netcode.Peer) {append(&g_forgot, peer)}
	defer delete(g_forgot)
	dev_link, link := godot.dev_link_wrap(inner, 5)
	other := netcode.loopback_link(hub, 1)
	defer netcode.link_close(&other)
	buf: [64]u8
	inbox := proc(hub: ^netcode.Hub, i: int) -> int {
		return netcode.hub_queued(hub, netcode.Peer(i))
	}

	netcode.link_forget(&link, 1)
	netcode.link_send(&link, 1, {1, 2, 3})
	testing.expect_value(t, inbox(hub, 1), 1) // delivered at once, no netsim
	testing.expect(t, dev_link.sim.data == nil, "no netsim created while off")
	netcode.link_send(&other, 0, {9})
	size, from, ok := netcode.link_recv(&link, buf[:])
	testing.expect(t, ok && size == 1 && buf[0] == 9 && from == 1)

	godot.dev_link_set(dev_link, {
		enabled = true,
		up = {latency_ms = 20},
		down = {latency_ms = 20},
	})
	netcode.link_forget(&link, 1) // with the netsim on
	netcode.link_send(&link, 1, {4})
	testing.expect_value(t, inbox(hub, 1), 1) // held for 20 ms
	time.sleep(30 * time.Millisecond)
	_, _, _ = netcode.link_recv(&link, buf[:]) // pumps the netsim
	testing.expect_value(t, inbox(hub, 1), 2)

	// Off again: a datagram received while on is still delivered (drained), then direct.
	netcode.link_send(&other, 0, {7})
	_, _, _ = netcode.link_recv(&link, buf[:]) // the netsim takes it in, due in 20 ms
	godot.dev_link_set(dev_link, {})
	time.sleep(30 * time.Millisecond)
	size, _, ok = netcode.link_recv(&link, buf[:])
	testing.expect(t, ok && size == 1 && buf[0] == 7, "drained after the switch")
	netcode.link_send(&link, 1, {5})
	testing.expect_value(t, inbox(hub, 1), 3) // direct again
	testing.expect_value(t, len(g_forgot), 2)
	netcode.link_close(&link)
}

// The host's pose memory (#284): tick - 1 as remembered, and its estimate after a rollback or skipped ticks.
@(test)
pose_memory_estimates_after_rollbacks :: proc(t: ^testing.T) {
	memory: godot.Pose_Memory
	godot.pose_memory_init(&memory, 4, 4)
	defer godot.pose_memory_destroy(&memory)
	remember :: proc(memory: ^godot.Pose_Memory, tick: u32, x: f32, rollback := false) -> (f32, bool) {
		godot.pose_memory_begin(memory, rollback)
		previous, found := godot.pose_remember(memory, .View, 0, 7, tick, {x, 0, 0}, view.IDENTITY)
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
