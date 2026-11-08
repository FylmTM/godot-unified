//! Raw, hand-written `extern "C"` declarations for the subset of Box3D (pinned commit 3362633 +
//! `third_party/box3d.patch`) that unified uses. Single precision only (`b3Pos == b3Vec3`).
//!
//! Every struct is `#[repr(C)]` with the exact field order of the C headers. Sizes, alignments and
//! key offsets are `const`-asserted below (values from the C compiler, identical on LP64 macOS/Linux
//! and LLP64 Windows because no struct here contains `long`), and `crate::verify_layout` cross-checks
//! at runtime against offsets the C library itself writes into a `b3BoxHull` plus the definition
//! cookies. C enums are `c_int` aliases + constants; callback slots we never set are opaque
//! nullable function pointers.
#![allow(non_camel_case_types, non_snake_case, non_upper_case_globals, dead_code)]

use core::ffi::{c_char, c_int, c_void};
use core::mem::{align_of, offset_of, size_of};

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct b3Vec3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct b3Quat {
    pub v: b3Vec3,
    pub s: f32,
}

pub type b3Pos = b3Vec3;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct b3Matrix3 {
    pub cx: b3Vec3,
    pub cy: b3Vec3,
    pub cz: b3Vec3,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct b3AABB {
    pub lowerBound: b3Vec3,
    pub upperBound: b3Vec3,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct b3Plane {
    pub normal: b3Vec3,
    pub offset: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct b3WorldId {
    pub index1: u16,
    pub generation: u16,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct b3BodyId {
    pub index1: i32,
    pub world0: u16,
    pub generation: u16,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct b3ShapeId {
    pub index1: i32,
    pub world0: u16,
    pub generation: u16,
}

pub type b3OpaqueCallback = Option<unsafe extern "C" fn()>;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct b3Capacity {
    pub staticShapeCount: c_int,
    pub dynamicShapeCount: c_int,
    pub staticBodyCount: c_int,
    pub dynamicBodyCount: c_int,
    pub contactCount: c_int,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct b3WorldDef {
    pub gravity: b3Vec3,
    pub restitutionThreshold: f32,
    pub restitutionIterations: c_int,
    pub enableRestitutionPropagation: bool,
    pub hitEventThreshold: f32,
    pub contactHertz: f32,
    pub contactDampingRatio: f32,
    pub contactSpeed: f32,
    pub maximumLinearSpeed: f32,
    pub isotropicInertiaTolerance: f32,
    pub frictionCallback: b3OpaqueCallback,
    pub restitutionCallback: b3OpaqueCallback,
    pub enableSleep: bool,
    pub enableContinuous: bool,
    pub workerCount: u32,
    pub enqueueTask: b3OpaqueCallback,
    pub finishTask: b3OpaqueCallback,
    pub userTaskContext: *mut c_void,
    pub userData: *mut c_void,
    pub createDebugShape: b3OpaqueCallback,
    pub destroyDebugShape: b3OpaqueCallback,
    pub userDebugShapeContext: *mut c_void,
    pub capacity: b3Capacity,
    pub internalValue: c_int,
}

pub type b3BodyType = c_int;
pub const b3_staticBody: b3BodyType = 0;
pub const b3_kinematicBody: b3BodyType = 1;
pub const b3_dynamicBody: b3BodyType = 2;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct b3MotionLocks {
    pub linearX: bool,
    pub linearY: bool,
    pub linearZ: bool,
    pub angularX: bool,
    pub angularY: bool,
    pub angularZ: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct b3BodyDef {
    pub type_: b3BodyType,
    pub position: b3Pos,
    pub rotation: b3Quat,
    pub linearVelocity: b3Vec3,
    pub angularVelocity: b3Vec3,
    pub linearDamping: f32,
    pub angularDamping: f32,
    pub gravityScale: f32,
    pub sleepThreshold: f32,
    pub safetyFactor: f32,
    pub name: *const c_char,
    pub userData: *mut c_void,
    pub motionLocks: b3MotionLocks,
    pub enableSleep: bool,
    pub isAwake: bool,
    pub isBullet: bool,
    pub isEnabled: bool,
    pub allowFastRotation: bool,
    pub enableContactRecycling: bool,
    pub internalValue: c_int,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct b3Filter {
    pub categoryBits: u64,
    pub maskBits: u64,
    pub groupIndex: c_int,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct b3SurfaceMaterial {
    pub friction: f32,
    pub restitution: f32,
    pub rollingResistance: f32,
    pub tangentVelocity: b3Vec3,
    pub userMaterialId: u64,
    pub customColor: u32,
    pub padding: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct b3ShapeDef {
    pub name: *const c_char,
    pub userData: *mut c_void,
    pub materials: *mut b3SurfaceMaterial,
    pub materialCount: c_int,
    pub baseMaterial: b3SurfaceMaterial,
    pub density: f32,
    pub explosionScale: f32,
    pub filter: b3Filter,
    pub enableCustomFiltering: bool,
    pub isSensor: bool,
    pub enableSensorEvents: bool,
    pub enableContactEvents: bool,
    pub enableHitEvents: bool,
    pub enablePreSolveEvents: bool,
    pub invokeContactCreation: bool,
    pub updateBodyMass: bool,
    pub enableSpeculativeContact: bool,
    pub internalValue: c_int,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct b3QueryFilter {
    pub categoryBits: u64,
    pub maskBits: u64,
    pub id: u64,
    pub name: *const c_char,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct b3RayResult {
    pub shapeId: b3ShapeId,
    pub point: b3Pos,
    pub normal: b3Vec3,
    pub userMaterialId: u64,
    pub fraction: f32,
    pub triangleIndex: c_int,
    pub childIndex: c_int,
    pub nodeVisits: c_int,
    pub leafVisits: c_int,
    pub hit: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct b3Capsule {
    pub center1: b3Vec3,
    pub center2: b3Vec3,
    pub radius: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct b3HullVertex {
    pub edge: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct b3HullHalfEdge {
    pub next: u8,
    pub twin: u8,
    pub origin: u8,
    pub face: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct b3HullFace {
    pub edge: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct b3HullData {
    pub version: u64,
    pub hash: u64,
    pub aabb: b3AABB,
    pub surfaceArea: f32,
    pub volume: f32,
    pub innerRadius: f32,
    pub center: b3Vec3,
    pub centralInertia: b3Matrix3,
    pub vertexCount: i32,
    pub vertexOffset: i32,
    pub pointOffset: i32,
    pub edgeCount: i32,
    pub edgeOffset: i32,
    pub faceCount: i32,
    pub planeOffset: i32,
    pub faceOffset: i32,
    pub soaVertexOffset: i32,
    pub soaNormalOffset: i32,
    pub edgeCosineOffset: i32,
    pub byteCount: i32,
    pub padding: i32,
}

/// Self-contained box hull, returned by value (696 bytes). The offsets in `base` index into the
/// arrays that follow, so it must be passed as `&hull.base` from its own address.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct b3BoxHull {
    pub base: b3HullData,
    pub boxVertices: [b3HullVertex; 8],
    pub boxPoints: [b3Vec3; 8],
    pub boxEdges: [b3HullHalfEdge; 24],
    pub boxPlanes: [b3Plane; 6],
    pub boxFaces: [b3HullFace; 6],
    pub padding: [u8; 2],
    pub vx: [f32; 8],
    pub vy: [f32; 8],
    pub vz: [f32; 8],
    pub nx: [f32; 8],
    pub ny: [f32; 8],
    pub nz: [f32; 8],
    pub edgeCosines: [f32; 12],
}

/// Opaque fork types (box3d.h `world_state` group).
#[repr(C)]
pub struct b3WorldStateCache {
    _private: [u8; 0],
}
#[repr(C)]
pub struct b3WorldState {
    _private: [u8; 0],
}

/// WORKAROUND: the fork can save a state and expose its bytes (`b3WorldState_GetData/GetSize`) but
/// has no call to load bytes back into a `b3WorldState`, which a portable snapshot (late join, a
/// snapshot file) needs. `struct b3WorldState { b3RecBuffer buffer; }` and
/// `b3RecBuffer { uint8_t* data; int capacity; int size; bool countOnly; }` (src/recording.h), and
/// `b3World_RestoreState` only reads `data` and `size`, so an image with this layout stands in for a
/// state. Checked against the library at runtime in `verify_layout` (a saved state's GetData/GetSize
/// must equal the first fields read through this view).
#[repr(C)]
pub struct RecBufferImage {
    pub data: *mut u8,
    pub capacity: c_int,
    pub size: c_int,
    pub countOnly: bool,
}

unsafe extern "C" {
    pub fn b3DefaultWorldDef() -> b3WorldDef;
    pub fn b3DefaultBodyDef() -> b3BodyDef;
    pub fn b3DefaultShapeDef() -> b3ShapeDef;
    pub fn b3DefaultQueryFilter() -> b3QueryFilter;

    /// Renamed in BOX3D_DOUBLE_PRECISION builds, so a precision mismatch is a link error.
    pub fn b3CreateWorld(def: *const b3WorldDef) -> b3WorldId;
    pub fn b3DestroyWorld(worldId: b3WorldId);
    pub fn b3World_Step(worldId: b3WorldId, timeStep: f32, subStepCount: c_int);
    pub fn b3World_CastRayClosest(
        worldId: b3WorldId,
        origin: b3Pos,
        translation: b3Vec3,
        filter: b3QueryFilter,
    ) -> b3RayResult;

    pub fn b3CreateBody(worldId: b3WorldId, def: *const b3BodyDef) -> b3BodyId;
    pub fn b3DestroyBody(bodyId: b3BodyId);
    pub fn b3Body_IsValid(id: b3BodyId) -> bool;
    pub fn b3Body_GetPosition(bodyId: b3BodyId) -> b3Pos;
    pub fn b3Body_GetRotation(bodyId: b3BodyId) -> b3Quat;
    pub fn b3Body_GetLinearVelocity(bodyId: b3BodyId) -> b3Vec3;
    pub fn b3Body_GetAngularVelocity(bodyId: b3BodyId) -> b3Vec3;
    pub fn b3Body_SetLinearVelocity(bodyId: b3BodyId, linearVelocity: b3Vec3);
    pub fn b3Body_ApplyLinearImpulseToCenter(bodyId: b3BodyId, impulse: b3Vec3, wake: bool);

    pub fn b3CreateCapsuleShape(bodyId: b3BodyId, def: *const b3ShapeDef, capsule: *const b3Capsule) -> b3ShapeId;
    pub fn b3CreateHullShape(bodyId: b3BodyId, def: *const b3ShapeDef, hull: *const b3HullData) -> b3ShapeId;
    pub fn b3MakeBoxHull(hx: f32, hy: f32, hz: f32) -> b3BoxHull;

    // Fork: world save/restore (third_party/box3d.patch).
    pub fn b3CreateWorldStateCache() -> *mut b3WorldStateCache;
    pub fn b3DestroyWorldStateCache(cache: *mut b3WorldStateCache);
    pub fn b3CreateWorldState() -> *mut b3WorldState;
    pub fn b3DestroyWorldState(state: *mut b3WorldState);
    pub fn b3WorldState_GetData(state: *const b3WorldState) -> *const u8;
    pub fn b3WorldState_GetSize(state: *const b3WorldState) -> c_int;
    pub fn b3World_SaveState(worldId: b3WorldId, cache: *mut b3WorldStateCache, state: *mut b3WorldState) -> c_int;
    pub fn b3World_RestoreState(worldId: b3WorldId, cache: *mut b3WorldStateCache, state: *const b3WorldState) -> bool;
}

macro_rules! check_layout {
    ($t:ty, $size:expr, $align:expr $(, $field:ident @ $off:expr)*) => {
        const _: () = {
            assert!(size_of::<$t>() == $size);
            assert!(align_of::<$t>() == $align);
            $(assert!(offset_of!($t, $field) == $off);)*
        };
    };
}

check_layout!(b3Vec3, 12, 4);
check_layout!(b3Quat, 16, 4, s @ 12);
check_layout!(b3WorldId, 4, 2);
check_layout!(b3BodyId, 8, 4);
check_layout!(b3ShapeId, 8, 4);
check_layout!(b3Capacity, 20, 4);
check_layout!(b3WorldDef, 152, 8,
    gravity @ 0, enableRestitutionPropagation @ 20, hitEventThreshold @ 24, frictionCallback @ 48,
    enableSleep @ 64, workerCount @ 68, enqueueTask @ 72, capacity @ 128, internalValue @ 148);
check_layout!(b3MotionLocks, 6, 1);
check_layout!(b3BodyDef, 112, 8,
    type_ @ 0, position @ 4, rotation @ 16, name @ 80, motionLocks @ 96, enableSleep @ 102,
    internalValue @ 108);
check_layout!(b3Filter, 24, 8);
check_layout!(b3SurfaceMaterial, 40, 8, tangentVelocity @ 12, userMaterialId @ 24);
check_layout!(b3ShapeDef, 120, 8,
    materialCount @ 24, baseMaterial @ 32, density @ 72, filter @ 80, enableCustomFiltering @ 104,
    internalValue @ 116);
check_layout!(b3QueryFilter, 32, 8);
check_layout!(b3RayResult, 64, 8, point @ 8, userMaterialId @ 32, fraction @ 40, hit @ 60);
check_layout!(b3Capsule, 28, 4);
check_layout!(b3HullData, 152, 8, aabb @ 16, centralInertia @ 64, vertexCount @ 100, padding @ 148);
check_layout!(b3BoxHull, 696, 8,
    boxVertices @ 152, boxPoints @ 160, boxEdges @ 256, boxPlanes @ 352, boxFaces @ 448, vx @ 456,
    nx @ 552, edgeCosines @ 648);
check_layout!(RecBufferImage, 24, 8, capacity @ 8, size @ 12, countOnly @ 16);

/// `B3_SECRET_COOKIE` (src/core.h), written into `internalValue` by the b3Default*Def functions.
pub const B3_SECRET_COOKIE: c_int = 1152023;
