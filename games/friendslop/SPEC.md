# friendslop

Status: draft, pending #327

A third-person co-op physics sandbox, unified's example of a physics-heavy game: 1–4 wobbly capsule characters ride
platforms, bounce on jump pads, push, carry, stack and throw things (and each other), knock each other over and haul
heavy things together. A hub yard to mess around in, and a short route that strings every interaction into beats.
Units: metres, seconds and kilograms at **64 Hz**, Y up. Every rule number is a named constant in
`simulation/friendslop/tuning.odin`; the level's own numbers (sizes, launches, paths) are its markers' properties.

## Loop

- **Hub** (spawn, late join): loose items, a lift, a ferry, a jump pad and a bumper. No goals.
- **Run:** walking through the start gate starts the team's run timer. Each beat's exit is a team **checkpoint**.
- **Falling** (below `KILL_Y`): the player's body is parked out of the way for `RESPAWN_S`, then they respawn at
  the team's last checkpoint (spread by slot, `CHECKPOINT_SPREAD`), or their hub spawn. A fallen item goes back where
  the level placed it.
- **Finish:** the trophy in the finish volume ends the run (the best time is kept); after `FINISH_HOLD_S` everyone
  is back at their hub spawn and every item, platform and trigger is as the level made it. When the last player
  leaves, a run ends there the same way.

No health, no fail state: getting hit or dropped costs time, not a life.

**Players** are session members (`sim.Players` of `Character`): one who joins or comes back gets a fresh body at
their respawn point; one who leaves lets go of what they hold and is let go of, and their body goes. Whatever names a
player names the person (`sim.Player`), never the slot: who holds a grab point or a friend, an item's thrower,
events and views. Spawn points are per slot: a `spawn` marker each.

## The route

Solo finishes every beat; co-op is faster or opens a shortcut.

| # | Beat | Exercises |
|---|---|---|
| 1 | **Steps and gaps** | steps, slopes, jump, air control |
| 2 | **Jump pad** onto a high ledge | launch, landing |
| 3 | **Ferry** across a chasm | riding a horizontal platform |
| 4 | **Lift** up a shaft | riding a vertical platform |
| 5 | **Stack:** crates in a pit below a high ledge | carry, place, stack, stand on dynamic bodies |
| 6 | **Toss:** a switch on a perch lowers the gate | throw a friend up; solo: stack the crates there |
| 7 | **Plate and gate:** the weight cube on a plate holds a gate open | carry and place; the plate reads mass |
| 8 | **Bell:** throw a ball at a bell to lower a bridge | aimed throw |
| 9 | **Pass:** the key across a beam to a lock that opens a gate | throw to a friend, catch |
| 10 | **Haul:** the heavy crate to the scale (items only) | two-person lift; solo drags it round the wall |
| 11 | **Trophy ride:** the trophy across moving platforms to the pedestal | carrying while riding |

## Rules

- **Character** (`physics.Character`, `src/physics/SPEC.md`): a rotation-locked dynamic capsule driven by a mover
  joint and held up by a pogo spring, so it rides platforms, is pushed by items, bumpers and friends and feels what it
  holds without special cases. It walks at `WALK_SPEED`; facing (a unit vector) follows the move, or the aim while
  holding. Holding slows it (`HOLD_SLOW`, `HOLD_SLOW_HEAVY` for the heavy crate). A held, stunned or fallen player
  doesn't move themselves.
- **Grab** (a toggle): the target on the aim ray (`GRAB_RAY_RANGE`), else the nearest grabbable within `GRAB_RANGE`
  of the chest in a cone around the aim (`GRAB_CONE_COS`; any direction within `GRAB_ANYWHERE`), lowest index on
  ties. Items and players are grabbable; a held player can't grab, and a player holding a player can't be grabbed.
  Holding grab while a thrown thing passes catches it. Pressing grab again drops.
- **Hold:** a motor joint pulls the target's grab point to the hold point (chest height, `HOLD_DIST` along facing,
  raised by the aim's pitch), its force capped by the target's weight times its `lift` (`ITEM_SPECS`; a friend:
  `PLAYER_LIFT`). Collisions push back; nothing teleports. The heavy crate has two handles and a cap of 60 % of its
  weight each: alone it drags, two lift it.
- **Holding a friend:** the held player goes limp and drops what they held. `BREAK_FREE_PRESSES` jump presses within
  `BREAK_FREE_WINDOW_TICKS` (not before `BREAK_FREE_MIN_TICKS`) break free with a hop; the holder lets go anyway after
  `HELD_MAX_TICKS`. A dropped or freed friend is limp until they land.
- **Throw:** hold throw to charge (`THROW_CHARGE_TICKS`), release: the target gets the holder's velocity plus the aim
  times `THROW_SPEED_MIN + THROW_SPEED_ADD · charge`, plus `THROW_LIFT` up. The heavy crate can't be thrown (it is
  dropped). A thrown item is "thrown by P" for `THROWN_TAG_TICKS` and ignores its thrower for
  `THROWER_IGNORE_TICKS`. A thrown friend is limp until they land (`THROWN_MIN_TICKS` to `THROWN_MAX_TICKS`).
