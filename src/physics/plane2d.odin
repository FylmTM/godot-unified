// 2D physics: Box3D bodies locked to the plane z = 0 (src/physics/SPEC.md, "2D"). The plane uses
// Godot's 2D axes (x right, y down, z into the screen); a 2D rotation is a unit vector (cos a, sin a)
// about +Z, so nothing here needs trig.
package physics

import box3d "box3d:bindings"
import "unified:dmath"

// The most points create_polygon_shape_2d takes (its prism stays well inside Box3D's hull limits).
POLYGON_2D_MAX :: 32

// A body definition locked to the plane: z = 0, no linear z motion, rotation only about Z.
// `rot` is any non-zero direction (normalised here); zero means no rotation.
body_def_2d :: proc(type: Body_Type, pos: [2]f32, rot := [2]f32{1, 0}) -> Body_Def {
	body_def := transmute(Body_Def)box3d.DefaultBodyDef()
	body_def.type = type
	body_def.position = {pos.x, pos.y, 0}
	body_def.rotation = quat_2d(rot)
	body_def.motion_locks = {
		linear_z  = true,
		angular_x = true,
		angular_y = true,
	}
	return body_def
}

// The quaternion (x, y, z, w) of a 2D rotation: about +Z by the angle of `rot` (any non-zero
// direction; zero: identity), w ≥ 0. Half angle without trig: w = √((1 + c)/2), z = s/(2w), or from
// z = ±√((1 − c)/2) when c < 0, so neither divides by a small number.
quat_2d :: proc "contextless" (rot: [2]f32) -> [4]f32 {
	length := dmath.sqrt(rot.x * rot.x + rot.y * rot.y)
	if length == 0 do return {0, 0, 0, 1}
	cos_a := rot.x / length
	sin_a := rot.y / length
	if cos_a >= 0 {
		w := dmath.sqrt((1 + cos_a) * 0.5)
		return {0, 0, sin_a / (2 * w), w}
	}
	z := dmath.sqrt((1 - cos_a) * 0.5)
	if sin_a < 0 do z = -z
	return {0, 0, z, sin_a / (2 * z)}
}

// The 2D rotation (cos a, sin a) of a rotation about Z: (w² − z², 2wz). x and y are ignored (zero
// for a plane-locked body).
rot_2d :: proc "contextless" (quat: [4]f32) -> [2]f32 {
	return {quat.w * quat.w - quat.z * quat.z, 2 * quat.w * quat.z}
}

// A plane-locked body's position in the plane.
body_position_2d :: proc(world: ^World, ref: Body_Ref) -> [2]f32 {
	position := transmute([3]f32)box3d.Body_GetPosition(body_id(world, ref))
	return {position.x, position.y}
}

// A plane-locked body's rotation as a unit vector (cos a, sin a) about +Z.
body_rotation_2d :: proc(world: ^World, ref: Body_Ref) -> [2]f32 {
	return rot_2d(transmute([4]f32)box3d.Body_GetRotation(body_id(world, ref)))
}

// Moves a plane-locked body (teleports it); `rot` as body_def_2d's. Its velocities are kept.
body_set_transform_2d :: proc(world: ^World, ref: Body_Ref, pos: [2]f32, rot := [2]f32{1, 0}) {
	box3d.Body_SetTransform(
		body_id(world, ref),
		transmute(box3d.Vec3)[3]f32{pos.x, pos.y, 0},
		transmute(box3d.Quat)quat_2d(rot),
	)
}

// A plane-locked body's linear velocity in the plane (m/s).
body_linear_velocity_2d :: proc(world: ^World, ref: Body_Ref) -> [2]f32 {
	velocity := transmute([3]f32)box3d.Body_GetLinearVelocity(body_id(world, ref))
	return {velocity.x, velocity.y}
}

// A plane-locked body's angular velocity about +Z (rad/s, positive turns +x toward +y).
body_angular_velocity_2d :: proc(world: ^World, ref: Body_Ref) -> f32 {
	return box3d.Body_GetAngularVelocity(body_id(world, ref)).z
}

// Sets a plane-locked body's linear velocity in the plane.
body_set_linear_velocity_2d :: proc(world: ^World, ref: Body_Ref, velocity: [2]f32) {
	box3d.Body_SetLinearVelocity(body_id(world, ref), transmute(box3d.Vec3)[3]f32{velocity.x, velocity.y, 0})
}

// Sets a plane-locked body's angular velocity about +Z.
body_set_angular_velocity_2d :: proc(world: ^World, ref: Body_Ref, velocity: f32) {
	box3d.Body_SetAngularVelocity(body_id(world, ref), transmute(box3d.Vec3)[3]f32{0, 0, velocity})
}

// Adds a force (N) in the plane at a point of the plane for the next step.
body_apply_force_2d :: proc(world: ^World, ref: Body_Ref, force: [2]f32, point: [2]f32, wake := true) {
	box3d.Body_ApplyForce(
		body_id(world, ref),
		transmute(box3d.Vec3)[3]f32{force.x, force.y, 0},
		transmute(box3d.Vec3)[3]f32{point.x, point.y, 0},
		wake,
	)
}

// Adds a force (N) in the plane at the centre of mass for the next step.
body_apply_force_to_center_2d :: proc(world: ^World, ref: Body_Ref, force: [2]f32, wake := true) {
	box3d.Body_ApplyForceToCenter(body_id(world, ref), transmute(box3d.Vec3)[3]f32{force.x, force.y, 0}, wake)
}

