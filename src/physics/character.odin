// The character controller (src/physics/README.md, Character), ported from Box3D's dynamic mover sample
// (samples/dynamic_mover.cpp, which asks to be vendored). A rotation-locked dynamic capsule: a mover
// joint drives it to a target horizontal velocity under a force cap, a pogo joint (a spring along
// the ground normal) holds it above the ground found by ray probes. Standing on a kinematic body
// attaches the mover joint to it, so platforms carry it. Changes from the sample: the 8 skirt
// directions come from a fixed table (no trig), the state is a plain struct in the block, plus
// coyote time, a jump buffer and a limp mode (held, stunned).
package physics

import box3d "box3d:bindings"
import "unified:dmath"
import "unified:sim"

// What the character's last update found and what it is doing.
Character_Flag :: enum u8 {
	On_Ground, // the probes found ground and the character is not jumping
	Walkable, // that ground is flat enough to walk on
	Jumping, // left the ground on purpose: the pogo doesn't pull it back down
	Limp, // no drive, no pogo (held, stunned)
}
// A character's state flags (Character.flags).
Character_Flags :: bit_set[Character_Flag;u8]

// One character, in the block. Zero value: no character.
Character :: struct {
	body:          Body_Ref,
	move_joint:    Mover_Joint_Ref,
	pogo:          Pogo_Joint_Ref,
	ground:        Body_Link, // what the pogo stands on (zero: air)
	velocity:      [3]f32, // the drive's target, relative to the body it is attached to
	pogo_impulse:  f32,
	pogo_velocity: f32,
	time_sliding:  f32,
	coyote:        u16, // ticks left in which a jump still counts as grounded
	jump_buffer:   u16, // ticks left in which an early jump press fires on landing
	jump_ticks:    u16,
	flags:         Character_Flags,
	_pad:          u8,
}
#assert(size_of(Character) == 64)

// Tuning; constants in game code, not in the block. Seconds and metres.
Character_Def :: struct {
	radius:                 f32,
	half_height:            f32, // capsule segment half length (total height = 2 · (half_height + radius))
	density:                f32,
	category:               u64, // filter bits of the capsule and of the probes
	mask:                   u64,
	material:               u64, // the capsule's user material id (how others recognise a character)
	hit_events:             bool, // the capsule reports contact hit events
	sensor_events:          bool, // sensors see the capsule (Shape_Def.enable_sensor_events)
	max_speed:              f32,
	min_speed:              f32,
	stop_speed:             f32,
	accelerate:             f32,
	friction:               f32, // ground friction, 1/s
	air_steer:              f32, // fraction of the ground acceleration available in the air
	jump_speed:             f32,
	gravity_scale:          f32,
	max_ground_force:       f32,
	max_air_force:          f32,
	pogo_rest:              f32,
	pogo_hertz:             f32,
	pogo_damping:           f32,
	pogo_compression_scale: f32, // pogo force limits as multiples of the character's weight
	pogo_tension_scale:     f32,
	min_ground_normal_y:    f32,
	slide_s:                f32,
	coyote_s:               f32,
	jump_buffer_s:          f32,
	platform_material:      u64, // attach to kinematic bodies with this material (0: any kinematic body)
}

// The sample's defaults (a 1.6 m tall character): a game starts from them and sets its own fields
// (`def := physics.CHARACTER_DEFAULT`, then `def.radius = ...`).
CHARACTER_DEFAULT :: Character_Def {
	radius                 = 0.3,
	half_height            = 0.5,
	density                = 200,
	max_speed              = 6,
	min_speed              = 0.1,
	stop_speed             = 3,
	accelerate             = 20,
	friction               = 8,
	air_steer              = 0.25,
	jump_speed             = 7,
	gravity_scale          = 1.5,
	max_ground_force       = 6000,
	max_air_force          = 1500,
	pogo_rest              = 0.9,
	pogo_hertz             = 3,
	pogo_damping           = 0.8,
	pogo_compression_scale = 100,
	pogo_tension_scale     = 100,
	min_ground_normal_y    = 0.7,
	slide_s                = 0.2,
	coyote_s               = 0.125,
	jump_buffer_s          = 0.125,
}

