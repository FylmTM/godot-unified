// Shapes (src/physics/SPEC.md, What physics covers): created on a Body_Ref, referred to by a Shape_Ref; Box3D's shape
// procs named by its names without `get_`. A shape is destroyed with its body (or by destroy_shape).
package physics

import "base:runtime"

import box3d "box3d:bindings"


// ---- creation

// A shape definition: Box3D's default with its collision category and mask (every category by default). Set any other
// field (density, material, events, sensor) before creating the shape.
shape_def :: proc(category: u64, mask: u64 = max(u64)) -> Shape_Def {
	def := default_shape_def()
	def.filter.category = category
	def.filter.mask = mask
	return def
}

// A body with one box of half extents `half` (create_body, then create_box_shape): what a game makes most.
create_box :: proc(
	world: ^World,
	body: Body_Def,
	shape: Shape_Def,
	half: [3]f32,
	tag: u64 = 0,
	loc := #caller_location,
) -> (
	Body_Ref,
	Shape_Ref,
) {
	ref := create_body(world, body, tag, loc)
	return ref, create_box_shape(world, ref, shape, half, loc)
}

// A body with one sphere of `radius` at its origin.
create_sphere :: proc(
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
	return ref, create_sphere_shape(world, ref, shape, {{}, radius}, loc)
}

// A body with one capsule (body-local).
create_capsule :: proc(
	world: ^World,
	body: Body_Def,
	shape: Shape_Def,
	capsule: Capsule,
	tag: u64 = 0,
	loc := #caller_location,
) -> (
	Body_Ref,
	Shape_Ref,
) {
	ref := create_body(world, body, tag, loc)
	return ref, create_capsule_shape(world, ref, shape, capsule, loc)
}

// Adds a box of half extents `half`, centred on the body, to a body (make_box_hull, then create_hull_shape).
create_box_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	def: Shape_Def,
	half: [3]f32,
	loc := #caller_location,
) -> Shape_Ref {
	hull := make_box_hull(half)
	return create_hull_shape(world, ref, def, &hull.base, loc)
}

// Adds a sphere to a body. The def's user_data and name stay unset (pointers).
create_sphere_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	def: Shape_Def,
	sphere: Sphere,
	loc := #caller_location,
) -> Shape_Ref {
	def := def
	check_shape_def(def, loc)
	sphere := sphere
	return shape_ref_of(
		box3d.CreateSphereShape(body_id(world, ref), (^box3d.ShapeDef)(&def), (^box3d.Sphere)(&sphere)),
	)
}

// Adds a capsule (two centres and a radius, body-local) to a body.
create_capsule_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	def: Shape_Def,
	capsule: Capsule,
	loc := #caller_location,
) -> Shape_Ref {
	def := def
	check_shape_def(def, loc)
	capsule := capsule
	return shape_ref_of(
		box3d.CreateCapsuleShape(body_id(world, ref), (^box3d.ShapeDef)(&def), (^box3d.Capsule)(&capsule)),
	)
}

// Adds a convex hull to a body (Box3D copies it into its geometry database: the caller keeps or frees its own).
create_hull_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	def: Shape_Def,
	hull: ^Hull_Data,
	loc := #caller_location,
) -> Shape_Ref {
	def := def
	check_shape_def(def, loc)
	return shape_ref_of(box3d.CreateHullShape(body_id(world, ref), (^box3d.ShapeDef)(&def), hull))
}

// Adds a hull moved by `transform` (body-local) and scaled to a body (Box3D copies the result).
create_transformed_hull_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	def: Shape_Def,
	hull: ^Hull_Data,
	transform: Transform,
	scale := [3]f32{1, 1, 1},
	loc := #caller_location,
) -> Shape_Ref {
	def := def
	check_shape_def(def, loc)
	return shape_ref_of(
		box3d.CreateTransformedHullShape(
			body_id(world, ref),
			(^box3d.ShapeDef)(&def),
			hull,
			transmute(box3d.Transform)transform,
			transmute(box3d.Vec3)scale,
		),
	)
}

