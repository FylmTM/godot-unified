// The HUD's session data (Data_Hud, pushed every frame by fill_frame): the run and the local player's state, derived
// from the state on the session thread. GDScript reads it as `Unified.data.hud` (class DataHud): `phase` is an
// EnumPhase value. View code, not simulation code: f32 for display only.
package holdout_extension

import "unified:sim"

import g "../holdout"

Data :: union {
	Data_Hud,
}

Data_Hud :: struct {
	phase:        g.Phase, // EnumPhase
	wave:         u8,
	up:           bool, // the local player is present and up
	downed:       bool,
	core_hp:      i32,
	enemies:      i32, // alive
	kills:        i32, // this run's, everyone's
	my_kills:     i32,
	hp:           i32, // the local player's
	timer_s:      f32, // Countdown, Break, Over: seconds to the next phase
	respawn_s:    f32, // downed: seconds until they get up at their spawn
	revive:       f32, // downed: a teammate's progress, 0..1
	grenade:      f32, // the grenade's cooldown left, 0..1 (0: ready)
	fire_ready:   bool, // the rifle would fire this tick (for the view's own muzzle flash)
	won:          bool, // Over: the yard held (else the core fell)
	players:      u8, // present
	players_down: u8,
}

hud_of :: proc(f: ^Frame) -> (hud: Data_Hud) {
	hud.phase = f.state.phase
	hud.wave = f.state.wave
	hud.won = f.state.won
	hud.core_hp = f.state.core_hp
	hud.enemies = i32(f.state.enemies.count)
	hud.kills = i32(f.state.kills)
	if f.state.phase == .Countdown || f.state.phase == .Break || f.state.phase == .Over {
		hud.timer_s = sim.timer_remaining_s(f.time, f.state.phase_timer, g.TICK_HZ)
	}
	players := sim.iterate_present(&f.state.players)
	for data in sim.next(&players) {
		hud.players += 1
		hud.players_down += u8(data.downed)
	}
	me := sim.player_data(&f.state.players, f.local_players[0])
	if me == nil || !sim.player_present(&f.state.players, f.local_players[0]) do return
	hud.up = !me.downed
	hud.downed = me.downed
	hud.hp = i32(me.hp)
	hud.my_kills = i32(me.kills)
	hud.fire_ready = !sim.timer_running(f.time, me.fire_ready)
	hud.grenade = 1 - sim.timer_fraction(f.time, me.grenade) if sim.timer_running(f.time, me.grenade) else 0
	if me.downed {
		hud.respawn_s = sim.timer_remaining_s(f.time, me.respawn, g.TICK_HZ)
		hud.revive = f32(me.revive_ticks) / (g.REVIVE_S * g.TICK_HZ)
	}
	return
}
