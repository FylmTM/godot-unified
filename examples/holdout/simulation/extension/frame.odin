// The view contract and the frame (session thread): every view the state shows, and the HUD's data (hud.odin).
package holdout_extension

import "unified:dmath"
import "unified:godot"
import "unified:physics"
import "unified:sim"

import g "../holdout"

// Scene views (the view index: a scene per kind, with a UnifiedView marker), each kind its data: a player's, keyed by
// sim.player_key, and an enemy's, keyed by its handle (its events' `enemy`). The core and the level are the level
// scene's.
View :: union {
	View_Player,
	View_Enemy,
}

// MultiMesh views: bolts and grenades, keyed by their handles.
MultiView :: enum u8 {
	Bolt,
	Grenade,
}

Frame :: godot.Frame(g.Game, View, MultiView)

PLAYER_COLORS := [g.PLAYERS]godot.Color {
	{0.95, 0.45, 0.35, 1},
	{0.45, 0.85, 0.4, 1},
	{0.35, 0.7, 1, 1},
	{0.85, 0.55, 1, 1},
}

// A player: its pose is its feet, turned by its aim's yaw.
View_Player :: struct {
	color:  godot.Color,
	pitch:  f32, // the aim's pitch, turns: the head and the gun tilt by it
	hp:     i16,
	downed: bool,
	_pad:   u8,
	revive: f32, // a teammate's progress getting them up, 0..1
}

// An enemy: its pose is its feet, turned to where it faces.
View_Enemy :: struct {
	kind: g.Enemy_Kind, // EnumEnemyKind: which body the view shows
	_pad: [3]u8,
	hp:   f32, // left, 0..1
}

// Events go by their subject (a shot, a hurt or a throw to the player's view, an enemy's hit to its view), except
// what is no one view's: a death (its enemy is gone) and a revive (two players) go to the sim_event signal only.
event_key :: proc(event: g.Event, _: godot.Subject) -> godot.Event_Target {
	#partial switch _ in event {
	case g.Event_Enemy_Died, g.Event_Player_Revived:
		return {route = .No_View}
	}
	return {}
}

fill_frame :: proc(f: ^Frame) {
	phys := f.world.phys
	players := sim.iterate_present(&f.state.players)
	for data, player in sim.next(&players) {
		if data.controller.body == {} do continue
		center := physics.body_position(phys, data.controller.body)
		forward, _ := dmath.aim_flat(data.aim)
		slot := sim.player_slot(&f.state.players, player)
		godot.push_view(f, player, {
			pos  = sim.Position(center - {0, g.PLAYER_HALF_HEIGHT + g.PLAYER_RADIUS, 0}),
			rot  = dmath.quat_yaw(forward.xz),
			warp = data.warp,
		}, View_Player {
			color  = PLAYER_COLORS[slot],
			pitch  = dmath.aim_pitch(data.aim),
			hp     = data.hp,
			downed = data.downed,
			revive = f32(data.revive_ticks) / (g.REVIVE_S * g.TICK_HZ),
		})
	}
	enemies := sim.iterate(&f.state.enemies)
	for enemy, handle in sim.next(&enemies) {
		godot.push_view(f, handle, {
			pos = sim.Position(enemy.pos),
			rot = dmath.quat_yaw(enemy.facing),
		}, View_Enemy{kind = enemy.kind, hp = f32(enemy.hp) / f32(g.ENEMY_SPECS[enemy.kind].hp)})
	}
	bolts := sim.iterate(&f.state.bolts)
	for bolt, handle in sim.next(&bolts) {
		godot.push_multi_view(f, {key = sim.handle_key(handle), kind = .Bolt, pos = sim.Position(bolt.pos)})
	}
	grenades := sim.iterate(&f.state.grenades)
	for grenade, handle in sim.next(&grenades) {
		godot.push_multi_view(f, {
			key  = sim.handle_key(handle),
			kind = .Grenade,
			pos  = sim.Position(physics.body_position(phys, grenade.body)),
			rot  = physics.body_rotation(phys, grenade.body),
		})
	}
	godot.push_data(f, hud_of(f))
}
