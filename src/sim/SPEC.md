# `unified:sim`: the deterministic harness

Status: signed off 2026-11-18 (#331)

A game is a function `tick(state, inputs) → next state`. Every machine that starts from the same bytes and applies
the same inputs computes the same bytes; rollback, replays, late join and desync detection follow from that. This
package is the harness that runs it. Arithmetic: `src/dmath/SPEC.md`. Bytes: `src/wire/SPEC.md`. Box3D as rollback
state: `src/physics/SPEC.md`. What tick code may not use: `src/lint/SPEC.md`.

## The game type

A game names its six types once; everything generic over a game takes that one type:

```odin
Game :: sim.Game(State, Input, World, Event, Cmd, PLAYERS)
Tick :: sim.Tick(Game)

GAME := Game{name = "coins", version = "1", tick_hz = 64, tick = tick, scripted_input = scripted_input}
```

- `State`, **the state block**: one plain-data struct: sized integers (not `int`, `uint` or `uintptr`), `f32` (no
  other float), bools, enums and bit_sets with a sized backing integer, fixed arrays, nested structs; no pointers,
  slices, maps or unions; no implicit padding (gaps are explicit `_pad` fields). Its memory is its canonical
  little-endian serialization: a snapshot is a copy, the checksum hashes its bytes. It holds the session's players
  in a field named `players` (Players, below).
- `Input`, one player's **input** for one tick: plain data **without bools or floats**. It comes from another
  machine and is compared and logged as raw bytes: a bool's byte may hold neither 0 nor 1 there (use a bit_set), a
  float may be a NaN (quantize: `dmath.axis_i8`, a `dmath.Dir2` / `Dir3`). Enums and bit_sets are fine: `tick` reads
  an enum outside its declared values as its zero value and a bit_set without the bits of no element, on every peer
  alike (the caller's `Inputs` stay as sent). The netcode may repeat or substitute
  it, so it is the controls' state, never a one-shot: buttons are a bit_set field named `buttons` holding what is
  down, and `buttons(t, player)` gives `down`, `pressed` and `released` against the slot's input of the tick before
  (`input_before(t, player)`). A one-shot value is a command.
- `World`: everything outside the block (the Box3D world, level geometry, scratch); `sim.No_World` for a game with
  none. **It holds only what `world_create` builds and what the Extra rolls back**: anything else in it that affects
  `tick` diverges after a rollback, unhashed. The sync-tests (`scenarios.rollback_every_tick`, `headless.Run`) fail
  on the tick such state shows.
- `Event` and `Cmd`: the event and command unions (below; `sim.No_Commands` for a game without commands). `emit`,
  `send_command` and the command loop check their variant at compile time.
- `PLAYERS`: the number of input slots, 1..32.

`sim.Game` itself is the descriptor: `name`, `version` (bump it when `tick` computes differently without a layout
change: a rule, a constant), `tick_hz` (a power of two, 32..128; `dt = 1/tick_hz` exactly), `tick(t)`, and the
optional `content` (the level the game ships with, `src/level/SPEC.md`: `#load`ed once in the sim package; below),
`world_create(seed, content)` (nil: a zeroed World), `world_destroy` (nil: `free`), `extra(world)` (the World's
rollback state: physics games return `physics.extra(world.phys, State)`), `init(t)` (tick 0: the block is zeroed
before, nobody is present; it may emit, roll and create bodies), the **scripted player** `scripted_input(seed, slot,
tick, state) -> Input` and `scripted_commands(seed, slot, tick, state, out)`, and `bench_prepare(state, world,
count)` (fill the tick-0 state with `count` entities and hold that population: the headless `bench`, Godot's `--bench
N`, single player only). The last three are never called by the sim: tests, benchmarks, headless runs and Godot's
`--scripted` sessions play with them. A game without a scripted player plays zero Inputs. A script that answers from
(seed, slot, tick) alone gives every client and every offline run the same player: `script_bits(seed, slot, tick,
period)` is a hash that holds for each `period`-tick block.

**Content.** `GAME.content` is the default wherever content is taken: `create`, `compat_of` and `from_snapshot`
given none (nil) use it (`game_content(&GAME, content)`), so the Godot host, the netcode, the headless runs and the
suites all play the level the game ships with. Other bytes override it: a test's own level, the headless `--level
FILE` (a copy of the game with that content). A re-baked level rebuilds the extension (`uni` counts the `.level`
file as an input).

`game_violation(&GAME) -> string` is "" when the game can run, else why: its tick rate, State (`plain_violation`),
Input (`wire_violation`) and both unions. `create` panics with it; the Godot host reports it. What the compiler can
check does not compile instead: a State without `players` (or one for another Input or `PLAYERS`), an Event union
without the library's join and leave events.

Generic library code takes `$G` and names a part with `part(G, GAME_STATE)` (`GAME_INPUT`, `GAME_WORLD`,
`GAME_EVENT`, `GAME_CMD`, `GAME_PLAYERS`). Odin refuses `part` in a parameter list, so parameters are structs built
from `G` (`^Sim(G)`, `^Tick(G)`, `^Inputs(G)`). Passing something that is not a `sim.Game` (`sim.Tick(State)`) gives a
where-clause error followed by a cascade of `part` errors: read the first.

**Time.** A time constant is written in seconds and converted, never written as raw ticks:
`RESPAWN_TICKS :: u16(RESPAWN_S * TICK_HZ)` (Odin refuses a constant conversion that truncates, so a time that is
not a whole number of ticks does not compile). From data at run time: `ticks(seconds, tick_hz) -> u32` (nearest,
clamped to 0..max(i32)); for views: `seconds(count, tick_hz) -> f32`. Inside `tick`, `t.dt`.

`compat_of(&GAME, content) -> u64` is the build's identity for the netcode, input logs and snapshots: the layouts
of `State`, `Input` and `Inputs` (field names included), the unions, `PLAYERS`, `tick_hz`, `name`, `version`, the
content hash, `LIBRARY_VERSION` (bumped by hand per the `sim-change` skill) and `box3d_pin()` (the `[box3d] tag` of
`pins.cfg`). `Library{version, box3d}` computes another build's (tests).

## The tick

`tick :: proc(t: ^Tick)` advances the state from tick `number - 1` to `number`. The harness builds the `Tick`:
`state`, `world`, `number`, `seed`, `dt`, `inputs`, `events`, `player_changes`, and the decoded commands. Per-tick
helpers take it (`input`, `buttons`, `commands`, `emit`, `roll_below`, `player_data`, ...). Odin's implicit
`context` carries no sim data.

`Inputs(G) = {present, replaced, input: [PLAYERS]Input, joins: [PLAYERS]u16, commands}`, by slot. `present`
(`Slots`, a `bit_set[0 ..< 32; u32]`) is which slots are in the game this tick: joining and leaving are presence
changes the relay decides, never flags in `Input`. `joins` holds each slot's **join record**: the relay's member id
of who becomes present there, non-zero only on that tick. `replaced` marks inputs the relay substituted
(informational, for tools and stats: a peer that predicted the tick right steps it without the mark, one catching
up or replaying the log with it, so the lint bans reading it in tick code). `inputs_same(a, b)`: the same presence, join records, input bytes and
commands.

## Players

A **slot** is an input index `0 ..< PLAYERS`. A **player** is a `Player` handle naming a session **member**, the
person: who leaves and comes back gets the same handle back in whatever slot is free, with everything keyed by it.
An **account** (EOS id, a LAN token) is host-side only, never in State, Inputs, logs or snapshots
(`src/netcode/SPEC.md`, Members).

```odin
State :: struct {..., players: sim.Players(Player_Data, Input, PLAYERS), ...}
Event :: union {sim.Event_Player_Joined, sim.Event_Player_Left, ...}

tick :: proc(t: ^Tick) {
	for player in t.player_changes.left do destroy_ship(t, player)
	for player in t.player_changes.arrived do spawn_ship(t, player) // new or back, in slot order
	players := sim.iterate_present(t)
	for ship, player in sim.next(&players) {
		if .Fire in sim.buttons(t, player).pressed {...}
		for sent in sim.commands(t, player) {...}
	}
}
```

- `Players(T, Input, PLAYERS)` holds the member table (2 x PLAYERS people: `MEMBERS_PER_SLOT`), who holds each slot,
  each slot's input of the tick before, and the game's `T` per member. `T` and the block stay padding-free.
- **Before `tick`** the harness applies the presence: first the leaves (a held slot no longer present, or present
  with another member's join record), then the joins in slot order (a slot that becomes present with a join record;
  **a slot present without one stays absent**). A known member returns with its data intact; a new one gets a zeroed
  `T` in the first free entry, else the entry of the **longest-absent** member, which is forgotten: its handles go
  stale and, if that person comes back, they are new. A member who left on this tick is never forgotten on it, so its
  handle in `t.player_changes.left` still names its data while the game cleans up. A member already present
  elsewhere moves (the newest connection). It fills `t.player_changes` (`arrived`: everyone present from this tick;
  `joined`: those of them who are new; `left`) and emits `Event_Player_Joined{player, slot, returning}` and
  `Event_Player_Left{player, slot}` before the game's events.
- **After `tick`** it keeps each held slot's input as `before` (zero for an empty slot and when the holder changes):
  it is state, so a rollback restores it and a predicted repeat never reads as a press.
- **The library reports; the game decides** what an absent player's things do: an owner is a `Player`, never a
  slot. An absent member's `T` owns nothing outside the block (a body is destroyed at the leave and made again on the
  return), since the table may forget it before any `tick` runs.
- Queries take the tick or a `Players` (views, tests), `iterate_present(t)` included: `player_data(t, player) -> ^T` (nil when nobody, stale or
  forgotten; valid while absent), `player_slot(t, player) -> (slot, present)` (`slot := ...` is fine: -1 when
  absent), `player_present`, `player_in_slot(t, slot)` (also on a `^Sim`, for drivers outside `tick`),
  `present_count(t)`, `player_known(&players, player)`; `iterate_present` (slot order) and `iterate_known` (member
  order) with `next`; `input(t, player)` (zero when absent), `input_before`, `buttons`, `commands`.
  `player_key(player) -> u64` (0 for nobody) names a player to views and GDScript; `player_of_key` reverses it.
- `slot_data(t, slot) -> ^T` (also on a `^Players` or a `^Sim`): the data of whoever holds the slot (nil: nobody), a
  HUD's row or a test's look at a slot.
- Join records come from the relay. Tests, tools and bots write them with `seat(&inputs, sim_or_players, slot,
  member)`: the slot present, with a join record only when someone else holds it in the state the tick steps from (so
  a slot is never present without one by mistake); `join(&inputs, slot, member)` writes one as it is. Scripted runs
  give slot i member i + 1; `headless.Run` keeps who sits where (`run_seat`).

## Commands

A one-shot action (pick an upgrade, start the match) is delivered exactly once, in order, per player.

```odin
Cmd_Drop_Coin :: struct {value: u8}                 // any plain struct, 1..64 bytes
Cmd :: union {Cmd_Drop_Coin, Cmd_Start}             // kind = variant index; name = type name without Cmd_, lowercased

for sent in sim.commands(t, player) {               // this player's, in order, exactly once each
	switch command in sent {
	case Cmd_Drop_Coin: ...
	}
}
```

- A command is **input, not state**: part of the tick's record, so it is logged, replayed and sent to late joiners;
  never in the block. On the wire and in the log it is its kind and its struct's bytes (`Raw_Command{kind, slot,
  size, data}`).
- The harness decodes a tick's commands once, before `tick`. `commands(t, player)` never holds a nil entry: one whose
  bytes don't decode (an unknown kind, a wrong size from the network) is left out on every peer alike.
- The union is checked like the block (plain, no padding, 1..64 bytes, at most 255 variants, names unique; not
  `#no_nil` or `#shared_nil`). Decoding reads a command as it came from another machine: each bool as 0 or 1, each
  bit_set without the bits of no element, and a command whose enum field holds an undeclared value or whose float is
  not finite (a NaN, an infinity) is left out on every peer alike, as an undecodable one. Names: command types
  `Cmd_<Name>`, event types `Event_<Name>`; the names and Godot classes leave the prefix out (`drop_coin`,
  `CommandDropCoin`).
- A tick holds at most `COMMANDS_PER_SLOT` of one slot and `TICK_COMMANDS` in all, inline in `Inputs`, so a record
  has a fixed size and fits a datagram; more wait for the next tick, in order. Tests and tools add one to a tick's
  record with `add_command(&inputs, slot, value) -> bool`, typed by the game's `Cmd` (or `add_command(&inputs, raw)`).
- Sources send into a `Command_Out(Cmd)`: `send_command(out, value) -> bool` (false: its `cap` reached).
  `command_make(Cmd, value)` builds a raw one. Delivery: `src/netcode/SPEC.md`.

## Events

Events tell the view what happened (a shot, a pickup). They are not state: not in the block, not hashed. One struct
per event (≤ 64 bytes) and a union of them; plain data like the block except that padding is allowed (events are
never hashed or compared as bytes). An event never has a field named `tick`, `kind` or `id`: every event carries
those already (`game_violation` refuses them).

```odin
Event_Coin_Picked :: struct {coin: sim.Handle(Coin), player: sim.Player, position: sim.Position, value: u32}
sim.emit(t, Event_Coin_Picked{coin = handle, player = player, position = {x, y, 0}, value = coin.value})
```

A thing that is not a table's item (a level marker, an item of a fixed array) is named in events by an `Entity`
(`distinct u64`): `entity(index)`, `entity_index(e) -> (index, ok)`; its zero value is none, so index 0 is a thing.
The Godot host routes an event to the views keyed by its first handle's key or its first `Entity`'s index
(`src/godot/SPEC.md`), found by type, whatever the field's name.

Each tick's events are kept in the ring as kind + bytes (`Raw_Event`) and emitted again when the tick is
re-simulated. `events_at(simulation, tick)` reads them back in emission order, `event_value(&raw, Event)` makes one
the union again (nil for a kind out of range or a wrong size), `event_names(Event)` names them. How the view
matches and routes them: `src/godot/SPEC.md`.

## Tables and handles

- `Table(T, N)`: `items`, `slots` (generation, alive, free-list link), `free_head`, `high_water` (one past the highest
  slot in use), `count`. The zero value is empty. Indices are stable (no swap-remove); a freed slot is zeroed (equal
  states hash equal) and reused last-in-first-out.
- `Handle(T) = {index, generation}`, typed. Generation 0 is never live, so `Handle{}` is null. `get(&table, handle)`
  is nil for a stale, null or out-of-range handle.
- `spawn(&table) -> (^T, Handle(T), ok)` (false: full), `despawn(&table, handle) -> bool`, `despawn_all(&table)`
  (what a reset does: every item goes, each slot keeps its generation, spawns start again from slot 0, and no old
  handle names a new item; zeroing the table instead resets the generations, so keys repeat).
  `handle_key(handle) -> u64` is unique among a table's live and past items (view keys, physics tags);
  `handle_of_key(T, key)` reverses it.
- **Walking** a table, in index order:

  ```odin
  coins := sim.iterate(&t.state.coins)
  for coin, handle in sim.next(&coins) { ... }
  ```

  Despawning the current item is safe. The walk covers the slots in use when it started: an item spawned during it
  is visited only when it reuses a free slot ahead of the walk.

## Random numbers

Two kinds, on SplitMix64's mixing function, integer-only:

- **Keyed rolls**, nothing in the block: `roll_below(t, n, purpose, key := 0, index := 0)` and `roll_f32` hash (seed,
  tick number, purpose, key, index); `purpose` is a value of the game's own enum. A roll depends only on what it
  names, so adding or reordering one system's rolls never moves another's; two rolls that should differ must differ
  in something (in a loop, the index). **The sim's own draws are keyed rolls.**
- **`Rng`**, one stream (`rng_seed`, `rng_next`, `rng_below` unbiased, `rng_f32` with 24 bits): for code outside
  `tick` that wants "the next number". A draw added anywhere shifts every later one.

## The harness

`Sim(G)` holds the tick counter, the block, the World, the Extra and a ring of saved ticks (the block, the Extra's
save, the events). Ticks count from 1; tick 0 is the initial state.

- `create(&GAME, seed, content = nil)` (World, Extra, `init`, tick 0 saved; nil content: `GAME.content`), `destroy`.
- **The ring** keeps about 250 ms at any rate: `ring_size(tick_hz) = tick_hz / 4` (8..32 slots), allocated at
  `create`. It bounds rollback: the netcode predicts at most ring − 2 ticks ahead.
- `step(simulation, &inputs, save := true)` builds the `Tick`, applies the presence, runs `tick` and saves. `save =
  false` keeps the tick's events but not its state (a tick nothing will roll back to): `events_at` answers for it,
  `state_at`, `restore` and `snapshot_encode` don't. `save(simulation)` saves the current tick again (a test that
  changed it). `restore(simulation, tick)` (the Extra first: on failure the block and tick are untouched; false when
  the tick is no longer in the ring), `state_at`, `events_at`.
- `checksum(simulation)`: XXH3-64, one-shot (Odin's streaming XXH3 is wrong for some lengths), over the tick (u32 LE),
  the block, then the Extra's bytes. Peers compare it on finalized ticks.
- **Extra**: rollback state outside the block, at most one per game (a game with two kinds composes them). The
  harness asks `Game.extra` for it right after `world_create`, so bodies made there are the World's. Its `tick_hz`
  is the rate it steps at (physics: `Settings.tick_hz`; 0: none): `create` refuses one other than the game's
  (`extra_violation`). `save` and
  `restore` take the ring slot; `hash(tick, out)` covers the whole internal state on multiples of
  `DEEP_CHECKSUM_EVERY` (the ticks the netcode compares) and may cover less otherwise; `image(slot, live)` and
  `load(bytes)` are its portable form (`live`: the slot is the current tick's, saved after its last change, so the
  live state may be imaged as it is); optional `keep(slot, index)` and `image_kept(index)` together (a slot's save
  copied aside, imaged later: `snapshot_keep`); optional `size(slot)` (what a slot's save holds) and
  `check(state) -> string` ("" when it agrees with the block, else why: physics' broken refs and orphaned bodies).
  `check_extra(simulation)` runs the check; the sync-tests run it after every restore. `save_size` and
  `snapshot_size` measure a tick's save and its portable image.

## Files

Readers accept only the current version of each format (`LOG_VERSION`, `SNAP_VERSION`): bump it on any change to
what the bytes hold. The byte layouts are in the headers of `log.odin` and `snapshot.odin`.

- **Input log** (`UNIL`): seed, content hash, the recording build's compat, then each tick's presence, inputs,
  commands and join records. Seed + content + log is the whole session. `Input_Log(G)` in memory: `log_append`,
  `log_inputs(&log, k)` (tick k + 1), `log_encode`, `log_decode(bytes, G)`; decoding refuses a malformed tick, but a
  recording that never ended (a stopped relay's) keeps its whole ticks and leaves out a cut last one. A recording
  grows through a `Log_Stream` into a `Log_Sink` (`log_sink_memory`; `headless.log_sink_file`). File I/O is
  `unified:headless`'s (`log_write`, `log_read`): this package touches no files.
- **Portable snapshot** (`UNIS`): seed, content hash, tick, `layout_hash(State)`, the build's compat, a payload digest,
  the block, the Extra's image. `snapshot_encode(simulation, tick)` (`snapshot_encode_into` reuses a buffer),
  `snapshot_keep(simulation, tick, index)` (a ring tick copied into one of `KEEP_SLOTS` keep slots: the block and,
  through the Extra's `keep`, its save; an Extra without it is imaged at once) and `snapshot_encode_kept(simulation,
  index, out)` (the bytes `snapshot_encode` gave for that tick, after the ring moved on),
  `from_snapshot(&GAME, bytes) -> (^Sim, Snap_Error)`: `Bad_Header`, `Layout_Differs`, `Content_Differs`,
  `Build_Differs` (the same layout, another compat), `Checksum_Mismatch`, `Extra_Rejected`. The library never prints.
- `snapshot_diff(State, a, b) -> string`: what differs between two snapshots of one build, down to the leaf field
  ("tick 4160: enemies[12].pos.x 3.25 vs 3.5", a table read by item index), then the Extra's image by its first
  differing byte: the typed desync report. `events_diff(a, b, Event) -> string`: the same for two lists of one tick's
  events (count, kinds, fields; padding aside), what the sync-test compares a re-simulated tick's events with.
- `find_nan(simulation, &floats) -> string`: where a NaN is in the block ("tick 40: enemies[12].pos.x is a NaN
  (ffc00000)"; "": none), the State's float offsets kept in `floats` after the first call. No NaN may reach the
  block (`src/dmath/SPEC.md`); the sync-test (`headless.Run`) runs it after every forward tick.
