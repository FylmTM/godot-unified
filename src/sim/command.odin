// Commands (src/sim/README.md, Commands): one-shot actions a player sends, delivered exactly once, in order.
// The game declares one plain struct per command and a union of them (sim.Game's Command; kind = variant
// index). A command is input, not state: part of the tick's input record (Inputs.commands; logged,
// replayed, sent to late joiners with the log), never in the block. `tick` reads them with `commands`.
package sim

import "base:builtin"
import "base:intrinsics"
import "base:runtime"
import "core:strings"

COMMAND_MAX :: 64 // bytes of one command's struct
COMMANDS_PER_SLOT :: 4 // per slot per tick: more wait for the next tick, in order
TICK_COMMANDS :: 16 // per tick, every player together (a tick's commands also fit one datagram)

// One command in a tick's input record: its kind (the variant's index in the Command union), the slot it
// was sent from and its struct's bytes.
Raw_Command :: struct {
	kind: u8,
	slot: u8,
	size: u8, // bytes used in `data` (the struct's size)
	data: [COMMAND_MAX]u8,
}

// The commands sent from `slot` for this tick, in the order sent (inside `tick`, by player: sim.commands(t,
// player), players.odin).
slot_commands :: proc(inputs: ^Inputs($G), slot: int) -> []Raw_Command {
	count := inputs.command_count
	low := 0
	for low < count && int(inputs.commands[low].slot) < slot {
		low += 1
	}
	high := low
	for high < count && int(inputs.commands[high].slot) == slot {
		high += 1
	}
	return inputs.commands[low:high]
}

// The command as the game's union (nil: a kind out of range or the wrong size). Inside `tick`, sim.commands gives
// them decoded.
command_value :: proc(raw: ^Raw_Command, $Command: typeid) -> Command {
	return union_value(int(raw.kind), raw.data[:raw.size], Command)
}

// A tick's commands, decoded once before `tick` (Tick.commands), each with its slot, in the record's order.
@(private)
Commands :: struct($Command: typeid) {
	list:  [TICK_COMMANDS]Command,
	slots: [TICK_COMMANDS]u8,
	count: int,
}

// The prefix of a dev command's type name: a variant `Command_Dev_<Name>` of the game's Command union is a dev command, an
// ordinary command everywhere (sent, relayed, logged, replayed) that a build without the dev UI never applies
// (commands_decode) and the dev UI offers as a form.
DEV_COMMAND_PREFIX :: "Command_Dev_"

// Whether a command is a dev command (its type is named Command_Dev_*): by its type (`sim.command_is_dev(Command_Dev_Spawn)`),
// or by its variant index in a command union known at run time.
command_is_dev :: proc {
	command_is_dev_type,
	command_is_dev_kind,
}

// command_is_dev of a command type (a variant of the game's union).
command_is_dev_type :: proc($C: typeid) -> bool {
	named, is_named := type_info_of(C).variant.(runtime.Type_Info_Named)
	return is_named && strings.has_prefix(named.name, DEV_COMMAND_PREFIX)
}

// command_is_dev of variant `kind` of the command union `commands`.
command_is_dev_kind :: proc(commands: typeid, kind: int) -> bool {
	variants := union_variants(commands)
	if kind < 0 || kind >= len(variants) do return false
	named, is_named := variants[kind].variant.(runtime.Type_Info_Named)
	return is_named && strings.has_prefix(named.name, DEV_COMMAND_PREFIX)
}

// Whether a command union has a dev command.
has_dev_commands :: proc(commands: typeid) -> bool {
	for _, kind in union_variants(commands) do if command_is_dev(commands, kind) do return true
	return false
}

// Decodes the record's commands, leaving out any whose bytes don't decode (an unknown kind, a wrong size), and the dev
// commands unless `dev` (a build without the dev UI never applies one, whoever sends it).
@(private)
commands_decode :: proc(commands: ^Commands($Command), inputs: ^Inputs($G), dev := DEV) {
	commands.count = 0
	when intrinsics.type_union_variant_count(Command) > 0 { 	// sim.No_Commands: nothing to decode
		for &raw in inputs.commands[:inputs.command_count] {
			if !dev && command_is_dev(Command, int(raw.kind)) do continue
			value := command_value(&raw, Command)
			if value == nil do continue
			commands.list[commands.count] = value
			commands.slots[commands.count] = raw.slot
			commands.count += 1
		}
	}
}

