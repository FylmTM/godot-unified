// Box3D's value types and definitions as games use them (src/physics/SPEC.md, The boundary): b3's mirrors, by alias,
// so a game imports unified:physics alone. Creation takes refs as arguments and fills a def's ids itself.
package physics

import "unified:b3"

Body_Type :: b3.Body_Type
Body_Def :: b3.Body_Def
Shape_Def :: b3.Shape_Def
Surface_Material :: b3.Surface_Material
Filter :: b3.Filter
Motion_Locks :: b3.Motion_Locks
Transform :: b3.Transform
AABB :: b3.AABB
Sphere :: b3.Sphere
Capsule :: b3.Capsule
Hull_Data :: b3.Hull_Data
Box_Hull :: b3.Box_Hull // `&box.base` is the hull
Shape_Proxy :: b3.Shape_Proxy
Joint_Def :: b3.Joint_Def
Motor_Joint_Def :: b3.Motor_Joint_Def
Mover_Joint_Def :: b3.Mover_Joint_Def
Pogo_Joint_Def :: b3.Pogo_Joint_Def

MAX_SHAPE_CAST_POINTS :: b3.MAX_SHAPE_CAST_POINTS

default_body_def :: b3.default_body_def
default_shape_def :: b3.default_shape_def
default_motor_joint_def :: b3.default_motor_joint_def
default_mover_joint_def :: b3.default_mover_joint_def
default_pogo_joint_def :: b3.default_pogo_joint_def

// A proxy for shape overlaps and casts: a convex point cloud (at most MAX_SHAPE_CAST_POINTS, the caller's memory)
// with a radius. One point with a radius is a sphere, two a capsule.
make_proxy :: proc(points: [][3]f32, radius: f32) -> Shape_Proxy {
	assert(len(points) >= 1 && len(points) <= MAX_SHAPE_CAST_POINTS)
	return {points = raw_data(points), count = i32(len(points)), radius = radius}
}
