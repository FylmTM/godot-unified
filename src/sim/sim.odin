// The deterministic simulation harness, generic over the game type, sim.Game(State, Input, World, Event, Cmd,
// Setup, Profile, PLAYERS) (src/sim/README.md):
//
//   State    the state block: plain data (no pointers, no padding), so a snapshot is a copy and its bytes
//            are the checksum input. It holds the players (`players: sim.Players(...)`), tables and handles.
//   Input    one player's input for one tick (plain data, no bools or floats).
//   World    everything outside the block (physics world, per-tick scratch); its rollback state is the
//            game's Extra (physics.extra for Box3D).
//   Event    the event union, Cmd the command union.
//   Setup    what differs between two sessions of one build (a mode, a difficulty, saved progress): fixed when the
//            session starts, beside the seed (sim.No_Setup: none).
//   Profile  what a player chose before joining (a character, a colour): on their join record, kept in the
//            State's Players by member (sim.No_Profile: none).
//   PLAYERS  input slots (1..32): a player (a session member, sim.Player) holds one while present.
//
// The harness owns the tick counter, a ring of saved ticks (block copy + the Extra's save + the events the
// tick emitted, ring_size(tick_hz) of them) and the checksum. Ticks are numbered from 1: the state after the
// k-th step is tick k; tick 0 is the initial state.
package sim

// Used only inside generic procs: @(require) keeps -vet from calling them unused in a program that never
// instantiates those (a game's tests that run the sim offline only).
import "base:builtin"
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
LIBRARY_VERSION :: 5

// The library's part of a build's identity (compat_of): its sim version and the unified-box3d pin.
Library :: struct {
	version: u32, // LIBRARY_VERSION
	box3d:   string, // box3d_pin()
}

// The unified-box3d release the build is pinned to: `[box3d] tag` of unified's pins.cfg (src/cli/README.md, Pins),
// embedded at compile time. Part of compat_of: Box3D's state is the sim's (src/physics/README.md), so builds pinned to
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

// A set of input slots, one bit per slot (Inputs.present, Inputs.replaced).
Slots :: bit_set[0 ..< MAX_PLAYERS;u32]

// What a tick consumes, by slot: every slot's input, which slots are present, the join records and the commands
// sent for this tick (command.odin). A slot not in `present` has a zero input. `joins` holds each slot's join record:
// the relay's member id of who becomes present in it, non-zero only on that tick (a slot that becomes present without
// one stays absent; sim.join), and `profiles` the Profile that join brings (meaningful only beside a join record). `replaced` marks inputs the relay substituted (the slot's last one) because the real
// one came too late; it is informational (tools, stats): peers step the same tick with and without it, so the lint
// bans reading it in tick code. Commands are never repeated or
// substituted: each arrives in one tick only.
Inputs :: struct($G: typeid) where intrinsics.type_is_specialization_of(G, Game) {
	present:       Slots,
	replaced:      Slots,
	input:         [part(G, GAME_PLAYERS)]part(G, GAME_INPUT),
	joins:         [part(G, GAME_PLAYERS)]u16,
	profiles:      [part(G, GAME_PLAYERS)]part(G, GAME_PROFILE),
	command_count: int,
	commands:      [TICK_COMMANDS]Raw_Command, // ordered by slot, each slot's in the order sent (sim.commands)
}