// The decoded commands of `slot`: slot_commands' scan over the decoded list, which commands_decode may leave shorter
// than the raw one (an undecodable or dev command), so the raw list's range can't index it.
@(private)
commands_of_slot :: proc(commands: ^Commands($Command), slot: int) -> []Command {
	low := 0
	for low < commands.count && int(commands.slots[low]) < slot {
		low += 1
	}
	high := low
	for high < commands.count && int(commands.slots[high]) == slot {
		high += 1
	}
	return commands.list[low:high]
}

// A raw command of kind `kind` from its struct's bytes (false: an unknown kind or the wrong size).
command_from_bytes :: proc(commands: typeid, kind: int, bytes: []u8) -> (raw: Raw_Command, ok: bool) {
	variants := union_variants(commands)
	if kind < 0 || kind >= len(variants) || len(bytes) != variants[kind].size {
		return
	}
	raw.kind = u8(kind)
	raw.size = u8(len(bytes))
	copy(raw.data[:], bytes)
	return raw, true
}

// A raw command from a value of one of the game's command structs (tests and tools):
// `sim.command_make(Command, Command_Set_Map{map_index = 2})`. A value that is not a variant of Command does not compile.
command_make :: proc($Command: typeid, value: $T) -> Raw_Command where intrinsics.type_is_variant_of(Command, T) {
	value := value
	raw, _ := command_from_bytes(Command, variant_kind(Command, T), ([^]u8)(&value)[:size_of(T)])
	return raw
}

// Adds a command to a tick's record (tests, tools, bots): a value of one of the game's command structs sent from `slot`
// (`sim.add_command(&inputs, 2, Command_Pick{upgrade})`: another value does not compile), a value of the game's Command union
// (whichever command it holds; nil: none, false), or a raw command from its own slot. It goes after the commands that
// slot already has there. False at the limits (COMMANDS_PER_SLOT for the slot, TICK_COMMANDS in all).
add_command :: proc {
	add_command_value,
	add_command_union,
	add_raw_command,
}

add_command_value :: proc(
	inputs: ^Inputs($G),
	slot: int,
	value: $T,
) -> bool where intrinsics.type_is_variant_of(part(G, GAME_COMMAND), T) {
	if slot < 0 || slot >= part(G, GAME_PLAYERS) do return false
	raw := command_make(part(G, GAME_COMMAND), value)
	raw.slot = u8(slot)
	return add_raw_command(inputs, raw)
}

// The union itself only: a struct value goes to add_command_value.
add_command_union :: proc(
	inputs: ^Inputs($G),
	slot: int,
	command: $Command,
) -> bool where Command ==
	part(G, GAME_COMMAND) {
	command := command
	kind := union_kind(&command)
	if kind < 0 || slot < 0 || slot >= part(G, GAME_PLAYERS) do return false
	raw, _ := command_from_bytes(Command, kind, ([^]u8)(&command)[:union_variants(Command)[kind].size])
	raw.slot = u8(slot)
	return add_raw_command(inputs, raw)
}

add_raw_command :: proc(inputs: ^Inputs($G), raw: Raw_Command) -> bool {
	PLAYERS :: part(G, GAME_PLAYERS)
	count := inputs.command_count
	if count >= TICK_COMMANDS ||
	   int(raw.slot) >= PLAYERS ||
	   len(slot_commands(inputs, int(raw.slot))) >= COMMANDS_PER_SLOT {
		return false
	}
	at := count
	for at > 0 && inputs.commands[at - 1].slot > raw.slot {
		inputs.commands[at] = inputs.commands[at - 1]
		at -= 1
	}
	inputs.commands[at] = raw
	inputs.command_count += 1
	return true
}

// Where a command source (a UI, a script, a bot) puts the commands it sends for one tick; Command is the game's union.
Command_Out :: struct($Command: typeid) {
	slot: int, // the sender's slot
	list: [dynamic]Raw_Command,
	cap:  int, // the most `list` may hold
}

// Sends a command (false: the out is full). A value that is not a variant of Command does not compile.
send_command :: proc(out: ^Command_Out($Command), value: $T) -> bool where intrinsics.type_is_variant_of(Command, T) {
	return push_command(out, command_make(Command, value))
}

// Sends a command made with command_make or command_from_bytes (false when the out is full).
push_command :: proc(out: ^Command_Out($Command), raw: Raw_Command) -> bool {
	if len(out.list) >= out.cap {
		return false
	}
	raw := raw
	raw.slot = u8(out.slot)
	builtin.append(&out.list, raw)
	return true
}
