// The tick (games/friendslop/SPEC.md), in this order: presence; per player input (break free, grab, drop,
// throw); holds; movers; platforms; pads and bumpers; the physics step; hits (players, bells);
// plates and switches; stuns; falls; the run (start, checkpoints, finish, reset).
package friendslop

import "unified:b3"
import "unified:dmath"
import "unified:physics"
import "unified:sim"

Events :: ^[dynamic]sim.Event

tick :: proc(s: ^State, w: ^World, t: u32, inputs: ^Inputs, events: Events) {
	presence(s, w, inputs, events)
	jumps: [MAX_PLAYERS]bool
	for p in 0 ..< MAX_PLAYERS {
		if s.players[p].active do jumps[p] = player_actions(s, w, p, inputs.input[p], events)
	}
	update_holds(s, w)
	for p in 0 ..< MAX_PLAYERS {
		if s.players[p].active do player_move(s, w, p, inputs.input[p], jumps[p], events)
	}
	platforms(s, w)
	pads(s, w, events)
	bumpers(s, w, events)
	physics.step(w.phys, DT, SUBSTEPS)
	hits(s, w, events)
	plates_and_switches(s, w, events)
	stuns(s, w)
	falls(s, w, events)
	run(s, w, t, events)
}

// ---- helpers

player_pos :: proc(s: ^State, w: ^World, p: int) -> [3]f32 {
	return physics.position(w.phys, s.players[p].mover.body)
}

holding :: proc(pl: ^Player) -> bool {
	return pl.held_kind != .None
}

// The yaw quaternion turning local +z to `facing` (unit x, z), from half-angle identities (sqrt only).
yaw_quat :: proc(facing: [2]f32) -> [4]f32 {
	c := dmath.sqrt(max(0, (1 + facing.y) * 0.5))
	sn := dmath.sqrt(max(0, (1 - facing.y) * 0.5))
	if facing.x < 0 do sn = -sn
	return {0, sn, 0, c}
}

item_key :: proc(w: ^World, i: int) -> u32 {
	return u32(w.items[i].marker + 1)
}

// What a body is, from its user material: (Held_Kind.Item, index), (.Player, slot) or (.None, -1).
entity_of :: proc(material: u64) -> (Held_Kind, int) {
	switch {
	case material >= MAT_ITEM && material < MAT_ITEM + MAX_ITEMS:
		return .Item, int(material - MAT_ITEM)
	case material >= MAT_PLAYER && material < MAT_PLAYER + MAX_PLAYERS:
		return .Player, int(material - MAT_PLAYER)
	}
	return .None, -1
}

limp :: proc(s: ^State, w: ^World, p: int) {
	physics.mover_set_limp(w.phys, &s.players[p].mover, true)
}

// ---- presence

presence :: proc(s: ^State, w: ^World, inputs: ^Inputs, events: Events) {
	for p in 0 ..< MAX_PLAYERS {
		pl := &s.players[p]
		here := p in inputs.present
		if here && !pl.active {
			pl^ = {
				active = true,
				facing = {0, 1},
				aim    = {0, 0, 1},
			}
			physics.mover_create(w.phys, &pl.mover, &w.movers[p], respawn_point(s, w, p))
			sim.emit(events, Event_Kind.Player_Joined, u32(p + 1), respawn_point(s, w, p), slot = p)
		} else if !here && pl.active {
			release_all(s, w, p, events)
			physics.mover_destroy(w.phys, &pl.mover)
			pl^ = {}
			sim.emit(events, Event_Kind.Player_Left, u32(p + 1), slot = p)
		}
	}
}

respawn_point :: proc(s: ^State, w: ^World, p: int) -> [3]f32 {
	if s.checkpoint >= 0 {
		for i in 0 ..< w.n_checkpoints {
			c := &w.checkpoints[i]
			if c.index == int(s.checkpoint) {
				return c.vol.pos + {f32(p) * 0.9 - 1.35, 0, 0}
			}
		}
	}
	return w.spawns[p]
}

