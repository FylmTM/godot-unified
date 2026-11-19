// Queries (src/physics/README.md, Results): the world's casts and overlaps, the mover queries, the per-body
// and per-shape queries, sensor and contact data. Deterministic: Box3D's trees are part of the world state, so the
// same world answers the same way after a restore or on another machine, and collected results are sorted on top.
// Every result names the body (a link), the shape, the body's tag and the shape's category bits, so a game knows what
// it hit without decoding anything.
package physics

import "base:runtime"

import box3d "box3d:bindings"
import "unified:dmath"

// A shape an overlap, a sensor or a contact names.
Overlap :: struct {
	body:     Body_Link,
	shape:    Shape_Ref,
	tag:      u64, // the body's (create_body)
	category: u64, // the shape's category bits
}

// A ray or shape cast's hit.
Hit :: struct {
	using overlap: Overlap,
	material:      u64, // the user material id at the hit (a mesh triangle's, a compound child's)
	point:         [3]f32,
	normal:        [3]f32,
	fraction:      f32, // along `translation`
}

// A plane between a mover capsule and a shape (world_collide_mover, body_collide_mover).
Mover_Plane :: struct {
	using overlap: Overlap,
	plane:         Plane, // outward from the shape, relative to the query's origin
	point:         [3]f32, // the closest point on the shape, relative to the query's origin
}

// One contact manifold between two touching shapes (a mesh or height field contact can have several).
Contact_Data :: struct {
	a, b:     Overlap,
	manifold: Manifold, // its normal points from a to b
}

// The most planes body_collide_mover reports.
MAX_BODY_MOVER_PLANES :: 32

@(private)
query_filter :: proc(filter: Filter) -> box3d.QueryFilter {
	query := box3d.DefaultQueryFilter()
	if filter.category != 0 do query.categoryBits = filter.category
	if filter.mask != 0 do query.maskBits = filter.mask
	return query
}

// The overlap record of a shape (zero for a shape that no longer exists: an end event after a destroy).
@(private)
overlap_of :: proc(world: ^World, id: box3d.ShapeId) -> Overlap {
	if id.index1 == 0 || !box3d.Shape_IsValid(id) do return {}
	body := box3d.Shape_GetBody(id)
	return {link_of(body), shape_ref_of(id), tag_of(world, body.index1), box3d.Shape_GetFilter(id).categoryBits}
}

@(private)
hit_of :: proc(world: ^World, shape: box3d.ShapeId, point, normal: box3d.Vec3, fraction: f32, material: u64) -> Hit {
	return {overlap_of(world, shape), material, transmute([3]f32)point, transmute([3]f32)normal, fraction}
}

// Whether the shape is on the body `ignore` names (a zero id: none).
@(private)
on_body :: proc(shape: box3d.ShapeId, ignore: box3d.BodyId) -> bool {
	body := box3d.Shape_GetBody(shape)
	return ignore.index1 != 0 && body.index1 == ignore.index1 && body.generation == ignore.generation
}

// ---- world casts and overlaps

@(private)
Ray_Ctx :: struct {
	ctx:    runtime.Context,
	world:  ^World,
	ignore: box3d.BodyId,
	hit:    Hit,
	found:  bool,
	out:    ^[dynamic]Hit, // every hit (world_cast_ray, world_cast_shape); nil: the closest only
}

// The closest hit along `translation` from `origin`, skipping sensors and the `ignore` body (a ray that starts inside
// a shape reports it, so callers skip their own body).
world_cast_ray_closest :: proc(
	world: ^World,
	origin, translation: [3]f32,
	filter := Filter{},
	ignore := Body_Link{},
) -> (
	hit: Hit,
	ok: bool,
) {
	ray := Ray_Ctx {
		ctx    = context,
		world  = world,
		ignore = link_id(world, ignore),
	}
	box3d.World_CastRay(
		world.id,
		transmute(box3d.Vec3)origin,
		transmute(box3d.Vec3)translation,
		query_filter(filter),
		ray_callback,
		&ray,
	)
	return ray.hit, ray.found
}

