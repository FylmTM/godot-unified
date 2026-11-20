# friendslop: a co-op physics sandbox

A third-person co-op physics sandbox, unified's example of a physics-heavy game: 1–4 wobbly capsule characters ride
platforms, bounce on jump pads, push, carry, stack and throw things (and each other), knock each other over and haul
heavy things together. A hub yard to mess around in, and a short route that strings every interaction into beats: two
levels, and the team moves between them inside one session (unified's example of a level change). A Godot project
(this folder is `res://`): the sim, its tests, the headless binary and the GDExtension in `simulation/` (Odin),
everything Godot in `game/`; the levels are Godot scenes (`game/levels/hub.tscn`, `route.tscn`). `uni run friendslop`
plays it.

Metres, seconds and kilograms at `TICK_HZ`, Y up. Every rule number is a named constant in
`simulation/friendslop/tuning.odin`; the level's own numbers (sizes, launches, paths) are its markers' properties.

## Controls

WASD / left stick to move (camera-relative), mouse / right stick to look, Space / A to jump, LMB or E / RT to grab
and drop, RMB or Q / LT held to charge a throw (release throws), Esc / Start for the menu, F1 for the dev UI. Grab a
friend to carry them; mash jump to break free.

**Invite friends**: a single-player session opens to friends from the pause menu (online when the build has online
play, else on the LAN port; the code on the session panel) and keeps running, the hub and route as they are; Stop inviting lets nobody new in while the friends
playing stay.

## Loop

- **Hub** level (spawn, late join): loose items, a lift, a ferry, a jump pad and a bumper. No goals.
- **Run:** walking through the hub's start gate takes the whole team to the **route** level (everyone at the route's
  spawns, by slot) and starts the run timer. Each beat's exit is a team **checkpoint**.
- **Falling** (below `KILL_Y`): the player's body is parked out of the way for `RESPAWN_S`, then they respawn at
  the team's last checkpoint (spread by slot, `CHECKPOINT_SPREAD`), or their hub spawn. A fallen item goes back where
  the level placed it.
- **Finish:** the trophy in the finish volume ends the run (the best time is kept); after `FINISH_HOLD_S` the team is
  back in the hub level, everyone at their hub spawn and every item, platform and trigger as the hub makes them. When
  the last player leaves, a run ends there the same way.
- **Travel:** the pause menu's "Back to hub" (`Command_Travel`) takes the team to the hub, ending a run; a travel to the
  route starts one.
- **A level change** (`enter_level`): everyone lets go and their bodies go, the old level's items, platforms and
  trigger sensors go, the static geometry is swapped (`physics.level_change`), the new level's things are made in
  level order, and every present player gets a fresh body at their spawn. The players, the phase and the best time
  are the block's and carry over.

No health, no fail state: getting hit or dropped costs time, not a life.

**Players** are session members (`sim.Players` of `Character`): one who joins or comes back gets a fresh body at
their respawn point; one who leaves lets go of what they hold and is let go of, and their body goes. Whatever names a
player names the person (`sim.Player`), never the slot: who holds a grab point or a friend, an item's thrower,
events and views. Spawn points are per slot: a `spawn` marker each, by its `slot` property.

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

- **Character** (`physics.Character`, `src/physics/README.md`): a rotation-locked dynamic capsule driven by a mover
  joint and held up by a pogo spring, so it rides platforms, is pushed by items, bumpers and friends and feels what it
  holds without special cases. It walks at `WALK_SPEED`; facing follows the move, or the aim while holding. Holding
  slows it (`HOLD_SLOW`, `HOLD_SLOW_HEAVY` for the heavy crate). A held, stunned or fallen player doesn't move
  themselves.
