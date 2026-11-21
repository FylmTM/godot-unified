# playground: a co-op physics playground

Up to four players fly free cameras through twelve of Box3D's sample scenes and play with them together, under
rollback: grab and fling things, shoot bullets, spawn bodies, set off explosions, drive cars, switch and reset scenes.
unified's example of physics at its widest: every joint type, ragdolls, continuous collision, conveyors, wind, sensors,
hit and joint events, height fields and large piles, each saved, restored and re-simulated with the rest of the state.
A Godot project (this folder is `res://`): the sim, its tests, the headless binary and the GDExtension in
`simulation/` (Odin), everything Godot in `game/`; each scene's static ground is a level (`game/levels/<scene>.tscn`).
`uni run playground` plays it (alone, or with friends online or on the LAN: The app), `uni coop playground` as a
host and a joiner.

Metres, seconds and kilograms at `TICK_HZ`, Y up. Every rule number is a named constant in
`simulation/playground/tuning.odin`.

## Controls

WASD fly (forward along the look), Space / Ctrl up and down, the mouse or the right stick looks. Hold the left button
to grab what the crosshair is on (Q / E pull it closer or push it away), right button to shoot, F to spawn a body (G
picks its shape), X to set off an explosion where the crosshair points, C to get in or out of a car (Driving), `[` `]`
or PageUp / PageDown to change the scene for everyone, R to reset it, Esc / Start for the menu, F1 for the dev UI. The
HUD's controls list says the same, from the InputMap, for what the player is doing.

## The app