// The closest hit as the world was `rewind_s` ago, to first order: what a shot hits on the picture its shooter saw a
// few ticks before (the caller caps the rewind). Bodies with no linear velocity (statics, sleepers, still bodies, and a
// body moved by body_set_transform) are cast as they are; a body driven by velocity (body_set_linear_velocity,
// body_set_target_transform, the solver) as if moved back by its linear velocity times `rewind_s`, its rotation as it
// is, so the hit's point is on the body there. Sensors and the `ignore` body are skipped. A moving body's hit wins
// over a still one's by fraction, then body and shape index; among still shapes ties go as world_cast_ray_closest's
// (Box3D's callback order). A `rewind_s` of 0 or less, or not finite, is world_cast_ray_closest. Its cost beside that
// cast: a look at the velocity of every body that isn't the active level's, and a ray per shape of each moving body
// whose box the ray crosses, so it is for a shot, not for every ray of a tick.
world_cast_ray_closest_rewound :: proc(
	world: ^World,
	origin, translation: [3]f32,
	rewind_s: f32,
	filter := Filter{},
	ignore := Body_Link{},
) -> (
	hit: Hit,
	ok: bool,
) {
	if !(rewind_s > 0 && rewind_s < max(f32)) do return world_cast_ray_closest(world, origin, translation, filter, ignore)
	// Bodies at rest, as they are: Box3D's cast, skipping every moving body.
	ray := Ray_Ctx {
		ctx    = context,
		world  = world,
		ignore = link_id(world, ignore),
	}
	box3d.World_CastRay(
		world.id,
		transmute(box3d.Vec3)origin,
		transmute(box3d.Vec3)translation,
		query_filter(filter),
		still_ray_callback,
		&ray,
	)
	hit, ok = ray.hit, ray.found
	// Each moving body, moved back: the ray moved forward by the same displacement against its shapes as they are.
	query := query_filter(filter)
	for entry, index in world.bodies {
		if .Alive not_in entry.flags || .Level in entry.flags do continue
		id := body_id(world, Body_Ref{index1 = i32(index + 1), generation = entry.generation})
		if id == ray.ignore || !box3d.Body_IsValid(id) do continue
		velocity := transmute([3]f32)box3d.Body_GetLinearVelocity(id)
		if velocity == {} do continue
		displacement := velocity * rewind_s
		shifted := origin + displacement
		count := int(box3d.Body_GetShapeCount(id))
		if count > len(world.body_shapes) do resize(&world.body_shapes, count)
		count = int(box3d.Body_GetShapes(id, raw_data(world.body_shapes), i32(count)))
		for shape in world.body_shapes[:count] {
			if box3d.Shape_IsSensor(shape) do continue
			shape_filter := box3d.Shape_GetFilter(shape)
			if shape_filter.categoryBits & query.maskBits == 0 || shape_filter.maskBits & query.categoryBits == 0 do continue
			box := transmute(AABB)box3d.Shape_GetAABB(shape)
			if !ray_crosses_box(shifted, translation, box) do continue
			candidate, found := shape_ray_cast(world, shape_ref_of(shape), shifted, translation)
			if !found do continue
			candidate.point -= displacement
			if !ok || hit_before(candidate, hit) do hit, ok = candidate, true
		}
	}
	return
}

// world_cast_ray_closest_rewound's cast of the bodies at rest: ray_callback's, skipping moving bodies too.
@(private)
still_ray_callback :: proc "c" (
	shape: box3d.ShapeId,
	point, normal: box3d.Vec3,
	fraction: f32,
	material: u64,
	child: i32,
	triangle: i32,
	user: rawptr,
) -> f32 {
	if transmute([3]f32)box3d.Body_GetLinearVelocity(box3d.Shape_GetBody(shape)) != {} do return -1
	return ray_callback(shape, point, normal, fraction, material, child, triangle, user)
}

// Whether the segment from `origin` along `translation` may touch `box` (a slab test, the box grown by a millimetre so
// rounding never rejects a touch): a cheap rejection before a shape's own ray.
@(private)
ray_crosses_box :: proc(origin, translation: [3]f32, box: AABB) -> bool {
	MARGIN :: 0.001
	enter, leave: f32 = 0, 1
	for axis in 0 ..< 3 {
		lo, hi := box.lower_bound[axis] - MARGIN, box.upper_bound[axis] + MARGIN
		start, along := origin[axis], translation[axis]
		if along == 0 {
			if start < lo || start > hi do return false
			continue
		}
		near, far := (lo - start) / along, (hi - start) / along
		if near > far do near, far = far, near
		if near > enter do enter = near
		if far < leave do leave = far
		if enter > leave do return false
	}
	return true
}

