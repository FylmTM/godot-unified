// Geometry (src/physics/SPEC.md, What physics covers): hulls, meshes, height fields and compounds to build shapes
// from, and their mass and bounds. Host-side and outside the block: a game builds them when its World is created (or
// when it needs a new one), keeps them in its World and frees them with their destroy_*. A hull shape copies its hull
// into Box3D's geometry database; mesh, height field and compound shapes keep a pointer to the game's, so those live
// as long as the world (a rollback can bring back a destroyed shape). Portable images carry every kind: a loading
// world gets its own copies.
package physics

import box3d "box3d:bindings"


// ---- hulls

// The convex hull of `points` (at most `max_vertex_count` vertices; 64 keeps it under Box3D's 128 edges); nil when
// the points are degenerate (flat, collinear, fewer than 4). Free with destroy_hull.
create_hull :: proc(points: [][3]f32, max_vertex_count := 64) -> ^Hull_Data {
	return box3d.CreateHull(([^]box3d.Vec3)(raw_data(points)), i32(len(points)), i32(max_vertex_count))
}

// A copy of a hull. Free with destroy_hull.
clone_hull :: proc(hull: ^Hull_Data) -> ^Hull_Data {
	return box3d.CloneHull(hull)
}

// A copy of a hull moved by `transform` and scaled. Free with destroy_hull.
clone_and_transform_hull :: proc(hull: ^Hull_Data, transform: Transform, scale := [3]f32{1, 1, 1}) -> ^Hull_Data {
	return box3d.CloneAndTransformHull(hull, transmute(box3d.Transform)transform, transmute(box3d.Vec3)scale)
}

// Frees a hull made by create_hull, clone_hull, clone_and_transform_hull, create_cylinder or create_cone.
destroy_hull :: proc(hull: ^Hull_Data) {
	box3d.DestroyHull(hull)
}

// A cube hull of the given half width, centred on the origin (by value: `&box.base` is the hull; nothing to free).
make_cube_hull :: proc(half_width: f32) -> Box_Hull {
	return box3d.MakeCubeHull(half_width)
}

// A box hull with the given half extents, centred on the origin.
make_box_hull :: proc(hx, hy, hz: f32) -> Box_Hull {
	return box3d.MakeBoxHull(hx, hy, hz)
}

// A box hull with the given half extents, centred on `offset`.
make_offset_box_hull :: proc(hx, hy, hz: f32, offset: [3]f32) -> Box_Hull {
	return box3d.MakeOffsetBoxHull(hx, hy, hz, transmute(box3d.Vec3)offset)
}

// A box hull with the given half extents, moved by `transform`.
make_transformed_box_hull :: proc(hx, hy, hz: f32, transform: Transform) -> Box_Hull {
	return box3d.MakeTransformedBoxHull(hx, hy, hz, transmute(box3d.Transform)transform)
}

// A box hull with the given half extents, moved by `transform`, then scaled by `post_scale` (which may shear it
// back into a box: Box3D refits it).
make_scaled_box_hull :: proc(half_widths: [3]f32, transform: Transform, post_scale: [3]f32) -> Box_Hull {
	return box3d.MakeScaledBoxHull(
		transmute(box3d.Vec3)half_widths,
		transmute(box3d.Transform)transform,
		transmute(box3d.Vec3)post_scale,
	)
}

// A cylinder hull along y with `sides` sides, its base at `y_offset`. Free with destroy_hull.
create_cylinder :: proc(height, radius, y_offset: f32, sides: int) -> ^Hull_Data {
	return box3d.CreateCylinder(height, radius, y_offset, i32(sides))
}

// A cone (a frustum) hull along y, `bottom_radius` at the base, `top_radius` at the top. Free with destroy_hull.
create_cone :: proc(height, bottom_radius, top_radius: f32, slices: int) -> ^Hull_Data {
	return box3d.CreateCone(height, bottom_radius, top_radius, i32(slices))
}

// ---- meshes

// A mesh definition over the caller's vertices and triangle indices (3 per triangle, counter-clockwise seen from
// the front), optionally one material index per triangle; adjust the rest (welding, edges) before create_mesh.
make_mesh_def :: proc(vertices: [][3]f32, indices: []i32, material_indices: []u8 = nil) -> Mesh_Def {
	assert(len(indices) % 3 == 0 && (material_indices == nil || len(material_indices) == len(indices) / 3))
	return {
		vertices         = raw_data(vertices),
		indices          = raw_data(indices),
		material_indices = raw_data(material_indices),
		vertex_count     = i32(len(vertices)),
		triangle_count   = i32(len(indices) / 3),
		identify_edges   = true,
	}
}

// A triangle mesh (a BVH) from a definition; nothing in the def is kept. The indices of degenerate triangles (left
// out) go into `degenerate_triangles`, as many as fit. Nil when the mesh can't be built. Free with destroy_mesh.
create_mesh :: proc(def: ^Mesh_Def, degenerate_triangles: []i32 = nil) -> ^Mesh_Data {
	return box3d.CreateMesh((^box3d.MeshDef)(def), raw_data(degenerate_triangles), i32(len(degenerate_triangles)))
}

// A closed box mesh centred on `center` with half extents `extent`. Free with destroy_mesh.
create_box_mesh :: proc(center, extent: [3]f32, identify_edges := true) -> ^Mesh_Data {
	return box3d.CreateBoxMesh(transmute(box3d.Vec3)center, transmute(box3d.Vec3)extent, identify_edges)
}