The app layer survivor, friendslop and drift share, copied into `game/app/` and `game/ui/`: the `Game` autoload owns
the session for the app's lifetime and switches scenes on its status (the main menu, connecting, the play scene, back
to the menu saying why), whoever started it (the menus, the session flags, `uni coop`); `Settings` (name, volumes,
mouse sensitivity and invert look, window, 3D resolution, FPS) and `Sfx` (sounds synthesized at boot) beside it. The
main menu (`game/ui/main_menu.tscn`) is the Pyramid scene as it starts, built by `game/ui/backdrop.gd` without a sim,
under a slow orbit: Single player, Host online (an EOS lobby; its code on the HUD's session panel, Copy beside it),
Join with code, Join by address or Host on LAN instead, Settings. The play scene (`game/main.tscn`) hands the session
its level and view roots; Esc opens the pause menu (Resume, Settings, Leave to menu), which pauses a single-player
session and frees the mouse, captured the rest of the time (a session panel's Copy is clicked beside it). Changing or
resetting the scene stays on its keys, not in the menu: it is everyone's, like any other command. Online play needs a
build with the EOS IDs compiled in: `uni run` with `.env` set, or the zip `uni release playground` makes
(`docs/EOS.md`).

Where it differs from the shared copy on purpose: the session panel's colours are the cameras'
(`UiTheme.PLAYER_COLORS`), a key that types a symbol is labelled by it (`[`, not BracketLeft), and the pause menu lets
clicks beside its panel through to the HUD.

The play scene routes sim events to effects as they are first shown (a predicted one included; a cancelled shot's
sound stops): shots, spawns, grabs, explosions (which shake the camera within reach), breaking joints and sensor
visits make sounds by distance; a scene everyone entered, once confirmed, plays its chime and the HUD's banner names
it.

## Scenes

One level each (`Scene`, the level enum), built in code at the scene change the way the Box3D sample of the same name
builds it, scaled so the step plus a re-sim at the prediction cap fits the frame (each scene is a `uni bench` row):

| Group | Scene | What it is | What it exercises |
|---|---|---|---|
| Stacking | Pyramid | a box pyramid, `PYRAMID_ROWS` high | a large stack, sleep |
| Stacking | Dominoes | `DOMINO_COUNT` dominoes in an outward spiral, a ball rolling into the first | long contact chains, waking |
| Joints | Bridge | a plank bridge on revolute joints between two pillars, crates on it; a ball and chain of capsules on spherical joints | revolute and spherical joints to the World's anchor |
| Joints | Driving | a car per slot on a height field, crates to drive into | wheel joints (suspension, spin motor, steering), a parallel joint, a level height field |
| Ragdolls | Ragdolls | `MAX_RAGDOLLS` ragdolls dropped on an incline | `physics.Ragdoll` |
| Continuous | Bounce House | fast bodies of every shape in a closed room, restitution 1 | continuous collision against statics |
| Continuous | Bullets | a crate wall, a turret firing bullets at it every `TURRET_EVERY_TICKS` | bullet bodies, continuous collision against dynamics |
| Shapes | Conveyor | crates dropped onto two belts (the level's tangent velocity), balls on a slope, half with rolling resistance | level surfaces, rolling resistance |
| Shapes | Wind | three hanging chains and light bodies in a wind turning once every `WIND_TURN_TICKS` | `shape_apply_wind` |
| Events | Sensors | three sensor volumes counting visitors, balls and crates rolling through, every hit lighting its bodies | sensor begin events, sensor overlaps, hit events |
| Events | Breakable | a crate wall welded together and a plank chain, every joint breaking past `BREAK_FORCE` or `BREAK_TORQUE` | joint force and torque thresholds, joint events |
| Benchmarks | Rain | a body of a rolled shape falling in every `RAIN_EVERY_TICKS`, the oldest gone past `RAIN_CAP` | a busy pile, creation and destruction every few ticks |

## Rules

- **Cameras.** A player is a camera (`Player_Data`): the stick flies it along the look at up to `FLY_SPEED`, inside the
  scene's box (`FLY_BOUND`, `FLY_FLOOR`, `FLY_CEILING`); the look is the Input's `dmath.Aim`. A player joining, or
  everyone at a scene change, starts at the scene's camera start for their slot.
- **Grab** (held): the dynamic body the aim ray meets within `GRAB_RANGE` is pulled by a motor joint from the World's
  anchor toward a point in front of the camera (`GRAB_HERTZ`, at most `GRAB_FORCE_SCALE` times its weight, its spin
  damped by `GRAB_TORQUE`); Closer and Farther move that point. Letting go leaves the body its velocity: a fling.
- **Shoot**: a bullet body (`SHOT_RADIUS`, `SHOT_DENSITY`) from the camera at `SHOT_SPEED`, gone after `SHOT_TICKS`.
- **Spawn**: a body of the chosen shape `SPAWN_DIST` along the look.
- **Explode**: `world_explode` where the aim ray meets something (`EXPLODE_RADIUS`, `EXPLODE_FALLOFF`,
  `EXPLODE_IMPULSE`).
- Each of shoot, spawn and explode starts the player's cooldown (`SHOT_COOLDOWN_TICKS`, `SPAWN_COOLDOWN_TICKS`,
  `EXPLODE_COOLDOWN_TICKS`); a command sent during it is dropped.
- **Cars**: Command_Drive takes the nearest free car within `DRIVE_RANGE`, or gets out. A driver's stick steers the front
  wheels (`CAR_STEER`) and drives the rear ones (`CAR_SPIN_SPEED`, `CAR_SPIN_TORQUE`); a car without a driver brakes.
  The camera rides behind it.
- **The table.** The block owns every body it made in a `sim.Table` of `MAX_PROPS` props (and the ragdolls, cars and
  sensors in arrays). With it full, a shot removes the oldest bullet, a spawn the player's oldest spawn. Anything below
  `KILL_Y` goes (a car goes back to its start).
- **Scene change** (`Command_Scene`, the first of a tick): every grab lets go and every driver gets out, everything the old
  scene built goes, the level is swapped (`physics.level_change`), the new scene is built and every camera goes to its
  start. Picking the current scene resets it. The Setup's `scene` is where a session starts.

## Systems (`tick`, in this order)

1. `update_presence`: leaves (let go, out of the car) and arrivals (a camera at the start).
2. `change_scene`: the first `Command_Scene` (`Event_Scene_Entered`).
3. `fly_cameras`: the sticks and looks; a driver's camera behind their car.
4. `use_tools`: per player, the grab, then their commands (`Event_Grabbed`, `Event_Released`, `Event_Shot`,
   `Event_Spawned`, `Event_Exploded`).
5. `drive_cars`, then `run_scene_rules`: the turret, the conveyor's drops, the wind, the rain.
6. The physics step.
7. `after_step`: Sensors' events and overlaps (`Event_Sensor_Entered`), Breakable's joint events
   (`Event_Joint_Broke`), bullets aging out.
8. `remove_fallen`.

## Scripted players

Pure functions of (seed, slot, tick): a stick drawn every `SCRIPT_PERIOD` ticks, a look sweeping toward -Z (where
each scene is from the cameras' starts), the grab held part of the time, each tool on its own period, and slot 0
changing the scene every `SCRIPT_SCENE_TICKS`, so the reference run crosses scene changes and each benchmark (a
scene's Setup, 600 ticks) stays in its scene. A script that read the state would play differently in a session than
offline: each client asks with the state it has.

## Levels

Twelve levels in `Scene` order, `game/levels/<scene>.tscn` baked to `.level` files the game embeds: static boxes
(the ground, pillars, walls, an incline, posts), the conveyor's belts (a `unified_tangent_velocity` on their
shapes) and Driving's `HeightMapShape3D`, which `game/levels/height_mesh.gd` draws (Godot draws no mesh for one).
Everything that moves is built in code, so a level holds no markers.

## View contract (`simulation/extension`)

- MultiMesh views by shape: `box`, `sphere`, `cylinder` (unit meshes scaled to the body) and `capsule` (a unit sphere
  that `game/capsule.gdshader` stretches by the instance's custom data: radius, half length). Every body the sim made
  is one of them, coloured by what it is (a spawn or a bullet by its player); a ragdoll's bones draw their capsules
  (`physics.ragdoll_capsules`).
- Scene views: `camera` (a player's camera, keyed by the player: their colour, their grab point while they hold
  something; the local player's own hides itself) and `sensor` (Sensors' volumes, with how many bodies are in each and
  have entered).
- `Data_Hud` (`Unified.data.hud`): the scene, the players, the bodies and how many are awake, what the local player is
  doing. The scenes' enum is the level enum: `EnumLevel` in GDScript.
- Input: the InputMap's move, grab, closer and farther actions; the camera rig's yaw and pitch (`Unified.input`, set on
  `input_wanted`) are the aim. The tools' one-shots are commands `main.gd` sends while the game has the input (not
  under the pause menu).
