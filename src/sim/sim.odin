// The deterministic simulation harness, generic over the game type, sim.Game(State, Input, World, Event, Cmd,
// PLAYERS) (src/sim/SPEC.md):
//
//   State    the state block: plain data (no pointers, no padding), so a snapshot is a copy and its bytes
//            are the checksum input. It holds the players (`players: sim.Players(...)`), tables and handles.
//   Input    one player's input for one tick (plain data, no bools or floats).
//   World    everything outside the block (physics world, per-tick scratch); its rollback state is the
//            game's Extra (physics.extra for Box3D).
//   Event    the event union, Cmd the command union.
//   PLAYERS  input slots (1..32): a player (a session member, sim.Player) holds one while present.
//
// The harness owns the tick counter, a ring of saved ticks (block copy + the Extra's save + the events the
// tick emitted, ring_size(tick_hz) of them) and the checksum. Ticks are numbered from 1: the state after the
// k-th step is tick k; tick 0 is the initial state.
package sim

// Used only inside generic procs: @(require) keeps -vet from calling them unused in a program that never
// instantiates those (a game's tests that run the sim offline only).
@(require) import "base:intrinsics"
@(require) import "base:runtime"
import "core:fmt"
import "core:hash/xxhash"
import "core:strings"

import "unified:dmath"

MAX_PLAYERS :: 32

// The library's own simulation (src/sim, src/dmath, src/physics): bump it in a change that makes a reference
// run or a golden trace compute differently because of the library, not a game's rules (the sim-change skill). Part of
// compat_of, so builds on other library versions refuse each other instead of desyncing; a game's own changes bump
// its Game.version.
LIBRARY_VERSION :: 4

// The library's part of a build's identity (compat_of): its sim version and the unified-box3d pin.
Library :: struct {
	version: u32, // LIBRARY_VERSION
	box3d:   string, // box3d_pin()
}

// The unified-box3d release the build is pinned to: `[box3d] tag` of unified's pins.cfg (src/cli/SPEC.md, Pins),
// embedded at compile time. Part of compat_of: Box3D's state is the sim's (src/physics/SPEC.md), so builds pinned to
// other releases refuse each other. A UNIFIED_BOX3D checkout (unified-box3d's own development) still reports the pin.
box3d_pin :: proc() -> string {
	PINS :: #load("../../pins.cfg", string)
	text, section := PINS, false
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "[") {
			section = trimmed == "[box3d]"
		} else if section && strings.has_prefix(trimmed, "tag") {
			value := strings.trim_space(trimmed[len("tag"):])
			if strings.has_prefix(value, "=") do return strings.trim(value[1:], ` "`)
		}
	}
	panic("pins.cfg has no [box3d] tag")
}

#assert(ODIN_ENDIAN == .Little) // the block's in-memory bytes are its canonical LE serialization

Slots :: bit_set[0 ..< MAX_PLAYERS;u32]

// What a tick consumes, by slot: every slot's input, which slots are present, the join records and the commands
// sent for this tick (command.odin). A slot not in `present` has a zero input. `joins` holds each slot's join record:
// the relay's member id of who becomes present in it, non-zero only on that tick (a slot that becomes present without
// one stays absent; sim.join). `replaced` marks inputs the relay substituted (the slot's last one) because the real
// one came too late; it is informational (tools, stats): peers step the same tick with and without it, so the lint
// bans reading it in tick code. Commands are never repeated or
// substituted: each arrives in one tick only.
Inputs :: struct($G: typeid) where intrinsics.type_is_specialization_of(G, Game) {
	present:       Slots,
	replaced:      Slots,
	input:         [part(G, GAME_PLAYERS)]part(G, GAME_INPUT),
	joins:         [part(G, GAME_PLAYERS)]u16,
	command_count: int,
	commands:      [TICK_COMMANDS]Raw_Command, // ordered by slot, each slot's in the order sent (sim.commands)
}

