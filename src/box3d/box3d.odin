// Hand-written Box3D bindings: only what unified uses, transcribed from the pinned headers
// (commit 336263320469e5e9febfe18697ab562488f7e97a, single precision) plus the save/restore fork API
// from third_party/box3d.patch. Odin's `vendor:box3d` targets an older commit with a different ABI
// (b3WorldDef, b3BodyDef, b3HullData, b3BoxHull and b3RayResult all changed), so it can't be used.
// Layouts are checked with #assert against sizes/offsets from a C probe on the pinned headers.
//
// The static library is the one `tools/box3d.py` builds into third_party/box3d/build/<platform>/
// (Windows: static CRT, matching Odin's default). It is imported by relative path, so a plain
// `odin build`/`odin test` links it with no extra linker flags; a missing library only fails at
// link time (`odin check` and OLS don't need it).
package box3d

import "core:c"

when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	foreign import lib "../../third_party/box3d/build/macos-arm64/lib/libbox3d.a"
} else when ODIN_OS == .Darwin && ODIN_ARCH == .amd64 {
	foreign import lib "../../third_party/box3d/build/macos-x64/lib/libbox3d.a"
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	foreign import lib {"../../third_party/box3d/build/linux-x64/lib/libbox3d.a", "system:m", "system:pthread"}
} else when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
	foreign import lib "../../third_party/box3d/build/windows-x64/lib/box3d.lib"
} else {
	#panic(
		"unified: no Box3D build for this target (tools/box3d.py builds macos-arm64, macos-x64, linux-x64, windows-x64)",
	)
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

JointId :: struct {
	index1:     i32,
	world0:     u16,
	generation: u16,
}

ContactId :: struct {
	index1:     i32,
	world0:     u16,
	padding:    i16,
	generation: u32,
}

Transform :: struct {
	p: Vec3,
	q: Quat,
}

TreeStats :: struct {
	nodeVisits, leafVisits: c.int,
}

JointDef :: struct {
	userData:               rawptr,
	bodyIdA:                BodyId,
	bodyIdB:                BodyId,
	localFrameA:            Transform,
	localFrameB:            Transform,
	forceThreshold:         f32,
	torqueThreshold:        f32,
	constraintHertz:        f32,
	constraintDampingRatio: f32,
	drawScale:              f32,
	collideConnected:       bool,
	internalValue:          c.int,
}

MotorJointDef :: struct {
	base:                JointDef,
	linearVelocity:      Vec3,
	maxVelocityForce:    f32,
	angularVelocity:     Vec3,
	maxVelocityTorque:   f32,
	linearHertz:         f32,
	linearDampingRatio:  f32,
	maxSpringForce:      f32,
	angularHertz:        f32,
	angularDampingRatio: f32,
	maxSpringTorque:     f32,
}

MoverJointDef :: struct {
	base:           JointDef,
	linearVelocity: Vec3,
	maxForce:       f32,
}

PogoJointDef :: struct {
	base:                JointDef,
	normal:              Vec3,
	hertz:               f32,
	dampingRatio:        f32,
	restLength:          f32,
	maxTensionForce:     f32,
	maxCompressionForce: f32,
	impulse:             f32,
	velocity:            f32,
}

ContactBeginTouchEvent :: struct {
	shapeIdA, shapeIdB: ShapeId,
	contactId:          ContactId,
}

ContactEndTouchEvent :: ContactBeginTouchEvent

ContactHitEvent :: struct {
	shapeIdA, shapeIdB: ShapeId,
	contactId:          ContactId,
	point:              Pos,
	normal:             Vec3,
	approachSpeed:      f32,
	userMaterialIdA:    u64,
	userMaterialIdB:    u64,
}

ContactEvents :: struct {
	beginEvents: [^]ContactBeginTouchEvent,
	endEvents:   [^]ContactEndTouchEvent,
	hitEvents:   [^]ContactHitEvent,
	beginCount:  c.int,
	endCount:    c.int,
	hitCount:    c.int,
}

