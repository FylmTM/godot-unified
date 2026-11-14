// The tick (games/friendslop/SPEC.md), in this order: presence; per player input (break free, grab, drop,
// throw); holds; movers; platforms; pads and bumpers; the physics step; hits (players, bells);
// plates and switches; stuns; falls; the run (start, checkpoints, finish, reset).
package friendslop

import "unified:b3"
import "unified:dmath"
import "unified:physics"
import "unified:sim"

tick :: proc(tick: ^Tick) {
	state, world := tick.state, tick.world
	presence(tick)
	jumps: [PLAYERS]bool
	for player in 0 ..< PLAYERS {
		if state.players[player].active do jumps[player] = player_actions(tick, player, tick.inputs.input[player])
	}
	update_holds(state, world)
	for player in 0 ..< PLAYERS {
		if state.players[player].active do player_move(tick, player, tick.inputs.input[player], jumps[player])
	}
	platforms(state, world)
	pads(tick)
	bumpers(tick)
	physics.step(world.phys, DT, SUBSTEPS)
	hits(tick)
	plates_and_switches(tick)
	stuns(state, world)
	falls(tick)
	run(tick)
}

// ---- helpers

player_pos :: proc(state: ^State, world: ^World, player: int) -> [3]f32 {
	return physics.position(world.phys, state.players[player].mover.body)
}

holding :: proc(character: ^Player) -> bool {
	return character.held_kind != .None
}

// The yaw quaternion turning local +z to `facing` (unit x, z), from half-angle identities (sqrt only).
yaw_quat :: proc(facing: [2]f32) -> [4]f32 {
	cos_half := dmath.sqrt(max(0, (1 + facing.y) * 0.5))
	sin_half := dmath.sqrt(max(0, (1 - facing.y) * 0.5))
	if facing.x < 0 do sin_half = -sin_half
	return {0, sin_half, 0, cos_half}
}

// An event's `entity` for a level marker: its index + 1 (0: none).
marker_entity :: proc(marker: int) -> u64 {
	return u64(marker + 1)
}

item_entity :: proc(world: ^World, item: int) -> u64 {
	return marker_entity(world.items[item].marker)
}

// What a body is, from its user material: (Held_Kind.Item, index), (.Player, player) or (.None, -1).
entity_of :: proc(material: u64) -> (Held_Kind, int) {
	switch {
	case material >= MAT_ITEM && material < MAT_ITEM + MAX_ITEMS:
		return .Item, int(material - MAT_ITEM)
	case material >= MAT_PLAYER && material < MAT_PLAYER + PLAYERS:
		return .Player, int(material - MAT_PLAYER)
	}
	return .None, -1
}

limp :: proc(state: ^State, world: ^World, player: int) {
	physics.mover_set_limp(world.phys, &state.players[player].mover, true)
}

// ---- presence

presence :: proc(tick: ^Tick) {
	state, world := tick.state, tick.world
	for player in 0 ..< PLAYERS {
		character := &state.players[player]
		here := player in tick.inputs.present
		if here && !character.active {
			character^ = {
				active = true,
				facing = {0, 1},
				aim    = {0, 0, 1},
			}
			physics.mover_create(
				world.phys,
				&character.mover,
				&world.movers[player],
				respawn_point(state, world, player),
			)
			sim.emit(
				tick,
				Player_Joined{position = sim.Position(respawn_point(state, world, player)), player = u8(player)},
			)
		} else if !here && character.active {
			release_all(tick, player)
			physics.mover_destroy(world.phys, &character.mover)
			character^ = {}
			sim.emit(tick, Player_Left{player = u8(player)})
		}
	}
}

respawn_point :: proc(state: ^State, world: ^World, player: int) -> [3]f32 {
	if state.checkpoint >= 0 {
		for i in 0 ..< world.checkpoint_count {
			checkpoint := &world.checkpoints[i]
			if checkpoint.index == int(state.checkpoint) {
				return checkpoint.volume.pos + {f32(player) * 0.9 - 1.35, 0, 0}
			}
		}
	}
	return world.spawns[player]
}