// The game type. A game names its eight types once, `Game :: sim.Game(State, Input, World, Event, Cmd, Setup, Profile,
// PLAYERS)`, and everything generic over a game (Sim, Tick, the netcode's Client, the headless runs, godot.Glue, ...)
// takes that one type, `$G`, and names a part of it with `part(G, GAME_<PART>)`:
//
//   part(G, GAME_STATE)    the State           part(G, GAME_CMD)      the Cmd union
//   part(G, GAME_INPUT)    the Input           part(G, GAME_SETUP)    the Setup
//   part(G, GAME_WORLD)    the World           part(G, GAME_PROFILE)  the Profile
//   part(G, GAME_EVENT)    the Event union     part(G, GAME_PLAYERS)  PLAYERS, the slot count
//
// Inside a body, name the parts it uses once: `State :: sim.part(G, sim.GAME_STATE)`. Odin refuses `part` in a
// proc's parameter list, so a parameter is a struct built from G (`^Sim($G)`, `^Tick(G)`, `^Inputs(G)`). Passing
// something that is not a sim.Game (`sim.Tick(State)`) gives a where-clause error followed by a cascade of `part`
// errors: read the first.
part :: intrinsics.type_polymorphic_record_parameter_value
GAME_STATE :: 0
GAME_INPUT :: 1
GAME_WORLD :: 2
GAME_EVENT :: 3
GAME_CMD :: 4
GAME_SETUP :: 5
GAME_PROFILE :: 6
GAME_PLAYERS :: 7

// The most bytes a Setup may have: it travels whole in the netcode's Welcome, the input log's header and every
// snapshot's.
SETUP_MAX :: 512
// The most bytes a Profile may have, a command's (COMMAND_MAX): it rides beside a join record.
PROFILE_MAX :: COMMAND_MAX

