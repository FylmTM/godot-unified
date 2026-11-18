# friendslop: the co-op physics sandbox (the second game)

Status: signed off 2026-11-09, review pending #14; the developer's decisions are marked (D).

Code: `games/friendslop/`, laid out like `games/survivor/`. Library work it needs: `src/physics/SPEC.md` (character,
joints, paths) and `src/level/SPEC.md` (Godot-authored levels).

A third-person physics sandbox for 1–4 players (solo works): wobbly capsule characters who ride platforms, bounce
on jump pads, push, carry, stack and throw things (and each other), knock each other over, and haul heavy things
together. A hub yard to mess around in, plus a short route (~3–5 min with a friend) that strings every interaction
into beats. "friendslop" is also our umbrella term for this kind of game (D).

It proves `unified` for physics-heavy co-op: characters, joints, kinematic movers, carries and throws inside
rollback, bit-exact across machines. Metres, seconds, Y up; 64 Hz (`DT = 1/64`), Box3D 4 substeps.

## Loop

1. **Hub** (spawn, lobby, late join): a fenced yard with loose crates, balls, a weight cube, a heavy crate, a lift
   up to a ledge, a ferry, a jump pad onto a high ledge and a bumper (open: a seesaw, a cannon pad). No goals: the
   sandbox, and where players land after a run.
2. **Run:** walking through the start gate starts the team's run timer. Beats in order; each beat's exit is a team
   **checkpoint**.
3. **Falling** (y < −10): respawn at the team's last checkpoint after 1.5 s. An item that falls resets to its
   spawn (open: also resetting a key item that leaves its beat).
4. **Finish:** the trophy on the pedestal → run time shown (best time kept by the view) → after 5 s everyone is back
   in the hub and the route resets.

When the last player leaves, a run (or its finish) ends there: the route resets and the phase is back to the hub, as
drift and survivor reset theirs.

No health, no fail state: getting hit or dropped costs time, not a life.

**Players** (`src/sim/SPEC.md` "Players"): the State's `players` is a `sim.Players` of `Character` (8 remembered
members for 4 slots). A player who joins, or comes back, gets a fresh body at their slot's spawn (or the team's
checkpoint, spread by slot); one who leaves lets go of what they hold and is let go of, and their body goes. Whatever
names a player names the person (`sim.Player`), never the slot: who holds a grab point or a friend, an item's
thrower (so someone new in the thrower's slot is not its thrower, and the thrower is still it after coming back in
another slot), events and views. Spawn points and colours are per slot.

## The route

Solo finishes every beat; co-op is faster or opens a shortcut.

| # | Beat | Exercises |
|---|---|---|
| 1 | **Steps and gaps:** low steps, a slope, a short gap | controller: steps, slopes, jump, air control |
| 2 | **Jump pad** onto a high ledge | jump pad launch, landing |
| 3 | **Ferry:** a platform shuttles sideways across a chasm | riding a horizontal platform, getting on and off |
| 4 | **Lift:** a platform goes up and down a shaft | riding a vertical platform; standing on a friend while riding |
| 5 | **Stack:** crates in a pit, a ledge too high to jump to | push, carry, place, stack, stand on dynamic bodies |
| 6 | **Toss:** a switch on a 3 m perch lowers the gate ahead | throw a friend up onto the perch; solo: stack the three crates there |
| 7 | **Plate and gate:** a weight cube on a pressure plate holds a gate open | carry and place; the plate reads mass |
| 8 | **Bell:** throw a ball at a bell across a gap to lower a bridge | aimed throw at a target |
| 9 | **Pass:** the key crosses a narrow beam to a lock that opens a gate | throw to a friend, catch; solo: throw it over, then cross |
| 10 | **Haul:** a heavy crate to the scale (items only) that opens the last door | two-person lift over a low wall; solo drags it round the wall's end (D) |
| 11 | **Trophy ride:** the trophy across moving platforms to the pedestal | carrying while riding; throwing things at friends |

## Player controller (D: dynamic character)