// The game type. A game names its six types once, `Game :: sim.Game(State, Input, World, Event, Cmd, PLAYERS)`, and
// everything generic over a game (Sim, Tick, the netcode's Client, headless.Headless, godot.Glue, ...) takes that one
// type, `$G`, and names a part of it with `part(G, GAME_<PART>)`:
//
//   part(G, GAME_STATE)    the State           part(G, GAME_EVENT)    the Event union
//   part(G, GAME_INPUT)    the Input           part(G, GAME_CMD)      the Cmd union
//   part(G, GAME_WORLD)    the World           part(G, GAME_PLAYERS)  PLAYERS, the slot count
//
// Inside a body, name the parts it uses once: `State :: sim.part(G, sim.GAME_STATE)`. Odin refuses `part` in a
// proc's parameter list, so a parameter is a struct built from G (`^Sim($G)`, `^Tick(G)`, `^Inputs(G)`).
part :: intrinsics.type_polymorphic_record_parameter_value
GAME_STATE :: 0
GAME_INPUT :: 1
GAME_WORLD :: 2
GAME_EVENT :: 3
GAME_CMD :: 4
GAME_PLAYERS :: 5

// What `tick` gets: the harness builds one for each step, after it updated the State's Players (players.odin), and
// one for `init` (number 0, no inputs, no changes). Per-tick helpers that need more than the block take it (emit,
// roll_below, input, commands). Event and Cmd are the game's unions: emit and commands check against them at compile
// time.
Tick :: struct($G: typeid) where intrinsics.type_is_specialization_of(G, Game) {
	state:          ^part(G, GAME_STATE),
	world:          ^part(G, GAME_WORLD),
	number:         u32, // the tick being computed: the state goes from tick number - 1 to number
	seed:           u64, // the session's seed
	dt:             f32, // seconds per tick: 1 / tick_hz, exact
	inputs:         ^Inputs(G),
	events:         ^Events, // what this tick emits (event.odin)
	player_changes: Player_Changes, // who arrived or left this tick (the State's Players already shows it)
	commands:       ^Commands(part(G, GAME_CMD)), // the tick's commands, decoded (command.odin)
}

// The step's changes to the State's Players (Tick.player_changes): `for player in t.player_changes.arrived`.
Player_Changes :: struct {
	arrived: []Player, // everyone present from this tick, new or back, in slot order
	joined:  []Player, // those of them who are new members (zeroed data); the others come back with their data
	left:    []Player, // members absent from this tick
}

// Rollback state that lives outside the block (physics: physics.extra). A game has at most one (Game.extra; a game
// with two kinds composes them into one). The harness calls `save`/`restore` with the ring slot (tick % ring_size),
// so an Extra keeps one saved copy per ring slot (at most MAX_RING_SIZE).
Extra :: struct {
	data:       rawptr,
	tick_hz:    int, // its step rate (physics: Settings.tick_hz; 0: none): create refuses another (extra_violation)
	save:       proc(data: rawptr, slot: int),
	restore:    proc(data: rawptr, slot: int) -> bool,
	// Appends the canonical bytes of the current state to `out` (checksum input). On ticks that are a multiple of
	// DEEP_CHECKSUM_EVERY (the ones the netcode compares) it covers all of its internal state; on others it may cover
	// less (a cheaper summary).
	hash:       proc(data: rawptr, tick: u32, out: ^[dynamic]u8),
	// Portable bytes of a ring slot (valid until that slot is saved again or the next image). `live`: the slot holds
	// the current tick, saved after its last change, so the live state is that slot's and the Extra may image it
	// directly instead of putting the slot in place first (physics skips swapping its world out and back).
	image:      proc(data: rawptr, slot: int, live: bool) -> []u8,
	// Loads portable bytes (from `image`, possibly another machine) into the live state.
	load:       proc(data: rawptr, bytes: []u8) -> bool,
	// Optional, together (snapshot_keep): `keep` copies ring slot `slot`'s save into keep slot `index` (0 ..<
	// KEEP_SLOTS; a memcpy, this build's bytes); `image_kept` gives keep slot `index`'s portable bytes, the same `image`
	// gave for the slot it was kept from (valid until the next image). Without them snapshot_keep images at once.
	keep:       proc(data: rawptr, slot: int, index: int),
	image_kept: proc(data: rawptr, index: int) -> []u8,
	// Optional: the bytes the save of a ring slot holds (what each tick's save copies; save_size, the benchmarks).
	size:       proc(data: rawptr, slot: int) -> int,
	// Optional: "" when the extra agrees with the block (`state`), else why (physics: a broken ref, an orphaned body).
	// sim.check_extra runs it; the sync-tests run it after every restore.
	check:      proc(data: rawptr, state: rawptr) -> string,
}

