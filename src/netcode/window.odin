// The finalized ticks of a relay packet: each tick as its changes from the tick before it in the same
// packet, the first from the empty tick (nobody present, zero inputs, no commands). A packet decodes on its own, so
// losing one costs what it did before: the next packet repeats the ticks the client hasn't acked. Per tick:
//
//   flags u8 (Window_Flags)
//   .Presence: present, then replaced, each a bit per slot (ceil(PLAYERS / 8) bytes)
//   .Inputs:   the players whose input changed (a bit per player, ceil(PLAYERS / 8) bytes), then per such player,
//              in order, its input as window_write_input writes it: the bytes that changed (a bit per byte,
//              ceil(size_of(Input) / 8) bytes) and their new values
//   .Commands: the tick's commands (sim.write_commands); without the flag the tick has none
//   .Joins:    the tick's join records with their Profiles (sim.write_joins); without the flag it has none (they are
//              per tick, never carried over from the tick before; the relay seats one new player per tick)
//
// A tick like the one before it, without commands, is one byte. The input log keeps sim.write_tick's format. A
// client's Inputs packet writes its own unacked inputs the same way, each from the one before it.
package netcode

import "unified:sim"
import "unified:wire"

// A part of a window tick that follows its flags byte (the layout: this file's header).
Window_Flag :: enum u8 {
	Presence, // present and replaced differ from the tick before
	Inputs, // some player's input bytes differ from the tick before
	Commands, // the tick has commands
	Joins, // the tick has join records
}
// A window tick's first byte: which of its parts follow.
Window_Flags :: bit_set[Window_Flag;u8]

// The most bytes window_write_tick writes for a relay's tick with `commands`: every field changed, a player joining with
// a Profile of `profile_size` bytes (the relay seats one new player per tick: src/netcode/README.md, Relay).
window_tick_max_bytes :: proc($Input: typeid, $PLAYERS: int, commands: []sim.Raw_Command, profile_size := 0) -> int {
	size := 1 + 3 * mask_bytes(PLAYERS) + PLAYERS * window_input_max_bytes(Input)
	size += 1 + sim.JOIN_BYTES + profile_size
	if len(commands) > 0 {
		size += 1
		for &command in commands {
			size += sim.COMMAND_HEAD + int(command.size)
		}
	}
	return size
}

// Writes `tick` as its changes from `base`, the tick before it in the packet (nil: the empty tick).
window_write_tick :: proc(writer: ^wire.Writer, tick: ^sim.Inputs($G), base: ^sim.Inputs(G)) {
	Input :: sim.part(G, sim.GAME_INPUT)
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	zero: Input
	base_present, base_replaced: sim.Slots
	if base != nil {
		base_present, base_replaced = base.present, base.replaced
	}
	flags: Window_Flags
	if tick.present != base_present || tick.replaced != base_replaced {
		flags += {.Presence}
	}
	changed: sim.Slots
	for player in 0 ..< PLAYERS {
		before := base != nil ? input_bytes(&base.input[player]) : input_bytes(&zero)
		if string(before) != string(input_bytes(&tick.input[player])) {
			changed += {player}
		}
	}
	if changed != {} {
		flags += {.Inputs}
	}
	if tick.command_count > 0 {
		flags += {.Commands}
	}
	if sim.join_count(tick.joins[:]) > 0 {
		flags += {.Joins}
	}
	wire.w_u8(writer, transmute(u8)flags)
	if .Presence in flags {
		write_slots(writer, tick.present, PLAYERS)
		write_slots(writer, tick.replaced, PLAYERS)
	}
	if .Inputs in flags {
		write_slots(writer, changed, PLAYERS)
		for player in changed {
			window_write_input(writer, &tick.input[player], base != nil ? &base.input[player] : &zero)
		}
	}
	if .Commands in flags {
		sim.write_commands(writer, tick.commands[:tick.command_count])
	}
	if .Joins in flags {
		sim.write_joins(writer, tick.joins[:], ([^]u8)(&tick.profiles)[:size_of(tick.profiles)])
	}
}

