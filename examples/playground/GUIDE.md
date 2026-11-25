# Writing gameplay that survives rollback

For whoever writes this game's sim and views: the patterns that hold up under prediction, rollback, late joins and
replays, then the symptoms of breaking them. Each line points at the README section or declaration that holds the
detail. `src/` and `examples/` are unified's (`unified/src/`, `unified/examples/` in a game repo); `uni doc <pkg>`
prints a package's API (`--brief`: a line per declaration; `uni doc sim Game`: one declaration, a struct with its
fields' comments); this game's own code comments repeat the warnings where they apply.

`tick` turns the state block and one tick's inputs into the next block. Every client runs it ahead on guesses of the
others' inputs and, when the real ones arrive, restores an older tick and runs it again (`src/sim/README.md`, The
harness). So `tick` runs any number of times for one tick number, on every machine, and must compute the same bytes
each time; the views show the newest guess and are told when it changes.

## Patterns

**The state** (`src/sim/README.md`)
- Everything `tick` reads across ticks is in `State`: plain data, no pointers, slices or maps (The state block). Things
  are `sim.Table` items named by a `sim.Handle`; small bags are `sim.List`, `sim.Queue`, `sim.Bits` (Tables and
  handles; Collections).
- The World holds only what `world_create` builds and what the Extra (physics) rolls back; scratch such as a
  `sim.Grid` is rebuilt from the block by the pass that uses it (World; Neighbours and time slicing).
- A session's choice (a mode, a difficulty, saved progress) is its Setup; a player's choice before joining (a
  character, a colour) their Profile; neither is a command after the fact (Setup and Profile).
- Bump `Game.version` with every rule or tuning change, so builds that would compute differently refuse each other
  (Build identity).

**Input and commands** (`src/sim/README.md`)
- `Input` is the controls' state, read again on every repeat: what is held in a `buttons` bit_set (presses from
  `sim.buttons`), axes quantized (`dmath.axis_i8`). A one-shot (throw, pick, ready) is a command (Input; Commands).
- Both come from another machine: an Input's enum declares a member of value 0, and `tick` survives any value (Bytes
  from another machine).
- A cheat or a test shortcut (give XP, spawn enemies) is a `Command_Dev_<Name>` command: a form in the dev UI, left out
  by a public build (Commands).
- In-game lobby flow (ready, team) is commands in a waiting phase of the state. A bot fills the same `Input` a player
  sends, before the systems that read it, so one code path moves both.

**Events and views** (`src/godot/README.md`)
- `tick` emits events for what happened; `fill_frame` reads the state for what is. A view's effect goes on EMITTED,
  its undo on CANCELLED, anything final (a score, an unlock) on CONFIRMED (Events).
- Whatever teleports pushes a warp epoch with its view (`View_Item.warp`; Filling a frame): a body's is
  `physics.body_warp` (every physics teleport moves it on); a thing that is no one body keeps a `u8` in its state.
- A kind whose spawns must never show mispredicted is `Appear.Verified`; its smoothing and who poses it are its
  policy, in its `Glue.view_policy` / `multi_policy` entry (Filling a frame).
- What a view shows of the rules' next move (the item a grab would take, the next upgrade) calls the proc `tick`
  calls, from `fill_frame`, so the two cannot disagree. A preview that follows the player's own input (a piece under
  the cursor, an aim line) reads `Frame.local_inputs`, the newest sample, not the state's, which trails it by the
  input delay.
- Mispredictions hide behind acceleration rather than an instant velocity, behind an action whose animation starts at
  once and whose effect a few ticks later, and behind a projectile that is a ray cast per tick with a view-only tracer.

**Re-simulation** (`src/sim/README.md`)
- `tick` reads the block, the World and the inputs only: no package state, no clock, no files (`src/lint/README.md`,
  Rules). To see inside it, debug draws (`sim.debug_line`, `physics.debug_draw`) and zones (`sim.zone`), redrawn on
  every re-simulation (Debug draws and zones).
