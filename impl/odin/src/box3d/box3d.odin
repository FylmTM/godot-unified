// Hand-written Box3D bindings: only what unified uses, transcribed from the pinned headers
// (commit 336263320469e5e9febfe18697ab562488f7e97a, single precision) plus the save/restore fork API
// from third_party/box3d.patch. Odin's `vendor:box3d` targets an older commit with a different ABI
// (b3WorldDef, b3BodyDef, b3HullData, b3BoxHull and b3RayResult all changed), so it can't be used.
// Layouts are checked with #assert against sizes/offsets from a C probe on the pinned headers.
//
// The library is linked as "system:box3d" (box3d.lib on Windows: Odin passes system names to
// link.exe verbatim); build.py passes the directory of the static library produced by
// tools/box3d.py through -extra-linker-flags (-L for clang, /LIBPATH for MSVC link).
package box3d

import "core:c"

when ODIN_OS == .Windows {
	foreign import lib "system:box3d.lib"
} else {
	foreign import lib "system:box3d"
}

Vec3 :: struct {
	x, y, z: f32,
}

Quat :: struct {
	v: Vec3,
	s: f32,
}

// Single-precision build: b3Pos is b3Vec3.
Pos :: Vec3

AABB :: struct {
	lowerBound, upperBound: Vec3,
}

Matrix3 :: struct {
	cx, cy, cz: Vec3,
}

WorldId :: struct {
	index1:     u16,
	generation: u16,
}

BodyId :: struct {
	index1:     i32,
	world0:     u16,
	generation: u16,
}

ShapeId :: struct {
	index1:     i32,
	world0:     u16,
	generation: u16,
}

BodyType :: enum c.int {
	staticBody    = 0,
	kinematicBody = 1,
	dynamicBody   = 2,
}

Capacity :: struct {
	staticShapeCount:  c.int,
	dynamicShapeCount: c.int,
	staticBodyCount:   c.int,
	dynamicBodyCount:  c.int,
	contactCount:      c.int,
}

WorldDef :: struct {
	gravity:                      Vec3,
	restitutionThreshold:         f32,
	restitutionIterations:        c.int,
	enableRestitutionPropagation: bool,
	hitEventThreshold:            f32,
	contactHertz:                 f32,
	contactDampingRatio:          f32,
	contactSpeed:                 f32,
	maximumLinearSpeed:           f32,
	isotropicInertiaTolerance:    f32,
	frictionCallback:             rawptr,
	restitutionCallback:          rawptr,
	enableSleep:                  bool,
	enableContinuous:             bool,
	workerCount:                  u32,
	enqueueTask:                  rawptr,
	finishTask:                   rawptr,
	userTaskContext:              rawptr,
	userData:                     rawptr,
	createDebugShape:             rawptr,
	destroyDebugShape:            rawptr,
	userDebugShapeContext:        rawptr,
	capacity:                     Capacity,
	internalValue:                c.int,
}

MotionLocks :: struct {
	linearX, linearY, linearZ:    bool,
	angularX, angularY, angularZ: bool,
}

BodyDef :: struct {
	type:                   BodyType,
	position:               Pos,
	rotation:               Quat,
	linearVelocity:         Vec3,
	angularVelocity:        Vec3,
	linearDamping:          f32,
	angularDamping:         f32,
	gravityScale:           f32,
	sleepThreshold:         f32,
	safetyFactor:           f32,
	name:                   cstring,
	userData:               rawptr,
	motionLocks:            MotionLocks,
	enableSleep:            bool,
	isAwake:                bool,
	isBullet:               bool,
	isEnabled:              bool,
	allowFastRotation:      bool,
	enableContactRecycling: bool,
	internalValue:          c.int,
}

SurfaceMaterial :: struct {
	friction:          f32,
	restitution:       f32,
	rollingResistance: f32,
	tangentVelocity:   Vec3,
	userMaterialId:    u64,
	customColor:       u32,
	padding:           u32,
}

Filter :: struct {
	categoryBits: u64,
	maskBits:     u64,
	groupIndex:   c.int,
}

ShapeDef :: struct {
	name:                     cstring,
	userData:                 rawptr,
	materials:                [^]SurfaceMaterial,
	materialCount:            c.int,
	baseMaterial:             SurfaceMaterial,
	density:                  f32,
	explosionScale:           f32,
	filter:                   Filter,
	enableCustomFiltering:    bool,
	isSensor:                 bool,
	enableSensorEvents:       bool,
	enableContactEvents:      bool,
	enableHitEvents:          bool,
	enablePreSolveEvents:     bool,
	invokeContactCreation:    bool,
	updateBodyMass:           bool,
	enableSpeculativeContact: bool,
	internalValue:            c.int,
}

