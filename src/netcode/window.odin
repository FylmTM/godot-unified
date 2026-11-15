// The finalized ticks of a relay packet (#192): each tick as its changes from the tick before it in the same
// packet, the first from the empty tick (nobody present, zero inputs, no commands). A packet decodes on its own, so
// losing one costs what it did before: the next packet repeats the ticks the client hasn't acked. Per tick:
//
//   flags u8 (Window_Flags)
//   .Presence: present u32, replaced u32
//   .Inputs:   the players whose input changed (a bit per player, ceil(PLAYERS / 8) bytes), then per such player,
//              in order, the bytes of its input that changed (a bit per byte, ceil(size_of(Input) / 8) bytes) and
//              their new values
//   .Commands: the tick's commands (sim.write_commands); without the flag the tick has none
//   .Joins:    the tick's join records (sim.write_joins); without the flag it has none (they are per tick, never
//              carried over from the tick before)
//
// A tick like the one before it, without commands, is one byte. The input log keeps sim.write_tick's format.
package netcode

import "unified:sim"
import "unified:wire"

Window_Flag :: enum u8 {
	Presence, // present and replaced differ from the tick before
	Inputs, // some player's input bytes differ from the tick before
	Commands, // the tick has commands
	Joins, // the tick has join records
}
Window_Flags :: bit_set[Window_Flag;u8]

// The most bytes window_write_tick writes for a tick with `commands`: every field changed, every slot joining.
window_tick_max_bytes :: proc($Input: typeid, $PLAYERS: int, commands: []sim.Raw_Command) -> int {
	size := 1 + 8 + mask_bytes(PLAYERS) + PLAYERS * (mask_bytes(size_of(Input)) + size_of(Input))
	size += 1 + PLAYERS * sim.JOIN_BYTES
	if len(commands) > 0 {
		size += 1
		for &command in commands {
			size += sim.COMMAND_HEAD + int(command.size)
		}
	}
	return size
}

// Writes `tick` as its changes from `base`, the tick before it in the packet (nil: the empty tick).
window_write_tick :: proc(
	writer: ^wire.Writer,
	tick: ^sim.Inputs($Input, $PLAYERS),
	base: ^sim.Inputs(Input, PLAYERS),
) {
	zero: Input
	base_present, base_replaced: sim.Players
	if base != nil {
		base_present, base_replaced = base.present, base.replaced
	}
	flags: Window_Flags
	if tick.present != base_present || tick.replaced != base_replaced {
		flags += {.Presence}
	}
	changed: sim.Players
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
	if sim.join_count(tick.member[:]) > 0 {
		flags += {.Joins}
	}
	wire.w_u8(writer, transmute(u8)flags)
	if .Presence in flags {
		wire.w_u32(writer, transmute(u32)tick.present)
		wire.w_u32(writer, transmute(u32)tick.replaced)
	}
	if .Inputs in flags {
		players := transmute(u32)changed
		for i in 0 ..< mask_bytes(PLAYERS) {
			wire.w_u8(writer, u8(players >> uint(8 * i)))
		}
		for player in changed {
			before := base != nil ? input_bytes(&base.input[player]) : input_bytes(&zero)
			after := input_bytes(&tick.input[player])
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
	}
	if .Commands in flags {
		sim.write_commands(writer, tick.commands[:tick.command_count])
	}
	if .Joins in flags {
		sim.write_joins(writer, tick.member[:])
	}
}

// Reads the next tick of a packet into `tick`, which holds the tick before it (zeroed for the first): its changes
// are applied in place. False when it is malformed: unknown flags, a player past PLAYERS or a byte past the input's
// size, bad commands (sim.read_commands) or join records (sim.read_joins), or cut short; the ticks after it can't be found.
window_read_tick :: proc(reader: ^wire.Reader, tick: ^sim.Inputs($Input, $PLAYERS)) -> bool {
	KNOWN :: Window_Flags{.Presence, .Inputs, .Commands, .Joins}
	flags := transmute(Window_Flags)wire.r_u8(reader)
	if !reader.ok || flags - KNOWN != {} {
		return false
	}
	if .Presence in flags {
		tick.present = transmute(sim.Players)wire.r_u32(reader)
		tick.replaced = transmute(sim.Players)wire.r_u32(reader)
	}
	if .Inputs in flags {
		players: u64
		for i in 0 ..< mask_bytes(PLAYERS) {
			players |= u64(wire.r_u8(reader)) << uint(8 * i)
		}
		if !reader.ok || players >> uint(PLAYERS) != 0 {
			return false
		}
		for player in 0 ..< PLAYERS {
			if players & (1 << uint(player)) == 0 {
				continue
			}
			mask := wire.r_bytes(reader, mask_bytes(size_of(Input)))
			if mask == nil {
				return false
			}
			for i in size_of(Input) ..< 8 * len(mask) {
				if mask[i / 8] & (1 << uint(i % 8)) != 0 {
					return false
				}
			}
			after := input_bytes(&tick.input[player])
			for i in 0 ..< size_of(Input) {
				if mask[i / 8] & (1 << uint(i % 8)) != 0 {
					after[i] = wire.r_u8(reader)
				}
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
	tick.member = {}
	if .Joins in flags && !sim.read_joins(reader, tick.present, tick.member[:]) {
		return false
	}
	return reader.ok
}

@(private)
mask_bytes :: #force_inline proc(bits: int) -> int {
	return (bits + 7) / 8
}

@(private)
input_bytes :: #force_inline proc(input: ^$Input) -> []u8 {
	return ([^]u8)(input)[:size_of(Input)]
}
