// godot_host without Godot: the session driver (its thread, frames, events, statuses, transports) installed
// with the toy game, and the dev UI's switchable netsim link. The Godot-facing classes run under headless
// Godot (`dev.py game headless`, `session-check`, tests/godot).
package test_godot_host

import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import gh "unified:godot_host"
import "unified:netcode"
import "unified:sim"
import "unified:view"

import "../toy"

@(private = "file")
seen: struct {
	pressed:   u32, // button edges the sample hook received (atomic)
	extracted: int, // frames extracted (atomic)
	bumps:     u32, // the local player's bump commands applied, in the last frame (atomic)
	bump_fold: u32,
	pumps:     int,
	closes:    int,
	hub:       ^netcode.Hub,
}

@(private = "file")
GLUE := gh.Glue(toy.State, toy.Input, toy.World) {
	scenes = {{name = "dot"}},
	scene_dir = "res://views",
	actions = {buttons = {"spawn"}},
	extract = proc(cur, prev: ^toy.State, w: ^toy.World, out: ^gh.Frame) {
		for p in 0 ..< toy.SLOTS {
			if !cur.joined[p] do continue
			out.scene[out.n_scene] = {
				key  = view.Key(1 + p),
				slot = i8(p),
				pos  = {cur.pos[p].x, 0, cur.pos[p].y},
			}
			out.n_scene += 1
		}
		sync.atomic_store(&seen.bumps, cur.bumps[0])
		sync.atomic_store(&seen.bump_fold, cur.bump_fold[0])
		sync.atomic_add(&seen.extracted, 1)
	},
	sample = proc(a: gh.Actions, slot: int, tick: u32, state: ^toy.State) -> toy.Input {
		sync.atomic_or(&seen.pressed, a.pressed)
		return {dx = 1, buttons = u8(a.pressed & 1)}
	},
}

@(private = "file")
FAILING := gh.Transport {
	name = "fake",
	open_host = proc(_: rawptr, ev: ^gh.Transport_Events) -> (netcode.Link, bool) {
		ev.fail(ev.ctx, "fake: no lobby service")
		return {}, false
	},
	close = proc(_: rawptr) {seen.closes += 1},
}

@(private = "file")
OPENING := gh.Transport {
	name = "fake",
	open_host = proc(_: rawptr, ev: ^gh.Transport_Events) -> (netcode.Link, bool) {
		ev.code(ev.ctx, "ABC123")
		return netcode.loopback_link(seen.hub, 0), true
	},
	pump = proc(_: rawptr, ev: ^gh.Transport_Events) {seen.pumps += 1},
	close = proc(_: rawptr) {seen.closes += 1},
}

// Pops messages until `pred` holds or `ms` pass; returns every message seen.
@(private = "file")
drain :: proc(out: ^[dynamic]gh.Message, ms: int, pred: proc(m: gh.Message) -> bool) -> bool {
	deadline := time.tick_now()
	for time.duration_milliseconds(time.tick_since(deadline)) < f64(ms) {
		for {
			m, ok := gh.api.pop()
			if !ok do break
			append(out, m)
			if pred(m) do return true
		}
		time.sleep(2 * time.Millisecond)
	}
	return false
}

@(private = "file")
text :: proc(m: gh.Message) -> string {
	m := m
	return strings.clone(string(m.text[:m.len]), context.temp_allocator)
}

@(private = "file")
is_result :: proc(m: gh.Message) -> bool {return m.kind == .Result}

