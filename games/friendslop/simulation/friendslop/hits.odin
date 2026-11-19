package friendslop

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// Knocks a player whose centre is inside a bumper's volume away from the bumper's centre at its strength.
bump_players :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for character, player in sim.next(&players) {
		if character.stun > 0 || sim.timer_running(t, character.respawn) || character.held_by != {} do continue
		pos := player_pos(t, player)
		for &bumper in sim.slice(&places(t).bumpers) {
			if !in_volume(bumper.volume, pos) do continue
			direction := dmath.normalize(pos.xz - bumper.volume.pos.xz)
			if direction == {} do direction = -character.facing
			knock(t, player, direction, bumper.strength, bumper = true)
			break
		}
	}
}

// The step's hit events: a thrown or fast item knocks back a player it hits (not its holder, nor its thrower just
// after the throw), and a hard enough hit rings a bell.
apply_hits :: proc(t: ^Tick) {
	physics.world_contact_events(t.world.phys, &t.world.contacts)
	for &hit in t.world.contacts {
		if hit.kind != .Hit do continue
		a, b := body_of(hit.a.category, hit.a.tag), body_of(hit.b.category, hit.b.tag)
		if a.kind == .Player && b.kind == .Item do a, b = b, a
		if a.kind == .Item && b.kind == .Player {
			hit_player(t, a.item, b.player, &hit)
			continue
		}
		for shape in ([2]physics.Overlap{hit.a, hit.b}) {
			if shape.category & CAT_TRIGGER != 0 do ring_bell(t, int(shape.tag), &hit)
		}
	}
}

// Item `index` hit `player`: knocked back along the item's motion if it was thrown or fast enough.
hit_player :: proc(t: ^Tick, index: int, player: sim.Player, hit: ^physics.Contact_Event) {
	item := &t.state.items[index]
	if !sim.player_present(t, player) || item.holders[0] == player || item.holders[1] == player do return
	// (a thrown item can't hit its thrower before it is clear of them: their bodies don't touch, age_throws)
	if !sim.timer_running(t, item.thrown) && hit.speed < HIT_SPEED do return
	direction := dmath.normalize(physics.body_linear_velocity(t.world.phys, item.body).xz)
	if direction == {} do direction = dmath.normalize(hit.normal.xz)
	knock(t, player, direction, KNOCKBACK, bumper = false)
}

// A hit on trigger `index`: a bell rings when the hit is fast enough and it is not cooling down.
ring_bell :: proc(t: ^Tick, index: int, hit: ^physics.Contact_Event) {
	def := &sim.slice(&places(t).triggers)[index]
	trigger := &t.state.triggers[index]
	if def.kind != .Bell || hit.speed < BELL_SPEED || sim.timer_running(t, trigger.cooldown) do return
	trigger.active = true
	sim.timer_start_ticks(t, &trigger.cooldown, u32(BELL_COOLDOWN_TICKS))
	sim.emit(
		t,
		Event_Bell_Rung{entity = sim.entity(def.marker), position = sim.Position(hit.point), speed = hit.speed},
	)
}

// Knocks the player along `direction` (horizontal, unit) at `speed`, with a hop: stunned, drops what it holds.
// `bumper`: a bumper knocked them, not an item (Event_Hit says which).
knock :: proc(t: ^Tick, player: sim.Player, direction: [2]f32, speed: f32, bumper: bool) {
	character := sim.player_data(t, player)
	if character.held_by != {} || sim.timer_running(t, character.respawn) do return
	if character.held_kind != .None do drop(t, player)
	physics.character_set_limp(t.world.phys, &character.controller, true)
	character.stun = STUN_TICKS
	character.thrown = false
	character.charge = 0
	physics.body_set_linear_velocity(
		t.world.phys,
		character.controller.body,
		{direction.x * speed, KNOCKBACK_UP, direction.y * speed},
	)
	sim.emit(
		t,
		Event_Hit{position = sim.Position(player_pos(t, player)), speed = speed, player = player, bumper = bumper},
	)
}