// Drops whatever the player holds and frees them if someone holds them.
release_all :: proc(tick: ^Tick, player: int) {
	character := &tick.state.players[player]
	if holding(character) do drop(tick, player)
	if character.held_by != 0 do drop(tick, int(character.held_by) - 1)
}

// ---- actions

// Break free, grab, drop, throw. Returns whether jump was pressed this tick (for the mover).
player_actions :: proc(tick: ^Tick, player: int, input: Input) -> (jump: bool) {
	state, world := tick.state, tick.world
	character := &state.players[player]
	pressed := input.buttons & ~character.prev_buttons
	released := character.prev_buttons & ~input.buttons
	character.prev_buttons = input.buttons
	aim := dmath.normalize3({f32(input.aim_x), f32(input.aim_y), f32(input.aim_z)})
	if aim != {} do character.aim = aim
	if character.respawn > 0 do return
	jump = pressed & BUTTON_JUMP != 0

	if character.held_by != 0 {
		// Held: 3 jump presses within the window break free (not too early); the holder lets go anyway
		// after a while.
		character.held_ticks += 1
		if character.break_window > 0 do character.break_window -= 1
		else do character.break_presses = 0
		if pressed & BUTTON_JUMP != 0 {
			if character.break_presses == 0 do character.break_window = BREAK_FREE_WINDOW_TICKS
			character.break_presses += 1
		}
		if (character.break_presses >= 3 && character.held_ticks >= BREAK_FREE_MIN_TICKS) ||
		   character.held_ticks >= HELD_MAX_TICKS {
			holder := int(character.held_by) - 1
			drop(tick, holder)
			physics.set_velocity(
				world.phys,
				character.mover.body,
				physics.velocity(world.phys, character.mover.body) + {0, 4, 0},
			)
			sim.emit(tick, Broke_Free{position = sim.Position(player_pos(state, world, player)), player = u8(player)})
		}
		return false
	}
	if character.stun > 0 do return

	if pressed & BUTTON_GRAB != 0 {
		if holding(character) do drop(tick, player)
		else do try_grab(tick, player, false)
	} else if input.buttons & BUTTON_GRAB != 0 && !holding(character) {
		try_grab(tick, player, true) // catch
	}
	if holding(character) {
		if input.buttons & BUTTON_THROW != 0 do character.charge = min(character.charge + 1, THROW_CHARGE_TICKS)
		if released & BUTTON_THROW != 0 do throw(tick, player)
	} else {
		character.charge = 0
	}
	return
}

Target :: struct {
	kind:       Held_Kind,
	index:      int,
	grab_point: int,
	distance:   f32,
}

// Grabs the target the player aims at (a ray along the aim), else the nearest grabbable in a 60° cone
// in front. `only_thrown`: catching, so only things in flight.
try_grab :: proc(tick: ^Tick, player: int, only_thrown: bool) {
	state, world := tick.state, tick.world
	character := &state.players[player]
	chest := player_pos(state, world, player) + {0, HOLD_UP, 0}
	best := Target {
		distance = max(f32),
	}
	if hit, ok := physics.ray_closest(
		world.phys,
		chest,
		character.aim * (GRAB_RANGE + 0.7),
		{mask = CAT_ITEM | CAT_PLAYER | CAT_STATIC | CAT_PLATFORM},
		physics.link(character.mover.body),
	); ok {
		kind, index := entity_of(hit.material)
		if kind != .None {
			grab_point := grabbable(state, world, player, kind, index, chest, only_thrown)
			if grab_point >= 0 do best = {kind, index, grab_point, 0}
		}
	}
	if best.kind == .None {
		forward := dmath.normalize2({character.aim.x, character.aim.z})
		if forward == {} do forward = character.facing
		consider :: proc(
			best: ^Target,
			kind: Held_Kind,
			index, grab_point: int,
			offset: [3]f32,
			radius: f32,
			forward: [2]f32,
		) {
			if grab_point < 0 do return
			distance := dmath.length3(offset) - radius
			if distance > GRAB_RANGE || abs(offset.y) > 1.6 do return
			flat := dmath.normalize2({offset.x, offset.z})
			if distance > 0.4 && flat.x * forward.x + flat.y * forward.y < GRAB_CONE_COS do return
			if distance < best.distance do best^ = {kind, index, grab_point, distance}
		}
		for i in 0 ..< world.item_count {
			if !state.items[i].alive do continue
			pos := physics.position(world.phys, state.items[i].body)
			consider(
				&best,
				.Item,
				i,
				grabbable(state, world, player, .Item, i, chest, only_thrown),
				pos - chest,
				ITEM_SPECS[world.items[i].kind].radius,
				forward,
			)
		}
		for other in 0 ..< PLAYERS {
			if other == player || !state.players[other].active do continue
			consider(
				&best,
				.Player,
				other,
				grabbable(state, world, player, .Player, other, chest, only_thrown),
				player_pos(state, world, other) - chest,
				PLAYER_RADIUS,
				forward,
			)
		}
	}
	if best.kind != .None do grab(tick, player, best)
}

