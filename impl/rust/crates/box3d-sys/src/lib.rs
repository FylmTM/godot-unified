//! Box3D for unified: raw declarations in [`ffi`] and a small safe wrapper ([`World`],
//! [`WorldState`]) that is the only `unsafe` code in the workspace.
//!
//! Bodies are referred to by [`BodyKey`] (index + generation, without the world index), which is
//! what the pointer-free state block stores: it is the same in every client's world and survives a
//! snapshot moving to another process. Box3D validates ids itself; the wrapper additionally checks
//! them in debug builds.
#![deny(unsafe_op_in_unsafe_fn)]

pub mod ffi;

use core::ffi::c_int;
use core::ptr::NonNull;
use ffi::*;
use std::sync::Mutex;

pub use ffi::{b3Quat as Quat, b3Vec3 as Vec3};

/// `b3CreateWorld` / `b3DestroyWorld` scan and edit Box3D's global world array; worlds created on
/// different threads (one per session client) must not race there. Stepping distinct worlds
/// concurrently is fine.
static WORLD_ARRAY_LOCK: Mutex<()> = Mutex::new(());

pub const fn v3(x: f32, y: f32, z: f32) -> Vec3 {
    Vec3 { x, y, z }
}

/// A body id without its world index: portable between worlds and processes.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct BodyKey {
    pub index1: i32,
    pub generation: u16,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BodyKind {
    Static,
    Dynamic,
}

#[derive(Clone, Copy, Debug)]
pub struct BodyDesc {
    pub kind: BodyKind,
    pub position: Vec3,
    pub lock_rotation: bool,
    pub enable_sleep: bool,
}

#[derive(Clone, Copy, Debug)]
pub struct ShapeDesc {
    pub density: f32,
    /// Collision category bits (ray queries can exclude categories by mask).
    pub category_bits: u64,
    /// Stored as the shape material's `userMaterialId`; returned by ray casts.
    pub user_id: u64,
}

#[derive(Clone, Copy, Debug)]
pub struct RayHit {
    pub point: Vec3,
    pub fraction: f32,
    pub user_id: u64,
}

/// One Box3D world plus the save/restore geometry cache that belongs to it.
pub struct World {
    id: b3WorldId,
    cache: NonNull<b3WorldStateCache>,
    primed: bool,
}

impl World {
    /// Default world definition, the given gravity, one worker (single-threaded, no task callbacks).
    pub fn new(gravity: Vec3) -> World {
        verify_layout();
        // SAFETY: plain by-value call.
        let mut def = unsafe { b3DefaultWorldDef() };
        def.gravity = gravity;
        def.workerCount = 1;
        let id = {
            let _g = WORLD_ARRAY_LOCK.lock().unwrap_or_else(|e| e.into_inner());
            // SAFETY: def is a fully initialised default definition.
            unsafe { b3CreateWorld(&def) }
        };
        assert!(id.index1 != 0, "b3CreateWorld failed (too many worlds?)");
        // SAFETY: no preconditions; returns an owned allocation.
        let cache = NonNull::new(unsafe { b3CreateWorldStateCache() }).expect("b3CreateWorldStateCache");
        World { id, cache, primed: false }
    }

    fn body_id(&self, b: BodyKey) -> b3BodyId {
        let id = b3BodyId { index1: b.index1, world0: self.id.index1 - 1, generation: b.generation };
        // SAFETY: b3Body_IsValid accepts any id value.
        debug_assert!(unsafe { b3Body_IsValid(id) }, "stale body {b:?}");
        id
    }

    pub fn step(&mut self, dt: f32, substeps: i32) {
        // SAFETY: valid world id owned by self.
        unsafe { b3World_Step(self.id, dt, substeps as c_int) }
    }

