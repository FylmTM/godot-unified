// drift's state block, input, commands, events and constants (games/drift/SPEC.md). Metres and seconds; the
// plane is XY in Godot's 2D axes (x right, y down); every time constant is in seconds, converted to whole ticks
// at compile time.
package drift

import "unified:physics"
import "unified:sim"

TICK_HZ :: 64
DT :: f32(1) / TICK_HZ
PHYSICS_WORKERS :: 1 // Box3D's step threads: any count steps identically, more take CPU from Godot and the netcode

PLAYERS :: 4
MAX_ROCKS :: 128
MAX_BULLETS :: 256
MAX_GEMS :: 64
MAX_GATES :: 8
MAX_SPAWNERS :: 16

// ---- tuning (games/drift/SPEC.md "Rules")

SHIP_RADIUS :: f32(0.5)
SHIP_DENSITY :: f32(4)
SHIP_DAMPING :: f32(1.4)
THRUST_ACCEL :: f32(14) // m/s² at full stick (terminal speed THRUST_ACCEL / SHIP_DAMPING)
TURN_GAIN :: f32(8)
TURN_MAX :: f32(6) // rad/s
BOOST_SPEED :: f32(8) // m/s added along the heading
BOOST_COOLDOWN_S :: 1.5
FIRE_EVERY_S :: 0.125
BULLET_SPEED :: f32(18)
BULLET_LIFE_S :: 0.875
BULLET_PUSH :: f32(0.6) // N·s along the bullet on a hit

STATION_RADIUS :: f32(2.5) // the hexagon's corners
STATION_SPIN :: f32(0.25) // rad/s
STATION_HP :: i32(100)

ROCK_DEPTH :: f32(1)
ROCK_SPLIT_SPEED :: f32(2.5)
WAVE_EVERY_S :: 20
ROCK_EVERY_S :: 1.5 // between a wave's rocks
ROCK_SPEED :: f32(2)
ROCK_SPEED_PER_WAVE :: f32(0.2)

GATE_RADIUS :: f32(0.8)
GATE_CHARGE_S :: 2

GEM_PICK_RADIUS :: f32(1)
GEM_LIFE_S :: 10
GEM_REPAIR :: i32(2)
GEM_DRAG :: f32(0.98) // per tick

OVER_HOLD_S :: 5

BOOST_COOLDOWN_TICKS :: u16(BOOST_COOLDOWN_S * TICK_HZ)
FIRE_EVERY_TICKS :: u16(FIRE_EVERY_S * TICK_HZ)
BULLET_LIFE_TICKS :: u16(BULLET_LIFE_S * TICK_HZ)
WAVE_EVERY_TICKS :: u32(WAVE_EVERY_S * TICK_HZ)
ROCK_EVERY_TICKS :: u32(ROCK_EVERY_S * TICK_HZ)
GATE_CHARGE_TICKS :: u16(GATE_CHARGE_S * TICK_HZ)
GEM_LIFE_TICKS :: u32(GEM_LIFE_S * TICK_HZ)
OVER_HOLD_TICKS :: u32(OVER_HOLD_S * TICK_HZ)

Rock_Size :: enum u8 {
	Small,
	Medium,
	Large,
}

@(rodata)
ROCK_RADIUS := [Rock_Size]f32 {
	.Small  = 0.6,
	.Medium = 1.0,
	.Large  = 1.6,
}

@(rodata)
ROCK_HP := [Rock_Size]u8 {
	.Small  = 1,
	.Medium = 3,
	.Large  = 6,
}

@(rodata)
ROCK_STATION_DAMAGE := [Rock_Size]i32 {
	.Small  = 2,
	.Medium = 5,
	.Large  = 10,
}

ROCK_VARIANTS :: 4

// The rock shapes: 8 corners at the 8 compass directions (dmath.DIR8), each at this fraction of the rock's
// radius. The body is their convex hull (the view draws the same hull). Fixed shapes, so every rock hull a
// late joiner's world may have to load is registered at tick 0 (world.odin: the catalogue).
@(rodata)
ROCK_SHAPES := [ROCK_VARIANTS][8]f32 {
	{1.0, 0.82, 0.95, 0.78, 1.0, 0.86, 0.92, 0.8},
	{0.9, 1.0, 0.76, 0.94, 0.84, 1.0, 0.8, 0.9},
	{0.8, 0.92, 1.0, 0.85, 0.78, 0.95, 1.0, 0.88},
	{1.0, 0.78, 0.88, 1.0, 0.9, 0.76, 0.96, 0.84},
}

// ---- input

// One player's input for one tick. Directions are in world space (the plane's x right, y down), −127..127.
Input :: struct {
	move_x:  i8,
	move_y:  i8,
	aim_x:   i8, // zero aim: keep the heading
	aim_y:   i8,
	buttons: u8,
}

BUTTON_FIRE :: u8(1 << 0) // held: fires every FIRE_EVERY_S
BUTTON_BOOST :: u8(1 << 1) // held: boosts whenever the cooldown allows

Inputs :: sim.Inputs(Input, PLAYERS)

