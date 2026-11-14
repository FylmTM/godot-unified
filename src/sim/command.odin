// Commands (src/sim/SPEC.md "Commands"): one-shot actions a player sends, delivered exactly once, in order.
// The game declares one plain struct per command and a union of them (Game.commands; kind = variant
// index). A command is input, not state: part of the tick's input record (Inputs.commands; logged,
// replayed, sent to late joiners with the log), never in the block. `tick` reads them with `commands`
// and `command_value`.
package sim

COMMAND_MAX :: 64 // bytes of one command's struct
COMMANDS_PER_PLAYER :: 4 // per player per tick: more wait for the next tick, in order
TICK_COMMANDS :: 16 // per tick, every player together (a tick's commands also fit one datagram)

// One command in a tick's input record: its kind (the variant's index in Game.commands), the player
// who sent it and its struct's bytes.
Raw_Command :: struct {
	kind:   u8,
	player: u8,
	size:   u8, // bytes used in `data` (the struct's size)
	data:   [COMMAND_MAX]u8,
}

// The commands `player` sent for this tick, in the order sent. Read inside `tick`:
//
//   for &raw in sim.commands(tick.inputs, player) {
//       switch command in sim.command_value(&raw, Command) {
//       case Cmd_Set_Map: ...
//       }
//   }
commands :: proc(inputs: ^Inputs($Input, $PLAYERS), player: int) -> []Raw_Command {
	count := inputs.command_count
	low := 0
	for low < count && int(inputs.commands[low].player) < player {
		low += 1
	}
	high := low
	for high < count && int(inputs.commands[high].player) == player {
		high += 1
	}
	return inputs.commands[low:high]
}

// The command as the game's union (nil: a kind out of range or the wrong size).
command_value :: proc(raw: ^Raw_Command, $Command: typeid) -> Command {
	return union_value(int(raw.kind), raw.data[:raw.size], Command)
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
// `sim.command_make(Command, Cmd_Set_Map{map_index = 2})`.
command_make :: proc(commands: typeid, value: $T) -> (raw: Raw_Command, ok: bool) {
	value := value
	return command_from_bytes(commands, variant_kind(commands, T), ([^]u8)(&value)[:size_of(T)])
}

// Adds a command to a tick's record, after the commands `raw.player` already has there. False at the
// limits (COMMANDS_PER_PLAYER for the player, TICK_COMMANDS in all).
add_command :: proc(inputs: ^Inputs($Input, $PLAYERS), raw: Raw_Command) -> bool {
	count := inputs.command_count
	if count >= TICK_COMMANDS ||
	   int(raw.player) >= PLAYERS ||
	   len(commands(inputs, int(raw.player))) >= COMMANDS_PER_PLAYER {
		return false
	}
	at := count
	for at > 0 && inputs.commands[at - 1].player > raw.player {
		inputs.commands[at] = inputs.commands[at - 1]
		at -= 1
	}
	inputs.commands[at] = raw
	inputs.command_count += 1
	return true
}

// Where a command source (a UI, a script, a bot) puts the commands it sends for one tick.
Command_Out :: struct {
	commands: typeid, // the game's command union
	player:   int, // the sender
	list:     [dynamic]Raw_Command,
	cap:      int, // the most `list` may hold
}

// Sends a command; false when T is not one of the game's command structs or the out is full.
send_command :: proc(out: ^Command_Out, value: $T) -> bool {
	raw, ok := command_make(out.commands, value)
	return ok && push_command(out, raw)
}

// Sends a command made with command_make or command_from_bytes (false when the out is full).
push_command :: proc(out: ^Command_Out, raw: Raw_Command) -> bool {
	if len(out.list) >= out.cap {
		return false
	}
	raw := raw
	raw.player = u8(out.player)
	append(&out.list, raw)
	return true
}
