package friendslop

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// Leaves and arrivals: a player who left lets go of everything (and is let go of), and their body goes; a player who
// joined or came back gets a fresh body at their respawn point.
update_presence :: proc(t: ^Tick) {
	for player in t.player_changes.left {
		release_all(t, player)
		character := sim.player_data(t, player)
		physics.character_destroy(t.world.phys, &character.controller)
		character^ = {}
	}
	for player in t.player_changes.arrived do spawn_character(t, player)
}

// A fresh body for a present player at their respawn point (an arrival, or every player when the team enters a level).
spawn_character :: proc(t: ^Tick, player: sim.Player) {
	character := sim.player_data(t, player)
	character^ = {
		facing = {0, 1},
		aim    = {0, 0, 1},
	}
	at := respawn_point(t, sim.player_slot(t, player))
	physics.character_create(
		t.world.phys,
		&character.controller,
		t.world.character_def,
		at,
		tag = sim.player_key(player),
	)
	sim.emit(t, Event_Spawned{position = sim.Position(at), player = player})
}

// Where a player in `slot` (re)appears: their place at the team's last checkpoint during a run, else their spawn in
// the active level.
respawn_point :: proc(t: ^Tick, slot: int) -> [3]f32 {
	if t.state.checkpoint >= 0 {
		for &checkpoint in sim.slice(&places(t).checkpoints) {
			if checkpoint.index == int(t.state.checkpoint) {
				spread := f32(slot) * CHECKPOINT_SPREAD - CHECKPOINT_SPREAD * (PLAYERS - 1) / 2
				return checkpoint.volume.pos + {spread, 0, 0}
			}
		}
	}
	return places(t).spawns[slot]
}

// The centre of the player's capsule.
player_pos :: proc(t: ^Tick, player: sim.Player) -> [3]f32 {
	return physics.body_position(t.world.phys, sim.player_data(t, player).controller.body)
}

// Drives each free player's character from their stick and jump press: facing follows the move (the aim while
// holding), and holding slows them down. A held, stunned or fallen player doesn't move themselves.
move_players :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for character, player in sim.next(&players) {
		if sim.timer_running(t, character.respawn) || character.held_by != {} || character.stun > 0 do continue
		input := sim.input(t, player)
		move := dmath.stick(input.move_x, input.move_z)
		holding := character.held_kind != .None
		if holding {
			facing := dmath.normalize(character.aim.xz)
			if facing != {} do character.facing = facing
		} else if dmath.length_sq(move) > TURN_STICK * TURN_STICK {
			character.facing = dmath.normalize(move)
		}
		speed_scale: f32 = 1
		if holding {
			speed_scale = HOLD_SLOW
			if character.held_kind == .Item && sim.slice(&places(t).items)[character.held_item].kind == .Heavy {
				speed_scale = HOLD_SLOW_HEAVY
			}
		}
		jump := .Jump in sim.buttons(t, player).pressed
		if physics.character_update(
			t.world.phys,
			&character.controller,
			t.world.character_def,
			move,
			jump,
			speed_scale,
		) {
			sim.emit(t, Event_Jumped{position = sim.Position(player_pos(t, player)), player = player})
		}
	}
}

// Counts down stuns; a thrown player gets up as soon as they land. A player whose stun ends stops being limp.
recover_from_stuns :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for character, player in sim.next(&players) {
		if character.held_by != {} || character.stun == 0 do continue
		character.stun -= 1
		if character.thrown && character.stun <= THROWN_MAX_TICKS - THROWN_MIN_TICKS {
			if _, ok := physics.world_cast_ray_closest(
				t.world.phys,
				player_pos(t, player),
				{0, -(FEET + LANDING_PROBE), 0},
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
// them back at their respawn point.
respawn_fallen :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for character, player in sim.next(&players) {
		if sim.timer_running(t, character.respawn) do continue
		if sim.timer_fired(t, character.respawn) {
			pos := respawn_point(t, sim.player_slot(t, player))
			physics.character_teleport(t.world.phys, &character.controller, pos)
			physics.character_set_limp(t.world.phys, &character.controller, false)
			sim.emit(t, Event_Respawned{position = sim.Position(pos), player = player})
			continue
		}
		pos := player_pos(t, player)
		if pos.y >= KILL_Y do continue
		release_all(t, player)
		character.stun = 0
		character.thrown = false
		sim.timer_start_ticks(t, &character.respawn, RESPAWN_TICKS)
		physics.character_set_limp(t.world.phys, &character.controller, true)
		park := [3]f32{f32(sim.player_slot(t, player)) * PARK_SPACING, PARK_Y, 0}
		physics.body_teleport(t.world.phys, character.controller.body, park) // the view snaps away, and back
		sim.emit(t, Event_Fell{position = sim.Position(pos), player = player})
	}
}
