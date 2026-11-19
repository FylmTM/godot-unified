package holdout

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// Leaves and arrivals: a player who left loses their body; one who joined or came back gets a fresh one at their spawn,
// at full health.
update_presence :: proc(t: ^Tick) {
	for player in t.player_changes.left {
		data := sim.player_data(t, player)
		physics.character_destroy(t.world.phys, &data.controller)
		data^ = {}
	}
	for player in t.player_changes.arrived do spawn_player(t, player, t.world.spawns[sim.player_slot(t, player)])
}

// A fresh body for a present player at `at`, up and at full health.
spawn_player :: proc(t: ^Tick, player: sim.Player, at: [3]f32) {
	data := sim.player_data(t, player)
	physics.character_destroy(t.world.phys, &data.controller)
	data^ = {
		hp    = PLAYER_HP,
		aim   = data.aim,
		kills = data.kills,
		warp  = data.warp + 1,
	}
	center := at + {0, PLAYER_HALF_HEIGHT + PLAYER_RADIUS, 0}
	physics.character_create(
		t.world.phys,
		&data.controller,
		t.world.character_def,
		center,
		tag = sim.player_key(player),
	)
}

// The centre of a player's capsule.
player_center :: proc(t: ^Tick, player: sim.Player) -> [3]f32 {
	return physics.body_position(t.world.phys, sim.player_data(t, player).controller.body)
}

// A player's eye: EYE_HEIGHT above their capsule's centre.
player_eye :: proc(t: ^Tick, player: sim.Player) -> [3]f32 {
	return player_center(t, player) + {0, EYE_HEIGHT, 0}
}

// Each player walks along their stick, turned by their aim's yaw (strafe, forward), and jumps on a press. A downed
// player lies still.
move_players :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for data, player in sim.next(&players) {
		input := sim.input(t, player)
		data.aim = input.aim
		if data.downed {
			physics.character_update(t.world.phys, &data.controller, t.world.character_def, {}, false, 1)
			continue
		}
		forward, right := dmath.aim_flat(input.aim)
		stick := dmath.stick(input.move_x, input.move_z)
		move := right.xz * stick.x + forward.xz * stick.y
		jump := .Jump in sim.buttons(t, player).pressed
		physics.character_update(t.world.phys, &data.controller, t.world.character_def, move, jump, 1)
		if player_center(t, player).y < KILL_Y do hurt_player(t, player, data.hp)
	}
}

// Takes `damage` from a player who is up: at 0 they go down (RESPAWN_S to get up at the core, unless revived).
hurt_player :: proc(t: ^Tick, player: sim.Player, damage: i16) {
	data := sim.player_data(t, player)
	if data.downed || damage <= 0 do return
	data.hp = dmath.max(data.hp - damage, 0)
	data.hurt_at = t.time
	sim.emit(t, Event_Player_Hurt{player = player, damage = damage})
	if data.hp > 0 do return
	data.downed = true
	data.revive_ticks = 0
	sim.timer_start(t, &data.respawn, RESPAWN_S)
	sim.emit(t, Event_Player_Downed{at = sim.Position(player_center(t, player)), player = player})
}

// A player who is up and holds Use beside a downed teammate (the nearest, by slot order on a tie) brings them closer to
// getting up; REVIVE_S of it gets them up with REVIVE_HP. A downed player no one revives this tick loses the progress.
revive_players :: proc(t: ^Tick) {
	revived: [PLAYERS]bool
	helpers := sim.iterate_present(t)
	for helper_data, helper in sim.next(&helpers) {
		if helper_data.downed || .Use not_in sim.buttons(t, helper).down do continue
		at := player_center(t, helper)
		best: sim.Player
		best_distance := REVIVE_RANGE * REVIVE_RANGE
		downed := sim.iterate_present(t)
		for data, player in sim.next(&downed) {
			if !data.downed do continue
			distance := dmath.dist_sq3(player_center(t, player), at)
			if distance <= best_distance do best, best_distance = player, distance
		}
		if best == {} do continue
		slot := sim.player_slot(t, best)
		if revived[slot] do continue
		revived[slot] = true
		data := sim.player_data(t, best)
		data.revive_ticks += 1
		if f32(data.revive_ticks) < REVIVE_S * TICK_HZ do continue
		data.downed, data.hp, data.revive_ticks, data.respawn = false, REVIVE_HP, 0, {}
		sim.emit(t, Event_Player_Revived{player = best, reviver = helper})
	}
	downed := sim.iterate_present(t)
	for data, player in sim.next(&downed) {
		if data.downed && !revived[sim.player_slot(t, player)] do data.revive_ticks = 0
	}
}

// A downed player whose RESPAWN_S ran out gets up at the core's spawn for their slot, at full health.
respawn_players :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for data, player in sim.next(&players) {
		if !data.downed || !sim.timer_fired(t, data.respawn) do continue
		at := t.world.spawns[sim.player_slot(t, player)]
		spawn_player(t, player, at)
		sim.emit(t, Event_Player_Respawned{at = sim.Position(at), player = player})
	}
}

// How many present players are up.
players_up :: proc(t: ^Tick) -> int {
	up := 0
	players := sim.iterate_present(t)
	for data in sim.next(&players) do up += int(!data.downed)
	return up
}
