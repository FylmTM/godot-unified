//! Physics world construction (spec/GAME.md "World"), in the specified creation order, and the
//! body helpers the systems use.

use crate::consts::*;
use crate::state::{BodyRef, N_ITEMS, State};
use box3d_sys::{BodyDesc, BodyKey, BodyKind, ShapeDesc, Vec3, World, v3};

pub fn key(b: BodyRef) -> BodyKey {
    debug_assert!(b.live != 0);
    BodyKey { index1: b.index1, generation: b.generation }
}

fn body_ref(k: BodyKey) -> BodyRef {
    BodyRef { index1: k.index1, generation: k.generation, live: 1 }
}

fn shape(category_bits: u64, user_id: u64) -> ShapeDesc {
    ShapeDesc { density: 1.0, category_bits, user_id }
}

fn static_box(w: &mut World, pos: Vec3, half: Vec3) {
    let b =
        w.create_body(&BodyDesc { kind: BodyKind::Static, position: pos, lock_rotation: false, enable_sleep: true });
    w.add_box(b, half, &shape(CAT_WORLD, UID_STATIC));
}

pub fn is_barrel_item(i: usize) -> bool {
    i % 5 == 2
}

pub fn item_position(i: usize) -> Vec3 {
    let x = ((i % 8) * 4) as f32 - 14.0;
    let z = ((i / 8) * 4) as f32 - 8.0;
    v3(x, 1.0, z)
}

pub fn pillar_center(k: usize) -> (f32, f32) {
    (PILLAR_RING * COS[k], PILLAR_RING * SIN[k])
}

/// Creates the world before tick 0: ground, walls, pillars, crates and barrels, then the players
/// in `initial_mask`. Fills the item, barrel and player body references in `s`.
pub fn create_world(s: &mut State) -> World {
    let mut w = World::new(v3(0.0, GRAVITY_Y, 0.0));
    // Ground and walls (inner faces at +-30, height 3, thickness 1).
    static_box(&mut w, v3(0.0, -0.5, 0.0), v3(32.0, 0.5, 32.0));
    static_box(&mut w, v3(30.5, 1.5, 0.0), v3(0.5, 1.5, 31.0));
    static_box(&mut w, v3(-30.5, 1.5, 0.0), v3(0.5, 1.5, 31.0));
    static_box(&mut w, v3(0.0, 1.5, 30.5), v3(31.0, 1.5, 0.5));
    static_box(&mut w, v3(0.0, 1.5, -30.5), v3(31.0, 1.5, 0.5));
    for k in 0..8 {
        let (x, z) = pillar_center(k);
        static_box(&mut w, v3(x, PILLAR_HALF[1], z), v3(PILLAR_HALF[0], PILLAR_HALF[1], PILLAR_HALF[2]));
    }
    let mut b = 0;
    for i in 0..N_ITEMS {
        if is_barrel_item(i) {
            s.barrels[b].item = i as u32;
            s.barrels[b].hp = BARREL_HP;
            s.barrels[b].respawn = 0;
            s.barrels[b].body = create_barrel(&mut w, i, b);
            s.items[i] = s.barrels[b].body;
            b += 1;
        } else {
            let k = w.create_body(&dynamic(item_position(i), false, true));
            w.add_box(k, v3(CRATE_HALF, CRATE_HALF, CRATE_HALF), &shape(CAT_WORLD, UID_CRATE | i as u64));
            s.items[i] = body_ref(k);
        }
    }
    for p in 0..s.players.len() {
        if s.initial_mask & (1 << p) != 0 {
            crate::systems::join_player(s, &mut w, p);
        }
    }
    w
}

fn dynamic(position: Vec3, lock_rotation: bool, enable_sleep: bool) -> BodyDesc {
    BodyDesc { kind: BodyKind::Dynamic, position, lock_rotation, enable_sleep }
}

pub fn create_barrel(w: &mut World, item: usize, barrel: usize) -> BodyRef {
    let k = w.create_body(&dynamic(item_position(item), false, true));
    w.add_capsule(
        k,
        v3(0.0, -BARREL_HALF_SEGMENT, 0.0),
        v3(0.0, BARREL_HALF_SEGMENT, 0.0),
        BARREL_RADIUS,
        &shape(CAT_WORLD, UID_BARREL | barrel as u64),
    );
    body_ref(k)
}

pub fn create_player_body(w: &mut World, p: usize) -> BodyRef {
    let [x, y, z] = PLAYER_START[p];
    let k = w.create_body(&dynamic(v3(x, y, z), true, false));
    w.add_capsule(
        k,
        v3(0.0, -PLAYER_HALF_SEGMENT, 0.0),
        v3(0.0, PLAYER_HALF_SEGMENT, 0.0),
        PLAYER_RADIUS,
        &shape(CAT_PLAYER, UID_PLAYER | p as u64),
    );
    body_ref(k)
}