// Every hit along `translation` from `origin` into `out` (replaced, never appended to), sensors skipped, sorted by
// fraction, then body and shape index.
world_cast_ray :: proc(world: ^World, origin, translation: [3]f32, out: ^[dynamic]Hit, filter := Filter{}) {
	clear(out)
	ray := Ray_Ctx {
		ctx   = context,
		world = world,
		out   = out,
	}
	box3d.World_CastRay(
		world.id,
		transmute(box3d.Vec3)origin,
		transmute(box3d.Vec3)translation,
		query_filter(filter),
		ray_callback,
		&ray,
	)
	sort_results(world, out[:], hit_before)
}

// Every shape the proxy at `origin`, swept by `translation`, hits, into `out` (replaced), sensors skipped, sorted like
// world_cast_ray's.
world_cast_shape :: proc(
	world: ^World,
	origin: [3]f32,
	proxy: Shape_Proxy,
	translation: [3]f32,
	out: ^[dynamic]Hit,
	filter := Filter{},
) {
	clear(out)
	ray := Ray_Ctx {
		ctx   = context,
		world = world,
		out   = out,
	}
	proxy := proxy
	box3d.World_CastShape(
		world.id,
		transmute(box3d.Vec3)origin,
		(^box3d.ShapeProxy)(&proxy),
		transmute(box3d.Vec3)translation,
		query_filter(filter),
		ray_callback,
		&ray,
	)
	sort_results(world, out[:], hit_before)
}

// Box3D calls it for each shape along a cast: -1 skips the shape, `fraction` clips the cast to the hit (the closest
// only), 1 goes on (every hit).
@(private)
ray_callback :: proc "c" (
	shape: box3d.ShapeId,
	point, normal: box3d.Vec3,
	fraction: f32,
	material: u64,
	_: i32,
	_: i32,
	user: rawptr,
) -> f32 {
	ray := (^Ray_Ctx)(user)
	context = ray.ctx
	if on_body(shape, ray.ignore) || box3d.Shape_IsSensor(shape) do return -1
	hit := hit_of(ray.world, shape, point, normal, fraction, material)
	if ray.out != nil {
		append(ray.out, hit)
		return 1
	}
	ray.hit = hit
	ray.found = true
	return fraction
}

@(private)
Overlap_Ctx :: struct {
	ctx:   runtime.Context,
	world: ^World,
	out:   ^[dynamic]Overlap,
}

// Every shape whose fat AABB overlaps the box [lo, hi] ("near" rather than exact: world_overlap_shape is exact), into
// `out` (replaced), sorted by body index, then shape index. A game keeps `out` in its World as scratch: it never
// holds anything from an earlier call, so it can't carry a result into another tick (src/sim/README.md, World).
world_overlap_aabb :: proc(world: ^World, lo, hi: [3]f32, out: ^[dynamic]Overlap, filter := Filter{}) {
	clear(out)
	overlap := Overlap_Ctx{context, world, out}
	box3d.World_OverlapAABB(
		world.id,
		transmute(box3d.AABB)AABB{lo, hi},
		query_filter(filter),
		overlap_callback,
		&overlap,
	)
	sort_results(world, out[:], overlap_before)
}

// Every shape the proxy at `origin` overlaps (exactly), into `out` (replaced), sorted like world_overlap_aabb's.
world_overlap_shape :: proc(
	world: ^World,
	origin: [3]f32,
	proxy: Shape_Proxy,
	out: ^[dynamic]Overlap,
	filter := Filter{},
) {
	clear(out)
	overlap := Overlap_Ctx{context, world, out}
	proxy := proxy
	box3d.World_OverlapShape(
		world.id,
		transmute(box3d.Vec3)origin,
		(^box3d.ShapeProxy)(&proxy),
		query_filter(filter),
		overlap_callback,
		&overlap,
	)
	sort_results(world, out[:], overlap_before)
}

@(private)
overlap_callback :: proc "c" (shape: box3d.ShapeId, user: rawptr) -> bool {
	overlap := (^Overlap_Ctx)(user)
	context = overlap.ctx
	append(overlap.out, overlap_of(overlap.world, shape))
	return true
}

// ---- mover queries

