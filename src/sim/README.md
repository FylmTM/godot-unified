# `unified:sim`: the deterministic harness

A game is a function `tick(state, inputs) → next state`. Every machine that starts from the same bytes and applies
the same inputs computes the same bytes; rollback, replays, late join and desync detection follow from that. This
package is the harness that runs it: the game type, the tick and what it reads (inputs, players, commands, rolls) and
writes (the state block, events), the ring of saved ticks, the checksum, the input log and the portable snapshot.

It imports `dmath` (the arithmetic, `src/dmath/README.md`) and `wire` (the bytes, `src/wire/README.md`). `physics`
plugs Box3D in as rollback state (the Extra, `src/physics/README.md`); `netcode`, `headless` and `godot` drive it;
`lint` says what tick code may not use (`src/lint/README.md`). It touches no files and never prints: file I/O is
`headless`'s, and a failure comes back as a value (a violation string, a `Snap_Error`).

## The game type

A game names its eight types once, `Game :: sim.Game(State, Input, World, Event, Cmd, Setup, Profile, PLAYERS)`, and
fills one value of it, the descriptor: name, version, tick rate, `tick` and the optional hooks, each documented on its field.
Everything generic over a game takes that one type (`Sim(G)`, `Tick(G)`, `Inputs(G)`, the netcode's client, the
headless runs, `godot.Glue`) and names a part of it with `part`.

What the compiler can check does not compile: a State without `players` (or one for another Profile, Input or
PLAYERS), a Setup or Profile of another type where the game's is taken (`create`, `join`), an
Event union without the library's join and leave events, an `emit` or `send_command` of a type outside the union. The
rest (the tick rate, the plain-data rules below) `game_violation` checks once at run time: `create` panics with its
reason, the Godot host reports it.

### The state block

`State` is one plain-data struct (`plain_violation` has the rule): sized integers, `f32`, bools, enums and bit_sets
with a sized backing integer, fixed arrays and nested structs, with no implicit padding (gaps are explicit `_pad`
fields). Its memory is its canonical little-endian serialization: a snapshot is a copy, the checksum hashes its
bytes, a desync report reads it by RTTI. It holds the session's players in a field named `players` (Players, below)
and the game's tables (Tables and handles).

### Input

`Input` is one player's controls for one tick. It comes from another machine and is compared and logged as raw
bytes, so it holds no bools or floats (`wire_violation`; quantize an axis: `dmath`'s encodings), and every peer reads
it the same way (Bytes from another machine).

The netcode may repeat or substitute an input (prediction, the relay's stand-in for a late one), so an input is the
controls' state, never a one-shot: buttons are a bit_set field named `buttons` holding what is down, and `buttons`
derives presses and releases against the slot's input of the tick before, which the state keeps (a predicted repeat
never presses twice). A one-shot value is a command.

### World

`World` is everything outside the block: the Box3D world, level geometry, scratch (`sim.No_World` for none). **It
holds only what `world_create` builds and what the Extra rolls back**: anything else in it that affects `tick`
diverges after a rollback, unhashed. The sync-tests (`scenarios.rollback_every_tick`, `headless.Run`) fail on the
tick such state shows.

### Setup and Profile

Two kinds of choice reach the sim before it runs, recorded like inputs, never as commands after the fact (a player
spawning as a default and swapping a tick later is a visible change and a misprediction):

- **Setup**: what differs between two sessions of one build (a mode, a difficulty, saved progress). It is fixed when
  the session starts and lives **beside the seed**, outside the block: `Sim.setup`, never rolled back or hashed (a
  session has one). `world_create` gets it, and every tick (`init` too) gets a copy in `t.setup`, so a write there
  reaches nothing and read-only needs no rule. `Game.setup` is the Setup of a session started without one, so a
  variant of the game is a copy of the descriptor with another Setup.
  Progress a game saves is its own small file, which the host turns into the next session's Setup; a snapshot is
  never a save, since it stops loading after every `compat` change.
- **Profile**: what a player chose before joining (a character, a colour). It rides beside the player's join record
  (`Inputs.profiles`) and the harness writes it into the State's Players by member on that tick, before the join
  event and `tick`: the player spawns as chosen on their first tick, the predicted one too. It is state: a rollback
  restores it, a snapshot carries it, the checksum covers it. A returning member brings a new one (they may have
  picked another character in the menu) and keeps its data; a game that wants the first keeps it in its `T`.

Both are plain structs without padding, checked like commands (`game_violation`), at most `SETUP_MAX` and
`PROFILE_MAX` bytes. A game without them names `sim.No_Setup` and `sim.No_Profile`, as it names `sim.No_World`: zero
bytes everywhere, so its State is what it would be without them.

### Levels

A game ships several levels, `Game.levels`: each a name and a level file's bytes (`src/level/README.md`), embedded
once, in the order of the game's level enum, so tick code says `Level_Id.Route` and tools say "route". Every host,
run and suite plays them, and `world_create` gets them to parse and build once. **The active level is state**: a
`sim.Active_Level(Level_Id)` named `level` in the State, changed only by `level_enter` (`physics.level_change` for a
physics game) at a tick, by a rule or a command. So a level change is a sim decision like any other: a rollback
across it, a late join after it and a replay of it need nothing of their own, and the sim keeps ticking through it.
`compat_of` hashes every level (`content_hash`), so every peer has every level and nothing is loaded or checked at a
change. `game_violation` holds the list to the enum (`levels_violation`): a list in another order never runs.

What carries over a change is what the game keeps in the block (players, a score); what belongs to a level (its
things, built from its markers) the game rebuilds in its change, in a fixed order. A level's marker indices count
from 0 in each file, so an `Entity` naming a marker names one of the level active at its tick. Which level a
session starts in is the game's choice in `init` (its Setup's, when it has one). Other levels are a copy of the
game with other `levels` (the headless `--level NAME=FILE`); a re-baked level rebuilds the extension (`uni` counts
the `.level` files as inputs).

