// The ragdoll (src/physics/README.md, Ragdoll), ported from Box3D's sample ragdoll (shared/human.c): 12 capsule
// bones in a 1.8 m human's rest pose, each held to its parent by a joint with the human's limits (spherical with a
// swing cone and a twist range at the spine, neck, hips and shoulders; revolute with an angle range at the knees and
// elbows), whose motor at zero speed is the joint's friction and whose optional spring pulls it back toward the pose
// the ragdoll was made in. Changes from the sample:
//
// - it faces +Z (a Character's, quat_yaw's forward) with its left side at +X: the sample's human faces -Z, and its
//   `_l` bones are on its right, so the table is the sample's turned a half turn about +Y, its sides named anew;
// - each joint's spring targets the pose the ragdoll was made in (the sample's target each joint's zero, a crouch);
// - the bones that never touch each other are kept apart by filter joints only (the sample adds a collision group the
//   game would have to number per ragdoll);
// - it can be made turned, in a pose of the game's (a character's at the moment it falls) and at any scale;
// - its state is a plain struct in the block.
package physics

import "unified:dmath"

// A ragdoll's bones, parents before children (each bone's joint holds it to its parent: Ragdoll.sockets and .hinges).
Ragdoll_Bone :: enum u8 {
	Pelvis, // the root: no joint
	Spine, // on the pelvis
	Chest, // on the spine
	Head, // on the chest
	Left_Thigh, // on the pelvis, at +X
	Left_Calf, // on the left thigh (a revolute knee; the foot is a second capsule of the calf)
	Right_Thigh,
	Right_Calf,
	Left_Upper_Arm, // on the chest
	Left_Forearm, // on the left upper arm (a revolute elbow)
	Right_Upper_Arm,
	Right_Forearm,
}

// How many filter joints a ragdoll keeps (Ragdoll.filters): the pairs of its bones that would touch without being
// jointed (the thighs, the spine and each thigh, the head and each upper arm).
RAGDOLL_FILTERS :: 5

// The bones a spherical joint holds to their parents (Ragdoll.sockets), named by the bone: the spine on the pelvis, the
// chest on the spine, the head on the chest, the thighs on the pelvis and the upper arms on the chest.
Ragdoll_Socket :: enum u8 {
	Spine,
	Chest,
	Head,
	Left_Thigh,
	Right_Thigh,
	Left_Upper_Arm,
	Right_Upper_Arm,
}

// The bones a revolute joint holds to their parents (Ragdoll.hinges), named by the bone: the calves (the knees) and the
// forearms (the elbows).
Ragdoll_Hinge :: enum u8 {
	Left_Calf,
	Right_Calf,
	Left_Forearm,
	Right_Forearm,
}

// One ragdoll, in the block: its bodies, each bone's joint to its parent by type (the pelvis, the root, has none; a
// bone's untyped one: ragdoll_joint) and the filter joints between bones. Zero value: no ragdoll. check_refs and
// destroy_refs find every ref in it, as in any value of the block.
Ragdoll :: struct {
	bones:   [Ragdoll_Bone]Body_Ref,
	sockets: [Ragdoll_Socket]Spherical_Joint_Ref,
	hinges:  [Ragdoll_Hinge]Revolute_Joint_Ref,
	filters: [RAGDOLL_FILTERS]Filter_Joint_Ref,
}
#assert(size_of(Ragdoll) == 224)

// Tuning; constants in game code, not in the block. Newton-metres, hertz, kg/m³, metres.
Ragdoll_Def :: struct {
	friction_torque: f32, // the torque each joint's motor holds against (the arms take a share of it: their bones' table)
	hertz:           f32, // the joints' springs toward the pose it was made in (0: no spring, a limp ragdoll)
	damping_ratio:   f32, // the springs' damping (1: critical)
	density:         f32, // the bones' (the feet's capsules half of it); 1000, water's, makes the sample's 146 kg
	scale:           f32, // every length: the bones' places, capsules and joint anchors (1: the sample's 1.8 m human)
	category:        u64, // filter bits of every bone (0: Box3D's default)
	mask:            u64,
	material:        u64, // every bone's user material id (how others recognise a ragdoll)
	hit_events:      bool, // the bones report contact hit events
	sensor_events:   bool, // sensors see the bones (Shape_Def.enable_sensor_events)
}

