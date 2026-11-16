// 2D physics: Box3D bodies locked to the plane z = 0 (src/physics/SPEC.md, "2D"). The plane uses
// Godot's 2D axes (x right, y down, z into the screen); a 2D rotation is a unit vector (cos a, sin a)
// about +Z, so nothing here needs trig.
package physics

import "unified:b3"
import "unified:dmath"

// The most points create_polygon_shape_2d takes (its prism stays well inside Box3D's hull limits).
POLYGON_2D_MAX :: 32

// A body definition locked to the plane: z = 0, no linear z motion, rotation only about Z.
// `rot` is any non-zero direction (normalised here); zero means no rotation.
body_def_2d :: proc(type: Body_Type, pos: [2]f32, rot := [2]f32{1, 0}) -> Body_Def {
	body_def := b3.default_body_def()
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
	position := b3.body_get_position(body_id(world, ref))
	return {position.x, position.y}
}

// A plane-locked body's rotation as a unit vector (cos a, sin a) about +Z.
body_rotation_2d :: proc(world: ^World, ref: Body_Ref) -> [2]f32 {
	return rot_2d(b3.body_get_rotation(body_id(world, ref)))
}

// Moves a plane-locked body (teleports it); `rot` as body_def_2d's. Its velocities are kept.
body_set_transform_2d :: proc(world: ^World, ref: Body_Ref, pos: [2]f32, rot := [2]f32{1, 0}) {
	b3.body_set_transform(body_id(world, ref), {pos.x, pos.y, 0}, quat_2d(rot))
}

// A plane-locked body's linear velocity in the plane (m/s).
body_linear_velocity_2d :: proc(world: ^World, ref: Body_Ref) -> [2]f32 {
	velocity := b3.body_get_linear_velocity(body_id(world, ref))
	return {velocity.x, velocity.y}
}

// A plane-locked body's angular velocity about +Z (rad/s, positive turns +x toward +y).
body_angular_velocity_2d :: proc(world: ^World, ref: Body_Ref) -> f32 {
	return b3.body_get_angular_velocity(body_id(world, ref)).z
}

// Sets a plane-locked body's linear velocity in the plane.
body_set_linear_velocity_2d :: proc(world: ^World, ref: Body_Ref, velocity: [2]f32) {
	b3.body_set_linear_velocity(body_id(world, ref), {velocity.x, velocity.y, 0})
}

// Sets a plane-locked body's angular velocity about +Z.
body_set_angular_velocity_2d :: proc(world: ^World, ref: Body_Ref, velocity: f32) {
	b3.body_set_angular_velocity(body_id(world, ref), {0, 0, velocity})
}

// Adds a force (N) in the plane at a point of the plane for the next step.
body_apply_force_2d :: proc(world: ^World, ref: Body_Ref, force: [2]f32, point: [2]f32, wake := true) {
	b3.body_apply_force(body_id(world, ref), {force.x, force.y, 0}, {point.x, point.y, 0}, wake)
}

// Adds a force (N) in the plane at the centre of mass for the next step.
body_apply_force_to_center_2d :: proc(world: ^World, ref: Body_Ref, force: [2]f32, wake := true) {
	b3.body_apply_force_to_center(body_id(world, ref), {force.x, force.y, 0}, wake)
}

// Adds a torque (N·m) about +Z for the next step.
body_apply_torque_2d :: proc(world: ^World, ref: Body_Ref, torque: f32, wake := true) {
	b3.body_apply_torque(body_id(world, ref), {0, 0, torque}, wake)
}

// Adds an impulse (N·s) in the plane at a point of the plane.
body_apply_linear_impulse_2d :: proc(world: ^World, ref: Body_Ref, impulse: [2]f32, point: [2]f32, wake := true) {
	b3.body_apply_linear_impulse(body_id(world, ref), {impulse.x, impulse.y, 0}, {point.x, point.y, 0}, wake)
}

// Adds an impulse (N·s) in the plane at the centre of mass. A force F over one tick is F · dt.
body_apply_linear_impulse_to_center_2d :: proc(world: ^World, ref: Body_Ref, impulse: [2]f32, wake := true) {
	b3.body_apply_linear_impulse_to_center(body_id(world, ref), {impulse.x, impulse.y, 0}, wake)
}

// Adds an angular impulse (N·m·s) about +Z.
body_apply_angular_impulse_2d :: proc(world: ^World, ref: Body_Ref, impulse: f32, wake := true) {
	b3.body_apply_angular_impulse(body_id(world, ref), {0, 0, impulse}, wake)
}

// A circle: a sphere centred in the plane.
create_circle_shape_2d :: proc(
	world: ^World,
	ref: Body_Ref,
	def: ^Shape_Def,
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
	def: ^Shape_Def,
	half: [2]f32,
	depth: f32,
	loc := #caller_location,
) -> Shape_Ref {
	hull := b3.make_box_hull(half.x, half.y, depth * 0.5)
	return create_hull_shape(world, ref, def, &hull.base, loc)
}

// The convex hull of `points` (body-local, any order; 3 to POLYGON_2D_MAX) extruded to `depth`, centred on the plane.
// Not ok: too few or too many points, or a degenerate hull (collinear points).
create_polygon_shape_2d :: proc(
	world: ^World,
	ref: Body_Ref,
	def: ^Shape_Def,
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
	hull := b3.create_hull(hull_points[:2 * len(points)], 2 * POLYGON_2D_MAX)
	if hull == nil do return {}, false
	defer b3.destroy_hull(hull)
	return create_hull_shape(world, ref, def, hull, loc), true
}
