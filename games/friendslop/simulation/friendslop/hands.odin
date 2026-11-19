package friendslop

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// Per player, in slot order: the aim follows the input; a held player struggles (jump presses break free); a free one
// grabs, drops, catches, charges and throws.
use_hands :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for character, player in sim.next(&players) {
		aim := dmath.dir3_vec(sim.input(t, player).aim)
		if aim != {} do character.aim = aim
		if sim.timer_running(t, character.respawn) do continue
		buttons := sim.buttons(t, player)
		if character.held_by != {} {
			struggle(t, character, player, .Jump in buttons.pressed)
			continue
		}
		if character.stun > 0 do continue
		holding := character.held_kind != .None
		if .Grab in buttons.pressed {
			if holding do drop(t, player)
			else do try_grab(t, player, false)
		} else if .Grab in buttons.down && !holding {
			try_grab(t, player, true) // catch
		}
		if character.held_kind != .None {
			if .Throw in buttons.down do character.charge = dmath.min(character.charge + 1, THROW_CHARGE_TICKS)
			if .Throw in buttons.released do throw(t, player)
		} else {
			character.charge = 0
		}
	}
}

// A held player: BREAK_FREE_PRESSES jump presses within the window break free (not too early), with a hop; the holder
// lets go anyway after HELD_MAX_TICKS.
struggle :: proc(t: ^Tick, character: ^Character, player: sim.Player, pressed_jump: bool) {
	character.held_ticks += 1
	if character.break_window > 0 do character.break_window -= 1
	else do character.break_presses = 0
	if pressed_jump {
		if character.break_presses == 0 do character.break_window = BREAK_FREE_WINDOW_TICKS
		character.break_presses += 1
	}
	broke_free := character.break_presses >= BREAK_FREE_PRESSES && character.held_ticks >= BREAK_FREE_MIN_TICKS
	if !broke_free && character.held_ticks < HELD_MAX_TICKS do return
	drop(t, character.held_by)
	body := character.controller.body
	physics.body_set_linear_velocity(
		t.world.phys,
		body,
		physics.body_linear_velocity(t.world.phys, body) + {0, BREAK_FREE_HOP, 0},
	)
	sim.emit(t, Event_Broke_Free{position = sim.Position(player_pos(t, player)), player = player})
}

// A grab's target: what it is, which grab point, and how far (0: on the aim ray).
Target :: struct {
	using body: Body,
	grab_point: int,
	distance:   f32,
}

// Grabs the target the player aims at (a ray along the aim), else the nearest grabbable in a cone in front (on a tie
// the first found: items by index, then players in slot order).
// `only_thrown`: catching, so only things in flight.
try_grab :: proc(t: ^Tick, player: sim.Player, only_thrown: bool) {
	character := sim.player_data(t, player)
	chest := player_pos(t, player) + {0, HOLD_UP, 0}
	best := Target {
		distance = max(f32),
	}
	if hit, ok := physics.world_cast_ray_closest(
		t.world.phys,
		chest,
		character.aim * GRAB_RAY_RANGE,
		{mask = CAT_ITEM | CAT_PLAYER | CAT_STATIC | CAT_PLATFORM},
		physics.link(character.controller.body),
	); ok {
		body := body_of(hit.category, hit.tag)
		if body.kind != .Other {
			grab_point := grabbable(t, player, body, chest, only_thrown)
			if grab_point >= 0 do best = {body, grab_point, 0}
		}
	}
	if best.kind == .Other {
		forward := dmath.normalize(character.aim.xz)
		if forward == {} do forward = character.facing
		consider :: proc(best: ^Target, body: Body, grab_point: int, offset: [3]f32, radius: f32, forward: [2]f32) {
			if grab_point < 0 do return
			distance := dmath.length(offset) - radius
			if distance > GRAB_RANGE || abs(offset.y) > GRAB_HEIGHT do return
			if distance > GRAB_ANYWHERE && dmath.dot(dmath.normalize(offset.xz), forward) < GRAB_CONE_COS do return
			if distance < best.distance do best^ = {body, grab_point, distance}
		}
		for i in 0 ..< places(t).item_count {
			item := Body {
				kind = .Item,
				item = i,
			}
			consider(
				&best,
				item,
				grabbable(t, player, item, chest, only_thrown),
				physics.body_position(t.world.phys, t.state.items[i].body) - chest,
				ITEM_SPECS[places(t).items[i].kind].radius,
				forward,
			)
		}
		others := sim.iterate_present(t)
		for _, other in sim.next(&others) {
			if other == player do continue
			target := Body {
				kind   = .Player,
				player = other,
			}
			consider(
				&best,
				target,
				grabbable(t, player, target, chest, only_thrown),
				player_pos(t, other) - chest,
				PLAYER_RADIUS,
				forward,
			)
		}
	}
	if best.kind != .Other do grab(t, player, best)
}

