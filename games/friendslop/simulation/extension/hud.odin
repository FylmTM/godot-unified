// The HUD's session data (Data_Hud, pushed every frame by fill_frame with godot.push_data): the run and per slot
// what its player is doing, derived from the state on the session thread. GDScript reads it as `Unified.data.hud`
// (class DataHud): `phase` is an EnumPhase value, `players` an Array[DataHudPlayer] by slot (zero for an empty slot);
// who holds a slot comes from the session. View code, not simulation code: f32 for display only. Plain and
// padding-free (`_pad`).
package extension

import "unified:dmath"
import "unified:sim"

import g "../friendslop"

Data :: union {
	Data_Hud,
}

Hud_Player :: struct {
	holding: g.Held_Kind, // an EnumHeldKind value
	held:    bool, // someone holds this player
	stunned: bool,
	fallen:  bool,
	charge:  f32, // 0..1
}

Data_Hud :: struct {
	phase:      g.Phase,
	_pad:       [3]u8,
	run_s:      f32, // the current run's time (Run), or the finished run's (Finished)
	best_s:     f32, // 0: none
	checkpoint: i32,
	reset_in_s: f32, // Finished: seconds until everyone is back in the hub
	players:    [g.PLAYERS]Hud_Player,
}

hud_of :: proc(f: ^Frame) -> (hud: Data_Hud) {
	hud.phase = f.state.phase
	hud.best_s = sim.seconds(f.state.best_ticks, g.TICK_HZ)
	hud.checkpoint = f.state.checkpoint
	switch f.state.phase {
	case .Hub:
	case .Run:
		hud.run_s = sim.seconds(f.tick - f.state.run_tick, g.TICK_HZ)
	case .Finished:
		hud.run_s = sim.seconds(f.state.finish_tick - f.state.run_tick, g.TICK_HZ)
		hud.reset_in_s = sim.seconds(
			g.FINISH_HOLD_TICKS - dmath.min(f.tick - f.state.finish_tick, g.FINISH_HOLD_TICKS),
			g.TICK_HZ,
		)
	}
	for slot in 0 ..< g.PLAYERS {
		character := sim.slot_data(&f.state.players, slot)
		if character == nil do continue
		hud.players[slot] = {
			holding = character.held_kind,
			held    = character.held_by != {},
			stunned = character.stun > 0,
			fallen  = sim.timer_running(f.time, character.respawn),
			charge  = f32(character.charge) / f32(g.THROW_CHARGE_TICKS),
		}
	}
	return
}
