// The dynamic character mover (spec/physics.md), ported from Box3D's reference sample
// (samples/dynamic_mover.cpp, which asks to be vendored). A rotation-locked dynamic capsule: a mover
// joint drives it to a target horizontal velocity under a force cap, a pogo joint (a spring along
// the ground normal) holds it above the ground found by ray probes. Standing on a kinematic body
// attaches the mover joint to it, so platforms carry it. Changes from the sample: the 8 skirt
// directions come from a fixed table (no trig), the state is a plain struct in the block, plus
// coyote time, a jump buffer and a limp mode (held, stunned).
package physics

import b3 "../box3d"
import "../dmath"

Mover_Flag :: enum u8 {
	On_Ground, // the probes found ground and the mover is not jumping
	Walkable, // that ground is flat enough to walk on
	Jumping, // left the ground on purpose: the pogo doesn't pull it back down
	Limp, // no drive, no pogo (held, stunned)
}
Mover_Flags :: bit_set[Mover_Flag;u8]

// One character, in the block. Zero value: no mover.
Mover :: struct {
	body:          Body_Ref,
	move_joint:    Joint_Ref,
	pogo:          Joint_Ref,
	ground:        Body_Link, // what the pogo stands on (zero: air)
	velocity:      [3]f32, // the drive's target, relative to the body it is attached to
	pogo_impulse:  f32,
	pogo_velocity: f32,
	time_sliding:  f32,
	coyote:        u16, // ticks left in which a jump still counts as grounded
	jump_buffer:   u16, // ticks left in which an early jump press fires on landing
	jump_ticks:    u16,
	flags:         Mover_Flags,
	_pad:          u8,
}
#assert(size_of(Mover) == 64)

// Tuning; constants in game code, not in the block. Seconds and metres.
Mover_Def :: struct {
	radius:                 f32,
	half_height:            f32, // capsule segment half length (total height = 2 · (half_height + radius))
	density:                f32,
	category:               u64, // filter bits of the capsule and of the probes
	mask:                   u64,
	material:               u64, // the capsule's user material id (how others recognise a mover)
	hit_events:             bool, // the capsule reports contact hit events
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
	pogo_compression_scale: f32, // pogo force limits as multiples of the mover's weight
	pogo_tension_scale:     f32,
	min_ground_normal_y:    f32,
	slide_s:                f32,
	coyote_s:               f32,
	jump_buffer_s:          f32,
	platform_material:      u64, // attach to kinematic bodies with this material (0: any kinematic body)
}

