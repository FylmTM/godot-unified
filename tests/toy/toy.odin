// A tiny deterministic game for the library's own tests: players move dots, a table of things is
// spawned and despawned from the state's RNG, events are emitted, commands are counted. No physics
// (tests/physics covers the Extra), so it is fast enough to run sessions on a virtual clock inside
// `odin test`.
package toy

import "unified:sim"

PLAYERS :: 4
HZ :: 64

Input :: struct {
	dx:      i8,
	dy:      i8,
	buttons: u8,
	_pad:    u8,
}

Thing :: struct {
	pos:   [2]f32,
	life:  i32,
	owner: i32,
}

// Commands: a bump (counted, summed and folded in order: exactly-once and order checks) and a mark (every
// field kind the Godot host converts from a Dictionary: tests/godot_views).
Cmd_Bump :: struct {
	amount: i32,
}

Shape :: enum u8 {
	Dot,
	Ring,
	Star,
}

Shapes :: bit_set[Shape;u8]

Cmd_Mark :: struct {
	at:     [2]f32,
	normal: [3]f32,
	weight: f32,
	count:  i16,
	shape:  Shape,
	shapes: Shapes,
	loud:   bool,
	_pad:   [3]u8,
}

Cmd :: union {
	Cmd_Bump,
	Cmd_Mark,
}

State :: struct {
	rng:       sim.Rng,
	spawned:   u32,
	pos:       [PLAYERS][2]f32,
	score:     [PLAYERS]i32,
	joined:    [PLAYERS]bool,
	things:    sim.Table(Thing, 32),
	bumps:     [PLAYERS]u32, // bump commands applied
	bump_sum:  [PLAYERS]i32,
	bump_fold: [PLAYERS]u32, // bump_fold(fold, amount) over the bumps in order
	marks:     [PLAYERS]u32,
	last_mark: [PLAYERS]Cmd_Mark,
}

World :: struct {
	ticks_run: int, // outside the block: not rolled back, not hashed
}

// Events: a player's (Event_Joined, Event_Left), a thing's (Event_Expired) and one with both subjects and a position (Event_Spawned).
Event_Joined :: struct {
	player: u8,
}

Event_Left :: struct {
	player: u8,
}

Event_Spawned :: struct {
	thing:    sim.Handle(Thing),
	position: sim.Position,
	player:   u8,
	shape:    Shape,
	_pad:     [2]u8,
}

Event_Expired :: struct {
	thing: sim.Handle(Thing),
}

Event :: union {
	Event_Joined,
	Event_Left,
	Event_Spawned,
	Event_Expired,
}

Game :: sim.Game(State, Input, World, PLAYERS)
Sim :: sim.Sim(State, Input, World, PLAYERS)
Inputs :: sim.Inputs(Input, PLAYERS)
Tick :: sim.Tick(State, Input, World, PLAYERS)

GAME := Game {
	name = "toy",
	version = "1",
	tick_hz = HZ,
	world_create = proc(seed: u64, _: []u8) -> ^World {return new(World)},
	world_destroy = proc(world: ^World) {free(world)},
	init = proc(state: ^State, world: ^World, seed: u64) {
		state.rng = sim.rng_seed(seed)
	},
	tick = tick,
	events = Event,
	commands = Cmd,
}

tick :: proc(tick: ^Tick) {
	state := tick.state
	tick.world.ticks_run += 1
	for player in 0 ..< PLAYERS {
		here := player in tick.inputs.present
		if here != state.joined[player] {
			state.joined[player] = here
			if here {
				sim.emit(tick, Event_Joined{player = u8(player)})
			} else {
				sim.emit(tick, Event_Left{player = u8(player)})
			}
		}
		if !here {
			continue
		}
		for &raw in sim.commands(tick.inputs, player) {
			switch command in sim.command_value(&raw, Cmd) {
			case Cmd_Bump:
				state.bumps[player] += 1
				state.bump_sum[player] += command.amount
				state.bump_fold[player] = bump_fold(state.bump_fold[player], command.amount)
			case Cmd_Mark:
				state.marks[player] += 1
				state.last_mark[player] = command
			}
		}
		input := tick.inputs.input[player]
		state.pos[player].x += f32(input.dx) / 64
		state.pos[player].y += f32(input.dy) / 64
		if input.buttons & 1 != 0 && state.things.count < 32 {
			thing, handle, _ := sim.spawn(&state.things)
			thing.pos = state.pos[player]
			thing.life = i32(4 + sim.rng_below(&state.rng, 60))
			thing.owner = i32(player)
			state.spawned += 1
			sim.emit(tick, Event_Spawned {
				thing    = handle,
				position = {thing.pos.x, 0, thing.pos.y},
				player   = u8(player),
				shape    = Shape(thing.life % 3),
			})
		}
	}
	things := sim.iterate(&state.things)
	for thing, handle in sim.next(&things) {
		thing.life -= 1
		if thing.life <= 0 {
			state.score[thing.owner] += 1
			sim.emit(tick, Event_Expired{thing = handle})
			sim.despawn(&state.things, handle)
		}
	}
}

// Scripted input: a hash of (seed, player, tick / 8), so any tick can be asked for in any order.
scripted_input :: proc(seed: u64, player: int, tick: u32) -> Input {
	x := u32(seed) * 0x9E3779B1 ~ u32(player + 1) * 0x85EBCA77 ~ (tick / 8) * 0xC2B2AE3D
	x ~= x >> 15
	x *= 0x2C1B3C6D
	x ~= x >> 12
	return {
		dx      = i8(x % 7) - 3,
		dy      = i8((x >> 8) % 7) - 3,
		buttons = u8((x >> 16) % 5 == 0),
	}
}

// Order-sensitive: the same bumps in another order fold differently.
bump_fold :: proc(fold: u32, amount: i32) -> u32 {
	return fold * 31 + u32(amount) + 1
}

// Scripted commands of `player` for a tick, a function of (seed, player, tick) only: a bump about every
// 16th tick, a burst of 6 bumps every 200th tick (tick % 200 == 50: two of them wait for the next tick), a
// mark every 64th.
scripted_commands :: proc(seed: u64, player: int, tick: u32, out: ^sim.Command_Out) {
	x := u32(seed) * 0x85EBCA77 ~ u32(player + 1) * 0x9E3779B1 ~ tick * 0x27D4EB2F
	x ~= x >> 15
	x *= 0x2C1B3C6D
	x ~= x >> 13
	if x % 16 == 0 {
		sim.send_command(out, Cmd_Bump{i32((x >> 8) % 1000) - 500})
	}
	if tick % 200 == 50 {
		for k in 0 ..< 6 {
			sim.send_command(out, Cmd_Bump{i32(player * 100 + k)})
		}
	}
	if tick % 64 == 7 {
		sim.send_command(out, Cmd_Mark {
			at    = {f32(player), f32(tick % 7)},
			count = i16(tick % 100),
			shape = .Ring,
			loud  = true,
		})
	}
}
