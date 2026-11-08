//! The state block: one pointer-free, padding-free `bytemuck::Pod` struct.
//!
//! `#[derive(Pod)]` rejects, at compile time, any field that isn't plain data (references, `Box`,
//! `Vec`, raw pointers) and any implicit padding, so `bytes_of(&state)` is a canonical image: the
//! checksum hashes it directly (every target is little-endian) and a snapshot is a memcpy.
//! Physics bodies are referenced by stored Box3D ids ([`BodyRef`]); the Box3D world is the only
//! state outside the block. Tables are fixed-capacity with free lists (stable indices) and
//! per-slot generations ([`Handle`]).

use bytemuck::{Pod, Zeroable};
use simcore::MAX_PLAYERS;

pub const MAX_ENEMIES: usize = 1200;
pub const MAX_PROJECTILES: usize = 512;
pub const MAX_GEMS: usize = 1024;
/// Crates + barrels on the 5x8 grid.
pub const N_ITEMS: usize = 40;
/// Items with `i % 5 == 2` are barrels (spec/GAME.md; see README: that rule gives 8, not 16).
pub const N_BARRELS: usize = {
    let mut n = 0;
    let mut i = 0;
    while i < N_ITEMS {
        if i % 5 == 2 {
            n += 1;
        }
        i += 1;
    }
    n
};

/// A Box3D body id without its world index (see box3d_sys::BodyKey). `live == 0`: no body.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Pod, Zeroable)]
pub struct BodyRef {
    pub index1: i32,
    pub generation: u16,
    pub live: u16,
}

/// Generational handle into a fixed-capacity table.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Pod, Zeroable)]
pub struct Handle {
    pub index: u16,
    pub generation: u16,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Pod, Zeroable)]
pub struct Player {
    pub body: BodyRef,
    /// Position read back after the physics step (system 11).
    pub pos: [f32; 3],
    pub hp: i32,
    pub xp: u32,
    pub level: u32,
    pub pending_levelups: u32,
    pub fire_interval: u32,
    pub fire_cooldown: u32,
    pub damage_bonus: u32,
    pub move_speed: f32,
    pub dash_ticks: u32,
    pub dash_cooldown: u32,
    pub respawn: u32,
    pub active: u8,
    pub alive: u8,
    pub prev_buttons: u8,
    pub _pad: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Pod, Zeroable)]
pub struct Barrel {
    pub body: BodyRef,
    /// Grid item index (spawn spot).
    pub item: u32,
    pub hp: i32,
    pub respawn: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct Enemies {
    pub px: [f32; MAX_ENEMIES],
    pub pz: [f32; MAX_ENEMIES],
    pub vx: [f32; MAX_ENEMIES],
    pub vz: [f32; MAX_ENEMIES],
    pub hp: [i32; MAX_ENEMIES],
    pub generation: [u16; MAX_ENEMIES],
    pub free: [u16; MAX_ENEMIES],
    pub kind: [u8; MAX_ENEMIES],
    pub alive: [u8; MAX_ENEMIES],
    pub climbing: [u8; MAX_ENEMIES],
    pub contact_cd: [u8; MAX_ENEMIES],
    pub free_count: u32,
    pub count: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct Projectiles {
    pub px: [f32; MAX_PROJECTILES],
    pub py: [f32; MAX_PROJECTILES],
    pub pz: [f32; MAX_PROJECTILES],
    pub vx: [f32; MAX_PROJECTILES],
    pub vz: [f32; MAX_PROJECTILES],
    pub damage: [i32; MAX_PROJECTILES],
    pub life: [u16; MAX_PROJECTILES],
    pub generation: [u16; MAX_PROJECTILES],
    pub free: [u16; MAX_PROJECTILES],
    pub alive: [u8; MAX_PROJECTILES],
    pub owner: [u8; MAX_PROJECTILES],
    pub free_count: u32,
    pub count: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct Gems {
    pub px: [f32; MAX_GEMS],
    pub pz: [f32; MAX_GEMS],
    pub generation: [u16; MAX_GEMS],
    pub free: [u16; MAX_GEMS],
    pub value: [u8; MAX_GEMS],
    pub alive: [u8; MAX_GEMS],
    pub free_count: u32,
    pub count: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct State {
    /// Completed ticks: the state after the k-th step is tick k.
    pub tick: u32,
    /// The spawner's xorshift32.
    pub rng: u32,
    pub seed_lo: u32,
    pub seed_hi: u32,
    /// Alive-enemy cap for the spawner: 1200, or the `bench --enemies` count.
    pub enemy_limit: u32,
    /// Bitmask of the players created with the world (before tick 1).
    pub initial_mask: u32,
    pub players: [Player; MAX_PLAYERS],
    /// Crate and barrel bodies in grid item order.
    pub items: [BodyRef; N_ITEMS],
    pub barrels: [Barrel; N_BARRELS],
    pub enemies: Enemies,
    pub projectiles: Projectiles,
    pub gems: Gems,
}

impl State {
    pub fn seed(&self) -> u64 {
        self.seed_lo as u64 | ((self.seed_hi as u64) << 32)
    }
}

/// Free-list tables with stable indices: `alloc` pops the lowest never-reused index first, `release`
/// bumps the slot's generation so stale handles are detected. Removing never reorders live slots.
macro_rules! impl_table {
    ($t:ty, $n:expr) => {
        impl $t {
            pub const CAPACITY: usize = $n;

            pub fn reset(&mut self) {
                for i in 0..$n {
                    self.free[i] = ($n - 1 - i) as u16;
                }
                self.free_count = $n as u32;
                self.count = 0;
            }

            pub fn alloc(&mut self) -> Option<Handle> {
                if self.free_count == 0 {
                    return None;
                }
                self.free_count -= 1;
                let i = self.free[self.free_count as usize] as usize;
                self.alive[i] = 1;
                self.count += 1;
                Some(Handle { index: i as u16, generation: self.generation[i] })
            }

            pub fn release(&mut self, i: usize) {
                debug_assert!(self.alive[i] == 1);
                self.alive[i] = 0;
                self.generation[i] = self.generation[i].wrapping_add(1);
                self.free[self.free_count as usize] = i as u16;
                self.free_count += 1;
                self.count -= 1;
            }

            pub fn is_live(&self, h: Handle) -> bool {
                let i = h.index as usize;
                i < $n && self.alive[i] == 1 && self.generation[i] == h.generation
            }
        }
    };
}
impl_table!(Enemies, MAX_ENEMIES);
impl_table!(Projectiles, MAX_PROJECTILES);
impl_table!(Gems, MAX_GEMS);

pub const STATE_BYTES: usize = core::mem::size_of::<State>();
const _: () = assert!(core::mem::align_of::<State>() == 4 && STATE_BYTES.is_multiple_of(4) && STATE_BYTES < 128 * 1024);