### Time

A time constant is written in seconds and converted, never written as raw ticks: `RESPAWN_TICKS :: u16(RESPAWN_S *
TICK_HZ)`. Odin refuses a constant conversion that truncates, so a time that is not a whole number of ticks does not
compile. A time from data converts with `ticks`, a view's with `seconds`; inside `tick`, `t.dt`. A Timer takes
seconds at run time (`timer_start`, rounded to the nearest tick), outside that check: a time that must be a whole
number of ticks stays an `X_TICKS` constant for `timer_start_ticks`.

### Build identity

`compat_of` is the build's identity: the layouts of the types, the unions, the tick rate, the game's name and
version, its levels' hash and the library's part (`LIBRARY_VERSION`, the unified-box3d pin). The netcode's hello,
input logs and snapshots carry it, so builds that would compute differently refuse each other instead of desyncing. A
change a layout doesn't show bumps a version by hand: `Game.version` for the game's rules, `LIBRARY_VERSION` for the
library's (the `sim-change` skill).

## The tick

`tick` advances the state from tick `number - 1` to `number`, reading everything through the `Tick` the harness
builds; Odin's implicit `context` carries no sim data. A step goes in this order: the inputs are read as every peer
reads them, the presence is applied to the State's Players (with their join and leave events), the commands are
decoded, `tick` runs, each held slot's input is kept as its `before`, and the tick is saved into the ring.

`Inputs` are by slot. Joining and leaving are presence changes the relay decides (`present` and the join records),
never flags in an Input.

## Game time

Timers are state with nothing to decrement: a `Timer` holds the game time it started and the one it ends, and every
read compares them with the tick's `t.time`, so a rollback restores it with the block, a system that skips a tick
misses nothing and no loop counts down. A counter that only counts down, or a stored "tick it happens at", is a Timer;
a count-up meter stays an integer.

Game time is the tick number unless the State holds a `Clock`. Then the harness advances the clock before every tick
that isn't paused and gives the tick `t.time` and `t.paused`, so every timer, `due` and stamp in that game holds
through a pause with no call site knowing about it. The clock is found by its type, so it can be named anything.

**The co-op pause is state.** Online, a pause from outside the sim is not exact (the others keep playing), so a pause
is a command that every peer applies at the same tick: `set_paused` from it, and `tick` returns early when `t.paused`,
skipping the game's systems and `physics.step`. It needs nothing from the netcode: the relay keeps finalizing ticks,
clients keep predicting, a rollback re-simulates through it, a late joiner's snapshot and the log carry it. A pause
or resume takes effect from the next tick, so no game time is run twice. On a paused tick:

- Presence is applied as always (people come and go while paused), and commands arrive once, as always: the game
  reads the pause's own before it returns, and any command it doesn't read then is gone (a game that wants otherwise
  reads them there too).
- Keyed rolls name the tick number, never game time, so a roll made on a paused tick still differs every tick.
- `buttons` compares with the slot's input of the tick before on every tick, paused or not: a press during the pause
  is pressed on that tick, and a button held through the resume is not pressed again.

Time scales (slow motion) are deliberately not built.

## Players

A **slot** is an input index `0 ..< PLAYERS`. A **player** is a `Player` handle naming a session **member**, the
person: who leaves and comes back gets the same handle back in whatever slot is free, with everything keyed by it.
An **account** (an EOS id, a LAN token) is host-side only, never in State, Inputs, logs or snapshots
(`src/netcode/README.md`, Members).

```odin
State :: struct {..., players: sim.Players(Player_Data, Profile, Input, PLAYERS), ...}
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

- **Before `tick`** the harness applies the presence: first the leaves (a held slot no longer present, or present
  with another member's join record), then the joins in slot order (a slot that becomes present with a join record;
  **a slot present without one stays absent**). A known member returns with its data intact; a new one gets a zeroed
  `T` in the first free entry, else the entry of the **longest-absent** member, which is forgotten: its handles go
  stale and, if that person comes back, they are new. A member who left on this tick is never forgotten on it, so its
  handle in `t.player_changes.left` still names its data while the game cleans up. A member already present
  elsewhere moves (the newest connection). The join and leave events come before the game's.
- **After `tick`** it keeps each held slot's input as `before` (zero for an empty slot and when the holder changes):
  it is state, so a rollback restores it and a predicted repeat never reads as a press.
- **The library reports; the game decides** what an absent player's things do: an owner is a `Player`, never a
  slot. An absent member's `T` owns nothing outside the block (a body is destroyed at the leave and made again on the
  return), since the table may forget it before any `tick` runs.
- Every query takes the tick, a `^Players` (views) or a `^Sim` (tests and drivers outside `tick`); `input`,
  `input_before`, `buttons` and `commands` take the tick only.
- Join records come from the relay; tests, tools and bots write them with `seat`, which can't leave a slot present
  without one by mistake.

## Commands

A one-shot action (pick an upgrade, start the match) is delivered exactly once, in order, per player.

```odin
Cmd_Drop_Coin :: struct {value: u8}                 // any plain struct
Cmd_Start :: struct {}                              // a command with nothing to say is empty
Cmd :: union {Cmd_Drop_Coin, Cmd_Start}             // kind = variant index

for sent in sim.commands(t, player) {               // this player's, in order, exactly once each
	switch command in sent {
	case Cmd_Drop_Coin: ...
	}
}
```

- A command is **input, not state**: part of the tick's record, so it is logged, replayed and sent to late joiners;
  never in the block. On the wire and in the log it is its kind and its struct's bytes.
- The union is checked like the block (`game_violation`): plain data without padding, 0 to `COMMAND_MAX` bytes per
  variant, at most 255 variants with unique names, not `#no_nil` or `#shared_nil`.
- Names: command types are `Cmd_<Name>`, event types `Event_<Name>`; the names and the Godot classes leave the prefix
  out (`drop_coin`, `CommandDropCoin`).
- A tick's record holds them inline in `Inputs`, up to `COMMANDS_PER_SLOT` of one slot and `TICK_COMMANDS` in all,
  so a record has a fixed size and fits a datagram; a sender's surplus waits for the next tick, in order. Delivery:
  `src/netcode/README.md`, Commands.

## Bytes from another machine

An Input and a command come from another machine: a modified or buggy client can send any bytes. Every peer reads
them the same way, so a bad value can neither crash `tick` (an index out of bounds, a phantom button) nor desync it:

- **An Input**: an enum field outside its declared values reads as its zero value, so an Input's enum must declare a
  member of value 0 (an absent player's all-zero input holds it too); a bit_set reads without the bits of no element.
  The caller's `Inputs` stay as sent: `step` reads a fixed copy.
- **A command**: each bool reads as 0 or 1 and each bit_set without the bits of no element; one whose enum field holds
  an undeclared value or whose float is not finite is left out on every peer alike, like one of an unknown kind or the
  wrong size.
- **A Profile** is read like a command, inside the step, so the relay, a prediction, a replay and a test read it
  alike: one that a command would leave out is the zero Profile.
- **A Setup** that does not read as sent is refused (`setup_violation`), never zeroed: a zeroed Setup would play
  another session than the host's.

## Events

Events tell the view what happened (a shot, a pickup). They are not state: not in the block, not hashed. One struct
per event (1 to `EVENT_MAX` bytes) and a union of them, plain data like the block except that padding is allowed
(events are never hashed or compared as bytes). An event never has a field named `tick`, `kind` or `id`: every event
carries those already (`game_violation` refuses them).

```odin
Event_Coin_Picked :: struct {coin: sim.Handle(Coin), player: sim.Player, position: sim.Position, value: u32}
sim.emit(t, Event_Coin_Picked{coin = handle, player = player, position = {x, y, z}, value = coin.value})
```

A tick's events are kept in its ring slot and emitted again when the tick is re-simulated, so a view shows a
predicted event at once and confirms or cancels it when the tick is verified; the sync-test checks that a
re-simulated tick emits the same events (`events_diff`).

**The subject convention.** The Godot host routes an event to the views pushed with its first `Handle` or its first
`Entity` as their subject, found by type, whatever the field's name (`src/godot/README.md`, Events). A thing that is
not a table's item (a level marker, an item of a fixed array) is named by an `Entity`. A point is a `Position`, in
sim units, which the view maps to its own.

## Debug draws and zones

Tick code can show a developer what the sim saw and time its systems; neither is state. **Draws** (`debug_line`,
`debug_sphere`, `debug_text`, ...; `physics.debug_draw` for the physics world) are kept in the tick's ring slot
beside its events, so a re-simulated tick draws again and replaces what it drew, and the host shows the shown tick's
draws. **Zones** (`sim.zone(t, Zone.Steer)`, scoped) time the rest of a scope; a zone's time is its self time, so a
step's zones and "other" add up to the step. The zone a draw is made in is its draw group, the unit the dev UI
toggles, so one enum names both; a game names its zone enum at each call because a bare `.Steer` has nothing to infer
the enum from, and a seventh `sim.Game` parameter for a dev feature would cost every game more.

Both hang off a `Dev` the host attaches to a `Sim` (`dev_attach`), which owns the clock: the sim reads none itself.
Without one every call is a nil check; a build without the dev UI (`DEV` false) leaves every call an empty proc. The
lint bans `.dev` outside this package, so tick code can't read a draw list or a zone time into state, and the
sync-tests prove a run with everything attached computes the checksums of one without.

## Tables and handles

A `Table` is a fixed-capacity array of the game's items inside the State, so it is plain data, rolled back, hashed
and snapshotted with the block; its zero value is empty. Indices are stable (no swap-remove), and a freed slot is
zeroed, so equal states hash equal. Anything that refers to an item across ticks (the block, an event, a view, a
physics tag through `handle_key`) holds a typed generational `Handle`, which a reused slot makes stale instead of
pointing at the new item. A desync report reads a table by item index (`enemies[12].pos.x`).

```odin
coins := sim.iterate(&t.state.coins)
for coin, handle in sim.next(&coins) { ... }
```

## Collections

Beside tables, the block holds three inline, fixed-capacity collections: `List` (items in order, for small bags whose
indices nobody keeps), `Queue` (first in, first out) and `Bits` (a set of indices sized by a constant, where an enum's
set is Odin's `bit_set`). Heap containers can't be state: they allocate, must be freed on every peer, and move on
growth. These are plain data for any element type and capacity: the count is as wide as the element's alignment, so
no padding appears and `plain_violation` passes with no `_pad` field (which is why a 1-byte element caps a List at
255 items). Every remove, pop and clear zeroes what it vacates, so a List's bytes are a function of its items: equal
contents hash equal whatever their history (a Queue's also depend on where its head is, until it empties).

Their verbs are Odin's own for dynamic arrays and bit_sets (`append`, `pop`, `ordered_remove`, `unordered_remove`,
`clear`, `pop_front`, `incl`, `excl`, `card`), so a game writes what it already knows. Inside package sim they shadow
the builtins, which sim calls as `builtin.append` and `builtin.clear`. The desync report and the Inspector recognise
the three by their RTTI names and show only the live items (a List's by index, a Queue's oldest first, a Bits as its
indices).

## Neighbours and time slicing

Entities that live only in the block (a horde, bullets, pickups) have no Box3D bodies to query, so `Grid` finds what
is near a point: a counting sort of ids into square cells. It is scratch in the World, never state: a pass that needs
it rebuilds it from the block, which costs microseconds, so a rollback can never leave it stale (the sync-tests fail on
any tick where stale scratch reaches the state). Its answers come in a fixed order, by row, column and then the order
the ids were added, so walking a table in index order gives each cell's ids in index order and no hashing or pointer
order reaches the simulation.

`due` spreads work too costly to run every tick for every entity: each key's turn comes once per period, and dense
keys share the ticks evenly.

## Random numbers

Two kinds, on SplitMix64's mixing function, integer-only:

- **Keyed rolls** (`roll_below`, `roll_f32`) keep nothing in the block: a roll hashes (seed, tick number, purpose,
  key, index), with `purpose` a value of the game's own enum. A roll depends only on what it names, so adding or
  reordering one system's rolls never moves another's; two rolls that should differ must differ in something (in a
  loop, the index). **`tick` draws keyed rolls.**
- **A keyed roll can be peeked.** It reads no state, so anyone who can name it computes it early: a HUD shows "the next
  upgrade" with `roll_below_at` from `Frame.seed`, touching nothing. Put the roll in one proc that both the tick and
  the view call. Name the tick when it is known from state (the tick a spawn is due); name tick 0 and something stable
  in key and index (a player's level) when the roll must not depend on when it is made.
- **`Rng`**, one stream, for code outside `tick` that wants "the next number". A draw added anywhere shifts every
  later one.

## The harness

A `Sim` holds the tick counter, the block, the World, the Extra and a ring of saved ticks (`ring_size`): per slot the
block, the Extra's save and the events. Ticks count from 1; tick 0 is the initial state, saved by `create`. Rollback
is `restore` to a tick still in the ring, then `step` again; the ring's size bounds how far the netcode predicts.

The **Extra** is the rollback state outside the block, at most one per game (`Game.extra`; physics:
`physics.extra`). The harness saves and restores it with each ring slot, appends its canonical bytes to the checksum
(all of its state on the ticks the netcode compares, `DEEP_CHECKSUM_EVERY`) and puts its portable image in snapshots.
Its optional `check` is how the sync-tests catch it disagreeing with the block after every restore.

`checksum` is XXH3-64 over the tick, the block and the Extra's bytes; peers compare it on finalized ticks.

## Files

Readers accept only the current version of each format (`LOG_VERSION`, `SNAP_VERSION`): bump it on any change to
what the bytes hold. The byte layouts are in the headers of `log.odin` and `snapshot.odin`.

- **The input log** (`Input_Log`, `log_encode`; recorded as it grows through a `Log_Stream`): seed, the session's
  Setup, levels' hash and the recording build's compat, then each tick's record, a join with the Profile it brought.
  Levels + log is the whole session.
- **The portable snapshot** (`snapshot_encode`, `from_snapshot`): the session's Setup, the block and the Extra's image
  with the build's identity, so it restores on another OS or CPU (late join, `resume`) or says why not
  (`Snap_Error`). A late joiner needs nothing else: its World is built from the Setup everyone built theirs from, and
  every remembered member's Profile is in the block.
- **Text**: `struct_from_text` reads a Setup or a Profile from `key=value` (the headless and Godot `--setup`).
- **Desync reports**: `snapshot_diff` (two snapshots of one build, down to the leaf field), `events_diff` (two lists
  of one tick's events) and `find_nan` (no NaN may reach the block, `src/dmath/README.md`).