// The sample's numbers (its ragdoll on a box: 5 N·m of friction, a 1 Hz spring at 0.7 damping, water's density, full
// size): a game starts from them and sets its own fields (`def := physics.RAGDOLL_DEFAULT`, then `def.hertz = 0`).
RAGDOLL_DEFAULT :: Ragdoll_Def {
	friction_torque = 5,
	hertz           = 1,
	damping_ratio   = 0.7,
	density         = 1000,
	scale           = 1,
}

// Each bone's world transform in the ragdoll's rest pose, standing on `pos` (the point between its feet; the pelvis
// is about `scale` metres above it), facing +Z turned by `rotation` (x, y, z, w): what ragdoll_create makes without a
// pose, and the start of one a game poses.
ragdoll_rest_pose :: proc(
	pos: [3]f32,
	rotation := [4]f32{0, 0, 0, 1},
	scale: f32 = 1,
) -> (
	pose: [Ragdoll_Bone]Transform,
) {
	for bone in Ragdoll_Bone {
		frame := RAGDOLL_BONES[bone].frame // the sample's, facing -Z: turned a half turn about +Y
		turned := dmath.quat_mul(rotation, HALF_TURN_Y)
		pose[bone] = {pos + dmath.quat_rotate(turned, frame.p * scale), unit_quat(dmath.quat_mul(turned, frame.q))}
	}
	return pose
}

// Creates the ragdoll's bodies (each tagged `tag`, as create_body's), joints and filter joints: in its rest pose on
// `pos` turned by `rotation` (ragdoll_rest_pose), or with each bone at `pose`'s world transform (a character's at the
// moment it falls: then `pos` and `rotation` are unused). The joints' springs target that pose. Its bodies are made in
// Ragdoll_Bone order, then its joints, then its filter joints: a fixed creation order, as the block's bodies need.
ragdoll_create :: proc(
	world: ^World,
	ragdoll: ^Ragdoll,
	def: Ragdoll_Def,
	pos: [3]f32,
	rotation := [4]f32{0, 0, 0, 1},
	tag: u64 = 0,
	pose: Maybe([Ragdoll_Bone]Transform) = nil,
	loc := #caller_location,
) {
	assert(def.scale > 0, "a ragdoll's scale must be positive (RAGDOLL_DEFAULT's is 1)", loc)
	ragdoll^ = {}
	transforms, posed := pose.?
	if !posed do transforms = ragdoll_rest_pose(pos, rotation, def.scale)
	for bone in Ragdoll_Bone {
		spec := &RAGDOLL_BONES[bone]
		body_def := body_def(.Dynamic, transforms[bone].p, transforms[bone].q)
		body_def.name = spec.name
		ref := create_body(world, body_def, tag, loc)
		ragdoll.bones[bone] = ref
		shape_def := default_shape_def()
		shape_def.density = def.density
		if def.category != 0 do shape_def.filter.category = def.category
		if def.mask != 0 do shape_def.filter.mask = def.mask
		shape_def.base_material.friction = spec.friction
		shape_def.base_material.rolling_resistance = spec.rolling_resistance
		shape_def.base_material.user_material_id = def.material
		shape_def.enable_hit_events = def.hit_events
		shape_def.enable_sensor_events = def.sensor_events
		capsules, count := ragdoll_capsules(bone, def.scale)
		create_capsule_shape(world, ref, shape_def, capsules[0], loc)
		if count > 1 {
			shape_def.density = def.density / 2 // the foot
			create_capsule_shape(world, ref, shape_def, capsules[1], loc)
		}
	}
	for bone in Ragdoll_Bone {
		spec := &RAGDOLL_BONES[bone]
		if bone == .Pelvis do continue
		parent, child := link(ragdoll.bones[spec.parent]), link(ragdoll.bones[bone])
		frame_a := Transform{spec.joint_a.p * def.scale, unit_quat(spec.joint_a.q)}
		frame_b := Transform{spec.joint_b.p * def.scale, unit_quat(spec.joint_b.q)}
		// The pose made: frame B's rotation relative to frame A's, each in the world (what the spring holds).
		frame_a_world := dmath.quat_mul(transforms[spec.parent].q, frame_a.q)
		frame_b_world := dmath.quat_mul(transforms[bone].q, frame_b.q)
		relative := dmath.quat_mul(quat_conjugate(frame_a_world), frame_b_world)
		slot, revolute, _ := joint_slot(bone)
		if revolute {
			joint_def := default_revolute_joint_def()
			joint_def.base.local_frame_a, joint_def.base.local_frame_b = frame_a, frame_b
			joint_def.enable_limit = true
			joint_def.lower_angle, joint_def.upper_angle = spec.twist[0], spec.twist[1]
			joint_def.enable_spring = def.hertz > 0
			joint_def.hertz, joint_def.damping_ratio = def.hertz, def.damping_ratio
			joint_def.enable_motor = true
			joint_def.max_motor_torque = spec.friction_share * def.friction_torque
			joint := create_revolute_joint(world, parent, child, joint_def, loc)
			// The made pose's angle, as Box3D measures it (about frame A's z, from the bodies as they are).
			revolute_joint_set_target_angle(world, joint, revolute_joint_angle(world, joint))
			ragdoll.hinges[Ragdoll_Hinge(slot)] = joint
		} else {
			joint_def := default_spherical_joint_def()
			joint_def.base.local_frame_a, joint_def.base.local_frame_b = frame_a, frame_b
			joint_def.enable_cone_limit = true
			joint_def.cone_angle = spec.swing
			joint_def.enable_twist_limit = true
			joint_def.lower_twist_angle, joint_def.upper_twist_angle = spec.twist[0], spec.twist[1]
			joint_def.enable_spring = def.hertz > 0
			joint_def.hertz, joint_def.damping_ratio = def.hertz, def.damping_ratio
			joint_def.target_rotation = unit_quat(relative)
			joint_def.enable_motor = true
			joint_def.max_motor_torque = spec.friction_share * def.friction_torque
			ragdoll.sockets[Ragdoll_Socket(slot)] = create_spherical_joint(world, parent, child, joint_def, loc)
		}
	}
	for pair, i in RAGDOLL_FILTER_PAIRS {
		ragdoll.filters[i] = create_filter_joint(
			world,
			link(ragdoll.bones[pair[0]]),
			link(ragdoll.bones[pair[1]]),
			default_filter_joint_def(),
			loc,
		)
	}
}

