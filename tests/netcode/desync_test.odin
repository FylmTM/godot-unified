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
	planted: Planted // the fault this test plants warns by design: counted here, not printed
	context.logger = planted_logger(&planted)
	hub := netcode.hub_create(2)
	defer netcode.hub_destroy(hub)
	fake: Fake_Relay
	fake_make(&fake, hub)
	defer fake_destroy(&fake)
	Seen :: struct {
		count:    int,
		tick:     u32,
		diverged: sim.Slots,
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
	client := netcode.client_create(&toy.GAME, {}, netcode.loopback_link(hub, 1), hooks)
	defer netcode.client_destroy(client)
	fake_welcome(&fake, client)
	writer := fake_begin(&fake, .Desync)
	wire.w_u32(writer, 4160)
	wire.w_u32(writer, transmute(u32)sim.Slots{2})
	detail := "tick 4160: score[2] 3 vs 4"
	wire.w_u16(writer, u16(len(detail)))
	wire.w_bytes(writer, transmute([]u8)detail)
	fake_send(&fake)
	for _ in 0 ..< 4 {
		fake_step(&fake, client)
	}
	testing.expect_value(t, seen.count, 1)
	testing.expect_value(t, seen.tick, 4160)
	testing.expect_value(t, seen.diverged, sim.Slots{2})
	testing.expect_value(t, string(seen.detail[:seen.len]), detail)
	testing.expect_value(t, client.stats.desyncs, 1)
	testing.expect(t, !netcode.client_result(client, context.temp_allocator).ok)
	testing.expectf(t, planted.warnings > 0, "the planted fault warned of nothing")
}

// With two players a checksum vote is a tie: the lowest slot's value is the majority (with 2 players, the host's), and
// the other slot is the one that diverged, whichever of them computed wrong.
@(test)
a_checksum_tie_goes_to_the_lowest_slot :: proc(t: ^testing.T) {
	planted: Planted // the fault this test plants warns by design: counted here, not printed
	context.logger = planted_logger(&planted)
	for evil_slot in ([]u8{0, 1}) {
		session: Net
		net_make_relay(&session, 2, 0)
		defer net_destroy(&session)
		evil: Evil
		evil_seat(&evil, &session, 7, evil_slot)
		defer evil_destroy(&evil)
		evil.acking = true
		net_join(&session, 1 - int(evil_slot))
		evil_run(&evil, &session, 1)
		testing.expect(t, session.relay.started)
		tick := (session.relay.finalized / netcode.CHECKSUM_EVERY) * netcode.CHECKSUM_EVERY
		writer := evil_begin(&evil, .Checksum)
		wire.w_u32(writer, tick)
		wire.w_u64(writer, 1) // not what the honest client computes
		evil_send(&evil, &session)
		evil_run(&evil, &session, 2)
		testing.expectf(t, session.relay.desyncs == 1, "evil slot %d: %d desyncs", evil_slot, session.relay.desyncs)
		testing.expect_value(t, session.relay.first_desync.tick, tick)
		testing.expect_value(t, session.relay.first_desync.diverged, sim.Slots{1})
	}
	testing.expectf(t, planted.warnings > 0, "the planted fault warned of nothing")
}

// A typed report waits for its snapshots while they make progress, not a fixed time from asking: the diverged
// player's image is 4 MB, which takes ~4 s at the reliable pace (past IMAGE_WAIT_MS), and the report still diffs it.
@(test)
a_typed_report_waits_for_a_large_image :: proc(t: ^testing.T) {
	planted: Planted // the fault this test plants warns by design: counted here, not printed
	context.logger = planted_logger(&planted)
	session: Net
	net_make_relay(&session, 2, 0, desync_detail = true)
	defer net_destroy(&session)
	evil: Evil
	evil_seat(&evil, &session, 7, 1) // slot 1 loses the tie: the diverged one
	defer evil_destroy(&evil)
	evil.acking = true
	net_join(&session, 0, .Ideal)
	evil_run(&evil, &session, 1)
	tick := (session.relay.finalized / netcode.CHECKSUM_EVERY) * netcode.CHECKSUM_EVERY
	writer := evil_begin(&evil, .Checksum)
	wire.w_u32(writer, tick)
	wire.w_u64(writer, 1) // not what the honest client computes
	evil_send(&evil, &session)
	request := evil_run(&evil, &session, 2, .Snap_Request)
	if !testing.expect(t, request != nil, "the relay asked the diverged slot for no image") do return
	image := make([]u8, 4 << 20)
	defer delete(image)
	evil_snapshot(&evil, &session, netcode.RELAY_TARGET, tick, image)
	evil_run(&evil, &session, 10)
	testing.expect_value(t, session.relay.desyncs, 1)
	detail := session.relay.first_desync.detail
	testing.expectf(
		t,
		detail != "" && detail != "the snapshots of that tick were not available",
		"the report says %q",
		detail,
	)
	testing.expectf(t, planted.warnings > 0, "the planted fault warned of nothing")
}

