// L2 netcode tests for desync reports: what the relay sends reaches the client's `desync` hook and fails its
// result. (A desync made on purpose, detected and reported end to end: tests/headless.)
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:sim"
import "unified:wire"

// The relay's desync reports reach the `desync` hook, with the tick, who diverged and the detail.
@(test)
desync_report_reaches_the_hook :: proc(t: ^testing.T) {
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	fake: Fake_Relay
	fake_make(&fake, hub)
	defer fake_destroy(&fake)
	Seen :: struct {
		count:    int,
		tick:     u32,
		diverged: sim.Players,
		detail:   [64]u8,
		len:      int,
	}
	seen: Seen
	hooks := Hooks {
		user = &seen,
		desync = proc(user: rawptr, report: netcode.Desync_Report) {
			seen := (^Seen)(user)
			seen.count += 1
			seen.tick, seen.diverged = report.tick, report.diverged
			seen.len = copy(seen.detail[:], report.detail)
		},
	}
	client := netcode.client_create(&toy.GAME, {
			slot  = -1,
			name  = "c",
			quiet = true,
		}, netcode.loopback_link(hub, 1), hooks)
	defer netcode.client_destroy(client)
	fake_welcome(&fake, client)
	writer := fake_begin(&fake, .Desync)
	wire.w_u32(writer, 4160)
	wire.w_u32(writer, transmute(u32)sim.Players{2})
	detail := "tick 4160: score[2] 3 vs 4"
	wire.w_u16(writer, u16(len(detail)))
	wire.w_bytes(writer, transmute([]u8)detail)
	fake_send(&fake)
	for _ in 0 ..< 4 {
		fake_step(&fake, client)
	}
	testing.expect_value(t, seen.count, 1)
	testing.expect_value(t, seen.tick, 4160)
	testing.expect_value(t, seen.diverged, sim.Players{2})
	testing.expect_value(t, string(seen.detail[:seen.len]), detail)
	testing.expect_value(t, client.desyncs, 1)
	testing.expect(t, !netcode.client_result(client, context.temp_allocator).ok)
}