// Adds a triangle mesh, scaled, to a body (one material per mesh material index, from the def's `materials`). Unlike
// a hull, the mesh is kept by pointer: it must live as long as the world (keep it in the game's World).
create_mesh_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	def: Shape_Def,
	mesh: ^Mesh_Data,
	scale := [3]f32{1, 1, 1},
	loc := #caller_location,
) -> Shape_Ref {
	def := def
	check_shape_def(def, loc)
	return shape_ref_of(
		box3d.CreateMeshShape(body_id(world, ref), (^box3d.ShapeDef)(&def), mesh, transmute(box3d.Vec3)scale),
	)
}

// Adds a height field to a static body. Kept by pointer: it must live as long as the world.
create_height_field_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	def: Shape_Def,
	height_field: ^Height_Field_Data,
	loc := #caller_location,
) -> Shape_Ref {
	def := def
	check_shape_def(def, loc)
	return shape_ref_of(box3d.CreateHeightFieldShape(body_id(world, ref), (^box3d.ShapeDef)(&def), height_field))
}

// Adds a baked compound to a static body. Kept by pointer (and the compound keeps its meshes'): they must live as
// long as the world.
create_baked_compound_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	def: Shape_Def,
	compound: ^Compound_Data,
	loc := #caller_location,
) -> Shape_Ref {
	def := def
	check_shape_def(def, loc)
	return shape_ref_of(box3d.CreateBakedCompoundShape(body_id(world, ref), (^box3d.ShapeDef)(&def), compound))
}

// Destroys the shape (if it is still alive: destroying a body destroys its shapes) and clears the ref;
// `update_body_mass` recomputes its body's mass.
destroy_shape :: proc(world: ^World, shape: ^Shape_Ref, update_body_mass := true) {
	if shape_valid(world, shape^) {
		box3d.DestroyShape(shape_id(world, shape^), update_body_mass)
	}
	shape^ = {}
}

// ---- what a shape is

// Sphere, capsule, hull, mesh, height field or compound.
shape_type :: proc(world: ^World, shape: Shape_Ref) -> Shape_Type {
	return Shape_Type(box3d.Shape_GetType(shape_id(world, shape)))
}

// The body a shape belongs to (a link: a shape in a result may be anyone's; resolve it to use it).
shape_body :: proc(world: ^World, shape: Shape_Ref) -> Body_Link {
	return link_of(box3d.Shape_GetBody(shape_id(world, shape)))
}

// Whether the shape is a sensor.
shape_is_sensor :: proc(world: ^World, shape: Shape_Ref) -> bool {
	return box3d.Shape_IsSensor(shape_id(world, shape))
}

// The shape's sphere (body-local).
shape_sphere :: proc(world: ^World, shape: Shape_Ref) -> Sphere {
	return transmute(Sphere)box3d.Shape_GetSphere(shape_id(world, shape))
}

// The shape's capsule (body-local).
shape_capsule :: proc(world: ^World, shape: Shape_Ref) -> Capsule {
	return transmute(Capsule)box3d.Shape_GetCapsule(shape_id(world, shape))
}

// The shape's hull: Box3D's copy (host memory, read only, valid while the world lives).
shape_hull :: proc(world: ^World, shape: Shape_Ref) -> ^Hull_Data {
	return box3d.Shape_GetHull(shape_id(world, shape))
}

// The shape's mesh (the one it was made with, or a loaded image's copy; read only) and its scale.
shape_mesh :: proc(world: ^World, shape: Shape_Ref) -> Mesh {
	return transmute(Mesh)box3d.Shape_GetMesh(shape_id(world, shape))
}

// The shape's height field (the one it was made with, or a loaded image's copy; read only).
shape_height_field :: proc(world: ^World, shape: Shape_Ref) -> ^Height_Field_Data {
	return box3d.Shape_GetHeightField(shape_id(world, shape))
}

