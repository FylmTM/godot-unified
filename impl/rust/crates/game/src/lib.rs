//! Survivor-lite (spec/GAME.md) on the unified core: [`Game`] implements
//! [`simcore::Simulation`].

pub mod consts;
pub mod grid;
pub mod rng;
pub mod script;
pub mod state;
pub mod systems;
pub mod world;

use box3d_sys::{World, WorldState};
use bytemuck::Zeroable;
use simcore::{InputSet, Simulation};
use state::{MAX_ENEMIES, N_ITEMS, STATE_BYTES, State};
use xxhash_rust::xxh3::{Xxh3, xxh3_64};

pub use script::{PlayerScript, ScriptGen, Scripted};

pub struct Game {
    /// The state block (boxed: ~70 KB).
    pub s: Box<State>,
    world: World,
    grid: Box<grid::Grid>,
    nv: Vec<[f32; 2]>,
}

/// A ring slot: a copy of the block plus a Box3D world image.
pub struct Slot {
    block: Box<State>,
    phys: WorldState,
    tick: u32,
}

const SNAP_MAGIC: &[u8; 4] = b"UNIS";
const SNAP_VERSION: u16 = 1;
const SNAP_HEADER: usize = 4 + 2 + 2 + 4 + 4;

impl Game {
    /// A fresh game before tick 1: the world built in spec order, the players in `initial_mask`
    /// joined, the spawner's rng seeded (`seed as u32`, 0 -> 1).
    pub fn new(seed: u64, initial_mask: u8, enemy_limit: u32) -> Game {
        let mut s: Box<State> = bytemuck::zeroed_box();
        s.seed_lo = seed as u32;
        s.seed_hi = (seed >> 32) as u32;
        s.rng = rng::seed32(seed);
        s.enemy_limit = enemy_limit.min(MAX_ENEMIES as u32);
        s.initial_mask = initial_mask as u32;
        s.enemies.reset();
        s.projectiles.reset();
        s.gems.reset();
        let world = world::create_world(&mut s);
        Game { s, world, grid: grid::Grid::new_boxed(), nv: vec![[0.0; 2]; MAX_ENEMIES] }
    }

    pub fn mask_of(players: usize) -> u8 {
        ((1u32 << players.min(4)) - 1) as u8
    }

    /// `bench`: pre-spawn enemies.
    pub fn prespawn(&mut self, n: u32) {
        systems::prespawn(&mut self.s, n);
    }

    pub fn alive_enemies(&self) -> u32 {
        self.s.enemies.count
    }

    /// Builds a game from a portable snapshot (`snapshot` / `resume`).
    pub fn from_snapshot(bytes: &[u8]) -> Result<Game, String> {
        let block = parse_snapshot(bytes)?.0;
        let s: State = bytemuck::pod_read_unaligned(block);
        let mut g = Game::new(s.seed(), s.initial_mask as u8, s.enemy_limit);
        g.import(bytes)?;
        Ok(g)
    }

    fn body_bytes(&self, out: &mut Vec<u8>) {
        let w = &self.world;
        let mut put = |b: state::BodyRef| {
            let k = world::key(b);
            let p = w.position(k);
            let q = w.rotation(k);
            let v = w.linear_velocity(k);
            let a = w.angular_velocity(k);
            for f in [p.x, p.y, p.z, q.v.x, q.v.y, q.v.z, q.s, v.x, v.y, v.z, a.x, a.y, a.z] {
                let f = if f == 0.0 { 0.0f32 } else { f }; // -0.0 -> +0.0
                out.extend_from_slice(&f.to_le_bytes());
            }
        };
        for i in 0..N_ITEMS {
            if self.s.items[i].live != 0 {
                put(self.s.items[i]);
            }
        }
        for pl in self.s.players.iter() {
            if pl.alive != 0 {
                put(pl.body);
            }
        }
    }
}

fn parse_snapshot(bytes: &[u8]) -> Result<(&[u8], &[u8]), String> {
    if bytes.len() < SNAP_HEADER + 8 || &bytes[0..4] != SNAP_MAGIC {
        return Err("not a unified snapshot (bad magic)".into());
    }
    let version = u16::from_le_bytes([bytes[4], bytes[5]]);
    if version != SNAP_VERSION {
        return Err(format!("snapshot version {version}, expected {SNAP_VERSION}"));
    }
    let block_len = u32::from_le_bytes(bytes[8..12].try_into().unwrap()) as usize;
    let phys_len = u32::from_le_bytes(bytes[12..16].try_into().unwrap()) as usize;
    if block_len != STATE_BYTES {
        return Err(format!("snapshot block is {block_len} bytes, this build's State is {STATE_BYTES}"));
    }
    let end = SNAP_HEADER + block_len + phys_len;
    if bytes.len() != end + 8 {
        return Err("snapshot size mismatch".into());
    }
    let sum = u64::from_le_bytes(bytes[end..end + 8].try_into().unwrap());
    if xxh3_64(&bytes[..end]) != sum {
        return Err("snapshot checksum mismatch".into());
    }
    Ok((&bytes[SNAP_HEADER..SNAP_HEADER + block_len], &bytes[SNAP_HEADER + block_len..end]))
}