- **Hit:** a contact hit between a thrown or fast (`HIT_SPEED`) item and a player, or a player inside a bumper:
  `KNOCKBACK` along the item's motion (away from the bumper) plus `KNOCKBACK_UP`, limp for `STUN_TICKS`, and they drop
  what they hold.
- **Jump pads:** a player whose feet, or an item whose lower part, is inside a pad's volume gets the pad's launch
  velocity (a straight-up pad keeps the horizontal velocity); `PAD_COOLDOWN_TICKS` per body.
- **Platforms:** kinematic bodies on `physics.Path`s (ping-pong, loop, once, or follow: forward while their trigger
  is active, back while not), optionally gated by a trigger. The pose is a pure function of the platform's phase.
- **Triggers:** a plate is pressed while the summed mass in its sensor (up to `PLATE_REACH` above it) reaches its
  threshold (players count unless it is `items_only`); a bell rings on a hit of at least `BELL_SPEED`; a switch fires
  when a player enters it; a lock when the key enters it. Bells, switches and locks latch until the route resets.
- **Sensor or point test:** a Box3D sensor where the rule needs who or what is in a volume (a plate's mass, a
  switch's player, a lock's key); a point against a box where it asks whether one known body is (pads, bumpers,
  checkpoints, the start and the finish).

## Systems (`tick`, in this order)

1. `update_presence`: leaves (let go, body gone) and arrivals (a body, `spawned`).
2. `use_hands`: per player, the aim; a held player struggles (`broke_free`); a free one grabs, drops, catches,
   charges and throws.
3. `update_holds`: hold points follow facing and aim; holds whose target went away end.
4. `move_players`: the stick, the jump press (`jumped`), facing and the hold's slowdown.
5. `move_platforms`, then `launch_from_pads` (`launched`) and `bump_players` (`hit`).
6. The physics step.
7. `apply_hits`: item hits on players (`hit`) and bells (`bell_rung`); `age_throws`.
8. `press_triggers`: plates (`plate_on`, `plate_off`), switches and locks (`switch_on`).
9. `recover_from_stuns`, `respawn_fallen` (`fell`, `respawned`), `return_fallen_items`.
10. `advance_phase`: the start gate (`run_started`), checkpoints (`checkpoint`), the finish (`run_finished`), the
    reset (`respawned`).

## Events

Each names its subject: `player` (a `sim.Player`) when it is about a player, `entity` (`sim.entity` of the level
marker index) when it is about an item, plate, bell, switch or lock, and `position` in metres. `spawned`, `jumped`,
`broke_free`, `fell`, `respawned`, `run_started` (`position`, `player`); `hit` (+ `speed`, `bumper`: a bumper, not an
item); `checkpoint` (+ `index`); `launched` (a player, or an item's `entity`); `grabbed`, `dropped`, `thrown`
(+ `speed`): `player` the holder, `entity` the item or `held_player` the friend; `run_finished` (the trophy's
`entity`, `duration_s`); `plate_on`, `plate_off` (+ `mass`), `bell_rung` (+ `speed`), `switch_on` (`player` for a
switch, none for a lock); and the library's joins and leaves.

## Input

`move_x, move_z` (world-space: the client rotates the stick by its camera; `dmath.stick`), `aim` (`dmath.Dir3`, the
camera's look direction) and `buttons` (`Jump`, `Grab`, `Throw`, held; presses and releases from `sim.buttons`). No
angles cross the wire, so the sim needs no trig. No commands.

## Level

One level, `game/levels/park.tscn` (the hub and the route are parts it instances), baked to `park.level`
(`src/level/SPEC.md`), which the game embeds. Geometry is Godot's static bodies; the rest are markers: `item` (kind
crate, ball, cube, key, heavy, trophy), `platform` (with a path), `pad`, `bumper`, `plate`, `bell`, `switch`, `lock`,
`checkpoint`, `spawn`, `start`, `finish`. At runtime each sim view adopts its marker's visuals.

A marker property's default lives in its marker script (`game/levels/markers/`), never in the sim: the bake writes
every exported property, so the sim reads them without defaults and asserts what its rules need (a volume's size, a
plate's mass, a spawn per slot, an item kind or platform mode the sim knows).

## View contract (`simulation/extension`)

- Scene views: `player` (keyed by `sim.player_key`; data `limp`, `holding`, `charge`) and `marker`, every sim object
  the level placed (items, platforms, bells, plates, switches, locks), keyed by its level marker index. An event about
  a player goes to that player's view, so grabbed, dropped and thrown stay with the holder; one about a marker alone
  goes to that marker's view.
- Session data `Data_Hud` (`Unified.data.hud`): `phase`, the run's and best times, `checkpoint`, the reset
  countdown, and per slot (`DataHudPlayer`) `holding` (an `EnumHeldKind`), `held`, `stunned`, `fallen`, `charge`.
- Constants (`Unified.constants`): the player capsule (radius, half height, feet), the heavy crate's
  `handle_outset` and each item kind's size (`item_sizes`), which the item markers draw.
- Input: the InputMap's move, jump, grab and throw, the stick turned by the camera rig's `look` and `right`
  (`Unified.input`, set on `input_wanted`), the aim its look.