- Each state transition is one idempotent proc that every rule calls (`set_ragdoll(t, thing, on)`), so a
  re-simulation that reaches it by another path ends in the same state.

**Presence and joins** (`src/sim/README.md`, Players)
- A player is a `sim.Player`, never a slot: who leaves and comes back gets their handle and data back in any free
  slot, so things are owned by `Player`.
- `t.player_changes` (arrived, joined, left) is handled before the systems; a leaver's bodies are destroyed at the
  leave and made again on the return. Late joins, local players and opening a session to friends are presence changes
  like any other (`src/godot/README.md`, Input).

**Levels**
- The active level is state: `physics.level_change` (`sim.level_enter` without physics) at a tick, by a rule or a
  command. The change first destroys what hangs on the old level, then rebuilds the level's things from its markers
  in a fixed order (`src/sim/README.md`, Levels; `src/physics/README.md`, Levels).
- The screen follows the verified level and the sim keeps ticking through a load; waiting for everyone is game state
  (a ready command, a timeout) (`src/godot/README.md`, Levels).
- The levels go inline in the `@(rodata)` descriptor, `levels = {{"meadow", #load("../../game/levels/meadow.level")}}`
  (`src/sim/README.md`, Levels); a level without physics is parsed with `level.load` and entered with
  `sim.level_enter`.
- Procedural content comes from the seed (keyed rolls in `init`) and the Setup, never from the network.

**Time and pause** (`src/sim/README.md`)
- A time is seconds converted to ticks (`X_TICKS :: u32(X_S * TICK_HZ)`) or a `sim.Timer`; nothing counts down by
  hand. A stamp is `t.time` (a `sim.Game_Time`), never `t.number`, which names the record only (Game time).