// What `tick` gets: the harness builds one for each step, after it updated the State's Players (players.odin), and
// one for `init` (number 0, no inputs, no changes). Per-tick helpers that need more than the block take it (emit,
// roll_below, input, commands). Event and Cmd are the game's unions: emit and commands check against them at compile
// time.
Tick :: struct($G: typeid) where intrinsics.type_is_specialization_of(G, Game) {
	state:          ^part(G, GAME_STATE),
	world:          ^part(G, GAME_WORLD),
	number:         u32, // the tick being computed: the state goes from tick number - 1 to number
	seed:           u64, // the session's seed
	setup:          part(G, GAME_SETUP), // the session's Setup (Sim.setup): a copy, so a write here reaches nothing
	dt:             f32, // seconds per tick: 1 / tick_hz, exact
	inputs:         ^Inputs(G),
	events:         ^Events, // what this tick emits (event.odin)
	player_changes: Player_Changes, // who arrived or left this tick (the State's Players already shows it)
	commands:       ^Commands(part(G, GAME_CMD)), // the tick's commands, decoded (command.odin)
	dev:            ^Dev, // the Sim's development attachment (dev.odin; nil: none): the harness's, never tick code's
	time:           u32, // game time (time.odin): the State's Clock after this tick's advance, or `number` without one
	paused:         bool, // the Clock stood still this tick (the co-op pause: the game runs no system); false without one
	tick_hz:        int, // the game's rate (Game.tick_hz)
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
	$State, $Input, $World, $Event, $Cmd, $Setup, $Profile: typeid,
	$PLAYERS: int,
) where PLAYERS >= 1 &&
	PLAYERS <= MAX_PLAYERS,
	intrinsics.type_has_field(State, "players"),
	intrinsics.type_is_specialization_of(intrinsics.type_field_type(State, "players"), Players),
	part(intrinsics.type_field_type(State, "players"), 1) ==
	Profile,
	part(intrinsics.type_field_type(State, "players"), 2) ==
	Input,
	part(intrinsics.type_field_type(State, "players"), 3) ==
	PLAYERS {
	name:                  string,
	// The simulation's version: bump it when `tick` changes behaviour in a way the state and input
	// layouts don't show (a rule, a constant). Part of compat_of, so builds that differ refuse to
	// play together instead of desyncing.
	version:               string,
	tick_hz:               int, // a power of two, 32..128; dt = 1 / tick_hz exactly
	// Optional: the game's levels (src/sim/README.md, Levels), embedded once in the sim package, in the order of its
	// level enum (`levels = {{"hub", #load("../../game/levels/hub.level")}, {"route", ...}}`): every host, run and
	// suite plays them, and compat_of covers all of them. A run on other levels plays a copy of the game with other
	// levels (the headless `--level NAME=FILE`).
	levels:                []Level_File,
	// The Setup of a session started without one: create, the netcode's hosts and the headless runs play it unless
	// given another (a menu's, the headless `--setup`). Zero unless set; a variant of the game is a copy of the
	// descriptor with another Setup. It must read as sent (game_violation).
	setup:                 Setup,

	// Optional: the World for a session with this seed and Setup, given the game's levels (Game.levels): physics
	// world, every level parsed and built, scratch buffers. The levels outlive the World. nil: a zeroed World (a game
	// without one names sim.No_World).
	world_create:          proc(seed: u64, levels: []Level_File, setup: Setup) -> ^World,
	// Optional: frees what world_create made (nil: free(world)).
	world_destroy:         proc(world: ^World),
	// The World's rollback state (nil: none), asked for right after world_create, so bodies made there are the
	// World's: a physics game returns physics.extra(world.phys, State).
	extra:                 proc(world: ^World) -> Extra,
	// Optional: fills the tick-0 state (the block is zeroed before): t.number is 0, no player is present. May emit,
	// roll and create physics bodies.
	init:                  proc(t: ^Tick(Game(State, Input, World, Event, Cmd, Setup, Profile, PLAYERS))),
	// Advances the state from tick.number - 1 to tick.number.
	tick:                  proc(tick: ^Tick(Game(State, Input, World, Event, Cmd, Setup, Profile, PLAYERS))),
	// Optional: a scripted player, for tests, benchmarks, headless checks and Godot's `--scripted` sessions (never
	// called by the sim; without one they play zero Inputs): the input of the player in `slot` for `tick`, and right
	// after it that player's commands (sim.send_command(out, command)).
	// `state` is the caller's current state; a script that answers from (seed, slot, tick) alone (sim.script_bits)
	// gives every client of a session and every offline run the same player.
	scripted_input:        proc(seed: u64, slot: int, tick: u32, state: ^State) -> Input,
	scripted_commands:     proc(seed: u64, slot: int, tick: u32, state: ^State, out: ^Command_Out(Cmd)),
	// Optional, never called by the sim: the Profile a scripted player in `slot` joins with (without one: the zero
	// Profile). A script that answers from (seed, slot) alone gives every client and offline run the same players.
	scripted_profile:      proc(seed: u64, slot: int) -> Profile,
	// Optional, never called by the sim: fill the initial state with `count` entities and hold that population (the
	// headless `bench`, Godot's `-- --bench N`). Single player only: it changes the initial state, which every peer
	// would have to share.
	bench_prepare:         proc(state: ^State, world: ^World, count: int),
	// Optional, never read by the sim: the least input delay a client plays this game with, in ticks (0: one tick).
	// A slower-paced game takes 2 or 3: every input is felt that much later, and each correction reaches that much
	// less far back (as many guesses are wrong; src/netcode/README.md, Timing). At most the netcode's delay ceiling
	// (netcode.game_violation). Not part of compat_of: it changes when a client samples, never what a tick computes.
	input_delay_min_ticks: int,
	// Optional, never called by the sim: a client's guess of a remote player's input `ticks_ahead` (>= 1) ticks after
	// `last`, the newest of theirs it knows (nil: `last` again). Only a guess: a wrong one is corrected by a rollback
	// like any other, peers need not agree on it, and the relay still repeats `last` for a missing input. Pure and
	// cheap: it runs for every remote player on every predicted and re-simulated tick, and must give the same guess
	// for the same arguments. Measure before adopting one: `predict-stats` (src/headless/README.md) scores it on a
	// recorded log.
	predict_input:         proc(last: Input, ticks_ahead: u32) -> Input,
}

// The command union of a game that has no commands: sim.Game(State, Input, World, Event, sim.No_Commands, ...).
No_Commands :: union {}

// The World of a game that keeps nothing outside the block: sim.Game(State, Input, sim.No_World, ...).
No_World :: struct {}

// The Setup of a game whose sessions differ only by seed: sim.Game(..., Cmd, sim.No_Setup, Profile, ...).
// Zero bytes everywhere.
No_Setup :: struct {}

