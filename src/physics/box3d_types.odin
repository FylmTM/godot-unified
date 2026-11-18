// Box3D's value types and definitions (src/physics/SPEC.md, The boundary): mirrors of the bindings' structs
// (`box3d:bindings`, upstream's C API 1:1) with Odin names, [3]f32 vectors and [4]f32 rotations (x, y, z, w). Each has
// its binding's layout scalar for scalar (tests/physics/box3d_test.odin walks both by RTTI), so a conversion is a
// transmute or a pointer cast, never math or a copy loop. Opaque data that callers only pass around are aliases.
package physics

import box3d "box3d:bindings"

// ---- math and geometry

Transform :: struct {
	p: [3]f32,
	q: [4]f32, // x, y, z, w
}

AABB :: struct {
	lower_bound: [3]f32,
	upper_bound: [3]f32,
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

Sphere :: struct {
	center: [3]f32,
	radius: f32,
}

Capsule :: struct {
	center1: [3]f32,
	center2: [3]f32,
	radius:  f32,
}

// A convex point cloud with a radius, for shape overlaps and casts: a sphere is one point with a radius, a capsule
// two, a box its 8 corners with none. `points` is the caller's (at most MAX_SHAPE_CAST_POINTS).
Shape_Proxy :: struct {
	points: [^][3]f32,
	count:  i32,
	radius: f32,
}

MAX_SHAPE_CAST_POINTS :: box3d.MAX_SHAPE_CAST_POINTS

Hull_Data :: box3d.HullData

Box_Hull :: box3d.BoxHull // `&h.base` is the hull

Mesh_Data :: box3d.MeshData // a triangle mesh's BVH (create_mesh); data hangs off its end, never copy it

Height_Field_Data :: box3d.HeightFieldData // a compressed height field (create_height_field)

Compound_Data :: box3d.CompoundData // a baked compound (create_compound)

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

// ---- bodies and shapes

Body_Type :: enum i32 {
	Static_Body    = 0,
	Kinematic_Body = 1,
	Dynamic_Body   = 2,
}

Motion_Locks :: struct {
	linear_x:  bool,
	linear_y:  bool,
	linear_z:  bool,
	angular_x: bool,
	angular_y: bool,
	angular_z: bool,
}

Body_Def :: struct {
	type:                     Body_Type,
	position:                 [3]f32,
	rotation:                 [4]f32,
	linear_velocity:          [3]f32,
	angular_velocity:         [3]f32,
	linear_damping:           f32,
	angular_damping:          f32,
	gravity_scale:            f32,
	sleep_threshold:          f32,
	safety_factor:            f32,
	name:                     cstring,
	user_data:                rawptr,
	motion_locks:             Motion_Locks,
	enable_sleep:             bool,
	is_awake:                 bool,
	is_bullet:                bool,
	is_enabled:               bool,
	allow_fast_rotation:      bool,
	enable_contact_recycling: bool,
	internal_value:           i32,
}

Shape_Type :: enum i32 {
	Capsule_Shape  = 0,
	Compound_Shape = 1,
	Height_Shape   = 2,
	Hull_Shape     = 3,
	Mesh_Shape     = 4,
	Sphere_Shape   = 5,
}

Surface_Material :: struct {
	friction:           f32,
	restitution:        f32,
	rolling_resistance: f32,
	tangent_velocity:   [3]f32,
	user_material_id:   u64,
	custom_color:       u32,
	padding:            u32,
}

Filter :: struct {
	category_bits: u64,
	mask_bits:     u64,
	group_index:   i32,
}

Shape_Def :: struct {
	name:                       cstring,
	user_data:                  rawptr,
	materials:                  [^]Surface_Material,
	material_count:             i32,
	base_material:              Surface_Material,
	density:                    f32,
	explosion_scale:            f32,
	filter:                     Filter,
	enable_custom_filtering:    bool,
	is_sensor:                  bool,
	enable_sensor_events:       bool,
	enable_contact_events:      bool,
	enable_hit_events:          bool,
	enable_pre_solve_events:    bool,
	invoke_contact_creation:    bool,
	update_body_mass:           bool,
	enable_speculative_contact: bool,
	internal_value:             i32,
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

// The contact points between two shapes (1 to 4), the normal from shape A to shape B.
Manifold :: struct {
	points:           [box3d.MAX_MANIFOLD_POINTS]Manifold_Point,
	normal:           [3]f32,
	twist_impulse:    f32,
	friction_impulse: [3]f32,
	rolling_impulse:  [3]f32,
	point_count:      i32,
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

// ---- joints

// What kind a joint is (joint_get_type).
Joint_Type :: enum i32 {
	Parallel_Joint  = 0,
	Distance_Joint  = 1,
	Filter_Joint    = 2,
	Motor_Joint     = 3,
	Prismatic_Joint = 4,
	Revolute_Joint  = 5,
	Spherical_Joint = 6,
	Weld_Joint      = 7,
	Wheel_Joint     = 8,
	Mover_Joint     = 9,
	Pogo_Joint      = 10,
}

Joint_Def :: struct {
	user_data:                rawptr,
	body_id_a:                box3d.BodyId,
	body_id_b:                box3d.BodyId,
	local_frame_a:            Transform,
	local_frame_b:            Transform,
	force_threshold:          f32,
	torque_threshold:         f32,
	constraint_hertz:         f32,
	constraint_damping_ratio: f32,
	draw_scale:               f32,
	collide_connected:        bool,
	internal_value:           i32,
}

Distance_Joint_Def :: struct {
	base:               Joint_Def,
	length:             f32,
	enable_spring:      bool,
	lower_spring_force: f32,
	upper_spring_force: f32,
	hertz:              f32,
	damping_ratio:      f32,
	enable_limit:       bool,
	min_length:         f32,
	max_length:         f32,
	enable_motor:       bool,
	max_motor_force:    f32,
	motor_speed:        f32,
}

// Disables collision between two bodies, nothing else.
Filter_Joint_Def :: struct {
	base: Joint_Def,
}

Motor_Joint_Def :: struct {
	base:                  Joint_Def,
	linear_velocity:       [3]f32,
	max_velocity_force:    f32,
	angular_velocity:      [3]f32,
	max_velocity_torque:   f32,
	linear_hertz:          f32,
	linear_damping_ratio:  f32,
	max_spring_force:      f32,
	angular_hertz:         f32,
	angular_damping_ratio: f32,
	max_spring_torque:     f32,
}

Mover_Joint_Def :: struct {
	base:            Joint_Def,
	linear_velocity: [3]f32,
	max_force:       f32,
}

Parallel_Joint_Def :: struct {
	base:          Joint_Def,
	hertz:         f32,
	damping_ratio: f32,
	max_torque:    f32,
}

Pogo_Joint_Def :: struct {
	base:                  Joint_Def,
	normal:                [3]f32,
	hertz:                 f32,
	damping_ratio:         f32,
	rest_length:           f32,
	max_tension_force:     f32,
	max_compression_force: f32,
	impulse:               f32,
	velocity:              f32,
}

Prismatic_Joint_Def :: struct {
	base:               Joint_Def,
	enable_spring:      bool,
	hertz:              f32,
	damping_ratio:      f32,
	target_translation: f32,
	enable_limit:       bool,
	lower_translation:  f32,
	upper_translation:  f32,
	enable_motor:       bool,
	max_motor_force:    f32,
	motor_speed:        f32,
}

Revolute_Joint_Def :: struct {
	base:             Joint_Def,
	target_angle:     f32,
	enable_spring:    bool,
	hertz:            f32,
	damping_ratio:    f32,
	enable_limit:     bool,
	lower_angle:      f32,
	upper_angle:      f32,
	enable_motor:     bool,
	max_motor_torque: f32,
	motor_speed:      f32,
}

Spherical_Joint_Def :: struct {
	base:               Joint_Def,
	enable_spring:      bool,
	hertz:              f32,
	damping_ratio:      f32,
	target_rotation:    [4]f32, // frame B relative to frame A
	enable_cone_limit:  bool,
	cone_angle:         f32,
	enable_twist_limit: bool,
	lower_twist_angle:  f32,
	upper_twist_angle:  f32,
	enable_motor:       bool,
	max_motor_torque:   f32,
	motor_velocity:     [3]f32, // B's angular velocity minus A's, world frame
}

Weld_Joint_Def :: struct {
	base:                  Joint_Def,
	linear_hertz:          f32,
	angular_hertz:         f32,
	linear_damping_ratio:  f32,
	angular_damping_ratio: f32,
}

Wheel_Joint_Def :: struct {
	base:                     Joint_Def,
	enable_suspension_spring: bool,
	suspension_hertz:         f32,
	suspension_damping_ratio: f32,
	enable_suspension_limit:  bool,
	lower_suspension_limit:   f32,
	upper_suspension_limit:   f32,
	enable_spin_motor:        bool,
	max_spin_torque:          f32,
	spin_speed:               f32,
	enable_steering:          bool,
	steering_hertz:           f32,
	steering_damping_ratio:   f32,
	target_steering_angle:    f32,
	max_steering_torque:      f32,
	enable_steering_limit:    bool,
	lower_steering_limit:     f32,
	upper_steering_limit:     f32,
}
