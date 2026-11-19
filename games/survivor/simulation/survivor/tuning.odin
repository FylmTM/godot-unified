package survivor

import "unified:dmath"
import "unified:sim"

// Every rule's number. Times are written in seconds and converted to ticks at compile time: a value that is not a whole
// number of ticks does not compile.

// ---- sizes

MAX_ENEMIES :: 1200
MAX_PROJECTILES :: 512
MAX_GEMS :: 1024
MAX_ITEMS :: 64 // crates and barrels: the most item markers a level may hold
PHYSICS_WORKERS :: 1 // Box3D's step threads: any count steps identically (the suite checks), more take CPU from Godot

// ---- the arena (its walls and pillars are the level's: game/levels/arena.tscn)

ARENA_HALF :: 32 // the ground is 2 * ARENA_HALF square, centred (m); the walls stand inside it
START_RADIUS :: 3.5 // the lobby's start circle at the arena centre (m)
SPAWN_RING :: 27 // enemies spawn this far from the centre (m)
SPAWN_JITTER :: 1 // ... plus or minus this much along each axis, rolled apart (m)
BENCH_HALF :: ARENA_HALF - 4 // the bench pre-spawns its population over this square's half size (m), inside the walls

// ---- players

PLAYER_HP :: 100
PLAYER_SPEED :: 6.0 // m/s
PLAYER_RADIUS :: 0.45 // the capsule's radius and half segment (m)
PLAYER_RESPAWN_TICKS :: u32(3.0 * TICK_HZ)
DASH_TICKS :: u32(0.125 * TICK_HZ)
DASH_COOLDOWN_TICKS :: u32(1.5 * TICK_HZ)
DASH_SPEEDUP :: 3 // speed times this while dashing
GEM_REACH :: 1.5 // a player this close collects a gem (m)

// ---- level-ups

DAMAGE_LEVELUP :: 3 // per "damage" level-up
SPEED_LEVELUP :: 0.5 // m/s per "move speed" level-up
FIRE_LEVELUP_TICKS :: i32(0.03125 * TICK_HZ) // fire interval reduction per "fire rate" level-up

// ---- the auto-attack

FIRE_INTERVAL_TICKS :: i32(0.3125 * TICK_HZ)
FIRE_INTERVAL_MIN_TICKS :: i32(0.09375 * TICK_HZ)
FIRE_RANGE :: 14 // fires at the nearest enemy within this (m)
PROJECTILE_SPEED :: 16 // m/s
PROJECTILE_RADIUS :: 0.15 // m
PROJECTILE_DAMAGE :: 5 // before level-ups
PROJECTILE_LIFE_TICKS :: i32(1.0 * TICK_HZ)

// ---- enemies

CONTACT_COOLDOWN_TICKS :: u16(0.5 * TICK_HZ) // an enemy hurts a player once per this
ENEMY_STEER :: 0.2 // each tick, velocity moves this far towards the desired one
ENEMY_OVERSPEED :: 1.5 // the speed limit, times the enemy's speed (separation can push it past its own)
SEPARATION :: 0.5 // the push between overlapping enemies, over their distance squared
SEPARATION_MIN_SQ :: 1e-8 // two enemies closer than this (squared, m²) stand on one spot: no push (no direction)
CLIMB_CHECK_TICKS :: u32(0.125 * TICK_HZ) // how often an enemy checks whether it stands on an item
CLIMB_HEIGHT :: 0.8 // standing on something higher than this (m) is climbing
CLIMB_SLOWDOWN :: 0.5 // speed times this while climbing
CLIMB_RAY_FROM :: 3 // the climb check casts down from this height (m)

Enemy_Stats :: struct {
	hp:     i32,
	speed:  f32, // m/s
	radius: f32, // m
	damage: i32, // per contact
	xp:     i32, // the gem it drops
}

@(rodata)
ENEMY_STATS := [Enemy_Kind]Enemy_Stats {
	.Grunt = {hp = 10, speed = 2.0, radius = 0.4, damage = 5, xp = 1},
	.Runner = {hp = 6, speed = 3.2, radius = 0.35, damage = 3, xp = 1},
	.Brute = {hp = 40, speed = 1.2, radius = 0.7, damage = 12, xp = 5},
}

// A spawn's kind by its roll in 0 ..< 10: 7 in 10 grunts, 2 runners, 1 brute.
@(rodata)
SPAWN_KINDS := [10]Enemy_Kind{.Grunt, .Grunt, .Grunt, .Grunt, .Grunt, .Grunt, .Grunt, .Runner, .Runner, .Brute}

