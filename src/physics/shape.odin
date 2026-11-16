// Shapes (src/physics/SPEC.md, What physics covers): created on a Body_Ref, referred to by a Shape_Ref; Box3D's shape
// procs named by its names without `get_`. A shape is destroyed with its body (or by destroy_shape).
package physics

import "base:runtime"

import "unified:b3"

Shape_Type :: b3.Shape_Type

// ---- creation

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

// Adds a hull moved by `transform` (body-local) and scaled to a body (Box3D copies the result).
create_transformed_hull_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	def: ^Shape_Def,
	hull: ^Hull_Data,
	transform: Transform,
	scale := [3]f32{1, 1, 1},
	loc := #caller_location,
) -> Shape_Ref {
	check_shape_def(def, loc)
	return shape_ref_of(b3.create_transformed_hull_shape(body_id(world, ref), def, hull, transform, scale))
}

// Adds a triangle mesh, scaled, to a body (one material per mesh material index, from the def's `materials`). Unlike
// a hull, the mesh is kept by pointer: it must live as long as the world (keep it in the game's World).
create_mesh_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	def: ^Shape_Def,
	mesh: ^Mesh_Data,
	scale := [3]f32{1, 1, 1},
	loc := #caller_location,
) -> Shape_Ref {
	check_shape_def(def, loc)
	return shape_ref_of(b3.create_mesh_shape(body_id(world, ref), def, mesh, scale))
}

// Adds a height field to a static body. Kept by pointer: it must live as long as the world.
create_height_field_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	def: ^Shape_Def,
	height_field: ^Height_Field_Data,
	loc := #caller_location,
) -> Shape_Ref {
	check_shape_def(def, loc)
	return shape_ref_of(b3.create_height_field_shape(body_id(world, ref), def, height_field))
}

// Adds a baked compound to a static body. Kept by pointer (and the compound keeps its meshes'): they must live as
// long as the world.
create_baked_compound_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	def: ^Shape_Def,
	compound: ^Compound_Data,
	loc := #caller_location,
) -> Shape_Ref {
	check_shape_def(def, loc)
	return shape_ref_of(b3.create_baked_compound_shape(body_id(world, ref), def, compound))
}

// Destroys the shape (if it is still alive: destroying a body destroys its shapes) and clears the ref;
// `update_body_mass` recomputes its body's mass.
destroy_shape :: proc(world: ^World, shape: ^Shape_Ref, update_body_mass := true) {
	if shape_valid(world, shape^) {
		b3.destroy_shape(shape_id(world, shape^), update_body_mass)
	}
	shape^ = {}
}

// ---- what a shape is

// Sphere, capsule, hull, mesh, height field or compound.
shape_type :: proc(world: ^World, shape: Shape_Ref) -> Shape_Type {
	return b3.shape_get_type(shape_id(world, shape))
}

// The body a shape belongs to (a link: a shape in a result may be anyone's; resolve it to use it).
shape_body :: proc(world: ^World, shape: Shape_Ref) -> Body_Link {
	return link_of(b3.shape_get_body(shape_id(world, shape)))
}

// Whether the shape is a sensor.
shape_is_sensor :: proc(world: ^World, shape: Shape_Ref) -> bool {
	return b3.shape_is_sensor(shape_id(world, shape))
}

// The shape's sphere (body-local).
shape_sphere :: proc(world: ^World, shape: Shape_Ref) -> Sphere {
	return b3.shape_get_sphere(shape_id(world, shape))
}

// The shape's capsule (body-local).
shape_capsule :: proc(world: ^World, shape: Shape_Ref) -> Capsule {
	return b3.shape_get_capsule(shape_id(world, shape))
}

// The shape's hull: Box3D's copy (host memory, read only, valid while the world lives).
shape_hull :: proc(world: ^World, shape: Shape_Ref) -> ^Hull_Data {
	return b3.shape_get_hull(shape_id(world, shape))
}

// The shape's mesh (the one it was made with, or a loaded image's copy; read only) and its scale.
shape_mesh :: proc(world: ^World, shape: Shape_Ref) -> Mesh {
	return b3.shape_get_mesh(shape_id(world, shape))
}

// The shape's height field (the one it was made with, or a loaded image's copy; read only).
shape_height_field :: proc(world: ^World, shape: Shape_Ref) -> ^Height_Field_Data {
	return b3.shape_get_height_field(shape_id(world, shape))
}

// The shape's baked compound (the one it was made with, or a loaded image's copy; read only).
shape_compound :: proc(world: ^World, shape: Shape_Ref) -> ^Compound_Data {
	return b3.shape_get_compound(shape_id(world, shape))
}

// Makes the shape a sphere (body-local).
shape_set_sphere :: proc(world: ^World, shape: Shape_Ref, sphere: Sphere) {
	sphere := sphere
	b3.shape_set_sphere(shape_id(world, shape), &sphere)
}

// Makes the shape a capsule (body-local).
shape_set_capsule :: proc(world: ^World, shape: Shape_Ref, capsule: Capsule) {
	capsule := capsule
	b3.shape_set_capsule(shape_id(world, shape), &capsule)
}

// Makes the shape a hull (Box3D copies it).
shape_set_hull :: proc(world: ^World, shape: Shape_Ref, hull: ^Hull_Data) {
	b3.shape_set_hull(shape_id(world, shape), hull)
}

// Makes the shape a scaled mesh (kept by pointer: it must live as long as the world).
shape_set_mesh :: proc(world: ^World, shape: Shape_Ref, mesh: ^Mesh_Data, scale := [3]f32{1, 1, 1}) {
	b3.shape_set_mesh(shape_id(world, shape), mesh, scale)
}

// The shape's world AABB (tight), as of the last step or pose change.
shape_aabb :: proc(world: ^World, shape: Shape_Ref) -> AABB {
	return b3.shape_get_aabb(shape_id(world, shape))
}

