// The mover queries, the per-body and per-shape queries, contact data and the body and joint events
// (src/physics/SPEC.md, What physics covers), in deterministic order like query.odin's: collected results are sorted,
// events come in Box3D's order (part of the world state), and every result naming a body carries its tag and the
// shape's category bits.
package physics

import "unified:b3"

Plane :: b3.Plane
Manifold :: b3.Manifold
Manifold_Point :: b3.Manifold_Point

// A plane between a mover capsule and a shape (world_collide_mover, body_collide_mover).
Mover_Plane :: struct {
	body:     Body_Link,
	shape:    Shape_Ref,
	tag:      u64, // the body's
	category: u64, // the shape's category bits
	plane:    Plane, // outward from the shape, relative to the query's origin
	point:    [3]f32, // the closest point on the shape, relative to the query's origin
}

// One contact manifold between two touching shapes (a mesh or height field contact can have several).
Contact_Data :: struct {
	a, b:     Overlap,
	manifold: Manifold, // its normal points from a to b
}

// A body that moved in the last step (every awake dynamic or kinematic body).
Body_Move_Event :: struct {
	body:        Body_Link,
	tag:         u64,
	transform:   Transform,
	fell_asleep: bool,
}

// The most planes body_collide_mover reports.
MAX_BODY_MOVER_PLANES :: 32

// ---- mover queries

@(private)
Mover_Ctx :: struct {
	world:  ^World,
	ignore: b3.Body_Id,
	out:    ^[dynamic]Mover_Plane,
}

// Whether a shape counts for a mover: not a sensor, not on the ignored body.
@(private)
mover_accepts :: proc(shape: b3.Shape_Id, user: rawptr) -> bool {
	ctx := (^Mover_Ctx)(user)
	body := b3.shape_get_body(shape)
	ignored := ctx.ignore.index1 != 0 && body.index1 == ctx.ignore.index1 && body.generation == ctx.ignore.generation
	return !ignored && !b3.shape_is_sensor(shape)
}

// How far (a fraction of `translation`) the mover capsule (relative to `origin`) sweeps before it hits a shape; 1: no
// hit. Sensors, the `ignore` body and shapes it starts inside are skipped.
world_cast_mover :: proc(
	world: ^World,
	origin: [3]f32,
	mover: Capsule,
	translation: [3]f32,
	query := Query{},
	ignore := Body_Link{},
) -> f32 {
	ctx := Mover_Ctx {
		world  = world,
		ignore = link_id(world, ignore),
	}
	mover := mover
	return b3.world_cast_mover(world.id, origin, &mover, translation, query_filter(query), mover_accepts, &ctx)
}

// The planes between the mover capsule (relative to `origin`) and every shape it touches, into `out` (replaced),
// sensors and the `ignore` body skipped, sorted by body index, then shape index (a shape's planes in Box3D's order).
world_collide_mover :: proc(
	world: ^World,
	origin: [3]f32,
	mover: Capsule,
	out: ^[dynamic]Mover_Plane,
	query := Query{},
	ignore := Body_Link{},
) {
	clear(out)
	ctx := Mover_Ctx {
		world  = world,
		ignore = link_id(world, ignore),
		out    = out,
	}
	mover := mover
	b3.world_collide_mover(world.id, origin, &mover, query_filter(query), mover_planes_callback, &ctx)
	sort_mover_planes(out[:])
}

@(private)
mover_planes_callback :: proc(shape: b3.Shape_Id, planes: []b3.Plane_Result, user: rawptr) -> bool {
	ctx := (^Mover_Ctx)(user)
	if !mover_accepts(shape, user) do return true
	for plane in planes {
		append(ctx.out, mover_plane_of(ctx.world, shape, plane))
	}
	return true
}

@(private)
mover_plane_of :: proc(world: ^World, shape: b3.Shape_Id, plane: b3.Plane_Result) -> Mover_Plane {
	overlap := overlap_of(world, shape)
	return {overlap.body, overlap.shape, overlap.tag, overlap.category, plane.plane, plane.point}
}

// ---- per-body queries (`pose` nil: the body where it is)

// A ray from `origin` along `translation` against this body's shapes alone (sensors too); not ok: no hit.
body_cast_ray :: proc(
	world: ^World,
	ref: Body_Ref,
	origin, translation: [3]f32,
	query := Query{},
	max_fraction: f32 = 1,
	pose: Maybe(Transform) = nil,
) -> (
	hit: Ray_Hit,
	ok: bool,
) {
	id := body_id(world, ref)
	result: b3.Body_Cast_Result
	result, ok = b3.body_cast_ray(id, origin, translation, query_filter(query), max_fraction, pose_of(id, pose))
	if !ok do return {}, false
	return body_hit_of(world, result), true
}

