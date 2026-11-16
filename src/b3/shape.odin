// Box3D's shape and geometry procs beyond b3.odin's (src/b3/SPEC.md): what physics' Shapes and Geometry groups and
// per-shape queries wrap.
package b3

import box3d "box3d:bindings"

// ---- shapes

// Adds a hull to a body, moved by `transform` and scaled (Box3D copies the result into its geometry database).
create_transformed_hull_shape :: proc(
	body_id: Body_Id,
	def: ^Shape_Def,
	hull: ^Hull_Data,
	transform: Transform,
	scale: [3]f32,
) -> Shape_Id {
	return box3d.CreateTransformedHullShape(
		body_id,
		(^box3d.ShapeDef)(def),
		hull,
		transmute(box3d.Transform)transform,
		transmute(box3d.Vec3)scale,
	)
}

// Adds a triangle mesh to a body, scaled. The shape keeps a pointer to the mesh: it must outlive the shape.
create_mesh_shape :: proc(body_id: Body_Id, def: ^Shape_Def, mesh: ^Mesh_Data, scale: [3]f32) -> Shape_Id {
	return box3d.CreateMeshShape(body_id, (^box3d.ShapeDef)(def), mesh, transmute(box3d.Vec3)scale)
}

// Adds a height field to a (static) body. The shape keeps a pointer to it: it must outlive the shape.
create_height_field_shape :: proc(body_id: Body_Id, def: ^Shape_Def, height_field: ^Height_Field_Data) -> Shape_Id {
	return box3d.CreateHeightFieldShape(body_id, (^box3d.ShapeDef)(def), height_field)
}

// Adds a baked compound to a (static) body. The shape keeps a pointer to it (and the compound to its meshes): they
// must outlive the shape.
create_baked_compound_shape :: proc(body_id: Body_Id, def: ^Shape_Def, compound: ^Compound_Data) -> Shape_Id {
	return box3d.CreateBakedCompoundShape(body_id, (^box3d.ShapeDef)(def), compound)
}

// Destroys a shape; `update_body_mass` recomputes its body's mass. Unchecked in the release library.
destroy_shape :: proc(shape_id: Shape_Id, update_body_mass: bool) {
	box3d.DestroyShape(shape_id, update_body_mass)
}

// Sphere, capsule, hull, mesh, height field or compound.
shape_get_type :: proc(shape_id: Shape_Id) -> Shape_Type {
	return Shape_Type(box3d.Shape_GetType(shape_id))
}

// Sets the density (kg/m³); `update_body_mass` recomputes the body's mass now.
shape_set_density :: proc(shape_id: Shape_Id, density: f32, update_body_mass: bool) {
	box3d.Shape_SetDensity(shape_id, density, update_body_mass)
}

// The density.
shape_get_density :: proc(shape_id: Shape_Id) -> f32 {
	return box3d.Shape_GetDensity(shape_id)
}

// Sets the friction of the shape's base material.
shape_set_friction :: proc(shape_id: Shape_Id, friction: f32) {
	box3d.Shape_SetFriction(shape_id, friction)
}

// The base material's friction.
shape_get_friction :: proc(shape_id: Shape_Id) -> f32 {
	return box3d.Shape_GetFriction(shape_id)
}

// Sets the restitution (bounciness) of the shape's base material.
shape_set_restitution :: proc(shape_id: Shape_Id, restitution: f32) {
	box3d.Shape_SetRestitution(shape_id, restitution)
}

// The base material's restitution.
shape_get_restitution :: proc(shape_id: Shape_Id) -> f32 {
	return box3d.Shape_GetRestitution(shape_id)
}

// Sets the shape's base surface material.
shape_set_surface_material :: proc(shape_id: Shape_Id, surface_material: Surface_Material) {
	box3d.Shape_SetSurfaceMaterial(shape_id, transmute(box3d.SurfaceMaterial)surface_material)
}

// The shape's base surface material.
shape_get_surface_material :: proc(shape_id: Shape_Id) -> Surface_Material {
	return transmute(Surface_Material)box3d.Shape_GetSurfaceMaterial(shape_id)
}

// How many materials a mesh or height field shape has (1 for convex shapes).
shape_get_mesh_material_count :: proc(shape_id: Shape_Id) -> i32 {
	return box3d.Shape_GetMeshMaterialCount(shape_id)
}

// Sets one of a mesh or height field shape's materials (index < shape_get_mesh_material_count).
shape_set_mesh_material :: proc(shape_id: Shape_Id, surface_material: Surface_Material, index: i32) {
	box3d.Shape_SetMeshMaterial(shape_id, transmute(box3d.SurfaceMaterial)surface_material, index)
}

