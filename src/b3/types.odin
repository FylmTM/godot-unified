// unified's Box3D API (src/b3/SPEC.md): a hand-written layer over the library's bindings (`box3d:bindings`, upstream's
// C API 1:1) with Odin-style names, [3]f32 vectors and [4]f32 rotations (x, y, z, w), slices, Odin callbacks and
// (value, ok) results. Conversions only: every struct here has the bindings' layout field for field (asserted
// below and tested in tests/b3), so a conversion is a transmute or a pointer cast, never math or a copy loop.
package b3

import box3d "box3d:bindings"

// ---- ids: opaque handles, passed by value (zero is null)

World_Id :: box3d.WorldId
Body_Id :: box3d.BodyId
Shape_Id :: box3d.ShapeId
Joint_Id :: box3d.JointId
Contact_Id :: box3d.ContactId

// ---- opaque or untouched by callers

Hull_Data :: box3d.HullData
Box_Hull :: box3d.BoxHull // `&h.base` is the hull
World_State :: box3d.WorldState // a reusable image buffer (create_world_state)
World_Snapshot :: box3d.WorldSnapshot // zero-initialise; destroy_world_snapshot frees it

// ---- mirrors of the bindings' structs (same layout, Odin names, [3]f32 / [4]f32)

Transform :: struct {
	p: [3]f32,
	q: [4]f32, // x, y, z, w
}

AABB :: struct {
	lower_bound: [3]f32,
	upper_bound: [3]f32,
}

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

Capacity :: struct {
	static_shape_count:  i32,
	dynamic_shape_count: i32,
	static_body_count:   i32,
	dynamic_body_count:  i32,
	contact_count:       i32,
}