- **Grab** (a toggle): the target on the aim ray (`GRAB_RAY_RANGE`), else the nearest grabbable within `GRAB_RANGE`
  of the chest in a cone around the aim (`GRAB_CONE_COS`; any direction within `GRAB_ANYWHERE`). Items and players
  are grabbable; a held player can't grab, and a player holding a player can't be grabbed. Holding grab while a
  thrown thing passes catches it. Pressing grab again drops.
- **Hold:** a motor joint pulls the target's grab point to the hold point in front of the chest (`HOLD_DIST`, raised
  by the aim's pitch), its force capped by the target's weight times its `lift` (`ITEM_SPECS`; a friend:
  `PLAYER_LIFT`). Collisions push back; nothing teleports. The heavy crate has two handles, each capped below its
  weight: alone it drags, two lift it.
- **Holding a friend:** the held player goes limp and drops what they held. `BREAK_FREE_PRESSES` jump presses within
  `BREAK_FREE_WINDOW_TICKS` (not before `BREAK_FREE_MIN_TICKS`) break free with a hop; the holder lets go anyway after
  `HELD_MAX_TICKS`. A dropped or freed friend is limp until they land.
- **Throw:** hold throw to charge (`THROW_CHARGE_TICKS`), release: the target gets the holder's velocity plus the aim
  times `THROW_SPEED_MIN + THROW_SPEED_ADD · charge`, plus `THROW_LIFT` up. The heavy crate can't be thrown (it is
  dropped). A thrown item is "thrown by P" for `THROWN_TAG_TICKS`, and it and its thrower pass through each other
  (a contact ignore, `physics.ignore_contacts`) until it is `THROW_CLEAR_DIST` from them, its tag ends or they leave;
  after that a bounce back hits them like any hit. A thrown friend is limp until they land (`THROWN_MIN_TICKS` to
  `THROWN_MAX_TICKS`).
- **Hit:** a contact hit between a thrown or fast (`HIT_SPEED`) item and a player knocks them back along the item's
  motion (`KNOCKBACK`); a player inside a bumper is knocked away from it at the bumper's `strength`. Either way they
  hop (`KNOCKBACK_UP`), are limp for `STUN_TICKS`, and drop what they hold.
- **Jump pads:** a player whose feet, or an item whose lower part, is inside a pad's volume gets the pad's launch
  velocity (a straight-up pad keeps the horizontal velocity); `PAD_COOLDOWN_TICKS` per body.