// The shape's mass data at its density (body-local centre).
shape_compute_mass_data :: proc(world: ^World, shape: Shape_Ref) -> Mass_Data {
	return b3.shape_compute_mass_data(shape_id(world, shape))
}

// ---- material and mass

// Sets the density (kg/m³); `update_body_mass` recomputes the body's mass now.
shape_set_density :: proc(world: ^World, shape: Shape_Ref, density: f32, update_body_mass := true) {
	b3.shape_set_density(shape_id(world, shape), density, update_body_mass)
}

// The density.
shape_density :: proc(world: ^World, shape: Shape_Ref) -> f32 {
	return b3.shape_get_density(shape_id(world, shape))
}

// Sets the friction of the shape's base material.
shape_set_friction :: proc(world: ^World, shape: Shape_Ref, friction: f32) {
	b3.shape_set_friction(shape_id(world, shape), friction)
}

// The base material's friction.
shape_friction :: proc(world: ^World, shape: Shape_Ref) -> f32 {
	return b3.shape_get_friction(shape_id(world, shape))
}

// Sets the restitution (bounciness) of the shape's base material.
shape_set_restitution :: proc(world: ^World, shape: Shape_Ref, restitution: f32) {
	b3.shape_set_restitution(shape_id(world, shape), restitution)
}

// The base material's restitution.
shape_restitution :: proc(world: ^World, shape: Shape_Ref) -> f32 {
	return b3.shape_get_restitution(shape_id(world, shape))
}

// Sets the shape's base surface material (friction, restitution, rolling resistance, tangent velocity, user id).
shape_set_surface_material :: proc(world: ^World, shape: Shape_Ref, material: Surface_Material) {
	b3.shape_set_surface_material(shape_id(world, shape), material)
}

// The shape's base surface material.
shape_surface_material :: proc(world: ^World, shape: Shape_Ref) -> Surface_Material {
	return b3.shape_get_surface_material(shape_id(world, shape))
}

// How many materials a mesh or height field shape has (1 for convex shapes).
shape_mesh_material_count :: proc(world: ^World, shape: Shape_Ref) -> int {
	return int(b3.shape_get_mesh_material_count(shape_id(world, shape)))
}

// Sets one of a mesh or height field shape's materials (index < shape_mesh_material_count).
shape_set_mesh_material :: proc(world: ^World, shape: Shape_Ref, material: Surface_Material, index: int) {
	b3.shape_set_mesh_material(shape_id(world, shape), material, i32(index))
}

// One of a mesh or height field shape's materials.
shape_mesh_surface_material :: proc(world: ^World, shape: Shape_Ref, index: int) -> Surface_Material {
	return b3.shape_get_mesh_surface_material(shape_id(world, shape), i32(index))
}

// ---- filtering and events

// The shape's collision filter (category and mask bits).
shape_filter :: proc(world: ^World, shape: Shape_Ref) -> Filter {
	return b3.shape_get_filter(shape_id(world, shape))
}

// Sets the collision filter; `invoke_contacts` re-checks the shape's contacts now (else at the next step).
shape_set_filter :: proc(world: ^World, shape: Shape_Ref, filter: Filter, invoke_contacts := true) {
	b3.shape_set_filter(shape_id(world, shape), filter, invoke_contacts)
}

// Turns sensor events on or off for this shape as a visitor.
shape_enable_sensor_events :: proc(world: ^World, shape: Shape_Ref, flag: bool) {
	b3.shape_enable_sensor_events(shape_id(world, shape), flag)
}

// Whether the shape makes sensor events.
shape_are_sensor_events_enabled :: proc(world: ^World, shape: Shape_Ref) -> bool {
	return b3.shape_are_sensor_events_enabled(shape_id(world, shape))
}

// Turns contact begin and end events on or off.
shape_enable_contact_events :: proc(world: ^World, shape: Shape_Ref, flag: bool) {
	b3.shape_enable_contact_events(shape_id(world, shape), flag)
}

// Whether the shape makes contact events.
shape_are_contact_events_enabled :: proc(world: ^World, shape: Shape_Ref) -> bool {
	return b3.shape_are_contact_events_enabled(shape_id(world, shape))
}

// Turns hit events on or off.
shape_enable_hit_events :: proc(world: ^World, shape: Shape_Ref, flag: bool) {
	b3.shape_enable_hit_events(shape_id(world, shape), flag)
}

// Whether the shape makes hit events.
shape_are_hit_events_enabled :: proc(world: ^World, shape: Shape_Ref) -> bool {
	return b3.shape_are_hit_events_enabled(shape_id(world, shape))
}

// ---- forces

// Applies wind drag and lift to a sphere, capsule or hull of a dynamic body (`wind` the air's velocity, m/s;
// `max_speed` caps the relative speed).
shape_apply_wind :: proc(world: ^World, shape: Shape_Ref, wind: [3]f32, drag, lift, max_speed: f32, wake := true) {
	b3.shape_apply_wind(shape_id(world, shape), wind, drag, lift, max_speed, wake)
}

@(private)
check_shape_def :: proc(def: ^Shape_Def, loc: runtime.Source_Code_Location) {
	assert(def.user_data == nil, "physics: a shape def's user_data stays unset (a pointer in rollback state)", loc)
}

// Names the shape (copied into the world: rollback state; for debugging and tools).
shape_set_name :: proc(world: ^World, shape: Shape_Ref, name: cstring) {
	b3.shape_set_name(shape_id(world, shape), name)
}

// The shape's name ("" when unnamed; valid while the shape lives).
shape_name :: proc(world: ^World, shape: Shape_Ref) -> cstring {
	return b3.shape_get_name(shape_id(world, shape))
}