// The shape's baked compound (the one it was made with, or a loaded image's copy; read only).
shape_compound :: proc(world: ^World, shape: Shape_Ref) -> ^Compound_Data {
	return box3d.Shape_GetCompound(shape_id(world, shape))
}

// Makes the shape a sphere (body-local).
shape_set_sphere :: proc(world: ^World, shape: Shape_Ref, sphere: Sphere) {
	sphere := sphere
	box3d.Shape_SetSphere(shape_id(world, shape), (^box3d.Sphere)(&sphere))
}

// Makes the shape a capsule (body-local).
shape_set_capsule :: proc(world: ^World, shape: Shape_Ref, capsule: Capsule) {
	capsule := capsule
	box3d.Shape_SetCapsule(shape_id(world, shape), (^box3d.Capsule)(&capsule))
}

// Makes the shape a hull (Box3D copies it).
shape_set_hull :: proc(world: ^World, shape: Shape_Ref, hull: ^Hull_Data) {
	box3d.Shape_SetHull(shape_id(world, shape), hull)
}

// Makes the shape a scaled mesh (kept by pointer: it must live as long as the world).
shape_set_mesh :: proc(world: ^World, shape: Shape_Ref, mesh: ^Mesh_Data, scale := [3]f32{1, 1, 1}) {
	box3d.Shape_SetMesh(shape_id(world, shape), mesh, transmute(box3d.Vec3)scale)
}

// The shape's world AABB (tight), as of the last step or pose change.
shape_aabb :: proc(world: ^World, shape: Shape_Ref) -> AABB {
	return transmute(AABB)box3d.Shape_GetAABB(shape_id(world, shape))
}

// The shape's mass data at its density (body-local centre).
shape_compute_mass_data :: proc(world: ^World, shape: Shape_Ref) -> Mass_Data {
	return transmute(Mass_Data)box3d.Shape_ComputeMassData(shape_id(world, shape))
}

// ---- material and mass

// Sets the density (kg/m³); `update_body_mass` recomputes the body's mass now.
shape_set_density :: proc(world: ^World, shape: Shape_Ref, density: f32, update_body_mass := true) {
	box3d.Shape_SetDensity(shape_id(world, shape), density, update_body_mass)
}

// The density.
shape_density :: proc(world: ^World, shape: Shape_Ref) -> f32 {
	return box3d.Shape_GetDensity(shape_id(world, shape))
}

// Sets the friction of the shape's base material.
shape_set_friction :: proc(world: ^World, shape: Shape_Ref, friction: f32) {
	box3d.Shape_SetFriction(shape_id(world, shape), friction)
}

// The base material's friction.
shape_friction :: proc(world: ^World, shape: Shape_Ref) -> f32 {
	return box3d.Shape_GetFriction(shape_id(world, shape))
}

// Sets the restitution (bounciness) of the shape's base material.
shape_set_restitution :: proc(world: ^World, shape: Shape_Ref, restitution: f32) {
	box3d.Shape_SetRestitution(shape_id(world, shape), restitution)
}

// The base material's restitution.
shape_restitution :: proc(world: ^World, shape: Shape_Ref) -> f32 {
	return box3d.Shape_GetRestitution(shape_id(world, shape))
}

// Sets the shape's base surface material (friction, restitution, rolling resistance, tangent velocity, user id).
shape_set_surface_material :: proc(world: ^World, shape: Shape_Ref, material: Surface_Material) {
	box3d.Shape_SetSurfaceMaterial(shape_id(world, shape), transmute(box3d.SurfaceMaterial)material)
}

// The shape's base surface material.
shape_surface_material :: proc(world: ^World, shape: Shape_Ref) -> Surface_Material {
	return transmute(Surface_Material)box3d.Shape_GetSurfaceMaterial(shape_id(world, shape))
}

// How many materials a mesh or height field shape has (1 for convex shapes).
shape_mesh_material_count :: proc(world: ^World, shape: Shape_Ref) -> int {
	return int(box3d.Shape_GetMeshMaterialCount(shape_id(world, shape)))
}