// ---- crates and barrels

BARREL_HP :: 30
BARREL_RESPAWN_TICKS :: sim.Game_Time(10.0 * TICK_HZ)
CRATE_HALF :: 0.5 // m
BARREL_RADIUS :: 0.4 // the capsule's radius (m)
BARREL_HALF_HEIGHT :: 0.3 // half its segment (m)
// How far from its centre an item reaches on the ground however it lies (m): a crate's half diagonal, a barrel's
// radius plus half its segment. Enemies near an item check whether they stand on it.
CRATE_REACH :: CRATE_HALF * 1.7320508 // √3
BARREL_REACH :: BARREL_RADIUS + BARREL_HALF_HEIGHT
BLAST_RADIUS :: 5 // bodies and enemies within this are hit (m)
BLAST_ENEMY_DAMAGE :: 25
BLAST_PLAYER_RADIUS :: 3 // players within this are hurt (m)
BLAST_PLAYER_DAMAGE :: 15
BLAST_IMPULSE :: 12 // at the centre, falling to 0 at BLAST_RADIUS
BLAST_LIFT :: 0.5 // the impulse's upward part, before normalizing

// ---- phases

OVER_HOLD_S :: 5.0 // the match-over screen, before the world resets
OVER_HOLD_TICKS :: sim.Game_Time(OVER_HOLD_S * TICK_HZ)

// ---- difficulty and roles

HARD_SPAWN_PCT :: 150 // Hard: bursts this % of Normal's
HARD_HP_PCT_PER_WAVE :: 10 // Hard: enemy HP + this % per wave on top of the tuning's
ROLE_FIRE_TICKS :: 3 // a Gunner's shots come this many ticks sooner
ROLE_DAMAGE :: 3 // a Bruiser's shots do this much more
ROLE_SPEED :: 0.75 // a Runner moves this much faster (m/s)

// ---- the pace of a match

// `play` is what people play; `stress` is the dense spawner the headless tests and the bench use (hundreds of
// enemies within a minute); `bench` holds a fixed population (bench_prepare).
Tuning_Kind :: enum u8 {
	Play,
	Stress,
	Bench,
}

Tuning :: struct {
	spawn_every_ticks: u32, // a spawn burst every this many ticks of the match
	spawn_base:        u32, // enemies per burst in wave 0, for one player
	spawn_per_wave:    u32, // + per wave
	spawn_cap:         u32, // max per burst, for one player
	extra_player_pct:  u32, // burst size +x% per present player beyond the first
	wave_ticks:        u32,
	enemy_cap:         u32, // never more enemies than this
	hp_pct_per_wave:   i32, // enemy HP +x% per wave
	xp_first:          i32, // XP from level 1 to 2
	xp_step:           i32, // + per level after that
	endless:           bool, // the match never ends (the bench holds its population)
	_pad:              [3]u8,
}

@(rodata)
TUNINGS := [Tuning_Kind]Tuning {
	.Play = {
		spawn_every_ticks = u32(2.0 * TICK_HZ),
		spawn_base        = 2,
		spawn_per_wave    = 1,
		spawn_cap         = 20,
		extra_player_pct  = 50,
		wave_ticks        = u32(30.0 * TICK_HZ),
		enemy_cap         = MAX_ENEMIES,
		hp_pct_per_wave   = 10,
		xp_first          = 8,
		xp_step           = 4,
	},
	.Stress = {
		spawn_every_ticks = u32(0.3125 * TICK_HZ),
		spawn_base        = 4,
		spawn_per_wave    = 3,
		spawn_cap         = 40,
		extra_player_pct  = 0,
		wave_ticks        = u32(10.0 * TICK_HZ),
		enemy_cap         = MAX_ENEMIES,
		hp_pct_per_wave   = 0,
		xp_first          = 10,
		xp_step           = 5,
	},
	.Bench = {
		spawn_every_ticks = u32(0.3125 * TICK_HZ),
		spawn_base        = 4,
		spawn_per_wave    = 3,
		spawn_cap         = 40,
		extra_player_pct  = 0,
		wave_ticks        = u32(10.0 * TICK_HZ),
		enemy_cap         = MAX_ENEMIES, // bench_prepare lowers it to the population it holds
		hp_pct_per_wave   = 0,
		xp_first          = 10,
		xp_step           = 5,
		endless           = true,
	},
}

// XP needed for the next level from `level` (levels start at 1).
xp_next :: proc(tuning: ^Tuning, level: i32) -> i32 {
	return tuning.xp_first + (dmath.max(level, 1) - 1) * tuning.xp_step
}
