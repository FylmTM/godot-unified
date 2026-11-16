// The tick (games/friendslop/SPEC.md), in this order: presence; per player input (break free, grab, drop,
// throw); holds; characters; platforms; pads and bumpers; the physics step; hits (players, bells);
// plates and switches; stuns; falls; the run (start, checkpoints, finish, reset).
package friendslop

import "unified:b3"
import "unified:dmath"
import "unified:physics"
import "unified:sim"

// Advances the game one tick (GAME.tick): runs the systems in the order above around the physics step.
tick :: proc(t: ^Tick) {
	presence(t)
	jumps: [PLAYERS]bool // by slot
	for slot in 0 ..< PLAYERS {
		if player := sim.player_in_slot(&t.state.players, slot); player != {} {
			jumps[slot] = player_actions(t, player, sim.input(t, player))
		}
	}
	update_holds(t)
	for slot in 0 ..< PLAYERS {
		if player := sim.player_in_slot(&t.state.players, slot); player != {} {
			player_move(t, player, sim.input(t, player), jumps[slot])
		}
	}
	platforms(t)
	pads(t)
	bumpers(t)
	physics.step(t.world.phys, DT, SUBSTEPS)
	hits(t)
	plates_and_switches(t)
	stuns(t)
	falls(t)
	run(t)
}

// ---- helpers

// The player's data (nil: nobody, or a member the session forgot).
character_of :: proc(t: ^Tick, player: sim.Player) -> ^Character {
	return sim.player_data(&t.state.players, player)
}

// The slot a present player holds (spawn points and parking spots are per slot).
slot_of :: proc(t: ^Tick, player: sim.Player) -> int {
	slot, _ := sim.player_slot(&t.state.players, player)
	return slot
}

player_pos :: proc(t: ^Tick, player: sim.Player) -> [3]f32 {
	return physics.position(t.world.phys, character_of(t, player).controller.body)
}

