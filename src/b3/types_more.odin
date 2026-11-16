// More mirrors of the bindings' structs (src/b3/SPEC.md, Conventions): what the body, shape, world and geometry procs
// beyond b3.odin's take and return. Same layout as the bindings scalar for scalar (asserted below, tested in
// tests/b3/more_layout_test.odin), so a conversion is a transmute or a pointer cast.
package b3

import box3d "box3d:bindings"

// ---- opaque or untouched by callers: geometry that lives in Box3D's database (or the caller's, until made a shape)

Mesh_Data :: box3d.MeshData // a triangle mesh's BVH (create_mesh); data hangs off its end, never copy it
Height_Field_Data :: box3d.HeightFieldData // a compressed height field (create_height_field)
Compound_Data :: box3d.CompoundData // a baked compound (create_compound)

// ---- mirrors

Shape_Type :: enum i32 {
	Capsule_Shape  = 0,
	Compound_Shape = 1,
	Height_Shape   = 2,
	Hull_Shape     = 3,
	Mesh_Shape     = 4,
	Sphere_Shape   = 5,
}

// A 3x3 matrix as three columns (no Odin `matrix` types: the sim never multiplies with them).
Matrix3 :: struct {
	cx: [3]f32,
	cy: [3]f32,
	cz: [3]f32,
}

// A shape's or a body's mass, its centre of mass (local) and its inertia about that centre.
Mass_Data :: struct {
	mass:    f32,
	center:  [3]f32,
	inertia: Matrix3,
}

// separation = dot(normal, point) - offset
Plane :: struct {
	normal: [3]f32,
	offset: f32,
}

// An explosion (world_explode): an impulse per area of the shapes facing `position`, fading to zero over `falloff`
// past `radius`; only spheres, capsules and hulls, only shapes in `mask_bits`.
Explosion_Def :: struct {
	mask_bits:        u64,
	position:         [3]f32,
	radius:           f32,
	falloff:          f32,
	impulse_per_area: f32,
}

// A contact point. Anchors are relative to each body's centre of mass, in world axes.
Manifold_Point :: struct {
	anchor_a:             [3]f32,
	anchor_b:             [3]f32,
	separation:           f32, // negative when penetrating
	normal_impulse:       f32,
	total_normal_impulse: f32,
	normal_velocity:      f32,
	base_separation:      f32,
	feature_id:           u32,
	triangle_index:       i32,
	persisted:            bool,
}

// The contact points between two shapes (1 to 4), the normal from shape A to shape B.
Manifold :: struct {
	points:           [box3d.MAX_MANIFOLD_POINTS]Manifold_Point,
	normal:           [3]f32,
	twist_impulse:    f32,
	friction_impulse: [3]f32,
	rolling_impulse:  [3]f32,
	point_count:      i32,
}

// A touching contact between two shapes: `manifolds` points into Box3D's memory, valid until the next step.
Contact_Data :: struct {
	contact_id:     Contact_Id,
	shape_id_a:     Shape_Id,
	shape_id_b:     Shape_Id,
	manifolds:      [^]Manifold,
	manifold_count: i32,
}

// A body that moved in the last step (every awake dynamic or kinematic body).
Body_Move_Event :: struct {
	user_data:   rawptr,
	transform:   Transform,
	body_id:     Body_Id,
	fell_asleep: bool,
}

// An awake joint whose force or torque passed its threshold in the last step.
Joint_Event :: struct {
	joint_id:  Joint_Id,
	user_data: rawptr,
}

// A triangle mesh to build (create_mesh); nothing in it is kept, so the arrays may be temporary.
Mesh_Def :: struct {
	vertices:           [^][3]f32,
	stride:             int, // bytes between vertices; 0: contiguous
	indices:            [^]i32, // 3 per triangle, counter-clockwise unless clock_wise_winding
	material_indices:   [^]u8, // 1 per triangle (nil: all 0), into the shape def's materials
	weld_tolerance:     f32,
	vertex_count:       i32,
	triangle_count:     i32,
	weld_vertices:      bool,
	use_median_split:   bool,
	identify_edges:     bool,
	clock_wise_winding: bool,
}

// A mesh with a scale, as a shape holds it.
Mesh :: struct {
	data:  ^Mesh_Data,
	scale: [3]f32,
}

// A height field to build (create_height_field): count_x × count_z heights, a material per cell (0xFF: a hole).
Height_Field_Def :: struct {
	heights:               [^]f32,
	material_indices:      [^]u8,
	scale:                 [3]f32,
	count_x:               i32,
	count_z:               i32,
	global_minimum_height: f32,
	global_maximum_height: f32,
	clockwise_winding:     bool,
}

Compound_Capsule_Def :: struct {
	capsule:  Capsule,
	material: Surface_Material,
}

Compound_Hull_Def :: struct {
	hull:      ^Hull_Data,
	transform: Transform,
	material:  Surface_Material,
}

Compound_Mesh_Def :: struct {
	mesh_data:      ^Mesh_Data,
	transform:      Transform,
	scale:          [3]f32,
	materials:      [^]Surface_Material,
	material_count: i32,
}