// Drops whatever p holds and frees p if someone holds them.
release_all :: proc(s: ^State, w: ^World, p: int, events: Events) {
	pl := &s.players[p]
	if holding(pl) do drop(s, w, p, events)
	if pl.held_by != 0 do drop(s, w, int(pl.held_by) - 1, events)
}

// ---- actions

// Break free, grab, drop, throw. Returns whether jump was pressed this tick (for the mover).
player_actions :: proc(s: ^State, w: ^World, p: int, in_: Input, events: Events) -> (jump: bool) {
	pl := &s.players[p]
	pressed := in_.buttons & ~pl.prev_buttons
	released := pl.prev_buttons & ~in_.buttons
	pl.prev_buttons = in_.buttons
	aim := dmath.normalize3({f32(in_.aim_x), f32(in_.aim_y), f32(in_.aim_z)})
	if aim != {} do pl.aim = aim
	if pl.respawn > 0 do return
	jump = pressed & BUTTON_JUMP != 0

	if pl.held_by != 0 {
		// Held: 3 jump presses within the window break free (not too early); the holder lets go anyway
		// after a while.
		pl.held_ticks += 1
		if pl.break_window > 0 do pl.break_window -= 1
		else do pl.break_presses = 0
		if pressed & BUTTON_JUMP != 0 {
			if pl.break_presses == 0 do pl.break_window = BREAK_FREE_WINDOW_TICKS
			pl.break_presses += 1
		}
		if (pl.break_presses >= 3 && pl.held_ticks >= BREAK_FREE_MIN_TICKS) || pl.held_ticks >= HELD_MAX_TICKS {
			holder := int(pl.held_by) - 1
			drop(s, w, holder, events)
			physics.set_velocity(w.phys, pl.mover.body, physics.velocity(w.phys, pl.mover.body) + {0, 4, 0})
			sim.emit(events, Event_Kind.Broke_Free, u32(p + 1), player_pos(s, w, p), slot = p)
		}
		return false
	}
	if pl.stun > 0 do return

	if pressed & BUTTON_GRAB != 0 {
		if holding(pl) do drop(s, w, p, events)
		else do try_grab(s, w, p, false, events)
	} else if in_.buttons & BUTTON_GRAB != 0 && !holding(pl) {
		try_grab(s, w, p, true, events) // catch
	}
	if holding(pl) {
		if in_.buttons & BUTTON_THROW != 0 do pl.charge = min(pl.charge + 1, THROW_CHARGE_TICKS)
		if released & BUTTON_THROW != 0 do throw(s, w, p, events)
	} else {
		pl.charge = 0
	}
	return
}

Target :: struct {
	kind:   Held_Kind,
	index:  int,
	handle: int,
	dist:   f32,
}

