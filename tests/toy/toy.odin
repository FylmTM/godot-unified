// A tiny deterministic game for the library's own tests: players move dots, a table of things they own is
// spawned and despawned (each thing's life a keyed roll), events are emitted, commands are counted, and a command
// takes the team to the other of its two levels (dots are faster in the cave), so every session crosses level
// changes. No physics
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
	seen:    sim.Seen, // the Godot host stamps it (tests/godot_driver); scripts leave it 0
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

// Commands: a bump (counted, summed and folded in order: exactly-once and order checks), a mark (every
// field kind the Godot host converts from a Dictionary: tests/godot_views) and an empty one (zero bytes).
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
	area:   Mark_Area, // a nested struct: an object of its class (DataMarkArea)
}

Mark_Area :: struct {
	corner: [2]f32,
	layer:  u8,
	_pad:   [3]u8,
}

// A command without fields (zero bytes): the sender's bump counters start over.
Cmd_Clear_Bumps :: struct {}

// The toy's levels, in GAME.levels' order.
Area :: enum u8 {
	Meadow,
	Cave,
}

// Pauses or resumes the game for everyone (the co-op pause: sim.set_paused).
Cmd_Pause :: struct {
	paused: bool,
}

// Takes the team to a level (nothing when it is the active one).
Cmd_Travel :: struct {
	to: Area,
}

// A trail of up to 3 points (a List of positions: view units in GDScript, sim units in the sim), kept by the sender.
Cmd_Trail :: struct {
	points: sim.List(sim.Position, 3),
}

Cmd :: union {
	Cmd_Bump,
	Cmd_Mark,
	Cmd_Clear_Bumps,
	Cmd_Travel,
	Cmd_Pause,
	Cmd_Trail,
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
	trail:     sim.List(sim.Position, 3), // the last Cmd_Trail's
	color:     u32, // their Profile's, from the tick they arrived
}

// The session's Setup: things live `life_bonus` ticks longer (0, the toy's default, changes nothing).
Setup :: struct {
	life_bonus: u8,
	_pad:       [3]u8,
}

// What a player chose before joining: a colour, kept in their data from the tick they arrive.
Profile :: struct {
	color: u8,
	_pad:  [3]u8,
}

State :: struct {
	spawned: u32,
	level:   sim.Active_Level(Area),
	_pad:    u32,
	clock:   sim.Clock, // game time: a Cmd_Pause stops it (the co-op pause)
	players: sim.Players(Player_Data, Profile, Input, PLAYERS),
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

Game :: sim.Game(State, Input, World, Event, Cmd, Setup, Profile, PLAYERS)
Sim :: sim.Sim(Game)
Inputs :: sim.Inputs(Game)
Tick :: sim.Tick(Game)

GAME := Game {
	name = "toy",
	version = "4", // 4: the co-op pause
	tick_hz = HZ,
	levels = {
		{"meadow", #load("../godot_views/levels/meadow.level")},
		{"cave", #load("../godot_views/levels/cave.level")},
	},
	init = proc(t: ^Tick) {sim.level_enter(t, Area.Meadow)},
	tick = tick,
	scripted_input = scripted_input,
	scripted_commands = scripted_commands,
	scripted_profile = scripted_profile,
	save = save,
}

// The toy's save (Game.save): the next session's things live longer the more this one spawned. A save point is one
// tick of every 7 of game time, so a client that missed a tick's save, or saved a predicted one, saves otherwise than
// the relay's log replays to (every session scenario checks it).
save :: proc(state: ^State, setup: ^Setup) -> bool {
	if u64(state.clock.time) % 7 != 0 do return false
	setup.life_bonus = u8(state.spawned / 4 % 8)
	return true
}

// What the toy's keyed rolls are for (sim.roll_below).
Roll :: enum u8 {
	Thing_Life,
}

tick :: proc(t: ^Tick) {
	t.world.ticks_run += 1
	for player in t.player_changes.arrived {
		sim.player_data(t, player).color = u32(sim.player_profile(t, player).color)
	}
	players := sim.iterate_present(t)
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
			case Cmd_Clear_Bumps:
				data.bumps, data.bump_sum, data.bump_fold = 0, 0, 0
			case Cmd_Travel:
				if command.to != t.state.level.id do sim.level_enter(t, command.to)
			case Cmd_Trail:
				data.trail = command.points
			case Cmd_Pause:
				sim.set_paused(t, command.paused)
			case:
				panic("sim.commands yielded a nil entry") // it never does: an undecodable command is left out
			}
		}
		if t.paused do continue // the co-op pause: commands are read (none is lost), nothing moves or spawns
		input := sim.input(t, player)
		speed := f32(1) / 32 if t.state.level.id == .Cave else f32(1) / 64
		data.pos.x += f32(input.dx) * speed
		data.pos.y += f32(input.dy) * speed
		if .Spawn in sim.buttons(t, player).pressed && t.state.things.count < 32 { 	// held: one thing
			thing, handle, _ := sim.spawn(&t.state.things)
			thing.pos = data.pos
			thing.life = i32(
				4 + sim.roll_below(t, 60, Roll.Thing_Life, sim.handle_key(handle)) + u32(t.setup.life_bonus),
			)
			thing.owner = player
			t.state.spawned += 1
			sim.emit(t, Event_Spawned {
				thing    = handle,
				position = sim.position_2d(thing.pos),
				player   = player,
				shape    = Shape(thing.life % 3),
			})
		}
	}
	if t.paused do return // things don't age while paused
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
	return sim.slot_data(&state.players, slot)
}