@(test)
driver_sessions :: proc(t: ^testing.T) {
	gh.install(&toy.GAME, GLUE)
	testing.expect(t, gh.api.installed)
	testing.expect_value(t, gh.api.scene_dir, "res://views")
	testing.expect_value(t, gh.api.tick_hz, toy.HZ)

	// Single player, 40 ticks: connected, frames published, a pressed button reaches sample once,
	// commands sent from the main thread reach the sim once each, in order, verified events confirmed, a
	// result at the end.
	{
		testing.expect(t, !gh.api.send({}), "no session: nothing to send to")
		ok, err := gh.api.start({mode = .Single, seed = 7, ticks = 40, name = "solo"})
		testing.expect(t, ok, err)
		gh.press_button(0)
		for amount in ([]i32{3, -1, 8}) {
			c, _ := sim.command_make(toy.GAME.commands, toy.Cmd_Bump{amount})
			testing.expect(t, gh.api.send(c))
		}
		msgs := make([dynamic]gh.Message, context.temp_allocator)
		testing.expect(t, drain(&msgs, 5000, is_result), "the session ends with a result")
		connected, joined := false, false
		for m in msgs {
			if m.kind == .Status && m.status == .Connected do connected = true
			if m.kind == .Event && m.action == .Confirm && toy.Event_Kind(m.event.kind) == .Joined do joined = true
		}
		testing.expect(t, connected, "a Connected status")
		testing.expect(t, joined, "the local player's join is confirmed")
		f, _ := gh.api.front()
		testing.expect(t, f != nil && f.n_scene == 1 && f.local_slot == 0, "the last frame shows the player")
		testing.expect(t, f != nil && f.tick >= 39, "the last frame is at the end")
		testing.expect(t, sync.atomic_load(&seen.extracted) > 0)
		testing.expect_value(t, sync.atomic_load(&seen.pressed), 1) // exactly the one press, once
		testing.expect_value(t, sync.atomic_load(&seen.bumps), 3)
		testing.expect_value(
			t,
			sync.atomic_load(&seen.bump_fold),
			toy.bump_fold(toy.bump_fold(toy.bump_fold(0, 3), -1), 8),
		)
		testing.expect(t, strings.contains(gh.api.result(), "\"checksum"), gh.api.result())
		for gh.api.running() do time.sleep(time.Millisecond)
		gh.api.wait()
		testing.expect(t, !gh.api.running())
	}

	// Online without a transport: refused before a thread starts.
	{
		ok, err := gh.api.start({mode = .Host_Online})
		testing.expect(t, !ok && err != "", "online needs a transport")
	}

	// A transport that fails to open: its reason is the only Failed status (no generic one after it).
	{
		gh.set_transport(&FAILING)
		defer gh.set_transport(nil)
		ok, _ := gh.api.start({mode = .Host_Online})
		testing.expect(t, ok)
		for gh.api.running() do time.sleep(time.Millisecond)
		msgs := make([dynamic]gh.Message, context.temp_allocator)
		drain(&msgs, 50, proc(m: gh.Message) -> bool {return false})
		failed: [dynamic]string
		failed.allocator = context.temp_allocator
		for m in msgs do if m.kind == .Status && m.status == .Failed do append(&failed, text(m))
		testing.expect_value(t, len(failed), 1)
		if len(failed) == 1 do testing.expect_value(t, failed[0], "fake: no lobby service")
		gh.api.wait()
	}

	// A transport that opens: the code reaches the main thread, pump runs, stop ends the session
	// (nobody to say goodbye to) and closes the transport once.
	{
		seen.hub = netcode.hub_create(2)
		defer netcode.hub_destroy(seen.hub)
		seen.closes, seen.pumps = 0, 0
		gh.set_transport(&OPENING)
		defer gh.set_transport(nil)
		ok, _ := gh.api.start({mode = .Host_Online, seed = 3})
		testing.expect(t, ok)
		msgs := make([dynamic]gh.Message, context.temp_allocator)
		got_code := drain(&msgs, 2000, proc(m: gh.Message) -> bool {
			return m.kind == .Lobby_Code && text(m) == "ABC123"
		})
		testing.expect(t, got_code, "the lobby code is posted")
		time.sleep(50 * time.Millisecond)
		gh.api.stop()
		testing.expect(t, gh.api.stopping())
		testing.expect(t, drain(&msgs, 5000, is_result), "a stopped session ends with a result")
		for gh.api.running() do time.sleep(time.Millisecond)
		gh.api.wait()
		testing.expect(t, seen.pumps > 0, "the transport is pumped")
		testing.expect_value(t, seen.closes, 1)
	}
}

// The dev UI's netsim link: straight through while off (no queue), impaired while on, drained after.
@(test)
dev_link_passes_through_while_off :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	dl, l := gh.dev_link_wrap(netcode.loopback_link(hub, 0), 5)
	other := netcode.loopback_link(hub, 1)
	defer netcode.link_close(&other)
	buf: [64]u8
	inbox := proc(hub: ^netcode.Hub, i: int) -> int {
		sync.guard(&hub.inboxes[i].mu)
		return len(hub.inboxes[i].queue)
	}

	netcode.link_send(&l, 1, {1, 2, 3})
	testing.expect_value(t, inbox(hub, 1), 1) // delivered at once, no netsim
	testing.expect(t, dl.sim.data == nil, "no netsim created while off")
	netcode.link_send(&other, 0, {9})
	n, from, ok := netcode.link_recv(&l, buf[:])
	testing.expect(t, ok && n == 1 && buf[0] == 9 && from == 1)

	gh.dev_link_set(dl, {enabled = true, latency_ms = 20})
	netcode.link_send(&l, 1, {4})
	testing.expect_value(t, inbox(hub, 1), 1) // held for 20 ms
	time.sleep(30 * time.Millisecond)
	_, _, _ = netcode.link_recv(&l, buf[:]) // pumps the netsim
	testing.expect_value(t, inbox(hub, 1), 2)

	// Off again: a datagram received while on is still delivered (drained), then direct.
	netcode.link_send(&other, 0, {7})
	_, _, _ = netcode.link_recv(&l, buf[:]) // the netsim takes it in, due in 20 ms
	gh.dev_link_set(dl, {})
	time.sleep(30 * time.Millisecond)
	n, _, ok = netcode.link_recv(&l, buf[:])
	testing.expect(t, ok && n == 1 && buf[0] == 7, "drained after the switch")
	netcode.link_send(&l, 1, {5})
	testing.expect_value(t, inbox(hub, 1), 3) // direct again
	netcode.link_close(&l)
}