// Grabs the target the player aims at (a ray along the aim), else the nearest grabbable in a 60° cone
// in front. `only_thrown`: catching, so only things in flight.
try_grab :: proc(s: ^State, w: ^World, p: int, only_thrown: bool, events: Events) {
	pl := &s.players[p]
	chest := player_pos(s, w, p) + {0, HOLD_UP, 0}
	best := Target {
		dist = max(f32),
	}
	if h, ok := physics.ray_closest(
		w.phys,
		chest,
		pl.aim * (GRAB_RANGE + 0.7),
		{mask = CAT_ITEM | CAT_PLAYER | CAT_STATIC | CAT_PLATFORM},
		physics.link(pl.mover.body),
	); ok {
		kind, index := entity_of(h.material)
		if kind != .None {
			handle := grabbable(s, w, p, kind, index, chest, only_thrown)
			if handle >= 0 do best = {kind, index, handle, 0}
		}
	}
	if best.kind == .None {
		fwd := dmath.normalize2({pl.aim.x, pl.aim.z})
		if fwd == {} do fwd = pl.facing
		consider :: proc(best: ^Target, kind: Held_Kind, index, handle: int, d: [3]f32, radius: f32, fwd: [2]f32) {
			if handle < 0 do return
			dist := dmath.length3(d) - radius
			if dist > GRAB_RANGE || abs(d.y) > 1.6 do return
			flat := dmath.normalize2({d.x, d.z})
			if dist > 0.4 && flat.x * fwd.x + flat.y * fwd.y < GRAB_CONE_COS do return
			if dist < best.dist do best^ = {kind, index, handle, dist}
		}
		for i in 0 ..< w.n_items {
			if !s.items[i].alive do continue
			pos := physics.position(w.phys, s.items[i].body)
			consider(
				&best,
				.Item,
				i,
				grabbable(s, w, p, .Item, i, chest, only_thrown),
				pos - chest,
				ITEM_SPECS[w.items[i].kind].radius,
				fwd,
			)
		}
		for q in 0 ..< MAX_PLAYERS {
			if q == p || !s.players[q].active do continue
			consider(
				&best,
				.Player,
				q,
				grabbable(s, w, p, .Player, q, chest, only_thrown),
				player_pos(s, w, q) - chest,
				PLAYER_RADIUS,
				fwd,
			)
		}
	}
	if best.kind != .None do grab(s, w, p, best, events)
}

// The free grab point of a target p may take (the nearest to `chest`), or -1.
grabbable :: proc(s: ^State, w: ^World, p: int, kind: Held_Kind, index: int, chest: [3]f32, only_thrown: bool) -> int {
	switch kind {
	case .Item:
		it := &s.items[index]
		if !it.alive || (only_thrown && it.thrown_ticks == 0) do return -1
		spec := &ITEM_SPECS[w.items[index].kind]
		best, best_d := -1, max(f32)
		for h in 0 ..< int(spec.handles) {
			if it.holders[h] != 0 do continue
			if spec.handles == 1 do return 0
			pos := physics.position(w.phys, it.body)
			hp := pos + physics.rotate(physics.rotation(w.phys, it.body), item_handle(w.items[index].kind, h))
			d := hp - chest
			dd := d.x * d.x + d.y * d.y + d.z * d.z
			if dd < best_d do best, best_d = h, dd
		}
		return best
	case .Player:
		q := &s.players[index]
		if !q.active || q.respawn > 0 || q.held_by != 0 || q.held_kind == .Player do return -1
		if only_thrown && !q.thrown do return -1
		return 0
	case .None:
	}
	return -1
}

// The hold point in the holder's body frame (rotation locked: world axes) and the frame's rotation.
hold_frame :: proc(pl: ^Player, target: Held_Kind) -> b3.Transform {
	up: f32 = HOLD_UP + pl.aim.y * HOLD_PITCH + (target == .Player ? 0.5 : 0)
	off := [3]f32{pl.facing.x * HOLD_DIST, up, pl.facing.y * HOLD_DIST}
	return {off, yaw_quat(pl.facing)}
}