// Adds a torque (N·m) about +Z for the next step.
body_apply_torque_2d :: proc(world: ^World, ref: Body_Ref, torque: f32, wake := true) {
	box3d.Body_ApplyTorque(body_id(world, ref), transmute(box3d.Vec3)[3]f32{0, 0, torque}, wake)
}

// Adds an impulse (N·s) in the plane at a point of the plane.
body_apply_linear_impulse_2d :: proc(world: ^World, ref: Body_Ref, impulse: [2]f32, point: [2]f32, wake := true) {
	box3d.Body_ApplyLinearImpulse(
		body_id(world, ref),
		transmute(box3d.Vec3)[3]f32{impulse.x, impulse.y, 0},
		transmute(box3d.Vec3)[3]f32{point.x, point.y, 0},
		wake,
	)
}

// Adds an impulse (N·s) in the plane at the centre of mass. A force F over one tick is F · dt.
body_apply_linear_impulse_to_center_2d :: proc(world: ^World, ref: Body_Ref, impulse: [2]f32, wake := true) {
	box3d.Body_ApplyLinearImpulseToCenter(
		body_id(world, ref),
		transmute(box3d.Vec3)[3]f32{impulse.x, impulse.y, 0},
		wake,
	)
}

// Adds an angular impulse (N·m·s) about +Z.
body_apply_angular_impulse_2d :: proc(world: ^World, ref: Body_Ref, impulse: f32, wake := true) {
	box3d.Body_ApplyAngularImpulse(body_id(world, ref), transmute(box3d.Vec3)[3]f32{0, 0, impulse}, wake)
}

// A plane-locked body (body_def_2d) with one circle of `radius` at its origin.
create_circle_2d :: proc(
	world: ^World,
	body: Body_Def,
	shape: Shape_Def,
	radius: f32,
	tag: u64 = 0,
	loc := #caller_location,
) -> (
	Body_Ref,
	Shape_Ref,
) {
	ref := create_body(world, body, tag, loc)
	return ref, create_circle_shape_2d(world, ref, shape, radius, loc = loc)
}

// A plane-locked body with one box centred on it, `depth` thick along z.
create_box_2d :: proc(
	world: ^World,
	body: Body_Def,
	shape: Shape_Def,
	half: [2]f32,
	depth: f32,
	tag: u64 = 0,
	loc := #caller_location,
) -> (
	Body_Ref,
	Shape_Ref,
) {
	ref := create_body(world, body, tag, loc)
	return ref, create_box_shape_2d(world, ref, shape, half, depth, loc)
}

// A plane-locked body with one convex polygon (create_polygon_shape_2d). Not ok: the polygon can't be built, and no
// body was made.
create_polygon_2d :: proc(
	world: ^World,
	body: Body_Def,
	shape: Shape_Def,
	points: [][2]f32,
	depth: f32,
	tag: u64 = 0,
	loc := #caller_location,
) -> (
	ref: Body_Ref,
	shape_ref: Shape_Ref,
	ok: bool,
) {
	ref = create_body(world, body, tag, loc)
	shape_ref, ok = create_polygon_shape_2d(world, ref, shape, points, depth, loc)
	if !ok do destroy_body(world, &ref)
	return
}

// A circle: a sphere centred in the plane.
create_circle_shape_2d :: proc(
	world: ^World,
	ref: Body_Ref,
	def: Shape_Def,
	radius: f32,
	center := [2]f32{},
	loc := #caller_location,
) -> Shape_Ref {
	return create_sphere_shape(world, ref, def, {{center.x, center.y, 0}, radius}, loc)
}

// A box centred on the body, `depth` thick along z (centred on the plane).
create_box_shape_2d :: proc(
	world: ^World,
	ref: Body_Ref,
	def: Shape_Def,
	half: [2]f32,
	depth: f32,
	loc := #caller_location,
) -> Shape_Ref {
	hull := box3d.MakeBoxHull(half.x, half.y, depth * 0.5)
	return create_hull_shape(world, ref, def, &hull.base, loc)
}

// The convex hull of `points` (body-local, any order; 3 to POLYGON_2D_MAX) extruded to `depth`, centred on the plane.
// Not ok: too few or too many points, or a degenerate hull (collinear points).
create_polygon_shape_2d :: proc(
	world: ^World,
	ref: Body_Ref,
	def: Shape_Def,
	points: [][2]f32,
	depth: f32,
	loc := #caller_location,
) -> (
	Shape_Ref,
	bool,
) {
	if len(points) < 3 || len(points) > POLYGON_2D_MAX do return {}, false
	half_depth := depth * 0.5
	hull_points: [2 * POLYGON_2D_MAX][3]f32
	for point, i in points {
		hull_points[2 * i] = {point.x, point.y, -half_depth}
		hull_points[2 * i + 1] = {point.x, point.y, half_depth}
	}
	hull := box3d.CreateHull(
		([^]box3d.Vec3)(raw_data(hull_points[:2 * len(points)])),
		i32(len(hull_points[:2 * len(points)])),
		2 * POLYGON_2D_MAX,
	)
	if hull == nil do return {}, false
	defer box3d.DestroyHull(hull)
	return create_hull_shape(world, ref, def, hull, loc), true
}