// The game's Extra's check on the current state: "" when it agrees with the block (or the game has none), else why.
check_extra :: proc(simulation: ^Sim($G)) -> string {
	extra := &simulation.extra
	return extra.check(extra.data, &simulation.state) if extra.check != nil else ""
}

// The whole ticks nearest to `seconds` at `tick_hz` (clamped to 0..max(i32)): a time from data (a level file). A time
// constant converts as a constant instead, `X_TICKS :: u16(X_S * TICK_HZ)`, which the compiler checks is exact.
ticks :: proc(seconds: f32, tick_hz: int) -> u32 {
	scaled := seconds * f32(tick_hz) + 0.5
	if !(scaled > 0) do return 0 // also NaN
	if scaled >= 2147483647 do return 2147483647
	return u32(scaled)
}

// The seconds `count` ticks last at `tick_hz` (views, HUDs), for a tick count of any integer type.
seconds :: proc(count: $T, tick_hz: int) -> f32 where intrinsics.type_is_integer(T) {
	return f32(count) / f32(tick_hz)
}

// A game, as the harness, netcode and tools see it.
Game :: struct(
	$State, $Input, $World, $Event, $Cmd: typeid,
	$PLAYERS: int,
) where PLAYERS >= 1 &&
	PLAYERS <= MAX_PLAYERS,
	intrinsics.type_has_field(State, "players"),
	intrinsics.type_is_specialization_of(intrinsics.type_field_type(State, "players"), Players),
	part(intrinsics.type_field_type(State, "players"), 1) ==
	Input,
	part(intrinsics.type_field_type(State, "players"), 2) ==
	PLAYERS {
	name:              string,
	// The simulation's version: bump it when `tick` changes behaviour in a way the state and input
	// layouts don't show (a rule, a constant). Part of compat_of, so builds that differ refuse to
	// play together instead of desyncing.
	version:           string,
	tick_hz:           int, // a power of two, 32..128; dt = 1 / tick_hz exactly
	// Optional: the content the game ships with, its level file's bytes (src/level/SPEC.md), embedded once in the
	// sim package (`content = #load("../../game/levels/arena.level")`). create, compat_of and from_snapshot use it
	// when given no content, so every host, run and suite plays it unless given other bytes (a test's own level,
	// the headless `--level FILE`).
	content:           []u8,

	// Optional: the World for a session with this seed and content (the level file's bytes, src/level/SPEC.md;
	// empty when the game has none): physics world, static geometry, scratch buffers. The bytes outlive the World
	// (the caller of create owns them). nil: a zeroed World (a game without one names sim.No_World).
	world_create:      proc(seed: u64, content: []u8) -> ^World,
	// Optional: frees what world_create made (nil: free(world)).
	world_destroy:     proc(world: ^World),
	// The World's rollback state (nil: none), asked for right after world_create: a physics game returns
	// physics.extra(world.phys, State).
	extra:             proc(world: ^World) -> Extra,
	// Optional: fills the tick-0 state (the block is zeroed before): t.number is 0, no player is present. May emit,
	// roll and create physics bodies.
	init:              proc(t: ^Tick(Game(State, Input, World, Event, Cmd, PLAYERS))),
	// Advances the state from tick.number - 1 to tick.number.
	tick:              proc(tick: ^Tick(Game(State, Input, World, Event, Cmd, PLAYERS))),
	// Optional: a scripted player, for tests, benchmarks and headless checks (never called by the sim): the input of
	// the player in `slot` for `tick`, and right after it that player's commands (sim.send_command(out, command)).
	// `state` is the caller's current state; a script that answers from (seed, slot, tick) alone (sim.script_bits)
	// gives every client of a session and every offline run the same player.
	scripted_input:    proc(seed: u64, slot: int, tick: u32, state: ^State) -> Input,
	scripted_commands: proc(seed: u64, slot: int, tick: u32, state: ^State, out: ^Command_Out(Cmd)),
	// Optional, never called by the sim: fill the initial state with `count` entities and hold that population (the
	// headless `bench`, Godot's `-- --bench N`). Single player only: it changes the initial state, which every peer
	// would have to share.
	bench_prepare:     proc(state: ^State, world: ^World, count: int),
}