    pub fn create_body(&mut self, d: &BodyDesc) -> BodyKey {
        // SAFETY: by-value default definition.
        let mut def = unsafe { b3DefaultBodyDef() };
        def.type_ = match d.kind {
            BodyKind::Static => b3_staticBody,
            BodyKind::Dynamic => b3_dynamicBody,
        };
        def.position = d.position;
        if d.lock_rotation {
            def.motionLocks.angularX = true;
            def.motionLocks.angularY = true;
            def.motionLocks.angularZ = true;
        }
        def.enableSleep = d.enable_sleep;
        // SAFETY: valid world id and definition.
        let id = unsafe { b3CreateBody(self.id, &def) };
        assert!(id.index1 != 0, "b3CreateBody failed");
        BodyKey { index1: id.index1, generation: id.generation }
    }

    pub fn destroy_body(&mut self, b: BodyKey) {
        let id = self.body_id(b);
        // SAFETY: valid body of this world.
        unsafe { b3DestroyBody(id) }
    }

    fn shape_def(s: &ShapeDesc) -> b3ShapeDef {
        // SAFETY: by-value default definition.
        let mut def = unsafe { b3DefaultShapeDef() };
        def.density = s.density;
        def.filter.categoryBits = s.category_bits;
        def.baseMaterial.userMaterialId = s.user_id;
        def
    }

    /// A box hull with the given half extents, centred on the body.
    pub fn add_box(&mut self, b: BodyKey, half: Vec3, s: &ShapeDesc) {
        let def = Self::shape_def(s);
        // SAFETY: by-value call; the hull is self-contained and passed from its own address (Box3D
        // copies it into the shape).
        let hull = unsafe { b3MakeBoxHull(half.x, half.y, half.z) };
        let id = self.body_id(b);
        // SAFETY: valid body, definition and hull for the duration of the call.
        unsafe { b3CreateHullShape(id, &def, &hull.base) };
    }

    pub fn add_capsule(&mut self, b: BodyKey, center1: Vec3, center2: Vec3, radius: f32, s: &ShapeDesc) {
        let def = Self::shape_def(s);
        let cap = b3Capsule { center1, center2, radius };
        let id = self.body_id(b);
        // SAFETY: valid body; def and capsule live for the call.
        unsafe { b3CreateCapsuleShape(id, &def, &cap) };
    }

    pub fn position(&self, b: BodyKey) -> Vec3 {
        // SAFETY: valid body id (checked in debug).
        unsafe { b3Body_GetPosition(self.body_id(b)) }
    }
    pub fn rotation(&self, b: BodyKey) -> Quat {
        // SAFETY: as above.
        unsafe { b3Body_GetRotation(self.body_id(b)) }
    }
    pub fn linear_velocity(&self, b: BodyKey) -> Vec3 {
        // SAFETY: as above.
        unsafe { b3Body_GetLinearVelocity(self.body_id(b)) }
    }
    pub fn angular_velocity(&self, b: BodyKey) -> Vec3 {
        // SAFETY: as above.
        unsafe { b3Body_GetAngularVelocity(self.body_id(b)) }
    }
    pub fn set_linear_velocity(&mut self, b: BodyKey, v: Vec3) {
        // SAFETY: as above.
        unsafe { b3Body_SetLinearVelocity(self.body_id(b), v) }
    }
    pub fn apply_impulse_to_center(&mut self, b: BodyKey, impulse: Vec3) {
        // SAFETY: as above.
        unsafe { b3Body_ApplyLinearImpulseToCenter(self.body_id(b), impulse, true) }
    }

    /// Closest hit along `origin .. origin + translation` among shapes whose category intersects
    /// `mask_bits`.
    pub fn cast_ray_closest(&self, origin: Vec3, translation: Vec3, mask_bits: u64) -> Option<RayHit> {
        // SAFETY: pure by-value call.
        let mut filter = unsafe { b3DefaultQueryFilter() };
        filter.maskBits = mask_bits;
        // SAFETY: valid world; filter.name is the default (null).
        let r = unsafe { b3World_CastRayClosest(self.id, origin, translation, filter) };
        r.hit.then_some(RayHit { point: r.point, fraction: r.fraction, user_id: r.userMaterialId })
    }