// One of a mesh or height field shape's materials.
shape_get_mesh_surface_material :: proc(shape_id: Shape_Id, index: i32) -> Surface_Material {
	return transmute(Surface_Material)box3d.Shape_GetMeshSurfaceMaterial(shape_id, index)
}

// Sets the collision filter; `invoke_contacts` re-checks the shape's contacts now.
shape_set_filter :: proc(shape_id: Shape_Id, filter: Filter, invoke_contacts: bool) {
	box3d.Shape_SetFilter(shape_id, transmute(box3d.Filter)filter, invoke_contacts)
}

// Turns sensor events on or off for this shape as a visitor.
shape_enable_sensor_events :: proc(shape_id: Shape_Id, flag: bool) {
	box3d.Shape_EnableSensorEvents(shape_id, flag)
}

// Whether the shape makes sensor events.
shape_are_sensor_events_enabled :: proc(shape_id: Shape_Id) -> bool {
	return box3d.Shape_AreSensorEventsEnabled(shape_id)
}

// Turns contact begin and end events on or off.
shape_enable_contact_events :: proc(shape_id: Shape_Id, flag: bool) {
	box3d.Shape_EnableContactEvents(shape_id, flag)
}

// Whether the shape makes contact events.
shape_are_contact_events_enabled :: proc(shape_id: Shape_Id) -> bool {
	return box3d.Shape_AreContactEventsEnabled(shape_id)
}

// Turns hit events on or off.
shape_enable_hit_events :: proc(shape_id: Shape_Id, flag: bool) {
	box3d.Shape_EnableHitEvents(shape_id, flag)
}

// Whether the shape makes hit events.
shape_are_hit_events_enabled :: proc(shape_id: Shape_Id) -> bool {
	return box3d.Shape_AreHitEventsEnabled(shape_id)
}

// A ray from `origin` along `translation` against this shape alone; not ok: no hit.
shape_ray_cast :: proc(shape_id: Shape_Id, origin, translation: [3]f32) -> (output: Cast_Output, ok: bool) {
	raw := box3d.Shape_RayCast(shape_id, transmute(box3d.Vec3)origin, transmute(box3d.Vec3)translation)
	return (^Cast_Output)(&raw)^, raw.hit
}

// A sphere shape's sphere (body-local).
shape_get_sphere :: proc(shape_id: Shape_Id) -> Sphere {
	return transmute(Sphere)box3d.Shape_GetSphere(shape_id)
}

// A capsule shape's capsule (body-local).
shape_get_capsule :: proc(shape_id: Shape_Id) -> Capsule {
	return transmute(Capsule)box3d.Shape_GetCapsule(shape_id)
}

// A hull shape's hull: Box3D's copy, valid while the world lives.
shape_get_hull :: proc(shape_id: Shape_Id) -> ^Hull_Data {
	return box3d.Shape_GetHull(shape_id)
}

// A mesh shape's mesh (the one it was made with, or an image's copy) and scale.
shape_get_mesh :: proc(shape_id: Shape_Id) -> Mesh {
	return transmute(Mesh)box3d.Shape_GetMesh(shape_id)
}

// A height field shape's height field (the one it was made with, or an image's copy).
shape_get_height_field :: proc(shape_id: Shape_Id) -> ^Height_Field_Data {
	return box3d.Shape_GetHeightField(shape_id)
}

// A compound shape's compound (the one it was made with, or an image's copy).
shape_get_compound :: proc(shape_id: Shape_Id) -> ^Compound_Data {
	return box3d.Shape_GetCompound(shape_id)
}

// Replaces a shape's geometry with a sphere (the shape becomes a sphere).
shape_set_sphere :: proc(shape_id: Shape_Id, sphere: ^Sphere) {
	box3d.Shape_SetSphere(shape_id, (^box3d.Sphere)(sphere))
}

// Replaces a shape's geometry with a capsule.
shape_set_capsule :: proc(shape_id: Shape_Id, capsule: ^Capsule) {
	box3d.Shape_SetCapsule(shape_id, (^box3d.Capsule)(capsule))
}

// Replaces a shape's geometry with a hull (copied into the geometry database).
shape_set_hull :: proc(shape_id: Shape_Id, hull: ^Hull_Data) {
	box3d.Shape_SetHull(shape_id, hull)
}

// Replaces a shape's geometry with a scaled mesh (kept by pointer: it must outlive the shape).
shape_set_mesh :: proc(shape_id: Shape_Id, mesh: ^Mesh_Data, scale: [3]f32) {
	box3d.Shape_SetMesh(shape_id, mesh, transmute(box3d.Vec3)scale)
}

// How many contacts shape_get_contact_data can report (the size it needs).
shape_get_contact_capacity :: proc(shape_id: Shape_Id) -> i32 {
	return box3d.Shape_GetContactCapacity(shape_id)
}