grab :: proc(s: ^State, w: ^World, p: int, t: Target, events: Events) {
	pl := &s.players[p]
	jd := b3.default_motor_joint_def()
	jd.base.body_id_a = physics.body_id(w.phys, pl.mover.body)
	jd.base.local_frame_a = hold_frame(pl, t.kind)
	jd.base.collide_connected = false
	jd.linear_hertz = 5
	jd.linear_damping_ratio = 1
	jd.angular_hertz = 5
	jd.angular_damping_ratio = 1
	key: u32
	switch t.kind {
	case .Item:
		it := &s.items[t.index]
		kind := w.items[t.index].kind
		spec := &ITEM_SPECS[kind]
		jd.base.body_id_b = physics.body_id(w.phys, it.body)
		jd.base.local_frame_b = {item_handle(kind, t.handle), {0, 0, 0, 1}}
		jd.max_spring_force = spec.lift * spec.mass * GRAVITY
		jd.max_spring_torque = spec.handles > 1 ? 0 : spec.mass * 20
		it.holders[t.handle] = u8(p + 1)
		it.thrown_ticks = 0
		it.thrown_by = 0
		key = item_key(w, t.index)
	case .Player:
		q := &s.players[t.index]
		if holding(q) do drop(s, w, t.index, events)
		q.held_by = u8(p + 1)
		q.held_ticks = 0
		q.break_presses = 0
		q.break_window = 0
		q.stun = 0
		q.thrown = false
		q.charge = 0
		limp(s, w, t.index)
		jd.base.body_id_b = physics.body_id(w.phys, q.mover.body)
		jd.base.local_frame_b = {{}, {0, 0, 0, 1}}
		jd.max_spring_force = PLAYER_LIFT * physics.mass(w.phys, q.mover.body) * GRAVITY * MOVER.gravity_scale
		jd.max_spring_torque = 0
		key = u32(t.index + 1)
	case .None:
		return
	}
	pl.hold = physics.joint_ref_of(b3.create_motor_joint(w.phys.id, &jd))
	pl.held_kind = t.kind
	pl.held_index = u8(t.index)
	pl.handle = u8(t.handle)
	pl.charge = 0
	s.grabs += 1
	sim.emit(events, Event_Kind.Grabbed, key, player_pos(s, w, p), f32(t.kind), slot = p)
}

// Lets go of whatever p holds (no throw). A dropped friend falls and gets up on landing.
drop :: proc(s: ^State, w: ^World, p: int, events: Events) {
	pl := &s.players[p]
	if !holding(pl) do return
	physics.destroy_joint(w.phys, &pl.hold)
	key: u32
	switch pl.held_kind {
	case .Item:
		it := &s.items[pl.held_index]
		it.holders[pl.handle] = 0
		key = item_key(w, int(pl.held_index))
	case .Player:
		q := &s.players[pl.held_index]
		q.held_by = 0
		q.held_ticks = 0
		q.thrown = true
		q.stun = THROWN_MAX_TICKS
		key = u32(pl.held_index) + 1
	case .None:
	}
	pl.held_kind = .None
	pl.charge = 0
	sim.emit(events, Event_Kind.Dropped, key, player_pos(s, w, p), slot = p)
}

throw :: proc(s: ^State, w: ^World, p: int, events: Events) {
	pl := &s.players[p]
	kind, index := pl.held_kind, int(pl.held_index)
	if kind == .Item && !ITEM_SPECS[w.items[index].kind].throwable {
		drop(s, w, p, events)
		return
	}
	charge := f32(pl.charge) / f32(THROW_CHARGE_TICKS)
	speed := THROW_SPEED_MIN + THROW_SPEED_ADD * charge
	v := physics.velocity(w.phys, pl.mover.body) + pl.aim * speed + {0, 1.5, 0}
	drop(s, w, p, events)
	body: Body_Ref
	key: u32
	if kind == .Item {
		it := &s.items[index]
		it.thrown_by = u8(p + 1)
		it.thrown_ticks = THROWN_TAG_TICKS
		body = it.body
		key = item_key(w, index)
	} else {
		body = s.players[index].mover.body
		key = u32(index + 1)
	}
	physics.set_velocity(w.phys, body, v)
	s.throws += 1
	sim.emit(events, Event_Kind.Thrown, key, player_pos(s, w, p), speed, slot = p)
}

// Every tick, before the movers: hold points follow facing and aim; holds whose target went away end.
update_holds :: proc(s: ^State, w: ^World) {
	for p in 0 ..< MAX_PLAYERS {
		pl := &s.players[p]
		if !holding(pl) do continue
		if !physics.joint_valid(w.phys, pl.hold) {
			pl.held_kind = .None
			pl.hold = {}
			continue
		}
		b3.joint_set_local_frame_a(physics.joint_id(w.phys, pl.hold), hold_frame(pl, pl.held_kind))
	}
}