// A proxy at `origin` swept by `translation` against this body's shapes; not ok: no hit. `can_encroach` lets a
// rounded proxy end closer than its radius.
body_cast_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	origin: [3]f32,
	proxy: Shape_Proxy,
	translation: [3]f32,
	query := Query{},
	max_fraction: f32 = 1,
	can_encroach := false,
	pose: Maybe(Transform) = nil,
) -> (
	hit: Ray_Hit,
	ok: bool,
) {
	id := body_id(world, ref)
	proxy := proxy
	result: b3.Body_Cast_Result
	result, ok = b3.body_cast_shape(
		id,
		origin,
		&proxy,
		translation,
		query_filter(query),
		max_fraction,
		can_encroach,
		pose_of(id, pose),
	)
	if !ok do return {}, false
	return body_hit_of(world, result), true
}

// Whether the proxy at `origin` overlaps one of this body's shapes.
body_overlap_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	origin: [3]f32,
	proxy: Shape_Proxy,
	query := Query{},
	pose: Maybe(Transform) = nil,
) -> bool {
	id := body_id(world, ref)
	proxy := proxy
	return b3.body_overlap_shape(id, origin, &proxy, query_filter(query), pose_of(id, pose))
}

// The point of the body's spheres, capsules and hulls closest to `target`, and its distance (0 inside).
body_closest_point :: proc(world: ^World, ref: Body_Ref, target: [3]f32) -> (point: [3]f32, distance: f32) {
	return b3.body_get_closest_point(body_id(world, ref), target)
}

// The planes between the mover capsule (relative to `origin`) and this body's shapes, into `out` (replaced; at most
// MAX_BODY_MOVER_PLANES), sorted by shape index.
body_collide_mover :: proc(
	world: ^World,
	ref: Body_Ref,
	origin: [3]f32,
	mover: Capsule,
	out: ^[dynamic]Mover_Plane,
	query := Query{},
	pose: Maybe(Transform) = nil,
) {
	clear(out)
	id := body_id(world, ref)
	mover := mover
	planes: [MAX_BODY_MOVER_PLANES]b3.Body_Plane_Result
	count := b3.body_collide_mover(id, planes[:], origin, &mover, query_filter(query), pose_of(id, pose))
	for plane in planes[:count] {
		append(out, mover_plane_of(world, plane.shape_id, plane.result))
	}
	sort_mover_planes(out[:])
}

// When the mover capsule (relative to `origin`) swept by `translation` first touches this body moving from `pose1` to
// `pose2` (nil: where it is); shapes the mover starts inside are skipped. Not ok: no hit. The hit's normal points
// from the body to the mover.
body_time_of_impact_mover :: proc(
	world: ^World,
	ref: Body_Ref,
	origin: [3]f32,
	mover: Capsule,
	translation: [3]f32,
	query := Query{},
	pose1: Maybe(Transform) = nil,
	pose2: Maybe(Transform) = nil,
) -> (
	hit: Ray_Hit,
	ok: bool,
) {
	id := body_id(world, ref)
	mover := mover
	result := b3.body_time_of_impact_mover(
		id,
		origin,
		&mover,
		translation,
		query_filter(query),
		pose_of(id, pose1),
		pose_of(id, pose2),
	)
	if result.fraction >= 1 do return {}, false
	material := b3.shape_get_surface_material(result.shape_id).user_material_id
	return hit_of(world, result.shape_id, result.point, result.normal, result.fraction, material), true
}

@(private)
pose_of :: proc(id: b3.Body_Id, pose: Maybe(Transform)) -> Transform {
	transform, given := pose.?
	return transform if given else b3.body_get_transform(id)
}

@(private)
body_hit_of :: proc(world: ^World, result: b3.Body_Cast_Result) -> Ray_Hit {
	return hit_of(world, result.shape_id, result.point, result.normal, result.fraction, result.user_material_id)
}

@(private)
hit_of :: proc(world: ^World, shape: b3.Shape_Id, point, normal: [3]f32, fraction: f32, material: u64) -> Ray_Hit {
	overlap := overlap_of(world, shape)
	return {overlap.body, overlap.shape, overlap.tag, overlap.category, material, point, normal, fraction}
}

// ---- per-shape queries

// A ray from `origin` along `translation` against this shape alone; not ok: no hit. The material is the hit
// triangle's on a mesh or height field.
shape_ray_cast :: proc(world: ^World, shape: Shape_Ref, origin, translation: [3]f32) -> (hit: Ray_Hit, ok: bool) {
	id := shape_id(world, shape)
	output: b3.Cast_Output
	output, ok = b3.shape_ray_cast(id, origin, translation)
	if !ok do return {}, false
	material := b3.shape_get_surface_material(id).user_material_id
	if output.material_index >= 0 && output.material_index < b3.shape_get_mesh_material_count(id) {
		material = b3.shape_get_mesh_surface_material(id, output.material_index).user_material_id
	}
	return hit_of(world, id, output.point, output.normal, output.fraction, material), true
}