// The typed report's setup up to the relay's request for the diverged slot's image (slot 1, a raw channel; slot 0
// an honest client): returns the honest client and the tick of the desync.
@(private = "file")
diverged_image_asked :: proc(t: ^testing.T, session: ^Net, evil: ^Evil) -> (honest: ^Client, tick: u32, ok: bool) {
	net_make_relay(session, 2, 0, desync_detail = true)
	evil_seat(evil, session, 7, 1) // slot 1 loses the tie: the diverged one
	evil.acking = true
	honest = net_join(session, 0, .Ideal)
	evil_run(evil, session, 1)
	tick = (session.relay.finalized / netcode.CHECKSUM_EVERY) * netcode.CHECKSUM_EVERY
	writer := evil_begin(evil, .Checksum)
	wire.w_u32(writer, tick)
	wire.w_u64(writer, 1) // not what the honest client computes
	evil_send(evil, session)
	request := evil_run(evil, session, 2, .Snap_Request)
	ok = testing.expect(t, request != nil, "the relay asked the diverged slot for no image")
	return
}

// An empty chunk is no progress: a slot that answers with a Snap_Begin and then only empty chunks (or Snap_Begins
// again) holds the report IMAGE_WAIT_MS after its answer, not for as long as it keeps sending them.
@(test)
empty_chunks_do_not_hold_the_desync_report :: proc(t: ^testing.T) {
	planted: Planted // the fault this test plants warns by design: counted here, not printed
	context.logger = planted_logger(&planted)
	session: Net
	evil: Evil
	defer net_destroy(&session)
	defer evil_destroy(&evil)
	honest, tick, ok := diverged_image_asked(t, &session, &evil)
	if !ok do return
	for k in 0 ..< 6 {
		writer := evil_begin(&evil, k % 3 == 0 ? .Snap_Begin : .Snap_Chunk)
		wire.w_u8(writer, netcode.RELAY_TARGET)
		if k % 3 == 0 {
			wire.w_u32(writer, tick)
			wire.w_u32(writer, 1 << 20)
		} else {
			wire.w_u32(writer, 0) // offset 0, no bytes
		}
		evil_send(&evil, &session)
		evil_run(&evil, &session, 1)
	}
	testing.expect_value(t, session.relay.desyncs, 1)
	testing.expectf(t, honest.stats.desyncs > 0, "6 s after the answer the honest client was told of no desync")
	testing.expect_value(t, session.relay.first_desync.detail, "the snapshots of that tick were not available")
	testing.expectf(t, planted.warnings > 0, "the planted fault warned of nothing")
}

// The wait has an end: a slot that sends its image a byte at a time (each one progress) holds the report for
// IMAGE_GIVE_UP_MS at most.
@(test)
a_dripping_image_holds_the_desync_report_until_the_wait_gives_up :: proc(t: ^testing.T) {
	planted: Planted // the fault this test plants warns by design: counted here, not printed
	context.logger = planted_logger(&planted)
	session: Net
	evil: Evil
	defer net_destroy(&session)
	defer evil_destroy(&evil)
	honest, tick, ok := diverged_image_asked(t, &session, &evil)
	if !ok do return
	asked := session.relay.pending_from
	writer := evil_begin(&evil, .Snap_Begin)
	wire.w_u8(writer, netcode.RELAY_TARGET)
	wire.w_u32(writer, tick)
	wire.w_u32(writer, 1 << 20)
	evil_send(&evil, &session)
	for offset: u32 = 0; honest.stats.desyncs == 0 && offset < 60; offset += 1 {
		writer = evil_begin(&evil, .Snap_Chunk)
		wire.w_u8(writer, netcode.RELAY_TARGET)
		wire.w_u32(writer, offset)
		wire.w_u8(writer, 0) // one byte
		evil_send(&evil, &session)
		evil_run(&evil, &session, 1)
	}
	waited_ms := (session.clock.now - asked) / 1000
	testing.expectf(t, honest.stats.desyncs > 0, "the honest client was never told of the desync")
	testing.expectf(
		t,
		waited_ms >= netcode.IMAGE_GIVE_UP_MS - 2000 && waited_ms <= netcode.IMAGE_GIVE_UP_MS + 2000,
		"told %d ms after the relay asked for the images (gives up after %d)",
		waited_ms,
		netcode.IMAGE_GIVE_UP_MS,
	)
	testing.expectf(t, planted.warnings > 0, "the planted fault warned of nothing")
}