// Reads the next tick of a packet into `tick`, which holds the tick before it (zeroed for the first): its changes
// are applied in place. False when it is malformed: unknown flags, a slot past PLAYERS (present, replaced or an
// input) or a byte past the input's size, bad commands (sim.read_commands) or join records (sim.read_joins), or cut
// short; the ticks after it can't be found.
window_read_tick :: proc(reader: ^wire.Reader, tick: ^sim.Inputs($G)) -> bool {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	KNOWN :: Window_Flags{.Presence, .Inputs, .Commands, .Joins}
	flags := transmute(Window_Flags)wire.r_u8(reader)
	if !reader.ok || flags - KNOWN != {} {
		return false
	}
	if .Presence in flags {
		present, present_ok := read_slots(reader, PLAYERS)
		replaced, replaced_ok := read_slots(reader, PLAYERS)
		if !present_ok || !replaced_ok {
			return false
		}
		tick.present, tick.replaced = present, replaced
	}
	if .Inputs in flags {
		changed, changed_ok := read_slots(reader, PLAYERS)
		if !changed_ok {
			return false
		}
		for slot in changed {
			if !window_read_input(reader, &tick.input[slot]) {
				return false
			}
		}
	}
	tick.command_count = 0
	if .Commands in flags {
		count, ok := sim.read_commands(reader, PLAYERS, &tick.commands)
		if !ok {
			return false
		}
		tick.command_count = count
	}
	tick.joins = {}
	tick.profiles = {}
	profiles := ([^]u8)(&tick.profiles)[:size_of(tick.profiles)]
	if .Joins in flags && !sim.read_joins(reader, tick.present, tick.joins[:], profiles) {
		return false
	}
	return reader.ok
}

// Writes `input` as its changes from `base`: a bit per byte (ceil(size_of(Input) / 8) bytes), then the bytes that
// changed, in order. An input like its base is the mask alone.
window_write_input :: proc(writer: ^wire.Writer, input, base: ^$Input) {
	before, after := input_bytes(base), input_bytes(input)
	mask_at := len(writer.buf)
	for _ in 0 ..< mask_bytes(size_of(Input)) {
		wire.w_u8(writer, 0)
	}
	for i in 0 ..< size_of(Input) {
		if before[i] != after[i] {
			writer.buf[mask_at + i / 8] |= 1 << uint(i % 8)
			wire.w_u8(writer, after[i])
		}
	}
}

// The most bytes window_write_input writes for one input: every byte changed.
@(private)
window_input_max_bytes :: proc($Input: typeid) -> int {
	return mask_bytes(size_of(Input)) + size_of(Input)
}

// Reads the next input's changes into `input`, which holds its base (the input before it): false when malformed (a
// bit past the input's size, or cut short).
window_read_input :: proc(reader: ^wire.Reader, input: ^$Input) -> bool {
	mask := wire.r_bytes(reader, mask_bytes(size_of(Input)))
	if mask == nil {
		return false
	}
	for i in size_of(Input) ..< 8 * len(mask) {
		if mask[i / 8] & (1 << uint(i % 8)) != 0 {
			return false
		}
	}
	after := input_bytes(input)
	for i in 0 ..< size_of(Input) {
		if mask[i / 8] & (1 << uint(i % 8)) != 0 {
			after[i] = wire.r_u8(reader)
		}
	}
	return reader.ok
}

// A set of slots as a bit per slot, ceil(players / 8) bytes.
@(private)
write_slots :: proc(writer: ^wire.Writer, slots: sim.Slots, players: int) {
	bits := transmute(u32)slots
	for i in 0 ..< mask_bytes(players) {
		wire.w_u8(writer, u8(bits >> uint(8 * i)))
	}
}

// A set of slots write_slots wrote: false when cut short or naming a slot past `players`.
@(private)
read_slots :: proc(reader: ^wire.Reader, players: int) -> (slots: sim.Slots, ok: bool) {
	bits: u64
	for i in 0 ..< mask_bytes(players) {
		bits |= u64(wire.r_u8(reader)) << uint(8 * i)
	}
	if !reader.ok || bits >> uint(players) != 0 {
		return
	}
	return transmute(sim.Slots)u32(bits), true
}

@(private)
mask_bytes :: #force_inline proc(bits: int) -> int {
	return (bits + 7) / 8
}

@(private)
input_bytes :: #force_inline proc(input: ^$Input) -> []u8 {
	return ([^]u8)(input)[:size_of(Input)]
}