// The free grab point of a target the player may take (the nearest to `chest`), or -1.
grabbable :: proc(
	state: ^State,
	world: ^World,
	player: int,
	kind: Held_Kind,
	index: int,
	chest: [3]f32,
	only_thrown: bool,
) -> int {
	switch kind {
	case .Item:
		item := &state.items[index]
		if !item.alive || (only_thrown && item.thrown_ticks == 0) do return -1
		spec := &ITEM_SPECS[world.items[index].kind]
		best, best_distance_sq := -1, max(f32)
		for point in 0 ..< int(spec.grab_points) {
			if item.holders[point] != 0 do continue
			if spec.grab_points == 1 do return 0
			pos := physics.position(world.phys, item.body)
			point_pos :=
				pos +
				physics.rotate(
					physics.rotation(world.phys, item.body),
					grab_point_offset(world.items[index].kind, point),
				)
			offset := point_pos - chest
			distance_sq := offset.x * offset.x + offset.y * offset.y + offset.z * offset.z
			if distance_sq < best_distance_sq do best, best_distance_sq = point, distance_sq
		}
		return best
	case .Player:
		target := &state.players[index]
		if !target.active || target.respawn > 0 || target.held_by != 0 || target.held_kind == .Player do return -1
		if only_thrown && !target.thrown do return -1
		return 0
	case .None:
	}
	return -1
}

// The hold point in the holder's body frame (rotation locked: world axes) and the frame's rotation.
hold_frame :: proc(character: ^Player, target: Held_Kind) -> b3.Transform {
	up: f32 = HOLD_UP + character.aim.y * HOLD_PITCH + (target == .Player ? 0.5 : 0)
	offset := [3]f32{character.facing.x * HOLD_DIST, up, character.facing.y * HOLD_DIST}
	return {offset, yaw_quat(character.facing)}
}