// ---- movement

player_move :: proc(s: ^State, w: ^World, p: int, in_: Input, jump: bool, events: Events) {
	pl := &s.players[p]
	if pl.respawn > 0 || pl.held_by != 0 || pl.stun > 0 do return
	move := [2]f32{f32(in_.move_x) / 127, f32(in_.move_z) / 127}
	move = dmath.clamp_length2(move, 1)
	if holding(pl) {
		f := dmath.normalize2({pl.aim.x, pl.aim.z})
		if f != {} do pl.facing = f
	} else if move.x * move.x + move.y * move.y > 0.01 {
		pl.facing = dmath.normalize2(move)
	}
	scale: f32 = 1
	if holding(pl) {
		scale = HOLD_SLOW
		if pl.held_kind == .Item && w.items[pl.held_index].kind == .Heavy do scale = HOLD_SLOW_HEAVY
	}
	if physics.mover_update(w.phys, &pl.mover, &w.movers[p], move, jump, scale, DT) {
		sim.emit(events, Event_Kind.Jumped, u32(p + 1), player_pos(s, w, p), slot = p)
	}
}

platforms :: proc(s: ^State, w: ^World) {
	for i in 0 ..< w.n_platforms {
		d := &w.platforms[i]
		pf := &s.platforms[i]
		total := physics.path_duration_ticks(&d.path, TICK_HZ)
		active := d.trigger < 0 || s.triggers[d.trigger].active
		switch d.mode {
		case .Ping_Pong, .Loop:
			if active do pf.running = true
			if pf.running do pf.phase += 1
		case .Once:
			if active do pf.running = true
			if pf.running && pf.phase < total do pf.phase += 1
		case .Follow:
			if active && pf.phase < total do pf.phase += 1
			if !active && pf.phase > 0 do pf.phase -= 1
		}
		target := d.origin + (physics.path_sample(&d.path, pf.phase, TICK_HZ) - d.path.points[0])
		physics.drive_kinematic(w.phys, pf.body, target, TICK_HZ)
	}
}

// A pad's launch: its vertical speed; a directed pad (a horizontal push) also sets the horizontal velocity,
// so it lands where the level expects whatever the run-up; a straight-up pad keeps it.
pad_velocity :: proc(pad: ^Pad_Def, v: [3]f32) -> [3]f32 {
	if pad.launch.x == 0 && pad.launch.z == 0 do return {v.x, pad.launch.y, v.z}
	return pad.launch
}

pads :: proc(s: ^State, w: ^World, events: Events) {
	for p in 0 ..< MAX_PLAYERS {
		pl := &s.players[p]
		if pl.pad_cooldown > 0 do pl.pad_cooldown -= 1
		if !pl.active || pl.respawn > 0 || pl.held_by != 0 || pl.pad_cooldown > 0 do continue
		feet := player_pos(s, w, p) - {0, FEET - 0.05, 0}
		for k in 0 ..< w.n_pads {
			pad := &w.pads[k]
			if !in_volume(pad.vol, feet) do continue
			physics.set_velocity(w.phys, pl.mover.body, pad_velocity(pad, physics.velocity(w.phys, pl.mover.body)))
			physics.mover_launch(w.phys, &pl.mover)
			pl.pad_cooldown = PAD_COOLDOWN_TICKS
			s.pad_launches += 1
			sim.emit(events, Event_Kind.Launched, u32(p + 1), pad.vol.pos, slot = p)
			break
		}
	}
	for i in 0 ..< w.n_items {
		it := &s.items[i]
		if it.pad_cooldown > 0 do it.pad_cooldown -= 1
		if !it.alive || it.holders != {} || it.pad_cooldown > 0 do continue
		pos := physics.position(w.phys, it.body)
		bottom := pos - {0, ITEM_SPECS[w.items[i].kind].radius * 0.8, 0}
		for k in 0 ..< w.n_pads {
			pad := &w.pads[k]
			if !in_volume(pad.vol, bottom) do continue
			physics.set_velocity(w.phys, it.body, pad_velocity(pad, physics.velocity(w.phys, it.body)))
			it.pad_cooldown = PAD_COOLDOWN_TICKS
			s.pad_launches += 1
			sim.emit(events, Event_Kind.Launched, item_key(w, i), pad.vol.pos)
			break
		}
	}
}

