// The deterministic simulation harness, generic over a game's types at compile time (src/sim/SPEC.md):
//
//   State    the state block: plain data (no pointers, no padding), so a snapshot is a copy and its bytes
//            are the checksum input. Games put sim.Table(T, N) tables, handles and an Rng in it.
//   Input    one player's input for one tick (plain data).
//   World    the game's World: everything outside the block (physics world, per-tick scratch). Rollback
//            state outside the block is registered as Extra state (physics.extra does that for Box3D).
//   PLAYERS  player seats (1..32).
//
// The harness owns the tick counter, a ring of saved ticks (block copy + every Extra's save + the
// events the tick emitted, ring_size(tick_hz) of them) and the checksum. Ticks are numbered from 1:
// the state after the k-th step is tick k; tick 0 is the initial state.
package sim

// Used only inside generic procs: @(require) keeps -vet from calling them unused in a program that never
// instantiates those (a game's tests that run the sim offline only).
@(require) import "base:runtime"
import "core:fmt"
import "core:hash/xxhash"

MAX_PLAYERS :: 32
NO_PLAYER :: u8(0xFF) // "no player" in a u8 player field

#assert(ODIN_ENDIAN == .Little) // the block's in-memory bytes are its canonical LE serialization

Players :: bit_set[0 ..< MAX_PLAYERS;u32]

// What a tick consumes: every player's input, who is in the game, and the commands sent for this
// tick (command.odin). A player not in `present` has a zero input. `replaced` marks inputs the relay
// substituted (the player's last one) because the real one came too late; it is informational, games
// should not branch on it. Commands are never repeated or substituted: each arrives in one tick only.
Inputs :: struct($Input: typeid, $PLAYERS: int) where PLAYERS >= 1 && PLAYERS <= MAX_PLAYERS {
	present:       Players,
	replaced:      Players,
	input:         [PLAYERS]Input,
	command_count: int,
	commands:      [TICK_COMMANDS]Raw_Command, // ordered by player, each player's in the order sent (sim.commands)
}

// Who joined and who left since the last tick: compares this tick's presence with `present`, a Players field the
// game keeps in its State, and updates it. The game emits its own events from the two sets.
//
//   joined, left := sim.presence_changes(tick, &state.present)
//   for player in joined do sim.emit(tick, Joined{player = u8(player)})
presence_changes :: proc(
	tick: ^Tick($State, $Input, $World, $PLAYERS),
	present: ^Players,
) -> (
	joined: Players,
	left: Players,
) {
	now := tick.inputs.present
	joined, left = now - present^, present^ - now
	present^ = now
	return
}

// What `tick` gets: the harness builds one for each step. Per-tick helpers that need more than the
// block take it (emit, roll_below).
Tick :: struct($State, $Input, $World: typeid, $PLAYERS: int) {
	state:  ^State,
	world:  ^World,
	number: u32, // the tick being computed: the state goes from tick number - 1 to number
	seed:   u64, // the session's seed
	inputs: ^Inputs(Input, PLAYERS),
	events: ^Events, // what this tick emits (event.odin)
}

// Rollback state that lives outside the block (physics). The harness calls `save`/`restore` with
// the ring slot (tick % ring_size), so an Extra keeps one saved copy per ring slot (at most
// MAX_RING_SIZE).
Extra :: struct {
	name:    string,
	data:    rawptr,
	save:    proc(data: rawptr, slot: int),
	restore: proc(data: rawptr, slot: int) -> bool,
	// Appends the canonical bytes of the current state to `out` (checksum input). `state` points
	// at the block, for extras whose order follows references stored in it. On ticks that are a
	// multiple of DEEP_CHECKSUM_EVERY (the ones the netcode compares) an extra covers all of its
	// internal state; on others it may cover less (a cheaper summary).
	hash:    proc(data: rawptr, state: rawptr, tick: u32, out: ^[dynamic]u8),
	// Portable bytes of a ring slot (valid until that slot is saved again).
	image:   proc(data: rawptr, slot: int) -> []u8,
	// Loads portable bytes (from `image`, possibly another machine) into the live state.
	load:    proc(data: rawptr, bytes: []u8) -> bool,
}