grab :: proc(tick: ^Tick, player: int, target: Target) {
	state, world := tick.state, tick.world
	character := &state.players[player]
	joint_def := b3.default_motor_joint_def()
	joint_def.base.body_id_a = physics.body_id(world.phys, character.mover.body)
	joint_def.base.local_frame_a = hold_frame(character, target.kind)
	joint_def.base.collide_connected = false
	joint_def.linear_hertz = 5
	joint_def.linear_damping_ratio = 1
	joint_def.angular_hertz = 5
	joint_def.angular_damping_ratio = 1
	entity: u64
	held_player := sim.NO_PLAYER
	switch target.kind {
	case .Item:
		item := &state.items[target.index]
		kind := world.items[target.index].kind
		spec := &ITEM_SPECS[kind]
		joint_def.base.body_id_b = physics.body_id(world.phys, item.body)
		joint_def.base.local_frame_b = {grab_point_offset(kind, target.grab_point), {0, 0, 0, 1}}
		joint_def.max_spring_force = spec.lift * spec.mass * GRAVITY
		joint_def.max_spring_torque = spec.grab_points > 1 ? 0 : spec.mass * 20
		item.holders[target.grab_point] = u8(player + 1)
		item.thrown_ticks = 0
		item.thrown_by = 0
		entity = item_entity(world, target.index)
	case .Player:
		held := &state.players[target.index]
		if holding(held) do drop(tick, target.index)
		held.held_by = u8(player + 1)
		held.held_ticks = 0
		held.break_presses = 0
		held.break_window = 0
		held.stun = 0
		held.thrown = false
		held.charge = 0
		limp(state, world, target.index)
		joint_def.base.body_id_b = physics.body_id(world.phys, held.mover.body)
		joint_def.base.local_frame_b = {{}, {0, 0, 0, 1}}
		joint_def.max_spring_force =
			PLAYER_LIFT * physics.mass(world.phys, held.mover.body) * GRAVITY * MOVER.gravity_scale
		joint_def.max_spring_torque = 0
		held_player = u8(target.index)
	case .None:
		return
	}
	character.hold = physics.joint_ref_of(b3.create_motor_joint(world.phys.id, &joint_def))
	character.held_kind = target.kind
	character.held_index = u8(target.index)
	character.grab_point = u8(target.grab_point)
	character.charge = 0
	state.grabs += 1
	sim.emit(
		tick,
		Grabbed {
			entity = entity,
			position = sim.Position(player_pos(state, world, player)),
			player = u8(player),
			held_kind = target.kind,
			held_player = held_player,
		},
	)
}

// Lets go of whatever the player holds (no throw). A dropped friend falls and gets up on landing.
drop :: proc(tick: ^Tick, player: int) {
	state, world := tick.state, tick.world
	character := &state.players[player]
	if !holding(character) do return
	physics.destroy_joint(world.phys, &character.hold)
	held_kind := character.held_kind
	entity: u64
	held_player := sim.NO_PLAYER
	switch held_kind {
	case .Item:
		item := &state.items[character.held_index]
		item.holders[character.grab_point] = 0
		entity = item_entity(world, int(character.held_index))
	case .Player:
		held := &state.players[character.held_index]
		held.held_by = 0
		held.held_ticks = 0
		held.thrown = true
		held.stun = THROWN_MAX_TICKS
		held_player = character.held_index
	case .None:
	}
	character.held_kind = .None
	character.charge = 0
	sim.emit(
		tick,
		Dropped {
			entity = entity,
			position = sim.Position(player_pos(state, world, player)),
			player = u8(player),
			held_kind = held_kind,
			held_player = held_player,
		},
	)
}

throw :: proc(tick: ^Tick, player: int) {
	state, world := tick.state, tick.world
	character := &state.players[player]
	kind, index := character.held_kind, int(character.held_index)
	if kind == .Item && !ITEM_SPECS[world.items[index].kind].throwable {
		drop(tick, player)
		return
	}
	charge := f32(character.charge) / f32(THROW_CHARGE_TICKS)
	speed := THROW_SPEED_MIN + THROW_SPEED_ADD * charge
	velocity := physics.velocity(world.phys, character.mover.body) + character.aim * speed + {0, 1.5, 0}
	drop(tick, player)
	body: Body_Ref
	entity: u64
	held_player := sim.NO_PLAYER
	if kind == .Item {
		item := &state.items[index]
		item.thrown_by = u8(player + 1)
		item.thrown_ticks = THROWN_TAG_TICKS
		body = item.body
		entity = item_entity(world, index)
	} else {
		body = state.players[index].mover.body
		held_player = u8(index)
	}
	physics.set_velocity(world.phys, body, velocity)
	state.throws += 1
	sim.emit(
		tick,
		Thrown {
			entity = entity,
			position = sim.Position(player_pos(state, world, player)),
			speed = speed,
			player = u8(player),
			held_kind = kind,
			held_player = held_player,
		},
	)
}

// Every tick, before the movers: hold points follow facing and aim; holds whose target went away end.
update_holds :: proc(state: ^State, world: ^World) {
	for player in 0 ..< PLAYERS {
		character := &state.players[player]
		if !holding(character) do continue
		if !physics.joint_valid(world.phys, character.hold) {
			character.held_kind = .None
			character.hold = {}
			continue
		}
		b3.joint_set_local_frame_a(
			physics.joint_id(world.phys, character.hold),
			hold_frame(character, character.held_kind),
		)
	}
}