// Creates the character's body (tagged `tag`, as create_body's) and drive joint at `pos` (the capsule's centre).
character_create :: proc(world: ^World, character: ^Character, def: Character_Def, pos: [3]f32, tag: u64 = 0) {
	character^ = {}
	body_def := transmute(Body_Def)box3d.DefaultBodyDef()
	body_def.type = .Dynamic
	body_def.position = pos
	body_def.gravity_scale = def.gravity_scale
	body_def.motion_locks = {
		angular_x = true,
		angular_y = true,
		angular_z = true,
	}
	body_def.enable_sleep = false
	body_def.name = "character"
	body := box3d.CreateBody(world.id, (^box3d.BodyDef)(&body_def))
	body_created(world, body, tag)
	shape_def := transmute(Shape_Def)box3d.DefaultShapeDef()
	shape_def.density = def.density
	// The joints do all the moving; surface friction would fight them.
	shape_def.base_material.friction = 0
	shape_def.base_material.restitution = 0
	shape_def.base_material.user_material_id = def.material
	if def.category != 0 do shape_def.filter.category = def.category
	if def.mask != 0 do shape_def.filter.mask = def.mask
	shape_def.enable_hit_events = def.hit_events
	shape_def.enable_sensor_events = def.sensor_events
	capsule := Capsule{{0, -def.half_height, 0}, {0, def.half_height, 0}, def.radius}
	box3d.CreateCapsuleShape(body, (^box3d.ShapeDef)(&shape_def), (^box3d.Capsule)(&capsule))
	character.body = ref_of(body)
	character.move_joint = create_move_joint(world, character, def, world.anchor)
}

// Destroys the body (and with it the joints) and clears the character.
character_destroy :: proc(world: ^World, character: ^Character) {
	destroy_body(world, &character.body)
	character^ = {}
}

@(private)
create_move_joint :: proc(
	world: ^World,
	character: ^Character,
	def: Character_Def,
	base: box3d.BodyId,
) -> Mover_Joint_Ref {
	joint_def := transmute(Mover_Joint_Def)box3d.DefaultMoverJointDef()
	joint_def.linear_velocity = character.velocity
	joint_def.max_force = .Limp in character.flags ? 0 : def.max_ground_force
	joint_def.base.body_id_a = base
	joint_def.base.body_id_b = body_id(world, character.body)
	joint_def.base.collide_connected = true
	return {joint_ref_of(box3d.CreateMoverJoint(world.id, (^box3d.MoverJointDef)(&joint_def)))}
}

@(private)
character_weight :: proc(world: ^World, character: ^Character, def: Character_Def) -> f32 {
	gravity := transmute([3]f32)box3d.World_GetGravity(world.id)
	return(
		def.gravity_scale *
		dmath.sqrt(gravity.x * gravity.x + gravity.y * gravity.y + gravity.z * gravity.z) *
		box3d.Body_GetMass(body_id(world, character.body)) \
	)
}

@(private)
drop_pogo :: proc(world: ^World, character: ^Character) {
	destroy_joint(world, &character.pogo)
	character.ground = {}
	character.pogo_impulse = 0
	character.pogo_velocity = 0
}

// An outside impulse lifts the character (pads, hits, its own jump): the pogo stops pulling it down
// until it lands again, from this step on (its joint may already be set up for this tick).
character_launch :: proc(world: ^World, character: ^Character) {
	character.flags -= {.On_Ground, .Walkable}
	character.flags += {.Jumping}
	character.jump_ticks = 0
	character.coyote = 0
	if joint_valid(world, character.pogo) do box3d.PogoJoint_SetMaxTensionForce(joint_id(world, character.pogo), 0)
}

