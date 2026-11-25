package horde

import "unified:sim"

// The whole simulation state: one pointer-free block (checked by sim.create). Everything tick reads across ticks lives
// here: kept anywhere else (the World, a package variable), it desyncs after a rollback (src/sim/README.md, The
// state block).
State :: struct {
	clock:      sim.Clock, // game time (no pause: a horde game runs on)
	phase:      Phase,
	_pad:       [3]u8,
	match_tick: sim.Game_Time, // the tick the current match started
	over_hold:  sim.Timer, // over: the hold before the reset
	wave:       u32, // 0-based wave of the current match (its age / WAVE_S)
	bench_hold: u32, // the bench's population (bench_prepare): the waves refill to it; 0: play
	kills:      u32, // enemies killed this match
	players:    sim.Players(Hero, sim.No_Profile, Input, PLAYERS),
	enemies:    sim.Table(Enemy, MAX_ENEMIES),
	bolts:      sim.Table(Bolt, MAX_BOLTS),
	bombs:      sim.Table(Bomb, MAX_BOMBS),
	blasts:     sim.Table(Blast, MAX_BLASTS),
	gems:       sim.Table(Gem, MAX_GEMS),
}

// match: waves run; over: every present hero is down, and the arena resets after OVER_HOLD_S.
Phase :: enum u8 {
	Match,
	Over,
}

// A hero's state and progress (the State's sim.Players data): zeroed for someone new, kept while they are away.
Hero :: struct {
	pos:              [2]f32,
	vel:              [2]f32, // this tick's move, for the views (facing, trails)
	hp:               i32,
	hp_max:           i32,
	speed:            f32,
	level:            i32,
	xp:               i32,
	pending_levelups: i32,
	hurt:             sim.Timer, // no hit while it runs (HERO_HURT_COOLDOWN_S); a view flashes while it runs
	respawn:          sim.Timer, // a downed hero stands up when it runs out (HERO_RESPAWN_S)
	bolt_ready:       sim.Timer,
	lightning_ready:  sim.Timer,
	bomb_ready:       sim.Timer,
	bolt_interval:    u32, // ticks between fans (Upgrade.Fire_Rate lowers it)
	blast_radius:     f32,
	bolt_count:       u8, // bolts per fan
	bolt_pierce:      u8, // enemies one bolt hits
	chains:           u8, // enemies one lightning strike reaches
	alive:            bool,
	warp:             u8, // bumped by each respawn: a view snaps to the new spot
	_pad:             [3]u8,
}

Enemy_Kind :: enum u8 {
	Grunt,
	Runner,
	Brute,
}

// An enemy on the arena's plane.
Enemy :: struct {
	pos:      [2]f32,
	vel:      [2]f32,
	hp:       i32,
	hp_max:   i32,
	hit_tick: sim.Game_Time, // the last tick it took damage (0: never): a view's hit flash
	kind:     Enemy_Kind,
	_pad:     [3]u8,
}

// A bolt in flight: it moves BOLT_SPEED along its direction until its life runs out or it has pierced its last enemy.
Bolt :: struct {
	pos:      [2]f32,
	vel:      [2]f32,
	life:     u32, // ticks left
	last_hit: sim.Handle(Enemy), // the enemy it hit last ({}: none), so it never hits one twice in a row
	pierce:   u8, // enemies it may still hit
	slot:     u8, // the hero's slot when fired, for its colour
	_pad:     [2]u8,
}

// A bomb in the air, from `from` to `to`, landing when `flight` runs out.
Bomb :: struct {
	from:   [2]f32,
	to:     [2]f32,
	flight: sim.Timer,
	radius: f32,
	slot:   u8,
	_pad:   [3]u8,
}

// A blast where a bomb landed: it hurt every enemy within `radius` on its first tick and stays for the views.
Blast :: struct {
	pos:    [2]f32,
	radius: f32,
	show:   sim.Timer, // gone when it runs out (BLAST_SHOW_S)
	slot:   u8,
	_pad:   [3]u8,
}

// An XP gem dropped by an enemy.
Gem :: struct {
	pos:   [2]f32,
	value: i32,
}

// The world outside the block: scratch, rebuilt every tick and never snapshotted.
World :: struct {
	grid:    Enemy_Grid,
	near:    [MAX_ENEMIES]Near_Enemy, // in the grid's order (grid.ids): what the separation pass reads
	push:    [MAX_ENEMIES][2]f32, // in the grid's order: each enemy's separation, summed by the pass
	new_vel: [MAX_ENEMIES][2]f32,
	struck:  [CHAIN_MAX]i32, // one lightning strike's enemies so far
}

// An enemy as its neighbours' separation sees it: a copy, rebuilt every tick by steer_enemies.
Near_Enemy :: struct {
	pos:    [2]f32,
	radius: f32,
}

// What the keyed rolls are for (sim.roll_below, sim.roll_f32).
Roll :: enum u8 {
	Spawn_Direction,
	Spawn_Jitter_X,
	Spawn_Jitter_Y,
	Spawn_Kind,
	Upgrade_Offer,
}