    pub fn new_state(&self) -> WorldState {
        // SAFETY: no preconditions; returns an owned allocation.
        WorldState(NonNull::new(unsafe { b3CreateWorldState() }).expect("b3CreateWorldState"))
    }

    /// Saves the world (at a step boundary) into `st`, reusing its buffer. Returns the image size.
    pub fn save(&mut self, st: &mut WorldState) -> usize {
        self.primed = true;
        // SAFETY: valid world, our cache, and an owned state.
        let n = unsafe { b3World_SaveState(self.id, self.cache.as_ptr(), st.0.as_ptr()) };
        assert!(n > 0, "b3World_SaveState failed");
        n as usize
    }

    /// Restores a state saved by this world (same cache).
    pub fn restore(&mut self, st: &WorldState) -> bool {
        // SAFETY: valid world, our cache, a state saved with it.
        unsafe { b3World_RestoreState(self.id, self.cache.as_ptr(), st.0.as_ptr()) }
    }

    /// Restores an image produced by [`WorldState::bytes`] in this or another process. The image
    /// refers to interned hull geometry by registry index, so this world must have been built the
    /// same way (same hull shapes, created in the same order) as the one that saved it. The
    /// registry is primed by saving this world once first.
    pub fn restore_bytes(&mut self, bytes: &[u8]) -> bool {
        if bytes.is_empty() || bytes.len() > i32::MAX as usize {
            return false;
        }
        if !self.primed {
            let mut tmp = self.new_state();
            self.save(&mut tmp);
        }
        let image = RecBufferImage {
            data: bytes.as_ptr() as *mut u8,
            capacity: bytes.len() as c_int,
            size: bytes.len() as c_int,
            countOnly: false,
        };
        // SAFETY: `image` has b3WorldState's layout (see RecBufferImage, checked in
        // verify_layout); RestoreState only reads `data[0..size]`, which `bytes` covers and which
        // outlives the call. The image is bounds-checked by Box3D's reader.
        unsafe {
            b3World_RestoreState(self.id, self.cache.as_ptr(), (&image as *const RecBufferImage).cast::<b3WorldState>())
        }
    }
}

impl Drop for World {
    fn drop(&mut self) {
        let _g = WORLD_ARRAY_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        // SAFETY: we own the world and the cache; nothing refers to them after this.
        unsafe {
            b3DestroyWorld(self.id);
            b3DestroyWorldStateCache(self.cache.as_ptr());
        }
    }
}

/// A reusable physics snapshot buffer (`b3WorldState`).
pub struct WorldState(NonNull<b3WorldState>);

impl WorldState {
    /// The saved image (empty before the first save).
    pub fn bytes(&self) -> &[u8] {
        // SAFETY: owned state; data/size describe its buffer (null/0 before a save).
        unsafe {
            let n = b3WorldState_GetSize(self.0.as_ptr());
            let p = b3WorldState_GetData(self.0.as_ptr());
            if p.is_null() || n <= 0 { &[] } else { core::slice::from_raw_parts(p, n as usize) }
        }
    }
}

impl Drop for WorldState {
    fn drop(&mut self) {
        // SAFETY: owned allocation.
        unsafe { b3DestroyWorldState(self.0.as_ptr()) }
    }
}

