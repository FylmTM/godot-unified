//! Constants from spec/GAME.md.

pub const SUBSTEPS: i32 = 4;
pub const GRAVITY_Y: f32 = -10.0;
pub const ARENA: f32 = 30.0;

/// Angle table for k * 45 degrees (cos, sin); spec: use this table, not trig.
pub const COS: [f32; 8] = [1.0, 0.70710677, 0.0, -0.70710677, -1.0, -0.70710677, 0.0, 0.70710677];
pub const SIN: [f32; 8] = [0.0, 0.70710677, 1.0, 0.70710677, 0.0, -0.70710677, -1.0, -0.70710677];

pub const PILLAR_RING: f32 = 14.0;
pub const PILLAR_HALF: [f32; 3] = [1.0, 1.5, 1.0];

pub const PLAYER_RADIUS: f32 = 0.45;
pub const PLAYER_HALF_SEGMENT: f32 = 0.45;
pub const PLAYER_START: [[f32; 3]; 4] = [[4.0, 1.0, 4.0], [-4.0, 1.0, 4.0], [4.0, 1.0, -4.0], [-4.0, 1.0, -4.0]];
pub const PLAYER_HP: i32 = 100;
pub const PLAYER_SPEED: f32 = 6.0;
pub const RESPAWN_TICKS: u32 = 180;
pub const DASH_MULT: f32 = 3.0;
pub const DASH_TICKS: u32 = 8;
pub const DASH_COOLDOWN: u32 = 90;
pub const FIRE_INTERVAL: u32 = 20;
pub const FIRE_INTERVAL_MIN: u32 = 6;
pub const FIRE_RANGE: f32 = 14.0;

pub const CRATE_HALF: f32 = 0.5;
pub const BARREL_RADIUS: f32 = 0.4;
pub const BARREL_HALF_SEGMENT: f32 = 0.3;
pub const BARREL_HP: i32 = 30;
pub const BARREL_RESPAWN: u32 = 600;
pub const EXPLOSION_RADIUS: f32 = 5.0;
pub const EXPLOSION_IMPULSE: f32 = 12.0;
pub const EXPLOSION_ENEMY_DAMAGE: i32 = 25;
pub const EXPLOSION_PLAYER_RADIUS: f32 = 3.0;
pub const EXPLOSION_PLAYER_DAMAGE: i32 = 15;

pub const SPAWN_RING: f32 = 27.0;
pub const SPAWN_EVERY: u32 = 20;
pub const WAVE_TICKS: u32 = 600;
pub const SPAWN_MAX_BATCH: u32 = 40;

pub const CONTACT_COOLDOWN: u8 = 30;
pub const CLIMB_EVERY: u32 = 8;
pub const CLIMB_RAY_Y: f32 = 3.0;
pub const CLIMB_MIN_Y: f32 = 0.8;

pub const PROJECTILE_SPEED: f32 = 16.0;
pub const PROJECTILE_LIFE: u16 = 60;
pub const PROJECTILE_RADIUS: f32 = 0.15;
pub const PROJECTILE_DAMAGE: i32 = 5;

pub const GEM_PICKUP: f32 = 1.5;

/// Spatial grid: 2 m cells over the 60 x 60 arena.
pub const CELL: f32 = 2.0;
pub const GRID: i32 = 30;

#[derive(Clone, Copy)]
pub struct EnemyKind {
    pub hp: i32,
    pub speed: f32,
    pub radius: f32,
    pub damage: i32,
    pub xp: u8,
}

/// 0 grunt, 1 runner, 2 brute.
pub const KINDS: [EnemyKind; 3] = [
    EnemyKind { hp: 10, speed: 2.0, radius: 0.4, damage: 5, xp: 1 },
    EnemyKind { hp: 6, speed: 3.2, radius: 0.35, damage: 3, xp: 1 },
    EnemyKind { hp: 40, speed: 1.2, radius: 0.7, damage: 12, xp: 5 },
];

/// Collision categories: players are excluded from gameplay ray casts (a projectile starts inside
/// its shooter's capsule; Box3D reports a ray starting inside a capsule as a hit at fraction 0).
pub const CAT_WORLD: u64 = 1;
pub const CAT_PLAYER: u64 = 2;
pub const RAY_MASK: u64 = !CAT_PLAYER;

/// Shape user ids (material `userMaterialId`), returned by ray casts: kind << 32 | index.
pub const UID_STATIC: u64 = 0;
pub const UID_CRATE: u64 = 1 << 32;
pub const UID_BARREL: u64 = 2 << 32;
pub const UID_PLAYER: u64 = 3 << 32;