// Destroys the ragdoll's joints and bodies (whatever of them is still alive) and clears it: its joints in bone order,
// then its filter joints, then its bodies.
ragdoll_destroy :: proc(world: ^World, ragdoll: ^Ragdoll) {
	for bone in Ragdoll_Bone {
		slot, revolute, has_joint := joint_slot(bone)
		if !has_joint do continue
		if revolute do destroy_joint(world, &ragdoll.hinges[Ragdoll_Hinge(slot)])
		else do destroy_joint(world, &ragdoll.sockets[Ragdoll_Socket(slot)])
	}
	destroy_refs(world, ragdoll)
	ragdoll^ = {}
}

// The type of a bone's joint to its parent: .Revolute at the knees and elbows (Ragdoll.hinges), .Spherical elsewhere
// (Ragdoll.sockets); `has_joint` false for the pelvis, the root.
ragdoll_joint_type :: proc "contextless" (bone: Ragdoll_Bone) -> (type: Joint_Type, has_joint: bool) {
	_, revolute, ok := joint_slot(bone)
	if !ok do return {}, false
	return revolute ? .Revolute : .Spherical, true
}

// A bone's joint to its parent as an untyped ref, for the generic joint_* procs (zero for the pelvis, the root).
ragdoll_joint :: proc "contextless" (ragdoll: ^Ragdoll, bone: Ragdoll_Bone) -> Joint_Ref {
	slot, revolute, has_joint := joint_slot(bone)
	if !has_joint do return {}
	return revolute ? ragdoll.hinges[Ragdoll_Hinge(slot)].joint : ragdoll.sockets[Ragdoll_Socket(slot)].joint
}

