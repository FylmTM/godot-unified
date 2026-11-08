// The deterministic simulation harness, generic over a game's types at compile time:
//
//   S  the state block: plain data (no pointers, no padding), so a snapshot is a copy and its bytes
//      are the checksum input. Games put sim.Table(T, N) tables, handles and an Rng in it.
//   I  one player's input for one tick (plain data).
//   W  the game's World: everything outside the block (physics world, per-tick scratch). Rollback
//      state outside the block is registered as Extra state (physics.extra does that for Box3D).
//   P  player slots (1..32).
//
// The harness owns the tick counter, a ring of RING snapshots (block copy + every Extra's save),
// the events each tick emitted, and the checksum. Ticks are numbered from 1: the state after the
// k-th step is tick k; tick 0 is the initial state.
package sim

import "base:intrinsics"
import "core:hash/xxhash"

RING :: 16
MAX_SLOTS :: 32

#assert(ODIN_ENDIAN == .Little) // the block's in-memory bytes are its canonical LE serialization

Players :: bit_set[0 ..< MAX_SLOTS;u32]

// What a tick consumes: every slot's input plus who is in the game. A slot not in `present` has a
// zero input. `replaced` marks inputs the relay substituted (the player's last one) because the
// real one came too late; it is informational, games should not branch on it.
Inputs :: struct($I: typeid, $P: int) where P >= 1 && P <= MAX_SLOTS {
	present:  Players,
	replaced: Players,
	input:    [P]I,
}

// An event a tick emits for the view (sounds, effects, UI). Events are deterministic, kept per tick
// in the ring and re-emitted when a tick is re-simulated, so a view can show predicted events at
// once and confirm or cancel them when the tick is verified. Not part of the checksum.
Event :: struct {
	kind:   u16, // the game's event enum value
	slot:   u8, // player slot it concerns, NO_SLOT if none
	_pad:   u8,
	entity: u32, // the game's entity key (e.g. handle_key), 0 if none
	pos:    [3]f32,
	value:  f32,
}

NO_SLOT :: u8(0xFF)

// Appends an event; `kind` is any enum of the game.
emit :: proc(
	events: ^[dynamic]Event,
	kind: $K,
	entity: u32 = 0,
	pos := [3]f32{},
	value: f32 = 0,
	slot := -1,
) where intrinsics.type_is_enum(K) {
	append(
		events,
		Event{kind = u16(kind), slot = slot < 0 ? NO_SLOT : u8(slot), entity = entity, pos = pos, value = value},
	)
}

// Rollback state that lives outside the block (physics). The harness calls `save`/`restore` with
// the ring slot index (tick % RING), so an Extra keeps RING saved copies of its own.
Extra :: struct {
	name:    string,
	data:    rawptr,
	save:    proc(data: rawptr, slot: int),
	restore: proc(data: rawptr, slot: int) -> bool,
	// Appends the canonical bytes of the current state to `out` (checksum input). `state` points
	// at the block, for extras whose order follows references stored in it.
	hash:    proc(data: rawptr, state: rawptr, out: ^[dynamic]u8),
	// Portable bytes of a ring slot (valid until that slot is saved again).
	image:   proc(data: rawptr, slot: int) -> []u8,
	// Loads portable bytes (from `image`, possibly another machine) into the live state.
	load:    proc(data: rawptr, bytes: []u8) -> bool,
}

// A game, as the harness, netcode and tools see it.
Game :: struct($S, $I, $W: typeid, $P: int) {
	name:          string,
	tick_hz:       int, // a power of two (32, 64, 128); dt = 1 / tick_hz exactly
	// The World for a session with this seed: physics world, static geometry, scratch buffers.
	world_create:  proc(seed: u64) -> ^W,
	world_destroy: proc(w: ^W),
	// The World's rollback state (nil: none).
	extras:        proc(w: ^W) -> []Extra,
	// Fills the tick-0 state (the block is zeroed before). May create physics bodies.
	init:          proc(s: ^S, w: ^W, seed: u64),
	// Advances the state from tick t-1 to tick t.
	tick:          proc(s: ^S, w: ^W, t: u32, inputs: ^Inputs(I, P), events: ^[dynamic]Event),
	// Names of the event kinds, indexed by kind (for views and tools).
	event_names:   []string,
}

Ring_Slot :: struct($S: typeid) {
	tick:   u32,
	valid:  bool,
	state:  S,
	events: [dynamic]Event, // emitted by the step that produced `tick`
}

Sim :: struct($S, $I, $W: typeid, $P: int) {
	game:     ^Game(S, I, W, P),
	seed:     u64,
	tick:     u32,
	state:    S,
	world:    ^W,
	extras:   []Extra,
	ring:     [RING]Ring_Slot(S),
	// Checksum input: tick, block bytes, then each Extra's bytes. Hashed one-shot, because
	// core:hash/xxhash's streaming XXH3 (dev-2026-11) returns wrong digests for some lengths.
	hash_buf: [dynamic]u8,
}