// The command union of a game that has no commands: sim.Game(State, Input, World, Event, sim.No_Commands, PLAYERS).
No_Commands :: union {}

// The World of a game that keeps nothing outside the block: sim.Game(State, Input, sim.No_World, Event, Cmd, PLAYERS).
No_World :: struct {}

@(private)
MIN_RING_SIZE :: 8
MAX_RING_SIZE :: 32

// The ring keeps about 250 ms of ticks at any rate: 8 at 32 Hz, 16 at 64, 32 at 128. It bounds
// rollback: the netcode predicts at most ring_size - 2 ticks ahead.
ring_size :: proc(tick_hz: int) -> int {
	return dmath.clamp(tick_hz / 4, MIN_RING_SIZE, MAX_RING_SIZE)
}

// Ticks a Sim keeps aside for a portable snapshot later (snapshot_keep): the netcode keeps its last checksum ticks
// for a desync report.
KEEP_SLOTS :: 8

// A tick kept aside: its block and (with the Extra's keep) the Extra's save, or else the Extra's image taken at once.
@(private)
Kept_Tick :: struct($State: typeid) {
	tick:  u32,
	kept:  bool,
	state: State,
	image: [dynamic]u8, // the Extra's portable image when it has no keep
}

@(private)
Ring_Slot :: struct($State: typeid) {
	tick:   u32,
	valid:  bool, // the slot holds `tick`'s events
	saved:  bool, // ... and its state (step(save = false) leaves it out): state_at, restore and snapshots read it
	state:  State,
	events: Events, // emitted by the step that produced `tick`
}