// A bone's capsules at `scale` (Ragdoll_Def.scale), body-local (what a view draws at the bone's body): its own, and a
// calf's foot as a second one (`count` 2; else 1).
ragdoll_capsules :: proc "contextless" (bone: Ragdoll_Bone, scale: f32 = 1) -> (capsules: [2]Capsule, count: int) {
	capsules = RAGDOLL_BONES[bone].capsules
	count = capsules[1].radius > 0 ? 2 : 1
	for &capsule in capsules {
		capsule = {capsule.center1 * scale, capsule.center2 * scale, capsule.radius * scale}
	}
	return capsules, count
}

// Sets the torque every joint's motor holds against (Ragdoll_Def.friction_torque: each bone takes its share). Joints
// gone (a ragdoll partly destroyed, or none) are skipped.
ragdoll_set_friction_torque :: proc(world: ^World, ragdoll: ^Ragdoll, torque: f32) {
	for bone in Ragdoll_Bone {
		slot, revolute, has_joint := joint_slot(bone)
		if !has_joint || !joint_valid(world, ragdoll_joint(ragdoll, bone)) do continue
		share := RAGDOLL_BONES[bone].friction_share * torque
		if revolute {
			revolute_joint_set_max_motor_torque(world, ragdoll.hinges[Ragdoll_Hinge(slot)], share)
		} else {
			spherical_joint_set_max_motor_torque(world, ragdoll.sockets[Ragdoll_Socket(slot)], share)
		}
	}
}

// Sets the joints' springs toward the pose the ragdoll was made in (Ragdoll_Def.hertz; 0 turns them off). Joints gone
// are skipped.
ragdoll_set_spring_hertz :: proc(world: ^World, ragdoll: ^Ragdoll, hertz: f32) {
	for bone in Ragdoll_Bone {
		slot, revolute, has_joint := joint_slot(bone)
		if !has_joint || !joint_valid(world, ragdoll_joint(ragdoll, bone)) do continue
		if revolute {
			hinge := ragdoll.hinges[Ragdoll_Hinge(slot)]
			revolute_joint_enable_spring(world, hinge, hertz > 0)
			revolute_joint_set_spring_hertz(world, hinge, hertz)
		} else {
			socket := ragdoll.sockets[Ragdoll_Socket(slot)]
			spherical_joint_enable_spring(world, socket, hertz > 0)
			spherical_joint_set_spring_hertz(world, socket, hertz)
		}
	}
}

// Sets the springs' damping ratio (Ragdoll_Def.damping_ratio). Joints gone are skipped.
ragdoll_set_spring_damping_ratio :: proc(world: ^World, ragdoll: ^Ragdoll, damping_ratio: f32) {
	for bone in Ragdoll_Bone {
		slot, revolute, has_joint := joint_slot(bone)
		if !has_joint || !joint_valid(world, ragdoll_joint(ragdoll, bone)) do continue
		if revolute {
			revolute_joint_set_spring_damping_ratio(world, ragdoll.hinges[Ragdoll_Hinge(slot)], damping_ratio)
		} else {
			spherical_joint_set_spring_damping_ratio(world, ragdoll.sockets[Ragdoll_Socket(slot)], damping_ratio)
		}
	}
}

// Moves the ragdoll as one rigid body would: each bone gets `linear` (m/s, the pelvis's centre of mass) plus
// `angular` × its centre of mass's offset from the pelvis's, and the angular velocity `angular` (rad/s): a ragdoll
// thrown, or taking over a character's motion as it falls. Bodies gone are skipped (the pelvis gone: about the origin).
ragdoll_set_velocity :: proc(world: ^World, ragdoll: ^Ragdoll, linear: [3]f32, angular := [3]f32{}) {
	pivot: [3]f32
	if body_valid(world, link(ragdoll.bones[.Pelvis])) do pivot = body_world_center(world, ragdoll.bones[.Pelvis])
	for bone in ragdoll.bones {
		if !body_valid(world, link(bone)) do continue
		offset := body_world_center(world, bone) - pivot
		spin := [3]f32 {
			angular.y * offset.z - angular.z * offset.y,
			angular.z * offset.x - angular.x * offset.z,
			angular.x * offset.y - angular.y * offset.x,
		}
		body_set_linear_velocity(world, bone, linear + spin)
		body_set_angular_velocity(world, bone, angular)
	}
}