// Sets one of a mesh or height field shape's materials (index < shape_mesh_material_count).
shape_set_mesh_material :: proc(world: ^World, shape: Shape_Ref, material: Surface_Material, index: int) {
	box3d.Shape_SetMeshMaterial(shape_id(world, shape), transmute(box3d.SurfaceMaterial)material, i32(index))
}

// One of a mesh or height field shape's materials.
shape_mesh_surface_material :: proc(world: ^World, shape: Shape_Ref, index: int) -> Surface_Material {
	return transmute(Surface_Material)box3d.Shape_GetMeshSurfaceMaterial(shape_id(world, shape), i32(index))
}

// ---- filtering and events

// The shape's collision filter (category and mask bits).
shape_filter :: proc(world: ^World, shape: Shape_Ref) -> Filter {
	return transmute(Filter)box3d.Shape_GetFilter(shape_id(world, shape))
}

// Sets the collision filter; `invoke_contacts` re-checks the shape's contacts now (else at the next step).
shape_set_filter :: proc(world: ^World, shape: Shape_Ref, filter: Filter, invoke_contacts := true) {
	box3d.Shape_SetFilter(shape_id(world, shape), transmute(box3d.Filter)filter, invoke_contacts)
}

// Turns sensor events on or off for this shape as a visitor.
shape_enable_sensor_events :: proc(world: ^World, shape: Shape_Ref, flag: bool) {
	box3d.Shape_EnableSensorEvents(shape_id(world, shape), flag)
}

// Whether the shape makes sensor events.
shape_are_sensor_events_enabled :: proc(world: ^World, shape: Shape_Ref) -> bool {
	return box3d.Shape_AreSensorEventsEnabled(shape_id(world, shape))
}

// Turns contact begin and end events on or off.
shape_enable_contact_events :: proc(world: ^World, shape: Shape_Ref, flag: bool) {
	box3d.Shape_EnableContactEvents(shape_id(world, shape), flag)
}

// Whether the shape makes contact events.
shape_are_contact_events_enabled :: proc(world: ^World, shape: Shape_Ref) -> bool {
	return box3d.Shape_AreContactEventsEnabled(shape_id(world, shape))
}

// Turns hit events on or off.
shape_enable_hit_events :: proc(world: ^World, shape: Shape_Ref, flag: bool) {
	box3d.Shape_EnableHitEvents(shape_id(world, shape), flag)
}

// Whether the shape makes hit events.
shape_are_hit_events_enabled :: proc(world: ^World, shape: Shape_Ref) -> bool {
	return box3d.Shape_AreHitEventsEnabled(shape_id(world, shape))
}

// ---- forces

// Applies wind drag and lift to a sphere, capsule or hull of a dynamic body (`wind` the air's velocity, m/s;
// `max_speed` caps the relative speed).
shape_apply_wind :: proc(world: ^World, shape: Shape_Ref, wind: [3]f32, drag, lift, max_speed: f32, wake := true) {
	box3d.Shape_ApplyWind(shape_id(world, shape), transmute(box3d.Vec3)wind, drag, lift, max_speed, wake)
}

@(private)
check_shape_def :: proc(def: Shape_Def, loc: runtime.Source_Code_Location) {
	assert(def.user_data == nil, "physics: a shape def's user_data stays unset (a pointer in rollback state)", loc)
}

// Names the shape (copied into the world: rollback state; for debugging and tools).
shape_set_name :: proc(world: ^World, shape: Shape_Ref, name: cstring) {
	box3d.Shape_SetName(shape_id(world, shape), name)
}

// The shape's name ("" when unnamed; valid while the shape lives).
shape_name :: proc(world: ^World, shape: Shape_Ref) -> cstring {
	return box3d.Shape_GetName(shape_id(world, shape))
}

// Box3D's default shape definition, to adjust before creating a shape.
default_shape_def :: proc() -> Shape_Def {
	return transmute(Shape_Def)box3d.DefaultShapeDef()
}