// Knocks player p along `dir` (horizontal, unit) at `speed`, with a hop: stunned, drops what it holds.
knock :: proc(s: ^State, w: ^World, p: int, dir: [2]f32, speed: f32, events: Events) {
	pl := &s.players[p]
	if pl.held_by != 0 || pl.respawn > 0 do return
	if holding(pl) do drop(s, w, p, events)
	limp(s, w, p)
	pl.stun = STUN_TICKS
	pl.thrown = false
	pl.charge = 0
	physics.set_velocity(w.phys, pl.mover.body, {dir.x * speed, KNOCKBACK_UP, dir.y * speed})
	s.hits += 1
	sim.emit(events, Event_Kind.Hit, u32(p + 1), player_pos(s, w, p), speed, slot = p)
}

bumpers :: proc(s: ^State, w: ^World, events: Events) {
	for p in 0 ..< MAX_PLAYERS {
		pl := &s.players[p]
		if !pl.active || pl.stun > 0 || pl.respawn > 0 || pl.held_by != 0 do continue
		pos := player_pos(s, w, p)
		for k in 0 ..< w.n_bumpers {
			b := &w.bumpers[k]
			if !in_volume(b.vol, pos) do continue
			dir := dmath.normalize2({pos.x - b.vol.pos.x, pos.z - b.vol.pos.z})
			if dir == {} do dir = {-pl.facing.x, -pl.facing.y}
			knock(s, w, p, dir, b.strength, events)
			break
		}
	}
}

// ---- after the step

hits :: proc(s: ^State, w: ^World, events: Events) {
	clear(&w.hits)
	physics.hit_events(w.phys, &w.hits)
	for &h in w.hits {
		ka, ia := entity_of(h.material_a)
		kb, ib := entity_of(h.material_b)
		// Item hits a player.
		item, player := -1, -1
		if ka == .Item && kb == .Player do item, player = ia, ib
		if kb == .Item && ka == .Player do item, player = ib, ia
		if item >= 0 {
			it := &s.items[item]
			pl := &s.players[player]
			if !pl.active || it.holders[0] == u8(player + 1) || it.holders[1] == u8(player + 1) do continue
			own := it.thrown_by == u8(player + 1) && it.thrown_ticks > THROWN_TAG_TICKS - THROWER_IGNORE_TICKS
			if own || (it.thrown_ticks == 0 && h.speed < HIT_SPEED) do continue
			v := physics.velocity(w.phys, it.body)
			dir := dmath.normalize2({v.x, v.z})
			if dir == {} do dir = dmath.normalize2({h.normal.x, h.normal.z})
			knock(s, w, player, dir, KNOCKBACK, events)
			continue
		}
		// Anything hits a bell.
		for m in ([2]u64{h.material_a, h.material_b}) {
			if m < MAT_TRIGGER || m >= MAT_TRIGGER + MAX_TRIGGERS do continue
			ti := int(m - MAT_TRIGGER)
			tr := &s.triggers[ti]
			if w.triggers[ti].kind != .Bell || h.speed < BELL_SPEED || tr.cooldown > 0 do continue
			tr.active = true
			tr.cooldown = BELL_COOLDOWN_TICKS
			sim.emit(events, Event_Kind.Bell_Rung, u32(w.triggers[ti].marker + 1), h.point, h.speed)
		}
	}
	for i in 0 ..< w.n_items {
		if s.items[i].thrown_ticks > 0 do s.items[i].thrown_ticks -= 1
	}
}