@(private)
Mover_Ctx :: struct {
	ctx:    runtime.Context,
	world:  ^World,
	ignore: box3d.BodyId,
	out:    ^[dynamic]Mover_Plane,
}

// Whether a shape counts for a mover: not a sensor, not on the ignored body.
@(private)
mover_accepts :: proc "c" (shape: box3d.ShapeId, user: rawptr) -> bool {
	mover := (^Mover_Ctx)(user)
	context = mover.ctx
	return !on_body(shape, mover.ignore) && !box3d.Shape_IsSensor(shape)
}

// How far (a fraction of `translation`) the mover capsule (relative to `origin`) sweeps before it hits a shape; 1: no
// hit. Sensors, the `ignore` body and shapes it starts inside are skipped.
world_cast_mover :: proc(
	world: ^World,
	origin: [3]f32,
	mover: Capsule,
	translation: [3]f32,
	filter := Filter{},
	ignore := Body_Link{},
) -> f32 {
	ctx := Mover_Ctx {
		ctx    = context,
		world  = world,
		ignore = link_id(world, ignore),
	}
	mover := mover
	return box3d.World_CastMover(
		world.id,
		transmute(box3d.Vec3)origin,
		(^box3d.Capsule)(&mover),
		transmute(box3d.Vec3)translation,
		query_filter(filter),
		mover_accepts,
		&ctx,
	)
}

// The planes between the mover capsule (relative to `origin`) and every shape it touches, into `out` (replaced),
// sensors and the `ignore` body skipped, sorted by body index, then shape index (a shape's planes in Box3D's order).
world_collide_mover :: proc(
	world: ^World,
	origin: [3]f32,
	mover: Capsule,
	out: ^[dynamic]Mover_Plane,
	filter := Filter{},
	ignore := Body_Link{},
) {
	clear(out)
	ctx := Mover_Ctx {
		ctx    = context,
		world  = world,
		ignore = link_id(world, ignore),
		out    = out,
	}
	mover := mover
	box3d.World_CollideMover(
		world.id,
		transmute(box3d.Vec3)origin,
		(^box3d.Capsule)(&mover),
		query_filter(filter),
		mover_planes_callback,
		&ctx,
	)
	sort_results(world, out[:], plane_before)
}

@(private)
mover_planes_callback :: proc "c" (
	shape: box3d.ShapeId,
	planes: ^box3d.PlaneResult,
	count: i32,
	user: rawptr,
) -> bool {
	if !mover_accepts(shape, user) do return true
	mover := (^Mover_Ctx)(user)
	context = mover.ctx
	for plane in ([^]box3d.PlaneResult)(planes)[:count] {
		append(mover.out, mover_plane_of(mover.world, shape, plane))
	}
	return true
}

@(private)
mover_plane_of :: proc(world: ^World, shape: box3d.ShapeId, plane: box3d.PlaneResult) -> Mover_Plane {
	return {overlap_of(world, shape), transmute(Plane)plane.plane, transmute([3]f32)plane.point}
}

// The translation that brings a mover as close to `target_delta` (its wanted translation from where the planes were
// collected: world_collide_mover's origin) as `planes` allow, each plane's `push` set to how far it pushed. Box3D's
// plane solver: a kinematic mover's step is collide, solve, move by the delta, then clip_vector its velocity.
solve_planes :: proc(target_delta: [3]f32, planes: []Collision_Plane) -> Plane_Solver_Result {
	return(
		transmute(Plane_Solver_Result)box3d.SolvePlanes(
			transmute(box3d.Vec3)target_delta,
			(^box3d.CollisionPlane)(raw_data(planes)),
			i32(len(planes)),
		) \
	)
}

// `vector` (a mover's velocity) with its part into each plane that pushed (`push` > 0 after solve_planes) and clips
// (`clip_velocity`) removed, so the mover slides along what it touches.
clip_vector :: proc(vector: [3]f32, planes: []Collision_Plane) -> [3]f32 {
	return(
		transmute([3]f32)box3d.ClipVector(
			transmute(box3d.Vec3)vector,
			(^box3d.CollisionPlane)(raw_data(planes)),
			i32(len(planes)),
		) \
	)
}

// ---- per-body queries (`pose` nil: the body where it is)