Sim :: struct($G: typeid) where intrinsics.type_is_specialization_of(G, Game) {
	game:          ^G,
	seed:          u64,
	content:       []u8, // what it plays (create's, or Game.content); borrowed: the caller of create keeps it alive
	content_hash:  u64, // content_hash(content): recorded in input logs and snapshots
	compat:        u64, // compat_of(game, content): recorded in snapshots
	layout:        u64, // layout_hash(State): recorded in snapshots (a constant of the type, derived once)
	tick:          u32,
	state:         part(G, GAME_STATE),
	world:         ^part(G, GAME_WORLD),
	extra:         Extra, // the game's (Game.extra; zero: none)
	ring:          []Ring_Slot(part(G, GAME_STATE)), // ring_size(game.tick_hz) slots, allocated at create
	changes:       Changes_Buffer(part(G, GAME_PLAYERS)), // the step's joins and leaves (Tick.player_changes)
	commands:      Commands(part(G, GAME_CMD)), // the step's commands, decoded (Tick.commands)
	input_fixable: bool, // the Input holds an enum or a bit_set: step reads each slot's through wire_fix
	read_inputs:   Inputs(G), // a step's inputs as read when one slot's Input needed it (inputs_as_read)
	// Checksum input: tick, block bytes, then each Extra's bytes. Hashed one-shot, because
	// core:hash/xxhash's streaming XXH3 (dev-2026-11) returns wrong digests for some lengths.
	hash_buf:      [dynamic]u8,
	kept:          []Kept_Tick(part(G, GAME_STATE)), // KEEP_SLOTS, allocated by the first snapshot_keep
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
// tuning, has its own) and version, the library's (LIBRARY_VERSION) and the unified-box3d pin (box3d_pin):
// `library` overrides those two (tests: another build's compat; zero fields: this build's). Two builds with the same value run
// the same simulation, as far as the build can tell. The content's hash goes in too, so peers with different
// levels refuse to play together (nil: the game's own, Game.content).
compat_of :: proc(
	game: ^$G,
	content: []u8 = nil,
	library := Library{},
) -> u64 where intrinsics.type_is_specialization_of(G, Game) {
	return compat_with(game, layout_hash(part(G, GAME_STATE)), game_content(game, content), library)
}

// compat_of for a caller that has the State's layout hash already (create, from_snapshot): one RTTI walk fewer.
@(private)
compat_with :: proc(
	game: ^$G,
	state_layout: u64,
	content: []u8,
	library: Library,
) -> u64 where intrinsics.type_is_specialization_of(G, Game) {
	Input :: part(G, GAME_INPUT)
	Event :: part(G, GAME_EVENT)
	Cmd :: part(G, GAME_CMD)
	PLAYERS :: part(G, GAME_PLAYERS)
	Ids :: struct {
		state, input, inputs, name, version, content, commands, events, box3d: u64,
		players, tick_hz, library, _pad:                                       u32, // no padding: hashed as bytes
	}
	ids := Ids {
		state    = state_layout,
		input    = layout_hash(Input),
		inputs   = layout_hash(Inputs(G)),
		name     = hash_bytes(transmute([]u8)game.name),
		version  = hash_bytes(transmute([]u8)game.version),
		content  = content_hash(content),
		commands = union_hash(Cmd, COMMAND_PREFIX),
		events   = union_hash(Event, EVENT_PREFIX),
		box3d    = hash_bytes(transmute([]u8)(library.box3d != "" ? library.box3d : box3d_pin())),
		players  = u32(PLAYERS),
		tick_hz  = u32(game.tick_hz),
		library  = library.version != 0 ? library.version : LIBRARY_VERSION,
	}
	return dmath.max(hash_bytes(([^]u8)(&ids)[:size_of(Ids)]), 1) // never 0 ("any")
}

// Whether two ticks' inputs are the same for the simulation: the same slots present, the same join
// records, the same input bytes (what the checksum sees: -0.0 and +0.0 differ, a NaN equals itself) and the same
// commands. `replaced` is informational and not compared.
inputs_same :: proc(a, b: ^Inputs($G)) -> bool {
	Input :: part(G, GAME_INPUT)
	PLAYERS :: part(G, GAME_PLAYERS)
	if a.present != b.present ||
	   a.joins != b.joins ||
	   a.command_count != b.command_count ||
	   runtime.memory_compare(&a.input, &b.input, size_of([PLAYERS]Input)) != 0 {
		return false
	}
	for i in 0 ..< a.command_count {
		x, y := &a.commands[i], &b.commands[i]
		if x.kind != y.kind ||
		   x.slot != y.slot ||
		   x.size != y.size ||
		   runtime.memory_compare(&x.data[0], &y.data[0], int(x.size)) != 0 {
			return false
		}
	}
	return true
}

// The content a run of `game` plays: `content`, or the game's own (Game.content) when that is nil.
game_content :: proc(game: ^$G, content: []u8) -> []u8 where intrinsics.type_is_specialization_of(G, Game) {
	return content if content != nil else game.content
}

// The identity of a game's content (src/level/SPEC.md): XXH3 of the bytes, 0 for none.
content_hash :: proc(content: []u8) -> u64 {
	return hash_bytes(content) if len(content) > 0 else 0
}

// Why a game can't run ("" when it can; temp-allocated): its tick rate, its State (plain data: plain_violation), its
// Input (wire_violation), its command and event unions. create panics with it; the Godot host reports it. What the
// compiler can check (the State's `players`, the library's events in the Event union) doesn't compile instead.
game_violation :: proc(game: ^$G) -> string where intrinsics.type_is_specialization_of(G, Game) {
	State :: part(G, GAME_STATE)
	Input :: part(G, GAME_INPUT)
	Cmd :: part(G, GAME_CMD)
	Event :: part(G, GAME_EVENT)
	return declaration_violation(game.name, game.tick_hz, type_info_of(State), type_info_of(Input), Cmd, Event)
}

// game_violation's body, for the types at run time (a non-generic home for its imports: -vet).
@(private)
declaration_violation :: proc(
	name: string,
	tick_hz: int,
	state, input: ^runtime.Type_Info,
	commands, events: typeid,
) -> string {
	if tick_hz < 32 || tick_hz > 128 || tick_hz & (tick_hz - 1) != 0 {
		return fmt.tprintf("%s: tick_hz %d (a power of two, 32..128)", name, tick_hz)
	}
	if reason := plain_violation(state, fmt.tprint(state.id)); reason != "" {
		return fmt.tprintf("%s: the State is not plain data: %s", name, reason)
	}
	if reason := wire_violation(input, fmt.tprint(input.id)); reason != "" {
		return fmt.tprintf("%s: the Input can't be sent between machines: %s", name, reason)
	}
	if reason := union_violation(commands, COMMAND_MAX, COMMAND_PREFIX); reason != "" {
		return fmt.tprintf("%s: commands: %s", name, reason)
	}
	if reason := union_violation(events, EVENT_MAX, EVENT_PREFIX, padding = true); reason != "" {
		return fmt.tprintf("%s: events: %s", name, reason)
	}
	for variant in union_variants(events) {
		info := runtime.type_info_base(variant).variant.(runtime.Type_Info_Struct) or_continue
		for i in 0 ..< int(info.field_count) {
			if field := info.names[i]; field == "tick" || field == "kind" || field == "id" {
				return fmt.tprintf(
					"%s: events: %v has a field named `%s`, which every event carries already (its tick, kind and id): rename it",
					name,
					variant.id,
					field,
				)
			}
		}
	}
	return ""
}

// Why a game's Extra can't run with it ("" when it can; temp-allocated): it steps at another rate than the game.
extra_violation :: proc(game: ^$G, extra: Extra) -> string where intrinsics.type_is_specialization_of(G, Game) {
	if extra.tick_hz == 0 || extra.tick_hz == game.tick_hz do return ""
	return fmt.tprintf(
		"%s: its Extra steps at %d Hz, the game at %d Hz (physics.Settings.tick_hz must be Game.tick_hz)",
		game.name,
		extra.tick_hz,
		game.tick_hz,
	)
}

// Creates the World and the tick-0 state, allocates the ring and saves tick 0 into it. `content`: the level it plays
// (nil: the game's own, Game.content), borrowed: the caller keeps it alive.
create :: proc(
	game: ^$G,
	seed: u64,
	content: []u8 = nil,
) -> ^Sim(G) where intrinsics.type_is_specialization_of(G, Game) {
	State :: part(G, GAME_STATE)
	Input :: part(G, GAME_INPUT)
	Event :: part(G, GAME_EVENT)
	Cmd :: part(G, GAME_CMD)
	PLAYERS :: part(G, GAME_PLAYERS)
	if reason := game_violation(game); reason != "" {
		panic(reason)
	}
	level := game_content(game, content)
	simulation := new(Sim(G))
	simulation.game = game
	simulation.seed = seed
	simulation.content = level
	simulation.content_hash = content_hash(level)
	simulation.layout = layout_hash(State)
	simulation.compat = compat_with(game, simulation.layout, level, {})
	simulation.input_fixable = wire_fixable(type_info_of(Input))
	simulation.ring = make([]Ring_Slot(State), ring_size(game.tick_hz))
	for &slot in simulation.ring {
		// Grows under create's allocator, whatever is active then; room for a usual tick's events up front, so the
		// session thread doesn't allocate the first time a ring slot gets some.
		slot.events.list = make([dynamic]Raw_Event, 0, 8)
	}
	simulation.hash_buf = make([dynamic]u8)
	simulation.world = game.world_create(seed, level) if game.world_create != nil else new(part(G, GAME_WORLD))
	if game.extra != nil {
		simulation.extra = game.extra(simulation.world)
		if reason := extra_violation(game, simulation.extra); reason != "" {
			panic(reason)
		}
	}
	inputs: Inputs(G)
	slot := &simulation.ring[0]
	slot.tick = 0
	slot.valid = true
	if game.init != nil {
		t := make_tick(simulation, 0, &inputs, &slot.events)
		game.init(&t)
	}
	save(simulation)
	return simulation
}

// Frees a Sim made by create or from_snapshot: its ring, its events and the game's World (game.world_destroy, or
// free).
destroy :: proc(simulation: ^Sim($G)) {
	for &slot in simulation.ring {
		delete(slot.events.list)
	}
	delete(simulation.ring)
	delete(simulation.hash_buf)
	for &kept in simulation.kept {
		delete(kept.image)
	}
	delete(simulation.kept)
	if simulation.game.world_destroy != nil {
		simulation.game.world_destroy(simulation.world)
	} else {
		free(simulation.world)
	}
	free(simulation)
}

// The ring slot of a tick.
ring_slot :: #force_inline proc(simulation: ^Sim($G), tick: u32) -> int {
	return int(tick % u32(len(simulation.ring)))
}