// Query callbacks (box3d/types.h). Return -1 to ignore a shape, 0 to stop, the fraction to clip.
CastResultFcn :: #type proc "c" (
	shapeId: ShapeId,
	point: Pos,
	normal: Vec3,
	fraction: f32,
	userMaterialId: u64,
	triangleIndex: c.int,
	childIndex: c.int,
	ctx: rawptr,
) -> f32
OverlapResultFcn :: #type proc "c" (shapeId: ShapeId, ctx: rawptr) -> bool

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
	World_CastRay :: proc(worldId: WorldId, origin: Pos, translation: Vec3, filter: QueryFilter, fcn: CastResultFcn, ctx: rawptr) -> TreeStats ---
	World_OverlapAABB :: proc(worldId: WorldId, aabb: AABB, filter: QueryFilter, fcn: OverlapResultFcn, ctx: rawptr) -> TreeStats ---
	World_GetContactEvents :: proc(worldId: WorldId) -> ContactEvents ---
	World_GetGravity :: proc(worldId: WorldId) -> Vec3 ---

	CreateBody :: proc(worldId: WorldId, def: ^BodyDef) -> BodyId ---
	DestroyBody :: proc(bodyId: BodyId) ---
	Body_ApplyLinearImpulseToCenter :: proc(bodyId: BodyId, impulse: Vec3, wake: bool) ---
	Body_GetPosition :: proc(bodyId: BodyId) -> Pos ---
	Body_GetRotation :: proc(bodyId: BodyId) -> Quat ---
	Body_GetLinearVelocity :: proc(bodyId: BodyId) -> Vec3 ---
	Body_GetAngularVelocity :: proc(bodyId: BodyId) -> Vec3 ---
	Body_SetLinearVelocity :: proc(bodyId: BodyId, linearVelocity: Vec3) ---
	Body_SetAngularVelocity :: proc(bodyId: BodyId, angularVelocity: Vec3) ---
	Body_IsValid :: proc(bodyId: BodyId) -> bool ---
	Body_GetType :: proc(bodyId: BodyId) -> BodyType ---
	Body_SetTransform :: proc(bodyId: BodyId, position: Pos, rotation: Quat) ---
	Body_GetLocalPoint :: proc(bodyId: BodyId, worldPoint: Pos) -> Vec3 ---
	Body_GetMass :: proc(bodyId: BodyId) -> f32 ---
	Shape_GetBody :: proc(shapeId: ShapeId) -> BodyId ---
	Shape_IsSensor :: proc(shapeId: ShapeId) -> bool ---

	DefaultMotorJointDef :: proc() -> MotorJointDef ---
	DefaultMoverJointDef :: proc() -> MoverJointDef ---
	DefaultPogoJointDef :: proc() -> PogoJointDef ---
	CreateMotorJoint :: proc(worldId: WorldId, def: ^MotorJointDef) -> JointId ---
	CreateMoverJoint :: proc(worldId: WorldId, def: ^MoverJointDef) -> JointId ---
	CreatePogoJoint :: proc(worldId: WorldId, def: ^PogoJointDef) -> JointId ---
	DestroyJoint :: proc(jointId: JointId, wakeAttached: bool) ---
	Joint_IsValid :: proc(jointId: JointId) -> bool ---
	Joint_GetBodyA :: proc(jointId: JointId) -> BodyId ---
	Joint_SetLocalFrameA :: proc(jointId: JointId, localFrame: Transform) ---
	Joint_SetLocalFrameB :: proc(jointId: JointId, localFrame: Transform) ---
	MotorJoint_SetMaxSpringForce :: proc(jointId: JointId, maxForce: f32) ---
	MoverJoint_SetLinearVelocity :: proc(jointId: JointId, velocity: Vec3) ---
	MoverJoint_SetMaxVelocityForce :: proc(jointId: JointId, maxForce: f32) ---
	PogoJoint_SetSpringHertz :: proc(jointId: JointId, hertz: f32) ---
	PogoJoint_SetSpringDampingRatio :: proc(jointId: JointId, dampingRatio: f32) ---
	PogoJoint_SetMaxTensionForce :: proc(jointId: JointId, force: f32) ---
	PogoJoint_SetMaxCompressionForce :: proc(jointId: JointId, force: f32) ---
	PogoJoint_SetNormal :: proc(jointId: JointId, normal: Vec3) ---
	PogoJoint_GetCurrentSpeed :: proc(jointId: JointId) -> f32 ---
	PogoJoint_GetImpulse :: proc(jointId: JointId) -> f32 ---

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
	buf^ = {
		data     = raw_data(image),
		capacity = c.int(len(image)),
		size     = c.int(len(image)),
	}
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
#assert(size_of(JointId) == 8 && size_of(ContactId) == 12 && size_of(Transform) == 28 && size_of(TreeStats) == 8)
#assert(size_of(JointDef) == 112)
#assert(offset_of(JointDef, bodyIdA) == 8)
#assert(offset_of(JointDef, localFrameA) == 24)
#assert(offset_of(JointDef, localFrameB) == 52)
#assert(offset_of(JointDef, forceThreshold) == 80)
#assert(offset_of(JointDef, collideConnected) == 100)
#assert(offset_of(JointDef, internalValue) == 104)
#assert(size_of(MotorJointDef) == 168)
#assert(offset_of(MotorJointDef, linearVelocity) == 112)
#assert(offset_of(MotorJointDef, maxVelocityForce) == 124)
#assert(offset_of(MotorJointDef, angularVelocity) == 128)
#assert(offset_of(MotorJointDef, linearHertz) == 144)
#assert(offset_of(MotorJointDef, maxSpringTorque) == 164)
#assert(size_of(MoverJointDef) == 128 && offset_of(MoverJointDef, maxForce) == 124)
#assert(size_of(PogoJointDef) == 152)
#assert(offset_of(PogoJointDef, normal) == 112)
#assert(offset_of(PogoJointDef, hertz) == 124)
#assert(offset_of(PogoJointDef, maxCompressionForce) == 140)
#assert(offset_of(PogoJointDef, velocity) == 148)
#assert(size_of(ContactBeginTouchEvent) == 28)
#assert(size_of(ContactHitEvent) == 72)
#assert(offset_of(ContactHitEvent, contactId) == 16)
#assert(offset_of(ContactHitEvent, point) == 28)
#assert(offset_of(ContactHitEvent, approachSpeed) == 52)
#assert(offset_of(ContactHitEvent, userMaterialIdA) == 56)
#assert(offset_of(ContactHitEvent, userMaterialIdB) == 64)
#assert(size_of(ContactEvents) == 40)
#assert(offset_of(ContactEvents, hitEvents) == 16)
#assert(offset_of(ContactEvents, beginCount) == 24)
#assert(offset_of(ContactEvents, hitCount) == 32)
