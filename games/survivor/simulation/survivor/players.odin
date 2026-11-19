package survivor

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// Leaves and arrivals, respawns (none while the match is over), movement and the dash: the stick times the player's
// speed, DASH_SPEEDUP times that while dashing; the fall speed is the body's own.
update_players :: proc(t: ^Tick) {
	for player in t.player_changes.left {
		character_leave(t.world, sim.player_data(t, player))
	}
	for player in t.player_changes.joined {
		character_reset(sim.player_data(t, player)) // someone new: fresh progress
	}
	for player in t.player_changes.arrived {
		character_spawn(t.world, sim.player_data(t, player), sim.player_slot(t, player)) // one back keeps their progress
	}
	players := sim.iterate_present(t)
	for character, player in sim.next(&players) {
		if character.dash_cooldown > 0 {
			character.dash_cooldown -= 1
		}
		if !character.alive {
			if t.state.phase == .Over {
				continue // nobody respawns until the reset
			}
			character.respawn -= 1
			if character.respawn > 0 {
				continue
			}
			character_spawn(t.world, character, sim.player_slot(t, player))
			sim.emit(t, Event_Player_Respawned{position = sim.Position(character.pos), player = player})
		}
		if .Dash in sim.buttons(t, player).pressed && character.dash_cooldown == 0 {
			character.dash_ticks = DASH_TICKS
			character.dash_cooldown = DASH_COOLDOWN_TICKS
		}
		input := sim.input(t, player)
		move := dmath.stick(input.move_x, input.move_z) * character.speed
		if character.dash_ticks > 0 {
			move *= DASH_SPEEDUP
			character.dash_ticks -= 1
		}
		fall := physics.body_linear_velocity(t.world.phys, character.body).y
		physics.body_set_linear_velocity(t.world.phys, character.body, {move.x, fall, move.y})
	}
}

// The two upgrades a player's level-up to `level` offers. A keyed roll that names no tick (tick 0), only the player
// and the level, so the HUD computes the same offer from the state it shows, whenever it asks (sim.roll_below_at:
// src/sim/README.md, Random numbers).
upgrade_offers :: proc(seed: u64, player: sim.Player, level: i32) -> [2]Upgrade {
	key := sim.player_key(player)
	first := sim.roll_below_at(seed, 0, len(Upgrade), Roll.Upgrade_Offer, key, int(level) * 2)
	skip := sim.roll_below_at(seed, 0, len(Upgrade) - 1, Roll.Upgrade_Offer, key, int(level) * 2 + 1)
	return {Upgrade(first), Upgrade((first + 1 + skip) % len(Upgrade))}
}

// The level the oldest of a character's pending level-ups reached: the one a pick goes to.
oldest_pending_level :: proc(character: ^Character) -> i32 {
	return character.level - character.pending_levelups + 1
}

// Level-up picks (Cmd_Pick, each delivered once): each takes the oldest pending level-up if it is one of its offers.
pick_upgrades :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for character, player in sim.next(&players) {
		for sent in sim.commands(t, player) {
			pick := sent.(Cmd_Pick) or_continue
			if character.pending_levelups <= 0 {
				continue // nothing to pick
			}
			offers := upgrade_offers(t.seed, player, oldest_pending_level(character))
			if pick.upgrade != offers[0] && pick.upgrade != offers[1] {
				continue // not offered
			}
			switch pick.upgrade {
			case .Fire_Rate:
				character.fire_interval = dmath.max(
					character.fire_interval - FIRE_LEVELUP_TICKS,
					FIRE_INTERVAL_MIN_TICKS,
				)
			case .Damage:
				character.damage_bonus += DAMAGE_LEVELUP
			case .Move_Speed:
				character.speed += SPEED_LEVELUP
			}
			character.pending_levelups -= 1
		}
	}
}

// Damages an alive player (nobody, absent or dead: nothing); at HP <= 0 they die.
damage_player :: proc(t: ^Tick, player: sim.Player, amount: i32) {
	character := sim.player_data(t, player)
	if character == nil || !character.alive {
		return
	}
	character.hp -= amount
	if character.hp <= 0 {
		player_dies(t, character, player)
	}
}

// The body goes and the respawn timer starts.
player_dies :: proc(t: ^Tick, character: ^Character, player: sim.Player) {
	sim.emit(t, Event_Player_Died{position = sim.Position(character.pos), player = player})
	character.alive = false
	character.respawn = PLAYER_RESPAWN_TICKS
	character.dash_ticks = 0
	physics.destroy_body(t.world.phys, &character.body)
}

// A player who walks over a gem takes its XP (the first alive player in slot order).
collect_gems :: proc(t: ^Tick) {
	targets := targets_of(t)
	gems := sim.iterate(&t.state.gems)
	for gem, handle in sim.next(&gems) {
		for target in sim.slice(&targets) {
			character := target.character
			if !character.alive || dmath.dist_sq(character.pos.xz, gem.pos) >= GEM_REACH * GEM_REACH {
				continue
			}
			character.xp += gem.value
			sim.emit(t, Event_Gem_Collected {
				gem      = handle,
				position = sim.position_floor(gem.pos),
				xp       = gem.value,
				player   = target.player,
			})
			sim.despawn(&t.state.gems, handle)
			break
		}
	}
}

// XP over the level's threshold becomes levels, each a pending level-up to pick.
level_up :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for character, player in sim.next(&players) {
		for character.xp >= xp_next(&t.state.tuning, character.level) {
			character.xp -= xp_next(&t.state.tuning, character.level)
			character.level += 1
			character.pending_levelups += 1
			sim.emit(
				t,
				Event_Level_Up{position = sim.Position(character.pos), level = character.level, player = player},
			)
		}
	}
}

// The alive present players, in slot order, taken once for a pass over many enemies or gems instead of walking the
// presence for each (a pass that can kill checks `alive` again).
Targets :: sim.List(Target, PLAYERS)

// An alive present player and their data.
Target :: struct {
	character: ^Character,
	player:    sim.Player,
}

targets_of :: proc(t: ^Tick) -> (targets: Targets) {
	players := sim.iterate_present(t)
	for character, player in sim.next(&players) {
		if character.alive do sim.append(&targets, Target{character, player})
	}
	return
}

// The nearest alive target to `pos` on the ground (the lowest slot on ties); nil if none.
nearest_target :: proc(targets: ^Targets, pos: [2]f32) -> (best: ^Character) {
	best_distance_sq: f32
	for target in sim.slice(targets) {
		character := target.character
		if !character.alive {
			continue
		}
		distance_sq := dmath.dist_sq(character.pos.xz, pos)
		if best == nil || distance_sq < best_distance_sq {
			best, best_distance_sq = character, distance_sq
		}
	}
	return
}
