package friendslop

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// Knocks a player whose centre is inside a bumper's volume away from the bumper's centre at its strength.
bump_players :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for character, player in sim.next(&players) {
		if character.stun > 0 || character.respawn > 0 || character.held_by != {} do continue
		pos := player_pos(t, player)
		for &bumper in t.world.bumpers[:t.world.bumper_count] {
			if !in_volume(bumper.volume, pos) do continue
			direction := dmath.normalize(pos.xz - bumper.volume.pos.xz)
			if direction == {} do direction = -character.facing
			knock(t, player, direction, bumper.strength)
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
	own := item.thrown_by == player && item.thrown_ticks > THROWN_TAG_TICKS - THROWER_IGNORE_TICKS
	if own || (item.thrown_ticks == 0 && hit.speed < HIT_SPEED) do return
	direction := dmath.normalize(physics.body_linear_velocity(t.world.phys, item.body).xz)
	if direction == {} do direction = dmath.normalize(hit.normal.xz)
	knock(t, player, direction, KNOCKBACK)
}

// A hit on trigger `index`: a bell rings when the hit is fast enough and it is not cooling down.
ring_bell :: proc(t: ^Tick, index: int, hit: ^physics.Contact_Event) {
	def := &t.world.triggers[index]
	trigger := &t.state.triggers[index]
	if def.kind != .Bell || hit.speed < BELL_SPEED || trigger.cooldown > 0 do return
	trigger.active = true
	trigger.cooldown = BELL_COOLDOWN_TICKS
	sim.emit(
		t,
		Event_Bell_Rung{entity = sim.entity(def.marker), position = sim.Position(hit.point), speed = hit.speed},
	)
}

// Knocks the player along `direction` (horizontal, unit) at `speed`, with a hop: stunned, drops what it holds.
knock :: proc(t: ^Tick, player: sim.Player, direction: [2]f32, speed: f32) {
	character := sim.player_data(t, player)
	if character.held_by != {} || character.respawn > 0 do return
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
	sim.emit(t, Event_Hit{position = sim.Position(player_pos(t, player)), speed = speed, player = player})
}
