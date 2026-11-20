package playground

import "unified:dmath"
import "unified:physics"
import "unified:sim"

GRAB_REEL_SPEED :: f32(6) // m/s the grab point moves while Closer or Farther is held

// Every present player's tools, in slot order: the grab (a held button), then their commands (shoot, spawn, explode,
// drive). A tool used starts the player's cooldown; a command sent while it runs is dropped.
use_tools :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for data, player in sim.next(&players) {
		grab(t, player, data)
		for sent in sim.commands(t, player) {
			if _, is_drive := sent.(Command_Drive); is_drive {
				toggle_car(t, player)
				continue
			}
			if sim.timer_running(t, data.cooldown) do continue
			switch command in sent {
			case Command_Shoot:
				shoot(t, player, data)
				sim.timer_start_ticks(t, &data.cooldown, SHOT_COOLDOWN_TICKS)
			case Command_Spawn:
				spawn(t, player, data, command.shape)
				sim.timer_start_ticks(t, &data.cooldown, SPAWN_COOLDOWN_TICKS)
			case Command_Explode:
				explode(t, player, data)
				sim.timer_start_ticks(t, &data.cooldown, EXPLODE_COOLDOWN_TICKS)
			case Command_Scene, Command_Drive: // change_scene's, above
			}
		}
	}
}

// The grab: a press takes the dynamic body the aim ray meets within GRAB_RANGE (a motor joint from the World's anchor,
// its frame on the body at the point hit); while held, the joint's other frame is the point GRAB_DIST in front of the
// camera (reeled by Closer and Farther), so the body follows with a spring capped at GRAB_FORCE_SCALE times its
// weight, its spin damped; a release lets go. A body that went (despawned, its scene left) ends the grab.
grab :: proc(t: ^Tick, player: sim.Player, data: ^Player_Data) {
	world := t.world.phys
	buttons := sim.buttons(t, player)
	if data.grab != {} && (.Grab in buttons.released || !physics.body_valid(world, data.held_body)) {
		release(t, player)
	}
	look := dmath.aim_vec(data.aim)
	if .Grab in buttons.pressed && data.grab == {} && data.car < 0 {
		hit, hit_ok := physics.world_cast_ray_closest(
			world,
			data.pos,
			look * GRAB_RANGE,
			{category = CAT_PROP, mask = CAT_PROP},
		)
		if !hit_ok do return
		body, alive := physics.resolve(world, hit.body)
		if !alive || physics.body_type(world, body) != .Dynamic do return
		mass := physics.body_mass(world, body)
		joint_def := physics.default_motor_joint_def()
		joint_def.base.local_frame_a = {hit.point, {0, 0, 0, 1}} // the World's anchor sits at the origin
		joint_def.base.local_frame_b = {physics.body_local_point(world, body, hit.point), {0, 0, 0, 1}}
		joint_def.linear_hertz = GRAB_HERTZ
		joint_def.linear_damping_ratio = GRAB_DAMPING
		joint_def.max_spring_force = mass * 9.8 * GRAB_FORCE_SCALE
		joint_def.max_velocity_torque = mass * GRAB_TORQUE
		data.grab = physics.create_motor_joint(world, physics.world_anchor(world), hit.body, joint_def)
		data.held_body = hit.body
		data.grab_dist = dmath.max(hit.fraction * GRAB_RANGE, GRAB_DIST_MIN)
		sim.emit(t, Event_Grabbed{player = player, position = sim.Position(hit.point)})
	}
	if data.grab == {} do return
	if .Closer in buttons.down do data.grab_dist = dmath.max(data.grab_dist - GRAB_REEL_SPEED * t.dt, GRAB_DIST_MIN)
	if .Farther in buttons.down do data.grab_dist = dmath.min(data.grab_dist + GRAB_REEL_SPEED * t.dt, GRAB_RANGE)
	physics.joint_set_local_frame_a(world, data.grab, {data.pos + look * data.grab_dist, {0, 0, 0, 1}})
	physics.joint_wake_bodies(world, data.grab)
}

// `player` lets go of what they hold (nothing when they hold nothing).
release :: proc(t: ^Tick, player: sim.Player) {
	data := sim.player_data(t, player)
	if data.grab == {} do return
	physics.destroy_joint(t.world.phys, &data.grab)
	data.held_body = {}
	sim.emit(t, Event_Released{player = player})
}

// A bullet from the camera along the aim at SHOT_SPEED (a bullet body: continuous collision against dynamic bodies
// too), gone after SHOT_TICKS. With MAX_PROPS out, the oldest bullet goes to make room.
shoot :: proc(t: ^Tick, player: sim.Player, data: ^Player_Data) {
	look := dmath.aim_vec(data.aim)
	fire_bullet(t, player, data.pos + look * 0.6, look * SHOT_SPEED)
}

// A bullet at `pos` with `velocity`, `player`'s ({}: the turret's).
fire_bullet :: proc(t: ^Tick, player: sim.Player, pos, velocity: [3]f32) {
	make_room(t, .Bullet, {})
	if _, _, ok := spawn_prop(t, {
		kind     = .Sphere,
		size     = SHOT_RADIUS,
		pos      = pos,
		velocity = velocity,
		role     = .Bullet,
		density  = SHOT_DENSITY,
		owner    = player,
		bullet   = true,
	}); ok {
		sim.emit(t, Event_Shot{player = player, position = sim.Position(pos)})
	}
}

// A body of `shape` SPAWN_DIST along the aim, `player`'s. With MAX_PROPS out, the player's oldest spawn goes first.
spawn :: proc(t: ^Tick, player: sim.Player, data: ^Player_Data, shape: Shape) {
	pos := data.pos + dmath.aim_vec(data.aim) * SPAWN_DIST
	make_room(t, .Spawned, player)
	size := [3]f32{SPAWN_HALF, SPAWN_HALF, SPAWN_HALF}
	if shape == .Capsule || shape == .Cylinder do size = {SPAWN_HALF * 0.6, SPAWN_HALF, 0}
	if _, _, ok := spawn_prop(t, {kind = shape, size = size, pos = pos, role = .Spawned, owner = player}); ok {
		sim.emit(t, Event_Spawned{player = player, position = sim.Position(pos)})
	}
}

// With the table full, the oldest prop of `role` (`owner`'s, unless {}) goes.
make_room :: proc(t: ^Tick, role: Role, owner: sim.Player) {
	if int(t.state.props.count) < MAX_PROPS do return
	if oldest, found := oldest_prop(t, role, owner); found do despawn_prop(t, oldest)
}

// An explosion where the aim ray first meets something within GRAB_RANGE (else at its end): world_explode's impulses
// on the props around (EXPLODE_RADIUS, fading over EXPLODE_FALLOFF, EXPLODE_IMPULSE per square metre).
explode :: proc(t: ^Tick, player: sim.Player, data: ^Player_Data) {
	world := t.world.phys
	look := dmath.aim_vec(data.aim)
	at := data.pos + look * GRAB_RANGE
	if hit, ok := physics.world_cast_ray_closest(world, data.pos, look * GRAB_RANGE); ok do at = hit.point
	def := physics.default_explosion_def()
	def.mask_bits = CAT_PROP
	def.position = at
	def.radius = EXPLODE_RADIUS
	def.falloff = EXPLODE_FALLOFF
	def.impulse_per_area = EXPLODE_IMPULSE
	physics.world_explode(world, def)
	sim.emit(t, Event_Exploded{player = player, position = sim.Position(at)})
}