// A ray from `origin` along `translation` against this body's shapes alone (sensors too); not ok: no hit.
body_cast_ray :: proc(
	world: ^World,
	ref: Body_Ref,
	origin, translation: [3]f32,
	filter := Filter{},
	max_fraction: f32 = 1,
	pose: Maybe(Transform) = nil,
) -> (
	hit: Hit,
	ok: bool,
) {
	id := body_id(world, ref)
	result := box3d.Body_CastRay(
		id,
		transmute(box3d.Vec3)origin,
		transmute(box3d.Vec3)translation,
		query_filter(filter),
		max_fraction,
		pose_of(id, pose),
	)
	if !result.hit do return {}, false
	return hit_of(world, result.shapeId, result.point, result.normal, result.fraction, result.userMaterialId), true
}

// A proxy at `origin` swept by `translation` against this body's shapes; not ok: no hit. `can_encroach` lets a
// rounded proxy end closer than its radius.
body_cast_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	origin: [3]f32,
	proxy: Shape_Proxy,
	translation: [3]f32,
	filter := Filter{},
	max_fraction: f32 = 1,
	can_encroach := false,
	pose: Maybe(Transform) = nil,
) -> (
	hit: Hit,
	ok: bool,
) {
	id := body_id(world, ref)
	proxy := proxy
	result := box3d.Body_CastShape(
		id,
		transmute(box3d.Vec3)origin,
		(^box3d.ShapeProxy)(&proxy),
		transmute(box3d.Vec3)translation,
		query_filter(filter),
		max_fraction,
		can_encroach,
		pose_of(id, pose),
	)
	if !result.hit do return {}, false
	return hit_of(world, result.shapeId, result.point, result.normal, result.fraction, result.userMaterialId), true
}

// Whether the proxy at `origin` overlaps one of this body's shapes.
body_overlap_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	origin: [3]f32,
	proxy: Shape_Proxy,
	filter := Filter{},
	pose: Maybe(Transform) = nil,
) -> bool {
	id := body_id(world, ref)
	proxy := proxy
	return box3d.Body_OverlapShape(
		id,
		transmute(box3d.Vec3)origin,
		(^box3d.ShapeProxy)(&proxy),
		query_filter(filter),
		pose_of(id, pose),
	)
}

// The point of the body's spheres, capsules and hulls closest to `target`, and its distance (0 inside).
body_closest_point :: proc(world: ^World, ref: Body_Ref, target: [3]f32) -> (point: [3]f32, distance: f32) {
	distance = box3d.Body_GetClosestPoint(body_id(world, ref), (^box3d.Vec3)(&point), transmute(box3d.Vec3)target)
	return
}

// The planes between the mover capsule (relative to `origin`) and this body's shapes, into `out` (replaced; at most
// MAX_BODY_MOVER_PLANES), sorted by shape index.
body_collide_mover :: proc(
	world: ^World,
	ref: Body_Ref,
	origin: [3]f32,
	mover: Capsule,
	out: ^[dynamic]Mover_Plane,
	filter := Filter{},
	pose: Maybe(Transform) = nil,
) {
	clear(out)
	id := body_id(world, ref)
	mover := mover
	planes: [MAX_BODY_MOVER_PLANES]box3d.BodyPlaneResult
	count := box3d.Body_CollideMover(
		id,
		raw_data(planes[:]),
		len(planes),
		transmute(box3d.Vec3)origin,
		(^box3d.Capsule)(&mover),
		query_filter(filter),
		pose_of(id, pose),
	)
	for plane in planes[:count] {
		append(out, mover_plane_of(world, plane.shapeId, plane.result))
	}
	sort_results(world, out[:], plane_before)
}

// When the mover capsule (relative to `origin`) swept by `translation` first touches this body moving from `pose1` to
// `pose2` (nil: where it is); shapes the mover starts inside are skipped. Not ok: no hit. The hit's normal points
// from the body to the mover. The material is the shape's first (Box3D names no triangle or child here): a ray
// (shape_ray_cast) names a mesh triangle's or a compound child's, as on a level.
body_time_of_impact_mover :: proc(
	world: ^World,
	ref: Body_Ref,
	origin: [3]f32,
	mover: Capsule,
	translation: [3]f32,
	filter := Filter{},
	pose1: Maybe(Transform) = nil,
	pose2: Maybe(Transform) = nil,
) -> (
	hit: Hit,
	ok: bool,
) {
	id := body_id(world, ref)
	mover := mover
	result := box3d.Body_TimeOfImpactMover(
		id,
		transmute(box3d.Vec3)origin,
		(^box3d.Capsule)(&mover),
		transmute(box3d.Vec3)translation,
		query_filter(filter),
		pose_of(id, pose1),
		pose_of(id, pose2),
	)
	if result.fraction >= 1 do return {}, false
	material := box3d.Shape_GetSurfaceMaterial(result.shapeId).userMaterialId
	return hit_of(world, result.shapeId, result.point, result.normal, result.fraction, material), true
}