QueryFilter :: struct {
	categoryBits: u64,
	maskBits:     u64,
	id:           u64,
	name:         cstring,
}

RayResult :: struct {
	shapeId:        ShapeId,
	point:          Pos,
	normal:         Vec3,
	userMaterialId: u64,
	fraction:       f32,
	triangleIndex:  c.int,
	childIndex:     c.int,
	nodeVisits:     c.int,
	leafVisits:     c.int,
	hit:            bool,
}

Sphere :: struct {
	center: Vec3,
	radius: f32,
}

Capsule :: struct {
	center1, center2: Vec3,
	radius:           f32,
}

Plane :: struct {
	normal: Vec3,
	offset: f32,
}

HullVertex :: struct {
	edge: u8,
}

HullHalfEdge :: struct {
	next, twin, origin, face: u8,
}

HullFace :: struct {
	edge: u8,
}

HullData :: struct {
	version:          u64,
	hash:             u64,
	aabb:             AABB,
	surfaceArea:      f32,
	volume:           f32,
	innerRadius:      f32,
	center:           Vec3,
	centralInertia:   Matrix3,
	vertexCount:      i32,
	vertexOffset:     i32,
	pointOffset:      i32,
	edgeCount:        i32,
	edgeOffset:       i32,
	faceCount:        i32,
	planeOffset:      i32,
	faceOffset:       i32,
	soaVertexOffset:  i32,
	soaNormalOffset:  i32,
	edgeCosineOffset: i32,
	byteCount:        i32,
	padding:          i32,
}

// Returned by value from b3MakeBoxHull/b3MakeCubeHull; the internal offsets in `base` point into
// this struct, so it must have the exact C layout (checked below).
BoxHull :: struct {
	base:        HullData,
	boxVertices: [8]HullVertex,
	boxPoints:   [8]Vec3,
	boxEdges:    [24]HullHalfEdge,
	boxPlanes:   [6]Plane,
	boxFaces:    [6]HullFace,
	padding:     [2]u8,
	vx, vy, vz:  [8]f32,
	nx, ny, nz:  [8]f32,
	edgeCosines: [12]f32,
}

@(default_calling_convention = "c", link_prefix = "b3")
foreign lib {
	DefaultWorldDef :: proc() -> WorldDef ---
	DefaultBodyDef :: proc() -> BodyDef ---
	DefaultShapeDef :: proc() -> ShapeDef ---
	DefaultQueryFilter :: proc() -> QueryFilter ---

	CreateWorld :: proc(def: ^WorldDef) -> WorldId ---
	DestroyWorld :: proc(worldId: WorldId) ---
	World_Step :: proc(worldId: WorldId, timeStep: f32, subStepCount: c.int) ---
	World_CastRayClosest :: proc(worldId: WorldId, origin: Pos, translation: Vec3, filter: QueryFilter) -> RayResult ---

	CreateBody :: proc(worldId: WorldId, def: ^BodyDef) -> BodyId ---
	DestroyBody :: proc(bodyId: BodyId) ---
	Body_ApplyLinearImpulseToCenter :: proc(bodyId: BodyId, impulse: Vec3, wake: bool) ---
	Body_GetPosition :: proc(bodyId: BodyId) -> Pos ---
	Body_GetRotation :: proc(bodyId: BodyId) -> Quat ---
	Body_GetLinearVelocity :: proc(bodyId: BodyId) -> Vec3 ---
	Body_GetAngularVelocity :: proc(bodyId: BodyId) -> Vec3 ---
	Body_SetLinearVelocity :: proc(bodyId: BodyId, linearVelocity: Vec3) ---

	MakeBoxHull :: proc(hx, hy, hz: f32) -> BoxHull ---
	MakeCubeHull :: proc(halfWidth: f32) -> BoxHull ---
	CreateHullShape :: proc(bodyId: BodyId, def: ^ShapeDef, hull: ^HullData) -> ShapeId ---
	CreateSphereShape :: proc(bodyId: BodyId, def: ^ShapeDef, sphere: ^Sphere) -> ShapeId ---
	CreateCapsuleShape :: proc(bodyId: BodyId, def: ^ShapeDef, capsule: ^Capsule) -> ShapeId ---

	// Fork API (third_party/box3d.patch): world save/restore for rollback.
	CreateWorldStateCache :: proc() -> ^WorldStateCache ---
	DestroyWorldStateCache :: proc(cache: ^WorldStateCache) ---
	CreateWorldState :: proc() -> ^WorldState ---
	DestroyWorldState :: proc(state: ^WorldState) ---
	WorldState_GetData :: proc(state: ^WorldState) -> [^]u8 ---
	WorldState_GetSize :: proc(state: ^WorldState) -> c.int ---
	World_SaveState :: proc(worldId: WorldId, cache: ^WorldStateCache, state: ^WorldState) -> c.int ---
	World_RestoreState :: proc(worldId: WorldId, cache: ^WorldStateCache, state: ^WorldState) -> bool ---
}