// Limp: no drive force and no pogo (held, stunned); the body just tumbles along. Leaving limp
// starts like a launch, so the character settles back onto the ground through the pogo.
character_set_limp :: proc(world: ^World, character: ^Character, limp: bool) {
	if limp == (.Limp in character.flags) do return
	if limp {
		character.flags += {.Limp}
		character.flags -= {.On_Ground, .Walkable}
		character.velocity = {}
		character.coyote = 0
		character.jump_buffer = 0
		drop_pogo(world, character)
		if joint_valid(world, character.move_joint) {
			id := joint_id(world, character.move_joint)
			box3d.MoverJoint_SetMaxVelocityForce(id, 0)
			box3d.MoverJoint_SetLinearVelocity(id, transmute(box3d.Vec3)[3]f32{})
		}
	} else {
		character.flags -= {.Limp}
		character_launch(world, character)
	}
}

// Moves the character (respawn): velocities zeroed, ground forgotten.
character_teleport :: proc(world: ^World, character: ^Character, pos: [3]f32) {
	id := body_id(world, character.body)
	box3d.Body_SetTransform(id, transmute(box3d.Vec3)pos, transmute(box3d.Quat)[4]f32{0, 0, 0, 1})
	box3d.Body_SetLinearVelocity(id, transmute(box3d.Vec3)[3]f32{})
	box3d.Body_SetAngularVelocity(id, transmute(box3d.Vec3)[3]f32{})
	drop_pogo(world, character)
	character.velocity = {}
	character.flags -= {.On_Ground, .Walkable, .Jumping}
	character.coyote = 0
	character.jump_buffer = 0
}

// Whether the character stands on walkable ground (what jumps and ground movement go by).
character_grounded :: proc(character: ^Character) -> bool {
	return .On_Ground in character.flags && .Walkable in character.flags
}

