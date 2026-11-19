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

// A session's worth of ticks: players joining (with join records) and leaving, replaced inputs, inputs held for a while and changed
// byte by byte, commands now and then.
@(private = "file")
varied_ticks :: proc(ticks: []toy.Inputs) {
	state := u32(0x9E37_79B9)
	for &tick_inputs, i in ticks {
		if i > 0 {
			tick_inputs = ticks[i - 1]
			tick_inputs.command_count = 0
			tick_inputs.joins = {} // join records are per tick
		}
		state ~= state << 13
		state ~= state >> 17
		state ~= state << 5
		switch i % 11 {
		case 0:
			slot := int(state % toy.PLAYERS)
			tick_inputs.present ~= {slot}
			if slot in tick_inputs.present do tick_inputs.joins[slot] = u16(i + 1) // a join record
		case 3:
			tick_inputs.replaced = state % 2 == 0 ? {} : tick_inputs.present
		case 5:
			bump := sim.command_make(toy.Cmd, toy.Cmd_Bump{i32(i)})
			bump.slot = u8(state % toy.PLAYERS)
			sim.add_command(&tick_inputs, bump)
		}
		if i % 3 != 0 {
			player := int(state >> 8) % toy.PLAYERS
			tick_inputs.input[player].dx = i8(state >> 16)
			if i % 2 == 0 {
				tick_inputs.input[player].buttons = transmute(toy.Buttons)u8(state >> 24) // any bits: the window copies bytes
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
	ticks[2].input[1].buttons = {.Spawn}
	// 1 flag + 2 presence (a bit per slot, present and replaced) + 1 slot mask + (1 byte mask + 2 bytes) for slot 0
	testing.expect_value(t, expect_round_trip(t, ticks[:1]), 7)
	testing.expect_value(t, expect_round_trip(t, ticks[:2]), 7 + 1)
	// 1 flag + 1 slot mask + (1 byte mask + 1 byte) for slot 1
	testing.expect_value(t, expect_round_trip(t, ticks[:3]), 7 + 1 + 4)

	// Everything changed: presence, every byte of every input, commands, a player joining (the relay seats one new
	// player per tick).
	full: [2]toy.Inputs
	full[1].present = {0, 1, 2, 3}
	full[1].joins = {0, 0, 3, 0}
	full[1].profiles[2] = {
		color = 9,
	}
	full[1].replaced = {2}
	for &input in full[1].input {
		input = {
			dx      = 1,
			dy      = 2,
			buttons = transmute(toy.Buttons)u8(3),
			_pad    = 4,
		}
	}
	for player in 0 ..< toy.PLAYERS {
		bump := sim.command_make(toy.Cmd, toy.Cmd_Bump{7})
		bump.slot = u8(player)
		sim.add_command(&full[1], bump)
	}
	commands := full[1].commands[:full[1].command_count]
	testing.expect_value(
		t,
		expect_round_trip(t, full[:]) - 1, // the first tick, unchanged from the empty one
		netcode.window_tick_max_bytes(toy.Input, toy.PLAYERS, commands, size_of(toy.Profile)),
	)
}

// Malformed ticks are refused, never read past: unknown flags, a slot past PLAYERS, a byte past the input's
// size, bad commands, bad join records, and every cut-short prefix of a valid window.
@(test)
window_refuses_malformed :: proc(t: ^testing.T) {
	expect_refused :: proc(t: ^testing.T, bytes: []u8, what: string, loc := #caller_location) {
		reader := wire.reader_make(bytes)
		back: toy.Inputs
		testing.expectf(t, !netcode.window_read_tick(&reader, &back), "%s: read", what, loc = loc)
	}
	expect_refused(t, {0x10}, "an unknown flag")
	expect_refused(t, {0x80}, "an unknown flag")
	expect_refused(t, {0x01, 0x10, 0}, "slot 4 of 4 present") // .Presence {4}
	expect_refused(t, {0x01, 0x01, 0x80}, "slot 7 of 4 replaced") // .Presence {0}, replaced {7}
	expect_refused(t, {0x02, 0x10, 0x01, 7}, "player 4 of 4") // .Inputs, players {4}
	expect_refused(t, {0x02, 0x01, 0x10, 7}, "byte 4 of a 4-byte input") // .Inputs, players {0}, bytes {4}
	expect_refused(t, {0x04, 17}, "17 commands")
	expect_refused(t, {0x04, 1, 4, 0, 4, 1, 2, 3, 4}, "a command of player 4")
	expect_refused(t, {0x08, 1, 0, 1, 0}, "a join record for a slot not present") // .Joins, slot 0, member 1
	expect_refused(t, {0x09, 1, 0, 1, 0, 0, 0}, "a join record of member 0") // .Presence {0}

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

// A client's own unacked inputs (#245): each as its changes from the one before, the first from the zero input. A
// held input is one byte (the mask); they read back as written; a bit past the input's size or a cut is refused.
@(test)
window_own_inputs :: proc(t: ^testing.T) {
	inputs: [20]toy.Input
	for &input, i in inputs {
		input = i > 0 ? inputs[i - 1] : {}
		if i % 6 == 1 do input.dx = i8(i)
		if i % 9 == 2 do input.buttons = {.Spawn}
	}
	writer := wire.writer_make(netcode.MAX_DATAGRAM)
	defer delete(writer.buf)
	base: toy.Input
	for &input in inputs {
		netcode.window_write_input(&writer, &input, &base)
		base = input
	}
	// 20 masks, plus dx at 1, 7, 13, 19 and buttons at 2, 11 (at 11 they were set already: only 2 changes them)
	testing.expect_value(t, len(writer.buf), 20 + 4 + 1)
	reader := wire.reader_make(writer.buf[:])
	back: toy.Input
	for &input, i in inputs {
		ok := netcode.window_read_input(&reader, &back)
		testing.expectf(t, ok && back == input, "input %d differs", i)
	}
	testing.expect_value(t, wire.r_remaining(&reader), 0)
	for cut in 0 ..< len(writer.buf) {
		cut_reader := wire.reader_make(writer.buf[:cut])
		cut_back: toy.Input
		read := 0
		for read < len(inputs) && netcode.window_read_input(&cut_reader, &cut_back) {
			read += 1
		}
		testing.expectf(t, read < len(inputs), "own inputs cut to %d of %d bytes read whole", cut, len(writer.buf))
	}
	past := wire.reader_make({0x10, 7}) // byte 4 of a 4-byte input
	testing.expect(t, !netcode.window_read_input(&past, &back))
}

@(private = "file")
Width_Input :: struct($B: int) {
	bytes: [B]u8,
}

@(private = "file")
Width_State :: struct($B: int, $PLAYERS: int) {
	players: sim.Players(struct {
			sum: u32,
		}, sim.No_Profile, Width_Input(B), PLAYERS),
}

@(private = "file")
Width_Event :: union {
	sim.Event_Player_Joined,
	sim.Event_Player_Left,
}

// netcode.game_violation of a game of PLAYERS players with a B-byte Input.
@(private = "file")
width_violation :: proc($PLAYERS: int, $B: int) -> string {
	G :: sim.Game(
		Width_State(B, PLAYERS),
		Width_Input(B),
		sim.No_World,
		Width_Event,
		sim.No_Commands,
		sim.No_Setup,
		sim.No_Profile,
		PLAYERS,
	)
	game := G {
		name = "width",
	}
	return netcode.game_violation(&game)
}

// The relay carries a game whose widest tick leaves TICKS_PER_MESSAGE_MIN of them per Finalized message (a tick of
// at most 267 bytes beside a full couch's acks, one player joining in it) and refuses one byte of Input wider, at each
// player count: 114 bytes at 2 players, 76 at 3, 56 at 4, 28 at 8, 14 at 16, 6 at 32.
@(test)
the_relay_refuses_a_tick_too_wide_for_its_stream :: proc(t: ^testing.T) {
	testing.expect_value(t, width_violation(2, 114), "")
	testing.expect(t, width_violation(2, 115) != "")
	testing.expect_value(t, width_violation(3, 76), "")
	testing.expect(t, width_violation(3, 77) != "")
	testing.expect_value(t, width_violation(4, 56), "")
	testing.expect(t, width_violation(4, 57) != "")
	testing.expect_value(t, width_violation(8, 28), "")
	testing.expect(t, width_violation(8, 29) != "")
	testing.expect_value(t, width_violation(16, 14), "")
	testing.expect(t, width_violation(16, 15) != "")
	testing.expect_value(t, width_violation(32, 6), "")
	testing.expect_value(
		t,
		width_violation(32, 7),
		"width: a tick of 32 players with 7-byte Inputs takes up to 273 bytes, so 3 fit a message and the relay needs 4: fewer players or a narrower Input",
	)
	testing.expect_value(t, netcode.game_violation(&toy.GAME), "")
}