holding :: proc(character: ^Character) -> bool {
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

// An event's `entity` for an item: its level marker's.
item_entity :: proc(world: ^World, item: int) -> u64 {
	return marker_entity(world.items[item].marker)
}

// What a body is, from its user material: an item (its index) or a player (its handle).
Entity :: struct {
	kind:   Held_Kind,
	item:   int, // .Item: the item index
	player: sim.Player, // .Player
}

// Makes the player's character limp (no drive force, pogo released) while held, stunned or waiting to respawn.
entity_of :: proc(t: ^Tick, material: u64) -> (entity: Entity) {
	switch {
	case material >= MAT_ITEM && material < MAT_ITEM + MAX_ITEMS:
		return {kind = .Item, item = int(material - MAT_ITEM)}
	case material >= MAT_PLAYER && material < MAT_PLAYER + CHARACTERS:
		// A player's body exists only while they are present: the member at that index is its owner.
		index := int(material - MAT_PLAYER)
		return {kind = .Player, player = {u16(index), t.state.players.members[index].id}}
	}
	return
}

limp :: proc(t: ^Tick, player: sim.Player) {
	physics.character_set_limp(t.world.phys, &character_of(t, player).controller, true)
}

// ---- presence

// The harness has applied the tick's leaves and joins: a player who left lets go of everything (and is let go
// of), and their body goes; a player who joined or came back gets a fresh body at their slot's spawn.
presence :: proc(t: ^Tick) {
	for player in t.player_changes.left {
		release_all(t, player)
		character := character_of(t, player)
		physics.character_destroy(t.world.phys, &character.controller)
		character^ = {}
	}
	for player in t.player_changes.joined do appear(t, player)
	for player in t.player_changes.returned do appear(t, player)
}

// Where the player (re)appears: their place at the team's last checkpoint during a run, else their hub spawn.
appear :: proc(t: ^Tick, player: sim.Player) {
	character := character_of(t, player)
	character^ = {
		facing = {0, 1},
		aim    = {0, 0, 1},
	}
	at := respawn_point(t, slot_of(t, player))
	physics.character_create(t.world.phys, &character.controller, &t.world.character_defs[player.index], at)
	sim.emit(t, Event_Spawned{position = sim.Position(at), player = player})
}

respawn_point :: proc(t: ^Tick, slot: int) -> [3]f32 {
	if t.state.checkpoint >= 0 {
		for i in 0 ..< t.world.checkpoint_count {
			checkpoint := &t.world.checkpoints[i]
			if checkpoint.index == int(t.state.checkpoint) {
				return checkpoint.volume.pos + {f32(slot) * 0.9 - 1.35, 0, 0}
			}
		}
	}
	return t.world.spawns[slot]
}

// Drops whatever the player holds and frees them if someone holds them.
release_all :: proc(t: ^Tick, player: sim.Player) {
	character := character_of(t, player)
	if holding(character) do drop(t, player)
	if character.held_by != {} do drop(t, character.held_by)
}

// ---- actions

// Break free, grab, drop, throw. Returns whether jump was pressed this tick (for the character).
player_actions :: proc(t: ^Tick, player: sim.Player, input: Input) -> (jump: bool) {
	character := character_of(t, player)
	buttons := sim.buttons(t, player)
	aim := dmath.dir3_vec(input.aim)
	if aim != {} do character.aim = aim
	if character.respawn > 0 do return
	jump = .Jump in buttons.pressed

	if character.held_by != {} {
		// Held: 3 jump presses within the window break free (not too early); the holder lets go anyway
		// after a while.
		character.held_ticks += 1
		if character.break_window > 0 do character.break_window -= 1
		else do character.break_presses = 0
		if .Jump in buttons.pressed {
			if character.break_presses == 0 do character.break_window = BREAK_FREE_WINDOW_TICKS
			character.break_presses += 1
		}
		if (character.break_presses >= 3 && character.held_ticks >= BREAK_FREE_MIN_TICKS) ||
		   character.held_ticks >= HELD_MAX_TICKS {
			drop(t, character.held_by)
			physics.set_velocity(
				t.world.phys,
				character.controller.body,
				physics.velocity(t.world.phys, character.controller.body) + {0, 4, 0},
			)
			sim.emit(t, Event_Broke_Free{position = sim.Position(player_pos(t, player)), player = player})
		}
		return false
	}
	if character.stun > 0 do return

	if .Grab in buttons.pressed {
		if holding(character) do drop(t, player)
		else do try_grab(t, player, false)
	} else if .Grab in buttons.down && !holding(character) {
		try_grab(t, player, true) // catch
	}
	if holding(character) {
		if .Throw in buttons.down do character.charge = min(character.charge + 1, THROW_CHARGE_TICKS)
		if .Throw in buttons.released do throw(t, player)
	} else {
		character.charge = 0
	}
	return
}

Target :: struct {
	using entity: Entity,
	grab_point:   int,
	distance:     f32,
}

// Grabs the target the player aims at (a ray along the aim), else the nearest grabbable in a 60° cone
// in front. `only_thrown`: catching, so only things in flight.
try_grab :: proc(t: ^Tick, player: sim.Player, only_thrown: bool) {
	character := character_of(t, player)
	chest := player_pos(t, player) + {0, HOLD_UP, 0}
	best := Target {
		distance = max(f32),
	}
	if hit, ok := physics.ray_closest(
		t.world.phys,
		chest,
		character.aim * (GRAB_RANGE + 0.7),
		{mask = CAT_ITEM | CAT_PLAYER | CAT_STATIC | CAT_PLATFORM},
		physics.link(character.controller.body),
	); ok {
		entity := entity_of(t, hit.material)
		if entity.kind != .None {
			grab_point := grabbable(t, player, entity, chest, only_thrown)
			if grab_point >= 0 do best = {entity, grab_point, 0}
		}
	}
	if best.kind == .None {
		forward := dmath.normalize2({character.aim.x, character.aim.z})
		if forward == {} do forward = character.facing
		consider :: proc(
			best: ^Target,
			entity: Entity,
			grab_point: int,
			offset: [3]f32,
			radius: f32,
			forward: [2]f32,
		) {
			if grab_point < 0 do return
			distance := dmath.length3(offset) - radius
			if distance > GRAB_RANGE || abs(offset.y) > 1.6 do return
			flat := dmath.normalize2({offset.x, offset.z})
			if distance > 0.4 && flat.x * forward.x + flat.y * forward.y < GRAB_CONE_COS do return
			if distance < best.distance do best^ = {entity, grab_point, distance}
		}
		for i in 0 ..< t.world.item_count {
			if !t.state.items[i].alive do continue
			item := Entity {
				kind = .Item,
				item = i,
			}
			consider(
				&best,
				item,
				grabbable(t, player, item, chest, only_thrown),
				physics.position(t.world.phys, t.state.items[i].body) - chest,
				ITEM_SPECS[t.world.items[i].kind].radius,
				forward,
			)
		}
		others := sim.iterate_present(&t.state.players)
		for _, other in sim.next(&others) {
			if other == player do continue
			target := Entity {
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
	if best.kind != .None do grab(t, player, best)
}

// The free grab point of a target the player may take (the nearest to `chest`), or -1.
grabbable :: proc(t: ^Tick, player: sim.Player, target: Entity, chest: [3]f32, only_thrown: bool) -> int {
	switch target.kind {
	case .Item:
		item := &t.state.items[target.item]
		if !item.alive || (only_thrown && item.thrown_ticks == 0) do return -1
		kind := t.world.items[target.item].kind
		spec := &ITEM_SPECS[kind]
		best, best_distance_sq := -1, max(f32)
		for point in 0 ..< int(spec.grab_points) {
			if item.holders[point] != {} do continue
			if spec.grab_points == 1 do return 0
			pos := physics.position(t.world.phys, item.body)
			point_pos :=
				pos + dmath.quat_rotate(physics.rotation(t.world.phys, item.body), grab_point_offset(kind, point))
			offset := point_pos - chest
			distance_sq := offset.x * offset.x + offset.y * offset.y + offset.z * offset.z
			if distance_sq < best_distance_sq do best, best_distance_sq = point, distance_sq
		}
		return best
	case .Player:
		if target.player == player || !sim.player_present(&t.state.players, target.player) do return -1
		held := character_of(t, target.player)
		if held.respawn > 0 || held.held_by != {} || held.held_kind == .Player do return -1
		if only_thrown && !held.thrown do return -1
		return 0
	case .None:
	}
	return -1
}

// The hold point in the holder's body frame (rotation locked: world axes) and the frame's rotation.
hold_frame :: proc(character: ^Character, target: Held_Kind) -> b3.Transform {
	up: f32 = HOLD_UP + character.aim.y * HOLD_PITCH + (target == .Player ? 0.5 : 0)
	offset := [3]f32{character.facing.x * HOLD_DIST, up, character.facing.y * HOLD_DIST}
	return {offset, yaw_quat(character.facing)}
}

// Starts a hold: a motor joint from the player's hold point to the target's grab point, its force capped by what
// the target weighs. A grabbed player drops what they held and goes limp.
grab :: proc(t: ^Tick, player: sim.Player, target: Target) {
	character := character_of(t, player)
	joint_def := b3.default_motor_joint_def()
	joint_def.base.body_id_a = physics.body_id(t.world.phys, character.controller.body)
	joint_def.base.local_frame_a = hold_frame(character, target.kind)
	joint_def.base.collide_connected = false
	joint_def.linear_hertz = 5
	joint_def.linear_damping_ratio = 1
	joint_def.angular_hertz = 5
	joint_def.angular_damping_ratio = 1
	entity: u64
	switch target.kind {
	case .Item:
		item := &t.state.items[target.item]
		kind := t.world.items[target.item].kind
		spec := &ITEM_SPECS[kind]
		joint_def.base.body_id_b = physics.body_id(t.world.phys, item.body)
		joint_def.base.local_frame_b = {grab_point_offset(kind, target.grab_point), {0, 0, 0, 1}}
		joint_def.max_spring_force = spec.lift * spec.mass * GRAVITY
		joint_def.max_spring_torque = spec.grab_points > 1 ? 0 : spec.mass * 20
		item.holders[target.grab_point] = player
		item.thrown_ticks = 0
		item.thrown_by = {}
		entity = item_entity(t.world, target.item)
	case .Player:
		held := character_of(t, target.player)
		if holding(held) do drop(t, target.player)
		held.held_by = player
		held.held_ticks = 0
		held.break_presses = 0
		held.break_window = 0
		held.stun = 0
		held.thrown = false
		held.charge = 0
		limp(t, target.player)
		joint_def.base.body_id_b = physics.body_id(t.world.phys, held.controller.body)
		joint_def.base.local_frame_b = {{}, {0, 0, 0, 1}}
		joint_def.max_spring_force =
			PLAYER_LIFT * physics.mass(t.world.phys, held.controller.body) * GRAVITY * CHARACTER_DEF.gravity_scale
		joint_def.max_spring_torque = 0
	case .None:
		return
	}
	character.hold = physics.joint_ref_of(b3.create_motor_joint(t.world.phys.id, &joint_def))
	character.held_kind = target.kind
	character.held_item = u8(target.item)
	character.held_player = target.player
	character.grab_point = u8(target.grab_point)
	character.charge = 0
	t.state.grabs += 1
	sim.emit(t, Event_Grabbed {
		entity      = entity,
		position    = sim.Position(player_pos(t, player)),
		player      = player,
		held_player = target.player,
		held_kind   = target.kind,
	})
}

// Lets go of whatever the player holds (no throw). A dropped friend falls and gets up on landing.
drop :: proc(t: ^Tick, player: sim.Player) {
	character := character_of(t, player)
	if !holding(character) do return
	physics.destroy_joint(t.world.phys, &character.hold)
	held_kind, held_player := character.held_kind, character.held_player
	entity: u64
	switch held_kind {
	case .Item:
		t.state.items[character.held_item].holders[character.grab_point] = {}
		entity = item_entity(t.world, int(character.held_item))
	case .Player:
		held := character_of(t, held_player)
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
		held_kind   = held_kind,
	})
}

// Throws what the player holds along their aim, faster the longer throw was charged, and tags a thrown item with
// its thrower for hit attribution. A heavy item is dropped instead.
throw :: proc(t: ^Tick, player: sim.Player) {
	character := character_of(t, player)
	kind, index, held_player := character.held_kind, int(character.held_item), character.held_player
	if kind == .Item && !ITEM_SPECS[t.world.items[index].kind].throwable {
		drop(t, player)
		return
	}
	charge := f32(character.charge) / f32(THROW_CHARGE_TICKS)
	speed := THROW_SPEED_MIN + THROW_SPEED_ADD * charge
	velocity := physics.velocity(t.world.phys, character.controller.body) + character.aim * speed + {0, 1.5, 0}
	drop(t, player)
	body: Body_Ref
	entity: u64
	if kind == .Item {
		item := &t.state.items[index]
		item.thrown_by = player
		item.thrown_ticks = THROWN_TAG_TICKS
		body = item.body
		entity = item_entity(t.world, index)
	} else {
		body = character_of(t, held_player).controller.body
	}
	physics.set_velocity(t.world.phys, body, velocity)
	t.state.throws += 1
	sim.emit(t, Event_Thrown {
		entity      = entity,
		position    = sim.Position(player_pos(t, player)),
		speed       = speed,
		player      = player,
		held_player = held_player,
		held_kind   = kind,
	})
}

// Every tick, before the characters: hold points follow facing and aim; holds whose target went away end.
update_holds :: proc(t: ^Tick) {
	players := sim.iterate_present(&t.state.players)
	for character in sim.next(&players) {
		if !holding(character) do continue
		if !physics.joint_valid(t.world.phys, character.hold) {
			character.held_kind = .None
			character.held_item = 0
			character.held_player = {}
			character.hold = {}
			continue
		}
		b3.joint_set_local_frame_a(
			physics.joint_id(t.world.phys, character.hold),
			hold_frame(character, character.held_kind),
		)
	}
}

// ---- movement

// Drives a free player's character from their move input and jump: facing follows the move (the aim while holding),
// and holding slows them down. A held, stunned or fallen player doesn't move themselves.
player_move :: proc(t: ^Tick, player: sim.Player, input: Input, jump: bool) {
	character := character_of(t, player)
	if character.respawn > 0 || character.held_by != {} || character.stun > 0 do return
	move := dmath.stick(input.move_x, input.move_z)
	if holding(character) {
		facing := dmath.normalize2({character.aim.x, character.aim.z})
		if facing != {} do character.facing = facing
	} else if move.x * move.x + move.y * move.y > 0.01 {
		character.facing = dmath.normalize2(move)
	}
	scale: f32 = 1
	if holding(character) {
		scale = HOLD_SLOW
		if character.held_kind == .Item && t.world.items[character.held_item].kind == .Heavy do scale = HOLD_SLOW_HEAVY
	}
	if physics.character_update(
		t.world.phys,
		&character.controller,
		&t.world.character_defs[player.index],
		move,
		jump,
		scale,
		DT,
	) {
		sim.emit(t, Event_Jumped{position = sim.Position(player_pos(t, player)), player = player})
	}
}

// Advances each platform along its path (by its mode, and while its trigger is active when it has one) and drives its
// kinematic body to the pose for its phase, a pure function of the platform's state.
platforms :: proc(t: ^Tick) {
	for i in 0 ..< t.world.platform_count {
		def := &t.world.platforms[i]
		platform := &t.state.platforms[i]
		total := physics.path_duration_ticks(&def.path, TICK_HZ)
		active := def.trigger < 0 || t.state.triggers[def.trigger].active
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
		physics.drive_kinematic(t.world.phys, platform.body, target, TICK_HZ)
	}
}

// A pad's launch: its vertical speed; a directed pad (a horizontal push) also sets the horizontal velocity,
// so it lands where the level expects whatever the run-up; a straight-up pad keeps it.
pad_velocity :: proc(pad: ^Pad_Def, velocity: [3]f32) -> [3]f32 {
	if pad.launch.x == 0 && pad.launch.z == 0 do return {velocity.x, pad.launch.y, velocity.z}
	return pad.launch
}

// Launches players whose feet and items whose bottom are inside a jump pad's volume, with a per-body cooldown. The
// sim checks the volumes itself rather than using Box3D sensors.
pads :: proc(t: ^Tick) {
	players := sim.iterate_present(&t.state.players)
	for character, player in sim.next(&players) {
		if character.pad_cooldown > 0 do character.pad_cooldown -= 1
		if character.respawn > 0 || character.held_by != {} || character.pad_cooldown > 0 do continue
		feet := player_pos(t, player) - {0, FEET - 0.05, 0}
		for k in 0 ..< t.world.pad_count {
			pad := &t.world.pads[k]
			if !in_volume(pad.volume, feet) do continue
			physics.set_velocity(
				t.world.phys,
				character.controller.body,
				pad_velocity(pad, physics.velocity(t.world.phys, character.controller.body)),
			)
			physics.character_launch(t.world.phys, &character.controller)
			character.pad_cooldown = PAD_COOLDOWN_TICKS
			t.state.pad_launches += 1
			sim.emit(t, Event_Launched{position = sim.Position(pad.volume.pos), player = player})
			break
		}
	}
	for i in 0 ..< t.world.item_count {
		item := &t.state.items[i]
		if item.pad_cooldown > 0 do item.pad_cooldown -= 1
		if !item.alive || item.holders != {} || item.pad_cooldown > 0 do continue
		pos := physics.position(t.world.phys, item.body)
		bottom := pos - {0, ITEM_SPECS[t.world.items[i].kind].radius * 0.8, 0}
		for k in 0 ..< t.world.pad_count {
			pad := &t.world.pads[k]
			if !in_volume(pad.volume, bottom) do continue
			physics.set_velocity(t.world.phys, item.body, pad_velocity(pad, physics.velocity(t.world.phys, item.body)))
			item.pad_cooldown = PAD_COOLDOWN_TICKS
			t.state.pad_launches += 1
			sim.emit(t, Event_Launched{entity = item_entity(t.world, i), position = sim.Position(pad.volume.pos)})
			break
		}
	}
}

// Knocks the player along `direction` (horizontal, unit) at `speed`, with a hop: stunned, drops what it holds.
knock :: proc(t: ^Tick, player: sim.Player, direction: [2]f32, speed: f32) {
	character := character_of(t, player)
	if character.held_by != {} || character.respawn > 0 do return
	if holding(character) do drop(t, player)
	limp(t, player)
	character.stun = STUN_TICKS
	character.thrown = false
	character.charge = 0
	physics.set_velocity(
		t.world.phys,
		character.controller.body,
		{direction.x * speed, KNOCKBACK_UP, direction.y * speed},
	)
	t.state.hits += 1
	sim.emit(t, Event_Hit {
		position = sim.Position(player_pos(t, player)),
		speed    = speed,
		player   = player,
	})
}

// Knocks a player whose centre is inside a bumper's volume away from the bumper's centre at its strength.
bumpers :: proc(t: ^Tick) {
	players := sim.iterate_present(&t.state.players)
	for character, player in sim.next(&players) {
		if character.stun > 0 || character.respawn > 0 || character.held_by != {} do continue
		pos := player_pos(t, player)
		for k in 0 ..< t.world.bumper_count {
			bumper := &t.world.bumpers[k]
			if !in_volume(bumper.volume, pos) do continue
			direction := dmath.normalize2({pos.x - bumper.volume.pos.x, pos.z - bumper.volume.pos.z})
			if direction == {} do direction = {-character.facing.x, -character.facing.y}
			knock(t, player, direction, bumper.strength)
			break
		}
	}
}

// ---- after the step

// Handles the step's Box3D hit events: a thrown or fast item knocks back a player it hits (not its holder, nor its
// thrower just after the throw), and a hard enough hit rings a bell. Then counts down the items' thrown tags.
hits :: proc(t: ^Tick) {
	physics.hit_events(t.world.phys, &t.world.hits)
	for &hit in t.world.hits {
		entity_a := entity_of(t, hit.material_a)
		entity_b := entity_of(t, hit.material_b)
		// Item hits a player.
		item_index, player := -1, sim.Player{}
		if entity_a.kind == .Item && entity_b.kind == .Player do item_index, player = entity_a.item, entity_b.player
		if entity_b.kind == .Item && entity_a.kind == .Player do item_index, player = entity_b.item, entity_a.player
		if item_index >= 0 {
			item := &t.state.items[item_index]
			if !sim.player_present(&t.state.players, player) ||
			   item.holders[0] == player ||
			   item.holders[1] == player {
				continue
			}
			own := item.thrown_by == player && item.thrown_ticks > THROWN_TAG_TICKS - THROWER_IGNORE_TICKS
			if own || (item.thrown_ticks == 0 && hit.speed < HIT_SPEED) do continue
			velocity := physics.velocity(t.world.phys, item.body)
			direction := dmath.normalize2({velocity.x, velocity.z})
			if direction == {} do direction = dmath.normalize2({hit.normal.x, hit.normal.z})
			knock(t, player, direction, KNOCKBACK)
			continue
		}
		// Anything hits a bell.
		for material in ([2]u64{hit.material_a, hit.material_b}) {
			if material < MAT_TRIGGER || material >= MAT_TRIGGER + MAX_TRIGGERS do continue
			trigger_index := int(material - MAT_TRIGGER)
			trigger := &t.state.triggers[trigger_index]
			if t.world.triggers[trigger_index].kind != .Bell || hit.speed < BELL_SPEED || trigger.cooldown > 0 do continue
			trigger.active = true
			trigger.cooldown = BELL_COOLDOWN_TICKS
			sim.emit(t, Event_Bell_Rung {
				entity   = marker_entity(t.world.triggers[trigger_index].marker),
				position = sim.Position(hit.point),
				speed    = hit.speed,
			})
		}
	}
	for i in 0 ..< t.world.item_count {
		if t.state.items[i].thrown_ticks > 0 do t.state.items[i].thrown_ticks -= 1
	}
}

// Updates the triggers after the step: a pressure plate is pressed while the mass over it reaches its threshold, and
// a switch (a player inside) or a lock (the key inside) latches on.
plates_and_switches :: proc(t: ^Tick) {
	for i in 0 ..< t.world.trigger_count {
		def := &t.world.triggers[i]
		trigger := &t.state.triggers[i]
		if trigger.cooldown > 0 do trigger.cooldown -= 1
		switch def.kind {
		case .Plate:
			// The mass of the bodies whose centre is over the plate (up to 2.5 m above it).
			top := def.volume.pos.y + def.volume.half.y
			low := def.volume.pos - def.volume.half
			high := def.volume.pos + def.volume.half + {0, 2.5, 0}
			physics.overlap_aabb(
				t.world.phys,
				low,
				high,
				&t.world.links,
				{mask = def.items_only ? CAT_ITEM : CAT_ITEM | CAT_PLAYER},
			)
			mass: f32 = 0
			for link in t.world.links {
				id := physics.link_id(t.world.phys, link)
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
					sim.emit(t, Event_Plate_On {
						entity   = entity,
						position = position,
						mass     = mass,
					})
				} else {
					sim.emit(t, Event_Plate_Off {
						entity   = entity,
						position = position,
						mass     = mass,
					})
				}
			}
		case .Switch:
			if trigger.active do continue
			players := sim.iterate_present(&t.state.players)
			for character, player in sim.next(&players) {
				if character.respawn > 0 do continue
				if in_volume(def.volume, player_pos(t, player)) {
					trigger.active = true
					sim.emit(t, Event_Switch_On {
						entity   = marker_entity(def.marker),
						position = sim.Position(def.volume.pos),
						player   = player,
					})
					break
				}
			}
		case .Lock:
			if trigger.active do continue
			for k in 0 ..< t.world.item_count {
				if t.world.items[k].kind != .Key || !t.state.items[k].alive do continue
				if in_volume(def.volume, physics.position(t.world.phys, t.state.items[k].body)) {
					trigger.active = true
					sim.emit(
						t,
						Event_Switch_On{entity = marker_entity(def.marker), position = sim.Position(def.volume.pos)},
					)
					break
				}
			}
		case .Bell:
		}
	}
}

// Counts down stuns; a thrown player gets up as soon as they land. A player whose stun ends stops being limp.
stuns :: proc(t: ^Tick) {
	players := sim.iterate_present(&t.state.players)
	for character, player in sim.next(&players) {
		if character.held_by != {} || character.stun == 0 do continue
		character.stun -= 1
		if character.thrown && character.stun <= THROWN_MAX_TICKS - THROWN_MIN_TICKS {
			// A thrown player gets up as soon as it lands.
			if _, ok := physics.ray_closest(
				t.world.phys,
				player_pos(t, player),
				{0, -(FEET + 0.25), 0},
				{},
				physics.link(character.controller.body),
			); ok {
				character.stun = 0
			}
		}
		if character.stun == 0 {
			character.thrown = false
			physics.character_set_limp(t.world.phys, &character.controller, false)
		}
	}
}

// Takes a player who fell below KILL_Y out for RESPAWN_TICKS (holds released, body parked far below), then brings
// them back at their respawn point; puts an item that fell back where the level placed it.
falls :: proc(t: ^Tick) {
	players := sim.iterate_present(&t.state.players)
	for character, player in sim.next(&players) {
		if character.respawn > 0 {
			character.respawn -= 1
			if character.respawn == 0 {
				pos := respawn_point(t, slot_of(t, player))
				physics.character_teleport(t.world.phys, &character.controller, pos)
				physics.character_set_limp(t.world.phys, &character.controller, false)
				sim.emit(t, Event_Respawned{position = sim.Position(pos), player = player})
			}
			continue
		}
		pos := player_pos(t, player)
		if pos.y >= KILL_Y do continue
		release_all(t, player)
		character.stun = 0
		character.thrown = false
		character.respawn = RESPAWN_TICKS
		limp(t, player)
		// Park the body far below while it waits (a spot per slot).
		physics.teleport(t.world.phys, character.controller.body, {f32(slot_of(t, player)) * 4, -60, 0})
		sim.emit(t, Event_Fell{position = sim.Position(pos), player = player})
	}
	for i in 0 ..< t.world.item_count {
		item := &t.state.items[i]
		if item.alive && physics.position(t.world.phys, item.body).y < KILL_Y do item_home(t, i)
	}
}

// Puts an item back where the level placed it.
item_home :: proc(t: ^Tick, index: int) {
	item := &t.state.items[index]
	for point in 0 ..< 2 {
		if item.holders[point] != {} do drop(t, item.holders[point])
	}
	physics.teleport(t.world.phys, item.body, t.world.items[index].pos, t.world.items[index].rot)
	item.thrown_ticks = 0
	item.thrown_by = {}
}

// ---- the run

// Moves the run on: a player in the start gate starts the run timer, players reaching checkpoints advance the team's
// checkpoint, the trophy on the finish ends the run (keeping the best time), and the route resets after the hold or
// as soon as nobody is present.
run :: proc(t: ^Tick) {
	nobody := sim.iterate_present(&t.state.players)
	if _, _, anyone := sim.next(&nobody); !anyone {
		if t.state.phase != .Hub do reset_route(t)
		return
	}
	switch t.state.phase {
	case .Hub:
		if t.world.start.half == {} do return
		players := sim.iterate_present(&t.state.players)
		for character, player in sim.next(&players) {
			if character.respawn > 0 do continue
			if in_volume(t.world.start, player_pos(t, player)) {
				t.state.phase = .Run
				t.state.run_tick = t.number
				sim.emit(t, Event_Run_Started{position = sim.Position(t.world.start.pos), player = player})
				break
			}
		}
	case .Run:
		players := sim.iterate_present(&t.state.players)
		for character, player in sim.next(&players) {
			if character.respawn > 0 do continue
			pos := player_pos(t, player)
			for i in 0 ..< t.world.checkpoint_count {
				checkpoint := &t.world.checkpoints[i]
				if checkpoint.index > int(t.state.checkpoint) && in_volume(checkpoint.volume, pos) {
					t.state.checkpoint = i32(checkpoint.index)
					sim.emit(t, Event_Checkpoint {
						position = sim.Position(checkpoint.volume.pos),
						index    = i32(checkpoint.index),
						player   = player,
					})
				}
			}
		}
		if t.world.finish.half == {} do return
		for i in 0 ..< t.world.item_count {
			if t.world.items[i].kind != .Trophy || !t.state.items[i].alive do continue
			if in_volume(t.world.finish, physics.position(t.world.phys, t.state.items[i].body)) {
				t.state.phase = .Finished
				t.state.finish_tick = t.number
				t.state.runs += 1
				ticks := t.number - t.state.run_tick
				if t.state.best_ticks == 0 || ticks < t.state.best_ticks do t.state.best_ticks = ticks
				sim.emit(t, Event_Run_Finished {
					entity   = item_entity(t.world, i),
					position = sim.Position(t.world.finish.pos),
					seconds  = f32(ticks) * DT,
				})
				break
			}
		}
	case .Finished:
		if t.number - t.state.finish_tick >= FINISH_HOLD_TICKS do reset_route(t)
	}
}

// Back to the hub: everyone home, every item, platform and trigger as the level made it.
reset_route :: proc(t: ^Tick) {
	holders := sim.iterate_present(&t.state.players)
	for _, player in sim.next(&holders) do release_all(t, player)
	t.state.phase = .Hub
	t.state.checkpoint = -1
	players := sim.iterate_present(&t.state.players)
	for character, player in sim.next(&players) {
		character.stun = 0
		character.thrown = false
		character.respawn = 0
		home := t.world.spawns[slot_of(t, player)]
		physics.character_teleport(t.world.phys, &character.controller, home)
		physics.character_set_limp(t.world.phys, &character.controller, false)
		sim.emit(t, Event_Respawned{position = sim.Position(home), player = player})
	}
	for i in 0 ..< t.world.item_count do item_home(t, i)
	for i in 0 ..< t.world.platform_count {
		t.state.platforms[i].phase = 0
		t.state.platforms[i].running = t.world.platforms[i].trigger < 0
	}
	for &trigger in t.state.triggers do trigger = {}
}