// The sample's defaults (a 1.6 m tall character).
MOVER_DEFAULT :: Mover_Def {
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

// cos and sin of i·45°, the skirt probe directions.
@(private)
SKIRT_C := [8]f32{1, 0.70710677, 0, -0.70710677, -1, -0.70710677, 0, 0.70710677}
@(private)
SKIRT_S := [8]f32{0, 0.70710677, 1, 0.70710677, 0, -0.70710677, -1, -0.70710677}

// Creates the mover's body and drive joint at `pos` (the capsule's centre). Needs Settings.anchor.
mover_create :: proc(w: ^World, m: ^Mover, def: ^Mover_Def, pos: [3]f32) {
	assert(w.anchor.index1 != 0, "physics: movers need Settings.anchor")
	m^ = {}
	bd := b3.DefaultBodyDef()
	bd.type = .dynamicBody
	bd.position = v3(pos)
	bd.gravityScale = def.gravity_scale
	bd.motionLocks = {
		angularX = true,
		angularY = true,
		angularZ = true,
	}
	bd.enableSleep = false
	bd.name = "mover"
	body := b3.CreateBody(w.id, &bd)
	sd := b3.DefaultShapeDef()
	sd.density = def.density
	// The joints do all the moving; surface friction would fight them.
	sd.baseMaterial.friction = 0
	sd.baseMaterial.restitution = 0
	sd.baseMaterial.userMaterialId = def.material
	if def.category != 0 do sd.filter.categoryBits = def.category
	if def.mask != 0 do sd.filter.maskBits = def.mask
	sd.enableHitEvents = def.hit_events
	cap := b3.Capsule{{0, -def.half_height, 0}, {0, def.half_height, 0}, def.radius}
	b3.CreateCapsuleShape(body, &sd, &cap)
	m.body = ref_of(body)
	m.move_joint = create_move_joint(w, m, def, w.anchor)
}

// Destroys the body (and with it the joints) and clears the mover.
mover_destroy :: proc(w: ^World, m: ^Mover) {
	destroy_body(w, &m.body)
	m^ = {}
}

@(private)
create_move_joint :: proc(w: ^World, m: ^Mover, def: ^Mover_Def, base: b3.BodyId) -> Joint_Ref {
	jd := b3.DefaultMoverJointDef()
	jd.linearVelocity = v3(m.velocity)
	jd.maxForce = .Limp in m.flags ? 0 : def.max_ground_force
	jd.base.bodyIdA = base
	jd.base.bodyIdB = body_id(w, m.body)
	jd.base.collideConnected = true
	return joint_ref_of(b3.CreateMoverJoint(w.id, &jd))
}

@(private)
mover_weight :: proc(w: ^World, m: ^Mover, def: ^Mover_Def) -> f32 {
	g := b3.World_GetGravity(w.id)
	return def.gravity_scale * dmath.sqrt(g.x * g.x + g.y * g.y + g.z * g.z) * b3.Body_GetMass(body_id(w, m.body))
}

@(private)
drop_pogo :: proc(w: ^World, m: ^Mover) {
	destroy_joint(w, &m.pogo)
	m.ground = {}
	m.pogo_impulse = 0
	m.pogo_velocity = 0
}

// An outside impulse lifts the mover (pads, hits, its own jump): the pogo stops pulling it down
// until it lands again.
mover_launch :: proc(m: ^Mover) {
	m.flags -= {.On_Ground, .Walkable}
	m.flags += {.Jumping}
	m.jump_ticks = 0
	m.coyote = 0
}

// Limp: no drive force and no pogo (held, stunned); the body just tumbles along. Leaving limp
// starts like a launch, so the mover settles back onto the ground through the pogo.
mover_set_limp :: proc(w: ^World, m: ^Mover, limp: bool) {
	if limp == (.Limp in m.flags) do return
	if limp {
		m.flags += {.Limp}
		m.flags -= {.On_Ground, .Walkable}
		m.velocity = {}
		m.coyote = 0
		m.jump_buffer = 0
		drop_pogo(w, m)
		if joint_valid(w, m.move_joint) {
			id := joint_id(w, m.move_joint)
			b3.MoverJoint_SetMaxVelocityForce(id, 0)
			b3.MoverJoint_SetLinearVelocity(id, {})
		}
	} else {
		m.flags -= {.Limp}
		mover_launch(m)
	}
}

// Moves the mover (respawn): velocities zeroed, ground forgotten.
mover_teleport :: proc(w: ^World, m: ^Mover, pos: [3]f32) {
	teleport(w, m.body, pos)
	drop_pogo(w, m)
	m.velocity = {}
	m.flags -= {.On_Ground, .Walkable, .Jumping}
	m.coyote = 0
	m.jump_buffer = 0
}

mover_grounded :: proc(m: ^Mover) -> bool {
	return .On_Ground in m.flags && .Walkable in m.flags
}

// Advances the mover's drive before the world step. `move` is the wanted horizontal direction in
// world space (x, z), length ≤ 1; `jump` is a fresh press (edge); `speed_scale` scales max_speed.
// Returns true when it jumped this tick.
mover_update :: proc(
	w: ^World,
	m: ^Mover,
	def: ^Mover_Def,
	move: [2]f32,
	jump: bool,
	speed_scale: f32,
	dt: f32,
) -> (
	jumped: bool,
) {
	if .Limp in m.flags do return false
	body := body_id(w, m.body)

	// Jump (from the previous update's ground state), with coyote time and a buffer.
	if jump {
		m.jump_buffer = u16(def.jump_buffer_s / dt + 0.5)
	}
	if m.jump_buffer > 0 && m.coyote > 0 && .Jumping not_in m.flags {
		surface_vy: f32 = 0
		if body_valid(w, m.ground) {
			surface_vy = b3.Body_GetLinearVelocity(link_id(w, m.ground)).y
		}
		vy := b3.Body_GetLinearVelocity(body).y
		dv := max(0, def.jump_speed - vy) + surface_vy
		b3.Body_ApplyLinearImpulseToCenter(body, {0, b3.Body_GetMass(body) * dv, 0}, true)
		mover_launch(m)
		m.jump_buffer = 0
		jumped = true
	} else if m.jump_buffer > 0 {
		m.jump_buffer -= 1
	}

	// Probe for ground: reach further while grounded so the spring finds the ground over a step.
	ray_len := .On_Ground in m.flags ? 2 * def.pogo_rest : def.pogo_rest
	translation := [3]f32{0, -ray_len, 0}
	p := b3.Body_GetPosition(body)
	origin := [3]f32{p.x, p.y - def.half_height, p.z}
	q := Query{def.category, def.mask}
	self := link(m.body)
	hit, found := ray_closest(w, origin, translation, q, self)
	offset: [3]f32
	if !(found && hit.normal.y >= def.min_ground_normal_y) {
		// The skirt turns with the direction of travel, so ties go to the leading probe.
		v := b3.Body_GetLinearVelocity(body)
		heading := [2]f32{v.x, v.z}
		hl := heading.x * heading.x + heading.y * heading.y
		if hl < 1.1920929e-07 {
			heading = {1, 0}
		} else {
			l := dmath.sqrt(hl)
			heading = {heading.x / l, heading.y / l}
		}
		side := [2]f32{-heading.y, heading.x}
		best := max(f32)
		for i in 0 ..< 8 {
			o := [3]f32 {
				def.radius * (SKIRT_C[i] * heading.x + SKIRT_S[i] * side.x),
				0,
				def.radius * (SKIRT_C[i] * heading.y + SKIRT_S[i] * side.y),
			}
			h, ok := ray_closest(w, origin + o, translation, q, self)
			if ok && h.normal.y >= def.min_ground_normal_y {
				d := abs(h.fraction * ray_len - def.pogo_rest)
				if d < best {
					best = d
					hit = h
					found = true
					offset = o
				}
			}
		}
	}

	// Should the jump end?
	if .Jumping in m.flags {
		m.jump_ticks += 1
		// Give the jump time to leave the ground first.
		if m.jump_ticks > 2 && found && dot3(m.velocity, hit.normal) <= 0 {
			m.flags -= {.Jumping}
		}
	}

	if found {
		if hit.normal.y >= def.min_ground_normal_y do m.flags += {.Walkable}
		else do m.flags -= {.Walkable}
		if .Jumping in m.flags do m.flags -= {.On_Ground}
		else do m.flags += {.On_Ground}
		if .On_Ground in m.flags {
			if .Walkable in m.flags do m.time_sliding = max(m.time_sliding - dt, 0)
			else do m.time_sliding = min(m.time_sliding + dt, def.slide_s)
		}
	} else {
		m.flags -= {.On_Ground, .Walkable}
		m.time_sliding = max(m.time_sliding - dt, 0)
	}
	if .On_Ground in m.flags && .Walkable in m.flags {
		m.coyote = u16(def.coyote_s / dt + 0.5)
	} else if m.coyote > 0 {
		m.coyote -= 1
	}

	// Attach the drive to a kinematic platform under the mover (acts like friction).
	base := w.anchor
	if found {
		gid := link_id(w, hit.body)
		if b3.Body_GetType(gid) == .kinematicBody &&
		   (def.platform_material == 0 || hit.material == def.platform_material) {
			base = gid
		}
	}
	if !joint_valid(w, m.move_joint) || b3.Joint_GetBodyA(joint_id(w, m.move_joint)) != base {
		destroy_joint(w, &m.move_joint)
		m.move_joint = create_move_joint(w, m, def, base)
	}
	mj := joint_id(w, m.move_joint)
	bv := b3.Body_GetLinearVelocity(body)
	pv := b3.Body_GetLinearVelocity(base)
	m.velocity = {bv.x - pv.x, bv.y - pv.y, bv.z - pv.z}

	// Friction in the horizontal plane; the pogo owns the vertical motion.
	if .On_Ground in m.flags {
		speed := dmath.sqrt(m.velocity.x * m.velocity.x + m.velocity.z * m.velocity.z)
		if speed < def.min_speed {
			m.velocity.x = 0
			m.velocity.z = 0
		} else {
			control := speed < def.stop_speed ? def.stop_speed : speed
			drop := control * def.friction * dt
			ratio := max(0, speed - drop) / speed
			m.velocity.x *= ratio
			m.velocity.z *= ratio
		}
	}

	max_force: f32
	if .On_Ground in m.flags {
		if def.slide_s > 0 {
			max_force = clamp(1 - m.time_sliding / def.slide_s, 0, 1) * def.max_ground_force
		} else {
			max_force = .Walkable in m.flags ? def.max_ground_force : 0
		}
	} else {
		max_force = def.max_air_force
	}
	b3.MoverJoint_SetMaxVelocityForce(mj, max_force)

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
	want_speed = min(want_speed, max_speed)
	add := want_speed - dot3(m.velocity, dir)
	if add > 0 {
		steer: f32 = .Walkable in m.flags ? 1 : def.air_steer
		accel := min(steer * def.accelerate * max_speed * dt, add)
		m.velocity.x += accel * dir.x
		m.velocity.z += accel * dir.z
	}

	// The pogo.
	n := hit.normal
	if found && abs(1 - dot3(n, n)) < 100 * 1.1920929e-07 {
		weight := mover_weight(w, m, def)
		tension := .Jumping in m.flags ? 0 : def.pogo_tension_scale * weight
		gid := link_id(w, hit.body)
		lp := b3.Body_GetLocalPoint(gid, v3(hit.point))
		frame_b := b3.Transform{{offset.x, -def.half_height, offset.z}, {{0, 0, 0}, 1}}
		if hit.body != m.ground || !joint_valid(w, m.pogo) {
			if joint_valid(w, m.pogo) {
				pj := joint_id(w, m.pogo)
				m.pogo_impulse = b3.PogoJoint_GetImpulse(pj)
				m.pogo_velocity = b3.PogoJoint_GetCurrentSpeed(pj)
				destroy_joint(w, &m.pogo)
			}
			m.ground = hit.body
			pd := b3.DefaultPogoJointDef()
			pd.base.localFrameA = {lp, {{0, 0, 0}, 1}}
			pd.base.localFrameB = frame_b
			pd.base.bodyIdA = gid
			pd.base.bodyIdB = body
			pd.base.collideConnected = true
			pd.normal = v3(n)
			pd.restLength = def.pogo_rest
			pd.hertz = def.pogo_hertz
			pd.dampingRatio = def.pogo_damping
			pd.maxCompressionForce = def.pogo_compression_scale * weight
			pd.maxTensionForce = tension
			// Warm start from the joint that was just destroyed.
			pd.impulse = m.pogo_impulse
			pd.velocity = m.pogo_velocity
			m.pogo = joint_ref_of(b3.CreatePogoJoint(w.id, &pd))
		} else {
			pj := joint_id(w, m.pogo)
			b3.Joint_SetLocalFrameA(pj, {lp, {{0, 0, 0}, 1}})
			b3.Joint_SetLocalFrameB(pj, frame_b)
			b3.PogoJoint_SetNormal(pj, v3(n))
			b3.PogoJoint_SetMaxTensionForce(pj, tension)
			b3.PogoJoint_SetMaxCompressionForce(pj, def.pogo_compression_scale * weight)
			b3.PogoJoint_SetSpringHertz(pj, def.pogo_hertz)
			b3.PogoJoint_SetSpringDampingRatio(pj, def.pogo_damping)
		}
	} else {
		drop_pogo(w, m)
	}

	b3.MoverJoint_SetLinearVelocity(mj, v3(m.velocity))
	return
}

@(private)
dot3 :: #force_inline proc "contextless" (a, b: [3]f32) -> f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}
