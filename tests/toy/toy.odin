// A tiny deterministic game for the library's own tests: players move dots, a table of things they own is
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
	buttons: Buttons, // held (sim.buttons: down, pressed, released)
	_pad:    u8,
}

Button :: enum u8 {
	Spawn,
}

Buttons :: bit_set[Button;u8]

Thing :: struct {
	pos:   [2]f32,
	life:  i32,
	owner: sim.Player, // who spawned it: scores when it expires, whether present or not
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
	target: sim.Handle(Thing), // its key
	place:  sim.Position, // a Vector2 in the 2D host (view units)
	area:   Mark_Area, // a Dictionary
}

Mark_Area :: struct {
	corner: [2]f32,
	layer:  u8,
	_pad:   [3]u8,
}

Cmd :: union {
	Cmd_Bump,
	Cmd_Mark,
}

// A player's data (sim.Players): zeroed when someone new joins, kept while they are away.
Player_Data :: struct {
	pos:       [2]f32,
	score:     i32,
	bumps:     u32, // bump commands applied
	bump_sum:  i32,
	bump_fold: u32, // bump_fold(fold, amount) over the bumps in order
	marks:     u32,
	last_mark: Cmd_Mark,
}

State :: struct {
	spawned: u32,
	_pad:    u32,
	players: sim.Players(Player_Data, Input, PLAYERS),
	things:  sim.Table(Thing, 32),
}

World :: struct {
	ticks_run: int, // outside the block: not rolled back, not hashed
}

// Events: the library's join and leave, a thing's (Event_Expired) and one with both subjects and a position
// (Event_Spawned).
Event_Spawned :: struct {
	thing:    sim.Handle(Thing),
	position: sim.Position,
	player:   sim.Player,
	shape:    Shape,
}

Event_Expired :: struct {
	thing: sim.Handle(Thing),
}

Event :: union {
	sim.Event_Player_Joined,
	sim.Event_Player_Left,
	Event_Spawned,
	Event_Expired,
}

Game :: sim.Game(State, Input, World, Event, Cmd, PLAYERS)
Sim :: sim.Sim(Game)
Inputs :: sim.Inputs(Game)
Tick :: sim.Tick(Game)

GAME := Game {
	name = "toy",
	version = "2", // 2: a thing's life is a keyed roll
	tick_hz = HZ,
	world_create = proc(seed: u64, _: []u8) -> ^World {return new(World)},
	world_destroy = proc(world: ^World) {free(world)},
	init = proc(t: ^Tick) {},
	tick = tick,
}

// What the toy's keyed rolls are for (sim.roll_below).
Roll :: enum u8 {
	Thing_Life,
}

tick :: proc(t: ^Tick) {
	t.world.ticks_run += 1
	players := sim.iterate_present(&t.state.players)
	for data, player in sim.next(&players) {
		for sent in sim.commands(t, player) {
			switch command in sent {
			case Cmd_Bump:
				data.bumps += 1
				data.bump_sum += command.amount
				data.bump_fold = bump_fold(data.bump_fold, command.amount)
			case Cmd_Mark:
				data.marks += 1
				data.last_mark = command
			}
		}
		input := sim.input(t, player)
		data.pos.x += f32(input.dx) / 64
		data.pos.y += f32(input.dy) / 64
		if .Spawn in sim.buttons(t, player).pressed && t.state.things.count < 32 { 	// held: one thing
			thing, handle, _ := sim.spawn(&t.state.things)
			thing.pos = data.pos
			thing.life = i32(4 + sim.roll_below(t, 60, Roll.Thing_Life, sim.handle_key(handle)))
			thing.owner = player
			t.state.spawned += 1
			sim.emit(t, Event_Spawned {
				thing    = handle,
				position = {thing.pos.x, thing.pos.y, 0},
				player   = player,
				shape    = Shape(thing.life % 3),
			})
		}
	}
	things := sim.iterate(&t.state.things)
	for thing, handle in sim.next(&things) {
		thing.life -= 1
		if thing.life <= 0 {
			if owner := sim.player_data(t, thing.owner); owner != nil {
				owner.score += 1
			}
			sim.emit(t, Event_Expired{thing = handle})
			sim.despawn(&t.state.things, handle)
		}
	}
}

// The data of whoever holds `slot` (nil: nobody), for tests that look at a client's own player.
in_slot :: proc(state: ^State, slot: int) -> ^Player_Data {
	return sim.player_data(&state.players, sim.player_in_slot(&state.players, slot))
}

// Scripted input: a hash of (seed, slot, tick / 8), so any tick can be asked for in any order.
scripted_input :: proc(seed: u64, slot: int, tick: u32) -> Input {
	x := u32(seed) * 0x9E3779B1 ~ u32(slot + 1) * 0x85EBCA77 ~ (tick / 8) * 0xC2B2AE3D
	x ~= x >> 15
	x *= 0x2C1B3C6D
	x ~= x >> 12
	return {
		dx      = i8(x % 7) - 3,
		dy      = i8((x >> 8) % 7) - 3,
		buttons = {.Spawn} if (x >> 16) % 5 == 0 else {},
	}
}

// Order-sensitive: the same bumps in another order fold differently.
bump_fold :: proc(fold: u32, amount: i32) -> u32 {
	return fold * 31 + u32(amount) + 1
}

// Scripted commands of `slot` for a tick, a function of (seed, slot, tick) only: a bump about every
// 16th tick, a burst of 6 bumps every 200th tick (tick % 200 == 50: two of them wait for the next tick), a
// mark every 64th.
scripted_commands :: proc(seed: u64, slot: int, tick: u32, out: ^sim.Command_Out(Cmd)) {
	x := u32(seed) * 0x85EBCA77 ~ u32(slot + 1) * 0x9E3779B1 ~ tick * 0x27D4EB2F
	x ~= x >> 15
	x *= 0x2C1B3C6D
	x ~= x >> 13
	if x % 16 == 0 {
		sim.send_command(out, Cmd_Bump{i32((x >> 8) % 1000) - 500})
	}
	if tick % 200 == 50 {
		for k in 0 ..< 6 {
			sim.send_command(out, Cmd_Bump{i32(slot * 100 + k)})
		}
	}
	if tick % 64 == 7 {
		sim.send_command(out, Cmd_Mark {
			at    = {f32(slot), f32(tick % 7)},
			count = i16(tick % 100),
			shape = .Ring,
			loud  = true,
		})
	}
}