// A box mesh facing inwards (a room). Free with destroy_mesh.
create_hollow_box_mesh :: proc(center, extent: [3]f32) -> ^Mesh_Data {
	return box3d.CreateHollowBoxMesh(transmute(box3d.Vec3)center, transmute(box3d.Vec3)extent)
}

// A platform mesh: a frustum `height` tall, `top_width` over `bottom_width`. Free with destroy_mesh.
create_platform_mesh :: proc(center: [3]f32, height, top_width, bottom_width: f32) -> ^Mesh_Data {
	return box3d.CreatePlatformMesh(transmute(box3d.Vec3)center, height, top_width, bottom_width)
}

// A flat grid mesh in xz of x_count × z_count cells of `cell_width`, cycling through `material_count` materials.
// Free with destroy_mesh.
create_grid_mesh :: proc(
	x_count, z_count: int,
	cell_width: f32,
	material_count := 1,
	identify_edges := true,
) -> ^Mesh_Data {
	return box3d.CreateGridMesh(i32(x_count), i32(z_count), cell_width, i32(material_count), identify_edges)
}

// Frees a mesh made by create_mesh or a create_*_mesh.
destroy_mesh :: proc(mesh: ^Mesh_Data) {
	box3d.DestroyMesh(mesh)
}

// ---- height fields

// A height field from a definition (nothing in it is kept). Free with destroy_height_field.
create_height_field :: proc(def: ^Height_Field_Def) -> ^Height_Field_Data {
	return box3d.CreateHeightField((^box3d.HeightFieldDef)(def))
}

// A flat height field of row_count × column_count points, scaled; `make_holes` punches a pattern of holes. Free with
// destroy_height_field.
create_grid :: proc(row_count, column_count: int, scale: [3]f32, make_holes := false) -> ^Height_Field_Data {
	return box3d.CreateGrid(i32(row_count), i32(column_count), transmute(box3d.Vec3)scale, make_holes)
}

// Frees a height field.
destroy_height_field :: proc(height_field: ^Height_Field_Data) {
	box3d.DestroyHeightField(height_field)
}

// ---- compounds

// A baked compound from a definition (every child copied in: one broad-phase shape for many children). Free with
// destroy_compound.
create_compound :: proc(def: ^Compound_Def) -> ^Compound_Data {
	return box3d.CreateCompound((^box3d.CompoundDef)(def))
}

// Frees a compound.
destroy_compound :: proc(compound: ^Compound_Data) {
	box3d.DestroyCompound(compound)
}

// ---- mass and bounds

// A sphere's mass data at a density (kg/m³).
compute_sphere_mass :: proc(sphere: Sphere, density: f32) -> Mass_Data {
	sphere := sphere
	return transmute(Mass_Data)box3d.ComputeSphereMass((^box3d.Sphere)(&sphere), density)
}

// A capsule's mass data at a density.
compute_capsule_mass :: proc(capsule: Capsule, density: f32) -> Mass_Data {
	capsule := capsule
	return transmute(Mass_Data)box3d.ComputeCapsuleMass((^box3d.Capsule)(&capsule), density)
}

// A hull's mass data at a density.
compute_hull_mass :: proc(hull: ^Hull_Data, density: f32) -> Mass_Data {
	return transmute(Mass_Data)box3d.ComputeHullMass(hull, density)
}

// A sphere's AABB at a transform.
compute_sphere_aabb :: proc(sphere: Sphere, transform: Transform) -> AABB {
	sphere := sphere
	return transmute(AABB)box3d.ComputeSphereAABB((^box3d.Sphere)(&sphere), transmute(box3d.Transform)transform)
}

// A capsule's AABB at a transform.
compute_capsule_aabb :: proc(capsule: Capsule, transform: Transform) -> AABB {
	capsule := capsule
	return transmute(AABB)box3d.ComputeCapsuleAABB((^box3d.Capsule)(&capsule), transmute(box3d.Transform)transform)
}

// A hull's AABB at a transform.
compute_hull_aabb :: proc(hull: ^Hull_Data, transform: Transform) -> AABB {
	return transmute(AABB)box3d.ComputeHullAABB(hull, transmute(box3d.Transform)transform)
}

// A scaled mesh's AABB at a transform.
compute_mesh_aabb :: proc(mesh: ^Mesh_Data, transform: Transform, scale := [3]f32{1, 1, 1}) -> AABB {
	return transmute(AABB)box3d.ComputeMeshAABB(mesh, transmute(box3d.Transform)transform, transmute(box3d.Vec3)scale)
}

// A height field's AABB at a transform.
compute_height_field_aabb :: proc(height_field: ^Height_Field_Data, transform: Transform) -> AABB {
	return transmute(AABB)box3d.ComputeHeightFieldAABB(height_field, transmute(box3d.Transform)transform)
}

// A compound's AABB at a transform.
compute_compound_aabb :: proc(compound: ^Compound_Data, transform: Transform) -> AABB {
	return transmute(AABB)box3d.ComputeCompoundAABB(compound, transmute(box3d.Transform)transform)
}

// A proxy for shape overlaps and casts: a convex point cloud (at most MAX_SHAPE_CAST_POINTS, the caller's memory)
// with a radius. One point with a radius is a sphere, two a capsule.
make_proxy :: proc(points: [][3]f32, radius: f32) -> Shape_Proxy {
	assert(len(points) >= 1 && len(points) <= MAX_SHAPE_CAST_POINTS)
	return {points = raw_data(points), count = i32(len(points)), radius = radius}
}