// The free grab point of a target the player may take (the nearest to `chest`), or -1.
grabbable :: proc(t: ^Tick, player: sim.Player, target: Body, chest: [3]f32, only_thrown: bool) -> int {
	switch target.kind {
	case .Item:
		item := &t.state.items[target.item]
		if only_thrown && !sim.timer_running(t, item.thrown) do return -1
		kind := places(t).items[target.item].kind
		spec := &ITEM_SPECS[kind]
		best, best_distance_sq := -1, max(f32)
		for point in 0 ..< int(spec.grab_points) {
			if item.holders[point] != {} do continue
			if spec.grab_points == 1 do return 0
			point_pos :=
				physics.body_position(t.world.phys, item.body) +
				dmath.quat_rotate(physics.body_rotation(t.world.phys, item.body), grab_point_offset(kind, point))
			distance_sq := dmath.length_sq(point_pos - chest)
			if distance_sq < best_distance_sq do best, best_distance_sq = point, distance_sq
		}
		return best
	case .Player:
		if target.player == player || !sim.player_present(t, target.player) do return -1
		held := sim.player_data(t, target.player)
		if sim.timer_running(t, held.respawn) || held.held_by != {} || held.held_kind == .Player do return -1
		if only_thrown && !held.thrown do return -1
		return 0
	case .Other:
	}
	return -1
}

// The hold point in the holder's body frame (rotation locked: world axes) and the frame's rotation.
hold_frame :: proc(character: ^Character, target: Held_Kind) -> physics.Transform {
	up: f32 = HOLD_UP + character.aim.y * HOLD_PITCH + (target == .Player ? HOLD_UP_PLAYER : 0)
	offset := [3]f32{character.facing.x * HOLD_DIST, up, character.facing.y * HOLD_DIST}
	return {offset, dmath.quat_yaw(character.facing)}
}

// Starts a hold: a motor joint from the player's hold point to the target's grab point, its force capped by what the
// target weighs. A grabbed player drops what they held and goes limp.
grab :: proc(t: ^Tick, player: sim.Player, target: Target) {
	character := sim.player_data(t, player)
	held_kind: Held_Kind
	held_body: physics.Body_Ref
	joint_def := physics.default_motor_joint_def()
	joint_def.base.collide_connected = false
	joint_def.linear_hertz = HOLD_HERTZ
	joint_def.linear_damping_ratio = HOLD_DAMPING
	joint_def.angular_hertz = HOLD_HERTZ
	joint_def.angular_damping_ratio = HOLD_DAMPING
	entity: sim.Entity
	switch target.kind {
	case .Item:
		held_kind = .Item
		item := &t.state.items[target.item]
		kind := places(t).items[target.item].kind
		spec := &ITEM_SPECS[kind]
		held_body = item.body
		joint_def.base.local_frame_b = {grab_point_offset(kind, target.grab_point), {0, 0, 0, 1}}
		joint_def.max_spring_force = spec.lift * spec.mass * GRAVITY
		joint_def.max_spring_torque = spec.grab_points > 1 ? 0 : spec.mass * HOLD_TORQUE_PER_KG
		item.holders[target.grab_point] = player
		sim.timer_stop(&item.thrown)
		item.thrown_by = {}
		physics.stop_ignoring(t.world.phys, &item.thrower_ignore)
		entity = sim.entity(places(t).items[target.item].marker)
	case .Player:
		held_kind = .Player
		held := sim.player_data(t, target.player)
		if held.held_kind != .None do drop(t, target.player)
		held.held_by = player
		held.held_ticks = 0
		held.break_presses = 0
		held.break_window = 0
		held.stun = 0
		held.thrown = false
		held.charge = 0
		physics.character_set_limp(t.world.phys, &held.controller, true)
		held_body = held.controller.body
		joint_def.base.local_frame_b = {{}, {0, 0, 0, 1}}
		joint_def.max_spring_force =
			PLAYER_LIFT *
			physics.body_mass(t.world.phys, held.controller.body) *
			GRAVITY *
			t.world.character_def.gravity_scale
		joint_def.max_spring_torque = 0
	case .Other:
		return
	}
	joint_def.base.local_frame_a = hold_frame(character, held_kind)
	character.hold = physics.create_motor_joint(
		t.world.phys,
		physics.link(character.controller.body),
		physics.link(held_body),
		joint_def,
	)
	character.held_kind = held_kind
	character.held_item = u8(target.item)
	character.held_player = target.player
	character.grab_point = u8(target.grab_point)
	character.charge = 0
	sim.emit(t, Event_Grabbed {
		entity      = entity,
		position    = sim.Position(player_pos(t, player)),
		player      = player,
		held_player = target.player,
	})
}

