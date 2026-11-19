package holdout

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// The run's phases (Phase): a Ready press in the lobby starts the countdown, then the waves with a break between, until
// the last is cleared or the core falls; OVER_HOLD_S later the yard is back to the lobby.
run_phase :: proc(t: ^Tick) {
	switch t.state.phase {
	case .Lobby:
		players := sim.iterate_present(t)
		for _, player in sim.next(&players) {
			if .Ready not_in sim.buttons(t, player).pressed do continue
			t.state.phase = .Countdown
			sim.timer_start(t, &t.state.phase_timer, START_DELAY_S)
			sim.emit(t, Event_Countdown{player = player})
			break
		}
	case .Countdown, .Break:
		if sim.timer_fired(t, t.state.phase_timer) do start_wave(t, t.state.wave + 1)
	case .Wave:
		if t.state.enemies.count > 0 do break
		plan := WAVE_PLANS[t.state.wave - 1]
		for burst, i in plan do if int(t.state.spawned[i]) < scaled_count(burst, wave_players(t)) do return
		sim.emit(t, Event_Wave_Cleared{wave = t.state.wave})
		if t.state.wave == WAVES {
			t.state.won = true
			over(t)
			sim.emit(t, Event_Victory{kills = t.state.kills})
		} else {
			t.state.phase = .Break
			sim.timer_start(t, &t.state.phase_timer, WAVE_BREAK_S)
		}
	case .Over:
		if sim.timer_fired(t, t.state.phase_timer) do back_to_lobby(t)
	}
}

// How many players a wave's bursts are scaled for: those present, at least one.
wave_players :: proc(t: ^Tick) -> int {
	return dmath.max(sim.present_count(t), 1)
}

start_wave :: proc(t: ^Tick, wave: u8) {
	t.state.phase = .Wave
	t.state.wave = wave
	t.state.wave_started = t.time
	t.state.spawned = {}
	sim.emit(t, Event_Wave_Started{wave = wave})
}

// During a wave, each burst spawns its next enemy at its gate once its time came (`start_s` into the wave, then one
// every `every_s`), while fewer than ENEMY_CAP are alive: one per burst per tick at most.
spawn_enemies :: proc(t: ^Tick) {
	if t.state.phase != .Wave do return
	elapsed := sim.seconds(u32(t.time - t.state.wave_started), TICK_HZ)
	plan := WAVE_PLANS[t.state.wave - 1]
	for burst, i in plan {
		spawned := int(t.state.spawned[i])
		if spawned >= scaled_count(burst, wave_players(t)) || t.state.enemies.count >= ENEMY_CAP do continue
		if elapsed < burst.start_s + f32(spawned) * burst.every_s do continue
		gate := t.world.gates[int(burst.gate) % t.world.gate_count]
		if spawn_enemy(t.state, t.world, burst.kind, gate) do t.state.spawned[i] += 1
	}
}

// The core fell during a wave or a break: the run is lost.
end_run :: proc(t: ^Tick) {
	if t.state.core_hp > 0 || (t.state.phase != .Wave && t.state.phase != .Break) do return
	t.state.won = false
	over(t)
	sim.emit(t, Event_Core_Destroyed{wave = t.state.wave})
}

over :: proc(t: ^Tick) {
	t.state.phase = .Over
	sim.timer_start(t, &t.state.phase_timer, OVER_HOLD_S)
}

// The yard as at the start: no enemies, bolts or grenades, the core whole, every present player up at their spawn.
back_to_lobby :: proc(t: ^Tick) {
	sim.emit(t, Event_Lobby{wave = t.state.wave, won = t.state.won})
	physics.despawn_all(t.world.phys, &t.state.enemies)
	physics.despawn_all(t.world.phys, &t.state.grenades)
	sim.despawn_all(&t.state.bolts)
	t.state.core_hp = CORE_HP
	t.state.kills = 0
	t.state.phase = .Lobby
	t.state.wave = 0
	t.state.won = false
	t.state.phase_timer = {}
	players := sim.iterate_present(t)
	for data, player in sim.next(&players) {
		data.kills = 0
		spawn_player(t, player, t.world.spawns[sim.player_slot(t, player)])
	}
}