// The Profile of a game whose players choose nothing before joining: sim.Game(..., Setup, sim.No_Profile, PLAYERS)
// and sim.Players(T, sim.No_Profile, Input, PLAYERS). Zero bytes everywhere: the State keeps no Profile.
No_Profile :: struct {}

@(private)
MIN_RING_SIZE :: 10
MAX_RING_SIZE :: 32

// The ring keeps about 250 ms of ticks at any rate: 16 at 64 Hz, 32 at 128. It bounds rollback: the netcode predicts
// at most ring_size - 2 ticks ahead, so below 40 Hz the floor keeps that cap at 250 ms or more (10 at 32 Hz, a cap of
// 8): at 32 Hz two ticks are 62 ms, and a ring of 250 ms left a cap of 188, short of a lossy path's round trip.
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
	draws:  Debug_Draws, // drawn by the step that produced `tick` (dev.odin)
}

// A running simulation of game G (create, from_snapshot; destroy): the tick counter, the block, the World, the Extra
// and the ring of saved ticks. Read `tick` and `state` directly; change them only through step, restore and save.
Sim :: struct($G: typeid) where intrinsics.type_is_specialization_of(G, Game) {
	game:         ^G,
	seed:         u64,
	setup:        part(G, GAME_SETUP), // the session's, fixed at create: outside the block, never rolled back
	content_hash: u64, // content_hash(game.levels): recorded in input logs and snapshots
	compat:       u64, // compat_of(game): recorded in snapshots
	layout:       u64, // layout_hash(State): recorded in snapshots (a constant of the type, derived once)
	tick:         u32,
	state:        part(G, GAME_STATE),
	world:        ^part(G, GAME_WORLD),
	extra:        Extra, // the game's (Game.extra; zero: none)
	ring:         []Ring_Slot(part(G, GAME_STATE)), // ring_size(game.tick_hz) slots, allocated at create
	changes:      Changes_Buffer(part(G, GAME_PLAYERS)), // the step's joins and leaves (Tick.player_changes)
	commands:     Commands(part(G, GAME_CMD)), // the step's commands, decoded (Tick.commands)
	input_check:  Wire_Check, // the Input's wire rules, compiled: step checks each slot's with it (inputs_as_read)
	read_inputs:  Inputs(G), // a step's inputs as read when one slot's Input needed it (inputs_as_read)
	// Checksum input: tick, block bytes, then each Extra's bytes. Hashed one-shot, because
	// core:hash/xxhash's streaming XXH3 (dev-2026-11) returns wrong digests for some lengths.
	hash_buf:     [dynamic]u8,
	kept:         []Kept_Tick(part(G, GAME_STATE)), // KEEP_SLOTS, allocated by the first snapshot_keep
	dev:          ^Dev, // draws and zones (dev_attach; nil: none)
}

// XXH3-64 (seed 0), one-shot.
hash_bytes :: proc(bytes: []u8) -> u64 {
	if len(bytes) == 0 {
		none: [1]u8 // core:hash/xxhash asserts on a nil pointer, even for zero bytes
		return xxhash.XXH3_64_default(none[:0])
	}
	return xxhash.XXH3_64_default(bytes)
}

// The game build's identity for netcode (Hello's compat): the state, input, inputs and Setup layouts (the Profile's
// is in the State's and the inputs'), the command and event types, the player count, the tick rate, the game's name (each variant, e.g. a
// tuning, has its own) and version, the library's (LIBRARY_VERSION) and the unified-box3d pin (box3d_pin):
// `library` overrides those two (tests: another build's compat; zero fields: this build's). Two builds with the same value run
// the same simulation, as far as the build can tell. Every level's hash goes in too (content_hash), so peers with
// different levels refuse to play together, and nothing is checked when a session changes level.
compat_of :: proc(game: ^$G, library := Library{}) -> u64 where intrinsics.type_is_specialization_of(G, Game) {
	return compat_with(game, layout_hash(part(G, GAME_STATE)), library)
}