// The shape's touching contacts into `out` (at most len(out)); the count written. Their manifolds are Box3D's
// memory, valid until the next step.
shape_get_contact_data :: proc(shape_id: Shape_Id, out: []Contact_Data) -> i32 {
	return box3d.Shape_GetContactData(shape_id, ([^]box3d.ContactData)(raw_data(out)), i32(len(out)))
}

// The shape's world AABB (tight, not the broad phase's enlarged one), as of the last step or pose change.
shape_get_aabb :: proc(shape_id: Shape_Id) -> AABB {
	return transmute(AABB)box3d.Shape_GetAABB(shape_id)
}

// The shape's mass data at its density (body-local centre).
shape_compute_mass_data :: proc(shape_id: Shape_Id) -> Mass_Data {
	return transmute(Mass_Data)box3d.Shape_ComputeMassData(shape_id)
}

// The point on the shape (a sphere, capsule or hull) closest to `target`, world space.
shape_get_closest_point :: proc(shape_id: Shape_Id, target: [3]f32) -> [3]f32 {
	return transmute([3]f32)box3d.Shape_GetClosestPoint(shape_id, transmute(box3d.Vec3)target)
}

// Applies wind drag and lift to a sphere, capsule or hull of a dynamic body (`wind` the air's velocity; `max_speed`
// caps the relative speed).
shape_apply_wind :: proc(shape_id: Shape_Id, wind: [3]f32, drag, lift, max_speed: f32, wake: bool) {
	box3d.Shape_ApplyWind(shape_id, transmute(box3d.Vec3)wind, drag, lift, max_speed, wake)
}

// ---- geometry (host-side; free what create_* returns with its destroy_*)

// A cylinder hull along y (`sides` around), its base at `y_offset`. Free with destroy_hull.
create_cylinder :: proc(height, radius, y_offset: f32, sides: i32) -> ^Hull_Data {
	return box3d.CreateCylinder(height, radius, y_offset, sides)
}

// A cone (frustum) hull along y, radius1 at the bottom, radius2 at the top. Free with destroy_hull.
create_cone :: proc(height, radius1, radius2: f32, slices: i32) -> ^Hull_Data {
	return box3d.CreateCone(height, radius1, radius2, slices)
}

// A copy of a hull. Free with destroy_hull.
clone_hull :: proc(hull: ^Hull_Data) -> ^Hull_Data {
	return box3d.CloneHull(hull)
}

// A cube hull with the given half width (by value, nothing to free).
make_cube_hull :: proc(half_width: f32) -> Box_Hull {
	return box3d.MakeCubeHull(half_width)
}

// A box hull with the given half extents, centred on `offset`.
make_offset_box_hull :: proc(hx, hy, hz: f32, offset: [3]f32) -> Box_Hull {
	return box3d.MakeOffsetBoxHull(hx, hy, hz, transmute(box3d.Vec3)offset)
}

// A box hull with the given half extents, moved by `transform`.
make_transformed_box_hull :: proc(hx, hy, hz: f32, transform: Transform) -> Box_Hull {
	return box3d.MakeTransformedBoxHull(hx, hy, hz, transmute(box3d.Transform)transform)
}

// A box hull with the given half extents, moved by `transform`, then scaled by `post_scale`.
make_scaled_box_hull :: proc(half_widths: [3]f32, transform: Transform, post_scale: [3]f32) -> Box_Hull {
	return box3d.MakeScaledBoxHull(
		transmute(box3d.Vec3)half_widths,
		transmute(box3d.Transform)transform,
		transmute(box3d.Vec3)post_scale,
	)
}

// A triangle mesh from a definition; the indices of degenerate triangles go into `degenerate_triangles` (at most its
// length; the count is the mesh's degenerateCount). Nil when the mesh can't be built. Free with destroy_mesh.
create_mesh :: proc(def: ^Mesh_Def, degenerate_triangles: []i32) -> ^Mesh_Data {
	return box3d.CreateMesh((^box3d.MeshDef)(def), raw_data(degenerate_triangles), i32(len(degenerate_triangles)))
}

// A flat grid mesh in xz of x_count × z_count cells. Free with destroy_mesh.
create_grid_mesh :: proc(
	x_count, z_count: i32,
	cell_width: f32,
	material_count: i32,
	identify_edges: bool,
) -> ^Mesh_Data {
	return box3d.CreateGridMesh(x_count, z_count, cell_width, material_count, identify_edges)
}

// A closed box mesh. Free with destroy_mesh.
create_box_mesh :: proc(center, extent: [3]f32, identify_edges: bool) -> ^Mesh_Data {
	return box3d.CreateBoxMesh(transmute(box3d.Vec3)center, transmute(box3d.Vec3)extent, identify_edges)
}