// Scripted input: a hash of (seed, slot, tick / 8), so any tick can be asked for in any order.
scripted_input :: proc(seed: u64, slot: int, tick: u32, state: ^State = nil) -> Input {
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

// The scripted players' Profiles: a colour per slot and seed.
scripted_profile :: proc(seed: u64, slot: int) -> Profile {
	return {color = u8(1 + slot + int(seed % 3))}
}

// Order-sensitive: the same bumps in another order fold differently.
bump_fold :: proc(fold: u32, amount: i32) -> u32 {
	return fold * 31 + u32(amount) + 1
}

// Scripted commands of `slot` for a tick, a function of (seed, slot, tick) only: a bump about every 16th tick, a burst
// of 3 bumps every 200th tick (tick % 200 == 50), a mark every 64th, and from slot 0 a travel to the cave every 300th
// tick (tick % 300 == 120) and back 90 ticks later, and from slot 0 a pause of 40 ticks of every 512 (from tick 300):
// never more than a tick takes (offline runs play it).
scripted_commands :: proc(seed: u64, slot: int, tick: u32, state: ^State, out: ^sim.Command_Out(Cmd)) {
	commands_of(seed, slot, tick, out, 3)
}

// The same with a burst of 6 bumps: more than a tick takes, so two of them wait for the next tick (the netcode's
// tests: the relay holds them).
burst_commands :: proc(seed: u64, slot: int, tick: u32, state: ^State, out: ^sim.Command_Out(Cmd)) {
	commands_of(seed, slot, tick, out, 6)
}

@(private)
commands_of :: proc(seed: u64, slot: int, tick: u32, out: ^sim.Command_Out(Cmd), burst: int) {
	x := u32(seed) * 0x85EBCA77 ~ u32(slot + 1) * 0x9E3779B1 ~ tick * 0x27D4EB2F
	x ~= x >> 15
	x *= 0x2C1B3C6D
	x ~= x >> 13
	if x % 16 == 0 {
		sim.send_command(out, Cmd_Bump{i32((x >> 8) % 1000) - 500})
	}
	if tick % 200 == 50 {
		for k in 0 ..< burst {
			sim.send_command(out, Cmd_Bump{i32(slot * 100 + k)})
		}
	}
	if slot == 0 && tick % 300 == 120 do sim.send_command(out, Cmd_Travel{.Cave})
	if slot == 0 && tick % 300 == 210 do sim.send_command(out, Cmd_Travel{.Meadow})
	if slot == 0 && tick % 512 == 300 do sim.send_command(out, Cmd_Pause{true}) // never a travel tick
	if slot == 0 && tick % 512 == 340 do sim.send_command(out, Cmd_Pause{false})
	if tick % 64 == 7 { 	// never a burst tick (50 + 200k is even mod 64, 7 is odd)
		sim.send_command(out, Cmd_Mark {
			at    = {f32(slot), f32(tick % 7)},
			count = i16(tick % 100),
			shape = .Ring,
			loud  = true,
		})
	}
}