// A game, as the harness, netcode and tools see it.
Game :: struct($State, $Input, $World: typeid, $PLAYERS: int) {
	name:            string,
	// The simulation's version: bump it when `tick` changes behaviour in a way the state and input
	// layouts don't show (a rule, a constant). Part of compat_of, so builds that differ refuse to
	// play together instead of desyncing.
	version:         string,
	tick_hz:         int, // a power of two, 32..128; dt = 1 / tick_hz exactly
	// The least input delay the netcode gives a player, in ticks (0: 1). The delay grows past it only as far as a
	// round trip needs to keep the prediction inside the rollback window (src/netcode/SPEC.md, Timing).
	min_input_delay: int,
	// The World for a session with this seed and content (the level file's bytes, src/level/SPEC.md;
	// empty when the game has none): physics world, static geometry, scratch buffers. The bytes
	// outlive the World (the caller of create owns them).
	world_create:    proc(seed: u64, content: []u8) -> ^World,
	world_destroy:   proc(world: ^World),
	// The World's rollback state (nil: none).
	extras:          proc(world: ^World) -> []Extra,
	// Fills the tick-0 state (the block is zeroed before). May create physics bodies.
	init:            proc(state: ^State, world: ^World, seed: u64),
	// Advances the state from tick.number - 1 to tick.number.
	tick:            proc(tick: ^Tick(State, Input, World, PLAYERS)),
	// The game's event union (event.odin): one plain struct per event (nil: no events).
	events:          typeid,
	// The game's command union (command.odin): one plain struct per command (nil: no commands).
	commands:        typeid,
}

MIN_RING_SIZE :: 8
MAX_RING_SIZE :: 32

// The ring keeps about 250 ms of ticks at any rate: 8 at 32 Hz, 16 at 64, 32 at 128. It bounds
// rollback: the netcode predicts at most ring_size - 2 ticks ahead.
ring_size :: proc(tick_hz: int) -> int {
	return clamp(tick_hz / 4, MIN_RING_SIZE, MAX_RING_SIZE)
}

Ring_Slot :: struct($State: typeid) {
	tick:   u32,
	valid:  bool, // the slot holds `tick`'s events
	saved:  bool, // ... and its state (step_unsaved leaves it out): state_at, restore and snapshots read it
	state:  State,
	events: Events, // emitted by the step that produced `tick`
}

Sim :: struct($State, $Input, $World: typeid, $PLAYERS: int) {
	game:         ^Game(State, Input, World, PLAYERS),
	seed:         u64,
	content:      []u8, // borrowed: the caller of create keeps it alive
	content_hash: u64, // content_hash(content): recorded in input logs and snapshots
	tick:         u32,
	state:        State,
	world:        ^World,
	extras:       []Extra,
	ring:         []Ring_Slot(State), // ring_size(game.tick_hz) slots, allocated at create
	// Checksum input: tick, block bytes, then each Extra's bytes. Hashed one-shot, because
	// core:hash/xxhash's streaming XXH3 (dev-2026-11) returns wrong digests for some lengths.
	hash_buf:     [dynamic]u8,
}

// XXH3-64 (seed 0), one-shot.
hash_bytes :: proc(bytes: []u8) -> u64 {
	if len(bytes) == 0 {
		none: [1]u8 // core:hash/xxhash asserts on a nil pointer, even for zero bytes
		return xxhash.XXH3_64_default(none[:0])
	}
	return xxhash.XXH3_64_default(bytes)
}

// The game build's identity for netcode (Hello's compat): the state, input and inputs layouts, the
// command and event types, the player count, the tick rate, the game's name (each variant, e.g. a
// tuning, has its own) and version. Two builds with the same value run the same simulation, as far as
// the build can tell. The content's hash goes in too, so peers with different levels refuse to play
// together.
compat_of :: proc(game: ^Game($State, $Input, $World, $PLAYERS), content: []u8 = nil) -> u64 {
	Ids :: struct {
		state, input, inputs, name, version, content, commands, events: u64,
		players, tick_hz:                                               u32,
	}
	ids := Ids {
		state    = layout_hash(State),
		input    = layout_hash(Input),
		inputs   = layout_hash(Inputs(Input, PLAYERS)),
		name     = hash_bytes(transmute([]u8)game.name),
		version  = hash_bytes(transmute([]u8)game.version),
		content  = content_hash(content),
		commands = union_hash(game.commands, COMMAND_PREFIX),
		events   = union_hash(game.events, EVENT_PREFIX),
		players  = u32(PLAYERS),
		tick_hz  = u32(game.tick_hz),
	}
	return max(hash_bytes(([^]u8)(&ids)[:size_of(Ids)]), 1) // never 0 ("any")
}

