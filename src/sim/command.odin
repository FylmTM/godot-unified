// Commands (src/sim/SPEC.md "Commands"): one-shot actions a player sends, delivered exactly once, in order.
// A command is a typed plain struct the game declares in Game.commands (index = kind). It is input, not
// state: part of the tick's input record (Inputs.commands; logged, replayed, sent to late joiners with
// the log), never in the block. `tick` reads them with `commands` and `command_as`.
package sim

import "core:fmt"

COMMAND_MAX :: 64 // bytes of one command's struct
COMMANDS_PER_PLAYER :: 4 // per player per tick: more wait for the next tick, in order
TICK_COMMANDS :: 16 // per tick, every player together (a tick's commands also fit one datagram)

// A command type the game declares: `{"set_map", Cmd_Set_Map}`. Its index in Game.commands is its kind.
Command_Kind :: struct {
	name: string,
	id:   typeid,
}

// One command in a tick's input record.
Command :: struct {
	id:   typeid, // the command's type: the harness fills it in from Game.commands before `tick` (nil: unknown)
	kind: u8, // index into Game.commands
	slot: u8, // the player who sent it
	size: u8, // bytes used in `data` (the type's size)
	data: [COMMAND_MAX]u8,
}

// The commands `slot` sent for this tick, in the order sent. Read inside `tick`:
//
//   for &c in sim.commands(inputs, slot) {
//       if m, ok := sim.command_as(&c, Cmd_Set_Map); ok { ... }
//   }
commands :: proc(inputs: ^Inputs($I, $P), slot: int) -> []Command {
	n := int(inputs.n_commands)
	lo := 0
	for lo < n && int(inputs.commands[lo].slot) < slot {
		lo += 1
	}
	hi := lo
	for hi < n && int(inputs.commands[hi].slot) == slot {
		hi += 1
	}
	return inputs.commands[lo:hi]
}

// The command's value if it is a T (one of the game's command types).
command_as :: proc(c: ^Command, $T: typeid) -> (v: T, ok: bool) {
	if c.id != T || int(c.size) != size_of(T) {
		return
	}
	copy(([^]u8)(&v)[:size_of(T)], c.data[:size_of(T)])
	return v, true
}

// Why a game's command types can't be used ("" when they can): each must be plain data (sim.plain_violation),
// at most COMMAND_MAX bytes and declared once; at most 255 kinds.
commands_violation :: proc(kinds: []Command_Kind) -> string {
	if len(kinds) > 255 {
		return fmt.tprintf("%d command kinds (at most 255)", len(kinds))
	}
	for k, i in kinds {
		ti := type_info_of(k.id)
		if r := plain_violation(ti, fmt.tprint(k.id)); r != "" {
			return fmt.tprintf("command %q: %s", k.name, r)
		}
		if ti.size > COMMAND_MAX || ti.size == 0 {
			return fmt.tprintf("command %q: %d bytes (1..%d)", k.name, ti.size, COMMAND_MAX)
		}
		for j in 0 ..< i {
			if kinds[j].id == k.id || kinds[j].name == k.name {
				return fmt.tprintf("command %q is declared twice", k.name)
			}
		}
	}
	return ""
}

// The kind of a command type (-1: not one of `kinds`).
command_kind :: proc(kinds: []Command_Kind, id: typeid) -> int {
	for k, i in kinds {
		if k.id == id {
			return i
		}
	}
	return -1
}

// A command of kind `kind` from its struct's bytes (false: an unknown kind or the wrong size).
command_from_bytes :: proc(kinds: []Command_Kind, kind: int, bytes: []u8) -> (c: Command, ok: bool) {
	if kind < 0 || kind >= len(kinds) || len(bytes) != size_of_id(kinds[kind].id) {
		return
	}
	c.id = kinds[kind].id
	c.kind = u8(kind)
	c.size = u8(len(bytes))
	copy(c.data[:], bytes)
	return c, true
}

@(private)
size_of_id :: proc(id: typeid) -> int {
	return type_info_of(id).size
}

// A command from a value of one of the game's command types.
command_make :: proc(kinds: []Command_Kind, v: $T) -> (c: Command, ok: bool) {
	v := v
	return command_from_bytes(kinds, command_kind(kinds, T), ([^]u8)(&v)[:size_of(T)])
}

// Adds a command to a tick's record, after the commands `c.slot` already has there. False at the limits
// (COMMANDS_PER_PLAYER for the slot, TICK_COMMANDS in all).
add_command :: proc(inputs: ^Inputs($I, $P), c: Command) -> bool {
	n := int(inputs.n_commands)
	if n >= TICK_COMMANDS || int(c.slot) >= P || len(commands(inputs, int(c.slot))) >= COMMANDS_PER_PLAYER {
		return false
	}
	at := n
	for at > 0 && inputs.commands[at - 1].slot > c.slot {
		inputs.commands[at] = inputs.commands[at - 1]
		at -= 1
	}
	inputs.commands[at] = c
	inputs.n_commands += 1
	return true
}

// Fills in each command's type from the game's kinds (nil for an unknown kind or a wrong size, which
// command_as never matches). `advance` does this before every tick.
bind_commands :: proc(inputs: ^Inputs($I, $P), kinds: []Command_Kind) {
	for &c in inputs.commands[:inputs.n_commands] {
		c.id = nil
		if int(c.kind) < len(kinds) && int(c.size) == size_of_id(kinds[c.kind].id) {
			c.id = kinds[c.kind].id
		}
	}
}

// Where a command source (a UI, a script, a bot) puts the commands it sends for one tick.
Command_Out :: struct {
	kinds: []Command_Kind, // the game's
	slot:  int, // the sender
	list:  [dynamic]Command,
	cap:   int, // the most `list` may hold
}

// Sends a command; false when T is not one of the game's command types or the out is full.
send_command :: proc(out: ^Command_Out, v: $T) -> bool {
	c, ok := command_make(out.kinds, v)
	return ok && push_command(out, c)
}

// Sends a command made with command_make or command_from_bytes (false when the out is full).
push_command :: proc(out: ^Command_Out, c: Command) -> bool {
	if len(out.list) >= out.cap {
		return false
	}
	c := c
	c.slot = u8(out.slot)
	append(&out.list, c)
	return true
}

// The XXH3 of the declared command kinds (names and layouts), for compat_of.
@(private)
commands_hash :: proc(kinds: []Command_Kind) -> u64 {
	if len(kinds) == 0 {
		return 0
	}
	b := make([dynamic]u8, 0, 64 * len(kinds), context.temp_allocator)
	for k in kinds {
		append(&b, ..transmute([]u8)k.name)
		h := transmute([8]u8)u64le(layout_hash_of(type_info_of(k.id)))
		append(&b, ..h[:])
	}
	return hash_bytes(b[:])
}