// Advances one tick with the given inputs and saves the new state into the ring. `save` false keeps only its events
// there: for ticks nothing will roll back to (the netcode re-simulating ticks that are already final; a benchmark
// timing the save apart); events_at answers for such a tick, state_at, restore and snapshot_encode don't. The slot is
// the new tick's from the start: it never answers for the tick it held before. The State's Players is updated first
// (players.odin) and its join and leave events emitted before the game's. Each Input is read as every peer reads
// bytes from another machine (inputs_as_read); `inputs` itself is left as it is.
step :: proc(simulation: ^Sim($G), inputs: ^Inputs(G), save := true) {
	read := inputs_as_read(simulation, inputs) // as every peer reads them: `inputs` stays as sent
	number := simulation.tick + 1
	slot := &simulation.ring[ring_slot(simulation, number)]
	slot.tick = number
	slot.valid = true
	slot.saved = false
	clear(&slot.events.list)
	tick := make_tick(simulation, number, read, &slot.events)
	changes := &simulation.changes
	players_update(&tick, changes)
	tick.player_changes = {
		arrived = changes.arrived[:changes.arrived_count],
		joined  = changes.joined[:changes.joined_count],
		left    = changes.left[:changes.left_count],
	}
	commands_decode(&simulation.commands, read)
	simulation.game.tick(&tick)
	players_remember(&simulation.state.players, read)
	simulation.tick = number
	if save do save_tick(simulation)
}

