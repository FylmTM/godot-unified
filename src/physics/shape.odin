// Shapes (src/physics/SPEC.md, What physics covers): created on a Body_Ref, referred to by a Shape_Ref; Box3D's shape
// procs named by its names without `get_`. A shape is destroyed with its body.
package physics

import "base:runtime"

import "unified:b3"

// Adds a sphere to a body. The def's user_data and name stay unset (pointers).
create_sphere_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	def: ^Shape_Def,
	sphere: Sphere,
	loc := #caller_location,
) -> Shape_Ref {
	check_shape_def(def, loc)
	sphere := sphere
	return shape_ref_of(b3.create_sphere_shape(body_id(world, ref), def, &sphere))
}

// Adds a capsule (two centres and a radius, body-local) to a body.
create_capsule_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	def: ^Shape_Def,
	capsule: Capsule,
	loc := #caller_location,
) -> Shape_Ref {
	check_shape_def(def, loc)
	capsule := capsule
	return shape_ref_of(b3.create_capsule_shape(body_id(world, ref), def, &capsule))
}

// Adds a convex hull to a body (Box3D copies it into its geometry database: the caller keeps or frees its own).
create_hull_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	def: ^Shape_Def,
	hull: ^Hull_Data,
	loc := #caller_location,
) -> Shape_Ref {
	check_shape_def(def, loc)
	return shape_ref_of(b3.create_hull_shape(body_id(world, ref), def, hull))
}

// The body a shape belongs to.
shape_body :: proc(world: ^World, shape: Shape_Ref) -> Body_Ref {
	return ref_of(b3.shape_get_body(shape_id(world, shape)))
}

// Whether the shape is a sensor.
shape_is_sensor :: proc(world: ^World, shape: Shape_Ref) -> bool {
	return b3.shape_is_sensor(shape_id(world, shape))
}

// The shape's collision filter (category and mask bits).
shape_filter :: proc(world: ^World, shape: Shape_Ref) -> Filter {
	return b3.shape_get_filter(shape_id(world, shape))
}

@(private)
check_shape_def :: proc(def: ^Shape_Def, loc: runtime.Source_Code_Location) {
	assert(def.user_data == nil && def.name == nil, "physics: a shape def's user_data and name stay unset", loc)
}