@(private)
pose_of :: proc(id: box3d.BodyId, pose: Maybe(Transform)) -> box3d.Transform {
	transform, given := pose.?
	return transmute(box3d.Transform)transform if given else box3d.Body_GetTransform(id)
}

// ---- per-shape queries

// A ray from `origin` along `translation` against this shape alone; not ok: no hit. The material is the hit
// triangle's on a mesh or height field, the child's on a compound.
shape_ray_cast :: proc(world: ^World, shape: Shape_Ref, origin, translation: [3]f32) -> (hit: Hit, ok: bool) {
	id := shape_id(world, shape)
	output := box3d.Shape_RayCast(id, transmute(box3d.Vec3)origin, transmute(box3d.Vec3)translation)
	if !output.hit do return {}, false
	material := box3d.Shape_GetSurfaceMaterial(id).userMaterialId
	if output.materialIndex >= 0 && output.materialIndex < box3d.Shape_GetMeshMaterialCount(id) {
		material = box3d.Shape_GetMeshSurfaceMaterial(id, output.materialIndex).userMaterialId
	}
	return hit_of(world, id, output.point, output.normal, output.fraction, material), true
}

// The point on the shape (a sphere, capsule or hull) closest to `target`, in world space.
shape_closest_point :: proc(world: ^World, shape: Shape_Ref, target: [3]f32) -> [3]f32 {
	return transmute([3]f32)box3d.Shape_GetClosestPoint(shape_id(world, shape), transmute(box3d.Vec3)target)
}

// The shapes inside a sensor after the last step, into `out` (replaced), sorted by body index, then shape index.
shape_sensor_data :: proc(world: ^World, sensor: Shape_Ref, out: ^[dynamic]Overlap) {
	clear(out)
	id := shape_id(world, sensor)
	capacity := int(box3d.Shape_GetSensorCapacity(id))
	if capacity == 0 do return
	resize(&world.visitors, capacity)
	count := box3d.Shape_GetSensorData(id, raw_data(world.visitors), i32(capacity))
	for visitor in world.visitors[:count] {
		append(out, overlap_of(world, visitor))
	}
	sort_results(world, out[:], overlap_before)
}

// ---- contact data

// The body's touching contacts after the last step into `out` (replaced): one entry per manifold, sorted by a's body
// and shape index, then b's.
body_contact_data :: proc(world: ^World, ref: Body_Ref, out: ^[dynamic]Contact_Data) {
	collect_contacts(world, out, body_id(world, ref), {})
}

// The shape's touching contacts after the last step into `out` (replaced), as body_contact_data's.
shape_contact_data :: proc(world: ^World, shape: Shape_Ref, out: ^[dynamic]Contact_Data) {
	collect_contacts(world, out, {}, shape_id(world, shape))
}

