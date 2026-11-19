// The view contract and the frame (session thread): every view the state shows, and the HUD's data.
package extension

import "unified:dmath"
import "unified:godot"
import "unified:physics"
import "unified:sim"

import g "../friendslop"

// Scene views (the view index: a scene per kind, with a UnifiedView marker). A player's view is keyed by
// sim.player_key. Every sim object the level placed (items, platforms, bells, plates, switches, locks) is a `marker`
// view keyed by its level marker index (its events' `entity` is sim.entity of that index); the view adopts that
// marker's visuals.
View :: enum u8 {
	Player,
	Marker,
}

// No MultiMesh views.
MultiView :: enum u8 {}

Frame :: godot.Frame(g.Game, View, MultiView)

// An event about a player goes to that player's view. So grabbed, dropped and thrown stay with the holder's view, and
// a switch a player touched with the player's, where the default routing would send them to the item's or the
// switch's view (its `entity`: the marker view keyed by that marker's index). The rest: by their subject.
event_key :: proc(_: g.Event, subject: godot.Subject) -> (kind: View, key: u64, route: godot.Event_Route) {
	if subject.player != {} do return .Player, sim.player_key(subject.player), .View
	return
}

// The player view's data: set as its properties when it changes.
Player_View :: struct {
	limp:    bool, // stunned or held: the body tips over
	holding: bool,
	charge:  f32, // throw charge 0..1
}

fill_frame :: proc(f: ^Frame) {
	players := sim.iterate_present(&f.state.players)
	for character, player in sim.next(&players) {
		godot.push_view(f, player, {
			kind = .Player,
			pos  = sim.Position(physics.body_position(f.world.phys, character.controller.body)),
			rot  = dmath.quat_yaw(character.facing),
		}, Player_View {
			limp    = character.stun > 0 || character.held_by != {},
			holding = character.held_kind != .None,
			charge  = f32(character.charge) / f32(g.THROW_CHARGE_TICKS),
		})
	}
	for i in 0 ..< f.world.item_count do push_body(f, f.state.items[i].body, f.world.items[i].marker)
	for i in 0 ..< f.world.platform_count do push_body(f, f.state.platforms[i].body, f.world.platforms[i].marker)
	for i in 0 ..< f.world.trigger_count {
		marker := f.world.triggers[i].marker
		godot.push_view(f, sim.entity(marker), {
			kind = .Marker,
			pos  = sim.Position(f.world.triggers[i].volume.pos),
			rot  = physics.level_data(f.world.phys, g.Level_Id.Park).markers[marker].rot,
		})
	}
	godot.push_data(f, hud_of(f.state, f.tick))
}

// The marker view of a body the block owns (an item or a platform), where the body is.
push_body :: proc(f: ^Frame, body: physics.Body_Ref, marker: int) {
	if body == {} do return
	godot.push_view(f, sim.entity(marker), {
		kind = .Marker,
		pos  = sim.Position(physics.body_position(f.world.phys, body)),
		rot  = physics.body_rotation(f.world.phys, body),
	})
}