// Makes every bone a bullet (continuous collision against dynamic bodies too), or not. Bodies gone are skipped.
ragdoll_set_bullet :: proc(world: ^World, ragdoll: ^Ragdoll, flag: bool) {
	for bone in ragdoll.bones {
		if body_valid(world, link(bone)) do body_set_bullet(world, bone, flag)
	}
}

// One bone of the sample's human: its rest pose (relative to the point between the feet), capsules, surface, and its
// joint to its parent (frames on the parent and on itself, the swing cone and the twist or angle range in radians, its
// share of the friction torque).
@(private)
Ragdoll_Bone_Spec :: struct {
	name:               cstring,
	parent:             Ragdoll_Bone,
	frame:              Transform,
	capsules:           [2]Capsule, // the second (a foot) when its radius isn't 0
	friction:           f32,
	rolling_resistance: f32,
	joint_a, joint_b:   Transform, // normalized at creation (unit_quat), as the sample does
	swing:              f32,
	twist:              [2]f32,
	friction_share:     f32,
}

@(private)
DEG :: 0.017453292519943295 // radians per degree (folded at compile time)

// The sample's human (shared/human.c), its numbers as it writes them, facing -Z (ragdoll_rest_pose turns it), its sides
// named anew: the sample's `_l` bones are on its right (Right_* here).
@(private, rodata)
RAGDOLL_BONES := [Ragdoll_Bone]Ragdoll_Bone_Spec {
	.Pelvis = {
		name = "pelvis",
		frame = {{0, 0.996219, -0.023868}, {1, 0, 0, 0}},
		capsules = {0 = {{0.04, 0.000001, 0}, {-0.04, -0.000001, 0}, 0.15}},
		friction = 0.6,
		rolling_resistance = 0.1,
		friction_share = 1,
	},
	.Spine = {
		name = "spine",
		parent = .Pelvis,
		frame = {{0, 1.017288, -0.024882}, {1, 0, 0, 0}},
		capsules = {0 = {{0.029876, -0.146581, 0.00626}, {-0.029876, -0.146574, 0.00626}, 0.145663}},
		friction = 0.5,
		rolling_resistance = 0.1,
		joint_a = {{0, -0.021069, 0.001014}, {-0.642737, 0, 0, -0.766087}},
		joint_b = {{0, 0, 0}, {-0.707107, 0, 0, -0.707107}},
		swing = 35 * DEG,
		twist = {-17.5 * DEG, 17.5 * DEG},
		friction_share = 1,
	},
	.Chest = {
		name = "chest",
		parent = .Spine,
		frame = {{0, 1.267766, -0.02232}, {1, 0, 0, 0}},
		capsules = {0 = {{0.063996, -0.117434, -0.040199}, {-0.063996, -0.117432, -0.040199}, 0.165004}},
		friction = 0.5,
		rolling_resistance = 0.1,
		joint_a = {{0, -0.250478, -0.002562}, {-0.642766, 0, 0, -0.766063}},
		joint_b = {{0, 0, 0}, {-0.707107, 0, 0, -0.707107}},
		swing = 35 * DEG,
		twist = {-17.5 * DEG, 17.5 * DEG},
		friction_share = 1,
	},
	.Head = {
		name = "head",
		parent = .Chest,
		frame = {{0, 1.498783, 0.024462}, {0.987879, 0, 0, 0.155228}},
		capsules = {0 = {{0, -0.21234, 0}, {0, -0.08734, 0}, 0.11}},
		friction = 0.2,
		rolling_resistance = 0.05,
		joint_a = {{0, -0.231017, -0.046781}, {-0.516157, -0.000002, 0.000003, -0.856494}},
		joint_b = {{0, 0, 0}, {-0.707108, -0.000002, 0.000002, -0.707106}},
		swing = 30 * DEG,
		twist = {-17.5 * DEG, 17.5 * DEG},
		friction_share = 1,
	},
	.Right_Thigh = {
		name = "right thigh",
		parent = .Pelvis,
		frame = {{0.092175, 0.971562, -0.011177}, {0.471412, 0.52951, -0.499888, -0.497495}},
		capsules = {0 = {{-0.047269, 0.000001, 0}, {-0.379769, 0.000005, 0}, 0.091539}},
		friction = 0.6,
		rolling_resistance = 0.1,
		joint_a = {{0.092175, 0.024656, -0.012691}, {-0.460186, -0.365368, -0.637662, 0.498118}},
		joint_b = {{0, 0, 0}, {-0.499997, -0.500003, 0.500002, 0.499998}},
		swing = 30 * DEG,
		twist = {-10 * DEG, 10 * DEG},
		friction_share = 1,
	},
	.Right_Calf = {
		name           = "right calf",
		parent         = .Right_Thigh,
		frame          = {{0.11872, 0.534541, -0.035362}, {0.521188, 0.480597, -0.54638, -0.445935}},
		capsules       = {
			{{-0.445, 0.000001, 0}, {0.005, -0.000001, 0}, 0.08},
			{{-0.456371, 0.129321, 0.000013}, {-0.359977, 0.014394, 0.000013}, 0.07},
		},
		friction       = 0.1,
		joint_a        = {{-0.438494, -0.000175, 0}, {0.344866, -0.938652, 0.000002, -0.000008}},
		joint_b        = {{0, 0, 0}, {-0.008182, -0.999967, 0.000001, -0.000007}},
		twist          = {-30 * DEG, 30 * DEG},
		friction_share = 1,
	},
	.Left_Thigh = {
		name = "left thigh",
		parent = .Pelvis,
		frame = {{-0.092175, 0.971562, -0.011177}, {-0.497495, 0.499888, 0.52951, -0.471412}},
		capsules = {0 = {{0.047269, -0.000001, 0}, {0.379769, -0.000005, 0}, 0.092587}},
		friction = 0.6,
		rolling_resistance = 0.1,
		joint_a = {{-0.092175, 0.024656, -0.012691}, {0.380666, 0.491846, 0.488644, -0.611889}},
		joint_b = {{0, 0, 0}, {-0.500002, 0.499998, -0.499998, 0.500002}},
		swing = 30 * DEG,
		twist = {-10 * DEG, 10 * DEG},
		friction_share = 1,
	},
	.Left_Calf = {
		name           = "left calf",
		parent         = .Left_Thigh,
		frame          = {{-0.11872, 0.534541, -0.035362}, {-0.445935, 0.54638, 0.480597, -0.521188}},
		capsules       = {
			{{0.445, -0.000002, 0.000003}, {-0.005, 0, 0.000003}, 0.08},
			{{0.369113, -0.00683, 0.000017}, {0.465507, -0.121757, 0.000017}, 0.07},
		},
		friction       = 0.1,
		joint_a        = {{0.438494, 0.000175, 0}, {0.000007, 0.000005, -0.34486, -0.938654}},
		joint_b        = {{0, 0, 0}, {0.000006, 0.000005, 0.008188, -0.999966}},
		twist          = {-30 * DEG, 30 * DEG},
		friction_share = 1,
	},
	.Right_Upper_Arm = {
		name = "right upper arm",
		parent = .Chest,
		frame = {{0.185817, 1.44363, 0.031306}, {0.56022, -0.307179, 0.366233, -0.676512}},
		capsules = {0 = {{0.296038, 0.004386, -0.000794}, {-0.016086, 0.004384, -0.016127}, 0.065}},
		friction = 0.6,
		rolling_resistance = 0.1,
		joint_a = {{0.185817, -0.175865, -0.053625}, {-0.559466, -0.213784, -0.670199, 0.438323}},
		joint_b = {{0, 0, 0}, {-0.500953, -0.502617, -0.509318, -0.486844}},
		swing = 45 * DEG,
		twist = {-20 * DEG, 20 * DEG},
		friction_share = 0.8,
	},
	.Right_Forearm = {
		name = "right forearm",
		parent = .Right_Upper_Arm,
		frame = {{0.347683, 1.193455, 0.029378}, {0.406736, -0.493012, 0.089135, -0.763911}},
		capsules = {0 = {{0.312329, -0.008256, -0.016454}, {0.033153, 0.008259, -0.002741}, 0.06}},
		friction = 0.3,
		rolling_resistance = 0.1,
		joint_a = {{0.297979, 0.000361, 0}, {0.916726, 0.399352, 0.000839, -0.011456}},
		joint_b = {{0, 0, 0}, {0.999922, -0.003857, 0.004659, -0.010908}},
		twist = {-35 * DEG, 35 * DEG},
		friction_share = 0.06,
	},
	.Left_Upper_Arm = {
		name = "left upper arm",
		parent = .Chest,
		frame = {{-0.185817, 1.44363, 0.031306}, {0.676512, 0.366233, 0.307179, 0.56022}},
		capsules = {0 = {{-0.300237, -0.000001, -0.000319}, {0.011887, 0.000001, 0.015013}, 0.065}},
		friction = 0.6,
		rolling_resistance = 0.1,
		joint_a = {{-0.185817, -0.175865, -0.053625}, {0.213793, 0.559449, 0.438334, -0.670204}},
		joint_b = {{0, 0, 0}, {-0.509319, 0.486843, 0.500954, -0.502617}},
		swing = 45 * DEG,
		twist = {-20 * DEG, 20 * DEG},
		friction_share = 0.8,
	},
	.Left_Forearm = {
		name = "left forearm",
		parent = .Left_Upper_Arm,
		frame = {{-0.347683, 1.193455, 0.029378}, {0.763911, 0.089135, 0.493012, 0.406736}},
		capsules = {0 = {{-0.312649, -0.000003, 0.016471}, {-0.032986, 0, 0.002732}, 0.06}},
		friction = 0.3,
		rolling_resistance = 0.1,
		joint_a = {{-0.297979, -0.000361, 0}, {-0.405444, 0.914059, 0.010541, 0.000852}},
		joint_b = {{0, 0, 0}, {-0.002794, 0.999936, 0.010042, 0.004364}},
		twist = {-35 * DEG, 35 * DEG},
		friction_share = 0.06,
	},
}