// ---- movement

player_move :: proc(tick: ^Tick, player: int, input: Input, jump: bool) {
	state, world := tick.state, tick.world
	character := &state.players[player]
	if character.respawn > 0 || character.held_by != 0 || character.stun > 0 do return
	move := [2]f32{f32(input.move_x) / 127, f32(input.move_z) / 127}
	move = dmath.clamp_length2(move, 1)
	if holding(character) {
		facing := dmath.normalize2({character.aim.x, character.aim.z})
		if facing != {} do character.facing = facing
	} else if move.x * move.x + move.y * move.y > 0.01 {
		character.facing = dmath.normalize2(move)
	}
	scale: f32 = 1
	if holding(character) {
		scale = HOLD_SLOW
		if character.held_kind == .Item && world.items[character.held_index].kind == .Heavy do scale = HOLD_SLOW_HEAVY
	}
	if physics.mover_update(world.phys, &character.mover, &world.movers[player], move, jump, scale, DT) {
		sim.emit(tick, Jumped{position = sim.Position(player_pos(state, world, player)), player = u8(player)})
	}
}

platforms :: proc(state: ^State, world: ^World) {
	for i in 0 ..< world.platform_count {
		def := &world.platforms[i]
		platform := &state.platforms[i]
		total := physics.path_duration_ticks(&def.path, TICK_HZ)
		active := def.trigger < 0 || state.triggers[def.trigger].active
		switch def.mode {
		case .Ping_Pong, .Loop:
			if active do platform.running = true
			if platform.running do platform.phase += 1
		case .Once:
			if active do platform.running = true
			if platform.running && platform.phase < total do platform.phase += 1
		case .Follow:
			if active && platform.phase < total do platform.phase += 1
			if !active && platform.phase > 0 do platform.phase -= 1
		}
		target := def.origin + (physics.path_sample(&def.path, platform.phase, TICK_HZ) - def.path.points[0])
		physics.drive_kinematic(world.phys, platform.body, target, TICK_HZ)
	}
}

// A pad's launch: its vertical speed; a directed pad (a horizontal push) also sets the horizontal velocity,
// so it lands where the level expects whatever the run-up; a straight-up pad keeps it.
pad_velocity :: proc(pad: ^Pad_Def, velocity: [3]f32) -> [3]f32 {
	if pad.launch.x == 0 && pad.launch.z == 0 do return {velocity.x, pad.launch.y, velocity.z}
	return pad.launch
}

pads :: proc(tick: ^Tick) {
	state, world := tick.state, tick.world
	for player in 0 ..< PLAYERS {
		character := &state.players[player]
		if character.pad_cooldown > 0 do character.pad_cooldown -= 1
		if !character.active || character.respawn > 0 || character.held_by != 0 || character.pad_cooldown > 0 do continue
		feet := player_pos(state, world, player) - {0, FEET - 0.05, 0}
		for k in 0 ..< world.pad_count {
			pad := &world.pads[k]
			if !in_volume(pad.volume, feet) do continue
			physics.set_velocity(
				world.phys,
				character.mover.body,
				pad_velocity(pad, physics.velocity(world.phys, character.mover.body)),
			)
			physics.mover_launch(world.phys, &character.mover)
			character.pad_cooldown = PAD_COOLDOWN_TICKS
			state.pad_launches += 1
			sim.emit(tick, Launched{position = sim.Position(pad.volume.pos), player = u8(player)})
			break
		}
	}
	for i in 0 ..< world.item_count {
		item := &state.items[i]
		if item.pad_cooldown > 0 do item.pad_cooldown -= 1
		if !item.alive || item.holders != {} || item.pad_cooldown > 0 do continue
		pos := physics.position(world.phys, item.body)
		bottom := pos - {0, ITEM_SPECS[world.items[i].kind].radius * 0.8, 0}
		for k in 0 ..< world.pad_count {
			pad := &world.pads[k]
			if !in_volume(pad.volume, bottom) do continue
			physics.set_velocity(world.phys, item.body, pad_velocity(pad, physics.velocity(world.phys, item.body)))
			item.pad_cooldown = PAD_COOLDOWN_TICKS
			state.pad_launches += 1
			sim.emit(
				tick,
				Launched {
					entity = item_entity(world, i),
					position = sim.Position(pad.volume.pos),
					player = sim.NO_PLAYER,
				},
			)
			break
		}
	}
}