`physics.Character` (`src/physics/SPEC.md`): a rotation-locked dynamic capsule (r 0.35, height 1.6), a mover joint (target
velocity, force cap) and a pogo joint (ground spring, ray probes). Being a real body, it rides kinematic platforms
(the mover joint attaches to them), is pushed by thrown items, bumpers and friends, stands on crates and other
players, and feels the pull of what it holds, all without special cases.

Tuning: walk 5.5 m/s, accelerate 20/s, ground friction 8/s, air steer 0.25, jump 7 m/s, gravity scale 1.5, coyote
time 0.125 s, jump buffer 0.125 s. Facing (a unit vector, no angles) follows the move direction, or the aim while
holding.

## Interactions

- **Grab** (toggle, D): the nearest grabbable within 1.6 m of the chest in a 60° cone around the aim (a ray along the
  aim first, then nearest-in-cone; lowest index on ties). Grabbables: items and players (D).
- **Hold** (D: capped spring): a motor joint pulls the target's grab point to the hold point (chest height, 1.1 m
  along facing, raised with aim pitch) with a force cap `HOLD_FORCE`; an angular spring keeps it upright relative to
  facing. Collisions push back, nothing teleports. Holding slows the holder: −15 %, −40 % for a heavy item.
- **Heavy items** (5× a crate's mass, two handles): one holder's cap is ~60 % of the weight, so alone it only drags;
  two holders on two handles sum to ~120 % and lift it. Emergent from the force caps, not scripted.
- **Holding a friend** (D): the held player goes limp (drive force 0, pogo released) and drops what they held; they
  hang like a medium item. They break free with 3 jump presses within 1 s (not before 0.5 s held); auto-release
  after 4 s (D). No chains: a held player can't grab, and a player holding a player can't be grabbed.
- **Drop:** grab again.
- **Throw:** hold throw to charge (0–0.5 s), release: the joint goes, the target gets `mass · (6 + 10·charge) · aim`
  plus the holder's velocity. Heavy items can't be thrown. A thrown thing is "thrown by P" for 1 s (hit attribution;
  ignores its thrower for 0.2 s). A thrown friend is stunned until they land (max 1 s).
- **Catch:** holding grab while a thrown thing passes within reach grabs it.
- **Hit** (D: knockback + stun): a Box3D contact hit event between a thrown or fast (> 6 m/s) item and a player →
  impulse along the item's velocity, stun 0.75 s: drops what they hold, drive force 0, pogo released; the view tips
  the character over. Bumpers do the same.
- **Jump pads:** a box volume checked by the sim each tick (not Box3D sensors): a player whose feet are inside, or an
  item whose centre is inside, gets the pad's launch velocity (vertical, plus an optional push); the character is told
  it launched. 0.25 s per-body cooldown.
- **Platforms:** kinematic bodies on `physics.Path`s (waypoints, segment times, smoothstep, ping-pong or loop, waits),
  optionally gated by a plate, bell or switch. The pose is a pure function of the platform's state (`running`,
  `phase_tick`); the sim drives the body to it each tick.
