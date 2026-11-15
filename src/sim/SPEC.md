# `unified:sim`: the deterministic harness

Reviewed with the developer in the #6 sitting and signed off (2026-11-14, #166); the code follows it since the
sitting's follow-up PR.

A game is a function `tick(state, inputs) → next state`. Every machine that starts from the same bytes and applies
the same inputs computes the same bytes; rollback, replays, late join and desync detection follow from that. This
package is the harness that runs it. Arithmetic: `src/dmath/SPEC.md`. Bytes: `src/wire/SPEC.md`. Box3D as rollback
state: `src/physics/SPEC.md`. What tick code may not use: `src/lint/SPEC.md`.

## What a game supplies

Four compile-time types and a descriptor, `sim.Game(State, Input, World, PLAYERS)`:

- `State` **the state block**: one plain-data struct (integers, floats, bools, enums, bit_sets with an explicit
  backing integer, fixed arrays, nested structs; no pointers, slices, maps or unions; no implicit padding: gaps are
  explicit `_pad` fields). Its memory is its canonical little-endian serialization: a snapshot is a copy, the
  checksum hashes its bytes. `create` checks it by an RTTI walk (`plain_violation`) and panics with the reason.
- `Input` one player's **input** for one tick, plain data. The netcode may repeat or substitute it, so a one-shot
  action is never an `Input` field: it is a command.
- `World` everything outside the block (the Box3D world, level geometry, scratch). **The World holds only what
  `world_create` builds and what an `Extra` rolls back.** Anything else in it that affects `tick` diverges after a
  rollback, unhashed. Every game's suite runs `scenarios.rollback_every_tick` (restore 8 ticks back on every tick,
  re-simulate, compare each checksum with the forward run), which fails offline on the tick such state shows.
- `PLAYERS` the number of player seats, 1..32. A **player** is a seat index `0 ..< PLAYERS`; people join and leave,
  the seat stays.
- `Game`: `name`, `version` (bump when `tick` computes differently without a layout change: a rule, a constant),
  `tick_hz` (a power of two, 32..128; `dt = 1/tick_hz` exactly), `world_create(seed, content)` (`content`: the
  level file's bytes, `src/level/SPEC.md`; empty when the game has none), `world_destroy`, `extras(world)`,
  `init(state, world, seed)` (tick 0; the block is zeroed before), `tick(tick: ^Tick)`, `events` (the event union,
  below), `commands` (the command union, below), `min_input_delay` (the least input delay the netcode gives a
  player, in ticks; 0: 1; `src/netcode/SPEC.md`, Timing).
- `compat_of(&GAME, content) -> u64`: the build's identity for the netcode (the layouts of `State`, `Input` and
  `Inputs`, the command and event types, `PLAYERS`, `tick_hz`, `name`, `version`, the content hash).

Odin can't derive one generic type from another, so a game declares its aliases once:

```odin
Game :: sim.Game(State, Input, World, PLAYER_COUNT)
Simulation :: sim.Sim(State, Input, World, PLAYER_COUNT)
Tick :: sim.Tick(State, Input, World, PLAYER_COUNT)
```

## The tick

`tick :: proc(tick: ^Tick)` advances the state from tick `number - 1` to `number`. `sim.Tick(State, Input, World,
PLAYERS)` is built by the harness for each step: `{state: ^State, world: ^World, number: u32, seed: u64, inputs:
^Inputs, events: ^Events}`. Per-tick helpers that need more than the block take it (`roll_below`, `emit`). Systems
take `tick` or narrower arguments, as the game prefers. Odin's implicit `context` carries no sim data.

`Inputs(Input, PLAYERS) = {present: Players, replaced: Players, input: [PLAYERS]Input, commands}`. `present` (a
`bit_set[0 ..< 32; u32]`) is who is in the game this tick: joining and leaving are presence changes the relay
decides, never flags in `Input`. `replaced` marks inputs the relay substituted (informational). `inputs_same(a, b)`:
same presence, input bytes and commands. `joined, left := presence_changes(tick, &state.present)` (#9's T6) compares this
tick's presence with a `Players` field the game keeps in its State and updates it: the game emits its own join and
leave events from the two sets.

## Commands

Signed off 2026-11-10; declaration and reading decided in #6 (D11, D13), the limits (D2). A one-shot action (pick
an upgrade, set the map, ready up) is delivered exactly once, in order, per player; never lost, never repeated.

```odin
Cmd_Drop_Coin :: struct {value: u8}                 // any plain struct, 1..64 bytes
Cmd_Start :: struct {map_index: u8, _pad: [3]u8}
Cmd :: union {Cmd_Drop_Coin, Cmd_Start}             // kind = variant index; name = type name without Cmd_, lowercased

GAME := Game{..., commands = Cmd}

for &raw in sim.commands(tick.inputs, player) {     // inside tick: this player's, in order, exactly once each
	switch command in sim.command_value(&raw, Cmd) {
	case Cmd_Drop_Coin: ...
	case Cmd_Start: ...
	}
}
```