// Opaque fork types.
WorldStateCache :: struct {}
WorldState :: struct {}

// WORKAROUND: the fork can save an image and restore a saved one, but it has no call that loads
// an image from foreign bytes (a file or a network transfer). b3WorldState is a single b3RecBuffer
// (src/recording.h: data, capacity, size, countOnly), so a loaded image is restored by pointing a
// scratch state's buffer at the bytes for the duration of the call, then detaching it again.
@(private)
Rec_Buffer :: struct {
	data:       [^]u8,
	capacity:   c.int,
	size:       c.int,
	count_only: bool,
}
#assert(size_of(Rec_Buffer) == 24)

// Restores `image` (bytes from World_SaveState, possibly from another process or machine) into
// the world. The geometry registry in `cache` must already hold the image's hulls (in practice:
// the world was built the same way and saved once with this cache).
World_RestoreStateFromBytes :: proc(worldId: WorldId, cache: ^WorldStateCache, image: []u8) -> bool {
	st := CreateWorldState()
	defer DestroyWorldState(st)
	buf := (^Rec_Buffer)(st)
	buf^ = {data = raw_data(image), capacity = c.int(len(image)), size = c.int(len(image))}
	ok := World_RestoreState(worldId, cache, st)
	buf^ = {}
	return ok
}

// Sizes and offsets from a C probe (clang, arm64 macOS) against the pinned headers. The same
// numbers hold on x64 Linux/Windows: every field is fixed-size or a pointer (8 bytes on all targets).
#assert(size_of(WorldId) == 4 && align_of(WorldId) == 2)
#assert(size_of(BodyId) == 8 && size_of(ShapeId) == 8)
#assert(size_of(WorldDef) == 152)
#assert(offset_of(WorldDef, enableSleep) == 64)
#assert(offset_of(WorldDef, workerCount) == 68)
#assert(offset_of(WorldDef, capacity) == 128)
#assert(offset_of(WorldDef, internalValue) == 148)
#assert(size_of(BodyDef) == 112)
#assert(offset_of(BodyDef, position) == 4)
#assert(offset_of(BodyDef, name) == 80)
#assert(offset_of(BodyDef, motionLocks) == 96)
#assert(offset_of(BodyDef, enableSleep) == 102)
#assert(offset_of(BodyDef, internalValue) == 108)
#assert(size_of(SurfaceMaterial) == 40 && size_of(Filter) == 24)
#assert(size_of(ShapeDef) == 120)
#assert(offset_of(ShapeDef, baseMaterial) == 32)
#assert(offset_of(ShapeDef, density) == 72)
#assert(offset_of(ShapeDef, filter) == 80)
#assert(offset_of(ShapeDef, enableCustomFiltering) == 104)
#assert(offset_of(ShapeDef, internalValue) == 116)
#assert(size_of(QueryFilter) == 32)
#assert(size_of(RayResult) == 64)
#assert(offset_of(RayResult, point) == 8)
#assert(offset_of(RayResult, fraction) == 40)
#assert(offset_of(RayResult, hit) == 60)
#assert(size_of(HullData) == 152)
#assert(size_of(BoxHull) == 696)
#assert(offset_of(BoxHull, boxVertices) == 152)
#assert(offset_of(BoxHull, boxPoints) == 160)
#assert(offset_of(BoxHull, boxEdges) == 256)
#assert(offset_of(BoxHull, boxPlanes) == 352)
#assert(offset_of(BoxHull, boxFaces) == 448)
#assert(offset_of(BoxHull, padding) == 454)
#assert(offset_of(BoxHull, vx) == 456)
#assert(offset_of(BoxHull, edgeCosines) == 648)
#assert(size_of(Sphere) == 16 && size_of(Capsule) == 28 && size_of(MotionLocks) == 6)