// The inputs as the tick reads them: an enum field outside its declared values reads as its zero value and a bit_set
// holds only its own elements (wire_fix), so an Input from a modified or buggy client can't make `tick` index out of
// bounds or see a phantom button, on any peer. Valid inputs (every honest client's) are used as they are; otherwise a
// fixed copy is.
@(private)
inputs_as_read :: proc(simulation: ^Sim($G), inputs: ^Inputs(G)) -> ^Inputs(G) {
	Input :: part(G, GAME_INPUT)
	if !simulation.input_fixable do return inputs
	for &input in inputs.input {
		if changed, _ := wire_fix(&input, type_info_of(Input), .Input, apply = false); changed {
			simulation.read_inputs = inputs^
			for &fixed in simulation.read_inputs.input {
				wire_fix(&fixed, type_info_of(Input), .Input, apply = true)
			}
			return &simulation.read_inputs
		}
	}
	return inputs
}

// The Tick for computing tick `number` (no player changes: step fills them).
@(private)
make_tick :: proc(simulation: ^Sim($G), number: u32, inputs: ^Inputs(G), events: ^Events) -> Tick(G) {
	return {
		state    = &simulation.state,
		world    = simulation.world,
		number   = number,
		seed     = simulation.seed,
		dt       = 1 / f32(simulation.game.tick_hz),
		inputs   = inputs,
		events   = events,
		commands = &simulation.commands,
	}
}