// Lets go of whatever the player holds (no throw). A dropped friend falls and gets up on landing.
drop :: proc(t: ^Tick, player: sim.Player) {
	character := sim.player_data(t, player)
	if character.held_kind == .None do return
	physics.destroy_joint(t.world.phys, &character.hold)
	held_player := character.held_player
	entity: sim.Entity
	switch character.held_kind {
	case .Item:
		t.state.items[character.held_item].holders[character.grab_point] = {}
		entity = sim.entity(places(t).items[character.held_item].marker)
	case .Player:
		held := sim.player_data(t, held_player)
		held.held_by = {}
		held.held_ticks = 0
		held.thrown = true
		held.stun = THROWN_MAX_TICKS
	case .None:
	}
	character.held_kind = .None
	character.held_item = 0
	character.held_player = {}
	character.charge = 0
	sim.emit(t, Event_Dropped {
		entity      = entity,
		position    = sim.Position(player_pos(t, player)),
		player      = player,
		held_player = held_player,
	})
}

// Throws what the player holds along their aim, faster the longer throw was charged, and tags a thrown item with its
// thrower for hit attribution. A heavy item is dropped instead.
throw :: proc(t: ^Tick, player: sim.Player) {
	character := sim.player_data(t, player)
	kind, index, held_player := character.held_kind, int(character.held_item), character.held_player
	if kind == .Item && !ITEM_SPECS[places(t).items[index].kind].throwable {
		drop(t, player)
		return
	}
	charge := f32(character.charge) / f32(THROW_CHARGE_TICKS)
	speed := THROW_SPEED_MIN + THROW_SPEED_ADD * charge
	velocity :=
		physics.body_linear_velocity(t.world.phys, character.controller.body) +
		character.aim * speed +
		{0, THROW_LIFT, 0}
	drop(t, player)
	body: physics.Body_Ref
	entity: sim.Entity
	if kind == .Item {
		item := &t.state.items[index]
		item.thrown_by = player
		sim.timer_start_ticks(t, &item.thrown, u32(THROWN_TAG_TICKS))
		physics.stop_ignoring(t.world.phys, &item.thrower_ignore) // a throw of an item still clearing its last thrower
		item.thrower_ignore = physics.ignore_contacts(
			t.world.phys,
			physics.link(character.controller.body),
			physics.link(item.body),
		)
		body = item.body
		entity = sim.entity(places(t).items[index].marker)
	} else {
		body = sim.player_data(t, held_player).controller.body
	}
	physics.body_set_linear_velocity(t.world.phys, body, velocity)
	sim.emit(t, Event_Thrown {
		entity      = entity,
		position    = sim.Position(player_pos(t, player)),
		speed       = speed,
		player      = player,
		held_player = held_player,
	})
}

// Every tick, before the characters move: hold points follow facing and aim; holds whose target went away end.
update_holds :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for character in sim.next(&players) {
		if character.held_kind == .None do continue
		if !physics.joint_valid(t.world.phys, character.hold) {
			character.held_kind = .None
			character.held_item = 0
			character.held_player = {}
			character.hold = {}
			continue
		}
		physics.joint_set_local_frame_a(t.world.phys, character.hold, hold_frame(character, character.held_kind))
	}
}

// Drops whatever the player holds and frees them if someone holds them.
release_all :: proc(t: ^Tick, player: sim.Player) {
	character := sim.player_data(t, player)
	if character.held_kind != .None do drop(t, player)
	if character.held_by != {} do drop(t, character.held_by)
}
