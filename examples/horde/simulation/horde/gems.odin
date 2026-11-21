package horde

import "unified:dmath"
import "unified:sim"

// A gem within GEM_MAGNET of an alive hero flies to the nearest at GEM_SPEED; within GEM_PICKUP it is theirs: its
// value in XP.
pull_gems :: proc(t: ^Tick) {
	gems := sim.iterate(&t.state.gems)
	for gem, handle in sim.next(&gems) {
		best: ^Hero
		best_player: sim.Player
		best_sq := GEM_MAGNET * GEM_MAGNET
		players := sim.iterate_present(t)
		for hero, player in sim.next(&players) {
			if !hero.alive do continue
			distance_sq := dmath.length_sq(hero.pos - gem.pos)
			if distance_sq < best_sq {
				best, best_player, best_sq = hero, player, distance_sq
			}
		}
		if best == nil do continue
		if best_sq < GEM_PICKUP * GEM_PICKUP {
			best.xp += gem.value
			sim.emit(t, Event_Gem_Collected {
				gem      = handle,
				position = sim.position_2d(gem.pos),
				xp       = gem.value,
				player   = best_player,
			})
			sim.despawn(&t.state.gems, handle)
			continue
		}
		gem.pos += dmath.normalize(best.pos - gem.pos) * (GEM_SPEED * t.dt)
	}
}

// The XP a hero at `level` needs for the next.
xp_to_next :: proc(level: i32) -> i32 {
	return XP_BASE + XP_PER_LEVEL * level
}

// A hero with enough XP levels up (one level a tick): a pending pick, its event.
level_up :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for hero, player in sim.next(&players) {
		if !hero.started || hero.xp < xp_to_next(hero.level) do continue
		hero.xp -= xp_to_next(hero.level)
		hero.level += 1
		hero.pending_levelups += 1
		sim.emit(t, Event_Level_Up{player = player, position = sim.position_2d(hero.pos), level = hero.level})
	}
}