// Advances the character's drive before the world step. `move` is the wanted horizontal direction in
// world space (x, z), length ≤ 1; `jump` is a fresh press (edge); `speed_scale` scales max_speed (1: as tuned).
// Returns true when it jumped this tick.
character_update :: proc(
	world: ^World,
	character: ^Character,
	def: Character_Def,
	move: [2]f32,
	jump: bool,
	speed_scale: f32,
) -> (
	jumped: bool,
) {
	dt := world.dt
	if .Limp in character.flags do return false
	body := body_id(world, character.body)

	// Jump (from the previous update's ground state), with coyote time and a buffer.
	if jump {
		character.jump_buffer = ticks_u16(def.jump_buffer_s, world.tick_hz)
	}
	if character.jump_buffer > 0 && character.coyote > 0 && .Jumping not_in character.flags {
		surface_vy: f32 = 0
		if body_valid(world, character.ground) {
			surface_vy = box3d.Body_GetLinearVelocity(link_id(world, character.ground)).y
		}
		vy := box3d.Body_GetLinearVelocity(body).y
		delta_speed := dmath.max(0, def.jump_speed - vy) + surface_vy
		box3d.Body_ApplyLinearImpulseToCenter(
			body,
			transmute(box3d.Vec3)[3]f32{0, box3d.Body_GetMass(body) * delta_speed, 0},
			true,
		)
		character_launch(world, character)
		character.jump_buffer = 0
		jumped = true
	} else if character.jump_buffer > 0 {
		character.jump_buffer -= 1
	}

	// Probe for ground: reach further while grounded so the spring finds the ground over a step.
	ray_len := .On_Ground in character.flags ? 2 * def.pogo_rest : def.pogo_rest
	translation := [3]f32{0, -ray_len, 0}
	pos := transmute([3]f32)box3d.Body_GetPosition(body)
	origin := [3]f32{pos.x, pos.y - def.half_height, pos.z}
	filter := Filter{def.category, def.mask, 0}
	self := link(character.body)
	hit, found := world_cast_ray_closest(world, origin, translation, filter, self)
	offset: [3]f32
	if !(found && hit.normal.y >= def.min_ground_normal_y) {
		// The skirt turns with the direction of travel, so ties go to the leading probe.
		vel := transmute([3]f32)box3d.Body_GetLinearVelocity(body)
		heading := [2]f32{vel.x, vel.z}
		heading_len_sq := heading.x * heading.x + heading.y * heading.y
		if heading_len_sq < 1.1920929e-07 {
			heading = {1, 0}
		} else {
			heading_len := dmath.sqrt(heading_len_sq)
			heading = {heading.x / heading_len, heading.y / heading_len}
		}
		side := [2]f32{-heading.y, heading.x}
		best := max(f32)
		for i in 0 ..< 8 {
			skirt_offset := [3]f32 {
				def.radius * (dmath.DIR8[i].x * heading.x + dmath.DIR8[i].y * side.x),
				0,
				def.radius * (dmath.DIR8[i].x * heading.y + dmath.DIR8[i].y * side.y),
			}
			skirt_hit, ok := world_cast_ray_closest(world, origin + skirt_offset, translation, filter, self)
			if ok && skirt_hit.normal.y >= def.min_ground_normal_y {
				gap := abs(skirt_hit.fraction * ray_len - def.pogo_rest)
				if gap < best {
					best = gap
					hit = skirt_hit
					found = true
					offset = skirt_offset
				}
			}
		}
	}

	// Should the jump end?
	if .Jumping in character.flags {
		character.jump_ticks += 1
		// Give the jump time to leave the ground first.
		if character.jump_ticks > 2 && found && dmath.dot3(character.velocity, hit.normal) <= 0 {
			character.flags -= {.Jumping}
		}
	}

	if found {
		if hit.normal.y >= def.min_ground_normal_y do character.flags += {.Walkable}
		else do character.flags -= {.Walkable}
		if .Jumping in character.flags do character.flags -= {.On_Ground}
		else do character.flags += {.On_Ground}
		if .On_Ground in character.flags {
			if .Walkable in character.flags do character.time_sliding = dmath.max(character.time_sliding - dt, 0)
			else do character.time_sliding = dmath.min(character.time_sliding + dt, def.slide_s)
		}
	} else {
		character.flags -= {.On_Ground, .Walkable}
		character.time_sliding = dmath.max(character.time_sliding - dt, 0)
	}
	if .On_Ground in character.flags && .Walkable in character.flags {
		character.coyote = ticks_u16(def.coyote_s, world.tick_hz)
	} else if character.coyote > 0 {
		character.coyote -= 1
	}

	// Attach the drive to a kinematic platform under the character (acts like friction).
	base := world.anchor
	if found {
		ground_id := link_id(world, hit.body)
		if Body_Type(box3d.Body_GetType(ground_id)) == .Kinematic &&
		   (def.platform_material == 0 || hit.material == def.platform_material) {
			base = ground_id
		}
	}
	if !joint_valid(world, character.move_joint) ||
	   box3d.Joint_GetBodyA(joint_id(world, character.move_joint)) != base {
		destroy_joint(world, &character.move_joint)
		character.move_joint = create_move_joint(world, character, def, base)
	}
	move_joint_id := joint_id(world, character.move_joint)
	body_vel := transmute([3]f32)box3d.Body_GetLinearVelocity(body)
	base_vel := transmute([3]f32)box3d.Body_GetLinearVelocity(base)
	character.velocity = {body_vel.x - base_vel.x, body_vel.y - base_vel.y, body_vel.z - base_vel.z}

	// Friction in the horizontal plane; the pogo owns the vertical motion.
	if .On_Ground in character.flags {
		speed := dmath.sqrt(character.velocity.x * character.velocity.x + character.velocity.z * character.velocity.z)
		if speed < def.min_speed {
			character.velocity.x = 0
			character.velocity.z = 0
		} else {
			control := speed < def.stop_speed ? def.stop_speed : speed
			drop := control * def.friction * dt
			ratio := dmath.max(0, speed - drop) / speed
			character.velocity.x *= ratio
			character.velocity.z *= ratio
		}
	}

	max_force: f32
	if .On_Ground in character.flags {
		if def.slide_s > 0 {
			max_force = dmath.clamp(1 - character.time_sliding / def.slide_s, 0, 1) * def.max_ground_force
		} else {
			max_force = .Walkable in character.flags ? def.max_ground_force : 0
		}
	} else {
		max_force = def.max_air_force
	}
	box3d.MoverJoint_SetMaxVelocityForce(move_joint_id, max_force)

	// Accelerate towards the wanted velocity.
	max_speed := speed_scale * def.max_speed
	want := [3]f32{max_speed * move.x, 0, max_speed * move.y}
	want_speed := dmath.sqrt(want.x * want.x + want.z * want.z)
	dir: [3]f32
	if want_speed * want_speed > 1000 * 1.1754944e-38 {
		dir = {want.x / want_speed, 0, want.z / want_speed}
	} else {
		want_speed = 0
	}
	want_speed = dmath.min(want_speed, max_speed)
	add := want_speed - dmath.dot3(character.velocity, dir)
	if add > 0 {
		steer: f32 = .Walkable in character.flags ? 1 : def.air_steer
		accel := dmath.min(steer * def.accelerate * max_speed * dt, add)
		character.velocity.x += accel * dir.x
		character.velocity.z += accel * dir.z
	}

	// The pogo.
	normal := hit.normal
	if found && abs(1 - dmath.dot3(normal, normal)) < 100 * 1.1920929e-07 {
		weight := character_weight(world, character, def)
		tension := .Jumping in character.flags ? 0 : def.pogo_tension_scale * weight
		ground_id := link_id(world, hit.body)
		local_point := transmute([3]f32)box3d.Body_GetLocalPoint(ground_id, transmute(box3d.Vec3)hit.point)
		frame_b := Transform{{offset.x, -def.half_height, offset.z}, {0, 0, 0, 1}}
		if hit.body != character.ground || !joint_valid(world, character.pogo) {
			if joint_valid(world, character.pogo) {
				pogo_id := joint_id(world, character.pogo)
				character.pogo_impulse = box3d.PogoJoint_GetImpulse(pogo_id)
				character.pogo_velocity = box3d.PogoJoint_GetCurrentSpeed(pogo_id)
				destroy_joint(world, &character.pogo)
			}
			character.ground = hit.body
			pogo_def := transmute(Pogo_Joint_Def)box3d.DefaultPogoJointDef()
			pogo_def.base.local_frame_a = {local_point, {0, 0, 0, 1}}
			pogo_def.base.local_frame_b = frame_b
			pogo_def.base.body_id_a = ground_id
			pogo_def.base.body_id_b = body
			pogo_def.base.collide_connected = true
			pogo_def.normal = normal
			pogo_def.rest_length = def.pogo_rest
			pogo_def.hertz = def.pogo_hertz
			pogo_def.damping_ratio = def.pogo_damping
			pogo_def.max_compression_force = def.pogo_compression_scale * weight
			pogo_def.max_tension_force = tension
			// Warm start from the joint that was just destroyed.
			pogo_def.impulse = character.pogo_impulse
			pogo_def.velocity = character.pogo_velocity
			character.pogo = {joint_ref_of(box3d.CreatePogoJoint(world.id, (^box3d.PogoJointDef)(&pogo_def)))}
		} else {
			pogo_id := joint_id(world, character.pogo)
			box3d.Joint_SetLocalFrameA(pogo_id, transmute(box3d.Transform)Transform{local_point, {0, 0, 0, 1}})
			box3d.Joint_SetLocalFrameB(pogo_id, transmute(box3d.Transform)frame_b)
			box3d.PogoJoint_SetNormal(pogo_id, transmute(box3d.Vec3)normal)
			box3d.PogoJoint_SetMaxTensionForce(pogo_id, tension)
			box3d.PogoJoint_SetMaxCompressionForce(pogo_id, def.pogo_compression_scale * weight)
			box3d.PogoJoint_SetSpringHertz(pogo_id, def.pogo_hertz)
			box3d.PogoJoint_SetSpringDampingRatio(pogo_id, def.pogo_damping)
		}
	} else {
		drop_pogo(world, character)
	}

	box3d.MoverJoint_SetLinearVelocity(move_joint_id, transmute(box3d.Vec3)character.velocity)
	return
}

// Seconds as whole ticks (sim.ticks: rounded), clamped to u16.
@(private)
ticks_u16 :: proc(seconds: f32, tick_hz: int) -> u16 {
	return u16(dmath.min(sim.ticks(seconds, tick_hz), u32(max(u16))))
}
