// The relay packet's finalized-tick window (window.odin, #192): each tick as its changes from the one before.
package test_netcode

import "core:testing"

import "../toy"
import "unified:netcode"
import "unified:sim"
import "unified:wire"

// Writes `ticks` as one packet's window and reads them back; every tick must come back as it was written, with
// nothing left over.
@(private = "file")
expect_round_trip :: proc(t: ^testing.T, ticks: []toy.Inputs, loc := #caller_location) -> (bytes: int) {
	writer := wire.writer_make(netcode.MAX_DATAGRAM)
	defer delete(writer.buf)
	for &tick_inputs, i in ticks {
		netcode.window_write_tick(&writer, &tick_inputs, i > 0 ? &ticks[i - 1] : nil)
	}
	reader := wire.reader_make(writer.buf[:])
	back: toy.Inputs
	for &tick_inputs, i in ticks {
		ok := netcode.window_read_tick(&reader, &back)
		testing.expectf(t, ok, "tick %d of %d does not read", i, len(ticks), loc = loc)
		testing.expectf(
			t,
			ok && sim.inputs_same(&back, &tick_inputs) && back.replaced == tick_inputs.replaced,
			"tick %d of %d differs",
			i,
			len(ticks),
			loc = loc,
		)
	}
	testing.expect_value(t, wire.r_remaining(&reader), 0, loc = loc)
	return len(writer.buf)
}

// A session's worth of ticks: players joining and leaving, replaced inputs, inputs held for a while and changed
// byte by byte, commands now and then.
@(private = "file")
varied_ticks :: proc(ticks: []toy.Inputs) {
	state := u32(0x9E37_79B9)
	for &tick_inputs, i in ticks {
		if i > 0 {
			tick_inputs = ticks[i - 1]
			tick_inputs.command_count = 0
		}
		state ~= state << 13
		state ~= state >> 17
		state ~= state << 5
		switch i % 11 {
		case 0:
			tick_inputs.present ~= {int(state % toy.PLAYERS)}
		case 3:
			tick_inputs.replaced = state % 2 == 0 ? {} : tick_inputs.present
		case 5:
			bump, _ := sim.command_make(toy.Cmd, toy.Cmd_Bump{i32(i)})
			bump.player = u8(state % toy.PLAYERS)
			sim.add_command(&tick_inputs, bump)
		}
		if i % 3 != 0 {
			player := int(state >> 8) % toy.PLAYERS
			tick_inputs.input[player].dx = i8(state >> 16)
			if i % 2 == 0 {
				tick_inputs.input[player].buttons = u8(state >> 24)
			}
		}
	}
}

@(test)
window_round_trips :: proc(t: ^testing.T) {
	ticks: [netcode.WINDOW_MAX]toy.Inputs
	varied_ticks(ticks[:])
	expect_round_trip(t, ticks[:0])
	expect_round_trip(t, ticks[:1])
	expect_round_trip(t, ticks[7:8]) // a first tick that isn't the session's first
	expect_round_trip(t, ticks[:])
	expect_round_trip(t, ticks[9:])
}

// An unchanged tick is one byte; the first tick costs only what differs from the empty tick (absent seats' zero
// inputs are free); a tick that changed everything stays within window_tick_max_bytes.
@(test)
window_sizes :: proc(t: ^testing.T) {
	ticks: [3]toy.Inputs
	ticks[0].present = {0, 1}
	ticks[0].input[0] = {
		dx = 5,
		dy = -3,
	}
	ticks[1] = ticks[0]
	ticks[2] = ticks[0]
	ticks[2].input[1].buttons = 1
	// 1 flag + 8 presence + 1 player mask + (1 byte mask + 2 bytes) for player 0
	testing.expect_value(t, expect_round_trip(t, ticks[:1]), 13)
	testing.expect_value(t, expect_round_trip(t, ticks[:2]), 13 + 1)
	// 1 flag + 1 player mask + (1 byte mask + 1 byte) for player 1
	testing.expect_value(t, expect_round_trip(t, ticks[:3]), 13 + 1 + 4)

	// Everything changed: presence, every byte of every input, commands.
	full: [2]toy.Inputs
	full[1].present = {0, 1, 2, 3}
	full[1].replaced = {2}
	for &input in full[1].input {
		input = {
			dx      = 1,
			dy      = 2,
			buttons = 3,
			_pad    = 4,
		}
	}
	for player in 0 ..< toy.PLAYERS {
		bump, _ := sim.command_make(toy.Cmd, toy.Cmd_Bump{7})
		bump.player = u8(player)
		sim.add_command(&full[1], bump)
	}
	commands := full[1].commands[:full[1].command_count]
	testing.expect_value(
		t,
		expect_round_trip(t, full[:]) - 1, // the first tick, unchanged from the empty one
		netcode.window_tick_max_bytes(toy.Input, toy.PLAYERS, commands),
	)
}

// Malformed ticks are refused, never read past: unknown flags, a player past PLAYERS, a byte past the input's
// size, bad commands, and every cut-short prefix of a valid window.
@(test)
window_refuses_malformed :: proc(t: ^testing.T) {
	expect_refused :: proc(t: ^testing.T, bytes: []u8, what: string, loc := #caller_location) {
		reader := wire.reader_make(bytes)
		back: toy.Inputs
		testing.expectf(t, !netcode.window_read_tick(&reader, &back), "%s: read", what, loc = loc)
	}
	expect_refused(t, {0x08}, "an unknown flag")
	expect_refused(t, {0x80}, "an unknown flag")
	expect_refused(t, {0x02, 0x10, 0x01, 7}, "player 4 of 4") // .Inputs, players {4}
	expect_refused(t, {0x02, 0x01, 0x10, 7}, "byte 4 of a 4-byte input") // .Inputs, players {0}, bytes {4}
	expect_refused(t, {0x04, 17}, "17 commands")
	expect_refused(t, {0x04, 1, 4, 0, 4, 1, 2, 3, 4}, "a command of player 4")

	ticks: [12]toy.Inputs
	varied_ticks(ticks[:])
	writer := wire.writer_make(netcode.MAX_DATAGRAM)
	defer delete(writer.buf)
	for &tick_inputs, i in ticks {
		netcode.window_write_tick(&writer, &tick_inputs, i > 0 ? &ticks[i - 1] : nil)
	}
	for cut in 0 ..< len(writer.buf) {
		reader := wire.reader_make(writer.buf[:cut])
		back: toy.Inputs
		read := 0
		for read < len(ticks) && netcode.window_read_tick(&reader, &back) {
			read += 1
		}
		testing.expectf(t, read < len(ticks), "a window cut to %d of %d bytes read whole", cut, len(writer.buf))
	}
}