// Saves the current state into its ring slot (keeping that slot's events).
save :: proc(simulation: ^Sim($G)) {
	save_tick(simulation)
}

// save's body, under another name: step's `save` parameter shadows the proc there.
@(private)
save_tick :: proc(simulation: ^Sim($G)) {
	index := ring_slot(simulation, simulation.tick)
	slot := &simulation.ring[index]
	slot.state = simulation.state
	if extra := &simulation.extra; extra.save != nil {
		extra.save(extra.data, index)
	}
	slot.tick = simulation.tick
	slot.valid = true
	slot.saved = true
}

// Restores the saved state of `tick` (it must still be in the ring). The extra goes first: if it fails, the block
// and the tick are left as they were and false comes back (the caller treats the sim as broken). The later ticks leave the ring: they are
// another timeline's until they are stepped again.
restore :: proc(simulation: ^Sim($G), tick: u32) -> bool {
	index := ring_slot(simulation, tick)
	slot := &simulation.ring[index]
	if !slot.saved || slot.tick != tick {
		return false
	}
	if extra := &simulation.extra; extra.restore != nil && !extra.restore(extra.data, index) {
		return false
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
state_at :: proc(simulation: ^Sim($G), tick: u32) -> ^part(G, GAME_STATE) {
	slot := &simulation.ring[ring_slot(simulation, tick)]
	return &slot.state if slot.saved && slot.tick == tick else nil
}

// The events the step to `tick` emitted, in emission order (empty when the tick is not in the
// ring). event_value reads one back as the game's union.
events_at :: proc(simulation: ^Sim($G), tick: u32) -> []Raw_Event {
	slot := &simulation.ring[ring_slot(simulation, tick)]
	return slot.events.list[:] if slot.valid && slot.tick == tick else nil
}

// XXH3-64 (seed 0) over the tick (u32 LE), the block's bytes (its canonical serialization, in
// field order) and then the Extra's canonical bytes.
checksum :: proc(simulation: ^Sim($G)) -> u64 {
	clear(&simulation.hash_buf)
	tick := transmute([4]u8)u32le(simulation.tick)
	append(&simulation.hash_buf, ..tick[:])
	append(&simulation.hash_buf, ..([^]u8)(&simulation.state)[:size_of(simulation.state)])
	if extra := &simulation.extra; extra.hash != nil {
		extra.hash(extra.data, simulation.tick, &simulation.hash_buf)
	}
	return hash_bytes(simulation.hash_buf[:])
}

// The ticks whose checksums cover the Extra's whole internal state (Extra.hash), and the ones the netcode compares
// between peers.
DEEP_CHECKSUM_EVERY :: 16

// Bytes each tick's save copies, measured on the current tick: the block and the extra's save of its slot (an extra
// without `size` counts 0). What a tick costs in the ring, against snapshot_size's portable image.
save_size :: proc(simulation: ^Sim($G)) -> int {
	size := size_of(simulation.state)
	if extra := &simulation.extra; extra.size != nil {
		size += extra.size(extra.data, ring_slot(simulation, simulation.tick))
	}
	return size
}

// Size in bytes of a full snapshot of the current tick (block + the extra's image).
snapshot_size :: proc(simulation: ^Sim($G)) -> int {
	size := size_of(simulation.state)
	if extra := &simulation.extra; extra.image != nil {
		index := ring_slot(simulation, simulation.tick)
		slot := &simulation.ring[index]
		size += len(extra.image(extra.data, index, slot.saved && slot.tick == simulation.tick))
	}
	return size
}