Compound_Sphere_Def :: struct {
	sphere:   Sphere,
	material: Surface_Material,
}

// A baked compound to build (create_compound): every child is copied in.
Compound_Def :: struct {
	capsules:      [^]Compound_Capsule_Def,
	capsule_count: i32,
	hulls:         [^]Compound_Hull_Def,
	hull_count:    i32,
	meshes:        [^]Compound_Mesh_Def,
	mesh_count:    i32,
	spheres:       [^]Compound_Sphere_Def,
	sphere_count:  i32,
}

// b3CastOutput (b3WorldCastOutput) without its `hit` field (its last): shape_ray_cast returns (Cast_Output, ok).
Cast_Output :: struct {
	normal:         [3]f32,
	point:          [3]f32,
	fraction:       f32,
	iterations:     i32,
	triangle_index: i32,
	child_index:    i32,
	material_index: i32,
}

// b3BodyCastResult without its `hit` field (its last): the body casts return (Body_Cast_Result, ok).
Body_Cast_Result :: struct {
	shape_id:         Shape_Id,
	point:            [3]f32,
	normal:           [3]f32,
	fraction:         f32,
	triangle_index:   i32,
	user_material_id: u64,
	iterations:       i32,
}

// The plane between a character mover and a shape.
Plane_Result :: struct {
	plane:          Plane, // outward
	point:          [3]f32, // the closest point on the shape
	triangle_index: i32,
	child_index:    i32,
	material_index: i32,
}

// A mover's plane against one of a body's shapes (body_collide_mover).
Body_Plane_Result :: struct {
	shape_id: Shape_Id,
	result:   Plane_Result,
}

// A mover's time of impact against a body (body_time_of_impact_mover). `fraction` 1: no hit.
Body_TOI_Result :: struct {
	point:    [3]f32,
	normal:   [3]f32, // from the body to the mover
	fraction: f32,
	shape_id: Shape_Id,
}

// Called for each shape a mover cast meets; return false to ignore it. `user` is the query's.
Mover_Filter_Fcn :: #type proc(shape_id: Shape_Id, user: rawptr) -> bool

// Called with a shape's planes against a mover (Box3D's memory, valid during the call); return false to stop.
Plane_Result_Fcn :: #type proc(shape_id: Shape_Id, planes: []Plane_Result, user: rawptr) -> bool

#assert(size_of(Shape_Type) == size_of(box3d.ShapeType))
#assert(i32(Shape_Type.Capsule_Shape) == i32(box3d.ShapeType.capsuleShape))
#assert(i32(Shape_Type.Compound_Shape) == i32(box3d.ShapeType.compoundShape))
#assert(i32(Shape_Type.Height_Shape) == i32(box3d.ShapeType.heightShape))
#assert(i32(Shape_Type.Hull_Shape) == i32(box3d.ShapeType.hullShape))
#assert(i32(Shape_Type.Mesh_Shape) == i32(box3d.ShapeType.meshShape))
#assert(i32(Shape_Type.Sphere_Shape) == i32(box3d.ShapeType.sphereShape))
#assert(size_of(Matrix3) == size_of(box3d.Matrix3))
#assert(size_of(Mass_Data) == size_of(box3d.MassData))
#assert(size_of(Plane) == size_of(box3d.Plane))
#assert(size_of(Explosion_Def) == size_of(box3d.ExplosionDef))
#assert(size_of(Manifold_Point) == size_of(box3d.ManifoldPoint))
#assert(size_of(Manifold) == size_of(box3d.Manifold))
#assert(size_of(Contact_Data) == size_of(box3d.ContactData))
#assert(size_of(Body_Move_Event) == size_of(box3d.BodyMoveEvent))
#assert(size_of(Joint_Event) == size_of(box3d.JointEvent))
#assert(size_of(Mesh_Def) == size_of(box3d.MeshDef))
#assert(size_of(Mesh) == size_of(box3d.Mesh))
#assert(size_of(Height_Field_Def) == size_of(box3d.HeightFieldDef))
#assert(size_of(Compound_Capsule_Def) == size_of(box3d.CompoundCapsuleDef))
#assert(size_of(Compound_Hull_Def) == size_of(box3d.CompoundHullDef))
#assert(size_of(Compound_Mesh_Def) == size_of(box3d.CompoundMeshDef))
#assert(size_of(Compound_Sphere_Def) == size_of(box3d.CompoundSphereDef))
#assert(size_of(Compound_Def) == size_of(box3d.CompoundDef))
#assert(offset_of(box3d.CastOutput, hit) == offset_of(Cast_Output, material_index) + size_of(i32))
#assert(size_of(Cast_Output) <= size_of(box3d.CastOutput))
#assert(offset_of(box3d.BodyCastResult, hit) == offset_of(Body_Cast_Result, iterations) + size_of(i32))
#assert(size_of(Body_Cast_Result) <= size_of(box3d.BodyCastResult))
#assert(size_of(Plane_Result) == size_of(box3d.PlaneResult))
#assert(size_of(Body_Plane_Result) == size_of(box3d.BodyPlaneResult))
#assert(size_of(Body_TOI_Result) == size_of(box3d.BodyTOIResult))