impl Simulation for Game {
    type Slot = Slot;

    fn new_slot(&mut self) -> Slot {
        Slot { block: bytemuck::zeroed_box(), phys: self.world.new_state(), tick: u32::MAX }
    }

    fn tick(&self) -> u32 {
        self.s.tick
    }

    fn step(&mut self, inputs: &InputSet) {
        let t = self.s.tick;
        let Game { s, world, grid, nv } = self;
        systems::players(s, world, inputs);
        systems::level_up(s, inputs);
        systems::spawner(s, t);
        systems::enemies(s, world, grid, nv, t);
        systems::contact_damage(s, world);
        systems::auto_attack(s);
        systems::projectiles(s, world, grid);
        systems::barrels(s, world);
        systems::deaths_and_xp(s);
        world.step(simcore::DT, consts::SUBSTEPS);
        systems::read_back(s, world);
        s.tick = t + 1;
    }

    /// XXH3-64 (seed 0) of the block's bytes (canonical: Pod, no padding, little-endian) followed
    /// by every live physics body in entity order (items, then players): position, rotation,
    /// linear and angular velocity, -0.0 canonicalized.
    fn checksum(&self) -> u64 {
        let mut h = Xxh3::new();
        h.update(bytemuck::bytes_of(&*self.s));
        let mut bodies = Vec::with_capacity((N_ITEMS + 4) * 52);
        self.body_bytes(&mut bodies);
        h.update(&bodies);
        h.digest()
    }

    fn save(&mut self, slot: &mut Slot) {
        *slot.block = *self.s;
        self.world.save(&mut slot.phys);
        slot.tick = self.s.tick;
    }

    fn restore(&mut self, slot: &Slot) {
        *self.s = *slot.block;
        assert!(self.world.restore(&slot.phys), "b3World_RestoreState failed");
    }

    fn slot_tick(slot: &Slot) -> u32 {
        slot.tick
    }

    fn slot_bytes(slot: &Slot) -> usize {
        STATE_BYTES + slot.phys.bytes().len()
    }

    /// `UNIS` | version u16 | 0 u16 | block len u32 | physics len u32 | block | physics image |
    /// XXH3 of everything before. The block is little-endian plain data; the Box3D image is the
    /// fork's pointer-free serialization (its layout hash rejects a mismatched build).
    fn export_slot(slot: &Slot) -> Vec<u8> {
        let block = bytemuck::bytes_of(&*slot.block);
        let phys = slot.phys.bytes();
        let mut out = Vec::with_capacity(SNAP_HEADER + block.len() + phys.len() + 8);
        out.extend_from_slice(SNAP_MAGIC);
        out.extend_from_slice(&SNAP_VERSION.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&(block.len() as u32).to_le_bytes());
        out.extend_from_slice(&(phys.len() as u32).to_le_bytes());
        out.extend_from_slice(block);
        out.extend_from_slice(phys);
        let sum = xxh3_64(&out);
        out.extend_from_slice(&sum.to_le_bytes());
        out
    }

    fn import(&mut self, bytes: &[u8]) -> Result<(), String> {
        let (block, phys) = parse_snapshot(bytes)?;
        if !self.world.restore_bytes(phys) {
            return Err("Box3D rejected the physics image (b3World_RestoreState)".into());
        }
        *self.s = bytemuck::pod_read_unaligned(block);
        Ok(())
    }
}

impl Default for State {
    fn default() -> State {
        State::zeroed()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deterministic_and_restorable() {
        let run = |n: u32| {
            let mut g = Game::new(3, Game::mask_of(4), 1200);
            let mut sc = Scripted::new(3, 4);
            for _ in 0..n {
                let i = sc.next(&g);
                g.step(&i);
            }
            g.checksum()
        };
        assert_eq!(run(300), run(300));

        let mut g = Game::new(3, Game::mask_of(4), 1200);
        let mut sc = Scripted::new(3, 4);
        for _ in 0..200 {
            let i = sc.next(&g);
            g.step(&i);
        }
        let mut slot = g.new_slot();
        g.save(&mut slot);
        let bytes = Game::export_slot(&slot);
        let mut sc2 = Scripted::new(3, 4);
        for _ in 0..100 {
            let i = sc.next(&g);
            g.step(&i);
        }
        let mut h = Game::from_snapshot(&bytes).unwrap();
        assert_eq!(h.tick(), 200);
        for _ in 0..100 {
            let i = sc2.next(&h);
            h.step(&i);
        }
        assert_eq!(g.checksum(), h.checksum());
    }
}