World_Def :: struct {
	gravity:                        [3]f32,
	restitution_threshold:          f32,
	restitution_iterations:         i32,
	enable_restitution_propagation: bool,
	hit_event_threshold:            f32,
	contact_hertz:                  f32,
	contact_damping_ratio:          f32,
	contact_speed:                  f32,
	maximum_linear_speed:           f32,
	isotropic_inertia_tolerance:    f32,
	friction_callback:              box3d.FrictionCallback,
	restitution_callback:           box3d.RestitutionCallback,
	enable_sleep:                   bool,
	enable_continuous:              bool,
	worker_count:                   u32,
	enqueue_task:                   box3d.EnqueueTaskCallback,
	finish_task:                    box3d.FinishTaskCallback,
	user_task_context:              rawptr,
	user_data:                      rawptr,
	create_debug_shape:             box3d.CreateDebugShapeCallback,
	destroy_debug_shape:            box3d.DestroyDebugShapeCallback,
	user_debug_shape_context:       rawptr,
	capacity:                       Capacity,
	internal_value:                 i32,
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

Query_Filter :: struct {
	category_bits: u64,
	mask_bits:     u64,
	id:            u64,
	name:          cstring,
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

Joint_Def :: struct {
	user_data:                rawptr,
	body_id_a:                Body_Id,
	body_id_b:                Body_Id,
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

// b3RayResult without its `hit` field (its last): world_cast_ray_closest returns (Ray_Result, ok).
Ray_Result :: struct {
	shape_id:         Shape_Id,
	point:            [3]f32,
	normal:           [3]f32,
	user_material_id: u64,
	fraction:         f32,
	triangle_index:   i32,
	child_index:      i32,
	node_visits:      i32,
	leaf_visits:      i32,
}

Tree_Stats :: struct {
	node_visits: i32,
	leaf_visits: i32,
}

Contact_Begin_Touch_Event :: struct {
	shape_id_a: Shape_Id,
	shape_id_b: Shape_Id,
	contact_id: Contact_Id,
}

Contact_End_Touch_Event :: struct {
	shape_id_a: Shape_Id,
	shape_id_b: Shape_Id,
	contact_id: Contact_Id,
}

Contact_Hit_Event :: struct {
	shape_id_a:         Shape_Id,
	shape_id_b:         Shape_Id,
	contact_id:         Contact_Id,
	point:              [3]f32,
	normal:             [3]f32,
	approach_speed:     f32,
	user_material_id_a: u64,
	user_material_id_b: u64,
}

// The step's contact events, as slices into Box3D's memory: valid until the next step.
Contact_Events :: struct {
	begin_events: []Contact_Begin_Touch_Event,
	end_events:   []Contact_End_Touch_Event,
	hit_events:   []Contact_Hit_Event,
}

// Called for each shape an overlap query finds; return false to stop. `user` is the query's.
Overlap_Result_Fcn :: #type proc(shape_id: Shape_Id, user: rawptr) -> bool

// Called for each shape a ray hits. Return -1 to ignore the shape, 0 to stop, `fraction` to clip the ray (closest
// hit), 1 to go on. `user` is the query's.
Cast_Result_Fcn :: #type proc(
	shape_id: Shape_Id,
	point: [3]f32,
	normal: [3]f32,
	fraction: f32,
	user_material_id: u64,
	triangle_index: i32,
	child_index: i32,
	user: rawptr,
) -> f32

// Same size as the bindings' structs (tests/b3 checks every field's offset and size too). `[3]f32` and `[4]f32`
// have Vec3's and Quat's layout: f32s, 4-byte aligned.
#assert(size_of([3]f32) == size_of(box3d.Vec3) && align_of([3]f32) == align_of(box3d.Vec3))
#assert(size_of([4]f32) == size_of(box3d.Quat) && align_of([4]f32) == align_of(box3d.Quat))
#assert(size_of(Transform) == size_of(box3d.Transform))
#assert(size_of(AABB) == size_of(box3d.AABB))
#assert(size_of(Body_Type) == size_of(box3d.BodyType))
#assert(i32(Body_Type.Static_Body) == i32(box3d.BodyType.staticBody))
#assert(i32(Body_Type.Kinematic_Body) == i32(box3d.BodyType.kinematicBody))
#assert(i32(Body_Type.Dynamic_Body) == i32(box3d.BodyType.dynamicBody))
#assert(size_of(Motion_Locks) == size_of(box3d.MotionLocks))
#assert(size_of(Capacity) == size_of(box3d.Capacity))
#assert(size_of(World_Def) == size_of(box3d.WorldDef))
#assert(size_of(Body_Def) == size_of(box3d.BodyDef))
#assert(size_of(Surface_Material) == size_of(box3d.SurfaceMaterial))
#assert(size_of(Filter) == size_of(box3d.Filter))
#assert(size_of(Shape_Def) == size_of(box3d.ShapeDef))
#assert(size_of(Query_Filter) == size_of(box3d.QueryFilter))
#assert(size_of(Sphere) == size_of(box3d.Sphere))
#assert(size_of(Capsule) == size_of(box3d.Capsule))
#assert(size_of(Joint_Def) == size_of(box3d.JointDef))
#assert(size_of(Motor_Joint_Def) == size_of(box3d.MotorJointDef))
#assert(size_of(Mover_Joint_Def) == size_of(box3d.MoverJointDef))
#assert(size_of(Pogo_Joint_Def) == size_of(box3d.PogoJointDef))
#assert(offset_of(box3d.RayResult, hit) == offset_of(Ray_Result, leaf_visits) + size_of(i32))
#assert(size_of(Ray_Result) <= size_of(box3d.RayResult))
#assert(size_of(Tree_Stats) == size_of(box3d.TreeStats))
#assert(size_of(Contact_Begin_Touch_Event) == size_of(box3d.ContactBeginTouchEvent))
#assert(size_of(Contact_End_Touch_Event) == size_of(box3d.ContactEndTouchEvent))
#assert(size_of(Contact_Hit_Event) == size_of(box3d.ContactHitEvent))