// compat_of for a caller that has the State's layout hash already (create, from_snapshot): one RTTI walk fewer.
@(private)
compat_with :: proc(
	game: ^$G,
	state_layout: u64,
	library: Library,
) -> u64 where intrinsics.type_is_specialization_of(G, Game) {
	Input :: part(G, GAME_INPUT)
	Event :: part(G, GAME_EVENT)
	Cmd :: part(G, GAME_CMD)
	PLAYERS :: part(G, GAME_PLAYERS)
	Ids :: struct {
		state, input, inputs, name, version, content, commands, events, box3d, setup: u64,
		// dev: 1 when this build applies the union's dev commands (sim.DEV and it has some): a public build and a dev
		// build of a game with dev commands compute differently, so they refuse each other
		players, tick_hz, library, dev:                                               u32, // no padding: hashed as bytes
	}
	ids := Ids {
		state    = state_layout,
		input    = layout_hash(Input),
		inputs   = layout_hash(Inputs(G)),
		name     = hash_bytes(transmute([]u8)game.name),
		version  = hash_bytes(transmute([]u8)game.version),
		content  = content_hash(game.levels),
		commands = union_hash(Cmd, COMMAND_PREFIX),
		events   = union_hash(Event, EVENT_PREFIX),
		box3d    = hash_bytes(transmute([]u8)(library.box3d != "" ? library.box3d : box3d_pin())),
		setup    = layout_hash(part(G, GAME_SETUP)), // its layout: the value travels (Welcome, the log, snapshots)
		players  = u32(PLAYERS),
		tick_hz  = u32(game.tick_hz),
		library  = library.version != 0 ? library.version : LIBRARY_VERSION,
		dev      = DEV && has_dev_commands(Cmd) ? 1 : 0,
	}
	return dmath.max(hash_bytes(([^]u8)(&ids)[:size_of(Ids)]), 1) // never 0 ("any")
}

