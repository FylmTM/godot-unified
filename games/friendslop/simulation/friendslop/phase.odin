package friendslop

import "unified:physics"
import "unified:sim"

// Moves the run on: a player in the start gate starts the run timer, players reaching checkpoints advance the team's
// checkpoint, the trophy on the finish ends the run (keeping the best time), and the route resets after the hold or as
// soon as nobody is present.
advance_phase :: proc(t: ^Tick) {
	if sim.present_count(t) == 0 {
		if t.state.phase != .Hub do reset_route(t)
		return
	}
	switch t.state.phase {
	case .Hub:
		if t.world.start.half == {} do return
		players := sim.iterate_present(t)
		for character, player in sim.next(&players) {
			if character.respawn > 0 || !in_volume(t.world.start, player_pos(t, player)) do continue
			t.state.phase = .Run
			t.state.run_tick = t.number
			sim.emit(t, Event_Run_Started{position = sim.Position(t.world.start.pos), player = player})
			break
		}
	case .Run:
		players := sim.iterate_present(t)
		for character, player in sim.next(&players) {
			if character.respawn > 0 do continue
			pos := player_pos(t, player)
			for &checkpoint in sim.slice(&t.world.checkpoints) {
				if checkpoint.index <= int(t.state.checkpoint) || !in_volume(checkpoint.volume, pos) do continue
				t.state.checkpoint = i32(checkpoint.index)
				sim.emit(t, Event_Checkpoint {
					position = sim.Position(checkpoint.volume.pos),
					index    = i32(checkpoint.index),
					player   = player,
				})
			}
		}
		if t.world.finish.half == {} do return
		for i in 0 ..< t.world.item_count {
			if t.world.items[i].kind != .Trophy do continue
			if !in_volume(t.world.finish, physics.body_position(t.world.phys, t.state.items[i].body)) do continue
			t.state.phase = .Finished
			t.state.finish_tick = t.number
			ticks := t.number - t.state.run_tick
			if t.state.best_ticks == 0 || ticks < t.state.best_ticks do t.state.best_ticks = ticks
			sim.emit(t, Event_Run_Finished {
				entity     = sim.entity(t.world.items[i].marker),
				position   = sim.Position(t.world.finish.pos),
				duration_s = sim.seconds(ticks, TICK_HZ),
			})
			break
		}
	case .Finished:
		if t.number - t.state.finish_tick >= FINISH_HOLD_TICKS do reset_route(t)
	}
}

// Back to the hub: everyone home, every item, platform and trigger as the level made it.
reset_route :: proc(t: ^Tick) {
	holders := sim.iterate_present(t)
	for _, player in sim.next(&holders) do release_all(t, player)
	t.state.phase = .Hub
	t.state.checkpoint = -1
	players := sim.iterate_present(t)
	for character, player in sim.next(&players) {
		character.stun = 0
		character.thrown = false
		character.respawn = 0
		home := t.world.spawns[sim.player_slot(t, player)]
		physics.character_teleport(t.world.phys, &character.controller, home)
		physics.character_set_limp(t.world.phys, &character.controller, false)
		sim.emit(t, Event_Respawned{position = sim.Position(home), player = player})
	}
	for i in 0 ..< t.world.item_count do send_item_home(t, i)
	for i in 0 ..< t.world.platform_count {
		t.state.platforms[i].phase = 0
		t.state.platforms[i].running = t.world.platforms[i].trigger < 0
	}
	for &trigger in t.state.triggers do trigger = {}
}
