// A tiny deterministic game for the library's own tests: players move dots, a table of things is
// spawned and despawned from the state's RNG, events are emitted. No physics (tests/physics covers
// the Extra), so it is fast enough to run sessions on a virtual clock inside `odin test`.
package toy

import "unified:sim"

SLOTS :: 4
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

State :: struct {
	rng:     sim.Rng,
	spawned: u32,
	pos:     [SLOTS][2]f32,
	score:   [SLOTS]i32,
	joined:  [SLOTS]bool,
	things:  sim.Table(Thing, 32),
}

World :: struct {
	ticks_run: int, // outside the block: not rolled back, not hashed
}

Event_Kind :: enum u16 {
	Joined,
	Left,
	Spawned,
	Expired,
}

EVENT_NAMES := []string{"joined", "left", "spawned", "expired"}

Game :: sim.Game(State, Input, World, SLOTS)
Sim :: sim.Sim(State, Input, World, SLOTS)
Inputs :: sim.Inputs(Input, SLOTS)

GAME := Game {
	name = "toy",
	tick_hz = HZ,
	world_create = proc(seed: u64) -> ^World {return new(World)},
	world_destroy = proc(w: ^World) {free(w)},
	init = proc(s: ^State, w: ^World, seed: u64) {
		s.rng = sim.rng_seed(seed)
	},
	tick = tick,
	event_names = EVENT_NAMES,
}

tick :: proc(s: ^State, w: ^World, t: u32, inputs: ^Inputs, events: ^[dynamic]sim.Event) {
	w.ticks_run += 1
	for p in 0 ..< SLOTS {
		here := p in inputs.present
		if here != s.joined[p] {
			s.joined[p] = here
			sim.emit(events, here ? Event_Kind.Joined : Event_Kind.Left, slot = p)
		}
		if !here {
			continue
		}
		in_ := inputs.input[p]
		s.pos[p].x += f32(in_.dx) / 64
		s.pos[p].y += f32(in_.dy) / 64
		if in_.buttons & 1 != 0 && s.things.count < 32 {
			th, h, _ := sim.spawn(&s.things)
			th.pos = s.pos[p]
			th.life = i32(4 + sim.rng_below(&s.rng, 60))
			th.owner = i32(p)
			s.spawned += 1
			sim.emit(events, Event_Kind.Spawned, entity = sim.handle_key(h), pos = {th.pos.x, 0, th.pos.y}, slot = p)
		}
	}
	for i in 0 ..< s.things.high_water {
		th := sim.at(&s.things, i) or_continue
		th.life -= 1
		if th.life <= 0 {
			s.score[th.owner] += 1
			sim.emit(events, Event_Kind.Expired, entity = sim.handle_key(sim.handle(&s.things, i)))
			sim.despawn(&s.things, int(i))
		}
	}
}

// Scripted input: a hash of (seed, slot, tick / 8), so any tick can be asked for in any order.
script :: proc(seed: u64, slot: int, t: u32) -> Input {
	x := u32(seed) * 0x9E3779B1 ~ u32(slot + 1) * 0x85EBCA77 ~ (t / 8) * 0xC2B2AE3D
	x ~= x >> 15
	x *= 0x2C1B3C6D
	x ~= x >> 12
	return {dx = i8(x % 7) - 3, dy = i8((x >> 8) % 7) - 3, buttons = u8((x >> 16) % 5 == 0)}
}