// Whether two ticks' inputs are the same for the simulation: the same slots present, the same join records with the
// same Profiles, the same input bytes (what the checksum sees: -0.0 and +0.0 differ, a NaN equals itself) and the same
// commands. `replaced` is informational and not compared, nor is a Profile beside no join record.
inputs_same :: proc(a, b: ^Inputs($G)) -> bool {
	Input :: part(G, GAME_INPUT)
	Profile :: part(G, GAME_PROFILE)
	PLAYERS :: part(G, GAME_PLAYERS)
	if a.present != b.present ||
	   a.joins != b.joins ||
	   a.command_count != b.command_count ||
	   runtime.memory_compare(&a.input, &b.input, size_of([PLAYERS]Input)) != 0 {
		return false
	}
	when size_of(Profile) > 0 {
		for slot in 0 ..< PLAYERS {
			if a.joins[slot] != 0 &&
			   runtime.memory_compare(&a.profiles[slot], &b.profiles[slot], size_of(Profile)) != 0 {
				return false
			}
		}
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

// The identity of a game's levels (Game.levels): XXH3 over each level's name hash and bytes hash, in order, 0 for
// none. Every level's name, bytes and place count.
content_hash :: proc(levels: []Level_File) -> u64 {
	if len(levels) == 0 do return 0
	hashes := make([]u64, 2 * len(levels), context.temp_allocator)
	for file, i in levels {
		hashes[2 * i] = hash_bytes(transmute([]u8)file.name)
		hashes[2 * i + 1] = hash_bytes(file.bytes)
	}
	return hash_bytes(([^]u8)(raw_data(hashes))[:len(hashes) * size_of(u64)])
}

// Why a game can't run ("" when it can; temp-allocated): its tick rate, its State (plain data: plain_violation), its
// Input (wire_violation), its command and event unions, its Setup and Profile (plain structs without padding, at most
// SETUP_MAX and PROFILE_MAX bytes), its default Setup (Game.setup must read as sent: setup_violation) and its levels
// (levels_violation). create panics with it; the Godot host reports it. What the compiler can check (the State's `players`, the library's events
// in the Event union) doesn't compile instead.
game_violation :: proc(game: ^$G) -> string where intrinsics.type_is_specialization_of(G, Game) {
	State :: part(G, GAME_STATE)
	Input :: part(G, GAME_INPUT)
	Cmd :: part(G, GAME_CMD)
	Event :: part(G, GAME_EVENT)
	Setup :: part(G, GAME_SETUP)
	Profile :: part(G, GAME_PROFILE)
	reason := declaration_violation(game.name, game.tick_hz, type_info_of(State), type_info_of(Input), Cmd, Event)
	if reason != "" do return reason
	if reason = levels_violation(game.name, type_info_of(State), game.levels); reason != "" do return reason
	setup := game.setup
	return choices_violation(game.name, type_info_of(Setup), type_info_of(Profile), &setup)
}

// Why a Setup can't be a session's ("" when it can; temp-allocated): it does not read as sent, as every peer reads
// bytes from another machine (src/sim/README.md, Bytes from another machine): an enum outside its declared values, a
// float that is not finite, a bool byte other than 0 or 1, a bit_set bit of no element. Such a Setup is refused
// everywhere (create panics; a client, a log and a snapshot refuse it), never zeroed: a zeroed Setup would play
// another session than the host's.
setup_violation :: proc(
	game: ^$G,
	setup: ^$S,
) -> string where intrinsics.type_is_specialization_of(G, Game) &&
	S == part(G, GAME_SETUP) {
	return choice_reads(setup, type_info_of(S))
}

// game_violation's Setup and Profile part, for the types at run time (a non-generic home for its imports: -vet).
@(private)
choices_violation :: proc(name: string, setup, profile: ^runtime.Type_Info, default_setup: rawptr) -> string {
	if reason := choice_violation(setup, SETUP_MAX); reason != "" {
		return fmt.tprintf("%s: the Setup %s", name, reason)
	}
	if reason := choice_violation(profile, PROFILE_MAX); reason != "" {
		return fmt.tprintf("%s: the Profile %s", name, reason)
	}
	if reason := choice_reads(default_setup, setup); reason != "" {
		return fmt.tprintf("%s: Game.setup %s", name, reason)
	}
	return ""
}

// Why a type can't be a Setup or a Profile ("" when it can): it is a plain struct (bools and f32 allowed) without
// padding, of at most `max_size` bytes.
@(private)
choice_violation :: proc(type: ^runtime.Type_Info, max_size: int) -> string {
	if _, is_struct := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct); !is_struct {
		return fmt.tprintf("%v is not a struct", type.id)
	}
	if reason := plain_violation(type, fmt.tprint(type.id)); reason != "" {
		return fmt.tprintf("is not plain data: %s", reason)
	}
	if type.size > max_size {
		return fmt.tprintf("%v has %d bytes (at most %d)", type.id, type.size, max_size)
	}
	return ""
}

// Whether a Setup or Profile at `data` reads as sent ("" when it does, else why).
@(private)
choice_reads :: proc(data: rawptr, type: ^runtime.Type_Info) -> string {
	changed, rejected := wire_fix(data, type, .Command, apply = false)
	if rejected do return "holds an enum outside its declared values or a float that is not finite"
	if changed do return "holds a bool that is neither 0 nor 1 or a bit_set bit of no element"
	return ""
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
	if reason := clock_violation(state); reason != "" {
		return fmt.tprintf("%s: %s", name, reason)
	}
	if reason := plain_violation(state, fmt.tprint(state.id)); reason != "" {
		return fmt.tprintf("%s: the State is not plain data: %s", name, reason)
	}
	if reason := wire_violation(input, fmt.tprint(input.id)); reason != "" {
		return fmt.tprintf("%s: the Input can't be sent between machines: %s", name, reason)
	}
	if reason := union_violation(commands, 0, COMMAND_MAX, COMMAND_PREFIX); reason != "" {
		return fmt.tprintf("%s: commands: %s", name, reason)
	}
	if reason := union_violation(events, 1, EVENT_MAX, EVENT_PREFIX, padding = true); reason != "" {
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

// Creates the World and the tick-0 state, allocates the ring and saves tick 0 into it: `create(&GAME, seed)` plays the
// game's default Setup (Game.setup), `create(&GAME, seed, Setup{...})` this session's (a Setup of another type does not
// compile). The World gets the game's levels (Game.levels).
create :: proc {
	create_default,
	create_with_setup,
}

// create with the game's default Setup (Game.setup).
create_default :: proc(game: ^$G, seed: u64) -> ^Sim(G) where intrinsics.type_is_specialization_of(G, Game) {
	return create_with_setup(game, seed, game.setup)
}

// create with this session's Setup; panics when it does not read as sent (setup_violation: a caller holding bytes
// from another machine asks first).
create_with_setup :: proc(
	game: ^$G,
	seed: u64,
	setup: $S,
) -> ^Sim(G) where intrinsics.type_is_specialization_of(G, Game) &&
	S == part(G, GAME_SETUP) {
	State :: part(G, GAME_STATE)
	Input :: part(G, GAME_INPUT)
	if reason := game_violation(game); reason != "" {
		panic(reason)
	}
	checked := setup
	if reason := setup_violation(game, &checked); reason != "" {
		panic(fmt.tprintf("%s: the session's Setup %s", game.name, reason))
	}
	simulation := new(Sim(G))
	simulation.game = game
	simulation.seed = seed
	simulation.setup = setup
	simulation.content_hash = content_hash(game.levels)
	simulation.layout = layout_hash(State)
	simulation.compat = compat_with(game, simulation.layout, {})
	simulation.input_check = wire_check_make(type_info_of(Input))
	simulation.ring = make([]Ring_Slot(State), ring_size(game.tick_hz))
	for &slot in simulation.ring {
		// Grows under create's allocator, whatever is active then; room for a usual tick's events up front, so the
		// session thread doesn't allocate the first time a ring slot gets some.
		slot.events.list = make([dynamic]Raw_Event, 0, 8)
	}
	simulation.hash_buf = make([dynamic]u8)
	simulation.world =
		game.world_create(seed, game.levels, setup) if game.world_create != nil else new(part(G, GAME_WORLD))
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
		delete(slot.draws.shapes)
		delete(slot.draws.text)
	}
	delete(simulation.ring)
	dev_destroy(simulation.dev)
	delete(simulation.hash_buf)
	wire_check_destroy(&simulation.input_check)
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
	builtin.clear(&slot.events.list)
	started := dev_step_begin(simulation.dev, &slot.draws)
	tick := make_tick(simulation, number, read, &slot.events)
	clock_step(&tick)
	changes := &simulation.changes
	players_update(&tick, changes)
	tick.player_changes = {
		arrived = changes.arrived[:changes.arrived_count],
		joined  = changes.joined[:changes.joined_count],
		left    = changes.left[:changes.left_count],
	}
	commands_decode(&simulation.commands, read)
	simulation.game.tick(&tick)
	dev_step_end(simulation.dev, started)
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
	if !simulation.input_check.any do return inputs
	for &input in inputs.input {
		if !wire_reads_as_sent(&simulation.input_check, &input) {
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
		setup    = simulation.setup,
		dt       = 1 / f32(simulation.game.tick_hz),
		tick_hz  = simulation.game.tick_hz,
		inputs   = inputs,
		events   = events,
		commands = &simulation.commands,
		dev      = simulation.dev,
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

// Restores the saved state of `tick`; false, changing nothing, when the ring no longer holds it or holds it unsaved
// (step(save = false)). The extra goes first: if it fails, the block and the tick are left as they were and false
// comes back (the caller treats the sim as broken). The later ticks leave the ring: they are another timeline's until
// they are stepped again.
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
	builtin.clear(&simulation.hash_buf)
	tick := transmute([4]u8)u32le(simulation.tick)
	builtin.append(&simulation.hash_buf, ..tick[:])
	builtin.append(&simulation.hash_buf, ..([^]u8)(&simulation.state)[:size_of(simulation.state)])
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
