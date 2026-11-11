// 2D physics: Box3D bodies locked to the plane z = 0 (src/physics/SPEC.md, "2D"). The plane uses
// Godot's 2D axes (x right, y down, z into the screen); a 2D rotation is a unit vector (cos a, sin a)
// about +Z, so nothing here needs trig.
package physics

import "unified:b3"
import "unified:dmath"

// The most points polygon_2d takes (its prism stays well inside Box3D's hull limits).
POLYGON_2D_MAX :: 32

// A body definition locked to the plane: z = 0, no linear z motion, rotation only about Z.
// `rot` is any non-zero direction (normalised here); zero means no rotation.
body_def_2d :: proc(type: b3.Body_Type, pos: [2]f32, rot := [2]f32{1, 0}) -> b3.Body_Def {
	bd := b3.default_body_def()
	bd.type = type
	bd.position = {pos.x, pos.y, 0}
	bd.rotation = quat_2d(rot)
	bd.motion_locks = {
		linear_z  = true,
		angular_x = true,
		angular_y = true,
	}
	return bd
}

// The quaternion (x, y, z, w) of a 2D rotation: about +Z by the angle of `rot` (any non-zero
// direction; zero: identity), w ≥ 0. Half angle without trig: w = √((1 + c)/2), z = s/(2w), or from
// z = ±√((1 − c)/2) when c < 0, so neither divides by a small number.
quat_2d :: proc "contextless" (rot: [2]f32) -> [4]f32 {
	n := dmath.sqrt(rot.x * rot.x + rot.y * rot.y)
	if n == 0 do return {0, 0, 0, 1}
	c := rot.x / n
	s := rot.y / n
	if c >= 0 {
		w := dmath.sqrt((1 + c) * 0.5)
		return {0, 0, s / (2 * w), w}
	}
	z := dmath.sqrt((1 - c) * 0.5)
	if s < 0 do z = -z
	return {0, 0, z, s / (2 * z)}
}

// The 2D rotation (cos a, sin a) of a rotation about Z: (w² − z², 2wz). x and y are ignored (zero
// for a plane-locked body).
rot_2d :: proc "contextless" (q: [4]f32) -> [2]f32 {
	return {q.w * q.w - q.z * q.z, 2 * q.w * q.z}
}

// A plane-locked body's position and 2D rotation.
pose_2d :: proc(w: ^World, r: Body_Ref) -> (pos: [2]f32, rot: [2]f32) {
	id := body_id(w, r)
	p := b3.body_get_position(id)
	q := b3.body_get_rotation(id)
	return {p.x, p.y}, rot_2d(q)
}

// Linear velocity in the plane and angular velocity about +Z (rad/s, positive turns +x toward +y).
velocity_2d :: proc(w: ^World, r: Body_Ref) -> (linear: [2]f32, angular: f32) {
	id := body_id(w, r)
	v := b3.body_get_linear_velocity(id)
	a := b3.body_get_angular_velocity(id)
	return {v.x, v.y}, a.z
}

set_velocity_2d :: proc(w: ^World, r: Body_Ref, linear: [2]f32, angular: f32) {
	id := body_id(w, r)
	b3.body_set_linear_velocity(id, {linear.x, linear.y, 0})
	b3.body_set_angular_velocity(id, {0, 0, angular})
}

// An impulse (N·s) at the centre of mass, waking the body. A force F over one tick is F · dt.
apply_impulse_2d :: proc(w: ^World, r: Body_Ref, j: [2]f32) {
	b3.body_apply_linear_impulse_to_center(body_id(w, r), {j.x, j.y, 0}, true)
}

// A circle: a sphere centred in the plane.
circle_2d :: proc(body: b3.Body_Id, sd: ^b3.Shape_Def, radius: f32, center := [2]f32{}) -> b3.Shape_Id {
	s := b3.Sphere{{center.x, center.y, 0}, radius}
	return b3.create_sphere_shape(body, sd, &s)
}

// A box centred on the body, `depth` thick along z (centred on the plane).
box_2d :: proc(body: b3.Body_Id, sd: ^b3.Shape_Def, half: [2]f32, depth: f32) -> b3.Shape_Id {
	h := b3.make_box_hull(half.x, half.y, depth * 0.5)
	return b3.create_hull_shape(body, sd, &h.base)
}

// The convex hull of `points` (body-local, any order; 3 to POLYGON_2D_MAX) extruded to `depth`,
// centred on the plane. Not ok: too few or too many points, or a degenerate hull (collinear points).
polygon_2d :: proc(body: b3.Body_Id, sd: ^b3.Shape_Def, points: [][2]f32, depth: f32) -> (b3.Shape_Id, bool) {
	if len(points) < 3 || len(points) > POLYGON_2D_MAX do return {}, false
	h := depth * 0.5
	pts: [2 * POLYGON_2D_MAX][3]f32
	for p, i in points {
		pts[2 * i] = {p.x, p.y, -h}
		pts[2 * i + 1] = {p.x, p.y, h}
	}
	hull := b3.create_hull(pts[:2 * len(points)], 2 * POLYGON_2D_MAX)
	if hull == nil do return {}, false
	defer b3.destroy_hull(hull)
	return b3.create_hull_shape(body, sd, hull), true
}