// The point on the shape (a sphere, capsule or hull) closest to `target`, in world space.
shape_closest_point :: proc(world: ^World, shape: Shape_Ref, target: [3]f32) -> [3]f32 {
	return b3.shape_get_closest_point(shape_id(world, shape), target)
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
collect_contacts :: proc(world: ^World, out: ^[dynamic]Contact_Data, body: b3.Body_Id, shape: b3.Shape_Id) {
	RAW_PER_ENTRY :: size_of(Contact_Data) / size_of(b3.Contact_Data)
	#assert(RAW_PER_ENTRY >= 1 && align_of(Contact_Data) >= align_of(b3.Contact_Data))
	clear(out)
	from_body := body.index1 != 0
	capacity := int(from_body ? b3.body_get_contact_capacity(body) : b3.shape_get_contact_capacity(shape))
	if capacity == 0 do return
	resize(out, (capacity + RAW_PER_ENTRY - 1) / RAW_PER_ENTRY)
	raw := ([^]b3.Contact_Data)(raw_data(out^))[:capacity]
	count := int(from_body ? b3.body_get_contact_data(body, raw) : b3.shape_get_contact_data(shape, raw))
	if count == 0 {
		clear(out)
		return
	}
	manifolds := 0
	for contact in raw[:count] {
		manifolds += int(contact.manifold_count)
	}
	resize(out, manifolds + (count + RAW_PER_ENTRY - 1) / RAW_PER_ENTRY)
	front := ([^]b3.Contact_Data)(raw_data(out^))[:count]
	tail := ([^]b3.Contact_Data)(&out[manifolds])[:count]
	copy(tail, front) // a memmove: the two may overlap
	entry := 0
	for contact in tail {
		a, b := overlap_of(world, contact.shape_id_a), overlap_of(world, contact.shape_id_b)
		for manifold in contact.manifolds[:contact.manifold_count] {
			out[entry] = {a, b, manifold}
			entry += 1
		}
	}
	resize(out, manifolds)
	sort_contacts(out[:])
}

// ---- events

// The joints whose force or torque passed their threshold in the last step, into `out` (replaced), in Box3D's order
// (joint_as gives a typed ref).
world_joint_events :: proc(world: ^World, out: ^[dynamic]Joint_Ref) {
	clear(out)
	for event in b3.world_get_joint_events(world.id) {
		append(out, joint_ref_of(event.joint_id))
	}
}

// The bodies that moved in the last step, into `out` (replaced), in Box3D's order: every awake dynamic or kinematic
// body, `fell_asleep` on the step it fell asleep.
world_body_events :: proc(world: ^World, out: ^[dynamic]Body_Move_Event) {
	clear(out)
	for event in b3.world_get_body_events(world.id) {
		append(out, Body_Move_Event {
			body        = link_of(event.body_id),
			tag         = tag_of(world, event.body_id.index1),
			transform   = event.transform,
			fell_asleep = event.fell_asleep,
		})
	}
}

// ---- deterministic order (insertion sorts, stable: equal keys keep Box3D's order)

@(private)
sort_mover_planes :: proc(items: []Mover_Plane) {
	for i in 1 ..< len(items) {
		held := items[i]
		j := i
		for j > 0 && plane_before(held, items[j - 1]) {
			items[j] = items[j - 1]
			j -= 1
		}
		items[j] = held
	}
}

@(private)
plane_before :: proc(a, b: Mover_Plane) -> bool {
	if a.body.index1 != b.body.index1 do return a.body.index1 < b.body.index1
	return a.shape.index1 < b.shape.index1
}

@(private)
sort_contacts :: proc(items: []Contact_Data) {
	for i in 1 ..< len(items) {
		held := items[i]
		j := i
		for j > 0 && contact_before(held, items[j - 1]) {
			items[j] = items[j - 1]
			j -= 1
		}
		items[j] = held
	}
}

@(private)
contact_before :: proc(a, b: Contact_Data) -> bool {
	if a.a.body.index1 != b.a.body.index1 do return a.a.body.index1 < b.a.body.index1
	if a.a.shape.index1 != b.a.shape.index1 do return a.a.shape.index1 < b.a.shape.index1
	if a.b.body.index1 != b.b.body.index1 do return a.b.body.index1 < b.b.body.index1
	return a.b.shape.index1 < b.b.shape.index1
}