plates_and_switches :: proc(s: ^State, w: ^World, events: Events) {
	for i in 0 ..< w.n_triggers {
		d := &w.triggers[i]
		tr := &s.triggers[i]
		if tr.cooldown > 0 do tr.cooldown -= 1
		switch d.kind {
		case .Plate:
			// The mass of the bodies whose centre is over the plate (up to 2.5 m above it).
			top := d.vol.pos.y + d.vol.half.y
			clear(&w.links)
			lo := d.vol.pos - d.vol.half
			hi := d.vol.pos + d.vol.half + {0, 2.5, 0}
			physics.overlap_aabb(w.phys, lo, hi, &w.links, {mask = d.items_only ? CAT_ITEM : CAT_ITEM | CAT_PLAYER})
			mass: f32 = 0
			for l in w.links {
				id := physics.link_id(w.phys, l)
				c := b3.body_get_position(id)
				if abs(c.x - d.vol.pos.x) > d.vol.half.x || abs(c.z - d.vol.pos.z) > d.vol.half.z do continue
				if c.y < top - 0.2 || c.y > top + 2.5 do continue
				mass += b3.body_get_mass(id)
			}
			on := mass >= d.mass
			if on != tr.active {
				tr.active = on
				sim.emit(events, on ? Event_Kind.Plate_On : Event_Kind.Plate_Off, u32(d.marker + 1), d.vol.pos, mass)
			}
		case .Switch:
			if tr.active do continue
			for p in 0 ..< MAX_PLAYERS {
				if !s.players[p].active || s.players[p].respawn > 0 do continue
				if in_volume(d.vol, player_pos(s, w, p)) {
					tr.active = true
					sim.emit(events, Event_Kind.Switch_On, u32(d.marker + 1), d.vol.pos, slot = p)
					break
				}
			}
		case .Lock:
			if tr.active do continue
			for k in 0 ..< w.n_items {
				if w.items[k].kind != .Key || !s.items[k].alive do continue
				if in_volume(d.vol, physics.position(w.phys, s.items[k].body)) {
					tr.active = true
					sim.emit(events, Event_Kind.Switch_On, u32(d.marker + 1), d.vol.pos)
					break
				}
			}
		case .Bell:
		}
	}
}

stuns :: proc(s: ^State, w: ^World) {
	for p in 0 ..< MAX_PLAYERS {
		pl := &s.players[p]
		if !pl.active || pl.held_by != 0 || pl.stun == 0 do continue
		pl.stun -= 1
		if pl.thrown && pl.stun <= THROWN_MAX_TICKS - THROWN_MIN_TICKS {
			// A thrown player gets up as soon as it lands.
			pos := player_pos(s, w, p)
			if _, ok := physics.ray_closest(w.phys, pos, {0, -(FEET + 0.25), 0}, {}, physics.link(pl.mover.body)); ok {
				pl.stun = 0
			}
		}
		if pl.stun == 0 {
			pl.thrown = false
			physics.mover_set_limp(w.phys, &pl.mover, false)
		}
	}
}

falls :: proc(s: ^State, w: ^World, events: Events) {
	for p in 0 ..< MAX_PLAYERS {
		pl := &s.players[p]
		if !pl.active do continue
		if pl.respawn > 0 {
			pl.respawn -= 1
			if pl.respawn == 0 {
				pos := respawn_point(s, w, p)
				physics.mover_teleport(w.phys, &pl.mover, pos)
				physics.mover_set_limp(w.phys, &pl.mover, false)
				sim.emit(events, Event_Kind.Respawned, u32(p + 1), pos, slot = p)
			}
			continue
		}
		pos := player_pos(s, w, p)
		if pos.y >= KILL_Y do continue
		release_all(s, w, p, events)
		pl.stun = 0
		pl.thrown = false
		pl.respawn = RESPAWN_TICKS
		limp(s, w, p)
		// Park the body far below while it waits.
		physics.teleport(w.phys, pl.mover.body, {f32(p) * 4, -60, 0})
		sim.emit(events, Event_Kind.Fell, u32(p + 1), pos, slot = p)
	}
	for i in 0 ..< w.n_items {
		it := &s.items[i]
		if it.alive && physics.position(w.phys, it.body).y < KILL_Y do item_home(s, w, i, events)
	}
}

