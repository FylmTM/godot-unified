package drift

import "unified:sim"

// Every rule's number. Metres and seconds; angular velocities in radians (Box3D's), angles in turns (dmath's). Times
// are written in seconds and converted to ticks at compile time: a value that is not a whole number of ticks does not
// compile.

// ---- sizes

MAX_ROCKS :: 128
MAX_BULLETS :: 256
MAX_GEMS :: 64
MAX_GATES :: 8
MAX_SPAWNERS :: 16 // rock_spawn markers
PHYSICS_WORKERS :: 1 // Box3D's step threads: any count steps identically (the suite checks), more take CPU from Godot
BODY_DEPTH :: 1 // the station's and the rocks' thickness across the plane (m)

// ---- ships

SHIP_RADIUS :: 0.5 // m
SHIP_DENSITY :: 4
SHIP_DAMPING :: 1.4 // linear damping: the terminal speed is THRUST_ACCEL / SHIP_DAMPING
SHIP_RESTITUTION :: 0.5
SHIP_FRICTION :: 0.1
THRUST_ACCEL :: 14 // m/s² at full stick
TURN_GAIN :: 8 // the turn rate (rad/s) per unit of sine between the heading and the aim
TURN_MAX :: 6 // rad/s; the rate when the aim is behind
BOOST_SPEED :: 8 // m/s added along the heading
BOOST_COOLDOWN_TICKS :: u32(1.5 * TICK_HZ)

// ---- bullets

FIRE_EVERY_TICKS :: u32(0.125 * TICK_HZ) // while fire is held
BULLET_SPEED :: 18 // m/s along the heading, plus the ship's velocity
BULLET_LIFE_TICKS :: u16(0.875 * TICK_HZ)
BULLET_PUSH :: 0.6 // the impulse along the bullet on the rock it hits (N·s)
MUZZLE_GAP :: 0.1 // a bullet starts this far ahead of the ship's edge (m)

// ---- the station

STATION_RADIUS :: 2.5 // the hexagon's corners (m)
STATION_SPIN :: 0.25 // rad/s, not while the match is over
STATION_HP :: 100

// ---- rocks

ROCK_DENSITY :: 1
ROCK_RESTITUTION :: 0.4
ROCK_FRICTION :: 0.3
ROCK_SPLIT_SPEED :: 2.5 // the two halves move apart at this, across the parent's velocity (m/s)
ROCK_SPLIT_GAP :: 0.9 // the halves start this many of their radii either side of the parent's centre
ROCK_SPLIT_SPIN :: 0.5 // each half spins at this times the parent's spin, the second the other way

Rock_Stats :: struct {
	radius:         f32, // m
	hp:             u8, // bullet hits
	station_damage: i32, // what it costs the station
}

@(rodata)
ROCK_STATS := [Rock_Size]Rock_Stats {
	.Small = {radius = 0.6, hp = 1, station_damage = 2},
	.Medium = {radius = 1.0, hp = 3, station_damage = 5},
	.Large = {radius = 1.6, hp = 6, station_damage = 10},
}

ROCK_VARIANTS :: 4

// The rock shapes: 8 corners at the 8 compass directions (dmath.DIR8), each at this fraction of the rock's radius. The
// body is their convex hull (the view draws the same hull).
@(rodata)
ROCK_SHAPES := [ROCK_VARIANTS][8]f32 {
	{1.0, 0.82, 0.95, 0.78, 1.0, 0.86, 0.92, 0.8},
	{0.9, 1.0, 0.76, 0.94, 0.84, 1.0, 0.8, 0.9},
	{0.8, 0.92, 1.0, 0.85, 0.78, 0.95, 1.0, 0.88},
	{1.0, 0.78, 0.88, 1.0, 0.9, 0.76, 0.96, 0.84},
}

// ---- waves

WAVE_EVERY_TICKS :: u32(20 * TICK_HZ)
WAVE_ROCKS :: 3 // large rocks in the first wave
WAVE_ROCKS_MORE :: 2 // ... and this many more in each wave after it
ROCK_EVERY_TICKS :: u32(1.5 * TICK_HZ) // between a wave's rocks
ROCK_SPEED :: 2 // m/s in the first wave
ROCK_SPEED_PER_WAVE :: 0.2 // m/s more in each wave after it
ROCK_SPREAD_TURNS :: 0.04 // a rock's direction turns up to this either way from its spawn marker's (turns: 14.4°)
ROCK_SPIN_MAX :: 1 // a new rock spins up to this either way (rad/s)

// ---- gates

GATE_RADIUS :: 0.8 // a ship whose centre comes this close warps (m)
GATE_CHARGE_TICKS :: u32(2 * TICK_HZ) // both gates of a warp, and the ship, before the next

// ---- gems

GEM_DROP_EVERY :: 2 // one small rock in this many drops a gem
GEM_THROW :: 0.3 // a gem leaves at this times the rock's velocity
GEM_DRAG :: 0.98 // its velocity times this each tick
GEM_PICK_RADIUS :: 1 // m
GEM_LIFE_TICKS :: sim.Game_Time(10 * TICK_HZ)
GEM_REPAIR :: 2 // station HP per gem, up to STATION_HP

// ---- phases

OVER_HOLD_TICKS :: u32(5 * TICK_HZ) // the match-over screen, before the world resets