- **Platforms:** kinematic bodies on `physics.Path`s (ping-pong, loop, once, or follow: forward while their trigger
  is active, back while not), optionally gated by a trigger. The pose is a pure function of the platform's phase.
  Each leg is linear, smoothstepped, or follows a designer curve on the marker (`easing`: the ferry's slow start).
- **Triggers:** a plate is pressed while the summed mass in its sensor (up to `PLATE_REACH` above it) reaches its
  threshold (players count unless it is `items_only`); a bell rings on a hit of at least `BELL_SPEED` (again after
  `BELL_COOLDOWN_TICKS`); a switch fires when a player enters it; a lock when the key enters it. Bells, switches and
  locks latch until the route resets.
- **Sensor or point test:** a Box3D sensor where the rule needs who or what is in a volume (a plate's mass, a
  switch's player, a lock's key); a point against a box where it asks whether one known body is (pads, bumpers,
  checkpoints, the start and the finish).

## Systems (`tick`, in this order)

1. `update_presence`: leaves (let go, body gone) and arrivals (a body, `Event_Spawned`).
2. `use_hands`: per player, the aim; a held player struggles (`Event_Broke_Free`); a free one grabs, drops, catches,
   charges and throws (`Event_Grabbed`, `Event_Dropped`, `Event_Thrown`).
3. `update_holds`: hold points follow facing and aim; holds whose target went away end.
4. `move_players`: the stick, the jump press (`Event_Jumped`), facing and the hold's slowdown.
5. `move_platforms`, then `launch_from_pads` (`Event_Launched`) and `bump_players` (`Event_Hit`).
6. The physics step.
7. `apply_hits`: item hits on players (`Event_Hit`) and bells (`Event_Bell_Rung`); `age_throws`.
8. `press_triggers`: plates (`Event_Plate_On`, `Event_Plate_Off`), switches and locks (`Event_Switch_On`).
9. `recover_from_stuns`, `respawn_fallen` (`Event_Fell`, `Event_Respawned`), `return_fallen_items`.
10. `advance_phase`: the start gate (`Event_Run_Started`, the route), checkpoints (`Event_Checkpoint`), the finish
    (`Event_Run_Finished`), the return to the hub (`Event_Respawned`).
11. `travel`: the players' travel commands (`Command_Travel`), the first that goes somewhere.

## Events

Each names its subject: `player` (a `sim.Player`) when it is about a player, `entity` (`sim.entity` of the level
marker index) when it is about an item, plate, bell, switch or lock, and `position` in metres. An event about both
(a holder and what they grabbed, dropped or threw) goes to the player's view. The library's joins and leaves come
too.

## Input

A world-space stick (the client rotates it by its camera), the camera's look direction as the aim, and jump, grab and
throw, held (presses and releases from `sim.buttons`). No angles cross the wire, so the sim needs no trig. One
command, `Command_Travel` (the pause menu's "Back to hub"); the scripted player sends it too, so every scripted session,
replay and reference run crosses level changes.

## Levels

Two levels, in `Level_Id` order: `game/levels/hub.tscn` and `route.tscn` (each instances its part from
`game/levels/parts/` with the sky and sun), baked to `.level` files (`src/level/README.md`), which the game embeds.
Each has a spawn per slot; the hub's `start` marker is the door to the route, the route's `finish` its end. The World
reads every level's markers once (`Places`, by level); tick code reads the active level's (`places(t)`). Geometry is
Godot's static bodies; the rest are markers: `item` (kind crate, ball, cube, key, heavy, trophy), `platform` (with a
path), `pad`, `bumper`, `plate`, `bell`, `switch`, `lock`, `checkpoint`, `spawn`, `start`, `finish`. At runtime
each sim view adopts its marker's visuals.

A marker property's default lives in its marker script (`game/levels/markers/`), never in the sim: the bake writes
every exported property, so the sim reads them without defaults and asserts what its rules need (a volume's size, a
plate's mass, a spawn per slot, an item kind or platform mode the sim knows).

## View contract (`simulation/extension`)

- The play scene's `Level` is the session's `level_root`: the session instances the active level's scene there,
  loading it on a thread behind a loading label, and a marker view finds its marker with
  `UnifiedSession.level_marker`.
- Scene views: `player` (keyed by `sim.player_key`; data `limp`, `holding`, `charge`) and `marker`, every sim object
  the active level placed (items, platforms, bells, plates, switches, locks), keyed by its level marker index (data
  `held_by`: the player holding a one-handle item). Markers are script-posed (`Glue.views`): the view takes
  the sim's pose, except an item the local player holds, drawn at their hand every rendered frame. A respawn, a park
  below the level and an item sent home teleport a body, which moves its warp epoch on (`physics.body_warp`): the
  view snaps there instead of gliding. An event about a player goes to that player's view, so grabbed, dropped and thrown stay
  with the holder; one about a marker alone goes to that marker's view.
- Session data `Data_Hud` (`Unified.data.hud`): the phase, the run's and best times, the checkpoint, the reset
  countdown, and each slot's player (`DataHudPlayer`).
- Constants (`Unified.constants`): the player capsule (radius, half height, feet), the heavy crate's
  `handle_outset`, each item kind's size (`item_sizes`), which the item markers draw, and the hold point
  (`hold_dist`, `hold_up`, `hold_pitch`) a held item is drawn at.
- Input: the InputMap's move, jump, grab and throw, the stick turned by the camera rig's `look` and `right`
  (`Unified.input`, set on `input_wanted`), the aim its look.