- A `sim.Clock` in the State makes game time pausable. The co-op pause is a command `tick` reads before it returns
  early on `t.paused`, before `physics.step` (this game's `pause.odin`); single player pauses from outside
  (`UnifiedSession.paused`) (Game time).
- Work too costly for every entity every tick runs on `sim.due` turns (Neighbours and time slicing).

**Randomness** (`src/sim/README.md`, Random numbers)
- A rule's own rolls on a tick no command decides are keyed rolls (`sim.roll_below`, `sim.roll_f32`) named by a
  purpose enum, a key and an index.
- A roll on a tick a command decides (its own effect, or a phase or timer it starts) names state, never the tick: a
  stream in the block (`sim.rng_keyed`, then `sim.rng_below` / `sim.shuffle`), so a command placed a tick late draws
  the same. One stream per player or hero: a shared one deals in the relay's order.
- A view peeks a roll the sim will make with `sim.roll_below_at` from `Frame.seed`, through the proc the tick calls.

**Determinism** (`src/dmath/README.md`)
- f32; `dmath`'s `min`, `max`, `clamp`; its trig in turns (`TAU` only at a Box3D call); curves sampled at bake time
  (`curve_delta`); `to_i32_clamped` for a conversion that can overflow; no NaN in the block.
- The lint and the scenarios in `simulation/tests/` catch what they can; pin a reference run once the rules settle
  (`reference_test.odin`), which every platform must reproduce (`src/headless/README.md`, Reference runs).

**Replay regressions** (`src/headless/README.md`, Replay regressions)
- A session worth keeping (a feature played through, a bug's F3 note once it is fixed) goes into
  `simulation/tests/replays/<name>/`: copy its replay folder (`<user data>/recordings/<time>/`, or the note's), then
  `uni test <game> --bless`. `uni test` replays it from then on and names the first tick and the fields that differ.
- A rules or tuning change that moves a regression on purpose: bump `Game.version`, `uni test <game> --bless` (the
  reference run too) and commit what it re-pinned with the change, saying why. One that moves it by surprise is a bug: look at that tick in the
  game's replay of the folder (`UnifiedSession.replay`).

**Physics recipes** (`src/physics/README.md`)
- A jump pad sets a velocity, not an impulse, so every mass flies alike (friendslop's `pads.odin`).
- A safe respawn spot is banked only when a ring of downward rays (`physics.world_cast_ray_closest`) all hit static
  geometry.
- A thrower and what it threw ignore each other for a while: `physics.ignore_contacts`, its ref in the block.

## Gotchas: symptom, cause, fix

- **A sound or a score fires twice.** Something final ran on EMITTED, and a rollback moved its event to another tick
  (a new event). Run it on CONFIRMED, or undo on CANCELLED (`src/godot/README.md`, Events).
- **The HUD flickers, or shows a win that un-happens.** Session data is the newest prediction. Show what must be
  final from a CONFIRMED event (`src/godot/README.md`, Data and classes).
- **A view glides across the map on a respawn.** No warp epoch pushed with it (`View_Item.warp`: a body's
  `physics.body_warp`), or a body moved by a velocity instead of a teleport.
- **A spawn flashes and vanishes.** A mispredicted spawn, shown at once by default: `Appear.Verified` for that kind.
- **A MultiMesh instance pops on a correction.** Its kind sets no smoothing in `Glue.multi_policy`.
- **The crosshair shows one target and the grab takes another.** The view decides on its own: call the sim's proc in
  `fill_frame`.
- **A tap is lost or repeats.** A one-shot in `Input`, which prediction repeats and the relay replaces. Hold it in
  `buttons` and read `sim.buttons(t, player).pressed`, or send a command (`src/sim/README.md`, Input).
- **Desync right after a rollback; the sync-test names a tick.** State outside the block: a World field the Extra
  doesn't roll back, scratch kept across ticks (`src/sim/README.md`, World).
- **Desync only between different CPUs, or one CI platform fails the reference run.** A float trap: builtin
  `min`/`max` on floats, `core:math`, a NaN, an out-of-range float-to-int (`src/dmath/README.md`).
- **Someone rejoins and gets another player's things.** Something keyed by slot: key it by `sim.Player`.
- **A player spawns as the default, then swaps.** Their choice was a command after joining: make it the Profile.
- **`check_refs` names an orphan or a dead ref.** A body no `Body_Ref` in the block owns, or a `Body_Ref` or
  `Shape_Ref` to something destroyed (`src/physics/README.md`, References).
- **A joint call asserts "a stale joint ref".** The joint died with one of its bodies (destroyed by another system, or
  the old level's): joint refs are weak, so check `physics.joint_valid` before using one whose bodies aren't the
  holder's own (`src/physics/README.md`, References).
- **A timer never fires.** `timer_fired` is true on one tick: a sliced or skipped system misses it. Use `timer_done`
  and `timer_stop` (`sim.timer_fired`).
- **A command sent during the co-op pause does nothing.** The paused tick returned before reading it, and a command
  arrives once (`src/sim/README.md`, Game time).
- **Two players roll the same, or a new roll changed another system's.** Rolls naming the same purpose, key and
  index, or two sequences sharing one stream (`src/sim/README.md`, Random numbers).
- **A drawn card changes after a rollback.** A roll a command caused named the tick, and the command landed a tick
  later than predicted: draw it from a stream in the block (`sim.rng_keyed`).
- **The HUD's preview isn't what the player gets.** The peek names another tick or key than the roll: one proc for
  both (`sim.roll_below_at`).
- **A time constant doesn't compile.** It isn't a whole number of ticks: change it, or start a `sim.Timer` with
  seconds (`src/sim/README.md`, Game time).
- **Two builds desync instead of refusing each other.** A rule changed without a `Game.version` bump.
- **A replay regression diverges after a change that shouldn't move the sim.** It did: the report's fields say where.
  Bless only after a change meant to compute differently (`src/headless/README.md`, Replay regressions).
- **A replay regression says its recording does not decode.** The Input, a command, the Setup or the Profile changed
  layout: record the session again and bless it.