// Box3D writes its contacts (a few of them fit in each Contact_Data) into `out`'s own memory, so no scratch is
// needed; they are then moved past the entries' room and each manifold becomes an entry, never overwriting a raw
// contact before it is read.
@(private)
collect_contacts :: proc(world: ^World, out: ^[dynamic]Contact_Data, body: box3d.BodyId, shape: box3d.ShapeId) {
	RAW_PER_ENTRY :: size_of(Contact_Data) / size_of(box3d.ContactData)
	#assert(RAW_PER_ENTRY >= 1 && align_of(Contact_Data) >= align_of(box3d.ContactData))
	clear(out)
	from_body := body.index1 != 0
	capacity := int(from_body ? box3d.Body_GetContactCapacity(body) : box3d.Shape_GetContactCapacity(shape))
	if capacity == 0 do return
	resize(out, (capacity + RAW_PER_ENTRY - 1) / RAW_PER_ENTRY)
	raw := ([^]box3d.ContactData)(raw_data(out^))
	count := int(
		from_body ? box3d.Body_GetContactData(body, raw, i32(capacity)) : box3d.Shape_GetContactData(shape, raw, i32(capacity)),
	)
	if count == 0 {
		clear(out)
		return
	}
	manifolds := 0
	for contact in raw[:count] {
		manifolds += int(contact.manifoldCount)
	}
	resize(out, manifolds + (count + RAW_PER_ENTRY - 1) / RAW_PER_ENTRY)
	front := ([^]box3d.ContactData)(raw_data(out^))[:count]
	tail := ([^]box3d.ContactData)(&out[manifolds])[:count]
	copy(tail, front) // a memmove: the two may overlap
	entry := 0
	for contact in tail {
		a, b := overlap_of(world, contact.shapeIdA), overlap_of(world, contact.shapeIdB)
		for manifold in ([^]Manifold)(contact.manifolds)[:contact.manifoldCount] {
			out[entry] = {a, b, manifold}
			entry += 1
		}
	}
	resize(out, manifolds)
	sort_results(world, out[:], contact_before)
}

// ---- deterministic order

// Results up to this many are sorted by insertion; above, a merge sort of insertion-sorted runs this long.
@(private)
SORT_RUN :: 16

// Sorts `items` by `before`, stably (equal keys keep Box3D's order), without core:slice (not in tick code): by
// insertion for a handful of results; above SORT_RUN (a broad overlap, a crowd in a sensor) a bottom-up merge sort
// through the World's scratch, O(n log n) and the same order.
@(private)
sort_results :: proc(world: ^World, items: []$T, before: proc(a, b: T) -> bool) {
	if len(items) <= SORT_RUN {
		insertion_sort(items, before)
		return
	}
	#assert(align_of(T) <= align_of(u64))
	words := (len(items) * size_of(T) + size_of(u64) - 1) / size_of(u64)
	if len(world.sort_scratch) < words do resize(&world.sort_scratch, words)
	scratch := ([^]T)(raw_data(world.sort_scratch))[:len(items)]
	for start := 0; start < len(items); start += SORT_RUN {
		insertion_sort(items[start:dmath.min(start + SORT_RUN, len(items))], before)
	}
	from, to := items, scratch
	for width := SORT_RUN; width < len(items); width *= 2 {
		for start := 0; start < len(items); start += 2 * width {
			middle := dmath.min(start + width, len(items))
			end := dmath.min(start + 2 * width, len(items))
			merge_runs(from[start:middle], from[middle:end], to[start:end], before)
		}
		from, to = to, from
	}
	if raw_data(from) != raw_data(items) do copy(items, from)
}

// Merges two sorted runs into `out`; on equal keys the left run's item goes first (stable).
@(private)
merge_runs :: proc(left, right, out: []$T, before: proc(a, b: T) -> bool) {
	i, j := 0, 0
	for i < len(left) && j < len(right) {
		if before(right[j], left[i]) {
			out[i + j] = right[j]
			j += 1
		} else {
			out[i + j] = left[i]
			i += 1
		}
	}
	copy(out[i + j:], left[i:])
	copy(out[i + j + len(left) - i:], right[j:])
}

// Sorts a handful of `items` by `before`, stably.
@(private)
insertion_sort :: proc(items: []$T, before: proc(a, b: T) -> bool) {
	for i in 1 ..< len(items) {
		held := items[i]
		j := i
		for j > 0 && before(held, items[j - 1]) {
			items[j] = items[j - 1]
			j -= 1
		}
		items[j] = held
	}
}

@(private)
overlap_before :: proc(a, b: Overlap) -> bool {
	if a.body.index1 != b.body.index1 do return a.body.index1 < b.body.index1
	return a.shape.index1 < b.shape.index1
}

@(private)
hit_before :: proc(a, b: Hit) -> bool {
	if a.fraction != b.fraction do return a.fraction < b.fraction
	return overlap_before(a, b)
}

@(private)
plane_before :: proc(a, b: Mover_Plane) -> bool {
	return overlap_before(a, b)
}

@(private)
contact_before :: proc(a, b: Contact_Data) -> bool {
	if a.a.body.index1 != b.a.body.index1 || a.a.shape.index1 != b.a.shape.index1 do return overlap_before(a.a, b.a)
	return overlap_before(a.b, b.b)
}