// A box mesh facing inwards (a room). Free with destroy_mesh.
create_hollow_box_mesh :: proc(center, extent: [3]f32) -> ^Mesh_Data {
	return box3d.CreateHollowBoxMesh(transmute(box3d.Vec3)center, transmute(box3d.Vec3)extent)
}

// A platform mesh (a frustum: top_width over bottom_width). Free with destroy_mesh.
create_platform_mesh :: proc(center: [3]f32, height, top_width, bottom_width: f32) -> ^Mesh_Data {
	return box3d.CreatePlatformMesh(transmute(box3d.Vec3)center, height, top_width, bottom_width)
}

// Frees a mesh made by a create_*_mesh or create_mesh.
destroy_mesh :: proc(mesh: ^Mesh_Data) {
	box3d.DestroyMesh(mesh)
}

// A height field from a definition. Free with destroy_height_field.
create_height_field :: proc(def: ^Height_Field_Def) -> ^Height_Field_Data {
	return box3d.CreateHeightField((^box3d.HeightFieldDef)(def))
}

// A flat height field of row_count × column_count points, scaled; `make_holes` punches a pattern of holes. Free
// with destroy_height_field.
create_grid :: proc(row_count, column_count: i32, scale: [3]f32, make_holes: bool) -> ^Height_Field_Data {
	return box3d.CreateGrid(row_count, column_count, transmute(box3d.Vec3)scale, make_holes)
}

// Frees a height field.
destroy_height_field :: proc(height_field: ^Height_Field_Data) {
	box3d.DestroyHeightField(height_field)
}

// A baked compound from a definition (every child copied in). Free with destroy_compound.
create_compound :: proc(def: ^Compound_Def) -> ^Compound_Data {
	return box3d.CreateCompound((^box3d.CompoundDef)(def))
}

// Frees a compound.
destroy_compound :: proc(compound: ^Compound_Data) {
	box3d.DestroyCompound(compound)
}

// A sphere's mass data at a density.
compute_sphere_mass :: proc(shape: ^Sphere, density: f32) -> Mass_Data {
	return transmute(Mass_Data)box3d.ComputeSphereMass((^box3d.Sphere)(shape), density)
}

// A capsule's mass data at a density.
compute_capsule_mass :: proc(shape: ^Capsule, density: f32) -> Mass_Data {
	return transmute(Mass_Data)box3d.ComputeCapsuleMass((^box3d.Capsule)(shape), density)
}

// A hull's mass data at a density.
compute_hull_mass :: proc(shape: ^Hull_Data, density: f32) -> Mass_Data {
	return transmute(Mass_Data)box3d.ComputeHullMass(shape, density)
}

// A sphere's AABB at a transform.
compute_sphere_aabb :: proc(shape: ^Sphere, transform: Transform) -> AABB {
	return transmute(AABB)box3d.ComputeSphereAABB((^box3d.Sphere)(shape), transmute(box3d.Transform)transform)
}

// A capsule's AABB at a transform.
compute_capsule_aabb :: proc(shape: ^Capsule, transform: Transform) -> AABB {
	return transmute(AABB)box3d.ComputeCapsuleAABB((^box3d.Capsule)(shape), transmute(box3d.Transform)transform)
}

// A hull's AABB at a transform.
compute_hull_aabb :: proc(shape: ^Hull_Data, transform: Transform) -> AABB {
	return transmute(AABB)box3d.ComputeHullAABB(shape, transmute(box3d.Transform)transform)
}

// A scaled mesh's AABB at a transform.
compute_mesh_aabb :: proc(shape: ^Mesh_Data, transform: Transform, scale: [3]f32) -> AABB {
	return transmute(AABB)box3d.ComputeMeshAABB(shape, transmute(box3d.Transform)transform, transmute(box3d.Vec3)scale)
}

// A height field's AABB at a transform.
compute_height_field_aabb :: proc(shape: ^Height_Field_Data, transform: Transform) -> AABB {
	return transmute(AABB)box3d.ComputeHeightFieldAABB(shape, transmute(box3d.Transform)transform)
}

// A compound's AABB at a transform.
compute_compound_aabb :: proc(shape: ^Compound_Data, transform: Transform) -> AABB {
	return transmute(AABB)box3d.ComputeCompoundAABB(shape, transmute(box3d.Transform)transform)
}

// Names the shape (copied into the world, as a body's name).
shape_set_name :: proc(shape_id: Shape_Id, name: cstring) {
	box3d.Shape_SetName(shape_id, name)
}

// The shape's name ("" when unnamed; Box3D's memory, valid while the shape lives).
shape_get_name :: proc(shape_id: Shape_Id) -> cstring {
	return box3d.Shape_GetName(shape_id)
}