// Commands (src/sim/SPEC.md): one-shot actions, each delivered exactly once. A command's name is its type's
// without `Cmd_`, lowercased ("start", "restart"): what GDScript's send_command uses.
Cmd_Start :: struct {
	_pad: u8,
}

Cmd_Restart :: struct {
	_pad: u8,
}

Cmd :: union {
	Cmd_Start,
	Cmd_Restart,
}

// ---- state

Phase :: enum u8 {
	Lobby,
	Match,
	Over,
}

Ship :: struct {
	body:           physics.Body_Ref,
	fire_cooldown:  u16, // ticks until the next shot
	boost_cooldown: u16,
	gate_cooldown:  u16, // ticks before this ship may warp again
	active:         bool,
	thrust:         bool, // thrusting this tick (the view's flame)
	shots:          u32,
	gems:           u32,
}

Rock :: struct {
	body:     physics.Body_Ref,
	hit_tick: u32,
	size:     Rock_Size,
	variant:  u8,
	hp:       u8,
	_pad:     u8,
}

Bullet :: struct {
	pos:   [2]f32,
	vel:   [2]f32,
	ttl:   u16,
	owner: u8,
	_pad:  u8,
}

Gem :: struct {
	pos:        [2]f32,
	vel:        [2]f32,
	spawn_tick: u32,
}

Gate :: struct {
	charge: u16, // ticks until it can warp again (0: ready)
	_pad:   u16,
}

State :: struct {
	station:        physics.Body_Ref,
	station_hp:     i32,
	phase:          Phase,
	_pad0:          u8,
	waves:          u16, // waves started this match
	match_tick:     u32,
	over_tick:      u32,
	next_wave_tick: u32,
	next_rock_tick: u32,
	rocks_left:     u32, // of the current wave
	spawner:        u32, // the next rock_spawn marker, in turn
	score:          u32,
	matches:        u32,
	gems_dropped:   u32, // every other small rock drops a gem
	_pad1:          u32, // the Rng's u64 is 8-byte aligned
	rng:            sim.Rng, // the waves' stream
	ships:          [PLAYERS]Ship,
	gates:          [MAX_GATES]Gate,
	rocks:          sim.Table(Rock, MAX_ROCKS),
	bullets:        sim.Table(Bullet, MAX_BULLETS),
	gems:           sim.Table(Gem, MAX_GEMS),
}

// ---- events

// What a tick tells the view (src/sim/SPEC.md "Events"): one plain struct per event, named like the event
// (type name lowercased: "rock_hit"). Positions are in metres on the plane (z = 0). Subjects: `player`, and the
// first handle (a rock's).

// A ship appeared at its spawn.
Event_Joined :: struct {
	position: sim.Position,
	player:   u8,
	_pad:     [3]u8,
}

Event_Left :: struct {
	player: u8,
}

// A bullet left the ship's nose (`position`: the muzzle).
Event_Fired :: struct {
	position: sim.Position,
	player:   u8,
	_pad:     [3]u8,
}

Event_Boosted :: struct {
	position: sim.Position,
	player:   u8,
	_pad:     [3]u8,
}

// A ship warped from gate `from_gate` to `to_gate` (`position`: where it came out).
Event_Warped :: struct {
	position:  sim.Position,
	player:    u8,
	from_gate: u8,
	to_gate:   u8,
	_pad:      u8,
}

// A bullet of `player` hit `rock` at `position` (the hit point).
Event_Rock_Hit :: struct {
	rock:     sim.Handle(Rock),
	position: sim.Position,
	player:   u8,
	size:     Rock_Size,
	_pad:     [2]u8,
}

// `rock` (of `size`, gone now) broke into two of the next size.
Event_Rock_Split :: struct {
	rock:     sim.Handle(Rock),
	position: sim.Position,
	size:     Rock_Size,
	_pad:     [3]u8,
}

// `rock` (a small one, gone now) was shot to pieces.
Event_Rock_Destroyed :: struct {
	rock:     sim.Handle(Rock),
	position: sim.Position,
	size:     Rock_Size,
	_pad:     [3]u8,
}

// A rock of `size` hit the station at `position`: `damage` is what it costs the station's HP during a match.
Event_Station_Hit :: struct {
	position: sim.Position,
	damage:   i32,
	size:     Rock_Size,
	_pad:     [3]u8,
}

Event_Gem_Picked :: struct {
	position: sim.Position,
	player:   u8,
	_pad:     [3]u8,
}

// Event_Wave `wave` (1..) started.
Event_Wave :: struct {
	wave: u16,
}

// `player` sent the `start` that began the match.
Event_Match_Started :: struct {
	player: u8,
}

Event_Match_Over :: struct {
	seconds_survived: f32,
}

Event :: union {
	Event_Joined,
	Event_Left,
	Event_Fired,
	Event_Boosted,
	Event_Warped,
	Event_Rock_Hit,
	Event_Rock_Split,
	Event_Rock_Destroyed,
	Event_Station_Hit,
	Event_Gem_Picked,
	Event_Wave,
	Event_Match_Started,
	Event_Match_Over,
}
