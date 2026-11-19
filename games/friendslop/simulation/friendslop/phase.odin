package friendslop

import "unified:physics"
import "unified:sim"

// Moves the run on: a player in the hub's start gate takes the team to the route and starts the run timer, players
// reaching checkpoints advance the team's checkpoint, the trophy on the finish ends the run (keeping the best time), and
// the team is back in the hub after the hold or as soon as nobody is present.
advance_phase :: proc(t: ^Tick) {
	if sim.present_count(t) == 0 {
		if t.state.phase != .Hub do reset_route(t)
		return
	}
	switch t.state.phase {
	case .Hub:
		if places(t).start.half == {} do return
		players := sim.iterate_present(t)
		for character, player in sim.next(&players) {
			if character.respawn > 0 || !in_volume(places(t).start, player_pos(t, player)) do continue
			at := places(t).start.pos
			start_run(t)
			sim.emit(t, Event_Run_Started{position = sim.Position(at), player = player})
			break
		}
	case .Run:
		players := sim.iterate_present(t)
		for character, player in sim.next(&players) {
			if character.respawn > 0 do continue
			pos := player_pos(t, player)
			for &checkpoint in sim.slice(&places(t).checkpoints) {
				if checkpoint.index <= int(t.state.checkpoint) || !in_volume(checkpoint.volume, pos) do continue
				t.state.checkpoint = i32(checkpoint.index)
				sim.emit(t, Event_Checkpoint {
					position = sim.Position(checkpoint.volume.pos),
					index    = i32(checkpoint.index),
					player   = player,
				})
			}
		}
		if places(t).finish.half == {} do return
		for i in 0 ..< places(t).item_count {
			if places(t).items[i].kind != .Trophy do continue
			if !in_volume(places(t).finish, physics.body_position(t.world.phys, t.state.items[i].body)) do continue
			t.state.phase = .Finished
			t.state.finish_tick = t.number
			ticks := t.number - t.state.run_tick
			if t.state.best_ticks == 0 || ticks < t.state.best_ticks do t.state.best_ticks = ticks
			sim.emit(t, Event_Run_Finished {
				entity     = sim.entity(places(t).items[i].marker),
				position   = sim.Position(places(t).finish.pos),
				duration_s = sim.seconds(ticks, TICK_HZ),
			})
			break
		}
	case .Finished:
		if t.number - t.state.finish_tick >= FINISH_HOLD_TICKS do reset_route(t)
	}
}

// To the route: the run's timer starts, the team at the route's spawns.
start_run :: proc(t: ^Tick) {
	t.state.phase = .Run
	t.state.run_tick = t.number
	t.state.checkpoint = -1
	enter_level(t, .Route)
}

// The players' travel commands, the first that goes somewhere: to the hub ends the run, to the route starts one.
travel :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for _, player in sim.next(&players) {
		for sent in sim.commands(t, player) {
			command := sent.(Cmd_Travel) or_continue
			if command.to == t.state.level.id do continue
			switch command.to {
			case .Hub:
				reset_route(t)
			case .Route:
				start_run(t)
				sim.emit(t, Event_Run_Started{position = sim.Position(places(t).spawns[0]), player = player})
			}
			return
		}
	}
}

// Back to the hub: everyone home, every item, platform and trigger as the hub makes them (enter_level).
reset_route :: proc(t: ^Tick) {
	t.state.phase = .Hub
	t.state.checkpoint = -1
	enter_level(t, .Hub)
	players := sim.iterate_present(t)
	for _, player in sim.next(&players) {
		sim.emit(
			t,
			Event_Respawned{position = sim.Position(places(t).spawns[sim.player_slot(t, player)]), player = player},
		)
	}
}