// Knocks the player along `direction` (horizontal, unit) at `speed`, with a hop: stunned, drops what it holds.
knock :: proc(tick: ^Tick, player: int, direction: [2]f32, speed: f32) {
	state, world := tick.state, tick.world
	character := &state.players[player]
	if character.held_by != 0 || character.respawn > 0 do return
	if holding(character) do drop(tick, player)
	limp(state, world, player)
	character.stun = STUN_TICKS
	character.thrown = false
	character.charge = 0
	physics.set_velocity(world.phys, character.mover.body, {direction.x * speed, KNOCKBACK_UP, direction.y * speed})
	state.hits += 1
	sim.emit(tick, Hit{position = sim.Position(player_pos(state, world, player)), speed = speed, player = u8(player)})
}

bumpers :: proc(tick: ^Tick) {
	state, world := tick.state, tick.world
	for player in 0 ..< PLAYERS {
		character := &state.players[player]
		if !character.active || character.stun > 0 || character.respawn > 0 || character.held_by != 0 do continue
		pos := player_pos(state, world, player)
		for k in 0 ..< world.bumper_count {
			bumper := &world.bumpers[k]
			if !in_volume(bumper.volume, pos) do continue
			direction := dmath.normalize2({pos.x - bumper.volume.pos.x, pos.z - bumper.volume.pos.z})
			if direction == {} do direction = {-character.facing.x, -character.facing.y}
			knock(tick, player, direction, bumper.strength)
			break
		}
	}
}

// ---- after the step

hits :: proc(tick: ^Tick) {
	state, world := tick.state, tick.world
	clear(&world.hits)
	physics.hit_events(world.phys, &world.hits)
	for &hit in world.hits {
		kind_a, index_a := entity_of(hit.material_a)
		kind_b, index_b := entity_of(hit.material_b)
		// Item hits a player.
		item_index, player := -1, -1
		if kind_a == .Item && kind_b == .Player do item_index, player = index_a, index_b
		if kind_b == .Item && kind_a == .Player do item_index, player = index_b, index_a
		if item_index >= 0 {
			item := &state.items[item_index]
			character := &state.players[player]
			if !character.active || item.holders[0] == u8(player + 1) || item.holders[1] == u8(player + 1) do continue
			own := item.thrown_by == u8(player + 1) && item.thrown_ticks > THROWN_TAG_TICKS - THROWER_IGNORE_TICKS
			if own || (item.thrown_ticks == 0 && hit.speed < HIT_SPEED) do continue
			velocity := physics.velocity(world.phys, item.body)
			direction := dmath.normalize2({velocity.x, velocity.z})
			if direction == {} do direction = dmath.normalize2({hit.normal.x, hit.normal.z})
			knock(tick, player, direction, KNOCKBACK)
			continue
		}
		// Anything hits a bell.
		for material in ([2]u64{hit.material_a, hit.material_b}) {
			if material < MAT_TRIGGER || material >= MAT_TRIGGER + MAX_TRIGGERS do continue
			trigger_index := int(material - MAT_TRIGGER)
			trigger := &state.triggers[trigger_index]
			if world.triggers[trigger_index].kind != .Bell || hit.speed < BELL_SPEED || trigger.cooldown > 0 do continue
			trigger.active = true
			trigger.cooldown = BELL_COOLDOWN_TICKS
			sim.emit(
				tick,
				Bell_Rung {
					entity = marker_entity(world.triggers[trigger_index].marker),
					position = sim.Position(hit.point),
					speed = hit.speed,
				},
			)
		}
	}
	for i in 0 ..< world.item_count {
		if state.items[i].thrown_ticks > 0 do state.items[i].thrown_ticks -= 1
	}
}