// Whether two ticks' inputs are the same for the simulation: the same players present, the same
// input bytes (what the checksum sees: -0.0 and +0.0 differ, a NaN equals itself) and the same
// commands. `replaced` is informational and not compared.
inputs_same :: proc(a, b: ^Inputs($Input, $PLAYERS)) -> bool {
	if a.present != b.present ||
	   a.command_count != b.command_count ||
	   runtime.memory_compare(&a.input, &b.input, size_of([PLAYERS]Input)) != 0 {
		return false
	}
	for i in 0 ..< a.command_count {
		x, y := &a.commands[i], &b.commands[i]
		if x.kind != y.kind ||
		   x.player != y.player ||
		   x.size != y.size ||
		   runtime.memory_compare(&x.data[0], &y.data[0], int(x.size)) != 0 {
			return false
		}
	}
	return true
}

// The identity of a game's content (src/level/SPEC.md): XXH3 of the bytes, 0 for none.
content_hash :: proc(content: []u8) -> u64 {
	return hash_bytes(content) if len(content) > 0 else 0
}

// Why a game's declaration can't be used ("" when it can): the tick rate, the command and event unions.
game_violation :: proc(name: string, tick_hz: int, commands, events: typeid) -> string {
	if tick_hz < 32 || tick_hz > 128 || tick_hz & (tick_hz - 1) != 0 {
		return fmt.tprintf("%s: tick_hz %d (a power of two, 32..128)", name, tick_hz)
	}
	if reason := union_violation(commands, COMMAND_MAX, COMMAND_PREFIX); reason != "" {
		return fmt.tprintf("%s: commands: %s", name, reason)
	}
	if reason := union_violation(events, EVENT_MAX, EVENT_PREFIX); reason != "" {
		return fmt.tprintf("%s: events: %s", name, reason)
	}
	return ""
}

// Creates the World and the tick-0 state, allocates the ring and saves tick 0 into it.
create :: proc(
	game: ^Game($State, $Input, $World, $PLAYERS),
	seed: u64,
	content: []u8 = nil,
) -> ^Sim(State, Input, World, PLAYERS) {
	check_plain(State)
	check_plain(Input)
	if reason := game_violation(game.name, game.tick_hz, game.commands, game.events); reason != "" {
		panic(reason)
	}
	simulation := new(Sim(State, Input, World, PLAYERS))
	simulation.game = game
	simulation.seed = seed
	simulation.content = content
	simulation.content_hash = content_hash(content)
	simulation.ring = make([]Ring_Slot(State), ring_size(game.tick_hz))
	for &slot in simulation.ring {
		slot.events.type = game.events
	}
	simulation.world = game.world_create(seed, content)
	if game.extras != nil {
		simulation.extras = game.extras(simulation.world)
	}
	game.init(&simulation.state, simulation.world, seed)
	save(simulation)
	return simulation
}

destroy :: proc(simulation: ^Sim($State, $Input, $World, $PLAYERS)) {
	for &slot in simulation.ring {
		delete(slot.events.list)
	}
	delete(simulation.ring)
	delete(simulation.hash_buf)
	simulation.game.world_destroy(simulation.world)
	free(simulation)
}

// The ring slot of a tick.
ring_slot :: #force_inline proc(simulation: ^Sim($State, $Input, $World, $PLAYERS), tick: u32) -> int {
	return int(tick % u32(len(simulation.ring)))
}

// One tick without saving it (benchmarks time the two halves apart); step is advance + save. The slot is the
// new tick's from the start, holding its events and no state: it never answers for the tick it held before.
advance :: proc(simulation: ^Sim($State, $Input, $World, $PLAYERS), inputs: ^Inputs(Input, PLAYERS)) {
	number := simulation.tick + 1
	slot := &simulation.ring[ring_slot(simulation, number)]
	slot.tick = number
	slot.valid = true
	slot.saved = false
	clear(&slot.events.list)
	tick := Tick(State, Input, World, PLAYERS) {
		state  = &simulation.state,
		world  = simulation.world,
		number = number,
		seed   = simulation.seed,
		inputs = inputs,
		events = &slot.events,
	}
	simulation.game.tick(&tick)
	simulation.tick = number
}

