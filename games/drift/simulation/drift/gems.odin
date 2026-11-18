package drift

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// Every gem drifts and slows; the first present ship in slot order within GEM_PICK_RADIUS picks it up (+1 score,
// GEM_REPAIR station HP); one nobody picks expires after GEM_LIFE_TICKS.
collect_gems :: proc(t: ^Tick) {
	Picker :: struct {
		ship:   ^Ship,
		player: sim.Player,
		pos:    [2]f32,
	}
	pickers: [PLAYERS]Picker
	picker_count := 0
	ships := sim.iterate_present(t)
	for ship, player in sim.next(&ships) {
		pickers[picker_count] = {ship, player, physics.body_position_2d(t.world.phys, ship.body)}
		picker_count += 1
	}
	gems := sim.iterate(&t.state.gems)
	each_gem: for gem, handle in sim.next(&gems) {
		gem.pos += gem.vel * t.dt
		gem.vel *= GEM_DRAG
		for picker in pickers[:picker_count] {
			if dmath.dist_sq(picker.pos, gem.pos) > GEM_PICK_RADIUS * GEM_PICK_RADIUS do continue
			picker.ship.gems += 1
			t.state.score += 1
			t.state.station_hp = dmath.min(t.state.station_hp + GEM_REPAIR, STATION_HP)
			sim.emit(t, Event_Gem_Picked{position = sim.position(gem.pos), player = picker.player})
			sim.despawn(&t.state.gems, handle)
			continue each_gem
		}
		if t.number - gem.spawn_tick >= GEM_LIFE_TICKS do sim.despawn(&t.state.gems, handle)
	}
}