plates_and_switches :: proc(tick: ^Tick) {
	state, world := tick.state, tick.world
	for i in 0 ..< world.trigger_count {
		def := &world.triggers[i]
		trigger := &state.triggers[i]
		if trigger.cooldown > 0 do trigger.cooldown -= 1
		switch def.kind {
		case .Plate:
			// The mass of the bodies whose centre is over the plate (up to 2.5 m above it).
			top := def.volume.pos.y + def.volume.half.y
			clear(&world.links)
			low := def.volume.pos - def.volume.half
			high := def.volume.pos + def.volume.half + {0, 2.5, 0}
			physics.overlap_aabb(
				world.phys,
				low,
				high,
				&world.links,
				{mask = def.items_only ? CAT_ITEM : CAT_ITEM | CAT_PLAYER},
			)
			mass: f32 = 0
			for link in world.links {
				id := physics.link_id(world.phys, link)
				centre := b3.body_get_position(id)
				if abs(centre.x - def.volume.pos.x) > def.volume.half.x ||
				   abs(centre.z - def.volume.pos.z) > def.volume.half.z {
					continue
				}
				if centre.y < top - 0.2 || centre.y > top + 2.5 do continue
				mass += b3.body_get_mass(id)
			}
			pressed := mass >= def.mass
			if pressed != trigger.active {
				trigger.active = pressed
				entity, position := marker_entity(def.marker), sim.Position(def.volume.pos)
				if pressed {
					sim.emit(tick, Plate_On{entity = entity, position = position, mass = mass})
				} else {
					sim.emit(tick, Plate_Off{entity = entity, position = position, mass = mass})
				}
			}
		case .Switch:
			if trigger.active do continue
			for player in 0 ..< PLAYERS {
				if !state.players[player].active || state.players[player].respawn > 0 do continue
				if in_volume(def.volume, player_pos(state, world, player)) {
					trigger.active = true
					sim.emit(
						tick,
						Switch_On {
							entity = marker_entity(def.marker),
							position = sim.Position(def.volume.pos),
							player = u8(player),
						},
					)
					break
				}
			}
		case .Lock:
			if trigger.active do continue
			for k in 0 ..< world.item_count {
				if world.items[k].kind != .Key || !state.items[k].alive do continue
				if in_volume(def.volume, physics.position(world.phys, state.items[k].body)) {
					trigger.active = true
					sim.emit(
						tick,
						Switch_On {
							entity = marker_entity(def.marker),
							position = sim.Position(def.volume.pos),
							player = sim.NO_PLAYER,
						},
					)
					break
				}
			}
		case .Bell:
		}
	}
}

stuns :: proc(state: ^State, world: ^World) {
	for player in 0 ..< PLAYERS {
		character := &state.players[player]
		if !character.active || character.held_by != 0 || character.stun == 0 do continue
		character.stun -= 1
		if character.thrown && character.stun <= THROWN_MAX_TICKS - THROWN_MIN_TICKS {
			// A thrown player gets up as soon as it lands.
			pos := player_pos(state, world, player)
			if _, ok := physics.ray_closest(
				world.phys,
				pos,
				{0, -(FEET + 0.25), 0},
				{},
				physics.link(character.mover.body),
			); ok {
				character.stun = 0
			}
		}
		if character.stun == 0 {
			character.thrown = false
			physics.mover_set_limp(world.phys, &character.mover, false)
		}
	}
}