// XXH3-64 (seed 0), one-shot.
hash_bytes :: proc(b: []u8) -> u64 {
	return xxhash.XXH3_64_default(b)
}

// Seconds -> ticks at `hz`, rounded to nearest (exact for the power-of-two rates and any
// seconds value that is a multiple of 1/hz).
ticks_of :: proc "contextless" (seconds: f32, hz: int) -> u32 {
	return u32(seconds * f32(hz) + 0.5)
}

// Creates the World and the tick-0 state, and saves tick 0 into the ring. That first save also
// lets physics fill its geometry registry in a fixed order, which is what makes a portable
// snapshot from another process restore here.
create :: proc(game: ^Game($S, $I, $W, $P), seed: u64) -> ^Sim(S, I, W, P) {
	check_plain(S)
	check_plain(Inputs(I, P))
	assert(game.tick_hz > 0 && game.tick_hz & (game.tick_hz - 1) == 0, "tick_hz must be a power of two")
	s := new(Sim(S, I, W, P))
	s.game = game
	s.seed = seed
	s.world = game.world_create(seed)
	if game.extras != nil {
		s.extras = game.extras(s.world)
	}
	game.init(&s.state, s.world, seed)
	save(s)
	return s
}

destroy :: proc(s: ^Sim($S, $I, $W, $P)) {
	for &slot in s.ring {
		delete(slot.events)
	}
	delete(s.hash_buf)
	s.game.world_destroy(s.world)
	free(s)
}

// One tick without saving it (benchmarks time the two halves apart); step is advance + save.
advance :: proc(s: ^Sim($S, $I, $W, $P), inputs: ^Inputs(I, P)) {
	t := s.tick + 1
	slot := &s.ring[t % RING]
	clear(&slot.events)
	s.game.tick(&s.state, s.world, t, inputs, &slot.events)
	s.tick = t
}

// Advances one tick with the given inputs and saves the new state into the ring.
step :: proc(s: ^Sim($S, $I, $W, $P), inputs: ^Inputs(I, P)) {
	advance(s, inputs)
	save(s)
}

// Saves the current state into ring slot tick % RING (keeping that slot's events).
save :: proc(s: ^Sim($S, $I, $W, $P)) {
	idx := int(s.tick % RING)
	slot := &s.ring[idx]
	slot.state = s.state
	for &e in s.extras {
		e.save(e.data, idx)
	}
	slot.tick = s.tick
	slot.valid = true
}

// Restores the saved state of `tick` (it must still be in the ring).
restore :: proc(s: ^Sim($S, $I, $W, $P), tick: u32) -> bool {
	idx := int(tick % RING)
	slot := &s.ring[idx]
	if !slot.valid || slot.tick != tick {
		return false
	}
	s.state = slot.state
	s.tick = tick
	for &e in s.extras {
		if !e.restore(e.data, idx) {
			return false
		}
	}
	return true
}

has_tick :: proc(s: ^Sim($S, $I, $W, $P), tick: u32) -> bool {
	slot := &s.ring[tick % RING]
	return slot.valid && slot.tick == tick
}

// The saved state of `tick`, or nil when it is not in the ring.
state_at :: proc(s: ^Sim($S, $I, $W, $P), tick: u32) -> ^S {
	slot := &s.ring[tick % RING]
	return &slot.state if slot.valid && slot.tick == tick else nil
}

// The events the step to `tick` emitted (empty when the tick is not in the ring).
events_at :: proc(s: ^Sim($S, $I, $W, $P), tick: u32) -> []Event {
	slot := &s.ring[tick % RING]
	return slot.events[:] if slot.valid && slot.tick == tick else nil
}

// XXH3-64 (seed 0) over the tick (u32 LE), the block's bytes (its canonical serialization, in
// field order) and then each Extra's canonical bytes.
checksum :: proc(s: ^Sim($S, $I, $W, $P)) -> u64 {
	clear(&s.hash_buf)
	t := transmute([4]u8)u32le(s.tick)
	append(&s.hash_buf, ..t[:])
	append(&s.hash_buf, ..([^]u8)(&s.state)[:size_of(S)])
	for &e in s.extras {
		e.hash(e.data, &s.state, &s.hash_buf)
	}
	return hash_bytes(s.hash_buf[:])
}

// Size in bytes of a full snapshot of the current tick (block + extras' images).
snapshot_size :: proc(s: ^Sim($S, $I, $W, $P)) -> int {
	n := size_of(S)
	for &e in s.extras {
		n += len(e.image(e.data, int(s.tick % RING)))
	}
	return n
}
