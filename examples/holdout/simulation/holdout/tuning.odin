// Every rule number of holdout (examples/holdout/README.md names them), in seconds, metres and hit points.
package holdout

// ---- players

PLAYER_RADIUS :: f32(0.35)
PLAYER_HALF_HEIGHT :: f32(0.5) // the capsule's segment half length: 1.7 m tall with its radius
EYE_HEIGHT :: f32(0.6) // the eye above the capsule's centre
WALK_SPEED :: f32(6)
PLAYER_HP :: i16(100)
REVIVE_HP :: i16(40) // what a revived player gets up with
REVIVE_S :: f32(3) // a teammate holding Use this long beside a downed player gets them up
REVIVE_RANGE :: f32(1.8) // from the reviver's centre to the downed player's
RESPAWN_S :: f32(12) // a downed player no one revives gets up at the core after this
KILL_Y :: f32(-20) // below this a player fell out of the yard: downed at once

// ---- the rifle

FIRE_INTERVAL_TICKS :: 8 // ticks between shots while Fire is held (8 a second at 64 Hz)
RIFLE_DAMAGE :: i16(18)
HEADSHOT_MULT :: i16(3) // a hit on a head shape does this many times RIFLE_DAMAGE
RIFLE_RANGE :: f32(90)
SPREAD :: f32(0.012) // the most a shot strays from the aim, as a fraction of its range (radians, near enough)
MAX_REWIND_S :: f32(0.1) // the most a shot looks back for what its shooter saw (sim.seen_rewind)

// ---- the grenade

GRENADE_COOLDOWN_S :: f32(5)
GRENADE_SPEED :: f32(15) // thrown along the aim, plus the thrower's own velocity
GRENADE_RADIUS :: f32(0.12)
GRENADE_DENSITY :: f32(800)
GRENADE_RESTITUTION :: f32(0.45) // it bounces
FUSE_S :: f32(2.2) // it explodes this long after the throw, or at once on touching an enemy
BLAST_RADIUS :: f32(5)
BLAST_DAMAGE :: i16(140) // at the centre, down to a third at the edge
TOUCH_RADIUS :: f32(0.6) // an enemy's capsule this close sets a grenade off

// ---- enemies

Enemy_Kind :: enum u8 {
	Runner, // fast and fragile: chases a player it sees, else the core; hits in melee
	Brute, // slow and tough: ignores players and hits the core
	Spitter, // stops at SPIT_RANGE from its target and fires bolts
}

// What an enemy kind is: its body, speed, health and attack.
Enemy_Spec :: struct {
	radius:      f32, // its capsule
	half_height: f32, // the capsule's segment half length
	head_radius: f32, // the head sphere on top
	speed:       f32,
	hp:          i16,
	damage:      i16, // per attack on a player (a bolt's, for a spitter)
	core_damage: i16, // per attack on the core
	attack_s:    f32, // between attacks
	reach:       f32, // a melee attack lands within this of its target's surface
	chases:      bool, // goes for players it sees (a brute doesn't)
}

@(rodata)
ENEMY_SPECS := [Enemy_Kind]Enemy_Spec {
	.Runner = {
		radius      = 0.35,
		half_height = 0.45,
		head_radius = 0.22,
		speed       = 5.2,
		hp          = 45,
		damage      = 9,
		core_damage = 3,
		attack_s    = 0.7,
		reach       = 0.6,
		chases      = true,
	},
	.Brute = {
		radius      = 0.5,
		half_height = 0.55,
		head_radius = 0.3,
		speed       = 2.4,
		hp          = 300,
		damage      = 30,
		core_damage = 30,
		attack_s    = 1.2,
		reach       = 0.8,
	},
	.Spitter = {
		radius      = 0.35,
		half_height = 0.5,
		head_radius = 0.24,
		speed       = 3.4,
		hp          = 70,
		damage      = 11,
		core_damage = 11,
		attack_s    = 1.6,
		reach       = 0.6,
		chases      = true,
	},
}

AGGRO_RADIUS :: f32(24) // a runner or spitter goes for the nearest player it can see within this
SIGHT_EVERY_TICKS :: 16 // an enemy looks for a player this often (time-sliced: sim.due)
SPIT_RANGE :: f32(14) // a spitter stops this far from its target and fires
SPIT_REACH :: f32(20) // and fires at what it sees within this
SEPARATION :: f32(1.0) // enemies closer than this push apart
SEPARATION_SPEED :: f32(2.5) // at most, metres per second
SAME_FLOOR :: f32(1.5) // enemies further apart in height than this don't push (stacked floors)
GOAL_REACH :: f32(2.5) // a target's point on the mesh: nav.nearest within this
CORE_REACH :: f32(0.9) // an enemy hits the core within this of the core's side

// ---- bolts

BOLT_SPEED :: f32(13)
BOLT_LIFE_S :: f32(3)

// ---- the core and the run

CORE_HP :: i32(4000)
CORE_HALF :: f32(1.2) // the core's half width (the level's Core body: 2.4 m square)
START_DELAY_S :: f32(5) // the countdown after a player presses Ready in the lobby
WAVE_BREAK_S :: f32(8)
OVER_HOLD_S :: f32(6) // the result shows this long, then the yard resets to the lobby
ENEMY_CAP :: 48 // the most enemies alive at once: a burst waits while the yard is full

// One burst of a wave: `count` enemies of a kind from a gate, the first `start_s` into the wave, then one every
// `every_s`. Scaled by the players present (scaled_count).
Burst :: struct {
	gate:    u8,
	kind:    Enemy_Kind,
	count:   u8,
	start_s: f32,
	every_s: f32,
}

MAX_BURSTS :: 6 // the most bursts a wave has
WAVES :: 8

// The waves, by number: each a list of at most MAX_BURSTS bursts.
@(rodata)
WAVE_PLANS := [WAVES][]Burst {
	{{0, .Runner, 6, 0, 1.2}, {1, .Runner, 4, 4, 1.5}},
	{{0, .Runner, 6, 0, 1}, {1, .Runner, 6, 2, 1}, {2, .Spitter, 2, 6, 3}},
	{{2, .Runner, 8, 0, 0.8}, {0, .Brute, 1, 3, 1}, {1, .Spitter, 3, 5, 2.5}},
	{{0, .Runner, 10, 0, 0.7}, {1, .Runner, 10, 0, 0.7}, {2, .Brute, 2, 4, 4}},
	{{0, .Spitter, 4, 0, 2}, {1, .Spitter, 4, 1, 2}, {2, .Runner, 12, 0, 0.6}, {0, .Brute, 2, 6, 3}},
	{{0, .Runner, 12, 0, 0.5}, {1, .Runner, 12, 0, 0.5}, {2, .Runner, 12, 0, 0.5}, {1, .Brute, 3, 3, 3}},
	{{0, .Brute, 3, 0, 3}, {1, .Brute, 3, 0, 3}, {2, .Spitter, 6, 2, 1.5}, {0, .Runner, 14, 2, 0.5}},
	{
		{0, .Runner, 16, 0, 0.4},
		{1, .Runner, 16, 0, 0.4},
		{2, .Runner, 16, 0, 0.4},
		{0, .Brute, 4, 4, 2.5},
		{1, .Spitter, 6, 2, 1.5},
		{2, .Brute, 4, 6, 2.5},
	},
}

// A burst's count for the players present: half again for each player past the first.
scaled_count :: proc(burst: Burst, players: int) -> int {
	return int(burst.count) + int(burst.count) * (players - 1) / 2
}