/// Runtime cross-check of the hand-written layouts against the linked library: the box hull
/// carries C's own `sizeof`/`offsetof`, the default definitions end in a cookie, and a saved
/// state viewed through [`RecBufferImage`] must agree with GetData/GetSize. Runs once per process.
pub fn verify_layout() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        use core::mem::{offset_of, size_of};
        // SAFETY: plain by-value C calls with no preconditions.
        let (h, w, b, s) =
            unsafe { (b3MakeBoxHull(1.0, 2.0, 3.0), b3DefaultWorldDef(), b3DefaultBodyDef(), b3DefaultShapeDef()) };
        let off = |o: usize| o as i32;
        assert_eq!(h.base.byteCount, off(size_of::<b3BoxHull>()), "b3BoxHull size");
        assert_eq!(h.base.vertexOffset, off(offset_of!(b3BoxHull, boxVertices)));
        assert_eq!(h.base.pointOffset, off(offset_of!(b3BoxHull, boxPoints)));
        assert_eq!(h.base.edgeOffset, off(offset_of!(b3BoxHull, boxEdges)));
        assert_eq!(h.base.planeOffset, off(offset_of!(b3BoxHull, boxPlanes)));
        assert_eq!(h.base.faceOffset, off(offset_of!(b3BoxHull, boxFaces)));
        assert_eq!(h.base.soaVertexOffset, off(offset_of!(b3BoxHull, vx)));
        assert_eq!(h.base.soaNormalOffset, off(offset_of!(b3BoxHull, nx)));
        assert_eq!(h.base.edgeCosineOffset, off(offset_of!(b3BoxHull, edgeCosines)));
        assert_eq!(w.internalValue, B3_SECRET_COOKIE, "b3WorldDef layout");
        assert_eq!(b.internalValue, B3_SECRET_COOKIE, "b3BodyDef layout");
        assert_eq!(s.internalValue, B3_SECRET_COOKIE, "b3ShapeDef layout");
        assert_eq!(w.gravity, v3(0.0, -10.0, 0.0));
        assert_eq!(b.rotation.s, 1.0);

        // b3WorldState image layout (restore_bytes workaround).
        let _g = WORLD_ARRAY_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        // SAFETY: create a throwaway world, save it, inspect the state through the documented
        // layout, and free everything.
        unsafe {
            let world = b3CreateWorld(&w);
            let cache = b3CreateWorldStateCache();
            let st = b3CreateWorldState();
            let n = b3World_SaveState(world, cache, st);
            let view = &*(st as *const RecBufferImage);
            assert!(n > 0 && view.size == n && view.capacity >= n, "b3WorldState layout (size)");
            assert_eq!(view.data as *const u8, b3WorldState_GetData(st), "b3WorldState layout (data)");
            assert_eq!(b3WorldState_GetSize(st), n);
            b3DestroyWorldState(st);
            b3DestroyWorldStateCache(cache);
            b3DestroyWorld(world);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_matches_library() {
        verify_layout();
    }

    #[test]
    fn save_restore_bytes_roundtrip() {
        let mk = || {
            let mut w = World::new(v3(0.0, -10.0, 0.0));
            let g = w.create_body(&BodyDesc {
                kind: BodyKind::Static,
                position: v3(0.0, -0.5, 0.0),
                lock_rotation: false,
                enable_sleep: true,
            });
            let sd = ShapeDesc { density: 1.0, category_bits: 1, user_id: 7 };
            w.add_box(g, v3(10.0, 0.5, 10.0), &sd);
            let b = w.create_body(&BodyDesc {
                kind: BodyKind::Dynamic,
                position: v3(0.0, 2.0, 0.0),
                lock_rotation: false,
                enable_sleep: true,
            });
            w.add_box(b, v3(0.5, 0.5, 0.5), &sd);
            (w, b)
        };
        let (mut a, b) = mk();
        for _ in 0..30 {
            a.step(1.0 / 60.0, 4);
        }
        let mut st = a.new_state();
        a.save(&mut st);
        let bytes = st.bytes().to_vec();
        for _ in 0..30 {
            a.step(1.0 / 60.0, 4);
        }
        let want = a.position(b);
        let (mut c, _) = mk();
        assert!(c.restore_bytes(&bytes));
        for _ in 0..30 {
            c.step(1.0 / 60.0, 4);
        }
        assert_eq!(c.position(b), want);
        let hit = c.cast_ray_closest(v3(0.0, 5.0, 0.0), v3(0.0, -10.0, 0.0), u64::MAX).unwrap();
        assert_eq!(hit.user_id, 7);
    }
}