// A half turn about +Y: the sample's -Z-facing human turned to face +Z.
@(private)
HALF_TURN_Y :: [4]f32{0, 1, 0, 0}

// The bone pairs a filter joint keeps apart: neither jointed nor meant to touch.
@(private, rodata)
RAGDOLL_FILTER_PAIRS := [RAGDOLL_FILTERS][2]Ragdoll_Bone {
	{.Left_Thigh, .Right_Thigh},
	{.Head, .Left_Upper_Arm},
	{.Head, .Right_Upper_Arm},
	{.Spine, .Left_Thigh}, // the sample's collision group
	{.Spine, .Right_Thigh},
}

// The bone each socket and each hinge holds to its parent.
@(private, rodata)
RAGDOLL_SOCKET_BONES := [Ragdoll_Socket]Ragdoll_Bone {
	.Spine           = .Spine,
	.Chest           = .Chest,
	.Head            = .Head,
	.Left_Thigh      = .Left_Thigh,
	.Right_Thigh     = .Right_Thigh,
	.Left_Upper_Arm  = .Left_Upper_Arm,
	.Right_Upper_Arm = .Right_Upper_Arm,
}

@(private, rodata)
RAGDOLL_HINGE_BONES := [Ragdoll_Hinge]Ragdoll_Bone {
	.Left_Calf     = .Left_Calf,
	.Right_Calf    = .Right_Calf,
	.Left_Forearm  = .Left_Forearm,
	.Right_Forearm = .Right_Forearm,
}

// Where a bone's joint to its parent is in a Ragdoll: its index in .hinges (`revolute`) or in .sockets; `has_joint`
// false for the pelvis.
@(private)
joint_slot :: proc "contextless" (bone: Ragdoll_Bone) -> (slot: int, revolute: bool, has_joint: bool) {
	for hinge_bone, hinge in RAGDOLL_HINGE_BONES {
		if hinge_bone == bone do return int(hinge), true, true
	}
	for socket_bone, socket in RAGDOLL_SOCKET_BONES {
		if socket_bone == bone do return int(socket), false, true
	}
	return 0, false, false
}

// `quat` scaled to unit length (times 1 / sqrt of its squared length, as b3NormalizeQuat does).
@(private)
unit_quat :: proc(quat: [4]f32) -> [4]f32 {
	scale := 1 / dmath.sqrt(quat.x * quat.x + quat.y * quat.y + quat.z * quat.z + quat.w * quat.w)
	return quat * scale
}

// The inverse rotation of a unit quaternion.
@(private)
quat_conjugate :: proc(quat: [4]f32) -> [4]f32 {
	return {-quat.x, -quat.y, -quat.z, quat.w}
}
