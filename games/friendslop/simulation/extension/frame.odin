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
			warp = character.controller.warp,
		}, Player_View {
			limp    = character.stun > 0 || character.held_by != {},
			holding = character.held_kind != .None,
			charge  = f32(character.charge) / f32(g.THROW_CHARGE_TICKS),
		})
	}
	// The active level's things: a marker index names a marker of the level active at this tick.
	places := &f.world.places[f.state.level.id]
	for i in 0 ..< places.item_count {
		item := &f.state.items[i]
		push_body(f, item.body, places.items[i].marker, item.warp, held_by_one(item, places.items[i].kind))
	}
	for i in 0 ..< places.platform_count do push_body(f, f.state.platforms[i].body, places.platforms[i].marker)
	for i in 0 ..< places.trigger_count {
		marker := places.triggers[i].marker
		godot.push_view(f, sim.entity(marker), {
			kind = .Marker,
			pos  = sim.Position(places.triggers[i].volume.pos),
			rot  = physics.level_data(f.world.phys, f.state.level.id).markers[marker].rot,
		}, Marker_View{})
	}
	godot.push_data(f, hud_of(f.state, f.tick))
}

// The marker view's data: an item's holder, whom the view follows when that is the local player (marker_view.gd).
Marker_View :: struct {
	held_by: sim.Player, // the one player holding a one-handle item ({}: nobody, a two-handle item, not an item)
}

// The marker view of a body the block owns (an item or a platform), where the body is.
push_body :: proc(f: ^Frame, body: physics.Body_Ref, marker: int, warp: u8 = 0, held_by: sim.Player = {}) {
	if body == {} do return
	godot.push_view(f, sim.entity(marker), {
		kind = .Marker,
		pos  = sim.Position(physics.body_position(f.world.phys, body)),
		rot  = physics.body_rotation(f.world.phys, body),
		warp = warp,
	}, Marker_View{held_by = held_by})
}

// Who holds a one-handle item ({} for a two-handle one: it hangs from its grab point, not at the hand).
held_by_one :: proc(item: ^g.Item, kind: g.Item_Kind) -> sim.Player {
	return g.ITEM_SPECS[kind].grab_points > 1 ? {} : item.holders[0]
}