- Naming (#214): command types `Cmd_<Name>` in a union `Cmd`, event types `Event_<Name>` in a union `Event`. The
  prefixes are left out of the names (`drop_coin`, `coin_picked`) and of the Godot classes (`CommandDropCoin`,
  `EventCoinPicked`); an event type without `Event_` still works.
- A command is **input, not state**: part of the tick's input record, so it is logged, replayed and sent to late
  joiners with the log; never in the block. Only `tick` reads it. The union exists only when `command_value` builds
  it; on the wire and in the log a command is its kind and its struct's bytes.
- `create` checks the union: a plain union (not `#no_nil` or `#shared_nil`), plain variants with no padding, 1..64
  bytes (`COMMAND_MAX`), at most 255 variants, names unique. GDScript sends one as an object of its class
  (`CommandDropCoin`: `src/godot/SPEC.md`).
- A tick holds at most `COMMANDS_PER_PLAYER` (4) of one player and `TICK_COMMANDS` (16) in all, inline in `Inputs`,
  so a tick's record has a fixed size and fits one datagram. More wait for the next tick, in order:
  `add_command(&inputs, raw) -> bool`. Ordered by player, each player's in the order sent.
- `Raw_Command {kind, player, size, data: [64]u8}`. A kind out of range or a wrong size reads as no variant (bytes
  from the network are dropped the same way on every peer).
- Sources (a UI, a script, a bot) send into a `Command_Out` (`player`, `cap`): `send_command(out, value) -> bool`
  (false: not a variant, or `cap` reached). `command_make(Cmd, value)` builds a raw one for tests and tools.
  Delivery (the client predicts it at the tick it was sent for, or at the first tick not yet finalized when that one
  is; the relay places it): `src/netcode/SPEC.md`.

## Events

Decided in #6 (D5). Events tell the view what happened (a shot, a hit, a pickup). They are not state: not in the
block, not hashed, not rolled back as such. The game declares one plain struct per event (≤ 64 bytes) and a union of
them; an event carries only its own fields:

```odin
Event_Coin_Picked :: struct {
	coin:     sim.Handle(Coin),
	player:   u8,
	position: sim.Position, // distinct [3]f32, sim units (2D: z = 0)
	value:    u32,
}
Event :: union {Event_Coin_Spawned, Event_Coin_Picked, Event_Coin_Dropped}  // name = type name without Event_, lowercased: "coin_picked"

GAME := Game{..., events = Event}
sim.emit(tick, Event_Coin_Picked{coin = handle, player = u8(player), position = {x, y, 0}, value = coin.value})
```

- Stored per tick in the ring as kind + bytes (`Raw_Event {kind, size, data}`), like commands; emitted again when a
  tick is re-simulated. `events_at(simulation, tick)` reads a tick's back in emission order, `event_value(&raw,
  Event)` makes one the union again (nil for a kind out of range or a wrong size), `event_names(Event)` names them.
  `create` checks the union as it checks commands (`EVENT_MAX` 64).
- **The subject convention** (how the view matches an event across re-simulations and routes it): an event's
  subject is its `player` field and its first `Handle(T)` field (or a `u64` field named `entity`), when it has them.
  The view's tracker identifies an event by (tick, type, subject, its index among events of that type and subject
  in the tick).
- How GDScript receives them (an object of a class per event kind, a typed property per field: a handle becomes its key, `sim.Position` is converted to
  view units, an enum becomes its name; the states Emitted, Confirmed and Cancelled; routing to the subject's
  view and one global `sim_event` signal): `src/godot/SPEC.md`.

## Tables and handles

- `Table(T, N)`: `items: [N]T`, `slots: [N]Slot` (generation, alive, free-list link), `free_head`, `high_water` (one
  past the highest slot ever used), `count`. The zero value is empty. Stable indices (no swap-remove), freed slots
  reused last-in-first-out and zeroed (equal states hash equal).
- `Handle(T) = {index: u32, generation: u32}`, typed (a `Handle(Enemy)` is not a `Handle(Bullet)`). Generation 0 is
  never live, so `Handle{}` is null. A slot reused every tick wraps its generation after 2³² reuses (~2 years at
  64 Hz).
- An **index** is the slot a loop is standing on this tick; a **handle** is a reference kept across ticks (in the
  block, in an event, by a view). `get(&table, handle) -> ^T` is nil for a stale, null or out-of-range handle.
- `spawn(&table) -> (^T, Handle(T), ok)` (ok = false: full), `despawn(&table, index | handle)`, `handle(&table,
  index)`, `handle_key(handle) -> u64` (generation << 32 | index: unique among a table's live and past items; view
  keys), `prev_item(prev, cur, index) -> (^T, ok)` (the same item in the previous tick's table: views interpolate).
- **Iteration**, in index order, safe to despawn the current item:

  ```odin
  coins := sim.iterate(&tick.state.coins)
  for coin, handle in sim.next(&coins) { ... }
  ```

  It walks the slots up to `high_water`, which never goes down. `uni bench` measures a sparse 64k table; an alive
  bitmask (1 bit per slot) comes only if that shows the scan matters.
- `schema_of(State)`: tables (by shape: `items` + `slots`; fixed arrays of structs count as always-live tables) and
  globals, with byte offsets, for inspectors, diffs and dumps. `snapshot_diff(State, a, b) -> string` (typed desync
  reports): what differs between two snapshots, down to the leaf field ("tick 4160: enemies[12].pos.x 3.25 vs
  3.5"), then each extra's image by its first differing byte; at most `DIFF_MAX` (8) listed.

## Random numbers

Decided in #6 (D7). Two kinds, built on the same SplitMix64 mixing function, integer-only:

- **`Rng`** (SplitMix64, 8 bytes in the block, period 2⁶⁴): `rng_seed(u64)`, `rng_next`, `rng_below(&rng, n)`
  (unbiased: Lemire's multiply-shift with rejection), `rng_f32` (24 bits, exact in f32). For code that wants "the
  next number": level generation, shuffles. One `Rng` is one stream: a draw added anywhere shifts every later draw
  from it.
- **Keyed rolls**, nothing in the block: `roll_below(tick, n, purpose, key := 0, index := 0)` and `roll_f32` hash
  (seed, tick number, purpose, key, index); `purpose` is a value of the game's own enum. A roll depends only on what
  it names, so adding, removing or reordering one system's rolls never moves another's. Two rolls that should
  differ must differ in something: in a loop, pass the loop index.

## The harness

`Sim(State, Input, World, PLAYERS)` holds the tick counter, `state`, `world`, the extras and a ring of saved ticks
(the block copy, the extras' saves, the events that tick emitted). Ticks count from 1; tick 0 is the initial state.

- **The ring** keeps about 250 ms of ticks at any rate: `ring_size(tick_hz) = tick_hz / 4` (8 at 32 Hz, 16 at 64,
  32 at 128), allocated once at `create`. It bounds rollback: the netcode predicts at most ring − 2 ticks ahead
  (`src/netcode/SPEC.md`).
- `create(&GAME, seed, content)` (world, init, save tick 0), `destroy`.
- `step(simulation, &inputs)` = advance (build the `Tick`, run `tick`) + save. `step_unsaved` keeps the tick's
  events in the ring but not its state (the netcode re-simulating ticks that are already final, #117):
  `events_at` answers for it, `state_at`, `restore` and `snapshot_encode` don't. `restore(simulation, tick)`
  (extras first: on failure the block and tick are untouched; false when the tick is no longer saved in the ring),
  `state_at(simulation, tick)`, `events_at(simulation, tick)`.
- `checksum(simulation)`: XXH3-64 (one-shot; Odin's streaming XXH3 is wrong for some lengths) over the tick (u32 LE),
  the block, then each Extra's bytes. Peers compare it on finalized ticks.
- **Extra** (`save/restore(slot)` with `slot = tick % ring_size`, `hash(state, tick, out)`: on multiples of
  `DEEP_CHECKSUM_EVERY` (16), the ticks the netcode compares, its whole internal state, otherwise a cheaper
  summary; `image(slot)`, `load(bytes)`): rollback state outside the block. The harness knows nothing about Box3D
  (`src/physics/SPEC.md`).

## Files

- **Input log** `UNIL`: seed, content hash, players, input size, ticks (0 with ticks after it: a recording that
  never ended, read to its end); per tick (`write_tick`, also the netcode's finalized tick) present, replaced, the
  players' input bytes, a command count (an empty tick costs one byte) and per command its player, kind, size and
  struct bytes. Seed + content + log = the whole session (replays, reference runs). `Input_Log` in memory:
  `log_append(&log, &inputs)`, `log_inputs(&log, k) -> Inputs` (tick k + 1), `log_encode / decode / read / write`;
  decoding refuses a malformed tick. Written as it grows (a relay's recording): a `Log_Sink` (`write(offset,
  bytes)`, optional `close`; `log_sink_memory(&buf)`, `log_sink_file(path)`, 64 KB at a time) fed by a `Log_Stream`
  (`log_stream_begin(header)`, `log_stream_tick(&inputs)`, `log_stream_end`: the tick count, then close).
- **Portable snapshot** `UNIS`: seed, content hash, tick, block size, `layout_hash(State)` (field names, offsets and
  types), a payload digest, the block bytes, each Extra's image. `snapshot_encode(simulation, tick)`,
  `from_snapshot(&GAME, bytes) -> (^Sim, Snap_Error)` (creates the world the same way, saves tick 0, then loads).
  `Snap_Error`: `Bad_Header` (not a snapshot, or another format version), `Layout_Differs` (another build's state:
  another layout or block size), `Content_Differs`, `Checksum_Mismatch`, `Extra_Count`, `Extra_Rejected`. The
  library never prints.
- **Format versions** (D9): readers accept only the current version of each format. Decide again before a release
  whose game saves replays or saves that players keep. A format change bumps the version and regenerates every
  reference run (`uni record-reference <game>|toy`).

## Open

Optional components and `using` as component; cross-table helpers; keeping only the verified and the predicted
state instead of a ring (#153). Desync recovery is the netcode's (`src/netcode/SPEC.md`, #188).