// Puts item i back where the level placed it.
item_home :: proc(s: ^State, w: ^World, i: int, events: Events) {
	it := &s.items[i]
	for h in 0 ..< 2 {
		if it.holders[h] != 0 do drop(s, w, int(it.holders[h]) - 1, events)
	}
	physics.teleport(w.phys, it.body, w.items[i].pos, w.items[i].rot)
	it.thrown_ticks = 0
	it.thrown_by = 0
}

// ---- the run

run :: proc(s: ^State, w: ^World, t: u32, events: Events) {
	switch s.phase {
	case .Hub:
		if w.start.half == {} do return
		for p in 0 ..< MAX_PLAYERS {
			if !s.players[p].active || s.players[p].respawn > 0 do continue
			if in_volume(w.start, player_pos(s, w, p)) {
				s.phase = .Run
				s.run_tick = t
				sim.emit(events, Event_Kind.Run_Started, 0, w.start.pos, slot = p)
				break
			}
		}
	case .Run:
		for p in 0 ..< MAX_PLAYERS {
			if !s.players[p].active || s.players[p].respawn > 0 do continue
			pos := player_pos(s, w, p)
			for i in 0 ..< w.n_checkpoints {
				c := &w.checkpoints[i]
				if c.index > int(s.checkpoint) && in_volume(c.vol, pos) {
					s.checkpoint = i32(c.index)
					sim.emit(events, Event_Kind.Checkpoint, u32(c.index), c.vol.pos, f32(c.index), slot = p)
				}
			}
		}
		if w.finish.half == {} do return
		for i in 0 ..< w.n_items {
			if w.items[i].kind != .Trophy || !s.items[i].alive do continue
			if in_volume(w.finish, physics.position(w.phys, s.items[i].body)) {
				s.phase = .Finished
				s.finish_tick = t
				s.runs += 1
				ticks := t - s.run_tick
				if s.best_ticks == 0 || ticks < s.best_ticks do s.best_ticks = ticks
				sim.emit(events, Event_Kind.Run_Finished, item_key(w, i), w.finish.pos, f32(ticks) * DT)
				break
			}
		}
	case .Finished:
		if t - s.finish_tick >= FINISH_HOLD_TICKS do reset_route(s, w, events)
	}
}

// Back to the hub: everyone home, every item, platform and trigger as the level made it.
reset_route :: proc(s: ^State, w: ^World, events: Events) {
	for p in 0 ..< MAX_PLAYERS {
		if s.players[p].active do release_all(s, w, p, events)
	}
	s.phase = .Hub
	s.checkpoint = -1
	for p in 0 ..< MAX_PLAYERS {
		pl := &s.players[p]
		if !pl.active do continue
		pl.stun = 0
		pl.thrown = false
		pl.respawn = 0
		physics.mover_teleport(w.phys, &pl.mover, w.spawns[p])
		physics.mover_set_limp(w.phys, &pl.mover, false)
		sim.emit(events, Event_Kind.Respawned, u32(p + 1), w.spawns[p], slot = p)
	}
	for i in 0 ..< w.n_items do item_home(s, w, i, events)
	for i in 0 ..< w.n_platforms {
		s.platforms[i].phase = 0
		s.platforms[i].running = w.platforms[i].trigger < 0
	}
	for &tr in s.triggers do tr = {}
}
