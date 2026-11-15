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
}

@(private = "file")
View :: enum u8 {
	Dot,
}

@(private = "file")
Multi :: enum u8 {
	Spark,
}

@(private = "file")
GLUE := godot.Glue(toy.State, toy.Input, toy.World, View, Multi) {
	sample_input = proc(input: ^toy.Input) {input.dx = sync.atomic_load(&seen.dx)},
	fill_frame = proc(frame: ^godot.Frame(toy.State, toy.World, View, Multi)) {
		state := frame.state
		for player in 0 ..< toy.PLAYERS {
			if !state.joined[player] do continue
			godot.push_view(
				frame,
				{
					key = view.Key(1 + player),
					kind = .Dot,
					player = player,
					pos = {state.pos[player].x, 0, state.pos[player].y},
				},
			)
			godot.push_multi(frame, {key = u64(1 + player), kind = .Spark, pos = {state.pos[player].x, 1, 0}})
		}
		sync.atomic_store(&seen.bumps, state.bumps[0])
		sync.atomic_store(&seen.bump_fold, state.bump_fold[0])
		sync.atomic_add(&seen.extracted, 1)
	},
	// event positions in view units: ×10, lifted by 1 (a game's metres or cells to pixels)
	event_pos = proc(position: sim.Position, world: ^toy.World) -> sim.Position {
		return {position.x * 10, position.y * 10, position.z * 10 + 1}
	},
}

@(private = "file")
FAILING := godot.Transport {
	name = "fake",
	open_host = proc(_: rawptr, events: ^godot.Transport_Events) -> (netcode.Link, bool) {
		events.fail(events.ctx, "fake: no lobby service")
		return {}, false
	},
	close = proc(_: rawptr) {seen.closes += 1},
}

@(private = "file")
OPENING := godot.Transport {
	name = "fake",
	open_host = proc(_: rawptr, events: ^godot.Transport_Events) -> (netcode.Link, bool) {
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
		ok, err := godot.api.start({mode = .Single, seed = 7, ticks = 40, name = "solo", scripted = false})
		testing.expect(t, ok, err)
		godot.api.sample_input() // the main thread's sample (the session took none yet: a start clears it)
		for amount in ([]i32{3, -1, 8}) {
			command, _ := sim.command_make(toy.Command, toy.Cmd_Bump{amount})
			testing.expect(t, godot.api.send(command))
		}
		messages := make([dynamic]godot.Message, context.temp_allocator)
		testing.expect(t, drain(&messages, 5000, is_result), "the session ends with a result")
		connected, joined := false, false
		for &message in messages {
			if message.kind == .Status && message.status == .Connected do connected = true
			if message.kind != .Event do continue
			switch event in sim.event_value(&message.event, toy.Event) {
			case toy.Joined:
				if message.action == .Confirmed do joined = true
			case toy.Spawned, toy.Left, toy.Expired:
			}
		}
		testing.expect(t, connected, "a Connected status")
		testing.expect(t, joined, "the local player's join is confirmed")
		frame, _ := godot.api.front()
		testing.expect(
			t,
			frame != nil && frame.n_views == 1 && frame.n_multis == 1 && frame.local_player == 0,
			"the last frame shows the player",
		)
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
		for godot.api.running() do time.sleep(time.Millisecond)
		godot.api.wait()
		testing.expect(t, !godot.api.running())
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

	// A transport that opens: the code reaches the main thread, pump runs, stop ends the session
	// (nobody to say goodbye to) and closes the transport once.
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
		testing.expect_value(t, seen.closes, 1)
	}
}

// The dev UI's netsim link: straight through while off (no queue), impaired while on, drained after.
@(test)
dev_link_passes_through_while_off :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	dev_link, link := godot.dev_link_wrap(netcode.loopback_link(hub, 0), 5)
	other := netcode.loopback_link(hub, 1)
	defer netcode.link_close(&other)
	buf: [64]u8
	inbox := proc(hub: ^netcode.Hub, i: int) -> int {
		sync.guard(&hub.inboxes[i].mu)
		return len(hub.inboxes[i].queue)
	}

	netcode.link_send(&link, 1, {1, 2, 3})
	testing.expect_value(t, inbox(hub, 1), 1) // delivered at once, no netsim
	testing.expect(t, dev_link.sim.data == nil, "no netsim created while off")
	netcode.link_send(&other, 0, {9})
	size, from, ok := netcode.link_recv(&link, buf[:])
	testing.expect(t, ok && size == 1 && buf[0] == 9 && from == 1)

	godot.dev_link_set(dev_link, {enabled = true, up = {latency_ms = 20}, down = {latency_ms = 20}})
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
	netcode.link_close(&link)
}