- **Pressure plates:** a sensor box reaching 2.5 m above the plate; the summed mass of the bodies in it ≥ threshold
  → pressed. A friend standing on it counts (a co-op answer), unless the plate is `items_only` (the haul's scale).
- **Bell, switch, lock:** a hit event with approach speed ≥ 4 m/s, a player entering its sensor, or a key item
  entering its sensor → triggered (latched).

## Sim and view

**Deterministic sim** (`simulation/friendslop`, block + Box3D): bodies (players, items, platforms, gates), joints
(character, pogo, hold), controller state, holds, throws, stuns, pads, plates, triggers, checkpoints, the run timer,
phases and events (`Event` in `state.odin`: the library's player joined and left, spawned, jumped, launched,
grabbed, dropped, thrown, hit, broke free, fell, respawned, checkpoint, run started and finished, plate on and off,
bell rung, switch on). Each event is its own struct: `player` (a `sim.Player`, GDScript gets its key) when it is
about a player, `entity` (the level marker index + 1) when it is
about an item, plate, bell, switch or lock, `position` in metres, and its own values (speed, mass, seconds).

**What the view gets** (`simulation/extension`):

- Scene views: `player` (keyed by `sim.player_key`; data `limp`, `holding`, `charge`) and `marker`, every sim object
  the level placed (items, platforms, bells, plates, switches), keyed by its level marker index with `entity` = that
  index + 1 (its events' `entity`); the view adopts its marker's visuals. An event about a player goes to that
  player's view, else one with an `entity` to that marker's view (`event_key`): grabbed, dropped and thrown stay with
  the holder.
- Session data `Data_Hud` (`Unified.data.hud`, `hud.odin`, from the state alone): `phase`, the run's and best
  times, `runs`, `checkpoint`, the reset countdown, the active triggers (a bit each), and per slot (`DataHudPlayer`)
  `holding`, `held`, `stunned`, `fallen`, `charge`.
- Constants `Data_Constants` (`Unified.constants`): the finish hold and respawn seconds, the player capsule (radius,
  half height, feet) and each item kind's size (`item_sizes`: `kind`, `size`; `validate` checks the level's item
  markers draw them so).
- Enums as classes: `EnumPhase`, `EnumHeldKind`, `EnumItemKind`.

**Godot only:** the camera (orbit, collision, smoothing; it produces the input's aim), character animation
(procedural squash, lean, wobble, stun tumble, arms), the level scene's own meshes and lights, materials,
particles, sounds, HUD (timer, beat, prompts; the shared session and controls panels, `games/survivor/SPEC.md`),
nameplates, menus, settings, dev UI.

## Input (8 bytes per player per tick)

`move_x, move_z: i8` (world-space; the client rotates the stick by the camera yaw; `dmath.stick`), `aim: dmath.Dir3`
(the camera's look direction), `buttons: bit_set[Button]` (`Jump`, `Grab`, `Throw` held; presses and releases from
`sim.buttons`), 1 spare byte. No angles cross the wire, so the sim needs no trig.

## Camera and controls (D)

Orbit camera, mouse captured / right stick. WASD moves relative to the camera, Space jumps, LMB grabs/drops
(toggle), RMB held charges a throw, released throws. Pad: A jump, RT grab, LT charge/throw, B drop.

## Level (D: authored in Godot)

One level per session: `game/levels/park.tscn` instances `hub.tscn` and `route.tscn`. Godot's
StaticBody3D/CollisionShape3D for geometry and marker nodes for the rest
(`src/level/SPEC.md`): `platform` (+ Path3D; gates and bridges are platforms that follow a trigger), `pad`, `plate`,
`item` (kind: crate, ball, cube, key, heavy, trophy), `spawn`, `checkpoint`, `bell`, `switch`, `lock`, `bumper`,
`start`, `finish`. At runtime each sim view adopts its marker's visuals. Exported to a level file the sim loads at
runtime; the default levels are embedded too, so headless runs need no path.

## Art

Greybox with primitives and toon shading: bright pastel players (one colour per player, googly eyes), items colour-
coded by weight (light yellow, medium blue, heavy red with handles), striped platforms, glowing pads, flag
checkpoints. Sounds synthesized at boot, as in the survivor.

## Tests and checks

- `simulation/tests`: sync-test (window 8) on scripted chaos inputs that walk, jump, grab, throw, hit, hold friends
  and ride (players start next to items and platforms); scenarios asserting outcomes (two lift the heavy crate, one
  can't; a rider stays on for a full platform cycle; a throw stuns a friend; a held friend breaks free); a netcode
  session under the `bad` profile.
- A headless binary with the `src/headless/SPEC.md` CLI modes; sync-test and session runs for friendslop in its
  end-to-end suite (`uni test`).
- The `godot` suite's `validate` and `tour` steps and `uni coop friendslop`, as for the survivor; `tour` drives a
  scripted bot through the route.
- Budget (to be measured, then set): forward step ≤ 0.5 ms with 4 players and ~60 dynamic bodies; an 8-tick re-sim
  ≤ 4 ms.

## Build order

1. Library: `src/physics/SPEC.md` and `src/level/SPEC.md`, with tests (after sign-off).
2. **Vertical slice:** the hub, two players online: one platform, one jump pad, one throwable, one heavy crate,
   holding a friend. Single player, EOS online with lobby codes, menus, settings, dev UI (the survivor pattern).
3. The route, beat by beat, each with a scenario test.