falls :: proc(tick: ^Tick) {
	state, world := tick.state, tick.world
	for player in 0 ..< PLAYERS {
		character := &state.players[player]
		if !character.active do continue
		if character.respawn > 0 {
			character.respawn -= 1
			if character.respawn == 0 {
				pos := respawn_point(state, world, player)
				physics.mover_teleport(world.phys, &character.mover, pos)
				physics.mover_set_limp(world.phys, &character.mover, false)
				sim.emit(tick, Respawned{position = sim.Position(pos), player = u8(player)})
			}
			continue
		}
		pos := player_pos(state, world, player)
		if pos.y >= KILL_Y do continue
		release_all(tick, player)
		character.stun = 0
		character.thrown = false
		character.respawn = RESPAWN_TICKS
		limp(state, world, player)
		// Park the body far below while it waits.
		physics.teleport(world.phys, character.mover.body, {f32(player) * 4, -60, 0})
		sim.emit(tick, Fell{position = sim.Position(pos), player = u8(player)})
	}
	for i in 0 ..< world.item_count {
		item := &state.items[i]
		if item.alive && physics.position(world.phys, item.body).y < KILL_Y do item_home(tick, i)
	}
}

// Puts an item back where the level placed it.
item_home :: proc(tick: ^Tick, index: int) {
	state, world := tick.state, tick.world
	item := &state.items[index]
	for point in 0 ..< 2 {
		if item.holders[point] != 0 do drop(tick, int(item.holders[point]) - 1)
	}
	physics.teleport(world.phys, item.body, world.items[index].pos, world.items[index].rot)
	item.thrown_ticks = 0
	item.thrown_by = 0
}

// ---- the run

run :: proc(tick: ^Tick) {
	state, world := tick.state, tick.world
	switch state.phase {
	case .Hub:
		if world.start.half == {} do return
		for player in 0 ..< PLAYERS {
			if !state.players[player].active || state.players[player].respawn > 0 do continue
			if in_volume(world.start, player_pos(state, world, player)) {
				state.phase = .Run
				state.run_tick = tick.number
				sim.emit(tick, Run_Started{position = sim.Position(world.start.pos), player = u8(player)})
				break
			}
		}
	case .Run:
		for player in 0 ..< PLAYERS {
			if !state.players[player].active || state.players[player].respawn > 0 do continue
			pos := player_pos(state, world, player)
			for i in 0 ..< world.checkpoint_count {
				checkpoint := &world.checkpoints[i]
				if checkpoint.index > int(state.checkpoint) && in_volume(checkpoint.volume, pos) {
					state.checkpoint = i32(checkpoint.index)
					sim.emit(
						tick,
						Checkpoint {
							position = sim.Position(checkpoint.volume.pos),
							index = i32(checkpoint.index),
							player = u8(player),
						},
					)
				}
			}
		}
		if world.finish.half == {} do return
		for i in 0 ..< world.item_count {
			if world.items[i].kind != .Trophy || !state.items[i].alive do continue
			if in_volume(world.finish, physics.position(world.phys, state.items[i].body)) {
				state.phase = .Finished
				state.finish_tick = tick.number
				state.runs += 1
				ticks := tick.number - state.run_tick
				if state.best_ticks == 0 || ticks < state.best_ticks do state.best_ticks = ticks
				sim.emit(
					tick,
					Run_Finished {
						entity = item_entity(world, i),
						position = sim.Position(world.finish.pos),
						seconds = f32(ticks) * DT,
					},
				)
				break
			}
		}
	case .Finished:
		if tick.number - state.finish_tick >= FINISH_HOLD_TICKS do reset_route(tick)
	}
}

// Back to the hub: everyone home, every item, platform and trigger as the level made it.
reset_route :: proc(tick: ^Tick) {
	state, world := tick.state, tick.world
	for player in 0 ..< PLAYERS {
		if state.players[player].active do release_all(tick, player)
	}
	state.phase = .Hub
	state.checkpoint = -1
	for player in 0 ..< PLAYERS {
		character := &state.players[player]
		if !character.active do continue
		character.stun = 0
		character.thrown = false
		character.respawn = 0
		physics.mover_teleport(world.phys, &character.mover, world.spawns[player])
		physics.mover_set_limp(world.phys, &character.mover, false)
		sim.emit(tick, Respawned{position = sim.Position(world.spawns[player]), player = u8(player)})
	}
	for i in 0 ..< world.item_count do item_home(tick, i)
	for i in 0 ..< world.platform_count {
		state.platforms[i].phase = 0
		state.platforms[i].running = world.platforms[i].trigger < 0
	}
	for &trigger in state.triggers do trigger = {}
}
