package horde

// Every rule number, in sim units (a unit is a metre-sized cell: the views draw UNIT_PX pixels per unit) and seconds.

ARENA_HALF :: f32(30) // the arena is a square of twice this, centred on the origin

// Heroes
HERO_RADIUS :: f32(0.4)
HERO_SPEED :: f32(5)
HERO_SPEED_LEVELUP :: f32(0.5) // Upgrade.Move_Speed
HERO_HP :: i32(100)
HERO_HP_LEVELUP :: i32(25) // Upgrade.Max_Hp: raises the most and heals as much
HERO_HURT_COOLDOWN_S :: f32(0.5) // after a hit, no hit for this long
HERO_RESPAWN_S :: f32(5)
HERO_SPAWN_SPACING :: f32(1.5) // slot k starts this far right of slot k - 1

// Enemies
MAX_ENEMIES :: 4096
SPAWN_EVERY_S :: f32(0.5) // a burst every half second of the match
SPAWN_BASE :: u32(6) // a burst's size at wave 0
SPAWN_PER_WAVE :: u32(4) // and this many more per wave
SPAWN_CAP :: u32(80) // the largest burst
ENEMY_CAP :: u32(3000) // no burst past this many alive (the bench holds its own count)
WAVE_S :: f32(20) // a wave is this long
SPAWN_RING :: f32(26) // bursts appear on this ring around the arena's centre
SPAWN_JITTER :: f32(3) // plus up to this along each axis
ENEMY_STEER :: f32(0.15) // how much of the desired velocity each tick blends in
ENEMY_OVERSPEED :: f32(1.4) // pushes may carry an enemy this much over its speed
SEPARATION :: f32(0.6) // how hard overlapping enemies push apart
SEPARATION_MIN_SQ :: f32(0.0001) // closer than this, no push (no division by ~0)
HP_PCT_PER_WAVE :: i32(15) // enemies spawn with this much more HP per wave

// What each kind of enemy is (Enemy_Kind).
Enemy_Stats :: struct {
	hp:     i32,
	speed:  f32,
	radius: f32,
	damage: i32, // a touch on a hero
	xp:     i32, // its gem's value
}

@(rodata)
ENEMY_STATS := [Enemy_Kind]Enemy_Stats {
	.Grunt = {hp = 20, speed = 1.6, radius = 0.35, damage = 6, xp = 1},
	.Runner = {hp = 10, speed = 2.9, radius = 0.28, damage = 4, xp = 1},
	.Brute = {hp = 90, speed = 1.1, radius = 0.6, damage = 14, xp = 4},
}

// A burst's kinds, rolled by index: grunts mostly.
@(rodata)
SPAWN_KINDS := [8]Enemy_Kind{.Grunt, .Grunt, .Grunt, .Runner, .Grunt, .Runner, .Grunt, .Brute}

// Bolts: auto-aimed at the nearest enemy, a fan of `bolt_count`, each piercing `bolt_pierce` enemies.
MAX_BOLTS :: 2048
BOLT_INTERVAL_S :: f32(0.5)
BOLT_INTERVAL_MIN_TICKS :: u32(6)
BOLT_INTERVAL_LEVELUP_TICKS :: u32(4) // Upgrade.Fire_Rate
BOLT_SPEED :: f32(14)
BOLT_LIFE_S :: f32(1.2)
BOLT_RADIUS :: f32(0.15)
BOLT_DAMAGE :: i32(12)
BOLT_SPREAD_TURNS :: f32(0.02) // between two bolts of a fan
BOLT_RANGE :: f32(14) // no enemy closer: no shot

// Chain lightning: from the hero to the nearest enemy in range, then on to the nearest not yet struck, `chains` times.
LIGHTNING_INTERVAL_S :: f32(1.2)
LIGHTNING_RANGE :: f32(8)
LIGHTNING_CHAIN_RANGE :: f32(3.5)
LIGHTNING_DAMAGE :: i32(18)
LIGHTNING_CHAINS :: u8(3) // at level 1
CHAIN_MAX :: 16 // the most enemies one strike reaches

// Bombs: lobbed at the nearest enemy, they land after BOMB_FLIGHT_S and blast everything within `blast_radius`.
MAX_BOMBS :: 128
MAX_BLASTS :: 128
BOMB_INTERVAL_S :: f32(2)
BOMB_FLIGHT_S :: f32(0.6)
BOMB_RANGE :: f32(10)
BLAST_RADIUS :: f32(2.2) // at level 1
BLAST_RADIUS_LEVELUP :: f32(0.4) // Upgrade.Bomb_Radius
BLAST_DAMAGE :: i32(30)
BLAST_SHOW_S :: f32(0.4) // a blast stays in the state this long, for the views

// Gems and levels
MAX_GEMS :: 4096
GEM_MAGNET :: f32(3) // a gem this near a hero flies to them
GEM_SPEED :: f32(10)
GEM_PICKUP :: f32(0.5)
XP_BASE :: i32(5) // level n -> n + 1 takes XP_BASE + XP_PER_LEVEL * n
XP_PER_LEVEL :: i32(5)

// The phase
OVER_HOLD_S :: f32(3) // every hero down: the arena resets after this