// Advances one tick with the given inputs and saves the new state into the ring.
step :: proc(simulation: ^Sim($State, $Input, $World, $PLAYERS), inputs: ^Inputs(Input, PLAYERS)) {
	advance(simulation, inputs)
	save(simulation)
}

// Advances one tick and keeps its events in the ring, without saving its state: for ticks nothing will roll back
// to (the netcode re-simulating ticks that are already final, #117). events_at answers for it; state_at, restore
// and snapshot_encode don't.
step_unsaved :: proc(simulation: ^Sim($State, $Input, $World, $PLAYERS), inputs: ^Inputs(Input, PLAYERS)) {
	advance(simulation, inputs)
}

// Saves the current state into its ring slot (keeping that slot's events).
save :: proc(simulation: ^Sim($State, $Input, $World, $PLAYERS)) {
	index := ring_slot(simulation, simulation.tick)
	slot := &simulation.ring[index]
	slot.state = simulation.state
	for &extra in simulation.extras {
		extra.save(extra.data, index)
	}
	slot.tick = simulation.tick
	slot.valid = true
	slot.saved = true
}

// Restores the saved state of `tick` (it must still be in the ring). The extras go first: if one
// fails, the block and the tick are left as they were and false comes back (the extras before it
// may have been restored; the caller treats the sim as broken). The later ticks leave the ring: they are
// another timeline's until they are stepped again.
restore :: proc(simulation: ^Sim($State, $Input, $World, $PLAYERS), tick: u32) -> bool {
	index := ring_slot(simulation, tick)
	slot := &simulation.ring[index]
	if !slot.saved || slot.tick != tick {
		return false
	}
	for &extra in simulation.extras {
		if !extra.restore(extra.data, index) {
			return false
		}
	}
	simulation.state = slot.state
	simulation.tick = tick
	for &later in simulation.ring {
		if later.tick > tick {
			later.valid = false
			later.saved = false
		}
	}
	return true
}

// The saved state of `tick`, or nil when it is not in the ring.
state_at :: proc(simulation: ^Sim($State, $Input, $World, $PLAYERS), tick: u32) -> ^State {
	slot := &simulation.ring[ring_slot(simulation, tick)]
	return &slot.state if slot.saved && slot.tick == tick else nil
}

// The events the step to `tick` emitted, in emission order (empty when the tick is not in the
// ring). event_value reads one back as the game's union.
events_at :: proc(simulation: ^Sim($State, $Input, $World, $PLAYERS), tick: u32) -> []Raw_Event {
	slot := &simulation.ring[ring_slot(simulation, tick)]
	return slot.events.list[:] if slot.valid && slot.tick == tick else nil
}

// XXH3-64 (seed 0) over the tick (u32 LE), the block's bytes (its canonical serialization, in
// field order) and then each Extra's canonical bytes.
checksum :: proc(simulation: ^Sim($State, $Input, $World, $PLAYERS)) -> u64 {
	clear(&simulation.hash_buf)
	tick := transmute([4]u8)u32le(simulation.tick)
	append(&simulation.hash_buf, ..tick[:])
	append(&simulation.hash_buf, ..([^]u8)(&simulation.state)[:size_of(State)])
	for &extra in simulation.extras {
		extra.hash(extra.data, &simulation.state, simulation.tick, &simulation.hash_buf)
	}
	return hash_bytes(simulation.hash_buf[:])
}

// The ticks whose checksums cover every extra's whole internal state (Extra.hash), and the ones the
// netcode compares between peers.
DEEP_CHECKSUM_EVERY :: 16

// Size in bytes of a full snapshot of the current tick (block + extras' images).
snapshot_size :: proc(simulation: ^Sim($State, $Input, $World, $PLAYERS)) -> int {
	size := size_of(State)
	for &extra in simulation.extras {
		size += len(extra.image(extra.data, ring_slot(simulation, simulation.tick)))
	}
	return size
}
